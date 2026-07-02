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
    var degradedNodes = 0;
    final logicalSize = _logicalSize();
    if (root != null) {
      // _walkVisible prunes hidden subtrees AND Scout's own overlay chrome:
      // the annotation FAB/badge must never surface as app interactables
      // (tap.add_location_alt) that an agent might try to press.
      _walkVisible(root, (Element element) {
        // Per-element fault isolation: reading one misbehaving widget (a
        // throwing property getter, corrupt render state, …) must skip that
        // element only — never blind the agent to the entire screen.
        try {
          debugSnapshotNodeProbe?.call(element);
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
        } catch (_) {
          degradedNodes += 1;
        }
      });
    }

    List<ScoutNode> compactNodes;
    try {
      compactNodes = _disambiguateIds(
        _inferActionableLabels(_compactNodes(nodes)),
      );
    } catch (_) {
      // Post-processing failed as a batch; fall back to the raw nodes so the
      // agent keeps (noisier) eyes instead of none.
      degradedNodes += 1;
      compactNodes = nodes;
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
      degradedNodes: degradedNodes,
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
    _walkVisible(root, (Element element) {
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
      if (!_isInsideActiveAnnotationModal(element, modalElement)) return;
      final widget = element.widget;
      final widgetType = widget.runtimeType.toString();
      final key = _annotationKeyLabel(widget.key);
      final text = _ownText(widget)?.trim();
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
          label = _labelFor(element, widget);
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

      label ??= _labelFor(element, widget);
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
