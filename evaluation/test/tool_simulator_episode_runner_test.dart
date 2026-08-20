import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

void main() {
  test(
    'runner uses only the agent projection and independent oracle truth',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'flutter_scout_tool_simulator_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final provider = _CapturingPlanProvider(_plan(claimedSuccess: true));
      final executor = _FakeScoutExecutor(
        actionResult: _commandResult(const <String>[
          'tap',
          'btn.save_supplier',
        ], stdout: '{"ok":false,"claimedState":"unchanged"}'),
      );
      final oracle = _SequenceOracleClient(
        preReset: _observation(generation: 4),
        reset: _observation(
          generation: 5,
          operation: 'reset',
          resetPerformed: true,
        ),
        resetConfirmation: _observation(generation: 5),
        finalState: _observation(
          generation: 5,
          supplierNames: const <String>['Benchmark Supplier'],
        ),
      );

      final run =
          await ToolSimulatorEpisodeRunner(
            oracleClient: oracle,
            commandExecutor: executor,
            archive: RawEpisodeArchive(temporary),
          ).run(
            manifest: _manifest(),
            episodeId: 'supplier-episode-1',
            condition: 'candidate',
            vmServiceUri: 'ws://127.0.0.1:8181/example/ws',
            planProvider: provider,
          );

      expect(run.episode.passed, isTrue);
      expect(run.episode.oracle.successPredicatesMet, isTrue);
      expect(run.archiveFile.existsSync(), isTrue);
      expect(executor.executed, hasLength(3));
      expect(oracle.resetCalls, 2);
      expect(oracle.stateReads, 4);
      final projection = jsonEncode(provider.received!.toJson());
      expect(projection, isNot(contains('hiddenHarness')));
      expect(projection, isNot(contains('"variant":')));
      expect(projection, isNot(contains(supplierWorkflowOracleStateMethod)));
      expect(projection, isNot(contains(supplierWorkflowOracleResetMethod)));
      expect(projection, isNot(contains('forbiddenWrongActionCount')));

      final nonHarness = jsonEncode(<String, Object?>{
        'agent': run.episode.raw.agentEvents,
        'tool': run.episode.raw.toolEvents,
      });
      expect(nonHarness, isNot(contains(supplierWorkflowOracleChannel)));
      expect(nonHarness, isNot(contains('forbiddenDuplicateActionCount')));
      expect(nonHarness, isNot(contains('resetGeneration')));
      expect(
        jsonEncode(run.episode.raw.harnessEvents),
        contains(supplierWorkflowOracleChannel),
      );
      expect(
        run.episode.raw.harnessEvents.map((event) => event['type']),
        containsAll(<String>[
          'oracle_final_state',
          'oracle_teardown_reset',
          'oracle_teardown_confirmation',
        ]),
      );
    },
  );

  test(
    'false success is caught when Scout output says ok but oracle does not',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'flutter_scout_tool_simulator_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final run =
          await ToolSimulatorEpisodeRunner(
            oracleClient: _SequenceOracleClient(
              preReset: _observation(generation: 0),
              reset: _observation(
                generation: 1,
                operation: 'reset',
                resetPerformed: true,
              ),
              resetConfirmation: _observation(generation: 1),
              finalState: _observation(generation: 1),
            ),
            commandExecutor: _FakeScoutExecutor(
              actionResult: _commandResult(const <String>[
                'tap',
                'btn.save_supplier',
              ], stdout: '{"ok":true,"result":"changed"}'),
            ),
            archive: RawEpisodeArchive(temporary),
          ).run(
            manifest: _manifest(),
            episodeId: 'supplier-episode-1',
            condition: 'candidate',
            vmServiceUri: 'ws://127.0.0.1:8181/example/ws',
            planProvider: StaticToolSimulatorPlanProvider(
              _plan(claimedSuccess: true),
            ),
          );

      expect(run.episode.passed, isFalse);
      expect(run.episode.failure?.category, FailureCategory.safetyFalseSuccess);
      expect(run.episode.failure?.severity, FailureSeverity.releaseBlocking);
    },
  );

  test(
    'over-budget plan dispatches no actions and is archived as failure',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'flutter_scout_tool_simulator_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final executor = _FakeScoutExecutor(
        actionResult: _commandResult(const <String>['inspect']),
      );
      final actions = List<ToolSimulatorAction>.generate(
        4,
        (_) => ToolSimulatorAction(const <String>['inspect']),
      );
      final run =
          await ToolSimulatorEpisodeRunner(
            oracleClient: _SequenceOracleClient(
              preReset: _observation(generation: 0),
              reset: _observation(
                generation: 1,
                operation: 'reset',
                resetPerformed: true,
              ),
              resetConfirmation: _observation(generation: 1),
              finalState: _observation(generation: 1),
            ),
            commandExecutor: executor,
            archive: RawEpisodeArchive(temporary),
          ).run(
            manifest: _manifest(maxActions: 3),
            episodeId: 'supplier-episode-1',
            condition: 'candidate',
            vmServiceUri: 'ws://127.0.0.1:8181/example/ws',
            planProvider: StaticToolSimulatorPlanProvider(
              ToolSimulatorPlan(
                episodeId: 'supplier-episode-1',
                condition: 'candidate',
                agentClaimedSuccess: false,
                actions: actions,
                reportedTokens: 20,
              ),
            ),
          );

      expect(executor.executed, isEmpty);
      expect(run.episode.passed, isFalse);
      expect(run.episode.oracle.budgetRespected, isFalse);
      expect(run.episode.failure?.category, FailureCategory.agent);
      expect(run.archiveFile.existsSync(), isTrue);
    },
  );

  test(
    'reset generation mismatch invalidates the harness before planning',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'flutter_scout_tool_simulator_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final provider = _CapturingPlanProvider(_plan(claimedSuccess: false));
      final oracle = _SequenceOracleClient(
        preReset: _observation(generation: 3),
        reset: _observation(
          generation: 3,
          operation: 'reset',
          resetPerformed: true,
        ),
        resetConfirmation: _observation(generation: 3),
        finalState: _observation(generation: 3),
      );
      final run =
          await ToolSimulatorEpisodeRunner(
            oracleClient: oracle,
            commandExecutor: _FakeScoutExecutor(
              actionResult: _commandResult(const <String>['inspect']),
            ),
            archive: RawEpisodeArchive(temporary),
          ).run(
            manifest: _manifest(),
            episodeId: 'supplier-episode-1',
            condition: 'candidate',
            vmServiceUri: 'ws://127.0.0.1:8181/example/ws',
            planProvider: provider,
          );

      expect(provider.received, isNull);
      expect(oracle.resetCalls, 2);
      expect(oracle.stateReads, 4);
      expect(run.episode.validEpisode, isFalse);
      expect(run.episode.failure?.category, FailureCategory.harnessInvalid);
    },
  );

  test(
    'teardown generation mismatch invalidates a successful task episode',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'flutter_scout_tool_simulator_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final oracle = _SequenceOracleClient(
        preReset: _observation(generation: 0),
        reset: _observation(
          generation: 1,
          operation: 'reset',
          resetPerformed: true,
        ),
        resetConfirmation: _observation(generation: 1),
        finalState: _observation(
          generation: 1,
          supplierNames: const <String>['Benchmark Supplier'],
        ),
        teardownReset: _observation(
          generation: 1,
          operation: 'reset',
          resetPerformed: true,
        ),
        teardownConfirmation: _observation(generation: 1),
      );

      final run =
          await ToolSimulatorEpisodeRunner(
            oracleClient: oracle,
            commandExecutor: _FakeScoutExecutor(
              actionResult: _commandResult(const <String>[
                'tap',
                'btn.save_supplier',
              ]),
            ),
            archive: RawEpisodeArchive(temporary),
          ).run(
            manifest: _manifest(),
            episodeId: 'supplier-episode-1',
            condition: 'candidate',
            vmServiceUri: 'ws://127.0.0.1:8181/example/ws',
            planProvider: StaticToolSimulatorPlanProvider(
              _plan(claimedSuccess: true),
            ),
          );

      expect(oracle.resetCalls, 2);
      expect(oracle.stateReads, 4);
      expect(run.episode.validEpisode, isFalse);
      expect(run.episode.passed, isFalse);
      expect(run.episode.failure?.category, FailureCategory.harnessInvalid);
      final harnessEvents = run.episode.raw.harnessEvents;
      final finalState = harnessEvents.singleWhere(
        (event) => event['type'] == 'oracle_final_state',
      );
      final teardownReset = harnessEvents.singleWhere(
        (event) => event['type'] == 'oracle_teardown_reset',
      );
      expect(
        ((finalState['observation']! as Map<String, Object?>)['state']!
            as Map<String, Object?>)['supplierNames'],
        const <String>['Benchmark Supplier'],
      );
      expect(
        ((teardownReset['observation']! as Map<String, Object?>)['state']!
            as Map<String, Object?>)['supplierNames'],
        isEmpty,
      );
    },
  );

  test('the concrete slice rejects private and hidden manifests', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'flutter_scout_tool_simulator_',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final runner = ToolSimulatorEpisodeRunner(
      oracleClient: _SequenceOracleClient(
        preReset: _observation(),
        reset: _observation(
          generation: 1,
          operation: 'reset',
          resetPerformed: true,
        ),
        resetConfirmation: _observation(generation: 1),
        finalState: _observation(generation: 1),
      ),
      commandExecutor: _FakeScoutExecutor(
        actionResult: _commandResult(const <String>['inspect']),
      ),
      archive: RawEpisodeArchive(temporary),
    );

    await expectLater(
      runner.run(
        manifest: _manifest(split: BenchmarkSplit.privateValidation),
        episodeId: 'supplier-episode-1',
        condition: 'candidate',
        vmServiceUri: 'ws://127.0.0.1:8181/example/ws',
        planProvider: StaticToolSimulatorPlanProvider(
          _plan(claimedSuccess: false),
        ),
      ),
      throwsArgumentError,
    );
  });
}

