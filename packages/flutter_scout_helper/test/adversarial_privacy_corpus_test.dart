import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'adversarial corpus is source-redacted across every helper artifact surface',
    (tester) async {
      FlutterScoutHelper.ensureRegistered();
      final runtime = FlutterScoutHelper.debugRuntime;
      if (runtime.debugIsRecording) {
        await runtime.debugStopRecording(discard: true);
      }

      final corpus = _PrivacyCorpus.load();
      final cases = corpus.cases;
      expect(
        cases.map((entry) => entry.category).toSet(),
        containsAll(<String>{
          'password',
          'pin',
          'passcode',
          'otp',
          'payment',
          'cvv',
          'token',
          'cookie',
          'session',
          'api_key',
          'bearer',
        }),
      );
      expect(
        cases.where((entry) => _hasAdversarialControl(entry.secret)),
        isNotEmpty,
      );

      final controllers = <String, TextEditingController>{
        for (final entry in cases) entry.key: TextEditingController(),
      };
      addTearDown(() {
        for (final controller in controllers.values) {
          controller.dispose();
        }
      });

      final temp = Directory.systemTemp.createTempSync(
        'scout_adversarial_helper_privacy_',
      );
      addTearDown(() {
        runtime.debugSetRecordingsRootOverride(null);
        runtime.debugSetRecordSettleMs(1500, 2200);
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      runtime.debugSetRecordingsRootOverride(temp.path);
      runtime.debugSetRecordSettleMs(0, 0);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: <Widget>[
                  Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 180,
                      child: ElevatedButton(
                        key: const ValueKey<String>('commit_privacy_corpus'),
                        onPressed: () {},
                        child: const Text('Commit corpus'),
                      ),
                    ),
                  ),
                  for (final entry in cases)
                    TextField(
                      key: ValueKey<String>(entry.key),
                      controller: controllers[entry.key],
                      obscureText: entry.obscureText,
                      decoration: InputDecoration(labelText: entry.label),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final captured = <String, Object?>{};
      captured['emptySnapshot'] = runtime.debugSnapshot().toJson();
      runtime.debugStartRecording(
        name: 'adversarial privacy corpus',
        feature: 'security',
      );

      for (final entry in cases) {
        controllers[entry.key]!.text = entry.secret;
      }
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('commit_privacy_corpus')),
      );
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final liveSteps = runtime.debugRecordSteps;
      final inputSteps = liveSteps
          .where((step) => step['cmd'] == 'input')
          .toList(growable: false);
      expect(inputSteps, hasLength(cases.length));
      for (final step in inputSteps) {
        expect(step['_redacted'], 'true');
        expect(step['_redactionPolicy'], 'source');
        expect(step['value'], startsWith('\u0000VAR:'));
      }
      captured['recorderDebugSteps'] = liveSteps;

      final stopResult = await tester.runAsync(runtime.debugStopRecording);
      expect(stopResult, isNotNull);
      expect(stopResult!['ok'], isTrue);
      expect(stopResult['persisted'], isTrue);
      captured['recorderStop'] = stopResult;

      final populated = runtime.debugSnapshot();
      captured['snapshotFull'] = populated.toJson();
      captured['snapshotSummary'] = populated.summaryJson();
      for (final entry in cases) {
        final field = populated.fields.singleWhere(
          (candidate) => candidate.key == entry.key,
        );
        final fieldJson = field.toJson();
        expect(field.redacted, isTrue, reason: entry.key);
        expect(field.value, isNull, reason: entry.key);
        expect(field.hasValue, isTrue, reason: entry.key);
        expect(field.isEmpty, isFalse, reason: entry.key);
        expect(fieldJson['redacted'], isTrue, reason: entry.key);
        expect(fieldJson.containsKey('value'), isFalse, reason: entry.key);
        expect(fieldJson.containsKey('length'), isFalse, reason: entry.key);
      }

      captured['inspectFull'] = runtime.debugInspectPayload();
      captured['inspectBrief'] = runtime.debugInspectPayload(
        brief: true,
        maxItems: cases.length + 10,
      );
      for (final section in <String>{
        'fields',
        'visualTree',
        'controlGroups',
        'rows',
        'semantics',
      }) {
        captured['inspectSection:$section'] = runtime.debugInspectPayload(
          sections: <String>{section},
        );
      }
      captured['annotationTargets'] = <Object?>[
        for (final target in runtime.debugVisibleAnnotationTargets())
          target.toJson(),
      ];
      captured['captureLegend'] = runtime.debugCaptureMarks().legend;

      final first = cases.first;
      final updatedSecret = '${first.secret}::ROTATED_PRIVATE_VALUE';
      final inputResult = await runtime.debugInputTarget(
        'field.${first.key}',
        updatedSecret,
      );
      expect(inputResult['ok'], isTrue);
      expect(
        ((inputResult['delta'] as Map)['changedFields'] as List<Object?>),
        contains('field.${first.key}'),
      );
      captured['beforeAfterDelta'] = inputResult;

      final expectation = await tester.runAsync(
        () => runtime.debugActionExpectation(<String, String>{
          'expectField': 'field.${first.key}=$updatedSecret',
          'expectTimeoutMs': '250',
        }),
      );
      expect(expectation, isNotNull);
      expect(expectation!['ok'], isTrue);
      final fieldCondition =
          ((expectation['expectation'] as Map)['conditions'] as Map)['field']
              as Map;
      expect(fieldCondition['redacted'], isTrue);
      expect(fieldCondition.containsKey('value'), isFalse);
      expect(fieldCondition.containsKey('length'), isFalse);
      captured['expectationEcho'] = expectation;

      runtime.debugRecordError(
        <String>[
          ...cases.map((entry) => entry.secret),
          updatedSecret,
        ].join('\nERROR_DELIMITER|'),
      );
      captured['errorInspect'] = runtime.debugInspectPayload(brief: true);

      final secrets = <String>[
        ...cases.map((entry) => entry.secret),
        updatedSecret,
      ];
      _expectLeakFree(captured, secrets, surface: 'helper captured JSON');
      _expectNoRedactedLengthDisclosure(captured);

      final recording = File(
        '${temp.path}/security/adversarial-privacy-corpus.json',
      );
      final index = File('${temp.path}/index.json');
      expect(recording.existsSync(), isTrue);
      expect(index.existsSync(), isTrue);
      final storedFlow = jsonDecode(recording.readAsStringSync()) as Map;
      final storedSteps = (storedFlow['steps'] as List)
          .whereType<Map>()
          .where((step) => step['cmd'] == 'input')
          .toList(growable: false);
      expect(storedSteps, hasLength(cases.length));
      for (final step in storedSteps) {
        expect(step['_redacted'], 'true');
        expect(step['_redactionPolicy'], 'source');
        expect(step['value'], startsWith('\u0000VAR:'));
      }
      expect(storedFlow['dataClassification'], 'private_application_data');
      expect(storedFlow['telemetryCollected'], isFalse);
      expect((storedFlow['retentionPolicy'] as Map)['policy'], 'manual');

      if (!Platform.isWindows) {
        expect(FileStat.statSync(temp.path).mode & 0x3f, 0);
        expect(FileStat.statSync(recording.path).mode & 0x3f, 0);
        expect(FileStat.statSync(index.path).mode & 0x3f, 0);
      }
      _expectDirectoryLeakFree(temp, secrets);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _PrivacyCase {
  const _PrivacyCase({
    required this.category,
    required this.label,
    required this.key,
    required this.obscureText,
    required this.secret,
  });

  final String category;
  final String label;
  final String key;
  final bool obscureText;
  final String secret;
}

class _PrivacyCorpus {
  const _PrivacyCorpus(this.cases);

  final List<_PrivacyCase> cases;

  static _PrivacyCorpus load() {
    final file = File(
      '${Directory.current.path}/../../security/adversarial_privacy_corpus.json',
    );
    expect(file.existsSync(), isTrue, reason: file.path);
    final root = jsonDecode(file.readAsStringSync()) as Map;
    expect(root['schemaVersion'], 1);
    final seed = root['seed']! as String;
    final categories = (root['categories']! as List).cast<Map>();
    final tricks = (root['payloadTricks']! as List).cast<String>();
    final cases = <_PrivacyCase>[];
    for (
      var categoryIndex = 0;
      categoryIndex < categories.length;
      categoryIndex++
    ) {
      final category = categories[categoryIndex];
      for (var trickIndex = 0; trickIndex < tricks.length; trickIndex++) {
        final id = category['id']! as String;
        final key =
            '${category['key']}_${trickIndex.toString().padLeft(2, '0')}';
        final paddingLength = (categoryIndex * 7 + trickIndex * 3) % 17;
        final padding = List<String>.filled(paddingLength, 'x').join();
        final trick = _decodeCorpusEscapes(tricks[trickIndex]);
        cases.add(
          _PrivacyCase(
            category: id,
            label: '${category['label']} ${trickIndex + 1}',
            key: key,
            obscureText: category['obscureText'] == true,
            secret:
                'SCOUT_PRIVATE_${seed}_${categoryIndex.toString().padLeft(2, '0')}_'
                '${trickIndex.toString().padLeft(2, '0')}_${id}_${padding}_$trick'
                '_PRIVATE_END',
          ),
        );
      }
    }
    return _PrivacyCorpus(cases);
  }
}

String _decodeCorpusEscapes(String value) => value
    .replaceAll(r'\u0000', '\u0000')
    .replaceAll(r'\u001f', '\u001f')
    .replaceAll(r'\u001b', '\u001b')
    .replaceAll(r'\u2028', '\u2028')
    .replaceAll(r'\u2029', '\u2029')
    .replaceAll(r'\r', '\r')
    .replaceAll(r'\n', '\n')
    .replaceAll(r'\t', '\t')
    .replaceAll(r'\"', '"')
    .replaceAll(r'\\', '\\');

bool _hasAdversarialControl(String value) => value.codeUnits.any(
  (unit) => unit < 0x20 || unit == 0x7f || unit == 0x2028 || unit == 0x2029,
);

Set<String> _secretVariants(String secret) {
  final jsonString = jsonEncode(secret);
  return <String>{
    secret,
    jsonString,
    if (jsonString.length >= 2) jsonString.substring(1, jsonString.length - 1),
    Uri.encodeComponent(secret),
    base64.encode(utf8.encode(secret)),
    base64Url.encode(utf8.encode(secret)),
    utf8
        .encode(secret)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(),
  }..removeWhere((variant) => variant.isEmpty);
}

void _expectLeakFree(
  Object? value,
  Iterable<String> secrets, {
  required String surface,
}) {
  final serialized = jsonEncode(value);
  for (final secret in secrets) {
    for (final variant in _secretVariants(secret)) {
      expect(
        serialized.contains(variant),
        isFalse,
        reason:
            '$surface leaked ${_variantName(secret, variant)} for a '
            '${secret.length}-code-unit secret',
      );
    }
  }
}

void _expectDirectoryLeakFree(Directory directory, Iterable<String> secrets) {
  final variants = <List<int>>[
    for (final secret in secrets)
      for (final variant in _secretVariants(secret)) utf8.encode(variant),
  ];
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) continue;
    final bytes = entity.readAsBytesSync();
    for (final needle in variants) {
      expect(
        _containsBytes(bytes, needle),
        isFalse,
        reason: 'secret representation leaked into ${entity.path}',
      );
    }
  }
}

