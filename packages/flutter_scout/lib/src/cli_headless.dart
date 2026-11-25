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
    final hidden = rendering == null
        ? null
        : rendering['framesEnabled'] != true;
    return <String, Object?>{
      'enabled': true,
      'source': record!['source'],
      'setAt': record['setAt'],
      if (hidden != null) 'appVisible': !hidden,
      if (hidden == true) 'lifecycle': rendering!['lifecycle'],
      if (drive?['reason'] != null) 'reason': drive!['reason'],
      'notice': hidden == true
          ? 'HEADLESS: the app is not visible (lifecycle '
                '${rendering!['lifecycle']}${drive?['reason'] == null ? '' : ', ${drive!['reason']}'}); '
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
    final reason = (rendering?['headlessDrive'] as Map?)?['reason'];
    if (rendering?['framesEnabled'] == true && reason != 'screen_locked') {
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
    final displayDetail = displaySleep == null
        ? 'unknown'
        : displaySleep == 0
        ? 'display sleep is off'
        : 'the display sleeps after $displaySleep min idle';
    return <String, Object?>{
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

/// Deterministic probes for headless-drive decisions without a running app.
extension HeadlessDriveDebug on FlutterScoutCli {
  /// The native-capture rule for a headless-drive session, given the
  /// helper's rendering facts (null: the app could not be observed).
  void debugRefuseNativeCaptureFor(Map<String, dynamic>? rendering) =>
      _refuseNativeCaptureFor(rendering);

  /// Host power facts, read through [FlutterScoutCli.debugNativeProcessRunner]
  /// when it is set.
  Future<Map<String, Object?>?> debugHostPowerFacts() => _hostPowerFacts();
}
