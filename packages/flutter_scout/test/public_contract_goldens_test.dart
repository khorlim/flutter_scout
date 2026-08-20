import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:test/test.dart';

import 'public_contract_support.dart';

void main() {
  final packageRoot = Directory.current.path;
  final commandContract = readContractJson(
    packageRoot,
    '../../protocol/schemas/v1/public-cli-commands.json',
  );
  final errorContract = readContractJson(
    packageRoot,
    '../../protocol/schemas/v1/stable-errors.json',
  );
  final persistentContract = readContractJson(
    packageRoot,
    '../../protocol/schemas/v1/persistent-methods.json',
  );
  final helperResponseSchema = readContractJson(
    packageRoot,
    '../../protocol/schemas/v1/response.schema.json',
  );

  test('public command artifact matches production dispatch and transport', () {
    final commands = commandContract['commands']! as Map<String, dynamic>;
    expect(
      commandContract['artifactKind'],
      'flutter_scout_public_cli_command_contract',
    );
    expect(commandContract['schemaVersion'], 1);
    expect(commandContract['protocolVersion'], 15);
    expect(
      commands.keys.toList(),
      orderedEquals(commands.keys.toList()..sort()),
    );

    final shell = File('lib/src/flutter_scout_cli.dart').readAsStringSync();
    final commandBlock = RegExp(
      r'''static const Set<String> _commands = \{(.*?)\n  \};''',
      dotAll: true,
    ).firstMatch(shell);
    expect(commandBlock, isNotNull, reason: 'production _commands not found');
    final productionCommands = RegExp(r'''['"]([a-z][a-z0-9-]*)['"]''')
        .allMatches(commandBlock!.group(1)!)
        .map((match) => match.group(1)!)
        .toSet();
    expect(commands.keys.toSet(), productionCommands);

    final dispatchBlock = RegExp(
      r'''exitCode = await switch \(command\) \{(.*?)_ => _unknown\(command\),''',
      dotAll: true,
    ).firstMatch(shell);
    expect(dispatchBlock, isNotNull, reason: 'production dispatcher not found');
    final dispatched = RegExp(r'''['"]([a-z][a-z0-9-]*)['"]\s*=>''')
        .allMatches(dispatchBlock!.group(1)!)
        .map((match) => match.group(1)!)
        .toSet();
    expect(dispatched, containsAll(productionCommands));

    final persistent = (persistentContract['methods']! as Map<String, dynamic>)
        .keys
        .toSet();
    final declaredPersistent = <String>{
      for (final entry in commands.entries)
        if ((entry.value as Map)['persistentMethod'] == true) entry.key,
    };
    expect(declaredPersistent, persistent);
    expect(productionCommands, containsAll(persistent));

    final humanOnly = <String>{
      for (final entry in commands.entries)
        if ((entry.value as Map)['surface'] == 'human_prose') entry.key,
    };
    expect(humanOnly, <String>{'help'});
    expect((commandContract['humanOnlyInvocations']! as List).toSet(), <String>{
      '--help',
      '-h',
      'no-command',
    });
  });

  test('every source-emitted stable structured code has one fixed meaning', () {
    final errors = errorContract['errors']! as Map<String, dynamic>;
    final nonErrors =
        errorContract['nonErrorStructuredCodes']! as Map<String, dynamic>;
    expect(
      errorContract['artifactKind'],
      'flutter_scout_stable_structured_error_contract',
    );
    expect(errors.keys.toList(), orderedEquals(errors.keys.toList()..sort()));
    expect(
      nonErrors.keys.toList(),
      orderedEquals(nonErrors.keys.toList()..sort()),
    );
    expect(errors.keys.toSet().intersection(nonErrors.keys.toSet()), isEmpty);
    for (final entry in errors.entries) {
      expect(entry.key, matches(RegExp(r'^[a-z][a-z0-9_]*$')));
      final definition = entry.value as Map;
      expect(definition['meaning'], isA<String>());
      expect((definition['meaning']! as String).trim(), isNotEmpty);
      expect((definition['meaning']! as String).length, lessThanOrEqualTo(320));
      expect(definition['family'], isA<String>());
    }

    final emitted = _sourceStructuredCodes(packageRoot, errorContract);
    final declared = <String>{...errors.keys, ...nonErrors.keys};
    expect(
      declared,
      emitted,
      reason:
          'A source-emitted code was added/removed, or a checked-in stable '
          'meaning no longer has an emission site. '
          'uncatalogued=${emitted.difference(declared).toList()..sort()}; '
          'withoutEmission=${declared.difference(emitted).toList()..sort()}',
    );
  });

  test('every public command and stable error matches its bounded golden', () {
    final expected = readContractJson(
      packageRoot,
      'test/goldens/public-contract-envelopes.v1.json',
    );
    final current = buildPublicContractGoldens(packageRoot);
    expect(current, expected);

    final commandRows = (current['commands']! as List).cast<Map>();
    expect(
      commandRows.map((row) => row['command']).toSet(),
      (commandContract['commands']! as Map).keys.toSet(),
    );
    for (final row in commandRows) {
      final envelope = row['canonicalEnvelope'];
      if (row['surface'] == 'human_prose') {
        expect(row['command'], 'help');
        expect(envelope, isNull);
        continue;
      }
      _expectBoundedCanonicalEnvelope(envelope! as Map, ok: true);
      expect((envelope['result'] as Map)['command'], row['command']);
    }

    final errorRows = (current['errors']! as List).cast<Map>();
    expect(
      errorRows.map((row) => row['code']).toSet(),
      (errorContract['errors']! as Map).keys.toSet(),
    );
    for (final row in errorRows) {
      final envelope = row['canonicalEnvelope']! as Map;
      _expectBoundedCanonicalEnvelope(envelope, ok: false);
      final structured = envelope['structuredError']! as Map;
      expect(structured['code'], row['code']);
      expect(structured['message'], row['meaning']);
      expect(envelope['result'], isNull);
    }
  });

  test(
    'additive response tolerance and required-field rejection stay live',
    () {
      expect(
        helperResponseSchema['additionalProperties'],
        isNot(false),
        reason: 'unknown optional response fields are additive in schema v1',
      );
      final cli = FlutterScoutCli();
      final additive = _compatibleHelperEnvelope()
        ..['futureOptionalField'] = const <String, Object?>{
          'introducedBy': 'future-compatible-helper',
        };
      expect(
        cli.debugValidateHelperProtocolEnvelope(additive),
        containsPair('compatible', true),
      );

      final required = (helperResponseSchema['required']! as List)
          .cast<String>();
      for (final field in required) {
        final missing = _compatibleHelperEnvelope()..remove(field);
        expect(
          cli.debugValidateHelperProtocolEnvelope(missing)['compatible'],
          isFalse,
          reason: 'missing required field `$field` must be rejected',
        );
      }
    },
  );
}

