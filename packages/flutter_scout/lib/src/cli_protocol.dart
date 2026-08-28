part of 'flutter_scout_cli.dart';

// part: negotiated v1 envelopes and exactly-once mutation invocation.

const int _scoutCliSchemaVersion = 1;
const int _scoutCliProtocolMin = 15;
const int _scoutCliProtocolMax = 15;

const Map<String, bool> _scoutCliProtocolCapabilities = <String, bool>{
  'typedEnvelopeV1': true,
  'stateGeneration': true,
  'stateDigestSha256': true,
  'strictMutationEnvelope': true,
  'serializedMutations': true,
  'idempotentMutations': true,
  'stableIdempotencyFingerprintV1': true,
  'idempotencyTombstonesV1': true,
  'runtimeErrorCursor': true,
  'heldDragExclusion': true,
  'sourceRedaction': true,
  'closedMutationOutcomes': true,
  'semanticStabilityV1': true,
  'runtimeSignalProvenanceV1': true,
  'activeRuntimeSignalsV1': true,
  'cliResponseEnvelopeV1': true,
  'structuredHeartbeatsV1': true,
  'correlatedEventCursorsV1': true,
  'boundedCliPayloadsV1': true,
  'durableIdempotencyReceiptsV1': true,
  'callerIdempotencyKeysV1': true,
  'phaseTimingsV1': true,
};

const Set<String> _requiredMutationCapabilities = <String>{
  'typedEnvelopeV1',
  'stateGeneration',
  'stateDigestSha256',
  'strictMutationEnvelope',
  'serializedMutations',
  'idempotentMutations',
  'stableIdempotencyFingerprintV1',
  'idempotencyTombstonesV1',
  'runtimeErrorCursor',
  'heldDragExclusion',
  'sourceRedaction',
  'phaseTimingsV1',
};

const Set<String> _knownPreDispatchErrors = <String>{
  'missing_mutation_envelope',
  'incompatible_schema',
  'incompatible_protocol',
  'invalid_state_generation',
  'invalid_deadline',
  'runtime_instance_mismatch',
  'mutation_deadline_expired',
  'state_observation_failed',
  'stale_state_generation',
  'run_mismatch',
  'idempotency_conflict',
  'held_drag_active',
  'missing_target',
  'missing_text',
  'missing_values',
  'invalid_values',
  'target_not_found',
  'target_not_visible',
  'text_not_found',
  'text_not_actionable',
  'tap_text_target_mismatch',
  'field_not_found',
  'scrollable_not_found',
  'missing_direction',
  'invalid_direction',
  'drag_not_active',
};

class _MutationInvocation {
  const _MutationInvocation({
    required this.commandId,
    required this.idempotencyKey,
    required this.idempotencyKeyDigest,
    required this.businessFingerprint,
    required this.callerSuppliedIdempotencyKey,
    required this.runId,
    required this.runtimeInstanceId,
    required this.expectedStateGeneration,
    required this.deadlineEpochMs,
    required this.errorCursor,
    required this.params,
    this.preflightTimings,
    this.connectionPhase,
  });

  final String commandId;
  final String idempotencyKey;
  final String idempotencyKeyDigest;
  final String businessFingerprint;
  final bool callerSuppliedIdempotencyKey;
  final String runId;
  final String runtimeInstanceId;
  final int expectedStateGeneration;
  final int deadlineEpochMs;
  final int? errorCursor;
  final Map<String, String> params;
  final Object? preflightTimings;
  final Map<String, Object?>? connectionPhase;

  _MutationInvocation withTransactionTimings({
    required Object? preflightTimings,
    required Map<String, Object?> connectionPhase,
  }) => _MutationInvocation(
    commandId: commandId,
    idempotencyKey: idempotencyKey,
    idempotencyKeyDigest: idempotencyKeyDigest,
    businessFingerprint: businessFingerprint,
    callerSuppliedIdempotencyKey: callerSuppliedIdempotencyKey,
    runId: runId,
    runtimeInstanceId: runtimeInstanceId,
    expectedStateGeneration: expectedStateGeneration,
    deadlineEpochMs: deadlineEpochMs,
    errorCursor: errorCursor,
    params: params,
    preflightTimings: preflightTimings,
    connectionPhase: connectionPhase,
  );
}

