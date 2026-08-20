import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../digests.dart';
import '../json_support.dart';
import '../performance/performance_sample.dart';
import '../tool_simulator/scout_process_executor.dart';
import 'endurance_archive.dart';
import 'endurance_config.dart';
import 'endurance_contract.dart';

class EnduranceRunner {
  const EnduranceRunner({
    required this.commandExecutor,
    required this.harnessController,
    required this.archiveParent,
    required this.clock,
    this.cancellation = const NeverCancelledEnduranceSignal(),
  });

  final ScoutCommandExecutor commandExecutor;
  final EnduranceHarnessController harnessController;
  final Directory archiveParent;
  final EnduranceClock clock;
  final EnduranceCancellationSignal cancellation;

  Future<EnduranceRunResult> run(EnduranceConfig config) async {
    final startedAtUtc = clock.utcNow;
    final startedUs = clock.monotonicMicroseconds;
    var lastClockUs = startedUs;
    final writer = await EnduranceArchiveWriter.create(
      parent: archiveParent,
      config: config,
      createdAtUtc: startedAtUtc,
    );
    final memory = _BoundedMemoryAssessor(config.limits);
    final commandIds = <String>{};
    EnduranceSetupObservation? setup;
    EnduranceResourceProbe? latestProbe;
    EnduranceTeardownObservation? teardown;
    EnduranceCommandEvidence? latestCommandEvidence;
    EnduranceFailure? failure;
    var actionCount = 0;
    var noProgressStreak = 0;
    var crashCount = 0;
    var crossoverCount = 0;
    var deadlockCount = 0;
    var blockingSignalCount = 0;
    var freshSetupProven = false;
    var cleanTeardownProven = false;
    var evidenceComplete = true;
    String? lastRecordSha256;
    int? activeStartedUs;
    int? activeFinishedUs;
    DateTime? activeStartedAtUtc;
    DateTime? activeFinishedAtUtc;

    EnduranceFailure detected({
      required EnduranceFailureKind kind,
      required EnduranceFailureOwner owner,
      required String message,
      int? sequence,
      bool releaseBlocking = false,
    }) => EnduranceFailure(
      kind: kind,
      owner: owner,
      releaseBlocking: releaseBlocking,
      message: message,
      sequence: sequence,
    );

    int monotonicNow({int? sequence}) {
      final current = clock.monotonicMicroseconds;
      if (current < lastClockUs) {
        failure ??= detected(
          kind: EnduranceFailureKind.clockRegressed,
          owner: EnduranceFailureOwner.harness,
          message: 'The injected monotonic clock regressed.',
          sequence: sequence,
        );
        evidenceComplete = false;
        return lastClockUs;
      }
      lastClockUs = current;
      return current;
    }

    Future<T?> boundedHook<T>(
      Future<T> Function() operation, {
      required EnduranceFailureKind failureKind,
      required String stage,
      int? sequence,
    }) async {
      try {
        return await operation().timeout(
          Duration(milliseconds: config.limits.harnessHookTimeoutMs),
        );
      } on TimeoutException {
        failure ??= detected(
          kind: failureKind,
          owner: EnduranceFailureOwner.harness,
          message: 'The independent $stage hook exceeded its bound.',
          sequence: sequence,
        );
        evidenceComplete = false;
      } on Object catch (error) {
        failure ??= detected(
          kind: failureKind,
          owner: EnduranceFailureOwner.harness,
          message:
              'The independent $stage hook failed '
              '(${error.runtimeType}).',
          sequence: sequence,
        );
        evidenceComplete = false;
      }
      return null;
    }

    Future<EnduranceResourceProbe?> collectFailureProbe({
      required int sequence,
      required String actionId,
      required EnduranceCorrelation anchor,
    }) async {
      final probe = await boundedHook(
        () => harnessController.probe(
          EnduranceProbeRequest(
            enduranceRunId: config.enduranceRunId,
            sequence: sequence,
            actionId: actionId,
            anchor: anchor,
          ),
        ),
        failureKind: EnduranceFailureKind.probeFailed,
        stage: 'post-failure resource probe',
        sequence: sequence,
      );
      if (probe == null) return null;
      latestProbe = probe;
      final probeFailure = _validateProbe(
        config: config,
        probe: probe,
        anchor: anchor,
        expectedSequence: sequence,
      );
      if (probeFailure != null) {
        if (failure?.kind == EnduranceFailureKind.commandFailed &&
            probeFailure.owner == EnduranceFailureOwner.product) {
          failure = probeFailure;
        }
        evidenceComplete = false;
      }
      crashCount = math.max(crashCount, probe.crashCount);
      crossoverCount = math.max(crossoverCount, probe.crossoverCount);
      deadlockCount = math.max(deadlockCount, probe.deadlockCount);
      blockingSignalCount = math.max(
        blockingSignalCount,
        probe.blockingSignalCount,
      );
      memory.add(probe.memory.processRssBytes);
      return probe;
    }

    try {
      if (canonicalJsonEncode(harnessController.identity.toJson()) !=
          canonicalJsonEncode(config.harness.toJson())) {
        failure = detected(
          kind: EnduranceFailureKind.controllerIdentityMismatch,
          owner: EnduranceFailureOwner.harness,
          message:
              'The supplied harness controller identity does not match '
              'the preregistered immutable controller.',
        );
        evidenceComplete = false;
      }

      if (failure == null) {
        setup = await boundedHook(
          () => harnessController.setUp(config),
          failureKind: EnduranceFailureKind.setupFailed,
          stage: 'fresh setup',
        );
        if (setup != null) {
          await writer.preserveEvent('setup', <String, Object?>{
            'schemaVersion': enduranceArchiveSchemaVersion,
            'recordType': 'setup',
            ...setup.toJson(),
          });
          final setupIssue = _validateSetup(config, setup);
          if (setupIssue != null) {
            failure = detected(
              kind: EnduranceFailureKind.setupNotFresh,
              owner: EnduranceFailureOwner.harness,
              message: setupIssue,
            );
            evidenceComplete = false;
          } else {
            freshSetupProven = true;
          }
        }
      }

      if (failure == null && setup != null) {
        final baselineRaw = await _execute(
          <String>['--app', config.sessionName, 'inspect', '--brief'],
          timeout: Duration(
            milliseconds: math.min(
              config.limits.harnessHookTimeoutMs,
              config.limits.maximumDurationMs,
            ),
          ),
        );
        if (baselineRaw.failure != null) {
          failure = baselineRaw.failure;
          evidenceComplete = false;
          final failureProbe = await collectFailureProbe(
            sequence: 0,
            actionId: 'baseline-inspect',
            anchor: setup.correlation,
          );
          await writer.preserveEvent(
            'baseline_failure',
            baselineRaw.rawEvent(
              sequence: 0,
              actionId: 'baseline-inspect',
              detectedFailure: failure,
              probe: failureProbe,
            ),
          );
        } else {
          final parsed = _parseCommandEvidence(
            baselineRaw.result!,
            expectedCommandName: 'inspect',
            maximumOutputBytes: config.limits.maximumCommandOutputBytes,
          );
          if (parsed.failure != null) {
            failure = parsed.failure;
            evidenceComplete = false;
            final failureProbe = await collectFailureProbe(
              sequence: 0,
              actionId: 'baseline-inspect',
              anchor: setup.correlation,
            );
            await writer.preserveEvent(
              'baseline_failure',
              baselineRaw.rawEvent(
                sequence: 0,
                actionId: 'baseline-inspect',
                detectedFailure: failure,
                probe: failureProbe,
              ),
            );
          } else {
            latestCommandEvidence = parsed.evidence;
            final correlationFailure = _validateCommandCorrelation(
              parsed.evidence!,
              setup.correlation,
              previousStateGeneration: null,
              previousLogCursor: null,
              commandIds: commandIds,
              sequence: 0,
            );
            if (correlationFailure != null) {
              failure = correlationFailure;
              evidenceComplete = false;
            }
            final baselineProbe = await boundedHook(
              () => harnessController.probe(
                EnduranceProbeRequest(
                  enduranceRunId: config.enduranceRunId,
                  sequence: 0,
                  actionId: 'baseline-inspect',
                  anchor: setup!.correlation,
                ),
              ),
              failureKind: EnduranceFailureKind.probeFailed,
              stage: 'baseline resource probe',
              sequence: 0,
            );
            latestProbe = baselineProbe;
            if (baselineProbe != null) {
              final probeFailure = _validateProbe(
                config: config,
                probe: baselineProbe,
                anchor: setup.correlation,
                expectedSequence: 0,
              );
              failure ??= probeFailure;
              if (probeFailure != null) evidenceComplete = false;
              memory.add(baselineProbe.memory.processRssBytes);
              crashCount = baselineProbe.crashCount;
              crossoverCount = baselineProbe.crossoverCount;
              deadlockCount = baselineProbe.deadlockCount;
              blockingSignalCount = baselineProbe.blockingSignalCount;
            }
            await writer.preserveEvent('baseline', <String, Object?>{
              'schemaVersion': enduranceArchiveSchemaVersion,
              'recordType': 'baseline',
              'command': parsed.evidence!.toJson(),
              'probe': baselineProbe?.toJson(),
            });
            if (failure == null && baselineProbe != null) {
              activeStartedUs = monotonicNow(sequence: 0);
              activeStartedAtUtc = startedAtUtc.add(
                Duration(microseconds: activeStartedUs - startedUs),
              );
            }
          }
        }
      }

      var previousStateGeneration = latestCommandEvidence?.stateGeneration;
      var previousLogCursor = latestCommandEvidence?.logCursor;
      String? previousProgress = latestProbe?.progressSignature;

      while (failure == null && setup != null && latestProbe != null) {
        final currentDurationMs = activeStartedUs == null
            ? 0
            : math.max(
                0,
                (monotonicNow() - activeStartedUs) ~/
                    Duration.microsecondsPerMillisecond,
              );
        if (failure != null) break;
        if (config.limits.targetReached(
          durationMs: currentDurationMs,
          actionCount: actionCount,
        )) {
          break;
        }
        if (cancellation.isCancelled) {
          failure = detected(
            kind: EnduranceFailureKind.runnerCancelled,
            owner: EnduranceFailureOwner.interruption,
            message: cancellation.reason ?? 'The endurance run was cancelled.',
            sequence: actionCount + 1,
          );
          break;
        }
        if (actionCount >= config.limits.maximumActions ||
            currentDurationMs >= config.limits.maximumDurationMs) {
          failure = detected(
            kind: EnduranceFailureKind.hardBoundReached,
            owner: EnduranceFailureOwner.product,
            releaseBlocking: true,
            message:
                'The hard endurance bound was reached before the '
                'preregistered target.',
            sequence: actionCount + 1,
          );
          break;
        }

        final sequence = actionCount + 1;
        final action = config.plan.actionForSequence(sequence);
        final actualArguments = <String>[
          '--app',
          config.sessionName,
          if (action.mutating) ...<String>[
            '--idempotency-key',
            config.plan.idempotencyKey(
              enduranceRunId: config.enduranceRunId,
              sequence: sequence,
            ),
          ],
          ...action.arguments,
        ];
        final stepStartedAt = clock.utcNow;
        final stepStartedUs = monotonicNow(sequence: sequence);
        final remainingHardMs = math.max(
          1,
          config.limits.maximumDurationMs - currentDurationMs,
        );
        final raw = await _execute(
          actualArguments,
          timeout: Duration(
            milliseconds: math.min(action.timeoutMs, remainingHardMs),
          ),
          sequence: sequence,
        );
        if (raw.failure != null) {
          failure = raw.failure;
          evidenceComplete = false;
          final failureProbe = await collectFailureProbe(
            sequence: sequence,
            actionId: action.actionId,
            anchor: setup.correlation,
          );
          await writer.preserveEvent(
            'failure_${sequence.toString().padLeft(6, '0')}',
            raw.rawEvent(
              sequence: sequence,
              actionId: action.actionId,
              detectedFailure: failure,
              probe: failureProbe,
            ),
          );
          continue;
        }
        final parsed = _parseCommandEvidence(
          raw.result!,
          expectedCommandName: action.arguments.first,
          maximumOutputBytes: config.limits.maximumCommandOutputBytes,
          mutation: action.mutating,
          sequence: sequence,
        );
        if (parsed.failure != null) {
          failure = parsed.failure;
          evidenceComplete = false;
          final failureProbe = await collectFailureProbe(
            sequence: sequence,
            actionId: action.actionId,
            anchor: setup.correlation,
          );
          await writer.preserveEvent(
            'failure_${sequence.toString().padLeft(6, '0')}',
            raw.rawEvent(
              sequence: sequence,
              actionId: action.actionId,
              detectedFailure: failure,
              probe: failureProbe,
            ),
          );
          continue;
        }
        final commandEvidence = parsed.evidence!;
        failure = _validateCommandCorrelation(
          commandEvidence,
          setup.correlation,
          previousStateGeneration: previousStateGeneration,
          previousLogCursor: previousLogCursor,
          commandIds: commandIds,
          sequence: sequence,
        );
        previousStateGeneration = commandEvidence.stateGeneration;
        previousLogCursor = commandEvidence.logCursor;
        latestCommandEvidence = commandEvidence;

        final probe = await boundedHook(
          () => harnessController.probe(
            EnduranceProbeRequest(
              enduranceRunId: config.enduranceRunId,
              sequence: sequence,
              actionId: action.actionId,
              anchor: setup!.correlation,
            ),
          ),
          failureKind: EnduranceFailureKind.probeFailed,
          stage: 'per-step resource probe',
          sequence: sequence,
        );
        if (probe == null) {
          evidenceComplete = false;
          await writer.preserveEvent(
            'failure_${sequence.toString().padLeft(6, '0')}',
            raw.rawEvent(
              sequence: sequence,
              actionId: action.actionId,
              detectedFailure: failure,
            ),
          );
          continue;
        }
        latestProbe = probe;
        failure ??= _validateProbe(
          config: config,
          probe: probe,
          anchor: setup.correlation,
          expectedSequence: sequence,
        );
        if (failure != null) evidenceComplete = false;

        crashCount = math.max(crashCount, probe.crashCount);
        crossoverCount = math.max(crossoverCount, probe.crossoverCount);
        deadlockCount = math.max(deadlockCount, probe.deadlockCount);
        blockingSignalCount = math.max(
          blockingSignalCount,
          probe.blockingSignalCount,
        );
        memory.add(probe.memory.processRssBytes);
        if (action.requiresProgress) {
          if (probe.progressSignature == previousProgress ||
              commandEvidence.observation == 'no_effect' ||
              commandEvidence.observation == 'completed_same_state') {
            noProgressStreak++;
          } else {
            noProgressStreak = 0;
          }
        }
        previousProgress = probe.progressSignature;

        final stepFinishedUs = monotonicNow(sequence: sequence);
        final step = EnduranceStepRecord(
          sequence: sequence,
          actionId: action.actionId,
          mutating: action.mutating,
          requiresProgress: action.requiresProgress,
          argumentsSha256: jsonSha256(actualArguments),
          startedAtUtc: stepStartedAt,
          finishedAtUtc: clock.utcNow,
          elapsedUs: math.max(0, stepFinishedUs - stepStartedUs),
          command: commandEvidence,
          probe: probe,
          noProgressStreak: noProgressStreak,
          previousRecordSha256: lastRecordSha256,
        );
        final entry = await writer.preserveStep(step);
        lastRecordSha256 = entry.sha256;
        actionCount++;

        if (failure == null &&
            noProgressStreak >= config.limits.maximumConsecutiveNoProgress) {
          failure = detected(
            kind: EnduranceFailureKind.noProgress,
            owner: EnduranceFailureOwner.product,
            releaseBlocking: true,
            message:
                'The independent progress signature remained unchanged '
                'for $noProgressStreak required-progress actions.',
            sequence: sequence,
          );
        }
      }
    } on EnduranceArchiveException catch (error) {
      failure ??= detected(
        kind: EnduranceFailureKind.archiveIncomplete,
        owner: EnduranceFailureOwner.evidenceArchive,
        message: error.message,
        sequence: actionCount,
      );
      evidenceComplete = false;
    } on Object catch (error) {
      failure ??= detected(
        kind: EnduranceFailureKind.setupFailed,
        owner: EnduranceFailureOwner.harness,
        message:
            'The endurance harness failed unexpectedly '
            '(${error.runtimeType}).',
        sequence: actionCount,
      );
      evidenceComplete = false;
    } finally {
      if (activeStartedUs != null) {
        activeFinishedUs ??= monotonicNow(sequence: actionCount);
        activeFinishedAtUtc ??= startedAtUtc.add(
          Duration(microseconds: activeFinishedUs - startedUs),
        );
      }
      if (setup != null) {
        teardown = await boundedHook(
          () => harnessController.tearDown(
            config: config,
            anchor: setup!.correlation,
          ),
          failureKind: EnduranceFailureKind.teardownFailed,
          stage: 'teardown',
          sequence: actionCount,
        );
        if (teardown != null) {
          try {
            await writer.preserveEvent('teardown', <String, Object?>{
              'schemaVersion': enduranceArchiveSchemaVersion,
              'recordType': 'teardown',
              ...teardown.toJson(),
            });
          } on Object {
            evidenceComplete = false;
            failure ??= detected(
              kind: EnduranceFailureKind.archiveIncomplete,
              owner: EnduranceFailureOwner.evidenceArchive,
              message: 'Teardown evidence could not be preserved.',
              sequence: actionCount,
            );
          }
          final teardownIssue = _validateTeardown(config, setup, teardown);
          if (teardownIssue == null) {
            cleanTeardownProven = true;
          } else {
            evidenceComplete = false;
            failure ??= detected(
              kind: EnduranceFailureKind.teardownNotClean,
              owner: EnduranceFailureOwner.harness,
              message: teardownIssue,
              sequence: actionCount,
            );
          }
        }
      }
    }

    final finishedUs = monotonicNow(sequence: actionCount);
    final finishedAtUtc = clock.utcNow;
    final durationMs = activeStartedUs == null
        ? 0
        : math.max(
            0,
            ((activeFinishedUs ?? finishedUs) - activeStartedUs) ~/
                Duration.microsecondsPerMillisecond,
          );
    final memoryAssessment = memory.assess();
    if (failure == null && memoryAssessment.unboundedGrowthObserved) {
      failure = detected(
        kind: EnduranceFailureKind.unboundedMemoryGrowth,
        owner: EnduranceFailureOwner.product,
        releaseBlocking: true,
        message: 'RSS exceeded its bound with a sustained positive tail trend.',
        sequence: actionCount,
      );
    } else if (failure == null && memoryAssessment.boundExceeded) {
      failure = detected(
        kind: EnduranceFailureKind.memoryBoundExceeded,
        owner: EnduranceFailureOwner.product,
        releaseBlocking: true,
        message:
            'Positive resident-memory growth exceeded the preregistered '
            'bound.',
        sequence: actionCount,
      );
    }
    final targetReached = config.limits.targetReached(
      durationMs: durationMs,
      actionCount: actionCount,
    );
    if (failure == null && !targetReached) {
      failure = detected(
        kind: EnduranceFailureKind.hardBoundReached,
        owner: EnduranceFailureOwner.product,
        releaseBlocking: true,
        message: 'The run ended before either endurance target was reached.',
        sequence: actionCount,
      );
    }
    final status = switch (failure?.owner) {
      null => EnduranceRunStatus.completed,
      EnduranceFailureOwner.product => EnduranceRunStatus.productFailure,
      EnduranceFailureOwner.interruption => EnduranceRunStatus.interrupted,
      EnduranceFailureOwner.harness || EnduranceFailureOwner.evidenceArchive =>
        EnduranceRunStatus.harnessInvalid,
    };
    final componentStatus = config.mode == EnduranceRunMode.testOnly
        ? EnduranceComponentStatus.unmeasured
        : status == EnduranceRunStatus.completed &&
              targetReached &&
              evidenceComplete &&
              freshSetupProven &&
              cleanTeardownProven &&
              crashCount == 0 &&
              crossoverCount == 0 &&
              deadlockCount == 0 &&
              blockingSignalCount == 0 &&
              !memoryAssessment.boundExceeded &&
              !memoryAssessment.unboundedGrowthObserved
        ? EnduranceComponentStatus.pass
        : status == EnduranceRunStatus.productFailure
        ? EnduranceComponentStatus.fail
        : EnduranceComponentStatus.unmeasured;
    final outcome = EnduranceOutcome(
      enduranceRunId: config.enduranceRunId,
      configSha256: config.sha256,
      environmentSha256: config.environment.sha256,
      planSha256: config.plan.sha256,
      mode: config.mode,
      status: status,
      componentStatus: componentStatus,
      releaseClaimable: false,
      startedAtUtc: startedAtUtc,
      finishedAtUtc: finishedAtUtc,
      measurementStartedAtUtc: activeStartedAtUtc,
      measurementFinishedAtUtc: activeFinishedAtUtc,
      durationMs: durationMs,
      actionCount: actionCount,
      targetReached: targetReached,
      evidenceComplete: evidenceComplete && cleanTeardownProven,
      freshSetupProven: freshSetupProven,
      cleanTeardownProven: cleanTeardownProven,
      crashCount: crashCount,
      crossoverCount: crossoverCount,
      deadlockCount: deadlockCount,
      blockingSignalCount: blockingSignalCount,
      failure: failure,
      memory: memoryAssessment,
      finalCorrelation: latestProbe?.correlation ?? setup?.correlation,
      finalRecordSha256: lastRecordSha256,
      inventory: writer.inventory,
    );
    return writer.finalize(outcome);
  }

