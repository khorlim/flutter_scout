part of 'flutter_scout_binding.dart';

// part: state an app only paints.
//
// Scout reads a control's state from its widget or Semantics (`selected`,
// `checked`, `toggled`, `expanded`). A custom chip, segment or filter that
// shows its state only by colour, border or opacity has none of those, so
// Scout cannot tell which one is on. This part does not guess the state. It
// points at the control: a receipt says when a tap changed only how its
// target is painted, and a scene names controls that look like a choice
// without stating one. Both tell the agent to read a crop, and the app to add
// `Semantics(selected: ...)`.

/// The paint configuration of a control's own render subtree: text style
/// (not the text, which the scene already compares), box decoration,
/// opacity, physical model colour and image tint. Custom painters are left
/// out: an app usually builds a new painter object every frame. Bounded to
/// [budget] render objects.
List<String> _paintFacets(RenderObject? root, {int budget = 80}) {
  final facets = <String>[];
  if (root == null || !root.attached) return facets;
  final queue = <RenderObject>[root];
  var visited = 0;
  while (queue.isNotEmpty && visited < budget) {
    final object = queue.removeAt(0);
    visited += 1;
    final facet = _paintFacet(object);
    if (facet != null) facets.add(facet);
    object.visitChildren(queue.add);
  }
  return facets;
}

String? _paintFacet(RenderObject object) {
  int? argb(Color? color) => color?.toARGB32();
  switch (object) {
    case RenderParagraph():
      final style = object.text.style;
      return 'text:${argb(style?.color)}:${style?.fontWeight?.value}:'
          '${style?.decoration}:${argb(style?.backgroundColor)}';
    case RenderDecoratedBox():
      return 'box:${object.decoration.hashCode}';
    case RenderOpacity():
      return 'opacity:${object.opacity}';
    case RenderAnimatedOpacity():
      return 'opacity:${object.opacity.value}';
    case RenderPhysicalModel():
      return 'model:${argb(object.color)}:${object.elevation}';
    case RenderPhysicalShape():
      return 'shape:${argb(object.color)}:${object.elevation}';
    case RenderImage():
      return 'image:${argb(object.color)}:${object.opacity?.value}';
  }
  return null;
}

const String _paintedStateFix =
    'add Semantics(selected: ...) (checked:, toggled: for a check box or '
    'switch) around the control so Scout and screen readers see its state';

extension _RuntimePaintedState on FlutterScoutRuntime {
  /// Receipt evidence when an input changed nothing Scout reads but changed
  /// how [node] is painted: its state likely changed where only pixels show
  /// it. Null otherwise.
  Map<String, Object?>? _paintOnlyChange(
    ScoutNode? node,
    List<String>? before, {
    required bool changed,
  }) {
    if (changed || node == null || before == null) return null;
    final render = node._renderObject;
    if (render == null || !render.attached) return null;
    final after = _paintFacets(render);
    if (listEquals(before, after)) return null;
    return <String, Object?>{
      'target': node.id,
      'hint':
          'The input changed how ${node.id} is painted (colour, border, '
          'decoration or opacity) but no state Scout can read. Check a crop '
          'before tapping it again; the app can $_paintedStateFix.',
    };
  }

  /// Controls in one row or wrap of look-alike controls whose state Scout
  /// cannot read: siblings state theirs and these do not, or they are painted
  /// differently from each other and none states one. At most four groups.
  List<Map<String, Object?>> _stateHints(List<ScoutNode> controls) {
    final groups = <RenderObject, List<ScoutNode>>{};
    for (final node in controls) {
      if (node.kind != 'btn' && node.kind != 'tap') continue;
      final parent = _choiceParent(node._renderObject);
      if (parent == null) continue;
      (groups[parent] ??= <ScoutNode>[]).add(node);
    }
    bool stated(ScoutNode node) =>
        node.selected != null || node.states.isNotEmpty;
    final hints = <Map<String, Object?>>[];
    for (final members in groups.values) {
      if (hints.length >= 4) break;
      if (members.length < 2 || members.length > 12) continue;
      final unstated = members.where((node) => !stated(node)).toList();
      if (unstated.isEmpty) continue;
      if (unstated.length < members.length) {
        hints.add(<String, Object?>{
          'ids': [for (final node in unstated.take(6)) node.id],
          'reason': 'siblings_report_state',
          'siblings': [
            for (final node in members.where(stated).take(6)) node.id,
          ],
        });
        continue;
      }
      // None states anything: a choice drawn only in paint looks like
      // same-type, same-height controls painted differently.
      final type = members.first.widgetType;
      final height = members.first.rect?.height;
      if (height == null ||
          members.any(
            (node) =>
                node.widgetType != type ||
                node.rect == null ||
                (node.rect!.height - height).abs() > 2,
          )) {
        continue;
      }
      final looks = {
        for (final node in members)
          _paintFacets(node._renderObject, budget: 40).join('|'),
      };
      if (looks.length < 2) continue;
      hints.add(<String, Object?>{
        'ids': [for (final node in members.take(6)) node.id],
        'reason': 'painted_differently',
      });
    }
    return hints;
  }

  /// The row, column or wrap that lays out [render] and its look-alike
  /// siblings, a few levels up and never across a scrollable or another
  /// surface.
  RenderObject? _choiceParent(RenderObject? render) {
    var current = render?.parent;
    for (var depth = 0; current != null && depth < 10; depth += 1) {
      if (current is RenderFlex || current is RenderWrap) return current;
      if (current is RenderViewportBase || current is RenderSliver) return null;
      current = current.parent;
    }
    return null;
  }

  /// The scene's `stateHints`: why Scout cannot read these controls' state
  /// and what to do about it.
  Map<String, Object?>? _stateHintsPayload(List<ScoutNode> controls) {
    final hints = _stateHints(controls);
    if (hints.isEmpty) return null;
    return <String, Object?>{
      'controls': hints,
      'note':
          'These controls may show a state only in paint; Scout cannot read '
          'it. Read a crop to see it; the app can $_paintedStateFix.',
    };
  }
}
