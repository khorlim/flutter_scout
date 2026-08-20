part of 'flutter_scout_cli.dart';

// Native mobile capability routing. Platform tools are always started locally
// as an executable plus argv; Scout never invokes a local shell. Android deep
// links necessarily cross ADB's remote shell, so the untrusted URL is encoded
// as one POSIX single-quoted remote argument before dispatch.

/// Test-only process seam for deterministic native-platform contract tests.
/// Production must leave [FlutterScoutCli.debugNativeProcessRunner] null.
typedef NativeProcessDebugRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments,
      bool binaryStdout,
    );

const int _maxNativeToolTextBytes = 64 * 1024;
const int _maxNativeScreenshotBytes = 64 * 1024 * 1024;
const int _maxNativeScreenshotPixels = 64 * 1024 * 1024;
const Duration _nativePreflightTimeout = Duration(seconds: 5);
const Duration _nativeDeeplinkTimeout = Duration(seconds: 15);
const Duration _nativeScreenshotTimeout = Duration(seconds: 30);

enum _NativeMobilePlatform { androidEmulator, iosSimulator }

class _NativeMobileTarget {
  const _NativeMobileTarget({
    required this.id,
    required this.name,
    required this.platform,
    required this.category,
    required this.kind,
  });

  final String id;
  final String name;
  final String platform;
  final String category;
  final _NativeMobilePlatform kind;

  String get backend => switch (kind) {
    _NativeMobilePlatform.androidEmulator => 'android_emulator_adb',
    _NativeMobilePlatform.iosSimulator => 'ios_simulator_simctl',
  };

  String get tool => switch (kind) {
    _NativeMobilePlatform.androidEmulator => 'adb',
    _NativeMobilePlatform.iosSimulator => 'xcrun_simctl',
  };

  String get deeplinkMethod => switch (kind) {
    _NativeMobilePlatform.androidEmulator => 'process.adb.am_start',
    _NativeMobilePlatform.iosSimulator => 'process.simctl.openurl',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'platform': platform,
    'category': category,
    'emulator': true,
    'backend': backend,
  };
}

class _PngFacts {
  const _PngFacts({
    required this.width,
    required this.height,
    required this.byteLength,
  });

  final int width;
  final int height;
  final int byteLength;

  Map<String, Object?> toJson() => <String, Object?>{
    'format': 'png',
    'widthPx': width,
    'heightPx': height,
    'byteLength': byteLength,
  };
}

class _BoundedNativeProcessResult {
  const _BoundedNativeProcessResult({
    required this.exitCode,
    required this.stdoutBytes,
    required this.stderrBytes,
    this.timedOut = false,
    this.outputExceeded = false,
    this.startFailure,
  });

  final int? exitCode;
  final List<int> stdoutBytes;
  final List<int> stderrBytes;
  final bool timedOut;
  final bool outputExceeded;
  final Object? startFailure;

  String get stdoutText => utf8.decode(stdoutBytes, allowMalformed: true);

  bool get started => startFailure == null;
}

/// Deterministic test probes for native routing without a real emulator.
extension NativePlatformDebug on FlutterScoutCli {
  Map<String, Object?> debugNativeTargetFromRecorded({
    required String? device,
    required Map<String, dynamic>? deviceInfo,
    String operation = 'screenshot',
  }) => _nativeMobileTargetFromRecorded(
    device: device,
    deviceInfo: deviceInfo,
    operation: operation,
  ).toJson();

  Future<Map<String, Object?>> debugCaptureNativeMobileScreenshot({
    required String output,
    required String device,
    required Map<String, dynamic> deviceInfo,
  }) async {
    final target = _nativeMobileTargetFromRecorded(
      device: device,
      deviceInfo: deviceInfo,
      operation: 'screenshot',
    );
    await _preflightNativeTarget(target, operation: 'screenshot');
    return target.kind == _NativeMobilePlatform.androidEmulator
        ? _captureAndroidScreenshot(output, target)
        : _captureIosScreenshot(output, target);
  }

