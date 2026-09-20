import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pin_code_fields/pin_code_fields.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('guarded activation inputs into the actual unwrapped control', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await _pumpFixture(tester, fixture);
    final runtime = FlutterScoutHelper.debugRuntime;
    final representedInnerIgnorePointer = tester.renderObject(
      find
          .descendant(
            of: find.byType(PinCodeTextField),
            matching: find.byType(IgnorePointer),
          )
          .first,
    );
    runtime.debugRepresentedRenderObjectOverride = (element) =>
        element.widget is GestureDetector
        ? representedInnerIgnorePointer
        : null;
    addTearDown(() => runtime.debugRepresentedRenderObjectOverride = null);
    final targets = _pinTargets();

    final observedActivation = runtime
        .debugSnapshot()
        .interactables
        .firstWhere((node) => node.id == targets.activation)
        .toJson();
    expect(
      observedActivation['pointerReceiver'],
      containsPair('relationship', 'gesture_owner_pointer_listener_v1'),
    );

    final result = await _guardedInputWithEngineFrame(
      tester,
      field: targets.field,
      value: '246810',
      activation: targets.activation,
    );

    expect(
      result['ok'],
      isTrue,
      reason:
          '${result['reason']} ${(result['guardedActivation'] as Map?)?['postActivationFrame']}',
    );
    expect(fixture.pinController.text, '246810');
    expect(result['guardedActivation'], isA<Map<String, Object?>>());
    final activationResolution =
        (result['guardedActivation'] as Map)['activation'] as Map;
    final immediateHitTest = activationResolution['immediateHitTest'] as Map;
    expect(immediateHitTest['containsTarget'], isFalse);
    expect(immediateHitTest['containsReceiver'], isTrue);
    expect(immediateHitTest['relationshipMatched'], isTrue);
    expect(result.toString(), isNot(contains('246810')));
  });

  testWidgets('missing post-activation frame fails closed at the deadline', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await _pumpFixture(tester, fixture);
    final targets = _pinTargets();

    // Do not pump the widget-test engine while the request is pending.
    final result = (await tester.runAsync(
      () => FlutterScoutHelper.debugRuntime.debugInputTarget(
        targets.field,
        '654321',
        activationTarget: targets.activation,
      ),
    ))!;

    expect(result['ok'], isFalse, reason: '$result');
    expect(result['reason'], 'post_activation_frame_unavailable');
    expect(_textDispatch(result), 'not_dispatched');
    expect(fixture.pinController.text, isEmpty);
  });

  testWidgets('blocking overlay rejects activation before pointer dispatch', (
    tester,
  ) async {
    final fixture = _Fixture(overlay: true);
    addTearDown(fixture.dispose);
    await _pumpFixture(tester, fixture);
    final snapshot = FlutterScoutHelper.debugRuntime.debugSnapshot();
    final field = snapshot.fields.single.id;
    final activation = snapshot.interactables
        .firstWhere((node) => node.widgetType == 'GestureDetector')
        .id;

    final result = (await tester.runAsync(
      () => FlutterScoutHelper.debugRuntime.debugInputTarget(
        field,
        '135790',
        activationTarget: activation,
      ),
    ))!;

    expect(result['ok'], isFalse);
    expect(_activationStatus(result), 'occluded');
    expect(_textDispatch(result), 'not_dispatched');
    expect(fixture.overlayTapCount, 0);
    expect(fixture.pinController.text, isEmpty);
  });

  testWidgets('wrong focused field rejects text after guarded activation', (
    tester,
  ) async {
    final fixture = _Fixture(includeOtherField: true);
    addTearDown(fixture.dispose);
    await _pumpFixture(tester, fixture);
    final snapshot = FlutterScoutHelper.debugRuntime.debugSnapshot();
    final pin = snapshot.fields.firstWhere(
      (node) => node.widgetType == 'TextFormField',
    );
    final other = snapshot.fields.firstWhere(
      (node) => node.widgetType == 'TextField',
    );

    final result = await _guardedInputWithEngineFrame(
      tester,
      field: pin.id,
      value: '112233',
      activation: other.id,
    );

    expect(result['ok'], isFalse);
    expect(result['reason'], 'activation_focused_different_field');
    expect(_textDispatch(result), 'not_dispatched');
    expect(fixture.pinController.text, isEmpty);
    expect(fixture.otherController.text, isEmpty);
  });

  testWidgets('focus theft queued by activation rejects text dispatch', (
    tester,
  ) async {
    final fixture = _Fixture(includeOtherField: true, stealFocusAfterTap: true);
    addTearDown(fixture.dispose);
    await _pumpFixture(tester, fixture);
    final targets = _pinTargets();

    final result = await _guardedInputWithEngineFrame(
      tester,
      field: targets.field,
      value: '123456',
      activation: targets.activation,
    );

    expect(result['ok'], isFalse, reason: '$result');
    expect(_textDispatch(result), 'not_dispatched');
    expect(fixture.pinController.text, isEmpty);
    expect(fixture.otherController.text, isEmpty);
  });

  testWidgets('post-tap blocking overlay rejects text dispatch', (
    tester,
  ) async {
    final fixture = _Fixture(insertOverlayAfterTap: true);
    addTearDown(fixture.dispose);
    await _pumpFixture(tester, fixture);
    final targets = _pinTargets();

    final result = await _guardedInputWithEngineFrame(
      tester,
      field: targets.field,
      value: '234567',
      activation: targets.activation,
    );
    await tester.pump();

    expect(fixture.overlayRequested, isTrue);
    expect(find.byKey(const ValueKey('post-tap-overlay')), findsOneWidget);
    expect(result['ok'], isFalse, reason: '$result');
    expect(_activationStatus(result), 'occluded');
    expect(_textDispatch(result), 'not_dispatched');
    expect(fixture.pinController.text, isEmpty);
  });

  testWidgets(
    'post-tap activation callback replacement rejects text dispatch',
    (tester) async {
      final fixture = _Fixture(replaceCallbackAfterTap: true);
      addTearDown(fixture.dispose);
      await _pumpFixture(tester, fixture);
      final targets = _pinTargets();

      final result = await _guardedInputWithEngineFrame(
        tester,
        field: targets.field,
        value: '456789',
        activation: targets.activation,
      );
      await tester.pump();

      expect(fixture.callbackReplaced, isTrue);
      expect(result['ok'], isFalse, reason: '$result');
      expect(result['reason'], 'final_revalidation_failed');
      expect(
        ((result['guardedActivation'] as Map)['revalidation']
            as Map)['activationConfigurationUnchanged'],
        isFalse,
      );
      expect(_textDispatch(result), 'not_dispatched');
      expect(fixture.pinController.text, isEmpty);
    },
  );

  testWidgets('stale replacement rejects before pointer and text dispatch', (
    tester,
  ) async {
    final first = _Fixture(keySeed: 1);
    final replacement = _Fixture(keySeed: 2);
    addTearDown(first.dispose);
    addTearDown(replacement.dispose);
    await _pumpFixture(tester, first);
    final targets = _pinTargets();
    final runtime = FlutterScoutHelper.debugRuntime;
    runtime.debugBeforeGuardedInputActivationRevalidation = () async {
      await tester.pumpWidget(replacement.app());
      await tester.pump();
    };
    addTearDown(() {
      runtime.debugBeforeGuardedInputActivationRevalidation = null;
    });

    final result = await runtime.debugInputTarget(
      targets.field,
      '555666',
      activationTarget: targets.activation,
    );

    expect(result['ok'], isFalse);
    expect([
      result['reason'],
      _activationStatus(result),
    ], anyElement(contains('stale')));
    expect(_activationDispatch(result), 'not_dispatched');
    expect(_textDispatch(result), 'not_dispatched');
    expect(first.pinController.text, isEmpty);
    expect(replacement.pinController.text, isEmpty);
  });

  testWidgets('same-identity receiver substitution fails closed', (
    tester,
  ) async {
    final first = _Fixture();
    final replacement = _Fixture(appKeySeed: 1);
    addTearDown(first.dispose);
    addTearDown(replacement.dispose);
    await _pumpFixture(tester, first);
    final targets = _pinTargets();
    final runtime = FlutterScoutHelper.debugRuntime;
    runtime.debugBeforeGuardedInputActivationRevalidation = () async {
      await tester.pumpWidget(replacement.app());
      await tester.pump();
    };
    addTearDown(() {
      runtime.debugBeforeGuardedInputActivationRevalidation = null;
    });

    final result = await runtime.debugInputTarget(
      targets.field,
      '111333',
      activationTarget: targets.activation,
    );

    expect(result['ok'], isFalse, reason: '$result');
    expect(_activationDispatch(result), 'not_dispatched');
    expect(_textDispatch(result), 'not_dispatched');
    expect(first.pinController.text, isEmpty);
    expect(replacement.pinController.text, isEmpty);
  });

  testWidgets('geometry change before dispatch fails closed', (tester) async {
    final first = _Fixture();
    final moved = _Fixture(horizontalInset: 24, appKeySeed: 1);
    addTearDown(first.dispose);
    addTearDown(moved.dispose);
    await _pumpFixture(tester, first);
    final targets = _pinTargets();
    final runtime = FlutterScoutHelper.debugRuntime;
    runtime.debugBeforeGuardedInputActivationRevalidation = () async {
      await tester.pumpWidget(moved.app());
      await tester.pump();
    };
    addTearDown(() {
      runtime.debugBeforeGuardedInputActivationRevalidation = null;
    });

    final result = await runtime.debugInputTarget(
      targets.field,
      '222444',
      activationTarget: targets.activation,
    );

    expect(result['ok'], isFalse, reason: '$result');
    expect(_activationDispatch(result), 'not_dispatched');
    expect(_textDispatch(result), 'not_dispatched');
    expect(first.pinController.text, isEmpty);
    expect(moved.pinController.text, isEmpty);
  });

  testWidgets('same-geometry sibling overlay is not a receiver', (
    tester,
  ) async {
    final fixture = _Fixture(sameGeometrySiblingOverlay: true);
    addTearDown(fixture.dispose);
    await _pumpFixture(tester, fixture);
    final snapshot = FlutterScoutHelper.debugRuntime.debugSnapshot();
    final field = snapshot.fields.single.id;
    final activation = snapshot.interactables
        .firstWhere((node) => node.widgetType == 'GestureDetector')
        .id;

    final result = await FlutterScoutHelper.debugRuntime.debugInputTarget(
      field,
      '333555',
      activationTarget: activation,
    );

    expect(result['ok'], isFalse, reason: '$result');
    expect(_activationDispatch(result), 'not_dispatched');
    expect(_textDispatch(result), 'not_dispatched');
    expect(fixture.overlayTapCount, 0);
    expect(fixture.pinController.text, isEmpty);
  });

  testWidgets('disabled and hidden targets reject without dispatch', (
    tester,
  ) async {
    final disabled = _Fixture(enabled: false);
    addTearDown(disabled.dispose);
    await _pumpFixture(tester, disabled);
    var snapshot = FlutterScoutHelper.debugRuntime.debugSnapshot();
    final disabledResult = await FlutterScoutHelper.debugRuntime
        .debugInputTarget(
          snapshot.fields.single.id,
          '111222',
          activationTarget: snapshot.interactables.single.id,
        );
    expect(disabledResult['ok'], isFalse);
    expect(_fieldStatus(disabledResult), 'disabled');
    expect(_activationDispatch(disabledResult), 'not_dispatched');
    expect(disabled.pinController.text, isEmpty);

    final hidden = _Fixture(visible: false);
    addTearDown(hidden.dispose);
    await _pumpFixture(tester, hidden);
    final hiddenResult = await FlutterScoutHelper.debugRuntime.debugInputTarget(
      'field.textformfield',
      '333444',
      activationTarget: 'tap.gesturedetector',
    );
    expect(hiddenResult['ok'], isFalse);
    expect(_activationDispatch(hiddenResult), 'not_dispatched');
    expect(_textDispatch(hiddenResult), 'not_dispatched');
    expect(hidden.pinController.text, isEmpty);
  });

  testWidgets('explicit field-only input remains fail closed', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await _pumpFixture(tester, fixture);
    final field = FlutterScoutHelper.debugRuntime.debugSnapshot().fields.single;

    final result = await FlutterScoutHelper.debugRuntime.debugInputTarget(
      field.id,
      '111111',
    );

    expect(result['ok'], isFalse);
    expect(
      (result['resolution']! as Map)['status'],
      anyOf('occluded', 'notHitTestable'),
    );
    expect(fixture.pinController.text, isEmpty);
  });

  testWidgets('focus-only input behavior remains unchanged behind an overlay', (
    tester,
  ) async {
    final fixture = _Fixture(overlay: true);
    addTearDown(fixture.dispose);
    await _pumpFixture(tester, fixture);
    fixture.pinFocus.requestFocus();
    await tester.pump();

    final result = await FlutterScoutHelper.debugRuntime.debugInputTarget(
      'focused',
      '123456',
    );

    expect(
      result['ok'],
      isTrue,
      reason:
          '${result['reason']} ${(result['guardedActivation'] as Map?)?['postActivationFrame']}',
    );
    expect(fixture.pinController.text, '123456');
    expect(fixture.overlayTapCount, 0);
  });

  testWidgets('guarded input retains keyboard-semantic formatters', (
    tester,
  ) async {
    final fixture = _Fixture(digitsOnly: true);
    addTearDown(fixture.dispose);
    await _pumpFixture(tester, fixture);
    final targets = _pinTargets();

    final result = await _guardedInputWithEngineFrame(
      tester,
      field: targets.field,
      value: 'abc9876543',
      activation: targets.activation,
    );

    expect(
      result['ok'],
      isTrue,
      reason:
          '${result['reason']} ${(result['guardedActivation'] as Map?)?['postActivationFrame']}',
    );
    expect(fixture.pinController.text, '987654');
  });
}

