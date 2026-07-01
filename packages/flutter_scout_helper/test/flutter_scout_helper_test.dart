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
    expect(bytes!.sublist(0, 4), equals(<int>[0x89, 0x50, 0x4E, 0x47]));
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
      // plus encode). Capture waits two frames for a deterministic clean
      // raster; with no frame pump in tests each hits the 500ms frame timeout,
      // so allow > 2× that here (a real app pumps frames in ~16ms each).
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(
        annotation.beforeCropPng,
        isNotNull,
        reason: 'before crop should be captured in-app at creation',
      );

      final seqBefore = runtime.debugHandoffSeq;
      runtime.debugSignalHandoff();
      expect(runtime.debugHandoffSeq, seqBefore + 1);

      expect(runtime.debugMarkFixed(annotation.id), isTrue);
      expect(annotation.status, 'pending_review');
      expect(annotation.isActive, isTrue);
    });

    await tester.pump();
  });

  testWidgets('removeAnnotation deletes only the requested id', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    final runtime = FlutterScoutHelper.debugRuntime;

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

    // Seed the list directly so the `delete` action's removed/notFound
    // reporting (built on removeAnnotation) is exercised without the async
    // before-crop capture that addAnnotation kicks off.
    runtime.debugAnnotations
      ..clear()
      ..add(
        ScoutAnnotation(
          id: 'ann_001',
          createdAt: DateTime(2024),
          comment: 'first',
          status: 'open',
          target: target,
        ),
      )
      ..add(
        ScoutAnnotation(
          id: 'ann_002',
          createdAt: DateTime(2024),
          comment: 'second',
          status: 'open',
          target: target,
        ),
      );

    expect(runtime.removeAnnotation('ann_001'), isTrue, reason: 'removed');
    expect(runtime.removeAnnotation('ann_404'), isFalse, reason: 'notFound');
    expect(
      runtime.debugAnnotations.map((annotation) => annotation.id),
      ['ann_002'],
      reason: 'untargeted pins must survive',
    );

    runtime.debugAnnotations.clear();
  });

  testWidgets(
    'annotation targets exclude non-interactive content under an opaque layer',
    (tester) async {
      FlutterScoutHelper.ensureRegistered();
      final runtime = FlutterScoutHelper.debugRuntime;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                // Covered by the opaque gesture layer painted on top of it.
                const Positioned(
                  left: 0,
                  top: 0,
                  width: 200,
                  height: 100,
                  child: Center(child: Text('BehindLabel')),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  width: 200,
                  height: 100,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                  ),
                ),
                // Nothing on top of this one.
                const Positioned(
                  left: 0,
                  top: 300,
                  width: 200,
                  height: 100,
                  child: Center(child: Text('VisibleLabel')),
                ),
              ],
            ),
          ),
        ),
      );
      runtime.debugSetAnnotationMode(true);
      await tester.pumpAndSettle();

      final labels = runtime
          .debugVisibleAnnotationTargets()
          .map((target) => target.text ?? target.label)
          .toList();

      // The strict occlusion-aware gate (used for non-interactive kinds) drops
      // the label hidden under the opaque layer while keeping the visible one.
      expect(labels, contains('VisibleLabel'));
      expect(labels, isNot(contains('BehindLabel')));

      runtime.debugSetAnnotationMode(false);
      await tester.pump();
    },
  );

  testWidgets(
    'a tappable container is surfaced and labeled from a contained text sibling',
    (tester) async {
      FlutterScoutHelper.ensureRegistered();
      final runtime = FlutterScoutHelper.debugRuntime;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 100,
                // The label is a sibling of the tappable layer, not inside its
                // own subtree, so only inspect-style cross-node inference can
                // attach it. This mirrors the real "Add Appointment" card.
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {},
                      ),
                    ),
                    const Center(child: Text('OpenReport')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      runtime.debugSetAnnotationMode(true);
      await tester.pumpAndSettle();

      final tappables = runtime
          .debugVisibleAnnotationTargets()
          .where((target) => target.kind == 'tap' || target.kind == 'btn')
          .map((target) => target.label)
          .toList();

      // The container has no text of its own; it must borrow "OpenReport".
      expect(tappables, contains('OpenReport'));

      runtime.debugSetAnnotationMode(false);
      await tester.pump();
    },
  );

  testWidgets(
    'a non-interactive card with a visible background is surfaced as a box',
    (tester) async {
      FlutterScoutHelper.ensureRegistered();
      final runtime = FlutterScoutHelper.debugRuntime;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                // A filled card (no onTap) — should surface as a whole box.
                Positioned(
                  left: 20,
                  top: 100,
                  width: 200,
                  height: 80,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFE0E0FF),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: const Text('TotalEffort'),
                  ),
                ),
                // A transparent layout wrapper — must NOT surface as a box.
                const Positioned(
                  left: 20,
                  top: 220,
                  width: 200,
                  height: 80,
                  child: DecoratedBox(
                    decoration: BoxDecoration(),
                    child: Center(child: Text('PlainArea')),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      runtime.debugSetAnnotationMode(true);
      await tester.pumpAndSettle();

      final boxes = runtime.debugVisibleAnnotationTargets().where(
        (target) => target.kind == 'widget' || target.kind == 'layout',
      );
      final cardRect = boxes.where((t) => t.label == 'TotalEffort');
      expect(cardRect, isNotEmpty, reason: 'filled card should be a box');
      // The transparent wrapper paints nothing, so it should not be a box.
      expect(
        boxes.where((t) => t.label == 'PlainArea'),
        isEmpty,
        reason: 'transparent layout wrapper should not surface',
      );

      runtime.debugSetAnnotationMode(false);
      await tester.pump();
    },
  );

  group('scoutAnnotationDialogPlacement', () {
    const screen = Size(400, 800);
    const safe = EdgeInsets.only(top: 44, bottom: 34);
    const dialog = Size(300, 200);

    test('anchors to the right of a small left-edge target', () {
      final p = scoutAnnotationDialogPlacement(
        target: const Rect.fromLTWH(8, 300, 40, 40),
        dialog: const Size(280, 180),
        screen: screen,
        safeArea: safe,
        keyboardInset: 0,
      );
      // Right side has room, so it sits just past the target's right edge.
      expect(p.offset.dx, greaterThanOrEqualTo(48));
      expect(p.origin, Alignment.centerLeft);
    });

    test('keeps the dialog above the keyboard for a low target', () {
      const keyboard = 300.0;
      final p = scoutAnnotationDialogPlacement(
        target: const Rect.fromLTWH(20, 700, 120, 60),
        dialog: dialog,
        screen: screen,
        safeArea: safe,
        keyboardInset: keyboard,
      );
      // Bottom of the dialog must clear the keyboard line (with margin).
      expect(p.offset.dy + dialog.height, lessThanOrEqualTo(800 - keyboard));
    });

    test('stays within the horizontal safe area', () {
      final p = scoutAnnotationDialogPlacement(
        target: const Rect.fromLTWH(20, 120, 362, 50), // full-width row
        dialog: dialog,
        screen: screen,
        safeArea: safe,
        keyboardInset: 0,
      );
      expect(p.offset.dx, greaterThanOrEqualTo(12));
      expect(p.offset.dx + dialog.width, lessThanOrEqualTo(400 - 12));
    });
  });
}
