import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ordinary multilingual text stays visible and targetable', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    const labels = [
      '菜单',
      '添加服务',
      '存',
      '保存する',
      'حفظ',
      '저장',
      'บันทึก',
      'É',
      'Cafe\u0301',
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(children: [for (final label in labels) Text(label)]),
        ),
      ),
    );
    await tester.pump();

    final runtime = FlutterScoutHelper.debugRuntime;
    final snapshot = runtime.debugSnapshot();
    expect(snapshot.visibleText, containsAll(labels));
    expect(snapshot.textTargets.map((node) => node.label), containsAll(labels));
    expect(snapshot.textTargets.map((node) => node.id), contains('text.菜单'));
    expect(
      snapshot.textTargets.map((node) => node.id),
      contains('text.cafe\u0301'),
    );
    final located = await runtime.debugLocate({'text': '菜单'});
    expect(located['ok'], isTrue);
  });

  testWidgets('localized card and deep Cupertino labels drive exact actions', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A card with an icon before a wrapped Text, as in Tunaipro.
              GestureDetector(
                onTap: () => tapped.add('菜单'),
                child: const SizedBox(
                  width: 160,
                  height: 80,
                  child: Column(
                    children: [
                      Icon(Icons.menu),
                      Padding(padding: EdgeInsets.all(8), child: Text('菜单')),
                    ],
                  ),
                ),
              ),
              CupertinoButton(
                onPressed: () => tapped.add('添加服务'),
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [SizedBox(height: 4), Text('添加服务')],
                  ),
                ),
              ),
              CupertinoButton(
                onPressed: () => tapped.add('保存'),
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final runtime = FlutterScoutHelper.debugRuntime;
    final snapshot = runtime.debugSnapshot();
    expect(
      snapshot.interactables.map((node) => node.label),
      containsAll(['菜单', '添加服务', '保存']),
    );
    expect(snapshot.interactables.map((node) => node.id), contains('btn.保存'));
    final brief = runtime.debugInspectPayload(brief: true);
    expect(brief.toString(), contains('添加服务'));
    for (final label in ['菜单', '添加服务', '保存']) {
      final result = await tester.runAsync(
        () => runtime.debugTapTextTarget(label),
      );
      expect(result?['ok'], isTrue, reason: '$label: $result');
    }
    expect(tapped, ['菜单', '添加服务', '保存']);
  });

  testWidgets('short punctuation and private icon glyphs stay filtered', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Text('·'),
              Text('!?'),
              Text('\ue000'),
              Text('🚀'),
              Text('\u0301'),
              Text('保存'),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final snapshot = FlutterScoutHelper.debugRuntime.debugSnapshot();
    expect(snapshot.visibleText, contains('保存'));
    for (final glyph in ['·', '!?', '\ue000', '🚀', '\u0301']) {
      expect(snapshot.visibleText, isNot(contains(glyph)));
    }
  });

  testWidgets('duplicate localized labels abstain without dispatch', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (var index = 0; index < 2; index++)
                TextButton(onPressed: () => taps++, child: const Text('保存')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final runtime = FlutterScoutHelper.debugRuntime;
    expect(runtime.debugResolveTarget('保存')['status'], 'ambiguous');
    final result = await tester.runAsync(
      () => runtime.debugTapTextTarget('保存'),
    );
    expect(result?['ok'], isFalse);
    expect(taps, 0);
  });
}
