part of 'flutter_scout_cli.dart';

const int _maxScoutLogMetadataBytes = 1024 * 1024;
const int _maxScoutLogTailBytes = 4 * 1024 * 1024;
const int _maxScoutLogRecordBytes = 256 * 1024;
const int _maxScoutLogResultLines = 1000;
const int _maxScoutLogFilterCharacters = 4096;

/// Resolves only the legacy Scout log or the exact active run log. Session
/// metadata is data, never authority to read an arbitrary local path.
String _resolvedScoutLogFilePath() {
  final sessionRoot = _canonicalStorageTargetPath(_sessionDir.path);
  final legacy = _canonicalStorageTargetPath(_legacyLogFile);
  final metaPath = _canonicalStorageTargetPath(_sessionMetaFile);
  final meta = File(metaPath);
  _assertPrivateFilePath(metaPath, boundary: sessionRoot);
  if (!meta.existsSync()) return legacy;
  _securePrivateFile(meta.path, boundary: sessionRoot);
  if (meta.lengthSync() > _maxScoutLogMetadataBytes) {
    throw const ScoutCliException(
      'runtime_log_corrupt',
      'Scout session metadata exceeds the bounded run-log resolver size.',
    );
  }

  final metaCanonical = meta.resolveSymbolicLinksSync();
  final metaBefore = FileStat.statSync(meta.path);
  final metaBytes = meta.readAsBytesSync();
  final metaAfter = FileStat.statSync(meta.path);
  if (FileSystemEntity.typeSync(meta.path, followLinks: false) !=
          FileSystemEntityType.file ||
      !_sameFileStat(metaBefore, metaAfter) ||
      meta.resolveSymbolicLinksSync() != metaCanonical) {
    throw const ScoutCliException(
      'runtime_log_changed',
      'Scout session metadata changed while the active run log was resolved.',
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(metaBytes));
  } catch (_) {
    throw const ScoutCliException(
      'runtime_log_corrupt',
      'Scout session metadata is not valid UTF-8 JSON, so its run log cannot '
          'be resolved safely.',
    );
  }
  if (decoded is! Map) {
    throw const ScoutCliException(
      'runtime_log_corrupt',
      'Scout session metadata is not an object, so its run log cannot be '
          'resolved safely.',
    );
  }
  final mode = decoded['mode']?.toString();
  final configuredValue = decoded['logFile'];
  if (mode != 'scout_owned_flutter_run' || configuredValue == null) {
    return legacy;
  }
  if (configuredValue is! String ||
      configuredValue.isEmpty ||
      configuredValue.length > 4096 ||
      configuredValue.contains('\u0000')) {
    throw const ScoutCliException(
      'runtime_log_corrupt',
      'Scout session metadata contains an invalid run-log path.',
    );
  }

  final configured = _canonicalStorageTargetPath(configuredValue);
  if (configured != sessionRoot && !p.isWithin(sessionRoot, configured)) {
    _unsafeStoragePath(
      configuredValue,
      'session log metadata escapes the Scout-owned session directory',
    );
  }
  _assertPrivateFilePath(configured, boundary: sessionRoot);
  if (configured == legacy) return legacy; // v1 compatibility path.

  final runIdValue = decoded['runId'];
  if (runIdValue is! String ||
      !RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(runIdValue)) {
    throw const ScoutCliException(
      'runtime_log_corrupt',
      'Scout-owned run metadata lacks a valid run identity for its log.',
    );
  }
  final expected = _canonicalStorageTargetPath(
    p.join(sessionRoot, 'runs', runIdValue, 'logs.txt'),
  );
  if (configured != expected) {
    _unsafeStoragePath(
      configuredValue,
      'session log metadata does not name the exact active Scout run log',
    );
  }
  return configured;
}

