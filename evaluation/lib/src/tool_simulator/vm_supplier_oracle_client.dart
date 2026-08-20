import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tool_simulator_contract.dart';

abstract interface class SupplierOracleClient {
  Future<SupplierOracleObservation> readState();

  Future<SupplierOracleObservation> reset({
    Map<String, Object?>? publicFixture,
  });
}

class SupplierOracleTransportException implements Exception {
  const SupplierOracleTransportException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

abstract interface class VmServiceJsonRpcPeer {
  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> parameters,
  );

  Future<void> close();
}

typedef VmServiceJsonRpcConnector =
    Future<VmServiceJsonRpcPeer> Function(Uri uri);

class VmServiceSupplierOracleClient implements SupplierOracleClient {
  VmServiceSupplierOracleClient({
    required String vmServiceUri,
    required String capability,
    this.timeout = const Duration(seconds: 8),
    VmServiceJsonRpcConnector? connector,
  }) : _webSocketUri = _normalizeLoopbackVmServiceUri(vmServiceUri),
       _capability = capability,
       _connector = connector ?? _connectWebSocketPeer {
    if (capability.length < 32 || capability.trim() != capability) {
      throw ArgumentError.value(
        capability,
        'capability',
        'must be an unpadded token containing at least 32 characters',
      );
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
  }

  final Uri _webSocketUri;
  final String _capability;
  final VmServiceJsonRpcConnector _connector;
  final Duration timeout;
  int _requestSequence = 0;

  @override
  Future<SupplierOracleObservation> readState() =>
      _call(supplierWorkflowOracleStateMethod, 'state');

  @override
  Future<SupplierOracleObservation> reset({
    Map<String, Object?>? publicFixture,
  }) => _call(
    supplierWorkflowOracleResetMethod,
    'reset',
    publicFixture: publicFixture,
  );

  Future<SupplierOracleObservation> _call(
    String method,
    String operation, {
    Map<String, Object?>? publicFixture,
  }) async {
    final sequence = ++_requestSequence;
    final requestId =
        'evaluator-${DateTime.now().microsecondsSinceEpoch}-$sequence';
    VmServiceJsonRpcPeer? peer;
    try {
      peer = await _connector(_webSocketUri).timeout(timeout);
      final vmResult = await peer
          .call('getVM', const <String, Object?>{})
          .timeout(timeout);
      final isolateId = _mainIsolateId(vmResult);
      final result = await peer
          .call(method, <String, Object?>{
            'isolateId': isolateId,
            'capability': _capability,
            'requestId': requestId,
            if (publicFixture != null) 'fixture': jsonEncode(publicFixture),
          })
          .timeout(timeout);
      final decoded = _decodeExtensionResult(result);
      final observation = SupplierOracleObservation.fromJson(decoded);
      if (observation.operation != operation ||
          observation.requestId != requestId) {
        throw const SupplierOracleTransportException(
          'oracle_response_mismatch',
          'The evaluator oracle response did not match its request.',
        );
      }
      return observation;
    } on SupplierOracleTransportException {
      rethrow;
    } on TimeoutException catch (_) {
      throw const SupplierOracleTransportException(
        'oracle_timeout',
        'The evaluator oracle did not respond before its deadline.',
      );
    } on Object catch (error) {
      throw SupplierOracleTransportException(
        'oracle_transport_failed',
        'The evaluator oracle transport failed (${error.runtimeType}).',
      );
    } finally {
      await peer?.close();
    }
  }

  String _mainIsolateId(Map<String, Object?> vmResult) {
    final rawIsolates = vmResult['isolates'];
    if (rawIsolates is! List) {
      throw const SupplierOracleTransportException(
        'oracle_isolate_missing',
        'The VM service did not report a runnable isolate.',
      );
    }
    final isolates = <Map<String, Object?>>[
      for (final value in rawIsolates)
        if (value is Map) Map<String, Object?>.from(value),
    ];
    final main = isolates.where((isolate) => isolate['name'] == 'main');
    final candidate = main.isNotEmpty
        ? main.first
        : isolates
              .where((isolate) => isolate['isSystemIsolate'] != true)
              .firstOrNull;
    final id = candidate?['id'];
    if (id is! String || id.isEmpty) {
      throw const SupplierOracleTransportException(
        'oracle_isolate_missing',
        'The VM service did not report a runnable main isolate.',
      );
    }
    return id;
  }

  Map<String, Object?> _decodeExtensionResult(Map<String, Object?> result) {
    final nested = result['result'];
    if (nested is String) {
      final decoded = jsonDecode(nested);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    }
    if (nested is Map) return Map<String, Object?>.from(nested);
    return result;
  }
}

Future<VmServiceJsonRpcPeer> _connectWebSocketPeer(Uri uri) async =>
    _WebSocketJsonRpcPeer(await WebSocket.connect(uri.toString()));

class _WebSocketJsonRpcPeer implements VmServiceJsonRpcPeer {
  _WebSocketJsonRpcPeer(this._socket)
    : _messages = StreamIterator<dynamic>(_socket);

