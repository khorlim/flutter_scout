import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:crypto/crypto.dart' as crypto;

import 'icon_names.g.dart';

part 'scout_design.dart';
part 'annotation_overlay.dart';
part 'models.dart';
part 'runtime_annotations.dart';
part 'runtime_actions.dart';
part 'runtime_privacy.dart';
part 'runtime_timings.dart';
part 'runtime_typed_methods.dart';
part 'runtime_protocol.dart';
part 'runtime_resolution.dart';
part 'runtime_navigation.dart';
part 'runtime_snapshot.dart';
part 'runtime_nodes.dart';
part 'runtime_internals.dart';
part 'runtime_recorder.dart';

/// Protocol version reported in every helper response, so the CLI can tell
/// when the RUNNING helper is older than the one it expects — the classic
/// git-dependency trap where editing pub-cache source and hot reloading
/// silently keeps executing old code. Bump when the CLI starts depending on
/// new helper behavior; keep in sync with the CLI's
/// `_expectedHelperProtocolVersion`.
const int scoutHelperProtocolVersion = 15;
const int scoutHelperMinSupportedProtocolVersion = 15;
const int scoutHelperMaxSupportedProtocolVersion = 15;
const int scoutHelperSchemaVersion = 1;
const String scoutHelperPackageVersion = '0.2.0-dev.1';

class FlutterScoutBinding {
  FlutterScoutBinding._();

  static void ensureInitialized() {
    // The helper must be a true no-op outside debug, including not choosing or
    // initializing the application's binding as a side effect.
    if (!kDebugMode) return;
    WidgetsFlutterBinding.ensureInitialized();
    FlutterScoutHelper.ensureRegistered();
  }
}

class FlutterScoutHelper {
  FlutterScoutHelper._();

  static bool _registered = false;
  static final FlutterScoutRuntime _runtime = FlutterScoutRuntime();

  static void ensureRegistered() {
    // Scout is a debug-only tool. Bail outside debug so nothing it does — VM
    // service extensions, error-handler hooks, the overlay — is wired into a
    // profile or release build. (Matches the kDebugMode guards in
    // _broadcastVmUri and the overlay install.)
    if (!kDebugMode || _registered) return;
    _registered = true;
    _runtime.install();
  }

  @visibleForTesting
  static FlutterScoutRuntime get debugRuntime => _runtime;
}

class FlutterScoutRuntime {
  static const String _compiledRunId = String.fromEnvironment(
    'FLUTTER_SCOUT_RUN_ID',
  );

  final List<Map<String, Object?>> _errors = <Map<String, Object?>>[];
  final List<ScoutAnnotation> _annotations = <ScoutAnnotation>[];
  final ValueNotifier<int> _annotationRevision = ValueNotifier<int>(0);
  final DateTime _installedAt = DateTime.now();
  late final String _runtimeInstanceId =
      '${_installedAt.microsecondsSinceEpoch}-${identityHashCode(this)}';
  late final int _sensitiveValueSalt = math.Random.secure().nextInt(0x7fffffff);
  final Set<String> _knownSensitiveValues = <String>{};
  int _knownSensitiveValueBytes = 0;
  List<String>? _knownSensitiveValuesByLength;
  bool _sensitiveValueCapacityExceeded = false;
  Object? _lastSensitiveTreeScanRequestContext;
  bool _sensitiveTreeScanInProgress = false;
  final LinkedHashMap<String, _MutationRecord> _mutationRecords =
      LinkedHashMap<String, _MutationRecord>();
  Future<void> _mutationTail = Future<void>.value();
  String? _boundRunId = _compiledRunId.isEmpty ? null : _compiledRunId;
  String? _lastStateDigest;
  int _stateGeneration = 0;
  int _errorCursor = 0;
  // Runtime-error events remain cursor-addressed and immutable. This map is a
  // separate current-state view for blocking error surfaces that remain
  // visible across requests, so they are not falsely reported as either new
  // action-caused errors or a clean runtime.
  final Map<String, int> _activeVisibleErrorSignalCursors = <String, int>{};
  bool _observingStateForResponse = false;
  // Test-only fault gate for proving that stability never invents a result
  // when semantic observation is unavailable. Production keeps this true.
  bool _stabilityObservationEnabled = true;
  // Incremented only when Scout itself advances the Flutter pipeline. This is
  // exposed to tests so observation commands can prove they never reach the
  // mutation-settling machinery, including while engine frames are disabled.
  int _manualMutationFrameAdvanceCount = 0;
  int _nextSyntheticPointer = 1000000;
  int _nextAnnotationId = 1;
  int _annotationHandoffSeq = 0;
  // Logical bounds currently being rasterised. The overlay omits its chrome
  // (scrim/outlines/pins) *inside* these rects so captures stay clean — without
  // blanking the whole overlay, which caused a visible flash on save. A list so
  // overlapping captures compose; entries are added/removed by _captureRegion.
  final List<Rect> _captureClearRects = <Rect>[];
  bool _annotationMode = false;
  // ---- Flow recorder (see runtime_recorder.dart) -------------------------
  // Whether a recording is in progress, and whether it is temporarily paused.
  bool _recording = false;
  bool _recordPaused = false;
  // Buffered steps for the active recording. Each entry is a session.json-shaped
  // record ({cmd, target/x/y, value, expect*}) plus `_`-prefixed metadata; all
  // values are Strings, matching the CLI record invariant so the same
  // replay/batch/export executors run human recordings unchanged.
  final List<Map<String, String>> _recordSteps = <Map<String, String>>[];
  final ValueNotifier<int> _recordRevision = ValueNotifier<int>(0);
  // Active-recording metadata.
  String? _recordName;
  String? _recordFeature;
  String? _recordTitle;
  DateTime? _recordStartedAt;
  String? _recordStartScreen;
  // Per-pointer capture state, keyed by PointerEvent.pointer.
  final Map<int, _RecordPointer> _recordPointers = <int, _RecordPointer>{};
  // Baseline snapshot (last committed step's after-state, or the record-start
  // state) used to diff field edits and derive per-step assertions.
  ScoutSnapshot? _recordBaseline;
  bool _recordRouteInstalled = false;
  int _recordAutoNameSeq = 0;
  // Gesture commits run one at a time on this tail so their settle waits (which
  // can span a load) never interleave and race the shared baseline.
  Future<void> _recordCommitTail = Future<void>.value();
  // Wall-clock of the last recorded action, used to stamp per-step dwell (the
  // human's pause before this action) as a replay pacing floor.
  DateTime? _recordLastActionAt;
  int _recordPendingDwellMs = 0;
  // How long each step's after-state may take to settle before its assertion is
  // captured: [_recordSettleMs] waits for the tree to go quiet, [_recordLateMs]
  // then polls for a late-arriving change (async load). Tests set these to 0.
  int _recordSettleMs = 1500;
  int _recordLateMs = 1200;
  // Absolute path to the app project (so the helper writes recordings straight
  // to <project>/.flutter_scout/recordings/). Injected by the CLI at launch;
  // falls back to the process cwd on desktop.
  static const String _recordProjectDefine = String.fromEnvironment(
    'FLUTTER_SCOUT_PROJECT',
  );
  // Test-only override for the recordings root (real runs use the project path).
  String? _recordRootOverride;
  // True only while collecting annotation targets. The overlay's full-screen
  // absorber goes hit-test-transparent during this window so the global hit
  // test reaches the app and returns the real topmost (occlusion-aware) path,
  // instead of us falling back to a per-target self hit test that can't see
  // Stack siblings painted on top.
  bool _collectingAnnotationTargets = false;
  // Depth of synthetic (agent-dispatched) gestures currently in flight. While
  // positive, ALL Scout chrome (annotation FAB, instance badge, absorber,
  // pins) is hit-test-transparent, so an agent tap lands on the app control
  // beneath instead of silently activating Scout's own UI. Human taps are
  // unaffected. A counter, not a bool, so overlapping dispatches compose.
  int _syntheticGestureDepth = 0;
  _HeldDragState? _heldDrag;
  Timer? _heldDragExpiry;

  /// Whether Scout's overlay chrome should be invisible to hit testing right
  /// now — during annotation-target collection and agent gesture dispatch.
  bool get _scoutChromeHitTransparent =>
      _collectingAnnotationTargets || _syntheticGestureDepth > 0;
  OverlayEntry? _annotationOverlayEntry;
  // The OverlayState the entry was inserted into. State.mounted is the
  // reliable liveness signal — OverlayEntry.mounted can stay stale when the
  // host Overlay is disposed without removing its entries.
  OverlayState? _annotationOverlayHost;
  bool _annotationOverlayInstallScheduled = false;
  // Interactive overlay chrome remains explicit opt-in. A Scout-owned launch
  // may still install its passive, pointer-transparent session badge so humans
  // can distinguish concurrent agent windows without changing app semantics.
  bool _annotationOverlayOptedIn = false;
  bool? _debugLaunchBadgeVisible;
  bool _debugForceOverlayInteractive = false;
  FlutterExceptionHandler? _previousFlutterError;
  ui.ErrorCallback? _previousPlatformError;

  /// Test-only fault injector, invoked for every element the snapshot walk
  /// visits. Lets tests prove that a throwing element degrades only itself
  /// (see [ScoutSnapshot.degradedNodes]) instead of failing the whole inspect.
  @visibleForTesting
  void Function(Element element)? debugSnapshotNodeProbe;

