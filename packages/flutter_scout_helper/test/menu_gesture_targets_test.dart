import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

// Chat-list shapes from real app use: a row that opens its menu from
// onLongPressStart or a right click, and a menu opened over that list.
Widget chatRow({
  required String preview,
  VoidCallback? onTap,
  GestureLongPressStartCallback? onLongPressStart,
  GestureTapDownCallback? onSecondaryTapDown,
}) => GestureDetector(
  behavior: HitTestBehavior.opaque,
  onLongPressStart: onLongPressStart,
  onSecondaryTapDown: onSecondaryTapDown,
  child: GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: SizedBox(
      height: 72,
      width: 320,
      child: Align(alignment: Alignment.centerLeft, child: Text(preview)),
    ),
  ),
);

void main() {
  testWidgets('a row that opens its menu on long-press start is live', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              chatRow(
                preview: 'how is your eye treatment',
                onTap: () {},
                onLongPressStart: (_) => opened++,
              ),
            ],
          ),
        ),
      ),
    );
    final runtime = FlutterScoutHelper.debugRuntime;
    final rows = runtime.debugSnapshot().interactables.where(
      (node) => node.label == 'how is your eye treatment',
    );
    expect(rows, isNotEmpty);
    expect(rows.every((node) => node.enabled), isTrue);

    final result = await tester.runAsync(
      () => runtime.debugLongPressTarget(
        'tap.how_is_your_eye_treatment',
        durationMs: 700,
      ),
    );
    await tester.pump();
    expect(result?['ok'], isTrue, reason: '$result');
    expect(opened, 1);
  });

  testWidgets('a secondary tap is a mouse right click', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    var primary = 0;
    final secondary = <PointerDeviceKind?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              chatRow(
                preview: 'Raymond',
                onTap: () => primary++,
                onSecondaryTapDown: (details) => secondary.add(details.kind),
              ),
            ],
          ),
        ),
      ),
    );
    final runtime = FlutterScoutHelper.debugRuntime;
    final result = await tester.runAsync(
      () => runtime.debugTapTarget('tap.raymond', button: 'secondary'),
    );
    await tester.pump();
    expect(result?['ok'], isTrue, reason: '$result');
    expect(result?['button'], 'secondary');
    expect(secondary, [PointerDeviceKind.mouse]);
    expect(primary, 0);

    final plain = await tester.runAsync(
      () => runtime.debugTapTarget('tap.raymond'),
    );
    await tester.pump();
    expect(plain?['ok'], isTrue, reason: '$plain');
    expect(primary, 1, reason: '$plain');
    expect(secondary, hasLength(1));
  });

  testWidgets('menu buttons over a list keep their own labels', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: Column(
            children: [
              chatRow(preview: '+44 7710 173736', onTap: () {}),
              chatRow(preview: 'Retention', onTap: () {}),
            ],
          ),
        ),
      ),
    );
    // An open menu over the rows: keyed buttons without text of their own,
    // standing exactly over the rows beneath, on a route of its own.
    navigator.currentState!.push(
      PageRouteBuilder<void>(
        opaque: false,
        pageBuilder: (_, _, _) => Align(
          alignment: Alignment.topLeft,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final name in ['archive', 'pin'])
                SizedBox(
                  height: 72,
                  width: 320,
                  child: ElevatedButton(
                    key: GlobalObjectKey(name),
                    onPressed: () {},
                    child: const SizedBox.shrink(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final buttons = FlutterScoutHelper.debugRuntime
        .debugSnapshot()
        .interactables
        .where((node) => node.widgetType == 'ElevatedButton');
    expect(buttons, hasLength(2));
    for (final button in buttons) {
      expect(button.label, isNot(anyOf('+44 7710 173736', 'Retention')));
    }
  });
}
