import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class FlutterScoutBinding {
  FlutterScoutBinding._();

  static bool _initialized = false;
  static final FlutterScoutRuntime _runtime = FlutterScoutRuntime();

  static void ensureInitialized() {
    WidgetsFlutterBinding.ensureInitialized();
    if (_initialized) return;
    _initialized = true;
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
        point = node?.rect?.center;
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
      return _ok({
        'action': 'tap ${target ?? '${point.dx},${point.dy}'}',
        'stable': stable,
        'result': _changed(before, after) ? 'changed' : 'unchanged',
        'target': node?.toJson(),
        'before': before.summaryJson(),
        'after': after.summaryJson(),
        'delta': _delta(before, after),
        'recentErrors': _errors,
      });
    } catch (error) {
      return _fail('tap_failed', error.toString());
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
      for (final entry in decoded.entries) {
        final editable = _findEditable(target: entry.key);
        if (editable == null) {
          failed.add(entry.key);
          continue;
        }
        _setEditableText(editable, entry.value?.toString() ?? '');
        filled.add(entry.key);
      }

      final stable = await _waitStableForAction(params);
      final after = _snapshot();
      return _ok({
        'action': 'fill',
        'stable': stable,
        'filled': filled,
        'failed': failed,
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
    final delta = _dragDelta(direction, distance, scrollGesture: scrollGesture);
    await _dispatchDrag(start, delta);
    final stable = await _waitStableForAction(params);
    final after = _snapshot();
    return _ok({
      'action': action,
      'stable': stable,
      'result': _changed(before, after) ? 'changed' : 'unchanged',
      'before': before.summaryJson(),
      'after': after.summaryJson(),
      'delta': _delta(before, after),
      'recentErrors': _errors,
    });
  }

  ScoutSnapshot _snapshot() {
    final root = WidgetsBinding.instance.rootElement;
    final nodes = <ScoutNode>[];
    final visibleText = <String>{};
    var screen = 'RootWidget';
    if (root != null) {
      _walk(root, (Element element) {
        final widgetType = element.widget.runtimeType.toString();
        if (screen == 'RootWidget' && widgetType.endsWith('Screen')) {
          screen = widgetType;
        }
        final node = _nodeFromElement(element);
        if (node != null) {
          nodes.add(node);
        }
        final text = _ownText(element.widget);
        if (text != null && _isUsefulVisibleText(text)) {
          visibleText.add(text.trim());
        }
      });
    }

    final compactNodes = _compactNodes(nodes);
    final interactables = compactNodes
        .where((node) => node.kind != 'text' && node.kind != 'field')
        .toList(growable: false);
    final fields = compactNodes
        .where((node) => node.kind == 'field')
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
      logicalSize:
          WidgetsBinding.instance.platformDispatcher.views.first.physicalSize /
          WidgetsBinding
              .instance
              .platformDispatcher
              .views
              .first
              .devicePixelRatio,
      visibleText: visibleText.toList(growable: false),
      interactables: interactables,
      fields: fields,
      recentErrors: List<Map<String, Object?>>.from(_errors),
    );
  }

  ScoutNode? _nodeFromElement(Element element) {
    final widget = element.widget;
    final rect = _rectFor(element);
    if (rect == null || rect.width < 1 || rect.height < 1) return null;

    final kind = _kindFor(widget, element);
    if (kind == null) return null;

    final label = _labelFor(element, widget);
    final id = _stableId(
      kind,
      label,
      widget.key,
      element.widget.runtimeType.toString(),
    );
    return ScoutNode(
      id: id,
      fallbackId:
          'i${id.hashCode.abs().toString().padLeft(8, '0').substring(0, 6)}',
      kind: kind,
      label: label,
      value: kind == 'field' ? _editableValueBelow(element) : null,
      widgetType: widget.runtimeType.toString(),
      key: _keyLabel(widget.key),
      rect: rect,
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
    if (widget is TextField) {
      return widget.decoration?.labelText ?? widget.decoration?.hintText;
    }
    final own = _ownText(widget);
    if (own != null && own.trim().isNotEmpty) return own.trim();
    return _textBelow(element);
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
    final x = double.tryParse(params['x'] ?? '');
    final y = double.tryParse(params['y'] ?? '');
    if (x != null && y != null) return Offset(x, y);
    if (target == null || target.isEmpty) return null;
    return _snapshot().findNode(target)?.rect?.center;
  }

  Offset _screenCenter() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final logicalSize = view.physicalSize / view.devicePixelRatio;
    return Offset(logicalSize.width / 2, logicalSize.height / 2);
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
              node.kind == 'field' ? 'field' : 'act',
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
      EditableTextState? result;
      _walk(root, (Element element) {
        if (result != null) return;
        final node = _nodeFromElement(element);
        if (node != null &&
            (node.id == matchedNode.id || node.label == matchedNode.label)) {
          result = _editableStateBelow(element);
        }
      });
      if (result != null) return result;
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
        kind: PointerDeviceKind.mouse,
        viewId: viewId,
      ),
    );
    binding.handlePointerEvent(
      PointerDownEvent(
        pointer: pointer,
        device: pointer,
        position: point,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
        viewId: viewId,
      ),
    );
    await Future<void>.delayed(hold);
    binding.handlePointerEvent(
      PointerUpEvent(
        pointer: pointer,
        device: pointer,
        position: point,
        kind: PointerDeviceKind.mouse,
        viewId: viewId,
      ),
    );
    binding.handlePointerEvent(
      PointerRemovedEvent(
        pointer: pointer,
        device: pointer,
        position: point,
        kind: PointerDeviceKind.mouse,
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
        kind: PointerDeviceKind.mouse,
        viewId: viewId,
      ),
    );
    binding.handlePointerEvent(
      PointerDownEvent(
        pointer: pointer,
        device: pointer,
        position: start,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
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
          kind: PointerDeviceKind.mouse,
          buttons: kPrimaryMouseButton,
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
        kind: PointerDeviceKind.mouse,
        viewId: viewId,
      ),
    );
    binding.handlePointerEvent(
      PointerRemovedEvent(
        pointer: pointer,
        device: pointer,
        position: start + delta,
        kind: PointerDeviceKind.mouse,
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
      jsonEncode(before.summaryJson()) != jsonEncode(after.summaryJson());

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
      'newInteractables': afterActions
          .difference(beforeActions)
          .toList(growable: false),
      'removedInteractables': beforeActions
          .difference(afterActions)
          .toList(growable: false),
    };
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
  final List<Map<String, Object?>> recentErrors;

  ScoutNode? findNode(String target) {
    for (final node in [...interactables, ...fields]) {
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
    };
  }

  Map<String, Object?> toJson() {
    return {
      ...summaryJson(),
      'interactables': interactables
          .map((node) => node.toJson())
          .toList(growable: false),
      'fields': fields.map((node) => node.toJson()).toList(growable: false),
      'overlays': const <Object?>[],
      'keyboard': {'visible': false},
      'recentErrors': recentErrors,
    };
  }
}

class ScoutNode {
  const ScoutNode({
    required this.id,
    required this.fallbackId,
    required this.kind,
    required this.label,
    required this.value,
    required this.widgetType,
    required this.key,
    required this.rect,
    required this.enabled,
    required this.confidence,
  });

  final String id;
  final String fallbackId;
  final String kind;
  final String? label;
  final String? value;
  final String widgetType;
  final String? key;
  final Rect? rect;
  final bool enabled;
  final double confidence;

  ScoutNode copyWith({String? label, String? value, double? confidence}) {
    return ScoutNode(
      id: id,
      fallbackId: fallbackId,
      kind: kind,
      label: label ?? this.label,
      value: value ?? this.value,
      widgetType: widgetType,
      key: key,
      rect: rect,
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
      'fallbackId': fallbackId,
      'kind': kind,
      'label': label,
      if (kind == 'field') 'value': value,
      'widgetType': widgetType,
      'key': key,
      'rect': rect == null
          ? null
          : [rect!.left, rect!.top, rect!.width, rect!.height],
      'enabled': enabled,
      'confidence': confidence,
    };
  }
}
