part of 'flutter_scout_binding.dart';

// part: data models (snapshot, node, annotation, capture-result, and the
// small value types shared across the runtime).

class ScoutSnapshot {
  const ScoutSnapshot({
    required this.screen,
    this.screenEvidence = const <String, Object?>{
      'kind': 'heuristic_inference',
      'source': 'unspecified',
      'scoreKind': 'uncalibrated_heuristic',
    },
    required this.activeSurface,
    required this.routeGuess,
    required this.idle,
    required this.devicePixelRatio,
    required this.logicalSize,
    this.physicalSize = Size.zero,
    this.padding = EdgeInsets.zero,
    this.viewPadding = EdgeInsets.zero,
    this.viewInsets = EdgeInsets.zero,
    this.viewMetricsAvailable = false,
    required this.visibleText,
    required this.hitTestableText,
    required this.offscreenText,
    required this.interactables,
    required this.fields,
    required this.textTargets,
    required this.scrollables,
    this.perceptionGaps = const <Map<String, Object?>>[],
    this.captureBackend = const <String, Object?>{
      'status': 'observation_unavailable',
      'reason': 'capture_backend_not_probed',
    },
    required this.overlays,
    required this.visualTree,
    required this.controlGroups,
    required this.structuredRows,
    required this.suggestedActions,
    required this.recentErrors,
    this.stateGeneration = 0,
    this.stateDigest = '',
    this.degradedNodes = 0,
  });

  final String screen;
  final Map<String, Object?> screenEvidence;
  final Map<String, Object?>? activeSurface;
  final String? routeGuess;
  final bool idle;
  final double devicePixelRatio;
  final Size logicalSize;
  final Size physicalSize;
  final EdgeInsets padding;
  final EdgeInsets viewPadding;
  final EdgeInsets viewInsets;
  final bool viewMetricsAvailable;
  final List<String> visibleText;
  final List<String> hitTestableText;
  final List<String> offscreenText;
  final List<ScoutNode> interactables;
  final List<ScoutNode> fields;
  final List<ScoutNode> textTargets;
  final List<Map<String, Object?>> scrollables;

  /// Visible regions whose pixels or semantics are not fully represented by
  /// the widget-tree observation. These are factual limitations, not guesses
  /// about what the region contains.
  final List<Map<String, Object?>> perceptionGaps;

  /// Availability and coverage of the in-app raster capture backend at the
  /// time of this snapshot. Native host capture is selected by the CLI and
  /// therefore cannot be claimed available by the helper.
  final Map<String, Object?> captureBackend;

  final List<Map<String, Object?>> overlays;
  final Map<String, Object?>? visualTree;
  final List<Map<String, Object?>> controlGroups;
  final List<Map<String, Object?>> structuredRows;
  final List<Map<String, Object?>> suggestedActions;
  final List<Map<String, Object?>> recentErrors;
  final int stateGeneration;
  final String stateDigest;

  /// Elements the snapshot walk skipped because collecting them threw. One
  /// misbehaving widget must degrade only itself, never the whole inspect.
  final int degradedNodes;

  ScoutSnapshot copyWith({
    List<ScoutNode>? interactables,
    List<ScoutNode>? fields,
    List<ScoutNode>? textTargets,
    List<Map<String, Object?>>? scrollables,
    List<Map<String, Object?>>? overlays,
    Map<String, Object?>? visualTree,
    List<Map<String, Object?>>? controlGroups,
    List<Map<String, Object?>>? structuredRows,
    List<Map<String, Object?>>? suggestedActions,
    List<Map<String, Object?>>? perceptionGaps,
    Map<String, Object?>? captureBackend,
    int? stateGeneration,
    String? stateDigest,
  }) {
    return ScoutSnapshot(
      screen: screen,
      screenEvidence: screenEvidence,
      activeSurface: activeSurface,
      routeGuess: routeGuess,
      idle: idle,
      devicePixelRatio: devicePixelRatio,
      logicalSize: logicalSize,
      physicalSize: physicalSize,
      padding: padding,
      viewPadding: viewPadding,
      viewInsets: viewInsets,
      viewMetricsAvailable: viewMetricsAvailable,
      visibleText: visibleText,
      hitTestableText: hitTestableText,
      offscreenText: offscreenText,
      interactables: interactables ?? this.interactables,
      fields: fields ?? this.fields,
      textTargets: textTargets ?? this.textTargets,
      scrollables: scrollables ?? this.scrollables,
      perceptionGaps: perceptionGaps ?? this.perceptionGaps,
      captureBackend: captureBackend ?? this.captureBackend,
      overlays: overlays ?? this.overlays,
      visualTree: visualTree ?? this.visualTree,
      controlGroups: controlGroups ?? this.controlGroups,
      structuredRows: structuredRows ?? this.structuredRows,
      suggestedActions: suggestedActions ?? this.suggestedActions,
      recentErrors: recentErrors,
      stateGeneration: stateGeneration ?? this.stateGeneration,
      stateDigest: stateDigest ?? this.stateDigest,
      degradedNodes: degradedNodes,
    );
  }

