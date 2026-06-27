part of 'flutter_scout_cli.dart';

// part: screenshot/crop commands, in-app capture call, and PNG cropping.

extension _CliCapture on FlutterScoutCli {
  Future<int> _screenshot(List<String> args) async {
    final parser = ArgParser()
      ..addOption('output', abbr: 'o')
      ..addOption('target')
      ..addFlag('native', defaultsTo: false);
    final parsed = parser.parse(args);
    final native = parsed.flag('native');
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
      final capture = await _inAppCapture(mode: 'screen');
      if (capture?.bytes != null) {
        File(output).writeAsBytesSync(capture!.bytes!);
        stdout.writeln(
          jsonEncode({
            'ok': true,
            'path': output,
            'backend': 'in_app_capture',
          }),
        );
        return 0;
      }
    }
    final capture = await _captureScreenshot(output);
    stdout.writeln(jsonEncode({'ok': true, 'path': output, ...capture}));
    return 0;
  }

  Future<int> _crop(List<String> args) async {
    final parser = ArgParser()
      ..addOption('target')
      ..addOption('output', abbr: 'o')
      ..addOption('padding', defaultsTo: '12')
      ..addFlag('native', defaultsTo: false);
    final parsed = parser.parse(args);
    final native = parsed.flag('native');
    final target =
        parsed.option('target') ??
        (parsed.rest.isEmpty ? null : parsed.rest.first);
    if (target == null || target.isEmpty) {
      throw const ScoutCliException(
        'usage',
        'Usage: flutter-scout crop <target> [-o <path>] [--native]',
      );
    }

    final inspect = await _call('ext.flutter_scout.inspect');
    final node = _findNodeInInspect(inspect, target);
    if (node == null) {
      throw ScoutCliException(
        'target_not_found',
        'No inspect target matched `$target`.',
      );
    }
    final rect = node['rect'];
    if (rect is! List || rect.length < 4) {
      throw ScoutCliException(
        'target_has_no_rect',
        'Target `$target` has no usable rect.',
      );
    }
    final rectNums = rect.cast<num>();
    _ensureSessionDir();
    final padding = int.tryParse(parsed.option('padding') ?? '') ?? 12;
    final output =
        parsed.option('output') ??
        p.join(
          _sessionDir.path,
          'crops',
          '${_safeFileName(target)}_${DateTime.now().millisecondsSinceEpoch}.png',
        );
    Directory(p.dirname(output)).createSync(recursive: true);

    if (!native) {
      final capture = await _inAppCapture(
        mode: 'crop',
        rect: rectNums,
        padding: padding,
      );
      if (capture?.bytes != null) {
        File(output).writeAsBytesSync(capture!.bytes!);
        stdout.writeln(
          jsonEncode({
            'ok': true,
            'target': target,
            'path': output,
            'rect': rect,
            'backend': 'in_app_capture',
          }),
        );
        return 0;
      }
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
    final dpr =
        (inspect['devicePixelRatio'] as num?)?.toDouble() ??
        _inferDevicePixelRatio(inspect, source);
    final crop = _cropPngBytes(source, rectNums, dpr, padding);
    File(output).writeAsBytesSync(crop.bytes);
    stdout.writeln(
      jsonEncode({
        'ok': true,
        'target': target,
        'path': output,
        'source': shotPath,
        'rect': rect,
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
    return (bytes: img.encodePng(cropped), pixelRect: [left, top, width, height]);
  }

  /// Asks the in-app helper to rasterise the screen (or a crop rect). Returns
  /// null when the capture extension is unavailable so callers fall back to a
  /// native screenshot.
  Future<({Uint8List? bytes, bool needsNative})?> _inAppCapture({
    required String mode,
    List<num>? rect,
    int? padding,
    String native = 'auto',
  }) async {
    try {
      final params = <String, String>{'mode': mode, 'native': native};
      if (rect != null && rect.length >= 4) {
        params['rect'] = '${rect[0]},${rect[1]},${rect[2]},${rect[3]}';
      }
      if (padding != null) {
        params['padding'] = padding.toString();
      }
      final res = await _call('ext.flutter_scout.capture', params);
      if (res['ok'] == false) return null;
      final needsNative = res['needsNative'] == true;
      final bytes = res['bytes'];
      if (bytes is String && bytes.isNotEmpty) {
        return (bytes: base64Decode(bytes), needsNative: needsNative);
      }
      if (needsNative) return (bytes: null, needsNative: true);
      return null;
    } catch (_) {
      return null;
    }
  }

}
