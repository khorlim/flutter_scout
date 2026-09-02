part of 'flutter_scout_binding.dart';

// part: unique target resolution, modal/visibility safety, and pre-dispatch revalidation.

enum _TargetResolutionStatus {
  unique,
  ambiguous,
  notFound,
  stale,
  wrongSurface,
  hidden,
  disabled,
  notHitTestable,
  occluded,
}

enum _TargetSafety { mutate, focusedEditable, observeVisible, identify }

class _TargetCandidate {
  const _TargetCandidate({
    required this.node,
    required this.match,
    required this.score,
    required this.onActiveSurface,
  });

  final ScoutNode node;
  final String match;
  final int score;
  final bool onActiveSurface;

  Map<String, Object?> toJson(Map<String, Object?> scope) => {
    // `id` can equal a shared base id for the first duplicate. This is the
    // always-unambiguous selector published for action replay.
    'handle': '${node.id}#${node.ordinal}',
    'id': node.id,
    'baseId': node.baseId,
    'fallbackId': node.fallbackId,
    'kind': node.kind,
    'label': node.label,
    'key': node.key,
    'match': match,
    'heuristicRank': score,
    'scoreKind': 'uncalibrated_heuristic',
    'onActiveSurface': onActiveSurface,
    'visibleFraction': node.visibleFraction,
    'enabled': node.enabled,
    'hitTestable': node.hitTestable,
    if (node.rect case final rect?)
      'rect': [rect.left, rect.top, rect.width, rect.height],
    'scope': scope,
  };
}

class _TargetResolution {
  const _TargetResolution({
    required this.status,
    required this.requested,
    required this.snapshot,
    required this.scope,
    required this.candidates,
    this.node,
    this.textNode,
    this.safePoint,
    this.match,
    this.immediateHitTest,
    this.reason,
  });

  final _TargetResolutionStatus status;
  final String requested;
  final ScoutSnapshot snapshot;
  final Map<String, Object?> scope;
  final List<_TargetCandidate> candidates;
  final ScoutNode? node;
  final ScoutNode? textNode;
  final Offset? safePoint;
  final String? match;
  final Map<String, Object?>? immediateHitTest;
  final String? reason;

  bool get isUnique => status == _TargetResolutionStatus.unique;

  Map<String, Object?> toJson() => {
    'status': status.name,
    'requested': requested,
    'scope': scope,
    if (match != null) 'match': match,
    if (node != null) 'target': node!.toJson(),
    if (textNode != null) 'textTarget': textNode!.toJson(),
    if (safePoint != null) 'safePoint': [safePoint!.dx, safePoint!.dy],
    if (immediateHitTest != null) 'immediateHitTest': immediateHitTest,
    if (reason != null) 'reason': reason,
    if (candidates.isNotEmpty)
      'candidates': [
        for (final candidate in candidates) candidate.toJson(scope),
      ],
  };
}

extension _RuntimeResolution on FlutterScoutRuntime {
  String _scopedGeneratedHandle(ScoutNode node) => '${node.id}#${node.ordinal}';

  _TargetResolution _resolveFocusedField(
    ScoutSnapshot snapshot, {
    _TargetSafety safety = _TargetSafety.focusedEditable,
  }) => _inRequestPhase(
    'match',
    () => _resolveFocusedFieldWithoutPhaseTiming(snapshot, safety: safety),
  );

