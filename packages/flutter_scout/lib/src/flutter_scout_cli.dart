import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

part 'cli_batch.dart';
part 'cli_serve.dart';
part 'cli_models.dart';
part 'cli_session.dart';
part 'cli_annotations.dart';
part 'cli_actions.dart';
part 'cli_capture.dart';
part 'cli_evidence.dart';
part 'cli_results.dart';

class FlutterScoutCli {
  /// Test-only override for the session registry path, so tests never touch
  /// the real `~/.flutter_scout/registry.json`.
  static String? debugRegistryPathOverride;

  /// Helper protocol version this CLI is built against. Keep in sync with
  /// `scoutHelperProtocolVersion` in flutter_scout_helper — the helper echoes
  /// its version in every response, and a lower value means the running app
  /// compiled an older helper (typically the git/pub-cache dependency trap
  /// where hot reload silently keeps old code).
  static const int expectedHelperProtocolVersion = 5;

  /// Test-only view of response protocol diagnostics.
  Map<String, dynamic> debugProtocolDiagnostics(
    String method,
    Map<String, dynamic> result,
  ) => _withProtocolDiagnostics(method, result);

  // Batch-mode connection cache: one WebSocket serves every step of a batch
  // instead of connect/dispose per command. See cli_batch.dart.
  bool _reuseVmConnection = false;
  VmService? _cachedVmService;
  String? _cachedVmUri;

  /// Splits a batch script into commands on `;` and newlines, honoring
  /// single/double quotes so quoted arguments can contain separators.
  static List<String> splitBatchScript(String script) {
    final commands = <String>[];
    final current = StringBuffer();
    var inSingle = false;
    var inDouble = false;
    for (var i = 0; i < script.length; i++) {
      final char = script[i];
      if (inSingle) {
        current.write(char);
        if (char == "'") inSingle = false;
        continue;
      }
      if (inDouble) {
        current.write(char);
        if (char == '"') inDouble = false;
        continue;
      }
      if (char == "'") {
        inSingle = true;
        current.write(char);
        continue;
      }
      if (char == '"') {
        inDouble = true;
        current.write(char);
        continue;
      }
      if (char == ';' || char == '\n') {
        final command = current.toString().trim();
        if (command.isNotEmpty && !command.startsWith('#')) {
          commands.add(command);
        }
        current.clear();
        continue;
      }
      current.write(char);
    }
    final tail = current.toString().trim();
    if (tail.isNotEmpty && !tail.startsWith('#')) commands.add(tail);
    return commands;
  }

