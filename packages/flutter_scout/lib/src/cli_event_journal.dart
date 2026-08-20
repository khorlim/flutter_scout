part of 'flutter_scout_cli.dart';

// The public `events.jsonl` file remains a bounded recent-event projection for
// v1 consumers. Durable history is an append-only operation journal split into
// bounded segments. A reservation is a `put`; its completion is a `patch`.
// Neither operation rewrites prior durable history.
const int _eventJournalSchemaVersion = 1;
const int _maxEventOperationBytes = 128 * 1024;
const int _maxEventSegmentBytes = 512 * 1024;
const int _maxEventOperationsPerSegment = 256;
const int _maxEventJournalSegments = 64;
const int _maxEventOpenReservations = 64;
const int _maxEventProjectionRows = 256;
const int _maxEventProjectionBytes = 8 * 1024 * 1024;
const int _maxLegacyEventRows =
    _maxEventJournalSegments * _maxEventOperationsPerSegment;
const int _maxEventHeadBytes = 64 * 1024;

String get _eventJournalDirectory => p.join(_sessionDir.path, 'events');
String get _eventSegmentDirectory => p.join(_eventJournalDirectory, 'segments');
String get _eventHeadFile => p.join(_eventJournalDirectory, 'head.json');
String get _eventProjectionHeadFile =>
    p.join(_eventJournalDirectory, 'projection_head.json');

String _eventSegmentFile(int number) => p.join(
  _eventSegmentDirectory,
  'segment-${number.toString().padLeft(8, '0')}.jsonl',
);

extension _SegmentedEventJournal on FlutterScoutCli {
  int _appendSegmentedEventStrict(Map<String, Object?> event) {
    _ensurePrivateDirectory(
      _sessionDir.path,
      boundary: _sessionManagedBoundary(),
    );
    return _withPrivateFileLock<int>(
      '$_eventsFile.lock',
      boundary: _sessionDir.path,
      body: () {
        _validateEventProjectionPath();
        var head = _loadEventJournalHeadUnlocked();
        final projectionRows = _loadEventProjectionTailUnlocked(head);
        final sanitized = _sanitizeForSerialization(event);
        if (sanitized is! Map) {
          throw const ScoutCliException(
            'event_serialization_failed',
            'The Scout event could not be represented as a JSON object.',
          );
        }
        final cursor = head.lastEventCursor + 1;
        var next = Map<String, Object?>.from(sanitized)
          ..['eventCursor'] = cursor
          ..['cursor'] = cursor
          ..['previousEventCursor'] = head.lastEventCursor == 0
              ? null
              : head.lastEventCursor;
        next = _correlateCliEvent(next, allowCurrentContext: true);

        final operationSequence = head.lastOperationSequence + 1;
        final operation = <String, Object?>{
          'schemaVersion': _eventJournalSchemaVersion,
          'operationSequence': operationSequence,
          'operation': 'put',
          'eventCursor': cursor,
          'event': next,
        };
        final commandId = next['commandId']?.toString();
        final open = Map<int, String>.from(head.openReservations);
        if (next['status'] == 'started' &&
            commandId != null &&
            commandId.isNotEmpty) {
          if (open.length >= _maxEventOpenReservations) {
            throw const ScoutCliException(
              'event_journal_capacity_exceeded',
              'The bounded Scout event journal has too many unfinished '
                  'command reservations.',
            );
          }
          open[cursor] = commandId;
        }
        head = _appendEventOperationUnlocked(head, operation);
        head = head.copyWith(
          lastOperationSequence: operationSequence,
          lastEventCursor: cursor,
          openReservations: open,
        );
        _writeEventJournalHeadUnlocked(head);
        FlutterScoutCli.debugEventJournalAfterHeadCommitHook?.call();
        projectionRows.add(Map<String, Object?>.from(next));
        if (projectionRows.length > _maxEventProjectionRows) {
          projectionRows.removeRange(
            0,
            projectionRows.length - _maxEventProjectionRows,
          );
        }
        _writeEventProjectionUnlocked(projectionRows, head: head);
        return cursor;
      },
    );
  }

