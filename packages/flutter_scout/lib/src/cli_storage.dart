part of 'flutter_scout_cli.dart';

// Private, crash-safe storage primitives shared by every CLI artifact sink.
//
// Scout artifacts routinely contain application text, screenshots, logs, and
// runtime identifiers.  A private parent directory is the first boundary; the
// per-file mode is defense in depth and also protects files moved elsewhere.

const int _privateDirectoryMode = 0x1c0; // 0700
const int _privateFileMode = 0x180; // 0600
const String _privateApplicationData = 'private_application_data';
const int _retentionRegistrySchemaVersion = 1;
const String _retentionRegistryKind =
    'flutter_scout_private_artifact_retention';
const int _maxRetentionRegistryBytes = 8 * 1024 * 1024;
const int _maxRetentionEntries = 4096;
const int _maxRetainedDirectoryEntries = 50000;
const int _retentionDigestChunkBytes = 64 * 1024;
const Duration _retentionInProcessLockTimeout = Duration(seconds: 30);
const Duration _retentionInProcessLockPoll = Duration(milliseconds: 2);

bool get _supportsPosixModes => !Platform.isWindows;

String _absoluteNormalized(String path) => p.normalize(p.absolute(path));

/// Resolves aliases in an output path's existing parent without ever
/// dereferencing the output object itself.
///
/// Dart may expose the same macOS temporary directory as both `/var/...` and
/// `/private/var/...`. Storage ownership checks must compare those as one
/// location, while a final-component symlink must remain visible to the
/// fail-closed file and directory validators below. For a not-yet-created
/// parent, only existing ancestors are resolved and the missing suffix is
/// appended lexically.
String _canonicalStorageTargetPath(String path) {
  final absolute = _absoluteNormalized(path);
  final basename = p.basename(absolute);
  var cursor = p.dirname(absolute);
  final missingParents = <String>[];
  while (FileSystemEntity.typeSync(cursor, followLinks: false) ==
      FileSystemEntityType.notFound) {
    final parent = p.dirname(cursor);
    if (parent == cursor) {
      _unsafeStoragePath(path, 'no existing output ancestor could be resolved');
    }
    missingParents.add(p.basename(cursor));
    cursor = parent;
  }
  final resolvedAncestor = switch (FileSystemEntity.typeSync(
    cursor,
    followLinks: false,
  )) {
    FileSystemEntityType.directory ||
    FileSystemEntityType.link => Directory(cursor).resolveSymbolicLinksSync(),
    _ => _unsafeStoragePath(
      path,
      'an existing output ancestor is not a directory',
    ),
  };
  if (FileSystemEntity.typeSync(resolvedAncestor, followLinks: false) !=
      FileSystemEntityType.directory) {
    _unsafeStoragePath(path, 'the resolved output ancestor is not a directory');
  }
  var resolvedParent = _absoluteNormalized(resolvedAncestor);
  for (final segment in missingParents.reversed) {
    resolvedParent = p.join(resolvedParent, segment);
  }
  return p.normalize(p.join(resolvedParent, basename));
}

String _canonicalSessionDirectory() =>
    _canonicalStorageTargetPath(_sessionDir.path);

Never _unsafeStoragePath(String path, String reason) {
  throw ScoutCliException(
    'unsafe_storage_path',
    'Refusing private artifact path `$path`: $reason.',
  );
}

void _enforcePrivateMode(String path, int mode) {
  if (!_supportsPosixModes) return;
  final current = FileStat.statSync(path).mode & 0x1ff;
  if (current == mode) return;
  final symbolic = mode == _privateDirectoryMode ? '700' : '600';
  final result = Process.runSync('chmod', <String>[symbolic, path]);
  if (result.exitCode != 0) {
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    throw ScoutCliException(
      'private_permissions_failed',
      'Could not set owner-only permissions on private Scout storage.',
    );
  }
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    return;
  }
  final applied = FileStat.statSync(path).mode & 0x1ff;
  if (applied != mode) {
    throw ScoutCliException(
      'private_permissions_failed',
      'Owner-only permissions were not applied to private Scout storage.',
    );
  }
}

List<String> _managedPathSegments(String boundary, String target) {
  final root = _absoluteNormalized(boundary);
  final value = _absoluteNormalized(target);
  if (value != root && !p.isWithin(root, value)) {
    _unsafeStoragePath(value, 'the path escapes its managed storage root');
  }
  final paths = <String>[root];
  if (value == root) return paths;
  var cursor = root;
  for (final segment in p.split(p.relative(value, from: root))) {
    cursor = p.join(cursor, segment);
    paths.add(cursor);
  }
  return paths;
}

void _assertNoManagedLinks(
  String boundary,
  String target, {
  bool finalMayBeFile = false,
  bool allowMissing = true,
}) {
  final paths = _managedPathSegments(boundary, target);
  for (var index = 0; index < paths.length; index++) {
    final path = paths[index];
    final isFinal = index == paths.length - 1;
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound && allowMissing) continue;
    if (type == FileSystemEntityType.link) {
      _unsafeStoragePath(path, 'symbolic links are not allowed');
    }
    final accepted = isFinal && finalMayBeFile
        ? type == FileSystemEntityType.file
        : type == FileSystemEntityType.directory;
    if (!accepted) {
      _unsafeStoragePath(path, 'an unexpected filesystem object is present');
    }
  }
}

Directory _ensurePrivateDirectory(
  String path, {
  required String boundary,
  bool secureExistingTree = false,
}) {
  final absolute = _absoluteNormalized(path);
  final root = _absoluteNormalized(boundary);
  _assertNoManagedLinks(root, absolute);
  Directory(absolute).createSync(recursive: true);
  _assertNoManagedLinks(root, absolute, allowMissing: false);
  for (final directoryPath in _managedPathSegments(root, absolute)) {
    _enforcePrivateMode(directoryPath, _privateDirectoryMode);
  }
  if (secureExistingTree) {
    final directory = Directory(absolute);
    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        // A concurrent atomic writer may have renamed its same-directory temp
        // entry after listSync observed it.
        continue;
      }
      if (type == FileSystemEntityType.link) {
        _unsafeStoragePath(entity.path, 'symbolic links are not allowed');
      }
      if (type == FileSystemEntityType.directory) {
        try {
          _enforcePrivateMode(entity.path, _privateDirectoryMode);
        } on FileSystemException {
          if (FileSystemEntity.typeSync(entity.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            rethrow;
          }
        }
      } else if (type == FileSystemEntityType.file) {
        try {
          _enforcePrivateMode(entity.path, _privateFileMode);
        } on FileSystemException {
          if (FileSystemEntity.typeSync(entity.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            rethrow;
          }
        }
      } else {
        _unsafeStoragePath(
          entity.path,
          'an unexpected filesystem object is present',
        );
      }
    }
  }
  return Directory(absolute);
}

void _deletePrivateDirectoryIfExists(String path, {required String boundary}) {
  final absolute = _absoluteNormalized(path);
  final root = _absoluteNormalized(boundary);
  _managedPathSegments(root, absolute);
  final type = FileSystemEntity.typeSync(absolute, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type != FileSystemEntityType.directory) {
    _unsafeStoragePath(absolute, 'the retained artifact is not a directory');
  }
  for (final entity in Directory(
    absolute,
  ).listSync(recursive: true, followLinks: false)) {
    if (FileSystemEntity.typeSync(entity.path, followLinks: false) ==
        FileSystemEntityType.link) {
      _unsafeStoragePath(
        entity.path,
        'symbolic links are not allowed during retention cleanup',
      );
    }
  }
  Directory(absolute).deleteSync(recursive: true);
}

void _assertPrivateFilePath(
  String path, {
  required String boundary,
  bool allowMissing = true,
}) {
  _assertNoManagedLinks(
    boundary,
    _absoluteNormalized(path),
    finalMayBeFile: true,
    allowMissing: allowMissing,
  );
}

void _securePrivateFile(String path, {required String boundary}) {
  _assertPrivateFilePath(path, boundary: boundary, allowMissing: false);
  _enforcePrivateMode(path, _privateFileMode);
}

