part of 'flutter_scout_cli.dart';

// part: canonical eight-phase timing merge and derived action overhead.

const List<String> _scoutCliPhaseNames = <String>[
  'connect',
  'snapshot',
  'match',
  'dispatch',
  'settle',
  'delta',
  'logs',
  'serialize',
];

const Set<String> _scoutCliOwnedPhases = <String>{
  'connect',
  'logs',
  'serialize',
};

/// Request-local connection timing state. Keeping this object on the call
/// stack (rather than on [FlutterScoutCli]) preserves truthful measurements
/// when the persistent server has more than one pending read.
class _CliConnectPhaseTiming {
  Stopwatch? _stopwatch;
  bool? _reused;
  String? _connection;
  String? _outcome;
  String? _unavailableReason;
  int? _elapsedMs;

  void begin({required bool reused, required String connection}) {
    _reused = reused;
    _connection = connection;
    _unavailableReason = null;
    _stopwatch = Stopwatch()..start();
  }

  void complete({required String outcome}) {
    final stopwatch = _stopwatch;
    if (stopwatch == null) return;
    stopwatch.stop();
    _elapsedMs = stopwatch.elapsedMilliseconds;
    _outcome = outcome;
  }

  void unavailable(String reason) {
    _stopwatch?.stop();
    _stopwatch = null;
    _elapsedMs = null;
    _reused = null;
    _connection = null;
    _outcome = null;
    _unavailableReason = reason;
  }

  Map<String, Object?> get phaseRecord {
    final elapsedMs = _elapsedMs;
    if (elapsedMs != null) {
      return <String, Object?>{
        'status': 'measured',
        'elapsedMs': max(0, elapsedMs),
        'owner': 'cli',
        'scope': _reused == true
            ? 'explicit cached VM-service connection reuse decision'
            : 'bounded VM-service connection establishment',
        'clock': 'monotonic_stopwatch',
        'aggregation': 'exclusive_non_overlapping',
        'connection': _connection ?? (_reused == true ? 'reused' : 'new'),
        'reused': _reused == true,
        if (_outcome != null) 'outcome': _outcome,
      };
    }
    return <String, Object?>{
      'status': 'unavailable',
      'elapsedMs': null,
      'owner': 'cli',
      'reason':
          _unavailableReason ?? 'connection_phase_not_reached_before_response',
    };
  }
}

extension _CliPhaseTimings on FlutterScoutCli {
  /// Self-describing placeholder for the generic command lifecycle journal.
  /// That reservation proves a command process existed; it is intentionally
  /// not the action-result evidence record and must never inherit action phase
  /// measurements.
  Map<String, Object?> _lifecycleReservationTimings() => <String, Object?>{
    'totalMs': null,
    'status': 'unavailable',
    'phases': <String, Object?>{
      for (final phase in _scoutCliPhaseNames)
        phase: <String, Object?>{
          'status': 'unavailable',
          'elapsedMs': null,
          'owner': _scoutCliOwnedPhases.contains(phase) ? 'cli' : 'helper',
          'reason': 'lifecycle_reservation_not_action_evidence',
        },
    },
    'actionOverheadExcludingSettle': <String, Object?>{
      'status': 'unavailable',
      'elapsedMs': null,
      'reason': 'lifecycle_reservation_not_action_evidence',
      'unavailablePhases': <String>[
        for (final phase in _scoutCliPhaseNames)
          if (phase != 'settle') phase,
      ],
      'excludes': 'settle',
    },
  };

  int _phaseElapsedMs(Map<String, dynamic> result, String phase) {
    final timings = result['timings'];
    final phases = timings is Map ? timings['phases'] : null;
    final record = phases is Map ? phases[phase] : null;
    return record is Map &&
            record['status'] == 'measured' &&
            record['elapsedMs'] is int
        ? record['elapsedMs'] as int
        : 0;
  }