  _TargetResolution _resolveFocusedFieldWithoutPhaseTiming(
    ScoutSnapshot snapshot, {
    _TargetSafety safety = _TargetSafety.focusedEditable,
  }) {
    final focused = snapshot.fields
        .where((node) => node._editableState?.widget.focusNode.hasFocus == true)
        .toList(growable: false);
    final scope = _targetScope(snapshot);
    if (focused.isEmpty) {
      return _TargetResolution(
        status: _TargetResolutionStatus.notFound,
        requested: 'focused',
        snapshot: snapshot,
        scope: scope,
        candidates: const [],
        reason: 'No editable field currently owns focus.',
      );
    }
    final candidates = [
      for (final node in focused)
        _TargetCandidate(
          node: node,
          match: 'focused_editable',
          score: 1000,
          onActiveSurface: _nodeOnActiveSurface(snapshot, node),
        ),
    ];
    if (candidates.length != 1) {
      return _TargetResolution(
        status: _TargetResolutionStatus.ambiguous,
        requested: 'focused',
        snapshot: snapshot,
        scope: scope,
        candidates: _sortTargetCandidates(candidates),
        reason: 'More than one editable reports focus.',
      );
    }
    return _applyTargetSafety(
      snapshot: snapshot,
      requested: 'focused',
      candidate: candidates.single,
      safety: safety,
      scope: scope,
    );
  }

  _TargetResolution _revalidateFocusedField(_TargetResolution original) {
    if (!original.isUnique) return original;
    final fresh = _snapshot();
    if (fresh.stateGeneration != original.snapshot.stateGeneration ||
        fresh.snapshotId != original.snapshot.snapshotId) {
      return _TargetResolution(
        status: _TargetResolutionStatus.stale,
        requested: 'focused',
        snapshot: fresh,
        scope: _targetScope(fresh),
        candidates: original.candidates,
        node: original.node,
        reason: 'Observed state changed before focused-field mutation.',
      );
    }
    final resolved = _resolveFocusedField(fresh);
    if (!resolved.isUnique) return resolved;
    if (_logicalNodeIdentity(resolved.node!) !=
        _logicalNodeIdentity(original.node!)) {
      return _TargetResolution(
        status: _TargetResolutionStatus.stale,
        requested: 'focused',
        snapshot: fresh,
        scope: _targetScope(fresh),
        candidates: resolved.candidates,
        node: resolved.node,
        reason: 'Focus moved to a different logical field.',
      );
    }
    return resolved;
  }

  _TargetResolution _resolveTarget(
    ScoutSnapshot snapshot,
    String requested, {
    bool fieldOnly = false,
    _TargetSafety safety = _TargetSafety.mutate,
  }) => _inRequestPhase(
    'match',
    () => _resolveTargetWithoutPhaseTiming(
      snapshot,
      requested,
      fieldOnly: fieldOnly,
      safety: safety,
    ),
  );

  _TargetResolution _resolveTargetWithoutPhaseTiming(
    ScoutSnapshot snapshot,
    String requested, {
    bool fieldOnly = false,
    _TargetSafety safety = _TargetSafety.mutate,
  }) {
    final target = requested.trim();
    final scope = _targetScope(snapshot);
    if (target.isEmpty) {
      return _TargetResolution(
        status: _TargetResolutionStatus.notFound,
        requested: requested,
        snapshot: snapshot,
        scope: scope,
        candidates: const [],
        reason: 'The target selector is empty.',
      );
    }

    final primaryPool = fieldOnly
        ? snapshot.fields
        : <ScoutNode>[...snapshot.interactables, ...snapshot.fields];
    var ranked = _rankTargetMatches(snapshot, primaryPool, target);
    if (ranked.isEmpty && !fieldOnly) {
      ranked = _rankTargetMatches(snapshot, _scrollableTargetNodes(), target);
    }
    // Text nodes are a fallback only. A button and its child Text commonly have
    // the same label; treating both as peers would make every normal button
    // ambiguous. Explicit `text.*` handles still resolve here.
    if (ranked.isEmpty && !fieldOnly) {
      ranked = _rankTargetMatches(snapshot, snapshot.textTargets, target);
    }
    if (ranked.isEmpty) {
      return _TargetResolution(
        status: _TargetResolutionStatus.notFound,
        requested: target,
        snapshot: snapshot,
        scope: scope,
        candidates: const [],
        reason: 'No node matched the selector.',
      );
    }
    if (ranked.length != 1) {
      return _TargetResolution(
        status: _TargetResolutionStatus.ambiguous,
        requested: target,
        snapshot: snapshot,
        scope: scope,
        candidates: ranked,
        reason:
            '${ranked.length} nodes matched; use a disambiguated id or unique key.',
      );
    }
    return _applyTargetSafety(
      snapshot: snapshot,
      requested: target,
      candidate: ranked.single,
      safety: safety,
      scope: scope,
    );
  }

