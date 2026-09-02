import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

part 'cli_batch.dart';
part 'cli_typed_methods.dart';
part 'cli_serve.dart';
part 'cli_models.dart';
part 'cli_session.dart';
part 'cli_temporary_helper.dart';
part 'cli_temporary_helper_storage.dart';
part 'cli_session_recovery.dart';
part 'cli_supervisor.dart';
part 'cli_annotations.dart';
part 'cli_actions.dart';
part 'cli_navigation.dart';
part 'cli_capture.dart';
part 'cli_native_platform.dart';
part 'cli_vm_transport.dart';
part 'cli_evidence.dart';
part 'cli_privacy.dart';
part 'cli_idempotency.dart';
part 'cli_protocol.dart';
part 'cli_response.dart';
part 'cli_operability.dart';
part 'cli_results.dart';
part 'cli_timings.dart';
part 'cli_record.dart';
part 'cli_secret_ingress.dart';
part 'cli_storage.dart';
part 'cli_event_journal.dart';
part 'cli_log_storage.dart';

Map<String, String> _flutterToolEnvironment([
  Map<String, String>? inherited,
]) => <String, String>{
  ...(inherited ?? Platform.environment),
  // Flutter documents this environment variable for non-interactive tooling.
  // Scout never opts the application or its developer into Flutter analytics.
  'FLUTTER_SUPPRESS_ANALYTICS': 'true',
};

class FlutterScoutCli {
  static const String packageVersion = '2.0.0-dev.1';
  static String? _sessionDirectoryOverride;
  static void Function()? debugEventJournalAfterHeadCommitHook;
  static void Function()? debugEventProjectionDiskLoadHook;
  static void Function()? debugRetentionRegistryWriteHook;
  static void Function(String path)? debugLogReadValidationHook;
  String? _activeCommandId;
  String? _activeCommandName;
  Stopwatch? _activeCommandStopwatch;
  int _heartbeatCursor = 0;
  String? _implicitlySelectedSessionName;
  final Set<String> _activeSensitiveValues = <String>{};
  final Map<String, String> _protectedSecretIngress = <String, String>{};
  _SensitiveRedactionMatcher? _sensitiveRedactionMatcherCache;
  int _sensitiveRedactionMatcherBuildCount = 0;
  String? _eventProjectionCacheSession;
  int? _eventProjectionCacheSequence;
  List<Map<String, Object?>>? _eventProjectionCacheRows;

  /// Test-only override for the session registry path, so tests never touch
  /// the real `~/.flutter_scout/registry.json`.
  static String? debugRegistryPathOverride;

  /// Test-only deterministic substitute for `flutter pub get` in temporary
  /// helper transaction tests. Production always leaves this null.
  static Future<ProcessResult> Function(String project)?
  debugTemporaryHelperPubGetOverride;

  /// Test-only crash checkpoint. When set, the temporary-helper transaction
  /// deliberately stops immediately after durably recording this phase.
  static String? debugTemporaryHelperInterruptAfterPhase;

  /// Helper protocol version this CLI is built against. Keep in sync with
  /// `scoutHelperProtocolVersion` in flutter_scout_helper — the helper echoes
  /// its version in every response, and a lower value means the running app
  /// compiled an older helper (typically the git/pub-cache dependency trap
  /// where hot reload silently keeps old code).
  static const int expectedHelperProtocolVersion = 15;

  /// Test-only view of the environment applied to every Flutter tool process.
  Map<String, String> debugFlutterToolEnvironment(
    Map<String, String> inherited,
  ) => _flutterToolEnvironment(inherited);

  /// Test-only view of response protocol diagnostics.
  Map<String, dynamic> debugProtocolDiagnostics(
    String method,
    Map<String, dynamic> result,
  ) => _withProtocolDiagnostics(method, result);

  /// Test-only view of the source compatibility contract used by mutation
  /// preflight. This deliberately describes this checkout, not any published
  /// binary or retained simulator evidence.
  Map<String, Object?> debugProtocolCompatibilityContract() =>
      <String, Object?>{
        'schemaVersion': _scoutCliSchemaVersion,
        'minSupportedProtocolVersion': _scoutCliProtocolMin,
        'maxSupportedProtocolVersion': _scoutCliProtocolMax,
        'requiredHelperMutationCapabilities':
            _requiredMutationCapabilities.toList()..sort(),
      };

  /// Test-only access to the production helper-envelope compatibility gate.
  Map<String, Object?> debugValidateHelperProtocolEnvelope(
    Map<String, dynamic> response, {
    bool requireMutationCapabilities = true,
  }) {
    final issue = _protocolEnvelopeIssue(
      response,
      requireMutationCapabilities: requireMutationCapabilities,
    );
    return <String, Object?>{
      'compatible': issue == null,
      if (issue != null) 'errorCode': issue.$1,
      if (issue != null) 'message': issue.$2,
    };
  }

  /// Test-only view of default compact action output.
  Map<String, dynamic> debugCompactActionResult(Map<String, dynamic> result) =>
      _compactActionResult(result);

  Map<String, dynamic> debugCompactBriefInspect(Map<String, dynamic> result) =>
      _compactBriefInspect(result);

  Map<String, dynamic> debugCompactWhere(Map<String, dynamic> result) =>
      _compactWhere(result);

  /// Test-only deterministic access to the canonical phase closure used by
  /// responses, compact output, evidence, and durable mutation outcomes.
  Map<String, dynamic> debugCanonicalPhaseTimings(
    Map<String, dynamic> result,
  ) => _withCanonicalPhaseTimings(result);

  Map<String, dynamic> debugMergePreflightPhaseTimings(
    Map<String, dynamic> result,
    Object? preflightTimings,
  ) => _withPreflightPhaseTimings(result, preflightTimings);

  Map<String, dynamic> debugMeasureCliPhase(
    Map<String, dynamic> result, {
    required String phase,
    required int elapsedMs,
  }) => _withMeasuredCliPhase(
    result,
    phase: phase,
    elapsedMs: elapsedMs,
    scope: 'deterministic_test_scope',
  );

  Map<String, dynamic> debugMaterializeActionCapture(
    Map<String, dynamic> result,
    String output,
  ) => _materializeActionCapture(result, output);

  Map<String, dynamic> debugAssertActionHasNoErrors(
    Map<String, dynamic> result,
  ) => _assertActionHasNoErrors(result, enabled: true);

  Future<Map<String, dynamic>> debugDurableLocalMutation({
    required String idempotencyKey,
    required String method,
    required Map<String, String> businessParams,
    required Future<Map<String, dynamic>> Function() dispatch,
  }) => _withCallerIdempotencyKey<Map<String, dynamic>>(
    idempotencyKey,
    () => _runDurableLocalMutation(
      method: method,
      businessParams: businessParams,
      dispatch: dispatch,
      classifyDispatch: (result) =>
          result['dispatch']?.toString() ?? 'dispatch_outcome_unknown',
    ),
  );

  Map<String, Object?> debugLaunchTimingFromLines(List<String> lines) {
    final timing = _LaunchTiming(startedAt: DateTime.now());
    for (final line in lines) {
      timing.observeLine(line);
    }
    return timing.toJson();
  }

  /// Test-only access to the repository-scoped launch source identity.
  Future<Map<String, Object?>> debugProjectSourceIdentity(String project) =>
      _projectSourceIdentity(project);

  /// Test-only guard for the iOS post-build VM-service handoff race.
  bool debugShouldAwaitPostBuildVmService({
    required DateTime now,
    required DateTime? buildDoneAt,
  }) => _shouldAwaitPostBuildVmService(now: now, buildDoneAt: buildDoneAt);

  static String debugNamedSessionDirectory(String base, String name) =>
      p.join(base, '.flutter_scout', 'sessions', _safeSessionName(name));

  /// Test-only view of the project-bound named-session routing used by
  /// launch/ensure command preprocessing.
  static String debugCanonicalNamedSessionDirectory(
    String project,
    String name,
  ) => _canonicalNamedSessionDirectory(project, name);

  /// Test-only access to fail-closed duplicate named-session resolution.
  String debugResolveRegisteredSessionDirectory(
    String name,
    String registeredDirectory,
  ) => _resolveRegisteredScoutSession(name, registeredDirectory);

  /// Test-only access to the production registry conflict guard.
  void debugRegisterScoutSession(
    String name,
    String directory, {
    String? project,
  }) => _registerScoutSession(name, directory, project: project);

  Future<Map<String, Object?>> debugPrepareTemporaryHelper({
    required String project,
    required String helperPath,
  }) async {
    final setup = await _prepareTemporaryHelper(
      project: project,
      originalTarget: 'lib/main.dart',
      helperPath: helperPath,
      runId: 'test',
    );
    return setup.toJson();
  }

  Future<Map<String, Object?>> debugCleanupTemporaryHelper(
    Map<String, Object?> setup,
  ) => _cleanupTemporaryHelper(
    _TemporaryHelperSetup(
      project: setup['project']!.toString(),
      targetPath: setup['targetPath']!.toString(),
      lockExisted: setup['lockExisted'] == true,
      lockBackupPath: setup['lockBackupPath']?.toString(),
      transactionRecordPath: setup['transactionRecordPath']?.toString(),
      transactionId: setup['transactionId']?.toString(),
    ),
  );

  /// Test-only entry point for the same project-local startup repair scanner
  /// used by real commands.
  Future<Map<String, Object?>> debugRecoverTemporaryHelperProject(
    String project,
  ) => _recoverTemporaryHelperProject(project, preserveLive: false);

  /// Test-only ownership reconciliation for a reachable VM service.
  Future<bool> debugReconcileReachableSessionOwnership(String vmUri) =>
      _reconcileReachableSessionOwnership(vmUri);

  /// Test-only view of hot-update availability for the current session.
  Future<Map<String, Object?>> debugHotUpdateCapability(String vmUri) =>
      _hotUpdateCapability(vmUri);

  /// Test-only launchd configuration for a supervised Flutter worker.
  String debugLaunchdRunnerPlist({
    required String label,
    required String configFile,
    required String outputFile,
  }) => _launchdRunnerPlist(
    label: label,
    configFile: configFile,
    outputFile: outputFile,
  );

  /// Test-only session-safe VM URI selection from mixed log output.
  String? debugPreferredVmUriFromLogText(String text) =>
      _preferredVmUriFromLogText(text);

  /// Test-only view of Scout-owned runtime log signal classification.
  List<Map<String, Object?>> debugRecentLogSignalsFromLines(
    List<String> lines, {
    int scanLines = 300,
    int max = 8,
  }) => _logSignalMaps(
    _logSignalsFromLines(lines, scanLines: scanLines, max: max),
    phase: 'debug_classification',
  );

  /// Test-only view of the compiler diagnostics used to reject a hot update.
  Map<String, Object?>? debugHotUpdateFailureAcknowledgementFromLines(
    String action,
    List<String> lines,
  ) => _hotUpdateFailureAcknowledgementFromLines(
    action: action,
    rawLines: lines,
    startCursor: 0,
  );

  /// Test-only view of the bounded Flutter-tool acknowledgement policy.
  Duration debugHotUpdateAcknowledgementTimeout(String action) =>
      _hotUpdateAcknowledgementTimeout(action);

  /// Test-only view of the bounded post-update inspection policy.
  Map<String, Duration> debugPostHotUpdateInspectionPolicy() =>
      const <String, Duration>{
        'timeout': _postHotUpdateInspectionTimeout,
        'probeTimeout': _postHotUpdateInspectProbeTimeout,
        'stableTimeout': _postHotUpdateWaitStableTimeout,
      };

  /// Test-only deterministic seam for slow post-update helper responses.
  Future<Map<String, dynamic>?> debugWaitForPostHotUpdateInspection({
    required Duration timeout,
    required Duration probeTimeout,
    required Future<Map<String, dynamic>?> Function(Duration timeout) inspect,
    required Future<void> Function(Duration timeout) waitStable,
    String? previousRuntimeInstanceId,
    bool requireNewRuntime = false,
  }) => _waitForPostHotUpdateInspection(
    timeout: timeout,
    probeTimeout: probeTimeout,
    stableTimeout: const Duration(milliseconds: 15),
    retryDelay: const Duration(milliseconds: 1),
    inspect: inspect,
    waitStable: waitStable,
    previousRuntimeInstanceId: previousRuntimeInstanceId,
    requireNewRuntime: requireNewRuntime,
  );

  /// Test-only view of `logs --summary` classification.
  Map<String, Object?> debugLogSummary(List<String> lines, {int last = 20}) =>
      _summarizeLogLines(lines, last: last);

  String debugRedactLogText(String value) => _redactSensitiveLogText(value);

  /// Test-only source-redaction surface. Production writes go through the
  /// same [_recordAction] sink.
  void debugRecordAction(Map<String, Object?> action) => _recordAction(action);

  /// Test-only view of the exact serialization guard used for command output,
  /// diagnostics, and events.
  Object? debugSanitizeSerialization(
    Object? value, {
    Iterable<String> sensitiveValues = const <String>[],
  }) {
    final previous = Set<String>.of(_activeSensitiveValues);
    _activeSensitiveValues
      ..clear()
      ..addAll(sensitiveValues.where((value) => value.isNotEmpty));
    try {
      return _sanitizeForSerialization(value);
    } finally {
      _activeSensitiveValues
        ..clear()
        ..addAll(previous);
    }
  }

  /// Test-only counter proving repeated scalar redaction reuses the compiled
  /// exact/encoded secret matcher until the active secret set changes.
  int get debugSensitiveRedactionMatcherBuildCount =>
      _sensitiveRedactionMatcherBuildCount;

  /// Test-only view of the additive machine-readable CLI response envelope.
  Map<String, Object?> debugCliResponseEnvelope(
    Object? value, {
    bool? success,
  }) => _cliResponseEnvelope(value, success: success);

  /// Test-only view of the exact persistent `/health` response without
  /// opening a socket. Production uses the same bounded payload builder.
  Future<Map<String, Object?>> debugPersistentHealthResponse({
    int port = 17341,
  }) async => _cliResponseEnvelope(
    await _persistentHealthPayload(port),
    commandName: 'health',
  );

  /// Test-only deterministic heartbeat shape. Production progress uses the
  /// same builder, with a process-local monotonic heartbeat cursor.
  Map<String, Object?> debugCliHeartbeatEnvelope({
    required String stage,
    required int elapsedMs,
    String? commandId,
    String? runId,
    String? runtimeInstanceId,
    int? stateGeneration,
    Map<String, Object?> progress = const <String, Object?>{},
  }) => _cliHeartbeatEnvelope(
    stage,
    elapsedMs: elapsedMs,
    heartbeatCursor: 1,
    commandId: commandId,
    runId: runId,
    runtimeInstanceId: runtimeInstanceId,
    stateGeneration: stateGeneration,
    progress: progress,
  );