  Future<_RawExecution> _execute(
    List<String> arguments, {
    required Duration timeout,
    int? sequence,
  }) async {
    try {
      final result = await commandExecutor
          .execute(arguments: arguments, timeout: timeout)
          .timeout(timeout);
      if (result.timedOut) {
        return _RawExecution.failure(
          result,
          EnduranceFailure(
            kind: EnduranceFailureKind.deadlock,
            owner: EnduranceFailureOwner.product,
            releaseBlocking: true,
            message:
                'A bounded Scout command timed out; dispatch may be '
                'uncertain and must not be retried.',
            sequence: sequence,
          ),
        );
      }
      return _RawExecution.result(result);
    } on TimeoutException {
      return _RawExecution.failure(
        null,
        EnduranceFailure(
          kind: EnduranceFailureKind.deadlock,
          owner: EnduranceFailureOwner.product,
          releaseBlocking: true,
          message:
              'The Scout executor did not return within the bounded '
              'deadline; dispatch is unknown and will not be retried.',
          sequence: sequence,
        ),
      );
    } on Object catch (error) {
      return _RawExecution.failure(
        null,
        EnduranceFailure(
          kind: EnduranceFailureKind.commandLaunchFailed,
          owner: EnduranceFailureOwner.harness,
          releaseBlocking: false,
          message:
              'The harness could not launch the Scout command process '
              '(${error.runtimeType}).',
          sequence: sequence,
        ),
      );
    }
  }
}