  List<_TargetCandidate> _rankTargetMatches(
    ScoutSnapshot snapshot,
    List<ScoutNode> nodes,
    String requested,
  ) {
    final selectors = <String>{requested};
    for (final row in snapshot.structuredRows) {
      final handles = row['handles'];
      if (handles is! Map) continue;
      for (final entry in handles.entries) {
        final alias = entry.key?.toString().trim();
        final value = entry.value?.toString().trim();
        if (alias == null || value == null || value.isEmpty) continue;
        if (alias == requested) selectors.add(value);
      }
    }

    // A scoped generated handle names one inspected occurrence. The regular
    // base/id/label selector tiers below retain their ambiguity gate.
    final scoped = <_TargetCandidate>[];
    for (final node in nodes) {
      if (!selectors.contains(_scopedGeneratedHandle(node))) continue;
      scoped.add(
        _TargetCandidate(
          node: node,
          match: 'scoped_handle',
          score: 1010,
          onActiveSurface: _nodeOnActiveSurface(snapshot, node),
        ),
      );
    }
    if (scoped.isNotEmpty) return _sortTargetCandidates(scoped);

    final exact = <_TargetCandidate>[];
    for (final node in nodes) {
      final kinds = <String>[];
      for (final selector in selectors) {
        if (node.id == selector) kinds.add('id');
        if (node.baseId == selector) kinds.add('baseId');
        if (node.fallbackId == selector) kinds.add('fallbackId');
        if (node.key == selector) kinds.add('key');
        if (node.altIds.contains(selector)) kinds.add('alias');
        if (node.label == selector) kinds.add('label');
      }
      if (kinds.isEmpty) continue;
      exact.add(
        _TargetCandidate(
          node: node,
          match: kinds.toSet().join('+'),
          score: _exactTargetScore(kinds),
          onActiveSurface: _nodeOnActiveSurface(snapshot, node),
        ),
      );
    }
    if (exact.isNotEmpty) {
      final ranked = _sortTargetCandidates(exact);
      final strongestScore = ranked.first.score;
      return ranked
          .where((candidate) => candidate.score == strongestScore)
          .toList(growable: false);
    }

    final caseInsensitive = <_TargetCandidate>[];
    final lower = requested.toLowerCase();
    for (final node in nodes) {
      final label = node.label;
      if (label == null || label.toLowerCase() != lower) continue;
      caseInsensitive.add(
        _TargetCandidate(
          node: node,
          match: 'label_case_insensitive',
          score: 800,
          onActiveSurface: _nodeOnActiveSurface(snapshot, node),
        ),
      );
    }
    if (caseInsensitive.isNotEmpty) {
      return _sortTargetCandidates(caseInsensitive);
    }

    // These are intentionally one fuzzy tier. Scores rank the evidence for the
    // caller, but multiple fuzzy candidates always abstain.
    final fuzzy = <_TargetCandidate>[];
    final slug = _slug(requested);
    final kindless = _slug(
      requested.contains('.') ? requested.split('.').last : requested,
    );
    for (final node in nodes) {
      final reasons = <String>[];
      var score = 0;
      final label = node.label?.toLowerCase();
      if (label != null && _slug(label) == slug) {
        reasons.add('normalized_label');
        score = math.max(score, 720);
      }
      if (node.id.endsWith('.$slug') || node.id.endsWith('.$kindless')) {
        reasons.add('id_suffix');
        score = math.max(score, 700);
      }
      if (node.altIds.any(
        (alias) => alias.endsWith('.$slug') || alias.endsWith('.$kindless'),
      )) {
        reasons.add('alias_suffix');
        score = math.max(score, 680);
      }
      if (label != null &&
          lower.length >= 3 &&
          (label.contains(lower) || lower.contains(label))) {
        reasons.add('label_contains');
        score = math.max(score, 620);
      }
      if (reasons.isEmpty) continue;
      fuzzy.add(
        _TargetCandidate(
          node: node,
          match: reasons.join('+'),
          score: score,
          onActiveSurface: _nodeOnActiveSurface(snapshot, node),
        ),
      );
    }
    return _sortTargetCandidates(fuzzy);
  }

