part of 'flutter_scout_cli.dart';

// part: bounded, additive CLI response envelopes, structured errors, and
// long-operation heartbeats. Helper envelopes remain authoritative and are
// retained flat; this layer fills the same contract for local CLI commands.

const int _maxCliSerializedResponseBytes = 4 * 1024 * 1024;
const int _maxCliStringCharacters = 65536;
const int _maxCliCollectionEntries = 1024;
const int _maxCliPayloadDepth = 24;
const int _cliEnvelopeReservedEntries = 64;

const Set<String> _cliEnvelopeMetadataKeys = <String>{
  'messageType',
  'ok',
  'schemaVersion',
  'protocolVersion',
  'minSupportedProtocolVersion',
  'maxSupportedProtocolVersion',
  'protocolRange',
  'capabilities',
  'capabilitySource',
  'commandId',
  'cliCommandId',
  'commandName',
  'runId',
  'runtimeInstanceId',
  'stateGeneration',
  'identityStatus',
  'identityAvailability',
  'result',
  'structuredError',
  'timings',
  'payloadBounds',
};

extension _CliResponse on FlutterScoutCli {
  Map<String, Object?> _cliResponseEnvelope(
    Object? value, {
    bool? success,
    String? commandName,
  }) {
    final sanitized = _sanitizeForSerialization(value);
    final raw = sanitized is Map
        ? <String, Object?>{
            for (final entry in sanitized.entries)
              entry.key.toString(): entry.value,
          }
        : <String, Object?>{'value': sanitized};
    // Reserve room for invariant contract fields. A large legacy payload must
    // never push identity or error metadata past the collection cap.
    final bounded = _boundCliPayload(
      raw,
      maxEntries: _maxCliCollectionEntries - _cliEnvelopeReservedEntries,
    );
    final legacy = Map<String, Object?>.from(bounded.value! as Map);
    final nestedResult = legacy['result'] is Map
        ? Map<String, Object?>.from(legacy['result']! as Map)
        : null;

    final declaredOk = success ?? _inferCliResponseSuccess(legacy);
    // Omitted data might contain a blocking error or uncertain dispatch fact.
    // Failing closed is the only generic safe disposition for truncation.
    final ok = declaredOk && !bounded.truncated;
    final structuredError = bounded.truncated
        ? <String, Object?>{
            'code': 'truncated_safety_evidence',
            'message':
                'The response was truncated, so Flutter Scout cannot prove '
                'that all safety and dispatch evidence was preserved.',
            'details': <String, Object?>{
              'declaredOk': declaredOk,
              'truncationCount': bounded.truncationCount,
              'originalErrorCode': _responseErrorCode(raw),
            },
          }
        : ok
        ? null
        : _normalizeCliStructuredError(legacy, nestedResult);
    final responseCommandId = _nonEmptyString(
      legacy.containsKey('commandId')
          ? legacy['commandId']
          : nestedResult?['commandId'] ?? _activeCommandId,
    );
    final cliCommandId = _nonEmptyString(
      legacy.containsKey('cliCommandId')
          ? legacy['cliCommandId']
          : _activeCommandId ?? responseCommandId,
    );
    final sessionMeta = _safeResponseSessionMeta();
    final runId = _nullableIdentity(
      legacy,
      nestedResult,
      'runId',
      fallback: sessionMeta?['runId'],
    );
    final runtimeInstanceId = _nullableIdentity(
      legacy,
      nestedResult,
      'runtimeInstanceId',
      fallback: sessionMeta?['runtimeInstanceId'],
    );
    final stateGeneration = _nullableNonNegativeInt(
      legacy.containsKey('stateGeneration')
          ? legacy['stateGeneration']
          : nestedResult?['stateGeneration'] ?? sessionMeta?['stateGeneration'],
    );
    final resolvedCommandName =
        _nonEmptyString(legacy['commandName']) ??
        commandName ??
        _activeCommandName;
    final protocolVersion =
        _nullableNonNegativeInt(legacy['protocolVersion']) ??
        _scoutCliProtocolMax;
    final protocolMin =
        _nullableNonNegativeInt(legacy['minSupportedProtocolVersion']) ??
        _scoutCliProtocolMin;
    final protocolMax =
        _nullableNonNegativeInt(legacy['maxSupportedProtocolVersion']) ??
        _scoutCliProtocolMax;
    final capabilities = <String, Object?>{
      ..._scoutCliProtocolCapabilities,
      if (legacy['capabilities'] case final Map rawCapabilities)
        for (final entry in rawCapabilities.entries)
          entry.key.toString(): entry.value,
      'cliResponseEnvelopeV1': true,
      'structuredHeartbeatsV1': true,
      'correlatedEventCursorsV1': true,
      'boundedCliPayloadsV1': true,
    };
    final timings = _cliResponseTimings(legacy, nestedResult);
    final result = bounded.truncated
        ? null
        : legacy.containsKey('result')
        ? legacy['result']
        : ok
        ? <String, Object?>{
            for (final entry in legacy.entries)
              if (!_cliEnvelopeMetadataKeys.contains(entry.key))
                entry.key: entry.value,
          }
        : null;
    final identityAvailability = <String, String>{
      'commandId': responseCommandId == null ? 'unavailable' : 'available',
      'cliCommandId': cliCommandId == null ? 'unavailable' : 'available',
      'runId': runId == null ? 'unavailable' : 'available',
      'runtimeInstanceId': runtimeInstanceId == null
          ? 'unavailable'
          : 'available',
      'stateGeneration': stateGeneration == null ? 'unavailable' : 'available',
    };
    final identityStatus =
        _nonEmptyString(legacy['identityStatus']) ??
        (runtimeInstanceId != null && stateGeneration != null
            ? 'observed'
            : runId != null || responseCommandId != null
            ? 'partial'
            : 'unavailable');

    final envelope = <String, Object?>{
      // Insert contract fields before caller-controlled legacy fields so
      // collection bounding can never compact these fields away.
      'messageType': _nonEmptyString(legacy['messageType']) ?? 'response',
      'ok': ok,
      'schemaVersion': _scoutCliSchemaVersion,
      'protocolVersion': protocolVersion,
      'minSupportedProtocolVersion': protocolMin,
      'maxSupportedProtocolVersion': protocolMax,
      'protocolRange': <String, Object?>{
        'minimum': protocolMin,
        'maximum': protocolMax,
        'compatibility':
            protocolVersion >= protocolMin && protocolVersion <= protocolMax
            ? 'within_supported_range'
            : 'outside_supported_range',
      },
      'capabilities': capabilities,
      'capabilitySource': _nonEmptyString(legacy['capabilitySource']) ?? 'cli',
      'commandId': responseCommandId,
      'cliCommandId': cliCommandId,
      'commandName': resolvedCommandName,
      'runId': runId,
      'runtimeInstanceId': runtimeInstanceId,
      'stateGeneration': stateGeneration,
      'identityStatus': identityStatus,
      'identityAvailability': identityAvailability,
      'result': result,
      'structuredError': structuredError,
      'timings': timings,
      'logCursor': _responseLogCursor(legacy, nestedResult),
      'eventCursor': _responseEventCursor(legacy, nestedResult),
      'payloadBounds': <String, Object?>{
        'maxSerializedBytes': _maxCliSerializedResponseBytes,
        'maxStringCharacters': _maxCliStringCharacters,
        'maxCollectionEntries': _maxCliCollectionEntries,
        'maxDepth': _maxCliPayloadDepth,
        'truncated': bounded.truncated,
        'truncationCount': bounded.truncationCount,
        'safetyDisposition': bounded.truncated ? 'failed_closed' : 'complete',
      },
      if (!ok) 'error': structuredError,
      'safetyEvidenceStatus': bounded.truncated ? 'truncated' : 'complete',
    };
    // Preserve legacy flattened fields additively. Canonical contract fields
    // above win collisions so a legacy value cannot weaken the envelope.
    for (final entry in legacy.entries) {
      envelope.putIfAbsent(entry.key, () => entry.value);
    }
    if (envelope['messageType'] == 'response' &&
        const <String>{
          'doctor',
          'status',
          'health',
        }.contains(resolvedCommandName)) {
      envelope['operability'] = _cliOperabilityFacts(
        legacy,
        commandName: resolvedCommandName!,
        runId: runId,
        runtimeInstanceId: runtimeInstanceId,
        stateGeneration: stateGeneration,
        capabilities: capabilities,
        structuredError: structuredError,
      );
    }
    final finalBounded = _boundCliPayload(_sanitizeForSerialization(envelope));
    final output = Map<String, Object?>.from(finalBounded.value! as Map);
    if (finalBounded.truncated && !bounded.truncated) {
      const finalError = <String, Object?>{
        'code': 'truncated_safety_evidence',
        'message':
            'The response was truncated, so Flutter Scout cannot prove that '
            'all safety and dispatch evidence was preserved.',
      };
      output['ok'] = false;
      output['result'] = null;
      output['structuredError'] = finalError;
      output['error'] = finalError;
      output['safetyEvidenceStatus'] = 'truncated';
      output['payloadBounds'] = <String, Object?>{
        'maxSerializedBytes': _maxCliSerializedResponseBytes,
        'maxStringCharacters': _maxCliStringCharacters,
        'maxCollectionEntries': _maxCliCollectionEntries,
        'maxDepth': _maxCliPayloadDepth,
        'truncated': true,
        'truncationCount': finalBounded.truncationCount,
        'safetyDisposition': 'failed_closed',
      };
    }
    return output;
  }

