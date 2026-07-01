part of 'flutter_scout_cli.dart';

// part: interaction commands: bounds-adjacent tap/input/tap-text/long-press/fill/wait/reload/restart/scroll/swipe/scroll-to/back/deeplink/logs.

extension _CliActions on FlutterScoutCli {
  Future<int> _tap(List<String> args) async {
    final parser = ArgParser()
      ..addOption('x')
      ..addOption('y')
      ..addOption('wait-ms', defaultsTo: '1500')
      ..addFlag('verbose', defaultsTo: false);
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
    );
  }

  Future<int> _input(List<String> args) async {
    final parser = ArgParser()
      ..addOption('target')
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    final valueArgs = parsed.rest;
    if (valueArgs.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout input [--target <field>] <value>',
      );
    }
    final value = valueArgs.join(' ');
    final target = parsed.option('target') ?? 'focused';
    return _callAndPrint(
      'ext.flutter_scout.input',
      params: {'target': target, 'value': value},
      record: {'cmd': 'input', 'target': target, 'value': value},
      compact: !parsed.flag('verbose'),
    );
  }

  Future<int> _tapText(List<String> args) async {
    final parser = ArgParser()
      ..addOption('wait-ms', defaultsTo: '1500')
      ..addFlag('allow-mismatch', defaultsTo: false, negatable: false)
      ..addFlag('verbose', defaultsTo: false);
    final parsed = parser.parse(args);
    if (parsed.rest.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout tap-text <visible text>',
      );
    }
    final text = parsed.rest.join(' ');
    final params = <String, String>{
      'text': text,
      'waitMs': parsed.option('wait-ms') ?? '1500',
      if (parsed.flag('allow-mismatch')) 'allowMismatch': 'true',
    };
    var result = await _call('ext.flutter_scout.tapText', params);
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
    final parsed = parser.parse(args);
    final raw = parsed.option('json');
    if (raw == null || raw.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout fill --json <object>',
      );
    }
    jsonDecode(raw);
    return _callAndPrint(
      'ext.flutter_scout.fill',
      params: {'values': raw},
      record: {'cmd': 'fill', 'values': jsonDecode(raw)},
      compact: !parsed.flag('verbose'),
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
      ..addOption('direction', defaultsTo: 'down')
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
    final params = <String, String>{
      'target': target,
      'maxScrolls': parsed.option('max-scrolls') ?? '20',
      'direction': parsed.option('direction') ?? 'down',
      if (parsed.option('distance') != null)
        'distance': parsed.option('distance')!,
    };
    return _callAndPrint(
      'ext.flutter_scout.scrollTo',
      params: params,
      record: {'cmd': 'scroll-to', ...params},
      compact: !parsed.flag('verbose'),
    );
  }

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