void _atomicWritePrivateBytes(
  String path,
  List<int> bytes, {
  required String boundary,
}) {
  final target = _absoluteNormalized(path);
  final root = _absoluteNormalized(boundary);
  final parent = p.dirname(target);
  _ensurePrivateDirectory(parent, boundary: root);
  _assertPrivateFilePath(target, boundary: root);

  final random = Random.secure().nextInt(0x7fffffff);
  final temporaryPath = p.join(
    parent,
    '.${p.basename(target)}.$pid.'
    '${DateTime.now().microsecondsSinceEpoch}.$random.tmp',
  );
  _assertPrivateFilePath(temporaryPath, boundary: root);
  final temporary = File(temporaryPath);
  RandomAccessFile? handle;
  try {
    temporary.createSync(exclusive: true);
    _securePrivateFile(temporary.path, boundary: root);
    handle = temporary.openSync(mode: FileMode.write);
    handle.writeFromSync(bytes);
    handle.flushSync();
    handle.closeSync();
    handle = null;

    // Re-check immediately before the only operation that names the target.
    // The owner-only parent prevents an untrusted user racing this check.
    _assertPrivateFilePath(target, boundary: root);
    temporary.renameSync(target);
    _securePrivateFile(target, boundary: root);
  } catch (_) {
    try {
      handle?.closeSync();
    } catch (_) {}
    try {
      if (temporary.existsSync()) temporary.deleteSync();
    } catch (_) {}
    rethrow;
  }
}

void _atomicWritePrivateString(
  String path,
  String value, {
  required String boundary,
}) => _atomicWritePrivateBytes(path, utf8.encode(value), boundary: boundary);

/// Atomically writes an owner-only file selected by the caller without
/// chmodding or otherwise taking ownership of its parent directory.
///
/// Resolving an accepted existing parent pins the write to its canonical
/// directory even if an alias is later changed. The final component itself
/// must never be a symlink or non-regular filesystem object.
void _atomicWriteOwnerOnlyBytes(String path, List<int> bytes) {
  final requested = _absoluteNormalized(path);
  final requestedParent = Directory(p.dirname(requested));
  _preparePrivateArtifactOutputParent(requested);
  final resolvedParent = requestedParent.resolveSymbolicLinksSync();
  if (FileSystemEntity.typeSync(resolvedParent, followLinks: false) !=
      FileSystemEntityType.directory) {
    _unsafeStoragePath(requested, 'the output parent is not a directory');
  }
  final target = p.join(resolvedParent, p.basename(requested));
  final initialType = FileSystemEntity.typeSync(target, followLinks: false);
  if (initialType != FileSystemEntityType.notFound &&
      initialType != FileSystemEntityType.file) {
    _unsafeStoragePath(requested, 'the output is not a regular file');
  }

  final random = Random.secure().nextInt(0x7fffffff);
  final temporary = File(
    p.join(
      resolvedParent,
      '.${p.basename(target)}.$pid.'
      '${DateTime.now().microsecondsSinceEpoch}.$random.tmp',
    ),
  );
  RandomAccessFile? handle;
  try {
    temporary.createSync(exclusive: true);
    _enforcePrivateMode(temporary.path, _privateFileMode);
    handle = temporary.openSync(mode: FileMode.write);
    handle.writeFromSync(bytes);
    handle.flushSync();
    handle.closeSync();
    handle = null;

    final finalType = FileSystemEntity.typeSync(target, followLinks: false);
    if (finalType != FileSystemEntityType.notFound &&
        finalType != FileSystemEntityType.file) {
      _unsafeStoragePath(requested, 'the output became a non-regular file');
    }
    temporary.renameSync(target);
    if (FileSystemEntity.typeSync(target, followLinks: false) !=
        FileSystemEntityType.file) {
      _unsafeStoragePath(requested, 'the completed output is not regular');
    }
    _enforcePrivateMode(target, _privateFileMode);
  } catch (_) {
    try {
      handle?.closeSync();
    } catch (_) {}
    try {
      if (temporary.existsSync()) temporary.deleteSync();
    } catch (_) {}
    rethrow;
  }
}

void _atomicWriteOwnerOnlyString(String path, String value) =>
    _atomicWriteOwnerOnlyBytes(path, utf8.encode(value));

/// Prepares only the immediate output parent without taking ownership of a
/// caller's existing directory. A missing leaf is created through a randomized
/// owner-only directory and atomically renamed; missing ancestors are refused.
void _preparePrivateArtifactOutputParent(String outputPath) {
  final output = _absoluteNormalized(outputPath);
  final parentPath = p.dirname(output);
  final parentType = FileSystemEntity.typeSync(parentPath, followLinks: false);
  if (parentType == FileSystemEntityType.directory) return;
  if (parentType != FileSystemEntityType.notFound) {
    _unsafeStoragePath(output, 'the output parent is a link or non-directory');
  }
  final grandparentPath = p.dirname(parentPath);
  if (grandparentPath == parentPath ||
      FileSystemEntity.typeSync(grandparentPath, followLinks: false) !=
          FileSystemEntityType.directory) {
    _unsafeStoragePath(
      output,
      'only one missing output-directory leaf may be created',
    );
  }
  final temporary = Directory(
    grandparentPath,
  ).createTempSync('.${p.basename(parentPath)}.flutter_scout_output.');
  var temporaryExists = true;
  try {
    _enforcePrivateMode(temporary.path, _privateDirectoryMode);
    try {
      temporary.renameSync(parentPath);
      temporaryExists = false;
    } on FileSystemException {
      // A concurrent caller may have created the requested leaf. It remains
      // caller-owned and must not be chmodded by Scout.
      if (FileSystemEntity.typeSync(parentPath, followLinks: false) !=
          FileSystemEntityType.directory) {
        rethrow;
      }
    }
  } finally {
    if (temporaryExists && temporary.existsSync()) {
      temporary.deleteSync();
    }
  }
}

void _atomicWritePrivateJson(
  String path,
  Object? value, {
  required String boundary,
}) => _atomicWritePrivateString(
  path,
  const JsonEncoder.withIndent('  ').convert(value),
  boundary: boundary,
);

T _withPrivateFileLock<T>(
  String lockPath, {
  required String boundary,
  required T Function() body,
}) {
  final root = _absoluteNormalized(boundary);
  final path = _absoluteNormalized(lockPath);
  _ensurePrivateDirectory(p.dirname(path), boundary: root);
  _assertPrivateFilePath(path, boundary: root);
  final file = File(path);
  if (!file.existsSync()) {
    try {
      file.createSync(exclusive: true);
    } on FileSystemException {
      // A concurrent writer may have won creation. Validate its object below.
    }
  }
  _securePrivateFile(path, boundary: root);
  final handle = file.openSync(mode: FileMode.append);
  // `exclusive` is deliberately non-blocking in dart:io and drops concurrent
  // writers with EWOULDBLOCK. The blocking kernel lock queues cooperative
  // processes and is released automatically if a writer crashes.
  handle.lockSync(FileLock.blockingExclusive);
  try {
    return body();
  } finally {
    try {
      handle.unlockSync();
    } finally {
      handle.closeSync();
    }
  }
}

RandomAccessFile _openPrivateAppendFile(String path) {
  final absolute = _absoluteNormalized(path);
  final session = _absoluteNormalized(_sessionDir.path);
  final boundary = absolute == session || p.isWithin(session, absolute)
      ? session
      : p.dirname(absolute);
  if (boundary == session) _ensureSessionDir();
  _ensurePrivateDirectory(p.dirname(absolute), boundary: boundary);
  _assertPrivateFilePath(absolute, boundary: boundary);
  final file = File(absolute);
  if (!file.existsSync()) {
    try {
      file.createSync(exclusive: true);
    } on FileSystemException {
      // A cooperative concurrent writer may have created it.
    }
  }
  _securePrivateFile(absolute, boundary: boundary);
  return file.openSync(mode: FileMode.append);
}

String _sessionManagedBoundary() {
  final absolute = _absoluteNormalized(_sessionDir.path);
  final segments = p.split(absolute);
  final index = segments.lastIndexOf('.flutter_scout');
  if (index < 0) return absolute;
  return p.joinAll(segments.take(index + 1));
}

void _writePrivateSessionString(String path, String value) {
  _ensureSessionDir();
  _atomicWritePrivateString(path, value, boundary: _sessionDir.path);
}

void _writePrivateSessionJson(String path, Object? value) {
  _ensureSessionDir();
  _atomicWritePrivateJson(path, value, boundary: _sessionDir.path);
}

