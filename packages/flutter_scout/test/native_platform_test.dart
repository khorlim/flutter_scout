import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('native Android emulator capability', () {
    late List<({String executable, List<String> arguments, bool binary})> calls;

    setUp(() {
      calls = [];
    });

    tearDown(() {
      FlutterScoutCli.debugNativeProcessRunner = null;
    });

    test('is derived only from matching recorded emulator metadata', () {
      final target = FlutterScoutCli().debugNativeTargetFromRecorded(
        device: 'emulator-5554',
        deviceInfo: _androidDeviceInfo,
      );
      expect(target, containsPair('backend', 'android_emulator_adb'));
      expect(target, containsPair('emulator', true));

      expect(
        () => FlutterScoutCli().debugNativeTargetFromRecorded(
          device: 'emulator-5556',
          deviceInfo: _androidDeviceInfo,
        ),
        throwsA(
          isA<ScoutCliException>().having(
            (error) => error.code,
            'code',
            'unsupported_capability',
          ),
        ),
      );
      expect(
        () => FlutterScoutCli().debugNativeTargetFromRecorded(
          device: 'emulator-5554',
          deviceInfo: <String, dynamic>{
            ..._androidDeviceInfo,
            'emulator': false,
          },
        ),
        throwsA(
          isA<ScoutCliException>().having(
            (error) => error.code,
            'code',
            'unsupported_capability',
          ),
        ),
      );
      expect(
        () => FlutterScoutCli().debugNativeTargetFromRecorded(
          device: 'emulator-5554',
          deviceInfo: <String, dynamic>{
            ..._androidDeviceInfo,
            'platform': 'not-android',
          },
        ),
        throwsA(
          isA<ScoutCliException>().having(
            (error) => error.code,
            'code',
            'unsupported_capability',
          ),
        ),
      );
    });

    test(
      'captures PNG bytes with exact argv and atomic owner-only output',
      () async {
        final png = _onePixelPng();
        FlutterScoutCli.debugNativeProcessRunner =
            (executable, arguments, binary) async {
              calls.add((
                executable: executable,
                arguments: arguments,
                binary: binary,
              ));
              if (arguments.contains('get-state')) {
                return ProcessResult(1, 0, 'device\n', '');
              }
              return ProcessResult(2, 0, png, '');
            };
        final directory = await Directory.systemTemp.createTemp(
          'flutter_scout_android_capture_test_',
        );
        addTearDown(() => directory.deleteSync(recursive: true));
        final output = p.join(directory.path, 'capture.png');

        final result = await FlutterScoutCli()
            .debugCaptureNativeMobileScreenshot(
              output: output,
              device: 'emulator-5554',
              deviceInfo: _androidDeviceInfo,
            );

        expect(calls, hasLength(2));
        expect(calls[0].executable, 'adb');
        expect(calls[0].arguments, <String>[
          '-s',
          'emulator-5554',
          'get-state',
        ]);
        expect(calls[0].binary, isFalse);
        expect(calls[1].executable, 'adb');
        expect(calls[1].arguments, <String>[
          '-s',
          'emulator-5554',
          'exec-out',
          'screencap',
          '-p',
        ]);
        expect(calls[1].binary, isTrue);
        expect(File(output).readAsBytesSync(), png);
        if (!Platform.isWindows) {
          expect(FileStat.statSync(output).mode & 0x1ff, 0x180);
        }
        expect(result['backend'], 'android_emulator_adb');
        expect(result['image'], containsPair('widthPx', 1));
        expect(
          result['coordinateSpace'],
          containsPair('image', 'physical_display_pixels'),
        );
        expect(result['limitations'], isNotEmpty);
      },
    );

    test('rejects non-PNG tool output without creating the artifact', () async {
      FlutterScoutCli.debugNativeProcessRunner =
          (executable, arguments, binary) async =>
              arguments.contains('get-state')
              ? ProcessResult(1, 0, 'device\n', '')
              : ProcessResult(2, 0, <int>[1, 2, 3], '');
      final directory = await Directory.systemTemp.createTemp(
        'flutter_scout_android_capture_invalid_',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final output = p.join(directory.path, 'capture.png');

      await expectLater(
        FlutterScoutCli().debugCaptureNativeMobileScreenshot(
          output: output,
          device: 'emulator-5554',
          deviceInfo: _androidDeviceInfo,
        ),
        throwsA(
          isA<ScoutCliException>().having(
            (error) => error.code,
            'code',
            'screenshot_invalid_png',
          ),
        ),
      );
      expect(File(output).existsSync(), isFalse);
    });

    test('rejects a structurally plausible PNG with an invalid body', () {
      final corrupt = _corruptFirstIdatByte(_onePixelPng());

      expect(
        () => FlutterScoutCli().debugValidateNativeScreenshotPng(corrupt),
        throwsA(
          isA<ScoutCliException>().having(
            (error) => error.code,
            'code',
            'screenshot_invalid_png',
          ),
        ),
      );
    });

    test('native crop transform requires an exact physical viewport match', () {
      final cli = FlutterScoutCli();
      final frame = <String, Object?>{
        'primarySpace': 'logical_flutter_points',
        'origin': 'flutter_view_top_left',
        'xDirection': 'right',
        'yDirection': 'down',
        'logicalViewport': <num>[0, 0, 200, 400],
        'physicalViewport': <num>[0, 0, 400, 800],
        'devicePixelRatio': 2.0,
        'logicalToPhysicalScale': 2.0,
        'viewMetricsAvailable': true,
        'provenance': 'flutter_view_physical_size_and_device_pixel_ratio',
      };
      expect(
        cli.debugValidateNativeCropCoordinateFrame(
          coordinateFrame: frame,
          imageWidth: 400,
          imageHeight: 800,
          nodeDevicePixelRatio: 2.0,
        ),
        2.0,
      );
      expect(
        () => cli.debugValidateNativeCropCoordinateFrame(
          coordinateFrame: frame,
          imageWidth: 400,
          imageHeight: 824,
          nodeDevicePixelRatio: 2.0,
        ),
        throwsA(
          isA<ScoutCliException>().having(
            (error) => error.code,
            'code',
            'native_crop_coordinate_frame_mismatch',
          ),
        ),
      );
    });

    test(
      'preflight failure abstains before the app mutation command',
      () async {
        FlutterScoutCli.debugNativeProcessRunner =
            (executable, arguments, binary) async {
              calls.add((
                executable: executable,
                arguments: arguments,
                binary: binary,
              ));
              throw ProcessException(executable, arguments, 'not installed');
            };

        await expectLater(
          FlutterScoutCli().debugDispatchNativeDeeplink(
            url: 'example://safe',
            device: 'emulator-5554',
            deviceInfo: _androidDeviceInfo,
          ),
          throwsA(
            isA<ScoutCliException>()
                .having((error) => error.code, 'code', 'unsupported_capability')
                .having(
                  (error) => error.details['dispatch'],
                  'dispatch',
                  'not_dispatched',
                ),
          ),
        );
        expect(calls, hasLength(1));
        expect(calls.single.arguments, <String>[
          '-s',
          'emulator-5554',
          'get-state',
        ]);
      },
    );

    test(
      'deep link uses one argv value and requires Activity Manager ack',
      () async {
        const url = r'example://item?value=$(touch /tmp/not-executed)&x=`id`';
        FlutterScoutCli.debugNativeProcessRunner =
            (executable, arguments, binary) async {
              calls.add((
                executable: executable,
                arguments: arguments,
                binary: binary,
              ));
              if (arguments.contains('get-state')) {
                return ProcessResult(1, 0, 'device\n', '');
              }
              return ProcessResult(
                2,
                0,
                'Starting: Intent { ... }\nStatus: ok\nComplete\n',
                '',
              );
            };

        final result = await FlutterScoutCli().debugDispatchNativeDeeplink(
          url: url,
          device: 'emulator-5554',
          deviceInfo: _androidDeviceInfo,
        );

        expect(calls, hasLength(2));
        expect(calls[1].executable, 'adb');
        expect(calls[1].arguments, <String>[
          '-s',
          'emulator-5554',
          'shell',
          'am',
          'start',
          '-W',
          '-a',
          'android.intent.action.VIEW',
          '-d',
          "'$url'",
        ]);
        expect(calls[1].arguments.where((value) => value == url), isEmpty);
        expect(calls[1].arguments.last, "'$url'");
        expect(result['acknowledgement'], 'activity_manager_status_ok');
        expect(
          result['commandTransport'],
          'local_argv_with_remote_shell_single_quote_escaping',
        );
        expect(
          result['remoteArgumentEncoding'],
          'posix_single_quote_for_adb_shell',
        );
        expect(
          FlutterScoutCli().debugAdbShellQuotedArgument("example://O'Reilly"),
          "'example://O'\"'\"'Reilly'",
        );
      },
    );

    test('exit zero without Status ok remains outcome unknown', () async {
      FlutterScoutCli.debugNativeProcessRunner =
          (executable, arguments, binary) async =>
              arguments.contains('get-state')
              ? ProcessResult(1, 0, 'device\n', '')
              : ProcessResult(2, 0, 'Starting: Intent { ... }\n', '');

      final result = await FlutterScoutCli().debugDispatchNativeDeeplink(
        url: 'example://safe',
        device: 'emulator-5554',
        deviceInfo: _androidDeviceInfo,
      );
      expect(result['dispatch'], 'dispatch_outcome_unknown');
      expect(
        (result['structuredError'] as Map)['code'],
        'deeplink_outcome_unknown',
      );
    });

    test('deep-link observation must be protocol-valid and same-session', () {
      final cli = FlutterScoutCli();
      final observation = _validReadObservation();

      expect(
        cli.debugNativeDeeplinkObservationIssue(
          observation,
          expectedRunId: 'native-run',
        ),
        isNull,
      );
      expect(
        cli.debugNativeDeeplinkObservationIssue(
          observation,
          expectedRunId: 'different-run',
        ),
        'session_run_id_mismatch',
      );
      expect(
        cli.debugNativeDeeplinkObservationIssue(<String, dynamic>{
          ...observation,
          'stateDigest': List<String>.filled(64, 'b').join(),
        }, expectedRunId: 'native-run'),
        'snapshot_identity_unavailable',
      );
      expect(
        cli.debugNativeDeeplinkObservationIssue(
          null,
          expectedRunId: 'native-run',
        ),
        'observation_unavailable',
      );
    });

    test(
      'native process timeout escalates TERM to bounded KILL',
      () async {
        final stopwatch = Stopwatch()..start();
        final result = await FlutterScoutCli().debugRunBoundedNativeProcess(
          executable: Platform.resolvedExecutable,
          arguments: <String>[
            p.join('test', 'fixtures', 'native_process_ignores_term.dart'),
          ],
          timeout: const Duration(seconds: 1),
          maxStdoutBytes: 2048,
        );
        stopwatch.stop();

        expect(result['started'], isTrue);
        expect(result['timedOut'], isTrue);
        expect(result['exitCode'], isNotNull);
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 4)));
      },
      skip: Platform.isWindows
          ? 'POSIX TERM/KILL semantics are unavailable'
          : false,
    );

    test(
      'native process output limit also escalates to bounded KILL',
      () async {
        final stopwatch = Stopwatch()..start();
        final result = await FlutterScoutCli().debugRunBoundedNativeProcess(
          executable: Platform.resolvedExecutable,
          arguments: <String>[
            p.join('test', 'fixtures', 'native_process_ignores_term.dart'),
          ],
          timeout: const Duration(seconds: 10),
          maxStdoutBytes: 32,
        );
        stopwatch.stop();

        expect(result['started'], isTrue);
        expect(result['outputExceeded'], isTrue);
        expect(result['timedOut'], isFalse);
        expect(result['exitCode'], isNotNull);
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 4)));
      },
      skip: Platform.isWindows
          ? 'POSIX TERM/KILL semantics are unavailable'
          : false,
    );
  });
}

