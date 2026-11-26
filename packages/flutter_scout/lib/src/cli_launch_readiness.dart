part of 'flutter_scout_cli.dart';

// part: adaptive helper-readiness wait for launch, ensure and attach. The wait
// starts from a base window (scaled by how slow a launch's post-build phase
// was), keeps going only while the VM service answers and the app or runner
// shows progress (new log output, an isolate state change, process CPU), and
// never passes the caller's hard deadline. It only observes: it never
// resumes an isolate, retries an action or relaunches.

/// The default `--launch-timeout`; also the hard limit for attach, which has
/// no such option.
const Duration _defaultLaunchTimeout = Duration(seconds: 1200);

/// Shortest base window for a fresh launch (the former fixed window).
const Duration _launchHelperReadyMinimum = Duration(seconds: 20);

/// Longest base window, however slow the post-build phase was.
const Duration _launchHelperReadyMaximum = Duration(seconds: 120);

/// Base window when ensure or attach checks an app that is already running.
const Duration _existingAppHelperReadyWindow = Duration(seconds: 8);

/// After the base window, the wait ends once nothing progressed this long.
const Duration _helperProgressWindow = Duration(seconds: 20);

/// How often the runner/app process-tree CPU is sampled during the wait.
const Duration _helperCpuSampleInterval = Duration(seconds: 5);

/// CPU seconds per sample that count as the app or runner doing work.
const double _helperBusyCpuSeconds = 0.5;

/// Longest single helper probe (connect, getVM and getIsolate are 5 s each).
const Duration _helperProbeBudget = Duration(seconds: 15);

const Duration _helperWaitHeartbeatInterval = Duration(seconds: 15);

/// Base window for a fresh launch: at least [_launchHelperReadyMinimum], and
/// as long as the observed post-build phase (app start plus file sync) took,
/// up to [_launchHelperReadyMaximum]. A machine that needed 131 s to sync
/// files needs more than 20 s to run main().
Duration _launchHelperReadyBaseWindow({
  required DateTime? buildDoneAt,
  required DateTime? vmServiceFoundAt,
  required DateTime confirmedAt,
}) {
  final postBuildStart = buildDoneAt ?? vmServiceFoundAt;
  if (postBuildStart == null) return _launchHelperReadyMinimum;
  final postBuild = confirmedAt.difference(postBuildStart);
  if (postBuild < _launchHelperReadyMinimum) return _launchHelperReadyMinimum;
  if (postBuild > _launchHelperReadyMaximum) return _launchHelperReadyMaximum;
  return postBuild;
}

/// One passive helper check: whether the helper answers, and what the VM
/// service and main isolate showed on the way.
class _HelperProbe {
  const _HelperProbe({
    required this.ready,
    this.vmAnswered = false,
    this.isolateState,
    this.extensionCount,
    this.frameworkExtensions = false,
  });

  final _ScoutReady ready;
  final bool vmAnswered;

  /// `running`, `not_runnable`, `paused_at_start`, `paused_at_exit`,
  /// `paused`, or `no_isolate`; null when the VM service did not answer.
  final String? isolateState;
  final int? extensionCount;

  /// Flutter's own `ext.flutter.*` extensions are registered, so the binding
  /// is initialized and main() is past its first lines.
  final bool frameworkExtensions;

  String? get signature => vmAnswered
      ? '$isolateState|${extensionCount ?? ''}|$frameworkExtensions'
      : null;
}

/// What the owned run did since the last sample. Null fields are unknown
/// (attach-only sessions have neither a run log nor a process to sample).
class _HelperActivity {
  const _HelperActivity({this.logBytes, this.cpuSeconds, this.ownerAlive});

  final int? logBytes;
  final double? cpuSeconds;
  final bool? ownerAlive;
}

class _HelperWaitOutcome {
  const _HelperWaitOutcome({
    required this.ready,
    required this.stopReason,
    required this.waited,
    required this.baseWindow,
    required this.hardLimit,
    required this.extended,
    required this.lastProbe,
    required this.vmAnsweredAgo,
    required this.frameworkReadyAgo,
    required this.lastProgressKind,
    required this.lastProgressAgo,
    required this.ownerAlive,
  });

  final _ScoutReady ready;

  /// `ready`, `no_progress`, `vm_service_unresponsive`,
  /// `helper_absent_after_framework_ready`, `runner_exited` or
  /// `hard_timeout`.
  final String stopReason;
  final Duration waited;
  final Duration baseWindow;
  final Duration hardLimit;
  final bool extended;
  final _HelperProbe? lastProbe;
  final Duration? vmAnsweredAgo;
  final Duration? frameworkReadyAgo;
  final String? lastProgressKind;
  final Duration? lastProgressAgo;