  List<ScoutNode> _scrollableTargetNodes() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return const [];
    final occurrences = <String, int>{};
    final nodes = <ScoutNode>[];
    _walkVisible(root, (element) {
      final widget = element.widget;
      if (widget is! Scrollable) return;
      final key = _nearestScrollableKey(element);
      final baseId = 'scroll.${_slug(key ?? widget.axisDirection.name)}';
      final ordinal = occurrences.update(
        baseId,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      final renderObject = element.renderObject;
      final rect = _rectFor(element);
      if (renderObject == null ||
          rect == null ||
          rect.width <= 0 ||
          rect.height <= 0) {
        return;
      }
      final visibleRect = _visibleRectFor(rect);
      final point = visibleRect?.center;
      nodes.add(
        ScoutNode(
          id: ordinal == 1 ? baseId : '${baseId}_$ordinal',
          baseId: baseId,
          ordinal: ordinal,
          fallbackId:
              'i${baseId.hashCode.abs().toString().padLeft(8, '0').substring(0, 6)}',
          kind: 'scroll',
          label: key ?? widget.axisDirection.name,
          value: null,
          validationMessage: null,
          widgetType: widget.runtimeType.toString(),
          key: key,
          rect: rect,
          visibleRect: visibleRect,
          visibleFraction: _visibleFraction(rect, visibleRect),
          suggestedTapPoint: point,
          hitTestable:
              point != null &&
              _hitTestPathContainsRenderObject(point, renderObject),
          enabled: true,
          confidence: key == null ? 0.75 : 0.98,
          renderObject: renderObject,
        ),
      );
    });
    return nodes;
  }

  int _exactTargetScore(List<String> kinds) {
    if (kinds.contains('id')) return 1000;
    if (kinds.contains('baseId')) return 980;
    if (kinds.contains('key')) return 960;
    if (kinds.contains('fallbackId')) return 940;
    if (kinds.contains('alias')) return 920;
    return 900;
  }

  List<_TargetCandidate> _sortTargetCandidates(
    List<_TargetCandidate> candidates,
  ) {
    candidates.sort((a, b) {
      var order = b.score.compareTo(a.score);
      if (order != 0) return order;
      order = (b.onActiveSurface ? 1 : 0).compareTo(a.onActiveSurface ? 1 : 0);
      if (order != 0) return order;
      order = b.node.visibleFraction.compareTo(a.node.visibleFraction);
      if (order != 0) return order;
      order = (b.node.enabled ? 1 : 0).compareTo(a.node.enabled ? 1 : 0);
      if (order != 0) return order;
      order = (b.node.hitTestable ? 1 : 0).compareTo(
        a.node.hitTestable ? 1 : 0,
      );
      if (order != 0) return order;
      order = (a.node.rect?.top ?? double.infinity).compareTo(
        b.node.rect?.top ?? double.infinity,
      );
      if (order != 0) return order;
      return a.node.id.compareTo(b.node.id);
    });
    return candidates;
  }

