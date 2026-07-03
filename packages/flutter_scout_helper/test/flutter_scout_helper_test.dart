import 'dart:convert';

import 'package:flutter/cupertino.dart';
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
    'a tappable container with no own text is labeled from its content',
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
                // The tappable has no text of its own; its label must be borrowed
                // from the text it contains. Mirrors the real "Add Appointment"
                // card (a GestureDetector wrapping the label).
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: const Center(child: Text('OpenReport')),
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

  testWidgets('nested sub-regions and content rows are each selectable', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    final runtime = FlutterScoutHelper.debugRuntime;

    // Mirrors the "Add Appointment" empty state: a tappable card wrapping a
    // margined filled box wrapping a Row(icon + label).
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 140,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.all(20),
                      decoration: const BoxDecoration(color: Color(0xFFE7E7FF)),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add),
                          SizedBox(width: 8),
                          Text('OpenReport'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    runtime.debugSetAnnotationMode(true);
    await tester.pumpAndSettle();

    final targets = runtime.debugVisibleAnnotationTargets();

    // The card (the only interactive target here) stays selectable; the margined
    // filled box is a distinct nested region that must survive collapse; and the
    // icon+label Row surfaces as a groupable content row.
    expect(
      targets.any((t) => t.kind == 'tap' || t.kind == 'btn'),
      isTrue,
      reason: 'card should be selectable',
    );
    expect(
      targets.any((t) => t.kind == 'widget' && t.label == 'OpenReport'),
      isTrue,
      reason: 'inset filled box should survive collapse',
    );
    expect(
      targets.any((t) => t.kind == 'layout' && t.label == 'OpenReport'),
      isTrue,
      reason: 'content row should be selectable',
    );

    runtime.debugSetAnnotationMode(false);
    await tester.pump();
  });

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

  testWidgets('snapshot tolerates widgets with non-finite geometry', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Text('finite sibling'),
              // A NaN transform makes localToGlobal return non-finite
              // offsets; the snapshot must skip such rects instead of
              // throwing "Unsupported operation: Infinity or NaN toInt".
              // ExcludeSemantics keeps the test binding's semantics flush
              // from asserting on the same NaN before Scout runs.
              ExcludeSemantics(
                child: Transform(
                  transform: Matrix4.identity()..setEntry(0, 0, double.nan),
                  child: const SizedBox(
                    width: 100,
                    height: 40,
                    child: Text('nan zone'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final runtime = FlutterScoutHelper.debugRuntime;
    final snapshot = runtime.debugSnapshot();
    expect(snapshot.visibleText, contains('finite sibling'));
  });

  testWidgets('a throwing element degrades itself, not the whole snapshot', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    final runtime = FlutterScoutHelper.debugRuntime;
    runtime.debugSnapshotNodeProbe = (element) {
      if (element.widget is FlutterLogo) {
        throw StateError('injected per-node fault');
      }
    };
    addTearDown(() => runtime.debugSnapshotNodeProbe = null);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(children: [Text('healthy sibling'), FlutterLogo()]),
        ),
      ),
    );
    await tester.pump();

    final snapshot = runtime.debugSnapshot();
    expect(snapshot.visibleText, contains('healthy sibling'));
    expect(snapshot.degradedNodes, greaterThan(0));
    expect(snapshot.summaryJson()['degradedNodes'], snapshot.degradedNodes);

    // A healthy tree reports no degradation (and omits the key entirely).
    runtime.debugSnapshotNodeProbe = null;
    final healthy = runtime.debugSnapshot();
    expect(healthy.degradedNodes, 0);
    expect(healthy.summaryJson().containsKey('degradedNodes'), isFalse);
  });

  testWidgets('icon-only buttons get names from SDK tables and semantics', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              // Unlabeled CupertinoButton wrapping a Material icon that is NOT
              // in the curated semantic map — must resolve via the generated
              // SDK table instead of surfacing btn.cupertinobutton.
              CupertinoButton(
                onPressed: () {},
                child: const Icon(Icons.settings),
              ),
              // Cupertino glyph, also only in the generated table.
              CupertinoButton(
                onPressed: () {},
                child: const Icon(CupertinoIcons.person_badge_plus),
              ),
              // Accessibility label wins for icon-only controls.
              CupertinoButton(
                onPressed: () {},
                child: Semantics(
                  label: 'Admin area',
                  child: const Icon(Icons.abc),
                ),
              ),
              // Single-character plain text keeps its literal label.
              TextButton(onPressed: () {}, child: const Text('5')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final snapshot = FlutterScoutHelper.debugRuntime.debugSnapshot();
    final ids = snapshot.interactables.map((node) => node.id).toList();
    expect(ids, contains('btn.settings'));
    expect(ids, contains('btn.person_badge_plus'));
    expect(ids, contains('btn.admin_area'));
    expect(ids.where((id) => id.startsWith('btn.cupertinobutton')), isEmpty);
    // Single-character plain text keeps its literal label — no icon_35 noise.
    expect(snapshot.textTargets.map((node) => node.id), contains('text.5'));
  });

  testWidgets('interactables surface selection/toggle state', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              // Custom segment control: selection expressed via Semantics,
              // like a tab bar built from GestureDetectors.
              GestureDetector(
                onTap: () {},
                child: Semantics(
                  selected: true,
                  child: const SizedBox(
                    width: 80,
                    height: 30,
                    child: Text('T&C'),
                  ),
                ),
              ),
              GestureDetector(
                onTap: () {},
                child: Semantics(
                  selected: false,
                  child: const SizedBox(
                    width: 80,
                    height: 30,
                    child: Text('Outlet'),
                  ),
                ),
              ),
              Switch(value: true, onChanged: (_) {}),
              ChoiceChip(
                label: const Text('Filter'),
                selected: false,
                onSelected: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final snapshot = FlutterScoutHelper.debugRuntime.debugSnapshot();
    bool? selectedOf(String id) =>
        snapshot.interactables.firstWhere((node) => node.id == id).selected;
    expect(selectedOf('tap.t_c'), isTrue);
    expect(selectedOf('tap.outlet'), isFalse);
    final switchNode = snapshot.interactables.firstWhere(
      (node) => node.widgetType == 'Switch',
    );
    expect(switchNode.selected, isTrue);
    final chipNode = snapshot.interactables.firstWhere(
      (node) => node.widgetType == 'ChoiceChip',
      orElse: () => snapshot.interactables.firstWhere(
        (node) => (node.label ?? '') == 'Filter',
      ),
    );
    expect(chipNode.selected, isFalse);
    // Serialized only when known.
    expect(switchNode.toJson()['selected'], isTrue);
  });

  testWidgets('Scout chrome is excluded from inspect output', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('app text'))),
      ),
    );
    await tester.pumpAndSettle();

    final snapshot = FlutterScoutHelper.debugRuntime.debugSnapshot();
    // The annotation toggle FAB used to leak in as an app interactable
    // (tap.add_location_alt) that agents would try to press.
    expect(
      snapshot.interactables.map((node) => node.id),
      isNot(contains('tap.add_location_alt')),
    );
    expect(snapshot.visibleText, contains('app text'));
  });

  testWidgets('synthetic agent taps pass through Scout chrome', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => taps++,
              child: const Text('Hit me'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final runtime = FlutterScoutHelper.debugRuntime;
    runtime.debugSetAnnotationMode(true);
    // Overlay chrome installs via a post-frame callback, then the entry
    // itself builds on the following frame.
    await tester.pump();
    await tester.pump();
    addTearDown(() => runtime.debugSetAnnotationMode(false));

    final center = tester.getCenter(find.text('Hit me'));
    // A real user tap is absorbed by the annotation scrim (chrome works for
    // humans as before).
    await tester.tapAt(center);
    await tester.pump();
    expect(taps, 0);

    // An agent-dispatched tap treats Scout chrome as transparent and lands
    // on the app control beneath.
    await tester.runAsync(() => runtime.debugDispatchTap(center));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('brief inspect payload is compact; sections opt back in', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ElevatedButton(onPressed: () {}, child: const Text('Save')),
              const TextField(decoration: InputDecoration(labelText: 'Name')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final runtime = FlutterScoutHelper.debugRuntime;
    final brief = runtime.debugInspectPayload(brief: true);
    expect(brief['screen'], isNotNull);
    expect(brief['visibleText'], contains('Save'));
    expect(brief.containsKey('textTargets'), isFalse);
    expect(brief.containsKey('visualTree'), isFalse);
    expect(brief.containsKey('scrollables'), isFalse);
    final interactables = brief['interactables']! as List<Object?>;
    final save = interactables.cast<Map<String, Object?>>().firstWhere(
      (node) => node['id'] == 'btn.save',
    );
    // Compact node: no rects, no confidence plumbing.
    expect(save.containsKey('rect'), isFalse);
    expect(save.containsKey('confidence'), isFalse);
    expect(brief['fieldValues'], isA<Map<String, Object?>>());

    // Sections opt back into full data.
    final sectioned = runtime.debugInspectPayload(
      sections: {'textTargets', 'scrollables'},
    );
    expect(sectioned['textTargets'], isA<List<Object?>>());
    expect(sectioned['scrollables'], isA<List<Object?>>());
    expect(sectioned.containsKey('interactables'), isFalse);

    // Brief payload is materially smaller than the full one.
    final fullLength = jsonEncode(runtime.debugInspectPayload()).length;
    final briefLength = jsonEncode(brief).length;
    expect(briefLength, lessThan(fullLength ~/ 2));
  });

  testWidgets('tap-text --contains matches a truncated label', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 140,
            child: Text(
              'Prenatal Bliss\u2026',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final runtime = FlutterScoutHelper.debugRuntime;
    // Exact/substring fails (query is longer than the shown label)...
    expect(runtime.debugTapTextMatchId('Prenatal Bliss Massage'), isNull);
    // ...but loose matches the truncated prefix.
    expect(
      runtime.debugTapTextMatchId('Prenatal Bliss Massage', loose: true),
      isNotNull,
    );
  });

  testWidgets('brief adds position hints to duplicate handles', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              ElevatedButton(onPressed: () {}, child: const Text('Edit')),
              ElevatedButton(onPressed: () {}, child: const Text('Save')),
              ElevatedButton(onPressed: () {}, child: const Text('Edit')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final brief = FlutterScoutHelper.debugRuntime.debugInspectPayload(
      brief: true,
    );
    final nodes = (brief['interactables']! as List)
        .cast<Map<String, Object?>>();
    final edits = nodes
        .where((n) => (n['label'] as String?) == 'Edit')
        .toList();
    expect(edits.length, 2);
    // Duplicates carry an `at` position hint; the unique Save does not.
    expect(edits.every((n) => n.containsKey('at')), isTrue);
    expect(edits[0]['at'], isNot(edits[1]['at']));
    final save = nodes.firstWhere((n) => (n['label'] as String?) == 'Save');
    expect(save.containsKey('at'), isFalse);
  });

  testWidgets('wait-for conditions match visible text case-insensitively', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(children: [Text('Saved Successfully'), Text('Loading')]),
        ),
      ),
    );
    await tester.pump();

    final runtime = FlutterScoutHelper.debugRuntime;
    expect(
      runtime.debugWaitForConditionsMet({'text': 'saved success'}),
      isTrue,
    );
    expect(runtime.debugWaitForConditionsMet({'text': 'Deleted'}), isFalse);
    expect(runtime.debugWaitForConditionsMet({'gone': 'Loading'}), isFalse);
    expect(runtime.debugWaitForConditionsMet({'gone': 'Spinner'}), isTrue);
    expect(
      runtime.debugWaitForConditionsMet({'text': 'Saved', 'gone': 'Loading'}),
      isFalse,
    );

    // Spinner clears -> gone condition flips.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Column(children: [Text('Saved Successfully')])),
      ),
    );
    await tester.pump();
    expect(
      runtime.debugWaitForConditionsMet({'text': 'Saved', 'gone': 'Loading'}),
      isTrue,
    );
  });

  testWidgets('wait-for conditions: target, selected, screen, field', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ElevatedButton(onPressed: () {}, child: const Text('Go')),
              Switch(value: true, onChanged: (_) {}),
              const TextField(decoration: InputDecoration(labelText: 'Name')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final runtime = FlutterScoutHelper.debugRuntime;

    expect(runtime.debugWaitForConditionsMet({'target': 'btn.go'}), isTrue);
    expect(runtime.debugWaitForConditionsMet({'target': 'btn.nope'}), isFalse);
    expect(
      runtime.debugWaitForConditionsMet({'selected': 'btn.switch'}),
      isTrue,
    );
    expect(runtime.debugWaitForConditionsMet({'selected': 'btn.go'}), isFalse);
    final screen = runtime.debugSnapshot().screen;
    expect(runtime.debugWaitForConditionsMet({'screen': screen}), isTrue);
    expect(
      runtime.debugWaitForConditionsMet({'screen': 'OtherScreen'}),
      isFalse,
    );
    expect(runtime.debugWaitForConditionsMet({'field': 'field.name='}), isTrue);
    expect(
      runtime.debugWaitForConditionsMet({'field': 'field.name=abc'}),
      isFalse,
    );
    final signature = runtime.debugSnapshot().viewSignature;
    final fragment = signature.split(' | ').first;
    expect(runtime.debugWaitForConditionsMet({'view': fragment}), isTrue);
    expect(
      runtime.debugWaitForConditionsMet({'view': 'no-such-view'}),
      isFalse,
    );
  });

  testWidgets('action expectations gate in the same call', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('Ready'))),
      ),
    );
    await tester.pump();
    final runtime = FlutterScoutHelper.debugRuntime;

    final met = await tester.runAsync(
      () => runtime.debugActionExpectation({'expectText': 'Ready'}),
    );
    expect(met!['ok'], isTrue);
    final expectation = met['expectation']! as Map<String, Object?>;
    expect(expectation['met'], isTrue);
    expect(
      (expectation['conditions']! as Map<String, Object?>)['text'],
      'Ready',
    );

    final unmet = await tester.runAsync(
      () => runtime.debugActionExpectation({
        'expectText': 'Never Appears',
        'expectTimeoutMs': '250',
      }),
    );
    expect(unmet!['ok'], isFalse);
    expect(
      (unmet['error']! as Map<String, Object?>)['code'],
      'expectation_not_met',
    );
    expect((unmet['expectation']! as Map<String, Object?>)['met'], isFalse);
    // The action outcome itself is preserved alongside the failed expectation.
    expect(unmet['result'], 'changed');

    // Without expect params the payload passes through untouched.
    final plain = await tester.runAsync(
      () => runtime.debugActionExpectation({}),
    );
    expect(plain!['ok'], isTrue);
    expect(plain.containsKey('expectation'), isFalse);
  });

  testWidgets('viewSignature distinguishes views on the same route', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    final runtime = FlutterScoutHelper.debugRuntime;

    Widget view(String title, List<String> items) => MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Text(title, style: const TextStyle(fontSize: 32)),
            for (final item in items) Text(item),
          ],
        ),
      ),
    );

    await tester.pumpWidget(view('Operation', ['Member', 'Orders']));
    await tester.pump();
    final operation = runtime.debugSnapshot();
    // Stable across re-snapshots of the same view.
    expect(runtime.debugSnapshot().viewSignature, operation.viewSignature);
    expect(runtime.debugSnapshot().visibleTextHash, operation.visibleTextHash);
    // The big title leads the signature (prominence by painted area).
    expect(operation.viewSignature, startsWith('Operation'));

    await tester.pumpWidget(view('Admin', ['Menu', 'Setting']));
    await tester.pump();
    final admin = runtime.debugSnapshot();
    expect(admin.viewSignature, isNot(operation.viewSignature));
    expect(admin.visibleTextHash, isNot(operation.visibleTextHash));
    expect(admin.summaryJson()['viewSignature'], admin.viewSignature);
  });

  testWidgets('segment selection is inferred from the odd text color', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    Widget segment(String label, Color color) => GestureDetector(
      onTap: () {},
      child: SizedBox(
        width: 90,
        height: 32,
        child: Center(
          child: Text(label, style: TextStyle(color: color)),
        ),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              // Custom segmented control: active segment has a distinct color.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  segment('AllX', Colors.grey),
                  segment('ActiveX', Colors.blue),
                  segment('InactiveX', Colors.grey),
                ],
              ),
              const SizedBox(height: 60),
              // Spread-out row of same-kind buttons: adjacency gate must
              // prevent inference (corner toolbar false positive).
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  segment('LeftX', Colors.grey),
                  segment('MidX', Colors.blue),
                  segment('RightX', Colors.grey),
                ],
              ),
              const SizedBox(height: 60),
              // Uniform colors: nothing to infer.
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  segment('OneY', Colors.grey),
                  segment('TwoY', Colors.grey),
                  segment('ThreeY', Colors.grey),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final snapshot = FlutterScoutHelper.debugRuntime.debugSnapshot();
    bool? selectedOf(String id) =>
        snapshot.interactables.firstWhere((node) => node.id == id).selected;
    expect(selectedOf('tap.activex'), isTrue);
    expect(selectedOf('tap.allx'), isFalse);
    expect(selectedOf('tap.inactivex'), isFalse);
    // Spread-out row: no inference.
    expect(selectedOf('tap.midx'), isNull);
    expect(selectedOf('tap.leftx'), isNull);
    // Uniform row: no inference.
    expect(selectedOf('tap.oney'), isNull);
  });

  testWidgets('TickerMode-disabled content stays visible to inspect', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TickerMode(
            // A backgrounded window / inactive tab disables TickerMode; the
            // content is still painted and tappable, so Scout must still see
            // it (regression for the pruned-dashboard-grid bug).
            enabled: false,
            child: Column(
              children: [
                ElevatedButton(onPressed: () {}, child: const Text('DashTile')),
                const Text('visible under paused ticker'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final snapshot = FlutterScoutHelper.debugRuntime.debugSnapshot();
    expect(snapshot.visibleText, contains('visible under paused ticker'));
    expect(
      snapshot.interactables.map((node) => node.id),
      contains('btn.dashtile'),
    );
  });

  testWidgets('modal surfaces get a screen name instead of RootWidget', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) =>
                        const AlertDialog(content: Text('confirm payment')),
                  ),
                  child: const Text('open'),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
    // No *Screen widget: base app should not report RootWidget uselessly —
    // it is a plain MaterialApp home, so this stays generic.
    final runtime = FlutterScoutHelper.debugRuntime;

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final dialogScreen = runtime.debugSnapshot().screen;
    expect(dialogScreen, isNot('RootWidget'));
    expect(dialogScreen, 'Dialog');
  });

  testWidgets('custom modal over a ModalBarrier is detected and named', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showGeneralDialog<void>(
                  context: context,
                  barrierDismissible: true,
                  barrierLabel: 'x',
                  // Custom modal content: a plain Container, NOT a Dialog.
                  pageBuilder: (context, animation, secondary) =>
                      const _AnnouncementPanel(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final snapshot = FlutterScoutHelper.debugRuntime.debugSnapshot();
    // Screen names the modal (content class) instead of the base home.
    expect(snapshot.screen, isNot('RootWidget'));
    expect(snapshot.screen, anyOf('_AnnouncementPanel', 'Modal'));
    // A modalBarrier overlay is reported so agents know a scrim is up.
    expect(snapshot.overlays.any((o) => o['kind'] == 'modalBarrier'), isTrue);
  });

  testWidgets('page-suffixed widgets are detected as the screen', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(const MaterialApp(home: _CheckoutPage()));
    await tester.pump();
    expect(
      FlutterScoutHelper.debugRuntime.debugSnapshot().screen,
      '_CheckoutPage',
    );
  });

  testWidgets('dismiss finds a close control on a custom overlay', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Center(child: Text('base')),
              // A custom overlay panel with its own close (xmark) in the header.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 60,
                child: Row(
                  children: [
                    IconButton(icon: const Icon(Icons.close), onPressed: () {}),
                    const Text('Panel'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(FlutterScoutHelper.debugRuntime.debugCloseControlId(), 'btn.close');
  });

  testWidgets('tap-text suggestions surface near matches', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Text('Save Supplier'),
              Text('Delete Supplier'),
              Text('Checkout'),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final runtime = FlutterScoutHelper.debugRuntime;
    final suggestions = runtime.debugTextSuggestions('save supplier now');
    expect(suggestions.first, 'Save Supplier');
    expect(runtime.debugTextSuggestions('zzz-no-match'), isEmpty);
  });

  testWidgets('list cell borrows its label even when text is not hittable', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 80,
            // Opaque tappable ON TOP of the label — the label is inside it but
            // not itself hit-testable (the card's gesture wins the hit test).
            child: Stack(
              children: [
                const Center(child: Text('Prenatal Bliss Massage')),
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final ids = FlutterScoutHelper.debugRuntime
        .debugSnapshot()
        .interactables
        .map((node) => node.id)
        .toList();
    // The cell borrows its content label instead of staying anonymous.
    expect(ids, contains('tap.prenatal_bliss_massage'));
    expect(ids.where((id) => id.startsWith('tap.gesturedetector')), isEmpty);
  });

  testWidgets('anonymous gesture detector over a labeled control is dropped', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              // A labeled button wrapped in an anonymous GestureDetector
              // (a very common pattern) — the wrapper is noise.
              GestureDetector(
                onTap: () {},
                behavior: HitTestBehavior.opaque,
                child: ElevatedButton(
                  onPressed: () {},
                  child: const Text('Confirm'),
                ),
              ),
              // A standalone anonymous gesture area (no labeled sibling) must
              // survive — it may be a real invisible hit target.
              GestureDetector(
                onTap: () {},
                behavior: HitTestBehavior.opaque,
                child: const SizedBox(width: 200, height: 80),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final ids = FlutterScoutHelper.debugRuntime
        .debugSnapshot()
        .interactables
        .map((node) => node.id)
        .toList();
    expect(ids, contains('btn.confirm'));
    // The wrapper over the labeled button is gone; the standalone one stays.
    final anonymous = ids.where((id) => id.startsWith('tap.gesturedetector'));
    expect(anonymous.length, 1);
  });

  testWidgets('small keyed handle records its enclosing tappable', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            key: const ValueKey('order_row'),
            onTap: () {},
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 400,
              height: 90,
              child: Row(
                children: [
                  // A small keyed tappable (avatar) inside the whole row.
                  GestureDetector(
                    key: const ValueKey('order_avatar'),
                    onTap: () {},
                    child: const SizedBox(width: 48, height: 48),
                  ),
                  const Text('Tyuyu'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final snapshot = FlutterScoutHelper.debugRuntime.debugSnapshot();
    final avatar = snapshot.interactables.firstWhere(
      (node) => node.id == 'tap.order_avatar',
    );
    expect(avatar.enclosingTarget, 'tap.order_row');
    // The big row itself has nothing larger enclosing it.
    final row = snapshot.interactables.firstWhere(
      (node) => node.id == 'tap.order_row',
    );
    expect(row.enclosingTarget, isNull);
  });

  testWidgets('altIds keep alternate handles resolving', (tester) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CupertinoButton(
            onPressed: () {},
            // Primary label comes from the (possibly async-loaded, volatile)
            // accessibility label; the icon-derived handle must remain an
            // alternate so yesterday's id still resolves.
            child: Semantics(
              label: 'khor lim',
              child: const Icon(Icons.settings),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final snapshot = FlutterScoutHelper.debugRuntime.debugSnapshot();
    final node = snapshot.interactables.firstWhere(
      (node) => node.id == 'btn.khor_lim',
    );
    expect(node.altIds, contains('btn.settings'));
    // Both the volatile primary and the stable alternate resolve the node.
    expect(snapshot.findNode('btn.khor_lim')?.id, node.id);
    expect(snapshot.findNode('btn.settings')?.id, node.id);
    // Kind-prefix-agnostic matching works for alternates too.
    expect(snapshot.findNode('settings')?.id, node.id);
  });

  testWidgets('set-of-marks suppresses overlapping badges and filters', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              // Two controls stacked at the SAME top-left: only one badge fits.
              Positioned(
                left: 10,
                top: 10,
                child: ElevatedButton(
                  onPressed: () {},
                  child: const Text('OnTop'),
                ),
              ),
              const Positioned(
                left: 12,
                top: 12,
                width: 60,
                height: 30,
                child: TextField(),
              ),
              // A well-separated button.
              Positioned(
                left: 300,
                top: 300,
                child: ElevatedButton(
                  onPressed: () {},
                  child: const Text('FarAway'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final runtime = FlutterScoutHelper.debugRuntime;

    final all = runtime.debugCaptureMarks();
    // The two co-located controls collapse to one badge; the far one stays.
    expect(all.omitted, greaterThanOrEqualTo(1));
    expect(all.legend.length, lessThan(3));

    final buttonsOnly = runtime.debugCaptureMarks(filter: 'buttons');
    expect(buttonsOnly.legend.every((mark) => mark['kind'] == 'btn'), isTrue);
    final fieldsOnly = runtime.debugCaptureMarks(filter: 'fields');
    expect(fieldsOnly.legend.every((mark) => mark['kind'] == 'field'), isTrue);
  });

  testWidgets('set-of-marks capture composites numbered marks onto the PNG', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ElevatedButton(onPressed: () {}, child: const Text('Go')),
          ),
        ),
      ),
    );
    await tester.pump();

    final runtime = FlutterScoutHelper.debugRuntime;
    final node = runtime.debugSnapshot().interactables.firstWhere(
      (node) => node.id == 'btn.go',
    );
    final plain = await tester.runAsync(() => runtime.debugCaptureRegion());
    final marked = await tester.runAsync(
      () =>
          runtime.debugCaptureRegion(marks: [(n: 1, rect: node.visibleRect!)]),
    );
    expect(marked, isNotNull);
    // Valid PNG with the mark overlay baked in (different bytes than plain).
    expect(marked!.sublist(0, 4), equals(<int>[0x89, 0x50, 0x4E, 0x47]));
    expect(marked, isNot(equals(plain)));
  });

  testWidgets(
    'deferred-frame drain completes a route animation without vsync',
    (tester) async {
      FlutterScoutHelper.ensureRegistered();
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: Center(child: Text('page one'))),
        ),
      );
      await tester.pump();

      // Background the window: the embedder stops delivering vsync, so the
      // route transition below would freeze at its first frame forever.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
      expect(tester.binding.framesEnabled, isFalse);

      navKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Center(child: Text('page two'))),
        ),
      );

      final runtime = FlutterScoutHelper.debugRuntime;
      // One clock-frozen pump is NOT enough — the transition needs elapsed
      // time. The drain fabricates an advancing clock until it settles.
      await tester.runAsync(() => runtime.debugDrainDeferredFrames());

      final snapshot = runtime.debugSnapshot();
      expect(snapshot.visibleText, contains('page two'));
      // Transition fully completed: no tickers left animating.
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}

class _CheckoutPage extends StatelessWidget {
  const _CheckoutPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('Checkout')));
  }
}

class _AnnouncementPanel extends StatelessWidget {
  const _AnnouncementPanel();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 300,
        height: 200,
        color: const Color(0xFFFFFFFF),
        child: const Text('Announcement body'),
      ),
    );
  }
}
