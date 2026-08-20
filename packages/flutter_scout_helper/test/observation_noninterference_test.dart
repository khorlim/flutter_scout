import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'read commands preserve app state and never advance disabled frames',
    (tester) async {
      FlutterScoutHelper.ensureRegistered();
      final runtime = FlutterScoutHelper.debugRuntime;
      final probeKey = GlobalKey<_NonInterferenceProbeState>();
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          routes: <String, WidgetBuilder>{
            '/': (_) => _NonInterferenceProbe(key: probeKey),
            '/other': (_) => const Scaffold(body: Text('Other route')),
          },
        ),
      );
      await tester.pump();
      final probe = probeKey.currentState!;
      probe.focusNode.requestFocus();
      await tester.pump();
      final semantics = tester.ensureSemantics();

      expect(runtime.debugOverlayInstalled, isFalse);
      expect(find.text('SCOUT'), findsNothing);
      expect(find.bySemanticsLabel('business increment'), findsOneWidget);
      expect(find.bySemanticsLabel('bottom left app action'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
      expect(tester.binding.framesEnabled, isFalse);
      probe.armPendingTicker();
      expect(tester.binding.transientCallbackCount, greaterThan(0));

      final focusBefore = FocusManager.instance.primaryFocus;
      final routeBefore = ModalRoute.of(probe.context);
      final businessBefore = probe.businessCount;
      final pointersBefore = probe.pointerDownCount;
      final tickerTicksBefore = probe.tickerTicks;
      final tickerValueBefore = probe.tickerValue;
      final manualFramesBefore = runtime.debugManualMutationFrameAdvanceCount;

      final firstInspect = await tester.runAsync(runtime.debugInspect);
      expect(firstInspect, isNotNull);
      final snapshotId = firstInspect!['snapshotId']! as String;
      final responses = <Map<String, Object?>>[
        firstInspect,
        (await tester.runAsync(runtime.debugWhere))!,
        (await tester.runAsync(
          () => runtime.debugLocate(const {'target': 'btn.increment'}),
        ))!,
        (await tester.runAsync(() => runtime.debugInspectSince(snapshotId)))!,
        (await tester.runAsync(() => runtime.debugWaitStable(timeoutMs: 280)))!,
        (await tester.runAsync(
          () => runtime.debugWaitFor(const {
            'text': 'Business 0',
            'timeoutMs': '100',
            'pollMs': '16',
          }),
        ))!,
        (await tester.runAsync(runtime.debugDragStatus))!,
        (await tester.runAsync(runtime.debugAnnotationsRead))!,
        (await tester.runAsync(
          () => runtime.debugAnnotationsRead(action: 'targets'),
        ))!,
        (await tester.runAsync(runtime.debugRecordRead))!,
        (await tester.runAsync(
          () => runtime.debugRecordRead(action: 'steps'),
        ))!,
        // Repeat the stateful observation surfaces. This catches accidental
        // first-call setup (frame scheduling, focus requests, or overlay
        // installation) as well as per-poll interference.
        (await tester.runAsync(runtime.debugInspect))!,
        (await tester.runAsync(runtime.debugWhere))!,
        (await tester.runAsync(
          () => runtime.debugLocate(const {'target': 'btn.increment'}),
        ))!,
        (await tester.runAsync(() => runtime.debugInspectSince(snapshotId)))!,
        (await tester.runAsync(() => runtime.debugWaitStable(timeoutMs: 160)))!,
        (await tester.runAsync(
          () => runtime.debugWaitFor(const {
            'target': 'btn.increment',
            'timeoutMs': '100',
            'pollMs': '16',
          }),
        ))!,
      ];

      for (final response in responses) {
        expect(response['ok'], isTrue, reason: '$response');
        final effects = response['observationEffects']! as Map<String, Object?>;
        expect(effects['mode'], 'read_only_observation');
        expect(effects['scoutSchedulesFrames'], isFalse);
        expect(effects['scoutMayAdvanceDisabledFrames'], isFalse);
        expect(effects['phasePointerDispatch'], isFalse);
        expect(effects['phaseFocusRequest'], isFalse);
        expect(effects['phaseRouteMutation'], isFalse);
        expect(effects['phaseOverlayInstallation'], isFalse);
      }

      expect(FocusManager.instance.primaryFocus, same(focusBefore));
      expect(probe.focusNode.hasFocus, isTrue);
      expect(ModalRoute.of(probe.context), same(routeBefore));
      expect(navigatorKey.currentState!.canPop(), isFalse);
      expect(probe.businessCount, businessBefore);
      expect(probe.pointerDownCount, pointersBefore);
      expect(probe.tickerTicks, tickerTicksBefore);
      expect(probe.tickerValue, tickerValueBefore);
      expect(runtime.debugManualMutationFrameAdvanceCount, manualFramesBefore);
      expect(runtime.debugOverlayInstalled, isFalse);
      expect(find.text('SCOUT'), findsNothing);
      expect(find.bySemanticsLabel('business increment'), findsOneWidget);
      expect(find.bySemanticsLabel('bottom left app action'), findsOneWidget);

      // A real app control in Scout's former bottom-left interception area is
      // still reachable because observation never installed overlay chrome.
      await tester.tap(find.bySemanticsLabel('bottom left app action'));
      expect(probe.bottomLeftTaps, 1);
      semantics.dispose();
    },
  );

  testWidgets(
    'explicit UI opt-in is removable and mutation settling may advance frames',
    (tester) async {
      FlutterScoutHelper.ensureRegistered();
      final runtime = FlutterScoutHelper.debugRuntime;
      final probeKey = GlobalKey<_NonInterferenceProbeState>();
      await tester.pumpWidget(
        MaterialApp(home: _NonInterferenceProbe(key: probeKey)),
      );
      await tester.pump();
      final probe = probeKey.currentState!;

      expect(runtime.debugOverlayInstalled, isFalse);
      runtime.debugSetAnnotationMode(true);
      await tester.pump();
      await tester.pump();
      expect(runtime.debugOverlayInstalled, isTrue);
      runtime.debugSetAnnotationMode(false);
      await tester.pump();
      expect(runtime.debugOverlayInstalled, isFalse);
      expect(find.text('SCOUT'), findsNothing);

      runtime.debugStartRecording(name: 'non-interference-proof');
      await tester.pump();
      await tester.pump();
      expect(runtime.debugOverlayInstalled, isTrue);
      await runtime.debugStopRecording(discard: true);
      await tester.pump();
      expect(runtime.debugOverlayInstalled, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
      probe.armPendingTicker();
      final manualFramesBefore = runtime.debugManualMutationFrameAdvanceCount;
      final tickerBefore = probe.tickerValue;

      final result = await tester.runAsync(
        () => runtime.debugTapTarget('btn.increment'),
      );
      expect(result, isNotNull);
      expect(result!['ok'], isTrue, reason: '$result');
      final effects = result['observationEffects']! as Map<String, Object?>;
      expect(effects['mode'], 'post_mutation_settling');
      expect(effects['scoutMayAdvanceDisabledFrames'], isTrue);
      expect(probe.businessCount, 1);
      expect(probe.pointerDownCount, greaterThan(0));
      expect(probe.tickerValue, greaterThan(tickerBefore));
      expect(probe.tickerTicks, greaterThan(0));
      expect(
        runtime.debugManualMutationFrameAdvanceCount,
        greaterThan(manualFramesBefore),
      );
    },
  );
}

