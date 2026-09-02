part of 'flutter_scout_cli.dart';

// part: the `record` command — manage and replay named flow recordings.
//
// Capture itself happens in-app (the helper's gesture recorder). This command
// drives the recorder over the VM service (start/stop/pause/status) and manages
// the on-disk store the helper writes at <cwd>/.flutter_scout/recordings/:
// list/show/rename/delete, plus `run` (replay with pass/fail + a structured
// report) and `export` (freeze to a replayable array).

/// Redacted-value marker written by the helper recorder (must match
/// `_kRecordRedactedPrefix` in flutter_scout_helper/runtime_recorder.dart):
/// a redacted field's value is stored as ` VAR:<field-id>`, resolved at replay
/// from protected `--var-file` or `--var-stdin` input. Legacy `--var` remains
/// available with an explicit process-argument exposure warning.
const String _kRecordRedactedPrefix = ' VAR:';

extension _CliRecord on FlutterScoutCli {
  Directory get _recordingsDir =>
      Directory(p.join(_sessionDir.path, 'recordings'));

  String get _recordingsIndexFile => p.join(_recordingsDir.path, 'index.json');

  static const _recordUsage =
      'Usage: flutter-scout record '
      '[start|stop|pause|resume|undo|status|list|show|rename|delete|run|export|save-last]';

  Future<int> _record(List<String> args) async {
    final action = args.isEmpty ? 'status' : args.first;
    final rest = args.skip(1).toList();
    switch (action) {
      case 'start':
        return _recordStart(rest);
      case 'stop':
        return _recordStop(rest);
      case 'pause':
        return _recordSimple('pause');
      case 'resume':
        return _recordSimple('resume');
      case 'undo':
        return _recordSimple('undo');
      case 'status':
        return _recordSimple('status');
      case 'list':
        return _recordList(rest);
      case 'show':
        return _recordShow(rest);
      case 'rename':
        return _recordRename(rest);
      case 'delete':
        return _recordDelete(rest);
      case 'run':
        return _recordRun(rest);
      case 'export':
        return _recordExport(rest);
      case 'save-last':
        return _recordSaveLast(rest);
      default:
        throw const ScoutCliException('usage', _recordUsage);
    }
  }

