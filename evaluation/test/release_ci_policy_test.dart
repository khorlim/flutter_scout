import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'blocking CI preserves and repeats every deterministic critical layer',
    () {
      final workflow = File('../.github/workflows/ci.yml').readAsStringSync();
      final canaryStart = workflow.indexOf('  compatibility-canary:');
      expect(canaryStart, greaterThan(0));
      final blockingJob = workflow.substring(0, canaryStart);

      expect(blockingJob, contains("flutter-version: '3.44.2'"));
      expect(
        RegExp(
          r'uses:\s+[^\s@]+@[a-f0-9]{40}(?:\s+#\s+v\d+)?',
        ).allMatches(workflow).length,
        5,
      );
      expect(workflow, isNot(matches(RegExp(r'uses:\s+[^\s@]+@v\d+'))));
      expect(blockingJob, contains('seeds=(1729 2718 31415)'));
      expect(
        blockingJob,
        contains('timeout --signal=TERM --kill-after=15s 20m'),
      );
      expect(blockingJob, contains(r'exit "$failures"'));
      expect(blockingJob, isNot(contains('continue-on-error: true')));
      expect(blockingJob.toLowerCase(), isNot(contains('coverage')));

      for (final suite in const <String>[
        'run_suite cli',
        'run_suite helper',
        'run_suite verification-app',
        'run_suite evaluation',
      ]) {
        expect(blockingJob, contains(suite), reason: suite);
      }
      for (final criticalTest in const <String>[
        'test/flutter_scout_test.dart',
        'test/protocol_safety_test.dart',
        'test/cross_version_compatibility_test.dart',
        'test/lifecycle_safety_test.dart',
        'test/privacy_redaction_test.dart',
        'test/protected_secret_ingress_test.dart',
        'test/dart_define_ingress_test.dart',
        'test/artifact_retention_test.dart',
        'test/bounded_batch_replay_test.dart',
        'test/vm_transport_security_test.dart',
        'test/native_platform_test.dart',
        'test/operability_contract_test.dart',
        'test/changed_region_capture_test.dart',
        'test/public_contract_goldens_test.dart',
        'test/protocol_hardening_test.dart',
        'test/runtime_resolution_test.dart',
        'test/runtime_navigation_test.dart',
        'test/perception_scroll_truth_test.dart',
        'test/observation_noninterference_test.dart',
        'test/protocol_property_fuzz_test.dart',
        'test/resolution_property_fuzz_test.dart',
        'test/snapshot_state_property_fuzz_test.dart',
        'test/semantic_stability_test.dart',
        'test/runtime_signal_provenance_test.dart',
        'test/runtime_recorder_storage_test.dart',
        'test/operability_identity_test.dart',
        'test/widget_test.dart',
        'test/evaluation_oracle_test.dart',
        'test/public_fixture_screen_test.dart',
      ]) {
        expect(blockingJob, contains(criticalTest), reason: criticalTest);
      }

      for (final evidence in const <String>[
        'context.log',
        'outcomes.tsv',
        '.command',
        '.stdout.log',
        '.stderr.log',
        'if: always()',
        'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02',
        'if-no-files-found: error',
        'retention-days: 90',
      ]) {
        expect(blockingJob, contains(evidence), reason: evidence);
      }

      final releasePolicy = File('../RELEASING.md').readAsStringSync();
      expect(releasePolicy, contains('Repeated release-critical test gate'));
      expect(releasePolicy, contains('even if a later attempt passes'));
      expect(releasePolicy, contains('coverage percentage'));
      expect(releasePolicy, contains('Tier-1 simulator repetitions'));
    },
  );
}