  Map<String, dynamic> _withMeasuredPhase(
    Map<String, dynamic> result, {
    required String phase,
    required int elapsedMs,
    required String owner,
    required String scope,
    Map<String, Object?> facts = const <String, Object?>{},
  }) {
    if (!_scoutCliPhaseNames.contains(phase)) {
      throw ArgumentError.value(phase, 'phase', 'Unknown Scout timing phase.');
    }
    return _withCanonicalPhaseTimings(result, <String, Object?>{
      phase: <String, Object?>{
        'status': 'measured',
        'elapsedMs': max(0, elapsedMs),
        'owner': owner,
        'scope': scope,
        'clock': 'monotonic_stopwatch',
        'aggregation': 'exclusive_non_overlapping',
        ...facts,
      },
    });
  }

  Map<String, dynamic> _withUnavailablePhase(
    Map<String, dynamic> result, {
    required String phase,
    required String owner,
    required String reason,
  }) {
    if (!_scoutCliPhaseNames.contains(phase)) {
      throw ArgumentError.value(phase, 'phase', 'Unknown Scout timing phase.');
    }
    if (reason.trim().isEmpty) {
      throw ArgumentError.value(reason, 'reason', 'Reason cannot be empty.');
    }
    return _withCanonicalPhaseTimings(result, <String, Object?>{
      phase: <String, Object?>{
        'status': 'unavailable',
        'elapsedMs': null,
        'owner': owner,
        'reason': reason.trim(),
      },
    });
  }

  Map<String, dynamic> _withConnectionPhaseTiming(
    Map<String, dynamic> result,
    _CliConnectPhaseTiming timing,
  ) {
    final canonical = _withCanonicalPhaseTimings(result);
    final phases = ((canonical['timings']! as Map)['phases']! as Map);
    final prior = phases['connect'];
    final delivery = timing.phaseRecord;
    final replaySkippedConnection =
        delivery['status'] == 'unavailable' &&
        delivery['reason'] == 'durable_receipt_replay_skipped_vm_connection';
    if (replaySkippedConnection &&
        prior is Map &&
        prior['status'] == 'measured') {
      // The response is a delivery of the original mutation outcome. Keep the
      // original action transaction's connect measurement; record that replay
      // delivery itself skipped transport without replacing durable evidence.
      return _withCanonicalPhaseTimings(canonical, <String, Object?>{
        'connect': <String, Object?>{
          for (final entry in prior.entries) entry.key.toString(): entry.value,
          'replayDeliveryConnection': 'skipped',
          'replayDeliveryReason': delivery['reason'],
        },
      });
    }
    return _withCanonicalPhaseTimings(canonical, <String, Object?>{
      'connect': delivery,
    });
  }

  Map<String, dynamic> _withInvocationPhaseTimings(
    Map<String, dynamic> result,
    _MutationInvocation invocation,
  ) {
    var timed = _withPreflightPhaseTimings(result, invocation.preflightTimings);
    final connectionPhase = invocation.connectionPhase;
    if (connectionPhase != null) {
      timed = _withCanonicalPhaseTimings(timed, <String, Object?>{
        'connect': connectionPhase,
      });
    }
    return timed;
  }

  /// Adds the helper work from the mandatory inspect preflight to the action
  /// helper response. The two VM calls are sequential, so summing like-named
  /// exclusive intervals cannot create overlap.
  Map<String, dynamic> _withPreflightPhaseTimings(
    Map<String, dynamic> result,
    Object? preflightTimings,
  ) {
    final action = _withCanonicalPhaseTimings(result);
    if (preflightTimings is! Map) return action;
    final preflight = _withCanonicalPhaseTimings(<String, dynamic>{
      'timings': preflightTimings,
    });
    final actionTimings = action['timings']! as Map;
    final actionPhases = actionTimings['phases']! as Map;
    final preflightPhases = ((preflight['timings']! as Map)['phases']! as Map);
    final replacements = <String, Object?>{};
    for (final phase in _scoutCliPhaseNames) {
      final earlier = preflightPhases[phase];
      final later = actionPhases[phase];
      final earlierElapsed =
          earlier is Map &&
              earlier['status'] == 'measured' &&
              earlier['elapsedMs'] is int
          ? earlier['elapsedMs'] as int
          : null;
      final laterElapsed =
          later is Map &&
              later['status'] == 'measured' &&
              later['elapsedMs'] is int
          ? later['elapsedMs'] as int
          : null;
      if (earlierElapsed == null) continue;
      final combined = earlierElapsed + (laterElapsed ?? 0);
      replacements[phase] = <String, Object?>{
        'status': 'measured',
        'elapsedMs': combined,
        'owner': phase == 'serialize'
            ? 'helper'
            : _scoutCliOwnedPhases.contains(phase)
            ? 'cli'
            : 'helper',
        'scope': 'sequential preflight and action $phase intervals',
        'clock': 'monotonic_stopwatch',
        'aggregation': 'exclusive_non_overlapping_cross_call_sum',
        'preflightElapsedMs': earlierElapsed,
        'actionElapsedMs': laterElapsed ?? 0,
      };
    }
    return _withCanonicalPhaseTimings(action, replacements);
  }

