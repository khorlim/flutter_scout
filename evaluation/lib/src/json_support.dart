import 'dart:convert';

Map<String, Object?> expectJsonObject(Object? value, String path) {
  if (value is! Map) {
    throw FormatException('$path must be a JSON object.');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$path contains a non-string key.');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

List<Object?> expectJsonList(Object? value, String path) {
  if (value is! List) {
    throw FormatException('$path must be a JSON array.');
  }
  return List<Object?>.from(value);
}

String expectJsonString(Object? value, String path, {bool nonEmpty = true}) {
  if (value is! String || (nonEmpty && value.trim().isEmpty)) {
    throw FormatException(
      '$path must be ${nonEmpty ? 'a non-empty ' : ''}string.',
    );
  }
  return value;
}

int expectJsonInt(Object? value, String path, {int? minimum}) {
  if (value is! int || (minimum != null && value < minimum)) {
    final suffix = minimum == null ? '' : ' greater than or equal to $minimum';
    throw FormatException('$path must be an integer$suffix.');
  }
  return value;
}

bool expectJsonBool(Object? value, String path) {
  if (value is! bool) {
    throw FormatException('$path must be a boolean.');
  }
  return value;
}

void rejectUnknownKeys(
  Map<String, Object?> value,
  Set<String> allowed,
  String path,
) {
  final unknown = value.keys.where((key) => !allowed.contains(key)).toList()
    ..sort();
  if (unknown.isNotEmpty) {
    throw FormatException(
      '$path contains unknown fields: ${unknown.join(', ')}.',
    );
  }
}

Map<String, Object?> deepCopyJsonObject(Map<String, Object?> value) {
  final decoded = jsonDecode(jsonEncode(value));
  return expectJsonObject(decoded, r'$');
}

List<Map<String, Object?>> deepCopyJsonEvents(
  Iterable<Map<String, Object?>> values,
) {
  return List<Map<String, Object?>>.unmodifiable(
    values.map(deepCopyJsonObject),
  );
}

Map<String, num> expectNumericMap(Object? value, String path) {
  final object = expectJsonObject(value, path);
  final result = <String, num>{};
  for (final entry in object.entries) {
    final number = entry.value;
    if (number is! num) {
      throw FormatException('$path.${entry.key} must be numeric.');
    }
    result[entry.key] = number;
  }
  return Map<String, num>.unmodifiable(result);
}

void validateIdentifier(String value, String path) {
  if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(value)) {
    throw FormatException(
      '$path must match ^[a-z0-9][a-z0-9._-]*\$; got `$value`.',
    );
  }
}
