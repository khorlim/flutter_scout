import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

import 'endurance_test_support.dart';
import 'test_support.dart';

void main() {
  test(
    'short fake run archives every phase/resource step but stays unmeasured',
    () async {
      final temporary = await createPrivateTestDirectory(
        'flutter_scout_endurance_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final clock = FakeEnduranceClock();
      final executor = FakeEnduranceScoutExecutor(clock: clock);
      final controller = FakeEnduranceHarnessController(clock: clock);
      final config = testEnduranceConfig();

      final result = await EnduranceRunner(
        commandExecutor: executor,
        harnessController: controller,
        archiveParent: temporary,
        clock: clock,
      ).run(config);

      expect(result.outcome.status, EnduranceRunStatus.completed);
      expect(
        result.outcome.componentStatus,
        EnduranceComponentStatus.unmeasured,
      );
      expect(result.outcome.releaseClaimable, isFalse);
      expect(result.outcome.targetReached, isTrue);
      expect(result.outcome.actionCount, 3);
      expect(result.outcome.evidenceComplete, isTrue);
      expect(controller.setupCalls, 1);
      expect(controller.probeCalls, 4);
      expect(controller.teardownCalls, 1);
      expect(executor.executed, hasLength(4));

      final mutationArguments = executor.executed.singleWhere(
        (arguments) => arguments.contains('tap'),
      );
      expect(mutationArguments.take(2), ['--app', 'endurance-session']);
      expect(mutationArguments, contains('--idempotency-key'));
      expect(
        mutationArguments.join(' '),
        isNot(contains(config.plan.seed.toString())),
      );

      final loaded = await const ImmutableEnduranceArchiveLoader().load(
        Directory(result.archiveDirectory),
      );
      expect(loaded.archiveSha256, result.archiveSha256);
      expect(loaded.outcome.toJson(), result.outcome.toJson());
      for (var sequence = 1; sequence <= 3; sequence++) {
        final step =
            jsonDecode(
                  File(
                    '${result.archiveDirectory}/steps/'
                    '${sequence.toString().padLeft(6, '0')}.json',
                  ).readAsStringSync(),
                )
                as Map<String, Object?>;
        final command = step['command']! as Map<String, Object?>;
        final phases = command['phaseTimingsUs']! as Map<String, Object?>;
        final probe = step['probe']! as Map<String, Object?>;
        expect(phases.keys.toSet(), performancePhaseNames.toSet());
        expect(probe.keys, containsAll(['cpu', 'memory', 'frameTime']));
      }
    },
  );

  test('runtime crossover is a release-blocking product failure', () async {
    final temporary = await createPrivateTestDirectory(
      'flutter_scout_endurance_',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final clock = FakeEnduranceClock();
    final controller = FakeEnduranceHarnessController(
      clock: clock,
      probeTransform: (request, probe) {
        if (request.sequence != 2) return probe;
        return _copyProbe(
          probe,
          correlation: EnduranceCorrelation(
            sessionName: probe.correlation.sessionName,
            runId: probe.correlation.runId,
            runtimeInstanceId: 'runtime-crossed',
            processId: probe.correlation.processId,
            fixtureGeneration: probe.correlation.fixtureGeneration,
          ),
        );
      },
    );

    final result = await EnduranceRunner(
      commandExecutor: FakeEnduranceScoutExecutor(clock: clock),
      harnessController: controller,
      archiveParent: temporary,
      clock: clock,
    ).run(testEnduranceConfig());

    expect(result.outcome.status, EnduranceRunStatus.productFailure);
    expect(result.outcome.failure?.kind, EnduranceFailureKind.runtimeCrossover);
    expect(result.outcome.failure?.releaseBlocking, isTrue);
    expect(controller.teardownCalls, 1);
  });

  test('uncertain dispatch is never retried', () async {
    final temporary = await createPrivateTestDirectory(
      'flutter_scout_endurance_',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final clock = FakeEnduranceClock();
    final executor = FakeEnduranceScoutExecutor(
      clock: clock,
      responseTransform: (invocation, arguments, response) {
        if (!arguments.contains('tap')) return response;
        (response['result']! as Map<String, Object?>)['dispatch'] =
            'dispatch_outcome_unknown';
        return response;
      },
    );

    final result =
        await EnduranceRunner(
          commandExecutor: executor,
          harnessController: FakeEnduranceHarnessController(clock: clock),
          archiveParent: temporary,
          clock: clock,
        ).run(
          testEnduranceConfig(
            actions: <EnduranceActionSpec>[
              EnduranceActionSpec(
                actionId: 'uncertain-tap',
                arguments: const <String>['tap', 'btn.next'],
                mutating: true,
                requiresProgress: true,
                timeoutMs: 1000,
              ),
            ],
          ),
        );

    expect(result.outcome.status, EnduranceRunStatus.productFailure);
    expect(
      result.outcome.failure?.kind,
      EnduranceFailureKind.uncertainDispatch,
    );
    expect(executor.executed, hasLength(2));
    expect(result.outcome.actionCount, 0);
  });

  test(
    'independent failure probe attributes runtime loss to app crash',
    () async {
      final temporary = await createPrivateTestDirectory(
        'flutter_scout_endurance_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final clock = FakeEnduranceClock();
      final executor = FakeEnduranceScoutExecutor(
        clock: clock,
        responseTransform: (_, arguments, response) {
          if (!arguments.contains('tap')) return response;
          response['ok'] = false;
          response['structuredError'] = <String, Object?>{
            'code': 'runtime_lost',
            'message': 'Runtime disconnected.',
          };
          return response;
        },
      );
      final controller = FakeEnduranceHarnessController(
        clock: clock,
        probeTransform: (request, probe) => request.sequence == 1
            ? _copyProbe(probe, processAlive: false, crashCount: 1)
            : probe,
      );

      final result =
          await EnduranceRunner(
            commandExecutor: executor,
            harnessController: controller,
            archiveParent: temporary,
            clock: clock,
          ).run(
            testEnduranceConfig(
              actions: <EnduranceActionSpec>[
                EnduranceActionSpec(
                  actionId: 'crashing-tap',
                  arguments: const <String>['tap', 'btn.crash'],
                  mutating: true,
                  requiresProgress: true,
                  timeoutMs: 1000,
                ),
              ],
            ),
          );

      expect(result.outcome.failure?.kind, EnduranceFailureKind.appCrash);
      expect(result.outcome.failure?.owner, EnduranceFailureOwner.product);
      expect(result.outcome.crashCount, 1);
      expect(controller.probeCalls, 2);
      expect(executor.executed, hasLength(2));
    },
  );

  test(
    'repeated required-progress signature stops a no-progress loop',
    () async {
      final temporary = await createPrivateTestDirectory(
        'flutter_scout_endurance_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final clock = FakeEnduranceClock();
      final fixedProgress = sha256Text('fixed-progress');
      final controller = FakeEnduranceHarnessController(
        clock: clock,
        probeTransform: (_, probe) =>
            _copyProbe(probe, progressSignature: fixedProgress),
      );
      final mutation = EnduranceActionSpec(
        actionId: 'progress-required',
        arguments: const <String>['tap', 'btn.next'],
        mutating: true,
        requiresProgress: true,
        timeoutMs: 1000,
      );

      final result =
          await EnduranceRunner(
            commandExecutor: FakeEnduranceScoutExecutor(clock: clock),
            harnessController: controller,
            archiveParent: temporary,
            clock: clock,
          ).run(
            testEnduranceConfig(
              minimumActions: 4,
              maximumActions: 4,
              maximumNoProgress: 2,
              actions: <EnduranceActionSpec>[mutation],
            ),
          );

      expect(result.outcome.failure?.kind, EnduranceFailureKind.noProgress);
      expect(result.outcome.actionCount, 2);
      expect(controller.probeCalls, 3);
    },
  );

  test('sustained RSS growth reports both bound and trend', () async {
    final temporary = await createPrivateTestDirectory(
      'flutter_scout_endurance_',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final clock = FakeEnduranceClock();
    final mebibyte = 1024 * 1024;
    final controller = FakeEnduranceHarnessController(
      clock: clock,
      rssValues: <int>[
        50 * mebibyte,
        52 * mebibyte,
        56 * mebibyte,
        62 * mebibyte,
      ],
    );

    final result =
        await EnduranceRunner(
          commandExecutor: FakeEnduranceScoutExecutor(clock: clock),
          harnessController: controller,
          archiveParent: temporary,
          clock: clock,
        ).run(
          testEnduranceConfig(
            maximumGrowthBytes: mebibyte,
            maximumSlopeBytesPerAction: 100,
          ),
        );

    expect(result.outcome.memory.boundExceeded, isTrue);
    expect(result.outcome.memory.unboundedGrowthObserved, isTrue);
    expect(
      result.outcome.failure?.kind,
      EnduranceFailureKind.unboundedMemoryGrowth,
    );
  });

  test(
    'cancellation and teardown failure have distinct typed ownership',
    () async {
      final cancellationDirectory = await createPrivateTestDirectory(
        'flutter_scout_endurance_cancel_',
      );
      final teardownDirectory = await createPrivateTestDirectory(
        'flutter_scout_endurance_teardown_',
      );
      addTearDown(() async {
        await cancellationDirectory.delete(recursive: true);
        await teardownDirectory.delete(recursive: true);
      });

      final cancelClock = FakeEnduranceClock();
      final signal = MutableEnduranceCancellationSignal();
      final cancelled = await EnduranceRunner(
        commandExecutor: FakeEnduranceScoutExecutor(
          clock: cancelClock,
          cancelAfterInvocation: 1,
          cancellation: signal,
        ),
        harnessController: FakeEnduranceHarnessController(clock: cancelClock),
        archiveParent: cancellationDirectory,
        clock: cancelClock,
        cancellation: signal,
      ).run(testEnduranceConfig(enduranceRunId: 'cancelled-test'));

      expect(cancelled.outcome.status, EnduranceRunStatus.interrupted);
      expect(
        cancelled.outcome.failure?.owner,
        EnduranceFailureOwner.interruption,
      );
      expect(cancelled.outcome.actionCount, 0);
      expect(cancelled.outcome.cleanTeardownProven, isTrue);

      final teardownClock = FakeEnduranceClock();
      final invalid = await EnduranceRunner(
        commandExecutor: FakeEnduranceScoutExecutor(clock: teardownClock),
        harnessController: FakeEnduranceHarnessController(
          clock: teardownClock,
          teardownThrows: true,
        ),
        archiveParent: teardownDirectory,
        clock: teardownClock,
      ).run(testEnduranceConfig(enduranceRunId: 'teardown-invalid'));

      expect(invalid.outcome.status, EnduranceRunStatus.harnessInvalid);
      expect(
        invalid.outcome.failure?.kind,
        EnduranceFailureKind.teardownFailed,
      );
      expect(
        invalid.outcome.componentStatus,
        EnduranceComponentStatus.unmeasured,
      );
    },
  );
}

EnduranceResourceProbe _copyProbe(
  EnduranceResourceProbe source, {
  EnduranceCorrelation? correlation,
  String? progressSignature,
  bool? processAlive,
  int? crashCount,
}) => EnduranceResourceProbe(
  sequence: source.sequence,
  correlation: correlation ?? source.correlation,
  capturedAtUtc: source.capturedAtUtc,
  progressSignature: progressSignature ?? source.progressSignature,
  processAlive: processAlive ?? source.processAlive,
  crashCount: crashCount ?? source.crashCount,
  crossoverCount: source.crossoverCount,
  deadlockCount: source.deadlockCount,
  blockingSignalCount: source.blockingSignalCount,
  cpu: source.cpu,
  memory: source.memory,
  frameTime: source.frameTime,
);