  /// Whether the owned Flutter tool was alive at the last sample; null when
  /// the session has no owned process (attach-only).
  final bool? ownerAlive;

  /// The VM service still answers or the owned run is still alive, so the
  /// session record must survive this failure.
  bool get reachable => lastProbe?.vmAnswered == true || ownerAlive == true;

  Map<String, Object?> toJson() => {
    'stopReason': stopReason,
    'waitedMs': waited.inMilliseconds,
    'baseWindowMs': baseWindow.inMilliseconds,
    'hardLimitMs': hardLimit.inMilliseconds,
    'extended': extended,
    'helperCheck': ?ready.reason,
    'vmServiceAnswered': vmAnsweredAgo != null,
    if (vmAnsweredAgo != null)
      'vmServiceAnsweredAgoMs': vmAnsweredAgo!.inMilliseconds,
    'isolateState': ?lastProbe?.isolateState,
    'frameworkExtensionsRegistered': frameworkReadyAgo != null,
    'lastProgress': ?lastProgressKind,
    if (lastProgressAgo != null)
      'lastProgressAgoMs': lastProgressAgo!.inMilliseconds,
  };

  String get _seconds => '${(waited.inMilliseconds / 1000).round()}s';

  /// One sentence: how long Scout waited, what it observed, and why it
  /// stopped.
  String get evidence {
    final base = '${baseWindow.inSeconds}s';
    final waitedPart = extended
        ? 'Waited $_seconds (base window $base, extended while the app made '
              'progress)'
        : 'Waited $_seconds (base window $base)';
    final vm = vmAnsweredAgo == null
        ? 'the VM service never answered'
        : 'the VM service last answered ${_ago(vmAnsweredAgo!)}';
    final isolate = switch (lastProbe?.isolateState) {
      null => '',
      'paused_at_start' => '; the main isolate is paused at start',
      'paused_at_exit' => '; the main isolate is paused at exit',
      'no_isolate' => '; the VM reported no isolate',
      final state => '; the main isolate is $state',
    };
    final framework = frameworkReadyAgo == null
        ? ''
        : ' with Flutter framework extensions but no ext.flutter_scout';
    final progress = lastProgressKind == null
        ? '; no progress was observed'
        : '; last progress: ${lastProgressKind!.replaceAll('_', ' ')} '
              '${_ago(lastProgressAgo!)}';
    final stopped = switch (stopReason) {
      'no_progress' =>
        'Stopped: nothing progressed for ${_helperProgressWindow.inSeconds}s '
            'after the base window.',
      'vm_service_unresponsive' =>
        'Stopped: the VM service did not answer for '
            '${_helperProgressWindow.inSeconds}s after the base window.',
      'helper_absent_after_framework_ready' =>
        'Stopped: the Flutter binding started ${_ago(frameworkReadyAgo!)} '
            'but the Scout helper never registered.',
      'runner_exited' =>
        'Stopped: the owned Flutter runner exited and the VM service no '
            'longer answers.',
      'hard_timeout' => 'Stopped: reached the hard launch limit.',
      _ => 'Stopped: $stopReason.',
    };
    return '$waitedPart; $vm$isolate$framework$progress. $stopped';
  }

  String get hint => switch (stopReason) {
    'helper_absent_after_framework_ready' =>
      'Check that main() calls ${ready.expected ?? 'FlutterScoutBinding.ensureInitialized()'} '
          '(or FlutterScoutHelper.ensureRegistered() after its binding).',
    'runner_exited' =>
      'The app stopped. Read `logs --last 50` for the cause before '
          'launching again.',
    'hard_timeout' =>
      'Run status: it re-checks the helper and promotes the session to '
          'ready. Raise --launch-timeout only if the app was still starting.',
    _ =>
      'Run status: it re-checks the helper and promotes the session to '
          'ready when it answers. Do not launch --replace while the app may '
          'still be starting.',
  };
}

String _ago(Duration value) => '${(value.inMilliseconds / 1000).round()}s ago';

Future<void> _pauseFor(Duration value) => Future<void>.delayed(value);

