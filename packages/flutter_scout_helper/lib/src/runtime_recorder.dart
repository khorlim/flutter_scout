part of 'flutter_scout_binding.dart';

// part: the in-app flow recorder. Passively observes the tester's real pointer
// and text-field activity via ONE global pointer route, maps each gesture to a
// Scout stable handle (the same id `inspect`/`tap`/`replay` use), classifies it
// (tap / long-press / scroll / drag), captures a lightweight auto-assertion
// from the before→after snapshot delta, and buffers session.json-shaped step
// maps. Recordings persist to <project>/.flutter_scout/recordings/ so the
// existing replay/batch executors run human recordings unchanged.

/// Per-pointer capture state, opened on PointerDown and resolved on PointerUp.
class _RecordPointer {
  _RecordPointer({
    required this.downPosition,
    required this.downAt,
    required this.downWallAt,
    required this.before,
    required this.ignored,
  });

  final Offset downPosition;
  final Duration downAt;
  // Wall-clock at pointer-down — the true moment of the human action, used to
  // measure inter-step dwell without the previous step's settle time leaking in.
  final DateTime downWallAt;
  // Snapshot taken at pointer-down; the before-state for this gesture's delta.
  final ScoutSnapshot before;
  // True when the gesture began on Scout's own chrome (launcher/menu/HUD) — it
  // is watched only to be dropped, never recorded.
  final bool ignored;
}

/// Marker prefix for a redacted (obscured-field) value. Stored in place of the
/// real text; supplied at replay via `--var <field>=<value>`.
const String _kRecordRedactedPrefix = '\u0000VAR:';

const String _kRecordDataClassification = 'private_application_data';
const int _kRecordPrivateDirectoryMode = 0x1c0; // 0700
const int _kRecordPrivateFileMode = 0x180; // 0600
const Duration _kRecordStaleTemporaryAge = Duration(hours: 24);
const int _kRecordMaximumArtifactBytes = 8 * 1024 * 1024;
const int _kRecordMaximumScanEntries = 10000;

final RegExp _kRecordStorageSegment = RegExp(
  r'^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$',
);
final RegExp _kRecordOwnedTemporaryName = RegExp(
  r'^\.[a-z0-9][a-z0-9-]*\.json\.[0-9]+\.[0-9]+\.[0-9]+\.tmp$',
);

class _RecordingStorageFailure implements Exception {
  const _RecordingStorageFailure(this.code);

  final String code;
}

class _RecordingStoreLocation {
  const _RecordingStoreLocation({required this.boundary, required this.root});

  final String boundary;
  final String root;
}

class _RecordingWriteResult {
  const _RecordingWriteResult.persisted(this.path)
    : status = 'persisted_by_helper',
      reason = null;

  const _RecordingWriteResult.delegated(this.reason)
    : path = null,
      status = 'delegated_to_cli';

  final String? path;
  final String status;
  final String? reason;
}

extension _RuntimeRecorder on FlutterScoutRuntime {
  // ---- lifecycle --------------------------------------------------------

  void _installRecorderRoute() {
    if (_recordRouteInstalled) return;
    // A global route observes every pointer event app-wide and CANNOT consume
    // or block the gesture (routes are notified, not hit-test participants).
    GestureBinding.instance.pointerRouter.addGlobalRoute(
      _onRecorderPointerEvent,
    );
    _recordRouteInstalled = true;
  }

  /// Toggle used by the in-app menu Record row. Auto-names on start so the
  /// tester can just tap-act-stop; rename/regroup afterward.
  Future<Map<String, Object?>> _toggleRecording() {
    if (_recording) return _stopRecording();
    return Future.value(_startRecording());
  }

  Map<String, Object?> _startRecording({
    String? name,
    String? feature,
    String? title,
  }) {
    if (_recording) {
      return {'ok': false, 'error': 'already_recording', 'name': _recordName};
    }
    final baseline = _snapshot();
    return _inRequestPhase('dispatch', () {
      _recordSteps.clear();
      _recordPointers.clear();
      _recordPaused = false;
      _recordBaseline = baseline;
      _recordCommitTail = Future<void>.value();
      _recordLastActionAt = DateTime.now();
      _recordPendingDwellMs = 0;
      _recordStartedAt = DateTime.now();
      _recordStartScreen = baseline.screen;
      _recordFeature = _recordSlug(feature) ?? 'unsorted';
      _recordName = _recordSlug(name) ?? _recordAutoName();
      _recordTitle = (title != null && title.trim().isNotEmpty)
          ? title.trim()
          : null;
      _recording = true;
      // Starting a recording is an explicit request for the recording HUD.
      // The runtime itself never installs overlay chrome merely because it
      // attached or because an observation command ran.
      _annotationOverlayOptedIn = true;
      _bumpRecordRevision();
      _reconcileAnnotationOverlay();
      return {'ok': true, ..._recordStatusJson()};
    });
  }

