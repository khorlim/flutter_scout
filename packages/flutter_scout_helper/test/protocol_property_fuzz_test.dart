import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

import 'seeded_property_support.dart';

void main() {
  const file = 'protocol_property_fuzz_test.dart';
  const maximumResponseBytes = 4 * 1024 * 1024;
  const maximumPayloadDepth = 64;
  const maximumPayloadNodes = 131072;
  const maximumParameterCount = 64;
  const maximumParameterNameBytes = 128;
  const maximumRequestBytes = 1024 * 1024;
  const maximumValueBytes = 64 * 1024;
  const maximumBulkValueBytes = 512 * 1024;
  const requestCampaign =
      'seeded request bounds are exact at count and UTF-8 thresholds';
  const responseCampaign =
      'seeded response depth size node and non-finite bounds fail closed';
  const cycleCampaign =
      'seeded cyclic payload shapes terminate and fail closed';

  testWidgets(requestCampaign, (tester) async {
    final seed = fuzzSeed(0x8e90e57);
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Request bounds fixture'))),
    );
    await tester.pump();

    final contract = runtime.debugProtocolParameterContract();
    final requestLimits = contract['requestLimits']! as Map;
    expect(requestLimits['maximumParameterCount'], maximumParameterCount);
    expect(
      requestLimits['maximumParameterNameUtf8Bytes'],
      maximumParameterNameBytes,
    );
    expect(
      requestLimits['maximumTotalParameterUtf8Bytes'],
      maximumRequestBytes,
    );
    expect(requestLimits['defaultMaximumValueUtf8Bytes'], maximumValueBytes);
    expect(requestLimits['bulkMaximumValueUtf8Bytes'], maximumBulkValueBytes);

    for (final caseIndex in fuzzCases(36)) {
      final random = fuzzRandom(seed, caseIndex);
      final context = fuzzReplay(
        file: file,
        seed: seed,
        caseIndex: caseIndex,
        testName: requestCampaign,
      );
      switch (caseIndex % 6) {
        case 0:
          final offset = const <int>[-1, 0, 1][(caseIndex ~/ 6) % 3];
          final count = maximumParameterCount + offset;
          final params = <String, String>{
            for (var index = 0; index < count; index += 1) 'unknown$index': 'v',
          };
          final response = await runtime.debugProtocolRead(
            params,
            method: 'ext.flutter_scout.inspect',
          );
          expect(
            _errorCode(response),
            count > maximumParameterCount
                ? 'request_parameter_count_exceeded'
                : 'unknown_parameter',
            reason: context,
          );
          break;
        case 1:
          final offset = const <int>[-1, 0, 1][(caseIndex ~/ 6) % 3];
          final byteLength = maximumParameterNameBytes + offset;
          final useTwoByte =
              byteLength.isEven && (random.nextBool() || caseIndex == 7);
          final name = useTwoByte
              ? '\u00e9' * (byteLength ~/ 2)
              : 'n' * byteLength;
          expect(utf8.encode(name).length, byteLength, reason: context);
          final response = await runtime.debugProtocolRead(<String, String>{
            name: 'v',
          }, method: 'ext.flutter_scout.inspect');
          expect(
            _errorCode(response),
            byteLength > maximumParameterNameBytes
                ? 'request_parameter_name_too_large'
                : 'unknown_parameter',
            reason: context,
          );
          break;
        case 2:
          final offset = const <int>[-1, 0, 1][(caseIndex ~/ 6) % 3];
          final byteLength = maximumValueBytes + offset;
          final response = await runtime.debugProtocolRead(<String, String>{
            'brief': 'b' * byteLength,
          }, method: 'ext.flutter_scout.inspect');
          if (byteLength <= maximumValueBytes) {
            // The generic byte gate admits the value; the narrower typed
            // method contract then rejects a non-boolean `brief`.
            expect(
              _errorCode(response),
              'invalid_parameter_value',
              reason: context,
            );
          } else {
            expect(
              _errorCode(response),
              'request_parameter_too_large',
              reason: context,
            );
          }
          break;
        case 3:
          final offset = const <int>[-1, 0, 1][(caseIndex ~/ 6) % 3];
          final byteLength = maximumBulkValueBytes + offset;
          final response = await runtime.debugProtocolRead(<String, String>{
            'action': 'list',
            'records': 'r' * byteLength,
          }, method: 'ext.flutter_scout.annotations');
          if (byteLength <= maximumBulkValueBytes) {
            // `records` fits the generic bulk allowance but is illegal for a
            // read-only list action, so semantic validation must run next.
            expect(
              _errorCode(response),
              'invalid_parameter_value',
              reason: context,
            );
          } else {
            expect(
              _errorCode(response),
              'request_parameter_too_large',
              reason: context,
            );
          }
          break;
        case 4:
          final offset = const <int>[-1, 0, 1][(caseIndex ~/ 6) % 3];
          final byteLength = 256 + offset;
          final response = await runtime.debugProtocolRead(<String, String>{
            'commandId': 'c' * byteLength,
          }, method: 'ext.flutter_scout.inspect');
          if (byteLength <= 256) {
            expect(response['ok'], isTrue, reason: context);
          } else {
            expect(
              _errorCode(response),
              'request_parameter_too_large',
              reason: context,
            );
          }
          break;
        case 5:
          final offset = const <int>[-1, 0, 1][(caseIndex ~/ 6) % 3];
          final targetBytes = maximumRequestBytes + offset;
          final params = _inputParamsWithEncodedBytes(targetBytes);
          expect(_requestBytes(params), targetBytes, reason: context);
          final response = await runtime.debugProtocolRead(
            params,
            method: 'ext.flutter_scout.input',
          );
          if (targetBytes <= maximumRequestBytes) {
            // The synthetic values deliberately are not a valid input call;
            // at and below the aggregate byte bound they must reach the
            // narrower typed contract rather than fail the generic size gate.
            expect(
              _errorCode(response),
              'invalid_parameter_value',
              reason: context,
            );
          } else {
            expect(
              _errorCode(response),
              'request_payload_too_large',
              reason: context,
            );
          }
          break;
      }
    }
  });

  testWidgets(responseCampaign, (tester) async {
    final seed = fuzzSeed(0xb01d5afe);
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Response bounds fixture'))),
    );
    await tester.pump();

    for (final caseIndex in fuzzCases(24)) {
      final context = fuzzReplay(
        file: file,
        seed: seed,
        caseIndex: caseIndex,
        testName: responseCampaign,
      );
      late final Object? result;
      late final bool shouldSucceed;
      late final Set<String> expectedFailureReasons;
      switch (caseIndex % 4) {
        case 0:
          final offset = const <int>[-1, 0, 1][(caseIndex ~/ 4) % 3];
          final chainDepth = maximumPayloadDepth - 1 + offset;
          Object? nested = 'leaf';
          for (var level = 0; level < chainDepth; level += 1) {
            nested = <String, Object?>{'next': nested};
          }
          result = <String, Object?>{'result': nested};
          shouldSucceed = chainDepth <= maximumPayloadDepth - 1;
          expectedFailureReasons = const <String>{
            'payload_depth_limit_exceeded',
          };
          break;
        case 1:
          final offset = const <int>[-65536, -4096, 0, 1][(caseIndex ~/ 4) % 4];
          final length = maximumResponseBytes + offset;
          result = <String, Object?>{'result': 'x' * length};
          shouldSucceed = length <= maximumResponseBytes - 4096;
          expectedFailureReasons = const <String>{
            'encoded_payload_bytes_exceeded',
            'payload_scalar_bytes_exceeded',
            'payload_bytes_exceeded',
            'final_encoded_payload_bound_failed',
          };
          break;
        case 2:
          final offset = (caseIndex ~/ 4).isEven ? -1024 : 1;
          final count = maximumPayloadNodes + offset;
          result = <String, Object?>{
            'result': List<Object?>.filled(count, null),
          };
          shouldSucceed = count <= maximumPayloadNodes - 1024;
          expectedFailureReasons = const <String>{
            'payload_node_limit_exceeded',
          };
          break;
        case 3:
          result = <String, Object?>{
            'result': (caseIndex ~/ 4).isEven ? double.nan : double.infinity,
          };
          shouldSucceed = false;
          expectedFailureReasons = const <String>{'non_finite_number'};
          break;
      }

      final response = await runtime.debugProtocolMutation(
        _mutationEnvelope(runtime, commandId: 'response-bound-$caseIndex'),
        () async => result! as Map<String, Object?>,
      );
      expect(
        utf8.encode(jsonEncode(response)).length,
        lessThanOrEqualTo(maximumResponseBytes),
        reason: context,
      );
      if (shouldSucceed) {
        expect(response['ok'], isTrue, reason: context);
      } else {
        expect(response['ok'], isFalse, reason: context);
        expect(response['result'], isNull, reason: context);
        expect(
          expectedFailureReasons,
          contains(_failureReason(response)),
          reason: context,
        );
      }
    }
  });

  testWidgets(cycleCampaign, (tester) async {
    final seed = fuzzSeed(0xc1c1e5);
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Cycle fixture'))),
    );
    await tester.pump();

    for (final caseIndex in fuzzCases(6)) {
      final random = fuzzRandom(seed, caseIndex);
      final ringLength = 1 + random.nextInt(7);
      final ring = <Map<String, Object?>>[
        for (var index = 0; index < ringLength; index += 1)
          <String, Object?>{'index': index},
      ];
      for (var index = 0; index < ring.length; index += 1) {
        ring[index]['next'] = ring[(index + 1) % ring.length];
      }
      if (random.nextBool()) {
        ring[random.nextInt(ring.length)]['branch'] = <Object?>[ring.first];
      }
      final context = fuzzReplay(
        file: file,
        seed: seed,
        caseIndex: caseIndex,
        testName: cycleCampaign,
      );
      final response = await runtime.debugProtocolMutation(
        _mutationEnvelope(runtime, commandId: 'cycle-$caseIndex'),
        () async => ring.first,
      );
      expect(response['ok'], isFalse, reason: context);
      expect(
        _errorCode(response),
        'truncated_safety_evidence',
        reason: context,
      );
      expect(
        const <String>{
          'payload_depth_limit_exceeded',
          'payload_node_limit_exceeded',
        },
        contains(_failureReason(response)),
        reason: context,
      );
      expect(response['result'], isNull, reason: context);
      expect(
        utf8.encode(jsonEncode(response)).length,
        lessThanOrEqualTo(maximumResponseBytes),
        reason: context,
      );
    }
  });
}

