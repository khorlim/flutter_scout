import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('sensitive tracking is bounded and fails closed at capacity', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('privacy fixture'))),
    );
    addTearDown(runtime.debugResetSensitiveValueTracking);

    for (var index = 0; index < 256; index++) {
      runtime.debugRememberSensitiveValue(
        'sensitive-value-${index.toString().padLeft(3, '0')}',
      );
    }
    var state = runtime.debugSensitiveValueTracking;
    expect(state['count'], 256);
    expect(state['bytes'], lessThanOrEqualTo(1024 * 1024));
    expect(state['capacityExceeded'], isFalse);
    expect(
      runtime.debugRedactSensitiveText('echo sensitive-value-000'),
      isNot(contains('sensitive-value-000')),
    );

    const overflowSecret = 'sensitive-value-overflow-must-not-echo';
    runtime.debugRememberSensitiveValue(overflowSecret);
    state = runtime.debugSensitiveValueTracking;
    expect(state['count'], 256);
    expect(state['bytes'], lessThanOrEqualTo(1024 * 1024));
    expect(state['capacityExceeded'], isTrue);

    final response = await runtime.debugProtocolRead(<String, String>{
      'commandId': 'privacy-capacity-read',
      'runId': 'privacy-capacity-run',
      'errorCursor': '0',
    });
    expect(response['ok'], isFalse);
    expect(
      ((response['structuredError'] as Map)['details'] as Map)['reason'],
      'sensitive_value_capacity_exceeded',
    );
    expect(jsonEncode(response), isNot(contains(overflowSecret)));
  });
}
