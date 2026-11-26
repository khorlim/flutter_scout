import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:flutter_scout/src/agent_session.dart';
import 'package:test/test.dart';

AgentView view(int generation, {required String status, String? reason}) => {
  'ok': true,
  'runId': 'run',
  'runtimeInstanceId': 'one',
  'snapshotId': 'g$generation',
  'screen': 'Probe',
  'visibleText': const ['Working'],
  'safetyEvidenceStatus': 'complete',
  'rendering': {
    'status': status,
    'framesEnabled': status == 'active',
    'lifecycle': status == 'active' ? 'resumed' : 'hidden',
    if (reason != null || status == 'active')
      'headlessDrive': {
        'enabled': true,
        'driving': status == 'driven',
        'reason': ?reason,
        'notice': status == 'driven'
            ? 'HEADLESS: the app is not visible (lifecycle hidden), so '
                  'Flutter stopped rendering; Scout is driving its frames.'
            : 'Headless drive is on but idle: the app renders normally.',
      },
  },
  'interactables': const [
    {'id': 'btn.pause', 'label': 'Pause'},
  ],
};

const tap = <String, dynamic>{
  'method': 'tap',
  'args': ['btn.pause'],
};
const receipt = <String, dynamic>{
  'ok': true,
  'dispatch': 'dispatched',
  'postcondition': 'postcondition_not_requested',
};

