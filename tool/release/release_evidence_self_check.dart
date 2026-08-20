import 'dart:convert';
import 'dart:io';

import 'release_evidence.dart';

Future<void> main() async {
  _expect(
    sha256Bytes(const <int>[]) ==
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    'SHA-256 empty vector',
  );
  _expect(
    sha256Bytes(utf8.encode('abc')) ==
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    'SHA-256 abc vector',
  );

  final sandbox = Directory.systemTemp.createTempSync(
    'flutter_scout_release_evidence_self_check.',
  );
  try {
    final repository = Directory('${sandbox.path}/repository')..createSync();
    Directory('${repository.path}/.git').createSync();
    Directory(
      '${repository.path}/.github/workflows',
    ).createSync(recursive: true);
    Directory(
      '${repository.path}/protocol/schemas/v1',
    ).createSync(recursive: true);
    Directory(
      '${repository.path}/packages/example',
    ).createSync(recursive: true);
    Directory(
      '${repository.path}/packages/flutter_scout/lib/src',
    ).createSync(recursive: true);
    Directory(
      '${repository.path}/packages/flutter_scout_helper/lib/src',
    ).createSync(recursive: true);
    Directory('${repository.path}/tool/release').createSync(recursive: true);
    for (final name in const <String>[
      'QUALITY_STANDARD.md',
      'RELEASING.md',
      'SECURITY.md',
    ]) {
      File('${repository.path}/$name').writeAsStringSync('$name\n');
    }
    File('${repository.path}/COMPATIBILITY.md').writeAsStringSync('''
# Compatibility

## Upgrade procedure

Upgrade safely.

## Downgrade and rollback compatibility

Downgrade safely.
''');
    File('${repository.path}/protocol/CHANGELOG.md').writeAsStringSync('''
## Unreleased

- Align schema-1 and protocol 15.
''');
    File(
      '${repository.path}/protocol/compatibility-matrix.v1.json',
    ).writeAsStringSync(
      '${jsonEncode(<String, Object?>{
        'evidenceScope': <String, Object?>{'releaseRatified': false},
        'currentContract': <String, Object?>{
          'cliPackage': <String, Object?>{'name': 'flutter_scout', 'version': '2.0.0-dev.1'},
          'helperPackage': <String, Object?>{'name': 'flutter_scout_helper', 'version': '0.2.0-dev.1'},
          'schemaVersion': 1,
          'protocolVersion': 15,
          'cliSupportedProtocolRange': <String, int>{'minimum': 15, 'maximum': 15},
          'helperSupportedProtocolRange': <String, int>{'minimum': 15, 'maximum': 15},
        },
      })}\n',
    );
    File(
      '${repository.path}/.github/workflows/ci.yml',
    ).writeAsStringSync("flutter-version: '3.44.2'\n");
    File(
      '${repository.path}/protocol/schemas/v1/response.schema.json',
    ).writeAsStringSync(
      '{"\$schema":"https://json-schema.org/draft/2020-12/schema",'
      '"\$id":"https://flutter-scout.dev/protocol/schemas/v1/response.schema.json",'
      '"properties":{"capabilities":{"required":'
      '["typedEnvelopeV1","stateGeneration"]}}}\n',
    );
    File(
      '${repository.path}/packages/flutter_scout/lib/src/cli_protocol.dart',
    ).writeAsStringSync('''
const int _scoutCliSchemaVersion = 1;
const int _scoutCliProtocolMin = 15;
const int _scoutCliProtocolMax = 15;
''');
    File(
      '${repository.path}/packages/flutter_scout_helper/lib/src/'
      'flutter_scout_binding.dart',
    ).writeAsStringSync('''
const int scoutHelperProtocolVersion = 15;
const int scoutHelperMinSupportedProtocolVersion = 15;
const int scoutHelperMaxSupportedProtocolVersion = 15;
const int scoutHelperSchemaVersion = 1;
''');
    File(
      '${repository.path}/packages/flutter_scout_helper/lib/src/'
      'runtime_protocol.dart',
    ).writeAsStringSync('protocol runtime\n');
    File(
      '${repository.path}/packages/flutter_scout/pubspec.yaml',
    ).writeAsStringSync('''
name: flutter_scout
version: 2.0.0-dev.1
environment:
  sdk: ^3.12.2
''');
    File(
      '${repository.path}/packages/flutter_scout/CHANGELOG.md',
    ).writeAsStringSync('''
## Unreleased

- Align candidate 2.0.0-dev.1.
''');
    File(
      '${repository.path}/packages/flutter_scout_helper/pubspec.yaml',
    ).writeAsStringSync('''
name: flutter_scout_helper
version: 0.2.0-dev.1
environment:
  sdk: ^3.12.2
''');
    File(
      '${repository.path}/packages/flutter_scout_helper/CHANGELOG.md',
    ).writeAsStringSync('''
## Unreleased

- Align candidate 0.2.0-dev.1.
''');
    File('${repository.path}/packages/example/pubspec.yaml').writeAsStringSync(
      '''
name: example
version: 1.2.3
environment:
  sdk: ^3.12.2
''',
    );
    File(
      '${repository.path}/packages/example/CHANGELOG.md',
    ).writeAsStringSync('## Unreleased\n');
    File('${repository.path}/packages/example/pubspec.lock').writeAsStringSync(
      '''
packages:
  alpha:
    dependency: "direct main"
    description:
      name: alpha
      sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      url: "https://pub.dev"
    source: hosted
    version: "1.0.0"
  beta:
    dependency: transitive
    description:
      path: "../beta"
      relative: true
    source: path
    version: "2.0.0"
sdks:
  dart: ">=3.12.2 <4.0.0"
''',
    );
    File(
      '${repository.path}/tool/release/generate_release_evidence.dart',
    ).writeAsStringSync('generator\n');
    File(
      '${repository.path}/tool/release/release_evidence.dart',
    ).writeAsStringSync('library\n');
    File(
      '${repository.path}/tool/release/release_contract.dart',
    ).writeAsStringSync('contract library\n');
    File(
      '${repository.path}/tool/release/release-contracts.v1.json',
    ).writeAsStringSync('${jsonEncode(_contractCatalogFixture())}\n');
    final artifact = File('${sandbox.path}/example.tar.gz')
      ..writeAsBytesSync(utf8.encode('artifact'));

    Future<ReleaseProbeResult> fakeRunner(
      String executable,
      List<String> arguments,
      String workingDirectory,
    ) async {
      final command = '$executable ${arguments.join(' ')}';
      return switch (command) {
        'git rev-parse HEAD' => const ReleaseProbeResult(
          exitCode: 0,
          stdout: '1111111111111111111111111111111111111111\n',
          stderr: '',
        ),
        'git rev-parse HEAD^{tree}' => const ReleaseProbeResult(
          exitCode: 0,
          stdout: '2222222222222222222222222222222222222222\n',
          stderr: '',
        ),
        'git status --porcelain=v1 --untracked-files=all' =>
          const ReleaseProbeResult(exitCode: 0, stdout: '', stderr: ''),
        'git show -s --format=%ct HEAD' => const ReleaseProbeResult(
          exitCode: 0,
          stdout: '1700000000\n',
          stderr: '',
        ),
        'dart --version' => const ReleaseProbeResult(
          exitCode: 0,
          stdout: '',
          stderr: 'Dart SDK version: 3.12.2 (stable)',
        ),
        'flutter --version --machine' => const ReleaseProbeResult(
          exitCode: 0,
          stdout:
              '{"frameworkVersion":"3.44.2","channel":"stable",'
              '"frameworkRevision":"abc","engineRevision":"def",'
              '"dartSdkVersion":"3.12.2"}',
          stderr: '',
        ),
        'uname -m' => const ReleaseProbeResult(
          exitCode: 0,
          stdout: 'arm64\n',
          stderr: '',
        ),
        _ => ReleaseProbeResult(
          exitCode: 127,
          stdout: '',
          stderr: 'unexpected command: $command in $workingDirectory',
        ),
      };
    }

    final generator = ReleaseEvidenceGenerator(
      repository: repository,
      commandRunner: fakeRunner,
      environment: const <String, String>{},
      operatingSystem: 'test-os',
      operatingSystemVersion: 'test-os 1',
      dartRuntimeVersion: 'test-dart-runtime',
    );
    final outputA = Directory('${sandbox.path}/evidence-a');
    final outputB = Directory('${sandbox.path}/evidence-b');
    final outputC = Directory('${sandbox.path}/evidence-c');
    final outputD = Directory('${sandbox.path}/evidence-d');
    final artifactInput = ReleaseArtifact(
      name: 'example.tar.gz',
      file: artifact,
    );
    await generator.generate(
      outputDirectory: outputA,
      artifacts: <ReleaseArtifact>[artifactInput],
      sourceDateEpoch: 1700000000,
    );
    await generator.generate(
      outputDirectory: outputB,
      artifacts: <ReleaseArtifact>[artifactInput],
      sourceDateEpoch: 1700000000,
    );
    await generator.generate(
      outputDirectory: outputC,
      artifacts: <ReleaseArtifact>[artifactInput],
      sourceDateEpoch: 1700000000,
    );
    await generator.generate(
      outputDirectory: outputD,
      artifacts: <ReleaseArtifact>[artifactInput],
      sourceDateEpoch: 1700000000,
    );

    final namesA =
        outputA.listSync().map((entity) => _name(entity.path)).toList()..sort();
    final namesB =
        outputB.listSync().map((entity) => _name(entity.path)).toList()..sort();
    _expect(
      jsonEncode(namesA) == jsonEncode(namesB),
      'deterministic filenames',
    );
    for (final name in namesA) {
      final left = File('${outputA.path}/$name').readAsBytesSync();
      final right = File('${outputB.path}/$name').readAsBytesSync();
      _expect(
        sha256Bytes(left) == sha256Bytes(right),
        'deterministic content for $name',
      );
    }

    final inventory =
        jsonDecode(
              File(
                '${outputA.path}/dependency-inventory.cdx.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final components = inventory['components']! as List<dynamic>;
    _expect(components.length == 2, 'lockfile components are inventoried');
    _expect(
      components.any((entry) => (entry as Map)['name'] == 'alpha'),
      'hosted dependency is inventoried',
    );
    _expect(
      components.any((entry) => (entry as Map)['name'] == 'beta'),
      'path dependency is inventoried',
    );
    final sbom =
        jsonDecode(
              File(
                '${outputA.path}/dependency-sbom.cdx.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    _expect(
      sbom[r'$schema'] == 'http://cyclonedx.org/schema/bom-1.5.schema.json' &&
          sbom['bomFormat'] == 'CycloneDX' &&
          sbom['specVersion'] == '1.5',
      'CycloneDX 1.5 SBOM is emitted',
    );
    _expect(
      ((sbom['compositions'] as List).single as Map)['aggregate'] ==
          'incomplete',
      'SBOM incompleteness is explicit',
    );
    final signing =
        jsonDecode(
              File(
                '${outputA.path}/signing-verification.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    _expect(
      (signing['signature'] as Map)['state'] == 'not_performed' &&
          signing['releaseEligibilityEstablished'] == false,
      'generation cannot claim a signature',
    );
    final rollback =
        jsonDecode(
              File('${outputA.path}/rollback-plan.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    _expect(
      (rollback['exercise'] as Map)['state'] == 'not_exercised',
      'generation cannot claim a rollback exercise',
    );

    final verified = await generator.verify(
      evidenceDirectory: outputA,
      artifacts: <String, File>{'example.tar.gz': artifact},
    );
    _expect(verified.ok, 'fresh evidence verifies: ${verified.errors}');

    final alignmentFile = File('${outputB.path}/release-alignment.json');
    final alteredAlignment =
        jsonDecode(alignmentFile.readAsStringSync()) as Map<String, dynamic>;
    alteredAlignment['sourceIntentAligned'] = false;
    alignmentFile.writeAsStringSync('${jsonEncode(alteredAlignment)}\n');
    _rewriteManifestDigest(outputB, 'release-alignment.json');
    final semanticallyTampered = await generator.verify(
      evidenceDirectory: outputB,
      artifacts: <String, File>{'example.tar.gz': artifact},
    );
    _expect(
      !semanticallyTampered.ok &&
          semanticallyTampered.errors.any(
            (error) => error.contains('release-alignment.json'),
          ),
      'semantic tampering is detected after outer checksums are recomputed',
    );

    final signingFile = File('${outputC.path}/signing-verification.json');
    final falseSigningClaim =
        jsonDecode(signingFile.readAsStringSync()) as Map<String, dynamic>;
    (falseSigningClaim['signature'] as Map<String, dynamic>)['state'] =
        'verified';
    falseSigningClaim['releaseEligibilityEstablished'] = true;
    signingFile.writeAsStringSync('${jsonEncode(falseSigningClaim)}\n');
    _rewriteManifestDigest(outputC, 'signing-verification.json');
    final falseSignature = await generator.verify(
      evidenceDirectory: outputC,
      artifacts: <String, File>{'example.tar.gz': artifact},
    );
    _expect(
      !falseSignature.ok &&
          falseSignature.errors.any((error) => error.contains('signing')),
      'a rechecksummed false signature claim is rejected',
    );

    final rollbackFile = File('${outputD.path}/rollback-plan.json');
    final falseRollbackClaim =
        jsonDecode(rollbackFile.readAsStringSync()) as Map<String, dynamic>;
    (falseRollbackClaim['exercise'] as Map<String, dynamic>)['state'] =
        'passed';
    falseRollbackClaim['releaseEligibilityEstablished'] = true;
    rollbackFile.writeAsStringSync('${jsonEncode(falseRollbackClaim)}\n');
    _rewriteManifestDigest(outputD, 'rollback-plan.json');
    final falseRollback = await generator.verify(
      evidenceDirectory: outputD,
      artifacts: <String, File>{'example.tar.gz': artifact},
    );
    _expect(
      !falseRollback.ok &&
          falseRollback.errors.any((error) => error.contains('rollback')),
      'a rechecksummed false rollback claim is rejected',
    );

    artifact.writeAsStringSync('tampered');
    final tampered = await generator.verify(
      evidenceDirectory: outputA,
      artifacts: <String, File>{'example.tar.gz': artifact},
    );
    _expect(
      !tampered.ok &&
          tampered.errors.any((error) => error.contains('artifact checksum')),
      'artifact tampering is detected',
    );
  } finally {
    sandbox.deleteSync(recursive: true);
  }
  stdout.writeln('release evidence self-check: PASS');
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('self-check failed: $message');
}

String _name(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.substring(normalized.lastIndexOf('/') + 1);
}

Map<String, Object?> _contractCatalogFixture() => <String, Object?>{
  'artifactKind': 'flutter_scout_release_evidence_contract_catalog',
  'formatVersion': 1,
  'qualification': 'self-check fixture; does not establish eligibility',
  'requiredEvidenceFiles': <Map<String, String>>[
    for (final entry in const <(String, String)>[
      ('artifact-checksums.sha256', 'sha256sum-lines-v1'),
      ('artifacts.json', 'artifact-digests-v1'),
      ('dependency-inventory.cdx.json', 'offline-lockfile-inventory-v1'),
      ('dependency-sbom.cdx.json', 'cyclonedx-v1'),
      ('provenance-statement.intoto.json', 'slsa-v1'),
      ('provenance.json', 'provenance-v1'),
      ('release-alignment.json', 'alignment-v1'),
      ('release-contract-catalog.json', 'catalog-v1'),
      ('release-schema-manifest.json', 'schema-manifest-v1'),
      ('rollback-plan.json', 'rollback-v1'),
      ('schema-digests.json', 'schema-digests-v1'),
      ('signing-verification.json', 'signing-v1'),
      ('source-checksums.sha256', 'sha256sum-lines-v1'),
    ])
      <String, String>{
        'name': entry.$1,
        'mediaType': entry.$1.endsWith('.json')
            ? 'application/json'
            : 'text/plain',
        'contract': entry.$2,
      },
  ],
};

void _rewriteManifestDigest(Directory output, String changedName) {
  final manifestFile = File('${output.path}/manifest.json');
  final manifest =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final evidenceFiles = manifest['evidenceFiles'] as Map<String, dynamic>;
  evidenceFiles[changedName] = sha256File(File('${output.path}/$changedName'));
  manifestFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
  );
  File(
    '${output.path}/manifest.sha256',
  ).writeAsStringSync('${sha256File(manifestFile)}  manifest.json\n');
}
