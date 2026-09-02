part of 'flutter_scout_cli.dart';

// part: VM response printing, protocol diagnostics, and result compaction.

extension _CliResults on FlutterScoutCli {
  Future<int> _callAndPrint(
    String method, {
    Map<String, String> params = const {},
    Map<String, Object?>? record,
    bool compact = false,
    Duration? callTimeout,
    String? captureOutput,
    bool assertNoErrors = true,
    Map<String, dynamic> Function(Map<String, dynamic>)? outputTransform,
    bool prettyOutput = true,
    String? expectLog,
    String? rejectLog,
    Duration logExpectationTimeout = const Duration(seconds: 5),
  }) async {
    final totalStopwatch = Stopwatch()..start();
    final logCursor = _currentLogCursor();
    final vmStopwatch = Stopwatch()..start();
    late Map<String, dynamic> result;
    try {
      result = _withProtocolDiagnostics(
        method,
        await _call(method, params, callTimeout, captureOutput),
      );
    } catch (error) {
      final recognizedTransportLoss =
          error is TimeoutException ||
          error is RPCError ||
          error is SocketException ||
          error is HttpException ||
          error is WebSocketException;
      if (!recognizedTransportLoss) rethrow;
      final timedOut = error is TimeoutException;
      result = _notDispatchedProtocolFailure(
        code: timedOut ? 'runtime_transport_timeout' : 'runtime_transport_lost',
        message: timedOut
            ? 'The runtime transport timed out before Scout received an actionable semantic observation.'
            : 'The runtime transport was lost before Scout received an actionable semantic observation.',
        method: method,
        runId: _currentRunIdFromSession(),
        transport: timedOut ? 'timeout' : 'failed',
        details: <String, Object?>{'failureType': error.runtimeType.toString()},
      );
    }
    vmStopwatch.stop();
    result = _materializeActionCapture(result, captureOutput);
    final logStopwatch = Stopwatch()..start();
    var enrichedResult = await _withRecentLogSignals(
      result,
      sinceCursor: logCursor,
    );
    enrichedResult = await _applyLogExpectations(
      enrichedResult,
      sinceCursor: logCursor,
      expectLog: expectLog,
      rejectLog: rejectLog,
      timeout: logExpectationTimeout,
    );
    logStopwatch.stop();
    enrichedResult = _assertActionHasNoErrors(
      enrichedResult,
      enabled: assertNoErrors,
    );
    enrichedResult = _withMeasuredCliPhase(
      enrichedResult,
      phase: 'logs',
      elapsedMs: logStopwatch.elapsedMilliseconds,
      scope:
          'bounded log-cursor collection, log-settle window, and expectation checks',
      facts: <String, Object?>{
        'sinceCursor': logCursor,
        'expectationRequested': expectLog != null || rejectLog != null,
      },
    );
    totalStopwatch.stop();
    final helperTimings = enrichedResult['timings'];
    enrichedResult = {
      ...enrichedResult,
      'timings': <String, Object?>{
        if (helperTimings is Map)
          for (final entry in helperTimings.entries)
            if (entry.key.toString() != 'totalMs')
              entry.key.toString(): entry.value,
        if (helperTimings is Map && helperTimings['totalMs'] is num)
          'helperTotalMs': helperTimings['totalMs'],
        'vmCallMs': vmStopwatch.elapsedMilliseconds,
        'logSettleAndExpectationMs': logStopwatch.elapsedMilliseconds,
        'totalMs': totalStopwatch.elapsedMilliseconds,
      },
    };
    final actionSucceeded = enrichedResult['ok'] == true;
    enrichedResult = _commitActionEvidence(
      method: method,
      result: enrichedResult,
      record: record,
    );
    final output = outputTransform != null
        ? outputTransform(enrichedResult)
        : compact
        ? _compactActionResult(enrichedResult)
        : enrichedResult;
    _emitActionOutput(output, pretty: prettyOutput);
    if (record != null && actionSucceeded && enrichedResult['ok'] == true) {
      await _maybeStartAutoServe();
    }
    return enrichedResult['ok'] == false ? 1 : 0;
  }

  /// Commits the replay journal and action-result event before any success is
  /// emitted. A failed sink converts the response into an explicit uncertain
  /// failure; callers must reconcile state rather than blindly retrying.
  Map<String, dynamic> _commitActionEvidence({
    required String method,
    required Map<String, dynamic> result,
    Map<String, Object?>? record,
  }) {
    final originalOk = result['ok'] == true;
    var reported = _withCanonicalPhaseTimings(result);
    final reportedPhases = ((reported['timings']! as Map)['phases']! as Map);
    final reportedLogs = reportedPhases['logs'];
    if (reportedLogs is! Map || reportedLogs['status'] != 'measured') {
      reported = _withUnavailableCliPhase(
        reported,
        phase: 'logs',
        reason: 'not_applicable:log_collection_not_requested_for_command',
      );
    }
    var actionRecorded = false;
    String? failedSink;
    Object? persistenceError;
    final idempotency = result['idempotency'];
    final replayedFromReceipt =
        idempotency is Map && idempotency['status'] == 'replayed';

    if (record != null && originalOk && !replayedFromReceipt) {
      try {
        _recordAction(record);
        actionRecorded = true;
      } catch (error) {
        failedSink = 'session_action_journal';
        persistenceError = error;
        reported = _actionEvidenceFailure(
          result,
          sink: failedSink,
          error: error,
          actionRecorded: false,
          mutationIntent: true,
        );
      }
    }

    final evidence = <String, Object?>{
      'status': failedSink == null ? 'committed' : 'partial',
      // This object is written as part of the event itself: if the row is
      // observable, the event journal commit necessarily succeeded.
      'eventJournal': 'committed',
      'actionJournal': record == null
          ? 'not_applicable'
          : replayedFromReceipt
          ? 'not_repeated_idempotency_replay'
          : !originalOk
          ? 'not_recorded_unsuccessful'
          : actionRecorded
          ? 'committed'
          : 'failed',
      'failedSink': ?failedSink,
    };
    reported = <String, dynamic>{...reported, 'evidence': evidence};

    try {
      Map<String, Object?> eventPayloadFor(
        Map<String, dynamic> value,
      ) => <String, Object?>{
        'schemaVersion': 1,
        'type': 'action_result',
        ..._protocolEventEvidence(value),
        'cliCommandId': ?_activeCommandId,
        'method': method,
        'ok': value['ok'] == true,
        'originalOk': originalOk,
        'runId': ?value['runId'],
        'runtimeInstanceId': ?value['runtimeInstanceId'],
        'snapshotId': ?value['snapshotId'],
        'timings': value['timings'],
        'evidence': evidence,
        'error': ?value['error'],
        'blockingRuntimeErrors': _objectList(value['blockingErrors']).length,
        'blockingLogSignals': _objectList(value['blockingLogSignals']).length,
      };

      final probeEventPayload = _idempotencySafeEvidenceValue(
        reported,
        eventPayloadFor(reported),
      );
      reported = _withCliSerializeProbe(
        reported,
        probeValue: probeEventPayload,
        boundary: 'action_event_journal',
      );
      final safeEventPayload = _idempotencySafeEvidenceValue(
        reported,
        eventPayloadFor(reported),
      );
      final eventCursor = _appendEventStrict(<String, Object?>{
        for (final entry in (safeEventPayload! as Map).entries)
          entry.key.toString(): entry.value,
      });
      return <String, dynamic>{
        ...reported,
        'evidence': <String, Object?>{
          ...evidence,
          'eventJournal': 'committed',
          'eventCursor': eventCursor,
        },
      };
    } catch (error) {
      return _actionEvidenceFailure(
        reported,
        sink: 'action_event_journal',
        error: error,
        actionRecorded: actionRecorded,
        mutationIntent: record != null,
        priorSink: failedSink,
        priorError: persistenceError,
      );
    }
  }

  Map<String, dynamic> _actionEvidenceFailure(
    Map<String, dynamic> result, {
    required String sink,
    required Object error,
    required bool actionRecorded,
    required bool mutationIntent,
    String? priorSink,
    Object? priorError,
  }) {
    final priorErrorPayload = result['error'];
    final priorEvidence = result['evidence'];
    final priorActionJournal = priorEvidence is Map
        ? priorEvidence['actionJournal']?.toString()
        : null;
    return <String, dynamic>{
      ...result,
      'ok': false,
      'error': <String, Object?>{
        'code': 'action_evidence_persistence_failed',
        'message':
            'Scout received an action outcome but could not commit all '
            'required evidence. The action may have occurred; inspect current '
            'state before deciding whether to retry.',
        'failedSink': sink,
        'cause': error.toString(),
      },
      'priorActionError': ?priorErrorPayload,
      'mutationMayHaveOccurred': _actionMayHaveOccurred(
        result,
        mutationIntent: mutationIntent,
      ),
      'evidence': <String, Object?>{
        'status': 'unavailable',
        'eventJournal': sink == 'action_event_journal'
            ? 'failed'
            : 'not_committed',
        'actionJournal': actionRecorded
            ? 'committed'
            : priorActionJournal ??
                  (sink == 'session_action_journal'
                      ? 'failed'
                      : 'not_applicable'),
        'failedSink': sink,
        'priorFailedSink': ?priorSink,
        if (priorError case final priorError?)
          'priorCause': priorError.toString(),
      },
    };
  }

  bool _actionMayHaveOccurred(
    Map<String, dynamic> result, {
    required bool mutationIntent,
  }) {
    if (mutationIntent && result['ok'] == true) return true;
    final dispatch = result['dispatch'];
    if (dispatch is String) {
      return dispatch == 'dispatched' || dispatch == 'dispatch_outcome_unknown';
    }
    if (dispatch is Map) {
      final status = dispatch['status']?.toString();
      if (status == 'dispatched' || status == 'dispatch_outcome_unknown') {
        return true;
      }
    }
    final activation = result['activation'];
    return activation is Map && activation['dispatched'] == true;
  }

  Map<String, Object?> _protocolEventEvidence(Map<String, dynamic> result) {
    final evidence = <String, Object?>{
      for (final key in const <String>[
        'schemaVersion',
        'protocolVersion',
        'minSupportedProtocolVersion',
        'maxSupportedProtocolVersion',
        'capabilities',
        'capabilitySource',
        'commandId',
        'runId',
        'runtimeInstanceId',
        'stateGeneration',
        'stateDigest',
        'snapshotId',
        'identityStatus',
        'errorCursor',
        'logCursor',
        'errorsSinceCursor',
        'transport',
        'dispatch',
        'observation',
        'postcondition',
        'runtimeHealth',
        'runtimeHealthScope',
        'activeBlockingSignals',
        'stable',
        'stability',
        'evidence',
        'idempotency',
        'idempotencyKeyDigest',
        'idempotencyScope',
        'expectedStateGeneration',
        'deadlineEpochMs',
        'reconciledAfterTimeout',
        'beforeStateGeneration',
        'beforeSnapshotId',
        'afterStateGeneration',
        'afterSnapshotId',
        'structuredError',
      ])
        if (result.containsKey(key)) key: result[key],
    };
    final digest = _resultIdempotencyKeyDigest(result);
    final source = _resultIdempotencyKeySource(result);
    if (digest != null) evidence['idempotencyKeyDigest'] = digest;
    if (source != null) evidence['idempotencyKeySource'] = source;
    final safe = _idempotencySafeEvidenceValue(result, evidence);
    return <String, Object?>{
      for (final entry in (safe! as Map).entries)
        entry.key.toString(): entry.value,
    };
  }

