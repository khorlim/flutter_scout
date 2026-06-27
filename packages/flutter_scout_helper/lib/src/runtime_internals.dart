part of 'flutter_scout_binding.dart';

// part: low-level pointer dispatch, tree walk, snapshot delta, and JSON response helpers.

extension _RuntimeInternals on FlutterScoutRuntime {
  void _setEditableText(EditableTextState state, String value) {
    state.requestKeyboard();
    state.userUpdateTextEditingValue(
      TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      ),
      SelectionChangedCause.keyboard,
    );
  }

  Future<void> _dispatchTap(Offset point) async {
    await _dispatchPress(point, hold: const Duration(milliseconds: 30));
  }

  Future<void> _dispatchPress(Offset point, {required Duration hold}) async {
    final binding = GestureBinding.instance;
    final pointer = _nextSyntheticPointer++;
    final viewId = _primaryViewId;
    binding.handlePointerEvent(
      PointerAddedEvent(
        pointer: pointer,
        device: pointer,
        position: point,
        kind: PointerDeviceKind.touch,
        viewId: viewId,
      ),
    );
    binding.handlePointerEvent(
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
    binding.handlePointerEvent(
      PointerUpEvent(
        pointer: pointer,
        device: pointer,
        position: point,
        kind: PointerDeviceKind.touch,
        viewId: viewId,
      ),
    );
    binding.handlePointerEvent(
      PointerRemovedEvent(
        pointer: pointer,
        device: pointer,
        position: point,
        kind: PointerDeviceKind.touch,
        viewId: viewId,
      ),
    );
  }

  Future<void> _dispatchDrag(Offset start, Offset delta) async {
    final binding = GestureBinding.instance;
    final pointer = _nextSyntheticPointer++;
    final viewId = _primaryViewId;
    binding.handlePointerEvent(
      PointerAddedEvent(
        pointer: pointer,
        device: pointer,
        position: start,
        kind: PointerDeviceKind.touch,
        viewId: viewId,
      ),
    );
    binding.handlePointerEvent(
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
      binding.handlePointerEvent(
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
    binding.handlePointerEvent(
      PointerUpEvent(
        pointer: pointer,
        device: pointer,
        position: start + delta,
        kind: PointerDeviceKind.touch,
        viewId: viewId,
      ),
    );
    binding.handlePointerEvent(
      PointerRemovedEvent(
        pointer: pointer,
        device: pointer,
        position: start + delta,
        kind: PointerDeviceKind.touch,
        viewId: viewId,
      ),
    );
  }

  int get _primaryViewId {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    return views.isEmpty ? 0 : views.first.viewId;
  }

  void _walk(Element element, void Function(Element element) visitor) {
    visitor(element);
    element.visitChildElements((Element child) => _walk(child, visitor));
  }

  bool _changed(ScoutSnapshot before, ScoutSnapshot after) =>
      jsonEncode(before.summaryJson()) != jsonEncode(after.summaryJson()) ||
      _geometryChanged(before, after);

  bool _geometryChanged(ScoutSnapshot before, ScoutSnapshot after) {
    return _changedGeometryIds(before, after).isNotEmpty;
  }

  Map<String, Object?> _delta(ScoutSnapshot before, ScoutSnapshot after) {
    final beforeText = before.visibleText.toSet();
    final afterText = after.visibleText.toSet();
    final beforeFields = before.fields.map((node) => node.id).toSet();
    final afterFields = after.fields.map((node) => node.id).toSet();
    final beforeActions = before.interactables.map((node) => node.id).toSet();
    final afterActions = after.interactables.map((node) => node.id).toSet();
    final beforeFieldValues = {
      for (final node in before.fields) node.id: node.value,
    };
    final afterFieldValues = {
      for (final node in after.fields) node.id: node.value,
    };
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
    final changedGeometry = _changedGeometryIds(before, after);
    return {
      'screenChanged': before.screen != after.screen,
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
          if (beforeFieldValues[id] != afterFieldValues[id]) id,
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
      'newInteractables': afterActions
          .difference(beforeActions)
          .toList(growable: false),
      'removedInteractables': beforeActions
          .difference(afterActions)
          .toList(growable: false),
    };
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
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'ok': true, ...value}),
    );
  }

  developer.ServiceExtensionResponse _fail(
    String code,
    String message, {
    Map<String, Object?> extra = const {},
  }) {
    return developer.ServiceExtensionResponse.result(
      jsonEncode({
        'ok': false,
        'error': {'code': code, 'message': message},
        ...extra,
        'recentErrors': _recentErrors(),
      }),
    );
  }
}
