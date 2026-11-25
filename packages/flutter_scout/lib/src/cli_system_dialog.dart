part of 'flutter_scout_cli.dart';

// Native system dialogs above the app (runtime permission prompts and other
// system alerts) on the recorded iOS Simulator or Android emulator, plus the
// explicit `system-tap` answer and `permissions` pre-grant command.
//
// Mechanisms (read-only probes; one input only on an explicit system-tap):
// - Android: `dumpsys window` focus check, then `uiautomator dump` of the
//   focused window and the focused task's activities; `input tap`.
// - iOS Simulator: AXe (`axe describe-ui`, `axe tap`), an optional external
//   tool. Physical devices and macOS are not probed.
//
// The eyes probe only while Flutter reports the app not resumed or not
// rendering, while a dialog was last seen, or on an explicit query, and they
// reuse a probe for [_systemDialogProbeInterval].

const Duration _systemDialogProbeInterval = Duration(milliseconds: 1000);

/// Longest gap between probes while the app stays inactive or hidden with no
/// dialog found (a backgrounded app): each empty probe doubles the gap.
const Duration _systemDialogMaxProbeInterval = Duration(seconds: 5);
const Duration _systemDialogToolTimeout = Duration(seconds: 8);
const int _maxSystemDialogToolBytes = 8 * 1024 * 1024;
const String _axeInstallHint = 'brew install cameroncooke/axe/axe';

/// The AXe executable: `FLUTTER_SCOUT_AXE` when set, else `axe` on PATH.
String get _axeExecutable {
  final override = Platform.environment['FLUTTER_SCOUT_AXE']?.trim();
  return override == null || override.isEmpty ? 'axe' : override;
}

/// Lifecycle or rendering facts that mean something may cover the app.
bool _systemDialogTrigger(Map<String, dynamic> raw) {
  final rendering = raw['rendering'];
  if (rendering is! Map) return false;
  final lifecycle = rendering['lifecycle'];
  if (lifecycle is String && lifecycle != 'resumed') return true;
  final status = rendering['status'];
  return status is String && status != 'active' && status != 'driven';
}

class _SystemDialogProbe {
  _SystemDialogProbe(this.cli, {required this.vmPid});

  final FlutterScoutCli cli;
  final Future<int?> Function() vmPid;
  final Stopwatch _clock = Stopwatch()..start();

  _NativeMobileTarget? _target;
  String? _unsupported;
  bool _resolved = false;
  SystemDialogApp? _app;
  Map<String, Object?>? _last;
  int _lastAt = -1 << 30;
  bool _sticky = false;
  int _intervalMs = _systemDialogProbeInterval.inMilliseconds;
  Future<Map<String, Object?>>? _inflight;

  /// Resolves the exact recorded emulator once. Null when this session is
  /// not an iOS Simulator or Android emulator (macOS, physical devices).
  _NativeMobileTarget? get target {
    if (!_resolved) {
      _resolved = true;
      try {
        _target = cli._nativeMobileTargetFromRecorded(
          device: cli._readDevice(),
          deviceInfo: cli._readDeviceInfo(),
          operation: 'system_dialog',
        );
      } on ScoutCliException catch (error) {
        _unsupported = error.message;
      }
    }
    return _target;
  }

  /// The `systemDialog` block for one observation, or null when nothing is
  /// known to cover the app. Never blocks on a probe when the app is
  /// resumed and no dialog was seen.
  Future<Map<String, Object?>?> forObservation(Map<String, dynamic> raw) async {
    if (target == null) return null;
    if (!_sticky && !_systemDialogTrigger(raw)) {
      // Resumed: the next change of lifecycle probes at once.
      _last = null;
      _intervalMs = _systemDialogProbeInterval.inMilliseconds;
      return null;
    }
    final result = await probe();
    return result['present'] == false ? null : result;
  }

  /// One probe, shared by concurrent callers and reused for
  /// [_systemDialogProbeInterval] unless [force]d.
  Future<Map<String, Object?>> probe({bool force = false}) {
    final inflight = _inflight;
    if (inflight != null) return inflight;
    final last = _last;
    if (!force &&
        last != null &&
        _clock.elapsedMilliseconds - _lastAt < _intervalMs) {
      return Future.value(last);
    }
    final future = _probeOnce().then((value) {
      _last = value;
      _lastAt = _clock.elapsedMilliseconds;
      _sticky = value['present'] == true;
      _intervalMs = value['present'] == false
          ? min(_intervalMs * 2, _systemDialogMaxProbeInterval.inMilliseconds)
          : _systemDialogProbeInterval.inMilliseconds;
      return value;
    });
    _inflight = future;
    return future.whenComplete(() => _inflight = null);
  }

