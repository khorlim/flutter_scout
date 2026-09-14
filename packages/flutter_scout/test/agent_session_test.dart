import 'dart:async';
import 'package:flutter_scout/src/agent_session.dart';
import 'package:test/test.dart';

AgentView view(
  int generation, {
  String status = 'active',
  String runtime = 'one',
  List<String> text = const ['Working'],
}) => {
  'ok': true,
  'runId': 'run',
  'runtimeInstanceId': runtime,
  'snapshotId': 'g$generation',
  'screen': 'Probe',
  'visibleText': text,
  'safetyEvidenceStatus': 'complete',
  'rendering': {'status': status, 'framesEnabled': status == 'active'},
  'interactables': [
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
Future<AgentView> event(AgentSession session, String type) async {
  for (var i = 0; i < 20; i++) {
    final value = await session.nextEvent(500);
    if (value['type'] == type) return value;
  }
  throw StateError('Missing $type event');
}

void main() {
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
      current = view(2);
      await s.observe();
      expect(() => s.start(1, tap), throwsStateError);
      current = view(2, status: 'suspended');
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
}