  /// Test-only proof that stored placeholders become VM parameters only when
  /// the caller explicitly supplies their runtime variables.
  Map<String, String> debugResolveRecordedAction(
    Map<String, Object?> action,
    Map<String, String> variables,
  ) => _recordCallParams(_redactRecordedAction(action), variables);

  /// Test-only launch spec. It deliberately returns the URI-file path and
  /// child argv separately so a regression can inspect the process surface.
  Map<String, Object?> debugVmLogListenerLaunchSpec({
    required String vmUri,
    required String logFile,
    required int ownerPid,
  }) => _prepareVmLogListenerLaunchSpec(
    vmUri: vmUri,
    logFile: logFile,
    ownerPid: ownerPid,
  ).toJson();

  /// Test-only view of the exact user define arguments persisted for the
  /// detached worker and forwarded to Flutter. Protected file contents must
  /// never be present in this surface.
  List<String> debugDartDefineFlutterArgs({
    Iterable<String> inline = const <String>[],
    Iterable<String> files = const <String>[],
  }) => _prepareDartDefineFlutterArgs(inline: inline, files: files);

  /// Test-only storage boundary probes used by adversarial filesystem tests.
  void debugEnsurePrivateStorage() => _ensureSessionDir();

  void debugAtomicSessionWrite(String relativePath, String value) {
    final target = p.join(_sessionDir.path, relativePath);
    _writePrivateSessionString(target, value);
  }

  void debugWriteAnnotationManifest(List<Map<String, Object?>> annotations) =>
      _writeAnnotationManifest(annotations);

  void debugWriteAnnotationCrop(String path, List<int> bytes) =>
      _writePrivateArtifactBytes(path, bytes);

  void debugWriteServePortFile(String path, int port) =>
      _writeServePortFile(path, port);

  void debugWriteServeCredentialFile(String path, String credential) =>
      _writeServeCredentialFile(path, credential);

  int debugAppendEventStrict(Map<String, Object?> event) =>
      _appendEventStrict(event);

  void debugUpdateEventStrict({
    required int cursor,
    required String commandId,
    required Map<String, Object?> updates,
  }) => _updateEventStrict(
    cursor: cursor,
    commandId: commandId,
    updates: updates,
  );

  List<Map<String, Object?>> debugReadEventJournal() =>
      _readEventRows(File(_eventsFile));

  Map<String, Object?> debugReadScoutLog({
    int? sinceCursor,
    int maxBytes = _maxScoutLogTailBytes,
  }) {
    final chunk = _readLogChunk(
      File(_logFile),
      sinceCursor: sinceCursor,
      maxBytes: maxBytes,
    );
    return <String, Object?>{
      'path': _logFile,
      'lines': chunk.lines,
      'startCursor': chunk.startCursor,
      'endCursor': chunk.endCursor,
      'observedFileLength': chunk.observedFileLength,
      'bytesRead': chunk.bytesRead,
      'pendingBytes': chunk.pendingBytes,
      'truncated': chunk.truncated,
    };
  }

  String get debugResolvedScoutLogFile => _logFile;

  Map<String, dynamic> debugCommitActionEvidence({
    required String method,
    required Map<String, dynamic> result,
    Map<String, Object?>? record,
  }) => _commitActionEvidence(method: method, result: result, record: record);

  void debugWritePrivateArtifact(
    String path,
    List<int> bytes, {
    String retention = 'session',
  }) {
    _writePrivateArtifactBytes(path, bytes);
    _writePrivateArtifactMetadata(path, retention);
  }

  // Batch-mode connection cache: one WebSocket serves every step of a batch
  // instead of connect/dispose per command. See cli_batch.dart.
  /// Test-only native-process seam. Production always leaves this null.
  static NativeProcessDebugRunner? debugNativeProcessRunner;

  /// Test-only notification immediately before an approved VM-service
  /// connection. Rejected URI candidates must never reach this observer.
  static void Function(String normalizedUri)? debugVmServiceConnectObserver;

  bool _reuseVmConnection = false;
  VmService? _cachedVmService;
  String? _cachedVmUri;

  // Batch mode keeps normal action methods intact while collecting their
  // compact results into one final timeline instead of printing a large JSON
  // document per step.
  bool _suppressActionOutput = false;
  final List<Map<String, dynamic>> _suppressedActionResults = [];

  /// Splits a batch script into commands on `;` and newlines, honoring
  /// single/double quotes so quoted arguments can contain separators.
  static List<String> splitBatchScript(String script) {
    final commands = <String>[];
    final current = StringBuffer();
    var inSingle = false;
    var inDouble = false;
    for (var i = 0; i < script.length; i++) {
      final char = script[i];
      if (inSingle) {
        current.write(char);
        if (char == "'") inSingle = false;
        continue;
      }
      if (inDouble) {
        current.write(char);
        if (char == '"') inDouble = false;
        continue;
      }
      if (char == "'") {
        inSingle = true;
        current.write(char);
        continue;
      }
      if (char == '"') {
        inDouble = true;
        current.write(char);
        continue;
      }
      if (char == ';' || char == '\n') {
        final command = current.toString().trim();
        if (command.isNotEmpty && !command.startsWith('#')) {
          commands.add(command);
        }
        current.clear();
        continue;
      }
      current.write(char);
    }
    final tail = current.toString().trim();
    if (tail.isNotEmpty && !tail.startsWith('#')) commands.add(tail);
    return commands;
  }

  /// Quotes one argument for a batch script so splitCommandLine reproduces
  /// it exactly: bare when safe, single-quoted when possible, double-quoted
  /// with escapes otherwise.
  static String quoteBatchArg(String value) {
    if (value.isEmpty) return "''";
    if (RegExp(r'^[A-Za-z0-9._\-=/:@,+]+$').hasMatch(value)) return value;
    if (!value.contains("'") && !value.contains('\n') && !value.contains(';')) {
      return "'$value'";
    }
    final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }

