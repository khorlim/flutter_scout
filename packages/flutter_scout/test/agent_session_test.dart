import 'dart:async';
import 'package:flutter_scout/src/agent_session.dart';
import 'package:test/test.dart';

AgentView view(
  int generation, {
  String status = 'active',
  String runtime = 'one',
  String screen = 'Probe',
  List<String> text = const ['Working'],
  List<Map<String, Object?>> extra = const [],
}) => {
  'ok': true,
  'runId': 'run',
  'runtimeInstanceId': runtime,
  'snapshotId': 'g$generation',
  'screen': screen,
  'visibleText': text,
  'safetyEvidenceStatus': 'complete',
  'rendering': {'status': status, 'framesEnabled': status == 'active'},
  'interactables': [
    {'id': 'btn.pause', 'label': 'Pause'},
    ...extra,
  ],
};
const dispatchedFailure = <String, dynamic>{
  'ok': false,
  'dispatch': 'dispatched',
  'error': {'code': 'expectation_not_met'},
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
Future<AgentView> event(AgentSession session, String type) async {
  for (var i = 0; i < 20; i++) {
    final value = await session.nextEvent(500);
    if (value['type'] == type) return value;
  }
  throw StateError('Missing $type event');
}

void main() {
  test(
    'known failed input can restore visibility without clearing its halt',
    () async {
      var current = view(1);
      final s = AgentSession(
        read: () async => current,
        validate: (_) {},
        act: (_, _) async {
          current = view(2, status: 'suspended');
          return dispatchedFailure;
        },
      );
      addTearDown(s.close);
      await s.open();
      final id = s.start(1, tap)['actionId'];
      await event(s, 'action');
      final restored = await s.foreground(() async {
        current = view(3);
      });
      expect(restored['ok'], isTrue);
      expect(restored['actionable'], isFalse);
      expect(s.scene['hand']['halted'], 'agent_action_failed');
      expect(s.reconcile(id, restored['viewRevision'])['ok'], isTrue);
      expect(s.actions, 1);
    },
  );

  test(
    'explicit foreground shares the hand and requires real resumed eyes',
    () async {
      var current = view(1, status: 'suspended');
      final activate = Completer<void>();
      final s = AgentSession(
        read: () async => current,
        act: (_, _) async => receipt,
        validate: (_) {},
      );
      addTearDown(s.close);
      await s.open();
      expect(() => s.start(1, tap), throwsStateError);
      final pending = s.foreground(() => activate.future);
      current = view(2);
      await s.observe();
      expect(() => s.start(s.scene['viewRevision'], tap), throwsStateError);
      activate.complete();
      final resumed = await pending;
      expect(resumed['ok'], isTrue);
      expect(resumed['actionable'], isTrue);
      expect(s.actions, 0);
      s.start(resumed['viewRevision'], tap);
      await event(s, 'action');
      await expectLater(s.foreground(() async {}), throwsStateError);
    },
  );

  test(
    'foreground cannot clear runtime replacement or native failure',
    () async {
      var current = view(1, status: 'suspended');
      final s = AgentSession(
        read: () async => current,
        act: (_, _) async => receipt,
        validate: (_) {},
      );
      addTearDown(s.close);
      await s.open();
      await expectLater(
        s.foreground(() async {
          throw StateError('denied');
        }),
        throwsStateError,
      );
      expect(s.scene['actionable'], isFalse);
      final result = await s.foreground(() async {
        current = view(2, runtime: 'replacement');
      });
      expect(result['ok'], isFalse);
      expect(s.scene['hand']['halted'], 'agent_runtime_changed');
      expect(s.actions, 0);
    },
  );

  test(
    'live-view rejection names rendering facts and foreground() on macOS',
    () async {
      final current = view(1, status: 'suspended')
        ..['rendering'] = {
          'status': 'suspended',
          'framesEnabled': false,
          'lifecycle': 'hidden',
          'lastFrameworkFrameAgeMs': 13897,
        };
      final s = AgentSession(
        read: () async => current,
        act: (_, _) async => receipt,
        validate: (_) {},
        foregroundAvailable: true,
      );
      addTearDown(s.close);
      await s.open();
      final blocked = s.scene['blockedBy'] as Map;
      expect(s.scene['actionable'], isFalse);
      expect(blocked['reason'], 'rendering_suspended');
      expect(blocked['nextStep'], contains('await scout.foreground()'));
      expect(
        () => s.start(1, tap),
        throwsA(
          isA<AgentRejection>()
              .having((e) => e.code, 'code', 'agent_live_view_unavailable')
              .having((e) => e.message, 'message', contains('lifecycle hidden'))
              .having((e) => e.nextStep, 'nextStep', contains('foreground()'))
              .having((e) => e.details, 'details', {
                'reason': 'rendering_suspended',
                'rendering': {
                  'status': 'suspended',
                  'framesEnabled': false,
                  'lifecycle': 'hidden',
                  'lastFrameworkFrameAgeMs': 13897,
                },
                'foregroundAvailable': true,
                'platform': 'macos',
                'safetyEvidenceStatus': 'complete',
                'activeBlockingSignalCount': 0,
                'errorsSinceCursorCount': 0,
              }),
        ),
      );
      expect(s.actions, 0);
    },
  );

  test(
    'active rendering blocked by safety does not suggest foreground',
    () async {
      final current = view(1)
        ..['activeBlockingSignals'] = [
          {'code': 'flutter_error'},
        ];
      final s = AgentSession(
        read: () async => current,
        act: (_, _) async => receipt,
        validate: (_) {},
        foregroundAvailable: true,
      );
      addTearDown(s.close);
      await s.open();
      expect(
        () => s.start(1, tap),
        throwsA(
          isA<AgentRejection>()
              .having((e) => e.details['reason'], 'reason', 'blocking_signals')
              .having((e) => e.message, 'message', contains('flutter_error'))
              .having(
                (e) => e.nextStep,
                'nextStep',
                isNot(contains('foreground')),
              ),
        ),
      );
    },
  );

  test(
    'observe on a halted session reports its cause, not a generic failure',
    () async {
      var current = view(1);
      final s = AgentSession(
        read: () async => current,
        act: (_, _) async => receipt,
        validate: (_) {},
      );
      addTearDown(s.close);
      await s.open();
      current = view(2, runtime: 'replacement');
      final observed = await s.observe();
      expect(observed['ok'], isFalse);
      expect(
        observed['error'],
        allOf(
          containsPair('code', 'agent_hand_unavailable'),
          containsPair('reason', 'agent_session_stopped'),
        ),
      );
      expect(observed['error']['message'], contains('agent_runtime_changed'));
    },
  );

  test(
    'foreground waits passively for active rendering within its bound',
    () async {
      var current = view(1, status: 'suspended');
      var activated = 0;
      var readsAfterActivation = 0;
      final s = AgentSession(
        read: () async {
          if (activated > 0 && ++readsAfterActivation == 3) current = view(2);
          return current;
        },
        act: (_, _) async => receipt,
        validate: (_) {},
        foregroundAvailable: true,
      );
      addTearDown(s.close);
      await s.open();
      final resumed = await s.foreground(() async => activated++);
      expect(activated, 1, reason: 'activation is never retried');
      expect(readsAfterActivation, greaterThanOrEqualTo(3));
      expect(resumed['ok'], isTrue);
      expect(resumed['actionable'], isTrue);
      expect(resumed.containsKey('error'), isFalse);
    },
  );

  test(
    'foreground that cannot restore rendering names lifecycle and focus',
    () async {
      final current = view(1, status: 'suspended')
        ..['rendering'] = {
          'status': 'suspended',
          'framesEnabled': false,
          'lifecycle': 'inactive',
        };
      var activated = 0;
      final s = AgentSession(
        read: () async => current,
        act: (_, _) async => receipt,
        validate: (_) {},
        foregroundAvailable: true,
      );
      addTearDown(s.close);
      await s.open();
      final result = await s.foreground(
        () async => activated++,
        diagnose: () async => {
          'frontmostApp': 'Other App',
          'frontmostIsTarget': false,
        },
        wait: const Duration(milliseconds: 300),
      );
      expect(activated, 1);
      expect(result['ok'], isFalse);
      expect(result['inputDispatched'], isFalse);
      final error = result['error'] as Map;
      expect(error['code'], 'agent_live_view_unavailable');
      expect(error['reason'], 'rendering_still_suspended');
      expect(error['message'], contains('lifecycle inactive'));
      expect(error['message'], contains('"Other App"'));
      expect(error['nextStep'], contains('do not loop foreground()'));
      expect(
        error['details'],
        allOf(
          containsPair('frontmostIsTarget', false),
          containsPair('activationRequested', true),
        ),
      );
      expect(s.actions, 0);
    },
  );

  test('foreground behind a locked screen says so', () async {
    final current = view(1, status: 'suspended')
      ..['rendering'] = {
        'status': 'suspended',
        'framesEnabled': false,
        'lifecycle': 'hidden',
      };
    final s = AgentSession(
      read: () async => current,
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
        'frontmostIsTarget': false,
      },
      wait: const Duration(milliseconds: 300),
    );
    final error = result['error'] as Map;
    expect(error['reason'], 'rendering_still_suspended');
    expect(error['message'], contains('screen is locked'));
    expect(error['nextStep'], contains('unlock the Mac'));
    expect(s.actions, 0);
  });

  test('foreground on a stopped hand names the blocking cause', () async {
    var current = view(1);
    final s = AgentSession(
      read: () async => current,
      act: (_, _) async => receipt,
      validate: (_) {},
    );
    addTearDown(s.close);
    await s.open();
    current = view(2, runtime: 'replacement');
    await s.observe();
    var activated = false;
    await expectLater(
      s.foreground(() async => activated = true),
      throwsA(
        isA<AgentRejection>()
            .having((e) => e.code, 'code', 'agent_foreground_unavailable')
            .having((e) => e.message, 'message', contains('agent_runtime')),
      ),
    );
    expect(activated, isFalse);
  });

  test(
    'another input requires delivery and acknowledgement of its receipt',
    () async {
      var count = 0;
      final s = AgentSession(
        read: () async => view(1),
        act: (_, _) async {
          count++;
          return receipt;
        },
        validate: (_) {},
      );
      addTearDown(s.close);
      await s.open();
      final ticket = s.start(1, tap);
      await Future<void>.delayed(Duration.zero);
      expect(() => s.acknowledge(ticket['actionId']), throwsStateError);
      expect(() => s.start(1, tap), throwsStateError);
      await event(s, 'action');
      expect(() => s.start(1, tap), throwsStateError);
      s.acknowledge(ticket['actionId']);
      s.start(1, tap);
      await event(s, 'action');
      expect(count, 2);
    },
  );

  test(
    'known failure can be reconciled but never automatically retried',
    () async {
      var count = 0;
      final s = AgentSession(
        read: () async => view(1),
        act: (_, _) async {
          count++;
          return dispatchedFailure;
        },
        validate: (_) {},
      );
      addTearDown(s.close);
      await s.open();
      final id = s.start(1, tap)['actionId'];
      await event(s, 'action');
      expect(() => s.acknowledge(id), throwsStateError);
      // Every halt names the action and the literal recovery call.
      expect(
        () => s.start(s.scene['viewRevision'], tap),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains("reconcile('$id', scene.viewRevision)"),
          ),
        ),
      );
      await s.observe();
      expect(
        s.reconcile(id, s.scene['viewRevision'])['previousActionRetried'],
        false,
      );
      expect(count, 1);
      s.start(s.scene['viewRevision'], tap);
      await event(s, 'action');
      expect(count, 2);
    },
  );

  test(
    'unknown dispatch cannot be cleared by receipt acknowledgement or reconciliation',
    () async {
      final s = AgentSession(
        read: () async => view(1),
        act: (_, _) async => {
          'ok': false,
          'dispatch': 'dispatch_outcome_unknown',
        },
        validate: (_) {},
      );
      addTearDown(s.close);
      await s.open();
      final id = s.start(1, tap)['actionId'];
      await event(s, 'action');
      await s.observe();
      expect(() => s.acknowledge(id), throwsStateError);
      expect(() => s.reconcile(id, s.scene['viewRevision']), throwsStateError);
      expect(() => s.start(s.scene['viewRevision'], tap), throwsStateError);
    },
  );

  test(
    'malformed observations resolve and halt instead of hanging the lane',
    () async {
      for (final bad in [
        {'rendering': 'broken'},
        {'runId': 123},
        {'visibleText': {}},
        {'omittedSections': []},
        {'activeBlockingSignals': 'unknown'},
      ]) {
        final s = AgentSession(
          read: () async => {...view(1), ...bad},
          act: (_, _) async => receipt,
          validate: (_) {},
        );
        final result = await s.open().timeout(const Duration(seconds: 1));
        expect(result['ok'], false);
        expect(() => s.start(1, tap), throwsStateError);
        await s.close();
      }
    },
  );

  test('absence cannot be inferred from omitted text', () async {
    var current = {
      ...view(1),
      'omitted': {'visibleText': 4},
    };
    final s = AgentSession(
      read: () async => current,
      act: (_, _) async => receipt,
      validate: (_) {},
    );
    addTearDown(s.close);
    await s.open();
    s.watch({'gone': 'Loading'}, 1000);
    await s.observe();
    await event(s, 'view');
    expect((await s.nextEvent(0))['type'], 'timeout');
    current = view(2);
    await s.observe();
    expect((await event(s, 'condition'))['status'], 'met');
  });

  test('text and gone match interactable labels and handles too', () async {
    final capsule = {'id': 'btn.data_sync', 'label': 'Data sync'};
    var current = view(1, text: ['45%'], extra: [capsule]);
    final s = AgentSession(
      read: () async => current,
      act: (_, _) async => receipt,
      validate: (_) {},
    );
    addTearDown(s.close);
    await s.open();
    final label = s.watch({'text': 'Data sync'}, 1000)['conditionId'];
    final handle = s.watch({'text': 'btn.data_sync'}, 1000)['conditionId'];
    final gone = s.watch({'gone': 'Data sync'}, 2000)['conditionId'];
    final met = <String>{};
    for (var i = 0; i < 2; i++) {
      final ended = await event(s, 'condition');
      expect(ended['status'], 'met');
      met.add(ended['conditionId'] as String);
    }
    expect(met, {label, handle});
    // The capsule is still there: gone waits.
    expect((await s.nextEvent(0))['type'], 'timeout');
    current = view(2, text: ['Synced']);
    await s.observe();
    final ended = await event(s, 'condition');
    expect([ended['conditionId'], ended['status']], [gone, 'met']);
  });

  test(
    'a control seen by gone needs the full control list to be gone',
    () async {
      final capsule = {'id': 'btn.data_sync', 'label': 'Data sync'};
      var current = view(1, extra: [capsule]);
      final s = AgentSession(
        read: () async => current,
        act: (_, _) async => receipt,
        validate: (_) {},
      );
      addTearDown(s.close);
      await s.open();
      s.watch({'gone': 'Data sync'}, 300);
      s.watch({'gone': 'Loading'}, 1000);
      // Past the maxItems cut the capsule may still exist; plain text (never
      // seen as a control) is still provably gone from the full text list.
      current = {
        ...view(2),
        'omitted': {'interactables': 3},
      };
      await s.observe();
      final text = await event(s, 'condition');
      expect(text['status'], 'met');
      final control = await event(s, 'condition');
      expect(control['status'], 'timeout');
      expect(control['absenceUnproven'], ['interactables']);
    },
  );

  test(
    'observe reports text that came and went since the last observe',
    () async {
      var current = view(1);
      final s = AgentSession(
        read: () async => current,
        act: (_, _) async => receipt,
        validate: (_) {},
        interval: const Duration(hours: 1),
      );
      addTearDown(s.close);
      await s.open();
      current = view(2, text: ['Working', 'Saved Successfully']);
      await s.observe();
      current = view(3);
      await s.observe();
      // Truncated text cannot prove a later toast vanished.
      current = view(4, text: ['Working', 'Undo']);
      await s.observe();
      current = {
        ...view(5),
        'omitted': {'visibleText': 2},
      };
      await s.observe();
      final seen = await s.observeForCaller();
      final transient = seen['transientText'] as List;
      expect(transient.map((e) => e['text']), ['Saved Successfully']);
      expect(transient.single['goneAgoMs'], isA<int>());
      expect(transient.single['shownMs'], isA<int>());
      // Reported once; text still on screen at the caller's observation and
      // then gone is not transient.
      current = view(6, text: ['Working', 'Undo']);
      final next = await s.observeForCaller();
      expect(next.containsKey('transientText'), isFalse);
      current = view(7);
      await s.observe();
      expect(
        (await s.observeForCaller()).containsKey('transientText'),
        isFalse,
      );
    },
  );

  test('quiet conditions time out without a speculative tap', () async {
    var calls = 0;
    final s = AgentSession(
      read: () async => view(1),
      act: (_, _) async {
        calls++;
        return receipt;
      },
      validate: (_) {},
    );
    addTearDown(s.close);
    await s.open();
    s.watch(
      {'text': 'Pause requested'},
      20,
      revision: 1,
      reaction: {'type': 'tap', 'target': 'btn.pause'},
    );
    expect((await event(s, 'reaction'))['status'], 'timeout');
    expect(calls, 0);
  });

  test('eyes observe a brief transition while one hand is pending', () async {
    var current = view(1);
    final pending = Completer<AgentView>();
    var dispatches = 0;
    final session = AgentSession(
      read: () async => current,
      act: (_, _) {
        dispatches++;
        return pending.future;
      },
      validate: (_) {},
      interval: const Duration(hours: 1),
    );
    addTearDown(session.close);
    await session.open();
    final ticket = session.start(1, tap);
    expect(ticket['phase'], 'accepted');
    expect(ticket['dispatch'], 'not_yet_established');
    expect(() => session.start(1, tap), throwsStateError);
    current = view(2, text: ['Pause requested']);
    await session.observe();
    current = view(3);
    await session.observe();
    final seen = <AgentView>[];
    for (var i = 0; i < 3; i++) {
      seen.add(await event(session, 'view'));
    }
    expect((seen[1]['view'] as Map)['visibleText'], ['Pause requested']);
    expect(session.scene['hand']['pendingAction'], ticket['actionId']);
    pending.complete(receipt);
    expect((await event(session, 'action'))['result'], receipt);
    expect(dispatches, 1);
  });

  test(
    'fresh revision required and suspended rendering never authorizes action',
    () async {
      var current = view(1);
      var calls = 0;
      final s = AgentSession(
        read: () async => current,
        act: (_, _) async {
          calls++;
          return receipt;
        },
        validate: (_) {},
      );
      addTearDown(s.close);
      await s.open();
      current = view(2, screen: 'Next');
      await s.observe();
      expect(() => s.start(1, tap), throwsStateError);
      current = view(2, screen: 'Next', status: 'suspended');
      await s.observe();
      expect(() => s.start(s.scene['viewRevision'], tap), throwsStateError);
      expect(calls, 0);
    },
  );

  test(
    'stop reaction prevents future dispatch but drains in-flight action',
    () async {
      var current = view(1);
      final pending = Completer<AgentView>();
      final s = AgentSession(
        read: () async => current,
        act: (_, _) => pending.future,
        validate: (_) {},
      );
      await s.open();
      s.watch(
        {'text': 'Pause requested'},
        1000,
        revision: 1,
        reaction: {'type': 'stop'},
      );
      s.start(1, tap);
      current = view(2, text: ['Pause requested']);
      await s.observe();
      final reaction = await event(s, 'reaction');
      expect(reaction['status'], 'triggered');
      expect(reaction['inflightActionCancelled'], false);
      expect(() => s.start(s.scene['viewRevision'], tap), throwsStateError);
      var closed = false;
      final closing = s.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, false);
      pending.complete(receipt);
      await closing;
      expect((await event(s, 'action'))['result'], receipt);
    },
  );

  test(
    'authorized reaction dispatches one guarded tap without an agent turn',
    () async {
      var current = view(1);
      final seen = <AgentView>[];
      final s = AgentSession(
        read: () async => current,
        act: (a, v) async {
          seen.add(v);
          return receipt;
        },
        validate: (_) {},
      );
      addTearDown(s.close);
      await s.open();
      s.watch(
        {'text': 'Pause requested'},
        1000,
        revision: 1,
        reaction: {'type': 'tap', 'target': 'btn.pause'},
      );
      current = view(2, text: ['Pause requested']);
      await s.observe();
      await event(s, 'action');
      await s.observe();
      await s.observe();
      expect(seen.length, 1);
      expect(seen.single['snapshotId'], 'g2');
    },
  );

  test(
    'reaction cannot cross surfaces or target an unobserved handle',
    () async {
      var current = view(1);
      var calls = 0;
      final s = AgentSession(
        read: () async => current,
        act: (_, _) async {
          calls++;
          return receipt;
        },
        validate: (_) {},
      );
      addTearDown(s.close);
      await s.open();
      expect(
        () => s.watch(
          {'text': 'Pause requested'},
          1000,
          revision: 1,
          reaction: {'type': 'tap', 'target': 'btn.missing'},
        ),
        throwsArgumentError,
      );
      s.watch(
        {'text': 'Pause requested'},
        1000,
        revision: 1,
        reaction: {'type': 'tap', 'target': 'btn.pause'},
      );
      current = {
        ...view(2, text: ['Pause requested']),
        'activeSurface': {'kind': 'dialog'},
      };
      await s.observe();
      expect((await event(s, 'reaction'))['status'], 'context_changed');
      expect(calls, 0);
    },
  );

  test(
    'separate wait cancellation does not cancel actions or app operations',
    () async {
      final s = AgentSession(
        read: () async => view(1),
        act: (_, _) async => receipt,
        validate: (_) {},
      );
      addTearDown(s.close);
      await s.open();
      final job = s.watch({'text': 'Ready'}, 1000);
      final result = s.cancel('wait', conditionId: job['conditionId']);
      expect(result['inflightActionCancelled'], false);
      expect(result['appOperationCancelled'], false);
      expect((await event(s, 'condition'))['status'], 'cancelled');
      expect(() => s.cancel('operation'), throwsArgumentError);
      s.start(1, tap);
      await event(s, 'action');
    },
  );

  test('wait observes completion without taking the hand lane', () async {
    var current = view(1);
    final s = AgentSession(
      read: () async => current,
      act: (_, _) async => receipt,
      validate: (_) {},
    );
    addTearDown(s.close);
    await s.open();
    s.watch({'text': 'Ready'}, 1000);
    s.start(1, tap);
    await event(s, 'action');
    current = view(2, text: ['Ready']);
    await s.observe();
    expect((await event(s, 'condition'))['status'], 'met');
  });

  test('observer and runtime failures invalidate reaction authority', () async {
    var current = view(1);
    final s = AgentSession(
      read: () async => current,
      act: (_, _) async => receipt,
      validate: (_) {},
    );
    addTearDown(s.close);
    await s.open();
    s.watch(
      {'text': 'Pause requested'},
      1000,
      revision: 1,
      reaction: {'type': 'tap', 'target': 'btn.pause'},
    );
    current = view(2, runtime: 'replacement', text: ['Pause requested']);
    await s.observe();
    expect((await event(s, 'stopped'))['reason'], 'agent_runtime_changed');
    expect(s.actions, 0);
    expect(() => s.start(s.scene['viewRevision'], tap), throwsStateError);
  });

  test('unknown action outcome stops future actions without retry', () async {
    var calls = 0;
    final s = AgentSession(
      read: () async => view(1),
      act: (_, _) async {
        calls++;
        throw StateError('transport');
      },
      validate: (_) {},
    );
    addTearDown(s.close);
    await s.open();
    s.start(1, tap);
    final result = (await event(s, 'action'))['result'] as Map;
    expect(result['dispatch'], 'dispatch_outcome_unknown');
    expect(() => s.start(1, tap), throwsStateError);
    expect(calls, 1);
  });

  test(
    'backpressure is explicit and bounded rather than losing transitions silently',
    () async {
      var generation = 0;
      final s = AgentSession(
        read: () async => view(++generation),
        act: (_, _) async => receipt,
        validate: (_) {},
        maxEvents: 4,
      );
      addTearDown(s.close);
      await s.open();
      for (var i = 0; i < 10; i++) {
        await s.observe();
      }
      expect(s.scene['hand']['halted'], 'agent_event_overflow');
      expect(s.scene['metrics']['queuedEvents'], lessThanOrEqualTo(6));
      expect(() => s.start(s.scene['viewRevision'], tap), throwsStateError);
    },
  );

  test(
    'suspended eyes end waits as unavailable, not met or silently timed out',
    () async {
      var current = view(1);
      final s = AgentSession(
        read: () async => current,
        act: (_, _) async => receipt,
        validate: (_) {},
      );
      addTearDown(s.close);
      await s.open();
      s.watch({'text': 'Ready'}, 1000);
      current = view(2, status: 'suspended', text: ['Ready']);
      await s.observe();
      expect(
        (await event(s, 'condition'))['status'],
        'observation_unavailable',
      );
    },
  );

  test(
    'a delivered not_dispatched rejection frees the hand without retry',
    () async {
      var current = view(1);
      final results = <AgentView>[
        {
          'ok': false,
          'dispatch': 'not_dispatched',
          'error': {'code': 'live_view_changed'},
        },
        receipt,
      ];
      var calls = 0;
      final s = AgentSession(
        read: () async => current,
        act: (_, _) async => results[calls++],
        validate: (_) {},
        interval: const Duration(hours: 1),
      );
      addTearDown(s.close);
      await s.open();
      final id = s.start(1, tap)['actionId'] as String;
      await Future<void>.delayed(Duration.zero);
      // The receipt must still be consumed before another input.
      expect(
        () => s.start(s.scene['viewRevision'], tap),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains(id), contains('next()')),
          ),
        ),
      );
      final failed = await event(s, 'action');
      expect((failed['result'] as Map)['dispatch'], 'not_dispatched');
      expect(s.scene['hand']['halted'], isNull);
      expect(s.scene['hand']['unacknowledgedAction'], isNull);
      // No fresh safe view is needed because nothing reached the app.
      current = view(2, status: 'suspended');
      await s.observe();
      // The documented recovery call is harmless; acknowledge explains why
      // it is unnecessary instead of hiding the failure.
      final reconciled = s.reconcile(id, s.scene['viewRevision']);
      expect(reconciled['ok'], isTrue);
      expect(reconciled['previousActionRetried'], isFalse);
      expect(
        () => s.acknowledge(id),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('agent_not_dispatched'),
          ),
        ),
      );
      expect(calls, 1);
      current = view(3);
      await s.observe();
      s.start(s.scene['viewRevision'], tap);
      expect((await event(s, 'action'))['result'], receipt);
      expect(calls, 2);
    },
  );

  test(
    'unknown outcome halt names the action and reconnection recovery',
    () async {
      final s = AgentSession(
        read: () async => view(1),
        act: (_, _) async => {
          'ok': false,
          'dispatch': 'dispatch_outcome_unknown',
        },
        validate: (_) {},
      );
      addTearDown(s.close);
      await s.open();
      final id = s.start(1, tap)['actionId'] as String;
      await event(s, 'action');
      await s.observe();
      final names = isA<StateError>().having(
        (e) => e.message,
        'message',
        allOf(contains(id), contains('close()')),
      );
      expect(() => s.start(s.scene['viewRevision'], tap), throwsA(names));
      expect(() => s.reconcile(id, s.scene['viewRevision']), throwsA(names));
    },
  );

  test(
    'unrelated in-place text ticks do not invalidate an exact target decision',
    () async {
      var current = view(
        1,
        text: ['10:41', 'Resend in 39'],
        extra: [
          {'id': 'btn.resend_in_39', 'kind': 'button', 'enabled': false},
        ],
      );
      final seen = <AgentView>[];
      final s = AgentSession(
        read: () async => current,
        act: (_, observed) async {
          seen.add(observed);
          return receipt;
        },
        validate: (_) {},
        interval: const Duration(hours: 1),
      );
      addTearDown(s.close);
      await s.open();
      current = view(
        2,
        text: ['10:42', 'Resend in 38'],
        extra: [
          {'id': 'btn.resend_in_38', 'kind': 'button', 'enabled': false},
        ],
      );
      await s.observe();
      expect(s.scene['viewRevision'], 2);
      final ticket = s.start(1, tap);
      expect(ticket['ok'], isTrue);
      await event(s, 'action');
      // Fresh preflight compares the decision view, not the later one.
      expect(seen.single['snapshotId'], 'g1');
    },
  );

  test('allowUnrelatedChanges accepts background churn but not changes '
      'that touch the target', () {
    // The agent's brief view: no geometry, so covering is left to the app's
    // dispatch-time hit test.
    Map<String, Object?> control(String id, {bool enabled = true}) => {
      'id': id,
      'kind': 'btn',
      'label': id.substring(4),
      if (!enabled) 'enabled': false,
    };
    AgentView screen(
      int revision,
      List<String> text,
      List<Map<String, Object?>> controls,
    ) => {...view(revision, text: text), 'interactables': controls};
    final pay = control('btn.pay');
    final decision = screen(1, ['Cart', 'Downloading data'], [pay]);
    // A sync toast changes wording and a new list row appears elsewhere.
    final churn = screen(
      2,
      ['Cart', 'Members · Waiting', 'AI Smoke'],
      [pay, control('btn.row_3')],
    );
    expect(
      AgentSession.staleReason(decision, churn, {'btn.pay'}),
      contains('allowUnrelatedChanges'),
    );
    expect(
      AgentSession.targetUnaffected(decision, churn, {
        'btn.pay',
      }, allowUnrelatedChanges: true),
      isTrue,
    );
    final rejected = <String, AgentView>{
      'target disabled': screen(
        2,
        ['Cart'],
        [control('btn.pay', enabled: false)],
      ),
      'target relabelled': screen(
        2,
        ['Cart'],
        [
          {...pay, 'label': 'Paid'},
        ],
      ),
      'target gone': screen(2, ['Cart'], [control('btn.dismiss')]),
      'new surface': {
        ...screen(2, ['Cart'], [pay]),
        'activeSurface': {'kind': 'dialog'},
      },
      'other screen': {
        ...screen(2, ['Cart'], [pay]),
        'screen': 'Next',
      },
      'field value': {
        ...screen(2, ['Cart'], [pay]),
        'fieldValues': {'field.amount': '9'},
      },
    };
    for (final entry in rejected.entries) {
      expect(
        AgentSession.staleReason(decision, entry.value, {
          'btn.pay',
        }, allowUnrelatedChanges: true),
        isNotNull,
        reason: entry.key,
      );
    }
  });

  test('a stale rejection names each changed field with its old and new '
      'value', () {
    final decision = {
      ...view(1, text: ['Cart']),
      'rendering': {
        'status': 'active',
        'framesEnabled': true,
        'lifecycle': 'resumed',
      },
    };
    final hidden = {
      ...decision,
      'rendering': {
        'status': 'suspended',
        'framesEnabled': false,
        'lifecycle': 'hidden',
      },
    };
    final rendering = AgentSession.staleChange(decision, hidden, {'btn.pay'})!;
    expect(rendering.reason, 'rendering changed');
    expect(rendering.changes, [
      {'field': 'rendering.status', 'before': 'active', 'after': 'suspended'},
      {'field': 'rendering.framesEnabled', 'before': true, 'after': false},
      {'field': 'rendering.lifecycle', 'before': 'resumed', 'after': 'hidden'},
    ]);
    final total = AgentSession.staleChange(
      decision,
      {
        ...decision,
        'visibleText': ['Cart', 'Total RM 12.00'],
      },
      {'btn.pause'},
    )!;
    expect(total.changes.single['field'], 'visibleText');
    expect(total.changes.single['appeared'], ['Total RM 12.00']);
    final retargeted = AgentSession.staleChange(
      {
        ...decision,
        'interactables': [
          {'id': 'btn.pay', 'kind': 'btn', 'enabled': false},
        ],
      },
      {
        ...decision,
        'interactables': [
          {'id': 'btn.pay', 'kind': 'btn', 'enabled': true},
        ],
      },
      {'btn.pay'},
    )!;
    expect(retargeted.changes, [
      {
        'field': 'interactables[btn.pay].enabled',
        'before': false,
        'after': true,
      },
    ]);
  });

  test('a handle that now names another control is refused as stale even '
      'with allowUnrelatedChanges', () {
    Map<String, Object?> tile(int instance) => {
      'id': 'btn.thai_yoga',
      'kind': 'btn',
      'label': 'Thai Yoga',
      'instance': instance,
      'enabled': true,
    };
    final decision = {
      ...view(1),
      'interactables': [tile(10)],
    };
    final moved = {
      ...view(2),
      'interactables': [tile(11)],
    };
    final stale = AgentSession.staleChange(decision, moved, {
      'btn.thai_yoga',
    }, allowUnrelatedChanges: true)!;
    expect(stale.reason, 'target btn.thai_yoga changed');
    expect(stale.changes, [
      {
        'field': 'interactables[btn.thai_yoga].instance',
        'before': 10,
        'after': 11,
      },
    ]);
    expect(
      AgentSession.targetUnaffected(
        decision,
        {
          ...view(2),
          'interactables': [tile(10)],
        },
        {'btn.thai_yoga'},
        allowUnrelatedChanges: true,
      ),
      isTrue,
    );
  });

  test('a keypad dialog stays the same surface while its display, its '
      'guessed name and a suggestion change', () {
    final keys = [
      for (var i = 1; i <= 3; i++) {'id': 'btn.key_$i', 'kind': 'btn'},
    ];
    AgentView pad(int revision, String display, {int instance = 7}) => {
      ...view(revision, screen: '${display}Surface', text: [display]),
      'activeSurface': {
        'kind': 'modal',
        'label': display,
        'screen': '${display}Surface',
        'source': 'regionTitle',
        'instance': instance,
      },
      'interactables': [
        if (display.length > 3) {'id': 'btn.sofa', 'kind': 'btn'},
        ...keys,
      ],
    };
    final decision = pad(1, '+60');
    final typed = pad(5, '+60 1512');
    expect(
      AgentSession.targetUnaffected(decision, typed, {
        'btn.key_2',
      }, allowUnrelatedChanges: true),
      isTrue,
    );
    // Without the authority, the new suggestion row still matters.
    expect(
      AgentSession.staleReason(decision, typed, {'btn.key_2'}),
      contains('appeared'),
    );
    // Another dialog with the same keys is not the same surface.
    expect(
      AgentSession.staleReason(decision, pad(5, '+60 1512', instance: 8), {
        'btn.key_2',
      }, allowUnrelatedChanges: true),
      'screen changed',
    );
  });

  test('a scroll on a named list is scoped to that list', () {
    final action = {
      'method': 'scroll',
      'args': ['up'],
      'params': {'target': 'scroll.day_grid', 'distance': -400},
    };
    expect(AgentSession.scopedTargets(action), {'scroll.day_grid'});
    AgentView grid(int revision, {required bool atStart}) => {
      ...view(revision, text: ['10:4$revision']),
      'scrollables': [
        {
          'id': 'scroll.day_grid',
          'axis': 'vertical',
          'axisDirection': 'down',
          'atStart': atStart,
        },
      ],
    };
    expect(
      AgentSession.targetUnaffected(
        grid(1, atStart: true),
        grid(2, atStart: false),
        {'scroll.day_grid'},
        allowUnrelatedChanges: true,
      ),
      isTrue,
    );
    expect(
      AgentSession.staleReason(
        grid(1, atStart: true),
        view(2, text: ['10:42']),
        {'scroll.day_grid'},
        allowUnrelatedChanges: true,
      ),
      'target scroll.day_grid changed',
    );
  });

  test('real screen or target changes still reject a stale decision', () async {
    final decision = view(1, text: ['10:41']);
    final changes = <String, AgentView>{
      'route': view(2, screen: 'Next', text: ['10:41']),
      'new text': view(2, text: ['10:41', 'Invalid code']),
      'target': {
        ...view(2, text: ['10:41']),
        'interactables': [
          {'id': 'btn.pause', 'label': 'Pause', 'enabled': false},
        ],
      },
      'control shape': view(
        2,
        text: ['10:41'],
        extra: [
          {'id': 'btn.cancel', 'kind': 'button'},
        ],
      ),
      'surface': {
        ...view(2, text: ['10:41']),
        'activeSurface': {'kind': 'dialog'},
      },
    };
    for (final entry in changes.entries) {
      expect(
        AgentSession.targetUnaffected(decision, entry.value, {'btn.pause'}),
        isFalse,
        reason: entry.key,
      );
    }
    expect(
      AgentSession.targetUnaffected(decision, view(2, text: ['10:42']), {
        'btn.pause',
      }),
      isTrue,
    );
    // Only exact handle actions are scoped; text, coordinates and gestures
    // keep exact revision freshness.
    expect(AgentSession.scopedTargets(tap), {'btn.pause'});
    // A double tap or right click on a handle still presses only that handle.
    expect(
      AgentSession.scopedTargets({
        'method': 'tap',
        'args': ['btn.pause'],
        'params': {'taps': 2, 'intervalMs': 80, 'button': 'secondary'},
      }),
      {'btn.pause'},
    );
    expect(
      AgentSession.scopedTargets({
        'method': 'input',
        'args': ['value'],
        'params': {'target': 'field.code'},
      }),
      {'field.code'},
    );
    for (final action in <AgentView>[
      {
        'method': 'tap-text',
        'args': ['Pause'],
      },
      {
        'method': 'tap',
        'args': ['10', '20'],
      },
      {
        'method': 'tap',
        'args': ['btn.pause'],
        'params': {'taps': 2, 'expectText': 'Paused'},
      },
      {
        'method': 'scroll',
        'args': ['down'],
      },
      {'method': 'back'},
    ]) {
      expect(AgentSession.scopedTargets(action), isNull, reason: '$action');
    }

    var current = decision;
    final s = AgentSession(
      read: () async => current,
      act: (_, _) async => receipt,
      validate: (_) {},
      interval: const Duration(hours: 1),
    );
    addTearDown(s.close);
    await s.open();
    current = view(2, text: ['10:42']);
    await s.observe();
    expect(
      () => s.start(1, {
        'method': 'tap-text',
        'args': ['Pause'],
      }),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('agent_view_changed'),
        ),
      ),
    );
    current = view(3, screen: 'Next', text: ['10:43']);
    await s.observe();
    expect(() => s.start(1, tap), throwsStateError);
    expect(s.actions, 0);
  });

  test('scene names why input is blocked; old helpers still observe', () async {
    var current = view(1, status: 'suspended');
    final s = AgentSession(
      read: () async => current,
      act: (_, _) async => receipt,
      validate: (_) {},
    );
    addTearDown(s.close);
    final ready = await s.open();
    expect(ready['actionable'], isFalse);
    expect(ready['inputBlockedReason'], 'rendering_suspended');
    current = {
      ...view(2),
      'missingHelperCapabilities': ['liveRenderingGuardV1'],
    };
    final scene = await s.observe();
    expect(scene['ok'], isTrue);
    expect(scene['inputBlockedReason'], 'helper_capability_missing');
    expect(
      () => s.start(scene['viewRevision'], tap),
      throwsA(
        predicate((e) => '$e'.contains('agent_helper_capability_missing')),
      ),
    );
    s.watch({'text': 'Working'}, 1000);
    expect((await event(s, 'condition'))['status'], 'met');
    current = view(3);
    final ready2 = await s.observe();
    expect(ready2['actionable'], isTrue);
    expect(ready2['inputBlockedReason'], isNull);
    s.start(ready2['viewRevision'], tap);
    expect(s.scene['inputBlockedReason'], 'action_in_flight');
    await event(s, 'action');
    expect(s.scene['inputBlockedReason'], 'receipt_unacknowledged');
    expect(s.actions, 1);
  });
}