  Future<Map<String, Object?>> debugDispatchNativeDeeplink({
    required String url,
    required String device,
    required Map<String, dynamic> deviceInfo,
  }) async {
    final target = _nativeMobileTargetFromRecorded(
      device: device,
      deviceInfo: deviceInfo,
      operation: 'deeplink',
    );
    await _preflightNativeTarget(target, operation: 'deeplink');
    return _dispatchNativeDeeplink(target, url);
  }

  Map<String, Object?> debugValidateNativeScreenshotPng(List<int> bytes) =>
      _validateNativeScreenshotPng(bytes).toJson();

  Future<Map<String, Object?>> debugRunBoundedNativeProcess({
    required String executable,
    required List<String> arguments,
    required Duration timeout,
    int maxStdoutBytes = _maxNativeToolTextBytes,
    int maxStderrBytes = _maxNativeToolTextBytes,
  }) async {
    final result = await _runBoundedNativeProcess(
      executable,
      arguments,
      timeout: timeout,
      maxStdoutBytes: maxStdoutBytes,
      maxStderrBytes: maxStderrBytes,
    );
    return <String, Object?>{
      'started': result.started,
      'exitCode': result.exitCode,
      'timedOut': result.timedOut,
      'outputExceeded': result.outputExceeded,
      'stdout': result.stdoutText,
      'stderr': utf8.decode(result.stderrBytes, allowMalformed: true),
    };
  }

  String debugAdbShellQuotedArgument(String value) =>
      _adbShellQuotedArgument(value);

  String? debugNativeDeeplinkObservationIssue(
    Map<String, dynamic>? observation, {
    required String? expectedRunId,
  }) => _nativeDeeplinkObservationIssue(
    observation,
    expectedRunId: expectedRunId,
  );

  double debugValidateNativeCropCoordinateFrame({
    required Map<String, Object?> coordinateFrame,
    required int imageWidth,
    required int imageHeight,
    double? nodeDevicePixelRatio,
  }) => _validatedNativeCropDevicePixelRatio(
    coordinateFrame: coordinateFrame,
    sourceWidth: imageWidth,
    sourceHeight: imageHeight,
    expectedNodeDevicePixelRatio: nodeDevicePixelRatio,
    backend: 'deterministic_test_backend',
  );
}

extension _CliNativePlatform on FlutterScoutCli {
  _NativeMobileTarget _requireNativeMobileTarget({required String operation}) =>
      _nativeMobileTargetFromRecorded(
        device: _readDevice(),
        deviceInfo: _readDeviceInfo(),
        operation: operation,
      );

  _NativeMobileTarget _nativeMobileTargetFromRecorded({
    required String? device,
    required Map<String, dynamic>? deviceInfo,
    required String operation,
  }) {
    final recordedId = deviceInfo?['id']?.toString().trim();
    final platform = deviceInfo?['platform']?.toString().trim().toLowerCase();
    final category = deviceInfo?['category']?.toString().trim().toLowerCase();
    final emulator = deviceInfo?['emulator'];
    final name = deviceInfo?['name']?.toString().trim();
    final exactDevice = device?.trim();

    Never unsupported(String reason) {
      throw ScoutCliException(
        'unsupported_capability',
        'Native $operation is unavailable: $reason',
        details: <String, Object?>{
          'capability': 'native_$operation',
          'dispatch': 'not_dispatched',
          'targetPlatform': platform ?? 'unavailable',
          'targetCategory': category ?? 'unavailable',
          'emulator': emulator == true,
        },
      );
    }

    if (exactDevice == null || exactDevice.isEmpty) {
      unsupported('the session has no exact recorded device id.');
    }
    if (recordedId == null || recordedId.isEmpty || recordedId != exactDevice) {
      unsupported(
        'the recorded device identity is missing or does not match the session.',
      );
    }
    if (exactDevice.length > 256 ||
        exactDevice.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
      unsupported('the recorded device id is not a bounded printable value.');
    }
    if (emulator != true) {
      unsupported('the recorded target is not proven to be an emulator.');
    }
    if (category != 'mobile') {
      unsupported('the recorded target is not a mobile emulator.');
    }
    if (platform == null || platform.isEmpty || platform.length > 64) {
      unsupported('the recorded target platform is unavailable.');
    }

    final kind = platform == 'android' || platform.startsWith('android-')
        ? _NativeMobilePlatform.androidEmulator
        : platform == 'ios'
        ? _NativeMobilePlatform.iosSimulator
        : null;
    if (kind == null) {
      unsupported(
        'platform `$platform` has no proven native $operation backend.',
      );
    }
    return _NativeMobileTarget(
      id: exactDevice,
      name: name == null || name.isEmpty ? exactDevice : name,
      platform: platform,
      category: category!,
      kind: kind,
    );
  }

