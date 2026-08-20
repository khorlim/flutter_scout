import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;

void main() {
  final root = p.normalize(p.join(Directory.current.path, '..', '..'));
  final schemaRoot = p.join(root, 'protocol', 'schemas', 'v1');
  final cli = FlutterScoutCli();
  final descriptors = cli.debugPersistentTypedMethodContract();

  final catalogFile = File(p.join(schemaRoot, 'persistent-methods.json'));
  final catalog =
      jsonDecode(catalogFile.readAsStringSync()) as Map<String, dynamic>;
  catalog
    ..['schemaVersion'] = 1
    ..['agentProtocolVersion'] = 2
    ..['contractKind'] = 'canonical_typed_persistent_methods'
    ..['legacyNamedOptionsInArgs'] = <String, Object?>{
      'accepted': true,
      'normalizedBeforeValidation': true,
      'removalRequiresAgentProtocolVersion': 3,
    }
    ..['methods'] = <String, Object?>{
      for (final entry in descriptors.entries)
        entry.key: ((entry.value as Map)['parameters'] as Map).keys.toList()
          ..sort(),
    }
    ..['methodDescriptors'] = descriptors;
  catalogFile.writeAsStringSync(_pretty(catalog));

  final schemaFile = File(p.join(schemaRoot, 'persistent-call.schema.json'));
  final schema =
      jsonDecode(schemaFile.readAsStringSync()) as Map<String, dynamic>;
  final properties = schema['properties'] as Map<String, dynamic>;
  final method = properties['method'] as Map<String, dynamic>;
  method['enum'] = descriptors.keys.toList()..sort();
  schema['oneOf'] = cli.debugPersistentCallDiscriminator()['oneOf'];
  schemaFile.writeAsStringSync(_pretty(schema));
}

String _pretty(Object? value) =>
    '${const JsonEncoder.withIndent('  ').convert(value)}\n';