bool _containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    var match = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (haystack[start + offset] != needle[offset]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

String _variantName(String secret, String variant) {
  if (variant == secret) return 'plaintext';
  if (variant == jsonEncode(secret)) return 'JSON string';
  if (variant == Uri.encodeComponent(secret)) return 'URI encoding';
  if (variant == base64.encode(utf8.encode(secret))) return 'Base64 encoding';
  if (variant == base64Url.encode(utf8.encode(secret))) {
    return 'Base64URL encoding';
  }
  return 'escaped or hexadecimal encoding';
}

void _expectNoRedactedLengthDisclosure(Object? value) {
  void visit(Object? child) {
    if (child is Map) {
      if (child['redacted'] == true || child['_redacted'] == 'true') {
        for (final forbidden in <String>{
          'valueLength',
          'length',
          'characterCount',
          'maskLength',
        }) {
          expect(child.containsKey(forbidden), isFalse, reason: '$child');
        }
        if (child['redacted'] == true) {
          expect(child.containsKey('value'), isFalse, reason: '$child');
        }
      }
      for (final nested in child.values) {
        visit(nested);
      }
    } else if (child is Iterable) {
      for (final nested in child) {
        visit(nested);
      }
    } else if (child is String) {
      expect(RegExp(r'[•●*]{4,}').hasMatch(child), isFalse);
    }
  }

  visit(value);
}
