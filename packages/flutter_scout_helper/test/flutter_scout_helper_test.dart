import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ensureInitialized can be called more than once', () {
    FlutterScoutBinding.ensureInitialized();
    FlutterScoutBinding.ensureInitialized();
  });

  test('ensureRegistered can be called more than once', () {
    FlutterScoutHelper.ensureRegistered();
    FlutterScoutHelper.ensureRegistered();
  });

  testWidgets('in-app capture rasterises the screen to PNG bytes', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('hello scout'))),
      ),
    );
    await tester.pump();

    final runtime = FlutterScoutHelper.debugRuntime;
    final bytes = await tester.runAsync(() => runtime.debugCaptureRegion());

    expect(bytes, isNotNull);
    // PNG magic number: 89 50 4E 47.
    expect(
      bytes!.sublist(0, 4),
      equals(<int>[0x89, 0x50, 0x4E, 0x47]),
    );
  });

  testWidgets('annotation captures a before crop, marks fixed, and signals '
      'handoff', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    final runtime = FlutterScoutHelper.debugRuntime;
    runtime.debugAnnotations.clear();

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('hello scout'))),
      ),
    );
    await tester.pump();

    const target = ScoutAnnotationTarget(
      id: 't1',
      stableId: 's1',
      kind: 'text',
      widgetType: 'Text',
      key: null,
      label: 'hello scout',
      text: 'hello scout',
      screen: '/',
      routeGuess: '/',
      rect: Rect.fromLTWH(0, 0, 120, 40),
      visibleRect: Rect.fromLTWH(0, 0, 120, 40),
      visibleFraction: 1,
      depth: 1,
      ancestorSummary: <String>[],
      scoutNodeId: null,
    );

    await tester.runAsync(() async {
      final annotation = runtime.addAnnotation(
        target: target,
        comment: 'too wide',
      );
      expect(annotation.status, 'open');
      expect(annotation.isActive, isTrue);

      // Let the fire-and-forget before-crop capture finish (500ms frame wait
      // plus encode).
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(annotation.beforeCropPng, isNotNull,
          reason: 'before crop should be captured in-app at creation');

      final seqBefore = runtime.debugHandoffSeq;
      runtime.debugSignalHandoff();
      expect(runtime.debugHandoffSeq, seqBefore + 1);

      expect(runtime.debugMarkFixed(annotation.id), isTrue);
      expect(annotation.status, 'pending_review');
      expect(annotation.isActive, isTrue);
    });

    await tester.pump();
  });
}
