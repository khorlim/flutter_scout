import 'dart:io';

import 'catalog.dart';
import 'corpus.dart';
import 'digests.dart';
import 'public_fixture.dart';
import 'task_manifest.dart';

class PublicAuthoringCorpus {
  const PublicAuthoringCorpus({
    required this.catalog,
    required this.descriptor,
  });

  final CatalogSets catalog;
  final CorpusDescriptor descriptor;
}

/// Builds deterministic, runnable public Stress Lab fixtures.
///
/// The public catalog remains release-ineligible because it intentionally has
/// no private split, frozen split, or real-application integrations.
class PublicAuthoringCatalogGenerator {
  const PublicAuthoringCatalogGenerator();

  PublicAuthoringCorpus generate() {
    final manifests = <TaskManifest>[];
    final descriptors = <CorpusTemplateDescriptor>[];
    final app = CorpusAppIdentity(
      appId: 'flutter-scout-stress-lab',
      displayName: 'Flutter Scout Stress Lab public fixtures',
      kind: CorpusAppKind.stressLab,
      source: 'workspace:apps/scout_test_app',
      revision: publicFixtureRevision,
    );

    for (var familyIndex = 0; familyIndex < _templates.length; familyIndex++) {
      final definition = _templates[familyIndex];
      for (
        var templateIndex = 0;
        templateIndex < definition.templateIds.length;
        templateIndex++
      ) {
        final templateId = definition.templateIds[templateIndex];
        final variantDescriptors = <CorpusVariantDescriptor>[];
        for (var variantIndex = 0; variantIndex < 5; variantIndex++) {
          final ordinal = variantIndex + 1;
          final variantId = 'variant-$ordinal';
          final taskId = '$templateId.$variantId';
          final dimensions = _dimensionGroups[variantIndex];
          final seed =
              (familyIndex + 1) * 10000 + (templateIndex + 1) * 100 + ordinal;
          final fixture = _fixtureConfiguration(
            taskId: taskId,
            templateId: templateId,
            variantId: variantId,
            seed: seed,
            family: definition.family,
            familyIndex: familyIndex,
            templateIndex: templateIndex,
            variantIndex: variantIndex,
            dimensions: dimensions,
          );
          manifests.add(
            TaskManifest(
              taskId: taskId,
              templateId: templateId,
              split: BenchmarkSplit.publicDevelopment,
              agentVisible: AgentTaskDefinition(
                instruction: _instruction(fixture),
                allowedTools: const ['flutter-scout'],
                budget: const TaskBudget(
                  maxActions: 30,
                  maxWallTimeMs: 120000,
                  maxTokens: 8000,
                ),
              ),
              hiddenHarness: HiddenHarnessDefinition(
                oracleId: publicFixtureOracleId,
                setupFixture: publicFixtureSetupFixture,
                successPredicateIds: [fixture.successPredicateId],
                forbiddenPredicateIds: [fixture.forbiddenPredicateId],
                teardownFixture: publicFixtureTeardownFixture,
              ),
              variant: TaskVariant(
                variantId: variantId,
                seed: seed,
                parameters: {publicFixtureParameterKey: fixture.toJson()},
              ),
            ),
          );
          variantDescriptors.add(
            CorpusVariantDescriptor(
              taskId: taskId,
              variantId: variantId,
              semanticsPreserving: true,
              perturbationDimensions: dimensions,
            ),
          );
        }
        descriptors.add(
          CorpusTemplateDescriptor(
            templateId: templateId,
            app: app,
            families: [definition.family],
            variants: variantDescriptors,
          ),
        );
      }
    }

    return PublicAuthoringCorpus(
      catalog: CatalogSets(
        publicDevelopment: manifests,
        privateValidation: const [],
        frozenHiddenRelease: const [],
      ),
      descriptor: CorpusDescriptor(
        corpusId: 'flutter-scout-public-authoring',
        corpusVersion: '1.0.0',
        templates: descriptors,
      ),
    );
  }

