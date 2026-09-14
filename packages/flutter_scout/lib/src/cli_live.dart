part of 'flutter_scout_cli.dart';

extension _CliLive on FlutterScoutCli {
  Future<int> _live(List<String> args) async {
    final parser = ArgParser()
      ..addOption('interval-ms', defaultsTo: '1000')
      ..addOption('max-items', defaultsTo: '30');
    final parsed = parser.parse(args);
    final interval = int.tryParse(parsed.option('interval-ms') ?? '');
    final maxItems = int.tryParse(parsed.option('max-items') ?? '');
    if (parsed.rest.isNotEmpty ||
        interval == null ||
        interval < 250 ||
        interval > 10000 ||
        maxItems == null ||
        maxItems < 1 ||
        maxItems > 100) {
      throw const ScoutCliException(
        'usage',
        'live accepts --interval-ms 250..10000 and --max-items 1..100.',
      );
    }
    final hadReuse = _reuseVmConnection;
    _reuseVmConnection = true;
    final loop = LiveViewLoop(
      settle: () async {
        final result = await _call('ext.flutter_scout.waitStable', {
          'timeoutMs': '1500',
        });
        final payload = {...result, ..._observationPayload(result)};
        return {
          for (final key in [
            'ok',
            'stability',
            'recentErrors',
            'activeBlockingSignals',
            'errorsSinceCursor',
            'error',
            'structuredError',
          ])
            if (payload.containsKey(key)) key: payload[key],
        };
      },
      read: () async {
        final result = await _call('ext.flutter_scout.inspect', {
          'brief': 'true',
          'maxItems': '$maxItems',
        });
        final brief = _compactBriefInspect(result);
        final compact = <String, dynamic>{
          ...brief,
          ..._observationPayload(brief),
        }..remove('result');
        final signals = _freshRecentLogSignals();
        if (signals.isNotEmpty) {
          compact['recentLogSignals'] = _logSignalMaps(
            signals,
            phase: 'inspect',
          );
        }
        // Retain normal observation/safety fields; remove only repetitive timing
        // and connection diagnostics from the agent's working view.
        for (final key in [
          'timings',
          'capabilities',
          'protocolRange',
          'viewSignature',
          'visibleTextHash',
        ]) {
          compact.remove(key);
        }
        return compact;
      },
      act: (request, observed) async {
        _liveDecisionView = observed;
        try {
          final captured = await _runTypedCall(
            jsonEncode({
              ...request,
              'idempotencyKey': _newProtocolIdentifier('live-action'),
            }),
          );
          final result = captured['result'];
          if (result is Map) {
            final action = Map<String, dynamic>.from(result);
            // Full deltas are already in the normal command evidence. The
            // next view is more useful here than repeating its old geometry.
            for (final key in [
              'delta',
              'timings',
              'capabilities',
              'protocolRange',
            ]) {
              action.remove(key);
            }
            return action;
          }
          return {
            'ok': false,
            // Without a canonical action envelope we cannot establish where
            // capture failed. Do not turn missing evidence into a safe retry.
            'dispatch': 'dispatch_outcome_unknown',
            'error': {
              'code': 'live_action_outcome_unknown',
              'cause': captured['structuredError'] ?? captured['error'],
            },
          };
        } finally {
          _liveDecisionView = null;
        }
      },
    );
    Timer? timer;
    try {
      _printJson({'mode': 'live', ...await loop.observe()}, pretty: false);
      timer = Timer.periodic(Duration(milliseconds: interval), (_) {
        unawaited(loop.refreshInBackground());
      });
      await for (final line in _boundedLiveLines(stdin)) {
        Map<String, dynamic> response;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map<String, dynamic>) throw const FormatException();
          final method = decoded['method'];
          if (method == 'close') break;
          if (method == 'observe') {
            response = await loop.observe();
          } else if (method == 'wait') {
            final viewId = decoded['viewId'];
            final timeout = decoded['timeoutMs'] ?? 10000;
            if (viewId is! int ||
                timeout is! int ||
                timeout < 0 ||
                timeout > 30000) {
              throw const FormatException();
            }
            response = await loop.waitForChange(
              viewId,
              Duration(milliseconds: timeout),
            );
          } else {
            response = await loop.perform(decoded);
          }
        } on FormatException {
          response = {
            'ok': false,
            'dispatch': 'not_dispatched',
            'error': {
              'code': 'invalid_live_request',
              'message': 'Expected one valid bounded JSON request.',
            },
          };
        }
        _printJson(response, pretty: false);
      }
      return 0;
    } finally {
      timer?.cancel();
      await loop.drain();
      _liveDecisionView = null;
      _reuseVmConnection = hadReuse;
      if (!hadReuse) await _disposeCachedVmService();
    }
  }
}

Stream<String> _boundedLiveLines(Stream<List<int>> input) async* {
  final pending = <int>[];
  await for (final chunk in input) {
    for (final byte in chunk) {
      if (byte == 10) {
        final line = utf8.decode(pending).trim();
        pending.clear();
        if (line.isNotEmpty) yield line;
      } else {
        pending.add(byte);
        if (pending.length > 65536) {
          throw const ScoutCliException(
            'live_request_too_large',
            'A live request exceeds 64 KiB.',
          );
        }
      }
    }
  }
  if (pending.isNotEmpty) {
    final line = utf8.decode(pending).trim();
    if (line.isNotEmpty) yield line;
  }
}