  void _updateSegmentedEventStrict({
    required int cursor,
    required String commandId,
    required Map<String, Object?> updates,
  }) {
    _ensurePrivateDirectory(
      _sessionDir.path,
      boundary: _sessionManagedBoundary(),
    );
    _withPrivateFileLock<void>(
      '$_eventsFile.lock',
      boundary: _sessionDir.path,
      body: () {
        _validateEventProjectionPath();
        var head = _loadEventJournalHeadUnlocked();
        final projectionRows = _loadEventProjectionTailUnlocked(head);
        if (head.openReservations[cursor] != commandId) {
          throw const ScoutCliException(
            'event_reservation_missing',
            'The reserved Scout command event is unavailable.',
          );
        }
        final sanitized = _sanitizeForSerialization(updates);
        if (sanitized is! Map) {
          throw const ScoutCliException(
            'event_serialization_failed',
            'The Scout event update could not be represented as an object.',
          );
        }
        const protectedKeys = <String>{
          'eventCursor',
          'cursor',
          'previousEventCursor',
          'commandId',
          'cliCommandId',
          'type',
          'startedAt',
          'correlation',
        };
        if (sanitized.keys.any((key) => protectedKeys.contains('$key'))) {
          throw const ScoutCliException(
            'event_update_invalid',
            'A Scout event update attempted to change reserved identity.',
          );
        }
        final safeUpdates = Map<String, Object?>.from(sanitized);
        final operationSequence = head.lastOperationSequence + 1;
        final operation = <String, Object?>{
          'schemaVersion': _eventJournalSchemaVersion,
          'operationSequence': operationSequence,
          'operation': 'patch',
          'eventCursor': cursor,
          'commandId': commandId,
          'updates': safeUpdates,
        };
        head = _appendEventOperationUnlocked(head, operation);
        final open = Map<int, String>.from(head.openReservations)
          ..remove(cursor);
        head = head.copyWith(
          lastOperationSequence: operationSequence,
          openReservations: open,
        );
        _writeEventJournalHeadUnlocked(head);
        FlutterScoutCli.debugEventJournalAfterHeadCommitHook?.call();
        _projectEventPatchUnlocked(
          rows: projectionRows,
          cursor: cursor,
          commandId: commandId,
          updates: safeUpdates,
          head: head,
        );
      },
    );
  }

  List<Map<String, Object?>> _readSegmentedEventRows({
    required File legacyProjection,
  }) {
    final hasSegments =
        FileSystemEntity.typeSync(_eventSegmentDirectory, followLinks: false) ==
        FileSystemEntityType.directory;
    if (!hasSegments) {
      return _readLegacyEventRows(
        legacyProjection,
        maxBytes: _maxEventProjectionBytes,
        maxRows: _maxLegacyEventRows,
      );
    }
    return _withPrivateFileLock<List<Map<String, Object?>>>(
      '$_eventsFile.lock',
      boundary: _sessionDir.path,
      body: _foldEventOperationsUnlocked,
    );
  }

  _EventJournalHead _loadEventJournalHeadUnlocked() {
    _ensurePrivateDirectory(_eventSegmentDirectory, boundary: _sessionDir.path);
    final headFile = File(_eventHeadFile);
    _assertPrivateFilePath(_eventHeadFile, boundary: _sessionDir.path);
    if (headFile.existsSync()) {
      try {
        final head = _readEventJournalHead(headFile);
        _validateEventJournalHeadAgainstTail(head);
        return head;
      } on ScoutCliException {
        return _recoverEventJournalHeadUnlocked();
      }
    }

    final segments = _eventSegmentFilesUnlocked();
    if (segments.isNotEmpty) return _recoverEventJournalHeadUnlocked();

    final projection = File(_eventsFile);
    if (projection.existsSync() && projection.lengthSync() > 0) {
      return _migrateLegacyEventJournalUnlocked(projection);
    }
    return const _EventJournalHead();
  }

