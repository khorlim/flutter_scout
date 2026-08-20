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
      )
      ..addOption(
        'capture',
        help:
            'Write an in-app screenshot at the exact post-action expectation '
            'frame.',
      )
      ..addFlag(
        'allow-errors',
        defaultsTo: false,
        negatable: false,
        help:
            'Allow fresh blocking runtime/log errors (actions fail on them by default).',
      )
      ..addFlag(
        'assert-no-errors',
        defaultsTo: true,
        negatable: false,
        hide: true,
      )
      ..addOption(
        'expect-log',
        help: 'Wait for this text in fresh Scout-owned logs after the action.',
      )
      ..addOption(
        'reject-log',
        help: 'Fail if this text appears in fresh Scout-owned action logs.',
      );
  }

  static void _addAllowErrorsOption(ArgParser parser) {
    parser.addFlag(
      'allow-errors',
      defaultsTo: false,
      negatable: false,
      help: 'Allow fresh blocking runtime/log errors (failed by default).',
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
    if (opt('capture') != null) params['capture'] = 'true';
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
        'max-items',
        help:
            'Maximum entries per brief list (1-100, default 20). Request '
            'full named data with --sections instead of raising this by default.',
      )
      ..addOption(
        'sections',
        help:
            'Comma-separated full sections to include: text, interactables, '
            'fields, textTargets, scrollables, overlays, visualTree, '
            'controlGroups, rows, annotations, semantics.',
      )
      ..addOption(
        'since',
        help:
            'Return a structured delta from this run/runtime snapshot identity.',
      )
      ..addOption(
        'max-response-bytes',
        defaultsTo: '65536',
        help: 'Bound an inspect --since response (4096-1048576 bytes).',
      )
      ..addFlag(
        'include-stale',
        defaultsTo: false,
        help: 'Include log signals older than 30 seconds.',
      );
    final parsed = parser.parse(args);
    final sections = parsed.option('sections');
    final maxItems = parsed.option('max-items');
    final since = parsed.option('since');
    if (maxItems != null &&
        (int.tryParse(maxItems) == null ||
            int.parse(maxItems) < 1 ||
            int.parse(maxItems) > 100)) {
      throw const ScoutCliException(
        'usage',
        '--max-items must be an integer from 1 to 100.',
      );
    }
    if (since != null &&
        since.isNotEmpty &&
        (parsed.flag('brief') ||
            parsed.flag('surface') ||
            (sections != null && sections.isNotEmpty) ||
            maxItems != null)) {
      throw const ScoutCliException(
        'usage',
        '--since cannot be combined with --brief, --surface, --sections, or --max-items.',
      );
    }
    final maxResponseBytes = _boundedNavigationInteger(
      parsed.option('max-response-bytes'),
      name: '--max-response-bytes',
      minimum: 4096,
      maximum: 1048576,
    );
    var result = _withProtocolDiagnostics(
      'ext.flutter_scout.inspect',
      await _call('ext.flutter_scout.inspect', {
        if (parsed.flag('brief') || parsed.flag('surface')) 'brief': 'true',
        if (parsed.flag('surface')) 'surfaceOnly': 'true',
        if (sections != null && sections.isNotEmpty) 'sections': sections,
        if (since != null && since.isNotEmpty) 'since': since,
        if (since != null && since.isNotEmpty)
          'maxResponseBytes': '$maxResponseBytes',
        'maxItems': ?maxItems,
      }),
    );
    if (parsed.flag('brief') || parsed.flag('surface')) {
      result = _compactBriefInspect(result);
    }
    // Surface swallowed app-log errors (location denied, failed API calls…)
    // that the in-isolate error handlers never see, so a QA sweep notices
    // them without a separate `logs` call.
    final logSignals = parsed.flag('include-stale')
        ? _recentLogSignals()
        : _freshRecentLogSignals();
    if (logSignals.isNotEmpty && result['ok'] != false) {
      result['recentLogSignals'] = _logSignalMaps(
        logSignals,
        phase: 'inspect',
        actionCommandId: _activeCommandId,
      );
    }
    result['logCursor'] = _currentLogCursor();
    if (_currentRunIdFromSession() case final runId?) {
      result['runId'] = runId;
    }
    _printJson(result);
    return result['ok'] == false ? 1 : 0;
  }

  Future<int> _health(List<String> args) async {
    final parser = ArgParser()..addFlag('include-stale', defaultsTo: false);
    final parsed = parser.parse(args);
    final health = await _healthPayload(
      includeStale: parsed.flag('include-stale'),
    );
    _printJson(health);
    return health['ok'] == false ? 1 : 0;
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
      captureOutput: parsed.option('capture'),
      assertNoErrors: !parsed.flag('allow-errors'),
      expectLog: parsed.option('expect-log'),
      rejectLog: parsed.option('reject-log'),
      logExpectationTimeout: Duration(
        milliseconds:
            int.tryParse(parsed.option('expect-timeout') ?? '') ?? 5000,
      ),
    );
  }

  Future<int> _input(List<String> args) async {
    final parser = ArgParser()
      ..addOption('target')
      ..addOption(
        'file',
        help: 'Read the value from a regular owner-only 0600 UTF-8 file.',
      )
      ..addFlag(
        'stdin',
        defaultsTo: false,
        negatable: false,
        help: 'Read one bounded UTF-8 value from protected standard input.',
      )
      ..addFlag('verbose', defaultsTo: false);
    _addExpectOptions(parser);
    final parsed = parser.parse(args);
    final filePath = parsed.option('file');
    final fromStdin = parsed.flag('stdin');
    final sourceCount =
        (filePath != null ? 1 : 0) +
        (fromStdin ? 1 : 0) +
        (parsed.rest.isNotEmpty ? 1 : 0);
    if (sourceCount != 1) {
      throw const ScoutCliException(
        'usage',
        'Use exactly one input source: a positional value, '
            '`--file <owner-only-path>`, or `--stdin`.',
      );
    }
    final String value;
    if (filePath != null && filePath.isNotEmpty) {
      value = _protectedActionInput('input');
    } else if (fromStdin) {
      value = _protectedActionInput('input');
    } else {
      value = parsed.rest.join(' ');
    }
    final target = parsed.option('target') ?? 'focused';
    _registerSensitiveValue(value);
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
      captureOutput: parsed.option('capture'),
      assertNoErrors: !parsed.flag('allow-errors'),
      expectLog: parsed.option('expect-log'),
      rejectLog: parsed.option('reject-log'),
      logExpectationTimeout: Duration(
        milliseconds:
            int.tryParse(parsed.option('expect-timeout') ?? '') ?? 5000,
      ),
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
    final totalStopwatch = Stopwatch()..start();
    final actionLogCursor = _currentLogCursor();
    final vmStopwatch = Stopwatch()..start();
    var result = await _call(
      'ext.flutter_scout.tapText',
      params,
      _actionCallTimeout(parsed, params),
    );
    result = await _tapTextFallbackIfNeeded(result, params);
    vmStopwatch.stop();
    result = _withProtocolDiagnostics('ext.flutter_scout.tapText', result);
    result = _materializeActionCapture(result, parsed.option('capture'));
    result = await _withRecentLogSignals(result, sinceCursor: actionLogCursor);
    result = await _applyLogExpectations(
      result,
      sinceCursor: actionLogCursor,
      expectLog: parsed.option('expect-log'),
      rejectLog: parsed.option('reject-log'),
      timeout: Duration(
        milliseconds:
            int.tryParse(parsed.option('expect-timeout') ?? '') ?? 5000,
      ),
    );
    result = _assertActionHasNoErrors(
      result,
      enabled: !parsed.flag('allow-errors'),
    );
    totalStopwatch.stop();
    result = {
      ...result,
      'timings': {
        'vmCallMs': vmStopwatch.elapsedMilliseconds,
        'totalMs': totalStopwatch.elapsedMilliseconds,
      },
    };
    final actionSucceeded = result['ok'] == true;
    result = _commitActionEvidence(
      method: 'ext.flutter_scout.tapText',
      result: result,
      record: {'cmd': 'tap-text', ...params},
    );
    _emitActionOutput(
      Map<String, dynamic>.from(
        parsed.flag('verbose') ? result : _compactActionResult(result),
      ),
    );
    if (actionSucceeded && result['ok'] == true) {
      await _maybeStartAutoServe();
    }
    return result['ok'] == false ? 1 : 0;
  }

  Future<int> _longPress(List<String> args) async {
    final parser = ArgParser()
      ..addOption('duration-ms', defaultsTo: '600')
      ..addOption('x')
      ..addOption('y')
      ..addFlag('verbose', defaultsTo: false);
    _addAllowErrorsOption(parser);
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
      assertNoErrors: !parsed.flag('allow-errors'),
    );
  }

  Future<int> _fill(List<String> args) async {
    final parser = ArgParser()
      ..addOption('json')
      ..addOption(
        'file',
        help:
            'Read one JSON object of string field/value pairs from a regular '
            'owner-only 0600 file.',
      )
      ..addFlag(
        'stdin',
        defaultsTo: false,
        negatable: false,
        help:
            'Read one bounded JSON object of string field/value pairs from '
            'protected standard input.',
      )
      ..addFlag('verbose', defaultsTo: false);
    _addExpectOptions(parser);
    final parsed = parser.parse(args);
    final inlineJson = parsed.option('json');
    final filePath = parsed.option('file');
    final fromStdin = parsed.flag('stdin');
    final sourceCount =
        (inlineJson != null ? 1 : 0) +
        (filePath != null ? 1 : 0) +
        (fromStdin ? 1 : 0);
    if (sourceCount != 1) {
      throw const ScoutCliException(
        'usage',
        'Use exactly one fill source: deprecated `--json <object>`, '
            '`--file <owner-only-path>`, or `--stdin`.',
      );
    }
    final protectedSource = filePath != null || fromStdin;
    final raw = protectedSource ? _protectedActionInput('fill') : inlineJson!;
    final Object? decodedValues;
    if (protectedSource) {
      decodedValues = _decodeProtectedStringObject(
        raw,
        source: 'fill input',
        allowEmpty: false,
      );
    } else {
      try {
        decodedValues = jsonDecode(raw);
      } catch (_) {
        throw const ScoutCliException(
          'invalid_fill_json',
          '`fill --json` must contain a valid JSON object. Input content was '
              'not included in this diagnostic.',
        );
      }
      if (decodedValues is! Map) {
        throw const ScoutCliException(
          'invalid_fill_json',
          '`fill --json` must contain one JSON object.',
        );
      }
    }
    _registerSensitiveValue(decodedValues);
    final params = <String, String>{
      'values': protectedSource ? jsonEncode(decodedValues) : raw,
      ..._expectParams(parsed),
    };
    return _callAndPrint(
      'ext.flutter_scout.fill',
      params: params,
      record: {'cmd': 'fill', ...params},
      compact: !parsed.flag('verbose'),
      callTimeout: _actionCallTimeout(parsed, params),
      captureOutput: parsed.option('capture'),
      assertNoErrors: !parsed.flag('allow-errors'),
      expectLog: parsed.option('expect-log'),
      rejectLog: parsed.option('reject-log'),
      logExpectationTimeout: Duration(
        milliseconds:
            int.tryParse(parsed.option('expect-timeout') ?? '') ?? 5000,
      ),
    );
  }

  Future<int> _wait(List<String> args) async {
    final stableArgs = args.isNotEmpty && args.first == 'stable'
        ? args.skip(1).toList(growable: false)
        : args;
    if (args.isNotEmpty && args.first != 'stable') {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout wait stable [--timeout <ms>] [--verbose]',
      );
    }
    final parser = ArgParser()
      ..addOption('timeout', defaultsTo: '3000')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(stableArgs);
    return _callAndPrint(
      'ext.flutter_scout.waitStable',
      params: {'timeoutMs': parsed.option('timeout') ?? '3000'},
      compact: !parsed.flag('verbose'),
    );
  }

  Future<int> _reload(List<String> args) async {
    final parser = ArgParser()..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final logCursor = _currentLogCursor();
    final result = await _hotUpdate(
      action: 'reload',
      signal: ProcessSignal.sigusr1,
      fullRestart: false,
    );
    final logsStopwatch = Stopwatch()..start();
    var enrichedResult = await _withRecentLogSignals(
      result,
      sinceCursor: logCursor,
    );
    logsStopwatch.stop();
    enrichedResult = _withMeasuredCliPhase(
      enrichedResult,
      phase: 'logs',
      elapsedMs:
          _phaseElapsedMs(enrichedResult, 'logs') +
          logsStopwatch.elapsedMilliseconds,
      scope:
          'hot-update acknowledgement plus bounded post-action log collection',
      facts: <String, Object?>{'sinceCursor': logCursor},
    );
    enrichedResult = _persistHotUpdateOperability(enrichedResult);
    enrichedResult = _commitActionEvidence(
      method: 'process.flutter.reload',
      result: enrichedResult,
      record: const {'cmd': 'reload'},
    );
    _emitActionOutput(
      parsed.flag('verbose')
          ? enrichedResult
          : _compactActionResult(enrichedResult),
    );
    return enrichedResult['ok'] == false ? 1 : 0;
  }

  Future<int> _restart(List<String> args) async {
    final parser = ArgParser()..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final logCursor = _currentLogCursor();
    final result = await _hotUpdate(
      action: 'restart',
      signal: ProcessSignal.sigusr2,
      fullRestart: true,
    );
    final logsStopwatch = Stopwatch()..start();
    var enrichedResult = await _withRecentLogSignals(
      result,
      sinceCursor: logCursor,
    );
    logsStopwatch.stop();
    enrichedResult = _withMeasuredCliPhase(
      enrichedResult,
      phase: 'logs',
      elapsedMs:
          _phaseElapsedMs(enrichedResult, 'logs') +
          logsStopwatch.elapsedMilliseconds,
      scope:
          'hot-update acknowledgement plus bounded post-action log collection',
      facts: <String, Object?>{'sinceCursor': logCursor},
    );
    enrichedResult = _persistHotUpdateOperability(enrichedResult);
    enrichedResult = _commitActionEvidence(
      method: 'process.flutter.restart',
      result: enrichedResult,
      record: const {'cmd': 'restart'},
    );
    _emitActionOutput(
      parsed.flag('verbose')
          ? enrichedResult
          : _compactActionResult(enrichedResult),
    );
    return enrichedResult['ok'] == false ? 1 : 0;
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

  Future<int> _dragStart(List<String> args) async {
    final parser = ArgParser()
      ..addOption('target')
      ..addOption('from')
      ..addOption('x')
      ..addOption('y')
      ..addFlag('verbose', defaultsTo: false);
    _addAllowErrorsOption(parser);
    final parsed = parser.parse(args);
    final params = <String, String>{
      if (parsed.option('target') != null) 'target': parsed.option('target')!,
      if (parsed.option('from') != null) 'point': parsed.option('from')!,
      if (parsed.option('x') != null) 'x': parsed.option('x')!,
      if (parsed.option('y') != null) 'y': parsed.option('y')!,
    };
    return _callAndPrint(
      'ext.flutter_scout.dragStart',
      params: params,
      record: {'cmd': 'drag-start', ...params},
      compact: !parsed.flag('verbose'),
      assertNoErrors: !parsed.flag('allow-errors'),
    );
  }

  Future<int> _dragMove(List<String> args) async {
    final parser = ArgParser()
      ..addOption('to')
      ..addOption('by')
      ..addOption('x')
      ..addOption('y')
      ..addOption('screenshot')
      ..addFlag('verbose', defaultsTo: false);
    _addAllowErrorsOption(parser);
    final parsed = parser.parse(args);
    final logCursor = _currentLogCursor();
    final params = _heldDragPointParams(parsed);
    if (params.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout drag-move (--to x,y | --by dx,dy)',
      );
    }
    var result = _withProtocolDiagnostics(
      'ext.flutter_scout.dragMove',
      await _call('ext.flutter_scout.dragMove', params),
    );
    final screenshot = parsed.option('screenshot');
    if (result['ok'] == true && screenshot != null && screenshot.isNotEmpty) {
      final capture = await _inAppCapture(mode: 'screen');
      if (capture?.bytes != null) {
        _writePrivateArtifactBytes(screenshot, capture!.bytes!);
        _writePrivateArtifactMetadata(screenshot, 'session');
        result = {
          ...result,
          'screenshot': File(screenshot).absolute.path,
          'screenshotMetadata': '$screenshot.metadata.json',
          ..._privateArtifactMetadata('session'),
        };
      } else {
        result = {
          ...result,
          'warnings': [
            ..._objectList(result['warnings']),
            'Could not capture the held-drag frame in-app.',
          ],
        };
      }
    }
    result = await _withRecentLogSignals(result, sinceCursor: logCursor);
    result = _assertActionHasNoErrors(
      result,
      enabled: !parsed.flag('allow-errors'),
    );
    result = _commitActionEvidence(
      method: 'ext.flutter_scout.dragMove',
      result: result,
      record: {'cmd': 'drag-move', ...params},
    );
    _emitActionOutput(
      parsed.flag('verbose') ? result : _compactActionResult(result),
    );
    return result['ok'] == false ? 1 : 0;
  }

  Future<int> _dragEnd(List<String> args) async {
    final parser = ArgParser()
      ..addOption('to')
      ..addOption('by')
      ..addOption('x')
      ..addOption('y')
      ..addFlag('verbose', defaultsTo: false);
    _addAllowErrorsOption(parser);
    final parsed = parser.parse(args);
    final params = _heldDragPointParams(parsed);
    return _callAndPrint(
      'ext.flutter_scout.dragEnd',
      params: params,
      record: {'cmd': 'drag-end', ...params},
      compact: !parsed.flag('verbose'),
      assertNoErrors: !parsed.flag('allow-errors'),
    );
  }

  Future<int> _dragCancel(List<String> args) =>
      _callAndPrint('ext.flutter_scout.dragCancel', compact: true);

  Future<int> _dragStatus(List<String> args) => _callAndPrint(
    'ext.flutter_scout.dragStatus',
    compact: !args.contains('--verbose'),
  );

  Map<String, String> _heldDragPointParams(ArgResults parsed) => {
    if (parsed.option('to') != null) 'to': parsed.option('to')!,
    if (parsed.option('by') != null) 'by': parsed.option('by')!,
    if (parsed.option('x') != null) 'x': parsed.option('x')!,
    if (parsed.option('y') != null) 'y': parsed.option('y')!,
  };

  Future<int> _scrollTo(List<String> args) async {
    final parser = ArgParser()
      ..addOption('max-scrolls', defaultsTo: '20')
      ..addOption('direction')
      ..addOption('distance')
      ..addFlag('verbose', defaultsTo: false);
    _addAllowErrorsOption(parser);
    final parsed = parser.parse(args);
    final logCursor = _currentLogCursor();
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
    final callerScope = _activeCallerIdempotencyKey;
    final idempotencyScope =
        callerScope ?? _newProtocolIdentifier('scroll-to-scope');
    final initialKey = _derivedStepIdempotencyKey(
      scope: idempotencyScope,
      step: 0,
      businessRequest: <String, Object?>{
        'kind': 'scroll-to-attempt',
        'params': params,
      },
    );
    var result = _withProtocolDiagnostics(
      'ext.flutter_scout.scrollTo',
      await _withCallerIdempotencyKey<Map<String, dynamic>>(
        initialKey,
        () => _call('ext.flutter_scout.scrollTo', params),
      ),
    );
    if (result['ok'] == false &&
        !explicitDirection &&
        _isClosedCertainScrollToFallbackOutcome(result) &&
        _shouldRetryScrollToOpposite(result)) {
      final opposite = _oppositeDirection(direction);
      final retryParams = {...params, 'direction': opposite};
      final retryKey = _derivedStepIdempotencyKey(
        scope: idempotencyScope,
        step: 1,
        businessRequest: <String, Object?>{
          'kind': 'scroll-to-opposite-attempt',
          'params': retryParams,
        },
      );
      final retry = _withProtocolDiagnostics(
        'ext.flutter_scout.scrollTo',
        await _withCallerIdempotencyKey<Map<String, dynamic>>(
          retryKey,
          () => _call('ext.flutter_scout.scrollTo', retryParams),
        ),
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
    result = <String, dynamic>{
      ...result,
      'idempotencyScope': <String, Object?>{
        'kind': 'deterministic_composite_steps',
        'keySource': callerScope == null ? 'generated' : 'caller',
        'scopeKeyDigest': _idempotencyKeyDigest(idempotencyScope),
      },
      if (callerScope == null) 'idempotencyScopeKey': idempotencyScope,
    };
    result = await _withRecentLogSignals(result, sinceCursor: logCursor);
    result = _assertActionHasNoErrors(
      result,
      enabled: !parsed.flag('allow-errors'),
    );
    result = _commitActionEvidence(
      method: 'ext.flutter_scout.scrollTo',
      result: result,
      record: {'cmd': 'scroll-to', ...recordParams},
    );
    final output = parsed.flag('verbose')
        ? result
        : _compactActionResult(result);
    _emitActionOutput(output);
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

  bool _isClosedCertainScrollToFallbackOutcome(Map<String, dynamic> result) =>
      result['transport'] == 'ok' &&
      result['dispatch'] == 'dispatched' &&
      result['identityStatus'] == 'validated' &&
      result['observation'] != 'observation_unavailable';

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
    _addAllowErrorsOption(parser);
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
      assertNoErrors: !parsed.flag('allow-errors'),
    );
  }

  Future<int> _back(List<String> args) async {
    final parser = ArgParser()..addFlag('verbose', defaultsTo: false);
    _addAllowErrorsOption(parser);
    final parsed = parser.parse(args);
    return _callAndPrint(
      'ext.flutter_scout.back',
      record: const {'cmd': 'back'},
      compact: !parsed.flag('verbose'),
      assertNoErrors: !parsed.flag('allow-errors'),
    );
  }

  Future<int> _dismiss(List<String> args) async {
    final parser = ArgParser()
      ..addOption('wait-ms', defaultsTo: '1500')
      ..addFlag('verbose', defaultsTo: false);
    _addAllowErrorsOption(parser);
    final parsed = parser.parse(args);
    return _callAndPrint(
      'ext.flutter_scout.dismiss',
      params: {'waitMs': parsed.option('wait-ms') ?? '1500'},
      record: const {'cmd': 'dismiss'},
      compact: !parsed.flag('verbose'),
      assertNoErrors: !parsed.flag('allow-errors'),
    );
  }

  Future<int> _deeplink(List<String> args) async {
    final parser = ArgParser()
      ..addOption(
        'url-file',
        help: 'Read the URL from an owner-only 0600 regular file.',
      )
      ..addFlag(
        'url-stdin',
        defaultsTo: false,
        negatable: false,
        help: 'Read the URL from bounded protected standard input.',
      );
    final parsed = parser.parse(args);
    if (parsed.rest.length > 1 ||
        (parsed.rest.isEmpty &&
            parsed.option('url-file') == null &&
            !parsed.flag('url-stdin'))) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout deeplink '
            '(<legacy-url> | --url-file <0600-file> | --url-stdin)',
      );
    }
    final protected = _protectedDeeplinkInput();
    final url = protected.url;
    final dispatched = await _durableDeeplink(url);
    final result = _commitActionEvidence(
      method: dispatched['method']?.toString() ?? 'platform.deeplink',
      result: dispatched,
      record: <String, Object?>{
        'cmd': 'deeplink',
        'url': '${_kRecordRedactedPrefix}deeplink.url',
        'urlSource': protected.source,
        '_redacted': 'true',
        '_redactedFields': const <String>['url'],
        '_redactionPolicy': 'source',
      },
    );
    _emitActionOutput(result);
    return result['ok'] == false ? 1 : 0;
  }

  Future<Map<String, dynamic>> _durableDeeplink(String url) async {
    final validatedUrl = _validateDeeplinkUrl(url);
    late final _NativeMobileTarget target;
    try {
      target = _requireNativeMobileTarget(operation: 'deeplink');
      // Capability and exact target reachability are proven before the durable
      // mutation boundary. An unsupported tool/platform therefore cannot be
      // confused with an uncertain application dispatch.
      await _preflightNativeTarget(target, operation: 'deeplink');
    } on ScoutCliException catch (error) {
      return _notDispatchedProtocolFailure(
        code: error.code,
        message: error.message,
        method: 'platform.deeplink',
        runId: _currentRunIdFromSession(),
        details: error.details,
      );
    }
    return _runDurableLocalMutation(
      method: target.deeplinkMethod,
      businessParams: <String, String>{'url': url},
      dispatch: () async {
        final before = await _tryInspect(
          callTimeout: const Duration(seconds: 2),
        );
        final expectedRunId = _currentRunIdFromSession();
        final observationIssue = _nativeDeeplinkObservationIssue(
          before,
          expectedRunId: expectedRunId,
        );
        if (observationIssue != null) {
          var failure = _notDispatchedProtocolFailure(
            code: 'native_deeplink_preflight_observation_unavailable',
            message:
                'Scout could not prove a live protocol-valid observation from '
                'this exact session immediately before native deep-link '
                'dispatch. Nothing was sent to the emulator.',
            method: target.deeplinkMethod,
            runId: expectedRunId,
            transport: before == null ? 'failed' : 'invalid_response',
            details: <String, Object?>{
              'reason': observationIssue,
              'backend': target.backend,
              'device': target.id,
              'expectedRunId': expectedRunId,
              if (before != null) 'observedIdentity': _protocolIdentity(before),
            },
          );
          if (before != null &&
              _canonicalPhaseTimingsIssue(before['timings']) == null) {
            failure = _withPreflightPhaseTimings(failure, before['timings']);
          }
          for (final phase in const <String>[
            'match',
            'dispatch',
            'settle',
            'delta',
          ]) {
            failure = _withUnavailablePhase(
              failure,
              phase: phase,
              owner: phase == 'settle'
                  ? 'helper'
                  : phase == 'delta'
                  ? 'cli_and_helper'
                  : 'cli',
              reason:
                  'not_applicable:native_deeplink_preflight_observation_failed',
            );
          }
          return failure;
        }
        final beforeObserved = before!;
        final dispatchStopwatch = Stopwatch()..start();
        final nativeDispatch = await _dispatchNativeDeeplink(
          target,
          validatedUrl,
        );
        dispatchStopwatch.stop();
        final nativeDispatchStatus =
            nativeDispatch['dispatch']?.toString() ??
            'dispatch_outcome_unknown';
        if (nativeDispatchStatus == 'not_dispatched') {
          var failure = _notDispatchedProtocolFailure(
            code:
                ((nativeDispatch['structuredError'] as Map?)?['code'])
                    ?.toString() ??
                'deeplink_not_dispatched',
            message:
                ((nativeDispatch['structuredError'] as Map?)?['message'])
                    ?.toString() ??
                'The native deep-link process could not be started.',
            method: target.deeplinkMethod,
            runId: _currentRunIdFromSession(),
            details: <String, Object?>{
              'backend': target.backend,
              'device': target.id,
            },
          );
          failure = _withPreflightPhaseTimings(
            failure,
            beforeObserved['timings'],
          );
          failure = _withMeasuredPhase(
            failure,
            phase: 'dispatch',
            elapsedMs: dispatchStopwatch.elapsedMilliseconds,
            owner: 'cli',
            scope: 'bounded native deep-link process start',
          );
          failure = _withUnavailablePhase(
            failure,
            phase: 'match',
            owner: 'cli',
            reason: 'not_applicable:native_deeplink_has_no_widget_selector',
          );
          failure = _withUnavailablePhase(
            failure,
            phase: 'settle',
            owner: 'helper',
            reason: 'not_applicable:deeplink_was_not_dispatched',
          );
          failure = _withUnavailablePhase(
            failure,
            phase: 'delta',
            owner: 'cli_and_helper',
            reason: 'not_applicable:deeplink_was_not_dispatched',
          );
          return failure;
        }
        Map<String, dynamic>? settled;
        try {
          settled = await _call(
            'ext.flutter_scout.waitStable',
            const <String, String>{'timeoutMs': '3000'},
            const Duration(seconds: 5),
          );
        } catch (_) {
          settled = null;
        }
        final after = await _tryInspect(
          callTimeout: const Duration(seconds: 2),
        );
        final afterObserved = after?['ok'] == true ? after : null;
        final deltaStopwatch = Stopwatch()..start();
        final delta = _inspectDelta(beforeObserved, afterObserved);
        deltaStopwatch.stop();
        final nativeStructuredError = nativeDispatch['structuredError'];
        var result = <String, dynamic>{
          'ok': nativeDispatchStatus == 'dispatched',
          'deeplink': <String, Object?>{
            'accepted': true,
            'credentialPresent': _deeplinkCredentialPresent(url),
          },
          'method': target.deeplinkMethod,
          'backend': target.backend,
          'nativeDispatch': nativeDispatch,
          if (nativeStructuredError is Map)
            'structuredError': <String, Object?>{
              for (final entry in nativeStructuredError.entries)
                entry.key.toString(): entry.value,
            },
          'transport': nativeDispatch['transport'] ?? 'ok',
          'dispatch': nativeDispatchStatus,
          'observation': afterObserved != null
              ? _inspectChanged(beforeObserved, afterObserved)
                    ? 'changed'
                    : 'no_effect'
              : 'observation_unavailable',
          'postcondition': 'postcondition_not_requested',
          'runtimeHealth': afterObserved == null
              ? 'runtime_health_unknown'
              : _objectList(afterObserved['activeBlockingSignals']).isEmpty
              ? 'runtime_clean'
              : 'runtime_blocked',
          'stable': settled?['stable'] == true,
          'before': beforeObserved,
          'after': afterObserved,
          'delta': delta,
        };
        result = _withPreflightPhaseTimings(result, beforeObserved['timings']);
        result = _withPreflightPhaseTimings(
          result,
          _postDispatchObservationTimings(settled?['timings']),
        );
        result = _withPreflightPhaseTimings(
          result,
          _postDispatchObservationTimings(afterObserved?['timings']),
        );
        result = _withMeasuredPhase(
          result,
          phase: 'dispatch',
          elapsedMs: dispatchStopwatch.elapsedMilliseconds,
          owner: 'cli',
          scope: 'bounded simulator deep-link process dispatch',
        );
        result = _withMeasuredPhase(
          result,
          phase: 'delta',
          elapsedMs:
              deltaStopwatch.elapsedMilliseconds +
              _phaseElapsedMs(result, 'delta'),
          owner: 'cli_and_helper',
          scope:
              'post-dispatch helper observation plus CLI factual delta construction',
        );
        return _withUnavailablePhase(
          result,
          phase: 'match',
          owner: 'cli',
          reason: 'not_applicable:native_deeplink_has_no_widget_selector',
        );
      },
      classifyDispatch: (result) =>
          result['dispatch']?.toString() ?? 'dispatch_outcome_unknown',
    );
  }

  String _validateDeeplinkUrl(String raw) {
    _registerDeeplinkCredentials(raw);
    if (raw.isEmpty ||
        utf8.encode(raw).length > 8192 ||
        raw.codeUnits.any((unit) => unit == 0 || unit < 0x20 || unit == 0x7f)) {
      throw const ScoutCliException(
        'invalid_deeplink_url',
        'A deep link must be a non-empty URI of at most 8192 UTF-8 bytes and '
            'must not contain control characters.',
      );
    }
    final parsed = Uri.tryParse(raw);
    if (parsed == null || parsed.scheme.isEmpty) {
      throw const ScoutCliException(
        'invalid_deeplink_url',
        'A deep link must contain an explicit URI scheme.',
      );
    }
    return raw;
  }

  bool _deeplinkCredentialPresent(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return true;
    return uri.userInfo.isNotEmpty ||
        uri.pathSegments.any((segment) => segment.isNotEmpty) ||
        uri.hasQuery ||
        uri.fragment.isNotEmpty;
  }

  String? _nativeDeeplinkObservationIssue(
    Map<String, dynamic>? observation, {
    required String? expectedRunId,
  }) {
    if (observation == null) return 'observation_unavailable';
    if (observation['ok'] != true) return 'observation_not_ok';
    final protocolIssue = _protocolEnvelopeIssue(
      observation,
      requireMutationCapabilities: false,
    );
    if (protocolIssue != null) return protocolIssue.$1;
    if (expectedRunId == null || expectedRunId.isEmpty) {
      return 'session_run_id_unavailable';
    }
    if (observation['runId']?.toString() != expectedRunId) {
      return 'session_run_id_mismatch';
    }
    final generation = observation['stateGeneration'];
    final snapshotId = observation['snapshotId']?.toString();
    final stateDigest = observation['stateDigest']?.toString();
    if (generation is! int ||
        snapshotId == null ||
        !RegExp(r'^g\d+:[a-f0-9]{64}$').hasMatch(snapshotId) ||
        snapshotId != 'g$generation:$stateDigest' ||
        stateDigest == null ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(stateDigest)) {
      return 'snapshot_identity_unavailable';
    }
    return null;
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
    _printJson(payload);
    return 0;
  }

  Future<Map<String, Object?>> _logsPayload({
    required int last,
    required String? contains,
    required bool summary,
  }) async {
    if (last <= 0) {
      throw const ScoutCliException(
        'usage',
        '`logs --last` must be a positive integer.',
      );
    }
    if (last > _maxScoutLogResultLines) {
      throw const ScoutCliException(
        'request_parameter_too_large',
        '`logs --last` exceeds the bounded 1000-line result limit.',
      );
    }
    if (contains != null && contains.length > _maxScoutLogFilterCharacters) {
      throw const ScoutCliException(
        'request_parameter_too_large',
        '`logs --contains` exceeds the bounded 4096-character filter limit.',
      );
    }
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
    final chunk = _readLogChunk(file, maxBytes: _maxScoutLogTailBytes);
    final rawLines = chunk.lines;
    // Discover and register every capability URL before serializing even the
    // first line. The URI may occur later in the log than an echoed token, so
    // line-by-line generic redaction cannot establish this ordering safely.
    for (final line in rawLines) {
      _extractVmUri(line) ?? _extractFlutterToolVmUri(line);
    }
    final allLines = _dedupeVmStdoutEcho(
      rawLines.map(_redactActiveSensitiveText).toList(growable: false),
    );
    if (summary) {
      final summary = _summarizeLogLines(allLines, last: last);
      return {
        'ok': true,
        'path': _logFile,
        'available': allLines.isNotEmpty,
        'source': allLines.isEmpty
            ? 'empty_scout_log'
            : 'scout_owned_flutter_run',
        'cursor': chunk.endCursor,
        'retainedFromCursor': chunk.startCursor,
        'readBytes': chunk.bytesRead,
        'truncated': chunk.truncated,
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
      'cursor': chunk.endCursor,
      'retainedFromCursor': chunk.startCursor,
      'readBytes': chunk.bytesRead,
      'truncated': chunk.truncated,
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
      ..addOption('vm-uri-file')
      ..addOption('log-file')
      ..addOption('session-dir')
      ..addOption('owner-pid');
    final parsed = parser.parse(args);
    final vmUriFile = parsed.option('vm-uri-file');
    final logFile = parsed.option('log-file');
    final sessionDir = parsed.option('session-dir');
    final ownerPid = int.tryParse(parsed.option('owner-pid') ?? '');
    if (vmUriFile == null ||
        vmUriFile.isEmpty ||
        logFile == null ||
        logFile.isEmpty ||
        sessionDir == null ||
        sessionDir.isEmpty ||
        ownerPid == null) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout vm-log-listener --vm-uri-file <private-file> '
            '--log-file <path> --session-dir <path> --owner-pid <pid>',
      );
    }
    final sessionRoot = p.normalize(p.absolute(sessionDir));
    final credentialPath = p.normalize(p.absolute(vmUriFile));
    if (!p.isWithin(sessionRoot, credentialPath)) {
      throw const ScoutCliException(
        'invalid_vm_uri_file',
        'The VM credential handoff must be inside the selected session directory.',
      );
    }
    final credential = File(credentialPath);
    if (FileSystemEntity.typeSync(credential.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const ScoutCliException(
        'invalid_vm_uri_file',
        'The VM credential handoff is missing or is not a regular file.',
      );
    }
    late final String vmUri;
    try {
      vmUri = _readOwnerOnlySecretFile(credential.path).trim();
    } finally {
      _deleteFileIfExists(credential.path);
    }
    if (vmUri.isEmpty) {
      throw const ScoutCliException(
        'invalid_vm_uri_file',
        'The VM credential handoff was empty.',
      );
    }
    _registerVmUriCredentials(vmUri);
    final validatedVmUri = _normalizeVmUri(vmUri);
    FlutterScoutCli._sessionDirectoryOverride = sessionDir;
    return _listenToVmLogs(
      vmUri: validatedVmUri,
      logFile: logFile,
      ownerPid: ownerPid,
    );
  }

  Future<int> _listenToVmLogs({
    required String vmUri,
    required String logFile,
    required int ownerPid,
  }) async {
    _LockedLogWriter? writer;
    var consecutiveFailures = 0;
    try {
      writer = _LockedLogWriter(logFile);

      Future<void> writeLine(String line) {
        final sanitized = _redactActiveSensitiveText(line);
        final timestamped = _extractLogTimestamp(sanitized) == null
            ? '[${DateTime.now().toUtc().toIso8601String()}] $sanitized'
            : sanitized;
        return writer!.write(timestamped);
      }

      Future<bool> exactlyOwnsRunner() async {
        final meta = _readSessionMeta();
        return _readPid() == ownerPid &&
            await _matchesOwnedFlutterRun(ownerPid, meta);
      }

      // The listener is spawned just before the final ready metadata write.
      // Wait briefly for that exact owner tuple instead of accepting mere PID
      // existence during the handoff.
      final ownershipDeadline = DateTime.now().add(const Duration(seconds: 5));
      while (!await exactlyOwnsRunner() &&
          DateTime.now().isBefore(ownershipDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!await exactlyOwnsRunner()) {
        await writeLine(
          '[flutter_scout] VM logging listener stopped: owner identity was not established',
        );
        _deleteFileIfExists(_vmLogListenerPidFile);
        return 0;
      }

      while (true) {
        if (!await exactlyOwnsRunner()) {
          await writeLine(
            '[flutter_scout] VM logging listener stopped: Flutter run ownership ended ${DateTime.now().toIso8601String()}',
          );
          _deleteFileIfExists(_vmLogListenerPidFile);
          return 0;
        }

        VmService? service;
        final subscriptions = <StreamSubscription<Event>>[];
        try {
          service = await _connect(vmUri);
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
          if (consecutiveFailures > 0) {
            await writeLine(
              '[flutter_scout] VM logging listener recovered after '
              '$consecutiveFailures connection failure(s)',
            );
            consecutiveFailures = 0;
          }
          await writeLine(
            '[flutter_scout] VM logging listener attached ${DateTime.now().toIso8601String()}',
          );
          await connected.onDone;
          await writeLine(
            '[flutter_scout] VM logging listener disconnected ${DateTime.now().toIso8601String()}; reconnecting',
          );
        } catch (error) {
          consecutiveFailures += 1;
          if (consecutiveFailures == 1 || consecutiveFailures % 30 == 0) {
            await writeLine(
              '[flutter_scout] VM logging listener connection failed '
              '($consecutiveFailures attempt(s)): $error',
            );
          }
        } finally {
          for (final subscription in subscriptions) {
            await subscription.cancel();
          }
          await service?.dispose();
          await writer.flush();
        }

        final backoffSeconds = min(30, 1 << min(5, consecutiveFailures));
        await Future<void>.delayed(Duration(seconds: backoffSeconds));
      }
    } catch (error) {
      writer ??= _LockedLogWriter(logFile);
      await writer.write(
        '[flutter_scout] VM logging listener failed: '
        '${_redactActiveSensitiveText(error.toString())}',
      );
      return 1;
    } finally {
      await writer?.close();
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
  List<String> _dedupeVmStdoutEcho(List<String> lines) =>
      FlutterScoutCli.dedupeVmStdoutEcho(lines);

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
