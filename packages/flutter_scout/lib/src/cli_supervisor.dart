part of 'flutter_scout_cli.dart';

// part: detached ownership of Scout-started Flutter tool processes.

// Source and Pub JIT snapshots need a script after the Dart executable. AOT
// executables are already the script, so repeating it becomes a CLI command.
// Resolve the script path too so invocation through a symlink keeps working.
List<String> _scoutSelfArguments(List<String> arguments) {
  final script = Platform.script.toFilePath();
  final isNativeExecutable =
      p.equals(Platform.resolvedExecutable, script) ||
      p.equals(
        Platform.resolvedExecutable,
        File(script).resolveSymbolicLinksSync(),
      );
  return [if (!isNativeExecutable) script, ...arguments];
}

extension _CliSupervisor on FlutterScoutCli {
  Future<String> _resolveFlutterExecutable() async {
    final result = await Process.run('which', ['flutter']);
    final resolved = '${result.stdout}'.trim();
    if (result.exitCode == 0 && resolved.isNotEmpty) return resolved;
    throw const ScoutCliException(
      'flutter_executable_not_found',
      'Flutter Scout could not resolve the Flutter executable before '
          'starting the detached runner.',
    );
  }

  Future<_RunnerSupervisor> _startFlutterRunnerSupervisor({
    required String configFile,
    required String runId,
    required String outputFile,
    required bool inheritLaunchContext,
  }) async {
    if (_shouldUseLaunchdRunnerSupervisor(
      isMacOS: Platform.isMacOS,
      launchdDisabledByEnvironment:
          Platform.environment['FLUTTER_SCOUT_DISABLE_LAUNCHD'] == '1',
      inheritLaunchContext: inheritLaunchContext,
    )) {
      try {
        return await _startLaunchdRunnerSupervisor(
          configFile: configFile,
          runId: runId,
          outputFile: outputFile,
        );
      } catch (error) {
        final writer = _LockedLogWriter(outputFile);
        await writer.write(
          '[${DateTime.now().toUtc().toIso8601String()}] '
          '[flutter_scout] launchd supervisor unavailable; using detached '
          'worker: ${_redactSensitiveLogText(error.toString())}',
        );
        await writer.close();
      }
    }

    final process = await Process.start(
      Platform.resolvedExecutable,
      _scoutSelfArguments(['flutter-run-worker', '--config', configFile]),
      mode: ProcessStartMode.detached,
    );
    final processIdentity = await _readProcessOwnershipIdentity(
      process.pid,
      role: _flutterWorkerProcessRole,
    );
    return _RunnerSupervisor.detached(
      process,
      runId: runId,
      configFile: configFile,
      processIdentity: processIdentity,
    );
  }