  Future<Map<String, Object?>> _stopRecording({bool discard = false}) async {
    if (!_recording) {
      return {'ok': false, 'error': 'not_recording'};
    }
    // Complete the recorder precondition before this command dispatches. This
    // is snapshot/precondition work, not post-dispatch application settling.
    await _inRequestPhaseAsync('snapshot', () async {
      await _recordCommitTail;
      // Flush any trailing text edit the tester made before hitting stop.
      _recordFlushFieldEdits(_snapshot());
    });
    final name = _recordName!;
    final feature = _recordFeature!;
    final flow = _recordFlowJson();
    return _inRequestPhaseAsync('dispatch', () async {
      _recording = false;
      _recordPaused = false;
      _recordPointers.clear();
      _recordBaseline = null;
      _bumpRecordRevision();
      _reconcileAnnotationOverlay();
      if (discard) {
        _resetRecordMeta();
        return {'ok': true, 'discarded': true, 'name': name};
      }
      final written = await _writeRecordingToDisk(feature, name, flow);
      _resetRecordMeta();
      return {
        'ok': true,
        'name': name,
        'feature': feature,
        'stepCount': (flow['steps'] as List).length,
        'path': ?written.path,
        'persisted': written.path != null,
        'persistenceStatus': written.status,
        if (written.reason != null) 'persistenceReason': written.reason,
        'artifactHandling': {
          'dataClassification': _kRecordDataClassification,
          'containsPrivateApplicationData': true,
          'retentionPolicy': 'manual',
          'telemetryCollected': false,
          'cliFallbackAvailable': true,
        },
        // Always hand the flow back so a CLI/agent driver can persist it even
        // when the app sandbox cannot reach the project dir (iOS simulator).
        'flow': flow,
      };
    });
  }

  void _pauseRecording() {
    if (_recording && !_recordPaused) {
      _inRequestPhase('dispatch', () {
        _recordPaused = true;
        _bumpRecordRevision();
      });
    }
  }

  void _resumeRecording() {
    if (_recording && _recordPaused) {
      // Re-baseline so a mid-pause manual change isn't attributed to a step.
      final baseline = _snapshot();
      _inRequestPhase('dispatch', () {
        _recordPaused = false;
        _recordBaseline = baseline;
        _bumpRecordRevision();
      });
    }
  }

  Map<String, Object?> _undoLastStep() {
    if (_recordSteps.isEmpty) {
      return {'ok': true, 'dropped': null, 'stepCount': 0};
    }
    return _inRequestPhase('dispatch', () {
      final dropped = _recordSteps.removeLast();
      _bumpRecordRevision();
      return {
        'ok': true,
        'dropped': _recordPublicStep(dropped),
        'stepCount': _recordSteps.length,
      };
    });
  }

  void _resetRecordMeta() {
    _recordName = null;
    _recordFeature = null;
    _recordTitle = null;
    _recordStartedAt = null;
    _recordStartScreen = null;
    _recordSteps.clear();
  }

  void _bumpRecordRevision() {
    _recordRevision.value++;
    // The overlay chrome (REC HUD, menu Record row) repaints off the annotation
    // revision, so bump both to keep it live without a second listener.
    _bumpAnnotationRevision();
  }

