import '../json_support.dart';
import '../oracle.dart';
import '../public_fixture.dart';
import '../task_manifest.dart';

const int toolSimulatorPlanSchemaVersion = 1;
const int supplierOracleObservationSchemaVersion = 1;
const String supplierWorkflowOracleId = 'oracle.supplier-workflow-v1';
const String supplierWorkflowSetupFixture = 'setup.supplier-clean-reset';
const String supplierWorkflowTeardownFixture = 'teardown.supplier-reset';
const String supplierWorkflowOracleChannel = 'supplier_workflow_oracle_v1';
const String supplierWorkflowOracleStateMethod =
    'ext.flutter_scout_evaluator.supplier_state';
const String supplierWorkflowOracleResetMethod =
    'ext.flutter_scout_evaluator.supplier_reset';

const Set<String> _supplierWorkflowCommands = <String>{
  'inspect',
  'tap',
  'tap-text',
  'input',
  'fill',
  'wait',
  'long-press',
  'scroll',
  'scroll-to',
  'swipe',
  'back',
};

class ToolSimulatorAction {
  ToolSimulatorAction(Iterable<String> arguments)
    : arguments = List<String>.unmodifiable(arguments) {
    if (this.arguments.isEmpty) {
      throw ArgumentError('A Scout action requires command arguments.');
    }
    if (!_supplierWorkflowCommands.contains(this.arguments.first)) {
      throw ArgumentError.value(
        this.arguments.first,
        'arguments',
        'is not allowed in the bounded public tool-simulator workflow',
      );
    }
    if (this.arguments.length > 32 ||
        this.arguments.any(
          (argument) =>
              argument.isEmpty ||
              argument.length > 4096 ||
              argument.codeUnits.any(
                (codeUnit) => codeUnit == 0 || codeUnit == 10 || codeUnit == 13,
              ),
        )) {
      throw ArgumentError.value(
        this.arguments,
        'arguments',
        'must be bounded, non-empty, single-line process arguments',
      );
    }
  }

  final List<String> arguments;

  factory ToolSimulatorAction.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {'arguments'}, path);
    final rawArguments = expectJsonList(json['arguments'], '$path.arguments');
    return ToolSimulatorAction([
      for (var index = 0; index < rawArguments.length; index++)
        expectJsonString(rawArguments[index], '$path.arguments[$index]'),
    ]);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'arguments': List<String>.from(arguments),
  };
}

class ToolSimulatorPlan {
  ToolSimulatorPlan({
    required this.episodeId,
    required this.condition,
    required this.agentClaimedSuccess,
    required Iterable<ToolSimulatorAction> actions,
    this.reportedTokens,
  }) : actions = List<ToolSimulatorAction>.unmodifiable(actions) {
    validateIdentifier(episodeId, 'episodeId');
    validateIdentifier(condition, 'condition');
    if (this.actions.length > 1000) {
      throw ArgumentError.value(actions, 'actions', 'contains over 1000 items');
    }
    if (reportedTokens != null && reportedTokens! < 0) {
      throw ArgumentError.value(reportedTokens, 'reportedTokens');
    }
  }

  final String episodeId;
  final String condition;
  final bool agentClaimedSuccess;
  final List<ToolSimulatorAction> actions;
  final int? reportedTokens;

  factory ToolSimulatorPlan.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$');
    rejectUnknownKeys(json, const {
      'schemaVersion',
      'episodeId',
      'condition',
      'agentClaimedSuccess',
      'reportedTokens',
      'actions',
    }, r'$');
    final version = expectJsonInt(json['schemaVersion'], r'$.schemaVersion');
    if (version != toolSimulatorPlanSchemaVersion) {
      throw FormatException(
        'Unsupported tool simulator plan schemaVersion $version; expected '
        '$toolSimulatorPlanSchemaVersion.',
      );
    }
    final rawActions = expectJsonList(json['actions'], r'$.actions');
    return ToolSimulatorPlan(
      episodeId: expectJsonString(json['episodeId'], r'$.episodeId'),
      condition: expectJsonString(json['condition'], r'$.condition'),
      agentClaimedSuccess: expectJsonBool(
        json['agentClaimedSuccess'],
        r'$.agentClaimedSuccess',
      ),
      reportedTokens: json['reportedTokens'] == null
          ? null
          : expectJsonInt(
              json['reportedTokens'],
              r'$.reportedTokens',
              minimum: 0,
            ),
      actions: <ToolSimulatorAction>[
        for (var index = 0; index < rawActions.length; index++)
          ToolSimulatorAction.fromJson(
            rawActions[index],
            r'$.actions[' + '$index]',
          ),
      ],
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': toolSimulatorPlanSchemaVersion,
    'episodeId': episodeId,
    'condition': condition,
    'agentClaimedSuccess': agentClaimedSuccess,
    if (reportedTokens != null) 'reportedTokens': reportedTokens,
    'actions': <Map<String, Object?>>[
      for (final action in actions) action.toJson(),
    ],
  };
}

