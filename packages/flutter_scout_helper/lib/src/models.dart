part of 'flutter_scout_binding.dart';

// part: data models (snapshot, node, annotation, capture-result, and the
// small value types shared across the runtime).

class ScoutSnapshot {
  const ScoutSnapshot({
    required this.screen,
    required this.routeGuess,
    required this.idle,
    required this.devicePixelRatio,
    required this.logicalSize,
    required this.visibleText,
    required this.hitTestableText,
    required this.offscreenText,
    required this.interactables,
    required this.fields,
    required this.textTargets,
    required this.scrollables,
    required this.overlays,
    required this.visualTree,
    required this.controlGroups,
    required this.suggestedActions,
    required this.recentErrors,
  });

  final String screen;
  final String? routeGuess;
  final bool idle;
  final double devicePixelRatio;
  final Size logicalSize;
  final List<String> visibleText;
  final List<String> hitTestableText;
  final List<String> offscreenText;
  final List<ScoutNode> interactables;
  final List<ScoutNode> fields;
  final List<ScoutNode> textTargets;
  final List<Map<String, Object?>> scrollables;
  final List<Map<String, Object?>> overlays;
  final Map<String, Object?>? visualTree;
  final List<Map<String, Object?>> controlGroups;
  final List<Map<String, Object?>> suggestedActions;
  final List<Map<String, Object?>> recentErrors;

  ScoutSnapshot copyWith({
    Map<String, Object?>? visualTree,
    List<Map<String, Object?>>? controlGroups,
    List<Map<String, Object?>>? suggestedActions,
  }) {
    return ScoutSnapshot(
      screen: screen,
      routeGuess: routeGuess,
      idle: idle,
      devicePixelRatio: devicePixelRatio,
      logicalSize: logicalSize,
      visibleText: visibleText,
      hitTestableText: hitTestableText,
      offscreenText: offscreenText,
      interactables: interactables,
      fields: fields,
      textTargets: textTargets,
      scrollables: scrollables,
      overlays: overlays,
      visualTree: visualTree ?? this.visualTree,
      controlGroups: controlGroups ?? this.controlGroups,
      suggestedActions: suggestedActions ?? this.suggestedActions,
      recentErrors: recentErrors,
    );
  }

  ScoutNode? findNode(String target) {
    for (final node in [...interactables, ...fields, ...textTargets]) {
      if (node.matches(target)) return node;
    }
    return null;
  }

  ScoutNode? findField(String target) {
    for (final node in fields) {
      if (node.matches(target)) return node;
    }
    return null;
  }

  Map<String, Object?> summaryJson() {
    return {
      'screen': screen,
      'routeGuess': routeGuess,
      'idle': idle,
      'devicePixelRatio': devicePixelRatio,
      'logicalSize': [logicalSize.width, logicalSize.height],
      'visibleText': visibleText,
      'hitTestableText': hitTestableText,
      'offscreenText': offscreenText,
      if (visualTree != null) 'visualTree': visualTree,
      if (controlGroups.isNotEmpty) 'controlGroups': controlGroups,
      if (suggestedActions.isNotEmpty) 'suggestedActions': suggestedActions,
      'fieldValues': {for (final field in fields) field.id: field.value},
      'fieldsById': {
        for (final field in fields)
          field.id: {
            'label': field.label,
            'value': field.value,
            if (field.validationMessage != null)
              'validationMessage': field.validationMessage,
            'baseId': field.baseId,
            'ordinal': field.ordinal,
          },
      },
    };
  }

  Map<String, Object?> toJson() {
    return {
      ...summaryJson(),
      'interactables': interactables
          .map((node) => node.toJson())
          .toList(growable: false),
      'fields': fields.map((node) => node.toJson()).toList(growable: false),
      'textTargets': textTargets
          .map((node) => node.toJson())
          .toList(growable: false),
      'scrollables': scrollables,
      'overlays': overlays,
      if (visualTree != null) 'visualTree': visualTree,
      if (controlGroups.isNotEmpty) 'controlGroups': controlGroups,
      if (suggestedActions.isNotEmpty) 'suggestedActions': suggestedActions,
      'keyboard': {'visible': false},
      'recentErrors': recentErrors,
    };
  }
}

