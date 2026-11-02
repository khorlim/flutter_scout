part of 'flutter_scout_cli.dart';

// part: macOS app launch through LaunchServices so the app is its own TCC
// responsible process.
//
// `flutter run -d macos` executes the app binary as a child of the Flutter
// tool. macOS then attributes privacy requests (microphone, camera,
// Bluetooth) to the nearest responsibility root: Scout's launchd worker (a
// hardened `dart` without usage descriptions, so requests are denied without
// a prompt) or the inherited caller. The worker therefore builds with
// `flutter build macos --debug`, launches the bundle through `open -n` so
// launchd makes the app its own responsible process inside the user's GUI
// session, and then runs `flutter attach` for hot reload/restart signals.

const String _macosAppProcessRole = 'macos_app';
const String _macosDirectRunEnvironment = 'FLUTTER_SCOUT_MACOS_DIRECT_RUN';

bool _shouldLaunchMacosAppThroughLaunchServices({
  required bool isMacOS,
  required String deviceId,
  required Map<String, String> environment,
}) =>
    isMacOS &&
    deviceId == 'macos' &&
    environment[_macosDirectRunEnvironment] != '1';

/// Splits a Scout `flutter run` argument vector into the options that apply
/// to the build, the attach, and the engine switches of the launched app.
class _MacosLaunchPlan {
  _MacosLaunchPlan._({
    required this.buildArgs,
    required this.attachArgsBeforeUrl,
    required this.engineSwitches,
    required this.pidFile,
  });

  factory _MacosLaunchPlan.fromRunArgs(List<String> runArgs) {
    if (runArgs.isEmpty || runArgs.first != 'run') {
      throw const ScoutCliException(
        'invalid_worker_config',
        'The macOS launch plan requires a Flutter run argument vector.',
      );
    }
    final build = <String>['build', 'macos', '--debug'];
    final attach = <String>['attach', '-d', 'macos'];
    final engineSwitches = <String>[
      'enable-dart-profiling=true',
      'enable-checked-mode=true',
      'verify-entry-points=true',
    ];
    String? pidFile;
    for (var index = 1; index < runArgs.length; index++) {
      final argument = runArgs[index];
      String next() {
        if (index + 1 >= runArgs.length) {
          throw ScoutCliException(
            'invalid_worker_config',
            'The Flutter run option `$argument` has no value.',
          );
        }
        return runArgs[++index];
      }

      switch (argument) {
        case '-d':
        case '--device-id':
          next();
        case '--pid-file':
          pidFile = next();
        case '--enable-impeller':
          engineSwitches.add('enable-impeller=true');
        case '--no-enable-impeller':
          engineSwitches.add('enable-impeller=false');
        case '--no-pub':
          build.add(argument);
        case '--flavor':
          build.addAll([argument, next()]);
        case '--target':
        case '-t':
        case '--dart-define':
        case '--dart-define-from-file':
          final value = next();
          build.addAll([argument, value]);
          attach.addAll([argument, value]);
        case '--verbose':
        case '-v':
          build.add(argument);
          attach.add(argument);
        default:
          throw ScoutCliException(
            'invalid_worker_config',
            'The macOS launch plan does not support Flutter run option '
                '`$argument`.',
          );
      }
    }
    if (pidFile == null) {
      throw const ScoutCliException(
        'invalid_worker_config',
        'The macOS launch plan requires the Flutter tool signal PID file.',
      );
    }
    return _MacosLaunchPlan._(
      buildArgs: List.unmodifiable(build),
      attachArgsBeforeUrl: List.unmodifiable(attach),
      engineSwitches: List.unmodifiable(engineSwitches),
      pidFile: pidFile,
    );
  }

  final List<String> buildArgs;
  final List<String> attachArgsBeforeUrl;
  final List<String> engineSwitches;
  final String pidFile;

  List<String> attachArgs(String vmServiceUri) => [
    ...attachArgsBeforeUrl,
    '--debug-url',
    vmServiceUri,
    '--pid-file',
    pidFile,
  ];

  /// `open --env` arguments matching what `flutter run` passes to a desktop
  /// debug app through FLUTTER_ENGINE_SWITCHES.
  List<String> openEnvironmentArgs() => [
    '--env',
    'FLUTTER_ENGINE_SWITCHES=${engineSwitches.length}',
    for (var index = 0; index < engineSwitches.length; index++) ...[
      '--env',
      'FLUTTER_ENGINE_SWITCH_${index + 1}=${engineSwitches[index]}',
    ],
  ];
}

final RegExp _builtMacosAppPattern = RegExp(r'Built (\S.*\.app)\s*(?:\(|$)');

