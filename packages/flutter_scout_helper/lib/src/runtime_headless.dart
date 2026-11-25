part of 'flutter_scout_binding.dart';

// part: opt-in headless drive. While a Scout agent keeps sending requests that
// carry `headlessDrive=true` and Flutter has stopped frames because the app is
// not visible (lifecycle hidden/paused: minimized, covered, display asleep or
// screen locked), the helper advances frames itself so the agent can keep
// observing and acting. It never fakes the lifecycle: app code that reacts to
// `hidden` still runs, and every response says the app is driven headless.

/// How long one headless-drive request keeps the drive active. An attached
/// agent's eyes poll every 250 ms by default, so this lapses within a few
/// seconds of the agent disconnecting or the flag being turned off.
const Duration _headlessDriveLease = Duration(seconds: 5);

/// Minimum gap between self-driven frames: at most 20 frames per second, and
/// only while a build or an animation is pending.
const Duration _headlessDriveFrameInterval = Duration(milliseconds: 50);

class _HeadlessDrive {
  int? leaseUntilMs;
  Timer? leaseTimer;
  Timer? frameTimer;
  bool buildPending = false;
  bool buildHookInstalled = false;

  /// Frames Scout drove for requests (observation, preflight, capture).
  int requestFrames = 0;

  /// Frames the self-driven loop advanced between requests.
  int loopFrames = 0;

  /// `running`, `idle` (attached, nothing needs a frame) or `stopped`.
  String loop = 'stopped';
  String? stoppedReason;

  /// Fabricated frame clock: anchored to the last engine timestamp and
  /// advanced by real elapsed time, so it always lags the engine's own clock
  /// and a real vsync after resume stays monotonically ahead.
  Duration? clockBase;
  Stopwatch? clock;

  _AppNapActivity? appNap;
  String appNapStatus = 'not_requested';

  ({int atMs, bool? locked, bool? asleep})? hostFacts;
}

extension _RuntimeHeadless on FlutterScoutRuntime {
  /// Whether this request asked for headless drive. Debug-only by
  /// construction: the helper registers nothing outside debug builds.
  bool get _headlessRequested {
    if (!kDebugMode) return false;
    final context = Zone.current[_requestContextZoneKey] as _RequestContext?;
    return context?.params['headlessDrive'] == 'true';
  }

  bool get _headlessLeaseActive {
    final until = _headless.leaseUntilMs;
    return until != null && _renderingClock.elapsedMilliseconds < until;
  }

  /// True when this request may treat suspended rendering as driven.
  bool get _headlessDriving =>
      _headlessRequested && !WidgetsBinding.instance.framesEnabled;

  /// Called for every protocol request that carries `headlessDrive=true`,
  /// after its parameters were validated and before its handler runs.
  void _beginHeadlessRequest() {
    final drive = _headless;
    drive.leaseUntilMs =
        _renderingClock.elapsedMilliseconds +
        _headlessDriveLease.inMilliseconds;
    drive.leaseTimer?.cancel();
    drive.leaseTimer = Timer(_headlessDriveLease, () {
      if (!_headlessLeaseActive) _endHeadlessDrive('lease_expired');
    });
    _installHeadlessBuildHook();
    if (drive.appNap == null && drive.appNapStatus != 'unavailable') {
      final activity = _AppNapActivity.begin();
      drive.appNap = activity;
      drive.appNapStatus = activity == null ? 'unavailable' : 'prevented';
    }
    if (WidgetsBinding.instance.framesEnabled) return;
    // Bring the tree up to date for this observation or action. Unlike the
    // loop, this runs even when nothing reported a pending build: a
    // render-only change (a repaint) has no build hook to report it.
    if (_driveHeadlessFrame()) drive.requestFrames += 1;
    _scheduleHeadlessFrame();
  }

  /// Advances one frame with an advancing clock; false when Flutter is
  /// rendering on its own or a frame is already in progress.
  bool _driveHeadlessFrame() {
    final binding = WidgetsBinding.instance;
    if (binding.framesEnabled ||
        binding.schedulerPhase != SchedulerPhase.idle) {
      return false;
    }
    final drive = _headless;
    final clock = drive.clock ??= Stopwatch()..start();
    final base = drive.clockBase ??= binding.currentSystemFrameTimeStamp;
    var stamp = base + clock.elapsed;
    // Post-mutation settling also advances frames; stay monotonic with it.
    final last = binding.currentSystemFrameTimeStamp;
    if (stamp <= last) stamp = last + const Duration(milliseconds: 1);
    drive.buildPending = false;
    binding.handleBeginFrame(stamp);
    binding.handleDrawFrame();
    return true;
  }

  bool get _headlessNeedsFrame =>
      _headless.buildPending ||
      WidgetsBinding.instance.transientCallbackCount > 0;

