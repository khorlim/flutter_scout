part of 'flutter_scout_cli.dart';

// part: opt-in headless drive. The launch/ensure/attach flag and environment
// variable, the session record the agent reads, status/doctor host power
// facts, and the rule that a hidden or locked app is never captured with the
// macOS screenshot tool.

const String _headlessDriveEnvironment = 'FLUTTER_SCOUT_HEADLESS_DRIVE';

String get _headlessDriveFile =>
    p.join(_sessionDir.path, 'headless_drive.json');

bool _headlessDriveEnvRequested() => const {'1', 'true', 'yes'}.contains(
  Platform.environment[_headlessDriveEnvironment]?.trim().toLowerCase(),
);

void _addHeadlessDriveFlag(ArgParser parser) => parser.addFlag(
  'headless-drive',
  defaultsTo: false,
  negatable: false,
  help:
      'Debug apps only: keep driving the app while its window is hidden, '
      'covered, the display sleeps or the screen is locked (Scout advances '
      'its frames). Also enabled by $_headlessDriveEnvironment=1. Costs CPU '
      'and battery; nobody sees the app the agent acts on.',
);

extension _CliHeadless on FlutterScoutCli {
  /// Records this session's choice from `--headless-drive` or the
  /// environment. The latest launch, ensure or attach decides; an agent
  /// already connected keeps the choice it connected with.
  Map<String, Object?> _recordHeadlessDrive(ArgResults parsed) {
    final flag = parsed.flag('headless-drive');
    if (!flag && !_headlessDriveEnvRequested()) {
      _deleteFileIfExists(_headlessDriveFile);
    } else {
      _writePrivateSessionJson(_headlessDriveFile, <String, Object?>{
        'enabled': true,
        'source': flag ? 'flag' : 'environment',
        'setAt': DateTime.now().toUtc().toIso8601String(),
      });
    }
    return _headlessDriveReport();
  }

