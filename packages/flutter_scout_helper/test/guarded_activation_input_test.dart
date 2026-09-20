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
    final targets = _pinTargets();

    final result = (await tester.runAsync(
      () => FlutterScoutHelper.debugRuntime.debugInputTarget(
        targets.field,
        '246810',
        activationTarget: targets.activation,
      ),
    ))!;

    expect(result['ok'], isTrue);
    expect(fixture.pinController.text, '246810');
    expect(result['guardedActivation'], isA<Map<String, Object?>>());
    expect(result.toString(), isNot(contains('246810')));
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

    final result = (await tester.runAsync(
      () => FlutterScoutHelper.debugRuntime.debugInputTarget(
        pin.id,
        '112233',
        activationTarget: other.id,
      ),
    ))!;

    expect(result['ok'], isFalse);
    expect(result['reason'], 'activation_focused_different_field');
    expect(_textDispatch(result), 'not_dispatched');
    expect(fixture.pinController.text, isEmpty);
    expect(fixture.otherController.text, isEmpty);
  });

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

    expect(result['ok'], isTrue);
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

    final result = (await tester.runAsync(
      () => FlutterScoutHelper.debugRuntime.debugInputTarget(
        targets.field,
        'abc9876543',
        activationTarget: targets.activation,
      ),
    ))!;

    expect(result['ok'], isTrue);
    expect(fixture.pinController.text, '987654');
  });
}

Future<void> _pumpFixture(WidgetTester tester, _Fixture fixture) async {
  FlutterScoutHelper.ensureRegistered();
  await tester.pumpWidget(fixture.app());
  await tester.pump();
}

({String field, String activation}) _pinTargets() {
  final snapshot = FlutterScoutHelper.debugRuntime.debugSnapshot();
  return (
    field: snapshot.fields.single.id,
    activation: snapshot.interactables.single.id,
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
  });

  final bool overlay;
  final bool includeOtherField;
  final bool enabled;
  final bool visible;
  final int keySeed;
  final bool digitsOnly;
  final pinController = TextEditingController();
  final pinFocus = FocusNode();
  final otherController = TextEditingController();
  int overlayTapCount = 0;

  Widget app() => MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              if (includeOtherField)
                TextField(
                  key: const ValueKey('other-field'),
                  controller: otherController,
                ),
              Visibility(
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
                    onChanged: (_) {},
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
        ],
      ),
    ),
  );

  void dispose() {
    pinController.dispose();
    pinFocus.dispose();
    otherController.dispose();
  }
}