  /// Shell-like argv splitter for one batch command: whitespace separates,
  /// single quotes are literal, double quotes allow \" and \\ escapes.
  static List<String> splitCommandLine(String line) {
    final args = <String>[];
    final current = StringBuffer();
    var inSingle = false;
    var inDouble = false;
    var hasToken = false;
    for (var i = 0; i < line.length; i++) {
      final char = line[i];
      if (inSingle) {
        if (char == "'") {
          inSingle = false;
        } else {
          current.write(char);
        }
        continue;
      }
      if (inDouble) {
        if (char == '"') {
          inDouble = false;
        } else if (char == r'\' &&
            i + 1 < line.length &&
            (line[i + 1] == '"' || line[i + 1] == r'\')) {
          current.write(line[++i]);
        } else {
          current.write(char);
        }
        continue;
      }
      if (char == "'") {
        inSingle = true;
        hasToken = true;
        continue;
      }
      if (char == '"') {
        inDouble = true;
        hasToken = true;
        continue;
      }
      if (char == r'\' && i + 1 < line.length) {
        current.write(line[++i]);
        hasToken = true;
        continue;
      }
      if (char == ' ' || char == '\t') {
        if (hasToken || current.isNotEmpty) {
          args.add(current.toString());
          current.clear();
          hasToken = false;
        }
        continue;
      }
      current.write(char);
      hasToken = true;
    }
    if (hasToken || current.isNotEmpty) args.add(current.toString());
    return args;
  }

  Future<int> run(List<String> args) async {
    if (args.isEmpty || args.first == '--help' || args.first == '-h') {
      _printUsage();
      return 0;
    }
    if (args.first == '--version' || args.first == '-V') {
      return _version();
    }
    if (args.any((arg) => arg == '--help' || arg == '-h')) {
      String? command;
      for (var i = 0; i < args.length; i++) {
        final arg = args[i];
        if (arg == '--app' || arg == '--idempotency-key') {
          i++;
          continue;
        }
        if (arg.startsWith('--app=') ||
            arg.startsWith('--idempotency-key=') ||
            arg == '--help' ||
            arg == '-h') {
          continue;
        }
        if (!arg.startsWith('-')) {
          command = arg;
          break;
        }
      }
      _printUsage(command: command);
      return 0;
    }

    final previousSessionDirectory = _sessionDirectoryOverride;
    final previousCommandId = _activeCommandId;
    final previousCommandName = _activeCommandName;
    final previousCommandStopwatch = _activeCommandStopwatch;
    final previousHeartbeatCursor = _heartbeatCursor;
    final previousImplicitSessionName = _implicitlySelectedSessionName;
    final previousCallerIdempotencyKey = _activeCallerIdempotencyKey;
    final previousIdempotencyKeyWasGenerated =
        _activeIdempotencyKeyWasGenerated;
    final previousSensitiveValues = Set<String>.of(_activeSensitiveValues);
    final previousProtectedSecretIngress = Map<String, String>.of(
      _protectedSecretIngress,
    );
    final commandStartedAt = DateTime.now().toUtc();
    final commandStopwatch = Stopwatch()..start();
    final commandId =
        '${commandStartedAt.microsecondsSinceEpoch.toRadixString(36)}-$pid';
    _activeCommandId = commandId;
    _activeCommandStopwatch = commandStopwatch;
    _heartbeatCursor = 0;
    int? exitCode;
    int? commandEventCursor;
    var handledByProxy = false;
    Timer? longOperationHeartbeat;

    // Global `--app <name>`: run this command against the named session
    // (registered by launch/ensure --name) from anywhere — no cd dance.
    var effectiveArgs = args;
    String? appName;
    for (var i = 0; i < effectiveArgs.length; i++) {
      final arg = effectiveArgs[i];
      if (arg == '--app' && i + 1 < effectiveArgs.length) {
        appName = effectiveArgs[i + 1];
        effectiveArgs = [
          ...effectiveArgs.take(i),
          ...effectiveArgs.skip(i + 2),
        ];
        break;
      }
      if (arg.startsWith('--app=')) {
        appName = arg.substring('--app='.length);
        effectiveArgs = [
          ...effectiveArgs.take(i),
          ...effectiveArgs.skip(i + 1),
        ];
        break;
      }
    }
    try {
      final idempotency = _extractIdempotencyKey(effectiveArgs);
      effectiveArgs = idempotency.args;
      _activeCallerIdempotencyKey = idempotency.key;
    } on ScoutCliException catch (error) {
      _writeStructuredError(error.code, error.message);
      _activeCommandId = previousCommandId;
      _activeCommandName = previousCommandName;
      _activeCommandStopwatch = previousCommandStopwatch;
      _heartbeatCursor = previousHeartbeatCursor;
      _activeCallerIdempotencyKey = previousCallerIdempotencyKey;
      if (previousCallerIdempotencyKey != null &&
          previousIdempotencyKeyWasGenerated) {
        _adoptGeneratedIdempotencyKey(previousCallerIdempotencyKey);
      }
      return 1;
    }
    if (effectiveArgs.isEmpty) {
      _writeStructuredError(
        'missing_command',
        'A command is required after global options.',
      );
      _activeCommandId = previousCommandId;
      _activeCommandName = previousCommandName;
      _activeCommandStopwatch = previousCommandStopwatch;
      _heartbeatCursor = previousHeartbeatCursor;
      _activeCallerIdempotencyKey = previousCallerIdempotencyKey;
      if (previousCallerIdempotencyKey != null &&
          previousIdempotencyKeyWasGenerated) {
        _adoptGeneratedIdempotencyKey(previousCallerIdempotencyKey);
      }
      return 1;
    }
    _activeCommandName = effectiveArgs.isEmpty ? null : effectiveArgs.first;
    if (appName != null && appName.isNotEmpty) {
      late final Map<String, String> registry;
      try {
        registry = _readScoutRegistry();
      } on ScoutCliException catch (error) {
        _writeStructuredError(
          error.code,
          error.message,
          details: error.details,
          additional: error.additional,
        );
        _activeCommandId = previousCommandId;
        _activeCommandName = previousCommandName;
        _activeCommandStopwatch = previousCommandStopwatch;
        _heartbeatCursor = previousHeartbeatCursor;
        _activeCallerIdempotencyKey = previousCallerIdempotencyKey;
        if (previousCallerIdempotencyKey != null &&
            previousIdempotencyKeyWasGenerated) {
          _adoptGeneratedIdempotencyKey(previousCallerIdempotencyKey);
        }
        return 1;
      }
      var directory = registry[appName];
      if (directory != null) {
        try {
          directory = _resolveRegisteredScoutSession(appName, directory);
        } on ScoutCliException catch (error) {
          _writeStructuredError(
            error.code,
            error.message,
            details: error.details,
            additional: error.additional,
          );
          _activeCommandId = previousCommandId;
          _activeCommandName = previousCommandName;
          _activeCommandStopwatch = previousCommandStopwatch;
          _heartbeatCursor = previousHeartbeatCursor;
          _activeCallerIdempotencyKey = previousCallerIdempotencyKey;
          if (previousCallerIdempotencyKey != null &&
              previousIdempotencyKeyWasGenerated) {
            _adoptGeneratedIdempotencyKey(previousCallerIdempotencyKey);
          }
          return 1;
        }
      }
      if (directory == null || !Directory(directory).existsSync()) {
        _writeStructuredError(
          'session_not_registered',
          'No registered session named `$appName`'
              '${directory != null ? ' (directory `$directory` is gone)' : ''}. '
              'Sessions register on launch/ensure --name.',
          additional: <String, Object?>{
            'knownSessions': registry.keys.toList(growable: false),
          },
        );
        _activeCommandId = previousCommandId;
        _activeCommandName = previousCommandName;
        _activeCommandStopwatch = previousCommandStopwatch;
        _heartbeatCursor = previousHeartbeatCursor;
        _activeCallerIdempotencyKey = previousCallerIdempotencyKey;
        if (previousCallerIdempotencyKey != null &&
            previousIdempotencyKeyWasGenerated) {
          _adoptGeneratedIdempotencyKey(previousCallerIdempotencyKey);
        }
        return 1;
      }
      final registered = p.normalize(p.absolute(directory));
      _sessionDirectoryOverride =
          p.basename(registered) == '.flutter_scout' ||
              p.basename(p.dirname(registered)) == 'sessions'
          ? registered
          : p.join(registered, '.flutter_scout');
    }

    final command = effectiveArgs.first;
    final rest = effectiveArgs.skip(1).toList(growable: false);
    final requestedName = _optionValue(rest, 'name');
    String? pendingSessionRegistration;
    String? pendingSessionProject;
    if (appName == null &&
        (command == 'launch' || command == 'ensure') &&
        requestedName != null &&
        requestedName.isNotEmpty) {
      pendingSessionProject = _canonicalProjectDirectory(
        _optionValue(rest, 'project') ?? Directory.current.path,
      );
      if (Directory(pendingSessionProject).existsSync()) {
        _sessionDirectoryOverride = _canonicalNamedSessionDirectory(
          pendingSessionProject,
          requestedName,
        );
        pendingSessionRegistration = requestedName;
      }
    }
    _activeSensitiveValues.clear();
    _protectedSecretIngress.clear();
    try {
      _preloadProtectedSecretIngress(command, rest);
      _registerSensitiveCommandArgs(command, rest);
      _warnAboutLegacySecretIngress(command, rest);
      if (!_infrastructureCommands.contains(command)) {
        longOperationHeartbeat = Timer.periodic(const Duration(seconds: 5), (
          _,
        ) {
          try {
            _writeHeartbeat('command_running', <String, Object?>{
              'command': command,
            });
          } catch (_) {
            // A diagnostic heartbeat must never change command behavior.
          }
        });
      }
      final infrastructureCommand = _infrastructureCommands.contains(command);
      if (!infrastructureCommand) {
        _selectImplicitNamedSession(command);
        await _recoverPendingTemporaryHelpersAtCommandStart(command, rest);
        _runRetentionCleanupAtCommandStart(command, rest);
        if (command == 'stop' && rest.contains('--clear-session')) {
          _ensurePrivateDirectory(
            _sessionDir.path,
            boundary: _sessionManagedBoundary(),
          );
        } else {
          _ensureSessionDir();
        }
        if (pendingSessionRegistration != null) {
          _registerScoutSession(
            pendingSessionRegistration,
            _sessionDirectoryOverride!,
            project: pendingSessionProject,
          );
        }
      }
      if (!_reuseVmConnection &&
          _commandsEligibleForServeProxy.contains(command) &&
          !_usesProtectedStdin(command, rest)) {
        final proxied = await _tryProxyToActiveServe(effectiveArgs);
        if (proxied != null) {
          handledByProxy = true;
          exitCode = proxied;
          return proxied;
        }
      }
      final clearsSession =
          command == 'stop' && rest.contains('--clear-session');
      if (!_infrastructureCommands.contains(command) && !clearsSession) {
        // Reserve one durable event before dispatch. A crash or full-disk
        // failure can then leave an explicit `started` row, never erase the
        // fact that a command may have reached the app. Completion updates
        // this exact cursor rather than appending a second command record.
        commandEventCursor = _appendEventStrict({
          'schemaVersion': 1,
          'type': 'command',
          'status': 'started',
          'evidenceStatus': 'reserved_before_dispatch',
          'commandId': commandId,
          'startedAt': commandStartedAt.toIso8601String(),
          'command': command,
          'args': _redactedCommandArgs(command, rest),
          'runId': ?_currentRunIdFromSession(),
          'session': ?_readSessionMeta()?['name'],
          'transport': _reuseVmConnection ? 'persistent' : 'process',
          'timings': _lifecycleReservationTimings(),
        });
      }
      exitCode = await switch (command) {
        'launch' => _launch(rest),
        'ensure' => _ensure(rest),
        'attach' => _attach(rest),
        'status' => _status(),
        'doctor' => _doctor(rest),
        'stop' => _stop(rest),
        'cleanup' => _stop(rest),
        'inspect' => _inspect(rest),
        'where' => _where(rest),
        'locate' => _locate(rest),
        'reveal' => _reveal(rest),
        'annotations' => _annotations(rest),
        'bounds' => _bounds(rest),
        'tap' => _tap(rest),
        'tap-text' => _tapText(rest),
        'long-press' => _longPress(rest),
        'input' => _input(rest),
        'fill' => _fill(rest),
        'scroll' => _scroll(rest),
        'scroll-to' => _scrollTo(rest),
        'swipe' => _swipe(rest),
        'drag-start' => _dragStart(rest),
        'drag-move' => _dragMove(rest),
        'drag-end' => _dragEnd(rest),
        'drag-cancel' => _dragCancel(rest),
        'drag-status' => _dragStatus(rest),
        'back' => _back(rest),
        'dismiss' => _dismiss(rest),
        'wait' => _wait(rest),
        'wait-for' => _waitFor(rest),
        'health' => _health(rest),
        'batch' => _batch(rest),
        'export-batch' => _exportBatch(rest),
        'serve' => _serve(rest),
        'explore' => _explore(rest),
        'devices' => _devices(rest),
        'apps' => _apps(rest),
        'reload' => _reload(rest),
        'restart' => _restart(rest),
        'deeplink' => _deeplink(rest),
        'logs' => _logs(rest),
        'vm-log-listener' => _vmLogListener(rest),
        'flutter-run-worker' => _flutterRunWorker(rest),
        'screenshot' => _screenshot(rest),
        'crop' => _crop(rest),
        'evidence' => _evidence(rest),
        'replay' => _replay(rest),
        'record' => _record(rest),
        'version' => _version(),
        'help' => _help(rest),
        _ => _unknown(command),
      };
    } on ScoutCliException catch (error) {
      exitCode = 1;
      _writeStructuredError(
        error.code,
        error.message,
        details: error.details,
        additional: error.additional,
      );
    } catch (error) {
      exitCode = 1;
      _writeStructuredError('unexpected_error', error.toString());
    } finally {
      longOperationHeartbeat?.cancel();
      commandStopwatch.stop();
      if (!handledByProxy && commandEventCursor != null) {
        try {
          _updateEventStrict(
            cursor: commandEventCursor,
            commandId: commandId,
            updates: {
              'status': 'completed',
              'evidenceStatus': 'complete',
              'finishedAt': DateTime.now().toUtc().toIso8601String(),
              'durationMs': commandStopwatch.elapsedMilliseconds,
              'exitCode': exitCode ?? 1,
              'runId': ?_currentRunIdFromSession(),
              'session': ?_readSessionMeta()?['name'],
            },
          );
        } catch (error) {
          exitCode = 1;
          _writeStructuredError(
            'command_evidence_completion_failed',
            'The command may have completed, but Scout could not '
                'commit its reserved evidence row: ${error.toString()}',
            additional: <String, Object?>{
              'commandId': commandId,
              'eventCursor': commandEventCursor,
              'evidenceStatus': 'reserved_row_incomplete',
            },
          );
        }
      }
      _activeCommandId = previousCommandId;
      _activeCommandName = previousCommandName;
      _activeCommandStopwatch = previousCommandStopwatch;
      _heartbeatCursor = previousHeartbeatCursor;
      _implicitlySelectedSessionName = previousImplicitSessionName;
      _sessionDirectoryOverride = previousSessionDirectory;
      _activeCallerIdempotencyKey = previousCallerIdempotencyKey;
      if (previousCallerIdempotencyKey != null &&
          previousIdempotencyKeyWasGenerated) {
        _adoptGeneratedIdempotencyKey(previousCallerIdempotencyKey);
      }
      _activeSensitiveValues
        ..clear()
        ..addAll(previousSensitiveValues);
      _protectedSecretIngress
        ..clear()
        ..addAll(previousProtectedSecretIngress);
    }
    return exitCode ?? 1;
  }

  static const Set<String> _infrastructureCommands = {
    'vm-log-listener',
    'flutter-run-worker',
  };

  List<String> _redactedCommandArgs(String command, List<String> args) {
    if (command == 'batch') {
      return <String>[
        for (final arg in args)
          arg.startsWith('--') && !arg.contains('=') ? arg : '[REDACTED]',
      ];
    }
    final redacted = <String>[];
    var redactNext = false;
    for (final arg in args) {
      if (redactNext) {
        redacted.add('[REDACTED]');
        redactNext = false;
        continue;
      }
      final lower = arg.toLowerCase();
      if (lower == '--json' ||
          lower == '--file' ||
          lower == '--var' ||
          lower == '--var-file' ||
          lower == '--debug-url' ||
          lower == '--debug-url-file' ||
          lower == '--url-file' ||
          lower == '--dart-define' ||
          lower == '--dart-define-from-file') {
        redacted.add(arg);
        redactNext = true;
        continue;
      }
      if (lower.startsWith('--json=') ||
          lower.startsWith('--file=') ||
          lower.startsWith('--var=') ||
          lower.startsWith('--var-file=') ||
          lower.startsWith('--debug-url=') ||
          lower.startsWith('--debug-url-file=') ||
          lower.startsWith('--url-file=') ||
          lower.startsWith('--dart-define=') ||
          lower.startsWith('--dart-define-from-file=')) {
        redacted.add('${arg.split('=').first}=[REDACTED]');
        continue;
      }
      redacted.add(_redactSensitiveLogText(arg));
    }
    if (command == 'input') {
      const optionValues = {
        '--target',
        '--file',
        '--expect-text',
        '--expect-gone',
        '--expect-target',
        '--expect-selected',
        '--expect-screen',
        '--expect-view',
        '--expect-field',
        '--expect-timeout',
        '--capture',
        '--expect-log',
        '--reject-log',
      };
      for (var index = 0; index < redacted.length; index++) {
        final isOptionValue =
            index > 0 && optionValues.contains(args[index - 1].toLowerCase());
        if (!redacted[index].startsWith('-') && !isOptionValue) {
          redacted[index] = '[REDACTED]';
        }
      }
    }
    if (command == 'deeplink') {
      const optionValues = <String>{'--url-file'};
      for (var index = 0; index < redacted.length; index++) {
        final isOptionValue =
            index > 0 && optionValues.contains(args[index - 1].toLowerCase());
        if (!redacted[index].startsWith('-') && !isOptionValue) {
          redacted[index] = '[REDACTED]';
        }
      }
    }
    return redacted;
  }

  int _appendEvent(Map<String, Object?> event) => _appendEventStrict(event);

  int _appendEventStrict(Map<String, Object?> event) =>
      _appendSegmentedEventStrict(event);

  void _updateEventStrict({
    required int cursor,
    required String commandId,
    required Map<String, Object?> updates,
  }) => _updateSegmentedEventStrict(
    cursor: cursor,
    commandId: commandId,
    updates: updates,
  );

  List<Map<String, Object?>> _readEventRows(File file) =>
      _readSegmentedEventRows(legacyProjection: file);

  String? _optionValue(List<String> args, String name) {
    for (var index = 0; index < args.length; index++) {
      final value = args[index];
      if (value == '--$name' && index + 1 < args.length) {
        return args[index + 1];
      }
      if (value.startsWith('--$name=')) {
        return value.substring(name.length + 3);
      }
    }
    return null;
  }

  bool _inspectChanged(
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
  ) {
    if (before == null || after == null) return before != after;
    return jsonEncode(_compactSummary(before)) !=
        jsonEncode(_compactSummary(after));
  }

  Map<String, Object?> _inspectDelta(
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
  ) {
    if (before == null || after == null) {
      return {'available': false};
    }
    final beforeText = _stringSet(before['visibleText']);
    final afterText = _stringSet(after['visibleText']);
    final beforeFields = _stringKeySet(before['fieldValues']);
    final afterFields = _stringKeySet(after['fieldValues']);
    return {
      'screenChanged': before['screen'] != after['screen'],
      'newText': afterText.difference(beforeText).toList(growable: false),
      'removedText': beforeText.difference(afterText).toList(growable: false),
      'newFields': afterFields.difference(beforeFields).toList(growable: false),
      'removedFields': beforeFields
          .difference(afterFields)
          .toList(growable: false),
    };
  }

  Set<String> _stringSet(Object? value) {
    if (value is! List) return const <String>{};
    return value.map((item) => item.toString()).toSet();
  }

  Set<String> _stringKeySet(Object? value) {
    if (value is! Map) return const <String>{};
    return value.keys.map((item) => item.toString()).toSet();
  }

  bool _looksLikeMissingScoutExtension(RPCError error) {
    final message = error.message;
    return message.contains('ext.flutter_scout') ||
        message.contains('Unknown service extension') ||
        message.contains('Service extension not found') ||
        error.code == -32601;
  }

  Future<VmService> _connect(String uri) {
    final validated = _validatedVmServiceUri(uri);
    FlutterScoutCli.debugVmServiceConnectObserver?.call(validated.normalized);
    return vmServiceConnectUri(
      validated.normalized,
    ).timeout(const Duration(seconds: 5));
  }

  Future<_AttachDiscovery> _discoverAttachVmUri({
    required String? explicit,
    required String? device,
  }) async {
    if (explicit != null && explicit.isNotEmpty) {
      final uri = _normalizeVmUri(explicit);
      final validation = await _validateVmUri(uri);
      if (validation.ok) return _AttachDiscovery(uri: uri);
      return _AttachDiscovery(
        reason: 'vm_service_uri_unreachable',
        staleUri: uri,
        staleCleared: false,
      );
    }

    final fromLogs = await _discoverCurrentVmUri(device: device);
    if (fromLogs != null && fromLogs.uri.isNotEmpty) {
      final uri = _normalizeVmUri(fromLogs.uri);
      final validation = await _validateVmUri(uri);
      if (validation.ok) return _AttachDiscovery(uri: uri);
    }

    final fromSession = _readVmUri();
    if (fromSession != null && fromSession.isNotEmpty) {
      final uri = _normalizeVmUri(fromSession);
      final validation = await _validateVmUri(uri);
      if (validation.ok) return _AttachDiscovery(uri: uri);
      _clearVmUriFile();
      return _AttachDiscovery(
        reason: 'stale_vm_service_uri',
        staleUri: uri,
        staleCleared: true,
      );
    }

    return const _AttachDiscovery(reason: 'vm_service_uri_not_found');
  }

  Future<_VmUriValidation> _validateVmUri(String uri) async {
    VmService? service;
    try {
      service = await _connect(uri);
      // A dead app can leave a DDS/VM socket that still completes the WebSocket
      // handshake but never answers RPCs. Require a real response so discovery
      // never hands back a zombie URI that would later hang a readiness check.
      await service.getVM().timeout(const Duration(seconds: 5));
      return const _VmUriValidation(ok: true);
    } catch (error) {
      return _VmUriValidation(ok: false, error: error.toString());
    } finally {
      await service?.dispose();
    }
  }

  Future<_ScoutReady> _checkScoutReady(String uri) async {
    try {
      final service = await _connect(uri);
      try {
        final isolateId = await _findMainIsolate(service);
        final isolate = await service
            .getIsolate(isolateId)
            .timeout(const Duration(seconds: 5));
        final extensions = isolate.extensionRPCs ?? const <String>[];
        if (extensions.contains('ext.flutter_scout.inspect')) {
          return const _ScoutReady(ready: true);
        }
        return const _ScoutReady(
          ready: false,
          reason: 'helper_extension_missing',
          expected: 'FlutterScoutBinding.ensureInitialized()',
        );
      } finally {
        await service.dispose();
      }
    } catch (error) {
      return _ScoutReady(
        ready: false,
        reason: 'helper_extension_check_failed',
        expected: 'FlutterScoutBinding.ensureInitialized()',
        detail: error.toString(),
      );
    }
  }

  Future<_ScoutReady> _waitScoutReady(
    String uri, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final deadline = DateTime.now().add(timeout);
    _ScoutReady? last;
    while (DateTime.now().isBefore(deadline)) {
      // Bound each attempt by the remaining budget. The deadline is only
      // re-checked between attempts, so an unbounded attempt (e.g. an RPC to an
      // unresponsive VM service) would otherwise defeat it and hang forever.
      final remaining = deadline.difference(DateTime.now());
      final attemptBudget = remaining < const Duration(seconds: 1)
          ? const Duration(seconds: 1)
          : remaining;
      try {
        last = await _checkScoutReady(uri).timeout(attemptBudget);
      } on TimeoutException {
        return const _ScoutReady(
          ready: false,
          reason: 'helper_extension_check_timeout',
          expected: 'FlutterScoutBinding.ensureInitialized()',
        );
      }
      if (last.ready) return last;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return last ??
        const _ScoutReady(
          ready: false,
          reason: 'helper_extension_check_timeout',
          expected: 'FlutterScoutBinding.ensureInitialized()',
        );
  }

  Future<_MacosWindowTarget?> _macosWindowTarget() async {
    if (!await _isMacosScreenshotSession()) return null;
    final vmUri = _readVmUri();
    final listenerPid = vmUri == null
        ? null
        : await _pidForListeningVmPort(vmUri);
    final launchPid = _readPid();
    final pids = <int>[
      ?listenerPid,
      ...await _descendantPids(listenerPid),
      ?launchPid,
      ...await _descendantPids(launchPid),
    ];
    final seen = <int>{};
    for (final pid in pids) {
      if (!seen.add(pid)) continue;
      final target = await _findMacosWindowForPid(pid);
      if (target != null) return target;
    }
    return null;
  }

  Future<bool> _isMacosScreenshotSession() async {
    final device = _readDevice();
    final deviceInfo = _readDeviceInfo();
    final platform = deviceInfo?['platform']?.toString().toLowerCase();
    final category = deviceInfo?['category']?.toString().toLowerCase();
    final emulator = deviceInfo?['emulator'] == true;
    final isRecordedMacos =
        device == 'macos' ||
        platform == 'macos' ||
        category == 'desktop' ||
        emulator == false;
    final vmUri = _readVmUri();
    final listenerPid = vmUri == null
        ? null
        : await _pidForListeningVmPort(vmUri);
    final command = listenerPid == null
        ? null
        : await _processCommand(listenerPid);
    final looksLikeMacosApp =
        command != null && command.contains('.app/Contents/MacOS/');
    return isRecordedMacos || looksLikeMacosApp;
  }

  Future<_MacosWindowTarget?> _findMacosWindowForPid(int pid) async {
    final script = r'''
import Foundation
import CoreGraphics

let pid = Int(CommandLine.arguments[1])!
let options = CGWindowListOption(arrayLiteral: .optionAll, .excludeDesktopElements)
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
  exit(2)
}

func number(_ value: Any?) -> Double {
  if let value = value as? Double { return value }
  if let value = value as? Int { return Double(value) }
  if let value = value as? CGFloat { return Double(value) }
  if let value = value as? NSNumber { return value.doubleValue }
  return 0
}

var best: [String: Any]?
var bestArea = 0.0
for window in windows {
  guard (window[kCGWindowOwnerPID as String] as? Int) == pid else { continue }
  guard (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
  guard number(window[kCGWindowAlpha as String]) > 0 else { continue }
  guard (window[kCGWindowSharingState as String] as? Int ?? 0) != 0 else { continue }
  guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else { continue }
  let width = number(bounds["Width"])
  let height = number(bounds["Height"])
  guard width >= 80 && height >= 80 else { continue }
  let area = width * height
  if area > bestArea {
    bestArea = area
    best = window
  }
}

guard let window = best else {
  exit(3)
}

let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
let output: [String: Any] = [
  "windowId": window[kCGWindowNumber as String] as? Int ?? 0,
  "pid": pid,
  "ownerName": window[kCGWindowOwnerName as String] as? String ?? "",
  "windowName": window[kCGWindowName as String] as? String ?? "",
  "bounds": [
    number(bounds["X"]),
    number(bounds["Y"]),
    number(bounds["Width"]),
    number(bounds["Height"])
  ]
]
let data = try! JSONSerialization.data(withJSONObject: output)
print(String(data: data, encoding: .utf8)!)
''';
    final tempDirectory = await Directory.systemTemp.createTemp(
      'flutter_scout_window_',
    );
    _ensurePrivateDirectory(tempDirectory.path, boundary: tempDirectory.path);
    final temp = File(p.join(tempDirectory.path, 'window_probe.swift'));
    try {
      _atomicWritePrivateString(
        temp.path,
        script,
        boundary: tempDirectory.path,
      );
      final result = await Process.run('swift', [temp.path, pid.toString()])
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () =>
                ProcessResult(0, 124, '', 'window lookup timed out'),
          );
      if (result.exitCode != 0) return null;
      final decoded = jsonDecode(result.stdout as String);
      if (decoded is! Map<String, dynamic>) return null;
      return _MacosWindowTarget.fromJson(decoded);
    } finally {
      _deletePrivateDirectoryIfExists(
        tempDirectory.path,
        boundary: tempDirectory.path,
      );
    }
  }

  Map<String, Object?> _summarizeLogLines(
    List<String> lines, {
    required int last,
  }) {
    // Register credential-bearing VM URLs before sanitizing any neighboring
    // line. Otherwise an earlier summary field could serialize the raw token
    // before the later URI-bearing line was inspected.
    for (final line in lines) {
      _extractVmUri(line) ?? _extractFlutterToolVmUri(line);
    }
    final sanitizedLines = lines
        .map(_redactActiveSensitiveText)
        .toList(growable: false);
    final important = <String>[];
    final signals = _logSignalsFromLines(
      sanitizedLines,
      scanLines: sanitizedLines.length,
      max: sanitizedLines.length,
    );
    final signalLines = {for (final signal in signals) signal.line};
    var warnings = 0;
    Map<String, Object?>? vmServiceEndpoint;
    for (final line in sanitizedLines) {
      final lower = line.toLowerCase();
      final isSignal = signalLines.contains(line.trim());
      final isWarning =
          RegExp(r'\bwarn(?:ing)?\b', caseSensitive: false).hasMatch(line) &&
          !_isNegatedLogError(lower);
      final uri = _extractVmUri(line) ?? _extractFlutterToolVmUri(line);
      if (isWarning) warnings++;
      if (uri != null) {
        vmServiceEndpoint = _safeVmServiceEndpointIdentity(uri);
      }
      if (isSignal || isWarning || uri != null) {
        important.add(line);
      }
    }
    final limit = last <= 0 ? 20 : last;
    final recentSignals = signals.length > limit
        ? signals.sublist(signals.length - limit)
        : signals;
    return {
      'errors': signals.where((signal) => signal.severity != 'warning').length,
      'warnings': warnings,
      'vmServiceEndpoint': vmServiceEndpoint,
      'recentLogSignals': _logSignalMaps(recentSignals, phase: 'logs_summary'),
      'blockingLogSignals': _logSignalMaps(
        signals.where((signal) => signal.blocking).toList(growable: false),
        phase: 'logs_summary',
      ),
      'lastImportantLines': important.length > limit
          ? important.sublist(important.length - limit)
          : important,
    };
  }

  List<Map<String, dynamic>> _nodesFromInspect(
    Map<String, dynamic> inspect,
    String groupName,
  ) {
    final group = inspect[groupName];
    if (group is! List) return const <Map<String, dynamic>>[];
    return [
      for (final node in group)
        if (node is Map<String, dynamic>) node,
    ];
  }

  Map<String, Object?> _boundsForNode(Map<String, dynamic> node, double dpr) {
    final rect = node['rect'];
    if (rect is! List || rect.length < 4) {
      return {
        'id': node['id'],
        'label': node['label'],
        'kind': node['kind'],
        'rect': null,
      };
    }
    final left = (rect[0] as num).toDouble();
    final top = (rect[1] as num).toDouble();
    final width = (rect[2] as num).toDouble();
    final height = (rect[3] as num).toDouble();
    return {
      'id': node['id'],
      'fallbackId': node['fallbackId'],
      'label': node['label'],
      'kind': node['kind'],
      'enabled': node['enabled'],
      'rect': [left, top, width, height],
      'center': [left + width / 2, top + height / 2],
      'pixelRect': [
        (left * dpr).round(),
        (top * dpr).round(),
        (width * dpr).round(),
        (height * dpr).round(),
      ],
    };
  }

  List<Object?> _objectList(Object? value) {
    if (value is List) return List<Object?>.from(value);
    return const <Object?>[];
  }

  double _inferDevicePixelRatio(
    Map<String, dynamic> inspect,
    img.Image source,
  ) {
    final logicalSize = inspect['logicalSize'];
    if (logicalSize is List && logicalSize.length >= 2) {
      final width = (logicalSize[0] as num?)?.toDouble();
      if (width != null && width > 0) return source.width / width;
    }
    return 1;
  }

  Map<String, String> _stringMap(Map<String, Object?> value) {
    final result = <String, String>{};
    for (final entry in value.entries) {
      if (entry.key == 'cmd' || entry.value == null) continue;
      result[entry.key] = entry.value.toString();
    }
    return result;
  }

  Future<String> _findMainIsolate(VmService service) async {
    final vm = await service.getVM().timeout(const Duration(seconds: 5));
    final isolates = vm.isolates ?? const <IsolateRef>[];
    if (isolates.isEmpty || isolates.first.id == null) {
      throw const ScoutCliException('no_isolate', 'No Dart isolate found.');
    }
    for (final isolate in isolates) {
      if (isolate.name == 'main' && isolate.id != null) return isolate.id!;
    }
    return isolates.first.id!;
  }

  Future<String?> _discoverVmUriFromSimulatorLogs({String? device}) async {
    final target = device == null || device.isEmpty ? 'booted' : device;
    final predicate = 'eventMessage CONTAINS "[FLUTTER_SCOUT_VM_URI]"';
    try {
      final result =
          await Process.run('xcrun', [
            'simctl',
            'spawn',
            target,
            'log',
            'show',
            '--last',
            '10m',
            '--predicate',
            predicate,
          ]).timeout(
            const Duration(seconds: 5),
            onTimeout: () => ProcessResult(0, 1, '', ''),
          );
      if (result.exitCode != 0) return null;
      return _extractVmUri(result.stdout as String);
    } catch (_) {
      return null;
    }
  }

  Future<_DiscoveredVmUri?> _discoverCurrentVmUri({String? device}) async {
    final fromScoutLog = _discoverVmUriFromScoutLog();
    if (fromScoutLog != null) {
      return _DiscoveredVmUri(uri: fromScoutLog, source: 'scout_log');
    }
    final fromSimulatorLog = await _discoverVmUriFromSimulatorLogs(
      device: device,
    );
    if (fromSimulatorLog != null) {
      return _DiscoveredVmUri(uri: fromSimulatorLog, source: 'simulator_log');
    }
    return null;
  }

  Future<_DiscoveredVmUri?> _refreshStaleVmUri({
    required String staleUri,
  }) async {
    final discovered = await _discoverCurrentVmUri(device: _readDevice());
    if (discovered == null) return null;
    final uri = _normalizeVmUri(discovered.uri);
    if (uri == _normalizeVmUri(staleUri)) return null;
    final validation = await _validateVmUri(uri);
    if (!validation.ok) return null;
    _persistValidatedVmUri(uri);
    await _ensureVmLogListenerForCurrentSession(uri);
    return _DiscoveredVmUri(uri: uri, source: discovered.source);
  }

  String? _discoverVmUriFromScoutLog() {
    final file = File(_logFile);
    if (!file.existsSync()) return null;
    final text = _readLogChunk(
      file,
      maxBytes: _maxScoutLogTailBytes,
    ).lines.join('\n');
    // In a Scout-owned run, the Flutter tool's own service line is scoped to
    // the process this session launched. VM logging can contain app-emitted
    // Scout markers from another Flutter app on the same simulator; preferring
    // those could silently retarget a named session to the wrong application.
    return _preferredVmUriFromLogText(text);
  }

  Future<_FlutterDevice?> _resolveFlutterDevice(String requested) async {
    // Fastest path: desktop and web targets use fixed Flutter device ids
    // (`macos`, `chrome`, ...) that need no discovery at all, so resolve them
    // from a constant instead of paying ~7s for `flutter devices --machine`.
    final wellKnown = _resolveWellKnownDevice(requested);
    if (wellKnown != null) return wellKnown;
    // Fast path: resolve iOS Simulator targets directly through `xcrun simctl`
    // (~0.1s) instead of booting the Flutter tool via `flutter devices
    // --machine` (~7s). This call runs on every command, so the simctl path
    // shaves seconds off both cold launches and warm `ensure`/`status` loops.
    final simulatorDevice = await _resolveSimulatorDevice(requested);
    if (simulatorDevice != null) return simulatorDevice;
    // Fallback: physical devices are only known to the Flutter tool, so pay the
    // slower discovery cost when neither fast path matches.
    return _resolveDeviceViaFlutter(requested);
  }

  /// Resolves the fixed Flutter desktop/web device ids without spawning a
  /// process. These ids are constants, so `flutter run -d <id>` reports a clear
  /// error later if the platform is not enabled. Fields mirror what `flutter
  /// devices --machine` returns (null platform/category, `emulator: false`), so
  /// downstream screenshot routing is unchanged.
  _FlutterDevice? _resolveWellKnownDevice(String requested) {
    final name = wellKnownDeviceName(requested);
    if (name == null) return null;
    return _FlutterDevice(
      id: requested,
      name: name,
      platform: null,
      category: null,
      emulator: false,
    );
  }

  /// Returns the display name for a fixed Flutter desktop/web device id, or null
  /// for anything that needs real discovery. Exposed for testing.
  static String? wellKnownDeviceName(String id) => const <String, String>{
    'macos': 'macOS',
    'windows': 'Windows',
    'linux': 'Linux',
    'chrome': 'Chrome',
    'edge': 'Edge',
    'web-server': 'Web Server',
  }[id];

  Future<_FlutterDevice?> _resolveSimulatorDevice(String requested) async {
    final ProcessResult result;
    try {
      result = await Process.run('xcrun', [
        'simctl',
        'list',
        'devices',
        '--json',
      ]).timeout(const Duration(seconds: 10));
    } on Object {
      // xcrun missing/unavailable (non-macOS host, no Xcode) -> fall back.
      return null;
    }
    if (result.exitCode != 0) return null;
    final match = parseSimctlDevices(result.stdout as String, requested);
    if (match == null) return null;
    return _FlutterDevice(
      id: match['id'] as String,
      name: match['name'] as String,
      platform: match['platform'] as String,
      category: 'mobile',
      emulator: true,
    );
  }

  /// Whether [relativePath] is a Dart file that a running app never loads.
  ///
  /// Test and tooling sources change like any other file, but they are not
  /// compiled into the app, so source verification must not treat their absence
  /// from the isolate as an unverified reload.
  static bool isNonRuntimeDartPath(String relativePath) {
    final normalized = relativePath.replaceAll('\\', '/');
    if (normalized.endsWith('_test.dart')) return true;
    const testRoots = {'test', 'integration_test', 'test_driver', 'benchmark'};
    return normalized.split('/').any((segment) => testRoots.contains(segment));
  }

  /// Collapses the double-logging of app output into a single copy per line.
  ///
  /// App `print`/`dev.log` output reaches the Scout log twice: once as
  /// `[FLUTTER_STDOUT]` from the Flutter tool and once as `[VM_STDOUT]` from
  /// Scout's own VM log listener. Only tagged lines are considered, and a
  /// duplicate is dropped only when a matching payload from the *other* source
  /// appears within [window] lines, so a message the app genuinely logged twice
  /// still shows up twice.
  ///
  /// Untagged lines are never dropped. They are the continuation lines of a
  /// multi-line message, and removing them silently truncated log output.
  /// Exposed for testing without a running app.
  static List<String> dedupeVmStdoutEcho(
    List<String> lines, {
    int window = 200,
  }) {
    final tagged = RegExp(r'^\[[^\]]*\] \[(VM|FLUTTER)_STD(?:OUT|ERR)\] (.*)$');

    // Payload -> indexes of still-unmatched Flutter-tool lines carrying it.
    final pendingFlutter = <String, List<int>>{};
    final drop = <int>{};

    for (var index = 0; index < lines.length; index++) {
      final match = tagged.firstMatch(lines[index]);
      if (match == null) continue;
      final source = match.group(1)!;
      final payload = match.group(2)!;
      if (payload.isEmpty) continue;

      if (source == 'FLUTTER') {
        (pendingFlutter[payload] ??= <int>[]).add(index);
        continue;
      }

      final candidates = pendingFlutter[payload];
      if (candidates == null || candidates.isEmpty) continue;
      final origin = candidates.first;
      if (index - origin > window) continue;
      candidates.removeAt(0);
      drop.add(index);
    }

    if (drop.isEmpty) return lines;
    final result = <String>[];
    for (var index = 0; index < lines.length; index++) {
      if (drop.contains(index)) continue;
      result.add(lines[index]);
    }
    return result;
  }

  /// Finds the simulator matching [requested] (a UDID or device name) within the
  /// `xcrun simctl list devices --json` payload in [jsonOutput].
  ///
  /// Returns a map with `id`, `name`, and `platform`, or null when the payload
  /// is malformed or no available device matches. A UDID match wins
  /// immediately; for name matches a booted device is preferred so the same
  /// device created under multiple runtimes resolves deterministically. Exposed
  /// for testing the parser without spawning a process.
  static Map<String, Object?>? parseSimctlDevices(
    String jsonOutput,
    String requested,
  ) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonOutput);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final devices = decoded['devices'];
    if (devices is! Map) return null;

