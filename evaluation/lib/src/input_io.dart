import 'dart:io';

final class EvaluationInputException implements Exception {
  const EvaluationInputException(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<List<int>> readStableBoundedRegularFile(
  File file, {
  required int maximumBytes,
  bool allowEmpty = false,
}) async {
  if (maximumBytes <= 0) {
    throw ArgumentError.value(maximumBytes, 'maximumBytes');
  }
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type != FileSystemEntityType.file) {
    throw EvaluationInputException(
      'Input `${file.path}` must be a regular, non-symlink file.',
    );
  }
  final before = await file.stat();
  if ((!allowEmpty && before.size == 0) ||
      before.size < 0 ||
      before.size > maximumBytes) {
    throw EvaluationInputException(
      'Input `${file.path}` is outside its $maximumBytes-byte bound.',
    );
  }
  final bytes = <int>[];
  await for (final chunk in file.openRead()) {
    if (bytes.length + chunk.length > maximumBytes) {
      throw EvaluationInputException(
        'Input `${file.path}` grew beyond its $maximumBytes-byte bound.',
      );
    }
    bytes.addAll(chunk);
  }
  final after = await file.stat();
  if (after.type != FileSystemEntityType.file ||
      before.size != after.size ||
      before.modified != after.modified ||
      before.changed != after.changed ||
      bytes.length != after.size) {
    throw EvaluationInputException(
      'Input `${file.path}` changed while it was being read.',
    );
  }
  return List<int>.unmodifiable(bytes);
}