  Future<void> _preflightNativeTarget(
    _NativeMobileTarget target, {
    required String operation,
  }) async {
    final executable = target.kind == _NativeMobilePlatform.androidEmulator
        ? 'adb'
        : 'xcrun';
    final arguments = target.kind == _NativeMobilePlatform.androidEmulator
        ? <String>['-s', target.id, 'get-state']
        : <String>['simctl', 'getenv', target.id, 'SIMULATOR_UDID'];
    final result = await _runBoundedNativeProcess(
      executable,
      arguments,
      timeout: _nativePreflightTimeout,
      maxStdoutBytes: _maxNativeToolTextBytes,
      maxStderrBytes: _maxNativeToolTextBytes,
    );
    final available =
        result.started &&
        !result.timedOut &&
        !result.outputExceeded &&
        result.exitCode == 0 &&
        (target.kind == _NativeMobilePlatform.androidEmulator
            ? result.stdoutText.trim() == 'device'
            : result.stdoutText.trim() == target.id);
    if (available) return;
    throw ScoutCliException(
      'unsupported_capability',
      'Native $operation is unavailable because `${target.tool}` did not '
          'prove that the exact recorded emulator is reachable.',
      details: <String, Object?>{
        'capability': 'native_$operation',
        'backend': target.backend,
        'device': target.id,
        'dispatch': 'not_dispatched',
        'toolStarted': result.started,
        'toolTimedOut': result.timedOut,
        'toolOutputExceeded': result.outputExceeded,
        if (result.exitCode != null) 'toolExitCode': result.exitCode,
      },
    );
  }

  Future<Map<String, Object?>> _captureScreenshot(String output) async {
    final recordedPlatform = _readDeviceInfo()?['platform']
        ?.toString()
        .trim()
        .toLowerCase();
    if (recordedPlatform != null &&
        (recordedPlatform.contains('android') ||
            recordedPlatform.contains('ios'))) {
      final target = _requireNativeMobileTarget(operation: 'screenshot');
      await _preflightNativeTarget(target, operation: 'screenshot');
      return target.kind == _NativeMobilePlatform.androidEmulator
          ? _captureAndroidScreenshot(output, target)
          : _captureIosScreenshot(output, target);
    }
    final macos = await _macosWindowTarget();
    if (macos != null) {
      return _captureMacosWindowScreenshot(output, macos);
    }
    if (await _isMacosScreenshotSession()) {
      throw const ScoutCliException(
        'unsupported_capability',
        'Native screenshot is unavailable because no capturable macOS app '
            'window was proven for this session.',
        details: <String, Object?>{
          'capability': 'native_screenshot',
          'dispatch': 'not_applicable_read_only',
          'targetPlatform': 'macos',
        },
      );
    }
    // Produces the same typed unsupported result for unknown, desktop, web,
    // physical-device, and other experimental targets.
    _requireNativeMobileTarget(operation: 'screenshot');
    throw StateError('unreachable native screenshot target classification');
  }

  Future<Map<String, Object?>> _captureAndroidScreenshot(
    String output,
    _NativeMobileTarget target,
  ) async {
    final result = await _runBoundedNativeProcess(
      'adb',
      <String>['-s', target.id, 'exec-out', 'screencap', '-p'],
      timeout: _nativeScreenshotTimeout,
      binaryStdout: true,
      maxStdoutBytes: _maxNativeScreenshotBytes,
      maxStderrBytes: _maxNativeToolTextBytes,
    );
    final bytes = _requireSuccessfulScreenshotProcess(result, target: target);
    final png = _validateNativeScreenshotPng(bytes);
    _writePrivateArtifactBytes(output, bytes);
    return _nativeScreenshotFacts(target, png);
  }

