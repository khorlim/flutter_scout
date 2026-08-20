part of 'flutter_scout_cli.dart';

// part: screenshot/crop commands, in-app capture call, and PNG cropping.

extension _CliCapture on FlutterScoutCli {
  Future<int> _screenshot(List<String> args) async {
    final parser = ArgParser()
      ..addOption('output', abbr: 'o')
      ..addOption('target')
      ..addOption(
        'retention',
        defaultsTo: 'session',
        allowed: const ['session', '24h', '7d', 'manual'],
      )
      ..addFlag(
        'annotated',
        defaultsTo: false,
        help:
            'Set-of-marks capture: draw numbered marks over every visible '
            'interactable and print the number -> handle legend.',
      )
      ..addFlag('native', defaultsTo: false);
    final parsed = parser.parse(args);
    final native = parsed.flag('native');
    final annotated = parsed.flag('annotated');
    final retention = _retentionOption(parsed);
    final privacy = _privateArtifactMetadata(retention);
    final target = parsed.option('target');
    if (target != null && target.isNotEmpty) {
      return _crop([
        '--target',
        target,
        if (parsed.option('output') != null) ...[
          '--output',
          parsed.option('output')!,
        ],
        '--retention',
        retention,
        if (native) '--native',
      ]);
    }
    _ensureSessionDir();
    final output =
        parsed.option('output') ??
        p.join(
          _sessionDir.path,
          'screenshots',
          'screenshot_${DateTime.now().millisecondsSinceEpoch}.png',
        );
    _preparePrivateArtifactOutputParent(output);
    if (!native) {
      final capture = await _inAppCapture(mode: 'screen', annotate: annotated);
      if (capture?.bytes != null) {
        _writePrivateArtifactBytes(output, capture!.bytes!);
        _writePrivateArtifactMetadata(output, retention);
        _printJson({
          'ok': true,
          'path': output,
          'backend': 'in_app_capture',
          'metadata': '$output.metadata.json',
          ...privacy,
          if (annotated) 'marks': capture.marks ?? const <Object?>[],
        });
        return 0;
      }
    }
    if (annotated) {
      throw const ScoutCliException(
        'annotated_unsupported_native',
        'Set-of-marks screenshots require the in-app capture backend; it was '
            'unavailable for this session (platform view or capture failure).',
      );
    }
    final capture = await _captureScreenshot(output);
    _writePrivateArtifactMetadata(output, retention);
    _printJson({
      'ok': true,
      'path': output,
      ...capture,
      'metadata': '$output.metadata.json',
      ...privacy,
    });
    return 0;
  }

