part of 'flutter_scout_cli.dart';

// part: VM response printing, protocol diagnostics, and result compaction.

extension _CliResults on FlutterScoutCli {
  Future<int> _callAndPrint(
    String method, {
    Map<String, String> params = const {},
    Map<String, Object?>? record,
    bool compact = false,
  }) async {
    final result = _withProtocolDiagnostics(
      method,
      await _call(method, params),
    );
    final output = compact ? _compactActionResult(result) : result;
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(output));
    if (record != null && result['ok'] == true) {
      _recordAction(record);
    }
    return result['ok'] == false ? 1 : 0;
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
    if (warnings.isNotEmpty) {
      result['warnings'] = warnings;
    }
    return result;
  }

  Map<String, dynamic> _compactActionResult(Map<String, dynamic> result) {
    if (result['ok'] == false) {
      return {
        ...result,
        if (result['recentErrors'] is List)
          'recentErrors': _lastItems(result['recentErrors'] as List, 3),
      };
    }
    final after = result['after'];
    return {
      'ok': result['ok'],
      if (result['action'] != null) 'action': result['action'],
      if (result['stable'] != null) 'stable': result['stable'],
      if (result['result'] != null) 'result': result['result'],
      if (result['lateChangeObserved'] != null)
        'lateChangeObserved': result['lateChangeObserved'],
      if (result['waitTimedOut'] != null)
        'waitTimedOut': result['waitTimedOut'],
      if (result['method'] != null) 'method': result['method'],
      if (result['state'] != null) 'state': result['state'],
      if (result['appReachable'] != null)
        'appReachable': result['appReachable'],
      if (result['elapsedMs'] != null) 'elapsedMs': result['elapsedMs'],
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
      if (result['fieldResults'] != null)
        'fieldResults': result['fieldResults'],
      if (result['warnings'] != null) 'warnings': result['warnings'],
      if (result['fallback'] != null) 'fallback': result['fallback'],
      if (result['helperProtocol'] != null)
        'helperProtocol': result['helperProtocol'],
      if (after is Map<String, dynamic>) 'afterSummary': _compactSummary(after),
      if (result['delta'] != null) 'delta': result['delta'],
      if (result['recentErrors'] is List)
        'recentErrors': _lastItems(result['recentErrors'] as List, 3),
    };
  }

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
      if (summary['idle'] != null) 'idle': summary['idle'],
      if (summary['visibleText'] is List)
        'visibleText': _lastItems(summary['visibleText'] as List, 12),
      if (summary['hitTestableText'] is List)
        'hitTestableText': _lastItems(summary['hitTestableText'] as List, 12),
      if (summary['offscreenText'] is List)
        'offscreenText': _lastItems(summary['offscreenText'] as List, 8),
      if (summary['fieldValues'] != null) 'fieldValues': summary['fieldValues'],
      if (summary['fieldsById'] != null) 'fieldsById': summary['fieldsById'],
      if (summary['visualTree'] != null) 'visualTree': summary['visualTree'],
      if (summary['controlGroups'] != null)
        'controlGroups': summary['controlGroups'],
      if (summary['suggestedActions'] != null)
        'suggestedActions': summary['suggestedActions'],
    };
  }

  List<Object?> _lastItems(List<dynamic> items, int count) {
    if (items.length <= count) return List<Object?>.from(items);
    return items.sublist(items.length - count);
  }

  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, String> params = const {},
  ]) async {
    final uri = _readVmUri();
    if (uri == null || uri.isEmpty) {
      throw const ScoutCliException(
        'not_attached',
        'Run flutter-scout attach --debug-url <url> first.',
      );
    }
    final service = await _connect(uri);
    try {
      final isolateId = await _findMainIsolate(service);
      final Response response;
      try {
        response = await service
            .callServiceExtension(method, isolateId: isolateId, args: params)
            .timeout(const Duration(seconds: 20));
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
    } finally {
      await service.dispose();
    }
  }

  Future<Map<String, dynamic>> _hotUpdate({
    required String action,
    required ProcessSignal signal,
    required bool fullRestart,
  }) async {
    final started = DateTime.now();
    final before = await _tryInspect();
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
      final after = await _waitForInspectAfterHotUpdate(
        timeout: fullRestart
            ? const Duration(seconds: 15)
            : const Duration(seconds: 8),
      );
      final elapsedMs = DateTime.now().difference(started).inMilliseconds;
      return {
        'ok': after != null,
        'action': action,
        'method': fullRestart ? 'sigusr2_hot_restart' : 'sigusr1_hot_reload',
        'pid': pid,
        'stable': after?['idle'],
        'result': _inspectChanged(before, after) ? 'changed' : 'unchanged',
        'elapsedMs': elapsedMs,
        'before': before,
        'after': after,
        'delta': _inspectDelta(before, after),
        'recentErrors': after?['recentErrors'] ?? const <Object?>[],
        if (after == null)
          'error': {
            'code': '${action}_timeout',
            'message': 'Timed out waiting for Flutter Scout after $action.',
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
        final elapsedMs = DateTime.now().difference(started).inMilliseconds;
        return {
          'ok': reloadSucceeded && after != null,
          'action': 'reload',
          'method': 'vm_service_reload_sources',
          'reloadReport': report.toJson(),
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

  Future<Map<String, dynamic>?> _tryInspect() async {
    try {
      return await _call('ext.flutter_scout.inspect');
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _waitForInspectAfterHotUpdate({
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final inspect = await _tryInspect();
      if (inspect != null && inspect['ok'] == true) return inspect;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }
}
