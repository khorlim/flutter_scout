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
    String? expectLog,
    String? rejectLog,
    Duration logExpectationTimeout = const Duration(seconds: 5),
  }) async {
    final totalStopwatch = Stopwatch()..start();
    final logCursor = _currentLogCursor();
    final vmStopwatch = Stopwatch()..start();
    var result = _withProtocolDiagnostics(
      method,
      await _call(method, params, callTimeout),
    );
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
    totalStopwatch.stop();
    enrichedResult = {
      ...enrichedResult,
      'timings': {
        'vmCallMs': vmStopwatch.elapsedMilliseconds,
        'logSettleAndExpectationMs': logStopwatch.elapsedMilliseconds,
        'totalMs': totalStopwatch.elapsedMilliseconds,
      },
    };
    final output = compact
        ? _compactActionResult(enrichedResult)
        : enrichedResult;
    _emitActionOutput(output);
    if (record != null && enrichedResult['ok'] == true) {
      _recordAction(record);
      await _maybeStartAutoServe();
    }
    _appendEvent({
      'schemaVersion': 1,
      'type': 'action_result',
      'commandId': ?_activeCommandId,
      'method': method,
      'ok': enrichedResult['ok'] == true,
      'runId': ?enrichedResult['runId'],
      'runtimeInstanceId': ?enrichedResult['runtimeInstanceId'],
      'snapshotId': ?enrichedResult['snapshotId'],
      'timings': enrichedResult['timings'],
      if (enrichedResult['error'] != null) 'error': enrichedResult['error'],
      'blockingRuntimeErrors': _objectList(
        enrichedResult['blockingErrors'],
      ).length,
      'blockingLogSignals': _objectList(
        enrichedResult['blockingLogSignals'],
      ).length,
    });
    return enrichedResult['ok'] == false ? 1 : 0;
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
      text = _readLogChunk(file, sinceCursor: sinceCursor).lines.join('\n');
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
    final capture = result['capture'];
    if (capture is! Map) return result;
    final encoded = capture['bytes'];
    if (encoded is! String || encoded.isEmpty) return result;
    try {
      final file = File(output).absolute;
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(base64Decode(encoded));
      return {
        ...result,
        'capture': {
          for (final entry in capture.entries)
            if (entry.key != 'bytes') entry.key.toString(): entry.value,
          'path': file.path,
        },
      };
    } catch (error) {
      return {
        ...result,
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
    final runtime = _objectList(
      result['recentErrors'],
    ).where(blocking).toList();
    final logs = _objectList(
      result['recentLogSignals'],
    ).where(blocking).toList();
    if (runtime.isEmpty && logs.isEmpty) return result;
    return {
      ...result,
      'ok': false,
      'error': {
        'code': 'blocking_errors_observed',
        'message':
            'The action completed, but fresh blocking runtime errors were observed.',
      },
      'blockingErrors': runtime,
      'blockingLogSignals': logs,
    };
  }

  void _emitActionOutput(Map<String, dynamic> output) {
    if (_suppressActionOutput) {
      _suppressedActionResults.add(Map<String, dynamic>.from(output));
      return;
    }
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(output));
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
      if (signals.isNotEmpty) 'recentLogSignals': _logSignalMaps(signals),
    };
  }

  Future<Map<String, dynamic>> _tapTextFallbackIfNeeded(
    Map<String, dynamic> result,
    Map<String, String> params,
  ) async {
    if (!_needsTapTextFallback(result)) return result;
    final textTarget = result['target'];
    if (textTarget is! Map<String, dynamic>) return result;
    final inspect = await _tryInspect();
    if (inspect == null) return result;
    final fallbackTarget = _findActionableForTextTarget(inspect, textTarget);
    if (fallbackTarget == null) return result;
    final fallbackId = fallbackTarget['id']?.toString();
    if (fallbackId == null || fallbackId.isEmpty) return result;

    final fallbackResult = await _call('ext.flutter_scout.tap', {
      'target': fallbackId,
      if (params['waitMs'] != null) 'waitMs': params['waitMs']!,
    });
    return {
      ...fallbackResult,
      'action': 'tap-text ${params['text'] ?? params['target']}',
      'target': fallbackResult['target'] ?? fallbackTarget,
      'textTarget': textTarget,
      'fallback': {
        'used': true,
        'reason':
            'attached_helper_returned_text_target_without_actionable_parent',
        'target': fallbackId,
      },
      'warnings': [
        ..._objectList(fallbackResult['warnings']),
        'Attached helper did not provide tap-text actionable-parent data; CLI retried using overlapping inspect target `$fallbackId`.',
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

  Map<String, dynamic>? _findActionableForTextTarget(
    Map<String, dynamic> inspect,
    Map<String, dynamic> textTarget,
  ) {
    final textRect = _rectFromNode(textTarget);
    if (textRect == null) return null;
    final candidates = _nodesFromInspect(inspect, 'interactables')
        .where((node) => node['kind'] != 'text' && node['kind'] != 'field')
        .toList(growable: false);
    Map<String, dynamic>? best;
    var bestScore = 0.0;
    for (final candidate in candidates) {
      final rect = _rectFromNode(candidate);
      if (rect == null) continue;
      final containsCenter = _rectContains(rect, _rectCenter(textRect));
      final overlap = _overlapRatio(textRect, rect);
      final sameLabel =
          candidate['label'] != null &&
          textTarget['label'] != null &&
          candidate['label'].toString() == textTarget['label'].toString();
      final score =
          (containsCenter ? 3.0 : 0.0) +
          (sameLabel ? 2.0 : 0.0) +
          overlap -
          (_rectArea(rect) / 1000000000);
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return bestScore > 0 ? best : null;
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
        'ok': false,
        if (result['error'] != null) 'error': result['error'],
        if (result['action'] != null) 'action': result['action'],
        if (result['stable'] != null) 'stable': result['stable'],
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
      'ok': result['ok'],
      if (result['action'] != null) 'action': result['action'],
      if (result['stable'] != null) 'stable': result['stable'],
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

  Map<String, dynamic> _compactBriefInspect(Map<String, dynamic> result) {
    final compact = Map<String, dynamic>.from(result);
    if (compact['protocolMismatch'] == null) {
      compact.remove('helperProtocolVersion');
    }
    compact
      ..remove('runtimeInstanceId')
      ..removeWhere(
        (_, value) =>
            value == null ||
            (value is List && value.isEmpty) ||
            (value is Map && value.isEmpty),
      );
    final visible = compact['visibleText'];
    final hitTestable = compact['hitTestableText'];
    if (visible is List && hitTestable is List) {
      final hitSet = hitTestable.map((value) => value.toString()).toSet();
      final nonHitTestable = [
        for (final value in visible)
          if (!hitSet.contains(value.toString())) value,
      ];
      if (nonHitTestable.length <= 4) {
        compact.remove('hitTestableText');
        if (nonHitTestable.isNotEmpty) {
          compact['nonHitTestableText'] = nonHitTestable;
        }
      }
    }
    return compact;
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
  ]) async {
    final uri = _readVmUri();
    if (uri == null || uri.isEmpty) {
      throw const ScoutCliException(
        'not_attached',
        'Run flutter-scout attach --debug-url <url> first.',
      );
    }
    // In batch mode one WebSocket serves every step; per-call connect/dispose
    // is pure overhead (and a timing gap the UI can drift through).
    final reuse = _reuseVmConnection;
    final VmService service;
    if (reuse && _cachedVmService != null && _cachedVmUri == uri) {
      service = _cachedVmService!;
    } else {
      service = await _connect(uri);
      if (reuse) {
        await _disposeCachedVmService();
        _cachedVmService = service;
        _cachedVmUri = uri;
      }
    }
    try {
      final isolateId = await _findMainIsolate(service);
      final Response response;
      try {
        response = await service
            .callServiceExtension(method, isolateId: isolateId, args: params)
            .timeout(callTimeout ?? const Duration(seconds: 20));
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
        rethrow;
      }
      final json = response.json;
      if (json == null) return {'ok': false, 'error': 'empty VM response'};
      if (json.containsKey('ok')) {
        return Map<String, dynamic>.from(json);
      }
      final result = json['result'];
      if (result is String) {
        return jsonDecode(result) as Map<String, dynamic>;
      }
      if (result is Map<String, dynamic>) {
        return result;
      }
      return Map<String, dynamic>.from(json);
    } catch (_) {
      // A failed call over a cached connection may mean the socket is dead;
      // drop it so the next step reconnects fresh.
      if (reuse) await _disposeCachedVmService();
      rethrow;
    } finally {
      if (!reuse) await service.dispose();
    }
  }

  Future<Map<String, dynamic>> _hotUpdate({
    required String action,
    required ProcessSignal signal,
    required bool fullRestart,
  }) async {
    final started = DateTime.now();
    final before = await _tryInspect();
    final beforeRuntimeInstanceId = before?['runtimeInstanceId']?.toString();
    final logCursor = _currentLogCursor();
    final pid = _readPid();
    if (pid != null && await _looksLikeScoutFlutterRun(pid)) {
      final sent = Process.killPid(pid, signal);
      if (!sent) {
        return {
          'ok': false,
          'action': action,
          'error': {
            'code': '${action}_signal_failed',
            'message': 'Could not send ${signal.toString()} to pid $pid.',
          },
          'fullRebuildRequired': false,
          'appReachable': before != null,
        };
      }
      final acknowledgement = await _waitForHotUpdateAcknowledgement(
        action: action,
        sinceCursor: logCursor,
        timeout: fullRestart
            ? const Duration(seconds: 30)
            : const Duration(seconds: 20),
      );
      if (acknowledgement['ok'] != true) {
        return {
          'ok': false,
          'action': action,
          'method': fullRestart ? 'sigusr2_hot_restart' : 'sigusr1_hot_reload',
          'pid': pid,
          'appReachable': await _tryInspect() != null,
          'elapsedMs': DateTime.now().difference(started).inMilliseconds,
          'acknowledgement': acknowledgement,
          'error': {
            'code': acknowledgement['rejected'] == true
                ? '${action}_rejected'
                : '${action}_ack_timeout',
            'message': acknowledgement['message'],
          },
        };
      }
      final acknowledgedAt = DateTime.now();
      final after = await _waitForInspectAfterHotUpdate(
        timeout: fullRestart
            ? const Duration(seconds: 15)
            : const Duration(seconds: 8),
        previousRuntimeInstanceId: beforeRuntimeInstanceId,
        requireNewRuntime: fullRestart,
      );
      final sourceVerification = await _verifyLoadedDartSources();
      final sourceMismatch = sourceVerification['status'] == 'mismatch';
      final elapsedMs = DateTime.now().difference(started).inMilliseconds;
      return {
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
        'delta': _inspectDelta(before, after),
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
      };
    }

    if (!fullRestart) {
      return _vmServiceReload(started: started, before: before);
    }

    return {
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
    };
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
      };
    }
    try {
      final service = await _connect(uri);
      try {
        final isolateId = await _findMainIsolate(service);
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
        final after = await _waitForInspectAfterHotUpdate(
          timeout: const Duration(seconds: 8),
        );
        final sourceVerification = reloadSucceeded
            ? await _verifyLoadedDartSources(
                service: service,
                isolateId: isolateId,
              )
            : const <String, Object?>{'status': 'not_checked'};
        final sourceMismatch = sourceVerification['status'] == 'mismatch';
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
          'delta': _inspectDelta(before, after),
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
        };
      } finally {
        await service.dispose();
      }
    } catch (error) {
      return {
        'ok': false,
        'action': 'reload',
        'method': 'vm_service_reload_sources',
        'fullRebuildRequired': false,
        'appReachable': await _tryInspect() != null,
        'error': {'code': 'vm_reload_unavailable', 'message': error.toString()},
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
      for (final path in changed) {
        final relative = p.relative(path, from: project).replaceAll('\\', '/');
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
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      // A restarted isolate can leave an in-flight service-extension call
      // hanging until the normal 20-second command timeout. Bound each probe
      // so the loop can reconnect after the new isolate registers instead of
      // reporting a false restart timeout even though the app is back.
      final inspect = await _tryInspect(
        callTimeout: const Duration(seconds: 1),
      );
      if (inspect != null && inspect['ok'] == true) {
        final runtimeInstanceId = inspect['runtimeInstanceId']?.toString();
        if (requireNewRuntime &&
            previousRuntimeInstanceId != null &&
            runtimeInstanceId == previousRuntimeInstanceId) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          continue;
        }
        // Reassembly can make inspect reachable slightly before Flutter has
        // unlocked pointer dispatch. Let the helper observe a stable frame so
        // the next tap/drag is safe immediately after this command returns.
        try {
          await _call('ext.flutter_scout.waitStable', const {
            'timeoutMs': '1500',
          }, const Duration(seconds: 3));
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        return await _tryInspect(callTimeout: const Duration(seconds: 1)) ??
            inspect;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

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
    final rejectionPattern = RegExp(
      r'(hot reload was rejected|hot restart was rejected|could not hot reload|could not hot restart|try again after fixing the above error)',
      caseSensitive: false,
    );
    while (DateTime.now().isBefore(deadline)) {
      final file = File(_logFile);
      if (file.existsSync()) {
        final chunk = _readLogChunk(file, sinceCursor: sinceCursor);
        var cursor = chunk.startCursor;
        for (final rawLine in chunk.lines) {
          cursor += utf8.encode(rawLine).length + 1;
          final line = _redactSensitiveLogText(rawLine);
          if (rejectionPattern.hasMatch(line)) {
            return {
              'ok': false,
              'rejected': true,
              'cursor': cursor,
              'message': _stripLogMetadata(line),
            };
          }
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
