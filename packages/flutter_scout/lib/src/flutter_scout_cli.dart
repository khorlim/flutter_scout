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
        'inspect' => _callAndPrint('ext.flutter_scout.inspect'),
        'tap' => _tap(rest),
        'long-press' => _longPress(rest),
        'input' => _input(rest),
        'fill' => _fill(rest),
        'scroll' => _scroll(rest),
        'swipe' => _swipe(rest),
        'back' => _callAndPrint('ext.flutter_scout.back'),
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

    _ensureSessionDir();
    Directory(p.dirname(_logFile)).createSync(recursive: true);
    final logSink = File(_logFile).openWrite(mode: FileMode.write);
    final flutterArgs = <String>[
      'run',
      '-d',
      device,
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

    final process = await Process.start(
      'flutter',
      flutterArgs,
      workingDirectory: project,
      mode: ProcessStartMode.detachedWithStdio,
    );
    File(_deviceFile).writeAsStringSync(device);
    File(_pidFile).writeAsStringSync(process.pid.toString());

    final completer = Completer<String?>();
    final lines = <String>[];
    var logOpen = true;
    void handleLine(String line) {
      lines.add(line);
      if (logOpen) {
        logSink.writeln(line);
      }
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
    await _connect(wsUri).then((VmService service) => service.dispose());
    stdout.writeln(
      jsonEncode({
        'launched': true,
        'device': device,
        'project': project,
        'pid': process.pid,
        'vmServiceUri': wsUri,
        'logFile': _logFile,
      }),
    );
    return 0;
  }

  Future<int> _attach(List<String> args) async {
    final parser = ArgParser()
      ..addOption('debug-url')
      ..addOption('device')
      ..addFlag('json', defaultsTo: true);
    final parsed = parser.parse(args);
    final explicit = parsed.option('debug-url');
    final discovered =
        explicit ??
        await _discoverVmUriFromSimulatorLogs(
          device: parsed.option('device'),
        ) ??
        _readVmUri();
    if (discovered == null || discovered.isEmpty) {
      stdout.writeln(
        jsonEncode({
          'attached': false,
          'reason': 'vm_service_uri_not_found',
          'nextBestActions': [
            'Run the app in debug/profile mode and copy the VM Service URL',
            'flutter-scout attach --debug-url <url>',
            'flutter-scout launch --device <simulator-id> --project .',
          ],
        }),
      );
      return 1;
    }

    final wsUri = _normalizeVmUri(discovered);
    await _connect(wsUri).then((VmService service) => service.dispose());
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
    if (device != null) {
      output['device'] = device;
    }
    stdout.writeln(jsonEncode(output));
    return 0;
  }

  Future<int> _status() async {
    final vmUri = _readVmUri();
    if (vmUri == null) {
      stdout.writeln(jsonEncode({'running': false}));
      return 0;
    }
    try {
      final service = await _connect(vmUri);
      await service.dispose();
      stdout.writeln(jsonEncode({'running': true, 'vmServiceUri': vmUri}));
      return 0;
    } catch (_) {
      stdout.writeln(jsonEncode({'running': false, 'vmServiceUri': vmUri}));
      return 0;
    }
  }

  Future<int> _tap(List<String> args) async {
    final parser = ArgParser()
      ..addOption('x')
      ..addOption('y')
      ..addOption('wait-ms', defaultsTo: '1500');
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
    );
  }

  Future<int> _input(List<String> args) async {
    final parser = ArgParser()..addOption('target');
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
    );
  }

  Future<int> _longPress(List<String> args) async {
    final parser = ArgParser()
      ..addOption('duration-ms', defaultsTo: '600')
      ..addOption('x')
      ..addOption('y');
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
    );
  }

  Future<int> _fill(List<String> args) async {
    final parser = ArgParser()..addOption('json');
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
      ..addOption('distance');
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
      ..addOption('last', defaultsTo: '80')
      ..addOption('contains');
    final parsed = parser.parse(args);
    final file = File(_logFile);
    if (!file.existsSync()) {
      stdout.writeln(
        jsonEncode({'ok': true, 'path': _logFile, 'lines': const <String>[]}),
      );
      return 0;
    }
    final contains = parsed.option('contains');
    final last = int.tryParse(parsed.option('last') ?? '') ?? 80;
    var lines = file.readAsLinesSync();
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
    final file = args.isEmpty ? File(_sessionFile) : File(args.first);
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
        'deeplink' => await _replayDeeplink(item['url']?.toString()),
        _ => {'ok': false, 'error': 'unknown replay cmd: $cmd'},
      };
      results.add(result);
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
  }) async {
    final result = await _call(method, params);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
    if (record != null && result['ok'] == true) {
      _recordAction(record);
    }
    return result['ok'] == false ? 1 : 0;
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
      final response = await service
          .callServiceExtension(method, isolateId: isolateId, args: params)
          .timeout(const Duration(seconds: 20));
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

  Future<VmService> _connect(String uri) {
    return vmServiceConnectUri(
      _normalizeVmUri(uri),
    ).timeout(const Duration(seconds: 5));
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

  String? _readVmUri() {
    final file = File(_vmUriFile);
    if (!file.existsSync()) return null;
    final value = file.readAsStringSync().trim();
    return value.isEmpty ? null : value;
  }

  String? _readDevice() {
    final file = File(_deviceFile);
    if (!file.existsSync()) return null;
    final value = file.readAsStringSync().trim();
    return value.isEmpty ? null : value;
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
  flutter-scout inspect
  flutter-scout tap <target> | --x <x> --y <y>
  flutter-scout long-press <target>
  flutter-scout input [--target <field>] <value>
  flutter-scout fill --json <object>
  flutter-scout scroll [up|down|left|right] [--target <target>] [--distance <px>]
  flutter-scout swipe [up|down|left|right] [--target <target>] [--distance <px>]
  flutter-scout back
  flutter-scout wait stable
  flutter-scout deeplink <url>
  flutter-scout logs [--last <n>] [--contains <text>]
  flutter-scout screenshot [-o <path>] [--target <target>]
  flutter-scout crop <target> [-o <path>]
  flutter-scout replay [session.json]
''');
  }
}

class ScoutCliException implements Exception {
  const ScoutCliException(this.code, this.message);

  final String code;
  final String message;
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
