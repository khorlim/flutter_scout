part of 'flutter_scout_cli.dart';

// part: interaction commands: bounds-adjacent tap/input/tap-text/long-press/fill/wait/reload/restart/scroll/swipe/scroll-to/back/deeplink/logs.

extension _CliActions on FlutterScoutCli {
  /// Registers the shared `--expect-*` options: act + gate in ONE VM call,
  /// closing the act->verify gap that separate wait-for invocations leave
  /// open (process startup, connection setup, UI that reverts between
  /// commands).
  static void _addExpectOptions(ArgParser parser) {
    parser
      ..addOption(
        'expect-text',
        help: 'After the action, wait until this text is visible.',
      )
      ..addOption(
        'expect-gone',
        help: 'After the action, wait until this text is gone.',
      )
      ..addOption(
        'expect-target',
        help: 'After the action, wait until this handle is visible.',
      )
      ..addOption(
        'expect-selected',
        help: 'After the action, wait until this handle reports selected.',
      )
      ..addOption(
        'expect-screen',
        help: 'After the action, wait until the screen name equals this.',
      )
      ..addOption(
        'expect-view',
        help:
            'After the action, wait until the viewSignature contains this '
            '(same-route view swaps).',
      )
      ..addOption(
        'expect-field',
        help: 'After the action, wait until <handle>=<value> holds.',
      )
      ..addOption(
        'expect-timeout',
        defaultsTo: '5000',
        help: 'Expectation timeout in ms.',
      );
  }

  Map<String, String> _expectParams(ArgResults parsed) {
    String? opt(String name) {
      final value = parsed.option(name);
      return value == null || value.isEmpty ? null : value;
    }

    final params = <String, String>{
      if (opt('expect-text') != null) 'expectText': opt('expect-text')!,
      if (opt('expect-gone') != null) 'expectGone': opt('expect-gone')!,
      if (opt('expect-target') != null) 'expectTarget': opt('expect-target')!,
      if (opt('expect-selected') != null)
        'expectSelected': opt('expect-selected')!,
      if (opt('expect-screen') != null) 'expectScreen': opt('expect-screen')!,
      if (opt('expect-view') != null) 'expectView': opt('expect-view')!,
      if (opt('expect-field') != null) 'expectField': opt('expect-field')!,
    };
    if (params.isNotEmpty) {
      params['expectTimeoutMs'] = opt('expect-timeout') ?? '5000';
    }
    return params;
  }

  /// Client-side VM-call timeout with headroom above action wait plus any
  /// expectation window.
  Duration _actionCallTimeout(ArgResults parsed, Map<String, String> params) {
    final waitMs = int.tryParse(params['waitMs'] ?? '') ?? 1500;
    final expectMs = params.containsKey('expectTimeoutMs')
        ? int.tryParse(params['expectTimeoutMs'] ?? '') ?? 5000
        : 0;
    return Duration(milliseconds: waitMs + expectMs + 15000);
  }

  Future<int> _inspect(List<String> args) async {
    final parser = ArgParser()
      ..addFlag(
        'brief',
        defaultsTo: false,
        help:
            'Compact orientation payload: screen, text, compact interactables, '
            'field values, errors.',
      )
      ..addFlag(
        'surface',
        defaultsTo: false,
        help:
            'Focus compact inspect on the top active modal/dialog surface when '
            'Scout can identify its bounds.',
      )
      ..addOption(
        'sections',
        help:
            'Comma-separated full sections to include: text, interactables, '
            'fields, textTargets, scrollables, overlays, visualTree, '
            'controlGroups, annotations.',
      );
    final parsed = parser.parse(args);
    final sections = parsed.option('sections');
    final result = _withProtocolDiagnostics(
      'ext.flutter_scout.inspect',
      await _call('ext.flutter_scout.inspect', {
        if (parsed.flag('brief') || parsed.flag('surface')) 'brief': 'true',
        if (parsed.flag('surface')) 'surfaceOnly': 'true',
        if (sections != null && sections.isNotEmpty) 'sections': sections,
      }),
    );
    // Surface swallowed app-log errors (location denied, failed API calls…)
    // that the in-isolate error handlers never see, so a QA sweep notices
    // them without a separate `logs` call.
    final logErrors = _recentLogErrors();
    if (logErrors.isNotEmpty && result['ok'] != false) {
      result['recentLogErrors'] = logErrors;
    }
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
    return result['ok'] == false ? 1 : 0;
  }

