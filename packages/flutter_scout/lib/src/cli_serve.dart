part of 'flutter_scout_cli.dart';

// part: serve mode — a loopback HTTP daemon holding ONE persistent VM
// connection, for exploratory agent loops where the agent thinks between
// steps. `batch` removes per-step overhead for scripted flows; `serve`
// removes it for interactive ones: each request costs an HTTP round trip
// (~ms) instead of a fresh Dart VM + WebSocket handshake (~0.5-1.5s).
//
//   flutter-scout serve --port-file /tmp/scout.port \
//     --credential-file /tmp/scout.credential &
//   curl -X POST -H @/tmp/scout.credential \
//     -H 'content-type: application/json' \
//     -d '{"method":"tap","idempotencyKey":"save-order-42","args":["btn.save"],"params":{"expectText":"Saved"}}' \
//     "localhost:$(cat /tmp/scout.port)/v1/call"
//   curl -X POST -H @/tmp/scout.credential \
//     "localhost:$(cat /tmp/scout.port)/stop"

const int _defaultServeMaxBodyBytes = 64 * 1024;
const int _defaultServeRequestTimeoutSeconds = 30;
const String _serveAuthorizationHeader = 'authorization';
const String _serveDeadlineHeader = 'x-flutter-scout-deadline-ms';

class _ServeConfiguration {
  const _ServeConfiguration({
    required this.credential,
    required this.credentialFile,
    required this.allowLegacyRun,
    required this.maxBodyBytes,
    required this.requestTimeout,
  });

  final String credential;
  final String credentialFile;
  final bool allowLegacyRun;
  final int maxBodyBytes;
  final Duration requestTimeout;
}

class _ServeRequestException implements Exception {
  const _ServeRequestException(this.statusCode, this.code, this.message);

  final int statusCode;
  final String code;
  final String message;
}

