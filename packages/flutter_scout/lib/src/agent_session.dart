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
  static const actionMethods = {
    'tap',
    'tap-text',
    'long-press',
    'input',
    'fill',
    'scroll',
    'swipe',
    'scroll-to',
    'back',
    'dismiss',
    'reveal',
    'drag-start',
    'drag-move',
    'drag-end',
    'drag-cancel',
    'deeplink',
  };

  /// Exact handles an action is limited to, or null when its effect is not
  /// scoped to named observed handles (text, coordinates, gestures, routes).
  static Set<String>? scopedTargets(AgentView action) {
    final args = action['args'] ?? const <Object?>[];
    final params = action['params'] ?? const <String, Object?>{};
    if (args is! List || params is! Map) return null;
    Set<String>? handles(Iterable<Object?> values) {
      final result = <String>{};
      for (final value in values) {
        if (value is! String || value.isEmpty || value.trim() != value) {
          return null;
        }
        result.add(value);
      }
      return result.isEmpty ? null : result;
    }

    return switch (action['method']) {
      'tap' ||
      'long-press' when args.length == 1 && params.isEmpty => handles(args),
      'input'
          when args.length == 1 &&
              params.length == 1 &&
              params.containsKey('target') =>
        handles([params['target']]),
      'fill' when args.isEmpty && params.length == 1 && params['json'] is Map =>
        handles((params['json'] as Map).keys),
      _ => null,
    };
  }

  /// Whether [current] differs from [decision] only by in-place text updates
  /// (a ticking clock, a countdown label) outside the exact [targets]. Run,
  /// runtime, screen, route, surface, rendering, safety evidence, field
  /// values, scroll regions, omissions and the shape of every control must
  /// be unchanged; each target must appear once, identical in both views.
  /// Text may change but not appear or disappear. Dispatch-time target
  /// resolution, occlusion and hit-test checks in the app still apply.
  static bool targetUnaffected(
    AgentView decision,
    AgentView current,
    Set<String> targets,
  ) {
    if (targets.isEmpty || decision['ok'] != true || current['ok'] != true) {
      return false;
    }
    for (final key in const [
      'runId',
      'runtimeInstanceId',
      'screen',
      'routeGuess',
      'surfaceOnly',
      'viewport',
      'keyboard',
      'activeBlockingSignals',
      'errorsSinceCursor',
      'errorCursor',
      'recentErrors',
      'errorSummary',
      'safetyEvidenceStatus',
      'perception',
      'payloadBounds',
      'omittedSections',
      'omitted',
      'interactablesOmitted',
      'scrollables',
      'fieldValues',
      'degradedNodes',
      'inspectWarnings',
      'annotationMode',
    ]) {
      if (!_same(decision[key], current[key])) return false;
    }
    Object? pick(Object? value, List<String> keys) => value is Map
        ? {
            for (final key in keys)
              if (value.containsKey(key)) key: value[key],
          }
        : value;
    const surfaceKeys = ['kind', 'label', 'screen', 'source'];
    const renderingKeys = ['status', 'framesEnabled', 'lifecycle'];
    if (!_same(
          pick(decision['activeSurface'], surfaceKeys),
          pick(current['activeSurface'], surfaceKeys),
        ) ||
        !_same(
          pick(decision['rendering'], renderingKeys),
          pick(current['rendering'], renderingKeys),
        )) {
      return false;
    }
    int length(Object? value) =>
        value is List ? value.length : (value == null ? 0 : -1);
    for (final key in const [
      'visibleText',
      'hitTestableText',
      'nonHitTestableText',
      'offscreenText',
      'structuredRows',
    ]) {
      if (length(decision[key]) != length(current[key]) ||
          length(current[key]) < 0) {
        return false;
      }
    }
    final before = decision['interactables'];
    final after = current['interactables'];
    if (before is! List || after is! List || before.length != after.length) {
      return false;
    }
    final found = <String>{};
    for (var i = 0; i < before.length; i++) {
      final a = before[i];
      final b = after[i];
      if (a is! Map || b is! Map) return false;
      if (targets.contains(a['id']) || targets.contains(b['id'])) {
        if (!_same(a, b) || !found.add(a['id'] as String)) return false;
        continue;
      }
      // Unkeyed ids derive from labels, so a countdown button may change id
      // and label in place. Its kind and interaction state must not change.
      for (final key in const [
        'kind',
        'enabled',
        'hitTestable',
        'offscreen',
        'selected',
      ]) {
        if (!_same(a[key], b[key])) return false;
      }
    }
    return found.length == targets.length;
  }

  static bool _same(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every((key) => b.containsKey(key) && _same(a[key], b[key]));
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_same(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

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
  String? _unacknowledgedAction;
  // A delivered not_dispatched receipt releases the hand; remembered only so
  // a documented reconcile call for it is a harmless no-op.
  String? _releasedAction;
  // Recent views by revision, so a decision can be compared with the current
  // screen instead of being rejected for unrelated in-place text updates.
  final Map<int, AgentView> _history = {};
  AgentView? _receipt;
  bool _receiptDelivered = false;
  int _receiptReadCount = 0;
  int reads = 0;
  int actions = 0;

  AgentView get scene => {
    'actionable':
        !_closed &&
        _halt == null &&
        _safe &&
        _acting == null &&
        _unacknowledgedAction == null,
    'viewRevision': _revision,
    'viewAgeMs': _clock.elapsedMilliseconds - _observedAt,
    'view': _view,
    'images': 'manual',
    'hand': {
      'pendingAction': _pendingAction,
      'unacknowledgedAction': _unacknowledgedAction,
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
      'agentProtocol': 2,
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
          _history[_revision] = value;
          if (_history.length > 64) _history.remove(_history.keys.first);
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

  /// Returns the view the decision was made from. A stale revision is
  /// accepted only for an action scoped to exact observed handles when the
  /// screen differs solely by in-place text updates outside those targets.
  AgentView _authorize(int revision, [Set<String>? targets]) {
    if (_closed || _halt != null) throw StateError(_stoppedMessage());
    final decision = revision == _revision ? _view : _history[revision];
    if (revision != _revision &&
        (targets == null ||
            decision == null ||
            _view == null ||
            !targetUnaffected(decision, _view!, targets))) {
      throw StateError(
        'agent_view_changed: viewRevision $revision is stale (now $_revision) '
        'and the change may affect this action; nothing dispatched. Decide '
        'again from the returned scene.',
      );
    }
    if (!_safe) {
      throw StateError(
        'agent_live_view_unavailable: restore rendering/check safety; nothing dispatched',
      );
    }
    return decision!;
  }

  bool get _knownFailure =>
      _receiptDelivered &&
      const {'not_dispatched', 'dispatched'}.contains(_receipt?['dispatch']);

  /// Every stopped-hand rejection names the action and the literal recovery.
  String _stoppedMessage() {
    final id = _unacknowledgedAction;
    if (_closed) {
      return 'agent_session_closed: open a new connection; nothing dispatched';
    }
    if (_halt == 'agent_action_failed' && id != null) {
      if (!_receiptDelivered) {
        return "agent_receipt_required: consume action $id's receipt with "
            'next() first; nothing dispatched';
      }
      if (_knownFailure) {
        return 'agent_action_failed: action $id failed with dispatch '
            '${_receipt?['dispatch']}; inspect its receipt, observe(), then '
            "call reconcile('$id', scene.viewRevision). Nothing dispatched now.";
      }
      return 'agent_action_outcome_unknown: action $id may have reached the '
          'app and cannot be reconciled on this connection. Check app state, '
          'then close() and reconnect. Nothing dispatched now.';
    }
    return 'agent_session_stopped: $_halt; this connection accepts no more '
        'input. Check app state, then close() and reconnect. Nothing '
        'dispatched.';
  }

  /// Explicit native activation shares the hand, without fabricating frames
  /// or acknowledging an outstanding input receipt.
  Future<AgentView> foreground(Future<void> Function() activate) async {
    final knownFailure = _halt == 'agent_action_failed' && _knownFailure;
    if (_closed ||
        (_halt != null && !knownFailure) ||
        _acting != null ||
        (_unacknowledgedAction != null && !knownFailure) ||
        _view?['ok'] != true) {
      throw StateError('Reconcile the existing hand before activating its app');
    }
    final done = Completer<void>();
    _acting = done.future;
    try {
      await activate();
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      do {
        await observe();
        if (_live ||
            _closed ||
            (_halt != null &&
                (!knownFailure || _halt != 'agent_action_failed'))) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } while (DateTime.now().isBefore(deadline));
    } finally {
      _acting = null;
      done.complete();
    }
    return {
      'ok':
          _safe &&
          !_closed &&
          (_halt == null || (knownFailure && _halt == 'agent_action_failed')),
      'foregroundRequested': true,
      'inputDispatched': false,
      ...scene,
    };
  }

  AgentView start(int revision, AgentView action, {String? reactionId}) {
    final decision = _authorize(revision, scopedTargets(action));
    if (_acting != null || _unacknowledgedAction != null) {
      final id = _pendingAction ?? _unacknowledgedAction;
      throw StateError(
        _acting != null
            ? "agent_hand_busy: action $id is in flight; consume its receipt with next() first"
            : _receiptDelivered
            ? "agent_receipt_required: call acknowledge('$id') before another input"
            : "agent_receipt_required: consume action $id's receipt with next(), then acknowledge('$id')",
      );
    }
    validate(action);
    // Clone caller-owned maps before crossing an asynchronous boundary. Fresh
    // preflight compares against the decision view, not a later one.
    final request = jsonDecode(jsonEncode(action)) as AgentView;
    final observed = jsonDecode(jsonEncode(decision)) as AgentView;
    final id = 'a${++_ticket}';
    _pendingAction = id;
    _unacknowledgedAction = id;
    _releasedAction = null;
    _receipt = null;
    _receiptDelivered = false;
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
      _receipt = result;
      _receiptReadCount = reads;
      // A rejection that provably sent nothing leaves app state untouched:
      // the hand is released once its receipt is delivered, never retried.
      if (result['ok'] != true && result['dispatch'] != 'not_dispatched') {
        _stop('agent_action_failed');
      }
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

  /// A received successful input receipt must be acknowledged before more
  /// input. Failed input additionally needs a fresh explicit reconciliation,
  /// except a delivered not_dispatched receipt, which already freed the hand.
  AgentView acknowledge(String actionId) {
    if (_released(actionId)) {
      throw StateError(
        'agent_not_dispatched: action $actionId sent nothing and already '
        'released the hand; no acknowledge or reconcile is needed. Decide '
        'again from the current scene.',
      );
    }
    _requireReceipt(actionId);
    if (_receipt?['ok'] != true) {
      throw StateError(
        'agent_reconciliation_required: action $actionId failed; inspect its '
        "receipt, observe(), then call reconcile('$actionId', scene.viewRevision)",
      );
    }
    _unacknowledgedAction = null;
    return {'ok': true, ...scene};
  }

  bool _released(String actionId) =>
      actionId == _releasedAction && _unacknowledgedAction == null;

  void _requireReceipt(String actionId) {
    if (actionId != _unacknowledgedAction ||
        _receipt == null ||
        !_receiptDelivered) {
      final current = _unacknowledgedAction;
      throw StateError(
        current == null
            ? 'agent_receipt_required: action $actionId is not outstanding'
            : "agent_receipt_required: consume action $current's receipt with next() first",
      );
    }
  }

  AgentView reconcile(String actionId, int revision) {
    if (_released(actionId)) {
      // Nothing was dispatched, so there is nothing to reconcile.
      return {
        'ok': true,
        'previousActionRetried': false,
        'reconciliationRequired': false,
        ...scene,
      };
    }
    _requireReceipt(actionId);
    final retry =
        "observe(), then call reconcile('$actionId', scene.viewRevision)";
    final problem = _closed
        ? 'the connection is closed'
        : _halt == null
        ? 'action $actionId did not fail; acknowledge it instead'
        : _halt != 'agent_action_failed'
        ? 'the hand stopped for $_halt, which reconciliation cannot clear'
        : !_knownFailure
        ? 'action $actionId has an unknown dispatch outcome and stays halted; '
              'check app state, then close() and reconnect'
        : revision != _revision || reads <= _receiptReadCount
        ? 'viewRevision $revision is not a fresh observation after the '
              'receipt; $retry'
        : !_safe
        ? 'rendering is not active and safe; restore visibility '
              '(foreground() on macOS), then $retry'
        : null;
    if (problem != null) {
      throw StateError('agent_reconciliation_unavailable: $problem');
    }
    _halt = null;
    _unacknowledgedAction = null;
    _schedule();
    return {'ok': true, 'previousActionRetried': false, ...scene};
  }

  AgentView watch(
    AgentView condition,
    int timeoutMs, {
    int? revision,
    AgentView? reaction,
  }) {
    if (_closed || _halt != null) throw StateError(_stoppedMessage());
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
      if (_acting != null || _unacknowledgedAction != null) {
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
      _markDelivered(event);
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
    if (_events.isNotEmpty) {
      final event = _events.removeAt(0);
      _markDelivered(event);
      return Future.value(event);
    }
    if (_closed) return Future.value({'type': 'closed'});
    final waiter = _eventWaiter = Completer<AgentView>();
    _eventTimeout = Timer(Duration(milliseconds: timeoutMs), () {
      _eventWaiter = null;
      waiter.complete({'type': 'timeout'});
    });
    return waiter.future;
  }

  void _markDelivered(AgentView event) {
    if (event['type'] == 'action' &&
        event['actionId'] == _unacknowledgedAction) {
      _receiptDelivered = true;
      if (_receipt?['ok'] != true &&
          _receipt?['dispatch'] == 'not_dispatched') {
        _releasedAction = _unacknowledgedAction;
        _unacknowledgedAction = null;
      }
    }
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
