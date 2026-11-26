part of 'flutter_scout_binding.dart';

extension _RuntimeRendering on FlutterScoutRuntime {
  void _installRenderingProbe() {
    _renderingProbeInstalled = true;
    // Observe natural framework frames without requesting one. A persistent
    // callback itself does not schedule frames or keep a background app awake.
    WidgetsBinding.instance.addPersistentFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _completedFrameworkFrames++;
        _lastFrameworkFrameAt = _renderingClock.elapsedMilliseconds;
      });
    });
  }

  Map<String, Object?> _renderingState() {
    final binding = WidgetsBinding.instance;
    final enabled = binding.framesEnabled;
    final lifecycle = binding.lifecycleState?.name ?? 'unknown';
    // Flutter's lifecycle alone misses a window macOS hides: an app started
    // behind the lock screen, or a display that sleeps without the window
    // going hidden. `active` needs both to agree.
    final host = _hostFacts();
    final hostReason = host?.hiddenReason;
    final onScreen = enabled && hostReason == null;
    // Driven only for a request whose session opted into headless drive;
    // without it, an app that is not on screen is reported (and refused) as
    // suspended.
    final headless = _headlessRequested;
    final driven = headless && !onScreen;
    return {
      'status': onScreen
          ? 'active'
          : driven
          ? 'driven'
          : 'suspended',
      'framesEnabled': enabled,
      'lifecycle': lifecycle,
      'host': ?host?.toJson(),
      if (!onScreen && !driven)
        'notVisibleBecause': _hiddenPhrase(hostReason, lifecycle),
      'schedulerPhase': binding.schedulerPhase.name,
      'hasScheduledFrame': binding.hasScheduledFrame,
      'completedFrameworkFrames': _completedFrameworkFrames,
      'lastFrameworkFrameAgeMs': _lastFrameworkFrameAt == null
          ? null
          : _renderingClock.elapsedMilliseconds - _lastFrameworkFrameAt!,
      'observedAt': DateTime.now().toUtc().toIso8601String(),
      'source': 'flutter_scheduler_and_framework_frame_callback',
      'pixelFreshness': driven ? 'scout_driven_frame' : 'not_observed',
      'scoutSchedulesFrames': driven,
      if (headless)
        'headlessDrive': _headlessDriveState(
          onScreen: onScreen,
          lifecycle: lifecycle,
        ),
      'nextAction': onScreen || driven
          ? 'inspect_changes'
          : 'make_app_visible_then_observe_again',
      'limitations': [
        'An old frame can be a genuinely idle screen; age alone is not staleness.',
        'Completed framework frames do not prove compositor or platform-view pixels.',
        if (driven)
          'Frames are driven by Scout while the app is not visible; native '
              'window pixels, platform views and vsync-timed behavior are not '
              'what a visible app would show.',
        if (!onScreen && !driven)
          'Deferred widget builds may not reflect timer or network changes until rendering resumes.',
        if (enabled && hostReason != null)
          'macOS hides the window although Flutter has not stopped frames; '
              'with the display asleep no vsync arrives, so scheduled frames '
              'wait.',
      ],
    };
  }
}