Set<String> _sourceStructuredCodes(
  String packageRoot,
  Map<String, dynamic> errorContract,
) {
  final source = StringBuffer();
  for (final relative in const <String>[
    'lib/src',
    '../../packages/flutter_scout_helper/lib/src',
  ]) {
    final directory = Directory('$packageRoot/$relative');
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      source
        ..writeln(file.path)
        ..writeln(file.readAsStringSync());
    }
  }
  final text = source.toString();
  final codes = <String>{};
  void collect(RegExp pattern, [int group = 1]) {
    for (final match in pattern.allMatches(text)) {
      codes.add(match.group(group)!);
    }
  }

  void collectLiteralExpressions(RegExp pattern) {
    for (final expression in pattern.allMatches(text)) {
      for (final literal in RegExp(
        r'''[rR]?['"]([a-z][a-z0-9_]*)['"]''',
      ).allMatches(expression.group(1)!)) {
        codes.add(literal.group(1)!);
      }
    }
  }

  collect(
    RegExp(
      r'''(?:ScoutCliException|_TypedContractIssue|_writeStructuredError|_fail|_protocolFail|_typedRequestError)\s*\(\s*[rR]?['"]([a-z0-9_]+)['"]''',
      dotAll: true,
    ),
  );
  collect(
    RegExp(
      r'''_ServeRequestException\s*\(\s*[^,]+,\s*[rR]?['"]([a-z0-9_]+)['"]''',
      dotAll: true,
    ),
  );
  collect(
    RegExp(
      r'''(?:['"]code['"]|\bcode|\berrorCode|\bfailureCode)\s*:\s*[rR]?['"]([a-z0-9_]+)['"]''',
      dotAll: true,
    ),
  );
  collect(
    RegExp(
      r'''return\s*\(\s*[rR]?['"]([a-z0-9_]+)['"]\s*,\s*[rR]?['"]''',
      dotAll: true,
    ),
  );
  // Capture every literal branch of conditional code expressions, not only
  // the first token after `code:`. This makes adding a ternary/switch outcome
  // fail the catalog test instead of bypassing it.
  collectLiteralExpressions(
    RegExp(
      r'''['"]code['"]\s*:\s*([^,]{0,1024}),\s*['"]message['"]\s*:''',
      dotAll: true,
    ),
  );
  collectLiteralExpressions(
    RegExp(r'''\bcode\s*:\s*([^,]{0,1024}),\s*message\s*:''', dotAll: true),
  );
  collectLiteralExpressions(
    RegExp(
      r'''\berrorCode\s*:\s*([^,]{0,1024}),\s*(?:errorMessage|reason)\s*:''',
      dotAll: true,
    ),
  );
  collectLiteralExpressions(
    RegExp(
      r'''(?:ScoutCliException|_TypedContractIssue|_fail|_protocolFail|_typedRequestError)\s*\(\s*([^,]{0,512}\?[^,]{0,512}),''',
      dotAll: true,
    ),
  );
  for (final codeSwitch in RegExp(
    r'''final code = switch \([^)]*\) \{(.*?)\n\s*\};''',
    dotAll: true,
  ).allMatches(text)) {
    for (final branch in RegExp(
      r'''=>\s*['"]([a-z0-9_]+)['"]''',
    ).allMatches(codeSwitch.group(1)!)) {
      codes.add(branch.group(1)!);
    }
  }

  for (final rawFamily in errorContract['dynamicFamilies']! as List) {
    final family = rawFamily as Map;
    final template = family['sourceTemplate']! as String;
    if (family['actionValues'] case final List values) {
      expect(
        text,
        contains(template),
        reason: 'missing dynamic source `$template`',
      );
      for (final action in values.cast<String>()) {
        codes.add(template.replaceAll(r'${action}', action));
      }
    }
    if (family['explicitCodes'] case final List explicit) {
      for (final code in explicit.cast<String>()) {
        expect(
          text,
          contains("'$code'"),
          reason: 'missing source code `$code`',
        );
        codes.add(code);
      }
    }
  }
  // These are map/parameter field names that can occur inside a nested first
  // argument expression; they are not emitted error values.
  codes.removeAll(const <String>{
    'ambiguous',
    'code',
    'deeplink_not_dispatched',
    'message',
    'reason',
    'rejected',
  });
  return codes;
}

