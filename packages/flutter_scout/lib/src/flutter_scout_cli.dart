import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

class FlutterScoutCli {
  Future<int> run(List<String> args) async {
    if (args.isEmpty || args.first == '--help' || args.first == '-h') {
      _printUsage();
      return 0;
    }

    final command = args.first;
    final rest = args.skip(1).toList(growable: false);
    try {
      return await switch (command) {
        'launch' => _launch(rest),
        'attach' => _attach(rest),
        'status' => _status(),
        'doctor' => _doctor(rest),
        'stop' => _stop(rest),
        'cleanup' => _stop(rest),
        'inspect' => _callAndPrint('ext.flutter_scout.inspect'),
        'bounds' => _bounds(rest),
        'tap' => _tap(rest),
        'long-press' => _longPress(rest),
        'input' => _input(rest),
        'fill' => _fill(rest),
        'scroll' => _scroll(rest),
        'swipe' => _swipe(rest),
        'back' => _back(rest),
        'wait' => _wait(rest),
        'deeplink' => _deeplink(rest),
        'logs' => _logs(rest),
        'screenshot' => _screenshot(rest),
        'crop' => _crop(rest),
        'replay' => _replay(rest),
        _ => _unknown(command),
      };
    } on ScoutCliException catch (error) {
      stderr.writeln(
        jsonEncode({
          'ok': false,
          'error': {'code': error.code, 'message': error.message},
        }),
      );
      return 1;
    } catch (error) {
      stderr.writeln(
        jsonEncode({
          'ok': false,
          'error': {'code': 'unexpected_error', 'message': error.toString()},
        }),
      );
      return 1;
    }
  }

  Future<int> _launch(List<String> args) async {
    final parser = ArgParser()
      ..addOption('device', abbr: 'd')
      ..addOption('project', defaultsTo: Directory.current.path)
      ..addOption('target')
      ..addOption('flavor')
      ..addMultiOption('dart-define')
      ..addMultiOption('dart-define-from-file')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final device = parsed.option('device');
    if (device == null || device.isEmpty) {
      throw const ScoutCliException(
        'missing_device',
        'Usage: flutter-scout launch --device <simulator-id> [--project <path>]',
      );
    }
    final project = p.normalize(p.absolute(parsed.option('project')!));
    final projectDir = Directory(project);
    if (!projectDir.existsSync()) {
      throw ScoutCliException('project_missing', 'Project not found: $project');
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
    final logSink = File(_logFile).openWrite(mode: FileMode.write);
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
      if (parsed.flag('verbose')) '--verbose',
    ];

    _writeProgress('start_flutter_run', {
      'device': resolvedDevice.id,
      'deviceName': resolvedDevice.name,
      'project': project,
    });
    final process = await Process.start(
      'flutter',
      flutterArgs,
      workingDirectory: project,
      mode: ProcessStartMode.detachedWithStdio,
    );
    File(_deviceFile).writeAsStringSync(resolvedDevice.id);
    File(_pidFile).writeAsStringSync(process.pid.toString());
    final signalSubscriptions = _installLaunchSignalHandlers(process);

    final completer = Completer<String?>();
    final lines = <String>[];
    var logOpen = true;
    void handleLine(String line) {
      lines.add(line);
      if (logOpen) {
        logSink.writeln(line);
      }
      _writeLaunchProgressFromLine(line);
      final uri = _extractVmUri(line) ?? _extractFlutterToolVmUri(line);
      if (uri != null && !completer.isCompleted) {
        completer.complete(uri);
      }
      if (lines.length > 200 && !completer.isCompleted) {
        lines.removeAt(0);
      }
    }

    final stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(handleLine);
    final stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(handleLine);

    final vmUri = await completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () => null,
    );
    for (final subscription in signalSubscriptions) {
      await subscription.cancel();
    }
    await stdoutSub.cancel();
    await stderrSub.cancel();
    await logSink.flush();
    logOpen = false;
    await logSink.close();

    if (vmUri == null) {
      stdout.writeln(
        jsonEncode({
          'launched': false,
          'reason': 'vm_service_uri_not_found',
          'pid': process.pid,
          'tailLogLines': lines.length > 20
              ? lines.sublist(lines.length - 20)
              : lines,
        }),
      );
      return 1;
    }

    final wsUri = _normalizeVmUri(vmUri);
    File(_vmUriFile).writeAsStringSync(wsUri);
    _writeProgress('verify_vm_service', {'vmServiceUri': wsUri});
    final ready = await _checkScoutReady(wsUri);
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
        'vmServiceUri': wsUri,
        'logFile': _logFile,
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
    final device = parsed.option('device');
    if (device != null && device.isNotEmpty) {
      File(_deviceFile).writeAsStringSync(device);
    }
    final output = <String, Object?>{
      'attached': true,
      'reusedRunningApp': true,
      'vmServiceUri': wsUri,
      'appStatePreserved': true,
    };
    final ready = await _checkScoutReady(wsUri);
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