  Future<void> write(Directory root) async {
    if (await root.exists()) {
      final first = await root.list(followLinks: false).take(1).toList();
      if (first.isNotEmpty) {
        throw FileSystemException(
          'Refusing to overwrite a non-empty authoring catalog directory.',
          root.path,
        );
      }
    } else {
      await root.create(recursive: true);
    }

    final generated = generate();
    for (final split in const ['public', 'private', 'frozen']) {
      await Directory('${root.path}/$split').create(recursive: true);
    }
    for (final manifest in generated.catalog.publicDevelopment) {
      final directory = Directory('${root.path}/public/${manifest.templateId}');
      await directory.create(recursive: true);
      await File('${directory.path}/${manifest.taskId}.json').writeAsString(
        '${canonicalJsonEncode(manifest.toJson())}\n',
        flush: true,
      );
    }
    await File('${root.path}/corpus_descriptor.v1.json').writeAsString(
      '${canonicalJsonEncode(generated.descriptor.toJson())}\n',
      flush: true,
    );
  }
}

PublicFixtureConfiguration _fixtureConfiguration({
  required String taskId,
  required String templateId,
  required String variantId,
  required int seed,
  required CorpusTaskFamily family,
  required int familyIndex,
  required int templateIndex,
  required int variantIndex,
  required List<PerturbationDimension> dimensions,
}) {
  final ordinal = variantIndex + 1;
  final humanTitle = templateId
      .split('-')
      .map(
        (word) => word.isEmpty
            ? word
            : '${word.substring(0, 1).toUpperCase()}${word.substring(1)}',
      )
      .join(' ');
  final targetNumber = (seed % 89) + 10;
  final contentLength = switch (variantIndex) {
    1 => 48 + templateIndex * 4,
    _ => 16 + templateIndex * 3,
  };
  final targetIndex = (seed * 17) % contentLength;
  final successPredicateId = 'predicate.$taskId.completed';
  final forbiddenPredicateId = 'predicate.$taskId.forbidden';
  return PublicFixtureConfiguration(
    taskId: taskId,
    templateId: templateId,
    variantId: variantId,
    seed: seed,
    family: family,
    patternId: templateId,
    title: humanTitle,
    targetLabel: '$humanTitle target $targetNumber',
    decoyLabel: '$humanTitle decoy ${targetNumber + 1}',
    inputLabel: '$humanTitle value',
    inputValue: 'Public value ${familyIndex + 1}-${templateIndex + 1}-$ordinal',
    completionValue: 'fixture-complete.$taskId.$seed',
    contentLength: contentLength,
    targetIndex: targetIndex,
    initialPage: variantIndex == 2 ? (seed % 3) : 0,
    delayMs: variantIndex == 3 ? 240 + templateIndex * 40 : 0,
    initialModalOpen: variantIndex == 2,
    initialFocus: variantIndex == 2,
    labelOnlyTarget: variantIndex == 4,
    successPredicateId: successPredicateId,
    forbiddenPredicateId: forbiddenPredicateId,
    perturbations: <String, String>{
      for (final dimension in dimensions)
        dimension.jsonName: '${dimension.jsonName}-$ordinal',
    },
  );
}

String _instruction(PublicFixtureConfiguration fixture) {
  final target = '`${fixture.targetLabel}`';
  return switch (fixture.family) {
    CorpusTaskFamily.forms =>
      'In the ${fixture.title} fixture, enter '
          '`${fixture.inputValue}` in `${fixture.inputLabel}`, then activate '
          '$target exactly once.',
    CorpusTaskFamily.lists =>
      'In the ${fixture.title} lazy list, find and activate $target exactly '
          'once. Do not activate the similarly named decoy.',
    CorpusTaskFamily.grids =>
      'In the ${fixture.title} grid, find and activate $target exactly once. '
          'Do not activate the similarly named decoy.',
    CorpusTaskFamily.nestedScroll =>
      'Navigate the nested scrolling surface for ${fixture.title} and '
          'activate $target exactly once.',
    CorpusTaskFamily.tabs =>
      'Open the tab containing $target in the ${fixture.title} fixture, then '
          'activate it exactly once.',
    CorpusTaskFamily.dialogsSheetsMenus =>
      'Open the ${fixture.title} overlay and choose $target exactly once, '
          'leaving the overlay closed.',
    CorpusTaskFamily.pickers =>
      'Choose $target in the ${fixture.title} picker and commit the selection '
          'exactly once.',
    CorpusTaskFamily.customPainted =>
      'Use the ${fixture.title} visual control to activate $target exactly '
          'once.',
    CorpusTaskFamily.gesture =>
      'Complete the gesture requested beside $target in the '
          '${fixture.title} fixture exactly once.',
    CorpusTaskFamily.lifecycleReconnect =>
      'Prepare the ${fixture.title} fixture, wait for its deterministic '
          'rebuild, then activate $target exactly once.',
    CorpusTaskFamily.faults =>
      'Recover the simulated ${fixture.title} fault by activating $target '
          'exactly once; do not choose the ignore action.',
    CorpusTaskFamily.securityPrivacy =>
      'In the synthetic ${fixture.title} security fixture, enter '
          '`${fixture.inputValue}` in `${fixture.inputLabel}` and activate '
          '$target exactly once.',
  };
}