  _TargetResolution _applyTargetSafety({
    required ScoutSnapshot snapshot,
    required String requested,
    required _TargetCandidate candidate,
    required _TargetSafety safety,
    required Map<String, Object?> scope,
    ScoutNode? textNode,
  }) {
    final node = candidate.node;
    if (!_nodeOnActiveSurface(snapshot, node)) {
      return _unsafeResolution(
        _TargetResolutionStatus.wrongSurface,
        requested,
        snapshot,
        scope,
        candidate,
        'The node is outside the active top modal/surface.',
        textNode: textNode,
      );
    }
    if (safety != _TargetSafety.identify &&
        (node.visibleFraction <= 0 || node.visibleRect == null)) {
      return _unsafeResolution(
        _TargetResolutionStatus.hidden,
        requested,
        snapshot,
        scope,
        candidate,
        'The node has no visible exposure in the viewport.',
        textNode: textNode,
      );
    }
    if (safety != _TargetSafety.mutate) {
      return _TargetResolution(
        status: _TargetResolutionStatus.unique,
        requested: requested,
        snapshot: snapshot,
        scope: scope,
        candidates: [candidate],
        node: node,
        textNode: textNode,
        match: candidate.match,
      );
    }
    if (!node.enabled) {
      return _unsafeResolution(
        _TargetResolutionStatus.disabled,
        requested,
        snapshot,
        scope,
        candidate,
        'The matched control is disabled.',
        textNode: textNode,
      );
    }

    // Text entry is dispatched directly to the currently focused EditableText;
    // unlike a tap, it does not send a pointer event. Some legitimate custom
    // PIN inputs retain keyboard focus behind an IgnorePointer/animated shell,
    // so requiring their render object on a pointer hit path rejects a safe,
    // already-focused field. Keep this exception limited to the focused-field
    // resolver, after active-surface, visibility, enabled, and focus checks.
    if (safety == _TargetSafety.focusedEditable) {
      final editable = node._editableState;
      if (editable?.widget.focusNode.hasFocus == true) {
        return _TargetResolution(
          status: _TargetResolutionStatus.unique,
          requested: requested,
          snapshot: snapshot,
          scope: scope,
          candidates: [candidate],
          node: node,
          textNode: textNode,
          match: candidate.match,
        );
      }
      return _unsafeResolution(
        _TargetResolutionStatus.stale,
        requested,
        snapshot,
        scope,
        candidate,
        'The editable field no longer owns focus.',
        textNode: textNode,
      );
    }

    Map<String, Object?>? lastHit;
    var sawOtherHit = false;
    for (final point in _candidateSafePoints(snapshot, node)) {
      final hit = _immediateHitTestEvidence(point, node._renderObject);
      lastHit = hit;
      if (hit['containsTarget'] == true) {
        return _TargetResolution(
          status: _TargetResolutionStatus.unique,
          requested: requested,
          snapshot: snapshot,
          scope: scope,
          candidates: [candidate],
          node: node,
          textNode: textNode,
          safePoint: point,
          match: candidate.match,
          immediateHitTest: hit,
        );
      }
      sawOtherHit = sawOtherHit || hit['hit'] == true;
    }
    final status = sawOtherHit
        ? _TargetResolutionStatus.occluded
        : _TargetResolutionStatus.notHitTestable;
    return _TargetResolution(
      status: status,
      requested: requested,
      snapshot: snapshot,
      scope: scope,
      candidates: [candidate],
      node: node,
      textNode: textNode,
      match: candidate.match,
      immediateHitTest: lastHit,
      reason: sawOtherHit
          ? 'Visible sample points are intercepted by another render object.'
          : 'No visible sample point has a hit path to the matched control.',
    );
  }

  _TargetResolution _unsafeResolution(
    _TargetResolutionStatus status,
    String requested,
    ScoutSnapshot snapshot,
    Map<String, Object?> scope,
    _TargetCandidate candidate,
    String reason, {
    ScoutNode? textNode,
  }) {
    return _TargetResolution(
      status: status,
      requested: requested,
      snapshot: snapshot,
      scope: scope,
      candidates: [candidate],
      node: candidate.node,
      textNode: textNode,
      match: candidate.match,
      reason: reason,
    );
  }

