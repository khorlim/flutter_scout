import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'live rendering guard rejects a suspended mutation at the helper boundary',
    (tester) async {
      final runtime = FlutterScoutRuntime();
      await tester.pumpWidget(const MaterialApp(home: Text('Quiet')));
      final generation = runtime.debugSnapshot().stateGeneration;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      var dispatched = false;
      final response = (await tester.runAsync(
        () => runtime.debugProtocolMutation(
          {
            'schemaVersion': '1',
            'clientProtocolMin': '15',
            'clientProtocolMax': '15',
            'commandId': 'render-guard',
            'idempotencyKey': 'render-guard',
            'runId': 'run',
            'runtimeInstanceId': runtime.debugRuntimeInstanceId,
            'expectedStateGeneration': '$generation',
            'deadlineEpochMs':
                '${DateTime.now().add(const Duration(seconds: 5)).millisecondsSinceEpoch}',
            'requireLiveRendering': 'true',
          },
          () {
            dispatched = true;
            return runtime.debugTapTarget('missing');
          },
        ),
      ))!;
      expect(response['ok'], false);
      expect(
        (response['structuredError'] as Map)['code'],
        'agent_live_view_unavailable',
      );
      expect(dispatched, false);
    },
  );

  testWidgets('rendering suspension is distinct from a quiet live screen', (
    tester,
  ) async {
    FlutterScoutHelper.ensureRegistered();
    final runtime = FlutterScoutHelper.debugRuntime;
    await tester.pumpWidget(const MaterialApp(home: Text('Quiet')));
    await tester.pump();
    final active = (await tester.runAsync(runtime.debugInspect))!;
    expect((active['rendering'] as Map)['status'], 'active');
    expect(
      (active['rendering'] as Map)['completedFrameworkFrames'],
      greaterThan(0),
    );
    final advanced = runtime.debugManualMutationFrameAdvanceCount;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final suspended = (await tester.runAsync(runtime.debugInspect))!;
    final state = suspended['rendering'] as Map;
    expect(state['status'], 'suspended');
    expect(state['framesEnabled'], false);
    expect(state['pixelFreshness'], 'not_observed');
    expect(state['scoutSchedulesFrames'], false);
    expect(suspended['snapshotId'], active['snapshotId']);
    expect(runtime.debugManualMutationFrameAdvanceCount, advanced);
  });
}
