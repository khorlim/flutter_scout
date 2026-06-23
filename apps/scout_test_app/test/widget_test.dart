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
}
