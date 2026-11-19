import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// A point-of-sale screen whose clock ticks in the background, with a Pay
/// button that can be relabelled, and a keypad dialog titled by its display.
class _Till extends StatefulWidget {
  const _Till({super.key});

  @override
  State<_Till> createState() => _TillState();
}

class _TillState extends State<_Till> {
  int clock = 0;
  String pay = 'Pay';

  void tick() => setState(() => clock++);

  void relabel(String value) => setState(() => pay = value);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text('10:4$clock'),
        ElevatedButton(onPressed: () {}, child: Text(pay)),
      ],
    ),
  );
}

void main() {
  final tillKey = GlobalKey<_TillState>();
  var requests = 0;

  Map<String, String> envelope(
    FlutterScoutRuntime runtime,
    int generation, {
    String? freshTargets,
  }) => {
    'schemaVersion': '1',
    'clientProtocolMin': '15',
    'clientProtocolMax': '15',
    'commandId': 'fresh-${++requests}',
    'idempotencyKey': 'fresh-$requests',
    'runId': 'run',
    'runtimeInstanceId': runtime.debugRuntimeInstanceId,
    'expectedStateGeneration': '$generation',
    'deadlineEpochMs':
        '${DateTime.now().add(const Duration(seconds: 5)).millisecondsSinceEpoch}',
    'freshTargets': ?freshTargets,
  };

  testWidgets('an unchanged exact target survives background churn after '
      'preflight; a changed one does not', (tester) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(MaterialApp(home: _Till(key: tillKey)));
    final checked = runtime.debugSnapshot().stateGeneration;

    // The clock ticks between the client's preflight and dispatch.
    tillKey.currentState!.tick();
    await tester.pump();
    expect(runtime.debugSnapshot().stateGeneration, greaterThan(checked));

    Future<Map<String, Object?>> mutate(String? freshTargets) async =>
        (await tester.runAsync(
          () => runtime.debugProtocolMutation(
            envelope(runtime, checked, freshTargets: freshTargets),
            () => {'dispatched': true},
          ),
        ))!;

    final exact = await mutate(null);
    expect((exact['structuredError'] as Map)['code'], 'stale_state_generation');

    final scoped = await mutate('["btn.pay"]');
    expect(scoped['ok'], isTrue, reason: '$scoped');
    expect((scoped['targetFreshness'] as Map)['status'], 'targets_unchanged');

    // The target itself changes: refused, with the reason.
    tillKey.currentState!.relabel('Paid');
    await tester.pump();
    final changed = await mutate('["btn.pay"]');
    expect(
      (changed['structuredError'] as Map)['code'],
      'stale_state_generation',
    );
    expect(
      ((changed['structuredError'] as Map)['details'] as Map)['staleReason'],
      contains('btn.pay'),
    );
  });

  testWidgets('a dialog keeps its surface instance while its guessed title '
      'changes; a new dialog gets another', (tester) async {
    final runtime = FlutterScoutRuntime();
    final display = ValueNotifier<String>('+60 1');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => Dialog(
                child: ValueListenableBuilder<String>(
                  valueListenable: display,
                  builder: (_, value, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(value, style: const TextStyle(fontSize: 30)),
                      TextButton(onPressed: () {}, child: const Text('7')),
                    ],
                  ),
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final first = runtime.debugSnapshot().activeSurface!;
    display.value = '+60 15';
    await tester.pump();
    final typed = runtime.debugSnapshot().activeSurface!;
    expect(first['instance'], isA<int>());
    expect(typed['instance'], first['instance']);

    Navigator.of(tester.element(find.text('7'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(
      runtime.debugSnapshot().activeSurface!['instance'],
      isNot(first['instance']),
    );
  });
}
