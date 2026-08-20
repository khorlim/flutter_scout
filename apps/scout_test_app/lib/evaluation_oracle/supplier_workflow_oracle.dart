import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'public_fixture_configuration.dart';

const int supplierWorkflowOracleSchemaVersion = 1;
const String supplierWorkflowOracleChannel = 'supplier_workflow_oracle_v1';
const String supplierWorkflowOracleStateMethod =
    'ext.flutter_scout_evaluator.supplier_state';
const String supplierWorkflowOracleResetMethod =
    'ext.flutter_scout_evaluator.supplier_reset';

const bool _evaluationOracleEnabled = bool.fromEnvironment(
  'FLUTTER_SCOUT_EVALUATOR_ENABLED',
);
const String _evaluationOracleCapability = String.fromEnvironment(
  'FLUTTER_SCOUT_EVALUATOR_TOKEN',
);

typedef SupplierWorkflowReset =
    Future<void> Function(PublicFixtureConfiguration? fixture);

/// Independent, evaluator-only truth for Supplier and public corpus fixtures.
///
/// The controller is deliberately not connected to Flutter Scout snapshots or
/// action responses. In evaluator builds it observes domain events directly
/// from the fixture and exposes them through authenticated VM extensions.
class SupplierWorkflowOracleController {
  SupplierWorkflowOracleController({
    required String capability,
    String? runtimeId,
    this.resetTimeout = const Duration(seconds: 5),
  }) : _capability = capability,
       _runtimeId = runtimeId ?? _newRuntimeId() {
    if (capability.length < 32 || capability.trim() != capability) {
      throw ArgumentError.value(
        capability,
        'capability',
        'must be an unpadded token containing at least 32 characters',
      );
    }
    if (resetTimeout <= Duration.zero) {
      throw ArgumentError.value(
        resetTimeout,
        'resetTimeout',
        'must be positive',
      );
    }
  }

  final String _capability;
  final String _runtimeId;
  final Duration resetTimeout;

  Object? _resetOwner;
  SupplierWorkflowReset? _resetWorkflow;
  bool _resetInProgress = false;
  bool _modalOpen = false;
  int _resetGeneration = 0;
  int _supplierAdditionCount = 0;
  int _forbiddenDuplicateActionCount = 0;
  int _forbiddenWrongActionCount = 0;
  final List<String> _supplierNames = <String>[];
  PublicFixtureConfiguration? _activeFixture;

  void attach({required Object owner, required SupplierWorkflowReset reset}) {
    if (_resetOwner != null && !identical(_resetOwner, owner)) {
      throw StateError('An evaluator workflow is already attached.');
    }
    _resetOwner = owner;
    _resetWorkflow = reset;
  }

  void detach(Object owner) {
    if (!identical(_resetOwner, owner)) return;
    _resetOwner = null;
    _resetWorkflow = null;
  }

  void recordModalOpened() {
    _modalOpen = true;
  }

  void recordModalClosed() {
    _modalOpen = false;
  }

  void recordSupplierAdded(String supplierName) {
    final normalized = supplierName.trim();
    if (normalized.isEmpty) return;
    if (_supplierNames.contains(normalized)) {
      _forbiddenDuplicateActionCount++;
    }
    _supplierNames.add(normalized);
    _supplierAdditionCount++;
  }

  /// Records a fixture-owned completion event without consulting Scout.
  void recordFixtureCompletion(String completionValue) {
    recordSupplierAdded(completionValue);
  }

  void recordForbiddenDuplicateAction() {
    _forbiddenDuplicateActionCount++;
  }

  void recordForbiddenWrongAction() {
    _forbiddenWrongActionCount++;
  }

  Future<Map<String, Object?>> handleState(
    Map<String, String> parameters,
  ) async {
    _authenticate(parameters);
    _validateParameters(parameters, allowFixture: false);
    return _response(operation: 'state', requestId: _requestId(parameters));
  }

  Future<Map<String, Object?>> handleReset(
    Map<String, String> parameters,
  ) async {
    _authenticate(parameters);
    _validateParameters(parameters, allowFixture: true);
    final requestId = _requestId(parameters);
    final encodedFixture = parameters['fixture'];
    PublicFixtureConfiguration? fixture;
    try {
      fixture = encodedFixture == null
          ? null
          : PublicFixtureConfiguration.fromEncoded(encodedFixture);
    } on FormatException {
      throw const SupplierWorkflowOracleRequestException(
        'invalid_fixture',
        'The evaluator fixture configuration was rejected.',
      );
    }
    final reset = _resetWorkflow;
    if (reset == null) {
      throw const SupplierWorkflowOracleRequestException(
        'workflow_unavailable',
        'The evaluator workflow is not attached.',
      );
    }
    if (_resetInProgress) {
      throw const SupplierWorkflowOracleRequestException(
        'reset_in_progress',
        'An evaluator workflow reset is already running.',
      );
    }

    _resetInProgress = true;
    try {
      await reset(fixture).timeout(resetTimeout);
      _resetGeneration++;
      _activeFixture = fixture;
      _modalOpen = false;
      _supplierAdditionCount = 0;
      _forbiddenDuplicateActionCount = 0;
      _forbiddenWrongActionCount = 0;
      _supplierNames.clear();
      return _response(
        operation: 'reset',
        requestId: requestId,
        resetPerformed: true,
      );
    } on TimeoutException catch (_) {
      throw const SupplierWorkflowOracleRequestException(
        'reset_timeout',
        'The evaluator workflow did not reset before the evaluator deadline.',
      );
    } finally {
      _resetInProgress = false;
    }
  }