String? _validateSetup(
  EnduranceConfig config,
  EnduranceSetupObservation setup,
) {
  if (!setup.freshSetup) return 'The setup hook did not prove a fresh reset.';
  if (setup.setupFixtureSha256 != config.harness.setupFixtureSha256) {
    return 'The setup fixture digest differs from the preregistered fixture.';
  }
  if (setup.correlation.sessionName != config.sessionName) {
    return 'The setup hook anchored a different Scout session.';
  }
  return null;
}

String? _validateTeardown(
  EnduranceConfig config,
  EnduranceSetupObservation setup,
  EnduranceTeardownObservation teardown,
) {
  if (!teardown.attempted || !teardown.clean) {
    return 'The teardown hook did not prove a clean teardown.';
  }
  if (teardown.teardownFixtureSha256 != config.harness.teardownFixtureSha256) {
    return 'The teardown fixture digest differs from the preregistered '
        'fixture.';
  }
  if (!_sameCorrelation(teardown.anchorCorrelation, setup.correlation)) {
    return 'Teardown did not apply to the exact anchored session/run/runtime.';
  }
  return null;
}

class _ParsedCommand {
  const _ParsedCommand({this.evidence, this.failure});

  final EnduranceCommandEvidence? evidence;
  final EnduranceFailure? failure;
}

