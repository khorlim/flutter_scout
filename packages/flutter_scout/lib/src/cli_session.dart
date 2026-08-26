part of 'flutter_scout_cli.dart';

// part: session lifecycle commands: launch, attach, ensure, status, doctor, stop.

// POSIX advisory locks are process-scoped on some platforms, so a second
// Scout command served inside the same long-lived process needs an explicit
// in-process guard in addition to the kernel lease.
final Set<String> _heldLaunchLeasePaths = <String>{};

String get _launchLockInfoFile => '$_launchLockFile.info.json';

// On iOS Simulator, `flutter run` can report the Xcode build as complete just
// before launchd briefly loses the worker's process identity.  The worker can
// still flush the app's VM-service line a few seconds later.  Do not turn that
// narrow, post-build identity race into a destructive stop of a healthy app.
const Duration _postBuildVmServiceGrace = Duration(seconds: 45);

/// A live helper retains the launch run ID compiled into the application. An
/// attach command normally gets a new ID, which is correct for a third-party
/// app, but would make a healthy Scout-owned app inspect-only after its launch
/// worker exits. This record is produced only after a fresh local VM-helper
/// inspection; it never trusts an ID supplied on the command line.
class _AttachedHelperIdentity {
  const _AttachedHelperIdentity({
    required this.runId,
    required this.runtimeInstanceId,
  });

  final String runId;
  final String runtimeInstanceId;
}

Map<String, Object?>? _reconcileAttachRunIdentity({
  required Map<String, Object?>? previousMeta,
  required String helperRunId,
  required String runtimeInstanceId,
  required String? requestedDevice,
}) {
  if (previousMeta == null) return null;
  final previousRunId = previousMeta['runId']?.toString();
  final mode = previousMeta['mode']?.toString();
  final previousMode = previousMeta['previousMode']?.toString();
  final wasScoutOwned =
      mode == 'scout_owned_flutter_run' ||
      previousMode == 'scout_owned_flutter_run';
  if (!wasScoutOwned ||
      previousRunId == null ||
      previousRunId.isEmpty ||
      previousRunId != helperRunId) {
    return null;
  }

  // A caller that names a device must not silently recover a launch that was
  // recorded for another device. If the old launch did not record one, VM
  // loopback and exact run identity remain the available proof.
  final previousDevice = previousMeta['device']?.toString();
  if (requestedDevice != null &&
      requestedDevice.isNotEmpty &&
      previousDevice != null &&
      previousDevice.isNotEmpty &&
      previousDevice != requestedDevice) {
    return null;
  }
  return <String, Object?>{
    'runId': helperRunId,
    'previousRunId': previousRunId,
    'runtimeInstanceId': runtimeInstanceId,
    if (previousDevice != null && previousDevice.isNotEmpty)
      'previousDevice': previousDevice,
  };
}

bool _shouldAwaitPostBuildVmService({
  required DateTime now,
  required DateTime? buildDoneAt,
}) =>
    buildDoneAt != null &&
    now.isBefore(buildDoneAt.add(_postBuildVmServiceGrace));