  Future<int> _status() async {
    final vmUri = _readVmUri();
    if (vmUri == null) {
      stdout.writeln(jsonEncode({'running': false}));
      return 0;
    }
    final stale = await _validateVmUri(vmUri);
    if (stale.ok) {
      stdout.writeln(jsonEncode({'running': true, 'vmServiceUri': vmUri}));
      return 0;
    }
    _clearVmUriFile();
    stdout.writeln(
      jsonEncode({
        'running': false,
        'staleVmServiceUri': vmUri,
        'staleCleared': true,
        if (stale.error != null) 'reason': stale.error,
      }),
    );
    return 0;
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
      final ready = await _checkScoutReady(vmUri);
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
    _deleteFileIfExists(_pidFile);
    if (parsed.flag('clear-session')) {
      _clearVmUriFile();
      _deleteFileIfExists(_deviceFile);
      _deleteFileIfExists(_sessionFile);
    }
    stdout.writeln(
      jsonEncode({
        'ok': true,
        'pid': pid,
        'vmServiceListenerPid': listenerPid,
        'processExisted': processExisted,
        'vmServiceListenerExisted': listenerExisted,
        'stopped': stopped,
        'pidKillSkippedReason': ?pidKillSkippedReason,
        'pidFileCleared': true,
        if (parsed.flag('clear-session')) 'sessionCleared': true,
      }),
    );
    return 0;
  }

