part of 'flutter_scout_cli.dart';

// part: screenshot/crop commands, in-app capture call, and PNG cropping.

extension _CliCapture on FlutterScoutCli {
  Future<int> _screenshot(List<String> args) async {
    final parser = ArgParser()
      ..addOption('output', abbr: 'o')
      ..addOption('target')
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
    final target = parsed.option('target');
    if (target != null && target.isNotEmpty) {
      return _crop([
        '--target',
        target,
        if (parsed.option('output') != null) ...[
          '--output',
          parsed.option('output')!,
        ],
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
    Directory(p.dirname(output)).createSync(recursive: true);
    if (!native) {
      final capture = await _inAppCapture(mode: 'screen', annotate: annotated);
      if (capture?.bytes != null) {
        File(output).writeAsBytesSync(capture!.bytes!);
        stdout.writeln(
          jsonEncode({
            'ok': true,
            'path': output,
            'backend': 'in_app_capture',
            if (annotated) 'marks': capture.marks ?? const <Object?>[],
          }),
        );
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
    stdout.writeln(jsonEncode({'ok': true, 'path': output, ...capture}));
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
      ..addOption('output', abbr: 'o')
      ..addOption('padding', defaultsTo: '12')
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
    final rectOption = parsed.option('rect');
    final textOption = parsed.option('text');
    final target =
        parsed.option('target') ??
        (parsed.rest.isEmpty ? null : parsed.rest.first);
    if ((target == null || target.isEmpty) &&
        (textOption == null || textOption.isEmpty) &&
        (rectOption == null || rectOption.isEmpty)) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout crop <target> [-o <path>] [--native], '
            'flutter-scout crop --text <visible text> [-o <path>], or '
            'flutter-scout crop --rect x,y,w,h [-o <path>]',
      );
    }
    final selectorCount = [
      target != null && target.isNotEmpty,
      textOption != null && textOption.isNotEmpty,
      rectOption != null && rectOption.isNotEmpty,
    ].where((selected) => selected).length;
    if (selectorCount > 1) {
      throw const ScoutCliException(
        'usage',
        'Use only one crop selector: target, --text, or --rect.',
      );
    }

    Map<String, dynamic>? inspect;
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
      // The rect is in LOGICAL pixels; passing physical/DPR-scaled coords is a
      // common mistake that used to silently produce a full-screen capture
      // (the helper clamps an out-of-bounds rect to the whole screen). Catch
      // it here against the actual logical size so it fails loudly instead.
      inspect = await _call('ext.flutter_scout.inspect', {'brief': 'true'});
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
      inspect = await _call('ext.flutter_scout.inspect');
      final node = textOption != null && textOption.isNotEmpty
          ? _findTextNodeInInspect(
              inspect,
              textOption,
              contains: parsed.flag('contains'),
            )
          : _findNodeInInspect(inspect, target!);
      if (node == null) {
        throw ScoutCliException(
          'target_not_found',
          textOption != null && textOption.isNotEmpty
              ? 'No visible text target matched `$textOption`.'
              : 'No inspect target matched `$target`.',
        );
      }
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
    final output =
        parsed.option('output') ??
        p.join(
          _sessionDir.path,
          'crops',
          '${_safeFileName(cropLabel)}_${DateTime.now().millisecondsSinceEpoch}.png',
        );
    Directory(p.dirname(output)).createSync(recursive: true);

    if (!native) {
      final capture = await _inAppCapture(
        mode: 'crop',
        rect: rectNums,
        padding: padding,
        annotate: annotated,
      );
      if (capture?.bytes != null) {
        File(output).writeAsBytesSync(capture!.bytes!);
        stdout.writeln(
          jsonEncode({
            'ok': true,
            'target':
                target ?? (textOption == null ? 'rect:$rectOption' : null),
            if (textOption != null && textOption.isNotEmpty) 'text': textOption,
            'path': output,
            'rect': rectNums,
            'backend': 'in_app_capture',
            if (annotated) 'marks': capture.marks ?? const <Object?>[],
          }),
        );
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
    await _captureScreenshot(shotPath);
    final source = img.decodeImage(File(shotPath).readAsBytesSync());
    if (source == null) {
      throw const ScoutCliException(
        'image_decode_failed',
        'Could not decode simulator screenshot.',
      );
    }
    // `inspect` was already fetched above (rect-bounds check or target
    // resolution), so it is available here for the device pixel ratio.
    final dpr =
        (inspect['devicePixelRatio'] as num?)?.toDouble() ??
        _inferDevicePixelRatio(inspect, source);
    final crop = _cropPngBytes(source, rectNums, dpr, padding);
    File(output).writeAsBytesSync(crop.bytes);
    stdout.writeln(
      jsonEncode({
        'ok': true,
        'target': target ?? (textOption == null ? 'rect:$rectOption' : null),
        if (textOption != null && textOption.isNotEmpty) 'text': textOption,
        'path': output,
        'source': shotPath,
        'rect': rectNums,
        'pixelRect': crop.pixelRect,
        'backend': 'native',
      }),
    );
    return 0;
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
    })?
  >
  _inAppCapture({
    required String mode,
    List<num>? rect,
    int? padding,
    String native = 'auto',
    bool annotate = false,
    String annotateFilter = 'all',
  }) async {
    try {
      final params = <String, String>{'mode': mode, 'native': native};
      if (rect != null && rect.length >= 4) {
        params['rect'] = '${rect[0]},${rect[1]},${rect[2]},${rect[3]}';
      }
      if (padding != null) {
        params['padding'] = padding.toString();
      }
      if (annotate) {
        params['annotate'] = 'true';
        params['annotateFilter'] = annotateFilter;
      }
      final res = await _call('ext.flutter_scout.capture', params);
      if (res['ok'] == false) return null;
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
        );
      }
      if (needsNative) {
        return (
          bytes: null,
          needsNative: true,
          marks: marks,
          marksOmitted: marksOmitted,
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
