import 'dart:convert';
import 'dart:io';

import 'release_evidence.dart';

Future<void> main(List<String> arguments) async {
  try {
    final options = _Options.parse(arguments);
    if (options.help) {
      stdout.write(_usage);
      return;
    }
    final generator = ReleaseEvidenceGenerator(
      repository: Directory(options.root),
    );
    if (options.verifyDirectory != null) {
      final result = await generator.verify(
        evidenceDirectory: Directory(options.verifyDirectory!),
        artifacts: <String, File>{
          for (final artifact in options.artifacts)
            artifact.name: artifact.file,
        },
      );
      stdout.writeln(
        const JsonEncoder.withIndent(
          '  ',
        ).convert(<String, Object?>{'ok': result.ok, 'errors': result.errors}),
      );
      if (!result.ok) exitCode = 1;
      return;
    }
    final result = await generator.generate(
      outputDirectory: Directory(options.outputDirectory!),
      artifacts: options.artifacts,
      sourceDateEpoch: options.sourceDateEpoch,
      allowDirty: options.allowDirty,
    );
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'ok': true,
        'candidateCommit': result.candidateCommit,
        'cleanWorktree': result.cleanWorktree,
        'outputDirectory': result.outputDirectory.path,
        'files': result.files,
        'artifactEvidenceComplete': options.artifacts.isNotEmpty,
        'releaseEligibility': 'not_assessed',
        'releaseEligibilityNote':
            'This generator verifies evidence integrity only. Every gate in '
            'RELEASING.md must be assessed independently.',
      }),
    );
  } on Object catch (error) {
    stderr.writeln('release-evidence: $error');
    exitCode = 64;
  }
}

final class _Options {
  const _Options({
    required this.root,
    required this.outputDirectory,
    required this.verifyDirectory,
    required this.artifacts,
    required this.sourceDateEpoch,
    required this.allowDirty,
    required this.help,
  });

  final String root;
  final String? outputDirectory;
  final String? verifyDirectory;
  final List<ReleaseArtifact> artifacts;
  final int? sourceDateEpoch;
  final bool allowDirty;
  final bool help;

  static _Options parse(List<String> arguments) {
    var root = Directory.current.path;
    String? output;
    String? verify;
    int? sourceDateEpoch;
    var allowDirty = false;
    var help = false;
    final artifacts = <ReleaseArtifact>[];
    for (var index = 0; index < arguments.length; index += 1) {
      final argument = arguments[index];
      String takeValue(String option) {
        if (index + 1 >= arguments.length) {
          throw FormatException('$option requires a value');
        }
        index += 1;
        return arguments[index];
      }

      switch (argument) {
        case '--root':
          root = takeValue(argument);
        case '--output':
          output = takeValue(argument);
        case '--verify':
          verify = takeValue(argument);
        case '--artifact':
          final value = takeValue(argument);
          final separator = value.indexOf('=');
          if (separator <= 0 || separator == value.length - 1) {
            throw FormatException('--artifact must be NAME=/absolute/path');
          }
          artifacts.add(
            ReleaseArtifact(
              name: value.substring(0, separator),
              file: File(value.substring(separator + 1)),
            ),
          );
        case '--source-date-epoch':
          sourceDateEpoch = int.tryParse(takeValue(argument));
          if (sourceDateEpoch == null || sourceDateEpoch < 0) {
            throw FormatException(
              '--source-date-epoch must be a non-negative integer',
            );
          }
        case '--allow-dirty':
          allowDirty = true;
        case '--help' || '-h':
          help = true;
        default:
          throw FormatException('Unknown argument: $argument');
      }
    }
    if (!help && (output == null) == (verify == null)) {
      throw const FormatException(
        'Specify exactly one of --output or --verify.',
      );
    }
    return _Options(
      root: root,
      outputDirectory: output,
      verifyDirectory: verify,
      artifacts: List<ReleaseArtifact>.unmodifiable(artifacts),
      sourceDateEpoch: sourceDateEpoch,
      allowDirty: allowDirty,
      help: help,
    );
  }
}

const String _usage = '''
Generate deterministic, offline Flutter Scout release evidence.

Usage:
  dart tool/release/generate_release_evidence.dart \\
    --output /absolute/private/evidence-directory \\
    --artifact flutter_scout.tar.gz=/absolute/path/flutter_scout.tar.gz

  dart tool/release/generate_release_evidence.dart \\
    --verify /absolute/private/evidence-directory \\
    --artifact flutter_scout.tar.gz=/absolute/path/flutter_scout.tar.gz

Options:
  --root PATH                Flutter Scout Git worktree root (default: cwd).
  --output PATH              New or empty output directory outside the repo.
  --verify PATH              Verify an existing evidence directory.
  --artifact NAME=PATH       Released regular file; repeat for every artifact.
  --source-date-epoch VALUE  Fixed UTC timestamp; defaults to SOURCE_DATE_EPOCH
                             and then the candidate commit timestamp.
  --allow-dirty              Permit a diagnostic bundle from a dirty worktree.
                             Such a bundle is never release-eligible.
  --help                     Show this help.

The generator does not resolve packages or use the network. Its dependency
inventory and explicitly incomplete CycloneDX SBOM are derived only from
checked-in pubspec/pubspec.lock files and supplied artifact bytes. The signing
record remains `not_performed` and the rollback record remains `not_exercised`.
Missing artifacts, dirty source, failed toolchain probes, and unavailable CI
provenance are recorded instead of being promoted into support claims.
''';