  String _recordAutoName() {
    final now = _recordStartedAt ?? DateTime.now();
    final stamp =
        '${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        '-${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    _recordAutoNameSeq++;
    return 'rec-$stamp-$_recordAutoNameSeq';
  }

  String? _recordSlug(String? raw) {
    if (raw == null) return null;
    final slug = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? null : slug;
  }

  // ---- pointer observation ---------------------------------------------

  void _onRecorderPointerEvent(PointerEvent event) {
    if (!_recording || _recordPaused) return;
    // Both human taps AND agent-dispatched (synthetic) taps are captured, so an
    // agent can record a repetitive flow of its own CLI actions the same way a
    // tester records manual ones. Only non-primary views and Scout's own chrome
    // (handled per-gesture below) are excluded.
    if (event.viewId != _primaryViewId) return;

    if (event is PointerDownEvent) {
      final onChrome = _pointHitsScoutChrome(event.position);
      // Snapshot the before-state once per gesture (skip for chrome taps).
      _recordPointers[event.pointer] = _RecordPointer(
        downPosition: event.position,
        downAt: event.timeStamp,
        downWallAt: DateTime.now(),
        before: onChrome ? _recordBaseline ?? _snapshot() : _snapshot(),
        ignored: onChrome,
      );
    } else if (event is PointerUpEvent) {
      final state = _recordPointers.remove(event.pointer);
      if (state == null || state.ignored) return;
      // Serialize commits so a gesture whose settle spans a load can't
      // interleave with the next one and race the shared baseline.
      final captured = state;
      final up = event;
      _recordCommitTail = _recordCommitTail
          .then((_) => _recordCommitGesture(captured, up))
          .catchError((_) {});
    } else if (event is PointerCancelEvent) {
      _recordPointers.remove(event.pointer);
    }
  }

  Future<void> _recordCommitGesture(
    _RecordPointer state,
    PointerUpEvent up,
  ) async {
    if (!_recording) return;
    // Dwell = the human's pause before this action (a replay pacing floor for
    // loads too silent to assert), measured pointer-down to pointer-down so the
    // previous step's settle time doesn't leak in. Stamped on the first step.
    final actionAt = state.downWallAt;
    final last = _recordLastActionAt;
    _recordPendingDwellMs = last == null
        ? 0
        : actionAt.difference(last).inMilliseconds.clamp(0, 15000);
    _recordLastActionAt = actionAt;

    // Wait for the UI to actually SETTLE — navigation, animations, AND async
    // content loads — before reading the after-state, so the captured
    // assertion reflects the loaded screen (and a replay waits for that load).
    final after = await _recordSettledSnapshot(state.before);
    final before = state.before;

    // Any text the tester typed before this gesture shows up as a field-value
    // change between the baseline and this gesture's before-state — flush it as
    // an `input` step first so the timeline interleaves correctly.
    _recordFlushFieldEdits(before);

    final displacement = (up.position - state.downPosition).distance;
    final durationMs = (up.timeStamp - state.downAt).inMilliseconds
        .abs()
        .toDouble();

    final Map<String, String> step;
    if (displacement < kTouchSlop) {
      step = durationMs >= kLongPressTimeout.inMilliseconds
          ? _recordPressStep(up.position, before, 'long-press')
          : _recordPressStep(up.position, before, 'tap');
    } else if (_viewportMoved(before, after)) {
      step = _recordScrollStep(state.downPosition, up.position, displacement);
    } else {
      step = _recordDragStep(state.downPosition, up.position);
    }

    // A tap that lands on a text field is recorded as the focus; the actual
    // value is captured by field-diffing when the next step flushes. Skip
    // emitting a redundant tap for it.
    if (step['cmd'] == 'tap' && step['_fieldFocus'] == 'true') {
      _recordBaseline = after;
      return;
    }
    step.remove('_fieldFocus');
    step.addAll(_recordDeriveAssertion(before, after));
    _recordEmitStep(step);
    _recordBaseline = after;
  }

  /// The settled after-state for a gesture: reuses the same stability + late
  /// change detection the action commands use ([_snapshotAfterAction]), so an
  /// async load that resolves within the window is reflected in the captured
  /// assertion. Bounded by [_recordSettleMs] + [_recordLateMs].
  Future<ScoutSnapshot> _recordSettledSnapshot(ScoutSnapshot before) async {
    final result = await _snapshotAfterAction(before, {
      'waitMs': '$_recordSettleMs',
      'lateWaitMs': '$_recordLateMs',
    });
    return result.snapshot;
  }

  // ---- gesture → step ---------------------------------------------------

  Map<String, String> _recordPressStep(
    Offset point,
    ScoutSnapshot before,
    String cmd,
  ) {
    final node = _recordResolveHandle(point, before);
    if (node == null) {
      return {
        'cmd': cmd,
        'x': point.dx.round().toString(),
        'y': point.dy.round().toString(),
        if (cmd == 'tap') 'waitMs': '1500',
      };
    }
    final step = <String, String>{
      'cmd': cmd,
      'target': node.id,
      if (cmd == 'tap') 'waitMs': '1500',
      if (node.label != null && node.label!.trim().isNotEmpty)
        '_label': node.label!.trim(),
    };
    if (node.kind == 'field' && cmd == 'tap') step['_fieldFocus'] = 'true';
    return step;
  }

  Map<String, String> _recordScrollStep(
    Offset from,
    Offset to,
    double displacement,
  ) {
    final delta = to - from;
    final horizontal = delta.dx.abs() > delta.dy.abs();
    // Content scrolls opposite the finger: a finger moving up reveals lower
    // content, which Scout calls `scroll down` (see _dragDelta).
    final direction = horizontal
        ? (delta.dx < 0 ? 'right' : 'left')
        : (delta.dy < 0 ? 'down' : 'up');
    return {
      'cmd': 'scroll',
      'direction': direction,
      'distance': displacement.round().toString(),
      'point': '${from.dx.round()},${from.dy.round()}',
    };
  }

  Map<String, String> _recordDragStep(Offset from, Offset to) {
    return {
      'cmd': 'swipe',
      'direction': _recordDragDirection(to - from),
      'from': '${from.dx.round()},${from.dy.round()}',
      'to': '${to.dx.round()},${to.dy.round()}',
    };
  }

  String _recordDragDirection(Offset delta) {
    if (delta.dx.abs() > delta.dy.abs()) {
      return delta.dx < 0 ? 'left' : 'right';
    }
    return delta.dy < 0 ? 'up' : 'down';
  }

  /// Point → the Scout handle that `findNode`/`tap` will resolve: the smallest
  /// hit-testable interactable or field whose rect contains the point. Same id
  /// ladder (keys > label > text > type) `inspect` emits, so replays are
  /// deterministic. Returns null → the caller records an (x,y) fallback.
  ScoutNode? _recordResolveHandle(Offset point, ScoutSnapshot snapshot) {
    ScoutNode? best;
    double? bestArea;
    for (final node in [...snapshot.interactables, ...snapshot.fields]) {
      final rect = node.rect;
      if (rect == null || !rect.contains(point)) continue;
      if (!node.hitTestable) continue;
      final area = rect.width * rect.height;
      if (bestArea == null || area < bestArea) {
        best = node;
        bestArea = area;
      }
    }
    return best;
  }

  bool _pointHitsScoutChrome(Offset point) {
    try {
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, point, _primaryViewId);
      for (final entry in result.path) {
        final target = entry.target;
        if (target is! RenderObject) continue;
        final creator = target.debugCreator;
        if (creator is! DebugCreator) continue;
        if (_isScoutOverlayWidget(creator.element.widget)) return true;
        var chrome = false;
        creator.element.visitAncestorElements((ancestor) {
          if (_isScoutOverlayWidget(ancestor.widget)) {
            chrome = true;
            return false;
          }
          return true;
        });
        if (chrome) return true;
      }
    } catch (_) {
      // A failed hit test should never abort recording; treat as "not chrome".
    }
    return false;
  }

  // ---- text capture (field-value diffing) ------------------------------