void _writePrivateArtifactBytes(String path, List<int> value) {
  // If a registry already exists, validate it before committing another
  // private artifact. A malformed/torn registry must never be silently
  // replaced by the later metadata commit.
  _assertRetentionRegistryHealthyForWrite();
  _assertOutsideRetentionControlStorage(path);
  final absolute = _canonicalStorageTargetPath(path);
  final session = _canonicalSessionDirectory();
  if (absolute == session || p.isWithin(session, absolute)) {
    _ensureSessionDir();
    _atomicWritePrivateBytes(absolute, value, boundary: session);
  } else {
    _atomicWriteOwnerOnlyBytes(path, value);
  }
}

Map<String, Object?> _privateArtifactMetadata(
  String retentionPolicy, {
  DateTime? createdAt,
}) {
  const allowed = <String>{'session', '24h', '7d', 'manual'};
  if (!allowed.contains(retentionPolicy)) {
    throw ScoutCliException(
      'invalid_retention_policy',
      'Retention must be one of: session, 24h, 7d, manual.',
    );
  }
  final created = (createdAt ?? DateTime.now().toUtc()).toUtc();
  final expiresAt = switch (retentionPolicy) {
    '24h' => created.add(const Duration(hours: 24)),
    '7d' => created.add(const Duration(days: 7)),
    _ => null,
  };
  return <String, Object?>{
    'dataClassification': _privateApplicationData,
    'containsPrivateApplicationData': true,
    'retentionPolicy': <String, Object?>{
      'policy': retentionPolicy,
      'createdAt': created.toIso8601String(),
      if (expiresAt != null) 'expiresAt': expiresAt.toIso8601String(),
      'disposition': switch (retentionPolicy) {
        'session' => 'delete_on_session_clear',
        '24h' || '7d' => 'delete_after_expiry',
        _ => 'explicit_manual_deletion',
      },
    },
    'telemetryCollected': false,
  };
}

String _retentionOption(ArgResults parsed) =>
    parsed.option('retention')?.trim().toLowerCase() ?? 'session';

void _writePrivateArtifactMetadata(
  String artifactPath,
  String retentionPolicy, {
  String? metadataPath,
  DateTime? createdAt,
  bool registerForRetention = true,
}) {
  final path = metadataPath ?? '$artifactPath.metadata.json';
  _assertOutsideRetentionControlStorage(artifactPath);
  _assertOutsideRetentionControlStorage(path);
  final metadata = <String, Object?>{
    'schemaVersion': 1,
    'artifact': _canonicalStorageTargetPath(artifactPath),
    ..._privateArtifactMetadata(retentionPolicy, createdAt: createdAt),
  };
  final absolute = _canonicalStorageTargetPath(path);
  final session = _canonicalSessionDirectory();
  final encoded = const JsonEncoder.withIndent('  ').convert(metadata);
  if (absolute == session || p.isWithin(session, absolute)) {
    _atomicWritePrivateString(absolute, encoded, boundary: session);
  } else {
    _atomicWriteOwnerOnlyString(path, encoded);
  }
  if (registerForRetention) {
    _registerPrivateArtifact(
      artifactPath,
      metadataPath: path,
      retentionPolicy: retentionPolicy,
      createdAt: createdAt,
    );
  }
}

String get _retentionDirectory => p.join(_sessionDir.path, 'retention');
String get _retentionRegistryPath =>
    p.join(_retentionDirectory, 'registry.v1.json');
String get _retentionRegistryLockPath => '$_retentionRegistryPath.lock';
String get _retentionInProcessGuardPath =>
    '$_retentionRegistryLockPath.in_process_guard';

void _assertOutsideRetentionControlStorage(String path) {
  final target = _canonicalStorageTargetPath(path);
  final controls = _canonicalStorageTargetPath(_retentionDirectory);
  if (target == controls ||
      p.isWithin(controls, target) ||
      p.isWithin(target, controls)) {
    throw const ScoutCliException(
      'unsafe_retention_target',
      'A retained artifact cannot overlap Scout retention control storage.',
    );
  }
}

Never _invalidRetentionRegistry([String? reason]) {
  throw ScoutCliException(
    'retention_registry_invalid',
    'The private-artifact retention registry is invalid. No registered '
        'artifact was deleted and the registry was not replaced.',
    details: <String, Object?>{
      'cleanup': 'not_performed',
      'registryPreserved': true,
      'reason': ?reason,
    },
  );
}

String _canonicalJson(Object? value) {
  if (value == null || value is bool || value is String) {
    return jsonEncode(value);
  }
  if (value is num) {
    if (!value.isFinite) _invalidRetentionRegistry('non_finite_number');
    return jsonEncode(value);
  }
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  if (value is Map) {
    final keys = <String>[];
    for (final key in value.keys) {
      if (key is! String) _invalidRetentionRegistry('non_string_key');
      keys.add(key);
    }
    keys.sort();
    return '{${[for (final key in keys) '${jsonEncode(key)}:${_canonicalJson(value[key])}'].join(',')}}';
  }
  _invalidRetentionRegistry('unsupported_json_value');
}

String _canonicalDigest(Object? value) =>
    crypto.sha256.convert(utf8.encode(_canonicalJson(value))).toString();

Map<String, Object?> _strictStringMap(Object? value, String reason) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    _invalidRetentionRegistry(reason);
  }
  return <String, Object?>{
    for (final entry in value.entries) (entry.key as String): entry.value,
  };
}

void _requireExactKeys(
  Map<String, Object?> value,
  Set<String> required, {
  Set<String> optional = const <String>{},
  required String reason,
}) {
  if (!value.keys.toSet().containsAll(required) ||
      value.keys.any(
        (key) => !required.contains(key) && !optional.contains(key),
      )) {
    _invalidRetentionRegistry(reason);
  }
}

bool _isNormalizedAbsolutePath(String value) =>
    value.isNotEmpty &&
    !value.contains('\u0000') &&
    p.isAbsolute(value) &&
    _absoluteNormalized(value) == value;