class ScoutNode {
  const ScoutNode({
    required this.id,
    required this.baseId,
    required this.ordinal,
    required this.fallbackId,
    required this.kind,
    required this.label,
    required this.value,
    required this.validationMessage,
    required this.widgetType,
    required this.key,
    required this.rect,
    required this.visibleRect,
    required this.visibleFraction,
    required this.suggestedTapPoint,
    required this.hitTestable,
    required this.enabled,
    required this.confidence,
  });

  final String id;
  final String baseId;
  final int ordinal;
  final String fallbackId;
  final String kind;
  final String? label;
  final String? value;
  final String? validationMessage;
  final String widgetType;
  final String? key;
  final Rect? rect;
  final Rect? visibleRect;
  final double visibleFraction;
  final Offset? suggestedTapPoint;
  final bool hitTestable;
  final bool enabled;
  final double confidence;

  ScoutNode copyWith({
    String? id,
    String? baseId,
    int? ordinal,
    String? fallbackId,
    String? kind,
    String? label,
    String? value,
    String? validationMessage,
    double? confidence,
  }) {
    return ScoutNode(
      id: id ?? this.id,
      baseId: baseId ?? this.baseId,
      ordinal: ordinal ?? this.ordinal,
      fallbackId: fallbackId ?? this.fallbackId,
      kind: kind ?? this.kind,
      label: label ?? this.label,
      value: value ?? this.value,
      validationMessage: validationMessage ?? this.validationMessage,
      widgetType: widgetType,
      key: key,
      rect: rect,
      visibleRect: visibleRect,
      visibleFraction: visibleFraction,
      suggestedTapPoint: suggestedTapPoint,
      hitTestable: hitTestable,
      enabled: enabled,
      confidence: confidence ?? this.confidence,
    );
  }

  bool matches(String target) {
    final normalized = target.trim();
    if (id == normalized ||
        fallbackId == normalized ||
        key == normalized ||
        label == normalized) {
      return true;
    }
    final slug = _scoutSlug(normalized);
    final kindlessSlug = _scoutSlug(
      normalized.contains('.') ? normalized.split('.').last : normalized,
    );
    if (label != null &&
        RegExp(r'^\d$').hasMatch(label!.trim()) &&
        normalized == 'key.${label!.trim()}') {
      return true;
    }
    return id.endsWith('.$slug') || id.endsWith('.$kindlessSlug');
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'baseId': baseId,
      'ordinal': ordinal,
      'fallbackId': fallbackId,
      'kind': kind,
      'label': label,
      if (kind == 'field') 'value': value,
      if (kind == 'field' && validationMessage != null)
        'validationMessage': validationMessage,
      'widgetType': widgetType,
      'key': key,
      'rect': rect == null
          ? null
          : [rect!.left, rect!.top, rect!.width, rect!.height],
      'visibleRect': visibleRect == null
          ? null
          : [
              visibleRect!.left,
              visibleRect!.top,
              visibleRect!.width,
              visibleRect!.height,
            ],
      'visibleFraction': visibleFraction,
      'partiallyOffscreen': visibleFraction > 0 && visibleFraction < 1,
      'offscreen': visibleFraction == 0,
      'suggestedTapPoint': suggestedTapPoint == null
          ? null
          : [suggestedTapPoint!.dx, suggestedTapPoint!.dy],
      'hitTestable': hitTestable,
      'enabled': enabled,
      'confidence': confidence,
    };
  }
}

class ScoutAnnotation {
  ScoutAnnotation({
    required this.id,
    required this.createdAt,
    required this.comment,
    required this.status,
    required this.target,
  });

  final String id;
  final DateTime createdAt;
  final String comment;
  String status;
  final ScoutAnnotationTarget target;
  DateTime? updatedAt;
  String? note;

  /// PNG bytes of the annotated widget captured the moment the annotation was
  /// created (the "before" crop). Null until the in-app capture completes.
  Uint8List? beforeCropPng;