  _EventJournalHead _readEventJournalHead(File file) {
    _securePrivateFile(file.path, boundary: _sessionDir.path);
    if (file.lengthSync() > _maxEventHeadBytes) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'The Scout event journal head exceeds its bounded representation.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(file.readAsBytesSync()));
    } catch (_) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'The Scout event journal head is not valid UTF-8 JSON.',
      );
    }
    if (decoded is! Map) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'The Scout event journal head is not a JSON object.',
      );
    }
    return _EventJournalHead.fromJson(Map<String, Object?>.from(decoded));
  }

  void _validateEventJournalHeadAgainstTail(_EventJournalHead head) {
    final segments = _eventSegmentFilesUnlocked();
    if (segments.length > _maxEventJournalSegments) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'The Scout event journal contains too many retained segments.',
      );
    }
    if (head.currentSegmentOperations == 0) {
      if (head.lastOperationSequence != 0 ||
          head.currentSegmentBytes != 0 ||
          segments.isNotEmpty) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'The empty Scout event journal head disagrees with its segments.',
        );
      }
      return;
    }
    final current = File(_eventSegmentFile(head.currentSegment));
    _assertPrivateFilePath(
      current.path,
      boundary: _sessionDir.path,
      allowMissing: false,
    );
    _securePrivateFile(current.path, boundary: _sessionDir.path);
    if (current.lengthSync() != head.currentSegmentBytes ||
        current.lengthSync() > _maxEventSegmentBytes) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'The Scout event journal head does not match its current segment.',
      );
    }
    final lastLine = _readLastCompleteEventOperationLine(current);
    if (lastLine == null ||
        _eventOperationDigest(lastLine) != head.lastOperationDigest) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'The Scout event journal tail does not match its committed head.',
      );
    }
    final last = _decodeEventOperation(lastLine);
    if (last['operationSequence'] != head.lastOperationSequence) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'The Scout event journal operation cursor disagrees with its head.',
      );
    }
  }

  _EventJournalHead _appendEventOperationUnlocked(
    _EventJournalHead head,
    Map<String, Object?> operation,
  ) {
    final line = jsonEncode(operation);
    final bytes = utf8.encode('$line\n');
    if (bytes.length > _maxEventOperationBytes) {
      throw const ScoutCliException(
        'event_serialization_failed',
        'The Scout event exceeds the bounded journal record size.',
      );
    }

    var targetHead = head;
    final needsRotation =
        targetHead.currentSegmentOperations >= _maxEventOperationsPerSegment ||
        targetHead.currentSegmentBytes + bytes.length > _maxEventSegmentBytes;
    if (needsRotation) {
      _assertEventSegmentCapacityForRotationUnlocked();
      targetHead = targetHead.copyWith(
        currentSegment: targetHead.currentSegment + 1,
        currentSegmentOperations: 0,
        currentSegmentBytes: 0,
        lastOperationDigest: null,
      );
    }

    final path = _eventSegmentFile(targetHead.currentSegment);
    final file = File(path);
    _assertPrivateFilePath(path, boundary: _sessionDir.path);
    if (!file.existsSync()) {
      try {
        file.createSync(exclusive: true);
      } on FileSystemException {
        // The journal-wide lock excludes cooperative creation races. Validate
        // any object that nevertheless appeared before opening it.
      }
    }
    _securePrivateFile(path, boundary: _sessionDir.path);
    final originalLength = file.lengthSync();
    if (originalLength != targetHead.currentSegmentBytes) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'The Scout event segment changed before an append.',
      );
    }
    final handle = file.openSync(mode: FileMode.append);
    try {
      handle.writeFromSync(bytes);
      handle.flushSync();
    } catch (_) {
      try {
        handle.truncateSync(originalLength);
        handle.flushSync();
      } catch (_) {}
      rethrow;
    } finally {
      handle.closeSync();
    }
    _securePrivateFile(path, boundary: _sessionDir.path);
    return targetHead.copyWith(
      currentSegmentOperations: targetHead.currentSegmentOperations + 1,
      currentSegmentBytes: originalLength + bytes.length,
      lastOperationDigest: _eventOperationDigest(line),
    );
  }

  void _assertEventSegmentCapacityForRotationUnlocked() {
    final segments = _eventSegmentFilesUnlocked();
    if (segments.length < _maxEventJournalSegments) return;
    // History is lossless inside this journal. Retention cleanup must be an
    // explicit, separately recorded policy operation; rotation never silently
    // deletes a completed event. Refuse before appending when the bounded
    // recovery set is full, leaving every committed cursor intact.
    throw const ScoutCliException(
      'event_journal_capacity_exceeded',
      'The lossless Scout event journal reached its bounded 64-segment '
          'capacity. Export and explicitly retire history before retrying.',
    );
  }

  void _writeEventJournalHeadUnlocked(_EventJournalHead head) {
    _atomicWritePrivateJson(
      _eventHeadFile,
      head.toJson(),
      boundary: _sessionDir.path,
    );
  }

  _EventJournalHead _recoverEventJournalHeadUnlocked() {
    final operations = _readAllEventOperationsUnlocked(repairTornTail: true);
    if (operations.isEmpty) {
      final empty = const _EventJournalHead();
      _writeEventJournalHeadUnlocked(empty);
      return empty;
    }
    var previousSequence = (operations.first['operationSequence'] as int) - 1;
    var lastEventCursor = 0;
    final events = <int, Map<String, Object?>>{};
    for (final operation in operations) {
      final sequence = operation['operationSequence'] as int;
      if (sequence != previousSequence + 1) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'The Scout event operation cursor sequence is not contiguous.',
        );
      }
      previousSequence = sequence;
      final cursor = operation['eventCursor'] as int;
      if (operation['operation'] == 'put') {
        final event = Map<String, Object?>.from(operation['event']! as Map);
        if (cursor <= lastEventCursor) {
          throw const ScoutCliException(
            'event_journal_corrupt',
            'The Scout event cursor sequence is not strictly increasing.',
          );
        }
        lastEventCursor = cursor;
        events[cursor] = event;
      } else {
        final existing = events[cursor];
        if (existing == null) continue; // Its put may have been retained out.
        final commandId = operation['commandId']?.toString();
        if (existing['commandId']?.toString() != commandId) {
          throw const ScoutCliException(
            'event_journal_corrupt',
            'A Scout event patch does not match its reserved command.',
          );
        }
        existing.addAll(
          Map<String, Object?>.from(operation['updates']! as Map),
        );
      }
    }
    final segments = _eventSegmentFilesUnlocked();
    final current = segments.last;
    final number = _eventSegmentNumber(current.path);
    final currentLines = _readEventOperationLines(
      current,
      allowTornTail: false,
      repairTornTail: false,
    );
    final lastLine = currentLines.last;
    final open = <int, String>{};
    for (final entry in events.entries) {
      final commandId = entry.value['commandId']?.toString();
      if (entry.value['status'] == 'started' &&
          commandId != null &&
          commandId.isNotEmpty) {
        if (open.length >= _maxEventOpenReservations) {
          throw const ScoutCliException(
            'event_journal_capacity_exceeded',
            'The Scout event journal recovery found too many unfinished '
                'command reservations.',
          );
        }
        open[entry.key] = commandId;
      }
    }
    final recovered = _EventJournalHead(
      lastOperationSequence: previousSequence,
      lastEventCursor: lastEventCursor,
      currentSegment: number,
      currentSegmentOperations: currentLines.length,
      currentSegmentBytes: current.lengthSync(),
      lastOperationDigest: _eventOperationDigest(lastLine),
      openReservations: open,
    );
    _writeEventJournalHeadUnlocked(recovered);
    _writeEventProjectionUnlocked(
      events.values.toList(growable: false),
      head: recovered,
    );
    return recovered;
  }

  _EventJournalHead _migrateLegacyEventJournalUnlocked(File projection) {
    final rows = _readLegacyEventRows(
      projection,
      maxBytes: _maxEventProjectionBytes,
      maxRows: _maxLegacyEventRows,
    );
    var head = const _EventJournalHead();
    for (final row in rows) {
      final cursor = row['eventCursor']! as int;
      final commandId = row['commandId']?.toString();
      if (row['status'] == 'started' &&
          commandId != null &&
          commandId.isNotEmpty &&
          head.openReservations.length >= _maxEventOpenReservations) {
        throw const ScoutCliException(
          'event_journal_capacity_exceeded',
          'The legacy Scout event journal has too many unfinished command '
              'reservations to migrate safely.',
        );
      }
      final operationSequence = head.lastOperationSequence + 1;
      final operation = <String, Object?>{
        'schemaVersion': _eventJournalSchemaVersion,
        'operationSequence': operationSequence,
        'operation': 'put',
        'eventCursor': cursor,
        'event': row,
      };
      head = _appendEventOperationUnlocked(head, operation).copyWith(
        lastOperationSequence: operationSequence,
        lastEventCursor: cursor,
      );
      if (row['status'] == 'started' &&
          commandId != null &&
          commandId.isNotEmpty) {
        final open = Map<int, String>.from(head.openReservations);
        open[cursor] = commandId;
        head = head.copyWith(openReservations: open);
      }
    }
    _writeEventJournalHeadUnlocked(head);
    _writeEventProjectionUnlocked(rows, head: head);
    return head;
  }

  List<Map<String, Object?>> _foldEventOperationsUnlocked() {
    final operations = _readAllEventOperationsUnlocked(repairTornTail: false);
    final events = <int, Map<String, Object?>>{};
    int? previousSequence;
    var previousPutCursor = 0;
    for (final operation in operations) {
      final sequence = operation['operationSequence'] as int;
      if (previousSequence != null && sequence != previousSequence + 1) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'The Scout event operation cursor sequence is not contiguous.',
        );
      }
      previousSequence = sequence;
      final cursor = operation['eventCursor'] as int;
      if (operation['operation'] == 'put') {
        if (cursor <= previousPutCursor) {
          throw const ScoutCliException(
            'event_journal_corrupt',
            'The Scout event cursor sequence is not strictly increasing.',
          );
        }
        previousPutCursor = cursor;
        events[cursor] = Map<String, Object?>.from(operation['event']! as Map);
        continue;
      }
      final existing = events[cursor];
      if (existing == null) continue;
      if (existing['commandId']?.toString() !=
          operation['commandId']?.toString()) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'A Scout event patch does not match its reserved command.',
        );
      }
      existing.addAll(Map<String, Object?>.from(operation['updates']! as Map));
      events[cursor] = _correlateCliEvent(existing, allowCurrentContext: false);
    }
    return events.values.toList(growable: false);
  }

  List<Map<String, Object?>> _readAllEventOperationsUnlocked({
    required bool repairTornTail,
  }) {
    final segments = _eventSegmentFilesUnlocked();
    final operations = <Map<String, Object?>>[];
    for (var index = 0; index < segments.length; index++) {
      final isLast = index == segments.length - 1;
      for (final line in _readEventOperationLines(
        segments[index],
        allowTornTail: isLast,
        repairTornTail: isLast && repairTornTail,
      )) {
        operations.add(_decodeEventOperation(line));
      }
    }
    return operations;
  }

  List<File> _eventSegmentFilesUnlocked() {
    final directory = Directory(_eventSegmentDirectory);
    if (!directory.existsSync()) return const <File>[];
    final entities = directory.listSync(followLinks: false);
    if (entities.length > _maxEventJournalSegments + 1) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'The Scout event segment directory exceeds its bounded entry count.',
      );
    }
    final files = <File>[];
    for (final entity in entities) {
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (type != FileSystemEntityType.file ||
          !RegExp(
            r'^segment-[0-9]{8}\.jsonl$',
          ).hasMatch(p.basename(entity.path))) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'The Scout event segment directory contains an unexpected object.',
        );
      }
      _securePrivateFile(entity.path, boundary: _sessionDir.path);
      if (File(entity.path).lengthSync() > _maxEventSegmentBytes) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'A Scout event segment exceeds its bounded size.',
        );
      }
      files.add(File(entity.path));
    }
    files.sort(
      (left, right) => _eventSegmentNumber(
        left.path,
      ).compareTo(_eventSegmentNumber(right.path)),
    );
    for (var index = 1; index < files.length; index++) {
      if (_eventSegmentNumber(files[index].path) !=
          _eventSegmentNumber(files[index - 1].path) + 1) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'The Scout event segment sequence is not contiguous.',
        );
      }
    }
    return files;
  }

  List<String> _readEventOperationLines(
    File file, {
    required bool allowTornTail,
    required bool repairTornTail,
  }) {
    _assertPrivateFilePath(
      file.path,
      boundary: _sessionDir.path,
      allowMissing: false,
    );
    _securePrivateFile(file.path, boundary: _sessionDir.path);
    final bytes = file.readAsBytesSync();
    if (bytes.length > _maxEventSegmentBytes) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'A Scout event segment exceeds its bounded size.',
      );
    }
    var completeLength = bytes.length;
    if (bytes.isNotEmpty && bytes.last != 0x0a) {
      if (!allowTornTail) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'A non-final Scout event segment has a torn record.',
        );
      }
      completeLength = bytes.lastIndexOf(0x0a) + 1;
      if (repairTornTail) {
        final handle = file.openSync(mode: FileMode.append);
        try {
          handle.truncateSync(completeLength);
          handle.flushSync();
        } finally {
          handle.closeSync();
        }
      }
    }
    final String text;
    try {
      text = utf8.decode(bytes.sublist(0, completeLength));
    } catch (_) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'A Scout event segment is not valid UTF-8.',
      );
    }
    final lines = const LineSplitter()
        .convert(text)
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.length > _maxEventOperationsPerSegment) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'A Scout event segment exceeds its bounded operation count.',
      );
    }
    if (lines.any(
      (line) => utf8.encode(line).length + 1 > _maxEventOperationBytes,
    )) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'A Scout event operation exceeds its bounded record size.',
      );
    }
    return lines;
  }

  String? _readLastCompleteEventOperationLine(File file) {
    final length = file.lengthSync();
    if (length == 0) return null;
    final start = max(0, length - _maxEventOperationBytes);
    final handle = file.openSync(mode: FileMode.read);
    late final List<int> bytes;
    try {
      handle.setPositionSync(start);
      bytes = handle.readSync(length - start);
    } finally {
      handle.closeSync();
    }
    if (bytes.isEmpty || bytes.last != 0x0a) return null;
    final withoutFinalNewline = bytes.sublist(0, bytes.length - 1);
    final prior = withoutFinalNewline.lastIndexOf(0x0a);
    final lineBytes = withoutFinalNewline.sublist(prior + 1);
    try {
      return utf8.decode(lineBytes);
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> _decodeEventOperation(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'A complete Scout event operation is not valid JSON.',
      );
    }
    if (decoded is! Map) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'A Scout event operation is not an object.',
      );
    }
    final row = Map<String, Object?>.from(decoded);
    final sequence = row['operationSequence'];
    final cursor = row['eventCursor'];
    final kind = row['operation'];
    if (row['schemaVersion'] != _eventJournalSchemaVersion ||
        sequence is! int ||
        sequence <= 0 ||
        cursor is! int ||
        cursor <= 0 ||
        (kind != 'put' && kind != 'patch')) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'A Scout event operation has invalid required fields.',
      );
    }
    if (kind == 'put') {
      final event = row['event'];
      if (event is! Map || event['eventCursor'] != cursor) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'A Scout event put operation has an invalid event payload.',
        );
      }
    } else if (row['updates'] is! Map ||
        row['commandId'] is! String ||
        (row['commandId']! as String).isEmpty) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'A Scout event patch operation has an invalid update payload.',
      );
    }
    return row;
  }

  List<Map<String, Object?>> _readLegacyEventRows(
    File file, {
    required int maxBytes,
    required int maxRows,
  }) {
    _assertPrivateFilePath(file.path, boundary: _sessionDir.path);
    if (!file.existsSync()) return const <Map<String, Object?>>[];
    _securePrivateFile(file.path, boundary: _sessionDir.path);
    if (file.lengthSync() > maxBytes) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'The legacy Scout event journal exceeds its migration bound.',
      );
    }
    final bytes = file.readAsBytesSync();
    var completeLength = bytes.length;
    if (bytes.isNotEmpty && bytes.last != 0x0a) {
      completeLength = bytes.lastIndexOf(0x0a) + 1;
    }
    final String raw;
    try {
      raw = utf8.decode(bytes.sublist(0, completeLength));
    } catch (_) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'The legacy Scout event journal is not valid UTF-8.',
      );
    }
    final rows = <Map<String, Object?>>[];
    var previousCursor = 0;
    for (final line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      if (rows.length >= maxRows) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'The legacy Scout event journal exceeds its migration row bound.',
        );
      }
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } catch (_) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'The Scout event journal contains an invalid complete record.',
        );
      }
      if (decoded is! Map) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'The Scout event journal contains a non-object record.',
        );
      }
      final row = Map<String, Object?>.from(decoded);
      final storedCursor = row['eventCursor'];
      final eventCursor = storedCursor is int
          ? storedCursor
          : previousCursor + 1;
      if (eventCursor <= 0 ||
          (previousCursor != 0 && eventCursor != previousCursor + 1)) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'The Scout event journal cursor sequence is not contiguous.',
        );
      }
      row['eventCursor'] = eventCursor;
      row['cursor'] = eventCursor;
      row['previousEventCursor'] = eventCursor == 1 ? null : eventCursor - 1;
      rows.add(_correlateCliEvent(row, allowCurrentContext: false));
      previousCursor = eventCursor;
    }
    return rows;
  }

  void _validateEventProjectionPath() {
    _assertPrivateFilePath(_eventsFile, boundary: _sessionDir.path);
    final type = FileSystemEntity.typeSync(_eventsFile, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const ScoutCliException(
        'unsafe_storage_path',
        'The Scout event projection must be a regular non-symlink file.',
      );
    }
    if (type == FileSystemEntityType.file) {
      _securePrivateFile(_eventsFile, boundary: _sessionDir.path);
    }
  }

  void _projectEventPatchUnlocked({
    required List<Map<String, Object?>> rows,
    required int cursor,
    required String commandId,
    required Map<String, Object?> updates,
    required _EventJournalHead head,
  }) {
    final index = rows.indexWhere(
      (row) => row['eventCursor'] == cursor && row['commandId'] == commandId,
    );
    if (index >= 0) {
      rows[index].addAll(updates);
      rows[index] = _correlateCliEvent(rows[index], allowCurrentContext: true);
    }
    _writeEventProjectionUnlocked(rows, head: head);
  }

  List<Map<String, Object?>> _loadEventProjectionTailUnlocked(
    _EventJournalHead head,
  ) {
    final session = p.normalize(p.absolute(_sessionDir.path));
    if (_eventProjectionCacheSession == session &&
        _eventProjectionCacheSequence == head.lastOperationSequence &&
        _eventProjectionCacheRows != null) {
      return <Map<String, Object?>>[
        for (final row in _eventProjectionCacheRows!)
          Map<String, Object?>.from(row),
      ];
    }
    if (head.lastOperationSequence == 0) {
      _cacheEventProjection(<Map<String, Object?>>[], head: head);
      return <Map<String, Object?>>[];
    }
    FlutterScoutCli.debugEventProjectionDiskLoadHook?.call();
    final file = File(_eventsFile);
    try {
      final metadataFile = File(_eventProjectionHeadFile);
      _assertPrivateFilePath(
        metadataFile.path,
        boundary: _sessionDir.path,
        allowMissing: false,
      );
      _securePrivateFile(metadataFile.path, boundary: _sessionDir.path);
      if (!file.existsSync() ||
          metadataFile.lengthSync() > _maxEventHeadBytes) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'The Scout event projection checkpoint is incomplete.',
        );
      }
      final rows = _readLegacyEventRows(
        file,
        maxBytes: _maxEventProjectionBytes,
        maxRows: _maxEventProjectionRows,
      );
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(metadataFile.readAsBytesSync()));
      } catch (_) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'The Scout event projection checkpoint is not valid UTF-8 JSON.',
        );
      }
      if (decoded is! Map) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'The Scout event projection checkpoint is not an object.',
        );
      }
      final checkpoint = Map<String, Object?>.from(decoded);
      final encoded = rows.isEmpty
          ? ''
          : '${rows.map(jsonEncode).join('\n')}\n';
      final firstCursor = rows.isEmpty ? null : rows.first['eventCursor'];
      final lastCursor = rows.isEmpty ? null : rows.last['eventCursor'];
      if (checkpoint['schemaVersion'] != _eventJournalSchemaVersion ||
          checkpoint['lastOperationSequence'] != head.lastOperationSequence ||
          checkpoint['lastEventCursor'] != head.lastEventCursor ||
          checkpoint['projectionRowCount'] != rows.length ||
          checkpoint['projectionFirstEventCursor'] != firstCursor ||
          checkpoint['projectionLastEventCursor'] != lastCursor ||
          checkpoint['projectionSha256'] !=
              crypto.sha256.convert(utf8.encode(encoded)).toString()) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'The Scout event projection is stale relative to its durable head.',
        );
      }
      _cacheEventProjection(rows, head: head);
      return rows.toList(growable: true);
    } on ScoutCliException {
      final rows = _foldEventOperationsUnlocked();
      final retained =
          (rows.length > _maxEventProjectionRows
                  ? rows.sublist(rows.length - _maxEventProjectionRows)
                  : rows)
              .toList(growable: true);
      _writeEventProjectionUnlocked(retained, head: head);
      return retained;
    }
  }

  void _writeEventProjectionUnlocked(
    List<Map<String, Object?>> rows, {
    required _EventJournalHead head,
  }) {
    final retained = rows.length > _maxEventProjectionRows
        ? rows.sublist(rows.length - _maxEventProjectionRows)
        : rows;
    final encoded = retained.isEmpty
        ? ''
        : '${retained.map(jsonEncode).join('\n')}\n';
    _atomicWritePrivateDerivedString(
      _eventsFile,
      encoded,
      boundary: _sessionDir.path,
    );
    _atomicWritePrivateDerivedJson(_eventProjectionHeadFile, <String, Object?>{
      'schemaVersion': _eventJournalSchemaVersion,
      'kind': 'flutter_scout_event_projection_checkpoint',
      'lastOperationSequence': head.lastOperationSequence,
      'lastEventCursor': head.lastEventCursor,
      'projectionRowCount': retained.length,
      'projectionFirstEventCursor': retained.isEmpty
          ? null
          : retained.first['eventCursor'],
      'projectionLastEventCursor': retained.isEmpty
          ? null
          : retained.last['eventCursor'],
      'projectionSha256': crypto.sha256
          .convert(utf8.encode(encoded))
          .toString(),
    }, boundary: _sessionDir.path);
    _cacheEventProjection(retained, head: head);
  }

  void _cacheEventProjection(
    Iterable<Map<String, Object?>> rows, {
    required _EventJournalHead head,
  }) {
    _eventProjectionCacheSession = p.normalize(p.absolute(_sessionDir.path));
    _eventProjectionCacheSequence = head.lastOperationSequence;
    _eventProjectionCacheRows = <Map<String, Object?>>[
      for (final row in rows) Map<String, Object?>.from(row),
    ];
  }
}

