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
        'framesEnabled': true,
        'lifecycle': 'resumed',
      });
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
    });
  });
}
