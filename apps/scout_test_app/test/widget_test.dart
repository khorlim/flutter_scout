import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_test_app/main.dart';

void main() {
  testWidgets('supplier form can add a supplier', (WidgetTester tester) async {
    await tester.pumpWidget(const ScoutTestApp());

    expect(find.text('No suppliers found'), findsOneWidget);

    await tester.tap(find.text('Add supplier'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('supplier_name')),
      'QA Supplier',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('QA Supplier'), findsOneWidget);
  });

  testWidgets('smoke issues screen covers duplicate fields and picker', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ScoutTestApp());

    await tester.tap(find.text('Smoke issues'));
    await tester.pumpAndSettle();

    expect(find.text('Smoke issues'), findsOneWidget);
    expect(find.text('Enter the remark'), findsNWidgets(2));
    expect(find.text('Enter duplicate note'), findsNWidgets(2));

    await tester.enterText(
      find.byKey(const ValueKey('choice_remark')),
      'Choice remark',
    );
    await tester.enterText(
      find.byKey(const ValueKey('overall_remark')),
      'Overall remark',
    );
    await tester.enterText(
      find.byKey(const ValueKey('committed_answer')),
      'Committed answer',
    );
    await tester.pumpAndSettle();

    expect(find.text('Committed answer: Committed answer'), findsOneWidget);

    await tester.tap(find.text('Select Staff'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GoodJob'));
    await tester.pumpAndSettle();

    expect(find.text('Selected staff: GoodJob'), findsOneWidget);
  });

  testWidgets('custom phone dialog uses visible digit buttons', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ScoutTestApp());

    await tester.tap(find.text('Custom phone'));
    await tester.pumpAndSettle();

    expect(find.text('Phone Number'), findsOneWidget);
    expect(find.text('60'), findsOneWidget);

    for (final digit in '151234567'.split('')) {
      await tester.tap(find.byKey(ValueKey('custom_digit_$digit')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Custom phone: 60151234567'), findsOneWidget);
  });

  testWidgets('stress lab hub opens and lists destinations', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ScoutTestApp());

    await tester.tap(find.byKey(const ValueKey('stress_lab')));
    await tester.pumpAndSettle();

    expect(find.text('Scout Stress Lab'), findsOneWidget);
    expect(find.byKey(const ValueKey('lab_grid')), findsOneWidget);
    expect(find.byKey(const ValueKey('lab_long_list')), findsOneWidget);
    expect(find.byKey(const ValueKey('lab_mega_form')), findsOneWidget);
  });

  testWidgets('mega form opens and accepts input', (WidgetTester tester) async {
    await tester.pumpWidget(const ScoutTestApp());

    await tester.tap(find.byKey(const ValueKey('stress_lab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('lab_mega_form')));
    await tester.pumpAndSettle();

    expect(find.text('Mega form'), findsOneWidget);
    expect(find.byKey(const ValueKey('mega_form_scroll')), findsOneWidget);

    // Name and email sit at the top of the lazily-built form.
    await tester.enterText(
      find.byKey(const ValueKey('mega_name')),
      'QA Customer',
    );
    await tester.enterText(
      find.byKey(const ValueKey('mega_email')),
      'qa@example.com',
    );
    await tester.pumpAndSettle();

    expect(find.text('QA Customer'), findsOneWidget);
    expect(find.text('qa@example.com'), findsOneWidget);
  });
}