extension _CliServe on FlutterScoutCli {
  Future<int> _explore(List<String> args) async {
    final parser = ArgParser()
      ..addFlag('once', negatable: false, help: 'Print setup JSON and exit.')
      ..addOption('port', defaultsTo: '0', help: '0 picks a free port.')
      ..addOption(
        'credential-file',
        help: 'Write the owner-only HTTP authorization header here.',
      )
      ..addOption(
        'request-timeout',
        defaultsTo: '$_defaultServeRequestTimeoutSeconds',
        help: 'Maximum request deadline in seconds.',
      )
      ..addOption(
        'max-body-bytes',
        defaultsTo: '$_defaultServeMaxBodyBytes',
        help: 'Maximum accepted HTTP request body size.',
      )
      ..addFlag(
        'allow-legacy-run',
        defaultsTo: false,
        negatable: false,
        help: 'Opt in to authenticated free-form POST /run compatibility.',
      )
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
      final credentialFile =
          parsed.option('credential-file') ?? '$portFile.credential';
      _printJson({
        'ok': true,
        'mode': 'persistent_explore',
        'command':
            'flutter-scout explore --port ${parsed.option('port')} '
            '--port-file $portFile --credential-file $credentialFile',
        'portFile': portFile,
        'credentialFile': credentialFile,
        'endpoints': [
          '/v1/schema',
          '/v1/call',
          '/health',
          '/stop',
          if (parsed.flag('allow-legacy-run')) '/run',
        ],
        'legacyRunEnabled': parsed.flag('allow-legacy-run'),
        'reason':
            'Use one persistent VM connection for exploratory agent loops.',
      });
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
      ..addFlag(
        'allow-legacy-run',
        defaultsTo: false,
        negatable: false,
        help: 'Opt in to authenticated free-form POST /run compatibility.',
      )
      ..addOption(
        'request-timeout',
        defaultsTo: '$_defaultServeRequestTimeoutSeconds',
        help: 'Maximum request deadline in seconds.',
      )
      ..addOption(
        'max-body-bytes',
        defaultsTo: '$_defaultServeMaxBodyBytes',
        help: 'Maximum accepted HTTP request body size.',
      )
      ..addOption(
        'credential-file',
        help: 'Write the ephemeral owner-only HTTP authorization header here.',
      )
      ..addOption(
        'port-file',
        help: 'Write the bound port here so callers can discover it.',
      );
    final parsed = parser.parse(args);
    final port = int.tryParse(parsed.option('port') ?? '');
    if (port == null || port < 0 || port > 65535) {
      throw const ScoutCliException(
        'usage',
        '--port must be an integer from 0 to 65535.',
      );
    }
    final idleTimeout = Duration(
      seconds: int.tryParse(parsed.option('idle-timeout') ?? '') ?? 0,
    );
    if (idleTimeout.isNegative) {
      throw const ScoutCliException(
        'usage',
        '--idle-timeout must be zero or a positive number of seconds.',
      );
    }
    final requestTimeoutSeconds = int.tryParse(
      parsed.option('request-timeout') ?? '',
    );
    if (requestTimeoutSeconds == null ||
        requestTimeoutSeconds < 1 ||
        requestTimeoutSeconds > 300) {
      throw const ScoutCliException(
        'usage',
        '--request-timeout must be an integer from 1 to 300 seconds.',
      );
    }
    final maxBodyBytes = int.tryParse(parsed.option('max-body-bytes') ?? '');
    if (maxBodyBytes == null || maxBodyBytes < 1 || maxBodyBytes > 1048576) {
      throw const ScoutCliException(
        'usage',
        '--max-body-bytes must be an integer from 1 to 1048576.',
      );
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final boundPort = server.port;
    final hadReuse = _reuseVmConnection;
    _reuseVmConnection = true;
    final portFile = parsed.option('port-file');
    final credentialFile = p.normalize(
      p.absolute(
        parsed.option('credential-file') ??
            (portFile != null && portFile.isNotEmpty
                ? '$portFile.credential'
                : p.join(_sessionDir.path, 'serve.credential')),
      ),
    );
    final credential = _newServeCredential();
    final serveInstanceId = _newServeCredential();
    final serveProcessIdentity = await _readProcessOwnershipIdentity(
      pid,
      role: _serveProcessRole,
    );
    final configuration = _ServeConfiguration(
      credential: credential,
      credentialFile: credentialFile,
      allowLegacyRun: parsed.flag('allow-legacy-run'),
      maxBodyBytes: maxBodyBytes,
      requestTimeout: Duration(seconds: requestTimeoutSeconds),
    );
    var lastRequestAt = DateTime.now();
    Timer? idleTimer;
    try {
      _writeServeCredentialFile(credentialFile, credential);
      final existingMeta = _readSessionMeta() ?? <String, dynamic>{};
      _writeSessionMeta({
        ...existingMeta,
        'serve': {
          'pid': pid,
          'instanceId': serveInstanceId,
          'sessionDirectory': _sessionDir.path,
          'processIdentity': ?serveProcessIdentity,
          'port': boundPort,
          'startedAt': DateTime.now().toIso8601String(),
          'credentialFile': credentialFile,
          'legacyRunEnabled': configuration.allowLegacyRun,
          'requestTimeoutSeconds': requestTimeoutSeconds,
          'maxBodyBytes': maxBodyBytes,
          if (parsed.flag('auto')) 'automatic': true,
          if (idleTimeout > Duration.zero)
            'idleTimeoutSeconds': idleTimeout.inSeconds,
        },
      });
      if (portFile != null && portFile.isNotEmpty) {
        _writeServePortFile(portFile, boundPort);
      }
      _printJson({
        'serving': true,
        'address': InternetAddress.loopbackIPv4.address,
        'port': boundPort,
        'credentialFile': credentialFile,
        'authentication': 'bearer',
        'legacyRunEnabled': configuration.allowLegacyRun,
        'limits': {
          'maxBodyBytes': maxBodyBytes,
          'requestTimeoutMs': configuration.requestTimeout.inMilliseconds,
        },
        'endpoints': [
          '/v1/schema',
          '/v1/call',
          '/health',
          '/stop',
          if (configuration.allowLegacyRun) '/run',
        ],
      });
      if (idleTimeout > Duration.zero) {
        idleTimer = Timer.periodic(const Duration(seconds: 5), (_) {
          if (DateTime.now().difference(lastRequestAt) >= idleTimeout) {
            unawaited(server.close(force: true));
          }
        });
      }
      await for (final request in server) {
        lastRequestAt = DateTime.now();
        try {
          final done = await _handleServeRequest(
            request,
            boundPort,
            configuration,
          );
          if (done) break;
        } catch (_) {
          // One broken request must not take the daemon down.
          try {
            await _writeServeResponse(
              request.response,
              HttpStatus.internalServerError,
              const <String, Object?>{
                'ok': false,
                'error': <String, Object?>{
                  'code': 'internal_server_error',
                  'message': 'The request could not be completed.',
                },
              },
            );
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
          serve['port'] == boundPort &&
          serve['credentialFile'] == credentialFile &&
          serve['instanceId'] == serveInstanceId) {
        final updated = Map<String, dynamic>.from(meta)..remove('serve');
        _writeSessionMeta(updated);
      }
      _deleteServeCredentialFileIfOwned(credentialFile, credential);
    }
    _printJson({'serving': false});
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
    final credentialFile = serve['credentialFile']?.toString();
    final authorization = credentialFile == null
        ? null
        : _readServeAuthorizationHeader(credentialFile);
    if (port == null ||
        servePid == null ||
        authorization == null ||
        !await _matchesOwnedServeProcess(servePid, serve)) {
      if (meta != null) {
        final updated = Map<String, dynamic>.from(meta)..remove('serve');
        _writeSessionMeta(updated);
      }
      return null;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    final callerProvidedIdempotencyKey = _activeCallerIdempotencyKey != null;
    final generatedForMutation =
        !callerProvidedIdempotencyKey && _proxyCommandMayMutate(args);
    final proxyIdempotencyKey =
        _activeCallerIdempotencyKey ?? _newProtocolIdentifier('proxy');
    // Keep a generated proxy key active for the local fallback path too. If
    // the HTTP response is lost after dispatch, the second process path can
    // only reconcile this same identity through the durable receipt.
    if (generatedForMutation) {
      _adoptGeneratedIdempotencyKey(proxyIdempotencyKey);
    }
    try {
      final request = await client
          .postUrl(Uri.parse('http://127.0.0.1:$port/v1/call'))
          .timeout(const Duration(seconds: 2));
      request.headers
        ..contentType = ContentType.json
        ..set(_serveAuthorizationHeader, authorization)
        ..set(
          _serveDeadlineHeader,
          '${(int.tryParse('${serve['requestTimeoutSeconds'] ?? ''}') ?? _defaultServeRequestTimeoutSeconds) * 1000}',
        );
      request.write(
        jsonEncode({
          'method': args.first,
          'idempotencyKey': proxyIdempotencyKey,
          'args': args.skip(1).toList(growable: false),
        }),
      );
      final response = await request.close().timeout(
        Duration(
          seconds:
              (int.tryParse('${serve['requestTimeoutSeconds'] ?? ''}') ??
                  _defaultServeRequestTimeoutSeconds) +
              2,
        ),
      );
      final body = await utf8.decoder.bind(response).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      if (response.statusCode != HttpStatus.ok) {
        _printJson(
          !generatedForMutation
              ? decoded
              : _withGeneratedProxyRetryKey(decoded, proxyIdempotencyKey),
        );
        return 1;
      }
      final result = decoded['result'];
      final output = result ?? decoded;
      _printJson(
        !generatedForMutation
            ? output
            : _withGeneratedProxyRetryKey(output, proxyIdempotencyKey),
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
      // Reads retry normally. Mutations also fall back, but only because the
      // same key was durably reserved before daemon dispatch. The local path
      // will replay/reconcile that exact invocation or abstain; it cannot
      // create a second mutation identity.
      return null;
    } finally {
      client.close(force: true);
    }
  }

  bool _proxyCommandMayMutate(List<String> args) {
    final command = args.first;
    if (command == 'annotations') {
      final action = args.length > 1 ? args[1] : 'list';
      return !const <String>{'list', 'targets', 'get-crop'}.contains(action);
    }
    return const <String>{
      'back',
      'deeplink',
      'dismiss',
      'drag-cancel',
      'drag-end',
      'drag-move',
      'drag-start',
      'fill',
      'input',
      'long-press',
      'reload',
      'restart',
      'reveal',
      'scroll',
      'scroll-to',
      'swipe',
      'tap',
      'tap-text',
    }.contains(command);
  }

  Object? _withGeneratedProxyRetryKey(Object? value, String key) {
    if (value is! Map) return value;
    final output = <String, Object?>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
    final metadata = output['idempotency'];
    output
      ..['idempotencyKey'] = key
      ..['idempotencyKeyDigest'] = _idempotencyKeyDigest(key)
      ..['idempotency'] = <String, Object?>{
        if (metadata is Map)
          for (final entry in metadata.entries)
            entry.key.toString(): entry.value,
        'keySource': 'generated',
        'idempotencyKeyDigest': _idempotencyKeyDigest(key),
      };
    return output;
  }

  String _newServeCredential() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<bool> _matchesOwnedServeProcess(int processId, Object? value) async {
    if (value is! Map) return false;
    final recordedPid = int.tryParse('${value['pid'] ?? ''}');
    final instanceId = value['instanceId']?.toString();
    final sessionDirectory = value['sessionDirectory']?.toString();
    final expectedIdentity = value['processIdentity'];
    if (recordedPid != processId ||
        instanceId == null ||
        instanceId.length < 32 ||
        sessionDirectory != _sessionDir.path ||
        expectedIdentity is! Map) {
      return false;
    }
    final currentIdentity = await _readProcessOwnershipIdentity(
      processId,
      role: _serveProcessRole,
    );
    if (currentIdentity == null ||
        !_sameProcessOwnershipIdentity(expectedIdentity, currentIdentity)) {
      return false;
    }
    final command = await _processCommand(processId);
    return command != null &&
        _commandLooksLikeScoutCli(command) &&
        RegExp(r'(?:^|\s)(?:serve|explore)(?:\s|$)').hasMatch(command);
  }

  String _serveAuthorizationValue(String credential) => 'Bearer $credential';

  void _writeServePortFile(String path, int port) {
    _atomicWriteOwnerOnlyString(path, '$port');
  }

  void _writeServeCredentialFile(String path, String credential) {
    final file = File(path);
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link) {
      _unsafeStoragePath(path, 'symbolic-link credential files are forbidden');
    }
    if (file.existsSync() && _readServeAuthorizationHeader(path) == null) {
      throw ScoutCliException(
        'credential_file_exists',
        'Refusing to replace non-Scout credential file `$path`.',
      );
    }
    _atomicWriteOwnerOnlyString(
      path,
      'Authorization: ${_serveAuthorizationValue(credential)}\n',
    );
  }

  String? _readServeAuthorizationHeader(String path) {
    try {
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() > 256) return null;
      final line = file.readAsStringSync().trim();
      final match = RegExp(
        r'^Authorization:\s*Bearer\s+([A-Za-z0-9_-]{43})$',
        caseSensitive: false,
      ).firstMatch(line);
      return match == null ? null : 'Bearer ${match.group(1)}';
    } catch (_) {
      return null;
    }
  }

  void _deleteServeCredentialFileIfOwned(String path, String credential) {
    final expected = _serveAuthorizationValue(credential);
    if (_readServeAuthorizationHeader(path) != expected) return;
    try {
      File(path).deleteSync();
    } catch (_) {
      // A stale owner-only credential is inert after its daemon exits.
    }
  }

  /// Handles one request; returns true when the daemon should stop.
  Future<bool> _handleServeRequest(
    HttpRequest request,
    int port,
    _ServeConfiguration configuration,
  ) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      final remoteAddress = request.connectionInfo?.remoteAddress;
      if (remoteAddress == null || !remoteAddress.isLoopback) {
        throw const _ServeRequestException(
          HttpStatus.forbidden,
          'loopback_required',
          'Flutter Scout persistent transport accepts loopback clients only.',
        );
      }
      switch (request.uri.path) {
        case '/health':
          _requireServeMethod(request, const {'GET'});
          _requireNoServeQuery(request);
          _requireServeAuthorization(request, port, configuration);
          await _writeServeResponse(
            response,
            HttpStatus.ok,
            await _persistentHealthPayload(port),
            commandName: 'health',
          );
          return false;
        case '/v1/schema':
          _requireServeMethod(request, const {'GET'});
          _requireNoServeQuery(request);
          await _writeServeResponse(
            response,
            HttpStatus.ok,
            _agentProtocolSchema(port, configuration),
          );
          return false;
        case '/stop':
          _requireServeMethod(request, const {'POST'});
          _requireNoServeQuery(request);
          _requireServeAuthorization(request, port, configuration);
          final started = Stopwatch()..start();
          final deadline = _serveRequestDeadline(request, configuration);
          final body = await _readBoundedServeBody(
            request,
            configuration.maxBodyBytes,
            _remainingServeDeadline(deadline, started),
          );
          if (body.trim().isNotEmpty) {
            throw const _ServeRequestException(
              HttpStatus.badRequest,
              'unexpected_body',
              'POST /stop does not accept a request body.',
            );
          }
          await _writeServeResponse(response, HttpStatus.ok, {
            'ok': true,
            'stopping': true,
          });
          return true;
        case '/v1/call':
          _requireServeMethod(request, const {'POST'});
          _requireNoServeQuery(request);
          _requireServeAuthorization(request, port, configuration);
          _requireServeContentType(request, ContentType.json.mimeType);
          final started = Stopwatch()..start();
          final deadline = _serveRequestDeadline(request, configuration);
          final body = await _readBoundedServeBody(
            request,
            configuration.maxBodyBytes,
            _remainingServeDeadline(deadline, started),
          );
          await _writeServeOperation(
            response,
            _runTypedCall(body),
            _remainingServeDeadline(deadline, started),
          );
          return false;
        case '/run':
          if (!configuration.allowLegacyRun) {
            throw const _ServeRequestException(
              HttpStatus.notFound,
              'legacy_run_disabled',
              'Legacy free-form execution is disabled. Use POST /v1/call or '
                  'restart serve with --allow-legacy-run.',
            );
          }
          _requireServeMethod(request, const {'POST'});
          _requireNoServeQuery(request);
          _requireServeAuthorization(request, port, configuration);
          _requireServeContentType(request, ContentType.text.mimeType);
          final started = Stopwatch()..start();
          final deadline = _serveRequestDeadline(request, configuration);
          final body = await _readBoundedServeBody(
            request,
            configuration.maxBodyBytes,
            _remainingServeDeadline(deadline, started),
          );
          await _writeServeOperation(
            response,
            _runCaptured(body),
            _remainingServeDeadline(deadline, started),
          );
          return false;
        default:
          throw _ServeRequestException(
            HttpStatus.notFound,
            'unknown_endpoint',
            'Unknown endpoint `${request.uri.path}`.',
          );
      }
    } on _ServeRequestException catch (error) {
      if (error.statusCode == HttpStatus.unauthorized) {
        response.headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Bearer realm="flutter-scout"',
        );
      }
      if (error.statusCode == HttpStatus.methodNotAllowed) {
        response.headers.set(
          HttpHeaders.allowHeader,
          _allowedServeMethods(request),
        );
      }
      await _writeServeResponse(response, error.statusCode, {
        'ok': false,
        'error': {'code': error.code, 'message': error.message},
      });
      return false;
    }
  }