_ParsedCommand _parseCommandEvidence(
  ScoutCommandResult result, {
  required String expectedCommandName,
  required int maximumOutputBytes,
  bool mutation = false,
  int? sequence,
}) {
  final stdoutBytes = utf8.encode(result.stdout);
  final stderrBytes = utf8.encode(result.stderr);
  EnduranceFailure fail(
    EnduranceFailureKind kind,
    String message, {
    bool releaseBlocking = true,
  }) => EnduranceFailure(
    kind: kind,
    owner: EnduranceFailureOwner.product,
    releaseBlocking: releaseBlocking,
    message: message,
    sequence: sequence,
  );
  if (result.outputTruncated ||
      stdoutBytes.length > maximumOutputBytes ||
      stderrBytes.length > maximumOutputBytes) {
    return _ParsedCommand(
      failure: fail(
        EnduranceFailureKind.outputTruncated,
        'Scout command output exceeded its preregistered evidence bound.',
      ),
    );
  }
  Map<String, Object?> json;
  try {
    json = expectJsonObject(
      jsonDecode(utf8.decode(stdoutBytes, allowMalformed: false)),
      r'$',
    );
  } on Object {
    return _ParsedCommand(
      failure: fail(
        EnduranceFailureKind.malformedResponse,
        'Scout stdout was not one strict UTF-8 JSON response object.',
      ),
    );
  }
  if (json['messageType'] != 'response' ||
      json['ok'] is! bool ||
      json['commandId'] is! String ||
      (json['commandId'] as String).isEmpty ||
      json['commandName'] != expectedCommandName ||
      json['runId'] is! String ||
      json['runtimeInstanceId'] is! String ||
      json['stateGeneration'] is! int ||
      (json['stateGeneration'] as int) < 0 ||
      json['logCursor'] is! int ||
      (json['logCursor'] as int) < 0) {
    return _ParsedCommand(
      failure: fail(
        EnduranceFailureKind.missingSafetyEvidence,
        'Scout omitted required command/run/runtime/state/log correlation.',
      ),
    );
  }
  final payloadBounds = json['payloadBounds'];
  if (payloadBounds is! Map ||
      payloadBounds['truncated'] != false ||
      payloadBounds['safetyDisposition'] != 'complete' ||
      json['safetyEvidenceStatus'] != 'complete') {
    return _ParsedCommand(
      failure: fail(
        EnduranceFailureKind.missingSafetyEvidence,
        'Scout did not preserve a complete bounded safety envelope.',
      ),
    );
  }
  PerformancePhaseTimings phases;
  try {
    phases = _parsePhases(json['timings']);
  } on Object {
    return _ParsedCommand(
      failure: fail(
        EnduranceFailureKind.missingSafetyEvidence,
        'Scout did not report all eight independently measured phases.',
      ),
    );
  }
  final facts = _SafetyFactScan(json);
  if (facts.uncertainDispatch) {
    return _ParsedCommand(
      failure: fail(
        EnduranceFailureKind.uncertainDispatch,
        'Scout reported an uncertain dispatch; the runner abstained from '
        'retrying.',
      ),
    );
  }
  if (facts.blockingSignal) {
    return _ParsedCommand(
      failure: fail(
        EnduranceFailureKind.blockingRuntimeSignal,
        'Scout reported a fresh blocking runtime signal.',
      ),
    );
  }
  if (facts.failedPostcondition) {
    return _ParsedCommand(
      failure: fail(
        EnduranceFailureKind.postconditionFailed,
        'The planned action failed its same-call postcondition.',
      ),
    );
  }
  if (facts.missingObservation) {
    return _ParsedCommand(
      failure: fail(
        EnduranceFailureKind.missingSafetyEvidence,
        'Scout reported unavailable observation or runtime-health evidence.',
      ),
    );
  }
  if (mutation && facts.dispatch != 'dispatched') {
    return _ParsedCommand(
      failure: fail(
        EnduranceFailureKind.missingSafetyEvidence,
        'A mutating step did not close dispatch as `dispatched`.',
      ),
    );
  }
  if (mutation &&
      (facts.transport != 'ok' ||
          !const <String>{
            'changed',
            'completed_same_state',
            'no_effect',
          }.contains(facts.observation) ||
          !const <String>{
            'postcondition_met',
            'postcondition_not_requested',
          }.contains(facts.postcondition) ||
          facts.runtimeHealth != 'runtime_clean')) {
    return _ParsedCommand(
      failure: fail(
        EnduranceFailureKind.missingSafetyEvidence,
        'A mutating step did not close every outcome dimension with a clean '
        'supported value.',
      ),
    );
  }
  final structuredError = json['structuredError'];
  final structuredErrorCode = structuredError is Map
      ? structuredError['code']?.toString()
      : null;
  final evidence = EnduranceCommandEvidence(
    ok: json['ok'] as bool,
    commandId: json['commandId'] as String,
    commandName: expectedCommandName,
    runId: json['runId'] as String,
    runtimeInstanceId: json['runtimeInstanceId'] as String,
    stateGeneration: json['stateGeneration'] as int,
    logCursor: json['logCursor'] as int,
    phaseTimings: phases,
    executorElapsedUs: result.elapsedMs * Duration.microsecondsPerMillisecond,
    stdoutBytes: stdoutBytes.length,
    stderrBytes: stderrBytes.length,
    stdoutSha256: sha256Bytes(stdoutBytes),
    stderrSha256: sha256Bytes(stderrBytes),
    stdout: result.stdout,
    stderr: result.stderr,
    transport: facts.transport,
    dispatch: facts.dispatch,
    observation: facts.observation,
    postcondition: facts.postcondition,
    runtimeHealth: facts.runtimeHealth,
    structuredErrorCode: structuredErrorCode,
  );
  if (!result.succeeded || !evidence.ok) {
    return _ParsedCommand(
      evidence: evidence,
      failure: fail(
        EnduranceFailureKind.commandFailed,
        'Scout rejected or failed the planned endurance action'
        '${structuredErrorCode == null ? '' : ' ($structuredErrorCode)'}.',
      ),
    );
  }
  return _ParsedCommand(evidence: evidence);
}

