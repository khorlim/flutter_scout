import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// Brief interactables (what an agent's scene shows), by label.
Map<String, Map<String, Object?>> _controls() {
  final brief = FlutterScoutHelper.debugRuntime.debugInspectPayload(
    brief: true,
    maxItems: 100,
  );
  return {
    for (final node in (brief['interactables']! as List).cast<Map>())
      if (node['label'] case final String label)
        label: node.cast<String, Object?>(),
  };
}

void main() {
  testWidgets('controls report selected, checked, toggled and expanded from '
      'their widgets and semantics', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: DefaultTabController(
          length: 2,
          initialIndex: 1,
          child: Scaffold(
            appBar: AppBar(
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'Services'),
                  Tab(text: 'Products'),
                ],
              ),
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: 0,
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
                NavigationDestination(icon: Icon(Icons.list), label: 'Orders'),
              ],
            ),
            body: ListView(
              children: [
                SwitchListTile(
                  title: const Text('Roundup'),
                  value: true,
                  onChanged: (_) {},
                ),
                CheckboxListTile(
                  title: const Text('Print receipt'),
                  value: false,
                  onChanged: (_) {},
                ),
                RadioGroup<int>(
                  groupValue: 2,
                  onChanged: (_) {},
                  child: const Column(
                    children: [
                      RadioListTile<int>(title: Text('Cash'), value: 1),
                      RadioListTile<int>(title: Text('Card'), value: 2),
                    ],
                  ),
                ),
                ChoiceChip(
                  label: const Text('Points'),
                  selected: true,
                  onSelected: (_) {},
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'day', label: Text('Day')),
                    ButtonSegment(value: 'week', label: Text('Week')),
                  ],
                  selected: const {'week'},
                  onSelectionChanged: (_) {},
                ),
                const ExpansionTile(
                  title: Text('Advanced'),
                  initiallyExpanded: true,
                  children: [ListTile(title: Text('Body row'), onTap: _noop)],
                ),
                // A custom pressable that states its selection in Semantics.
                Semantics(
                  button: true,
                  selected: true,
                  onTap: () {},
                  child: Listener(
                    onPointerUp: (_) {},
                    child: const Text('Redeem with points'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final controls = _controls();
    expect(controls['Products']?['selected'], isTrue);
    expect(controls['Services']?['selected'], isFalse);
    expect(controls['Home']?['selected'], isTrue);
    expect(controls['Orders']?['selected'], isFalse);
    // The list tile's title names its switch and checkbox.
    expect(controls['Roundup'], containsPair('id', 'btn.roundup'));
    expect(controls['Roundup'], containsPair('toggled', true));
    expect(controls['Roundup']?['selected'], isTrue);
    expect(controls['Print receipt'], containsPair('checked', false));
    expect(controls['Card'], containsPair('checked', true));
    expect(controls['Cash'], containsPair('checked', false));
    expect(controls['Points']?['selected'], isTrue);
    // The selected segment draws a check icon before its text.
    expect(controls['Week'], containsPair('id', 'btn.week'));
    expect(controls['Week']?['selected'], isTrue);
    expect(controls['Day']?['selected'], isFalse);
    expect(controls['Advanced'], containsPair('expanded', true));
    // The body row of the tile is not its header.
    expect(controls['Body row']?.containsKey('expanded'), isFalse);
    expect(controls['Redeem with points']?['selected'], isTrue);
  });

  testWidgets('a tap whose only effect is a control state reports the change '
      'without the late wait', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    final runtime = FlutterScoutHelper.debugRuntime;
    var range = '<180 days';
    // Filter chips whose selection is stated in Semantics only: the text
    // and layout stay the same when one is picked.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Row(
              children: [
                for (final option in ['<180 days', '>180 days'])
                  Semantics(
                    button: true,
                    selected: range == option,
                    child: GestureDetector(
                      onTap: () => setState(() => range = option),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(option),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final chip = tester.getCenter(find.text('>180 days'));

    final stopwatch = Stopwatch()..start();
    final result = await tester.runAsync(() async {
      // The engine's frames, as a running app would have them.
      final frames = Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => unawaited(tester.pump()),
      );
      try {
        return await runtime.debugTapPoint(chip, waitMs: 600, lateWaitMs: 1500);
      } finally {
        frames.cancel();
      }
    });
    stopwatch.stop();

    expect(range, '>180 days');
    expect(result!['result'], 'changed', reason: '$result');
    expect(result['lateChangeObserved'], isNull);
    final changes = ((result['delta']! as Map)['controlStateChanges']! as List)
        .cast<Map>();
    expect(changes, isNotEmpty);
    // The 1.5 s late window was not waited out.
    expect(stopwatch.elapsedMilliseconds, lessThan(1000));
  });
}

void _noop() {}
