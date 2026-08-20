import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

const String _capability = 'abcdef0123456789abcdef0123456789';

void main() {
  test(
    'client queries the authenticated oracle on a separate JSON-RPC peer',
    () async {
      late Uri connectedUri;
      final peer = _FakeJsonRpcPeer();
      final client = VmServiceSupplierOracleClient(
        vmServiceUri: 'http://127.0.0.1:8181/auth/',
        capability: _capability,
        connector: (uri) async {
          connectedUri = uri;
          return peer;
        },
      );

      final observation = await client.reset();

      expect(connectedUri.toString(), 'ws://127.0.0.1:8181/auth/ws');
      expect(observation.operation, 'reset');
      expect(observation.resetPerformed, isTrue);
      expect(observation.state.isCleanReset, isTrue);
      expect(peer.closed, isTrue);
      expect(peer.calls, hasLength(2));
      expect(peer.calls.first.method, 'getVM');
      expect(peer.calls.first.parameters, isEmpty);
      expect(peer.calls.last.method, supplierWorkflowOracleResetMethod);
      expect(peer.calls.last.parameters['capability'], _capability);
      expect(peer.calls.last.parameters['isolateId'], 'isolates/1');
      expect(peer.calls.last.parameters['requestId'], startsWith('evaluator-'));
    },
  );

  test('client refuses non-loopback VM endpoints before sending a token', () {
    var connected = false;
    for (final invalid in const <String>[
      'ws://example.com:8181/token/ws',
      'ws://192.168.1.1:8181/token/ws',
      'ws://localhost/token/ws',
      'ws://user@localhost:8181/token/ws',
      'ws://localhost:8181/token/ws#fragment',
      'ws://localhost.:8181/token/ws',
      'ws://127.00.0.1:8181/token/ws',
      r'ws://127.0.0.1:8181/token\ws',
    ]) {
      expect(
        () => VmServiceSupplierOracleClient(
          vmServiceUri: invalid,
          capability: _capability,
          connector: (uri) async {
            connected = true;
            return _FakeJsonRpcPeer();
          },
        ),
        throwsFormatException,
        reason: invalid,
      );
    }
    expect(connected, isFalse);
  });

  test('client accepts strict IPv4-loopback aliases with explicit ports', () {
    expect(
      () => VmServiceSupplierOracleClient(
        vmServiceUri: 'http://127.255.0.1:8181/token/',
        capability: _capability,
        connector: (uri) async => _FakeJsonRpcPeer(),
      ),
      returnsNormally,
    );
  });
}

class _JsonRpcCall {
  const _JsonRpcCall(this.method, this.parameters);

  final String method;
  final Map<String, Object?> parameters;
}

class _FakeJsonRpcPeer implements VmServiceJsonRpcPeer {
  final List<_JsonRpcCall> calls = <_JsonRpcCall>[];
  bool closed = false;

  @override
  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> parameters,
  ) async {
    calls.add(_JsonRpcCall(method, Map<String, Object?>.from(parameters)));
    if (method == 'getVM') {
      return <String, Object?>{
        'isolates': <Map<String, Object?>>[
          <String, Object?>{'id': 'isolates/1', 'name': 'main'},
        ],
      };
    }
    return <String, Object?>{
      'schemaVersion': 1,
      'channel': supplierWorkflowOracleChannel,
      'operation': 'reset',
      'requestId': parameters['requestId'],
      'runtimeId': 'runtime-test',
      'workflowAttached': true,
      'resetGeneration': 1,
      'resetPerformed': true,
      'state': <String, Object?>{
        'modal': 'closed',
        'supplierAdditionCount': 0,
        'supplierNames': <String>[],
        'forbiddenDuplicateActionCount': 0,
        'forbiddenWrongActionCount': 0,
      },
    };
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