extension _CliSession on FlutterScoutCli {
  Future<int> _launch(List<String> args) async {
    final parser = ArgParser()
      ..addOption('device', abbr: 'd')
      ..addOption('project', defaultsTo: Directory.current.path)
      ..addOption('target')
      ..addOption('flavor')
      ..addOption('name')
      ..addFlag(
        'temporary-helper',
        defaultsTo: false,
        negatable: false,
        help:
            'Inject flutter_scout_helper through a generated bootstrap without '
            'leaving tracked project changes.',
      )
      ..addOption('helper-path')
      ..addFlag('replace', defaultsTo: false, negatable: false)
      ..addMultiOption(
        'dart-define',
        splitCommas: false,
        help:
            'Deprecated for inline values and rejected when secret-looking. '
            'Prefer --dart-define-from-file.',
      )
      ..addMultiOption(
        'dart-define-from-file',
        splitCommas: false,
        help:
            'Read Flutter defines from a bounded, strict-UTF-8, regular '
            'non-symlink file that is exactly 0600 on POSIX.',
      )
      ..addOption(
        'launch-timeout',
        help:
            'Hard ceiling in seconds for a launch to produce a VM service URI '
            '(default 1200). Raise it for very slow first builds.',
      )
      ..addOption(
        'launch-idle-timeout',
        help:
            'Give up when the runner prints nothing for this many seconds '
            '(default 180). This, not elapsed time, is what ends a stuck build.',
      )
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final launchTimeout = Duration(
      seconds: int.tryParse(parsed.option('launch-timeout') ?? '') ?? 1200,
    );
    final launchIdleTimeout = Duration(
      seconds: int.tryParse(parsed.option('launch-idle-timeout') ?? '') ?? 180,
    );
    final device = parsed.option('device');
    if (device == null || device.isEmpty) {
      throw const ScoutCliException(
        'missing_device',
        'Usage: flutter-scout launch --device <simulator-id> [--project <path>] '
            '[--name <label>] [--replace] [--temporary-helper]',
      );
    }
    final project = p.normalize(p.absolute(parsed.option('project')!));
    final projectDir = Directory(project);
    if (!projectDir.existsSync()) {
      throw ScoutCliException('project_missing', 'Project not found: $project');
    }
    final previousSessionMeta = _readSessionMeta();
    final existingVmUri = _readVmUri();
    if (existingVmUri != null && (await _validateVmUri(existingVmUri)).ok) {
      if (!parsed.flag('replace')) {
        throw const ScoutCliException(
          'session_already_running',
          'This Scout session is already ready. Use `ensure` to reuse it or '
              '`launch --replace` for an explicit fresh run.',
        );
      }
      await _stop(const ['--quiet']);
    }
    final launchLease = await _acquireLaunchLease(
      project: project,
      device: device,
      name: parsed.option('name'),
    );
    _TemporaryHelperSetup? temporarySetup;
    var preserveTemporarySetupForOwnedRun = false;
    try {
      // A normally exited macOS worker leaves an inactive launchd job loaded.
      // Once this launch owns the session lease, unload the previous exact job
      // before replacing its metadata with the new run.
      await _stopRunnerSupervisor(previousSessionMeta);
      // The detached worker writes a newly discovered, validated capability
      // URL to this single designated store. Remove any stale predecessor
      // before it starts so the parent cannot adopt a credential from an older
      // runtime while polling for this launch.
      _clearVmUriFile();
      final instanceName = parsed.option('name');
      if (instanceName != null && instanceName.isNotEmpty) {
        _registerScoutSession(instanceName, _sessionDir.path, project: project);
      }
      _writeProgress('resolve_device', {'requestedDevice': device});
      final resolvedDevice = await _resolveFlutterDevice(device);
      if (resolvedDevice == null) {
        throw ScoutCliException(
          'device_not_found',
          'No connected Flutter device exactly matched `$device`.',
        );
      }
      // Capture app/toolchain identity before temporary-helper preparation
      // writes any Scout-owned generated target or pub metadata.
      final flutterExecutable = await _resolveFlutterExecutable();
      final launchProvenance = await _collectLaunchProvenance(
        project: project,
        flutterExecutable: flutterExecutable,
      );

      _ensureSessionDir();
      final runLogFile = p.join(
        _sessionDir.path,
        'runs',
        launchLease.runId,
        'logs.txt',
      );
      _writePrivateSessionString(runLogFile, '');
      _writeSessionMeta({
        'mode': 'scout_owned_flutter_run',
        'state': 'building',
        'runId': launchLease.runId,
        'name': ?instanceName,
        'project': project,
        'device': resolvedDevice.id,
        'logFile': runLogFile,
        ...launchProvenance,
        'createdAt': launchLease.startedAt.toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      });
      temporarySetup = parsed.flag('temporary-helper')
          ? await _prepareTemporaryHelper(
              project: project,
              originalTarget: parsed.option('target') ?? 'lib/main.dart',
              helperPath: parsed.option('helper-path'),
              runId: launchLease.runId,
            )
          : null;
      if (temporarySetup != null) {
        // Commit the discoverable repair association before the detached
        // runner is started; session_meta is supplementary to the project WAL.
        _writeSessionMeta({
          ...?_readSessionMeta(),
          'temporarySetup': temporarySetup.toJson(),
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        });
      }
      final flutterArgs = <String>[
        'run',
        '-d',
        resolvedDevice.id,
        if (temporarySetup != null) '--no-pub',
        if (temporarySetup != null) ...[
          '--target',
          temporarySetup.targetPath,
        ] else if (parsed.option('target') != null) ...[
          '--target',
          parsed.option('target')!,
        ],
        if (parsed.option('flavor') != null) ...[
          '--flavor',
          parsed.option('flavor')!,
        ],
        ..._prepareDartDefineFlutterArgs(
          inline: parsed.multiOption('dart-define'),
          files: parsed.multiOption('dart-define-from-file'),
        ),
        if (parsed.option('name')?.isNotEmpty ?? false) ...[
          '--dart-define',
          '$kScoutInstanceDefine=${parsed.option('name')}',
        ],
        // Tell the in-app helper the project root so it can write recordings
        // straight to <project>/.flutter_scout/recordings/ (macOS/desktop; the
        // iOS-sim sandbox can't reach it, so the CLI persists from the ext there).
        '--dart-define',
        '$kScoutProjectDefine=${Directory(project).absolute.path}',
        // Scope helper responses and mutation envelopes to this exact owned
        // run. Attach-only sessions bind their generated run id in requests.
        '--dart-define',
        '$kScoutRunIdDefine=${launchLease.runId}',
        if (parsed.flag('verbose')) '--verbose',
      ];

      _writeProgress('start_flutter_run', {
        'device': resolvedDevice.id,
        'deviceName': resolvedDevice.name,
        'project': project,
      });
      final launchTiming = _LaunchTiming(startedAt: DateTime.now());
      if (!Platform.script.isScheme('file')) {
        throw const ScoutCliException(
          'flutter_worker_unavailable',
          'Flutter Scout could not resolve its executable for the detached Flutter log worker.',
        );
      }
      final workerConfigFile = p.join(
        _sessionDir.path,
        'runs',
        launchLease.runId,
        'flutter_worker.json',
      );
      final workerExitFile = p.join(
        _sessionDir.path,
        'runs',
        launchLease.runId,
        'flutter_exit.json',
      );
      final supervisorOutputFile = p.join(
        _sessionDir.path,
        'runs',
        launchLease.runId,
        'supervisor.txt',
      );
      final supervisorStateFile = p.join(
        _sessionDir.path,
        'runs',
        launchLease.runId,
        'supervisor_state.json',
      );
      _writePrivateSessionJson(workerConfigFile, {
        'project': project,
        'device': resolvedDevice.id,
        'flutterExecutable': flutterExecutable,
        'flutterArgs': flutterArgs,
        'logFile': runLogFile,
        'vmUriFile': _vmUriFile,
        'sessionDirectory': _sessionDir.path,
        'runId': launchLease.runId,
        'exitFile': workerExitFile,
        'stateFile': supervisorStateFile,
        'persistentConfig': Platform.isMacOS,
        'supervised': Platform.isMacOS,
      });
      // launchd opens this path itself; pre-creating it under the private
      // session boundary preserves 0600 even before the first log line.
      _writePrivateSessionString(supervisorOutputFile, '');
      final supervisor = await _startFlutterRunnerSupervisor(
        configFile: workerConfigFile,
        runId: launchLease.runId,
        outputFile: supervisorOutputFile,
      );
      final supervisorOwnershipMeta = <String, dynamic>{
        'mode': 'scout_owned_flutter_run',
        'runId': launchLease.runId,
        'project': project,
        'device': resolvedDevice.id,
        'supervisor': supervisor.toJson(),
        'supervisorStateFile': supervisorStateFile,
      };
      _writePrivateSessionString(_deviceFile, resolvedDevice.id);
      _writeDeviceInfo(resolvedDevice);
      final initialWorkerPid = supervisor.workerPid;
      if (initialWorkerPid != null) {
        _writePrivateSessionString(_pidFile, initialWorkerPid.toString());
      }
      _writeSessionMeta({
        ...?_readSessionMeta(),
        ...launchProvenance,
        'supervisor': supervisor.toJson(),
        'exitFile': workerExitFile,
        'supervisorStateFile': supervisorStateFile,
        'workerPid': ?initialWorkerPid,
        'updatedAt': DateTime.now().toIso8601String(),
      });
      final signalSubscriptions = _installRunnerSignalHandlers(
        supervisor,
        supervisorOwnershipMeta,
      );

      final lines = <String>[];
      void handleLine(String line) {
        lines.add(line);
        launchTiming.observeLine(line);
        _writeLaunchProgressFromLine(line);
        if (lines.length > 200) {
          lines.removeAt(0);
        }
      }

      String? vmUri;
      var readLineCount = 0;
      var lastHeartbeat = DateTime.now();
      // A cold build is slow but not stuck: pod install alone can run for
      // minutes without printing. Give up on silence, not on elapsed time, so a
      // first macOS/iOS build is never killed while it is still making
      // progress. [hardDeadline] still bounds a runner that never finishes.
      var lastProgressAt = DateTime.now();
      var stopReason = 'hard_timeout';
      var reportedPostBuildWorkerUncertainty = false;
      final hardDeadline = DateTime.now().add(launchTimeout);
      while (DateTime.now().isBefore(hardDeadline)) {
        final logFile = File(runLogFile);
        if (logFile.existsSync()) {
          final currentLines = _readLogLinesSync(logFile);
          if (currentLines.length > readLineCount) {
            lastProgressAt = DateTime.now();
          }
          for (final line in currentLines.skip(readLineCount)) {
            handleLine(line);
            vmUri ??= _extractVmUri(line) ?? _extractFlutterToolVmUri(line);
          }
          readLineCount = currentLines.length;
          vmUri ??= _readVmUri();
          if (vmUri != null) {
            _writeProgress('vm_service_found');
          }
          if (vmUri != null) break;
        }
        final now = DateTime.now();
        final awaitPostBuildVmService = _shouldAwaitPostBuildVmService(
          now: now,
          buildDoneAt: launchTiming.buildDoneAt,
        );
        if (now.difference(lastProgressAt) >= launchIdleTimeout &&
            !awaitPostBuildVmService) {
          stopReason = 'idle_timeout';
          _writeProgress('launch_stalled', {
            'idleMs': now.difference(lastProgressAt).inMilliseconds,
            'logLines': readLineCount,
          });
          break;
        }
        if (now.difference(lastHeartbeat) >= const Duration(seconds: 15)) {
          lastHeartbeat = now;
          _writeProgress('launch_heartbeat', {
            'elapsedMs': now.difference(launchTiming.startedAt).inMilliseconds,
            'logLines': readLineCount,
            if (lines.isNotEmpty) 'lastLine': _compactProgressLine(lines.last),
          });
        }
        if (!await _runnerSupervisorAlive(supervisor)) {
          if (awaitPostBuildVmService) {
            if (!reportedPostBuildWorkerUncertainty) {
              reportedPostBuildWorkerUncertainty = true;
              _writeProgress('await_post_build_vm_service', {
                'graceMs': _postBuildVmServiceGrace.inMilliseconds,
                'buildDoneMs': launchTiming.buildDoneAt!
                    .difference(launchTiming.startedAt)
                    .inMilliseconds,
              });
            }
            // The URI handoff itself remains constrained to the designated
            // session file and is VM-validated below; this grace merely avoids
            // killing a proven post-build app because launchd momentarily
            // cannot identify its worker.
            await Future<void>.delayed(const Duration(milliseconds: 250));
            continue;
          }
          stopReason = 'runner_exited';
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      for (final subscription in signalSubscriptions) {
        await subscription.cancel();
      }

      if (vmUri == null) {
        await _stopRunnerSupervisor(supervisorOwnershipMeta);
        if (temporarySetup != null) {
          await _cleanupTemporaryHelper(temporarySetup);
          temporarySetup = null;
        }
        _writeSessionMeta({
          ...?_readSessionMeta(),
          'state': 'failed',
          'updatedAt': DateTime.now().toIso8601String(),
        });
        _printJson({
          'ok': false,
          'launched': false,
          'reason': 'vm_service_uri_not_found',
          'error': <String, Object?>{
            'code': 'vm_service_uri_not_found',
            'message':
                'Flutter Scout did not observe a VM service URI before the bounded launch wait ended.',
          },
          // Which of the three ways the wait ended. A hard_timeout or
          // idle_timeout means Scout stopped a runner that may still have
          // been building; raise --launch-timeout / --launch-idle-timeout
          // rather than assuming the build itself failed.
          'failureMode': stopReason,
          'launchTimeoutSeconds': launchTimeout.inSeconds,
          'launchIdleTimeoutSeconds': launchIdleTimeout.inSeconds,
          'pid': supervisor.workerPid,
          'supervisor': supervisor.toJson(),
          'timing': launchTiming.toJson(completedAt: DateTime.now()),
          'tailLogLines': lines.length > 20
              ? lines.sublist(lines.length - 20)
              : lines,
        }, success: false);
        return 1;
      }

      final wsUri = _normalizeVmUri(vmUri);
      _persistValidatedVmUri(wsUri);
      final flutterToolPid =
          await _findScoutFlutterToolPid(
            project: project,
            instanceName: instanceName,
          ) ??
          initialWorkerPid;
      if (flutterToolPid == null) {
        await _stopRunnerSupervisor(supervisorOwnershipMeta);
        throw const ScoutCliException(
          'flutter_runner_pid_not_found',
          'The supervised Flutter runner became ready but its process id '
              'could not be verified.',
        );
      }
      final flutterProcessIdentity = await _readProcessOwnershipIdentity(
        flutterToolPid,
        role: _flutterRunProcessRole,
      );
      _writePrivateSessionString(_pidFile, '$flutterToolPid');
      final vmLogListenerPid = await _startVmLogListener(
        vmUri: wsUri,
        logFile: runLogFile,
        ownerPid: flutterToolPid,
      );
      final vmLogListenerIdentity = vmLogListenerPid == null
          ? null
          : await _readProcessOwnershipIdentity(
              vmLogListenerPid,
              role: _vmLogListenerProcessRole,
            );
      _writeSessionMeta({
        'mode': 'scout_owned_flutter_run',
        'state': 'ready',
        'runId': launchLease.runId,
        'name': ?instanceName,
        'pid': flutterToolPid,
        'processIdentity': ?flutterProcessIdentity,
        'processIdentityUnavailable': flutterProcessIdentity == null,
        'vmLogListenerPid': ?vmLogListenerPid,
        if (vmLogListenerPid != null && vmLogListenerIdentity != null)
          'vmLogListener': {
            'pid': vmLogListenerPid,
            'processIdentity': vmLogListenerIdentity,
            'ownerPid': flutterToolPid,
            'ownerProcessIdentity': flutterProcessIdentity,
            'runId': launchLease.runId,
            'sessionDirectory': _sessionDir.path,
          },
        'supervisor': supervisor.toJson(),
        'exitFile': workerExitFile,
        'supervisorStateFile': supervisorStateFile,
        'workerPid': ?initialWorkerPid,
        'logFile': runLogFile,
        'project': project,
        'device': resolvedDevice.id,
        ...launchProvenance,
        'createdAt': launchLease.startedAt.toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
        if (temporarySetup != null) 'temporarySetup': temporarySetup.toJson(),
      });
      preserveTemporarySetupForOwnedRun = temporarySetup != null;
      _writeProgress('verify_vm_service', {'vmServiceUri': wsUri});
      final ready = await _waitScoutReady(wsUri);
      launchTiming.readyAt = DateTime.now();
      _printJson({
        'launched': true,
        'ready': ready.ready,
        if (!ready.ready) 'reason': ready.reason,
        if (!ready.ready) 'expected': ready.expected,
        'device': resolvedDevice.id,
        'deviceName': resolvedDevice.name,
        'deviceCategory': resolvedDevice.category,
        'project': project,
        'sourceIdentity': launchProvenance['sourceIdentity'],
        'flutterToolchain': launchProvenance['flutterToolchain'],
        'runId': launchLease.runId,
        'pid': flutterToolPid,
        'vmLogListenerPid': ?vmLogListenerPid,
        'supervisor': supervisor.toJson(),
        'vmServiceUri': wsUri,
        'logFile': runLogFile,
        'timing': launchTiming.toJson(completedAt: launchTiming.readyAt),
      });
      return ready.ready ? 0 : 1;
    } finally {
      if (temporarySetup != null && !preserveTemporarySetupForOwnedRun) {
        await _cleanupTemporaryHelper(temporarySetup);
      }
      launchLease.release();
    }
  }

  Future<int> _flutterRunWorker(List<String> args) async {
    final parser = ArgParser()..addOption('config');
    final parsed = parser.parse(args);
    final configPath = parsed.option('config');
    if (configPath == null || configPath.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'flutter-run-worker requires --config <path>.',
      );
    }
    final configFile = File(configPath);
    final decoded = jsonDecode(configFile.readAsStringSync());
    if (decoded is! Map) {
      throw const ScoutCliException(
        'invalid_worker_config',
        'The Flutter worker configuration is not a JSON object.',
      );
    }
    final config = Map<String, dynamic>.from(decoded);
    final project = config['project']?.toString();
    final flutterExecutable = config['flutterExecutable']?.toString();
    final logFile = config['logFile']?.toString();
    final exitFile = config['exitFile']?.toString();
    final stateFile = config['stateFile']?.toString();
    final vmUriFile = config['vmUriFile']?.toString();
    final sessionDirectory = config['sessionDirectory']?.toString();
    final flutterArgs = config['flutterArgs'];
    if (project == null ||
        project.isEmpty ||
        flutterExecutable == null ||
        flutterExecutable.isEmpty ||
        logFile == null ||
        logFile.isEmpty ||
        flutterArgs is! List) {
      throw const ScoutCliException(
        'invalid_worker_config',
        'The Flutter worker configuration is incomplete.',
      );
    }
    final flutterArgv = flutterArgs
        .map((value) => value.toString())
        .toList(growable: false);
    _preflightWorkerDartDefineFiles(flutterArgv, workingDirectory: project);

    if ((vmUriFile == null) != (sessionDirectory == null)) {
      throw const ScoutCliException(
        'invalid_worker_config',
        'The Flutter worker capability handoff configuration is incomplete.',
      );
    }
    if (vmUriFile != null && sessionDirectory != null) {
      final expected = _absoluteNormalized(
        p.join(sessionDirectory, 'vm_uri.txt'),
      );
      if (_absoluteNormalized(vmUriFile) != expected) {
        throw const ScoutCliException(
          'invalid_worker_config',
          'The Flutter worker capability handoff must use the designated '
              'session credential store.',
        );
      }
    }

    final writer = _LockedLogWriter(logFile);
    Future<void> writeLine(String stream, String line) {
      final timestamp = DateTime.now().toUtc().toIso8601String();
      final plain = _stripLogAnsi(line);
      final discovered =
          _extractVmUri(plain) ?? _extractFlutterToolVmUri(plain);
      if (discovered != null && vmUriFile != null && sessionDirectory != null) {
        try {
          final validated = _validatedVmServiceUri(discovered);
          _atomicWritePrivateString(
            vmUriFile,
            validated.normalized,
            boundary: sessionDirectory,
          );
        } on ScoutCliException {
          // The URI was registered before this log sink and is therefore
          // redacted below, but an invalid/remote endpoint is never handed to
          // the parent and can never trigger a connection.
        }
      }
      final sanitized = _redactActiveSensitiveText(plain);
      return writer.write('[$timestamp] [FLUTTER_$stream] $sanitized');
    }

    Map<String, dynamic> readState() {
      if (stateFile == null || stateFile.isEmpty) return <String, dynamic>{};
      try {
        final decoded = jsonDecode(File(stateFile).readAsStringSync());
        return decoded is Map
            ? Map<String, dynamic>.from(decoded)
            : <String, dynamic>{};
      } catch (_) {
        return <String, dynamic>{};
      }
    }

    void writeState(Map<String, Object?> state) {
      if (stateFile == null || stateFile.isEmpty) return;
      final file = File(stateFile);
      _atomicWritePrivateJson(file.path, state, boundary: file.parent.path);
    }

    final previousState = readState();
    final launchCount = (previousState['launchCount'] as num?)?.toInt() ?? 0;
    final workerStartedAt = DateTime.now().toUtc().toIso8601String();
    final workerProcessIdentity = await _readProcessOwnershipIdentity(
      pid,
      role: _flutterWorkerProcessRole,
    );
    var supervisorState = <String, Object?>{
      'runId': ?config['runId']?.toString(),
      'launchCount': launchCount + 1,
      'workerPid': pid,
      'workerStartedAt': workerStartedAt,
      'workerProcessIdentity': ?workerProcessIdentity,
      'workerProcessIdentityUnavailable': workerProcessIdentity == null,
      if (previousState['workerPid'] != null)
        'previousWorkerPid': previousState['workerPid'],
      if (previousState['workerStartedAt'] != null)
        'previousWorkerStartedAt': previousState['workerStartedAt'],
      if (launchCount > 0)
        'previousWorkerExitRecorded':
            previousState['workerExitingNormally'] == true,
    };
    writeState(supervisorState);

    final previousFlutterPid = switch (previousState['flutterPid']) {
      final num value => value.toInt(),
      final String value => int.tryParse(value),
      _ => null,
    };
    final recoveryMeta = <String, dynamic>{
      'mode': 'scout_owned_flutter_run',
      'runId': config['runId'],
      'project': project,
      'device': config['device'],
      'processIdentity': previousState['flutterProcessIdentity'],
    };
    final recoverExistingFlutter =
        config['supervised'] == true &&
        launchCount > 0 &&
        previousState['workerExitingNormally'] != true &&
        previousFlutterPid != null &&
        await _matchesOwnedFlutterRun(previousFlutterPid, recoveryMeta);
    final previousFlutterIdentityUncertain =
        config['supervised'] == true &&
        launchCount > 0 &&
        previousState['workerExitingNormally'] != true &&
        previousFlutterPid != null &&
        !recoverExistingFlutter &&
        await _processExists(previousFlutterPid);
    if (previousFlutterIdentityUncertain) {
      // Starting another Flutter tool while a process still occupies the
      // recorded PID can duplicate app launches and mutations. A stale or
      // reparented identity is not authority to adopt or terminate it, so the
      // supervisor records the repair state and exits successfully to prevent
      // launchd from repeatedly creating competing runners.
      supervisorState = {
        ...supervisorState,
        'ownershipUncertain': true,
        'uncertainFlutterPid': previousFlutterPid,
        'reason': 'previous_flutter_process_identity_mismatch',
        'workerExitingNormally': true,
      };
      writeState(supervisorState);
      await writer.close();
      return 0;
    }
    if (recoverExistingFlutter) {
      supervisorState = {
        ...supervisorState,
        'flutterPid': previousFlutterPid,
        'recoveredExistingFlutter': true,
        'recoveredAt': workerStartedAt,
      };
      writeState(supervisorState);
      String? requestedSignal;

      Future<bool> stillOwnsRecoveredFlutter() =>
          _matchesOwnedFlutterRun(previousFlutterPid, recoveryMeta);

      void forwardSignal(ProcessSignal signal) {
        unawaited(() async {
          if (await stillOwnsRecoveredFlutter()) {
            Process.killPid(previousFlutterPid, signal);
          }
        }());
      }

      final signalSubscriptions = <StreamSubscription<ProcessSignal>>[
        ProcessSignal.sigusr1.watch().listen((_) {
          forwardSignal(ProcessSignal.sigusr1);
        }),
        ProcessSignal.sigusr2.watch().listen((_) {
          forwardSignal(ProcessSignal.sigusr2);
        }),
        ProcessSignal.sigterm.watch().listen((_) {
          requestedSignal = ProcessSignal.sigterm.toString();
          forwardSignal(ProcessSignal.sigterm);
        }),
        ProcessSignal.sigint.watch().listen((_) {
          requestedSignal = ProcessSignal.sigint.toString();
          forwardSignal(ProcessSignal.sigint);
        }),
      ];
      try {
        while (await stillOwnsRecoveredFlutter()) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        final exitedAt = DateTime.now().toUtc().toIso8601String();
        final exitInfo = <String, Object?>{
          'runId': ?config['runId']?.toString(),
          'workerPid': pid,
          'flutterPid': previousFlutterPid,
          'requestedSignal': ?requestedSignal,
          'reason': 'recovered_flutter_process_exited',
          'exitedAt': exitedAt,
        };
        if (exitFile != null && exitFile.isNotEmpty) {
          final file = File(exitFile);
          _atomicWritePrivateJson(
            file.path,
            exitInfo,
            boundary: file.parent.path,
          );
        }
        supervisorState = {
          ...supervisorState,
          ...exitInfo,
          'workerExitingNormally': true,
        };
        writeState(supervisorState);
        return 0;
      } finally {
        for (final subscription in signalSubscriptions) {
          await subscription.cancel();
        }
        await writer.close();
      }
    }

    final child = await Process.start(
      flutterExecutable,
      flutterArgv,
      workingDirectory: project,
      environment: _flutterToolEnvironment(),
    );
    final childIdentity = await _readProcessOwnershipIdentity(
      child.pid,
      role: _flutterRunProcessRole,
    );
    supervisorState = {
      ...supervisorState,
      'flutterPid': child.pid,
      'flutterProcessIdentity': ?childIdentity,
      'flutterProcessIdentityUnavailable': childIdentity == null,
    };
    writeState(supervisorState);
    final childOwnershipMeta = <String, dynamic>{
      'mode': 'scout_owned_flutter_run',
      'runId': config['runId'],
      'project': project,
      'device': config['device'],
      'processIdentity': childIdentity,
    };
    final outputDrains = <Future<void>>[
      child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asyncMap((line) => writeLine('STDOUT', line))
          .drain<void>(),
      child.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asyncMap((line) => writeLine('STDERR', line))
          .drain<void>(),
    ];
    String? requestedSignal;
    void forwardChildSignal(ProcessSignal signal) {
      unawaited(() async {
        if (await _matchesOwnedFlutterRun(child.pid, childOwnershipMeta)) {
          if (Process.killPid(child.pid, signal)) {
            requestedSignal = signal.toString();
          }
        }
      }());
    }

    final signalSubscriptions = <StreamSubscription<ProcessSignal>>[
      ProcessSignal.sigusr1.watch().listen(
        (_) => forwardChildSignal(ProcessSignal.sigusr1),
      ),
      ProcessSignal.sigusr2.watch().listen(
        (_) => forwardChildSignal(ProcessSignal.sigusr2),
      ),
      ProcessSignal.sigterm.watch().listen((_) {
        forwardChildSignal(ProcessSignal.sigterm);
      }),
      ProcessSignal.sigint.watch().listen((_) {
        forwardChildSignal(ProcessSignal.sigint);
      }),
    ];
    try {
      final exitCode = await child.exitCode;
      await Future.wait(outputDrains);
      final exitedAt = DateTime.now().toUtc().toIso8601String();
      final exitInfo = <String, Object?>{
        'runId': ?config['runId']?.toString(),
        'workerPid': pid,
        'flutterPid': child.pid,
        'exitCode': exitCode,
        'requestedSignal': ?requestedSignal,
        'exitedAt': exitedAt,
      };
      if (exitFile != null && exitFile.isNotEmpty) {
        final file = File(exitFile);
        _atomicWritePrivateJson(
          file.path,
          exitInfo,
          boundary: file.parent.path,
        );
      }
      supervisorState = {
        ...supervisorState,
        ...exitInfo,
        'workerExitingNormally': true,
      };
      writeState(supervisorState);
      // launchd restarts the worker only when the worker itself is lost. A
      // normal Flutter-tool exit is recorded but must not create a relaunch
      // loop or unexpectedly reset the app.
      return config['supervised'] == true ? 0 : exitCode;
    } finally {
      for (final subscription in signalSubscriptions) {
        await subscription.cancel();
      }
      await writer.close();
      if (config['persistentConfig'] != true) {
        try {
          configFile.deleteSync();
        } catch (_) {}
      }
    }
  }

  String _compactProgressLine(String line) {
    final sanitized = _redactSensitiveLogText(_stripLogMetadata(line));
    return sanitized.length <= 180
        ? sanitized
        : '${sanitized.substring(0, 177)}...';
  }

  Future<String?> _discoverBundledHelperPath() async {
    final candidates = <String>[
      p.normalize(p.join(Directory.current.path, '..', 'flutter_scout_helper')),
      p.normalize(
        p.join(Directory.current.path, 'packages', 'flutter_scout_helper'),
      ),
    ];
    for (final candidate in candidates) {
      if (File(p.join(candidate, 'pubspec.yaml')).existsSync()) {
        return candidate;
      }
    }
    if (Platform.script.isScheme('file')) {
      var cursor = Directory(p.dirname(Platform.script.toFilePath()));
      for (var depth = 0; depth < 8; depth++) {
        for (final candidate in [
          p.join(cursor.path, 'packages', 'flutter_scout_helper'),
          p.join(cursor.path, 'flutter_scout_helper'),
        ]) {
          if (File(p.join(candidate, 'pubspec.yaml')).existsSync()) {
            return p.normalize(candidate);
          }
        }
        final parent = cursor.parent;
        if (parent.path == cursor.path) break;
        cursor = parent;
      }
    }
    return null;
  }

  String _newAttachRunId() {
    final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );
    final entropy = Random.secure().nextInt(0x100000000);
    return 'attach-$timestamp-$pid-${entropy.toRadixString(16).padLeft(8, '0')}';
  }

