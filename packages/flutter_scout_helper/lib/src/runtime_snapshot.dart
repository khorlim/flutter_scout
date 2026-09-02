part of 'flutter_scout_binding.dart';

// part: widget-tree snapshot + annotation target collection + hit testing.

class _SnapshotScrollRegion {
  _SnapshotScrollRegion({
    required this.id,
    required this.baseId,
    required this.occurrence,
    required this.key,
    required this.widgetType,
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
  final String widgetType;
  final AxisDirection axisDirection;
  final Rect? rect;
  Rect? visibleRect;
  final Element element;
  final ScrollableState? state;
  final int treeOrdinal;
  final double? coordinateDevicePixelRatio;
  String? parentId;
  int nestingDepth = 0;
  List<String> scopePath = const <String>[];

  static List<double>? _rectJson(Rect? value) => value == null
      ? null
      : <double>[value.left, value.top, value.width, value.height];

  List<double>? _physicalRectJson(Rect? value) {
    final scale = coordinateDevicePixelRatio;
    if (value == null || scale == null || !scale.isFinite || scale <= 0) {
      return null;
    }
    return <double>[
      value.left * scale,
      value.top * scale,
      value.width * scale,
      value.height * scale,
    ];
  }

  double? _finite(double? value) => value?.isFinite == true ? value : null;

  Map<String, Object?> toJson({bool includeEphemeralPositionIdentity = false}) {
    final vertical = axisDirectionToAxis(axisDirection) == Axis.vertical;
    final logicalBounds = _rectJson(rect);
    final visibleLogicalBounds = _rectJson(visibleRect);
    final physicalBounds = _physicalRectJson(rect);
    final visiblePhysicalBounds = _physicalRectJson(visibleRect);
    ScrollPosition? position;
    String? positionUnavailableReason;
    try {
      position = state?.position;
      if (state == null) {
        positionUnavailableReason = 'scrollable_state_unavailable';
      }
    } catch (_) {
      positionUnavailableReason = 'scroll_position_unavailable';
    }

    double? pixels;
    double? minScrollExtent;
    double? maxScrollExtent;
    double? viewportDimension;
    var hasContentDimensions = false;
    if (position != null) {
      try {
        pixels = position.hasPixels ? _finite(position.pixels) : null;
        hasContentDimensions = position.hasContentDimensions;
        if (hasContentDimensions) {
          minScrollExtent = _finite(position.minScrollExtent);
          maxScrollExtent = _finite(position.maxScrollExtent);
          viewportDimension = _finite(position.viewportDimension);
        }
        if (pixels == null) {
          positionUnavailableReason = position.hasPixels
              ? 'non_finite_scroll_pixels'
              : 'scroll_pixels_not_available';
        } else if (!hasContentDimensions) {
          positionUnavailableReason = 'content_dimensions_not_available';
        } else if (minScrollExtent == null ||
            maxScrollExtent == null ||
            viewportDimension == null) {
          positionUnavailableReason = 'non_finite_scroll_metrics';
        }
      } catch (_) {
        pixels = null;
        minScrollExtent = null;
        maxScrollExtent = null;
        viewportDimension = null;
        hasContentDimensions = false;
        positionUnavailableReason = 'scroll_metrics_observation_failed';
      }
    }

    final completePosition =
        pixels != null &&
        minScrollExtent != null &&
        maxScrollExtent != null &&
        viewportDimension != null;
    final extentBefore = completePosition
        ? math.max(0.0, pixels - minScrollExtent)
        : null;
    final extentAfter = completePosition
        ? math.max(0.0, maxScrollExtent - pixels)
        : null;
    final range = completePosition ? maxScrollExtent - minScrollExtent : null;
    final normalized = completePosition
        ? range!.abs() <= 0.000001
              ? 0.0
              : ((pixels - minScrollExtent) / range).clamp(0.0, 1.0)
        : null;
    final visibleArea = visibleRect == null
        ? 0.0
        : visibleRect!.width * visibleRect!.height;
    final totalArea = rect == null ? 0.0 : rect!.width * rect!.height;
    final visibleFraction = totalArea <= 0
        ? 0.0
        : (visibleArea / totalArea).clamp(0.0, 1.0);
    final scopedId = scopePath.isEmpty ? id : scopePath.join('/');
    final hasOwnValueKey = element.widget.key is ValueKey;

    return <String, Object?>{
      'id': id,
      'scopedId': scopedId,
      'baseId': baseId,
      'ordinal': occurrence,
      if (key != null) 'key': key,
      if (key != null)
        'keyEvidence': <String, Object?>{
          'kind': 'observed',
          'source': hasOwnValueKey
              ? 'scrollable_value_key'
              : 'nearest_ancestor_value_key',
        },
      'widgetType': widgetType,
      'identity': <String, Object?>{
        'kind': 'deterministic_derivation',
        'source': key == null
            ? 'axis_direction_and_snapshot_occurrence'
            : hasOwnValueKey
            ? 'flutter_value_key'
            : 'nearest_ancestor_value_key_and_snapshot_occurrence',
        'stability': key == null
            ? 'snapshot_local'
            : hasOwnValueKey
            ? 'key_derived_within_observed_scope'
            : 'ancestor_scope_derived_snapshot_local',
        'scopedId': scopedId,
        'scopePath': scopePath,
        'uniqueInSnapshot': true,
      },
      'axis': vertical ? 'vertical' : 'horizontal',
      'axisDirection': axisDirection.name,
      'directionEvidence': const <String, Object?>{
        'kind': 'observed',
        'source': 'flutter_scrollable_axis_direction',
      },
      // Existing compact/action consumers use rect/visibleRect. The explicit
      // names below make their logical coordinate space unambiguous.
      'rect': logicalBounds,
      'visibleRect': visibleLogicalBounds,
      'logicalBounds': logicalBounds,
      'visibleLogicalBounds': visibleLogicalBounds,
      'physicalBounds': physicalBounds,
      'visiblePhysicalBounds': visiblePhysicalBounds,
      'visibleFraction': visibleFraction,
      'visibilityEvidence': <String, Object?>{
        'status': 'partially_observed',
        'clipping': 'derived_from_window_and_ancestor_scroll_bounds',
        'occlusion': 'not_directly_measured_for_scroll_region',
        'visibleFractionMeaning': 'geometric_clip_exposure_only',
      },
      'geometryEvidence': <String, Object?>{
        'logical': logicalBounds == null
            ? 'observation_unavailable'
            : 'observed',
        'physical': physicalBounds == null
            ? 'observation_unavailable'
            : 'derived_observation',
        'source': 'render_box_global_bounds',
        'visibleBoundsSource':
            'window_viewport_and_ancestor_scroll_region_intersection',
        if (physicalBounds != null)
          'physicalDerivation': 'logical_bounds_times_device_pixel_ratio',
        if (coordinateDevicePixelRatio != null)
          'devicePixelRatio': coordinateDevicePixelRatio,
        if (physicalBounds == null)
          'physicalUnavailableReason': 'view_metrics_not_captured',
      },
      'nestingDepth': nestingDepth,
      'parentId': parentId,
      'scopePath': scopePath,
      'treeOrdinal': treeOrdinal,
      'positionAvailable': pixels != null,
      'metricsAvailable': completePosition,
      'positionEvidence': <String, Object?>{
        'status': completePosition
            ? 'observed'
            : pixels != null
            ? 'partially_observed'
            : 'observation_unavailable',
        'source': 'flutter_scroll_position',
        'reason': ?positionUnavailableReason,
      },
      if (includeEphemeralPositionIdentity)
        'positionIdentity': position == null
            ? null
            : identityHashCode(position),
      if (includeEphemeralPositionIdentity && position != null)
        'positionIdentityScope': 'runtime_process_only',
      'pixels': pixels,
      'minScrollExtent': minScrollExtent,
      'maxScrollExtent': maxScrollExtent,
      'extentBefore': extentBefore,
      'extentAfter': extentAfter,
      'viewportDimension': viewportDimension,
      'viewport': <String, Object?>{
        'axisDimension': viewportDimension,
        'logicalBounds': logicalBounds,
        'visibleLogicalBounds': visibleLogicalBounds,
        'physicalBounds': physicalBounds,
        'source': 'scroll_position_and_render_box',
      },
      'approximateNormalizedPosition': normalized,
      'normalizedPositionEvidence': normalized == null
          ? const <String, Object?>{
              'status': 'observation_unavailable',
              'reason': 'complete_scroll_metrics_required',
            }
          : const <String, Object?>{
              'status': 'derived_observation',
              'basis':
                  '(pixels-minScrollExtent)/(maxScrollExtent-minScrollExtent)',
              'clamped': true,
            },
      'atStart': completePosition ? pixels <= minScrollExtent + 0.5 : null,
      'atEnd': completePosition ? pixels >= maxScrollExtent - 0.5 : null,
      'endpointEvidence': const <String, Object?>{
        'kind': 'metric_definition',
        'source': 'flutter_scroll_extent_metrics',
        'atStartMeaning': 'at_min_scroll_extent',
        'atEndMeaning': 'at_max_scroll_extent',
      },
      'canScroll': completePosition ? range!.abs() > 0.5 : null,
    };
  }
}

extension _RuntimeSnapshot on FlutterScoutRuntime {
  ScoutSnapshot _snapshot() =>
      _inRequestPhase(_requestSnapshotPhase, _snapshotWithoutPhaseTiming);

  ScoutSnapshot _snapshotWithoutPhaseTiming() {
    final root = WidgetsBinding.instance.rootElement;
    final nodes = <ScoutNode>[];
    final rawScrollables = <_SnapshotScrollRegion>[];
    final scrollables = <Map<String, Object?>>[];
    final scrollableIds = <String, int>{};
    final perceptionGaps = <Map<String, Object?>>[];
    final perceptionGapFingerprints = <String>{};
    final overlays = <Map<String, Object?>>[];
    final visibleText = <String>{};
    final hitTestableText = <String>{};
    final offscreenText = <String>{};
    var screen = 'RootWidget';
    var screenDepth = -1;
    var degradedNodes = 0;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final implicitView =
        WidgetsBinding.instance.platformDispatcher.implicitView;
    final view = implicitView != null && views.contains(implicitView)
        ? implicitView
        : views.isEmpty
        ? null
        : views.first;
    final rawDevicePixelRatio = view?.devicePixelRatio;
    final physicalSize = view?.physicalSize ?? Size.zero;
    final viewMetricsAvailable =
        view != null &&
        rawDevicePixelRatio != null &&
        rawDevicePixelRatio.isFinite &&
        rawDevicePixelRatio > 0 &&
        physicalSize.isFinite &&
        physicalSize.width > 0 &&
        physicalSize.height > 0;
    final devicePixelRatio = viewMetricsAvailable ? rawDevicePixelRatio : 1.0;
    final logicalSize = viewMetricsAvailable
        ? physicalSize / devicePixelRatio
        : Size.zero;
    EdgeInsets logicalInsets(ui.ViewPadding? value) =>
        value == null || !viewMetricsAvailable
        ? EdgeInsets.zero
        : EdgeInsets.fromLTRB(
            value.left / devicePixelRatio,
            value.top / devicePixelRatio,
            value.right / devicePixelRatio,
            value.bottom / devicePixelRatio,
          );
    final padding = logicalInsets(view?.padding);
    final viewPadding = logicalInsets(view?.viewPadding);
    final viewInsets = logicalInsets(view?.viewInsets);
    if (root != null) {
      // _walkVisible prunes hidden subtrees AND Scout's own overlay chrome:
      // the annotation FAB/badge must never surface as app interactables
      // (tap.add_location_alt) that an agent might try to press.
      _walkPerceptionVisible(root, (Element element) {
        // Per-element fault isolation: reading one misbehaving widget (a
        // throwing property getter, corrupt render state, …) must skip that
        // element only — never blind the agent to the entire screen.
        final widgetType = element.widget.runtimeType.toString();
        try {
          debugSnapshotNodeProbe?.call(element);
          final elementDepth = _elementDepth(element);
          if ((widgetType.endsWith('Screen') || widgetType.endsWith('Page')) &&
              !_frameworkScreenWidgets.contains(widgetType) &&
              elementDepth >= screenDepth &&
              _isElementOnActiveHitPath(element)) {
            screen = widgetType;
            screenDepth = elementDepth;
          }
          final node = _nodeFromElement(
            element,
            coordinateDevicePixelRatio: viewMetricsAvailable
                ? devicePixelRatio
                : null,
          );
          if (node != null) {
            nodes.add(node.copyWith(treeOrdinal: nodes.length));
          }
          final visualGap = _visualPerceptionGap(
            element,
            widgetType: widgetType,
            devicePixelRatio: viewMetricsAvailable ? devicePixelRatio : null,
            ordinal: perceptionGaps.length + 1,
          );
          if (visualGap != null) {
            _addPerceptionGap(
              perceptionGaps,
              perceptionGapFingerprints,
              visualGap,
            );
          }
          if (element.widget case final Scrollable widget) {
            final rect = _rectFor(element);
            final visibleRect = rect == null
                ? null
                : _visiblePerceptionRectFor(element, rect);
            final keyLabel = _nearestScrollableKey(element);
            final baseId =
                'scroll.${_slug(keyLabel ?? widget.axisDirection.name)}';
            final occurrence = scrollableIds.update(
              baseId,
              (count) => count + 1,
              ifAbsent: () => 1,
            );
            rawScrollables.add(
              _SnapshotScrollRegion(
                id: occurrence == 1 ? baseId : '${baseId}_$occurrence',
                baseId: baseId,
                occurrence: occurrence,
                key: keyLabel,
                widgetType: widgetType,
                axisDirection: widget.axisDirection,
                rect: rect,
                visibleRect: visibleRect,
                element: element,
                state:
                    element is StatefulElement &&
                        element.state is ScrollableState
                    ? element.state as ScrollableState
                    : null,
                // Use the same node-walk coordinate as overlays and active
                // surface anchors. Counting only scrollables makes this value
                // incomparable with a modal barrier/title ordinal and prevents
                // surface-only inspect from excluding background scroll views.
                treeOrdinal: nodes.length,
                coordinateDevicePixelRatio: viewMetricsAvailable
                    ? devicePixelRatio
                    : null,
              ),
            );
          }
          final overlay = _overlayFor(element);
          if (overlay != null) {
            overlay['ordinal'] = nodes.length;
            overlays.add(overlay);
          }
          final text = _isInsideSensitiveEditable(element)
              ? null
              : _ownText(element.widget);
          if (text != null && _isUsefulVisibleText(text)) {
            final rect = _rectFor(element);
            final trimmed = text.trim();
            if (rect == null || _visibleRectFor(rect) == null) {
              offscreenText.add(trimmed);
            } else {
              visibleText.add(trimmed);
              final point = _visibleCenter(rect);
              if (point != null &&
                  _hitTestable(point, target: element.renderObject)) {
                hitTestableText.add(trimmed);
              }
            }
          }
        } catch (_) {
          degradedNodes += 1;
          final semanticsNode = element.widget is Semantics;
          _addPerceptionGap(
            perceptionGaps,
            perceptionGapFingerprints,
            <String, Object?>{
              'id': 'gap.element_observation.${perceptionGaps.length + 1}',
              'kind': semanticsNode
                  ? 'semantics_node_observation_failed'
                  : 'element_observation_failed',
              'status': 'observation_unavailable',
              'evidenceKind': 'observed_failure',
              'source': semanticsNode
                  ? 'flutter_semantics_widget_probe'
                  : 'widget_tree_element_probe',
              'widgetType': widgetType,
              'affectedEvidence': semanticsNode
                  ? const <String>['semantics_label_and_state']
                  : const <String>[
                      'semantics',
                      'geometry',
                      'interaction_metadata',
                    ],
              'isolation': semanticsNode
                  ? 'affected_semantics_node_only'
                  : 'affected_element_only',
              'recommendation': const <String, Object?>{
                'action': 'inspect_remaining_snapshot',
                'reason': 'healthy_sibling_evidence_remains_available',
              },
            },
          );
        }
      });
    }

    _linkSnapshotScrollScopes(rawScrollables);
    scrollables.addAll(rawScrollables.map((region) => region.toJson()));
    final captureBackend = _captureBackendEvidence();
    if (captureBackend['status'] != 'available') {
      _addPerceptionGap(
        perceptionGaps,
        perceptionGapFingerprints,
        <String, Object?>{
          'id': 'gap.capture_backend.${perceptionGaps.length + 1}',
          'kind': 'capture_backend_unavailable',
          'status': 'observation_unavailable',
          'evidenceKind': 'observed_failure',
          'source': 'flutter_root_layer_probe',
          'affectedEvidence': const <String>['focused_pixel_capture'],
          'reason': captureBackend['reason'],
          'recommendation': const <String, Object?>{
            'action': 'use_native_screenshot_if_available',
            'availability': 'not_observable_by_helper',
          },
        },
      );
    }

    // A sensitive field may be encountered after another widget that mirrors
    // its controller value. Sanitize the complete collected state only after
    // the walk has registered every sensitive value, before any inference,
    // hierarchy, annotation, or debug payload can observe it.
    final safeNodes = [for (final node in nodes) _redactNode(node)];
    nodes
      ..clear()
      ..addAll(safeNodes);
    final safeVisibleText = _redactSensitiveStrings(visibleText);
    visibleText
      ..clear()
      ..addAll(safeVisibleText);
    final safeHitTestableText = _redactSensitiveStrings(hitTestableText);
    hitTestableText
      ..clear()
      ..addAll(safeHitTestableText);
    final safeOffscreenText = _redactSensitiveStrings(offscreenText);
    offscreenText
      ..clear()
      ..addAll(safeOffscreenText);
    for (var index = 0; index < scrollables.length; index++) {
      scrollables[index] = _redactSensitiveMap(scrollables[index]);
    }
    for (var index = 0; index < overlays.length; index++) {
      overlays[index] = _redactSensitiveMap(overlays[index]);
    }
    for (var index = 0; index < perceptionGaps.length; index++) {
      perceptionGaps[index] = _redactSensitiveMap(perceptionGaps[index]);
    }

    List<ScoutNode> compactNodes;
    try {
      compactNodes = _disambiguateIds(
        _inferIntentAliases(
          _inferActionableLabels(_inferFieldLabels(_compactNodes(nodes))),
        ),
      );
    } catch (_) {
      // Post-processing failed as a batch; fall back to the raw nodes so the
      // agent keeps (noisier) eyes instead of none.
      degradedNodes += 1;
      _addPerceptionGap(
        perceptionGaps,
        perceptionGapFingerprints,
        <String, Object?>{
          'id': 'gap.node_post_processing.${perceptionGaps.length + 1}',
          'kind': 'node_post_processing_failed',
          'status': 'observation_unavailable',
          'evidenceKind': 'observed_failure',
          'source': 'snapshot_node_enrichment',
          'affectedEvidence': const <String>[
            'handle_compaction',
            'label_inference',
            'id_disambiguation',
          ],
          'isolation': 'raw_nodes_retained',
        },
      );
      compactNodes = nodes;
    }
    try {
      compactNodes = _inferSegmentSelection(compactNodes);
    } catch (_) {
      // Inference is best-effort; never let it cost the snapshot.
      _addPerceptionGap(
        perceptionGaps,
        perceptionGapFingerprints,
        <String, Object?>{
          'id': 'gap.selection_inference.${perceptionGaps.length + 1}',
          'kind': 'selection_inference_failed',
          'status': 'heuristic_inference_unavailable',
          'evidenceKind': 'observed_failure',
          'source': 'uncalibrated_segment_selection_heuristic',
          'affectedEvidence': const <String>['inferred_selection_state'],
          'isolation': 'observed_node_facts_retained',
        },
      );
    }
    try {
      compactNodes = _linkEnclosingTargets(compactNodes);
    } catch (_) {
      // Best-effort enrichment.
      _addPerceptionGap(
        perceptionGaps,
        perceptionGapFingerprints,
        <String, Object?>{
          'id': 'gap.enclosing_target_inference.${perceptionGaps.length + 1}',
          'kind': 'enclosing_target_inference_failed',
          'status': 'heuristic_inference_unavailable',
          'evidenceKind': 'observed_failure',
          'source': 'uncalibrated_geometry_heuristic',
          'affectedEvidence': const <String>['enclosing_target_aliases'],
          'isolation': 'observed_node_facts_retained',
        },
      );
    }
    final interactables = compactNodes
        .where((node) => node.kind != 'text' && node.kind != 'field')
        .toList(growable: false);
    final fields = compactNodes
        .where((node) => node.kind == 'field')
        .toList(growable: false);
    final textTargets = compactNodes
        .where((node) => node.kind == 'text')
        .toList(growable: false);
    final rawRoute = root == null ? null : ModalRoute.of(root)?.settings.name;
    final route = rawRoute == null ? null : _redactSensitiveText(rawRoute);
    final modalScreenName = root == null ? null : _modalScreenName(root);
    final concreteModalSurface = root != null && _hasConcreteModalSurface(root);
    final genericModal =
        concreteModalSurface &&
        _genericModalSurfaceNames.contains(modalScreenName);
    final hasConcreteOverlaySurface = overlays.any(
      (overlay) =>
          overlay['kind'] == 'dialog' || overlay['kind'] == 'bottomSheet',
    );
    final hasViewportModalBarrier = overlays.any(
      (overlay) =>
          overlay['kind'] == 'modalBarrier' &&
          _coversViewport(overlay, logicalSize),
    );
    final activeSurface = _activeSurfaceFor(
      // Nested navigators create local ModalBarriers for their own route
      // stack. They are not dialogs: treating any such barrier as modal made
      // Scout relabel a normal page using the first prominent row title.
      // A bare barrier is modal evidence only when it covers this app view;
      // standard Dialog/BottomSheet surfaces remain valid at any size.
      modalActive:
          hasConcreteOverlaySurface || hasViewportModalBarrier || genericModal,
      allowVisibleTextFallback: genericModal,
      overlays: overlays,
      visibleText: visibleText,
      textTargets: textTargets,
      logicalSize: logicalSize,
    );
    // No *Screen/*Page widget (common for bottom sheets, dialogs, and
    // custom-named order/checkout surfaces) would otherwise leave `screen`
    // as the useless 'RootWidget'. Name the topmost modal surface instead.
    if (screen == 'RootWidget' && root != null) {
      if (activeSurface != null) {
        screen = activeSurface['screen']?.toString() ?? screen;
      } else if (genericModal) {
        screen = modalScreenName ?? screen;
      } else if (modalScreenName != null &&
          !modalScreenName.endsWith('Surface')) {
        screen = modalScreenName;
      }
    }
    var reportedScreen =
        activeSurface?['screen']?.toString() ??
        (route != null && route.isNotEmpty ? route : screen);
    if (activeSurface == null && reportedScreen.endsWith('Surface')) {
      reportedScreen = 'RootWidget';
    }
    final screenEvidence = route != null && route.isNotEmpty
        ? <String, Object?>{
            'kind': 'observed',
            'source': 'route_name',
            'routeNameAvailable': true,
          }
        : activeSurface != null
        ? <String, Object?>{
            'kind': 'heuristic_inference',
            'source': 'active_surface',
            'scoreKind': 'uncalibrated_heuristic',
            if (activeSurface['source'] != null)
              'surfaceSource': activeSurface['source'],
            if (activeSurface['heuristicScore'] != null)
              'heuristicScore': activeSurface['heuristicScore'],
          }
        : <String, Object?>{
            'kind': 'heuristic_inference',
            'source': 'widget_ancestry',
            'scoreKind': 'uncalibrated_heuristic',
            'basis': screen == 'RootWidget'
                ? 'root_widget_fallback'
                : 'screen_or_page_runtime_type',
          };
    _synchronizeVisibleErrorSurfaceSignals(perceptionGaps);
    var snapshot = ScoutSnapshot(
      screen: reportedScreen,
      screenEvidence: screenEvidence,
      activeSurface: activeSurface,
      routeGuess: route,
      idle: !WidgetsBinding.instance.hasScheduledFrame,
      devicePixelRatio: devicePixelRatio,
      logicalSize: logicalSize,
      physicalSize: physicalSize,
      padding: padding,
      viewPadding: viewPadding,
      viewInsets: viewInsets,
      viewMetricsAvailable: viewMetricsAvailable,
      visibleText: visibleText.toList(growable: false),
      hitTestableText: hitTestableText.toList(growable: false),
      offscreenText: offscreenText.toList(growable: false),
      interactables: interactables,
      fields: fields,
      textTargets: textTargets,
      scrollables: scrollables,
      perceptionGaps: perceptionGaps,
      captureBackend: captureBackend,
      overlays: overlays,
      visualTree: null,
      controlGroups: const [],
      structuredRows: const [],
      suggestedActions: const [],
      recentErrors: _recentErrors(useRequestCursor: false),
      degradedNodes: degradedNodes,
    );
    List<Map<String, Object?>> controlGroups;
    try {
      controlGroups = _buildControlGroups(snapshot);
    } catch (_) {
      controlGroups = const <Map<String, Object?>>[];
      snapshot.perceptionGaps.add(<String, Object?>{
        'id':
            'gap.control_group_inference.${snapshot.perceptionGaps.length + 1}',
        'kind': 'control_group_inference_failed',
        'status': 'heuristic_inference_unavailable',
        'evidenceKind': 'observed_failure',
        'source': 'uncalibrated_control_group_heuristic',
        'affectedEvidence': const <String>['controlGroups'],
        'isolation': 'base_snapshot_retained',
      });
    }
    // Custom numeric keypads commonly carry PIN/payment values outside an
    // EditableText. Control-group detection registers their display value;
    // re-scrub the base snapshot before building rows/visual hierarchy so that
    // value cannot survive through text targets or debug snapshot APIs.
    snapshot = _redactSnapshot(snapshot);
    List<Map<String, Object?>> structuredRows;
    try {
      structuredRows = _buildStructuredRows(snapshot);
    } catch (_) {
      structuredRows = const <Map<String, Object?>>[];
      snapshot.perceptionGaps.add(<String, Object?>{
        'id':
            'gap.structured_row_inference.${snapshot.perceptionGaps.length + 1}',
        'kind': 'structured_row_inference_failed',
        'status': 'heuristic_inference_unavailable',
        'evidenceKind': 'observed_failure',
        'source': 'uncalibrated_row_grouping_heuristic',
        'affectedEvidence': const <String>['structuredRows'],
        'isolation': 'base_snapshot_retained',
      });
    }
    Map<String, Object?>? visualTree;
    try {
      visualTree = _buildVisualTree(snapshot, controlGroups);
    } catch (_) {
      snapshot.perceptionGaps.add(<String, Object?>{
        'id': 'gap.visual_tree_inference.${snapshot.perceptionGaps.length + 1}',
        'kind': 'visual_tree_inference_failed',
        'status': 'heuristic_inference_unavailable',
        'evidenceKind': 'observed_failure',
        'source': 'uncalibrated_visual_hierarchy_heuristic',
        'affectedEvidence': const <String>['visualTree'],
        'isolation': 'base_snapshot_retained',
      });
    }
    final enriched = snapshot.copyWith(
      controlGroups: controlGroups,
      structuredRows: structuredRows,
      visualTree: visualTree,
    );
    List<Map<String, Object?>> suggestedActions;
    try {
      suggestedActions = _buildSuggestedActions(enriched, controlGroups);
    } catch (_) {
      suggestedActions = const <Map<String, Object?>>[];
      enriched.perceptionGaps.add(<String, Object?>{
        'id':
            'gap.action_suggestion_inference.${enriched.perceptionGaps.length + 1}',
        'kind': 'action_suggestion_inference_failed',
        'status': 'heuristic_inference_unavailable',
        'evidenceKind': 'observed_failure',
        'source': 'uncalibrated_action_suggestion_heuristic',
        'affectedEvidence': const <String>['suggestedActions'],
        'isolation': 'base_snapshot_retained',
      });
    }
    return _withStateIdentity(
      enriched.copyWith(suggestedActions: suggestedActions),
    );
  }

  void _synchronizeVisibleErrorSurfaceSignals(
    List<Map<String, Object?>> perceptionGaps,
  ) {
    final surfaces = <String>[
      for (final gap in perceptionGaps)
        if (gap['kind'] == 'flutter_error_widget_visible')
          jsonEncode(<String, Object?>{
            'widgetType': gap['widgetType'],
            'logicalBounds': gap['geometry'] is Map
                ? (gap['geometry'] as Map)['logicalBounds']
                : null,
          }),
    ]..sort();
    if (surfaces.isEmpty) {
      _activeVisibleErrorSignalCursors.clear();
      return;
    }

    final surfaceSetIdentity = crypto.sha256
        .convert(utf8.encode(jsonEncode(surfaces)))
        .toString();
    if (_activeVisibleErrorSignalCursors.containsKey(surfaceSetIdentity)) {
      return;
    }
    final signal = _recordError(
      type: 'visible_error_surface',
      message:
          'Flutter is visibly substituting an ErrorWidget; diagnostic text is intentionally omitted.',
      library: 'ErrorWidget',
      identityQualifier: surfaceSetIdentity,
    );
    _activeVisibleErrorSignalCursors
      ..clear()
      ..[surfaceSetIdentity] = signal['cursor']! as int;
  }

  String? _nearestScrollableKey(Element element) {
    String? stableKey(Key? key) {
      if (key is ValueKey) return key.value.toString();
      return null;
    }

    final own = stableKey(element.widget.key);
    if (own != null && own.trim().isNotEmpty) return own.trim();
    String? found;
    element.visitAncestorElements((ancestor) {
      final label = stableKey(ancestor.widget.key);
      if (label != null && label.trim().isNotEmpty) {
        found = label.trim();
        return false;
      }
      return true;
    });
    return found;
  }

  void _linkSnapshotScrollScopes(List<_SnapshotScrollRegion> regions) {
    final byElement = <Element, _SnapshotScrollRegion>{
      for (final region in regions) region.element: region,
    };
    final byId = <String, _SnapshotScrollRegion>{
      for (final region in regions) region.id: region,
    };
    for (final region in regions) {
      var clippedVisibleRect = region.visibleRect;
      region.element.visitAncestorElements((ancestor) {
        if (ancestor.widget is Scrollable) {
          region.nestingDepth += 1;
          final parent = byElement[ancestor];
          region.parentId ??= parent?.id;
          final parentViewport = parent?.visibleRect ?? parent?.rect;
          if (clippedVisibleRect != null && parentViewport != null) {
            final intersection = clippedVisibleRect!.intersect(parentViewport);
            clippedVisibleRect =
                intersection.width <= 0 || intersection.height <= 0
                ? null
                : intersection;
          }
        }
        return true;
      });
      region.visibleRect = clippedVisibleRect;
    }

    List<String> pathFor(_SnapshotScrollRegion region, Set<String> seen) {
      if (!seen.add(region.id)) return <String>[region.id];
      final parent = region.parentId == null ? null : byId[region.parentId];
      if (parent == null) return <String>[region.id];
      return <String>[...pathFor(parent, seen), region.id];
    }

    for (final region in regions) {
      region.scopePath = pathFor(region, <String>{});
    }
  }

  void _addPerceptionGap(
    List<Map<String, Object?>> gaps,
    Set<String> fingerprints,
    Map<String, Object?> gap,
  ) {
    final geometry = gap['geometry'];
    final logicalBounds = geometry is Map ? geometry['logicalBounds'] : null;
    final fingerprint = logicalBounds == null
        ? '${gap['kind']}|${gap['widgetType']}|${gap['id']}'
        : '${gap['kind']}|$logicalBounds';
    if (fingerprints.add(fingerprint)) gaps.add(gap);
  }

  Map<String, Object?> _captureBackendEvidence() {
    try {
      debugCaptureBackendProbe?.call();
      final renderView = _primaryRenderView();
      if (renderView == null) {
        return const <String, Object?>{
          'status': 'observation_unavailable',
          'backend': 'flutter_root_offset_layer',
          'reason': 'no_render_view',
          'nativeFallback': <String, Object?>{
            'status': 'not_observable_by_helper',
            'selectedBy': 'flutter_scout_cli',
          },
        };
      }
      // RenderView.layer is protected but is the same root-layer contract used
      // by the capture implementation in runtime_annotations.dart.
      // ignore: invalid_use_of_protected_member
      final layer = renderView.layer;
      if (layer is! OffsetLayer) {
        return const <String, Object?>{
          'status': 'observation_unavailable',
          'backend': 'flutter_root_offset_layer',
          'reason': 'no_offset_layer',
          'nativeFallback': <String, Object?>{
            'status': 'not_observable_by_helper',
            'selectedBy': 'flutter_scout_cli',
          },
        };
      }
      return <String, Object?>{
        'status': 'available',
        'backend': 'flutter_root_offset_layer',
        'provenance': const <String, Object?>{
          'kind': 'observed',
          'source': 'render_view_offset_layer',
        },
        'coverage': const <String, Object?>{
          'flutterLayers': 'supported',
          'platformViewPixels': 'unsupported',
          'texturePixels': 'not_guaranteed',
        },
        'nativeFallback': const <String, Object?>{
          'status': 'not_observable_by_helper',
          'selectedBy': 'flutter_scout_cli',
        },
      };
    } catch (_) {
      return const <String, Object?>{
        'status': 'observation_unavailable',
        'backend': 'flutter_root_offset_layer',
        'reason': 'capture_backend_probe_failed',
        'nativeFallback': <String, Object?>{
          'status': 'not_observable_by_helper',
          'selectedBy': 'flutter_scout_cli',
        },
      };
    }
  }

  Map<String, Object?>? _visualPerceptionGap(
    Element element, {
    required String widgetType,
    required double? devicePixelRatio,
    required int ordinal,
  }) {
    final widget = element.widget;
    final renderType = element.renderObject?.runtimeType.toString() ?? '';
    final platformSurface = <String>[
      widgetType,
      renderType,
    ].any(_isPlatformSurfaceRuntimeType);
    final textureSurface = widget is Texture;
    final customPaint = widget is CustomPaint;
    final imageSurface = widget is Image || widget is RawImage;
    final errorSurface = widget is ErrorWidget;
    if (!platformSurface &&
        !textureSurface &&
        !customPaint &&
        !imageSurface &&
        !errorSurface) {
      return null;
    }

    final rect = _rectFor(element);
    final visibleRect = rect == null
        ? null
        : _visiblePerceptionRectFor(element, rect);
    if (rect != null && visibleRect == null) return null;
    List<double>? rectJson(Rect? value) => value == null
        ? null
        : <double>[value.left, value.top, value.width, value.height];
    List<double>? physicalRectJson(Rect? value) {
      if (value == null || devicePixelRatio == null) return null;
      return <double>[
        value.left * devicePixelRatio,
        value.top * devicePixelRatio,
        value.width * devicePixelRatio,
        value.height * devicePixelRatio,
      ];
    }

    late final String kind;
    late final String status;
    late final bool nativeCaptureRequired;
    late final String limitation;
    Map<String, Object?>? semanticEvidence;
    List<String>? painterTypes;
    if (errorSurface) {
      kind = 'flutter_error_widget_visible';
      status = 'observed_blocking_error_surface';
      nativeCaptureRequired = false;
      limitation =
          'Flutter is visibly substituting an ErrorWidget; the affected subtree is not trustworthy. Rendered diagnostic text is intentionally omitted from snapshot evidence.';
    } else if (platformSurface) {
      kind = 'platform_view_pixels_unobserved';
      status = 'unsupported_by_in_app_raster_capture';
      nativeCaptureRequired = true;
      limitation =
          'The widget tree exposes the platform-view region, not its opaque native pixels or meaning.';
    } else if (textureSurface) {
      kind = 'texture_pixels_unobserved';
      status = 'capture_coverage_not_guaranteed';
      nativeCaptureRequired = true;
      limitation =
          'The widget tree exposes the Texture region, not the externally supplied texture pixels or meaning.';
    } else if (customPaint) {
      painterTypes = <String>[
        if (widget.painter != null) widget.painter.runtimeType.toString(),
        if (widget.foregroundPainter != null)
          widget.foregroundPainter.runtimeType.toString(),
      ];
      final painterSemanticsDeclared =
          widget.painter?.semanticsBuilder != null ||
          widget.foregroundPainter?.semanticsBuilder != null;
      kind = 'custom_paint_pixels_unobserved';
      status = 'unavailable_in_widget_tree_observation';
      nativeCaptureRequired = false;
      limitation = painterSemanticsDeclared
          ? 'Custom-painted pixels are not represented by inspect; painter semantics are declared but do not prove visual appearance.'
          : 'This CustomPaint declares no painter semantics, so its painted content and meaning are unavailable to inspect.';
      semanticEvidence = <String, Object?>{
        'status': painterSemanticsDeclared
            ? 'semantics_declared_not_visual_proof'
            : 'unsupported_by_widget_semantics',
        'source': 'custom_painter_semantics_builder',
      };
    } else {
      kind = 'image_pixels_unobserved';
      status = 'unavailable_in_widget_tree_observation';
      nativeCaptureRequired = false;
      limitation =
          'The Image region is observable, but its decoded pixels are not included in inspect.';
    }

    final logicalVisible = rectJson(visibleRect ?? rect);
    final totalArea = rect == null ? 0.0 : rect.width * rect.height;
    final visibleArea = visibleRect == null
        ? 0.0
        : visibleRect.width * visibleRect.height;
    final visibleFraction = totalArea <= 0
        ? 0.0
        : (visibleArea / totalArea).clamp(0.0, 1.0);
    final commandRect = logicalVisible
        ?.map((value) => value.toStringAsFixed(1))
        .join(',');
    return <String, Object?>{
      'id': 'gap.${_slug(kind)}.$ordinal',
      'kind': kind,
      'status': status,
      'evidenceKind': 'observed_limitation',
      'source': 'widget_and_render_runtime_type',
      'widgetType': widgetType,
      if (painterTypes?.isNotEmpty == true) 'painterTypes': painterTypes,
      if (renderType.isNotEmpty) 'renderObjectType': renderType,
      'geometry': <String, Object?>{
        'status': rect == null ? 'observation_unavailable' : 'observed',
        'logicalBounds': rectJson(rect),
        'visibleLogicalBounds': rectJson(visibleRect),
        'physicalBounds': physicalRectJson(rect),
        'visiblePhysicalBounds': physicalRectJson(visibleRect),
        'visibleFraction': visibleFraction,
        'clipped': visibleFraction > 0 && visibleFraction < 1,
        'visibilityEvidence': const <String, Object?>{
          'status': 'partially_observed',
          'clipping': 'derived_from_window_and_ancestor_clip_bounds',
          'occlusion': 'not_directly_measured_for_visual_region',
          'visibleFractionMeaning': 'geometric_clip_exposure_only',
        },
        'devicePixelRatio': ?devicePixelRatio,
        if (rect == null) 'reason': 'render_box_bounds_unavailable',
      },
      'semantics': ?semanticEvidence,
      'limitation': limitation,
      'recommendation': errorSurface
          ? const <String, Object?>{
              'action': 'inspect_runtime_errors',
              'pixelEvidenceRequired': false,
              'suggestedCommand': 'flutter-scout logs --summary',
            }
          : <String, Object?>{
              'action': 'capture_focused_region',
              'pixelEvidenceRequired': true,
              'nativeCaptureRequired': nativeCaptureRequired,
              if (commandRect != null)
                'suggestedCommand':
                    'flutter-scout crop --rect $commandRect${nativeCaptureRequired ? ' --native' : ''}',
              if (commandRect == null)
                'suggestedCommand':
                    'flutter-scout screenshot${nativeCaptureRequired ? ' --native' : ''}',
            },
    };
  }

  void _walkPerceptionVisible(
    Element element,
    void Function(Element element) visitor,
  ) {
    visitor(element);
    // ErrorWidget renders exception diagnostics as ordinary Text widgets. The
    // runtime-error stream owns those diagnostics and redaction; perception
    // observes the ErrorWidget surface itself, then prunes its potentially
    // sensitive diagnostic subtree in O(1) rather than ancestor-scanning every
    // element in the app.
    if (element.widget is ErrorWidget ||
        _hidesSubtree(element) ||
        _isScoutOverlayWidget(element.widget)) {
      return;
    }
    element.visitChildElements(
      (child) => _walkPerceptionVisible(child, visitor),
    );
  }

  Rect? _visiblePerceptionRectFor(Element element, Rect rect) {
    var visible = _visibleRectFor(rect);
    if (visible == null) return null;
    element.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      final clipsDescendants =
          widget is Scrollable ||
          widget is ClipRect ||
          widget is ClipRRect ||
          widget is ClipOval ||
          widget is PhysicalModel ||
          widget is PhysicalShape;
      if (!clipsDescendants) return true;
      final ancestorRect = _rectFor(ancestor);
      if (ancestorRect == null) return true;
      final intersection = visible!.intersect(ancestorRect);
      visible = intersection.width <= 0 || intersection.height <= 0
          ? null
          : intersection;
      return visible != null;
    });
    return visible;
  }

