part of 'flutter_scout_cli.dart';

// part: batch mode — run a scripted sequence of commands in ONE process over
// ONE VM-service connection. Each separate `flutter-scout` invocation pays
// ~0.5-1.5s of process + WebSocket startup, and the gaps between invocations
// are where timing-sensitive UI (auto-reverting admin views, short-lived
// toasts) drifts away. A batch removes both.

extension _CliBatch on FlutterScoutCli {
  Future<int> _batch(List<String> args) async {
    final parser = ArgParser()
      ..addOption('file', help: 'Read commands from a file, one per line.')
      ..addFlag(
        'keep-going',
        defaultsTo: false,
        negatable: false,
        help: 'Continue running remaining steps after a failed one.',
      );
    final parsed = parser.parse(args);
    final List<String> commands;
    final filePath = parsed.option('file');
    if (filePath != null && filePath.isNotEmpty) {
      final file = File(filePath);
      if (!file.existsSync()) {
        throw ScoutCliException('file_not_found', 'No file at `$filePath`.');
      }
      commands = FlutterScoutCli.splitBatchScript(file.readAsStringSync());
    } else {
      if (parsed.rest.isEmpty) {
        throw const ScoutCliException(
          'usage',
          "Usage: flutter-scout batch 'tap btn.save; wait-for --text Saved' "
              'or flutter-scout batch --file <script>',
        );
      }
      commands = FlutterScoutCli.splitBatchScript(parsed.rest.join(' '));
    }
    if (commands.isEmpty) {
      throw const ScoutCliException('usage', 'Batch script has no commands.');
    }

    // Save/restore so a batch nested under `serve` (which holds the cached
    // connection for its whole lifetime) does not tear the connection down.
    final hadReuse = _reuseVmConnection;
    _reuseVmConnection = true;
    final failed = <Map<String, Object?>>[];
    final stepTimingsMs = <int>[];
    var ranSteps = 0;
    try {
      for (var i = 0; i < commands.length; i++) {
        final argv = FlutterScoutCli.splitCommandLine(commands[i]);
        if (argv.isEmpty) continue;
        if (argv.first == 'batch') {
          throw const ScoutCliException(
            'usage',
            'Nested batch commands are not supported.',
          );
        }
        stdout.writeln(
          jsonEncode({
            'step': i + 1,
            'of': commands.length,
            'cmd': commands[i],
          }),
        );
        ranSteps += 1;
        final stopwatch = Stopwatch()..start();
        final code = await run(argv);
        stepTimingsMs.add(stopwatch.elapsedMilliseconds);
        if (code != 0) {
          failed.add({'step': i + 1, 'cmd': commands[i], 'exitCode': code});
          if (!parsed.flag('keep-going')) break;
        }
      }
    } finally {
      _reuseVmConnection = hadReuse;
      if (!hadReuse) await _disposeCachedVmService();
    }
    stdout.writeln(
      jsonEncode({
        'batch': true,
        'steps': commands.length,
        'ranSteps': ranSteps,
        'failedSteps': failed.length,
        if (failed.isNotEmpty) 'failed': failed,
        'stepTimingsMs': stepTimingsMs,
        'totalMs': stepTimingsMs.fold<int>(0, (sum, ms) => sum + ms),
        'stoppedEarly': ranSteps < commands.length,
      }),
    );
    return failed.isEmpty ? 0 : 1;
  }

  Future<void> _disposeCachedVmService() async {
    final cached = _cachedVmService;
    _cachedVmService = null;
    _cachedVmUri = null;
    if (cached != null) {
      try {
        await cached.dispose();
      } catch (_) {
        // A dead socket failing to close cleanly is not an error.
      }
    }
  }
}

extension _CliExportBatch on FlutterScoutCli {
  /// Reconstructs the session's recorded actions as a batch script — turning
  /// an interactive exploration into a replayable regression flow (a modern
  /// replacement for `replay`, composable with `--expect-*` gates).
  Future<int> _exportBatch(List<String> args) async {
    final parser = ArgParser()..addOption('output', abbr: 'o');
    final parsed = parser.parse(args);
    final actions = _readSessionActions();
    final commands = <String>[];
    final skipped = <Object?>[];
    for (final action in actions) {
      if (action is! Map) {
        skipped.add(action);
        continue;
      }
      final command = _commandForRecord(Map<String, Object?>.from(action));
      (command == null ? skipped : commands).add(command ?? action);
    }
    if (commands.isEmpty) {
      throw const ScoutCliException(
        'no_recorded_actions',
        'No exportable actions in .flutter_scout/session.json — run some '
            'tap/input/fill/scroll commands first.',
      );
    }
    final script = commands.join('\n');
    final output = parsed.option('output');
    if (output != null && output.isNotEmpty) {
      File(output).writeAsStringSync('$script\n');
    }
    stdout.writeln(
      jsonEncode({
        'ok': true,
        'commands': commands,
        'skipped': skipped.length,
        if (output != null && output.isNotEmpty) 'path': output,
        'runWith': output != null && output.isNotEmpty
            ? 'flutter-scout batch --file $output'
            : 'flutter-scout batch \'<commands joined with ;>\'',
      }),
    );
    return 0;
  }

  /// One recorded action -> one batch command line, or null when the record
  /// is not replayable.
  String? _commandForRecord(Map<String, Object?> record) {
    final cmd = record['cmd']?.toString();
    if (cmd == null || cmd.isEmpty) return null;
    final params = {
      for (final entry in record.entries)
        if (entry.key != 'cmd' && entry.value != null)
          entry.key: entry.value.toString(),
    };
    final parts = <String>[cmd];
    void takePositional(String key) {
      final value = params.remove(key);
      if (value != null && value.isNotEmpty) {
        parts.add(FlutterScoutCli.quoteBatchArg(value));
      }
    }

    switch (cmd) {
      case 'tap':
      case 'long-press':
        if (params.containsKey('target')) {
          takePositional('target');
          params.remove('x');
          params.remove('y');
        } else {
          takePositional('x');
          takePositional('y');
        }
      case 'tap-text':
        takePositional('text');
      case 'input':
        final target = params.remove('target');
        if (target != null && target != 'focused') {
          parts.addAll(['--target', FlutterScoutCli.quoteBatchArg(target)]);
        }
        takePositional('value');
      case 'fill':
        final values = params.remove('values');
        if (values == null) return null;
        parts.addAll(['--json', FlutterScoutCli.quoteBatchArg(values)]);
      case 'scroll':
      case 'swipe':
        takePositional('direction');
      case 'scroll-to':
        takePositional('target');
      default:
        return null;
    }
    // Defaults add noise; drop them.
    if (params['waitMs'] == '1500') params.remove('waitMs');
    if (params['expectTimeoutMs'] == '5000') params.remove('expectTimeoutMs');
    if (params['pollMs'] == '150') params.remove('pollMs');
    for (final entry in params.entries) {
      final flag = _flagNameForParam(entry.key);
      if (entry.key == 'allowMismatch') {
        if (entry.value == 'true') parts.add('--allow-mismatch');
        continue;
      }
      parts.addAll(['--$flag', FlutterScoutCli.quoteBatchArg(entry.value)]);
    }
    return parts.join(' ');
  }

  String _flagNameForParam(String param) {
    // Param names that do not follow the plain camelCase->kebab-case rule.
    const special = {'expectTimeoutMs': 'expect-timeout', 'pollMs': 'poll'};
    final mapped = special[param];
    if (mapped != null) return mapped;
    return param.replaceAllMapped(
      RegExp('[A-Z]'),
      (match) => '-${match.group(0)!.toLowerCase()}',
    );
  }
}
