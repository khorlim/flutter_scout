import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'inspect discloses custom-paint, texture, platform-view, and image gaps',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(800, 1600);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                CustomPaint(
                  size: const Size(80, 50),
                  painter: _NoSemanticsPainter(),
                ),
                const SizedBox(
                  width: 90,
                  height: 50,
                  child: Texture(textureId: 7),
                ),
                const SizedBox(
                  width: 100,
                  height: 50,
                  child: _FakePlatformViewSurface(),
                ),
                SizedBox(
                  width: 70,
                  height: 50,
                  child: Image.memory(
                    base64Decode(
                      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL+WQAAAABJRU5ErkJggg==',
                    ),
                    fit: BoxFit.fill,
                  ),
                ),
                const Text('healthy widget-tree evidence'),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final snapshot = FlutterScoutRuntime().debugSnapshot();
      expect(snapshot.visibleText, contains('healthy widget-tree evidence'));
      final byKind = <String, Map<String, Object?>>{
        for (final gap in snapshot.perceptionGaps) gap['kind']! as String: gap,
      };
      expect(byKind, contains('custom_paint_pixels_unobserved'));
      expect(byKind, contains('texture_pixels_unobserved'));
      expect(byKind, contains('platform_view_pixels_unobserved'));
      expect(byKind, contains('image_pixels_unobserved'));

      final custom = byKind['custom_paint_pixels_unobserved']!;
      expect(custom['evidenceKind'], 'observed_limitation');
      expect(
        (custom['semantics']! as Map)['status'],
        'unsupported_by_widget_semantics',
      );
      expect(
        (custom['recommendation']! as Map)['suggestedCommand'],
        startsWith('flutter-scout crop --rect '),
      );
      expect(
        (custom['recommendation']! as Map)['nativeCaptureRequired'],
        isFalse,
      );

      for (final kind in <String>[
        'texture_pixels_unobserved',
        'platform_view_pixels_unobserved',
      ]) {
        final recommendation = byKind[kind]!['recommendation']! as Map;
        expect(recommendation['nativeCaptureRequired'], isTrue);
        expect(recommendation['suggestedCommand'], contains('--native'));
      }

      final geometry = custom['geometry']! as Map<String, Object?>;
      final logical = (geometry['logicalBounds']! as List).cast<num>();
      final physical = (geometry['physicalBounds']! as List).cast<num>();
      for (var index = 0; index < logical.length; index++) {
        expect(physical[index], closeTo(logical[index] * 2, 0.000001));
      }

      final perception = snapshot.perceptionJson();
      expect((perception['visual']! as Map)['status'], 'known_perception_gaps');
      expect(perception['limitations'], isNotEmpty);
      expect(
        (snapshot.summaryJson()['perception']! as Map)['limitations'],
        isNotEmpty,
      );
      expect(snapshot.captureBackend['status'], 'available');
      expect(
        (snapshot.captureBackend['coverage']! as Map)['platformViewPixels'],
        'unsupported',
      );
      expect(
        (snapshot.captureBackend['nativeFallback']! as Map)['status'],
        'not_observable_by_helper',
      );

      final brief = FlutterScoutRuntime().debugInspectPayload(brief: true);
      final compactPerception = brief['perception']! as Map;
      expect(compactPerception['visualStatus'], 'known_perception_gaps');
      expect(
        compactPerception['limitationCount'],
        greaterThanOrEqualTo(byKind.length),
      );
      expect(
        (compactPerception['limitationKinds']! as List).cast<String>(),
        containsAll(byKind.keys),
      );
      expect(compactPerception.containsKey('limitations'), isFalse);
      expect(compactPerception['recoverWith'], 'inspect --sections perception');
    },
  );

  testWidgets('a malformed element yields a scoped limitation, not blindness', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    runtime.debugSnapshotNodeProbe = (element) {
      if (element.widget is FlutterLogo) {
        throw StateError('injected malformed element');
      }
    };
    addTearDown(() => runtime.debugSnapshotNodeProbe = null);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [Text('healthy sibling'), FlutterLogo(size: 48)],
          ),
        ),
      ),
    );
    await tester.pump();

    final snapshot = runtime.debugSnapshot();
    expect(snapshot.visibleText, contains('healthy sibling'));
    expect(snapshot.degradedNodes, 1);
    final limitation = snapshot.perceptionGaps.firstWhere(
      (gap) => gap['kind'] == 'element_observation_failed',
    );
    expect(limitation['status'], 'observation_unavailable');
    expect(limitation['isolation'], 'affected_element_only');
    expect(
      limitation['affectedEvidence'],
      containsAll(<String>['semantics', 'geometry', 'interaction_metadata']),
    );
    expect(
      (snapshot.perceptionJson()['coverage']! as Map)['widgetTree'],
      'observed_with_local_degradation',
    );
  });

  testWidgets('a malformed semantics node loses only semantics evidence', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    runtime.debugSnapshotNodeProbe = (element) {
      final widget = element.widget;
      if (widget is Semantics &&
          widget.properties.label == 'malformed semantic wrapper') {
        throw StateError('injected malformed semantics node');
      }
    };
    addTearDown(() => runtime.debugSnapshotNodeProbe = null);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Semantics(
                label: 'malformed semantic wrapper',
                child: const Text('semantic child remains observable'),
              ),
              ElevatedButton(
                key: const ValueKey('healthy_action'),
                onPressed: () {},
                child: const Text('Healthy action'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final snapshot = runtime.debugSnapshot();
    expect(
      snapshot.visibleText,
      containsAll(<String>[
        'semantic child remains observable',
        'Healthy action',
      ]),
    );
    expect(
      snapshot.interactables.map((node) => node.id),
      contains('btn.healthy_action'),
    );
    final limitation = snapshot.perceptionGaps.firstWhere(
      (gap) => gap['kind'] == 'semantics_node_observation_failed',
    );
    expect(limitation['status'], 'observation_unavailable');
    expect(limitation['source'], 'flutter_semantics_widget_probe');
    expect(limitation['affectedEvidence'], const <String>[
      'semantics_label_and_state',
    ]);
    expect(limitation['isolation'], 'affected_semantics_node_only');
    expect(snapshot.degradedNodes, 1);
  });

  testWidgets('perception gap geometry reports ancestor clipping', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 40,
              height: 30,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: 100,
                  maxWidth: 100,
                  minHeight: 80,
                  maxHeight: 80,
                  child: CustomPaint(
                    size: const Size(100, 80),
                    painter: _NoSemanticsPainter(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final gap = FlutterScoutRuntime().debugSnapshot().perceptionGaps.firstWhere(
      (candidate) =>
          candidate['kind'] == 'custom_paint_pixels_unobserved' &&
          (candidate['painterTypes']! as List).contains('_NoSemanticsPainter'),
    );
    final geometry = gap['geometry']! as Map;
    expect((geometry['logicalBounds']! as List)[2], 100);
    expect((geometry['logicalBounds']! as List)[3], 80);
    expect((geometry['visibleLogicalBounds']! as List)[2], 40);
    expect((geometry['visibleLogicalBounds']! as List)[3], 30);
    expect(geometry['visibleFraction'], closeTo(0.15, 0.000001));
    expect(geometry['clipped'], isTrue);
    expect(
      (geometry['visibilityEvidence']! as Map)['occlusion'],
      'not_directly_measured_for_visual_region',
    );
  });

  testWidgets('visible ErrorWidget is signalled without copying diagnostics', (
    tester,
  ) async {
    const diagnosticSecret = 'customer-token-should-not-enter-gap';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                height: 100,
                child: ClipRect(child: ErrorWidget(diagnosticSecret)),
              ),
              const Text('healthy sibling remains observable'),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final runtime = FlutterScoutRuntime();
    final snapshot = runtime.debugSnapshot();
    final limitation = snapshot.perceptionGaps.firstWhere(
      (gap) => gap['kind'] == 'flutter_error_widget_visible',
    );
    expect(limitation['status'], 'observed_blocking_error_surface');
    expect(
      (limitation['recommendation']! as Map)['action'],
      'inspect_runtime_errors',
    );
    expect(jsonEncode(limitation), isNot(contains(diagnosticSecret)));
    expect(snapshot.visibleText, isNot(contains(diagnosticSecret)));
    expect(
      snapshot.visibleText,
      contains('healthy sibling remains observable'),
    );
    expect(
      jsonEncode(runtime.debugInspectPayload()),
      isNot(contains(diagnosticSecret)),
    );
  });

  testWidgets('unavailable capture evidence remains explicit and local', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    runtime.debugCaptureBackendProbe = () {
      throw StateError('injected capture backend failure');
    };
    addTearDown(() => runtime.debugCaptureBackendProbe = null);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('tree still observable'))),
    );
    await tester.pump();
    final degraded = runtime.debugSnapshot();

    expect(degraded.visibleText, contains('tree still observable'));
    final perception = degraded.perceptionJson();
    expect(
      (perception['coverage']! as Map)['focusedPixelCapture'],
      'observation_unavailable',
    );
    expect(
      (perception['captureBackend']! as Map)['reason'],
      'capture_backend_probe_failed',
    );
    expect(
      (perception['limitations']! as List).cast<Map>().any(
        (gap) => gap['kind'] == 'capture_backend_unavailable',
      ),
      isTrue,
    );
  });

  testWidgets(
    'opaque platform-view region requests native capture without pixel claims',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 120,
              height: 80,
              child: _FakePlatformViewSurface(),
            ),
          ),
        ),
      );
      await tester.pump();

      final runtime = FlutterScoutRuntime();
      final snapshot = runtime.debugSnapshot();
      final limitation = snapshot.perceptionGaps.firstWhere(
        (gap) => gap['kind'] == 'platform_view_pixels_unobserved',
      );
      expect(limitation['evidenceKind'], 'observed_limitation');
      expect(limitation['status'], 'unsupported_by_in_app_raster_capture');
      expect(
        limitation['limitation'],
        contains('not its opaque native pixels or meaning'),
      );
      expect(
        (limitation['recommendation']! as Map)['nativeCaptureRequired'],
        isTrue,
      );

      final payload = await tester.runAsync(runtime.debugActionCapturePayload);
      expect(payload, isNotNull);
      final capture = payload!['capture']! as Map;
      expect(capture['ok'], isTrue);
      expect(capture['backend'], 'in_app_capture');
      expect(capture['needsNative'], isTrue);
    },
  );

  testWidgets('scroll metrics degrade without inventing dimensions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 120,
            child: Scrollable(
              key: const ValueKey('dimensionless'),
              axisDirection: AxisDirection.down,
              viewportBuilder: (_, _) => const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final region = FlutterScoutRuntime().debugSnapshot().scrollables.firstWhere(
      (candidate) => candidate['id'] == 'scroll.dimensionless',
    );
    final evidence = region['positionEvidence']! as Map;
    expect((region['identity']! as Map)['source'], 'flutter_value_key');
    expect((region['keyEvidence']! as Map)['source'], 'scrollable_value_key');
    expect(evidence['status'], isNot('observed'));
    expect(evidence['reason'], isNotNull);
    expect(region['metricsAvailable'], isFalse);
    expect(region['approximateNormalizedPosition'], isNull);
    expect(
      (region['normalizedPositionEvidence']! as Map)['status'],
      'observation_unavailable',
    );
  });

  testWidgets(
    'nested scroll regions expose scoped identity, metrics, and both spaces',
    (tester) async {
      tester.view.devicePixelRatio = 2.5;
      tester.view.physicalSize = const Size(1000, 2000);
      addTearDown(tester.view.reset);
      final outerController = ScrollController(initialScrollOffset: 80);
      final innerController = ScrollController(initialScrollOffset: 45);
      addTearDown(outerController.dispose);
      addTearDown(innerController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              key: const ValueKey('outer_feed'),
              controller: outerController,
              children: [
                const SizedBox(height: 160, child: Text('outer header')),
                SizedBox(
                  height: 150,
                  child: ListView.builder(
                    key: const ValueKey('inner_carousel'),
                    controller: innerController,
                    scrollDirection: Axis.horizontal,
                    itemCount: 20,
                    itemBuilder: (_, index) =>
                        SizedBox(width: 100, child: Text('card $index')),
                  ),
                ),
                for (var index = 0; index < 30; index++)
                  SizedBox(height: 60, child: Text('outer row $index')),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      var snapshot = FlutterScoutRuntime().debugSnapshot();
      final outer = snapshot.scrollables.firstWhere(
        (region) => region['id'] == 'scroll.outer_feed',
      );
      final inner = snapshot.scrollables.firstWhere(
        (region) => region['id'] == 'scroll.inner_carousel',
      );

      expect(outer['axis'], 'vertical');
      expect(outer['axisDirection'], 'down');
      expect(outer['nestingDepth'], 0);
      expect(outer['parentId'], isNull);
      expect(outer['scopePath'], <String>['scroll.outer_feed']);
      expect(outer['pixels'], closeTo(80, 0.01));
      expect(outer['minScrollExtent'], 0);
      expect(outer['maxScrollExtent'], greaterThan(80));
      expect(outer['extentBefore'], closeTo(80, 0.01));
      expect(outer['extentAfter'], greaterThan(0));
      expect(outer['atStart'], isFalse);
      expect(outer['atEnd'], isFalse);
      expect(outer['positionAvailable'], isTrue);
      expect(
        (outer['visibilityEvidence']! as Map)['visibleFractionMeaning'],
        'geometric_clip_exposure_only',
      );
      expect((outer['positionEvidence']! as Map)['status'], 'observed');
      expect(
        (outer['normalizedPositionEvidence']! as Map)['status'],
        'derived_observation',
      );

      expect(inner['axis'], 'horizontal');
      expect(inner['axisDirection'], 'right');
      expect(inner['nestingDepth'], 1);
      expect(inner['parentId'], 'scroll.outer_feed');
      expect(inner['scopePath'], <String>[
        'scroll.outer_feed',
        'scroll.inner_carousel',
      ]);
      expect(inner['pixels'], closeTo(45, 0.01));
      expect(
        (inner['identity']! as Map)['source'],
        'nearest_ancestor_value_key_and_snapshot_occurrence',
      );
      expect(
        (inner['identity']! as Map)['stability'],
        'ancestor_scope_derived_snapshot_local',
      );
      expect(inner['scopedId'], 'scroll.outer_feed/scroll.inner_carousel');

      final logical = (inner['logicalBounds']! as List).cast<num>();
      final physical = (inner['physicalBounds']! as List).cast<num>();
      for (var index = 0; index < logical.length; index++) {
        expect(physical[index], closeTo(logical[index] * 2.5, 0.000001));
      }
      expect(
        (inner['viewport']! as Map)['axisDimension'],
        inner['viewportDimension'],
      );
      expect(inner['approximateNormalizedPosition'], inInclusiveRange(0, 1));

      final brief = FlutterScoutRuntime().debugInspectPayload(brief: true);
      final compactInner = (brief['scrollables']! as List)
          .cast<Map<String, Object?>>()
          .firstWhere((region) => region['id'] == 'scroll.inner_carousel');
      expect(compactInner['parentId'], 'scroll.outer_feed');
      expect(
        compactInner['scopedId'],
        'scroll.outer_feed/scroll.inner_carousel',
      );
      expect(compactInner.containsKey('physicalBounds'), isFalse);
      expect(compactInner.containsKey('positionEvidence'), isFalse);
      expect(compactInner.containsKey('normalizedPositionEvidence'), isFalse);

      innerController.jumpTo(innerController.position.maxScrollExtent);
      await tester.pump();
      snapshot = FlutterScoutRuntime().debugSnapshot();
      final innerAtEnd = snapshot.scrollables.firstWhere(
        (region) => region['id'] == 'scroll.inner_carousel',
      );
      expect(innerAtEnd['atEnd'], isTrue);
      expect(innerAtEnd['approximateNormalizedPosition'], closeTo(1, 0.000001));

      // A lazy sliver may refine maxScrollExtent as new children are laid out.
      // Follow the observed end until its estimate stops moving.
      for (var attempt = 0; attempt < 4; attempt++) {
        outerController.jumpTo(outerController.position.maxScrollExtent);
        await tester.pump();
      }
      snapshot = FlutterScoutRuntime().debugSnapshot();
      final outerAtEnd = snapshot.scrollables.firstWhere(
        (region) => region['id'] == 'scroll.outer_feed',
      );
      expect(outerAtEnd['atEnd'], isTrue);
      expect(outerAtEnd['approximateNormalizedPosition'], closeTo(1, 0.000001));
    },
  );
}

class _NoSemanticsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.blue);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _FakePlatformViewSurface extends LeafRenderObjectWidget {
  const _FakePlatformViewSurface();

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _FakePlatformViewRenderBox();
}

class _FakePlatformViewRenderBox extends RenderBox {
  @override
  void performLayout() {
    size = constraints.constrain(const Size(100, 50));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    context.canvas.drawRect(offset & size, Paint()..color = Colors.black);
  }
}
