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
  int _nextSyntheticPointer = 1000000;
  FlutterExceptionHandler? _previousFlutterError;
  ui.ErrorCallback? _previousPlatformError;

  void install() {
    _installErrorHooks();
    _registerExtension('ext.flutter_scout.inspect', _handleInspect);
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
    final error = <String, Object?>{
      'type': type,
      'message': message,
      'timestamp': DateTime.now().toIso8601String(),
    };
    if (library != null) {
      error['library'] = library;
    }
    _errors.add(error);
    if (_errors.length > 30) {
      _errors.removeRange(0, _errors.length - 30);
    }
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
      return _ok(_snapshot().toJson());
    } catch (error) {
      return _fail('inspect_failed', error.toString());
    }
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
        point = node?.suggestedTapPoint ?? node?.rect?.center;
      } else if (x != null && y != null) {
        point = Offset(x, y);
      }

      if (point == null) {
        return _fail(
          'target_not_found',
          'No tappable target matched `$target`.',
        );
      }

      await _dispatchTap(point);
      final stable = await _waitStableForAction(params);
      final after = _snapshot();
      final changed = _changed(before, after);
      return _ok({
        'action': 'tap ${target ?? '${point.dx},${point.dy}'}',
        'stable': stable,
        'result': changed ? 'changed' : 'activated_no_observed_change',
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
        'recentErrors': _errors,
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
      if (match.actionable == null) {
        return _fail(
          'text_not_actionable',
          'Text `$text` is visible, but no actionable ancestor was found.',
        );
      }
      final rect = match.actionable!.rect;
      if (rect == null) {
        return _fail('text_has_no_rect', 'Text `$text` has no usable rect.');
      }
      final point = match.actionable!.suggestedTapPoint ?? rect.center;
      await _dispatchTap(point);
      final stable = await _waitStableForAction(params);
      final after = _snapshot();
      final changed = _changed(before, after);
      return _ok({
        'action': 'tap-text $text',
        'stable': stable,
        'result': changed ? 'changed' : 'activated_no_observed_change',
        'target': match.actionable!.toJson(),
        'textTarget': match.text.toJson(),
        'activation': {
          'dispatched': true,
          'observedChange': changed,
          'strategy': match.actionable!.id == match.text.id
              ? 'text_target'
              : 'nearest_actionable_ancestor',
        },
        if (!changed)
          'warnings': const [
            'tap-text activated the nearest actionable target, but no synchronous UI change was observed before the wait timeout.',
          ],
        'before': before.summaryJson(),
        'after': after.summaryJson(),
        'delta': _delta(before, after),
        'recentErrors': _errors,
      });
    } catch (error) {
      return _fail('tap_text_failed', error.toString());
    }
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
        return _fail('field_not_found', 'No editable field matched `$target`.');
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
        'recentErrors': _errors,
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
        'recentErrors': _errors,
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
        'recentErrors': _errors,
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
        'recentErrors': _errors,
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
      'recentErrors': _errors,
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
    return _ok({
      'action': action,
      'stable': stable,
      'result': changed ? 'changed' : 'unchanged',
      'gestureStart': [start.dx, start.dy],
      if (!changed)
        'unchangedReason': _viewportRect().contains(start)
            ? 'no_visible_change_after_gesture'
            : 'gesture_start_outside_viewport',
      'before': before.summaryJson(),
      'after': after.summaryJson(),
      'delta': _delta(before, after),
      'recentErrors': _errors,
    });
  }

  ScoutSnapshot _snapshot() {
    final root = WidgetsBinding.instance.rootElement;
    final nodes = <ScoutNode>[];
    final scrollables = <Map<String, Object?>>[];
    final overlays = <Map<String, Object?>>[];
    final visibleText = <String>{};
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
          visibleText.add(text.trim());
        }
      });
    }

    final compactNodes = _disambiguateIds(_compactNodes(nodes));
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
    return ScoutSnapshot(
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
      interactables: interactables,
      fields: fields,
      textTargets: textTargets,
      scrollables: scrollables,
      overlays: overlays,
      recentErrors: List<Map<String, Object?>>.from(_errors),
    );
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
    if (widget is TextField) {
      return widget.decoration?.labelText ?? widget.decoration?.hintText;
    }
    final tooltip = _tooltipBelow(element);
    if (tooltip != null && tooltip.isNotEmpty) return tooltip;
    final own = _ownText(widget);
    if (own != null && own.trim().isNotEmpty) return own.trim();
    return _textBelow(element);
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
    final slug = value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return slug.replaceAll(RegExp(r'^_|_$'), '');
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
    return node?.suggestedTapPoint ?? node?.rect?.center;
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

  developer.ServiceExtensionResponse _fail(String code, String message) {
    return developer.ServiceExtensionResponse.result(
      jsonEncode({
        'ok': false,
        'error': {'code': code, 'message': message},
        'recentErrors': _errors,
      }),
    );
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
    required this.interactables,
    required this.fields,
    required this.textTargets,
    required this.scrollables,
    required this.overlays,
    required this.recentErrors,
  });

  final String screen;
  final String? routeGuess;
  final bool idle;
  final double devicePixelRatio;
  final Size logicalSize;
  final List<String> visibleText;
  final List<ScoutNode> interactables;
  final List<ScoutNode> fields;
  final List<ScoutNode> textTargets;
  final List<Map<String, Object?>> scrollables;
  final List<Map<String, Object?>> overlays;
  final List<Map<String, Object?>> recentErrors;

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
      'fieldValues': {for (final field in fields) field.id: field.value},
      'fieldsById': {
        for (final field in fields)
          field.id: {
            'label': field.label,
            'value': field.value,
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
    String? label,
    String? value,
    double? confidence,
  }) {
    return ScoutNode(
      id: id ?? this.id,
      baseId: baseId ?? this.baseId,
      ordinal: ordinal ?? this.ordinal,
      fallbackId: fallbackId ?? this.fallbackId,
      kind: kind,
      label: label ?? this.label,
      value: value ?? this.value,
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
    final slug = normalized
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return id.endsWith('.$slug');
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