  Future<_LaunchLease> _acquireLaunchLease({
    required String project,
    required String device,
    required String? name,
  }) async {
    _ensureSessionDir();
    final startedAt = DateTime.now();
    final runId =
        '${startedAt.toUtc().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '')}-$pid';
    final file = File(_launchLockFile);
    final infoFile = File(_launchLockInfoFile);
    final normalizedLockPath = _absoluteNormalized(file.path);
    if (!_heldLaunchLeasePaths.add(normalizedLockPath)) {
      throw _launchInProgress(_readLaunchInfo());
    }

    RandomAccessFile? handle;
    var locked = false;
    try {
      _assertPrivateFilePath(file.path, boundary: _sessionDir.path);
      if (!file.existsSync()) {
        try {
          file.createSync(exclusive: true);
        } on FileSystemException {
          // A concurrent process may have created the stable control inode.
          // Its object and permissions are checked immediately below.
        }
      }
      _securePrivateFile(file.path, boundary: _sessionDir.path);
      handle = file.openSync(mode: FileMode.append);
      try {
        // `exclusive` is intentionally non-blocking. A launch command must
        // abstain instead of waiting behind a possibly minutes-long build.
        handle.lockSync(FileLock.exclusive);
        locked = true;
      } on FileSystemException {
        throw _launchInProgress(_readLaunchInfo());
      }

      // Old versions stored owner JSON directly in launch.lock. Clear those
      // bytes only after acquiring the stable inode's exclusive kernel lease.
      handle.truncateSync(0);
      handle.flushSync();
      _atomicWritePrivateJson(infoFile.path, <String, Object?>{
        'schemaVersion': 1,
        'lease': 'kernel_exclusive',
        'ownerPid': pid,
        'runId': runId,
        'name': ?name,
        'project': project,
        'device': device,
        'startedAt': startedAt.toIso8601String(),
      }, boundary: _sessionDir.path);
      return _LaunchLease(
        controlFile: file,
        infoFile: infoFile,
        handle: handle,
        runId: runId,
        startedAt: startedAt,
      );
    } catch (_) {
      if (locked) {
        try {
          handle?.unlockSync();
        } catch (_) {}
      }
      try {
        handle?.closeSync();
      } catch (_) {}
      _heldLaunchLeasePaths.remove(normalizedLockPath);
      rethrow;
    }
  }

