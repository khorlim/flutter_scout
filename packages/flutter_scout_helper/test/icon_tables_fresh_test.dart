import 'dart:io';

import 'package:flutter_scout_helper/src/icon_names.g.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards against icon-table drift after a Flutter SDK upgrade: re-parses the
/// SDK's icon sources exactly like tool/gen_icon_names.dart and compares the
/// result with the committed lib/src/icon_names.g.dart. On failure, run:
///
///   dart run tool/gen_icon_names.dart
void main() {
  test('generated icon tables match the current Flutter SDK', () {
    // The test executable lives somewhere under the Flutter SDK
    // (bin/cache/...); walk up until the SDK layout appears. FLUTTER_ROOT
    // wins when set.
    String? flutterRoot = Platform.environment['FLUTTER_ROOT'];
    if (flutterRoot == null || flutterRoot.isEmpty) {
      var directory = File(Platform.resolvedExecutable).parent;
      for (var i = 0; i < 10; i++) {
        if (File(
          '${directory.path}/packages/flutter/lib/src/material/icons.dart',
        ).existsSync()) {
          flutterRoot = directory.path;
          break;
        }
        directory = directory.parent;
      }
    }
    final material = File(
      '$flutterRoot/packages/flutter/lib/src/material/icons.dart',
    );
    final cupertino = File(
      '$flutterRoot/packages/flutter/lib/src/cupertino/icons.dart',
    );
    if (flutterRoot == null ||
        !material.existsSync() ||
        !cupertino.existsSync()) {
      markTestSkipped(
        'Flutter SDK sources not found relative to '
        '${Platform.resolvedExecutable}; cannot verify icon tables.',
      );
      return;
    }

    final freshMaterial = _parse(material.readAsStringSync());
    final freshCupertino = _parse(
      cupertino.readAsStringSync(),
      preferLast: true,
    );

    expect(
      kMaterialIconNames.length,
      freshMaterial.length,
      reason:
          'Material icon table is stale for this SDK — '
          'run `dart run tool/gen_icon_names.dart` and commit the result.',
    );
    expect(
      kCupertinoIconNames.length,
      freshCupertino.length,
      reason:
          'Cupertino icon table is stale for this SDK — '
          'run `dart run tool/gen_icon_names.dart` and commit the result.',
    );
    // Spot-check content, not just size.
    for (final entry in freshMaterial.entries.take(50)) {
      expect(
        kMaterialIconNames[entry.key],
        entry.value,
        reason: 'Material codepoint ${entry.key} drifted — regenerate tables.',
      );
    }
    for (final entry in freshCupertino.entries.take(50)) {
      expect(
        kCupertinoIconNames[entry.key],
        entry.value,
        reason: 'Cupertino codepoint ${entry.key} drifted — regenerate tables.',
      );
    }
  });
}

// Mirrors tool/gen_icon_names.dart's parser; keep the two in sync.
Map<int, String> _parse(String source, {bool preferLast = false}) {
  final declaration = RegExp(
    r'static const IconData (\w+) = IconData\(\s*(0x[0-9a-fA-F]+)',
    multiLine: true,
  );
  final names = <int, String>{};
  for (final match in declaration.allMatches(source)) {
    final name = match
        .group(1)!
        .replaceFirst(RegExp(r'_(sharp|rounded|outlined)$'), '');
    final code = int.parse(match.group(2)!);
    if (preferLast) {
      names[code] = name;
    } else {
      names.putIfAbsent(code, () => name);
    }
  }
  return names;
}
