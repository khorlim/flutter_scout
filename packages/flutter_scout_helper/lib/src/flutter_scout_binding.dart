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
const int scoutHelperProtocolVersion = 3;

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

  /// Test-only view of the tap-text near-match suggestions.
  @visibleForTesting
  List<String> debugTextSuggestions(String query) =>
      _textSuggestions(_snapshot().visibleText, query);

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
      final sections = (params['sections'] ?? '')
          .split(',')
          .map((section) => section.trim())
          .where((section) => section.isNotEmpty)
          .toSet();
      return _ok(_inspectPayload(brief: brief, sections: sections));
    } catch (error) {
      return _fail('inspect_failed', error.toString());
    }
  }

  /// Builds the inspect response. A full inspect can exceed 40KB — most of it
  /// textTargets and visualTree an agent rarely needs — so [brief] returns a
  /// compact orientation payload and [sections] opts into named full sections
  /// (text, interactables, fields, textTargets, scrollables, overlays,
  /// visualTree, controlGroups, annotations). Both empty → full payload.
  Map<String, Object?> _inspectPayload({
    required bool brief,
    required Set<String> sections,
  }) {
    if (!brief && sections.isEmpty) {
      final liveAnnotationTargets = _annotationTargets();
      return {
        ..._snapshot().toJson(),
        'annotationMode': _annotationMode,
        'annotations': _annotationJsonList(liveTargets: liveAnnotationTargets),
      };
    }
    final snapshot = _snapshot();
    final payload = <String, Object?>{
      'screen': snapshot.screen,
      'routeGuess': snapshot.routeGuess,
      'viewSignature': snapshot.viewSignature,
      'visibleTextHash': snapshot.visibleTextHash,
      'idle': snapshot.idle,
      'devicePixelRatio': snapshot.devicePixelRatio,
      'logicalSize': [snapshot.logicalSize.width, snapshot.logicalSize.height],
      if (snapshot.degradedNodes > 0) 'degradedNodes': snapshot.degradedNodes,
      'recentErrors': snapshot.recentErrors,
      'annotationMode': _annotationMode,
    };
    if (brief) {
      payload.addAll({
        'visibleText': snapshot.visibleText,
        'hitTestableText': snapshot.hitTestableText,
        'offscreenText': snapshot.offscreenText,
        'interactables': [
          for (final node in snapshot.interactables) _compactNodeJson(node),
        ],
        'fieldValues': {
          for (final field in snapshot.fields) field.id: field.value,
        },
      });
    }
    for (final section in sections) {
      payload.addAll(switch (section) {
        'text' => {
          'visibleText': snapshot.visibleText,
          'hitTestableText': snapshot.hitTestableText,
          'offscreenText': snapshot.offscreenText,
        },
        'interactables' => {
          'interactables': [
            for (final node in snapshot.interactables) node.toJson(),
          ],
        },
        'fields' => {
          'fields': [for (final node in snapshot.fields) node.toJson()],
          'fieldValues': {
            for (final field in snapshot.fields) field.id: field.value,
          },
        },
        'textTargets' => {
          'textTargets': [
            for (final node in snapshot.textTargets) node.toJson(),
          ],
        },
        'scrollables' => {'scrollables': snapshot.scrollables},
        'overlays' => {'overlays': snapshot.overlays},
        'visualTree' => {'visualTree': snapshot.visualTree},
        'controlGroups' => {'controlGroups': snapshot.controlGroups},
        'annotations' => {
          'annotations': _annotationJsonList(liveTargets: _annotationTargets()),
        },
        _ => {'unknownSections': '$section (ignored)'},
      });
    }
    return payload;
  }

  /// Orientation-sized node summary for brief inspect: enough to pick a
  /// handle and know its state, nothing else.
  Map<String, Object?> _compactNodeJson(ScoutNode node) {
    return {
      'id': node.id,
      'kind': node.kind,
      if (node.label != null) 'label': node.label,
      if (node.selected != null) 'selected': node.selected,
      if (node.altIds.isNotEmpty) 'altIds': node.altIds,
      if (!node.enabled) 'enabled': false,
      if (!node.hitTestable) 'hitTestable': false,
      if (node.visibleFraction == 0) 'offscreen': true,
    };
  }

  /// Test-only view of the inspect payload assembly.
  @visibleForTesting
  Map<String, Object?> debugInspectPayload({
    bool brief = false,
    Set<String> sections = const {},
  }) => _inspectPayload(brief: brief, sections: sections);
}