  final WebSocket _socket;
  final StreamIterator<dynamic> _messages;
  var _sequence = 0;

  @override
  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> parameters,
  ) async {
    final id = 'evaluator-rpc-${++_sequence}';
    _socket.add(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        if (parameters.isNotEmpty) 'params': parameters,
      }),
    );
    while (await _messages.moveNext()) {
      final decoded = _decodeMessage(_messages.current);
      if (decoded['id']?.toString() != id) continue;
      if (decoded['error'] != null) {
        throw const SupplierOracleTransportException(
          'oracle_rpc_rejected',
          'The VM service rejected the evaluator oracle request.',
        );
      }
      final result = decoded['result'];
      if (result is! Map) {
        throw const SupplierOracleTransportException(
          'oracle_rpc_invalid',
          'The VM service returned a malformed evaluator result.',
        );
      }
      return Map<String, Object?>.from(result);
    }
    throw const SupplierOracleTransportException(
      'oracle_connection_closed',
      'The VM service closed before returning evaluator evidence.',
    );
  }

  @override
  Future<void> close() async {
    await _messages.cancel();
    await _socket.close();
  }

  Map<String, Object?> _decodeMessage(Object? message) {
    final text = switch (message) {
      final String value => value,
      final List<int> value => utf8.decode(value),
      _ => throw const SupplierOracleTransportException(
        'oracle_rpc_invalid',
        'The VM service returned an unsupported frame.',
      ),
    };
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const SupplierOracleTransportException(
        'oracle_rpc_invalid',
        'The VM service returned a non-object message.',
      );
    }
    return Map<String, Object?>.from(decoded);
  }
}

Uri _normalizeLoopbackVmServiceUri(String value) {
  final candidate = value.trim();
  if (candidate != value ||
      candidate.isEmpty ||
      utf8.encode(candidate).length > 16 * 1024 ||
      candidate.codeUnits.any((unit) => unit <= 0x20 || unit == 0x7f) ||
      candidate.contains(r'\')) {
    throw const FormatException('The VM service URI text is invalid.');
  }
  final parsed = Uri.tryParse(candidate);
  if (parsed == null ||
      !parsed.hasScheme ||
      !parsed.hasAuthority ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      parsed.hasFragment ||
      !parsed.hasPort) {
    throw FormatException('The VM service URI is invalid.');
  }
  final port = parsed.port;
  if (port <= 0 || port > 65535) {
    throw const FormatException('The VM service URI port is invalid.');
  }
  final host = parsed.host.toLowerCase();
  if (!_isStrictLoopbackHost(host)) {
    throw const FormatException(
      'The evaluator oracle only connects to loopback VM services.',
    );
  }
  final scheme = switch (parsed.scheme) {
    'http' => 'ws',
    'https' => 'wss',
    'ws' || 'wss' => parsed.scheme,
    _ => throw const FormatException('Unsupported VM service URI scheme.'),
  };
  var path = parsed.path;
  if (!path.endsWith('/ws')) {
    if (!path.endsWith('/')) path = '$path/';
    path = '${path}ws';
  }
  return parsed.replace(scheme: scheme, path: path);
}

bool _isStrictLoopbackHost(String host) {
  if (host == 'localhost' || host == '::1') return true;
  final parts = host.split('.');
  if (parts.length != 4 || parts.first != '127') return false;
  for (final part in parts) {
    if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part)) return false;
    final octet = int.tryParse(part);
    if (octet == null || octet > 255) return false;
  }
  return true;
}
