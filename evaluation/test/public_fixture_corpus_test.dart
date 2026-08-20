import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

void main() {
  test('all 300 public variants have strict distinct runnable fixtures', () {
    final generated = const PublicAuthoringCatalogGenerator().generate();
    final manifests = generated.catalog.publicDevelopment;
    final taskIds = <String>{};
    final configurationJson = <String>{};
    final patternIds = <String>{};
    final familyCounts = <CorpusTaskFamily, int>{};

    expect(manifests, hasLength(300));
    for (final manifest in manifests) {
      final fixture = PublicFixtureConfiguration.fromManifest(manifest);
      expect(taskIds.add(fixture.taskId), isTrue);
      expect(
        configurationJson.add(canonicalJsonEncode(fixture.toJson())),
        isTrue,
      );
      patternIds.add(fixture.patternId);
      familyCounts.update(
        fixture.family,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      expect(manifest.agentVisible.instruction, isNot(contains('scaffold')));
      expect(manifest.agentVisible.instruction, contains(fixture.targetLabel));
      expect(fixture.targetIndex, lessThan(fixture.contentLength));
      expect(fixture.perturbations, isNotEmpty);
      expect(
        PublicFixtureConfiguration.fromJson(fixture.toJson()).toJson(),
        fixture.toJson(),
      );
    }

    expect(patternIds, hasLength(60));
    expect(familyCounts.keys.toSet(), CorpusTaskFamily.values.toSet());
    expect(familyCounts.values, everyElement(25));
  });

  test('all 300 agent projections exclude oracle configuration and values', () {
    final manifests = const PublicAuthoringCatalogGenerator()
        .generate()
        .catalog
        .publicDevelopment;

    for (final manifest in manifests) {
      final fixture = PublicFixtureConfiguration.fromManifest(manifest);
      final projection = manifest.toAgentView().toJson();
      final encoded = jsonEncode(projection);
      expect(projection.keys.toSet(), <String>{
        'schemaVersion',
        'taskId',
        'instruction',
        'allowedTools',
        'budget',
      });
      expect(encoded, isNot(contains(publicFixtureParameterKey)));
      expect(encoded, isNot(contains(publicFixtureOracleId)));
      expect(encoded, isNot(contains(fixture.completionValue)));
      expect(encoded, isNot(contains(fixture.successPredicateId)));
      expect(encoded, isNot(contains(fixture.forbiddenPredicateId)));
      expect(encoded, isNot(contains('completionValue')));
      expect(encoded, isNot(contains('predicateResults')));
    }
  });

  test('strict fixture decoder rejects drift and manifest mismatches', () {
    final manifest = const PublicAuthoringCatalogGenerator()
        .generate()
        .catalog
        .publicDevelopment
        .first;
    final fixture = PublicFixtureConfiguration.fromManifest(manifest);

    expect(
      () => PublicFixtureConfiguration.fromJson(<String, Object?>{
        ...fixture.toJson(),
        'unknown': true,
      }),
      throwsFormatException,
    );
    final mismatched = TaskManifest.fromJson(<String, Object?>{
      ...manifest.toJson(),
      'taskId': 'different-task.variant-1',
    });
    expect(
      () => PublicFixtureConfiguration.fromManifest(mismatched),
      throwsFormatException,
    );
  });

  test('tool-simulator contract routes every public manifest through the '
      'independent fixture boundary', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'flutter_scout_public_fixture_corpus_',
    );
    addTearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });
    final archive = Directory('${temporary.path}/archive');
    final oracle = _PublicCorpusOracleClient();
    final runner = ToolSimulatorEpisodeRunner(
      oracleClient: oracle,
      commandExecutor: const _SuccessfulScoutExecutor(),
      archive: RawEpisodeArchive(archive),
    );
    final manifests = const PublicAuthoringCatalogGenerator()
        .generate()
        .catalog
        .publicDevelopment;

    for (var index = 0; index < manifests.length; index++) {
      final manifest = manifests[index];
      final fixture = PublicFixtureConfiguration.fromManifest(manifest);
      final episodeId = 'public-fixture-episode-${index + 1}';
      final run = await runner.run(
        manifest: manifest,
        episodeId: episodeId,
        condition: 'candidate',
        vmServiceUri: 'ws://127.0.0.1:8181/example/ws',
        planProvider: StaticToolSimulatorPlanProvider(
          ToolSimulatorPlan(
            episodeId: episodeId,
            condition: 'candidate',
            agentClaimedSuccess: true,
            reportedTokens: 1,
            actions: <ToolSimulatorAction>[
              ToolSimulatorAction(const <String>['inspect']),
            ],
          ),
        ),
      );
      expect(run.episode.validEpisode, isTrue, reason: manifest.taskId);
      expect(run.episode.passed, isTrue, reason: manifest.taskId);
      expect(run.archiveFile.existsSync(), isTrue, reason: manifest.taskId);
      final nonHarness = jsonEncode(<String, Object?>{
        'agentEvents': run.episode.raw.agentEvents,
        'toolEvents': run.episode.raw.toolEvents,
      });
      expect(nonHarness, isNot(contains(fixture.completionValue)));
      expect(nonHarness, isNot(contains(fixture.successPredicateId)));
    }

    expect(oracle.configuredTaskIds, hasLength(300));
    expect(oracle.configuredTaskIds.toSet(), hasLength(300));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('public fixture false-success claim is release-blocking', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'flutter_scout_public_fixture_false_success_',
    );
    addTearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });
    final manifest = const PublicAuthoringCatalogGenerator()
        .generate()
        .catalog
        .publicDevelopment
        .first;
    final run =
        await ToolSimulatorEpisodeRunner(
          oracleClient: _PublicCorpusOracleClient(emitCompletion: false),
          commandExecutor: const _SuccessfulScoutExecutor(),
          archive: RawEpisodeArchive(Directory('${temporary.path}/archive')),
        ).run(
          manifest: manifest,
          episodeId: 'public-fixture-false-success',
          condition: 'candidate',
          vmServiceUri: 'ws://127.0.0.1:8181/example/ws',
          planProvider: StaticToolSimulatorPlanProvider(
            ToolSimulatorPlan(
              episodeId: 'public-fixture-false-success',
              condition: 'candidate',
              agentClaimedSuccess: true,
              reportedTokens: 1,
              actions: <ToolSimulatorAction>[
                ToolSimulatorAction(const <String>['inspect']),
              ],
            ),
          ),
        );

    expect(run.episode.passed, isFalse);
    expect(run.episode.failure?.category, FailureCategory.safetyFalseSuccess);
    expect(run.episode.failure?.severity, FailureSeverity.releaseBlocking);
  });
}

