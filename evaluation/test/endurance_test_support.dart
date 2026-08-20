import 'dart:convert';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';

EnduranceConfig testEnduranceConfig({
  String enduranceRunId = 'endurance-test',
  EnduranceRunMode mode = EnduranceRunMode.testOnly,
  int minimumActions = 3,
  int minimumDurationMs = 0,
  int maximumActions = 6,
  int maximumDurationMs = 60000,
  int maximumNoProgress = 3,
  int maximumGrowthBytes = 1024 * 1024,
  double maximumSlopeBytesPerAction = 64 * 1024,
  List<EnduranceActionSpec>? actions,
}) => EnduranceConfig(
  enduranceRunId: enduranceRunId,
  mode: mode,
  testOnlyReason: mode == EnduranceRunMode.testOnly
      ? 'Short deterministic harness contract test; not empirical evidence.'
      : null,
  condition: PerformanceCondition(
    conditionId: 'candidate',
    scoutGitCommit: 'a' * 40,
    cliVersion: '2.0.0-dev.1',
    helperVersion: '0.2.0-dev.1',
    protocolVersion: '15',
  ),
  environment: PerformanceEnvironment(
    hardware: PerformanceHardware(
      model: 'Test host',
      cpu: 'Test CPU',
      memoryBytes: 16 * 1024 * 1024 * 1024,
    ),
    hostOs: PerformanceHostOs(
      name: 'Test OS',
      version: '1.0',
      architecture: 'arm64',
    ),
    toolchains: PerformanceToolchains(
      flutterVersion: '3.44.2',
      dartVersion: '3.12.2',
      platformSdkVersion: 'test-sdk-1',
    ),
    buildMode: PerformanceBuildMode.debug,
    fixture: PerformanceFixture(
      appId: 'scout-test-app',
      appGitCommit: 'b' * 40,
      fixtureId: 'endurance-fixture',
      scenario: PerformanceScenario.actionOverhead,
      treeSizeNodes: 100,
    ),
    viewport: PerformanceViewport(
      logicalWidth: 390,
      logicalHeight: 844,
      devicePixelRatio: 3,
    ),
    device: PerformanceDevice(
      platform: 'ios-simulator',
      model: 'Test device',
      osImage: 'Test image 1',
    ),
    measurement: PerformanceMeasurementMethod(
      clock: 'fake-monotonic',
      method: 'per-step-independent-probe',
      collector: 'test-endurance-controller',
      collectorVersion: '1.0.0-test',
      tokenEstimator: 'utf8_bytes_divisor_ceiling',
      estimatedUtf8BytesPerToken: 4,
    ),
  ),
  sessionName: 'endurance-session',
  harness: testHarnessIdentity(),
  collectors: testCollectorPins(),
  plan: EnduranceActionPlan(
    seed: 72813,
    algorithm: 'fixed_cycle_v1',
    actions:
        actions ??
        <EnduranceActionSpec>[
          EnduranceActionSpec(
            actionId: 'inspect-home',
            arguments: const <String>['inspect', '--brief'],
            mutating: false,
            requiresProgress: false,
            timeoutMs: 1000,
          ),
          EnduranceActionSpec(
            actionId: 'tap-next',
            arguments: const <String>['tap', 'btn.next'],
            mutating: true,
            requiresProgress: true,
            timeoutMs: 1000,
          ),
        ],
  ),
  limits: EnduranceLimits(
    minimumDurationMs: minimumDurationMs,
    minimumActions: minimumActions,
    maximumDurationMs: maximumDurationMs,
    maximumActions: maximumActions,
    maximumConsecutiveNoProgress: maximumNoProgress,
    maximumPositiveRssGrowthBytes: maximumGrowthBytes,
    maximumTailSlopeBytesPerAction: maximumSlopeBytesPerAction,
    memoryWindowSamples: 3,
    harnessHookTimeoutMs: 1000,
    maximumCommandOutputBytes: 1024 * 1024,
    maximumArchiveBytes: 16 * 1024 * 1024,
  ),
);

EnduranceHarnessIdentity testHarnessIdentity() => EnduranceHarnessIdentity(
  controllerId: 'test-controller',
  controllerVersion: '1.0.0-test',
  controllerBuildSha256: 'c' * 64,
  setupFixtureSha256: 'd' * 64,
  teardownFixtureSha256: 'e' * 64,
);

