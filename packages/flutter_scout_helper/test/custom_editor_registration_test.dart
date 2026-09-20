import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pin_code_fields/pin_code_fields.dart';

void main() {
  testWidgets('registered real pin editor accepts explicit input', (
    tester,
  ) async {
    final fixture = _PinFixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(_app(fixture.registeredPin()));
    await fixture.focus(tester);

    final result = await _input(tester, '246810');
    final resolution = result['resolution']! as Map<String, Object?>;
    final authorization =
        resolution['explicitEditableAuthorization']! as Map<String, Object?>;

    expect(result['ok'], isTrue, reason: '$result');
    expect(fixture.controller.text, '246810');
    expect(
      authorization,
      containsPair('authorizationKind', 'registered_custom_editable_surface'),
    );
    expect(authorization, containsPair('policyVersion', 1));
    expect(authorization, containsPair('focusIdentityMatched', true));
    expect(authorization, containsPair('controllerIdentityMatched', true));
    expect(authorization, containsPair('hitWithinRegisteredSurface', true));
    expect(authorization, containsPair('revalidated', true));
  });

  testWidgets('unregistered real pin editor fails closed', (tester) async {
    final fixture = _PinFixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(_app(fixture.pin()));
    await fixture.focus(tester);

    final result = await _input(tester, '246810');

    _expectRejectedUnchanged(result, fixture.controller);
  });

  testWidgets('same-stack external occluder stays rejected', (tester) async {
    final fixture = _PinFixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 320,
          height: 56,
          child: Stack(
            children: [
              fixture.registeredPin(),
              const Positioned.fill(child: _OpaqueShield()),
            ],
          ),
        ),
      ),
    );
    await fixture.focus(tester);

    final result = await _input(tester, '246810');

    _expectRejectedUnchanged(result, fixture.controller);
  });

  testWidgets('tight-owner external occluder stays rejected', (tester) async {
    final fixture = _PinFixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(_app(_TightOwner(editor: fixture.registeredPin())));
    await fixture.focus(tester);

    final result = await _input(tester, '246810');

    _expectRejectedUnchanged(result, fixture.controller);
  });

  testWidgets('ordinary explicit TextField input remains supported', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      _app(
        TextField(
          key: const ValueKey('ordinary'),
          controller: controller,
          focusNode: focus,
          decoration: const InputDecoration(labelText: 'Ordinary'),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();

    final result = await _input(tester, 'hello');

    expect(result['ok'], isTrue, reason: '$result');
    expect(controller.text, 'hello');
  });

  testWidgets('ordinary externally occluded TextField remains rejected', (
    tester,
  ) async {
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      _app(
        SizedBox(
          width: 320,
          height: 56,
          child: Stack(
            children: [
              TextField(controller: controller, focusNode: focus),
              const Positioned.fill(child: _OpaqueShield()),
            ],
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();

    final result = await _input(tester, 'blocked');

    _expectRejectedUnchanged(result, controller);
  });

  testWidgets('registration with mismatched controller fails closed', (
    tester,
  ) async {
    final fixture = _PinFixture();
    final other = TextEditingController();
    addTearDown(fixture.dispose);
    addTearDown(other.dispose);
    await tester.pumpWidget(
      _app(
        ScoutExplicitEditableSurface(
          policyVersion: 1,
          controller: other,
          focusNode: fixture.focusNode,
          child: fixture.pin(),
        ),
      ),
    );
    await fixture.focus(tester);

    final result = await _input(tester, '246810');

    _expectRejectedUnchanged(result, fixture.controller);
  });

  testWidgets('registration with mismatched focus fails closed', (
    tester,
  ) async {
    final fixture = _PinFixture();
    final other = FocusNode();
    addTearDown(fixture.dispose);
    addTearDown(other.dispose);
    await tester.pumpWidget(
      _app(
        ScoutExplicitEditableSurface(
          policyVersion: 1,
          controller: fixture.controller,
          focusNode: other,
          child: fixture.pin(),
        ),
      ),
    );
    await fixture.focus(tester);

    final result = await _input(tester, '246810');

    _expectRejectedUnchanged(result, fixture.controller);
  });

  testWidgets('registration containing two editors fails closed', (
    tester,
  ) async {
    final first = TextEditingController();
    final second = TextEditingController();
    final firstFocus = FocusNode();
    final secondFocus = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    addTearDown(firstFocus.dispose);
    addTearDown(secondFocus.dispose);
    await tester.pumpWidget(
      _app(
        ScoutExplicitEditableSurface(
          policyVersion: 1,
          controller: first,
          focusNode: firstFocus,
          child: Column(
            children: [
              TextField(controller: first, focusNode: firstFocus),
              TextField(controller: second, focusNode: secondFocus),
            ],
          ),
        ),
      ),
    );
    firstFocus.requestFocus();
    await tester.pump();

    final runtime = FlutterScoutHelper.debugRuntime;
    final fields = runtime.debugSnapshot().fields;
    expect(fields, hasLength(2));
    final result = (await tester.runAsync(
      () => runtime.debugInputTarget(
        '${fields.first.id}#${fields.first.ordinal}',
        'blocked',
      ),
    ))!;

    expect(result['ok'], isFalse, reason: '$result');
    expect(first.text, isEmpty);
    expect(second.text, isEmpty);
  });

  test('registration policy and protocol capability are versioned', () {
    expect(ScoutExplicitEditableSurface.currentPolicyVersion, 1);
    final contract = FlutterScoutRuntime().debugProtocolCompatibilityContract();
    expect(
      contract['capabilities'],
      isA<Map>().having(
        (value) => value['registeredCustomEditableSurfaceV1'],
        'registeredCustomEditableSurfaceV1',
        true,
      ),
    );
  });
}

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(child: SizedBox(width: 320, child: child)),
  ),
);

Future<Map<String, Object?>> _input(WidgetTester tester, String value) async {
  final runtime = FlutterScoutHelper.debugRuntime;
  final fields = runtime.debugSnapshot().fields;
  expect(fields, hasLength(1));
  return (await tester.runAsync(
    () => runtime.debugInputTarget(fields.single.id, value),
  ))!;
}

void _expectRejectedUnchanged(
  Map<String, Object?> result,
  TextEditingController controller,
) {
  expect(result['ok'], isFalse, reason: '$result');
  expect(result['reason'], 'target_not_hit_testable');
  final resolution = result['resolution']! as Map<String, Object?>;
  expect(resolution['status'], anyOf('occluded', 'notHitTestable'));
  expect(controller.text, isEmpty);
}

class _PinFixture {
  final controller = TextEditingController();
  final focusNode = FocusNode();

  Widget pin() => Builder(
    builder: (context) => PinCodeTextField(
      appContext: context,
      length: 6,
      controller: controller,
      focusNode: focusNode,
      autoDisposeControllers: false,
      autoFocus: true,
      obscureText: true,
      keyboardType: TextInputType.number,
      animationType: AnimationType.none,
      onChanged: (_) {},
    ),
  );

  Widget registeredPin() => ScoutExplicitEditableSurface(
    policyVersion: 1,
    controller: controller,
    focusNode: focusNode,
    child: pin(),
  );

  Future<void> focus(WidgetTester tester) async {
    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
  }

  void dispose() {
    controller.dispose();
    focusNode.dispose();
  }
}

class _OpaqueShield extends StatelessWidget {
  const _OpaqueShield();

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () {},
    child: const SizedBox.expand(),
  );
}

class _TightOwner extends StatefulWidget {
  const _TightOwner({required this.editor});

  final Widget editor;

  @override
  State<_TightOwner> createState() => _TightOwnerState();
}

class _TightOwnerState extends State<_TightOwner> {
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 320,
    height: 56,
    child: Stack(
      children: [
        widget.editor,
        const Positioned.fill(child: _OpaqueShield()),
      ],
    ),
  );
}
