part of 'flutter_scout_binding.dart';

// part: typed protocol envelopes, canonical state identity, runtime-signal
// cursors, and serialized exactly-once mutation dispatch.

const Map<String, bool> _scoutProtocolCapabilities = <String, bool>{
  'typedEnvelopeV1': true,
  'stateGeneration': true,
  'stateDigestSha256': true,
  'strictMutationEnvelope': true,
  'serializedMutations': true,
  'idempotentMutations': true,
  'stableIdempotencyFingerprintV1': true,
  'idempotencyTombstonesV1': true,
  'runtimeErrorCursor': true,
  'runtimeSignalProvenanceV1': true,
  'activeRuntimeSignalsV1': true,
  'heldDragExclusion': true,
  'sourceRedaction': true,
  'boundedNavigation': true,
  'snapshotRelativeDeltas': true,
  'changedRegionCaptureV1': true,
  'semanticStabilityV1': true,
  'observationNonInterferenceV1': true,
  'overlayExplicitOptInV1': true,
  'strictTypedParametersV1': true,
  'boundedHelperRequestsV1': true,
  'boundedHelperPayloadsV1': true,
  'phaseTimingsV1': true,
};

const int _maxProtocolResponseBytes = 4 * 1024 * 1024;
const int _maxProtocolPayloadDepth = 64;
const int _maxProtocolPayloadNodes = 131072;
const int _maxProtocolIdentityBytes = 256;
const int _maxCompactSignalStringBytes = 512;
const int _maxProtocolRequestParameters = 64;
const int _maxProtocolRequestParameterNameBytes = 128;
const int _maxProtocolRequestTotalBytes = 1024 * 1024;
const int _maxProtocolRequestValueBytes = 64 * 1024;
const int _maxProtocolRequestBulkValueBytes = 512 * 1024;
const int _maxProtocolCommandIdBytes = 256;
const int _maxProtocolRunIdBytes = 128;
const int _maxProtocolRuntimeIdBytes = 128;
const int _maxVmTransportIsolateIdBytes = 128;

final RegExp _safeProtocolIdempotencyKey = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
);

const Set<String> _bulkProtocolParameters = <String>{
  'records',
  'value',
  'values',
};

const Map<String, int> _protocolParameterByteLimits = <String, int>{
  'schemaVersion': 16,
  'clientProtocolMin': 16,
  'clientProtocolMax': 16,
  'commandId': _maxProtocolCommandIdBytes,
  'runId': _maxProtocolRunIdBytes,
  'errorCursor': 32,
  'errorsSinceCursor': 32,
  'idempotencyKey': 128,
  'runtimeInstanceId': _maxProtocolRuntimeIdBytes,
  'isolateId': _maxVmTransportIsolateIdBytes,
  'expectedStateGeneration': 32,
  'deadlineEpochMs': 32,
};

// The VM service requires `isolateId` to route an extension call and forwards
// it to `developer.registerExtension`. It is transport metadata rather than a
// Scout method argument, so it is accepted at the boundary but not advertised
// in the public typed-method catalog or included in business fingerprints.
const Set<String> _vmTransportProtocolParameters = <String>{'isolateId'};

const Set<String> _commonProtocolParameters = <String>{
  'schemaVersion',
  'clientProtocolMin',
  'clientProtocolMax',
  'commandId',
  'runId',
  'errorCursor',
  // Protocol-15 migration alias, documented in protocol/README.md.
  'errorsSinceCursor',
  'idempotencyKey',
  'runtimeInstanceId',
  'expectedStateGeneration',
  'deadlineEpochMs',
};

const List<String> _requiredMutationEnvelopeParameters = <String>[
  'schemaVersion',
  'clientProtocolMin',
  'clientProtocolMax',
  'commandId',
  'idempotencyKey',
  'runId',
  'runtimeInstanceId',
  'expectedStateGeneration',
  'deadlineEpochMs',
];

final Object _requestContextZoneKey = Object();

class _RequestContext {
  _RequestContext({
    required this.extensionName,
    required this.method,
    required this.params,
    required this.mutating,
  }) : stopwatch = Stopwatch()..start(),
       commandId = params['commandId']?.trim(),
       runId = params['runId']?.trim(),
       errorCursor = int.tryParse(
         params['errorCursor'] ?? params['errorsSinceCursor'] ?? '',
       ),
       deadlineEpochMs = int.tryParse(params['deadlineEpochMs'] ?? '');

  final String extensionName;
  final String method;
  final Map<String, String> params;
  final bool mutating;
  final Stopwatch stopwatch;
  final String? commandId;
  final String? runId;
  final int? errorCursor;
  final int? deadlineEpochMs;
  bool handlerEntered = false;
}

class _MutationRecord {
  _MutationRecord({required this.fingerprint});

  final String fingerprint;
  final Completer<developer.ServiceExtensionResponse> completer =
      Completer<developer.ServiceExtensionResponse>();
  bool completed = false;
}

const int _maxMutationOutcomeRecords = 256;
const int _maxExactMutationTombstones = 2048;

/// Fixed-memory, no-false-negative tombstones for keys whose exact
/// fingerprint tombstone aged out. False positives are safe: they abstain
/// instead of dispatching. The filter is never cleared during a runtime.
class _MutationTombstoneFilter {
  static const int _bitCount = 65536;
  static const int _wordBits = 32;
  final List<int> _words = List<int>.filled(_bitCount ~/ _wordBits, 0);

  Iterable<int> _positions(String key) sync* {
    final digest = crypto.sha256.convert(utf8.encode(key)).bytes;
    for (var offset = 0; offset < 16; offset += 4) {
      final value =
          (digest[offset] << 24) |
          (digest[offset + 1] << 16) |
          (digest[offset + 2] << 8) |
          digest[offset + 3];
      yield value & (_bitCount - 1);
    }
  }

  void add(String key) {
    for (final position in _positions(key)) {
      final word = position ~/ _wordBits;
      final bit = position % _wordBits;
      _words[word] |= 1 << bit;
    }
  }

  bool mightContain(String key) {
    for (final position in _positions(key)) {
      final word = position ~/ _wordBits;
      final bit = position % _wordBits;
      if ((_words[word] & (1 << bit)) == 0) return false;
    }
    return true;
  }
}

class _MutationTombstoneState {
  final LinkedHashMap<String, String> exactFingerprints =
      LinkedHashMap<String, String>();
  final _MutationTombstoneFilter filter = _MutationTombstoneFilter();

  void remember(String key, String fingerprint) {
    exactFingerprints[key] = fingerprint;
    while (exactFingerprints.length > _maxExactMutationTombstones) {
      final oldest = exactFingerprints.keys.first;
      exactFingerprints.remove(oldest);
      filter.add(oldest);
    }
  }
}

final Expando<_MutationTombstoneState> _mutationTombstones =
    Expando<_MutationTombstoneState>('flutter_scout_mutation_tombstones');

extension _RuntimeProtocol on FlutterScoutRuntime {
  _MutationTombstoneState get _mutationTombstoneState =>
      _mutationTombstones[this] ??= _MutationTombstoneState();

  _RequestContext? get _requestContext =>
      Zone.current[_requestContextZoneKey] as _RequestContext?;