  Map<String, dynamic>? _readLaunchInfo() {
    final file = File(_launchLockInfoFile);
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      _unsafeStoragePath(
        file.path,
        'launch lease metadata is not a regular file',
      );
    }
    try {
      _assertPrivateFilePath(
        file.path,
        boundary: _sessionDir.path,
        allowMissing: false,
      );
      if (file.statSync().size > 64 * 1024) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  ScoutCliException _launchInProgress(Map<String, dynamic>? info) {
    return ScoutCliException(
      'launch_in_progress',
      'Another Flutter Scout launch holds this session lease. '
          'Use `ensure` to join it, or wait for it to become ready.',
      details: <String, Object?>{
        'leaseStatus': 'held',
        'ownerPid': info?['ownerPid'],
        'runId': info?['runId'],
        'startedAt': info?['startedAt'],
      },
    );
  }

  Future<bool> _launchLeaseIsHeld() async {
    final file = File(_launchLockFile);
    final normalizedLockPath = _absoluteNormalized(file.path);
    if (_heldLaunchLeasePaths.contains(normalizedLockPath)) return true;
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file) return true;

    RandomAccessFile? handle;
    try {
      _assertPrivateFilePath(
        file.path,
        boundary: _sessionDir.path,
        allowMissing: false,
      );
      handle = file.openSync(mode: FileMode.append);
      handle.lockSync(FileLock.exclusive);
      handle.unlockSync();
      return false;
    } on FileSystemException {
      // Contention and unexpected filesystem failures both fail closed.
      return true;
    } finally {
      try {
        handle?.closeSync();
      } catch (_) {}
    }
  }

  Future<void> _joinLaunchIfNeeded(
    void Function(String stage, [Map<String, Object?> extra]) progress,
  ) async {
    if (!await _launchLeaseIsHeld()) return;
    final info = _readLaunchInfo();
    progress('join_launch', {
      'runId': info?['runId'],
      'ownerPid': info?['ownerPid'],
      'startedAt': info?['startedAt'],
    });
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(deadline)) {
      final uri = _readVmUri();
      if (uri != null && (await _validateVmUri(uri)).ok) return;
      if (!await _launchLeaseIsHeld()) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw const ScoutCliException(
      'launch_join_timeout',
      'The existing Flutter Scout launch did not become ready within 5 minutes.',
    );
  }

  Future<int> _attach(List<String> args) async {
    final parser = ArgParser()
      ..addOption('debug-url')
      ..addOption('debug-url-file')
      ..addFlag('debug-url-stdin', defaultsTo: false, negatable: false)
      ..addOption('device')
      ..addFlag('json', defaultsTo: true);
    final parsed = parser.parse(args);
    final explicit = _protectedVmUriInput(parsed);
    final discovered = await _discoverAttachVmUri(
      explicit: explicit,
      device: parsed.option('device'),
    );
    if (discovered.uri == null || discovered.uri!.isEmpty) {
      _printJson({
        'attached': false,
        'reason': discovered.reason ?? 'vm_service_uri_not_found',
        if (discovered.staleUri != null)
          'staleVmServiceUri': discovered.staleUri,
        if (discovered.staleCleared) 'staleCleared': true,
        'nextBestActions': [
          'Run the app in debug/profile mode and copy the VM Service URL',
          'flutter-scout attach --debug-url-file <owner-only-0600-file>',
          'flutter-scout launch --device <simulator-id> --project .',
        ],
      });
      return 1;
    }

    final wsUri = discovered.uri!;
    final previousVmUri = _readVmUri();
    _ensureSessionDir();
    _persistValidatedVmUri(wsUri);
    final previousMeta = _readSessionMeta();
    final previousPid =
        _readPid() ?? int.tryParse('${previousMeta?['pid'] ?? ''}');
    final ownedLogUri = _discoverVmUriFromScoutLog();
    final preservesOwnedRun =
        previousPid != null &&
        await _matchesOwnedFlutterRun(previousPid, previousMeta) &&
        ownedLogUri != null &&
        _normalizeVmUri(ownedLogUri) == _normalizeVmUri(wsUri);
    final now = DateTime.now().toIso8601String();
    // Do not turn a run mismatch into permission to control some other local
    // app. The only reconciliation allowed is a helper that proves it still
    // carries this session's prior Scout launch identity. The endpoint has
    // already passed strict loopback validation in _discoverAttachVmUri.
    final helperIdentity = preservesOwnedRun
        ? null
        : await _readAttachedHelperIdentity(wsUri);
    final reconciledIdentity = helperIdentity == null
        ? null
        : _reconcileAttachRunIdentity(
            previousMeta: previousMeta,
            helperRunId: helperIdentity.runId,
            runtimeInstanceId: helperIdentity.runtimeInstanceId,
            requestedDevice: parsed.option('device'),
          );
    final reusesAttachedRun =
        previousMeta?['mode'] == 'attach_only' &&
        previousMeta?['runId'] != null &&
        previousVmUri != null &&
        _normalizeVmUri(previousVmUri) == _normalizeVmUri(wsUri);
    final attachRunId = reusesAttachedRun
        ? previousMeta!['runId']!.toString()
        : _newAttachRunId();
    final ownedRunId = previousMeta == null
        ? null
        : previousMeta['runId']?.toString();
    final effectiveRunId = preservesOwnedRun
        ? ownedRunId ?? _newAttachRunId()
        : reconciledIdentity?['runId']?.toString() ?? attachRunId;
    if (preservesOwnedRun) {
      _writePrivateSessionString(_pidFile, '$previousPid');
      _writeSessionMeta({
        ...?previousMeta,
        'mode': 'scout_owned_flutter_run',
        'state': 'ready',
        'runId': effectiveRunId,
        'vmServiceUri': wsUri,
        'pid': previousPid,
        if (parsed.option('device') != null) 'device': parsed.option('device'),
        'createdAt': previousMeta?['createdAt'] ?? now,
        'updatedAt': now,
      });
      await _ensureVmLogListenerForCurrentSession(wsUri);
    } else {
      // An attach-only session never inherits process ownership from whatever
      // session occupied this directory previously.
      _deleteFileIfExists(_pidFile);
      _deleteFileIfExists(_vmLogListenerPidFile);
      _writeSessionMeta({
        'mode': 'attach_only',
        'state': 'ready',
        'runId': effectiveRunId,
        'vmServiceUri': wsUri,
        if (parsed.option('device') != null) 'device': parsed.option('device'),
        'createdAt': now,
        'updatedAt': now,
        if (reconciledIdentity != null)
          'runIdentityRecovery': <String, Object?>{
            ...reconciledIdentity,
            'source': 'verified_local_vm_helper',
            'recoveredAt': now,
          },
      });
    }
    final output = <String, Object?>{
      'attached': true,
      'reusedRunningApp': true,
      'vmServiceUri': wsUri,
      'runId': effectiveRunId,
      'appStatePreserved': true,
      'attachOnly': !preservesOwnedRun,
      if (preservesOwnedRun) 'sessionOwnershipPreserved': true,
      if (reconciledIdentity != null) 'runIdentityRecovered': true,
    };
    final device = parsed.option('device');
    if (device != null && device.isNotEmpty) {
      _writePrivateSessionString(_deviceFile, device);
      final resolvedDevice = await _resolveFlutterDevice(device);
      if (resolvedDevice != null) {
        _writeDeviceInfo(resolvedDevice);
        output['deviceName'] = resolvedDevice.name;
        output['devicePlatform'] = resolvedDevice.platform;
        output['deviceCategory'] = resolvedDevice.category;
      } else {
        _deleteFileIfExists(_deviceInfoFile);
      }
    }
    final ready = await _waitScoutReady(wsUri);
    output['ready'] = ready.ready;
    if (!ready.ready) {
      output['reason'] = ready.reason;
      output['expected'] = ready.expected;
    }
    if (device != null) {
      output['device'] = device;
    }
    _printJson(output);
    return ready.ready ? 0 : 1;
  }

