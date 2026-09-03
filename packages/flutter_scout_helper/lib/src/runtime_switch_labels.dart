part of 'flutter_scout_binding.dart';

extension _RuntimeSwitchLabels on FlutterScoutRuntime {
  /// Ordinary settings rows often put a title far from their trailing switch.
  /// Use the nearest horizontal Flex and its child branches, never proximity
  /// across unrelated rows. Keep ambiguous or over-budget rows unlabeled.
  String? _switchRowLabel(Element control) {
    if (!_isSwitchWidget(control.widget)) return null;
    Element? row;
    var ancestorsLeft = 32;
    control.visitAncestorElements((ancestor) {
      if (--ancestorsLeft <= 0) return false;
      final widget = ancestor.widget;
      if (widget is Flex) {
        if (widget.direction == Axis.horizontal) row = ancestor;
        // A vertical group is a boundary, not a reason to borrow another row.
        return false;
      }
      if (widget is ScrollView || widget is ListTile) return false;
      return true;
    });
    if (row == null) return null;

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

  bool _isSwitchWidget(Widget widget) =>
      widget is Switch || widget is CupertinoSwitch;
}