/// Waits for the helper. Stops at the first of: the helper answers; the hard
/// deadline; the Flutter binding has been up for a base window without the
/// helper; the owned runner exited while the VM is silent; or, after the
/// base window, the VM service silent or nothing progressing for
/// [_helperProgressWindow]. Progress is a changed isolate state or
/// extension count, new run-log output, or runner/app CPU.
Future<_HelperWaitOutcome> _awaitHelperReadiness({
  required Future<_HelperProbe> Function(Duration budget) probe,
  required Future<_HelperActivity> Function({required bool sampleCpu}) activity,
  required Duration baseWindow,
  required DateTime hardDeadline,
  required void Function(String stage, Map<String, Object?> data) progress,
  DateTime Function() clock = DateTime.now,
  Future<void> Function(Duration) pause = _pauseFor,
  Duration pollInterval = const Duration(milliseconds: 250),
}) async {
  final startedAt = clock();
  final hardLimit = hardDeadline.isAfter(startedAt)
      ? hardDeadline.difference(startedAt)
      : Duration.zero;
  final effectiveBase = baseWindow > hardLimit ? hardLimit : baseWindow;
  final baseDeadline = startedAt.add(effectiveBase);
  final frameworkGrace = baseWindow > _helperProgressWindow
      ? baseWindow
      : _helperProgressWindow;
  DateTime? lastProgressAt;
  String? lastProgressKind;
  DateTime? lastVmAnswerAt;
  DateTime? frameworkReadyAt;
  String? signature;
  int? logBytes;
  double? cpuSeconds;
  DateTime? lastCpuSampleAt;
  bool? ownerAlive;
  var extended = false;
  var lastHeartbeatAt = startedAt;
  _HelperProbe? last;

  _HelperWaitOutcome outcome(String stopReason, DateTime now) =>
      _HelperWaitOutcome(
        ready:
            last?.ready ??
            const _ScoutReady(
              ready: false,
              reason: 'helper_extension_check_timeout',
              expected: 'FlutterScoutBinding.ensureInitialized()',
            ),
        stopReason: stopReason,
        waited: now.difference(startedAt),
        baseWindow: effectiveBase,
        hardLimit: hardLimit,
        extended: extended,
        lastProbe: last,
        vmAnsweredAgo: lastVmAnswerAt == null
            ? null
            : now.difference(lastVmAnswerAt),
        frameworkReadyAgo: frameworkReadyAt == null
            ? null
            : now.difference(frameworkReadyAt),
        lastProgressKind: lastProgressKind,
        lastProgressAgo: switch (lastProgressAt) {
          final DateTime at => now.difference(at),
          null => null,
        },
        ownerAlive: ownerAlive,
      );

  progress('await_helper_ready', {
    'baseWindowMs': effectiveBase.inMilliseconds,
    'hardLimitMs': hardLimit.inMilliseconds,
  });
  while (true) {
    final remaining = hardDeadline.difference(clock());
    final budget = remaining < const Duration(seconds: 1)
        ? const Duration(seconds: 1)
        : remaining > _helperProbeBudget
        ? _helperProbeBudget
        : remaining;
    _HelperProbe current;
    try {
      current = await probe(budget).timeout(budget);
    } on TimeoutException {
      current = const _HelperProbe(
        ready: _ScoutReady(
          ready: false,
          reason: 'helper_extension_check_timeout',
          expected: 'FlutterScoutBinding.ensureInitialized()',
        ),
      );
    }
    last = current;
    var now = clock();
    if (current.ready.ready) return outcome('ready', now);

    void observed(String kind) {
      lastProgressAt = now;
      lastProgressKind = kind;
    }

    if (current.vmAnswered) lastVmAnswerAt = now;
    if (current.frameworkExtensions) frameworkReadyAt ??= now;
    final currentSignature = current.signature;
    if (currentSignature != null) {
      if (signature != null && currentSignature != signature) {
        observed('isolate_state');
      }
      signature = currentSignature;
    }
    final sampleCpu =
        lastCpuSampleAt == null ||
        now.difference(lastCpuSampleAt) >= _helperCpuSampleInterval;
    final sample = await activity(sampleCpu: sampleCpu);
    ownerAlive = sample.ownerAlive;
    now = clock();
    final bytes = sample.logBytes;
    if (bytes != null) {
      if (logBytes != null && bytes > logBytes) observed('log_output');
      logBytes = bytes;
    }
    if (sampleCpu) {
      lastCpuSampleAt = now;
      final cpu = sample.cpuSeconds;
      if (cpu != null) {
        if (cpuSeconds != null && cpu - cpuSeconds >= _helperBusyCpuSeconds) {
          observed('process_cpu');
        }
        cpuSeconds = cpu;
      }
    }

    String? stop;
    if (sample.ownerAlive == false && !current.vmAnswered) {
      stop = 'runner_exited';
    } else if (!now.isBefore(hardDeadline)) {
      stop = 'hard_timeout';
    } else if (frameworkReadyAt != null &&
        now.difference(frameworkReadyAt) >= frameworkGrace) {
      stop = 'helper_absent_after_framework_ready';
    } else if (!now.isBefore(baseDeadline)) {
      if (lastVmAnswerAt == null ||
          now.difference(lastVmAnswerAt) >= _helperProgressWindow) {
        stop = 'vm_service_unresponsive';
      } else if (switch (lastProgressAt) {
        final DateTime at => now.difference(at) >= _helperProgressWindow,
        null => true,
      }) {
        stop = 'no_progress';
      } else if (!extended) {
        extended = true;
        progress('helper_wait_extended', {
          'baseWindowMs': effectiveBase.inMilliseconds,
          'lastProgress': lastProgressKind,
          'isolateState': ?current.isolateState,
        });
      }
    }
    if (stop != null) return outcome(stop, now);
    if (now.difference(lastHeartbeatAt) >= _helperWaitHeartbeatInterval) {
      lastHeartbeatAt = now;
      progress('helper_wait_heartbeat', {
        'elapsedMs': now.difference(startedAt).inMilliseconds,
        'helperCheck': ?current.ready.reason,
        'vmServiceAnswered': current.vmAnswered,
        'isolateState': ?current.isolateState,
        'lastProgress': ?lastProgressKind,
      });
    }
    await pause(pollInterval);
  }
}

