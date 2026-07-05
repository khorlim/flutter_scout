part of 'flutter_scout_binding.dart';

// part: node post-processing: compaction, label inference, disambiguation, visual tree, geometry helpers.

extension _RuntimeNodes on FlutterScoutRuntime {
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

  bool _isScoutOverlayWidget(Widget widget) {
    return widget.runtimeType.toString().startsWith('_FlutterScout');
  }

  /// The id [_nodeFromElement] would assign, computed directly from values the
  /// annotation walk already has. Avoids rebuilding a whole node (which re-runs
  /// an ancestor-walk, a rect computation, a label scan and a hit test) just to
  /// read its id — the hot redundancy in annotation-target collection.
  String? _scoutNodeIdFor(Element element, Widget widget, String? label) {
    final kind = _kindFor(widget, element);
    if (kind == null) return null;
    return _stableId(kind, label, widget.key, widget.runtimeType.toString());
  }

  ScoutNode? _nodeFromElement(Element element) {
    if (_isHiddenByAncestor(element)) return null;
    final widget = element.widget;
    final rect = _rectFor(element);
    if (rect == null || rect.width < 1 || rect.height < 1) return null;

    final kind = _kindFor(widget, element);
    if (kind == null) return null;

    final label = _labelFor(
      element,
      widget,
      deepText: _usesDeepTextLabel(widget),
    );
    final baseId = _stableId(
      kind,
      label,
      widget.key,
      element.widget.runtimeType.toString(),
    );
    // Alternate handles from the other label sources, so the node stays
    // addressable when its primary label source flickers (e.g. an
    // async-loaded Semantics username appearing after first paint).
    final altIds = <String>{};
    if (kind == 'btn' || kind == 'tap') {
      for (final alternate in [
        _iconLabelBelow(element),
        _semanticsLabelBelow(element),
        _textBelow(element),
      ]) {
        final trimmed = alternate?.trim();
        if (trimmed == null || trimmed.isEmpty || !_hasWord(trimmed)) continue;
        final altId = '$kind.${_slug(trimmed)}';
        if (altId != baseId) altIds.add(altId);
      }
    }
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
      selected: kind == 'text' ? null : _selectedStateFor(element, widget),
      altIds: altIds.toList(growable: false),
      textColor: kind == 'btn' || kind == 'tap'
          ? _effectiveTextColor(element)
          : null,
    );
  }

  /// Effective ARGB color of the first text descendant, resolving inherited
  /// colors via the nearest DefaultTextStyle (getInheritedWidgetOfExactType —
  /// no dependency is registered, safe outside build).
  int? _effectiveTextColor(Element element) {
    return _probeSubtree(element, (Element child) {
      final widget = child.widget;
      TextStyle? style;
      if (widget is Text) {
        style = widget.style;
      } else if (widget is RichText) {
        style = widget.text.style;
      } else {
        return null;
      }
      final color =
          style?.color ??
          child.getInheritedWidgetOfExactType<DefaultTextStyle>()?.style.color;
      return color?.toARGB32();
    });
  }

  /// Records, for each interactable that is fully enclosed by a larger
  /// interactable, the enclosing handle. A small keyed control (an avatar or
  /// icon inside a whole tappable row/card) can be a no-op on its own; the
  /// enclosing handle is the reliable fallback, so agents don't tap a dead
  /// center and give up.
  List<ScoutNode> _linkEnclosingTargets(List<ScoutNode> nodes) {
    final boxes = <int>[
      for (var i = 0; i < nodes.length; i++)
        if ((nodes[i].kind == 'btn' || nodes[i].kind == 'tap') &&
            nodes[i].rect != null)
          i,
    ];
    if (boxes.length < 2) return nodes;
    final result = [...nodes];
    for (final i in boxes) {
      final inner = nodes[i].rect!;
      final innerArea = inner.width * inner.height;
      if (innerArea <= 0) continue;
      String? bestId;
      double bestArea = double.infinity;
      for (final j in boxes) {
        if (j == i) continue;
        final outer = nodes[j].rect!;
        final outerArea = outer.width * outer.height;
        // Strictly larger, and fully containing the inner rect (small slop).
        if (outerArea <= innerArea * 1.3) continue;
        if (!_contains(outer, inner)) continue;
        if (outerArea < bestArea) {
          bestArea = outerArea;
          bestId = nodes[j].id;
        }
      }
      if (bestId != null) result[i] = nodes[i].withEnclosingTarget(bestId);
    }
    return result;
  }

  bool _contains(Rect outer, Rect inner) {
    const slop = 2.0;
    return inner.left >= outer.left - slop &&
        inner.top >= outer.top - slop &&
        inner.right <= outer.right + slop &&
        inner.bottom <= outer.bottom + slop;
  }

  /// Heuristic selection for CUSTOM segments/chips that expose no Semantics:
  /// in a horizontal run of >=3 adjacent same-kind tappables, when exactly
  /// one label color differs from an otherwise uniform rest, that outlier is
  /// the active segment. Applies only where nothing better is known
  /// (selected == null), so real widget/semantics state always wins.
  List<ScoutNode> _inferSegmentSelection(List<ScoutNode> nodes) {
    final candidates = <int>[
      for (var i = 0; i < nodes.length; i++)
        if ((nodes[i].kind == 'btn' || nodes[i].kind == 'tap') &&
            nodes[i].selected == null &&
            nodes[i].rect != null &&
            nodes[i].textColor != null)
          i,
    ];
    if (candidates.length < 3) return nodes;
    final result = [...nodes];
    final used = <int>{};
    for (final seed in candidates) {
      if (used.contains(seed)) continue;
      final group = <int>[
        for (final other in candidates)
          if (!used.contains(other) &&
              nodes[other].kind == nodes[seed].kind &&
              (nodes[other].rect!.top - nodes[seed].rect!.top).abs() <= 6 &&
              (nodes[other].rect!.height - nodes[seed].rect!.height).abs() <= 6)
            other,
      ];
      group.forEach(used.add);
      if (group.length < 3) continue;
      group.sort((a, b) => nodes[a].rect!.left.compareTo(nodes[b].rect!.left));
      // Segments sit shoulder to shoulder; a spread-out row (toolbar corners)
      // must not be treated as one control.
      var adjacent = true;
      for (var i = 1; i < group.length; i++) {
        final previous = nodes[group[i - 1]].rect!;
        final current = nodes[group[i]].rect!;
        final gap = current.left - previous.right;
        if (gap < -8 || gap > previous.height * 2) {
          adjacent = false;
          break;
        }
      }
      if (!adjacent) continue;
      final counts = <int, int>{};
      for (final index in group) {
        counts.update(nodes[index].textColor!, (n) => n + 1, ifAbsent: () => 1);
      }
      if (counts.length != 2) continue;
      final outliers = [
        for (final entry in counts.entries)
          if (entry.value == 1) entry.key,
      ];
      if (outliers.length != 1) continue;
      for (final index in group) {
        result[index] = nodes[index].withSelected(
          nodes[index].textColor == outliers.single,
        );
      }
    }
    return result;
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
        widget is FloatingActionButton ||
        widget is CupertinoButton) {
      return 'btn';
    }
    // Toggle/selection controls are tappable state-carrying interactables;
    // without a kind they would be invisible to agents (only their inner
    // gesture plumbing would surface, unlabeled and stateless).
    if (widget is Switch ||
        widget is CupertinoSwitch ||
        widget is Checkbox ||
        widget is ChoiceChip ||
        widget is FilterChip ||
        widget is InputChip ||
        widget is ActionChip) {
      return 'btn';
    }
    if (widget is GestureDetector ||
        widget is InkWell ||
        widget is InkResponse ||
        widget is ListTile) {
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
      // TickerMode(enabled:false) does NOT hide — it only pauses tickers; the
      // subtree stays visible and hit-testable (see _hidesSubtree).
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

  bool _usesDeepTextLabel(Widget widget) {
    return widget is ButtonStyleButton ||
        widget is IconButton ||
        widget is FloatingActionButton ||
        widget is CupertinoButton ||
        widget is GestureDetector ||
        widget is InkWell ||
        widget is InkResponse ||
        widget is ListTile;
  }

  String? _labelFor(Element element, Widget widget, {bool deepText = false}) {
    if (widget is Tooltip) return widget.message;
    if (widget is Semantics) {
      final semanticsLabel = widget.properties.label;
      if (semanticsLabel != null && semanticsLabel.trim().isNotEmpty) {
        return semanticsLabel.trim();
      }
    }
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
    final widgetType = widget.runtimeType.toString();
    if (widget is Switch ||
        widget is CupertinoSwitch ||
        widget is Checkbox ||
        widgetType == 'Switch' ||
        widgetType == 'CupertinoSwitch' ||
        widgetType == 'Checkbox') {
      return null;
    }
    final tooltip = _tooltipBelow(element);
    if (tooltip != null && tooltip.isNotEmpty) return tooltip;
    final own = _ownText(widget);
    if (own != null && own.trim().isNotEmpty) {
      final iconText = _iconLabelForText(
        own,
        fontFamily: _textFontFamily(widget),
      );
      if (iconText != null) return iconText;
      if (_hasWord(own)) return own.trim();
    }
    final text = _textBelow(element, maxDepth: deepText ? 18 : 5);
    if (text != null &&
        text.isNotEmpty &&
        _hasWord(text) &&
        _iconLabelForText(text) == null) {
      return text.trim();
    }
    // Icon-only control from here on. An explicit accessibility label is a
    // deliberate name and wins over glyph naming.
    final semantics = _semanticsLabelBelow(element);
    if (semantics != null && semantics.isNotEmpty) return semantics;
    // An Icon/glyph widget below knows its font family (resolving cross-font
    // codepoint collisions), so prefer it over interpreting bare glyph text.
    final icon = _iconLabelBelow(element);
    if (icon != null && icon.isNotEmpty) return icon;
    return null;
  }

  String? _textFontFamily(Widget widget) {
    if (widget is Text) return widget.style?.fontFamily;
    if (widget is RichText) return widget.text.style?.fontFamily;
    return null;
  }

  String? _semanticsLabelBelow(Element element) {
    return _labelInSubtree(element, (Element child) {
      final widget = child.widget;
      if (widget is Semantics) return widget.properties.label;
      return null;
    });
  }

  /// Budgeted whole-subtree search for a label. Depth caps are the wrong
  /// bound here — a button's content routinely sits 10-20 wrapper elements
  /// down (CupertinoButton alone contributes ~19). The correct boundary is
  /// semantic: never descend into a nested interactive control, because its
  /// content names that control, not the ancestor being labeled.
  String? _labelInSubtree(
    Element element,
    String? Function(Element element) probe,
  ) {
    final value = _probeSubtree(element, probe);
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// Shared subtree walk behind [_labelInSubtree] and selection-state mining:
  /// first non-null probe result wins, nested interactive controls are not
  /// descended into (their content describes them, not the ancestor), and an
  /// element budget bounds the cost.
  T? _probeSubtree<T>(Element element, T? Function(Element element) probe) {
    T? result;
    var budget = 400;
    void visit(Element child) {
      if (result != null || budget <= 0) return;
      budget -= 1;
      final value = probe(child);
      if (value != null) {
        result = value;
        return;
      }
      final kind = _kindFor(child.widget, child);
      if (kind == 'btn' || kind == 'tap' || kind == 'field') return;
      child.visitChildElements(visit);
    }

    element.visitChildElements(visit);
    return result;
  }

  /// Selection/toggle state for a node, from the widget itself or (for
  /// containers like tabs and segments) a state-bearing descendant.
  bool? _selectedStateFor(Element element, Widget widget) {
    final own = _widgetSelectedState(widget);
    if (own != null) return own;
    return _probeSubtree(
      element,
      (child) => _widgetSelectedState(child.widget),
    );
  }

  bool? _widgetSelectedState(Widget widget) {
    if (widget is Switch) return widget.value;
    if (widget is CupertinoSwitch) return widget.value;
    if (widget is Checkbox) return widget.value;
    if (widget is ChoiceChip) return widget.selected;
    if (widget is FilterChip) return widget.selected;
    if (widget is InputChip) return widget.selected;
    if (widget is ListTile) return widget.selected ? true : null;
    if (widget is Semantics) {
      final properties = widget.properties;
      return properties.selected ?? properties.toggled ?? properties.checked;
    }
    return null;
  }

  static final RegExp _wordChar = RegExp(r'[A-Za-z0-9]');
  bool _hasWord(String value) => _wordChar.hasMatch(value);

  String? _validationMessageForFieldWidget(Widget widget) {
    if (widget is TextField) {
      return widget.decoration?.errorText;
    }
    return null;
  }

  String? _iconLabelBelow(Element element) {
    return _labelInSubtree(
      element,
      (Element child) => _iconLabelForWidget(child.widget),
    );
  }

  String? _iconLabelForWidget(Widget widget) {
    if (widget is Icon) {
      final semantic = widget.semanticLabel;
      if (semantic != null && semantic.trim().isNotEmpty) {
        return semantic.trim();
      }
      return _iconLabelForData(widget.icon);
    }
    if (widget is Image) {
      final semantic = widget.semanticLabel;
      if (semantic != null && semantic.trim().isNotEmpty) {
        return semantic.trim();
      }
    }
    // A bare single-glyph Text/RichText (an icon font used without an Icon
    // widget) still carries its font family in its style.
    final own = _ownText(widget);
    if (own != null && own.trim().runes.length == 1) {
      return _iconLabelForText(own, fontFamily: _textFontFamily(widget));
    }
    return null;
  }

  String? _iconLabelForText(String value, {String? fontFamily}) {
    final trimmed = value.trim();
    if (trimmed.runes.length != 1) return null;
    final codePoint = trimmed.runes.single;
    final named =
        _iconLabelForCodePoint(codePoint) ??
        _iconNameFromTables(codePoint, fontFamily: fontFamily);
    if (named != null) return named;
    // Only a private-use-area rune is an icon glyph; a plain character ("5",
    // "A") must keep its literal text label, not become icon_35.
    if (_isIconGlyphCodePoint(codePoint)) {
      return 'icon_${codePoint.toRadixString(16)}';
    }
    return null;
  }

  String? _iconLabelForData(IconData? icon) {
    if (icon == null) return null;
    return _iconLabelForCodePoint(icon.codePoint) ??
        _iconNameFromTables(icon.codePoint, fontFamily: icon.fontFamily) ??
        'icon_${icon.codePoint.toRadixString(16)}';
  }

  /// Glyph name from the SDK-generated lookup tables. [fontFamily] (when the
  /// caller has an [IconData]) resolves cross-font codepoint collisions.
  String? _iconNameFromTables(int codePoint, {String? fontFamily}) {
    // A package-scoped font renders as 'packages/cupertino_icons/CupertinoIcons'.
    if (fontFamily != null && fontFamily.contains('CupertinoIcons')) {
      return kCupertinoIconNames[codePoint] ?? kMaterialIconNames[codePoint];
    }
    return kMaterialIconNames[codePoint] ?? kCupertinoIconNames[codePoint];
  }

  bool _isIconGlyphCodePoint(int codePoint) {
    // BMP private use area + supplementary private use planes, where icon
    // fonts place their glyphs.
    return (codePoint >= 0xe000 && codePoint <= 0xf8ff) || codePoint >= 0xf0000;
  }

  /// Semantic action names for common glyphs, ahead of the raw SDK names, so
  /// agents can guess intent handles (btn.save, btn.back) across icon choices.
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

  String? _textBelow(Element element, {int depth = 0, int maxDepth = 5}) {
    if (depth > maxDepth) return null;
    final own = _ownText(element.widget);
    if (own != null && own.trim().isNotEmpty) return own.trim();
    String? result;
    element.visitChildElements((Element child) {
      result ??= _textBelow(child, depth: depth + 1, maxDepth: maxDepth);
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
    } else if (_isModalBarrierWidget(widget)) {
      // A visible barrier means a modal is up even when its content is a
      // custom Container (no Dialog/BottomSheet widget) — so `overlays` is no
      // longer empty and agents know a scrim is intercepting the background.
      final rect = _rectFor(element);
      if (rect == null || _visibleRectFor(rect) == null) return null;
      kind = 'modalBarrier';
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
    final rect = topLeft & renderObject.size;
    // A degenerate/invalid transform (or a non-finite size) can make
    // localToGlobal return NaN or Infinity, producing a non-finite rect. Such
    // a rect is not a real, tappable region, and any downstream `.round()` or
    // JSON serialization would throw ("Unsupported operation: Infinity or NaN
    // toInt"), breaking inspect/tap/waitStable for the entire screen. Treat it
    // as having no geometry; every caller already handles a null rect.
    if (!rect.isFinite) return null;
    return rect;
  }

  Offset? _pointForTarget(
    String? target,
    Map<String, String> params, {
    ScoutSnapshot? snapshot,
  }) {
    final explicitPoint = _pointFromParams(params);
    if (explicitPoint != null) return explicitPoint;
    if (target == null || target.isEmpty) return null;
    // Reuse the caller's snapshot when it has one — building a fresh one just
    // to resolve a handle doubles the per-action tree-walk cost.
    final node = (snapshot ?? _snapshot()).findNode(target);
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
        if (_isStateControlWidgetType(node.widgetType))
          node.withoutLabel(confidence: 0.65)
        else if ((node.kind == 'tap' || node.kind == 'btn') &&
            !_isStateControlWidgetType(node.widgetType) &&
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
          // A cell/card's own label is frequently NOT hit-testable because the
          // card's tappable sits on top of it — so requiring hitTestable left
          // list/grid cells unlabeled (tap.gesturedetector_N noise). Accept
          // non-hittable text when THIS node fully contains it: the node is
          // then what's occluding the text, so borrowing its label is safe.
          if (rect.contains(textRect.center) &&
              textNode.visibleFraction > 0 &&
              (textNode.hitTestable || _contains(rect, textRect)) &&
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
    // Preserve explicit key-derived handles: when the widget carries a Key,
    // keep its stable `kind.<key>` id (and kind) so agents can discover and
    // target it, and only enrich the human-readable label from contained text.
    if (node.key != null && node.key!.isNotEmpty) {
      return node.copyWith(label: label, confidence: 0.86);
    }
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
    if (RegExp(r'^\d+([.,]\d+)?$').hasMatch(trimmed)) {
      return true;
    }
    return _actionLabelRank(trimmed) > 0 ||
        (trimmed.length >= 3 && RegExp(r'[A-Za-z]').hasMatch(trimmed));
  }

  bool _isStateControlWidgetType(String widgetType) {
    return widgetType == 'Switch' ||
        widgetType == 'CupertinoSwitch' ||
        widgetType == 'Checkbox';
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

    // Drop anonymous gesture-detector wrappers: an unlabeled, keyless `tap`
    // node that substantially coincides with a LABELED interactable is a
    // wrapper of that control, not a distinct action — it only adds
    // tap.gesturedetector_N noise, and the labeled sibling is the real
    // handle. Kept when it stands alone (a genuine invisible hit area).
    for (var i = 0; i < result.length; i++) {
      if (indexesToRemove.contains(i)) continue;
      final node = result[i];
      if (node.kind != 'tap' || node.rect == null) continue;
      if ((node.label != null && node.label!.trim().isNotEmpty) ||
          (node.key != null && node.key!.isNotEmpty)) {
        continue;
      }
      for (var j = 0; j < result.length; j++) {
        if (i == j || indexesToRemove.contains(j)) continue;
        final other = result[j];
        if (other.rect == null) continue;
        final labeled =
            (other.label != null && other.label!.trim().isNotEmpty) ||
            (other.key != null && other.key!.isNotEmpty);
        if (!labeled) continue;
        if (other.kind != 'btn' && other.kind != 'tap') continue;
        if (_overlapRatio(node.rect!, other.rect!) >= 0.8) {
          indexesToRemove.add(i);
          break;
        }
      }
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

  _TextTargetMatch? _findVisibleTextMatch(String text, {bool loose = false}) {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    final wanted = text.trim();
    final wantedLower = wanted.toLowerCase();
    _TextTargetMatch? exact;
    _TextTargetMatch? contains;
    _TextTargetMatch? truncated;
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
        return;
      }
      final ownLower = own.toLowerCase();
      if (wanted.length >= 3 &&
          contains == null &&
          ownLower.contains(wantedLower)) {
        contains = match;
      }
      // Truncation: the on-screen label is a shortened prefix of the query
      // (e.g. "Prenatal Bliss…" for "Prenatal Bliss Massage"). Only with the
      // explicit `loose` opt-in, since it is a weaker signal.
      if (loose && truncated == null) {
        final stripped = ownLower.replaceAll(RegExp(r'[…\.\s]+$'), '');
        if (stripped.length >= 4 && wantedLower.startsWith(stripped)) {
          truncated = match;
        }
      }
    });
    return exact ?? contains ?? truncated;
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
      // Ignore text that cannot be hit (e.g. the base screen sitting behind a
      // dialog's modal barrier); the keypad's own value display is on top and
      // hit-testable, so this keeps an unrelated digit-bearing label from
      // winning as the current value.
      if (!node.hitTestable) continue;
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
}
