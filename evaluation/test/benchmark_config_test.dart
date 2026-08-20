import 'dart:convert';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test('strict config round-trips and fingerprints every pinned input', () {
    final catalog = testCatalog();
    final config = testBenchmarkConfig(catalog: catalog);

    final decoded = BenchmarkConfig.fromJson(config.toJson());

    expect(decoded.toJson(), config.toJson());
    expect(decoded.sha256, matches(RegExp(r'^[a-f0-9]{64}$')));
    final changed = decoded.toJson();
    final agent = changed['agent']! as Map<String, Object?>;
    agent['reasoning'] = 'low';
    expect(BenchmarkConfig.fromJson(changed).sha256, isNot(config.sha256));
  });

  test('config rejects unknown post-hoc fields and abbreviated commits', () {
    final config = testBenchmarkConfig(catalog: testCatalog()).toJson();
    config['excludeFailedEpisodes'] = true;
    expect(
      () => BenchmarkConfig.fromJson(config),
      throwsA(isA<FormatException>()),
    );

    final clean = jsonDecode(jsonEncode(config)) as Map<String, Object?>;
    clean.remove('excludeFailedEpisodes');
    final conditions = clean['conditions']! as Map<String, Object?>;
    final candidate = conditions['candidate']! as Map<String, Object?>;
    candidate['scoutGitCommit'] = 'abc123';
    expect(
      () => BenchmarkConfig.fromJson(clean),
      throwsA(isA<FormatException>()),
    );
  });

  test('config requires each template in exactly one family', () {
    final catalog = testCatalog();
    expect(
      () => testBenchmarkConfig(
        catalog: catalog,
        templateFamilies: [
          TemplateFamily(
            familyId: 'first',
            templateIds: const ['save-profile'],
          ),
          TemplateFamily(
            familyId: 'second',
            templateIds: const ['save-profile'],
          ),
        ],
      ),
      throwsArgumentError,
    );
  });
}
