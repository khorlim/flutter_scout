part of 'flutter_scout_cli.dart';

// part: evidence bundle + replay commands and transcript formatting.

extension _CliEvidence on FlutterScoutCli {
  Future<int> _evidence(List<String> args) async {
    final parser = ArgParser()
      ..addOption('output', abbr: 'o')
      ..addOption('last', defaultsTo: '120');
    final parsed = parser.parse(args);
    _ensureSessionDir();
    final output =
        parsed.option('output') ??
        p.join(
          _sessionDir.path,
          'evidence',
          'evidence_${DateTime.now().millisecondsSinceEpoch}',
        );
    final dir = Directory(output);
    dir.createSync(recursive: true);

    final last = int.tryParse(parsed.option('last') ?? '') ?? 120;
    final status = await _statusPayload();
    final logs = await _logsPayload(last: last, contains: null, summary: false);
    final logsSummary = await _logsPayload(
      last: 40,
      contains: null,
      summary: true,
    );
    Map<String, dynamic>? inspect;
    Object? inspectError;
    try {
      inspect = await _call('ext.flutter_scout.inspect');
      File(
        p.join(dir.path, 'inspect.json'),
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(inspect));
    } on ScoutCliException catch (error) {
      inspectError = {'code': error.code, 'message': error.message};
    } catch (error) {
      inspectError = error.toString();
    }

    Map<String, Object?> screenshot = const {
      'ok': false,
      'skipped': true,
      'reason': 'not_attempted',
    };
    final screenshotPath = p.join(dir.path, 'screenshot.png');
    try {
      screenshot = {
        'ok': true,
        'path': screenshotPath,
        ...await _captureScreenshot(screenshotPath),
      };
    } on ScoutCliException catch (error) {
      screenshot = {
        'ok': false,
        'error': {'code': error.code, 'message': error.message},
      };
    } catch (error) {
      screenshot = {
        'ok': false,
        'error': {'code': 'screenshot_failed', 'message': error.toString()},
      };
    }

    final sessionActions = _readSessionActions();
    final summary = {
      'ok': true,
      'path': dir.path,
      'createdAt': DateTime.now().toIso8601String(),
      'status': status,
      'inspect': inspect == null
          ? {'ok': false, 'error': inspectError ?? 'inspect_unavailable'}
          : {
              'ok': true,
              'screen': inspect['screen'],
              'visibleText': _lastItems(
                (inspect['visibleText'] as List?) ?? const [],
                20,
              ),
              'recentErrors': _lastItems(
                (inspect['recentErrors'] as List?) ?? const [],
                5,
              ),
            },
      'screenshot': screenshot,
      'logs': {
        'available': logs['available'],
        'source': logs['source'],
        if (logs['message'] != null) 'message': logs['message'],
        'summary': logsSummary,
      },
      'sessionActions': {
        'path': _sessionFile,
        'count': sessionActions.length,
        'last': _lastItems(sessionActions, 20),
      },
      'files': {
        'summary': p.join(dir.path, 'summary.json'),
        if (inspect != null) 'inspect': p.join(dir.path, 'inspect.json'),
        'logs': p.join(dir.path, 'logs.json'),
        'status': p.join(dir.path, 'status.json'),
        if (sessionActions.isNotEmpty)
          'session': p.join(dir.path, 'session.json'),
        if (screenshot['ok'] == true) 'screenshot': screenshotPath,
      },
    };

    File(
      p.join(dir.path, 'status.json'),
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(status));
    File(
      p.join(dir.path, 'logs.json'),
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(logs));
    if (sessionActions.isNotEmpty) {
      File(p.join(dir.path, 'session.json')).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(sessionActions),
      );
    }
    File(
      p.join(dir.path, 'summary.json'),
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(summary));
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(summary));
    return 0;
  }

  Future<int> _replay(List<String> args) async {
    final parser = ArgParser()..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final file = parsed.rest.isEmpty
        ? File(_sessionFile)
        : File(parsed.rest.first);
    if (!file.existsSync()) {
      throw ScoutCliException(
        'replay_missing',
        'Replay file not found: ${file.path}',
      );
    }
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! List) {
      throw const ScoutCliException(
        'replay_invalid',
        'Replay file must contain a JSON array.',
      );
    }
    final results = <Object?>[];
    final transcript = <String>[];
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      final cmd = item['cmd'];
      final result = switch (cmd) {
        'tap' => await _call('ext.flutter_scout.tap', _stringMap(item)),
        'tap-text' => await _call('ext.flutter_scout.tapText', {
          'text': item['text'].toString(),
          if (item['waitMs'] != null) 'waitMs': item['waitMs'].toString(),
        }),
        'input' => await _call('ext.flutter_scout.input', {
          'target': item['target'].toString(),
          'value': item['value'].toString(),
        }),
        'fill' => await _call('ext.flutter_scout.fill', {
          'values': jsonEncode(item['values']),
        }),
        'long-press' => await _call('ext.flutter_scout.longPress', {
          'target': item['target'].toString(),
          if (item['durationMs'] != null)
            'durationMs': item['durationMs'].toString(),
        }),
        'scroll' => await _call('ext.flutter_scout.scroll', _stringMap(item)),
        'swipe' => await _call('ext.flutter_scout.swipe', _stringMap(item)),
        'scroll-to' => await _call(
          'ext.flutter_scout.scrollTo',
          _stringMap(item),
        ),
        'back' => await _call('ext.flutter_scout.back'),
        'reload' => await _hotUpdate(
          action: 'reload',
          signal: ProcessSignal.sigusr1,
          fullRestart: false,
        ),
        'restart' => await _hotUpdate(
          action: 'restart',
          signal: ProcessSignal.sigusr2,
          fullRestart: true,
        ),
        'deeplink' => await _replayDeeplink(item['url']?.toString()),
        _ => {'ok': false, 'error': 'unknown replay cmd: $cmd'},
      };
      results.add(
        parsed.flag('verbose') || result['ok'] == false
            ? result
            : _compactActionResult(result),
      );
      transcript.add(_transcriptStep(item, result));
    }
    stdout.writeln(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'ok': true, 'transcript': transcript, 'results': results}),
    );
    return 0;
  }

  String _transcriptStep(
    Map<String, dynamic> item,
    Map<String, Object?> result,
  ) {
    final cmd = item['cmd']?.toString() ?? 'unknown';
    final action = switch (cmd) {
      'tap-text' => 'tap-text "${item['text']}"',
      'tap' =>
        item['target'] != null
            ? 'tap ${item['target']}'
            : 'tap ${item['x']},${item['y']}',
      'input' => 'input ${item['target'] ?? 'focused'}',
      'fill' => 'fill ${_filledKeys(item['values'])}',
      'long-press' => 'long-press ${item['target']}',
      'scroll' => 'scroll ${item['direction'] ?? ''}'.trim(),
      'swipe' => 'swipe ${item['direction'] ?? ''}'.trim(),
      'scroll-to' => 'scroll-to ${item['target']}',
      'back' => 'back',
      'reload' => 'reload',
      'restart' => 'restart',
      'deeplink' => 'deeplink ${item['url']}',
      _ => cmd,
    };
    final ok = result['ok'] == false ? 'failed' : 'ok';
    final outcome = result['result'] ?? result['state'] ?? ok;
    final after = result['after'];
    final screen = after is Map ? after['screen'] : null;
    return [action, outcome, if (screen != null) 'screen=$screen'].join(' -> ');
  }

  String _filledKeys(Object? values) {
    if (values is Map) return values.keys.join(', ');
    return 'fields';
  }

  Future<Map<String, Object?>> _replayDeeplink(String? url) async {
    if (url == null || url.isEmpty) {
      return {'ok': false, 'error': 'deeplink replay missing url'};
    }
    try {
      await _openDeeplink(url);
      return {'ok': true, 'url': url};
    } catch (error) {
      return {'ok': false, 'url': url, 'error': error.toString()};
    }
  }

}
