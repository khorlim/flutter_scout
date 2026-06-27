part of 'flutter_scout_binding.dart';

// part: widget-tree snapshot + annotation target collection + hit testing.

extension _RuntimeSnapshot on FlutterScoutRuntime {
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
      if (result.path.any((entry) => identical(entry.target, target))) {
        return true;
      }
    } catch (_) {
      // Fall through to the overlay-aware fallback below.
    }
    // While annotation mode is active the overlay paints a full-screen opaque
    // gesture layer that absorbs the global hit test, truncating its path
    // before it reaches app widgets. Fall back to a direct hit test against the
    // target's own subtree so widgets remain selectable underneath the overlay.
    if (_annotationMode && target is RenderBox && target.attached) {
      try {
        final local = target.globalToLocal(point);
        if (target.size.contains(local)) {
          final boxResult = BoxHitTestResult();
          if (target.hitTest(boxResult, position: local)) return true;
        }
      } catch (_) {
        return false;
      }
    }
    return false;
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
