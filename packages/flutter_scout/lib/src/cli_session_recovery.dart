part of 'flutter_scout_cli.dart';

// part: safe selection and repair of existing named/owned sessions.

String _canonicalProjectDirectory(String project) {
  final absolute = p.normalize(p.absolute(project));
  try {
    return Directory(absolute).resolveSymbolicLinksSync();
  } catch (_) {
    return absolute;
  }
}

String _canonicalNamedSessionDirectory(String project, String name) => p.join(
  _canonicalProjectDirectory(project),
  '.flutter_scout',
  'sessions',
  _safeSessionName(name),
);

String _normalizeRegisteredSessionDirectory(String registered) {
  final absolute = p.normalize(p.absolute(registered));
  final sessionDirectory =
      p.basename(absolute) == '.flutter_scout' ||
          p.basename(p.dirname(absolute)) == 'sessions'
      ? absolute
      : p.join(absolute, '.flutter_scout');
  try {
    return Directory(sessionDirectory).resolveSymbolicLinksSync();
  } catch (_) {
    return sessionDirectory;
  }
}

bool _sameSessionDirectory(String first, String second) =>
    _normalizeRegisteredSessionDirectory(first) ==
    _normalizeRegisteredSessionDirectory(second);

Map<String, Object?>? _readNamedSessionMeta(String sessionDirectory) {
  final file = File(p.join(sessionDirectory, 'session_meta.json'));
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    return null;
  }
  try {
    if (file.statSync().size > 64 * 1024) return null;
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is Map
        ? <String, Object?>{
            for (final entry in decoded.entries)
              entry.key.toString(): entry.value,
          }
        : null;
  } catch (_) {
    return null;
  }
}

String? _projectFromNamedSession(String sessionDirectory) {
  final project = _readNamedSessionMeta(
    sessionDirectory,
  )?['project']?.toString();
  if (project != null && project.isNotEmpty) {
    return _canonicalProjectDirectory(project);
  }
  final parent = p.dirname(sessionDirectory);
  if (p.basename(parent) == 'sessions' &&
      p.basename(p.dirname(parent)) == '.flutter_scout') {
    return p.dirname(p.dirname(parent));
  }
  if (p.basename(sessionDirectory) == '.flutter_scout') {
    return p.dirname(sessionDirectory);
  }
  return null;
}

String? _storageRootFromNamedSession(String sessionDirectory) {
  final parent = p.dirname(sessionDirectory);
  if (p.basename(parent) == 'sessions' &&
      p.basename(p.dirname(parent)) == '.flutter_scout') {
    return p.dirname(p.dirname(parent));
  }
  if (p.basename(sessionDirectory) == '.flutter_scout') {
    return p.dirname(sessionDirectory);
  }
  return null;
}