  /// The parsed dialog behind the last probe, for dispatch.
  SystemDialog? _dialog;

  Future<Map<String, Object?>> _probeOnce() async {
    final device = target;
    if (device == null) {
      return {
        'present': null,
        'status': 'unsupported',
        'reason': _unsupported ?? 'no native target',
      };
    }
    final started = _clock.elapsedMilliseconds;
    try {
      final app = await _sessionApp(device);
      final dialog = device.kind == _NativeMobilePlatform.androidEmulator
          ? await _probeAndroid(device, app)
          : await _probeIos(device, app);
      _dialog = dialog;
      final elapsed = _clock.elapsedMilliseconds - started;
      if (dialog == null) {
        return {'present': false, 'probeMs': elapsed};
      }
      return {
        ...dialog.toJson(),
        'sessionApp': app?.toJson(),
        'answer':
            "act {method:'system-tap', args:[<button handle>]} only when the "
            'task authorizes that answer; Scout never answers by itself',
        'probe': {
          'backend': device.kind == _NativeMobilePlatform.androidEmulator
              ? 'adb_uiautomator'
              : 'axe_accessibility',
          'probeMs': elapsed,
        },
      };
    } on _SystemDialogProbeUnavailable catch (error) {
      _dialog = null;
      return {
        'present': null,
        'status': 'probe_unavailable',
        'reason': error.reason,
        if (error.installHint != null) 'installHint': error.installHint,
        'note':
            'Scout cannot see native dialogs right now. If the app looks '
            'stuck, take a native screenshot or ask the user.',
      };
    }
  }

  Future<SystemDialogApp?> _sessionApp(_NativeMobileTarget device) async {
    final known = _app;
    if (known != null) return known;
    final pid = await vmPid();
    if (pid == null || pid <= 0) return null;
    final app = device.kind == _NativeMobilePlatform.androidEmulator
        ? await cli._androidAppForPid(device, pid)
        : await cli._iosAppForPid(pid);
    _app = app;
    return app;
  }

  Future<SystemDialog?> _probeAndroid(
    _NativeMobileTarget device,
    SystemDialogApp? app,
  ) async {
    final focusText = await _tool('adb', [
      '-s',
      device.id,
      'shell',
      "dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'",
    ], 'adb');
    final focus = parseAndroidFocus(focusText);
    if (focus.package != null && focus.package == app?.id) return null;
    final xml = await _tool('adb', [
      '-s',
      device.id,
      'exec-out',
      'uiautomator',
      'dump',
      '/dev/tty',
    ], 'adb');
    if (!xml.contains('<hierarchy')) {
      throw _SystemDialogProbeUnavailable(
        'uiautomator dump returned no hierarchy (${_firstLine(xml)})',
      );
    }
    var taskPackages = const <String>{};
    final task = focus.task;
    if (task != null) {
      final activities = await _tool('adb', [
        '-s',
        device.id,
        'shell',
        'dumpsys activity activities | grep ActivityRecord',
      ], 'adb');
      taskPackages = androidTaskPackages(activities, task);
    }
    return parseAndroidSystemDialog(xml, app: app, taskPackages: taskPackages);
  }

  Future<SystemDialog?> _probeIos(
    _NativeMobileTarget device,
    SystemDialogApp? app,
  ) async {
    final text = await _tool(_axeExecutable, [
      'describe-ui',
      '--udid',
      device.id,
    ], 'axe');
    Object? tree;
    try {
      tree = jsonDecode(text);
    } on FormatException {
      throw _SystemDialogProbeUnavailable(
        'axe describe-ui did not return JSON (${_firstLine(text)})',
      );
    }
    return parseIosSystemDialog(tree, app: app);
  }

  Future<String> _tool(String executable, List<String> args, String name) =>
      cli._systemDialogTool(executable, args, name);

