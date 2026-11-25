import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// The session label is the chip people watch to see which agent session is
/// running and what it is doing. It must not blink: captures keep it mounted
/// and hide it only where a capture that excludes Scout's overlay covers it,
/// and its state word does not flip between an agent's turns.
void main() {
  final badge = find.byWidgetPredicate(
    (widget) => widget.runtimeType.toString() == '_ScoutInstanceBadge',
  );
  double labelOpacity(WidgetTester tester) => tester
      .widget<Opacity>(
        find.descendant(of: badge, matching: find.byType(Opacity)).first,
      )
      .opacity;

  Future<FlutterScoutRuntime> labelled(WidgetTester tester) async {
    FlutterScoutHelper.ensureRegistered();
    final runtime = FlutterScoutHelper.debugRuntime;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: GestureDetector(onTap: () {}, child: const Text('Save')),
          ),
        ),
      ),
    );
    runtime.debugSetLaunchBadgeVisible(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(badge, findsOneWidget);
    return runtime;
  }

  /// Runs one in-app capture and returns the lowest label opacity seen on
  /// the frames it drives, checking the label stays mounted throughout.
  Future<double> opacityDuring(
    WidgetTester tester,
    Future<Object?> Function() capture,
  ) async {
    final element = tester.element(badge);
    final pending = capture();
    var lowest = labelOpacity(tester);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.element(badge), same(element), reason: 'remounted');
      final opacity = labelOpacity(tester);
      if (opacity < lowest) lowest = opacity;
    }
    await tester.runAsync(() => pending);
    await tester.pump();
    expect(tester.element(badge), same(element), reason: 'remounted');
    expect(labelOpacity(tester), 1);
    return lowest;
  }

  testWidgets('captures keep the label unless they exclude it where it sits', (
    tester,
  ) async {
    final runtime = await labelled(tester);

    // A capture that includes Scout's overlay shows the label as it is.
    expect(
      await opacityDuring(
        tester,
        () => runtime.debugCaptureRegion(includeDrivingOverlay: true),
      ),
      1,
    );
    // A crop away from the bottom-left corner leaves it alone.
    expect(
      await opacityDuring(
        tester,
        () => runtime.debugCaptureRegion(
          rect: const Rect.fromLTWH(600, 20, 120, 80),
          padding: 0,
        ),
      ),
      1,
    );
    // An app-only screenshot that covers it hides it for those frames only.
    expect(await opacityDuring(tester, () => runtime.debugCaptureRegion()), 0);

    runtime.debugSetLaunchBadgeVisible(null);
    await tester.pump();
  });

  testWidgets('the label keeps controlling between turns at a fixed size', (
    tester,
  ) async {
    final runtime = await labelled(tester);
    // Real 16 ms frames, renewing the presence lease every 2 s as the agent's
    // eyes do.
    Future<void> wait(int ms) async {
      for (var elapsed = 0; elapsed < ms; elapsed += 16) {
        if (elapsed % 2000 == 0) await runtime.debugAgentOverlay('attach');
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    String label() => runtime.debugDrivingOverlayStatus['label']! as String;

    await wait(1000);
    expect(label(), 'observing');
    final size = tester.getSize(badge);

    await tester.runAsync(() => runtime.debugTapTarget('tap.save'));
    await wait(5000);
    // The glow and cursor calm down after a moment; the label waits longer
    // than a model's turn before it says observing.
    final status = runtime.debugDrivingOverlayStatus;
    expect(status['controlling'], isFalse);
    expect(status['label'], 'controlling');
    expect(tester.getSize(badge), size);

    // The next input inside that window starts the wait again.
    await wait(5000);
    await tester.runAsync(() => runtime.debugTapTarget('tap.save'));
    await wait(14000);
    expect(label(), 'controlling');

    await wait(4000);
    expect(label(), 'observing');
    await wait(500);
    expect(tester.getSize(badge), size);

    await runtime.debugAgentOverlay('detach');
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(runtime.debugDrivingOverlayStatus['installed'], isFalse);
    runtime.debugSetLaunchBadgeVisible(null);
    await tester.pump();
  });
}
