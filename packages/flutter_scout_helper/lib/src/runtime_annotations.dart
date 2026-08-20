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
      if (action != 'list' && action != 'targets' && action != 'get-crop') {
        _markRequestPhaseUnavailable(
          'match',
          'not_applicable:annotation_tool_state_mutation_has_no_widget_selector',
        );
      }
      switch (action) {
        case 'enable':
          _inRequestPhase('dispatch', () => _setAnnotationMode(true));
          break;
        case 'disable':
          _inRequestPhase('dispatch', () => _setAnnotationMode(false));
          break;
        case 'clear':
          _inRequestPhase('dispatch', () {
            final status = params['status'];
            if (status == null || status.isEmpty) {
              _annotations.clear();
            } else {
              _annotations.removeWhere(
                (annotation) => annotation.status == status,
              );
            }
            _bumpAnnotationRevision();
          });
          break;
        case 'delete':
          final ids = _annotationDeleteIds(params);
          if (ids.isEmpty) {
            return _fail(
              'annotation_ids_required',
              'annotations delete requires at least one id.',
            );
          }
          final removed = <String>[];
          final notFound = <String>[];
          _inRequestPhase('dispatch', () {
            for (final id in ids) {
              (removeAnnotation(id) ? removed : notFound).add(id);
            }
          });
          await _settleMutationFrames();
          return _ok({
            ..._annotationsStateJson(),
            'removed': removed,
            'notFound': notFound,
          });
        case 'restore':
          final restored = _inRequestPhase(
            'dispatch',
            () => restoreAnnotations(params['records']),
          );
          await _settleMutationFrames();
          return _ok({..._annotationsStateJson(), 'restored': restored});
        case 'resolve':
          final updated = _inRequestPhase(
            'dispatch',
            () => _updateAnnotationStatus(
              id: params['id'],
              status: 'resolved',
              note: params['note'],
            ),
          );
          if (!updated) return _annotationMissing(params['id']);
          break;
        case 'dismiss':
          final updated = _inRequestPhase(
            'dispatch',
            () => _updateAnnotationStatus(
              id: params['id'],
              status: 'dismissed',
              note: params['note'],
            ),
          );
          if (!updated) return _annotationMissing(params['id']);
          break;
        case 'reopen':
          final updated = _inRequestPhase(
            'dispatch',
            () => _updateAnnotationStatus(
              id: params['id'],
              status: 'open',
              note: params['note'],
            ),
          );
          if (!updated) return _annotationMissing(params['id']);
          break;
        case 'check':
          final targets = _annotationTargets();
          _inRequestPhase(
            'dispatch',
            () => _refreshStaleAnnotationStatuses(targets),
          );
          break;
        case 'mark-fixed':
          final id = params['id'];
          final updated = _inRequestPhase(
            'dispatch',
            () => _updateAnnotationStatus(
              id: id,
              status: 'pending_review',
              note: params['note'],
            ),
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
          _inRequestPhase('dispatch', _signalAnnotationHandoff);
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
      if (action != 'list' && action != 'targets') {
        await _settleMutationFrames();
      }
      return _ok({
        ..._annotationsStateJson(includeTargets: action == 'targets'),
        if (action == 'list' || action == 'targets')
          'observationEffects': _observationEffects(
            _FrameAdvancePolicy.observeOnly,
          ),
      });
    } catch (error) {
      return _fail('annotations_failed', error.toString());
    }
  }

  /// Selects which nodes get numbered marks for a set-of-marks capture and
  /// builds the legend. [region] (inflated logical bounds, null = whole
  /// screen) scopes marks to what the image shows; [filter] is all|buttons|
  /// fields. Badges that would land on top of an already-placed badge are
  /// suppressed so dense screens stay legible — those are counted in
  /// [omitted] rather than stacked into an unreadable pile.
  ({
    List<({int n, Rect rect})> marks,
    List<Map<String, Object?>> legend,
    int omitted,
  })
  _buildCaptureMarks({Rect? region, String filter = 'all'}) {
    final snapshot = _snapshot();
    final marks = <({int n, Rect rect})>[];
    final legend = <Map<String, Object?>>[];
    final placedBadges = <Offset>[];
    const badgeClearance = 20.0;
    var omitted = 0;
    var n = 0;
    bool addMark({
      required Rect visible,
      required String id,
      required String kind,
      String? label,
      bool? selected,
    }) {
      final badge = visible.topLeft;
      if (placedBadges.any(
        (placed) => (placed - badge).distance < badgeClearance,
      )) {
        omitted += 1;
        return false;
      }
      placedBadges.add(badge);
      n += 1;
      marks.add((n: n, rect: visible));
      final legendEntry = <String, Object?>{'n': n, 'id': id, 'kind': kind};
      if (label != null) legendEntry['label'] = label;
      if (selected != null) legendEntry['selected'] = selected;
      legend.add(legendEntry);
      return true;
    }

    for (final node in [...snapshot.interactables, ...snapshot.fields]) {
      final visible = node.visibleRect;
      if (visible == null) continue;
      if (region != null && !region.overlaps(visible)) continue;
      if (filter == 'buttons' && node.kind != 'btn') continue;
      if (filter == 'fields' && node.kind != 'field') continue;
      addMark(
        visible: visible,
        id: node.id,
        kind: node.kind,
        label: node.label,
        selected: node.selected,
      );
    }
    if (filter == 'all' && marks.length < 8) {
      final existing = [for (final mark in marks) mark.rect];
      for (final target in _annotationTargets()) {
        if (target.kind != 'tap' &&
            target.kind != 'btn' &&
            target.kind != 'card' &&
            target.kind != 'widget' &&
            target.kind != 'layout') {
          continue;
        }
        final visible = target.visibleRect;
        if (region != null && !region.overlaps(visible)) continue;
        if (existing.any((rect) => rect.overlaps(visible))) continue;
        if (addMark(
          visible: visible,
          id: target.scoutNodeId ?? target.stableId,
          kind: target.kind,
          label: target.label ?? target.text,
        )) {
          existing.add(visible);
        }
      }
    }
    return (marks: marks, legend: legend, omitted: omitted);
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
      'observationEffects': _observationEffects(
        _FrameAdvancePolicy.observeOnly,
      ),
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
    if (_annotationMode != enabled) {
      _annotationMode = enabled;
      _bumpAnnotationRevision();
    }
    if (enabled) {
      _annotationOverlayOptedIn = true;
    }
    _reconcileAnnotationOverlay();
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
    List<({int n, Rect rect})>? marks,
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
    final clearScoutChrome =
        _annotationOverlayEntry != null &&
        (_annotationOverlayHost?.mounted ?? false);
    if (clearScoutChrome) {
      _captureClearRects.add(bounds);
      _bumpAnnotationRevision();
    }
    try {
      if (clearScoutChrome) {
        // Wait two frames, not one: `endOfFrame` can resolve against a frame
        // that was already in flight when we added the clear rect. The first
        // await drains that frame; the second guarantees a frame built with
        // the clear rect has been composited before rasterization.
        await _settleMutationFrames();
        await _settleMutationFrames();
      }
      image = layer.toImageSync(physicalBounds, pixelRatio: 1.0);
    } catch (_) {
      // image stays null; handled below.
    } finally {
      if (clearScoutChrome) {
        _captureClearRects.remove(bounds);
        _bumpAnnotationRevision();
        // Restore the Scout overlay before the caller takes its mandatory
        // post-raster identity snapshot. Otherwise Scout's own scheduled
        // restoration frame changes `idle` and creates a false app-state race.
        await _settleMutationFrames();
        await _settleMutationFrames();
      }
    }
    if (image == null) {
      return _CaptureResult.failure(
        'capture_failed',
        needsNative: needsNative,
        bounds: bounds,
      );
    }
    try {
      if (marks != null && marks.isNotEmpty) {
        final composited = await _drawCaptureMarks(image, bounds, dpr, marks);
        image.dispose();
        image = composited;
      }
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

  /// Set-of-marks compositing: draws each mark's outline plus a numbered
  /// badge onto the captured raster, so one image tells an agent what is
  /// tappable and which handle each region maps to (via the returned legend).
  Future<ui.Image> _drawCaptureMarks(
    ui.Image base,
    Rect bounds,
    double dpr,
    List<({int n, Rect rect})> marks,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(base, Offset.zero, Paint());
    const markColor = Color(0xFFE5484D);
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * dpr
      ..color = markColor;
    final badgeFill = Paint()..color = markColor;
    for (final mark in marks) {
      // Logical, screen-relative -> physical, capture-relative.
      final rect = Rect.fromLTWH(
        (mark.rect.left - bounds.left) * dpr,
        (mark.rect.top - bounds.top) * dpr,
        mark.rect.width * dpr,
        mark.rect.height * dpr,
      );
      canvas.drawRect(rect, outline);
      final text = TextPainter(
        text: TextSpan(
          text: '${mark.n}',
          style: TextStyle(
            color: const Color(0xFFFFFFFF),
            fontSize: 10 * dpr,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final badge = Rect.fromLTWH(
        rect.left,
        rect.top,
        text.width + 6 * dpr,
        text.height + 2 * dpr,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(badge, Radius.circular(2 * dpr)),
        badgeFill,
      );
      text.paint(canvas, badge.topLeft + Offset(3 * dpr, 1 * dpr));
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(base.width, base.height);
    picture.dispose();
    return image;
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
      if (mode == 'changed-region') {
        return _handleChangedRegionCapture(params);
      }
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
      // Set-of-marks mode: number every visible interactable/field on the
      // image and return the number -> handle legend alongside the bytes.
      List<({int n, Rect rect})>? marks;
      List<Map<String, Object?>>? legend;
      var marksOmitted = 0;
      if (params['annotate'] == 'true') {
        final built = _buildCaptureMarks(
          region: rect?.inflate(padding),
          filter: params['annotateFilter'] ?? 'all',
        );
        marks = built.marks;
        legend = built.legend;
        marksOmitted = built.omitted;
      }
      final result = await _captureRegion(
        rect: rect,
        padding: padding,
        pixelRatio: pixelRatio,
        marks: marks,
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
        'marks': ?legend,
        if (marksOmitted > 0) 'marksOmitted': marksOmitted,
        'width': result.width,
        'height': result.height,
        'pixelRatio': result.pixelRatio,
        'rect': ?boundsJson,
      });
    } catch (error) {
      return _fail('capture_failed', error.toString());
    }
  }

  Future<developer.ServiceExtensionResponse> _handleChangedRegionCapture(
    Map<String, String> params,
  ) async {
    const maximumRegions = 16;
    const maximumPaddingLogical = 256.0;
    const maximumUnionAreaRatio = 0.50;
    const maximumOutputPixels = 4 * 1024 * 1024;
    const maximumOutputDimension = 4096;
    if (params['annotate'] == 'true') {
      return _fail(
        'changed_region_annotation_unsupported',
        'Changed-region capture cannot add marks because the marks would not be part of the snapshot-relative evidence.',
      );
    }
    if ((params['pixelRatio'] ?? '').isNotEmpty) {
      return _fail(
        'changed_region_pixel_ratio_override_unsupported',
        'Changed-region capture must use the current snapshot device pixel ratio.',
      );
    }
    if (params['native'] == 'on') {
      return _fail(
        'changed_region_native_capture_unsupported',
        'Native changed-region capture cannot be atomically bound to one Flutter snapshot. Use an in-app changed-region crop or a full native screenshot.',
        extra: const <String, Object?>{
          'nativeFallback': <String, Object?>{
            'status': 'unsupported',
            'reason': 'atomic_snapshot_binding_unavailable',
          },
        },
      );
    }
    final rawPadding = params['padding'] ?? '12';
    final padding = double.tryParse(rawPadding);
    if (padding == null ||
        !padding.isFinite ||
        padding < 0 ||
        padding > maximumPaddingLogical) {
      return _fail(
        'invalid_changed_region_padding',
        'Changed-region padding must be a finite logical-pixel value from 0 through 256.',
      );
    }

    final current = _snapshot();
    final lookup = _lookupNavigationSnapshot(
      current: current,
      requestedSnapshotId: params['since'] ?? '',
    );
    if (!lookup.ok) {
      return _fail(
        lookup.errorCode!,
        lookup.errorMessage!,
        extra: <String, Object?>{
          ..._navigationHistoryEvidence(current),
          'requestedSnapshotId': lookup.requestedSnapshotId,
          'reason': lookup.reason,
          'operation': 'capture_changed_region',
        },
      );
    }
    final baseline = lookup.baseline;
    final delta = _delta(baseline, current);
    final rawCoverage = delta['changedRegionCoverage'];
    final coverage = rawCoverage is Map
        ? <String, Object?>{
            for (final entry in rawCoverage.entries)
              entry.key.toString(): entry.value,
          }
        : const <String, Object?>{};
    final rawRegions = delta['changedRegions'];
    final regions = rawRegions is List
        ? rawRegions
              .whereType<Map>()
              .map((region) {
                return <String, Object?>{
                  for (final entry in region.entries)
                    entry.key.toString(): entry.value,
                };
              })
              .toList(growable: false)
        : const <Map<String, Object?>>[];
    final issues = coverage['issues'] is List
        ? (coverage['issues']! as List).map((issue) => issue.toString()).toSet()
        : const <String>{};
    String? coverageErrorCode;
    String? coverageErrorMessage;
    if (issues.contains('coordinate_frame_changed_or_unavailable')) {
      coverageErrorCode = 'changed_region_coordinate_frame_unavailable';
      coverageErrorMessage =
          'The baseline and current snapshots do not share one trustworthy logical/physical coordinate frame.';
    } else if (issues.contains('screen_or_route_changed')) {
      coverageErrorCode = 'changed_region_scope_ambiguous';
      coverageErrorMessage =
          'The screen or route changed, so a local crop would not truthfully represent the changed surface. Use a full screenshot.';
    } else if (issues.contains('ambiguous_geometry')) {
      coverageErrorCode = 'changed_region_geometry_ambiguous';
      coverageErrorMessage =
          'At least one changed semantic identity maps to ambiguous geometry.';
    } else if (issues.contains('unavailable_geometry') ||
        issues.contains('region_list_truncated')) {
      coverageErrorCode = 'changed_region_geometry_unavailable';
      coverageErrorMessage =
          'Complete geometry is unavailable for every changed visible semantic region.';
    } else if (issues.contains('no_visible_changed_region') ||
        regions.isEmpty) {
      coverageErrorCode = 'changed_region_unavailable';
      coverageErrorMessage =
          'No visible semantic changed region exists for the requested snapshot baseline.';
    }
    if (coverage['status'] != 'complete' || coverageErrorCode != null) {
      return _fail(
        coverageErrorCode ?? 'changed_region_geometry_unavailable',
        coverageErrorMessage ??
            'Changed-region geometry coverage is incomplete.',
        extra: <String, Object?>{
          'operation': 'capture_changed_region',
          'requestedSnapshotId': lookup.requestedSnapshotId,
          'baselineScope': <String, Object?>{
            'runId': lookup.baselineRecord!.runId,
            'runtimeInstanceId': lookup.baselineRecord!.runtimeInstanceId,
            'stateGeneration': baseline.stateGeneration,
            'snapshotId': baseline.snapshotId,
          },
          'currentScope': _targetScope(current),
          'changedRegionCoverage': coverage,
        },
      );
    }
    final reportedTotal = coverage['totalRegionCount'];
    if (reportedTotal is! int ||
        reportedTotal != regions.length ||
        reportedTotal > maximumRegions) {
      return _fail(
        'changed_region_count_exceeded',
        'Changed-region capture is limited to $maximumRegions complete regions.',
        extra: <String, Object?>{
          'regionCount': reportedTotal,
          'returnedRegionCount': regions.length,
          'maximumRegions': maximumRegions,
          'changedRegionCoverage': coverage,
        },
      );
    }
    final viewport = Offset.zero & current.logicalSize;
    Rect? union;
    for (final region in regions) {
      final rect = _changedRegionRectFromJson(region['logicalRect']);
      if (rect == null ||
          !_validChangedRegionRect(rect) ||
          rect.left < viewport.left ||
          rect.top < viewport.top ||
          rect.right > viewport.right ||
          rect.bottom > viewport.bottom) {
        return _fail(
          'changed_region_geometry_unavailable',
          'A reported changed region is outside the exact current Flutter viewport.',
          extra: <String, Object?>{
            'region': region,
            'logicalViewport': <double>[
              viewport.left,
              viewport.top,
              viewport.width,
              viewport.height,
            ],
          },
        );
      }
      union = union == null ? rect : union.expandToInclude(rect);
    }
    if (union == null || !_validChangedRegionRect(union)) {
      return _fail(
        'changed_region_unavailable',
        'The changed regions do not form a usable logical crop.',
      );
    }
    final paddedUnion = union.inflate(padding).intersect(viewport);
    final viewportArea = viewport.width * viewport.height;
    final unionAreaRatio = viewportArea <= 0
        ? double.infinity
        : (paddedUnion.width * paddedUnion.height) / viewportArea;
    if (!unionAreaRatio.isFinite || unionAreaRatio > maximumUnionAreaRatio) {
      return _fail(
        'changed_region_union_too_large',
        'The padded changed-region union exceeds 50% of the current viewport. Use a full screenshot.',
        extra: <String, Object?>{
          'unionAreaRatio': unionAreaRatio.isFinite ? unionAreaRatio : null,
          'maximumUnionAreaRatio': maximumUnionAreaRatio,
          'logicalUnionRect': _rectToList(union),
          'logicalPaddedRect': _rectToList(paddedUnion),
        },
      );
    }
    final dpr = current.devicePixelRatio;
    final outputWidth = (paddedUnion.width * dpr).ceil();
    final outputHeight = (paddedUnion.height * dpr).ceil();
    final outputPixels = outputWidth * outputHeight;
    if (outputWidth <= 0 ||
        outputHeight <= 0 ||
        outputWidth > maximumOutputDimension ||
        outputHeight > maximumOutputDimension ||
        outputPixels > maximumOutputPixels) {
      return _fail(
        'changed_region_output_too_large',
        'The changed-region raster exceeds its bounded output dimensions or pixel count.',
        extra: <String, Object?>{
          'predictedPhysicalSize': <int>[outputWidth, outputHeight],
          'predictedOutputPixels': outputPixels,
          'maximumOutputDimension': maximumOutputDimension,
          'maximumOutputPixels': maximumOutputPixels,
        },
      );
    }
    if (current.captureBackend['status'] != 'available') {
      return _fail(
        'changed_region_capture_backend_unavailable',
        'The in-app capture backend was unavailable in the scoped current snapshot.',
        extra: <String, Object?>{
          'captureBackend': current.captureBackend,
          'currentScope': _targetScope(current),
        },
      );
    }

    final result = await _captureRegion(rect: union, padding: padding);
    final verified = _snapshot();
    if (verified.snapshotId != current.snapshotId) {
      return _fail(
        'changed_region_snapshot_changed_during_capture',
        'The app changed while the region was rasterized, so Scout discarded the image.',
        extra: <String, Object?>{
          'requestedSnapshotId': lookup.requestedSnapshotId,
          'captureStartScope': _targetScope(current),
          'captureEndScope': _targetScope(verified),
          'captureStartIdle': current.idle,
          'captureEndIdle': verified.idle,
          'captureStartBackend': current.captureBackend,
          'captureEndBackend': verified.captureBackend,
          'captureStateDelta': _delta(current, verified),
          'dispatch': 'not_applicable_read_only',
        },
      );
    }
    if (result.needsNative) {
      return _fail(
        'changed_region_native_capture_required',
        'A platform view overlaps the changed region. Scout will not guess or race a native crop outside the snapshot-bound helper request.',
        extra: <String, Object?>{
          'requestedSnapshotId': lookup.requestedSnapshotId,
          'currentScope': _targetScope(current),
          'logicalPaddedRect': _rectToList(paddedUnion),
          'nativeFallback': const <String, Object?>{
            'status': 'unsupported',
            'reason': 'atomic_snapshot_binding_unavailable',
            'nextBestAction': 'capture_full_native_screenshot',
          },
        },
      );
    }
    if (result.bytes == null ||
        result.bounds == null ||
        !_sameRect(result.bounds, paddedUnion) ||
        (result.pixelRatio - dpr).abs() > 0.000001) {
      return _fail(
        'changed_region_capture_failed',
        'The in-app raster did not preserve the validated changed-region coordinate contract.',
        extra: <String, Object?>{
          'captureError': result.error,
          'expectedLogicalRect': _rectToList(paddedUnion),
          'actualLogicalRect': result.bounds == null
              ? null
              : _rectToList(result.bounds!),
          'expectedDevicePixelRatio': dpr,
          'actualDevicePixelRatio': result.pixelRatio,
        },
      );
    }
    final physicalRect = <double>[
      result.bounds!.left * dpr,
      result.bounds!.top * dpr,
      result.bounds!.width * dpr,
      result.bounds!.height * dpr,
    ];
    final captureIdentity = crypto.sha256
        .convert(
          utf8.encode(
            <String>[
              baseline.snapshotId,
              current.snapshotId,
              ..._rectToList(result.bounds!).map((value) => '$value'),
              '$dpr',
              'in_app_capture',
            ].join('|'),
          ),
        )
        .toString();
    return _ok(<String, Object?>{
      'operation': 'capture_changed_region',
      'mode': 'changed-region',
      'requestedSnapshotId': lookup.requestedSnapshotId,
      'baselineScope': <String, Object?>{
        'runId': lookup.baselineRecord!.runId,
        'runtimeInstanceId': lookup.baselineRecord!.runtimeInstanceId,
        'stateGeneration': baseline.stateGeneration,
        'snapshotId': baseline.snapshotId,
      },
      'currentScope': _targetScope(current),
      'captureVerifiedScope': _targetScope(verified),
      'semanticChanged': _changed(baseline, current),
      'changedRegions': regions,
      'changedRegionCoverage': coverage,
      'regionSelection': <String, Object?>{
        'strategy': 'bounded_union',
        'regionCount': regions.length,
        'logicalUnionRect': _rectToList(union),
        'logicalPaddedRect': _rectToList(result.bounds!),
        'physicalPaddedRect': physicalRect,
        'paddingLogical': padding,
        'unionAreaRatio': unionAreaRatio,
        'predictedOutputPixels': outputPixels,
        'bounds': const <String, Object?>{
          'maximumRegions': maximumRegions,
          'maximumPaddingLogical': maximumPaddingLogical,
          'maximumUnionAreaRatio': maximumUnionAreaRatio,
          'maximumOutputPixels': maximumOutputPixels,
          'maximumOutputDimension': maximumOutputDimension,
        },
      },
      'coordinateFrame': _changedRegionCoordinateFrame(current),
      'backend': 'in_app_capture',
      'captureBackend': current.captureBackend,
      'captureIdentity': captureIdentity,
      'needsNative': false,
      'bytes': base64Encode(result.bytes!),
      'width': result.width,
      'height': result.height,
      'pixelRatio': result.pixelRatio,
      'rect': _rectToList(result.bounds!),
      'limitations': const <String>[
        'Changed regions use semantic/render geometry rather than pixel differencing.',
        'Native fallback is unavailable because it cannot be atomically bound to this helper snapshot.',
      ],
    });
  }

  List<double> _rectToList(Rect value) => <double>[
    value.left,
    value.top,
    value.width,
    value.height,
  ];

  Map<String, Object?> _changedRegionCoordinateFrame(
    ScoutSnapshot snapshot,
  ) => <String, Object?>{
    'primarySpace': 'logical_flutter_points',
    'origin': 'flutter_view_top_left',
    'xDirection': 'right',
    'yDirection': 'down',
    'logicalViewport': <double>[
      0,
      0,
      snapshot.logicalSize.width,
      snapshot.logicalSize.height,
    ],
    'physicalViewport': <double>[
      0,
      0,
      snapshot.physicalSize.width,
      snapshot.physicalSize.height,
    ],
    'devicePixelRatio': snapshot.devicePixelRatio,
    'logicalToPhysicalScale': snapshot.devicePixelRatio,
    'viewMetricsAvailable': snapshot.viewMetricsAvailable,
    'provenance':
        'baseline_and_current_snapshot_render_geometry_with_current_flutter_view_metrics',
    'nativeImageContract': 'unsupported_for_snapshot_bound_changed_region',
  };

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
      'screenEvidence': snapshot.screenEvidence,
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
      // A restart resets the helper isolate. Include a timestamp so a new
      // human pin never collides with a durable CLI-session pin restored into
      // a later helper instance.
      id: 'ann_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_${_nextAnnotationId.toString().padLeft(3, '0')}',
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

  /// Rehydrates CLI-owned active annotations after a hot restart/full relaunch.
  /// Crops remain in the CLI session cache; the helper only needs enough
  /// metadata to draw/match the pin and capture a fresh after-crop on `fixed`.
  int restoreAnnotations(String? recordsJson) {
    if (recordsJson == null || recordsJson.isEmpty) return 0;
    final Object? decoded;
    try {
      decoded = jsonDecode(recordsJson);
    } catch (_) {
      return 0;
    }
    if (decoded is! List) return 0;
    var restored = 0;
    for (final raw in decoded) {
      if (raw is! Map) continue;
      final record = Map<String, dynamic>.from(raw);
      final annotation = _annotationFromJson(record);
      if (annotation == null ||
          _annotations.any((existing) => existing.id == annotation.id)) {
        continue;
      }
      _annotations.add(annotation);
      restored += 1;
    }
    if (restored > 0) _bumpAnnotationRevision();
    return restored;
  }

  ScoutAnnotation? _annotationFromJson(Map<String, dynamic> record) {
    final id = record['id']?.toString().trim();
    final comment = record['comment']?.toString();
    final status = record['status']?.toString();
    final targetRaw = record['target'];
    if (id == null ||
        id.isEmpty ||
        comment == null ||
        status == null ||
        targetRaw is! Map) {
      return null;
    }
    final target = _annotationTargetFromJson(
      Map<String, dynamic>.from(targetRaw),
    );
    if (target == null) return null;
    final createdAt = DateTime.tryParse(record['createdAt']?.toString() ?? '');
    final annotation = ScoutAnnotation(
      id: id,
      createdAt: createdAt ?? DateTime.now(),
      comment: comment,
      status: status,
      target: target,
    );
    annotation.updatedAt = DateTime.tryParse(
      record['updatedAt']?.toString() ?? '',
    );
    final note = record['note']?.toString().trim();
    annotation.note = note == null || note.isEmpty ? null : note;
    return annotation;
  }

  ScoutAnnotationTarget? _annotationTargetFromJson(Map<String, dynamic> json) {
    List<double>? rectFor(String key) {
      final raw = json[key];
      if (raw is! List || raw.length < 4) return null;
      final values = raw.take(4).map((value) => (value as num?)?.toDouble());
      if (values.any((value) => value == null)) return null;
      return values.cast<double>().toList(growable: false);
    }

    final rect = rectFor('rect');
    final visibleRect = rectFor('visibleRect') ?? rect;
    final id = json['id']?.toString().trim();
    final stableId = json['stableId']?.toString().trim();
    if (rect == null ||
        visibleRect == null ||
        id == null ||
        id.isEmpty ||
        stableId == null ||
        stableId.isEmpty) {
      return null;
    }
    return ScoutAnnotationTarget(
      id: id,
      stableId: stableId,
      kind: json['kind']?.toString() ?? 'widget',
      widgetType: json['widgetType']?.toString() ?? 'Widget',
      key: json['key']?.toString(),
      label: json['label']?.toString(),
      text: json['text']?.toString(),
      screen: json['screen']?.toString() ?? 'unknown',
      routeGuess: json['routeGuess']?.toString(),
      rect: Rect.fromLTWH(rect[0], rect[1], rect[2], rect[3]),
      visibleRect: Rect.fromLTWH(
        visibleRect[0],
        visibleRect[1],
        visibleRect[2],
        visibleRect[3],
      ),
      visibleFraction: (json['visibleFraction'] as num?)?.toDouble() ?? 1,
      depth: (json['depth'] as num?)?.toInt() ?? 0,
      ancestorSummary: json['ancestorSummary'] is List
          ? (json['ancestorSummary'] as List)
                .map((value) => value.toString())
                .toList(growable: false)
          : const [],
      scoutNodeId: json['scoutNodeId']?.toString(),
    );
  }

  /// Collects the ids targeted by a `delete` action from either `ids`
  /// (comma-separated, the CLI form) or a single `id`, de-duplicated and
  /// trimmed so the removed/notFound report has no blanks or repeats.
  List<String> _annotationDeleteIds(Map<String, String> params) {
    final ids = <String>[];
    for (final raw in [params['ids'], params['id']]) {
      if (raw == null) continue;
      for (final part in raw.split(',')) {
        final id = part.trim();
        if (id.isNotEmpty && !ids.contains(id)) ids.add(id);
      }
    }
    return ids;
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

  bool get _annotationOverlayUiActive => _annotationMode || _recording;

  bool get _launchSessionBadgeVisible =>
      _debugLaunchBadgeVisible ?? FlutterScoutRuntime._compiledRunId.isNotEmpty;

  bool get _annotationOverlayInteractive =>
      _debugForceOverlayInteractive ||
      (_annotationOverlayOptedIn && _annotationOverlayUiActive);

  bool get _annotationOverlayVisible =>
      _launchSessionBadgeVisible || _annotationOverlayInteractive;

  void _reconcileAnnotationOverlay() {
    if (_annotationOverlayVisible) {
      _scheduleAnnotationOverlayInstall();
      return;
    }
    _removeAnnotationOverlay();
  }

  void _scheduleAnnotationOverlayInstall({bool forceForTesting = false}) {
    if (!kDebugMode || (!_annotationOverlayVisible && !forceForTesting)) return;
    if (_annotationOverlayEntry != null) {
      if (_annotationOverlayHost?.mounted ?? false) return;
      // The Overlay that hosted the entry is gone (the app replaced its root
      // tree, or a test pumped a new one). Drop the stale reference so the
      // chrome reinstalls into the current tree; removing/disposing an entry
      // whose host state is already disposed is not safe, so just let it go.
      _annotationOverlayEntry = null;
      _annotationOverlayHost = null;
    }
    if (_annotationOverlayInstallScheduled) return;
    _annotationOverlayInstallScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _annotationOverlayInstallScheduled = false;
      _installAnnotationOverlayIfPossible(forceForTesting: forceForTesting);
    });
    // A post-frame callback alone never fires if the app is idle (no frames
    // scheduled) — common right after attach or in tests. Ask for one.
    WidgetsBinding.instance.scheduleFrame();
  }

  void _installAnnotationOverlayIfPossible({bool forceForTesting = false}) {
    if (!kDebugMode ||
        (!_annotationOverlayVisible && !forceForTesting) ||
        _annotationOverlayEntry != null) {
      return;
    }
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) {
      _scheduleAnnotationOverlayInstall(forceForTesting: forceForTesting);
      return;
    }
    final overlay = _findRootOverlay(root);
    if (overlay == null) {
      _scheduleAnnotationOverlayInstall(forceForTesting: forceForTesting);
      return;
    }
    _annotationOverlayEntry = OverlayEntry(
      builder: (context) => _FlutterScoutAnnotationOverlay(runtime: this),
    );
    _annotationOverlayHost = overlay;
    overlay.insert(_annotationOverlayEntry!);
  }

  void _removeAnnotationOverlay() {
    final entry = _annotationOverlayEntry;
    _annotationOverlayEntry = null;
    _annotationOverlayHost = null;
    _debugForceOverlayInteractive = false;
    if (entry == null) return;
    try {
      entry.remove();
      entry.dispose();
    } catch (_) {
      // A root replacement can dispose the host before Scout observes it.
      // Clearing our references is sufficient; the dead host owns cleanup.
    }
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