  Map<String, Object?> _response({
    required String operation,
    required String requestId,
    bool resetPerformed = false,
  }) => <String, Object?>{
    'schemaVersion': supplierWorkflowOracleSchemaVersion,
    'channel': supplierWorkflowOracleChannel,
    'operation': operation,
    'requestId': requestId,
    'runtimeId': _runtimeId,
    'workflowAttached': _resetWorkflow != null,
    'resetGeneration': _resetGeneration,
    if (resetPerformed) 'resetPerformed': true,
    'state': <String, Object?>{
      'modal': _modalOpen ? 'open' : 'closed',
      'supplierAdditionCount': _supplierAdditionCount,
      'supplierNames': List<String>.unmodifiable(_supplierNames),
      'forbiddenDuplicateActionCount': _forbiddenDuplicateActionCount,
      'forbiddenWrongActionCount': _forbiddenWrongActionCount,
      if (_activeFixture != null) 'activeTaskId': _activeFixture!.taskId,
      'predicateResults': _predicateResults(),
    },
  };

  Map<String, bool> _predicateResults() {
    final fixture = _activeFixture;
    if (fixture == null) return const <String, bool>{};
    final completedExactlyOnce =
        !_modalOpen &&
        _supplierAdditionCount == 1 &&
        _supplierNames.length == 1 &&
        _supplierNames.single == fixture.completionValue;
    final forbidden =
        _forbiddenDuplicateActionCount > 0 || _forbiddenWrongActionCount > 0;
    return <String, bool>{
      fixture.successPredicateId: completedExactlyOnce,
      fixture.forbiddenPredicateId: forbidden,
    };
  }

  void _authenticate(Map<String, String> parameters) {
    final supplied = parameters['capability'] ?? '';
    if (!_constantTimeEquals(supplied, _capability)) {
      throw const SupplierWorkflowOracleRequestException(
        'unauthorized',
        'Evaluator capability rejected.',
      );
    }
  }

  void _validateParameters(
    Map<String, String> parameters, {
    required bool allowFixture,
  }) {
    final unexpected = parameters.keys
        .where(
          (key) =>
              key != 'capability' &&
              key != 'requestId' &&
              !(allowFixture && key == 'fixture'),
        )
        .toList(growable: false);
    if (unexpected.isNotEmpty) {
      throw const SupplierWorkflowOracleRequestException(
        'invalid_parameters',
        'The evaluator request contained unsupported parameters.',
      );
    }
  }

  String _requestId(Map<String, String> parameters) {
    final requestId = parameters['requestId'] ?? '';
    if (!RegExp(r'^[a-zA-Z0-9._-]{1,96}$').hasMatch(requestId)) {
      throw const SupplierWorkflowOracleRequestException(
        'invalid_request_id',
        'requestId must be a bounded opaque identifier.',
      );
    }
    return requestId;
  }
}

class SupplierWorkflowOracleRequestException implements Exception {
  const SupplierWorkflowOracleRequestException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

SupplierWorkflowOracleController? _debugController;
bool _debugInstalled = false;

SupplierWorkflowOracleController? get debugSupplierWorkflowOracle =>
    _debugController;

/// Installs the oracle only in an explicitly enabled debug evaluator build.
///
/// Call this from an assertion so profile/release builds contain no reachable
/// registration path. A missing/weak token fails evaluator startup closed.
void installDebugSupplierWorkflowOracle() {
  if (!kDebugMode || !_evaluationOracleEnabled) return;
  if (_debugInstalled) return;
  final controller = SupplierWorkflowOracleController(
    capability: _evaluationOracleCapability,
  );
  _debugController = controller;
  _debugInstalled = true;
  developer.registerExtension(
    supplierWorkflowOracleStateMethod,
    (_, parameters) =>
        _serviceResponse(() => controller.handleState(parameters)),
  );
  developer.registerExtension(
    supplierWorkflowOracleResetMethod,
    (_, parameters) =>
        _serviceResponse(() => controller.handleReset(parameters)),
  );
}

Future<developer.ServiceExtensionResponse> _serviceResponse(
  Future<Map<String, Object?>> Function() operation,
) async {
  try {
    final response = await operation();
    return developer.ServiceExtensionResponse.result(jsonEncode(response));
  } on SupplierWorkflowOracleRequestException catch (error) {
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      jsonEncode(<String, Object?>{
        'code': error.code,
        'message': error.message,
      }),
    );
  } on Object {
    return developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      jsonEncode(<String, Object?>{
        'code': 'oracle_internal_error',
        'message': 'The evaluator oracle could not complete the request.',
      }),
    );
  }
}

bool _constantTimeEquals(String left, String right) {
  final leftCodes = left.codeUnits;
  final rightCodes = right.codeUnits;
  var difference = leftCodes.length ^ rightCodes.length;
  final length = max(leftCodes.length, rightCodes.length);
  for (var index = 0; index < length; index++) {
    final leftValue = index < leftCodes.length ? leftCodes[index] : 0;
    final rightValue = index < rightCodes.length ? rightCodes[index] : 0;
    difference |= leftValue ^ rightValue;
  }
  return difference == 0;
}

String _newRuntimeId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return 'runtime-${bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join()}';
}
