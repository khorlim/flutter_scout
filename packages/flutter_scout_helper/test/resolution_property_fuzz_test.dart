import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

import 'seeded_property_support.dart';

void main() {
  const file = 'resolution_property_fuzz_test.dart';
  const unicodeCampaign =
      'seeded Unicode selectors remain exact and normalization collisions abstain';
  const duplicateCampaign =
      'seeded duplicate exact key label and alias selectors never dispatch';
  const rankingCampaign =
      'ranked ambiguity is invariant to widget-list permutation';

  testWidgets(unicodeCampaign, (tester) async {
    final seed = fuzzSeed(0x5c017e);
    final labels = <String>[
      'Caf\u00e9',
      'Cafe\u0301',
      '\u0645\u0631\u062d\u0628\u0627',
      '\u4fdd\u5b58',
      '\ud55c\uae00',
      '\ud83d\ude80',
      '\ud83d\udc69\u200d\ud83d\udcbb',
      'na\u00efve',
      'Stra\u00dfe',
      '\u0394\u03bf\u03ba\u03b9\u03bc\u03ae',
      '\u043a\u043d\u043e\u043f\u043a\u0430',
      '\u200fRTL\u200e',
    ];
    final random = Random(seed);
    labels.shuffle(random);
    final keys = <String>[
      for (var index = 0; index < labels.length; index += 1)
        'key-$index-${labels[index]}',
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Wrap(
            children: <Widget>[
              for (var index = 0; index < labels.length; index += 1)
                SizedBox(
                  width: 190,
                  height: 54,
                  child: ElevatedButton(
                    key: ValueKey<String>(keys[index]),
                    onPressed: _noop,
                    child: Text('Case $index ${labels[index]}'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final runtime = FlutterScoutRuntime();
    for (final index in fuzzCases(labels.length)) {
      final context = fuzzReplay(
        file: file,
        seed: seed,
        caseIndex: index,
        testName: unicodeCampaign,
      );
      final snapshot = runtime.debugSnapshot();
      final keyed = snapshot.interactables
          .where((node) => node.key == keys[index])
          .toList(growable: false);
      expect(keyed, hasLength(1), reason: context);
      expect(keyed.single.id, isNotEmpty, reason: context);
      expect(
        runtime.debugResolveTarget(keys[index])['status'],
        'unique',
        reason: context,
      );
      expect(
        runtime.debugResolveTarget('  ${keyed.single.id}  ')['status'],
        'unique',
        reason: context,
      );
      expect(
        runtime.debugResolveTarget('Case $index ${labels[index]}')['status'],
        'unique',
        reason: context,
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              for (final label in const <String>[
                'Pay-now',
                'Pay now',
                'PAY__NOW',
              ])
                ElevatedButton(onPressed: _noop, child: Text(label)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final collision = runtime.debugResolveTarget('btn.pay_now');
    expect(collision['status'], 'ambiguous', reason: 'seed=$seed');
    expect((collision['candidates']! as List), hasLength(3));
  });

  testWidgets(duplicateCampaign, (tester) async {
    final seed = fuzzSeed(0x0ab57a1);
    final runtime = FlutterScoutRuntime();
    var dispatches = 0;
    for (final caseIndex in fuzzCases(12)) {
      final random = fuzzRandom(seed, caseIndex);
      final duplicateCount = 2 + random.nextInt(4);
      final token = _unicodeToken(random, 3 + random.nextInt(4));
      final duplicateKey = 'duplicate-$caseIndex-$token';
      final duplicateLabel = 'Shared $caseIndex $token';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                for (var index = 0; index < duplicateCount; index += 1)
                  Padding(
                    padding: EdgeInsets.zero,
                    child: IconButton(
                      key: ValueKey<String>(duplicateKey),
                      tooltip: duplicateLabel,
                      onPressed: () => dispatches += 1,
                      icon: const Icon(Icons.save),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final context = fuzzReplay(
        file: file,
        seed: seed,
        caseIndex: caseIndex,
        testName: duplicateCampaign,
      );
      final snapshot = runtime.debugSnapshot();
      final nodes = snapshot.interactables
          .where((node) => node.key == duplicateKey)
          .toList(growable: false);
      expect(nodes, hasLength(duplicateCount), reason: context);
      for (final selector in <String>{
        duplicateKey,
        duplicateLabel,
        nodes.first.baseId,
        'btn.save',
      }) {
        final resolution = runtime.debugResolveTarget(selector);
        expect(resolution['status'], 'ambiguous', reason: '$context $selector');
        final response = await runtime.debugTapTarget(selector);
        expect(response['ok'], isFalse, reason: '$context $selector');
      }
      expect(dispatches, 0, reason: context);
    }
  });

  testWidgets(rankingCampaign, (tester) async {
    final seed = fuzzSeed(0x51a7ed);
    final runtime = FlutterScoutRuntime();
    List<Map<String, Object?>>? baseline;
    for (final caseIndex in fuzzCases(20)) {
      final random = fuzzRandom(seed, caseIndex);
      final ids = <int>[0, 1, 2, 3]..shuffle(random);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: <Widget>[
                for (final id in ids)
                  Positioned(
                    left: 30,
                    top: 30 + id * 72,
                    width: 220,
                    height: 54,
                    child: ElevatedButton(
                      key: ValueKey<String>('ranked-$id'),
                      onPressed: _noop,
                      child: const Text('Shared action'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final context = fuzzReplay(
        file: file,
        seed: seed,
        caseIndex: caseIndex,
        testName: rankingCampaign,
      );
      final resolution = runtime.debugResolveTarget('Shared action');
      expect(resolution['status'], 'ambiguous', reason: context);
      final ranked = <Map<String, Object?>>[
        for (final raw in (resolution['candidates']! as List).cast<Map>())
          <String, Object?>{
            'handle': raw['handle'],
            'match': raw['match'],
            'heuristicRank': raw['heuristicRank'],
            'rect': raw['rect'],
            'onActiveSurface': raw['onActiveSurface'],
            'visibleFraction': raw['visibleFraction'],
          },
      ];
      baseline ??= ranked;
      expect(ranked, baseline, reason: context);
    }
  });
}

String _unicodeToken(Random random, int length) {
  const runes = <int>[
    0x00e9,
    0x0301,
    0x03bb,
    0x0436,
    0x05e9,
    0x0628,
    0x4fdd,
    0x1f680,
  ];
  return String.fromCharCodes(<int>[
    for (var index = 0; index < length; index += 1)
      runes[random.nextInt(runes.length)],
  ]);
}

void _noop() {}