  /// Test-only capture-backend fault injector. The production backend probe
  /// calls this at its normal failure boundary so tests can prove that capture
  /// loss remains local to pixel evidence while the widget snapshot survives.
  @visibleForTesting
  void Function()? debugCaptureBackendProbe;

  /// Test-only runtime-liveness seam for the bounded stability observer.
  /// Production observes root-element availability directly.
  @visibleForTesting
  bool Function()? debugRuntimeAvailabilityProbe;

  void install() {
    _installErrorHooks();
    _registerExtension('ext.flutter_scout.inspect', _handleNavigationInspect);
    _registerExtension('ext.flutter_scout.reveal', _handleReveal);
    _registerExtension('ext.flutter_scout.annotations', _handleAnnotations);
    _registerExtension('ext.flutter_scout.capture', _handleCapture);
    _registerExtension('ext.flutter_scout.tap', _handleTap);
    _registerExtension('ext.flutter_scout.tapText', _handleTapText);
    _registerExtension('ext.flutter_scout.longPress', _handleLongPress);
    _registerExtension('ext.flutter_scout.input', _handleInput);
    _registerExtension('ext.flutter_scout.fill', _handleFill);
    _registerExtension('ext.flutter_scout.scroll', _handleScroll);
    _registerExtension('ext.flutter_scout.scrollTo', _handleScrollTo);
    _registerExtension('ext.flutter_scout.swipe', _handleSwipe);
    _registerExtension('ext.flutter_scout.dragStart', _handleDragStart);
    _registerExtension('ext.flutter_scout.dragMove', _handleDragMove);
    _registerExtension('ext.flutter_scout.dragEnd', _handleDragEnd);
    _registerExtension('ext.flutter_scout.dragCancel', _handleDragCancel);
    _registerExtension('ext.flutter_scout.dragStatus', _handleDragStatus);
    _registerExtension('ext.flutter_scout.back', _handleBack);
    _registerExtension('ext.flutter_scout.waitStable', _handleWaitStable);
    _registerExtension('ext.flutter_scout.waitFor', _handleWaitFor);
    _registerExtension('ext.flutter_scout.dismiss', _handleDismiss);
    _registerExtension('ext.flutter_scout.record', _handleRecord);
    _installRecorderRoute();
    _broadcastVmUri();
    _reconcileAnnotationOverlay();
  }

  int get _activeAnnotationCount =>
      _annotations.where((annotation) => annotation.isActive).length;

  @visibleForTesting
  List<ScoutAnnotation> get debugAnnotations => _annotations;

  @visibleForTesting
  int get debugHandoffSeq => _annotationHandoffSeq;

  @visibleForTesting
  void debugSignalHandoff() => _signalAnnotationHandoff();

  @visibleForTesting
  Future<Uint8List?> debugCaptureRegion({
    Rect? rect,
    double padding = 12,
    List<({int n, Rect rect})>? marks,
  }) async {
    final result = await _captureRegion(
      rect: rect,
      padding: padding,
      marks: marks,
    );
    return result.bytes;
  }

  @visibleForTesting
  Future<void> debugCaptureAnnotationCrop(
    ScoutAnnotation annotation, {
    required String slot,
  }) {
    return _captureAnnotationCrop(annotation, slot: slot);
  }

  @visibleForTesting
  bool debugMarkFixed(String id) =>
      _updateAnnotationStatus(id: id, status: 'pending_review');

  @visibleForTesting
  void debugSetAnnotationMode(bool enabled) {
    if (!enabled) _debugForceOverlayInteractive = false;
    _setAnnotationMode(enabled);
  }

  /// In-app Record toggle entry point (used by the launcher menu) and test hooks
  /// for the flow recorder; the implementation lives in runtime_recorder.dart.
  Future<Map<String, Object?>> toggleRecording() => _toggleRecording();

  @visibleForTesting
  Map<String, Object?> debugStartRecording({String? name, String? feature}) =>
      _startRecording(name: name, feature: feature);

  @visibleForTesting
  Future<Map<String, Object?>> debugStopRecording({bool discard = false}) =>
      _stopRecording(discard: discard);

  @visibleForTesting
  List<Map<String, String>> get debugRecordSteps => [
    for (final s in _recordSteps) Map<String, String>.from(s),
  ];

  @visibleForTesting
  bool get debugIsRecording => _recording;

  @visibleForTesting
  void debugSetRecordingsRootOverride(String? path) =>
      _recordRootOverride = path;

  /// Test-only: collapse the per-step settle waits (fake-async can't advance the
  /// wall-clock deadlines in `_waitStable`), so the recorder captures the
  /// current frame without real delays.
  @visibleForTesting
  void debugSetRecordSettleMs(int settle, int late) {
    _recordSettleMs = settle;
    _recordLateMs = late;
  }

  /// Test-only explicit UI opt-in. Tests rebuild the tree per case, so this
  /// also re-homes a stale entry before asserting on launcher/menu chrome.
  @visibleForTesting
  void debugEnsureOverlayInstalled() {
    _annotationOverlayOptedIn = true;
    _debugForceOverlayInteractive = true;
    _scheduleAnnotationOverlayInstall(forceForTesting: true);
  }

  /// Test-only launch-context seam. Production derives this from the
  /// `FLUTTER_SCOUT_RUN_ID` injected only by Scout-owned launches.
  @visibleForTesting
  void debugSetLaunchBadgeVisible(bool? visible) {
    _debugLaunchBadgeVisible = visible;
    _reconcileAnnotationOverlay();
  }

  @visibleForTesting
  bool get debugOverlayInteractive => _annotationOverlayInteractive;

  @visibleForTesting
  bool get debugOverlayInstalled =>
      _annotationOverlayEntry != null &&
      (_annotationOverlayHost?.mounted ?? false);

  @visibleForTesting
  int get debugManualMutationFrameAdvanceCount =>
      _manualMutationFrameAdvanceCount;

  @visibleForTesting
  List<ScoutAnnotationTarget> debugVisibleAnnotationTargets() =>
      visibleAnnotationTargets();

  @visibleForTesting
  ScoutSnapshot debugSnapshot() => _snapshot();

  /// Test-only entry point for the same bounded semantic stability observer
  /// used by actions and `wait stable`.
  @visibleForTesting
  Future<Map<String, Object?>> debugObserveStability({
    int timeoutMs = 500,
    bool Function()? stopWhen,
  }) async {
    final observation = await _waitStable(
      frameAdvancePolicy: _FrameAdvancePolicy.observeOnly,
      timeout: Duration(milliseconds: timeoutMs),
      stopWhen: stopWhen,
    );
    return <String, Object?>{
      'stable': observation.stable,
      'stability': observation.toJson(),
      'timings': <String, Object?>{'settleMs': observation.elapsedMs},
      'observationEffects': _observationEffects(
        _FrameAdvancePolicy.observeOnly,
      ),
    };
  }

  @visibleForTesting
  void debugSetStabilityObservationEnabled(bool enabled) {
    _stabilityObservationEnabled = enabled;
  }