  void _requireServeMethod(HttpRequest request, Set<String> allowed) {
    if (allowed.contains(request.method)) return;
    throw _ServeRequestException(
      HttpStatus.methodNotAllowed,
      'method_not_allowed',
      '${allowed.join(' or ')} is required for `${request.uri.path}`.',
    );
  }

  String _allowedServeMethods(HttpRequest request) =>
      switch (request.uri.path) {
        '/health' || '/v1/schema' => 'GET',
        '/v1/call' || '/run' || '/stop' => 'POST',
        _ => '',
      };

  void _requireNoServeQuery(HttpRequest request) {
    if (!request.uri.hasQuery) return;
    throw const _ServeRequestException(
      HttpStatus.badRequest,
      'query_not_allowed',
      'This endpoint does not accept URL query parameters.',
    );
  }

  void _requireServeAuthorization(
    HttpRequest request,
    int port,
    _ServeConfiguration configuration,
  ) {
    String? provided;
    try {
      provided = request.headers.value(_serveAuthorizationHeader);
    } catch (_) {
      provided = null;
    }
    if (!_constantTimeEquals(
      provided ?? '',
      _serveAuthorizationValue(configuration.credential),
    )) {
      throw const _ServeRequestException(
        HttpStatus.unauthorized,
        'invalid_credential',
        'A valid ephemeral Flutter Scout bearer credential is required.',
      );
    }
    final fetchSite = request.headers.value('sec-fetch-site')?.toLowerCase();
    if (fetchSite == 'cross-site') {
      throw const _ServeRequestException(
        HttpStatus.forbidden,
        'cross_site_request_rejected',
        'Cross-site browser requests are not accepted.',
      );
    }
    final origin = request.headers.value('origin');
    if (origin == null || origin.isEmpty) return;
    final uri = Uri.tryParse(origin);
    final loopbackOrigin =
        uri != null &&
        (uri.host == 'localhost' ||
            uri.host == InternetAddress.loopbackIPv4.address ||
            uri.host == InternetAddress.loopbackIPv6.address) &&
        uri.port == port &&
        (uri.scheme == 'http' || uri.scheme == 'https');
    if (!loopbackOrigin) {
      throw const _ServeRequestException(
        HttpStatus.forbidden,
        'origin_not_allowed',
        'Browser origins must match this loopback Flutter Scout server.',
      );
    }
  }

