import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'snapshot reports observed viewport metrics and both coordinate spaces',
    (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.padding = const FakeViewPadding(top: 90, bottom: 60);
      tester.view.viewPadding = const FakeViewPadding(top: 120, bottom: 90);
      tester.view.viewInsets = const FakeViewPadding(bottom: 600);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: _SnapshotTruthScreen()));
      await tester.pump();

      final snapshot = FlutterScoutRuntime().debugSnapshot();
      expect(snapshot.viewMetricsAvailable, isTrue);
      expect(snapshot.devicePixelRatio, 3);
      expect(snapshot.logicalSize, const Size(400, 800));
      expect(snapshot.physicalSize, const Size(1200, 2400));
      expect(snapshot.padding, const EdgeInsets.only(top: 30, bottom: 20));
      expect(snapshot.viewPadding, const EdgeInsets.only(top: 40, bottom: 30));
      expect(snapshot.viewInsets, const EdgeInsets.only(bottom: 200));

      final viewport = snapshot.viewportJson();
      expect(viewport['available'], isTrue);
      expect(viewport['orientation'], 'portrait');
      expect(viewport['logicalSize'], <double>[400, 800]);
      expect(viewport['physicalSize'], <double>[1200, 2400]);
      expect(viewport['logicalToPhysicalScale'], 3);
      expect(viewport['physicalToLogicalScale'], closeTo(1 / 3, 0.000001));
      expect(viewport['padding'], <double>[0, 30, 0, 20]);
      expect(viewport['viewPadding'], <double>[0, 40, 0, 30]);
      expect(viewport['viewInsets'], <double>[0, 0, 0, 200]);

      final payload = snapshot.toJson();
      expect(
        payload['keyboard'],
        containsPair('source', 'flutter_view_metrics'),
      );
      expect(payload['keyboard'], containsPair('visible', true));
      expect(payload['keyboard'], containsPair('logicalInsetBottom', 200));

      final button = snapshot.findNode('btn.save')!;
      final node = button.toJson();
      final logicalRect = (node['rect']! as List).cast<num>();
      final physicalRect = (node['physicalRect']! as List).cast<num>();
      for (var index = 0; index < logicalRect.length; index++) {
        expect(physicalRect[index], closeTo(logicalRect[index] * 3, 0.000001));
      }
      final logicalTap = (node['suggestedTapPoint']! as List).cast<num>();
      final physicalTap = (node['physicalSuggestedTapPoint']! as List)
          .cast<num>();
      expect(physicalTap[0], closeTo(logicalTap[0] * 3, 0.000001));
      expect(physicalTap[1], closeTo(logicalTap[1] * 3, 0.000001));
      expect(node.containsKey('confidence'), isFalse);
      expect(node['heuristicScore'], isA<double>());
      expect(node['scoreKind'], 'uncalibrated_heuristic');
    },
  );

  testWidgets('screen names carry explicit inference provenance', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: _SnapshotTruthScreen()));
    await tester.pump();

    final snapshot = FlutterScoutRuntime().debugSnapshot();
    expect(snapshot.screen, '_SnapshotTruthScreen');
    expect(snapshot.screenEvidence['kind'], 'heuristic_inference');
    expect(snapshot.screenEvidence['source'], 'widget_ancestry');
    expect(snapshot.screenEvidence['scoreKind'], 'uncalibrated_heuristic');
    expect(snapshot.summaryJson()['screenEvidence'], snapshot.screenEvidence);

    final brief = FlutterScoutRuntime().debugInspectPayload(brief: true);
    expect(brief['screenEvidence'], isA<Map<String, Object?>>());
    expect(
      (brief['screenEvidence']! as Map)['kind'],
      isNot('observed'),
      reason: 'widget runtime-type inference must not look authoritative',
    );
  });

  testWidgets('landscape viewport preserves asymmetric insets and scaling', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(1800, 1000);
    tester.view.padding = const FakeViewPadding(
      left: 40,
      top: 20,
      right: 60,
      bottom: 80,
    );
    tester.view.viewPadding = const FakeViewPadding(
      left: 50,
      top: 30,
      right: 70,
      bottom: 90,
    );
    tester.view.viewInsets = const FakeViewPadding(
      left: 10,
      top: 12,
      right: 14,
      bottom: 200,
    );
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: _SnapshotTruthScreen()));
    await tester.pump();

    final viewport = FlutterScoutRuntime().debugSnapshot().viewportJson();
    expect(viewport['orientation'], 'landscape');
    expect(viewport['logicalSize'], <double>[900, 500]);
    expect(viewport['physicalSize'], <double>[1800, 1000]);
    expect(viewport['padding'], <double>[20, 10, 30, 40]);
    expect(viewport['viewPadding'], <double>[25, 15, 35, 45]);
    expect(viewport['viewInsets'], <double>[5, 6, 7, 100]);
    expect(viewport['safeArea'], <String, Object?>{
      'left': 20.0,
      'top': 10.0,
      'right': 30.0,
      'bottom': 40.0,
    });
    expect((viewport['windowScaling']! as Map)['status'], 'observed');
    expect((viewport['windowScaling']! as Map)['logicalToPhysical'], 2);
  });
}

class _SnapshotTruthScreen extends StatelessWidget {
  const _SnapshotTruthScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(onPressed: _noop, child: const Text('Save')),
      ),
    );
  }

  static void _noop() {}
}
