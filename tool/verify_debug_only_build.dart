import 'dart:convert';
import 'dart:io';

/// Verifies Flutter Scout's debug-only build boundary using three APKs built
/// from the same source revision.
///
/// The debug artifact is a positive control: every sentinel must be present in
/// its kernel. Profile and release AOT artifacts are the actual assertion:
/// none of the service-extension, evaluator capability, VM-URI broadcast,
/// recorder, or mutation protocol sentinels may remain in `libapp.so`.
Future<void> main(List<String> arguments) async {
  final paths = _parseArguments(arguments);
  final sentinels = <String>[
    'ext.flutter_scout.inspect',
    'ext.flutter_scout.record',
    '[FLUTTER_SCOUT_VM_URI]',
    'runtime_instance_mismatch',
    'held_drag_active',
    'recorder_persistence_delegated',
    'ext.flutter_scout_evaluator.supplier_state',
    'ext.flutter_scout_evaluator.supplier_reset',
    'SCOUT_EVALUATOR_BUILD_PROBE_9f4c2a7e',
  ];

  final results = <Map<String, Object?>>[];
  var passed = true;
  for (final mode in const <String>['debug', 'profile', 'release']) {
    final apk = File(paths[mode]!).absolute;
    if (!apk.existsSync()) {
      stderr.writeln('Missing $mode APK: ${apk.path}');
      exitCode = 2;
      return;
    }
    final member = await _scannableMember(apk, mode: mode);
    final bytes = await _readZipMember(apk, member);
    final payload = latin1.decode(bytes);
    final presence = <String, bool>{
      for (final sentinel in sentinels) sentinel: payload.contains(sentinel),
    };
    final expectedPresent = mode == 'debug';
    final modePassed = presence.values.every(
      (present) => present == expectedPresent,
    );
    passed = passed && modePassed;
    results.add(<String, Object?>{
      'mode': mode,
      'apk': apk.path,
      'apkBytes': apk.lengthSync(),
      'member': member,
      'memberBytes': bytes.length,
      'expectedSentinels': expectedPresent ? 'present' : 'absent',
      'sentinels': presence,
      'passed': modePassed,
    });
  }

  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'schemaVersion': 1,
      'check': 'flutter_scout_debug_only_build_boundary',
      'passed': passed,
      'interpretation':
          'Debug is the positive scanner control. Profile and release must '
          'tree-shake all code sentinels that can install Scout service '
          'extensions (including evaluator-only oracle channels and their '
          'configured capability), VM-URI broadcasts, recorder persistence, '
          'or mutation handling.',
      'results': results,
    }),
  );
  if (!passed) exitCode = 1;
}

Map<String, String> _parseArguments(List<String> arguments) {
  final values = <String, String>{};
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (!argument.startsWith('--') || index + 1 >= arguments.length) {
      _usage();
    }
    final name = argument.substring(2);
    if (!const <String>{'debug', 'profile', 'release'}.contains(name)) {
      _usage();
    }
    values[name] = arguments[++index];
  }
  if (values.length != 3 ||
      !values.keys.toSet().containsAll(const <String>{
        'debug',
        'profile',
        'release',
      })) {
    _usage();
  }
  return values;
}

Never _usage() {
  stderr.writeln(
    'Usage: dart run tool/verify_debug_only_build.dart '
    '--debug <app-debug.apk> --profile <app-profile.apk> '
    '--release <app-release.apk>',
  );
  exit(64);
}

Future<String> _scannableMember(File apk, {required String mode}) async {
  final result = await Process.run('unzip', <String>['-Z1', apk.path]);
  if (result.exitCode != 0) {
    throw StateError('Could not list ${apk.path}: ${result.stderr}');
  }
  final members = const LineSplitter()
      .convert(result.stdout.toString())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  if (mode == 'debug') {
    const kernel = 'assets/flutter_assets/kernel_blob.bin';
    if (!members.contains(kernel)) {
      throw StateError('Debug APK has no $kernel positive-control payload.');
    }
    return kernel;
  }
  final appLibraries = members
      .where(
        (member) => member.startsWith('lib/') && member.endsWith('/libapp.so'),
      )
      .toList(growable: false);
  if (appLibraries.length != 1) {
    throw StateError(
      '$mode APK must contain exactly one libapp.so for this pinned build; '
      'found ${appLibraries.length}.',
    );
  }
  return appLibraries.single;
}

Future<List<int>> _readZipMember(File apk, String member) async {
  final result = await Process.run('unzip', <String>[
    '-p',
    apk.path,
    member,
  ], stdoutEncoding: null);
  if (result.exitCode != 0 || result.stdout is! List<int>) {
    throw StateError('Could not extract $member from ${apk.path}.');
  }
  return List<int>.from(result.stdout as List<int>, growable: false);
}