    Map<String, Object?>? nameMatch;
    var nameMatchBooted = false;
    for (final entry in devices.entries) {
      final platform = _platformForSimRuntime(entry.key.toString());
      final list = entry.value;
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map) continue;
        if (item['isAvailable'] != true) continue;
        final udid = item['udid']?.toString();
        if (udid == null || udid.isEmpty) continue;
        final name = item['name']?.toString();
        final booted = item['state']?.toString() == 'Booted';
        if (udid == requested) {
          return {'id': udid, 'name': name ?? udid, 'platform': platform};
        }
        if (name == requested &&
            (nameMatch == null || (booted && !nameMatchBooted))) {
          nameMatch = {'id': udid, 'name': name ?? udid, 'platform': platform};
          nameMatchBooted = booted;
        }
      }
    }
    return nameMatch;
  }

  static String _platformForSimRuntime(String runtime) {
    final lower = runtime.toLowerCase();
    if (lower.contains('watchos')) return 'watchos';
    if (lower.contains('tvos')) return 'tvos';
    if (lower.contains('xros') || lower.contains('visionos')) return 'visionos';
    return 'ios';
  }

  Future<_FlutterDevice?> _resolveDeviceViaFlutter(String requested) async {
    final result =
        await Process.run('flutter', [
          'devices',
          '--machine',
        ], environment: _flutterToolEnvironment()).timeout(
          const Duration(seconds: 20),
          onTimeout: () => ProcessResult(0, 1, '', 'flutter devices timed out'),
        );
    if (result.exitCode != 0) {
      throw ScoutCliException(
        'device_discovery_failed',
        (result.stderr as String).trim(),
      );
    }
    final decoded = jsonDecode(result.stdout as String);
    if (decoded is! List) {
      throw const ScoutCliException(
        'device_discovery_failed',
        'flutter devices --machine returned an unexpected payload.',
      );
    }
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      final id = item['id']?.toString();
      final name = item['name']?.toString();
      if (id == requested || name == requested) {
        return _FlutterDevice(
          id: id ?? requested,
          name: name ?? requested,
          platform: item['platform']?.toString(),
          category: item['category']?.toString(),
          emulator: item['emulator'] == true,
        );
      }
    }
    return null;
  }

  String? _extractVmUri(String text) {
    final lines = text.split('\n').reversed;
    final pattern = RegExp(
      r'\[FLUTTER_SCOUT_VM_URI\]\s+(https?://\S+|wss?://\S+)',
    );
    for (final line in lines) {
      final match = pattern.firstMatch(line);
      if (match != null) {
        final value = match.group(1);
        if (value != null) _registerVmUriCredentials(value);
        return value;
      }
    }
    return null;
  }

  String? _extractFlutterToolVmUri(String text) {
    final patterns = [
      RegExp(r'(https?://127\.0\.0\.1:\d+/\S*=/?)'),
      RegExp(r'(https?://localhost:\d+/\S*=/?)'),
    ];
    for (final line in text.split('\n').reversed) {
      if (line.contains('[FLUTTER_SCOUT_VM_URI]')) continue;
      for (final pattern in patterns) {
        final match = pattern.firstMatch(line);
        if (match != null) {
          final value = match.group(1);
          if (value != null) _registerVmUriCredentials(value);
          return value;
        }
      }
    }
    return null;
  }

  String? _preferredVmUriFromLogText(String text) =>
      _extractFlutterToolVmUri(text) ?? _extractVmUri(text);

  String _normalizeVmUri(String uri) => _validatedVmServiceUri(uri).normalized;

  String _safeFileName(String value) =>
      _slug(value).isEmpty ? 'target' : _slug(value);

  String _slug(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');

  void _recordAction(Map<String, Object?> action) {
    _ensureSessionDir();
    _withPrivateFileLock<void>(
      '$_sessionFile.lock',
      boundary: _sessionDir.path,
      body: () {
        final file = File(_sessionFile);
        _assertPrivateFilePath(_sessionFile, boundary: _sessionDir.path);
        final Object? existing;
        try {
          existing = file.existsSync()
              ? jsonDecode(file.readAsStringSync())
              : <Object?>[];
        } catch (_) {
          throw const ScoutCliException(
            'session_journal_corrupt',
            'The Scout session journal is not valid JSON.',
          );
        }
        if (existing is! List) {
          throw const ScoutCliException(
            'session_journal_corrupt',
            'The Scout session journal must contain a JSON array.',
          );
        }
        final list = <Object?>[
          for (final item in existing)
            item is Map
                ? _redactRecordedAction(Map<String, Object?>.from(item))
                : _sanitizeNonActionValue(item),
          _redactRecordedAction(action),
        ];
        _atomicWritePrivateJson(_sessionFile, list, boundary: _sessionDir.path);
      },
    );
  }

  List<Object?> _readSessionActions() {
    _ensureSessionDir();
    return _withPrivateFileLock<List<Object?>>(
      '$_sessionFile.lock',
      boundary: _sessionDir.path,
      body: () {
        final file = File(_sessionFile);
        _assertPrivateFilePath(_sessionFile, boundary: _sessionDir.path);
        if (!file.existsSync()) return const <Object?>[];
        final Object? decoded;
        try {
          decoded = jsonDecode(file.readAsStringSync());
        } catch (_) {
          throw const ScoutCliException(
            'session_journal_corrupt',
            'The Scout session journal is not valid JSON.',
          );
        }
        if (decoded is! List) {
          throw const ScoutCliException(
            'session_journal_corrupt',
            'The Scout session journal must contain a JSON array.',
          );
        }
        final safe = <Object?>[
          for (final action in decoded)
            action is Map
                ? _redactRecordedAction(Map<String, Object?>.from(action))
                : _sanitizeNonActionValue(action),
        ];
        final encoded = const JsonEncoder.withIndent('  ').convert(safe);
        if (file.readAsStringSync() != encoded) {
          _atomicWritePrivateString(
            _sessionFile,
            encoded,
            boundary: _sessionDir.path,
          );
        }
        return safe;
      },
    );
  }

  void _writeProgress(String phase, [Map<String, Object?> data = const {}]) {
    _writeHeartbeat(phase, data);
  }

  void _writeLaunchProgressFromLine(String line) {
    final lower = line.toLowerCase();
    if (lower.contains('resolving dependencies')) {
      _writeProgress('pub_get');
    } else if (lower.contains('launching lib/main.dart') ||
        lower.contains('launching')) {
      _writeProgress('launching_app');
    } else if (lower.contains('xcode build done') ||
        lower.contains('built build/')) {
      _writeProgress('build_done');
    } else if (lower.contains('syncing files to device')) {
      _writeProgress('syncing_files');
    } else if (_extractVmUri(line) != null ||
        _extractFlutterToolVmUri(line) != null) {
      _writeProgress('vm_service_found');
    }
  }

  String? _readVmUri() {
    final file = File(_vmUriFile);
    if (!file.existsSync()) return null;
    final value = file.readAsStringSync().trim();
    _registerVmUriCredentials(value);
    return value.isEmpty ? null : value;
  }

  Future<int?> _startVmLogListener({
    required String vmUri,
    required String logFile,
    int? ownerPid,
  }) async {
    if (Platform.script.scheme != 'file') {
      return null;
    }
    try {
      final effectiveOwnerPid = ownerPid ?? _readPid();
      if (effectiveOwnerPid == null) return null;
      final spec = _prepareVmLogListenerLaunchSpec(
        vmUri: vmUri,
        logFile: logFile,
        ownerPid: effectiveOwnerPid,
      );
      late final Process process;
      try {
        process = await Process.start(
          Platform.resolvedExecutable,
          spec.arguments,
          mode: ProcessStartMode.detached,
        );
      } catch (_) {
        _deleteFileIfExists(spec.uriFile);
        rethrow;
      }
      _writePrivateSessionString(_vmLogListenerPidFile, process.pid.toString());
      return process.pid;
    } catch (error) {
      final writer = _LockedLogWriter(logFile);
      await writer.write(
        '[${DateTime.now().toUtc().toIso8601String()}] '
        '[flutter_scout] VM logging listener start failed: '
        '${_redactSensitiveLogText(error.toString())}',
      );
      await writer.close();
      return null;
    }
  }

  Future<int?> _findScoutFlutterToolPid({
    required String project,
    String? instanceName,
  }) async {
    try {
      final result = await Process.run('ps', ['ax', '-o', 'pid=,command=']);
      if (result.exitCode != 0) return null;
      final candidates = <int>[];
      for (final line in const LineSplitter().convert('${result.stdout}')) {
        if (!line.contains('flutter_tools.snapshot run')) continue;
        final matchesInstance =
            instanceName == null ||
            instanceName.isEmpty ||
            line.contains('FLUTTER_SCOUT_INSTANCE=$instanceName');
        final matchesProject = line.contains('FLUTTER_SCOUT_PROJECT=$project');
        if (!matchesInstance || !matchesProject) continue;
        final match = RegExp(r'^\s*(\d+)\s+').firstMatch(line);
        final candidate = int.tryParse(match?.group(1) ?? '');
        if (candidate != null) candidates.add(candidate);
      }
      if (candidates.isEmpty) return null;
      candidates.sort();
      return candidates.last;
    } catch (_) {
      return null;
    }
  }

  Future<int?> _ensureVmLogListenerForCurrentSession(String vmUri) async {
    if (await _isAttachOnlySession()) return null;
    final existing = _readVmLogListenerPid();
    final meta = _readSessionMeta();
    if (existing != null) {
      if (await _matchesOwnedVmLogListener(existing, meta)) return existing;
      // A recognizable command or matching PID is not sufficient ownership.
      // Leave an uncertain process untouched; an exact listener self-exits
      // when its owner tuple no longer matches.
      _deleteFileIfExists(_vmLogListenerPidFile);
    }
    final ownerPid = _readPid();
    if (ownerPid == null || !await _matchesOwnedFlutterRun(ownerPid, meta)) {
      return null;
    }
    final listenerPid = await _startVmLogListener(
      vmUri: vmUri,
      logFile: _logFile,
      ownerPid: ownerPid,
    );
    if (listenerPid == null) return null;
    final listenerIdentity = await _readProcessOwnershipIdentity(
      listenerPid,
      role: _vmLogListenerProcessRole,
    );
    final currentMeta = _readSessionMeta();
    if (listenerIdentity == null ||
        currentMeta == null ||
        !await _matchesOwnedFlutterRun(ownerPid, currentMeta)) {
      // Identity uncertainty means do not signal the listener. It will fail
      // closed once it cannot validate the owner metadata.
      _deleteFileIfExists(_vmLogListenerPidFile);
      return null;
    }
    _writeSessionMeta({
      ...currentMeta,
      'vmLogListenerPid': listenerPid,
      'vmLogListener': {
        'pid': listenerPid,
        'processIdentity': listenerIdentity,
        'ownerPid': ownerPid,
        'ownerProcessIdentity': currentMeta['processIdentity'],
        'runId': currentMeta['runId'],
        'sessionDirectory': _sessionDir.path,
      },
    });
    return listenerPid;
  }

  void _clearVmUriFile() {
    _deleteFileIfExists(_vmUriFile);
  }

  String? _readDevice() {
    final file = File(_deviceFile);
    if (!file.existsSync()) return null;
    final value = file.readAsStringSync().trim();
    return value.isEmpty ? null : value;
  }

  void _writeDeviceInfo(_FlutterDevice device) {
    _writePrivateSessionJson(_deviceInfoFile, device.toJson());
  }

  Map<String, dynamic>? _readDeviceInfo() {
    final file = File(_deviceInfoFile);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
    return null;
  }

  int? _readPid() {
    final file = File(_pidFile);
    if (!file.existsSync()) return null;
    return int.tryParse(file.readAsStringSync().trim());
  }

  int? _readVmLogListenerPid() {
    final file = File(_vmLogListenerPidFile);
    if (!file.existsSync()) return null;
    return int.tryParse(file.readAsStringSync().trim());
  }

  void _writeSessionMeta(Map<String, Object?> meta) {
    final safe = Map<String, Object?>.from(meta);
    final rawVmUri = safe.remove('vmServiceUri');
    if (rawVmUri != null) {
      final validated = _validatedVmServiceUri(rawVmUri.toString());
      safe['vmServiceEndpoint'] = validated.endpoint;
    }
    _writePrivateSessionJson(_sessionMetaFile, safe);
  }

  Map<String, dynamic>? _readSessionMeta() {
    final file = File(_sessionMetaFile);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      final result = Map<String, dynamic>.from(decoded);
      final rawVmUri = result.remove('vmServiceUri');
      if (rawVmUri != null) {
        _registerVmUriCredentials(rawVmUri);
        result['vmServiceEndpoint'] = _safeVmServiceEndpointIdentity(
          rawVmUri.toString(),
        );
        // Migrate legacy metadata immediately. The dedicated vm_uri.txt file
        // remains the sole credential store; metadata is endpoint-only.
        _writePrivateSessionJson(_sessionMetaFile, result);
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _readSessionConfiguredJson(String key) {
    final configured = _readSessionMeta()?[key]?.toString();
    if (configured == null ||
        configured.isEmpty ||
        !_isWithinSessionOwnershipBoundary(configured)) {
      return null;
    }
    final file = File(configured);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> _sessionModeInfo() {
    final meta = _readSessionMeta();
    final pid = _readPid();
    return {
      'mode': meta?['mode'] ?? (pid == null ? 'unknown' : 'legacy'),
      'state': ?meta?['state'],
      'runId': ?meta?['runId'],
      'name': ?meta?['name'],
      'pid': ?pid,
      'vmLogListenerPid': ?_readVmLogListenerPid(),
      'createdAt': ?meta?['createdAt'],
      'updatedAt': ?meta?['updatedAt'],
      'logFile': ?meta?['logFile'],
      'supervisor': ?meta?['supervisor'],
      'supervisorState': ?_readSessionConfiguredJson('supervisorStateFile'),
      'lastRunnerExit': ?_readSessionConfiguredJson('exitFile'),
      'previousMode': ?meta?['previousMode'],
      'ownershipLossReason': ?meta?['ownershipLossReason'],
      'ownershipLostAt': ?meta?['ownershipLostAt'],
      if (_implicitlySelectedSessionName != null)
        'implicitlySelectedName': _implicitlySelectedSessionName,
    };
  }

  Future<bool> _isAttachOnlySession() async {
    final meta = _readSessionMeta();
    if (meta?['mode'] == 'attach_only') return true;
    final pid = _readPid();
    if (meta?['mode'] == 'scout_owned_flutter_run') {
      return pid == null || !await _matchesOwnedFlutterRun(pid, meta);
    }
    // Legacy PID-only sessions have no immutable ownership proof. They remain
    // usable as attach-only sessions but cannot gain signal/termination
    // authority from a recognizable command line.
    if (pid == null) return false;
    return true;
  }

  Future<Map<String, Object?>> _hotUpdateCapability(String vmUri) async {
    final pid = _readPid();
    final meta = _readSessionMeta();
    final scoutOwned = pid != null && await _matchesOwnedFlutterRun(pid, meta);
    final ownershipLossReason = meta?['ownershipLossReason']?.toString();
    final ownershipLost = ownershipLossReason == 'owner_process_exited';
    final listenerPid = await _pidForListeningVmPort(vmUri);
    return {
      'reload': {
        'available': !ownershipLost,
        'method': ownershipLost
            ? 'unavailable_after_owner_process_exit'
            : scoutOwned
            ? 'sigusr1_hot_reload'
            : 'vm_service_reload_sources',
        'preservesState': !ownershipLost,
        'successRequires': scoutOwned
            ? const [
                'exact_process_identity',
                'flutter_tool_acknowledgement',
                'post_update_runtime_inspection',
                'no_loaded_source_mismatch',
              ]
            : const [
                'vm_reload_report_success',
                'post_update_runtime_inspection',
                'no_loaded_source_mismatch',
              ],
      },
      'restart': {
        'available': scoutOwned,
        'method': ownershipLost
            ? 'unavailable_after_owner_process_exit'
            : scoutOwned
            ? 'sigusr2_hot_restart'
            : 'unavailable_without_scout_owned_flutter_run',
        'requiresScoutOwnedRun': true,
        'successRequires': const [
          'exact_process_identity',
          'flutter_tool_acknowledgement',
          'new_runtime_instance',
          'no_loaded_source_mismatch',
        ],
      },
      'attachOnly': !scoutOwned,
      'ownershipProof': scoutOwned
          ? 'exact_process_identity'
          : meta?['mode'] == 'scout_owned_flutter_run'
          ? 'identity_mismatch_or_unavailable'
          : 'not_scout_owned',
      if (ownershipLost) 'ownershipLost': true,
      if (ownershipLost) 'ownershipLossReason': ownershipLossReason,
      if (scoutOwned) 'scoutPid': pid,
      'recordedScoutPid': ?pid,
      'vmServiceListenerPid': ?listenerPid,
      'nextBestActions': ownershipLost
          ? const [
              'The original Scout-owned Flutter runner exited; the app remains inspectable but cannot compile Dart edits',
              'Use flutter-scout launch --replace --device <sim-id> --project <path> when a fresh Scout-owned run is acceptable',
            ]
          : scoutOwned
          ? const [
              'Use flutter-scout reload for Dart-only edits',
              'Use flutter-scout restart when Dart state must reset',
            ]
          : const [
              'Use flutter-scout reload for Dart-only edits through the VM service',
              'Use the owning Flutter terminal or IDE for hot restart',
              'Run flutter-scout ensure --device <sim-id> --project <path> when Scout should own restart/log capture',
            ],
    };
  }

  Future<int?> _pidForListeningVmPort(String vmUri) async {
    final uri = Uri.tryParse(_normalizeVmUri(vmUri));
    final port = uri?.port;
    if (port == null || port <= 0) return null;
    try {
      final result = await Process.run('lsof', ['-tiTCP:$port', '-sTCP:LISTEN'])
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => ProcessResult(0, 1, '', ''),
          );
      if (result.exitCode != 0) return null;
      final firstLine = (result.stdout as String).trim().split('\n').first;
      return int.tryParse(firstLine);
    } catch (_) {
      return null;
    }
  }

  Future<List<int>> _descendantPids(int? pid) async {
    if (pid == null) return const <int>[];
    final result = <int>[];
    final queue = <int>[pid];
    final seen = <int>{pid};
    while (queue.isNotEmpty) {
      final parent = queue.removeAt(0);
      final children = await _childPids(parent);
      for (final child in children) {
        if (!seen.add(child)) continue;
        result.add(child);
        queue.add(child);
      }
    }
    return result;
  }

  Future<List<int>> _childPids(int pid) async {
    try {
      final result = await Process.run('pgrep', ['-P', '$pid']).timeout(
        const Duration(seconds: 2),
        onTimeout: () => ProcessResult(0, 1, '', ''),
      );
      if (result.exitCode != 0) return const <int>[];
      return (result.stdout as String)
          .split('\n')
          .map((line) => int.tryParse(line.trim()))
          .nonNulls
          .toList(growable: false);
    } catch (_) {
      return const <int>[];
    }
  }

  bool _commandLooksLikeScoutVmLogListener(String command) {
    final lower = command.toLowerCase();
    return _commandLooksLikeScoutCli(command) &&
        lower.contains('vm-log-listener');
  }

  bool _commandLooksLikeScoutCli(String command) {
    final lower = command.toLowerCase();
    return lower.contains('flutter_scout') || lower.contains('flutter-scout');
  }

  Future<bool> _processExists(int pid) async {
    return await _processCommand(pid) != null;
  }

  Future<String?> _processCommand(int pid) async {
    try {
      final result = await Process.run('ps', ['-p', '$pid', '-o', 'command='])
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => ProcessResult(0, 1, '', ''),
          );
      if (result.exitCode != 0) return null;
      final command = (result.stdout as String).trim();
      return command.isEmpty ? null : command;
    } catch (_) {
      return null;
    }
  }

  void _deleteFileIfExists(String path) {
    final file = File(path);
    if (file.existsSync()) {
      file.deleteSync();
    }
  }

  int _unknown(String command) {
    final suggestion = command == 'action' ? 'tap' : _closestCommand(command);
    _writeStructuredError(
      'unknown_command',
      'Unknown Flutter Scout command `${_redactSensitiveLogText(command)}`.',
      details: <String, Object?>{
        'requestedCommand': _redactSensitiveLogText(command),
        'suggestedCommand': suggestion,
        'helpCommand': 'flutter-scout help',
        'availableCommands': _commands.toList(growable: false)..sort(),
        if (command == 'action')
          'guidance':
              'Actions are direct commands, for example `flutter-scout tap btn.save --expect-text Saved`.',
      },
    );
    return 64;
  }

  Future<int> _version() async {
    _printJson({
      'ok': true,
      'package': 'flutter_scout',
      'version': packageVersion,
      'helperProtocolExpected': expectedHelperProtocolVersion,
      'executable': Platform.resolvedExecutable,
      'script': Platform.script.toString(),
    }, commandName: 'version');
    return 0;
  }

  Future<int> _help(List<String> args) async {
    _printUsage(command: args.isEmpty ? null : args.first);
    return 0;
  }

  String? _closestCommand(String input) {
    const aliases = {
      'screenshots': 'screenshot',
      'annotation': 'annotations',
      'app': 'apps',
      'relaunch': 'launch',
    };
    if (aliases[input] case final alias?) return alias;
    for (final command in _commands) {
      if (command.startsWith(input) || input.startsWith(command)) {
        return command;
      }
    }
    return null;
  }

  static const Set<String> _commands = {
    'attach',
    'launch',
    'ensure',
    'status',
    'doctor',
    'stop',
    'inspect',
    'where',
    'locate',
    'reveal',
    'annotations',
    'bounds',
    'tap',
    'tap-text',
    'long-press',
    'input',
    'fill',
    'scroll',
    'scroll-to',
    'swipe',
    'drag-start',
    'drag-move',
    'drag-end',
    'drag-cancel',
    'drag-status',
    'back',
    'dismiss',
    'wait',
    'wait-for',
    'health',
    'batch',
    'export-batch',
    'serve',
    'explore',
    'devices',
    'apps',
    'reload',
    'restart',
    'deeplink',
    'logs',
    'screenshot',
    'crop',
    'evidence',
    'replay',
    'record',
    'version',
    'help',
  };

  static const Set<String> _commandsEligibleForServeProxy = {
    'inspect',
    'where',
    'locate',
    'reveal',
    'annotations',
    'bounds',
    'tap',
    'tap-text',
    'long-press',
    'input',
    'fill',
    'scroll',
    'scroll-to',
    'swipe',
    'drag-start',
    'drag-move',
    'drag-end',
    'drag-cancel',
    'drag-status',
    'back',
    'dismiss',
    'wait',
    'wait-for',
    'health',
    'reload',
    'restart',
    'logs',
    'screenshot',
    'crop',
  };

  void _printUsage({String? command}) {
    if (command == 'launch' || command == 'ensure') {
      stdout.writeln('''
Flutter Scout: $command

Usage:
  flutter-scout $command --device <simulator-id> [--project <path>]
      [--dart-define-from-file <owner-only-0600-file>]

Compile-time value handling:
  Define files are bounded to 1 MiB, strict UTF-8, regular, non-symlink, and
  exactly 0600 on POSIX. Scout validates them before session creation and the
  detached worker revalidates immediately before spawning Flutter. Only the
  absolute file path enters Scout's worker configuration and the Flutter-tool
  argv Scout creates; keep the caller-owned file private and stable until
  Flutter reads it. Flutter may expose compile-time values in its own downstream
  tool processes or the built app, so Dart defines are not a secret vault.
  Inline `--dart-define <name=value>` remains temporarily compatible for
  nonsecret values and emits a structured deprecation warning. A secret-looking
  inline name or value is rejected before state or child-process creation.
''');
      return;
    }
    if (command == 'attach') {
      stdout.writeln('''
Flutter Scout: attach

Usage:
  flutter-scout attach [--device <simulator-id>]
      [--debug-url-file <owner-only-0600-file> | --debug-url-stdin]

VM-service transport:
  The credential-bearing VM-service URL is bounded, strict UTF-8, and accepted
  only for ws/wss/http/https on explicit loopback hosts (127/8, ::1, or exact
  localhost) with an explicit port. Remote VM-service egress is unsupported.
  `--debug-url <url>` remains temporarily compatible but exposes the capability
  URL through process argv and emits a structured deprecation warning.
''');
      return;
    }
    if (command == 'deeplink') {
      stdout.writeln('''
Flutter Scout: deeplink

Usage:
  flutter-scout [--idempotency-key <key>] deeplink
      (--url-file <owner-only-0600-file> | --url-stdin)

Secret handling:
  Deep-link URLs can contain session tokens. Protected file/stdin ingress keeps
  the URL out of argv and stores only a replay placeholder/provenance. A legacy
  positional URL remains compatible but emits a structured warning.

Native capability:
  Requires an exact recorded iOS Simulator or Android Emulator and a successful
  read-only platform-tool preflight plus a live protocol-valid observation from
  the exact selected session immediately before dispatch. Android uses bounded
  local-argv ADB with a single-quoted URL for the remote shell and requires
  Activity Manager `Status: ok`. Unsupported
  targets abstain before app dispatch; uncertain dispatch must be reconciled
  under the original idempotency key.
''');
      return;
    }
    if (command == 'screenshot' || command == 'crop') {
      stdout.writeln('''
Flutter Scout: $command

Usage:
  flutter-scout screenshot [-o <path>] [--target <target>] [--annotated]
      [--native] [--retention session|24h|7d|manual]
  flutter-scout crop <target> | crop --text <text> | crop --rect x,y,w,h [-o <path>] [--native]
  flutter-scout crop --changed-since <snapshot-id> [-o <path>] [--padding <0..256>]

Changed-region contract:
  Captures only a complete bounded semantic-region union from retained helper
  history. The baseline/current/capture-verification identities, logical and
  physical rects, DPR, backend, limits, and provenance are returned. Scout
  abstains on stale history, ambiguous/unavailable geometry, screen/route or
  coordinate-frame changes, more than 16 regions, a union above 50% of the
  viewport, or output above 4096x4096 / 4,194,304 pixels. Native fallback is
  unsupported because it cannot be atomically bound to the helper snapshot.

Native capability:
  Full capture supports exact recorded iOS Simulators, Android Emulators, and
  proven macOS app windows. Results disclose backend, provenance, physical-pixel
  space, and limitations. A native targeted crop proceeds only when the scoped
  Flutter physical viewport exactly matches the PNG dimensions; Scout never
  guesses system-bar, inset, rotation, or letterbox offsets.
''');
      return;
    }
    if (command != null &&
        const {'tap', 'tap-text', 'input', 'fill'}.contains(command)) {
      stdout.writeln('''
Flutter Scout: $command

Protected value input:
  ${command == 'input' ? '--file <0600-path> | --stdin' : '--file <0600-json> | --stdin'}
                             Keep values out of process argv. Protected input
                             is bounded to 1 MiB; files must be regular,
                             non-symlink, valid UTF-8, and exactly 0600 on POSIX.

Guarded action options:
  --expect-text <text>       Wait for visible text.
  --expect-gone <text>       Wait for text to disappear.
  --expect-target <handle>   Wait for a visible target.
  --expect-screen <screen>   Wait for a screen name.
  --expect-timeout <ms>      Expectation timeout (default 5000).
  --capture <path>           Capture the exact successful expectation frame.
  --expect-log <text>        Wait for fresh Scout-owned log text.
  --reject-log <text>        Fail if fresh logs contain this text.
  --allow-errors             Permit fresh blocking errors (failed by default).

Run `flutter-scout help` for the complete command list.
''');
      return;
    }
    stdout.writeln('''
Flutter Scout

Usage:
  flutter-scout [--app <name>] [--idempotency-key <key>] <command> [options]
    --idempotency-key accepts 1-128 safe ASCII characters. Reuse one key only
    for the same business mutation; retries replay/reconcile the first outcome.
  flutter-scout attach [--device <simulator-id>] [--debug-url-file <0600-path> | --debug-url-stdin]
  flutter-scout launch --device <simulator-id> [--project <path>] [--name <label>] [--replace] [--temporary-helper] [--dart-define-from-file <0600-path>] [--launch-timeout <s>] [--launch-idle-timeout <s>]
  flutter-scout ensure --device <simulator-id> [--project <path>] [--name <label>] [--temporary-helper] [--dart-define-from-file <0600-path>] [--launch-timeout <s>] [--launch-idle-timeout <s>]
  flutter-scout status
  flutter-scout devices
  flutter-scout apps [--all] [--prune]
  flutter-scout version | --version | -V
  flutter-scout doctor [--project <path>] [--device <simulator-id>]
  flutter-scout stop [--clear-session]
  flutter-scout inspect [--brief] [--surface] [--max-items <n>] [--sections <list>] [--since <snapshot-id>]
  flutter-scout where [--verbose]
  flutter-scout locate (--text <text> | --target <handle>) [--within <scroll-id>]
  flutter-scout reveal (--text <text> | --target <handle>) [--within <scroll-id>] [--direction down|up|right|left] [--max-actions <n>]
  flutter-scout annotations [list|targets|enable|disable|clear|resolve|dismiss|reopen|fixed|check]
  flutter-scout annotations wait [--timeout <seconds>] [--poll <ms>]
  flutter-scout annotations fixed <annotation-id> [--note <text>]
  flutter-scout bounds [target]
  flutter-scout tap <target> [--expect-text <text>] [--expect-log <text>] [--reject-log <text>] [--allow-errors] [--verbose]
  flutter-scout tap <x> <y> | tap --x <x> --y <y>
  flutter-scout tap-text <visible text> | tap-text --text <visible text> [--allow-mismatch] [--verbose]
  flutter-scout long-press <target> [--verbose]
  flutter-scout input [--target <field>] (--file <0600-path> | --stdin) [--verbose]
  flutter-scout input [--target <field>] <value> [--verbose]  # insecure legacy argv
  flutter-scout fill (--file <0600-json> | --stdin) [--verbose]
  flutter-scout fill --json <object> [--verbose]  # insecure legacy argv
  flutter-scout scroll [up|down|left|right] [--target <target>] [--distance <px>] [--x <x> --y <y> | --from x,y] [--verbose]
  flutter-scout scroll-to <target> [--max-scrolls <n>] [--direction down|up|left|right] [--distance <px>] [--verbose]
  flutter-scout swipe [up|down|left|right] [--target <target>] [--distance <px>] [--x <x> --y <y> | --from x,y] [--to x,y] [--verbose]
  flutter-scout drag-start [--target <target> | --from x,y]
  flutter-scout drag-move (--to x,y | --by dx,dy) [--screenshot <path>] [--verbose]
  flutter-scout drag-end [--to x,y | --by dx,dy] [--verbose]
  flutter-scout drag-status | drag-cancel
  flutter-scout back [--verbose]
  flutter-scout wait stable [--timeout <ms>] [--verbose]
  flutter-scout wait-for [--text <text>] [--gone <text>] [--target <handle>]
  flutter-scout health [--include-stale]
  flutter-scout batch '<command>; <command>' [--var-file <0600-json> | --var-stdin] [--keep-going] [--verbose]
  flutter-scout export-batch [-o <path>] [--retention session|24h|7d|manual]
  flutter-scout serve [--port <port>] [--port-file <path>] [--credential-file <path>] [--idle-timeout <seconds>] [--request-timeout <seconds>] [--max-body-bytes <n>] [--allow-legacy-run]
  flutter-scout explore [--port <port>] [--port-file <path>] [--credential-file <path>] [--once]
  flutter-scout record run <name> [--var-file <0600-json> | --var-stdin]
  flutter-scout record start|stop|list|show|pause|resume|undo|save-last
  flutter-scout reload [--verbose]
  flutter-scout restart [--verbose]
  flutter-scout deeplink (--url-file <0600-path> | --url-stdin)
  flutter-scout logs [--last <n>] [--contains <text>] [--summary]
  flutter-scout screenshot [-o <path>] [--target <target>] [--annotated] [--native] [--retention session|24h|7d|manual]
  flutter-scout crop <target> | crop --text <visible text> | crop --rect x,y,w,h | crop --changed-since <snapshot-id> [-o <path>] [--native] [--retention session|24h|7d|manual]
  flutter-scout evidence [-o <dir>] [--last <n>] [--audit] [--retention session|24h|7d|manual]
  flutter-scout replay [session.json] [--var-file <0600-json> | --var-stdin] [--verbose]
  flutter-scout help [command]
''');
  }

  bool _isNumeric(String value) => double.tryParse(value) != null;
}

/// Compile-time define the CLI injects (via `--name`) so the in-app helper can
/// render an instance-label badge. Lets several worktree sessions of the same
/// macOS/desktop app be told apart on screen. Must match the key the helper
/// reads with `String.fromEnvironment`.
const String kScoutInstanceDefine = 'FLUTTER_SCOUT_INSTANCE';
const String kScoutProjectDefine = 'FLUTTER_SCOUT_PROJECT';
const String kScoutRunIdDefine = 'FLUTTER_SCOUT_RUN_ID';

/// Global session registry: `--name <label>` at launch/ensure records
/// label -> session directory here, and the global `--app <label>` option
/// runs any command against that session from anywhere — no cd required.
File get _scoutRegistryFile => File(
  FlutterScoutCli.debugRegistryPathOverride ??
      p.join(
        Platform.environment['HOME'] ?? Directory.current.path,
        '.flutter_scout',
        'registry.json',
      ),
);

Map<String, String> _readScoutRegistry() {
  try {
    final file = _scoutRegistryFile;
    if (!file.existsSync()) return {};
    _ensurePrivateDirectory(file.parent.path, boundary: file.parent.path);
    _assertPrivateFilePath(file.path, boundary: file.parent.path);
    _securePrivateFile(file.path, boundary: file.parent.path);
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) {
      throw const ScoutCliException(
        'registry_corrupt',
        'The Flutter Scout session registry must be a JSON object.',
      );
    }
    return {
      for (final entry in decoded.entries)
        if (entry.value is String) entry.key.toString(): entry.value as String,
    };
  } on ScoutCliException {
    rethrow;
  } catch (_) {
    throw const ScoutCliException(
      'registry_corrupt',
      'The Flutter Scout session registry is not valid JSON.',
    );
  }
}

