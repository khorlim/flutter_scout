part of 'flutter_scout_cli.dart';

// Retained evidence bundles and descriptive (non-executable) transcripts.

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

  String _filledKeys(Object? values) {
    if (values is Map) return values.keys.join(', ');
    return 'fields';
  }
}
