import 'package:flutter_scout/flutter_scout.dart';
import 'package:test/test.dart';

void main() {
  group('runtime hard-signal classification', () {
    test('every supported log signal has closed provenance and freshness', () {
      final now = DateTime.now().toUtc().toIso8601String();
      final cases = <({String line, String kind, String severity, bool blocking})>[
        (
          line: '[$now] [VM_STDERR] Exception caught by widgets library',
          kind: 'flutter_framework_error',
          severity: 'blocking',
          blocking: true,
        ),
        (
          line: '[$now] [VM_STDERR] Unhandled exception: fixture failure',
          kind: 'unhandled_exception',
          severity: 'blocking',
          blocking: true,
        ),
        (
          line: '[$now] [VM_STDERR] A RenderFlex overflowed by 42 pixels',
          kind: 'render_overflow',
          severity: 'blocking',
          blocking: true,
        ),
        (
          line: '[$now] [VM_LOG] [fixture] level=1000 seq=1 fatal app state',
          kind: 'native_runtime_error',
          severity: 'blocking',
          blocking: true,
        ),
        (
          line:
              '[$now] [VM_LOG] [fixture] level=1000 seq=2 app invariant failed',
          kind: 'app_log_error',
          severity: 'non_blocking',
          blocking: false,
        ),
        (
          line:
              '[$now] [VM_LOG] [fixture] level=900 seq=3 camera permission denied',
          kind: 'permission_denied',
          severity: 'warning',
          blocking: false,
        ),
        (
          line:
              '[$now] [VM_LOG] [fixture] level=900 seq=4 HTTP request failed with status 503',
          kind: 'app_request_failure',
          severity: 'non_blocking',
          blocking: false,
        ),
        (
          line:
              '[$now] [VM_STDERR] NetworkImageLoadException: HTTP request failed',
          kind: 'image_loading_failure',
          severity: 'non_blocking',
          blocking: false,
        ),
        (
          line: '[$now] [VM_STDERR] Build error: invalid constant value',
          kind: 'flutter_build_error',
          severity: 'blocking',
          blocking: true,
        ),
        (
          line:
              '[$now] [FLUTTER_STDERR] lib/main.dart:26:14: Error: Undefined name.',
          kind: 'flutter_compile_error',
          severity: 'blocking',
          blocking: true,
        ),
        (
          line:
              '[$now] [VM_STDERR] Hot reload was rejected after fixing the above error',
          kind: 'flutter_hot_update_rejected',
          severity: 'blocking',
          blocking: true,
        ),
      ];

      for (final fixture in cases) {
        final signals = FlutterScoutCli().debugRecentLogSignalsFromLines([
          fixture.line,
        ]);
        expect(signals, hasLength(1), reason: fixture.line);
        final signal = signals.single;
        expect(signal['kind'], fixture.kind, reason: fixture.line);
        expect(signal['severity'], fixture.severity, reason: fixture.line);
        expect(signal['blocking'], fixture.blocking, reason: fixture.line);
        expect(
          signal['identity'],
          startsWith('log:unbound:'),
          reason: fixture.line,
        );
        expect(signal['timestamp'], now, reason: fixture.line);
        expect(signal['timestampStatus'], 'observed_in_log');
        expect(signal['ageStatus'], 'measured');
        expect(signal['ageMs'], isA<int>());
        expect(signal['freshness'], 'fresh');
        expect(signal['staleness'], 'fresh');
        expect(signal['stale'], isFalse);
        expect(signal['phase'], 'debug_classification');
        expect(signal['cursor'], greaterThan(0));
        expect(signal['logCursor'], signal['cursor']);
        expect(
          signal['provenance'],
          allOf(
            containsPair('source', 'scout_owned_runtime_log'),
            contains('stream'),
          ),
        );
      }
    });

    test('classifies supported Flutter image-provider failures precisely', () {
      final now = DateTime.now().toUtc().toIso8601String();
      final cases = <String, String>{
        '[$now] [VM_STDERR] Exception caught by image resource service':
            'image_loading_failure',
        '[$now] [VM_STDERR] Unable to load asset: assets/missing.png':
            'image_loading_failure',
        '[$now] [VM_STDERR] NetworkImageLoadException: HTTP request failed':
            'image_loading_failure',
        '[$now] [VM_LOG] [fixture] level=1000 seq=1 '
                'SCOUT_FAULT_IMAGE image loading failed: SocketException':
            'image_loading_failure',
      };

      for (final entry in cases.entries) {
        final signals = FlutterScoutCli().debugRecentLogSignalsFromLines([
          entry.key,
        ]);
        expect(signals, hasLength(1), reason: entry.key);
        expect(signals.single['kind'], entry.value, reason: entry.key);
        expect(signals.single['blocking'], isFalse, reason: entry.key);
        expect(
          signals.single['provenance'],
          containsPair('source', 'scout_owned_runtime_log'),
        );
        expect(signals.single['cursor'], greaterThan(0));
        expect(signals.single['freshness'], 'fresh');
      }
    });

    test('old log evidence stays stale and cannot masquerade as fresh', () {
      final old = DateTime.now()
          .toUtc()
          .subtract(const Duration(minutes: 2))
          .toIso8601String();
      final signals = FlutterScoutCli().debugRecentLogSignalsFromLines([
        '[$old] [VM_STDERR] A RenderFlex overflowed by 9 pixels',
      ]);

      expect(signals, hasLength(1));
      expect(signals.single['kind'], 'render_overflow');
      expect(signals.single['freshness'], 'stale');
      expect(signals.single['staleness'], 'stale');
      expect(signals.single['stale'], isTrue);
      expect(signals.single['ageMs'], greaterThanOrEqualTo(120000));
      expect(signals.single['timestampStatus'], 'observed_in_log');
    });

    test(
      'does not relabel a generic failed HTTP request as an image error',
      () {
        final now = DateTime.now().toUtc().toIso8601String();
        final signals = FlutterScoutCli().debugRecentLogSignalsFromLines([
          '[$now] [VM_LOG] [fixture] level=900 seq=2 '
              'HTTP request failed with statusCode: 503',
        ]);

        expect(signals, hasLength(1));
        expect(signals.single['kind'], 'app_request_failure');
      },
    );

    test('classifies hot reload and restart rejection as blocking', () {
      final now = DateTime.now().toUtc().toIso8601String();
      for (final message in <String>[
        'Hot reload was rejected after fixing the above error',
        'Could not hot restart because the program contains compile errors',
      ]) {
        final signals = FlutterScoutCli().debugRecentLogSignalsFromLines([
          '[$now] [VM_STDERR] $message',
        ]);
        expect(signals, hasLength(1), reason: message);
        expect(
          signals.single,
          containsPair('kind', 'flutter_hot_update_rejected'),
          reason: message,
        );
        expect(signals.single['severity'], 'blocking', reason: message);
        expect(signals.single['blocking'], isTrue, reason: message);
        expect(signals.single['phase'], 'debug_classification');
      }
    });

    test('hot update rejection preserves bounded compiler diagnostics', () {
      final now = DateTime.now().toUtc().toIso8601String();
      final acknowledgement = FlutterScoutCli()
          .debugHotUpdateFailureAcknowledgementFromLines('reload', [
            '[$now] [FLUTTER_STDOUT] Performing hot reload...',
            '[$now] [FLUTTER_STDERR] lib/main.dart:26:14: Error: '
                "The getter 'missingScoutTitle' isn't defined.",
            '[$now] [FLUTTER_STDERR] Try correcting the name.',
            '[$now] [FLUTTER_STDERR]       title: missingScoutTitle,',
            '[$now] [FLUTTER_STDERR]              ^^^^^^^^^^^^^^^^^',
          ]);

      expect(acknowledgement, isNotNull);
      expect(acknowledgement!['ok'], isFalse);
      expect(acknowledgement['rejected'], isTrue);
      expect(acknowledgement['rejectionReason'], 'dart_compile_error');
      expect(acknowledgement['terminalRejectionObserved'], isFalse);
      expect(
        acknowledgement['message'],
        contains('lib/main.dart:26:14: Error:'),
      );
      expect(
        acknowledgement['compilerDiagnostics'],
        equals([
          "lib/main.dart:26:14: Error: The getter 'missingScoutTitle' isn't defined.",
          'Try correcting the name.',
          'title: missingScoutTitle,',
          '^^^^^^^^^^^^^^^^^',
        ]),
      );
      expect(acknowledgement['compilerDiagnosticsTruncated'], isFalse);
      expect(acknowledgement['cursor'], greaterThan(0));
    });

    test(
      'terminal hot update rejection remains actionable without a compiler line',
      () {
        final now = DateTime.now().toUtc().toIso8601String();
        final acknowledgement = FlutterScoutCli()
            .debugHotUpdateFailureAcknowledgementFromLines('restart', [
              '[$now] [FLUTTER_STDERR] Could not hot restart because the '
                  'program contains compile errors.',
            ]);

        expect(acknowledgement, isNotNull);
        expect(acknowledgement!['rejectionReason'], 'flutter_tool_rejected');
        expect(acknowledgement['terminalRejectionObserved'], isTrue);
        expect(
          acknowledgement['message'],
          'Could not hot restart because the program contains compile errors.',
        );
        expect(acknowledgement.containsKey('compilerDiagnostics'), isFalse);
      },
    );

    test('hot update compiler diagnostics stay within their line bound', () {
      final now = DateTime.now().toUtc().toIso8601String();
      final acknowledgement = FlutterScoutCli()
          .debugHotUpdateFailureAcknowledgementFromLines('reload', [
            '[$now] [FLUTTER_STDERR] lib/main.dart:1:1: Error: Broken.',
            for (var index = 0; index < 20; index++)
              '[$now] [FLUTTER_STDERR] diagnostic context $index',
          ]);

      expect(acknowledgement, isNotNull);
      expect(
        acknowledgement!['compilerDiagnostics'],
        isA<List<Object?>>().having((lines) => lines.length, 'length', 12),
      );
      expect(acknowledgement['compilerDiagnosticsTruncated'], isTrue);
    });

    test(
      'currently visible blocking surfaces fail actions and survive compact output',
      () {
        final signal = <String, Object?>{
          'cursor': 8,
          'type': 'visible_error_surface',
          'blocking': true,
          'active': true,
          'freshness': 'currently_active',
          'stale': false,
        };
        final cli = FlutterScoutCli();
        final result = cli.debugAssertActionHasNoErrors(<String, dynamic>{
          'ok': true,
          'errorsSinceCursor': const <Object?>[],
          'activeBlockingSignals': <Object?>[signal],
          'runtimeHealth': 'runtime_blocked',
        });

        expect(result['ok'], isFalse);
        expect((result['error'] as Map)['code'], 'blocking_errors_observed');
        expect(result['activeBlockingErrors'], hasLength(1));
        final compact = cli.debugCompactActionResult(result);
        expect(compact['runtimeHealth'], 'runtime_blocked');
        expect(compact['activeBlockingSignals'], hasLength(1));
      },
    );
  });
}