  bool _constantTimeEquals(String first, String second) {
    final length = max(first.length, second.length);
    var difference = first.length ^ second.length;
    for (var index = 0; index < length; index++) {
      final firstCode = index < first.length ? first.codeUnitAt(index) : 0;
      final secondCode = index < second.length ? second.codeUnitAt(index) : 0;
      difference |= firstCode ^ secondCode;
    }
    return difference == 0;
  }

  void _requireServeContentType(HttpRequest request, String expected) {
    final actual = request.headers.contentType?.mimeType.toLowerCase();
    if (actual == expected) return;
    throw _ServeRequestException(
      HttpStatus.unsupportedMediaType,
      'unsupported_content_type',
      'Content-Type `$expected` is required for `${request.uri.path}`.',
    );
  }

  Duration _serveRequestDeadline(
    HttpRequest request,
    _ServeConfiguration configuration,
  ) {
    final raw = request.headers.value(_serveDeadlineHeader);
    if (raw == null || raw.trim().isEmpty) return configuration.requestTimeout;
    final milliseconds = int.tryParse(raw.trim());
    if (milliseconds == null ||
        milliseconds < 1 ||
        milliseconds > configuration.requestTimeout.inMilliseconds) {
      throw _ServeRequestException(
        HttpStatus.badRequest,
        'invalid_deadline',
        'Header `$_serveDeadlineHeader` must be from 1 to '
            '${configuration.requestTimeout.inMilliseconds}.',
      );
    }
    return Duration(milliseconds: milliseconds);
  }