void _registerScoutSession(String name, String directory, {String? project}) {
  try {
    final file = _scoutRegistryFile;
    _ensurePrivateDirectory(file.parent.path, boundary: file.parent.path);
    _withPrivateFileLock<void>(
      '${file.path}.lock',
      boundary: file.parent.path,
      body: () {
        final registry = _readScoutRegistry();
        final candidate = _normalizeRegisteredSessionDirectory(directory);
        final existing = registry[name];
        final competing = _discoverNamedSessionDirectories(
          name,
          seedDirectories: <String>[?existing, candidate],
          project: project,
        );
        final liveExisting = existing == null
            ? null
            : _normalizeRegisteredSessionDirectory(existing);
        final hasDifferentRegisteredSession =
            liveExisting != null &&
            Directory(liveExisting).existsSync() &&
            !_sameSessionDirectory(liveExisting, candidate);
        final hasDiscoveredConflict = competing.any(
          (path) => !_sameSessionDirectory(path, candidate),
        );
        if (hasDifferentRegisteredSession || hasDiscoveredConflict) {
          throw _namedSessionAmbiguity(name, <String>{
            ...competing,
            ?liveExisting,
            candidate,
          });
        }
        registry[name] = candidate;
        _writeScoutRegistryUnlocked(registry);
      },
    );
  } on ScoutCliException catch (error) {
    if (error.code == 'session_selection_required') rethrow;
  } catch (_) {
    // Registration is best-effort; the session still works from its own cwd.
  }
}

