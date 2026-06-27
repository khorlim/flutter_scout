part of 'flutter_scout_binding.dart';

// part: interaction handlers (tap, tap-text, input, long-press, fill, scroll, swipe, scroll-to, back, wait-stable) and pointer dispatch wait.

extension _RuntimeActions on FlutterScoutRuntime {
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
            extra: {
              'reachHint': 'scroll-to $target',
              'recentErrors': _recentErrors(),
            },
          );
        }
        return _fail(
          'target_not_found',
          'No tappable target matched `$target`.',
          extra: _notFoundScrollHint(target),
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
        return _fail(
          'target_not_found',
          'No target matched `$target`.',
          extra: _notFoundScrollHint(target),
        );
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

  Future<developer.ServiceExtensionResponse> _handleScrollTo(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final target = params['target'];
      if (target == null || target.trim().isEmpty) {
        return _fail('missing_target', 'Expected a target handle to reach.');
      }
      final before = _snapshot();
      final maxScrolls = int.tryParse(params['maxScrolls'] ?? '') ?? 20;
      final direction = params['direction'] ?? 'down';
      final distance =
          double.tryParse(params['distance'] ?? '') ??
          (_viewportRect().height * 0.7);

      // Already reachable without scrolling.
      var node = before.findNode(target);
      if (_isReachable(node)) {
        return _scrollToResult(
          before: before,
          after: before,
          node: node!,
          scrolls: 0,
          result: 'already_visible',
          target: target,
        );
      }

      var current = before;
      var scrolls = 0;
      while (scrolls < maxScrolls) {
        final start = _scrollStartFor(current, direction);
        if (start == null) {
          final after = _snapshot();
          return _scrollToFailure(
            before: before,
            after: after,
            scrolls: scrolls,
            reason: 'no_scrollable',
            message:
                'No scrollable was found to reach `$target`. Verify the '
                'handle exists on this screen.',
            target: target,
          );
        }
        final delta = _dragDelta(direction, distance, scrollGesture: true);
        await _dispatchDrag(start, delta);
        await _waitStableForAction(params);
        scrolls++;
        final after = _snapshot();
        node = after.findNode(target);
        if (_isReachable(node)) {
          return _scrollToResult(
            before: before,
            after: after,
            node: node!,
            scrolls: scrolls,
            result: 'reached',
            target: target,
          );
        }
        // Stop early if the scrollable did not move (hit an edge).
        if (!_geometryChanged(current, after)) {
          return _scrollToFailure(
            before: before,
            after: after,
            scrolls: scrolls,
            reason: 'reached_scroll_end',
            message:
                'Reached the end of the scrollable after $scrolls scroll(s) '
                'without finding `$target`. Try --direction ${_oppositeDirection(direction)} '
                'or a different screen.',
            target: target,
          );
        }
        current = after;
      }
      return _scrollToFailure(
        before: before,
        after: current,
        scrolls: scrolls,
        reason: 'target_not_reached',
        message:
            'Did not reach `$target` within $maxScrolls scroll(s). Increase '
            '--max-scrolls if the target is deeper.',
        target: target,
      );
    } catch (error) {
      return _fail('scroll_to_failed', error.toString());
    }
  }

  bool _isReachable(ScoutNode? node) =>
      node != null && node.visibleFraction > 0 && node.hitTestable;

  /// Extra payload for a `target_not_found` failure. When the screen has a
  /// scrollable, the target may simply be lazy-unbuilt or offscreen, so point
  /// the agent at `scroll-to` instead of letting it conclude the handle is
  /// wrong.
  Map<String, Object?> _notFoundScrollHint(String? target) {
    final snapshot = _snapshot();
    final hasScrollable = snapshot.scrollables.isNotEmpty;
    return {
      if (hasScrollable && target != null && target.isNotEmpty) ...{
        'reason': 'maybe_offscreen_or_lazy',
        'hint':
            'No built widget matched `$target`. Lazy lists/grids build '
            'children on demand, so the target may exist deeper in a '
            'scrollable. Run `scroll-to $target` to scroll until it builds, '
            'then retry.',
        'reachHint': 'scroll-to $target',
        'scrollableCount': snapshot.scrollables.length,
      },
      'recentErrors': _recentErrors(),
    };
  }

  String _oppositeDirection(String direction) => switch (direction) {
    'down' => 'up',
    'up' => 'down',
    'left' => 'right',
    'right' => 'left',
    _ => 'up',
  };

  /// Center of the largest visible scrollable whose major axis matches the
  /// scroll direction, used as the drag origin for [_handleScrollTo].
  Offset? _scrollStartFor(ScoutSnapshot snapshot, String direction) {
    final vertical = direction == 'down' || direction == 'up';
    Rect? best;
    var bestArea = 0.0;
    for (final scrollable in snapshot.scrollables) {
      final visible = scrollable['visibleRect'];
      final raw = visible is List ? visible : scrollable['rect'];
      if (raw is! List || raw.length < 4) continue;
      final rect = Rect.fromLTWH(
        (raw[0] as num).toDouble(),
        (raw[1] as num).toDouble(),
        (raw[2] as num).toDouble(),
        (raw[3] as num).toDouble(),
      );
      if (rect.width <= 0 || rect.height <= 0) continue;
      // Prefer a scrollable oriented along the requested axis when its shape
      // makes the axis obvious; otherwise fall back to largest visible area.
      final axisMatch = vertical
          ? rect.height >= rect.width * 0.6
          : rect.width >= rect.height * 0.6;
      final area = rect.width * rect.height * (axisMatch ? 1.0 : 0.25);
      if (area > bestArea) {
        bestArea = area;
        best = rect;
      }
    }
    if (best == null) return null;
    return best.center;
  }

  developer.ServiceExtensionResponse _scrollToResult({
    required ScoutSnapshot before,
    required ScoutSnapshot after,
    required ScoutNode node,
    required int scrolls,
    required String result,
    required String target,
  }) {
    return _ok({
      'action': 'scroll-to $target',
      'result': result,
      'reason': result,
      'scrollsUsed': scrolls,
      'target': node.toJson(),
      'before': before.summaryJson(),
      'after': after.summaryJson(),
      'delta': _delta(before, after),
      'recentErrors': _recentErrors(),
    });
  }

  developer.ServiceExtensionResponse _scrollToFailure({
    required ScoutSnapshot before,
    required ScoutSnapshot after,
    required int scrolls,
    required String reason,
    required String message,
    required String target,
  }) {
    return _fail(
      'target_not_reached',
      message,
      extra: {
        'reason': reason,
        'scrollsUsed': scrolls,
        'before': before.summaryJson(),
        'after': after.summaryJson(),
        'delta': _delta(before, after),
        'recentErrors': _recentErrors(),
      },
    );
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

}
