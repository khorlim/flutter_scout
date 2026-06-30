part of 'flutter_scout_binding.dart';

// part: annotation + in-app capture handlers (handleAnnotations, get-crop, status, handoff, capture extension, overlay install).

/// Public annotation API + in-app capture handlers. Public (not `_`-prefixed)
/// so the package's public `FlutterScoutRuntime` methods (`addAnnotation`,
/// `annotationCandidatesAt`, `visibleAnnotationTargets`) stay callable by
/// importers, exactly as when they were declared directly on the class.
extension RuntimeAnnotations on FlutterScoutRuntime {
  Future<developer.ServiceExtensionResponse> _handleAnnotations(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final action = params['action'] ?? 'list';
      switch (action) {
        case 'enable':
          _setAnnotationMode(true);
          break;
        case 'disable':
          _setAnnotationMode(false);
          break;
        case 'clear':
          final status = params['status'];
          if (status == null || status.isEmpty) {
            _annotations.clear();
          } else {
            _annotations.removeWhere(
              (annotation) => annotation.status == status,
            );
          }
          _bumpAnnotationRevision();
          break;
        case 'resolve':
          final updated = _updateAnnotationStatus(
            id: params['id'],
            status: 'resolved',
            note: params['note'],
          );
          if (!updated) return _annotationMissing(params['id']);
          break;
        case 'dismiss':
          final updated = _updateAnnotationStatus(
            id: params['id'],
            status: 'dismissed',
            note: params['note'],
          );
          if (!updated) return _annotationMissing(params['id']);
          break;
        case 'reopen':
          final updated = _updateAnnotationStatus(
            id: params['id'],
            status: 'open',
            note: params['note'],
          );
          if (!updated) return _annotationMissing(params['id']);
          break;
        case 'check':
          _refreshStaleAnnotationStatuses(_annotationTargets());
          break;
        case 'mark-fixed':
          final id = params['id'];
          final updated = _updateAnnotationStatus(
            id: id,
            status: 'pending_review',
            note: params['note'],
          );
          if (!updated) return _annotationMissing(id);
          final annotation = _annotations.firstWhere(
            (annotation) => annotation.id == id,
          );
          final live = _liveAnnotationTarget(annotation, _annotationTargets());
          await _captureAnnotationCrop(
            annotation,
            slot: 'after',
            liveTarget: live,
          );
          break;
        case 'get-crop':
          return _annotationCropResponse(
            params['id'],
            params['slot'] ?? 'before',
          );
        case 'signal-handoff':
          _signalAnnotationHandoff();
          break;
        case 'list':
        case 'targets':
          break;
        default:
          return _fail(
            'unknown_annotation_action',
            'Unknown annotations action `$action`.',
          );
      }
      await _waitForFrame();
      return _ok(_annotationsStateJson(includeTargets: action == 'targets'));
    } catch (error) {
      return _fail('annotations_failed', error.toString());
    }
  }

  developer.ServiceExtensionResponse _annotationCropResponse(
    String? id,
    String slot,
  ) {
    if (id == null || id.isEmpty) return _annotationMissing(id);
    ScoutAnnotation? annotation;
    for (final candidate in _annotations) {
      if (candidate.id == id) {
        annotation = candidate;
        break;
      }
    }
    if (annotation == null) return _annotationMissing(id);
    final isAfter = slot == 'after';
    final bytes = isAfter ? annotation.afterCropPng : annotation.beforeCropPng;
    final needsNative = isAfter
        ? annotation.afterCropNeedsNative
        : annotation.beforeCropNeedsNative;
    final rect = isAfter ? annotation.afterCropRect : annotation.beforeCropRect;
    return _ok({
      'id': id,
      'slot': slot,
      'hasCrop': bytes != null,
      'needsNative': needsNative,
      'rect': ?rect,
      if (bytes != null) 'bytes': base64Encode(bytes),
    });
  }

  developer.ServiceExtensionResponse _annotationMissing(String? id) {
    return _fail(
      'annotation_not_found',
      id == null || id.isEmpty
          ? 'Annotation id is required.'
          : 'Annotation `$id` was not found.',
    );
  }

  bool _updateAnnotationStatus({
    required String? id,
    required String status,
    String? note,
  }) {
    if (id == null || id.isEmpty) return false;
    for (final annotation in _annotations) {
      if (annotation.id == id) {
        annotation.status = status;
        annotation.updatedAt = DateTime.now();
        final trimmedNote = note?.trim();
        annotation.note = trimmedNote == null || trimmedNote.isEmpty
            ? null
            : trimmedNote;
        _bumpAnnotationRevision();
        return true;
      }
    }
    return false;
  }

  void _refreshStaleAnnotationStatuses(
    List<ScoutAnnotationTarget> liveTargets,
  ) {
    var changed = false;
    for (final annotation in _annotations) {
      if (annotation.status != 'open' && annotation.status != 'stale_target') {
        continue;
      }
      final liveTarget = _liveAnnotationTarget(annotation, liveTargets);
      final nextStatus = liveTarget == null ? 'stale_target' : 'open';
      if (annotation.status != nextStatus) {
        annotation.status = nextStatus;
        annotation.updatedAt = DateTime.now();
        changed = true;
      }
    }
    if (changed) _bumpAnnotationRevision();
  }

  void _setAnnotationMode(bool enabled) {
    if (_annotationMode == enabled) return;
    _annotationMode = enabled;
    _bumpAnnotationRevision();
    _scheduleAnnotationOverlayInstall();
  }

  void _bumpAnnotationRevision() {
    _annotationRevision.value++;
  }

  void _signalAnnotationHandoff() {
    _annotationHandoffSeq++;
    _bumpAnnotationRevision();
  }

  RenderView? _primaryRenderView() {
    final views = RendererBinding.instance.renderViews;
    if (views.isEmpty) return null;
    final implicitId =
        WidgetsBinding.instance.platformDispatcher.implicitView?.viewId;
    for (final view in views) {
      if (view.flutterView.viewId == implicitId) return view;
    }
    return views.first;
  }

  /// Captures a PNG of [rect] (logical coordinates, full screen when null) by
  /// rasterising the root layer. Returns base64 bytes plus a [needsNative] flag
  /// when a platform view (map/webview/native texture) overlaps the region and
  /// would render blank, signalling the CLI to fall back to a native capture.
  Future<_CaptureResult> _captureRegion({
    Rect? rect,
    double padding = 12,
    double? pixelRatio,
  }) async {
    final renderView = _primaryRenderView();
    if (renderView == null) {
      return const _CaptureResult.failure('no_render_view');
    }
    // RenderView.layer is @protected but is the stable, documented way to reach
    // the root OffsetLayer for rasterising the whole view.
    // ignore: invalid_use_of_protected_member
    final layer = renderView.layer;
    if (layer is! OffsetLayer) {
      return const _CaptureResult.failure('no_offset_layer');
    }
    final screen = Offset.zero & renderView.size;
    var bounds = rect == null ? screen : rect.inflate(padding);
    bounds = bounds.intersect(screen);
    if (bounds.isEmpty || bounds.width <= 0 || bounds.height <= 0) {
      bounds = screen;
    }
    // Use the captured view's own ratio (matches _primaryRenderView's choice)
    // rather than views.first, which could differ or be empty in multi-view.
    final dpr = pixelRatio ?? renderView.flutterView.devicePixelRatio;
    final needsNative = _regionHasPlatformView(renderView, bounds);
    // The root layer is a TransformLayer that already bakes in the device pixel
    // ratio, so toImage must receive bounds in PHYSICAL pixels with a pixelRatio
    // of 1.0 — otherwise the dpr scaling is applied twice and the content is
    // shifted off-screen.
    final physicalBounds = Rect.fromLTRB(
      bounds.left * dpr,
      bounds.top * dpr,
      bounds.right * dpr,
      bounds.bottom * dpr,
    );
    // Omit Scout's overlay chrome only inside `bounds` so the crop stays clean,
    // then capture synchronously and restore immediately — the chrome is absent
    // for ~one frame in a small rect, not a full-screen multi-frame blank.
    ui.Image? image;
    _captureClearRects.add(bounds);
    _bumpAnnotationRevision();
    try {
      // Wait two frames, not one: `endOfFrame` can resolve against a frame that
      // was already in flight when we added the clear rect (capture is usually
      // triggered right after another revision bump). The first await drains any
      // such in-flight frame; the second guarantees a frame built *with* the
      // clear rect has been composited before the synchronous raster reads it —
      // otherwise chrome could intermittently bleed into the crop.
      await _waitForFrame();
      await _waitForFrame();
      image = layer.toImageSync(physicalBounds, pixelRatio: 1.0);
    } catch (_) {
      // image stays null; handled below.
    } finally {
      _captureClearRects.remove(bounds);
      _bumpAnnotationRevision();
    }
    if (image == null) {
      return _CaptureResult.failure(
        'capture_failed',
        needsNative: needsNative,
        bounds: bounds,
      );
    }
    try {
      final width = image.width;
      final height = image.height;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) {
        return const _CaptureResult.failure('encode_failed');
      }
      return _CaptureResult(
        bytes: byteData.buffer.asUint8List(),
        width: width,
        height: height,
        pixelRatio: dpr,
        bounds: bounds,
        needsNative: needsNative,
      );
    } catch (error) {
      return _CaptureResult.failure(
        'capture_failed',
        needsNative: needsNative,
        bounds: bounds,
      );
    }
  }

  bool _regionHasPlatformView(RenderObject root, Rect bounds) {
    var found = false;
    void visit(RenderObject node) {
      if (found) return;
      final typeName = node.runtimeType.toString();
      final isPlatformSurface =
          typeName.contains('PlatformView') ||
          typeName.contains('Texture') ||
          typeName.contains('UiKitView') ||
          typeName.contains('AndroidView') ||
          typeName.contains('AppKitView') ||
          typeName.contains('PlatformViewSurface');
      if (isPlatformSurface && node is RenderBox && node.hasSize) {
        try {
          final transform = node.getTransformTo(null);
          final globalRect = MatrixUtils.transformRect(
            transform,
            Offset.zero & node.size,
          );
          if (globalRect.overlaps(bounds)) {
            found = true;
            return;
          }
        } catch (_) {
          // Unable to resolve geometry; assume it could overlap.
          found = true;
          return;
        }
      }
      node.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  Future<developer.ServiceExtensionResponse> _handleCapture(
    String method,
    Map<String, String> params,
  ) async {
    try {
      final mode = params['mode'] ?? 'screen';
      final native = params['native'] ?? 'auto';
      Rect? rect;
      if (mode == 'crop') {
        final parsed = _parseRectParam(params['rect']);
        if (parsed == null) {
          return _fail(
            'capture_missing_rect',
            'capture mode=crop requires rect=left,top,width,height.',
          );
        }
        rect = parsed;
      }
      final padding =
          double.tryParse(params['padding'] ?? '') ?? (mode == 'crop' ? 12 : 0);
      final pixelRatio = double.tryParse(params['pixelRatio'] ?? '');
      final result = await _captureRegion(
        rect: rect,
        padding: padding,
        pixelRatio: pixelRatio,
      );
      final boundsJson = result.bounds == null
          ? null
          : [
              result.bounds!.left,
              result.bounds!.top,
              result.bounds!.width,
              result.bounds!.height,
            ];
      if (result.needsNative && native != 'off') {
        return _ok({
          'mode': mode,
          'needsNative': true,
          'rect': ?boundsJson,
          'reason': 'platform_view_in_region',
        });
      }
      if (result.bytes == null) {
        return _fail(
          'capture_failed',
          'In-app capture failed (${result.error}).',
          extra: {'needsNative': result.needsNative, 'rect': ?boundsJson},
        );
      }
      return _ok({
        'mode': mode,
        'needsNative': result.needsNative,
        'bytes': base64Encode(result.bytes!),
        'width': result.width,
        'height': result.height,
        'pixelRatio': result.pixelRatio,
        'rect': ?boundsJson,
      });
    } catch (error) {
      return _fail('capture_failed', error.toString());
    }
  }

  Rect? _parseRectParam(String? value) {
    if (value == null || value.isEmpty) return null;
    final parts = value.split(',');
    if (parts.length < 4) return null;
    final nums = parts.map((part) => double.tryParse(part.trim())).toList();
    if (nums.any((n) => n == null)) return null;
    return Rect.fromLTWH(nums[0]!, nums[1]!, nums[2]!, nums[3]!);
  }

  Map<String, Object?> _annotationsStateJson({bool includeTargets = false}) {
    final snapshot = _snapshot();
    final liveTargets = _annotationTargets();
    return {
      'annotationMode': _annotationMode,
      'handoffSeq': _annotationHandoffSeq,
      'screen': snapshot.screen,
      'routeGuess': snapshot.routeGuess,
      'annotations': _annotationJsonList(liveTargets: liveTargets),
      if (includeTargets)
        'targets': liveTargets
            .map((target) => target.toJson())
            .toList(growable: false),
    };
  }

  List<Map<String, Object?>> _annotationJsonList({
    List<ScoutAnnotationTarget>? liveTargets,
  }) {
    final targets = liveTargets ?? _annotationTargets();
    return [
      for (final annotation in _annotations)
        annotation.toJson(
          liveTarget: _liveAnnotationTarget(annotation, targets),
        ),
    ];
  }

  List<({Rect rect, String status, String id, String comment})> _annotationPins(
    List<ScoutAnnotationTarget> liveTargets,
  ) {
    return [
      for (final annotation in _annotations)
        if (annotation.isActive)
          if (_liveAnnotationTarget(annotation, liveTargets) case final target?)
            (
              rect: target.rect,
              status: annotation.status,
              id: annotation.id,
              comment: annotation.comment,
            ),
    ];
  }

  ScoutAnnotationTarget? _liveAnnotationTarget(
    ScoutAnnotation annotation,
    List<ScoutAnnotationTarget> liveTargets,
  ) {
    ScoutAnnotationTarget? exactId;
    ScoutAnnotationTarget? exactNode;
    final stableMatches = <ScoutAnnotationTarget>[];
    for (final target in liveTargets) {
      if (target.id == annotation.target.id) {
        exactId = target;
        break;
      }
      if (annotation.target.scoutNodeId != null &&
          target.scoutNodeId == annotation.target.scoutNodeId) {
        exactNode ??= target;
      }
      if (target.stableId == annotation.target.stableId) {
        stableMatches.add(target);
      }
    }
    if (exactId != null) return exactId;
    if (exactNode != null) return exactNode;
    if (stableMatches.isEmpty) return null;
    stableMatches.sort(
      (a, b) => _annotationRectDistance(
        annotation.target.rect,
        a.rect,
      ).compareTo(_annotationRectDistance(annotation.target.rect, b.rect)),
    );
    return stableMatches.first;
  }

  double _annotationRectDistance(Rect snapshot, Rect live) {
    final snapshotCenter = snapshot.center;
    final liveCenter = live.center;
    return (snapshotCenter - liveCenter).distance;
  }

  ScoutAnnotation addAnnotation({
    required ScoutAnnotationTarget target,
    required String comment,
  }) {
    final annotation = ScoutAnnotation(
      id: 'ann_${_nextAnnotationId.toString().padLeft(3, '0')}',
      createdAt: DateTime.now(),
      comment: comment,
      status: 'open',
      target: target,
    );
    _nextAnnotationId++;
    _annotations.add(annotation);
    _bumpAnnotationRevision();
    unawaited(_captureAnnotationCrop(annotation, slot: 'before'));
    return annotation;
  }

  /// Removes the annotation with [id] (mirrors [addAnnotation]). Returns whether
  /// an annotation was actually removed, and bumps the revision so the overlay
  /// and any `annotations list` reflect the deletion.
  bool removeAnnotation(String id) {
    final before = _annotations.length;
    _annotations.removeWhere((annotation) => annotation.id == id);
    final removed = _annotations.length != before;
    if (removed) _bumpAnnotationRevision();
    return removed;
  }

  /// Rasterises the annotation's target region and stashes the PNG on the
  /// annotation so the CLI can serve it later via the `get-crop` action.
  Future<void> _captureAnnotationCrop(
    ScoutAnnotation annotation, {
    required String slot,
    ScoutAnnotationTarget? liveTarget,
  }) async {
    final target = liveTarget ?? annotation.target;
    final rect = target.rect;
    final rectJson = [rect.left, rect.top, rect.width, rect.height];
    final result = await _captureRegion(rect: rect);
    if (slot == 'before') {
      annotation.beforeCropRect = rectJson;
      annotation.beforeCropNeedsNative = result.needsNative;
      annotation.beforeCropPng = result.bytes;
    } else {
      annotation.afterCropRect = rectJson;
      annotation.afterCropNeedsNative = result.needsNative;
      annotation.afterCropPng = result.bytes;
    }
    _bumpAnnotationRevision();
  }

  List<ScoutAnnotationTarget> annotationCandidatesAt(Offset point) {
    final targets = [
      for (final target in _annotationTargets())
        if (target.rect.contains(point)) target,
    ];
    targets.sort((a, b) {
      final aArea = a.rect.width * a.rect.height;
      final bArea = b.rect.width * b.rect.height;
      final area = aArea.compareTo(bArea);
      if (area != 0) return area;
      return b.depth.compareTo(a.depth);
    });
    return targets;
  }

  List<ScoutAnnotationTarget> visibleAnnotationTargets() {
    return _annotationTargets();
  }

  void _scheduleAnnotationOverlayInstall() {
    if (kReleaseMode || _annotationOverlayEntry != null) return;
    if (_annotationOverlayInstallScheduled) return;
    _annotationOverlayInstallScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _annotationOverlayInstallScheduled = false;
      _installAnnotationOverlayIfPossible();
    });
  }

  void _installAnnotationOverlayIfPossible() {
    if (kReleaseMode || _annotationOverlayEntry != null) return;
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) {
      _scheduleAnnotationOverlayInstall();
      return;
    }
    final overlay = _findRootOverlay(root);
    if (overlay == null) {
      _scheduleAnnotationOverlayInstall();
      return;
    }
    _annotationOverlayEntry = OverlayEntry(
      builder: (context) => _FlutterScoutAnnotationOverlay(runtime: this),
    );
    overlay.insert(_annotationOverlayEntry!);
  }

  OverlayState? _findRootOverlay(Element root) {
    OverlayState? result;
    _walk(root, (Element element) {
      if (element is StatefulElement && element.state is OverlayState) {
        result = element.state as OverlayState;
      }
    });
    return result;
  }
}