abstract interface class ToolSimulatorPlanProvider {
  Future<ToolSimulatorPlan> createPlan(AgentTaskView agentTask);
}

class StaticToolSimulatorPlanProvider implements ToolSimulatorPlanProvider {
  const StaticToolSimulatorPlanProvider(this.plan);

  final ToolSimulatorPlan plan;

  @override
  Future<ToolSimulatorPlan> createPlan(AgentTaskView agentTask) async => plan;
}

class SupplierOracleState {
  SupplierOracleState({
    required this.modalOpen,
    required this.supplierAdditionCount,
    required Iterable<String> supplierNames,
    required this.forbiddenDuplicateActionCount,
    required this.forbiddenWrongActionCount,
    this.activeTaskId,
    Map<String, bool> predicateResults = const <String, bool>{},
  }) : supplierNames = List<String>.unmodifiable(supplierNames) {
    this.predicateResults = Map<String, bool>.unmodifiable(predicateResults);
    if (supplierAdditionCount < 0 ||
        forbiddenDuplicateActionCount < 0 ||
        forbiddenWrongActionCount < 0) {
      throw const FormatException('Oracle counters must be non-negative.');
    }
    if (activeTaskId != null) validateIdentifier(activeTaskId!, 'activeTaskId');
    for (final predicateId in this.predicateResults.keys) {
      validateIdentifier(predicateId, 'predicateResults');
    }
  }

  final bool modalOpen;
  final int supplierAdditionCount;
  final List<String> supplierNames;
  final int forbiddenDuplicateActionCount;
  final int forbiddenWrongActionCount;
  final String? activeTaskId;
  late final Map<String, bool> predicateResults;

  bool get isCleanReset =>
      !modalOpen &&
      supplierAdditionCount == 0 &&
      supplierNames.isEmpty &&
      forbiddenDuplicateActionCount == 0 &&
      forbiddenWrongActionCount == 0 &&
      predicateResults.values.every((value) => !value);

  factory SupplierOracleState.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'modal',
      'supplierAdditionCount',
      'supplierNames',
      'forbiddenDuplicateActionCount',
      'forbiddenWrongActionCount',
      'activeTaskId',
      'predicateResults',
    }, path);
    final modal = expectJsonString(json['modal'], '$path.modal');
    if (modal != 'open' && modal != 'closed') {
      throw FormatException('$path.modal must be `open` or `closed`.');
    }
    final rawNames = expectJsonList(
      json['supplierNames'],
      '$path.supplierNames',
    );
    final rawPredicates = json['predicateResults'] == null
        ? const <String, Object?>{}
        : expectJsonObject(json['predicateResults'], '$path.predicateResults');
    return SupplierOracleState(
      modalOpen: modal == 'open',
      supplierAdditionCount: expectJsonInt(
        json['supplierAdditionCount'],
        '$path.supplierAdditionCount',
        minimum: 0,
      ),
      supplierNames: <String>[
        for (var index = 0; index < rawNames.length; index++)
          expectJsonString(rawNames[index], '$path.supplierNames[$index]'),
      ],
      forbiddenDuplicateActionCount: expectJsonInt(
        json['forbiddenDuplicateActionCount'],
        '$path.forbiddenDuplicateActionCount',
        minimum: 0,
      ),
      forbiddenWrongActionCount: expectJsonInt(
        json['forbiddenWrongActionCount'],
        '$path.forbiddenWrongActionCount',
        minimum: 0,
      ),
      activeTaskId: json['activeTaskId'] == null
          ? null
          : expectJsonString(json['activeTaskId'], '$path.activeTaskId'),
      predicateResults: <String, bool>{
        for (final entry in rawPredicates.entries)
          entry.key: expectJsonBool(
            entry.value,
            '$path.predicateResults.${entry.key}',
          ),
      },
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'modal': modalOpen ? 'open' : 'closed',
    'supplierAdditionCount': supplierAdditionCount,
    'supplierNames': List<String>.from(supplierNames),
    'forbiddenDuplicateActionCount': forbiddenDuplicateActionCount,
    'forbiddenWrongActionCount': forbiddenWrongActionCount,
    if (activeTaskId != null) 'activeTaskId': activeTaskId,
    if (predicateResults.isNotEmpty)
      'predicateResults': Map<String, bool>.from(predicateResults),
  };
}

