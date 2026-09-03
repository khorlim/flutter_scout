import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

Widget settingsRow(String title, Widget control, {String? subtitle}) => Padding(
  padding: const EdgeInsets.all(12),
  child: Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [Text(title), if (subtitle != null) Text(subtitle)],
        ),
      ),
      control,
    ],
  ),
);

Future<void> showSettings(WidgetTester tester, List<Widget> rows) async {
  FlutterScoutHelper.ensureRegistered();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Column(children: rows)),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('wide settings rows expose the title and preserve raw handles', (
    tester,
  ) async {
    var changes = 0;
    await showSettings(tester, [
      settingsRow(
        'Enable Signature',
        CupertinoSwitch(value: true, onChanged: (_) {}),
      ),
      settingsRow(
        'Enable Overall Remark',
        CupertinoSwitch(value: false, onChanged: (_) => changes++),
        subtitle: 'Allow an overall note on this form',
      ),
      settingsRow(
        'Send notifications',
        Switch(value: false, onChanged: (_) {}),
      ),
    ]);
    final runtime = FlutterScoutHelper.debugRuntime;
    final switches = runtime.debugSnapshot().interactables.where(
      (node) => ['Switch', 'CupertinoSwitch'].contains(node.widgetType),
    );
    expect(switches.map((node) => node.label), [
      'Enable Signature',
      'Enable Overall Remark',
      'Send notifications',
    ]);
    final remark = switches.elementAt(1);
    expect(remark.id, 'btn.cupertinoswitch_2');
    expect(remark.altIds, contains('btn.enable_overall_remark'));
    expect(
      remark.altIds,
      isNot(contains('btn.allow_an_overall_note_on_this_form')),
    );
    expect(remark.selected, isFalse);
    expect(runtime.debugResolveTarget(remark.id)['status'], 'unique');
    expect(
      runtime.debugResolveTarget('btn.enable_overall_remark')['status'],
      'unique',
    );
    final result = await tester.runAsync(
      () => runtime.debugTapTarget('btn.enable_overall_remark'),
    );
    expect(result?['ok'], isTrue, reason: '$result');
    expect(changes, 1);
  });

  testWidgets('disabled keyed switch keeps its label and refuses dispatch', (
    tester,
  ) async {
    await showSettings(tester, [
      settingsRow(
        'Enable Overall Remark',
        const CupertinoSwitch(
          key: ValueKey('remark_toggle'),
          value: true,
          onChanged: null,
        ),
      ),
    ]);
    final runtime = FlutterScoutHelper.debugRuntime;
    final node = runtime.debugSnapshot().interactables.singleWhere(
      (node) => node.widgetType == 'CupertinoSwitch',
    );
    expect(node.id, 'btn.remark_toggle');
    expect(node.label, 'Enable Overall Remark');
    expect(node.enabled, isFalse);
    expect(node.selected, isTrue);
    final result = await tester.runAsync(
      () => runtime.debugTapTarget('btn.enable_overall_remark'),
    );
    expect(result?['ok'], isFalse);
    expect((result?['resolution'] as Map)['status'], 'disabled');
  });

  testWidgets('multiple switches or competing labels do not borrow row text', (
    tester,
  ) async {
    await showSettings(tester, [
      Row(
        children: [
          CupertinoSwitch(value: false, onChanged: (_) {}),
          const Text('Ambiguous setting'),
          CupertinoSwitch(value: true, onChanged: (_) {}),
        ],
      ),
      Row(
        children: [
          const Text('First heading'),
          const Spacer(),
          const Text('Second heading'),
          CupertinoSwitch(value: false, onChanged: (_) {}),
        ],
      ),
      Row(
        children: [
          const Expanded(
            child: Row(children: [Text('Left heading'), Text('Right heading')]),
          ),
          CupertinoSwitch(value: false, onChanged: (_) {}),
        ],
      ),
    ]);
    final switches = FlutterScoutHelper.debugRuntime
        .debugSnapshot()
        .interactables
        .where((node) => node.widgetType == 'CupertinoSwitch');
    expect(switches, hasLength(4));
    for (final node in switches) {
      expect(node.label, isNull);
      expect(node.altIds, isEmpty);
    }
  });

  testWidgets('localized RTL labels remain aliases and duplicates abstain', (
    tester,
  ) async {
    var changes = 0;
    await showSettings(tester, [
      Directionality(
        textDirection: TextDirection.rtl,
        child: settingsRow(
          'تفعيل الملاحظات',
          CupertinoSwitch(value: false, onChanged: (_) => changes++),
          subtitle: 'أضف ملاحظة إلى النموذج',
        ),
      ),
      for (var index = 0; index < 2; index++)
        settingsRow(
          '启用备注',
          CupertinoSwitch(value: false, onChanged: (_) => changes++),
        ),
    ]);
    final runtime = FlutterScoutHelper.debugRuntime;
    expect(
      runtime.debugResolveTarget('btn.تفعيل_الملاحظات')['status'],
      'unique',
    );
    expect(runtime.debugResolveTarget('btn.启用备注')['status'], 'ambiguous');
    final duplicate = await tester.runAsync(
      () => runtime.debugTapTarget('btn.启用备注'),
    );
    expect(duplicate?['ok'], isFalse);
    expect(changes, 0);
    final localized = await tester.runAsync(
      () => runtime.debugTapTarget('btn.تفعيل_الملاحظات'),
    );
    expect(localized?['ok'], isTrue, reason: '$localized');
    expect(changes, 1);
  });

  testWidgets('a heading outside the switch row is not a switch label', (
    tester,
  ) async {
    await showSettings(tester, [
      const Text('Unrelated heading'),
      Row(
        children: [
          const Spacer(),
          CupertinoSwitch(value: false, onChanged: (_) {}),
        ],
      ),
    ]);
    final node = FlutterScoutHelper.debugRuntime
        .debugSnapshot()
        .interactables
        .singleWhere((node) => node.widgetType == 'CupertinoSwitch');
    expect(node.label, isNull);
    expect(node.altIds, isEmpty);
  });
}
