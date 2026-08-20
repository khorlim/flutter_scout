import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

import 'seeded_property_support.dart';

void main() {
  const file = 'snapshot_state_property_fuzz_test.dart';
  const geometryCampaign =
      'seeded non-finite and viewport-clipped geometry stays locally isolated';
  const stateCampaign =
      'state generation and digest ignore observation projections and ordering';
  const idempotencyCampaign =
      'idempotency canonicalization ignores map order and retry-only fields';

  testWidgets(geometryCampaign, (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(1000, 1400);
    addTearDown(tester.view.reset);
    final seed = fuzzSeed(0x6e0f17);
    final runtime = FlutterScoutRuntime();

    for (final caseIndex in fuzzCases(16)) {
      final random = fuzzRandom(seed, caseIndex);
      final invalid = caseIndex.isEven ? double.nan : double.infinity;
      final children = <Widget>[
        const Positioned(
          left: -25,
          top: 20,
          width: 100,
          height: 44,
          child: ElevatedButton(
            key: ValueKey<String>('partial-sentinel'),
            onPressed: _noop,
            child: Text('Partial sentinel'),
          ),
        ),
        const Positioned(
          left: 180,
          top: 20,
          width: 150,
          height: 44,
          child: ElevatedButton(
            key: ValueKey<String>('finite-sentinel'),
            onPressed: _noop,
            child: Text('Finite sentinel'),
          ),
        ),
        for (var index = 0; index < 18; index += 1)
          Positioned(
            left: -160 + random.nextDouble() * 800,
            top: -120 + random.nextDouble() * 980,
            width: 30 + random.nextDouble() * 150,
            height: 24 + random.nextDouble() * 70,
            child: ElevatedButton(
              key: ValueKey<String>('finite-$caseIndex-$index'),
              onPressed: _noop,
              child: Text('F$index'),
            ),
          ),
        Positioned(
          left: 20,
          top: 100,
          child: ExcludeSemantics(
            child: Transform(
              transform: Matrix4.identity()..setEntry(0, 0, invalid),
              child: ElevatedButton(
                key: ValueKey<String>('invalid-$caseIndex'),
                onPressed: _noop,
                child: const Text('Invalid geometry'),
              ),
            ),
          ),
        ),
      ]..shuffle(random);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(clipBehavior: Clip.hardEdge, children: children),
          ),
        ),
      );
      await tester.pump();

      final context = fuzzReplay(
        file: file,
        seed: seed,
        caseIndex: caseIndex,
        testName: geometryCampaign,
      );
      final snapshot = runtime.debugSnapshot();
      expect(
        snapshot.interactables.any((node) => node.key == 'finite-sentinel'),
        isTrue,
        reason: context,
      );
      expect(
        snapshot.interactables.any((node) => node.key == 'invalid-$caseIndex'),
        isFalse,
        reason: context,
      );
      final partial = snapshot.interactables.singleWhere(
        (node) => node.key == 'partial-sentinel',
      );
      expect(
        partial.visibleFraction,
        allOf(greaterThan(0), lessThan(1)),
        reason: context,
      );
      for (final node in <ScoutNode>[
        ...snapshot.interactables,
        ...snapshot.fields,
        ...snapshot.textTargets,
      ]) {
        expect(node.visibleFraction.isFinite, isTrue, reason: context);
        expect(
          node.visibleFraction,
          inInclusiveRange(0.0, 1.0),
          reason: context,
        );
        expect(node.rect?.isFinite ?? true, isTrue, reason: context);
        expect(node.visibleRect?.isFinite ?? true, isTrue, reason: context);
        final visible = node.visibleRect;
        if (visible != null) {
          expect(visible.left, greaterThanOrEqualTo(0), reason: context);
          expect(visible.top, greaterThanOrEqualTo(0), reason: context);
          expect(
            visible.right,
            lessThanOrEqualTo(snapshot.logicalSize.width),
            reason: context,
          );
          expect(
            visible.bottom,
            lessThanOrEqualTo(snapshot.logicalSize.height),
            reason: context,
          );
        }
      }
      _expectFiniteTree(snapshot.toJson(), context);
      expect(
        () => jsonEncode(snapshot.toJson()),
        returnsNormally,
        reason: context,
      );
    }
  });

  testWidgets(stateCampaign, (tester) async {
    final seed = fuzzSeed(0x57a7e1d);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              Text('Stable state'),
              ElevatedButton(onPressed: _noop, child: Text('Continue')),
              TextField(decoration: InputDecoration(labelText: 'Reference')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final runtime = FlutterScoutRuntime();
    final baseline = runtime.debugSnapshot();
    const availableSections = <String>[
      'text',
      'interactables',
      'fields',
      'textTargets',
      'scrollables',
      'overlays',
      'visualTree',
      'controlGroups',
      'rows',
      'annotations',
    ];

    for (final caseIndex in fuzzCases(64)) {
      final random = fuzzRandom(seed, caseIndex);
      final shuffled = List<String>.of(availableSections)..shuffle(random);
      final sections = <String>{
        for (final section in shuffled.take(random.nextInt(6))) section,
      };
      final payload = runtime.debugInspectPayload(
        brief: random.nextBool(),
        maxItems: 1 + random.nextInt(50),
        sections: sections,
        surfaceOnly: random.nextBool(),
      );
      final observed = runtime.debugSnapshot();
      final context = fuzzReplay(
        file: file,
        seed: seed,
        caseIndex: caseIndex,
        testName: stateCampaign,
      );
      expect(
        payload['stateGeneration'],
        baseline.stateGeneration,
        reason: context,
      );
      expect(payload['stateDigest'], baseline.stateDigest, reason: context);
      expect(
        observed.stateGeneration,
        baseline.stateGeneration,
        reason: context,
      );
      expect(observed.stateDigest, baseline.stateDigest, reason: context);
      expect(observed.snapshotId, baseline.snapshotId, reason: context);
    }
  });

  testWidgets(idempotencyCampaign, (tester) async {
    final seed = fuzzSeed(0x1de07e);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Canonical fixture'))),
    );
    await tester.pump();
    final runtime = FlutterScoutRuntime();
    final baseline = runtime.debugSnapshot();
    var dispatches = 0;
    var expectedDispatches = 0;

    for (final caseIndex in fuzzCases(24)) {
      final random = fuzzRandom(seed, caseIndex);
      final key = 'canonical-$caseIndex';
      final business = <MapEntry<String, String>>[
        MapEntry<String, String>('alpha', 'a-${random.nextInt(1 << 20)}'),
        MapEntry<String, String>('beta', 'b-${random.nextInt(1 << 20)}'),
        MapEntry<String, String>('gamma', 'g-${random.nextInt(1 << 20)}'),
      ];
      final first = <MapEntry<String, String>>[
        ..._mutationEntries(
          runtime,
          generation: baseline.stateGeneration,
          commandId: 'first-$caseIndex',
          idempotencyKey: key,
          errorCursor: caseIndex,
        ),
        ...business,
      ]..shuffle(random);
      final firstResponse = await runtime.debugProtocolMutation(
        Map<String, String>.fromEntries(first),
        () async {
          dispatches += 1;
          return <String, Object?>{
            'activation': const <String, Object?>{'dispatched': true},
            'case': caseIndex,
          };
        },
      );
      expectedDispatches += 1;

      final retryRandom = fuzzRandom(seed ^ 0x777777, caseIndex);
      final retry = <MapEntry<String, String>>[
        ..._mutationEntries(
          runtime,
          generation: baseline.stateGeneration,
          commandId: 'retry-$caseIndex',
          idempotencyKey: key,
          errorCursor: 1000 + caseIndex,
        ),
        ...business.reversed,
      ]..shuffle(retryRandom);
      final retryResponse = await runtime.debugProtocolMutation(
        Map<String, String>.fromEntries(retry),
        () async {
          dispatches += 1000;
          return const <String, Object?>{'unexpected': true};
        },
      );
      final context = fuzzReplay(
        file: file,
        seed: seed,
        caseIndex: caseIndex,
        testName: idempotencyCampaign,
      );
      expect(firstResponse['ok'], isTrue, reason: context);
      expect(retryResponse, firstResponse, reason: context);
      expect(dispatches, expectedDispatches, reason: context);
      final observed = runtime.debugSnapshot();
      expect(
        observed.stateGeneration,
        baseline.stateGeneration,
        reason: context,
      );
      expect(observed.stateDigest, baseline.stateDigest, reason: context);
    }
  });
}