  /// Schedules the next self-driven frame when the drive is attached, Flutter
  /// has stopped frames and a build or animation is pending.
  void _scheduleHeadlessFrame() {
    final drive = _headless;
    if (drive.frameTimer != null) return;
    if (!_headlessLeaseActive) return;
    if (WidgetsBinding.instance.framesEnabled) {
      _stopHeadlessLoop('rendering_resumed');
      return;
    }
    if (!_headlessNeedsFrame) {
      drive.loop = 'idle';
      return;
    }
    drive.loop = 'running';
    drive.stoppedReason = null;
    drive.frameTimer = Timer(_headlessDriveFrameInterval, () {
      drive.frameTimer = null;
      if (!_headlessLeaseActive) {
        _endHeadlessDrive('lease_expired');
        return;
      }
      if (WidgetsBinding.instance.framesEnabled) {
        _stopHeadlessLoop('rendering_resumed');
        return;
      }
      if (_headlessNeedsFrame && _driveHeadlessFrame()) drive.loopFrames += 1;
      _scheduleHeadlessFrame();
    });
  }

  void _stopHeadlessLoop(String reason) {
    final drive = _headless;
    drive.frameTimer?.cancel();
    drive.frameTimer = null;
    drive.loop = 'stopped';
    drive.stoppedReason = reason;
    // Re-anchor the fabricated clock on the next hide.
    drive.clock = null;
    drive.clockBase = null;
  }

  /// No request renewed the lease: the agent disconnected or its session
  /// turned headless drive off. Stop driving and let macOS nap the app again.
  void _endHeadlessDrive(String reason) {
    final drive = _headless;
    drive.leaseTimer?.cancel();
    drive.leaseTimer = null;
    drive.leaseUntilMs = null;
    _stopHeadlessLoop(reason);
    drive.appNap?.end();
    drive.appNap = null;
    if (drive.appNapStatus == 'prevented') drive.appNapStatus = 'released';
  }

  /// A setState while frames are stopped schedules no engine frame; this
  /// hook notices it so the loop can build it. Installed once, on first use.
  void _installHeadlessBuildHook() {
    final drive = _headless;
    if (drive.buildHookInstalled) return;
    final owner = WidgetsBinding.instance.buildOwner;
    if (owner == null) return;
    drive.buildHookInstalled = true;
    final previous = owner.onBuildScheduled;
    owner.onBuildScheduled = () {
      previous?.call();
      if (_headlessLeaseActive && !WidgetsBinding.instance.framesEnabled) {
        drive.buildPending = true;
        _scheduleHeadlessFrame();
      }
    };
  }

  /// Why Flutter stopped frames, most specific first. Lock and display
  /// sleep come from macOS itself; otherwise the lifecycle says hidden.
  String _headlessReason(String lifecycle) {
    final facts = _headlessHostFacts();
    if (facts.locked == true) return 'screen_locked';
    if (facts.asleep == true) return 'display_asleep';
    return switch (lifecycle) {
      'hidden' => 'app_hidden',
      'paused' => 'app_paused',
      _ => 'frames_disabled',
    };
  }

  ({bool? locked, bool? asleep}) _headlessHostFacts() {
    final injected = debugHeadlessHostFacts;
    if (injected != null) return injected;
    final now = _renderingClock.elapsedMilliseconds;
    final cached = _headless.hostFacts;
    if (cached != null && now - cached.atMs < 1000) {
      return (locked: cached.locked, asleep: cached.asleep);
    }
    final host = _MacosHost.instance;
    final locked = host?.screenLocked();
    final asleep = host?.displayAsleep();
    _headless.hostFacts = (atMs: now, locked: locked, asleep: asleep);
    return (locked: locked, asleep: asleep);
  }

  /// The `headlessDrive` block of the rendering state, present only when the
  /// request asked for headless drive.
  Map<String, Object?> _headlessDriveState({
    required bool framesEnabled,
    required String lifecycle,
  }) {
    final drive = _headless;
    final driving = !framesEnabled;
    final reason = driving ? _headlessReason(lifecycle) : null;
    final hidden = switch (reason) {
      'screen_locked' => 'the screen is locked',
      'display_asleep' => 'the display is asleep',
      _ => 'the app is not visible (lifecycle $lifecycle)',
    };
    return {
      'enabled': true,
      'driving': driving,
      'reason': ?reason,
      'notice': driving
          ? 'HEADLESS: $hidden, so Flutter stopped rendering; Scout is '
                'driving its frames. Nobody can see this app while the agent '
                'acts on it.'
          : 'Headless drive is on but idle: the app renders normally.',
      'loop': drive.loop,
      'stoppedReason': ?drive.stoppedReason,
      'requestFrames': drive.requestFrames,
      'loopFrames': drive.loopFrames,
      'maxLoopFps': 1000 ~/ _headlessDriveFrameInterval.inMilliseconds,
      'leaseMs': _headlessDriveLease.inMilliseconds,
      'appNap': drive.appNapStatus,
      'lifecycleFaked': false,
    };
  }
}

