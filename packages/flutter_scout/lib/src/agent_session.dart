import 'dart:async';
import 'dart:convert';

typedef AgentView = Map<String, dynamic>;
typedef AgentRead = Future<AgentView> Function();
typedef AgentAct =
    Future<AgentView> Function(AgentView action, AgentView observed);
typedef AgentValidate = void Function(AgentView action);

/// One guarded hand, independent passive eyes, and bounded one-shot reactions.
/// No routes, app-specific logic, automatic retries, or implicit success waits.
class AgentSession {
  AgentSession({
    required this.read,
    required this.act,
    required this.validate,
    this.interval = const Duration(milliseconds: 250),
    this.maxEvents = 64,
  }) {
    if (interval <= Duration.zero || maxEvents < 1 || maxEvents > 256) {
      throw ArgumentError('Positive interval and maxEvents 1..256 required');
    }
  }

  final AgentRead read;
  final AgentAct act;
  final AgentValidate validate;
  final Duration interval;
  final int maxEvents;
  final Stopwatch _clock = Stopwatch()..start();
  final List<AgentView> _events = [];
  final Map<String, _ConditionJob> _jobs = {};
  Future<AgentView>? _reading;
  Future<void>? _acting;
  Completer<AgentView>? _eventWaiter;
  Timer? _eventTimeout;
  Timer? _poll;
  AgentView? _view;
  String? _viewKey;
  String? _runtime;
  String? _run;
  String? _halt;
  bool _closed = false;
  int _revision = 0;
  int _sequence = 0;
  int _ticket = 0;
  int _observedAt = 0;
  String? _pendingAction;
  int reads = 0;
  int actions = 0;

  AgentView get scene => {
    'viewRevision': _revision,
    'viewAgeMs': _clock.elapsedMilliseconds - _observedAt,
    'view': _view,
    'images': 'manual',
    'hand': {
      'pendingAction': _pendingAction,
      'halted': _halt,
      'closed': _closed,
    },
    'metrics': {
      'reads': reads,
      'actions': actions,
      'queuedEvents': _events.length,
    },
  };

  Future<AgentView> open() async {
    if (_view != null || _closed) {
      throw StateError('Session already opened/closed');
    }
    await observe();
    _schedule();
    return {
      'ok': _view?['ok'] == true && _halt == null,
      'agentProtocol': 1,
      ...scene,
    };
  }

  void _schedule() {
    _poll?.cancel();
    if (_closed || _halt != null) return;
    _poll = Timer(interval, () async {
      await observe();
      _schedule();
    });
  }

  Future<AgentView> observe() {
    if (_closed) throw StateError('Session closed');
    if (_reading != null) return _reading!;
    final done = Completer<AgentView>();
    _reading = done.future;
    () async {
      AgentView value;
      try {
        // Own the snapshot and reject malformed metadata before any job can
        // use it. A bad read must resolve, not strand the observation lane.
        value = jsonDecode(jsonEncode(await read())) as AgentView;
        for (final key in [
          'rendering',
          'activeSurface',
          'payloadBounds',
          'omittedSections',
        ]) {
          if (value[key] != null && value[key] is! Map) {
            throw FormatException('Invalid $key');
          }
        }
        for (final key in [
          'interactables',
          'visibleText',
          'activeBlockingSignals',
          'errorsSinceCursor',
          'recentErrors',
        ]) {
          if (value[key] != null && value[key] is! List) {
            throw FormatException('Invalid $key');
          }
        }
        for (final key in ['runId', 'runtimeInstanceId', 'snapshotId']) {
          if (value[key] != null && value[key] is! String) {
            throw FormatException('Invalid $key');
          }
        }
      } catch (_) {
        value = {
          'ok': false,
          'error': {'code': 'agent_observation_unavailable'},
        };
      }
      reads++;
      if (!_closed) {
        final rendering = value['rendering'] as Map?;
        final key = jsonEncode([
          value['ok'],
          value['runId'],
          value['runtimeInstanceId'],
          value['snapshotId'],
          rendering?['status'],
          rendering?['framesEnabled'],
          rendering?['lifecycle'],
          value['activeBlockingSignals'],
          value['errorsSinceCursor'],
          value['recentErrors'],
          value['perception'],
          value['payloadBounds'],
          value['error'],
        ]);
        final changed = key != _viewKey;
        _view = value;
        _observedAt = _clock.elapsedMilliseconds;
        if (changed) {
          _revision++;
          _viewKey = key;
        }
        if (value['ok'] != true) {
          _stop('agent_observation_unavailable');
        } else if (_runtime != null &&
            (_runtime != value['runtimeInstanceId'] ||
                _run != value['runId'])) {
          _stop('agent_runtime_changed');
        } else {
          _runtime ??= value['runtimeInstanceId'] as String?;
          _run ??= value['runId'] as String?;
          if ((_runtime ?? '').isEmpty ||
              (_run ?? '').isEmpty ||
              (value['snapshotId'] as String? ?? '').isEmpty) {
            _stop('agent_identity_unavailable');
          }
        }
        if (changed) _emit('view', {'viewRevision': _revision, 'view': value});
        _evaluateJobs();
      }
      _reading = null;
      done.complete({'ok': value['ok'] == true && _halt == null, ...scene});
    }();
    return done.future;
  }