  Future<_RunnerSupervisor> _startLaunchdRunnerSupervisor({
    required String configFile,
    required String runId,
    required String outputFile,
  }) async {
    final uidResult = await Process.run('id', ['-u']);
    if (uidResult.exitCode != 0) {
      throw ScoutCliException(
        'launchd_uid_unavailable',
        'Could not resolve the current macOS user id: ${uidResult.stderr}',
      );
    }
    final uid = '${uidResult.stdout}'.trim();
    if (!RegExp(r'^\d+$').hasMatch(uid)) {
      throw const ScoutCliException(
        'launchd_uid_invalid',
        'macOS returned an invalid user id for the runner supervisor.',
      );
    }
    final safeRunId = runId.replaceAll(RegExp(r'[^A-Za-z0-9.-]'), '-');
    final label = 'dev.flutter-scout.runner.$safeRunId';
    final domain = 'gui/$uid';
    final plistFile = File(
      p.join(p.dirname(configFile), 'flutter_runner.plist'),
    );
    _writePrivateSessionString(
      plistFile.path,
      _launchdRunnerPlist(
        label: label,
        configFile: configFile,
        outputFile: outputFile,
      ),
    );

    final bootstrap = await Process.run('launchctl', [
      'bootstrap',
      domain,
      plistFile.path,
    ]);
    if (bootstrap.exitCode != 0) {
      throw ScoutCliException(
        'launchd_bootstrap_failed',
        'Could not start the macOS runner supervisor: '
            '${bootstrap.stderr.toString().trim()}',
      );
    }

    int? workerPid;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      workerPid = await _launchdServicePid(domain: domain, label: label);
      if (workerPid != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final workerIdentity = workerPid == null
        ? null
        : await _readProcessOwnershipIdentity(
            workerPid,
            role: _flutterWorkerProcessRole,
          );
    return _RunnerSupervisor.launchd(
      domain: domain,
      label: label,
      plistFile: plistFile.path,
      workerPid: workerPid,
      runId: runId,
      configFile: configFile,
      processIdentity: workerIdentity,
    );
  }

  String _launchdRunnerPlist({
    required String label,
    required String configFile,
    required String outputFile,
  }) {
    final arguments = <String>[
      Platform.resolvedExecutable,
      ..._scoutSelfArguments(['flutter-run-worker', '--config', configFile]),
    ];
    final argumentXml = arguments
        .map((value) => '    <string>${_xmlEscape(value)}</string>')
        .join('\n');
    final path =
        Platform.environment['PATH'] ??
        '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin';
    final home = Platform.environment['HOME'];
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${_xmlEscape(label)}</string>
  <key>ProgramArguments</key>
  <array>
$argumentXml
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${_xmlEscape(path)}</string>
${home == null || home.isEmpty ? '' : '    <key>HOME</key>\n    <string>${_xmlEscape(home)}</string>\n'}  </dict>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>ThrottleInterval</key>
  <integer>2</integer>
  <key>StandardOutPath</key>
  <string>${_xmlEscape(outputFile)}</string>
  <key>StandardErrorPath</key>
  <string>${_xmlEscape(outputFile)}</string>
</dict>
</plist>
''';
  }

  String _xmlEscape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  Future<int?> _launchdServicePid({
    required String domain,
    required String label,
  }) async {
    final result = await Process.run('launchctl', ['print', '$domain/$label']);
    if (result.exitCode != 0) return null;
    final match = RegExp(
      r'^\s*pid\s*=\s*(\d+)\s*$',
      multiLine: true,
    ).firstMatch('${result.stdout}');
    return int.tryParse(match?.group(1) ?? '');
  }

  Future<bool> _runnerSupervisorAlive(_RunnerSupervisor supervisor) async {
    Future<bool> matchesLiveWorker(int workerPid) {
      final state = _readSessionConfiguredJson('supervisorStateFile');
      final expectedIdentity = _selectRunnerWorkerIdentity(
        initialIdentity: supervisor.processIdentity,
        expectedRunId: supervisor.runId,
        liveWorkerPid: workerPid,
        supervisorState: state,
      );
      return _matchesRunnerWorker(
        workerPid,
        expectedIdentity: expectedIdentity,
        expectedRunId: supervisor.runId,
        expectedConfigFile: supervisor.configFile,
      );
    }

    if (supervisor.type == 'launchd') {
      final domain = supervisor.domain;
      final label = supervisor.label;
      if (domain == null || label == null) return false;
      final workerPid = await _launchdServicePid(domain: domain, label: label);
      if (workerPid == null) return false;
      return matchesLiveWorker(workerPid);
    }
    final workerPid = supervisor.workerPid;
    return workerPid != null && await matchesLiveWorker(workerPid);
  }

  Future<bool> _matchesRunnerWorker(
    int workerPid, {
    required Object? expectedIdentity,
    required String? expectedRunId,
    required String? expectedConfigFile,
  }) async {
    if (expectedIdentity is! Map ||
        expectedRunId == null ||
        expectedRunId.isEmpty ||
        expectedConfigFile == null ||
        expectedConfigFile.isEmpty ||
        !_isWithinSessionOwnershipBoundary(expectedConfigFile)) {
      return false;
    }
    final currentIdentity = await _readProcessOwnershipIdentity(
      workerPid,
      role: _flutterWorkerProcessRole,
    );
    if (currentIdentity == null ||
        !_matchesRunnerWorkerIdentity(expectedIdentity, currentIdentity)) {
      return false;
    }
    final command = await _processCommand(workerPid);
    if (command == null) return false;
    return _commandLooksLikeScoutCli(command) &&
        command.contains('flutter-run-worker') &&
        command.contains(expectedConfigFile) &&
        File(expectedConfigFile).existsSync();
  }

  Future<bool> _matchesFlutterSupervisorAssociation(
    Map<String, dynamic> meta,
    Map<Object?, Object?> flutterIdentity,
  ) async {
    final supervisor = meta['supervisor'];
    if (supervisor is! Map) return true;
    final runId = meta['runId']?.toString();
    final configFile = supervisor['configFile']?.toString();
    var workerPid = int.tryParse('${supervisor['workerPid'] ?? ''}');
    Object? workerIdentity = supervisor['processIdentity'];
    final state = _readSessionConfiguredJson('supervisorStateFile');
    if (state != null && state['runId']?.toString() == runId) {
      final stateWorkerPid = int.tryParse('${state['workerPid'] ?? ''}');
      final stateWorkerIdentity = state['workerProcessIdentity'];
      if (stateWorkerPid != null && stateWorkerIdentity is Map) {
        workerPid = stateWorkerPid;
        workerIdentity = stateWorkerIdentity;
      }
    }
    final expectedParentPid = int.tryParse(
      '${flutterIdentity['parentPid'] ?? ''}',
    );
    if (workerPid == null ||
        workerPid != expectedParentPid ||
        runId == null ||
        configFile == null ||
        !_runnerConfigMatchesOwnership(configFile, meta)) {
      return false;
    }
    return _matchesRunnerWorker(
      workerPid,
      expectedIdentity: workerIdentity,
      expectedRunId: runId,
      expectedConfigFile: configFile,
    );
  }

  bool _isWithinSessionOwnershipBoundary(String candidate) {
    final boundary = _resolvedOwnershipPath(_sessionDir.path);
    final resolvedCandidate = _resolvedOwnershipPath(candidate);
    return p.equals(boundary, resolvedCandidate) ||
        p.isWithin(boundary, resolvedCandidate);
  }

  String _resolvedOwnershipPath(String value) {
    try {
      return File(value).resolveSymbolicLinksSync();
    } catch (_) {
      try {
        return Directory(value).resolveSymbolicLinksSync();
      } catch (_) {
        return p.normalize(p.absolute(value));
      }
    }
  }

  bool _runnerConfigMatchesOwnership(
    String configFile,
    Map<String, dynamic> meta,
  ) {
    try {
      final decoded = jsonDecode(File(configFile).readAsStringSync());
      if (decoded is! Map) return false;
      final runId = meta['runId']?.toString();
      final project = meta['project']?.toString();
      final device = meta['device']?.toString();
      final args = decoded['flutterArgs'];
      if (runId == null ||
          runId.isEmpty ||
          project == null ||
          project.isEmpty ||
          device == null ||
          device.isEmpty ||
          decoded['runId']?.toString() != runId ||
          decoded['device']?.toString() != device ||
          _resolvedOwnershipPath(decoded['project']?.toString() ?? '') !=
              _resolvedOwnershipPath(project) ||
          args is! List) {
        return false;
      }
      final values = args.map((value) => value.toString()).toList();
      bool hasPair(String option, String value) {
        for (var index = 0; index + 1 < values.length; index++) {
          if (values[index] == option && values[index + 1] == value) {
            return true;
          }
        }
        return false;
      }

      return values.contains('run') &&
          hasPair('-d', device) &&
          hasPair('--dart-define', '$kScoutRunIdDefine=$runId') &&
          hasPair(
            '--dart-define',
            '$kScoutProjectDefine=${Directory(project).absolute.path}',
          );
    } catch (_) {
      return false;
    }
  }

  List<StreamSubscription<ProcessSignal>> _installRunnerSignalHandlers(
    _RunnerSupervisor supervisor,
    Map<String, dynamic> supervisorOwnershipMeta,
  ) {
    void stopForInterrupt(ProcessSignal signal) {
      unawaited(() async {
        final result = await _stopRunnerSupervisor(supervisorOwnershipMeta);
        if (result['stopped'] == true) {
          _deleteFileIfExists(_pidFile);
        }
        _writeProgress('stopped_child_process', {
          'signal': signal.toString(),
          'pid': ?supervisor.workerPid,
          'supervisor': supervisor.type,
          'stopped': result['stopped'] == true,
          if (result['reason'] != null) 'reason': result['reason'],
        });
      }());
    }

    // SIGINT is an explicit Ctrl-C cancellation. SIGTERM commonly represents
    // the owning terminal or agent session being cleaned up; the detached
    // supervisor must survive that event and keep `flutter run` available.
    return [ProcessSignal.sigint.watch().listen(stopForInterrupt)];
  }

  Future<Map<String, Object?>> _stopRunnerSupervisor(
    Map<String, dynamic>? meta, {
    bool waitForWriterQuiescence = false,
  }) async {
    final supervisor = meta?['supervisor'];
    if (supervisor is! Map) {
      return const {'configured': false, 'stopped': false};
    }
    final type = supervisor['type']?.toString();
    final workerPid = int.tryParse('${supervisor['workerPid'] ?? ''}');
    final configFile = supervisor['configFile']?.toString();
    final supervisorRunId = supervisor['runId']?.toString();
    final processIdentity = supervisor['processIdentity'];
    final domain = supervisor['domain']?.toString();
    final label = supervisor['label']?.toString();
    final plistFile = supervisor['plistFile']?.toString();
    final runId = meta?['runId']?.toString();
    final project = meta?['project']?.toString();
    final expectedLabel = runId == null || runId.isEmpty
        ? null
        : 'dev.flutter-scout.runner.${runId.replaceAll(RegExp(r'[^A-Za-z0-9.-]'), '-')}';
    final commonTrusted =
        runId != null &&
        runId.isNotEmpty &&
        supervisorRunId == runId &&
        project != null &&
        project.isNotEmpty &&
        configFile != null &&
        configFile.isNotEmpty &&
        _isWithinSessionOwnershipBoundary(configFile) &&
        File(configFile).existsSync() &&
        _runnerConfigMatchesOwnership(configFile, meta!);
    if (!commonTrusted) {
      return const {
        'configured': true,
        'stopped': false,
        'reason': 'supervisor_identity_mismatch',
      };
    }

    if (type == 'detached_process') {
      if (workerPid == null) {
        return const {
          'configured': true,
          'stopped': false,
          'reason': 'supervisor_pid_missing',
        };
      }
      final exists = await _processExists(workerPid);
      if (!exists) {
        return {
          'configured': true,
          'stopped': true,
          'alreadyStopped': true,
          if (waitForWriterQuiescence) 'writersQuiesced': true,
          if (waitForWriterQuiescence) 'writerQuiescenceWaitMs': 0,
        };
      }
      final trustedWorker = await _matchesRunnerWorker(
        workerPid,
        expectedIdentity: processIdentity,
        expectedRunId: runId,
        expectedConfigFile: configFile,
      );
      if (!trustedWorker) {
        return const {
          'configured': true,
          'stopped': false,
          'reason': 'supervisor_process_identity_mismatch',
        };
      }
      final stopped = Process.killPid(workerPid);
      final quiescence = waitForWriterQuiescence
          ? await _waitForSupervisorWriterQuiescence(workerPid)
          : null;
      return {
        'configured': true,
        'stopped': stopped,
        'pid': workerPid,
        ...?quiescence,
      };
    }

    final trustedLaunchd =
        Platform.isMacOS &&
        type == 'launchd' &&
        domain != null &&
        RegExp(r'^gui/\d+$').hasMatch(domain) &&
        label != null &&
        label == expectedLabel &&
        plistFile != null &&
        _isWithinSessionOwnershipBoundary(plistFile);
    if (!trustedLaunchd) {
      return const {
        'configured': true,
        'stopped': false,
        'reason': 'supervisor_identity_mismatch',
      };
    }
    final plist = File(plistFile);
    if (!plist.existsSync()) {
      return const {
        'configured': true,
        'stopped': false,
        'reason': 'supervisor_plist_missing',
      };
    }
    final plistText = plist.readAsStringSync();
    if (!plistText.contains('<string>${_xmlEscape(label)}</string>') ||
        !plistText.contains('<string>${_xmlEscape(configFile)}</string>') ||
        !plistText.contains('flutter-run-worker')) {
      return const {
        'configured': true,
        'stopped': false,
        'reason': 'supervisor_plist_identity_mismatch',
      };
    }
    final liveWorkerPid = await _launchdServicePid(
      domain: domain,
      label: label,
    );
    if (liveWorkerPid != null) {
      Object? liveExpectedIdentity = processIdentity;
      final stateFile = meta['supervisorStateFile']?.toString();
      final state = stateFile == null
          ? null
          : _readSessionConfiguredJson('supervisorStateFile');
      if (state != null &&
          state['runId']?.toString() == runId &&
          int.tryParse('${state['workerPid'] ?? ''}') == liveWorkerPid) {
        liveExpectedIdentity = state['workerProcessIdentity'];
      }
      final trustedWorker = await _matchesRunnerWorker(
        liveWorkerPid,
        expectedIdentity: liveExpectedIdentity,
        expectedRunId: runId,
        expectedConfigFile: configFile,
      );
      if (!trustedWorker) {
        return const {
          'configured': true,
          'stopped': false,
          'reason': 'supervisor_process_identity_mismatch',
        };
      }
    }
    final result = await Process.run('launchctl', [
      'bootout',
      '$domain/$label',
    ]);
    final message = '${result.stderr}'.trim();
    final alreadyStopped =
        result.exitCode != 0 &&
        (message.contains('Could not find service') ||
            message.contains('No such process'));
    final quiescence = waitForWriterQuiescence && liveWorkerPid != null
        ? await _waitForSupervisorWriterQuiescence(liveWorkerPid)
        : waitForWriterQuiescence
        ? const <String, Object?>{
            'writersQuiesced': true,
            'writerQuiescenceWaitMs': 0,
          }
        : null;
    return {
      'configured': true,
      'stopped': result.exitCode == 0 || alreadyStopped,
      'label': label,
      if (result.exitCode != 0 && !alreadyStopped) 'error': message,
      ...?quiescence,
    };
  }

  Future<Map<String, Object?>> _waitForSupervisorWriterQuiescence(
    int workerPid,
  ) async {
    const timeout = Duration(seconds: 10);
    const pollInterval = Duration(milliseconds: 50);
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      if (!await _processExists(workerPid)) {
        stopwatch.stop();
        return <String, Object?>{
          'writersQuiesced': true,
          'writerQuiescenceWaitMs': stopwatch.elapsedMilliseconds,
        };
      }
      await Future<void>.delayed(pollInterval);
    }
    stopwatch.stop();
    return <String, Object?>{
      'writersQuiesced': false,
      'writerQuiescenceWaitMs': stopwatch.elapsedMilliseconds,
      'writerQuiescenceReason': 'supervisor_process_still_present',
    };
  }
}

bool _shouldUseLaunchdRunnerSupervisor({
  required bool isMacOS,
  required bool launchdDisabledByEnvironment,
  required bool inheritLaunchContext,
}) => isMacOS && !launchdDisabledByEnvironment && !inheritLaunchContext;

Object? _selectRunnerWorkerIdentity({
  required Object? initialIdentity,
  required String? expectedRunId,
  required int liveWorkerPid,
  required Map<String, dynamic>? supervisorState,
}) {
  if (supervisorState == null ||
      supervisorState['runId']?.toString() != expectedRunId ||
      int.tryParse('${supervisorState['workerPid'] ?? ''}') != liveWorkerPid ||
      supervisorState['workerProcessIdentity'] is! Map) {
    return initialIdentity;
  }
  return supervisorState['workerProcessIdentity'];
}

bool _matchesRunnerWorkerIdentity(
  Map<Object?, Object?> expected,
  Map<String, Object?> current,
) {
  if (_sameProcessOwnershipIdentity(expected, current)) return true;

  final expectedExecutable = expected['executable']?.toString();
  final currentExecutable = current['executable']?.toString();
  return int.tryParse('${expected['pid'] ?? ''}') == current['pid'] &&
      int.tryParse('${expected['parentPid'] ?? ''}') == current['parentPid'] &&
      expected['startedAt']?.toString() == current['startedAt'] &&
      expected['commandIdentity'] == _flutterWorkerProcessRole &&
      current['commandIdentity'] == _flutterWorkerProcessRole &&
      expectedExecutable != null &&
      currentExecutable != null &&
      p.basename(expectedExecutable) == 'dart' &&
      p.basename(currentExecutable) == 'dartvm' &&
      p.dirname(expectedExecutable) == p.dirname(currentExecutable);
}

extension FlutterScoutCliSupervisorTesting on FlutterScoutCli {
  bool debugShouldUseLaunchdRunnerSupervisor({
    required bool isMacOS,
    required bool launchdDisabledByEnvironment,
    required bool inheritLaunchContext,
  }) => _shouldUseLaunchdRunnerSupervisor(
    isMacOS: isMacOS,
    launchdDisabledByEnvironment: launchdDisabledByEnvironment,
    inheritLaunchContext: inheritLaunchContext,
  );

  Object? debugSelectRunnerWorkerIdentity({
    required Object? initialIdentity,
    required String? expectedRunId,
    required int liveWorkerPid,
    required Map<String, dynamic>? supervisorState,
  }) => _selectRunnerWorkerIdentity(
    initialIdentity: initialIdentity,
    expectedRunId: expectedRunId,
    liveWorkerPid: liveWorkerPid,
    supervisorState: supervisorState,
  );

  bool debugMatchesRunnerWorkerIdentity(
    Map<Object?, Object?> expected,
    Map<String, Object?> current,
  ) => _matchesRunnerWorkerIdentity(expected, current);
}

class _RunnerSupervisor {
  const _RunnerSupervisor._({
    required this.type,
    this.domain,
    this.label,
    this.plistFile,
    this.workerPid,
    this.runId,
    this.configFile,
    this.processIdentity,
  });

  factory _RunnerSupervisor.detached(
    Process process, {
    required String runId,
    required String configFile,
    required Map<String, Object?>? processIdentity,
  }) => _RunnerSupervisor._(
    type: 'detached_process',
    workerPid: process.pid,
    runId: runId,
    configFile: configFile,
    processIdentity: processIdentity,
  );

  factory _RunnerSupervisor.launchd({
    required String domain,
    required String label,
    required String plistFile,
    required int? workerPid,
    required String runId,
    required String configFile,
    required Map<String, Object?>? processIdentity,
  }) => _RunnerSupervisor._(
    type: 'launchd',
    domain: domain,
    label: label,
    plistFile: plistFile,
    workerPid: workerPid,
    runId: runId,
    configFile: configFile,
    processIdentity: processIdentity,
  );

  final String type;
  final String? domain;
  final String? label;
  final String? plistFile;
  final int? workerPid;
  final String? runId;
  final String? configFile;
  final Map<String, Object?>? processIdentity;

  Map<String, Object?> toJson() => {
    'type': type,
    if (domain != null) 'domain': domain,
    if (label != null) 'label': label,
    if (plistFile != null) 'plistFile': plistFile,
    if (workerPid != null) 'workerPid': workerPid,
    if (runId != null) 'runId': runId,
    if (configFile != null) 'configFile': configFile,
    if (processIdentity != null) 'processIdentity': processIdentity,
  };
}
