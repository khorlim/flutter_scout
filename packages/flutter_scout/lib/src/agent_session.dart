import 'dart:async';
import 'dart:convert';

typedef AgentView = Map<String, dynamic>;
typedef AgentRead = Future<AgentView> Function();
typedef AgentAct =
    Future<AgentView> Function(AgentView action, AgentView observed);
typedef AgentValidate = void Function(AgentView action);

/// A request the session refused before anything was dispatched. [code] is
/// the specific cause, [nextStep] the literal recovery, and [details] the
/// structured facts behind it. It stays a [StateError] for existing callers.
class AgentRejection extends StateError {
  AgentRejection(
    this.code,
    String text, {
    this.nextStep,
    this.details = const {},
  }) : super('$code: $text');

  final String code;
  final String? nextStep;
  final AgentView details;

  /// The transport error: still a request rejection, with the cause named.
  AgentView toError() => {
    'code': 'agent_request_rejected',
    'reason': code,
    'message': message,
    'nextStep': ?nextStep,
    if (details.isNotEmpty) 'details': details,
  };
}

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
    // One button of an observed native system dialog (iOS Simulator,
    // Android emulator); see [systemTapAuthorization].
    'system-tap',
  };

  /// `tap` options that change how it presses, never where.
  static const _tapPointParams = {'button', 'taps', 'intervalMs'};

  /// `scroll`/`swipe` options that keep the gesture on its named target.
  static const _gestureParams = {'target', 'distance'};

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
      'long-press' when args.length == 1 && params.isEmpty => handles(args),
      // A right click or a double tap is still one exact observed handle.
      'tap'
          when args.length == 1 &&
              params.keys.every(_tapPointParams.contains) =>
        handles(args),
      'input'
          when args.length == 1 &&
              params.length == 1 &&
              params.containsKey('target') =>
        handles([params['target']]),
      'fill' when args.isEmpty && params.length == 1 && params['json'] is Map =>
        handles((params['json'] as Map).keys),
      // A scroll or swipe on a named observed list or control, by direction.
      'scroll' || 'swipe'
          when args.length <= 1 &&
              params['target'] is String &&
              params.keys.every(_gestureParams.contains) =>
        handles([params['target']]),
      _ => null,
    };
  }

  /// Whether [current] differs from [decision] only in ways that cannot
  /// affect an action on the exact [targets]; see [staleReason].
  static bool targetUnaffected(
    AgentView decision,
    AgentView current,
    Set<String> targets, {
    bool allowUnrelatedChanges = false,
  }) =>
      staleReason(
        decision,
        current,
        targets,
        allowUnrelatedChanges: allowUnrelatedChanges,
      ) ==
      null;

  /// Why a decision made on [decision] may no longer hold on [current] for
  /// an action on the exact [targets], or null when it still stands.
  ///
  /// Without [allowUnrelatedChanges] only in-place text updates (a ticking
  /// clock, a countdown label) outside the targets are accepted. Run,
  /// runtime, screen, route, surface, rendering, safety evidence, field
  /// values, scroll regions, omissions and the shape of every control must
  /// be unchanged; each target must appear once, identical in both views.
  /// Text may change but not appear or disappear.
  ///
  /// With [allowUnrelatedChanges] (the caller's explicit per-action
  /// authority), other text and controls may also change, appear or
  /// disappear (a sync toast, a live list, a keypad display the previous
  /// key press updated) while every target is identical, enabled and
  /// hit-testable and run, screen, active surface, rendering, errors and
  /// field values are unchanged. The brief view carries no geometry, so
  /// whether something now covers a target is decided where it can be: the
  /// app's dispatch-time resolution, occlusion and hit-test checks, which
  /// apply to every action either way.
  static String? staleReason(
    AgentView decision,
    AgentView current,
    Set<String> targets, {
    bool allowUnrelatedChanges = false,
  }) => staleChange(
    decision,
    current,
    targets,
    allowUnrelatedChanges: allowUnrelatedChanges,
  )?.reason;

  /// [staleReason] with the facts behind it: `changes` names each changed
  /// field with its observed (`before`) and current (`after`) value, bounded
  /// in size, so a rejection says what changed and not only that it did.
  static ({String reason, List<AgentView> changes})? staleChange(
    AgentView decision,
    AgentView current,
    Set<String> targets, {
    bool allowUnrelatedChanges = false,
  }) {
    if (targets.isEmpty) {
      return (reason: 'the action has no exact observed target', changes: []);
    }
    if (decision['ok'] != true || current['ok'] != true) {
      return (
        reason: 'an observation was unavailable',
        changes: _diff('ok', decision['ok'], current['ok']),
      );
    }
    final shared = _sharedStateChange(decision, current);
    if (shared != null) return shared;
    final target = _targetChange(decision, current, targets);
    if (target != null) return target;
    final layout = _layoutChange(decision, current, targets);
    if (layout == null || allowUnrelatedChanges) return null;
    return (
      reason:
          '${layout.reason} (add "allowUnrelatedChanges": true if that '
          'change is unrelated to this action)',
      changes: layout.changes,
    );
  }

  /// At most this many changed fields are named per rejection.
  static const _maxStaleChanges = 8;

  /// One entry per changed field; maps are narrowed to their changed keys
  /// (`rendering.lifecycle`), so the entry names the exact fact.
  static List<AgentView> _diff(String field, Object? before, Object? after) {
    if (before is Map && after is Map) {
      return [
        for (final key in {...before.keys, ...after.keys})
          if (!_same(before[key], after[key]))
            ..._diff('$field.$key', before[key], after[key]),
      ].take(_maxStaleChanges).toList();
    }
    return [
      {'field': field, 'before': _bounded(before), 'after': _bounded(after)},
    ];
  }

  /// A value small enough to quote in a rejection: long text is cut, large
  /// lists and maps are summarized.
  static Object? _bounded(Object? value) {
    if (value is String) {
      return value.length <= 160 ? value : '${value.substring(0, 160)}…';
    }
    if (value is List) {
      if (jsonEncode(value).length <= 240) return value;
      return {
        'count': value.length,
        'first': [for (final item in value.take(3)) _bounded(item)],
      };
    }
    if (value is Map) {
      if (jsonEncode(value).length <= 240) return value;
      return {'keys': value.keys.take(8).toList(), 'count': value.length};
    }
    return value;
  }

  static ({String reason, List<AgentView> changes}) _stale(
    String reason,
    String field,
    Object? before,
    Object? after,
  ) => (reason: reason, changes: _diff(field, before, after));

  /// Changes that invalidate any decision on this screen.
  static ({String reason, List<AgentView> changes})? _sharedStateChange(
    AgentView decision,
    AgentView current,
  ) {
    // A dialog's name is guessed from its text, which may be the display a
    // key press just changed; the same mounted surface keeps its instance.
    final before = decision['activeSurface'];
    final after = current['activeSurface'];
    final sameSurface =
        before is Map &&
        after is Map &&
        before['instance'] is int &&
        before['instance'] == after['instance'] &&
        before['kind'] == after['kind'];
    if (!sameSurface && !_same(decision['screen'], current['screen'])) {
      return _stale(
        'screen changed',
        'screen',
        decision['screen'],
        current['screen'],
      );
    }
    for (final key in const [
      'runId',
      'runtimeInstanceId',
      'routeGuess',
      'surfaceOnly',
      'viewport',
      'keyboard',
      'activeBlockingSignals',
      'errorsSinceCursor',
      'errorCursor',
      'safetyEvidenceStatus',
      'fieldValues',
      'annotationMode',
    ]) {
      if (!_same(decision[key], current[key])) {
        return _stale('$key changed', key, decision[key], current[key]);
      }
    }
    Object? pick(Object? value, List<String> keys) => value is Map
        ? {
            for (final key in keys)
              if (value.containsKey(key)) key: value[key],
          }
        : value;
    const surfaceKeys = ['kind', 'label', 'screen', 'source'];
    if (!sameSurface &&
        !_same(
          pick(decision['activeSurface'], surfaceKeys),
          pick(current['activeSurface'], surfaceKeys),
        )) {
      return _stale(
        'the active surface changed',
        'activeSurface',
        pick(decision['activeSurface'], surfaceKeys),
        pick(current['activeSurface'], surfaceKeys),
      );
    }
    const renderingKeys = ['status', 'framesEnabled', 'lifecycle'];
    final renderingBefore = pick(decision['rendering'], renderingKeys);
    final renderingAfter = pick(current['rendering'], renderingKeys);
    if (!_same(renderingBefore, renderingAfter)) {
      return _stale(
        'rendering changed',
        'rendering',
        renderingBefore,
        renderingAfter,
      );
    }
    return null;
  }

  /// Whether every target appears once, identical, enabled and hit-testable.
  static ({String reason, List<AgentView> changes})? _targetChange(
    AgentView decision,
    AgentView current,
    Set<String> targets,
  ) {
    final before = decision['interactables'];
    final after = current['interactables'];
    if (before is! List || after is! List) {
      return (
        reason: 'controls are unavailable',
        changes: _diff(
          'interactables',
          before is List ? 'list' : before,
          after is List ? 'list' : after,
        ),
      );
    }
    List<Map> withId(List items, String id) => [
      for (final item in items)
        if (item is Map && item['id'] == id) item,
    ];
    // A scroll target is a list, not a control. Its position may change
    // (a scroll moves by a distance from wherever it is); not its identity.
    Object? region(AgentView view, String id) {
      final regions = view['scrollables'];
      if (regions is! List) return null;
      final matches = [
        for (final item in regions)
          if (item is Map && (item['id'] == id || item['scopedId'] == id))
            {
              for (final key in const [
                'id',
                'scopedId',
                'parentId',
                'axis',
                'axisDirection',
              ])
                key: item[key],
            },
      ];
      return matches.length == 1 ? matches.single : null;
    }

    for (final id in targets) {
      final a = withId(before, id);
      final b = withId(after, id);
      if (a.isEmpty && b.isEmpty) {
        final was = region(decision, id);
        if (was == null) {
          return (
            reason: 'target $id was not one observed control',
            changes: [
              {'field': 'interactables[$id]', 'before': 0, 'after': 0},
            ],
          );
        }
        final now = region(current, id);
        if (!_same(was, now)) {
          return _stale('target $id changed', 'scrollables[$id]', was, now);
        }
        continue;
      }
      if (a.length != 1) {
        return (
          reason: 'target $id was not one observed control',
          changes: [
            {
              'field': 'interactables[$id]',
              'before': a.length,
              'after': b.length,
            },
          ],
        );
      }
      if (b.length != 1) {
        return (
          reason: 'target $id is gone or no longer unique',
          changes: [
            {'field': 'interactables[$id]', 'before': 1, 'after': b.length},
          ],
        );
      }
      if (!_same(a.single, b.single)) {
        return _stale(
          'target $id changed',
          'interactables[$id]',
          a.single,
          b.single,
        );
      }
      final target = b.single;
      if (target['enabled'] == false ||
          target['hitTestable'] == false ||
          target['offscreen'] == true) {
        return (
          reason: 'target $id is not enabled, hit-testable and on screen',
          changes: [
            {
              'field': 'interactables[$id]',
              'after': {
                for (final key in const ['enabled', 'hitTestable', 'offscreen'])
                  if (target.containsKey(key)) key: target[key],
              },
            },
          ],
        );
      }
    }
    return null;
  }

  /// Changes outside the targets beyond in-place text updates.
  static ({String reason, List<AgentView> changes})? _layoutChange(
    AgentView decision,
    AgentView current,
    Set<String> targets,
  ) {
    for (final key in const [
      'recentErrors',
      'errorSummary',
      'perception',
      'payloadBounds',
      'omittedSections',
      'omitted',
      'interactablesOmitted',
      'scrollables',
      'degradedNodes',
      'inspectWarnings',
    ]) {
      if (!_same(decision[key], current[key])) {
        return _stale('$key changed', key, decision[key], current[key]);
      }
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
        final was = decision[key] is List ? decision[key] as List : const [];
        final now = current[key] is List ? current[key] as List : const [];
        String text(Object? item) => item is String ? item : jsonEncode(item);
        final wasText = was.map(text).toSet();
        final nowText = now.map(text).toSet();
        return (
          reason: 'text appeared or disappeared',
          changes: [
            {
              'field': key,
              'before': length(decision[key]),
              'after': length(current[key]),
              'appeared': [
                for (final item in nowText.difference(wasText).take(6))
                  _bounded(item),
              ],
              'disappeared': [
                for (final item in wasText.difference(nowText).take(6))
                  _bounded(item),
              ],
            },
          ],
        );
      }
    }
    final before = decision['interactables'] as List;
    final after = current['interactables'] as List;
    if (before.length != after.length) {
      Set<Object?> ids(List items) => {
        for (final item in items)
          if (item is Map) item['id'],
      };
      return (
        reason: 'controls appeared or disappeared',
        changes: [
          {
            'field': 'interactables',
            'before': before.length,
            'after': after.length,
            'appeared': ids(after).difference(ids(before)).take(8).toList(),
            'disappeared': ids(before).difference(ids(after)).take(8).toList(),
          },
        ],
      );
    }
    for (var i = 0; i < before.length; i++) {
      final a = before[i];
      final b = after[i];
      if (a is! Map || b is! Map) {
        return (
          reason: 'controls are unavailable',
          changes: [
            {'field': 'interactables[$i]', 'before': 'map', 'after': 'map'},
          ],
        );
      }
      if (targets.contains(a['id']) || targets.contains(b['id'])) {
        if (a['id'] != b['id']) {
          return _stale(
            'controls moved around a target',
            'interactables[$i].id',
            a['id'],
            b['id'],
          );
        }
        continue;
      }
      // Unkeyed ids derive from labels, so a countdown button may change id
      // and label in place. Its kind and interaction state must not change.
      for (final key in _controlStateKeys) {
        if (!_same(a[key], b[key])) {
          return _stale(
            'control ${b['id']} changed state',
            'interactables[${b['id']}].$key',
            a[key],
            b[key],
          );
        }
      }
    }
    return null;
  }

  /// A control's interaction state: a change to any of these outside the
  /// targets is a real layout change, not an in-place text update.
  static const _controlStateKeys = [
    'kind',
    'enabled',
    'hitTestable',
    'offscreen',
    'selected',
    'checked',
    'toggled',
    'expanded',
  ];

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
    this.foregroundAvailable = false,
    this.headlessDrive = false,
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

  /// Whether explicit native activation exists (a named macOS session), so
  /// rendering rejections can name `foreground()` as the literal next step.
  final bool foregroundAvailable;

  /// Whether this session opted into headless drive (`--headless-drive`):
  /// a hidden app whose helper reports rendering `driven` accepts input, and
  /// every scene says so. Off, suspended rendering is refused as before.
  final bool headlessDrive;
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
  // Short-lived text (a toast or snackbar) that appeared after the caller's
  // last observation and vanished before the next one, from background polls.
  static const maxTransientText = 12;
  Set<String> _callerTexts = {};
  Set<String> _polledTexts = {};
  final Map<String, int> _appearedAt = {};
  final List<({String text, int appearedAt, int goneAt})> _transient = [];
  int _transientOmitted = 0;
  AgentView? _receipt;
  bool _receiptDelivered = false;
  int _receiptReadCount = 0;
  int reads = 0;
  int actions = 0;

  /// First reason input is refused right now, or null when actionable.
  String? get _inputBlockedReason {
    if (_closed) return 'closed';
    if (_halt != null) return _halt;
    final blocked = _unsafeReason;
    if (blocked != null) return blocked;
    if (_helperCapabilityMissing) return 'helper_capability_missing';
    if (_acting != null) return 'action_in_flight';
    if (_unacknowledgedAction != null) return 'receipt_unacknowledged';
    return null;
  }

  AgentView get scene {
    final blocker = _blocker();
    return {
      'actionable': blocker == null,
      'inputBlockedReason': _inputBlockedReason,
      // Why input is refused right now, with the literal next step.
      'blockedBy': ?blocker,
      if (headlessDrive) 'headless': _headlessScene,
      ..._sceneBody,
    };
  }

  /// Plain statement of headless drive for every scene of an opted-in
  /// session: whether Scout is driving a hidden app right now, and why.
  AgentView get _headlessScene {
    final rendering = _view?['rendering'] as Map?;
    final drive = rendering?['headlessDrive'] as Map?;
    if (drive == null) {
      return {
        'driving': false,
        'notice': _view?['ok'] == true
            ? 'Headless drive is on for this session, but the app helper '
                  'did not report it (update flutter_scout_helper and fully '
                  'relaunch); a hidden app is refused as usual.'
            : 'Headless drive is on for this session; no current '
                  'observation exists.',
      };
    }
    return {
      'driving': rendering?['status'] == 'driven',
      'reason': drive['reason'],
      'lifecycle': rendering?['lifecycle'],
      'notice': drive['notice'],
    };
  }

  AgentView get _sceneBody => {
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
    _takeTransientText();
    _schedule();
    return _response(_view?['ok'] == true && _halt == null, {
      'agentProtocol': 2,
    });
  }

  /// An unsuccessful response names its cause instead of a generic failure.
  AgentView _response(bool ok, [AgentView extra = const {}]) {
    final current = scene;
    return {
      'ok': ok,
      ...extra,
      if (!ok && current['blockedBy'] != null) 'error': current['blockedBy'],
      ...current,
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
          (rendering?['headlessDrive'] as Map?)?['reason'],
          value['activeBlockingSignals'],
          value['errorsSinceCursor'],
          value['recentErrors'],
          value['perception'],
          value['payloadBounds'],
          value['error'],
          // A native dialog appearing, changing or going away is a new view;
          // probe timings are not.
          (value['systemDialog'] as Map?)?['fingerprint'] ??
              (value['systemDialog'] as Map?)?['status'],
        ]);
        final changed = key != _viewKey;
        _view = value;
        if (value['ok'] == true) _trackTransientText(value);
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
      done.complete(_response(value['ok'] == true && _halt == null));
    }();
    return done.future;
  }

  /// The caller's own observation: the current scene plus `transientText`,
  /// the texts that appeared and vanished since the caller last observed
  /// (background polls run every [interval], so text shown for less than
  /// one interval can still be missed).
  Future<AgentView> observeForCaller() async {
    final result = await observe();
    final transient = _takeTransientText();
    return {...result, ...transient};
  }

  void _trackTransientText(AgentView value) {
    final now = _clock.elapsedMilliseconds;
    final texts = <String>{
      for (final text in value['visibleText'] as List? ?? const [])
        if (text is String) text,
    };
    // A truncated list cannot prove that a text vanished.
    final complete = _complete(value, 'visibleText');
    final carried = <String>{};
    for (final text in _polledTexts) {
      if (texts.contains(text)) continue;
      if (!complete) {
        carried.add(text);
        continue;
      }
      _callerTexts.remove(text);
      final appeared = _appearedAt.remove(text);
      if (appeared == null) continue;
      _transient.removeWhere((entry) => entry.text == text);
      _transient.add((text: text, appearedAt: appeared, goneAt: now));
      if (_transient.length > maxTransientText) {
        _transient.removeAt(0);
        _transientOmitted++;
      }
    }
    for (final text in texts) {
      if (!_polledTexts.contains(text) && !_callerTexts.contains(text)) {
        _appearedAt.putIfAbsent(text, () => now);
      }
    }
    _polledTexts = {...texts, ...carried};
  }

  AgentView _takeTransientText() {
    final now = _clock.elapsedMilliseconds;
    final result = <String, dynamic>{
      if (_transient.isNotEmpty)
        'transientText': [
          for (final entry in _transient)
            {
              'text': entry.text,
              'shownMs': entry.goneAt - entry.appearedAt,
              'goneAgoMs': now - entry.goneAt,
            },
        ],
      if (_transientOmitted > 0) 'transientTextOmitted': _transientOmitted,
    };
    _transient.clear();
    _transientOmitted = 0;
    _appearedAt.clear();
    _callerTexts = Set.of(_polledTexts);
    return result;
  }

  bool get _live =>
      _view?['ok'] == true &&
      (_view?['rendering'] as Map?)?['status'] == 'active' &&
      (_view?['rendering'] as Map?)?['framesEnabled'] == true;

  /// A hidden app the helper is driving for this opted-in session.
  bool get _driven =>
      headlessDrive &&
      _view?['ok'] == true &&
      (_view?['rendering'] as Map?)?['status'] == 'driven';
  String? get _unsafeReason {
    if (_view?['ok'] != true) return 'observation_unavailable';
    if (_systemDialog != null) return 'system_dialog';
    if (!_live && !_driven) return 'rendering_suspended';
    if ((_view?['activeBlockingSignals'] as List? ?? []).isNotEmpty) {
      return 'blocking_signal_active';
    }
    if ((_view?['errorsSinceCursor'] as List? ?? []).isNotEmpty) {
      return 'runtime_errors_since_cursor';
    }
    if (_view?['safetyEvidenceStatus'] != 'complete') {
      return 'safety_evidence_incomplete';
    }
    return null;
  }

  /// The native system dialog covering the app in the current view, if any.
  /// Flutter input is refused while it is shown: a person could not reach
  /// the app either.
  AgentView? get _systemDialog => _presentDialog(_view);

  static AgentView? _presentDialog(AgentView? view) {
    final dialog = view?['systemDialog'];
    return dialog is Map && dialog['present'] == true
        ? Map<String, dynamic>.from(dialog)
        : null;
  }

  /// Observation stays usable on an older helper; only input is refused.
  bool get _helperCapabilityMissing =>
      _view?['missingHelperCapabilities'] != null;

  bool get _safe => _unsafeReason == null;

  /// Returns the view the decision was made from. A stale revision is
  /// accepted only for an action scoped to exact observed handles when
  /// [staleReason] finds nothing that may affect it; a rejection names why.
  AgentView _authorize(
    int revision, [
    Set<String>? targets,
    bool allowUnrelatedChanges = false,
  ]) {
    if (_closed || _halt != null) throw StateError(_stoppedMessage());
    final decision = revision == _revision ? _view : _history[revision];
    if (revision != _revision) {
      final stale = targets == null || decision == null || _view == null
          ? null
          : staleChange(
              decision,
              _view!,
              targets,
              allowUnrelatedChanges: allowUnrelatedChanges,
            );
      final reason = targets == null
          ? 'only an exact-handle tap, long-press, input or fill can use an '
                'older revision'
          : decision == null || _view == null
          ? 'viewRevision $revision is no longer retained'
          : stale?.reason;
      if (reason != null) {
        throw AgentRejection(
          'agent_view_changed',
          'viewRevision $revision is stale (now $_revision) and the change '
              'may affect this action: $reason; nothing dispatched. Decide '
              'again from the returned scene.',
          nextStep: 'observe(), then act on scene.viewRevision',
          details: {
            'observedRevision': revision,
            'currentRevision': _revision,
            'staleReason': reason,
            if (stale != null && stale.changes.isNotEmpty)
              'staleChanges': stale.changes,
          },
        );
      }
    }
    final unavailable = _liveViewBlocker();
    if (unavailable != null) {
      throw AgentRejection(
        unavailable['code'] as String,
        unavailable['text'] as String,
        nextStep: unavailable['nextStep'] as String,
        details: unavailable['details'] as AgentView,
      );
    }
    if (_helperCapabilityMissing) {
      throw StateError(
        'agent_helper_capability_missing: update flutter_scout_helper and fully relaunch for agent input; nothing dispatched',
      );
    }
    return decision!;
  }

  /// Why the hand refuses input now, or null when it is actionable.
  AgentView? _blocker() {
    if (_closed || _halt != null) {
      return _handUnavailable(_stoppedMessage());
    }
    if (_acting != null) {
      final id = _pendingAction;
      return _handUnavailable(
        id == null
            ? 'agent_hand_busy: foreground activation is in progress; wait '
                  'for its result'
            : 'agent_hand_busy: action $id is in flight; consume its receipt '
                  'with next() first',
      );
    }
    final id = _unacknowledgedAction;
    if (id != null) {
      return _handUnavailable(
        _receiptDelivered
            ? "agent_receipt_required: call acknowledge('$id') before another input"
            : "agent_receipt_required: consume action $id's receipt with next(), then acknowledge('$id')",
      );
    }
    final unavailable = _liveViewBlocker();
    if (unavailable == null) {
      if (!_helperCapabilityMissing) return null;
      return {
        'code': 'agent_helper_capability_missing',
        'reason': 'helper_capability_missing',
        'message':
            'agent_helper_capability_missing: the app helper lacks '
            '${_view?['missingHelperCapabilities']}',
        'nextStep': 'update flutter_scout_helper and fully relaunch the app',
      };
    }
    return {
      'code': unavailable['code'],
      'reason': unavailable['reason'],
      'message': '${unavailable['code']}: ${unavailable['text']}',
      'nextStep': unavailable['nextStep'],
      'details': unavailable['details'],
    };
  }

  /// A closed, stopped, busy or receipt-bound hand. Each [message] starts
  /// with its specific reason, which the stable code keeps as `reason`.
  AgentView _handUnavailable(String message) => {
    'code': 'agent_hand_unavailable',
    'reason': message.substring(0, message.indexOf(':')),
    'message': message,
    if (_halt != null) 'details': {'halted': _halt},
  };

  /// The literal next step when rendering, not safety, blocks input.
  /// A window that is only partly visible keeps rendering without focus, so
  /// a person using the machine can leave it where they can see it rather
  /// than lose focus to foreground().
  String get _restoreRendering => foregroundAvailable
      ? 'leave part of the app window visible (not minimized, fully covered '
            'or on another Space; it renders without focus), then observe() '
            'again; only when nobody is using this Mac, call await '
            'scout.foreground() once (it takes focus from the user)'
      : 'make the app visible on its device or simulator (not covered, '
            'minimized or locked), then observe() again';

  /// The first unproven live-input precondition as code, reason, text,
  /// literal next step and structured facts; null when the view is live and
  /// safe. Facts are copied from the observation, never inferred.
  AgentView? _liveViewBlocker() {
    if (_safe) return null;
    final view = _view;
    final rendering = view?['rendering'] as Map?;
    final signals = view?['activeBlockingSignals'] as List? ?? const [];
    final errors = view?['errorsSinceCursor'] as List? ?? const [];
    final facts = <String, dynamic>{
      'rendering': {
        for (final key in const [
          'status',
          'framesEnabled',
          'lifecycle',
          'lastFrameworkFrameAgeMs',
        ])
          key: rendering?[key],
      },
      'foregroundAvailable': foregroundAvailable,
      if (foregroundAvailable) 'platform': 'macos',
      if (headlessDrive) 'headlessDrive': true,
      'safetyEvidenceStatus': view?['safetyEvidenceStatus'],
      'activeBlockingSignalCount': signals.length,
      'errorsSinceCursorCount': errors.length,
    };
    AgentView blocked(String reason, String text, String nextStep) => {
      'code': 'agent_live_view_unavailable',
      'reason': reason,
      'text': '$text Nothing dispatched.',
      'nextStep': nextStep,
      'details': {'reason': reason, ...facts},
    };
    if (view?['ok'] != true) {
      return blocked(
        'observation_unavailable',
        'No current protocol-valid observation of the app exists.',
        'check the app with status, then close() and reconnect',
      );
    }
    final dialog = _systemDialog;
    if (dialog != null) {
      final buttons = [
        for (final button in dialog['buttons'] as List? ?? const [])
          if (button is Map) button['handle'],
      ];
      final owner = dialog['owner'] as Map?;
      return {
        ...blocked(
          'system_dialog',
          'A native ${dialog['platform']} system dialog covers the app: '
              '"${dialog['title']}" (buttons ${buttons.join(', ')}; owner '
              '${owner?['name'] ?? 'unknown'}). Flutter input is blocked '
              'until it is answered.',
          dialog['answerable'] == false
              ? 'ask the user to answer it; Scout never answers credential '
                    'or Apple Account prompts'
              : "answer it only when the task authorizes that answer: "
                    "act {method:'system-tap', args:['<handle>']} with one "
                    'of scene.view.systemDialog.buttons; or pre-grant with '
                    '`flutter-scout --app <name> permissions grant '
                    '<service>`, or ask the user. Scout never answers it by '
                    'itself',
        ),
        'details': {
          'reason': 'system_dialog',
          'systemDialog': {
            for (final key in const [
              'platform',
              'kind',
              'title',
              'owner',
              'answerable',
            ])
              key: dialog[key],
            'buttons': buttons,
          },
        },
      };
    }
    if (!_live && !_driven) {
      return blocked(
        'rendering_suspended',
        'Rendering is not active (status ${rendering?['status']}, '
            'framesEnabled ${rendering?['framesEnabled']}, lifecycle '
            '${rendering?['lifecycle']}, last framework frame '
            '${rendering?['lastFrameworkFrameAgeMs']} ms ago), so the app '
            'window is probably minimized, hidden or fully covered.',
        _restoreRendering,
      );
    }
    if (signals.isNotEmpty) {
      final codes = [
        for (final signal in signals.take(5))
          signal is Map ? signal['code'] ?? signal['kind'] : signal,
      ];
      return blocked(
        'blocking_signals',
        'Rendering is active, but the app reports active blocking signals '
            '$codes.',
        'inspect scene.view.activeBlockingSignals and resolve them in the '
            'app (Scout never overrides safety), then observe() again',
      );
    }
    if (errors.isNotEmpty) {
      return blocked(
        'app_errors',
        'Rendering is active, but ${errors.length} app error(s) were observed '
            'since the error cursor.',
        'inspect scene.view.errorsSinceCursor, fix or reload the app, then '
            'observe() again',
      );
    }
    return blocked(
      'safety_evidence_incomplete',
      'Rendering is active, but safety evidence is '
          '${view?['safetyEvidenceStatus']}, not complete.',
      'observe() again or narrow the screen; Scout never acts on incomplete '
          'safety evidence',
    );
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
  /// or acknowledging an outstanding input receipt. After activation it
  /// waits, bounded by [wait], for a fresh passive observation that reports
  /// active rendering; Scout never pumps frames or retries activation. On
  /// failure, [diagnose] may add cheap native facts (such as the frontmost
  /// app) so the error names the cause.
  Future<AgentView> foreground(
    Future<void> Function() activate, {
    Future<AgentView> Function()? diagnose,
    Duration wait = const Duration(seconds: 5),
  }) async {
    final knownFailure = _halt == 'agent_action_failed' && _knownFailure;
    if (_closed ||
        (_halt != null && !knownFailure) ||
        _acting != null ||
        (_unacknowledgedAction != null && !knownFailure) ||
        _view?['ok'] != true) {
      final blocker = _blocker();
      throw AgentRejection(
        'agent_foreground_unavailable',
        'foreground needs a free hand and a valid observation; '
            '${blocker?['message'] ?? 'no valid observation exists'}. No '
            'activation was requested.',
        nextStep: 'follow the blocking reason first',
      );
    }
    bool stopped() =>
        _closed ||
        (_halt != null && (!knownFailure || _halt != 'agent_action_failed'));
    final done = Completer<void>();
    _acting = done.future;
    final started = _clock.elapsedMilliseconds;
    AgentView facts = const {};
    try {
      await activate();
      // A read already in flight may predate activation: only a read that
      // starts afterwards can prove the activated state.
      await _reading;
      while (!stopped()) {
        await observe();
        if (_live ||
            stopped() ||
            _clock.elapsedMilliseconds - started >= wait.inMilliseconds) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (!_live && !stopped() && diagnose != null) {
        try {
          facts = await diagnose();
        } catch (_) {
          facts = const {'frontmostApp': null};
        }
      }
    } finally {
      _acting = null;
      done.complete();
    }
    // Activation succeeded only if the app renders on its own again; a
    // headless-driven scene is still a hidden window.
    final ok = _live && _safe && !stopped();
    return {
      'ok': ok,
      'foregroundRequested': true,
      'inputDispatched': false,
      if (!ok)
        'error': _foregroundError(
          facts,
          _clock.elapsedMilliseconds - started,
          stopped(),
        ),
      ...scene,
    };
  }

  /// A failed activation names its cause and the next step, never a
  /// generic failure, and never suggests a retry loop.
  AgentView _foregroundError(AgentView facts, int waitedMs, bool stopped) {
    if (stopped) {
      final error = _handUnavailable(_stoppedMessage());
      return {
        ...error,
        'details': {'halted': _halt, 'activationRequested': true},
      };
    }
    // Null while a headless-driven scene is safe but still not visible.
    final unavailable = _liveViewBlocker();
    final details = <String, dynamic>{
      ...?unavailable?['details'] as AgentView?,
      'activationRequested': true,
      'waitedMs': waitedMs,
      ...facts,
    };
    if (_live && unavailable != null) {
      // Rendering resumed; safety, not visibility, still blocks input.
      return {
        'code': unavailable['code'],
        'reason': unavailable['reason'],
        'message': '${unavailable['code']}: ${unavailable['text']}',
        'nextStep': unavailable['nextStep'],
        'details': details,
      };
    }
    final rendering = _view?['rendering'] as Map?;
    final frontmost = facts['frontmostApp'];
    // macOS reports loginwindow while the screen is locked or asleep; no app
    // can render then, and no activation will change that.
    final locked = frontmost == 'loginwindow';
    final cause = locked
        ? 'The Mac\'s screen is locked or at the login window ("loginwindow" '
              'is frontmost), so no app window can render.'
        : facts['frontmostIsTarget'] == false
        ? 'macOS kept "$frontmost" frontmost, so this app was not brought '
              'forward (macOS can decline activation requested by a '
              'background process, or another app took focus).'
        : facts['frontmostIsTarget'] == true
        ? 'The app is frontmost, so its window is probably minimized, on '
              'another Space or display, or covered by another window.'
        : 'The frontmost app could not be determined.';
    details['reason'] = 'rendering_still_suspended';
    return {
      'code': 'agent_live_view_unavailable',
      'reason': 'rendering_still_suspended',
      'message':
          'agent_live_view_unavailable: activation was requested, but after '
          '$waitedMs ms rendering is still ${rendering?['status']} (lifecycle '
          '${rendering?['lifecycle']}, framesEnabled '
          '${rendering?['framesEnabled']}). $cause Nothing dispatched.',
      'nextStep': locked
          ? 'ask the user to unlock the Mac and leave part of the app window '
                'visible, then observe() again; do not loop foreground()'
          : 'restore and uncover the app window by hand (Dock or Mission '
                'Control), then observe() again; do not loop foreground()',
      'details': details,
    };
  }

  AgentView start(int revision, AgentView action, {String? reactionId}) {
    final decision = action['method'] == 'system-tap'
        ? _authorizeSystemTap(revision, action, reactionId: reactionId)
        : _authorize(
            revision,
            scopedTargets(action),
            action['allowUnrelatedChanges'] == true,
          );
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

  /// A `system-tap` answers one native dialog: it needs a free hand, the
  /// exact dialog observed at [revision] still shown, and a button of that
  /// dialog that [systemTapAuthorization] allows. Flutter's own rendering
  /// and safety state do not block it (the dialog is what covers the app).
  /// The CLI probes the dialog again at dispatch.
  AgentView _authorizeSystemTap(
    int revision,
    AgentView action, {
    String? reactionId,
  }) {
    if (_closed || _halt != null) throw StateError(_stoppedMessage());
    if (reactionId != null) {
      throw AgentRejection(
        'agent_system_tap_not_reactive',
        'system-tap is never a reaction; an agent answers a dialog only by '
            'its own decision. Nothing dispatched.',
      );
    }
    final decision = revision == _revision ? _view : _history[revision];
    final decided = _presentDialog(decision);
    final args = action['args'];
    final handle = args is List && args.length == 1 ? args.single : null;
    final current = _systemDialog;
    final refusal = systemTapAuthorization(
      decided,
      current,
      handle is String ? handle : '',
      dialogOwner: (action['params'] as Map?)?['dialogOwner'] as String?,
    );
    if (refusal != null) {
      throw AgentRejection(
        refusal.code,
        '${refusal.message} Nothing dispatched.',
        nextStep: refusal.code == 'agent_system_dialog_changed'
            ? 'observe(), then decide again from scene.view.systemDialog'
            : 'read scene.view.systemDialog; answer only a button it lists, '
                  'or ask the user',
        details: {
          'observedRevision': revision,
          'currentRevision': _revision,
          'systemDialog': ?current,
        },
      );
    }
    return decision!;
  }

  /// Why a `system-tap` of [handle] decided on [decided] (the dialog in the
  /// decision view) must not start while [current] is shown, or null. The
  /// same rules as the CLI's dispatch-time check, on the observed facts.
  static ({String code, String message})? systemTapAuthorization(
    AgentView? decided,
    AgentView? current,
    String handle, {
    String? dialogOwner,
  }) {
    if (decided == null) {
      return (
        code: 'agent_system_dialog_not_observed',
        message:
            'no system dialog was observed at that viewRevision; system-tap '
            'answers only a dialog in scene.view.systemDialog.',
      );
    }
    if (current == null || current['fingerprint'] != decided['fingerprint']) {
      return (
        code: 'agent_system_dialog_changed',
        message: current == null
            ? 'the observed system dialog is no longer shown.'
            : 'a different system dialog is shown now ("${current['title']}").',
      );
    }
    if (decided['answerable'] != true) {
      return (
        code: 'agent_system_dialog_refused',
        message:
            'Scout never answers credential, password or Apple Account '
            'prompts ("${decided['title']}"); ask the user.',
      );
    }
    Map? button;
    var count = 0;
    for (final candidate in decided['buttons'] as List? ?? const []) {
      if (candidate is Map && candidate['handle'] == handle) {
        button = candidate;
        count++;
      }
    }
    if (button == null) {
      return (
        code: 'agent_system_dialog_button_not_observed',
        message:
            '$handle is not a button of the observed dialog; its buttons '
            'are ${[for (final b in decided['buttons'] as List? ?? const [])
              if (b is Map) b['handle']].join(', ')}.',
      );
    }
    if (count > 1 || button['ambiguous'] == true) {
      return (
        code: 'agent_system_dialog_button_ambiguous',
        message:
            'more than one button of the dialog is named $handle; Scout does '
            'not guess which one is meant.',
      );
    }
    final owner = decided['owner'] as Map?;
    if (owner?['belongsToSessionApp'] != true) {
      final name = owner?['name'] as String? ?? 'unknown';
      if (dialogOwner != name) {
        return (
          code: 'agent_system_dialog_other_app',
          message: owner?['belongsToSessionApp'] == false
              ? 'the dialog belongs to "$name", not to this session\'s app; '
                    'answer it only when the task covers that app, with '
                    'params.dialogOwner: "$name".'
              : 'Scout could not prove which app the dialog belongs to; '
                    'answer it only when the task covers it, with '
                    'params.dialogOwner: "unknown".',
        );
      }
    }
    return null;
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
        : !_safe && _unsafeReason != 'system_dialog'
        ? 'the live view is unavailable '
              '(${_liveViewBlocker()!['reason']}); '
              '${_liveViewBlocker()!['nextStep']}, then $retry'
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
    // A reaction acts on the agent's behalf, so it stays short. A plain
    // condition only observes; long business waits (a first data sync) would
    // otherwise need a polling loop of observations.
    final maximum = reaction == null ? 600000 : 30000;
    if (timeoutMs < 1 || timeoutMs > maximum) {
      throw ArgumentError('timeoutMs must be 1..$maximum');
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

  /// Whether [value] is the exact label or handle of a listed interactable
  /// (a progress capsule may show only "45%" while its control is labelled
  /// "Data sync").
  static bool _controlPresent(AgentView? view, String value) =>
      (view?['interactables'] as List? ?? const []).whereType<Map>().any(
        (node) => node['label'] == value || node['id'] == value,
      );

  /// Whether [value] is on screen as an exact visible text or as the exact
  /// label or handle of an interactable.
  static bool _present(AgentView? view, String value) =>
      (view?['visibleText'] as List? ?? const []).contains(value) ||
      _controlPresent(view, value);

  /// Whether [view] lists all of [section]; brief omission is not proof of
  /// absence. Anonymous generic controls (`interactablesOmitted`) have no
  /// label to match, so only the maxItems cut counts for interactables.
  static bool _complete(AgentView? view, String section) {
    final omitted = view?['omitted'];
    if (omitted is Map) {
      final count = omitted[section];
      if (count != null && count != 0) return false;
    } else if (omitted != null && omitted != 0 && omitted != false) {
      return false;
    }
    final sections = (view?['omittedSections'] as Map?)?['sections'];
    return sections == null ||
        (sections is List && !sections.contains(section));
  }

  /// Sections whose omission keeps a `gone` job from proving absence now.
  static List<String> _absenceUnproven(AgentView? view, _ConditionJob job) => [
    if (!_complete(view, 'visibleText')) 'visibleText',
    if (job.seenAsControl && !_complete(view, 'interactables')) 'interactables',
  ];

  bool _matches(_ConditionJob job) {
    final c = job.condition;
    if (c.containsKey('text')) return _present(_view, c['text'] as String);
    if (c.containsKey('gone')) {
      final value = c['gone'] as String;
      if (_controlPresent(_view, value)) {
        // Once seen as a control, absence also needs the full control list.
        job.seenAsControl = true;
        return false;
      }
      return !(_view?['visibleText'] as List? ?? const []).contains(value) &&
          _absenceUnproven(_view, job).isEmpty;
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
        // A native dialog over the app ends a wait with its own cause: the
        // agent decides how to answer it; nothing waits through it.
        _finishJob(
          job,
          _unsafeReason == 'system_dialog'
              ? 'system_dialog'
              : 'observation_unavailable',
        );
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
    final unproven = status == 'timeout' && job.condition.containsKey('gone')
        ? _absenceUnproven(_view, job)
        : const <String>[];
    _emit(job.reaction == null ? 'condition' : 'reaction', {
      'conditionId': job.id,
      'status': status,
      // Why a `gone` wait could not prove absence (truncated brief lists).
      if (unproven.isNotEmpty) 'absenceUnproven': unproven,
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
  bool seenAsControl = false;
}
