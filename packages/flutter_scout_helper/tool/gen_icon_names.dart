// Generates lib/src/icon_names.g.dart: codepoint -> icon-name lookup tables
// for Material and Cupertino icons, parsed from the Flutter SDK sources.
//
// Run from the package root whenever the Flutter SDK is upgraded:
//
//   dart run tool/gen_icon_names.dart
//
// The tables let the runtime name icon-only controls (btn.settings,
// btn.person_badge_plus) instead of surfacing anonymous handles like
// btn.cupertinobutton_2.
import 'dart:io';

void main(List<String> args) {
  final flutterRoot = args.isNotEmpty
      ? args.first
      : Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot == null || flutterRoot.isEmpty) {
    stderr.writeln(
      'Pass the Flutter SDK root as the first argument or set FLUTTER_ROOT.',
    );
    exit(64);
  }
  final materialSource = File(
    '$flutterRoot/packages/flutter/lib/src/material/icons.dart',
  );
  final cupertinoSource = File(
    '$flutterRoot/packages/flutter/lib/src/cupertino/icons.dart',
  );
  final material = _parse(materialSource.readAsStringSync());
  // Cupertino declares MaterialCommunity-era aliases first and the canonical
  // SF-Symbols-style names later in the file (person_add -> person_badge_plus),
  // so for duplicate codepoints the LAST declaration is the canonical name.
  // Material is alphabetical; the first name is as canonical as any.
  final cupertino = _parse(
    cupertinoSource.readAsStringSync(),
    preferLast: true,
  );

  final buffer = StringBuffer()
    ..writeln('// GENERATED FILE — do not edit by hand.')
    ..writeln('// Regenerate with: dart run tool/gen_icon_names.dart')
    ..writeln('//')
    ..writeln('// Codepoint -> icon-name lookups parsed from the Flutter SDK,')
    ..writeln('// used to label icon-only controls in inspect output.')
    ..writeln()
    ..writeln('/// Material icon glyph names by codepoint.')
    ..writeln('const Map<int, String> kMaterialIconNames = <int, String>{');
  material.forEach((code, name) {
    buffer.writeln("  $code: '$name',");
  });
  buffer
    ..writeln('};')
    ..writeln()
    ..writeln('/// Cupertino icon glyph names by codepoint.')
    ..writeln('const Map<int, String> kCupertinoIconNames = <int, String>{');
  cupertino.forEach((code, name) {
    buffer.writeln("  $code: '$name',");
  });
  buffer.writeln('};');

  final output = File('lib/src/icon_names.g.dart')
    ..writeAsStringSync(buffer.toString());
  stdout.writeln(
    'Wrote ${output.path}: ${material.length} material, '
    '${cupertino.length} cupertino entries.',
  );
}

Map<int, String> _parse(String source, {bool preferLast = false}) {
  // Handles both single-line and wrapped declarations:
  //   static const IconData ten_k = IconData(0xe000, ...);
  //   static const IconData left_chevron = IconData(\n    0xf3d2, ...);
  final declaration = RegExp(
    r'static const IconData (\w+) = IconData\(\s*(0x[0-9a-fA-F]+)',
    multiLine: true,
  );
  final names = <int, String>{};
  for (final match in declaration.allMatches(source)) {
    final name = _baseName(match.group(1)!);
    final code = int.parse(match.group(2)!);
    // Variants (sharp/rounded/outlined) have distinct codepoints and all get
    // their base name. For aliases sharing a codepoint, [preferLast] picks
    // whether the first or last declaration wins.
    if (preferLast) {
      names[code] = name;
    } else {
      names.putIfAbsent(code, () => name);
    }
  }
  return names;
}

String _baseName(String name) {
  return name.replaceFirst(RegExp(r'_(sharp|rounded|outlined)$'), '');
}
