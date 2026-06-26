import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

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
    if (_registered) return;
    _registered = true;
    _runtime.install();
  }
}

class FlutterScoutRuntime {
  final List<Map<String, Object?>> _errors = <Map<String, Object?>>[];
  final List<ScoutAnnotation> _annotations = <ScoutAnnotation>[];
  final ValueNotifier<int> _annotationRevision = ValueNotifier<int>(0);
  final DateTime _installedAt = DateTime.now();
  int _nextSyntheticPointer = 1000000;
  int _nextAnnotationId = 1;
  bool _annotationMode = false;
  OverlayEntry? _annotationOverlayEntry;
  bool _annotationOverlayInstallScheduled = false;
  FlutterExceptionHandler? _previousFlutterError;
  ui.ErrorCallback? _previousPlatformError;

  void install() {
    _installErrorHooks();
    _registerExtension('ext.flutter_scout.inspect', _handleInspect);
    _registerExtension('ext.flutter_scout.annotations', _handleAnnotations);
    _registerExtension('ext.flutter_scout.tap', _handleTap);
    _registerExtension('ext.flutter_scout.tapText', _handleTapText);
    _registerExtension('ext.flutter_scout.longPress', _handleLongPress);
    _registerExtension('ext.flutter_scout.input', _handleInput);
    _registerExtension('ext.flutter_scout.fill', _handleFill);
    _registerExtension('ext.flutter_scout.scroll', _handleScroll);
    _registerExtension('ext.flutter_scout.swipe', _handleSwipe);
    _registerExtension('ext.flutter_scout.back', _handleBack);
    _registerExtension('ext.flutter_scout.waitStable', _handleWaitStable);
    _broadcastVmUri();
    _scheduleAnnotationOverlayInstall();
  }

