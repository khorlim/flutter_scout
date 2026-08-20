part of 'flutter_scout_binding.dart';

// part: bounded orientation, location, reveal, and snapshot-relative deltas.

const int _navigationSnapshotHistoryLimit = 32;
const int _navigationSnapshotHistoryApproximateByteLimit = 4 * 1024 * 1024;
const int _navigationDefaultMaxResponseBytes = 64 * 1024;

final Expando<_NavigationState> _navigationStateByRuntime =
    Expando<_NavigationState>('flutter_scout_navigation');

class _NavigationState {
  final List<_NavigationSnapshotRecord> history = <_NavigationSnapshotRecord>[];
}

class _NavigationSnapshotRecord {
  const _NavigationSnapshotRecord({
    required this.runId,
    required this.runtimeInstanceId,
    required this.snapshot,
    required this.approximateBytes,
  });

  final String? runId;
  final String runtimeInstanceId;
  final ScoutSnapshot snapshot;
  final int approximateBytes;
}

class _SnapshotHistoryLookup {
  const _SnapshotHistoryLookup.success({
    required this.requestedSnapshotId,
    required this.current,
    required this.baselineRecord,
  }) : errorCode = null,
       errorMessage = null,
       reason = null;

  const _SnapshotHistoryLookup.failure({
    required this.requestedSnapshotId,
    required this.current,
    required this.errorCode,
    required this.errorMessage,
    required this.reason,
  }) : baselineRecord = null;

  final String requestedSnapshotId;
  final ScoutSnapshot current;
  final _NavigationSnapshotRecord? baselineRecord;
  final String? errorCode;
  final String? errorMessage;
  final String? reason;

  bool get ok => baselineRecord != null && errorCode == null;
  ScoutSnapshot get baseline => baselineRecord!.snapshot;
}

class _NavigationScrollRegion {
  _NavigationScrollRegion({
    required this.id,
    required this.baseId,
    required this.occurrence,
    required this.key,
    required this.axisDirection,
    required this.rect,
    required this.visibleRect,
    required this.element,
    required this.state,
    required this.treeOrdinal,
    required this.coordinateDevicePixelRatio,
  });

  final String id;
  final String baseId;
  final int occurrence;
  final String? key;
  final AxisDirection axisDirection;
  final Rect rect;
  final Rect? visibleRect;
  final Element element;
  final ScrollableState state;
  final int treeOrdinal;
  final double? coordinateDevicePixelRatio;
  String? parentId;
  int nestingDepth = 0;
  List<String> scopePath = const <String>[];

  ScrollPosition? get position {
    try {
      return state.position;
    } catch (_) {
      return null;
    }
  }

  bool get vertical => axisDirectionToAxis(axisDirection) == Axis.vertical;

  bool containsNode(ScoutNode node) {
    var current = node._renderObject;
    final regionRenderObject = element.renderObject;
    while (current != null) {
      if (identical(current, regionRenderObject)) return true;
      final parent = current.parent;
      current = parent is RenderObject ? parent : null;
    }
    final nodeRect = node.rect;
    if (nodeRect == null) return false;
    final crossAxisOverlap = vertical
        ? math.min(rect.right, nodeRect.right) -
              math.max(rect.left, nodeRect.left)
        : math.min(rect.bottom, nodeRect.bottom) -
              math.max(rect.top, nodeRect.top);
    return crossAxisOverlap > 0;
  }

  Map<String, Object?> toJson({bool includePosition = true}) {
    final observation =
        _SnapshotScrollRegion(
            id: id,
            baseId: baseId,
            occurrence: occurrence,
            key: key,
            widgetType: element.widget.runtimeType.toString(),
            axisDirection: axisDirection,
            rect: rect,
            visibleRect: visibleRect,
            element: element,
            state: state,
            treeOrdinal: treeOrdinal,
            coordinateDevicePixelRatio: coordinateDevicePixelRatio,
          )
          ..parentId = parentId
          ..nestingDepth = nestingDepth
          ..scopePath = scopePath;
    final result = observation.toJson(includeEphemeralPositionIdentity: true);
    if (!includePosition) {
      result.removeWhere(
        (key, _) => const <String>{
          'pixels',
          'minScrollExtent',
          'maxScrollExtent',
          'extentBefore',
          'extentAfter',
          'viewportDimension',
          'approximateNormalizedPosition',
          'normalizedPositionEvidence',
          'atStart',
          'atEnd',
          'canScroll',
        }.contains(key),
      );
    }
    return result;
  }
}

class _NavigationScopeSelection {
  const _NavigationScopeSelection({
    required this.regions,
    this.selected,
    this.failureCode,
    this.failureMessage,
    this.resolution,
  });

  final List<_NavigationScrollRegion> regions;
  final _NavigationScrollRegion? selected;
  final String? failureCode;
  final String? failureMessage;
  final _TargetResolution? resolution;

  bool get ok => selected != null && failureCode == null;
}

extension _RuntimeNavigation on FlutterScoutRuntime {
  _NavigationState get _navigationState =>
      _navigationStateByRuntime[this] ??= _NavigationState();

  /// Retains only detached, redacted semantic state. Old RenderObjects and
  /// Elements must not be kept alive merely to support `inspect --since`.
  ScoutSnapshot _rememberNavigationSnapshot(ScoutSnapshot snapshot) {
    final state = _navigationState;
    final duplicateIndex = state.history.indexWhere(
      (item) =>
          item.snapshot.snapshotId == snapshot.snapshotId &&
          item.runId == _boundRunId &&
          item.runtimeInstanceId == _runtimeInstanceId,
    );
    if (duplicateIndex >= 0) return snapshot;

    final detached = _detachNavigationSnapshot(snapshot);
    final record = _NavigationSnapshotRecord(
      runId: _boundRunId,
      runtimeInstanceId: _runtimeInstanceId,
      snapshot: detached,
      approximateBytes: _navigationSnapshotApproximateBytes(detached),
    );
    state.history.add(record);
    var retainedBytes = state.history.fold<int>(
      0,
      (total, item) => total + item.approximateBytes,
    );
    while (state.history.length > 1 &&
        (state.history.length > _navigationSnapshotHistoryLimit ||
            retainedBytes > _navigationSnapshotHistoryApproximateByteLimit)) {
      retainedBytes -= state.history.removeAt(0).approximateBytes;
    }
    return snapshot;
  }

  int _navigationSnapshotApproximateBytes(ScoutSnapshot snapshot) {
    var stringUnits =
        snapshot.screen.length + (snapshot.routeGuess?.length ?? 0);
    for (final value in <String>[
      ...snapshot.visibleText,
      ...snapshot.hitTestableText,
      ...snapshot.offscreenText,
    ]) {
      stringUnits += value.length;
    }
    for (final node in <ScoutNode>[
      ...snapshot.interactables,
      ...snapshot.fields,
      ...snapshot.textTargets,
    ]) {
      stringUnits +=
          node.id.length +
          node.baseId.length +
          node.fallbackId.length +
          node.widgetType.length +
          (node.label?.length ?? 0) +
          (node.value?.length ?? 0) +
          (node.validationMessage?.length ?? 0) +
          (node.key?.length ?? 0);
    }
    final nodeCount =
        snapshot.interactables.length +
        snapshot.fields.length +
        snapshot.textTargets.length;
    return stringUnits * 2 + nodeCount * 192 + 2048;
  }

