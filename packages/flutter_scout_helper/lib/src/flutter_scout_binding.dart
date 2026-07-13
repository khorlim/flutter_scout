import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'icon_names.g.dart';

part 'scout_design.dart';
part 'annotation_overlay.dart';
part 'models.dart';
part 'runtime_annotations.dart';
part 'runtime_actions.dart';
part 'runtime_snapshot.dart';
part 'runtime_nodes.dart';
part 'runtime_internals.dart';

/// Protocol version reported in every helper response, so the CLI can tell
/// when the RUNNING helper is older than the one it expects — the classic
/// git-dependency trap where editing pub-cache source and hot reloading
/// silently keeps executing old code. Bump when the CLI starts depending on
/// new helper behavior; keep in sync with the CLI's
/// `_expectedHelperProtocolVersion`.
const int scoutHelperProtocolVersion = 10;

class FlutterScoutBinding {
  FlutterScoutBinding._();

  static void ensureInitialized() {
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
  final List<Map<String, Object?>> _errors = <Map<String, Object?>>[];
  final List<ScoutAnnotation> _annotations = <ScoutAnnotation>[];
  final ValueNotifier<int> _annotationRevision = ValueNotifier<int>(0);
  final DateTime _installedAt = DateTime.now();
  int _nextSyntheticPointer = 1000000;
  int _nextAnnotationId = 1;
  int _annotationHandoffSeq = 0;
  // Logical bounds currently being rasterised. The overlay omits its chrome
  // (scrim/outlines/pins) *inside* these rects so captures stay clean — without
  // blanking the whole overlay, which caused a visible flash on save. A list so
  // overlapping captures compose; entries are added/removed by _captureRegion.
  final List<Rect> _captureClearRects = <Rect>[];
  bool _annotationMode = false;
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
  FlutterExceptionHandler? _previousFlutterError;
  ui.ErrorCallback? _previousPlatformError;

  /// Test-only fault injector, invoked for every element the snapshot walk
  /// visits. Lets tests prove that a throwing element degrades only itself
  /// (see [ScoutSnapshot.degradedNodes]) instead of failing the whole inspect.
  @visibleForTesting
  void Function(Element element)? debugSnapshotNodeProbe;

  void install() {
    _installErrorHooks();
    _registerExtension('ext.flutter_scout.inspect', _handleInspect);
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
    _registerExtension('ext.flutter_scout.back', _handleBack);
    _registerExtension('ext.flutter_scout.waitStable', _handleWaitStable);
    _registerExtension('ext.flutter_scout.waitFor', _handleWaitFor);
    _registerExtension('ext.flutter_scout.dismiss', _handleDismiss);
    _broadcastVmUri();
    _scheduleAnnotationOverlayInstall();
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
  void debugSetAnnotationMode(bool enabled) => _setAnnotationMode(enabled);

  @visibleForTesting
  List<ScoutAnnotationTarget> debugVisibleAnnotationTargets() =>
      visibleAnnotationTargets();

  @visibleForTesting
  ScoutSnapshot debugSnapshot() => _snapshot();

  /// Test-only: dispatch a synthetic tap exactly as agent actions do,
  /// including the chrome-transparency window.
  @visibleForTesting
  Future<void> debugDispatchTap(Offset point) => _dispatchTap(point);

  /// Test-only view of wait-for condition evaluation against a snapshot.
  /// [conditions] uses wait-for param names: text, gone, target, selected,
  /// screen, field (`<handle>=<value>`).
  @visibleForTesting
  bool debugWaitForConditionsMet(Map<String, String> conditions) =>
      _waitForConditionsMet(snapshot: _snapshot(), params: conditions);

  /// Test-only: run deferred frames with an advancing clock, as the
  /// observation windows do on a backgrounded desktop window.
  @visibleForTesting
  Future<void> debugDrainDeferredFrames({
    Duration budget = const Duration(milliseconds: 1500),
  }) => _drainDeferredFrames(budget: budget);

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

  void _recordError({
    required String type,
    required String message,
    String? library,
  }) {
    final timestamp = DateTime.now();
    final severity = _errorSeverity(type: type, message: message);
    final error = <String, Object?>{
      'type': type,
      'message': message,
      'timestamp': timestamp.toIso8601String(),
      'severity': severity,
      'blocking': severity == 'blocking',
      'phase': timestamp.difference(_installedAt) < const Duration(seconds: 10)
          ? 'startup'
          : 'runtime',
    };
    if (library != null) {
      error['library'] = library;
    }
    _errors.add(error);
    if (_errors.length > 30) {
      _errors.removeRange(0, _errors.length - 30);
    }
  }

  String _errorSeverity({required String type, required String message}) {
    final lower = message.toLowerCase();
    if (type == 'flutter_error') return 'blocking';
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

  List<Map<String, Object?>> _recentErrors() {
    final now = DateTime.now();
    return [
      for (final error in _errors)
        {
          ...error,
          if (DateTime.tryParse(error['timestamp']?.toString() ?? '')
              case final timestamp?) ...{
            'ageMs': now.difference(timestamp).inMilliseconds,
            'stale': now.difference(timestamp) > const Duration(seconds: 30),
          },
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
      developer.registerExtension(name, callback);
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
      await _waitForFrame();
      final brief = params['brief'] == 'true';
      final requestedMaxItems = int.tryParse(params['maxItems'] ?? '');
      final maxItems = (requestedMaxItems ?? 20).clamp(1, 100).toInt();
      final sections = (params['sections'] ?? '')
          .split(',')
          .map((section) => section.trim())
          .where((section) => section.isNotEmpty)
          .toSet();
      return _ok(
        _inspectPayload(
          brief: brief,
          maxItems: maxItems,
          sections: sections,
          surfaceOnly: params['surfaceOnly'] == 'true',
        ),
      );
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
    final surfaceRect = surfaceOnly ? _surfaceRectFor(snapshot) : null;
    final surfaceAnchorOrdinal = surfaceOnly
        ? _surfaceAnchorOrdinal(snapshot)
        : null;
    final surfaceApplied =
        surfaceOnly && (surfaceRect != null || surfaceAnchorOrdinal != null);
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
    final fullScreenSurface =
        surfaceOnly &&
        surfaceRect != null &&
        surfaceRect.width >= snapshot.logicalSize.width * 0.90 &&
        surfaceRect.height >= snapshot.logicalSize.height * 0.90;
    final visibleText = surfaceRect == null
        ? snapshot.visibleText
        : fullScreenSurface
        ? _surfaceVisibleLabels(snapshot, interactables, fields)
        : _labelsFrom(textTargets);
    final hitTestableText = surfaceRect == null
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
      'routeGuess': snapshot.routeGuess,
      if (snapshot.activeSurface != null)
        'activeSurface': snapshot.activeSurface,
      if (surfaceOnly)
        'surfaceOnly': {
          'applied': surfaceApplied,
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
      'visibleTextHash': snapshot.visibleTextHash,
      'idle': snapshot.idle,
      'devicePixelRatio': snapshot.devicePixelRatio,
      'logicalSize': [snapshot.logicalSize.width, snapshot.logicalSize.height],
      'perception': snapshot.perceptionJson(),
      if (snapshot.degradedNodes > 0) 'degradedNodes': snapshot.degradedNodes,
      'semanticQuality': _semanticQuality(snapshot),
      'recentErrors': snapshot.recentErrors,
      'annotationMode': _annotationMode,
    };
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
      final briefOffscreenText = _takeItems(
        snapshot.offscreenText,
        (maxItems ~/ 2).clamp(4, 20).toInt(),
      );
      final briefRows = snapshot.structuredRows
          .take((maxItems ~/ 4).clamp(2, 6).toInt())
          .map(_compactStructuredRow)
          .toList(growable: false);
      final briefFields = fields.take(maxItems);
      payload.addAll({
        'visibleText': briefVisibleText,
        'hitTestableText': briefHitTestableText,
        if (!surfaceOnly) 'offscreenText': briefOffscreenText,
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
        'semanticQuality': _semanticQuality(
          snapshot,
          anonymousGenericTargetsOmitted: omitted,
        ),
        if (snapshot.structuredRows.isNotEmpty) 'structuredRows': briefRows,
        if (visibleText.length > briefVisibleText.length ||
            hitTestableText.length > briefHitTestableText.length ||
            snapshot.offscreenText.length > briefOffscreenText.length ||
            briefInteractables.length > maxItems ||
            snapshot.structuredRows.length > briefRows.length ||
            fields.length > maxItems)
          'omitted': {
            if (visibleText.length > briefVisibleText.length)
              'visibleText': visibleText.length - briefVisibleText.length,
            if (hitTestableText.length > briefHitTestableText.length)
              'hitTestableText':
                  hitTestableText.length - briefHitTestableText.length,
            if (snapshot.offscreenText.length > briefOffscreenText.length)
              'offscreenText':
                  snapshot.offscreenText.length - briefOffscreenText.length,
            if (briefInteractables.length > maxItems)
              'interactables': briefInteractables.length - maxItems,
            if (snapshot.structuredRows.length > briefRows.length)
              'structuredRows':
                  snapshot.structuredRows.length - briefRows.length,
            if (fields.length > maxItems) 'fields': fields.length - maxItems,
            'hint': 'Use inspect --sections <name> for full detail.',
          },
        'fieldValues': {for (final field in briefFields) field.id: field.value},
      });
    }
    for (final section in sections) {
      payload.addAll(switch (section) {
        'text' => {
          'visibleText': visibleText,
          'hitTestableText': hitTestableText,
          if (!surfaceOnly) 'offscreenText': snapshot.offscreenText,
        },
        'interactables' => {
          'interactables': [for (final node in interactables) node.toJson()],
        },
        'fields' => {
          'fields': [for (final node in fields) node.toJson()],
          'fieldValues': {for (final field in fields) field.id: field.value},
        },
        'textTargets' => {
          'textTargets': [for (final node in textTargets) node.toJson()],
        },
        'scrollables' => {'scrollables': snapshot.scrollables},
        'overlays' => {'overlays': snapshot.overlays},
        'visualTree' => {'visualTree': snapshot.visualTree},
        'controlGroups' => {'controlGroups': snapshot.controlGroups},
        'rows' => {'structuredRows': snapshot.structuredRows},
        'annotations' => {
          'annotations': _annotationJsonList(liveTargets: _annotationTargets()),
        },
        'semantics' => {'semanticDiagnostics': _semanticDiagnostics(snapshot)},
        _ => {'unknownSections': '$section (ignored)'},
      });
    }
    return payload;
  }

  List<T> _takeItems<T>(List<T> items, int maxItems) =>
      items.length <= maxItems ? items : items.take(maxItems).toList();

  Map<String, Object?> _compactStructuredRow(Map<String, Object?> row) {
    final text = row['text'];
    return {
      if (row['id'] != null) 'id': row['id'],
      if (row['label'] != null) 'label': row['label'],
      if (text is List) 'text': _takeItems(List<Object?>.from(text), 6),
      if (row['primaryTarget'] != null) 'primaryTarget': row['primaryTarget'],
    };
  }

  Map<String, Object?> _semanticQuality(
    ScoutSnapshot snapshot, {
    int anonymousGenericTargetsOmitted = 0,
  }) {
    final interactables = snapshot.interactables
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
    final lowConfidence = [
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
      if (lowConfidence.isNotEmpty)
        {
          'code': 'low_confidence_targets',
          'severity': 'low',
          'count': lowConfidence.length,
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
    score -= (lowConfidence.length * 2).clamp(0, 10);
    if (snapshot.degradedNodes > 0) score -= 10;
    score = score.clamp(0, 100);
    return {
      'score': score,
      'grade': score >= 90
          ? 'excellent'
          : score >= 75
          ? 'good'
          : score >= 60
          ? 'fair'
          : 'poor',
      'metrics': {
        'visibleInteractables': interactables.length,
        'unlabeledInteractables': unlabeled.length,
        'anonymousGenericTargetsOmitted': anonymousGenericTargetsOmitted,
        'duplicateLabelInstances': duplicates,
        'nonHitTestableActions': disabledHitTargets.length,
        'lowConfidenceTargets': lowConfidence.length,
        'fields': snapshot.fields.length,
        'structuredRows': snapshot.structuredRows.length,
      },
      if (issues.isNotEmpty) 'issues': issues,
    };
  }

  /// Concrete, factual follow-up to the compact semantic-quality counters.
  /// This is deliberately opt-in: it identifies handles and evidence but does
  /// not make a subjective UX judgment.
  Map<String, Object?> _semanticDiagnostics(ScoutSnapshot snapshot) {
    final visible = snapshot.interactables
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
      'lowConfidenceControls': [
        for (final node in visible)
          if (node.confidence < 0.7)
            nodeJson(node, 'inferred handle confidence ${node.confidence}'),
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
            (anchorOrdinal == null || node.ordinal >= anchorOrdinal))
          if (surfaceRect == null)
            node
          else if (node.rect case final rect?)
            if (rect.overlaps(surfaceRect) || surfaceRect.contains(rect.center))
              node,
    ];
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