bool _isSha256(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

DateTime _strictRetentionTimestamp(Object? value, String reason) {
  if (value is! String) _invalidRetentionRegistry(reason);
  final parsed = DateTime.tryParse(value);
  if (parsed == null || !parsed.isUtc || parsed.toIso8601String() != value) {
    _invalidRetentionRegistry(reason);
  }
  return parsed;
}

void _validateStoredFileIdentity(
  Map<String, Object?> identity, {
  required String reason,
}) {
  _requireExactKeys(identity, const <String>{
    'kind',
    'canonicalPath',
    'size',
    'modifiedMicros',
    'changedMicros',
    'mode',
    'sha256',
  }, reason: reason);
  if (identity['kind'] != 'file' ||
      identity['canonicalPath'] is! String ||
      !_isNormalizedAbsolutePath(identity['canonicalPath']! as String) ||
      identity['size'] is! int ||
      (identity['size']! as int) < 0 ||
      identity['modifiedMicros'] is! int ||
      identity['changedMicros'] is! int ||
      identity['mode'] is! int ||
      (identity['mode']! as int) < 0 ||
      (identity['mode']! as int) > 0x1ff ||
      !_isSha256(identity['sha256'])) {
    _invalidRetentionRegistry(reason);
  }
}

void _validateStoredDirectoryIdentity(
  Map<String, Object?> identity, {
  required String reason,
}) {
  _requireExactKeys(identity, const <String>{
    'kind',
    'canonicalPath',
    'mode',
    'modifiedMicros',
    'changedMicros',
    'entryCount',
    'entries',
    'treeSha256',
  }, reason: reason);
  final entries = identity['entries'];
  if (identity['kind'] != 'directory' ||
      identity['canonicalPath'] is! String ||
      !_isNormalizedAbsolutePath(identity['canonicalPath']! as String) ||
      identity['mode'] is! int ||
      (identity['mode']! as int) < 0 ||
      (identity['mode']! as int) > 0x1ff ||
      identity['modifiedMicros'] is! int ||
      identity['changedMicros'] is! int ||
      identity['entryCount'] is! int ||
      entries is! List ||
      entries.length != identity['entryCount'] ||
      entries.length > _maxRetainedDirectoryEntries ||
      !_isSha256(identity['treeSha256']) ||
      identity['treeSha256'] != _canonicalDigest(entries)) {
    _invalidRetentionRegistry(reason);
  }
  String? previousPath;
  for (final rawEntry in entries) {
    final entry = _strictStringMap(rawEntry, reason);
    final kind = entry['kind'];
    final expected = kind == 'file'
        ? const <String>{
            'path',
            'kind',
            'canonicalPath',
            'mode',
            'modifiedMicros',
            'changedMicros',
            'size',
            'sha256',
          }
        : const <String>{
            'path',
            'kind',
            'canonicalPath',
            'mode',
            'modifiedMicros',
            'changedMicros',
          };
    _requireExactKeys(entry, expected, reason: reason);
    final relative = entry['path'];
    if (relative is! String ||
        relative.isEmpty ||
        p.isAbsolute(relative) ||
        p.normalize(relative) != relative ||
        relative == '.' ||
        relative == '..' ||
        relative.startsWith('../') ||
        relative.contains('\u0000') ||
        (kind != 'file' && kind != 'directory') ||
        entry['canonicalPath'] is! String ||
        !_isNormalizedAbsolutePath(entry['canonicalPath']! as String) ||
        entry['mode'] is! int ||
        entry['modifiedMicros'] is! int ||
        entry['changedMicros'] is! int ||
        (previousPath != null && previousPath.compareTo(relative) >= 0)) {
      _invalidRetentionRegistry(reason);
    }
    if (kind == 'file' &&
        (entry['size'] is! int ||
            (entry['size']! as int) < 0 ||
            !_isSha256(entry['sha256']))) {
      _invalidRetentionRegistry(reason);
    }
    previousPath = relative;
  }
  final canonicalPaths = <String>{};
  final portableRelativePaths = <String>{};
  for (final rawEntry in entries) {
    final entry = rawEntry as Map;
    final canonical = entry['canonicalPath']! as String;
    final relative = entry['path']! as String;
    final canonicalKey = (Platform.isMacOS || Platform.isWindows)
        ? canonical.toLowerCase()
        : canonical;
    // Reject Linux-only case variants too: the deletion proof must not become
    // ambiguous if an archive moves to a case-insensitive host.
    if (!canonicalPaths.add(canonicalKey) ||
        !portableRelativePaths.add(relative.toLowerCase())) {
      _invalidRetentionRegistry(reason);
    }
  }
}

void _validateStoredIdentity(Object? rawIdentity, {required String reason}) {
  final identity = _strictStringMap(rawIdentity, reason);
  switch (identity['kind']) {
    case 'file':
      _validateStoredFileIdentity(identity, reason: reason);
    case 'directory':
      _validateStoredDirectoryIdentity(identity, reason: reason);
    default:
      _invalidRetentionRegistry(reason);
  }
}

Map<String, Object?> _validateRetentionEntry(Object? rawEntry) {
  final entry = _strictStringMap(rawEntry, 'invalid_entry');
  _requireExactKeys(entry, const <String>{
    'schemaVersion',
    'artifactId',
    'artifactPath',
    'artifactBoundary',
    'artifactIdentity',
    'metadataPath',
    'metadataCoveredByArtifact',
    'metadataIdentity',
    'policy',
    'createdAt',
    'expiresAt',
    'sessionDirectory',
    'sessionId',
    'runId',
  }, reason: 'invalid_entry_fields');
  final artifactPath = entry['artifactPath'];
  final boundary = entry['artifactBoundary'];
  final metadataPath = entry['metadataPath'];
  final sessionDirectory = entry['sessionDirectory'];
  final policy = entry['policy'];
  final createdAt = _strictRetentionTimestamp(
    entry['createdAt'],
    'invalid_created_at',
  );
  if (entry['schemaVersion'] != 1 ||
      !_isSha256(entry['artifactId']) ||
      artifactPath is! String ||
      !_isNormalizedAbsolutePath(artifactPath) ||
      boundary is! String ||
      !_isNormalizedAbsolutePath(boundary) ||
      metadataPath is! String ||
      !_isNormalizedAbsolutePath(metadataPath) ||
      sessionDirectory is! String ||
      sessionDirectory != _canonicalSessionDirectory() ||
      !_isSha256(entry['sessionId']) ||
      entry['sessionId'] != _canonicalDigest(sessionDirectory) ||
      (entry['runId'] != null && entry['runId'] is! String) ||
      entry['metadataCoveredByArtifact'] is! bool ||
      !const <String>{'session', '24h', '7d', 'manual'}.contains(policy)) {
    _invalidRetentionRegistry('invalid_entry_value');
  }
  if (artifactPath != boundary && !p.isWithin(boundary, artifactPath)) {
    _invalidRetentionRegistry('artifact_escapes_boundary');
  }
  final sessionRoot = _canonicalSessionDirectory();
  if (artifactPath == sessionRoot || p.isWithin(artifactPath, sessionRoot)) {
    _invalidRetentionRegistry('artifact_contains_registry');
  }
  try {
    _assertOutsideRetentionControlStorage(artifactPath);
    _assertOutsideRetentionControlStorage(metadataPath);
  } on ScoutCliException {
    _invalidRetentionRegistry('artifact_overlaps_retention_controls');
  }
  final expectedId = _canonicalDigest(<String, Object?>{
    'sessionDirectory': sessionDirectory,
    'artifactPath': artifactPath,
  });
  if (entry['artifactId'] != expectedId) {
    _invalidRetentionRegistry('artifact_id_mismatch');
  }
  _validateStoredIdentity(
    entry['artifactIdentity'],
    reason: 'invalid_artifact_identity',
  );
  final covered = entry['metadataCoveredByArtifact']! as bool;
  if (covered) {
    if (entry['metadataIdentity'] != null ||
        !p.isWithin(artifactPath, metadataPath)) {
      _invalidRetentionRegistry('invalid_covered_metadata');
    }
  } else {
    _validateStoredIdentity(
      entry['metadataIdentity'],
      reason: 'invalid_metadata_identity',
    );
  }
  final expiresAtRaw = entry['expiresAt'];
  switch (policy) {
    case '24h':
      final expiresAt = _strictRetentionTimestamp(
        expiresAtRaw,
        'invalid_expires_at',
      );
      if (expiresAt != createdAt.add(const Duration(hours: 24))) {
        _invalidRetentionRegistry('expiry_policy_mismatch');
      }
    case '7d':
      final expiresAt = _strictRetentionTimestamp(
        expiresAtRaw,
        'invalid_expires_at',
      );
      if (expiresAt != createdAt.add(const Duration(days: 7))) {
        _invalidRetentionRegistry('expiry_policy_mismatch');
      }
    default:
      if (expiresAtRaw != null) {
        _invalidRetentionRegistry('unexpected_expiry');
      }
  }
  return entry;
}

final class _RetentionRegistryState {
  const _RetentionRegistryState({required this.exists, required this.entries});

  final bool exists;
  final List<Map<String, Object?>> entries;
}

_RetentionRegistryState _readRetentionRegistryUnlocked() {
  final path = _absoluteNormalized(_retentionRegistryPath);
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    return const _RetentionRegistryState(exists: false, entries: []);
  }
  if (type != FileSystemEntityType.file) {
    _invalidRetentionRegistry('registry_not_regular');
  }
  _assertPrivateFilePath(path, boundary: _sessionDir.path, allowMissing: false);
  _securePrivateFile(path, boundary: _sessionDir.path);
  final file = File(path);
  final length = file.lengthSync();
  if (length <= 0 || length > _maxRetentionRegistryBytes) {
    _invalidRetentionRegistry('registry_size_invalid');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } catch (_) {
    _invalidRetentionRegistry('registry_json_invalid');
  }
  final envelope = _strictStringMap(decoded, 'registry_envelope_invalid');
  _requireExactKeys(envelope, const <String>{
    'schemaVersion',
    'registryKind',
    'sessionDirectory',
    'entries',
    'payloadSha256',
  }, reason: 'registry_envelope_fields_invalid');
  final entriesRaw = envelope['entries'];
  if (envelope['schemaVersion'] != _retentionRegistrySchemaVersion ||
      envelope['registryKind'] != _retentionRegistryKind ||
      envelope['sessionDirectory'] != _canonicalSessionDirectory() ||
      entriesRaw is! List ||
      entriesRaw.length > _maxRetentionEntries ||
      !_isSha256(envelope['payloadSha256'])) {
    _invalidRetentionRegistry('registry_envelope_value_invalid');
  }
  final payload = <String, Object?>{
    'schemaVersion': envelope['schemaVersion'],
    'registryKind': envelope['registryKind'],
    'sessionDirectory': envelope['sessionDirectory'],
    'entries': entriesRaw,
  };
  if (envelope['payloadSha256'] != _canonicalDigest(payload)) {
    _invalidRetentionRegistry('registry_digest_mismatch');
  }
  final entries = <Map<String, Object?>>[];
  final artifactIds = <String>{};
  final artifactPaths = <String>{};
  for (final rawEntry in entriesRaw) {
    final entry = _validateRetentionEntry(rawEntry);
    if (!artifactIds.add(entry['artifactId']! as String) ||
        !artifactPaths.add(entry['artifactPath']! as String)) {
      _invalidRetentionRegistry('duplicate_artifact_entry');
    }
    entries.add(entry);
  }
  final sorted = List<Map<String, Object?>>.from(entries)
    ..sort(
      (left, right) => (left['artifactId']! as String).compareTo(
        right['artifactId']! as String,
      ),
    );
  if (_canonicalJson(sorted) != _canonicalJson(entriesRaw)) {
    _invalidRetentionRegistry('registry_entries_not_canonical');
  }
  return _RetentionRegistryState(exists: true, entries: sorted);
}

