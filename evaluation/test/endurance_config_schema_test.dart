import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

import 'endurance_test_support.dart';

void main() {
  test('test-only config round-trips and is explicitly ineligible', () {
    final config = testEnduranceConfig();
    final roundTrip = EnduranceConfig.fromJson(config.toJson());

    expect(roundTrip.toJson(), config.toJson());
    expect(roundTrip.mode, EnduranceRunMode.testOnly);
    expect(roundTrip.testOnlyReason, isNotEmpty);
    expect(roundTrip.sha256, config.sha256);
  });

  test('release evidence requires 60 minutes or 1000 actions', () {
    expect(
      () => testEnduranceConfig(mode: EnduranceRunMode.releaseEvidence),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message.toString(),
          'message',
          contains('60 minutes or 1,000 actions'),
        ),
      ),
    );

    final actionEligible = testEnduranceConfig(
      mode: EnduranceRunMode.releaseEvidence,
      minimumActions: 1000,
      maximumActions: 1000,
    );
    expect(actionEligible.mode, EnduranceRunMode.releaseEvidence);
  });

  test('release evidence cannot weaken the memory gate', () {
    expect(
      () => testEnduranceConfig(
        mode: EnduranceRunMode.releaseEvidence,
        minimumActions: 1000,
        maximumActions: 1000,
        maximumGrowthBytes: goldIncrementalRssMaxBytes + 1,
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message.toString(),
          'message',
          contains('20 MiB'),
        ),
      ),
    );
  });

  test('runner-owned identity flags and runtime replacement are rejected', () {
    expect(
      () => EnduranceActionSpec(
        actionId: 'unsafe-app',
        arguments: const <String>['inspect', '--app', 'other'],
        mutating: false,
        requiresProgress: false,
        timeoutMs: 100,
      ),
      throwsArgumentError,
    );
    expect(
      () => EnduranceActionSpec(
        actionId: 'unsafe-restart',
        arguments: const <String>['restart'],
        mutating: true,
        requiresProgress: false,
        timeoutMs: 100,
      ),
      throwsArgumentError,
    );
  });

  test(
    'schemas make short runs and release claims structurally impossible',
    () {
      final configSchema =
          jsonDecode(
                File(
                  'schemas/v1/endurance_config.schema.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final archiveSchema =
          jsonDecode(
                File(
                  'schemas/v1/endurance_archive.schema.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;

      expect(configSchema['additionalProperties'], isFalse);
      expect(archiveSchema['additionalProperties'], isFalse);
      expect(jsonEncode(configSchema), contains('3600000'));
      expect(jsonEncode(configSchema), contains('1000'));
      expect(jsonEncode(configSchema), contains('20971520'));
      expect(
        jsonEncode(archiveSchema),
        contains('"releaseClaimable":{"const":false}'),
      );
      final archiveText = jsonEncode(archiveSchema);
      for (final kind in EnduranceFailureKind.values) {
        expect(archiveText, contains('"${kind.jsonName}"'));
      }
      expect(enduranceConfigSchemaVersion, 1);
      expect(enduranceArchiveSchemaVersion, 1);
    },
  );
}