  Future<int> _crop(List<String> args) async {
    final parser = ArgParser()
      ..addOption('target')
      ..addOption(
        'text',
        help:
            'Crop around visible text. Use this when a label has no stable '
            'handle or starts with `-`.',
      )
      ..addOption(
        'rect',
        help: 'Explicit logical rect `x,y,w,h` instead of a target handle.',
      )
      ..addOption(
        'changed-since',
        help:
            'Capture the bounded union of complete semantic changed regions since one retained snapshot identity.',
      )
      ..addOption('output', abbr: 'o')
      ..addOption('padding', defaultsTo: '12')
      ..addOption(
        'retention',
        defaultsTo: 'session',
        allowed: const ['session', '24h', '7d', 'manual'],
      )
      ..addFlag(
        'contains',
        defaultsTo: false,
        negatable: false,
        help: 'For --text, allow case-insensitive containment matching.',
      )
      ..addFlag(
        'annotated',
        defaultsTo: false,
        help:
            'Draw numbered marks over interactables inside the region and '
            'print the number -> handle legend.',
      )
      ..addFlag('native', defaultsTo: false);
    final parsed = parser.parse(args);
    final native = parsed.flag('native');
    final annotated = parsed.flag('annotated');
    final retention = _retentionOption(parsed);
    final privacy = _privateArtifactMetadata(retention);
    final rectOption = parsed.option('rect');
    final textOption = parsed.option('text');
    final changedSince = parsed.option('changed-since');
    final target =
        parsed.option('target') ??
        (parsed.rest.isEmpty ? null : parsed.rest.first);
    if ((target == null || target.isEmpty) &&
        (textOption == null || textOption.isEmpty) &&
        (rectOption == null || rectOption.isEmpty) &&
        (changedSince == null || changedSince.isEmpty)) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout crop <target> [-o <path>] [--native], '
            'flutter-scout crop --text <visible text> [-o <path>], or '
            'flutter-scout crop --rect x,y,w,h [-o <path>], or '
            'flutter-scout crop --changed-since <snapshot-id> [-o <path>]',
      );
    }
    final selectorCount = [
      target != null && target.isNotEmpty,
      textOption != null && textOption.isNotEmpty,
      rectOption != null && rectOption.isNotEmpty,
      changedSince != null && changedSince.isNotEmpty,
    ].where((selected) => selected).length;
    if (selectorCount > 1) {
      throw const ScoutCliException(
        'usage',
        'Use only one crop selector: target, --text, --rect, or --changed-since.',
      );
    }
    if (changedSince != null && changedSince.isNotEmpty) {
      return _cropChangedSince(
        snapshotId: changedSince,
        outputOption: parsed.option('output'),
        paddingOption: parsed.option('padding'),
        retention: retention,
        native: native,
        annotated: annotated,
        contains: parsed.flag('contains'),
      );
    }

    Map<String, dynamic>? inspect;
    Map<String, Object?>? targetScope;
    Map<String, Object?>? targetCoordinateFrame;
    double? targetDevicePixelRatio;
    final List<num> rectNums;
    final String cropLabel;
    if (rectOption != null && rectOption.isNotEmpty) {
      final parts = rectOption
          .split(',')
          .map((part) => num.tryParse(part.trim()))
          .toList(growable: false);
      if (parts.length != 4 || parts.any((part) => part == null)) {
        throw const ScoutCliException(
          'usage',
          'Invalid --rect; expected four numbers: x,y,w,h (logical pixels).',
        );
      }
      rectNums = parts.cast<num>();
      if (rectNums.any((value) => !value.toDouble().isFinite) ||
          rectNums[0] < 0 ||
          rectNums[1] < 0 ||
          rectNums[2] <= 0 ||
          rectNums[3] <= 0) {
        throw const ScoutCliException(
          'invalid_crop_rect',
          'Crop rect values must be finite; x/y must be non-negative and '
              'width/height must be positive.',
        );
      }
      // The rect is in LOGICAL pixels; passing physical/DPR-scaled coords is a
      // common mistake that used to silently produce a full-screen capture
      // (the helper clamps an out-of-bounds rect to the whole screen). Catch
      // it here against the actual logical size so it fails loudly instead.
      inspect = await _call('ext.flutter_scout.inspect', {'brief': 'true'});
      targetCoordinateFrame = _coordinateFrameFromInspect(inspect);
      final size = inspect['logicalSize'];
      if (size is List && size.length >= 2) {
        final width = (size[0] as num).toDouble();
        final height = (size[1] as num).toDouble();
        final x = rectNums[0].toDouble();
        final y = rectNums[1].toDouble();
        final w = rectNums[2].toDouble();
        final h = rectNums[3].toDouble();
        if (w <= 0 || h <= 0 || x >= width || y >= height || x < 0 || y < 0) {
          throw ScoutCliException(
            'rect_out_of_bounds',
            '--rect $rectOption is outside the logical screen '
                '(${width.round()}x${height.round()}). Coordinates are LOGICAL '
                'pixels (not physical/DPR-scaled); check your x,y,w,h.',
          );
        }
      }
      cropLabel = 'rect_${rectNums[0]}_${rectNums[1]}';
    } else {
      final observation = await _locateUniqueReadNode(
        target: target,
        text: textOption,
        contains: parsed.flag('contains'),
      );
      final node = observation.node;
      targetScope = observation.scope;
      targetCoordinateFrame = observation.coordinateFrame;
      targetDevicePixelRatio = _nodeDevicePixelRatio(node);
      final rect = node['rect'];
      if (rect is! List || rect.length < 4) {
        throw ScoutCliException(
          'target_has_no_rect',
          'Target `$target` has no usable rect.',
        );
      }
      rectNums = rect.cast<num>();
      cropLabel = textOption != null && textOption.isNotEmpty
          ? 'text_$textOption'
          : target!;
    }
    _ensureSessionDir();
    final padding = int.tryParse(parsed.option('padding') ?? '') ?? 12;
    if (padding < 0 || padding > 4096) {
      throw const ScoutCliException(
        'invalid_crop_padding',
        'Crop padding must be an integer from 0 through 4096 physical pixels.',
      );
    }
    final output =
        parsed.option('output') ??
        p.join(
          _sessionDir.path,
          'crops',
          '${_safeFileName(cropLabel)}_${DateTime.now().millisecondsSinceEpoch}.png',
        );
    _preparePrivateArtifactOutputParent(output);

    if (!native) {
      final capture = await _inAppCapture(
        mode: 'crop',
        rect: rectNums,
        padding: padding,
        annotate: annotated,
      );
      if (capture?.bytes != null) {
        _writePrivateArtifactBytes(output, capture!.bytes!);
        _writePrivateArtifactMetadata(output, retention);
        _printJson({
          'ok': true,
          'target': target ?? (textOption == null ? 'rect:$rectOption' : null),
          if (textOption != null && textOption.isNotEmpty) 'text': textOption,
          'path': output,
          'rect': rectNums,
          'targetScope': ?targetScope,
          'coordinateFrame': targetCoordinateFrame,
          'backend': 'in_app_capture',
          'metadata': '$output.metadata.json',
          ...privacy,
          if (annotated) 'marks': capture.marks ?? const <Object?>[],
        });
        return 0;
      }
    }
    if (annotated) {
      throw const ScoutCliException(
        'annotated_unsupported_native',
        'Set-of-marks crops require the in-app capture backend; it was '
            'unavailable for this region (platform view or capture failure).',
      );
    }

    // Native fallback (forced via --native, or when in-app capture reports a
    // platform view in the region that would render blank).
    if (await _isMacosScreenshotSession()) {
      throw const ScoutCliException(
        'crop_unsupported_target',
        'Targeted crops are not supported for macOS window screenshots yet. Use flutter-scout screenshot -o <path> for a full macOS app-window capture.',
      );
    }
    final shotPath = p.join(
      _sessionDir.path,
      'screenshots',
      'crop_source_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    if (targetScope != null && targetDevicePixelRatio == null) {
      throw ScoutCliException(
        'target_geometry_scale_unavailable',
        'The uniquely resolved target does not include a trustworthy '
            'logical-to-physical scale, so a native crop cannot be '
            'materialized safely.',
        details: <String, Object?>{
          'target': target,
          if (textOption != null && textOption.isNotEmpty) 'text': textOption,
          'dispatch': 'not_applicable_read_only',
        },
        additional: <String, Object?>{'scope': targetScope},
      );
    }
    final nativeCapture = await _captureScreenshot(shotPath);
    _writePrivateArtifactMetadata(shotPath, retention);
    final source = img.decodeImage(File(shotPath).readAsBytesSync());
    if (source == null) {
      throw const ScoutCliException(
        'image_decode_failed',
        'Could not decode simulator screenshot.',
      );
    }
    final dpr = _validatedNativeCropDevicePixelRatio(
      coordinateFrame: targetCoordinateFrame,
      sourceWidth: source.width,
      sourceHeight: source.height,
      expectedNodeDevicePixelRatio: targetDevicePixelRatio,
      backend: nativeCapture['backend']?.toString() ?? 'native',
    );
    final crop = _cropPngBytes(source, rectNums, dpr, padding);
    _writePrivateArtifactBytes(output, crop.bytes);
    _writePrivateArtifactMetadata(output, retention);
    _printJson({
      'ok': true,
      'target': target ?? (textOption == null ? 'rect:$rectOption' : null),
      if (textOption != null && textOption.isNotEmpty) 'text': textOption,
      'path': output,
      'source': shotPath,
      'rect': rectNums,
      'targetScope': ?targetScope,
      'coordinateFrame': targetCoordinateFrame,
      'devicePixelRatio': dpr,
      'pixelRect': crop.pixelRect,
      'backend': nativeCapture['backend'] ?? 'native',
      'nativeCapture': nativeCapture,
      'coordinateTransform': <String, Object?>{
        'status': 'validated',
        'sourceFrame': 'helper_same_snapshot_coordinate_frame',
        'logicalToPhysicalScale': dpr,
        'physicalViewportMatchedImage': true,
      },
      'metadata': '$output.metadata.json',
      ...privacy,
    });
    return 0;
  }

  Future<int> _cropChangedSince({
    required String snapshotId,
    required String? outputOption,
    required String? paddingOption,
    required String retention,
    required bool native,
    required bool annotated,
    required bool contains,
  }) async {
    const maximumOutputBytes = 4 * 1024 * 1024;
    const maximumOutputPixels = 4 * 1024 * 1024;
    const maximumOutputDimension = 4096;
    const maximumRegions = 16;
    if (!RegExp(r'^g\d+:[a-f0-9]{64}$').hasMatch(snapshotId)) {
      throw const ScoutCliException(
        'invalid_snapshot_id',
        '--changed-since requires g<generation>:<64-lowercase-hex-digest>.',
      );
    }
    if (native) {
      throw const ScoutCliException(
        'changed_region_native_capture_unsupported',
        'Native changed-region capture cannot be atomically bound to one Flutter snapshot. Omit --native or capture a full native screenshot.',
      );
    }
    if (annotated || contains) {
      throw const ScoutCliException(
        'usage',
        '--changed-since cannot be combined with --annotated or --contains.',
      );
    }
    final padding = int.tryParse(paddingOption ?? '');
    if (padding == null || padding < 0 || padding > 256) {
      throw const ScoutCliException(
        'invalid_changed_region_padding',
        'Changed-region padding must be an integer from 0 through 256 logical pixels.',
      );
    }
    _ensureSessionDir();
    final output =
        outputOption ??
        p.join(
          _sessionDir.path,
          'crops',
          'changed_${DateTime.now().millisecondsSinceEpoch}.png',
        );
    _preparePrivateArtifactOutputParent(output);
    final capture = await _inAppCapture(
      mode: 'changed-region',
      since: snapshotId,
      padding: padding,
      native: 'off',
      failClosed: true,
    );
    if (capture?.bytes == null) {
      throw const ScoutCliException(
        'changed_region_capture_unavailable',
        'The helper returned no snapshot-bound changed-region raster.',
      );
    }
    final evidence = capture!.evidence;
    Map<String, Object?> map(Object? value) => value is Map
        ? <String, Object?>{
            for (final entry in value.entries)
              entry.key.toString(): entry.value,
          }
        : const <String, Object?>{};
    final baselineScope = map(evidence['baselineScope']);
    final currentScope = map(evidence['currentScope']);
    final verifiedScope = map(evidence['captureVerifiedScope']);
    final coverage = map(evidence['changedRegionCoverage']);
    final selection = map(evidence['regionSelection']);
    final frame = map(evidence['coordinateFrame']);
    final bounds = map(selection['bounds']);
    final currentSnapshotId = currentScope['snapshotId'];
    final verifiedSnapshotId = verifiedScope['snapshotId'];
    final captureIdentity = evidence['captureIdentity'];
    final regionCount = selection['regionCount'];
    final width = evidence['width'];
    final height = evidence['height'];
    final pixelRatio = evidence['pixelRatio'];
    final physicalRect = selection['physicalPaddedRect'];
    final logicalRect = selection['logicalPaddedRect'];
    final decoded = img.decodeImage(capture.bytes!);
    final responseIsBound =
        evidence['operation'] == 'capture_changed_region' &&
        evidence['mode'] == 'changed-region' &&
        evidence['backend'] == 'in_app_capture' &&
        evidence['needsNative'] == false &&
        evidence['requestedSnapshotId'] == snapshotId &&
        baselineScope['snapshotId'] == snapshotId &&
        currentSnapshotId is String &&
        RegExp(r'^g\d+:[a-f0-9]{64}$').hasMatch(currentSnapshotId) &&
        verifiedSnapshotId == currentSnapshotId &&
        baselineScope['runtimeInstanceId'] ==
            currentScope['runtimeInstanceId'] &&
        currentScope['runtimeInstanceId'] ==
            verifiedScope['runtimeInstanceId'] &&
        baselineScope['runId'] == currentScope['runId'] &&
        currentScope['runId'] == verifiedScope['runId'] &&
        coverage['status'] == 'complete' &&
        coverage['baselineSnapshotId'] == snapshotId &&
        coverage['currentSnapshotId'] == currentSnapshotId &&
        coverage['omittedRegionCount'] == 0 &&
        coverage['ambiguousGeometryCount'] == 0 &&
        coverage['unavailableGeometryCount'] == 0 &&
        regionCount is int &&
        regionCount > 0 &&
        regionCount <= maximumRegions &&
        selection['paddingLogical'] == padding &&
        selection['predictedOutputPixels'] == width * height &&
        bounds['maximumRegions'] == maximumRegions &&
        bounds['maximumPaddingLogical'] == 256.0 &&
        bounds['maximumOutputPixels'] == maximumOutputPixels &&
        bounds['maximumOutputDimension'] == maximumOutputDimension &&
        frame['origin'] == 'flutter_view_top_left' &&
        frame['viewMetricsAvailable'] == true &&
        pixelRatio is num &&
        pixelRatio.toDouble().isFinite &&
        pixelRatio > 0 &&
        width is int &&
        height is int &&
        width > 0 &&
        height > 0 &&
        width <= maximumOutputDimension &&
        height <= maximumOutputDimension &&
        width * height <= maximumOutputPixels &&
        decoded != null &&
        decoded.width == width &&
        decoded.height == height &&
        _validFourNumberList(logicalRect) &&
        _validFourNumberList(physicalRect) &&
        captureIdentity is String &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(captureIdentity) &&
        capture.bytes!.isNotEmpty &&
        capture.bytes!.length <= maximumOutputBytes;
    if (!responseIsBound ||
        !_physicalChangedRegionMatches(
          logicalRect as List,
          physicalRect as List,
          pixelRatio,
          width,
          height,
        )) {
      throw ScoutCliException(
        'changed_region_contract_invalid',
        'The helper response did not preserve the complete snapshot, geometry, and output bounds required for changed-region evidence.',
        details: <String, Object?>{
          'requestedSnapshotId': snapshotId,
          'baselineSnapshotId': baselineScope['snapshotId'],
          'currentSnapshotId': currentSnapshotId,
          'verifiedSnapshotId': verifiedSnapshotId,
          'coverageStatus': coverage['status'],
          'regionCount': regionCount,
          'backend': evidence['backend'],
        },
      );
    }
    final validatedWidth = width;
    final validatedHeight = height;
    final validatedPixelRatio = pixelRatio;
    _writePrivateArtifactBytes(output, capture.bytes!);
    _writePrivateArtifactMetadata(output, retention);
    _printJson(<String, Object?>{
      'ok': true,
      'changedSince': snapshotId,
      'path': output,
      'backend': 'in_app_capture',
      'captureIdentity': captureIdentity,
      'snapshotProvenance': <String, Object?>{
        'baseline': baselineScope,
        'current': currentScope,
        'captureVerified': verifiedScope,
      },
      'changedRegions': evidence['changedRegions'],
      'changedRegionCoverage': coverage,
      'regionSelection': selection,
      'coordinateFrame': frame,
      'devicePixelRatio': validatedPixelRatio,
      'logicalRect': logicalRect,
      'physicalRect': physicalRect,
      'pixelSize': <int>[validatedWidth, validatedHeight],
      'captureBackend': evidence['captureBackend'],
      'limitations': evidence['limitations'],
      'metadata': '$output.metadata.json',
      ..._privateArtifactMetadata(retention),
    });
    return 0;
  }

  bool _validFourNumberList(Object? value) {
    if (value is! List || value.length != 4) return false;
    final numbers = value.whereType<num>().map((item) => item.toDouble());
    if (numbers.length != 4 || numbers.any((item) => !item.isFinite)) {
      return false;
    }
    return (value[2] as num) > 0 && (value[3] as num) > 0;
  }

  bool _physicalChangedRegionMatches(
    List logical,
    List physical,
    num rawDevicePixelRatio,
    int width,
    int height,
  ) {
    final dpr = rawDevicePixelRatio.toDouble();
    for (var index = 0; index < 4; index++) {
      final logicalValue = (logical[index] as num).toDouble();
      final physicalValue = (physical[index] as num).toDouble();
      if ((logicalValue * dpr - physicalValue).abs() > 0.5) return false;
    }
    final expectedWidth = (physical[2] as num).toDouble();
    final expectedHeight = (physical[3] as num).toDouble();
    return (expectedWidth - width).abs() <= 1 &&
        (expectedHeight - height).abs() <= 1;
  }

  /// Resolves a crop/bounds target through the helper's central ranked
  /// resolver. Read-only visual commands must abstain on duplicate or fuzzy
  /// ambiguity too: selecting the first local JSON match can produce evidence
  /// for the wrong control even though it does not mutate the app.
  Future<
    ({
      Map<String, dynamic> node,
      Map<String, Object?> scope,
      Map<String, Object?> coordinateFrame,
    })
  >
  _locateUniqueReadNode({
    String? target,
    String? text,
    bool contains = false,
  }) async {
    final hasTarget = target != null && target.isNotEmpty;
    final hasText = text != null && text.isNotEmpty;
    if (hasTarget == hasText) {
      throw const ScoutCliException(
        'invalid_navigation_query',
        'Exactly one read-only target or text query is required.',
      );
    }
    final located = await _call('ext.flutter_scout.inspect', <String, String>{
      'navigationAction': 'locate',
      if (hasTarget) 'target': target,
      if (hasText) 'text': text,
      if (contains) 'contains': 'true',
      'maxCandidates': '20',
      'maxResponseBytes': '65536',
    });
    final rawResolution = located['resolution'];
    final resolution = rawResolution is Map
        ? <String, Object?>{
            for (final entry in rawResolution.entries)
              entry.key.toString(): entry.value,
          }
        : const <String, Object?>{};
    final status = resolution['status']?.toString();
    if (located['ok'] == false || status != 'unique') {
      final rawError = located['structuredError'] ?? located['error'];
      final error = rawError is Map
          ? <String, Object?>{
              for (final entry in rawError.entries)
                entry.key.toString(): entry.value,
            }
          : const <String, Object?>{};
      throw ScoutCliException(
        error['code']?.toString() ??
            (status == 'ambiguous' ? 'target_ambiguous' : 'target_not_found'),
        error['message']?.toString() ??
            'The read-only target could not be resolved uniquely.',
        details: <String, Object?>{
          'resolutionStatus': status ?? 'unavailable',
          'query': hasText ? text : target,
          'queryKind': hasText ? 'text' : 'target',
          'dispatch': 'not_applicable_read_only',
        },
        additional: <String, Object?>{
          'resolution': resolution,
          if (located['scope'] != null) 'scope': located['scope'],
          if (located['stoppingReason'] != null)
            'stoppingReason': located['stoppingReason'],
        },
      );
    }
    final rawNode = hasText
        ? resolution['textTarget'] ?? resolution['target']
        : resolution['target'];
    if (rawNode is! Map) {
      throw ScoutCliException(
        'target_observation_unavailable',
        'The helper reported a unique target without usable node evidence.',
        details: <String, Object?>{
          'resolutionStatus': status,
          'dispatch': 'not_applicable_read_only',
        },
        additional: <String, Object?>{'resolution': resolution},
      );
    }
    final rawScope = resolution['scope'] ?? located['scope'];
    final scope = rawScope is Map
        ? <String, Object?>{
            for (final entry in rawScope.entries)
              entry.key.toString(): entry.value,
          }
        : const <String, Object?>{};
    final runId = scope['runId'];
    final runtimeInstanceId = scope['runtimeInstanceId'];
    final stateGeneration = scope['stateGeneration'];
    final snapshotId = scope['snapshotId'];
    if (runId is! String ||
        runId.isEmpty ||
        runtimeInstanceId is! String ||
        runtimeInstanceId.isEmpty ||
        stateGeneration is! int ||
        stateGeneration < 0 ||
        snapshotId is! String ||
        !RegExp(r'^g\d+:[a-f0-9]{64}$').hasMatch(snapshotId)) {
      throw ScoutCliException(
        'target_observation_scope_unavailable',
        'The helper reported a unique target without a complete run, runtime, '
            'generation, and snapshot scope.',
        details: const <String, Object?>{
          'dispatch': 'not_applicable_read_only',
        },
        additional: <String, Object?>{'scope': scope},
      );
    }
    final rawCoordinateFrame = located['coordinateFrame'];
    final coordinateFrame = rawCoordinateFrame is Map
        ? <String, Object?>{
            for (final entry in rawCoordinateFrame.entries)
              entry.key.toString(): entry.value,
          }
        : const <String, Object?>{};
    return (
      node: <String, dynamic>{
        for (final entry in rawNode.entries) entry.key.toString(): entry.value,
      },
      scope: scope,
      coordinateFrame: coordinateFrame,
    );
  }

  Map<String, Object?> _coordinateFrameFromInspect(
    Map<String, dynamic> inspect,
  ) {
    final rawViewport = inspect['viewport'];
    final viewport = rawViewport is Map
        ? <String, Object?>{
            for (final entry in rawViewport.entries)
              entry.key.toString(): entry.value,
          }
        : const <String, Object?>{};
    final logicalSize = viewport['logicalSize'] ?? inspect['logicalSize'];
    final physicalSize = viewport['physicalSize'];
    return <String, Object?>{
      'primarySpace': 'logical_flutter_points',
      'origin': 'flutter_view_top_left',
      'xDirection': 'right',
      'yDirection': 'down',
      'logicalViewport': logicalSize is List && logicalSize.length >= 2
          ? <Object?>[0, 0, logicalSize[0], logicalSize[1]]
          : null,
      'physicalViewport': physicalSize is List && physicalSize.length >= 2
          ? <Object?>[0, 0, physicalSize[0], physicalSize[1]]
          : null,
      'devicePixelRatio': viewport['logicalToPhysicalScale'],
      'logicalToPhysicalScale': viewport['logicalToPhysicalScale'],
      'viewMetricsAvailable': viewport['available'] == true,
      'provenance': viewport['available'] == true
          ? 'flutter_view_physical_size_and_device_pixel_ratio'
          : 'unavailable',
      'nativeImageContract':
          'display_top_left_and_exact_physical_viewport_dimensions_required',
    };
  }

  double _validatedNativeCropDevicePixelRatio({
    required Map<String, Object?>? coordinateFrame,
    required int sourceWidth,
    required int sourceHeight,
    required double? expectedNodeDevicePixelRatio,
    required String backend,
  }) {
    final frame = coordinateFrame;
    final logical = frame?['logicalViewport'];
    final physical = frame?['physicalViewport'];
    final rawScale = frame?['logicalToPhysicalScale'];
    final scale = rawScale is num ? rawScale.toDouble() : null;
    final rawDevicePixelRatio = frame?['devicePixelRatio'];
    final devicePixelRatio = rawDevicePixelRatio is num
        ? rawDevicePixelRatio.toDouble()
        : null;
    final metricsAvailable = frame?['viewMetricsAvailable'] == true;
    final origin = frame?['origin']?.toString();
    final coordinateConventionValid =
        frame?['primarySpace'] == 'logical_flutter_points' &&
        origin == 'flutter_view_top_left' &&
        frame?['xDirection'] == 'right' &&
        frame?['yDirection'] == 'down' &&
        frame?['provenance'] ==
            'flutter_view_physical_size_and_device_pixel_ratio';
    final logicalValues = logical is List && logical.length >= 4
        ? logical
              .take(4)
              .whereType<num>()
              .map((value) => value.toDouble())
              .toList()
        : const <double>[];
    final physicalValues = physical is List && physical.length >= 4
        ? physical
              .take(4)
              .whereType<num>()
              .map((value) => value.toDouble())
              .toList()
        : const <double>[];
    final validNumbers =
        logicalValues.length == 4 &&
        physicalValues.length == 4 &&
        logicalValues.every((value) => value.isFinite) &&
        physicalValues.every((value) => value.isFinite) &&
        scale != null &&
        scale.isFinite &&
        scale > 0 &&
        devicePixelRatio != null &&
        devicePixelRatio.isFinite &&
        devicePixelRatio > 0 &&
        (devicePixelRatio - scale).abs() <= 0.000001;
    final exactTopLeft =
        validNumbers &&
        logicalValues[0] == 0 &&
        logicalValues[1] == 0 &&
        physicalValues[0] == 0 &&
        physicalValues[1] == 0 &&
        coordinateConventionValid;
    final dimensionsMatch =
        exactTopLeft &&
        physicalValues[2] == sourceWidth.toDouble() &&
        physicalValues[3] == sourceHeight.toDouble() &&
        (logicalValues[2] * scale - physicalValues[2]).abs() <= 0.5 &&
        (logicalValues[3] * scale - physicalValues[3]).abs() <= 0.5;
    final nodeScaleMatches =
        expectedNodeDevicePixelRatio == null ||
        (scale != null &&
            (expectedNodeDevicePixelRatio - scale).abs() <= 0.000001);
    if (!metricsAvailable || !dimensionsMatch || !nodeScaleMatches) {
      throw ScoutCliException(
        'native_crop_coordinate_frame_mismatch',
        'Scout will not guess a native crop transform because the helper '
            'physical viewport does not exactly match the captured image.',
        details: <String, Object?>{
          'dispatch': 'not_applicable_read_only',
          'backend': backend,
          'viewMetricsAvailable': metricsAvailable,
          'helperOrigin': origin ?? 'unavailable',
          'coordinateConventionValid': coordinateConventionValid,
          'capturedImageSize': <int>[sourceWidth, sourceHeight],
          if (physicalValues.length == 4)
            'helperPhysicalViewport': physicalValues,
          'nodeScaleMatchesFrame': nodeScaleMatches,
        },
        additional: <String, Object?>{
          'coordinateFrame': frame ?? const <String, Object?>{},
          'limitation':
              'System chrome, window insets, rotation, or letterboxing can make native display pixels differ from Flutter view pixels.',
        },
      );
    }
    return scale;
  }

  double? _nodeDevicePixelRatio(Map<String, dynamic> node) {
    final spaces = node['geometryCoordinateSpaces'];
    if (spaces is! Map) return null;
    final raw = spaces['devicePixelRatio'];
    if (raw is! num) return null;
    final value = raw.toDouble();
    return value.isFinite && value > 0 ? value : null;
  }

  /// Crops [rectLogical] (logical [l,t,w,h]) out of a decoded native
  /// screenshot, scaling by [dpr] and inflating by [padding] device pixels.
  ({Uint8List bytes, List<int> pixelRect}) _cropPngBytes(
    img.Image source,
    List<num> rectLogical,
    double dpr,
    int padding,
  ) {
    final left = ((rectLogical[0].toDouble() * dpr) - padding).floor().clamp(
      0,
      source.width - 1,
    );
    final top = ((rectLogical[1].toDouble() * dpr) - padding).floor().clamp(
      0,
      source.height - 1,
    );
    final width = (((rectLogical[2].toDouble() * dpr) + padding * 2).ceil())
        .clamp(1, source.width - left);
    final height = (((rectLogical[3].toDouble() * dpr) + padding * 2).ceil())
        .clamp(1, source.height - top);
    final cropped = img.copyCrop(
      source,
      x: left,
      y: top,
      width: width,
      height: height,
    );
    return (
      bytes: img.encodePng(cropped),
      pixelRect: [left, top, width, height],
    );
  }

  /// Asks the in-app helper to rasterise the screen (or a crop rect). Returns
  /// null when the capture extension is unavailable so callers fall back to a
  /// native screenshot.
  Future<
    ({
      Uint8List? bytes,
      bool needsNative,
      List<Object?>? marks,
      int marksOmitted,
      Map<String, dynamic> evidence,
    })?
  >
  _inAppCapture({
    required String mode,
    List<num>? rect,
    String? since,
    int? padding,
    String native = 'auto',
    bool annotate = false,
    String annotateFilter = 'all',
    bool failClosed = false,
  }) async {
    try {
      final params = <String, String>{'mode': mode, 'native': native};
      if (rect != null && rect.length >= 4) {
        params['rect'] = '${rect[0]},${rect[1]},${rect[2]},${rect[3]}';
      }
      if (padding != null) {
        params['padding'] = padding.toString();
      }
      if (since != null && since.isNotEmpty) {
        params['since'] = since;
      }
      if (annotate) {
        params['annotate'] = 'true';
        params['annotateFilter'] = annotateFilter;
      }
      final res = await _call('ext.flutter_scout.capture', params);
      if (res['ok'] == false) {
        if (!failClosed) return null;
        final rawError = res['structuredError'] ?? res['error'];
        final error = rawError is Map
            ? <String, Object?>{
                for (final entry in rawError.entries)
                  entry.key.toString(): entry.value,
              }
            : const <String, Object?>{};
        final rawDetails = error['details'];
        throw ScoutCliException(
          error['code']?.toString() ?? 'changed_region_capture_failed',
          error['message']?.toString() ??
              'The helper rejected changed-region capture.',
          details: rawDetails is Map
              ? <String, Object?>{
                  for (final entry in rawDetails.entries)
                    entry.key.toString(): entry.value,
                }
              : const <String, Object?>{},
          additional: <String, Object?>{
            for (final entry in res.entries)
              if (!const <String>{
                'bytes',
                'result',
                'structuredError',
                'error',
              }.contains(entry.key))
                entry.key: entry.value,
          },
        );
      }
      final needsNative = res['needsNative'] == true;
      final marks = res['marks'] is List ? res['marks'] as List<Object?> : null;
      final marksOmitted = res['marksOmitted'] is int
          ? res['marksOmitted'] as int
          : 0;
      final bytes = res['bytes'];
      if (bytes is String && bytes.isNotEmpty) {
        return (
          bytes: base64Decode(bytes),
          needsNative: needsNative,
          marks: marks,
          marksOmitted: marksOmitted,
          evidence: res,
        );
      }
      if (needsNative) {
        return (
          bytes: null,
          needsNative: true,
          marks: marks,
          marksOmitted: marksOmitted,
          evidence: res,
        );
      }
      return null;
    } catch (error) {
      if (failClosed) {
        if (error is ScoutCliException) rethrow;
        throw ScoutCliException(
          'changed_region_capture_failed',
          'Changed-region capture failed before a complete snapshot-bound raster was available.',
          details: <String, Object?>{
            'failureType': error.runtimeType.toString(),
          },
        );
      }
      return null;
    }
  }
}