  ScoutSnapshot _detachNavigationSnapshot(ScoutSnapshot source) {
    ScoutNode node(ScoutNode value) => ScoutNode(
      id: value.id,
      baseId: value.baseId,
      ordinal: value.ordinal,
      fallbackId: value.fallbackId,
      kind: value.kind,
      label: value.label,
      value: value.value,
      validationMessage: value.validationMessage,
      widgetType: value.widgetType,
      key: value.key,
      rect: value.rect,
      visibleRect: value.visibleRect,
      visibleFraction: value.visibleFraction,
      suggestedTapPoint: value.suggestedTapPoint,
      hitTestable: value.hitTestable,
      enabled: value.enabled,
      confidence: value.confidence,
      coordinateDevicePixelRatio: value.coordinateDevicePixelRatio,
      selected: value.selected,
      altIds: List<String>.from(value.altIds),
      textColor: value.textColor,
      enclosingTarget: value.enclosingTarget,
      obscured: value.obscured,
      redacted: value.redacted,
      isEmpty: value.isEmpty,
      valueToken: value._valueToken,
      treeOrdinal: value._treeOrdinal,
    );

    Map<String, Object?>? mapCopy(Map<String, Object?>? value) => value == null
        ? null
        : Map<String, Object?>.from(
            jsonDecode(jsonEncode(value)) as Map<String, dynamic>,
          );
    List<Map<String, Object?>> mapList(List<Map<String, Object?>> values) =>
        <Map<String, Object?>>[for (final value in values) mapCopy(value)!];

    return ScoutSnapshot(
      screen: source.screen,
      screenEvidence: Map<String, Object?>.from(source.screenEvidence),
      activeSurface: mapCopy(source.activeSurface),
      routeGuess: source.routeGuess,
      idle: source.idle,
      devicePixelRatio: source.devicePixelRatio,
      logicalSize: source.logicalSize,
      physicalSize: source.physicalSize,
      padding: source.padding,
      viewPadding: source.viewPadding,
      viewInsets: source.viewInsets,
      viewMetricsAvailable: source.viewMetricsAvailable,
      visibleText: List<String>.from(source.visibleText),
      hitTestableText: List<String>.from(source.hitTestableText),
      offscreenText: List<String>.from(source.offscreenText),
      interactables: [for (final value in source.interactables) node(value)],
      fields: [for (final value in source.fields) node(value)],
      textTargets: [for (final value in source.textTargets) node(value)],
      scrollables: mapList(source.scrollables),
      perceptionGaps: mapList(source.perceptionGaps),
      captureBackend: mapCopy(source.captureBackend)!,
      overlays: mapList(source.overlays),
      visualTree: null,
      controlGroups: const [],
      structuredRows: const [],
      suggestedActions: const [],
      recentErrors: mapList(source.recentErrors),
      stateGeneration: source.stateGeneration,
      stateDigest: source.stateDigest,
      degradedNodes: source.degradedNodes,
    );
  }

  Future<developer.ServiceExtensionResponse> _handleNavigationInspect(
    String method,
    Map<String, String> params,
  ) async {
    final action = params['navigationAction'];
    if (action == 'where') return _handleWhere(method, params);
    if (action == 'locate') return _handleLocate(method, params);
    if ((params['since'] ?? '').isNotEmpty) {
      return _handleInspectSince(method, params);
    }
    return _handleInspect(method, params);
  }