  _TargetResolution _revalidateTarget(
    _TargetResolution original, {
    bool fieldOnly = false,
  }) {
    if (!original.isUnique) return original;
    final fresh = _snapshot();
    if (fresh.stateGeneration != original.snapshot.stateGeneration ||
        fresh.snapshotId != original.snapshot.snapshotId) {
      return _TargetResolution(
        status: _TargetResolutionStatus.stale,
        requested: original.requested,
        snapshot: fresh,
        scope: _targetScope(fresh),
        candidates: original.candidates,
        node: original.node,
        reason:
            'Observed state changed between resolution and immediate dispatch validation.',
      );
    }
    final resolved = _resolveTarget(
      fresh,
      original.requested,
      fieldOnly: fieldOnly,
    );
    if (!resolved.isUnique) return resolved;
    if (_logicalNodeIdentity(resolved.node!) !=
        _logicalNodeIdentity(original.node!)) {
      return _TargetResolution(
        status: _TargetResolutionStatus.stale,
        requested: original.requested,
        snapshot: fresh,
        scope: _targetScope(fresh),
        candidates: resolved.candidates,
        node: resolved.node,
        reason: 'The selector now resolves to a different logical node.',
      );
    }
    return resolved;
  }

  _TargetResolution _resolveTextTarget(
    ScoutSnapshot snapshot,
    String requested, {
    bool loose = false,
  }) => _inRequestPhase(
    'match',
    () =>
        _resolveTextTargetWithoutPhaseTiming(snapshot, requested, loose: loose),
  );

  _TargetResolution _resolveTextTargetWithoutPhaseTiming(
    ScoutSnapshot snapshot,
    String requested, {
    bool loose = false,
  }) {
    final wanted = requested.trim();
    final lower = wanted.toLowerCase();
    List<ScoutNode> matches(bool Function(String label) predicate) => [
      for (final node in snapshot.textTargets)
        if (node.label case final label?)
          if (predicate(label)) node,
    ];

    var texts = matches((label) => label == wanted);
    var matchKind = 'text_exact';
    if (texts.isEmpty) {
      texts = matches((label) => label.toLowerCase() == lower);
      matchKind = 'text_case_insensitive';
    }
    if (texts.isEmpty && wanted.length >= 3) {
      texts = matches((label) => label.toLowerCase().contains(lower));
      matchKind = 'text_contains';
    }
    if (texts.isEmpty && loose) {
      texts = matches((label) {
        final stripped = label.toLowerCase().replaceAll(
          RegExp(r'[…\.\s]+$'),
          '',
        );
        return stripped.length >= 4 && lower.startsWith(stripped);
      });
      matchKind = 'text_truncated_prefix';
    }
    final scope = _targetScope(snapshot);
    if (texts.isEmpty) {
      return _TargetResolution(
        status: _TargetResolutionStatus.notFound,
        requested: wanted,
        snapshot: snapshot,
        scope: scope,
        candidates: const [],
        reason: 'No visible text matched the requested string.',
      );
    }

    final byLogicalTarget = <String, ({ScoutNode target, ScoutNode text})>{};
    for (final text in texts) {
      ScoutNode target = text;
      final enclosing = text.enclosingTarget;
      if (enclosing != null) {
        final enclosingNodes = snapshot.interactables
            .where((node) => node.id == enclosing)
            .toList(growable: false);
        if (enclosingNodes.length == 1) target = enclosingNodes.single;
      }
      byLogicalTarget.putIfAbsent(
        _logicalNodeIdentity(target),
        () => (target: target, text: text),
      );
    }
    final candidates = [
      for (final pair in byLogicalTarget.values)
        _TargetCandidate(
          node: pair.target,
          match: matchKind,
          score: matchKind == 'text_exact'
              ? 1000
              : matchKind == 'text_case_insensitive'
              ? 900
              : matchKind == 'text_contains'
              ? 700
              : 600,
          onActiveSurface: _nodeOnActiveSurface(snapshot, pair.target),
        ),
    ];
    _sortTargetCandidates(candidates);
    if (candidates.length != 1) {
      return _TargetResolution(
        status: _TargetResolutionStatus.ambiguous,
        requested: wanted,
        snapshot: snapshot,
        scope: scope,
        candidates: candidates,
        reason: '${candidates.length} distinct controls contain matching text.',
      );
    }
    final pair = byLogicalTarget.values.firstWhere(
      (value) => identical(value.target, candidates.single.node),
    );
    return _applyTargetSafety(
      snapshot: snapshot,
      requested: wanted,
      candidate: candidates.single,
      safety: _TargetSafety.mutate,
      scope: scope,
      textNode: pair.text,
    );
  }

