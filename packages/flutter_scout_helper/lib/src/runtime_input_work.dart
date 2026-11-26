part of 'flutter_scout_binding.dart';

// part: the app work one input started, for ending the late-change window
// early when nothing is pending.
//
// Scout's pointer events run inside a zone forked from the request zone. The
// zone only counts and delegates: every timer, microtask and callback keeps
// its normal parent behaviour, error zone and zone values. What it counts is
// exactly the work the input's handlers started in that zone (and the work
// that work started, since callbacks run in the zone they were created in).
//
// The input is idle when every timer it started has fired or been cancelled,
// every microtask has run, every continuation Flutter registered has run,
// and it registered no async continuation (an `await`, `then` or stream
// listener) from app code. Work it cannot follow is reported instead of
// guessed: a periodic timer, an app continuation, or an app microtask (for
// example a stream event queued for a listener the app created earlier,
// which then runs in the app's own zone) makes the input `busy` for the
// whole window. Flutter's own microtasks and continuations (tap feedback,
// focus updates, a button's press animation, platform-channel replies) are
// followed to completion through the counters instead. A continuation counts
// until it first runs; error callbacks are not counted because they only run
// on failure. Work the input hands to code outside this zone without a
// visible change (a completer the app created earlier) cannot be seen.

/// Why an input's work could not be followed to completion.
enum _InputWorkBusy {
  appAsyncCallback('app_async_callback'),
  appMicrotask('app_microtask'),
  periodicTimer('periodic_timer');

  const _InputWorkBusy(this.wire);
  final String wire;
}

class _InputWorkTracker {
  _InputWorkTracker(Zone parent) {
    zone = parent.fork(
      specification: ZoneSpecification(
        scheduleMicrotask: _scheduleMicrotask,
        createTimer: _createTimer,
        createPeriodicTimer: _createPeriodicTimer,
        registerUnaryCallback: _registerUnaryCallback,
        registerBinaryCallback: _registerBinaryCallback,
      ),
    );
  }

  late final Zone zone;

  /// Counting stops when the request that owns the input ends; later work in
  /// the zone is only delegated.
  bool active = true;

  /// At least one pointer event ran in [zone]. Other input paths (text,
  /// back, dismiss) are not tracked and never end the window early.
  bool covered = false;
  int pendingTimers = 0;
  int pendingMicrotasks = 0;
  int pendingCallbacks = 0;
  _InputWorkBusy? busy;

  /// The library that scheduled the work Scout cannot follow, for the
  /// receipt (a `package:` or `file:` URI without line numbers).
  String? busySource;

  bool get idle =>
      covered &&
      busy == null &&
      pendingTimers == 0 &&
      pendingMicrotasks == 0 &&
      pendingCallbacks == 0;

  T run<T>(T Function() body) {
    covered = true;
    return zone.run(body);
  }

  /// Who scheduled this work; app work marks the input busy. Once the input
  /// is busy the answer no longer matters and the stack is not read.
  _InputWorkCaller _classify(_InputWorkBusy reason) {
    if (busy != null) return _InputWorkCaller.app;
    final (caller, source) = _inputWorkCaller(StackTrace.current);
    if (caller == _InputWorkCaller.app) {
      busy = reason;
      busySource = source;
    }
    return caller;
  }

  void _scheduleMicrotask(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    void Function() f,
  ) {
    if (!active) return parent.scheduleMicrotask(zone, f);
    _classify(_InputWorkBusy.appMicrotask);
    pendingMicrotasks += 1;
    parent.scheduleMicrotask(zone, () {
      try {
        f();
      } finally {
        pendingMicrotasks -= 1;
      }
    });
  }

  Timer _createTimer(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    Duration duration,
    void Function() f,
  ) {
    if (!active) return parent.createTimer(zone, duration, f);
    late final _TrackedTimer tracked;
    pendingTimers += 1;
    final inner = parent.createTimer(zone, duration, () {
      try {
        f();
      } finally {
        tracked.finish();
      }
    });
    return tracked = _TrackedTimer(inner, this);
  }

  Timer _createPeriodicTimer(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    Duration period,
    void Function(Timer timer) f,
  ) {
    // Timer.periodic registers its callback first; name the timer itself.
    if (active) {
      busy = _InputWorkBusy.periodicTimer;
      busySource = _inputWorkCaller(StackTrace.current).$2 ?? 'package:flutter';
    }
    return parent.createPeriodicTimer(zone, period, f);
  }