  Future<Map<String, dynamic>> _applyLogExpectations(
    Map<String, dynamic> result, {
    required int sinceCursor,
    String? expectLog,
    String? rejectLog,
    required Duration timeout,
  }) async {
    if ((expectLog == null || expectLog.isEmpty) &&
        (rejectLog == null || rejectLog.isEmpty)) {
      return result;
    }
    final file = File(_logFile);
    if (!file.existsSync()) {
      return {
        ...result,
        'ok': false,
        'error': {
          'code': 'log_expectation_unavailable',
          'message': 'Scout-owned logs are unavailable for this session.',
        },
      };
    }
    final deadline = DateTime.now().add(timeout);
    String text = '';
    do {
      final chunk = _readLogChunk(file, sinceCursor: sinceCursor);
      if (chunk.truncated) {
        return {
          ...result,
          'ok': false,
          'error': {
            'code': 'log_expectation_unavailable',
            'message':
                'Fresh Scout-owned logs exceeded the bounded read window; '
                'the requested expectation cannot be proven.',
          },
          'logCursor': chunk.endCursor,
          'retainedFromLogCursor': chunk.startCursor,
        };
      }
      text = chunk.lines.join('\n');
      if (rejectLog != null &&
          rejectLog.isNotEmpty &&
          text.toLowerCase().contains(rejectLog.toLowerCase())) {
        return {
          ...result,
          'ok': false,
          'error': {
            'code': 'rejected_log_observed',
            'message': 'Fresh logs contained rejected text `$rejectLog`.',
          },
          'rejectedLog': rejectLog,
        };
      }
      if (expectLog == null ||
          expectLog.isEmpty ||
          text.toLowerCase().contains(expectLog.toLowerCase())) {
        return {
          ...result,
          if (expectLog != null && expectLog.isNotEmpty)
            'expectedLogMatched': expectLog,
        };
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } while (DateTime.now().isBefore(deadline));
    return {
      ...result,
      'ok': false,
      'error': {
        'code': 'expected_log_timeout',
        'message':
            'Fresh logs did not contain `$expectLog` within '
            '${timeout.inMilliseconds} ms.',
      },
      'expectedLog': expectLog,
    };
  }

  Map<String, dynamic> _materializeActionCapture(
    Map<String, dynamic> result,
    String? output,
  ) {
    if (output == null || output.isEmpty) return result;
    final topLevelCapture = result['capture'];
    final nestedResult = result['result'];
    final nestedCapture = nestedResult is Map ? nestedResult['capture'] : null;
    final capture = topLevelCapture is Map
        ? topLevelCapture
        : nestedCapture is Map
        ? nestedCapture
        : null;
    if (capture == null) return result;
    final encoded = capture['bytes'];
    if (encoded is! String || encoded.isEmpty) return result;

    Map<String, Object?> withoutBytes(Map source, {String? path}) =>
        <String, Object?>{
          for (final entry in source.entries)
            if (entry.key != 'bytes') entry.key.toString(): entry.value,
          'path': ?path,
        };

    Map<String, dynamic> replaceCaptures({
      required Map<String, Object?> topLevel,
      required Map<String, Object?> nested,
    }) => <String, dynamic>{
      ...result,
      if (topLevelCapture is Map) 'capture': topLevel,
      if (nestedResult is Map)
        'result': <String, Object?>{
          for (final entry in nestedResult.entries)
            entry.key.toString(): entry.value,
          if (nestedCapture is Map) 'capture': nested,
        },
    };

    try {
      final file = File(output).absolute;
      _writePrivateArtifactBytes(file.path, base64Decode(encoded));
      _writePrivateArtifactMetadata(file.path, 'session');
      final materializedTopLevel = topLevelCapture is Map
          ? withoutBytes(topLevelCapture, path: file.path)
          : <String, Object?>{};
      final materializedNested = nestedCapture is Map
          ? withoutBytes(nestedCapture, path: file.path)
          : <String, Object?>{};
      return replaceCaptures(
        topLevel: materializedTopLevel,
        nested: materializedNested,
      );
    } catch (error) {
      final failedCapture = <String, Object?>{
        ...withoutBytes(capture),
        'ok': false,
        'error': 'capture_write_failed',
      };
      return <String, dynamic>{
        ...replaceCaptures(
          topLevel: topLevelCapture is Map
              ? <String, Object?>{
                  ...withoutBytes(topLevelCapture),
                  ...failedCapture,
                }
              : const <String, Object?>{},
          nested: nestedCapture is Map
              ? <String, Object?>{
                  ...withoutBytes(nestedCapture),
                  ...failedCapture,
                }
              : const <String, Object?>{},
        ),
        'ok': false,
        'error': <String, Object?>{
          'code': 'capture_failed',
          'message':
              'The action completed, but its requested post-action capture '
              'could not be written to the selected private artifact path.',
          'cause': error.toString(),
        },
        'mutationMayHaveOccurred': _actionMayHaveOccurred(
          result,
          mutationIntent: true,
        ),
        'warnings': [
          ..._objectList(result['warnings']),
          'The post-action frame was captured, but could not be written to '
              '`$output`: $error',
        ],
      };
    }
  }

  Map<String, dynamic> _assertActionHasNoErrors(
    Map<String, dynamic> result, {
    required bool enabled,
  }) {
    if (!enabled || result['ok'] == false) return result;
    bool blocking(Object? value) =>
        value is Map && value['blocking'] == true && value['stale'] != true;
    // Protocol-v15's cursor-relative list is authoritative for action
    // attribution. Fall back only for an explicitly older read payload.
    final runtimeSource = result.containsKey('errorsSinceCursor')
        ? result['errorsSinceCursor']
        : result['recentErrors'];
    final runtime = _objectList(runtimeSource).where(blocking).toList();
    final activeRuntime = _objectList(
      result['activeBlockingSignals'],
    ).where((value) => value is Map && value['blocking'] == true).toList();
    final logs = _objectList(
      result['recentLogSignals'],
    ).where(blocking).toList();
    if (runtime.isEmpty && activeRuntime.isEmpty && logs.isEmpty) return result;
    return {
      ...result,
      'ok': false,
      'error': {
        'code': 'blocking_errors_observed',
        'message':
            'The action completed, but fresh or currently active blocking runtime errors were observed.',
      },
      'blockingErrors': runtime,
      'activeBlockingErrors': activeRuntime,
      'blockingLogSignals': logs,
    };
  }

  void _emitActionOutput(Map<String, dynamic> output, {bool pretty = true}) {
    final safe = Map<String, dynamic>.from(
      _sanitizeForSerialization(output)! as Map,
    );
    if (_suppressActionOutput) {
      _suppressedActionResults.add(safe);
      return;
    }
    _printJson(safe, pretty: pretty);
  }

  Future<Map<String, dynamic>> _withRecentLogSignals(
    Map<String, dynamic> result, {
    Duration settleDelay = const Duration(milliseconds: 150),
    int? sinceCursor,
  }) async {
    if (settleDelay > Duration.zero && File(_logFile).existsSync()) {
      await Future<void>.delayed(settleDelay);
    }
    final signals = sinceCursor == null
        ? _freshRecentLogSignals()
        : _recentLogSignals(sinceCursor: sinceCursor);
    return {
      ...result,
      'logCursor': _currentLogCursor(),
      'runId': ?_currentRunIdFromSession(),
      if (signals.isNotEmpty)
        'recentLogSignals': _logSignalMaps(
          signals,
          phase: 'action',
          actionCommandId: _activeCommandId,
        ),
    };
  }

  Future<Map<String, dynamic>> _tapTextFallbackIfNeeded(
    Map<String, dynamic> result,
    Map<String, String> params,
  ) async {
    if (!_needsTapTextFallback(result)) return result;
    // This legacy helper has already dispatched the mutation. A second tap at
    // a newly inferred parent can duplicate an irreversible operation even
    // when the first response lacked modern target evidence.
    return {
      ...result,
      'ok': false,
      'action': 'tap-text ${params['text'] ?? params['target']}',
      'dispatch': 'dispatched',
      'postcondition': 'postcondition_not_requested',
      'fallback': {
        'used': false,
        'reason': 'mutation_already_dispatched_by_incompatible_helper',
      },
      'error': {
        'code': 'incompatible_helper_after_dispatch',
        'message':
            'The attached helper dispatched tap-text but did not return the '
            'target-safety evidence required by this CLI. Scout did not retry '
            'the mutation. Hot restart or relaunch with the current helper '
            'before acting again.',
      },
      'warnings': [
        ..._objectList(result['warnings']),
        'Automatic tap-text fallback was withheld because the first mutation '
            'may already have taken effect.',
      ],
    };
  }

  bool _needsTapTextFallback(Map<String, dynamic> result) {
    if (result['ok'] != true) return false;
    if (result.containsKey('textTarget')) return false;
    final target = result['target'];
    if (target is! Map) return false;
    return target['kind'] == 'text';
  }

  Map<String, dynamic> _withProtocolDiagnostics(
    String method,
    Map<String, dynamic> result,
  ) {
    if (result['ok'] != true) return result;
    final warnings = <Object?>[..._objectList(result['warnings'])];
    final version = result['helperProtocolVersion'];
    if (version is int) {
      // Modern helper: staleness is decided by the explicit version, not by
      // guessing from missing fields (which brief/sectioned payloads omit on
      // purpose).
      if (version < FlutterScoutCli.expectedHelperProtocolVersion) {
        result['protocolMismatch'] =
            '$version<${FlutterScoutCli.expectedHelperProtocolVersion}';
        if (_claimSessionNotice(
          'protocol-$version-${FlutterScoutCli.expectedHelperProtocolVersion}',
        )) {
          warnings.add(
            'Running flutter_scout_helper protocol v$version is older than this '
            'CLI expects (v${FlutterScoutCli.expectedHelperProtocolVersion}). '
            'Hot reload cannot refresh a git/pub-cache dependency: bump the '
            'dependency (or edit the resolved pub-cache checkout) and fully '
            'relaunch the app.',
          );
          result['helperProtocol'] = {
            'status': 'older_than_cli',
            'helperProtocolVersion': version,
            'cliExpects': FlutterScoutCli.expectedHelperProtocolVersion,
            'nextBestActions': [
              'flutter-scout stop --clear-session',
              'flutter-scout launch --device <device> --project <path>',
            ],
          };
        }
      }
      if (warnings.isNotEmpty) {
        result['warnings'] = warnings;
      }
      return result;
    }
    final missing = <String>[];
    if (method == 'ext.flutter_scout.inspect' &&
        !result.containsKey('textTargets')) {
      result['textTargets'] = const <Object?>[];
      missing.add('textTargets');
    }
    if (method == 'ext.flutter_scout.tapText' &&
        !result.containsKey('textTarget')) {
      final target = result['target'];
      if (target is Map && target['kind'] == 'text') {
        missing.add('tapTextActionableTarget');
      }
    }
    if (missing.isNotEmpty) {
      result['protocolMismatch'] = 'legacy';
      if (_claimSessionNotice('protocol-legacy')) {
        warnings.add(
          'Attached app appears to be running an older flutter_scout_helper protocol; hot restart or relaunch the app so helper output includes ${missing.join(', ')}.',
        );
        result['helperProtocol'] = {
          'status': 'stale_or_old_helper',
          'missing': missing,
          'nextBestActions': [
            'Run flutter-scout reload',
            'If reload does not update helper behavior, hot restart from the owning Flutter terminal or relaunch the app',
          ],
        };
      }
    }
    if (warnings.isNotEmpty) {
      result['warnings'] = warnings;
    }
    return result;
  }

  Map<String, dynamic> _compactActionResult(Map<String, dynamic> result) {
    if (result['ok'] == false) {
      final before = result['before'];
      final after = result['after'];
      final sameSnapshot =
          before is Map<String, dynamic> &&
          after is Map<String, dynamic> &&
          !_inspectChanged(before, after);
      return {
        ..._compactProtocolSafetyEvidence(result),
        'ok': false,
        if (result['error'] != null) 'error': result['error'],
        if (result['priorActionError'] != null)
          'priorActionError': result['priorActionError'],
        if (result['mutationMayHaveOccurred'] != null)
          'mutationMayHaveOccurred': result['mutationMayHaveOccurred'],
        if (result['evidence'] != null) 'evidence': result['evidence'],
        if (result['action'] != null) 'action': result['action'],
        if (result['stable'] != null) 'stable': result['stable'],
        if (result['stability'] is Map) 'stability': result['stability'],
        if (result['result'] != null) 'result': result['result'],
        if (result['lateChangeObserved'] != null)
          'lateChangeObserved': result['lateChangeObserved'],
        if (result['waitTimedOut'] != null)
          'waitTimedOut': result['waitTimedOut'],
        if (result['activityObserved'] == true) 'activityObserved': true,
        if (result['transientViewSignatures'] is List &&
            (result['transientViewSignatures'] as List).isNotEmpty)
          'transientViewSignatures': result['transientViewSignatures'],
        if (result['method'] != null) 'method': result['method'],
        if (result['state'] != null) 'state': result['state'],
        if (result['appReachable'] != null)
          'appReachable': result['appReachable'],
        if (result['elapsedMs'] != null) 'elapsedMs': result['elapsedMs'],
        if (result['timing'] != null) 'timing': result['timing'],
        if (result['timings'] != null) 'timings': result['timings'],
        if (result['sourceVerification'] != null)
          'sourceVerification': result['sourceVerification'],
        if (result['acknowledgement'] != null)
          'acknowledgement': result['acknowledgement'],
        if (result['waitedMs'] != null) 'waitedMs': result['waitedMs'],
        if (result['active'] != null) 'active': result['active'],
        if (result['position'] != null) 'position': result['position'],
        if (result['pathLength'] != null) 'pathLength': result['pathLength'],
        if (result['message'] != null) 'message': result['message'],
        if (result['reason'] != null) 'reason': result['reason'],
        if (result['target'] is Map<String, dynamic>)
          'target': _compactNode(result['target'] as Map<String, dynamic>),
        if (result['textTarget'] is Map<String, dynamic>)
          'textTarget': _compactNode(
            result['textTarget'] as Map<String, dynamic>,
          ),
        if (result['activation'] != null) 'activation': result['activation'],
        if (result['expectation'] != null) 'expectation': result['expectation'],
        if (result['expectedLogMatched'] != null)
          'expectedLogMatched': result['expectedLogMatched'],
        if (result['capture'] != null) 'capture': result['capture'],
        if (result['warnings'] != null) 'warnings': result['warnings'],
        if (result['didYouMean'] != null) 'didYouMean': result['didYouMean'],
        if (result['reachHint'] != null) 'reachHint': result['reachHint'],
        if (result['suggestedActions'] != null)
          'suggestedActions': result['suggestedActions'],
        if (result['fallback'] != null) 'fallback': result['fallback'],
        if (result['helperProtocol'] != null)
          'helperProtocol': result['helperProtocol'],
        if (result['protocolMismatch'] != null)
          'protocolMismatch': result['protocolMismatch'],
        if (!sameSnapshot && before is Map<String, dynamic>)
          'beforeSummary': _compactSummary(before),
        if (!sameSnapshot && after is Map<String, dynamic>)
          'afterSummary': _compactSummary(after),
        if (sameSnapshot) 'sameSnapshot': true,
        if (result['delta'] is Map)
          'delta': _compactDelta(result['delta'] as Map),
        if (_isNonEmptyList(result['recentErrors']))
          'recentErrors': _lastItems(result['recentErrors'] as List, 3),
        if (_isNonEmptyList(result['recentLogSignals']))
          'recentLogSignals': _lastItems(result['recentLogSignals'] as List, 3),
        if (result['logCursor'] != null) 'logCursor': result['logCursor'],
        if (result['runId'] != null) 'runId': result['runId'],
      };
    }
    final after = result['after'];
    final compactDelta = result['delta'] is Map
        ? _compactDelta(result['delta'] as Map)
        : const <String, Object?>{};
    final workflowHints = _workflowHints();
    return {
      ..._compactProtocolSafetyEvidence(result),
      'ok': result['ok'],
      if (result['evidence'] != null) 'evidence': result['evidence'],
      if (result['action'] != null) 'action': result['action'],
      if (result['stable'] != null) 'stable': result['stable'],
      if (result['stability'] is Map) 'stability': result['stability'],
      if (result['result'] != null) 'result': result['result'],
      if (result['lateChangeObserved'] != null)
        'lateChangeObserved': result['lateChangeObserved'],
      if (result['waitTimedOut'] != null)
        'waitTimedOut': result['waitTimedOut'],
      if (result['activityObserved'] == true) 'activityObserved': true,
      if (result['transientViewSignatures'] is List &&
          (result['transientViewSignatures'] as List).isNotEmpty)
        'transientViewSignatures': result['transientViewSignatures'],
      if (result['method'] != null) 'method': result['method'],
      if (result['state'] != null) 'state': result['state'],
      if (result['appReachable'] != null)
        'appReachable': result['appReachable'],
      if (result['elapsedMs'] != null) 'elapsedMs': result['elapsedMs'],
      if (result['timing'] != null) 'timing': result['timing'],
      if (result['timings'] != null) 'timings': result['timings'],
      if (result['sourceVerification'] != null)
        'sourceVerification': result['sourceVerification'],
      if (result['operabilityPersistence'] != null)
        'operabilityPersistence': result['operabilityPersistence'],
      if (result['acknowledgement'] != null)
        'acknowledgement': result['acknowledgement'],
      if (result['waitedMs'] != null) 'waitedMs': result['waitedMs'],
      if (result['active'] != null) 'active': result['active'],
      if (result['position'] != null) 'position': result['position'],
      if (result['pathLength'] != null) 'pathLength': result['pathLength'],
      if (result['gestureStart'] != null)
        'gestureStart': result['gestureStart'],
      if (result['gestureEnd'] != null) 'gestureEnd': result['gestureEnd'],
      if (result['screenshot'] != null) 'screenshot': result['screenshot'],
      if (result['capture'] != null) 'capture': result['capture'],
      if (result['expectedLogMatched'] != null)
        'expectedLogMatched': result['expectedLogMatched'],
      if (result['message'] != null) 'message': result['message'],
      if (result['fullRebuildRequired'] != null)
        'fullRebuildRequired': result['fullRebuildRequired'],
      if (result['reloadReport'] != null)
        'reloadReport': result['reloadReport'],
      if (result['nextBestActions'] != null)
        'nextBestActions': result['nextBestActions'],
      if (result['filled'] != null) 'filled': result['filled'],
      if (result['failed'] != null) 'failed': result['failed'],
      if (result['popped'] != null) 'popped': result['popped'],
      if (result['scrollsUsed'] != null) 'scrollsUsed': result['scrollsUsed'],
      if (result['reason'] != null) 'reason': result['reason'],
      if (result['target'] is Map<String, dynamic>)
        'target': _compactNode(result['target'] as Map<String, dynamic>),
      if (result['textTarget'] is Map<String, dynamic>)
        'textTarget': _compactNode(
          result['textTarget'] as Map<String, dynamic>,
        ),
      if (result['activation'] != null) 'activation': result['activation'],
      if (result['fieldResults'] is List)
        'fieldResults': [
          for (final field in result['fieldResults'] as List)
            if (field is Map)
              {
                if (field['target'] != null) 'target': field['target'],
                if (field['ok'] != null) 'ok': field['ok'],
                if (field['stable'] != null) 'stable': field['stable'],
                if (field['stability'] is Map) 'stability': field['stability'],
                if (field['changed'] != null) 'changed': field['changed'],
                if (field['delta'] is Map)
                  'delta': _compactDelta(field['delta'] as Map),
              },
        ],
      if (result['warnings'] != null) 'warnings': result['warnings'],
      if (workflowHints.isNotEmpty) 'workflowHints': workflowHints,
      if (result['fallback'] != null) 'fallback': result['fallback'],
      if (result['helperProtocol'] != null)
        'helperProtocol': result['helperProtocol'],
      if (result['protocolMismatch'] != null)
        'protocolMismatch': result['protocolMismatch'],
      if (after is Map<String, dynamic> && after['screen'] != null)
        'screen': after['screen'],
      if (after is Map<String, dynamic> && after['screenEvidence'] is Map)
        'screenEvidence': after['screenEvidence'],
      if (after is Map<String, dynamic> && after['snapshotId'] != null)
        'snapshotId': after['snapshotId'],
      if (after is Map<String, dynamic> && after['activeSurface'] is Map)
        'activeSurface': _compactActiveSurface(after['activeSurface'] as Map),
      if (compactDelta.isNotEmpty) 'delta': compactDelta,
      if (compactDelta.isEmpty && after is Map<String, dynamic>)
        'sameSnapshot': true,
      if (_isNonEmptyList(result['recentErrors']))
        'recentErrors': _lastItems(result['recentErrors'] as List, 3),
      if (_isNonEmptyList(result['recentLogSignals']))
        'recentLogSignals': _lastItems(result['recentLogSignals'] as List, 3),
      if (result['logCursor'] != null) 'logCursor': result['logCursor'],
      if (result['runId'] != null) 'runId': result['runId'],
    };
  }

  /// Protocol evidence is safety-critical and must survive compact output.
  /// Agents need these fields to distinguish an observed success from an
  /// unknown dispatch outcome without requesting the verbose payload.
  Map<String, Object?> _compactProtocolSafetyEvidence(
    Map<String, dynamic> result,
  ) {
    final compact = <String, Object?>{
      for (final key in const <String>[
        'schemaVersion',
        'protocolVersion',
        'minSupportedProtocolVersion',
        'maxSupportedProtocolVersion',
        'capabilities',
        'capabilitySource',
        'commandId',
        'runId',
        'runtimeInstanceId',
        'stateGeneration',
        'stateDigest',
        'snapshotId',
        'identityStatus',
        'errorCursor',
        'errorsSinceCursor',
        'structuredError',
        'transport',
        'dispatch',
        'observation',
        'postcondition',
        'runtimeHealth',
        'runtimeHealthScope',
        'activeBlockingSignals',
        'idempotency',
        'idempotencyKeyDigest',
        'idempotencyScope',
        'idempotencyScopeKey',
        'expectedStateGeneration',
        'deadlineEpochMs',
        'reconciledAfterTimeout',
        'beforeStateGeneration',
        'beforeSnapshotId',
        'afterStateGeneration',
        'afterSnapshotId',
      ])
        if (result.containsKey(key)) key: result[key],
    };
    final digest = _resultIdempotencyKeyDigest(result);
    final source = _resultIdempotencyKeySource(result);
    if (digest != null) compact['idempotencyKeyDigest'] = digest;
    if (source != null) compact['idempotencyKeySource'] = source;
    // A generated key is new retry authority supplied by Scout, so returning
    // it to the direct caller is safe and necessary. A caller-supplied key is
    // never copied into compact evidence or any persisted artifact.
    if (source == 'generated' && result['idempotencyKey'] is String) {
      compact['idempotencyKey'] = result['idempotencyKey'];
    }
    return compact;
  }

  Map<String, dynamic> _compactBriefInspect(Map<String, dynamic> result) {
    final payload = _observationPayload(result);
    final visible = payload['visibleText'];
    final hitTestable = payload['hitTestableText'];
    List<Object?>? nonHitTestable;
    if (visible is List && hitTestable is List) {
      final hitSet = hitTestable.map((value) => value.toString()).toSet();
      final difference = <Object?>[
        for (final value in visible)
          if (!hitSet.contains(value.toString())) value,
      ];
      if (difference.length <= 4) {
        nonHitTestable = difference;
      }
    }
    final compact = <String, dynamic>{
      ..._compactProtocolSafetyEvidence(result),
      'ok': result['ok'],
      if (result['error'] != null) 'error': result['error'],
      if (result['evidence'] != null) 'evidence': result['evidence'],
      if (payload['screen'] != null) 'screen': payload['screen'],
      if (payload['screenEvidence'] is Map)
        'screenEvidence': payload['screenEvidence'],
      if (payload['routeGuess'] != null) 'routeGuess': payload['routeGuess'],
      if (payload['activeSurface'] is Map)
        'activeSurface': _compactActiveSurface(payload['activeSurface'] as Map),
      if (payload['surfaceOnly'] != null) 'surfaceOnly': payload['surfaceOnly'],
      if (payload['viewSignature'] != null)
        'viewSignature': _compactObservationString(
          payload['viewSignature'].toString(),
        ),
      if (payload['visibleTextHash'] != null)
        'visibleTextHash': payload['visibleTextHash'],
      if (payload['idle'] != null) 'idle': payload['idle'],
      if (payload['viewport'] is Map)
        'viewport': _compactObservationViewport(payload['viewport'] as Map),
      if (payload['perception'] is Map)
        'perception': _compactObservationPerception(
          payload['perception'] as Map,
        ),
      if (payload['keyboard'] is Map) 'keyboard': payload['keyboard'],
      if (payload['degradedNodes'] != null)
        'degradedNodes': payload['degradedNodes'],
      if (_isNonEmptyList(payload['recentErrors']))
        'recentErrors': _compactObservationSignals(
          payload['recentErrors'] as List,
        ),
      if (payload['errorSummary'] != null)
        'errorSummary': payload['errorSummary'],
      if (payload['annotationMode'] == true) 'annotationMode': true,
      if (_isNonEmptyList(visible)) 'visibleText': visible,
      if (hitTestable is List &&
          hitTestable.isNotEmpty &&
          nonHitTestable == null)
        'hitTestableText': hitTestable,
      if (nonHitTestable != null && nonHitTestable.isNotEmpty)
        'nonHitTestableText': nonHitTestable,
      if (_isNonEmptyList(payload['offscreenText']))
        'offscreenText': payload['offscreenText'],
      if (_isNonEmptyList(payload['interactables']))
        'interactables': payload['interactables'],
      if (payload['interactablesOmitted'] != null)
        'interactablesOmitted': payload['interactablesOmitted'],
      if (_isNonEmptyList(payload['inspectWarnings']))
        'inspectWarnings': payload['inspectWarnings'],
      if (_isNonEmptyList(payload['structuredRows']))
        'structuredRows': (payload['structuredRows'] as List).take(4).toList(),
      if (_isNonEmptyList(payload['scrollables']))
        'scrollables': <Object?>[
          for (final item in (payload['scrollables'] as List).take(3))
            if (item is Map) _compactBriefObservationScrollRegion(item),
        ],
      if (payload['omittedSections'] != null)
        'omittedSections': payload['omittedSections'],
      if (payload['omitted'] != null) 'omitted': payload['omitted'],
      if (payload['fieldValues'] is Map &&
          (payload['fieldValues'] as Map).isNotEmpty)
        'fieldValues': payload['fieldValues'],
      if (payload['observationEffects'] != null)
        'observationEffects': payload['observationEffects'],
      if (result['timings'] != null) 'timings': result['timings'],
      if (result['warnings'] != null) 'warnings': result['warnings'],
      if (result['helperProtocol'] != null)
        'helperProtocol': result['helperProtocol'],
      if (result['protocolMismatch'] != null)
        'protocolMismatch': result['protocolMismatch'],
      if (_isNonEmptyList(result['recentLogSignals']))
        'recentLogSignals': _lastItems(result['recentLogSignals'] as List, 3),
      if (result['logCursor'] != null) 'logCursor': result['logCursor'],
    };
    return _nestCompactObservation(compact);
  }

  Map<String, dynamic> _compactWhere(Map<String, dynamic> result) {
    final payload = _observationPayload(result);
    final regions = payload['scrollRegions'] is List
        ? payload['scrollRegions'] as List
        : const <Object?>[];
    const maxRegions = 20;
    final compact = <String, dynamic>{
      ..._compactProtocolSafetyEvidence(result),
      'ok': result['ok'],
      if (result['error'] != null) 'error': result['error'],
      if (result['evidence'] != null) 'evidence': result['evidence'],
      'orientation': payload['orientation'] ?? 'where',
      if (payload['route'] != null) 'route': payload['route'],
      if (payload['screen'] != null) 'screen': payload['screen'],
      if (payload['screenEvidence'] is Map)
        'screenEvidence': payload['screenEvidence'],
      if (payload['activeSurface'] is Map)
        'activeSurface': _compactActiveSurface(payload['activeSurface'] as Map),
      if (_isNonEmptyList(payload['activeTabCandidates']))
        'activeTabCandidates': payload['activeTabCandidates'],
      if (_isNonEmptyList(payload['tabSystems']))
        'tabSystems': payload['tabSystems'],
      if (_isNonEmptyList(payload['navigators']))
        'navigators': <Object?>[
          for (final item in (payload['navigators'] as List).take(8))
            if (item is Map)
              <String, Object?>{
                for (final key in const <String>[
                  'depth',
                  'active',
                  'canPop',
                  'key',
                  'rect',
                ])
                  if (item.containsKey(key)) key: item[key],
              },
        ],
      if (_isNonEmptyList(payload['overlays']))
        'overlays': <Object?>[
          for (final item in (payload['overlays'] as List).take(8))
            if (item is Map)
              <String, Object?>{
                for (final key in const <String>[
                  'kind',
                  'widgetType',
                  'label',
                  'rect',
                ])
                  if (item.containsKey(key)) key: item[key],
              },
        ],
      if (payload['keyboard'] is Map) 'keyboard': payload['keyboard'],
      'scrollRegions': <Object?>[
        for (final item in regions.take(maxRegions))
          if (item is Map) _compactObservationScrollRegion(item),
      ],
      if (regions.length > maxRegions)
        'scrollRegionsOmitted': <String, Object?>{
          'count': regions.length - maxRegions,
          'recoverWith': 'where --verbose',
        },
      if (_isNonEmptyList(payload['panes'])) 'panes': payload['panes'],
      if (payload['coordinateFrame'] is Map)
        'coordinateFrame': _compactObservationCoordinateFrame(
          payload['coordinateFrame'] as Map,
        ),
      if (payload['scope'] is Map) 'scope': payload['scope'],
      if (_isNonEmptyList(payload['limitations']))
        'limitations': payload['limitations'],
      if (payload['observationEffects'] != null)
        'observationEffects': payload['observationEffects'],
      if (payload['payloadBounds'] != null)
        'helperPayloadBounds': payload['payloadBounds'],
      if (result['timings'] != null) 'timings': result['timings'],
      if (result['warnings'] != null) 'warnings': result['warnings'],
      if (result['helperProtocol'] != null)
        'helperProtocol': result['helperProtocol'],
      if (result['protocolMismatch'] != null)
        'protocolMismatch': result['protocolMismatch'],
      if (_isNonEmptyList(result['recentErrors']))
        'recentErrors': _compactObservationSignals(
          result['recentErrors'] as List,
        ),
      if (_isNonEmptyList(result['recentLogSignals']))
        'recentLogSignals': _lastItems(result['recentLogSignals'] as List, 3),
      if (result['logCursor'] != null) 'logCursor': result['logCursor'],
    };
    return _nestCompactObservation(compact);
  }

  Map<String, dynamic> _nestCompactObservation(Map<String, dynamic> compact) {
    const envelopeKeys = <String>{
      'ok',
      'schemaVersion',
      'protocolVersion',
      'minSupportedProtocolVersion',
      'maxSupportedProtocolVersion',
      'capabilities',
      'capabilitySource',
      'commandId',
      'runId',
      'runtimeInstanceId',
      'stateGeneration',
      'stateDigest',
      'snapshotId',
      'identityStatus',
      'errorCursor',
      'errorsSinceCursor',
      'structuredError',
      'transport',
      'dispatch',
      'observation',
      'postcondition',
      'runtimeHealth',
      'runtimeHealthScope',
      'activeBlockingSignals',
      'idempotency',
      'idempotencyKeyDigest',
      'idempotencyKeySource',
      'idempotencyKey',
      'idempotencyScope',
      'idempotencyScopeKey',
      'expectedStateGeneration',
      'deadlineEpochMs',
      'reconciledAfterTimeout',
      'beforeStateGeneration',
      'beforeSnapshotId',
      'afterStateGeneration',
      'afterSnapshotId',
      'error',
      'evidence',
      'timings',
      'warnings',
      'helperProtocol',
      'protocolMismatch',
      'logCursor',
    };
    return <String, dynamic>{
      for (final entry in compact.entries)
        if (envelopeKeys.contains(entry.key)) entry.key: entry.value,
      'result': <String, Object?>{
        for (final entry in compact.entries)
          if (!envelopeKeys.contains(entry.key)) entry.key: entry.value,
      },
    };
  }

  Map<String, dynamic> _observationPayload(Map<String, dynamic> result) {
    final nested = result['result'];
    if (nested is! Map) return result;
    return <String, dynamic>{
      for (final entry in nested.entries) entry.key.toString(): entry.value,
      for (final entry in result.entries)
        if (entry.key != 'result') entry.key: entry.value,
    };
  }

  Map<String, Object?> _compactObservationViewport(Map viewport) =>
      <String, Object?>{
        for (final key in const <String>[
          'available',
          'orientation',
          'logicalSize',
          'devicePixelRatio',
        ])
          if (viewport.containsKey(key)) key: viewport[key],
      };

  Map<String, Object?> _compactObservationCoordinateFrame(Map frame) =>
      <String, Object?>{
        for (final key in const <String>[
          'primarySpace',
          'origin',
          'xDirection',
          'yDirection',
          'logicalViewport',
          'devicePixelRatio',
        ])
          if (frame.containsKey(key)) key: frame[key],
      };

  Map<String, Object?> _compactObservationPerception(Map perception) {
    final limitations = perception['limitations'];
    final kinds = <String>{
      if (limitations is List)
        for (final item in limitations)
          if (item is Map && item['kind']?.toString().isNotEmpty == true)
            item['kind'].toString(),
      if (perception['limitationKinds'] is List)
        for (final item in perception['limitationKinds'] as List)
          if (item.toString().isNotEmpty) item.toString(),
    }.toList()..sort();
    final capture = perception['captureBackend'];
    return <String, Object?>{
      for (final key in const <String>[
        'observationKind',
        'pixelEvidence',
        'visualStatus',
        'degradedElementCount',
        'recoverWith',
      ])
        if (perception.containsKey(key)) key: perception[key],
      if (capture is Map)
        'captureBackend': <String, Object?>{
          for (final key in const <String>['status', 'backend', 'reason'])
            if (capture.containsKey(key)) key: capture[key],
        },
      'limitationCount':
          perception['limitationCount'] ??
          (limitations is List ? limitations.length : 0),
      if (kinds.isNotEmpty) 'limitationKinds': kinds.take(8).toList(),
      if (kinds.length > 8) 'limitationKindsOmitted': kinds.length - 8,
      if (limitations is List && limitations.isNotEmpty)
        'recoverWith': 'inspect --sections perception',
    };
  }

  Map<String, Object?> _compactObservationScrollRegion(Map region) =>
      <String, Object?>{
        for (final key in const <String>[
          'id',
          'scopedId',
          'parentId',
          'nestingDepth',
          'axis',
          'axisDirection',
          'logicalBounds',
          'positionAvailable',
          'metricsAvailable',
          'pixels',
          'minScrollExtent',
          'maxScrollExtent',
          'approximateNormalizedPosition',
          'atStart',
          'atEnd',
          'canScroll',
        ])
          if (region.containsKey(key)) key: region[key],
      };

  Map<String, Object?> _compactBriefObservationScrollRegion(Map region) =>
      <String, Object?>{
        for (final key in const <String>[
          'id',
          'scopedId',
          'parentId',
          'nestingDepth',
          'axis',
          'axisDirection',
          'positionAvailable',
          'metricsAvailable',
          'atStart',
          'atEnd',
          'canScroll',
        ])
          if (region.containsKey(key)) key: region[key],
      };

  List<Object?> _compactObservationSignals(List signals) {
    final blocking = <Object?>[];
    final other = <Object?>[];
    for (final signal in signals) {
      final target = signal is Map && signal['blocking'] == true
          ? blocking
          : other;
      target.add(signal is Map ? _compactObservationSignal(signal) : signal);
    }
    return <Object?>[...blocking, ...other.reversed.take(4).toList().reversed];
  }

  Map<String, Object?> _compactObservationSignal(Map signal) =>
      <String, Object?>{
        for (final key in const <String>[
          'cursor',
          'type',
          'severity',
          'blocking',
          'freshness',
          'source',
          'code',
        ])
          if (signal.containsKey(key)) key: signal[key],
        if (signal['message'] != null)
          'message': _compactObservationString(signal['message'].toString()),
      };

  String _compactObservationString(String value) {
    const limit = 280;
    return value.length <= limit ? value : '${value.substring(0, limit)}…';
  }

  List<Map<String, Object?>> _workflowHints() {
    if (_reuseVmConnection) return const [];
    final actionCount = _readSessionActions().length;
    if (actionCount < 3) return const [];
    if (!_claimWorkflowHint('automatic_persistent_transport')) return const [];
    return [
      {
        'code': 'automatic_persistent_transport',
        'actionCount': actionCount,
        'message':
            'Scout is automatically starting an expiring persistent transport for faster follow-up commands.',
      },
    ];
  }

  bool _claimWorkflowHint(String code) {
    final meta = _readSessionMeta() ?? <String, dynamic>{};
    final emitted = (meta['emittedWorkflowHints'] is List)
        ? List<String>.from(meta['emittedWorkflowHints'] as List)
        : <String>[];
    if (emitted.contains(code)) return false;
    emitted.add(code);
    _writeSessionMeta({...meta, 'emittedWorkflowHints': emitted});
    return true;
  }

  bool _claimSessionNotice(String code) {
    final meta = _readSessionMeta() ?? <String, dynamic>{};
    final emitted = (meta['emittedNotices'] is List)
        ? List<String>.from(meta['emittedNotices'] as List)
        : <String>[];
    if (emitted.contains(code)) return false;
    emitted.add(code);
    _writeSessionMeta({...meta, 'emittedNotices': emitted});
    return true;
  }

  bool _isNonEmptyList(Object? value) => value is List && value.isNotEmpty;

  Map<String, Object?> _compactNode(Map<String, dynamic> node) {
    return {
      'id': node['id'],
      if (node['label'] != null) 'label': node['label'],
      if (node['kind'] != null) 'kind': node['kind'],
      if (node['enabled'] != null) 'enabled': node['enabled'],
    };
  }

  Map<String, Object?> _compactSummary(Map<String, dynamic> summary) {
    return {
      if (summary['screen'] != null) 'screen': summary['screen'],
      if (summary['screenEvidence'] is Map)
        'screenEvidence': summary['screenEvidence'],
      if (summary['activeSurface'] is Map)
        'activeSurface': _compactActiveSurface(summary['activeSurface'] as Map),
      if (summary['routeGuess'] != null) 'routeGuess': summary['routeGuess'],
      if (summary['viewSignature'] != null)
        'viewSignature': summary['viewSignature'],
      if (summary['snapshotId'] != null) 'snapshotId': summary['snapshotId'],
      if (summary['visibleTextHash'] != null)
        'visibleTextHash': summary['visibleTextHash'],
      if (summary['idle'] != null) 'idle': summary['idle'],
      if (summary['perception'] is Map)
        'perception': _compactPerception(summary['perception'] as Map),
      if (summary['fieldValues'] != null) 'fieldValues': summary['fieldValues'],
      if (summary['degradedNodes'] != null)
        'degradedNodes': summary['degradedNodes'],
    };
  }

  Map<String, Object?> _compactPerception(Map perception) {
    final text = perception['text'];
    final semantics = perception['semantics'];
    return {
      if (text is Map && text['source'] != null) 'textSource': text['source'],
      if (semantics is Map && semantics['usedForLabels'] != null)
        'semanticsUsed': semantics['usedForLabels'],
    };
  }

  Map<String, Object?> _compactActiveSurface(Map surface) => {
    if (surface['kind'] != null) 'kind': surface['kind'],
    if (surface['label'] != null) 'label': surface['label'],
    if (surface['screen'] != null) 'screen': surface['screen'],
    if (surface['source'] != null) 'source': surface['source'],
    if (surface['heuristicScore'] != null)
      'heuristicScore': surface['heuristicScore'],
    if (surface['scoreKind'] != null) 'scoreKind': surface['scoreKind'],
  };

  Map<String, Object?> _compactDelta(Map delta) {
    const listKeys = {
      'newText',
      'removedText',
      'changedText',
      'newFields',
      'removedFields',
      'changedFields',
      'newValidationMessages',
      'validationCandidates',
      'changedGeometry',
      'newInteractables',
      'removedInteractables',
    };
    final compact = <String, Object?>{};
    for (final entry in delta.entries) {
      final key = entry.key.toString();
      final value = entry.value;
      if (listKeys.contains(key)) {
        if (value is List && value.isNotEmpty) {
          compact[key] = _firstItems(value, 12);
        }
        continue;
      }
      if (value == true || (value != null && value != false)) {
        compact[key] = value;
      }
    }
    return compact;
  }

  List<Object?> _lastItems(List<dynamic> items, int count) {
    if (items.length <= count) return List<Object?>.from(items);
    return items.sublist(items.length - count);
  }

  List<Object?> _firstItems(List<dynamic> items, int count) {
    if (items.length <= count) return List<Object?>.from(items);
    return items.take(count).toList(growable: false);
  }

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, String> params = const {},
    Duration? callTimeout,
    String? captureOutput,
  ]) async {
    final connectionTiming = _CliConnectPhaseTiming();
    final result = await _callWithConnectionTiming(
      method,
      params,
      callTimeout,
      connectionTiming,
      captureOutput,
    );
    return _withConnectionPhaseTiming(result, connectionTiming);
  }

  Future<Map<String, dynamic>> _callWithConnectionTiming(
    String method,
    Map<String, String> params,
    Duration? callTimeout,
    _CliConnectPhaseTiming connectionTiming,
    String? captureOutput,
  ) async {
    final mutating = _isMutatingExtension(method, params);
    final preTransport = mutating
        ? _inspectReceiptBeforeTransport(method: method, businessParams: params)
        : null;
    final immediateReceiptOutcome = preTransport?.immediate;
    if (immediateReceiptOutcome != null) {
      connectionTiming.unavailable(
        'durable_receipt_replay_skipped_vm_connection',
      );
      return immediateReceiptOutcome;
    }
    final uncertainReceiptInvocation = preTransport?.uncertainInvocation;
    final uri = _readVmUri();
    if (uri == null || uri.isEmpty) {
      connectionTiming.unavailable('vm_service_uri_unavailable');
      if (uncertainReceiptInvocation != null) {
        return _idempotencyReconciliationUnavailable(
          uncertainReceiptInvocation,
          connectionStage: 'session_uri_lookup',
        );
      }
      return _notDispatchedProtocolFailure(
        code: 'not_attached',
        message:
            'Save the local VM-service URL in an owner-only 0600 file, then '
            'run flutter-scout attach --debug-url-file <path>.',
        method: method,
        runId: _currentRunIdFromSession(),
        transport: 'failed',
        details: <String, Object?>{
          'connectionStage': 'session_uri_lookup',
          'mutationIntent': mutating,
        },
      );
    }
    // In batch mode one WebSocket serves every step; per-call connect/dispose
    // is pure overhead (and a timing gap the UI can drift through).
    final reuse = _reuseVmConnection;
    late final VmService service;
    if (reuse && _cachedVmService != null && _cachedVmUri == uri) {
      connectionTiming.begin(reused: true, connection: 'cached_vm_service');
      service = _cachedVmService!;
      connectionTiming.complete(outcome: 'reused');
    } else {
      connectionTiming.begin(reused: false, connection: 'new_vm_service');
      try {
        service = await _connect(uri);
        connectionTiming.complete(outcome: 'connected');
      } catch (error) {
        connectionTiming.complete(outcome: 'failed');
        if (reuse) await _disposeCachedVmService();
        if (uncertainReceiptInvocation != null) {
          return _idempotencyReconciliationUnavailable(
            uncertainReceiptInvocation,
            connectionStage: 'initial_connect',
            cause: error,
          );
        }
        return _notDispatchedProtocolFailure(
          code: 'vm_service_connection_failed',
          message:
              'Flutter Scout could not establish the bounded VM-service connection. Nothing was dispatched.',
          method: method,
          runId: _currentRunIdFromSession(),
          transport: 'failed',
          details: <String, Object?>{
            'connectionStage': 'initial_connect',
            'mutationIntent': mutating,
            'failureType': error.runtimeType.toString(),
          },
        );
      }
      if (reuse) {
        await _disposeCachedVmService();
        _cachedVmService = service;
        _cachedVmUri = uri;
      }
    }
    final timeout = callTimeout ?? const Duration(seconds: 20);
    _MutationInvocation? mutation;
    try {
      final isolateId = await _findMainIsolate(service);
      Map<String, String> effectiveParams;
      if (mutating) {
        final prepared = await _prepareMutationInvocation(
          service: service,
          isolateId: isolateId,
          method: method,
          params: params,
          actionTimeout: timeout,
          connectionPhase: connectionTiming.phaseRecord,
        );
        final preflightFailure = prepared.failure;
        if (preflightFailure != null) {
          if (uncertainReceiptInvocation != null &&
              preflightFailure['dispatch'] != 'dispatch_outcome_unknown') {
            return _idempotencyReconciliationUnavailable(
              uncertainReceiptInvocation,
              connectionStage: 'protocol_preflight',
            );
          }
          return preflightFailure;
        }
        final replay = prepared.replay;
        if (replay != null) return replay;
        mutation = prepared.invocation!;
        effectiveParams = mutation.params;
      } else {
        effectiveParams = _withReadEnvelope(params);
      }

      Map<String, dynamic> result;
      var reconciledAfterTimeout = false;
      try {
        result = await _invokeServiceExtension(
          service: service,
          isolateId: isolateId,
          method: method,
          params: effectiveParams,
          timeout: timeout,
        );
      } on TimeoutException {
        final invocation = mutation;
        if (invocation == null) rethrow;
        // Reconcile only with the exact same idempotency key and fingerprint.
        // If the first request reached this runtime, the helper returns the
        // original future/result. If it did not, its expired deadline prevents
        // a late dispatch. A fresh key is never generated here.
        try {
          result = await _invokeServiceExtension(
            service: service,
            isolateId: isolateId,
            method: method,
            params: invocation.params,
            timeout: const Duration(seconds: 2),
          );
          reconciledAfterTimeout = true;
        } catch (_) {
          return _closeDurableMutationOutcome(
            invocation,
            _mutationTimeoutFailure(invocation),
          );
        }
      } on RPCError catch (error) {
        if (_looksLikeMissingScoutExtension(error)) {
          throw const ScoutCliException(
            'flutter_scout_helper_not_registered',
            'VM service is reachable, but ext.flutter_scout is not registered. '
                'Add flutter_scout_helper and call '
                'FlutterScoutBinding.ensureInitialized() before runApp(), or '
                'FlutterScoutHelper.ensureRegistered() after an existing debug '
                'binding is initialized.',
          );
        }
        final invocation = mutation;
        if (invocation != null) {
          return _closeDurableMutationOutcome(
            invocation,
            _unknownDispatchProtocolFailure(
              code: 'mutation_transport_error',
              message:
                  'The VM service failed after the mutation request may have been dispatched. Scout will not retry with a new identity.',
              invocation: invocation,
              transport: 'failed',
              details: <String, Object?>{
                'rpcErrorCode': error.code,
                'rpcErrorMessage': error.message,
              },
            ),
          );
        }
        rethrow;
      }

      final invocation = mutation;
      if (invocation == null) return result;
      final identityFailure = _validateMutationResponse(result, invocation);
      if (identityFailure != null) {
        return _closeDurableMutationOutcome(invocation, identityFailure);
      }
      return _closeDurableMutationOutcome(
        invocation,
        _materializeActionCapture(
          _withClosedMutationOutcome(
            result,
            invocation,
            reconciledAfterTimeout: reconciledAfterTimeout,
          ),
          captureOutput,
        ),
      );
    } on RPCError catch (error) {
      if (_looksLikeMissingScoutExtension(error)) {
        if (uncertainReceiptInvocation != null) {
          return _idempotencyReconciliationUnavailable(
            uncertainReceiptInvocation,
            connectionStage: 'protocol_preflight',
            cause: error,
          );
        }
        throw const ScoutCliException(
          'flutter_scout_helper_not_registered',
          'VM service is reachable, but ext.flutter_scout is not registered. '
              'Add flutter_scout_helper and call '
              'FlutterScoutBinding.ensureInitialized() before runApp(), or '
              'FlutterScoutHelper.ensureRegistered() after an existing debug '
              'binding is initialized.',
        );
      }
      final invocation = mutation;
      if (invocation != null) {
        return _closeDurableMutationOutcome(
          invocation,
          _unknownDispatchProtocolFailure(
            code: 'mutation_transport_error',
            message:
                'The VM service failed after the mutation request may have been dispatched. Scout will not retry with a new identity.',
            invocation: invocation,
            transport: 'failed',
            details: <String, Object?>{
              'rpcErrorCode': error.code,
              'rpcErrorMessage': error.message,
            },
          ),
        );
      }
      if (mutating) {
        if (uncertainReceiptInvocation != null) {
          return _idempotencyReconciliationUnavailable(
            uncertainReceiptInvocation,
            connectionStage: 'protocol_preflight',
            cause: error,
          );
        }
        return _notDispatchedProtocolFailure(
          code: 'protocol_preflight_transport_error',
          message:
              'The VM service failed during mutation preflight. Nothing was dispatched.',
          method: method,
          runId: _currentRunIdFromSession(),
          transport: 'failed',
          details: <String, Object?>{
            'rpcErrorCode': error.code,
            'rpcErrorMessage': error.message,
          },
        );
      }
      rethrow;
    } catch (error) {
      // A failed call over a cached connection may mean the socket is dead;
      // drop it so the next step reconnects fresh.
      if (reuse) await _disposeCachedVmService();
      final invocation = mutation;
      if (invocation != null) {
        return _closeDurableMutationOutcome(
          invocation,
          _unknownDispatchProtocolFailure(
            code: 'mutation_transport_error',
            message:
                'The mutation call failed after dispatch may have occurred. Scout will not retry with a new identity.',
            invocation: invocation,
            transport: 'failed',
            details: <String, Object?>{
              'failureType': error.runtimeType.toString(),
            },
          ),
        );
      }
      if (mutating) {
        if (uncertainReceiptInvocation != null) {
          return _idempotencyReconciliationUnavailable(
            uncertainReceiptInvocation,
            connectionStage: 'protocol_preflight',
            cause: error,
          );
        }
        return _notDispatchedProtocolFailure(
          code: 'protocol_preflight_transport_error',
          message:
              'Mutation preflight failed before a request identity was dispatched.',
          method: method,
          runId: _currentRunIdFromSession(),
          transport: 'failed',
          details: <String, Object?>{
            'failureType': error.runtimeType.toString(),
          },
        );
      }
      rethrow;
    } finally {
      if (!reuse) await service.dispose();
    }
  }

  Future<Map<String, dynamic>> _hotUpdate({
    required String action,
    required ProcessSignal signal,
    required bool fullRestart,
  }) => _runDurableLocalMutation(
    method: 'process.flutter.$action',
    businessParams: <String, String>{
      'action': action,
      'signal': signal.toString(),
      'fullRestart': '$fullRestart',
    },
    dispatch: () => _performHotUpdate(
      action: action,
      signal: signal,
      fullRestart: fullRestart,
    ),
    classifyDispatch: _classifyHotUpdateDispatch,
  );

  String _classifyHotUpdateDispatch(Map<String, dynamic> result) {
    final existing = result['dispatch']?.toString();
    if (existing == 'dispatched' ||
        existing == 'not_dispatched' ||
        existing == 'dispatch_outcome_unknown') {
      return existing!;
    }
    final error = result['error'];
    final code = error is Map ? error['code']?.toString() : null;
    if (code == 'not_attached' ||
        code == 'hot_reload_unavailable_owner_exited' ||
        code == 'hot_restart_unavailable' ||
        (code?.endsWith('_signal_failed') ?? false)) {
      return 'not_dispatched';
    }
    if (code == 'vm_reload_unavailable') {
      return 'dispatch_outcome_unknown';
    }
    return 'dispatched';
  }

  Future<Map<String, dynamic>> _performHotUpdate({
    required String action,
    required ProcessSignal signal,
    required bool fullRestart,
  }) async {
    final started = DateTime.now();
    final before = await _tryInspect();
    final beforeRuntimeInstanceId = before?['runtimeInstanceId']?.toString();

    Map<String, dynamic> closeNativeHotUpdateTimings(Map<String, dynamic> raw) {
      var timed = <String, dynamic>{
        for (final entry in raw.entries)
          if (!entry.key.startsWith('_phase')) entry.key: entry.value,
      };
      timed = _withPreflightPhaseTimings(timed, before?['timings']);
      // `_waitForInspectAfterHotUpdate` owns its nested reconnect/snapshot
      // probes as settle work. Do not also aggregate the returned inspect's
      // phases here or those intervals would overlap `settle`.
      final extraConnectMs = raw['_phaseConnectMs'];
      if (extraConnectMs is int) {
        timed = _withMeasuredPhase(
          timed,
          phase: 'connect',
          elapsedMs: _phaseElapsedMs(timed, 'connect') + extraConnectMs,
          owner: 'cli',
          scope: 'sequential helper and native VM-service connections',
        );
      }
      for (final phase in const <String>[
        'dispatch',
        'settle',
        'delta',
        'logs',
      ]) {
        final elapsedMs =
            raw['_phase${phase[0].toUpperCase()}${phase.substring(1)}Ms'];
        if (elapsedMs is int) {
          timed = _withMeasuredPhase(
            timed,
            phase: phase,
            elapsedMs: _phaseElapsedMs(timed, phase) + elapsedMs,
            owner: phase == 'dispatch' || phase == 'logs'
                ? 'cli'
                : 'helper_and_cli',
            scope: switch (phase) {
              'dispatch' => 'native Flutter hot-update dispatch',
              'settle' =>
                'post-dispatch helper availability and semantic settling',
              'delta' =>
                'post-settle source verification and factual delta construction',
              'logs' => 'bounded Flutter-tool acknowledgement log collection',
              _ => 'native Flutter hot-update phase',
            },
          );
        } else {
          timed = _withUnavailablePhase(
            timed,
            phase: phase,
            owner: phase == 'dispatch' || phase == 'logs' ? 'cli' : 'helper',
            reason: raw['dispatch'] == 'not_dispatched'
                ? 'not_applicable:native_hot_update_not_dispatched'
                : 'native_hot_update_phase_not_reached_before_response',
          );
        }
      }
      return _withUnavailablePhase(
        timed,
        phase: 'match',
        owner: 'cli',
        reason: 'not_applicable:native_hot_update_has_no_widget_selector',
      );
    }

    final logCursor = _currentLogCursor();
    final pid = _readPid();
    final sessionMeta = _readSessionMeta();
    if (pid != null && await _matchesOwnedFlutterRun(pid, sessionMeta)) {
      final dispatchStopwatch = Stopwatch()..start();
      final sent = Process.killPid(pid, signal);
      dispatchStopwatch.stop();
      if (!sent) {
        return closeNativeHotUpdateTimings(<String, dynamic>{
          'ok': false,
          'action': action,
          'error': {
            'code': '${action}_signal_failed',
            'message': 'Could not send ${signal.toString()} to pid $pid.',
          },
          'fullRebuildRequired': false,
          'appReachable': before != null,
          'dispatch': 'not_dispatched',
          '_phaseDispatchMs': dispatchStopwatch.elapsedMilliseconds,
        });
      }
      final logsStopwatch = Stopwatch()..start();
      final acknowledgement = await _waitForHotUpdateAcknowledgement(
        action: action,
        sinceCursor: logCursor,
        timeout: _hotUpdateAcknowledgementTimeout(action),
      );
      logsStopwatch.stop();
      if (acknowledgement['ok'] != true) {
        final settleStopwatch = Stopwatch()..start();
        final reachable = await _tryInspect() != null;
        settleStopwatch.stop();
        return closeNativeHotUpdateTimings(<String, dynamic>{
          'ok': false,
          'action': action,
          'method': fullRestart ? 'sigusr2_hot_restart' : 'sigusr1_hot_reload',
          'pid': pid,
          'appReachable': reachable,
          'elapsedMs': DateTime.now().difference(started).inMilliseconds,
          'acknowledgement': acknowledgement,
          'error': {
            'code': acknowledgement['rejected'] == true
                ? '${action}_rejected'
                : '${action}_ack_timeout',
            'message': acknowledgement['message'],
          },
          'dispatch': 'dispatched',
          '_phaseDispatchMs': dispatchStopwatch.elapsedMilliseconds,
          '_phaseLogsMs': logsStopwatch.elapsedMilliseconds,
          '_phaseSettleMs': settleStopwatch.elapsedMilliseconds,
        });
      }
      final acknowledgedAt = DateTime.now();
      final settleStopwatch = Stopwatch()..start();
      final after = await _waitForInspectAfterHotUpdate(
        timeout: _postHotUpdateInspectionTimeout,
        previousRuntimeInstanceId: beforeRuntimeInstanceId,
        requireNewRuntime: fullRestart,
      );
      settleStopwatch.stop();
      final deltaStopwatch = Stopwatch()..start();
      final sourceVerification = await _verifyLoadedDartSources();
      final sourceMismatch = sourceVerification['status'] == 'mismatch';
      final delta = _inspectDelta(before, after);
      deltaStopwatch.stop();
      final elapsedMs = DateTime.now().difference(started).inMilliseconds;
      return closeNativeHotUpdateTimings(<String, dynamic>{
        'ok': after != null && !sourceMismatch,
        'action': action,
        'method': fullRestart ? 'sigusr2_hot_restart' : 'sigusr1_hot_reload',
        'pid': pid,
        'stable': after?['idle'],
        'result': _inspectChanged(before, after) ? 'changed' : 'unchanged',
        'elapsedMs': elapsedMs,
        'timing': {
          'ackMs': acknowledgedAt.difference(started).inMilliseconds,
          'postAckStableMs': DateTime.now()
              .difference(acknowledgedAt)
              .inMilliseconds,
          'totalMs': elapsedMs,
        },
        'acknowledgement': acknowledgement,
        'sourceVerification': sourceVerification,
        'before': before,
        'after': after,
        'delta': delta,
        'recentErrors': after?['recentErrors'] ?? const <Object?>[],
        if (after == null)
          'error': {
            'code': '${action}_timeout',
            'message': 'Timed out waiting for Flutter Scout after $action.',
          },
        if (sourceMismatch)
          'error': {
            'code': '${action}_source_mismatch',
            'message':
                'The VM is still running different source for one or more changed Dart files.',
          },
        if (after == null)
          'nextBestActions': [
            'Run flutter-scout status',
            'Run flutter-scout inspect',
            'If the app is not reachable, run flutter-scout launch --device <sim-id> --project <path>',
          ],
        'dispatch': 'dispatched',
        '_phaseDispatchMs': dispatchStopwatch.elapsedMilliseconds,
        '_phaseLogsMs': logsStopwatch.elapsedMilliseconds,
        '_phaseSettleMs': settleStopwatch.elapsedMilliseconds,
        '_phaseDeltaMs': deltaStopwatch.elapsedMilliseconds,
      });
    }

    if (!fullRestart) {
      final ownershipLossReason = _readSessionMeta()?['ownershipLossReason']
          ?.toString();
      if (ownershipLossReason == 'owner_process_exited') {
        return closeNativeHotUpdateTimings(<String, dynamic>{
          'ok': false,
          'action': action,
          'method': 'unavailable_after_owner_process_exit',
          'freshLaunchRequired': true,
          'appReachable': before != null,
          'state': 'running_app_without_flutter_tool_owner',
          'error': {
            'code': 'hot_reload_unavailable_owner_exited',
            'message':
                'The original Scout-owned Flutter runner exited. The app is still inspectable, but it can no longer compile Dart edits for hot reload.',
          },
          'nextBestActions': [
            'Keep using inspect and actions against the currently running app when previous code is sufficient',
            'Use flutter-scout launch --replace --device <sim-id> --project <path> when a fresh Scout-owned run is acceptable',
          ],
          'dispatch': 'not_dispatched',
        });
      }
      return closeNativeHotUpdateTimings(
        await _vmServiceReload(started: started, before: before),
      );
    }

    return closeNativeHotUpdateTimings(<String, dynamic>{
      'ok': false,
      'action': action,
      'method': 'unavailable_without_scout_owned_flutter_run',
      'fullRebuildRequired': false,
      'attachOnly': true,
      'vmServiceUri': _readVmUri(),
      'vmServiceListenerPid': _readVmUri() == null
          ? null
          : await _pidForListeningVmPort(_readVmUri()!),
      'error': {
        'code': 'hot_restart_unavailable',
        'message':
            'Hot restart requires a Scout-owned flutter run process. Attach-only sessions can inspect and act, but cannot restart the Flutter tool process.',
      },
      'nextBestActions': [
        'Use the owning Flutter terminal or IDE debug session to hot restart this attached app',
        'Run flutter-scout reload for Dart-only changes that can be applied through the VM service',
        'If reload is rejected, relaunch from the owning terminal or start a Scout-owned run with flutter-scout ensure --device <sim-id> --project <path>',
      ],
      'dispatch': 'not_dispatched',
    });
  }

  Future<Map<String, dynamic>> _vmServiceReload({
    required DateTime started,
    required Map<String, dynamic>? before,
  }) async {
    final uri = _readVmUri();
    if (uri == null || uri.isEmpty) {
      return {
        'ok': false,
        'action': 'reload',
        'method': 'vm_service_reload_sources',
        'error': {
          'code': 'not_attached',
          'message': 'Run flutter-scout attach or launch first.',
        },
        'dispatch': 'not_dispatched',
      };
    }
    Stopwatch? connectStopwatch;
    Stopwatch? dispatchStopwatch;
    try {
      connectStopwatch = Stopwatch()..start();
      final service = await _connect(uri);
      connectStopwatch.stop();
      try {
        final isolateId = await _findMainIsolate(service);
        dispatchStopwatch = Stopwatch()..start();
        final report = await service
            .reloadSources(isolateId, force: false, pause: false)
            .timeout(const Duration(seconds: 20));
        final reloadSucceeded = report.success == true;
        try {
          await service
              .callServiceExtension(
                'ext.flutter.reassemble',
                isolateId: isolateId,
              )
              .timeout(const Duration(seconds: 5));
        } catch (_) {
          // Some embedder/tool combinations reassemble as part of reloadSources.
        }
        dispatchStopwatch.stop();
        final settleStopwatch = Stopwatch()..start();
        final after = await _waitForInspectAfterHotUpdate(
          timeout: _postHotUpdateInspectionTimeout,
        );
        settleStopwatch.stop();
        final deltaStopwatch = Stopwatch()..start();
        final sourceVerification = reloadSucceeded
            ? await _verifyLoadedDartSources(
                service: service,
                isolateId: isolateId,
              )
            : const <String, Object?>{'status': 'not_checked'};
        final sourceMismatch = sourceVerification['status'] == 'mismatch';
        final delta = _inspectDelta(before, after);
        deltaStopwatch.stop();
        final elapsedMs = DateTime.now().difference(started).inMilliseconds;
        return {
          'ok': reloadSucceeded && after != null && !sourceMismatch,
          'action': 'reload',
          'method': 'vm_service_reload_sources',
          'reloadReport': report.toJson(),
          'sourceVerification': sourceVerification,
          'appReachable': after != null,
          if (!reloadSucceeded)
            'state':
                'reload_rejected_running_app_still_available_with_previous_code',
          'stable': after?['idle'],
          'result': !reloadSucceeded
              ? 'reload_rejected'
              : _inspectChanged(before, after)
              ? 'changed'
              : 'unchanged',
          'elapsedMs': elapsedMs,
          'before': before,
          'after': after,
          'delta': delta,
          'recentErrors': after?['recentErrors'] ?? const <Object?>[],
          if (!reloadSucceeded)
            'error': {
              'code': 'reload_sources_failed',
              'message':
                  'VM service reloadSources reported failure. The app remained inspectable, so it is likely still running the previous code.',
            },
          if (after == null)
            'error': {
              'code': 'reload_inspect_timeout',
              'message': 'Reload completed but Flutter Scout did not respond.',
            },
          if (sourceMismatch)
            'error': {
              'code': 'reload_source_mismatch',
              'message':
                  'Reload acknowledged, but the VM source differs from changed Dart files on disk.',
            },
          'dispatch': 'dispatched',
          '_phaseConnectMs': connectStopwatch.elapsedMilliseconds,
          '_phaseDispatchMs': dispatchStopwatch.elapsedMilliseconds,
          '_phaseSettleMs': settleStopwatch.elapsedMilliseconds,
          '_phaseDeltaMs': deltaStopwatch.elapsedMilliseconds,
        };
      } finally {
        await service.dispose();
      }
    } catch (error) {
      connectStopwatch?.stop();
      dispatchStopwatch?.stop();
      return {
        'ok': false,
        'action': 'reload',
        'method': 'vm_service_reload_sources',
        'fullRebuildRequired': false,
        'appReachable': await _tryInspect() != null,
        'error': {'code': 'vm_reload_unavailable', 'message': error.toString()},
        'dispatch': dispatchStopwatch == null
            ? 'not_dispatched'
            : 'dispatch_outcome_unknown',
        if (connectStopwatch != null)
          '_phaseConnectMs': connectStopwatch.elapsedMilliseconds,
        if (dispatchStopwatch != null)
          '_phaseDispatchMs': dispatchStopwatch.elapsedMilliseconds,
        'nextBestActions': [
          'Use the owning Flutter terminal or IDE debug session to hot reload this attached app',
          'Start the app with flutter-scout launch to enable signal-based reload/restart',
          'If Dart reload is rejected, relaunch after native, plugin, asset, or pubspec changes',
        ],
      };
    }
  }

  Future<Map<String, Object?>> _verifyLoadedDartSources({
    VmService? service,
    String? isolateId,
  }) async {
    final project = _readSessionMeta()?['project']?.toString();
    if (project == null ||
        project.isEmpty ||
        !Directory(project).existsSync()) {
      return const {'status': 'unavailable', 'reason': 'project_unknown'};
    }
    final changed = await _changedDartFiles(project);
    if (changed.isEmpty) {
      return const {'status': 'no_changes', 'files': <Object?>[]};
    }
    VmService? ownedService;
    try {
      final activeService = service ?? await _connect(_readVmUri()!);
      if (service == null) ownedService = activeService;
      final activeIsolateId =
          isolateId ?? await _findMainIsolate(activeService);
      final refs =
          (await activeService.getScripts(activeIsolateId)).scripts ??
          const <ScriptRef>[];
      final byUri = <String, ScriptRef>{
        for (final ref in refs)
          if (ref.uri != null) ref.uri!: ref,
      };
      final verified = <String>[];
      final mismatched = <String>[];
      final notLoaded = <String>[];
      final skipped = <String>[];
      for (final path in changed) {
        final relative = p.relative(path, from: project).replaceAll('\\', '/');
        if (FlutterScoutCli.isNonRuntimeDartPath(relative)) {
          // Test sources are never compiled into the running app, so counting
          // them as notLoaded downgraded every clean reload to
          // partially_verified and buried the sources that genuinely matter.
          skipped.add(relative);
          continue;
        }
        final candidates = <String>{
          Uri.file(path).toString(),
          ?_packageUriForDartPath(path),
        };
        ScriptRef? ref;
        for (final candidate in candidates) {
          ref ??= byUri[candidate];
        }
        if (ref == null) {
          notLoaded.add(relative);
          continue;
        }
        final object = await activeService.getObject(activeIsolateId, ref.id!);
        final vmSource = object is Script ? object.source : null;
        if (vmSource == null) {
          notLoaded.add(relative);
        } else if (_normalizeSource(vmSource) ==
            _normalizeSource(File(path).readAsStringSync())) {
          verified.add(relative);
        } else {
          mismatched.add(relative);
        }
      }
      return {
        'status': mismatched.isNotEmpty
            ? 'mismatch'
            : notLoaded.isNotEmpty
            ? 'partially_verified'
            : 'verified',
        'verified': verified,
        'mismatched': mismatched,
        'notLoaded': notLoaded,
        if (skipped.isNotEmpty) 'skipped': skipped,
      };
    } catch (error) {
      return {'status': 'unavailable', 'reason': error.toString()};
    } finally {
      await ownedService?.dispose();
    }
  }

  Future<List<String>> _changedDartFiles(String project) async {
    try {
      final rootResult = await Process.run('git', [
        '-C',
        project,
        'rev-parse',
        '--show-toplevel',
      ]);
      if (rootResult.exitCode != 0) return const [];
      final repositoryRoot = '${rootResult.stdout}'.trim();
      if (repositoryRoot.isEmpty) return const [];
      final result = await Process.run('git', [
        '-C',
        project,
        'status',
        '--porcelain',
        '--untracked-files=all',
      ]);
      if (result.exitCode != 0) return const [];
      final files = <String>[];
      for (final line in const LineSplitter().convert('${result.stdout}')) {
        if (line.length < 4) continue;
        var relative = line.substring(3).trim();
        if (relative.contains(' -> ')) {
          relative = relative.split(' -> ').last.trim();
        }
        if (!relative.endsWith('.dart')) continue;
        final path = p.normalize(p.join(repositoryRoot, relative));
        if (File(path).existsSync()) files.add(path);
      }
      return files;
    } catch (_) {
      return const [];
    }
  }

  String? _projectPackageName(String project) {
    final pubspec = File(p.join(project, 'pubspec.yaml'));
    if (!pubspec.existsSync()) return null;
    final match = RegExp(
      r'^name:\s*([a-zA-Z0-9_]+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec.readAsStringSync());
    return match?.group(1);
  }

  String? _packageUriForDartPath(String path) {
    var directory = File(path).parent;
    while (directory.parent.path != directory.path) {
      final pubspec = File(p.join(directory.path, 'pubspec.yaml'));
      if (pubspec.existsSync()) {
        final packageName = _projectPackageName(directory.path);
        final relative = p
            .relative(path, from: directory.path)
            .replaceAll('\\', '/');
        if (packageName != null && relative.startsWith('lib/')) {
          return 'package:$packageName/${relative.substring(4)}';
        }
        return null;
      }
      directory = directory.parent;
    }
    return null;
  }

  String _normalizeSource(String value) =>
      value.replaceAll('\r\n', '\n').trimRight();

  Future<Map<String, dynamic>?> _tryInspect({Duration? callTimeout}) async {
    try {
      return await _call('ext.flutter_scout.inspect', const {}, callTimeout);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _waitForInspectAfterHotUpdate({
    required Duration timeout,
    String? previousRuntimeInstanceId,
    bool requireNewRuntime = false,
  }) => _waitForPostHotUpdateInspection(
    timeout: timeout,
    probeTimeout: _postHotUpdateInspectProbeTimeout,
    stableTimeout: _postHotUpdateWaitStableTimeout,
    retryDelay: _postHotUpdateInspectRetryDelay,
    previousRuntimeInstanceId: previousRuntimeInstanceId,
    requireNewRuntime: requireNewRuntime,
    inspect: (callTimeout) => _tryInspect(callTimeout: callTimeout),
    waitStable: (callTimeout) async {
      await _call('ext.flutter_scout.waitStable', const {
        'timeoutMs': '1500',
      }, callTimeout);
    },
  );

  Future<Map<String, Object?>> _waitForHotUpdateAcknowledgement({
    required String action,
    required int sinceCursor,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    final successPattern = action == 'restart'
        ? RegExp(
            r'(restarted application in|hot restart performed|performing hot restart.*done)',
            caseSensitive: false,
          )
        : RegExp(
            r'(reloaded \d+(?: of \d+)? libraries|hot reload performed|performing hot reload.*done)',
            caseSensitive: false,
          );
    while (DateTime.now().isBefore(deadline)) {
      final file = File(_logFile);
      if (file.existsSync()) {
        var chunk = _readLogChunk(file, sinceCursor: sinceCursor);
        if (chunk.truncated) {
          return {
            'ok': false,
            'truncated': true,
            'cursor': chunk.endCursor,
            'retainedFromCursor': chunk.startCursor,
            'message':
                'Flutter tool acknowledgement logs exceeded the bounded '
                'read window; update success cannot be proven.',
          };
        }
        var failure = _hotUpdateFailureAcknowledgementFromLines(
          action: action,
          rawLines: chunk.lines,
          startCursor: chunk.startCursor,
        );
        if (failure?['rejectionReason'] == 'dart_compile_error' &&
            failure?['terminalRejectionObserved'] != true) {
          // Newer Flutter tools can stop after printing frontend compiler
          // diagnostics without emitting a final "hot reload was rejected"
          // marker. Give the log writer one short bounded window to flush the
          // source line and caret before returning the rejection immediately.
          await Future<void>.delayed(const Duration(milliseconds: 150));
          chunk = _readLogChunk(file, sinceCursor: sinceCursor);
          if (!chunk.truncated) {
            failure = _hotUpdateFailureAcknowledgementFromLines(
              action: action,
              rawLines: chunk.lines,
              startCursor: chunk.startCursor,
            );
          }
        }
        if (failure != null) return failure;
        var cursor = chunk.startCursor;
        for (final rawLine in chunk.lines) {
          cursor += utf8.encode(rawLine).length + 1;
          final line = _redactSensitiveLogText(rawLine);
          if (successPattern.hasMatch(line)) {
            return {
              'ok': true,
              'cursor': cursor,
              'message': _stripLogMetadata(line),
            };
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return {
      'ok': false,
      'timedOut': true,
      'message':
          'Timed out waiting for the Flutter tool to acknowledge $action. The previous runtime was not accepted as updated.',
    };
  }
}

Duration _hotUpdateAcknowledgementTimeout(String action) => action == 'restart'
    ? const Duration(seconds: 30)
    : const Duration(seconds: 60);

Future<Map<String, dynamic>?> _waitForPostHotUpdateInspection({
  required Duration timeout,
  required Duration probeTimeout,
  required Duration stableTimeout,
  required Duration retryDelay,
  required Future<Map<String, dynamic>?> Function(Duration timeout) inspect,
  required Future<void> Function(Duration timeout) waitStable,
  String? previousRuntimeInstanceId,
  bool requireNewRuntime = false,
}) async {
  final elapsed = Stopwatch()..start();

  Duration remaining() {
    final value = timeout - elapsed.elapsed;
    return value.isNegative ? Duration.zero : value;
  }

  Duration bounded(Duration requested) {
    final available = remaining();
    return requested < available ? requested : available;
  }

  Future<void> delayWithinBudget(Duration delay) async {
    final budget = bounded(delay);
    if (budget > Duration.zero) await Future<void>.delayed(budget);
  }

  while (remaining() > Duration.zero) {
    // Keep each call bounded so a restarted isolate cannot consume the full
    // command timeout, while allowing a large healthy widget tree enough time
    // to answer after Flutter has explicitly acknowledged the update.
    final inspectBudget = bounded(probeTimeout);
    final inspected = inspectBudget > Duration.zero
        ? await inspect(inspectBudget)
        : null;
    if (inspected != null && inspected['ok'] == true) {
      final runtimeInstanceId = inspected['runtimeInstanceId']?.toString();
      if (requireNewRuntime &&
          previousRuntimeInstanceId != null &&
          runtimeInstanceId == previousRuntimeInstanceId) {
        await delayWithinBudget(retryDelay);
        continue;
      }

      // Reassembly can make inspect reachable slightly before Flutter has
      // unlocked pointer dispatch. Let the helper observe a stable frame so
      // the next tap/drag is safe immediately after this command returns.
      final stableBudget = bounded(stableTimeout);
      if (stableBudget > Duration.zero) {
        try {
          await waitStable(stableBudget);
        } catch (_) {
          await delayWithinBudget(const Duration(milliseconds: 100));
        }
      }

      final refreshBudget = bounded(probeTimeout);
      if (refreshBudget <= Duration.zero) return inspected;
      return await inspect(refreshBudget) ?? inspected;
    }
    await delayWithinBudget(retryDelay);
  }
  return null;
}

const Duration _postHotUpdateInspectionTimeout = Duration(seconds: 30);
const Duration _postHotUpdateInspectProbeTimeout = Duration(seconds: 12);
const Duration _postHotUpdateWaitStableTimeout = Duration(seconds: 3);
const Duration _postHotUpdateInspectRetryDelay = Duration(milliseconds: 250);

const int _maxHotUpdateCompilerDiagnosticLines = 12;
const int _maxHotUpdateCompilerDiagnosticCharacters = 4096;

final RegExp _hotUpdateTerminalRejectionPattern = RegExp(
  r'(hot reload was rejected|hot restart was rejected|could not hot reload|could not hot restart|try again after fixing the above error)',
  caseSensitive: false,
);

final RegExp _dartCompilerErrorPattern = RegExp(
  r'(?:^|\s)(?:[^\r\n:]+[/\\])?[^\r\n:]+\.dart:\d+:\d+:\s+(?:Error|Internal problem):',
  caseSensitive: false,
);

Map<String, Object?>? _hotUpdateFailureAcknowledgementFromLines({
  required String action,
  required List<String> rawLines,
  required int startCursor,
}) {
  int? compilerErrorIndex;
  int? terminalRejectionIndex;
  var cursor = startCursor;
  final endCursors = <int>[];
  final sanitized = <String>[];

  for (var index = 0; index < rawLines.length; index++) {
    final rawLine = rawLines[index];
    cursor += utf8.encode(rawLine).length + 1;
    endCursors.add(cursor);
    final line = _redactSensitiveLogText(rawLine);
    sanitized.add(line);
    final diagnostic = _stripFlutterToolLogMetadata(line);
    if (compilerErrorIndex == null &&
        _dartCompilerErrorPattern.hasMatch(diagnostic)) {
      compilerErrorIndex = index;
    }
    if (terminalRejectionIndex == null &&
        _hotUpdateTerminalRejectionPattern.hasMatch(diagnostic)) {
      terminalRejectionIndex = index;
    }
  }

  if (compilerErrorIndex == null && terminalRejectionIndex == null) {
    return null;
  }

  final diagnosticLines = <String>[];
  var diagnosticCharacters = 0;
  var diagnosticsTruncated = false;
  if (compilerErrorIndex != null) {
    final endIndex = terminalRejectionIndex ?? sanitized.length;
    for (var index = compilerErrorIndex; index < endIndex; index++) {
      final line = _stripFlutterToolLogMetadata(sanitized[index]);
      if (line.trim().isEmpty) continue;
      final separatorCharacters = diagnosticLines.isEmpty ? 0 : 1;
      final remaining =
          _maxHotUpdateCompilerDiagnosticCharacters -
          diagnosticCharacters -
          separatorCharacters;
      if (diagnosticLines.length >= _maxHotUpdateCompilerDiagnosticLines ||
          remaining <= 0) {
        diagnosticsTruncated = true;
        break;
      }
      if (line.length > remaining) {
        diagnosticLines.add('${line.substring(0, remaining)}…');
        diagnosticsTruncated = true;
        break;
      }
      diagnosticLines.add(line);
      diagnosticCharacters += line.length + separatorCharacters;
    }
  }

  final terminalMessage = terminalRejectionIndex == null
      ? null
      : _stripFlutterToolLogMetadata(sanitized[terminalRejectionIndex]);
  final message = diagnosticLines.isNotEmpty
      ? diagnosticLines.first
      : terminalMessage ?? '$action was rejected by the Flutter tool.';

  return <String, Object?>{
    'ok': false,
    'rejected': true,
    'rejectionReason': compilerErrorIndex == null
        ? 'flutter_tool_rejected'
        : 'dart_compile_error',
    'terminalRejectionObserved': terminalRejectionIndex != null,
    'cursor': endCursors.isEmpty ? startCursor : endCursors.last,
    'message': message,
    if (diagnosticLines.isNotEmpty) 'compilerDiagnostics': diagnosticLines,
    if (diagnosticLines.isNotEmpty)
      'compilerDiagnosticsTruncated': diagnosticsTruncated,
    'terminalMessage': ?terminalMessage,
  };
}

String _stripFlutterToolLogMetadata(String line) {
  var text = _stripLogMetadata(_stripLogAnsi(line));
  text = text.replaceFirst(RegExp(r'^\[FLUTTER_STD(?:OUT|ERR)\]\s*'), '');
  return text.trimRight();
}