  /// Reclassifies an inspect performed after dispatch. Its helper snapshot is
  /// factual post-action observation, so it belongs to `delta`, not the
  /// pre-dispatch `snapshot` bucket when native CLI mutations aggregate calls.
  Object? _postDispatchObservationTimings(Object? rawTimings) {
    if (rawTimings is! Map || rawTimings['phases'] is! Map) return rawTimings;
    final timings = <String, Object?>{
      for (final entry in rawTimings.entries) entry.key.toString(): entry.value,
    };
    final phases = <String, Object?>{
      for (final entry in (rawTimings['phases']! as Map).entries)
        entry.key.toString(): entry.value,
    };
    final snapshot = phases['snapshot'];
    final delta = phases['delta'];
    final snapshotElapsed =
        snapshot is Map &&
            snapshot['status'] == 'measured' &&
            snapshot['elapsedMs'] is int
        ? snapshot['elapsedMs'] as int
        : null;
    final deltaElapsed =
        delta is Map &&
            delta['status'] == 'measured' &&
            delta['elapsedMs'] is int
        ? delta['elapsedMs'] as int
        : null;
    if (snapshotElapsed != null || deltaElapsed != null) {
      phases['delta'] = <String, Object?>{
        'status': 'measured',
        'elapsedMs': (snapshotElapsed ?? 0) + (deltaElapsed ?? 0),
        'owner': 'helper',
        'scope': 'post-dispatch inspect observation and factual delta input',
        'clock': 'monotonic_stopwatch',
        'aggregation': 'exclusive_non_overlapping_cross_call_sum',
      };
    }
    phases['snapshot'] = const <String, Object?>{
      'status': 'unavailable',
      'elapsedMs': null,
      'owner': 'helper',
      'reason': 'post_dispatch_observation_accounted_as_delta',
    };
    timings['phases'] = phases;
    return timings;
  }

  Map<String, dynamic> _withMeasuredCliPhase(
    Map<String, dynamic> result, {
    required String phase,
    required int elapsedMs,
    required String scope,
    Map<String, Object?> facts = const <String, Object?>{},
  }) {
    if (!_scoutCliOwnedPhases.contains(phase)) {
      throw ArgumentError.value(
        phase,
        'phase',
        'Only CLI-owned phases can be measured at this boundary.',
      );
    }
    final canonical = _withCanonicalPhaseTimings(result);
    final canonicalTimings = canonical['timings']! as Map;
    final canonicalPhases = canonicalTimings['phases']! as Map;
    final prior = canonicalPhases[phase];
    final priorSerializeMeasured =
        phase == 'serialize' &&
        prior is Map &&
        prior['status'] == 'measured' &&
        prior['elapsedMs'] is int;
    final priorMap = prior is Map ? prior : null;
    final priorOwner = priorMap?['owner']?.toString();
    final rawHelperElapsedMs = priorMap == null
        ? null
        : priorMap['helperElapsedMs'];
    final helperWasMeasured =
        priorSerializeMeasured &&
        (priorOwner == 'helper' ||
            priorOwner == 'helper_and_cli' ||
            rawHelperElapsedMs is int);
    final helperElapsedMs = priorSerializeMeasured
        ? rawHelperElapsedMs is int
              ? rawHelperElapsedMs
              : priorOwner == 'helper'
              ? priorMap!['elapsedMs'] as int
              : 0
        : 0;
    final cliElapsedMs = max(0, elapsedMs);
    final combinedElapsedMs = helperElapsedMs + cliElapsedMs;
    return _withCanonicalPhaseTimings(canonical, <String, Object?>{
      phase: <String, Object?>{
        'status': 'measured',
        'elapsedMs': combinedElapsedMs,
        'owner': helperWasMeasured ? 'helper_and_cli' : 'cli',
        'scope': helperWasMeasured
            ? 'helper VM-response encode probe plus $scope'
            : scope,
        'clock': 'monotonic_stopwatch',
        'aggregation': 'exclusive_non_overlapping',
        if (phase == 'serialize') ...<String, Object?>{
          if (helperWasMeasured) 'helperElapsedMs': helperElapsedMs,
          'cliElapsedMs': cliElapsedMs,
          if (priorMap?['preflightElapsedMs'] is int)
            'preflightElapsedMs': priorMap!['preflightElapsedMs'],
          if (priorMap?['actionElapsedMs'] is int)
            'actionElapsedMs': priorMap!['actionElapsedMs'],
        },
        ...facts,
      },
    });
  }