  @visibleForTesting
  Future<Map<String, Object?>> debugInspect({bool brief = true}) async {
    final response = await _handleInspect('debugInspect', {'brief': '$brief'});
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  @visibleForTesting
  Future<Map<String, Object?>> debugWhere() async {
    final response = await _handleWhere('debugWhere', const {});
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  @visibleForTesting
  Future<Map<String, Object?>> debugLocate(Map<String, String> params) async {
    final response = await _handleLocate('debugLocate', params);
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  @visibleForTesting
  Future<Map<String, Object?>> debugReveal(Map<String, String> params) async {
    final response = await _handleReveal('debugReveal', params);
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  @visibleForTesting
  Future<Map<String, Object?>> debugInspectSince(String snapshotId) async {
    final response = await _handleInspectSince('debugInspectSince', {
      'since': snapshotId,
    });
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  /// Test/public-debug entry point for the exact helper request used by
  /// `flutter-scout crop --changed-since`. The raster is returned only while
  /// the retained baseline and capture-time snapshot identities remain bound.
  @visibleForTesting
  Future<Map<String, Object?>> debugCaptureChangedSince(
    String snapshotId, {
    double padding = 12,
  }) async {
    final response = await _handleCapture('debugCaptureChangedSince', {
      'mode': 'changed-region',
      'since': snapshotId,
      'padding': '$padding',
    });
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  @visibleForTesting
  Future<Map<String, Object?>> debugWaitStable({int timeoutMs = 250}) async {
    final response = await _handleWaitStable('debugWaitStable', {
      'timeoutMs': '$timeoutMs',
    });
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  @visibleForTesting
  Future<Map<String, Object?>> debugWaitFor(Map<String, String> params) async {
    final response = await _handleWaitFor('debugWaitFor', params);
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  @visibleForTesting
  Future<Map<String, Object?>> debugDragStatus() async {
    final response = await _handleDragStatus('debugDragStatus', const {});
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  @visibleForTesting
  Future<Map<String, Object?>> debugAnnotationsRead({
    String action = 'list',
  }) async {
    assert(action == 'list' || action == 'targets' || action == 'get-crop');
    final response = await _handleAnnotations('debugAnnotationsRead', {
      'action': action,
    });
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  @visibleForTesting
  Future<Map<String, Object?>> debugRecordRead({
    String action = 'status',
  }) async {
    assert(action == 'status' || action == 'steps');
    final response = await _handleRecord('debugRecordRead', {'action': action});
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  /// Test-only transport-equivalent entry points for proving that mixed
  /// read/write subcommands retain truthful request-local phase ownership.
  @visibleForTesting
  Future<Map<String, Object?>> debugProtocolAnnotations(
    Map<String, String> params,
  ) async {
    const method = 'ext.flutter_scout.annotations';
    final response = await _dispatchProtocolRequest(
      extensionName: method,
      method: method,
      params: params,
      callback: _handleAnnotations,
    );
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  @visibleForTesting
  Future<Map<String, Object?>> debugProtocolRecord(
    Map<String, String> params,
  ) async {
    const method = 'ext.flutter_scout.record';
    final response = await _dispatchProtocolRequest(
      extensionName: method,
      method: method,
      params: params,
      callback: _handleRecord,
    );
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  @visibleForTesting
  String get debugRuntimeInstanceId => _runtimeInstanceId;

  @visibleForTesting
  int get debugErrorCursor => _errorCursor;

  /// Exercises the production protocol gate without registering a VM service
  /// extension. Existing action-specific debug hooks intentionally bypass the
  /// gate so their focused widget tests do not need transport boilerplate.
  @visibleForTesting
  Future<Map<String, Object?>> debugProtocolMutation(
    Map<String, String> params,
    FutureOr<Map<String, Object?>> Function() mutation, {
    String method = 'ext.flutter_scout.debugMutation',
  }) async {
    final response = await _dispatchProtocolRequest(
      extensionName: method,
      method: method,
      params: params,
      callback: (_, _) async => _ok(await Future.sync(mutation)),
      mutationOverride: true,
      validateTypedParameters: method != 'ext.flutter_scout.debugMutation',
    );
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  @visibleForTesting
  Future<Map<String, Object?>> debugProtocolRead(
    Map<String, String> params, {
    String method = 'ext.flutter_scout.debugRead',
  }) async {
    final response = await _dispatchProtocolRequest(
      extensionName: method,
      method: method,
      params: params,
      callback: (_, _) async => _ok({'recentErrors': _recentErrors()}),
      mutationOverride: false,
      validateTypedParameters: method != 'ext.flutter_scout.debugRead',
    );
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  @visibleForTesting
  bool debugIsMutationRequest(
    String extensionName,
    Map<String, String> params,
  ) => _isMutatingRequest(extensionName, params);

  @visibleForTesting
  Map<String, Object?> debugProtocolParameterContract() => <String, Object?>{
    'maximumEncodedResponseBytes': _maxProtocolResponseBytes,
    'maximumPayloadDepth': _maxProtocolPayloadDepth,
    'maximumPayloadNodes': _maxProtocolPayloadNodes,
    'requestLimits': <String, Object?>{
      'maximumParameterCount': _maxProtocolRequestParameters,
      'maximumParameterNameUtf8Bytes': _maxProtocolRequestParameterNameBytes,
      'maximumTotalParameterUtf8Bytes': _maxProtocolRequestTotalBytes,
      'defaultMaximumValueUtf8Bytes': _maxProtocolRequestValueBytes,
      'bulkMaximumValueUtf8Bytes': _maxProtocolRequestBulkValueBytes,
      'bulkParameters': _bulkProtocolParameters.toList()..sort(),
      'identifierMaximumUtf8Bytes': const <String, int>{
        'commandId': _maxProtocolCommandIdBytes,
        'runId': _maxProtocolRunIdBytes,
        'runtimeInstanceId': _maxProtocolRuntimeIdBytes,
      },
      'idempotencyKey': const <String, Object?>{
        'minimumLength': 1,
        'maximumLength': 128,
        'allowedPattern': r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$',
      },
    },
    'commonEnvelopeParameters': _commonProtocolParameters.toList()..sort(),
    'commonParameterDescriptors': <String, Object?>{
      for (final entry in _commonHelperParameterContracts.entries)
        entry.key: entry.value.toJson(),
    },
    'methods': _helperTypedMethodCatalog(),
  };

  /// Test-only view of the helper side of the source compatibility contract.
  /// It is intentionally not evidence about a compiled release artifact.
  @visibleForTesting
  Map<String, Object?> debugProtocolCompatibilityContract() =>
      <String, Object?>{
        'schemaVersion': scoutHelperSchemaVersion,
        'protocolVersion': scoutHelperProtocolVersion,
        'minSupportedProtocolVersion': scoutHelperMinSupportedProtocolVersion,
        'maxSupportedProtocolVersion': scoutHelperMaxSupportedProtocolVersion,
        'capabilities': <String, bool>{..._scoutProtocolCapabilities},
        'requiredMutationEnvelopeParameters':
            _requiredMutationEnvelopeParameters.toList()..sort(),
      };

  /// Test-only: resolve the drag origin that `scroll-to` would use.
  @visibleForTesting
  Offset? debugScrollStartFor(String direction, {String? target}) {
    final snapshot = _snapshot();
    final resolution = target == null
        ? null
        : _resolveTarget(snapshot, target, safety: _TargetSafety.identify);
    return _scrollStartFor(
      snapshot,
      direction,
      target: resolution?.isUnique == true ? resolution!.node : null,
    );
  }

  /// Test-only view of the production resolver, including ranked abstention
  /// evidence and the snapshot/run/runtime scope bound to returned handles.
  @visibleForTesting
  Map<String, Object?> debugResolveTarget(
    String target, {
    bool fieldOnly = false,
  }) => _resolveTarget(_snapshot(), target, fieldOnly: fieldOnly).toJson();

  /// Test-only: dispatch a synthetic tap exactly as agent actions do,
  /// including the chrome-transparency window.
  @visibleForTesting
  Future<void> debugDispatchTap(Offset point) => _dispatchTap(point);

  /// Test-only: run a scroll through the same service-extension handler the
  /// CLI uses, so coordinate handling is covered without a simulator.
  @visibleForTesting
  Future<Map<String, Object?>> debugScroll(Map<String, String> params) async {
    final response = await _handleScroll('debugScroll', {
      'waitMs': '0',
      'lateWaitMs': '0',
      ...params,
    });
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  /// Test-only: resolve and dispatch a handle-targeted tap through the same
  /// service-extension handler used by the CLI.
  @visibleForTesting
  Future<Map<String, Object?>> debugTapTarget(String target) async {
    final response = await _handleTap('debugTapTarget', {
      'target': target,
      'waitMs': '0',
      'lateWaitMs': '0',
    });
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  /// Test-only: resolve visible text through the production uniqueness gate and
  /// dispatch only when exactly one safe logical control owns the match.
  @visibleForTesting
  Future<Map<String, Object?>> debugTapTextTarget(
    String text, {
    bool contains = false,
  }) async {
    final response = await _handleTapText('debugTapTextTarget', {
      'text': text,
      'contains': '$contains',
      'waitMs': '0',
      'lateWaitMs': '0',
    });
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  /// Test-only: enter text through the same extension handler used by the CLI.
  @visibleForTesting
  Future<Map<String, Object?>> debugInputTarget(
    String target,
    String value,
  ) async {
    final response = await _handleInput('debugInputTarget', {
      'target': target,
      'value': value,
      'waitMs': '0',
      'lateWaitMs': '0',
    });
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  /// Test-only error injection for privacy and runtime-signal coverage.
  @visibleForTesting
  void debugRecordError(String message) {
    _recordError(type: 'test_error', message: message);
  }

  /// Test-only bounded privacy-state surface.
  @visibleForTesting
  Map<String, Object?> get debugSensitiveValueTracking => <String, Object?>{
    'count': _knownSensitiveValues.length,
    'bytes': _knownSensitiveValueBytes,
    'capacityExceeded': _sensitiveValueCapacityExceeded,
  };

  @visibleForTesting
  void debugRememberSensitiveValue(String value) {
    _rememberSensitiveValue(value);
  }

  @visibleForTesting
  String debugRedactSensitiveText(String value) => _redactSensitiveText(value);

  @visibleForTesting
  void debugResetSensitiveValueTracking() {
    _knownSensitiveValues.clear();
    _knownSensitiveValueBytes = 0;
    _knownSensitiveValuesByLength = null;
    _sensitiveValueCapacityExceeded = false;
    _lastSensitiveTreeScanRequestContext = null;
    _sensitiveTreeScanInProgress = false;
  }

  /// Test-only active non-blocking signal injection. This protects the
  /// distinction between factual active signals and active *blocking* signals.
  @visibleForTesting
  void debugRecordActiveWarning(String message) {
    final warning = _recordError(type: 'test_warning', message: message);
    final cursor = warning['cursor'];
    if (cursor is int) {
      _activeVisibleErrorSignalCursors['debug-warning:$cursor'] = cursor;
    }
  }

  Future<Map<String, Object?>> debugActionCapturePayload() =>
      _withActionCapture(
        const {'capture': 'true'},
        const {'action': 'debug-capture'},
      );

  @visibleForTesting
  Future<Map<String, Object?>> debugTrackAction(
    Future<void> Function() action, {
    int waitMs = 600,
    int lateWaitMs = 600,
    Map<String, String> params = const {},
  }) async {
    final before = _snapshot();
    await action();
    final tracked = await _snapshotAfterAction(before, {
      ...params,
      'waitMs': '$waitMs',
      'lateWaitMs': '$lateWaitMs',
    });
    final changed = _changed(before, tracked.snapshot);
    return {
      'changed': changed,
      'activityObserved': tracked.activityObserved,
      'result': changed
          ? 'changed'
          : tracked.activityObserved
          ? 'completed_same_state'
          : 'activated_no_observed_change',
      'stable': tracked.stable,
      'stability': tracked.stability.toJson(),
      'timings': <String, Object?>{'settleMs': tracked.stability.elapsedMs},
      'delta': _delta(before, tracked.snapshot),
      'waitTimedOut': tracked.waitTimedOut,
      'transientViewSignatures': tracked.transientViewSignatures,
    };
  }

  /// Test-app primitive matching the service-extension held-drag lifecycle.
  @visibleForTesting
  Future<void> debugDragStart(Offset point) async {
    final state = await _beginHeldDrag(point, _snapshot());
    _recordHeldDragSample(state, state.before);
  }

  @visibleForTesting
  Future<void> debugDragMove(Offset point) async {
    final state = _heldDrag;
    if (state == null) throw StateError('No held drag is active.');
    await _moveHeldDrag(point);
    _recordHeldDragSample(state, _snapshot());
  }

  @visibleForTesting
  Future<List<Map<String, Object?>>> debugDragEnd() async {
    final state = await _finishHeldDrag(cancel: false);
    _recordHeldDragSample(state, _snapshot(), phase: 'end');
    return state.path;
  }

  @visibleForTesting
  bool get debugHeldDragActive => _heldDrag != null;

  /// Test-only protocol-gate fixture. Real pointer lifecycle behavior is
  /// covered by [debugDragStart]/[debugDragMove]/[debugDragEnd]; this hook lets
  /// exactly-once tests assert exclusion without leaving a pointer down while
  /// the widget-test fake clock is paused.
  @visibleForTesting
  void debugSetHeldDragGate(bool active) {
    _heldDragExpiry?.cancel();
    _heldDragExpiry = null;
    if (!active) {
      _heldDrag = null;
      return;
    }
    final snapshot = _snapshot();
    _heldDrag = _HeldDragState(
      pointer: -1,
      viewId: _primaryViewId,
      start: Offset.zero,
      position: Offset.zero,
      startedAt: DateTime.now(),
      before: snapshot,
      path: <Map<String, Object?>>[],
    );
  }

  /// Test-only view of wait-for condition evaluation against a snapshot.
  /// [conditions] uses wait-for param names: text, gone, target, selected,
  /// screen, field (`<handle>=<value>`).
  @visibleForTesting
  bool debugWaitForConditionsMet(Map<String, String> conditions) =>
      _waitForConditionsMet(snapshot: _snapshot(), params: conditions);

  /// Test-only: run the explicit post-mutation deferred-frame settler with an
  /// advancing clock on a backgrounded desktop window.
  @visibleForTesting
  Future<void> debugDrainDeferredFrames({
    Duration budget = const Duration(milliseconds: 1500),
  }) => _drainDeferredMutationFrames(budget: budget);

  /// Test-only: the tap-text match id for [text], optionally loose.
  @visibleForTesting
  String? debugTapTextMatchId(String text, {bool loose = false}) =>
      _findVisibleTextMatch(text, loose: loose)?.text.id;

  /// Test-only: compact details for the tap-text match picker.
  @visibleForTesting
  Map<String, Object?>? debugTapTextMatchSummary(
    String text, {
    bool loose = false,
  }) {
    final match = _findVisibleTextMatch(text, loose: loose);
    if (match == null) return null;
    return {
      'textId': match.text.id,
      'textHitTestable': match.text.hitTestable,
      'actionableId': match.actionable?.id,
      'actionableHitTestable': match.actionable?.hitTestable,
      'risk': _tapTextActivationRisk(match),
    };
  }

  /// Test-only: the close control that `dismiss` would tap when no route
  /// pops.
  @visibleForTesting
  String? debugCloseControlId() => _findCloseControl(_snapshot())?.id;

  /// Test-only view of the navigator that owns the current full-view modal.
  @visibleForTesting
  NavigatorState? debugViewportModalNavigator() {
    final root = WidgetsBinding.instance.rootElement;
    return root == null ? null : _findViewportModalNavigator(root);
  }

  /// Test-only view of the tap-text near-match suggestions.
  @visibleForTesting
  List<String> debugTextSuggestions(String query) =>
      _textSuggestions(_snapshot().visibleText, query);

  /// Test-only view of set-of-marks selection (legend + omitted count).
  @visibleForTesting
  ({List<Map<String, Object?>> legend, int omitted}) debugCaptureMarks({
    String filter = 'all',
  }) {
    final built = _buildCaptureMarks(filter: filter);
    return (legend: built.legend, omitted: built.omitted);
  }

  /// Test-only: runs the post-action expectation wait exactly as
  /// tap/tap-text/input/fill do for `expect*` params, returning the decoded
  /// response payload.
  @visibleForTesting
  Future<Map<String, Object?>> debugActionExpectation(
    Map<String, String> params,
  ) async {
    final response = await _respondWithExpectation(params, {
      'action': 'debug',
      'result': 'changed',
    });
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  /// Runs the expectation handler inside the real request/mutation protocol
  /// context so tests can prove that the outer mutation deadline bounds every
  /// inner wait and that failure envelopes retain observed stability/timings.
  @visibleForTesting
  Future<Map<String, Object?>> debugProtocolActionExpectation(
    Map<String, String> params,
  ) async {
    final response = await _dispatchProtocolRequest(
      extensionName: 'ext.flutter_scout.debugExpectation',
      method: 'ext.flutter_scout.debugExpectation',
      params: params,
      callback: (_, requestParams) => _respondWithExpectation(requestParams, {
        'action': 'debug',
        'result': 'changed',
      }),
      mutationOverride: true,
      validateTypedParameters: false,
    );
    return jsonDecode(response.result!) as Map<String, Object?>;
  }

  void _installErrorHooks() {
    _previousFlutterError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      _recordError(
        type: 'flutter_error',
        message: details.exceptionAsString(),
        library: details.library,
      );
      _previousFlutterError?.call(details);
    };

    _previousPlatformError = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      _recordError(type: 'platform_error', message: error.toString());
      return _previousPlatformError?.call(error, stack) ?? false;
    };
  }

  Map<String, Object?> _recordError({
    required String type,
    required String message,
    String? library,
    String? identityQualifier,
  }) {
    _rememberSensitiveValuesFromTree(force: true);
    final timestamp = DateTime.now().toUtc();
    final severity = _errorSeverity(type: type, message: message);
    final sanitizedMessage = _sensitiveValueCapacityExceeded
        ? _kScoutRedacted
        : _redactSensitiveText(message);
    final sanitizedLibrary = library == null
        ? null
        : _sensitiveValueCapacityExceeded
        ? _kScoutRedacted
        : _redactSensitiveText(library);
    final cursor = ++_errorCursor;
    final context = _requestContext;
    final observedDuringRequest = context != null;
    final observedDuringMutation = context == null
        ? null
        : _isMutatingRequest(context.extensionName, context.params);
    final runId = _boundRunId ?? context?.runId;
    final snapshotId = _lastStateDigest == null
        ? null
        : 'g$_stateGeneration:$_lastStateDigest';
    final recorderSignal = type.startsWith('recorder_');
    final error = <String, Object?>{
      'cursor': cursor,
      'errorCursor': cursor,
      'logCursor': null,
      'actionCommandId': context?.commandId,
      'identity': _runtimeSignalIdentity(
        type: type,
        message: identityQualifier == null
            ? sanitizedMessage
            : '$sanitizedMessage|$identityQualifier',
        library: sanitizedLibrary,
      ),
      'type': type,
      'message': sanitizedMessage,
      'timestamp': timestamp.toIso8601String(),
      'severity': severity,
      'blocking': severity == 'blocking',
      'phase': observedDuringRequest
          ? observedDuringMutation == true
                ? 'mutation_request'
                : 'observation_request'
          : timestamp.difference(_installedAt.toUtc()) <
                const Duration(seconds: 10)
          ? 'startup'
          : 'runtime',
      'provenance': <String, Object?>{
        'source': switch (type) {
          'flutter_error' => 'FlutterError.onError',
          'platform_error' => 'PlatformDispatcher.onError',
          'visible_error_surface' => 'flutter_widget_tree',
          _ when recorderSignal => 'flutter_scout_recorder',
          _ => 'flutter_scout_runtime',
        },
        'captureMechanism': switch (type) {
          'flutter_error' => 'framework_error_hook',
          'platform_error' => 'platform_dispatcher_error_hook',
          'visible_error_surface' => 'visible_error_widget_probe',
          _ when recorderSignal => 'guarded_recorder_boundary',
          _ => 'explicit_runtime_report',
        },
        'observedBy': 'flutter_scout_helper',
      },
      'correlation': <String, Object?>{
        'status': observedDuringRequest
            ? 'observed_during_request'
            : 'unattributed_runtime',
        'causalAttribution': 'not_established',
        'commandId': context?.commandId,
        'method': context?.extensionName,
        'requestErrorCursor': context?.errorCursor,
      },
      'runId': runId,
      'runtimeInstanceId': _runtimeInstanceId,
      'stateGeneration': _stateGeneration,
      'snapshotId': snapshotId,
      'stateIdentityStatus': snapshotId == null
          ? 'observation_unavailable'
          : 'last_observed',
    };
    if (sanitizedLibrary != null) {
      error['library'] = sanitizedLibrary;
    }
    _errors.add(error);
    while (_errors.length > 30) {
      final activeCursors = _activeVisibleErrorSignalCursors.values.toSet();
      final removable = _errors.indexWhere(
        (candidate) => !activeCursors.contains(candidate['cursor']),
      );
      if (removable < 0) break;
      _errors.removeAt(removable);
    }
    return error;
  }

  String _errorSeverity({required String type, required String message}) {
    final lower = message.toLowerCase();
    if (type == 'flutter_error' || type == 'visible_error_surface') {
      return 'blocking';
    }
    if (lower.contains('renderflex overflow') ||
        lower.contains('failed assertion') ||
        lower.contains('setstate()') ||
        lower.contains('null check operator used on a null value')) {
      return 'blocking';
    }
    if (lower.contains('httpexception') ||
        lower.contains('socketexception') ||
        lower.contains('connection closed before full header') ||
        lower.contains('connection refused') ||
        lower.contains('connection reset')) {
      return 'non_blocking';
    }
    return 'warning';
  }

  List<Map<String, Object?>> _recentErrors({
    int? sinceCursor,
    bool useRequestCursor = true,
  }) {
    _rememberSensitiveValuesFromTree();
    final now = DateTime.now().toUtc();
    final effectiveCursor =
        sinceCursor ?? (useRequestCursor ? _requestContext?.errorCursor : null);
    return [
      for (final error in _errors)
        if ((error['cursor'] as int? ?? 0) > (effectiveCursor ?? -1))
          _redactSensitiveMap(() {
            final timestamp = DateTime.tryParse(
              error['timestamp']?.toString() ?? '',
            );
            final ageMs = timestamp == null
                ? null
                : math.max(0, now.difference(timestamp.toUtc()).inMilliseconds);
            final stale = ageMs == null || ageMs > 30000;
            return <String, Object?>{
              ...error,
              'observedSinceCursor': effectiveCursor != null,
              'timestampStatus': timestamp == null
                  ? 'unavailable'
                  : 'observed_in_runtime',
              'ageStatus': ageMs == null ? 'unknown' : 'measured',
              'freshness': ageMs == null
                  ? 'unknown'
                  : stale
                  ? 'stale'
                  : 'fresh',
              'stale': stale,
              'ageMs': ageMs,
            };
          }()),
    ];
  }

  List<Map<String, Object?>> _activeBlockingRuntimeSignals() {
    if (_activeVisibleErrorSignalCursors.isEmpty) {
      return const <Map<String, Object?>>[];
    }
    final activeCursors = _activeVisibleErrorSignalCursors.values.toSet();
    final observedAt = DateTime.now().toUtc();
    return <Map<String, Object?>>[
      for (final error in _recentErrors(useRequestCursor: false))
        if (activeCursors.contains(error['cursor']) &&
            error['blocking'] == true)
          <String, Object?>{
            ...error,
            'active': true,
            'activeStatus': 'currently_observed',
            'lastObservedAt': observedAt.toIso8601String(),
            'activeDurationMs': error['ageMs'],
            'freshness': 'currently_active',
            'stale': false,
            'ageStatus': 'measured_since_first_observation',
            'causalAttribution': 'not_established',
          },
    ];
  }

  void _registerExtension(
    String name,
    Future<developer.ServiceExtensionResponse> Function(
      String method,
      Map<String, String> params,
    )
    callback,
  ) {
    try {
      developer.registerExtension(
        name,
        (method, params) => _dispatchProtocolRequest(
          extensionName: name,
          method: method,
          params: params,
          callback: callback,
        ),
      );
    } catch (_) {
      // Hot restart/reassemble and multiple test bindings can try to register
      // again. Keeping this idempotent matters more than surfacing the duplicate.
    }
  }

  void _broadcastVmUri() {
    if (!kDebugMode) return;
    unawaited(
      developer.Service.getInfo().then((developer.ServiceProtocolInfo info) {
        final uri = info.serverUri;
        if (uri != null) {
          debugPrint('[FLUTTER_SCOUT_VM_URI] $uri');
        }
      }),
    );
  }

  Future<developer.ServiceExtensionResponse> _handleInspect(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final brief = params['brief'] == 'true';
      final requestedMaxItems = int.tryParse(params['maxItems'] ?? '');
      final maxItems = (requestedMaxItems ?? 20).clamp(1, 100).toInt();
      final sections = (params['sections'] ?? '')
          .split(',')
          .map((section) => section.trim())
          .where((section) => section.isNotEmpty)
          .toSet();
      return _ok(<String, Object?>{
        ..._inspectPayload(
          brief: brief,
          maxItems: maxItems,
          sections: sections,
          surfaceOnly: params['surfaceOnly'] == 'true',
        ),
        'observationEffects': _observationEffects(
          _FrameAdvancePolicy.observeOnly,
        ),
      });
    } catch (error) {
      return _fail('inspect_failed', error.toString());
    }
  }

  /// Builds the inspect response. A full inspect can exceed 40KB — most of it
  /// textTargets and visualTree an agent rarely needs — so [brief] returns a
  /// compact orientation payload and [sections] opts into named full sections
  /// (text, interactables, fields, textTargets, scrollables, overlays,
  /// visualTree, controlGroups, rows, annotations). Both empty → full payload.
  Map<String, Object?> _inspectPayload({
    required bool brief,
    int maxItems = 20,
    required Set<String> sections,
    bool surfaceOnly = false,
  }) {
    final snapshot = _snapshot();
    final focusSurface =
        surfaceOnly || (brief && snapshot.activeSurface != null);
    final surfaceRect = focusSurface
        ? _rectFromJson(snapshot.activeSurface?['rect']) ??
              _surfaceRectFor(snapshot)
        : null;
    final surfaceAnchorOrdinal = focusSurface
        ? _modalContentStartOrdinal(snapshot.overlays) ??
              _surfaceAnchorOrdinal(snapshot)
        : null;
    final surfaceApplied =
        focusSurface && (surfaceRect != null || surfaceAnchorOrdinal != null);
    final interactables = _nodesForSurface(
      snapshot.interactables,
      surfaceRect,
      surfaceAnchorOrdinal,
    );
    final fields = _nodesForSurface(
      snapshot.fields,
      surfaceRect,
      surfaceAnchorOrdinal,
    );
    final textTargets = _nodesForSurface(
      snapshot.textTargets,
      surfaceRect,
      surfaceAnchorOrdinal,
    );
    final scrollables = focusSurface
        ? _scrollablesForSurface(
            snapshot.scrollables,
            surfaceRect,
            surfaceAnchorOrdinal,
          )
        : snapshot.scrollables;
    final overlays = focusSurface
        ? _overlaysForSurface(
            snapshot.overlays,
            surfaceRect,
            surfaceAnchorOrdinal,
          )
        : snapshot.overlays;
    final surfaceSnapshot = focusSurface
        ? snapshot.copyWith(
            interactables: interactables,
            fields: fields,
            textTargets: textTargets,
            scrollables: scrollables,
            overlays: overlays,
          )
        : snapshot;
    final controlGroups = focusSurface
        ? _buildControlGroups(surfaceSnapshot)
        : snapshot.controlGroups;
    final structuredRows = focusSurface
        ? _buildStructuredRows(
            surfaceSnapshot.copyWith(controlGroups: controlGroups),
          )
        : snapshot.structuredRows;
    final visualTree = focusSurface
        ? _buildVisualTree(surfaceSnapshot, controlGroups)
        : snapshot.visualTree;
    final fullScreenSurface =
        focusSurface &&
        surfaceRect != null &&
        surfaceRect.width >= snapshot.logicalSize.width * 0.90 &&
        surfaceRect.height >= snapshot.logicalSize.height * 0.90;
    final visibleText = !focusSurface
        ? snapshot.visibleText
        : fullScreenSurface
        ? _surfaceVisibleLabels(snapshot, interactables, fields)
        : _labelsFrom(textTargets);
    final hitTestableText = !focusSurface
        ? snapshot.hitTestableText
        : fullScreenSurface
        ? _surfaceVisibleLabels(snapshot, interactables, fields)
        : _labelsFrom(textTargets.where((node) => node.hitTestable));
    if (!brief && sections.isEmpty && !surfaceOnly) {
      final liveAnnotationTargets = _annotationTargets();
      return {
        ...snapshot.toJson(),
        'annotationMode': _annotationMode,
        'annotations': _annotationJsonList(liveTargets: liveAnnotationTargets),
      };
    }
    final payload = <String, Object?>{
      'screen': snapshot.screen,
      'screenEvidence': snapshot.screenEvidence,
      'routeGuess': snapshot.routeGuess,
      if (snapshot.activeSurface != null)
        'activeSurface': brief
            ? _compactActiveSurface(snapshot.activeSurface!)
            : snapshot.activeSurface,
      if (focusSurface)
        'surfaceOnly': {
          'applied': surfaceApplied,
          if (!surfaceOnly) 'automatic': true,
          if (!surfaceApplied)
            'reason': snapshot.activeSurface == null
                ? 'no_active_surface'
                : 'surface_bounds_unavailable'
          else if (surfaceRect != null)
            'rect': [
              surfaceRect.left,
              surfaceRect.top,
              surfaceRect.width,
              surfaceRect.height,
            ],
          'anchorOrdinal': ?surfaceAnchorOrdinal,
        },
      'viewSignature': snapshot.viewSignature,
      'stateGeneration': snapshot.stateGeneration,
      'stateDigest': snapshot.stateDigest,
      'snapshotId': snapshot.snapshotId,
      'visibleTextHash': snapshot.visibleTextHash,
      'idle': snapshot.idle,
      'viewport': snapshot.viewportJson(),
      // Perception limitations are safety evidence, not optional detail. Brief
      // mode keeps their status and count, but not every geometry-heavy gap.
      // The full details remain explicitly available through --sections
      // perception so a compact orientation read cannot imply full coverage.
      'perception': brief
          ? _compactBriefPerception(snapshot)
          : <String, Object?>{
              'observationKind': 'widget_tree_and_render_geometry',
              'pixelEvidence': 'not_included_in_inspect',
              'visualStatus': snapshot.perceptionGaps.isEmpty
                  ? 'pixels_not_observed'
                  : 'known_perception_gaps',
              'captureBackend': <String, Object?>{
                'status': snapshot.captureBackend['status'],
                'backend': snapshot.captureBackend['backend'],
                if (snapshot.captureBackend['reason'] != null)
                  'reason': snapshot.captureBackend['reason'],
                if (snapshot.captureBackend['provenance'] != null)
                  'provenance': snapshot.captureBackend['provenance'],
                if (snapshot.captureBackend['coverage']
                    case final Map coverage) ...{
                  'platformViewPixels': coverage['platformViewPixels'],
                  'texturePixels': coverage['texturePixels'],
                },
                if (snapshot.captureBackend['nativeFallback']
                    case final Map nativeFallback)
                  'nativeFallbackStatus': nativeFallback['status'],
              },
              'limitationCount': snapshot.perceptionGaps.length,
              if (snapshot.perceptionGaps.isNotEmpty)
                'limitations': snapshot.perceptionGaps,
              if (snapshot.degradedNodes > 0)
                'degradedElementCount': snapshot.degradedNodes,
            },
      'keyboard': <String, Object?>{
        'visible':
            snapshot.viewMetricsAvailable && snapshot.viewInsets.bottom > 0.5,
        'logicalInsetBottom': snapshot.viewMetricsAvailable
            ? snapshot.viewInsets.bottom
            : null,
        'source': snapshot.viewMetricsAvailable
            ? 'flutter_view_metrics'
            : 'observation_unavailable',
      },
      if (snapshot.degradedNodes > 0) 'degradedNodes': snapshot.degradedNodes,
      if (snapshot.recentErrors.isNotEmpty)
        'recentErrors': brief
            ? _compactBriefErrors(snapshot.recentErrors)
            : snapshot.recentErrors,
      if (brief && snapshot.recentErrors.isNotEmpty)
        'errorSummary': _briefErrorSummary(snapshot.recentErrors),
      if (_annotationMode) 'annotationMode': true,
    };
    if (!brief && (sections.isNotEmpty || surfaceOnly)) {
      const detailSections = <String>[
        'text',
        'interactables',
        'fields',
        'textTargets',
        'scrollables',
        'overlays',
        'visualTree',
        'controlGroups',
        'rows',
        'annotations',
        'semantics',
        'geometry',
        'perception',
      ];
      payload['omittedSections'] = <String, Object?>{
        'reason': sections.isNotEmpty
            ? 'explicit_section_selection'
            : 'surface_only_mode',
        'sections': <String>[
          for (final section in detailSections)
            if (!sections.contains(section)) section,
        ],
        if (sections.isNotEmpty) 'included': sections.toList()..sort(),
        'recoverWith': 'inspect --sections <name>',
      };
    }
    if (brief) {
      final briefInteractables = [
        for (final node in interactables)
          if (_includeInBriefInteractables(node)) node,
      ];
      // Duplicate handles (btn.save, btn.save_2, …) are indistinguishable in
      // brief output; give the whole duplicate group a compact position hint
      // so an agent can pick "the one in row 2" without full geometry.
      final duplicateBaseIds = <String, int>{};
      for (final node in briefInteractables) {
        duplicateBaseIds.update(node.baseId, (n) => n + 1, ifAbsent: () => 1);
      }
      final omitted = interactables.length - briefInteractables.length;
      final inspectWarnings = _inspectWarnings(
        anonymousGenericTargetsOmitted: omitted,
      );
      final briefVisibleText = _takeItems(visibleText, maxItems);
      final briefHitTestableText = _takeItems(hitTestableText, maxItems);
      final briefOffscreenText = focusSurface
          ? const <String>[]
          : _takeItems(
              snapshot.offscreenText,
              (maxItems ~/ 2).clamp(4, 20).toInt(),
            );
      final briefRows = structuredRows
          .take((maxItems ~/ 4).clamp(2, 6).toInt())
          .map(_compactStructuredRow)
          .toList(growable: false);
      final briefFields = fields.take(maxItems);
      payload.addAll({
        if (briefVisibleText.isNotEmpty) 'visibleText': briefVisibleText,
        if (briefHitTestableText.isNotEmpty &&
            !_sameStringLists(briefVisibleText, briefHitTestableText))
          'hitTestableText': briefHitTestableText,
        if (!focusSurface && briefOffscreenText.isNotEmpty)
          'offscreenText': briefOffscreenText,
        'interactables': [
          for (final node in briefInteractables.take(maxItems))
            _compactNodeJson(
              node,
              withPositionHint: (duplicateBaseIds[node.baseId] ?? 0) > 1,
            ),
        ],
        if (omitted > 0)
          'interactablesOmitted': {
            'count': omitted,
            'reason': 'anonymous_generic_targets',
            'hint':
                'Use inspect --sections interactables when these low-label controls matter.',
          },
        if (inspectWarnings.isNotEmpty) 'inspectWarnings': inspectWarnings,
        if (structuredRows.isNotEmpty) 'structuredRows': briefRows,
        if (scrollables.isNotEmpty)
          'scrollables': [
            for (final scrollable in scrollables.take(3))
              _compactBriefScrollable(scrollable),
          ],
        'omittedSections': <String, Object?>{
          'reason': 'brief_mode',
          'sections': const <String>[
            'textTargets',
            'overlays',
            'visualTree',
            'controlGroups',
            'annotations',
          ],
          if (scrollables.length > 3) 'scrollableItems': scrollables.length - 3,
          'recoverWith':
              'inspect --sections textTargets,scrollables,overlays,visualTree,controlGroups,annotations',
        },
        if (visibleText.length > briefVisibleText.length ||
            hitTestableText.length > briefHitTestableText.length ||
            (!focusSurface &&
                snapshot.offscreenText.length > briefOffscreenText.length) ||
            briefInteractables.length > maxItems ||
            structuredRows.length > briefRows.length ||
            fields.length > maxItems)
          'omitted': {
            if (visibleText.length > briefVisibleText.length)
              'visibleText': visibleText.length - briefVisibleText.length,
            if (hitTestableText.length > briefHitTestableText.length)
              'hitTestableText':
                  hitTestableText.length - briefHitTestableText.length,
            if (!focusSurface &&
                snapshot.offscreenText.length > briefOffscreenText.length)
              'offscreenText':
                  snapshot.offscreenText.length - briefOffscreenText.length,
            if (briefInteractables.length > maxItems)
              'interactables': briefInteractables.length - maxItems,
            if (structuredRows.length > briefRows.length)
              'structuredRows': structuredRows.length - briefRows.length,
            if (fields.length > maxItems) 'fields': fields.length - maxItems,
            'hint': 'Use inspect --sections <name> for full detail.',
          },
        if (briefFields.isNotEmpty)
          'fieldValues': {
            for (final field in briefFields) field.id: field.serializedValue,
          },
      });
    }
    for (final section in sections) {
      payload.addAll(switch (section) {
        'text' => {
          'visibleText': visibleText,
          'hitTestableText': hitTestableText,
          if (!focusSurface) 'offscreenText': snapshot.offscreenText,
        },
        'interactables' => {
          'interactables': [for (final node in interactables) node.toJson()],
        },
        'fields' => {
          'fields': [for (final node in fields) node.toJson()],
          'fieldValues': {
            for (final field in fields) field.id: field.serializedValue,
          },
        },
        'textTargets' => {
          'textTargets': [for (final node in textTargets) node.toJson()],
        },
        'scrollables' => {'scrollables': scrollables},
        'overlays' => {'overlays': overlays},
        'visualTree' => {'visualTree': visualTree},
        'controlGroups' => {'controlGroups': controlGroups},
        'rows' => {'structuredRows': structuredRows},
        'annotations' => {
          'annotations': _annotationJsonList(liveTargets: _annotationTargets()),
        },
        'semantics' => {
          'semanticCoverageHeuristic': _semanticCoverageHeuristic(
            snapshot,
            scopedInteractables: interactables,
            scopedFields: fields,
          ),
          'semanticDiagnostics': _semanticDiagnostics(
            snapshot,
            scopedInteractables: interactables,
          ),
        },
        'geometry' => {
          'devicePixelRatio': snapshot.devicePixelRatio,
          'logicalSize': [
            snapshot.logicalSize.width,
            snapshot.logicalSize.height,
          ],
          'viewport': snapshot.viewportJson(),
        },
        'perception' => {'perception': snapshot.perceptionJson()},
        _ => {'unknownSections': '$section (ignored)'},
      });
    }
    return payload;
  }

  Map<String, Object?> _compactActiveSurface(Map<String, Object?> surface) => {
    if (surface['kind'] != null) 'kind': surface['kind'],
    if (surface['label'] != null) 'label': surface['label'],
    if (surface['screen'] != null) 'screen': surface['screen'],
    if (surface['source'] != null) 'source': surface['source'],
    if (surface['heuristicScore'] != null)
      'heuristicScore': surface['heuristicScore'],
    if (surface['scoreKind'] != null) 'scoreKind': surface['scoreKind'],
    if (surface['provenance'] != null) 'provenance': surface['provenance'],
  };

  bool _sameStringLists(List<String> first, List<String> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  List<T> _takeItems<T>(List<T> items, int maxItems) =>
      items.length <= maxItems ? items : items.take(maxItems).toList();

  /// Bounded safety summary for orientation reads. Full perception gaps can
  /// contain ancestor paths and geometry for many nodes; their aggregate state
  /// is enough to prevent an agent from treating the snapshot as complete.
  Map<String, Object?> _compactBriefPerception(ScoutSnapshot snapshot) {
    final kinds = <String>{
      for (final gap in snapshot.perceptionGaps)
        if (gap['kind']?.toString().trim().isNotEmpty ?? false)
          gap['kind']!.toString(),
    }.toList()..sort();
    return <String, Object?>{
      'observationKind': 'widget_tree_and_render_geometry',
      'pixelEvidence': 'not_included_in_inspect',
      'visualStatus': snapshot.perceptionGaps.isEmpty
          ? 'pixels_not_observed'
          : 'known_perception_gaps',
      'captureBackend': <String, Object?>{
        'status': snapshot.captureBackend['status'],
        'backend': snapshot.captureBackend['backend'],
        if (snapshot.captureBackend['reason'] != null)
          'reason': snapshot.captureBackend['reason'],
      },
      'limitationCount': snapshot.perceptionGaps.length,
      if (kinds.isNotEmpty) 'limitationKinds': _takeItems(kinds, 8),
      if (kinds.length > 8) 'limitationKindsOmitted': kinds.length - 8,
      if (snapshot.degradedNodes > 0)
        'degradedElementCount': snapshot.degradedNodes,
      'recoverWith': 'inspect --sections perception',
    };
  }

  /// Keep only scroll state needed to decide whether a scroll action is a
  /// viable next step. Geometry, nested provenance, and exact extents belong
  /// in the explicit scrollables section.
  Map<String, Object?> _compactBriefScrollable(
    Map<String, Object?> scrollable,
  ) => <String, Object?>{
    'id': scrollable['id'],
    'scopedId': scrollable['scopedId'],
    'parentId': scrollable['parentId'],
    'nestingDepth': scrollable['nestingDepth'],
    'axis': scrollable['axis'],
    'axisDirection': scrollable['axisDirection'],
    'positionAvailable': scrollable['positionAvailable'],
    'metricsAvailable': scrollable['metricsAvailable'],
    'atStart': scrollable['atStart'],
    'atEnd': scrollable['atEnd'],
  };

  /// Errors remain visible in brief mode, including their severity and
  /// blocking status. Bound stack-like messages and correlation/provenance
  /// plumbing, which otherwise dominate an orientation response.
  List<Map<String, Object?>> _compactBriefErrors(
    List<Map<String, Object?>> errors,
  ) {
    final blocking = errors
        .where((error) => error['blocking'] == true)
        .toList();
    final other = errors.where((error) => error['blocking'] != true).toList();
    final selected =
        <Map<String, Object?>>[
          ..._takeLastItems(blocking, 4),
          ..._takeLastItems(other, 4),
        ]..sort(
          (left, right) => (left['cursor'] as int? ?? 0).compareTo(
            right['cursor'] as int? ?? 0,
          ),
        );
    return [
      for (final error in selected)
        <String, Object?>{
          'cursor': error['cursor'],
          'type': error['type'],
          'severity': error['severity'],
          'blocking': error['blocking'],
          if (error['message'] != null)
            'message': _abbreviateBriefString(error['message'].toString()),
          'freshness': error['freshness'],
        },
    ];
  }

  Map<String, Object?> _briefErrorSummary(List<Map<String, Object?>> errors) {
    final blockingCount = errors
        .where((error) => error['blocking'] == true)
        .length;
    return <String, Object?>{
      'count': errors.length,
      'blockingCount': blockingCount,
      if (errors.length > 8) 'omitted': errors.length - 8,
      'recoverWith': 'inspect (without --brief) or logs for full diagnostics',
    };
  }

  List<T> _takeLastItems<T>(List<T> items, int maxItems) {
    if (items.length <= maxItems) return items;
    return items.sublist(items.length - maxItems);
  }

  String _abbreviateBriefString(String value) {
    const limit = 280;
    if (value.length <= limit) return value;
    return '${value.substring(0, limit)}…';
  }

  Map<String, Object?> _compactStructuredRow(Map<String, Object?> row) {
    final text = row['text'];
    return {
      if (row['id'] != null) 'id': row['id'],
      if (row['label'] != null) 'label': row['label'],
      if (text is List) 'text': _takeItems(List<Object?>.from(text), 6),
      if (row['primaryTarget'] != null) 'primaryTarget': row['primaryTarget'],
    };
  }

  Map<String, Object?> _semanticCoverageHeuristic(
    ScoutSnapshot snapshot, {
    int anonymousGenericTargetsOmitted = 0,
    List<ScoutNode>? scopedInteractables,
    List<ScoutNode>? scopedFields,
  }) {
    final interactables = (scopedInteractables ?? snapshot.interactables)
        .where((node) => node.visibleFraction > 0)
        .toList(growable: false);
    final unlabeled = [
      for (final node in interactables)
        if ((node.label ?? '').trim().isEmpty &&
            (node.key ?? '').trim().isEmpty &&
            node.altIds.isEmpty)
          node,
    ];
    final disabledHitTargets = [
      for (final node in interactables)
        if (!node.hitTestable && node.enabled) node,
    ];
    final lowHeuristicScore = [
      for (final node in interactables)
        if (node.confidence < 0.7) node,
    ];
    final labels = <String, int>{};
    for (final node in interactables) {
      final label = node.label?.trim();
      if (label == null || label.isEmpty) continue;
      labels.update(
        label.toLowerCase(),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final duplicates = labels.values
        .where((count) => count > 1)
        .fold<int>(0, (sum, count) => sum + count);
    final issues = <Map<String, Object?>>[
      if (unlabeled.isNotEmpty || anonymousGenericTargetsOmitted > 0)
        {
          'code': 'unlabeled_interactables',
          'severity': anonymousGenericTargetsOmitted >= 10 ? 'high' : 'medium',
          'count': unlabeled.length + anonymousGenericTargetsOmitted,
          'hint':
              'Add keys, tooltips, or Semantics labels to important controls.',
        },
      if (duplicates > 0)
        {
          'code': 'duplicate_action_labels',
          'severity': 'low',
          'count': duplicates,
          'hint': 'Use keys or more specific labels for repeated actions.',
        },
      if (disabledHitTargets.isNotEmpty)
        {
          'code': 'non_hit_testable_actions',
          'severity': 'medium',
          'count': disabledHitTargets.length,
          'hint':
              'Visible enabled controls should usually be reachable at their suggested tap point.',
        },
      if (lowHeuristicScore.isNotEmpty)
        {
          'code': 'low_heuristic_score_targets',
          'severity': 'low',
          'count': lowHeuristicScore.length,
          'hint':
              'Prefer explicit keys or Semantics labels for inferred targets.',
        },
      if (snapshot.structuredRows.isEmpty && interactables.length >= 8)
        {
          'code': 'no_structured_rows',
          'severity': 'low',
          'hint':
              'Dense list or table screens are easier to operate when rows can be inferred.',
        },
    ];
    var score = 100;
    score -= (unlabeled.length * 8 + anonymousGenericTargetsOmitted * 2).clamp(
      0,
      35,
    );
    score -= (duplicates * 3).clamp(0, 15);
    score -= (disabledHitTargets.length * 4).clamp(0, 20);
    score -= (lowHeuristicScore.length * 2).clamp(0, 10);
    if (snapshot.degradedNodes > 0) score -= 10;
    score = score.clamp(0, 100);
    return {
      'heuristicScore': score,
      'scoreKind': 'uncalibrated_heuristic',
      'heuristicBand': score >= 90
          ? 'high_coverage'
          : score >= 75
          ? 'moderate_coverage'
          : score >= 60
          ? 'low_coverage'
          : 'very_low_coverage',
      'formulaVersion': 1,
      'metrics': {
        'visibleInteractables': interactables.length,
        'unlabeledInteractables': unlabeled.length,
        'anonymousGenericTargetsOmitted': anonymousGenericTargetsOmitted,
        'duplicateLabelInstances': duplicates,
        'nonHitTestableActions': disabledHitTargets.length,
        'lowHeuristicScoreTargets': lowHeuristicScore.length,
        'fields': (scopedFields ?? snapshot.fields).length,
        'structuredRows': snapshot.structuredRows.length,
      },
      if (issues.isNotEmpty) 'issues': issues,
    };
  }

  /// Concrete, factual follow-up to the compact semantic-quality counters.
  /// This is deliberately opt-in: it identifies handles and evidence but does
  /// not make a subjective UX judgment.
  Map<String, Object?> _semanticDiagnostics(
    ScoutSnapshot snapshot, {
    List<ScoutNode>? scopedInteractables,
  }) {
    final visible = (scopedInteractables ?? snapshot.interactables)
        .where((node) => node.visibleFraction > 0)
        .toList(growable: false);
    Map<String, Object?> nodeJson(ScoutNode node, String evidence) => {
      'id': node.id,
      'kind': node.kind,
      if (node.label != null) 'label': node.label,
      if (node.key != null) 'key': node.key,
      if (node.altIds.isNotEmpty) 'altIds': node.altIds,
      'evidence': evidence,
    };
    final labels = <String, List<ScoutNode>>{};
    for (final node in visible) {
      final label = node.label?.trim();
      if (label != null && label.isNotEmpty) {
        (labels[label.toLowerCase()] ??= []).add(node);
      }
    }
    final duplicates = [
      for (final entry in labels.entries)
        if (entry.value.length > 1)
          {
            'label': entry.key,
            'controls': [
              for (final node in entry.value.take(12))
                nodeJson(node, 'duplicate visible label'),
            ],
          },
    ];
    return {
      'unlabeledControls': [
        for (final node in visible)
          if ((node.label ?? '').trim().isEmpty &&
              (node.key ?? '').trim().isEmpty &&
              node.altIds.isEmpty)
            nodeJson(node, 'no label, key, or derived alias'),
      ],
      'nonHitTestableControls': [
        for (final node in visible)
          if (node.enabled && !node.hitTestable)
            nodeJson(node, 'visible and enabled but has no safe tap point'),
      ],
      'lowHeuristicScoreControls': [
        for (final node in visible)
          if (node.confidence < 0.7)
            nodeJson(
              node,
              'uncalibrated inferred-handle heuristic ${node.confidence}',
            ),
      ],
      if (duplicates.isNotEmpty) 'duplicateLabels': duplicates,
    };
  }

  List<Map<String, Object?>> _inspectWarnings({
    required int anonymousGenericTargetsOmitted,
  }) {
    return [
      if (anonymousGenericTargetsOmitted >= 20)
        {
          'code': 'many_anonymous_targets',
          'count': anonymousGenericTargetsOmitted,
          'message':
              'Many visible tappables have no label, key, tooltip, or semantic action name.',
          'hint':
              'Add keys, tooltips, or Semantics labels to important controls.',
        },
    ];
  }

  Rect? _surfaceRectFor(ScoutSnapshot snapshot) {
    for (final overlay in snapshot.overlays.reversed) {
      if (overlay['kind'] == 'modalBarrier') continue;
      final rect = _rectFromJson(overlay['rect']);
      if (rect != null && rect.width > 0 && rect.height > 0) return rect;
    }
    return null;
  }

  int? _surfaceAnchorOrdinal(ScoutSnapshot snapshot) {
    final value = snapshot.activeSurface?['anchorOrdinal'];
    return value is int ? value : null;
  }

  Rect? _rectFromJson(Object? value) {
    if (value is! List || value.length < 4) return null;
    final left = (value[0] as num?)?.toDouble();
    final top = (value[1] as num?)?.toDouble();
    final width = (value[2] as num?)?.toDouble();
    final height = (value[3] as num?)?.toDouble();
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    return Rect.fromLTWH(left, top, width, height);
  }

  List<ScoutNode> _nodesForSurface(
    List<ScoutNode> nodes,
    Rect? surfaceRect,
    int? anchorOrdinal,
  ) {
    if (surfaceRect == null && anchorOrdinal == null) return nodes;
    return [
      for (final node in nodes)
        if (node.hitTestable &&
            (anchorOrdinal == null ||
                (node._treeOrdinal ?? -1) >= anchorOrdinal))
          if (surfaceRect == null)
            node
          else if (node.rect case final rect?)
            if (rect.overlaps(surfaceRect) || surfaceRect.contains(rect.center))
              node,
    ];
  }

  List<Map<String, Object?>> _scrollablesForSurface(
    List<Map<String, Object?>> scrollables,
    Rect? surfaceRect,
    int? minimumOrdinal,
  ) {
    if (surfaceRect == null && minimumOrdinal == null) return scrollables;
    return [
      for (final scrollable in scrollables)
        if ((minimumOrdinal == null ||
                (scrollable['treeOrdinal'] as int? ?? -1) >= minimumOrdinal) &&
            _mapOverlapsSurface(scrollable, surfaceRect))
          scrollable,
    ];
  }

  List<Map<String, Object?>> _overlaysForSurface(
    List<Map<String, Object?>> overlays,
    Rect? surfaceRect,
    int? minimumOrdinal,
  ) {
    if (surfaceRect == null && minimumOrdinal == null) return overlays;
    final barriers = [
      for (final overlay in overlays)
        if (overlay['kind'] == 'modalBarrier') overlay,
    ];
    final topBarrier = barriers.isEmpty ? null : barriers.last;
    return [
      for (final overlay in overlays)
        if (identical(overlay, topBarrier) ||
            (overlay['kind'] != 'modalBarrier' &&
                (minimumOrdinal == null ||
                    (overlay['ordinal'] as int? ?? -1) >= minimumOrdinal) &&
                _mapOverlapsSurface(overlay, surfaceRect)))
          overlay,
    ];
  }

  bool _mapOverlapsSurface(Map<String, Object?> value, Rect? surfaceRect) {
    if (surfaceRect == null) return true;
    final rect =
        _rectFromJson(value['visibleRect']) ?? _rectFromJson(value['rect']);
    return rect != null && _rectOverlapsSurface(rect, surfaceRect);
  }

  bool _rectOverlapsSurface(Rect rect, Rect? surfaceRect) {
    if (surfaceRect == null) return true;
    return rect.overlaps(surfaceRect) || surfaceRect.contains(rect.center);
  }

  List<String> _labelsFrom(Iterable<ScoutNode> nodes) {
    final labels = <String>{};
    for (final node in nodes) {
      final label = node.label?.trim();
      if (label != null && label.isNotEmpty) labels.add(label);
    }
    return labels.toList(growable: false);
  }

  List<String> _surfaceVisibleLabels(
    ScoutSnapshot snapshot,
    List<ScoutNode> interactables,
    List<ScoutNode> fields,
  ) {
    final labels = <String>{};
    final activeLabel = snapshot.activeSurface?['label']?.toString().trim();
    if (activeLabel != null && activeLabel.isNotEmpty) {
      labels.add(activeLabel);
    } else {
      labels.addAll(snapshot.hitTestableText);
    }
    labels.addAll(_labelsFrom([...interactables, ...fields]));
    return labels.toList(growable: false);
  }

  bool _includeInBriefInteractables(ScoutNode node) {
    if ((node.label ?? '').trim().isNotEmpty) return true;
    if ((node.key ?? '').trim().isNotEmpty) return true;
    if (node.altIds.isNotEmpty) return true;
    if (node.selected != null) return true;
    if (node.enclosingTarget != null) return true;
    final id = node.id.toLowerCase();
    final baseId = node.baseId.toLowerCase();
    final widgetType = node.widgetType.toLowerCase();
    final generic =
        id.contains('gesturedetector') ||
        baseId.contains('gesturedetector') ||
        widgetType == 'gesturedetector' ||
        widgetType == 'listener' ||
        widgetType == 'rawgesturedetector';
    return !generic;
  }

  /// Orientation-sized node summary for brief inspect: enough to pick a
  /// handle and know its state, nothing else.
  Map<String, Object?> _compactNodeJson(
    ScoutNode node, {
    bool withPositionHint = false,
  }) {
    return {
      'id': node.id,
      'kind': node.kind,
      if (node.label != null) 'label': node.label,
      if (node.selected != null) 'selected': node.selected,
      if (node.altIds.isNotEmpty) 'altIds': node.altIds,
      if (node.enclosingTarget != null) 'enclosingTarget': node.enclosingTarget,
      if (withPositionHint && node.rect != null)
        'at': _positionHint(node.rect!),
      if (!node.enabled) 'enabled': false,
      if (!node.hitTestable) 'hitTestable': false,
      if (node.visibleFraction == 0) 'offscreen': true,
    };
  }

  /// Compact human-readable position for disambiguating duplicate handles:
  /// a coarse grid cell of the screen (r1c1 = top-left) plus rounded top-left
  /// pixels for tie-breaking.
  String _positionHint(Rect rect) {
    final size = _logicalSize();
    final center = rect.center;
    final col = size.width <= 0
        ? 1
        : ((center.dx / size.width) * 3).floor().clamp(0, 2) + 1;
    final row = size.height <= 0
        ? 1
        : ((center.dy / size.height) * 4).floor().clamp(0, 3) + 1;
    return 'r${row}c$col@${rect.left.round()},${rect.top.round()}';
  }

  /// Test-only view of the inspect payload assembly.
  @visibleForTesting
  Map<String, Object?> debugInspectPayload({
    bool brief = false,
    int maxItems = 20,
    Set<String> sections = const {},
    bool surfaceOnly = false,
  }) => _inspectPayload(
    brief: brief,
    maxItems: maxItems,
    sections: sections,
    surfaceOnly: surfaceOnly,
  );
}

class _HeldDragState {
  _HeldDragState({
    required this.pointer,
    required this.viewId,
    required this.start,
    required this.position,
    required this.startedAt,
    required this.before,
    required this.path,
  });

  final int pointer;
  final int viewId;
  final Offset start;
  Offset position;
  final DateTime startedAt;
  final ScoutSnapshot before;
  final List<Map<String, Object?>> path;
}