class SupplierOracleObservation {
  SupplierOracleObservation({
    required this.operation,
    required this.requestId,
    required this.runtimeId,
    required this.workflowAttached,
    required this.resetGeneration,
    required this.resetPerformed,
    required this.state,
  }) {
    if (operation != 'state' && operation != 'reset') {
      throw FormatException('Unsupported oracle operation `$operation`.');
    }
    if (resetGeneration < 0) {
      throw const FormatException('resetGeneration must be non-negative.');
    }
    if (operation == 'reset' && !resetPerformed) {
      throw const FormatException(
        'A reset response must prove resetPerformed.',
      );
    }
    if (operation == 'state' && resetPerformed) {
      throw const FormatException('A state response cannot claim a reset.');
    }
    validateIdentifier(runtimeId, 'runtimeId');
    if (!RegExp(r'^[a-zA-Z0-9._-]{1,96}$').hasMatch(requestId)) {
      throw const FormatException('requestId is invalid.');
    }
  }

  final String operation;
  final String requestId;
  final String runtimeId;
  final bool workflowAttached;
  final int resetGeneration;
  final bool resetPerformed;
  final SupplierOracleState state;

  factory SupplierOracleObservation.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$');
    rejectUnknownKeys(json, const {
      'schemaVersion',
      'channel',
      'operation',
      'requestId',
      'runtimeId',
      'workflowAttached',
      'resetGeneration',
      'resetPerformed',
      'state',
    }, r'$');
    final version = expectJsonInt(json['schemaVersion'], r'$.schemaVersion');
    if (version != supplierOracleObservationSchemaVersion) {
      throw FormatException(
        'Unsupported supplier oracle schemaVersion $version; expected '
        '$supplierOracleObservationSchemaVersion.',
      );
    }
    final channel = expectJsonString(json['channel'], r'$.channel');
    if (channel != supplierWorkflowOracleChannel) {
      throw FormatException('Unexpected evaluator oracle channel `$channel`.');
    }
    return SupplierOracleObservation(
      operation: expectJsonString(json['operation'], r'$.operation'),
      requestId: expectJsonString(json['requestId'], r'$.requestId'),
      runtimeId: expectJsonString(json['runtimeId'], r'$.runtimeId'),
      workflowAttached: expectJsonBool(
        json['workflowAttached'],
        r'$.workflowAttached',
      ),
      resetGeneration: expectJsonInt(
        json['resetGeneration'],
        r'$.resetGeneration',
        minimum: 0,
      ),
      resetPerformed: json['resetPerformed'] == null
          ? false
          : expectJsonBool(json['resetPerformed'], r'$.resetPerformed'),
      state: SupplierOracleState.fromJson(json['state'], r'$.state'),
    );
  }

  Map<String, Object?> toPrivateJson() => <String, Object?>{
    'schemaVersion': supplierOracleObservationSchemaVersion,
    'channel': supplierWorkflowOracleChannel,
    'operation': operation,
    'requestId': requestId,
    'runtimeId': runtimeId,
    'workflowAttached': workflowAttached,
    'resetGeneration': resetGeneration,
    if (resetPerformed) 'resetPerformed': true,
    'state': state.toJson(),
  };
}

class SupplierWorkflowHiddenOracle implements HiddenOracle {
  SupplierWorkflowHiddenOracle({
    required this.expectedSupplierName,
    required this.expectedRuntimeId,
    required this.expectedResetGeneration,
  });