  /// Quotes one argument for a batch script so splitCommandLine reproduces
  /// it exactly: bare when safe, single-quoted when possible, double-quoted
  /// with escapes otherwise.
  static String quoteBatchArg(String value) {
    if (value.isEmpty) return "''";
    if (RegExp(r'^[A-Za-z0-9._\-=/:@,+]+$').hasMatch(value)) return value;
    if (!value.contains("'") && !value.contains('\n') && !value.contains(';')) {
      return "'$value'";
    }
    final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  /// Shell-like argv splitter for one batch command: whitespace separates,
  /// single quotes are literal, double quotes allow \" and \\ escapes.
  static List<String> splitCommandLine(String line) {
    final args = <String>[];
    final current = StringBuffer();
    var inSingle = false;
    var inDouble = false;
    var hasToken = false;
    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (inSingle) {
        if (char == "'") {
          inSingle = false;
        } else {
          current.write(char);
        }
        continue;
      }
      if (inDouble) {
        if (char == '"') {
          inDouble = false;
        } else if (char == r'\' &&
            i + 1 < line.length &&
            (line[i + 1] == '"' || line[i + 1] == r'\')) {
          current.write(line[++i]);
        } else {
          current.write(char);
        }
        continue;
      }
      if (char == "'") {
        inSingle = true;
        hasToken = true;
        continue;
      }
      if (char == '"') {
        inDouble = true;
        hasToken = true;
        continue;
      }
      if (char == r'\' && i + 1 < line.length) {
        current.write(line[++i]);
        hasToken = true;
        continue;
      }
      if (char == ' ' || char == '\t') {
        if (hasToken || current.isNotEmpty) {
          args.add(current.toString());
          current.clear();
          hasToken = false;
        }
        continue;
      }
      current.write(char);
      hasToken = true;
    }
    if (hasToken || current.isNotEmpty) args.add(current.toString());
    return args;
  }

  Future<int> run(List<String> args) async {
    if (args.isEmpty || args.first == '--help' || args.first == '-h') {
      _printUsage();
      return 0;
    }

    // Global `--app <name>`: run this command against the named session
    // (registered by launch/ensure --name) from anywhere — no cd dance.
    var effectiveArgs = args;
    String? appName;
    for (var i = 0; i < effectiveArgs.length; i++) {
      final arg = effectiveArgs[i];
      if (arg == '--app' && i + 1 < effectiveArgs.length) {
        appName = effectiveArgs[i + 1];
        effectiveArgs = [
          ...effectiveArgs.take(i),
          ...effectiveArgs.skip(i + 2),
        ];
        break;
      }
      if (arg.startsWith('--app=')) {
        appName = arg.substring('--app='.length);
        effectiveArgs = [
          ...effectiveArgs.take(i),
          ...effectiveArgs.skip(i + 1),
        ];
        break;
      }
    }
    if (appName != null && appName.isNotEmpty) {
      final registry = _readScoutRegistry();
      final directory = registry[appName];
      if (directory == null || !Directory(directory).existsSync()) {
        stderr.writeln(
          jsonEncode({
            'ok': false,
            'error': {
              'code': 'session_not_registered',
              'message':
                  'No registered session named `$appName`'
                  '${directory != null ? ' (directory `$directory` is gone)' : ''}. '
                  'Sessions register on launch/ensure --name.',
            },
            'knownSessions': registry.keys.toList(growable: false),
          }),
        );
        return 1;
      }
      Directory.current = directory;
    }

    final command = effectiveArgs.first;
    final rest = effectiveArgs.skip(1).toList(growable: false);
    try {
      return await switch (command) {
        'launch' => _launch(rest),
        'ensure' => _ensure(rest),
        'attach' => _attach(rest),
        'status' => _status(),
        'doctor' => _doctor(rest),
        'stop' => _stop(rest),
        'cleanup' => _stop(rest),
        'inspect' => _inspect(rest),
        'annotations' => _annotations(rest),
        'bounds' => _bounds(rest),
        'tap' => _tap(rest),
        'tap-text' => _tapText(rest),
        'long-press' => _longPress(rest),
        'input' => _input(rest),
        'fill' => _fill(rest),
        'scroll' => _scroll(rest),
        'scroll-to' => _scrollTo(rest),
        'swipe' => _swipe(rest),
        'back' => _back(rest),
        'wait' => _wait(rest),
        'wait-for' => _waitFor(rest),
        'batch' => _batch(rest),
        'export-batch' => _exportBatch(rest),
        'serve' => _serve(rest),
        'apps' => _apps(),
        'reload' => _reload(rest),
        'restart' => _restart(rest),
        'deeplink' => _deeplink(rest),
        'logs' => _logs(rest),
        'vm-log-listener' => _vmLogListener(rest),
        'screenshot' => _screenshot(rest),
        'crop' => _crop(rest),
        'evidence' => _evidence(rest),
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

  bool _inspectChanged(
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
  ) {
    if (before == null || after == null) return before != after;
    return jsonEncode(_compactSummary(before)) !=
        jsonEncode(_compactSummary(after));
  }

  Map<String, Object?> _inspectDelta(
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
  ) {
    if (before == null || after == null) {
      return {'available': false};
    }
    final beforeText = _stringSet(before['visibleText']);
    final afterText = _stringSet(after['visibleText']);
    final beforeFields = _stringKeySet(before['fieldValues']);
    final afterFields = _stringKeySet(after['fieldValues']);
    return {
      'screenChanged': before['screen'] != after['screen'],
      'newText': afterText.difference(beforeText).toList(growable: false),
      'removedText': beforeText.difference(afterText).toList(growable: false),
      'newFields': afterFields.difference(beforeFields).toList(growable: false),
      'removedFields': beforeFields
          .difference(afterFields)
          .toList(growable: false),
    };
  }

  Set<String> _stringSet(Object? value) {
    if (value is! List) return const <String>{};
    return value.map((item) => item.toString()).toSet();
  }

  Set<String> _stringKeySet(Object? value) {
    if (value is! Map) return const <String>{};
    return value.keys.map((item) => item.toString()).toSet();
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

    final fromLogs = await _discoverCurrentVmUri(device: device);
    if (fromLogs != null && fromLogs.uri.isNotEmpty) {
      final uri = _normalizeVmUri(fromLogs.uri);
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
    VmService? service;
    try {
      service = await _connect(uri);
      // A dead app can leave a DDS/VM socket that still completes the WebSocket
      // handshake but never answers RPCs. Require a real response so discovery
      // never hands back a zombie URI that would later hang a readiness check.
      await service.getVM().timeout(const Duration(seconds: 5));
      return const _VmUriValidation(ok: true);
    } catch (error) {
      return _VmUriValidation(ok: false, error: error.toString());
    } finally {
      await service?.dispose();
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

  Future<_ScoutReady> _waitScoutReady(
    String uri, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final deadline = DateTime.now().add(timeout);
    _ScoutReady? last;
    while (DateTime.now().isBefore(deadline)) {
      // Bound each attempt by the remaining budget. The deadline is only
      // re-checked between attempts, so an unbounded attempt (e.g. an RPC to an
      // unresponsive VM service) would otherwise defeat it and hang forever.
      final remaining = deadline.difference(DateTime.now());
      final attemptBudget = remaining < const Duration(seconds: 1)
          ? const Duration(seconds: 1)
          : remaining;
      try {
        last = await _checkScoutReady(uri).timeout(attemptBudget);
      } on TimeoutException {
        return const _ScoutReady(
          ready: false,
          reason: 'helper_extension_check_timeout',
          expected: 'FlutterScoutBinding.ensureInitialized()',
        );
      }
      if (last.ready) return last;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return last ??
        const _ScoutReady(
          ready: false,
          reason: 'helper_extension_check_timeout',
          expected: 'FlutterScoutBinding.ensureInitialized()',
        );
  }

  Future<Map<String, Object?>> _captureScreenshot(String output) async {
    Directory(p.dirname(output)).createSync(recursive: true);
    final macos = await _macosWindowTarget();
    if (macos != null) {
      return _captureMacosWindowScreenshot(output, macos);
    }
    final simTarget = _requireSimulatorScreenshotTarget();
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
    return {'backend': 'ios_simulator', 'device': simTarget};
  }

  String _requireSimulatorScreenshotTarget() {
    final device = _readDevice();
    final deviceInfo = _readDeviceInfo();
    final platform = deviceInfo?['platform']?.toString().toLowerCase();
    final category = deviceInfo?['category']?.toString().toLowerCase();
    final emulator = deviceInfo?['emulator'] == true;
    if (device == null || device.isEmpty) {
      throw const ScoutCliException(
        'screenshot_unsupported_target',
        'No screenshot-capable target is recorded for this session. Attach with --device <ios-simulator-id> for iOS Simulator screenshots, or attach to a reachable macOS Flutter VM service so Scout can find that app window.',
      );
    }
    if (device == 'macos' ||
        platform == 'macos' ||
        category == 'desktop' ||
        emulator == false) {
      throw ScoutCliException(
        'screenshot_unsupported_target',
        'No capturable macOS app window was found for `${deviceInfo?['name'] ?? device}`. Make sure the app window is open and not minimized.',
      );
    }
    if (platform != null && !platform.contains('ios')) {
      throw ScoutCliException(
        'screenshot_unsupported_target',
        'Screenshots and crops currently use xcrun simctl and are only supported for iOS Simulator sessions. The attached target platform is `$platform`.',
      );
    }
    return device;
  }

  Future<Map<String, Object?>> _captureMacosWindowScreenshot(
    String output,
    _MacosWindowTarget target,
  ) async {
    final result = await Process.run('screencapture', [
      '-x',
      '-l',
      target.windowId.toString(),
      output,
    ]);
    if (result.exitCode != 0) {
      throw ScoutCliException(
        'screenshot_failed',
        (result.stderr as String).trim().isEmpty
            ? 'macOS screencapture failed for window ${target.windowId}.'
            : (result.stderr as String).trim(),
      );
    }
    return {
      'backend': 'macos_window',
      'windowId': target.windowId,
      'pid': target.pid,
      'ownerName': target.ownerName,
      if (target.windowName != null && target.windowName!.isNotEmpty)
        'windowName': target.windowName,
      if (target.bounds != null) 'bounds': target.bounds,
    };
  }

  Future<_MacosWindowTarget?> _macosWindowTarget() async {
    if (!await _isMacosScreenshotSession()) return null;
    final vmUri = _readVmUri();
    final listenerPid = vmUri == null
        ? null
        : await _pidForListeningVmPort(vmUri);
    final launchPid = _readPid();
    final pids = <int>[
      ?listenerPid,
      ...await _descendantPids(listenerPid),
      ?launchPid,
      ...await _descendantPids(launchPid),
    ];
    final seen = <int>{};
    for (final pid in pids) {
      if (!seen.add(pid)) continue;
      final target = await _findMacosWindowForPid(pid);
      if (target != null) return target;
    }
    return null;
  }

  Future<bool> _isMacosScreenshotSession() async {
    final device = _readDevice();
    final deviceInfo = _readDeviceInfo();
    final platform = deviceInfo?['platform']?.toString().toLowerCase();
    final category = deviceInfo?['category']?.toString().toLowerCase();
    final emulator = deviceInfo?['emulator'] == true;
    final isRecordedMacos =
        device == 'macos' ||
        platform == 'macos' ||
        category == 'desktop' ||
        emulator == false;
    final vmUri = _readVmUri();
    final listenerPid = vmUri == null
        ? null
        : await _pidForListeningVmPort(vmUri);
    final command = listenerPid == null
        ? null
        : await _processCommand(listenerPid);
    final looksLikeMacosApp =
        command != null && command.contains('.app/Contents/MacOS/');
    return isRecordedMacos || looksLikeMacosApp;
  }

  Future<_MacosWindowTarget?> _findMacosWindowForPid(int pid) async {
    final script = r'''
import Foundation
import CoreGraphics

let pid = Int(CommandLine.arguments[1])!
let options = CGWindowListOption(arrayLiteral: .optionAll, .excludeDesktopElements)
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
  exit(2)
}

func number(_ value: Any?) -> Double {
  if let value = value as? Double { return value }
  if let value = value as? Int { return Double(value) }
  if let value = value as? CGFloat { return Double(value) }
  if let value = value as? NSNumber { return value.doubleValue }
  return 0
}

var best: [String: Any]?
var bestArea = 0.0
for window in windows {
  guard (window[kCGWindowOwnerPID as String] as? Int) == pid else { continue }
  guard (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
  guard number(window[kCGWindowAlpha as String]) > 0 else { continue }
  guard (window[kCGWindowSharingState as String] as? Int ?? 0) != 0 else { continue }
  guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else { continue }
  let width = number(bounds["Width"])
  let height = number(bounds["Height"])
  guard width >= 80 && height >= 80 else { continue }
  let area = width * height
  if area > bestArea {
    bestArea = area
    best = window
  }
}

guard let window = best else {
  exit(3)
}

let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
let output: [String: Any] = [
  "windowId": window[kCGWindowNumber as String] as? Int ?? 0,
  "pid": pid,
  "ownerName": window[kCGWindowOwnerName as String] as? String ?? "",
  "windowName": window[kCGWindowName as String] as? String ?? "",
  "bounds": [
    number(bounds["X"]),
    number(bounds["Y"]),
    number(bounds["Width"]),
    number(bounds["Height"])
  ]
]
let data = try! JSONSerialization.data(withJSONObject: output)
print(String(data: data, encoding: .utf8)!)
''';
    final temp = await File(
      p.join(
        Directory.systemTemp.path,
        'flutter_scout_window_${DateTime.now().microsecondsSinceEpoch}.swift',
      ),
    ).create();
    try {
      await temp.writeAsString(script);
      final result = await Process.run('swift', [temp.path, pid.toString()])
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () =>
                ProcessResult(0, 124, '', 'window lookup timed out'),
          );
      if (result.exitCode != 0) return null;
      final decoded = jsonDecode(result.stdout as String);
      if (decoded is! Map<String, dynamic>) return null;
      return _MacosWindowTarget.fromJson(decoded);
    } finally {
      if (await temp.exists()) {
        await temp.delete();
      }
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
      final negatedError =
          lower.contains('no error') || lower.contains('0 errors');
      final isError =
          !negatedError &&
          (lower.contains('error') ||
              lower.contains('exception') ||
              lower.contains('failed') ||
              lower.contains('fatal'));
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

  List<Object?> _objectList(Object? value) {
    if (value is List) return List<Object?>.from(value);
    return const <Object?>[];
  }

  List<double>? _rectFromNode(Map<String, dynamic> node) {
    final rect = node['rect'];
    if (rect is! List || rect.length < 4) return null;
    final left = (rect[0] as num?)?.toDouble();
    final top = (rect[1] as num?)?.toDouble();
    final width = (rect[2] as num?)?.toDouble();
    final height = (rect[3] as num?)?.toDouble();
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    return [left, top, width, height];
  }

  List<double> _rectCenter(List<double> rect) => [
    rect[0] + rect[2] / 2,
    rect[1] + rect[3] / 2,
  ];

  bool _rectContains(List<double> rect, List<double> point) {
    return point[0] >= rect[0] &&
        point[0] <= rect[0] + rect[2] &&
        point[1] >= rect[1] &&
        point[1] <= rect[1] + rect[3];
  }

  double _rectArea(List<double> rect) => rect[2] * rect[3];

  double _overlapRatio(List<double> a, List<double> b) {
    final left = a[0] > b[0] ? a[0] : b[0];
    final top = a[1] > b[1] ? a[1] : b[1];
    final right = a[0] + a[2] < b[0] + b[2] ? a[0] + a[2] : b[0] + b[2];
    final bottom = a[1] + a[3] < b[1] + b[3] ? a[1] + a[3] : b[1] + b[3];
    final width = right - left;
    final height = bottom - top;
    if (width <= 0 || height <= 0) return 0;
    final smaller = _rectArea(a) < _rectArea(b) ? _rectArea(a) : _rectArea(b);
    if (smaller <= 0) return 0;
    return (width * height) / smaller;
  }

  Map<String, dynamic>? _findNodeInInspect(
    Map<String, dynamic> inspect,
    String target,
  ) {
    for (final groupName in ['interactables', 'fields', 'textTargets']) {
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
    final vm = await service.getVM().timeout(const Duration(seconds: 5));
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

  Future<_DiscoveredVmUri?> _discoverCurrentVmUri({String? device}) async {
    final fromScoutLog = _discoverVmUriFromScoutLog();
    if (fromScoutLog != null) {
      return _DiscoveredVmUri(uri: fromScoutLog, source: 'scout_log');
    }
    final fromSimulatorLog = await _discoverVmUriFromSimulatorLogs(
      device: device,
    );
    if (fromSimulatorLog != null) {
      return _DiscoveredVmUri(uri: fromSimulatorLog, source: 'simulator_log');
    }
    return null;
  }

  Future<_DiscoveredVmUri?> _refreshStaleVmUri({
    required String staleUri,
  }) async {
    final discovered = await _discoverCurrentVmUri(device: _readDevice());
    if (discovered == null) return null;
    final uri = _normalizeVmUri(discovered.uri);
    if (uri == _normalizeVmUri(staleUri)) return null;
    final validation = await _validateVmUri(uri);
    if (!validation.ok) return null;
    File(_vmUriFile).writeAsStringSync(uri);
    await _ensureVmLogListenerForCurrentSession(uri);
    return _DiscoveredVmUri(uri: uri, source: discovered.source);
  }

  String? _discoverVmUriFromScoutLog() {
    final file = File(_logFile);
    if (!file.existsSync()) return null;
    final text = file.readAsStringSync();
    return _extractVmUri(text) ?? _extractFlutterToolVmUri(text);
  }

  Future<_FlutterDevice?> _resolveFlutterDevice(String requested) async {
    // Fastest path: desktop and web targets use fixed Flutter device ids
    // (`macos`, `chrome`, ...) that need no discovery at all, so resolve them
    // from a constant instead of paying ~7s for `flutter devices --machine`.
    final wellKnown = _resolveWellKnownDevice(requested);
    if (wellKnown != null) return wellKnown;
    // Fast path: resolve iOS Simulator targets directly through `xcrun simctl`
    // (~0.1s) instead of booting the Flutter tool via `flutter devices
    // --machine` (~7s). This call runs on every command, so the simctl path
    // shaves seconds off both cold launches and warm `ensure`/`status` loops.
    final simulatorDevice = await _resolveSimulatorDevice(requested);
    if (simulatorDevice != null) return simulatorDevice;
    // Fallback: physical devices are only known to the Flutter tool, so pay the
    // slower discovery cost when neither fast path matches.
    return _resolveDeviceViaFlutter(requested);
  }

  /// Resolves the fixed Flutter desktop/web device ids without spawning a
  /// process. These ids are constants, so `flutter run -d <id>` reports a clear
  /// error later if the platform is not enabled. Fields mirror what `flutter
  /// devices --machine` returns (null platform/category, `emulator: false`), so
  /// downstream screenshot routing is unchanged.
  _FlutterDevice? _resolveWellKnownDevice(String requested) {
    final name = wellKnownDeviceName(requested);
    if (name == null) return null;
    return _FlutterDevice(
      id: requested,
      name: name,
      platform: null,
      category: null,
      emulator: false,
    );
  }

  /// Returns the display name for a fixed Flutter desktop/web device id, or null
  /// for anything that needs real discovery. Exposed for testing.
  static String? wellKnownDeviceName(String id) => const <String, String>{
    'macos': 'macOS',
    'windows': 'Windows',
    'linux': 'Linux',
    'chrome': 'Chrome',
    'edge': 'Edge',
    'web-server': 'Web Server',
  }[id];

  Future<_FlutterDevice?> _resolveSimulatorDevice(String requested) async {
    final ProcessResult result;
    try {
      result = await Process.run('xcrun', [
        'simctl',
        'list',
        'devices',
        '--json',
      ]).timeout(const Duration(seconds: 10));
    } on Object {
      // xcrun missing/unavailable (non-macOS host, no Xcode) -> fall back.
      return null;
    }
    if (result.exitCode != 0) return null;
    final match = parseSimctlDevices(result.stdout as String, requested);
    if (match == null) return null;
    return _FlutterDevice(
      id: match['id'] as String,
      name: match['name'] as String,
      platform: match['platform'] as String,
      category: 'mobile',
      emulator: true,
    );
  }

  /// Finds the simulator matching [requested] (a UDID or device name) within the
  /// `xcrun simctl list devices --json` payload in [jsonOutput].
  ///
  /// Returns a map with `id`, `name`, and `platform`, or null when the payload
  /// is malformed or no available device matches. A UDID match wins
  /// immediately; for name matches a booted device is preferred so the same
  /// device created under multiple runtimes resolves deterministically. Exposed
  /// for testing the parser without spawning a process.
  static Map<String, Object?>? parseSimctlDevices(
    String jsonOutput,
    String requested,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonOutput);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final devices = decoded['devices'];
    if (devices is! Map) return null;

    Map<String, Object?>? nameMatch;
    var nameMatchBooted = false;
    for (final entry in devices.entries) {
      final platform = _platformForSimRuntime(entry.key.toString());
      final list = entry.value;
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map) continue;
        if (item['isAvailable'] != true) continue;
        final udid = item['udid']?.toString();
        if (udid == null || udid.isEmpty) continue;
        final name = item['name']?.toString();
        final booted = item['state']?.toString() == 'Booted';
        if (udid == requested) {
          return {'id': udid, 'name': name ?? udid, 'platform': platform};
        }
        if (name == requested &&
            (nameMatch == null || (booted && !nameMatchBooted))) {
          nameMatch = {'id': udid, 'name': name ?? udid, 'platform': platform};
          nameMatchBooted = booted;
        }
      }
    }
    return nameMatch;
  }

  static String _platformForSimRuntime(String runtime) {
    final lower = runtime.toLowerCase();
    if (lower.contains('watchos')) return 'watchos';
    if (lower.contains('tvos')) return 'tvos';
    if (lower.contains('xros') || lower.contains('visionos')) return 'visionos';
    return 'ios';
  }

  Future<_FlutterDevice?> _resolveDeviceViaFlutter(String requested) async {
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
    for (final line in text.split('\n').reversed) {
      for (final pattern in patterns) {
        final match = pattern.firstMatch(line);
        if (match != null) return match.group(1);
      }
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

  String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

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

  List<Object?> _readSessionActions() {
    final file = File(_sessionFile);
    if (!file.existsSync()) return const <Object?>[];
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is List) return decoded;
    } catch (_) {
      return const <Object?>[];
    }
    return const <Object?>[];
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

  Future<int?> _startVmLogListener({
    required String vmUri,
    required String logFile,
  }) async {
    if (Platform.script.scheme != 'file') {
      return null;
    }
    try {
      final process = await Process.start(Platform.resolvedExecutable, [
        Platform.script.toFilePath(),
        'vm-log-listener',
        '--vm-uri',
        vmUri,
        '--log-file',
        logFile,
      ], mode: ProcessStartMode.detached);
      File(_vmLogListenerPidFile).writeAsStringSync(process.pid.toString());
      return process.pid;
    } catch (error) {
      File(logFile).writeAsStringSync(
        '[flutter_scout] VM logging listener start failed: $error\n',
        mode: FileMode.append,
      );
      return null;
    }
  }

  Future<int?> _ensureVmLogListenerForCurrentSession(String vmUri) async {
    if (await _isAttachOnlySession()) return null;
    final existing = _readVmLogListenerPid();
    if (existing != null) {
      final command = await _processCommand(existing);
      if (command != null && _commandLooksLikeScoutVmLogListener(command)) {
        if (command.contains(vmUri)) return existing;
        Process.killPid(existing);
      }
      _deleteFileIfExists(_vmLogListenerPidFile);
    }
    return _startVmLogListener(vmUri: vmUri, logFile: _logFile);
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

  void _writeDeviceInfo(_FlutterDevice device) {
    _ensureSessionDir();
    File(_deviceInfoFile).writeAsStringSync(jsonEncode(device.toJson()));
  }

  Map<String, dynamic>? _readDeviceInfo() {
    final file = File(_deviceInfoFile);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
    return null;
  }

  int? _readPid() {
    final file = File(_pidFile);
    if (!file.existsSync()) return null;
    return int.tryParse(file.readAsStringSync().trim());
  }

  int? _readVmLogListenerPid() {
    final file = File(_vmLogListenerPidFile);
    if (!file.existsSync()) return null;
    return int.tryParse(file.readAsStringSync().trim());
  }

  void _writeSessionMeta(Map<String, Object?> meta) {
    _ensureSessionDir();
    File(
      _sessionMetaFile,
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(meta));
  }

  Map<String, dynamic>? _readSessionMeta() {
    final file = File(_sessionMetaFile);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
    return null;
  }

  Map<String, Object?> _sessionModeInfo() {
    final meta = _readSessionMeta();
    final pid = _readPid();
    return {
      'mode': meta?['mode'] ?? (pid == null ? 'unknown' : 'legacy'),
      'pid': ?pid,
      'vmLogListenerPid': ?_readVmLogListenerPid(),
      'createdAt': ?meta?['createdAt'],
      'logFile': ?meta?['logFile'],
    };
  }

  Future<bool> _isAttachOnlySession() async {
    final meta = _readSessionMeta();
    if (meta?['mode'] == 'attach_only') return true;
    if (meta?['mode'] == 'scout_owned_flutter_run') return false;
    final pid = _readPid();
    if (pid != null && await _looksLikeScoutFlutterRun(pid)) return false;
    if (pid == null) return false;
    return true;
  }

  Future<Map<String, Object?>> _hotUpdateCapability(String vmUri) async {
    final pid = _readPid();
    final scoutOwned = pid != null && await _looksLikeScoutFlutterRun(pid);
    final listenerPid = await _pidForListeningVmPort(vmUri);
    return {
      'reload': {
        'available': true,
        'method': scoutOwned
            ? 'sigusr1_hot_reload'
            : 'vm_service_reload_sources',
        'preservesState': true,
      },
      'restart': {
        'available': scoutOwned,
        'method': scoutOwned
            ? 'sigusr2_hot_restart'
            : 'unavailable_without_scout_owned_flutter_run',
        'requiresScoutOwnedRun': true,
      },
      'attachOnly': !scoutOwned,
      'scoutPid': ?pid,
      'vmServiceListenerPid': ?listenerPid,
      'nextBestActions': scoutOwned
          ? const [
              'Use flutter-scout reload for Dart-only edits',
              'Use flutter-scout restart when Dart state must reset',
            ]
          : const [
              'Use flutter-scout reload for Dart-only edits through the VM service',
              'Use the owning Flutter terminal or IDE for hot restart',
              'Run flutter-scout ensure --device <sim-id> --project <path> when Scout should own restart/log capture',
            ],
    };
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

  Future<List<int>> _descendantPids(int? pid) async {
    if (pid == null) return const <int>[];
    final result = <int>[];
    final queue = <int>[pid];
    final seen = <int>{pid};
    while (queue.isNotEmpty) {
      final parent = queue.removeAt(0);
      final children = await _childPids(parent);
      for (final child in children) {
        if (!seen.add(child)) continue;
        result.add(child);
        queue.add(child);
      }
    }
    return result;
  }

  Future<List<int>> _childPids(int pid) async {
    try {
      final result = await Process.run('pgrep', ['-P', '$pid']).timeout(
        const Duration(seconds: 2),
        onTimeout: () => ProcessResult(0, 1, '', ''),
      );
      if (result.exitCode != 0) return const <int>[];
      return (result.stdout as String)
          .split('\n')
          .map((line) => int.tryParse(line.trim()))
          .nonNulls
          .toList(growable: false);
    } catch (_) {
      return const <int>[];
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

  Future<bool> _looksLikeScoutVmLogListener(int pid) async {
    final command = await _processCommand(pid);
    if (command == null) return false;
    return _commandLooksLikeScoutVmLogListener(command);
  }

  bool _commandLooksLikeScoutVmLogListener(String command) {
    final lower = command.toLowerCase();
    final hasScoutCommand =
        lower.contains('flutter_scout') || lower.contains('flutter-scout');
    return hasScoutCommand && lower.contains('vm-log-listener');
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
  flutter-scout launch --device <simulator-id> [--project <path>] [--name <label>]
  flutter-scout ensure --device <simulator-id> [--project <path>] [--name <label>]
  flutter-scout status
  flutter-scout doctor [--project <path>] [--device <simulator-id>]
  flutter-scout stop [--clear-session]
  flutter-scout inspect
  flutter-scout annotations [list|targets|enable|disable|clear|resolve|dismiss|reopen|fixed|check]
  flutter-scout annotations wait [--timeout <seconds>] [--poll <ms>]
  flutter-scout annotations fixed <annotation-id> [--note <text>]
  flutter-scout bounds [target]
  flutter-scout tap <target> | tap <x> <y> | --x <x> --y <y> [--verbose]
  flutter-scout tap-text <visible text> [--allow-mismatch] [--verbose]
  flutter-scout long-press <target> [--verbose]
  flutter-scout input [--target <field>] <value> [--verbose]
  flutter-scout fill --json <object> [--verbose]
  flutter-scout scroll [up|down|left|right] [--target <target>] [--distance <px>] [--x <x> --y <y> | --from x,y] [--verbose]
  flutter-scout scroll-to <target> [--max-scrolls <n>] [--direction down|up|left|right] [--distance <px>] [--verbose]
  flutter-scout swipe [up|down|left|right] [--target <target>] [--distance <px>] [--x <x> --y <y> | --from x,y] [--to x,y] [--verbose]
  flutter-scout back [--verbose]
  flutter-scout wait stable
  flutter-scout reload [--verbose]
  flutter-scout restart [--verbose]
  flutter-scout deeplink <url>
  flutter-scout logs [--last <n>] [--contains <text>] [--summary]
  flutter-scout screenshot [-o <path>] [--target <target>] [--native]
  flutter-scout crop <target> [-o <path>] [--native]
  flutter-scout evidence [-o <dir>] [--last <n>]
  flutter-scout replay [session.json] [--verbose]
''');
  }

  bool _isNumeric(String value) => double.tryParse(value) != null;
}

/// Compile-time define the CLI injects (via `--name`) so the in-app helper can
/// render an instance-label badge. Lets several worktree sessions of the same
/// macOS/desktop app be told apart on screen. Must match the key the helper
/// reads with `String.fromEnvironment`.
const String kScoutInstanceDefine = 'FLUTTER_SCOUT_INSTANCE';

/// Global session registry: `--name <label>` at launch/ensure records
/// label -> session directory here, and the global `--app <label>` option
/// runs any command against that session from anywhere — no cd required.
File get _scoutRegistryFile => File(
  FlutterScoutCli.debugRegistryPathOverride ??
      p.join(
        Platform.environment['HOME'] ?? Directory.current.path,
        '.flutter_scout',
        'registry.json',
      ),
);

Map<String, String> _readScoutRegistry() {
  try {
    final file = _scoutRegistryFile;
    if (!file.existsSync()) return {};
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return {};
    return {
      for (final entry in decoded.entries)
        if (entry.value is String) entry.key.toString(): entry.value as String,
    };
  } catch (_) {
    return {};
  }
}

void _registerScoutSession(String name, String directory) {
  try {
    final registry = _readScoutRegistry();
    registry[name] = directory;
    _scoutRegistryFile.parent.createSync(recursive: true);
    _scoutRegistryFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(registry),
    );
  } catch (_) {
    // Registration is best-effort; the session still works from its own cwd.
  }
}

/// Drops registry names pointing at [directory] (a cleared session). Returns
/// the pruned names.
List<String> _pruneScoutRegistryFor(String directory) {
  try {
    // getcwd resolves symlinks (macOS /var -> /private/var) while registry
    // entries keep the path as given; compare fully-resolved paths.
    String resolved(String path) {
      try {
        return Directory(path).resolveSymbolicLinksSync();
      } catch (_) {
        return p.normalize(p.absolute(path));
      }
    }

    final target = resolved(directory);
    final registry = _readScoutRegistry();
    final pruned = [
      for (final entry in registry.entries)
        if (resolved(entry.value) == target) entry.key,
    ];
    if (pruned.isEmpty) return const [];
    pruned.forEach(registry.remove);
    _scoutRegistryFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(registry),
    );
    return pruned;
  } catch (_) {
    return const [];
  }
}

Directory get _sessionDir =>
    Directory(p.join(Directory.current.path, '.flutter_scout'));
String get _vmUriFile => p.join(_sessionDir.path, 'vm_uri.txt');
String get _deviceFile => p.join(_sessionDir.path, 'device.txt');
String get _deviceInfoFile => p.join(_sessionDir.path, 'device_info.json');
String get _sessionFile => p.join(_sessionDir.path, 'session.json');
String get _pidFile => p.join(_sessionDir.path, 'flutter.pid');
String get _vmLogListenerPidFile =>
    p.join(_sessionDir.path, 'vm_log_listener.pid');
String get _logFile => p.join(_sessionDir.path, 'logs.txt');
String get _sessionMetaFile => p.join(_sessionDir.path, 'session_meta.json');

void _ensureSessionDir() {
  _sessionDir.createSync(recursive: true);
}