  Map<String, dynamic>? _readHeadlessDrive() {
    final file = File(_headlessDriveFile);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  bool get _sessionHeadlessDrive => _readHeadlessDrive()?['enabled'] == true;

  /// The session's headless-drive setting, and when [rendering] is known,
  /// whether the app is hidden right now.
  Map<String, Object?> _headlessDriveReport({Map<String, dynamic>? rendering}) {
    final record = _readHeadlessDrive();
    if (record?['enabled'] != true) {
      return const <String, Object?>{
        'enabled': false,
        'notice':
            'Headless drive is off: a hidden, covered, asleep or locked app '
            'stops rendering and Scout refuses input.',
      };
    }
    final drive = rendering?['headlessDrive'] as Map?;
    final host = rendering?['host'] as Map?;
    // `active` is the helper's combined verdict (Flutter lifecycle and what
    // macOS reports); frames alone do not prove anyone can see the window.
    final hidden = rendering == null
        ? null
        : rendering['status'] != 'active' ||
              rendering['framesEnabled'] != true ||
              host?['hidden'] == true;
    return <String, Object?>{
      'enabled': true,
      'source': record!['source'],
      'setAt': record['setAt'],
      if (hidden != null) 'appVisible': !hidden,
      if (hidden == true) 'lifecycle': rendering!['lifecycle'],
      if (drive?['reason'] != null || host?['hiddenReason'] != null)
        'reason': drive?['reason'] ?? host!['hiddenReason'],
      'notice': hidden == true
          ? 'HEADLESS: the app is not visible (lifecycle '
                '${rendering!['lifecycle']}${(drive?['reason'] ?? host?['hiddenReason']) == null ? '' : ', ${drive?['reason'] ?? host!['hiddenReason']}'}); '
                'an attached Scout agent drives its frames and keeps acting '
                'on it. Nobody can see this app.'
          : 'Headless drive is on: if the window is hidden or covered, the '
                'display sleeps or the screen locks, an attached agent keeps '
                'driving the app. System sleep still suspends it. Reconnect '
                'the agent after changing this setting.',
    };
  }

  /// Rendering facts from one brief inspect; the first response also
  /// proves whether the helper accepts `headlessDrive`. Null when the app
  /// cannot be observed.
  Future<Map<String, dynamic>?> _headlessRenderingProbe() async {
    Future<Map<String, dynamic>?> probe() async {
      final raw = await _call('ext.flutter_scout.inspect', const {
        'brief': 'true',
        'maxItems': '1',
      }, const Duration(seconds: 5));
      if (raw['ok'] != true) return null;
      final rendering = _observationPayload(raw)['rendering'];
      return rendering is Map ? Map<String, dynamic>.from(rendering) : null;
    }

    try {
      final sent = _sendHeadlessDrive;
      final rendering = await probe();
      // Re-read with the flag so the helper names lock or display sleep.
      if (!sent && _sendHeadlessDrive && rendering?['framesEnabled'] != true) {
        return await probe();
      }
      return rendering;
    } catch (_) {
      return null;
    }
  }

  /// Screenshots and crops of a headless-drive session use the in-app
  /// capture, and the capture itself carries `headlessDrive` so the helper
  /// advances a frame before rasterizing a hidden app.
  Future<void> _prepareHeadlessCapture() async {
    if (!_sessionHeadlessDrive) return;
    _headlessDrive = true;
    if (!_helperHeadlessDriveV1) await _headlessRenderingProbe();
  }

  /// `screencapture` cannot capture a hidden window or a locked screen, so a
  /// headless-drive session never calls it unless the app is visibly
  /// rendering; a forced `--native` gets this error instead.
  Future<void> _refuseNativeCaptureWhileHeadless() async {
    if (!_sessionHeadlessDrive) return;
    _headlessDrive = true;
    _refuseNativeCaptureFor(await _headlessRenderingProbe());
  }

  /// Throws unless [rendering] proves the app visibly renders on its own.
  /// Null [rendering] means Scout could not observe the app: fail closed.
  void _refuseNativeCaptureFor(Map<String, dynamic>? rendering) {
    final reason =
        (rendering?['headlessDrive'] as Map?)?['reason'] ??
        (rendering?['host'] as Map?)?['hiddenReason'];
    if (rendering?['status'] == 'active' &&
        rendering?['framesEnabled'] == true &&
        reason == null) {
      return;
    }
    final cause = rendering == null
        ? 'Scout could not confirm that the app is visible'
        : 'the app is not visible (lifecycle ${rendering['lifecycle']}'
              '${reason == null ? '' : ', $reason'})';
    throw ScoutCliException(
      'native_capture_unavailable_headless',
      'Headless drive is on and $cause, so Scout did not run the macOS '
          'screenshot tool (screencapture cannot capture a hidden window or '
          'a locked screen). Omit --native to use the in-app capture; content '
          'inside a platform view needs the app visible again.',
      details: <String, Object?>{
        'capability': 'native_screenshot',
        'dispatch': 'not_applicable_read_only',
        'headlessDrive': true,
        'lifecycle': ?rendering?['lifecycle'],
        'framesEnabled': ?rendering?['framesEnabled'],
        'reason': ?reason,
      },
    );
  }

  /// What would stop a normal (visible-window) run on this Mac, read from
  /// `pmset`, `sysadminctl` and `ioreg` without changing anything. Null off
  /// macOS.
  Future<Map<String, Object?>?> _hostPowerFacts() async {
    if (!Platform.isMacOS) return null;
    Future<String?> run(
      String executable,
      List<String> arguments, {
      bool stderr = false,
    }) async {
      final result = await _runBoundedNativeProcess(
        executable,
        arguments,
        timeout: const Duration(seconds: 3),
        maxStdoutBytes: 256 * 1024,
        maxStderrBytes: 16 * 1024,
      );
      if (!result.started || result.timedOut) return null;
      return stderr
          ? utf8.decode(result.stderrBytes, allowMalformed: true)
          : result.stdoutText;
    }

    final settings = await run('/usr/bin/pmset', const ['-g']) ?? '';
    final assertions =
        await run('/usr/bin/pmset', const ['-g', 'assertions']) ?? '';
    final lock = await run('/usr/sbin/sysadminctl', const [
      '-screenLock',
      'status',
    ], stderr: true);
    final clamshell = await run('/usr/sbin/ioreg', const [
      '-r',
      '-k',
      'AppleClamshellState',
      '-d',
      '1',
    ]);
    int? minutes(String key) => int.tryParse(
      RegExp(
            '^\\s*$key\\s+(\\d+)',
            multiLine: true,
          ).firstMatch(settings)?.group(1) ??
          '',
    );
    int assertionCount(String key) =>
        int.tryParse(
          RegExp(
                '^\\s*$key\\s+(\\d+)',
                multiLine: true,
              ).firstMatch(assertions)?.group(1) ??
              '',
        ) ??
        0;
    final displaySleep = minutes('displaysleep');
    final systemSleep = minutes('sleep');
    final preventedBy = <String>{
      for (final name
          in (RegExp(
                    r'^\s*sleep\s+\d+\s*\(sleep prevented by ([^)]*)\)',
                    multiLine: true,
                  ).firstMatch(settings)?.group(1) ??
                  '')
              .split(','))
        if (name.trim().isNotEmpty) name.trim(),
    }.toList();
    final idleSleepPrevented =
        assertionCount('PreventUserIdleSystemSleep') > 0 ||
        assertionCount('PreventSystemSleep') > 0;
    final lockDelay = lock == null
        ? null
        : RegExp(r'screenLock delay is ([^\n]+)').firstMatch(lock)?.group(1) ??
              (RegExp(r'screenLock is off').hasMatch(lock) ? 'off' : null);
    final lidSleeps = clamshell == null
        ? null
        : RegExp(
                r'"AppleClamshellCausesSleep" = (Yes|No)',
              ).firstMatch(clamshell)?.group(1) ==
              'Yes';
    final now = _macHostVisibilityNow(
      await _macHostVisibilityRaw(),
      screenLockDelay: lockDelay,
    );
    final displayDetail = displaySleep == null
        ? 'unknown'
        : displaySleep == 0
        ? 'display sleep is off'
        : 'the display sleeps after $displaySleep min idle';
    return <String, Object?>{
      // Live, read when this command ran; the rest are configured settings.
      'now': now,
      'displaySleepMinutes': displaySleep,
      'systemSleepMinutes': systemSleep,
      'idleSystemSleepPreventedNow': idleSleepPrevented,
      if (preventedBy.isNotEmpty) 'systemSleepPreventedBy': preventedBy,
      'screenLockDelay': lockDelay,
      'lidCloseSleeps': lidSleeps,
      // What stops agent input on a normal run, with a visible window.
      'normalRunStoppedBy': <String, Object?>{
        'hiddenOrCoveredWindow':
            'yes: a minimized, hidden, fully covered or other-Space window '
            'stops rendering',
        'displaySleep': displaySleep == 0
            ? 'no ($displayDetail)'
            : 'yes: $displayDetail',
        'screenLock': lockDelay == null
            ? 'yes when locked (lock delay unknown)'
            : lockDelay == 'off'
            ? 'yes when locked by hand (no automatic lock after sleep)'
            : lockDelay == 'immediate'
            ? 'yes: the screen locks as soon as the display sleeps'
            : 'yes: the screen locks $lockDelay after the display sleeps',
        'systemSleep': idleSleepPrevented
            ? 'not now: idle system sleep is prevented'
                  '${preventedBy.isEmpty ? '' : ' by ${preventedBy.join(', ')}'}'
                  ' (ends when that process releases it)'
            : systemSleep == null || systemSleep == 0
            ? 'no idle system sleep is configured'
            : 'yes: the Mac sleeps after $systemSleep min idle and suspends '
                  'the app and Scout',
        if (lidSleeps != null)
          'lidClose': lidSleeps
              ? 'yes: closing the lid sleeps the Mac'
              : 'no: the lid does not cause sleep now',
      },
      'headlessDriveCovers':
          'a hidden or covered window, display sleep and screen lock. Not '
          'system sleep or a closed lid: keep the Mac awake for long runs, '
          'for example `caffeinate -i -w <app pid>`.',
    };
  }
}

extension _CliMacHostVisibility on FlutterScoutCli {
  /// Raw live facts from CoreGraphics and AppKit through JavaScript for
  /// Automation, so status and doctor report them without the app. Null
  /// when they could not be read.
  Future<Map<String, dynamic>?> _macHostVisibilityRaw() async {
    const script = r'''
ObjC.import('CoreGraphics');
ObjC.import('AppKit');
function run() {
  var out = {};
  try {
    var d = $.CGSessionCopyCurrentDictionary();
    var o = d ? ObjC.deepUnwrap(ObjC.castRefToObject(d)) : null;
    if (o) {
      var l = o.CGSSessionScreenIsLocked;
      out.sessionLockFlag = l === true || l === 1;
      var c = o.kCGSSessionOnConsoleKey;
      out.onConsole = !(c === false || c === 0);
    }
  } catch (e) {}
  try {
    var ids = [$.CGMainDisplayID()];
    var screens = $.NSScreen.screens;
    for (var i = 0; i < screens.count; i++) {
      var n = ObjC.unwrap(screens.objectAtIndex(i).deviceDescription.objectForKey('NSScreenNumber'));
      if (ids.indexOf(n) < 0) ids.push(n);
    }
    out.displayAsleep = ids.every(function (id) { return $.CGDisplayIsAsleep(id) !== 0; });
  } catch (e) {}
  try {
    var app = $.NSWorkspace.sharedWorkspace.frontmostApplication;
    out.loginWindowFrontmost = !!app && !app.isNil() &&
      ObjC.unwrap(app.bundleIdentifier) === 'com.apple.loginwindow';
  } catch (e) {}
  return JSON.stringify(out);
}
''';
    final result = await _runBoundedNativeProcess(
      '/usr/bin/osascript',
      const ['-l', 'JavaScript', '-e', script],
      timeout: const Duration(seconds: 3),
      maxStdoutBytes: 4096,
      maxStderrBytes: 4096,
    );
    if (!result.started || result.timedOut || result.exitCode != 0) {
      return null;
    }
    try {
      final decoded = jsonDecode(result.stdoutText);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }
}

/// Whether macOS hides apps right now, from raw facts ([raw] null: not
/// readable). The same rules as the helper's `rendering.host`: macOS sets
/// its session lock flag the moment the display sleeps, also inside the
/// password grace period, so the flag alone never means locked. Locked is
/// the login window in front of an awake display, or a sleeping display
/// with the flag set when the lock applies immediately.
Map<String, Object?> _macHostVisibilityNow(
  Map<String, dynamic>? raw, {
  String? screenLockDelay,
}) {
  bool? fact(String key) => raw?[key] is bool ? raw![key] as bool : null;
  final asleep = fact('displayAsleep');
  final flag = fact('sessionLockFlag');
  final loginWindow = fact('loginWindowFrontmost');
  final onConsole = fact('onConsole');
  final bool? locked;
  if (asleep != true && loginWindow == true) {
    locked = true;
  } else if (flag == false) {
    locked = false;
  } else if (asleep == true && flag == true && screenLockDelay == 'immediate') {
    locked = true;
  } else {
    locked = null;
  }
  final hiddenReason = asleep == true
      ? 'display_asleep'
      : locked == true
      ? 'screen_locked'
      : onConsole == false
      ? 'session_inactive'
      : null;
  return <String, Object?>{
    'observedAt': DateTime.now().toUtc().toIso8601String(),
    'displayAsleep': asleep,
    'screenLocked': locked,
    'sessionLockFlag': flag,
    'loginWindowFrontmost': loginWindow,
    'onConsole': onConsole,
    'appsHidden': hiddenReason != null,
    'hiddenReason': ?hiddenReason,
    if (flag == true && locked == null)
      'screenLockNote':
          'macOS sets its lock flag as soon as the display sleeps, also '
          'inside the ${screenLockDelay ?? 'unknown'} password grace period; '
          'the lock is in force once the login window shows.',
  };
}

/// Deterministic probes for headless-drive decisions without a running app.
extension HeadlessDriveDebug on FlutterScoutCli {
  /// The native-capture rule for a headless-drive session, given the
  /// helper's rendering facts (null: the app could not be observed).
  void debugRefuseNativeCaptureFor(Map<String, dynamic>? rendering) =>
      _refuseNativeCaptureFor(rendering);

  /// The live display-sleep and lock classification status/doctor report
  /// under `hostPower.now`, from raw macOS facts.
  Map<String, Object?> debugMacHostVisibilityNow(
    Map<String, dynamic>? raw, {
    String? screenLockDelay,
  }) => _macHostVisibilityNow(raw, screenLockDelay: screenLockDelay);

  /// Host power facts, read through [FlutterScoutCli.debugNativeProcessRunner]
  /// when it is set.
  Future<Map<String, Object?>?> debugHostPowerFacts() => _hostPowerFacts();
}