/// An `NSProcessInfo` activity that keeps macOS from napping (throttling
/// timers and CPU of) the hidden app while headless drive is attached. It
/// still allows idle system sleep: keeping the Mac awake is the user's call.
class _AppNapActivity {
  _AppNapActivity._(this._host, this._activity);

  final _MacosHost _host;
  ffi.Pointer<ffi.Void>? _activity;

  static _AppNapActivity? begin() {
    final host = _MacosHost.instance;
    final activity = host?.beginActivity('Flutter Scout headless drive');
    return activity == null ? null : _AppNapActivity._(host!, activity);
  }

  void end() {
    final activity = _activity;
    _activity = null;
    if (activity != null) _host.endActivity(activity);
  }
}

typedef _IdFromCString = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint8>);
typedef _MsgSendId =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _MsgSendBeginNative =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Uint64,
      ffi.Pointer<ffi.Void>,
    );
typedef _MsgSendBegin =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      int,
      ffi.Pointer<ffi.Void>,
    );
typedef _MsgSendVoidIdNative =
    ffi.Void Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _MsgSendVoidId =
    void Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _CopyDictionary = ffi.Pointer<ffi.Void> Function();
typedef _GetValue =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    );
typedef _TypeIdOfNative = ffi.UintPtr Function(ffi.Pointer<ffi.Void>);
typedef _TypeIdOf = int Function(ffi.Pointer<ffi.Void>);
typedef _TypeIdNative = ffi.UintPtr Function();
typedef _TypeId = int Function();
typedef _BoolOfNative = ffi.Uint8 Function(ffi.Pointer<ffi.Void>);
typedef _BoolOf = int Function(ffi.Pointer<ffi.Void>);
typedef _ReleaseNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _Release = void Function(ffi.Pointer<ffi.Void>);
typedef _MainDisplayNative = ffi.Uint32 Function();
typedef _MainDisplay = int Function();
typedef _DisplayAsleepNative = ffi.Int32 Function(ffi.Uint32);
typedef _DisplayAsleep = int Function(int);
typedef _MallocNative = ffi.Pointer<ffi.Uint8> Function(ffi.IntPtr);
typedef _Malloc = ffi.Pointer<ffi.Uint8> Function(int);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<ffi.Uint8>);
typedef _Free = void Function(ffi.Pointer<ffi.Uint8>);

/// The few macOS calls headless drive needs, through the Objective-C runtime,
/// Foundation and CoreGraphics with `dart:ffi`, so the helper stays a pure
/// Dart package with no plugin code. Null off macOS, under `flutter test`, or
/// when a symbol is missing; every call is best effort.
class _MacosHost {
  _MacosHost._(ffi.DynamicLibrary lib)
    : _malloc = lib.lookupFunction<_MallocNative, _Malloc>('malloc'),
      _free = lib.lookupFunction<_FreeNative, _Free>('free'),
      _getClass = lib.lookupFunction<_IdFromCString, _IdFromCString>(
        'objc_getClass',
      ),
      _selector = lib.lookupFunction<_IdFromCString, _IdFromCString>(
        'sel_registerName',
      ),
      _sendId = lib.lookupFunction<_MsgSendId, _MsgSendId>('objc_msgSend'),
      _sendBegin = lib.lookupFunction<_MsgSendBeginNative, _MsgSendBegin>(
        'objc_msgSend',
      ),
      _sendVoidId = lib.lookupFunction<_MsgSendVoidIdNative, _MsgSendVoidId>(
        'objc_msgSend',
      ),
      _stringFromSelector = lib.lookupFunction<_MsgSendIdOne, _MsgSendIdOne>(
        'NSStringFromSelector',
      ),
      _copySession = lib.lookupFunction<_CopyDictionary, _CopyDictionary>(
        'CGSessionCopyCurrentDictionary',
      ),
      _getValue = lib.lookupFunction<_GetValue, _GetValue>(
        'CFDictionaryGetValue',
      ),
      _typeIdOf = lib.lookupFunction<_TypeIdOfNative, _TypeIdOf>('CFGetTypeID'),
      _booleanTypeId = lib.lookupFunction<_TypeIdNative, _TypeId>(
        'CFBooleanGetTypeID',
      ),
      _booleanValue = lib.lookupFunction<_BoolOfNative, _BoolOf>(
        'CFBooleanGetValue',
      ),
      _release = lib.lookupFunction<_ReleaseNative, _Release>('CFRelease'),
      _mainDisplay = lib.lookupFunction<_MainDisplayNative, _MainDisplay>(
        'CGMainDisplayID',
      ),
      _displayAsleep = lib.lookupFunction<_DisplayAsleepNative, _DisplayAsleep>(
        'CGDisplayIsAsleep',
      );