class _NonInterferenceProbe extends StatefulWidget {
  const _NonInterferenceProbe({super.key});

  @override
  State<_NonInterferenceProbe> createState() => _NonInterferenceProbeState();
}

class _NonInterferenceProbeState extends State<_NonInterferenceProbe>
    with SingleTickerProviderStateMixin {
  final FocusNode focusNode = FocusNode(debugLabel: 'probe-field');
  late final AnimationController _ticker = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  )..addListener(() => tickerTicks += 1);

  int businessCount = 0;
  int pointerDownCount = 0;
  int bottomLeftTaps = 0;
  int tickerTicks = 0;

  double get tickerValue => _ticker.value;

  void armPendingTicker() {
    _ticker.forward(from: 0);
  }

  @override
  void dispose() {
    focusNode.dispose();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => pointerDownCount += 1,
        child: Stack(
          children: <Widget>[
            Positioned(
              left: 24,
              right: 24,
              top: 24,
              child: TextField(
                key: const ValueKey<String>('field.probe'),
                focusNode: focusNode,
                decoration: const InputDecoration(labelText: 'Probe field'),
              ),
            ),
            Center(
              child: Semantics(
                label: 'business increment',
                button: true,
                child: ElevatedButton(
                  key: const ValueKey<String>('btn.increment'),
                  onPressed: () => setState(() => businessCount += 1),
                  child: Text('Business $businessCount'),
                ),
              ),
            ),
            Positioned(
              left: 0,
              bottom: 0,
              width: 150,
              height: 64,
              child: Semantics(
                label: 'bottom left app action',
                button: true,
                child: ElevatedButton(
                  key: const ValueKey<String>('btn.bottom_left'),
                  onPressed: () => bottomLeftTaps += 1,
                  child: const Text('App action'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
