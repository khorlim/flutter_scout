import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('every runtime response identifies the compiled helper package', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('operability identity'))),
    );
    await tester.pump();

    final response = await FlutterScoutRuntime().debugInspect();
    expect(scoutHelperPackageVersion, '0.2.0-dev.1');
    expect(response['helperPackageVersion'], scoutHelperPackageVersion);
    expect(response['helperProtocolVersion'], scoutHelperProtocolVersion);
    expect(response['minSupportedProtocolVersion'], 15);
    expect(response['maxSupportedProtocolVersion'], 15);
    expect(response['capabilities'], isA<Map>());
  });
}
