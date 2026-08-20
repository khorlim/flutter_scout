import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:test/test.dart';

void main() {
  test('runtime, pubspec, compatibility table, and changelogs agree', () {
    final cliPubspec = File('pubspec.yaml').readAsStringSync();
    final helperPubspec = File(
      '../flutter_scout_helper/pubspec.yaml',
    ).readAsStringSync();
    final compatibility = File('../../COMPATIBILITY.md').readAsStringSync();
    final cliChangelog = File('CHANGELOG.md').readAsStringSync();
    final helperChangelog = File(
      '../flutter_scout_helper/CHANGELOG.md',
    ).readAsStringSync();
    final helperBinding = File(
      '../flutter_scout_helper/lib/src/flutter_scout_binding.dart',
    ).readAsStringSync();
    final workflow = File('../../.github/workflows/ci.yml').readAsStringSync();

    const cliVersion = FlutterScoutCli.packageVersion;
    const helperVersion = '0.2.0-dev.1';
    expect(_pubspecVersion(cliPubspec), cliVersion);
    expect(_pubspecVersion(helperPubspec), helperVersion);
    expect(
      helperBinding,
      contains("const String scoutHelperPackageVersion = '$helperVersion';"),
    );
    expect(compatibility, contains('`flutter_scout` $cliVersion'));
    expect(compatibility, contains('`flutter_scout_helper` $helperVersion'));
    expect(cliChangelog, contains('`$cliVersion`'));
    expect(helperChangelog, contains('`$helperVersion`'));

    final blockingFlutter = RegExp(
      r"flutter-version:\s*'([^']+)'",
    ).firstMatch(workflow)?.group(1);
    expect(blockingFlutter, isNotNull);
    expect(
      _pubspecEnvironmentConstraint(helperPubspec, 'flutter'),
      '>=$blockingFlutter',
    );
    expect(
      compatibility,
      contains('| Helper Flutter SDK | `>=$blockingFlutter` |'),
    );
  });
}

String _pubspecVersion(String contents) {
  final match = RegExp(
    r'^version:\s*(\S+)\s*$',
    multiLine: true,
  ).firstMatch(contents);
  if (match == null) throw StateError('pubspec has no version');
  return match.group(1)!;
}

String _pubspecEnvironmentConstraint(String contents, String name) {
  final environment = RegExp(
    r'^environment:\s*\n((?:^[ \t]+.*\n?)*)',
    multiLine: true,
  ).firstMatch(contents)?.group(1);
  if (environment == null) throw StateError('pubspec has no environment');
  final match = RegExp(
    "^\\s+$name:\\s*['\"]?([^'\"\\s]+)['\"]?\\s*\$",
    multiLine: true,
  ).firstMatch(environment);
  if (match == null) {
    throw StateError('pubspec environment has no $name constraint');
  }
  return match.group(1)!;
}
