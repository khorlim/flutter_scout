part of 'flutter_scout_cli.dart';

// part: launch-wait diagnostics. Distinguishes a silent-but-busy build from a
// stalled one, tolerates transient supervisor probe failures, and classifies a
// failed launch from the runner log so agents see the cause without logs.txt.

/// How long a supervisor probe may keep failing before the launch gives up.
const Duration _runnerProbeGrace = Duration(seconds: 30);

/// Silence after which the launch starts sampling the runner's CPU time.
const Duration _silentBuildSampleAfter = Duration(seconds: 30);
const Duration _silentBuildSampleInterval = Duration(seconds: 15);

/// CPU seconds the runner tree must use between samples to count as busy.
const double _silentBuildBusyCpuSeconds = 1.0;

/// Parses `ps -o time=` values: `[[dd-]hh:]mm:ss[.cc]`.
double? _parsePsCpuTime(String value) {
  final match = RegExp(
    r'^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  final days = int.parse(match.group(1) ?? '0');
  final hours = int.parse(match.group(2) ?? '0');
  final minutes = int.parse(match.group(3)!);
  final seconds = double.parse(match.group(4)!);
  return ((days * 24 + hours) * 60 + minutes) * 60 + seconds;
}

/// Sums CPU seconds of [rootPid] and all its descendants from `ps -ax` rows of
/// `pid ppid time`.
double? _processTreeCpuSecondsFromPs(String psOutput, int rootPid) {
  final children = <int, List<int>>{};
  final cpu = <int, double>{};
  for (final line in psOutput.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length != 3) continue;
    final pid = int.tryParse(parts[0]);
    final ppid = int.tryParse(parts[1]);
    final time = _parsePsCpuTime(parts[2]);
    if (pid == null || ppid == null || time == null) continue;
    cpu[pid] = time;
    children.putIfAbsent(ppid, () => <int>[]).add(pid);
  }
  if (!cpu.containsKey(rootPid)) return null;
  var total = 0.0;
  final queue = <int>[rootPid];
  final seen = <int>{};
  while (queue.isNotEmpty) {
    final pid = queue.removeLast();
    if (!seen.add(pid)) continue;
    total += cpu[pid] ?? 0;
    queue.addAll(children[pid] ?? const <int>[]);
  }
  return total;
}

/// A classified launch failure: a stable cause, the log line that shows it,
/// and the next step for the agent.
class _LaunchFailureCause {
  const _LaunchFailureCause(this.cause, this.evidence, this.hint);

  final String cause;
  final String evidence;
  final String hint;

  Map<String, Object?> toJson() => {
    'cause': cause,
    'evidence': evidence,
    'hint': hint,
  };
}

_LaunchFailureCause? _classifyLaunchFailure(List<String> lines) {
  final rules = <(String, RegExp, String)>[
    (
      'macos_app_launch_failed',
      RegExp(r'\[flutter_scout\] (macos_app_[a-z_]+): '),
      'The app built but could not be opened or attached; see evidence.',
    ),
    (
      'device_unavailable',
      RegExp(
        r'No (?:supported )?devices? found (?:with name or id )?matching|'
        r'Unable to locate a development device|is not connected',
        caseSensitive: false,
      ),
      'Boot the simulator or emulator first (for example '
          '`xcrun simctl boot <udid>`), then confirm it in '
          '`flutter-scout devices`.',
    ),
    (
      'install_failed_insufficient_storage',
      RegExp(r'INSUFFICIENT_STORAGE|not enough space', caseSensitive: false),
      'Free storage on the device (uninstall apps or wipe the emulator) or '
          'use another device.',
    ),
    (
      'dart_compile_failed',
      RegExp(r'\.dart:\d+:\d+: Error:'),
      'Fix the Dart compile error, then launch again.',
    ),
    (
      'cocoapods_failed',
      RegExp(
        r'sandbox is not in sync with the Podfile\.lock|Error running pod install|CocoaPods',
        caseSensitive: false,
      ),
      'Run `pod install` in the ios/ or macos/ folder (check that another '
          'process is not rewriting Podfile.lock), then launch again.',
    ),
    (
      'gradle_build_failed',
      RegExp(r'FAILURE: Build failed with an exception|Gradle task \S+ failed'),
      'Fix the Gradle error shown in the evidence and launch again.',
    ),
    (
      'native_build_failed',
      RegExp(
        r'\*\* BUILD FAILED \*\*|Error \(Xcode\)|Could not build the application|'
        r'Error building|Error launching application',
      ),
      'Fix the native build error shown in the evidence and launch again.',
    ),
    (
      'app_exited_during_launch',
      RegExp(r'Lost connection to device|Application finished\.'),
      'The app exited before Scout connected; check the app log for a crash.',
    ),
  ];
  for (final (cause, pattern, hint) in rules) {
    for (final line in lines.reversed) {
      final match = pattern.firstMatch(line);
      if (match == null) continue;
      var evidence = _redactSensitiveLogText(_stripLogMetadata(line));
      if (evidence.length > 300) evidence = '${evidence.substring(0, 297)}...';
      return _LaunchFailureCause(
        cause == 'macos_app_launch_failed' ? match.group(1)! : cause,
        evidence,
        hint,
      );
    }
  }
  return null;
}