  Future<developer.ServiceExtensionResponse> _handleWhere(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final snapshot = _snapshot();
      final regions = _navigationScrollRegions(snapshot);
      final root = WidgetsBinding.instance.rootElement;
      final activeNavigator = root == null ? null : _findActiveNavigator(root);
      final navigators = <Map<String, Object?>>[];
      final tabs = <Map<String, Object?>>[];
      if (root != null) {
        _walkVisible(root, (element) {
          if (element is StatefulElement && element.state is NavigatorState) {
            final navigator = element.state as NavigatorState;
            final rect = _rectFor(element);
            var depth = 0;
            element.visitAncestorElements((ancestor) {
              if (ancestor is StatefulElement &&
                  ancestor.state is NavigatorState) {
                depth += 1;
              }
              return true;
            });
            navigators.add(<String, Object?>{
              'identity': identityHashCode(navigator),
              'depth': depth,
              'active': identical(navigator, activeNavigator),
              'canPop': navigator.canPop(),
              if (element.widget.key != null)
                'key': element.widget.key.toString(),
              if (rect != null)
                'rect': [rect.left, rect.top, rect.width, rect.height],
            });
          }
          final widget = element.widget;
          if (widget is TabBar) {
            final controller =
                widget.controller ?? DefaultTabController.maybeOf(element);
            tabs.add(<String, Object?>{
              'widget': 'TabBar',
              'index': controller?.index,
              'previousIndex': controller?.previousIndex,
              'length': controller?.length ?? widget.tabs.length,
              'changing': controller?.indexIsChanging,
              'labels': [
                for (final tab in widget.tabs)
                  if (tab is Tab) tab.text ?? tab.icon?.runtimeType.toString(),
              ],
            });
          }
        });
      }
      final selected = <Map<String, Object?>>[
        for (final node in snapshot.interactables)
          if (node.selected == true)
            <String, Object?>{
              'handle': node.id,
              'label': node.label,
              'widgetType': node.widgetType,
            },
      ];
      final keyboardInset = snapshot.viewInsets.bottom;
      final payload = <String, Object?>{
        'orientation': 'where',
        'result': 'orientation',
        'observationEffects': _observationEffects(
          _FrameAdvancePolicy.observeOnly,
        ),
        'route': snapshot.routeGuess,
        'screen': snapshot.screen,
        'screenEvidence': snapshot.screenEvidence,
        'activeSurface': snapshot.activeSurface,
        'activeTabCandidates': selected,
        'tabSystems': tabs,
        'navigators': navigators,
        'overlays': snapshot.overlays,
        'keyboard': <String, Object?>{
          'visible': keyboardInset > 0.5,
          'logicalInsetBottom': snapshot.viewMetricsAvailable
              ? keyboardInset
              : null,
          'changesLayoutViewport': keyboardInset > 0.5,
          'source': snapshot.viewMetricsAvailable
              ? 'flutter_view_metrics'
              : 'observation_unavailable',
        },
        'scrollRegions': [for (final region in regions) region.toJson()],
        'panes': _navigationPanes(regions),
        'coordinateFrame': <String, Object?>{
          'primarySpace': 'logical_flutter_pixels',
          'origin': 'top_left',
          'xDirection': 'right',
          'yDirection': 'down',
          'logicalViewport': [
            0,
            0,
            snapshot.logicalSize.width,
            snapshot.logicalSize.height,
          ],
          'devicePixelRatio': snapshot.devicePixelRatio,
          'physicalViewport': [
            0,
            0,
            snapshot.viewMetricsAvailable ? snapshot.physicalSize.width : null,
            snapshot.viewMetricsAvailable ? snapshot.physicalSize.height : null,
          ],
          'viewMetrics': snapshot.viewportJson(),
        },
        'scope': _targetScope(snapshot),
        'limitations': const <String>[
          'Route names are available only when the app supplied RouteSettings.name.',
          'Tab facts use public TabController and semantics selection state; custom tab systems may appear only as selected controls.',
          'Split panes are inferred from independently visible scroll regions and geometry.',
          'Lazy-list children outside the built extent cannot be located without bounded reveal.',
          'Platform-view contents require screenshot or native accessibility evidence.',
        ],
      };
      return _navigationBoundedOk(payload, params);
    } catch (error) {
      return _fail('orientation_failed', error.toString());
    }
  }

  Future<developer.ServiceExtensionResponse> _handleLocate(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final snapshot = _snapshot();
      final query = _navigationQuery(params);
      if (query == null) {
        return _fail(
          'invalid_navigation_query',
          'Provide exactly one of text or target.',
          extra: <String, Object?>{
            'operation': 'locate',
            'activation': const {'dispatched': false},
          },
        );
      }
      final within = params['within']?.trim();
      final selection = within == null || within.isEmpty
          ? null
          : _selectNavigationScrollRegion(
              snapshot,
              within: within,
              requireExplicit: true,
            );
      if (selection != null && !selection.ok) {
        return _navigationScopeFailure(
          operation: 'locate',
          query: query,
          snapshot: snapshot,
          selection: selection,
          params: params,
        );
      }
      final resolution = _resolveNavigationQuery(
        snapshot,
        query,
        region: selection?.selected,
        safety: _TargetSafety.identify,
      );
      final payload = _navigationLocatePayload(
        query: query,
        within: within,
        snapshot: snapshot,
        region: selection?.selected,
        resolution: resolution,
        params: params,
      );
      if (!resolution.isUnique) {
        return _navigationResolutionFailure(
          operation: 'locate',
          resolution: resolution,
          payload: payload,
          params: params,
        );
      }
      return _navigationBoundedOk(payload, params);
    } catch (error) {
      return _fail('locate_failed', error.toString());
    }
  }

  Future<developer.ServiceExtensionResponse> _handleReveal(
    String method,
    Map<String, String> params,
  ) async {
    final stopwatch = Stopwatch()..start();
    ScoutSnapshot? before;
    _NavigationScrollRegion? restorationRegion;
    ScrollPosition? restorationPosition;
    double? restorationOffset;
    var dispatchCount = 0;
    var distanceUsed = 0.0;
    try {
      // This is pre-dispatch stabilization for the navigation precondition,
      // not observation of an action outcome. Keep it in `snapshot` so the
      // canonical post-dispatch `settle` interval remains truthful.
      await _inRequestPhaseAsync(
        'snapshot',
        _settleMutationFramesWithoutPhaseTiming,
      );
      before = _snapshot();
      final query = _navigationQuery(params);
      final bounds = _revealBounds(params, before);
      if (query == null) {
        return _fail(
          'invalid_navigation_query',
          'Provide exactly one of text or target.',
          extra: _revealBasePayload(
            query: const <String, Object?>{'invalid': true},
            within: params['within'],
            direction: params['direction'] ?? 'down',
            before: before,
            bounds: bounds,
            stopwatch: stopwatch,
            stoppingReason: 'invalid_query',
            activationDispatched: false,
          ),
        );
      }
      final direction = (params['direction'] ?? 'down').trim();
      if (!const {'up', 'down', 'left', 'right'}.contains(direction)) {
        return _fail(
          'invalid_direction',
          'Direction must be up, down, left, or right.',
          extra: _revealBasePayload(
            query: query,
            within: params['within'],
            direction: direction,
            before: before,
            bounds: bounds,
            stopwatch: stopwatch,
            stoppingReason: 'invalid_direction',
            activationDispatched: false,
          ),
        );
      }

      var resolution = _resolveNavigationQuery(
        before,
        query,
        safety: _TargetSafety.mutate,
      );
      final within = params['within']?.trim();
      if (resolution.isUnique && (within == null || within.isEmpty)) {
        _markRequestPhaseUnavailable(
          'dispatch',
          'not_applicable:navigation_target_already_visible_no_dispatch',
        );
        _markRequestPhaseUnavailable(
          'settle',
          'not_applicable:navigation_target_already_visible_no_post_dispatch_settle',
        );
        return _navigationBoundedOk(<String, Object?>{
          ..._revealBasePayload(
            query: query,
            within: params['within'],
            direction: direction,
            before: before,
            bounds: bounds,
            stopwatch: stopwatch,
            stoppingReason: 'already_visible',
            activationDispatched: false,
          ),
          'revealed': true,
          'result': 'already_visible',
          'resolution': _compactNavigationResolution(resolution),
          'progressSignatures': [_navigationProgressSignature(before, null)],
          'scrollRegionsAttempted': const <Object?>[],
          'repeatedStateDetected': false,
          'loopDetected': false,
          'endOfContentDetected': false,
          'restoration': const <String, Object?>{
            'attempted': false,
            'result': 'not_required',
          },
          'before': _navigationSnapshotEvidence(before),
          'after': _navigationSnapshotEvidence(before),
          'delta': _delta(before, before),
        }, params);
      }
      final canScopeAmbiguity =
          resolution.status == _TargetResolutionStatus.ambiguous &&
          within != null &&
          within.isNotEmpty;
      if (!_navigationResolutionMayReveal(resolution) && !canScopeAmbiguity) {
        return _navigationResolutionFailure(
          operation: 'reveal',
          resolution: resolution,
          payload: <String, Object?>{
            ..._revealBasePayload(
              query: query,
              within: params['within'],
              direction: direction,
              before: before,
              bounds: bounds,
              stopwatch: stopwatch,
              stoppingReason: 'unsafe_initial_resolution',
              activationDispatched: false,
            ),
            'revealed': false,
            'resolution': _compactNavigationResolution(resolution),
            'progressSignatures': [_navigationProgressSignature(before, null)],
            'scrollRegionsAttempted': const <Object?>[],
            'repeatedStateDetected': false,
            'loopDetected': false,
            'endOfContentDetected': false,
            'restoration': const <String, Object?>{
              'attempted': false,
              'result': 'not_required',
            },
          },
          params: params,
        );
      }

      final selection = _selectNavigationScrollRegion(
        before,
        within: within,
        requireExplicit: true,
      );
      if (!selection.ok) {
        return _navigationScopeFailure(
          operation: 'reveal',
          query: query,
          snapshot: before,
          selection: selection,
          params: params,
          bounds: bounds,
          direction: direction,
          stopwatch: stopwatch,
        );
      }
      final selected = selection.selected!;
      resolution = _resolveNavigationQuery(
        before,
        query,
        region: selected,
        safety: _TargetSafety.mutate,
      );
      if (resolution.isUnique) {
        _markRequestPhaseUnavailable(
          'dispatch',
          'not_applicable:navigation_target_already_visible_no_dispatch',
        );
        _markRequestPhaseUnavailable(
          'settle',
          'not_applicable:navigation_target_already_visible_no_post_dispatch_settle',
        );
        return _navigationBoundedOk(<String, Object?>{
          ..._revealBasePayload(
            query: query,
            within: within,
            direction: direction,
            before: before,
            bounds: bounds,
            stopwatch: stopwatch,
            stoppingReason: 'already_visible',
            activationDispatched: false,
          ),
          'revealed': true,
          'result': 'already_visible',
          'resolution': _compactNavigationResolution(resolution),
          'selectedScrollRegion': selected.toJson(),
          'progressSignatures': [
            _navigationProgressSignature(before, selected),
          ],
          'scrollRegionsAttempted': const <Object?>[],
          'repeatedStateDetected': false,
          'loopDetected': false,
          'endOfContentDetected': false,
          'restoration': const <String, Object?>{
            'attempted': false,
            'result': 'not_required',
          },
          'before': _navigationSnapshotEvidence(before),
          'after': _navigationSnapshotEvidence(before),
          'delta': _delta(before, before),
        }, params);
      }
      if (!_navigationResolutionMayReveal(resolution)) {
        return _navigationResolutionFailure(
          operation: 'reveal',
          resolution: resolution,
          payload: <String, Object?>{
            ..._revealBasePayload(
              query: query,
              within: within,
              direction: direction,
              before: before,
              bounds: bounds,
              stopwatch: stopwatch,
              stoppingReason: 'unsafe_scoped_resolution',
              activationDispatched: false,
            ),
            'revealed': false,
            'resolution': _compactNavigationResolution(resolution),
            'selectedScrollRegion': selected.toJson(),
            'progressSignatures': [
              _navigationProgressSignature(before, selected),
            ],
            'scrollRegionsAttempted': const <Object?>[],
            'repeatedStateDetected': false,
            'loopDetected': false,
            'endOfContentDetected': false,
            'restoration': const <String, Object?>{
              'attempted': false,
              'result': 'not_required',
            },
          },
          params: params,
        );
      }
      if ((selected.vertical &&
              (direction == 'left' || direction == 'right')) ||
          (!selected.vertical && (direction == 'up' || direction == 'down'))) {
        return _fail(
          'invalid_direction',
          'Direction `$direction` does not match selected ${selected.vertical ? 'vertical' : 'horizontal'} scroll region `${selected.id}`.',
          extra: <String, Object?>{
            ..._revealBasePayload(
              query: query,
              within: params['within'],
              direction: direction,
              before: before,
              bounds: bounds,
              stopwatch: stopwatch,
              stoppingReason: 'direction_axis_mismatch',
              activationDispatched: false,
            ),
            'scrollRegions': [
              for (final region in selection.regions) region.toJson(),
            ],
            'selectedScrollRegion': selected.toJson(),
          },
        );
      }
      final initialPosition = selected.position;
      if (initialPosition == null ||
          !initialPosition.hasPixels ||
          !initialPosition.hasContentDimensions) {
        return _fail(
          'scrollable_not_found',
          'Selected scroll region `${selected.id}` has no attached content position.',
          extra: <String, Object?>{
            ..._revealBasePayload(
              query: query,
              within: params['within'],
              direction: direction,
              before: before,
              bounds: bounds,
              stopwatch: stopwatch,
              stoppingReason: 'scroll_position_unavailable',
              activationDispatched: false,
            ),
            'selectedScrollRegion': selected.toJson(),
          },
        );
      }
      final initialOffset = initialPosition.pixels;
      restorationRegion = selected;
      restorationPosition = initialPosition;
      restorationOffset = initialOffset;
      final initialPositionIdentity = identityHashCode(initialPosition);
      final seen = <String>{};
      final progress = <Map<String, Object?>>[];
      final attempted = <Map<String, Object?>>[];
      var current = before;
      var repeated = false;
      var loop = false;
      var endOfContent = false;
      var stoppingReason = 'action_bound_exhausted';
      ScoutSnapshot failureSnapshot = current;
      _TargetResolution? finalResolution = resolution;

      void recordProgress(
        ScoutSnapshot snapshot,
        _NavigationScrollRegion region,
      ) {
        final signature = _navigationProgressSignature(snapshot, region);
        final token = signature['signature']!.toString();
        if (!seen.add(token)) repeated = true;
        progress.add(signature);
      }

      recordProgress(current, selected);
      while (dispatchCount < bounds.maxActions &&
          distanceUsed < bounds.maxDistance &&
          stopwatch.elapsedMilliseconds < bounds.maxTimeMs) {
        final dispatchSnapshot = _snapshot();
        if (dispatchSnapshot.snapshotId != current.snapshotId) {
          stoppingReason = 'stale_state_before_scroll';
          failureSnapshot = dispatchSnapshot;
          break;
        }
        final freshRegions = _navigationScrollRegions(dispatchSnapshot);
        final matching = freshRegions
            .where((region) => region.id == selected.id)
            .toList(growable: false);
        if (matching.length != 1) {
          stoppingReason = matching.isEmpty
              ? 'scroll_region_stale'
              : 'scroll_region_ambiguous';
          failureSnapshot = dispatchSnapshot;
          break;
        }
        final freshRegion = matching.single;
        final position = freshRegion.position;
        if (position == null ||
            identityHashCode(position) != initialPositionIdentity ||
            !position.hasPixels ||
            !position.hasContentDimensions) {
          stoppingReason = 'scroll_region_stale';
          failureSnapshot = dispatchSnapshot;
          break;
        }
        final remainingDistance = bounds.maxDistance - distanceUsed;
        final requestedStep = math.min(bounds.stepDistance, remainingDistance);
        final sign = direction == freshRegion.axisDirection.name ? 1.0 : -1.0;
        final from = position.pixels;
        final desired = (from + sign * requestedStep).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if ((desired - from).abs() <= 0.5) {
          endOfContent = true;
          stoppingReason = 'end_of_content';
          failureSnapshot = dispatchSnapshot;
          break;
        }
        final otherOffsets = <String, double>{
          for (final region in freshRegions)
            if (region.id != freshRegion.id &&
                region.position?.hasPixels == true)
              region.id: region.position!.pixels,
        };
        _inRequestPhase('dispatch', () => position.jumpTo(desired));
        dispatchCount += 1;
        await _settleMutationFrames();
        await _waitStable(
          frameAdvancePolicy: _FrameAdvancePolicy.mutationSettling,
          timeout: Duration(
            milliseconds: math.min(
              400,
              math.max(16, bounds.maxTimeMs - stopwatch.elapsedMilliseconds),
            ),
          ),
        );
        final after = _snapshot();
        final moved = (position.pixels - from).abs();
        distanceUsed += moved;
        final afterRegions = _navigationScrollRegions(after);
        final unintended = <String>[];
        for (final region in afterRegions) {
          final old = otherOffsets[region.id];
          final now = region.position;
          if (old != null &&
              now?.hasPixels == true &&
              (now!.pixels - old).abs() > 0.5) {
            unintended.add(region.id);
          }
        }
        attempted.add(<String, Object?>{
          'regionId': freshRegion.id,
          'positionIdentity': initialPositionIdentity,
          'action': 'jump_scroll_position',
          'direction': direction,
          'fromPixels': from,
          'requestedPixels': desired,
          'toPixels': position.pixels,
          'distance': moved,
          'stateGenerationBefore': dispatchSnapshot.stateGeneration,
          'stateGenerationAfter': after.stateGeneration,
          if (unintended.isNotEmpty)
            'unexpectedChangedScrollRegions': unintended,
        });
        failureSnapshot = after;
        if (unintended.isNotEmpty) {
          stoppingReason = 'wrong_scroll_region_changed';
          break;
        }
        if (moved <= 0.5 || !_viewportMoved(current, after)) {
          endOfContent = true;
          stoppingReason = 'end_of_content';
          break;
        }
        recordProgress(after, freshRegion);
        if (repeated) {
          loop = true;
          stoppingReason = 'repeated_state_loop';
          break;
        }
        resolution = _resolveNavigationQuery(
          after,
          query,
          region: freshRegion,
          safety: _TargetSafety.mutate,
        );
        finalResolution = resolution;
        if (resolution.isUnique) {
          return _navigationBoundedOk(<String, Object?>{
            ..._revealBasePayload(
              query: query,
              within: params['within'],
              direction: direction,
              before: before,
              bounds: bounds,
              stopwatch: stopwatch,
              stoppingReason: 'target_revealed',
              activationDispatched: true,
            ),
            'revealed': true,
            'result': 'revealed',
            'resolution': _compactNavigationResolution(resolution),
            'selectedScrollRegion': freshRegion.toJson(),
            'progressSignatures': progress,
            'scrollRegionsAttempted': attempted,
            'actionsUsed': dispatchCount,
            'distanceUsed': distanceUsed,
            'repeatedStateDetected': repeated,
            'loopDetected': loop,
            'endOfContentDetected': endOfContent,
            'restoration': const <String, Object?>{
              'attempted': false,
              'result': 'not_required',
            },
            'before': _navigationSnapshotEvidence(before),
            'after': _navigationSnapshotEvidence(after),
            'delta': _delta(before, after),
            'activation': const <String, Object?>{
              'dispatched': true,
              'observedChange': true,
            },
          }, params);
        }
        if (!_navigationResolutionMayReveal(resolution)) {
          stoppingReason = 'unsafe_resolution_after_scroll';
          break;
        }
        current = after;
      }
      if (stopwatch.elapsedMilliseconds >= bounds.maxTimeMs) {
        stoppingReason = 'time_bound_exhausted';
      } else if (distanceUsed >= bounds.maxDistance &&
          stoppingReason == 'action_bound_exhausted') {
        stoppingReason = 'distance_bound_exhausted';
      }
      final restoration = await _restoreNavigationPosition(
        region: selected,
        position: initialPosition,
        initialOffset: initialOffset,
      );
      final afterRestore = _snapshot();
      return _navigationBoundedFail(
        'target_not_reached',
        'Bounded reveal stopped with `$stoppingReason` before the target became uniquely actionable.',
        <String, Object?>{
          ..._revealBasePayload(
            query: query,
            within: params['within'],
            direction: direction,
            before: before,
            bounds: bounds,
            stopwatch: stopwatch,
            stoppingReason: stoppingReason,
            activationDispatched: dispatchCount > 0,
          ),
          'revealed': false,
          'result': 'not_revealed',
          if (finalResolution != null)
            'resolution': _compactNavigationResolution(finalResolution),
          'selectedScrollRegion': selected.toJson(),
          'progressSignatures': progress,
          'scrollRegionsAttempted': attempted,
          'actionsUsed': dispatchCount,
          'distanceUsed': distanceUsed,
          'repeatedStateDetected': repeated,
          'loopDetected': loop,
          'endOfContentDetected': endOfContent,
          'failureSnapshot': _navigationSnapshotEvidence(failureSnapshot),
          'restoration': restoration,
          'before': _navigationSnapshotEvidence(before),
          'after': _navigationSnapshotEvidence(afterRestore),
          'delta': _delta(before, afterRestore),
          'activation': <String, Object?>{
            'dispatched': dispatchCount > 0,
            'observedChange': dispatchCount > 0,
          },
        },
        params,
      );
    } catch (error) {
      final restoration =
          dispatchCount > 0 &&
              restorationRegion != null &&
              restorationPosition != null &&
              restorationOffset != null
          ? await _restoreNavigationPosition(
              region: restorationRegion,
              position: restorationPosition,
              initialOffset: restorationOffset,
            )
          : const <String, Object?>{
              'attempted': false,
              'result': 'not_required_no_dispatch',
            };
      return _navigationBoundedFail(
        'reveal_failed',
        error.toString(),
        <String, Object?>{
          'activation': <String, Object?>{'dispatched': dispatchCount > 0},
          'actionsUsed': dispatchCount,
          'distanceUsed': distanceUsed,
          'elapsedMs': stopwatch.elapsedMilliseconds,
          'restoration': restoration,
          if (before != null) 'before': _navigationSnapshotEvidence(before),
        },
        params,
      );
    }
  }

  Future<developer.ServiceExtensionResponse> _handleInspectSince(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final current = _snapshot();
      final lookup = _lookupNavigationSnapshot(
        current: current,
        requestedSnapshotId: params['since'] ?? '',
      );
      if (!lookup.ok) {
        return _fail(
          lookup.errorCode!,
          lookup.errorMessage!,
          extra: <String, Object?>{
            ..._navigationHistoryEvidence(current),
            'requestedSnapshotId': lookup.requestedSnapshotId,
            'reason': lookup.reason,
          },
        );
      }
      final since = lookup.requestedSnapshotId;
      final record = lookup.baselineRecord!;
      final baseline = lookup.baseline;
      return _navigationBoundedOk(<String, Object?>{
        'operation': 'inspect_since',
        'result': 'delta',
        'observationEffects': _observationEffects(
          _FrameAdvancePolicy.observeOnly,
        ),
        'requestedSnapshotId': since,
        'baselineScope': <String, Object?>{
          'runId': record.runId,
          'runtimeInstanceId': record.runtimeInstanceId,
          'stateGeneration': baseline.stateGeneration,
          'snapshotId': baseline.snapshotId,
        },
        'currentScope': _targetScope(current),
        'generationDistance':
            current.stateGeneration - baseline.stateGeneration,
        'semanticChanged': _changed(baseline, current),
        'delta': _delta(baseline, current),
        'before': _navigationSnapshotEvidence(baseline),
        'after': _navigationSnapshotEvidence(current),
        'history': _navigationHistoryEvidence(current),
      }, params);
    } catch (error) {
      return _fail('snapshot_delta_failed', error.toString());
    }
  }

  _SnapshotHistoryLookup _lookupNavigationSnapshot({
    required ScoutSnapshot current,
    required String requestedSnapshotId,
  }) {
    final since = requestedSnapshotId.trim();
    final parsed = RegExp(r'^g([0-9]+):([a-f0-9]{64})$').firstMatch(since);
    if (parsed == null) {
      return _SnapshotHistoryLookup.failure(
        requestedSnapshotId: since,
        current: current,
        errorCode: 'invalid_snapshot_id',
        errorMessage:
            'Snapshot identities must use g<generation>:<64-lowercase-hex-digest>.',
        reason: 'invalid_format',
      );
    }
    final generation = int.parse(parsed.group(1)!);
    if (generation > current.stateGeneration) {
      return _SnapshotHistoryLookup.failure(
        requestedSnapshotId: since,
        current: current,
        errorCode: 'stale_snapshot_identity',
        errorMessage:
            'The requested generation is newer than this runtime state.',
        reason: 'future_generation',
      );
    }
    final scopedHistory = _navigationState.history.where(
      (record) =>
          record.runtimeInstanceId == _runtimeInstanceId &&
          record.runId == _boundRunId,
    );
    final matches = scopedHistory
        .where((record) => record.snapshot.snapshotId == since)
        .toList(growable: false);
    if (matches.length == 1) {
      return _SnapshotHistoryLookup.success(
        requestedSnapshotId: since,
        current: current,
        baselineRecord: matches.single,
      );
    }
    final sameGeneration = scopedHistory.where(
      (record) => record.snapshot.stateGeneration == generation,
    );
    final digestMismatch = sameGeneration.isNotEmpty;
    return _SnapshotHistoryLookup.failure(
      requestedSnapshotId: since,
      current: current,
      errorCode: digestMismatch
          ? 'stale_snapshot_identity'
          : 'snapshot_history_unavailable',
      errorMessage: digestMismatch
          ? 'This runtime has a different digest for the requested generation.'
          : 'The snapshot is outside this runtime/run bounded history or was produced by another runtime.',
      reason: digestMismatch
          ? 'generation_digest_mismatch'
          : 'not_in_bounded_history',
    );
  }

  Map<String, Object?> _navigationHistoryEvidence(ScoutSnapshot current) {
    final records = _navigationState.history
        .where(
          (record) =>
              record.runtimeInstanceId == _runtimeInstanceId &&
              record.runId == _boundRunId,
        )
        .toList(growable: false);
    return <String, Object?>{
      'runId': _boundRunId,
      'runtimeInstanceId': _runtimeInstanceId,
      'currentSnapshotId': current.snapshotId,
      'currentStateGeneration': current.stateGeneration,
      'historyCapacity': _navigationSnapshotHistoryLimit,
      'historyApproximateByteLimit':
          _navigationSnapshotHistoryApproximateByteLimit,
      'historyCount': records.length,
      'historyApproximateBytes': records.fold<int>(
        0,
        (total, record) => total + record.approximateBytes,
      ),
      if (records.isNotEmpty) ...<String, Object?>{
        'oldestSnapshotId': records.first.snapshot.snapshotId,
        'newestSnapshotId': records.last.snapshot.snapshotId,
        'oldestStateGeneration': records.first.snapshot.stateGeneration,
        'newestStateGeneration': records.last.snapshot.stateGeneration,
      },
    };
  }

  Map<String, Object?>? _navigationQuery(Map<String, String> params) {
    final text = params['text']?.trim();
    final target = params['target']?.trim();
    final hasText = text != null && text.isNotEmpty;
    final hasTarget = target != null && target.isNotEmpty;
    if (hasText == hasTarget) return null;
    return <String, Object?>{
      'kind': hasText ? 'text' : 'target',
      'value': hasText ? text : target,
      if (params['contains'] == 'true') 'contains': true,
    };
  }

  _TargetResolution _resolveNavigationQuery(
    ScoutSnapshot snapshot,
    Map<String, Object?> query, {
    _NavigationScrollRegion? region,
    required _TargetSafety safety,
  }) {
    final value = query['value']!.toString();
    var resolution = query['kind'] == 'text'
        ? _resolveTextTarget(snapshot, value, loose: query['contains'] == true)
        : _resolveTarget(snapshot, value, safety: safety);
    if (region == null) return resolution;
    final candidates = resolution.candidates
        .where((candidate) => region.containsNode(candidate.node))
        .toList(growable: false);
    if (candidates.isEmpty) {
      return _TargetResolution(
        status: _TargetResolutionStatus.notFound,
        requested: value,
        snapshot: snapshot,
        scope: <String, Object?>{
          ..._targetScope(snapshot),
          'within': region.id,
        },
        candidates: const [],
        reason:
            'No matching node belongs to selected scroll region `${region.id}`.',
      );
    }
    if (candidates.length > 1) {
      return _TargetResolution(
        status: _TargetResolutionStatus.ambiguous,
        requested: value,
        snapshot: snapshot,
        scope: <String, Object?>{
          ..._targetScope(snapshot),
          'within': region.id,
        },
        candidates: candidates,
        reason: '${candidates.length} matching nodes belong to `${region.id}`.',
      );
    }
    final candidate = candidates.single;
    resolution = _applyTargetSafety(
      snapshot: snapshot,
      requested: value,
      candidate: candidate,
      safety: safety,
      scope: <String, Object?>{..._targetScope(snapshot), 'within': region.id},
      textNode: resolution.textNode,
    );
    return resolution;
  }

  bool _navigationResolutionMayReveal(_TargetResolution resolution) =>
      resolution.status == _TargetResolutionStatus.notFound ||
      resolution.status == _TargetResolutionStatus.hidden;

  List<_NavigationScrollRegion> _navigationScrollRegions(
    ScoutSnapshot snapshot,
  ) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return const [];
    final occurrences = <String, int>{};
    final regions = <_NavigationScrollRegion>[];
    var ordinal = 0;
    _walkVisible(root, (element) {
      final widget = element.widget;
      if (widget is! Scrollable) return;
      final key = _nearestScrollableKey(element);
      final baseId = 'scroll.${_slug(key ?? widget.axisDirection.name)}';
      final occurrence = occurrences.update(
        baseId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      // Count every observed Scrollable before filtering action-ineligible
      // geometry/state. This keeps snapshot, resolver, and navigation handles
      // identical even when an earlier same-base region is locally degraded.
      if (element is! StatefulElement || element.state is! ScrollableState) {
        return;
      }
      final rect = _rectFor(element);
      if (rect == null || rect.width <= 0 || rect.height <= 0) return;
      final region = _NavigationScrollRegion(
        id: occurrence == 1 ? baseId : '${baseId}_$occurrence',
        baseId: baseId,
        occurrence: occurrence,
        key: key,
        axisDirection: widget.axisDirection,
        rect: rect,
        visibleRect: _visibleRectFor(rect),
        element: element,
        state: element.state as ScrollableState,
        treeOrdinal: ordinal++,
        coordinateDevicePixelRatio: snapshot.viewMetricsAvailable
            ? snapshot.devicePixelRatio
            : null,
      );
      regions.add(region);
    });
    final byState = <ScrollableState, _NavigationScrollRegion>{
      for (final region in regions) region.state: region,
    };
    for (final region in regions) {
      region.element.visitAncestorElements((ancestor) {
        if (ancestor is StatefulElement && ancestor.state is ScrollableState) {
          region.nestingDepth += 1;
          region.parentId ??= byState[ancestor.state as ScrollableState]?.id;
        }
        return true;
      });
    }
    final byId = <String, _NavigationScrollRegion>{
      for (final region in regions) region.id: region,
    };
    List<String> scopePathFor(
      _NavigationScrollRegion region,
      Set<String> seen,
    ) {
      if (!seen.add(region.id)) return <String>[region.id];
      final parent = region.parentId == null ? null : byId[region.parentId];
      if (parent == null) return <String>[region.id];
      return <String>[...scopePathFor(parent, seen), region.id];
    }

    for (final region in regions) {
      region.scopePath = scopePathFor(region, <String>{});
    }
    return regions
        .where((region) => _navigationRegionOnActiveSurface(snapshot, region))
        .toList(growable: false);
  }

  bool _navigationRegionOnActiveSurface(
    ScoutSnapshot snapshot,
    _NavigationScrollRegion region,
  ) {
    if (snapshot.activeSurface == null) return region.visibleRect != null;
    final surface =
        _rectFromJson(snapshot.activeSurface?['rect']) ??
        _surfaceRectFor(snapshot);
    if (surface == null || region.visibleRect == null) return false;
    final overlap = surface.intersect(region.visibleRect!);
    return overlap.width > 0 && overlap.height > 0;
  }

  _NavigationScopeSelection _selectNavigationScrollRegion(
    ScoutSnapshot snapshot, {
    String? within,
    required bool requireExplicit,
  }) {
    final regions = _navigationScrollRegions(snapshot);
    if (within == null || within.isEmpty) {
      if (regions.isEmpty) {
        return const _NavigationScopeSelection(
          regions: [],
          failureCode: 'scrollable_not_found',
          failureMessage:
              'No visible scroll region exists on the active surface.',
        );
      }
      if (requireExplicit && regions.length != 1) {
        return _NavigationScopeSelection(
          regions: regions,
          failureCode: 'target_ambiguous',
          failureMessage:
              '${regions.length} visible scroll regions exist; choose one with --within <scroll-id>.',
        );
      }
      return _NavigationScopeSelection(
        regions: regions,
        selected: regions.single,
      );
    }
    final resolution = _resolveTarget(
      snapshot,
      within,
      safety: _TargetSafety.identify,
    );
    if (!resolution.isUnique) {
      return _NavigationScopeSelection(
        regions: regions,
        failureCode: resolution.status == _TargetResolutionStatus.ambiguous
            ? 'target_ambiguous'
            : 'scrollable_not_found',
        failureMessage:
            resolution.reason ?? 'The requested scroll scope is not unique.',
        resolution: resolution,
      );
    }
    final matches = regions
        .where((region) => region.id == resolution.node!.id)
        .toList(growable: false);
    if (matches.length != 1) {
      return _NavigationScopeSelection(
        regions: regions,
        failureCode: matches.isEmpty
            ? 'scrollable_not_found'
            : 'target_ambiguous',
        failureMessage: matches.isEmpty
            ? '`$within` resolved to `${resolution.node!.id}`, which is not an active scroll region.'
            : '`$within` identifies more than one active scroll region.',
        resolution: resolution,
      );
    }
    return _NavigationScopeSelection(
      regions: regions,
      selected: matches.single,
      resolution: resolution,
    );
  }

  List<Map<String, Object?>> _navigationPanes(
    List<_NavigationScrollRegion> regions,
  ) {
    final topLevel = regions
        .where((region) => region.parentId == null)
        .toList(growable: false);
    if (topLevel.length < 2) return const [];
    return <Map<String, Object?>>[
      for (var index = 0; index < topLevel.length; index++)
        <String, Object?>{
          'pane': index + 1,
          'scrollRegionId': topLevel[index].id,
          'rect': [
            topLevel[index].rect.left,
            topLevel[index].rect.top,
            topLevel[index].rect.width,
            topLevel[index].rect.height,
          ],
        },
    ];
  }

  Map<String, Object?> _navigationLocatePayload({
    required Map<String, Object?> query,
    required String? within,
    required ScoutSnapshot snapshot,
    required _NavigationScrollRegion? region,
    required _TargetResolution resolution,
    required Map<String, String> params,
  }) => <String, Object?>{
    'operation': 'locate',
    'result': resolution.status.name,
    'readOnly': true,
    'observationEffects': _observationEffects(_FrameAdvancePolicy.observeOnly),
    'query': query,
    'scope': <String, Object?>{
      ..._targetScope(snapshot),
      if (within != null && within.isNotEmpty) 'within': within,
    },
    'searchRegion':
        region?.toJson() ??
        <String, Object?>{
          'kind': snapshot.activeSurface == null
              ? 'logical_viewport'
              : 'active_surface',
          'rect':
              snapshot.activeSurface?['rect'] ??
              <Object?>[
                0,
                0,
                snapshot.logicalSize.width,
                snapshot.logicalSize.height,
              ],
        },
    'coordinateFrame': <String, Object?>{
      'primarySpace': 'logical_flutter_points',
      'origin': 'flutter_view_top_left',
      'xDirection': 'right',
      'yDirection': 'down',
      'logicalViewport': <Object?>[
        0,
        0,
        snapshot.logicalSize.width,
        snapshot.logicalSize.height,
      ],
      'physicalViewport': <Object?>[
        0,
        0,
        snapshot.viewMetricsAvailable ? snapshot.physicalSize.width : null,
        snapshot.viewMetricsAvailable ? snapshot.physicalSize.height : null,
      ],
      'devicePixelRatio': snapshot.viewMetricsAvailable
          ? snapshot.devicePixelRatio
          : null,
      'logicalToPhysicalScale': snapshot.viewMetricsAvailable
          ? snapshot.devicePixelRatio
          : null,
      'viewMetricsAvailable': snapshot.viewMetricsAvailable,
      'provenance': snapshot.viewMetricsAvailable
          ? 'flutter_view_physical_size_and_device_pixel_ratio'
          : 'unavailable',
      'nativeImageContract':
          'display_top_left_and_exact_physical_viewport_dimensions_required',
    },
    'direction': 'none',
    'startingStateGeneration': snapshot.stateGeneration,
    'bounds': <String, Object?>{
      'actions': 0,
      'distance': 0,
      'timeMs': 0,
      'maxCandidates': _navigationMaxCandidates(params),
      'maxResponseBytes': _navigationMaxResponseBytes(params),
    },
    'resolution': _compactNavigationResolution(
      resolution,
      maxCandidates: _navigationMaxCandidates(params),
    ),
    'stoppingReason': resolution.status.name,
    'restoration': const <String, Object?>{
      'attempted': false,
      'result': 'not_applicable_read_only',
    },
  };

  Map<String, Object?> _compactNavigationResolution(
    _TargetResolution resolution, {
    int maxCandidates = 20,
  }) {
    final candidates = resolution.candidates.take(maxCandidates).toList();
    return <String, Object?>{
      'status': resolution.status.name,
      'requested': resolution.requested,
      'scope': resolution.scope,
      if (resolution.match != null) 'match': resolution.match,
      if (resolution.node != null) 'target': resolution.node!.toJson(),
      if (resolution.textNode != null)
        'textTarget': resolution.textNode!.toJson(),
      if (resolution.safePoint != null)
        'safePoint': [resolution.safePoint!.dx, resolution.safePoint!.dy],
      if (resolution.reason != null) 'reason': resolution.reason,
      'candidateCount': resolution.candidates.length,
      'candidatesReturned': candidates.length,
      'candidatesTruncated': candidates.length < resolution.candidates.length,
      if (candidates.isNotEmpty)
        'candidates': [
          for (final candidate in candidates)
            candidate.toJson(resolution.scope),
        ],
    };
  }

  developer.ServiceExtensionResponse _navigationResolutionFailure({
    required String operation,
    required _TargetResolution resolution,
    required Map<String, Object?> payload,
    required Map<String, String> params,
  }) {
    final code = switch (resolution.status) {
      _TargetResolutionStatus.ambiguous => 'target_ambiguous',
      _TargetResolutionStatus.stale => 'stale_target',
      _TargetResolutionStatus.disabled => 'target_disabled',
      _TargetResolutionStatus.hidden => 'target_not_visible',
      _ => 'target_not_found',
    };
    return _navigationBoundedFail(
      code,
      resolution.reason ?? '$operation stopped: ${resolution.status.name}.',
      <String, Object?>{
        ...payload,
        'activation': const <String, Object?>{'dispatched': false},
      },
      params,
    );
  }

  developer.ServiceExtensionResponse _navigationScopeFailure({
    required String operation,
    required Map<String, Object?> query,
    required ScoutSnapshot snapshot,
    required _NavigationScopeSelection selection,
    required Map<String, String> params,
    _RevealBounds? bounds,
    String direction = 'none',
    Stopwatch? stopwatch,
  }) {
    final payload = <String, Object?>{
      'operation': operation,
      'query': query,
      'scope': _targetScope(snapshot),
      'searchRegion': params['within'] ?? 'not_selected',
      'direction': direction,
      'startingStateGeneration': snapshot.stateGeneration,
      'bounds':
          bounds?.toJson() ??
          <String, Object?>{
            'actions': 0,
            'distance': 0,
            'timeMs': 0,
            'maxCandidates': _navigationMaxCandidates(params),
            'maxResponseBytes': _navigationMaxResponseBytes(params),
          },
      'scrollRegions': [
        for (final region in selection.regions) region.toJson(),
      ],
      if (selection.resolution != null)
        'scopeResolution': _compactNavigationResolution(selection.resolution!),
      'progressSignatures': [_navigationProgressSignature(snapshot, null)],
      'scrollRegionsAttempted': const <Object?>[],
      'repeatedStateDetected': false,
      'loopDetected': false,
      'endOfContentDetected': false,
      'stoppingReason': selection.failureCode,
      'elapsedMs': stopwatch?.elapsedMilliseconds ?? 0,
      'restoration': const <String, Object?>{
        'attempted': false,
        'result': 'not_required_no_dispatch',
      },
      'activation': const <String, Object?>{'dispatched': false},
    };
    return _navigationBoundedFail(
      selection.failureCode ?? 'scrollable_not_found',
      selection.failureMessage ?? 'No unique safe scroll region was selected.',
      payload,
      params,
    );
  }

  Map<String, Object?> _navigationProgressSignature(
    ScoutSnapshot snapshot,
    _NavigationScrollRegion? region,
  ) {
    final pixels = region?.position?.hasPixels == true
        ? region!.position!.pixels
        : null;
    final signature = <String>[
      snapshot.stateGeneration.toString(),
      snapshot.stateDigest,
      snapshot.visibleTextHash,
      region?.id ?? 'none',
      pixels == null ? 'na' : pixels.toStringAsFixed(2),
    ].join('|');
    return <String, Object?>{
      'signature': crypto.sha256.convert(utf8.encode(signature)).toString(),
      'stateGeneration': snapshot.stateGeneration,
      'snapshotId': snapshot.snapshotId,
      'visibleTextHash': snapshot.visibleTextHash,
      'viewSignature': snapshot.viewSignature,
      if (region != null) 'scrollRegionId': region.id,
      'pixels': ?pixels,
    };
  }

  Map<String, Object?> _navigationSnapshotEvidence(ScoutSnapshot snapshot) =>
      <String, Object?>{
        'screen': snapshot.screen,
        'screenEvidence': snapshot.screenEvidence,
        'route': snapshot.routeGuess,
        'activeSurface': snapshot.activeSurface,
        'viewSignature': snapshot.viewSignature,
        'visibleTextHash': snapshot.visibleTextHash,
        'stateGeneration': snapshot.stateGeneration,
        'stateDigest': snapshot.stateDigest,
        'snapshotId': snapshot.snapshotId,
        'idle': snapshot.idle,
        'visibleTextCount': snapshot.visibleText.length,
        'interactableCount': snapshot.interactables.length,
        'fieldCount': snapshot.fields.length,
        'scrollRegionCount': snapshot.scrollables.length,
        'degradedNodes': snapshot.degradedNodes,
      };

  _RevealBounds _revealBounds(
    Map<String, String> params,
    ScoutSnapshot snapshot,
  ) {
    final maxActions = (int.tryParse(params['maxActions'] ?? '') ?? 8).clamp(
      1,
      50,
    );
    final stepDistance =
        (double.tryParse(params['distance'] ?? '') ??
                snapshot.logicalSize.height * 0.65)
            .clamp(1.0, 5000.0)
            .toDouble();
    final maxDistance =
        (double.tryParse(params['maxDistance'] ?? '') ??
                stepDistance * maxActions)
            .clamp(stepDistance, 100000.0)
            .toDouble();
    final requestedTime = (int.tryParse(params['timeoutMs'] ?? '') ?? 8000)
        .clamp(100, 12000);
    final protocolDeadline = int.tryParse(params['deadlineEpochMs'] ?? '');
    final protocolRemaining = protocolDeadline == null
        ? requestedTime
        : math.max(
            16,
            protocolDeadline - DateTime.now().millisecondsSinceEpoch - 100,
          );
    return _RevealBounds(
      maxActions: maxActions,
      stepDistance: stepDistance,
      maxDistance: maxDistance,
      maxTimeMs: math.min(requestedTime, protocolRemaining),
      maxResponseBytes: _navigationMaxResponseBytes(params),
    );
  }

  Map<String, Object?> _revealBasePayload({
    required Map<String, Object?> query,
    required String? within,
    required String direction,
    required ScoutSnapshot before,
    required _RevealBounds bounds,
    required Stopwatch stopwatch,
    required String stoppingReason,
    required bool activationDispatched,
  }) => <String, Object?>{
    'operation': 'reveal',
    'query': query,
    'scope': <String, Object?>{
      ..._targetScope(before),
      if (within != null && within.isNotEmpty) 'within': within,
    },
    'searchRegion': within ?? 'implicit_only_if_unique',
    'direction': direction,
    'startingStateGeneration': before.stateGeneration,
    'bounds': bounds.toJson(),
    'stoppingReason': stoppingReason,
    'elapsedMs': stopwatch.elapsedMilliseconds,
    'restoration': <String, Object?>{
      'attempted': false,
      'result': activationDispatched
          ? 'not_required_success'
          : 'not_required_no_dispatch',
    },
    'activation': <String, Object?>{'dispatched': activationDispatched},
  };

  Future<Map<String, Object?>> _restoreNavigationPosition({
    required _NavigationScrollRegion region,
    required ScrollPosition position,
    required double initialOffset,
  }) async {
    try {
      if (!position.hasPixels || !position.hasContentDimensions) {
        return const <String, Object?>{
          'attempted': true,
          'result': 'unavailable',
          'reason': 'scroll_position_detached',
        };
      }
      final destination = initialOffset.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      _inRequestPhase('dispatch', () => position.jumpTo(destination));
      await _settleMutationFrames();
      final restored = (position.pixels - destination).abs() <= 0.5;
      return <String, Object?>{
        'attempted': true,
        'result': restored ? 'restored' : 'failed',
        'scrollRegionId': region.id,
        'requestedPixels': initialOffset,
        'actualPixels': position.pixels,
      };
    } catch (error) {
      return <String, Object?>{
        'attempted': true,
        'result': 'failed',
        'scrollRegionId': region.id,
        'reason': error.toString(),
      };
    }
  }

  developer.ServiceExtensionResponse _navigationBoundedOk(
    Map<String, Object?> payload,
    Map<String, String> params,
  ) {
    final maxBytes = _navigationMaxResponseBytes(params);
    final fitted = _fitNavigationPayload(payload, maxBytes - 1024);
    final encodedBytes = utf8.encode(jsonEncode(fitted)).length;
    return _ok(<String, Object?>{
      ...fitted,
      'responseBytes': encodedBytes,
      'maxResponseBytes': maxBytes,
    });
  }

  developer.ServiceExtensionResponse _navigationBoundedFail(
    String code,
    String message,
    Map<String, Object?> payload,
    Map<String, String> params,
  ) {
    final maxBytes = _navigationMaxResponseBytes(params);
    // Failure details are intentionally present both top-level and under the
    // typed structuredError. Fit to half the declared budget so that envelope
    // duplication still remains bounded.
    final fitted = _fitNavigationPayload(
      payload,
      math.max(1024, (maxBytes - 1024) ~/ 2),
    );
    final encodedBytes = utf8.encode(jsonEncode(fitted)).length;
    return _fail(
      code,
      message,
      extra: <String, Object?>{
        ...fitted,
        'responseBytes': encodedBytes,
        'maxResponseBytes': maxBytes,
      },
    );
  }

  Map<String, Object?> _fitNavigationPayload(
    Map<String, Object?> payload,
    int targetBytes,
  ) {
    final result = Map<String, Object?>.from(payload);
    final originalBytes = utf8.encode(jsonEncode(payload)).length;
    if (originalBytes <= targetBytes) return result;

    void boundList(String key, int keep) {
      final raw = result[key];
      if (raw is! List || raw.length <= keep) return;
      final firstCount = math.max(1, keep ~/ 2);
      final lastCount = math.max(1, keep - firstCount);
      result[key] = <Object?>[
        ...raw.take(firstCount),
        ...raw.skip(raw.length - lastCount),
      ];
      result['${key}Count'] = raw.length;
      result['${key}Truncated'] = true;
    }

    for (final entry in const <MapEntry<String, int>>[
      MapEntry('scrollRegions', 8),
      MapEntry('scrollRegionsAttempted', 8),
      MapEntry('progressSignatures', 8),
      MapEntry('navigators', 8),
      MapEntry('tabSystems', 8),
      MapEntry('overlays', 8),
      MapEntry('panes', 8),
    ]) {
      boundList(entry.key, entry.value);
    }
    for (final key in const ['resolution', 'scopeResolution']) {
      final raw = result[key];
      if (raw is! Map) continue;
      final resolution = <String, Object?>{
        for (final entry in raw.entries) entry.key.toString(): entry.value,
      };
      final candidates = resolution['candidates'];
      if (candidates is List && candidates.length > 4) {
        resolution['candidates'] = candidates.take(4).toList(growable: false);
        resolution['candidatesReturned'] = 4;
        resolution['candidatesTruncated'] = true;
      }
      result[key] = resolution;
    }
    final delta = result['delta'];
    if (delta is Map) {
      final boundedDelta = <String, Object?>{
        for (final entry in delta.entries) entry.key.toString(): entry.value,
      };
      for (final entry in boundedDelta.entries.toList(growable: false)) {
        final value = entry.value;
        if (value is List && value.length > 20) {
          boundedDelta[entry.key] = value.take(20).toList(growable: false);
          boundedDelta['${entry.key}Count'] = value.length;
          boundedDelta['${entry.key}Truncated'] = true;
        }
      }
      result['delta'] = boundedDelta;
    }
    result['responseTruncated'] = true;
    result['originalResponseBytes'] = originalBytes;
    if (utf8.encode(jsonEncode(result)).length <= targetBytes) return result;

    const essential = <String>{
      'operation',
      'orientation',
      'query',
      'scope',
      'searchRegion',
      'direction',
      'startingStateGeneration',
      'bounds',
      'stoppingReason',
      'revealed',
      'result',
      'resolution',
      'repeatedStateDetected',
      'loopDetected',
      'endOfContentDetected',
      'restoration',
      'activation',
      'requestedSnapshotId',
      'baselineScope',
      'currentScope',
      'generationDistance',
      'semanticChanged',
      'history',
      'coordinateFrame',
      'screen',
      'route',
      'activeSurface',
      'keyboard',
    };
    final core = <String, Object?>{
      for (final entry in result.entries)
        if (essential.contains(entry.key)) entry.key: entry.value,
      'responseTruncated': true,
      'originalResponseBytes': originalBytes,
      'omittedFields': [
        for (final key in payload.keys)
          if (!essential.contains(key)) key,
      ],
    };
    if (utf8.encode(jsonEncode(core)).length <= targetBytes) return core;

    return <String, Object?>{
      'operation': payload['operation'] ?? payload['orientation'],
      if (payload['query'] != null) 'query': payload['query'],
      if (payload['scope'] != null) 'scope': payload['scope'],
      if (payload['direction'] != null) 'direction': payload['direction'],
      if (payload['startingStateGeneration'] != null)
        'startingStateGeneration': payload['startingStateGeneration'],
      if (payload['bounds'] != null) 'bounds': payload['bounds'],
      if (payload['stoppingReason'] != null)
        'stoppingReason': payload['stoppingReason'],
      if (payload['restoration'] != null) 'restoration': payload['restoration'],
      if (payload['activation'] != null) 'activation': payload['activation'],
      'responseTruncated': true,
      'originalResponseBytes': originalBytes,
      'omittedFieldCount': payload.length,
    };
  }

  int _navigationMaxCandidates(Map<String, String> params) =>
      (int.tryParse(params['maxCandidates'] ?? '') ?? 20).clamp(1, 100);

  int _navigationMaxResponseBytes(Map<String, String> params) =>
      (int.tryParse(params['maxResponseBytes'] ?? '') ??
              _navigationDefaultMaxResponseBytes)
          .clamp(4096, 1024 * 1024);
}

class _RevealBounds {
  const _RevealBounds({
    required this.maxActions,
    required this.stepDistance,
    required this.maxDistance,
    required this.maxTimeMs,
    required this.maxResponseBytes,
  });

  final int maxActions;
  final double stepDistance;
  final double maxDistance;
  final int maxTimeMs;
  final int maxResponseBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'maxActions': maxActions,
    'stepDistance': stepDistance,
    'maxDistance': maxDistance,
    'maxTimeMs': maxTimeMs,
    'maxResponseBytes': maxResponseBytes,
  };
}
