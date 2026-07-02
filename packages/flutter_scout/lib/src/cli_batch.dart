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

    _reuseVmConnection = true;
    var failedSteps = 0;
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
        final code = await run(argv);
        if (code != 0) {
          failedSteps += 1;
          if (!parsed.flag('keep-going')) break;
        }
      }
    } finally {
      _reuseVmConnection = false;
      await _disposeCachedVmService();
    }
    stdout.writeln(
      jsonEncode({
        'batch': true,
        'steps': commands.length,
        'ranSteps': ranSteps,
        'failedSteps': failedSteps,
        'stoppedEarly': ranSteps < commands.length,
      }),
    );
    return failedSteps == 0 ? 0 : 1;
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