class _EventJournalHead {
  const _EventJournalHead({
    this.lastOperationSequence = 0,
    this.lastEventCursor = 0,
    this.currentSegment = 1,
    this.currentSegmentOperations = 0,
    this.currentSegmentBytes = 0,
    this.lastOperationDigest,
    this.openReservations = const <int, String>{},
  });

  factory _EventJournalHead.fromJson(Map<String, Object?> value) {
    final schemaVersion = value['schemaVersion'];
    final lastOperationSequence = value['lastOperationSequence'];
    final lastEventCursor = value['lastEventCursor'];
    final currentSegment = value['currentSegment'];
    final currentSegmentOperations = value['currentSegmentOperations'];
    final currentSegmentBytes = value['currentSegmentBytes'];
    final lastOperationDigest = value['lastOperationDigest'];
    final rawOpen = value['openReservations'];
    if (schemaVersion != _eventJournalSchemaVersion ||
        lastOperationSequence is! int ||
        lastOperationSequence < 0 ||
        lastEventCursor is! int ||
        lastEventCursor < 0 ||
        currentSegment is! int ||
        currentSegment <= 0 ||
        currentSegmentOperations is! int ||
        currentSegmentOperations < 0 ||
        currentSegmentOperations > _maxEventOperationsPerSegment ||
        currentSegmentBytes is! int ||
        currentSegmentBytes < 0 ||
        currentSegmentBytes > _maxEventSegmentBytes ||
        (lastOperationDigest != null &&
            (lastOperationDigest is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(lastOperationDigest))) ||
        rawOpen is! Map ||
        rawOpen.length > _maxEventOpenReservations) {
      throw const ScoutCliException(
        'event_journal_corrupt',
        'The Scout event journal head has invalid bounded fields.',
      );
    }
    final open = <int, String>{};
    for (final entry in rawOpen.entries) {
      final cursor = int.tryParse(entry.key.toString());
      final commandId = entry.value;
      if (cursor == null ||
          cursor <= 0 ||
          cursor > lastEventCursor ||
          commandId is! String ||
          commandId.isEmpty ||
          commandId.length > 512) {
        throw const ScoutCliException(
          'event_journal_corrupt',
          'The Scout event journal head has an invalid reservation index.',
        );
      }
      open[cursor] = commandId;
    }
    return _EventJournalHead(
      lastOperationSequence: lastOperationSequence,
      lastEventCursor: lastEventCursor,
      currentSegment: currentSegment,
      currentSegmentOperations: currentSegmentOperations,
      currentSegmentBytes: currentSegmentBytes,
      lastOperationDigest: lastOperationDigest as String?,
      openReservations: open,
    );
  }

