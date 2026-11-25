part of 'flutter_scout_binding.dart';

extension _RuntimeSwitchLabels on FlutterScoutRuntime {
  /// Ordinary settings rows often put a title far from their trailing switch.
  /// Use the nearest horizontal Flex and its child branches, never proximity
  /// across unrelated rows. Keep ambiguous or over-budget rows unlabeled.
  ///
  /// A switch or checkbox in a list tile (SwitchListTile, CheckboxListTile,
  /// a ListTile with a trailing switch) takes the tile's title. In a
  /// vertical group, one text stacked directly above the control (a
  /// "Roundup" caption over its switch) names it.
  String? _switchRowLabel(Element control) {
    if (!_isSwitchWidget(control.widget)) return null;
    Element? row;
    Element? tile;
    var vertical = false;
    var ancestorsLeft = 48;
    control.visitAncestorElements((ancestor) {
      if (--ancestorsLeft <= 0) return false;
      final widget = ancestor.widget;
      if (widget is Flex) {
        row = ancestor;
        vertical = widget.direction == Axis.vertical;
        return false;
      }
      if (widget is ListTile) {
        tile = ancestor;
        return false;
      }
      if (widget is ScrollView) return false;
      return true;
    });
    if (tile != null) return _listTileTitleText(tile!);
    if (row == null) return null;
    final controlRect = _rectFor(control);
    if (vertical && controlRect == null) return null;

    final branches = <Element>[];
    row!.visitChildElements(branches.add);
    final textBranches = <List<({String label, Rect rect})>>[];
    var budget = 400;
    var foundControl = false;
    var otherControl = false;
    for (final branch in branches) {
      final texts = <({String label, Rect rect})>[];
      var containsControl = false;
      void visit(Element element) {
        if (budget-- <= 0 || otherControl) return;
        if (identical(element, control)) {
          foundControl = true;
          containsControl = true;
          return; // Ignore the switch's internal gesture/semantics plumbing.
        }
        if (_isHiddenByAncestor(element)) return;
        final widget = element.widget;
        final kind = _kindFor(widget, element);
        if (_isSwitchWidget(widget) ||
            kind == 'btn' ||
            kind == 'tap' ||
            kind == 'field') {
          otherControl = true;
          return;
        }
        if (_isInsideSensitiveEditable(element)) return;
        if (widget is Text || widget is RichText) {
          final label = _ownText(widget)?.trim();
          final rect = _rectFor(element);
          if (label != null &&
              _hasWord(label) &&
              _iconLabelForText(label, fontFamily: _textFontFamily(widget)) ==
                  null &&
              rect != null) {
            texts.add((label: label, rect: rect));
          }
          return; // Text builds RichText; do not count that label twice.
        }
        element.visitChildElements(visit);
      }

      visit(branch);
      if (containsControl && texts.isNotEmpty) return null;
      if (texts.isNotEmpty) textBranches.add(texts);
    }
    if (budget <= 0 ||
        !foundControl ||
        otherControl ||
        textBranches.length != 1) {
      return null;
    }
    final texts = textBranches.single
      ..sort((a, b) => a.rect.top.compareTo(b.rect.top));
    final title = texts.first;
    // Stacked: the caption must sit above the control, not below it.
    if (vertical &&
        (texts.length != 1 || title.rect.bottom > controlRect!.top + 2)) {
      return null;
    }
    // Built offscreen rows retain their name for locate/reveal. Visibility and
    // dispatch are independently enforced on the switch by target resolution.
    // A vertical title/subtitle stack has one primary label. Side-by-side
    // texts, overlapping titles, or a separate column of text are ambiguous.
    for (final subtitle in texts.skip(1)) {
      if (subtitle.rect.top < title.rect.bottom - 1 ||
          (subtitle.rect.left >= title.rect.right ||
              subtitle.rect.right <= title.rect.left)) {
        return null;
      }
    }
    return title.label;
  }

  /// The text of a list tile's own title slot, when it has one word label.
  String? _listTileTitleText(Element tile) {
    final title = (tile.widget as ListTile).title;
    if (title == null) return null;
    Element? slot;
    var budget = 1500;
    void find(Element element) {
      if (budget-- <= 0 || slot != null) return;
      if (identical(element.widget, title)) {
        slot = element;
        return;
      }
      // The title never sits inside the tile's own switch or checkbox.
      if (_isSwitchWidget(element.widget)) return;
      element.visitChildElements(find);
    }

    tile.visitChildElements(find);
    final text = slot == null
        ? null
        : _textBelow(slot!, maxDepth: 12, wordsOnly: true);
    return text == null || !_hasWord(text) ? null : text;
  }

  bool _isSwitchWidget(Widget widget) =>
      widget is Switch ||
      widget is CupertinoSwitch ||
      widget is Checkbox ||
      widget is CupertinoCheckbox;
}