  Future<developer.ServiceExtensionResponse> _dispatchProtocolRequest({
    required String extensionName,
    required String method,
    required Map<String, String> params,
    required Future<developer.ServiceExtensionResponse> Function(
      String method,
      Map<String, String> params,
    )
    callback,
    bool? mutationOverride,
    bool validateTypedParameters = true,
  }) {
    final mutating =
        mutationOverride ?? _isMutatingRequest(extensionName, params);
    final phaseTimings = _RequestPhaseTimings(
      mutating: mutating,
      command: extensionName.split('.').last,
    );
    final context = _RequestContext(
      extensionName: extensionName,
      method: method,
      params: Map<String, String>.unmodifiable(params),
      mutating: mutating,
    );
    final zoneValues = <Object, Object>{
      _requestContextZoneKey: context,
      _requestPhaseTimingsZoneKey: phaseTimings,
    };
    if (validateTypedParameters) {
      final issue = _typedParameterBoundaryIssue(extensionName, params);
      if (issue != null) {
        return runZoned(
          () async => _fail(
            issue.code,
            issue.message,
            extra: <String, Object?>{
              ...issue.details,
              if (mutating) ...<String, Object?>{
                'activation': const <String, Object?>{'dispatched': false},
                'dispatch': 'not_dispatched',
              },
            },
          ),
          zoneValues: zoneValues,
        );
      }
      // Generic count/name/value limits and the exact method allowlist run
      // first. Mutation protocol identity then takes precedence over narrower
      // business semantics, so a schema/range mismatch cannot masquerade as
      // an invalid target or action parameter.
      if (mutating) {
        final staticError = runZoned(
          () => _staticMutationEnvelopeError(params),
          zoneValues: zoneValues,
        );
        if (staticError != null) {
          return Future<developer.ServiceExtensionResponse>.value(staticError);
        }
      }
      final semanticIssue = _helperTypedSemanticIssue(
        extensionName.split('.').last,
        params,
      );
      if (semanticIssue != null) {
        return runZoned(
          () async => _fail(
            semanticIssue.code,
            semanticIssue.message,
            extra: <String, Object?>{
              ...semanticIssue.details,
              if (mutating) ...<String, Object?>{
                'activation': const <String, Object?>{'dispatched': false},
                'dispatch': 'not_dispatched',
              },
            },
          ),
          zoneValues: zoneValues,
        );
      }
    }
    if (!mutating) {
      final attachRunId = context.runId;
      if (_boundRunId == null &&
          attachRunId != null &&
          attachRunId.isNotEmpty) {
        _boundRunId = attachRunId;
      }
      return runZoned(() {
        context.handlerEntered = true;
        return callback(method, params);
      }, zoneValues: zoneValues);
    }
    return runZoned(
      () => _dispatchMutation(context, callback),
      zoneValues: zoneValues,
    );
  }