EnduranceCollectorPins testCollectorPins() => EnduranceCollectorPins(
  cpu: EnduranceCollectorPin(
    source: 'test-profiler',
    method: 'test-cpu-window',
    collectorVersion: '1.0.0-test',
    target: 'scout-process',
  ),
  memory: EnduranceCollectorPin(
    source: 'test-profiler',
    method: 'test-rss',
    collectorVersion: '1.0.0-test',
    target: 'scout-process',
  ),
  frameTime: EnduranceCollectorPin(
    source: 'test-frame-timing',
    method: 'test-frame-window',
    collectorVersion: '1.0.0-test',
    target: 'fixture-app',
  ),
);

class FakeEnduranceClock implements EnduranceClock {
  FakeEnduranceClock({DateTime? startedAt})
    : _utc = startedAt ?? DateTime.utc(2026, 8, 20),
      _microseconds = 0;

  DateTime _utc;
  int _microseconds;

  @override
  int get monotonicMicroseconds => _microseconds;

  @override
  DateTime get utcNow => _utc;

  void advance(Duration duration) {
    _microseconds += duration.inMicroseconds;
    _utc = _utc.add(duration);
  }

  void regress(Duration duration) {
    _microseconds -= duration.inMicroseconds;
  }
}

typedef ResponseTransform =
    Map<String, Object?> Function(
      int invocation,
      List<String> arguments,
      Map<String, Object?> response,
    );

class FakeEnduranceScoutExecutor implements ScoutCommandExecutor {
  FakeEnduranceScoutExecutor({
    required this.clock,
    this.responseTransform,
    this.cancelAfterInvocation,
    this.cancellation,
  });

  final FakeEnduranceClock clock;
  final ResponseTransform? responseTransform;
  final int? cancelAfterInvocation;
  final MutableEnduranceCancellationSignal? cancellation;
  final List<List<String>> executed = <List<String>>[];
  var _invocation = 0;
  var _stateGeneration = 10;

  @override
  Future<ScoutCommandResult> attach({
    required String vmServiceUri,
    required Duration timeout,
  }) => throw UnimplementedError('The endurance runner does not call attach.');

  @override
  Future<ScoutCommandResult> execute({
    required List<String> arguments,
    required Duration timeout,
  }) async {
    _invocation++;
    executed.add(List<String>.from(arguments));
    clock.advance(const Duration(milliseconds: 7));
    if (cancelAfterInvocation == _invocation) {
      cancellation?.cancel('Deterministic test cancellation.');
    }
    final commandName = _commandName(arguments);
    final mutation = arguments.contains('--idempotency-key');
    if (mutation) _stateGeneration++;
    var response = testScoutResponse(
      commandId: 'command-$_invocation',
      commandName: commandName,
      stateGeneration: _stateGeneration,
      logCursor: _invocation,
      mutation: mutation,
    );
    response =
        responseTransform?.call(_invocation, arguments, response) ?? response;
    final stdout = jsonEncode(response);
    return ScoutCommandResult(
      arguments: List<String>.from(arguments),
      exitCode: response['ok'] == true ? 0 : 1,
      stdout: stdout,
      stderr: '',
      elapsedMs: 7,
      timedOut: false,
      outputTruncated: false,
    );
  }
}

class FakeEnduranceHarnessController implements EnduranceHarnessController {
  FakeEnduranceHarnessController({
    required this.clock,
    EnduranceHarnessIdentity? identity,
    this.freshSetup = true,
    this.cleanTeardown = true,
    this.teardownThrows = false,
    this.probeTransform,
    this.rssValues = const <int>[],
  }) : _identity = identity ?? testHarnessIdentity();

  final FakeEnduranceClock clock;
  final EnduranceHarnessIdentity _identity;
  final bool freshSetup;
  final bool cleanTeardown;
  final bool teardownThrows;
  final EnduranceResourceProbe Function(
    EnduranceProbeRequest request,
    EnduranceResourceProbe probe,
  )?
  probeTransform;
  final List<int> rssValues;
  var setupCalls = 0;
  var probeCalls = 0;
  var teardownCalls = 0;

  EnduranceCorrelation get correlation => EnduranceCorrelation(
    sessionName: 'endurance-session',
    runId: 'run-endurance',
    runtimeInstanceId: 'runtime-endurance',
    processId: 4242,
    fixtureGeneration: 7,
  );

  @override
  EnduranceHarnessIdentity get identity => _identity;