  final String expectedSupplierName;
  final String expectedRuntimeId;
  final int expectedResetGeneration;

  @override
  String get id => supplierWorkflowOracleId;

  @override
  Future<HiddenOracleVerdict> evaluate(HiddenOracleInput input) async {
    try {
      final observation = SupplierOracleObservation.fromJson(
        input.outOfBandState,
      );
      if (!observation.workflowAttached ||
          observation.runtimeId != expectedRuntimeId ||
          observation.resetGeneration != expectedResetGeneration ||
          observation.state.supplierAdditionCount !=
              observation.state.supplierNames.length) {
        return HiddenOracleVerdict.invalid(
          'The evaluator oracle state was inconsistent with the fresh reset.',
          privateEvidence: observation.toPrivateJson(),
        );
      }
      final state = observation.state;
      final success =
          !state.modalOpen &&
          state.supplierAdditionCount == 1 &&
          state.supplierNames.length == 1 &&
          state.supplierNames.single == expectedSupplierName;
      final forbidden =
          state.forbiddenDuplicateActionCount > 0 ||
          state.forbiddenWrongActionCount > 0;
      return HiddenOracleVerdict.valid(
        successPredicatesMet: success,
        forbiddenStateObserved: forbidden,
        blockingRuntimeFaultObserved: false,
        privateEvidence: <String, Object?>{
          'expectedSupplierName': expectedSupplierName,
          'observation': observation.toPrivateJson(),
        },
      );
    } on Object catch (error) {
      return HiddenOracleVerdict.invalid(
        'The evaluator oracle response was invalid: $error',
      );
    }
  }
}

class PublicFixtureHiddenOracle implements HiddenOracle {
  PublicFixtureHiddenOracle({
    required this.configuration,
    required this.expectedRuntimeId,
    required this.expectedResetGeneration,
  });

  final PublicFixtureConfiguration configuration;
  final String expectedRuntimeId;
  final int expectedResetGeneration;

  @override
  String get id => publicFixtureOracleId;

  @override
  Future<HiddenOracleVerdict> evaluate(HiddenOracleInput input) async {
    try {
      final observation = SupplierOracleObservation.fromJson(
        input.outOfBandState,
      );
      final state = observation.state;
      final expectedPredicateIds = <String>{
        configuration.successPredicateId,
        configuration.forbiddenPredicateId,
      };
      if (!observation.workflowAttached ||
          observation.runtimeId != expectedRuntimeId ||
          observation.resetGeneration != expectedResetGeneration ||
          state.activeTaskId != configuration.taskId ||
          state.supplierAdditionCount != state.supplierNames.length ||
          state.predicateResults.keys
              .toSet()
              .difference(expectedPredicateIds)
              .isNotEmpty ||
          expectedPredicateIds
              .difference(state.predicateResults.keys.toSet())
              .isNotEmpty) {
        return HiddenOracleVerdict.invalid(
          'The evaluator fixture state was inconsistent with its fresh reset.',
          privateEvidence: observation.toPrivateJson(),
        );
      }
      final exactCompletion =
          !state.modalOpen &&
          state.supplierAdditionCount == 1 &&
          state.supplierNames.length == 1 &&
          state.supplierNames.single == configuration.completionValue;
      final success =
          exactCompletion &&
          state.predicateResults[configuration.successPredicateId] == true;
      final forbidden =
          state.forbiddenDuplicateActionCount > 0 ||
          state.forbiddenWrongActionCount > 0 ||
          state.predicateResults[configuration.forbiddenPredicateId] == true;
      return HiddenOracleVerdict.valid(
        successPredicatesMet: success,
        forbiddenStateObserved: forbidden,
        blockingRuntimeFaultObserved: false,
        privateEvidence: <String, Object?>{
          'taskId': configuration.taskId,
          'successPredicateId': configuration.successPredicateId,
          'forbiddenPredicateId': configuration.forbiddenPredicateId,
          'observation': observation.toPrivateJson(),
        },
      );
    } on Object catch (error) {
      return HiddenOracleVerdict.invalid(
        'The evaluator public-fixture response was invalid: $error',
      );
    }
  }
}
