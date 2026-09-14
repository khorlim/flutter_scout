part of 'flutter_scout_cli.dart';

void _validateAgentAction(AgentView action) {
  if (action.keys.any(
        (key) => !const {'method', 'args', 'params'}.contains(key),
      ) ||
      !LiveViewLoop.actionMethods.contains(action['method'])) {
    throw const FormatException('Only documented UI actions are accepted.');
  }
  final validation = _validatePersistentTypedPayload(action);
  final issue = validation.issue;
  if (issue != null) throw FormatException('${issue.code}: ${issue.message}');
  // Check normalized legacy args too: named options in args must not smuggle
  // a long wait, capture, file input, or safety override into the short hand.
  for (final key in {
    ...validation.call!.parameters.keys,
    ...(action['params'] as Map? ?? {}).keys,
  }) {
    if (key.toString().startsWith('expect') ||
        const {
          'capture',
          'screenshot',
          'file',
          'allowErrors',
          'allowMismatch',
          'assertNoErrors',
          'rejectLog',
          'waitMs',
          'verbose',
        }.contains(key)) {
      throw const FormatException(
        'agent uses short receipts; use watch for conditions and manual screenshots. Safety overrides and file input are not supported.',
      );
    }
  }
}

extension _CliAgent on FlutterScoutCli {
  Future<int> _agent(List<String> args) async {
    final parser = ArgParser()
      ..addOption('interval-ms', defaultsTo: '250')
      ..addOption('max-items', defaultsTo: '60');
    final parsed = parser.parse(args);
    final interval = int.tryParse(parsed.option('interval-ms') ?? '');
    final maximum = int.tryParse(parsed.option('max-items') ?? '');
    if (parsed.rest.isNotEmpty ||
        interval == null ||
        interval < 100 ||
        interval > 10000 ||
        maximum == null ||
        maximum < 1 ||
        maximum > 100) {
      throw const ScoutCliException(
        'usage',
        'agent accepts --interval-ms 100..10000 and --max-items 1..100.',
      );
    }
    // Isolate mutable command context, captures and VM caches by lane. The
    // shared named session is fixed; clients cannot switch apps inside agent.
    final observer = FlutterScoutCli().._reuseVmConnection = true;
    final hand = FlutterScoutCli().._reuseVmConnection = true;
    final outputZone = Zone.current;
    final requests = <String, Future<void>>{};
    final seenIds = <String>{};
    late final AgentSession session;
    void printResponse(Map<String, dynamic> value) {
      // Never let action's IOOverrides capture the agent transport response.
      outputZone.run(() {
        _activeSensitiveValues.addAll(hand._activeSensitiveValues);
        _printJson(value, pretty: false);
      });
    }

    session = AgentSession(
      interval: Duration(milliseconds: interval),
      validate: _validateAgentAction,
      read: () async {
        final raw = await observer._call('ext.flutter_scout.inspect', {
          'brief': 'true',
          'maxItems': '$maximum',
        });
        final compact = observer._compactBriefInspect(raw);
        return {
          ...compact,
          ...observer._observationPayload(compact),
          'safetyEvidenceStatus': raw['safetyEvidenceStatus'],
          'payloadBounds': raw['payloadBounds'],
        }..remove('result');
      },
      act: (action, observed) async {
        hand._liveDecisionView = observed;
        hand._agentRequiresLiveRendering = true;
        try {
          final method = action['method'] as String;
          final parameters = <String, dynamic>{
            ...?action['params'] as Map<String, dynamic>?,
          };
          if (_typedMethodContracts[method]!.parameters.containsKey('waitMs')) {
            parameters['waitMs'] = 0;
          }
          final captured = await hand._runTypedCall(
            jsonEncode({
              ...action,
              'params': parameters,
              'idempotencyKey': _newProtocolIdentifier('agent-action'),
            }),
          );
          final result = captured['result'];
          if (result is Map) return Map<String, dynamic>.from(result);
          return {
            'ok': false,
            'dispatch': 'dispatch_outcome_unknown',
            'error': {'code': 'agent_action_outcome_unknown'},
          };
        } finally {
          hand._liveDecisionView = null;
          hand._agentRequiresLiveRendering = false;
        }
      },
    );

    Future<void> handle(Map<String, dynamic> request, String id) async {
      try {
        final method = request['method'];
        final allowed = <String, Set<String>>{
          'observe': {},
          'status': {},
          'next': {'timeoutMs'},
          'start': {'viewRevision', 'action'},
          'watch': {'condition', 'timeoutMs'},
          'react': {'viewRevision', 'condition', 'reaction', 'timeoutMs'},
          'cancel': {'scope', 'conditionId'},
        };
        if (!allowed.containsKey(method) ||
            request.keys.any(
              (key) => !{'id', 'method', ...allowed[method]!}.contains(key),
            )) {
          throw const FormatException('Unsupported method or field');
        }
        Map<String, dynamic> object(String key) {
          final value = request[key];
          if (value is! Map<String, dynamic>) {
            throw FormatException('$key must be an object');
          }
          return value;
        }

        int integer(String key, [int? fallback]) {
          final value = request[key] ?? fallback;
          if (value is! int) throw FormatException('$key must be an integer');
          return value;
        }

        final AgentView result;
        switch (method) {
          case 'observe':
            result = await session.observe();
          case 'status':
            result = {'ok': true, ...session.scene};
          case 'next':
            result = {
              'ok': true,
              'event': await session.nextEvent(integer('timeoutMs', 10000)),
            };
          case 'start':
            result = session.start(integer('viewRevision'), object('action'));
          case 'watch':
            result = session.watch(
              object('condition'),
              integer('timeoutMs', 5000),
            );
          case 'react':
            result = session.watch(
              object('condition'),
              integer('timeoutMs', 5000),
              revision: integer('viewRevision'),
              reaction: object('reaction'),
            );
          case 'cancel':
            if (request['scope'] is! String ||
                (request['conditionId'] != null &&
                    request['conditionId'] is! String)) {
              throw const FormatException('Invalid cancellation identity');
            }
            result = session.cancel(
              request['scope'] as String,
              conditionId: request['conditionId'] as String?,
            );
          default:
            throw const FormatException('Unsupported method');
        }
        printResponse({'id': id, ...result});
      } catch (error) {
        printResponse({
          'id': id,
          'ok': false,
          'dispatch': 'not_dispatched',
          'error': {
            'code': 'agent_request_rejected',
            'message': error.toString(),
          },
          'retry': 'never_automatic',
        });
      }
    }

    try {
      printResponse({'type': 'ready', ...await session.open()});
      await for (final line in _boundedLiveLines(stdin)) {
        try {
          final request = jsonDecode(line);
          if (request is! Map<String, dynamic>) {
            throw const FormatException('Object required');
          }
          final id = request['id'];
          if (id is! String ||
              !RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id) ||
              seenIds.contains(id)) {
            throw const FormatException(
              'Unique id of 1..64 ASCII letters/digits/_/- required',
            );
          }
          if (requests.length >= 16 || seenIds.length >= 10000) {
            throw const FormatException('Session request limit reached');
          }
          seenIds.add(id);
          if (request['method'] == 'close') {
            if (request.keys.any(
              (key) => !const {'id', 'method'}.contains(key),
            )) {
              throw const FormatException('Unexpected close field');
            }
            await session.close();
            printResponse({
              'id': id,
              'ok': true,
              'type': 'closed',
              'inflightActionCancelled': false,
            });
            break;
          }
          // Reserve before scheduling: concurrent next/observe never block
          // reception of an explicit stop or cancellation on stdin.
          final completed = Completer<void>();
          requests[id] = completed.future;
          unawaited(
            handle(request, id).whenComplete(() {
              requests.remove(id);
              completed.complete();
            }),
          );
        } on FormatException catch (error) {
          printResponse({
            'ok': false,
            'dispatch': 'not_dispatched',
            'error': {
              'code': 'invalid_agent_request',
              'message': error.message,
            },
          });
        }
      }
      return 0;
    } finally {
      await session.close();
      await Future.wait(requests.values.toList());
      await observer._disposeCachedVmService();
      await hand._disposeCachedVmService();
    }
  }
}