  /// Presses one button of the observed dialog after a fresh probe proves
  /// it is unchanged. Returns a canonical agent receipt.
  Future<Map<String, dynamic>> tap(
    Map<String, dynamic> action,
    Map<String, dynamic> observed,
  ) async {
    Map<String, dynamic> refused({
      required String code,
      required String message,
      Map? facts,
    }) => {
      'ok': false,
      'dispatch': 'not_dispatched',
      'error': {'code': code, 'message': '$message Nothing was pressed.'},
      'systemDialog': ?facts,
      'businessCompletion': 'not_asserted',
    };
    final handle = (action['args'] as List).single as String;
    final params = action['params'] as Map? ?? const {};
    final owner = params['dialogOwner'] as String?;
    final decided = observed['systemDialog'];
    final device = target;
    if (device == null) {
      return refused(
        code: 'system_dialog_unsupported',
        message:
            'system dialogs are handled only on the recorded iOS Simulator '
            'or Android emulator (${_unsupported ?? 'no native target'}).',
      );
    }
    // Dispatch-time revalidation: the dialog must still be the one decided.
    final fresh = await probe(force: true);
    final dialog = _dialog;
    final unreadable = fresh['present'] == null;
    if (fresh['present'] != true || dialog == null) {
      return refused(
        code: unreadable
            ? 'system_dialog_probe_unavailable'
            : 'system_dialog_gone',
        message: unreadable
            ? 'the dialog could not be read again before pressing '
                  '(${fresh['reason']}).'
            : 'the observed dialog is no longer shown.',
        facts: fresh,
      );
    }
    if (decided is! Map || decided['fingerprint'] != dialog.fingerprint) {
      return refused(
        code: 'system_dialog_changed',
        message:
            'the dialog on screen differs from the one decided on; observe '
            'and decide again.',
        facts: fresh,
      );
    }
    final refusal = systemTapRefusal(dialog, handle, dialogOwner: owner);
    if (refusal != null) {
      return refused(
        code: refusal.code,
        message: refusal.message,
        facts: fresh,
      );
    }
    final button = dialog.button(handle)!;
    final point = button.tapPoint;
    final android = device.kind == _NativeMobilePlatform.androidEmulator;
    final executable = android ? 'adb' : _axeExecutable;
    final arguments = android
        ? [
            '-s',
            device.id,
            'shell',
            'input',
            'tap',
            '${point.x.round()}',
            '${point.y.round()}',
          ]
        : [
            '--output',
            'json',
            'tap',
            '-x',
            point.x.toStringAsFixed(1),
            '-y',
            point.y.toStringAsFixed(1),
            '--udid',
            device.id,
          ];
    final started = _clock.elapsedMilliseconds;
    final result = await cli._runBoundedNativeProcess(
      executable,
      arguments,
      timeout: _systemDialogToolTimeout,
      maxStdoutBytes: _maxNativeToolTextBytes,
      maxStderrBytes: _maxNativeToolTextBytes,
    );
    final tapped = {
      'handle': handle,
      'label': button.label,
      if (button.resourceId != null) 'resourceId': button.resourceId,
      'dialogTitle': dialog.title,
      'dialogOwner': dialog.ownerName,
      'point': {'x': point.x, 'y': point.y},
      'coordinateUnits': android ? 'physical_pixels' : 'logical_points',
      'mechanism': android ? 'adb_input_tap' : 'axe_tap',
      'elapsedMs': _clock.elapsedMilliseconds - started,
    };
    if (!result.started) {
      return refused(
        code: 'system_dialog_tool_unavailable',
        message: '`$executable` could not be started.',
        facts: {'installHint': android ? null : _axeInstallHint},
      );
    }
    if (result.timedOut || result.exitCode != 0) {
      // The tool may have sent the touch before failing: never guess.
      return {
        'ok': false,
        'dispatch': 'dispatch_outcome_unknown',
        'error': {
          'code': 'system_tap_outcome_unknown',
          'message':
              '`$executable` ${result.timedOut ? 'timed out' : 'exited ${result.exitCode}'} '
              'while pressing $handle; the touch may or may not have been '
              'sent. Check the screen; nothing is retried.',
          'toolOutput': _firstLine(
            result.stdoutText +
                utf8.decode(result.stderrBytes, allowMalformed: true),
          ),
        },
        'systemTap': tapped,
        'businessCompletion': 'not_asserted',
      };
    }
    // Bounded postcondition observation, never a retry: up to ~3 s for the
    // dialog to go away or change.
    var after = fresh;
    for (var attempt = 0; attempt < 6; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      after = await probe(force: true);
      if (after['present'] != true ||
          after['fingerprint'] != dialog.fingerprint) {
        break;
      }
    }
    final outcome = after['present'] == false
        ? 'dismissed'
        : after['present'] == null
        ? 'unknown'
        : after['fingerprint'] == dialog.fingerprint
        ? 'still_present'
        : 'replaced';
    return {
      'ok': true,
      'dispatch': 'dispatched',
      'result': outcome == 'still_present' ? 'unchanged' : 'changed',
      'systemTap': tapped,
      'dialogAfter': outcome,
      if (after['present'] != false) 'systemDialogAfter': after,
      'businessCompletion': 'not_asserted',
    };
  }
}