  Map<String, Object?> _cliHeartbeatEnvelope(
    String stage, {
    required int elapsedMs,
    required int heartbeatCursor,
    String? commandId,
    String? runId,
    String? runtimeInstanceId,
    int? stateGeneration,
    Map<String, Object?> progress = const <String, Object?>{},
  }) {
    final boundedProgress = _boundCliPayload(
      _sanitizeForSerialization(progress),
      maxEntries: 128,
      maxStringCharacters: 8192,
      maxDepth: 12,
    );
    return _cliResponseEnvelope(<String, Object?>{
      'messageType': 'heartbeat',
      'ok': true,
      'commandId': commandId ?? _activeCommandId,
      'runId': runId ?? _safeResponseSessionMeta()?['runId'],
      'runtimeInstanceId': runtimeInstanceId,
      'stateGeneration': stateGeneration,
      'stage': stage,
      'elapsedMs': elapsedMs < 0 ? 0 : elapsedMs,
      'heartbeatCursor': heartbeatCursor,
      'progress': boundedProgress.value,
      'result': <String, Object?>{
        'stage': stage,
        'elapsedMs': elapsedMs < 0 ? 0 : elapsedMs,
        'progress': boundedProgress.value,
      },
      'timings': <String, Object?>{
        'elapsedMs': elapsedMs < 0 ? 0 : elapsedMs,
        'totalMs': null,
        'status': 'in_progress',
      },
    });
  }