  int get _activeAnnotationCount =>
      _annotations.where((annotation) => annotation.isActive).length;

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
    if (kReleaseMode) return;
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
      final liveAnnotationTargets = _annotationTargets();
      return _ok({
        ..._snapshot().toJson(),
        'annotationMode': _annotationMode,
        'annotations': _annotationJsonList(liveTargets: liveAnnotationTargets),
      });
    } catch (error) {
      return _fail('inspect_failed', error.toString());
    }
  }

  Future<developer.ServiceExtensionResponse> _handleAnnotations(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final action = params['action'] ?? 'list';
      switch (action) {
        case 'enable':
          _setAnnotationMode(true);
          break;
        case 'disable':
          _setAnnotationMode(false);
          break;
        case 'clear':
          final status = params['status'];
          if (status == null || status.isEmpty) {
            _annotations.clear();
          } else {
            _annotations.removeWhere(
              (annotation) => annotation.status == status,
            );
          }
          _bumpAnnotationRevision();
          break;
        case 'resolve':
          final updated = _updateAnnotationStatus(
            id: params['id'],
            status: 'resolved',
            note: params['note'],
          );
          if (!updated) return _annotationMissing(params['id']);
          break;
        case 'dismiss':
          final updated = _updateAnnotationStatus(
            id: params['id'],
            status: 'dismissed',
            note: params['note'],
          );
          if (!updated) return _annotationMissing(params['id']);
          break;
        case 'reopen':
          final updated = _updateAnnotationStatus(
            id: params['id'],
            status: 'open',
            note: params['note'],
          );
          if (!updated) return _annotationMissing(params['id']);
          break;
        case 'check':
          _refreshStaleAnnotationStatuses(_annotationTargets());
          break;
        case 'list':
        case 'targets':
          break;
        default:
          return _fail(
            'unknown_annotation_action',
            'Unknown annotations action `$action`.',
          );
      }
      await _waitForFrame();
      return _ok(_annotationsStateJson(includeTargets: action == 'targets'));
    } catch (error) {
      return _fail('annotations_failed', error.toString());
    }
  }

  developer.ServiceExtensionResponse _annotationMissing(String? id) {
    return _fail(
      'annotation_not_found',
      id == null || id.isEmpty
          ? 'Annotation id is required.'
          : 'Annotation `$id` was not found.',
    );
  }

  bool _updateAnnotationStatus({
    required String? id,
    required String status,
    String? note,
  }) {
    if (id == null || id.isEmpty) return false;
    for (final annotation in _annotations) {
      if (annotation.id == id) {
        annotation.status = status;
        annotation.updatedAt = DateTime.now();
        final trimmedNote = note?.trim();
        annotation.note = trimmedNote == null || trimmedNote.isEmpty
            ? null
            : trimmedNote;
        _bumpAnnotationRevision();
        return true;
      }
    }
    return false;
  }

  void _refreshStaleAnnotationStatuses(
    List<ScoutAnnotationTarget> liveTargets,
  ) {
    var changed = false;
    for (final annotation in _annotations) {
      if (annotation.status != 'open' && annotation.status != 'stale_target') {
        continue;
      }
      final liveTarget = _liveAnnotationTarget(annotation, liveTargets);
      final nextStatus = liveTarget == null ? 'stale_target' : 'open';
      if (annotation.status != nextStatus) {
        annotation.status = nextStatus;
        annotation.updatedAt = DateTime.now();
        changed = true;
      }
    }
    if (changed) _bumpAnnotationRevision();
  }

  void _setAnnotationMode(bool enabled) {
    if (_annotationMode == enabled) return;
    _annotationMode = enabled;
    _bumpAnnotationRevision();
    _scheduleAnnotationOverlayInstall();
  }

  void _bumpAnnotationRevision() {
    _annotationRevision.value++;
  }

  Map<String, Object?> _annotationsStateJson({bool includeTargets = false}) {
    final snapshot = _snapshot();
    final liveTargets = _annotationTargets();
    return {
      'annotationMode': _annotationMode,
      'screen': snapshot.screen,
      'routeGuess': snapshot.routeGuess,
      'annotations': _annotationJsonList(liveTargets: liveTargets),
      if (includeTargets)
        'targets': liveTargets
            .map((target) => target.toJson())
            .toList(growable: false),
    };
  }

  List<Map<String, Object?>> _annotationJsonList({
    List<ScoutAnnotationTarget>? liveTargets,
  }) {
    final targets = liveTargets ?? _annotationTargets();
    return [
      for (final annotation in _annotations)
        annotation.toJson(
          liveTarget: _liveAnnotationTarget(annotation, targets),
        ),
    ];
  }

  List<Rect> _annotationPinRects(List<ScoutAnnotationTarget> liveTargets) {
    return [
      for (final annotation in _annotations)
        if (annotation.isActive)
          if (_liveAnnotationTarget(annotation, liveTargets) case final target?)
            target.rect,
    ];
  }

  ScoutAnnotationTarget? _liveAnnotationTarget(
    ScoutAnnotation annotation,
    List<ScoutAnnotationTarget> liveTargets,
  ) {
    ScoutAnnotationTarget? exactId;
    ScoutAnnotationTarget? exactNode;
    final stableMatches = <ScoutAnnotationTarget>[];
    for (final target in liveTargets) {
      if (target.id == annotation.target.id) {
        exactId = target;
        break;
      }
      if (annotation.target.scoutNodeId != null &&
          target.scoutNodeId == annotation.target.scoutNodeId) {
        exactNode ??= target;
      }
      if (target.stableId == annotation.target.stableId) {
        stableMatches.add(target);
      }
    }
    if (exactId != null) return exactId;
    if (exactNode != null) return exactNode;
    if (stableMatches.isEmpty) return null;
    stableMatches.sort(
      (a, b) => _annotationRectDistance(
        annotation.target.rect,
        a.rect,
      ).compareTo(_annotationRectDistance(annotation.target.rect, b.rect)),
    );
    return stableMatches.first;
  }

  double _annotationRectDistance(Rect snapshot, Rect live) {
    final snapshotCenter = snapshot.center;
    final liveCenter = live.center;
    return (snapshotCenter - liveCenter).distance;
  }

  ScoutAnnotation addAnnotation({
    required ScoutAnnotationTarget target,
    required String comment,
  }) {
    final annotation = ScoutAnnotation(
      id: 'ann_${_nextAnnotationId.toString().padLeft(3, '0')}',
      createdAt: DateTime.now(),
      comment: comment,
      status: 'open',
      target: target,
    );
    _nextAnnotationId++;
    _annotations.add(annotation);
    _bumpAnnotationRevision();
    return annotation;
  }

  List<ScoutAnnotationTarget> annotationCandidatesAt(Offset point) {
    final targets = [
      for (final target in _annotationTargets())
        if (target.rect.contains(point)) target,
    ];
    targets.sort((a, b) {
      final aArea = a.rect.width * a.rect.height;
      final bArea = b.rect.width * b.rect.height;
      final area = aArea.compareTo(bArea);
      if (area != 0) return area;
      return b.depth.compareTo(a.depth);
    });
    return targets;
  }

  List<ScoutAnnotationTarget> visibleAnnotationTargets() {
    return _annotationTargets();
  }

  void _scheduleAnnotationOverlayInstall() {
    if (kReleaseMode || _annotationOverlayEntry != null) return;
    if (_annotationOverlayInstallScheduled) return;
    _annotationOverlayInstallScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _annotationOverlayInstallScheduled = false;
      _installAnnotationOverlayIfPossible();
    });
  }

  void _installAnnotationOverlayIfPossible() {
    if (kReleaseMode || _annotationOverlayEntry != null) return;
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) {
      _scheduleAnnotationOverlayInstall();
      return;
    }
    final overlay = _findRootOverlay(root);
    if (overlay == null) {
      _scheduleAnnotationOverlayInstall();
      return;
    }
    _annotationOverlayEntry = OverlayEntry(
      builder: (context) => _FlutterScoutAnnotationOverlay(runtime: this),
    );
    overlay.insert(_annotationOverlayEntry!);
  }

  OverlayState? _findRootOverlay(Element root) {
    OverlayState? result;
    _walk(root, (Element element) {
      if (element is StatefulElement && element.state is OverlayState) {
        result = element.state as OverlayState;
      }
    });
    return result;
  }

  Future<developer.ServiceExtensionResponse> _handleTap(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final before = _snapshot();
      final target = params['target'];
      final x = double.tryParse(params['x'] ?? '');
      final y = double.tryParse(params['y'] ?? '');

      Offset? point;
      ScoutNode? node;
      if (target != null && target.isNotEmpty) {
        node = _snapshot().findNode(target);
        point = node?.suggestedTapPoint;
      } else if (x != null && y != null) {
        point = Offset(x, y);
      }

      if (point == null) {
        if (node != null && node.visibleFraction == 0) {
          return _fail(
            'target_not_visible',
            'Target `$target` matched `${node.id}` but is offscreen; scroll it into view before tapping.',
          );
        }
        return _fail(
          'target_not_found',
          'No tappable target matched `$target`.',
        );
      }

      await _dispatchTap(point);
      final actionSnapshot = await _snapshotAfterAction(before, params);
      final stable = actionSnapshot.stable;
      final after = actionSnapshot.snapshot;
      final changed = _changed(before, after);
      return _ok({
        'action': 'tap ${target ?? '${point.dx},${point.dy}'}',
        'stable': stable,
        'result': changed ? 'changed' : 'activated_no_observed_change',
        if (actionSnapshot.lateChangeObserved) 'lateChangeObserved': true,
        if (actionSnapshot.waitTimedOut) 'waitTimedOut': true,
        'target': node?.toJson(),
        'activation': {
          'dispatched': true,
          'observedChange': changed,
          'note': changed
              ? null
              : 'Tap was dispatched, but no synchronous Flutter tree, field, text, or geometry change was observed before the wait timeout.',
        },
        if (!changed)
          'warnings': const [
            'Tap dispatched without an observed synchronous UI change; check recentErrors, overlays, logs, or increase --wait-ms if the action is async.',
          ],
        'before': before.summaryJson(),
        'after': after.summaryJson(),
        'delta': _delta(before, after),
        'recentErrors': _recentErrors(),
      });
    } catch (error) {
      return _fail('tap_failed', error.toString());
    }
  }

  Future<developer.ServiceExtensionResponse> _handleTapText(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final before = _snapshot();
      final text = params['text'] ?? params['target'];
      if (text == null || text.trim().isEmpty) {
        return _fail('missing_text', 'Expected text to tap.');
      }
      final match = _findVisibleTextMatch(text);
      if (match == null) {
        return _fail('text_not_found', 'No visible text matched `$text`.');
      }
      final targetNode = match.actionable ?? match.text;
      if (_unsafeTapTextActivation(match, text) &&
          params['allowMismatch'] != 'true') {
        return _fail(
          'tap_text_target_mismatch',
          'Text `$text` matched `${match.text.label}`, but the actionable target is `${targetNode.label ?? targetNode.id}`. Use `tap ${targetNode.id}` if that is intended, or pass allowMismatch=true to tap-text.',
          extra: {
            'target': targetNode.toJson(),
            'textTarget': match.text.toJson(),
            'activation': {
              'dispatched': false,
              'strategy': 'semantic_mismatch_blocked',
            },
            'warnings': [
              'tap-text refused to tap a different semantic action than the visible text. This prevents accidentally submitting or confirming when selecting a row label.',
            ],
          },
        );
      }
      final point = _tapPointForTextMatch(match);
      if (point == null) {
        return _fail(
          'text_not_actionable',
          'Text `$text` is visible, but no actionable ancestor was found.',
        );
      }
      await _dispatchTap(point);
      final actionSnapshot = await _snapshotAfterAction(before, params);
      final stable = actionSnapshot.stable;
      final after = actionSnapshot.snapshot;
      final changed = _changed(before, after);
      return _ok({
        'action': 'tap-text $text',
        'stable': stable,
        'result': changed ? 'changed' : 'activated_no_observed_change',
        if (actionSnapshot.lateChangeObserved) 'lateChangeObserved': true,
        if (actionSnapshot.waitTimedOut) 'waitTimedOut': true,
        'target': targetNode.toJson(),
        'textTarget': match.text.toJson(),
        'activation': {
          'dispatched': true,
          'observedChange': changed,
          'strategy': _tapTextStrategy(match),
        },
        if (!changed)
          'warnings': const [
            'tap-text activated the nearest actionable target, but no synchronous UI change was observed before the wait timeout.',
          ],
        'before': before.summaryJson(),
        'after': after.summaryJson(),
        'delta': _delta(before, after),
        'recentErrors': _recentErrors(),
      });
    } catch (error) {
      return _fail('tap_text_failed', error.toString());
    }
  }

  Offset? _tapPointForTextMatch(_TextTargetMatch match) {
    final textPoint = match.text.suggestedTapPoint ?? match.text.rect?.center;
    final actionable = match.actionable;
    if (actionable == null) {
      return textPoint != null && _hitTestable(textPoint) ? textPoint : null;
    }
    if (_shouldTapTextPoint(match)) return textPoint;
    return actionable.suggestedTapPoint ?? actionable.rect?.center ?? textPoint;
  }

  bool _shouldTapTextPoint(_TextTargetMatch match) {
    final actionable = match.actionable;
    final actionRect = actionable?.rect;
    final textRect = match.text.rect;
    if (actionable == null || actionRect == null || textRect == null) {
      return false;
    }
    final actionArea = actionRect.width * actionRect.height;
    final textArea = textRect.width * textRect.height;
    if (actionArea <= 0 || textArea <= 0) return false;
    return actionArea / textArea > 16;
  }

  String _tapTextStrategy(_TextTargetMatch match) {
    if (match.actionable == null) return 'visible_text_point';
    if (match.actionable!.id == match.text.id) return 'text_target';
    if (_shouldTapTextPoint(match)) return 'broad_ancestor_text_point';
    return 'nearest_actionable_ancestor';
  }

  bool _unsafeTapTextActivation(_TextTargetMatch match, String requestedText) {
    final actionable = match.actionable;
    if (actionable == null) return false;
    if (actionable.id == match.text.id) return false;
    if (actionable.kind != 'btn') return false;
    final actionLabel = actionable.label;
    if (actionLabel == null || actionLabel.trim().isEmpty) return false;
    final requestedSlug = _slug(requestedText);
    final textSlug = _slug(match.text.label ?? requestedText);
    final actionSlug = _slug(actionLabel);
    final actionIdSlug = _slug(actionable.id);
    return !actionSlug.contains(requestedSlug) &&
        !actionSlug.contains(textSlug) &&
        !actionIdSlug.contains(requestedSlug) &&
        !actionIdSlug.contains(textSlug);
  }

  Future<developer.ServiceExtensionResponse> _handleInput(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final before = _snapshot();
      final target = params['target'];
      final value = params['value'] ?? '';
      final editable = _findEditable(target: target);
      if (editable == null) {
        return _fail(
          'field_not_found',
          'No editable text field matched `$target`. Custom controls are exposed through inspect visualTree/controlGroups and must be operated with tap commands.',
          extra: {'suggestedActions': _inputRecoverySuggestions(target)},
        );
      }
      _setEditableText(editable, value);
      final stable = await _waitStableForAction(params);
      final after = _snapshot();
      return _ok({
        'action': 'input ${target ?? 'focused'}',
        'stable': stable,
        'result': _changed(before, after) ? 'changed' : 'unchanged',
        'before': before.summaryJson(),
        'after': after.summaryJson(),
        'delta': _delta(before, after),
        'recentErrors': _recentErrors(),
      });
    } catch (error) {
      return _fail('input_failed', error.toString());
    }
  }

  Future<developer.ServiceExtensionResponse> _handleLongPress(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final before = _snapshot();
      final target = params['target'];
      final durationMs = int.tryParse(params['durationMs'] ?? '') ?? 600;
      final point = _pointForTarget(target, params);
      if (point == null) {
        return _fail('target_not_found', 'No target matched `$target`.');
      }

      await _dispatchPress(point, hold: Duration(milliseconds: durationMs));
      final stable = await _waitStableForAction(params);
      final after = _snapshot();
      return _ok({
        'action': 'longPress ${target ?? '${point.dx},${point.dy}'}',
        'stable': stable,
        'result': _changed(before, after) ? 'changed' : 'unchanged',
        'before': before.summaryJson(),
        'after': after.summaryJson(),
        'delta': _delta(before, after),
        'recentErrors': _recentErrors(),
      });
    } catch (error) {
      return _fail('long_press_failed', error.toString());
    }
  }

  Future<developer.ServiceExtensionResponse> _handleFill(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final before = _snapshot();
      final raw = params['values'];
      if (raw == null || raw.isEmpty) {
        return _fail('missing_values', 'Expected a JSON object in `values`.');
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return _fail('invalid_values', '`values` must be a JSON object.');
      }

      final filled = <String>[];
      final failed = <String>[];
      final results = <Map<String, Object?>>[];
      final warnings = <String>[];
      for (final entry in decoded.entries) {
        final fieldBefore = _snapshot();
        final editable = _findEditable(target: entry.key);
        if (editable == null) {
          failed.add(entry.key);
          results.add({
            'target': entry.key,
            'ok': false,
            'reason': 'field_not_found',
            'message':
                'No editable text field matched `${entry.key}`. Custom controls are exposed through inspect visualTree/controlGroups and must be operated with tap commands.',
            'suggestedActions': _inputRecoverySuggestions(entry.key),
          });
          continue;
        }
        _setEditableText(editable, entry.value?.toString() ?? '');
        final fieldStable = await _waitStableForAction(params);
        final fieldAfter = _snapshot();
        final fieldDelta = _delta(fieldBefore, fieldAfter);
        final changedFields = fieldDelta['changedFields'];
        final changedFieldCount = changedFields is List
            ? changedFields.length
            : 0;
        final screenChanged = fieldDelta['screenChanged'] == true;
        final newInteractables = fieldDelta['newInteractables'];
        final removedInteractables = fieldDelta['removedInteractables'];
        final actionStateChanged =
            (newInteractables is List && newInteractables.isNotEmpty) ||
            (removedInteractables is List && removedInteractables.isNotEmpty);
        final changed = _changed(fieldBefore, fieldAfter);
        if (changed &&
            changedFieldCount == 0 &&
            !screenChanged &&
            !actionStateChanged) {
          warnings.add('filled `${entry.key}` changed visible state only');
        }
        filled.add(entry.key);
        results.add({
          'target': entry.key,
          'ok': true,
          'stable': fieldStable,
          'changed': changed,
          'delta': fieldDelta,
        });
      }

      final stable = await _waitStableForAction(params);
      final after = _snapshot();
      return _ok({
        'action': 'fill',
        'stable': stable,
        'filled': filled,
        'failed': failed,
        'fieldResults': results,
        if (warnings.isNotEmpty) 'warnings': warnings,
        'result': failed.isEmpty ? 'success' : 'partial',
        'before': before.summaryJson(),
        'after': after.summaryJson(),
        'delta': _delta(before, after),
        'recentErrors': _recentErrors(),
      });
    } catch (error) {
      return _fail('fill_failed', error.toString());
    }
  }

  Future<developer.ServiceExtensionResponse> _handleScroll(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final direction = params['direction'] ?? 'down';
      final distance = double.tryParse(params['distance'] ?? '') ?? 280;
      return _drag(
        action: 'scroll $direction',
        direction: direction,
        distance: distance,
        scrollGesture: true,
        params: params,
      );
    } catch (error) {
      return _fail('scroll_failed', error.toString());
    }
  }

  Future<developer.ServiceExtensionResponse> _handleSwipe(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final direction = params['direction'] ?? 'left';
      final distance = double.tryParse(params['distance'] ?? '') ?? 320;
      return _drag(
        action: 'swipe $direction',
        direction: direction,
        distance: distance,
        scrollGesture: false,
        params: params,
      );
    } catch (error) {
      return _fail('swipe_failed', error.toString());
    }
  }

  Future<developer.ServiceExtensionResponse> _handleBack(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final before = _snapshot();
      final rootContext = WidgetsBinding.instance.rootElement;
      if (rootContext == null) {
        return _fail('no_root', 'No root element is attached.');
      }
      final navigator = _findActiveNavigator(rootContext);
      final popped = await navigator?.maybePop() ?? false;
      final stable = await _waitStableForAction(params);
      final after = _snapshot();
      return _ok({
        'action': 'back',
        'stable': stable,
        'popped': popped,
        'result': _changed(before, after) ? 'changed' : 'unchanged',
        'before': before.summaryJson(),
        'after': after.summaryJson(),
        'delta': _delta(before, after),
        'recentErrors': _recentErrors(),
      });
    } catch (error) {
      return _fail('back_failed', error.toString());
    }
  }

  Future<developer.ServiceExtensionResponse> _handleWaitStable(
    String method,
    Map<String, String> params,
  ) async {
    final timeoutMs = int.tryParse(params['timeoutMs'] ?? '') ?? 3000;
    final stable = await _waitStable(
      timeout: Duration(milliseconds: timeoutMs),
    );
    return _ok({
      'stable': stable,
      'reason': stable ? null : 'frames_still_changing',
      'durationMs': timeoutMs,
      'snapshot': _snapshot().summaryJson(),
      'recentErrors': _recentErrors(),
    });
  }

  Future<void> _waitForFrame() async {
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(milliseconds: 500),
      onTimeout: () {},
    );
  }

  Future<bool> _waitStable({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var quietFrames = 0;
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final frameTimeout = remaining < const Duration(milliseconds: 200)
          ? remaining
          : const Duration(milliseconds: 200);
      if (frameTimeout <= Duration.zero) break;
      await WidgetsBinding.instance.endOfFrame.timeout(
        frameTimeout,
        onTimeout: () {},
      );
      if (!WidgetsBinding.instance.hasScheduledFrame) {
        quietFrames++;
        if (quietFrames >= 2) return true;
      } else {
        quietFrames = 0;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    return !WidgetsBinding.instance.hasScheduledFrame;
  }

  Future<bool> _waitStableForAction(Map<String, String> params) {
    final waitMs = int.tryParse(params['waitMs'] ?? '') ?? 1500;
    if (waitMs <= 0) return Future.value(false);
    return _waitStable(timeout: Duration(milliseconds: waitMs));
  }

  Future<_ActionSnapshotResult> _snapshotAfterAction(
    ScoutSnapshot before,
    Map<String, String> params,
  ) async {
    final stable = await _waitStableForAction(params);
    var after = _snapshot();
    if (_changed(before, after)) {
      return _ActionSnapshotResult(snapshot: after, stable: stable);
    }

    final lateWaitMs = int.tryParse(params['lateWaitMs'] ?? '') ?? 1000;
    if (lateWaitMs <= 0) {
      return _ActionSnapshotResult(snapshot: after, stable: stable);
    }

    final deadline = DateTime.now().add(Duration(milliseconds: lateWaitMs));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await _waitStable(timeout: const Duration(milliseconds: 250));
      after = _snapshot();
      if (_changed(before, after)) {
        return _ActionSnapshotResult(
          snapshot: after,
          stable: !WidgetsBinding.instance.hasScheduledFrame,
          lateChangeObserved: true,
        );
      }
    }

    return _ActionSnapshotResult(
      snapshot: after,
      stable: stable,
      waitTimedOut: !stable || WidgetsBinding.instance.hasScheduledFrame,
    );
  }

  Future<developer.ServiceExtensionResponse> _drag({
    required String action,
    required String direction,
    required double distance,
    required bool scrollGesture,
    required Map<String, String> params,
  }) async {
    final before = _snapshot();
    final start = _pointForTarget(params['target'], params) ?? _screenCenter();
    final explicitEnd = _pointFromParams(params, prefix: 'to');
    final delta = explicitEnd == null
        ? _dragDelta(direction, distance, scrollGesture: scrollGesture)
        : explicitEnd - start;
    await _dispatchDrag(start, delta);
    final stable = await _waitStableForAction(params);
    final after = _snapshot();
    final changed = _changed(before, after);
    final actionDelta = _delta(before, after);
    final screenChanged = actionDelta['screenChanged'] == true;
    return _ok({
      'action': action,
      'stable': stable,
      'result': screenChanged
          ? 'navigated'
          : (changed ? 'changed' : 'unchanged'),
      'gestureStart': [start.dx, start.dy],
      'gestureEnd': [start.dx + delta.dx, start.dy + delta.dy],
      if (!changed)
        'unchangedReason': _viewportRect().contains(start)
            ? 'no_visible_change_after_gesture'
            : 'gesture_start_outside_viewport',
      'before': before.summaryJson(),
      'after': after.summaryJson(),
      'delta': actionDelta,
      'recentErrors': _recentErrors(),
    });
  }

  ScoutSnapshot _snapshot() {
    final root = WidgetsBinding.instance.rootElement;
    final nodes = <ScoutNode>[];
    final scrollables = <Map<String, Object?>>[];
    final overlays = <Map<String, Object?>>[];
    final visibleText = <String>{};
    final hitTestableText = <String>{};
    final offscreenText = <String>{};
    var screen = 'RootWidget';
    final logicalSize = _logicalSize();
    if (root != null) {
      _walk(root, (Element element) {
        if (_isHiddenByAncestor(element)) return;
        final widgetType = element.widget.runtimeType.toString();
        if (screen == 'RootWidget' && widgetType.endsWith('Screen')) {
          screen = widgetType;
        }
        final node = _nodeFromElement(element);
        if (node != null) {
          nodes.add(node);
        }
        if (element.widget is Scrollable) {
          final rect = _rectFor(element);
          if (rect != null) {
            final visibleRect = _visibleRectFor(rect);
            scrollables.add({
              'widgetType': element.widget.runtimeType.toString(),
              'rect': [rect.left, rect.top, rect.width, rect.height],
              'visibleRect': visibleRect == null
                  ? null
                  : [
                      visibleRect.left,
                      visibleRect.top,
                      visibleRect.width,
                      visibleRect.height,
                    ],
              'visibleFraction': _visibleFraction(rect, visibleRect),
            });
          }
        }
        final overlay = _overlayFor(element);
        if (overlay != null) {
          overlays.add(overlay);
        }
        final text = _ownText(element.widget);
        if (text != null && _isUsefulVisibleText(text)) {
          final rect = _rectFor(element);
          final trimmed = text.trim();
          if (rect == null || _visibleRectFor(rect) == null) {
            offscreenText.add(trimmed);
          } else {
            visibleText.add(trimmed);
            final point = _visibleCenter(rect);
            if (point != null && _hitTestable(point)) {
              hitTestableText.add(trimmed);
            }
          }
        }
      });
    }

    final compactNodes = _disambiguateIds(
      _inferActionableLabels(_compactNodes(nodes)),
    );
    final interactables = compactNodes
        .where((node) => node.kind != 'text' && node.kind != 'field')
        .toList(growable: false);
    final fields = compactNodes
        .where((node) => node.kind == 'field')
        .toList(growable: false);
    final textTargets = compactNodes
        .where((node) => node.kind == 'text')
        .toList(growable: false);
    final route = root == null ? null : ModalRoute.of(root)?.settings.name;
    final snapshot = ScoutSnapshot(
      screen: route != null && route.isNotEmpty ? route : screen,
      routeGuess: route,
      idle: !WidgetsBinding.instance.hasScheduledFrame,
      devicePixelRatio: WidgetsBinding
          .instance
          .platformDispatcher
          .views
          .first
          .devicePixelRatio,
      logicalSize: logicalSize,
      visibleText: visibleText.toList(growable: false),
      hitTestableText: hitTestableText.toList(growable: false),
      offscreenText: offscreenText.toList(growable: false),
      interactables: interactables,
      fields: fields,
      textTargets: textTargets,
      scrollables: scrollables,
      overlays: overlays,
      visualTree: null,
      controlGroups: const [],
      suggestedActions: const [],
      recentErrors: _recentErrors(),
    );
    final controlGroups = _buildControlGroups(snapshot);
    return snapshot.copyWith(
      controlGroups: controlGroups,
      visualTree: _buildVisualTree(snapshot, controlGroups),
      suggestedActions: controlGroups.isEmpty
          ? const []
          : const [
              {
                'intent': 'enterValue',
                'method': 'tapSequence',
                'reason':
                    'A custom control group is visible. It is not a text field; operate it by tapping the exposed child controls in order, then tap the commit action if needed.',
              },
            ],
    );
  }

  List<ScoutAnnotationTarget> _annotationTargets() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return const <ScoutAnnotationTarget>[];
    final route = ModalRoute.of(root)?.settings.name;
    final screen = _screenName(root, route);
    final modalElement = _activeAnnotationModalElement(root);
    final targets = <ScoutAnnotationTarget>[];
    _walk(root, (Element element) {
      if (_isHiddenByAncestor(element) || _isScoutOverlayElement(element)) {
        return;
      }
      if (!_isInsideActiveAnnotationModal(element, modalElement)) return;
      final rect = _rectFor(element);
      if (rect == null || rect.width < 1 || rect.height < 1) return;
      final visibleRect = _visibleRectFor(rect);
      if (visibleRect == null) return;
      if (!_annotationTargetReceivesHit(element, rect)) return;
      final widget = element.widget;
      final widgetType = widget.runtimeType.toString();
      final key = _annotationKeyLabel(widget.key);
      final label = _labelFor(element, widget);
      final text = _ownText(widget)?.trim();
      final kind = _annotationKindFor(widget, element);
      if (!_isUsefulAnnotationTarget(
        widget: widget,
        kind: kind,
        key: key,
        label: label,
        text: text,
      )) {
        return;
      }
      final ancestors = _ancestorSummary(element);
      targets.add(
        ScoutAnnotationTarget(
          id: _annotationTargetId(
            kind: kind,
            widgetType: widgetType,
            key: key,
            label: label,
            text: text,
            rect: rect,
            ancestors: ancestors,
          ),
          stableId: _stableAnnotationId(
            kind: kind,
            widgetType: widgetType,
            key: key,
            label: label,
            text: text,
          ),
          kind: kind,
          widgetType: widgetType,
          key: key,
          label: label,
          text: text,
          screen: screen,
          routeGuess: route,
          rect: rect,
          visibleRect: visibleRect,
          visibleFraction: _visibleFraction(rect, visibleRect),
          depth: _elementDepth(element),
          ancestorSummary: ancestors,
          scoutNodeId: _nodeFromElement(element)?.id,
        ),
      );
    });

    final deduped = <String, ScoutAnnotationTarget>{};
    for (final target in _removeOversizedModalTargets(
      targets,
      modalActive: modalElement != null,
    )) {
      final rect = target.rect;
      final key = [
        target.stableId,
        rect.left.round(),
        rect.top.round(),
        rect.width.round(),
        rect.height.round(),
      ].join(':');
      final existing = deduped[key];
      if (existing == null || target.depth > existing.depth) {
        deduped[key] = target;
      }
    }
    final result = deduped.values.toList(growable: false)
      ..sort((a, b) {
        final top = a.rect.top.compareTo(b.rect.top);
        if (top != 0) return top;
        final left = a.rect.left.compareTo(b.rect.left);
        if (left != 0) return left;
        return a.rect.width.compareTo(b.rect.width);
      });
    return result;
  }

  Element? _activeAnnotationModalElement(Element root) {
    Element? result;
    var resultDepth = -1;
    _walk(root, (Element element) {
      if (_isHiddenByAncestor(element) || _isScoutOverlayElement(element)) {
        return;
      }
      final widget = element.widget;
      if (widget is! AlertDialog &&
          widget is! SimpleDialog &&
          widget is! Dialog &&
          widget is! BottomSheet) {
        return;
      }
      final rect = _rectFor(element);
      if (rect == null || _visibleRectFor(rect) == null) return;
      final depth = _elementDepth(element);
      if (depth >= resultDepth) {
        result = element;
        resultDepth = depth;
      }
    });
    return result;
  }

  bool _isInsideActiveAnnotationModal(Element element, Element? modalElement) {
    if (modalElement == null) return true;
    if (identical(element, modalElement)) return true;
    var result = false;
    element.visitAncestorElements((ancestor) {
      if (identical(ancestor, modalElement)) {
        result = true;
        return false;
      }
      return true;
    });
    return result;
  }

  bool _annotationTargetReceivesHit(Element element, Rect rect) {
    final renderObject = element.renderObject;
    if (renderObject == null) return false;
    final visible = _visibleRectFor(rect);
    if (visible == null) return false;
    final insetX = (visible.width * 0.2).clamp(1.0, 12.0);
    final insetY = (visible.height * 0.2).clamp(1.0, 12.0);
    final points = <Offset>[
      visible.center,
      Offset(visible.left + insetX, visible.top + insetY),
      Offset(visible.right - insetX, visible.top + insetY),
      Offset(visible.left + insetX, visible.bottom - insetY),
      Offset(visible.right - insetX, visible.bottom - insetY),
    ];
    for (final point in points) {
      if (_hitTestPathContainsRenderObject(point, renderObject)) return true;
    }
    return false;
  }

  bool _hitTestPathContainsRenderObject(Offset point, RenderObject target) {
    try {
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, point, _primaryViewId);
      return result.path.any((entry) => identical(entry.target, target));
    } catch (_) {
      return false;
    }
  }

  List<ScoutAnnotationTarget> _removeOversizedModalTargets(
    List<ScoutAnnotationTarget> targets, {
    required bool modalActive,
  }) {
    if (!modalActive || targets.isEmpty) return targets;
    final viewportArea = _rectArea(_viewportRect());
    final contentCandidates = [
      for (final target in targets)
        if (_rectArea(target.rect) < viewportArea * 0.45) target.rect,
    ];
    if (contentCandidates.isEmpty) return targets;
    final contentRect = contentCandidates.reduce(
      (value, element) => value.expandToInclude(element),
    );
    final contentArea = _rectArea(contentRect);
    return [
      for (final target in targets)
        if (_rectArea(target.rect) <= contentArea * 3) target,
    ];
  }

  String _screenName(Element root, String? route) {
    if (route != null && route.isNotEmpty) return route;
    var screen = 'RootWidget';
    _walk(root, (Element element) {
      if (screen != 'RootWidget') return;
      final widgetType = element.widget.runtimeType.toString();
      if (widgetType.endsWith('Screen')) screen = widgetType;
    });
    return screen;
  }

  String _annotationKindFor(Widget widget, Element element) {
    final scoutKind = _kindFor(widget, element);
    if (scoutKind != null) return scoutKind;
    if (widget is Image) return 'image';
    if (widget is Icon) return 'icon';
    if (widget is AppBar) return 'appBar';
    if (widget is Scaffold) return 'screen';
    if (widget is Card) return 'card';
    if (widget is Dialog || widget is AlertDialog || widget is SimpleDialog) {
      return 'dialog';
    }
    if (widget is Row ||
        widget is Column ||
        widget is Stack ||
        widget is Wrap) {
      return 'layout';
    }
    return 'widget';
  }

  bool _isUsefulAnnotationTarget({
    required Widget widget,
    required String kind,
    required String? key,
    required String? label,
    required String? text,
  }) {
    final type = widget.runtimeType.toString();
    if (key != null && key.isNotEmpty) return true;
    if (type.startsWith('_')) return false;
    if (kind == 'widget' || kind == 'layout') {
      if (text != null && text.trim().isNotEmpty) return true;
      if (type.endsWith('Screen') || type.endsWith('Dialog')) return true;
      return false;
    }
    if (kind == 'tap' &&
        (label == null || label.trim().isEmpty) &&
        (text == null || text.trim().isEmpty)) {
      return false;
    }
    if (label != null && label.trim().isNotEmpty) return true;
    if (text != null && text.trim().isNotEmpty) return true;
    if (kind != 'widget' && kind != 'layout') return true;
    if (type.endsWith('Screen') || type.endsWith('Dialog')) return true;
    return false;
  }

  String? _annotationKeyLabel(Key? key) {
    if (key is ValueKey) {
      final label = key.value.toString();
      if (label.startsWith('_') || label.contains('#')) return null;
      return label;
    }
    return null;
  }

  String _annotationTargetId({
    required String kind,
    required String widgetType,
    required String? key,
    required String? label,
    required String? text,
    required Rect rect,
    required List<String> ancestors,
  }) {
    final base = _stableAnnotationId(
      kind: kind,
      widgetType: widgetType,
      key: key,
      label: label,
      text: text,
    );
    final ancestorTail = ancestors.length <= 3
        ? ancestors.join('.')
        : ancestors.sublist(ancestors.length - 3).join('.');
    return [
      'annTarget',
      _slug(ancestorTail),
      base,
      rect.left.round(),
      rect.top.round(),
    ].where((part) => part.toString().isNotEmpty).join('.');
  }

  String _stableAnnotationId({
    required String kind,
    required String widgetType,
    required String? key,
    required String? label,
    required String? text,
  }) {
    if (key != null && key.isNotEmpty) return '$kind.${_slug(key)}';
    if (label != null && label.isNotEmpty) return '$kind.${_slug(label)}';
    if (text != null && text.isNotEmpty) return '$kind.${_slug(text)}';
    return '$kind.${_slug(widgetType)}';
  }

  List<String> _ancestorSummary(Element element) {
    final ancestors = <String>[];
    element.visitAncestorElements((ancestor) {
      final type = ancestor.widget.runtimeType.toString();
      if (!type.startsWith('_') && ancestors.length < 8) {
        ancestors.add(type);
      }
      return true;
    });
    return ancestors.reversed.toList(growable: false);
  }

  int _elementDepth(Element element) {
    var depth = 0;
    element.visitAncestorElements((_) {
      depth++;
      return true;
    });
    return depth;
  }

  bool _isScoutOverlayElement(Element element) {
    var isScout = _isScoutOverlayWidget(element.widget);
    element.visitAncestorElements((ancestor) {
      if (_isScoutOverlayWidget(ancestor.widget)) {
        isScout = true;
        return false;
      }
      return true;
    });
    return isScout;
  }

  bool _isScoutOverlayWidget(Widget widget) {
    return widget.runtimeType.toString().startsWith('_FlutterScout');
  }

  ScoutNode? _nodeFromElement(Element element) {
    if (_isHiddenByAncestor(element)) return null;
    final widget = element.widget;
    final rect = _rectFor(element);
    if (rect == null || rect.width < 1 || rect.height < 1) return null;

    final kind = _kindFor(widget, element);
    if (kind == null) return null;

    final label = _labelFor(element, widget);
    final baseId = _stableId(
      kind,
      label,
      widget.key,
      element.widget.runtimeType.toString(),
    );
    final visibleRect = _visibleRectFor(rect);
    final suggestedTapPoint = _visibleCenter(rect);
    return ScoutNode(
      id: baseId,
      baseId: baseId,
      ordinal: 1,
      fallbackId:
          'i${baseId.hashCode.abs().toString().padLeft(8, '0').substring(0, 6)}',
      kind: kind,
      label: label,
      value: kind == 'field' ? _editableValueBelow(element) : null,
      validationMessage: kind == 'field'
          ? _validationMessageForFieldWidget(widget)
          : null,
      widgetType: widget.runtimeType.toString(),
      key: _keyLabel(widget.key),
      rect: rect,
      visibleRect: visibleRect,
      visibleFraction: _visibleFraction(rect, visibleRect),
      suggestedTapPoint: suggestedTapPoint,
      hitTestable: suggestedTapPoint == null
          ? false
          : _hitTestable(suggestedTapPoint),
      enabled: _enabledFor(widget),
      confidence: label == null ? 0.65 : 0.94,
    );
  }

  String? _kindFor(Widget widget, Element element) {
    if (widget is TextField ||
        widget is TextFormField ||
        widget is EditableText) {
      if (widget is EditableText && _hasTextFieldAncestor(element)) {
        return null;
      }
      return 'field';
    }
    if (widget is Text || widget is RichText) {
      return 'text';
    }
    if (widget is ButtonStyleButton ||
        widget is IconButton ||
        widget is FloatingActionButton) {
      return 'btn';
    }
    if (widget is GestureDetector || widget is InkWell || widget is ListTile) {
      return 'tap';
    }
    return null;
  }

  bool _hasTextFieldAncestor(Element element) {
    var result = false;
    element.visitAncestorElements((Element ancestor) {
      final widget = ancestor.widget;
      if (widget is TextField || widget is TextFormField) {
        result = true;
        return false;
      }
      return true;
    });
    return result;
  }

  bool _isHiddenByAncestor(Element element) {
    var hidden = false;
    element.visitAncestorElements((Element ancestor) {
      final widget = ancestor.widget;
      if (widget is Offstage && widget.offstage) {
        hidden = true;
        return false;
      }
      if (widget is Visibility && !widget.visible && !widget.maintainSize) {
        hidden = true;
        return false;
      }
      if (widget is TickerMode && !widget.enabled) {
        hidden = true;
        return false;
      }
      if (widget is IgnorePointer && widget.ignoring) {
        hidden = true;
        return false;
      }
      return true;
    });
    return hidden;
  }

  bool _enabledFor(Widget widget) {
    if (widget is ButtonStyleButton) {
      return widget.onPressed != null || widget.onLongPress != null;
    }
    if (widget is IconButton) return widget.onPressed != null;
    if (widget is FloatingActionButton) return widget.onPressed != null;
    return true;
  }

  String? _labelFor(Element element, Widget widget) {
    if (widget is Tooltip) return widget.message;
    if (widget is FloatingActionButton && widget.tooltip != null) {
      return widget.tooltip;
    }
    if (widget is IconButton && widget.tooltip != null) {
      return widget.tooltip;
    }
    if (widget is IconButton) {
      final icon = _iconLabelForWidget(widget.icon);
      if (icon != null && icon.isNotEmpty) return icon;
    }
    if (widget is TextField) {
      return widget.decoration?.labelText ?? widget.decoration?.hintText;
    }
    final tooltip = _tooltipBelow(element);
    if (tooltip != null && tooltip.isNotEmpty) return tooltip;
    final own = _ownText(widget);
    if (own != null && own.trim().isNotEmpty) {
      final iconText = _iconLabelForText(own);
      return iconText ?? own.trim();
    }
    final text = _textBelow(element);
    if (text != null && text.isNotEmpty) {
      final iconText = _iconLabelForText(text);
      return iconText ?? text;
    }
    final icon = _iconLabelBelow(element);
    if (icon != null && icon.isNotEmpty) return icon;
    return null;
  }

  String? _validationMessageForFieldWidget(Widget widget) {
    if (widget is TextField) {
      return widget.decoration?.errorText;
    }
    return null;
  }

  String? _iconLabelBelow(Element element, {int depth = 0}) {
    if (depth > 4) return null;
    final widget = element.widget;
    final icon = _iconLabelForWidget(widget);
    if (icon != null) return icon;
    String? result;
    element.visitChildElements((Element child) {
      result ??= _iconLabelBelow(child, depth: depth + 1);
    });
    return result;
  }

  String? _iconLabelForWidget(Widget widget) {
    if (widget is Icon) {
      return _iconLabelForData(widget.icon);
    }
    return null;
  }

  String? _iconLabelForText(String value) {
    final trimmed = value.trim();
    if (trimmed.runes.length != 1) return null;
    return _iconLabelForCodePoint(trimmed.runes.single);
  }

  String? _iconLabelForData(IconData? icon) {
    if (icon == null) return null;
    return _iconLabelForCodePoint(icon.codePoint) ??
        'icon_${icon.codePoint.toRadixString(16)}';
  }

  String? _iconLabelForCodePoint(int codePoint) {
    bool same(IconData icon) => codePoint == icon.codePoint;

    if (same(Icons.add) || same(Icons.add_circle)) {
      return 'add';
    }
    if (same(Icons.arrow_back) ||
        same(Icons.chevron_left) ||
        codePoint == 62415) {
      return 'back';
    }
    if (same(Icons.save) || same(Icons.check) || codePoint == 62701) {
      return 'save';
    }
    if (same(Icons.copy) ||
        same(Icons.content_copy) ||
        same(Icons.file_copy) ||
        codePoint == 63026) {
      return 'duplicate';
    }
    if (same(Icons.delete) || same(Icons.delete_outline)) {
      return 'delete';
    }
    if (same(Icons.download) || same(Icons.file_download)) {
      return 'download';
    }
    if (same(Icons.search)) return 'search';
    if (same(Icons.close) || same(Icons.cancel)) {
      return 'close';
    }
    if (same(Icons.edit)) return 'edit';
    if (same(Icons.more_vert) || same(Icons.more_horiz)) {
      return 'more';
    }
    return null;
  }

  String? _tooltipBelow(Element element, {int depth = 0}) {
    if (depth > 4) return null;
    final widget = element.widget;
    if (widget is Tooltip &&
        widget.message != null &&
        widget.message!.isNotEmpty) {
      return widget.message;
    }
    String? result;
    element.visitChildElements((Element child) {
      result ??= _tooltipBelow(child, depth: depth + 1);
    });
    return result;
  }

  String? _ownText(Widget widget) {
    if (widget is Text) {
      return widget.data ?? widget.textSpan?.toPlainText();
    }
    if (widget is RichText) {
      return widget.text.toPlainText();
    }
    return null;
  }

  bool _isUsefulVisibleText(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.runes.length <= 2 &&
        !RegExp(r'[A-Za-z0-9]').hasMatch(trimmed)) {
      return false;
    }
    return true;
  }

  String? _textBelow(Element element, {int depth = 0}) {
    if (depth > 5) return null;
    final own = _ownText(element.widget);
    if (own != null && own.trim().isNotEmpty) return own.trim();
    String? result;
    element.visitChildElements((Element child) {
      result ??= _textBelow(child, depth: depth + 1);
    });
    return result;
  }

  Map<String, Object?>? _overlayFor(Element element) {
    final widget = element.widget;
    final String? kind;
    if (widget is AlertDialog || widget is SimpleDialog || widget is Dialog) {
      kind = 'dialog';
    } else if (widget is BottomSheet) {
      kind = 'bottomSheet';
    } else {
      kind = null;
    }
    if (kind == null) return null;
    final rect = _rectFor(element);
    final visibleRect = rect == null ? null : _visibleRectFor(rect);
    return {
      'kind': kind,
      'widgetType': widget.runtimeType.toString(),
      'label': _textBelow(element),
      'rect': rect == null
          ? null
          : [rect.left, rect.top, rect.width, rect.height],
      'visibleRect': visibleRect == null
          ? null
          : [
              visibleRect.left,
              visibleRect.top,
              visibleRect.width,
              visibleRect.height,
            ],
    };
  }

  String _stableId(String kind, String? label, Key? key, String widgetType) {
    final keyLabel = _keyLabel(key);
    if (keyLabel != null && keyLabel.isNotEmpty) {
      return '$kind.${_slug(keyLabel)}';
    }
    if (label != null && label.isNotEmpty) return '$kind.${_slug(label)}';
    return '$kind.${_slug(widgetType)}';
  }

  String _slug(String value) {
    return _scoutSlug(value);
  }

  String? _keyLabel(Key? key) {
    if (key is ValueKey) return key.value.toString();
    return key?.toString();
  }

  Rect? _rectFor(Element element) {
    final renderObject = element.renderObject;
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return null;
    }
    final topLeft = renderObject.localToGlobal(Offset.zero);
    return topLeft & renderObject.size;
  }

  Offset? _pointForTarget(String? target, Map<String, String> params) {
    final explicitPoint = _pointFromParams(params);
    if (explicitPoint != null) return explicitPoint;
    if (target == null || target.isEmpty) return null;
    final node = _snapshot().findNode(target);
    return node?.suggestedTapPoint;
  }

  Offset? _pointFromParams(Map<String, String> params, {String prefix = ''}) {
    final xKey = prefix.isEmpty ? 'x' : '${prefix}X';
    final yKey = prefix.isEmpty ? 'y' : '${prefix}Y';
    final x = double.tryParse(params[xKey] ?? '');
    final y = double.tryParse(params[yKey] ?? '');
    if (x != null && y != null) return Offset(x, y);
    final pointKey = prefix.isEmpty ? 'point' : prefix;
    final point = params[pointKey];
    if (point == null || !point.contains(',')) return null;
    final parts = point.split(',');
    if (parts.length != 2) return null;
    final px = double.tryParse(parts[0].trim());
    final py = double.tryParse(parts[1].trim());
    return px == null || py == null ? null : Offset(px, py);
  }

  Offset _screenCenter() {
    final logicalSize = _logicalSize();
    return Offset(logicalSize.width / 2, logicalSize.height / 2);
  }

  Size _logicalSize() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return view.physicalSize / view.devicePixelRatio;
  }

  Rect _viewportRect() => Offset.zero & _logicalSize();

  Rect? _visibleRectFor(Rect rect) {
    final visible = rect.intersect(_viewportRect());
    if (visible.width <= 0 || visible.height <= 0) return null;
    return visible;
  }

  double _visibleFraction(Rect rect, Rect? visibleRect) {
    if (visibleRect == null) return 0;
    final area = rect.width * rect.height;
    if (area <= 0) return 0;
    return (visibleRect.width * visibleRect.height / area).clamp(0, 1);
  }

  double _rectArea(Rect rect) => rect.width * rect.height;

  Offset? _visibleCenter(Rect rect) {
    final visible = _visibleRectFor(rect);
    if (visible == null) return null;
    return visible.center;
  }

  bool _hitTestable(Offset point) {
    try {
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, point, _primaryViewId);
      return result.path.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Offset _dragDelta(
    String direction,
    double distance, {
    required bool scrollGesture,
  }) {
    final sign = scrollGesture ? -1.0 : 1.0;
    return switch (direction) {
      'up' => Offset(0, -distance * sign),
      'down' => Offset(0, distance * sign),
      'left' => Offset(-distance * sign, 0),
      'right' => Offset(distance * sign, 0),
      _ => Offset(0, distance * sign),
    };
  }

  List<ScoutNode> _compactNodes(List<ScoutNode> nodes) {
    final byArea = <String, ScoutNode>{};
    for (final node in nodes) {
      final rect = node.rect;
      final areaKey = rect == null
          ? node.id
          : [
              node.kind,
              rect.left.round(),
              rect.top.round(),
              rect.width.round(),
              rect.height.round(),
            ].join(':');
      final existing = byArea[areaKey];
      if (existing == null || _nodeRank(node) > _nodeRank(existing)) {
        byArea[areaKey] = node;
      }
    }

    final seen = <String>{};
    final candidates = <ScoutNode>[];
    for (final node in byArea.values) {
      final rect = node.rect;
      final key = rect == null
          ? node.id
          : '${node.id}:${rect.center.dx.round()}:${rect.center.dy.round()}';
      if (seen.add(key)) {
        candidates.add(node);
      }
    }
    final result = _mergeNestedControls(candidates);
    result.sort((a, b) {
      final top = (a.rect?.top ?? 0).compareTo(b.rect?.top ?? 0);
      if (top != 0) return top;
      return (a.rect?.left ?? 0).compareTo(b.rect?.left ?? 0);
    });
    return result;
  }

  List<ScoutNode> _inferActionableLabels(List<ScoutNode> nodes) {
    final textNodes = nodes
        .where((node) => node.kind == 'text' && node.label != null)
        .toList(growable: false);
    return [
      for (final node in nodes)
        if ((node.kind == 'tap' || node.kind == 'btn') &&
            (node.label == null ||
                node.id == '${node.kind}.${_slug(node.widgetType)}'))
          _inferActionableLabel(node, textNodes)
        else
          node,
    ];
  }

  ScoutNode _inferActionableLabel(ScoutNode node, List<ScoutNode> textNodes) {
    final rect = node.rect;
    if (rect == null || rect.width <= 0 || rect.height <= 0) return node;
    final viewportArea = _logicalSize().width * _logicalSize().height;
    final nodeArea = rect.width * rect.height;
    if (viewportArea > 0 && nodeArea / viewportArea > 0.45) {
      return node;
    }

    final contained = [
      for (final textNode in textNodes)
        if (textNode.rect case final textRect?)
          if (rect.contains(textRect.center) &&
              textNode.visibleFraction > 0 &&
              textNode.hitTestable &&
              _isUsefulActionLabel(textNode.label!))
            textNode,
    ];
    if (contained.isEmpty) return node;

    contained.sort((a, b) {
      final actionRank = _actionLabelRank(
        b.label!,
      ).compareTo(_actionLabelRank(a.label!));
      if (actionRank != 0) return actionRank;
      return (b.rect?.width ?? 0).compareTo(a.rect?.width ?? 0);
    });
    final label = contained.first.label!;
    final kind = _buttonLikeActionLabel(label) ? 'btn' : node.kind;
    return node.copyWith(
      id: '$kind.${_slug(label)}',
      kind: kind,
      label: label,
      confidence: 0.86,
    );
  }

  bool _isUsefulActionLabel(String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return false;
    if (_iconLabelForText(trimmed) != null) return false;
    if (trimmed.runes.length == 1 && RegExp(r'^\d$').hasMatch(trimmed)) {
      return false;
    }
    return _actionLabelRank(trimmed) > 0 ||
        (trimmed.length >= 3 && RegExp(r'[A-Za-z]').hasMatch(trimmed));
  }

  bool _buttonLikeActionLabel(String label) {
    final slug = _slug(label);
    return const {
      'add',
      'add_new_order',
      'cancel',
      'cash',
      'close',
      'confirm',
      'confirm_payment',
      'continue',
      'create_order',
      'done',
      'login',
      'ok',
      'pay',
      'payment',
      'print_receipt',
      'save',
      'select_member',
      'submit',
    }.contains(slug);
  }

  int _actionLabelRank(String label) {
    final slug = _slug(label);
    if (const {
      'confirm_payment',
      'payment',
      'done',
      'create_order',
      'add_new_order',
      'select_member',
      'login',
      'continue',
      'save',
      'ok',
      'cash',
    }.contains(slug)) {
      return 100;
    }
    if (slug.startsWith('payment') || slug.startsWith('confirm')) return 90;
    if (slug.contains('order') || slug.contains('receipt')) return 80;
    if (slug.contains('pay') || slug.contains('cash')) return 70;
    if (slug.contains('add') || slug.contains('select')) return 60;
    return 10;
  }

  List<ScoutNode> _disambiguateIds(List<ScoutNode> nodes) {
    final counts = <String, int>{};
    return [
      for (final node in nodes)
        _disambiguateNode(
          node,
          counts.update(node.id, (value) => value + 1, ifAbsent: () => 1),
        ),
    ];
  }

  ScoutNode _disambiguateNode(ScoutNode node, int ordinal) {
    if (ordinal == 1) {
      return node.copyWith(baseId: node.id, ordinal: ordinal);
    }
    final id = '${node.id}_$ordinal';
    return node.copyWith(
      id: id,
      baseId: node.id,
      ordinal: ordinal,
      fallbackId:
          'i${id.hashCode.abs().toString().padLeft(8, '0').substring(0, 6)}',
    );
  }

  List<ScoutNode> _mergeNestedControls(List<ScoutNode> nodes) {
    final result = List<ScoutNode>.from(nodes);
    final indexesToRemove = <int>{};

    for (var i = 0; i < result.length; i++) {
      final node = result[i];
      if (node.kind != 'tap' || node.rect == null) continue;

      var bestButtonIndex = -1;
      var bestOverlap = 0.0;
      for (var j = 0; j < result.length; j++) {
        final candidate = result[j];
        if (candidate.kind != 'btn' || candidate.rect == null) continue;
        final overlap = _overlapRatio(node.rect!, candidate.rect!);
        if (overlap > bestOverlap) {
          bestOverlap = overlap;
          bestButtonIndex = j;
        }
      }

      if (bestButtonIndex == -1 || bestOverlap < 0.7) continue;
      final button = result[bestButtonIndex];
      if (button.label == null && node.label != null) {
        result[bestButtonIndex] = button.copyWith(
          label: node.label,
          confidence: node.confidence,
        );
      }
      indexesToRemove.add(i);
    }

    return [
      for (var i = 0; i < result.length; i++)
        if (!indexesToRemove.contains(i)) result[i],
    ];
  }

  double _overlapRatio(Rect a, Rect b) {
    final left = a.left > b.left ? a.left : b.left;
    final top = a.top > b.top ? a.top : b.top;
    final right = a.right < b.right ? a.right : b.right;
    final bottom = a.bottom < b.bottom ? a.bottom : b.bottom;
    final width = right - left;
    final height = bottom - top;
    if (width <= 0 || height <= 0) return 0;
    final intersection = width * height;
    final smaller = a.width * a.height < b.width * b.height
        ? a.width * a.height
        : b.width * b.height;
    if (smaller <= 0) return 0;
    return intersection / smaller;
  }

  int _nodeRank(ScoutNode node) {
    var rank = 0;
    if (node.kind == 'btn') rank += 20;
    if (node.widgetType == 'TextField' || node.widgetType == 'TextFormField') {
      rank += 20;
    }
    if (node.key != null) rank += 10;
    if (node.label != null) rank += 5;
    return rank;
  }

  EditableTextState? _findEditable({String? target}) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    if (target == null || target.isEmpty || target == 'focused') {
      return _focusedEditable(root);
    }

    final snapshot = _snapshot();
    final matchedNode = snapshot.findField(target);
    if (matchedNode != null) {
      final candidates = <_EditableCandidate>[];
      _walk(root, (Element element) {
        final node = _nodeFromElement(element);
        if (node == null) return;
        final sameBase =
            node.id == matchedNode.id || node.id == matchedNode.baseId;
        final sameLabel = node.label != null && node.label == matchedNode.label;
        if (!sameBase && !sameLabel) return;
        final editable = _editableStateBelow(element);
        if (editable != null) {
          candidates.add(_EditableCandidate(node: node, state: editable));
        }
      });
      for (final candidate in candidates) {
        if (_sameRect(candidate.node.rect, matchedNode.rect)) {
          return candidate.state;
        }
      }
      if (matchedNode.ordinal > 0 && matchedNode.ordinal <= candidates.length) {
        return candidates[matchedNode.ordinal - 1].state;
      }
      if (candidates.isNotEmpty) return candidates.first.state;
    }

    EditableTextState? result;
    _walk(root, (Element element) {
      if (result != null) return;
      final label = _labelFor(element, element.widget);
      if (label != null && _slug(label) == _slug(target)) {
        result = _editableStateBelow(element);
      }
    });
    return result;
  }

  bool _sameRect(Rect? a, Rect? b) {
    if (a == null || b == null) return false;
    return (a.left - b.left).abs() < 0.5 &&
        (a.top - b.top).abs() < 0.5 &&
        (a.width - b.width).abs() < 0.5 &&
        (a.height - b.height).abs() < 0.5;
  }

  _TextTargetMatch? _findVisibleTextMatch(String text) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    final wanted = text.trim();
    _TextTargetMatch? exact;
    _TextTargetMatch? contains;
    _walk(root, (Element element) {
      if (exact != null) return;
      final own = _ownText(element.widget)?.trim();
      if (own == null || own.isEmpty) return;
      final rect = _rectFor(element);
      if (rect == null || _visibleRectFor(rect) == null) return;
      final node = _nodeFromElement(element);
      if (node == null) return;
      final actionable = _nearestActionableAncestor(element);
      final match = _TextTargetMatch(text: node, actionable: actionable);
      if (own == wanted) {
        exact = match;
      } else if (wanted.length >= 3 &&
          contains == null &&
          own.toLowerCase().contains(wanted.toLowerCase())) {
        contains = match;
      }
    });
    return exact ?? contains;
  }

  List<Map<String, Object?>> _buildControlGroups(ScoutSnapshot snapshot) {
    final surface = _detectCustomInputSurface(snapshot);
    if (surface == null) return const [];
    return [surface.toControlGroupJson()];
  }

  Map<String, Object?> _buildVisualTree(
    ScoutSnapshot snapshot,
    List<Map<String, Object?>> controlGroups,
  ) {
    final children = <Map<String, Object?>>[];
    if (controlGroups.isNotEmpty) {
      children.add(_visualRegionForControlGroups(snapshot, controlGroups));
    } else if (snapshot.overlays.isNotEmpty) {
      for (final overlay in snapshot.overlays) {
        children.add(_visualRegionForOverlay(snapshot, overlay, controlGroups));
      }
    } else {
      children.addAll(_visualRows(snapshot));
    }
    return {
      'kind': 'screen',
      'label': snapshot.screen,
      'rect': [0, 0, snapshot.logicalSize.width, snapshot.logicalSize.height],
      'children': children,
    };
  }

  Map<String, Object?> _visualRegionForControlGroups(
    ScoutSnapshot snapshot,
    List<Map<String, Object?>> controlGroups,
  ) {
    final groupRects = [
      for (final group in controlGroups) ?_rectFromJsonList(group['rect']),
    ];
    final bounds = groupRects.reduce(
      (value, element) => value.expandToInclude(element),
    );
    final region = Rect.fromLTRB(
      (bounds.left - 96).clamp(0, snapshot.logicalSize.width),
      (bounds.top - 120).clamp(0, snapshot.logicalSize.height),
      (bounds.right + 96).clamp(0, snapshot.logicalSize.width),
      (bounds.bottom + 96).clamp(0, snapshot.logicalSize.height),
    );
    final horizontalBand = Rect.fromLTRB(
      region.left,
      0,
      region.right,
      snapshot.logicalSize.height,
    );
    final titleCandidates = [
      for (final node in snapshot.textTargets)
        if (node.rect case final rect?)
          if (rect.center.dy < bounds.top &&
              region.contains(rect.center) &&
              horizontalBand.contains(rect.center) &&
              rect.width >= bounds.width * 0.5 &&
              !_looksLikePureValue(node.label))
            node,
    ]..sort(_compareNodesByPosition);
    final displayCandidates = [
      for (final node in snapshot.textTargets)
        if (node.rect case final rect?)
          if (rect.center.dy < bounds.top &&
              region.contains(rect.center) &&
              _looksLikePureValue(node.label))
            node,
    ]..sort(_compareNodesByPosition);
    final actionNodes = [
      for (final node in snapshot.interactables)
        if (node.kind == 'btn' && node.label != null)
          if (node.rect case final rect?)
            if (rect.center.dy > bounds.bottom - 8 &&
                region.contains(rect.center))
              _visualNode(node, role: 'action'),
    ];
    final children = <Map<String, Object?>>[
      if (titleCandidates.isNotEmpty)
        _visualNode(titleCandidates.first, role: 'title'),
      for (final node in displayCandidates) _visualNode(node, role: 'display'),
      ...controlGroups,
      if (actionNodes.isNotEmpty) {'kind': 'actions', 'children': actionNodes},
    ];
    return {
      'kind': 'dialog',
      'label': titleCandidates.isEmpty
          ? 'custom control'
          : titleCandidates.first.label,
      'rect': _rectToJson(region),
      'children': children,
    };
  }

  Map<String, Object?> _visualRegionForOverlay(
    ScoutSnapshot snapshot,
    Map<String, Object?> overlay,
    List<Map<String, Object?>> controlGroups,
  ) {
    final rect = _rectFromJsonList(overlay['rect']);
    final textNodes = [
      for (final node in snapshot.textTargets)
        if (rect == null || _nodeInsideRect(node, rect)) node,
    ];
    textNodes.sort(_compareNodesByPosition);
    final containedGroups = [
      for (final group in controlGroups)
        if (rect == null || _rectContainsJsonRect(rect, group['rect'])) group,
    ];
    final groupedNodeIds = _nodeIdsInControlGroups(containedGroups);
    final actions = [
      for (final node in snapshot.interactables)
        if ((rect == null || _nodeInsideRect(node, rect)) &&
            node.kind == 'btn' &&
            node.label != null &&
            !groupedNodeIds.contains(node.id))
          _visualNode(node, role: 'action'),
    ];
    final children = <Map<String, Object?>>[];
    if (textNodes.isNotEmpty) {
      children.add(_visualNode(textNodes.first, role: 'title'));
    }
    for (final node in textNodes.skip(1)) {
      if (groupedNodeIds.contains(node.id)) continue;
      final label = node.label ?? '';
      children.add(
        _visualNode(
          node,
          role: _digitsOnly(label).length >= 2 ? 'display' : 'text',
        ),
      );
    }
    children.addAll(containedGroups);
    if (actions.isNotEmpty) {
      children.add({'kind': 'actions', 'children': actions});
    }
    return {
      'kind': overlay['kind'] ?? 'region',
      'label': textNodes.isEmpty ? overlay['label'] : textNodes.first.label,
      'rect': overlay['rect'],
      'children': children,
    };
  }

  List<Map<String, Object?>> _visualRows(ScoutSnapshot snapshot) {
    final nodes =
        [
            ...snapshot.fields,
            ...snapshot.interactables,
            ...snapshot.textTargets,
          ].where((node) => node.visibleFraction > 0).toList(growable: false)
          ..sort(_compareNodesByPosition);
    return [for (final node in nodes.take(60)) _visualNode(node)];
  }

  Map<String, Object?> _visualNode(ScoutNode node, {String? role}) {
    return {
      'kind': node.kind == 'btn' || node.kind == 'tap' ? 'button' : node.kind,
      'role': ?role,
      'label': node.label,
      'id': node.id,
      if (node.label != null && RegExp(r'^\d$').hasMatch(node.label!.trim()))
        'tapAlias': 'key.${node.label!.trim()}',
      'rect': _rectToJson(node.rect),
      'hitTestable': node.hitTestable,
      'enabled': node.enabled,
    };
  }

  bool _looksLikePureValue(String? label) {
    if (label == null) return false;
    final trimmed = label.trim();
    if (trimmed.isEmpty) return false;
    return RegExp(r'^[\d\s()+\-.]+$').hasMatch(trimmed) &&
        _digitsOnly(trimmed).isNotEmpty;
  }

  Set<String> _nodeIdsInControlGroups(List<Map<String, Object?>> groups) {
    final ids = <String>{};
    for (final group in groups) {
      final children = group['children'];
      if (children is! List) continue;
      for (final child in children) {
        if (child is Map && child['targetId'] is String) {
          ids.add(child['targetId'] as String);
        }
      }
    }
    return ids;
  }

  int _compareNodesByPosition(ScoutNode a, ScoutNode b) {
    final top = (a.rect?.top ?? 0).compareTo(b.rect?.top ?? 0);
    if (top != 0) return top;
    return (a.rect?.left ?? 0).compareTo(b.rect?.left ?? 0);
  }

  List<double>? _rectToJson(Rect? rect) {
    if (rect == null) return null;
    return [rect.left, rect.top, rect.width, rect.height];
  }

  Rect? _rectFromJsonList(Object? value) {
    if (value is! List || value.length != 4) return null;
    final left = _numberToDouble(value[0]);
    final top = _numberToDouble(value[1]);
    final width = _numberToDouble(value[2]);
    final height = _numberToDouble(value[3]);
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    return Rect.fromLTWH(left, top, width, height);
  }

  bool _nodeInsideRect(ScoutNode node, Rect rect) {
    final nodeRect = node.rect;
    if (nodeRect == null) return false;
    return rect.contains(nodeRect.center);
  }

  bool _rectContainsJsonRect(Rect container, Object? value) {
    final rect = _rectFromJsonList(value);
    if (rect == null) return false;
    return container.contains(rect.center);
  }

  double? _numberToDouble(Object? value) {
    if (value is int) return value.toDouble();
    if (value is double) return value;
    return null;
  }

  _CustomInputSurface? _detectCustomInputSurface(
    ScoutSnapshot snapshot, {
    String? target,
  }) {
    final digitText = <String, ScoutNode>{};
    for (final node in [...snapshot.textTargets, ...snapshot.interactables]) {
      final label = node.label?.trim();
      if (label == null || !RegExp(r'^\d$').hasMatch(label)) continue;
      if (node.visibleFraction <= 0 || !node.hitTestable) continue;
      digitText[label] = node;
    }
    if (digitText.length < 8) return null;
    if (!_looksLikeKeyGrid(digitText.values.toList(growable: false))) {
      return null;
    }

    final targetFound =
        target == null ||
        target.trim().isEmpty ||
        snapshot.textTargets.any((node) => node.matches(target)) ||
        snapshot.interactables.any((node) => node.matches(target)) ||
        snapshot.visibleText.any((text) => _slug(text) == _slug(target));
    if (!targetFound && snapshot.overlays.isEmpty) return null;

    final commitAction = _customInputCommitAction(snapshot);
    return _CustomInputSurface(
      kind: 'custom_numeric_keypad',
      label: target,
      currentValue: _visibleInputValue(snapshot, digitText.values),
      keys: digitText,
      commitAction: commitAction,
      targetMatched: targetFound,
    );
  }

  bool _looksLikeKeyGrid(List<ScoutNode> keys) {
    final centers = [
      for (final key in keys)
        if (key.rect case final rect?) rect.center,
    ];
    if (centers.length < 8) return false;
    final rows = <int>{};
    final cols = <int>{};
    for (final center in centers) {
      rows.add((center.dy / 24).round());
      cols.add((center.dx / 24).round());
    }
    return rows.length >= 3 && cols.length >= 3;
  }

  ScoutNode? _customInputCommitAction(ScoutSnapshot snapshot) {
    const commitSlugs = {
      'save',
      'done',
      'ok',
      'confirm',
      'submit',
      'continue',
      'apply',
    };
    final candidates = [
      for (final node in [...snapshot.interactables, ...snapshot.textTargets])
        if (node.label case final label?)
          if (commitSlugs.contains(_slug(label)) &&
              node.visibleFraction > 0 &&
              (node.suggestedTapPoint != null || node.rect != null))
            node,
    ];
    if (candidates.isEmpty) return null;
    candidates.sort(
      (a, b) => (b.kind == 'btn' ? 1 : 0).compareTo(a.kind == 'btn' ? 1 : 0),
    );
    return candidates.first;
  }

  String? _visibleInputValue(
    ScoutSnapshot snapshot,
    Iterable<ScoutNode> keyNodes,
  ) {
    final keyRects = [for (final key in keyNodes) ?key.rect];
    final values = <String>[];
    for (final node in snapshot.textTargets) {
      final label = node.label?.trim();
      final rect = node.rect;
      if (label == null || rect == null) continue;
      if (RegExp(r'^\d$').hasMatch(label)) continue;
      final digits = _digitsOnly(label);
      if (digits.length < 2) continue;
      final overlapsKey = keyRects.any(
        (keyRect) => _overlapRatio(rect, keyRect) > 0.2,
      );
      if (!overlapsKey) values.add(label);
    }
    if (values.isEmpty) return null;
    values.sort(
      (a, b) => _digitsOnly(b).length.compareTo(_digitsOnly(a).length),
    );
    return values.first;
  }

  String _digitsOnly(String value) => value.replaceAll(RegExp(r'\D'), '');

  List<Map<String, Object?>> _inputRecoverySuggestions(String? target) {
    return [
      {
        'intent': 'enterValue',
        if (target != null && target.isNotEmpty) 'target': target,
        'method': 'inspectThenTapControls',
        'reason':
            'No EditableText matched. If the app uses a custom keypad, picker, stepper, or similar control, use inspect visualTree/controlGroups to identify the visible buttons and tap them explicitly.',
      },
    ];
  }

  ScoutNode? _nearestActionableAncestor(Element element) {
    ScoutNode? result;
    element.visitAncestorElements((Element ancestor) {
      final node = _nodeFromElement(ancestor);
      if (node != null && node.kind != 'text' && node.kind != 'field') {
        result = node;
        return false;
      }
      return true;
    });
    return result == null ? null : _canonicalInteractable(result!);
  }

  ScoutNode _canonicalInteractable(ScoutNode target) {
    final snapshot = _snapshot();
    for (final node in snapshot.interactables) {
      if (node.label != null &&
          node.label == target.label &&
          node.rect != null &&
          target.rect != null &&
          _overlapRatio(node.rect!, target.rect!) > 0.7) {
        return node;
      }
    }
    for (final node in snapshot.interactables) {
      if (node.kind == target.kind &&
          node.label == target.label &&
          _sameRect(node.rect, target.rect)) {
        return node;
      }
    }
    for (final node in snapshot.interactables) {
      if (_sameRect(node.rect, target.rect)) {
        return node;
      }
    }
    return target;
  }

  EditableTextState? _focusedEditable(Element root) {
    EditableTextState? result;
    _walk(root, (Element element) {
      if (result != null) return;
      if (element is StatefulElement && element.state is EditableTextState) {
        final state = element.state as EditableTextState;
        if (state.widget.focusNode.hasFocus) result = state;
      }
    });
    return result;
  }

  EditableTextState? _editableStateBelow(Element element) {
    if (element is StatefulElement && element.state is EditableTextState) {
      return element.state as EditableTextState;
    }
    EditableTextState? result;
    element.visitChildElements((Element child) {
      result ??= _editableStateBelow(child);
    });
    return result;
  }

  String? _editableValueBelow(Element element) {
    final editable = _editableStateBelow(element);
    return editable?.widget.controller.text;
  }

  NavigatorState? _findActiveNavigator(Element root) {
    NavigatorState? result;
    _walk(root, (Element element) {
      if (element is StatefulElement && element.state is NavigatorState) {
        result = element.state as NavigatorState;
      }
    });
    return result;
  }

  void _setEditableText(EditableTextState state, String value) {
    state.requestKeyboard();
    state.userUpdateTextEditingValue(
      TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      ),
      SelectionChangedCause.keyboard,
    );
  }

  Future<void> _dispatchTap(Offset point) async {
    await _dispatchPress(point, hold: const Duration(milliseconds: 30));
  }

  Future<void> _dispatchPress(Offset point, {required Duration hold}) async {
    final binding = GestureBinding.instance;
    final pointer = _nextSyntheticPointer++;
    final viewId = _primaryViewId;
    binding.handlePointerEvent(
      PointerAddedEvent(
        pointer: pointer,
        device: pointer,
        position: point,
        kind: PointerDeviceKind.touch,
        viewId: viewId,
      ),
    );
    binding.handlePointerEvent(
      PointerDownEvent(
        pointer: pointer,
        device: pointer,
        position: point,
        kind: PointerDeviceKind.touch,
        buttons: kPrimaryButton,
        viewId: viewId,
      ),
    );
    await Future<void>.delayed(hold);
    binding.handlePointerEvent(
      PointerUpEvent(
        pointer: pointer,
        device: pointer,
        position: point,
        kind: PointerDeviceKind.touch,
        viewId: viewId,
      ),
    );
    binding.handlePointerEvent(
      PointerRemovedEvent(
        pointer: pointer,
        device: pointer,
        position: point,
        kind: PointerDeviceKind.touch,
        viewId: viewId,
      ),
    );
  }

  Future<void> _dispatchDrag(Offset start, Offset delta) async {
    final binding = GestureBinding.instance;
    final pointer = _nextSyntheticPointer++;
    final viewId = _primaryViewId;
    binding.handlePointerEvent(
      PointerAddedEvent(
        pointer: pointer,
        device: pointer,
        position: start,
        kind: PointerDeviceKind.touch,
        viewId: viewId,
      ),
    );
    binding.handlePointerEvent(
      PointerDownEvent(
        pointer: pointer,
        device: pointer,
        position: start,
        kind: PointerDeviceKind.touch,
        buttons: kPrimaryButton,
        viewId: viewId,
      ),
    );
    const steps = 8;
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      binding.handlePointerEvent(
        PointerMoveEvent(
          pointer: pointer,
          device: pointer,
          position: start + delta * (i / steps),
          delta: delta / steps.toDouble(),
          kind: PointerDeviceKind.touch,
          buttons: kPrimaryButton,
          viewId: viewId,
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 16));
    binding.handlePointerEvent(
      PointerUpEvent(
        pointer: pointer,
        device: pointer,
        position: start + delta,
        kind: PointerDeviceKind.touch,
        viewId: viewId,
      ),
    );
    binding.handlePointerEvent(
      PointerRemovedEvent(
        pointer: pointer,
        device: pointer,
        position: start + delta,
        kind: PointerDeviceKind.touch,
        viewId: viewId,
      ),
    );
  }

  int get _primaryViewId {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    return views.isEmpty ? 0 : views.first.viewId;
  }

  void _walk(Element element, void Function(Element element) visitor) {
    visitor(element);
    element.visitChildElements((Element child) => _walk(child, visitor));
  }

  bool _changed(ScoutSnapshot before, ScoutSnapshot after) =>
      jsonEncode(before.summaryJson()) != jsonEncode(after.summaryJson()) ||
      _geometryChanged(before, after);

  bool _geometryChanged(ScoutSnapshot before, ScoutSnapshot after) {
    return _changedGeometryIds(before, after).isNotEmpty;
  }

  Map<String, Object?> _delta(ScoutSnapshot before, ScoutSnapshot after) {
    final beforeText = before.visibleText.toSet();
    final afterText = after.visibleText.toSet();
    final beforeFields = before.fields.map((node) => node.id).toSet();
    final afterFields = after.fields.map((node) => node.id).toSet();
    final beforeActions = before.interactables.map((node) => node.id).toSet();
    final afterActions = after.interactables.map((node) => node.id).toSet();
    final beforeFieldValues = {
      for (final node in before.fields) node.id: node.value,
    };
    final afterFieldValues = {
      for (final node in after.fields) node.id: node.value,
    };
    final beforeValidationMessages = {
      for (final node in before.fields) node.id: node.validationMessage,
    };
    final afterValidationMessages = {
      for (final node in after.fields) node.id: node.validationMessage,
    };
    final changedGeometry = _changedGeometryIds(before, after);
    return {
      'screenChanged': before.screen != after.screen,
      'newText': afterText.difference(beforeText).toList(growable: false),
      'removedText': beforeText.difference(afterText).toList(growable: false),
      'newFields': afterFields.difference(beforeFields).toList(growable: false),
      'removedFields': beforeFields
          .difference(afterFields)
          .toList(growable: false),
      'changedFields': [
        for (final id in afterFields.intersection(beforeFields))
          if (beforeFieldValues[id] != afterFieldValues[id]) id,
      ],
      'newValidationMessages': [
        for (final id in afterFields)
          if ((afterValidationMessages[id] ?? '').isNotEmpty &&
              beforeValidationMessages[id] != afterValidationMessages[id])
            {
              'field': id,
              'label': after.fields.firstWhere((node) => node.id == id).label,
              'message': afterValidationMessages[id],
            },
      ],
      'validationCandidates': [
        for (final id in afterFields)
          if ((afterValidationMessages[id] ?? '').isNotEmpty)
            {
              'field': id,
              'label': after.fields.firstWhere((node) => node.id == id).label,
              'message': afterValidationMessages[id],
            },
      ],
      'changedGeometry': changedGeometry,
      'newInteractables': afterActions
          .difference(beforeActions)
          .toList(growable: false),
      'removedInteractables': beforeActions
          .difference(afterActions)
          .toList(growable: false),
    };
  }

  List<String> _changedGeometryIds(ScoutSnapshot before, ScoutSnapshot after) {
    final beforeNodes = {
      for (final node in [...before.fields, ...before.interactables])
        node.id: node,
    };
    final afterNodes = {
      for (final node in [...after.fields, ...after.interactables])
        node.id: node,
    };
    final changed = <String>[];
    for (final id in beforeNodes.keys) {
      final previous = beforeNodes[id];
      final current = afterNodes[id];
      if (previous == null || current == null) continue;
      if (!_sameRect(previous.rect, current.rect) ||
          (previous.visibleFraction - current.visibleFraction).abs() > 0.01) {
        changed.add(id);
      }
    }
    return changed;
  }

  developer.ServiceExtensionResponse _ok(Map<String, Object?> value) {
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'ok': true, ...value}),
    );
  }

  developer.ServiceExtensionResponse _fail(
    String code,
    String message, {
    Map<String, Object?> extra = const {},
  }) {
    return developer.ServiceExtensionResponse.result(
      jsonEncode({
        'ok': false,
        'error': {'code': code, 'message': message},
        ...extra,
        'recentErrors': _recentErrors(),
      }),
    );
  }
}

