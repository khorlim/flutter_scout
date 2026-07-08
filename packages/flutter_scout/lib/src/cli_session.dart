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
      ..addMultiOption('dart-define')
      ..addMultiOption('dart-define-from-file')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final device = parsed.option('device');
    if (device == null || device.isEmpty) {
      throw const ScoutCliException(
        'missing_device',
        'Usage: flutter-scout launch --device <simulator-id> [--project <path>] [--name <label>]',
      );
    }
    final project = p.normalize(p.absolute(parsed.option('project')!));
    final projectDir = Directory(project);
    if (!projectDir.existsSync()) {
      throw ScoutCliException('project_missing', 'Project not found: $project');
    }
    final instanceName = parsed.option('name');
    if (instanceName != null && instanceName.isNotEmpty) {
      // Session files live in the cwd; register it so `--app <name>` can
      // address this session from anywhere.
      _registerScoutSession(instanceName, Directory.current.path);
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
    Directory(p.dirname(_logFile)).createSync(recursive: true);
    File(_logFile).writeAsStringSync('');
    final flutterArgs = <String>[
      'run',
      '-d',
      resolvedDevice.id,
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
        '--dart-define',
        '$kScoutInstanceDefine=${parsed.option('name')}',
      ],
      if (parsed.flag('verbose')) '--verbose',
    ];

    _writeProgress('start_flutter_run', {
      'device': resolvedDevice.id,
      'deviceName': resolvedDevice.name,
      'project': project,
    });
    final launchTiming = _LaunchTiming(startedAt: DateTime.now());
    final process = await Process.start('/bin/bash', [
      '-lc',
      'cd ${_shellQuote(project)} && exec flutter ${flutterArgs.map(_shellQuote).join(' ')} >> ${_shellQuote(_logFile)} 2>&1',
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
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(deadline)) {
      final logFile = File(_logFile);
      if (logFile.existsSync()) {
        final currentLines = _readLogLinesSync(logFile);
        for (final line in currentLines.skip(readLineCount)) {
          handleLine(line);
          vmUri ??= _extractVmUri(line) ?? _extractFlutterToolVmUri(line);
        }
        readLineCount = currentLines.length;
        if (vmUri != null) break;
      }
      if (!await _processExists(process.pid)) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    for (final subscription in signalSubscriptions) {
      await subscription.cancel();
    }

    if (vmUri == null) {
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
    final vmLogListenerPid = await _startVmLogListener(
      vmUri: wsUri,
      logFile: _logFile,
    );
    _writeSessionMeta({
      'mode': 'scout_owned_flutter_run',
      'pid': process.pid,
      'vmLogListenerPid': ?vmLogListenerPid,
      'logFile': _logFile,
      'project': project,
      'device': resolvedDevice.id,
      'createdAt': DateTime.now().toIso8601String(),
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
        'pid': process.pid,
        'vmLogListenerPid': ?vmLogListenerPid,
        'vmServiceUri': wsUri,
        'logFile': _logFile,
        'timing': launchTiming.toJson(completedAt: launchTiming.readyAt),
      }),
    );
    return ready.ready ? 0 : 1;
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
    _writeSessionMeta({
      'mode': 'attach_only',
      'vmServiceUri': wsUri,
      if (parsed.option('device') != null) 'device': parsed.option('device'),
      'createdAt': DateTime.now().toIso8601String(),
    });
    final output = <String, Object?>{
      'attached': true,
      'reusedRunningApp': true,
      'vmServiceUri': wsUri,
      'appStatePreserved': true,
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
      _registerScoutSession(instanceName, Directory.current.path);
    }
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
        final pid = _readPid();
        final scoutOwned = pid != null && await _looksLikeScoutFlutterRun(pid);
        _writeSessionMeta({
          'mode': scoutOwned ? 'scout_owned_flutter_run' : 'attach_only',
          'vmServiceUri': discovered.uri,
          'pid': ?pid,
          if (scoutOwned) 'logFile': _logFile,
          'device': ?device,
          'createdAt': DateTime.now().toIso8601String(),
        });
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

  /// Lists sessions registered via launch/ensure `--name`, addressable with
  /// the global `--app <name>` option.
  Future<int> _apps() async {
    final registry = _readScoutRegistry();
    stdout.writeln(
      jsonEncode({
        'ok': true,
        'sessions': [
          for (final entry in registry.entries)
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
      return {'running': false, 'session': _sessionModeInfo()};
    }
    final stale = await _validateVmUri(vmUri);
    if (stale.ok) {
      await _ensureVmLogListenerForCurrentSession(vmUri);
      return {
        'running': true,
        'vmServiceUri': vmUri,
        if (_readDevice() != null) 'device': _readDevice(),
        if (_readDeviceInfo() != null) 'deviceInfo': _readDeviceInfo(),
        'session': _sessionModeInfo(),
        'hotUpdate': await _hotUpdateCapability(vmUri),
      };
    }
    final refreshed = await _refreshStaleVmUri(staleUri: vmUri);
    if (refreshed != null) {
      return {
        'running': true,
        'vmServiceUri': refreshed.uri,
        'staleVmServiceUri': vmUri,
        'staleRefreshed': true,
        'refreshSource': refreshed.source,
        if (_readDevice() != null) 'device': _readDevice(),
        if (_readDeviceInfo() != null) 'deviceInfo': _readDeviceInfo(),
        'session': _sessionModeInfo(),
        'hotUpdate': await _hotUpdateCapability(refreshed.uri),
      };
    }
    _clearVmUriFile();
    return {
      'running': false,
      'staleVmServiceUri': vmUri,
      'staleCleared': true,
      'session': _sessionModeInfo(),
      if (stale.error != null) 'reason': stale.error,
    };
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
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'ok': true,
        'cli': {'available': true, 'sessionDir': _sessionDir.path},
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

  Future<int> _stop(List<String> args) async {
    final parser = ArgParser()
      ..addFlag('clear-session', defaultsTo: false, negatable: false);
    final parsed = parser.parse(args);
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
    _deleteFileIfExists(_pidFile);
    _deleteFileIfExists(_vmLogListenerPidFile);
    var registryPruned = const <String>[];
    if (parsed.flag('clear-session')) {
      _clearVmUriFile();
      _deleteFileIfExists(_deviceFile);
      _deleteFileIfExists(_deviceInfoFile);
      _deleteFileIfExists(_sessionFile);
      _deleteFileIfExists(_sessionMetaFile);
      registryPruned = _pruneScoutRegistryFor(Directory.current.path);
    }
    stdout.writeln(
      jsonEncode({
        'ok': true,
        'pid': pid,
        'vmServiceListenerPid': listenerPid,
        'vmLogListenerPid': vmLogListenerPid,
        'processExisted': processExisted,
        'vmServiceListenerExisted': listenerExisted,
        'vmLogListenerExisted': vmLogListenerExisted,
        'stopped': stopped,
        'pidKillSkippedReason': ?pidKillSkippedReason,
        ...vmLogListenerKillSkippedReason,
        'pidFileCleared': true,
        'vmLogListenerPidFileCleared': true,
        if (parsed.flag('clear-session')) 'sessionCleared': true,
        if (registryPruned.isNotEmpty) 'registryPruned': registryPruned,
      }),
    );
    return 0;
  }
}
