part of 'flutter_scout_binding.dart';

// part: opt-in headless drive. While a Scout agent keeps sending requests that
// carry `headlessDrive=true` and the app is not on screen (Flutter stopped
// frames because the lifecycle is hidden/paused, or macOS reports the display
// asleep, the screen locked, the session switched away or the window
// occluded; see runtime_macos_host.dart), the helper advances frames itself so
// the agent can keep observing and acting. It never fakes the lifecycle: app
// code that reacts to `hidden` still runs, and every response says the app is
// driven headless.

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
  VoidCallback? buildHook;
  VoidCallback? previousBuildScheduled;

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

  /// True when this request may treat an app that is not on screen as
  /// driven.
  bool get _headlessDriving => _headlessRequested && !_appOnScreen;

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
    if (_appOnScreen) {
      // Visible again while the loop was idle: nothing else would record it.
      if (drive.loop != 'stopped') _stopHeadlessLoop('rendering_resumed');
      return;
    }
    // Bring the tree up to date for this observation or action. Unlike the
    // loop, this runs even when nothing reported a pending build: a
    // render-only change (a repaint) has no build hook to report it.
    if (_driveHeadlessFrame()) drive.requestFrames += 1;
    _scheduleHeadlessFrame();
  }

  /// Advances one frame with an advancing clock; false when the app is on
  /// screen (Flutter renders on its own) or a frame is already in progress.
  /// With frames enabled but the display asleep, vsync has stopped and this
  /// frame is the only one; behind a lock screen with the display awake,
  /// Flutter's own frames may still run between these.
  bool _driveHeadlessFrame() {
    final binding = WidgetsBinding.instance;
    if (_appOnScreen || binding.schedulerPhase != SchedulerPhase.idle) {
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
      // The driving overlay's own ticker is not app work: nobody sees it
      // while the app is hidden, so it never keeps the loop running.
      _appTransientCallbackCount > 0;

  /// Schedules the next self-driven frame when the drive is attached, the
  /// app is not on screen and a build or animation is pending.
  void _scheduleHeadlessFrame() {
    final drive = _headless;
    if (drive.frameTimer != null) return;
    if (!_headlessLeaseActive) return;
    if (_appOnScreen) {
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
      if (_appOnScreen) {
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

  /// A setState while frames are stopped schedules no engine frame; the
  /// build hook notices it so the loop can build it.
  void _noteHeadlessBuildScheduled() {
    if (_headlessLeaseActive && !_appOnScreen) {
      _headless.buildPending = true;
      _scheduleHeadlessFrame();
    }
  }

  /// While the driving overlay tracks app work it owns `onBuildScheduled`
  /// (it checks that the hook is still its own) and forwards app builds
  /// here; otherwise headless drive chains its own hook.
  void _installHeadlessBuildHook() {
    final drive = _headless;
    _drivingOverlay.onAppBuildScheduled ??= _noteHeadlessBuildScheduled;
    if (_drivingOverlay.tracksAppWork) return;
    final owner = WidgetsBinding.instance.buildOwner;
    if (owner == null) return;
    final hook = drive.buildHook ??= () {
      drive.previousBuildScheduled?.call();
      _noteHeadlessBuildScheduled();
    };
    if (identical(owner.onBuildScheduled, hook)) return;
    drive.previousBuildScheduled = owner.onBuildScheduled;
    owner.onBuildScheduled = hook;
  }

  /// Why the app is not on screen, most specific first: what macOS
  /// reports, otherwise the lifecycle. Occlusion is what Flutter's own
  /// `hidden` comes from, so it is named only when the lifecycle missed it.
  String _headlessReason(String lifecycle) {
    final host = _hostFacts()?.hiddenReason;
    if (host != null && !(host == 'window_occluded' && lifecycle == 'hidden')) {
      return host;
    }
    return switch (lifecycle) {
      'hidden' => 'app_hidden',
      'paused' => 'app_paused',
      _ => 'frames_disabled',
    };
  }

  /// The `headlessDrive` block of the rendering state, present only when the
  /// request asked for headless drive.
  Map<String, Object?> _headlessDriveState({
    required bool onScreen,
    required String lifecycle,
  }) {
    final drive = _headless;
    final driving = !onScreen;
    final reason = driving ? _headlessReason(lifecycle) : null;
    return {
      'enabled': true,
      'driving': driving,
      'reason': ?reason,
      'notice': driving
          ? 'HEADLESS: ${_hiddenPhrase(reason, lifecycle)}, so nobody sees '
                'the window; Scout is driving its frames. Nobody can see this '
                'app while the agent acts on it.'
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

/// Plain words for a hidden reason, shared by rendering and headless notices.
String _hiddenPhrase(String? reason, String lifecycle) => switch (reason) {
  'display_asleep' => 'macOS reports the display is asleep',
  'screen_locked' =>
    'macOS reports the screen is locked (the login window is in front)',
  'session_inactive' =>
    'macOS reports this login session is not on the console (another user '
        'is switched in)',
  'window_occluded' =>
    'macOS reports no part of the app window is visible (minimized, covered '
        'or on another Space)',
  _ => 'the app is not visible (lifecycle $lifecycle)',
};

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