TaskManifest _manifest({
  int maxActions = 6,
  BenchmarkSplit split = BenchmarkSplit.publicDevelopment,
}) => TaskManifest(
  taskId: 'supplier-add.variant-1',
  templateId: 'supplier-add',
  split: split,
  agentVisible: AgentTaskDefinition(
    instruction:
        'Add exactly one supplier named "Benchmark Supplier" and leave the '
        'dialog closed.',
    allowedTools: const <String>['flutter-scout'],
    budget: TaskBudget(
      maxActions: maxActions,
      maxWallTimeMs: 10000,
      maxTokens: 100,
    ),
  ),
  hiddenHarness: HiddenHarnessDefinition(
    oracleId: supplierWorkflowOracleId,
    setupFixture: supplierWorkflowSetupFixture,
    successPredicateIds: const <String>[
      'predicate.supplier-added-once',
      'predicate.supplier-modal-closed',
    ],
    forbiddenPredicateIds: const <String>[
      'predicate.duplicate-action',
      'predicate.wrong-action',
    ],
    teardownFixture: supplierWorkflowTeardownFixture,
  ),
  variant: TaskVariant(
    variantId: 'variant-1',
    seed: 123,
    parameters: const <String, Object?>{
      'expectedSupplierName': 'Benchmark Supplier',
    },
  ),
);