  /// Reads the helper's already-bound identity without sending a run ID. A
  /// read request cannot dispatch UI work, and omitting runId is important:
  /// an unbound helper remains free for the ordinary attach flow to bind to
  /// the new attach identity later.
  Future<_AttachedHelperIdentity?> _readAttachedHelperIdentity(
    String vmUri,
  ) async {
    VmService? service;
    try {
      service = await _connect(vmUri);
      final isolateId = await _findMainIsolate(service);
      final response = await _invokeServiceExtension(
        service: service,
        isolateId: isolateId,
        method: 'ext.flutter_scout.inspect',
        params: const <String, String>{'brief': 'true', 'maxItems': '1'},
        timeout: const Duration(seconds: 5),
      );
      final runId = response['runId']?.toString();
      final runtimeInstanceId = response['runtimeInstanceId']?.toString();
      if (response['ok'] != true ||
          runId == null ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(runId) ||
          runtimeInstanceId == null ||
          !RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(runtimeInstanceId)) {
        return null;
      }
      return _AttachedHelperIdentity(
        runId: runId,
        runtimeInstanceId: runtimeInstanceId,
      );
    } catch (_) {
      // Identity recovery is optional. Failure deliberately falls back to the
      // existing inspect-only attach posture instead of weakening the guard.
      return null;
    } finally {
      await service?.dispose();
    }
  }

  Future<int> _ensure(List<String> args) async {
    final parser = ArgParser()
      ..addOption('debug-url')
      ..addOption('debug-url-file')
      ..addFlag('debug-url-stdin', defaultsTo: false, negatable: false)
      ..addOption('device')
      ..addOption('project', defaultsTo: Directory.current.path)
      ..addOption('target')
      ..addOption('flavor')
      ..addOption('name')
      ..addFlag('temporary-helper', defaultsTo: false, negatable: false)
      ..addOption('helper-path')
      ..addMultiOption(
        'dart-define',
        splitCommas: false,
        help:
            'Deprecated for inline values and rejected when secret-looking. '
            'Prefer --dart-define-from-file.',
      )
      ..addMultiOption(
        'dart-define-from-file',
        splitCommas: false,
        help:
            'Read Flutter defines from a bounded, strict-UTF-8, regular '
            'non-symlink file that is exactly 0600 on POSIX.',
      )
      ..addOption(
        'launch-timeout',
        help:
            'Hard ceiling in seconds for a launch to produce a VM service URI '
            '(default 1200). Raise it for very slow first builds.',
      )
      ..addOption(
        'launch-idle-timeout',
        help:
            'Give up when the runner prints nothing for this many seconds '
            '(default 180). This, not elapsed time, is what ends a stuck build.',
      )
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final device = parsed.option('device');
    void progress(String stage, [Map<String, Object?> extra = const {}]) {
      _writeHeartbeat(stage, extra, false);
    }

    final instanceName = parsed.option('name');
    if (instanceName != null && instanceName.isNotEmpty) {
      _registerScoutSession(
        instanceName,
        _sessionDir.path,
        project: _canonicalProjectDirectory(parsed.option('project')!),
      );
    }
    await _joinLaunchIfNeeded(progress);
    progress('discover_vm_service', {'device': ?device});
    // Every step inside discovery is individually bounded, but a hard phase
    // ceiling guarantees ensure can never sit silent for minutes — fail with
    // a structured error instead.
    final discovered =
        await _discoverAttachVmUri(
          explicit: _protectedVmUriInput(parsed),
          device: device,
        ).timeout(
          const Duration(seconds: 60),
          onTimeout: () => throw const ScoutCliException(
            'ensure_discovery_timeout',
            'VM-service discovery did not complete within 60s. Run '
                'flutter-scout stop --clear-session, then retry; if it '
                'persists, launch directly with flutter-scout launch.',
          ),
        );
    if (discovered.uri != null && discovered.uri!.isNotEmpty) {
      progress('reuse_check', {'vmServiceUri': discovered.uri});
      final ready = await _waitScoutReady(discovered.uri!);
      if (!ready.ready) {
        progress('reuse_not_ready', {
          'reason': ?ready.reason,
          'detail': ?ready.detail,
        });
      }
      if (ready.ready) {
        _ensureSessionDir();
        _persistValidatedVmUri(discovered.uri!);
        await _reconcileReachableSessionOwnership(discovered.uri!);
        final ownershipLost = _sessionOwnershipWasLost();
        final pid = _readPid();
        final previousMeta = _readSessionMeta();
        final scoutOwned =
            pid != null && await _matchesOwnedFlutterRun(pid, previousMeta);
        final now = DateTime.now().toIso8601String();
        if (!scoutOwned) {
          // Reusing a reachable human-owned app must drop stale ownership
          // artifacts before any later `stop` command inspects the session.
          _deleteFileIfExists(_pidFile);
          _deleteFileIfExists(_vmLogListenerPidFile);
        }
        _writeSessionMeta(
          scoutOwned
              ? {
                  // Preserve the owning run's identity, listener, log path,
                  // and temporary-helper cleanup record on reuse.
                  ...?previousMeta,
                  'mode': 'scout_owned_flutter_run',
                  'state': 'ready',
                  'vmServiceUri': discovered.uri,
                  'pid': pid,
                  'logFile': _logFile,
                  'device': ?device,
                  'createdAt': previousMeta?['createdAt'] ?? now,
                  'updatedAt': now,
                }
              : ownershipLost
              ? {
                  ...?previousMeta,
                  'mode': 'attach_only',
                  'state': 'ready',
                  'runId': previousMeta?['runId'] ?? _newAttachRunId(),
                  'vmServiceUri': discovered.uri,
                  'device': ?device,
                  'updatedAt': now,
                }
              : {
                  'mode': 'attach_only',
                  'state': 'ready',
                  'runId': _newAttachRunId(),
                  'vmServiceUri': discovered.uri,
                  'device': ?device,
                  'createdAt': now,
                  'updatedAt': now,
                },
        );
        if (device != null && device.isNotEmpty) {
          _writePrivateSessionString(_deviceFile, device);
          final resolvedDevice = await _resolveFlutterDevice(device);
          if (resolvedDevice != null) {
            _writeDeviceInfo(resolvedDevice);
          } else {
            _deleteFileIfExists(_deviceInfoFile);
          }
        }
        _printJson({
          'ensured': true,
          'reusedRunningApp': true,
          'appStatePreserved': true,
          'ready': true,
          'vmServiceUri': discovered.uri,
          'runId': ?_currentRunIdFromSession(),
          'device': ?device,
          'attachOnly': !scoutOwned,
          if (ownershipLost) 'sessionOwnershipLost': true,
          'hotUpdate': await _hotUpdateCapability(discovered.uri!),
        });
        return 0;
      }
    } else {
      progress('no_reusable_session', {'reason': ?discovered.reason});
    }

    progress('fallback_launch', {'device': ?device});
    final launchArgs = <String>[
      if (device != null && device.isNotEmpty) ...['--device', device],
      '--project',
      parsed.option('project')!,
      if (parsed.option('target') != null) ...[
        '--target',
        parsed.option('target')!,
      ],
      if (parsed.option('flavor') != null) ...[
        '--flavor',
        parsed.option('flavor')!,
      ],
      for (final value in parsed.multiOption('dart-define')) ...[
        '--dart-define',
        value,
      ],
      for (final value in parsed.multiOption('dart-define-from-file')) ...[
        '--dart-define-from-file',
        value,
      ],
      if (parsed.option('name')?.isNotEmpty ?? false) ...[
        '--name',
        parsed.option('name')!,
      ],
      if (parsed.flag('temporary-helper')) '--temporary-helper',
      if (parsed.option('helper-path') != null) ...[
        '--helper-path',
        parsed.option('helper-path')!,
      ],
      if (parsed.option('launch-timeout') != null) ...[
        '--launch-timeout',
        parsed.option('launch-timeout')!,
      ],
      if (parsed.option('launch-idle-timeout') != null) ...[
        '--launch-idle-timeout',
        parsed.option('launch-idle-timeout')!,
      ],
      if (parsed.flag('verbose')) '--verbose',
    ];
    if (device == null || device.isEmpty) {
      throw const ScoutCliException(
        'missing_device',
        'Usage: flutter-scout ensure --device <simulator-id> [--project <path>]',
      );
    }
    return _launch(launchArgs);
  }

  Future<int> _status() async {
    final payload = await _statusPayload();
    final project =
        _readSessionMeta()?['project']?.toString() ?? Directory.current.path;
    final temporaryHelper = Directory(project).existsSync()
        ? await _recoverTemporaryHelperProject(project, preserveLive: true)
        : const <String, Object?>{'status': 'not_applicable'};
    _printJson(<String, Object?>{
      ...payload,
      'temporaryHelperRecovery': temporaryHelper,
    });
    return 0;
  }

  Future<int> _devices(List<String> args) async {
    if (args.isNotEmpty) {
      throw const ScoutCliException('usage', 'Usage: flutter-scout devices');
    }
    final result =
        await Process.run('flutter', [
          'devices',
          '--machine',
        ], environment: _flutterToolEnvironment()).timeout(
          const Duration(seconds: 20),
          onTimeout: () => ProcessResult(0, 1, '', 'flutter devices timed out'),
        );
    if (result.exitCode != 0) {
      throw ScoutCliException(
        'device_discovery_failed',
        '${result.stderr}'.trim(),
      );
    }
    final decoded = jsonDecode('${result.stdout}');
    if (decoded is! List) {
      throw const ScoutCliException(
        'device_discovery_failed',
        'flutter devices --machine returned an unexpected payload.',
      );
    }
    _printJson({
      'ok': true,
      'devices': [
        for (final item in decoded)
          if (item is Map && item['isSupported'] != false)
            {
              'id': item['id'],
              'name': item['name'],
              'platform': item['targetPlatform'],
              'emulator': item['emulator'] == true,
              'screenshot': item['capabilities'] is Map
                  ? (item['capabilities'] as Map)['screenshot'] == true
                  : false,
            },
      ],
    });
    return 0;
  }

  /// Lists sessions registered via launch/ensure `--name`, addressable with
  /// the global `--app <name>` option.
  Future<int> _apps(List<String> args) async {
    final parser = ArgParser()
      ..addFlag(
        'all',
        defaultsTo: false,
        negatable: false,
        help: 'Include registry entries whose session directory is missing.',
      )
      ..addFlag(
        'prune',
        defaultsTo: false,
        negatable: false,
        help: 'Remove missing session directories from the registry.',
      );
    final parsed = parser.parse(args);
    final registry = _readScoutRegistry();
    final missing = registry.entries
        .where((entry) => !Directory(entry.value).existsSync())
        .toList(growable: false);
    if (parsed.flag('prune') && missing.isNotEmpty) {
      for (final entry in missing) {
        registry.remove(entry.key);
      }
      _writeScoutRegistry(registry);
    }
    _printJson({
      'ok': true,
      if (parsed.flag('prune')) 'pruned': missing.length,
      'sessions': [
        for (final entry in registry.entries)
          if (parsed.flag('all') || Directory(entry.value).existsSync())
            {
              'name': entry.key,
              'directory': entry.value,
              'exists': Directory(entry.value).existsSync(),
            },
      ],
    });
    return 0;
  }

