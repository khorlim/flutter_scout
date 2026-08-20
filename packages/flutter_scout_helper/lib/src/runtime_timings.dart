part of 'flutter_scout_binding.dart';

// part: exclusive, monotonic-clock request-phase timing.

const List<String> _scoutRequestPhaseNames = <String>[
  'connect',
  'snapshot',
  'match',
  'dispatch',
  'settle',
  'delta',
  'logs',
  'serialize',
];

const Set<String> _helperRequestPhaseNames = <String>{
  'snapshot',
  'match',
  'dispatch',
  'settle',
  'delta',
};

final Object _requestPhaseTimingsZoneKey = Object();

/// A request-local exclusive timeline.
///
/// Entering a phase closes the preceding phase at the same monotonic clock
/// reading, so measured phases never overlap. Calls made while another phase
/// operation is active inherit that outer phase. This is especially important
/// for snapshots taken by the stability observer: the complete observation
/// interval belongs to `settle`, rather than being counted in both `settle`
/// and `snapshot`.
///
/// A composite navigation transaction may revisit an earlier logical bucket
/// after a later one (for example, dispatching one bounded scroll and then
/// matching again). Those occurrences remain disjoint on this timeline and
/// are accumulated into the canonical bucket; phase-name order is therefore
/// not used as a proxy for wall-clock order.
class _RequestPhaseTimings {
  _RequestPhaseTimings({
    required this.mutating,
    required this.command,
    Stopwatch? stopwatch,
  }) : _stopwatch = stopwatch ?? (Stopwatch()..start());

  final bool mutating;
  final String command;
  final Stopwatch _stopwatch;
  final Map<String, int> _elapsedMicros = <String, int>{};
  final Map<String, String> _unavailableReasons = <String, String>{};

  String? _activePhase;
  int? _activePhaseStartedMicros;
  int _operationDepth = 0;
  bool _finalized = false;
  bool _dispatchEntered = false;

  /// A snapshot before the first dispatch is perception work; a snapshot after
  /// dispatch is part of factual outcome/delta observation. Snapshots nested
  /// inside a locked settle operation inherit `settle` before this value is
  /// consulted.
  String get snapshotPhase => _dispatchEntered ? 'delta' : 'snapshot';

  T inPhase<T>(String phase, T Function() operation) {
    _validateHelperPhase(phase);
    if (_operationDepth > 0) return operation();
    _enter(phase);
    _operationDepth += 1;
    try {
      return operation();
    } finally {
      _operationDepth -= 1;
    }
  }

  Future<T> inPhaseAsync<T>(
    String phase,
    Future<T> Function() operation,
  ) async {
    _validateHelperPhase(phase);
    if (_operationDepth > 0) return operation();
    _enter(phase);
    _operationDepth += 1;
    try {
      return await operation();
    } finally {
      _operationDepth -= 1;
    }
  }

  void markUnavailable(String phase, String reason) {
    if (!_scoutRequestPhaseNames.contains(phase)) {
      throw ArgumentError.value(phase, 'phase', 'Unknown Scout phase.');
    }
    if (reason.trim().isEmpty) {
      throw ArgumentError.value(reason, 'reason', 'Reason cannot be empty.');
    }
    _unavailableReasons.putIfAbsent(phase, () => reason.trim());
  }

  /// Stops the active clock and returns all eight phase records.
  ///
  /// Helper-owned phases that were never reached remain explicitly
  /// unavailable. CLI-owned boundaries are also unavailable here and are
  /// replaced with measurements by the CLI before output/evidence commit.
  Map<String, Object?> finalizePhases() {
    if (!_finalized) {
      _accrueActive(_stopwatch.elapsedMicroseconds);
      _activePhase = null;
      _activePhaseStartedMicros = null;
      _finalized = true;
    }
    return <String, Object?>{
      for (final phase in _scoutRequestPhaseNames) phase: _phaseRecord(phase),
    };
  }

  Map<String, Object?> _phaseRecord(String phase) {
    final micros = _elapsedMicros[phase];
    if (micros != null) {
      return <String, Object?>{
        'status': 'measured',
        'elapsedMs': micros ~/ Duration.microsecondsPerMillisecond,
        'owner': 'helper',
        'scope': _helperPhaseScope(phase),
        'clock': 'monotonic_stopwatch',
        'aggregation': 'exclusive_non_overlapping',
      };
    }
    final reason =
        _unavailableReasons[phase] ??
        (!_helperRequestPhaseNames.contains(phase)
            ? 'measured_at_cli_boundary'
            : mutating
            ? 'phase_not_reached_before_response'
            : 'not_applicable_for_read:$command');
    return <String, Object?>{
      'status': 'unavailable',
      'elapsedMs': null,
      'owner': _helperRequestPhaseNames.contains(phase) ? 'helper' : 'cli',
      'reason': reason,
    };
  }

  String _helperPhaseScope(String phase) => switch (phase) {
    'snapshot' =>
      'fresh pre-dispatch observation and helper work until matching begins',
    'match' =>
      'target matching, safety resolution, and helper work until dispatch begins',
    'dispatch' =>
      'single interaction dispatch and helper work until settling begins',
    'settle' =>
      'post-dispatch activity observation, frame settling, and semantic quiescence only',
    'delta' =>
      'post-settle observation, factual delta calculation, and response assembly',
    _ => 'helper request work',
  };

  void _validateHelperPhase(String phase) {
    if (!_helperRequestPhaseNames.contains(phase)) {
      throw ArgumentError.value(
        phase,
        'phase',
        'Only helper-owned phases can be entered by the runtime.',
      );
    }
    if (_finalized) {
      throw StateError('Request phase timings were already finalized.');
    }
  }

  void _enter(String phase) {
    if (_activePhase == phase) return;
    final nowMicros = _stopwatch.elapsedMicroseconds;
    _accrueActive(nowMicros);
    _activePhase = phase;
    _activePhaseStartedMicros = nowMicros;
    if (phase == 'dispatch') _dispatchEntered = true;
  }

  void _accrueActive(int nowMicros) {
    final phase = _activePhase;
    final started = _activePhaseStartedMicros;
    if (phase == null || started == null) return;
    final elapsed = math.max(0, nowMicros - started);
    _elapsedMicros.update(
      phase,
      (value) => value + elapsed,
      ifAbsent: () => elapsed,
    );
  }
}

extension _RuntimePhaseTiming on FlutterScoutRuntime {
  _RequestPhaseTimings? get _requestPhaseTimings =>
      Zone.current[_requestPhaseTimingsZoneKey] as _RequestPhaseTimings?;

  String get _requestSnapshotPhase =>
      _requestPhaseTimings?.snapshotPhase ?? 'snapshot';

  T _inRequestPhase<T>(String phase, T Function() operation) =>
      _requestPhaseTimings?.inPhase(phase, operation) ?? operation();

  Future<T> _inRequestPhaseAsync<T>(
    String phase,
    Future<T> Function() operation,
  ) => _requestPhaseTimings?.inPhaseAsync(phase, operation) ?? operation();

  void _markRequestPhaseUnavailable(String phase, String reason) =>
      _requestPhaseTimings?.markUnavailable(phase, reason);
}