  static _MacosHost? _instance;
  static bool _unavailable = false;

  static _MacosHost? get instance {
    if (_unavailable) return null;
    if (_instance != null) return _instance;
    try {
      if (!Platform.isMacOS ||
          Platform.environment.containsKey('FLUTTER_TEST')) {
        _unavailable = true;
        return null;
      }
      // Both frameworks are already loaded in a macOS Flutter app; opening
      // them only makes the lookups independent of the embedder's links.
      for (final framework in const ['Foundation', 'CoreGraphics']) {
        ffi.DynamicLibrary.open(
          '/System/Library/Frameworks/$framework.framework/$framework',
        );
      }
      return _instance = _MacosHost._(ffi.DynamicLibrary.process());
    } catch (_) {
      _unavailable = true;
      return null;
    }
  }

  final _Malloc _malloc;
  final _Free _free;
  final _IdFromCString _getClass;
  final _IdFromCString _selector;
  final _MsgSendId _sendId;
  final _MsgSendBegin _sendBegin;
  final _MsgSendVoidId _sendVoidId;
  final _MsgSendIdOne _stringFromSelector;
  final _CopyDictionary _copySession;
  final _GetValue _getValue;
  final _TypeIdOf _typeIdOf;
  final _TypeId _booleanTypeId;
  final _BoolOf _booleanValue;
  final _Release _release;
  final _MainDisplay _mainDisplay;
  final _DisplayAsleep _displayAsleep;
  final Map<String, ffi.Pointer<ffi.Void>> _selectors = {};
  ffi.Pointer<ffi.Void>? _lockedKey;

  ffi.Pointer<ffi.Void> _withCString(
    String value,
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint8>) use,
  ) {
    final bytes = utf8.encode(value);
    final pointer = _malloc(bytes.length + 1);
    try {
      pointer.asTypedList(bytes.length + 1)
        ..setAll(0, bytes)
        ..[bytes.length] = 0;
      return use(pointer);
    } finally {
      _free(pointer);
    }
  }

  ffi.Pointer<ffi.Void> _sel(String name) =>
      _selectors[name] ??= _withCString(name, _selector);

  /// An NSString, also usable as a CFString, from a selector name. Selector
  /// names are interned by the runtime, so the string is never freed.
  ffi.Pointer<ffi.Void> _string(String value) =>
      _stringFromSelector(_sel(value));

  /// `[[NSProcessInfo processInfo] beginActivityWithOptions:reason:]` with
  /// NSActivityUserInitiatedAllowingIdleSystemSleep, retained because the
  /// returned object is autoreleased and the activity ends when it is freed.
  ffi.Pointer<ffi.Void>? beginActivity(String reason) {
    try {
      final processInfo = _sendId(
        _withCString('NSProcessInfo', _getClass),
        _sel('processInfo'),
      );
      if (processInfo == ffi.nullptr) return null;
      const userInitiatedAllowingIdleSystemSleep = 0x00FFFFFF & ~(1 << 20);
      final activity = _sendBegin(
        processInfo,
        _sel('beginActivityWithOptions:reason:'),
        userInitiatedAllowingIdleSystemSleep,
        _string(reason),
      );
      if (activity == ffi.nullptr) return null;
      return _sendId(activity, _sel('retain'));
    } catch (_) {
      return null;
    }
  }

  void endActivity(ffi.Pointer<ffi.Void> activity) {
    try {
      final processInfo = _sendId(
        _withCString('NSProcessInfo', _getClass),
        _sel('processInfo'),
      );
      _sendVoidId(processInfo, _sel('endActivity:'), activity);
      _sendId(activity, _sel('release'));
    } catch (_) {}
  }

  /// `CGSSessionScreenIsLocked` in the current login session's dictionary.
  bool? screenLocked() {
    try {
      final session = _copySession();
      if (session == ffi.nullptr) return null;
      try {
        final key = _lockedKey ??= _string('CGSSessionScreenIsLocked');
        final value = _getValue(session, key);
        if (value == ffi.nullptr) return false;
        if (_typeIdOf(value) != _booleanTypeId()) return true;
        return _booleanValue(value) != 0;
      } finally {
        _release(session);
      }
    } catch (_) {
      return null;
    }
  }

  bool? displayAsleep() {
    try {
      return _displayAsleep(_mainDisplay()) != 0;
    } catch (_) {
      return null;
    }
  }
}

typedef _MsgSendIdOne = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);