extension _CliProtocol on FlutterScoutCli {
  bool _isMutatingExtension(String method, Map<String, String> params) {
    final command = method.split('.').last;
    if (command == 'inspect' ||
        command == 'capture' ||
        command == 'waitStable' ||
        command == 'waitFor' ||
        command == 'dragStatus') {
      return false;
    }
    if (command == 'annotations') {
      return switch (params['action'] ?? 'list') {
        'list' || 'targets' || 'get-crop' => false,
        _ => true,
      };
    }
    if (command == 'record') {
      return switch (params['action'] ?? 'status') {
        'status' || 'steps' => false,
        _ => true,
      };
    }
    return true;
  }

  Map<String, String> _withReadEnvelope(Map<String, String> params) {
    final runId = _currentRunIdFromSession();
    return <String, String>{
      ...params,
      'schemaVersion': '$_scoutCliSchemaVersion',
      'clientProtocolMin': '$_scoutCliProtocolMin',
      'clientProtocolMax': '$_scoutCliProtocolMax',
      'commandId': _newProtocolIdentifier('read'),
      if (runId != null && runId.isNotEmpty) 'runId': runId,
    };
  }

  Future<
    ({
      _MutationInvocation? invocation,
      Map<String, dynamic>? replay,
      Map<String, dynamic>? failure,
    })
  >
  _prepareMutationInvocation({
    required VmService service,
    required String isolateId,
    required String method,
    required Map<String, String> params,
    required Duration actionTimeout,
    required Map<String, Object?> connectionPhase,
  }) async {
    final runId = _currentRunIdFromSession();
    if (runId == null || runId.isEmpty) {
      return (
        invocation: null,
        replay: null,
        failure: _notDispatchedProtocolFailure(
          code: 'missing_session_run_id',
          message:
              'This session has no run identity. Reattach or relaunch before mutating the app.',
          method: method,
        ),
      );
    }

    final preflightCommandId = _newProtocolIdentifier('preflight');
    late final Map<String, dynamic> preflight;
    try {
      preflight = await _invokeServiceExtension(
        service: service,
        isolateId: isolateId,
        method: 'ext.flutter_scout.inspect',
        params: <String, String>{
          'schemaVersion': '$_scoutCliSchemaVersion',
          'clientProtocolMin': '$_scoutCliProtocolMin',
          'clientProtocolMax': '$_scoutCliProtocolMax',
          'commandId': preflightCommandId,
          'runId': runId,
          'brief': 'true',
          'maxItems': '1',
        },
        timeout: const Duration(seconds: 5),
      );
    } on TimeoutException {
      return (
        invocation: null,
        replay: null,
        failure: _notDispatchedProtocolFailure(
          code: 'protocol_preflight_timeout',
          message:
              'Scout could not obtain a fresh state identity before the mutation deadline.',
          method: method,
          runId: runId,
          transport: 'timeout',
        ),
      );
    }

    Map<String, dynamic> withPreflightTiming(Map<String, dynamic> failure) =>
        _withPreflightPhaseTimings(failure, preflight['timings']);

    final compatibility = _protocolEnvelopeIssue(
      preflight,
      requireMutationCapabilities: true,
    );
    if (compatibility != null) {
      return (
        invocation: null,
        replay: null,
        failure: withPreflightTiming(
          _notDispatchedProtocolFailure(
            code: compatibility.$1,
            message: compatibility.$2,
            method: method,
            runId: runId,
            details: <String, Object?>{
              'preflight': _protocolIdentity(preflight),
            },
          ),
        ),
      );
    }
    if (preflight['commandId'] != preflightCommandId) {
      return (
        invocation: null,
        replay: null,
        failure: withPreflightTiming(
          _notDispatchedProtocolFailure(
            code: 'protocol_preflight_identity_mismatch',
            message:
                'The helper preflight response did not echo the request command identity. Nothing was dispatched.',
            method: method,
            runId: runId,
            details: <String, Object?>{
              'preflight': _protocolIdentity(preflight),
            },
          ),
        ),
      );
    }
    if (preflight['ok'] != true) {
      return (
        invocation: null,
        replay: null,
        failure: withPreflightTiming(
          _notDispatchedProtocolFailure(
            code: 'protocol_preflight_failed',
            message:
                'The helper could not produce a trustworthy fresh snapshot before mutation.',
            method: method,
            runId: runId,
            details: <String, Object?>{
              if (preflight['structuredError'] != null)
                'structuredError': preflight['structuredError'],
            },
          ),
        ),
      );
    }

    final helperRunId = preflight['runId']?.toString();
    if (helperRunId != null && helperRunId.isNotEmpty && helperRunId != runId) {
      return (
        invocation: null,
        replay: null,
        failure: withPreflightTiming(
          _notDispatchedProtocolFailure(
            code: 'run_mismatch',
            message:
                'The attached helper is bound to a different Scout run. Nothing was dispatched.',
            method: method,
            runId: runId,
            details: <String, Object?>{'helperRunId': helperRunId},
          ),
        ),
      );
    }

    final runtimeInstanceId = preflight['runtimeInstanceId']!.toString();
    final stateGeneration = (preflight['stateGeneration'] as num).toInt();
    final stateDigest = preflight['stateDigest']?.toString();
    final snapshotId = preflight['snapshotId']?.toString();
    final validDigest =
        stateDigest != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(stateDigest);
    if (stateGeneration < 0 ||
        !validDigest ||
        snapshotId != 'g$stateGeneration:$stateDigest') {
      return (
        invocation: null,
        replay: null,
        failure: withPreflightTiming(
          _notDispatchedProtocolFailure(
            code: 'invalid_preflight_state_identity',
            message:
                'The helper did not provide a valid generation-bound SHA-256 snapshot identity. Nothing was dispatched.',
            method: method,
            runId: runId,
            details: <String, Object?>{
              'preflight': _protocolIdentity(preflight),
            },
          ),
        ),
      );
    }
    final errorCursor = switch (preflight['errorCursor']) {
      final num value => value.toInt(),
      final String value => int.tryParse(value),
      _ => null,
    };
    final commandId = _newProtocolIdentifier(
      _activeCommandId == null ? 'mutation' : 'mutation-$_activeCommandId',
    );
    final callerKey = _activeCallerIdempotencyKey;
    final idempotencyKey = callerKey ?? _newProtocolIdentifier('idem');
    final idempotencyKeyDigest = _idempotencyKeyDigest(idempotencyKey);
    final businessFingerprint = _mutationBusinessFingerprint(
      method: method,
      runId: runId,
      params: params,
    );
    final deadlineEpochMs = DateTime.now()
        .add(actionTimeout)
        .millisecondsSinceEpoch;
    final envelope = <String, String>{
      ...params,
      'schemaVersion': '$_scoutCliSchemaVersion',
      'clientProtocolMin': '$_scoutCliProtocolMin',
      'clientProtocolMax': '$_scoutCliProtocolMax',
      'commandId': commandId,
      'idempotencyKey': idempotencyKey,
      'runId': runId,
      'runtimeInstanceId': runtimeInstanceId,
      'expectedStateGeneration': '$stateGeneration',
      'deadlineEpochMs': '$deadlineEpochMs',
      if (errorCursor != null) 'errorCursor': '$errorCursor',
    };
    final proposed = _MutationInvocation(
      commandId: commandId,
      idempotencyKey: idempotencyKey,
      idempotencyKeyDigest: idempotencyKeyDigest,
      businessFingerprint: businessFingerprint,
      callerSuppliedIdempotencyKey:
          callerKey != null && !_activeIdempotencyKeyWasGenerated,
      runId: runId,
      runtimeInstanceId: runtimeInstanceId,
      expectedStateGeneration: stateGeneration,
      deadlineEpochMs: deadlineEpochMs,
      errorCursor: errorCursor,
      params: Map<String, String>.unmodifiable(envelope),
      preflightTimings: preflight['timings'],
      connectionPhase: connectionPhase,
    );
    final durable = _reserveDurableMutationInvocation(
      proposed: proposed,
      method: method,
      businessParams: params,
    );
    final durableInvocation = durable.invocation;
    return (
      invocation: durableInvocation?.withTransactionTimings(
        preflightTimings: preflight['timings'],
        connectionPhase: connectionPhase,
      ),
      replay: durable.replay,
      failure: durable.failure,
    );
  }