Future<void> _pumpFixture(WidgetTester tester, _Fixture fixture) async {
  FlutterScoutHelper.ensureRegistered();
  await tester.pumpWidget(fixture.app());
  await tester.pump();
}

Future<Map<String, Object?>> _guardedInputWithEngineFrame(
  WidgetTester tester, {
  required String field,
  required String value,
  required String activation,
}) async {
  final runtime = FlutterScoutHelper.debugRuntime;
  final manualAdvancesBefore = runtime.debugManualMutationFrameAdvanceCount;
  late Future<Map<String, Object?>> pending;
  await tester.runAsync(() async {
    pending = runtime.debugInputTarget(
      field,
      value,
      activationTarget: activation,
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
  });
  // Widget tests have no engine vsync. This pump represents the naturally
  // scheduled engine frame; production Scout never pumps or schedules it.
  await tester.pump();
  final result = (await tester.runAsync(() => pending))!;
  expect(runtime.debugManualMutationFrameAdvanceCount, manualAdvancesBefore);
  return result;
}

({String field, String activation}) _pinTargets() {
  final snapshot = FlutterScoutHelper.debugRuntime.debugSnapshot();
  return (
    field: snapshot.fields
        .firstWhere((node) => node.widgetType == 'TextFormField')
        .id,
    activation: snapshot.interactables
        .firstWhere((node) => node.widgetType == 'GestureDetector')
        .id,
  );
}

String? _fieldStatus(Map<String, Object?> result) =>
    ((result['guardedActivation'] as Map?)?['field'] as Map?)?['status']
        ?.toString();

String? _activationStatus(Map<String, Object?> result) =>
    ((result['guardedActivation'] as Map?)?['activation'] as Map?)?['status']
        ?.toString();

String? _activationDispatch(Map<String, Object?> result) =>
    ((result['guardedActivation'] as Map?)?['dispatch'] as Map?)?['activation']
        ?.toString();

String? _textDispatch(Map<String, Object?> result) =>
    ((result['guardedActivation'] as Map?)?['dispatch'] as Map?)?['text']
        ?.toString();

class _Fixture {
  _Fixture({
    this.overlay = false,
    this.includeOtherField = false,
    this.enabled = true,
    this.visible = true,
    this.keySeed = 0,
    this.digitsOnly = false,
    this.stealFocusAfterTap = false,
    this.insertOverlayAfterTap = false,
    this.replaceCallbackAfterTap = false,
    this.sameGeometrySiblingOverlay = false,
    this.horizontalInset = 0,
    this.appKeySeed = 0,
  });

  final bool overlay;
  final bool includeOtherField;
  final bool enabled;
  final bool visible;
  final int keySeed;
  final bool digitsOnly;
  final bool stealFocusAfterTap;
  final bool insertOverlayAfterTap;
  final bool replaceCallbackAfterTap;
  final bool sameGeometrySiblingOverlay;
  final double horizontalInset;
  final int appKeySeed;
  final pinController = TextEditingController();
  final pinFocus = FocusNode();
  final otherController = TextEditingController();
  final otherFocus = FocusNode();
  int overlayTapCount = 0;
  bool overlayRequested = false;
  bool callbackReplaced = false;
  StateSetter? _setState;

  Widget app() => MaterialApp(
    key: ValueKey('app-$appKeySeed'),
    home: StatefulBuilder(
      builder: (context, setState) {
        _setState = setState;
        return Scaffold(
          body: IgnorePointer(
            ignoring: false,
            child: AnimatedOpacity(
              opacity: 1,
              duration: Duration.zero,
              child: AnimatedOpacity(
                opacity: 1,
                duration: Duration.zero,
                child: Stack(
                  children: [
                    Column(
                      children: [
                        if (includeOtherField)
                          TextField(
                            key: const ValueKey('other-field'),
                            controller: otherController,
                            focusNode: otherFocus,
                          ),
                        Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: horizontalInset,
                          ),
                          child: Visibility(
                            visible: visible,
                            maintainState: true,
                            maintainAnimation: true,
                            maintainSize: true,
                            child: Builder(
                              builder: (context) => PinCodeTextField(
                                key: ValueKey('pin-$keySeed'),
                                appContext: context,
                                length: 6,
                                controller: pinController,
                                focusNode: pinFocus,
                                autoDisposeControllers: false,
                                enabled: enabled,
                                keyboardType: TextInputType.number,
                                inputFormatters: digitsOnly
                                    ? [FilteringTextInputFormatter.digitsOnly]
                                    : const [],
                                onTap: callbackReplaced
                                    ? _replacementTap
                                    : _initialTap,
                                onChanged: (_) {},
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (overlay)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => overlayTapCount += 1,
                        ),
                      ),
                    if (overlayRequested)
                      const Positioned.fill(
                        child: ColoredBox(
                          key: ValueKey('post-tap-overlay'),
                          color: Colors.black,
                        ),
                      ),
                    if (sameGeometrySiblingOverlay)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        height: 50,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => overlayTapCount += 1,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  void _initialTap() {
    if (stealFocusAfterTap) scheduleMicrotask(otherFocus.requestFocus);
    if (insertOverlayAfterTap) {
      _setState!(() => overlayRequested = true);
    }
    if (replaceCallbackAfterTap) {
      _setState!(() => callbackReplaced = true);
    }
  }

  void _replacementTap() => otherFocus.requestFocus();

  void dispose() {
    pinController.dispose();
    pinFocus.dispose();
    otherController.dispose();
    otherFocus.dispose();
  }
}
