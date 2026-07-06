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
        // Resolve against the snapshot we just took — a second full tree walk
        // here doubled the cost of every targeted tap.
        node = before.findNode(target);
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
      return _respondWithExpectation(params, {
        'action': 'tap ${target ?? '${point.dx},${point.dy}'}',
        'stable': stable,
        'result': _tapResult(changed: changed, node: node),
        if (actionSnapshot.lateChangeObserved) 'lateChangeObserved': true,
        if (actionSnapshot.waitTimedOut) 'waitTimedOut': true,
        'target': node?.toJson(),
        'activation': {
          'dispatched': true,
          'observedChange': changed,
          'note': changed
              ? null
              : (node?.selected == true
                    ? 'Target was already selected before the tap; no change is expected.'
                    : 'Tap was dispatched, but no synchronous Flutter tree, field, text, or geometry change was observed before the wait timeout.'),
        },
        if (!changed && node?.selected != true)
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
      final match = _findVisibleTextMatch(
        text,
        loose: params['contains'] == 'true',
      );
      if (match == null) {
        final suggestions = _textSuggestions(before.visibleText, text);
        return _fail(
          'text_not_found',
          'No visible text matched `$text`.'
              '${suggestions.isEmpty ? '' : ' Did you mean: ${suggestions.map((s) => '`$s`').join(', ')}?'}',
          extra: {if (suggestions.isNotEmpty) 'didYouMean': suggestions},
        );
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
      final activationRisk = _tapTextActivationRisk(match);
      await _dispatchTap(point);
      final actionSnapshot = await _snapshotAfterAction(before, params);
      final stable = actionSnapshot.stable;
      final after = actionSnapshot.snapshot;
      final changed = _changed(before, after);
      return _respondWithExpectation(params, {
        'action': 'tap-text $text',
        'stable': stable,
        'result': _tapResult(changed: changed, node: targetNode),
        if (actionSnapshot.lateChangeObserved) 'lateChangeObserved': true,
        if (actionSnapshot.waitTimedOut) 'waitTimedOut': true,
        'target': targetNode.toJson(),
        'textTarget': match.text.toJson(),
        'activation': {
          'dispatched': true,
          'observedChange': changed,
          'strategy': _tapTextStrategy(match),
          'risk': activationRisk,
        },
        if ((!changed && targetNode.selected != true) ||
            activationRisk['level'] != 'low')
          'warnings': [
            if (!changed && targetNode.selected != true)
              'tap-text activated the nearest actionable target, but no synchronous UI change was observed before the wait timeout.',
            if (activationRisk['level'] != 'low')
              'tap-text used a higher-risk activation path; prefer a concrete handle from inspect when repeating this action.',
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

  /// Fuzzy near-matches for a failed tap-text, so the agent's next attempt
  /// doesn't need a full re-inspect: containment either way, shared tokens,
  /// and shared prefixes all score.
  List<String> _textSuggestions(List<String> visibleText, String query) {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return const [];
    final qTokens = q.split(RegExp(r'\s+')).toSet();
    final scored = <(String, int)>[];
    for (final value in visibleText) {
      final v = value.toLowerCase();
      var score = 0;
      if (v.contains(q) || q.contains(v)) score += 3;
      score += qTokens.intersection(v.split(RegExp(r'\s+')).toSet()).length * 2;
      var shared = 0;
      while (shared < q.length && shared < v.length && q[shared] == v[shared]) {
        shared++;
      }
      if (shared >= 3) score += 1;
      if (score > 0) scored.add((value, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(3).map((entry) => entry.$1).toList(growable: false);
  }

  /// A no-change tap on an already-selected target (active tab, checked
  /// toggle) is expected behavior, not a failed activation — report it as
  /// `already_selected` so agents don't retry or escalate.
  String _tapResult({required bool changed, required ScoutNode? node}) {
    if (changed) return 'changed';
    if (node?.selected == true) return 'already_selected';
    return 'activated_no_observed_change';
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

  Map<String, Object?> _tapTextActivationRisk(_TextTargetMatch match) {
    final reasons = <String>[];
    var score = 0;
    final actionable = match.actionable;
    if (actionable == null) {
      reasons.add('visible_text_without_actionable_ancestor');
      score += 25;
    } else {
      if (actionable.id != match.text.id) {
        reasons.add('actionable_ancestor');
        score += 8;
      }
      final actionRect = actionable.rect;
      final textRect = match.text.rect;
      if (actionRect != null && textRect != null) {
        final textArea = textRect.width * textRect.height;
        final actionArea = actionRect.width * actionRect.height;
        if (textArea > 0 && actionArea / textArea > 16) {
          reasons.add('broad_ancestor');
          score += 16;
        }
      }
      if (!actionable.hitTestable) {
        reasons.add('target_not_hit_testable_at_center');
        score += 10;
      }
      if (actionable.confidence < 0.75) {
        reasons.add('low_confidence_target');
        score += 8;
      }
    }
    if (!match.text.hitTestable) {
      reasons.add('text_not_hit_testable');
      score += 10;
    }
    final level = score >= 24
        ? 'high'
        : score >= 10
        ? 'medium'
        : 'low';
    return {
      'level': level,
      'confidence': (1 - (score / 60)).clamp(0.0, 1.0),
      if (reasons.isNotEmpty) 'reasons': reasons,
    };
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
      return _respondWithExpectation(params, {
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
      final point = _pointForTarget(target, params, snapshot: before);
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
      return _respondWithExpectation(params, {
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

      // Bound a single call so it always returns before the CLI's VM-service
      // RPC timeout (20s), no matter how deep the target. A very deep target
      // (e.g. a keyed row thousands of items down a lazy list) can need
      // hundreds of scrolls; rather than block until the transport times out
      // with an opaque error, stop at the budget and report progress with a
      // resume hint. scroll-to resumes from the new position, so the agent just
      // calls it again to continue. The budget sits well under 20s so the final
      // snapshot and RPC serialization still complete inside the transport
      // window even on a slow tree.
      final budgetDeadline = DateTime.now().add(
        const Duration(milliseconds: 12000),
      );
      var current = before;
      var scrolls = 0;
      while (scrolls < maxScrolls) {
        if (DateTime.now().isAfter(budgetDeadline)) {
          final after = _snapshot();
          return _scrollToFailure(
            before: before,
            after: after,
            scrolls: scrolls,
            reason: 'time_budget_exhausted',
            message:
                'Scrolled $scrolls time(s) toward `$target` but reached the '
                'per-call time budget before it became visible. The scrollable '
                'is still moving — run `scroll-to $target` again to continue '
                'from here.',
            target: target,
          );
        }
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
        // Stop early only if the scrollable genuinely did not move (hit an
        // edge). Use viewport-content movement, not just per-id geometry, so a
        // lazy list whose visible children fully turn over each step is not
        // mistaken for a pinned scrollable.
        if (!_viewportMoved(current, after)) {
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

  /// Closes the top modal/screen without the caller guessing between a system
  /// `back` and an in-app close button. Pops the top route first (handles
  /// showDialog/showModalBottomSheet/pushed screens); if nothing pops (a
  /// custom OverlayEntry modal), taps a close-like control (xmark/close/
  /// cancel/back). Reports which strategy worked.
  Future<developer.ServiceExtensionResponse> _handleDismiss(
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
      String strategy = popped ? 'popped_route' : 'none';
      String? tappedId;
      if (!popped) {
        // No route popped — look for a close-like control on the current
        // screen (a custom overlay's own X/Cancel).
        final closeNode = _findCloseControl(before);
        final point = closeNode?.suggestedTapPoint;
        if (closeNode != null && point != null) {
          await _dispatchTap(point);
          strategy = 'tapped_close';
          tappedId = closeNode.id;
        }
      }
      final actionSnapshot = await _snapshotAfterAction(before, params);
      final after = actionSnapshot.snapshot;
      final changed = _changed(before, after);
      return _ok({
        'action': 'dismiss',
        'stable': actionSnapshot.stable,
        'strategy': strategy,
        'popped': popped,
        'tappedClose': ?tappedId,
        'result': changed
            ? 'changed'
            : (strategy == 'none'
                  ? 'nothing_to_dismiss'
                  : 'activated_no_observed_change'),
        'before': before.summaryJson(),
        'after': after.summaryJson(),
        'delta': _delta(before, after),
        'recentErrors': _recentErrors(),
      });
    } catch (error) {
      return _fail('dismiss_failed', error.toString());
    }
  }

  /// A close/cancel/back control among the current interactables, preferring
  /// ones near the top of the screen (modal headers).
  ScoutNode? _findCloseControl(ScoutSnapshot snapshot) {
    const closeIds = {
      'btn.xmark',
      'btn.close',
      'btn.cancel',
      'btn.back',
      'btn.chevron_left',
      'tap.close',
      'tap.cancel',
    };
    ScoutNode? best;
    for (final node in snapshot.interactables) {
      final id = node.id;
      final label = (node.label ?? '').toLowerCase();
      final looksClose =
          closeIds.contains(id) ||
          label == 'close' ||
          label == 'cancel' ||
          label == 'dismiss';
      if (!looksClose) continue;
      if (node.suggestedTapPoint == null) continue;
      // Prefer the highest (smallest top) — modal close buttons live in the
      // header.
      if (best == null || (node.rect?.top ?? 1e9) < (best.rect?.top ?? 1e9)) {
        best = node;
      }
    }
    return best;
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

  /// Waits until visible text appears ([text]) and/or disappears ([gone]) —
  /// the missing primitive for async outcomes: "Saved Successfully" toasts,
  /// "Loading" spinners clearing, navigation banners. Polls snapshots; exits
  /// early on a fresh blocking error (waiting longer is pointless).
  Future<developer.ServiceExtensionResponse> _handleWaitFor(
    String method,
    Map<String, String> params,
  ) async {
    try {
      if (!_hasWaitConditions(params)) {
        return _fail(
          'usage',
          'Provide at least one condition: text, gone, target, selected, '
              'screen, or field=<handle>=<value>.',
        );
      }
      final conditions = _describeWaitConditions(params);
      final outcome = await _awaitConditions(params);
      if (outcome.met) {
        return _ok({
          'action': 'wait-for',
          'result': 'met',
          'waitedMs': outcome.waitedMs,
          'polls': outcome.polls,
          'conditions': conditions,
          'recentErrors': _recentErrors(),
        });
      }
      if (outcome.blocked) {
        return _fail(
          'blocking_error_during_wait',
          'A fresh blocking error surfaced while waiting; the awaited UI change is unlikely to arrive.',
          extra: {
            'result': 'blocked',
            'waitedMs': outcome.waitedMs,
            'polls': outcome.polls,
            'conditions': conditions,
          },
        );
      }
      return _fail(
        'wait_for_timeout',
        'Conditions not met within ${outcome.waitedMs}ms: '
            '${conditions.entries.map((e) => '${e.key}=`${e.value}`').join(', ')}.',
        extra: {
          'result': 'timeout',
          'waitedMs': outcome.waitedMs,
          'polls': outcome.polls,
          'conditions': conditions,
          'visibleText': outcome.visibleText,
        },
      );
    } catch (error) {
      return _fail('wait_for_failed', error.toString());
    }
  }

  /// Polls snapshots (driving deferred frames on backgrounded windows) until
  /// every condition in [params] holds, a fresh blocking error appears, or
  /// the timeout elapses. Shared by wait-for and action `expect*` params.
  Future<
    ({
      bool met,
      bool blocked,
      int waitedMs,
      int polls,
      List<String> visibleText,
    })
  >
  _awaitConditions(
    Map<String, String> params, {
    String prefix = '',
    String timeoutParam = 'timeoutMs',
    int defaultTimeoutMs = 5000,
  }) async {
    final timeoutMs =
        int.tryParse(params[timeoutParam] ?? '') ?? defaultTimeoutMs;
    final pollMs = (int.tryParse(params['pollMs'] ?? '') ?? 150).clamp(
      16,
      2000,
    );
    final stopwatch = Stopwatch()..start();
    var polls = 0;
    while (true) {
      polls += 1;
      _pumpPendingFrame();
      await _drainDeferredFrames(budget: Duration(milliseconds: pollMs));
      final snapshot = _snapshot();
      if (_waitForConditionsMet(
        snapshot: snapshot,
        params: params,
        prefix: prefix,
      )) {
        return (
          met: true,
          blocked: false,
          waitedMs: stopwatch.elapsedMilliseconds,
          polls: polls,
          visibleText: snapshot.visibleText,
        );
      }
      final blocking = snapshot.recentErrors.any(
        (error) => error['blocking'] == true && error['stale'] != true,
      );
      if (blocking || stopwatch.elapsedMilliseconds >= timeoutMs) {
        return (
          met: false,
          blocked: blocking,
          waitedMs: stopwatch.elapsedMilliseconds,
          polls: polls,
          visibleText: snapshot.visibleText,
        );
      }
      await Future<void>.delayed(Duration(milliseconds: pollMs));
    }
  }

  /// Completes an action response, honoring `expect*` params: when present,
  /// the action's dispatch is followed — in the SAME VM call — by a bounded
  /// wait for the expected UI state (toast text, spinner gone, handle
  /// visible, screen reached). This closes the act→verify gap that separate
  /// wait-for invocations leave open (process startup, connection setup, and
  /// UI that reverts between commands).
  Future<developer.ServiceExtensionResponse> _respondWithExpectation(
    Map<String, String> params,
    Map<String, Object?> payload,
  ) async {
    if (!_hasWaitConditions(params, prefix: 'expect')) return _ok(payload);
    final conditions = _describeWaitConditions(params, prefix: 'expect');
    final outcome = await _awaitConditions(
      params,
      prefix: 'expect',
      timeoutParam: 'expectTimeoutMs',
    );
    final expectation = {
      'met': outcome.met,
      'waitedMs': outcome.waitedMs,
      'polls': outcome.polls,
      'conditions': conditions,
    };
    if (outcome.met) {
      return _ok({...payload, 'expectation': expectation});
    }
    return _fail(
      outcome.blocked ? 'blocking_error_during_wait' : 'expectation_not_met',
      'Action dispatched, but the expectation was not met within '
      '${outcome.waitedMs}ms: '
      '${conditions.entries.map((e) => '${e.key}=`${e.value}`').join(', ')}.',
      extra: {
        ...payload,
        'expectation': expectation,
        'visibleText': outcome.visibleText,
      },
    );
  }

  /// Whether any wait/expect condition is present in [params].
  /// [prefix] selects the param namespace: '' for wait-for (`text`, `gone`,
  /// …) or 'expect' for action expectations (`expectText`, `expectGone`, …).
  bool _hasWaitConditions(Map<String, String> params, {String prefix = ''}) {
    return _conditionNames.any(
      (name) => (params[_conditionParam(prefix, name)] ?? '').isNotEmpty,
    );
  }

  static const List<String> _conditionNames = [
    'text',
    'gone',
    'target',
    'selected',
    'screen',
    'view',
    'field',
  ];

  String _conditionParam(String prefix, String name) {
    if (prefix.isEmpty) return name;
    return '$prefix${name[0].toUpperCase()}${name.substring(1)}';
  }

  /// Names and values of the conditions present in [params], for echoing in
  /// responses.
  Map<String, Object?> _describeWaitConditions(
    Map<String, String> params, {
    String prefix = '',
  }) {
    return {
      for (final name in _conditionNames)
        if ((params[_conditionParam(prefix, name)] ?? '').isNotEmpty)
          name: params[_conditionParam(prefix, name)],
    };
  }

  /// Evaluates every present condition against [snapshot]; all must hold.
  ///
  /// - `text`: case-insensitive substring of some visible text
  /// - `gone`: no visible text contains it
  /// - `target`: a node matching the handle exists and is at least partly
  ///   visible
  /// - `selected`: a node matching the handle exists with `selected == true`
  /// - `screen`: snapshot screen name equals it
  /// - `field`: `<handle>=<value>` — the field's current value equals value
  bool _waitForConditionsMet({
    required ScoutSnapshot snapshot,
    required Map<String, String> params,
    String prefix = '',
  }) {
    String? param(String name) {
      final value = params[_conditionParam(prefix, name)];
      return value == null || value.isEmpty ? null : value;
    }

    bool visible(String needle) {
      final lower = needle.toLowerCase();
      return snapshot.visibleText.any(
        (value) => value.toLowerCase().contains(lower),
      );
    }

    final text = param('text');
    if (text != null && !visible(text)) return false;
    final gone = param('gone');
    if (gone != null && visible(gone)) return false;
    final target = param('target');
    if (target != null) {
      final node = snapshot.findNode(target);
      if (node == null || node.visibleFraction <= 0) return false;
    }
    final selected = param('selected');
    if (selected != null) {
      final node = snapshot.findNode(selected);
      if (node == null || node.selected != true) return false;
    }
    final screen = param('screen');
    if (screen != null && snapshot.screen != screen) return false;
    final view = param('view');
    if (view != null &&
        !snapshot.viewSignature.toLowerCase().contains(view.toLowerCase())) {
      return false;
    }
    final field = param('field');
    if (field != null) {
      final separator = field.indexOf('=');
      if (separator <= 0) return false;
      final node = snapshot.findField(field.substring(0, separator));
      if (node == null ||
          (node.value ?? '') != field.substring(separator + 1)) {
        return false;
      }
    }
    return true;
  }

  /// Drive the rendering pipeline to flush a deferred frame when the engine
  /// has stopped delivering vsync, so a follow-up snapshot reflects post-action
  /// state instead of the stale, pre-action render tree.
  ///
  /// A desktop Flutter window that is not the frontmost/key window stops
  /// receiving frame callbacks from the embedder. A tapped callback's
  /// `setState` then never produces a serviced frame, so without this the
  /// action looks like `activated_no_observed_change` even though it ran.
  void _pumpPendingFrame() {
    final binding = WidgetsBinding.instance;
    // Only step in when the embedder has stopped delivering frames — i.e. a
    // backgrounded/occluded desktop window where `framesEnabled` is false. In
    // that state `setState` never schedules a serviced frame, so dirtied
    // elements are deferred indefinitely and a follow-up snapshot reads stale,
    // pre-action UI. Driving `handleDrawFrame` flushes that pending build,
    // layout, and paint synchronously.
    //
    // When frames are enabled the engine services its own frames; pumping on
    // top of that would fight in-flight animations (scroll ballistics, route
    // transitions) and corrupt their timing, so leave those entirely to the
    // engine.
    if (binding.framesEnabled) return;
    if (binding.schedulerPhase != SchedulerPhase.idle) return;
    binding.handleBeginFrame(null);
    binding.handleDrawFrame();
  }

  /// Runs deferred frames WITH AN ADVANCING CLOCK while the embedder delivers
  /// no vsync (backgrounded/occluded desktop window), so in-flight animations
  /// — route pushes, flips, tab transitions — progress to completion instead
  /// of freezing on their first frame. [_pumpPendingFrame] alone cannot do
  /// this: `handleBeginFrame(null)` reuses the previous raw timestamp, so
  /// tickers see zero elapsed time no matter how many frames are pumped.
  ///
  /// The fabricated clock is anchored to real elapsed time on top of the last
  /// engine timestamp, so it always lags the engine's own clock — if the
  /// window regains focus mid-drain, the next real vsync timestamp is still
  /// monotonically ahead and ticker timelines stay consistent.
  ///
  /// Self-terminates when no more frames are scheduled (animations finished),
  /// when real vsync resumes, or when [budget] runs out (indeterminate
  /// spinners schedule frames forever; the budget keeps waits bounded).
  Future<void> _drainDeferredFrames({
    Duration budget = const Duration(milliseconds: 1500),
  }) async {
    final binding = WidgetsBinding.instance;
    if (binding.framesEnabled) return;
    final base = binding.currentSystemFrameTimeStamp;
    final stopwatch = Stopwatch()..start();
    // `hasScheduledFrame` alone cannot gate this loop: scheduleFrame() is a
    // no-op while framesEnabled is false, so it stays false on a backgrounded
    // window even mid-animation. Active tickers (route transitions, flips)
    // are visible as transient callbacks instead.
    while (!binding.framesEnabled &&
        (binding.hasScheduledFrame || binding.transientCallbackCount > 0) &&
        binding.schedulerPhase == SchedulerPhase.idle &&
        stopwatch.elapsed < budget) {
      binding.handleBeginFrame(
        base + stopwatch.elapsed + const Duration(milliseconds: 1),
      );
      binding.handleDrawFrame();
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  Future<void> _waitForFrame() async {
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(milliseconds: 500),
      onTimeout: () {},
    );
    _pumpPendingFrame();
    // If an animation is mid-flight on a backgrounded window, let it finish
    // (bounded) so the snapshot reads settled UI, not a frozen transition.
    await _drainDeferredFrames(budget: const Duration(milliseconds: 400));
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
      // A backgrounded desktop window receives no vsync, so the awaited frame
      // may never have run. Drive it ourselves so the stability check and the
      // snapshot that follows reflect post-action state — including running
      // any in-flight animation to completion with an advancing clock, or it
      // would keep `hasScheduledFrame` true forever and never look stable.
      _pumpPendingFrame();
      await _drainDeferredFrames(budget: frameTimeout);
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
    final start =
        _pointForTarget(params['target'], params, snapshot: before) ??
        _screenCenter();
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