List<MapEntry<String, String>> _mutationEntries(
  FlutterScoutRuntime runtime, {
  required int generation,
  required String commandId,
  required String idempotencyKey,
  required int errorCursor,
}) => <MapEntry<String, String>>[
  const MapEntry<String, String>('schemaVersion', '1'),
  const MapEntry<String, String>('clientProtocolMin', '15'),
  const MapEntry<String, String>('clientProtocolMax', '15'),
  MapEntry<String, String>('commandId', commandId),
  MapEntry<String, String>('idempotencyKey', idempotencyKey),
  const MapEntry<String, String>('runId', 'property-run'),
  MapEntry<String, String>('runtimeInstanceId', runtime.debugRuntimeInstanceId),
  MapEntry<String, String>('expectedStateGeneration', '$generation'),
  MapEntry<String, String>(
    'deadlineEpochMs',
    '${DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch}',
  ),
  MapEntry<String, String>('errorCursor', '$errorCursor'),
];

void _expectFiniteTree(Object? value, String context) {
  if (value is double) {
    expect(value.isFinite, isTrue, reason: context);
    return;
  }
  if (value is Map) {
    for (final entry in value.entries) {
      _expectFiniteTree(entry.key, context);
      _expectFiniteTree(entry.value, context);
    }
    return;
  }
  if (value is Iterable) {
    for (final item in value) {
      _expectFiniteTree(item, context);
    }
  }
}

void _noop() {}
