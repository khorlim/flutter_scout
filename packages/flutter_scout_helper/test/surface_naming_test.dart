import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// A popover page like a POS app's dialogs: an app bar over a body.
Widget _popover({required Widget title, required Widget body}) => Dialog(
  child: _page(title: title, body: body),
);

Widget _page({required Widget title, required Widget body}) => SizedBox(
  width: 360,
  height: 420,
  child: Scaffold(
    appBar: AppBar(title: title),
    body: body,
  ),
);

/// A member picker with no title of its own: its app bar holds a
/// segmented control.
class MemberListScreen extends StatelessWidget {
  const MemberListScreen({super.key, required this.members});

  final ValueNotifier<List<String>> members;

  @override
  Widget build(BuildContext context) => _page(
    title: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final segment in ['Car', 'Member'])
          GestureDetector(onTap: () {}, child: Text(segment)),
      ],
    ),
    body: ValueListenableBuilder<List<String>>(
      valueListenable: members,
      builder: (context, names, _) => ListView(
        children: [
          for (final name in names) ListTile(title: Text(name), onTap: () {}),
        ],
      ),
    ),
  );
}

Future<Map<String, Object?>> _surfaceAfterOpening(
  WidgetTester tester,
  Widget Function(BuildContext context) builder,
) async {
  FlutterScoutHelper.ensureRegistered();
  late BuildContext home;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          home = context;
          return const Scaffold(body: Text('Order'));
        },
      ),
    ),
  );
  showDialog<void>(context: home, builder: builder);
  await tester.pumpAndSettle();
  return _surface();
}

Map<String, Object?> _surface() =>
    (FlutterScoutHelper.debugRuntime.debugSnapshot().activeSurface ?? {})
        .cast<String, Object?>();

void main() {
  testWidgets('a surface is named from its app bar title, not the first '
      'bold label in it', (tester) async {
    final surface = await _surfaceAfterOpening(
      tester,
      (_) => _popover(
        title: const Text('Member Detail'),
        body: const Column(
          children: [
            Text(
              'OUTSTANDING',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
            Text('RM 0.00'),
          ],
        ),
      ),
    );
    expect(surface['label'], 'Member Detail');
    expect(surface['screen'], 'MemberDetailSurface');
    expect(surface['source'], 'appBarTitle');
  });

  testWidgets('an item sheet is named from its product title, not a '
      'field row', (tester) async {
    final surface = await _surfaceAfterOpening(
      tester,
      (_) => _popover(
        title: const Text('Thai Yoga'),
        body: const Column(children: [Text('Quantity'), Text('Price')]),
      ),
    );
    expect(surface['label'], 'Thai Yoga');
  });

  testWidgets('a surface without a title is named from its widget type and '
      'keeps that name while its content changes', (tester) async {
    final members = ValueNotifier(['Zern Yet', 'Ali']);
    addTearDown(members.dispose);
    final opened = await _surfaceAfterOpening(
      tester,
      (_) => Dialog(child: MemberListScreen(members: members)),
    );
    expect(opened['label'], 'MemberListScreen');
    expect(opened['source'], 'widgetType');
    members.value = ['Car Wash Sdn Bhd', 'Mei Ling'];
    await tester.pump();
    final later = _surface();
    expect(later['label'], opened['label']);
    expect(later['screen'], opened['screen']);
    expect(later['instance'], opened['instance']);
  });
}