  bool get _live =>
      _view?['ok'] == true &&
      (_view?['rendering'] as Map?)?['status'] == 'active' &&
      (_view?['rendering'] as Map?)?['framesEnabled'] == true;
  bool get _safe =>
      _live &&
      (_view?['activeBlockingSignals'] as List? ?? []).isEmpty &&
      (_view?['errorsSinceCursor'] as List? ?? []).isEmpty &&
      _view?['safetyEvidenceStatus'] == 'complete';

  void _authorize(int revision) {
    if (_closed || _halt != null) {
      throw StateError('Session stopped: ${_halt ?? 'closed'}');
    }
    if (revision != _revision) {
      throw StateError(
        'agent_view_changed: observe and decide again; nothing dispatched',
      );
    }
    if (!_safe) {
      throw StateError(
        'agent_live_view_unavailable: restore rendering/check safety; nothing dispatched',
      );
    }
  }

  AgentView start(int revision, AgentView action, {String? reactionId}) {
    _authorize(revision);
    if (_acting != null) {
      throw StateError('agent_hand_busy: nothing queued or dispatched');
    }
    validate(action);
    // Clone caller-owned maps before crossing an asynchronous boundary.
    final request = jsonDecode(jsonEncode(action)) as AgentView;
    final observed = jsonDecode(jsonEncode(_view)) as AgentView;
    final id = 'a${++_ticket}';
    _pendingAction = id;
    actions++;
    final started = _clock.elapsedMilliseconds;
    final done = Completer<void>();
    _acting = done.future;
    () async {
      AgentView result;
      try {
        result = await act(request, observed);
      } catch (_) {
        result = {
          'ok': false,
          'dispatch': 'dispatch_outcome_unknown',
          'error': {'code': 'agent_action_outcome_unknown'},
        };
      }
      _pendingAction = null;
      _acting = null;
      if (result['ok'] != true) _stop('agent_action_failed');
      _emit('action', {
        'actionId': id,
        'reactionId': ?reactionId,
        'phase': 'finished',
        'startedAtMs': started,
        'finishedAtMs': _clock.elapsedMilliseconds,
        'result': result,
        'businessCompletion': 'not_asserted',
      });
      done.complete();
      if (!_closed) await observe();
    }();
    return {
      'ok': true,
      'actionId': id,
      'phase': 'accepted',
      'dispatch': 'not_yet_established',
      'businessCompletion': 'not_asserted',
    };
  }