  Future<Map<String, Object?>> _statusPayload() async {
    final vmUri = _readVmUri();
    if (vmUri == null) {
      final recovered = await _recoverMissingOwnedVmUri();
      if (recovered != null) {
        final runtimeObservation = await _observeRuntimeOperability();
        return {
          'running': true,
          'appReachable': runtimeObservation['appReachability'] == 'reachable',
          'vmServiceUri': recovered.uri,
          'missingVmServiceUriRestored': true,
          'refreshSource': recovered.source,
          if (_readDevice() != null) 'device': _readDevice(),
          if (_readDeviceInfo() != null) 'deviceInfo': _readDeviceInfo(),
          'session': _sessionModeInfo(),
          'hotUpdate': await _hotUpdateCapability(recovered.uri),
          'runtimeObservation': runtimeObservation,
          'lastHotUpdate': _readSessionMeta()?['lastHotUpdate'],
        };
      }
      final meta = _readSessionMeta();
      final recordedOwner = int.tryParse('${meta?['pid'] ?? ''}');
      if (meta?['mode'] == 'scout_owned_flutter_run' &&
          meta?['state'] == 'ready' &&
          (recordedOwner == null ||
              !await _matchesOwnedFlutterRun(recordedOwner, meta))) {
        await _markSessionStopped('owner_process_exited');
      }
      final launch = _readLaunchInfo();
      final launching = await _launchLeaseIsHeld();
      return {
        'running': false,
        'appReachable': false,
        if (launching) 'launching': true,
        if (launching) 'launch': launch,
        'session': _sessionModeInfo(),
        if (_readDevice() != null) 'device': _readDevice(),
        if (_readDeviceInfo() != null) 'deviceInfo': _readDeviceInfo(),
        'runtimeObservation': _unavailableRuntimeOperability(
          launching ? 'launch_in_progress' : 'vm_service_uri_unavailable',
        ),
        'lastHotUpdate': _readSessionMeta()?['lastHotUpdate'],
      };
    }
    final stale = await _validateVmUri(vmUri);
    if (stale.ok) {
      await _reconcileReachableSessionOwnership(vmUri);
      final ownershipLost = _sessionOwnershipWasLost();
      await _ensureVmLogListenerForCurrentSession(vmUri);
      final runtimeObservation = await _observeRuntimeOperability();
      return {
        'running': true,
        'appReachable': runtimeObservation['appReachability'] == 'reachable',
        'vmServiceUri': vmUri,
        if (ownershipLost) 'sessionOwnershipLost': true,
        if (_readDevice() != null) 'device': _readDevice(),
        if (_readDeviceInfo() != null) 'deviceInfo': _readDeviceInfo(),
        'session': _sessionModeInfo(),
        'hotUpdate': await _hotUpdateCapability(vmUri),
        'runtimeObservation': runtimeObservation,
        'lastHotUpdate': _readSessionMeta()?['lastHotUpdate'],
      };
    }
    final refreshed = await _refreshStaleVmUri(staleUri: vmUri);
    if (refreshed != null) {
      await _reconcileReachableSessionOwnership(refreshed.uri);
      final ownershipLost = _sessionOwnershipWasLost();
      final runtimeObservation = await _observeRuntimeOperability();
      return {
        'running': true,
        'appReachable': runtimeObservation['appReachability'] == 'reachable',
        'vmServiceUri': refreshed.uri,
        'staleVmServiceUri': vmUri,
        'staleRefreshed': true,
        'refreshSource': refreshed.source,
        if (ownershipLost) 'sessionOwnershipLost': true,
        if (_readDevice() != null) 'device': _readDevice(),
        if (_readDeviceInfo() != null) 'deviceInfo': _readDeviceInfo(),
        'session': _sessionModeInfo(),
        'hotUpdate': await _hotUpdateCapability(refreshed.uri),
        'runtimeObservation': runtimeObservation,
        'lastHotUpdate': _readSessionMeta()?['lastHotUpdate'],
      };
    }
    _clearVmUriFile();
    await _markSessionStopped('stale_vm_service');
    return {
      'running': false,
      'appReachable': false,
      'staleVmServiceUri': vmUri,
      'staleCleared': true,
      'session': _sessionModeInfo(),
      if (_readDevice() != null) 'device': _readDevice(),
      if (_readDeviceInfo() != null) 'deviceInfo': _readDeviceInfo(),
      'runtimeObservation': _unavailableRuntimeOperability(
        'stale_vm_service_unreachable',
      ),
      'lastHotUpdate': _readSessionMeta()?['lastHotUpdate'],
      if (stale.error != null) 'reason': stale.error,
    };
  }

  Future<void> _markSessionStopped(String reason) async {
    final meta = _readSessionMeta();
    final listenerPid = _readVmLogListenerPid();
    if (listenerPid != null) {
      if (await _matchesOwnedVmLogListener(listenerPid, meta)) {
        Process.killPid(listenerPid);
      }
      _deleteFileIfExists(_vmLogListenerPidFile);
    }
    if (meta != null) {
      final stopped =
          <String, Object?>{
              ...meta,
              'state': 'stopped',
              'stopReason': reason,
              'updatedAt': DateTime.now().toUtc().toIso8601String(),
            }
            ..remove('vmLogListenerPid')
            ..remove('vmLogListener');
      _writeSessionMeta(stopped);
    }
  }

  Future<int> _doctor(List<String> args) async {
    final parser = ArgParser()
      ..addOption('project', defaultsTo: Directory.current.path)
      ..addOption('device');
    final parsed = parser.parse(args);
    final project = p.normalize(p.absolute(parsed.option('project')!));
    final projectDir = Directory(project);
    final pubspec = File(p.join(project, 'pubspec.yaml'));
    final mainFile = File(p.join(project, 'lib', 'main.dart'));
    final device = parsed.option('device');
    final resolvedDevice = device == null || device.isEmpty
        ? null
        : await _resolveFlutterDevice(device);
    final temporaryHelperRecovery = projectDir.existsSync()
        ? await _recoverTemporaryHelperProject(project, preserveLive: true)
        : const <String, Object?>{'status': 'not_applicable'};
    final vmUri = _readVmUri();
    final session = vmUri == null
        ? const _VmUriValidation(ok: false, error: 'no_session_vm_uri')
        : await _validateVmUri(vmUri);

    var runtimeObservation = _unavailableRuntimeOperability(
      session.error ?? 'vm_service_unavailable',
    );
    var helperExtensionRegistered = false;
    String? helperExtensionError;
    if (session.ok && vmUri != null) {
      runtimeObservation = await _observeRuntimeOperability();
      helperExtensionRegistered = runtimeObservation['status'] == 'observed';
      helperExtensionError = helperExtensionRegistered
          ? null
          : _nonEmptyString(runtimeObservation['reason']);
    }

    final pubspecText = pubspec.existsSync() ? pubspec.readAsStringSync() : '';
    final mainText = mainFile.existsSync() ? mainFile.readAsStringSync() : '';
    final resolvedHelper = _resolvedPackageInfo(
      project,
      'flutter_scout_helper',
    );
    _printJson({
      'ok': true,
      'cli': {
        'available': true,
        'version': FlutterScoutCli.packageVersion,
        'helperProtocolExpected': FlutterScoutCli.expectedHelperProtocolVersion,
        'sessionDir': _sessionDir.path,
        'executable': Platform.resolvedExecutable,
        'script': Platform.script.toString(),
      },
      'project': {
        'path': project,
        'exists': projectDir.existsSync(),
        'pubspecExists': pubspec.existsSync(),
        'mainExists': mainFile.existsSync(),
        'hasHelperDependency': pubspecText.contains('flutter_scout_helper'),
        'hasBindingInitializer': mainText.contains(
          'FlutterScoutBinding.ensureInitialized',
        ),
        'hasRegistrationInitializer': mainText.contains(
          'FlutterScoutHelper.ensureRegistered',
        ),
        'resolvedHelper': resolvedHelper,
        'temporaryHelper': {
          'supported': true,
          'trackedFilesRemainClean': true,
          'crashSafeTransaction': true,
          'recovery': temporaryHelperRecovery,
          'command':
              'flutter-scout ensure --temporary-helper --device <device> --project $project --name <session>',
        },
      },
      'device': {
        'requested': device,
        'resolved': resolvedDevice?.toJson(),
        if (device != null && device.isNotEmpty)
          'exactMatch': resolvedDevice != null,
      },
      'session': {
        'vmServiceUri': vmUri,
        'valid': session.ok,
        if (session.error != null) 'error': session.error,
        'helperExtensionRegistered': helperExtensionRegistered,
        ...helperExtensionError == null
            ? const <String, Object?>{}
            : {'helperExtensionError': helperExtensionError},
      },
      'sessionState': _sessionModeInfo(),
      if (_readDeviceInfo() != null) 'deviceInfo': _readDeviceInfo(),
      'appReachable': runtimeObservation['appReachability'] == 'reachable',
      'runtimeObservation': runtimeObservation,
      'lastHotUpdate': _readSessionMeta()?['lastHotUpdate'],
    });
    return 0;
  }