void _writeRetentionRegistryUnlocked(List<Map<String, Object?>> entries) {
  if (entries.length > _maxRetentionEntries) {
    throw const ScoutCliException(
      'retention_registry_full',
      'The private-artifact retention registry reached its bounded capacity.',
    );
  }
  final sorted = List<Map<String, Object?>>.from(entries)
    ..sort(
      (left, right) => (left['artifactId']! as String).compareTo(
        right['artifactId']! as String,
      ),
    );
  final payload = <String, Object?>{
    'schemaVersion': _retentionRegistrySchemaVersion,
    'registryKind': _retentionRegistryKind,
    'sessionDirectory': _canonicalSessionDirectory(),
    'entries': sorted,
  };
  final envelope = <String, Object?>{
    ...payload,
    'payloadSha256': _canonicalDigest(payload),
  };
  final encoded = const JsonEncoder.withIndent('  ').convert(envelope);
  if (utf8.encode(encoded).length > _maxRetentionRegistryBytes) {
    throw const ScoutCliException(
      'retention_registry_full',
      'The private-artifact retention registry exceeded its bounded size.',
    );
  }
  _atomicWritePrivateString(
    _retentionRegistryPath,
    encoded,
    boundary: _sessionDir.path,
  );
}

T _withRetentionRegistryLock<T>(
  T Function() body, {
  bool secureExistingSessionTree = true,
}) {
  final registryType = FileSystemEntity.typeSync(
    _retentionRegistryPath,
    followLinks: false,
  );
  if (registryType != FileSystemEntityType.notFound &&
      registryType != FileSystemEntityType.file) {
    _invalidRetentionRegistry('registry_not_regular');
  }
  if (secureExistingSessionTree) {
    _ensureSessionDir();
  } else {
    // Cleanup must be able to stop first and then report an unrelated unsafe
    // descendant. Validate only the managed path to the session root here;
    // the exact retention directory/lock path is validated immediately below.
    _ensurePrivateDirectory(
      _sessionDir.path,
      boundary: _sessionManagedBoundary(),
    );
  }
  _ensurePrivateDirectory(_retentionDirectory, boundary: _sessionDir.path);
  return _withPrivateFileLock<T>(
    _retentionRegistryLockPath,
    boundary: _sessionDir.path,
    // POSIX advisory file locks may be process-scoped. The exclusive-create
    // guard closes that gap for isolates in one long-lived Scout process,
    // while the kernel lock still serializes processes and releases on crash.
    body: () => _withRetentionInProcessGuard(body),
  );
}

T _withRetentionInProcessGuard<T>(T Function() body) {
  final path = _absoluteNormalized(_retentionInProcessGuardPath);
  final deadline = DateTime.now().add(_retentionInProcessLockTimeout);
  final token =
      '$pid:${DateTime.now().microsecondsSinceEpoch}:'
      '${Random.secure().nextInt(0x7fffffff)}';
  final guard = File(path);
  while (true) {
    _assertPrivateFilePath(path, boundary: _sessionDir.path);
    try {
      guard.createSync(exclusive: true);
      _securePrivateFile(path, boundary: _sessionDir.path);
      final handle = guard.openSync(mode: FileMode.write);
      try {
        handle.writeStringSync(token);
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
      break;
    } on FileSystemException {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        if (!DateTime.now().isBefore(deadline)) {
          throw const ScoutCliException(
            'retention_registry_lock_timeout',
            'Timed out waiting for another retention registry writer. The '
                'registry and artifacts were preserved.',
          );
        }
        sleep(_retentionInProcessLockPoll);
        continue;
      }
      if (type != FileSystemEntityType.file) {
        throw const ScoutCliException(
          'retention_registry_lock_invalid',
          'The retention registry lock guard is not a regular file.',
        );
      }
      if (!DateTime.now().isBefore(deadline)) {
        throw const ScoutCliException(
          'retention_registry_lock_timeout',
          'Timed out waiting for another retention registry writer. The '
              'registry and artifacts were preserved.',
        );
      }
      sleep(_retentionInProcessLockPoll);
    }
  }
  try {
    return body();
  } finally {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw const ScoutCliException(
        'retention_registry_lock_invalid',
        'The retention registry lock guard changed while held.',
      );
    }
    String? committedToken;
    try {
      committedToken = guard.readAsStringSync();
    } catch (_) {}
    if (committedToken != token) {
      throw const ScoutCliException(
        'retention_registry_lock_invalid',
        'The retention registry lock guard identity changed while held.',
      );
    }
    guard.deleteSync();
  }
}

void _assertRetentionRegistryHealthyForWrite() {
  final retentionType = FileSystemEntity.typeSync(
    _retentionDirectory,
    followLinks: false,
  );
  if (retentionType == FileSystemEntityType.notFound) return;
  if (retentionType != FileSystemEntityType.directory) {
    _invalidRetentionRegistry('retention_directory_not_regular');
  }
  final registryType = FileSystemEntity.typeSync(
    _retentionRegistryPath,
    followLinks: false,
  );
  if (registryType == FileSystemEntityType.notFound) return;
  if (registryType != FileSystemEntityType.file) {
    _invalidRetentionRegistry('registry_not_regular');
  }
  _withRetentionRegistryLock<void>(() {
    _readRetentionRegistryUnlocked();
  });
}

final class _DigestCollector implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) {
    if (value != null) {
      throw StateError('A hash conversion produced more than one digest.');
    }
    value = data;
  }

  @override
  void close() {}
}

String _sha256FileSync(String path) {
  final output = _DigestCollector();
  final input = crypto.sha256.startChunkedConversion(output);
  final file = File(path).openSync(mode: FileMode.read);
  try {
    while (true) {
      final chunk = file.readSync(_retentionDigestChunkBytes);
      if (chunk.isEmpty) break;
      input.add(chunk);
    }
  } finally {
    file.closeSync();
  }
  input.close();
  final digest = output.value;
  if (digest == null) {
    throw StateError('A file hash conversion produced no digest.');
  }
  return digest.toString();
}

bool _sameFileStat(FileStat left, FileStat right) =>
    left.type == right.type &&
    left.size == right.size &&
    left.mode == right.mode &&
    left.modified == right.modified &&
    left.changed == right.changed;