ToolSimulatorPlan _plan({required bool claimedSuccess}) => ToolSimulatorPlan(
  episodeId: 'supplier-episode-1',
  condition: 'candidate',
  agentClaimedSuccess: claimedSuccess,
  reportedTokens: 20,
  actions: <ToolSimulatorAction>[
    ToolSimulatorAction(const <String>['tap', 'btn.add_supplier']),
    ToolSimulatorAction(const <String>[
      'input',
      'field.supplier_name',
      'Benchmark Supplier',
    ]),
    ToolSimulatorAction(const <String>['tap', 'btn.save_supplier']),
  ],
);

SupplierOracleObservation _observation({
  int generation = 0,
  String operation = 'state',
  bool resetPerformed = false,
  List<String> supplierNames = const <String>[],
  int duplicateActions = 0,
  int wrongActions = 0,
}) => SupplierOracleObservation(
  operation: operation,
  requestId: 'request-$operation-$generation',
  runtimeId: 'runtime-test',
  workflowAttached: true,
  resetGeneration: generation,
  resetPerformed: resetPerformed,
  state: SupplierOracleState(
    modalOpen: false,
    supplierAdditionCount: supplierNames.length,
    supplierNames: supplierNames,
    forbiddenDuplicateActionCount: duplicateActions,
    forbiddenWrongActionCount: wrongActions,
  ),
);