  /// Emits `input` steps for any field whose value changed between the recorder
  /// baseline and [current]. This captures typing without hooking FocusManager:
  /// by the time the tester taps the next control, the edited value is already
  /// in the tree.
  void _recordFlushFieldEdits(ScoutSnapshot current) {
    final baseline = _recordBaseline;
    if (baseline == null) return;
    final beforeFields = {for (final field in baseline.fields) field.id: field};
    for (final field in current.fields) {
      final before = beforeFields[field.id];
      // Emit whenever a field we already knew about changed value — including a
      // clear (populated → ''), which a replay must reproduce. Brand-new fields
      // are skipped as focus noise. Every recorded input value is private
      // application data and becomes a runtime variable placeholder at source;
      // sensitive fields also compare their private salted token, never
      // plaintext or length.
      if (before == null || before.hasSameFieldValue(field)) continue;
      final redacted = _recordShouldRedact(field);
      final step = <String, String>{
        'cmd': 'input',
        'target': field.id,
        'value': redacted
            ? '$_kRecordRedactedPrefix${field.id}'
            : field.value ?? '',
        if (redacted) '_redacted': 'true',
        if (redacted) '_redactionPolicy': 'source',
        if (field.label != null && field.label!.trim().isNotEmpty)
          '_label': 'enter ${field.label!.trim()}',
      };
      _recordEmitStep(step);
    }
    _recordBaseline = current;
  }

  // Recording is a persistence boundary. Even an apparently ordinary name,
  // note, or search value can contain credentials or personal data, and the
  // recorder cannot prove otherwise. Preserve only the field identity; replay
  // requests the value through the CLI's protected variable mechanism.
  bool _recordShouldRedact(ScoutNode _) => true;

  // ---- auto-assertion ---------------------------------------------------

  /// A lightweight per-step check derived from the before→after delta, stored in
  /// the existing `expect*` keys so replay/batch gate on it for free. Screen
  /// navigation → expectScreen; a same-route view swap → expectView; otherwise a
  /// salient new text → expectText. Nothing when nothing observably changed.
  Map<String, String> _recordDeriveAssertion(
    ScoutSnapshot before,
    ScoutSnapshot after,
  ) {
    if (before.screen != after.screen && after.screen.isNotEmpty) {
      return {'expectScreen': after.screen, 'expectTimeoutMs': '8000'};
    }
    if (before.viewSignature != after.viewSignature &&
        after.viewSignature.isNotEmpty) {
      return {'expectView': after.viewSignature, 'expectTimeoutMs': '8000'};
    }
    final newText = after.visibleText.toSet()
      ..removeAll(before.visibleText.toSet());
    final salient = _recordSalientText(newText);
    if (salient != null) {
      return {'expectText': salient, 'expectTimeoutMs': '8000'};
    }
    return const {};
  }

  String? _recordSalientText(Set<String> candidates) {
    String? best;
    for (final text in candidates) {
      final trimmed = text.trim();
      // Skip empties and long paragraphs; a short label makes a stable gate.
      if (trimmed.isEmpty || trimmed.length > 40) continue;
      if (best == null || trimmed.length < best.length) best = trimmed;
    }
    return best;
  }

  void _recordEmitStep(Map<String, String> step) {
    step['_recordedAt'] = DateTime.now().toUtc().toIso8601String();
    // Stamp the pending dwell on the first step of a commit (a replay floor for
    // undetectable loads); later steps in the same burst are contiguous.
    if (_recordPendingDwellMs > 0) {
      step['_dwellMs'] = '$_recordPendingDwellMs';
      _recordPendingDwellMs = 0;
    }
    _recordSteps.add(step);
    _bumpRecordRevision();
  }

  // ---- flow JSON + persistence -----------------------------------------

  /// The public (VM-param) view of a step: strips `_`-prefixed recorder
  /// metadata so it dispatches cleanly, and masks redacted values.
  Map<String, String> _recordPublicStep(Map<String, String> step) {
    final out = <String, String>{};
    for (final entry in step.entries) {
      if (entry.key.startsWith('_')) continue;
      out[entry.key] = entry.value;
    }
    return out;
  }

  Map<String, Object?> _recordFlowJson() {
    final now = DateTime.now().toUtc();
    final created = (_recordStartedAt ?? now).toUtc();
    final flow = <String, Object?>{
      'schemaVersion': 1,
      'name': _recordName,
      'feature': _recordFeature,
      if (_recordTitle != null) 'title': _recordTitle,
      'createdAt': created.toIso8601String(),
      'updatedAt': now.toIso8601String(),
      'revision': 1,
      'instance': _scoutInstanceLabel.isEmpty ? null : _scoutInstanceLabel,
      'startScreen': _recordStartScreen,
      'stepCount': _recordSteps.length,
      'steps': [
        for (final step in _recordSteps) Map<String, String>.from(step),
      ],
      ..._recordArtifactMetadata(created),
    };
    return _recordFlowForPersistence(flow);
  }

  Map<String, Object?> _recordStatusJson() {
    return {
      'recording': _recording,
      'paused': _recordPaused,
      if (_recordName != null) 'name': _recordName,
      if (_recordFeature != null) 'feature': _recordFeature,
      if (_recordTitle != null) 'title': _recordTitle,
      if (_recordStartScreen != null) 'startScreen': _recordStartScreen,
      'stepCount': _recordSteps.length,
      if (_recordSteps.isNotEmpty)
        'lastStep': _recordStepSummary(_recordSteps.last),
    };
  }

  String _recordStepSummary(Map<String, String> step) {
    final cmd = step['cmd'] ?? '?';
    final subject =
        step['target'] ??
        step['direction'] ??
        (step['x'] != null ? '${step['x']},${step['y']}' : '');
    return subject.isEmpty ? cmd : '$cmd $subject';
  }

