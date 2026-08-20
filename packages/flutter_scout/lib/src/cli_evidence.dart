part of 'flutter_scout_cli.dart';

// part: evidence bundle + replay commands and transcript formatting.

const Set<String> _replaySupportedCommands = <String>{
  'tap',
  'tap-text',
  'input',
  'fill',
  'long-press',
  'scroll',
  'swipe',
  'scroll-to',
  'back',
  'deeplink',
};

const Set<String> _replayExpectationFields = <String>{
  'expectText',
  'expectGone',
  'expectTarget',
  'expectSelected',
  'expectScreen',
  'expectView',
  'expectField',
  'expectTimeoutMs',
  'capture',
};

class _ReplayPlanStep {
  const _ReplayPlanStep({
    required this.index,
    required this.command,
    required this.item,
    required this.evidenceMethod,
    required this.callParameters,
    this.deeplinkUrl,
  });

  final int index;
  final String command;
  final Map<String, Object?> item;
  final String evidenceMethod;
  final Map<String, String> callParameters;
  final String? deeplinkUrl;
}

class _ReplayOutcomeAssessment {
  const _ReplayOutcomeAssessment({
    required this.status,
    required this.accepted,
    required this.businessSuccessClaimed,
    required this.transport,
    required this.dispatch,
    required this.observation,
    required this.postcondition,
    required this.runtimeHealth,
    required this.evidenceStatus,
    required this.commandOk,
    this.recoveryAction,
  });

  final String status;
  final bool accepted;
  final bool businessSuccessClaimed;
  final String transport;
  final String dispatch;
  final String observation;
  final String postcondition;
  final String runtimeHealth;
  final String evidenceStatus;
  final bool commandOk;
  final String? recoveryAction;

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status,
    'accepted': accepted,
    'businessSuccessClaimed': businessSuccessClaimed,
    'commandOk': commandOk,
    'transport': transport,
    'dispatch': dispatch,
    'observation': observation,
    'postcondition': postcondition,
    'runtimeHealth': runtimeHealth,
    'evidenceStatus': evidenceStatus,
    if (recoveryAction != null) 'recoveryAction': recoveryAction,
  };
}

