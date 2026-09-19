import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('focus change still invalidates snapshot identity', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            focusNode: focus,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = runtime.debugSnapshot();
    focus.requestFocus();
    await tester.pumpAndSettle();
    final focused = runtime.debugSnapshot();
    expect(focus.hasFocus, isTrue);
    expect(focused.stateGeneration, greaterThan(before.stateGeneration));
    expect(focused.stateDigest, isNot(before.stateDigest));
  });
  testWidgets('scheduled frames do not invalidate unchanged controls', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Stable'))),
    );
    await tester.pumpAndSettle();
    final before = runtime.debugSnapshot();
    expect(before.idle, isTrue);
    tester.binding.scheduleFrame();
    final pending = runtime.debugSnapshot();
    expect(pending.idle, isFalse);
    expect(pending.stateGeneration, before.stateGeneration);
    expect(pending.stateDigest, before.stateDigest);
    await tester.pump();
    expect(runtime.debugSnapshot().snapshotId, before.snapshotId);
  });

  testWidgets('value and geometry changes still invalidate snapshot identity', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    Widget form(double width) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: TextField(
            controller: controller,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
        ),
      ),
    );
    await tester.pumpWidget(form(200));
    await tester.pumpAndSettle();
    final before = runtime.debugSnapshot();
    controller.text = 'Changed';
    await tester.pump();
    final changed = runtime.debugSnapshot();
    expect(changed.stateGeneration, greaterThan(before.stateGeneration));
    expect(changed.stateDigest, isNot(before.stateDigest));
    await tester.pumpWidget(form(300));
    await tester.pumpAndSettle();
    final moved = runtime.debugSnapshot();
    expect(moved.stateGeneration, greaterThan(changed.stateGeneration));
    expect(moved.stateDigest, isNot(changed.stateDigest));
  });
}