  /// Short identity for the CURRENT VIEW, independent of route names: the
  /// most prominent visible texts by painted area. Two states on the same
  /// route (an Operation/Admin flip, a swapped tab body) get different
  /// signatures, so agents can assert "the view changed" without diffing
  /// full text lists — `screen` alone often cannot tell them apart.
  String get viewSignature {
    final prominent =
        [
          for (final node in textTargets)
            if (node.visibleFraction > 0 &&
                node.rect != null &&
                (node.label ?? '').trim().isNotEmpty)
              node,
        ]..sort((a, b) {
          final area = (b.rect!.width * b.rect!.height).compareTo(
            a.rect!.width * a.rect!.height,
          );
          if (area != 0) return area;
          return a.label!.compareTo(b.label!);
        });
    return prominent.take(5).map((node) => node.label!.trim()).join(' | ');
  }

  /// Stable FNV-1a hash of the sorted visible-text set: equal hashes mean
  /// the same texts are on screen, a cheap same-view/different-view check.
  String get visibleTextHash {
    final sorted = [...visibleText]..sort();
    var hash = 0x811c9dc5;
    void mix(int unit) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }

    for (final value in sorted) {
      value.codeUnits.forEach(mix);
      mix(0x1F);
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// Authoritative identity for one observation. The generation prevents a
  /// state that changed away and later returned from masquerading as the old
  /// observation; the SHA-256 digest guards the canonical redacted contents.
  String get snapshotId => 'g$stateGeneration:$stateDigest';

  ScoutNode? findNode(String target) {
    final normalized = target.trim();
    final nodes = [...interactables, ...fields, ...textTargets];
    if (normalized.startsWith('row.')) {
      final rowTarget = _rowHandleTarget(normalized);
      if (rowTarget != null && rowTarget != normalized) {
        final rowNode = _findBestNode(nodes, rowTarget);
        if (rowNode != null) return rowNode;
      }
    }
    final directNode = _findBestNode(nodes, normalized);
    if (directNode != null) return directNode;
    final rowTarget = _rowHandleTarget(target);
    if (rowTarget != null && rowTarget != target) {
      return _findBestNode(nodes, rowTarget);
    }
    return null;
  }

  /// Strong selectors must win globally before aliases or fuzzy suffixes are
  /// considered, even when the exact node appears later in tree order.
  ScoutNode? _findBestNode(List<ScoutNode> nodes, String target) {
    final normalized = target.trim();
    for (final node in nodes) {
      if (node.id == normalized) return node;
    }
    for (final node in nodes) {
      if (node.fallbackId == normalized) return node;
    }
    for (final node in nodes) {
      if (node.key == normalized) return node;
    }
    for (final node in nodes) {
      if (node.matches(normalized)) return node;
    }
    return null;
  }

  String? _rowHandleTarget(String target) {
    final normalized = target.trim();
    if (normalized.isEmpty) return null;
    for (final row in structuredRows) {
      final handles = row['handles'];
      if (handles is! Map) continue;
      final exact = handles[normalized];
      if (exact is String && exact.isNotEmpty) return exact;
      final slug = _scoutSlug(normalized);
      for (final entry in handles.entries) {
        final key = entry.key?.toString();
        final value = entry.value;
        if (key == null || value is! String || value.isEmpty) continue;
        if (key.endsWith('.$slug') || _scoutSlug(key) == slug) return value;
      }
    }
    return null;
  }

  ScoutNode? findField(String target) {
    return _findBestNode(fields, target);
  }

  Map<String, Object?> summaryJson() {
    return {
      'screen': screen,
      'screenEvidence': screenEvidence,
      if (activeSurface != null) 'activeSurface': activeSurface,
      'routeGuess': routeGuess,
      'viewSignature': viewSignature,
      'stateGeneration': stateGeneration,
      'stateDigest': stateDigest,
      'snapshotId': snapshotId,
      'visibleTextHash': visibleTextHash,
      'idle': idle,
      'devicePixelRatio': devicePixelRatio,
      'logicalSize': [logicalSize.width, logicalSize.height],
      'viewport': viewportJson(),
      'perception': perceptionJson(),
      'visibleText': visibleText,
      'hitTestableText': hitTestableText,
      'offscreenText': offscreenText,
      if (visualTree != null) 'visualTree': visualTree,
      if (controlGroups.isNotEmpty) 'controlGroups': controlGroups,
      if (structuredRows.isNotEmpty) 'structuredRows': structuredRows,
      if (suggestedActions.isNotEmpty) 'suggestedActions': suggestedActions,
      if (scrollables.isNotEmpty) 'scrollables': scrollables,
      if (degradedNodes > 0) 'degradedNodes': degradedNodes,
      'fieldValues': {
        for (final field in fields) field.id: field.serializedValue,
      },
      'fieldsById': {
        for (final field in fields)
          field.id: {
            'label': field.label,
            ...field.serializedFieldState,
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
      'overlays': overlays,
      if (visualTree != null) 'visualTree': visualTree,
      if (controlGroups.isNotEmpty) 'controlGroups': controlGroups,
      if (structuredRows.isNotEmpty) 'structuredRows': structuredRows,
      if (suggestedActions.isNotEmpty) 'suggestedActions': suggestedActions,
      'keyboard': {
        'visible': viewMetricsAvailable && viewInsets.bottom > 0.5,
        'logicalInsetBottom': viewMetricsAvailable ? viewInsets.bottom : null,
        'source': viewMetricsAvailable
            ? 'flutter_view_metrics'
            : 'observation_unavailable',
      },
      'recentErrors': recentErrors,
    };
  }

  Map<String, Object?> perceptionJson() {
    final hasUnavailableCapture = captureBackend['status'] != 'available';
    return {
      'observationKind': 'widget_tree_and_render_geometry',
      'pixelEvidence': 'not_included_in_inspect',
      'text': {
        'status': 'observed',
        'source': 'flutter_widget_tree',
        'visibleCount': visibleText.length,
        'hitTestableCount': hitTestableText.length,
        'offscreenCount': offscreenText.length,
      },
      'semantics': {
        'status': 'partially_observed',
        'source': 'widget_properties_and_semantics',
        'usedForLabels': true,
        'limitation':
            'Malformed, absent, or custom-painted semantics can leave an affected region undescribed.',
      },
      'geometry': {
        'status': viewMetricsAvailable ? 'observed' : 'partially_observed',
        'source': 'render_box_bounds',
        'devicePixelRatio': devicePixelRatio,
        'logicalSize': [logicalSize.width, logicalSize.height],
        'physicalSize': viewMetricsAvailable
            ? [physicalSize.width, physicalSize.height]
            : null,
        'viewMetricsAvailable': viewMetricsAvailable,
      },
      'visual': {
        'screenshotInPayload': false,
        'ocrInPayload': false,
        'status': perceptionGaps.isEmpty
            ? 'pixels_not_observed'
            : 'known_perception_gaps',
        'gapCount': perceptionGaps.length,
        'fallback':
            'Use `flutter-scout screenshot` or `flutter-scout crop <target>` when pixel-level visual confirmation is needed.',
      },
      'captureBackend': captureBackend,
      if (perceptionGaps.isNotEmpty) 'limitations': perceptionGaps,
      if (degradedNodes > 0) 'degradedElementCount': degradedNodes,
      'coverage': <String, Object?>{
        'widgetTree': degradedNodes == 0
            ? 'observed'
            : 'observed_with_local_degradation',
        'renderGeometry': viewMetricsAvailable
            ? 'observed'
            : 'observation_unavailable',
        'pixels': 'not_observed_in_this_snapshot',
        'focusedPixelCapture': hasUnavailableCapture
            ? 'observation_unavailable'
            : 'available_for_flutter_layers',
      },
    };
  }

  Map<String, Object?> viewportJson() {
    List<double> insets(EdgeInsets value) => <double>[
      value.left,
      value.top,
      value.right,
      value.bottom,
    ];

    return <String, Object?>{
      'available': viewMetricsAvailable,
      'orientation': logicalSize.width > logicalSize.height
          ? 'landscape'
          : logicalSize.height > logicalSize.width
          ? 'portrait'
          : 'square',
      'logicalSize': <double>[logicalSize.width, logicalSize.height],
      'physicalSize': viewMetricsAvailable
          ? <double>[physicalSize.width, physicalSize.height]
          : null,
      'devicePixelRatio': devicePixelRatio,
      'logicalToPhysicalScale': viewMetricsAvailable ? devicePixelRatio : null,
      'physicalToLogicalScale': viewMetricsAvailable && devicePixelRatio > 0
          ? 1 / devicePixelRatio
          : null,
      'padding': viewMetricsAvailable ? insets(padding) : null,
      'viewPadding': viewMetricsAvailable ? insets(viewPadding) : null,
      'viewInsets': viewMetricsAvailable ? insets(viewInsets) : null,
      'safeArea': viewMetricsAvailable
          ? <String, Object?>{
              'left': padding.left,
              'top': padding.top,
              'right': padding.right,
              'bottom': padding.bottom,
            }
          : null,
      'coordinateConvention': <String, Object?>{
        'logical': 'origin_top_left_logical_points',
        'physical': 'origin_top_left_physical_pixels',
      },
      'windowScaling': <String, Object?>{
        'status': viewMetricsAvailable ? 'observed' : 'observation_unavailable',
        'source': viewMetricsAvailable
            ? 'flutter_view_device_pixel_ratio'
            : 'flutter_view_unavailable',
        'logicalToPhysical': viewMetricsAvailable ? devicePixelRatio : null,
      },
      if (!viewMetricsAvailable)
        'unavailableReason': 'flutter_view_metrics_not_captured',
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
    required String? value,
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
    this.coordinateDevicePixelRatio,
    this.selected,
    this.altIds = const [],
    this.textColor,
    this.enclosingTarget,
    this.obscured = false,
    this.redacted = false,
    this.isEmpty,
    Object? valueToken,
    RenderObject? renderObject,
    EditableTextState? editableState,
    int? treeOrdinal,
  }) : value = redacted ? null : value,
       // Public parameter names avoid exposing private implementation details.
       // ignore: prefer_initializing_formals
       _valueToken = valueToken,
       // ignore: prefer_initializing_formals
       _renderObject = renderObject,
       // ignore: prefer_initializing_formals
       _editableState = editableState,
       // ignore: prefer_initializing_formals
       _treeOrdinal = treeOrdinal;

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
  final double? coordinateDevicePixelRatio;

  /// Selection/toggle state (tab selected, switch on, checkbox checked) when
  /// determinable from the widget or its semantics; null when unknown. Lets
  /// agents tell "tap did nothing" from "already on that tab".
  final bool? selected;

  /// Effective ARGB color of the node's first text descendant, captured for
  /// segment-selection inference (see _inferSegmentSelection). Internal —
  /// not serialized.
  final int? textColor;

  /// Handle of the smallest OTHER interactable that fully encloses this one.
  /// A small keyed handle (an avatar inside a whole tappable row) may do
  /// nothing on its own; the enclosing handle is the reliable fallback.
  final String? enclosingTarget;

  /// Alternate handles derived from other label sources (icon glyph name,
  /// accessibility label, contained text). The primary id can drift between
  /// snapshots when a volatile source (async-loaded semantics) appears or
  /// disappears; altIds keep yesterday's handle resolving today, which
  /// protects replays and cross-snapshot references.
  final List<String> altIds;

  /// Whether this field's editable is `obscureText: true` (password-style).
  /// Kept separately from [redacted] so diagnostics can distinguish an explicit
  /// Flutter obscuring contract from a password/PIN/token heuristic.
  final bool obscured;

  /// Whether this field's value is sensitive. [value] is always null when this
  /// is true; callers get only [isEmpty]/[hasValue] and never plaintext/length.
  final bool redacted;

  /// Safe presence metadata for fields. Null for non-field nodes.
  final bool? isEmpty;
  bool? get hasValue => isEmpty == null ? null : !isEmpty!;

  /// Process-local comparison token. It lets deltas and recording detect a
  /// non-empty secret changing to another non-empty secret without retaining or
  /// serializing the plaintext. The per-runtime salt never leaves the helper.
  final Object? _valueToken;

  /// Runtime-only references used to prove that a freshly resolved point still
  /// hits this exact control immediately before dispatch. They never serialize.
  final RenderObject? _renderObject;
  final EditableTextState? _editableState;

  /// Original widget-walk position. Unlike [ordinal], which disambiguates equal
  /// handles, this is global and can prove modal-surface ownership.
  final int? _treeOrdinal;

  Object? get serializedValue => redacted
      ? <String, Object?>{
          'redacted': true,
          'isEmpty': isEmpty ?? true,
          'hasValue': hasValue ?? false,
        }
      : value;

  Map<String, Object?> get serializedFieldState => redacted
      ? <String, Object?>{
          'redacted': true,
          'isEmpty': isEmpty ?? true,
          'hasValue': hasValue ?? false,
        }
      : <String, Object?>{'value': value};

  bool hasSameFieldValue(ScoutNode other) {
    if (redacted || other.redacted) {
      return redacted == other.redacted &&
          isEmpty == other.isEmpty &&
          _valueToken == other._valueToken;
    }
    return value == other.value;
  }

  bool matchesFieldValue(String expected, Object expectedToken) {
    return redacted ? _valueToken == expectedToken : (value ?? '') == expected;
  }

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
    int? treeOrdinal,
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
      coordinateDevicePixelRatio: coordinateDevicePixelRatio,
      selected: selected,
      altIds: altIds,
      textColor: textColor,
      enclosingTarget: enclosingTarget,
      obscured: obscured,
      redacted: redacted,
      isEmpty: isEmpty,
      valueToken: _valueToken,
      renderObject: _renderObject,
      editableState: _editableState,
      treeOrdinal: treeOrdinal ?? _treeOrdinal,
    );
  }

  /// Copy with an explicit selection value (inference result). copyWith
  /// cannot express "set to null vs keep", so this is a dedicated setter-copy.
  ScoutNode withSelected(bool? value) {
    return ScoutNode(
      id: id,
      baseId: baseId,
      ordinal: ordinal,
      fallbackId: fallbackId,
      kind: kind,
      label: label,
      value: this.value,
      validationMessage: validationMessage,
      widgetType: widgetType,
      key: key,
      rect: rect,
      visibleRect: visibleRect,
      visibleFraction: visibleFraction,
      suggestedTapPoint: suggestedTapPoint,
      hitTestable: hitTestable,
      enabled: enabled,
      confidence: confidence,
      coordinateDevicePixelRatio: coordinateDevicePixelRatio,
      selected: value,
      altIds: altIds,
      textColor: textColor,
      enclosingTarget: enclosingTarget,
      obscured: obscured,
      redacted: redacted,
      isEmpty: isEmpty,
      valueToken: _valueToken,
      renderObject: _renderObject,
      editableState: _editableState,
      treeOrdinal: _treeOrdinal,
    );
  }

  /// Copy that intentionally removes a misleading inferred label.
  ScoutNode withoutLabel({double? confidence}) {
    return ScoutNode(
      id: id,
      baseId: baseId,
      ordinal: ordinal,
      fallbackId: fallbackId,
      kind: kind,
      label: null,
      value: value,
      validationMessage: validationMessage,
      widgetType: widgetType,
      key: key,
      rect: rect,
      visibleRect: visibleRect,
      visibleFraction: visibleFraction,
      suggestedTapPoint: suggestedTapPoint,
      hitTestable: hitTestable,
      enabled: enabled,
      confidence: confidence ?? this.confidence,
      coordinateDevicePixelRatio: coordinateDevicePixelRatio,
      selected: selected,
      altIds: altIds,
      textColor: textColor,
      enclosingTarget: enclosingTarget,
      obscured: obscured,
      redacted: redacted,
      isEmpty: isEmpty,
      valueToken: _valueToken,
      renderObject: _renderObject,
      editableState: _editableState,
      treeOrdinal: _treeOrdinal,
    );
  }

  /// Copy carrying an [enclosingTarget] handle.
  ScoutNode withEnclosingTarget(String? target) {
    return ScoutNode(
      id: id,
      baseId: baseId,
      ordinal: ordinal,
      fallbackId: fallbackId,
      kind: kind,
      label: label,
      value: value,
      validationMessage: validationMessage,
      widgetType: widgetType,
      key: key,
      rect: rect,
      visibleRect: visibleRect,
      visibleFraction: visibleFraction,
      suggestedTapPoint: suggestedTapPoint,
      hitTestable: hitTestable,
      enabled: enabled,
      confidence: confidence,
      coordinateDevicePixelRatio: coordinateDevicePixelRatio,
      selected: selected,
      altIds: altIds,
      textColor: textColor,
      enclosingTarget: target,
      obscured: obscured,
      redacted: redacted,
      isEmpty: isEmpty,
      valueToken: _valueToken,
      renderObject: _renderObject,
      editableState: _editableState,
      treeOrdinal: _treeOrdinal,
    );
  }

  /// Adds stable intent aliases without replacing the primary raw handle.
  /// Agents can use the readable alias while replay remains compatible with
  /// the icon/key-derived primary id.
  ScoutNode withAltIds(Iterable<String> aliases) {
    final merged = <String>{...altIds, ...aliases}
      ..remove(id)
      ..remove(baseId);
    return ScoutNode(
      id: id,
      baseId: baseId,
      ordinal: ordinal,
      fallbackId: fallbackId,
      kind: kind,
      label: label,
      value: value,
      validationMessage: validationMessage,
      widgetType: widgetType,
      key: key,
      rect: rect,
      visibleRect: visibleRect,
      visibleFraction: visibleFraction,
      suggestedTapPoint: suggestedTapPoint,
      hitTestable: hitTestable,
      enabled: enabled,
      confidence: confidence,
      coordinateDevicePixelRatio: coordinateDevicePixelRatio,
      selected: selected,
      altIds: merged.toList(growable: false),
      textColor: textColor,
      enclosingTarget: enclosingTarget,
      obscured: obscured,
      redacted: redacted,
      isEmpty: isEmpty,
      valueToken: _valueToken,
      renderObject: _renderObject,
      editableState: _editableState,
      treeOrdinal: _treeOrdinal,
    );
  }

  bool matches(String target) {
    final normalized = target.trim();
    if (id == normalized ||
        fallbackId == normalized ||
        key == normalized ||
        label == normalized ||
        altIds.contains(normalized)) {
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
    if (id.endsWith('.$slug') || id.endsWith('.$kindlessSlug')) return true;
    return altIds.any(
      (alt) => alt.endsWith('.$slug') || alt.endsWith('.$kindlessSlug'),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'baseId': baseId,
      'ordinal': ordinal,
      'fallbackId': fallbackId,
      'kind': kind,
      'label': label,
      if (kind == 'field') ...serializedFieldState,
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
      'physicalRect': rect == null || coordinateDevicePixelRatio == null
          ? null
          : [
              rect!.left * coordinateDevicePixelRatio!,
              rect!.top * coordinateDevicePixelRatio!,
              rect!.width * coordinateDevicePixelRatio!,
              rect!.height * coordinateDevicePixelRatio!,
            ],
      'physicalSuggestedTapPoint':
          suggestedTapPoint == null || coordinateDevicePixelRatio == null
          ? null
          : [
              suggestedTapPoint!.dx * coordinateDevicePixelRatio!,
              suggestedTapPoint!.dy * coordinateDevicePixelRatio!,
            ],
      'geometryCoordinateSpaces': coordinateDevicePixelRatio == null
          ? const <String, Object?>{
              'logical': 'available',
              'physical': 'unavailable',
              'reason': 'view_metrics_not_captured',
            }
          : <String, Object?>{
              'logical': 'logical_flutter_points',
              'physical': 'physical_pixels',
              'devicePixelRatio': coordinateDevicePixelRatio,
            },
      'hitTestable': hitTestable,
      'enabled': enabled,
      'heuristicScore': confidence,
      'scoreKind': 'uncalibrated_heuristic',
      'heuristicMeaning': 'target_label_and_handle_quality',
      if (selected != null) 'selected': selected,
      if (altIds.isNotEmpty) 'altIds': altIds,
      if (enclosingTarget != null) 'enclosingTarget': enclosingTarget,
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
      'currentValue': <String, Object?>{
        'redacted': true,
        'isEmpty': currentValue == null || currentValue!.isEmpty,
        'hasValue': currentValue != null && currentValue!.isNotEmpty,
      },
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

enum _StabilityState {
  stable('stable'),
  transient('transient'),
  continuousAnimation('continuous_animation'),
  neverSettling('never_settling'),
  runtimeLost('runtime_lost'),
  observationUnavailable('observation_unavailable');

  const _StabilityState(this.wireName);

  final String wireName;
}

/// A bounded, agent-relevant observation of UI quiescence.
///
/// This is deliberately richer than SchedulerBinding's `hasScheduledFrame`.
/// A spinner can schedule frames forever while the actionable widget tree is
/// unchanged; conversely, an async load can change semantics without a frame
/// being scheduled at the exact instant Scout samples it.
class _StabilityObservation {
  const _StabilityObservation({
    required this.state,
    required this.actionable,
    required this.stoppingReason,
    required this.elapsedMs,
    required this.budgetMs,
    required this.deadlineEpochMs,
    required this.sampleCount,
    required this.semanticChangeCount,
    required this.distinctSemanticStates,
    required this.quietWindowMs,
    required this.quietForMs,
    required this.scheduledFrameSamples,
    required this.transientCallbackSamples,
    required this.maxTransientCallbacks,
    required this.disabledFrameSamples,
    required this.lastHasScheduledFrame,
    required this.lastTransientCallbackCount,
    required this.lastSchedulerPhase,
    required this.initialStateGeneration,
    required this.initialStateDigest,
    required this.initialSnapshotId,
    required this.finalStateGeneration,
    required this.finalStateDigest,
    required this.finalSnapshotId,
    this.expectationMet = false,
    this.boundedByRequestDeadline = false,
    this.limitations = const <String>[],
  });

  final _StabilityState state;
  final bool actionable;
  final String stoppingReason;
  final int elapsedMs;
  final int budgetMs;
  final int deadlineEpochMs;
  final int sampleCount;
  final int semanticChangeCount;
  final int distinctSemanticStates;
  final int quietWindowMs;
  final int quietForMs;
  final int scheduledFrameSamples;
  final int transientCallbackSamples;
  final int maxTransientCallbacks;
  final int disabledFrameSamples;
  final bool? lastHasScheduledFrame;
  final int? lastTransientCallbackCount;
  final String? lastSchedulerPhase;
  final int? initialStateGeneration;
  final String? initialStateDigest;
  final String? initialSnapshotId;
  final int? finalStateGeneration;
  final String? finalStateDigest;
  final String? finalSnapshotId;
  final bool expectationMet;
  final bool boundedByRequestDeadline;
  final List<String> limitations;

  bool get stable => switch (state) {
    _StabilityState.stable => true,
    _StabilityState.transient ||
    _StabilityState.continuousAnimation ||
    _StabilityState.neverSettling ||
    _StabilityState.runtimeLost ||
    _StabilityState.observationUnavailable => false,
  };

  bool get exhausted =>
      stoppingReason.startsWith('budget_exhausted') ||
      stoppingReason == 'request_deadline_reached';

  Map<String, Object?> toJson() => <String, Object?>{
    'state': state.wireName,
    'actionable': actionable,
    'stoppingReason': stoppingReason,
    'elapsedMs': elapsedMs,
    'budgetMs': budgetMs,
    'deadlineEpochMs': deadlineEpochMs,
    'bounded': true,
    if (boundedByRequestDeadline) 'boundedByRequestDeadline': true,
    if (expectationMet) 'expectationMet': true,
    'samples': <String, Object?>{
      'count': sampleCount,
      'semanticChangeCount': semanticChangeCount,
      'distinctSemanticStates': distinctSemanticStates,
      'quietWindowMs': quietWindowMs,
      'quietForMs': quietForMs,
    },
    'frames': <String, Object?>{
      'scheduledFrameSamples': scheduledFrameSamples,
      'transientCallbackSamples': transientCallbackSamples,
      'maxTransientCallbacks': maxTransientCallbacks,
      'disabledFrameSamples': disabledFrameSamples,
      'lastHasScheduledFrame': lastHasScheduledFrame,
      'lastTransientCallbackCount': lastTransientCallbackCount,
      'lastSchedulerPhase': lastSchedulerPhase,
    },
    'initial': <String, Object?>{
      'stateGeneration': initialStateGeneration,
      'stateDigest': initialStateDigest,
      'snapshotId': initialSnapshotId,
    },
    'final': <String, Object?>{
      'stateGeneration': finalStateGeneration,
      'stateDigest': finalStateDigest,
      'snapshotId': finalSnapshotId,
    },
    'limitations': limitations,
  };
}

class _ConditionWaitOutcome {
  const _ConditionWaitOutcome({
    required this.met,
    required this.blocked,
    required this.waitedMs,
    required this.budgetMs,
    required this.deadlineEpochMs,
    required this.polls,
    required this.visibleText,
    required this.initialSnapshot,
    required this.finalSnapshot,
    required this.semanticChangeCount,
    required this.distinctSemanticStates,
    required this.quietForMs,
    required this.scheduledFrameSamples,
    required this.transientCallbackSamples,
    required this.maxTransientCallbacks,
    required this.disabledFrameSamples,
    required this.lastHasScheduledFrame,
    required this.lastTransientCallbackCount,
    required this.lastSchedulerPhase,
  });

  final bool met;
  final bool blocked;
  final int waitedMs;
  final int budgetMs;
  final int deadlineEpochMs;
  final int polls;
  final List<String> visibleText;
  final ScoutSnapshot initialSnapshot;
  final ScoutSnapshot finalSnapshot;
  final int semanticChangeCount;
  final int distinctSemanticStates;
  final int quietForMs;
  final int scheduledFrameSamples;
  final int transientCallbackSamples;
  final int maxTransientCallbacks;
  final int disabledFrameSamples;
  final bool lastHasScheduledFrame;
  final int lastTransientCallbackCount;
  final String lastSchedulerPhase;
}

class _ActionSnapshotResult {
  const _ActionSnapshotResult({
    required this.snapshot,
    required this.stability,
    this.lateChangeObserved = false,
    this.activityObserved = false,
    this.transientViewSignatures = const [],
    this.waitTimedOut = false,
  });

  final ScoutSnapshot snapshot;
  final _StabilityObservation stability;
  final bool lateChangeObserved;
  final bool activityObserved;
  final List<String> transientViewSignatures;
  final bool waitTimedOut;

  bool get stable => stability.stable;
}

String _scoutSlug(String value) {
  final slug = value
      .toLowerCase()
      // Preserve localized labels/keys, including decomposed letter marks.
      // ASCII handles remain unchanged; unrelated CJK labels no longer
      // collapse to the same empty slug.
      .replaceAll(RegExp(r'[^\p{L}\p{N}\p{M}]+', unicode: true), '_')
      .replaceAll(RegExp(r'_+'), '_');
  return slug.replaceAll(RegExp(r'^_|_$'), '');
}