PerformancePhaseTimings _parsePhases(Object? value) {
  final timings = expectJsonObject(value, r'$.timings');
  final rawPhases = expectJsonObject(timings['phases'], r'$.timings.phases');
  int phase(String name) {
    final raw = expectJsonObject(
      rawPhases[name],
      r'$.timings.phases.'
      '$name',
    );
    if (raw['status'] != 'measured') {
      throw FormatException('Phase $name is not measured.');
    }
    final elapsedMs = expectJsonInt(
      raw['elapsedMs'],
      r'$.timings.phases.'
      '$name.elapsedMs',
      minimum: 0,
    );
    return elapsedMs * Duration.microsecondsPerMillisecond;
  }

  return PerformancePhaseTimings(
    connectUs: phase('connect'),
    snapshotUs: phase('snapshot'),
    matchUs: phase('match'),
    dispatchUs: phase('dispatch'),
    settleUs: phase('settle'),
    deltaUs: phase('delta'),
    logsUs: phase('logs'),
    serializeUs: phase('serialize'),
  );
}

EnduranceFailure? _validateCommandCorrelation(
  EnduranceCommandEvidence evidence,
  EnduranceCorrelation anchor, {
  required int? previousStateGeneration,
  required int? previousLogCursor,
  required Set<String> commandIds,
  required int sequence,
}) {
  EnduranceFailure fail(EnduranceFailureKind kind, String message) =>
      EnduranceFailure(
        kind: kind,
        owner: EnduranceFailureOwner.product,
        releaseBlocking: true,
        message: message,
        sequence: sequence,
      );
  if (evidence.runId != anchor.runId) {
    return fail(
      EnduranceFailureKind.runCrossover,
      'Scout returned evidence from a different run.',
    );
  }
  if (evidence.runtimeInstanceId != anchor.runtimeInstanceId) {
    return fail(
      EnduranceFailureKind.runtimeCrossover,
      'Scout returned evidence from a different runtime.',
    );
  }
  if (!commandIds.add(evidence.commandId)) {
    return fail(
      EnduranceFailureKind.missingSafetyEvidence,
      'Scout reused a command identity within the endurance run.',
    );
  }
  if (previousStateGeneration != null &&
      evidence.stateGeneration < previousStateGeneration) {
    return fail(
      EnduranceFailureKind.stateRegressed,
      'Scout state generation regressed.',
    );
  }
  if (previousLogCursor != null && evidence.logCursor < previousLogCursor) {
    return fail(
      EnduranceFailureKind.logCursorRegressed,
      'Scout log cursor regressed.',
    );
  }
  return null;
}