Map<String, Object?> _captureRegularFileIdentity(String path) {
  final absolute = _absoluteNormalized(path);
  if (FileSystemEntity.typeSync(absolute, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const ScoutCliException(
      'retention_identity_unavailable',
      'A retained artifact is not a stable regular file.',
    );
  }
  final before = FileStat.statSync(absolute);
  final canonical = File(absolute).resolveSymbolicLinksSync();
  final digest = _sha256FileSync(absolute);
  final afterType = FileSystemEntity.typeSync(absolute, followLinks: false);
  final after = FileStat.statSync(absolute);
  if (afterType != FileSystemEntityType.file ||
      !_sameFileStat(before, after) ||
      File(absolute).resolveSymbolicLinksSync() != canonical) {
    throw const ScoutCliException(
      'retention_identity_unavailable',
      'A retained artifact changed while its identity was captured.',
    );
  }
  return <String, Object?>{
    'kind': 'file',
    'canonicalPath': _absoluteNormalized(canonical),
    'size': after.size,
    'modifiedMicros': after.modified.microsecondsSinceEpoch,
    'changedMicros': after.changed.microsecondsSinceEpoch,
    'mode': after.mode & 0x1ff,
    'sha256': digest,
  };
}

Map<String, Object?> _captureDirectoryIdentity(String path) {
  final absolute = _absoluteNormalized(path);
  if (FileSystemEntity.typeSync(absolute, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const ScoutCliException(
      'retention_identity_unavailable',
      'A retained artifact is not a stable directory.',
    );
  }
  final canonical = Directory(absolute).resolveSymbolicLinksSync();
  final rootBefore = FileStat.statSync(absolute);
  final initialDirectoryStats = <String, FileStat>{absolute: rootBefore};
  final pending = <String>[absolute];
  final entries = <Map<String, Object?>>[];
  final canonicalRoot = _absoluteNormalized(canonical);
  final canonicalPaths = <String>{canonicalRoot};
  final portableRelativePaths = <String>{};
  while (pending.isNotEmpty) {
    final directoryPath = pending.removeLast();
    final children = Directory(directoryPath).listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in children) {
      if (entries.length >= _maxRetainedDirectoryEntries) {
        throw const ScoutCliException(
          'retention_identity_too_large',
          'A retained directory exceeded the bounded identity manifest.',
        );
      }
      final entityPath = _absoluteNormalized(entity.path);
      final type = FileSystemEntity.typeSync(entityPath, followLinks: false);
      final relative = p.relative(entityPath, from: absolute);
      final entityCanonical = switch (type) {
        FileSystemEntityType.directory => Directory(
          entityPath,
        ).resolveSymbolicLinksSync(),
        FileSystemEntityType.file => File(
          entityPath,
        ).resolveSymbolicLinksSync(),
        _ => '',
      };
      final normalizedCanonical = entityCanonical.isEmpty
          ? ''
          : _absoluteNormalized(entityCanonical);
      final canonicalKey = (Platform.isMacOS || Platform.isWindows)
          ? normalizedCanonical.toLowerCase()
          : normalizedCanonical;
      if (normalizedCanonical.isEmpty ||
          !p.isWithin(canonicalRoot, normalizedCanonical) ||
          !canonicalPaths.add(canonicalKey) ||
          !portableRelativePaths.add(relative.toLowerCase())) {
        throw const ScoutCliException(
          'retention_identity_unavailable',
          'A retained directory contains a canonical or case-colliding path.',
        );
      }
      if (type == FileSystemEntityType.directory) {
        final stat = FileStat.statSync(entityPath);
        initialDirectoryStats[entityPath] = stat;
        entries.add(<String, Object?>{
          'path': relative,
          'kind': 'directory',
          'canonicalPath': normalizedCanonical,
          'mode': stat.mode & 0x1ff,
          'modifiedMicros': stat.modified.microsecondsSinceEpoch,
          'changedMicros': stat.changed.microsecondsSinceEpoch,
        });
        pending.add(entityPath);
      } else if (type == FileSystemEntityType.file) {
        final identity = _captureRegularFileIdentity(entityPath);
        entries.add(<String, Object?>{
          'path': relative,
          'kind': 'file',
          'canonicalPath': identity['canonicalPath'],
          'mode': identity['mode'],
          'modifiedMicros': identity['modifiedMicros'],
          'changedMicros': identity['changedMicros'],
          'size': identity['size'],
          'sha256': identity['sha256'],
        });
      } else {
        throw const ScoutCliException(
          'retention_identity_unavailable',
          'A retained directory contains a symbolic link or non-regular object.',
        );
      }
    }
  }
  for (final item in initialDirectoryStats.entries) {
    if (FileSystemEntity.typeSync(item.key, followLinks: false) !=
            FileSystemEntityType.directory ||
        !_sameFileStat(item.value, FileStat.statSync(item.key))) {
      throw const ScoutCliException(
        'retention_identity_unavailable',
        'A retained directory changed while its identity was captured.',
      );
    }
  }
  if (Directory(absolute).resolveSymbolicLinksSync() != canonical) {
    throw const ScoutCliException(
      'retention_identity_unavailable',
      'A retained directory boundary changed while its identity was captured.',
    );
  }
  entries.sort(
    (left, right) =>
        (left['path']! as String).compareTo(right['path']! as String),
  );
  final rootAfter = FileStat.statSync(absolute);
  return <String, Object?>{
    'kind': 'directory',
    'canonicalPath': _absoluteNormalized(canonical),
    'mode': rootAfter.mode & 0x1ff,
    'modifiedMicros': rootAfter.modified.microsecondsSinceEpoch,
    'changedMicros': rootAfter.changed.microsecondsSinceEpoch,
    'entryCount': entries.length,
    'entries': entries,
    'treeSha256': _canonicalDigest(entries),
  };
}

Map<String, Object?> _captureRetainedArtifactIdentity(String path) {
  final type = FileSystemEntity.typeSync(
    _absoluteNormalized(path),
    followLinks: false,
  );
  return switch (type) {
    FileSystemEntityType.file => _captureRegularFileIdentity(path),
    FileSystemEntityType.directory => _captureDirectoryIdentity(path),
    _ => throw const ScoutCliException(
      'retention_identity_unavailable',
      'A retained artifact must be a regular file or directory, never a link.',
    ),
  };
}

void _registerPrivateArtifact(
  String artifactPath, {
  required String metadataPath,
  required String retentionPolicy,
  DateTime? createdAt,
}) {
  final artifact = _canonicalStorageTargetPath(artifactPath);
  final metadata = _canonicalStorageTargetPath(metadataPath);
  final sessionRoot = _canonicalSessionDirectory();
  final artifactIdentity = _captureRetainedArtifactIdentity(artifact);
  final artifactKind = artifactIdentity['kind'];
  final withinSession =
      artifact == sessionRoot || p.isWithin(sessionRoot, artifact);
  final boundary = withinSession
      ? sessionRoot
      : artifactKind == 'directory'
      ? artifact
      : p.dirname(artifact);
  if (artifact == sessionRoot || p.isWithin(artifact, sessionRoot)) {
    throw const ScoutCliException(
      'unsafe_retention_target',
      'A retained artifact cannot contain Scout retention control storage.',
    );
  }
  _assertOutsideRetentionControlStorage(artifact);
  _assertOutsideRetentionControlStorage(metadata);
  final metadataCovered =
      artifactKind == 'directory' && p.isWithin(artifact, metadata);
  final metadataIdentity = metadataCovered
      ? null
      : _captureRegularFileIdentity(metadata);
  final created = (createdAt ?? DateTime.now().toUtc()).toUtc();
  final expiresAt = switch (retentionPolicy) {
    '24h' => created.add(const Duration(hours: 24)),
    '7d' => created.add(const Duration(days: 7)),
    _ => null,
  };
  final entry = <String, Object?>{
    'schemaVersion': 1,
    'artifactId': _canonicalDigest(<String, Object?>{
      'sessionDirectory': sessionRoot,
      'artifactPath': artifact,
    }),
    'artifactPath': artifact,
    'artifactBoundary': boundary,
    'artifactIdentity': artifactIdentity,
    'metadataPath': metadata,
    'metadataCoveredByArtifact': metadataCovered,
    'metadataIdentity': metadataIdentity,
    'policy': retentionPolicy,
    'createdAt': created.toIso8601String(),
    'expiresAt': expiresAt?.toIso8601String(),
    'sessionDirectory': sessionRoot,
    'sessionId': _canonicalDigest(sessionRoot),
    'runId': _currentRunIdFromSession(),
  };
  _validateRetentionEntry(entry);
  _withRetentionRegistryLock<void>(() {
    final state = _readRetentionRegistryUnlocked();
    final entries = <Map<String, Object?>>[
      for (final existing in state.entries)
        if (existing['artifactId'] != entry['artifactId']) existing,
      entry,
    ];
    _writeRetentionRegistryUnlocked(entries);
  });
}

bool _storedIdentityMatches(String path, Object? storedIdentity) {
  try {
    final current = _captureRetainedArtifactIdentity(path);
    return _canonicalJson(current) == _canonicalJson(storedIdentity);
  } catch (_) {
    return false;
  }
}

Map<String, Object?> _cleanupPrivateArtifacts({
  required DateTime now,
  required bool includeSession,
  required String trigger,
}) {
  final retentionType = FileSystemEntity.typeSync(
    _retentionDirectory,
    followLinks: false,
  );
  if (retentionType == FileSystemEntityType.notFound) {
    return _absentRetentionCleanupReport(trigger);
  }
  if (retentionType != FileSystemEntityType.directory) {
    _invalidRetentionRegistry('retention_directory_not_regular');
  }
  final registryType = FileSystemEntity.typeSync(
    _retentionRegistryPath,
    followLinks: false,
  );
  if (registryType == FileSystemEntityType.notFound) {
    return _absentRetentionCleanupReport(trigger);
  }
  if (registryType != FileSystemEntityType.file) {
    _invalidRetentionRegistry('registry_not_regular');
  }
  return _withRetentionRegistryLock<Map<String, Object?>>(() {
    final state = _readRetentionRegistryUnlocked();
    if (!state.exists) return _absentRetentionCleanupReport(trigger);
    final currentTime = now.toUtc();
    final retained = <Map<String, Object?>>[];
    final failures = <Map<String, Object?>>[];
    var examined = 0;
    var deleted = 0;
    var alreadyAbsent = 0;
    var manualPreserved = 0;
    var unexpiredPreserved = 0;
    for (final entry in state.entries) {
      final policy = entry['policy']! as String;
      if (policy == 'manual') {
        manualPreserved += 1;
        retained.add(entry);
        continue;
      }
      final expiresAt = entry['expiresAt'] == null
          ? null
          : _strictRetentionTimestamp(entry['expiresAt'], 'invalid_expires_at');
      final selected =
          (includeSession && policy == 'session') ||
          (expiresAt != null && !expiresAt.isAfter(currentTime));
      if (!selected) {
        unexpiredPreserved += 1;
        retained.add(entry);
        continue;
      }
      examined += 1;
      final artifactId = entry['artifactId']! as String;
      final artifactPath = entry['artifactPath']! as String;
      final metadataPath = entry['metadataPath']! as String;
      final artifactType = FileSystemEntity.typeSync(
        artifactPath,
        followLinks: false,
      );
      final artifactAbsent = artifactType == FileSystemEntityType.notFound;
      final artifactSafe =
          artifactAbsent ||
          ((artifactType == FileSystemEntityType.file ||
                  artifactType == FileSystemEntityType.directory) &&
              _storedIdentityMatches(artifactPath, entry['artifactIdentity']));
      final metadataCovered = entry['metadataCoveredByArtifact']! as bool;
      final metadataType = metadataCovered
          ? FileSystemEntityType.notFound
          : FileSystemEntity.typeSync(metadataPath, followLinks: false);
      final metadataAbsent =
          metadataCovered || metadataType == FileSystemEntityType.notFound;
      final metadataSafe =
          metadataAbsent ||
          (metadataType == FileSystemEntityType.file &&
              _storedIdentityMatches(metadataPath, entry['metadataIdentity']));
      if (!artifactSafe || !metadataSafe) {
        failures.add(<String, Object?>{
          'artifactId': artifactId,
          'reason': !artifactSafe
              ? 'artifact_identity_changed_or_unsafe'
              : 'metadata_identity_changed_or_unsafe',
          'deleted': false,
        });
        retained.add(entry);
        continue;
      }

      // Re-capture immediately before deletion. This second proof catches a
      // caller modification between selection and the destructive operation.
      final artifactStillSafe =
          artifactAbsent ||
          (FileSystemEntity.typeSync(artifactPath, followLinks: false) ==
                  artifactType &&
              _storedIdentityMatches(artifactPath, entry['artifactIdentity']));
      final metadataStillSafe =
          metadataAbsent ||
          (FileSystemEntity.typeSync(metadataPath, followLinks: false) ==
                  metadataType &&
              _storedIdentityMatches(metadataPath, entry['metadataIdentity']));
      if (!artifactStillSafe || !metadataStillSafe) {
        failures.add(<String, Object?>{
          'artifactId': artifactId,
          'reason': 'identity_changed_before_delete',
          'deleted': false,
        });
        retained.add(entry);
        continue;
      }
      try {
        if (!artifactAbsent) {
          if (artifactType == FileSystemEntityType.file) {
            File(artifactPath).deleteSync();
          } else {
            _deletePrivateDirectoryIfExists(
              artifactPath,
              boundary: entry['artifactBoundary']! as String,
            );
          }
        }
        if (!metadataCovered && !metadataAbsent) {
          if (FileSystemEntity.typeSync(metadataPath, followLinks: false) !=
              FileSystemEntityType.file) {
            throw const FileSystemException(
              'Retained metadata changed before deletion.',
            );
          }
          File(metadataPath).deleteSync();
        }
        if (artifactAbsent && metadataAbsent) {
          alreadyAbsent += 1;
        } else {
          deleted += 1;
        }
      } catch (_) {
        failures.add(<String, Object?>{
          'artifactId': artifactId,
          'reason': 'delete_failed',
          'deleted': false,
        });
        retained.add(entry);
      }
    }
    _writeRetentionRegistryUnlocked(retained);
    return <String, Object?>{
      'ok': failures.isEmpty,
      'trigger': trigger,
      'registry': 'valid',
      'examined': examined,
      'deleted': deleted,
      'alreadyAbsent': alreadyAbsent,
      'preserved': failures.length,
      'manualPreserved': manualPreserved,
      'unexpiredPreserved': unexpiredPreserved,
      if (failures.isNotEmpty) 'failures': failures,
    };
  }, secureExistingSessionTree: false);
}

Map<String, Object?> _absentRetentionCleanupReport(String trigger) =>
    <String, Object?>{
      'ok': true,
      'trigger': trigger,
      'registry': 'absent',
      'examined': 0,
      'deleted': 0,
      'alreadyAbsent': 0,
      'preserved': 0,
      'manualPreserved': 0,
      'unexpiredPreserved': 0,
    };

extension _RetentionCommandStartCleanup on FlutterScoutCli {
  void _runRetentionCleanupAtCommandStart(
    String command,
    List<String> arguments,
  ) {
    if (command == 'stop' && arguments.contains('--clear-session')) return;
    final result = _cleanupPrivateArtifacts(
      now: DateTime.now().toUtc(),
      includeSession: false,
      trigger: 'command_start',
    );
    if (result['ok'] != true) {
      // A valid registry with one caller-modified artifact must not make an
      // unrelated read unusable. Keep stdout as the command's single machine
      // response and surface a typed warning separately on stderr.
      _writeStructuredWarning(<String, Object?>{
        'code': 'retention_cleanup_incomplete',
        'message':
            'Expired private artifacts were preserved because their '
            'recorded identities no longer match.',
        'details': result,
      });
    }
  }
}

Map<String, Object?> _cleanupManagedSessionInternals({
  required bool temporaryHelperCleanupComplete,
  String? serveCredentialPath,
}) {
  final sessionRoot = _canonicalSessionDirectory();
  final deleted = <String>[];
  final failures = <Map<String, Object?>>[];

  String relative(String path) => p.relative(path, from: sessionRoot);

  void deleteFile(String path) {
    final absolute = _canonicalStorageTargetPath(path);
    if (absolute != sessionRoot && !p.isWithin(sessionRoot, absolute)) {
      failures.add(<String, Object?>{
        'path': 'external:${p.basename(absolute)}',
        'reason': 'outside_managed_session_boundary',
      });
      return;
    }
    final type = FileSystemEntity.typeSync(absolute, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      failures.add(<String, Object?>{
        'path': relative(absolute),
        'reason': 'not_regular_file',
      });
      return;
    }
    try {
      File(absolute).deleteSync();
      deleted.add(relative(absolute));
    } catch (_) {
      failures.add(<String, Object?>{
        'path': relative(absolute),
        'reason': 'delete_failed',
      });
    }
  }

  void deleteDirectory(String name) {
    final path = p.join(sessionRoot, name);
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      failures.add(<String, Object?>{
        'path': name,
        'reason': 'not_regular_directory',
      });
      return;
    }
    try {
      _deletePrivateDirectoryIfExists(path, boundary: sessionRoot);
      deleted.add(name);
    } catch (_) {
      failures.add(<String, Object?>{
        'path': name,
        'reason': 'unsafe_or_delete_failed',
      });
    }
  }

  void deleteDirectoryIfEmpty(String name) {
    final path = p.join(sessionRoot, name);
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      failures.add(<String, Object?>{
        'path': name,
        'reason': 'not_regular_directory',
      });
      return;
    }
    try {
      if (Directory(path).listSync(followLinks: false).isEmpty) {
        Directory(path).deleteSync();
        deleted.add(name);
      }
    } catch (_) {
      failures.add(<String, Object?>{
        'path': name,
        'reason': 'inspect_or_delete_failed',
      });
    }
  }

  final rootFiles = <String>{
    _vmUriFile,
    _deviceFile,
    _deviceInfoFile,
    _sessionFile,
    '$_sessionFile.lock',
    _eventsFile,
    '$_eventsFile.lock',
    _pidFile,
    _vmLogListenerPidFile,
    _legacyLogFile,
    _launchLockFile,
    _launchLockInfoFile,
    p.join(sessionRoot, 'annotations.json'),
    p.join(sessionRoot, 'serve.credential'),
  };
  if (temporaryHelperCleanupComplete) rootFiles.add(_sessionMetaFile);
  if (serveCredentialPath != null && serveCredentialPath.isNotEmpty) {
    final credential = _canonicalStorageTargetPath(serveCredentialPath);
    if (credential == sessionRoot || p.isWithin(sessionRoot, credential)) {
      rootFiles.add(credential);
    } else if (FileSystemEntity.typeSync(credential, followLinks: false) !=
        FileSystemEntityType.notFound) {
      failures.add(<String, Object?>{
        'path': 'external:${p.basename(credential)}',
        'reason': 'external_credential_not_deleted_without_identity_proof',
      });
    }
  }
  for (final path in rootFiles) {
    deleteFile(path);
  }

  for (final directory in const <String>[
    'runs',
    '.private',
    'idempotency',
    'events',
  ]) {
    deleteDirectory(directory);
  }
  if (temporaryHelperCleanupComplete) {
    deleteDirectory('temporary_helper');
  }
  deleteFile(p.join(sessionRoot, 'evidence', 'index.json'));
  deleteFile(p.join(sessionRoot, 'evidence', 'index.json.lock'));
  for (final directory in const <String>['evidence', 'screenshots', 'crops']) {
    deleteDirectoryIfEmpty(directory);
  }

  var emptyRetentionRegistryRemoved = false;
  final retentionState = _withRetentionRegistryLock<_RetentionRegistryState>(
    () {
      final state = _readRetentionRegistryUnlocked();
      if (state.exists && state.entries.isEmpty) {
        try {
          if (FileSystemEntity.typeSync(
                _retentionRegistryPath,
                followLinks: false,
              ) !=
              FileSystemEntityType.file) {
            _invalidRetentionRegistry('registry_changed_before_clear');
          }
          File(_retentionRegistryPath).deleteSync();
          emptyRetentionRegistryRemoved = true;
          deleted.add(
            relative(_canonicalStorageTargetPath(_retentionRegistryPath)),
          );
        } catch (_) {
          failures.add(const <String, Object?>{
            'path': 'retention/registry.v1.json',
            'reason': 'empty_retention_registry_delete_failed',
          });
        }
      }
      return state;
    },
    secureExistingSessionTree: false,
  );
  final preservedEntries = retentionState.entries;
  final preservedInsideSession = <String>{};
  final preservedDirectoryRoots = <String>{};
  for (final entry in preservedEntries) {
    final artifact = entry['artifactPath']! as String;
    final metadata = entry['metadataPath']! as String;
    if (artifact == sessionRoot || p.isWithin(sessionRoot, artifact)) {
      preservedInsideSession.add(artifact);
      final identity = entry['artifactIdentity'] as Map;
      if (identity['kind'] == 'directory') {
        preservedDirectoryRoots.add(artifact);
      }
    }
    if (metadata == sessionRoot || p.isWithin(sessionRoot, metadata)) {
      preservedInsideSession.add(metadata);
    }
  }

  bool allowedResidual(String path) {
    final retention = _canonicalStorageTargetPath(_retentionDirectory);
    final recordings = _canonicalStorageTargetPath(
      p.join(sessionRoot, 'recordings'),
    );
    final allowedRetentionControls = <String>{
      retention,
      _canonicalStorageTargetPath(_retentionRegistryPath),
      _canonicalStorageTargetPath(_retentionRegistryLockPath),
    };
    if (allowedRetentionControls.contains(path)) return true;
    if (path == recordings || p.isWithin(recordings, path)) return true;
    if (preservedInsideSession.contains(path)) return true;
    if (preservedInsideSession.any((item) => p.isWithin(path, item))) {
      return true; // An ancestor directory of an exact preserved artifact.
    }
    if (preservedDirectoryRoots.any(
      (directory) => path == directory || p.isWithin(directory, path),
    )) {
      return true;
    }
    return false;
  }

  final residuals = <String>[];
  var residualCount = 0;
  try {
    if (Directory(sessionRoot).existsSync()) {
      for (final entity in Directory(
        sessionRoot,
      ).listSync(recursive: true, followLinks: false)) {
        final absolute = _canonicalStorageTargetPath(entity.path);
        final type = FileSystemEntity.typeSync(absolute, followLinks: false);
        if (type == FileSystemEntityType.link || !allowedResidual(absolute)) {
          residualCount += 1;
          if (residuals.length < 64) residuals.add(relative(absolute));
        }
      }
    }
  } catch (_) {
    failures.add(const <String, Object?>{
      'path': '.',
      'reason': 'residual_audit_failed',
    });
  }
  if (!temporaryHelperCleanupComplete) {
    failures.add(const <String, Object?>{
      'path': 'temporary_helper',
      'reason': 'temporary_helper_repair_incomplete',
    });
  }
  return <String, Object?>{
    'ok': failures.isEmpty && residualCount == 0,
    'deletedCount': deleted.length,
    'deleted': deleted,
    'preservedRetentionEntries': preservedEntries.length,
    'emptyRetentionRegistryRemoved': emptyRetentionRegistryRemoved,
    'retentionLockPreservedForSerialization': true,
    'recordingsPreserved':
        FileSystemEntity.typeSync(
          p.join(sessionRoot, 'recordings'),
          followLinks: false,
        ) ==
        FileSystemEntityType.directory,
    'unexpectedResidualCount': residualCount,
    if (residuals.isNotEmpty) 'unexpectedResidualPaths': residuals,
    if (failures.isNotEmpty) 'failures': failures,
  };
}