/// Exercises runner plumbing only. UI execution is owned by the verification
/// app widget suite and is never inferred from this deterministic fake.
class _PublicCorpusOracleClient implements SupplierOracleClient {
  _PublicCorpusOracleClient({this.emitCompletion = true});

  final bool emitCompletion;
  final List<String> configuredTaskIds = <String>[];
  PublicFixtureConfiguration? _fixture;
  int _generation = 0;
  int _readsAfterSetup = -1;
  bool _awaitingTeardown = false;
  int _request = 0;

  @override
  Future<SupplierOracleObservation> readState() async {
    final fixture = _fixture;
    if (_readsAfterSetup < 0 || fixture == null) {
      return _observation(clean: true);
    }
    _readsAfterSetup++;
    return _observation(clean: _readsAfterSetup != 2);
  }

  @override
  Future<SupplierOracleObservation> reset({
    Map<String, Object?>? publicFixture,
  }) async {
    if (!_awaitingTeardown) {
      if (publicFixture == null) {
        throw StateError('A public fixture configuration was not supplied.');
      }
      _fixture = PublicFixtureConfiguration.fromJson(publicFixture);
      configuredTaskIds.add(_fixture!.taskId);
      _generation++;
      _readsAfterSetup = 0;
      _awaitingTeardown = true;
    } else {
      final repeated = PublicFixtureConfiguration.fromJson(publicFixture);
      if (repeated.taskId != _fixture!.taskId) {
        throw StateError('Teardown selected a different public fixture.');
      }
      _generation++;
      _readsAfterSetup = -1;
      _awaitingTeardown = false;
    }
    return _observation(clean: true, operation: 'reset');
  }

  SupplierOracleObservation _observation({
    required bool clean,
    String operation = 'state',
  }) {
    final fixture = _fixture;
    final success = !clean && fixture != null && emitCompletion;
    return SupplierOracleObservation(
      operation: operation,
      requestId: 'request-${++_request}',
      runtimeId: 'runtime-public-corpus',
      workflowAttached: true,
      resetGeneration: _generation,
      resetPerformed: operation == 'reset',
      state: SupplierOracleState(
        modalOpen: false,
        supplierAdditionCount: success ? 1 : 0,
        supplierNames: success
            ? <String>[fixture.completionValue]
            : const <String>[],
        forbiddenDuplicateActionCount: 0,
        forbiddenWrongActionCount: 0,
        activeTaskId: fixture?.taskId,
        predicateResults: fixture == null
            ? const <String, bool>{}
            : <String, bool>{
                fixture.successPredicateId: success,
                fixture.forbiddenPredicateId: false,
              },
      ),
    );
  }
}

class _SuccessfulScoutExecutor implements ScoutCommandExecutor {
  const _SuccessfulScoutExecutor();

  @override
  Future<ScoutCommandResult> attach({
    required String vmServiceUri,
    required Duration timeout,
  }) async => const ScoutCommandResult(
    arguments: <String>['attach', '--debug-url-file', '<protected>'],
    exitCode: 0,
    stdout: '{"ok":true}',
    stderr: '',
    elapsedMs: 1,
    timedOut: false,
    outputTruncated: false,
  );

  @override
  Future<ScoutCommandResult> execute({
    required List<String> arguments,
    required Duration timeout,
  }) async => ScoutCommandResult(
    arguments: arguments,
    exitCode: 0,
    stdout: '{"ok":true}',
    stderr: '',
    elapsedMs: 1,
    timedOut: false,
    outputTruncated: false,
  );
}
