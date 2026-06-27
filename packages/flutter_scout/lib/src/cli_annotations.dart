part of 'flutter_scout_cli.dart';

// part: annotations command + crop materialization (list/wait/fixed, crop cache + native fallback).

extension _CliAnnotations on FlutterScoutCli {
  Future<int> _bounds(List<String> args) async {
    final parser = ArgParser()..addOption('target');
    final parsed = parser.parse(args);
    final target =
        parsed.option('target') ??
        (parsed.rest.isEmpty ? null : parsed.rest.first);
    final inspect = await _call('ext.flutter_scout.inspect');
    final nodes = [
      ..._nodesFromInspect(inspect, 'interactables'),
      ..._nodesFromInspect(inspect, 'fields'),
      ..._nodesFromInspect(inspect, 'textTargets'),
    ];
    final dpr = (inspect['devicePixelRatio'] as num?)?.toDouble() ?? 1;
    if (target != null && target.isNotEmpty) {
      final node = _findNodeInInspect(inspect, target);
      if (node == null) {
        throw ScoutCliException(
          'target_not_found',
          'No inspect target matched `$target`.',
        );
      }
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert({
          'ok': true,
          'target': target,
          'devicePixelRatio': dpr,
          'bounds': _boundsForNode(node, dpr),
        }),
      );
      return 0;
    }
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'ok': true,
        'devicePixelRatio': dpr,
        'logicalSize': inspect['logicalSize'],
        'bounds': [for (final node in nodes) _boundsForNode(node, dpr)],
      }),
    );
    return 0;
  }

  Future<int> _annotations(List<String> args) async {
    final action = args.isEmpty ? 'list' : args.first;
    const usage =
        'Usage: flutter-scout annotations [list|targets|enable|disable|clear|resolve|dismiss|reopen|fixed|check|wait|signal-handoff]';
    const allowed = {
      'list',
      'targets',
      'enable',
      'disable',
      'clear',
      'resolve',
      'dismiss',
      'reopen',
      'fixed',
      'check',
      'wait',
      'signal-handoff',
    };
    if (!allowed.contains(action)) {
      throw const ScoutCliException('usage', usage);
    }
    if (action == 'wait') {
      final parser = ArgParser()
        ..addOption('timeout', defaultsTo: '600')
        ..addOption('poll', defaultsTo: '1000');
      final parsed = _parseAnnotationArgs(parser, args.skip(1), usage);
      if (parsed.rest.isNotEmpty) {
        throw const ScoutCliException(
          'usage',
          'Usage: flutter-scout annotations wait [--timeout <seconds>] [--poll <ms>]',
        );
      }
      return _annotationsWait(parsed);
    }
    // 'fixed' is the ergonomic name for the runtime 'mark-fixed' action.
    final params = <String, String>{
      'action': action == 'fixed' ? 'mark-fixed' : action,
    };
    switch (action) {
      case 'resolve':
      case 'dismiss':
      case 'reopen':
      case 'fixed':
        final parser = ArgParser()..addOption('note');
        final parsed = _parseAnnotationArgs(parser, args.skip(1), usage);
        if (parsed.rest.length != 1) {
          throw ScoutCliException(
            'usage',
            'Usage: flutter-scout annotations $action <annotation-id> [--note <text>]',
          );
        }
        params['id'] = parsed.rest.first;
        final note = parsed.option('note');
        if (note != null && note.isNotEmpty) {
          params['note'] = note;
        }
        break;
      case 'clear':
        final parser = ArgParser()
          ..addFlag('resolved', defaultsTo: false)
          ..addFlag('dismissed', defaultsTo: false)
          ..addOption('status');
        final parsed = _parseAnnotationArgs(parser, args.skip(1), usage);
        if (parsed.rest.isNotEmpty) {
          throw const ScoutCliException(
            'usage',
            'Usage: flutter-scout annotations clear [--resolved|--dismissed|--status <status>]',
          );
        }
        final status = parsed.option('status');
        final filters = [
          if (status != null && status.isNotEmpty) status,
          if (parsed.flag('resolved')) 'resolved',
          if (parsed.flag('dismissed')) 'dismissed',
        ];
        if (filters.length > 1) {
          throw const ScoutCliException(
            'usage',
            'Use only one annotation clear filter.',
          );
        }
        if (status != null && status.isNotEmpty) {
          params['status'] = status;
        } else if (parsed.flag('resolved')) {
          params['status'] = 'resolved';
        } else if (parsed.flag('dismissed')) {
          params['status'] = 'dismissed';
        }
        break;
      default:
        if (args.length > 1) {
          throw const ScoutCliException('usage', usage);
        }
    }
    return _runAnnotationsAndPrint(params);
  }

  /// Calls the annotations extension, materialises any in-app crops to the
  /// session `crops/` dir (with native fallback for platform-view regions),
  /// then prints the augmented JSON.
  Future<int> _runAnnotationsAndPrint(Map<String, String> params) async {
    final result = await _call('ext.flutter_scout.annotations', params);
    final annotations = result['annotations'];
    if (result['ok'] != false && annotations is List) {
      await _attachCropPaths(annotations);
    }
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
    return result['ok'] == false ? 1 : 0;
  }

  Future<int> _annotationsWait(ArgResults parsed) async {
    final timeoutSeconds = int.tryParse(parsed.option('timeout') ?? '') ?? 600;
    final pollMs = (int.tryParse(parsed.option('poll') ?? '') ?? 1000).clamp(
      200,
      60000,
    );
    final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));
    final initial = await _call('ext.flutter_scout.annotations', {
      'action': 'list',
    });
    if (initial['ok'] == false) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(initial));
      return 1;
    }
    final baseline = (initial['handoffSeq'] as num?)?.toInt() ?? 0;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(milliseconds: pollMs));
      final Map<String, dynamic> state;
      try {
        state = await _call('ext.flutter_scout.annotations', {
          'action': 'list',
        });
      } catch (_) {
        // A transient disconnect (hot reload, GC pause, sim hiccup) must not
        // abort a long wait — keep polling until the deadline.
        continue;
      }
      if (state['ok'] == false) continue;
      final seq = (state['handoffSeq'] as num?)?.toInt() ?? 0;
      if (seq > baseline) {
        final annotations = state['annotations'];
        if (annotations is List) await _attachCropPaths(annotations);
        stdout.writeln(
          const JsonEncoder.withIndent('  ').convert({
            ...state,
            'handoff': true,
            'timedOut': false,
          }),
        );
        return 0;
      }
    }
    final timeoutState = await _call('ext.flutter_scout.annotations', {
      'action': 'list',
    });
    // The app may have disconnected during the wait; don't report a clean
    // timeout (exit 0) on top of an error payload.
    if (timeoutState['ok'] == false) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(timeoutState));
      return 1;
    }
    final annotations = timeoutState['annotations'];
    if (annotations is List) await _attachCropPaths(annotations);
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        ...timeoutState,
        'handoff': false,
        'timedOut': true,
      }),
    );
    return 0;
  }

  /// Cache filename for an annotation crop. The token ties the file to the
  /// capture identity (the annotation's timestamp) so a same-numbered
  /// annotation from a later app launch — IDs reset to `ann_001` on restart
  /// while the session `crops/` dir persists — can never serve a stale crop,
  /// and a re-captured `after` crop (reopen then fixed again) gets a fresh file.
  String _cropCachePath(Map<dynamic, dynamic> annotation, String slot) {
    final stamp = slot == 'after'
        ? (annotation['updatedAt'] ?? annotation['createdAt'])
        : annotation['createdAt'];
    final token = (stamp?.toString() ?? '').replaceAll(
      RegExp(r'[^0-9A-Za-z]'),
      '',
    );
    final id = annotation['id']?.toString() ?? 'unknown';
    final suffix = token.isEmpty ? '' : '_$token';
    return p.join(_sessionDir.path, 'crops', '${id}_$slot$suffix.png');
  }

  Future<void> _attachCropPaths(List<dynamic> annotations) async {
    for (final annotation in annotations.whereType<Map>()) {
      final id = annotation['id']?.toString();
      if (id == null) continue;
      for (final slot in const ['before', 'after']) {
        final capitalized = slot == 'before' ? 'Before' : 'After';
        final hasCrop = annotation['has${capitalized}Crop'] == true;
        final needsNative = annotation['${slot}CropNeedsNative'] == true;
        final rect = annotation['${slot}CropRect'];
        final outPath = _cropCachePath(annotation, slot);
        if (File(outPath).existsSync()) {
          annotation['${slot}CropPath'] = outPath;
          continue;
        }
        if (hasCrop) {
          final fetched = await _fetchAnnotationCrop(id, slot, outPath);
          if (fetched != null) {
            annotation['${slot}CropPath'] = fetched;
            continue;
          }
        }
        if (needsNative && rect is List && rect.length >= 4) {
          final native = await _nativeCropToFile(rect.cast<num>(), outPath);
          if (native != null) {
            annotation['${slot}CropPath'] = native;
            annotation['${slot}CropBackend'] = 'native';
            continue;
          }
          annotation['${slot}CropMissing'] = 'native_capture_unavailable';
        } else if (hasCrop) {
          // The runtime has the crop but the in-app fetch failed (decode/IO);
          // mark it so the agent doesn't expect a path that isn't there.
          annotation['${slot}CropMissing'] = 'in_app_fetch_failed';
        }
      }
    }
  }

  Future<String?> _fetchAnnotationCrop(
    String id,
    String slot,
    String outPath,
  ) async {
    try {
      final res = await _call('ext.flutter_scout.annotations', {
        'action': 'get-crop',
        'id': id,
        'slot': slot,
      });
      final bytes = res['bytes'];
      if (res['ok'] != false && bytes is String && bytes.isNotEmpty) {
        Directory(p.dirname(outPath)).createSync(recursive: true);
        File(outPath).writeAsBytesSync(base64Decode(bytes));
        return outPath;
      }
    } catch (_) {
      // Fall through; caller may try a native capture.
    }
    return null;
  }

  Future<String?> _nativeCropToFile(List<num> rectLogical, String outPath) async {
    final shotPath = p.join(
      _sessionDir.path,
      'screenshots',
      'crop_source_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    try {
      if (await _isMacosScreenshotSession()) return null;
      final inspect = await _call('ext.flutter_scout.inspect');
      await _captureScreenshot(shotPath);
      final sourceBytes = File(shotPath).readAsBytesSync();
      final source = img.decodeImage(sourceBytes);
      if (source == null) return null;
      final dpr =
          (inspect['devicePixelRatio'] as num?)?.toDouble() ??
          _inferDevicePixelRatio(inspect, source);
      final crop = _cropPngBytes(source, rectLogical, dpr, 12);
      Directory(p.dirname(outPath)).createSync(recursive: true);
      File(outPath).writeAsBytesSync(crop.bytes);
      return outPath;
    } catch (_) {
      return null;
    } finally {
      // The full-screen source is only an intermediate for the targeted crop;
      // don't leave it behind (this path can run per poll on platform-view
      // annotations during `annotations wait`).
      final source = File(shotPath);
      if (source.existsSync()) {
        try {
          source.deleteSync();
        } catch (_) {}
      }
    }
  }

  ArgResults _parseAnnotationArgs(
    ArgParser parser,
    Iterable<String> args,
    String usage,
  ) {
    try {
      return parser.parse(args);
    } on FormatException catch (error) {
      throw ScoutCliException('usage', '$usage\n${error.message}');
    }
  }

}