/// The message for a launch that never reported a VM service. It always
/// names what ended the wait and the option that changes it.
String _launchFailureMessage({
  required String failureMode,
  required _LaunchFailureCause? cause,
  required Duration launchTimeout,
  required Duration launchIdleTimeout,
  required DateTime? lastOutputAt,
  required String? lastOutputLine,
}) {
  if (cause != null) {
    return 'Launch failed (${cause.cause}): ${cause.evidence} ${cause.hint}';
  }
  final last = lastOutputAt == null
      ? 'no runner output was recorded'
      : 'last output at ${lastOutputAt.toUtc().toIso8601String()}'
            '${lastOutputLine == null ? '' : ': "$lastOutputLine"'}';
  return switch (failureMode) {
    'idle_timeout' =>
      'Scout stopped the launch after ${launchIdleTimeout.inSeconds}s with no '
          'runner output and no build CPU activity ($last). If this build is '
          'legitimately silent, rerun with --launch-idle-timeout <seconds>.',
    'hard_timeout' =>
      'Scout stopped the launch at --launch-timeout '
          '${launchTimeout.inSeconds}s while the runner was still active '
          '($last). Rerun with a larger --launch-timeout if the build is '
          'progressing.',
    'runner_probe_failed' =>
      'Scout could not confirm its runner process for '
          '${_runnerProbeGrace.inSeconds}s although it may still be alive '
          '($last). The machine may be overloaded; check `ps` and rerun.',
    _ =>
      'The Scout runner exited before the app reported a VM service '
          '($last). See tailLogLines.',
  };
}

extension _CliLaunchDiagnostics on FlutterScoutCli {
  Future<double?> _processTreeCpuSeconds(int rootPid) async {
    try {
      final result = await Process.run('ps', [
        '-ax',
        '-o',
        'pid=,ppid=,time=',
      ]).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) return null;
      return _processTreeCpuSecondsFromPs('${result.stdout}', rootPid);
    } catch (_) {
      return null;
    }
  }

  /// Fails fast for a shut-down iOS Simulator instead of waiting for Flutter
  /// to report that no device matched.
  Future<void> _requireBootedSimulator(String device) async {
    if (!Platform.isMacOS ||
        !RegExp(
          r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
        ).hasMatch(device)) {
      return;
    }
    ProcessResult result;
    try {
      result = await Process.run('xcrun', [
        'simctl',
        'list',
        'devices',
        '-j',
      ]).timeout(const Duration(seconds: 10));
    } catch (_) {
      return;
    }
    if (result.exitCode != 0) return;
    final state = _simulatorState('${result.stdout}', device);
    if (state == null || state == 'Booted') return;
    throw ScoutCliException(
      'device_not_booted',
      'iOS Simulator $device is $state. Boot it with `xcrun simctl boot '
          '$device` (and `open -a Simulator`), then rerun.',
      details: {'device': device, 'state': state},
    );
  }
}

String? _simulatorState(String simctlJson, String udid) {
  try {
    final decoded = jsonDecode(simctlJson);
    final runtimes = decoded is Map ? decoded['devices'] : null;
    if (runtimes is! Map) return null;
    for (final devices in runtimes.values) {
      if (devices is! List) continue;
      for (final device in devices) {
        if (device is Map &&
            '${device['udid']}'.toUpperCase() == udid.toUpperCase()) {
          return device['state']?.toString();
        }
      }
    }
  } catch (_) {}
  return null;
}

extension FlutterScoutCliLaunchDiagnosticsTesting on FlutterScoutCli {
  double? debugParsePsCpuTime(String value) => _parsePsCpuTime(value);

  double? debugProcessTreeCpuSeconds(String psOutput, int rootPid) =>
      _processTreeCpuSecondsFromPs(psOutput, rootPid);

  Map<String, Object?>? debugClassifyLaunchFailure(List<String> lines) =>
      _classifyLaunchFailure(lines)?.toJson();

  String? debugSimulatorState(String simctlJson, String udid) =>
      _simulatorState(simctlJson, udid);
}