extension _CliEvidence on FlutterScoutCli {
  Future<int> _evidence(List<String> args) async {
    final parser = ArgParser()
      ..addOption('output', abbr: 'o')
      ..addOption('last', defaultsTo: '120')
      ..addOption(
        'retention',
        defaultsTo: 'session',
        allowed: const ['session', '24h', '7d', 'manual'],
        help:
            'Private-data retention: session (safe default), 24h, 7d, or manual.',
      )
      ..addFlag(
        'audit',
        defaultsTo: false,
        help:
            'Also write audit.md and transcript.txt as a human-readable UI/UX audit scaffold.',
      );
    final parsed = parser.parse(args);
    _ensureSessionDir();
    final output =
        parsed.option('output') ??
        p.join(
          _sessionDir.path,
          'evidence',
          'evidence_${DateTime.now().microsecondsSinceEpoch}_$pid',
        );
    _assertRetentionRegistryHealthyForWrite();
    final dir = Directory(output);
    final sessionRoot = _absoluteNormalized(_sessionDir.path);
    final evidenceRoot = _absoluteNormalized(dir.path);
    if (FileSystemEntity.typeSync(evidenceRoot, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const ScoutCliException(
        'evidence_output_exists',
        'Evidence output must be a fresh directory so retention cleanup can '
            'prove that every contained path belongs to this bundle.',
      );
    }
    final storageBoundary =
        evidenceRoot == sessionRoot || p.isWithin(sessionRoot, evidenceRoot)
        ? sessionRoot
        : evidenceRoot;
    if (storageBoundary == evidenceRoot) {
      // The caller selected this fresh directory, not its parent chain. Create
      // only that leaf through the same owner-only atomic parent preparation
      // used by file artifacts; missing ancestors and links fail closed.
      _preparePrivateArtifactOutputParent(p.join(evidenceRoot, '.bundle'));
    }
    _ensurePrivateDirectory(
      evidenceRoot,
      boundary: storageBoundary,
      secureExistingTree: true,
    );
    final retention = _retentionOption(parsed);
    final privacy = _privateArtifactMetadata(retention);
    final createdAt = DateTime.now().toUtc();

    void writeJson(String name, Object? value) => _atomicWritePrivateJson(
      p.join(dir.path, name),
      _sanitizeForArtifact(value),
      boundary: storageBoundary,
    );

    void writeText(String name, String value) => _atomicWritePrivateString(
      p.join(dir.path, name),
      value,
      boundary: storageBoundary,
    );

    final last = int.tryParse(parsed.option('last') ?? '') ?? 120;
    final status = await _statusPayload();
    final logs = await _logsPayload(last: last, contains: null, summary: false);
    final logsSummary = await _logsPayload(
      last: 40,
      contains: null,
      summary: true,
    );
    Map<String, dynamic>? inspect;
    Object? inspectError;
    try {
      inspect = await _call('ext.flutter_scout.inspect');
      writeJson('inspect.json', inspect);
    } on ScoutCliException catch (error) {
      inspectError = {'code': error.code, 'message': error.message};
    } catch (error) {
      inspectError = error.toString();
    }

    Map<String, Object?> screenshot = const {
      'ok': false,
      'skipped': true,
      'reason': 'not_attempted',
    };
    final screenshotPath = p.join(dir.path, 'screenshot.png');
    try {
      screenshot = {
        'ok': true,
        'path': screenshotPath,
        ...await _captureScreenshot(screenshotPath),
        ...privacy,
      };
      _writePrivateArtifactMetadata(
        screenshotPath,
        retention,
        metadataPath: p.join(dir.path, 'screenshot.metadata.json'),
        registerForRetention: false,
      );
    } on ScoutCliException catch (error) {
      screenshot = {
        'ok': false,
        'error': {'code': error.code, 'message': error.message},
      };
    } catch (error) {
      screenshot = {
        'ok': false,
        'error': {'code': 'screenshot_failed', 'message': error.toString()},
      };
    }
    screenshot = {...screenshot, ...privacy};

    final sessionActions = _readSessionActions();
    final sessionMeta = _readSessionMeta();
    final events = File(_eventsFile);
    final eventRows = _readEventRows(events);
    final transcript = [
      for (final item in sessionActions)
        if (item is Map<String, dynamic>) _actionLine(item),
    ];
    if (transcript.isNotEmpty) {
      writeText('transcript.txt', '${transcript.join('\n')}\n');
    }
    if (parsed.flag('audit')) {
      writeText(
        'audit.md',
        _auditScaffold(
          status: status,
          inspect: inspect,
          inspectError: inspectError,
          screenshot: screenshot,
          logsSummary: logsSummary,
          transcript: transcript,
        ),
      );
    }
    final missingEvidence = <Map<String, Object?>>[
      const {
        'field': 'source.cliCommit',
        'reason': 'not_embedded_in_cli_binary',
      },
      if (sessionMeta?['appCommit'] == null)
        {
          'field': 'source.appCommit',
          'reason':
              (sessionMeta?['sourceIdentity'] as Map?)?['reason'] ??
              'not_persisted_at_session_start',
        },
      if (sessionMeta?['flutterVersion'] == null)
        {
          'field': 'toolchain.flutterVersion',
          'reason':
              (sessionMeta?['flutterToolchain'] as Map?)?['reason'] ??
              'not_persisted_at_session_start',
        },
      if (inspect == null)
        {
          'field': 'runtime',
          'reason': 'inspect_unavailable',
          'details': inspectError,
        },
      if (logs['available'] != true)
        {
          'field': 'logs',
          'reason': logs['message'] ?? 'runtime_logs_unavailable',
        },
      if (screenshot['ok'] != true)
        {
          'field': 'capture',
          'reason': screenshot['error'] ?? screenshot['reason'],
        },
      const {'field': 'benchmark.seed', 'reason': 'not_a_benchmark_episode'},
      const {
        'field': 'benchmark.hiddenOracle',
        'reason': 'not_a_benchmark_episode',
      },
    ];
    final provenance = <String, Object?>{
      'evidenceSchemaVersion': 1,
      'artifactKind': 'flutter_scout_evidence_bundle',
      'createdAt': createdAt.toIso8601String(),
      'tool': const <String, Object?>{
        'package': 'flutter_scout',
        'version': FlutterScoutCli.packageVersion,
      },
      'protocol': <String, Object?>{
        'schemaVersion': _scoutCliSchemaVersion,
        'cliProtocolMin': _scoutCliProtocolMin,
        'cliProtocolMax': _scoutCliProtocolMax,
        'helperProtocolVersion': inspect?['protocolVersion'],
        'helperProtocolMin': inspect?['minSupportedProtocolVersion'],
        'helperProtocolMax': inspect?['maxSupportedProtocolVersion'],
        'capabilities': inspect?['capabilities'],
      },
      'source': <String, Object?>{
        'cliCommit': null,
        'appCommit': sessionMeta?['appCommit'],
        'identity': sessionMeta?['sourceIdentity'],
        'project': sessionMeta?['project'],
      },
      'toolchain': <String, Object?>{
        'dartRuntimeVersion': Platform.version,
        'flutterVersion': sessionMeta?['flutterVersion'],
        'flutter': sessionMeta?['flutterToolchain'],
      },
      'platform': <String, Object?>{
        'hostOperatingSystem': Platform.operatingSystem,
        'hostOperatingSystemVersion': Platform.operatingSystemVersion,
        'device': status['device'] ?? sessionMeta?['device'],
        'deviceInfo': status['deviceInfo'],
      },
      'run': <String, Object?>{
        'sessionName': sessionMeta?['name'],
        'runId': inspect?['runId'] ?? sessionMeta?['runId'],
        'runtimeInstanceId': inspect?['runtimeInstanceId'],
        'stateGeneration': inspect?['stateGeneration'],
        'snapshotId': inspect?['snapshotId'],
        'sessionCreatedAt': sessionMeta?['createdAt'],
        'sessionUpdatedAt': sessionMeta?['updatedAt'],
      },
      'benchmark': const <String, Object?>{
        'episode': false,
        'seed': null,
        'hiddenOracle': null,
      },
      'transcript': <String, Object?>{
        'actionCount': sessionActions.length,
        'eventJournalPresent': eventRows.isNotEmpty,
      },
      'missingEvidence': missingEvidence,
    };
    final summary = {
      'ok': true,
      'path': dir.path,
      'createdAt': createdAt.toIso8601String(),
      ...privacy,
      'provenance': provenance,
      'missingEvidence': missingEvidence,
      'status': status,
      'inspect': inspect == null
          ? {'ok': false, 'error': inspectError ?? 'inspect_unavailable'}
          : {
              'ok': true,
              'screen': inspect['screen'],
              'visibleText': _lastItems(
                (inspect['visibleText'] as List?) ?? const [],
                20,
              ),
              'recentErrors': _lastItems(
                (inspect['recentErrors'] as List?) ?? const [],
                5,
              ),
            },
      'screenshot': screenshot,
      'logs': {
        'available': logs['available'],
        'source': logs['source'],
        if (logs['message'] != null) 'message': logs['message'],
        'summary': logsSummary,
      },
      'sessionActions': {
        'path': _sessionFile,
        'count': sessionActions.length,
        'last': _lastItems(sessionActions, 20),
        if (transcript.isNotEmpty) 'transcript': _lastItems(transcript, 20),
      },
      'files': {
        'summary': p.join(dir.path, 'summary.json'),
        if (inspect != null) 'inspect': p.join(dir.path, 'inspect.json'),
        'logs': p.join(dir.path, 'logs.json'),
        'status': p.join(dir.path, 'status.json'),
        if (sessionActions.isNotEmpty)
          'session': p.join(dir.path, 'session.json'),
        if (eventRows.isNotEmpty) 'events': p.join(dir.path, 'events.jsonl'),
        if (transcript.isNotEmpty)
          'transcript': p.join(dir.path, 'transcript.txt'),
        if (parsed.flag('audit')) 'audit': p.join(dir.path, 'audit.md'),
        if (screenshot['ok'] == true) 'screenshot': screenshotPath,
        if (screenshot['ok'] == true)
          'screenshotMetadata': p.join(dir.path, 'screenshot.metadata.json'),
        'retentionMetadata': p.join(dir.path, 'retention.metadata.json'),
      },
    };

    writeJson('status.json', status);
    writeJson('logs.json', logs);
    if (sessionActions.isNotEmpty) {
      writeJson('session.json', sessionActions);
    }
    if (eventRows.isNotEmpty) {
      final safeEvents = <String>[];
      for (final event in eventRows) {
        try {
          safeEvents.add(jsonEncode(_sanitizeForArtifact(event)));
        } catch (_) {
          safeEvents.add(_redactActiveSensitiveText(jsonEncode(event)));
        }
      }
      writeText(
        'events.jsonl',
        safeEvents.isEmpty ? '' : '${safeEvents.join('\n')}\n',
      );
    }
    writeJson('summary.json', summary);
    // A bundle is one retention unit. Register it only after every payload and
    // its in-bundle metadata are committed, so cleanup never owns a partial
    // directory or a caller's pre-existing tree.
    _writePrivateArtifactMetadata(
      dir.path,
      retention,
      metadataPath: p.join(dir.path, 'retention.metadata.json'),
      createdAt: createdAt,
    );
    _registerEvidenceBundle(summary);
    _printJson(summary);
    return 0;
  }

  void _registerEvidenceBundle(Map<String, Object?> summary) {
    final evidenceDirectory = p.join(_sessionDir.path, 'evidence');
    final indexPath = p.join(evidenceDirectory, 'index.json');
    _ensurePrivateDirectory(evidenceDirectory, boundary: _sessionDir.path);
    _withPrivateFileLock<void>(
      '$indexPath.lock',
      boundary: _sessionDir.path,
      body: () {
        final file = File(indexPath);
        _assertPrivateFilePath(indexPath, boundary: _sessionDir.path);
        var bundles = <Object?>[];
        if (file.existsSync()) {
          final Object? decoded;
          try {
            decoded = jsonDecode(file.readAsStringSync());
          } catch (_) {
            throw const ScoutCliException(
              'evidence_index_corrupt',
              'The evidence index is not valid JSON.',
            );
          }
          if (decoded is! Map || decoded['bundles'] is! List) {
            throw const ScoutCliException(
              'evidence_index_corrupt',
              'The evidence index has an invalid structure.',
            );
          }
          bundles = List<Object?>.from(decoded['bundles'] as List);
        }
        bundles.add({
          'path': summary['path'],
          'createdAt': summary['createdAt'],
          'dataClassification': summary['dataClassification'],
          'retentionPolicy': summary['retentionPolicy'],
        });
        _atomicWritePrivateJson(indexPath, {
          'schemaVersion': 1,
          'dataClassification': _privateApplicationData,
          'telemetryCollected': false,
          'bundles': bundles,
        }, boundary: _sessionDir.path);
      },
    );
  }

  String _actionLine(Map<String, dynamic> item) {
    final cmd = item['cmd']?.toString() ?? 'unknown';
    return switch (cmd) {
      'tap-text' => 'tap-text "${item['text']}"',
      'tap' =>
        item['target'] != null
            ? 'tap ${item['target']}'
            : 'tap ${item['x']},${item['y']}',
      'input' => 'input ${item['target'] ?? 'focused'}',
      'fill' => 'fill ${_filledKeys(item['values'])}',
      'long-press' => 'long-press ${item['target']}',
      'scroll' => 'scroll ${item['direction'] ?? ''}'.trim(),
      'swipe' => 'swipe ${item['direction'] ?? ''}'.trim(),
      'scroll-to' => 'scroll-to ${item['target']}',
      'back' => 'back',
      'dismiss' => 'dismiss',
      'reload' => 'reload',
      'restart' => 'restart',
      'deeplink' => 'deeplink ${item['url']}',
      _ => cmd,
    };
  }

  String _auditScaffold({
    required Map<String, Object?> status,
    required Map<String, dynamic>? inspect,
    required Object? inspectError,
    required Map<String, Object?> screenshot,
    required Map<String, Object?> logsSummary,
    required List<String> transcript,
  }) {
    final buffer = StringBuffer()
      ..writeln('# Flutter Scout UI/UX Audit')
      ..writeln()
      ..writeln('Created: ${DateTime.now().toIso8601String()}')
      ..writeln()
      ..writeln('## Current State')
      ..writeln()
      ..writeln('- Status available: ${status['ok'] != false}')
      ..writeln(
        '- Screen: ${inspect == null ? 'unavailable' : inspect['screen'] ?? 'unknown'}',
      )
      ..writeln(
        '- View signature: ${inspect == null ? 'unavailable' : inspect['viewSignature'] ?? 'unknown'}',
      )
      ..writeln(
        '- Screenshot: ${screenshot['ok'] == true ? 'captured' : 'not captured'}',
      )
      ..writeln(
        '- Logs available: ${logsSummary['available'] == true ? 'yes' : 'no'}',
      );
    if (inspect == null) {
      buffer.writeln('- Inspect error: $inspectError');
    }
    buffer
      ..writeln()
      ..writeln('## Flow Transcript')
      ..writeln();
    if (transcript.isEmpty) {
      buffer.writeln('No recorded Scout actions in this evidence bundle.');
    } else {
      for (var i = 0; i < transcript.length; i++) {
        buffer.writeln('${i + 1}. ${transcript[i]}');
      }
    }
    buffer
      ..writeln()
      ..writeln('## Findings')
      ..writeln()
      ..writeln('- P0: ')
      ..writeln('- P1: ')
      ..writeln('- P2: ')
      ..writeln()
      ..writeln('## Evidence Files')
      ..writeln()
      ..writeln('- `summary.json`')
      ..writeln('- `status.json`')
      ..writeln('- `logs.json`')
      ..writeln('- `inspect.json` when inspect was available')
      ..writeln('- `screenshot.png` when capture was available')
      ..writeln(
        '- `session.json` and `transcript.txt` when actions were recorded',
      );
    return buffer.toString();
  }

  Future<int> _replay(List<String> args) async {
    final parser = ArgParser()..addFlag('verbose', defaultsTo: false);
    _addReplayVariableOptions(parser);
    final parsed = parser.parse(args);
    if (parsed.rest.length > 1) {
      throw const ScoutCliException(
        'replay_input_conflict',
        'Replay accepts at most one input path.',
      );
    }
    final vars = _replayVariablesFromSources(parsed);
    final path = parsed.rest.isEmpty ? _sessionFile : parsed.rest.first;
    final source = _readBoundedCommandFile(path, kind: 'replay');
    _validateBoundedJsonText(source, kind: 'replay');
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const ScoutCliException(
        'replay_invalid_json',
        'Replay input must contain one valid bounded JSON document.',
      );
    }
    _validateBoundedJsonValue(decoded, kind: 'replay');
    if (decoded is! List) {
      throw const ScoutCliException(
        'replay_invalid',
        'Replay file must contain a JSON array.',
      );
    }
    final plan = _preflightReplay(decoded, vars);
    final results = <Object?>[];
    final transcript = <String>[];
    final stepOutcomes = <Map<String, Object?>>[];
    final callerIdempotencyScope = _activeCallerIdempotencyKey;
    final replayIdempotencyScope =
        callerIdempotencyScope ?? _newProtocolIdentifier('replay');
    for (final step in plan) {
      final item = step.item;
      final stepKey = _derivedStepIdempotencyKey(
        scope: replayIdempotencyScope,
        step: step.index,
        businessRequest: <String, Object?>{'kind': 'replay', 'step': item},
      );
      final result = await _withCallerIdempotencyKey<Map<String, Object?>>(
        stepKey,
        () async => step.deeplinkUrl != null
            ? _replayDeeplink(step.deeplinkUrl)
            : _call(step.evidenceMethod, step.callParameters),
      );
      var enrichedResult = await _withRecentLogSignals(
        Map<String, dynamic>.from(result),
      );
      enrichedResult = _commitActionEvidence(
        method: step.evidenceMethod,
        result: enrichedResult,
        record: item,
      );
      final assessment = _assessReplayOutcome(enrichedResult);
      final assessmentJson = <String, Object?>{
        'step': step.index + 1,
        'command': step.command,
        ...assessment.toJson(),
      };
      stepOutcomes.add(assessmentJson);
      enrichedResult = <String, dynamic>{
        ...enrichedResult,
        'replayOutcome': assessmentJson,
      };
      results.add(
        parsed.flag('verbose') || enrichedResult['ok'] == false
            ? enrichedResult
            : <String, Object?>{
                ..._compactActionResult(enrichedResult),
                'replayOutcome': assessmentJson,
              },
      );
      transcript.add(_transcriptStep(item, assessment));
    }
    final succeeded = stepOutcomes.every(
      (outcome) => outcome['accepted'] == true,
    );
    final verified =
        succeeded &&
        stepOutcomes.every(
          (outcome) => outcome['businessSuccessClaimed'] == true,
        );
    final verdict = !succeeded
        ? 'failed'
        : verified
        ? 'verified'
        : 'completed_unasserted';
    _printJson({
      'ok': succeeded,
      'verdict': verdict,
      'businessSuccessClaimed': verified,
      'commandCompleted': succeeded,
      'transcript': transcript,
      'results': results,
      'stepOutcomes': stepOutcomes,
      'verifiedSteps': stepOutcomes
          .where((outcome) => outcome['businessSuccessClaimed'] == true)
          .length,
      'unassertedSteps': stepOutcomes
          .where((outcome) => outcome['status'] == 'completed_unasserted')
          .length,
      'failedSteps': stepOutcomes
          .where((outcome) => outcome['accepted'] != true)
          .length,
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
    return succeeded ? 0 : 1;
  }

  List<_ReplayPlanStep> _preflightReplay(
    List<dynamic> decoded,
    Map<String, String> variables,
  ) {
    if (decoded.isEmpty) {
      throw const ScoutCliException(
        'replay_empty',
        'Replay input contains no actions, so it cannot verify anything.',
      );
    }
    if (decoded.length > _maxReplayActions) {
      throw const ScoutCliException(
        'replay_too_many_actions',
        'Replay inputs are limited to $_maxReplayActions actions.',
      );
    }

    final actions = <Map<String, Object?>>[];
    for (var index = 0; index < decoded.length; index++) {
      final raw = decoded[index];
      if (raw is! Map || raw.keys.any((key) => key is! String)) {
        throw ScoutCliException(
          'replay_element_invalid',
          'Replay action ${index + 1} must be one JSON object. Nothing was dispatched.',
          additional: <String, Object?>{
            'step': index + 1,
            'dispatch': 'not_dispatched',
          },
        );
      }
      final action = <String, Object?>{
        for (final entry in raw.entries) entry.key as String: entry.value,
      };
      _validateReplayAction(action, step: index + 1);
      final redacted = _redactRecordedAction(action);
      _validateReplayRedaction(redacted, step: index + 1);
      actions.add(redacted);
    }

    // Resolve every required protected value and materialize every exact VM
    // parameter map before the first action can dispatch.
    _requireRecordVariables(actions, variables);
    final plan = <_ReplayPlanStep>[];
    for (var index = 0; index < actions.length; index++) {
      final item = actions[index];
      final command = item['cmd']! as String;
      final evidenceMethod = _replayMethod(command);
      final callParameters = command == 'deeplink'
          ? const <String, String>{}
          : command == 'input' || command == 'fill'
          ? _recordCallParams(item, variables)
          : <String, String>{
              for (final entry in _stringMap(item).entries)
                if (!entry.key.startsWith('_')) entry.key: entry.value,
            };
      for (final entry in callParameters.entries) {
        if (!_isWellFormedUnicode(entry.key) ||
            !_isWellFormedUnicode(entry.value) ||
            utf8.encode(entry.key).length > _maxBatchReplayStringBytes ||
            utf8.encode(entry.value).length > _maxBatchReplayStringBytes) {
          throw ScoutCliException(
            'replay_parameter_bounds_exceeded',
            'Replay action ${index + 1} exceeds the per-parameter bound.',
            additional: <String, Object?>{
              'step': index + 1,
              'dispatch': 'not_dispatched',
            },
          );
        }
      }
      final deeplinkUrl = command == 'deeplink'
          ? _validateDeeplinkUrl(
              _resolveRecordVariables(
                item['url'],
                variables,
                redacted: true,
              )!.toString(),
            )
          : null;
      plan.add(
        _ReplayPlanStep(
          index: index,
          command: command,
          item: item,
          evidenceMethod: evidenceMethod,
          callParameters: callParameters,
          deeplinkUrl: deeplinkUrl,
        ),
      );
    }
    return plan;
  }

  void _validateReplayAction(Map<String, Object?> action, {required int step}) {
    final rawCommand = action['cmd'];
    if (rawCommand is! String || rawCommand.isEmpty) {
      throw _replayPreflightError(
        'replay_command_missing',
        'Replay action $step requires a non-empty string `cmd`.',
        step,
      );
    }
    final command = rawCommand;
    if (!_replaySupportedCommands.contains(command)) {
      throw _replayPreflightError(
        'replay_command_forbidden',
        'Replay action $step uses unsupported command `$command`. Lifecycle, infrastructure, and recursive commands are never replay actions.',
        step,
        command: command,
      );
    }
    final allowed = _allowedReplayFields(command);
    final extras = action.keys.where((key) => !allowed.contains(key)).toList()
      ..sort();
    if (extras.isNotEmpty) {
      throw _replayPreflightError(
        'replay_extra_field',
        'Replay action $step contains fields outside the `$command` schema.',
        step,
        command: command,
        details: <String, Object?>{'extraFields': extras},
      );
    }
    for (final entry in action.entries) {
      if (entry.value == null) {
        throw _replayPreflightError(
          'replay_field_invalid',
          'Replay action $step contains a null field.',
          step,
          command: command,
        );
      }
      if (entry.key == 'values' || entry.key == '_redactedFields') continue;
      if (entry.value is! String &&
          entry.value is! num &&
          entry.value is! bool) {
        throw _replayPreflightError(
          'replay_field_invalid',
          'Replay action $step has an invalid `${entry.key}` value type.',
          step,
          command: command,
        );
      }
    }
    _validateReplayMetadata(action, step: step, command: command);

    _validateReplayPlaceholderScope(action, step: step, command: command);
    _validateReplayExpectations(action, step: step, command: command);
    switch (command) {
      case 'tap':
        _validateReplayTargetOrCoordinates(
          action,
          step: step,
          command: command,
        );
        _replayBoundedInt(action['waitMs'], 0, 60000, 'waitMs', step, command);
      case 'tap-text':
        _requireReplayString(action, 'text', step, command);
        _replayBoundedInt(action['waitMs'], 0, 60000, 'waitMs', step, command);
        _validateReplayBoolean(
          action['allowMismatch'],
          'allowMismatch',
          step,
          command,
        );
        _validateReplayBoolean(action['contains'], 'contains', step, command);
      case 'input':
        _requireReplayString(action, 'value', step, command);
        if (action['target'] != null) {
          _requireReplayString(action, 'target', step, command);
        }
      case 'fill':
        final values = _decodeReplayFillValues(action['values'], step: step);
        if (values.isEmpty) {
          throw _replayPreflightError(
            'replay_required_field_missing',
            'Replay fill action $step requires at least one field value.',
            step,
            command: command,
          );
        }
      case 'long-press':
        _validateReplayTargetOrCoordinates(
          action,
          step: step,
          command: command,
        );
        _replayBoundedInt(
          action['durationMs'],
          1,
          60000,
          'durationMs',
          step,
          command,
        );
      case 'scroll':
      case 'swipe':
        _validateReplayOptionalString(action, 'target', step, command);
        final direction = action['direction']?.toString();
        if (direction != null &&
            !const {'up', 'down', 'left', 'right'}.contains(direction)) {
          throw _replayPreflightError(
            'replay_field_invalid',
            'Replay action $step has an invalid direction.',
            step,
            command: command,
          );
        }
        for (final field in const <String>['distance', 'x', 'y']) {
          _replayFiniteNumber(action[field], field, step, command);
        }
        _validateReplayPoint(action['point'], 'point', step, command);
        _validateReplayPoint(action['to'], 'to', step, command);
      case 'scroll-to':
        _requireReplayString(action, 'target', step, command);
        _replayBoundedInt(
          action['maxScrolls'],
          1,
          100,
          'maxScrolls',
          step,
          command,
        );
        final direction = action['direction']?.toString();
        if (direction != null &&
            !const {'up', 'down', 'left', 'right'}.contains(direction)) {
          throw _replayPreflightError(
            'replay_field_invalid',
            'Replay action $step has an invalid scroll-to direction.',
            step,
            command: command,
          );
        }
        _replayFiniteNumber(action['distance'], 'distance', step, command);
      case 'back':
      // The strict allowlist already proves this action has no parameters.
      case 'deeplink':
        _requireReplayString(action, 'url', step, command);
        final urlSource = action['urlSource'];
        if (urlSource != null &&
            (urlSource is! String ||
                !const <String>{
                  'legacy_process_argv',
                  'protected_owner_only_file',
                  'protected_stdin',
                }.contains(urlSource))) {
          throw _replayPreflightError(
            'replay_field_invalid',
            'Replay deep-link action $step has invalid source metadata.',
            step,
            command: command,
          );
        }
      // Source-redacted URLs are resolved and URI-validated only after all
      // replay variables have been proven present for the complete plan.
    }
  }

  void _validateReplayPlaceholderScope(
    Map<String, Object?> action, {
    required int step,
    required String command,
  }) {
    final allowedField = switch (command) {
      'input' => 'value',
      'fill' => 'values',
      'deeplink' => 'url',
      _ => null,
    };
    final forbidden = <String>[
      for (final entry in action.entries)
        if (entry.key != allowedField)
          ..._recordVariableOccurrences(entry.value),
    ];
    if (command == 'fill') {
      final values = _decodeReplayFillValues(action['values'], step: step);
      for (final key in values.keys) {
        forbidden.addAll(_recordVariableOccurrences(key));
      }
    }
    if (forbidden.isEmpty) return;
    throw _replayPreflightError(
      'replay_placeholder_scope_invalid',
      'Replay action $step contains a protected placeholder outside its secret business value.',
      step,
      command: command,
    );
  }

  void _validateReplayMetadata(
    Map<String, Object?> action, {
    required int step,
    required String command,
  }) {
    final redacted = action['_redacted'];
    if (redacted != null && redacted != true && redacted != 'true') {
      throw _replayPreflightError(
        'replay_redaction_metadata_invalid',
        'Replay action $step has invalid redaction metadata.',
        step,
        command: command,
      );
    }
    final policy = action['_redactionPolicy'];
    if (policy != null && policy != 'source') {
      throw _replayPreflightError(
        'replay_redaction_metadata_invalid',
        'Replay action $step has an unsupported redaction policy.',
        step,
        command: command,
      );
    }
    final fields = action['_redactedFields'];
    if (fields != null &&
        (fields is! List || fields.any((field) => field is! String))) {
      throw _replayPreflightError(
        'replay_redaction_metadata_invalid',
        'Replay action $step has invalid redacted-field metadata.',
        step,
        command: command,
      );
    }
  }

  void _validateReplayRedaction(
    Map<String, Object?> action, {
    required int step,
  }) {
    final command = action['cmd']! as String;
    final placeholders = _requiredRecordVariables(action);
    for (final name in placeholders) {
      _validateProtectedVariableName(name);
    }
    if (command == 'input') {
      if (action['_redacted'] != 'true' && action['_redacted'] != true ||
          !_isRecordVariable(action['value']) ||
          placeholders.length != 1) {
        throw _replayPreflightError(
          'replay_redaction_incomplete',
          'Replay input action $step did not reduce to one protected placeholder.',
          step,
          command: command,
        );
      }
    } else if (command == 'fill') {
      final values = action['values'];
      if (action['_redacted'] != 'true' && action['_redacted'] != true ||
          values is! Map ||
          values.isEmpty ||
          values.values.any((value) => !_isRecordVariable(value))) {
        throw _replayPreflightError(
          'replay_redaction_incomplete',
          'Replay fill action $step did not reduce every value to a protected placeholder.',
          step,
          command: command,
        );
      }
    } else if (command == 'deeplink') {
      if (action['_redacted'] != 'true' && action['_redacted'] != true ||
          action['_redactionPolicy'] != 'source' ||
          !_isRecordVariable(action['url']) ||
          placeholders.length != 1) {
        throw _replayPreflightError(
          'replay_redaction_incomplete',
          'Replay deep-link action $step must preserve one source-redacted URL placeholder.',
          step,
          command: command,
        );
      }
    } else if (placeholders.isNotEmpty) {
      throw _replayPreflightError(
        'replay_placeholder_scope_invalid',
        'Replay action $step contains a placeholder outside input/fill values.',
        step,
        command: command,
      );
    }
  }

  Map<String, Object?> _decodeReplayFillValues(
    Object? raw, {
    required int step,
  }) {
    final Object? decoded;
    if (raw is String) {
      _validateBoundedJsonText(raw, kind: 'replay_fill');
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        throw _replayPreflightError(
          'replay_field_invalid',
          'Replay fill action $step has malformed JSON values.',
          step,
          command: 'fill',
        );
      }
    } else {
      decoded = raw;
    }
    if (decoded is! Map ||
        decoded.keys.any((key) => key is! String || key.toString().isEmpty) ||
        decoded.values.any((value) => value is! String)) {
      throw _replayPreflightError(
        'replay_field_invalid',
        'Replay fill action $step requires a string-to-string values object.',
        step,
        command: 'fill',
      );
    }
    return <String, Object?>{
      for (final entry in decoded.entries) entry.key as String: entry.value,
    };
  }

  void _validateReplayExpectations(
    Map<String, Object?> action, {
    required int step,
    required String command,
  }) {
    for (final field in const <String>[
      'expectText',
      'expectGone',
      'expectTarget',
      'expectSelected',
      'expectScreen',
      'expectView',
      'expectField',
    ]) {
      _validateReplayOptionalString(action, field, step, command);
    }
    _replayBoundedInt(
      action['expectTimeoutMs'],
      1,
      120000,
      'expectTimeoutMs',
      step,
      command,
    );
    final field = action['expectField'];
    if (field is String && field.indexOf('=') <= 0) {
      throw _replayPreflightError(
        'replay_field_invalid',
        'Replay action $step expectField must use <handle>=<value>.',
        step,
        command: command,
      );
    }
    _validateReplayBoolean(action['capture'], 'capture', step, command);
  }

  void _validateReplayTargetOrCoordinates(
    Map<String, Object?> action, {
    required int step,
    required String command,
  }) {
    final target = action['target'];
    if (target != null && (target is! String || target.isEmpty)) {
      throw _replayPreflightError(
        'replay_field_invalid',
        'Replay action $step `target` must be a non-empty string.',
        step,
        command: command,
      );
    }
    final hasTarget = target != null && target.toString().isNotEmpty;
    final x = action['x'];
    final y = action['y'];
    final hasCoordinates = x != null || y != null;
    if (hasTarget == hasCoordinates ||
        (hasCoordinates && (x == null || y == null))) {
      throw _replayPreflightError(
        'replay_required_field_missing',
        'Replay action $step requires exactly one target or one complete x/y pair.',
        step,
        command: command,
      );
    }
    _replayFiniteNumber(x, 'x', step, command);
    _replayFiniteNumber(y, 'y', step, command);
  }

  void _requireReplayString(
    Map<String, Object?> action,
    String field,
    int step,
    String command,
  ) {
    final value = action[field];
    if (value is! String || value.isEmpty) {
      throw _replayPreflightError(
        'replay_required_field_missing',
        'Replay action $step requires non-empty string `$field`.',
        step,
        command: command,
      );
    }
  }

  void _validateReplayOptionalString(
    Map<String, Object?> action,
    String field,
    int step,
    String command,
  ) {
    final value = action[field];
    if (value != null && (value is! String || value.isEmpty)) {
      throw _replayPreflightError(
        'replay_field_invalid',
        'Replay action $step `$field` must be a non-empty string.',
        step,
        command: command,
      );
    }
  }

  void _validateReplayBoolean(
    Object? value,
    String field,
    int step,
    String command,
  ) {
    if (value == null || value is bool || value == 'true' || value == 'false') {
      return;
    }
    throw _replayPreflightError(
      'replay_field_invalid',
      'Replay action $step `$field` must be true or false.',
      step,
      command: command,
    );
  }

  void _validateReplayPoint(
    Object? value,
    String field,
    int step,
    String command,
  ) {
    if (value == null) return;
    if (value is! String) {
      throw _replayPreflightError(
        'replay_field_invalid',
        'Replay action $step `$field` must use x,y.',
        step,
        command: command,
      );
    }
    final parts = value.split(',');
    if (parts.length != 2) {
      throw _replayPreflightError(
        'replay_field_invalid',
        'Replay action $step `$field` must use x,y.',
        step,
        command: command,
      );
    }
    _replayFiniteNumber(parts[0].trim(), '$field.x', step, command);
    _replayFiniteNumber(parts[1].trim(), '$field.y', step, command);
  }

  void _replayBoundedInt(
    Object? value,
    int minimum,
    int maximum,
    String field,
    int step,
    String command,
  ) {
    if (value == null) return;
    final parsed = int.tryParse(value.toString());
    if (parsed == null || parsed < minimum || parsed > maximum) {
      throw _replayPreflightError(
        'replay_field_invalid',
        'Replay action $step `$field` must be an integer from $minimum to $maximum.',
        step,
        command: command,
      );
    }
  }

  void _replayFiniteNumber(
    Object? value,
    String field,
    int step,
    String command,
  ) {
    if (value == null) return;
    final parsed = double.tryParse(value.toString());
    if (parsed == null || !parsed.isFinite || parsed.abs() > 10000000) {
      throw _replayPreflightError(
        'replay_field_invalid',
        'Replay action $step `$field` must be a bounded finite number.',
        step,
        command: command,
      );
    }
  }

  ScoutCliException _replayPreflightError(
    String code,
    String message,
    int step, {
    String? command,
    Map<String, Object?> details = const <String, Object?>{},
  }) => ScoutCliException(
    code,
    '$message Nothing was dispatched.',
    details: details,
    additional: <String, Object?>{
      'step': step,
      'command': ?command,
      'dispatch': 'not_dispatched',
    },
  );

  String _replayMethod(String command) => switch (command) {
    'tap' => 'ext.flutter_scout.tap',
    'tap-text' => 'ext.flutter_scout.tapText',
    'input' => 'ext.flutter_scout.input',
    'fill' => 'ext.flutter_scout.fill',
    'long-press' => 'ext.flutter_scout.longPress',
    'scroll' => 'ext.flutter_scout.scroll',
    'swipe' => 'ext.flutter_scout.swipe',
    'scroll-to' => 'ext.flutter_scout.scrollTo',
    'back' => 'ext.flutter_scout.back',
    'deeplink' => 'platform.deeplink',
    _ => throw StateError('Replay command was not preflighted: $command'),
  };

  Set<String> _allowedReplayFields(String command) => <String>{
    'cmd',
    '_redacted',
    '_redactedFields',
    '_redactionPolicy',
    ...switch (command) {
      'tap' => const <String>{
        'target',
        'x',
        'y',
        'waitMs',
        ..._replayExpectationFields,
      },
      'tap-text' => const <String>{
        'text',
        'waitMs',
        'allowMismatch',
        'contains',
        ..._replayExpectationFields,
      },
      'input' => const <String>{'target', 'value', ..._replayExpectationFields},
      'fill' => const <String>{'values', ..._replayExpectationFields},
      'long-press' => const <String>{'target', 'x', 'y', 'durationMs'},
      'scroll' || 'swipe' => const <String>{
        'direction',
        'target',
        'distance',
        'x',
        'y',
        'point',
        'to',
      },
      'scroll-to' => const <String>{
        'target',
        'maxScrolls',
        'direction',
        'distance',
      },
      'back' => const <String>{},
      'deeplink' => const <String>{'url', 'urlSource'},
      _ => const <String>{},
    },
  };

  _ReplayOutcomeAssessment _assessReplayOutcome(Map<String, Object?> result) {
    final transport = result['transport']?.toString() ?? 'unavailable';
    final dispatch = result['dispatch']?.toString() ?? 'unavailable';
    final observation = result['observation']?.toString() ?? 'unavailable';
    final postcondition = result['postcondition']?.toString() ?? 'unavailable';
    final runtimeHealth = result['runtimeHealth']?.toString() ?? 'unavailable';
    final evidence = result['evidence'];
    final evidenceStatus = evidence is Map
        ? evidence['status']?.toString() ?? 'unavailable'
        : 'unavailable';
    final commandOk = result['ok'] == true;

    String status;
    String? recovery;
    if (transport != 'ok') {
      status = 'transport_failed';
    } else if (dispatch == 'dispatch_outcome_unknown') {
      status = 'dispatch_outcome_unknown';
      recovery =
          'Inspect and reconcile current state with the same idempotency key; do not issue a fresh mutation identity.';
    } else if (dispatch != 'dispatched') {
      status = dispatch == 'not_dispatched'
          ? 'not_dispatched'
          : 'outcome_incomplete';
    } else if (observation == 'observation_unavailable') {
      status = 'observation_unavailable';
      recovery =
          'Inspect current state before deciding whether any new mutation is safe.';
    } else if (observation == 'no_effect') {
      status = 'no_effect';
    } else if (observation != 'changed' &&
        observation != 'completed_same_state') {
      status = 'outcome_incomplete';
    } else if (postcondition == 'postcondition_not_met') {
      status = 'postcondition_not_met';
    } else if (postcondition != 'postcondition_met' &&
        postcondition != 'postcondition_not_requested') {
      status = 'outcome_incomplete';
    } else if (runtimeHealth == 'runtime_blocked') {
      status = 'runtime_blocked';
    } else if (runtimeHealth != 'runtime_clean') {
      status = runtimeHealth == 'runtime_health_unknown'
          ? 'runtime_health_unknown'
          : 'outcome_incomplete';
    } else if (evidenceStatus != 'committed') {
      status = 'evidence_commit_failed';
      recovery =
          'Reconcile the observed state and durable receipt before retrying.';
    } else if (!commandOk) {
      status = 'command_failed';
    } else if (postcondition == 'postcondition_met') {
      status = 'verified';
    } else {
      status = 'completed_unasserted';
    }
    final accepted = status == 'verified' || status == 'completed_unasserted';
    return _ReplayOutcomeAssessment(
      status: status,
      accepted: accepted,
      businessSuccessClaimed: status == 'verified',
      transport: transport,
      dispatch: dispatch,
      observation: observation,
      postcondition: postcondition,
      runtimeHealth: runtimeHealth,
      evidenceStatus: evidenceStatus,
      commandOk: commandOk,
      recoveryAction: recovery,
    );
  }

  String _transcriptStep(
    Map<String, Object?> item,
    _ReplayOutcomeAssessment assessment,
  ) {
    final cmd = item['cmd']?.toString() ?? 'unknown';
    final action = switch (cmd) {
      'tap-text' => 'tap-text "${item['text']}"',
      'tap' =>
        item['target'] != null
            ? 'tap ${item['target']}'
            : 'tap ${item['x']},${item['y']}',
      'input' => 'input ${item['target'] ?? 'focused'}',
      'fill' => 'fill ${_filledKeys(item['values'])}',
      'long-press' => 'long-press ${item['target']}',
      'scroll' => 'scroll ${item['direction'] ?? ''}'.trim(),
      'swipe' => 'swipe ${item['direction'] ?? ''}'.trim(),
      'scroll-to' => 'scroll-to ${item['target']}',
      'back' => 'back',
      'deeplink' => 'deeplink ${item['url']}',
      _ => cmd,
    };
    return <String>[
      action,
      assessment.status,
      'transport=${assessment.transport}',
      'dispatch=${assessment.dispatch}',
      'observation=${assessment.observation}',
      'postcondition=${assessment.postcondition}',
      'runtimeHealth=${assessment.runtimeHealth}',
      'evidence=${assessment.evidenceStatus}',
    ].join(' -> ');
  }

  String _filledKeys(Object? values) {
    if (values is Map) return values.keys.join(', ');
    return 'fields';
  }

  Future<Map<String, Object?>> _replayDeeplink(String? url) async {
    if (url == null || url.isEmpty) {
      return {'ok': false, 'error': 'deeplink replay missing url'};
    }
    try {
      return await _durableDeeplink(url);
    } catch (error) {
      return {'ok': false, 'error': error.toString()};
    }
  }
}

/// Deterministic test surface for the exact truthfulness classifier used by
/// replay final/result/exit semantics. It performs no I/O or dispatch.
extension FlutterScoutCliReplayTesting on FlutterScoutCli {
  Map<String, Object?> debugAssessReplayOutcome(Map<String, Object?> result) =>
      _assessReplayOutcome(result).toJson();
}
