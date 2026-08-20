part of 'flutter_scout_binding.dart';

// part: low-level pointer dispatch, tree walk, snapshot delta, and JSON response helpers.

class _ChangedRegionCandidate {
  _ChangedRegionCandidate({
    required this.identity,
    required this.logicalRect,
    required Set<String> reasons,
    required this.source,
  }) : reasons = <String>{...reasons},
       sourceIdentities = <String>{identity},
       sources = <String>{source};

  final String identity;
  final String source;
  final Rect logicalRect;
  final Set<String> reasons;
  final Set<String> sourceIdentities;
  final Set<String> sources;
}

extension _RuntimeInternals on FlutterScoutRuntime {
  void _setEditableText(EditableTextState state, String value) =>
      _inRequestPhase(
        'dispatch',
        () => _setEditableTextWithoutPhaseTiming(state, value),
      );

  void _setEditableTextWithoutPhaseTiming(
    EditableTextState state,
    String value,
  ) {
    if (_isSensitiveEditableState(state)) {
      _rememberSensitiveValue(value);
    }
    state.requestKeyboard();
    state.userUpdateTextEditingValue(
      TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      ),
      SelectionChangedCause.keyboard,
    );
  }

  Future<void> _dispatchTap(Offset point) => _inRequestPhaseAsync(
    'dispatch',
    () => _dispatchTapWithoutPhaseTiming(point),
  );

  Future<void> _dispatchTapWithoutPhaseTiming(Offset point) async =>
      _dispatchPress(point, hold: const Duration(milliseconds: 30));

  Future<void> _dispatchPress(Offset point, {required Duration hold}) =>
      _inRequestPhaseAsync(
        'dispatch',
        () => _dispatchPressWithoutPhaseTiming(point, hold: hold),
      );

  Future<void> _dispatchPressWithoutPhaseTiming(
    Offset point, {
    required Duration hold,
  }) async {
    final pointer = _nextSyntheticPointer++;
    final viewId = _primaryViewId;
    _syntheticGestureDepth += 1;
    try {
      await _dispatchPointerEvent(
        PointerAddedEvent(
          pointer: pointer,
          device: pointer,
          position: point,
          kind: PointerDeviceKind.touch,
          viewId: viewId,
        ),
      );
      await _dispatchPointerEvent(
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
      await _dispatchPointerEvent(
        PointerUpEvent(
          pointer: pointer,
          device: pointer,
          position: point,
          kind: PointerDeviceKind.touch,
          viewId: viewId,
        ),
      );
      await _dispatchPointerEvent(
        PointerRemovedEvent(
          pointer: pointer,
          device: pointer,
          position: point,
          kind: PointerDeviceKind.touch,
          viewId: viewId,
        ),
      );
    } finally {
      _syntheticGestureDepth -= 1;
    }
  }

  Future<void> _dispatchDrag(Offset start, Offset delta) =>
      _inRequestPhaseAsync(
        'dispatch',
        () => _dispatchDragWithoutPhaseTiming(start, delta),
      );

  Future<void> _dispatchDragWithoutPhaseTiming(
    Offset start,
    Offset delta,
  ) async {
    final pointer = _nextSyntheticPointer++;
    final viewId = _primaryViewId;
    _syntheticGestureDepth += 1;
    try {
      await _dispatchPointerEvent(
        PointerAddedEvent(
          pointer: pointer,
          device: pointer,
          position: start,
          kind: PointerDeviceKind.touch,
          viewId: viewId,
        ),
      );
      await _dispatchPointerEvent(
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
        await _dispatchPointerEvent(
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
      await _dispatchPointerEvent(
        PointerUpEvent(
          pointer: pointer,
          device: pointer,
          position: start + delta,
          kind: PointerDeviceKind.touch,
          viewId: viewId,
        ),
      );
      await _dispatchPointerEvent(
        PointerRemovedEvent(
          pointer: pointer,
          device: pointer,
          position: start + delta,
          kind: PointerDeviceKind.touch,
          viewId: viewId,
        ),
      );
    } finally {
      _syntheticGestureDepth -= 1;
    }
  }

  /// Flutter briefly locks pointer dispatch while reassembling and while
  /// flushing a frame. A Scout action can arrive in that window immediately
  /// after hot reload; retrying the same not-yet-dispatched event on the next
  /// frame avoids leaking GestureBinding's internal `!locked` assertion.
  Future<void> _dispatchPointerEvent(PointerEvent event) async {
    final deadline = DateTime.now().add(const Duration(milliseconds: 750));
    while (true) {
      try {
        GestureBinding.instance.handlePointerEvent(event);
        return;
      } catch (error) {
        final locked = error.toString().contains('!locked');
        if (!locked || DateTime.now().isAfter(deadline)) rethrow;
        WidgetsBinding.instance.scheduleFrame();
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }
  }

  Future<_HeldDragState> _beginHeldDrag(
    Offset position,
    ScoutSnapshot before,
  ) => _inRequestPhaseAsync(
    'dispatch',
    () => _beginHeldDragWithoutPhaseTiming(position, before),
  );

  Future<_HeldDragState> _beginHeldDragWithoutPhaseTiming(
    Offset position,
    ScoutSnapshot before,
  ) async {
    if (_heldDrag != null) {
      throw StateError(
        'A held drag is already active. End or cancel it first.',
      );
    }
    final state = _HeldDragState(
      pointer: _nextSyntheticPointer++,
      viewId: _primaryViewId,
      start: position,
      position: position,
      startedAt: DateTime.now(),
      before: before,
      path: <Map<String, Object?>>[],
    );
    _syntheticGestureDepth += 1;
    try {
      await _dispatchPointerEvent(
        PointerAddedEvent(
          pointer: state.pointer,
          device: state.pointer,
          position: position,
          kind: PointerDeviceKind.touch,
          viewId: state.viewId,
        ),
      );
      await _dispatchPointerEvent(
        PointerDownEvent(
          pointer: state.pointer,
          device: state.pointer,
          position: position,
          kind: PointerDeviceKind.touch,
          buttons: kPrimaryButton,
          viewId: state.viewId,
        ),
      );
      _heldDrag = state;
      _resetHeldDragExpiry();
      return state;
    } catch (_) {
      _syntheticGestureDepth -= 1;
      rethrow;
    }
  }

  Future<void> _moveHeldDrag(Offset position) => _inRequestPhaseAsync(
    'dispatch',
    () => _moveHeldDragWithoutPhaseTiming(position),
  );

  Future<void> _moveHeldDragWithoutPhaseTiming(Offset position) async {
    final state = _heldDrag;
    if (state == null) throw StateError('No held drag is active.');
    final delta = position - state.position;
    await _dispatchPointerEvent(
      PointerMoveEvent(
        pointer: state.pointer,
        device: state.pointer,
        position: position,
        delta: delta,
        kind: PointerDeviceKind.touch,
        buttons: kPrimaryButton,
        viewId: state.viewId,
      ),
    );
    state.position = position;
    _resetHeldDragExpiry();
    WidgetsBinding.instance.scheduleFrame();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  Future<_HeldDragState> _finishHeldDrag({required bool cancel}) =>
      _inRequestPhaseAsync(
        'dispatch',
        () => _finishHeldDragWithoutPhaseTiming(cancel: cancel),
      );

  Future<_HeldDragState> _finishHeldDragWithoutPhaseTiming({
    required bool cancel,
  }) async {
    final state = _heldDrag;
    if (state == null) throw StateError('No held drag is active.');
    try {
      await _dispatchPointerEvent(
        cancel
            ? PointerCancelEvent(
                pointer: state.pointer,
                device: state.pointer,
                position: state.position,
                kind: PointerDeviceKind.touch,
                viewId: state.viewId,
              )
            : PointerUpEvent(
                pointer: state.pointer,
                device: state.pointer,
                position: state.position,
                kind: PointerDeviceKind.touch,
                viewId: state.viewId,
              ),
      );
      await _dispatchPointerEvent(
        PointerRemovedEvent(
          pointer: state.pointer,
          device: state.pointer,
          position: state.position,
          kind: PointerDeviceKind.touch,
          viewId: state.viewId,
        ),
      );
      return state;
    } finally {
      _heldDragExpiry?.cancel();
      _heldDragExpiry = null;
      _heldDrag = null;
      _syntheticGestureDepth -= 1;
    }
  }

  void _resetHeldDragExpiry() {
    _heldDragExpiry?.cancel();
    _heldDragExpiry = Timer(const Duration(minutes: 2), () {
      if (_heldDrag != null) unawaited(_finishHeldDrag(cancel: true));
    });
  }

  int get _primaryViewId {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    return views.isEmpty ? 0 : views.first.viewId;
  }

  void _walk(Element element, void Function(Element element) visitor) {
    visitor(element);
    element.visitChildElements((Element child) => _walk(child, visitor));
  }

  /// Like [_walk] but prunes whole subtrees that are hidden (Offstage, etc.) or
  /// belong to the Scout overlay. Pruning during descent — rather than visiting
  /// every element and walking its ancestors to test visibility — is what makes
  /// annotation-target collection cheap on apps that keep many offstage subtrees
  /// mounted (e.g. an IndexedStack tab bar). Callers no longer need their own
  /// `_isHiddenByAncestor`/`_isScoutOverlayElement` checks.
  void _walkVisible(Element element, void Function(Element element) visitor) {
    visitor(element);
    if (_hidesSubtree(element) || _isScoutOverlayWidget(element.widget)) {
      return;
    }
    element.visitChildElements((Element child) => _walkVisible(child, visitor));
  }

  /// Whether [element]'s widget hides its own subtree from view/interaction —
  /// the per-element form of the conditions [_isHiddenByAncestor] looks for.
  bool _hidesSubtree(Element element) {
    final widget = element.widget;
    if (widget is Offstage) return widget.offstage;
    if (widget is Visibility) return !widget.visible && !widget.maintainSize;
    // A disabled TickerMode alone does not imply hidden: backgrounded desktop
    // windows can remain painted and tappable. Navigator's maintained previous
    // route is also TickerMode-disabled, but is occluded by the current route.
    // Hit testing distinguishes those cases without calling ModalRoute.of
    // during a tree walk (which would register inherited dependencies).
    if (widget is TickerMode &&
        !widget.enabled &&
        !_isSubtreeOnActiveHitPath(element)) {
      return true;
    }
    if (widget is IgnorePointer) return widget.ignoring;
    return false;
  }

  bool _changed(ScoutSnapshot before, ScoutSnapshot after) {
    Map<String, Object?> comparable(ScoutSnapshot snapshot) {
      final summary = Map<String, Object?>.from(snapshot.summaryJson())
        ..remove('idle')
        // Identity records observation history. A transient A→B→A sequence
        // must advance generation while still comparing equal at the semantic
        // endpoints for action outcome classification.
        ..remove('stateGeneration')
        ..remove('stateDigest')
        ..remove('snapshotId');
      return summary;
    }

    return jsonEncode(comparable(before)) != jsonEncode(comparable(after)) ||
        _fieldValuesChanged(before, after) ||
        _geometryChanged(before, after);
  }

  bool _fieldValuesChanged(ScoutSnapshot before, ScoutSnapshot after) {
    final beforeFields = {for (final node in before.fields) node.id: node};
    final afterFields = {for (final node in after.fields) node.id: node};
    if (beforeFields.length != afterFields.length ||
        !beforeFields.keys.toSet().containsAll(afterFields.keys)) {
      return true;
    }
    for (final entry in afterFields.entries) {
      final previous = beforeFields[entry.key];
      if (previous == null || !previous.hasSameFieldValue(entry.value)) {
        return true;
      }
    }
    return false;
  }

  bool _geometryChanged(ScoutSnapshot before, ScoutSnapshot after) {
    return _changedGeometryIds(before, after).isNotEmpty;
  }

  /// Whether the viewport content actually moved between two snapshots.
  ///
  /// More robust than [_geometryChanged] alone for lazy lists/grids: a single
  /// scroll step can replace every visible child, so no node id survives into
  /// the next snapshot and a pure geometry comparison finds nothing in common
  /// and wrongly concludes the scrollable did not move. Treat a change in the
  /// set of visible text or built interactables as movement too, so scroll-to
  /// only reports `reached_scroll_end` when the content is genuinely pinned.
  bool _viewportMoved(ScoutSnapshot before, ScoutSnapshot after) {
    if (_geometryChanged(before, after)) return true;
    final beforeText = before.visibleText.toSet();
    final afterText = after.visibleText.toSet();
    if (beforeText.length != afterText.length ||
        !beforeText.containsAll(afterText)) {
      return true;
    }
    final beforeActions = before.interactables.map((node) => node.id).toSet();
    final afterActions = after.interactables.map((node) => node.id).toSet();
    if (beforeActions.length != afterActions.length ||
        !beforeActions.containsAll(afterActions)) {
      return true;
    }
    return false;
  }

  Map<String, Object?> _delta(ScoutSnapshot before, ScoutSnapshot after) =>
      _inRequestPhase('delta', () => _deltaWithoutPhaseTiming(before, after));

  Map<String, Object?> _deltaWithoutPhaseTiming(
    ScoutSnapshot before,
    ScoutSnapshot after,
  ) {
    final beforeText = before.visibleText.toSet();
    final afterText = after.visibleText.toSet();
    final beforeFields = before.fields.map((node) => node.id).toSet();
    final afterFields = after.fields.map((node) => node.id).toSet();
    final beforeActions = before.interactables.map((node) => node.id).toSet();
    final afterActions = after.interactables.map((node) => node.id).toSet();
    final beforeFieldNodes = {for (final node in before.fields) node.id: node};
    final afterFieldNodes = {for (final node in after.fields) node.id: node};
    final beforeValidationMessages = {
      for (final node in before.fields) node.id: node.validationMessage,
    };
    final afterValidationMessages = {
      for (final node in after.fields) node.id: node.validationMessage,
    };
    final beforeKeyedText = {
      for (final node in before.textTargets)
        if (node.key != null && node.key!.isNotEmpty) node.key!: node.label,
    };
    final afterKeyedText = {
      for (final node in after.textTargets)
        if (node.key != null && node.key!.isNotEmpty) node.key!: node.label,
    };
    final beforeNodes = <String, ScoutNode>{
      for (final node in [...before.interactables, ...before.fields])
        node.id: node,
    };
    final afterNodes = <String, ScoutNode>{
      for (final node in [...after.interactables, ...after.fields])
        node.id: node,
    };
    final beforeScrollables = <String, Map<String, Object?>>{
      for (final scrollable in before.scrollables)
        if (scrollable['id'] case final String id) id: scrollable,
    };
    final afterScrollables = <String, Map<String, Object?>>{
      for (final scrollable in after.scrollables)
        if (scrollable['id'] case final String id) id: scrollable,
    };
    Map<String, Object?> keyboard(ScoutSnapshot snapshot) => <String, Object?>{
      'visible': snapshot.viewMetricsAvailable
          ? snapshot.viewInsets.bottom > 0.5
          : null,
      'logicalInsetBottom': snapshot.viewMetricsAvailable
          ? snapshot.viewInsets.bottom
          : null,
      'source': snapshot.viewMetricsAvailable
          ? 'flutter_view_metrics'
          : 'observation_unavailable',
    };
    final beforeViewport = before.viewportJson();
    final afterViewport = after.viewportJson();
    final beforeKeyboard = keyboard(before);
    final afterKeyboard = keyboard(after);
    int lastErrorCursor(ScoutSnapshot snapshot) =>
        snapshot.recentErrors.fold(0, (cursor, error) {
          final next = error['cursor'] as int? ?? 0;
          return cursor > next ? cursor : next;
        });
    final beforeErrorCursor = lastErrorCursor(before);
    final afterErrorCursor = lastErrorCursor(after);
    final changedGeometry = _changedGeometryIds(before, after);
    final changedRegionEvidence = _changedRegionEvidence(before, after);
    return {
      'state': <String, Object?>{
        'beforeStateGeneration': before.stateGeneration,
        'beforeSnapshotId': before.snapshotId,
        'afterStateGeneration': after.stateGeneration,
        'afterSnapshotId': after.snapshotId,
      },
      'screenChanged': before.screen != after.screen,
      'screen': <String, Object?>{
        'changed': before.screen != after.screen,
        'before': before.screen,
        'after': after.screen,
        'beforeEvidence': before.screenEvidence,
        'afterEvidence': after.screenEvidence,
      },
      'route': <String, Object?>{
        'changed': before.routeGuess != after.routeGuess,
        'before': before.routeGuess,
        'after': after.routeGuess,
        'kind': 'heuristic_inference',
        'source': 'navigator_route_observation',
      },
      'activeSurface': <String, Object?>{
        'changed':
            jsonEncode(before.activeSurface) != jsonEncode(after.activeSurface),
        'before': before.activeSurface,
        'after': after.activeSurface,
      },
      // View swaps on the SAME route (tab body, flip dashboard) don't move
      // `screen`; the signature comparison catches them.
      'viewChanged': before.viewSignature != after.viewSignature,
      'viewport': <String, Object?>{
        'changed': jsonEncode(beforeViewport) != jsonEncode(afterViewport),
        'before': beforeViewport,
        'after': afterViewport,
      },
      'keyboard': <String, Object?>{
        'changed': jsonEncode(beforeKeyboard) != jsonEncode(afterKeyboard),
        'before': beforeKeyboard,
        'after': afterKeyboard,
      },
      'newText': afterText.difference(beforeText).toList(growable: false),
      'removedText': beforeText.difference(afterText).toList(growable: false),
      'changedText': [
        for (final entry in afterKeyedText.entries)
          if (beforeKeyedText.containsKey(entry.key) &&
              beforeKeyedText[entry.key] != entry.value)
            {
              'key': entry.key,
              'from': beforeKeyedText[entry.key],
              'to': entry.value,
            },
      ],
      'newFields': afterFields.difference(beforeFields).toList(growable: false),
      'removedFields': beforeFields
          .difference(afterFields)
          .toList(growable: false),
      'changedFields': [
        for (final id in afterFields.intersection(beforeFields))
          if (!beforeFieldNodes[id]!.hasSameFieldValue(afterFieldNodes[id]!))
            id,
      ],
      'controlStateChanges': [
        for (final id in beforeNodes.keys.toSet().intersection(
          afterNodes.keys.toSet(),
        ))
          if (beforeNodes[id]!.enabled != afterNodes[id]!.enabled ||
              beforeNodes[id]!.selected != afterNodes[id]!.selected ||
              beforeNodes[id]!.hitTestable != afterNodes[id]!.hitTestable ||
              (beforeNodes[id]!.visibleFraction -
                          afterNodes[id]!.visibleFraction)
                      .abs() >
                  0.01)
            <String, Object?>{
              'id': id,
              'before': <String, Object?>{
                'enabled': beforeNodes[id]!.enabled,
                'selected': beforeNodes[id]!.selected,
                'hitTestable': beforeNodes[id]!.hitTestable,
                'visibleFraction': beforeNodes[id]!.visibleFraction,
              },
              'after': <String, Object?>{
                'enabled': afterNodes[id]!.enabled,
                'selected': afterNodes[id]!.selected,
                'hitTestable': afterNodes[id]!.hitTestable,
                'visibleFraction': afterNodes[id]!.visibleFraction,
              },
            },
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
      'changedRegions': changedRegionEvidence.regions,
      'changedRegionCoverage': changedRegionEvidence.coverage,
      'newInteractables': afterActions
          .difference(beforeActions)
          .toList(growable: false),
      'removedInteractables': beforeActions
          .difference(afterActions)
          .toList(growable: false),
      'scroll': <String, Object?>{
        'newRegions': afterScrollables.keys
            .toSet()
            .difference(beforeScrollables.keys.toSet())
            .toList(growable: false),
        'removedRegions': beforeScrollables.keys
            .toSet()
            .difference(afterScrollables.keys.toSet())
            .toList(growable: false),
        'changedRegions': [
          for (final id in beforeScrollables.keys.toSet().intersection(
            afterScrollables.keys.toSet(),
          ))
            if (jsonEncode(beforeScrollables[id]) !=
                jsonEncode(afterScrollables[id]))
              <String, Object?>{
                'id': id,
                'before': beforeScrollables[id],
                'after': afterScrollables[id],
              },
        ],
      },
      'runtimeSignals': <String, Object?>{
        'beforeCursor': beforeErrorCursor,
        'afterCursor': afterErrorCursor,
        'newCount': after.recentErrors
            .where(
              (error) => (error['cursor'] as int? ?? 0) > beforeErrorCursor,
            )
            .length,
        'newIdentities': <Object?>[
          for (final error in after.recentErrors)
            if ((error['cursor'] as int? ?? 0) > beforeErrorCursor)
              error['identity'],
        ],
      },
    };
  }

  /// Returns bounded, snapshot-relative geometry for agent-observable visual
  /// changes. This is deliberately semantic/render geometry, not a pixel diff:
  /// callers must retain [coverage] and abstain when it is not complete.
  ({List<Map<String, Object?>> regions, Map<String, Object?> coverage})
  _changedRegionEvidence(ScoutSnapshot before, ScoutSnapshot after) {
    const maximumReturnedRegions = 64;
    final beforeViewport = Offset.zero & before.logicalSize;
    final afterViewport = Offset.zero & after.logicalSize;
    final coordinateFrameStable =
        before.viewMetricsAvailable &&
        after.viewMetricsAvailable &&
        _sameSize(before.logicalSize, after.logicalSize) &&
        _sameSize(before.physicalSize, after.physicalSize) &&
        (before.devicePixelRatio - after.devicePixelRatio).abs() <= 0.000001;
    final globalScopeChanged =
        before.screen != after.screen || before.routeGuess != after.routeGuess;
    var ambiguousGeometryCount = 0;
    var unavailableGeometryCount = 0;
    var nonVisualChangeCount = 0;
    final candidates = <_ChangedRegionCandidate>[];

    Rect? visibleRect(ScoutNode node, Rect viewport) {
      if (node.visibleFraction <= 0) return null;
      final raw = node.visibleRect ?? node.rect;
      if (raw == null || !_validChangedRegionRect(raw)) return null;
      final clipped = raw.intersect(viewport);
      return _validChangedRegionRect(clipped) ? clipped : null;
    }

    Map<String, List<ScoutNode>> nodesByIdentity(ScoutSnapshot snapshot) {
      final result = <String, List<ScoutNode>>{};
      for (final node in <ScoutNode>[
        ...snapshot.interactables,
        ...snapshot.fields,
        ...snapshot.textTargets,
      ]) {
        final identity = '${node.kind}:${node.id}';
        result.putIfAbsent(identity, () => <ScoutNode>[]).add(node);
      }
      return result;
    }

    final beforeNodes = nodesByIdentity(before);
    final afterNodes = nodesByIdentity(after);
    final identities = <String>{
      ...beforeNodes.keys,
      ...afterNodes.keys,
    }.toList()..sort();
    for (final identity in identities) {
      final previousMatches = beforeNodes[identity] ?? const <ScoutNode>[];
      final currentMatches = afterNodes[identity] ?? const <ScoutNode>[];
      if (previousMatches.length > 1 || currentMatches.length > 1) {
        ambiguousGeometryCount += 1;
        continue;
      }
      final previous = previousMatches.isEmpty ? null : previousMatches.single;
      final current = currentMatches.isEmpty ? null : currentMatches.single;
      final reasons = <String>{};
      if (previous == null) {
        reasons.add('added');
      } else if (current == null) {
        reasons.add('removed');
      } else {
        if (!_sameRect(previous.rect, current.rect) ||
            !_sameRect(previous.visibleRect, current.visibleRect) ||
            (previous.visibleFraction - current.visibleFraction).abs() > 0.01) {
          reasons.add('geometry');
        }
        if (previous.label != current.label ||
            previous.validationMessage != current.validationMessage) {
          reasons.add('text_or_validation');
        }
        if (previous.kind == 'field' && !previous.hasSameFieldValue(current)) {
          reasons.add('field_value');
        }
        if (previous.enabled != current.enabled ||
            previous.selected != current.selected ||
            previous.hitTestable != current.hitTestable) {
          reasons.add('control_state');
        }
      }
      if (reasons.isEmpty) continue;
      final previousRect = previous == null
          ? null
          : visibleRect(previous, beforeViewport);
      final currentRect = current == null
          ? null
          : visibleRect(current, afterViewport);
      if (previousRect == null && currentRect == null) {
        final wasVisible = previous != null && previous.visibleFraction > 0;
        final isVisible = current != null && current.visibleFraction > 0;
        if (wasVisible || isVisible) {
          unavailableGeometryCount += 1;
        } else {
          nonVisualChangeCount += 1;
        }
        continue;
      }
      candidates.add(
        _ChangedRegionCandidate(
          identity: identity,
          logicalRect: _unionChangedRegionRects(previousRect, currentRect)!,
          reasons: reasons,
          source: 'snapshot_node_geometry',
        ),
      );
    }

    Map<String, Map<String, Object?>> scrollablesById(ScoutSnapshot snapshot) =>
        <String, Map<String, Object?>>{
          for (final value in snapshot.scrollables)
            if (value['id'] case final String id) id: value,
        };
    final beforeScrollables = scrollablesById(before);
    final afterScrollables = scrollablesById(after);
    final scrollIds = <String>{
      ...beforeScrollables.keys,
      ...afterScrollables.keys,
    }.toList()..sort();
    for (final id in scrollIds) {
      final previous = beforeScrollables[id];
      final current = afterScrollables[id];
      if (jsonEncode(previous) == jsonEncode(current)) continue;
      final raw =
          current?['visibleLogicalBounds'] ?? previous?['visibleLogicalBounds'];
      final rect = _changedRegionRectFromJson(raw)?.intersect(afterViewport);
      if (rect == null || !_validChangedRegionRect(rect)) {
        unavailableGeometryCount += 1;
        continue;
      }
      candidates.add(
        _ChangedRegionCandidate(
          identity: 'scroll:$id',
          logicalRect: rect,
          reasons: const <String>{'scroll_position_or_content'},
          source: 'snapshot_scroll_region_geometry',
        ),
      );
    }

    if (jsonEncode(before.activeSurface) != jsonEncode(after.activeSurface)) {
      final previousRect = _changedRegionRectFromJson(
        before.activeSurface?['rect'],
      );
      final currentRect = _changedRegionRectFromJson(
        after.activeSurface?['rect'],
      );
      final rect = _unionChangedRegionRects(previousRect, currentRect);
      if (rect == null || !_validChangedRegionRect(rect)) {
        unavailableGeometryCount += 1;
      } else {
        candidates.add(
          _ChangedRegionCandidate(
            identity: 'active_surface',
            logicalRect: rect.intersect(afterViewport),
            reasons: const <String>{'active_surface'},
            source: 'snapshot_active_surface_geometry',
          ),
        );
      }
    }

    final merged = <String, _ChangedRegionCandidate>{};
    for (final candidate in candidates) {
      final rect = candidate.logicalRect;
      final fingerprint = <String>[
        rect.left.toStringAsFixed(3),
        rect.top.toStringAsFixed(3),
        rect.width.toStringAsFixed(3),
        rect.height.toStringAsFixed(3),
      ].join(':');
      final existing = merged[fingerprint];
      if (existing == null) {
        merged[fingerprint] = candidate;
      } else {
        existing.reasons.addAll(candidate.reasons);
        existing.sourceIdentities.add(candidate.identity);
        existing.sources.add(candidate.source);
      }
    }
    final ordered = merged.values.toList()
      ..sort((a, b) {
        final top = a.logicalRect.top.compareTo(b.logicalRect.top);
        if (top != 0) return top;
        final left = a.logicalRect.left.compareTo(b.logicalRect.left);
        if (left != 0) return left;
        return a.identity.compareTo(b.identity);
      });
    final omittedRegionCount = math.max(
      0,
      ordered.length - maximumReturnedRegions,
    );
    final returned = ordered
        .take(maximumReturnedRegions)
        .map((candidate) {
          final rect = candidate.logicalRect;
          final physicalRect = coordinateFrameStable
              ? <double>[
                  rect.left * after.devicePixelRatio,
                  rect.top * after.devicePixelRatio,
                  rect.width * after.devicePixelRatio,
                  rect.height * after.devicePixelRatio,
                ]
              : null;
          final identities = candidate.sourceIdentities.toList()..sort();
          final reasons = candidate.reasons.toList()..sort();
          final sources = candidate.sources.toList()..sort();
          return <String, Object?>{
            'logicalRect': <double>[
              rect.left,
              rect.top,
              rect.width,
              rect.height,
            ],
            'physicalRect': physicalRect,
            'reasons': reasons,
            'sourceIdentities': identities.take(8).toList(growable: false),
            if (identities.length > 8)
              'sourceIdentitiesOmitted': identities.length - 8,
            'geometryProvenance': <String, Object?>{
              'kind': 'derived_observation',
              'sources': sources,
              'logicalSpace': 'flutter_view_top_left',
              'physicalDerivation': coordinateFrameStable
                  ? 'logical_rect_times_current_device_pixel_ratio'
                  : 'unavailable_coordinate_frame_changed',
            },
          };
        })
        .toList(growable: false);
    final issues = <String>[
      if (!coordinateFrameStable) 'coordinate_frame_changed_or_unavailable',
      if (globalScopeChanged) 'screen_or_route_changed',
      if (ambiguousGeometryCount > 0) 'ambiguous_geometry',
      if (unavailableGeometryCount > 0) 'unavailable_geometry',
      if (omittedRegionCount > 0) 'region_list_truncated',
      if (ordered.isEmpty) 'no_visible_changed_region',
    ];
    return (
      regions: returned,
      coverage: <String, Object?>{
        'status': issues.isEmpty ? 'complete' : 'incomplete',
        'basis': 'snapshot_relative_agent_observable_semantic_geometry',
        'baselineSnapshotId': before.snapshotId,
        'currentSnapshotId': after.snapshotId,
        'coordinateFrameStable': coordinateFrameStable,
        'globalScopeChanged': globalScopeChanged,
        'totalRegionCount': ordered.length,
        'returnedRegionCount': returned.length,
        'maximumReturnedRegions': maximumReturnedRegions,
        'omittedRegionCount': omittedRegionCount,
        'ambiguousGeometryCount': ambiguousGeometryCount,
        'unavailableGeometryCount': unavailableGeometryCount,
        'nonVisualChangeCount': nonVisualChangeCount,
        'issues': issues,
        'limitations': const <String>[
          'Regions derive from agent-observable semantic and render geometry, not pixel differencing.',
          'Unchanged semantic geometry cannot reveal custom-painted pixel-only changes.',
        ],
      },
    );
  }

  bool _sameSize(Size a, Size b) =>
      (a.width - b.width).abs() <= 0.000001 &&
      (a.height - b.height).abs() <= 0.000001;

  bool _validChangedRegionRect(Rect value) =>
      value.isFinite && value.width > 0 && value.height > 0;

  Rect? _changedRegionRectFromJson(Object? value) {
    if (value is! List || value.length < 4) return null;
    final numbers = value
        .take(4)
        .map((item) => item is num ? item.toDouble() : double.nan)
        .toList(growable: false);
    if (numbers.any((item) => !item.isFinite) ||
        numbers[2] <= 0 ||
        numbers[3] <= 0) {
      return null;
    }
    return Rect.fromLTWH(numbers[0], numbers[1], numbers[2], numbers[3]);
  }

  Rect? _unionChangedRegionRects(Rect? a, Rect? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.expandToInclude(b);
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
    return _protocolOk(value);
  }

  developer.ServiceExtensionResponse _fail(
    String code,
    String message, {
    Map<String, Object?> extra = const {},
  }) {
    return _protocolFail(code, message, extra: extra);
  }
}