class _SystemDialogProbeUnavailable implements Exception {
  _SystemDialogProbeUnavailable(this.reason, {this.installHint});
  final String reason;
  final String? installHint;
}

String _firstLine(String text) {
  final line = text.trim().split('\n').first.trim();
  return line.length > 200 ? '${line.substring(0, 200)}…' : line;
}

/// Validates a `system-tap` action: one `sys.*` handle, optional
/// `params.dialogOwner`, nothing else.
void _validateSystemTapAction(Map<String, dynamic> action) {
  final args = action['args'];
  if (args is! List ||
      args.length != 1 ||
      args.single is! String ||
      !RegExp(r'^sys\.[a-z0-9_]{1,48}$').hasMatch(args.single as String)) {
    throw const FormatException(
      "system-tap takes exactly one observed button handle in args, such as "
      "['sys.allow'], from scene.view.systemDialog.buttons.",
    );
  }
  final params = action['params'];
  if (params != null &&
      (params is! Map ||
          params.keys.any((key) => key != 'dialogOwner') ||
          (params['dialogOwner'] != null &&
              (params['dialogOwner'] is! String ||
                  (params['dialogOwner'] as String).isEmpty ||
                  (params['dialogOwner'] as String).length > 128)))) {
    throw const FormatException(
      'system-tap accepts only params.dialogOwner (the observed '
      'owner.name, or "unknown"), for a dialog of another app.',
    );
  }
  if (action.containsKey('allowUnrelatedChanges')) {
    throw const FormatException(
      'system-tap does not take allowUnrelatedChanges; it presses only a '
      'button of the unchanged observed dialog.',
    );
  }
}

