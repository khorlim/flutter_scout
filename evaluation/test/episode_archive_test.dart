import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test(
    'raw episode archive round-trips and never overwrites an episode',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'flutter_scout_evaluation_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final archive = RawEpisodeArchive(temporary);
      final episode = await evaluateTestEpisode();

      final file = await archive.preserve(episode);
      final bytesBefore = await file.readAsBytes();
      final restored = await archive.read(episode.episodeId);

      expect(restored.toJson(), episode.toJson());
      expect(jsonDecode(utf8.decode(bytesBefore)), episode.toJson());
      if (!Platform.isWindows) {
        expect((await temporary.stat()).mode & 0x1ff, 0x1c0);
        expect((await file.stat()).mode & 0x1ff, 0x180);
      }
      await expectLater(archive.preserve(episode), throwsStateError);
      expect(await file.readAsBytes(), bytesBefore);
    },
  );

  test('archive read rejects path traversal identifiers', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'flutter_scout_evaluation_',
    );
    addTearDown(() => temporary.delete(recursive: true));

    await expectLater(
      RawEpisodeArchive(Directory('/tmp')).read('../secret'),
      throwsFormatException,
    );
  });

  test(
    'archive rejects symlink entries without changing their targets',
    () async {
      if (Platform.isWindows) return;
      final temporary = await Directory.systemTemp.createTemp(
        'flutter_scout_evaluation_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final victim = File('${temporary.path}/victim.txt')
        ..writeAsStringSync('untouched');
      await Link('${temporary.path}/episode-001.json').create(victim.path);

      await expectLater(
        RawEpisodeArchive(temporary).preserve(await evaluateTestEpisode()),
        throwsStateError,
      );
      expect(victim.readAsStringSync(), 'untouched');
    },
  );

  test('archive rejects unbounded and non-private entries', () async {
    if (Platform.isWindows) return;
    final temporary = await Directory.systemTemp.createTemp(
      'flutter_scout_evaluation_',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final archive = RawEpisodeArchive(temporary);
    final episode = await evaluateTestEpisode();
    final file = await archive.preserve(episode);

    expect(
      (await Process.run('/bin/chmod', <String>['644', file.path])).exitCode,
      0,
    );
    await expectLater(archive.read(episode.episodeId), throwsStateError);

    final bounded = RawEpisodeArchive(temporary, maximumEpisodeBytes: 32);
    await expectLater(
      bounded.preserve(await evaluateTestEpisode(episodeId: 'episode-002')),
      throwsStateError,
    );
    expect(File('${temporary.path}/episode-002.json').existsSync(), isFalse);
  });
}