/// Returns the absolute app bundle path from Flutter's `✓ Built …app` line.
String? _builtMacosAppPath(String line, {required String project}) {
  final match = _builtMacosAppPattern.firstMatch(_stripLogAnsi(line).trim());
  final relative = match?.group(1)?.trim();
  if (relative == null || relative.isEmpty) return null;
  return p.normalize(
    p.isAbsolute(relative) ? relative : p.join(project, relative),
  );
}

/// The app's own VM-service line is a raw capability that `flutter attach`
/// consumes. Redact it from the run log so the parent connects only through
/// the Flutter tool's DDS endpoint, exactly as with `flutter run`.
String _redactMacosAppVmServiceLine(String line) => line.replaceAll(
  RegExp(r'(?:https?|wss?)://(?:127\.0\.0\.1|localhost|\[::1\]):\d+/\S*'),
  '<app-vm-service>',
);

class _MacosLaunchedApp {
  const _MacosLaunchedApp({
    required this.pid,
    required this.executable,
    required this.identity,
    required this.vmServiceUri,
    required this.outputTail,
  });

  final int pid;
  final String executable;
  final Map<String, Object?>? identity;
  final String vmServiceUri;

  /// Completes after the output tail observed [isStopped] and wrote its last
  /// line, so the caller can close the log writer afterwards.
  final Future<void> outputTail;

  Map<String, Object?> toState() => {
    'macosAppPid': pid,
    'macosAppExecutable': executable,
    'macosAppProcessIdentity': ?identity,
  };
}

extension _CliMacosLaunch on FlutterScoutCli {
  Future<String?> _macosBundleExecutable(String appPath) async {
    final infoPlist = p.join(appPath, 'Contents', 'Info.plist');
    final result = await Process.run('/usr/bin/plutil', [
      '-extract',
      'CFBundleExecutable',
      'raw',
      infoPlist,
    ]);
    final name = '${result.stdout}'.trim();
    if (result.exitCode != 0 || name.isEmpty || name.contains('/')) {
      return null;
    }
    return p.join(appPath, 'Contents', 'MacOS', name);
  }

  Future<Set<int>> _pidsForExecutable(String executable) async {
    final result = await Process.run('ps', ['-ax', '-o', 'pid=,comm=']);
    if (result.exitCode != 0) return <int>{};
    final pids = <int>{};
    for (final line in '${result.stdout}'.split('\n')) {
      final match = RegExp(r'^\s*(\d+)\s+(.+?)\s*$').firstMatch(line);
      if (match == null || match.group(2) != executable) continue;
      final pid = int.tryParse(match.group(1)!);
      if (pid != null) pids.add(pid);
    }
    return pids;
  }