  Future<int> _recordSaveLast(List<String> args) async {
    final parser = ArgParser()
      ..addOption('last', defaultsTo: '5')
      ..addOption('feature', defaultsTo: 'unsorted')
      ..addOption('title');
    final parsed = parser.parse(args);
    if (parsed.rest.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: record save-last <name> [--last <count>] [--feature <name>]',
      );
    }
    final count = int.tryParse(parsed.option('last') ?? '') ?? 5;
    if (count < 1) {
      throw const ScoutCliException('usage', '--last must be greater than 0.');
    }
    final actions = _readSessionActions()
        .whereType<Map>()
        .map((item) => Map<String, Object?>.from(item))
        .toList(growable: false);
    if (actions.isEmpty) {
      throw const ScoutCliException(
        'no_actions',
        'No successful session actions are available to save.',
      );
    }
    final selected = actions.length > count
        ? actions.sublist(actions.length - count)
        : actions;
    final now = _isoNow();
    final flow = <String, Object?>{
      'schemaVersion': 1,
      'name': _recordSlug(parsed.rest.first),
      'feature': _recordSlug(parsed.option('feature') ?? 'unsorted'),
      'title': parsed.option('title') ?? parsed.rest.first,
      'createdAt': now,
      'updatedAt': now,
      'source': 'session_journal',
      'steps': selected,
    };
    final path = _writeFlowToStore(flow);
    _appendEvent({
      'schemaVersion': 1,
      'type': 'recording_saved',
      'commandId': ?_activeCommandId,
      'name': flow['name'],
      'feature': flow['feature'],
      'stepCount': selected.length,
      'source': 'session_journal',
      'path': path,
    });
    _printJson({
      'ok': true,
      'name': flow['name'],
      'feature': flow['feature'],
      'stepCount': selected.length,
      'path': path,
    });
    return 0;
  }

  // ---- recorder control (over the VM service) ---------------------------

  Future<int> _recordStart(List<String> args) async {
    final parser = ArgParser()
      ..addOption('feature')
      ..addOption('title')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final name = parsed.rest.isEmpty ? null : parsed.rest.first;
    var result = await _call('ext.flutter_scout.record', {
      'action': 'start',
      'name': ?name,
      if (parsed.option('feature') != null)
        'feature': parsed.option('feature')!,
      if (parsed.option('title') != null) 'title': parsed.option('title')!,
    });
    result = _commitActionEvidence(
      method: 'ext.flutter_scout.record',
      result: result,
    );
    _printJson(result);
    return result['ok'] == false ? 1 : 0;
  }

  Future<int> _recordStop(List<String> args) async {
    final parser = ArgParser()..addFlag('discard', defaultsTo: false);
    final parsed = parser.parse(args);
    final discard = parsed.flag('discard');
    var result = await _call('ext.flutter_scout.record', {
      'action': 'stop',
      if (discard) 'discard': 'true',
    });
    // Fallback persistence: if the in-app helper could not reach the project
    // dir (e.g. iOS-simulator sandbox), write the returned flow from here. The
    // CLI store is canonical for `record list/run`; preserve the helper result
    // separately so one path never overwrites the provenance of the other.
    if (!discard && result['ok'] != false && result['flow'] is Map) {
      final helperPersistence = <String, Object?>{
        'status': result['persistenceStatus'] ?? 'unknown',
        'persisted': result['persisted'] == true,
        if (result['path'] != null) 'path': result['path'],
        if (result['persistenceReason'] != null)
          'reason': result['persistenceReason'],
      };
      final flow = _redactFlowForStorage(
        Map<String, Object?>.from(result['flow'] as Map),
      );
      try {
        final path = _writeFlowToStore(flow);
        result['helperPersistence'] = helperPersistence;
        result['path'] = path;
        result['persisted'] = true;
        result['persistedBy'] = 'cli';
        result['persistenceStatus'] = 'persisted_by_cli';
        result.remove('persistenceReason');
      } catch (error) {
        result['ok'] = false;
        result['helperPersistence'] = helperPersistence;
        result['persisted'] = false;
        result['persistedBy'] = 'none';
        result['persistenceStatus'] = 'cli_persistence_failed';
        result['error'] = {
          'code': 'recording_persistence_failed',
          'message':
              'Recording stopped, but the canonical private CLI store could '
              'not commit the redacted flow: '
              '${_redactSensitiveLogText(error.toString())}',
        };
        result.remove('path');
      }
    }
    result.remove('flow');
    result = _commitActionEvidence(
      method: 'ext.flutter_scout.record',
      result: result,
    );
    _printJson(result);
    return result['ok'] == false ? 1 : 0;
  }

  Future<int> _recordSimple(String action) async {
    var result = await _call('ext.flutter_scout.record', {'action': action});
    if (_isMutatingExtension('ext.flutter_scout.record', <String, String>{
      'action': action,
    })) {
      result = _commitActionEvidence(
        method: 'ext.flutter_scout.record',
        result: result,
      );
    }
    _printJson(result);
    return result['ok'] == false ? 1 : 0;
  }

  // ---- store management (on disk) --------------------------------------

  Future<int> _recordList(List<String> args) async {
    final parser = ArgParser()..addOption('feature');
    final parsed = parser.parse(args);
    // Match the slugged feature the store uses, so `--feature "Auth Flow"`
    // finds recordings saved under `auth-flow`.
    final feature = parsed.option('feature') == null
        ? null
        : _recordSlug(parsed.option('feature')!);
    final rows = _scanRecordings()
        .where((r) => feature == null || r['feature'] == feature)
        .toList();
    _printJson({'ok': true, 'count': rows.length, 'recordings': rows});
    return 0;
  }

  Future<int> _recordShow(List<String> args) async {
    final parser = ArgParser()
      ..addOption('feature')
      ..addFlag('steps', defaultsTo: false)
      ..addFlag('transcript', defaultsTo: false);
    final parsed = parser.parse(args);
    if (parsed.rest.isEmpty) {
      throw const ScoutCliException('usage', 'Usage: record show <name>');
    }
    final flow = _loadFlow(parsed.rest.first, parsed.option('feature'));
    final steps = (flow['steps'] as List?) ?? const [];
    final out = <String, Object?>{
      'ok': true,
      'name': flow['name'],
      'feature': flow['feature'],
      'title': flow['title'],
      'startScreen': flow['startScreen'],
      'stepCount': steps.length,
      'createdAt': flow['createdAt'],
      'updatedAt': flow['updatedAt'],
    };
    if (parsed.flag('transcript')) {
      out['transcript'] = [
        for (var i = 0; i < steps.length; i++)
          '${i + 1} ${_recordStepLine(steps[i] as Map)}',
      ];
    }
    if (parsed.flag('steps')) {
      out['steps'] = steps;
    }
    _printJson(out);
    return 0;
  }

  Future<int> _recordRename(List<String> args) async {
    final parser = ArgParser()..addOption('feature');
    final parsed = parser.parse(args);
    if (parsed.rest.length != 2) {
      throw const ScoutCliException(
        'usage',
        'Usage: record rename <old> <new> [--feature <f>]',
      );
    }
    final file = _findFlowFile(parsed.rest.first, parsed.option('feature'));
    if (file == null) {
      throw ScoutCliException(
        'record_not_found',
        'No recording named `${parsed.rest.first}`.',
      );
    }
    final flow = _redactFlowForStorage(
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>,
    );
    final newName = _recordSlug(parsed.rest[1]);
    final feature = flow['feature']?.toString() ?? 'unsorted';
    final target = File(p.join(_recordingsDir.path, feature, '$newName.json'));
    // Never clobber a different existing recording (data loss).
    if (target.path != file.path && target.existsSync()) {
      throw ScoutCliException(
        'record_name_taken',
        'A recording named `$newName` already exists in feature `$feature`.',
      );
    }
    flow['name'] = newName;
    flow['updatedAt'] = _isoNow();
    _ensurePrivateDirectory(target.parent.path, boundary: _sessionDir.path);
    _atomicWritePrivateString(
      target.path,
      _prettyJson(_redactFlowForStorage(flow)),
      boundary: _sessionDir.path,
    );
    if (target.path != file.path) {
      // Move the old flow's checkpoint dir alongside the rename, then drop it.
      final oldShots = Directory(p.withoutExtension(file.path));
      if (oldShots.existsSync()) {
        oldShots.renameSync(p.withoutExtension(target.path));
      }
      file.deleteSync();
    }
    _rebuildIndex();
    _printJson({'ok': true, 'from': parsed.rest.first, 'to': newName});
    return 0;
  }

  Future<int> _recordDelete(List<String> args) async {
    final parser = ArgParser()..addOption('feature');
    final parsed = parser.parse(args);
    if (parsed.rest.isEmpty) {
      throw const ScoutCliException('usage', 'Usage: record delete <name>');
    }
    final file = _findFlowFile(parsed.rest.first, parsed.option('feature'));
    if (file == null) {
      _printJson({'ok': true, 'deleted': null, 'notFound': parsed.rest.first});
      return 0;
    }
    // Remove the per-flow checkpoint dir (<feature>/<name>/) too, if present.
    final shots = Directory(p.withoutExtension(file.path));
    if (shots.existsSync()) shots.deleteSync(recursive: true);
    final featureDir = file.parent;
    file.deleteSync();
    // Prune the feature directory once its last flow is gone.
    if (featureDir.existsSync() && featureDir.listSync().isEmpty) {
      featureDir.deleteSync();
    }
    _rebuildIndex();
    _printJson({'ok': true, 'deleted': parsed.rest.first});
    return 0;
  }

  // ---- run (replay + pass/fail report) ---------------------------------

  Future<int> _recordRun(List<String> args) async {
    final parser = ArgParser()
      ..addOption('feature')
      ..addFlag('keep-going', defaultsTo: false)
      ..addFlag('verbose', defaultsTo: false);
    _addReplayVariableOptions(parser);
    final parsed = parser.parse(args);
    if (parsed.rest.isEmpty) {
      throw const ScoutCliException('usage', 'Usage: record run <name>');
    }
    final Map<String, Object?> flow;
    try {
      flow = _loadFlow(parsed.rest.first, parsed.option('feature'));
    } on ScoutCliException catch (error) {
      // "Never ran" is distinct from "ran and regressed": exit 2.
      _printJson({
        'ok': false,
        'verdict': 'could-not-start',
        'exitCode': 2,
        'error': {'code': error.code, 'message': error.message},
      });
      return 2;
    }

    final vars = _replayVariablesFromSources(parsed);

    final steps = (flow['steps'] as List?) ?? const [];
    _requireRecordVariables(steps, vars);
    final keepGoing = parsed.flag('keep-going');
    final callerIdempotencyScope = _activeCallerIdempotencyKey;
    final replayIdempotencyScope =
        callerIdempotencyScope ?? _newProtocolIdentifier('record-run');
    final results = <Map<String, Object?>>[];
    var passed = 0;
    var failed = 0;

    // Optional precondition: report (do not hard-fail) a startScreen mismatch.
    Map<String, Object?>? precondition;
    final startScreen = flow['startScreen']?.toString();
    if (startScreen != null && startScreen.isNotEmpty) {
      try {
        final inspect = await _call('ext.flutter_scout.inspect', {
          'brief': 'true',
        });
        final actual = inspect['screen']?.toString();
        precondition = {
          'expected': startScreen,
          'actual': actual,
          'ok': actual == startScreen,
        };
      } catch (_) {
        // Not attached / cannot inspect → could-not-start.
        _printJson({
          'ok': false,
          'verdict': 'could-not-start',
          'exitCode': 2,
          'error': {
            'code': 'not_attached',
            'message': 'Could not reach the app to run the recording.',
          },
        });
        return 2;
      }
    }

    for (var i = 0; i < steps.length; i++) {
      final step = Map<String, Object?>.from(steps[i] as Map);
      final cmd = step['cmd']?.toString() ?? '';
      final method = _recordMethodForCmd(cmd);
      final line = _recordStepLine(step);
      // Pacing floor: if the PREVIOUS step carried no assertion gate (its
      // result wasn't verifiable — e.g. a silent async load), reproduce the
      // human's recorded pause before this step so replay doesn't outrun it.
      // A gated predecessor already waited for readiness, so skip it there.
      if (i > 0 && !_recordStepHasGate(steps[i - 1] as Map)) {
        final dwellMs = int.tryParse('${step['_dwellMs'] ?? ''}') ?? 0;
        final wait = dwellMs.clamp(0, 8000);
        if (wait > 0) {
          await Future<void>.delayed(Duration(milliseconds: wait));
        }
      }
      if (method == null) {
        results.add({
          'step': i + 1,
          'cmd': line,
          'status': 'skipped',
          'reason': 'unsupported_cmd',
        });
        continue;
      }
      final Map<String, String> callParams;
      try {
        callParams = _recordCallParams(step, vars);
      } on ScoutCliException catch (error) {
        // Missing --var for a redacted step: cannot run this flow as-is.
        _printJson({
          'ok': false,
          'verdict': 'could-not-start',
          'exitCode': 2,
          'error': {'code': error.code, 'message': error.message},
          'step': i + 1,
        });
        return 2;
      }
      final stepKey = _derivedStepIdempotencyKey(
        scope: replayIdempotencyScope,
        step: i,
        businessRequest: <String, Object?>{
          'kind': 'record-run',
          'feature': flow['feature'],
          'flow': flow['name'],
          'step': step,
        },
      );
      var result = await _withCallerIdempotencyKey<Map<String, dynamic>>(
        stepKey,
        () => _call(method, callParams),
      );
      result = await _withRecentLogSignals(result);
      result = _commitActionEvidence(
        method: method,
        result: result,
        record: step,
      );
      final ok = result['ok'] == true;
      if (ok) {
        passed++;
        results.add({'step': i + 1, 'cmd': line, 'status': 'pass'});
      } else {
        failed++;
        results.add({
          'step': i + 1,
          'cmd': line,
          'status': 'fail',
          'failure': _recordFailureFor(result),
        });
        if (!keepGoing) break;
      }
    }

    final ranSteps = results.where((r) => r['status'] != 'skipped').length;
    // A flow that executed nothing (empty recording, or every step an
    // unsupported cmd) must not report success — that would mask a broken
    // recording as verified. Treat it as could-not-start (exit 2).
    final String verdict;
    final int exitCode;
    if (ranSteps == 0) {
      verdict = 'no-steps';
      exitCode = 2;
    } else if (failed == 0) {
      verdict = 'pass';
      exitCode = 0;
    } else {
      verdict = 'fail';
      exitCode = 1;
    }
    _printJson({
      'ok': exitCode == 0,
      'feature': flow['feature'],
      'flow': flow['name'],
      'verdict': verdict,
      'exitCode': exitCode,
      'steps': steps.length,
      'ranSteps': ranSteps,
      'passed': passed,
      'failed': failed,
      'precondition': ?precondition,
      'results': results,
      'summary': _recordRunSummary(flow, passed, failed, results),
      'idempotency': <String, Object?>{
        'perStepKeys': 'deterministic_sha256_derivation',
        'scopeKeySource': callerIdempotencyScope == null
            ? 'generated'
            : 'caller',
        'scopeKeyDigest': _idempotencyKeyDigest(replayIdempotencyScope),
      },
      if (callerIdempotencyScope == null)
        'idempotencyScopeKey': replayIdempotencyScope,
    });
    return exitCode;
  }

  Future<int> _recordExport(List<String> args) async {
    final parser = ArgParser()
      ..addOption('feature')
      ..addOption('out', abbr: 'o')
      ..addOption(
        'retention',
        defaultsTo: 'session',
        allowed: const <String>['session', '24h', '7d', 'manual'],
        help: 'Private-data retention for the exported replay artifact.',
      );
    final parsed = parser.parse(args);
    if (parsed.rest.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: record export <name> -o <path> '
            '[--retention session|24h|7d|manual]',
      );
    }
    final flow = _loadFlow(parsed.rest.first, parsed.option('feature'));
    final steps = (flow['steps'] as List?) ?? const [];
    // A plain session-shaped array (recorder metadata stripped) that
    // `flutter-scout replay <file>` runs directly.
    final array = [
      for (final step in steps)
        {
          for (final entry in (step as Map).entries)
            if (!entry.key.toString().startsWith('_') ||
                entry.key == '_redacted' ||
                entry.key == '_redactedFields' ||
                entry.key == '_redactionPolicy')
              entry.key.toString(): entry.value,
        },
    ];
    final outPath =
        parsed.option('out') ??
        p.join(Directory.systemTemp.path, '${flow['name']}.json');
    final retention = _retentionOption(parsed);
    _writePrivateArtifactBytes(outPath, utf8.encode(_prettyJson(array)));
    _writePrivateArtifactMetadata(outPath, retention);
    _printJson({
      'ok': true,
      'name': flow['name'],
      'steps': array.length,
      'requiredVariables': _requiredRecordVariables(array),
      'path': outPath,
      'metadata': '$outPath.metadata.json',
      ..._privateArtifactMetadata(retention),
      'runWith': 'flutter-scout replay $outPath --var-file <0600-vars.json>',
    });
    return 0;
  }

  // ---- helpers ----------------------------------------------------------

  /// Whether a recorded step carries an assertion gate (an `expect*` key), so
  /// its replay waits for readiness rather than needing a dwell floor.
  bool _recordStepHasGate(Map step) =>
      step.keys.any((k) => k.toString().startsWith('expect'));

  String? _recordMethodForCmd(String cmd) => switch (cmd) {
    'tap' => 'ext.flutter_scout.tap',
    'tap-text' => 'ext.flutter_scout.tapText',
    'input' => 'ext.flutter_scout.input',
    'fill' => 'ext.flutter_scout.fill',
    'long-press' => 'ext.flutter_scout.longPress',
    'scroll' => 'ext.flutter_scout.scroll',
    'swipe' => 'ext.flutter_scout.swipe',
    'scroll-to' => 'ext.flutter_scout.scrollTo',
    'back' => 'ext.flutter_scout.back',
    _ => null,
  };

  /// Public VM params for a step: strips `_`-meta and substitutes redacted
  /// `VAR:<key>` values from `--var <key>=<value>`.
  Map<String, String> _recordCallParams(
    Map<String, Object?> step,
    Map<String, String> vars,
  ) {
    // Only a step explicitly flagged `_redacted` carries a VAR placeholder, and
    // only in its `value`. Anchoring to the flag + the exact ' VAR:' prefix
    // avoids mangling a legit value/assertion that merely contains "VAR:".
    final redacted = step['_redacted'] == 'true' || step['_redacted'] == true;
    final out = <String, String>{};
    for (final entry in step.entries) {
      if (entry.key.startsWith('_') || entry.key == 'cmd') continue;
      final resolved = _resolveRecordVariables(
        entry.value,
        vars,
        redacted: redacted,
      );
      if (entry.key == 'values' && resolved is! String) {
        out[entry.key] = jsonEncode(resolved);
      } else {
        out[entry.key] = resolved?.toString() ?? '';
      }
    }
    return out;
  }

  Map<String, Object?> _recordFailureFor(Map<String, dynamic> result) {
    final error = result['error'];
    final code = error is Map ? error['code']?.toString() : null;
    final kind = switch (code) {
      'expectation_not_met' => 'assertion',
      'target_not_found' || 'target_not_visible' => 'changed_handle',
      _ => 'hard_error',
    };
    return {
      'kind': kind,
      'code': ?code,
      if (error is Map && error['message'] != null) 'message': error['message'],
      if (result['expectation'] != null) 'expectation': result['expectation'],
      if (result['recentLogSignals'] != null)
        'logSignals': result['recentLogSignals'],
    };
  }

  String _recordRunSummary(
    Map<String, Object?> flow,
    int passed,
    int failed,
    List<Map<String, Object?>> results,
  ) {
    if (passed + failed == 0) {
      return 'NO RUNNABLE STEPS in ${flow['feature']}/${flow['name']} — '
          'nothing was verified.';
    }
    if (failed == 0) {
      return 'PASS: $passed/${passed + failed} steps passed for '
          '${flow['feature']}/${flow['name']}.';
    }
    final firstFail = results.firstWhere(
      (r) => r['status'] == 'fail',
      orElse: () => const {},
    );
    final where = firstFail.isEmpty
        ? ''
        : ' FAIL step ${firstFail['step']}: ${firstFail['cmd']}'
              ' (${(firstFail['failure'] as Map?)?['kind']})';
    return '$passed passed, $failed failed for '
        '${flow['feature']}/${flow['name']}.$where';
  }

  String _recordStepLine(Map step) {
    final cmd = step['cmd']?.toString() ?? '?';
    final subject =
        step['target'] ??
        step['text'] ??
        step['direction'] ??
        (step['x'] != null ? '${step['x']},${step['y']}' : '');
    final redacted = step['_redacted'] == 'true' ? ' (redacted)' : '';
    return subject.toString().isEmpty ? cmd : '$cmd $subject$redacted';
  }

  // ---- store IO ---------------------------------------------------------

  List<Map<String, Object?>> _scanRecordings() {
    final rows = <Map<String, Object?>>[];
    final root = _recordingsDir;
    if (!root.existsSync()) return rows;
    for (final entity in root.listSync()) {
      if (entity is! Directory) continue;
      final feature = p.basename(entity.path);
      for (final flowFile in entity.listSync()) {
        if (flowFile is! File || !flowFile.path.endsWith('.json')) continue;
        try {
          final flow = jsonDecode(flowFile.readAsStringSync()) as Map;
          rows.add({
            'name': flow['name'],
            'feature': flow['feature'] ?? feature,
            if (flow['title'] != null) 'title': flow['title'],
            'stepCount':
                flow['stepCount'] ?? (flow['steps'] as List?)?.length ?? 0,
            'revision': flow['revision'] ?? 1,
            'startScreen': flow['startScreen'],
            'updatedAt': flow['updatedAt'],
            'path': p.relative(flowFile.path, from: _sessionDir.path),
          });
        } catch (_) {
          // Skip unreadable flow file.
        }
      }
    }
    rows.sort((a, b) {
      final f = '${a['feature']}'.compareTo('${b['feature']}');
      return f != 0 ? f : '${a['name']}'.compareTo('${b['name']}');
    });
    return rows;
  }

  File? _findFlowFile(String name, String? feature) {
    final slug = _recordSlug(name);
    if (feature != null) {
      // The helper stores under a slugged feature dir, so slug here too.
      final f = File(
        p.join(_recordingsDir.path, _recordSlug(feature), '$slug.json'),
      );
      return f.existsSync() ? f : null;
    }
    final matches = <File>[];
    final root = _recordingsDir;
    if (root.existsSync()) {
      for (final dir in root.listSync().whereType<Directory>()) {
        final f = File(p.join(dir.path, '$slug.json'));
        if (f.existsSync()) matches.add(f);
      }
    }
    if (matches.length > 1) {
      throw ScoutCliException(
        'ambiguous_recording',
        'Multiple recordings named `$name`; pass --feature to disambiguate.',
      );
    }
    return matches.isEmpty ? null : matches.first;
  }

  Map<String, Object?> _loadFlow(String name, String? feature) {
    final file = _findFlowFile(name, feature);
    if (file == null) {
      throw ScoutCliException(
        'record_not_found',
        'No recording named `$name`'
            '${feature != null ? ' in feature `$feature`' : ''}.',
      );
    }
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final safe = _redactFlowForStorage(decoded);
    final encoded = _prettyJson(safe);
    if (file.readAsStringSync() != encoded) {
      _atomicWritePrivateString(file.path, encoded, boundary: _sessionDir.path);
    }
    return safe;
  }

  String _writeFlowToStore(Map<String, Object?> flow) {
    final safeFlow = _redactFlowForStorage(flow);
    final feature = safeFlow['feature']?.toString() ?? 'unsorted';
    final name = _recordSlug(safeFlow['name']?.toString() ?? 'recording');
    final file = File(p.join(_recordingsDir.path, feature, '$name.json'));
    _ensurePrivateDirectory(file.parent.path, boundary: _sessionDir.path);
    _atomicWritePrivateString(
      file.path,
      _prettyJson(safeFlow),
      boundary: _sessionDir.path,
    );
    _rebuildIndex();
    return file.path;
  }

  void _rebuildIndex() {
    final rows = _scanRecordings();
    _ensurePrivateDirectory(_recordingsDir.path, boundary: _sessionDir.path);
    _withPrivateFileLock<void>(
      '$_recordingsIndexFile.lock',
      boundary: _sessionDir.path,
      body: () => _atomicWritePrivateString(
        _recordingsIndexFile,
        _prettyJson({
          'schemaVersion': 1,
          'updatedAt': _isoNow(),
          'recordings': rows,
          ..._privateArtifactMetadata('manual'),
        }),
        boundary: _sessionDir.path,
      ),
    );
  }

  String _recordSlug(String raw) {
    final slug = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'recording' : slug;
  }

  String _isoNow() => DateTime.now().toUtc().toIso8601String();

  String _prettyJson(Object? value) =>
      const JsonEncoder.withIndent('  ').convert(value);

  void _printJson(
    Object? value, {
    bool? success,
    String? commandName,
    bool pretty = true,
  }) => _writeCliResponse(
    value,
    success: success,
    commandName: commandName,
    pretty: pretty,
  );
}