  Map<String, Object?> _recordArtifactMetadata(DateTime createdAt) => {
    'dataClassification': _kRecordDataClassification,
    'containsPrivateApplicationData': true,
    'retentionPolicy': {
      'policy': 'manual',
      'createdAt': createdAt.toUtc().toIso8601String(),
      'disposition': 'explicit_manual_deletion',
    },
    'telemetryCollected': false,
  };

  /// The helper only writes where it can enforce the complete private-storage
  /// contract. Mobile sandboxes and Windows are deliberately delegated to the
  /// CLI, which always receives [flow] from `_stopRecording` and persists it
  /// using its own platform storage implementation.
  bool get _recordHelperCanGuaranteePrivateStorage =>
      Platform.isMacOS || (Platform.isLinux && !Platform.isAndroid);

  _RecordingStoreLocation _recordingStoreLocation() {
    if (!_recordHelperCanGuaranteePrivateStorage) {
      throw const _RecordingStorageFailure(
        'helper_private_storage_unsupported_platform',
      );
    }
    final override = _recordRootOverride;
    if (override != null) {
      final root = _recordNormalizeAbsolutePath(override);
      final boundary = _recordParentPath(root);
      if (root == '/' || root == boundary) {
        throw const _RecordingStorageFailure('unsafe_recording_root');
      }
      _recordRequireTrustedBoundary(boundary);
      return _RecordingStoreLocation(boundary: boundary, root: root);
    }
    final rawProject = FlutterScoutRuntime._recordProjectDefine.isNotEmpty
        ? FlutterScoutRuntime._recordProjectDefine
        : Directory.current.path;
    if (rawProject.isEmpty) {
      throw const _RecordingStorageFailure('recording_project_path_missing');
    }
    final project = _recordNormalizeAbsolutePath(rawProject);
    if (project == '/') {
      throw const _RecordingStorageFailure('unsafe_recording_root');
    }
    _recordRequireTrustedBoundary(project);
    return _RecordingStoreLocation(
      boundary: project,
      root: '$project/.flutter_scout/recordings',
    );
  }

  String _recordNormalizeAbsolutePath(String raw) {
    if (!raw.startsWith('/') || raw.contains('\u0000')) {
      throw const _RecordingStorageFailure('unsafe_recording_root');
    }
    final parts = <String>[];
    for (final part in raw.split('/')) {
      if (part.isEmpty) continue;
      if (part == '.' || part == '..' || _recordHasControlCharacters(part)) {
        throw const _RecordingStorageFailure('unsafe_recording_root');
      }
      parts.add(part);
    }
    return parts.isEmpty ? '/' : '/${parts.join('/')}';
  }

  bool _recordHasControlCharacters(String value) {
    for (final unit in value.codeUnits) {
      if (unit < 0x20 || unit == 0x7f) return true;
    }
    return false;
  }

  void _recordRequireTrustedBoundary(String boundary) {
    final type = FileSystemEntity.typeSync(boundary, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw const _RecordingStorageFailure('recording_symbolic_link_refused');
    }
    if (type != FileSystemEntityType.directory) {
      throw const _RecordingStorageFailure('recording_boundary_unavailable');
    }
  }

  String _recordParentPath(String path) {
    final slash = path.lastIndexOf('/');
    if (slash <= 0) return '/';
    return path.substring(0, slash);
  }

  String _recordBaseName(String path) {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  List<String> _recordManagedPaths(String boundary, String target) {
    final root = _recordNormalizeAbsolutePath(boundary);
    final value = _recordNormalizeAbsolutePath(target);
    final inside = root == '/'
        ? value.startsWith('/')
        : value.startsWith('$root/');
    if (value != root && !inside) {
      throw const _RecordingStorageFailure('recording_path_escaped_root');
    }
    if (value == root) return <String>[root];
    final relative = root == '/'
        ? value.substring(1)
        : value.substring(root.length + 1);
    final paths = <String>[];
    var cursor = root;
    for (final part in relative.split('/')) {
      cursor = cursor == '/' ? '/$part' : '$cursor/$part';
      paths.add(cursor);
    }
    return paths;
  }

  void _recordAssertManagedPath(
    String boundary,
    String target, {
    required bool finalMayBeFile,
    bool allowMissing = true,
  }) {
    final paths = _recordManagedPaths(boundary, target);
    for (var index = 0; index < paths.length; index++) {
      final path = paths[index];
      final isFinal = index == paths.length - 1;
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.notFound && allowMissing) continue;
      if (type == FileSystemEntityType.link) {
        throw const _RecordingStorageFailure('recording_symbolic_link_refused');
      }
      final accepted = isFinal && finalMayBeFile
          ? type == FileSystemEntityType.file
          : type == FileSystemEntityType.directory;
      if (!accepted) {
        throw const _RecordingStorageFailure(
          'recording_unexpected_filesystem_object',
        );
      }
    }
  }