  Future<int> _health(List<String> args) async {
    final result = await _call('ext.flutter_scout.inspect', {'brief': 'true'});
    if (result['ok'] == false) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
      return 1;
    }
    final errors = result['recentErrors'];
    final errorList = errors is List ? errors : const <Object?>[];
    final blocking = [
      for (final e in errorList)
        if (e is Map && e['blocking'] == true && e['stale'] != true) e,
    ];
    final interactables = result['interactables'];
    final logErrors = _recentLogErrors();
    final health = <String, Object?>{
      'ok': true,
      'screen': result['screen'],
      'viewSignature': result['viewSignature'],
      'idle': result['idle'],
      'degradedNodes': result['degradedNodes'] ?? 0,
      'interactableCount': interactables is List ? interactables.length : 0,
      'blockingErrors': blocking,
      'recentErrorCount': errorList.length,
      'recentLogErrors': logErrors,
      'healthy': blocking.isEmpty && (result['degradedNodes'] ?? 0) == 0,
    };
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(health));
    return 0;
  }

  Future<int> _waitFor(List<String> args) async {
    final parser = ArgParser()
      ..addOption('text', help: 'Wait until this text is visible.')
      ..addOption('gone', help: 'Wait until this text is no longer visible.')
      ..addOption('target', help: 'Wait until this handle is visible.')
      ..addOption(
        'selected',
        help:
            'Wait until this handle reports selected (active tab, on '
            'toggle).',
      )
      ..addOption('screen', help: 'Wait until the screen name equals this.')
      ..addOption(
        'view',
        help:
            'Wait until the viewSignature contains this (same-route view '
            'swaps like tab bodies).',
      )
      ..addOption(
        'field',
        help: 'Wait until <handle>=<value> holds for a text field.',
      )
      ..addOption('timeout', defaultsTo: '5000', help: 'Timeout in ms.')
      ..addOption('poll', defaultsTo: '150', help: 'Poll interval in ms.');
    final parsed = parser.parse(args);
    var text = parsed.option('text');
    if ((text == null || text.isEmpty) && parsed.rest.isNotEmpty) {
      text = parsed.rest.join(' ');
    }
    String? opt(String name) {
      final value = parsed.option(name);
      return value == null || value.isEmpty ? null : value;
    }

    final conditions = <String, String>{
      if (text != null && text.isNotEmpty) 'text': text,
      if (opt('gone') != null) 'gone': opt('gone')!,
      if (opt('target') != null) 'target': opt('target')!,
      if (opt('selected') != null) 'selected': opt('selected')!,
      if (opt('screen') != null) 'screen': opt('screen')!,
      if (opt('view') != null) 'view': opt('view')!,
      if (opt('field') != null) 'field': opt('field')!,
    };
    if (conditions.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout wait-for [--text "Saved"] [--gone "Loading"] '
            '[--target btn.save] [--selected tap.t_c] [--screen X] '
            '[--field field.name=value] [--timeout 5000] [--poll 150]',
      );
    }
    final timeoutMs = int.tryParse(parsed.option('timeout') ?? '') ?? 5000;
    return _callAndPrint(
      'ext.flutter_scout.waitFor',
      params: {
        ...conditions,
        'timeoutMs': '$timeoutMs',
        'pollMs': parsed.option('poll') ?? '150',
      },
      // The helper needs the full wait window; keep client-side headroom
      // above it so long waits aren't cut off by the default VM-call timeout.
      callTimeout: Duration(milliseconds: timeoutMs + 10000),
    );
  }

  Future<int> _tap(List<String> args) async {
    final parser = ArgParser()
      ..addOption('x')
      ..addOption('y')
      ..addOption('wait-ms', defaultsTo: '1500')
      ..addFlag('verbose', defaultsTo: false);
    _addExpectOptions(parser);
    final parsed = parser.parse(args);
    final target = parsed.rest.isEmpty ? null : parsed.rest.first;
    final x = parsed.option('x');
    final y = parsed.option('y');
    String? resolvedTarget = target;
    String? resolvedX = x;
    String? resolvedY = y;
    if (parsed.rest.length == 2 &&
        _isNumeric(parsed.rest[0]) &&
        _isNumeric(parsed.rest[1]) &&
        x == null &&
        y == null) {
      resolvedTarget = null;
      resolvedX = parsed.rest[0];
      resolvedY = parsed.rest[1];
    } else if (parsed.rest.length > 1 && target != null) {
      throw ScoutCliException(
        'usage',
        _isNumeric(target)
            ? 'For coordinates, use: flutter-scout tap --x $target --y ${parsed.rest[1]} or flutter-scout tap $target ${parsed.rest[1]}.'
            : 'Usage: flutter-scout tap <target> or flutter-scout tap --x <x> --y <y>',
      );
    }
    if ((resolvedTarget == null || resolvedTarget.isEmpty) &&
        (resolvedX == null || resolvedY == null)) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout tap <target> or flutter-scout tap --x <x> --y <y>',
      );
    }
    final params = <String, String>{
      'waitMs': parsed.option('wait-ms') ?? '1500',
      ..._expectParams(parsed),
    };
    if (resolvedTarget != null && resolvedTarget.isNotEmpty) {
      params['target'] = resolvedTarget;
    }
    if (resolvedX != null) {
      params['x'] = resolvedX;
    }
    if (resolvedY != null) {
      params['y'] = resolvedY;
    }
    return _callAndPrint(
      'ext.flutter_scout.tap',
      params: params,
      record: {'cmd': 'tap', ...params},
      compact: !parsed.flag('verbose'),
      callTimeout: _actionCallTimeout(parsed, params),
    );
  }

  Future<int> _input(List<String> args) async {
    final parser = ArgParser()
      ..addOption('target')
      ..addOption(
        'file',
        help:
            'Read the value from this file instead of the command line — '
            'no shell quoting battles for long or multi-line text.',
      )
      ..addFlag('verbose', defaultsTo: false);
    _addExpectOptions(parser);
    final parsed = parser.parse(args);
    final filePath = parsed.option('file');
    final String value;
    if (filePath != null && filePath.isNotEmpty) {
      final file = File(filePath);
      if (!file.existsSync()) {
        throw ScoutCliException('file_not_found', 'No file at `$filePath`.');
      }
      value = file.readAsStringSync();
    } else {
      if (parsed.rest.isEmpty) {
        throw const ScoutCliException(
          'usage',
          'Usage: flutter-scout input [--target <field>] <value> or '
              'flutter-scout input --target <field> --file <path>',
        );
      }
      value = parsed.rest.join(' ');
    }
    final target = parsed.option('target') ?? 'focused';
    final params = <String, String>{
      'target': target,
      'value': value,
      ..._expectParams(parsed),
    };
    return _callAndPrint(
      'ext.flutter_scout.input',
      params: params,
      record: {'cmd': 'input', ...params},
      compact: !parsed.flag('verbose'),
      callTimeout: _actionCallTimeout(parsed, params),
    );
  }

  Future<int> _tapText(List<String> args) async {
    final parser = ArgParser()
      ..addOption(
        'text',
        help:
            'Visible text to tap. Use this when the label starts with `-` or '
            'could otherwise be parsed as an option.',
      )
      ..addOption('wait-ms', defaultsTo: '1500')
      ..addFlag('allow-mismatch', defaultsTo: false, negatable: false)
      ..addFlag(
        'contains',
        defaultsTo: false,
        negatable: false,
        help:
            'Also match a truncated on-screen label that is a prefix of the '
            'query (e.g. "Prenatal Bliss…").',
      )
      ..addFlag('verbose', defaultsTo: false);
    _addExpectOptions(parser);
    final parsed = parser.parse(args);
    final textOption = parsed.option('text');
    if ((textOption == null || textOption.isEmpty) && parsed.rest.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout tap-text <visible text> or '
            'flutter-scout tap-text --text <visible text>',
      );
    }
    if (textOption != null && textOption.isNotEmpty && parsed.rest.isNotEmpty) {
      throw const ScoutCliException(
        'usage',
        'Use either positional text or --text, not both.',
      );
    }
    final text = textOption != null && textOption.isNotEmpty
        ? textOption
        : parsed.rest.join(' ');
    final params = <String, String>{
      'text': text,
      'waitMs': parsed.option('wait-ms') ?? '1500',
      if (parsed.flag('allow-mismatch')) 'allowMismatch': 'true',
      if (parsed.flag('contains')) 'contains': 'true',
      ..._expectParams(parsed),
    };
    var result = await _call(
      'ext.flutter_scout.tapText',
      params,
      _actionCallTimeout(parsed, params),
    );
    result = await _tapTextFallbackIfNeeded(result, params);
    result = _withProtocolDiagnostics('ext.flutter_scout.tapText', result);
    stdout.writeln(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(parsed.flag('verbose') ? result : _compactActionResult(result)),
    );
    if (result['ok'] == true) {
      _recordAction({'cmd': 'tap-text', ...params});
    }
    return result['ok'] == false ? 1 : 0;
  }

  Future<int> _longPress(List<String> args) async {
    final parser = ArgParser()
      ..addOption('duration-ms', defaultsTo: '600')
      ..addOption('x')
      ..addOption('y')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final target = parsed.rest.isEmpty ? null : parsed.rest.first;
    if (target == null &&
        (parsed.option('x') == null || parsed.option('y') == null)) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout long-press <target> [--duration-ms <ms>]',
      );
    }
    final params = <String, String>{
      'durationMs': parsed.option('duration-ms') ?? '600',
    };
    if (target != null) {
      params['target'] = target;
    }
    if (parsed.option('x') != null) {
      params['x'] = parsed.option('x')!;
    }
    if (parsed.option('y') != null) {
      params['y'] = parsed.option('y')!;
    }
    return _callAndPrint(
      'ext.flutter_scout.longPress',
      params: params,
      record: {'cmd': 'long-press', ...params},
      compact: !parsed.flag('verbose'),
    );
  }

  Future<int> _fill(List<String> args) async {
    final parser = ArgParser()
      ..addOption('json')
      ..addFlag('verbose', defaultsTo: false);
    _addExpectOptions(parser);
    final parsed = parser.parse(args);
    final raw = parsed.option('json');
    if (raw == null || raw.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout fill --json <object>',
      );
    }
    jsonDecode(raw);
    final params = <String, String>{'values': raw, ..._expectParams(parsed)};
    return _callAndPrint(
      'ext.flutter_scout.fill',
      params: params,
      record: {'cmd': 'fill', ...params},
      compact: !parsed.flag('verbose'),
      callTimeout: _actionCallTimeout(parsed, params),
    );
  }

  Future<int> _wait(List<String> args) async {
    if (args.isNotEmpty && args.first != 'stable') {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout wait stable',
      );
    }
    return _callAndPrint('ext.flutter_scout.waitStable');
  }

  Future<int> _reload(List<String> args) async {
    final parser = ArgParser()..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final result = await _hotUpdate(
      action: 'reload',
      signal: ProcessSignal.sigusr1,
      fullRestart: false,
    );
    stdout.writeln(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(parsed.flag('verbose') ? result : _compactActionResult(result)),
    );
    if (result['ok'] == true) {
      _recordAction(const {'cmd': 'reload'});
    }
    return result['ok'] == false ? 1 : 0;
  }

  Future<int> _restart(List<String> args) async {
    final parser = ArgParser()..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final result = await _hotUpdate(
      action: 'restart',
      signal: ProcessSignal.sigusr2,
      fullRestart: true,
    );
    stdout.writeln(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(parsed.flag('verbose') ? result : _compactActionResult(result)),
    );
    if (result['ok'] == true) {
      _recordAction(const {'cmd': 'restart'});
    }
    return result['ok'] == false ? 1 : 0;
  }

  Future<int> _scroll(List<String> args) {
    return _dragCommand(
      method: 'ext.flutter_scout.scroll',
      command: 'scroll',
      defaultDirection: 'down',
      args: args,
    );
  }

  Future<int> _swipe(List<String> args) {
    return _dragCommand(
      method: 'ext.flutter_scout.swipe',
      command: 'swipe',
      defaultDirection: 'left',
      args: args,
    );
  }

  Future<int> _scrollTo(List<String> args) async {
    final parser = ArgParser()
      ..addOption('max-scrolls', defaultsTo: '20')
      ..addOption('direction')
      ..addOption('distance')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final target = parsed.rest.isEmpty ? null : parsed.rest.first;
    if (target == null || target.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout scroll-to <target> [--max-scrolls <n>] '
            '[--direction down|up|left|right] [--distance <px>]',
      );
    }
    final explicitDirection = _hasOption(args, 'direction');
    final direction = parsed.option('direction') ?? 'down';
    final params = <String, String>{
      'target': target,
      'maxScrolls': parsed.option('max-scrolls') ?? '20',
      'direction': direction,
      if (parsed.option('distance') != null)
        'distance': parsed.option('distance')!,
    };
    final recordParams = <String, String>{
      'target': target,
      'maxScrolls': parsed.option('max-scrolls') ?? '20',
      if (explicitDirection) 'direction': direction,
      if (parsed.option('distance') != null)
        'distance': parsed.option('distance')!,
    };
    var result = _withProtocolDiagnostics(
      'ext.flutter_scout.scrollTo',
      await _call('ext.flutter_scout.scrollTo', params),
    );
    if (result['ok'] == false &&
        !explicitDirection &&
        _shouldRetryScrollToOpposite(result)) {
      final opposite = _oppositeDirection(direction);
      final retryParams = {...params, 'direction': opposite};
      final retry = _withProtocolDiagnostics(
        'ext.flutter_scout.scrollTo',
        await _call('ext.flutter_scout.scrollTo', retryParams),
      );
      retry['fallback'] = {
        'used': true,
        'reason': 'initial_direction_reached_scroll_end',
        'initialDirection': direction,
        'retryDirection': opposite,
        'initialFailure': {
          'reason': result['reason'],
          'scrollsUsed': result['scrollsUsed'],
          'message': result['error'] is Map
              ? (result['error'] as Map)['message']
              : null,
        },
      };
      result = retry;
    }
    final output = parsed.flag('verbose')
        ? result
        : _compactActionResult(result);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(output));
    if (result['ok'] == true) {
      _recordAction({'cmd': 'scroll-to', ...recordParams});
    }
    return result['ok'] == false ? 1 : 0;
  }

  bool _shouldRetryScrollToOpposite(Map<String, dynamic> result) {
    final reason = result['reason'];
    if (reason == 'reached_scroll_end' || reason == 'target_not_reached') {
      return true;
    }
    final error = result['error'];
    if (error is Map && error['code'] == 'target_not_reached') return true;
    return false;
  }

  bool _hasOption(List<String> args, String name) =>
      args.any((arg) => arg == '--$name' || arg.startsWith('--$name='));

  String _oppositeDirection(String direction) => switch (direction) {
    'down' => 'up',
    'up' => 'down',
    'left' => 'right',
    'right' => 'left',
    _ => 'up',
  };

  Future<int> _dragCommand({
    required String method,
    required String command,
    required String defaultDirection,
    required List<String> args,
  }) async {
    final parser = ArgParser()
      ..addOption('target')
      ..addOption('distance')
      ..addOption('x')
      ..addOption('y')
      ..addOption('from')
      ..addOption('to')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final direction = parsed.rest.isEmpty
        ? defaultDirection
        : parsed.rest.first;
    final params = <String, String>{
      'direction': direction,
      if (parsed.option('target') != null) 'target': parsed.option('target')!,
      if (parsed.option('distance') != null)
        'distance': parsed.option('distance')!,
      if (parsed.option('x') != null) 'x': parsed.option('x')!,
      if (parsed.option('y') != null) 'y': parsed.option('y')!,
      if (parsed.option('from') != null) 'point': parsed.option('from')!,
      if (parsed.option('to') != null) 'to': parsed.option('to')!,
    };
    return _callAndPrint(
      method,
      params: params,
      record: {'cmd': command, ...params},
      compact: !parsed.flag('verbose'),
    );
  }

  Future<int> _back(List<String> args) async {
    final parser = ArgParser()..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    return _callAndPrint(
      'ext.flutter_scout.back',
      record: const {'cmd': 'back'},
      compact: !parsed.flag('verbose'),
    );
  }

  Future<int> _dismiss(List<String> args) async {
    final parser = ArgParser()
      ..addOption('wait-ms', defaultsTo: '1500')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    return _callAndPrint(
      'ext.flutter_scout.dismiss',
      params: {'waitMs': parsed.option('wait-ms') ?? '1500'},
      record: const {'cmd': 'dismiss'},
      compact: !parsed.flag('verbose'),
    );
  }

  Future<int> _deeplink(List<String> args) async {
    if (args.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout deeplink <url>',
      );
    }
    final url = args.first;
    await _openDeeplink(url);
    stdout.writeln(jsonEncode({'ok': true, 'url': url}));
    _recordAction({'cmd': 'deeplink', 'url': url});
    return 0;
  }

  Future<int> _logs(List<String> args) async {
    final parser = ArgParser()
      ..addOption('last', defaultsTo: '20')
      ..addOption('contains')
      ..addFlag('summary', defaultsTo: false, negatable: false);
    final parsed = parser.parse(args);
    final payload = await _logsPayload(
      last: int.tryParse(parsed.option('last') ?? '') ?? 20,
      contains: parsed.option('contains'),
      summary: parsed.flag('summary'),
    );
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(payload));
    return 0;
  }

  Future<Map<String, Object?>> _logsPayload({
    required int last,
    required String? contains,
    required bool summary,
  }) async {
    final file = File(_logFile);
    final attachOnly = await _isAttachOnlySession();
    if (!attachOnly) {
      final vmUri = _readVmUri();
      if (vmUri != null) {
        await _ensureVmLogListenerForCurrentSession(vmUri);
      }
    }
    if (attachOnly || !file.existsSync()) {
      return {
        'ok': true,
        'path': _logFile,
        'available': false,
        'source': attachOnly
            ? 'attach_only_session'
            : 'scout_owned_flutter_run',
        'session': _sessionModeInfo(),
        'message': attachOnly
            ? 'This is an attach-only session. Scout can inspect and act through the VM service, but it cannot read the owning VS Code, IDE, or terminal console logs. Use that owner console, run flutter logs separately, or start with flutter-scout ensure/launch when Scout should own log capture.'
            : 'No Scout-owned flutter run log file exists. Attach-only sessions cannot read the owning terminal or IDE console logs.',
        if (summary) ...{
          'errors': 0,
          'warnings': 0,
          'vmServiceUri': _readVmUri(),
          'lastImportantLines': const <String>[],
        } else
          'lines': const <String>[],
      };
    }
    final allLines = _dedupeVmStdoutEcho(file.readAsLinesSync());
    if (summary) {
      final summary = _summarizeLogLines(allLines, last: last);
      return {
        'ok': true,
        'path': _logFile,
        'available': allLines.isNotEmpty,
        'source': allLines.isEmpty
            ? 'empty_scout_log'
            : 'scout_owned_flutter_run',
        'session': _sessionModeInfo(),
        if (allLines.isEmpty)
          'message':
              'The Scout-owned log file exists, but no Flutter tool output has been captured yet.',
        ...summary,
      };
    }
    var lines = allLines;
    if (contains != null && contains.isNotEmpty) {
      lines = lines
          .where((line) => line.contains(contains))
          .toList(growable: false);
    }
    if (lines.length > last) {
      lines = lines.sublist(lines.length - last);
    }
    return {
      'ok': true,
      'path': _logFile,
      'available': allLines.isNotEmpty,
      'source': allLines.isEmpty
          ? 'empty_scout_log'
          : 'scout_owned_flutter_run',
      'session': _sessionModeInfo(),
      if (contains != null && contains.isNotEmpty) 'contains': contains,
      if (contains != null && contains.isNotEmpty) 'matched': lines.length,
      if (allLines.isEmpty)
        'message':
            'The Scout-owned log file exists, but no Flutter tool output has been captured yet.',
      if (allLines.isNotEmpty && lines.isEmpty)
        'message': 'No Scout-owned log lines matched the requested filter.',
      'lines': lines,
    };
  }

  Future<int> _vmLogListener(List<String> args) async {
    final parser = ArgParser()
      ..addOption('vm-uri')
      ..addOption('log-file');
    final parsed = parser.parse(args);
    final vmUri = parsed.option('vm-uri');
    final logFile = parsed.option('log-file');
    if (vmUri == null || vmUri.isEmpty || logFile == null || logFile.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout vm-log-listener --vm-uri <uri> --log-file <path>',
      );
    }
    return _listenToVmLogs(vmUri: vmUri, logFile: logFile);
  }

  Future<int> _listenToVmLogs({
    required String vmUri,
    required String logFile,
  }) async {
    IOSink? sink;
    try {
      Directory(p.dirname(logFile)).createSync(recursive: true);
      sink = File(logFile).openWrite(mode: FileMode.append);
      var writeChain = Future<void>.value();

      Future<void> writeLine(String line) {
        writeChain = writeChain.then((_) async {
          sink?.writeln(line);
          await sink?.flush();
        });
        return writeChain;
      }

      while (true) {
        final appPid = _readPid();
        if (appPid != null && !await _processExists(appPid)) {
          await writeLine(
            '[flutter_scout] VM logging listener stopped: Flutter run process exited ${DateTime.now().toIso8601String()}',
          );
          return 0;
        }

        VmService? service;
        final subscriptions = <StreamSubscription<Event>>[];
        try {
          service = await vmServiceConnectUri(_normalizeVmUri(vmUri));
          final connected = service;
          // developer.log / dart:developer records arrive on the Logging stream.
          subscriptions.add(
            connected.onLoggingEvent.listen((event) {
              unawaited(() async {
                try {
                  await writeLine(await _formatVmLogEvent(connected, event));
                } catch (error) {
                  await writeLine(
                    '[flutter_scout] VM logging event format failed: $error',
                  );
                }
              }());
            }),
          );
          // print / debugPrint / stdout / stderr arrive on the Stdout & Stderr
          // streams. The flutter-tool console redirect only carries these while
          // its own device connection is alive, so it drops them whenever the
          // app is backgrounded and never sees them in attach-only sessions.
          // Capturing the VM streams directly makes log capture comprehensive
          // and resilient to those cases.
          subscriptions.add(
            connected.onStdoutEvent.listen((event) {
              unawaited(_writeVmWriteEvent('STDOUT', event, writeLine));
            }),
          );
          subscriptions.add(
            connected.onStderrEvent.listen((event) {
              unawaited(_writeVmWriteEvent('STDERR', event, writeLine));
            }),
          );
          await connected.streamListen(EventStreams.kLogging);
          await _tryStreamListen(connected, EventStreams.kStdout);
          await _tryStreamListen(connected, EventStreams.kStderr);
          await writeLine(
            '[flutter_scout] VM logging listener attached ${DateTime.now().toIso8601String()}',
          );
          await connected.onDone;
          await writeLine(
            '[flutter_scout] VM logging listener disconnected ${DateTime.now().toIso8601String()}; reconnecting',
          );
        } catch (error) {
          await writeLine('[flutter_scout] VM logging listener failed: $error');
        } finally {
          for (final subscription in subscriptions) {
            await subscription.cancel();
          }
          await service?.dispose();
          await writeChain;
        }

        await Future<void>.delayed(const Duration(seconds: 1));
      }
    } catch (error) {
      sink ??= File(logFile).openWrite(mode: FileMode.append);
      sink.writeln('[flutter_scout] VM logging listener failed: $error');
      await sink.flush();
      return 1;
    } finally {
      await sink?.close();
    }
  }

  /// Collapses flutter-tool console echoes of app stdout/stderr that Scout's
  /// own VM listener already captured. The `flutter run` console (redirected
  /// into the log file) and the VM Stdout/Stderr streams both observe the same
  /// app output, so in a healthy foreground session the same print/debugPrint
  /// line lands twice: once bare (`flutter: msg`) and once VM-tagged
  /// (`[ts] [VM_STDOUT] flutter: msg`). We keep the timestamped VM copy and drop
  /// the bare echo, matched by count so genuinely repeated prints and
  /// startup-only lines (captured before the VM listener attached) survive.
  List<String> _dedupeVmStdoutEcho(List<String> lines) {
    final vmTag = RegExp(r'^\[[^\]]*\] \[VM_STD(?:OUT|ERR)\] (.*)$');
    final vmPayloads = <String, int>{};
    for (final line in lines) {
      final match = vmTag.firstMatch(line);
      if (match != null) {
        final payload = match.group(1)!;
        vmPayloads[payload] = (vmPayloads[payload] ?? 0) + 1;
      }
    }
    if (vmPayloads.isEmpty) return lines;
    final result = <String>[];
    for (final line in lines) {
      final remaining = vmPayloads[line];
      if (remaining != null && remaining > 0) {
        vmPayloads[line] = remaining - 1;
        continue;
      }
      result.add(line);
    }
    return result;
  }

  Future<void> _tryStreamListen(VmService service, String stream) async {
    try {
      await service.streamListen(stream);
    } catch (_) {
      // The stream may be unavailable or already subscribed on this client;
      // keep the other streams working rather than failing the whole listener.
    }
  }

  Future<void> _writeVmWriteEvent(
    String stream,
    Event event,
    Future<void> Function(String) writeLine,
  ) async {
    final bytes = event.bytes;
    if (bytes == null || bytes.isEmpty) return;
    String text;
    try {
      text = utf8.decode(base64.decode(bytes), allowMalformed: true);
    } catch (_) {
      return;
    }
    if (text.isEmpty) return;
    final timestamp = event.timestamp != null && event.timestamp! > 0
        ? DateTime.fromMillisecondsSinceEpoch(
            event.timestamp!,
          ).toIso8601String()
        : DateTime.now().toIso8601String();
    for (final line in const LineSplitter().convert(_stripAnsi(text))) {
      if (line.isEmpty) continue;
      await writeLine('[$timestamp] [VM_$stream] $line');
    }
  }

  Future<String> _formatVmLogEvent(VmService service, Event event) async {
    final record = event.logRecord;
    if (record == null) {
      return '[VM_LOG] ${jsonEncode(event.toJson())}';
    }
    final timestamp = record.time != null && record.time! > 0
        ? DateTime.fromMillisecondsSinceEpoch(record.time!).toIso8601String()
        : DateTime.now().toIso8601String();
    final isolateId = event.isolate?.id;
    final loggerName =
        await _instanceValue(service, isolateId, record.loggerName) ??
        record.loggerName?.id ??
        'log';
    final message = _stripAnsi(
      await _instanceValue(service, isolateId, record.message) ?? '',
    );
    final error = _stripAnsi(
      await _instanceValue(service, isolateId, record.error) ?? '',
    );
    final stackTrace = _stripAnsi(
      await _instanceValue(service, isolateId, record.stackTrace) ?? '',
    );
    final extras = <String>[
      if (record.level != null) 'level=${record.level}',
      if (record.sequenceNumber != null) 'seq=${record.sequenceNumber}',
    ].join(' ');
    return [
      '[$timestamp]',
      '[VM_LOG]',
      '[$loggerName]',
      if (extras.isNotEmpty) extras,
      message,
      // A null error/stackTrace ref resolves to the literal string 'null';
      // emitting `error=null` both adds noise and trips the log summarizer's
      // substring-based error counter, so treat it as absent.
      if (error.isNotEmpty && error != 'null') 'error=$error',
      if (stackTrace.isNotEmpty && stackTrace != 'null') 'stack=$stackTrace',
    ].where((part) => part.isNotEmpty).join(' ');
  }

  Future<String?> _instanceValue(
    VmService service,
    String? isolateId,
    InstanceRef? ref,
  ) async {
    final value = ref?.valueAsString;
    if (value != null &&
        value.isNotEmpty &&
        ref?.valueAsStringIsTruncated != true) {
      return value;
    }
    if (isolateId != null &&
        ref?.id != null &&
        ref?.valueAsStringIsTruncated == true) {
      try {
        final object = await service.getObject(isolateId, ref!.id!);
        if (object is Instance &&
            object.valueAsString != null &&
            object.valueAsString!.isNotEmpty) {
          return object.valueAsString;
        }
      } catch (_) {
        // Fall back to the truncated VM-service ref below.
      }
    }
    if (value != null && value.isNotEmpty) return '$value [truncated]';
    return null;
  }

  String _stripAnsi(String value) =>
      value.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
}