/// Deterministic storage probes for adversarial retention tests.
extension FlutterScoutRetentionDebug on FlutterScoutCli {
  static void debugUseSessionDirectory(String? path) {
    FlutterScoutCli._sessionDirectoryOverride = path;
  }

  String get debugRetentionRegistryPath => _retentionRegistryPath;

  void debugWriteRetainedArtifact(
    String path,
    List<int> bytes, {
    required String retention,
    DateTime? createdAt,
  }) {
    _writePrivateArtifactBytes(path, bytes);
    _writePrivateArtifactMetadata(path, retention, createdAt: createdAt);
  }

  void debugRegisterRetainedDirectory(
    String path, {
    required String retention,
    DateTime? createdAt,
  }) {
    _writePrivateArtifactMetadata(
      path,
      retention,
      metadataPath: p.join(path, 'retention.metadata.json'),
      createdAt: createdAt,
    );
  }

  Map<String, Object?> debugRetentionCleanup({
    required DateTime now,
    bool includeSession = false,
  }) => _cleanupPrivateArtifacts(
    now: now,
    includeSession: includeSession,
    trigger: includeSession ? 'debug_session_clear' : 'debug_expiry',
  );

  Map<String, Object?> debugRetentionStatus() =>
      _withRetentionRegistryLock<Map<String, Object?>>(() {
        final state = _readRetentionRegistryUnlocked();
        return <String, Object?>{
          'ok': true,
          'registry': state.exists ? 'valid' : 'absent',
          'entryCount': state.entries.length,
          'entries': state.entries,
        };
      });
}
