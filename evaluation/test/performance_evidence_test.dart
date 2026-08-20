import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

import 'performance_test_support.dart';

void main() {
  group('strict performance contracts', () {
    test('config round-trips all pinned environment facts', () {
      final config = testPerformanceConfig();
      final roundTrip = PerformanceConfig.fromJson(config.toJson());

      expect(roundTrip.toJson(), config.toJson());
      expect(roundTrip.environment.sha256, config.environment.sha256);
      expect(roundTrip.expectedSampleIds, {
        'baseline-r000001',
        'baseline-r000002',
        'candidate-r000001',
        'candidate-r000002',
      });
    });

    test('ratified thresholds reject a different environment', () {
      final config = testPerformanceConfig(ratified: true);
      final json = _copy(config.toJson());
      final environment = json['environment']! as Map<String, Object?>;
      final hardware = environment['hardware']! as Map<String, Object?>;
      hardware['model'] = 'Unfrozen replacement host';

      expect(
        () => PerformanceConfig.fromJson(json),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message.toString(),
            'message',
            contains('pinned to'),
          ),
        ),
      );
    });

    test('ratified primitive evidence requires one hundred repetitions', () {
      expect(
        () => testPerformanceConfig(ratified: true, repetitions: 99),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message.toString(),
            'message',
            contains('at least 100 repetitions'),
          ),
        ),
      );
    });

    test('a config cannot silently weaken provisional gold targets', () {
      final json = _copy(testPerformanceConfig().toJson());
      final thresholds = json['thresholds']! as Map<String, Object?>;
      thresholds['actionOverheadP95Us'] = 250001;

      expect(
        () => PerformanceConfig.fromJson(json),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message.toString(),
            'message',
            contains('must not weaken'),
          ),
        ),
      );
    });

    test('active Scout timing evidence rejects non-debug builds', () {
      final json = _copy(testPerformanceConfig().toJson());
      final environment = json['environment']! as Map<String, Object?>;
      environment['buildMode'] = 'profile';

      expect(
        () => PerformanceConfig.fromJson(json),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message.toString(),
            'message',
            contains('must remain inactive'),
          ),
        ),
      );
    });

    test('non-finite values fail before evidence can be reported', () {
      expect(
        () => PerformanceViewport(
          logicalWidth: double.nan,
          logicalHeight: 844,
          devicePixelRatio: 3,
        ),
        throwsArgumentError,
      );
      expect(
        () => CpuObservation(
          idlePercent: double.infinity,
          activePercent: 1,
          windowMs: 1,
          provenance: MeasurementProvenance(
            source: 'test',
            method: 'test',
            collectorVersion: '1',
            target: 'test',
            capturedAtUtc: DateTime.utc(2026),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('missing phase and incomplete resource facts fail closed', () {
      final config = testPerformanceConfig();
      final sample = testPerformanceSample(
        config: config,
        conditionId: config.baseline.conditionId,
        repetition: 1,
      );
      final missingPhase = _copy(sample.toJson());
      final phases = missingPhase['phaseTimingsUs']! as Map<String, Object?>;
      phases.remove('logs');
      expect(
        () => PerformanceRawSample.fromJson(missingPhase),
        throwsA(isA<FormatException>()),
      );

      final negativePhase = _copy(sample.toJson());
      final negativePhases =
          negativePhase['phaseTimingsUs']! as Map<String, Object?>;
      negativePhases['connect'] = -1;
      expect(
        () => PerformanceRawSample.fromJson(negativePhase),
        throwsA(isA<FormatException>()),
      );

      final incompleteResources = _copy(sample.toJson());
      final resources =
          incompleteResources['resources']! as Map<String, Object?>;
      resources.remove('frameTime');
      expect(
        () => PerformanceRawSample.fromJson(incompleteResources),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('report integrity and false-pass prevention', () {
    test(
      'provisional fixture can never pass quantitative or release gates',
      () {
        final config = testPerformanceConfig();
        final report = const PerformanceReportBuilder().build(
          config: config,
          samples: testPerformanceSamples(config),
        );
        final json = report.toJson();
        final quantitative = json['quantitativeGates']! as Map<String, Object?>;
        final gates = quantitative['gates']! as List<Object?>;
        final release = json['releaseAssessment']! as Map<String, Object?>;

        expect(
          gates.map((item) => (item as Map<String, Object?>)['status']),
          everyElement('unmeasured'),
        );
        expect(release['status'], 'unmeasured');
        expect(release['claimable'], isFalse);
        expect(report.componentBlocked, isFalse);
      },
    );

    test(
      'ratified component pass still does not claim release eligibility',
      () {
        final config = testPerformanceConfig(ratified: true);
        final report = const PerformanceReportBuilder().build(
          config: config,
          samples: testPerformanceSamples(config),
        );
        final json = report.toJson();
        final quantitative = json['quantitativeGates']! as Map<String, Object?>;
        final gates = quantitative['gates']! as List<Object?>;
        final release = json['releaseAssessment']! as Map<String, Object?>;

        expect(gates.map((item) => (item as Map<String, Object?>)['status']), [
          'unmeasured',
          'unmeasured',
          ...List.filled(6, 'pass'),
        ]);
        expect(release['status'], 'unmeasured');
        expect(release['claimable'], isFalse);
        expect(report.componentBlocked, isFalse);
      },
    );

    test('an observation side effect blocks an otherwise fast false pass', () {
      final config = testPerformanceConfig(ratified: true);
      final report = const PerformanceReportBuilder().build(
        config: config,
        samples: testPerformanceSamples(
          config,
          candidateObservationEffect: true,
        ),
      );
      final json = report.toJson();
      final nonInterference =
          json['observationNonInterference']! as Map<String, Object?>;
      final quantitative = json['quantitativeGates']! as Map<String, Object?>;
      final gates = quantitative['gates']! as List<Object?>;
      final release = json['releaseAssessment']! as Map<String, Object?>;

      expect(nonInterference['status'], 'blocked');
      expect(nonInterference['affectedSampleCount'], 1);
      expect(
        gates.map((item) => (item as Map<String, Object?>)['status']),
        everyElement('blocked'),
      );
      expect(release['status'], 'blocked');
      expect(release['claimable'], isFalse);
      expect(report.componentBlocked, isTrue);
    });

    test('missing, duplicate, and environment-mismatched samples fail', () {
      final config = testPerformanceConfig();
      final complete = testPerformanceSamples(config);

      expect(
        () => const PerformanceReportBuilder().build(
          config: config,
          samples: complete.sublist(1),
        ),
        throwsA(
          isA<PerformanceInputException>().having(
            (error) => error.toString(),
            'message',
            contains('Missing preregistered samples'),
          ),
        ),
      );
      expect(
        () => const PerformanceReportBuilder().build(
          config: config,
          samples: [...complete, complete.first],
        ),
        throwsA(
          isA<PerformanceInputException>().having(
            (error) => error.toString(),
            'message',
            contains('Duplicate sample id'),
          ),
        ),
      );
      final mismatchId = performanceSampleId(config.baseline.conditionId, 1);
      expect(
        () => const PerformanceReportBuilder().build(
          config: config,
          samples: testPerformanceSamples(
            config,
            mismatchedSampleId: mismatchId,
          ),
        ),
        throwsA(
          isA<PerformanceInputException>().having(
            (error) => error.toString(),
            'message',
            contains('config/environment mismatch'),
          ),
        ),
      );
      final postHoc = loadedPerformanceSample(
        testPerformanceSample(
          config: config,
          conditionId: config.candidate.conditionId,
          repetition: config.repetitions + 1,
        ),
      );
      expect(
        () => const PerformanceReportBuilder().build(
          config: config,
          samples: [...complete, postHoc],
        ),
        throwsA(
          isA<PerformanceInputException>().having(
            (error) => error.toString(),
            'message',
            contains('Extra/post-hoc samples'),
          ),
        ),
      );
    });

    test('typed samples cannot diverge from their retained exact bytes', () {
      final config = testPerformanceConfig();
      final complete = testPerformanceSamples(config);
      final original = complete.first;
      final tampered = LoadedPerformanceSample(
        sourcePath: original.sourcePath,
        fileSha256: sha256Bytes(utf8.encode('{}')),
        rawBytes: utf8.encode('{}'),
        sample: original.sample,
      );

      expect(
        () => const PerformanceReportBuilder().build(
          config: config,
          samples: [tampered, ...complete.skip(1)],
        ),
        throwsA(
          isA<PerformanceInputException>().having(
            (error) => error.toString(),
            'message',
            contains('exact raw bytes are not a valid sample'),
          ),
        ),
      );
    });

    test('action overhead excludes application settling', () {
      final timings = PerformancePhaseTimings(
        connectUs: 1,
        snapshotUs: 2,
        matchUs: 3,
        dispatchUs: 4,
        settleUs: 1000000,
        deltaUs: 5,
        logsUs: 6,
        serializeUs: 7,
      );

      expect(timings.actionOverheadExcludingSettleUs, 28);
      expect(timings.totalUs, 1000028);
    });
  });

  test(
    'immutable loader retains exact bytes and rejects archive clutter',
    () async {
      final config = testPerformanceConfig();
      final sample = testPerformanceSample(
        config: config,
        conditionId: config.baseline.conditionId,
        repetition: 1,
      );
      final root = await Directory.systemTemp.createTemp('scout-performance-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final source = File('${root.path}/${sample.sampleId}.json');
      final exact = utf8.encode('  ${jsonEncode(sample.toJson())}\n');
      await source.writeAsBytes(exact);

      final loaded = await const ImmutablePerformanceSampleLoader().load(root);
      expect(loaded.single.rawBytes, exact);
      expect(loaded.single.fileSha256, sha256Bytes(exact));

      await File('${root.path}/notes.txt').writeAsString('post-hoc notes');
      expect(
        () => const ImmutablePerformanceSampleLoader().load(root),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'performance loader enforces per-file and aggregate byte bounds',
    () async {
      final config = testPerformanceConfig();
      final sample = testPerformanceSample(
        config: config,
        conditionId: config.baseline.conditionId,
        repetition: 1,
      );
      final root = await Directory.systemTemp.createTemp('scout-performance-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      await File(
        '${root.path}/${sample.sampleId}.json',
      ).writeAsString(jsonEncode(sample.toJson()));

      await expectLater(
        const ImmutablePerformanceSampleLoader(
          maximumSampleBytes: 32,
          maximumArchiveBytes: 32,
        ).load(root),
        throwsA(isA<EvaluationInputException>()),
      );
    },
  );
}

Map<String, Object?> _copy(Map<String, Object?> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, Object?>;