void _writeScoutRegistry(Map<String, String> registry) {
  final file = _scoutRegistryFile;
  _ensurePrivateDirectory(file.parent.path, boundary: file.parent.path);
  _withPrivateFileLock<void>(
    '${file.path}.lock',
    boundary: file.parent.path,
    body: () => _writeScoutRegistryUnlocked(registry),
  );
}

void _writeScoutRegistryUnlocked(Map<String, String> registry) {
  final file = _scoutRegistryFile;
  _atomicWritePrivateJson(file.path, registry, boundary: file.parent.path);
}

/// Drops registry names pointing at [directory] (a cleared session). Returns
/// the pruned names.
List<String> _pruneScoutRegistryFor(String directory) {
  try {
    // getcwd resolves symlinks (macOS /var -> /private/var) while registry
    // entries keep the path as given; compare fully-resolved paths.
    String resolved(String path) {
      try {
        return Directory(path).resolveSymbolicLinksSync();
      } catch (_) {
        return p.normalize(p.absolute(path));
      }
    }

    final target = resolved(directory);
    final legacyProjectTarget = p.basename(directory) == '.flutter_scout'
        ? resolved(p.dirname(directory))
        : null;
    final file = _scoutRegistryFile;
    _ensurePrivateDirectory(file.parent.path, boundary: file.parent.path);
    return _withPrivateFileLock<List<String>>(
      '${file.path}.lock',
      boundary: file.parent.path,
      body: () {
        final registry = _readScoutRegistry();
        final pruned = [
          for (final entry in registry.entries)
            if (resolved(entry.value) == target ||
                (legacyProjectTarget != null &&
                    resolved(entry.value) == legacyProjectTarget) ||
                resolved(p.join(entry.value, '.flutter_scout')) == target)
              entry.key,
        ];
        if (pruned.isEmpty) return const [];
        pruned.forEach(registry.remove);
        _writeScoutRegistryUnlocked(registry);
        return pruned;
      },
    );
  } catch (_) {
    return const [];
  }
}