class _FlutterScoutAnnotationOverlay extends StatefulWidget {
  const _FlutterScoutAnnotationOverlay({required this.runtime});

  final FlutterScoutRuntime runtime;

  @override
  State<_FlutterScoutAnnotationOverlay> createState() =>
      _FlutterScoutAnnotationOverlayState();
}

class _FlutterScoutAnnotationOverlayState
    extends State<_FlutterScoutAnnotationOverlay> {
  final TextEditingController _commentController = TextEditingController();
  ScoutAnnotationTarget? _selectedTarget;
  List<ScoutAnnotationTarget> _currentCandidates = const [];
  List<ScoutAnnotationTarget> _visibleTargets = const [];
  Offset? _toggleButtonOffset;
  Offset? _lastTapPoint;
  int _candidateIndex = 0;
  int _lastCollectedRevision = -1;
  bool _targetRefreshScheduled = false;

  static const double _toggleButtonMargin = 12;
  static const double _toggleButtonHeight = 48;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  void _toggleAnnotationMode() {
    widget.runtime._setAnnotationMode(!widget.runtime._annotationMode);
    if (!widget.runtime._annotationMode) {
      setState(() {
        _selectedTarget = null;
        _currentCandidates = const [];
        _commentController.clear();
      });
    }
  }

  void _selectAt(Offset point) {
    final candidates = widget.runtime.annotationCandidatesAt(point);
    if (candidates.isEmpty) {
      setState(() {
        _selectedTarget = null;
        _currentCandidates = const [];
        _commentController.clear();
        _lastTapPoint = point;
        _candidateIndex = 0;
      });
      return;
    }

    var index = 0;
    final last = _lastTapPoint;
    if (last != null && (last - point).distance <= 12) {
      index = (_candidateIndex + 1) % candidates.length;
    }
    setState(() {
      _lastTapPoint = point;
      _candidateIndex = index;
      _currentCandidates = candidates;
      _selectedTarget = candidates[index];
      _commentController.clear();
    });
  }

  void _saveComment() {
    final target = _selectedTarget;
    final comment = _commentController.text.trim();
    if (target == null || comment.isEmpty) return;
    widget.runtime.addAnnotation(target: target, comment: comment);
    setState(() {
      _selectedTarget = null;
      _currentCandidates = const [];
      _commentController.clear();
    });
  }

  void _scheduleTargetRefresh(int revision) {
    if (_targetRefreshScheduled || _lastCollectedRevision == revision) return;
    _targetRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final enabled = widget.runtime._annotationMode;
      final targets = enabled
          ? widget.runtime.visibleAnnotationTargets()
          : const <ScoutAnnotationTarget>[];
      setState(() {
        _targetRefreshScheduled = false;
        _lastCollectedRevision = revision;
        _visibleTargets = targets;
      });
    });
  }

  void _moveToggleButton(DragUpdateDetails details, BuildContext context) {
    final current = _resolvedToggleButtonOffset(context);
    setState(() {
      _toggleButtonOffset = _clampedToggleButtonOffset(
        context,
        current + details.delta,
      );
    });
  }

  Offset _resolvedToggleButtonOffset(BuildContext context) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final defaultOffset = Offset(
      size.width - _toggleButtonWidth - _toggleButtonMargin,
      media.padding.top + _toggleButtonMargin,
    );
    return _clampedToggleButtonOffset(
      context,
      _toggleButtonOffset ?? defaultOffset,
    );
  }

  Offset _clampedToggleButtonOffset(BuildContext context, Offset offset) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final minLeft = _toggleButtonMargin;
    final minTop = media.padding.top + _toggleButtonMargin;
    final maxLeft = (size.width - _toggleButtonWidth - _toggleButtonMargin)
        .clamp(minLeft, double.infinity);
    final maxTop =
        (size.height -
                _toggleButtonHeight -
                media.padding.bottom -
                _toggleButtonMargin)
            .clamp(minTop, double.infinity);
    return Offset(
      offset.dx.clamp(minLeft, maxLeft),
      offset.dy.clamp(minTop, maxTop),
    );
  }

  double get _toggleButtonWidth {
    final count = widget.runtime._activeAnnotationCount;
    if (count == 0) return 56;
    return 74 + (count.toString().length * 8);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.runtime._annotationRevision,
      builder: (context, revision, child) {
        final enabled = widget.runtime._annotationMode;
        final toggleButtonOffset = _resolvedToggleButtonOffset(context);
        if (enabled) {
          _scheduleTargetRefresh(revision);
        } else if (_visibleTargets.isNotEmpty) {
          _scheduleTargetRefresh(revision);
        }
        return Stack(
          children: [
            if (enabled)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) => _selectAt(details.localPosition),
                  child: CustomPaint(
                    painter: _FlutterScoutAnnotationPainter(
                      targets: _visibleTargets,
                      annotationPinRects: widget.runtime._annotationPinRects(
                        _visibleTargets,
                      ),
                      selectedTarget: _selectedTarget,
                      colorScheme: Theme.of(context).colorScheme,
                      annotationRevision: revision,
                    ),
                  ),
                ),
              ),
            if (enabled && _selectedTarget != null)
              _AnnotationCommentPanel(
                target: _selectedTarget!,
                candidateIndex: _candidateIndex,
                candidateCount: _currentCandidates.length,
                controller: _commentController,
                onCancel: () {
                  setState(() {
                    _selectedTarget = null;
                    _currentCandidates = const [];
                    _commentController.clear();
                  });
                },
                onSave: _saveComment,
              ),
            Positioned(
              left: toggleButtonOffset.dx,
              top: toggleButtonOffset.dy,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanUpdate: (details) => _moveToggleButton(details, context),
                child: _AnnotationToggleButton(
                  enabled: enabled,
                  count: widget.runtime._activeAnnotationCount,
                  onPressed: _toggleAnnotationMode,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AnnotationToggleButton extends StatelessWidget {
  const _AnnotationToggleButton({
    required this.enabled,
    required this.count,
    required this.onPressed,
  });

  final bool enabled;
  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: enabled ? scheme.primary : scheme.surface,
      elevation: 6,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.edit_note,
                color: enabled ? scheme.onPrimary : scheme.onSurface,
              ),
              if (count > 0) ...[
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: enabled ? scheme.onPrimary : scheme.onSurface,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AnnotationCommentPanel extends StatelessWidget {
  const _AnnotationCommentPanel({
    required this.target,
    required this.candidateIndex,
    required this.candidateCount,
    required this.controller,
    required this.onCancel,
    required this.onSave,
  });

  final ScoutAnnotationTarget target;
  final int candidateIndex;
  final int candidateCount;
  final TextEditingController controller;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Positioned(
      left: 12,
      right: 12,
      bottom: MediaQuery.paddingOf(context).bottom + 12,
      child: Material(
        color: scheme.surface,
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                target.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                '${target.widgetType} - ${candidateIndex + 1} of $candidateCount',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Comment',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.newline,
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: onCancel, child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: onSave,
                    icon: const Icon(Icons.check),
                    label: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FlutterScoutAnnotationPainter extends CustomPainter {
  const _FlutterScoutAnnotationPainter({
    required this.targets,
    required this.annotationPinRects,
    required this.selectedTarget,
    required this.colorScheme,
    required this.annotationRevision,
  });

  final List<ScoutAnnotationTarget> targets;
  final List<Rect> annotationPinRects;
  final ScoutAnnotationTarget? selectedTarget;
  final ColorScheme colorScheme;
  final int annotationRevision;

  @override
  void paint(Canvas canvas, Size size) {
    final scrim = Paint()..color = colorScheme.scrim.withValues(alpha: 0.08);
    canvas.drawRect(Offset.zero & size, scrim);

    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = colorScheme.primary.withValues(alpha: 0.28);
    for (final target in targets.take(220)) {
      canvas.drawRect(target.rect, outline);
    }

    final selected = selectedTarget;
    if (selected != null) {
      final selectedPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = colorScheme.primary;
      canvas.drawRect(selected.rect, selectedPaint);
    }

    final pinPaint = Paint()..color = colorScheme.tertiary;
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );
    for (var i = 0; i < annotationPinRects.length; i++) {
      final rect = annotationPinRects[i];
      final center = Offset(rect.left + 10, rect.top + 10);
      canvas.drawCircle(center, 10, pinPaint);
      textPainter.text = TextSpan(
        text: '${i + 1}',
        style: TextStyle(
          color: colorScheme.onTertiary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      );
      textPainter.layout(minWidth: 20, maxWidth: 20);
      textPainter.paint(canvas, center - const Offset(10, 7));
    }
  }

  @override
  bool shouldRepaint(covariant _FlutterScoutAnnotationPainter oldDelegate) {
    return oldDelegate.targets != targets ||
        oldDelegate.annotationPinRects != annotationPinRects ||
        oldDelegate.selectedTarget != selectedTarget ||
        oldDelegate.colorScheme != colorScheme ||
        oldDelegate.annotationRevision != annotationRevision;
  }
}

class ScoutSnapshot {
  const ScoutSnapshot({
    required this.screen,
    required this.routeGuess,
    required this.idle,
    required this.devicePixelRatio,
    required this.logicalSize,
    required this.visibleText,
    required this.hitTestableText,
    required this.offscreenText,
    required this.interactables,
    required this.fields,
    required this.textTargets,
    required this.scrollables,
    required this.overlays,
    required this.visualTree,
    required this.controlGroups,
    required this.suggestedActions,
    required this.recentErrors,
  });

  final String screen;
  final String? routeGuess;
  final bool idle;
  final double devicePixelRatio;
  final Size logicalSize;
  final List<String> visibleText;
  final List<String> hitTestableText;
  final List<String> offscreenText;
  final List<ScoutNode> interactables;
  final List<ScoutNode> fields;
  final List<ScoutNode> textTargets;
  final List<Map<String, Object?>> scrollables;
  final List<Map<String, Object?>> overlays;
  final Map<String, Object?>? visualTree;
  final List<Map<String, Object?>> controlGroups;
  final List<Map<String, Object?>> suggestedActions;
  final List<Map<String, Object?>> recentErrors;

  ScoutSnapshot copyWith({
    Map<String, Object?>? visualTree,
    List<Map<String, Object?>>? controlGroups,
    List<Map<String, Object?>>? suggestedActions,
  }) {
    return ScoutSnapshot(
      screen: screen,
      routeGuess: routeGuess,
      idle: idle,
      devicePixelRatio: devicePixelRatio,
      logicalSize: logicalSize,
      visibleText: visibleText,
      hitTestableText: hitTestableText,
      offscreenText: offscreenText,
      interactables: interactables,
      fields: fields,
      textTargets: textTargets,
      scrollables: scrollables,
      overlays: overlays,
      visualTree: visualTree ?? this.visualTree,
      controlGroups: controlGroups ?? this.controlGroups,
      suggestedActions: suggestedActions ?? this.suggestedActions,
      recentErrors: recentErrors,
    );
  }

  ScoutNode? findNode(String target) {
    for (final node in [...interactables, ...fields, ...textTargets]) {
      if (node.matches(target)) return node;
    }
    return null;
  }

  ScoutNode? findField(String target) {
    for (final node in fields) {
      if (node.matches(target)) return node;
    }
    return null;
  }

  Map<String, Object?> summaryJson() {
    return {
      'screen': screen,
      'routeGuess': routeGuess,
      'idle': idle,
      'devicePixelRatio': devicePixelRatio,
      'logicalSize': [logicalSize.width, logicalSize.height],
      'visibleText': visibleText,
      'hitTestableText': hitTestableText,
      'offscreenText': offscreenText,
      if (visualTree != null) 'visualTree': visualTree,
      if (controlGroups.isNotEmpty) 'controlGroups': controlGroups,
      if (suggestedActions.isNotEmpty) 'suggestedActions': suggestedActions,
      'fieldValues': {for (final field in fields) field.id: field.value},
      'fieldsById': {
        for (final field in fields)
          field.id: {
            'label': field.label,
            'value': field.value,
            if (field.validationMessage != null)
              'validationMessage': field.validationMessage,
            'baseId': field.baseId,
            'ordinal': field.ordinal,
          },
      },
    };
  }

  Map<String, Object?> toJson() {
    return {
      ...summaryJson(),
      'interactables': interactables
          .map((node) => node.toJson())
          .toList(growable: false),
      'fields': fields.map((node) => node.toJson()).toList(growable: false),
      'textTargets': textTargets
          .map((node) => node.toJson())
          .toList(growable: false),
      'scrollables': scrollables,
      'overlays': overlays,
      if (visualTree != null) 'visualTree': visualTree,
      if (controlGroups.isNotEmpty) 'controlGroups': controlGroups,
      if (suggestedActions.isNotEmpty) 'suggestedActions': suggestedActions,
      'keyboard': {'visible': false},
      'recentErrors': recentErrors,
    };
  }
}

class ScoutNode {
  const ScoutNode({
    required this.id,
    required this.baseId,
    required this.ordinal,
    required this.fallbackId,
    required this.kind,
    required this.label,
    required this.value,
    required this.validationMessage,
    required this.widgetType,
    required this.key,
    required this.rect,
    required this.visibleRect,
    required this.visibleFraction,
    required this.suggestedTapPoint,
    required this.hitTestable,
    required this.enabled,
    required this.confidence,
  });

  final String id;
  final String baseId;
  final int ordinal;
  final String fallbackId;
  final String kind;
  final String? label;
  final String? value;
  final String? validationMessage;
  final String widgetType;
  final String? key;
  final Rect? rect;
  final Rect? visibleRect;
  final double visibleFraction;
  final Offset? suggestedTapPoint;
  final bool hitTestable;
  final bool enabled;
  final double confidence;

  ScoutNode copyWith({
    String? id,
    String? baseId,
    int? ordinal,
    String? fallbackId,
    String? kind,
    String? label,
    String? value,
    String? validationMessage,
    double? confidence,
  }) {
    return ScoutNode(
      id: id ?? this.id,
      baseId: baseId ?? this.baseId,
      ordinal: ordinal ?? this.ordinal,
      fallbackId: fallbackId ?? this.fallbackId,
      kind: kind ?? this.kind,
      label: label ?? this.label,
      value: value ?? this.value,
      validationMessage: validationMessage ?? this.validationMessage,
      widgetType: widgetType,
      key: key,
      rect: rect,
      visibleRect: visibleRect,
      visibleFraction: visibleFraction,
      suggestedTapPoint: suggestedTapPoint,
      hitTestable: hitTestable,
      enabled: enabled,
      confidence: confidence ?? this.confidence,
    );
  }

  bool matches(String target) {
    final normalized = target.trim();
    if (id == normalized ||
        fallbackId == normalized ||
        key == normalized ||
        label == normalized) {
      return true;
    }
    final slug = _scoutSlug(normalized);
    final kindlessSlug = _scoutSlug(
      normalized.contains('.') ? normalized.split('.').last : normalized,
    );
    if (label != null &&
        RegExp(r'^\d$').hasMatch(label!.trim()) &&
        normalized == 'key.${label!.trim()}') {
      return true;
    }
    return id.endsWith('.$slug') || id.endsWith('.$kindlessSlug');
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'baseId': baseId,
      'ordinal': ordinal,
      'fallbackId': fallbackId,
      'kind': kind,
      'label': label,
      if (kind == 'field') 'value': value,
      if (kind == 'field' && validationMessage != null)
        'validationMessage': validationMessage,
      'widgetType': widgetType,
      'key': key,
      'rect': rect == null
          ? null
          : [rect!.left, rect!.top, rect!.width, rect!.height],
      'visibleRect': visibleRect == null
          ? null
          : [
              visibleRect!.left,
              visibleRect!.top,
              visibleRect!.width,
              visibleRect!.height,
            ],
      'visibleFraction': visibleFraction,
      'partiallyOffscreen': visibleFraction > 0 && visibleFraction < 1,
      'offscreen': visibleFraction == 0,
      'suggestedTapPoint': suggestedTapPoint == null
          ? null
          : [suggestedTapPoint!.dx, suggestedTapPoint!.dy],
      'hitTestable': hitTestable,
      'enabled': enabled,
      'confidence': confidence,
    };
  }
}

class ScoutAnnotation {
  ScoutAnnotation({
    required this.id,
    required this.createdAt,
    required this.comment,
    required this.status,
    required this.target,
  });

  final String id;
  final DateTime createdAt;
  final String comment;
  String status;
  final ScoutAnnotationTarget target;
  DateTime? updatedAt;
  String? note;

  bool get isActive => status == 'open' || status == 'stale_target';

  Map<String, Object?> toJson({ScoutAnnotationTarget? liveTarget}) {
    final targetJson = target.toJson();
    final snapshotRect = target.rectJson;
    final liveRect = liveTarget?.rectJson;
    final geometryDelta = liveTarget == null
        ? null
        : <String, Object?>{
            'left': liveTarget.rect.left - target.rect.left,
            'top': liveTarget.rect.top - target.rect.top,
            'width': liveTarget.rect.width - target.rect.width,
            'height': liveTarget.rect.height - target.rect.height,
          };
    targetJson.addAll({
      'snapshotRect': snapshotRect,
      'liveMatched': liveTarget != null,
      if (liveTarget != null) ...{
        'liveRect': liveRect,
        'liveVisibleRect': liveTarget.visibleRectJson,
        'liveTarget': liveTarget.toJson(),
        'geometryChanged': !_sameRect(target.rect, liveTarget.rect),
        'geometryDelta': geometryDelta,
      },
    });
    return {
      'id': id,
      'createdAt': createdAt.toIso8601String(),
      if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
      'comment': comment,
      'status': status,
      if (note != null) 'note': note,
      'liveStatus': status == 'open' && liveTarget == null
          ? 'stale_target'
          : status,
      'target': targetJson,
    };
  }

  bool _sameRect(Rect a, Rect b) {
    return a.left == b.left &&
        a.top == b.top &&
        a.width == b.width &&
        a.height == b.height;
  }
}

class ScoutAnnotationTarget {
  const ScoutAnnotationTarget({
    required this.id,
    required this.stableId,
    required this.kind,
    required this.widgetType,
    required this.key,
    required this.label,
    required this.text,
    required this.screen,
    required this.routeGuess,
    required this.rect,
    required this.visibleRect,
    required this.visibleFraction,
    required this.depth,
    required this.ancestorSummary,
    required this.scoutNodeId,
  });

  final String id;
  final String stableId;
  final String kind;
  final String widgetType;
  final String? key;
  final String? label;
  final String? text;
  final String screen;
  final String? routeGuess;
  final Rect rect;
  final Rect visibleRect;
  final double visibleFraction;
  final int depth;
  final List<String> ancestorSummary;
  final String? scoutNodeId;

  String get displayName {
    final value = label ?? text ?? key ?? widgetType;
    return '$kind.$value';
  }

  List<double> get rectJson => [rect.left, rect.top, rect.width, rect.height];

  List<double> get visibleRectJson => [
    visibleRect.left,
    visibleRect.top,
    visibleRect.width,
    visibleRect.height,
  ];

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'stableId': stableId,
      'kind': kind,
      'widgetType': widgetType,
      'key': key,
      'label': label,
      'text': text,
      'screen': screen,
      'routeGuess': routeGuess,
      'rect': rectJson,
      'visibleRect': visibleRectJson,
      'visibleFraction': visibleFraction,
      'depth': depth,
      'ancestorSummary': ancestorSummary,
      if (scoutNodeId != null) 'scoutNodeId': scoutNodeId,
    };
  }
}

class _EditableCandidate {
  const _EditableCandidate({required this.node, required this.state});

  final ScoutNode node;
  final EditableTextState state;
}

class _TextTargetMatch {
  const _TextTargetMatch({required this.text, required this.actionable});

  final ScoutNode text;
  final ScoutNode? actionable;
}

class _CustomInputSurface {
  const _CustomInputSurface({
    required this.kind,
    required this.label,
    required this.currentValue,
    required this.keys,
    required this.commitAction,
    required this.targetMatched,
  });

  final String kind;
  final String? label;
  final String? currentValue;
  final Map<String, ScoutNode> keys;
  final ScoutNode? commitAction;
  final bool targetMatched;

  Map<String, Object?> toControlGroupJson() {
    final keyNodes = keys.values.toList(growable: false)
      ..sort((a, b) {
        final top = (a.rect?.top ?? 0).compareTo(b.rect?.top ?? 0);
        if (top != 0) return top;
        return (a.rect?.left ?? 0).compareTo(b.rect?.left ?? 0);
      });
    final allRects = [
      for (final node in [...keyNodes, ?commitAction])
        if (node.rect != null) node.rect!,
    ];
    final bounds = allRects.isEmpty
        ? null
        : allRects.reduce((value, element) => value.expandToInclude(element));
    return {
      'id': 'group.${kind.replaceAll('_', '.')}',
      'kind': 'controlGroup',
      'subtype': 'numeric_keypad',
      if (label != null && label!.isNotEmpty) 'label': label,
      'layout': 'grid',
      if (bounds != null)
        'rect': [bounds.left, bounds.top, bounds.width, bounds.height],
      if (currentValue != null && currentValue!.isNotEmpty)
        'currentValue': currentValue,
      'acceptedCharacters': 'digits',
      'targetMatched': targetMatched,
      'children': [
        for (final node in keyNodes)
          {
            'kind': 'button',
            'role': 'key',
            'label': node.label,
            'id': 'key.${node.label}',
            'targetId': node.id,
            'rect': node.rect == null
                ? null
                : [
                    node.rect!.left,
                    node.rect!.top,
                    node.rect!.width,
                    node.rect!.height,
                  ],
            if (node.suggestedTapPoint != null)
              'suggestedTapPoint': [
                node.suggestedTapPoint!.dx,
                node.suggestedTapPoint!.dy,
              ],
          },
      ],
      if (commitAction != null)
        'actions': [
          {
            'kind': 'button',
            'role': 'commit',
            'label': commitAction!.label,
            'id': commitAction!.id,
            'rect': commitAction!.rect == null
                ? null
                : [
                    commitAction!.rect!.left,
                    commitAction!.rect!.top,
                    commitAction!.rect!.width,
                    commitAction!.rect!.height,
                  ],
          },
        ],
      'suggestedAction': {
        'intent': 'enterValue',
        'method': 'tapSequence',
        'description':
            'Tap the key children matching the desired value, then tap the commit action if present.',
      },
    };
  }
}

class _ActionSnapshotResult {
  const _ActionSnapshotResult({
    required this.snapshot,
    required this.stable,
    this.lateChangeObserved = false,
    this.waitTimedOut = false,
  });

  final ScoutSnapshot snapshot;
  final bool stable;
  final bool lateChangeObserved;
  final bool waitTimedOut;
}

String _scoutSlug(String value) {
  final slug = value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_');
  return slug.replaceAll(RegExp(r'^_|_$'), '');
}