  void _writeCliResponse(
    Object? value, {
    bool? success,
    String? commandName,
    bool pretty = true,
    bool toStderr = false,
  }) {
    var envelope = _cliResponseEnvelope(
      value,
      success: success,
      commandName: commandName,
    );
    envelope = _withCliSerializeProbe(
      Map<String, dynamic>.from(envelope),
      probeValue: envelope,
      boundary: toStderr ? 'cli_stderr_response' : 'cli_stdout_response',
      pretty: pretty,
    );
    final encoded = _encodeCliMachineMessage(envelope, pretty: pretty);
    (toStderr ? stderr : stdout).writeln(encoded);
  }

  void _writeStructuredError(
    String code,
    String message, {
    Map<String, Object?> details = const <String, Object?>{},
    Map<String, Object?> additional = const <String, Object?>{},
  }) {
    _writeCliResponse(
      <String, Object?>{
        ...additional,
        'ok': false,
        'error': <String, Object?>{
          'code': code,
          'message': message,
          if (details.isNotEmpty) 'details': details,
        },
      },
      success: false,
      pretty: false,
      toStderr: true,
    );
  }

  void _writeStructuredWarning(Map<String, Object?> warning) {
    _writeCliResponse(
      <String, Object?>{
        'messageType': 'warning',
        'ok': true,
        'warning': warning,
        'result': <String, Object?>{'warning': warning},
      },
      pretty: false,
      toStderr: true,
    );
  }

  void _writeHeartbeat(
    String stage, [
    Map<String, Object?> progress = const <String, Object?>{},
    bool toStderr = true,
  ]) {
    final elapsedMs =
        _activeCommandStopwatch?.elapsedMilliseconds ??
        _nullableNonNegativeInt(progress['elapsedMs']) ??
        0;
    var heartbeat = _cliHeartbeatEnvelope(
      stage,
      elapsedMs: elapsedMs,
      heartbeatCursor: ++_heartbeatCursor,
      progress: progress,
    );
    heartbeat = _withCliSerializeProbe(
      Map<String, dynamic>.from(heartbeat),
      probeValue: heartbeat,
      boundary: toStderr ? 'cli_stderr_heartbeat' : 'cli_stdout_heartbeat',
    );
    final encoded = _encodeCliMachineMessage(heartbeat, pretty: false);
    (toStderr ? stderr : stdout).writeln(encoded);
  }

