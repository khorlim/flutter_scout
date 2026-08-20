import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'scout-benchmark-episodes-',
    );
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'loader preserves exact bytes and fingerprints the immutable input',
    () async {
      final catalog = testCatalog();
      final config = testBenchmarkConfig(catalog: catalog, repetitions: 1);
      final schedule = BenchmarkSchedule.generate(
        config: config,
        catalog: catalog,
      );
      final episode = loadedBenchmarkEpisode(
        config: config,
        schedule: schedule,
        scheduled: schedule.episodes.first,
      );
      final file = File('${directory.path}/episode.json');
      await file.writeAsBytes(episode.rawBytes, flush: true);

      final loaded = await const ImmutableEpisodeLoader().load(directory);

      expect(loaded, hasLength(1));
      expect(loaded.single.rawBytes, episode.rawBytes);
      expect(loaded.single.fileSha256, sha256Bytes(episode.rawBytes));
      expect(loaded.single.envelope.toJson(), episode.envelope.toJson());
    },
  );

  test(
    'loader rejects duplicate episode ids even in different files',
    () async {
      final catalog = testCatalog();
      final config = testBenchmarkConfig(catalog: catalog, repetitions: 1);
      final schedule = BenchmarkSchedule.generate(
        config: config,
        catalog: catalog,
      );
      final episode = loadedBenchmarkEpisode(
        config: config,
        schedule: schedule,
        scheduled: schedule.episodes.first,
      );
      await File('${directory.path}/first.json').writeAsBytes(episode.rawBytes);
      await File(
        '${directory.path}/second.json',
      ).writeAsBytes(episode.rawBytes);

      await expectLater(
        const ImmutableEpisodeLoader().load(directory),
        throwsA(
          isA<BenchmarkInputException>().having(
            (error) => error.toString(),
            'message',
            contains('Duplicate episode id'),
          ),
        ),
      );
    },
  );

  test('episode envelope rejects post-hoc exclusion metadata', () {
    final catalog = testCatalog();
    final config = testBenchmarkConfig(catalog: catalog, repetitions: 1);
    final schedule = BenchmarkSchedule.generate(
      config: config,
      catalog: catalog,
    );
    final envelope = loadedBenchmarkEpisode(
      config: config,
      schedule: schedule,
      scheduled: schedule.episodes.first,
    ).envelope.toJson();
    envelope['excluded'] = true;

    expect(
      () => BenchmarkEpisodeEnvelope.fromJson(jsonDecode(jsonEncode(envelope))),
      throwsA(isA<FormatException>()),
    );
  });

  test('a missing fresh reset can only be a harness-invalid episode', () {
    final catalog = testCatalog();
    final config = testBenchmarkConfig(catalog: catalog, repetitions: 1);
    final schedule = BenchmarkSchedule.generate(
      config: config,
      catalog: catalog,
    );
    final scheduled = schedule.episodes.first;

    expect(
      () => loadedBenchmarkEpisode(
        config: config,
        schedule: schedule,
        scheduled: scheduled,
        freshResetPerformed: false,
      ),
      throwsArgumentError,
    );
  });

  test('loader rejects oversized and non-regular archive entries', () async {
    final catalog = testCatalog();
    final config = testBenchmarkConfig(catalog: catalog, repetitions: 1);
    final schedule = BenchmarkSchedule.generate(
      config: config,
      catalog: catalog,
    );
    final episode = loadedBenchmarkEpisode(
      config: config,
      schedule: schedule,
      scheduled: schedule.episodes.first,
    );
    final file = File('${directory.path}/episode.json')
      ..writeAsBytesSync(episode.rawBytes);

    await expectLater(
      const ImmutableEpisodeLoader(
        maximumEpisodeBytes: 32,
        maximumArchiveBytes: 32,
      ).load(directory),
      throwsA(
        isA<BenchmarkInputException>().having(
          (error) => error.toString(),
          'message',
          contains('byte bound'),
        ),
      ),
    );

    if (!Platform.isWindows) {
      file.deleteSync();
      final victim = File('${directory.path}/victim.json')
        ..writeAsBytesSync(episode.rawBytes);
      await Link(file.path).create(victim.path);
      await expectLater(
        const ImmutableEpisodeLoader().load(directory),
        throwsA(isA<BenchmarkInputException>()),
      );
    }
  });
}