  ZoneUnaryCallback<R, T> _registerUnaryCallback<R, T>(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    R Function(T arg) f,
  ) {
    final registered = parent.registerUnaryCallback(zone, f);
    if (!active ||
        _classify(_InputWorkBusy.appAsyncCallback) !=
            _InputWorkCaller.framework) {
      return registered;
    }
    // A framework continuation: pending until it first runs. An async
    // function registers once and reuses it for every later await. A
    // platform-channel reply is not waited for: an embedder may never send
    // one for a fire-and-forget message (a semantics tap event).
    pendingCallbacks += 1;
    var ran = false;
    return (T arg) {
      if (!ran) {
        ran = true;
        pendingCallbacks -= 1;
      }
      return registered(arg);
    };
  }

  ZoneBinaryCallback<R, T1, T2> _registerBinaryCallback<R, T1, T2>(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    R Function(T1 arg1, T2 arg2) f,
  ) {
    // Error callbacks run only on failure; an app one still means the app
    // is waiting on work Scout cannot follow.
    if (active) _classify(_InputWorkBusy.appAsyncCallback);
    return parent.registerBinaryCallback(zone, f);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'tracked': covered,
    if (busy != null) 'busy': busy!.wire,
    'busySource': ?busySource,
    if (pendingTimers > 0) 'pendingTimers': pendingTimers,
    if (pendingMicrotasks > 0) 'pendingMicrotasks': pendingMicrotasks,
    if (pendingCallbacks > 0) 'pendingCallbacks': pendingCallbacks,
  };
}

/// A timer that releases its pending count once, when it fires or is
/// cancelled.
class _TrackedTimer implements Timer {
  _TrackedTimer(this._inner, this._tracker);

  final Timer _inner;
  final _InputWorkTracker _tracker;
  bool _finished = false;

  void finish() {
    if (_finished) return;
    _finished = true;
    _tracker.pendingTimers -= 1;
  }

  @override
  void cancel() {
    _inner.cancel();
    finish();
  }

  @override
  bool get isActive => _inner.isActive;

  @override
  int get tick => _inner.tick;
}

final RegExp _stackFrameUri = RegExp(
  r'\(((?:dart|package|file):[^)]*?)(?::\d+)*\)$',
);

/// Who scheduled a piece of input work.
enum _InputWorkCaller { app, framework, platformChannel }

/// The first caller outside `dart:` and Scout itself: app or third-party
/// code ([_InputWorkCaller.app], with its library in [source]), Flutter's
/// platform-channel layer (a message to the engine, such as tap feedback's
/// sound or semantics event, whose reply nothing on screen waits for), or the
/// rest of the framework. A frame Scout cannot read counts as app code, so an
/// unreadable stack never ends the window early. flutter_test stands in for
/// the engine and platform in widget tests.
(_InputWorkCaller, String?) _inputWorkCaller(StackTrace stack) {
  for (final line in stack.toString().split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('<asynchronous')) continue;
    final match = _stackFrameUri.firstMatch(trimmed);
    if (match == null) return (_InputWorkCaller.app, 'unknown');
    final uri = match.group(1)!;
    if (uri.startsWith('dart:') ||
        uri.startsWith('package:flutter_scout_helper/')) {
      continue;
    }
    if (uri.startsWith('package:flutter/src/services/') ||
        uri.startsWith('package:flutter_test/')) {
      return (_InputWorkCaller.platformChannel, null);
    }
    if (uri.startsWith('package:flutter/')) {
      return (_InputWorkCaller.framework, null);
    }
    return (_InputWorkCaller.app, uri);
  }
  return (_InputWorkCaller.framework, null);
}

extension _RuntimeInputWork on FlutterScoutRuntime {
  /// The tracker of the current mutation request's input, created by its
  /// first pointer event.
  _InputWorkTracker? get _inputWork => _requestContext?.inputWork;

  /// Runs one pointer dispatch inside the request's input-work zone.
  T _runTrackedInput<T>(T Function() body) {
    final context = _requestContext;
    if (context == null || !context.mutating) return body();
    final tracker = context.inputWork ??= _InputWorkTracker(Zone.current);
    if (!tracker.active) return body();
    return tracker.run(body);
  }

  /// Flutter has nothing left to draw for the app: no frame scheduled or in
  /// progress and no app ticker running (Scout's driving overlay excluded).
  bool get _framePipelineIdle {
    final binding = WidgetsBinding.instance;
    return binding.framesEnabled &&
        !binding.hasScheduledFrame &&
        binding.schedulerPhase == SchedulerPhase.idle &&
        _appTransientCallbackCount == 0;
  }

  /// The input started no work Scout can still see running, and Flutter is
  /// idle, so a late change has nothing left to come from.
  bool get _inputWorkSettled {
    final work = _inputWork;
    return work != null && work.idle && _framePipelineIdle;
  }

  void _endInputWorkTracking() {
    _requestContext?.inputWork?.active = false;
  }
}