  String _encodeCliMachineMessage(
    Map<String, Object?> envelope, {
    required bool pretty,
  }) {
    final safe = _sanitizeForSerialization(envelope);
    final encoder = pretty
        ? const JsonEncoder.withIndent('  ')
        : const JsonEncoder();
    final encoded = encoder.convert(safe);
    if (utf8.encode(encoded).length <= _maxCliSerializedResponseBytes) {
      return encoded;
    }
    final canonicalFallbackTimings =
        (_withCanonicalPhaseTimings(<String, dynamic>{
              'timings': envelope['timings'],
            })['timings']!
            as Map);
    final fallback = <String, Object?>{
      'messageType': 'response',
      'ok': false,
      'schemaVersion': _scoutCliSchemaVersion,
      'protocolVersion': _scoutCliProtocolMax,
      'minSupportedProtocolVersion': _scoutCliProtocolMin,
      'maxSupportedProtocolVersion': _scoutCliProtocolMax,
      'protocolRange': const <String, Object?>{
        'minimum': _scoutCliProtocolMin,
        'maximum': _scoutCliProtocolMax,
        'compatibility': 'within_supported_range',
      },
      'capabilities': <String, Object?>{
        ..._scoutCliProtocolCapabilities,
        'cliResponseEnvelopeV1': true,
        'structuredHeartbeatsV1': true,
        'correlatedEventCursorsV1': true,
        'boundedCliPayloadsV1': true,
      },
      'commandId': _activeCommandId,
      'cliCommandId': _activeCommandId,
      'commandName': _activeCommandName,
      'runId': _safeResponseSessionMeta()?['runId'],
      'runtimeInstanceId': null,
      'stateGeneration': null,
      'identityStatus': _activeCommandId == null ? 'unavailable' : 'partial',
      'identityAvailability': <String, String>{
        'commandId': _activeCommandId == null ? 'unavailable' : 'available',
        'cliCommandId': _activeCommandId == null ? 'unavailable' : 'available',
        'runId': _safeResponseSessionMeta()?['runId'] == null
            ? 'unavailable'
            : 'available',
        'runtimeInstanceId': 'unavailable',
        'stateGeneration': 'unavailable',
      },
      'result': null,
      'structuredError': const <String, Object?>{
        'code': 'response_payload_too_large',
        'message':
            'The response exceeded Flutter Scout\'s bounded serialization limit.',
      },
      'error': const <String, Object?>{
        'code': 'response_payload_too_large',
        'message':
            'The response exceeded Flutter Scout\'s bounded serialization limit.',
      },
      'timings': <String, Object?>{
        for (final entry in canonicalFallbackTimings.entries)
          entry.key.toString(): entry.value,
        'totalMs': _activeCommandStopwatch?.elapsedMilliseconds,
      },
      'logCursor': _safeCurrentLogCursor(),
      'eventCursor': null,
      'payloadBounds': const <String, Object?>{
        'maxSerializedBytes': _maxCliSerializedResponseBytes,
        'maxStringCharacters': _maxCliStringCharacters,
        'maxCollectionEntries': _maxCliCollectionEntries,
        'maxDepth': _maxCliPayloadDepth,
        'truncated': true,
        'truncationCount': 1,
        'safetyDisposition': 'failed_closed',
      },
      'safetyEvidenceStatus': 'truncated',
    };
    return encoder.convert(fallback);
  }

  bool _inferCliResponseSuccess(Map<String, Object?> value) {
    if (value['ok'] is bool) return value['ok'] == true;
    final exitCode = _nullableNonNegativeInt(value['exitCode']);
    if (exitCode != null) return exitCode == 0;
    if (value['structuredError'] is Map || value['error'] != null) return false;
    return true;
  }

  Map<String, Object?> _normalizeCliStructuredError(
    Map<String, Object?> value,
    Map<String, Object?>? nestedResult,
  ) {
    final candidate =
        value['structuredError'] ??
        value['error'] ??
        nestedResult?['structuredError'] ??
        nestedResult?['error'];
    if (candidate is Map) {
      final mapped = <String, Object?>{
        for (final entry in candidate.entries)
          entry.key.toString(): entry.value,
      };
      final code = _errorCode(mapped['code'] ?? value['reason']);
      final message =
          _nonEmptyString(mapped['message']) ??
          _nonEmptyString(value['reason']) ??
          'The Flutter Scout command failed.';
      return <String, Object?>{...mapped, 'code': code, 'message': message};
    }
    final message =
        _nonEmptyString(candidate) ??
        _nonEmptyString(value['reason']) ??
        'The Flutter Scout command failed.';
    return <String, Object?>{
      'code': _errorCode(value['reason']),
      'message': message,
    };
  }

