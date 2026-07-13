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
        'verbose',
        defaultsTo: false,
        negatable: false,
        help: 'Print each step output instead of one compact final timeline.',
      )
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
    final hadSuppressedOutput = _suppressActionOutput;
    final outputStart = _suppressedActionResults.length;
    _reuseVmConnection = true;
    _suppressActionOutput = !parsed.flag('verbose');
    final failed = <Map<String, Object?>>[];
    final stepTimingsMs = <int>[];
    final timeline = <Map<String, Object?>>[];
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
        if (parsed.flag('verbose')) {
          stdout.writeln(
            jsonEncode({
              'step': i + 1,
              'of': commands.length,
              'cmd': commands[i],
            }),
          );
        }
        ranSteps += 1;
        final stepOutputStart = _suppressedActionResults.length;
        final stopwatch = Stopwatch()..start();
        final code = await run(argv);
        final elapsedMs = stopwatch.elapsedMilliseconds;
        stepTimingsMs.add(elapsedMs);
        final outputs = _suppressedActionResults.sublist(stepOutputStart);
        timeline.add({
          'step': i + 1,
          'cmd': commands[i],
          'exitCode': code,
          'elapsedMs': elapsedMs,
          if (outputs.length == 1) 'result': _compactBatchStep(outputs.single),
          if (outputs.length > 1)
            'results': [
              for (final output in outputs) _compactBatchStep(output),
            ],
          if (outputs.isEmpty && !parsed.flag('verbose'))
            'result': {'summary': 'Command emitted no compact action result.'},
        });
        if (code != 0) {
          failed.add({'step': i + 1, 'cmd': commands[i], 'exitCode': code});
          if (!parsed.flag('keep-going')) break;
        }
      }
    } finally {
      _reuseVmConnection = hadReuse;
      _suppressActionOutput = hadSuppressedOutput;
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
        if (!parsed.flag('verbose')) 'timeline': timeline,
        'totalMs': stepTimingsMs.fold<int>(0, (sum, ms) => sum + ms),
        'stoppedEarly': ranSteps < commands.length,
      }),
    );
    if (_suppressedActionResults.length > outputStart) {
      _suppressedActionResults.removeRange(
        outputStart,
        _suppressedActionResults.length,
      );
    }
    return failed.isEmpty ? 0 : 1;
  }

  /// Batch already provides the chronological context, so repeating every
  /// action's full after-summary makes a short flow unreadable. Keep only the
  /// facts needed to decide whether to continue; `--verbose` remains the
  /// escape hatch for the complete per-step responses.
  Map<String, Object?> _compactBatchStep(Map<String, dynamic> result) {
    final after = result['afterSummary'];
    final afterSummary = after is Map
        ? {
            if (after['screen'] != null) 'screen': after['screen'],
            if (after['activeSurface'] != null)
              'activeSurface': after['activeSurface'],
            if (after['viewSignature'] != null)
              'viewSignature': after['viewSignature'],
            if (after['fieldValues'] != null)
              'fieldValues': after['fieldValues'],
          }
        : null;
    return {
      'ok': result['ok'],
      if (result['action'] != null) 'action': result['action'],
      if (result['result'] != null) 'result': result['result'],
      if (result['stable'] != null) 'stable': result['stable'],
      if (result['target'] != null) 'target': result['target'],
      if (result['filled'] != null) 'filled': result['filled'],
      if (result['failed'] != null) 'failed': result['failed'],
      if (result['activation'] != null) 'activation': result['activation'],
      if (afterSummary != null && afterSummary.isNotEmpty)
        'after': afterSummary,
      if (result['delta'] != null) 'delta': result['delta'],
      if (result['error'] != null) 'error': result['error'],
      if (result['expectation'] != null) 'expectation': result['expectation'],
      if (result['recentErrors'] != null)
        'recentErrors': result['recentErrors'],
    };
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
        final text = params.remove('text');
        if (text == null) return null;
        if (text.startsWith('-')) {
          parts.addAll(['--text', FlutterScoutCli.quoteBatchArg(text)]);
        } else {
          parts.add(FlutterScoutCli.quoteBatchArg(text));
        }
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
