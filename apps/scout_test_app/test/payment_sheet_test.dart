import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_test_app/screens/stress_lab_screens.dart';

/// Runs a Scout action while frames keep coming, as on a device.
Future<Map<String, Object?>> _withFrames(
  WidgetTester tester,
  Future<Map<String, Object?>> Function() action,
) async {
  Map<String, Object?>? result;
  Object? error;
  action().then((value) => result = value, onError: (Object e) => error = e);
  for (var i = 0; i < 600 && result == null && error == null; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (error != null) throw error!;
  expect(result, isNotNull, reason: 'the action never completed');
  await tester.pumpAndSettle();
  return result!;
}

const _settle = {'waitMs': '1500'};

void main() {
  testWidgets('a payment row under the floating button is swiped open after '
      'scrolling it clear', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(const MaterialApp(home: PaymentSheetScreen()));
    final runtime = FlutterScoutHelper.debugRuntime;
    List<String> handles() => [
      for (final node in runtime.debugSnapshot().interactables) node.id,
    ];

    // Covered, the row has no handle, and the button keeps its own name.
    expect(handles(), contains('btn.add_payment'));
    expect(handles(), isNot(contains('btn.cash')));

    // Swiping the button moves nothing, and Scout says so.
    final wrong = await _withFrames(
      tester,
      () => runtime.debugSwipe({
        'target': 'btn.add_payment',
        'direction': 'left',
        ..._settle,
      }),
    );
    expect(wrong['ok'], isFalse, reason: '$wrong');
    expect((wrong['error']! as Map)['code'], 'swipe_no_effect');

    // Scroll the row clear of the button, then swipe its own handle.
    await _withFrames(
      tester,
      () => runtime.debugScroll({
        'direction': 'down',
        'x': '200',
        'y': '300',
        'distance': '200',
        ..._settle,
      }),
    );
    final rows = runtime
        .debugSnapshot()
        .interactables
        .where((node) => node.label == 'Cash')
        .toList();
    expect(rows, hasLength(1), reason: '${handles()}');
    expect(rows.single.enabled, isTrue);
    final swipe = await _withFrames(
      tester,
      () => runtime.debugSwipe({
        'target': rows.single.id,
        'direction': 'left',
        ..._settle,
      }),
    );
    expect(swipe['ok'], isTrue, reason: '$swipe');
    expect(swipe['result'], 'changed');
    expect(runtime.debugSnapshot().visibleText, contains('Delete'));

    final delete = runtime.debugSnapshot().interactables.singleWhere(
      (node) => node.label == 'Delete',
    );
    await _withFrames(tester, () => runtime.debugTapTarget(delete.id));
    expect(find.text('Status: deleted Cash'), findsOneWidget);
  });
}