EnduranceFailure? _validateProbe({
  required EnduranceConfig config,
  required EnduranceResourceProbe probe,
  required EnduranceCorrelation anchor,
  required int expectedSequence,
}) {
  EnduranceFailure harness(EnduranceFailureKind kind, String message) =>
      EnduranceFailure(
        kind: kind,
        owner: EnduranceFailureOwner.harness,
        releaseBlocking: false,
        message: message,
        sequence: expectedSequence,
      );
  EnduranceFailure product(EnduranceFailureKind kind, String message) =>
      EnduranceFailure(
        kind: kind,
        owner: EnduranceFailureOwner.product,
        releaseBlocking: true,
        message: message,
        sequence: expectedSequence,
      );
  if (probe.sequence != expectedSequence) {
    return harness(
      EnduranceFailureKind.probeFailed,
      'The resource probe sequence does not match the requested step.',
    );
  }
  if (probe.correlation.sessionName != anchor.sessionName) {
    return product(
      EnduranceFailureKind.sessionCrossover,
      'The independent probe observed another Scout session.',
    );
  }
  if (probe.correlation.runId != anchor.runId) {
    return product(
      EnduranceFailureKind.runCrossover,
      'The independent probe observed another run.',
    );
  }
  if (probe.correlation.runtimeInstanceId != anchor.runtimeInstanceId) {
    return product(
      EnduranceFailureKind.runtimeCrossover,
      'The independent probe observed another runtime.',
    );
  }
  if (probe.correlation.processId != anchor.processId) {
    return product(
      EnduranceFailureKind.processCrossover,
      'The independent probe observed another app process.',
    );
  }
  if (probe.correlation.fixtureGeneration != anchor.fixtureGeneration) {
    return product(
      EnduranceFailureKind.sessionCrossover,
      'The independent fixture generation changed during the run.',
    );
  }
  if (!_provenanceMatches(probe.cpu.provenance, config.collectors.cpu) ||
      !_provenanceMatches(probe.memory.provenance, config.collectors.memory) ||
      !_provenanceMatches(
        probe.frameTime.provenance,
        config.collectors.frameTime,
      )) {
    return harness(
      EnduranceFailureKind.probeFailed,
      'A resource probe did not use the preregistered collector provenance.',
    );
  }
  if (!probe.processAlive || probe.crashCount > 0) {
    return product(
      EnduranceFailureKind.appCrash,
      'The independent probe observed app/runtime death.',
    );
  }
  if (probe.crossoverCount > 0) {
    return product(
      EnduranceFailureKind.sessionCrossover,
      'The independent probe recorded cross-session or cross-runtime access.',
    );
  }
  if (probe.deadlockCount > 0) {
    return product(
      EnduranceFailureKind.deadlock,
      'The independent probe recorded a deadlock.',
    );
  }
  if (probe.blockingSignalCount > 0) {
    return product(
      EnduranceFailureKind.blockingRuntimeSignal,
      'The independent probe recorded a fresh blocking runtime signal.',
    );
  }
  return null;
}

