import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_test_app/screens/eye_hand_probe_screen.dart';

void main() {
  testWidgets('transient request is gone before work completes', (
    tester,
  ) async {
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: EyeHandProbeScreen(onEvent: (event, _) => events.add(event)),
      ),
    );
    await tester.tap(find.text('Start flash'));
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('Notice: Pause requested'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.text('Notice: None'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 5600));
    expect(find.text('Phase: Ready'), findsOneWidget);
    expect(events, ['started', 'notice', 'noticeCleared', 'ready']);
  });

  testWidgets('pause during work cancels completion, late pause is counted', (
    tester,
  ) async {
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: EyeHandProbeScreen(onEvent: (event, _) => events.add(event)),
      ),
    );
    await tester.tap(find.text('Start hold'));
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.tap(find.text('Pause work'));
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Phase: Paused'), findsOneWidget);
    expect(events, ['started', 'notice', 'paused']);
    expect(find.text('Late pauses: 0'), findsOneWidget);
    await tester.tap(find.text('Start quiet'));
    await tester.pump(const Duration(seconds: 8));
    await tester.tap(find.text('Pause work'));
    await tester.pump();
    expect(find.text('Late pauses: 1'), findsOneWidget);
  });
}
