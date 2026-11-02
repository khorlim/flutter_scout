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