  /// Measures a first, bounded canonical serialization and then returns a
  /// result carrying that fact. Callers serialize the returned value once more
  /// for the actual stream, socket, or evidence write; write latency remains
  /// outside this phase by definition.
  Map<String, dynamic> _withCliSerializeProbe(
    Map<String, dynamic> result, {
    required Object? probeValue,
    required String boundary,
    bool pretty = false,
  }) {
    final stopwatch = Stopwatch()..start();
    final encoder = pretty
        ? const JsonEncoder.withIndent('  ')
        : const JsonEncoder();
    encoder.convert(_sanitizeForSerialization(probeValue));
    stopwatch.stop();
    return _withMeasuredCliPhase(
      result,
      phase: 'serialize',
      elapsedMs: stopwatch.elapsedMilliseconds,
      scope: 'first canonical $boundary encode probe',
      facts: <String, Object?>{
        'boundary': boundary,
        'finalWriteLatencyIncluded': false,
      },
    );
  }

  Map<String, dynamic> _withUnavailableCliPhase(
    Map<String, dynamic> result, {
    required String phase,
    required String reason,
  }) {
    if (!_scoutCliOwnedPhases.contains(phase)) {
      throw ArgumentError.value(
        phase,
        'phase',
        'Only CLI-owned phases can be closed at this boundary.',
      );
    }
    return _withUnavailablePhase(
      result,
      phase: phase,
      owner: 'cli',
      reason: reason,
    );
  }

  /// Guarantees a structurally valid record for every canonical phase while
  /// retaining only the bounded timing metadata Scout itself defines.
  Map<String, dynamic> _withCanonicalPhaseTimings(
    Map<String, dynamic> result, [
    Map<String, Object?> replacements = const <String, Object?>{},
  ]) {
    final rawTimings = result['timings'];
    final timings = rawTimings is Map
        ? <String, Object?>{
            for (final entry in rawTimings.entries)
              if (entry.key.toString() != 'phases')
                entry.key.toString(): entry.value,
          }
        : <String, Object?>{};
    final rawPhases = rawTimings is Map && rawTimings['phases'] is Map
        ? rawTimings['phases'] as Map
        : const <Object?, Object?>{};
    final phases = <String, Object?>{
      for (final phase in _scoutCliPhaseNames)
        phase: _normalizedPhaseRecord(phase, rawPhases[phase]),
    };
    for (final entry in replacements.entries) {
      if (!_scoutCliPhaseNames.contains(entry.key)) {
        throw ArgumentError.value(
          entry.key,
          'phase',
          'Unknown Scout timing phase.',
        );
      }
      phases[entry.key] = _normalizedPhaseRecord(entry.key, entry.value);
    }
    timings['phases'] = phases;
    final allMeasured = phases.values.every(
      (value) => value is Map && value['status'] == 'measured',
    );
    // Heartbeats describe a live command and must retain that lifecycle fact;
    // phase closure is additive and must not turn one into a completed result.
    final sourceStatus = rawTimings is Map
        ? _nonEmptyString(rawTimings['status'])
        : null;
    timings['status'] = sourceStatus == 'in_progress'
        ? 'in_progress'
        : allMeasured
        ? 'measured'
        : 'partial';
    final overhead = _phaseOverheadExcludingSettle(phases);
    timings['actionOverheadExcludingSettle'] = overhead;
    if (overhead['elapsedMs'] case final int elapsedMs) {
      timings['actionOverheadExcludingSettleMs'] = elapsedMs;
    } else {
      timings.remove('actionOverheadExcludingSettleMs');
    }
    return <String, dynamic>{...result, 'timings': timings};
  }

