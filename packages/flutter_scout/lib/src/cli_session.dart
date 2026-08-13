part of 'flutter_scout_cli.dart';

// part: session lifecycle commands: launch, attach, ensure, status, doctor, stop.

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
      ..addMultiOption('dart-define')
      ..addMultiOption('dart-define-from-file')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
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
    try {
      final instanceName = parsed.option('name');
      if (instanceName != null && instanceName.isNotEmpty) {
        // Session files live in the cwd; register it so `--app <name>` can
        // address this session from anywhere.
        _registerScoutSession(instanceName, _sessionDir.path);
      }
      _writeProgress('resolve_device', {'requestedDevice': device});
      final resolvedDevice = await _resolveFlutterDevice(device);
      if (resolvedDevice == null) {
        throw ScoutCliException(
          'device_not_found',
          'No connected Flutter device exactly matched `$device`.',
        );
      }

      _ensureSessionDir();
      final runLogFile = p.join(
        _sessionDir.path,
        'runs',
        launchLease.runId,
        'logs.txt',
      );
      Directory(p.dirname(runLogFile)).createSync(recursive: true);
      File(runLogFile).writeAsStringSync('');
      _writeSessionMeta({
        'mode': 'scout_owned_flutter_run',
        'state': 'building',
        'runId': launchLease.runId,
        'name': ?instanceName,
        'project': project,
        'device': resolvedDevice.id,
        'logFile': runLogFile,
        'createdAt': launchLease.startedAt.toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      });
      final temporarySetup = parsed.flag('temporary-helper')
          ? await _prepareTemporaryHelper(
              project: project,
              originalTarget: parsed.option('target') ?? 'lib/main.dart',
              helperPath: parsed.option('helper-path'),
              runId: launchLease.runId,
            )
          : null;
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
        for (final value in parsed.multiOption('dart-define')) ...[
          '--dart-define',
          value,
        ],
        for (final value in parsed.multiOption('dart-define-from-file')) ...[
          '--dart-define-from-file',
          value,
        ],
        if (parsed.option('name')?.isNotEmpty ?? false) ...[
          '--dart-define',
          '$kScoutInstanceDefine=${parsed.option('name')}',
        ],
        // Tell the in-app helper the project root so it can write recordings
        // straight to <project>/.flutter_scout/recordings/ (macOS/desktop; the
        // iOS-sim sandbox can't reach it, so the CLI persists from the ext there).
        '--dart-define',
        '$kScoutProjectDefine=${Directory(project).absolute.path}',
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
      File(workerConfigFile).writeAsStringSync(
        jsonEncode({
          'project': project,
          'flutterArgs': flutterArgs,
          'logFile': runLogFile,
          'runId': launchLease.runId,
        }),
      );
      final process = await Process.start(Platform.resolvedExecutable, [
        Platform.script.toFilePath(),
        'flutter-run-worker',
        '--config',
        workerConfigFile,
      ], mode: ProcessStartMode.detached);
      File(_deviceFile).writeAsStringSync(resolvedDevice.id);
      _writeDeviceInfo(resolvedDevice);
      File(_pidFile).writeAsStringSync(process.pid.toString());
      final signalSubscriptions = _installLaunchSignalHandlers(process);

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
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      while (DateTime.now().isBefore(deadline)) {
        final logFile = File(runLogFile);
        if (logFile.existsSync()) {
          final currentLines = _readLogLinesSync(logFile);
          for (final line in currentLines.skip(readLineCount)) {
            handleLine(line);
            vmUri ??= _extractVmUri(line) ?? _extractFlutterToolVmUri(line);
          }
          readLineCount = currentLines.length;
          if (vmUri != null) break;
        }
        final now = DateTime.now();
        if (now.difference(lastHeartbeat) >= const Duration(seconds: 15)) {
          lastHeartbeat = now;
          _writeProgress('launch_heartbeat', {
            'elapsedMs': now.difference(launchTiming.startedAt).inMilliseconds,
            'logLines': readLineCount,
            if (lines.isNotEmpty) 'lastLine': _compactProgressLine(lines.last),
          });
        }
        if (!await _processExists(process.pid)) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      for (final subscription in signalSubscriptions) {
        await subscription.cancel();
      }

      if (vmUri == null) {
        if (temporarySetup != null) {
          await _cleanupTemporaryHelper(temporarySetup);
        }
        _writeSessionMeta({
          ...?_readSessionMeta(),
          'state': 'failed',
          'updatedAt': DateTime.now().toIso8601String(),
        });
        stdout.writeln(
          jsonEncode({
            'launched': false,
            'reason': 'vm_service_uri_not_found',
            'pid': process.pid,
            'timing': launchTiming.toJson(completedAt: DateTime.now()),
            'tailLogLines': lines.length > 20
                ? lines.sublist(lines.length - 20)
                : lines,
          }),
        );
        return 1;
      }

      final wsUri = _normalizeVmUri(vmUri);
      File(_vmUriFile).writeAsStringSync(wsUri);
      final flutterToolPid =
          await _findScoutFlutterToolPid(
            project: project,
            instanceName: instanceName,
          ) ??
          process.pid;
      File(_pidFile).writeAsStringSync('$flutterToolPid');
      final vmLogListenerPid = await _startVmLogListener(
        vmUri: wsUri,
        logFile: runLogFile,
        ownerPid: flutterToolPid,
      );
      _writeSessionMeta({
        'mode': 'scout_owned_flutter_run',
        'state': 'ready',
        'runId': launchLease.runId,
        'name': ?instanceName,
        'pid': flutterToolPid,
        'vmLogListenerPid': ?vmLogListenerPid,
        'logFile': runLogFile,
        'project': project,
        'device': resolvedDevice.id,
        'createdAt': launchLease.startedAt.toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
        if (temporarySetup != null) 'temporarySetup': temporarySetup.toJson(),
      });
      _writeProgress('verify_vm_service', {'vmServiceUri': wsUri});
      final ready = await _waitScoutReady(wsUri);
      launchTiming.readyAt = DateTime.now();
      stdout.writeln(
        jsonEncode({
          'launched': true,
          'ready': ready.ready,
          if (!ready.ready) 'reason': ready.reason,
          if (!ready.ready) 'expected': ready.expected,
          'device': resolvedDevice.id,
          'deviceName': resolvedDevice.name,
          'deviceCategory': resolvedDevice.category,
          'project': project,
          'pid': flutterToolPid,
          'vmLogListenerPid': ?vmLogListenerPid,
          'vmServiceUri': wsUri,
          'logFile': runLogFile,
          'timing': launchTiming.toJson(completedAt: launchTiming.readyAt),
        }),
      );
      return ready.ready ? 0 : 1;
    } finally {
      launchLease.release();
    }
  }

  Future<_TemporaryHelperSetup> _prepareTemporaryHelper({
    required String project,
    required String originalTarget,
    required String? helperPath,
    required String runId,
  }) async {
    final pubspec = File(p.join(project, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      throw const ScoutCliException(
        'temporary_helper_pubspec_missing',
        'Temporary helper setup requires a Flutter pubspec.yaml.',
      );
    }
    final target = p.isAbsolute(originalTarget)
        ? p.normalize(originalTarget)
        : p.normalize(p.join(project, originalTarget));
    if (!File(target).existsSync()) {
      throw ScoutCliException(
        'temporary_helper_target_missing',
        'The original Flutter target does not exist: $target',
      );
    }
    final resolvedHelper = helperPath ?? await _discoverBundledHelperPath();
    if (resolvedHelper == null ||
        !File(p.join(resolvedHelper, 'pubspec.yaml')).existsSync()) {
      throw const ScoutCliException(
        'temporary_helper_path_missing',
        'Could not locate flutter_scout_helper. Pass '
            '`--helper-path <path-to-flutter_scout_helper>`.',
      );
    }

    final originalPubspec = pubspec.readAsBytesSync();
    final lockFile = File(p.join(project, 'pubspec.lock'));
    final lockExisted = lockFile.existsSync();
    final originalLock = lockExisted ? lockFile.readAsBytesSync() : null;
    final generatedDir = Directory(p.join(project, '.flutter_scout'))
      ..createSync(recursive: true);
    File? lockBackup;
    if (originalLock != null) {
      lockBackup = File(
        p.join(generatedDir.path, 'bootstrap_$runId.lock.backup'),
      )..writeAsBytesSync(originalLock);
    }
    final pubspecText = utf8.decode(originalPubspec);
    var dependencyInjected = false;
    try {
      if (!RegExp(
        r'^\s*flutter_scout_helper\s*:',
        multiLine: true,
      ).hasMatch(pubspecText)) {
        final dependencies = RegExp(
          r'^dependencies:\s*$',
          multiLine: true,
        ).firstMatch(pubspecText);
        if (dependencies == null) {
          throw const ScoutCliException(
            'temporary_helper_dependencies_missing',
            'pubspec.yaml has no top-level dependencies section.',
          );
        }
        final quotedPath = resolvedHelper.replaceAll("'", "''");
        final insertion = "\n  flutter_scout_helper:\n    path: '$quotedPath'";
        final updated = pubspecText.replaceRange(
          dependencies.end,
          dependencies.end,
          insertion,
        );
        pubspec.writeAsStringSync(updated);
        dependencyInjected = true;
      }

      final pubGet = await Process.run('flutter', const [
        'pub',
        'get',
      ], workingDirectory: project);
      if (pubGet.exitCode != 0) {
        throw ScoutCliException(
          'temporary_helper_pub_get_failed',
          'flutter pub get failed during temporary helper setup: '
              '${pubGet.stderr}',
        );
      }

      final generatedTarget = File(
        p.join(generatedDir.path, 'bootstrap_$runId.dart'),
      );
      final relativeTarget = p
          .relative(target, from: generatedDir.path)
          .split(p.separator)
          .join('/');
      generatedTarget.writeAsStringSync('''
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import '$relativeTarget' as app;

Future<void> main() async {
  FlutterScoutBinding.ensureInitialized();
  await Future<void>.sync(app.main);
}
''');
      return _TemporaryHelperSetup(
        project: project,
        targetPath: generatedTarget.path,
        lockExisted: lockExisted,
        lockBackupPath: lockBackup?.path,
      );
    } finally {
      if (dependencyInjected) pubspec.writeAsBytesSync(originalPubspec);
      if (originalLock != null) {
        lockFile.writeAsBytesSync(originalLock);
      } else if (!lockExisted && lockFile.existsSync()) {
        lockFile.deleteSync();
      }
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
    final logFile = config['logFile']?.toString();
    final flutterArgs = config['flutterArgs'];
    if (project == null ||
        project.isEmpty ||
        logFile == null ||
        logFile.isEmpty ||
        flutterArgs is! List) {
      throw const ScoutCliException(
        'invalid_worker_config',
        'The Flutter worker configuration is incomplete.',
      );
    }

    Directory(p.dirname(logFile)).createSync(recursive: true);
    final writer = _LockedLogWriter(logFile);
    Future<void> writeLine(String stream, String line) {
      final timestamp = DateTime.now().toUtc().toIso8601String();
      final sanitized = _redactSensitiveLogText(_stripLogAnsi(line));
      return writer.write('[$timestamp] [FLUTTER_$stream] $sanitized');
    }

    final child = await Process.start(
      'flutter',
      flutterArgs.map((value) => value.toString()).toList(growable: false),
      workingDirectory: project,
    );
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
    final signalSubscriptions = <StreamSubscription<ProcessSignal>>[
      ProcessSignal.sigusr1.watch().listen(
        (_) => child.kill(ProcessSignal.sigusr1),
      ),
      ProcessSignal.sigusr2.watch().listen(
        (_) => child.kill(ProcessSignal.sigusr2),
      ),
      ProcessSignal.sigterm.watch().listen((_) => child.kill()),
      ProcessSignal.sigint.watch().listen((_) => child.kill()),
    ];
    try {
      final exitCode = await child.exitCode;
      await Future.wait(outputDrains);
      return exitCode;
    } finally {
      for (final subscription in signalSubscriptions) {
        await subscription.cancel();
      }
      await writer.close();
      try {
        configFile.deleteSync();
      } catch (_) {}
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

  Future<_LaunchLease> _acquireLaunchLease({
    required String project,
    required String device,
    required String? name,
  }) async {
    _ensureSessionDir();
    final file = File(_launchLockFile);
    if (file.existsSync()) {
      final info = _readLaunchInfo();
      final ownerPid = int.tryParse('${info?['ownerPid'] ?? ''}');
      final active = ownerPid != null && await _processExists(ownerPid);
      if (active) {
        throw ScoutCliException(
          'launch_in_progress',
          'A Flutter Scout launch is already in progress'
              '${info?['name'] == null ? '' : ' for `${info?['name']}`'}. '
              'Use `ensure` to join it, or wait for it to become ready.',
        );
      }
      try {
        file.deleteSync();
      } catch (_) {}
    }
    final startedAt = DateTime.now();
    final runId =
        '${startedAt.toUtc().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '')}-$pid';
    try {
      file.createSync(recursive: true, exclusive: true);
    } on FileSystemException {
      throw const ScoutCliException(
        'launch_in_progress',
        'Another Flutter Scout launch acquired this session concurrently. '
            'Use `ensure` to join it.',
      );
    }
    file.writeAsStringSync(
      jsonEncode({
        'ownerPid': pid,
        'runId': runId,
        'name': ?name,
        'project': project,
        'device': device,
        'startedAt': startedAt.toIso8601String(),
      }),
    );
    return _LaunchLease(file: file, runId: runId, startedAt: startedAt);
  }

  Map<String, dynamic>? _readLaunchInfo() {
    final file = File(_launchLockFile);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _joinLaunchIfNeeded(
    void Function(String stage, [Map<String, Object?> extra]) progress,
  ) async {
    final info = _readLaunchInfo();
    final ownerPid = int.tryParse('${info?['ownerPid'] ?? ''}');
    if (ownerPid == null || !await _processExists(ownerPid)) return;
    progress('join_launch', {
      'runId': info?['runId'],
      'ownerPid': ownerPid,
      'startedAt': info?['startedAt'],
    });
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(deadline)) {
      final uri = _readVmUri();
      if (uri != null && (await _validateVmUri(uri)).ok) return;
      final current = _readLaunchInfo();
      final currentPid = int.tryParse('${current?['ownerPid'] ?? ''}');
      if (currentPid == null || !await _processExists(currentPid)) return;
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
      ..addOption('device')
      ..addFlag('json', defaultsTo: true);
    final parsed = parser.parse(args);
    final explicit = parsed.option('debug-url');
    final discovered = await _discoverAttachVmUri(
      explicit: explicit,
      device: parsed.option('device'),
    );
    if (discovered.uri == null || discovered.uri!.isEmpty) {
      stdout.writeln(
        jsonEncode({
          'attached': false,
          'reason': discovered.reason ?? 'vm_service_uri_not_found',
          if (discovered.staleUri != null)
            'staleVmServiceUri': discovered.staleUri,
          if (discovered.staleCleared) 'staleCleared': true,
          'nextBestActions': [
            'Run the app in debug/profile mode and copy the VM Service URL',
            'flutter-scout attach --debug-url <url>',
            'flutter-scout launch --device <simulator-id> --project .',
          ],
        }),
      );
      return 1;
    }

    final wsUri = discovered.uri!;
    _ensureSessionDir();
    File(_vmUriFile).writeAsStringSync(wsUri);
    final previousMeta = _readSessionMeta();
    final previousPid =
        _readPid() ?? int.tryParse('${previousMeta?['pid'] ?? ''}');
    final ownedLogUri = _discoverVmUriFromScoutLog();
    final preservesOwnedRun =
        previousPid != null &&
        await _looksLikeScoutFlutterRun(previousPid) &&
        ownedLogUri != null &&
        _normalizeVmUri(ownedLogUri) == _normalizeVmUri(wsUri);
    final now = DateTime.now().toIso8601String();
    if (preservesOwnedRun) {
      File(_pidFile).writeAsStringSync('$previousPid');
      _writeSessionMeta({
        ...?previousMeta,
        'mode': 'scout_owned_flutter_run',
        'state': 'ready',
        'vmServiceUri': wsUri,
        'pid': previousPid,
        if (parsed.option('device') != null) 'device': parsed.option('device'),
        'createdAt': previousMeta?['createdAt'] ?? now,
        'updatedAt': now,
      });
      await _ensureVmLogListenerForCurrentSession(wsUri);
    } else {
      _writeSessionMeta({
        'mode': 'attach_only',
        'state': 'ready',
        'vmServiceUri': wsUri,
        if (parsed.option('device') != null) 'device': parsed.option('device'),
        'createdAt': now,
        'updatedAt': now,
      });
    }
    final output = <String, Object?>{
      'attached': true,
      'reusedRunningApp': true,
      'vmServiceUri': wsUri,
      'appStatePreserved': true,
      'attachOnly': !preservesOwnedRun,
      if (preservesOwnedRun) 'sessionOwnershipPreserved': true,
    };
    final device = parsed.option('device');
    if (device != null && device.isNotEmpty) {
      File(_deviceFile).writeAsStringSync(device);
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
    stdout.writeln(jsonEncode(output));
    return ready.ready ? 0 : 1;
  }

  Future<int> _ensure(List<String> args) async {
    final parser = ArgParser()
      ..addOption('debug-url')
      ..addOption('device')
      ..addOption('project', defaultsTo: Directory.current.path)
      ..addOption('target')
      ..addOption('flavor')
      ..addOption('name')
      ..addFlag('temporary-helper', defaultsTo: false, negatable: false)
      ..addOption('helper-path')
      ..addMultiOption('dart-define')
      ..addMultiOption('dart-define-from-file')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final device = parsed.option('device');
    void progress(String stage, [Map<String, Object?> extra = const {}]) {
      stdout.writeln(
        jsonEncode({
          'progress': stage,
          'timestamp': DateTime.now().toIso8601String(),
          ...extra,
        }),
      );
    }

    final instanceName = parsed.option('name');
    if (instanceName != null && instanceName.isNotEmpty) {
      _registerScoutSession(instanceName, _sessionDir.path);
    }
    await _joinLaunchIfNeeded(progress);
    progress('discover_vm_service', {'device': ?device});
    // Every step inside discovery is individually bounded, but a hard phase
    // ceiling guarantees ensure can never sit silent for minutes — fail with
    // a structured error instead.
    final discovered =
        await _discoverAttachVmUri(
          explicit: parsed.option('debug-url'),
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
        File(_vmUriFile).writeAsStringSync(discovered.uri!);
        await _reconcileReachableSessionOwnership(discovered.uri!);
        final ownershipLost = _sessionOwnershipWasLost();
        final pid = _readPid();
        final scoutOwned = pid != null && await _looksLikeScoutFlutterRun(pid);
        final previousMeta = _readSessionMeta();
        final now = DateTime.now().toIso8601String();
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
                  'vmServiceUri': discovered.uri,
                  'device': ?device,
                  'updatedAt': now,
                }
              : {
                  'mode': 'attach_only',
                  'state': 'ready',
                  'vmServiceUri': discovered.uri,
                  'device': ?device,
                  'createdAt': now,
                  'updatedAt': now,
                },
        );
        if (device != null && device.isNotEmpty) {
          File(_deviceFile).writeAsStringSync(device);
          final resolvedDevice = await _resolveFlutterDevice(device);
          if (resolvedDevice != null) {
            _writeDeviceInfo(resolvedDevice);
          } else {
            _deleteFileIfExists(_deviceInfoFile);
          }
        }
        stdout.writeln(
          jsonEncode({
            'ensured': true,
            'reusedRunningApp': true,
            'appStatePreserved': true,
            'ready': true,
            'vmServiceUri': discovered.uri,
            'device': ?device,
            'attachOnly': !scoutOwned,
            if (ownershipLost) 'sessionOwnershipLost': true,
            'hotUpdate': await _hotUpdateCapability(discovered.uri!),
          }),
        );
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
    stdout.writeln(jsonEncode(await _statusPayload()));
    return 0;
  }

  Future<int> _devices(List<String> args) async {
    if (args.isNotEmpty) {
      throw const ScoutCliException('usage', 'Usage: flutter-scout devices');
    }
    final result = await Process.run('flutter', ['devices', '--machine'])
        .timeout(
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
    stdout.writeln(
      jsonEncode({
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
      }),
    );
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
    stdout.writeln(
      jsonEncode({
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
      }),
    );
    return 0;
  }

  Future<Map<String, Object?>> _statusPayload() async {
    final vmUri = _readVmUri();
    if (vmUri == null) {
      final recovered = await _recoverMissingOwnedVmUri();
      if (recovered != null) {
        return {
          'running': true,
          'vmServiceUri': recovered.uri,
          'missingVmServiceUriRestored': true,
          'refreshSource': recovered.source,
          if (_readDevice() != null) 'device': _readDevice(),
          if (_readDeviceInfo() != null) 'deviceInfo': _readDeviceInfo(),
          'session': _sessionModeInfo(),
          'hotUpdate': await _hotUpdateCapability(recovered.uri),
        };
      }
      final meta = _readSessionMeta();
      final recordedOwner = int.tryParse('${meta?['pid'] ?? ''}');
      if (meta?['mode'] == 'scout_owned_flutter_run' &&
          meta?['state'] == 'ready' &&
          (recordedOwner == null || !await _processExists(recordedOwner))) {
        await _markSessionStopped('owner_process_exited');
      }
      final launch = _readLaunchInfo();
      final ownerPid = int.tryParse('${launch?['ownerPid'] ?? ''}');
      final launching = ownerPid != null && await _processExists(ownerPid);
      return {
        'running': false,
        if (launching) 'launching': true,
        if (launching) 'launch': launch,
        'session': _sessionModeInfo(),
      };
    }
    final stale = await _validateVmUri(vmUri);
    if (stale.ok) {
      await _reconcileReachableSessionOwnership(vmUri);
      final ownershipLost = _sessionOwnershipWasLost();
      await _ensureVmLogListenerForCurrentSession(vmUri);
      return {
        'running': true,
        'appReachable': true,
        'vmServiceUri': vmUri,
        if (ownershipLost) 'sessionOwnershipLost': true,
        if (_readDevice() != null) 'device': _readDevice(),
        if (_readDeviceInfo() != null) 'deviceInfo': _readDeviceInfo(),
        'session': _sessionModeInfo(),
        'hotUpdate': await _hotUpdateCapability(vmUri),
      };
    }
    final refreshed = await _refreshStaleVmUri(staleUri: vmUri);
    if (refreshed != null) {
      await _reconcileReachableSessionOwnership(refreshed.uri);
      final ownershipLost = _sessionOwnershipWasLost();
      return {
        'running': true,
        'appReachable': true,
        'vmServiceUri': refreshed.uri,
        'staleVmServiceUri': vmUri,
        'staleRefreshed': true,
        'refreshSource': refreshed.source,
        if (ownershipLost) 'sessionOwnershipLost': true,
        if (_readDevice() != null) 'device': _readDevice(),
        if (_readDeviceInfo() != null) 'deviceInfo': _readDeviceInfo(),
        'session': _sessionModeInfo(),
        'hotUpdate': await _hotUpdateCapability(refreshed.uri),
      };
    }
    _clearVmUriFile();
    await _markSessionStopped('stale_vm_service');
    return {
      'running': false,
      'staleVmServiceUri': vmUri,
      'staleCleared': true,
      'session': _sessionModeInfo(),
      if (stale.error != null) 'reason': stale.error,
    };
  }

  Future<void> _markSessionStopped(String reason) async {
    final listenerPid = _readVmLogListenerPid();
    if (listenerPid != null) {
      final command = await _processCommand(listenerPid);
      if (command != null && _commandLooksLikeScoutVmLogListener(command)) {
        Process.killPid(listenerPid);
      }
      _deleteFileIfExists(_vmLogListenerPidFile);
    }
    final meta = _readSessionMeta();
    if (meta != null) {
      _writeSessionMeta({
        ...meta,
        'state': 'stopped',
        'stopReason': reason,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
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
    final vmUri = _readVmUri();
    final session = vmUri == null
        ? const _VmUriValidation(ok: false, error: 'no_session_vm_uri')
        : await _validateVmUri(vmUri);

    var helperExtensionRegistered = false;
    String? helperExtensionError;
    if (session.ok && vmUri != null) {
      final ready = await _waitScoutReady(vmUri);
      helperExtensionRegistered = ready.ready;
      helperExtensionError = ready.ready ? null : ready.reason;
    }

    final pubspecText = pubspec.existsSync() ? pubspec.readAsStringSync() : '';
    final mainText = mainFile.existsSync() ? mainFile.readAsStringSync() : '';
    final resolvedHelper = _resolvedPackageInfo(
      project,
      'flutter_scout_helper',
    );
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'ok': true,
        'cli': {
          'available': true,
          'version': FlutterScoutCli.packageVersion,
          'helperProtocolExpected':
              FlutterScoutCli.expectedHelperProtocolVersion,
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
      }),
    );
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
    final serve = _readSessionMeta()?['serve'];
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
    var stopped = false;
    var processExisted = false;
    String? pidKillSkippedReason;
    if (pid != null) {
      final trustedPid =
          listenerPid == pid || await _looksLikeScoutFlutterRun(pid);
      if (trustedPid) {
        processExisted = Process.killPid(pid);
        stopped = processExisted;
      } else {
        processExisted = await _processExists(pid);
        pidKillSkippedReason = processExisted
            ? 'pid_identity_mismatch'
            : 'process_not_found';
      }
    }
    var listenerExisted = false;
    if (listenerPid != null && listenerPid != pid) {
      listenerExisted = Process.killPid(listenerPid);
      stopped = stopped || listenerExisted;
    }
    var vmLogListenerExisted = false;
    var vmLogListenerKillSkippedReason = <String, Object?>{};
    if (vmLogListenerPid != null &&
        vmLogListenerPid != pid &&
        vmLogListenerPid != listenerPid) {
      if (await _looksLikeScoutVmLogListener(vmLogListenerPid)) {
        vmLogListenerExisted = Process.killPid(vmLogListenerPid);
        stopped = stopped || vmLogListenerExisted;
      } else {
        final exists = await _processExists(vmLogListenerPid);
        if (exists) {
          vmLogListenerKillSkippedReason = {
            'vmLogListenerKillSkippedReason': 'pid_identity_mismatch',
          };
        }
      }
    }
    var serveExisted = false;
    if (servePid != null &&
        servePid != pid &&
        servePid != listenerPid &&
        servePid != vmLogListenerPid) {
      final command = await _processCommand(servePid);
      if (command != null &&
          _commandLooksLikeScoutCli(command) &&
          RegExp(r'(?:^|\s)serve(?:\s|$)').hasMatch(command)) {
        serveExisted = Process.killPid(servePid);
        stopped = stopped || serveExisted;
      }
    }
    _deleteFileIfExists(_pidFile);
    _deleteFileIfExists(_vmLogListenerPidFile);
    var registryPruned = const <String>[];
    if (parsed.flag('clear-session')) {
      _clearVmUriFile();
      _deleteFileIfExists(_deviceFile);
      _deleteFileIfExists(_deviceInfoFile);
      _deleteFileIfExists(_sessionFile);
      _deleteFileIfExists(_eventsFile);
      _deleteFileIfExists(_sessionMetaFile);
      registryPruned = _pruneScoutRegistryFor(_sessionDir.path);
    }
    final temporaryCleanup = temporarySetup == null
        ? null
        : await _cleanupTemporaryHelper(temporarySetup);
    if (!parsed.flag('quiet')) {
      stdout.writeln(
        jsonEncode({
          'ok': true,
          'pid': pid,
          'vmServiceListenerPid': listenerPid,
          'vmLogListenerPid': vmLogListenerPid,
          'processExisted': processExisted,
          'vmServiceListenerExisted': listenerExisted,
          'vmLogListenerExisted': vmLogListenerExisted,
          'servePid': ?servePid,
          'serveExisted': serveExisted,
          'stopped': stopped,
          'pidKillSkippedReason': ?pidKillSkippedReason,
          ...vmLogListenerKillSkippedReason,
          'pidFileCleared': true,
          'vmLogListenerPidFileCleared': true,
          if (parsed.flag('clear-session')) 'sessionCleared': true,
          if (registryPruned.isNotEmpty) 'registryPruned': registryPruned,
          'temporaryHelperCleanup': ?temporaryCleanup,
        }),
      );
    }
    return 0;
  }

  _TemporaryHelperSetup? _temporarySetupFromMeta() {
    final value = _readSessionMeta()?['temporarySetup'];
    if (value is! Map) return null;
    final project = value['project']?.toString();
    final targetPath = value['targetPath']?.toString();
    if (project == null ||
        project.isEmpty ||
        targetPath == null ||
        targetPath.isEmpty) {
      return null;
    }
    return _TemporaryHelperSetup(
      project: project,
      targetPath: targetPath,
      lockExisted: value['lockExisted'] == true,
      lockBackupPath: value['lockBackupPath']?.toString(),
    );
  }

  Future<Map<String, Object?>> _cleanupTemporaryHelper(
    _TemporaryHelperSetup setup,
  ) async {
    var targetRemoved = false;
    final allowedRoot = p.normalize(p.join(setup.project, '.flutter_scout'));
    final target = p.normalize(setup.targetPath);
    if (p.isWithin(allowedRoot, target) &&
        p.basename(target).startsWith('bootstrap_')) {
      final file = File(target);
      if (file.existsSync()) {
        file.deleteSync();
        targetRemoved = true;
      }
    }
    final pubGet = await Process.run('flutter', const [
      'pub',
      'get',
    ], workingDirectory: setup.project);
    final lockFile = File(p.join(setup.project, 'pubspec.lock'));
    final backupPath = setup.lockBackupPath;
    var lockRestored = false;
    if (setup.lockExisted &&
        backupPath != null &&
        File(backupPath).existsSync()) {
      lockFile.writeAsBytesSync(File(backupPath).readAsBytesSync());
      File(backupPath).deleteSync();
      lockRestored = true;
    } else if (!setup.lockExisted && lockFile.existsSync()) {
      lockFile.deleteSync();
      lockRestored = true;
    }
    return {
      'targetRemoved': targetRemoved,
      'packageConfigRestored': pubGet.exitCode == 0,
      'lockRestored': lockRestored,
      if (pubGet.exitCode != 0) 'pubGetError': pubGet.stderr.toString(),
    };
  }
}
