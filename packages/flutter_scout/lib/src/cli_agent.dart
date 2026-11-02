part of 'flutter_scout_cli.dart';

void _validateAgentAction(AgentView action) {
  if (action.keys.any(
        (key) => !const {'method', 'args', 'params'}.contains(key),
      ) ||
      !AgentSession.actionMethods.contains(action['method'])) {
    throw const FormatException('Only documented UI actions are accepted.');
  }
  final validation = _validatePersistentTypedPayload(action);
  final issue = validation.issue;
  if (issue != null) {
    throw FormatException(
      '${issue.code}: '
      '${issue.detailedMessage(exclude: _isAgentRejectedParameter)}',
    );
  }
  if (action['method'] == 'input' && validation.call!.positional.length != 1) {
    throw const FormatException(
      'input accepts exactly one value in args; put the observed field handle in params.target, or use fill with a field-to-value map.',
    );
  }
  // Check normalized legacy args too: named options in args must not smuggle
  // a long wait, capture, file input, or safety override into the short hand.
  for (final key in {
    ...validation.call!.parameters.keys,
    ...(action['params'] as Map? ?? {}).keys,
  }) {
    if (_isAgentRejectedParameter(key.toString())) {
      throw const FormatException(
        'agent uses short receipts; use watch for conditions and manual screenshots. Safety overrides and file input are not supported.',
      );
    }
  }
}

/// Typed parameters the agent's short hand never accepts: long waits,
/// expectations, capture, file input and safety overrides.
bool _isAgentRejectedParameter(String key) =>
    key.startsWith('expect') ||
    const {
      'capture',
      'screenshot',
      'file',
      'stdin',
      'urlFile',
      'urlStdin',
      'allowErrors',
      'allowMismatch',
      'assertNoErrors',
      'rejectLog',
      'waitMs',
      'verbose',
    }.contains(key);

extension _CliAgent on FlutterScoutCli {
  /// The agent's view of one brief inspect. Observer reads and target-scoped
  /// mutation preflight share it so their decision fields stay comparable.
  Map<String, dynamic> _agentObservation(Map<String, dynamic> raw) {
    final compact = _compactBriefInspect(raw);
    return {
      ...compact,
      ..._observationPayload(compact),
      'safetyEvidenceStatus': raw['safetyEvidenceStatus'],
      'payloadBounds': raw['payloadBounds'],
    }..remove('result');
  }

  /// Requests native activation of the connected VM's macOS app and returns
  /// its PID. Each refusal names its cause; no UI input is ever sent.
  Future<int> _foregroundAgentApp() async {
    const noInput = 'No activation took effect and no UI input was sent.';
    if (!Platform.isMacOS || _readDevice() != 'macos') {
      throw AgentRejection(
        'agent_foreground_unsupported',
        'foreground exists only for a named macOS session. $noInput',
        nextStep: 'make the app visible on its device, then observe() again',
      );
    }
    final service = _cachedVmService;
    int? processId;
    try {
      processId = service == null
          ? null
          : (await service.getVM().timeout(const Duration(seconds: 5))).pid;
    } catch (_) {
      processId = null;
    }
    final command = processId == null ? null : await _processCommand(processId);
    if (processId == null ||
        processId <= 0 ||
        command == null ||
        !command.contains('.app/Contents/MacOS/')) {
      throw AgentRejection(
        'agent_foreground_app_unidentifiable',
        'the connected VM did not report the PID of a running macOS .app '
            'bundle, so Scout cannot activate it safely. $noInput',
        nextStep:
            'check the session with status; bring the app forward by '
            'hand if it is still running',
        details: {'vmPidReported': processId != null},
      );
    }
    // PID comes from the connected VM, never from a caller-selected app name.
    // NSRunningApplication activates an existing app only; no launch, input,
    // Accessibility dependency, hidden-state override or frame pumping.
    const script = r'''
ObjC.import('AppKit');
function run(argv) {
  var app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(argv[0]));
  if (!app || app.isNil() || app.isTerminated) return 'not-running';
  app.unhide;
  return app.activateWithOptions(3) ? 'activation-requested' : 'refused';
}
''';
    final result = await _runBoundedNativeProcess(
      '/usr/bin/osascript',
      ['-l', 'JavaScript', '-e', script, '$processId'],
      timeout: const Duration(seconds: 5),
      maxStdoutBytes: 1024,
      maxStderrBytes: 1024,
    );
    final status = result.stdoutText.trim();
    if (result.exitCode == 0 &&
        !result.timedOut &&
        !result.outputExceeded &&
        status == 'activation-requested') {
      return processId;
    }
    final details = {'pid': processId, 'osascriptStatus': status};
    if (status == 'not-running') {
      throw AgentRejection(
        'agent_foreground_app_not_running',
        'macOS reports no running app for the connected VM PID $processId. '
            '$noInput',
        nextStep: 'check the session with status before any further input',
        details: details,
      );
    }
    if (status == 'refused') {
      throw AgentRejection(
        'agent_foreground_activation_refused',
        'macOS refused to activate the app (PID $processId). $noInput',
        nextStep: 'bring the app window forward by hand, then observe() again',
        details: details,
      );
    }
    throw AgentRejection(
      'agent_foreground_activation_failed',
      'the native activation helper failed (exit ${result.exitCode}, '
          'timedOut ${result.timedOut}). $noInput',
      nextStep: 'bring the app window forward by hand, then observe() again',
      details: {...details, 'exitCode': result.exitCode},
    );
  }