  /// Opens the built bundle as a new LaunchServices instance, streams its
  /// stdout/stderr into the run log, and returns once the app reported its VM
  /// service. [isCancelled] stops waiting when the worker is asked to stop.
  Future<_MacosLaunchedApp> _openMacosAppForAttach({
    required String appPath,
    required _MacosLaunchPlan plan,
    required String outputFile,
    required Future<void> Function(String line) writeAppLine,
    required bool Function() isCancelled,
    required bool Function() isStopped,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final executable = await _macosBundleExecutable(appPath);
    if (executable == null) {
      throw ScoutCliException(
        'macos_app_bundle_invalid',
        'Flutter Scout could not read CFBundleExecutable from $appPath.',
      );
    }
    final existing = await _pidsForExecutable(executable);
    // The worker runs outside any session CWD; write within the run folder.
    _atomicWritePrivateString(outputFile, '', boundary: p.dirname(outputFile));
    final open = await Process.run('/usr/bin/open', [
      '-n',
      '--stdout',
      outputFile,
      '--stderr',
      outputFile,
      ...plan.openEnvironmentArgs(),
      appPath,
    ]);
    if (open.exitCode != 0) {
      throw ScoutCliException(
        'macos_app_open_failed',
        'LaunchServices could not open $appPath: '
            '${'${open.stderr}'.trim()}',
      );
    }

    var offset = 0;
    var pending = '';
    String? vmServiceUri;
    final deadline = DateTime.now().add(timeout);
    while (vmServiceUri == null) {
      if (isCancelled()) {
        throw const ScoutCliException(
          'macos_app_launch_cancelled',
          'The macOS app launch was cancelled before its VM service started.',
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        throw ScoutCliException(
          'macos_app_vm_service_not_found',
          'The macOS app opened but did not report a Dart VM service within '
              '${timeout.inSeconds}s. Check that it is a debug build.',
        );
      }
      final chunk = _readFileFrom(outputFile, offset);
      offset += chunk.length;
      pending += utf8.decode(chunk, allowMalformed: true);
      final lines = pending.split('\n');
      pending = lines.removeLast();
      for (final line in lines) {
        vmServiceUri ??= _extractAppVmServiceUri(line);
        await writeAppLine(_redactMacosAppVmServiceLine(line));
      }
      if (vmServiceUri == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    final outputTail = _tailMacosAppOutput(
      outputFile,
      offset: offset,
      pending: pending,
      writeAppLine: writeAppLine,
      isStopped: isStopped,
    );

    int? appPid;
    for (var attempt = 0; attempt < 25 && appPid == null; attempt++) {
      final launched = (await _pidsForExecutable(
        executable,
      )).difference(existing);
      if (launched.length == 1) appPid = launched.single;
      if (appPid == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    if (appPid == null) {
      throw ScoutCliException(
        'macos_app_process_not_found',
        'The macOS app reported a VM service but Flutter Scout could not '
            'identify exactly one new $executable process.',
      );
    }
    return _MacosLaunchedApp(
      pid: appPid,
      executable: executable,
      identity: await _readProcessOwnershipIdentity(
        appPid,
        role: _macosAppProcessRole,
      ),
      vmServiceUri: vmServiceUri,
      outputTail: outputTail,
    );
  }

  String? _extractAppVmServiceUri(String line) {
    final match = RegExp(
      r'Dart VM service is listening on (https?://(?:127\.0\.0\.1|localhost):\d+/\S*)',
    ).firstMatch(line);
    final value = match?.group(1);
    if (value == null) return null;
    _registerVmUriCredentials(value);
    return value;
  }

  List<int> _readFileFrom(String path, int offset) {
    RandomAccessFile? file;
    try {
      file = File(path).openSync();
      final length = file.lengthSync();
      if (length <= offset) return const <int>[];
      file.setPositionSync(offset);
      return file.readSync(length - offset);
    } catch (_) {
      return const <int>[];
    } finally {
      file?.closeSync();
    }
  }

  /// Keeps forwarding app prints into the run log, as `flutter run` does,
  /// until the worker reports [isStopped].
  Future<void> _tailMacosAppOutput(
    String outputFile, {
    required int offset,
    required String pending,
    required Future<void> Function(String line) writeAppLine,
    required bool Function() isStopped,
  }) async {
    var position = offset;
    var buffer = pending;
    while (true) {
      final stopping = isStopped();
      final chunk = _readFileFrom(outputFile, position);
      if (chunk.isNotEmpty) {
        position += chunk.length;
        buffer += utf8.decode(chunk, allowMalformed: true);
        final lines = buffer.split('\n');
        buffer = lines.removeLast();
        for (final line in lines) {
          await writeAppLine(_redactMacosAppVmServiceLine(line));
        }
      }
      if (stopping) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// Terminates the exact LaunchServices app this worker opened. `flutter
  /// attach` detaches without stopping the app, while `flutter run` stops a
  /// desktop app when the tool exits; this restores that ownership contract.
  Future<String> _terminateMacosApp(Map<String, dynamic>? state) async {
    final pid = int.tryParse('${state?['macosAppPid'] ?? ''}');
    final expected = state?['macosAppProcessIdentity'];
    if (pid == null) return 'not_recorded';
    if (expected is! Map) {
      return await _processExists(pid) ? 'identity_unavailable' : 'not_running';
    }
    Future<bool> stillOwned() async {
      final current = await _readProcessOwnershipIdentity(
        pid,
        role: _macosAppProcessRole,
      );
      return current != null &&
          _sameProcessOwnershipIdentity(expected, current);
    }

    if (!await stillOwned()) return 'not_running';
    Process.killPid(pid);
    for (var attempt = 0; attempt < 30; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!await stillOwned()) return 'terminated';
    }
    Process.killPid(pid, ProcessSignal.sigkill);
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!await stillOwned()) return 'killed';
    }
    return 'still_running';
  }
}

extension FlutterScoutCliMacosLaunchTesting on FlutterScoutCli {
  bool debugShouldLaunchMacosAppThroughLaunchServices({
    required bool isMacOS,
    required String deviceId,
    required Map<String, String> environment,
  }) => _shouldLaunchMacosAppThroughLaunchServices(
    isMacOS: isMacOS,
    deviceId: deviceId,
    environment: environment,
  );

  Map<String, Object?> debugMacosLaunchPlan(List<String> runArgs) {
    final plan = _MacosLaunchPlan.fromRunArgs(runArgs);
    return {
      'buildArgs': plan.buildArgs,
      'attachArgs': plan.attachArgs('<uri>'),
      'openEnvironmentArgs': plan.openEnvironmentArgs(),
    };
  }

  String? debugBuiltMacosAppPath(String line, {required String project}) =>
      _builtMacosAppPath(line, project: project);

  String debugRedactMacosAppVmServiceLine(String line) =>
      _redactMacosAppVmServiceLine(line);
}
