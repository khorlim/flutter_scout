import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

class _Counter extends StatefulWidget {
  const _Counter({super.key});

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;

  void increment() => setState(() => count += 1);

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text('Count $count'),
      ElevatedButton(onPressed: increment, child: const Text('Increment')),
    ],
  );
}

Map<String, String> _mutation(
  FlutterScoutRuntime runtime,
  int generation, {
  required String key,
  String? headlessDrive,
}) => {
  'schemaVersion': '1',
  'clientProtocolMin': '15',
  'clientProtocolMax': '15',
  'commandId': key,
  'idempotencyKey': key,
  'runId': 'run',
  'runtimeInstanceId': runtime.debugRuntimeInstanceId,
  'expectedStateGeneration': '$generation',
  'deadlineEpochMs':
      '${DateTime.now().add(const Duration(seconds: 5)).millisecondsSinceEpoch}',
  'requireLiveRendering': 'true',
  'headlessDrive': ?headlessDrive,
};

void main() {
  late FlutterScoutRuntime runtime;
  final counter = GlobalKey<_CounterState>();

  Future<void> pumpHidden(WidgetTester tester, Widget home) async {
    FlutterScoutHelper.ensureRegistered();
    runtime = FlutterScoutHelper.debugRuntime;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: home)));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }

  // Ends the drive inside the test body: the test framework rebuilds the
  // root before tear-downs run, and a live lease would schedule a frame.
  void finish(WidgetTester tester) {
    runtime.debugExpireHeadlessDrive();
    runtime.debugMacosHostFacts = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  int loopFrames() => runtime.debugHeadlessDrive['loopFrames']! as int;

  Future<Map<String, Object?>> inspect(
    WidgetTester tester, {
    bool headless = false,
  }) async => (await tester.runAsync(
    () => runtime.debugProtocolInspect({
      'brief': 'true',
      if (headless) 'headlessDrive': 'true',
    }),
  ))!;

  testWidgets('flag off: a hidden app stays suspended and refuses input', (
    tester,
  ) async {
    await pumpHidden(tester, _Counter(key: counter));
    await tester.runAsync(() async => counter.currentState!.increment());

    final view = await inspect(tester);
    final rendering = view['rendering'] as Map;
    expect(rendering['status'], 'suspended');
    expect(rendering['scoutSchedulesFrames'], false);
    expect(rendering.containsKey('headlessDrive'), false);
    // Nothing advanced the deferred build.
    expect(view['visibleText'], contains('Count 0'));
    expect(runtime.debugHeadlessDrive['leaseActive'], false);

    for (final headless in [null, 'false']) {
      var dispatched = false;
      final response = (await tester.runAsync(
        () => runtime.debugProtocolMutation(
          _mutation(
            runtime,
            runtime.debugSnapshot().stateGeneration,
            key: 'off-$headless',
            headlessDrive: headless,
          ),
          () {
            dispatched = true;
            return runtime.debugTapTarget('btn.increment');
          },
        ),
      ))!;
      expect(response['ok'], false);
      expect(
        (response['structuredError'] as Map)['code'],
        'agent_live_view_unavailable',
      );
      expect(dispatched, false);
    }
    finish(tester);
  });

  testWidgets('flag on: a hidden app is driven, current and accepts input', (
    tester,
  ) async {
    await pumpHidden(tester, _Counter(key: counter));
    await tester.runAsync(() async => counter.currentState!.increment());

    final view = await inspect(tester, headless: true);
    final rendering = view['rendering'] as Map;
    expect(rendering['status'], 'driven');
    expect(rendering['framesEnabled'], false);
    expect(rendering['lifecycle'], 'hidden');
    expect(rendering['scoutSchedulesFrames'], true);
    final drive = rendering['headlessDrive'] as Map;
    expect(drive['driving'], true);
    expect(drive['reason'], 'app_hidden');
    expect(drive['lifecycleFaked'], false);
    expect(drive['notice'], startsWith('HEADLESS: the app is not visible'));
    // The deferred setState was built before the observation.
    expect(view['visibleText'], contains('Count 1'));
    expect((view['observationEffects'] as Map)['scoutSchedulesFrames'], true);

    var dispatched = false;
    final response = (await tester.runAsync(
      () => runtime.debugProtocolMutation(
        _mutation(
          runtime,
          runtime.debugSnapshot().stateGeneration,
          key: 'on',
          headlessDrive: 'true',
        ),
        () {
          dispatched = true;
          return runtime.debugTapTarget('btn.increment');
        },
      ),
    ))!;
    expect(dispatched, true, reason: '$response');
    expect(response['ok'], true, reason: '$response');
    final after = await inspect(tester, headless: true);
    expect(after['visibleText'], contains('Count 2'));
    finish(tester);
  });

  testWidgets('display sleep and an in-force lock are told apart', (
    tester,
  ) async {
    await pumpHidden(tester, _Counter(key: counter));
    Future<Map> rendering() async =>
        (await inspect(tester, headless: true))['rendering'] as Map;

    // macOS sets the lock flag the moment the display sleeps, also inside
    // the password grace period: that is display sleep, lock unknown.
    runtime.debugMacosHostFacts = const ScoutMacosHostFacts(
      displayAsleep: true,
      sessionLockFlag: true,
      loginWindowFrontmost: true,
    );
    var view = await rendering();
    expect((view['headlessDrive'] as Map)['reason'], 'display_asleep');
    expect(
      (view['headlessDrive'] as Map)['notice'],
      startsWith('HEADLESS: macOS reports the display is asleep'),
    );
    var host = view['host'] as Map;
    expect(host['displayAsleep'], true);
    expect(host['screenLocked'], null);
    expect(host['screenLockNote'], isA<String>());

    // Display awake with the login window in front: the lock is in force.
    runtime.debugMacosHostFacts = const ScoutMacosHostFacts(
      displayAsleep: false,
      sessionLockFlag: true,
      loginWindowFrontmost: true,
    );
    view = await rendering();
    expect((view['headlessDrive'] as Map)['reason'], 'screen_locked');
    host = view['host'] as Map;
    expect(host['screenLocked'], true);
    expect(host['hiddenReason'], 'screen_locked');

    // Nothing from macOS hides it: the lifecycle names the reason.
    runtime.debugMacosHostFacts = const ScoutMacosHostFacts(
      displayAsleep: false,
      sessionLockFlag: false,
      loginWindowFrontmost: false,
      windowVisible: true,
    );
    view = await rendering();
    expect((view['headlessDrive'] as Map)['reason'], 'app_hidden');
    expect((view['host'] as Map)['screenLocked'], false);
    finish(tester);
  });

  testWidgets('a window macOS hides is not active though Flutter renders', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    runtime = FlutterScoutHelper.debugRuntime;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _Counter(key: counter)),
      ),
    );
    // Lifecycle stays resumed (frames enabled), as on 3 of 4 display sleeps
    // and for an app launched behind the lock screen.
    runtime.debugMacosHostFacts = const ScoutMacosHostFacts(
      displayAsleep: true,
      sessionLockFlag: true,
    );

    // Headless drive off: suspended, the cause named, input refused.
    var view = await inspect(tester);
    var rendering = view['rendering'] as Map;
    expect(rendering['framesEnabled'], true);
    expect(rendering['status'], 'suspended');
    expect(rendering['notVisibleBecause'], contains('display is asleep'));
    expect((rendering['host'] as Map)['hidden'], true);
    var dispatched = false;
    final refused = (await tester.runAsync(
      () => runtime.debugProtocolMutation(
        _mutation(
          runtime,
          runtime.debugSnapshot().stateGeneration,
          key: 'asleep-off',
        ),
        () {
          dispatched = true;
          return runtime.debugTapTarget('btn.increment');
        },
      ),
    ))!;
    expect(dispatched, false);
    expect(
      (refused['structuredError'] as Map)['code'],
      'agent_live_view_unavailable',
    );

    // A capture of that app says it may be stale.
    final shot = (await tester.runAsync(runtime.debugCaptureScreen))!;
    final freshness = shot['freshness'] as Map;
    expect(freshness['renderingStatus'], 'suspended');
    expect(freshness['capturedWhileSuspended'], true);
    expect(freshness['lastFrameAgeMs'], isA<int>());

    // Headless drive on: vsync stopped with the display, so Scout drives
    // the frame a setState is waiting for.
    await tester.runAsync(() async => counter.currentState!.increment());
    view = await inspect(tester, headless: true);
    rendering = view['rendering'] as Map;
    expect(rendering['status'], 'driven');
    expect((rendering['headlessDrive'] as Map)['reason'], 'display_asleep');
    expect(view['visibleText'], contains('Count 1'));

    // The display wakes: rendering is active again, and the loop says why
    // it stopped even though it was idle.
    runtime.debugMacosHostFacts = const ScoutMacosHostFacts(
      displayAsleep: false,
      sessionLockFlag: false,
      loginWindowFrontmost: false,
      windowVisible: true,
    );
    rendering = (await inspect(tester, headless: true))['rendering'] as Map;
    expect(rendering['status'], 'active');
    expect(runtime.debugHeadlessDrive['loop'], 'stopped');
    expect(runtime.debugHeadlessDrive['stoppedReason'], 'rendering_resumed');
    final visible = (await tester.runAsync(runtime.debugCaptureScreen))!;
    expect((visible['freshness'] as Map)['capturedWhileSuspended'], false);
    finish(tester);
  });

  testWidgets('the loop runs only while something needs a frame', (
    tester,
  ) async {
    await pumpHidden(tester, _Counter(key: counter));
    await inspect(tester, headless: true);
    // Nothing pending: no timer, no frames.
    expect(runtime.debugHeadlessDrive['loop'], 'idle');
    expect(runtime.debugHeadlessDrive['frameScheduled'], false);

    // A setState while hidden schedules exactly the frames it needs.
    final before = loopFrames();
    await tester.runAsync(() async {
      counter.currentState!.increment();
      expect(runtime.debugHeadlessDrive['loop'], 'running');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(loopFrames() - before, 1);
    expect(runtime.debugHeadlessDrive['loop'], 'idle');
    expect(find.text('Count 1'), findsOneWidget);
    finish(tester);
  });

  testWidgets('the loop drives animations and stops on disconnect and resume', (
    tester,
  ) async {
    await pumpHidden(tester, const CircularProgressIndicator());
    final before = loopFrames();
    await inspect(tester, headless: true);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    expect(runtime.debugHeadlessDrive['loop'], 'running');
    // Bounded: at most 20 frames per second, never a constant 60 fps.
    expect(loopFrames() - before, inInclusiveRange(2, 9));

    // No request renews the lease: the agent disconnected.
    runtime.debugExpireHeadlessDrive();
    final stopped = runtime.debugHeadlessDrive;
    expect(stopped['loop'], 'stopped');
    expect(stopped['stoppedReason'], 'lease_expired');
    expect(stopped['frameScheduled'], false);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    expect(loopFrames(), stopped['loopFrames']);

    // Re-attach, then the app becomes visible: Flutter renders on its own.
    await inspect(tester, headless: true);
    expect(runtime.debugHeadlessDrive['loop'], 'running');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    expect(runtime.debugHeadlessDrive['loop'], 'stopped');
    expect(runtime.debugHeadlessDrive['stoppedReason'], 'rendering_resumed');
    final active = (await inspect(tester, headless: true))['rendering'] as Map;
    expect(active['status'], 'active');
    expect((active['headlessDrive'] as Map)['driving'], false);
    finish(tester);
  });

  testWidgets('the driving overlay keeps working and drives no frames itself', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    runtime = FlutterScoutHelper.debugRuntime;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _Counter(key: counter)),
      ),
    );
    await runtime.debugAgentOverlay('attach');
    await tester.pump();
    await tester.pump();
    expect(runtime.debugOverlayTracksAppWork, true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);

    await inspect(tester, headless: true);
    // Headless drive left the overlay's build hook in place.
    expect(runtime.debugOverlayTracksAppWork, true);
    // The overlay's own ticker is not app work: the loop stays idle.
    expect(runtime.debugAppTransientCallbackCount, 0);
    expect(runtime.debugHeadlessDrive['loop'], 'idle');

    // An app build still reaches the loop through the overlay's hook.
    final before = loopFrames();
    await tester.runAsync(() async {
      counter.currentState!.increment();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(loopFrames() - before, greaterThanOrEqualTo(1));
    expect(runtime.debugHeadlessDrive['loop'], 'idle');
    expect(find.text('Count 1'), findsOneWidget);

    finish(tester);
    await runtime.debugAgentOverlay('detach');
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  });
}