void _expectBoundedCanonicalEnvelope(Map envelope, {required bool ok}) {
  expect(envelope.keys.toList(), canonicalCliEnvelopeKeys);
  expect(envelope['ok'], ok);
  expect(envelope['schemaVersion'], 1);
  expect(envelope['protocolVersion'], 15);
  final bounds = envelope['payloadBounds']! as Map;
  expect(bounds['maxSerializedBytes'], 4 * 1024 * 1024);
  expect(bounds['maxStringCharacters'], 65536);
  expect(bounds['maxCollectionEntries'], 1024);
  expect(bounds['maxDepth'], 24);
  expect(bounds['truncated'], isFalse);
  expect(bounds['safetyDisposition'], 'complete');
  expect(
    utf8.encode(jsonEncode(envelope)).length,
    lessThanOrEqualTo(bounds['maxSerializedBytes']! as int),
  );
  expect(envelope['structuredError'], ok ? isNull : isA<Map>());
}

Map<String, dynamic> _compatibleHelperEnvelope() {
  const phases = <String>[
    'connect',
    'snapshot',
    'match',
    'dispatch',
    'settle',
    'delta',
    'logs',
    'serialize',
  ];
  return <String, dynamic>{
    'ok': true,
    'schemaVersion': 1,
    'protocolVersion': 15,
    'minSupportedProtocolVersion': 15,
    'maxSupportedProtocolVersion': 15,
    'capabilities': const <String, bool>{
      'typedEnvelopeV1': true,
      'stateGeneration': true,
      'stateDigestSha256': true,
      'strictMutationEnvelope': true,
      'serializedMutations': true,
      'idempotentMutations': true,
      'stableIdempotencyFingerprintV1': true,
      'idempotencyTombstonesV1': true,
      'runtimeErrorCursor': true,
      'heldDragExclusion': true,
      'sourceRedaction': true,
      'phaseTimingsV1': true,
    },
    'commandId': 'public-contract-command',
    'runId': 'public-contract-run',
    'runtimeInstanceId': 'public-contract-runtime',
    'stateGeneration': 7,
    'result': const <String, Object?>{},
    'structuredError': null,
    'errorCursor': 0,
    'errorsSinceCursor': const <Object?>[],
    'activeBlockingSignals': const <Object?>[],
    'timings': <String, Object?>{
      'totalMs': 0,
      'status': 'partial',
      'phases': <String, Object?>{
        for (final phase in phases)
          phase: <String, Object?>{
            'status': phase == 'snapshot' || phase == 'serialize'
                ? 'measured'
                : 'unavailable',
            'elapsedMs': phase == 'snapshot' || phase == 'serialize' ? 0 : null,
            'owner': const <String>{'connect', 'logs'}.contains(phase)
                ? 'cli'
                : 'helper',
            if (phase != 'snapshot' && phase != 'serialize')
              'reason': 'not_applicable_for_contract_read',
          },
      },
    },
  };
}
