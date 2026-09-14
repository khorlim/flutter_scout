import 'dart:async';

import 'package:flutter_scout/src/live_view_loop.dart';
import 'package:test/test.dart';

Map<String, dynamic> view(String id, {String runtime = 'runtime-1'}) => {
  'ok': true,
  'runId': 'run-1',
  'runtimeInstanceId': runtime,
  'snapshotId': id,
  'screen': id,
};

void main() {
  test(
    'transient expectation settles before handing off its next view',
    () async {
      var current = view('home');
      var actions = 0;
      final loop = LiveViewLoop(
        read: () async => current,
        act: (_, _) async {
          actions++;
          current = view('dialog-in-transition');
          return {
            'ok': true,
            'stability': {'state': 'transient'},
          };
        },
        settle: () async {
          current = view('dialog-ready');
          return {
            'ok': true,
            'stability': {'actionable': true},
          };
        },
      );
      final initial = await loop.observe();
      final result = await loop.perform({
        'method': 'tap',
        'viewId': initial['viewId'],
      });
      expect(result['ok'], true);
      expect((result['view'] as Map)['screen'], 'dialog-ready');
      expect(actions, 1);
      expect(result['settling'], isNotNull);
    },
  );

  test(
    'failed readiness preserves dispatched action without claiming success',
    () async {
      final loop = LiveViewLoop(
        read: () async => view('screen'),
        act: (_, _) async => {
          'ok': true,
          'dispatch': 'dispatched',
          'stability': {'state': 'transient'},
        },
        settle: () async => {
          'ok': true,
          'stability': {'actionable': false},
        },
      );
      final initial = await loop.observe();
      final result = await loop.perform({
        'method': 'tap',
        'viewId': initial['viewId'],
      });
      expect(result['ok'], false);
      expect((result['action'] as Map)['dispatch'], 'dispatched');
      expect(result['view'], isNotNull);
    },
  );

  test(
    'unknown fields cannot select another app or bypass the live contract',
    () async {
      var attempts = 0;
      final loop = LiveViewLoop(
        read: () async => view('home'),
        act: (_, _) async {
          attempts++;
          return {'ok': true};
        },
      );
      final first = await loop.observe();
      final result = await loop.perform({
        'method': 'tap',
        'viewId': first['viewId'],
        'app': 'another-session',
      });
      expect(result['ok'], false);
      expect(attempts, 0);
    },
  );
  test(
    'action returns its resulting view without another agent inspect',
    () async {
      var current = view('home');
      final loop = LiveViewLoop(
        read: () async => current,
        act: (request, observed) async {
          expect(observed['snapshotId'], 'home');
          current = view('dialog');
          return {
            'ok': true,
            'dispatch': 'dispatched',
            'runtimeHealth': 'runtime_clean',
          };
        },
      );
      final initial = await loop.observe();
      final result = await loop.perform({
        'method': 'tap',
        'viewId': initial['viewId'],
        'args': ['btn.open'],
      });
      expect(result['ok'], true);
      expect((result['view'] as Map)['screen'], 'dialog');
      expect(result['viewId'], isNot(initial['viewId']));
      expect(result['images'], 'manual');
    },
  );

  test(
    'background updates do not silently authorize an old decision',
    () async {
      var current = view('home');
      var dispatched = 0;
      final loop = LiveViewLoop(
        read: () async => current,
        act: (_, _) async {
          dispatched++;
          return {'ok': true};
        },
      );
      final initial = await loop.observe();
      current = view('unexpected-dialog');
      await loop.refreshInBackground();
      final result = await loop.perform({
        'method': 'tap',
        'viewId': initial['viewId'],
        'args': ['btn.save'],
      });
      expect(dispatched, 0);
      expect(result['dispatch'], 'not_dispatched');
      expect((result['error'] as Map)['code'], 'live_view_changed');
      expect((result['view'] as Map)['screen'], 'unexpected-dialog');
    },
  );

  test(
    'identical observations coalesce but restarted runtimes invalidate views',
    () async {
      var current = view('home');
      final loop = LiveViewLoop(
        read: () async => current,
        act: (_, _) async => {'ok': true},
      );
      final first = await loop.observe();
      expect((await loop.observe())['viewId'], first['viewId']);
      current = view('home', runtime: 'runtime-2');
      expect((await loop.observe())['viewId'], isNot(first['viewId']));
    },
  );

  test('failed reads invalidate cached actionable state', () async {
    var disconnected = false;
    var dispatched = 0;
    final loop = LiveViewLoop(
      read: () async {
        if (disconnected) throw StateError('disconnected');
        return view('home');
      },
      act: (_, _) async {
        dispatched++;
        return {'ok': true};
      },
    );
    final first = await loop.observe();
    disconnected = true;
    await loop.refreshInBackground();
    final result = await loop.perform({
      'method': 'tap',
      'viewId': first['viewId'],
    });
    expect(dispatched, 0);
    expect(result['ok'], false);
    expect((result['view'] as Map)['ok'], false);
  });

  test(
    'unknown dispatch is retained and never automatically retried',
    () async {
      var attempts = 0;
      final loop = LiveViewLoop(
        read: () async => view('home'),
        act: (_, _) async {
          attempts++;
          throw TimeoutException('lost acknowledgement');
        },
      );
      final first = await loop.observe();
      final result = await loop.perform({
        'method': 'tap',
        'viewId': first['viewId'],
      });
      expect(attempts, 1);
      expect(result['ok'], false);
      expect((result['action'] as Map)['dispatch'], 'dispatch_outcome_unknown');
      expect((result['view'] as Map)['screen'], 'home');
    },
  );

  test('background reads cannot overlap an action', () async {
    final gate = Completer<void>();
    var reads = 0;
    final loop = LiveViewLoop(
      read: () async {
        reads++;
        return view('home');
      },
      act: (_, _) async {
        await gate.future;
        return {'ok': true};
      },
    );
    final first = await loop.observe();
    final action = loop.perform({'method': 'tap', 'viewId': first['viewId']});
    await Future<void>.delayed(Duration.zero);
    await loop.refreshInBackground();
    expect(reads, 1);
    gate.complete();
    await action;
    expect(reads, 2);
  });
}
