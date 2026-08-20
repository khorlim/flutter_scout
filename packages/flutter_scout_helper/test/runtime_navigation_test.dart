import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('where reports orientation, panes, scroll positions, and frame', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      MaterialApp(
        home: DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'First'),
                  Tab(text: 'Second'),
                ],
              ),
            ),
            body: Row(
              children: [
                Expanded(
                  child: ListView(
                    key: const ValueKey('left-pane'),
                    children: const [SizedBox(height: 1000, child: Text('L'))],
                  ),
                ),
                Expanded(
                  child: ListView(
                    key: const ValueKey('right-pane'),
                    children: const [SizedBox(height: 1000, child: Text('R'))],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final response = (await tester.runAsync(runtime.debugWhere))!;
    expect(response['ok'], isTrue);
    expect(response['orientation'], 'where');
    expect(response['screen'], isNotNull);
    expect(response['navigators'], isNotEmpty);
    expect(response['tabSystems'], isNotEmpty);
    expect(response['scrollRegions'], hasLength(2));
    expect(response['panes'], hasLength(2));
    final leftRegion = (response['scrollRegions']! as List)
        .cast<Map<String, Object?>>()
        .firstWhere((region) => region['id'] == 'scroll.left_pane');
    expect(leftRegion['scopedId'], 'scroll.left_pane');
    expect(
      (leftRegion['identity']! as Map)['source'],
      'nearest_ancestor_value_key_and_snapshot_occurrence',
    );
    expect(leftRegion['logicalBounds'], isA<List<Object?>>());
    expect(leftRegion['physicalBounds'], isA<List<Object?>>());
    expect((leftRegion['positionEvidence']! as Map)['status'], 'observed');
    expect(
      (leftRegion['normalizedPositionEvidence']! as Map)['status'],
      'derived_observation',
    );
    final frame = response['coordinateFrame']! as Map;
    expect(frame['primarySpace'], 'logical_flutter_pixels');
    expect(frame['devicePixelRatio'], greaterThan(0));
    final keyboard = response['keyboard']! as Map;
    expect(keyboard['visible'], isFalse);
    expect(response['limitations'], isNotEmpty);
  });

  testWidgets('locate is read-only and abstains on duplicate ranked text', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    var dispatched = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ElevatedButton(
                onPressed: () => dispatched += 1,
                child: const Text('Save'),
              ),
              ElevatedButton(
                onPressed: () => dispatched += 1,
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final response = (await tester.runAsync(
      () => runtime.debugLocate(const {'text': 'Save'}),
    ))!;
    expect(response['ok'], isFalse);
    expect(response['readOnly'], isTrue);
    expect(response['stoppingReason'], 'ambiguous');
    final bounds = response['bounds']! as Map;
    expect(bounds['actions'], 0);
    expect(bounds['distance'], 0);
    final coordinateFrame = response['coordinateFrame']! as Map;
    expect(coordinateFrame['origin'], 'flutter_view_top_left');
    expect(coordinateFrame['viewMetricsAvailable'], isTrue);
    expect(coordinateFrame['physicalViewport'], isA<List<Object?>>());
    expect(coordinateFrame['logicalToPhysicalScale'], greaterThan(0));
    expect(
      coordinateFrame['provenance'],
      'flutter_view_physical_size_and_device_pixel_ratio',
    );
    final resolution = response['resolution']! as Map;
    expect(resolution['status'], 'ambiguous');
    expect(resolution['candidateCount'], 2);
    expect(resolution['candidates'], hasLength(2));
    expect(dispatched, 0);
  });

  testWidgets(
    'reveal requires explicit region, moves only it, and restores on failure',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      final left = ScrollController();
      final right = ScrollController();
      addTearDown(left.dispose);
      addTearDown(right.dispose);

      Widget list({
        required String keyName,
        required String prefix,
        required ScrollController controller,
        bool hasNeedle = false,
      }) {
        return Expanded(
          child: ListView.builder(
            key: ValueKey(keyName),
            controller: controller,
            itemExtent: 60,
            itemCount: 40,
            itemBuilder: (context, index) {
              if (hasNeedle && index == 25) {
                return ElevatedButton(
                  onPressed: () {},
                  child: const Text('Needle'),
                );
              }
              return Text('$prefix $index');
            },
          ),
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                list(
                  keyName: 'left-list',
                  prefix: 'Left',
                  controller: left,
                  hasNeedle: true,
                ),
                list(keyName: 'right-list', prefix: 'Right', controller: right),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      Future<Map<String, Object?>> runReveal(Map<String, String> params) async {
        Map<String, Object?>? result;
        Object? failure;
        var completed = false;
        unawaited(
          runtime
              .debugReveal(params)
              .then(
                (value) {
                  result = value;
                  completed = true;
                },
                onError: (Object error) {
                  failure = error;
                  completed = true;
                },
              ),
        );
        for (var frame = 0; frame < 240 && !completed; frame++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        if (failure != null) throw failure!;
        expect(
          completed,
          isTrue,
          reason: 'reveal exceeded the test frame bound',
        );
        return result!;
      }

      final ambiguous = await runReveal(const {
        'text': 'Needle',
        'direction': 'down',
        'maxActions': '3',
        'distance': '180',
        'timeoutMs': '3000',
      });
      expect(ambiguous['ok'], isFalse);
      expect(ambiguous['stoppingReason'], 'target_ambiguous');
      expect(ambiguous['scrollRegionsAttempted'], isEmpty);
      expect(left.offset, closeTo(0, 0.5));
      expect(right.offset, closeTo(0, 0.5));

      final revealed = await runReveal(const {
        'text': 'Needle',
        'within': 'scroll.left_list',
        'direction': 'down',
        'maxActions': '12',
        'distance': '180',
        'maxDistance': '2200',
        'timeoutMs': '8000',
      });
      expect(revealed['ok'], isTrue, reason: '$revealed');
      expect(revealed['revealed'], isTrue);
      expect(revealed['stoppingReason'], 'target_revealed');
      expect(left.offset, greaterThan(0));
      expect(right.offset, closeTo(0, 0.5));
      final attempts = (revealed['scrollRegionsAttempted']! as List)
          .cast<Map>();
      expect(attempts, isNotEmpty);
      expect(
        attempts.every((attempt) => attempt['regionId'] == 'scroll.left_list'),
        isTrue,
      );
      expect(revealed['progressSignatures'], isNotEmpty);
      expect(revealed['repeatedStateDetected'], isFalse);

      left.jumpTo(0);
      await tester.pump();
      final missing = await runReveal(const {
        'text': 'Does Not Exist',
        'within': 'scroll.left_list',
        'direction': 'down',
        'maxActions': '2',
        'distance': '120',
        'maxDistance': '240',
        'timeoutMs': '4000',
      });
      expect(missing['ok'], isFalse);
      expect(missing['revealed'], isFalse);
      expect(missing['actionsUsed'], 2);
      expect(missing['scrollRegionsAttempted'], hasLength(2));
      final restoration = missing['restoration']! as Map;
      expect(restoration['attempted'], isTrue);
      expect(restoration['result'], 'restored');
      expect(left.offset, closeTo(0, 0.5));
      expect(right.offset, closeTo(0, 0.5));
    },
  );

  testWidgets('inspect since validates identity and returns bounded deltas', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Before state'))),
    );
    await tester.pump();
    final before = runtime.debugSnapshot();

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('After state'))),
    );
    await tester.pump();
    final after = runtime.debugSnapshot();
    expect(after.stateGeneration, greaterThan(before.stateGeneration));

    final delta = (await tester.runAsync(
      () => runtime.debugInspectSince(before.snapshotId),
    ))!;
    expect(delta['ok'], isTrue);
    expect(delta['requestedSnapshotId'], before.snapshotId);
    expect(delta['generationDistance'], greaterThan(0));
    expect(delta['semanticChanged'], isTrue);
    final changes = delta['delta']! as Map;
    expect(changes['newText'], contains('After state'));
    expect(changes['removedText'], contains('Before state'));
    final changedRegions = (changes['changedRegions']! as List).cast<Map>();
    expect(changedRegions, isNotEmpty);
    expect(changedRegions.length, lessThanOrEqualTo(64));
    for (final region in changedRegions) {
      expect(region['logicalRect'], isA<List>());
      expect(region['physicalRect'], isA<List>());
      expect(region['reasons'], isNotEmpty);
      expect(region['geometryProvenance'], isA<Map>());
    }
    final changedRegionCoverage = changes['changedRegionCoverage']! as Map;
    expect(changedRegionCoverage['status'], 'complete');
    expect(changedRegionCoverage['baselineSnapshotId'], before.snapshotId);
    expect(changedRegionCoverage['currentSnapshotId'], after.snapshotId);
    expect(changedRegionCoverage['omittedRegionCount'], 0);
    expect(changedRegionCoverage['ambiguousGeometryCount'], 0);
    expect(changedRegionCoverage['unavailableGeometryCount'], 0);
    expect(
      (delta['baselineScope']! as Map)['runtimeInstanceId'],
      runtime.debugRuntimeInstanceId,
    );

    final capture = (await tester.runAsync(
      () => runtime.debugCaptureChangedSince(before.snapshotId, padding: 8),
    ))!;
    expect(capture['ok'], isTrue, reason: capture.toString());
    expect(capture['operation'], 'capture_changed_region');
    expect(capture['requestedSnapshotId'], before.snapshotId);
    expect((capture['baselineScope']! as Map)['snapshotId'], before.snapshotId);
    expect((capture['currentScope']! as Map)['snapshotId'], after.snapshotId);
    expect(
      (capture['captureVerifiedScope']! as Map)['snapshotId'],
      after.snapshotId,
    );
    expect(capture['backend'], 'in_app_capture');
    expect(capture['captureIdentity'], matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(capture['bytes'], isA<String>());
    expect((capture['bytes']! as String), isNotEmpty);
    final selection = capture['regionSelection']! as Map;
    expect(selection['strategy'], 'bounded_union');
    expect(selection['regionCount'], inInclusiveRange(1, 16));
    expect(selection['paddingLogical'], 8);
    expect(selection['unionAreaRatio'], lessThanOrEqualTo(0.5));
    expect(selection['logicalPaddedRect'], isA<List>());
    expect(selection['physicalPaddedRect'], isA<List>());
    final frame = capture['coordinateFrame']! as Map;
    expect(frame['origin'], 'flutter_view_top_left');
    expect(frame['viewMetricsAvailable'], isTrue);

    final invalid = (await tester.runAsync(
      () => runtime.debugInspectSince('not-a-snapshot'),
    ))!;
    expect((invalid['error']! as Map)['code'], 'invalid_snapshot_id');

    final unavailable = (await tester.runAsync(
      () => runtime.debugInspectSince(
        'g0:${List<String>.filled(64, '0').join()}',
      ),
    ))!;
    expect(
      (unavailable['error']! as Map)['code'],
      'snapshot_history_unavailable',
    );
    expect((unavailable['historyCapacity'] as int), 32);
  });

  testWidgets(
    'changed-region capture restores opted-in Scout chrome before verification',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Overlay before'))),
      );
      runtime.debugSetAnnotationMode(true);
      runtime.debugEnsureOverlayInstalled();
      await tester.pump();
      await tester.pump();
      expect(runtime.debugOverlayInstalled, isTrue);
      final before = runtime.debugSnapshot();

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Overlay after'))),
      );
      await tester.pump();
      final after = runtime.debugSnapshot();

      final captureFuture = runtime.debugCaptureChangedSince(
        before.snapshotId,
        padding: 4,
      );
      // The production engine services the two hide and two restore frames
      // while the VM request is pending. Widget tests must drive those frames
      // explicitly before switching to real async for image byte encoding.
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump();
      }
      final capture = (await tester.runAsync(() => captureFuture))!;

      expect(capture['ok'], isTrue, reason: capture.toString());
      expect(runtime.debugOverlayInstalled, isTrue);
      expect(
        (capture['captureVerifiedScope']! as Map)['snapshotId'],
        after.snapshotId,
      );
      expect(runtime.debugSnapshot().snapshotId, after.snapshotId);
      runtime.debugSetAnnotationMode(false);
      await tester.pump();
    },
  );

  testWidgets('changed-region capture fails closed without a visual delta', (
    tester,
  ) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Unchanged state'))),
    );
    await tester.pump();
    final snapshot = runtime.debugSnapshot();

    final capture = (await tester.runAsync(
      () => runtime.debugCaptureChangedSince(snapshot.snapshotId),
    ))!;

    expect(capture['ok'], isFalse);
    expect(
      (capture['structuredError']! as Map)['code'],
      'changed_region_unavailable',
    );
    expect(capture['bytes'], isNull);
    expect(capture['dispatch'], isNot(equals('dispatched')));
  });

  testWidgets('reveal is classified as a protocol mutation', (tester) async {
    final runtime = FlutterScoutRuntime();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Protocol'))),
    );
    await tester.pump();
    expect(
      runtime.debugIsMutationRequest('ext.flutter_scout.reveal', const {}),
      isTrue,
    );
    expect(
      runtime.debugIsMutationRequest('ext.flutter_scout.inspect', const {
        'navigationAction': 'locate',
      }),
      isFalse,
    );
  });
}