  bool _isPlatformSurfaceRuntimeType(String name) {
    const exactTypes = <String>{
      'AndroidView',
      'AndroidViewSurface',
      'UiKitView',
      'AppKitView',
      'HtmlElementView',
      'PlatformViewLink',
      'PlatformViewSurface',
      'RenderAndroidView',
      'RenderUiKitView',
      'RenderAppKitView',
      'RenderHtmlElementView',
      'RenderPlatformView',
      'RenderPlatformViewSurface',
    };
    if (exactTypes.contains(name)) return true;
    // Flutter/plugin implementations may private-prefix the concrete class;
    // require an exact platform-surface suffix rather than a broad substring,
    // which would misclassify business widgets such as AndroidViewModel.
    return exactTypes.any((type) => name.endsWith(type));
  }

  bool _isElementOnActiveHitPath(Element element) {
    final rect = _rectFor(element);
    final visible = rect == null ? null : _visibleRectFor(rect);
    final renderObject = element.renderObject;
    if (visible == null || renderObject == null) return false;
    final points = <Offset>[
      visible.center,
      Offset(
        visible.left + visible.width * 0.2,
        visible.top + visible.height * 0.2,
      ),
      Offset(
        visible.right - visible.width * 0.2,
        visible.top + visible.height * 0.2,
      ),
      Offset(
        visible.left + visible.width * 0.2,
        visible.bottom - visible.height * 0.2,
      ),
      Offset(
        visible.right - visible.width * 0.2,
        visible.bottom - visible.height * 0.2,
      ),
    ];
    return points.any((point) => _hitTestable(point, target: renderObject));
  }