String _isolateStateName(Isolate isolate) {
  final kind = isolate.pauseEvent?.kind;
  if (kind == EventKind.kPauseStart) return 'paused_at_start';
  if (kind == EventKind.kPauseExit) return 'paused_at_exit';
  if (kind != null &&
      kind != EventKind.kResume &&
      kind != EventKind.kNone &&
      kind.startsWith('Pause')) {
    return 'paused';
  }
  return isolate.runnable == false ? 'not_runnable' : 'running';
}

extension _CliLaunchReadiness on FlutterScoutCli {
  /// Connects once and reads the VM and main isolate. Never resumes,
  /// pauses or calls into the app.
  Future<_HelperProbe> _probeHelper(String uri) async {
    const expected = 'FlutterScoutBinding.ensureInitialized()';
    var vmAnswered = false;
    String? isolateState;
    try {
      final service = await _connect(uri);
      try {
        final vm = await service.getVM().timeout(const Duration(seconds: 5));
        vmAnswered = true;
        final isolates = vm.isolates ?? const <IsolateRef>[];
        final ref = isolates.firstWhere(
          (isolate) => isolate.name == 'main' && isolate.id != null,
          orElse: () => isolates.firstWhere(
            (isolate) => isolate.id != null,
            orElse: IsolateRef.new,
          ),
        );
        if (ref.id == null) {
          return const _HelperProbe(
            ready: _ScoutReady(
              ready: false,
              reason: 'helper_extension_missing',
              expected: expected,
            ),
            vmAnswered: true,
            isolateState: 'no_isolate',
          );
        }
        final isolate = await service
            .getIsolate(ref.id!)
            .timeout(const Duration(seconds: 5));
        isolateState = _isolateStateName(isolate);
        final extensions = isolate.extensionRPCs ?? const <String>[];
        if (extensions.contains('ext.flutter_scout.inspect')) {
          return _HelperProbe(
            ready: const _ScoutReady(ready: true),
            vmAnswered: true,
            isolateState: isolateState,
            extensionCount: extensions.length,
          );
        }
        return _HelperProbe(
          ready: const _ScoutReady(
            ready: false,
            reason: 'helper_extension_missing',
            expected: expected,
          ),
          vmAnswered: true,
          isolateState: isolateState,
          extensionCount: extensions.length,
          frameworkExtensions: extensions.any(
            (name) => name.startsWith('ext.flutter.'),
          ),
        );
      } finally {
        await service.dispose();
      }
    } catch (error) {
      return _HelperProbe(
        ready: _ScoutReady(
          ready: false,
          reason: 'helper_extension_check_failed',
          expected: expected,
          detail: error.toString(),
        ),
        vmAnswered: vmAnswered,
        isolateState: isolateState,
      );
    }
  }