Directory get _sessionDir => Directory(
  FlutterScoutCli._sessionDirectoryOverride ??
      p.join(Directory.current.path, '.flutter_scout'),
);

String _safeSessionName(String value) {
  final safe = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
  return safe.isEmpty ? 'session' : safe;
}

String get _vmUriFile => p.join(_sessionDir.path, 'vm_uri.txt');
String get _deviceFile => p.join(_sessionDir.path, 'device.txt');
String get _deviceInfoFile => p.join(_sessionDir.path, 'device_info.json');
String get _sessionFile => p.join(_sessionDir.path, 'session.json');
String get _eventsFile => p.join(_sessionDir.path, 'events.jsonl');
String get _pidFile => p.join(_sessionDir.path, 'flutter.pid');
String get _vmLogListenerPidFile =>
    p.join(_sessionDir.path, 'vm_log_listener.pid');
String get _legacyLogFile => p.join(_sessionDir.path, 'logs.txt');
String get _launchLockFile => p.join(_sessionDir.path, 'launch.lock');

/// The active run owns its own log. This prevents overlapping launches from
/// truncating or parsing each other's Flutter output while retaining the
/// legacy path for old and attach-only sessions.
String get _logFile => _resolvedScoutLogFilePath();

List<String> _readLogLinesSync(File file) {
  if (!file.existsSync()) return const [];
  return _readValidatedScoutLogChunk(
    file,
    maxBytes: _maxScoutLogTailBytes,
  ).lines;
}

/// Recent hard runtime signals from the Scout-owned log — app logs and Flutter
/// console lines that the in-isolate error hooks can miss. Empty for attach
/// sessions with no Scout-owned log.
List<_LogSignal> _recentLogSignals({
  int scanLines = 300,
  int max = 8,
  int? sinceCursor,
}) {
  final file = File(_logFile);
  if (!file.existsSync()) return const [];
  try {
    final chunk = _readLogChunk(file, sinceCursor: sinceCursor);
    return _logSignalsFromLines(
      chunk.lines,
      scanLines: scanLines,
      max: max,
      baseCursor: chunk.startCursor,
      runId: _currentRunIdFromSession(),
    );
  } on ScoutCliException {
    rethrow;
  } catch (_) {
    return const [];
  }
}

List<_LogSignal> _freshRecentLogSignals({int scanLines = 300, int max = 8}) {
  final now = DateTime.now();
  return _recentLogSignals(
    scanLines: scanLines,
    max: max,
  ).where((signal) => !signal.isStale(now)).toList(growable: false);
}

List<_LogSignal> _logSignalsFromLines(
  List<String> lines, {
  int scanLines = 300,
  int max = 8,
  int baseCursor = 0,
  String? runId,
}) {
  if (lines.isEmpty || scanLines <= 0 || max <= 0) return const [];
  final tail = lines.length <= scanLines
      ? lines
      : lines.sublist(lines.length - scanLines);
  final skipped = lines.length - tail.length;
  var tailCursor = baseCursor;
  for (var index = 0; index < skipped; index++) {
    tailCursor += utf8.encode(lines[index]).length + 1;
  }
  final signals = <_LogSignal>[];
  final sanitizedTail = tail
      .map(_redactSensitiveLogText)
      .toList(growable: false);
  for (var i = 0; i < tail.length; i++) {
    final rawLine = tail[i];
    final line = sanitizedTail[i].trim();
    final lineEndCursor = tailCursor + utf8.encode(rawLine).length + 1;
    final classification = _classifyLogLine(line);
    if (classification != null) {
      signals.add(
        _LogSignal(
          kind: classification.kind,
          severity: classification.severity,
          blocking: classification.blocking,
          message: classification.message,
          line: line,
          timestamp: _extractLogTimestamp(line),
          context: _logSignalContext(sanitizedTail, i),
          cursor: lineEndCursor,
          runId: runId,
        ),
      );
    }
    tailCursor = lineEndCursor;
  }
  return signals.length <= max
      ? signals
      : signals.sublist(signals.length - max);
}