const Map<String, dynamic> _androidDeviceInfo = <String, dynamic>{
  'id': 'emulator-5554',
  'name': 'Pixel API 35',
  'platform': 'android-arm64',
  'category': 'mobile',
  'emulator': true,
};

List<int> _onePixelPng() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
  '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

List<int> _corruptFirstIdatByte(List<int> original) {
  final bytes = List<int>.from(original);
  var offset = 8;
  while (offset + 12 <= bytes.length) {
    final length =
        (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    final type = ascii.decode(bytes.sublist(offset + 4, offset + 8));
    if (type == 'IDAT' && length > 0) {
      bytes[offset + 8] ^= 0xff;
      return bytes;
    }
    offset += 12 + length;
  }
  throw StateError('PNG fixture has no IDAT body');
}

Map<String, dynamic> _validReadObservation() {
  final digest = List<String>.filled(64, 'a').join();
  return <String, dynamic>{
    'ok': true,
    'schemaVersion': 1,
    'protocolVersion': 15,
    'minSupportedProtocolVersion': 15,
    'maxSupportedProtocolVersion': 15,
    'capabilities': const <String, bool>{'phaseTimingsV1': true},
    'commandId': 'read-native-observation',
    'runId': 'native-run',
    'runtimeInstanceId': 'runtime-native-observation',
    'stateGeneration': 7,
    'stateDigest': digest,
    'snapshotId': 'g7:$digest',
    'errorCursor': 0,
    'errorsSinceCursor': const <Object?>[],
    'activeBlockingSignals': const <Object?>[],
    'result': const <String, Object?>{},
    'structuredError': null,
    'timings': <String, Object?>{
      'totalMs': 0,
      'status': 'partial',
      'phases': <String, Object?>{
        for (final name in const <String>[
          'connect',
          'match',
          'dispatch',
          'settle',
          'delta',
          'logs',
        ])
          name: const <String, Object?>{
            'status': 'unavailable',
            'elapsedMs': null,
            'reason': 'not_applicable:test_read_observation',
          },
        for (final name in const <String>['snapshot', 'serialize'])
          name: const <String, Object?>{'status': 'measured', 'elapsedMs': 0},
      },
    },
  };
}