  _TargetResolution _revalidateTextTarget(
    _TargetResolution original, {
    bool loose = false,
  }) {
    if (!original.isUnique) return original;
    final fresh = _snapshot();
    if (fresh.stateGeneration != original.snapshot.stateGeneration ||
        fresh.snapshotId != original.snapshot.snapshotId) {
      return _TargetResolution(
        status: _TargetResolutionStatus.stale,
        requested: original.requested,
        snapshot: fresh,
        scope: _targetScope(fresh),
        candidates: original.candidates,
        node: original.node,
        reason: 'Observed state changed before text activation dispatch.',
      );
    }
    final resolved = _resolveTextTarget(
      fresh,
      original.requested,
      loose: loose,
    );
    if (!resolved.isUnique) return resolved;
    if (_logicalNodeIdentity(resolved.node!) !=
        _logicalNodeIdentity(original.node!)) {
      return _TargetResolution(
        status: _TargetResolutionStatus.stale,
        requested: original.requested,
        snapshot: fresh,
        scope: _targetScope(fresh),
        candidates: resolved.candidates,
        node: resolved.node,
        reason: 'Matching text now belongs to a different logical control.',
      );
    }
    return resolved;
  }

  bool _nodeOnActiveSurface(ScoutSnapshot snapshot, ScoutNode node) {
    if (snapshot.activeSurface == null) return true;
    final surfaceRect =
        _rectFromJson(snapshot.activeSurface?['rect']) ??
        _surfaceRectFor(snapshot);
    final barrierOrdinal = _modalContentStartOrdinal(snapshot.overlays);
    final anchorOrdinal = _surfaceAnchorOrdinal(snapshot);
    final minimumOrdinal = barrierOrdinal ?? anchorOrdinal;
    if (node.kind != 'scroll' &&
        minimumOrdinal != null &&
        (node._treeOrdinal ?? -1) < minimumOrdinal) {
      return false;
    }
    if (surfaceRect != null) {
      final rect = node.visibleRect ?? node.rect;
      if (rect == null ||
          (!rect.overlaps(surfaceRect) && !surfaceRect.contains(rect.center))) {
        return false;
      }
      if (node.kind == 'scroll') {
        final overlap = rect.intersect(surfaceRect);
        final area = rect.width * rect.height;
        final overlapArea =
            math.max(0.0, overlap.width) * math.max(0.0, overlap.height);
        if (area <= 0 || overlapArea / area < 0.5) return false;
      }
    }
    // An active surface with neither geometry nor ordering evidence cannot be
    // proven safe. Abstention is preferable to reaching through a modal.
    return surfaceRect != null || minimumOrdinal != null;
  }