  Map<String, Object?>? _resolvedPackageInfo(
    String project,
    String packageName,
  ) {
    final config = File(p.join(project, '.dart_tool', 'package_config.json'));
    if (!config.existsSync()) return null;
    try {
      final decoded = jsonDecode(config.readAsStringSync());
      if (decoded is! Map || decoded['packages'] is! List) return null;
      for (final value in decoded['packages'] as List) {
        if (value is! Map || value['name'] != packageName) continue;
        final rootUri = value['rootUri']?.toString();
        if (rootUri == null || rootUri.isEmpty) return null;
        final resolved = config.uri.resolve(rootUri);
        final rootPath = resolved.isScheme('file')
            ? resolved.toFilePath()
            : resolved.toString();
        final packagePubspec = File(p.join(rootPath, 'pubspec.yaml'));
        String? version;
        if (packagePubspec.existsSync()) {
          final match = RegExp(
            r'^version:\s*(\S+)',
            multiLine: true,
          ).firstMatch(packagePubspec.readAsStringSync());
          version = match?.group(1);
        }
        return {'rootUri': rootUri, 'rootPath': rootPath, 'version': ?version};
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<int> _stop(List<String> args) async {
    final parser = ArgParser()
      ..addFlag('clear-session', defaultsTo: false, negatable: false)
      ..addFlag('quiet', defaultsTo: false, negatable: false, hide: true);
    final parsed = parser.parse(args);
    final sessionMeta = _readSessionMeta();
    final serve = sessionMeta?['serve'];
    final servePid = serve is Map
        ? int.tryParse('${serve['pid'] ?? ''}')
        : null;
    final temporarySetup = _temporarySetupFromMeta();
    final pid = _readPid();
    final vmUri = _readVmUri();
    final listenerPid = vmUri == null
        ? null
        : await _pidForListeningVmPort(vmUri);
    final vmLogListenerPid = _readVmLogListenerPid();
    final ownsFlutterRun = sessionMeta?['mode'] == 'scout_owned_flutter_run';
    var stopped = false;
    var processExisted = false;
    String? pidKillSkippedReason;
    final trustedPid =
        pid != null &&
        ownsFlutterRun &&
        await _matchesOwnedFlutterRun(pid, sessionMeta);

    // Stop Scout's auxiliary children while the exact Flutter owner is still
    // live and can participate in their ownership proof. A PID, descendant
    // relation, or recognizable command alone is never authority to signal.
    var vmLogListenerExisted = false;
    String? vmLogListenerKillSkippedReason;
    if (vmLogListenerPid != null &&
        vmLogListenerPid != pid &&
        vmLogListenerPid != listenerPid) {
      if (await _matchesOwnedVmLogListener(vmLogListenerPid, sessionMeta)) {
        vmLogListenerExisted = Process.killPid(vmLogListenerPid);
        stopped = stopped || vmLogListenerExisted;
      } else if (await _processExists(vmLogListenerPid)) {
        vmLogListenerKillSkippedReason = 'pid_identity_mismatch';
      }
    }

    var serveExisted = false;
    String? serveKillSkippedReason;
    if (servePid != null &&
        servePid != pid &&
        servePid != listenerPid &&
        servePid != vmLogListenerPid) {
      if (await _matchesOwnedServeProcess(servePid, serve)) {
        serveExisted = Process.killPid(servePid);
        stopped = stopped || serveExisted;
      } else if (await _processExists(servePid)) {
        serveKillSkippedReason = 'pid_identity_mismatch';
      }
    }

    if (pid != null) {
      // Revalidate immediately before signaling while its exact supervisor
      // and parent association are still live. Stop the supervisor only after
      // the owned Flutter tool has received termination.
      final stillTrusted =
          trustedPid && await _matchesOwnedFlutterRun(pid, sessionMeta);
      if (stillTrusted) {
        processExisted = Process.killPid(pid);
        stopped = stopped || processExisted;
      } else {
        processExisted = await _processExists(pid);
        pidKillSkippedReason = !ownsFlutterRun
            ? 'session_does_not_own_process'
            : processExisted
            ? 'pid_identity_mismatch'
            : 'process_not_found';
      }
    }
    final supervisorStop = await _stopRunnerSupervisor(
      ownsFlutterRun ? sessionMeta : null,
    );
    stopped = stopped || supervisorStop['stopped'] == true;
    // The VM-service listener is an app/runtime process, not a Scout-owned
    // daemon. Terminating the exact Flutter tool is the supported lifecycle
    // operation; a separately surviving app is intentionally left untouched.
    const listenerExisted = false;
    String? listenerKillSkippedReason;
    if (listenerPid != null && listenerPid != pid) {
      listenerKillSkippedReason = ownsFlutterRun
          ? 'managed_by_flutter_runner_not_signaled_separately'
          : 'session_does_not_own_process';
    }
    // `--clear-session` delegates these exact paths to the symlink-safe
    // managed cleanup below. The ordinary stop path retains its historical
    // lightweight PID-file cleanup behavior.
    if (!parsed.flag('clear-session')) {
      _deleteFileIfExists(_pidFile);
      _deleteFileIfExists(_vmLogListenerPidFile);
    }
    var registryPruned = const <String>[];
    final temporaryCleanup = temporarySetup == null
        ? null
        : await _cleanupTemporaryHelper(temporarySetup);
    final temporaryCleanupComplete =
        temporaryCleanup == null ||
        const <String>{
          'repaired',
          'legacy_cleanup_completed',
        }.contains(temporaryCleanup['status']);
    Map<String, Object?>? retentionCleanup;
    Map<String, Object?>? managedSessionCleanup;
    ScoutCliException? sessionCleanupError;
    var sessionClearComplete = true;
    if (parsed.flag('clear-session')) {
      try {
        retentionCleanup = _cleanupPrivateArtifacts(
          now: DateTime.now().toUtc(),
          includeSession: true,
          trigger: 'stop_clear_session',
        );
      } on ScoutCliException catch (error) {
        sessionCleanupError = error;
        retentionCleanup = <String, Object?>{
          'ok': false,
          'trigger': 'stop_clear_session',
          'registry': error.code == 'retention_registry_invalid'
              ? 'invalid'
              : 'unavailable',
          'cleanup': error.code == 'retention_registry_invalid'
              ? 'not_performed'
              : 'completion_unknown',
          'error': <String, Object?>{
            'code': error.code,
            'message': error.message,
            if (error.details.isNotEmpty) 'details': error.details,
          },
        };
      } catch (_) {
        sessionCleanupError = const ScoutCliException(
          'retention_cleanup_unavailable',
          'Private-artifact cleanup ended without a trustworthy completion '
              'result. Retained artifacts and controls require inspection.',
        );
        retentionCleanup = const <String, Object?>{
          'ok': false,
          'trigger': 'stop_clear_session',
          'registry': 'unavailable',
          'cleanup': 'completion_unknown',
          'error': <String, Object?>{
            'code': 'retention_cleanup_unavailable',
            'message':
                'Private-artifact cleanup ended without a trustworthy '
                'completion result.',
          },
        };
      }
      if (sessionCleanupError == null) {
        // A valid registry can contain one caller-modified artifact. Preserve
        // that exact entry, but still clean independently owned credentials,
        // logs, and temporary state before reporting the overall failure.
        try {
          managedSessionCleanup = _cleanupManagedSessionInternals(
            temporaryHelperCleanupComplete: temporaryCleanupComplete,
            serveCredentialPath: serve is Map
                ? serve['credentialFile']?.toString()
                : null,
          );
        } on ScoutCliException catch (error) {
          sessionCleanupError = error;
          managedSessionCleanup = <String, Object?>{
            'ok': false,
            'cleanup': 'completion_unknown',
            'error': <String, Object?>{
              'code': error.code,
              'message': error.message,
              if (error.details.isNotEmpty) 'details': error.details,
            },
          };
        } catch (_) {
          sessionCleanupError = const ScoutCliException(
            'managed_session_cleanup_unavailable',
            'Managed session cleanup ended without a trustworthy completion '
                'result. Session residue requires inspection.',
          );
          managedSessionCleanup = const <String, Object?>{
            'ok': false,
            'cleanup': 'completion_unknown',
            'error': <String, Object?>{
              'code': 'managed_session_cleanup_unavailable',
              'message':
                  'Managed session cleanup ended without a trustworthy '
                  'completion result.',
            },
          };
        }
      } else {
        // Without a trustworthy registry snapshot the allowlist cannot prove
        // which session paths must be preserved, so no residue cleanup runs.
        managedSessionCleanup = const <String, Object?>{
          'ok': false,
          'cleanup': 'not_performed',
          'skippedReason': 'retention_control_state_unavailable',
        };
      }
      sessionClearComplete =
          retentionCleanup['ok'] == true &&
          managedSessionCleanup['ok'] == true &&
          sessionCleanupError == null;
      if (sessionClearComplete) {
        registryPruned = _pruneScoutRegistryFor(_sessionDir.path);
      }
    }
    final commandOk = !parsed.flag('clear-session') || sessionClearComplete;
    if (!parsed.flag('quiet') || !commandOk) {
      _printJson({
        'ok': commandOk,
        if (!commandOk)
          'error': <String, Object?>{
            'code': sessionCleanupError?.code ?? 'session_cleanup_incomplete',
            'message':
                'The process was stopped, but unexpected or unsafe session '
                'residue was preserved. Inspect the cleanup report.',
          },
        'pid': pid,
        'vmServiceListenerPid': listenerPid,
        'vmLogListenerPid': vmLogListenerPid,
        'processExisted': processExisted,
        'vmServiceListenerExisted': listenerExisted,
        'vmServiceListenerKillSkippedReason': ?listenerKillSkippedReason,
        'vmLogListenerExisted': vmLogListenerExisted,
        'servePid': ?servePid,
        'serveExisted': serveExisted,
        'serveKillSkippedReason': ?serveKillSkippedReason,
        'supervisor': supervisorStop,
        'stopped': stopped,
        'pidKillSkippedReason': ?pidKillSkippedReason,
        'vmLogListenerKillSkippedReason': ?vmLogListenerKillSkippedReason,
        'pidFileCleared':
            FileSystemEntity.typeSync(_pidFile, followLinks: false) ==
            FileSystemEntityType.notFound,
        'vmLogListenerPidFileCleared':
            FileSystemEntity.typeSync(
              _vmLogListenerPidFile,
              followLinks: false,
            ) ==
            FileSystemEntityType.notFound,
        if (parsed.flag('clear-session'))
          'sessionCleared': sessionClearComplete,
        'privateArtifactRetentionCleanup': ?retentionCleanup,
        'managedSessionCleanup': ?managedSessionCleanup,
        if (registryPruned.isNotEmpty) 'registryPruned': registryPruned,
        'temporaryHelperCleanup': ?temporaryCleanup,
      }, success: commandOk);
    }
    return commandOk ? 0 : 1;
  }

  Future<bool> _matchesOwnedFlutterRun(
    int processId,
    Map<String, dynamic>? meta,
  ) async {
    if (meta?['mode'] != 'scout_owned_flutter_run') return false;
    final runId = meta?['runId']?.toString();
    final project = meta?['project']?.toString();
    final expectedIdentity = meta?['processIdentity'];
    if (runId == null || runId.isEmpty || project == null || project.isEmpty) {
      return false;
    }
    // A PID and matching command line are not an ownership identity: the PID
    // may have been reused, and a different run can contain similar tokens.
    // New owned sessions record an immutable process-start tuple. Older or
    // partial metadata therefore fails closed and is deliberately not killed.
    if (expectedIdentity is! Map) return false;
    final currentIdentity = await _readProcessOwnershipIdentity(
      processId,
      role: _flutterRunProcessRole,
    );
    if (currentIdentity == null ||
        !_sameProcessOwnershipIdentity(expectedIdentity, currentIdentity)) {
      return false;
    }
    if (!await _matchesFlutterSupervisorAssociation(meta!, expectedIdentity)) {
      return false;
    }
    final command = await _processCommand(processId);
    if (command == null) return false;
    final lower = command.toLowerCase();
    final hasFlutterTool =
        lower.contains('flutter_tools') ||
        RegExp(r'(^|[/\s])flutter(\s|$)').hasMatch(lower);
    final hasRunCommand = RegExp(r'(^|\s)run(\s|$)').hasMatch(lower);
    final ownsRun = command.contains('$kScoutRunIdDefine=$runId');
    final ownsProject = command.contains(
      '$kScoutProjectDefine=${Directory(project).absolute.path}',
    );
    final device = meta['device']?.toString();
    final ownsDevice =
        device == null ||
        device.isEmpty ||
        RegExp(
          '(?:^|\\s)(?:-d|--device)\\s+${RegExp.escape(device)}(?:\\s|\$)',
        ).hasMatch(command);
    return hasFlutterTool &&
        hasRunCommand &&
        ownsRun &&
        ownsProject &&
        ownsDevice;
  }

  Future<bool> _matchesOwnedVmLogListener(
    int processId,
    Map<String, dynamic>? meta,
  ) async {
    if (meta?['mode'] != 'scout_owned_flutter_run') return false;
    final listener = meta?['vmLogListener'];
    if (listener is! Map) return false;
    final listenerPid = int.tryParse('${listener['pid'] ?? ''}');
    final ownerPid = int.tryParse('${listener['ownerPid'] ?? ''}');
    final runId = meta?['runId']?.toString();
    final expectedIdentity = listener['processIdentity'];
    if (listenerPid != processId ||
        ownerPid == null ||
        ownerPid != _readPid() ||
        runId == null ||
        runId.isEmpty ||
        listener['runId']?.toString() != runId ||
        listener['sessionDirectory']?.toString() != _sessionDir.path ||
        expectedIdentity is! Map) {
      return false;
    }
    final currentIdentity = await _readProcessOwnershipIdentity(
      processId,
      role: _vmLogListenerProcessRole,
    );
    if (currentIdentity == null ||
        !_sameProcessOwnershipIdentity(expectedIdentity, currentIdentity)) {
      return false;
    }
    final command = await _processCommand(processId);
    if (command == null ||
        !_commandLooksLikeScoutVmLogListener(command) ||
        !command.contains(_sessionDir.path) ||
        !RegExp(
          '(?:^|\\s)--owner-pid\\s+${RegExp.escape('$ownerPid')}(?:\\s|\$)',
        ).hasMatch(command)) {
      return false;
    }
    final ownerIdentity = listener['ownerProcessIdentity'];
    if (ownerIdentity is! Map ||
        meta?['processIdentity'] is! Map ||
        !_sameProcessOwnershipIdentity(
          Map<Object?, Object?>.from(ownerIdentity),
          Map<String, Object?>.from(meta!['processIdentity'] as Map),
        )) {
      return false;
    }
    return _matchesOwnedFlutterRun(ownerPid, meta);
  }

  Future<Map<String, Object?>> _collectLaunchProvenance({
    required String project,
    required String flutterExecutable,
  }) async {
    final capturedAt = DateTime.now().toUtc().toIso8601String();
    final sourceIdentity = await _projectSourceIdentity(project);
    final flutterToolchain = _flutterToolchainIdentity(flutterExecutable);
    return <String, Object?>{
      'provenanceCapturedAt': capturedAt,
      'sourceIdentity': sourceIdentity,
      if (sourceIdentity['commit'] != null)
        'appCommit': sourceIdentity['commit'],
      if (sourceIdentity['workingTreeDirty'] != null)
        'appWorkingTreeDirty': sourceIdentity['workingTreeDirty'],
      if (sourceIdentity['workingTreeStatusDigest'] != null)
        'appWorkingTreeStatusDigest': sourceIdentity['workingTreeStatusDigest'],
      'flutterToolchain': flutterToolchain,
      if (flutterToolchain['frameworkVersion'] != null)
        'flutterVersion': flutterToolchain['frameworkVersion'],
    };
  }

  Future<Map<String, Object?>> _projectSourceIdentity(String project) async {
    try {
      final revision = await Process.run('git', <String>[
        '-C',
        project,
        'rev-parse',
        '--verify',
        'HEAD',
      ]);
      final commit = '${revision.stdout}'.trim();
      if (revision.exitCode != 0 ||
          !RegExp(r'^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$').hasMatch(commit)) {
        return const <String, Object?>{
          'status': 'unavailable',
          'reason': 'project_not_at_a_resolvable_git_commit',
          'excludedToolPaths': <String>['.flutter_scout/'],
        };
      }
      final status = await Process.run('git', <String>[
        '-C',
        project,
        'status',
        '--porcelain=v1',
        '--untracked-files=normal',
        '--',
        '.',
        ':(exclude).flutter_scout',
        ':(exclude).flutter_scout/**',
      ]);
      if (status.exitCode != 0) {
        return <String, Object?>{
          'status': 'partial',
          'commit': commit.toLowerCase(),
          'workingTreeStatus': 'unavailable',
          'reason': 'git_status_failed',
          'excludedToolPaths': const <String>['.flutter_scout/'],
        };
      }
      final statusText = '${status.stdout}';
      final statusBytes = utf8.encode(statusText);
      if (statusBytes.length > 4 * 1024 * 1024) {
        return <String, Object?>{
          'status': 'partial',
          'commit': commit.toLowerCase(),
          'workingTreeStatus': 'unavailable',
          'reason': 'git_status_exceeded_4_mib_bound',
          'excludedToolPaths': const <String>['.flutter_scout/'],
        };
      }
      final entryCount = const LineSplitter()
          .convert(statusText)
          .where((line) => line.isNotEmpty)
          .length;
      final dirty = entryCount > 0;
      return <String, Object?>{
        'status': dirty ? 'dirty_worktree' : 'clean_commit',
        'commit': commit.toLowerCase(),
        'workingTreeDirty': dirty,
        'workingTreeEntryCount': entryCount,
        'workingTreeStatusDigest': crypto.sha256
            .convert(statusBytes)
            .toString(),
        'statusDigestAlgorithm': 'sha256',
        'statusPathsPersisted': false,
        'excludedToolPaths': const <String>['.flutter_scout/'],
      };
    } catch (_) {
      return const <String, Object?>{
        'status': 'unavailable',
        'reason': 'git_identity_probe_failed',
        'excludedToolPaths': <String>['.flutter_scout/'],
      };
    }
  }

  Map<String, Object?> _flutterToolchainIdentity(String executable) {
    String? readBounded(String path) {
      try {
        final file = File(path);
        if (!file.existsSync() || file.lengthSync() > 4096) return null;
        final value = file.readAsStringSync().trim();
        return value.isEmpty ? null : value;
      } catch (_) {
        return null;
      }
    }

    try {
      final resolvedExecutable = File(executable).resolveSymbolicLinksSync();
      final sdkRoot = p.dirname(p.dirname(resolvedExecutable));
      final frameworkVersion = readBounded(p.join(sdkRoot, 'version'));
      final engineRevision = readBounded(
        p.join(sdkRoot, 'bin', 'internal', 'engine.version'),
      );
      final dartSdkVersion = readBounded(
        p.join(sdkRoot, 'bin', 'cache', 'dart-sdk', 'version'),
      );
      if (frameworkVersion == null &&
          engineRevision == null &&
          dartSdkVersion == null) {
        return const <String, Object?>{
          'status': 'unavailable',
          'reason': 'flutter_sdk_identity_files_unavailable',
        };
      }
      return <String, Object?>{
        'status': 'observed',
        'source': 'flutter_sdk_identity_files',
        'frameworkVersion': frameworkVersion,
        'engineRevision': engineRevision,
        'dartSdkVersion': dartSdkVersion,
      };
    } catch (_) {
      return const <String, Object?>{
        'status': 'unavailable',
        'reason': 'flutter_sdk_identity_probe_failed',
      };
    }
  }
}

/// Reads the minimum immutable tuple needed to distinguish a live process from
/// a later process that reused the same numeric PID.
///
/// This intentionally does not persist the full command line because Flutter
/// arguments can contain application secrets. Command tokens needed for
/// ownership are validated directly at termination time.
const String _flutterRunProcessRole = 'flutter_run';
const String _flutterWorkerProcessRole = 'flutter_run_worker';
const String _vmLogListenerProcessRole = 'vm_log_listener';
const String _serveProcessRole = 'serve_daemon';

Future<Map<String, Object?>?> _readProcessOwnershipIdentity(
  int pid, {
  required String role,
}) async {
  if (pid <= 0 || (!Platform.isMacOS && !Platform.isLinux)) return null;

  Future<String?> field(String name) async {
    try {
      final result = await Process.run('ps', ['-p', '$pid', '-o', '$name='])
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => ProcessResult(pid, 1, '', ''),
          );
      if (result.exitCode != 0) return null;
      final value = '${result.stdout}'.trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  final values = await Future.wait([
    field('ppid'),
    field('lstart'),
    field('comm'),
  ]);
  final parentPid = int.tryParse(values[0] ?? '');
  final startedAt = values[1];
  final executable = values[2];
  if (parentPid == null || startedAt == null || executable == null) return null;
  return {
    'pid': pid,
    'parentPid': parentPid,
    'startedAt': startedAt,
    'executable': executable,
    // The complete command line is intentionally not persisted because Dart
    // defines and launch arguments may contain application secrets. The
    // exact, non-secret role-specific command tokens are re-read and checked
    // immediately before every signal; this field makes the stored command
    // identity explicit and prevents one process kind being substituted for
    // another even when the immutable OS tuple happens to match.
    'commandIdentity': role,
  };
}

bool _sameProcessOwnershipIdentity(
  Map<Object?, Object?> expected,
  Map<String, Object?> current,
) {
  final expectedPid = int.tryParse('${expected['pid'] ?? ''}');
  final expectedParentPid = int.tryParse('${expected['parentPid'] ?? ''}');
  final expectedStartedAt = expected['startedAt']?.toString();
  final expectedExecutable = expected['executable']?.toString();
  final expectedCommandIdentity = expected['commandIdentity']?.toString();
  return expectedPid != null &&
      expectedPid == current['pid'] &&
      expectedParentPid != null &&
      expectedParentPid == current['parentPid'] &&
      expectedStartedAt != null &&
      expectedStartedAt == current['startedAt'] &&
      expectedExecutable != null &&
      expectedExecutable == current['executable'] &&
      expectedCommandIdentity != null &&
      expectedCommandIdentity == current['commandIdentity'];
}

/// Narrow process-level test seam for proving launch-lease contention and
/// crash recovery without starting Flutter or touching the user's sessions.
extension FlutterScoutCliLaunchLeaseTesting on FlutterScoutCli {
  Future<T> debugWithLaunchLease<T>({
    required String sessionDirectory,
    required String project,
    required String device,
    String? name,
    required Future<T> Function(Map<String, Object?> lease) body,
  }) async {
    final previousSessionDirectory = FlutterScoutCli._sessionDirectoryOverride;
    FlutterScoutCli._sessionDirectoryOverride = sessionDirectory;
    _LaunchLease? lease;
    try {
      lease = await _acquireLaunchLease(
        project: project,
        device: device,
        name: name,
      );
      return await body(<String, Object?>{
        'runId': lease.runId,
        'startedAt': lease.startedAt.toIso8601String(),
        'controlPath': lease.controlFile.path,
        'infoPath': lease.infoFile.path,
        'metadata': _readLaunchInfo(),
      });
    } finally {
      lease?.release();
      FlutterScoutCli._sessionDirectoryOverride = previousSessionDirectory;
    }
  }
}
