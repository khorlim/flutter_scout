part of 'flutter_scout_cli.dart';

// part: app helper pin advice: tells an agent when the app under test pins an
// older flutter_scout_helper than the installed Scout CLI, and where to bump it.

const _scoutGitUrlMarker = 'khorlim/flutter_scout';

/// A package's git pin as pub records it in a pubspec.lock.
class _GitPin {
  const _GitPin({required this.resolvedRef, required this.url});

  final String resolvedRef;
  final String url;
}

/// The `description` of [package] in [lockText] when it comes from git.
/// Path, hosted and missing packages return null: a path helper is always
/// the checkout's own code, so there is no pin to advise on.
_GitPin? _lockGitPin(String lockText, String package) {
  final lines = lockText.split('\n');
  final start = lines.indexOf('  $package:');
  if (start < 0) return null;
  String? ref;
  String? url;
  String? source;
  for (var i = start + 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.isNotEmpty && !line.startsWith('    ')) break;
    final match = RegExp(
      r'^\s+(resolved-ref|url|source):\s*"?([^"]+)"?\s*$',
    ).firstMatch(line);
    if (match == null) continue;
    switch (match.group(1)) {
      case 'resolved-ref':
        ref = match.group(2);
      case 'url':
        url = match.group(2);
      case 'source':
        source = match.group(2);
    }
  }
  if (source != 'git' || ref == null || url == null) return null;
  return _GitPin(resolvedRef: ref, url: url);
}

/// Advice for `ensure`/`launch` output when the app's helper pin differs
/// from the installed CLI's commit; null when they match or either is
/// unknown (path helper, CLI not activated from git, no lockfile).
/// [isAncestor] answers whether the first commit precedes the second, or null
/// when the history is unavailable.
Map<String, Object?>? _helperPinAdviceFrom({
  required String? appLockText,
  required String? appLockPath,
  required String? appPubspecPath,
  required String? installedLockText,
  required bool? Function(String older, String newer) isAncestor,
  bool? Function(String from, String to)? helperChanged,
}) {
  if (appLockText == null || installedLockText == null) return null;
  final app = _lockGitPin(appLockText, 'flutter_scout_helper');
  final cli = _lockGitPin(installedLockText, 'flutter_scout');
  if (app == null || cli == null) return null;
  if (!app.url.contains(_scoutGitUrlMarker) ||
      !cli.url.contains(_scoutGitUrlMarker)) {
    return null;
  }
  if (app.resolvedRef == cli.resolvedRef) return null;
  // CLI-only commits leave the helper identical; only helper changes matter.
  if (helperChanged?.call(app.resolvedRef, cli.resolvedRef) == false) {
    return null;
  }
  final appBehind = isAncestor(app.resolvedRef, cli.resolvedRef);
  final cliBehind = appBehind == true
      ? false
      : isAncestor(cli.resolvedRef, app.resolvedRef);
  final status = appBehind == true
      ? 'app_helper_behind'
      : cliBehind == true
      ? 'cli_behind'
      : 'differs';
  String short(String ref) => ref.length > 12 ? ref.substring(0, 12) : ref;
  final where = appPubspecPath ?? 'the app pubspec.yaml';
  return <String, Object?>{
    'status': status,
    'appHelperRef': app.resolvedRef,
    'installedScoutRef': cli.resolvedRef,
    'appPubspec': ?appPubspecPath,
    'appLockfile': ?appLockPath,
    'suggestion': switch (status) {
      'app_helper_behind' =>
        'This app pins flutter_scout_helper at ${short(app.resolvedRef)}, '
            'older than the installed Scout (${short(cli.resolvedRef)}), so '
            'helper fixes since then are missing in this app. Suggest to the '
            'user bumping the git `ref:` of flutter_scout_helper in $where to '
            '${cli.resolvedRef}, then `flutter pub get` and a fresh launch. '
            'It is a change in the app repository; ask before making it.',
      'cli_behind' =>
        'This app pins a newer flutter_scout_helper '
            '(${short(app.resolvedRef)}) than the installed Scout '
            '(${short(cli.resolvedRef)}). Refresh the CLI with `dart pub '
            'global activate --source git '
            'https://github.com/khorlim/flutter_scout.git --git-path '
            'packages/flutter_scout`.',
      _ =>
        'This app pins flutter_scout_helper at ${short(app.resolvedRef)}, '
            'not the installed Scout commit (${short(cli.resolvedRef)}). '
            'Suggest pinning the helper in $where to the installed commit '
            'so app and CLI fixes match.',
    },
  };
}

/// Reads the app's lockfile (the project's or its pub workspace root's), the
/// installed CLI's global lockfile and pub's git cache for Scout. Never fails
/// a launch: any unreadable input means no advice.
Map<String, Object?>? _helperPinAdvice(String project) {
  try {
    File? lock;
    var dir = Directory(p.normalize(p.absolute(project)));
    for (var depth = 0; depth < 6; depth++) {
      final candidate = File(p.join(dir.path, 'pubspec.lock'));
      if (candidate.existsSync()) {
        lock = candidate;
        break;
      }
      if (dir.parent.path == dir.path) break;
      dir = dir.parent;
    }
    final pubspec = File(p.join(project, 'pubspec.yaml'));
    final declares =
        pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('flutter_scout_helper');
    final home = Platform.environment['HOME'] ?? '';
    final pubCache =
        Platform.environment['PUB_CACHE'] ?? p.join(home, '.pub-cache');
    final installed = File(
      p.join(pubCache, 'global_packages', 'flutter_scout', 'pubspec.lock'),
    );
    final gitCaches = Directory(p.join(pubCache, 'git', 'cache')).existsSync()
        ? Directory(p.join(pubCache, 'git', 'cache'))
              .listSync()
              .whereType<Directory>()
              .where((d) => p.basename(d.path).startsWith('flutter_scout-'))
              .toList()
        : const <Directory>[];
    bool? isAncestor(String older, String newer) {
      for (final cache in gitCaches) {
        final result = Process.runSync('git', [
          '-C',
          cache.path,
          'merge-base',
          '--is-ancestor',
          older,
          newer,
        ]);
        // 0 = ancestor, 1 = not; anything else means a commit is missing here.
        if (result.exitCode == 0) return true;
        if (result.exitCode == 1) return false;
      }
      return null;
    }

    bool? helperChanged(String from, String to) {
      for (final cache in gitCaches) {
        final result = Process.runSync('git', [
          '-C',
          cache.path,
          'diff',
          '--quiet',
          from,
          to,
          '--',
          'packages/flutter_scout_helper',
        ]);
        if (result.exitCode == 0) return false;
        if (result.exitCode == 1) return true;
      }
      return null;
    }

    return _helperPinAdviceFrom(
      helperChanged: helperChanged,
      appLockText: lock?.readAsStringSync(),
      appLockPath: lock?.path,
      appPubspecPath: declares ? pubspec.path : null,
      installedLockText: installed.existsSync()
          ? installed.readAsStringSync()
          : null,
      isAncestor: isAncestor,
    );
  } catch (_) {
    return null;
  }
}
