import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_test_app/order_screen_main.dart';

void main() {
  testWidgets('the order screen names its controls after their text and '
      'keeps grid handles when the cart repeats a name', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: OrderScreen()));
    final runtime = FlutterScoutHelper.debugRuntime;
    ScoutNode control(String id) =>
        runtime.debugSnapshot().interactables.singleWhere((n) => n.id == id);
    final ids = runtime.debugSnapshot().interactables.map((n) => n.id);
    expect(
      ids,
      containsAll(<String>[
        'btn.thai_yoga',
        'btn.zern_yet',
        'tap.points',
        'tap.credit',
        'tap.lt_180_days',
        'tap.gt_180_days',
        'btn.roundup',
      ]),
    );

    // Credit states its mode in Semantics; Points only paints a border.
    await tester.tap(find.text('Credit'));
    await tester.tap(find.text('Points'));
    await tester.pump();
    expect(control('tap.credit').selected, isTrue);
    expect(control('tap.points').selected, isNull);

    final tile = control('btn.thai_yoga');
    await tester.tap(find.text('Thai Yoga'));
    await tester.pump();
    // The cart row reads first in its own list; the grid tile keeps its name.
    expect(control('btn.thai_yoga').instance, tile.instance);
    expect(control('btn.thai_yoga_2').instance, isNot(tile.instance));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Total RM 120.00'), findsOneWidget);

    // Menu rows are named after their text, never their GlobalKey or icon.
    await tester.tap(find.byIcon(CupertinoIcons.ellipsis_circle));
    await tester.pumpAndSettle();
    final menuIds = runtime.debugSnapshot().interactables.map((n) => n.id);
    expect(menuIds, containsAll(['btn.sort_by_name', 'btn.advanced_edit']));
    expect(menuIds.where((id) => id.contains('globalkey')), isEmpty);
  });
}