_LogChunk _readValidatedScoutLogChunk(
  File requested, {
  int? sinceCursor,
  int maxBytes = _maxScoutLogTailBytes,
}) {
  if (maxBytes <= 0 || maxBytes > _maxScoutLogTailBytes) {
    throw const ScoutCliException(
      'request_parameter_too_large',
      'The requested Scout log byte window exceeds the 4 MiB bound.',
    );
  }
  final expected = _resolvedScoutLogFilePath();
  final requestedPath = _canonicalStorageTargetPath(requested.path);
  if (requestedPath != expected) {
    _unsafeStoragePath(
      requested.path,
      'the requested log is not the resolved Scout-owned run log',
    );
  }
  final root = _canonicalStorageTargetPath(_sessionDir.path);
  _assertPrivateFilePath(requestedPath, boundary: root, allowMissing: false);
  final type = FileSystemEntity.typeSync(requestedPath, followLinks: false);
  if (type != FileSystemEntityType.file) {
    _unsafeStoragePath(
      requestedPath,
      'the Scout run log is not a regular file',
    );
  }
  _securePrivateFile(requestedPath, boundary: root);

  final canonicalBefore = File(requestedPath).resolveSymbolicLinksSync();
  final before = FileStat.statSync(requestedPath);
  if (before.type != FileSystemEntityType.file ||
      (_supportsPosixModes && (before.mode & 0x1ff) != _privateFileMode)) {
    _unsafeStoragePath(
      requestedPath,
      'the Scout run log is not an owner-only regular file',
    );
  }
  final length = before.size;
  if (sinceCursor != null && (sinceCursor < 0 || sinceCursor > length)) {
    throw const ScoutCliException(
      'runtime_log_changed',
      'The requested Scout log cursor is outside the current validated file.',
    );
  }
  final requestedStart = sinceCursor ?? max(0, length - maxBytes);
  final boundedStart = max(requestedStart, length - maxBytes);
  final rangeTruncated =
      boundedStart > requestedStart ||
      (sinceCursor == null && length > maxBytes);
  final verificationStart = boundedStart > 0 ? boundedStart - 1 : boundedStart;
  final handle = File(requestedPath).openSync(mode: FileMode.read);
  late final List<int> snapshottedRange;
  try {
    handle.lockSync(FileLock.blockingShared);
    handle.setPositionSync(verificationStart);
    snapshottedRange = handle.readSync(length - verificationStart);
  } finally {
    try {
      handle.unlockSync();
    } catch (_) {}
    handle.closeSync();
  }

  final precedingByte = boundedStart > 0 && snapshottedRange.isNotEmpty
      ? snapshottedRange.first
      : null;
  var bytes = boundedStart > verificationStart
      ? snapshottedRange.sublist(1)
      : snapshottedRange;
  var startCursor = boundedStart;
  var partialRecordDropped = false;
  if (boundedStart > 0 && precedingByte != 0x0a && bytes.isNotEmpty) {
    final firstNewline = bytes.indexOf(0x0a);
    if (firstNewline < 0) {
      if (bytes.length > _maxScoutLogRecordBytes) {
        throw const ScoutCliException(
          'runtime_log_record_too_large',
          'A Scout runtime log record exceeds the 256 KiB bound.',
        );
      }
    } else {
      startCursor += firstNewline + 1;
      bytes = bytes.sublist(firstNewline + 1);
      partialRecordDropped = true;
    }
  }
  _validateScoutLogRecordBounds(bytes);

  final lastNewline = bytes.lastIndexOf(0x0a);
  final completeLength = lastNewline < 0 ? 0 : lastNewline + 1;
  final completeBytes = bytes.sublist(0, completeLength);
  final pendingBytes = bytes.length - completeLength;

  final String text;
  try {
    text = utf8.decode(completeBytes, allowMalformed: false);
  } catch (_) {
    throw const ScoutCliException(
      'runtime_log_corrupt',
      'The Scout runtime log contains invalid UTF-8.',
    );
  }

  final afterType = FileSystemEntity.typeSync(
    requestedPath,
    followLinks: false,
  );
  final after = FileStat.statSync(requestedPath);
  if (afterType != FileSystemEntityType.file ||
      after.type != FileSystemEntityType.file ||
      after.size < length ||
      File(requestedPath).resolveSymbolicLinksSync() != canonicalBefore ||
      (_supportsPosixModes && (after.mode & 0x1ff) != _privateFileMode)) {
    throw const ScoutCliException(
      'runtime_log_changed',
      'The Scout runtime log was replaced, truncated, or changed type while '
          'it was being read.',
    );
  }

  // Appends after the snapshot are harmless. Re-read only the snapshotted
  // range through the pathname; a replacement or rewrite of that range fails
  // closed even when its size and timestamps were forged to look unchanged.
  final verification = File(requestedPath).openSync(mode: FileMode.read);
  late final List<int> verificationBytes;
  try {
    verification.lockSync(FileLock.blockingShared);
    verification.setPositionSync(verificationStart);
    verificationBytes = verification.readSync(length - verificationStart);
  } finally {
    try {
      verification.unlockSync();
    } catch (_) {}
    verification.closeSync();
  }
  if (!_constantTimeBytesEqual(snapshottedRange, verificationBytes)) {
    throw const ScoutCliException(
      'runtime_log_changed',
      'The Scout runtime log read range changed during validation.',
    );
  }

  return _LogChunk(
    const LineSplitter().convert(text),
    startCursor: startCursor,
    endCursor: startCursor + completeLength,
    observedFileLength: length,
    truncated: rangeTruncated || partialRecordDropped,
    bytesRead: completeBytes.length,
    pendingBytes: pendingBytes,
  );
}

void _validateScoutLogRecordBounds(List<int> bytes) {
  var recordBytes = 0;
  for (final byte in bytes) {
    if (byte == 0x0a) {
      if (recordBytes > _maxScoutLogRecordBytes) {
        throw const ScoutCliException(
          'runtime_log_record_too_large',
          'A Scout runtime log record exceeds the 256 KiB bound.',
        );
      }
      recordBytes = 0;
    } else {
      recordBytes++;
    }
  }
  if (recordBytes > _maxScoutLogRecordBytes) {
    throw const ScoutCliException(
      'runtime_log_record_too_large',
      'A Scout runtime log record exceeds the 256 KiB bound.',
    );
  }
}

bool _constantTimeBytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index++) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}

int _validatedScoutLogLength() {
  final path = _resolvedScoutLogFilePath();
  final root = _canonicalStorageTargetPath(_sessionDir.path);
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return 0;
  _assertPrivateFilePath(path, boundary: root, allowMissing: false);
  if (type != FileSystemEntityType.file) {
    _unsafeStoragePath(path, 'the Scout run log is not a regular file');
  }
  _securePrivateFile(path, boundary: root);
  final before = FileStat.statSync(path);
  final canonical = File(path).resolveSymbolicLinksSync();
  final length = before.size;
  final after = FileStat.statSync(path);
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file ||
      after.type != FileSystemEntityType.file ||
      after.size < length ||
      File(path).resolveSymbolicLinksSync() != canonical) {
    throw const ScoutCliException(
      'runtime_log_changed',
      'The Scout runtime log changed while its cursor was measured.',
    );
  }
  return after.size;
}
