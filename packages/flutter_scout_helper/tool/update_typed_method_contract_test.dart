import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('update checked-in helper typed-method catalog', () {
    final runtime = FlutterScoutRuntime();
    // This source-contract generator intentionally reads the same test seam as
    // the parity suite; it never ships in the helper library.
    // ignore: invalid_use_of_visible_for_testing_member
    final contract = runtime.debugProtocolParameterContract();
    final file = File(
      '${Directory.current.path}/../../protocol/schemas/v1/helper-methods.json',
    );
    final catalog = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    catalog
      ..['contractKind'] = 'canonical_typed_helper_methods'
      ..['commonParameterDescriptors'] = contract['commonParameterDescriptors']
      ..['methods'] = contract['methods'];
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(catalog)}\n',
    );
  });
}
