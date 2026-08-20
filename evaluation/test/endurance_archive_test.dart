import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

import 'endurance_test_support.dart';

void main() {
  test(
    'archive is create-only and exact-byte tampering fails validation',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'flutter_scout_endurance_archive_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final clock = FakeEnduranceClock();
      final config = testEnduranceConfig(enduranceRunId: 'archive-test');
      final result = await EnduranceRunner(
        commandExecutor: FakeEnduranceScoutExecutor(clock: clock),
        harnessController: FakeEnduranceHarnessController(clock: clock),
        archiveParent: temporary,
        clock: clock,
      ).run(config);

      await expectLater(
        EnduranceArchiveWriter.create(
          parent: temporary,
          config: config,
          createdAtUtc: clock.utcNow,
        ),
        throwsA(isA<EnduranceArchiveException>()),
      );

      final step = File('${result.archiveDirectory}/steps/000001.json');
      await step.writeAsString('${await step.readAsString()} ');
      await expectLater(
        const ImmutableEnduranceArchiveLoader().load(
          Directory(result.archiveDirectory),
        ),
        throwsA(
          isA<EnduranceArchiveException>().having(
            (error) => error.toString(),
            'message',
            contains('exact byte inventory'),
          ),
        ),
      );
    },
  );

  test(
    'invalid fresh setup is archived as HARNESS_INVALID ownership',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'flutter_scout_endurance_archive_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final clock = FakeEnduranceClock();
      final controller = FakeEnduranceHarnessController(
        clock: clock,
        freshSetup: false,
      );
      final executor = FakeEnduranceScoutExecutor(clock: clock);

      final result = await EnduranceRunner(
        commandExecutor: executor,
        harnessController: controller,
        archiveParent: temporary,
        clock: clock,
      ).run(testEnduranceConfig(enduranceRunId: 'invalid-setup'));

      expect(result.outcome.status, EnduranceRunStatus.harnessInvalid);
      expect(result.outcome.failure?.kind, EnduranceFailureKind.setupNotFresh);
      expect(result.outcome.failure?.owner, EnduranceFailureOwner.harness);
      expect(result.outcome.failure?.releaseBlocking, isFalse);
      expect(executor.executed, isEmpty);
      expect(controller.teardownCalls, 1);
      expect(result.outcome.releaseClaimable, isFalse);
    },
  );
}