  Future<Map<String, dynamic>> _invokeServiceExtension({
    required VmService service,
    required String isolateId,
    required String method,
    required Map<String, String> params,
    required Duration timeout,
  }) async {
    final response = await service
        .callServiceExtension(method, isolateId: isolateId, args: params)
        .timeout(timeout);
    return _decodeServiceExtensionResponse(response);
  }

  Map<String, dynamic> _decodeServiceExtensionResponse(Response response) {
    final json = response.json;
    if (json == null) {
      return <String, dynamic>{
        'ok': false,
        'error': <String, Object?>{
          'code': 'empty_vm_response',
          'message': 'The VM service returned no extension payload.',
        },
      };
    }
    if (json.containsKey('ok')) return Map<String, dynamic>.from(json);
    final result = json['result'];
    if (result is String) {
      final decoded = jsonDecode(result);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    if (result is Map) return Map<String, dynamic>.from(result);
    return Map<String, dynamic>.from(json);
  }

  String? _canonicalPhaseTimingsIssue(Object? rawTimings) {
    if (rawTimings is! Map || rawTimings['phases'] is! Map) {
      return 'timings.phases is missing';
    }
    final phases = rawTimings['phases']! as Map;
    for (final name in _scoutCliPhaseNames) {
      if (!phases.containsKey(name)) return 'timings.phases.$name is missing';
      final phase = phases[name];
      if (phase is! Map) return 'timings.phases.$name is not an object';
      final status = phase['status'];
      final elapsedMs = phase['elapsedMs'];
      if (status == 'measured') {
        if (elapsedMs is! int || elapsedMs < 0) {
          return 'timings.phases.$name has an invalid measured duration';
        }
        continue;
      }
      if (status == 'unavailable') {
        final reason = phase['reason']?.toString().trim();
        if (elapsedMs != null || reason == null || reason.isEmpty) {
          return 'timings.phases.$name has invalid unavailable semantics';
        }
        continue;
      }
      return 'timings.phases.$name has an invalid status';
    }
    return null;
  }

  (String, String)? _protocolEnvelopeIssue(
    Map<String, dynamic> response, {
    required bool requireMutationCapabilities,
  }) {
    final schema = switch (response['schemaVersion']) {
      final num value => value.toInt(),
      final String value => int.tryParse(value),
      _ => null,
    };
    if (schema != _scoutCliSchemaVersion) {
      return (
        'incompatible_helper_schema',
        'The helper schema is missing or incompatible; expected schema $_scoutCliSchemaVersion.',
      );
    }
    final helperMin = switch (response['minSupportedProtocolVersion']) {
      final num value => value.toInt(),
      final String value => int.tryParse(value),
      _ => null,
    };
    final helperMax = switch (response['maxSupportedProtocolVersion']) {
      final num value => value.toInt(),
      final String value => int.tryParse(value),
      _ => null,
    };
    final version = switch (response['protocolVersion']) {
      final num value => value.toInt(),
      final String value => int.tryParse(value),
      _ => null,
    };
    if (helperMin == null ||
        helperMax == null ||
        version == null ||
        helperMin > helperMax ||
        helperMax < _scoutCliProtocolMin ||
        helperMin > _scoutCliProtocolMax ||
        version < helperMin ||
        version > helperMax) {
      return (
        'incompatible_helper_protocol',
        'The CLI protocol range $_scoutCliProtocolMin-$_scoutCliProtocolMax does not overlap the helper range.',
      );
    }
    final runtime = response['runtimeInstanceId']?.toString();
    final generation = switch (response['stateGeneration']) {
      final num value => value.toInt(),
      final String value => int.tryParse(value),
      _ => null,
    };
    if (runtime == null ||
        runtime.isEmpty ||
        generation == null ||
        generation < 0) {
      return (
        'incomplete_helper_identity',
        'The helper omitted its runtime instance or monotonic state generation.',
      );
    }
    final commandId = response['commandId'];
    final capabilities = response['capabilities'];
    final timings = response['timings'];
    final totalMs = timings is Map ? timings['totalMs'] : null;
    final phaseTimingsIssue = _canonicalPhaseTimingsIssue(timings);
    final errorCursor = switch (response['errorCursor']) {
      final num value => value.toInt(),
      final String value => int.tryParse(value),
      _ => null,
    };
    final ok = response['ok'];
    final hasTypedOutcomeSlots =
        response.containsKey('result') &&
        response.containsKey('structuredError');
    final structuredError = response['structuredError'];
    final validOutcome =
        ok is bool &&
        hasTypedOutcomeSlots &&
        (ok
            ? structuredError == null
            : structuredError is Map &&
                  structuredError['code'] != null &&
                  structuredError['message'] != null);
    if (commandId is! String ||
        commandId.isEmpty ||
        capabilities is! Map ||
        totalMs is! num ||
        totalMs < 0 ||
        phaseTimingsIssue != null ||
        errorCursor == null ||
        errorCursor < 0 ||
        response['errorsSinceCursor'] is! List ||
        response['activeBlockingSignals'] is! List ||
        !validOutcome) {
      return (
        'invalid_helper_envelope',
        phaseTimingsIssue == null
            ? 'The helper omitted or malformed a required typed response field.'
            : 'The helper returned malformed canonical phase timings: $phaseTimingsIssue.',
      );
    }
    if (requireMutationCapabilities) {
      final missing = <String>[
        for (final name in _requiredMutationCapabilities)
          if (capabilities[name] != true) name,
      ];
      if (missing.isNotEmpty) {
        return (
          'missing_mutation_capability',
          'The helper cannot prove required mutation safety capabilities: ${missing.join(', ')}.',
        );
      }
    }
    return null;
  }

  Map<String, dynamic>? _validateMutationResponse(
    Map<String, dynamic> response,
    _MutationInvocation invocation,
  ) {
    final issue = _protocolEnvelopeIssue(
      response,
      requireMutationCapabilities: true,
    );
    if (issue != null) {
      return _unknownDispatchProtocolFailure(
        code: issue.$1,
        message:
            '${issue.$2} The mutation may already have been dispatched, so Scout will not retry it with a new identity.',
        invocation: invocation,
        details: <String, Object?>{'response': _protocolIdentity(response)},
      );
    }
    if (response['commandId'] != invocation.commandId ||
        response['runtimeInstanceId'] != invocation.runtimeInstanceId ||
        (response['runId'] != null &&
            response['runId'].toString() != invocation.runId)) {
      return _unknownDispatchProtocolFailure(
        code: 'mutation_response_identity_mismatch',
        message:
            'The helper response identity did not match the dispatched mutation. Scout will not treat it as authoritative or retry.',
        invocation: invocation,
        details: <String, Object?>{
          'expected': <String, Object?>{
            'commandId': invocation.commandId,
            'runId': invocation.runId,
            'runtimeInstanceId': invocation.runtimeInstanceId,
          },
          'received': _protocolIdentity(response),
        },
      );
    }
    final responseGeneration = switch (response['stateGeneration']) {
      final num value => value.toInt(),
      final String value => int.tryParse(value),
      _ => null,
    };
    if (responseGeneration == null ||
        responseGeneration < invocation.expectedStateGeneration) {
      return _unknownDispatchProtocolFailure(
        code: 'mutation_response_generation_regressed',
        message:
            'The helper response carried a state generation older than the mutation precondition. Scout will not treat it as authoritative or retry.',
        invocation: invocation,
        details: <String, Object?>{
          'expectedAtLeast': invocation.expectedStateGeneration,
          'received': responseGeneration,
        },
      );
    }
    return null;
  }

  Map<String, dynamic> _withClosedMutationOutcome(
    Map<String, dynamic> response,
    _MutationInvocation invocation, {
    bool reconciledAfterTimeout = false,
  }) {
    final errorCode = _responseErrorCode(response);
    final activation = response['activation'];
    final explicitlyDispatched =
        activation is Map && activation['dispatched'] == true;
    final explicitlyNotDispatched =
        activation is Map && activation['dispatched'] == false;
    final dispatch =
        explicitlyDispatched ||
            response['ok'] == true ||
            errorCode == 'expectation_not_met' ||
            errorCode == 'blocking_error_during_wait'
        ? 'dispatched'
        : explicitlyNotDispatched || _knownPreDispatchErrors.contains(errorCode)
        ? 'not_dispatched'
        : 'dispatch_outcome_unknown';

    final before = response['before'];
    final after = response['after'];
    final actionResult = response['result'];
    final observation = dispatch != 'dispatched'
        ? 'observation_unavailable'
        : actionResult == 'changed' ||
              (before is Map &&
                  after is Map &&
                  _inspectChanged(
                    Map<String, dynamic>.from(before),
                    Map<String, dynamic>.from(after),
                  ))
        ? 'changed'
        : actionResult == 'completed_same_state' ||
              actionResult == 'already_selected' ||
              response['activityObserved'] == true
        ? 'completed_same_state'
        : before is Map && after is Map
        ? 'no_effect'
        : 'observation_unavailable';
    final expectation = response['expectation'];
    final postcondition = expectation is! Map
        ? 'postcondition_not_requested'
        : expectation['met'] == true
        ? 'postcondition_met'
        : 'postcondition_not_met';
    final errors = _protocolList(response['errorsSinceCursor']);
    final activeBlockingSignals = _protocolList(
      response['activeBlockingSignals'],
    );
    final runtimeHealth =
        activeBlockingSignals.isNotEmpty ||
            errors.any((error) => error is Map && error['blocking'] == true)
        ? 'runtime_blocked'
        : response.containsKey('errorsSinceCursor')
        ? 'runtime_clean'
        : 'runtime_health_unknown';
    final reportedStability = response['stability'];
    final closedStability = reportedStability is Map
        ? <String, Object?>{
            for (final entry in reportedStability.entries)
              entry.key.toString(): entry.value,
          }
        : _unavailableCliStability(
            transport: 'ok',
            stoppingReason: dispatch == 'not_dispatched'
                ? 'action_not_dispatched'
                : 'helper_stability_observation_unavailable',
            deadlineEpochMs: invocation.deadlineEpochMs,
            initialStateGeneration: invocation.expectedStateGeneration,
          );

    return <String, dynamic>{
      ...response,
      'capabilities': <String, Object?>{
        if (response['capabilities'] case final Map capabilities)
          for (final entry in capabilities.entries)
            entry.key.toString(): entry.value,
        'closedMutationOutcomes': true,
      },
      'capabilitySource': 'negotiated',
      'identityStatus': 'validated',
      'transport': 'ok',
      'dispatch': dispatch,
      'observation': observation,
      'postcondition': postcondition,
      'runtimeHealth': runtimeHealth,
      'runtimeHealthScope': 'fresh_since_cursor_and_currently_active',
      'activeBlockingSignals': activeBlockingSignals,
      'stable': _truthfulLegacyStable(response['stable'], closedStability),
      'stability': closedStability,
      'idempotencyKey': invocation.idempotencyKey,
      'idempotencyKeyDigest': invocation.idempotencyKeyDigest,
      'expectedStateGeneration': invocation.expectedStateGeneration,
      'deadlineEpochMs': invocation.deadlineEpochMs,
      if (reconciledAfterTimeout) 'reconciledAfterTimeout': true,
      if (before is Map) ...<String, Object?>{
        if (before['stateGeneration'] != null)
          'beforeStateGeneration': before['stateGeneration'],
        if (before['snapshotId'] != null)
          'beforeSnapshotId': before['snapshotId'],
      },
      if (after is Map) ...<String, Object?>{
        if (after['stateGeneration'] != null)
          'afterStateGeneration': after['stateGeneration'],
        if (after['snapshotId'] != null) 'afterSnapshotId': after['snapshotId'],
      },
    };
  }

  Map<String, dynamic> _mutationTimeoutFailure(
    _MutationInvocation invocation,
  ) => _unknownDispatchProtocolFailure(
    code: 'mutation_dispatch_outcome_unknown',
    message:
        'The VM call timed out after the mutation may have reached the helper. Do not retry with a new idempotency key; inspect current state or retry only through the same runtime/key.',
    invocation: invocation,
    transport: 'timeout',
    details: <String, Object?>{
      'deadlineEpochMs': invocation.deadlineEpochMs,
      'safeRecoveryActions': <String>[
        'flutter-scout inspect --brief',
        'Check the intended postcondition before issuing another mutation',
      ],
    },
  );

  Map<String, dynamic> _notDispatchedProtocolFailure({
    required String code,
    required String message,
    required String method,
    String? runId,
    String transport = 'ok',
    Map<String, Object?> details = const <String, Object?>{},
  }) => <String, dynamic>{
    'ok': false,
    'schemaVersion': _scoutCliSchemaVersion,
    'protocolVersion': _scoutCliProtocolMax,
    'minSupportedProtocolVersion': _scoutCliProtocolMin,
    'maxSupportedProtocolVersion': _scoutCliProtocolMax,
    'capabilities': _scoutCliProtocolCapabilities,
    'capabilitySource': 'cli',
    'commandId': _activeCommandId ?? _newProtocolIdentifier('command'),
    'runId': runId,
    'runtimeInstanceId': null,
    'stateGeneration': null,
    'identityStatus': 'unavailable',
    'result': null,
    'structuredError': <String, Object?>{
      'code': code,
      'message': message,
      if (details.isNotEmpty) 'details': details,
    },
    'error': <String, Object?>{'code': code, 'message': message},
    'transport': transport,
    'dispatch': 'not_dispatched',
    'observation': 'observation_unavailable',
    'postcondition': 'postcondition_not_requested',
    'runtimeHealth': 'runtime_health_unknown',
    'stable': false,
    'stability': _unavailableCliStability(
      transport: transport,
      stoppingReason: transport == 'timeout'
          ? 'runtime_transport_timeout_before_dispatch'
          : transport == 'failed'
          ? 'runtime_transport_lost_before_dispatch'
          : 'observation_unavailable_before_dispatch',
    ),
    'errorCursor': null,
    'errorsSinceCursor': null,
    'method': method,
    'timings': const <String, Object?>{},
  };

  Map<String, dynamic> _unknownDispatchProtocolFailure({
    required String code,
    required String message,
    required _MutationInvocation invocation,
    String transport = 'invalid_response',
    Map<String, Object?> details = const <String, Object?>{},
  }) => <String, dynamic>{
    'ok': false,
    'schemaVersion': _scoutCliSchemaVersion,
    'protocolVersion': _scoutCliProtocolMax,
    'minSupportedProtocolVersion': _scoutCliProtocolMin,
    'maxSupportedProtocolVersion': _scoutCliProtocolMax,
    'capabilities': _scoutCliProtocolCapabilities,
    'capabilitySource': 'cli',
    'commandId': invocation.commandId,
    'runId': invocation.runId,
    'runtimeInstanceId': invocation.runtimeInstanceId,
    'stateGeneration': invocation.expectedStateGeneration,
    'identityStatus': 'validated_pre_dispatch',
    'result': null,
    'structuredError': <String, Object?>{
      'code': code,
      'message': message,
      if (details.isNotEmpty) 'details': details,
    },
    'error': <String, Object?>{'code': code, 'message': message},
    'transport': transport,
    'dispatch': 'dispatch_outcome_unknown',
    'observation': 'observation_unavailable',
    'postcondition': 'postcondition_not_requested',
    'runtimeHealth': 'runtime_health_unknown',
    'stable': false,
    'stability': _unavailableCliStability(
      transport: transport,
      stoppingReason: transport == 'timeout'
          ? 'runtime_transport_timeout_after_possible_dispatch'
          : transport == 'failed'
          ? 'runtime_transport_lost_after_possible_dispatch'
          : 'mutation_response_observation_unavailable',
      deadlineEpochMs: invocation.deadlineEpochMs,
      initialStateGeneration: invocation.expectedStateGeneration,
    ),
    'idempotencyKey': invocation.idempotencyKey,
    'idempotencyKeyDigest': invocation.idempotencyKeyDigest,
    'expectedStateGeneration': invocation.expectedStateGeneration,
    'deadlineEpochMs': invocation.deadlineEpochMs,
    'errorCursor': invocation.errorCursor,
    'errorsSinceCursor': null,
    'timings': const <String, Object?>{},
  };

  Map<String, Object?> _unavailableCliStability({
    required String transport,
    required String stoppingReason,
    int? deadlineEpochMs,
    int? initialStateGeneration,
  }) => <String, Object?>{
    'state': transport == 'timeout' || transport == 'failed'
        ? 'runtime_lost'
        : 'observation_unavailable',
    'actionable': false,
    'stoppingReason': stoppingReason,
    // Transport failure prevents a trustworthy helper-side duration or
    // semantic sample. Null is evidence of unavailability, never invented 0.
    'elapsedMs': null,
    'budgetMs': null,
    'deadlineEpochMs': deadlineEpochMs,
    'bounded': deadlineEpochMs != null,
    'samples': const <String, Object?>{
      'count': 0,
      'semanticChangeCount': 0,
      'distinctSemanticStates': 0,
      'quietWindowMs': 120,
      'quietForMs': 0,
    },
    'frames': const <String, Object?>{
      'scheduledFrameSamples': 0,
      'transientCallbackSamples': 0,
      'maxTransientCallbacks': 0,
      'disabledFrameSamples': 0,
      'lastHasScheduledFrame': null,
      'lastTransientCallbackCount': null,
      'lastSchedulerPhase': null,
    },
    'initial': <String, Object?>{
      'stateGeneration': initialStateGeneration,
      'stateDigest': null,
      'snapshotId': null,
    },
    'final': const <String, Object?>{
      'stateGeneration': null,
      'stateDigest': null,
      'snapshotId': null,
    },
    'limitations': transport == 'timeout' || transport == 'failed'
        ? const <String>[
            'The VM-service transport ended before Scout could complete a semantic stability observation.',
            'Inspect or reconnect to establish a new runtime and snapshot identity before acting again.',
          ]
        : const <String>[
            'The helper did not provide a complete semantic stability observation for this outcome.',
            'Do not infer quiescence from the legacy stable boolean or transport success.',
          ],
  };

  bool _truthfulLegacyStable(Object? stable, Object? stability) {
    if (stable != true || stability is! Map) return false;
    return stability['state'] == 'stable' && stability['actionable'] == true;
  }

  String? _responseErrorCode(Map<String, dynamic> response) {
    final structured = response['structuredError'];
    if (structured is Map && structured['code'] != null) {
      return structured['code'].toString();
    }
    final error = response['error'];
    if (error is Map && error['code'] != null) return error['code'].toString();
    return null;
  }

  Map<String, Object?> _protocolIdentity(Map<String, dynamic> response) =>
      <String, Object?>{
        for (final key in const <String>[
          'schemaVersion',
          'protocolVersion',
          'minSupportedProtocolVersion',
          'maxSupportedProtocolVersion',
          'commandId',
          'runId',
          'runtimeInstanceId',
          'stateGeneration',
          'errorCursor',
        ])
          if (response[key] != null) key: response[key],
      };

  List<Object?> _protocolList(Object? value) =>
      value is List ? List<Object?>.from(value) : const <Object?>[];

  String _newProtocolIdentifier(String prefix) {
    final bytes = <int>[
      for (var index = 0; index < 18; index++) Random.secure().nextInt(256),
    ];
    final token = base64Url.encode(bytes).replaceAll('=', '');
    final safePrefix = prefix.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    return '$safePrefix-$token';
  }
}