  Future<int> _bounds(List<String> args) async {
    final parser = ArgParser()..addOption('target');
    final parsed = parser.parse(args);
    final target =
        parsed.option('target') ??
        (parsed.rest.isEmpty ? null : parsed.rest.first);
    final inspect = await _call('ext.flutter_scout.inspect');
    final nodes = [
      ..._nodesFromInspect(inspect, 'interactables'),
      ..._nodesFromInspect(inspect, 'fields'),
    ];
    final dpr = (inspect['devicePixelRatio'] as num?)?.toDouble() ?? 1;
    if (target != null && target.isNotEmpty) {
      final node = _findNodeInInspect(inspect, target);
      if (node == null) {
        throw ScoutCliException(
          'target_not_found',
          'No inspect target matched `$target`.',
        );
      }
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert({
          'ok': true,
          'target': target,
          'devicePixelRatio': dpr,
          'bounds': _boundsForNode(node, dpr),
        }),
      );
      return 0;
    }
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'ok': true,
        'devicePixelRatio': dpr,
        'logicalSize': inspect['logicalSize'],
        'bounds': [for (final node in nodes) _boundsForNode(node, dpr)],
      }),
    );
    return 0;
  }

  Future<int> _tap(List<String> args) async {
    final parser = ArgParser()
      ..addOption('x')
      ..addOption('y')
      ..addOption('wait-ms', defaultsTo: '1500')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final target = parsed.rest.isEmpty ? null : parsed.rest.first;
    final x = parsed.option('x');
    final y = parsed.option('y');
    if ((target == null || target.isEmpty) && (x == null || y == null)) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout tap <target> or flutter-scout tap --x <x> --y <y>',
      );
    }
    final params = <String, String>{
      'waitMs': parsed.option('wait-ms') ?? '1500',
    };
    if (target != null && target.isNotEmpty) {
      params['target'] = target;
    }
    if (x != null) {
      params['x'] = x;
    }
    if (y != null) {
      params['y'] = y;
    }
    return _callAndPrint(
      'ext.flutter_scout.tap',
      params: params,
      record: {'cmd': 'tap', ...params},
      compact: !parsed.flag('verbose'),
    );
  }

  Future<int> _input(List<String> args) async {
    final parser = ArgParser()
      ..addOption('target')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final valueArgs = parsed.rest;
    if (valueArgs.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout input [--target <field>] <value>',
      );
    }
    final value = valueArgs.join(' ');
    final target = parsed.option('target') ?? 'focused';
    return _callAndPrint(
      'ext.flutter_scout.input',
      params: {'target': target, 'value': value},
      record: {'cmd': 'input', 'target': target, 'value': value},
      compact: !parsed.flag('verbose'),
    );
  }

  Future<int> _longPress(List<String> args) async {
    final parser = ArgParser()
      ..addOption('duration-ms', defaultsTo: '600')
      ..addOption('x')
      ..addOption('y')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final target = parsed.rest.isEmpty ? null : parsed.rest.first;
    if (target == null &&
        (parsed.option('x') == null || parsed.option('y') == null)) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout long-press <target> [--duration-ms <ms>]',
      );
    }
    final params = <String, String>{
      'durationMs': parsed.option('duration-ms') ?? '600',
    };
    if (target != null) {
      params['target'] = target;
    }
    if (parsed.option('x') != null) {
      params['x'] = parsed.option('x')!;
    }
    if (parsed.option('y') != null) {
      params['y'] = parsed.option('y')!;
    }
    return _callAndPrint(
      'ext.flutter_scout.longPress',
      params: params,
      record: {'cmd': 'long-press', ...params},
      compact: !parsed.flag('verbose'),
    );
  }

  Future<int> _fill(List<String> args) async {
    final parser = ArgParser()
      ..addOption('json')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final raw = parsed.option('json');
    if (raw == null || raw.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout fill --json <object>',
      );
    }
    jsonDecode(raw);
    return _callAndPrint(
      'ext.flutter_scout.fill',
      params: {'values': raw},
      record: {'cmd': 'fill', 'values': jsonDecode(raw)},
      compact: !parsed.flag('verbose'),
    );
  }

  Future<int> _wait(List<String> args) async {
    if (args.isNotEmpty && args.first != 'stable') {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout wait stable',
      );
    }
    return _callAndPrint('ext.flutter_scout.waitStable');
  }

  Future<int> _scroll(List<String> args) {
    return _dragCommand(
      method: 'ext.flutter_scout.scroll',
      command: 'scroll',
      defaultDirection: 'down',
      args: args,
    );
  }

  Future<int> _swipe(List<String> args) {
    return _dragCommand(
      method: 'ext.flutter_scout.swipe',
      command: 'swipe',
      defaultDirection: 'left',
      args: args,
    );
  }

  Future<int> _dragCommand({
    required String method,
    required String command,
    required String defaultDirection,
    required List<String> args,
  }) async {
    final parser = ArgParser()
      ..addOption('target')
      ..addOption('distance')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final direction = parsed.rest.isEmpty
        ? defaultDirection
        : parsed.rest.first;
    final params = <String, String>{
      'direction': direction,
      if (parsed.option('target') != null) 'target': parsed.option('target')!,
      if (parsed.option('distance') != null)
        'distance': parsed.option('distance')!,
    };
    return _callAndPrint(
      method,
      params: params,
      record: {'cmd': command, ...params},
      compact: !parsed.flag('verbose'),
    );
  }

  Future<int> _back(List<String> args) async {
    final parser = ArgParser()..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    return _callAndPrint(
      'ext.flutter_scout.back',
      record: const {'cmd': 'back'},
      compact: !parsed.flag('verbose'),
    );
  }

  Future<int> _deeplink(List<String> args) async {
    if (args.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout deeplink <url>',
      );
    }
    final url = args.first;
    await _openDeeplink(url);
    stdout.writeln(jsonEncode({'ok': true, 'url': url}));
    _recordAction({'cmd': 'deeplink', 'url': url});
    return 0;
  }

  Future<int> _logs(List<String> args) async {
    final parser = ArgParser()
      ..addOption('last', defaultsTo: '20')
      ..addOption('contains')
      ..addFlag('summary', defaultsTo: false, negatable: false);
    final parsed = parser.parse(args);
    final file = File(_logFile);
    if (!file.existsSync()) {
      stdout.writeln(
        jsonEncode({
          'ok': true,
          'path': _logFile,
          if (parsed.flag('summary')) ...{
            'errors': 0,
            'warnings': 0,
            'vmServiceUri': null,
            'lastImportantLines': const <String>[],
          } else
            'lines': const <String>[],
        }),
      );
      return 0;
    }
    final contains = parsed.option('contains');
    final last = int.tryParse(parsed.option('last') ?? '') ?? 20;
    var lines = file.readAsLinesSync();
    if (parsed.flag('summary')) {
      final summary = _summarizeLogLines(lines, last: last);
      stdout.writeln(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({'ok': true, 'path': _logFile, ...summary}),
      );
      return 0;
    }
    if (contains != null && contains.isNotEmpty) {
      lines = lines
          .where((line) => line.contains(contains))
          .toList(growable: false);
    }
    if (lines.length > last) {
      lines = lines.sublist(lines.length - last);
    }
    stdout.writeln(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'ok': true, 'path': _logFile, 'lines': lines}),
    );
    return 0;
  }

  Future<int> _screenshot(List<String> args) async {
    final parser = ArgParser()
      ..addOption('output', abbr: 'o')
      ..addOption('target');
    final parsed = parser.parse(args);
    final target = parsed.option('target');
    if (target != null && target.isNotEmpty) {
      return _crop([
        '--target',
        target,
        if (parsed.option('output') != null) ...[
          '--output',
          parsed.option('output')!,
        ],
      ]);
    }
    _ensureSessionDir();
    final output =
        parsed.option('output') ??
        p.join(
          _sessionDir.path,
          'screenshots',
          'screenshot_${DateTime.now().millisecondsSinceEpoch}.png',
        );
    Directory(p.dirname(output)).createSync(recursive: true);
    final device = _readDevice();
    final simTarget = device == null || device.isEmpty ? 'booted' : device;
    final result = await Process.run('xcrun', [
      'simctl',
      'io',
      simTarget,
      'screenshot',
      output,
    ]);
    if (result.exitCode != 0) {
      throw ScoutCliException(
        'screenshot_failed',
        (result.stderr as String).trim(),
      );
    }
    stdout.writeln(jsonEncode({'ok': true, 'path': output}));
    return 0;
  }

  Future<int> _crop(List<String> args) async {
    final parser = ArgParser()
      ..addOption('target')
      ..addOption('output', abbr: 'o')
      ..addOption('padding', defaultsTo: '12');
    final parsed = parser.parse(args);
    final target =
        parsed.option('target') ??
        (parsed.rest.isEmpty ? null : parsed.rest.first);
    if (target == null || target.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout crop <target> [-o <path>]',
      );
    }

    final inspect = await _call('ext.flutter_scout.inspect');
    final node = _findNodeInInspect(inspect, target);
    if (node == null) {
      throw ScoutCliException(
        'target_not_found',
        'No inspect target matched `$target`.',
      );
    }
    final rect = node['rect'];
    if (rect is! List || rect.length < 4) {
      throw ScoutCliException(
        'target_has_no_rect',
        'Target `$target` has no usable rect.',
      );
    }

    _ensureSessionDir();
    final shotPath = p.join(
      _sessionDir.path,
      'screenshots',
      'crop_source_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await _captureScreenshot(shotPath);

    final sourceBytes = File(shotPath).readAsBytesSync();
    final source = img.decodeImage(sourceBytes);
    if (source == null) {
      throw const ScoutCliException(
        'image_decode_failed',
        'Could not decode simulator screenshot.',
      );
    }
    final dpr =
        (inspect['devicePixelRatio'] as num?)?.toDouble() ??
        _inferDevicePixelRatio(inspect, source);
    final padding = int.tryParse(parsed.option('padding') ?? '') ?? 12;
    final left = (((rect[0] as num).toDouble() * dpr) - padding).floor().clamp(
      0,
      source.width - 1,
    );
    final top = (((rect[1] as num).toDouble() * dpr) - padding).floor().clamp(
      0,
      source.height - 1,
    );
    final width = ((((rect[2] as num).toDouble() * dpr) + padding * 2).ceil())
        .clamp(1, source.width - left);
    final height = ((((rect[3] as num).toDouble() * dpr) + padding * 2).ceil())
        .clamp(1, source.height - top);
    final cropped = img.copyCrop(
      source,
      x: left,
      y: top,
      width: width,
      height: height,
    );
    final output =
        parsed.option('output') ??
        p.join(
          _sessionDir.path,
          'crops',
          '${_safeFileName(target)}_${DateTime.now().millisecondsSinceEpoch}.png',
        );
    Directory(p.dirname(output)).createSync(recursive: true);
    File(output).writeAsBytesSync(img.encodePng(cropped));
    stdout.writeln(
      jsonEncode({
        'ok': true,
        'target': target,
        'path': output,
        'source': shotPath,
        'rect': rect,
        'pixelRect': [left, top, width, height],
      }),
    );
    return 0;
  }

  Future<int> _replay(List<String> args) async {
    final parser = ArgParser()..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final file = parsed.rest.isEmpty
        ? File(_sessionFile)
        : File(parsed.rest.first);
    if (!file.existsSync()) {
      throw ScoutCliException(
        'replay_missing',
        'Replay file not found: ${file.path}',
      );
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! List) {
      throw const ScoutCliException(
        'replay_invalid',
        'Replay file must contain a JSON array.',
      );
    }
    final results = <Object?>[];
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      final cmd = item['cmd'];
      final result = switch (cmd) {
        'tap' => await _call('ext.flutter_scout.tap', _stringMap(item)),
        'input' => await _call('ext.flutter_scout.input', {
          'target': item['target'].toString(),
          'value': item['value'].toString(),
        }),
        'fill' => await _call('ext.flutter_scout.fill', {
          'values': jsonEncode(item['values']),
        }),
        'long-press' => await _call('ext.flutter_scout.longPress', {
          'target': item['target'].toString(),
          if (item['durationMs'] != null)
            'durationMs': item['durationMs'].toString(),
        }),
        'scroll' => await _call('ext.flutter_scout.scroll', _stringMap(item)),
        'swipe' => await _call('ext.flutter_scout.swipe', _stringMap(item)),
        'back' => await _call('ext.flutter_scout.back'),
        'deeplink' => await _replayDeeplink(item['url']?.toString()),
        _ => {'ok': false, 'error': 'unknown replay cmd: $cmd'},
      };
      results.add(
        parsed.flag('verbose') || result['ok'] == false
            ? result
            : _compactActionResult(result),
      );
    }
    stdout.writeln(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'ok': true, 'results': results}),
    );
    return 0;
  }

  Future<Map<String, Object?>> _replayDeeplink(String? url) async {
    if (url == null || url.isEmpty) {
      return {'ok': false, 'error': 'deeplink replay missing url'};
    }
    try {
      await _openDeeplink(url);
      return {'ok': true, 'url': url};
    } catch (error) {
      return {'ok': false, 'url': url, 'error': error.toString()};
    }
  }

  Future<int> _callAndPrint(
    String method, {
    Map<String, String> params = const {},
    Map<String, Object?>? record,
    bool compact = false,
  }) async {
    final result = await _call(method, params);
    final output = compact ? _compactActionResult(result) : result;
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(output));
    if (record != null && result['ok'] == true) {
      _recordAction(record);
    }
    return result['ok'] == false ? 1 : 0;
  }

  Map<String, dynamic> _compactActionResult(Map<String, dynamic> result) {
    if (result['ok'] == false) {
      return {
        ...result,
        if (result['recentErrors'] is List)
          'recentErrors': _lastItems(result['recentErrors'] as List, 3),
      };
    }
    final after = result['after'];
    return {
      'ok': result['ok'],
      if (result['action'] != null) 'action': result['action'],
      if (result['stable'] != null) 'stable': result['stable'],
      if (result['result'] != null) 'result': result['result'],
      if (result['filled'] != null) 'filled': result['filled'],
      if (result['failed'] != null) 'failed': result['failed'],
      if (result['popped'] != null) 'popped': result['popped'],
      if (result['target'] is Map<String, dynamic>)
        'target': _compactNode(result['target'] as Map<String, dynamic>),
      if (after is Map<String, dynamic>) 'afterSummary': _compactSummary(after),
      if (result['delta'] != null) 'delta': result['delta'],
      if (result['recentErrors'] is List)
        'recentErrors': _lastItems(result['recentErrors'] as List, 3),
    };
  }

  Map<String, Object?> _compactNode(Map<String, dynamic> node) {
    return {
      'id': node['id'],
      if (node['label'] != null) 'label': node['label'],
      if (node['kind'] != null) 'kind': node['kind'],
      if (node['enabled'] != null) 'enabled': node['enabled'],
    };
  }

  Map<String, Object?> _compactSummary(Map<String, dynamic> summary) {
    return {
      if (summary['screen'] != null) 'screen': summary['screen'],
      if (summary['idle'] != null) 'idle': summary['idle'],
      if (summary['visibleText'] is List)
        'visibleText': _lastItems(summary['visibleText'] as List, 12),
      if (summary['fieldValues'] != null) 'fieldValues': summary['fieldValues'],
    };
  }

  List<Object?> _lastItems(List<dynamic> items, int count) {
    if (items.length <= count) return List<Object?>.from(items);
    return items.sublist(items.length - count);
  }

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, String> params = const {},
  ]) async {
    final uri = _readVmUri();
    if (uri == null || uri.isEmpty) {
      throw const ScoutCliException(
        'not_attached',
        'Run flutter-scout attach --debug-url <url> first.',
      );
    }
    final service = await _connect(uri);
    try {
      final isolateId = await _findMainIsolate(service);
      final Response response;
      try {
        response = await service
            .callServiceExtension(method, isolateId: isolateId, args: params)
            .timeout(const Duration(seconds: 20));
      } on RPCError catch (error) {
        if (_looksLikeMissingScoutExtension(error)) {
          throw const ScoutCliException(
            'flutter_scout_helper_not_registered',
            'VM service is reachable, but ext.flutter_scout is not registered. '
                'Add flutter_scout_helper and call '
                'FlutterScoutBinding.ensureInitialized() before runApp(), or '
                'FlutterScoutHelper.ensureRegistered() after an existing debug '
                'binding is initialized.',
          );
        }
        rethrow;
      }
      final json = response.json;
      if (json == null) return {'ok': false, 'error': 'empty VM response'};
      if (json.containsKey('ok')) {
        return Map<String, dynamic>.from(json);
      }
      final result = json['result'];
      if (result is String) {
        return jsonDecode(result) as Map<String, dynamic>;
      }
      if (result is Map<String, dynamic>) {
        return result;
      }
      return Map<String, dynamic>.from(json);
    } finally {
      await service.dispose();
    }
  }

  bool _looksLikeMissingScoutExtension(RPCError error) {
    final message = error.message;
    return message.contains('ext.flutter_scout') ||
        message.contains('Unknown service extension') ||
        message.contains('Service extension not found') ||
        error.code == -32601;
  }

  Future<VmService> _connect(String uri) {
    return vmServiceConnectUri(
      _normalizeVmUri(uri),
    ).timeout(const Duration(seconds: 5));
  }

  Future<_AttachDiscovery> _discoverAttachVmUri({
    required String? explicit,
    required String? device,
  }) async {
    if (explicit != null && explicit.isNotEmpty) {
      final uri = _normalizeVmUri(explicit);
      final validation = await _validateVmUri(uri);
      if (validation.ok) return _AttachDiscovery(uri: uri);
      return _AttachDiscovery(
        reason: 'vm_service_uri_unreachable',
        staleUri: uri,
        staleCleared: false,
      );
    }

    final fromLogs = await _discoverVmUriFromSimulatorLogs(device: device);
    if (fromLogs != null && fromLogs.isNotEmpty) {
      final uri = _normalizeVmUri(fromLogs);
      final validation = await _validateVmUri(uri);
      if (validation.ok) return _AttachDiscovery(uri: uri);
    }

    final fromSession = _readVmUri();
    if (fromSession != null && fromSession.isNotEmpty) {
      final uri = _normalizeVmUri(fromSession);
      final validation = await _validateVmUri(uri);
      if (validation.ok) return _AttachDiscovery(uri: uri);
      _clearVmUriFile();
      return _AttachDiscovery(
        reason: 'stale_vm_service_uri',
        staleUri: uri,
        staleCleared: true,
      );
    }

    return const _AttachDiscovery(reason: 'vm_service_uri_not_found');
  }

  Future<_VmUriValidation> _validateVmUri(String uri) async {
    try {
      final service = await _connect(uri);
      await service.dispose();
      return const _VmUriValidation(ok: true);
    } catch (error) {
      return _VmUriValidation(ok: false, error: error.toString());
    }
  }

  Future<_ScoutReady> _checkScoutReady(String uri) async {
    try {
      final service = await _connect(uri);
      try {
        final isolateId = await _findMainIsolate(service);
        final isolate = await service
            .getIsolate(isolateId)
            .timeout(const Duration(seconds: 5));
        final extensions = isolate.extensionRPCs ?? const <String>[];
        if (extensions.contains('ext.flutter_scout.inspect')) {
          return const _ScoutReady(ready: true);
        }
        return const _ScoutReady(
          ready: false,
          reason: 'helper_extension_missing',
          expected: 'FlutterScoutBinding.ensureInitialized()',
        );
      } finally {
        await service.dispose();
      }
    } catch (error) {
      return _ScoutReady(
        ready: false,
        reason: 'helper_extension_check_failed',
        expected: 'FlutterScoutBinding.ensureInitialized()',
        detail: error.toString(),
      );
    }
  }

  Future<void> _captureScreenshot(String output) async {
    Directory(p.dirname(output)).createSync(recursive: true);
    final device = _readDevice();
    final simTarget = device == null || device.isEmpty ? 'booted' : device;
    final result = await Process.run('xcrun', [
      'simctl',
      'io',
      simTarget,
      'screenshot',
      output,
    ]);
    if (result.exitCode != 0) {
      throw ScoutCliException(
        'screenshot_failed',
        (result.stderr as String).trim(),
      );
    }
  }

  Future<void> _openDeeplink(String url) async {
    final device = _readDevice();
    final simTarget = device == null || device.isEmpty ? 'booted' : device;
    final result = await Process.run('xcrun', [
      'simctl',
      'openurl',
      simTarget,
      url,
    ]);
    if (result.exitCode != 0) {
      throw ScoutCliException(
        'deeplink_failed',
        (result.stderr as String).trim(),
      );
    }
  }

  Map<String, Object?> _summarizeLogLines(
    List<String> lines, {
    required int last,
  }) {
    final important = <String>[];
    var errors = 0;
    var warnings = 0;
    String? vmServiceUri;
    for (final line in lines) {
      final lower = line.toLowerCase();
      final isError =
          lower.contains('error') ||
          lower.contains('exception') ||
          lower.contains('failed') ||
          lower.contains('fatal');
      final isWarning = lower.contains('warning') || lower.contains('warn ');
      final uri = _extractVmUri(line) ?? _extractFlutterToolVmUri(line);
      if (isError) errors++;
      if (isWarning) warnings++;
      if (uri != null) vmServiceUri = _normalizeVmUri(uri);
      if (isError || isWarning || uri != null) {
        important.add(line);
      }
    }
    final limit = last <= 0 ? 20 : last;
    return {
      'errors': errors,
      'warnings': warnings,
      'vmServiceUri': vmServiceUri,
      'lastImportantLines': important.length > limit
          ? important.sublist(important.length - limit)
          : important,
    };
  }

  List<Map<String, dynamic>> _nodesFromInspect(
    Map<String, dynamic> inspect,
    String groupName,
  ) {
    final group = inspect[groupName];
    if (group is! List) return const <Map<String, dynamic>>[];
    return [
      for (final node in group)
        if (node is Map<String, dynamic>) node,
    ];
  }

  Map<String, Object?> _boundsForNode(Map<String, dynamic> node, double dpr) {
    final rect = node['rect'];
    if (rect is! List || rect.length < 4) {
      return {
        'id': node['id'],
        'label': node['label'],
        'kind': node['kind'],
        'rect': null,
      };
    }
    final left = (rect[0] as num).toDouble();
    final top = (rect[1] as num).toDouble();
    final width = (rect[2] as num).toDouble();
    final height = (rect[3] as num).toDouble();
    return {
      'id': node['id'],
      'fallbackId': node['fallbackId'],
      'label': node['label'],
      'kind': node['kind'],
      'enabled': node['enabled'],
      'rect': [left, top, width, height],
      'center': [left + width / 2, top + height / 2],
      'pixelRect': [
        (left * dpr).round(),
        (top * dpr).round(),
        (width * dpr).round(),
        (height * dpr).round(),
      ],
    };
  }

  Map<String, dynamic>? _findNodeInInspect(
    Map<String, dynamic> inspect,
    String target,
  ) {
    for (final groupName in ['interactables', 'fields']) {
      final group = inspect[groupName];
      if (group is! List) continue;
      for (final node in group) {
        if (node is! Map<String, dynamic>) continue;
        if (_nodeMatches(node, target)) return node;
      }
    }
    return null;
  }

  bool _nodeMatches(Map<String, dynamic> node, String target) {
    final values = [
      node['id'],
      node['fallbackId'],
      node['key'],
      node['label'],
    ].whereType<String>();
    final slug = _slug(target);
    return values.any(
      (value) =>
          value == target || value.endsWith('.$slug') || _slug(value) == slug,
    );
  }

  double _inferDevicePixelRatio(
    Map<String, dynamic> inspect,
    img.Image source,
  ) {
    final logicalSize = inspect['logicalSize'];
    if (logicalSize is List && logicalSize.length >= 2) {
      final width = (logicalSize[0] as num?)?.toDouble();
      if (width != null && width > 0) return source.width / width;
    }
    return 1;
  }

  Map<String, String> _stringMap(Map<String, dynamic> value) {
    final result = <String, String>{};
    for (final entry in value.entries) {
      if (entry.key == 'cmd' || entry.value == null) continue;
      result[entry.key] = entry.value.toString();
    }
    return result;
  }

  Future<String> _findMainIsolate(VmService service) async {
    final vm = await service.getVM();
    final isolates = vm.isolates ?? const <IsolateRef>[];
    if (isolates.isEmpty || isolates.first.id == null) {
      throw const ScoutCliException('no_isolate', 'No Dart isolate found.');
    }
    for (final isolate in isolates) {
      if (isolate.name == 'main' && isolate.id != null) return isolate.id!;
    }
    return isolates.first.id!;
  }

  Future<String?> _discoverVmUriFromSimulatorLogs({String? device}) async {
    final target = device == null || device.isEmpty ? 'booted' : device;
    final predicate = 'eventMessage CONTAINS "[FLUTTER_SCOUT_VM_URI]"';
    try {
      final result =
          await Process.run('xcrun', [
            'simctl',
            'spawn',
            target,
            'log',
            'show',
            '--last',
            '10m',
            '--predicate',
            predicate,
          ]).timeout(
            const Duration(seconds: 5),
            onTimeout: () => ProcessResult(0, 1, '', ''),
          );
      if (result.exitCode != 0) return null;
      return _extractVmUri(result.stdout as String);
    } catch (_) {
      return null;
    }
  }

  Future<_FlutterDevice?> _resolveFlutterDevice(String requested) async {
    final result = await Process.run('flutter', ['devices', '--machine'])
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () => ProcessResult(0, 1, '', 'flutter devices timed out'),
        );
    if (result.exitCode != 0) {
      throw ScoutCliException(
        'device_discovery_failed',
        (result.stderr as String).trim(),
      );
    }
    final decoded = jsonDecode(result.stdout as String);
    if (decoded is! List) {
      throw const ScoutCliException(
        'device_discovery_failed',
        'flutter devices --machine returned an unexpected payload.',
      );
    }
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      final id = item['id']?.toString();
      final name = item['name']?.toString();
      if (id == requested || name == requested) {
        return _FlutterDevice(
          id: id ?? requested,
          name: name ?? requested,
          platform: item['platform']?.toString(),
          category: item['category']?.toString(),
          emulator: item['emulator'] == true,
        );
      }
    }
    return null;
  }

  String? _extractVmUri(String text) {
    final lines = text.split('\n').reversed;
    final pattern = RegExp(
      r'\[FLUTTER_SCOUT_VM_URI\]\s+(https?://\S+|wss?://\S+)',
    );
    for (final line in lines) {
      final match = pattern.firstMatch(line);
      if (match != null) return match.group(1);
    }
    return null;
  }

  String? _extractFlutterToolVmUri(String text) {
    final patterns = [
      RegExp(r'(https?://127\.0\.0\.1:\d+/\S*=/?)'),
      RegExp(r'(https?://localhost:\d+/\S*=/?)'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match != null) return match.group(1);
    }
    return null;
  }

  String _normalizeVmUri(String uri) {
    var value = uri.trim();
    if (value.startsWith('http://')) {
      value = 'ws://${value.substring(7)}';
    } else if (value.startsWith('https://')) {
      value = 'wss://${value.substring(8)}';
    }
    if (!value.endsWith('/ws')) {
      value = value.endsWith('/') ? '${value}ws' : '$value/ws';
    }
    return value;
  }

  String _safeFileName(String value) =>
      _slug(value).isEmpty ? 'target' : _slug(value);

  String _slug(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');

  void _recordAction(Map<String, Object?> action) {
    _ensureSessionDir();
    final file = File(_sessionFile);
    final existing = file.existsSync()
        ? jsonDecode(file.readAsStringSync())
        : <Object?>[];
    final list = existing is List ? existing : <Object?>[];
    list.add(action);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(list));
  }

  List<StreamSubscription<ProcessSignal>> _installLaunchSignalHandlers(
    Process process,
  ) {
    void stopProcess(ProcessSignal signal) {
      process.kill();
      _deleteFileIfExists(_pidFile);
      _writeProgress('stopped_child_process', {
        'signal': signal.toString(),
        'pid': process.pid,
      });
    }

    return [
      ProcessSignal.sigint.watch().listen(stopProcess),
      ProcessSignal.sigterm.watch().listen(stopProcess),
    ];
  }

  void _writeProgress(String phase, [Map<String, Object?> data = const {}]) {
    stderr.writeln(
      jsonEncode({
        'progress': phase,
        'timestamp': DateTime.now().toIso8601String(),
        ...data,
      }),
    );
  }

  void _writeLaunchProgressFromLine(String line) {
    final lower = line.toLowerCase();
    if (lower.contains('resolving dependencies')) {
      _writeProgress('pub_get');
    } else if (lower.contains('launching lib/main.dart') ||
        lower.contains('launching')) {
      _writeProgress('launching_app');
    } else if (lower.contains('xcode build done') ||
        lower.contains('built build/')) {
      _writeProgress('build_done');
    } else if (lower.contains('syncing files to device')) {
      _writeProgress('syncing_files');
    } else if (_extractVmUri(line) != null ||
        _extractFlutterToolVmUri(line) != null) {
      _writeProgress('vm_service_found');
    }
  }

  String? _readVmUri() {
    final file = File(_vmUriFile);
    if (!file.existsSync()) return null;
    final value = file.readAsStringSync().trim();
    return value.isEmpty ? null : value;
  }

  void _clearVmUriFile() {
    _deleteFileIfExists(_vmUriFile);
  }

  String? _readDevice() {
    final file = File(_deviceFile);
    if (!file.existsSync()) return null;
    final value = file.readAsStringSync().trim();
    return value.isEmpty ? null : value;
  }

  int? _readPid() {
    final file = File(_pidFile);
    if (!file.existsSync()) return null;
    return int.tryParse(file.readAsStringSync().trim());
  }

  Future<int?> _pidForListeningVmPort(String vmUri) async {
    final uri = Uri.tryParse(_normalizeVmUri(vmUri));
    final port = uri?.port;
    if (port == null || port <= 0) return null;
    try {
      final result = await Process.run('lsof', ['-tiTCP:$port', '-sTCP:LISTEN'])
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => ProcessResult(0, 1, '', ''),
          );
      if (result.exitCode != 0) return null;
      final firstLine = (result.stdout as String).trim().split('\n').first;
      return int.tryParse(firstLine);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _looksLikeScoutFlutterRun(int pid) async {
    final command = await _processCommand(pid);
    if (command == null) return false;
    final lower = command.toLowerCase();
    final hasFlutterTool =
        lower.contains('flutter_tools') ||
        RegExp(r'(^|[/\s])flutter(\s|$)').hasMatch(lower);
    final hasRunCommand = RegExp(r'(^|\s)run(\s|$)').hasMatch(lower);
    return hasFlutterTool && hasRunCommand;
  }

  Future<bool> _processExists(int pid) async {
    return await _processCommand(pid) != null;
  }

  Future<String?> _processCommand(int pid) async {
    try {
      final result = await Process.run('ps', ['-p', '$pid', '-o', 'command='])
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => ProcessResult(0, 1, '', ''),
          );
      if (result.exitCode != 0) return null;
      final command = (result.stdout as String).trim();
      return command.isEmpty ? null : command;
    } catch (_) {
      return null;
    }
  }

  void _deleteFileIfExists(String path) {
    final file = File(path);
    if (file.existsSync()) {
      file.deleteSync();
    }
  }

  int _unknown(String command) {
    stderr.writeln('Unknown command: $command');
    _printUsage();
    return 64;
  }

  void _printUsage() {
    stdout.writeln('''
Flutter Scout

Usage:
  flutter-scout attach [--debug-url <url>] [--device <simulator-id>]
  flutter-scout launch --device <simulator-id> [--project <path>]
  flutter-scout status
  flutter-scout doctor [--project <path>] [--device <simulator-id>]
  flutter-scout stop [--clear-session]
  flutter-scout inspect
  flutter-scout bounds [target]
  flutter-scout tap <target> | --x <x> --y <y> [--verbose]
  flutter-scout long-press <target> [--verbose]
  flutter-scout input [--target <field>] <value> [--verbose]
  flutter-scout fill --json <object> [--verbose]
  flutter-scout scroll [up|down|left|right] [--target <target>] [--distance <px>] [--verbose]
  flutter-scout swipe [up|down|left|right] [--target <target>] [--distance <px>] [--verbose]
  flutter-scout back [--verbose]
  flutter-scout wait stable
  flutter-scout deeplink <url>
  flutter-scout logs [--last <n>] [--contains <text>] [--summary]
  flutter-scout screenshot [-o <path>] [--target <target>]
  flutter-scout crop <target> [-o <path>]
  flutter-scout replay [session.json] [--verbose]
''');
  }
}