bool _provenanceMatches(
  MeasurementProvenance actual,
  EnduranceCollectorPin expected,
) =>
    actual.source == expected.source &&
    actual.method == expected.method &&
    actual.collectorVersion == expected.collectorVersion &&
    actual.target == expected.target;

bool _sameCorrelation(
  EnduranceCorrelation first,
  EnduranceCorrelation second,
) =>
    first.sessionName == second.sessionName &&
    first.runId == second.runId &&
    first.runtimeInstanceId == second.runtimeInstanceId &&
    first.processId == second.processId &&
    first.fixtureGeneration == second.fixtureGeneration;

class _SafetyFactScan {
  _SafetyFactScan(Object? value) {
    _visit(value, 0);
  }

  String? dispatch;
  String? transport;
  String? observation;
  String? postcondition;
  String? runtimeHealth;
  bool uncertainDispatch = false;
  bool blockingSignal = false;
  bool missingObservation = false;
  bool failedPostcondition = false;
  var _visited = 0;

  void _visit(Object? value, int depth) {
    if (depth > 32 || _visited++ > 100000) {
      missingObservation = true;
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString();
        final item = entry.value;
        if (key == 'transport' && item is String) transport ??= item;
        if (key == 'dispatch' && item is String) {
          dispatch ??= item;
          if (item == 'dispatch_outcome_unknown' || item == 'outcome_unknown') {
            uncertainDispatch = true;
          }
        }
        if (key == 'observation' && item is String) {
          observation ??= item;
          if (item == 'observation_unavailable') missingObservation = true;
        }
        if (key == 'postcondition' && item is String) {
          postcondition ??= item;
          if (item == 'postcondition_not_met') failedPostcondition = true;
        }
        if (key == 'runtimeHealth' && item is String) {
          runtimeHealth ??= item;
          if (item == 'runtime_blocked') blockingSignal = true;
          if (item == 'runtime_health_unknown') missingObservation = true;
        }
        if (key == 'blocking' && item == true) blockingSignal = true;
        _visit(item, depth + 1);
      }
    } else if (value is List) {
      for (final item in value) {
        _visit(item, depth + 1);
      }
    }
  }
}