  AgentView watch(
    AgentView condition,
    int timeoutMs, {
    int? revision,
    AgentView? reaction,
  }) {
    if (_closed || _halt != null) throw StateError('Session stopped');
    if (_jobs.length >= 8) throw StateError('agent_condition_limit');
    if (timeoutMs < 1 || timeoutMs > 30000) {
      throw ArgumentError('timeoutMs must be 1..30000');
    }
    _validateCondition(condition);
    if (reaction != null) {
      _authorize(revision ?? -1);
      if (!const {'stop', 'tap'}.contains(reaction['type']) ||
          reaction.keys.any((k) => !const {'type', 'target'}.contains(k))) {
        throw ArgumentError('Reaction must be stop or one exact tap');
      }
      if (reaction['type'] == 'tap') {
        final target = reaction['target'];
        if (target is! String || target.isEmpty || !_observedTarget(target)) {
          throw ArgumentError(
            'Reaction target must be an observed exact handle',
          );
        }
        validate({
          'method': 'tap',
          'args': [target],
          'params': <String, dynamic>{},
        });
      } else if (reaction.containsKey('target')) {
        throw ArgumentError('Stop has no target');
      }
    }
    final id = '${reaction == null ? 'w' : 'r'}${++_ticket}';
    final job = _ConditionJob(
      id,
      Map.of(condition),
      reaction == null ? null : Map.of(reaction),
      _clock.elapsedMilliseconds + timeoutMs,
      _view?['screen'],
      _surface(),
    );
    _jobs[id] = job;
    job.timer = Timer(
      Duration(milliseconds: timeoutMs),
      () => _finishJob(job, 'timeout'),
    );
    // Defer evaluation so acceptance is always returned before completion.
    scheduleMicrotask(_evaluateJobs);
    return {
      'ok': true,
      'conditionId': id,
      'oneShot': true,
      'timeoutMs': timeoutMs,
    };
  }

  bool _observedTarget(String target) =>
      (_view?['interactables'] as List? ?? [])
          .whereType<Map>()
          .where((node) => node['id'] == target)
          .length ==
      1;

  static void _validateCondition(AgentView condition) {
    if (condition.length != 1 ||
        !const {
          'text',
          'gone',
          'screen',
          'surfaceChanged',
        }.contains(condition.keys.single)) {
      throw ArgumentError(
        'Exactly one text, gone, screen, or surfaceChanged condition required',
      );
    }
    final value = condition.values.single;
    if (condition.containsKey('surfaceChanged')) {
      if (value != true) throw ArgumentError('surfaceChanged must be true');
    } else if (value is! String || value.isEmpty || value.length > 1000) {
      throw ArgumentError('Condition string must contain 1..1000 characters');
    }
  }

  String _surface() => jsonEncode([_view?['screen'], _view?['activeSurface']]);
  bool _matches(_ConditionJob job) {
    final c = job.condition;
    final texts = _view?['visibleText'] as List? ?? [];
    if (c.containsKey('text')) return texts.contains(c['text']);
    if (c.containsKey('gone')) {
      // Brief omission is not proof of absence.
      final omitted = _view?['omitted'];
      if (omitted is Map) {
        final textOmitted = omitted['visibleText'];
        if (textOmitted != null && textOmitted != 0) return false;
      } else if (omitted != null && omitted != 0 && omitted != false) {
        return false;
      }
      final sections = (_view?['omittedSections'] as Map?)?['sections'];
      if (sections != null &&
          (sections is! List || sections.contains('visibleText'))) {
        return false;
      }
      return !texts.contains(c['gone']);
    }
    if (c.containsKey('screen')) return _view?['screen'] == c['screen'];
    return _surface() != job.surface;
  }

  void _evaluateJobs() {
    if (_closed || _halt != null) return;
    for (final job in _jobs.values.toList()) {
      if (_clock.elapsedMilliseconds >= job.deadline) {
        _finishJob(job, 'timeout');
        continue;
      }
      if (!_safe) {
        _finishJob(job, 'observation_unavailable');
        continue;
      }
      final reaction = job.reaction;
      if (reaction != null &&
          reaction['type'] == 'tap' &&
          (_view?['screen'] != job.screen || _surface() != job.surface)) {
        _finishJob(job, 'context_changed');
        continue;
      }
      if (!_matches(job)) continue;
      if (reaction == null) {
        _finishJob(job, 'met');
        continue;
      }
      if (reaction['type'] == 'stop') {
        _finishJob(job, 'triggered');
        _stop('agent_reaction_stop');
        break;
      }
      if (_acting != null) {
        // Latch evidence, but never dispatch a stale queued reaction later.
        if (!job.notified) {
          job.notified = true;
          _emit('reaction', {
            'conditionId': job.id,
            'status': 'hand_busy',
            'viewRevision': _revision,
          });
        }
        continue;
      }
      if (!_observedTarget(reaction['target'] as String)) {
        _finishJob(job, 'target_unavailable');
        continue;
      }
      _jobs.remove(job.id);
      job.timer?.cancel();
      try {
        final ticket = start(_revision, {
          'method': 'tap',
          'args': [reaction['target']],
          'params': <String, dynamic>{},
        }, reactionId: job.id);
        _emit('reaction', {
          'conditionId': job.id,
          'status': 'triggered',
          'actionId': ticket['actionId'],
        });
      } catch (_) {
        _emit('reaction', {
          'conditionId': job.id,
          'status': 'not_dispatched',
          'retry': 'never_automatic',
        });
      }
    }
  }