String _namedSessionDiscoveryBoundary(String project) {
  var cursor = Directory(_canonicalProjectDirectory(project));
  while (true) {
    if (FileSystemEntity.typeSync(
          p.join(cursor.path, '.git'),
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound) {
      return cursor.path;
    }
    final parent = cursor.parent;
    if (parent.path == cursor.path) return cursor.path;
    cursor = parent;
  }
}

bool _directoryContainsNamedSession(String sessionDirectory) {
  for (final fileName in const <String>[
    'session_meta.json',
    'vm_uri.txt',
    'flutter.pid',
    'launch.lock',
  ]) {
    if (File(p.join(sessionDirectory, fileName)).existsSync()) return true;
  }
  return false;
}

List<String> _discoverNamedSessionDirectories(
  String name, {
  required Iterable<String> seedDirectories,
  String? project,
}) {
  final candidates = <String>{};
  final projects = <String>{
    if (project != null && project.isNotEmpty)
      _canonicalProjectDirectory(project),
  };
  for (final seed in seedDirectories) {
    final sessionDirectory = _normalizeRegisteredSessionDirectory(seed);
    if (_directoryContainsNamedSession(sessionDirectory)) {
      candidates.add(sessionDirectory);
    }
    final sessionProject = _projectFromNamedSession(sessionDirectory);
    if (sessionProject != null) projects.add(sessionProject);
  }

  final safeName = _safeSessionName(name);
  for (final sessionProject in projects) {
    final boundary = _namedSessionDiscoveryBoundary(sessionProject);
    var cursor = Directory(sessionProject);
    while (true) {
      final candidate = _normalizeRegisteredSessionDirectory(
        p.join(cursor.path, '.flutter_scout', 'sessions', safeName),
      );
      if (_directoryContainsNamedSession(candidate)) candidates.add(candidate);
      if (_canonicalProjectDirectory(cursor.path) == boundary) break;
      final parent = cursor.parent;
      if (parent.path == cursor.path) break;
      cursor = parent;
    }
  }
  return candidates.toList(growable: false)..sort();
}

Map<String, Object?> _namedSessionCandidateDetails(String directory) {
  final meta = _readNamedSessionMeta(directory);
  return <String, Object?>{
    'sessionDirectory': directory,
    'storageRoot': _storageRootFromNamedSession(directory),
    'projectRoot': meta?['project'] ?? _projectFromNamedSession(directory),
    'runId': meta?['runId'],
    'state': meta?['state'],
    'mode': meta?['mode'],
    'exists': Directory(directory).existsSync(),
  };
}

ScoutCliException _namedSessionAmbiguity(
  String name,
  Iterable<String> directories,
) {
  final candidates =
      directories
          .map(_normalizeRegisteredSessionDirectory)
          .toSet()
          .map(_namedSessionCandidateDetails)
          .toList(growable: false)
        ..sort(
          (first, second) => first['sessionDirectory'].toString().compareTo(
            second['sessionDirectory'].toString(),
          ),
        );
  return ScoutCliException(
    'session_selection_required',
    'Named Scout session `$name` is ambiguous across multiple project roots. '
        'Stop or clear the obsolete session explicitly before retrying; Scout '
        'will not choose one or start another build.',
    details: <String, Object?>{
      'reason': 'duplicate_named_session_roots',
      'name': name,
      'candidates': candidates,
      'recovery':
          'From the chosen candidate storageRoot, run '
          '`flutter-scout stop --clear-session`; then retry the named command.',
    },
  );
}

String _resolveRegisteredScoutSession(String name, String registered) {
  final normalized = _normalizeRegisteredSessionDirectory(registered);
  final candidates = _discoverNamedSessionDirectories(
    name,
    seedDirectories: <String>[normalized],
  );
  if (candidates.length > 1) {
    throw _namedSessionAmbiguity(name, candidates);
  }
  if (candidates.isNotEmpty) return candidates.single;
  // Preserve the original registry compatibility where a legacy value can
  // name the project directory and command routing appends `.flutter_scout`.
  final legacyProject = p.normalize(p.absolute(registered));
  return Directory(legacyProject).existsSync() ? legacyProject : normalized;
}

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
    if (ownerPid == null || !await _matchesOwnedFlutterRun(ownerPid, meta)) {
      final project = meta?['project']?.toString();
      if (project == null || project.isEmpty) return null;
      ownerPid = await _findScoutFlutterToolPid(
        project: project,
        instanceName: meta?['name']?.toString(),
      );
      if (ownerPid == null || !await _matchesOwnedFlutterRun(ownerPid, meta)) {
        return null;
      }
    }
    final discovered = _discoverVmUriFromScoutLog();
    if (discovered == null || discovered.isEmpty) return null;
    final uri = _normalizeVmUri(discovered);
    final validation = await _validateVmUri(uri);
    if (!validation.ok) return null;
    _writePrivateSessionString(_pidFile, '$ownerPid');
    _persistValidatedVmUri(uri);
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
    if (ownerPid != null && await _matchesOwnedFlutterRun(ownerPid, meta)) {
      return false;
    }

    final project = meta?['project']?.toString();
    if (project != null && project.isNotEmpty) {
      ownerPid = await _findScoutFlutterToolPid(
        project: project,
        instanceName: meta?['name']?.toString(),
      );
      if (ownerPid != null && await _matchesOwnedFlutterRun(ownerPid, meta)) {
        _writePrivateSessionString(_pidFile, '$ownerPid');
        _writeSessionMeta({...?meta, 'pid': ownerPid});
        return false;
      }
    }

    final listenerPid = _readVmLogListenerPid();
    if (listenerPid != null &&
        await _matchesOwnedVmLogListener(listenerPid, meta)) {
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
          ..remove('vmLogListenerPid')
          ..remove('vmLogListener')
          ..remove('processIdentity');
    _writeSessionMeta(reconciled);
    return true;
  }

  bool _sessionOwnershipWasLost() =>
      _readSessionMeta()?['ownershipLossReason'] == 'owner_process_exited';
}