  Duration _remainingServeDeadline(Duration deadline, Stopwatch elapsed) {
    final remaining = deadline - elapsed.elapsed;
    if (remaining > Duration.zero) return remaining;
    throw const _ServeRequestException(
      HttpStatus.requestTimeout,
      'request_deadline_exceeded',
      'The request deadline expired before command dispatch.',
    );
  }

  Future<String> _readBoundedServeBody(
    HttpRequest request,
    int maxBytes,
    Duration deadline,
  ) async {
    final declaredLength = request.contentLength;
    if (declaredLength > maxBytes) {
      throw _ServeRequestException(
        HttpStatus.requestEntityTooLarge,
        'request_body_too_large',
        'Request bodies are limited to $maxBytes bytes.',
      );
    }
    final builder = BytesBuilder(copy: false);
    try {
      await (() async {
        await for (final chunk in request) {
          if (builder.length + chunk.length > maxBytes) {
            throw _ServeRequestException(
              HttpStatus.requestEntityTooLarge,
              'request_body_too_large',
              'Request bodies are limited to $maxBytes bytes.',
            );
          }
          builder.add(chunk);
        }
      })().timeout(deadline);
      return utf8.decode(builder.takeBytes(), allowMalformed: false);
    } on TimeoutException {
      throw const _ServeRequestException(
        HttpStatus.requestTimeout,
        'request_deadline_exceeded',
        'The request deadline expired while reading its body.',
      );
    } on FormatException {
      throw const _ServeRequestException(
        HttpStatus.badRequest,
        'invalid_utf8',
        'The request body must contain valid UTF-8.',
      );
    }
  }

