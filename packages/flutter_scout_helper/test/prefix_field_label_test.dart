import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'empty inline name field uses own wrapped prefix, not preceding contact row',
    (tester) async {
      FlutterScoutHelper.ensureRegistered();
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: Column(
                children: [
                  const SizedBox(
                    height: 52,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('联络号码'),
                    ),
                  ),
                  TextFormField(
                    controller: controller,
                    textAlign: TextAlign.end,
                    decoration: const InputDecoration(
                      hintText: '',
                      prefixIcon: Padding(
                        padding: EdgeInsets.all(16),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [Text('名字')],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final fields = FlutterScoutHelper.debugRuntime.debugSnapshot().fields;
      expect(fields.map((field) => field.label), contains('名字'));
      expect(fields.map((field) => field.label), isNot(contains('联络号码')));
      final field = fields.singleWhere((field) => field.label == '名字');
      final result = await tester.runAsync(
        () => FlutterScoutHelper.debugRuntime.debugInputTarget(
          field.id,
          'QA Test',
        ),
      );
      expect(result?['ok'], isTrue, reason: '$result');
      expect(controller.text, 'QA Test');
    },
  );

  testWidgets('hidden prefix text is not promoted to a field label', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TextField(
            decoration: InputDecoration(
              hintText: '',
              prefixIcon: Offstage(child: Text('HiddenName')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      FlutterScoutHelper.debugRuntime.debugSnapshot().fields.map(
        (f) => f.label,
      ),
      isNot(contains('HiddenName')),
    );
  });

  testWidgets('truncated prefix traversal does not invent a unique label', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    Widget deep = const Text('Second');
    for (var i = 0; i < 90; i++) {
      deep = Padding(padding: EdgeInsets.zero, child: deep);
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            decoration: InputDecoration(
              hintText: '',
              prefixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [const Text('First'), deep],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      FlutterScoutHelper.debugRuntime.debugSnapshot().fields.map(
        (f) => f.label,
      ),
      isNot(contains('First')),
    );
  });
}