  final int lastOperationSequence;
  final int lastEventCursor;
  final int currentSegment;
  final int currentSegmentOperations;
  final int currentSegmentBytes;
  final String? lastOperationDigest;
  final Map<int, String> openReservations;

  _EventJournalHead copyWith({
    int? lastOperationSequence,
    int? lastEventCursor,
    int? currentSegment,
    int? currentSegmentOperations,
    int? currentSegmentBytes,
    Object? lastOperationDigest = _eventHeadUnset,
    Map<int, String>? openReservations,
  }) => _EventJournalHead(
    lastOperationSequence: lastOperationSequence ?? this.lastOperationSequence,
    lastEventCursor: lastEventCursor ?? this.lastEventCursor,
    currentSegment: currentSegment ?? this.currentSegment,
    currentSegmentOperations:
        currentSegmentOperations ?? this.currentSegmentOperations,
    currentSegmentBytes: currentSegmentBytes ?? this.currentSegmentBytes,
    lastOperationDigest: identical(lastOperationDigest, _eventHeadUnset)
        ? this.lastOperationDigest
        : lastOperationDigest as String?,
    openReservations: openReservations ?? this.openReservations,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': _eventJournalSchemaVersion,
    'kind': 'flutter_scout_segmented_event_journal_head',
    'lastOperationSequence': lastOperationSequence,
    'lastEventCursor': lastEventCursor,
    'currentSegment': currentSegment,
    'currentSegmentOperations': currentSegmentOperations,
    'currentSegmentBytes': currentSegmentBytes,
    'lastOperationDigest': lastOperationDigest,
    'openReservations': <String, Object?>{
      for (final entry in openReservations.entries)
        entry.key.toString(): entry.value,
    },
  };
}

const Object _eventHeadUnset = Object();

int _eventSegmentNumber(String path) =>
    int.parse(p.basename(path).substring('segment-'.length, 16));

String _eventOperationDigest(String line) =>
    crypto.sha256.convert(utf8.encode(line)).toString();