class _RawExecution {
  const _RawExecution._({this.result, this.failure});

  factory _RawExecution.result(ScoutCommandResult result) =>
      _RawExecution._(result: result);

  factory _RawExecution.failure(
    ScoutCommandResult? result,
    EnduranceFailure failure,
  ) => _RawExecution._(result: result, failure: failure);

  final ScoutCommandResult? result;
  final EnduranceFailure? failure;

  Map<String, Object?> rawEvent({
    required int sequence,
    required String actionId,
    EnduranceFailure? detectedFailure,
    EnduranceResourceProbe? probe,
  }) {
    final command = result?.toToolEvent();
    if (command != null) {
      final arguments = command.remove('arguments');
      command['argumentCount'] = arguments is List ? arguments.length : 0;
      command['argumentsSha256'] = jsonSha256(arguments ?? const <Object?>[]);
    }
    return <String, Object?>{
      'schemaVersion': enduranceArchiveSchemaVersion,
      'recordType': 'failed_command',
      'sequence': sequence,
      'actionId': actionId,
      'failure': (detectedFailure ?? failure)?.toJson(),
      'command': command,
      'probe': probe?.toJson(),
    };
  }
}

class _BoundedMemoryAssessor {
  _BoundedMemoryAssessor(this.limits);

  final EnduranceLimits limits;
  final List<int> _head = <int>[];
  final ListQueue<int> _tail = ListQueue<int>();
  var _sampleCount = 0;
  var _peak = 0;

  void add(int rssBytes) {
    if (rssBytes < 0) throw ArgumentError.value(rssBytes, 'rssBytes');
    _sampleCount++;
    _peak = math.max(_peak, rssBytes);
    if (_head.length < limits.memoryWindowSamples) _head.add(rssBytes);
    _tail.addLast(rssBytes);
    while (_tail.length > limits.memoryWindowSamples) {
      _tail.removeFirst();
    }
  }

  MemoryGrowthAssessment assess() {
    final headMedian = _median(_head);
    final tailValues = _tail.toList(growable: false);
    final tailMedian = _median(tailValues);
    final growth = math.max(0, tailMedian - headMedian);
    final slope = _leastSquaresSlope(tailValues);
    final monotonicRatio = _monotonicIncreaseRatio(tailValues);
    final boundExceeded = growth > limits.maximumPositiveRssGrowthBytes;
    final unbounded =
        boundExceeded &&
        slope > limits.maximumTailSlopeBytesPerAction &&
        monotonicRatio >= 0.75;
    return MemoryGrowthAssessment(
      sampleCount: _sampleCount,
      windowSampleCount: tailValues.length,
      startMedianRssBytes: headMedian,
      endMedianRssBytes: tailMedian,
      positiveGrowthBytes: growth,
      peakRssBytes: _peak,
      tailSlopeBytesPerAction: slope,
      tailMonotonicIncreaseRatio: monotonicRatio,
      maximumPositiveGrowthBytes: limits.maximumPositiveRssGrowthBytes,
      maximumTailSlopeBytesPerAction: limits.maximumTailSlopeBytesPerAction,
      boundExceeded: boundExceeded,
      unboundedGrowthObserved: unbounded,
    );
  }
}

int _median(List<int> values) {
  if (values.isEmpty) return 0;
  final sorted = List<int>.from(values)..sort();
  final middle = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[middle];
  return (sorted[middle - 1] + sorted[middle]) ~/ 2;
}

double _leastSquaresSlope(List<int> values) {
  if (values.length < 3) return 0;
  final meanX = (values.length - 1) / 2;
  final meanY = values.reduce((a, b) => a + b) / values.length;
  var numerator = 0.0;
  var denominator = 0.0;
  for (var index = 0; index < values.length; index++) {
    final dx = index - meanX;
    numerator += dx * (values[index] - meanY);
    denominator += dx * dx;
  }
  if (denominator == 0) return 0;
  return numerator / denominator;
}

double _monotonicIncreaseRatio(List<int> values) {
  if (values.length < 2) return 0;
  var increases = 0;
  for (var index = 1; index < values.length; index++) {
    if (values[index] > values[index - 1]) increases++;
  }
  return increases / (values.length - 1);
}
