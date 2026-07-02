part of 'flutter_scout_cli.dart';

// part: serve mode — a loopback HTTP daemon holding ONE persistent VM
// connection, for exploratory agent loops where the agent thinks between
// steps. `batch` removes per-step overhead for scripted flows; `serve`
// removes it for interactive ones: each request costs an HTTP round trip
// (~ms) instead of a fresh Dart VM + WebSocket handshake (~0.5-1.5s).
//
//   flutter-scout serve --port-file /tmp/scout.port &
//   curl "localhost:$(cat /tmp/scout.port)/run?cmd=inspect%20--brief"
//   curl "localhost:$(cat /tmp/scout.port)/stop"

extension _CliServe on FlutterScoutCli {
  Future<int> _serve(List<String> args) async {
    final parser = ArgParser()
      ..addOption('port', defaultsTo: '0', help: '0 picks a free port.')
      ..addOption(
        'port-file',
        help: 'Write the bound port here so callers can discover it.',
      );
    final parsed = parser.parse(args);
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      int.tryParse(parsed.option('port') ?? '') ?? 0,
    );
    final hadReuse = _reuseVmConnection;
    _reuseVmConnection = true;
    final portFile = parsed.option('port-file');
    if (portFile != null && portFile.isNotEmpty) {
      File(portFile).writeAsStringSync('${server.port}');
    }
    stdout.writeln(
      jsonEncode({
        'serving': true,
        'port': server.port,
        'endpoints': ['/run?cmd=<command line>', '/health', '/stop'],
      }),
    );
    try {
      await for (final request in server) {
        try {
          final done = await _handleServeRequest(request, server.port);
          if (done) break;
        } catch (_) {
          // One broken request must not take the daemon down.
          try {
            await request.response.close();
          } catch (_) {}
        }
      }
    } finally {
      _reuseVmConnection = hadReuse;
      if (!hadReuse) await _disposeCachedVmService();
      await server.close(force: true);
    }
    stdout.writeln(jsonEncode({'serving': false}));
    return 0;
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
              'message': 'Use /run?cmd=<command>, /health, or /stop.',
            },
          }),
        );
        await response.close();
        return false;
    }
  }

  Future<Map<String, Object?>> _runCaptured(String command) async {
    final argv = FlutterScoutCli.splitCommandLine(command);
    if (argv.isEmpty) {
      return {'exitCode': 1, 'error': 'empty command'};
    }
    if (argv.first == 'serve') {
      return {'exitCode': 1, 'error': 'nested serve is not supported'};
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
    return {
      'exitCode': exitCode,
      'output': capturedOut.text,
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
