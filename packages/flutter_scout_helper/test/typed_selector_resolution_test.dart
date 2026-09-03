import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget fixture(VoidCallback onPressed, {bool includeText = false}) =>
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              CupertinoButton(
                key: const ValueKey('settings'),
                onPressed: onPressed,
                child: Semantics(
                  label: 'Form',
                  child: const Icon(Icons.settings),
                ),
              ),
              if (includeText) const Text('Form'),
            ],
          ),
        ),
      );

  testWidgets('missing typed selectors cannot dispatch a suffix alias', (
    tester,
  ) async {
    var dispatches = 0;
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(fixture(() => dispatches++));
    await tester.pump();
    final snapshot = runtime.debugSnapshot();
    final button = snapshot.interactables.single;
    expect(button.id, 'btn.settings');
    expect(button.altIds, contains('btn.form'));
    expect(snapshot.textTargets.any((node) => node.id == 'text.form'), isFalse);

    for (final selector in [
      'text.form',
      'TEXT.Form',
      'BTN.Form',
      'field.form',
      'tap.form',
      'scroll.form',
      'row.form',
      'btn.form#99',
    ]) {
      final result = (await tester.runAsync(
        () => runtime.debugTapTarget(selector),
      ))!;
      expect(result['ok'], isFalse, reason: selector);
      final resolution = result['resolution']! as Map;
      expect(resolution['status'], 'notFound', reason: selector);
      expect(resolution['target'], isNull, reason: selector);
      expect(dispatches, 0, reason: selector);
    }
    final located = await runtime.debugLocate({'target': 'text.form'});
    expect((located['resolution']! as Map)['status'], 'notFound');
    expect(located['ok'], isFalse);
  });

  testWidgets('exact text selectors bypass unrelated interactable aliases', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(fixture(() {}, includeText: true));
    await tester.pump();
    for (final selector in ['text.form', 'text.form#1']) {
      final result = await runtime.debugLocate({'target': selector});
      final resolution = result['resolution']! as Map;
      expect(result['ok'], isTrue, reason: selector);
      expect(resolution['status'], 'unique');
      expect((resolution['target']! as Map)['id'], 'text.form');
      expect((resolution['target']! as Map)['kind'], 'text');
    }
  });

  testWidgets('published aliases and untyped fuzzy selectors stay usable', (
    tester,
  ) async {
    var dispatches = 0;
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(fixture(() => dispatches++));
    await tester.pump();
    for (final selector in ['btn.form', 'form', 'FORM', 'for']) {
      final result = (await tester.runAsync(
        () => runtime.debugTapTarget(selector),
      ))!;
      expect(result['ok'], isTrue, reason: selector);
      final resolution = result['resolution']! as Map;
      expect((resolution['target']! as Map)['id'], 'btn.settings');
    }
    expect(dispatches, 4);
  });

  testWidgets('exact text handle taps its owner rather than another alias', (
    tester,
  ) async {
    var settingsDispatches = 0;
    var formDispatches = 0;
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              CupertinoButton(
                key: const ValueKey('settings'),
                onPressed: () => settingsDispatches++,
                child: Semantics(
                  label: 'Form',
                  child: const Icon(Icons.settings),
                ),
              ),
              ElevatedButton(
                key: const ValueKey('editor'),
                onPressed: () => formDispatches++,
                child: const Text('Form'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final result = (await tester.runAsync(
      () => runtime.debugTapTarget('text.form'),
    ))!;
    expect(result['ok'], isTrue);
    final target = (result['resolution']! as Map)['target']! as Map;
    expect(target['id'], 'text.form');
    expect(settingsDispatches, 0);
    expect(formDispatches, 1);
  });

  testWidgets('typed-looking labels require an explicit text query', (
    tester,
  ) async {
    var dispatches = 0;
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ElevatedButton(
            key: const ValueKey('field.literal'),
            onPressed: () => dispatches++,
            child: const Text('text.literal'),
          ),
        ),
      ),
    );
    await tester.pump();
    for (final selector in ['field.literal', 'text.literal']) {
      final result = (await tester.runAsync(
        () => runtime.debugTapTarget(selector),
      ))!;
      expect((result['resolution']! as Map)['status'], 'notFound');
      expect(dispatches, 0);
    }
    final textResult = (await tester.runAsync(
      () => runtime.debugTapTextTarget('text.literal'),
    ))!;
    expect(textResult['ok'], isTrue);
    expect(dispatches, 1);
  });

  testWidgets('published row aliases still dispatch their mapped target', (
    tester,
  ) async {
    var dispatches = 0;
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              ListTile(
                key: const ValueKey('supplier'),
                title: const Text('Acme Supplies'),
                subtitle: const Text('Details'),
                onTap: () => dispatches++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final row = runtime.debugSnapshot().structuredRows.single;
    final handles = (row['handles']! as Map).cast<String, String>();
    expect(handles, contains('row.acme_supplies'));
    final result = (await tester.runAsync(
      () => runtime.debugTapTarget('row.acme_supplies'),
    ))!;
    expect(result['ok'], isTrue);
    final target = (result['resolution']! as Map)['target']! as Map;
    expect(target['id'], handles['row.acme_supplies']);
    expect(dispatches, 1);
  });

  testWidgets('exact typed widget keys retain their declared control kind', (
    tester,
  ) async {
    var dispatches = 0;
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ElevatedButton(
            key: const ValueKey('btn.save'),
            onPressed: () => dispatches++,
            child: const Text('Submit'),
          ),
        ),
      ),
    );
    await tester.pump();
    final result = (await tester.runAsync(
      () => runtime.debugTapTarget('btn.save'),
    ))!;
    expect(result['ok'], isTrue);
    final target = (result['resolution']! as Map)['target']! as Map;
    expect(target['id'], 'btn.btn_save');
    expect(target['key'], 'btn.save');
    expect(dispatches, 1);
  });
}