  Future<Map<String, Object?>> _captureIosScreenshot(
    String output,
    _NativeMobileTarget target,
  ) async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'flutter_scout_native_capture_',
    );
    _ensurePrivateDirectory(
      temporaryDirectory.path,
      boundary: temporaryDirectory.path,
    );
    final temporaryOutput = p.join(temporaryDirectory.path, 'capture.png');
    try {
      final result = await _runBoundedNativeProcess(
        'xcrun',
        <String>['simctl', 'io', target.id, 'screenshot', temporaryOutput],
        timeout: _nativeScreenshotTimeout,
        maxStdoutBytes: _maxNativeToolTextBytes,
        maxStderrBytes: _maxNativeToolTextBytes,
      );
      _requireSuccessfulNativeTool(result, operation: 'screenshot');
      final bytes = _readBoundedNativePngFile(
        temporaryOutput,
        boundary: temporaryDirectory.path,
      );
      final png = _validateNativeScreenshotPng(bytes);
      _writePrivateArtifactBytes(output, bytes);
      return _nativeScreenshotFacts(target, png);
    } finally {
      _deletePrivateDirectoryIfExists(
        temporaryDirectory.path,
        boundary: temporaryDirectory.path,
      );
    }
  }

  Future<Map<String, Object?>> _captureMacosWindowScreenshot(
    String output,
    _MacosWindowTarget target,
  ) async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'flutter_scout_native_capture_',
    );
    _ensurePrivateDirectory(
      temporaryDirectory.path,
      boundary: temporaryDirectory.path,
    );
    final temporaryOutput = p.join(temporaryDirectory.path, 'capture.png');
    try {
      final result = await _runBoundedNativeProcess(
        'screencapture',
        <String>['-x', '-l', target.windowId.toString(), temporaryOutput],
        timeout: _nativeScreenshotTimeout,
        maxStdoutBytes: _maxNativeToolTextBytes,
        maxStderrBytes: _maxNativeToolTextBytes,
      );
      _requireSuccessfulNativeTool(result, operation: 'screenshot');
      final bytes = _readBoundedNativePngFile(
        temporaryOutput,
        boundary: temporaryDirectory.path,
      );
      final png = _validateNativeScreenshotPng(bytes);
      _writePrivateArtifactBytes(output, bytes);
      return <String, Object?>{
        'backend': 'macos_window_screencapture',
        'device': 'macos',
        'windowId': target.windowId,
        'pid': target.pid,
        'ownerName': target.ownerName,
        if (target.windowName != null && target.windowName!.isNotEmpty)
          'windowName': target.windowName,
        if (target.bounds != null) 'windowBounds': target.bounds,
        'image': png.toJson(),
        'provenance': const <String, Object?>{
          'source': 'native_os_capture',
          'tool': 'screencapture',
          'captureScope': 'proven_app_window',
        },
        'coordinateSpace': const <String, Object?>{
          'image': 'physical_pixels',
          'origin': 'captured_window_top_left',
          'helperGeometry': 'logical_flutter_points',
          'logicalToPhysicalTransform': 'unavailable',
        },
        'limitations': const <String>[
          'Native targeted crops are unavailable for macOS window capture.',
        ],
      };
    } finally {
      _deletePrivateDirectoryIfExists(
        temporaryDirectory.path,
        boundary: temporaryDirectory.path,
      );
    }
  }

  List<int> _requireSuccessfulScreenshotProcess(
    _BoundedNativeProcessResult result, {
    required _NativeMobileTarget target,
  }) {
    _requireSuccessfulNativeTool(result, operation: 'screenshot');
    if (result.stdoutBytes.isEmpty) {
      throw ScoutCliException(
        'screenshot_failed',
        'The ${target.backend} screenshot command returned no image bytes.',
      );
    }
    return result.stdoutBytes;
  }

  void _requireSuccessfulNativeTool(
    _BoundedNativeProcessResult result, {
    required String operation,
  }) {
    if (!result.started) {
      throw ScoutCliException(
        '${operation}_failed',
        'The native $operation tool could not be started.',
      );
    }
    if (result.timedOut) {
      throw ScoutCliException(
        '${operation}_failed',
        'The native $operation tool exceeded its bounded deadline.',
      );
    }
    if (result.outputExceeded) {
      throw ScoutCliException(
        '${operation}_failed',
        'The native $operation tool exceeded its bounded output limit.',
      );
    }
    if (result.exitCode != 0) {
      throw ScoutCliException(
        '${operation}_failed',
        'The native $operation tool exited unsuccessfully.',
        details: <String, Object?>{'toolExitCode': result.exitCode},
      );
    }
  }

  List<int> _readBoundedNativePngFile(String path, {required String boundary}) {
    _assertPrivateFilePath(path, boundary: boundary, allowMissing: false);
    final file = File(path);
    final length = file.lengthSync();
    if (length <= 0 || length > _maxNativeScreenshotBytes) {
      throw const ScoutCliException(
        'screenshot_failed',
        'The native screenshot file is empty or exceeds the 64 MiB limit.',
      );
    }
    return file.readAsBytesSync();
  }

  _PngFacts _validateNativeScreenshotPng(List<int> bytes) {
    const signature = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    if (bytes.length < 45 || bytes.length > _maxNativeScreenshotBytes) {
      throw const ScoutCliException(
        'screenshot_invalid_png',
        'The native screenshot PNG is truncated or exceeds the 64 MiB limit.',
      );
    }
    for (var index = 0; index < signature.length; index++) {
      if (bytes[index] != signature[index]) {
        throw const ScoutCliException(
          'screenshot_invalid_png',
          'The native screenshot does not have a valid PNG signature.',
        );
      }
    }
    final ihdrLength = _readUint32BigEndian(bytes, 8);
    final ihdrType = ascii.decode(bytes.sublist(12, 16), allowInvalid: true);
    final width = _readUint32BigEndian(bytes, 16);
    final height = _readUint32BigEndian(bytes, 20);
    final hasIend =
        bytes[bytes.length - 12] == 0 &&
        bytes[bytes.length - 11] == 0 &&
        bytes[bytes.length - 10] == 0 &&
        bytes[bytes.length - 9] == 0 &&
        ascii.decode(
              bytes.sublist(bytes.length - 8, bytes.length - 4),
              allowInvalid: true,
            ) ==
            'IEND';
    final unsafeDimensions =
        width <= 0 ||
        height <= 0 ||
        width > _maxNativeScreenshotPixels ||
        height > _maxNativeScreenshotPixels ||
        width > _maxNativeScreenshotPixels ~/ height;
    if (ihdrLength != 13 ||
        ihdrType != 'IHDR' ||
        unsafeDimensions ||
        !hasIend) {
      throw const ScoutCliException(
        'screenshot_invalid_png',
        'The native screenshot PNG has invalid or unsafe dimensions/chunks.',
      );
    }
    img.Image? decoded;
    try {
      decoded = img.decodePng(Uint8List.fromList(bytes));
    } on Object {
      decoded = null;
    }
    if (decoded == null || decoded.width != width || decoded.height != height) {
      throw const ScoutCliException(
        'screenshot_invalid_png',
        'The native screenshot PNG body could not be decoded consistently.',
      );
    }
    return _PngFacts(width: width, height: height, byteLength: bytes.length);
  }

  int _readUint32BigEndian(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  Map<String, Object?> _nativeScreenshotFacts(
    _NativeMobileTarget target,
    _PngFacts png,
  ) => <String, Object?>{
    'backend': target.backend,
    'device': target.id,
    'target': target.toJson(),
    'image': png.toJson(),
    'provenance': <String, Object?>{
      'source': 'native_os_capture',
      'tool': target.tool,
      'captureScope': 'entire_emulator_display',
      'targetPlatform': target.platform,
      'emulatorIdentitySource': 'session_device_info',
    },
    'coordinateSpace': const <String, Object?>{
      'image': 'physical_display_pixels',
      'origin': 'display_top_left',
      'helperGeometry': 'logical_flutter_points',
      'nativeCropRequirement':
          'same_snapshot_dpr_and_exact_physical_viewport_match',
    },
    'limitations': const <String>[
      'The native image may include operating-system chrome and platform views.',
      'A native crop is safe only when Scout proves the helper physical viewport exactly matches this image.',
    ],
  };

  Future<Map<String, Object?>> _dispatchNativeDeeplink(
    _NativeMobileTarget target,
    String url,
  ) async {
    final executable = target.kind == _NativeMobilePlatform.androidEmulator
        ? 'adb'
        : 'xcrun';
    final arguments = target.kind == _NativeMobilePlatform.androidEmulator
        ? <String>[
            '-s',
            target.id,
            'shell',
            'am',
            'start',
            '-W',
            '-a',
            'android.intent.action.VIEW',
            '-d',
            _adbShellQuotedArgument(url),
          ]
        : <String>['simctl', 'openurl', target.id, url];
    final result = await _runBoundedNativeProcess(
      executable,
      arguments,
      timeout: _nativeDeeplinkTimeout,
      maxStdoutBytes: _maxNativeToolTextBytes,
      maxStderrBytes: _maxNativeToolTextBytes,
    );
    if (!result.started) {
      return <String, Object?>{
        'ok': false,
        'dispatch': 'not_dispatched',
        'backend': target.backend,
        'device': target.id,
        'structuredError': const <String, Object?>{
          'code': 'deeplink_process_start_failed',
          'message':
              'The native deep-link process could not be started; nothing was dispatched.',
        },
      };
    }
    if (result.timedOut ||
        result.outputExceeded ||
        result.exitCode == null ||
        result.exitCode != 0) {
      return <String, Object?>{
        'ok': false,
        'dispatch': 'dispatch_outcome_unknown',
        'transport': result.timedOut ? 'timeout' : 'failed',
        'backend': target.backend,
        'device': target.id,
        'structuredError': <String, Object?>{
          'code': result.timedOut
              ? 'deeplink_dispatch_timeout'
              : result.outputExceeded
              ? 'deeplink_tool_output_exceeded'
              : 'deeplink_process_failed',
          'message':
              'The native deep-link process did not provide a closed dispatch acknowledgement. Reconcile current app state before retrying under the same idempotency key.',
          'details': <String, Object?>{
            'toolTimedOut': result.timedOut,
            'toolOutputExceeded': result.outputExceeded,
            if (result.exitCode != null) 'toolExitCode': result.exitCode,
          },
        },
      };
    }
    if (target.kind == _NativeMobilePlatform.androidEmulator &&
        !RegExp(
          r'^Status:\s*ok\s*$',
          multiLine: true,
          caseSensitive: false,
        ).hasMatch(result.stdoutText)) {
      return <String, Object?>{
        'ok': false,
        'dispatch': 'dispatch_outcome_unknown',
        'transport': 'invalid_response',
        'backend': target.backend,
        'device': target.id,
        'structuredError': const <String, Object?>{
          'code': 'deeplink_outcome_unknown',
          'message':
              'Android Activity Manager exited successfully but did not provide a closed `Status: ok` acknowledgement. Reconcile current app state before retrying under the same idempotency key.',
        },
      };
    }
    return <String, Object?>{
      'ok': true,
      'dispatch': 'dispatched',
      'transport': 'ok',
      'backend': target.backend,
      'device': target.id,
      'targetPlatform': target.platform,
      'tool': target.tool,
      'acknowledgement': target.kind == _NativeMobilePlatform.androidEmulator
          ? 'activity_manager_status_ok'
          : 'simctl_exit_zero',
      'commandTransport': target.kind == _NativeMobilePlatform.androidEmulator
          ? 'local_argv_with_remote_shell_single_quote_escaping'
          : 'local_argv_no_shell',
      if (target.kind == _NativeMobilePlatform.androidEmulator)
        'remoteArgumentEncoding': 'posix_single_quote_for_adb_shell',
    };
  }

  String _adbShellQuotedArgument(String value) =>
      "'${value.replaceAll("'", "'\"'\"'")}'";

  Future<_BoundedNativeProcessResult> _runBoundedNativeProcess(
    String executable,
    List<String> arguments, {
    required Duration timeout,
    required int maxStdoutBytes,
    required int maxStderrBytes,
    bool binaryStdout = false,
  }) async {
    final override = FlutterScoutCli.debugNativeProcessRunner;
    if (override != null) {
      try {
        final result = await override(
          executable,
          List<String>.unmodifiable(arguments),
          binaryStdout,
        ).timeout(timeout);
        final stdoutBytes = _nativeOutputBytes(result.stdout);
        final stderrBytes = _nativeOutputBytes(result.stderr);
        return _BoundedNativeProcessResult(
          exitCode: result.exitCode,
          stdoutBytes: stdoutBytes.length > maxStdoutBytes
              ? stdoutBytes.sublist(0, maxStdoutBytes)
              : stdoutBytes,
          stderrBytes: stderrBytes.length > maxStderrBytes
              ? stderrBytes.sublist(0, maxStderrBytes)
              : stderrBytes,
          outputExceeded:
              stdoutBytes.length > maxStdoutBytes ||
              stderrBytes.length > maxStderrBytes,
        );
      } on TimeoutException {
        return const _BoundedNativeProcessResult(
          exitCode: null,
          stdoutBytes: <int>[],
          stderrBytes: <int>[],
          timedOut: true,
        );
      } on Object catch (error) {
        return _BoundedNativeProcessResult(
          exitCode: null,
          stdoutBytes: const <int>[],
          stderrBytes: const <int>[],
          startFailure: error,
        );
      }
    }

    Process process;
    try {
      process = await Process.start(
        executable,
        arguments,
        mode: ProcessStartMode.normal,
      ).timeout(_nativePreflightTimeout);
    } on Object catch (error) {
      return _BoundedNativeProcessResult(
        exitCode: null,
        stdoutBytes: const <int>[],
        stderrBytes: const <int>[],
        startFailure: error,
      );
    }

    final stdoutBytes = <int>[];
    final stderrBytes = <int>[];
    var outputExceeded = false;
    Future<int?>? forcedTermination;
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    late final StreamSubscription<List<int>> stdoutSubscription;
    late final StreamSubscription<List<int>> stderrSubscription;

    void collect(List<int> chunk, List<int> destination, int limit) {
      final remaining = limit - destination.length;
      if (remaining > 0) {
        destination.addAll(
          chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
        );
      }
      if (chunk.length > remaining) {
        outputExceeded = true;
        forcedTermination ??= _terminateNativeProcess(process);
      }
    }

    stdoutSubscription = process.stdout.listen(
      (chunk) => collect(chunk, stdoutBytes, maxStdoutBytes),
      onDone: stdoutDone.complete,
      onError: stdoutDone.completeError,
      cancelOnError: true,
    );
    stderrSubscription = process.stderr.listen(
      (chunk) => collect(chunk, stderrBytes, maxStderrBytes),
      onDone: stderrDone.complete,
      onError: stderrDone.completeError,
      cancelOnError: true,
    );

    var timedOut = false;
    int? exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      forcedTermination ??= _terminateNativeProcess(process);
      exitCode = await forcedTermination;
    }
    try {
      await Future.wait(<Future<void>>[
        stdoutDone.future,
        stderrDone.future,
      ]).timeout(const Duration(seconds: 2));
    } on Object {
      // Exit, timeout, and output flags are the authoritative process facts.
    } finally {
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
    }
    return _BoundedNativeProcessResult(
      exitCode: exitCode,
      stdoutBytes: stdoutBytes,
      stderrBytes: stderrBytes,
      timedOut: timedOut,
      outputExceeded: outputExceeded,
    );
  }

  Future<int?> _terminateNativeProcess(Process process) async {
    try {
      process.kill();
    } on Object {
      // The process may have raced to completion before TERM was delivered.
    }
    try {
      return await process.exitCode.timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      try {
        if (Platform.isWindows) {
          process.kill();
        } else {
          process.kill(ProcessSignal.sigkill);
        }
      } on Object {
        // A concurrent process exit is equivalent to a successful kill here.
      }
      try {
        return await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        return null;
      }
    }
  }

  List<int> _nativeOutputBytes(Object? output) {
    if (output is List<int>) return List<int>.from(output, growable: false);
    if (output is String) return utf8.encode(output);
    return utf8.encode(output?.toString() ?? '');
  }
}
