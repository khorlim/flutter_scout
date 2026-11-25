import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// [depth] wrapper levels, like a press-effect card's ripple, rim, shadow
/// and clip layers between the tappable and its content.
Widget _deep(Widget child, int depth) {
  var widget = child;
  for (var i = 0; i < depth; i++) {
    widget = Padding(padding: EdgeInsets.zero, child: widget);
  }
  return widget;
}

/// A custom pressable that is a target through its Semantics only.
Widget _pressable({required Widget child}) => Semantics(
  button: true,
  selected: false,
  onTap: () {},
  child: Listener(onPointerUp: (_) {}, child: _deep(child, 22)),
);

void main() {
  testWidgets('controls are named after their own text, not their icons, '
      'avatar initials or GlobalKey hashes', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              // Product tile: placeholder glyph, name, price, stock glyph.
              SizedBox(
                height: 64,
                child: _pressable(
                  child: Row(
                    children: [
                      const Icon(CupertinoIcons.cube_box_fill),
                      Expanded(
                        child: Column(
                          children: [
                            const Text('Thai Yoga'),
                            Row(
                              children: const [
                                Text('RM 120.00'),
                                Icon(CupertinoIcons.cube_box),
                                Text('5'),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Menu row: GlobalKey, invisible checkmark, item icon, title.
              CupertinoButton(
                key: GlobalKey(),
                onPressed: () {},
                child: Row(
                  children: [
                    const AnimatedOpacity(
                      opacity: 0,
                      duration: Duration.zero,
                      child: Icon(CupertinoIcons.checkmark),
                    ),
                    const Icon(CupertinoIcons.pencil),
                    Expanded(child: _deep(const Text('Advanced Edit'), 4)),
                  ],
                ),
              ),
              // Member card: avatar initials before the name.
              SizedBox(
                height: 64,
                child: _pressable(
                  child: const Row(
                    children: [
                      CircleAvatar(child: Text('ZY')),
                      Column(
                        children: [
                          Row(children: [Text('Zern Yet'), Icon(Icons.male)]),
                          Text('0123456789'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // Filter segments whose labels differ only by a symbol.
              GestureDetector(onTap: () {}, child: const Text('<180 days')),
              GestureDetector(onTap: () {}, child: const Text('>180 days')),
              // Icon-only controls keep their icon name.
              IconButton(onPressed: () {}, icon: const Icon(Icons.search)),
              // A string key still names a control; a feature key above it
              // is still an alternate handle.
              TextButton(
                key: const ValueKey('menu_button'),
                onPressed: () {},
                child: const Text('Default'),
              ),
              KeyedSubtree(
                key: const ValueKey('feature.order_menu'),
                child: TextButton(
                  onPressed: () {},
                  child: const Text('Custom menu'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final controls = FlutterScoutHelper.debugRuntime
        .debugSnapshot()
        .interactables;
    final ids = controls.map((node) => node.id).toList();
    expect(
      ids,
      containsAll(<String>[
        'btn.thai_yoga',
        'btn.advanced_edit',
        'btn.zern_yet',
        'tap.lt_180_days',
        'tap.gt_180_days',
        'btn.search',
        'btn.menu_button',
        'btn.custom_menu',
      ]),
    );
    expect(ids.where((id) => id.contains('globalkey')), isEmpty);
    final keyed = controls.singleWhere((node) => node.id == 'btn.menu_button');
    expect(keyed.label, 'Default');
    final menu = controls.singleWhere((node) => node.id == 'btn.custom_menu');
    expect(menu.altIds, contains('btn.feature_order_menu'));
    expect(
      FlutterScoutHelper.debugRuntime.debugResolveTarget(
        'tap.lt_180_days',
      )['status'],
      'unique',
    );
  });
}
