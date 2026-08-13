part of 'flutter_scout_cli.dart';

// part: safe selection and repair of existing named/owned sessions.

extension _CliSessionRecovery on FlutterScoutCli {
  static const Set<String> _commandsUsingCurrentSession = {
    'status',
    'stop',
    'cleanup',
    'inspect',
    'annotations',
    'bounds',
    'tap',
    'tap-text',
    'long-press',
    'input',
    'fill',
    'scroll',
    'scroll-to',
    'swipe',
    'drag-start',
    'drag-move',
    'drag-end',
    'drag-cancel',
    'drag-status',
    'back',
    'dismiss',
    'wait',
    'wait-for',
    'health',
    'batch',
    'export-batch',
    'serve',
    'explore',
    'reload',
    'restart',
    'deeplink',
    'logs',
    'screenshot',
    'crop',
    'evidence',
    'replay',
    'record',
  };

  void _selectImplicitNamedSession(String command) {
    if (FlutterScoutCli._sessionDirectoryOverride != null ||
        !_commandsUsingCurrentSession.contains(command)) {
      return;
    }
    final root = Directory(p.join(Directory.current.path, '.flutter_scout'));
    if (_directoryHasCurrentSession(root)) return;
    final sessions = Directory(p.join(root.path, 'sessions'));
    if (!sessions.existsSync()) return;
    final candidates =
        sessions
            .listSync(followLinks: false)
            .whereType<Directory>()
            .where(_directoryHasCurrentSession)
            .toList(growable: false)
          ..sort((a, b) => a.path.compareTo(b.path));
    if (candidates.isEmpty) return;
    if (candidates.length > 1) {
      final names = candidates
          .map((entry) => p.basename(entry.path))
          .join(', ');
      throw ScoutCliException(
        'session_selection_required',
        'Multiple named Scout sessions are available: $names. '
            'Choose one with `flutter-scout --app <name> $command`.',
      );
    }
    final selected = candidates.single;
    FlutterScoutCli._sessionDirectoryOverride = selected.path;
    _implicitlySelectedSessionName = p.basename(selected.path);
  }

  bool _directoryHasCurrentSession(Directory directory) {
    if (!directory.existsSync()) return false;
    for (final fileName in const ['vm_uri.txt', 'flutter.pid', 'launch.lock']) {
      if (File(p.join(directory.path, fileName)).existsSync()) return true;
    }
    final metaFile = File(p.join(directory.path, 'session_meta.json'));
    if (!metaFile.existsSync()) return false;
    try {
      final decoded = jsonDecode(metaFile.readAsStringSync());
      if (decoded is! Map) return false;
      final state = decoded['state']?.toString();
      return state == null || (state != 'stopped' && state != 'failed');
    } catch (_) {
      return false;
    }
  }

  Future<_DiscoveredVmUri?> _recoverMissingOwnedVmUri() async {
    final meta = _readSessionMeta();
    if (meta?['mode'] != 'scout_owned_flutter_run') return null;
    var ownerPid = _readPid() ?? int.tryParse('${meta?['pid'] ?? ''}');
    if (ownerPid == null || !await _looksLikeScoutFlutterRun(ownerPid)) {
      final project = meta?['project']?.toString();
      if (project == null || project.isEmpty) return null;
      ownerPid = await _findScoutFlutterToolPid(
        project: project,
        instanceName: meta?['name']?.toString(),
      );
      if (ownerPid == null || !await _looksLikeScoutFlutterRun(ownerPid)) {
        return null;
      }
    }
    final discovered = _discoverVmUriFromScoutLog();
    if (discovered == null || discovered.isEmpty) return null;
    final uri = _normalizeVmUri(discovered);
    final validation = await _validateVmUri(uri);
    if (!validation.ok) return null;
    File(_pidFile).writeAsStringSync('$ownerPid');
    File(_vmUriFile).writeAsStringSync(uri);
    final now = DateTime.now().toUtc().toIso8601String();
    _writeSessionMeta({
      ...?meta,
      'mode': 'scout_owned_flutter_run',
      'state': 'ready',
      'pid': ownerPid,
      'vmServiceUri': uri,
      'updatedAt': now,
      'recoveredAt': now,
    });
    await _ensureVmLogListenerForCurrentSession(uri);
    return _DiscoveredVmUri(uri: uri, source: 'scout_owned_log');
  }

  Future<bool> _reconcileReachableSessionOwnership(String vmUri) async {
    final meta = _readSessionMeta();
    if (meta?['mode'] != 'scout_owned_flutter_run') return false;

    var ownerPid = _readPid() ?? int.tryParse('${meta?['pid'] ?? ''}');
    if (ownerPid != null && await _looksLikeScoutFlutterRun(ownerPid)) {
      return false;
    }

    final project = meta?['project']?.toString();
    if (project != null && project.isNotEmpty) {
      ownerPid = await _findScoutFlutterToolPid(
        project: project,
        instanceName: meta?['name']?.toString(),
      );
      if (ownerPid != null && await _looksLikeScoutFlutterRun(ownerPid)) {
        File(_pidFile).writeAsStringSync('$ownerPid');
        _writeSessionMeta({...?meta, 'pid': ownerPid});
        return false;
      }
    }

    final listenerPid = _readVmLogListenerPid();
    if (listenerPid != null &&
        await _looksLikeScoutVmLogListener(listenerPid)) {
      Process.killPid(listenerPid);
    }
    _deleteFileIfExists(_pidFile);
    _deleteFileIfExists(_vmLogListenerPidFile);

    final now = DateTime.now().toUtc().toIso8601String();
    final reconciled =
        <String, Object?>{
            ...?meta,
            'mode': 'attach_only',
            'state': 'ready',
            'previousMode': 'scout_owned_flutter_run',
            'ownershipLossReason': 'owner_process_exited',
            'ownershipLostAt': now,
            'vmServiceUri': vmUri,
            'updatedAt': now,
          }
          ..remove('pid')
          ..remove('vmLogListenerPid');
    _writeSessionMeta(reconciled);
    return true;
  }

  bool _sessionOwnershipWasLost() =>
      _readSessionMeta()?['ownershipLossReason'] == 'owner_process_exited';
}