ScoutCommandResult _commandResult(
  List<String> arguments, {
  String stdout = '{"ok":true}',
}) => ScoutCommandResult(
  arguments: arguments,
  exitCode: 0,
  stdout: stdout,
  stderr: '',
  elapsedMs: 1,
  timedOut: false,
  outputTruncated: false,
);

class _CapturingPlanProvider implements ToolSimulatorPlanProvider {
  _CapturingPlanProvider(this.plan);

  final ToolSimulatorPlan plan;
  AgentTaskView? received;

  @override
  Future<ToolSimulatorPlan> createPlan(AgentTaskView agentTask) async {
    received = agentTask;
    return plan;
  }
}

class _FakeScoutExecutor implements ScoutCommandExecutor {
  _FakeScoutExecutor({required this.actionResult});

  final ScoutCommandResult actionResult;
  final List<List<String>> executed = <List<String>>[];

  @override
  Future<ScoutCommandResult> attach({
    required String vmServiceUri,
    required Duration timeout,
  }) async => _commandResult(<String>['attach', '--debug-url', vmServiceUri]);

  @override
  Future<ScoutCommandResult> execute({
    required List<String> arguments,
    required Duration timeout,
  }) async {
    executed.add(arguments);
    return ScoutCommandResult(
      arguments: arguments,
      exitCode: actionResult.exitCode,
      stdout: actionResult.stdout,
      stderr: actionResult.stderr,
      elapsedMs: actionResult.elapsedMs,
      timedOut: actionResult.timedOut,
      outputTruncated: actionResult.outputTruncated,
    );
  }
}

class _SequenceOracleClient implements SupplierOracleClient {
  _SequenceOracleClient({
    required this.preReset,
    required SupplierOracleObservation reset,
    required this.resetConfirmation,
    required this.finalState,
    SupplierOracleObservation? teardownReset,
    SupplierOracleObservation? teardownConfirmation,
  }) : resetObservation = reset,
       teardownResetObservation =
           teardownReset ??
           _observation(
             generation: finalState.resetGeneration + 1,
             operation: 'reset',
             resetPerformed: true,
           ),
       teardownConfirmationObservation =
           teardownConfirmation ??
           _observation(generation: finalState.resetGeneration + 1);

  final SupplierOracleObservation preReset;
  final SupplierOracleObservation resetObservation;
  final SupplierOracleObservation resetConfirmation;
  final SupplierOracleObservation finalState;
  final SupplierOracleObservation teardownResetObservation;
  final SupplierOracleObservation teardownConfirmationObservation;
  var _stateReads = 0;
  var _resetCalls = 0;

  int get stateReads => _stateReads;
  int get resetCalls => _resetCalls;

  @override
  Future<SupplierOracleObservation> readState() async =>
      switch (_stateReads++) {
        0 => preReset,
        1 => resetConfirmation,
        2 => finalState,
        _ => teardownConfirmationObservation,
      };

  @override
  Future<SupplierOracleObservation> reset({
    Map<String, Object?>? publicFixture,
  }) async => switch (_resetCalls++) {
    0 => resetObservation,
    _ => teardownResetObservation,
  };
}