  String _errorCode(Object? value) {
    final raw = value?.toString().trim().toLowerCase() ?? '';
    final normalized = raw.replaceAll(RegExp(r'[^a-z0-9_]+'), '_');
    return normalized.isNotEmpty && RegExp(r'^[a-z0-9_]+$').hasMatch(normalized)
        ? normalized
        : 'command_failed';
  }

  Map<String, Object?> _cliResponseTimings(
    Map<String, Object?> value,
    Map<String, Object?>? nestedResult,
  ) {
    final source = value['timings'] is Map
        ? value['timings'] as Map
        : nestedResult?['timings'] is Map
        ? nestedResult!['timings'] as Map
        : const <Object?, Object?>{};
    final timings = <String, Object?>{
      for (final entry in source.entries) entry.key.toString(): entry.value,
    };
    final activeElapsed = _activeCommandStopwatch?.elapsedMilliseconds;
    timings['totalMs'] ??= activeElapsed;
    timings['status'] ??= timings['totalMs'] == null
        ? 'unavailable'
        : 'measured';
    final canonical = _withCanonicalPhaseTimings(<String, dynamic>{
      'timings': timings,
    });
    return <String, Object?>{
      for (final entry in (canonical['timings']! as Map).entries)
        entry.key.toString(): entry.value,
    };
  }

  ({Object? value, bool truncated, int truncationCount}) _boundCliPayload(
    Object? value, {
    int maxEntries = _maxCliCollectionEntries,
    int maxStringCharacters = _maxCliStringCharacters,
    int maxDepth = _maxCliPayloadDepth,
    int depth = 0,
  }) {
    if (depth >= maxDepth) {
      return (
        value: '<maximum-depth-exceeded>',
        truncated: true,
        truncationCount: 1,
      );
    }
    if (value is String) {
      if (value.length <= maxStringCharacters) {
        return (value: value, truncated: false, truncationCount: 0);
      }
      return (
        value: '${value.substring(0, maxStringCharacters)}<truncated>',
        truncated: true,
        truncationCount: 1,
      );
    }
    if (value is Map) {
      final out = <String, Object?>{};
      var truncated = false;
      var count = 0;
      var index = 0;
      for (final entry in value.entries) {
        if (index++ >= maxEntries) {
          truncated = true;
          count += 1;
          break;
        }
        final bounded = _boundCliPayload(
          entry.value,
          maxEntries: maxEntries,
          maxStringCharacters: maxStringCharacters,
          maxDepth: maxDepth,
          depth: depth + 1,
        );
        out[entry.key.toString()] = bounded.value;
        truncated = truncated || bounded.truncated;
        count += bounded.truncationCount;
      }
      if (index > maxEntries) {
        if (out.length >= maxEntries && out.isNotEmpty) {
          out.remove(out.keys.last);
        }
        out['_truncatedEntries'] = true;
      }
      return (value: out, truncated: truncated, truncationCount: count);
    }
    if (value is Iterable) {
      final out = <Object?>[];
      var truncated = false;
      var count = 0;
      var index = 0;
      for (final child in value) {
        if (index++ >= maxEntries) {
          truncated = true;
          count += 1;
          break;
        }
        final bounded = _boundCliPayload(
          child,
          maxEntries: maxEntries,
          maxStringCharacters: maxStringCharacters,
          maxDepth: maxDepth,
          depth: depth + 1,
        );
        out.add(bounded.value);
        truncated = truncated || bounded.truncated;
        count += bounded.truncationCount;
      }
      if (index > maxEntries) {
        if (out.length >= maxEntries && out.isNotEmpty) {
          out.removeLast();
        }
        out.add('<truncated-entries>');
      }
      return (value: out, truncated: truncated, truncationCount: count);
    }
    return (value: value, truncated: false, truncationCount: 0);
  }

  Map<String, dynamic>? _safeResponseSessionMeta() {
    try {
      return _readSessionMeta();
    } catch (_) {
      return null;
    }
  }

  bool _safeResponseVmUriAvailable() {
    try {
      return _readVmUri() != null;
    } catch (_) {
      return false;
    }
  }

  int _safeCurrentLogCursor() {
    try {
      return _currentLogCursor();
    } catch (_) {
      return 0;
    }
  }