  void _finishJob(_ConditionJob job, String status) {
    if (_jobs.remove(job.id) == null) return;
    job.timer?.cancel();
    _emit(job.reaction == null ? 'condition' : 'reaction', {
      'conditionId': job.id,
      'status': status,
      'viewRevision': _revision,
      'view': _view,
      'inflightActionCancelled': false,
    });
  }

  AgentView cancel(String scope, {String? conditionId}) {
    if (scope == 'wait') {
      final job = _jobs[conditionId];
      if (job == null || job.reaction != null) {
        throw ArgumentError('Unknown wait conditionId');
      }
      _finishJob(job, 'cancelled');
    } else if (scope == 'reaction') {
      final job = _jobs[conditionId];
      if (job == null || job.reaction == null) {
        throw ArgumentError('Unknown reaction conditionId');
      }
      _finishJob(job, 'cancelled');
    } else if (scope == 'actions') {
      _stop('agent_caller_stop');
    } else {
      throw ArgumentError(
        'Use wait, reaction, or actions; app-operation cancellation requires an explicit app action',
      );
    }
    return {
      'ok': true,
      'scope': scope,
      'inflightActionCancelled': false,
      'appOperationCancelled': false,
    };
  }

  void _stop(String reason) {
    if (_halt != null) return;
    _halt = reason;
    _poll?.cancel();
    for (final job in _jobs.values.toList()) {
      _finishJob(job, 'stopped');
    }
    _emit('stopped', {'reason': reason, 'inflightActionCancelled': false});
  }

  void _emit(String type, AgentView data) {
    // Reserve terminal evidence rather than silently dropping alerts. There
    // can be at most one in-flight hand receipt after an overflow halt.
    if (_eventWaiter == null &&
        _events.length >= maxEvents &&
        !const {'stopped', 'closed'}.contains(type)) {
      _stop('agent_event_overflow');
      if (type != 'action') return;
    }
    final event = <String, dynamic>{
      'type': type,
      'sequence': ++_sequence,
      'observedAtMs': _clock.elapsedMilliseconds,
      ...data,
    };
    if (_eventWaiter != null) {
      final waiter = _eventWaiter!;
      _eventWaiter = null;
      _eventTimeout?.cancel();
      waiter.complete(event);
      return;
    }
    _events.add(event);
  }

  Future<AgentView> nextEvent(int timeoutMs) {
    if (timeoutMs < 0 || timeoutMs > 30000) {
      throw ArgumentError('timeoutMs must be 0..30000');
    }
    if (_eventWaiter != null) throw StateError('Only one pending next request');
    if (_events.isNotEmpty) return Future.value(_events.removeAt(0));
    if (_closed) return Future.value({'type': 'closed'});
    final waiter = _eventWaiter = Completer<AgentView>();
    _eventTimeout = Timer(Duration(milliseconds: timeoutMs), () {
      _eventWaiter = null;
      waiter.complete({'type': 'timeout'});
    });
    return waiter.future;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _poll?.cancel();
    for (final job in _jobs.values.toList()) {
      _finishJob(job, 'cancelled');
    }
    await _acting;
    await _reading;
    _emit('closed', {'inflightActionCancelled': false});
  }
}

class _ConditionJob {
  _ConditionJob(
    this.id,
    this.condition,
    this.reaction,
    this.deadline,
    this.screen,
    this.surface,
  );
  final String id;
  final AgentView condition;
  final AgentView? reaction;
  final int deadline;
  final Object? screen;
  final String surface;
  Timer? timer;
  bool notified = false;
}