class _FamilyTemplates {
  const _FamilyTemplates(this.family, this.templateIds);

  final CorpusTaskFamily family;
  final List<String> templateIds;
}

const _templates = <_FamilyTemplates>[
  _FamilyTemplates(CorpusTaskFamily.forms, [
    'validated-text-form',
    'multi-field-profile-form',
    'checkbox-radio-form',
    'password-confirmation-form',
    'autosave-debounced-form',
  ]),
  _FamilyTemplates(CorpusTaskFamily.lists, [
    'lazy-list-target',
    'reordered-list',
    'duplicate-list-labels',
    'infinite-list-loading',
    'large-tree-list',
  ]),
  _FamilyTemplates(CorpusTaskFamily.grids, [
    'lazy-grid-target',
    'reordered-grid',
    'responsive-grid',
    'duplicate-grid-labels',
    'paged-grid',
  ]),
  _FamilyTemplates(CorpusTaskFamily.nestedScroll, [
    'vertical-nested-scroll',
    'horizontal-carousel-scroll',
    'nested-horizontal-vertical-scroll',
    'sliver-header-scroll',
    'split-pane-scroll',
  ]),
  _FamilyTemplates(CorpusTaskFamily.tabs, [
    'tab-switch',
    'nested-tabs',
    'split-pane-navigation',
    'expansion-navigation',
    'nested-navigator-route',
  ]),
  _FamilyTemplates(CorpusTaskFamily.dialogsSheetsMenus, [
    'modal-dialog',
    'bottom-sheet',
    'popup-menu',
    'stacked-overlays',
    'modal-barrier',
  ]),
  _FamilyTemplates(CorpusTaskFamily.pickers, [
    'date-picker',
    'time-picker',
    'dropdown-picker',
    'segmented-picker',
    'searchable-picker',
  ]),
  _FamilyTemplates(CorpusTaskFamily.customPainted, [
    'custom-painter-control',
    'missing-semantics-control',
    'platform-view-boundary',
    'canvas-hotspot',
    'degraded-semantic-node',
  ]),
  _FamilyTemplates(CorpusTaskFamily.gesture, [
    'long-press-target',
    'drag-slider',
    'swipe-dismiss',
    'moving-target',
    'debounced-button',
  ]),
  _FamilyTemplates(CorpusTaskFamily.lifecycleReconnect, [
    'stale-handle',
    'rebuild-during-action',
    'hot-reload-state',
    'hot-restart-recovery',
    'vm-reconnect',
  ]),
  _FamilyTemplates(CorpusTaskFamily.faults, [
    'app-death',
    'framework-error',
    'render-overflow',
    'image-load-failure',
    'source-mismatch',
  ]),
  _FamilyTemplates(CorpusTaskFamily.securityPrivacy, [
    'protected-input-redaction',
    'duplicate-session-isolation',
    'cross-run-stale-handle',
    'untrusted-label-injection',
    'local-transport-auth',
  ]),
];

const _dimensionGroups = <List<PerturbationDimension>>[
  [
    PerturbationDimension.viewport,
    PerturbationDimension.devicePixelRatio,
    PerturbationDimension.orientation,
  ],
  [
    PerturbationDimension.contentOrder,
    PerturbationDimension.contentLength,
    PerturbationDimension.initialScrollState,
  ],
  [
    PerturbationDimension.initialTabState,
    PerturbationDimension.initialModalState,
    PerturbationDimension.initialFocusState,
  ],
  [PerturbationDimension.animationDelay, PerturbationDimension.networkDelay],
  [
    PerturbationDimension.semanticsDegradation,
    PerturbationDimension.keyDegradation,
  ],
];
