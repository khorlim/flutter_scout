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
}