  /// Logical [left, top, width, height] used for the before crop, retained so
  /// the CLI can re-crop from a native screenshot when [beforeCropNeedsNative].
  List<double>? beforeCropRect;
  bool beforeCropNeedsNative = false;

  /// PNG bytes captured when the annotation is marked fixed (the "after" crop).
  Uint8List? afterCropPng;
  List<double>? afterCropRect;
  bool afterCropNeedsNative = false;

  bool get isActive =>
      status == 'open' ||
      status == 'stale_target' ||
      status == 'pending_review';

  Map<String, Object?> toJson({ScoutAnnotationTarget? liveTarget}) {
    final targetJson = target.toJson();
    final snapshotRect = target.rectJson;
    final liveRect = liveTarget?.rectJson;
    final geometryDelta = liveTarget == null
        ? null
        : <String, Object?>{
            'left': liveTarget.rect.left - target.rect.left,
            'top': liveTarget.rect.top - target.rect.top,
            'width': liveTarget.rect.width - target.rect.width,
            'height': liveTarget.rect.height - target.rect.height,
          };
    targetJson.addAll({
      'snapshotRect': snapshotRect,
      'liveMatched': liveTarget != null,
      if (liveTarget != null) ...{
        'liveRect': liveRect,
        'liveVisibleRect': liveTarget.visibleRectJson,
        'liveTarget': liveTarget.toJson(),
        'geometryChanged': !_sameRect(target.rect, liveTarget.rect),
        'geometryDelta': geometryDelta,
      },
    });
    return {
      'id': id,
      'createdAt': createdAt.toIso8601String(),
      if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
      'comment': comment,
      'status': status,
      if (note != null) 'note': note,
      'liveStatus': status == 'open' && liveTarget == null
          ? 'stale_target'
          : status,
      'hasBeforeCrop': beforeCropPng != null,
      'beforeCropNeedsNative': beforeCropNeedsNative,
      if (beforeCropRect != null) 'beforeCropRect': beforeCropRect,
      'hasAfterCrop': afterCropPng != null,
      'afterCropNeedsNative': afterCropNeedsNative,
      if (afterCropRect != null) 'afterCropRect': afterCropRect,
      'target': targetJson,
    };
  }

  bool _sameRect(Rect a, Rect b) {
    return a.left == b.left &&
        a.top == b.top &&
        a.width == b.width &&
        a.height == b.height;
  }
}

class ScoutAnnotationTarget {
  const ScoutAnnotationTarget({
    required this.id,
    required this.stableId,
    required this.kind,
    required this.widgetType,
    required this.key,
    required this.label,
    required this.text,
    required this.screen,
    required this.routeGuess,
    required this.rect,
    required this.visibleRect,
    required this.visibleFraction,
    required this.depth,
    required this.ancestorSummary,
    required this.scoutNodeId,
  });

  final String id;
  final String stableId;
  final String kind;
  final String widgetType;
  final String? key;
  final String? label;
  final String? text;
  final String screen;
  final String? routeGuess;
  final Rect rect;
  final Rect visibleRect;
  final double visibleFraction;
  final int depth;
  final List<String> ancestorSummary;
  final String? scoutNodeId;

  String get displayName {
    final value = label ?? text ?? key ?? widgetType;
    return '$kind.$value';
  }

  List<double> get rectJson => [rect.left, rect.top, rect.width, rect.height];

  List<double> get visibleRectJson => [
    visibleRect.left,
    visibleRect.top,
    visibleRect.width,
    visibleRect.height,
  ];

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'stableId': stableId,
      'kind': kind,
      'widgetType': widgetType,
      'key': key,
      'label': label,
      'text': text,
      'screen': screen,
      'routeGuess': routeGuess,
      'rect': rectJson,
      'visibleRect': visibleRectJson,
      'visibleFraction': visibleFraction,
      'depth': depth,
      'ancestorSummary': ancestorSummary,
      if (scoutNodeId != null) 'scoutNodeId': scoutNodeId,
    };
  }
}

