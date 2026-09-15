part of 'flutter_scout_cli.dart';

// Agent-only typed dispatch and captured canonical receipts. No HTTP transport.
// Ownership matching remains solely to stop verified pre-cutover daemons.
extension _CliAgentDispatch on FlutterScoutCli {
  List<String> _persistentProxyArguments(List<String> args) {
    final arguments = args.skip(1).toList(growable: false);
    if (args.first != 'tap') return arguments;
    final ArgResults parsed;
    try {
      parsed = _tapArgumentParser().parse(arguments);
    } on FormatException {
      // Preserve normal typed validation for invalid syntax. A user argument
      // error must not be mistaken for a transport failure by the proxy.
      return arguments;
    }
    if (parsed.rest.length != 2 ||
        !parsed.rest.every(_isNumeric) ||
        parsed.option('x') != null ||
        parsed.option('y') != null) {
      return arguments;
    }
    // The CLI supports `tap x y`; the typed API intentionally accepts only
    // one positional target. Normalize this CLI alias without relaxing the
    // server's coordinate bounds, target exclusivity, or parameter types.
    return _typedParamsToArgs(<String, Object?>{
      'x': parsed.rest[0],
      'y': parsed.rest[1],
      for (final name in parsed.options)
        if (parsed.wasParsed(name)) name: parsed[name],
    });
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
    if (command == 'serve' ||
        command == 'explore' ||
        command == 'live' ||
        command == 'agent') {
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