  /// Waits for the helper at [uri] with [_awaitHelperReadiness]. [logFile]
  /// and [cpuRootPids] describe an owned run; [ownerPid] is its Flutter tool.
  Future<_HelperWaitOutcome> _waitHelperReady(
    String uri, {
    required Duration baseWindow,
    required DateTime hardDeadline,
    String? logFile,
    List<int> Function()? cpuRootPids,
    int? ownerPid,
  }) {
    return _awaitHelperReadiness(
      probe: (_) => _probeHelper(uri),
      activity: ({required bool sampleCpu}) async {
        int? bytes;
        if (logFile != null) {
          try {
            bytes = File(logFile).lengthSync();
          } on FileSystemException {
            bytes = null;
          }
        }
        double? cpu;
        if (sampleCpu && cpuRootPids != null) {
          for (final pid in cpuRootPids()) {
            final seconds = await _processTreeCpuSeconds(pid);
            if (seconds != null) cpu = (cpu ?? 0) + seconds;
          }
        }
        return _HelperActivity(
          logBytes: bytes,
          cpuSeconds: cpu,
          ownerAlive: ownerPid == null ? null : await _processExists(ownerPid),
        );
      },
      baseWindow: baseWindow,
      hardDeadline: hardDeadline,
      progress: _writeProgress,
    );
  }
}

extension _CliExistingAppReadiness on FlutterScoutCli {
  /// The same wait for an app that is already running (ensure reuse,
  /// attach): an [_existingAppHelperReadyWindow] base, and the run log and
  /// process CPU as progress only when this session owns the run.
  Future<_HelperWaitOutcome> _waitExistingAppHelperReady(
    String uri, {
    required Duration hardLimit,
  }) async {
    final meta = _readSessionMeta();
    final pid = _readPid() ?? int.tryParse('${meta?['pid'] ?? ''}');
    final owned = pid != null && await _matchesOwnedFlutterRun(pid, meta);
    final logFile = meta?['logFile']?.toString();
    return _waitHelperReady(
      uri,
      baseWindow: _existingAppHelperReadyWindow,
      hardDeadline: DateTime.now().add(hardLimit),
      logFile: owned && logFile != null && logFile.isNotEmpty ? logFile : null,
      cpuRootPids: owned ? () => [pid, ?_recordedMacosAppPid()] : null,
      ownerPid: owned ? pid : null,
    );
  }
}

extension FlutterScoutCliLaunchReadinessTesting on FlutterScoutCli {
  Duration debugLaunchHelperReadyBaseWindow({
    required DateTime? buildDoneAt,
    required DateTime? vmServiceFoundAt,
    required DateTime confirmedAt,
  }) => _launchHelperReadyBaseWindow(
    buildDoneAt: buildDoneAt,
    vmServiceFoundAt: vmServiceFoundAt,
    confirmedAt: confirmedAt,
  );

  /// Runs the real wait loop against scripted probes and a fake clock.
  /// [probes] and [activity] receive the elapsed time since the wait began.
  Future<Map<String, Object?>> debugAwaitHelperReadiness({
    required Map<String, Object?> Function(Duration elapsed) probes,
    required Map<String, Object?> Function(Duration elapsed) activity,
    required Duration baseWindow,
    required Duration hardLimit,
    List<String>? progressStages,
  }) async {
    final start = DateTime.utc(2026, 11, 26);
    var now = start;
    final outcome = await _awaitHelperReadiness(
      probe: (_) async {
        final value = probes(now.difference(start));
        // A probe takes time on the clock; one second keeps the loop honest.
        now = now.add(const Duration(seconds: 1));
        final ready = value['ready'] == true;
        return _HelperProbe(
          ready: _ScoutReady(
            ready: ready,
            reason: ready
                ? null
                : value['reason']?.toString() ?? 'helper_extension_missing',
            expected: 'FlutterScoutBinding.ensureInitialized()',
          ),
          vmAnswered: value['vmAnswered'] == true,
          isolateState: value['isolateState']?.toString(),
          extensionCount: value['extensionCount'] as int?,
          frameworkExtensions: value['frameworkExtensions'] == true,
        );
      },
      activity: ({required bool sampleCpu}) async {
        final value = activity(now.difference(start));
        return _HelperActivity(
          logBytes: value['logBytes'] as int?,
          cpuSeconds: sampleCpu
              ? (value['cpuSeconds'] as num?)?.toDouble()
              : null,
          ownerAlive: value['ownerAlive'] as bool?,
        );
      },
      baseWindow: baseWindow,
      hardDeadline: start.add(hardLimit),
      progress: (stage, _) => progressStages?.add(stage),
      clock: () => now,
      pause: (value) async => now = now.add(value),
    );
    return {
      'ready': outcome.ready.ready,
      ...outcome.toJson(),
      'reachable': outcome.reachable,
      'evidence': outcome.evidence,
      'hint': outcome.hint,
    };
  }
}