Map<String, String> _mutationEnvelope(
  FlutterScoutRuntime runtime, {
  required String commandId,
}) => <String, String>{
  'schemaVersion': '1',
  'clientProtocolMin': '15',
  'clientProtocolMax': '15',
  'commandId': commandId,
  'idempotencyKey': commandId,
  'runId': 'property-run',
  'runtimeInstanceId': runtime.debugRuntimeInstanceId,
  'expectedStateGeneration': '${runtime.debugSnapshot().stateGeneration}',
  'deadlineEpochMs':
      '${DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch}',
};

Map<String, String> _inputParamsWithEncodedBytes(int targetBytes) {
  const limits = <String, int>{
    'value': 512 * 1024,
    'target': 64 * 1024,
    'waitMs': 64 * 1024,
    'expectText': 64 * 1024,
    'expectGone': 64 * 1024,
    'expectTarget': 64 * 1024,
    'expectSelected': 64 * 1024,
    'expectScreen': 64 * 1024,
    'expectView': 64 * 1024,
    'expectField': 64 * 1024,
    'expectTimeoutMs': 64 * 1024,
    'pollMs': 64 * 1024,
    'capture': 64 * 1024,
  };
  var remaining = targetBytes;
  final result = <String, String>{};
  for (final entry in limits.entries) {
    if (remaining <= 0) break;
    final keyBytes = utf8.encode(entry.key).length;
    if (remaining <= keyBytes) continue;
    final valueBytes = min(entry.value, remaining - keyBytes);
    result[entry.key] = 'v' * valueBytes;
    remaining -= keyBytes + valueBytes;
  }
  if (remaining != 0) {
    throw StateError('Could not construct exact request size $targetBytes');
  }
  return result;
}

int _requestBytes(Map<String, String> params) => params.entries.fold<int>(
  0,
  (total, entry) =>
      total + utf8.encode(entry.key).length + utf8.encode(entry.value).length,
);

String _errorCode(Map<String, Object?> response) =>
    (response['structuredError']! as Map)['code']! as String;

String? _failureReason(Map<String, Object?> response) {
  final error = response['structuredError'];
  if (error is! Map) return null;
  final details = error['details'];
  return details is Map ? details['reason']?.toString() : null;
}
