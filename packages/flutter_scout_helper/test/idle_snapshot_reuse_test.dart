import 'package:flutter/material.dart';
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
}
