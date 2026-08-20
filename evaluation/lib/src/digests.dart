import 'dart:convert';

import 'package:crypto/crypto.dart';

String canonicalJsonEncode(Object? value) => jsonEncode(_canonicalize(value));

String sha256Text(String value) =>
    sha256.convert(utf8.encode(value)).toString();

String sha256Bytes(List<int> value) => sha256.convert(value).toString();

String jsonSha256(Object? value) => sha256Text(canonicalJsonEncode(value));

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) {
      if (key is! String) {
        throw FormatException('Canonical JSON objects require string keys.');
      }
      return key;
    }).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalize(value[key]),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) _canonicalize(item)];
  }
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  throw FormatException('`${value.runtimeType}` is not a JSON value.');
}