class _CaptureResult {
  const _CaptureResult({
    required this.bytes,
    required this.width,
    required this.height,
    required this.pixelRatio,
    required this.bounds,
    required this.needsNative,
  }) : error = null;

  const _CaptureResult.failure(
    this.error, {
    this.needsNative = false,
    this.bounds,
  }) : bytes = null,
       width = 0,
       height = 0,
       pixelRatio = 1;

  final Uint8List? bytes;
  final int width;
  final int height;
  final double pixelRatio;
  final Rect? bounds;
  final bool needsNative;
  final String? error;
}

class _EditableCandidate {
  const _EditableCandidate({required this.node, required this.state});

  final ScoutNode node;
  final EditableTextState state;
}

class _TextTargetMatch {
  const _TextTargetMatch({required this.text, required this.actionable});

  final ScoutNode text;
  final ScoutNode? actionable;
}

class _CustomInputSurface {
  const _CustomInputSurface({
    required this.kind,
    required this.label,
    required this.currentValue,
    required this.keys,
    required this.commitAction,
    required this.targetMatched,
  });

  final String kind;
  final String? label;
  final String? currentValue;
  final Map<String, ScoutNode> keys;
  final ScoutNode? commitAction;
  final bool targetMatched;

  Map<String, Object?> toControlGroupJson() {
    final keyNodes = keys.values.toList(growable: false)
      ..sort((a, b) {
        final top = (a.rect?.top ?? 0).compareTo(b.rect?.top ?? 0);
        if (top != 0) return top;
        return (a.rect?.left ?? 0).compareTo(b.rect?.left ?? 0);
      });
    final allRects = [
      for (final node in [...keyNodes, ?commitAction])
        if (node.rect != null) node.rect!,
    ];
    final bounds = allRects.isEmpty
        ? null
        : allRects.reduce((value, element) => value.expandToInclude(element));
    return {
      'id': 'group.${kind.replaceAll('_', '.')}',
      'kind': 'controlGroup',
      'subtype': 'numeric_keypad',
      if (label != null && label!.isNotEmpty) 'label': label,
      'layout': 'grid',
      if (bounds != null)
        'rect': [bounds.left, bounds.top, bounds.width, bounds.height],
      if (currentValue != null && currentValue!.isNotEmpty)
        'currentValue': currentValue,
      'acceptedCharacters': 'digits',
      'targetMatched': targetMatched,
      'children': [
        for (final node in keyNodes)
          {
            'kind': 'button',
            'role': 'key',
            'label': node.label,
            'id': 'key.${node.label}',
            'targetId': node.id,
            'rect': node.rect == null
                ? null
                : [
                    node.rect!.left,
                    node.rect!.top,
                    node.rect!.width,
                    node.rect!.height,
                  ],
            if (node.suggestedTapPoint != null)
              'suggestedTapPoint': [
                node.suggestedTapPoint!.dx,
                node.suggestedTapPoint!.dy,
              ],
          },
      ],
      if (commitAction != null)
        'actions': [
          {
            'kind': 'button',
            'role': 'commit',
            'label': commitAction!.label,
            'id': commitAction!.id,
            'rect': commitAction!.rect == null
                ? null
                : [
                    commitAction!.rect!.left,
                    commitAction!.rect!.top,
                    commitAction!.rect!.width,
                    commitAction!.rect!.height,
                  ],
          },
        ],
      'suggestedAction': {
        'intent': 'enterValue',
        'method': 'tapSequence',
        'description':
            'Tap the key children matching the desired value, then tap the commit action if present.',
      },
    };
  }
}

class _ActionSnapshotResult {
  const _ActionSnapshotResult({
    required this.snapshot,
    required this.stable,
    this.lateChangeObserved = false,
    this.waitTimedOut = false,
  });

  final ScoutSnapshot snapshot;
  final bool stable;
  final bool lateChangeObserved;
  final bool waitTimedOut;
}

String _scoutSlug(String value) {
  final slug = value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_');
  return slug.replaceAll(RegExp(r'^_|_$'), '');
}