  Map<String, Object?> _normalizedPhaseRecord(String phase, Object? raw) {
    final owner = _scoutCliOwnedPhases.contains(phase) ? 'cli' : 'helper';
    if (raw is Map) {
      final status = raw['status']?.toString();
      final elapsed = raw['elapsedMs'];
      if (status == 'measured' && elapsed is int && elapsed >= 0) {
        return <String, Object?>{
          'status': 'measured',
          'elapsedMs': elapsed,
          'owner': raw['owner']?.toString() ?? owner,
          'scope': ?_nonEmptyString(raw['scope']),
          'clock': ?_nonEmptyString(raw['clock']),
          'aggregation': ?_nonEmptyString(raw['aggregation']),
          'connection': ?_nonEmptyString(raw['connection']),
          'outcome': ?_nonEmptyString(raw['outcome']),
          'boundary': ?_nonEmptyString(raw['boundary']),
          'replayDeliveryConnection': ?_nonEmptyString(
            raw['replayDeliveryConnection'],
          ),
          'replayDeliveryReason': ?_nonEmptyString(raw['replayDeliveryReason']),
          if (raw['reused'] is bool) 'reused': raw['reused'],
          if (raw['finalWriteLatencyIncluded'] is bool)
            'finalWriteLatencyIncluded': raw['finalWriteLatencyIncluded'],
          if (raw['sinceCursor'] is int && raw['sinceCursor'] >= 0)
            'sinceCursor': raw['sinceCursor'],
          if (raw['expectationRequested'] is bool)
            'expectationRequested': raw['expectationRequested'],
          if (raw['helperElapsedMs'] is int && raw['helperElapsedMs'] >= 0)
            'helperElapsedMs': raw['helperElapsedMs'],
          if (raw['cliElapsedMs'] is int && raw['cliElapsedMs'] >= 0)
            'cliElapsedMs': raw['cliElapsedMs'],
          if (raw['preflightElapsedMs'] is int &&
              raw['preflightElapsedMs'] >= 0)
            'preflightElapsedMs': raw['preflightElapsedMs'],
          if (raw['actionElapsedMs'] is int && raw['actionElapsedMs'] >= 0)
            'actionElapsedMs': raw['actionElapsedMs'],
        };
      }
      final reason = _nonEmptyString(raw['reason']);
      if (status == 'unavailable' && elapsed == null && reason != null) {
        return <String, Object?>{
          'status': 'unavailable',
          'elapsedMs': null,
          'owner': raw['owner']?.toString() ?? owner,
          'reason': reason,
        };
      }
    }
    return <String, Object?>{
      'status': 'unavailable',
      'elapsedMs': null,
      'owner': owner,
      'reason': raw == null
          ? '${owner}_phase_missing_from_response'
          : 'invalid_${owner}_phase_record',
    };
  }

  Map<String, Object?> _phaseOverheadExcludingSettle(
    Map<String, Object?> phases,
  ) {
    var elapsedMs = 0;
    final unavailable = <String>[];
    for (final phase in _scoutCliPhaseNames) {
      if (phase == 'settle') continue;
      final record = phases[phase];
      if (record is! Map) {
        unavailable.add(phase);
        continue;
      }
      if (record['status'] == 'measured' && record['elapsedMs'] is int) {
        elapsedMs += record['elapsedMs'] as int;
        continue;
      }
      final reason = record['reason']?.toString() ?? '';
      if (reason.startsWith('not_applicable_for_') ||
          reason.startsWith('not_applicable:')) {
        continue;
      }
      unavailable.add(phase);
    }
    if (unavailable.isNotEmpty) {
      return <String, Object?>{
        'status': 'unavailable',
        'elapsedMs': null,
        'reason': 'required_phase_measurements_unavailable',
        'unavailablePhases': unavailable,
        'excludes': 'settle',
      };
    }
    return <String, Object?>{
      'status': 'measured',
      'elapsedMs': elapsedMs,
      'method': 'sum_of_exclusive_non_settle_phases',
      'excludes': 'settle',
    };
  }
}