  bool _isSubtreeOnActiveHitPath(Element element) {
    var visited = 0;
    var active = false;
    void probe(Element candidate) {
      if (active || visited >= 40) return;
      visited += 1;
      if (_isElementOnActiveHitPath(candidate)) {
        active = true;
        return;
      }
      candidate.visitChildElements(probe);
    }

    probe(element);
    return active;
  }

  /// Gives an icon-only control a readable alias when a single nearby text
  /// label clearly describes it (for example `btn.gear_alt` ->
  /// `btn.change_mode`). The raw handle remains primary; aliases are only
  /// added when unique so Scout never trades obscure handles for ambiguity.
  List<ScoutNode> _inferIntentAliases(List<ScoutNode> nodes) {
    final textNodes = nodes
        .where((node) => node.kind == 'text' && node.label != null)
        .toList(growable: false);
    final proposed = <int, String>{};
    final aliasCounts = <String, int>{};
    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      final rect = node.rect;
      if ((node.kind != 'btn' && node.kind != 'tap') ||
          rect == null ||
          node.key != null ||
          rect.width > 96 ||
          rect.height > 96 ||
          node.id.contains('gesturedetector')) {
        continue;
      }
      final candidates = [
        for (final text in textNodes)
          if (text.rect case final textRect?)
            if (text.visibleFraction > 0 &&
                // Material icon glyphs are exposed as RichText nodes too.
                // They describe their own icon, not the intent of a nearby
                // control, so never use them as cross-control labels.
                text.widgetType != 'RichText' &&
                _isUsefulActionLabel(text.label!) &&
                !_contains(rect, textRect) &&
                _nearbyIntentLabel(rect, textRect))
              text,
      ];
      if (candidates.isEmpty) continue;
      candidates.sort(
        (a, b) => _intentLabelDistance(
          rect,
          a.rect!,
        ).compareTo(_intentLabelDistance(rect, b.rect!)),
      );
      // A nearby icon can have more than one qualifying text node in a dense
      // toolbar. Keep the clearly nearest label, but refuse a tie rather than
      // inventing an ambiguous intent alias.
      if (candidates.length > 1 &&
          (_intentLabelDistance(rect, candidates[1].rect!) -
                      _intentLabelDistance(rect, candidates.first.rect!))
                  .abs() <
              8) {
        continue;
      }
      final alias = '${node.kind}.${_slug(candidates.first.label!)}';
      if (alias == node.id) continue;
      proposed[index] = alias;
      aliasCounts.update(alias, (count) => count + 1, ifAbsent: () => 1);
    }
    return [
      for (var index = 0; index < nodes.length; index++)
        if (proposed[index] case final alias?)
          if (aliasCounts[alias] == 1)
            nodes[index].withAltIds([alias])
          else
            nodes[index]
        else
          nodes[index],
    ];
  }

  bool _nearbyIntentLabel(Rect control, Rect label) {
    final verticalGap = (control.center.dy - label.center.dy).abs();
    // Intent labels are only inferred from the immediately trailing text. A
    // symmetric "nearby" search makes adjacent toolbar icons borrow each
    // other's Material icon labels (for example copy -> settings), which is
    // worse than exposing no alias at all.
    final trailingGap = label.left - control.right;
    return verticalGap <= 24 && trailingGap >= 0 && trailingGap <= 32;
  }

  double _intentLabelDistance(Rect control, Rect label) =>
      (control.center - label.center).distance;

  Map<String, Object?>? _activeSurfaceFor({
    required bool modalActive,
    required bool allowVisibleTextFallback,
    required List<Map<String, Object?>> overlays,
    required Set<String> visibleText,
    required List<ScoutNode> textTargets,
    required Size logicalSize,
  }) {
    if (!modalActive || (textTargets.isEmpty && visibleText.isEmpty)) {
      return null;
    }
    final overlaySurface = _activeSurfaceFromOverlays(
      overlays: overlays,
      textTargets: textTargets,
      logicalSize: logicalSize,
    );
    if (overlaySurface != null) return overlaySurface;
    final contentStartOrdinal = _modalContentStartOrdinal(overlays);
    final candidates = [
      for (final node in textTargets)
        if (node.rect case final rect?)
          if (node.visibleFraction > 0 &&
              (contentStartOrdinal == null || node.hitTestable) &&
              (contentStartOrdinal != null ||
                  rect.center.dy <= logicalSize.height * 0.30) &&
              _surfaceLabelScore(node.label ?? '') > 0)
            node,
    ];
    if (candidates.isEmpty) {
      if (!allowVisibleTextFallback) return null;
      final labels =
          [
            for (final label in visibleText)
              if (_surfaceLabelScore(label) > 0) label.trim(),
          ]..sort((a, b) {
            final rank = _surfaceLabelScore(b).compareTo(_surfaceLabelScore(a));
            if (rank != 0) return rank;
            return a.length.compareTo(b.length);
          });
      final label = labels.isEmpty ? null : labels.first;
      if (label == null || label.isEmpty) return null;
      final displayLabel = _surfaceDisplayLabel(label);
      final anchors =
          [
            for (final node in textTargets)
              if ((node.label ?? '').trim() == label) node,
          ]..sort(
            (a, b) => (a._treeOrdinal ?? 1 << 30).compareTo(
              b._treeOrdinal ?? 1 << 30,
            ),
          );
      final anchor = anchors.isEmpty ? null : anchors.first;
      return {
        'kind': 'modal',
        'label': displayLabel,
        'screen': '${_pascalCaseSurfaceName(displayLabel)}Surface',
        if (anchor?._treeOrdinal != null) 'anchorOrdinal': anchor!._treeOrdinal,
        if (anchor?.rect case final rect?)
          'anchorRect': [rect.left, rect.top, rect.width, rect.height],
        'source': 'visibleText',
        'heuristicScore': 0.62,
        'scoreKind': 'uncalibrated_heuristic',
      };
    }
    candidates.sort((a, b) {
      final rank = _surfaceTitleRank(
        b,
        logicalSize,
      ).compareTo(_surfaceTitleRank(a, logicalSize));
      if (rank != 0) return rank;
      final center = logicalSize.width / 2;
      final aCenter = ((a.rect?.center.dx ?? center) - center).abs();
      final bCenter = ((b.rect?.center.dx ?? center) - center).abs();
      final centered = aCenter.compareTo(bCenter);
      if (centered != 0) return centered;
      return (a.rect?.top ?? 0).compareTo(b.rect?.top ?? 0);
    });
    final label = candidates.first.label?.trim();
    if (label == null || label.isEmpty) return null;
    final displayLabel = _surfaceDisplayLabel(label);
    return {
      'kind': 'modal',
      'label': displayLabel,
      'screen': '${_pascalCaseSurfaceName(displayLabel)}Surface',
      if (candidates.first._treeOrdinal != null)
        'anchorOrdinal': candidates.first._treeOrdinal,
      if (candidates.first.rect case final rect?)
        'anchorRect': [rect.left, rect.top, rect.width, rect.height],
      'source': 'prominentText',
      'heuristicScore': _surfaceLabelRank(label) > 0 ? 0.92 : 0.74,
      'scoreKind': 'uncalibrated_heuristic',
    };
  }

  bool _coversViewport(Map<String, Object?> overlay, Size logicalSize) {
    final rect =
        _rectFromJsonList(overlay['visibleRect']) ??
        _rectFromJsonList(overlay['rect']);
    if (rect == null || logicalSize.width <= 0 || logicalSize.height <= 0) {
      return false;
    }
    // Permit minor safe-area/frame insets while rejecting a modal barrier
    // owned by a nested panel (for example, the right pane in a desktop app).
    return rect.width >= logicalSize.width * 0.90 &&
        rect.height >= logicalSize.height * 0.90;
  }

  Map<String, Object?>? _activeSurfaceFromOverlays({
    required List<Map<String, Object?>> overlays,
    required List<ScoutNode> textTargets,
    required Size logicalSize,
  }) {
    for (final overlay in overlays.reversed) {
      if (overlay['kind'] == 'modalBarrier') continue;
      final rect = _rectFromJsonList(overlay['rect']);
      final title = _surfaceTitleForRegion(
        textTargets: textTargets,
        region: rect,
        fallbackLabel: overlay['label']?.toString(),
        logicalSize: logicalSize,
      );
      final label = title?.label.trim();
      if (label == null || label.isEmpty) continue;
      final displayLabel = _surfaceDisplayLabel(label);
      final anchors =
          [
            for (final node in textTargets)
              if ((node.label ?? '').trim() == label) node,
          ]..sort(
            (a, b) => (a._treeOrdinal ?? 1 << 30).compareTo(
              b._treeOrdinal ?? 1 << 30,
            ),
          );
      final anchor = anchors.isEmpty ? null : anchors.first;
      return {
        'kind': 'modal',
        'label': displayLabel,
        'screen': '${_pascalCaseSurfaceName(displayLabel)}Surface',
        if (anchor?._treeOrdinal != null) 'anchorOrdinal': anchor!._treeOrdinal,
        if (anchor?.rect case final rect?)
          'anchorRect': [rect.left, rect.top, rect.width, rect.height],
        if (overlay['rect'] != null) 'rect': overlay['rect'],
        'source': title?.source ?? 'overlayLabel',
        'heuristicScore': title?.confidence ?? 0.86,
        'scoreKind': 'uncalibrated_heuristic',
      };
    }
    return null;
  }

  int? _modalContentStartOrdinal(List<Map<String, Object?>> overlays) {
    for (final overlay in overlays.reversed) {
      if (overlay['kind'] != 'modalBarrier') continue;
      final ordinal = overlay['ordinal'];
      if (ordinal is int) return ordinal;
    }
    return null;
  }

  ({String label, String source, double confidence})? _surfaceTitleForRegion({
    required List<ScoutNode> textTargets,
    required Rect? region,
    required String? fallbackLabel,
    required Size logicalSize,
  }) {
    final fallback = fallbackLabel?.trim();
    if (fallback != null && _surfaceLabelScore(fallback) > 0) {
      return (label: fallback, source: 'overlayLabel', confidence: 0.9);
    }
    final candidates = [
      for (final node in textTargets)
        if (node.rect case final rect?)
          if (node.visibleFraction > 0 &&
              (region != null || node.hitTestable) &&
              (region == null ||
                  region.contains(rect.center) ||
                  rect.overlaps(region)) &&
              _surfaceLabelScore(node.label ?? '') > 0)
            node,
    ];
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final rank = _surfaceTitleRank(
        b,
        logicalSize,
      ).compareTo(_surfaceTitleRank(a, logicalSize));
      if (rank != 0) return rank;
      return (a.rect?.top ?? 0).compareTo(b.rect?.top ?? 0);
    });
    final label = candidates.first.label?.trim();
    if (label == null || label.isEmpty) return null;
    return (label: label, source: 'regionTitle', confidence: 0.78);
  }

  static const Set<String> _genericModalSurfaceNames = {
    'Dialog',
    'BottomSheet',
    'Modal',
    'ActionSheet',
  };

  int _surfaceLabelRank(String label) {
    // Surface detection must stay app-agnostic. Product-specific words used
    // to outrank the actual topmost modal header (for example an underlying
    // "Appointment" label beating a "Select Shop" sheet title).
    return 0;
  }

  int _surfaceLabelScore(String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return 0;
    final slug = _scoutSlug(trimmed);
    if (slug.isEmpty) return 0;
    final allowlistRank = _surfaceLabelRank(trimmed);
    if (allowlistRank > 0) return allowlistRank;
    if (trimmed.length > 48) return 0;
    if (!_hasWordCharacter(trimmed)) return 0;
    if (_surfaceLooksLikePureValue(trimmed)) return 0;
    if (_looksLikeActionOnlyLabel(slug)) return 0;
    final wordCount = slug.split('_').where((part) => part.isNotEmpty).length;
    // Single glyphs such as calendar weekday initials are not surface titles.
    if (trimmed.length < 2) return 0;
    if (wordCount > 7) return 0;
    var score = 24;
    if (wordCount <= 4) score += 8;
    if (RegExp(r'^[A-Z0-9]').hasMatch(trimmed)) score += 4;
    if (trimmed.contains(':')) score -= 8;
    return score.clamp(0, 79);
  }

  int _surfaceTitleRank(ScoutNode node, Size logicalSize) {
    final rect = node.rect;
    final label = node.label ?? '';
    var score = _surfaceLabelScore(label);
    if (score <= 0 || rect == null) return score;
    final topBias = logicalSize.height <= 0
        ? 0
        : ((1 - (rect.top / logicalSize.height).clamp(0, 1)) * 12).round();
    final center = logicalSize.width / 2;
    final centeredBias = logicalSize.width <= 0
        ? 0
        : ((1 - ((rect.center.dx - center).abs() / center).clamp(0, 1)) * 8)
              .round();
    return score + topBias + centeredBias;
  }

  bool _hasWordCharacter(String value) =>
      RegExp(r'[A-Za-z0-9]').hasMatch(value);

  bool _surfaceLooksLikePureValue(String value) {
    return RegExp(r'^[\d\s()+\-.%/,]+$').hasMatch(value.trim()) &&
        RegExp(r'\d').hasMatch(value);
  }

  bool _looksLikeActionOnlyLabel(String slug) {
    return const {
      'ok',
      'yes',
      'no',
      'save',
      'done',
      'apply',
      'cancel',
      'close',
      'back',
      'next',
      'previous',
      'continue',
      'submit',
      'delete',
      'edit',
      'add',
      'search',
      'clear',
      'reset',
    }.contains(slug);
  }

  String _pascalCaseSurfaceName(String label) {
    final slug = _scoutSlug(label.replaceAll(RegExp(r'\([^)]*\)'), ''));
    final parts = slug
        .split('_')
        .where(
          (part) =>
              part.isNotEmpty &&
              !RegExp(r'^\d+$').hasMatch(part) &&
              !_surfaceNameStopWords.contains(part),
        );
    final buffer = StringBuffer();
    for (final part in parts) {
      buffer
        ..write(part[0].toUpperCase())
        ..write(part.length == 1 ? '' : part.substring(1));
    }
    return buffer.isEmpty ? 'Modal' : buffer.toString();
  }

  String _surfaceDisplayLabel(String label) {
    var result = label.trim();
    for (final word in _surfaceNameStopWords) {
      result = result.replaceFirst(
        RegExp('\\s+$word\$', caseSensitive: false),
        '',
      );
    }
    return result.trim().isEmpty ? label.trim() : result.trim();
  }

  static const Set<String> _surfaceNameStopWords = {
    'body',
    'content',
    'details',
    'detail',
    'description',
    'message',
    'text',
  };

  /// Framework widgets whose type ends in Screen/Page but are NOT app pages
  /// (e.g. the dialog-wrapping DisplayFeatureSubScreen), so screen detection
  /// doesn't latch onto them.
  static const Set<String> _frameworkScreenWidgets = {
    'DisplayFeatureSubScreen',
    'TwoDimensionalViewport',
  };

  /// A readable name for the topmost modal surface when no *Screen/*Page
  /// widget exists — so bottom sheets, dialogs, and custom-named routes stop
  /// reporting the useless 'RootWidget'. Prefers the pushed route's own
  /// widget type; falls back to a generic surface kind.
  String? _modalScreenName(Element root) {
    // Deepest (topmost) modal surface widget wins.
    String? surfaceKind;
    var surfaceDepth = -1;
    var barrierDepth = -1;
    _walkPerceptionVisible(root, (Element element) {
      final depth = _elementDepth(element);
      // A visible ModalBarrier is the general signal that a modal is open —
      // showDialog/showModalBottomSheet/showGeneralDialog and most custom
      // overlays put one behind their content. It catches modals that use no
      // standard Dialog/BottomSheet widget (a plain Container-in-Stack panel).
      if (_isModalBarrierWidget(element.widget)) {
        final rect = _rectFor(element);
        if (rect != null &&
            _visibleRectFor(rect) != null &&
            depth > barrierDepth) {
          barrierDepth = depth;
        }
        return;
      }
      final kind = _modalSurfaceKind(element.widget);
      if (kind == null) return;
      if (depth > surfaceDepth) {
        surfaceKind = kind;
        surfaceDepth = depth;
      }
    });
    if (surfaceKind != null) {
      // Prefer the modal's actual content class over the generic surface kind.
      return _deepestCustomWidgetType(
            root,
            minDepth: surfaceDepth,
            allowSurfaceSuffix: true,
          ) ??
          surfaceKind;
    }
    if (barrierDepth >= 0) {
      // Custom modal over a barrier: name from its content, else generic.
      return _deepestCustomWidgetType(
            root,
            minDepth: barrierDepth,
            allowSurfaceSuffix: true,
          ) ??
          'Modal';
    }
    // No modal at all — still try to name the page from its deepest custom
    // content widget (custom-named routes without a *Screen/*Page class).
    return _deepestCustomWidgetType(
      root,
      minDepth: -1,
      allowSurfaceSuffix: false,
    );
  }

  bool _isModalBarrierWidget(Widget widget) {
    if (widget is ModalBarrier) return true;
    // AnimatedModalBarrier is private-typed; match by name.
    return widget.runtimeType.toString().contains('ModalBarrier');
  }

  bool _hasConcreteModalSurface(Element root) {
    var found = false;
    _walkVisible(root, (Element element) {
      if (found) return;
      final kind = _modalSurfaceKind(element.widget);
      if (kind == null) return;
      final rect = _rectFor(element);
      if (rect == null || _visibleRectFor(rect) == null) return;
      found = true;
    });
    return found;
  }

  /// The kind of modal surface a widget represents, or null.
  String? _modalSurfaceKind(Widget widget) {
    if (widget is Dialog || widget is AlertDialog || widget is SimpleDialog) {
      return 'Dialog';
    }
    if (widget is BottomSheet) return 'BottomSheet';
    final type = widget.runtimeType.toString();
    if (type.contains('CupertinoActionSheet')) return 'ActionSheet';
    if (type.contains('CupertinoAlertDialog')) return 'Dialog';
    if (type.contains('DraggableScrollableSheet') ||
        type.contains('_BottomSheet') ||
        type.contains('ModalBottomSheet')) {
      return 'BottomSheet';
    }
    if (type.contains('CupertinoPopupSurface') ||
        type.contains('_CupertinoModal')) {
      return 'Modal';
    }
    return null;
  }

  /// Deepest non-framework (non-`_`, non-SDK-prefixed) widget type below
  /// [minDepth], used to name a modal from its actual content class.
  String? _deepestCustomWidgetType(
    Element root, {
    required int minDepth,
    required bool allowSurfaceSuffix,
  }) {
    String? best;
    var bestDepth = minDepth;
    var bestRank = 0;
    _walkVisible(root, (Element element) {
      final depth = _elementDepth(element);
      if (depth <= bestDepth) return;
      final type = element.widget.runtimeType.toString();
      if (type.startsWith('_')) return;
      if (_frameworkWidgetPrefixes.any(type.startsWith)) return;
      if (_frameworkScreenWidgets.contains(type)) return;
      final rank = _customWidgetScreenRank(
        type,
        allowSurfaceSuffix: allowSurfaceSuffix,
      );
      if (rank > 0 &&
          _isElementOnActiveHitPath(element) &&
          (rank > bestRank || rank == bestRank && depth > bestDepth)) {
        best = type;
        bestDepth = depth;
        bestRank = rank;
      }
    });
    return best;
  }

  int _customWidgetScreenRank(String type, {required bool allowSurfaceSuffix}) {
    if (type == 'MyApp' ||
        type == 'App' ||
        type == 'Root' ||
        type == 'Bootstrap' ||
        type == 'ProviderScope') {
      return 0;
    }
    if (type.endsWith('Screen') ||
        type.endsWith('Page') ||
        type.endsWith('Sheet') ||
        type.endsWith('Dialog') ||
        type.endsWith('Body') ||
        type.endsWith('Content') ||
        type.endsWith('View') ||
        type.endsWith('Panel') ||
        type.endsWith('Pane') ||
        type.endsWith('Flow') ||
        type.endsWith('Hub') ||
        type.endsWith('Workspace')) {
      return 100;
    }
    if (allowSurfaceSuffix && type.endsWith('Surface')) return 90;
    if (type.endsWith('Surface')) return 0;
    return 0;
  }

  static const List<String> _frameworkWidgetPrefixes = [
    'Padding',
    'Align',
    'Center',
    'Column',
    'Row',
    'Stack',
    'Container',
    'SizedBox',
    'Text',
    'RichText',
    'DefaultTextStyle',
    'Icon',
    'Builder',
    'Semantics',
    'GestureDetector',
    'Listener',
    'RawGestureDetector',
    'MouseRegion',
    'Focus',
    'Shortcuts',
    'Actions',
    'Navigator',
    'Overlay',
    'Hero',
    'Flexible',
    'Expanded',
    'ListView',
    'GridView',
    'ScrollView',
    'CustomScrollView',
    'SingleChildScrollView',
    'NestedScrollView',
    'PageView',
    'TabBarView',
    'Scaffold',
    'Material',
    'SafeArea',
    'Positioned',
    'DecoratedBox',
    'ConstrainedBox',
    'FractionallySizedBox',
    'Cupertino',
    // Common framework widgets whose type ends in Content/View and would
    // otherwise masquerade as an app page.
    'Reorderable',
    'Animated',
    'Sliver',
    'Overflow',
    'Viewport',
    'Draggable',
    'Dismissible',
    'Transform',
    'Opacity',
    'RepaintBoundary',
  ];

  List<ScoutAnnotationTarget> _annotationTargets() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return const <ScoutAnnotationTarget>[];
    final rawRoute = ModalRoute.of(root)?.settings.name;
    final route = rawRoute == null ? null : _redactSensitiveText(rawRoute);
    final screen = _redactSensitiveText(_screenName(root, rawRoute));
    final modalElement = _activeAnnotationModalElement(root);
    final targets = <ScoutAnnotationTarget>[];
    // Containers (cards/tiles/rows/buttons) are gated by whether they hold a
    // visible leaf, decided after the walk: a covered container has none, a
    // padded icon button has the (small, off-center) icon. Point-sampling a
    // mostly-empty box is unreliable, so we defer them here. Keyed by render
    // object, not element: some widgets (e.g. CupertinoButton) rebuild their
    // element identity between passes while reusing the same render object, so
    // an element-keyed link between a leaf and its container can miss.
    final containerCandidates =
        <({RenderObject render, ScoutAnnotationTarget target})>[];
    final rendersWithVisibleLeaf = <RenderObject>{};
    _walkPerceptionVisible(root, (Element element) {
      try {
        _collectAnnotationTarget(
          element: element,
          modalElement: modalElement,
          screen: screen,
          route: route,
          targets: targets,
          containerCandidates: containerCandidates,
          rendersWithVisibleLeaf: rendersWithVisibleLeaf,
        );
      } catch (_) {
        // One misbehaving widget must not abort annotation-target collection.
      }
    });

    for (final candidate in containerCandidates) {
      // A container is kept when it holds a visible leaf descendant — i.e. some
      // of its own content is on screen (a covered container has none).
      if (rendersWithVisibleLeaf.contains(candidate.render)) {
        targets.add(candidate.target);
      }
    }

    final enriched = _inferAnnotationTargetLabels(
      targets,
    ).where(_keepAnnotationTarget).toList(growable: false);

    final deduped = <String, ScoutAnnotationTarget>{};
    for (final target in _removeOversizedModalTargets(
      enriched,
      modalActive: modalElement != null,
    )) {
      final rect = target.rect;
      final rectKey = [
        rect.left.round(),
        rect.top.round(),
        rect.width.round(),
        rect.height.round(),
      ].join(':');
      // Collapse co-located container layers that share a rect and label into
      // one box (e.g. a tappable tile and the surface it paints, or a button's
      // InkWell and its GestureDetector), keyed by label not stableId; plain
      // targets keep their stableId key.
      final key = _isContainerKind(target.kind)
          ? 'c:${(target.label ?? '').toLowerCase().trim()}:$rectKey'
          : '${target.stableId}:$rectKey';
      final existing = deduped[key];
      if (existing == null ||
          _annotationTargetRank(target) > _annotationTargetRank(existing) ||
          (_annotationTargetRank(target) == _annotationTargetRank(existing) &&
              target.depth > existing.depth)) {
        deduped[key] = target;
      }
    }
    final result = _collapseNestedContainers(deduped.values.toList())
      ..sort((a, b) {
        final top = a.rect.top.compareTo(b.rect.top);
        if (top != 0) return top;
        final left = a.rect.left.compareTo(b.rect.left);
        if (left != 0) return left;
        return a.rect.width.compareTo(b.rect.width);
      });
    return result;
  }

  void _collectAnnotationTarget({
    required Element element,
    required Element? modalElement,
    required String screen,
    required String? route,
    required List<ScoutAnnotationTarget> targets,
    required List<({RenderObject render, ScoutAnnotationTarget target})>
    containerCandidates,
    required Set<RenderObject> rendersWithVisibleLeaf,
  }) {
    {
      if (element.widget is ErrorWidget) return;
      if (!_isInsideActiveAnnotationModal(element, modalElement)) return;
      if (_isInsideSensitiveEditable(element)) return;
      final widget = element.widget;
      final widgetType = widget.runtimeType.toString();
      final rawKey = _annotationKeyLabel(widget.key);
      final key = rawKey == null ? null : _redactSensitiveText(rawKey);
      final rawText = _ownText(widget)?.trim();
      final text = rawText == null ? null : _redactSensitiveText(rawText);
      final kind = _annotationKindFor(widget, element);
      final interactive = kind == 'tap' || kind == 'btn';
      // A "surface" is a non-interactive box that paints a visible background
      // (a card/panel). Like interactive containers, it's worth selecting as a
      // whole box even though its label lives in its children.
      final surface =
          !interactive &&
          (kind == 'widget' || kind == 'layout') &&
          _paintsVisibleSurface(element);
      // Row/Column/Wrap that group content (an icon + a label, a stat pair) are
      // worth pointing at as a unit for fine tweaks. Stack is excluded — it is
      // usually a positioning layer, not a visual group. Groupings only survive
      // if inference finds them a label (see _keepAnnotationTarget).
      final grouping = !interactive && (widget is Flex || widget is Wrap);
      final container = interactive || surface || grouping;

      // Cheap usefulness filter FIRST, before any geometry or hit testing, so
      // the many plain layout widgets that can never be a target cost nothing
      // beyond a few field reads — no rect projection, no hit tests. Container
      // targets are kept even without their own label (inferred after the walk).
      // _labelFor descends the subtree, so defer it: widget/layout usefulness
      // checks only own text, and container labels are resolved post-gate.
      String? label;
      if (container) {
        if (widgetType.startsWith('_')) return;
      } else {
        if (kind != 'widget' && kind != 'layout') {
          final rawLabel = _labelFor(element, widget);
          label = rawLabel == null ? null : _redactSensitiveText(rawLabel);
        }
        if (!_isUsefulAnnotationTarget(
          widget: widget,
          kind: kind,
          key: key,
          label: label,
          text: text,
        )) {
          return;
        }
      }

      // Geometry only for plausible targets.
      final rect = _rectFor(element);
      if (rect == null || rect.width < 1 || rect.height < 1) return;
      final visibleRect = _visibleRectFor(rect);
      if (visibleRect == null) return;
      // Leaves (text/icons/images) must themselves be the topmost responder —
      // the strict occlusion gate. Containers skip it and are gated post-walk by
      // holding a visible leaf.
      if (!container && !_leafReceivesHit(element, rect)) return;

      final rawLabel = label == null ? _labelFor(element, widget) : null;
      label ??= rawLabel == null ? null : _redactSensitiveText(rawLabel);
      final ancestors = _ancestorSummary(element);
      final target = ScoutAnnotationTarget(
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
        scoutNodeId: _scoutNodeIdFor(element, widget, label),
      );
      final render = element.renderObject;
      if (container) {
        if (render != null) {
          containerCandidates.add((render: render, target: target));
        }
      } else {
        targets.add(target);
        // A visible leaf makes every render object on its ancestor chain "have
        // content", so the enclosing containers survive the gate below.
        for (RenderObject? node = render; node != null; node = node.parent) {
          rendersWithVisibleLeaf.add(node);
        }
      }
    }
  }

  // A chain of wrapper widgets (GestureDetector > LabelWidget > Padding …) can
  // render one logical box at nearly the same rect several times, all carrying
  // the same inferred label. Collapse only those near-identical duplicates,
  // keeping the largest. Distinct nested sub-regions (a card and the padded
  // panel inside it) have meaningfully different rects and all survive, so the
  // user can point at each — as do side-by-side same-label items.
  List<ScoutAnnotationTarget> _collapseNestedContainers(
    List<ScoutAnnotationTarget> targets,
  ) {
    const tolerance = 6.0;
    bool nearlyEqual(Rect a, Rect b) =>
        (a.left - b.left).abs() <= tolerance &&
        (a.top - b.top).abs() <= tolerance &&
        (a.right - b.right).abs() <= tolerance &&
        (a.bottom - b.bottom).abs() <= tolerance;

    final byLabel = <String, List<ScoutAnnotationTarget>>{};
    final kept = <ScoutAnnotationTarget>[];
    for (final target in targets) {
      if (!_isContainerKind(target.kind) ||
          (target.label ?? '').trim().isEmpty) {
        kept.add(target);
      } else {
        (byLabel[target.label!.toLowerCase().trim()] ??= []).add(target);
      }
    }
    for (final group in byLabel.values) {
      // Highest-rank first (keyed > btn > tap > surface/layout) then largest,
      // so when a wrapper chain collapses we keep the most meaningful kind — a
      // tappable card, not the anonymous layout/box rendered at the same rect.
      group.sort((a, b) {
        final rank = _annotationTargetRank(
          b,
        ).compareTo(_annotationTargetRank(a));
        if (rank != 0) return rank;
        return _rectArea(b.rect).compareTo(_rectArea(a.rect));
      });
      final keptInGroup = <ScoutAnnotationTarget>[];
      for (final target in group) {
        if (keptInGroup.any((k) => nearlyEqual(k.rect, target.rect))) continue;
        keptInGroup.add(target);
      }
      kept.addAll(keptInGroup);
    }
    return kept;
  }

  // Mirrors inspect's `_inferActionableLabel`: a tappable container that has no
  // text of its own borrows a concise label from a text target sitting inside
  // it, so cards/tiles/rows become selectable whole-box targets. Targets that
  // stay unlabeled are dropped by [_keepAnnotationTarget].
  List<ScoutAnnotationTarget> _inferAnnotationTargetLabels(
    List<ScoutAnnotationTarget> targets,
  ) {
    final textTargets = [
      for (final target in targets)
        if (target.kind == 'text' &&
            (target.label ?? target.text)?.trim().isNotEmpty == true)
          target,
    ];
    if (textTargets.isEmpty) return targets;
    final viewportArea = _rectArea(_viewportRect());
    return [
      for (final target in targets)
        if (_isContainerKind(target.kind) &&
            (target.label == null || target.label!.trim().isEmpty))
          _inferAnnotationTargetLabel(target, textTargets, viewportArea)
        else
          target,
    ];
  }

  static bool _isContainerKind(String kind) =>
      kind == 'tap' || kind == 'btn' || kind == 'widget' || kind == 'layout';

  ScoutAnnotationTarget _inferAnnotationTargetLabel(
    ScoutAnnotationTarget target,
    List<ScoutAnnotationTarget> textTargets,
    double viewportArea,
  ) {
    final rect = target.rect;
    final area = _rectArea(rect);
    // Skip page-sized tappables (scroll/dismiss layers); their contained text
    // is ambiguous and a giant box is useless to annotate.
    if (viewportArea > 0 && area / viewportArea > 0.45) return target;
    final contained = [
      for (final textTarget in textTargets)
        if (rect.contains(textTarget.rect.center) &&
            textTarget.visibleFraction > 0 &&
            _isUsefulActionLabel(
              (textTarget.label ?? textTarget.text ?? '').trim(),
            ))
          textTarget,
    ];
    if (contained.isEmpty) return target;
    contained.sort((a, b) {
      final la = (a.label ?? a.text ?? '').trim();
      final lb = (b.label ?? b.text ?? '').trim();
      final rank = _actionLabelRank(lb).compareTo(_actionLabelRank(la));
      if (rank != 0) return rank;
      return b.rect.width.compareTo(a.rect.width);
    });
    final label = (contained.first.label ?? contained.first.text ?? '').trim();
    if (label.isEmpty) return target;
    // Preserve key-derived handles; only enrich the human-readable label. A
    // button-like label promotes a bare tappable to 'btn', but a non-interactive
    // surface keeps its kind (it is not actually a button).
    final canPromote = target.kind == 'tap' || target.kind == 'btn';
    final kind =
        canPromote &&
            (target.key == null || target.key!.isEmpty) &&
            _buttonLikeActionLabel(label)
        ? 'btn'
        : target.kind;
    return _annotationTargetWithLabel(target, kind: kind, label: label);
  }

  ScoutAnnotationTarget _annotationTargetWithLabel(
    ScoutAnnotationTarget target, {
    required String kind,
    required String label,
  }) {
    return ScoutAnnotationTarget(
      id: _annotationTargetId(
        kind: kind,
        widgetType: target.widgetType,
        key: target.key,
        label: label,
        text: target.text,
        rect: target.rect,
        ancestors: target.ancestorSummary,
      ),
      stableId: _stableAnnotationId(
        kind: kind,
        widgetType: target.widgetType,
        key: target.key,
        label: label,
        text: target.text,
      ),
      kind: kind,
      widgetType: target.widgetType,
      key: target.key,
      label: label,
      text: target.text,
      screen: target.screen,
      routeGuess: target.routeGuess,
      rect: target.rect,
      visibleRect: target.visibleRect,
      visibleFraction: target.visibleFraction,
      depth: target.depth,
      ancestorSummary: target.ancestorSummary,
      scoutNodeId: target.scoutNodeId,
    );
  }

  // Interactive containers kept through the walk are only useful once they
  // carry a key or an (inferred) label; drop the rest. Other kinds were already
  // vetted in the walk.
  // Preference when several targets collapse to one box: a keyed handle beats a
  // labeled button, which beats a bare tappable.
  int _annotationTargetRank(ScoutAnnotationTarget target) {
    if (target.key != null && target.key!.isNotEmpty) return 4;
    if (target.kind == 'btn') return 3;
    if (target.kind == 'tap') return 2;
    return 1; // widget/layout surface and everything else
  }

  bool _keepAnnotationTarget(ScoutAnnotationTarget target) {
    if (!_isContainerKind(target.kind)) return true;
    if (target.key != null && target.key!.isNotEmpty) return true;
    // Require a real word/number; this drops containers whose only "label" is an
    // icon-font glyph (private-use-area rune) or that never resolved a label.
    final word = RegExp(r'[A-Za-z0-9]');
    final label = target.label?.trim() ?? '';
    if (label.isNotEmpty && word.hasMatch(label)) return true;
    // A widget/layout target that arrived with its own text (vetted in the walk)
    // is still useful even if inference found no better label.
    final text = target.text?.trim() ?? '';
    return text.isNotEmpty && word.hasMatch(text);
  }

  // A surface is a non-interactive box that paints a visible background (fill,
  // gradient, border, or shadow): a card or panel worth selecting as a whole.
  // Detected from the widget so it stays cheap and avoids surfacing transparent
  // layout wrappers (which were the original "widgets under the stack" clutter).
  bool _paintsVisibleSurface(Element element) {
    final widget = element.widget;
    if (widget is Card) return true;
    if (widget is Material) {
      final color = widget.color;
      return color != null && color.a > 0.05;
    }
    if (widget is Container) {
      final color = widget.color;
      if (color != null && color.a > 0.05) return true;
      final decoration = widget.decoration;
      return decoration != null && _decorationFillVisible(decoration);
    }
    // CircleAvatar and other implicitly-animated boxes paint their fill through
    // an AnimatedContainer (which folds any `color` into its decoration).
    if (widget is AnimatedContainer) {
      final decoration = widget.decoration;
      return decoration != null && _decorationFillVisible(decoration);
    }
    if (widget is DecoratedBox) {
      return _decorationFillVisible(widget.decoration);
    }
    if (widget is ColoredBox) return widget.color.a > 0.05;
    return false;
  }

  bool _decorationFillVisible(Decoration decoration) {
    if (decoration is BoxDecoration) {
      final color = decoration.color;
      if (color != null && color.a > 0.05) return true;
      if (decoration.gradient != null) return true;
      if (decoration.border != null) return true;
      return decoration.boxShadow?.isNotEmpty ?? false;
    }
    if (decoration is ShapeDecoration) {
      final color = decoration.color;
      if (color != null && color.a > 0.05) return true;
      return decoration.gradient != null;
    }
    // Some other concrete decoration that exists — assume it paints something.
    return true;
  }

  Element? _activeAnnotationModalElement(Element root) {
    Element? result;
    var resultDepth = -1;
    _walkVisible(root, (Element element) {
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

  // A leaf (text/icon/image) is visible only if it is itself the topmost
  // responder at one of a few sample points — occlusion-aware, so a leaf buried
  // under an opaque sibling is dropped (and, via the container gate, so is any
  // container that holds only buried leaves).
  bool _leafReceivesHit(Element element, Rect rect) {
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

  // Runs a global hit test at [point] with the overlay absorber held
  // transparent (see _ScoutHitTestGate), then evaluates [matches] against the
  // resulting topmost-first path.
  bool _hitTest(Offset point, bool Function(HitTestResult) matches) {
    final wasCollecting = _collectingAnnotationTargets;
    _collectingAnnotationTargets = true;
    try {
      final result = HitTestResult();
      WidgetsBinding.instance.hitTestInView(result, point, _primaryViewId);
      return matches(result);
    } catch (_) {
      return false;
    } finally {
      _collectingAnnotationTargets = wasCollecting;
    }
  }

  bool _hitTestPathContainsRenderObject(Offset point, RenderObject target) {
    return _hitTest(
      point,
      (result) => result.path.any((entry) => identical(entry.target, target)),
    );
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
}