  void _recordEnforceMode(String path, int mode) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.link) {
      throw const _RecordingStorageFailure('recording_symbolic_link_refused');
    }
    final current = FileStat.statSync(path).mode & 0x1ff;
    if (current == mode) return;
    final symbolic = mode == _kRecordPrivateDirectoryMode ? '700' : '600';
    final result = Process.runSync('/bin/chmod', <String>[symbolic, path]);
    if (result.exitCode != 0 ||
        (FileStat.statSync(path).mode & 0x1ff) != mode) {
      throw const _RecordingStorageFailure(
        'recording_private_permissions_unavailable',
      );
    }
  }

  void _recordEnsurePrivateDirectory(String path, {required String boundary}) {
    _recordAssertManagedPath(boundary, path, finalMayBeFile: false);
    Directory(path).createSync(recursive: true);
    _recordAssertManagedPath(
      boundary,
      path,
      finalMayBeFile: false,
      allowMissing: false,
    );
    for (final managed in _recordManagedPaths(boundary, path)) {
      _recordEnforceMode(managed, _kRecordPrivateDirectoryMode);
    }
  }

  void _recordSecureExistingStore(String root, {required String boundary}) {
    _recordEnsurePrivateDirectory(root, boundary: boundary);
    var count = 0;
    for (final entity in Directory(
      root,
    ).listSync(recursive: true, followLinks: false)) {
      if (++count > _kRecordMaximumScanEntries) {
        throw const _RecordingStorageFailure('recording_store_scan_limit');
      }
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw const _RecordingStorageFailure('recording_symbolic_link_refused');
      }
      if (type == FileSystemEntityType.directory) {
        _recordEnforceMode(entity.path, _kRecordPrivateDirectoryMode);
      } else if (type == FileSystemEntityType.file) {
        _recordEnforceMode(entity.path, _kRecordPrivateFileMode);
      } else if (type != FileSystemEntityType.notFound) {
        throw const _RecordingStorageFailure(
          'recording_unexpected_filesystem_object',
        );
      }
    }
  }

  void _recordAssertPrivateFile(
    String path, {
    required String boundary,
    bool allowMissing = true,
  }) {
    _recordAssertManagedPath(
      boundary,
      path,
      finalMayBeFile: true,
      allowMissing: allowMissing,
    );
  }

  void _recordSecurePrivateFile(String path, {required String boundary}) {
    _recordAssertPrivateFile(path, boundary: boundary, allowMissing: false);
    _recordEnforceMode(path, _kRecordPrivateFileMode);
  }

  void _recordAtomicWriteJson(
    String path,
    Object? value, {
    required String boundary,
  }) {
    final parent = _recordParentPath(path);
    _recordEnsurePrivateDirectory(parent, boundary: boundary);
    _recordAssertPrivateFile(path, boundary: boundary);
    final bytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(value),
    );
    if (bytes.length > _kRecordMaximumArtifactBytes) {
      throw const _RecordingStorageFailure('recording_artifact_size_limit');
    }
    final temporaryPath =
        '$parent/.${_recordBaseName(path)}.$pid.'
        '${DateTime.now().microsecondsSinceEpoch}.'
        '${math.Random.secure().nextInt(0x7fffffff)}.tmp';
    _recordAssertPrivateFile(temporaryPath, boundary: boundary);
    final temporary = File(temporaryPath);
    RandomAccessFile? handle;
    try {
      temporary.createSync(exclusive: true);
      _recordSecurePrivateFile(temporaryPath, boundary: boundary);
      handle = temporary.openSync(mode: FileMode.write);
      handle.writeFromSync(bytes);
      handle.flushSync();
      handle.closeSync();
      handle = null;

      // The private parent prevents an untrusted user racing this final check.
      // Revalidating still catches accidental or same-owner link replacement.
      _recordAssertPrivateFile(path, boundary: boundary);
      temporary.renameSync(path);
      _recordSecurePrivateFile(path, boundary: boundary);
    } catch (_) {
      try {
        handle?.closeSync();
      } catch (_) {}
      try {
        if (temporary.existsSync()) temporary.deleteSync();
      } catch (_) {}
      rethrow;
    }
  }

  T _recordWithIndexLock<T>(
    _RecordingStoreLocation location,
    T Function() body,
  ) {
    final lockPath = '${location.root}/index.json.lock';
    _recordEnsurePrivateDirectory(location.root, boundary: location.boundary);
    _recordAssertPrivateFile(lockPath, boundary: location.boundary);
    final lock = File(lockPath);
    if (!lock.existsSync()) {
      try {
        lock.createSync(exclusive: true);
      } on FileSystemException {
        // A cooperative process may have created it between exists and create.
      }
    }
    _recordSecurePrivateFile(lockPath, boundary: location.boundary);
    final handle = lock.openSync(mode: FileMode.append);
    handle.lockSync(FileLock.blockingExclusive);
    try {
      _recordAssertPrivateFile(
        lockPath,
        boundary: location.boundary,
        allowMissing: false,
      );
      return body();
    } finally {
      try {
        handle.unlockSync();
      } finally {
        handle.closeSync();
      }
    }
  }

  Map<String, Object?> _recordFlowForPersistence(Map<String, Object?> flow) {
    final safe = _redactSensitiveMap(flow);
    final rawSteps = safe['steps'];
    if (rawSteps is List) {
      safe['steps'] = <Map<String, Object?>>[
        for (final raw in rawSteps)
          if (raw is Map)
            () {
              final step = <String, Object?>{
                for (final entry in raw.entries)
                  entry.key.toString(): entry.value,
              };
              if (step['cmd'] == 'input') {
                final target = _recordPlaceholderKey(
                  step['target']?.toString() ?? 'input',
                );
                step['value'] = '$_kRecordRedactedPrefix$target';
                step['_redacted'] = 'true';
                step['_redactionPolicy'] = 'source';
              } else if (step['cmd'] == 'fill') {
                final rawValues = step['values'];
                final decodedValues = rawValues is String
                    ? _recordTryDecodeJson(rawValues)
                    : rawValues;
                if (decodedValues is Map) {
                  step['values'] = <String, String>{
                    for (final key in decodedValues.keys)
                      key.toString():
                          '$_kRecordRedactedPrefix${_recordPlaceholderKey(key.toString())}',
                  };
                } else {
                  step['values'] = '${_kRecordRedactedPrefix}fill.values';
                }
                step['_redacted'] = 'true';
                step['_redactionPolicy'] = 'source';
              }
              return step;
            }(),
      ];
      safe['stepCount'] = (safe['steps'] as List).length;
    }
    final created =
        DateTime.tryParse(safe['createdAt']?.toString() ?? '')?.toUtc() ??
        DateTime.now().toUtc();
    safe.addAll(_recordArtifactMetadata(created));
    return safe;
  }

  Object? _recordTryDecodeJson(String value) {
    try {
      return jsonDecode(value);
    } catch (_) {
      return value;
    }
  }

  String _recordPlaceholderKey(String raw) {
    final buffer = StringBuffer();
    for (final unit in raw.codeUnits) {
      if (unit < 0x20 || unit == 0x7f || unit == 0x3d) {
        buffer.write('_');
      } else {
        buffer.writeCharCode(unit);
      }
    }
    final normalized = buffer.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return 'value';
    return normalized.length <= 120 ? normalized : normalized.substring(0, 120);
  }

  void _recordValidateSegment(String value) {
    if (!_kRecordStorageSegment.hasMatch(value)) {
      throw const _RecordingStorageFailure('recording_invalid_storage_segment');
    }
  }

  Future<_RecordingWriteResult> _writeRecordingToDisk(
    String feature,
    String name,
    Map<String, Object?> flow,
  ) async {
    try {
      _recordValidateSegment(feature);
      _recordValidateSegment(name);
      final location = _recordingStoreLocation();
      return _recordWithIndexLock(location, () {
        _recordSecureExistingStore(location.root, boundary: location.boundary);
        final directory = '${location.root}/$feature';
        _recordEnsurePrivateDirectory(directory, boundary: location.boundary);
        final path = '$directory/$name.json';
        _recordAtomicWriteJson(
          path,
          _recordFlowForPersistence(flow),
          boundary: location.boundary,
        );
        _writeRecordingsIndex(location);
        return _RecordingWriteResult.persisted(path);
      });
    } on _RecordingStorageFailure catch (error) {
      _recordError(
        type: 'recorder_persistence_delegated',
        message:
            'Helper persistence declined (${error.code}); CLI fallback required.',
      );
      return _RecordingWriteResult.delegated(error.code);
    } catch (_) {
      _recordError(
        type: 'recorder_persistence_delegated',
        message: 'Helper persistence failed; CLI fallback required.',
      );
      return const _RecordingWriteResult.delegated(
        'recording_storage_operation_failed',
      );
    }
  }

  /// Rebuilds recordings/index.json while the cross-process lock is held.
  /// Corrupt flows are excluded with ordered diagnostics. Stale, clearly-owned
  /// atomic temp files are removed after 24 hours; newer temps are left alone
  /// because another process may still be committing them.
  void _writeRecordingsIndex(_RecordingStoreLocation location) {
    final rows = <Map<String, Object?>>[];
    final ignored = <Map<String, Object?>>[];
    final now = DateTime.now().toUtc();
    final rootDir = Directory(location.root);
    var scanned = 0;
    for (final entity in rootDir.listSync(followLinks: false)) {
      if (++scanned > _kRecordMaximumScanEntries) {
        throw const _RecordingStorageFailure('recording_store_scan_limit');
      }
      final rootType = FileSystemEntity.typeSync(
        entity.path,
        followLinks: false,
      );
      if (rootType == FileSystemEntityType.link) {
        throw const _RecordingStorageFailure('recording_symbolic_link_refused');
      }
      if (rootType == FileSystemEntityType.file) {
        final basename = _recordBaseName(entity.path);
        if (_recordHandleOwnedTemporary(
          File(entity.path),
          relativePath: 'recordings/$basename',
          now: now,
          ignored: ignored,
        )) {
          continue;
        }
        if (basename != 'index.json' && basename != 'index.json.lock') {
          ignored.add({
            'path': 'recordings/$basename',
            'reason': 'unexpected_root_artifact_excluded',
          });
        }
        continue;
      }
      if (rootType != FileSystemEntityType.directory) continue;
      final feature = _recordBaseName(entity.path);
      if (!_kRecordStorageSegment.hasMatch(feature)) {
        ignored.add({
          'path': 'recordings/$feature',
          'reason': 'invalid_feature_directory',
        });
        continue;
      }
      for (final child in Directory(entity.path).listSync(followLinks: false)) {
        if (++scanned > _kRecordMaximumScanEntries) {
          throw const _RecordingStorageFailure('recording_store_scan_limit');
        }
        final type = FileSystemEntity.typeSync(child.path, followLinks: false);
        if (type == FileSystemEntityType.link) {
          throw const _RecordingStorageFailure(
            'recording_symbolic_link_refused',
          );
        }
        if (type != FileSystemEntityType.file) continue;
        final basename = _recordBaseName(child.path);
        if (_recordHandleOwnedTemporary(
          File(child.path),
          relativePath: 'recordings/$feature/$basename',
          now: now,
          ignored: ignored,
        )) {
          continue;
        }
        if (!basename.endsWith('.json') || basename.startsWith('.')) continue;
        final expectedName = basename.substring(0, basename.length - 5);
        if (!_kRecordStorageSegment.hasMatch(expectedName)) {
          ignored.add({
            'path': 'recordings/$feature/$basename',
            'reason': 'invalid_recording_filename',
          });
          continue;
        }
        try {
          if (FileStat.statSync(child.path).size >
              _kRecordMaximumArtifactBytes) {
            throw const FormatException('flow exceeds storage limit');
          }
          final decoded = jsonDecode(File(child.path).readAsStringSync());
          if (decoded is! Map || decoded['steps'] is! List) {
            throw const FormatException('invalid flow shape');
          }
          final rawFlow = <String, Object?>{
            for (final entry in decoded.entries)
              entry.key.toString(): entry.value,
          };
          if (rawFlow['name']?.toString() != expectedName ||
              rawFlow['feature']?.toString() != feature) {
            throw const FormatException('flow identity mismatch');
          }
          final safeFlow = _recordFlowForPersistence(rawFlow);
          final originalJson = const JsonEncoder.withIndent(
            '  ',
          ).convert(rawFlow);
          final safeJson = const JsonEncoder.withIndent('  ').convert(safeFlow);
          if (originalJson != safeJson) {
            _recordAtomicWriteJson(
              child.path,
              safeFlow,
              boundary: location.boundary,
            );
          }
          rows.add({
            'name': safeFlow['name'],
            'feature': feature,
            if (safeFlow['title'] != null) 'title': safeFlow['title'],
            'path': 'recordings/$feature/$basename',
            'stepCount': safeFlow['stepCount'] ?? 0,
            'revision': safeFlow['revision'] ?? 1,
            'updatedAt': safeFlow['updatedAt'],
            'startScreen': safeFlow['startScreen'],
            'dataClassification': _kRecordDataClassification,
            'containsPrivateApplicationData': true,
          });
        } catch (_) {
          ignored.add({
            'path': 'recordings/$feature/$basename',
            'reason': 'corrupt_or_incompatible_recording_excluded',
          });
        }
      }
    }
    rows.sort((a, b) {
      final f = (a['feature'] ?? '').toString().compareTo(
        (b['feature'] ?? '').toString(),
      );
      if (f != 0) return f;
      return (a['name'] ?? '').toString().compareTo(
        (b['name'] ?? '').toString(),
      );
    });
    ignored.sort(
      (a, b) =>
          (a['path'] ?? '').toString().compareTo((b['path'] ?? '').toString()),
    );
    final index = <String, Object?>{
      'schemaVersion': 1,
      'updatedAt': now.toIso8601String(),
      'recordings': rows,
      if (ignored.isNotEmpty) 'ignoredArtifacts': ignored,
      ..._recordArtifactMetadata(now),
    };
    _recordAtomicWriteJson(
      '${location.root}/index.json',
      index,
      boundary: location.boundary,
    );
  }

  bool _recordHandleOwnedTemporary(
    File file, {
    required String relativePath,
    required DateTime now,
    required List<Map<String, Object?>> ignored,
  }) {
    if (!_kRecordOwnedTemporaryName.hasMatch(_recordBaseName(file.path))) {
      return false;
    }
    final modified = FileStat.statSync(file.path).modified.toUtc();
    if (now.difference(modified) >= _kRecordStaleTemporaryAge) {
      file.deleteSync();
      ignored.add({
        'path': relativePath,
        'reason': 'stale_atomic_temporary_removed',
      });
    } else {
      ignored.add({
        'path': relativePath,
        'reason': 'active_atomic_temporary_ignored',
      });
    }
    return true;
  }

  // ---- VM service extension --------------------------------------------

  Future<developer.ServiceExtensionResponse> _handleRecord(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final action = params['action'] ?? 'status';
      switch (action) {
        case 'start':
          _markRequestPhaseUnavailable(
            'match',
            'not_applicable:recording_tool_state_mutation_has_no_widget_selector',
          );
          final started = _startRecording(
            name: params['name'],
            feature: params['feature'],
            title: params['title'],
          );
          if (started['ok'] == true) await _settleMutationFrames();
          return _ok(started);
        case 'stop':
          _markRequestPhaseUnavailable(
            'match',
            'not_applicable:recording_tool_state_mutation_has_no_widget_selector',
          );
          final stopped = await _stopRecording(
            discard: params['discard'] == 'true',
          );
          if (stopped['ok'] == true) await _settleMutationFrames();
          return _ok(stopped);
        case 'pause':
          _markRequestPhaseUnavailable(
            'match',
            'not_applicable:recording_tool_state_mutation_has_no_widget_selector',
          );
          _pauseRecording();
          await _settleMutationFrames();
          return _ok({'ok': true, ..._recordStatusJson()});
        case 'resume':
          _markRequestPhaseUnavailable(
            'match',
            'not_applicable:recording_tool_state_mutation_has_no_widget_selector',
          );
          _resumeRecording();
          await _settleMutationFrames();
          return _ok({'ok': true, ..._recordStatusJson()});
        case 'undo':
          _markRequestPhaseUnavailable(
            'match',
            'not_applicable:recording_tool_state_mutation_has_no_widget_selector',
          );
          final undone = _undoLastStep();
          await _settleMutationFrames();
          return _ok(undone);
        case 'status':
          return _ok({
            ..._recordStatusJson(),
            'observationEffects': _observationEffects(
              _FrameAdvancePolicy.observeOnly,
            ),
          });
        case 'steps':
          return _ok({
            ..._recordStatusJson(),
            'observationEffects': _observationEffects(
              _FrameAdvancePolicy.observeOnly,
            ),
            'steps': [
              for (final step in _recordSteps) Map<String, String>.from(step),
            ],
          });
        default:
          return _fail('unknown_record_action', 'action=$action');
      }
    } catch (error) {
      return _fail('record_failed', error.toString());
    }
  }
}