  int _responseLogCursor(
    Map<String, Object?> value,
    Map<String, Object?>? nestedResult,
  ) =>
      _nullableNonNegativeInt(
        value.containsKey('logCursor')
            ? value['logCursor']
            : nestedResult?['logCursor'],
      ) ??
      _safeCurrentLogCursor();

  int? _responseEventCursor(
    Map<String, Object?> value,
    Map<String, Object?>? nestedResult,
  ) {
    final direct = _nullableNonNegativeInt(value['eventCursor']);
    if (direct != null) return direct;
    final nested = _nullableNonNegativeInt(nestedResult?['eventCursor']);
    if (nested != null) return nested;
    final evidence = value['evidence'];
    return evidence is Map
        ? _nullableNonNegativeInt(evidence['eventCursor'])
        : null;
  }

  Map<String, Object?> _correlateCliEvent(
    Map<String, Object?> event, {
    required bool allowCurrentContext,
  }) {
    final sessionMeta = allowCurrentContext ? _safeResponseSessionMeta() : null;
    final commandId =
        _nonEmptyString(event['commandId']) ??
        _nonEmptyString(event['cliCommandId']) ??
        (allowCurrentContext ? _activeCommandId : null);
    final cliCommandId =
        _nonEmptyString(event['cliCommandId']) ??
        (allowCurrentContext ? _activeCommandId : null);
    final runId =
        _nonEmptyString(event['runId']) ??
        _nonEmptyString(event['sessionRunId']) ??
        _nonEmptyString(sessionMeta?['runId']);
    final runtimeInstanceId = _nonEmptyString(event['runtimeInstanceId']);
    final stateGeneration = _nullableNonNegativeInt(event['stateGeneration']);
    final logCursor =
        _nullableNonNegativeInt(event['logCursor']) ??
        (allowCurrentContext ? _safeCurrentLogCursor() : 0);
    final availability = <String, String>{
      'commandId': commandId == null ? 'unavailable' : 'available',
      'cliCommandId': cliCommandId == null ? 'unavailable' : 'available',
      'runId': runId == null ? 'unavailable' : 'available',
      'runtimeInstanceId': runtimeInstanceId == null
          ? 'unavailable'
          : 'available',
      'stateGeneration': stateGeneration == null ? 'unavailable' : 'available',
      'logCursor': 'available',
    };
    final eventCursor = _nullableNonNegativeInt(
      event['eventCursor'] ?? event['cursor'],
    );
    final correlationId =
        _nonEmptyString(event['correlationId']) ??
        commandId ??
        cliCommandId ??
        runId ??
        (eventCursor == null ? null : 'event-$eventCursor');
    return <String, Object?>{
      ...event,
      'schemaVersion': _scoutCliSchemaVersion,
      'protocolVersion': _scoutCliProtocolMax,
      'commandId': commandId,
      'cliCommandId': cliCommandId,
      'runId': runId,
      'sessionRunId': runId,
      'runtimeInstanceId': runtimeInstanceId,
      'stateGeneration': stateGeneration,
      'logCursor': logCursor,
      'correlationId': correlationId,
      'identityStatus': runtimeInstanceId != null && stateGeneration != null
          ? 'observed'
          : commandId != null || runId != null
          ? 'partial'
          : 'unavailable',
      'correlation': <String, Object?>{
        'commandId': commandId,
        'cliCommandId': cliCommandId,
        'runId': runId,
        'runtimeInstanceId': runtimeInstanceId,
        'stateGeneration': stateGeneration,
        'logCursor': logCursor,
        'availability': availability,
      },
    };
  }

  String? _nullableIdentity(
    Map<String, Object?> value,
    Map<String, Object?>? nestedResult,
    String key, {
    Object? fallback,
  }) {
    final candidate = value.containsKey(key)
        ? value[key]
        : nestedResult?.containsKey(key) == true
        ? nestedResult![key]
        : fallback;
    return _nonEmptyString(candidate);
  }

  String? _nonEmptyString(Object? value) {
    if (value == null) return null;
    final text = value.toString();
    return text.isEmpty ? null : text;
  }

  int? _nullableNonNegativeInt(Object? value) {
    final parsed = switch (value) {
      final int number => number,
      final num number => number.toInt(),
      final String text => int.tryParse(text),
      _ => null,
    };
    return parsed != null && parsed >= 0 ? parsed : null;
  }

  String? _responseErrorCode(Map<String, Object?> value) {
    final candidate = value['structuredError'] ?? value['error'];
    if (candidate is Map) return _nonEmptyString(candidate['code']);
    return null;
  }
}