  @override
  Future<EnduranceSetupObservation> setUp(EnduranceConfig config) async {
    setupCalls++;
    clock.advance(const Duration(milliseconds: 5));
    return EnduranceSetupObservation(
      freshSetup: freshSetup,
      correlation: correlation,
      capturedAtUtc: clock.utcNow,
      setupFixtureSha256: config.harness.setupFixtureSha256,
    );
  }

  @override
  Future<EnduranceResourceProbe> probe(EnduranceProbeRequest request) async {
    probeCalls++;
    clock.advance(const Duration(milliseconds: 3));
    final rss = rssValues.isEmpty
        ? 50 * 1024 * 1024
        : rssValues[request.sequence.clamp(0, rssValues.length - 1)];
    MeasurementProvenance provenance(EnduranceCollectorPin pin) =>
        MeasurementProvenance(
          source: pin.source,
          method: pin.method,
          collectorVersion: pin.collectorVersion,
          target: pin.target,
          capturedAtUtc: clock.utcNow,
        );
    final pins = testCollectorPins();
    var result = EnduranceResourceProbe(
      sequence: request.sequence,
      correlation: correlation,
      capturedAtUtc: clock.utcNow,
      progressSignature: sha256Text('progress-${request.sequence}'),
      processAlive: true,
      crashCount: 0,
      crossoverCount: 0,
      deadlockCount: 0,
      blockingSignalCount: 0,
      cpu: CpuObservation(
        idlePercent: 0.2,
        activePercent: 1.5,
        windowMs: 100,
        provenance: provenance(pins.cpu),
      ),
      memory: MemoryObservation(
        processRssBytes: rss,
        incrementalRssBytes: 2 * 1024 * 1024,
        peakRssBytes: rss + 1024,
        provenance: provenance(pins.memory),
      ),
      frameTime: FrameTimeObservation(
        frameCount: 10,
        medianUs: 16000,
        p95Us: 18000,
        provenance: provenance(pins.frameTime),
      ),
    );
    result = probeTransform?.call(request, result) ?? result;
    return result;
  }

  @override
  Future<EnduranceTeardownObservation> tearDown({
    required EnduranceConfig config,
    required EnduranceCorrelation anchor,
  }) async {
    teardownCalls++;
    clock.advance(const Duration(milliseconds: 5));
    if (teardownThrows) throw StateError('injected teardown failure');
    return EnduranceTeardownObservation(
      attempted: true,
      clean: cleanTeardown,
      anchorCorrelation: anchor,
      teardownFixtureSha256: config.harness.teardownFixtureSha256,
      teardownGeneration: anchor.fixtureGeneration + 1,
      capturedAtUtc: clock.utcNow,
    );
  }
}

Map<String, Object?> testScoutResponse({
  required String commandId,
  required String commandName,
  required int stateGeneration,
  required int logCursor,
  required bool mutation,
}) => <String, Object?>{
  'messageType': 'response',
  'ok': true,
  'schemaVersion': 1,
  'protocolVersion': 15,
  'commandId': commandId,
  'cliCommandId': commandId,
  'commandName': commandName,
  'runId': 'run-endurance',
  'runtimeInstanceId': 'runtime-endurance',
  'stateGeneration': stateGeneration,
  'result': <String, Object?>{
    if (mutation) ...<String, Object?>{
      'transport': 'ok',
      'dispatch': 'dispatched',
      'observation': 'changed',
      'postcondition': 'postcondition_not_requested',
      'runtimeHealth': 'runtime_clean',
    },
  },
  'structuredError': null,
  'timings': <String, Object?>{
    'totalMs': 8,
    'status': 'measured',
    'phases': <String, Object?>{
      for (final phase in performancePhaseNames)
        phase: <String, Object?>{'status': 'measured', 'elapsedMs': 1},
    },
  },
  'logCursor': logCursor,
  'payloadBounds': <String, Object?>{
    'maxSerializedBytes': 4194304,
    'maxStringCharacters': 65536,
    'maxCollectionEntries': 1024,
    'maxDepth': 24,
    'truncated': false,
    'truncationCount': 0,
    'safetyDisposition': 'complete',
  },
  'safetyEvidenceStatus': 'complete',
};

String _commandName(List<String> arguments) {
  for (var index = 0; index < arguments.length; index++) {
    final value = arguments[index];
    if (value == '--app' || value == '--idempotency-key') {
      index++;
      continue;
    }
    if (!value.startsWith('--')) return value;
  }
  throw StateError('No Scout command found.');
}
