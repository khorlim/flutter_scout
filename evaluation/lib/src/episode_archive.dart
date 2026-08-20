import 'dart:convert';
import 'dart:io';

import 'episode_result.dart';
import 'json_support.dart';

class RawEpisodeArchive {
  const RawEpisodeArchive(
    this.directory, {
    this.maximumEpisodeBytes = 16 * 1024 * 1024,
  }) : assert(maximumEpisodeBytes > 0);

  final Directory directory;
  final int maximumEpisodeBytes;

  Future<File> preserve(EpisodeResult episode) async {
    final archiveDirectory = await _preparePrivateArchiveDirectory(directory);
    final file = File('${archiveDirectory.path}/${episode.episodeId}.json');
    final bytes = utf8.encode(
      '${const JsonEncoder.withIndent('  ').convert(episode.toJson())}\n',
    );
    if (bytes.length > maximumEpisodeBytes) {
      throw StateError(
        'Raw episode `${episode.episodeId}` exceeds the '
        '$maximumEpisodeBytes-byte archive bound.',
      );
    }
    RandomAccessFile? handle;
    try {
      await file.create(exclusive: true);
      await _setPrivateMode(file.path, '600');
      handle = await file.open(mode: FileMode.writeOnly);
      await handle.writeFrom(bytes);
      await handle.flush();
      final committed = await file.stat();
      if (committed.type != FileSystemEntityType.file ||
          committed.size != bytes.length) {
        throw StateError(
          'Raw episode `${episode.episodeId}` was not committed exactly.',
        );
      }
      return file;
    } on FileSystemException {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError(
          'Raw episode `${episode.episodeId}` already exists and will not be '
          'overwritten.',
        );
      }
      rethrow;
    } finally {
      await handle?.close();
    }
  }

  Future<EpisodeResult> read(String episodeId) async {
    validateIdentifier(episodeId, 'episodeId');
    final archiveDirectory = await _requirePrivateArchiveDirectory(directory);
    final file = File('${archiveDirectory.path}/$episodeId.json');
    final bytes = await _readStablePrivateFile(file, maximumEpisodeBytes);
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    return EpisodeResult.fromJson(decoded);
  }
}

Future<Directory> _preparePrivateArchiveDirectory(Directory requested) async {
  final absolute = requested.absolute;
  final type = await FileSystemEntity.type(absolute.path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw StateError('Raw episode archive directory must not be a symlink.');
  }
  if (type == FileSystemEntityType.notFound) {
    final parentType = await FileSystemEntity.type(
      absolute.parent.path,
      followLinks: false,
    );
    if (parentType != FileSystemEntityType.directory) {
      throw StateError(
        'Raw episode archive parent must be an existing real directory.',
      );
    }
    final resolvedParent = Directory(
      await absolute.parent.resolveSymbolicLinks(),
    );
    final created = Directory(
      '${resolvedParent.path}${Platform.pathSeparator}${absolute.uri.pathSegments.last}',
    );
    await created.create();
    await _setPrivateMode(created.path, '700');
    return _requirePrivateArchiveDirectory(created);
  }
  if (type != FileSystemEntityType.directory) {
    throw StateError('Raw episode archive path must be a real directory.');
  }
  return _requirePrivateArchiveDirectory(absolute);
}

Future<Directory> _requirePrivateArchiveDirectory(Directory requested) async {
  final absolute = requested.absolute;
  final type = await FileSystemEntity.type(absolute.path, followLinks: false);
  if (type != FileSystemEntityType.directory) {
    throw StateError('Raw episode archive path must be a real directory.');
  }
  final resolved = Directory(await absolute.resolveSymbolicLinks());
  final resolvedType = await FileSystemEntity.type(
    resolved.path,
    followLinks: false,
  );
  if (resolvedType != FileSystemEntityType.directory) {
    throw StateError(
      'Raw episode archive path did not resolve to a directory.',
    );
  }
  if (!Platform.isWindows) {
    final mode = (await resolved.stat()).mode & 0x1ff;
    if ((mode & 0x3f) != 0) {
      throw StateError(
        'Raw episode archive directory must be owner-only (0700 or stricter).',
      );
    }
  }
  return resolved;
}

Future<List<int>> _readStablePrivateFile(File file, int maximumBytes) async {
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw StateError('Raw episode archive entry must be a regular file.');
  }
  final before = await file.stat();
  if (before.size <= 0 || before.size > maximumBytes) {
    throw StateError('Raw episode archive entry is outside its byte bound.');
  }
  if (!Platform.isWindows && ((before.mode & 0x1ff) & 0x3f) != 0) {
    throw StateError('Raw episode archive entry must be owner-only (0600).');
  }
  final bytes = <int>[];
  await for (final chunk in file.openRead()) {
    if (bytes.length + chunk.length > maximumBytes) {
      throw StateError('Raw episode archive entry grew beyond its byte bound.');
    }
    bytes.addAll(chunk);
  }
  final after = await file.stat();
  if (after.type != FileSystemEntityType.file ||
      before.size != after.size ||
      before.modified != after.modified ||
      before.changed != after.changed ||
      bytes.length != after.size) {
    throw StateError('Raw episode archive entry changed while it was read.');
  }
  return List<int>.unmodifiable(bytes);
}

Future<void> _setPrivateMode(String path, String mode) async {
  if (Platform.isWindows) return;
  final result = await Process.run('/bin/chmod', <String>[mode, path]);
  if (result.exitCode != 0) {
    throw StateError('Could not apply owner-only mode $mode to archive data.');
  }
  final expected = mode == '700' ? 0x1c0 : 0x180;
  final actual = (await FileStat.stat(path)).mode & 0x1ff;
  if (actual != expected) {
    throw StateError('Archive data did not retain owner-only mode $mode.');
  }
}
