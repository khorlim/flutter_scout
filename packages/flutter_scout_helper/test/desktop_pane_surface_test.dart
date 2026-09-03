import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('desktop detail sheet leaves sibling navigator controls usable', (
    tester,
  ) async {
    var backCount = 0;
    await tester.pumpWidget(_desktopPanes(onBack: () => backCount++));
    await tester.pumpAndSettle();
    final runtime = FlutterScoutRuntime();
    final snapshot = runtime.debugSnapshot();
    expect(snapshot.findNode('btn.back')!.hitTestable, isTrue);
    expect(snapshot.activeSurface, isNull);
    final brief = runtime.debugInspectPayload(brief: true);
    expect(brief['visibleText'], contains('Back'));
    expect(brief['visibleText'], contains('Template'));
    final result = (await tester.runAsync(
      () => runtime.debugTapTarget('btn.back'),
    ))!;
    expect(result['ok'], isTrue);
    expect(backCount, 1);
  });

  testWidgets('pane dialog blocks its background but permits sibling actions', (
    tester,
  ) async {
    var backCount = 0;
    var detailCount = 0;
    final detailNavigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      _desktopPanes(
        onBack: () => backCount++,
        onDetail: () => detailCount++,
        detailNavigator: detailNavigator,
      ),
    );
    await tester.pumpAndSettle();
    showDialog<void>(
      context: detailNavigator.currentState!.context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        title: const Text('Confirm template'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close confirmation'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final runtime = FlutterScoutRuntime();
    expect(runtime.debugSnapshot().activeSurface, isNull);
    final sibling = (await tester.runAsync(
      () => runtime.debugTapTarget('btn.back'),
    ))!;
    expect(sibling['ok'], isTrue);
    final covered = (await tester.runAsync(
      () => runtime.debugTapTarget('btn.detail_action'),
    ))!;
    expect(covered['ok'], isFalse);
    expect(backCount, 1);
    expect(detailCount, 0);
    final close = (await tester.runAsync(
      () => runtime.debugTapTarget('btn.close_confirmation'),
    ))!;
    expect(close['ok'], isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Confirm template'), findsNothing);
  });

  testWidgets('root modal still blocks both desktop navigators', (
    tester,
  ) async {
    var backCount = 0;
    final rootNavigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      _desktopPanes(onBack: () => backCount++, rootNavigator: rootNavigator),
    );
    await tester.pumpAndSettle();
    showDialog<void>(
      context: rootNavigator.currentState!.context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm all panes'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close confirmation'),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final runtime = FlutterScoutRuntime();
    expect(find.text('Confirm all panes'), findsOneWidget);
    expect(
      runtime.debugSnapshot().activeSurface?['label'],
      'Confirm all panes',
    );
    expect(
      runtime.debugInspectPayload(brief: true)['visibleText'],
      isNot(contains('Back')),
    );
    final blocked = (await tester.runAsync(
      () => runtime.debugTapTarget('btn.back'),
    ))!;
    expect(blocked['ok'], isFalse);
    expect(backCount, 0);
    final close = (await tester.runAsync(
      () => runtime.debugTapTarget('btn.close_confirmation'),
    ))!;
    expect(close['ok'], isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Confirm all panes'), findsNothing);
  });
}

Widget _desktopPanes({
  required VoidCallback onBack,
  VoidCallback? onDetail,
  GlobalKey<NavigatorState>? rootNavigator,
  GlobalKey<NavigatorState>? detailNavigator,
}) => MaterialApp(
  navigatorKey: rootNavigator,
  home: Scaffold(
    body: Row(
      children: [
        SizedBox(
          width: 240,
          child: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: TextButton(
                    onPressed: onBack,
                    child: const Text('Back'),
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: Navigator(
            key: detailNavigator,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: DraggableScrollableSheet(
                  initialChildSize: 1,
                  builder: (_, controller) => Material(
                    child: ListView(
                      controller: controller,
                      children: [
                        const Text('Template'),
                        TextButton(
                          onPressed: onDetail ?? () {},
                          child: const Text('Detail action'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  ),
);