_LogClassification? _classifyLogLine(String rawLine) {
  final line = _stripLogAnsi(rawLine).trim();
  if (line.isEmpty) return null;
  final lowerLine = line.toLowerCase();
  if (lowerLine.contains('[flutter_scout]') ||
      lowerLine.contains('flutter_scout_vm_uri') ||
      RegExp(r'\berror\s*=\s*null\b').hasMatch(lowerLine) ||
      _isNegatedLogError(lowerLine)) {
    return null;
  }

  final payload = _stripLogMetadata(line);
  final lower = payload.toLowerCase();
  if (lower.isEmpty || _isNegatedLogError(lower)) return null;

  final buildError = RegExp(
    r'build error:\s*(.+)$',
    caseSensitive: false,
  ).firstMatch(payload);
  if (buildError != null) {
    return _LogClassification(
      kind: 'flutter_build_error',
      severity: 'blocking',
      blocking: true,
      message: buildError.group(1)!.trim(),
    );
  }

  if (_dartCompilerErrorPattern.hasMatch(payload)) {
    return _LogClassification(
      kind: 'flutter_compile_error',
      severity: 'blocking',
      blocking: true,
      message: _stripFlutterToolLogMetadata(line),
    );
  }

  if (lower.contains('exception caught by widgets library') ||
      lower.contains('another exception was thrown') ||
      lower.contains('failed assertion') ||
      lower.contains('setstate() or markneedsbuild()')) {
    return _LogClassification(
      kind: 'flutter_framework_error',
      severity: 'blocking',
      blocking: true,
      message: payload,
    );
  }

  if (lower.contains('null check operator used on a null value')) {
    return _LogClassification(
      kind: 'dart_null_check_error',
      severity: 'blocking',
      blocking: true,
      message: payload,
    );
  }

  if (lower.contains('unhandled exception')) {
    return _LogClassification(
      kind: 'unhandled_exception',
      severity: 'blocking',
      blocking: true,
      message: payload,
    );
  }

  if (lower.contains('renderflex overflow') ||
      lower.contains('overflowed by') ||
      lower.contains('bottom overflowed')) {
    return _LogClassification(
      kind: 'render_overflow',
      severity: 'blocking',
      blocking: true,
      message: payload,
    );
  }

  // Flutter reports image-provider failures through several different
  // surfaces depending on the backend (asset bundle, network provider, codec,
  // or the image resource service). Keep this ahead of the generic
  // high-severity-log branch so the signal retains its actionable category.
  if (lower.contains('exception caught by image resource service') ||
      lower.contains('unable to load asset') ||
      lower.contains('failed to load network image') ||
      lower.contains('image loading failed') ||
      lower.contains('image load failed') ||
      lower.contains('imagecodec exception') ||
      lower.contains('imagecodecexception') ||
      lower.contains('networkimageloadexception')) {
    return _LogClassification(
      kind: 'image_loading_failure',
      severity: 'non_blocking',
      blocking: false,
      message: payload,
    );
  }

  if (lower.contains('hot reload was rejected') ||
      lower.contains('hot restart was rejected') ||
      lower.contains('could not hot reload') ||
      lower.contains('could not hot restart') ||
      lower.contains('hot reload failed') ||
      lower.contains('hot restart failed')) {
    return _LogClassification(
      kind: 'flutter_hot_update_rejected',
      severity: 'blocking',
      blocking: true,
      message: payload,
    );
  }

  if (lower.contains('[error:flutter/') ||
      lower.startsWith('[error:') ||
      RegExp(r'\bfatal\b', caseSensitive: false).hasMatch(payload)) {
    return _LogClassification(
      kind: 'native_runtime_error',
      severity: 'blocking',
      blocking: true,
      message: payload,
    );
  }

  final level = _extractLogLevel(line);
  if (level != null && level >= 1000) {
    return _LogClassification(
      kind: 'app_log_error',
      severity: 'non_blocking',
      blocking: false,
      message: payload,
    );
  }

  if (RegExp(
    r'(\b(permission|location|authorization|camera|photo)\b.*\bdenied\b|\bdenied\b.*\b(permission|location|authorization|camera|photo)\b)',
    caseSensitive: false,
  ).hasMatch(payload)) {
    return _LogClassification(
      kind: 'permission_denied',
      severity: 'warning',
      blocking: false,
      message: payload,
    );
  }

  if (RegExp(
    r'(\b(api|http|request|network|socket)\b.*\b(failed|failure)\b|\b(failed|failure)\b.*\b(api|http|request|network|socket)\b)',
    caseSensitive: false,
  ).hasMatch(payload)) {
    return _LogClassification(
      kind: 'app_request_failure',
      severity: 'non_blocking',
      blocking: false,
      message: payload,
    );
  }

  return null;
}

List<String> _logSignalContext(List<String> lines, int signalIndex) {
  final context = <String>[];
  final before = <String>[];
  for (
    var i = signalIndex - 1;
    i >= 0 && before.length < 3 && signalIndex - i <= 8;
    i--
  ) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    if (_classifyLogLine(line) != null) break;
    final payload = _stripLogMetadata(_stripLogAnsi(line));
    if (_looksLikeFlutterErrorContext(payload)) {
      before.insert(0, line);
      continue;
    }
    if (before.isNotEmpty) break;
  }
  context.addAll(before);
  for (
    var i = signalIndex + 1;
    i < lines.length && context.length < 6 && i <= signalIndex + 12;
    i++
  ) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    if (_classifyLogLine(line) != null) break;
    final payload = _stripLogMetadata(_stripLogAnsi(line));
    if (_looksLikeFlutterErrorContext(payload)) {
      context.add(line);
      continue;
    }
    if (context.isNotEmpty) break;
  }
  return context;
}

bool _looksLikeFlutterErrorContext(String payload) {
  final lower = payload.toLowerCase();
  return RegExp(r'^#\d+\s+').hasMatch(payload) ||
      payload.contains('package:') ||
      payload.contains('.dart:') ||
      lower.contains('the relevant error-causing widget was') ||
      lower.contains('when the exception was thrown') ||
      lower.contains('the following assertion was thrown') ||
      lower.contains('the following stateerror was thrown') ||
      lower.contains('the following fluttererror was thrown');
}

DateTime? _extractLogTimestamp(String line) {
  final match = RegExp(
    r'^\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[^\]]+)\]',
  ).firstMatch(line);
  if (match == null) return null;
  return DateTime.tryParse(match.group(1)!);
}

int? _extractLogLevel(String line) {
  final match = RegExp(r'\blevel=(\d+)\b').firstMatch(line);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

String _stripLogMetadata(String line) {
  var text = line.trim();
  text = text.replaceFirst(RegExp(r'^\[[^\]]+\]\s+'), '');
  text = text.replaceFirst(RegExp(r'^\[VM_STD(?:OUT|ERR)\]\s+'), '');
  if (text.startsWith('[VM_LOG]')) {
    text = text.substring('[VM_LOG]'.length).trimLeft();
    text = text.replaceFirst(RegExp(r'^\[[^\]]+\]\s+'), '');
    text = text.replaceFirst(RegExp(r'^(?:level=\d+\s+)?(?:seq=\d+\s+)?'), '');
  }
  return text.trim();
}

String _stripLogAnsi(String value) =>
    value.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');

bool _isNegatedLogError(String lower) {
  return lower.contains('no error') ||
      lower.contains('0 errors') ||
      lower.contains('without error') ||
      lower.contains('error-free') ||
      lower.contains('errortext:');
}

List<Map<String, Object?>> _logSignalMaps(
  List<_LogSignal> signals, {
  DateTime? now,
  String phase = 'session',
  String? actionCommandId,
}) {
  final effectiveNow = now ?? DateTime.now();
  return [
    for (final signal in signals)
      signal.toJson(
        now: effectiveNow,
        phase: phase,
        actionCommandId: actionCommandId,
      ),
  ];
}

class _LogSignal {
  const _LogSignal({
    required this.kind,
    required this.severity,
    required this.blocking,
    required this.message,
    required this.line,
    required this.context,
    required this.cursor,
    this.runId,
    this.timestamp,
  });

  final String kind;
  final String severity;
  final bool blocking;
  final String message;
  final String line;
  final List<String> context;
  final int cursor;
  final String? runId;
  final DateTime? timestamp;

  bool isStale(DateTime now) {
    final parsed = timestamp;
    if (parsed == null) return true;
    return now.difference(parsed) > const Duration(seconds: 30);
  }

  bool isFreshBlocking(DateTime now) => blocking && !isStale(now);

  Map<String, Object?> toJson({
    required DateTime now,
    required String phase,
    String? actionCommandId,
  }) {
    final parsed = timestamp;
    final ageMs = parsed == null ? null : now.difference(parsed).inMilliseconds;
    final stale = ageMs == null || ageMs > 30000;
    return {
      'identity': 'log:${runId ?? 'unbound'}:$cursor:$kind',
      'kind': kind,
      'severity': severity,
      'blocking': blocking,
      'message': message,
      'line': line,
      'provenance': {
        'source': 'scout_owned_runtime_log',
        'stream': _logSignalStream(line),
      },
      'phase': phase,
      'cursor': cursor,
      'logCursor': cursor,
      'actionCommandId': ?actionCommandId,
      'runId': ?runId,
      if (context.isNotEmpty) 'context': context,
      'timestamp': ?parsed?.toIso8601String(),
      'observedAt': now.toIso8601String(),
      'timestampStatus': parsed == null ? 'unavailable' : 'observed_in_log',
      'ageStatus': parsed == null ? 'unknown' : 'measured',
      'staleness': ageMs == null
          ? 'unknown'
          : stale
          ? 'stale'
          : 'fresh',
      'freshness': ageMs == null
          ? 'unknown'
          : stale
          ? 'stale'
          : 'fresh',
      'stale': stale,
      'ageMs': ?ageMs,
    };
  }
}

String _logSignalStream(String line) {
  if (line.contains('[VM_STDOUT]')) return 'vm_stdout';
  if (line.contains('[VM_STDERR]')) return 'vm_stderr';
  if (line.contains('[VM_LOG]')) return 'vm_logging';
  return 'flutter_tool_output';
}

int _currentLogCursor() {
  return _validatedScoutLogLength();
}

_LogChunk _readLogChunk(File file, {int? sinceCursor, int maxBytes = 262144}) {
  return _readValidatedScoutLogChunk(
    file,
    sinceCursor: sinceCursor,
    maxBytes: maxBytes,
  );
}

class _LogChunk {
  const _LogChunk(
    this.lines, {
    required this.startCursor,
    required this.endCursor,
    required this.observedFileLength,
    required this.truncated,
    required this.bytesRead,
    required this.pendingBytes,
  });

  final List<String> lines;
  final int startCursor;
  final int endCursor;
  final int observedFileLength;
  final bool truncated;
  final int bytesRead;
  final int pendingBytes;
}

class _LockedLogWriter {
  _LockedLogWriter(String path) : _file = _openPrivateAppendFile(path);

  final RandomAccessFile _file;
  Future<void> _chain = Future<void>.value();
  bool _closed = false;

  Future<void> write(String line) {
    if (_closed) return Future<void>.value();
    _chain = _chain.then((_) async {
      await _file.lock(FileLock.blockingExclusive);
      try {
        await _file.setPosition(await _file.length());
        await _file.writeString('$line\n');
        await _file.flush();
      } finally {
        await _file.unlock();
      }
    });
    return _chain;
  }

  Future<void> flush() => _chain;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _chain;
    await _file.close();
  }
}

String? _currentRunIdFromSession() {
  final file = File(_sessionMetaFile);
  if (!file.existsSync()) return null;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is Map ? decoded['runId']?.toString() : null;
  } catch (_) {
    return null;
  }
}

String _redactSensitiveLogText(String value) {
  var redacted = value;
  redacted = redacted.replaceAllMapped(
    RegExp(
      r'((?:wss?|https?)://(?:127\.0\.0\.1|localhost|\[::1\]):\d+/)([^/\s]+)(/ws\b)',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}<redacted>${match.group(3)}',
  );
  const names =
      r'authorization|token|access[_-]?token|refresh[_-]?token|session|cookie|api[_-]?key|mobile[_-]?id';
  redacted = redacted.replaceAllMapped(
    RegExp('("(?:$names)"\\s*:\\s*")[^"]*(")', caseSensitive: false),
    (match) => '${match.group(1)}<redacted>${match.group(2)}',
  );
  redacted = redacted.replaceAllMapped(
    RegExp("('(?:$names)'\\s*:\\s*')[^']*(')", caseSensitive: false),
    (match) => '${match.group(1)}<redacted>${match.group(2)}',
  );
  redacted = redacted.replaceAllMapped(
    RegExp(
      '((?:$names)\\s*[:=]\\s*)(?:Bearer\\s+)?'
      '[^,}\\]\\x00-\\x1f\\x7f-\\x9f\\u2028\\u2029]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}<redacted>',
  );
  redacted = redacted.replaceAllMapped(
    RegExp(
      r'(Bearer\s+)[^,}\]\x00-\x1f\x7f-\x9f\u2028\u2029]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}<redacted>',
  );
  return _escapeUnsafeLogControls(redacted);
}

/// Makes every diagnostic a single, non-forgeable record while retaining a
/// readable escaped representation of harmless whitespace and control input.
String _escapeUnsafeLogControls(String value) {
  final out = StringBuffer();
  for (final rune in value.runes) {
    switch (rune) {
      case 0x08:
        out.write(r'\b');
      case 0x09:
        out.write(r'\t');
      case 0x0a:
        out.write(r'\n');
      case 0x0c:
        out.write(r'\f');
      case 0x0d:
        out.write(r'\r');
      case 0x2028:
        out.write(r'\u2028');
      case 0x2029:
        out.write(r'\u2029');
      default:
        if (rune < 0x20 || (rune >= 0x7f && rune <= 0x9f)) {
          out
            ..write(r'\u')
            ..write(rune.toRadixString(16).padLeft(4, '0'));
        } else {
          out.writeCharCode(rune);
        }
    }
  }
  return out.toString();
}

class _LogClassification {
  const _LogClassification({
    required this.kind,
    required this.severity,
    required this.blocking,
    required this.message,
  });

  final String kind;
  final String severity;
  final bool blocking;
  final String message;
}

String get _sessionMetaFile => p.join(_sessionDir.path, 'session_meta.json');

void _ensureSessionDir() {
  _ensurePrivateDirectory(
    _sessionDir.path,
    boundary: _sessionManagedBoundary(),
    secureExistingTree: true,
  );
}
