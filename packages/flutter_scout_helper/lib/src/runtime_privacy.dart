part of 'flutter_scout_binding.dart';

// part: source-level field privacy classification, secret tracking, and the
// final recursive output scrub used by every service-extension response.

const String _kScoutRedacted = '[REDACTED]';

final RegExp _kSensitiveFieldWordPattern = RegExp(
  r'(^|[^a-z0-9])(password|passcode|passphrase|pwd|secret|pin|cvv|cvc|otp|token|cookie|session[ _-]?id|api[ _-]?key|security[ _-]?code|card[ _-]?number|account[ _-]?number|one[ _-]?time[ _-]?code)($|[^a-z0-9])',
  caseSensitive: false,
);

const Set<String> _kSensitiveFieldFragments = {
  'password',
  'newpassword',
  'currentpassword',
  'passcode',
  'passphrase',
  'onetimecode',
  'verificationcode',
  'securitycode',
  'creditcard',
  'cardnumber',
  'cardsecuritycode',
  'bankaccount',
  'sessionid',
  'accesstoken',
  'refreshtoken',
  'authtoken',
  'apikey',
};

extension _RuntimePrivacy on FlutterScoutRuntime {
  bool _shouldRedactField({
    required Element element,
    required EditableTextState? editable,
    String? label,
    String? key,
  }) {
    if (editable == null) return _sensitiveDescriptor('$label $key');
    if (editable.widget.obscureText) return true;
    if (editable.widget.keyboardType == TextInputType.visiblePassword) {
      return true;
    }

    final descriptors = <String>[
      label ?? '',
      key ?? '',
      editable.widget.autofillHints?.join(' ') ?? '',
    ];
    void addWidgetMetadata(Widget widget) {
      descriptors.add(_keyLabel(widget.key) ?? '');
      if (widget is TextField) {
        descriptors
          ..add(widget.decoration?.labelText ?? '')
          ..add(widget.decoration?.hintText ?? '')
          ..add(widget.decoration?.helperText ?? '');
      } else if (widget is Semantics) {
        descriptors.add(widget.properties.label ?? '');
      }
    }

    addWidgetMetadata(editable.widget);
    if (!identical(element, editable.context)) {
      addWidgetMetadata(element.widget);
    }
    editable.context.visitAncestorElements((ancestor) {
      addWidgetMetadata(ancestor.widget);
      return true;
    });
    return descriptors.any(_sensitiveDescriptor);
  }

  bool _sensitiveDescriptor(String descriptor) {
    final trimmed = descriptor.trim();
    if (trimmed.isEmpty) return false;
    if (_kSensitiveFieldWordPattern.hasMatch(trimmed)) return true;
    final compact = trimmed.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return _kSensitiveFieldFragments.any(compact.contains);
  }

  bool _isSensitiveEditableState(EditableTextState state) {
    final context = state.context;
    return _shouldRedactField(
      element: context as Element,
      editable: state,
      key: _keyLabel(state.widget.key),
    );
  }

  /// True only for descendants rendered by a sensitive EditableText. This
  /// removes mask glyph runs from text/annotation output because their count
  /// reveals the secret length even when plaintext is hidden.
  bool _isInsideSensitiveEditable(Element element) {
    bool sensitive(Element candidate) {
      return candidate is StatefulElement &&
          candidate.state is EditableTextState &&
          _isSensitiveEditableState(candidate.state as EditableTextState);
    }

    if (sensitive(element)) return true;
    var result = false;
    element.visitAncestorElements((ancestor) {
      if (sensitive(ancestor)) {
        result = true;
        return false;
      }
      return true;
    });
    return result;
  }

  Object _fieldValueToken(String value) =>
      Object.hash(_sensitiveValueSalt, value);

  void _rememberSensitiveValue(String? value) {
    if (value == null ||
        value.isEmpty ||
        _knownSensitiveValues.contains(value)) {
      return;
    }
    _knownSensitiveValues.add(value);
  }

