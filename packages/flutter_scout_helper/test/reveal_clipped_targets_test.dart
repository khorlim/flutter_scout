import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'reveal clips nested content behind a fixed footer and restores bounded failures',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      final outer = ScrollController();
      final inner = ScrollController();
      addTearDown(outer.dispose);
      addTearDown(inner.dispose);
      var activations = 0;
      await tester.pumpWidget(_fixture(outer, inner, () => activations++));
      await tester.pump();

      final before = runtime.debugSnapshot();
      final target = before.interactables.singleWhere(
        (node) => node.key == 'clipped-form',
      );
      expect(target.rect!.top, 350);
      expect(target.rect!.bottom, lessThan(600));
      expect(target.visibleRect, isNull);
      expect(target.visibleFraction, 0);
      expect(target.suggestedTapPoint, isNull);
      expect(target.hitTestable, isFalse);
      expect(before.visibleText, isNot(contains('Form')));
      expect(before.offscreenText, contains('Form'));
      expect(
        runtime.debugResolveTarget('btn.clipped_form')['status'],
        'hidden',
      );

      final bounded = await _reveal(
        tester,
        runtime,
        distance: 20,
        maxActions: 1,
      );
      expect(bounded['ok'], isFalse);
      expect(bounded['stoppingReason'], 'distance_bound_exhausted');
      expect(bounded['actionsUsed'], 1);
      expect(bounded['distanceUsed'], 20);
      expect((bounded['restoration']! as Map)['result'], 'restored');
      expect(inner.offset, 0);
      expect(outer.offset, 0);
      expect(activations, 0);

      // Only the top ten pixels of this button are now inside the inner viewport.
      inner.jumpTo(60);
      await tester.pump();
      final partial = runtime.debugSnapshot().interactables.singleWhere(
        (node) => node.key == 'clipped-form',
      );
      expect(partial.visibleRect!.bottom, 300);
      expect(partial.visibleFraction, greaterThan(0));
      expect(partial.visibleFraction, lessThan(1));
      expect(partial.suggestedTapPoint!.dy, lessThan(300));
      inner.jumpTo(0);
      await tester.pump();

      final revealed = await _reveal(
        tester,
        runtime,
        distance: 150,
        maxActions: 4,
      );
      expect(revealed['ok'], isTrue, reason: '$revealed');
      expect(revealed['stoppingReason'], 'target_revealed');
      expect(revealed['actionsUsed'], 1);
      expect(inner.offset, 150);
      expect(outer.offset, 0);
      expect(activations, 0, reason: 'reveal must not activate the target');
      final after = runtime.debugSnapshot();
      expect(after.visibleText, contains('Form'));
      expect(after.offscreenText, isNot(contains('Form')));
      final visible = after.interactables.singleWhere(
        (node) => node.key == 'clipped-form',
      );
      expect(visible.visibleFraction, 1);
      expect(visible.hitTestable, isTrue);
      expect(
        runtime.debugResolveTarget('btn.clipped_form')['status'],
        'unique',
      );
    },
  );

  testWidgets('reveal does not scroll clipped content through a modal', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    final outer = ScrollController();
    final inner = ScrollController();
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);
    var activations = 0;
    await tester.pumpWidget(_fixture(outer, inner, () => activations++));
    await tester.pump();
    unawaited(
      showDialog<void>(
        context: tester.element(find.byKey(const ValueKey('clipped-form'))),
        builder: (context) =>
            const AlertDialog(title: Text('Blocking confirmation')),
      ),
    );
    await tester.pumpAndSettle();

    final blocked = await _reveal(
      tester,
      runtime,
      distance: 150,
      maxActions: 4,
    );
    expect(blocked['ok'], isFalse);
    expect(blocked['stoppingReason'], 'unsafe_initial_resolution');
    expect((blocked['resolution']! as Map)['status'], 'wrongSurface');
    expect(blocked['scrollRegionsAttempted'], isEmpty);
    expect(inner.offset, 0);
    expect(outer.offset, 0);
    expect(activations, 0);
  });
}

Widget _fixture(
  ScrollController outer,
  ScrollController inner,
  VoidCallback onPressed,
) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 400,
        height: 400,
        child: SingleChildScrollView(
          key: const ValueKey('outer-scroll'),
          controller: outer,
          child: Column(
            children: [
              SizedBox(
                height: 300,
                child: SingleChildScrollView(
                  key: const ValueKey('inner-scroll'),
                  controller: inner,
                  child: Column(
                    children: [
                      const SizedBox(height: 350),
                      SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          key: const ValueKey('clipped-form'),
                          onPressed: onPressed,
                          child: const Text('Form'),
                        ),
                      ),
                      const SizedBox(height: 250),
                    ],
                  ),
                ),
              ),
              Container(
                height: 100,
                color: Colors.blue,
                child: const Center(child: Text('Fixed footer')),
              ),
              const SizedBox(height: 300),
            ],
          ),
        ),
      ),
    ),
  ),
);

Future<Map<String, Object?>> _reveal(
  WidgetTester tester,
  FlutterScoutRuntime runtime, {
  required int distance,
  required int maxActions,
}) async {
  Map<String, Object?>? result;
  Object? failure;
  var completed = false;
  unawaited(
    runtime
        .debugReveal({
          'text': 'Form',
          'within': 'scroll.inner_scroll',
          'direction': 'down',
          'distance': '$distance',
          'maxActions': '$maxActions',
          'timeoutMs': '4000',
        })
        .then(
          (value) {
            result = value;
            completed = true;
          },
          onError: (Object error) {
            failure = error;
            completed = true;
          },
        ),
  );
  for (var frame = 0; frame < 240 && !completed; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (failure != null) throw failure!;
  expect(completed, isTrue, reason: 'reveal exceeded the test frame bound');
  return result!;
}