  Future<void> _writeServeOperation(
    HttpResponse response,
    Future<Map<String, Object?>> operation,
    Duration deadline,
  ) async {
    try {
      final result = await operation.timeout(deadline);
      await _writeServeResponse(response, HttpStatus.ok, result);
    } on TimeoutException {
      await _writeServeResponse(response, HttpStatus.gatewayTimeout, {
        'ok': false,
        'error': {
          'code': 'request_deadline_exceeded',
          'message': 'The command exceeded the HTTP request deadline.',
          'outcome': 'dispatch_outcome_unknown',
        },
      });
      // Preserve the single-command invariant: do not accept the next queued
      // mutation while this uncancellable command is still completing.
      try {
        await operation;
      } catch (_) {}
    }
  }

  Future<void> _writeServeResponse(
    HttpResponse response,
    int statusCode,
    Map<String, Object?> body, {
    String? commandName,
  }) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    var envelope = _cliResponseEnvelope(body, commandName: commandName);
    envelope = _withCliSerializeProbe(
      Map<String, dynamic>.from(envelope),
      probeValue: envelope,
      boundary: 'cli_http_response',
      valueIsSanitized: true,
    );
    response.write(
      _encodeCliMachineMessage(envelope, pretty: false, valueIsSanitized: true),
    );
    await response.close();
  }

  Future<Map<String, Object?>> _runCaptured(String command) async {
    final argv = FlutterScoutCli.splitCommandLine(command);
    return _runCapturedArgs(argv);
  }

  Future<Map<String, Object?>> _runTypedCall(String body) async {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) {
        return _typedRequestError('invalid_request', 'Expected a JSON object.');
      }
      const envelopeKeys = {
        'method',
        'app',
        'idempotencyKey',
        'args',
        'params',
      };
      final unknownEnvelopeKeys = [
        for (final key in decoded.keys)
          if (key is! String || !envelopeKeys.contains(key)) key.toString(),
      ];
      if (unknownEnvelopeKeys.isNotEmpty) {
        return _typedRequestError(
          'unknown_request_field',
          'Unknown typed request field(s): ${unknownEnvelopeKeys.join(', ')}.',
        );
      }
      final rawApp = decoded['app'];
      if (rawApp != null &&
          (rawApp is! String ||
              rawApp.isEmpty ||
              rawApp.length > 128 ||
              rawApp.contains('\u0000'))) {
        return _typedRequestError(
          'invalid_app',
          '`app` must be a non-empty string of at most 128 characters.',
        );
      }

      final rawIdempotencyKey = decoded['idempotencyKey'];
      if (rawIdempotencyKey != null && rawIdempotencyKey is! String) {
        return _typedRequestError(
          'invalid_idempotency_key',
          '`idempotencyKey` must be a string when supplied.',
        );
      }
      String? idempotencyKey;
      if (rawIdempotencyKey is String) {
        try {
          idempotencyKey = _validateCallerIdempotencyKey(rawIdempotencyKey);
        } on ScoutCliException catch (error) {
          return _typedRequestError(error.code, error.message);
        }
      }

      final validation = _validatePersistentTypedPayload(decoded);
      final issue = validation.issue;
      if (issue != null) return _typedRequestError(issue.code, issue.message);
      final call = validation.call!;

      final argv = <String>[
        if (rawApp is String) ...['--app', rawApp],
        if (idempotencyKey != null) ...['--idempotency-key', idempotencyKey],
        call.method,
        ...call.positional,
        ..._typedParamsToArgs(call.parameters),
      ];
      return await _runCapturedArgs(argv);
    } on FormatException {
      return _typedRequestError('invalid_json', 'Expected valid JSON.');
    } catch (_) {
      return _typedRequestError(
        'invalid_request',
        'The typed request could not be processed.',
      );
    }
  }

  Map<String, Object?> _typedRequestError(String code, String message) => {
    'exitCode': 1,
    'error': {'code': code, 'message': message},
  };

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

  Map<String, Object?> _agentProtocolSchema(
    int port,
    _ServeConfiguration configuration,
  ) => {
    'ok': true,
    'protocol': 'flutter-scout-agent',
    'version': 2,
    'port': port,
    'authentication': {
      'scheme': 'bearer',
      'header': _serveAuthorizationHeader,
      'credentialFile': configuration.credentialFile,
      'requiredFor': [
        '/v1/call',
        '/stop',
        if (configuration.allowLegacyRun) '/run',
      ],
    },
    'limits': {
      'maxBodyBytes': configuration.maxBodyBytes,
      'defaultDeadlineMs': configuration.requestTimeout.inMilliseconds,
      'maximumDeadlineMs': configuration.requestTimeout.inMilliseconds,
      'deadlineHeader': _serveDeadlineHeader,
    },
    'legacyRun': {
      'enabled': configuration.allowLegacyRun,
      'optInFlag': '--allow-legacy-run',
      'method': 'POST',
      'contentType': 'text/plain',
    },
    'call': {
      'method': 'POST',
      'path': '/v1/call',
      'contentType': 'application/json',
      'shape': {
        'method': 'tap',
        'app': 'optional-session-name',
        'idempotencyKey': 'save-order-42',
        'args': ['btn.save'],
        'params': {
          'expectText': 'Saved',
          'capture': '/tmp/saved.png',
          'assertNoErrors': true,
        },
      },
      'idempotency': {
        'callerKeyField': 'idempotencyKey',
        'generatedWhenOmitted': true,
        'sameKeySameBusinessRequest': 'replay_original_outcome',
        'sameKeyDifferentBusinessRequest': 'idempotency_conflict',
        'uncertainOutcomeAfterRuntimeReplacement': 'dispatch_outcome_unknown',
      },
    },
    'methods': _typedMethodContracts.keys.toList()..sort(),
    'parameterAllowlist': {
      for (final entry in _typedMethodContracts.entries)
        entry.key: entry.value.parameters.keys.toList()..sort(),
    },
    'methodDescriptors': _persistentTypedMethodCatalog(),
    'requestDiscriminator': _persistentCallDiscriminators(),
  };

  Future<Map<String, Object?>> _runCapturedArgs(List<String> argv) async {
    if (argv.isEmpty) {
      return {'exitCode': 1, 'error': 'empty command'};
    }
    var commandIndex = 0;
    while (commandIndex < argv.length) {
      final value = argv[commandIndex];
      if (value == '--app' || value == '--idempotency-key') {
        commandIndex += 2;
        continue;
      }
      if (value.startsWith('--app=') ||
          value.startsWith('--idempotency-key=')) {
        commandIndex += 1;
        continue;
      }
      break;
    }
    if (commandIndex >= argv.length) {
      return {'exitCode': 1, 'error': 'missing command'};
    }
    final command = argv[commandIndex];
    if (command == 'serve' || command == 'explore') {
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
    final capturedStructuredError = _lastCapturedStructuredError(
      capturedErr.text,
    );
    return {
      'exitCode': exitCode,
      if (result != null) 'result': result else 'output': capturedOut.text,
      if (capturedErr.text.isNotEmpty) 'stderr': capturedErr.text,
      if (error != null)
        'error': error
      else if (capturedStructuredError != null) ...{
        'error': capturedStructuredError,
        'structuredError': capturedStructuredError,
      },
    };
  }

  Map<String, Object?>? _lastCapturedStructuredError(String value) {
    for (final line in value.trim().split('\n').reversed) {
      if (line.trim().isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } catch (_) {
        continue;
      }
      if (decoded is! Map || decoded['ok'] != false) continue;
      final candidate = decoded['structuredError'] ?? decoded['error'];
      if (candidate is! Map) continue;
      return <String, Object?>{
        for (final entry in candidate.entries)
          entry.key.toString(): entry.value,
      };
    }
    return null;
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
