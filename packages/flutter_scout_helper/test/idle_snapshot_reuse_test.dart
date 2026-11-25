import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// The eyes snapshot every 250 ms. On an idle screen (no frame since the
/// last snapshot and none scheduled) the trees cannot have changed, so the
/// last snapshot is answered again; anything that could change it forces a
/// fresh walk.
void main() {
  testWidgets('an idle screen reuses its snapshot until something changes', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    final runtime = FlutterScoutHelper.debugRuntime;
    final label = ValueNotifier<String>('Count 0');
    addTearDown(label.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: label,
            builder: (_, value, _) =>
                TextButton(onPressed: () {}, child: Text(value)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final first = runtime.debugSnapshot();
    final again = runtime.debugSnapshot();
    expect(
      identical(again.interactables, first.interactables),
      isTrue,
      reason: 'idle and unchanged: the same snapshot',
    );

    // A change schedules a frame: never answered from the old snapshot.
    label.value = 'Count 1';
    expect(tester.binding.hasScheduledFrame, isTrue);
    final pending = runtime.debugSnapshot();
    expect(identical(pending.interactables, first.interactables), isFalse);

    // After the frame the new text is observed.
    await tester.pump();
    final changed = runtime.debugSnapshot();
    expect(changed.visibleText, contains('Count 1'));
    expect(changed.visibleText, isNot(contains('Count 0')));

    // A new app error is part of the snapshot: a fresh one is built.
    final settled = runtime.debugSnapshot();
    runtime.debugRecordError('injected error');
    final withError = runtime.debugSnapshot();
    expect(identical(withError.interactables, settled.interactables), isFalse);
    expect(
      withError.recentErrors.map((error) => error['message']),
      contains(contains('injected error')),
    );
  });

  testWidgets(
    'frames that only repaint the driving overlay keep the snapshot; app '
    'builds and scrolls still force a fresh one',
    (tester) async {
      FlutterScoutHelper.ensureRegistered();
      final runtime = FlutterScoutHelper.debugRuntime;
      final label = ValueNotifier<String>('Count 0');
      final scroll = ScrollController();
      addTearDown(label.dispose);
      addTearDown(scroll.dispose);
      Future<void> frames(int ms) async {
        for (var elapsed = 0; elapsed < ms; elapsed += 16) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                // No ink, no setState: tapping it changes nothing in the app.
                GestureDetector(onTap: () {}, child: const Text('Ping')),
                ValueListenableBuilder<String>(
                  valueListenable: label,
                  builder: (_, value, _) => Text(value),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: scroll,
                    itemCount: 50,
                    itemBuilder: (_, index) => Text('Row $index'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await runtime.debugAgentOverlay('attach');
      await tester.pump();
      await tester.pump();
      await frames(700);

      // The overlay animates a press: its ticker keeps a frame scheduled.
      // The first input also turns the session label to "controlling"
      // (a short widget animation, which is app-side work); sample after it.
      await tester.runAsync(() => runtime.debugTapTarget('tap.ping'));
      await frames(300);
      expect(tester.binding.hasScheduledFrame, isTrue);
      final first = runtime.debugSnapshot();
      await frames(48);
      expect(tester.binding.hasScheduledFrame, isTrue);
      final again = runtime.debugSnapshot();
      expect(
        identical(again.interactables, first.interactables),
        isTrue,
        reason: 'only the overlay repainted: the same snapshot',
      );

      // An app build is never answered from the old snapshot.
      label.value = 'Count 1';
      expect(
        identical(runtime.debugSnapshot().interactables, first.interactables),
        isFalse,
      );
      await frames(32);
      expect(runtime.debugSnapshot().visibleText, contains('Count 1'));

      // A scroll moves pixels before any frame: a fresh snapshot sees it.
      final settled = runtime.debugSnapshot();
      scroll.jumpTo(120);
      final scrolled = runtime.debugSnapshot();
      expect(identical(scrolled.interactables, settled.interactables), isFalse);
      await frames(32);
      final afterFrame = runtime.debugSnapshot();
      expect(afterFrame.visibleText, isNot(contains('Row 0')));

      // Detaching restores the framework's hooks.
      await runtime.debugAgentOverlay('detach');
      await frames(600);
      expect(debugOnProfilePaint, isNull);
      expect(runtime.debugDrivingOverlayStatus['installed'], isFalse);
    },
  );
}
