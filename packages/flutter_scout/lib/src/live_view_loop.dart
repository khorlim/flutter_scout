import 'dart:async';
import 'dart:convert';

typedef LiveRead = Future<Map<String, dynamic>> Function();
typedef LiveAct =
    Future<Map<String, dynamic>> Function(
      Map<String, dynamic> request,
      Map<String, dynamic> observedView,
    );

/// A latest-view buffer shared by a continuous observer and one agent.
/// Background reads never imply that the agent has consumed a new view.
class LiveViewLoop {
  LiveViewLoop({required this.read, required this.act, this.settle});

  final LiveRead read;
  final LiveAct act;
  final LiveRead? settle;
  final Stopwatch _clock = Stopwatch()..start();
  Future<void> _tail = Future<void>.value();
  Map<String, dynamic>? _latest;
  String? _identity;
  int _revision = 0;
  int _observedAtMs = 0;
  bool _busy = false;
  int observations = 0;
  int changedViews = 0;

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
  };

  Future<T> _serialized<T>(Future<T> Function() work) {
    final operation = _tail.then((_) async {
      _busy = true;
      try {
        return await work();
      } finally {
        _busy = false;
      }
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<void> refreshInBackground() async {
    if (_busy) return;
    await _serialized(_refresh);
  }

  Future<void> _refresh() async {
    Map<String, dynamic> value;
    try {
      value = await read();
    } catch (_) {
      value = {
        'ok': false,
        'error': {'code': 'live_observation_unavailable'},
      };
    }
    observations++;
    // Keep diagnostic changes (including runtime loss) even if UI is unchanged.
    final identity = jsonEncode([
      value['ok'],
      value['runId'],
      value['runtimeInstanceId'],
      value['snapshotId'],
      value['recentErrors'],
      value['recentLogSignals'],
      value['activeBlockingSignals'],
      value['error'],
    ]);
    if (_identity != identity) {
      _revision++;
      changedViews++;
      _identity = identity;
    }
    _latest = value;
    _observedAtMs = _clock.elapsedMilliseconds;
  }

  Map<String, dynamic> _response() => {
    'viewId': _revision,
    'viewAgeMs': _clock.elapsedMilliseconds - _observedAtMs,
    'view': _latest,
    'images': 'manual',
    'observer': {'samples': observations, 'changedViews': changedViews},
  };

  Future<Map<String, dynamic>> observe() => _serialized(() async {
    await _refresh();
    return {'ok': _latest?['ok'] == true, ..._response()};
  });

  Future<Map<String, dynamic>> perform(
    Map<String, dynamic> request,
  ) => _serialized(() async {
    final started = _clock.elapsedMilliseconds;
    final method = request['method'];
    if (!actionMethods.contains(method) ||
        request['viewId'] is! int ||
        request.keys.any(
          (key) => !{'method', 'viewId', 'args', 'params'}.contains(key),
        )) {
      return {
        'ok': false,
        'dispatch': 'not_dispatched',
        'error': {
          'code': 'invalid_live_action',
          'message':
              'Supply the returned integer viewId and a supported UI method.',
        },
        ..._response(),
      };
    }
    if (_latest?['ok'] != true || _latest?['snapshotId'] is! String) {
      await _refresh();
      return {
        'ok': false,
        'dispatch': 'not_dispatched',
        'error': {'code': 'live_view_unavailable'},
        ..._response(),
      };
    }
    if (request['viewId'] != _revision) {
      return {
        'ok': false,
        'dispatch': 'not_dispatched',
        'error': {
          'code': 'live_view_changed',
          'message':
              'The screen changed since your observation. Read the returned view and choose again.',
        },
        ..._response(),
      };
    }
    final observed = Map<String, dynamic>.from(_latest!);
    Map<String, dynamic> result;
    try {
      result = await act({...request}..remove('viewId'), observed);
    } catch (_) {
      // Never retry or claim non-dispatch after a transport exception.
      result = {
        'ok': false,
        'dispatch': 'dispatch_outcome_unknown',
        'error': {'code': 'live_action_outcome_unknown'},
      };
    }
    Map<String, dynamic>? settling;
    if (result['ok'] == true &&
        (result['stability'] as Map?)?['state'] == 'transient' &&
        settle != null) {
      // An expectation may be satisfied before the transition is finished.
      // Observe readiness before handing the next decision to the agent; never
      // retry the mutation or silently authorize a replacement decision.
      try {
        settling = await settle!();
      } catch (_) {
        settling = {
          'ok': false,
          'error': {'code': 'live_observation_unavailable'},
        };
      }
    }
    await _refresh();
    return {
      'ok':
          result['ok'] == true &&
          _latest?['ok'] == true &&
          (settling == null ||
              (settling['ok'] == true &&
                  (settling['stability'] as Map?)?['actionable'] == true)),
      'action': result,
      'settling': ?settling,
      ..._response(),
      'actionAndViewMs': _clock.elapsedMilliseconds - started,
    };
  });

  Future<Map<String, dynamic>> waitForChange(
    int viewId,
    Duration timeout,
  ) async {
    final started = _clock.elapsedMilliseconds;
    do {
      final result = await observe();
      if (result['viewId'] != viewId || result['ok'] != true) {
        return {...result, 'changed': result['viewId'] != viewId};
      }
      final remaining =
          timeout.inMilliseconds - (_clock.elapsedMilliseconds - started);
      if (remaining <= 0) break;
      await Future<void>.delayed(
        Duration(milliseconds: remaining < 200 ? remaining : 200),
      );
    } while (_clock.elapsedMilliseconds - started < timeout.inMilliseconds);
    return {'ok': _latest?['ok'] == true, 'changed': false, ..._response()};
  }

  Future<void> drain() => _tail;
}
