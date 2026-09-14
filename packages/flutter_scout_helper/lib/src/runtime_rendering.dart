part of 'flutter_scout_binding.dart';

extension _RuntimeRendering on FlutterScoutRuntime {
  void _installRenderingProbe() {
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
    return {
      'status': enabled ? 'active' : 'suspended',
      'framesEnabled': enabled,
      'lifecycle': binding.lifecycleState?.name ?? 'unknown',
      'schedulerPhase': binding.schedulerPhase.name,
      'hasScheduledFrame': binding.hasScheduledFrame,
      'completedFrameworkFrames': _completedFrameworkFrames,
      'lastFrameworkFrameAgeMs': _lastFrameworkFrameAt == null
          ? null
          : _renderingClock.elapsedMilliseconds - _lastFrameworkFrameAt!,
      'observedAt': DateTime.now().toUtc().toIso8601String(),
      'source': 'flutter_scheduler_and_framework_frame_callback',
      'pixelFreshness': 'not_observed',
      'scoutSchedulesFrames': false,
      'nextAction': enabled
          ? 'inspect_changes'
          : 'make_app_visible_then_observe_again',
      'limitations': [
        'An old frame can be a genuinely idle screen; age alone is not staleness.',
        'Completed framework frames do not prove compositor or platform-view pixels.',
        if (!enabled)
          'Deferred widget builds may not reflect timer or network changes until rendering resumes.',
      ],
    };
  }
}
