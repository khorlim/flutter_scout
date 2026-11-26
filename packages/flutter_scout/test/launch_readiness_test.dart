import 'package:flutter_scout/flutter_scout.dart';
import 'package:test/test.dart';

void main() {
  final cli = FlutterScoutCli();

  group('launch helper base window', () {
    final confirmed = DateTime.utc(2026, 11, 26, 10);

    test('scales with the observed post-build phase', () {
      Duration window(Duration postBuild) =>
          cli.debugLaunchHelperReadyBaseWindow(
            buildDoneAt: confirmed.subtract(postBuild),
            vmServiceFoundAt: null,
            confirmedAt: confirmed,
          );
      expect(window(const Duration(seconds: 4)), const Duration(seconds: 20));
      expect(window(const Duration(seconds: 60)), const Duration(seconds: 60));
      // The measured 131 s file sync gets the longest base window.
      expect(window(const Duration(seconds: 131)), const Duration(minutes: 2));
    });

    test('falls back to the minimum without a post-build mark', () {
      expect(
        cli.debugLaunchHelperReadyBaseWindow(
          buildDoneAt: null,
          vmServiceFoundAt: null,
          confirmedAt: confirmed,
        ),
        const Duration(seconds: 20),
      );
    });
  });

  group('helper readiness wait', () {
    const running = {
      'vmAnswered': true,
      'isolateState': 'running',
      'extensionCount': 3,
    };

    test('returns at once when the helper answers', () async {
      final result = await cli.debugAwaitHelperReadiness(
        probes: (_) => {'ready': true, ...running},
        activity: (_) => const {},
        baseWindow: const Duration(seconds: 20),
        hardLimit: const Duration(minutes: 20),
      );
      expect(result['ready'], isTrue);
      expect(result['stopReason'], 'ready');
      expect(result['waitedMs'], lessThan(2000));
    });

    test('keeps waiting past the base window while output continues', () async {
      final stages = <String>[];
      final result = await cli.debugAwaitHelperReadiness(
        // The helper registers after 70 s on a loaded machine.
        probes: (elapsed) => {
          'ready': elapsed >= const Duration(seconds: 70),
          ...running,
        },
        // The app keeps printing while it starts.
        activity: (elapsed) => {'logBytes': elapsed.inSeconds ~/ 5},
        baseWindow: const Duration(seconds: 20),
        hardLimit: const Duration(minutes: 20),
        progressStages: stages,
      );
      expect(result['ready'], isTrue);
      expect(result['waitedMs'], greaterThanOrEqualTo(70000));
      expect(
        stages,
        containsAll(['await_helper_ready', 'helper_wait_extended']),
      );
    });

    test('process CPU and isolate state changes count as progress', () async {
      final result = await cli.debugAwaitHelperReadiness(
        probes: (elapsed) => {
          'ready': elapsed >= const Duration(seconds: 40),
          'vmAnswered': true,
          // Paused at start until 30 s, then running.
          'isolateState': elapsed < const Duration(seconds: 30)
              ? 'paused_at_start'
              : 'running',
        },
        activity: (elapsed) => {'cpuSeconds': elapsed.inSeconds.toDouble()},
        baseWindow: const Duration(seconds: 20),
        hardLimit: const Duration(minutes: 20),
      );
      expect(result['ready'], isTrue);
    });

    test('stops at the hard limit even while progress continues', () async {
      final result = await cli.debugAwaitHelperReadiness(
        probes: (_) => {'ready': false, ...running},
        activity: (elapsed) => {'logBytes': elapsed.inMilliseconds},
        baseWindow: const Duration(seconds: 20),
        hardLimit: const Duration(seconds: 45),
      );
      expect(result['ready'], isFalse);
      expect(result['stopReason'], 'hard_timeout');
      expect(result['extended'], isTrue);
      expect(result['waitedMs'], inInclusiveRange(45000, 47000));
      expect(result['reachable'], isTrue);
      expect(result['evidence'], contains('reached the hard launch limit'));
    });

    test('stops after the base window when nothing progresses', () async {
      final result = await cli.debugAwaitHelperReadiness(
        probes: (_) => {'ready': false, ...running},
        activity: (_) => const {'logBytes': 10, 'cpuSeconds': 1.0},
        baseWindow: const Duration(seconds: 20),
        hardLimit: const Duration(minutes: 20),
      );
      expect(result['stopReason'], 'no_progress');
      expect(result['extended'], isFalse);
      expect(result['waitedMs'], inInclusiveRange(20000, 22000));
      expect(result['evidence'], contains('no progress was observed'));
      expect(result['evidence'], contains('Waited 2'));
    });

    test('names a VM service that never answered', () async {
      final result = await cli.debugAwaitHelperReadiness(
        probes: (_) => {
          'ready': false,
          'reason': 'helper_extension_check_failed',
        },
        activity: (elapsed) => {'logBytes': elapsed.inMilliseconds},
        baseWindow: const Duration(seconds: 20),
        hardLimit: const Duration(minutes: 20),
      );
      expect(result['stopReason'], 'vm_service_unresponsive');
      expect(result['reachable'], isFalse);
      expect(result['evidence'], contains('the VM service never answered'));
    });

    test('a running binding without the helper does not wait for chatty '
        'output', () async {
      final result = await cli.debugAwaitHelperReadiness(
        probes: (_) => {
          'ready': false,
          ...running,
          'frameworkExtensions': true,
        },
        activity: (elapsed) => {'logBytes': elapsed.inMilliseconds},
        baseWindow: const Duration(seconds: 8),
        hardLimit: const Duration(minutes: 20),
      );
      expect(result['stopReason'], 'helper_absent_after_framework_ready');
      expect(result['waitedMs'], inInclusiveRange(20000, 23000));
      expect(result['hint'], contains('FlutterScoutBinding.ensureInitialized'));
    });

    test('an exited runner with a silent VM stops at once', () async {
      final result = await cli.debugAwaitHelperReadiness(
        probes: (_) => {
          'ready': false,
          'reason': 'helper_extension_check_failed',
        },
        activity: (_) => const {'ownerAlive': false},
        baseWindow: const Duration(seconds: 20),
        hardLimit: const Duration(minutes: 20),
      );
      expect(result['stopReason'], 'runner_exited');
      expect(result['waitedMs'], lessThan(2000));
      expect(result['reachable'], isFalse);
    });

    test(
      'a live owned run stays reachable when the VM stops answering',
      () async {
        final result = await cli.debugAwaitHelperReadiness(
          probes: (_) => {
            'ready': false,
            'reason': 'helper_extension_check_failed',
          },
          activity: (_) => const {'ownerAlive': true},
          baseWindow: const Duration(seconds: 20),
          hardLimit: const Duration(minutes: 20),
        );
        expect(result['stopReason'], 'vm_service_unresponsive');
        expect(result['reachable'], isTrue);
      },
    );
  });
}