void main() {
  group('agent session', () {
    test('flag off: a hidden app stays refused, as before', () async {
      var dispatched = 0;
      final s = AgentSession(
        read: () async => view(1, status: 'suspended'),
        act: (_, _) async {
          dispatched += 1;
          return receipt;
        },
        validate: (_) {},
      );
      addTearDown(s.close);
      final scene = await s.open();
      expect(scene['actionable'], isFalse);
      expect(scene['inputBlockedReason'], 'rendering_suspended');
      expect(scene.containsKey('headless'), isFalse);
      expect(() => s.start(1, tap), throwsA(isA<AgentRejection>()));
      expect(dispatched, 0);
    });

    test('flag off never trusts a driven report', () async {
      final s = AgentSession(
        read: () async => view(1, status: 'driven', reason: 'app_hidden'),
        act: (_, _) async => receipt,
        validate: (_) {},
      );
      addTearDown(s.close);
      final scene = await s.open();
      expect(scene['actionable'], isFalse);
      expect(scene['inputBlockedReason'], 'rendering_suspended');
    });

    test('flag on: a driven hidden app accepts input and says so', () async {
      var dispatched = 0;
      final s = AgentSession(
        read: () async => view(1, status: 'driven', reason: 'screen_locked'),
        act: (_, _) async {
          dispatched += 1;
          return receipt;
        },
        validate: (_) {},
        headlessDrive: true,
      );
      addTearDown(s.close);
      final scene = await s.open();
      expect(scene['actionable'], isTrue);
      final headless = scene['headless'] as Map;
      expect(headless['driving'], isTrue);
      expect(headless['reason'], 'screen_locked');
      expect(headless['lifecycle'], 'hidden');
      expect(headless['notice'], startsWith('HEADLESS:'));
      s.start(1, tap);
      AgentView action;
      do {
        action = await s.nextEvent(2000);
      } while (action['type'] != 'action');
      expect((action['result'] as Map)['ok'], isTrue);
      expect(dispatched, 1);
    });

    test('flag on still refuses a helper that cannot drive', () async {
      final s = AgentSession(
        read: () async => view(1, status: 'suspended'),
        act: (_, _) async => receipt,
        validate: (_) {},
        headlessDrive: true,
      );
      addTearDown(s.close);
      final scene = await s.open();
      expect(scene['actionable'], isFalse);
      expect((scene['headless'] as Map)['driving'], isFalse);
      expect(
        (scene['headless'] as Map)['notice'],
        contains('did not report it'),
      );
    });

    test('foreground succeeds only when the window really renders', () async {
      final s = AgentSession(
        read: () async => view(1, status: 'driven', reason: 'app_hidden'),
        act: (_, _) async => receipt,
        validate: (_) {},
        headlessDrive: true,
      );
      addTearDown(s.close);
      await s.open();
      final result = await s.foreground(
        () async {},
        wait: const Duration(milliseconds: 300),
      );
      expect(result['ok'], isFalse);
      expect((result['error'] as Map)['reason'], 'rendering_still_suspended');
      // Still driven, so the agent can keep acting.
      expect(result['actionable'], isTrue);
    });

    test('foreground is not ok while the login window is in front', () async {
      // An app launched behind the lock never goes hidden: Flutter says
      // active, macOS says loginwindow.
      final s = AgentSession(
        read: () async => view(1, status: 'active'),
        act: (_, _) async => receipt,
        validate: (_) {},
        foregroundAvailable: true,
      );
      addTearDown(s.close);
      await s.open();
      final result = await s.foreground(
        () async {},
        diagnose: () async => {
          'frontmostApp': 'loginwindow',
          'frontmostBundleId': 'com.apple.loginwindow',
          'frontmostIsTarget': false,
        },
        wait: const Duration(milliseconds: 300),
      );
      expect(result['ok'], isFalse);
      final error = result['error'] as Map;
      expect(error['reason'], 'rendering_still_suspended');
      expect(error['message'], contains('Flutter reports rendering active'));
      expect(error['message'], contains('screen is locked'));
      expect(error['nextStep'], contains('unlock the Mac'));
    });

    test('a refusal names the lock macOS reports', () async {
      final locked = view(1, status: 'suspended')
        ..['rendering'] = {
          'status': 'suspended',
          'framesEnabled': true,
          'lifecycle': 'resumed',
          'notVisibleBecause':
              'macOS reports the screen is locked (the login window is in '
              'front)',
          'host': {'hidden': true, 'hiddenReason': 'screen_locked'},
        };
      final s = AgentSession(
        read: () async => locked,
        act: (_, _) async => receipt,
        validate: (_) {},
        foregroundAvailable: true,
      );
      addTearDown(s.close);
      final scene = await s.open();
      final blocked = scene['blockedBy'] as Map;
      expect(blocked['reason'], 'rendering_suspended');
      expect(blocked['message'], contains('screen is locked'));
      expect(blocked['message'], isNot(contains('probably minimized')));
      expect(blocked['nextStep'], contains('unlock'));
      expect(blocked['nextStep'], contains('--headless-drive'));
    });
  });

  group('native capture', () {
    final cli = FlutterScoutCli();

    test('is refused while hidden, locked or unobservable', () {
      for (final rendering in <Map<String, dynamic>?>[
        null,
        {'framesEnabled': false, 'lifecycle': 'hidden'},
        {
          'framesEnabled': false,
          'lifecycle': 'hidden',
          'headlessDrive': {'reason': 'display_asleep'},
        },
        {
          'framesEnabled': true,
          'lifecycle': 'inactive',
          'headlessDrive': {'reason': 'screen_locked'},
        },
      ]) {
        expect(
          () => cli.debugRefuseNativeCaptureFor(rendering),
          throwsA(
            isA<ScoutCliException>()
                .having(
                  (error) => error.code,
                  'code',
                  'native_capture_unavailable_headless',
                )
                .having(
                  (error) => error.message,
                  'message',
                  contains('did not run the macOS screenshot tool'),
                ),
          ),
          reason: '$rendering',
        );
      }
    });

    test('is allowed while the app visibly renders', () {
      cli.debugRefuseNativeCaptureFor({
        'status': 'active',
        'framesEnabled': true,
        'lifecycle': 'resumed',
      });
    });

    test('is refused when macOS hides a window Flutter still renders', () {
      expect(
        () => cli.debugRefuseNativeCaptureFor({
          'status': 'suspended',
          'framesEnabled': true,
          'lifecycle': 'resumed',
          'host': {'hidden': true, 'hiddenReason': 'screen_locked'},
        }),
        throwsA(
          isA<ScoutCliException>().having(
            (error) => error.message,
            'message',
            contains('screen_locked'),
          ),
        ),
      );
    });
  });

  group('host power facts', () {
    tearDown(() => FlutterScoutCli.debugNativeProcessRunner = null);

    test('name what would stop a normal run', () async {
      FlutterScoutCli
          .debugNativeProcessRunner = (executable, arguments, binary) async {
        if (executable.endsWith('pmset') && arguments.length == 1) {
          return ProcessResult(
            1,
            0,
            ' displaysleep         2\n'
                ' sleep                1 (sleep prevented by coreaudiod, '
                'coreaudiod, powerd)\n',
            '',
          );
        }
        if (executable.endsWith('pmset')) {
          return ProcessResult(
            1,
            0,
            '   PreventUserIdleSystemSleep     1\n',
            '',
          );
        }
        if (executable.endsWith('sysadminctl')) {
          return ProcessResult(1, 0, '', 'screenLock delay is immediate\n');
        }
        if (executable.endsWith('osascript')) {
          return ProcessResult(
            1,
            0,
            '{"sessionLockFlag":true,"onConsole":true,'
                '"displayAsleep":true,"loginWindowFrontmost":true}',
            '',
          );
        }
        return ProcessResult(1, 0, '"AppleClamshellCausesSleep" = Yes\n', '');
      };
      final facts = await FlutterScoutCli().debugHostPowerFacts();
      if (!Platform.isMacOS) {
        expect(facts, isNull);
        return;
      }
      expect(facts!['displaySleepMinutes'], 2);
      expect(facts['systemSleepMinutes'], 1);
      expect(facts['systemSleepPreventedBy'], ['coreaudiod', 'powerd']);
      expect(facts['idleSystemSleepPreventedNow'], isTrue);
      expect(facts['screenLockDelay'], 'immediate');
      expect(facts['lidCloseSleeps'], isTrue);
      final stops = facts['normalRunStoppedBy'] as Map;
      expect(stops['displaySleep'], startsWith('yes'));
      expect(stops['screenLock'], contains('as soon as the display sleeps'));
      expect(stops['systemSleep'], startsWith('not now'));
      expect(facts['headlessDriveCovers'], contains('Not system sleep'));
      // Live, not only settings: asleep now, and the immediate lock delay
      // makes the flag mean locked.
      final now = facts['now'] as Map;
      expect(now['displayAsleep'], isTrue);
      expect(now['screenLocked'], isTrue);
      expect(now['hiddenReason'], 'display_asleep');
    });

    test('tell display sleep inside the grace period from a lock', () {
      final cli = FlutterScoutCli();
      // The flag is set the moment the display sleeps, even inside a 300 s
      // grace period: asleep, lock not yet proven.
      var now = cli.debugMacHostVisibilityNow({
        'displayAsleep': true,
        'sessionLockFlag': true,
        'loginWindowFrontmost': true,
        'onConsole': true,
      }, screenLockDelay: '300 seconds');
      expect(now['displayAsleep'], isTrue);
      expect(now['screenLocked'], isNull);
      expect(now['hiddenReason'], 'display_asleep');
      expect(now['screenLockNote'], contains('grace period'));
      // Awake with the login window in front: locked.
      now = cli.debugMacHostVisibilityNow({
        'displayAsleep': false,
        'sessionLockFlag': true,
        'loginWindowFrontmost': true,
      }, screenLockDelay: '300 seconds');
      expect(now['screenLocked'], isTrue);
      expect(now['hiddenReason'], 'screen_locked');
      // A leftover flag on an awake display without the login window does
      // not hide a visible app.
      now = cli.debugMacHostVisibilityNow({
        'displayAsleep': false,
        'sessionLockFlag': true,
        'loginWindowFrontmost': false,
      });
      expect(now['screenLocked'], isNull);
      expect(now['appsHidden'], isFalse);
      // Unreadable facts claim nothing.
      now = cli.debugMacHostVisibilityNow(null);
      expect(now['displayAsleep'], isNull);
      expect(now['appsHidden'], isFalse);
    });
  });
}
