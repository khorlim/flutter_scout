part of 'flutter_scout_cli.dart';

// part: serve mode — a loopback HTTP daemon holding ONE persistent VM
// connection, for exploratory agent loops where the agent thinks between
// steps. `batch` removes per-step overhead for scripted flows; `serve`
// removes it for interactive ones: each request costs an HTTP round trip
// (~ms) instead of a fresh Dart VM + WebSocket handshake (~0.5-1.5s).
//
//   flutter-scout serve --port-file /tmp/scout.port &
//   curl "localhost:$(cat /tmp/scout.port)/run?cmd=inspect%20--brief"
//   curl -X POST -H 'content-type: application/json' \
//     -d '{"method":"tap","args":["btn.save"],"params":{"expectText":"Saved"}}' \
//     "localhost:$(cat /tmp/scout.port)/v1/call"
//   curl "localhost:$(cat /tmp/scout.port)/stop"

extension _CliServe on FlutterScoutCli {
  Future<int> _explore(List<String> args) async {
    final parser = ArgParser()
      ..addFlag('once', negatable: false, help: 'Print setup JSON and exit.')
      ..addOption('port', defaultsTo: '0', help: '0 picks a free port.')
      ..addOption(
        'port-file',
        help: 'Write the bound port here so callers can discover it.',
      );
    if (args.contains('--help') || args.contains('-h')) {
      stdout.writeln(
        'Usage: flutter-scout explore [--port <port>] [--port-file <path>] [--once]',
      );
      return 0;
    }
    final parsed = parser.parse(args);
    if (parsed.flag('once')) {
      final portFile =
          parsed.option('port-file') ?? '.flutter_scout/explore_port';
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert({
          'ok': true,
          'mode': 'persistent_explore',
          'command':
              'flutter-scout explore --port ${parsed.option('port')} --port-file $portFile',
          'portFile': portFile,
          'endpoints': [
            '/v1/schema',
            '/v1/call',
            '/run?cmd=<command line>',
            '/health',
            '/stop',
          ],
          'reason':
              'Use one persistent VM connection for exploratory agent loops.',
        }),
      );
      return 0;
    }
    return _serve(args);
  }

  Future<int> _serve(List<String> args) async {
    final parser = ArgParser()
      ..addOption('port', defaultsTo: '0', help: '0 picks a free port.')
      ..addOption(
        'idle-timeout',
        defaultsTo: '0',
        help: 'Stop after this many idle seconds (0 disables timeout).',
      )
      ..addFlag('auto', defaultsTo: false, negatable: false, hide: true)
      ..addOption(
        'port-file',
        help: 'Write the bound port here so callers can discover it.',
      );
    final parsed = parser.parse(args);
    final idleTimeout = Duration(
      seconds: int.tryParse(parsed.option('idle-timeout') ?? '') ?? 0,
    );
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.tryParse(parsed.option('port') ?? '') ?? 0,
    );
    final boundPort = server.port;
    final hadReuse = _reuseVmConnection;
    _reuseVmConnection = true;
    final existingMeta = _readSessionMeta() ?? <String, dynamic>{};
    _writeSessionMeta({
      ...existingMeta,
      'serve': {
        'pid': pid,
        'port': boundPort,
        'startedAt': DateTime.now().toIso8601String(),
        if (parsed.flag('auto')) 'automatic': true,
        if (idleTimeout > Duration.zero)
          'idleTimeoutSeconds': idleTimeout.inSeconds,
      },
    });
    final portFile = parsed.option('port-file');
    if (portFile != null && portFile.isNotEmpty) {
      File(portFile).writeAsStringSync('$boundPort');
    }
    stdout.writeln(
      jsonEncode({
        'serving': true,
        'port': boundPort,
        'endpoints': [
          '/v1/schema',
          '/v1/call',
          '/run?cmd=<command line>',
          '/health',
          '/stop',
        ],
      }),
    );
    var lastRequestAt = DateTime.now();
    Timer? idleTimer;
    if (idleTimeout > Duration.zero) {
      idleTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (DateTime.now().difference(lastRequestAt) >= idleTimeout) {
          unawaited(server.close(force: true));
        }
      });
    }
    try {
      await for (final request in server) {
        lastRequestAt = DateTime.now();
        try {
          final done = await _handleServeRequest(request, boundPort);
          if (done) break;
        } catch (_) {
          // One broken request must not take the daemon down.
          try {
            await request.response.close();
          } catch (_) {}
        }
      }
    } finally {
      idleTimer?.cancel();
      _reuseVmConnection = hadReuse;
      if (!hadReuse) await _disposeCachedVmService();
      await server.close(force: true);
      final meta = _readSessionMeta();
      final serve = meta?['serve'];
      if (meta != null &&
          serve is Map &&
          serve['pid'] == pid &&
          serve['port'] == boundPort) {
        final updated = Map<String, dynamic>.from(meta)..remove('serve');
        _writeSessionMeta(updated);
      }
    }
    stdout.writeln(jsonEncode({'serving': false}));
    return 0;
  }

  Future<void> _maybeStartAutoServe() async {
    if (_reuseVmConnection || _readSessionActions().length < 3) return;
    final meta = _readSessionMeta();
    final name = meta?['name']?.toString();
    if (name == null || name.isEmpty || meta?['serve'] is Map) return;
    if (Platform.script.scheme != 'file') return;
    try {
      await Process.start(Platform.resolvedExecutable, [
        Platform.script.toFilePath(),
        '--app',
        name,
        'serve',
        '--idle-timeout',
        '600',
        '--auto',
      ], mode: ProcessStartMode.detached);
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final serve = _readSessionMeta()?['serve'];
        if (serve is Map && serve['automatic'] == true) {
          _appendEvent({
            'schemaVersion': 1,
            'type': 'transport',
            'commandId': ?_activeCommandId,
            'transport': 'persistent',
            'automatic': true,
            'pid': serve['pid'],
            'port': serve['port'],
          });
          return;
        }
      }
    } catch (_) {
      // Optimization failure must not fail the user action.
    }
  }

  Future<int?> _tryProxyToActiveServe(List<String> args) async {
    final meta = _readSessionMeta();
    final serve = meta?['serve'];
    if (serve is! Map) return null;
    final port = int.tryParse('${serve['port'] ?? ''}');
    final servePid = int.tryParse('${serve['pid'] ?? ''}');
    if (port == null || servePid == null || !await _processExists(servePid)) {
      if (meta != null) {
        final updated = Map<String, dynamic>.from(meta)..remove('serve');
        _writeSessionMeta(updated);
      }
      return null;
    }
    final command = args.map(_shellQuote).join(' ');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final request = await client
          .postUrl(Uri.parse('http://127.0.0.1:$port/run'))
          .timeout(const Duration(seconds: 2));
      request.headers.contentType = ContentType.text;
      request.write(command);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await utf8.decoder.bind(response).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final result = decoded['result'];
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(result ?? decoded),
      );
      return int.tryParse('${decoded['exitCode'] ?? ''}') ?? 1;
    } catch (_) {
      final current = _readSessionMeta();
      final currentServe = current?['serve'];
      if (current != null &&
          currentServe is Map &&
          currentServe['pid'] == servePid &&
          currentServe['port'] == port) {
        final updated = Map<String, dynamic>.from(current)..remove('serve');
        _writeSessionMeta(updated);
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Handles one request; returns true when the daemon should stop.
  Future<bool> _handleServeRequest(HttpRequest request, int port) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    switch (request.uri.path) {
      case '/health':
        response.write(jsonEncode({'ok': true, 'port': port}));
        await response.close();
        return false;
      case '/stop':
        response.write(jsonEncode({'ok': true, 'stopping': true}));
        await response.close();
        return true;
      case '/v1/schema':
        response.write(jsonEncode(_agentProtocolSchema(port)));
        await response.close();
        return false;
      case '/v1/call':
        if (request.method != 'POST') {
          response.statusCode = HttpStatus.methodNotAllowed;
          response.write(
            jsonEncode({
              'ok': false,
              'error': {
                'code': 'method_not_allowed',
                'message': 'POST a JSON request to /v1/call.',
              },
            }),
          );
          await response.close();
          return false;
        }
        final body = await utf8.decoder.bind(request).join();
        response.write(jsonEncode(await _runTypedCall(body)));
        await response.close();
        return false;
      case '/run':
        var command = request.uri.queryParameters['cmd'] ?? '';
        if (command.isEmpty && request.method == 'POST') {
          command = await utf8.decoder.bind(request).join();
        }
        response.write(jsonEncode(await _runCaptured(command)));
        await response.close();
        return false;
      default:
        response.statusCode = HttpStatus.notFound;
        response.write(
          jsonEncode({
            'ok': false,
            'error': {
              'code': 'unknown_endpoint',
              'message':
                  'Use /v1/schema, /v1/call, /run?cmd=<command>, /health, or /stop.',
            },
          }),
        );
        await response.close();
        return false;
    }
  }

  Future<Map<String, Object?>> _runCaptured(String command) async {
    final argv = FlutterScoutCli.splitCommandLine(command);
    return _runCapturedArgs(argv);
  }

  Future<Map<String, Object?>> _runTypedCall(String body) async {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return {
          'exitCode': 1,
          'error': {
            'code': 'invalid_request',
            'message': 'Expected a JSON object.',
          },
        };
      }
      final method = decoded['method']?.toString();
      if (method == null || method.isEmpty) {
        return {
          'exitCode': 1,
          'error': {
            'code': 'missing_method',
            'message': 'The typed request requires `method`.',
          },
        };
      }
      if (!FlutterScoutCli._commands.contains(method)) {
        return {
          'exitCode': 1,
          'error': {
            'code': 'unknown_method',
            'message': 'Unknown Flutter Scout method `$method`.',
          },
        };
      }
      final argv = <String>[
        if (decoded['app']?.toString().isNotEmpty == true) ...[
          '--app',
          decoded['app'].toString(),
        ],
        method,
        if (decoded['args'] is List)
          for (final value in decoded['args'] as List) value.toString(),
        ..._typedParamsToArgs(decoded['params']),
      ];
      return await _runCapturedArgs(argv);
    } catch (error) {
      return {
        'exitCode': 1,
        'error': {'code': 'invalid_json', 'message': error.toString()},
      };
    }
  }

  List<String> _typedParamsToArgs(Object? raw) {
    if (raw is! Map) return const [];
    final args = <String>[];
    for (final entry in raw.entries) {
      final name = entry.key.toString().replaceAllMapped(
        RegExp(r'[A-Z]'),
        (match) => '-${match.group(0)!.toLowerCase()}',
      );
      final value = entry.value;
      if (value == null || value == false) continue;
      if (value == true) {
        args.add('--$name');
      } else if (value is List) {
        for (final item in value) {
          args
            ..add('--$name')
            ..add(item.toString());
        }
      } else if (value is Map || (name == 'json' && value is! String)) {
        args
          ..add('--$name')
          ..add(jsonEncode(value));
      } else {
        args
          ..add('--$name')
          ..add(value.toString());
      }
    }
    return args;
  }

  Map<String, Object?> _agentProtocolSchema(int port) => {
    'ok': true,
    'protocol': 'flutter-scout-agent',
    'version': 1,
    'port': port,
    'call': {
      'method': 'POST',
      'path': '/v1/call',
      'shape': {
        'method': 'tap',
        'app': 'optional-session-name',
        'args': ['btn.save'],
        'params': {
          'expectText': 'Saved',
          'capture': '/tmp/saved.png',
          'assertNoErrors': true,
        },
      },
    },
    'methods': FlutterScoutCli._commands.toList()..sort(),
  };

  Future<Map<String, Object?>> _runCapturedArgs(List<String> argv) async {
    if (argv.isEmpty) {
      return {'exitCode': 1, 'error': 'empty command'};
    }
    if (argv.first == 'serve' || argv.first == 'explore') {
      return {
        'exitCode': 1,
        'error': 'nested persistent mode is not supported',
      };
    }
    final capturedOut = _CapturedStdio();
    final capturedErr = _CapturedStdio();
    var exitCode = 1;
    String? error;
    await IOOverrides.runZoned(
      () async {
        try {
          exitCode = await run(argv);
        } catch (thrown) {
          error = thrown.toString();
        }
      },
      stdout: () => capturedOut,
      stderr: () => capturedErr,
    );
    // Commands print JSON; nest it as a real object so callers parse the
    // response once, not twice (output was a JSON-encoded string). A command
    // that prints multiple JSON objects (batch) or non-JSON keeps its raw
    // text under `output`.
    final text = capturedOut.text.trim();
    Object? result;
    try {
      if (text.isNotEmpty) result = jsonDecode(text);
    } catch (_) {
      result = null;
    }
    return {
      'exitCode': exitCode,
      if (result != null) 'result': result else 'output': capturedOut.text,
      if (capturedErr.text.isNotEmpty) 'stderr': capturedErr.text,
      'error': ?error,
    };
  }
}

/// Minimal in-memory Stdout for capturing command output per serve request.
/// Commands only write text; every other member is a harmless no-op.
class _CapturedStdio implements Stdout {
  final StringBuffer _buffer = StringBuffer();

  String get text => _buffer.toString();

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeln([Object? object = '']) => _buffer.writeln(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  void add(List<int> data) =>
      _buffer.write(utf8.decode(data, allowMalformed: true));

  @override
  Future<void> close() async {}

  @override
  Future<void> flush() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