extension _CliSystemDialog on FlutterScoutCli {
  /// Runs one read-only probe tool; a missing tool or failure is
  /// `probe_unavailable`, never a guess.
  Future<String> _systemDialogTool(
    String executable,
    List<String> args,
    String name,
  ) async {
    final result = await _runBoundedNativeProcess(
      executable,
      args,
      timeout: _systemDialogToolTimeout,
      maxStdoutBytes: _maxSystemDialogToolBytes,
      maxStderrBytes: _maxNativeToolTextBytes,
    );
    if (!result.started) {
      throw _SystemDialogProbeUnavailable(
        name == 'axe'
            ? 'AXe is not installed (needed to read iOS Simulator system '
                  'dialogs)'
            : '`$executable` could not be started',
        installHint: name == 'axe' ? _axeInstallHint : null,
      );
    }
    if (result.timedOut || result.outputExceeded || result.exitCode != 0) {
      throw _SystemDialogProbeUnavailable(
        '`$name ${args.where((a) => !a.contains(' ')).take(3).join(' ')}` '
        '${result.timedOut
            ? 'timed out'
            : result.outputExceeded
            ? 'returned too much output'
            : 'exited ${result.exitCode}: ${_firstLine(utf8.decode(result.stderrBytes, allowMalformed: true) + result.stdoutText)}'}',
      );
    }
    return result.stdoutText;
  }

  /// The iOS Simulator app whose host process is [pid]: bundle id and the
  /// names its prompts quote, from the running bundle's Info.plist.
  Future<SystemDialogApp?> _iosAppForPid(int pid) async {
    final ps = await _runBoundedNativeProcess(
      '/bin/ps',
      ['-o', 'comm=', '-p', '$pid'],
      timeout: _nativePreflightTimeout,
      maxStdoutBytes: _maxNativeToolTextBytes,
      maxStderrBytes: _maxNativeToolTextBytes,
    );
    final command = ps.stdoutText.trim();
    final end = command.indexOf('.app/');
    if (ps.exitCode != 0 || end < 0) return null;
    final plist = p.join(command.substring(0, end + 4), 'Info.plist');
    final converted = await _runBoundedNativeProcess(
      '/usr/bin/plutil',
      ['-convert', 'json', '-o', '-', plist],
      timeout: _nativePreflightTimeout,
      maxStdoutBytes: _maxSystemDialogToolBytes,
      maxStderrBytes: _maxNativeToolTextBytes,
    );
    if (converted.exitCode != 0) return null;
    try {
      final info = jsonDecode(converted.stdoutText);
      final id = info is Map ? info['CFBundleIdentifier'] : null;
      if (id is! String || id.isEmpty) return null;
      return SystemDialogApp(
        id: id,
        names: {
          for (final key in const ['CFBundleDisplayName', 'CFBundleName'])
            if (info[key] is String && (info[key] as String).isNotEmpty)
              info[key] as String,
        }.toList(),
      );
    } on FormatException {
      return null;
    }
  }

  /// The Android package running as device process [pid].
  Future<SystemDialogApp?> _androidAppForPid(
    _NativeMobileTarget device,
    int pid,
  ) async {
    final result = await _runBoundedNativeProcess(
      'adb',
      ['-s', device.id, 'shell', 'cat', '/proc/$pid/cmdline'],
      timeout: _nativePreflightTimeout,
      maxStdoutBytes: _maxNativeToolTextBytes,
      maxStderrBytes: _maxNativeToolTextBytes,
    );
    final name = result.stdoutText
        .split('\u0000')
        .first
        .split(':')
        .first
        .trim();
    if (result.exitCode != 0 ||
        !RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$').hasMatch(name)) {
      return null;
    }
    return SystemDialogApp(id: name);
  }

  /// The VM's OS process id (a host pid on the iOS Simulator, a device pid
  /// on Android), over the cached or a short-lived connection.
  Future<int?> _sessionAppVmPid() async {
    final cached = _cachedVmService;
    if (cached != null) {
      try {
        return (await cached.getVM().timeout(const Duration(seconds: 5))).pid;
      } catch (_) {
        return null;
      }
    }
    final uri = _readVmUri();
    if (uri == null) return null;
    VmService? service;
    try {
      service = await _connect(uri).timeout(const Duration(seconds: 5));
      return (await service.getVM().timeout(const Duration(seconds: 5))).pid;
    } catch (_) {
      return null;
    } finally {
      await service?.dispose();
    }
  }

  /// `systemDialogs` for doctor: which mechanism this session's device uses
  /// and whether it is installed. Null for sessions without one.
  Future<Map<String, Object?>?> _systemDialogDoctor() async {
    final probe = _SystemDialogProbe(this, vmPid: () async => null);
    final device = probe.target;
    if (device == null) {
      final platform = _readDeviceInfo()?['platform']?.toString() ?? '';
      if (!platform.contains('ios') && !platform.contains('android')) {
        return null;
      }
      return {
        'supported': false,
        'reason': probe._unsupported,
        'note':
            'Only the iOS Simulator and Android emulators are probed. On a '
            'physical iPhone no host tool can press SpringBoard alerts '
            'without an XCUITest runner: ask the user, or set permissions in '
            'Settings before the run.',
      };
    }
    if (device.kind == _NativeMobilePlatform.androidEmulator) {
      return {
        'supported': true,
        'backend': 'adb_uiautomator',
        'available': true,
        'permissions': 'flutter-scout --app <name> permissions grant <service>',
      };
    }
    final version = await _runBoundedNativeProcess(
      _axeExecutable,
      ['--version'],
      timeout: _nativePreflightTimeout,
      maxStdoutBytes: _maxNativeToolTextBytes,
      maxStderrBytes: _maxNativeToolTextBytes,
    );
    final available = version.started && version.exitCode == 0;
    return {
      'supported': true,
      'backend': 'axe_accessibility',
      'available': available,
      'executable': _axeExecutable,
      if (available) 'version': version.stdoutText.trim(),
      if (!available) ...{
        'installHint': _axeInstallHint,
        'note':
            'Without AXe, Scout cannot see or answer iOS Simulator system '
            'dialogs; pre-grant with `permissions grant` where simctl '
            'supports the service, or ask the user.',
      },
      'permissions': 'flutter-scout --app <name> permissions grant <service>',
    };
  }
}