  /// The frontmost macOS app after a foreground wait, read passively from
  /// NSWorkspace, so a failure can say who holds focus. Best effort.
  Future<Map<String, dynamic>> _frontmostMacApp(int? targetPid) async {
    const script = r'''
ObjC.import('AppKit');
function run() {
  var app = $.NSWorkspace.sharedWorkspace.frontmostApplication;
  if (!app || app.isNil()) return '{}';
  return JSON.stringify({pid: app.processIdentifier, name: ObjC.unwrap(app.localizedName)});
}
''';
    final result = await _runBoundedNativeProcess(
      '/usr/bin/osascript',
      ['-l', 'JavaScript', '-e', script],
      timeout: const Duration(seconds: 2),
      maxStdoutBytes: 1024,
      maxStderrBytes: 1024,
    );
    Object? decoded;
    try {
      decoded = result.exitCode == 0 ? jsonDecode(result.stdoutText) : null;
    } on FormatException {
      decoded = null;
    }
    final pid = decoded is Map ? decoded['pid'] : null;
    final name = decoded is Map ? decoded['name'] : null;
    return {
      'frontmostApp': name is String ? name : null,
      if (pid is int && targetPid != null)
        'frontmostIsTarget': pid == targetPid,
    };
  }

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
    // A daemon started by an older binary does not participate in the agent
    // lease. Never create a second hand alongside that existing controller.
    final legacyController = _readSessionMeta()?['serve'];
    final legacyPid = legacyController is Map
        ? int.tryParse('${legacyController['pid'] ?? ''}')
        : null;
    if (legacyPid != null &&
        await _matchesOwnedServeProcess(legacyPid, legacyController)) {
      throw const ScoutCliException(
        'agent_session_busy',
        'A pre-cutover controller still owns this app. Have its owner close the legacy controller before connecting; the app was not stopped.',
      );
    }
    final lease = _openPrivateAppendFile(
      p.join(_sessionDir.path, 'agent.lock'),
    );
    try {
      lease.lockSync(FileLock.exclusive);
    } on FileSystemException {
      lease.closeSync();
      throw const ScoutCliException(
        'agent_session_busy',
        'This named app already has an agent connection. Reuse its owner; no second hand was opened.',
      );
    }
    try {
      // Isolate mutable command context, captures and VM caches by lane. The
      // shared named session is fixed; clients cannot switch apps inside agent.
      final observer = FlutterScoutCli()
        .._reuseVmConnection = true
        .._agentLane = true;
      final hand = FlutterScoutCli()
        .._reuseVmConnection = true
        .._agentLane = true;
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
        foregroundAvailable: Platform.isMacOS && _readDevice() == 'macos',
        validate: _validateAgentAction,
        read: () async {
          final Map<String, dynamic> raw;
          try {
            raw = await observer._call('ext.flutter_scout.inspect', {
              'brief': 'true',
              'maxItems': '$maximum',
            });
          } on ScoutCliException catch (error) {
            // Keep the CLI-authored cause (e.g. helper not registered) so the
            // ready/observe response says why the app is not observable.
            return {
              'ok': false,
              'error': {'code': error.code, 'message': error.message},
            };
          }
          final capabilities = raw['capabilities'];
          return {
            ...observer._agentObservation(raw),
            // Agent input needs the helper's dispatch-time rendering guard.
            if (raw['ok'] == true &&
                (capabilities is! Map ||
                    capabilities['liveRenderingGuardV1'] != true))
              'missingHelperCapabilities': const ['liveRenderingGuardV1'],
          };
        },
        act: (action, observed) async {
          hand._liveDecisionView = observed;
          hand._liveDecisionTargets = AgentSession.scopedTargets(action);
          hand._liveDecisionMaxItems = maximum;
          hand._agentRequiresLiveRendering = true;
          try {
            final method = action['method'] as String;
            final parameters = <String, dynamic>{
              ...?action['params'] as Map<String, dynamic>?,
            };
            if (_typedMethodContracts[method]!.parameters.containsKey(
              'waitMs',
            )) {
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
            hand._liveDecisionTargets = null;
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
            'acknowledge': {'actionId'},
            'reconcile': {'actionId', 'viewRevision'},
            'query': {'query'},
            'foreground': <String>{},
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
            case 'foreground':
              int? activatedPid;
              result = await session.foreground(
                () async => activatedPid = await observer._foregroundAgentApp(),
                diagnose: () => observer._frontmostMacApp(activatedPid),
              );
            case 'query':
              final query = object('query');
              if (!const {
                    'inspect',
                    'where',
                    'locate',
                    'bounds',
                    'drag-status',
                  }.contains(query['method']) ||
                  query.keys.any(
                    (key) => !const {'method', 'args', 'params'}.contains(key),
                  )) {
                throw const FormatException(
                  'query accepts only inspect, where, locate, bounds, drag-status',
                );
              }
              // Rare focused queries have isolated mutable CLI context. They
              // never share it with the continuously pending observer read.
              final reader = FlutterScoutCli().._agentLane = true;
              final captured = await reader._runTypedCall(jsonEncode(query));
              final body = captured['result'];
              result = body is Map
                  ? {
                      'ok': body['ok'] == true,
                      'queryResult': Map<String, dynamic>.from(body),
                    }
                  : {
                      'ok': false,
                      'error':
                          captured['error'] ?? {'code': 'agent_query_failed'},
                    };
            case 'acknowledge':
            case 'reconcile':
              final actionId = request['actionId'];
              if (actionId is! String) {
                throw const FormatException('actionId must be a string');
              }
              result = method == 'acknowledge'
                  ? session.acknowledge(actionId)
                  : session.reconcile(actionId, integer('viewRevision'));
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
            // A named rejection keeps its cause, next step and facts.
            'error': error is AgentRejection
                ? error.toError()
                : {
                    'code': 'agent_request_rejected',
                    'message': error.toString(),
                  },
            'retry': 'never_automatic',
            // The current scene lets one fresh decision follow a rejected
            // hand request without another round trip. It is not a retry.
            if (const {
              'start',
              'react',
              'acknowledge',
              'reconcile',
              'foreground',
            }.contains(request['method']))
              'scene': session.scene,
          });
        }
      }

      try {
        printResponse({'type': 'ready', ...await session.open()});
        await for (final line in _boundedAgentLines(stdin)) {
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
    } finally {
      try {
        lease.unlockSync();
      } finally {
        lease.closeSync();
      }
    }
  }
}
