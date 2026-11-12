import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pressable built on raw pointer events (as ripple packages are), which no
/// framework widget check recognizes. Only its Semantics says it is a button.
class _RawPressable extends StatelessWidget {
  const _RawPressable({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerUp: (_) => onPressed(),
      child: SizedBox(
        width: 320,
        height: 64,
        child: Align(alignment: Alignment.centerLeft, child: Text(label)),
      ),
    ),
  );
}

void main() {
  testWidgets('an app-declared semantic button is a tap target', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    var pressed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              _RawPressable(label: 'LimHan', onPressed: () => pressed++),
              ElevatedButton(onPressed: () {}, child: const Text('Send')),
            ],
          ),
        ),
      ),
    );
    final runtime = FlutterScoutHelper.debugRuntime;
    final interactables = runtime.debugSnapshot().interactables;
    final row = interactables.where((node) => node.label == 'LimHan');
    expect(row, hasLength(1));
    expect(row.single.kind, 'btn');
    expect(row.single.enabled, isTrue);
    // A framework button declares the same Semantics inside itself; it must
    // still be reported once.
    expect(interactables.where((node) => node.label == 'Send'), hasLength(1));

    final result = await tester.runAsync(
      () => runtime.debugTapTarget(row.single.id),
    );
    await tester.pump();
    expect(result?['ok'], isTrue, reason: '$result');
    expect(pressed, 1);
  });

  testWidgets('SelectableText is text to read and locate, not a field', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: SelectableText('Ya'))),
      ),
    );
    final runtime = FlutterScoutHelper.debugRuntime;
    final snapshot = runtime.debugSnapshot();
    expect(snapshot.visibleText, contains('Ya'));
    expect(snapshot.fields, isEmpty);
    expect(snapshot.textTargets.map((node) => node.label), contains('Ya'));
    final located = await tester.runAsync(
      () => runtime.debugLocate({'text': 'Ya'}),
    );
    expect(located?['ok'], isTrue, reason: '$located');
  });

  testWidgets(
    'a tap that changes nothing replies before the request deadline',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('quiet'))),
        ),
      );
      await tester.pump();
      final generation = runtime.debugSnapshot().stateGeneration;
      const budgetMs = 1500;
      final started = DateTime.now().millisecondsSinceEpoch;
      final response = await tester.runAsync(
        () => runtime.debugProtocolMutation(
          {
            'schemaVersion': '1',
            'clientProtocolMin': '15',
            'clientProtocolMax': '15',
            'commandId': 'quiet-tap',
            'idempotencyKey': 'quiet-tap',
            'runId': 'run-a',
            'runtimeInstanceId': runtime.debugRuntimeInstanceId,
            'expectedStateGeneration': '$generation',
            'deadlineEpochMs': '${started + budgetMs}',
            // Long waits on purpose: before the fix the late-change wait alone
            // ran past the deadline, which a caller sees as an unknown outcome.
          },
          () => runtime.debugTapPoint(
            const Offset(10, 300),
            waitMs: 5000,
            lateWaitMs: 5000,
          ),
        ),
      );
      final elapsed = DateTime.now().millisecondsSinceEpoch - started;
      expect(response?['ok'], isTrue, reason: '$response');
      expect(elapsed, lessThan(budgetMs), reason: 'elapsed $elapsed ms');
    },
  );

  testWidgets('dismiss closes a text toolbar, not the screen under it', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Chats')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(
          body: Center(child: SelectableText('Ya, see you tomorrow')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(SelectableText));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);

    final runtime = FlutterScoutHelper.debugRuntime;
    final result = await tester.runAsync(runtime.debugDismiss);
    await tester.pumpAndSettle();
    expect(result?['ok'], isTrue, reason: '$result');
    expect(result?['strategy'], 'closed_context_menu');
    expect(find.text('Copy'), findsNothing);
    expect(find.byType(SelectableText), findsOneWidget);
  });
}
