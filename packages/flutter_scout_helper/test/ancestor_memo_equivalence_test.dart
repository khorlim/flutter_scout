import 'dart:math' as math;
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// A snapshot caches ancestor facts (secret field, hidden, depth, overlay
/// entry, transform, clip) per element. It must report exactly what the
/// walk-per-node snapshot reports on a deep, transformed, clipped screen with
/// hidden subtrees, secret fields and a dialog over it.
void main() {
  testWidgets('memoized snapshot equals the walk-per-node snapshot', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(1600, 1200);
    addTearDown(tester.view.reset);
    addTearDown(() => FlutterScoutRuntime.debugDisableAncestorMemo = false);

    await tester.pumpWidget(const MaterialApp(home: _DeepScreen()));
    await tester.pump();
    final context = tester.element(find.text('Open dialog'));
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Phone'),
        content: Transform.translate(
          offset: const Offset(7, 3),
          child: Wrap(
            children: [
              for (final key in ['1', '2', '3', 'CLR'])
                TextButton(onPressed: () {}, child: Text(key)),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final runtime = FlutterScoutRuntime();
    FlutterScoutRuntime.debugDisableAncestorMemo = false;
    final memoized = _stable(runtime.debugSnapshot().toJson());
    FlutterScoutRuntime.debugDisableAncestorMemo = true;
    final walked = _stable(runtime.debugSnapshot().toJson());

    expect(memoized, walked);
    expect(memoized, contains('btn.clr'));
    expect(memoized, isNot(contains('hunter2')));
    expect(memoized, isNot(contains('Hidden offstage')));

    // The memo's core: any element, asked in any order, gets the answer a
    // plain walk to the root gives.
    final elements = <Element>[];
    void collect(Element element) {
      elements.add(element);
      element.visitChildElements(collect);
    }

    collect(tester.binding.rootElement!);
    elements.shuffle(math.Random(7));
    bool marked(Element element) {
      final widget = element.widget;
      return widget is Padding && identityHashCode(element) % 3 == 0 ||
          widget is ClipRect ||
          widget is Offstage ||
          widget is Material;
    }

    final facts = FlutterScoutRuntime.debugAncestorMemoFacts(elements, marked);
    for (var i = 0; i < elements.length; i++) {
      final element = elements[i];
      var strict = false;
      var depth = 0;
      element.visitAncestorElements((ancestor) {
        depth++;
        strict = strict || marked(ancestor);
        return true;
      });
      expect(facts[i], [marked(element) || strict, strict, depth]);
    }
  });
}

/// The snapshot JSON without values that change between two snapshots of
/// the same screen (clocks, ids, timings).
String _stable(Map<String, Object?> json) {
  const volatile = {
    'timings',
    'observedAt',
    'lastFrameworkFrameAgeMs',
    'completedFrameworkFrames',
    'snapshotId',
    'stateGeneration',
    'capturedAt',
    'createdAt',
    'ageMs',
  };
  Object? strip(Object? value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          if (!volatile.contains(entry.key)) entry.key: strip(entry.value),
      };
    }
    if (value is List) return value.map(strip).toList();
    return value;
  }

  return const JsonEncoder.withIndent(' ').convert(strip(json));
}

class _DeepScreen extends StatefulWidget {
  const _DeepScreen();

  @override
  State<_DeepScreen> createState() => _DeepScreenState();
}

class _DeepScreenState extends State<_DeepScreen> {
  final _password = TextEditingController(text: 'hunter2');
  final _pin = TextEditingController(text: '4321');
  final _name = TextEditingController(text: 'AI Smoke');
  final _scroll = ScrollController(initialScrollOffset: 120);

  @override
  void dispose() {
    _password.dispose();
    _pin.dispose();
    _name.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _nest(int levels, Widget child) => levels == 0
      ? child
      : Padding(
          padding: const EdgeInsets.all(0.5),
          child: _nest(levels - 1, child),
        );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Members')),
      body: Row(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemCount: 30,
              itemBuilder: (_, index) => ListTile(
                title: Text('Member $index'),
                trailing: IconButton(
                  icon: const Icon(Icons.person),
                  onPressed: () {},
                ),
                onTap: () {},
              ),
            ),
          ),
          Expanded(
            child: _nest(
              40,
              Column(
                children: [
                  Transform.scale(
                    scale: 0.8,
                    child: Transform.translate(
                      offset: const Offset(12, 4),
                      child: ElevatedButton(
                        onPressed: () {},
                        child: const Text('Open dialog'),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 30,
                    width: 80,
                    child: ClipRect(
                      child: OverflowBox(
                        maxWidth: 300,
                        child: TextButton(
                          onPressed: () {},
                          child: const Text('Half clipped'),
                        ),
                      ),
                    ),
                  ),
                  Offstage(
                    child: TextButton(
                      onPressed: () {},
                      child: const Text('Hidden offstage'),
                    ),
                  ),
                  Visibility(
                    visible: false,
                    child: TextButton(
                      onPressed: () {},
                      child: const Text('Hidden visibility'),
                    ),
                  ),
                  IgnorePointer(
                    child: TextButton(
                      onPressed: () {},
                      child: const Text('Ignored'),
                    ),
                  ),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'),
                  ),
                  TextField(
                    controller: _pin,
                    decoration: const InputDecoration(labelText: 'PIN'),
                  ),
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