class ScoutCliException implements Exception {
  const ScoutCliException(this.code, this.message);

  final String code;
  final String message;
}

class _AttachDiscovery {
  const _AttachDiscovery({
    this.uri,
    this.reason,
    this.staleUri,
    this.staleCleared = false,
  });

  final String? uri;
  final String? reason;
  final String? staleUri;
  final bool staleCleared;
}

class _VmUriValidation {
  const _VmUriValidation({required this.ok, this.error});

  final bool ok;
  final String? error;
}

class _ScoutReady {
  const _ScoutReady({
    required this.ready,
    this.reason,
    this.expected,
    this.detail,
  });

  final bool ready;
  final String? reason;
  final String? expected;
  final String? detail;
}

class _FlutterDevice {
  const _FlutterDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.category,
    required this.emulator,
  });

  final String id;
  final String name;
  final String? platform;
  final String? category;
  final bool emulator;

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'platform': platform,
      'category': category,
      'emulator': emulator,
    };
  }
}

Directory get _sessionDir =>
    Directory(p.join(Directory.current.path, '.flutter_scout'));
String get _vmUriFile => p.join(_sessionDir.path, 'vm_uri.txt');
String get _deviceFile => p.join(_sessionDir.path, 'device.txt');
String get _sessionFile => p.join(_sessionDir.path, 'session.json');
String get _pidFile => p.join(_sessionDir.path, 'flutter.pid');
String get _logFile => p.join(_sessionDir.path, 'logs.txt');

void _ensureSessionDir() {
  _sessionDir.createSync(recursive: true);
}
