import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

part 'annotation_overlay.dart';
part 'models.dart';
part 'runtime_annotations.dart';
part 'runtime_actions.dart';
part 'runtime_snapshot.dart';
part 'runtime_nodes.dart';
part 'runtime_internals.dart';

class FlutterScoutBinding {
  FlutterScoutBinding._();

  static void ensureInitialized() {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterScoutHelper.ensureRegistered();
  }
}

class FlutterScoutHelper {
  FlutterScoutHelper._();

  static bool _registered = false;
  static final FlutterScoutRuntime _runtime = FlutterScoutRuntime();

  static void ensureRegistered() {
    if (_registered) return;
    _registered = true;
    _runtime.install();
  }

  @visibleForTesting
  static FlutterScoutRuntime get debugRuntime => _runtime;
}

class FlutterScoutRuntime {
  final List<Map<String, Object?>> _errors = <Map<String, Object?>>[];
  final List<ScoutAnnotation> _annotations = <ScoutAnnotation>[];
  final ValueNotifier<int> _annotationRevision = ValueNotifier<int>(0);
  final DateTime _installedAt = DateTime.now();
  int _nextSyntheticPointer = 1000000;
  int _nextAnnotationId = 1;
  int _annotationHandoffSeq = 0;
  bool _annotationMode = false;
  OverlayEntry? _annotationOverlayEntry;
  bool _annotationOverlayInstallScheduled = false;
  FlutterExceptionHandler? _previousFlutterError;
  ui.ErrorCallback? _previousPlatformError;

  void install() {
    _installErrorHooks();
    _registerExtension('ext.flutter_scout.inspect', _handleInspect);
    _registerExtension('ext.flutter_scout.annotations', _handleAnnotations);
    _registerExtension('ext.flutter_scout.capture', _handleCapture);
    _registerExtension('ext.flutter_scout.tap', _handleTap);
    _registerExtension('ext.flutter_scout.tapText', _handleTapText);
    _registerExtension('ext.flutter_scout.longPress', _handleLongPress);
    _registerExtension('ext.flutter_scout.input', _handleInput);
    _registerExtension('ext.flutter_scout.fill', _handleFill);
    _registerExtension('ext.flutter_scout.scroll', _handleScroll);
    _registerExtension('ext.flutter_scout.scrollTo', _handleScrollTo);
    _registerExtension('ext.flutter_scout.swipe', _handleSwipe);
    _registerExtension('ext.flutter_scout.back', _handleBack);
    _registerExtension('ext.flutter_scout.waitStable', _handleWaitStable);
    _broadcastVmUri();
    _scheduleAnnotationOverlayInstall();
  }

  int get _activeAnnotationCount =>
      _annotations.where((annotation) => annotation.isActive).length;

  @visibleForTesting
  List<ScoutAnnotation> get debugAnnotations => _annotations;

  @visibleForTesting
  int get debugHandoffSeq => _annotationHandoffSeq;

  @visibleForTesting
  void debugSignalHandoff() => _signalAnnotationHandoff();

  @visibleForTesting
  Future<Uint8List?> debugCaptureRegion({Rect? rect, double padding = 12}) async {
    final result = await _captureRegion(rect: rect, padding: padding);
    return result.bytes;
  }

  @visibleForTesting
  Future<void> debugCaptureAnnotationCrop(
    ScoutAnnotation annotation, {
    required String slot,
  }) {
    return _captureAnnotationCrop(annotation, slot: slot);
  }

  @visibleForTesting
  bool debugMarkFixed(String id) =>
      _updateAnnotationStatus(id: id, status: 'pending_review');

  void _installErrorHooks() {
    _previousFlutterError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      _recordError(
        type: 'flutter_error',
        message: details.exceptionAsString(),
        library: details.library,
      );
      _previousFlutterError?.call(details);
    };

    _previousPlatformError = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      _recordError(type: 'platform_error', message: error.toString());
      return _previousPlatformError?.call(error, stack) ?? false;
    };
  }

  void _recordError({
    required String type,
    required String message,
    String? library,
  }) {
    final timestamp = DateTime.now();
    final severity = _errorSeverity(type: type, message: message);
    final error = <String, Object?>{
      'type': type,
      'message': message,
      'timestamp': timestamp.toIso8601String(),
      'severity': severity,
      'blocking': severity == 'blocking',
      'phase': timestamp.difference(_installedAt) < const Duration(seconds: 10)
          ? 'startup'
          : 'runtime',
    };
    if (library != null) {
      error['library'] = library;
    }
    _errors.add(error);
    if (_errors.length > 30) {
      _errors.removeRange(0, _errors.length - 30);
    }
  }

  String _errorSeverity({required String type, required String message}) {
    final lower = message.toLowerCase();
    if (type == 'flutter_error') return 'blocking';
    if (lower.contains('renderflex overflow') ||
        lower.contains('failed assertion') ||
        lower.contains('setstate()') ||
        lower.contains('null check operator used on a null value')) {
      return 'blocking';
    }
    if (lower.contains('httpexception') ||
        lower.contains('socketexception') ||
        lower.contains('connection closed before full header') ||
        lower.contains('connection refused') ||
        lower.contains('connection reset')) {
      return 'non_blocking';
    }
    return 'warning';
  }

  List<Map<String, Object?>> _recentErrors() {
    final now = DateTime.now();
    return [
      for (final error in _errors)
        {
          ...error,
          if (DateTime.tryParse(error['timestamp']?.toString() ?? '')
              case final timestamp?) ...{
            'ageMs': now.difference(timestamp).inMilliseconds,
            'stale': now.difference(timestamp) > const Duration(seconds: 30),
          },
        },
    ];
  }

  void _registerExtension(
    String name,
    Future<developer.ServiceExtensionResponse> Function(
      String method,
      Map<String, String> params,
    )
    callback,
  ) {
    try {
      developer.registerExtension(name, callback);
    } catch (_) {
      // Hot restart/reassemble and multiple test bindings can try to register
      // again. Keeping this idempotent matters more than surfacing the duplicate.
    }
  }

  void _broadcastVmUri() {
    if (kReleaseMode) return;
    unawaited(
      developer.Service.getInfo().then((developer.ServiceProtocolInfo info) {
        final uri = info.serverUri;
        if (uri != null) {
          debugPrint('[FLUTTER_SCOUT_VM_URI] $uri');
        }
      }),
    );
  }

  Future<developer.ServiceExtensionResponse> _handleInspect(
    String method,
    Map<String, String> params,
  ) async {
    try {
      await _waitForFrame();
      final liveAnnotationTargets = _annotationTargets();
      return _ok({
        ..._snapshot().toJson(),
        'annotationMode': _annotationMode,
        'annotations': _annotationJsonList(liveTargets: liveAnnotationTargets),
      });
    } catch (error) {
      return _fail('inspect_failed', error.toString());
    }
  }

}

