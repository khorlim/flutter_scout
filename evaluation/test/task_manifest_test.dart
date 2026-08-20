import 'dart:convert';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  test('task manifest v1 round-trips without changing data', () {
    final manifest = testManifest();
    final decoded = TaskManifest.fromJson(
      jsonDecode(jsonEncode(manifest.toJson())),
    );

    expect(decoded.toJson(), manifest.toJson());
    expect(decoded.split, BenchmarkSplit.publicDevelopment);
  });

  test('agent projection excludes every hidden harness and variant field', () {
    final manifest = testManifest();
    final visible = manifest.toAgentView().toJson();
    final encoded = jsonEncode(visible);

    expect(visible['schemaVersion'], agentTaskSchemaVersion);
    expect(visible['taskId'], manifest.taskId);
    expect(encoded, isNot(contains('oracle.profile-saved')));
    expect(encoded, isNot(contains('predicate.profile-saved')));
    expect(encoded, isNot(contains('Hidden expected value')));
    expect(visible, isNot(contains('hiddenHarness')));
    expect(visible, isNot(contains('variant')));
    expect(visible, isNot(contains('split')));
    expect(visible, isNot(contains('templateId')));
  });

  test('unknown fields and unsupported schema versions fail closed', () {
    final json = testManifest().toJson();
    expect(
      () => TaskManifest.fromJson({...json, 'unexpected': true}),
      throwsFormatException,
    );
    expect(
      () => TaskManifest.fromJson({...json, 'schemaVersion': 2}),
      throwsFormatException,
    );
  });
}
