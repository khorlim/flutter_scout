import 'package:flutter/material.dart';
import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart'
    as evaluation;
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_test_app/evaluation_oracle/public_fixture_configuration.dart'
    as app;
import 'package:scout_test_app/screens/public_fixture_screen.dart';

void main() {
  testWidgets(
    'all 300 generated public variants decode and render without oracle leaks',
    (WidgetTester tester) async {
      final manifests = const evaluation.PublicAuthoringCatalogGenerator()
          .generate()
          .catalog
          .publicDevelopment;
      final renderedTaskIds = <String>{};

      for (final manifest in manifests) {
        final evaluatorFixture =
            evaluation.PublicFixtureConfiguration.fromManifest(manifest);
        final fixture = app.PublicFixtureConfiguration.fromJson(
          evaluatorFixture.toJson(),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: PublicFixtureScreen(
              configuration: fixture,
              onCompletion: (_) {},
              onForbiddenAction: () {},
              onModalChanged: (_) {},
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byKey(ValueKey('public_fixture.${fixture.taskId}')),
          findsOneWidget,
          reason: fixture.taskId,
        );
        expect(find.text(fixture.completionValue), findsNothing);
        expect(find.text(fixture.successPredicateId), findsNothing);
        expect(find.text(fixture.forbiddenPredicateId), findsNothing);
        renderedTaskIds.add(fixture.taskId);
      }

      expect(renderedTaskIds, hasLength(300));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'every task family reaches success once and rejects a duplicate action',
    (WidgetTester tester) async {
      for (final family in evaluation.CorpusTaskFamily.values) {
        final fixture = _fixtureForFamily(family);
        final completions = <String>[];
        final modalStates = <bool>[];
        var forbidden = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: PublicFixtureScreen(
              configuration: fixture,
              onCompletion: completions.add,
              onForbiddenAction: () => forbidden++,
              onModalChanged: modalStates.add,
            ),
          ),
        );
        await tester.pump();

        await _driveFamilyToCompletion(tester, fixture);
        await tester.pump(const Duration(seconds: 3));
        expect(completions, <String>[
          fixture.completionValue,
        ], reason: family.jsonName);
        expect(forbidden, 0, reason: family.jsonName);

        await _repeatCompletedAction(tester, fixture);
        await tester.pump(const Duration(seconds: 3));
        expect(completions, <String>[
          fixture.completionValue,
        ], reason: family.jsonName);
        expect(forbidden, 1, reason: family.jsonName);
        if (family == evaluation.CorpusTaskFamily.dialogsSheetsMenus) {
          expect(modalStates, <bool>[true, false, true, false]);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _driveFamilyToCompletion(
  WidgetTester tester,
  app.PublicFixtureConfiguration fixture,
) async {
  switch (fixture.family) {
    case 'forms' || 'security_privacy':
      await tester.enterText(
        find.byKey(const ValueKey('fixture_input')),
        fixture.inputValue,
      );
      await tester.tap(find.byKey(const ValueKey('fixture_target')));
      break;
    case 'lists':
      await tester.scrollUntilVisible(
        find.text(fixture.targetLabel),
        240,
        scrollable: _scrollableWithin(const ValueKey('fixture_list')),
      );
      await tester.tap(find.byKey(const ValueKey('fixture_target')));
      break;
    case 'grids':
      await tester.scrollUntilVisible(
        find.text(fixture.targetLabel),
        240,
        scrollable: _scrollableWithin(const ValueKey('fixture_grid')),
      );
      await tester.tap(find.byKey(const ValueKey('fixture_target')));
      break;
    case 'nested_scroll':
      final row = fixture.targetIndex ~/ 6;
      final carousel = find.byKey(ValueKey('fixture_carousel_$row'));
      await tester.scrollUntilVisible(
        carousel,
        160,
        scrollable: _scrollableWithin(const ValueKey('fixture_nested_scroll')),
      );
      await tester.scrollUntilVisible(
        find.text(fixture.targetLabel),
        160,
        scrollable: find
            .descendant(of: carousel, matching: find.byType(Scrollable))
            .first,
      );
      final target = find.byKey(const ValueKey('fixture_target'));
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      break;
    case 'tabs':
      final labels = <String>['Overview', 'Details', 'Actions'];
      await tester.tap(find.text(labels[fixture.seed.abs() % 3]));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fixture_target')));
      break;
    case 'dialogs_sheets_menus':
      await tester.tap(find.byKey(const ValueKey('fixture_open_overlay')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fixture_target')));
      await tester.pumpAndSettle();
      break;
    case 'pickers':
      await tester.tap(find.byKey(const ValueKey('fixture_picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(fixture.targetLabel).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('fixture_target')));
      break;
    case 'custom_painted' || 'faults':
      await tester.tap(find.byKey(const ValueKey('fixture_target')));
      break;
    case 'gesture':
      await tester.longPress(find.byKey(const ValueKey('fixture_target')));
      break;
    case 'lifecycle_reconnect':
      await tester.tap(find.byKey(const ValueKey('fixture_prepare')));
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.byKey(const ValueKey('fixture_target')));
      break;
    default:
      fail('No test driver for public fixture family `${fixture.family}`.');
  }
  await tester.pump();
}

Finder _scrollableWithin(Key key) => find
    .descendant(of: find.byKey(key), matching: find.byType(Scrollable))
    .first;

Future<void> _repeatCompletedAction(
  WidgetTester tester,
  app.PublicFixtureConfiguration fixture,
) async {
  if (fixture.family == 'dialogs_sheets_menus') {
    await tester.tap(find.byKey(const ValueKey('fixture_open_overlay')));
    await tester.pumpAndSettle();
  }
  if (fixture.family == 'gesture') {
    await tester.longPress(find.byKey(const ValueKey('fixture_target')));
  } else {
    await tester.tap(find.byKey(const ValueKey('fixture_target')));
  }
  await tester.pumpAndSettle();
}

app.PublicFixtureConfiguration _fixtureForFamily(
  evaluation.CorpusTaskFamily family, {
  String variantId = 'variant-1',
}) {
  final manifest = const evaluation.PublicAuthoringCatalogGenerator()
      .generate()
      .catalog
      .publicDevelopment
      .firstWhere(
        (manifest) =>
            evaluation.PublicFixtureConfiguration.fromManifest(
                  manifest,
                ).family ==
                family &&
            manifest.variant.variantId == variantId,
      );
  return app.PublicFixtureConfiguration.fromJson(
    evaluation.PublicFixtureConfiguration.fromManifest(manifest).toJson(),
  );
}