  bool _isMutatingRequest(String extensionName, Map<String, String> params) {
    final command = extensionName.split('.').last;
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

  Future<developer.ServiceExtensionResponse> _dispatchMutation(
    _RequestContext context,
    Future<developer.ServiceExtensionResponse> Function(
      String method,
      Map<String, String> params,
    )
    callback,
  ) {
    final staticError = runZoned(
      () => _staticMutationEnvelopeError(context.params),
      zoneValues: {_requestContextZoneKey: context},
    );
    if (staticError != null) {
      return runZoned(
        () async => staticError,
        zoneValues: {_requestContextZoneKey: context},
      );
    }

    final key = context.params['idempotencyKey']!.trim();
    final keyDigest = crypto.sha256.convert(utf8.encode(key)).toString();
    Map<String, Object?> keyEvidence({String? receiptState}) =>
        <String, Object?>{
          'idempotencyKeyDigest': keyDigest,
          'idempotencyKeySource': 'request_envelope',
          'rawIdempotencyKeyRetained': false,
          'receiptState': ?receiptState,
        };
    final fingerprint = _mutationFingerprint(context);
    final existing = _mutationRecords[key];
    if (existing != null) {
      if (existing.fingerprint == fingerprint) {
        return existing.completer.future;
      }
      return runZoned(
        () async => _fail(
          'idempotency_conflict',
          'This idempotency identity was already used for a different request.',
          extra: keyEvidence(),
        ),
        zoneValues: {_requestContextZoneKey: context},
      );
    }

    final exactTombstone = _mutationTombstoneState.exactFingerprints[key];
    if (exactTombstone != null) {
      if (exactTombstone != fingerprint) {
        return runZoned(
          () async => _fail(
            'idempotency_conflict',
            'This idempotency identity was already used for a different request.',
            extra: keyEvidence(receiptState: 'tombstone'),
          ),
          zoneValues: {_requestContextZoneKey: context},
        );
      }
      return runZoned(
        () async => _fail(
          'idempotency_outcome_pruned',
          'The original outcome for this idempotency identity was pruned from '
              'the bounded runtime cache. Scout will not dispatch it again.',
          extra: keyEvidence(receiptState: 'exact_tombstone'),
        ),
        zoneValues: {_requestContextZoneKey: context},
      );
    }
    if (_mutationTombstoneState.filter.mightContain(key)) {
      return runZoned(
        () async => _fail(
          'idempotency_outcome_pruned',
          'This idempotency key may belong to a pruned mutation outcome. '
              'Scout fails closed and will not dispatch it.',
          extra: {...keyEvidence(receiptState: 'probabilistic_tombstone')},
        ),
        zoneValues: {_requestContextZoneKey: context},
      );
    }

    // Bound queued/in-flight requests too. Completed records are converted to
    // tombstones before admitting a new identity; if all slots are active,
    // reject instead of growing memory without bound.
    _trimMutationRecords(maximum: _maxMutationOutcomeRecords - 1);
    if (_mutationRecords.length >= _maxMutationOutcomeRecords) {
      return runZoned(
        () async => _fail(
          'idempotency_registry_capacity_reached',
          'The bounded runtime idempotency registry is full. Nothing was '
              'dispatched; retry only after current mutations complete.',
        ),
        zoneValues: {_requestContextZoneKey: context},
      );
    }

    final record = _MutationRecord(fingerprint: fingerprint);
    _mutationRecords[key] = record;
    final scheduled = _mutationTail.then((_) async {
      return runZoned(
        () => _runSerializedMutation(context, callback),
        zoneValues: {_requestContextZoneKey: context},
      );
    });
    _mutationTail = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    unawaited(
      scheduled
          .then<void>(
            record.completer.complete,
            onError: (Object error, StackTrace stack) {
              record.completer.complete(
                runZoned(
                  () => _fail('mutation_executor_failed', error.toString()),
                  zoneValues: {_requestContextZoneKey: context},
                ),
              );
            },
          )
          .whenComplete(() {
            record.completed = true;
            _trimMutationRecords(maximum: _maxMutationOutcomeRecords);
          }),
    );
    return record.completer.future;
  }

  Future<developer.ServiceExtensionResponse> _runSerializedMutation(
    _RequestContext context,
    Future<developer.ServiceExtensionResponse> Function(
      String method,
      Map<String, String> params,
    )
    callback,
  ) async {
    final deadline = context.deadlineEpochMs!;
    if (DateTime.now().millisecondsSinceEpoch >= deadline) {
      final command = context.extensionName.split('.').last;
      if (_heldDrag != null &&
          (command == 'dragMove' ||
              command == 'dragEnd' ||
              command == 'dragCancel')) {
        await _cancelHeldDragSafely();
      }
      return _fail(
        'mutation_deadline_expired',
        'The mutation deadline expired before dispatch; nothing was mutated.',
        extra: {'deadlineEpochMs': deadline},
      );
    }

    final validationError = _validateMutationImmediatelyBeforeDispatch(context);
    if (validationError != null) return validationError;

    final command = context.extensionName.split('.').last;
    final dragLifecycleCommand =
        command == 'dragStart' ||
        command == 'dragMove' ||
        command == 'dragEnd' ||
        command == 'dragCancel';
    if (DateTime.now().millisecondsSinceEpoch >= deadline) {
      if (_heldDrag != null && dragLifecycleCommand) {
        await _cancelHeldDragSafely();
      }
      return _fail(
        'mutation_deadline_expired',
        'The mutation deadline expired before dispatch; nothing was mutated.',
        extra: {'deadlineEpochMs': deadline},
      );
    }
    try {
      context.handlerEntered = true;
      final response = await callback(context.method, context.params);
      if (dragLifecycleCommand && _responseFailed(response)) {
        await _cancelHeldDragSafely();
      }
      return response;
    } catch (error) {
      if (_heldDrag != null) await _cancelHeldDragSafely();
      return _fail('mutation_dispatch_failed', error.toString());
    }
  }

  ({String code, String message, Map<String, Object?> details})?
  _typedParameterBoundaryIssue(
    String extensionName,
    Map<String, String> params,
  ) {
    if (params.length > _maxProtocolRequestParameters) {
      return (
        code: 'request_parameter_count_exceeded',
        message:
            'The typed helper request exceeds the bounded parameter count.',
        details: <String, Object?>{
          'maximumParameterCount': _maxProtocolRequestParameters,
          'observedParameterCount': params.length,
        },
      );
    }
    for (final name in params.keys) {
      final nameBytes = _boundedProtocolRequestUtf8Length(
        name,
        _maxProtocolRequestParameterNameBytes,
      );
      if (nameBytes == null) {
        return (
          code: 'request_parameter_name_too_large',
          message: 'A typed helper parameter name exceeds the request bound.',
          details: <String, Object?>{
            'maximumParameterNameUtf8Bytes':
                _maxProtocolRequestParameterNameBytes,
            'observedParameterNameCodeUnits': name.codeUnits.length,
          },
        );
      }
    }
    final command = extensionName.split('.').last;
    final methodContract = _helperMethodContracts[command];
    if (methodContract == null) {
      return (
        code: 'unsupported_method',
        message: 'The typed helper method `$extensionName` is not supported.',
        details: <String, Object?>{
          'method': extensionName,
          'supportedMethods': <String>[
            for (final name in _helperMethodContracts.keys)
              'ext.flutter_scout.$name',
          ]..sort(),
        },
      );
    }
    final allowed = <String>{
      ..._commonProtocolParameters,
      ..._vmTransportProtocolParameters,
      ...methodContract.parameters.keys,
    };
    final unknown =
        params.keys.where((name) => !allowed.contains(name)).toList()..sort();
    if (unknown.isNotEmpty) {
      return (
        code: 'unknown_parameter',
        message:
            'The typed helper method `$extensionName` received one or more '
            'parameters outside its allowlist.',
        details: <String, Object?>{
          'method': extensionName,
          'unknownParameterCount': unknown.length,
          'unknownParameterDisclosure': 'omitted_untrusted_input',
          'allowedParameters': allowed.toList()..sort(),
        },
      );
    }
    return _typedParameterValueIssue(params);
  }

  int? _boundedProtocolRequestUtf8Length(String value, int maximumBytes) {
    // Avoid allocating a second multi-megabyte buffer for obviously oversized
    // ASCII input. UTF-8 is never shorter than the UTF-16 code-unit count.
    if (value.codeUnits.length > maximumBytes) return null;
    final bytes = utf8.encode(value).length;
    return bytes <= maximumBytes ? bytes : null;
  }

  ({String code, String message, Map<String, Object?> details})?
  _typedParameterValueIssue(Map<String, String> params) {
    final idempotencyKey = params['idempotencyKey'];
    if (idempotencyKey != null &&
        (idempotencyKey.codeUnits.length > 128 ||
            !_safeProtocolIdempotencyKey.hasMatch(idempotencyKey))) {
      return (
        code: 'invalid_idempotency_key',
        message:
            'idempotencyKey must contain 1-128 safe ASCII characters and '
            'start with a letter or digit.',
        details: <String, Object?>{
          'minimumLength': 1,
          'maximumLength': 128,
          'allowedPattern': r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
          'idempotencyKeyStatus': 'invalid_omitted',
          'rawIdempotencyKeyRetained': false,
        },
      );
    }

    var totalBytes = 0;
    for (final entry in params.entries) {
      final maximumBytes =
          _protocolParameterByteLimits[entry.key] ??
          (_bulkProtocolParameters.contains(entry.key)
              ? _maxProtocolRequestBulkValueBytes
              : _maxProtocolRequestValueBytes);
      final valueBytes = _boundedProtocolRequestUtf8Length(
        entry.value,
        maximumBytes,
      );
      if (valueBytes == null) {
        return (
          code: 'request_parameter_too_large',
          message:
              'A typed helper parameter value exceeds its UTF-8 byte bound.',
          details: <String, Object?>{
            'parameter': entry.key,
            'maximumValueUtf8Bytes': maximumBytes,
            'observedValueCodeUnits': entry.value.codeUnits.length,
            'bulkParameter': _bulkProtocolParameters.contains(entry.key),
          },
        );
      }
      totalBytes += utf8.encode(entry.key).length + valueBytes;
      if (totalBytes > _maxProtocolRequestTotalBytes) {
        return (
          code: 'request_payload_too_large',
          message:
              'The typed helper request exceeds its total UTF-8 byte bound.',
          details: <String, Object?>{
            'maximumTotalParameterUtf8Bytes': _maxProtocolRequestTotalBytes,
            'observedParameterUtf8BytesLowerBound': totalBytes,
          },
        );
      }
    }
    return null;
  }

  developer.ServiceExtensionResponse? _staticMutationEnvelopeError(
    Map<String, String> params,
  ) {
    final missing = [
      for (final name in _requiredMutationEnvelopeParameters)
        if ((params[name] ?? '').trim().isEmpty) name,
    ];
    if (missing.isNotEmpty) {
      return _fail(
        'missing_mutation_envelope',
        'Mutating requests require every protocol safety field.',
        extra: {'missingFields': missing},
      );
    }

    final schemaVersion = int.tryParse(params['schemaVersion']!);
    if (schemaVersion != scoutHelperSchemaVersion) {
      return _fail(
        'incompatible_schema',
        'schemaVersion=${params['schemaVersion']} is not supported.',
        extra: {'supportedSchemaVersion': scoutHelperSchemaVersion},
      );
    }
    final clientMin = int.tryParse(params['clientProtocolMin']!);
    final clientMax = int.tryParse(params['clientProtocolMax']!);
    if (clientMin == null ||
        clientMax == null ||
        clientMin > clientMax ||
        clientMax < scoutHelperMinSupportedProtocolVersion ||
        clientMin > scoutHelperMaxSupportedProtocolVersion) {
      return _fail(
        'incompatible_protocol',
        'The client and helper protocol ranges do not overlap.',
        extra: {
          'clientProtocolMin': clientMin,
          'clientProtocolMax': clientMax,
          'minSupportedProtocolVersion': scoutHelperMinSupportedProtocolVersion,
          'maxSupportedProtocolVersion': scoutHelperMaxSupportedProtocolVersion,
        },
      );
    }
    if (int.tryParse(params['expectedStateGeneration']!) == null) {
      return _fail(
        'invalid_state_generation',
        'expectedStateGeneration must be an integer.',
      );
    }
    if (int.tryParse(params['deadlineEpochMs']!) == null) {
      return _fail(
        'invalid_deadline',
        'deadlineEpochMs must be an integer Unix epoch in milliseconds.',
      );
    }
    return null;
  }

  developer.ServiceExtensionResponse?
  _validateMutationImmediatelyBeforeDispatch(_RequestContext context) {
    final params = context.params;
    if (params['runtimeInstanceId'] != _runtimeInstanceId) {
      return _fail(
        'runtime_instance_mismatch',
        'The request belongs to a different helper runtime instance.',
        extra: {
          'expectedRuntimeInstanceId': _runtimeInstanceId,
          'receivedRuntimeInstanceId': params['runtimeInstanceId'],
        },
      );
    }

    final command = context.extensionName.split('.').last;
    final heldDragCommand =
        command == 'dragMove' ||
        command == 'dragEnd' ||
        command == 'dragCancel';
    if (_heldDrag != null && !heldDragCommand) {
      return _fail(
        'held_drag_active',
        'A held drag exclusively owns the mutation channel.',
        extra: {
          'allowedCommands': ['dragMove', 'dragEnd', 'dragCancel'],
        },
      );
    }

    ScoutSnapshot current;
    try {
      current = _snapshot();
    } catch (error) {
      return _fail(
        'state_observation_failed',
        'Current state could not be observed safely: $error',
      );
    }
    final expectedGeneration = int.parse(params['expectedStateGeneration']!);
    if (expectedGeneration != current.stateGeneration) {
      return _fail(
        'stale_state_generation',
        'The observed app state changed before mutation dispatch.',
        extra: {
          'expectedStateGeneration': expectedGeneration,
          'actualStateGeneration': current.stateGeneration,
          'actualSnapshotId': current.snapshotId,
        },
      );
    }

    final requestRunId = params['runId']!.trim();
    final requiredRunId = _boundRunId;
    if (requiredRunId != null && requestRunId != requiredRunId) {
      return _fail(
        'run_mismatch',
        'The request belongs to a different Scout run.',
        extra: {'expectedRunId': requiredRunId, 'receivedRunId': requestRunId},
      );
    }

    _boundRunId ??= requestRunId;
    return null;
  }

  Future<void> _cancelHeldDragSafely() async {
    final active = _heldDrag;
    if (active == null) return;
    if (active.pointer < 0) {
      _heldDragExpiry?.cancel();
      _heldDragExpiry = null;
      _heldDrag = null;
      return;
    }
    try {
      await _finishHeldDrag(cancel: true);
    } catch (_) {
      _heldDragExpiry?.cancel();
      _heldDragExpiry = null;
      _heldDrag = null;
      if (_syntheticGestureDepth > 0) _syntheticGestureDepth -= 1;
    }
  }

  bool _responseFailed(developer.ServiceExtensionResponse response) {
    try {
      final decoded = jsonDecode(response.result ?? '');
      return decoded is Map && decoded['ok'] == false;
    } catch (_) {
      return true;
    }
  }

  String _mutationFingerprint(_RequestContext context) {
    const volatile = <String>{
      'schemaVersion',
      'clientProtocolMin',
      'clientProtocolMax',
      'commandId',
      'idempotencyKey',
      'expectedStateGeneration',
      'deadlineEpochMs',
      'errorCursor',
      'errorsSinceCursor',
      'isolateId',
    };
    final businessParams = <String, String>{
      for (final entry in context.params.entries)
        if (!volatile.contains(entry.key)) entry.key: entry.value,
    };
    return crypto.sha256
        .convert(
          utf8.encode(
            _canonicalJson({
              'extension': context.extensionName,
              'method': context.method,
              'params': businessParams,
            }),
          ),
        )
        .toString();
  }

  void _trimMutationRecords({required int maximum}) {
    while (_mutationRecords.length > maximum) {
      String? oldestCompleted;
      String? fingerprint;
      for (final entry in _mutationRecords.entries) {
        if (entry.value.completed) {
          oldestCompleted = entry.key;
          fingerprint = entry.value.fingerprint;
          break;
        }
      }
      if (oldestCompleted == null) return;
      _mutationRecords.remove(oldestCompleted);
      _mutationTombstoneState.remember(oldestCompleted, fingerprint!);
    }
  }

  ScoutSnapshot _withStateIdentity(ScoutSnapshot snapshot) {
    final digest = crypto.sha256
        .convert(utf8.encode(_canonicalJson(_canonicalAgentState(snapshot))))
        .toString();
    if (_lastStateDigest != digest) {
      _lastStateDigest = digest;
      _stateGeneration += 1;
    }
    return _rememberNavigationSnapshot(
      snapshot.copyWith(stateGeneration: _stateGeneration, stateDigest: digest),
    );
  }

  Map<String, Object?> _canonicalAgentState(ScoutSnapshot snapshot) {
    final state = Map<String, Object?>.from(snapshot.toJson())
      ..remove('stateGeneration')
      ..remove('stateDigest')
      ..remove('snapshotId')
      ..remove('visibleTextHash')
      ..['recentErrors'] = [
        for (final error in _errors)
          {
            'cursor': error['cursor'],
            'errorCursor': error['errorCursor'],
            'logCursor': error['logCursor'],
            'actionCommandId': error['actionCommandId'],
            'identity': error['identity'],
            'type': error['type'],
            'message': error['message'],
            if (error['library'] != null) 'library': error['library'],
            'timestamp': error['timestamp'],
            'severity': error['severity'],
            'blocking': error['blocking'],
            'phase': error['phase'],
            'provenance': error['provenance'],
            'correlation': error['correlation'],
            'runId': error['runId'],
            'runtimeInstanceId': error['runtimeInstanceId'],
            'stateGeneration': error['stateGeneration'],
            'snapshotId': error['snapshotId'],
            'stateIdentityStatus': error['stateIdentityStatus'],
          },
      ];
    state['redactedFieldTokens'] = {
      for (final field in snapshot.fields)
        if (field.redacted) field.id: field._valueToken,
    };
    state['scoutAnnotations'] = {
      'enabled': _annotationMode,
      'handoffSeq': _annotationHandoffSeq,
      'items': [for (final annotation in _annotations) annotation.toJson()],
    };
    state['scoutRecorder'] = {
      'recording': _recording,
      'paused': _recordPaused,
      'name': _recordName,
      'feature': _recordFeature,
      'title': _recordTitle,
      'startScreen': _recordStartScreen,
      'stepCount': _recordSteps.length,
    };
    return _redactSensitiveMap(state);
  }

  String _canonicalJson(Object? value) => jsonEncode(_canonicalValue(value));

  Object? _canonicalValue(Object? value) {
    if (value is Map) {
      final entries = <MapEntry<String, Object?>>[
        for (final entry in value.entries)
          MapEntry(entry.key.toString(), _canonicalValue(entry.value)),
      ]..sort((a, b) => a.key.compareTo(b.key));
      return <String, Object?>{
        for (final entry in entries) entry.key: entry.value,
      };
    }
    if (value is Iterable) {
      return [for (final item in value) _canonicalValue(item)];
    }
    if (value is num || value is bool || value is String || value == null) {
      return value;
    }
    return value.toString();
  }

  String _runtimeSignalIdentity({
    required String type,
    required String message,
    String? library,
  }) {
    return crypto.sha256
        .convert(
          utf8.encode(
            _canonicalJson({
              'type': type,
              'message': message,
              'library': ?library,
            }),
          ),
        )
        .toString();
  }

  ({String code, String reason, int? encodedBytesLowerBound})?
  _protocolPayloadIssue(Object? root) {
    try {
      return _inspectProtocolPayload(root);
    } catch (_) {
      return (
        code: 'truncated_safety_evidence',
        reason: 'payload_inspection_failed',
        encodedBytesLowerBound: null,
      );
    }
  }

  ({String code, String reason, int? encodedBytesLowerBound})?
  _inspectProtocolPayload(Object? root) {
    final pending = <({Object? value, int depth})>[(value: root, depth: 0)];
    var nodes = 0;
    var encodedBytesLowerBound = 0;

    bool addStringBytes(String value) {
      // UTF-8 is never shorter than the UTF-16 code-unit count for the ASCII
      // protocol surfaces that dominate these payloads. Avoid first allocating
      // another multi-megabyte buffer when the value alone already exceeds the
      // response contract.
      final remaining = _maxProtocolResponseBytes - encodedBytesLowerBound;
      if (remaining < 0 || value.codeUnits.length > remaining) {
        encodedBytesLowerBound = _maxProtocolResponseBytes + 1;
        return false;
      }
      encodedBytesLowerBound += utf8.encode(value).length;
      return encodedBytesLowerBound <= _maxProtocolResponseBytes;
    }

    while (pending.isNotEmpty) {
      final item = pending.removeLast();
      nodes += 1;
      if (nodes > _maxProtocolPayloadNodes) {
        return (
          code: 'truncated_safety_evidence',
          reason: 'payload_node_limit_exceeded',
          encodedBytesLowerBound: encodedBytesLowerBound,
        );
      }
      if (item.depth > _maxProtocolPayloadDepth) {
        return (
          code: 'truncated_safety_evidence',
          reason: 'payload_depth_limit_exceeded',
          encodedBytesLowerBound: encodedBytesLowerBound,
        );
      }
      final value = item.value;
      if (value == null) {
        encodedBytesLowerBound += 4;
      } else if (value is bool) {
        encodedBytesLowerBound += value ? 4 : 5;
      } else if (value is num) {
        if (value is double && !value.isFinite) {
          return (
            code: 'truncated_safety_evidence',
            reason: 'non_finite_number',
            encodedBytesLowerBound: encodedBytesLowerBound,
          );
        }
        encodedBytesLowerBound += value.toString().length;
      } else if (value is String) {
        if (!addStringBytes(value)) {
          return (
            code: 'response_payload_too_large',
            reason: 'payload_scalar_bytes_exceeded',
            encodedBytesLowerBound: encodedBytesLowerBound,
          );
        }
      } else if (value is Map) {
        encodedBytesLowerBound += 2;
        for (final entry in value.entries) {
          if (!addStringBytes(entry.key.toString())) {
            return (
              code: 'response_payload_too_large',
              reason: 'payload_map_key_bytes_exceeded',
              encodedBytesLowerBound: encodedBytesLowerBound,
            );
          }
          pending.add((value: entry.value, depth: item.depth + 1));
          if (pending.length + nodes > _maxProtocolPayloadNodes) {
            return (
              code: 'truncated_safety_evidence',
              reason: 'payload_node_limit_exceeded',
              encodedBytesLowerBound: encodedBytesLowerBound,
            );
          }
        }
      } else if (value is Iterable) {
        encodedBytesLowerBound += 2;
        for (final child in value) {
          pending.add((value: child, depth: item.depth + 1));
          if (pending.length + nodes > _maxProtocolPayloadNodes) {
            return (
              code: 'truncated_safety_evidence',
              reason: 'payload_node_limit_exceeded',
              encodedBytesLowerBound: encodedBytesLowerBound,
            );
          }
        }
      } else {
        return (
          code: 'truncated_safety_evidence',
          reason: 'unsupported_payload_value_type',
          encodedBytesLowerBound: encodedBytesLowerBound,
        );
      }
      if (encodedBytesLowerBound > _maxProtocolResponseBytes) {
        return (
          code: 'response_payload_too_large',
          reason: 'payload_bytes_exceeded',
          encodedBytesLowerBound: encodedBytesLowerBound,
        );
      }
    }
    return null;
  }

  String _boundedProtocolText(
    String value, {
    int maximumBytes = _maxProtocolIdentityBytes,
  }) {
    final redacted = _redactSensitiveText(value);
    if (redacted.codeUnits.length <= maximumBytes &&
        utf8.encode(redacted).length <= maximumBytes) {
      return redacted;
    }
    return 'sha256:${crypto.sha256.convert(utf8.encode(redacted))}';
  }

  List<Map<String, Object?>> _compactProtocolSignals({
    required bool activeOnly,
  }) {
    final context = _requestContext;
    final effectiveCursor = context?.errorCursor ?? -1;
    final activeCursors = _activeVisibleErrorSignalCursors.values.toSet();
    final now = DateTime.now().toUtc();
    final compact = <Map<String, Object?>>[];
    for (final error in _errors) {
      final cursor = error['cursor'] as int? ?? 0;
      final active = activeCursors.contains(cursor);
      if (activeOnly ? !active : cursor <= effectiveCursor) continue;
      final timestamp = DateTime.tryParse(error['timestamp']?.toString() ?? '');
      final ageMs = timestamp == null
          ? null
          : math.max(0, now.difference(timestamp.toUtc()).inMilliseconds);
      final stale = active ? false : ageMs == null || ageMs > 30000;
      String? bounded(Object? value) => value == null
          ? null
          : _boundedProtocolText(
              value.toString(),
              maximumBytes: _maxCompactSignalStringBytes,
            );
      final provenance = error['provenance'];
      compact.add(<String, Object?>{
        'cursor': cursor,
        'errorCursor': error['errorCursor'] is int
            ? error['errorCursor']
            : cursor,
        'logCursor': error['logCursor'] is int ? error['logCursor'] : cursor,
        'identity': bounded(error['identity']),
        'type': bounded(error['type']) ?? 'runtime_signal',
        'message':
            'Diagnostic text omitted because the original response exceeded its safety bound.',
        'diagnosticOmitted': true,
        'severity': bounded(error['severity']) ?? 'unknown',
        'blocking': error['blocking'] == true,
        'phase': bounded(error['phase']) ?? 'unknown',
        'timestamp': bounded(error['timestamp']),
        'timestampStatus': timestamp == null
            ? 'unavailable'
            : 'observed_in_runtime',
        'ageMs': ageMs,
        'ageStatus': ageMs == null ? 'unknown' : 'measured',
        'freshness': active
            ? 'currently_active'
            : stale
            ? 'stale'
            : 'fresh',
        'stale': stale,
        'actionCommandId': ?bounded(error['actionCommandId']),
        'runId': ?bounded(error['runId']),
        'runtimeInstanceId': _runtimeInstanceId,
        if (error['stateGeneration'] is int)
          'stateGeneration': error['stateGeneration'],
        'snapshotId': ?bounded(error['snapshotId']),
        if (provenance is Map)
          'provenance': <String, Object?>{
            'source': ?bounded(provenance['source']),
            'capture': ?bounded(provenance['capture']),
            'observedBy': 'flutter_scout_helper',
          },
        if (active) ...const <String, Object?>{
          'active': true,
          'activeStatus': 'currently_observed',
          'causalAttribution': 'not_established',
        },
      });
    }
    return compact;
  }

  String _boundedDispatchStatus(Object? source) {
    final context = _requestContext;
    if (context?.mutating != true) return 'not_applicable';
    if (source is Map) {
      final direct = source['dispatch']?.toString();
      if (direct == 'not_dispatched' ||
          direct == 'dispatched' ||
          direct == 'dispatch_outcome_unknown') {
        return direct!;
      }
      final activation = source['activation'];
      if (activation is Map) {
        if (activation['dispatched'] == false) return 'not_dispatched';
        if (activation['dispatched'] == true) return 'dispatched';
      }
    }
    return context?.handlerEntered == true
        ? 'dispatch_outcome_unknown'
        : 'not_dispatched';
  }

  Map<String, Object?> _boundedMutationRequestEvidence() {
    final context = _requestContext;
    if (context?.mutating != true) return const <String, Object?>{};
    final rawKey = context?.params['idempotencyKey'];
    final safeKey =
        rawKey != null &&
            rawKey.codeUnits.length <= 128 &&
            _safeProtocolIdempotencyKey.hasMatch(rawKey)
        ? rawKey
        : null;
    return <String, Object?>{
      if (safeKey != null)
        'idempotencyKeyDigest': crypto.sha256
            .convert(utf8.encode(safeKey))
            .toString(),
      'idempotencyKeySource': 'request_envelope',
      'idempotencyKeyStatus': safeKey != null
          ? 'valid_digest_only'
          : rawKey == null || rawKey.isEmpty
          ? 'missing'
          : 'invalid_omitted',
      'rawIdempotencyKeyRetained': false,
      'expectedStateGeneration': int.tryParse(
        context?.params['expectedStateGeneration'] ?? '',
      ),
      'deadlineEpochMs': context?.deadlineEpochMs,
    };
  }

  Map<String, Object?> _closedRequestPhaseTimings() {
    final timings = _requestPhaseTimings;
    if (timings != null) return timings.finalizePhases();
    return <String, Object?>{
      for (final phase in _scoutRequestPhaseNames)
        phase: <String, Object?>{
          'status': 'unavailable',
          'elapsedMs': null,
          'owner': _helperRequestPhaseNames.contains(phase) ? 'helper' : 'cli',
          'reason': 'request_timing_context_unavailable',
        },
    };
  }

  ({
    String? failureCode,
    String? failureReason,
    int? originalEncodedBytes,
    String? encoded,
    int elapsedMs,
  })
  _probeProtocolEnvelope(Map<String, Object?> envelope) {
    final stopwatch = Stopwatch()..start();

    int finish() {
      stopwatch.stop();
      return stopwatch.elapsedMilliseconds;
    }

    final issue = _protocolPayloadIssue(envelope);
    if (issue != null) {
      return (
        failureCode: issue.code,
        failureReason: issue.reason,
        originalEncodedBytes: issue.encodedBytesLowerBound,
        encoded: null,
        elapsedMs: finish(),
      );
    }
    late final String encoded;
    try {
      encoded = jsonEncode(envelope);
    } catch (_) {
      return (
        failureCode: 'truncated_safety_evidence',
        failureReason: 'json_encoding_failed',
        originalEncodedBytes: null,
        encoded: null,
        elapsedMs: finish(),
      );
    }
    final encodedBytes = utf8.encode(encoded).length;
    if (encodedBytes > _maxProtocolResponseBytes) {
      return (
        failureCode: 'response_payload_too_large',
        failureReason: 'encoded_payload_bytes_exceeded',
        originalEncodedBytes: encodedBytes,
        encoded: null,
        elapsedMs: finish(),
      );
    }
    return (
      failureCode: null,
      failureReason: null,
      originalEncodedBytes: encodedBytes,
      encoded: encoded,
      elapsedMs: finish(),
    );
  }

  void _recordHelperSerializeProbe(
    Map<String, Object?> envelope,
    int elapsedMs,
  ) {
    // Direct debug handlers intentionally have no request timing context. Keep
    // all eight phases explicitly unavailable for those bypasses; every public
    // VM-service request is tracked by `_dispatchProtocolRequest`.
    if (_requestPhaseTimings == null) return;
    final timings = envelope['timings'];
    if (timings is! Map) return;
    final phases = timings['phases'];
    if (phases is! Map) return;
    phases['serialize'] = <String, Object?>{
      'status': 'measured',
      'elapsedMs': elapsedMs,
      'owner': 'helper',
      'scope': 'first_canonical_vm_response_encode_probe',
      'clock': 'monotonic_stopwatch',
      'aggregation': 'exclusive_non_overlapping',
    };
  }

  String? _finalProtocolEncoding(Map<String, Object?> envelope) {
    if (_protocolPayloadIssue(envelope) != null) return null;
    try {
      final encoded = jsonEncode(envelope);
      if (utf8.encode(encoded).length > _maxProtocolResponseBytes) return null;
      return encoded;
    } catch (_) {
      return null;
    }
  }

  developer.ServiceExtensionResponse _protocolBoundFailure({
    required String code,
    required String reason,
    required Object? source,
    int? originalEncodedBytes,
    String? originalErrorCode,
    String? originalErrorMessage,
  }) {
    final context = _requestContext;
    final errors = _compactProtocolSignals(activeOnly: false);
    final activeSignals = _compactProtocolSignals(activeOnly: true);
    final activeBlockingSignals = <Map<String, Object?>>[
      for (final signal in activeSignals)
        if (signal['blocking'] == true) signal,
    ];
    final blocking =
        activeBlockingSignals.isNotEmpty ||
        errors.any(
          (signal) => signal['blocking'] == true && signal['stale'] != true,
        );
    final dispatch = _boundedDispatchStatus(source);
    final mutation = context?.mutating == true;
    final expectationRequested =
        context?.params.keys.any(
          (name) => name.startsWith('expect') || name == 'capture',
        ) ==
        true;
    final message = code == 'response_payload_too_large'
        ? 'The helper response exceeded the 4 MiB encoded payload bound. The oversized result was omitted.'
        : 'The helper could not prove that all safety evidence fit the bounded typed response. The original result was omitted.';
    final commandId = _boundedProtocolText(
      context?.commandId ?? context?.method ?? 'debug-bypass',
    );
    final rawRunId = _boundRunId ?? context?.runId;
    final runId = rawRunId == null ? null : _boundedProtocolText(rawRunId);
    final phases = _closedRequestPhaseTimings();
    final envelope = <String, Object?>{
      'ok': false,
      'stable': false,
      'stability': _unavailableRuntimeStability(code),
      'helperPackageVersion': scoutHelperPackageVersion,
      'helperProtocolVersion': scoutHelperProtocolVersion,
      'schemaVersion': scoutHelperSchemaVersion,
      'protocolVersion': scoutHelperProtocolVersion,
      'minSupportedProtocolVersion': scoutHelperMinSupportedProtocolVersion,
      'maxSupportedProtocolVersion': scoutHelperMaxSupportedProtocolVersion,
      'capabilities': _scoutProtocolCapabilities,
      'commandId': commandId,
      'runId': runId,
      'runtimeInstanceId': _runtimeInstanceId,
      'stateGeneration': _stateGeneration,
      'result': null,
      'structuredError': <String, Object?>{
        'code': code,
        'message': message,
        'details': <String, Object?>{
          'reason': reason,
          'maximumEncodedBytes': _maxProtocolResponseBytes,
          'originalEncodedBytes': ?originalEncodedBytes,
          if (originalErrorCode != null)
            'originalErrorCode': _boundedProtocolText(originalErrorCode),
          if (originalErrorMessage != null)
            'originalErrorMessageDigest': crypto.sha256
                .convert(
                  utf8.encode(_redactSensitiveText(originalErrorMessage)),
                )
                .toString(),
        },
      },
      'error': <String, Object?>{'code': code, 'message': message},
      'resultStatus': 'omitted_due_to_response_bound',
      'timings': <String, Object?>{
        'status': 'partial',
        'phases': phases,
        'totalMs': context?.stopwatch.elapsedMilliseconds ?? 0,
      },
      'payloadBounds': <String, Object?>{
        'status': 'failed_closed',
        'maximumEncodedBytes': _maxProtocolResponseBytes,
        'originalEncodedBytes': ?originalEncodedBytes,
      },
      'safetyEvidenceStatus': 'truncated',
      'transport': 'ok',
      if (mutation) ...<String, Object?>{
        ..._boundedMutationRequestEvidence(),
        'dispatch': dispatch,
        'activation': <String, Object?>{
          'dispatched': switch (dispatch) {
            'dispatched' => true,
            'not_dispatched' => false,
            _ => null,
          },
        },
        'observation': 'observation_unavailable',
        'postcondition': expectationRequested
            ? 'postcondition_not_met'
            : 'postcondition_not_requested',
      },
      'runtimeHealth': blocking ? 'runtime_blocked' : 'runtime_health_unknown',
      'runtimeHealthScope': 'fresh_since_cursor_and_currently_active',
      'errorCursor': _errorCursor,
      'errorsSinceCursor': errors,
      'activeRuntimeSignals': activeSignals,
      'activeBlockingSignals': activeBlockingSignals,
      'recentErrors': errors,
    };
    final probe = _probeProtocolEnvelope(envelope);
    _recordHelperSerializeProbe(envelope, probe.elapsedMs);
    if (probe.failureCode == null) {
      final encoded = _finalProtocolEncoding(envelope);
      if (encoded != null) {
        return developer.ServiceExtensionResponse.result(encoded);
      }
    }

    // This branch is intentionally non-recursive. Every dynamic string is
    // already bounded above, but retain a final constant-size circuit breaker
    // so even a future regression cannot emit an oversized or invalid record.
    final emergencyPhases = _closedRequestPhaseTimings();
    final emergency = <String, Object?>{
      'ok': false,
      'schemaVersion': scoutHelperSchemaVersion,
      'protocolVersion': scoutHelperProtocolVersion,
      'minSupportedProtocolVersion': scoutHelperMinSupportedProtocolVersion,
      'maxSupportedProtocolVersion': scoutHelperMaxSupportedProtocolVersion,
      'capabilities': _scoutProtocolCapabilities,
      'commandId': commandId,
      'runId': runId,
      'runtimeInstanceId': _runtimeInstanceId,
      'stateGeneration': _stateGeneration,
      'result': null,
      'structuredError': <String, Object?>{
        'code': 'truncated_safety_evidence',
        'message':
            'The bounded safety fallback itself exceeded its reserve; detailed evidence was omitted.',
      },
      'timings': <String, Object?>{
        'status': 'partial',
        'phases': emergencyPhases,
        'totalMs': context?.stopwatch.elapsedMilliseconds ?? 0,
      },
      'payloadBounds': const <String, Object?>{
        'status': 'failed_closed',
        'maximumEncodedBytes': _maxProtocolResponseBytes,
      },
      'errorCursor': _errorCursor,
      if (mutation) ...<String, Object?>{
        ..._boundedMutationRequestEvidence(),
        'dispatch': dispatch,
        'activation': <String, Object?>{
          'dispatched': switch (dispatch) {
            'dispatched' => true,
            'not_dispatched' => false,
            _ => null,
          },
        },
      },
      'errorsSinceCursor': blocking
          ? const <Object?>[
              <String, Object?>{
                'type': 'runtime_signal_summary',
                'blocking': true,
                'diagnosticOmitted': true,
                'freshness': 'unknown',
              },
            ]
          : const <Object?>[],
      'activeRuntimeSignals': activeSignals.isEmpty
          ? const <Object?>[]
          : const <Object?>[
              <String, Object?>{
                'type': 'active_runtime_signal_summary',
                'active': true,
                'diagnosticOmitted': true,
              },
            ],
      'activeBlockingSignals': activeBlockingSignals.isEmpty
          ? const <Object?>[]
          : const <Object?>[
              <String, Object?>{
                'type': 'active_runtime_signal_summary',
                'blocking': true,
                'active': true,
                'diagnosticOmitted': true,
              },
            ],
      'runtimeHealth': blocking ? 'runtime_blocked' : 'runtime_health_unknown',
      'safetyEvidenceStatus': 'truncated',
      'signalSummary': <String, Object?>{
        'freshCount': errors.length,
        'activeCount': activeSignals.length,
        'activeBlockingCount': activeBlockingSignals.length,
        'blockingPresent': blocking,
      },
    };
    final emergencyProbe = _probeProtocolEnvelope(emergency);
    _recordHelperSerializeProbe(emergency, emergencyProbe.elapsedMs);
    final emergencyEncoded = _finalProtocolEncoding(emergency);
    if (emergencyEncoded != null) {
      return developer.ServiceExtensionResponse.result(emergencyEncoded);
    }

    // This last candidate is composed only of bounded strings, integers,
    // booleans, nulls, and constant-size collections. Its maximum structural
    // size is therefore orders of magnitude below 4 MiB, and jsonEncode cannot
    // consult caller-controlled converters. Keep it non-recursive while still
    // preserving the safety identities and the canonical eight timing keys.
    final ultimatePhases = <String, Object?>{
      for (final phase in _scoutRequestPhaseNames)
        phase: phase == 'serialize' && _requestPhaseTimings != null
            ? <String, Object?>{
                'status': 'measured',
                'elapsedMs': emergencyProbe.elapsedMs,
                'owner': 'helper',
                'scope': 'first_canonical_vm_response_encode_probe',
                'clock': 'monotonic_stopwatch',
                'aggregation': 'exclusive_non_overlapping',
              }
            : <String, Object?>{
                'status': 'unavailable',
                'elapsedMs': null,
                'owner': _helperRequestPhaseNames.contains(phase)
                    ? 'helper'
                    : 'cli',
                'reason': 'ultimate_response_encoding_fallback',
              },
    };
    final ultimate = <String, Object?>{
      'ok': false,
      'schemaVersion': scoutHelperSchemaVersion,
      'protocolVersion': scoutHelperProtocolVersion,
      'minSupportedProtocolVersion': scoutHelperMinSupportedProtocolVersion,
      'maxSupportedProtocolVersion': scoutHelperMaxSupportedProtocolVersion,
      'capabilities': const <String, bool>{
        'boundedHelperPayloadsV1': true,
        'phaseTimingsV1': true,
      },
      'commandId': commandId,
      'runId': runId,
      'runtimeInstanceId': _boundedProtocolText(_runtimeInstanceId),
      'stateGeneration': _stateGeneration,
      'result': null,
      'resultStatus': 'omitted_due_to_response_bound',
      'structuredError': const <String, Object?>{
        'code': 'truncated_safety_evidence',
        'message': 'The helper safety envelope could not be encoded.',
      },
      'timings': <String, Object?>{
        'status': 'partial',
        'phases': ultimatePhases,
        'totalMs': context?.stopwatch.elapsedMilliseconds ?? 0,
      },
      'payloadBounds': const <String, Object?>{
        'status': 'failed_closed',
        'maximumEncodedBytes': _maxProtocolResponseBytes,
      },
      'safetyEvidenceStatus': 'truncated',
      'transport': 'ok',
      if (mutation) ...<String, Object?>{
        ..._boundedMutationRequestEvidence(),
        'dispatch': dispatch,
        'activation': <String, Object?>{
          'dispatched': switch (dispatch) {
            'dispatched' => true,
            'not_dispatched' => false,
            _ => null,
          },
        },
        'observation': 'observation_unavailable',
        'postcondition': expectationRequested
            ? 'postcondition_not_met'
            : 'postcondition_not_requested',
      },
      'runtimeHealth': blocking ? 'runtime_blocked' : 'runtime_health_unknown',
      'runtimeHealthScope': 'fresh_since_cursor_and_currently_active',
      'errorCursor': _errorCursor,
      'errorsSinceCursor': blocking
          ? const <Object?>[
              <String, Object?>{
                'type': 'runtime_signal_summary',
                'blocking': true,
                'diagnosticOmitted': true,
                'freshness': 'unknown',
              },
            ]
          : const <Object?>[],
      'activeRuntimeSignals': activeSignals.isEmpty
          ? const <Object?>[]
          : const <Object?>[
              <String, Object?>{
                'type': 'active_runtime_signal_summary',
                'active': true,
                'diagnosticOmitted': true,
              },
            ],
      'activeBlockingSignals': activeBlockingSignals.isEmpty
          ? const <Object?>[]
          : const <Object?>[
              <String, Object?>{
                'type': 'active_runtime_signal_summary',
                'blocking': true,
                'active': true,
                'diagnosticOmitted': true,
              },
            ],
    };
    return developer.ServiceExtensionResponse.result(jsonEncode(ultimate));
  }

  developer.ServiceExtensionResponse _encodeProtocolEnvelope(
    Map<String, Object?> envelope, {
    required Object? source,
    String? originalErrorCode,
    String? originalErrorMessage,
  }) {
    // The first canonical bounds + JSON + UTF-8 size probe is timed after the
    // helper-owned phases have been finalized. Its measurement is inserted into
    // the structurally equivalent envelope before the final bounded encode.
    final probe = _probeProtocolEnvelope(envelope);
    _recordHelperSerializeProbe(envelope, probe.elapsedMs);
    if (probe.failureCode != null) {
      return _protocolBoundFailure(
        code: probe.failureCode!,
        reason: probe.failureReason!,
        source: source,
        originalEncodedBytes: probe.originalEncodedBytes,
        originalErrorCode: originalErrorCode,
        originalErrorMessage: originalErrorMessage,
      );
    }
    final encoded = _finalProtocolEncoding(envelope);
    if (encoded == null) {
      return _protocolBoundFailure(
        code: 'response_payload_too_large',
        reason: 'final_encoded_payload_bound_failed',
        source: source,
        originalErrorCode: originalErrorCode,
        originalErrorMessage: originalErrorMessage,
      );
    }
    return developer.ServiceExtensionResponse.result(encoded);
  }

  developer.ServiceExtensionResponse _protocolOk(Map<String, Object?> value) {
    final payloadGeneration = _responseStateGeneration(value);
    if (payloadGeneration == null) _ensureStateObservedForResponse();
    _rememberSensitiveValuesFromTree();
    final rawIssue = _protocolPayloadIssue(value);
    if (rawIssue != null) {
      return _protocolBoundFailure(
        code: rawIssue.code,
        reason: rawIssue.reason,
        source: value,
        originalEncodedBytes: rawIssue.encodedBytesLowerBound,
      );
    }
    late final Map<String, Object?> safeValue;
    try {
      safeValue = _redactSensitiveMap(value);
    } catch (_) {
      return _protocolBoundFailure(
        code: 'truncated_safety_evidence',
        reason: 'payload_redaction_failed',
        source: value,
      );
    }
    final context = _requestContext;
    final result = safeValue.containsKey('result')
        ? safeValue['result']
        : safeValue;
    final phaseTimings = safeValue['timings'];
    final envelope = <String, Object?>{
      ...safeValue,
      'ok': true,
      'helperPackageVersion': scoutHelperPackageVersion,
      'helperProtocolVersion': scoutHelperProtocolVersion,
      'schemaVersion': scoutHelperSchemaVersion,
      'protocolVersion': scoutHelperProtocolVersion,
      'minSupportedProtocolVersion': scoutHelperMinSupportedProtocolVersion,
      'maxSupportedProtocolVersion': scoutHelperMaxSupportedProtocolVersion,
      'capabilities': _scoutProtocolCapabilities,
      'commandId': context?.commandId ?? context?.method ?? 'debug-bypass',
      'runId': _boundRunId ?? context?.runId,
      'runtimeInstanceId': _runtimeInstanceId,
      'stateGeneration': payloadGeneration ?? _stateGeneration,
      'result': result,
      'structuredError': null,
      'timings': <String, Object?>{
        if (phaseTimings is Map)
          for (final entry in phaseTimings.entries)
            if (entry.key.toString() != 'phases')
              entry.key.toString(): entry.value,
        'status': 'partial',
        'phases': _closedRequestPhaseTimings(),
        'totalMs': context?.stopwatch.elapsedMilliseconds ?? 0,
      },
      'payloadBounds': const <String, Object?>{
        'status': 'within_bound',
        'maximumEncodedBytes': _maxProtocolResponseBytes,
      },
      'safetyEvidenceStatus': 'complete',
      'errorCursor': _errorCursor,
      'errorsSinceCursor': _recentErrors(
        sinceCursor: context?.errorCursor,
        useRequestCursor: false,
      ),
      'activeBlockingSignals': _activeBlockingRuntimeSignals(),
    };
    late final Map<String, Object?> safeEnvelope;
    try {
      safeEnvelope = _redactSensitiveMap(envelope);
    } catch (_) {
      return _protocolBoundFailure(
        code: 'truncated_safety_evidence',
        reason: 'envelope_redaction_failed',
        source: value,
      );
    }
    return _encodeProtocolEnvelope(safeEnvelope, source: value);
  }

  developer.ServiceExtensionResponse _protocolFail(
    String code,
    String message, {
    Map<String, Object?> extra = const {},
  }) {
    _ensureStateObservedForResponse();
    _rememberSensitiveValuesFromTree();
    final rawIssue = _protocolPayloadIssue(<String, Object?>{
      'code': code,
      'message': message,
      'extra': extra,
    });
    if (rawIssue != null) {
      return _protocolBoundFailure(
        code: rawIssue.code,
        reason: rawIssue.reason,
        source: extra,
        originalEncodedBytes: rawIssue.encodedBytesLowerBound,
        originalErrorCode: code,
        originalErrorMessage: message,
      );
    }
    final context = _requestContext;
    late final Map<String, Object?> structuredError;
    try {
      structuredError = _redactSensitiveMap({
        'code': code,
        'message': message,
        if (extra.isNotEmpty) 'details': extra,
      });
    } catch (_) {
      return _protocolBoundFailure(
        code: 'truncated_safety_evidence',
        reason: 'error_redaction_failed',
        source: extra,
        originalErrorCode: code,
        originalErrorMessage: message,
      );
    }
    final suppliedStability = extra['stability'];
    final suppliedTimings = extra['timings'];
    final suppliedStable = extra['stable'];
    final failedBeforeMutationHandler =
        context?.mutating == true && context?.handlerEntered != true;
    final envelope = <String, Object?>{
      ...extra,
      if (failedBeforeMutationHandler && !extra.containsKey('dispatch'))
        'dispatch': 'not_dispatched',
      if (failedBeforeMutationHandler && !extra.containsKey('activation'))
        'activation': const <String, Object?>{'dispatched': false},
      'ok': false,
      'stable': suppliedStable is bool ? suppliedStable : false,
      'stability': suppliedStability is Map
          ? suppliedStability
          : _unavailableRuntimeStability(code),
      'helperPackageVersion': scoutHelperPackageVersion,
      'helperProtocolVersion': scoutHelperProtocolVersion,
      'schemaVersion': scoutHelperSchemaVersion,
      'protocolVersion': scoutHelperProtocolVersion,
      'minSupportedProtocolVersion': scoutHelperMinSupportedProtocolVersion,
      'maxSupportedProtocolVersion': scoutHelperMaxSupportedProtocolVersion,
      'capabilities': _scoutProtocolCapabilities,
      'commandId': context?.commandId ?? context?.method ?? 'debug-bypass',
      'runId': _boundRunId ?? context?.runId,
      'runtimeInstanceId': _runtimeInstanceId,
      'stateGeneration': _stateGeneration,
      'result': extra.containsKey('result') ? extra['result'] : null,
      'structuredError': structuredError,
      'error': {'code': code, 'message': message},
      'timings': <String, Object?>{
        if (suppliedTimings is Map)
          for (final entry in suppliedTimings.entries)
            if (entry.key.toString() != 'totalMs' &&
                entry.key.toString() != 'phases')
              entry.key.toString(): entry.value,
        if (suppliedTimings is Map && suppliedTimings['totalMs'] is num)
          'operationTotalMs': suppliedTimings['totalMs'],
        'status': 'partial',
        'phases': _closedRequestPhaseTimings(),
        'totalMs': context?.stopwatch.elapsedMilliseconds ?? 0,
      },
      'payloadBounds': const <String, Object?>{
        'status': 'within_bound',
        'maximumEncodedBytes': _maxProtocolResponseBytes,
      },
      'safetyEvidenceStatus': 'complete',
      'errorCursor': _errorCursor,
      'errorsSinceCursor': _recentErrors(
        sinceCursor: context?.errorCursor,
        useRequestCursor: false,
      ),
      'activeBlockingSignals': _activeBlockingRuntimeSignals(),
      'recentErrors': _recentErrors(),
    };
    late final Map<String, Object?> safeEnvelope;
    try {
      safeEnvelope = _redactSensitiveMap(envelope);
    } catch (_) {
      return _protocolBoundFailure(
        code: 'truncated_safety_evidence',
        reason: 'envelope_redaction_failed',
        source: extra,
        originalErrorCode: code,
        originalErrorMessage: message,
      );
    }
    return _encodeProtocolEnvelope(
      safeEnvelope,
      source: extra,
      originalErrorCode: code,
      originalErrorMessage: message,
    );
  }

  Map<String, Object?> _unavailableRuntimeStability(String failureCode) {
    final context = _requestContext;
    final deadline = context?.deadlineEpochMs;
    final digest = _lastStateDigest;
    final snapshotId = digest == null ? null : 'g$_stateGeneration:$digest';
    return <String, Object?>{
      'state': 'observation_unavailable',
      'actionable': false,
      'stoppingReason': 'request_failed_before_stability:$failureCode',
      'elapsedMs': context?.stopwatch.elapsedMilliseconds ?? 0,
      'budgetMs': deadline == null
          ? null
          : math.max(0, deadline - DateTime.now().millisecondsSinceEpoch),
      'deadlineEpochMs': deadline,
      'bounded': deadline != null,
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
        'stateGeneration': _stateGeneration,
        'stateDigest': digest,
        'snapshotId': snapshotId,
      },
      'final': <String, Object?>{
        'stateGeneration': _stateGeneration,
        'stateDigest': digest,
        'snapshotId': snapshotId,
      },
      'limitations': const <String>[
        'The request failed before a bounded semantic stability observation could complete.',
      ],
    };
  }

  int? _responseStateGeneration(Map<String, Object?> value) {
    final direct = value['stateGeneration'];
    if (direct is int) return direct;
    for (final key in const ['after', 'snapshot']) {
      final nested = value[key];
      if (nested is Map && nested['stateGeneration'] is int) {
        return nested['stateGeneration']! as int;
      }
    }
    return null;
  }

  void _ensureStateObservedForResponse() {
    if (_observingStateForResponse || _heldDrag != null) return;
    _observingStateForResponse = true;
    try {
      _snapshot();
    } catch (_) {
      // A response must still carry the last trustworthy generation when fresh
      // observation is unavailable; the action/inspect handler reports details.
    } finally {
      _observingStateForResponse = false;
    }
  }
}