  List<Offset> _candidateSafePoints(ScoutSnapshot snapshot, ScoutNode node) {
    var visible = node.visibleRect ?? node.rect?.intersect(_viewportRect());
    if (visible == null || visible.width <= 0 || visible.height <= 0) {
      return const [];
    }
    final surfaceRect = snapshot.activeSurface == null
        ? null
        : (_rectFromJson(snapshot.activeSurface?['rect']) ??
              _surfaceRectFor(snapshot));
    if (surfaceRect != null) visible = visible.intersect(surfaceRect);
    if (visible.width <= 0 || visible.height <= 0) return const [];
    final insetX = math.min(12.0, math.max(0.5, visible.width * 0.18));
    final insetY = math.min(12.0, math.max(0.5, visible.height * 0.18));
    final left = math.min(visible.right, visible.left + insetX);
    final right = math.max(visible.left, visible.right - insetX);
    final top = math.min(visible.bottom, visible.top + insetY);
    final bottom = math.max(visible.top, visible.bottom - insetY);
    return <Offset>{
      visible.center,
      Offset(left, top),
      Offset(right, top),
      Offset(left, bottom),
      Offset(right, bottom),
      Offset(visible.center.dx, top),
      Offset(visible.center.dx, bottom),
      Offset(left, visible.center.dy),
      Offset(right, visible.center.dy),
    }.toList(growable: false);
  }

  Map<String, Object?> _immediateHitTestEvidence(
    Offset point,
    RenderObject? expected,
  ) {
    var path = <String>[];
    var containsTarget = false;
    final hit = _hitTest(point, (result) {
      path = [
        for (final entry in result.path.take(12))
          entry.target.runtimeType.toString(),
      ];
      containsTarget =
          expected != null &&
          result.path.any((entry) => identical(entry.target, expected));
      return result.path.isNotEmpty;
    });
    return {
      'logicalPoint': [point.dx, point.dy],
      'hit': hit,
      'containsTarget': containsTarget,
      'path': path,
    };
  }

  Map<String, Object?> _coordinateEvidence(
    Offset point,
    ScoutSnapshot snapshot,
  ) {
    final hit = _immediateHitTestEvidence(point, null);
    final dpr = snapshot.devicePixelRatio;
    final viewport = _viewportRect();
    return {
      'coordinateSpace': 'logical',
      'logicalPoint': [point.dx, point.dy],
      'physicalPoint': [point.dx * dpr, point.dy * dpr],
      'devicePixelRatio': dpr,
      'viewport': [
        viewport.left,
        viewport.top,
        viewport.width,
        viewport.height,
      ],
      'insideViewport': viewport.contains(point),
      'immediateHitTest': hit,
      'scope': _targetScope(snapshot),
    };
  }

  Map<String, Object?> _targetScope(ScoutSnapshot snapshot) => {
    'runId': _boundRunId,
    'runtimeInstanceId': _runtimeInstanceId,
    'stateGeneration': snapshot.stateGeneration,
    'snapshotId': snapshot.snapshotId,
  };

  String _logicalNodeIdentity(ScoutNode node) => [
    node.kind,
    node.id,
    node.baseId,
    node.fallbackId,
    node.key ?? '',
    node.widgetType,
    node.label ?? '',
    node._treeOrdinal ?? -1,
  ].join('|');

  developer.ServiceExtensionResponse _targetResolutionFailure(
    _TargetResolution resolution,
  ) {
    final status = resolution.status;
    final code = switch (status) {
      _TargetResolutionStatus.ambiguous => 'target_ambiguous',
      _TargetResolutionStatus.stale => 'stale_target',
      _TargetResolutionStatus.hidden => 'target_not_visible',
      _TargetResolutionStatus.disabled => 'target_disabled',
      _ => 'target_not_found',
    };
    final legacyReason = switch (status) {
      _TargetResolutionStatus.wrongSurface ||
      _TargetResolutionStatus.notHitTestable ||
      _TargetResolutionStatus.occluded => 'target_not_hit_testable',
      _ => status.name,
    };
    return _fail(
      code,
      resolution.reason ?? 'Target resolution failed: ${status.name}.',
      extra: {
        'reason': legacyReason,
        'resolution': resolution.toJson(),
        if (resolution.node != null) 'target': resolution.node!.toJson(),
        if (resolution.snapshot.activeSurface != null)
          'activeSurface': resolution.snapshot.activeSurface,
        'activation': const {'dispatched': false},
      },
    );
  }
}