  /// Error hooks can fire before the next inspect. Read only EditableText
  /// controllers that independently classify as sensitive so their current
  /// values are available to the error scrub immediately.
  void _rememberSensitiveValuesFromTree() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return;
    var budget = 10000;
    void visit(Element element) {
      if (budget-- <= 0 || _isScoutOverlayWidget(element.widget)) return;
      try {
        if (element is StatefulElement && element.state is EditableTextState) {
          final state = element.state as EditableTextState;
          if (_isSensitiveEditableState(state)) {
            _rememberSensitiveValue(state.widget.controller.text);
          }
        }
      } catch (_) {
        // Privacy collection is best-effort per element; the final source model
        // still redacts every sensitive field it can inspect successfully.
      }
      element.visitChildElements(visit);
    }

    visit(root);
  }

  String _redactSensitiveText(
    String value, {
    String replacement = _kScoutRedacted,
  }) {
    if (value.isEmpty || _knownSensitiveValues.isEmpty) return value;
    var redacted = value;
    final secrets = [..._knownSensitiveValues]
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final secret in secrets) {
      if (secret.isEmpty || !redacted.contains(secret)) continue;
      if (redacted == secret) return replacement;
      final shortAlphaNumeric =
          secret.length <= 3 && RegExp(r'^[A-Za-z0-9]+$').hasMatch(secret);
      if (!shortAlphaNumeric) {
        redacted = redacted.replaceAll(secret, replacement);
        continue;
      }
      // A one-character PIN such as `1` must be removed from `PIN=1`, but must
      // not rewrite every `1` inside runtime ids, fallback handles, timestamps,
      // or unrelated words. Treat short alphanumeric secrets as whole tokens.
      final pattern = RegExp(
        '(^|[^A-Za-z0-9])(${RegExp.escape(secret)})(?=\$|[^A-Za-z0-9])',
      );
      redacted = redacted.replaceAllMapped(
        pattern,
        (match) => '${match.group(1) ?? ''}$replacement',
      );
    }
    return redacted;
  }

  bool _containsKnownSensitiveValue(String? value) {
    if (value == null || value.isEmpty) return false;
    return _knownSensitiveValues.any(
      (secret) => secret.isNotEmpty && value.contains(secret),
    );
  }

  ScoutNode _redactNode(ScoutNode node) {
    final safeLabel = node.label == null
        ? null
        : _redactSensitiveText(node.label!);
    final safeKey = node.key == null ? null : _redactSensitiveText(node.key!);
    final sourceChanged = safeLabel != node.label || safeKey != node.key;
    final safeBaseId = sourceChanged
        ? '${node.kind}.${_slug((safeKey?.isNotEmpty ?? false)
              ? safeKey!
              : (safeLabel?.isNotEmpty ?? false)
              ? safeLabel!
              : node.widgetType)}'
        : _redactSensitiveText(node.baseId, replacement: 'redacted');
    final safeId = sourceChanged
        ? safeBaseId
        : _redactSensitiveText(node.id, replacement: 'redacted');
    final fallbackId = sourceChanged
        ? 'i${safeId.hashCode.abs().toString().padLeft(8, '0').substring(0, 6)}'
        : node.fallbackId;
    final valueContainsSecret = _containsKnownSensitiveValue(node.value);
    final redacted = node.redacted || valueContainsSecret;
    return ScoutNode(
      id: safeId,
      baseId: safeBaseId,
      ordinal: node.ordinal,
      fallbackId: fallbackId,
      kind: node.kind,
      label: safeLabel,
      value: redacted
          ? null
          : node.value == null
          ? null
          : _redactSensitiveText(node.value!),
      validationMessage: node.validationMessage == null
          ? null
          : _redactSensitiveText(node.validationMessage!),
      widgetType: node.widgetType,
      key: safeKey,
      rect: node.rect,
      visibleRect: node.visibleRect,
      visibleFraction: node.visibleFraction,
      suggestedTapPoint: node.suggestedTapPoint,
      hitTestable: node.hitTestable,
      enabled: node.enabled,
      confidence: node.confidence,
      coordinateDevicePixelRatio: node.coordinateDevicePixelRatio,
      selected: node.selected,
      altIds: [
        for (final id in node.altIds)
          _redactSensitiveText(id, replacement: 'redacted'),
      ],
      textColor: node.textColor,
      enclosingTarget: node.enclosingTarget == null
          ? null
          : _redactSensitiveText(
              node.enclosingTarget!,
              replacement: 'redacted',
            ),
      obscured: node.obscured,
      redacted: redacted,
      isEmpty: node.kind == 'field'
          ? node.isEmpty ?? (node.value ?? '').isEmpty
          : node.isEmpty,
      valueToken: node._valueToken,
      renderObject: node._renderObject,
      editableState: node._editableState,
      treeOrdinal: node._treeOrdinal,
    );
  }

  Set<String> _redactSensitiveStrings(Iterable<String> values) => {
    for (final value in values) _redactSensitiveText(value),
  };

  ScoutSnapshot _redactSnapshot(ScoutSnapshot snapshot) {
    Map<String, Object?>? safeOptionalMap(Map<String, Object?>? value) {
      return value == null ? null : _redactSensitiveMap(value);
    }

    List<Map<String, Object?>> safeMaps(
      Iterable<Map<String, Object?>> values,
    ) => [for (final value in values) _redactSensitiveMap(value)];

    return ScoutSnapshot(
      screen: _redactSensitiveText(snapshot.screen),
      screenEvidence: _redactSensitiveMap(snapshot.screenEvidence),
      activeSurface: safeOptionalMap(snapshot.activeSurface),
      routeGuess: snapshot.routeGuess == null
          ? null
          : _redactSensitiveText(snapshot.routeGuess!),
      idle: snapshot.idle,
      devicePixelRatio: snapshot.devicePixelRatio,
      logicalSize: snapshot.logicalSize,
      physicalSize: snapshot.physicalSize,
      padding: snapshot.padding,
      viewPadding: snapshot.viewPadding,
      viewInsets: snapshot.viewInsets,
      viewMetricsAvailable: snapshot.viewMetricsAvailable,
      visibleText: _redactSensitiveStrings(
        snapshot.visibleText,
      ).toList(growable: false),
      hitTestableText: _redactSensitiveStrings(
        snapshot.hitTestableText,
      ).toList(growable: false),
      offscreenText: _redactSensitiveStrings(
        snapshot.offscreenText,
      ).toList(growable: false),
      interactables: [
        for (final node in snapshot.interactables) _redactNode(node),
      ],
      fields: [for (final node in snapshot.fields) _redactNode(node)],
      textTargets: [for (final node in snapshot.textTargets) _redactNode(node)],
      scrollables: safeMaps(snapshot.scrollables),
      perceptionGaps: safeMaps(snapshot.perceptionGaps),
      captureBackend: _redactSensitiveMap(snapshot.captureBackend),
      overlays: safeMaps(snapshot.overlays),
      visualTree: safeOptionalMap(snapshot.visualTree),
      controlGroups: safeMaps(snapshot.controlGroups),
      structuredRows: safeMaps(snapshot.structuredRows),
      suggestedActions: safeMaps(snapshot.suggestedActions),
      recentErrors: safeMaps(snapshot.recentErrors),
      stateGeneration: snapshot.stateGeneration,
      stateDigest: snapshot.stateDigest,
      degradedNodes: snapshot.degradedNodes,
    );
  }

  Object? _redactSensitivePayload(Object? value) {
    if (value is String) return _redactSensitiveText(value);
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          // Response-schema keys are trusted constants. Dynamic app-derived
          // keys (field ids, row handles) are sanitized at their source before
          // they reach a map. Rewriting every schema key would corrupt the
          // protocol when a legitimate one-character PIN is `o`, `id`, etc.
          entry.key.toString(): _redactSensitivePayload(entry.value),
      };
    }
    if (value is Iterable) {
      return <Object?>[for (final item in value) _redactSensitivePayload(item)];
    }
    return value;
  }

  Map<String, Object?> _redactSensitiveMap(Map<String, Object?> value) {
    return _redactSensitivePayload(value)! as Map<String, Object?>;
  }
}
