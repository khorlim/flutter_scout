part of 'flutter_scout_cli.dart';

// part: batch mode — run a scripted sequence of commands in ONE process over
// ONE VM-service connection. Each separate `flutter-scout` invocation pays
// ~0.5-1.5s of process + WebSocket startup, and the gaps between invocations
// are where timing-sensitive UI (auto-reverting admin views, short-lived
// toasts) drifts away. A batch removes both.

const int _maxBatchReplayFileBytes = 1024 * 1024;
const int _maxBatchCommands = 256;
const int _maxBatchCommandBytes = 64 * 1024;
const int _maxBatchArgumentsPerCommand = 256;
const int _maxBatchReplayStringBytes = 256 * 1024;
const int _maxReplayActions = 256;
const int _maxReplayJsonDepth = 32;
const int _maxReplayJsonNodes = 8192;
const String _boundedBatchFileIngressKey = 'batch:bounded-file';

const Set<String> _batchCommandAllowlist = <String>{
  'inspect',
  'where',
  'locate',
  'reveal',
  'bounds',
  'tap',
  'tap-text',
  'long-press',
  'input',
  'fill',
  'scroll',
  'swipe',
  'scroll-to',
  'back',
  'dismiss',
  'wait',
  'wait-for',
  'health',
  'deeplink',
};

const Set<String> _batchMutationCommands = <String>{
  'reveal',
  'tap',
  'tap-text',
  'long-press',
  'input',
  'fill',
  'scroll',
  'swipe',
  'scroll-to',
  'back',
  'dismiss',
  'deeplink',
};

class _BatchPlan {
  const _BatchPlan({required this.commands, required this.arguments});

  final List<String> commands;
  final List<List<String>> arguments;
}

extension _CliBoundedCommandInput on FlutterScoutCli {
  /// Reads caller-owned scripts without following a final symlink and without
  /// ever allocating from an untrusted declared size. The second length/type
  /// check rejects files changed while they were being sampled.
  String _readBoundedCommandFile(String path, {required String kind}) {
    final code = kind.replaceAll('-', '_');
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw ScoutCliException(
        '${code}_missing',
        'The $kind file does not exist.',
      );
    }
    if (type != FileSystemEntityType.file) {
      throw ScoutCliException(
        '${code}_not_regular',
        'The $kind input must be a regular file, never a symbolic link.',
      );
    }

    final file = File(path);
    RandomAccessFile? handle;
    try {
      handle = file.openSync(mode: FileMode.read);
      final length = handle.lengthSync();
      if (length > _maxBatchReplayFileBytes) {
        throw ScoutCliException(
          '${code}_too_large',
          'The $kind input exceeds the $_maxBatchReplayFileBytes-byte limit.',
        );
      }
      final bytes = handle.readSync(length);
      handle.setPositionSync(0);
      final confirmation = handle.readSync(length);
      final finalLength = handle.lengthSync();
      final finalType = FileSystemEntity.typeSync(path, followLinks: false);
      if (bytes.length != length ||
          confirmation.length != length ||
          !_sameBoundedBytes(bytes, confirmation) ||
          finalLength != length ||
          finalType != FileSystemEntityType.file) {
        throw ScoutCliException(
          '${code}_changed_during_read',
          'The $kind input changed while Scout was reading it. Nothing was dispatched.',
        );
      }
      try {
        return utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        throw ScoutCliException(
          '${code}_invalid_utf8',
          'The $kind input must contain strictly valid UTF-8.',
        );
      }
    } on ScoutCliException {
      rethrow;
    } on FileSystemException {
      throw ScoutCliException(
        '${code}_read_failed',
        'The $kind input could not be read as one stable regular file.',
      );
    } finally {
      try {
        handle?.closeSync();
      } on FileSystemException {
        // A read-only close failure must not replace the deterministic typed
        // validation error that caused this cleanup path.
      }
    }
  }

  bool _sameBoundedBytes(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }

  void _validateBoundedJsonText(String source, {required String kind}) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    var stringCodeUnits = 0;
    for (final unit in source.codeUnits) {
      if (inString) {
        if (escaped) {
          escaped = false;
          stringCodeUnits += 1;
        } else if (unit == 0x5c) {
          escaped = true;
        } else if (unit == 0x22) {
          inString = false;
          stringCodeUnits = 0;
        } else {
          stringCodeUnits += 1;
          if (stringCodeUnits > _maxBatchReplayStringBytes) {
            throw ScoutCliException(
              '${kind}_string_too_large',
              'A $kind JSON string exceeds the per-string bound.',
            );
          }
        }
        continue;
      }
      if (unit == 0x22) {
        inString = true;
      } else if (unit == 0x7b || unit == 0x5b) {
        depth += 1;
        if (depth > _maxReplayJsonDepth) {
          throw ScoutCliException(
            '${kind}_too_deep',
            '$kind JSON nesting exceeds the $_maxReplayJsonDepth-level limit.',
          );
        }
      } else if (unit == 0x7d || unit == 0x5d) {
        depth -= 1;
        if (depth < 0) break;
      }
    }
  }

  void _validateBoundedJsonValue(Object? root, {required String kind}) {
    final pending = <({Object? value, int depth})>[(value: root, depth: 0)];
    var nodes = 0;
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      nodes += 1;
      if (nodes > _maxReplayJsonNodes) {
        throw ScoutCliException(
          '${kind}_too_many_nodes',
          '$kind JSON exceeds the $_maxReplayJsonNodes-node limit.',
        );
      }
      if (current.depth > _maxReplayJsonDepth) {
        throw ScoutCliException(
          '${kind}_too_deep',
          '$kind JSON nesting exceeds the $_maxReplayJsonDepth-level limit.',
        );
      }
      final value = current.value;
      if (value is String) {
        if (!_isWellFormedUnicode(value) ||
            utf8.encode(value).length > _maxBatchReplayStringBytes) {
          throw ScoutCliException(
            '${kind}_invalid_string',
            '$kind contains malformed Unicode or an oversized string.',
          );
        }
      } else if (value is Map) {
        for (final entry in value.entries) {
          if (entry.key is! String) {
            throw ScoutCliException(
              '${kind}_invalid_key',
              '$kind JSON object keys must be strings.',
            );
          }
          pending.add((value: entry.key, depth: current.depth + 1));
          pending.add((value: entry.value, depth: current.depth + 1));
        }
      } else if (value is Iterable) {
        for (final child in value) {
          pending.add((value: child, depth: current.depth + 1));
        }
      } else if (value is num && !value.isFinite) {
        throw ScoutCliException(
          '${kind}_invalid_number',
          '$kind contains a non-finite number.',
        );
      } else if (value != null && value is! bool && value is! num) {
        throw ScoutCliException(
          '${kind}_invalid_value',
          '$kind contains an unsupported value type.',
        );
      }
    }
  }
}

extension _CliBatch on FlutterScoutCli {
  Future<int> _batch(List<String> args) async {
    final parser = ArgParser()
      ..addOption('file', help: 'Read commands from a file, one per line.')
      ..addFlag(
        'verbose',
        defaultsTo: false,
        negatable: false,
        help: 'Print each step output instead of one compact final timeline.',
      )
      ..addFlag(
        'keep-going',
        defaultsTo: false,
        negatable: false,
        help: 'Continue running remaining steps after a failed one.',
      );
    _addReplayVariableOptions(parser);
    final parsed = parser.parse(args);
    final filePath = parsed.option('file');
    if (filePath != null && parsed.rest.isNotEmpty) {
      throw const ScoutCliException(
        'batch_input_conflict',
        'Use either `batch --file <path>` or one inline script, not both.',
      );
    }
    final String script;
    if (filePath != null && filePath.isNotEmpty) {
      script =
          _protectedSecretIngress[_boundedBatchFileIngressKey] ??
          _readBoundedCommandFile(filePath, kind: 'batch-file');
    } else {
      if (parsed.rest.isEmpty) {
        throw const ScoutCliException(
          'usage',
          "Usage: flutter-scout batch 'tap btn.save; wait-for --text Saved' "
              'or flutter-scout batch --file <script>',
        );
      }
      script = parsed.rest.join(' ');
    }
    final vars = _replayVariablesFromSources(parsed);
    final plan = _preflightBatchScript(script, vars);
    final commands = plan.commands;
    final resolvedCommands = plan.arguments;
    final callerIdempotencyScope = _activeCallerIdempotencyKey;
    final batchIdempotencyScope =
        callerIdempotencyScope ?? _newProtocolIdentifier('batch');

    // Save/restore so a batch nested under `serve` (which holds the cached
    // connection for its whole lifetime) does not tear the connection down.
    final hadReuse = _reuseVmConnection;
    final hadSuppressedOutput = _suppressActionOutput;
    final outputStart = _suppressedActionResults.length;
    _reuseVmConnection = true;
    // Always collect the exact nested response so aggregate safety semantics
    // never depend on presentation mode. Verbose mode prints the collected
    // response after assessment instead of bypassing assessment entirely.
    _suppressActionOutput = true;
    final failed = <Map<String, Object?>>[];
    final stepTimingsMs = <int>[];
    final timeline = <Map<String, Object?>>[];
    var ranSteps = 0;
    var commandFailureSteps = 0;
    var mutationSteps = 0;
    var verifiedMutationSteps = 0;
    var unassertedMutationSteps = 0;
    var failedMutationSteps = 0;
    try {
      for (var i = 0; i < commands.length; i++) {
        final argv = resolvedCommands[i];
        if (argv.isEmpty) continue;
        if (argv.first == 'batch') {
          throw const ScoutCliException(
            'usage',
            'Nested batch commands are not supported.',
          );
        }
        if (parsed.flag('verbose')) {
          _writeHeartbeat('batch_step_started', <String, Object?>{
            'step': i + 1,
            'of': commands.length,
            'cmd': commands[i],
          }, false);
        }
        ranSteps += 1;
        final stepOutputStart = _suppressedActionResults.length;
        final stopwatch = Stopwatch()..start();
        final stepKey = _derivedStepIdempotencyKey(
          scope: batchIdempotencyScope,
          step: i,
          businessRequest: <String, Object?>{'kind': 'batch', 'argv': argv},
        );
        final code = await run(<String>['--idempotency-key', stepKey, ...argv]);
        final elapsedMs = stopwatch.elapsedMilliseconds;
        stepTimingsMs.add(elapsedMs);
        final outputs = _suppressedActionResults.sublist(stepOutputStart);
        if (parsed.flag('verbose')) {
          for (final output in outputs) {
            _printJson(output, success: output['ok'] == true);
          }
        }
        final mutation = _batchMutationCommands.contains(argv.first);
        final assessments = <_ReplayOutcomeAssessment>[
          for (final output in outputs)
            if (output.containsKey('dispatch'))
              _assessReplayOutcome(Map<String, Object?>.from(output)),
        ];
        final mutationOutcomeMissing = mutation && assessments.isEmpty;
        final mutationOutcomeFailed =
            mutationOutcomeMissing ||
            assessments.any((assessment) => !assessment.accepted);
        final mutationVerified =
            mutation &&
            !mutationOutcomeFailed &&
            assessments.isNotEmpty &&
            assessments.every(
              (assessment) => assessment.businessSuccessClaimed,
            );
        if (code != 0) commandFailureSteps += 1;
        if (mutation) {
          mutationSteps += 1;
          if (mutationOutcomeFailed) {
            failedMutationSteps += 1;
          } else if (mutationVerified) {
            verifiedMutationSteps += 1;
          } else {
            unassertedMutationSteps += 1;
          }
        }
        final effectiveExitCode = code != 0 || mutationOutcomeFailed ? 1 : 0;
        timeline.add({
          'step': i + 1,
          'cmd': commands[i],
          'exitCode': effectiveExitCode,
          if (effectiveExitCode != code) 'commandExitCode': code,
          'elapsedMs': elapsedMs,
          if (mutation) 'mutation': true,
          if (mutationOutcomeMissing) 'outcomeStatus': 'outcome_incomplete',
          if (assessments.length == 1) 'outcome': assessments.single.toJson(),
          if (assessments.length > 1)
            'outcomes': [
              for (final assessment in assessments) assessment.toJson(),
            ],
          if (outputs.length == 1) 'result': _compactBatchStep(outputs.single),
          if (outputs.length > 1)
            'results': [
              for (final output in outputs) _compactBatchStep(output),
            ],
          if (outputs.isEmpty && !parsed.flag('verbose'))
            'result': {'summary': 'Command emitted no compact action result.'},
        });
        if (effectiveExitCode != 0) {
          failed.add({
            'step': i + 1,
            'cmd': commands[i],
            'exitCode': effectiveExitCode,
            'commandExitCode': code,
            if (mutationOutcomeMissing) 'outcomeStatus': 'outcome_incomplete',
            if (assessments.isNotEmpty)
              'outcomeStatuses': [
                for (final assessment in assessments) assessment.status,
              ],
          });
          if (!parsed.flag('keep-going')) break;
        }
      }
    } finally {
      _reuseVmConnection = hadReuse;
      _suppressActionOutput = hadSuppressedOutput;
      if (!hadReuse) await _disposeCachedVmService();
    }
    final accepted = failed.isEmpty && ranSteps == commands.length;
    final commandCompleted =
        commandFailureSteps == 0 && ranSteps == commands.length;
    final businessSuccessClaimed =
        accepted && mutationSteps > 0 && verifiedMutationSteps == mutationSteps;
    final verdict = !accepted
        ? 'failed'
        : businessSuccessClaimed
        ? 'verified'
        : mutationSteps == 0
        ? 'completed_non_mutating'
        : 'completed_unasserted';
    _printJson({
      'ok': accepted,
      'okMeaning': 'all_batch_outcomes_accepted',
      'verdict': verdict,
      'commandCompleted': commandCompleted,
      'businessSuccessClaimed': businessSuccessClaimed,
      'batch': true,
      'steps': commands.length,
      'ranSteps': ranSteps,
      'failedSteps': failed.length,
      'commandFailureSteps': commandFailureSteps,
      'mutationSteps': mutationSteps,
      'verifiedMutationSteps': verifiedMutationSteps,
      'unassertedMutationSteps': unassertedMutationSteps,
      'failedMutationSteps': failedMutationSteps,
      if (failed.isNotEmpty) 'failed': failed,
      'stepTimingsMs': stepTimingsMs,
      if (!parsed.flag('verbose')) 'timeline': timeline,
      'totalMs': stepTimingsMs.fold<int>(0, (sum, ms) => sum + ms),
      'stoppedEarly': ranSteps < commands.length,
      'idempotency': <String, Object?>{
        'perStepKeys': 'deterministic_sha256_derivation',
        'scopeKeySource': callerIdempotencyScope == null
            ? 'generated'
            : 'caller',
        'scopeKeyDigest': _idempotencyKeyDigest(batchIdempotencyScope),
      },
      if (callerIdempotencyScope == null)
        'idempotencyScopeKey': batchIdempotencyScope,
      if (failed.isNotEmpty)
        'error': <String, Object?>{
          'code': 'batch_step_failed',
          'message': '${failed.length} batch step(s) failed.',
        },
    }, success: accepted);
    if (_suppressedActionResults.length > outputStart) {
      _suppressedActionResults.removeRange(
        outputStart,
        _suppressedActionResults.length,
      );
    }
    return accepted ? 0 : 1;
  }

  _BatchPlan _preflightBatchScript(
    String script,
    Map<String, String> variables,
  ) {
    if (!_isWellFormedUnicode(script) ||
        utf8.encode(script).length > _maxBatchReplayFileBytes ||
        script.codeUnits.any((unit) => unit == 0)) {
      throw const ScoutCliException(
        'batch_script_invalid',
        'A batch script must be well-formed Unicode, contain no NUL byte, and fit the 1 MiB limit.',
      );
    }
    _assertBalancedBatchQuotes(script);
    final commands = FlutterScoutCli.splitBatchScript(script);
    if (commands.isEmpty) {
      throw const ScoutCliException(
        'batch_empty',
        'Batch script has no commands.',
      );
    }
    if (commands.length > _maxBatchCommands) {
      throw const ScoutCliException(
        'batch_too_many_commands',
        'Batch scripts are limited to $_maxBatchCommands commands.',
      );
    }

    final rawArguments = <List<String>>[];
    for (var index = 0; index < commands.length; index++) {
      final command = commands[index];
      if (utf8.encode(command).length > _maxBatchCommandBytes) {
        throw ScoutCliException(
          'batch_command_too_large',
          'Batch step ${index + 1} exceeds the $_maxBatchCommandBytes-byte command limit.',
          additional: <String, Object?>{'step': index + 1},
        );
      }
      final argv = FlutterScoutCli.splitCommandLine(command);
      if (argv.isEmpty || argv.length > _maxBatchArgumentsPerCommand) {
        throw ScoutCliException(
          'batch_command_invalid',
          'Batch step ${index + 1} is empty or has too many arguments.',
          additional: <String, Object?>{'step': index + 1},
        );
      }
      final name = argv.first;
      if (!_batchCommandAllowlist.contains(name)) {
        throw ScoutCliException(
          'batch_command_forbidden',
          'Batch step ${index + 1} uses `$name`, which is not an allowlisted UI command. Lifecycle, infrastructure, and recursive commands must run separately.',
          additional: <String, Object?>{
            'step': index + 1,
            'command': name,
            'allowedCommands': _batchCommandAllowlist.toList()..sort(),
          },
        );
      }
      _validateBatchPlaceholderScope(argv, step: index + 1);
      rawArguments.add(argv);
    }

    // Missing protected values and every late command/schema error are closed
    // before the first nested run can reach a VM service.
    _requireRecordVariables(rawArguments, variables);
    final resolved = <List<String>>[];
    for (var index = 0; index < rawArguments.length; index++) {
      final argv = _resolveBatchArguments(rawArguments[index], variables);
      _validateBatchArgumentBounds(argv, step: index + 1);
      _validateBatchCommand(argv, step: index + 1);
      resolved.add(argv);
    }
    return _BatchPlan(commands: commands, arguments: resolved);
  }

  void _assertBalancedBatchQuotes(String script) {
    var inSingle = false;
    var inDouble = false;
    var escaped = false;
    for (final unit in script.codeUnits) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (inDouble && unit == 0x5c) {
        escaped = true;
      } else if (!inDouble && unit == 0x27) {
        inSingle = !inSingle;
      } else if (!inSingle && unit == 0x22) {
        inDouble = !inDouble;
      }
    }
    if (inSingle || inDouble || escaped) {
      throw const ScoutCliException(
        'batch_unterminated_quote',
        'Batch scripts must close every quote and double-quoted escape before execution.',
      );
    }
  }

  void _validateBatchArgumentBounds(List<String> argv, {required int step}) {
    if (argv.length > _maxBatchArgumentsPerCommand ||
        argv.any(
          (value) =>
              !_isWellFormedUnicode(value) ||
              utf8.encode(value).length > _maxBatchReplayStringBytes,
        )) {
      throw ScoutCliException(
        'batch_argument_bounds_exceeded',
        'Batch step $step exceeds the argument count or per-string bound.',
        additional: <String, Object?>{'step': step},
      );
    }
  }

  void _validateBatchPlaceholderScope(List<String> argv, {required int step}) {
    final command = argv.first;
    final parser = _batchParserFor(command);
    final parsed = _parseBatchArguments(parser, argv.skip(1).toList(), step);
    final optionPlaceholders = <String>[
      for (final name in parsed.options)
        if (name != 'json') ..._recordVariableOccurrences(parsed[name]),
    ];
    final positionalPlaceholders = _recordVariableOccurrences(parsed.rest);

    if (command == 'input') {
      if (optionPlaceholders.isEmpty) return;
    } else if (command == 'fill') {
      final raw = parsed.option('json');
      if (raw != null) {
        try {
          _validateBoundedJsonText(raw, kind: 'batch_fill');
          final decoded = jsonDecode(raw);
          final keyPlaceholders = decoded is Map
              ? <String>[
                  for (final key in decoded.keys)
                    ..._recordVariableOccurrences(key),
                ]
              : const <String>[];
          if (optionPlaceholders.isEmpty &&
              positionalPlaceholders.isEmpty &&
              keyPlaceholders.isEmpty) {
            return;
          }
        } on ScoutCliException {
          rethrow;
        } on FormatException {
          // Malformed JSON receives its command-schema error in the complete
          // command validation pass below. It cannot authorize a placeholder.
          return;
        }
      }
    } else if (optionPlaceholders.isEmpty && positionalPlaceholders.isEmpty) {
      return;
    }
    throw ScoutCliException(
      'batch_placeholder_scope_invalid',
      'Batch step $step may use replay placeholders only as an input value or inside `fill --json` values.',
      additional: <String, Object?>{
        'step': step,
        'command': command,
        'dispatch': 'not_dispatched',
      },
    );
  }

  List<String> _recordVariableOccurrences(Object? value) {
    final names = <String>[];
    void visit(Object? child) {
      if (_isRecordVariable(child)) {
        names.add(_recordVariableName(child! as String));
      } else if (child is Map) {
        for (final nested in child.values) {
          visit(nested);
        }
      } else if (child is Iterable) {
        for (final nested in child) {
          visit(nested);
        }
      }
    }

    visit(value);
    return names;
  }

  void _validateBatchCommand(List<String> argv, {required int step}) {
    final command = argv.first;
    final parsed = _parseBatchArguments(
      _batchParserFor(command),
      argv.skip(1).toList(growable: false),
      step,
    );
    try {
      switch (command) {
        case 'inspect':
          final maxItems = parsed.option('max-items');
          if (maxItems != null) {
            _batchBoundedInt(maxItems, 1, 100, '--max-items');
          }
          final since = parsed.option('since');
          if (since != null &&
              since.isNotEmpty &&
              (parsed.flag('brief') ||
                  parsed.flag('surface') ||
                  (parsed.option('sections') ?? '').isNotEmpty ||
                  maxItems != null)) {
            throw const ScoutCliException(
              'batch_command_schema_invalid',
              '`inspect --since` cannot be combined with compact/full-section options.',
            );
          }
          _batchBoundedInt(
            parsed.option('max-response-bytes')!,
            4096,
            1048576,
            '--max-response-bytes',
          );
          if (parsed.rest.isNotEmpty) {
            throw const ScoutCliException(
              'batch_command_schema_invalid',
              '`inspect` accepts no positional arguments.',
            );
          }
        case 'where':
          _batchBoundedInt(
            parsed.option('max-response-bytes')!,
            4096,
            1048576,
            '--max-response-bytes',
          );
          if (parsed.rest.isNotEmpty) {
            throw const ScoutCliException(
              'batch_command_schema_invalid',
              '`where` accepts no positional arguments.',
            );
          }
        case 'locate':
          _validateBatchLocate(parsed, mutating: false);
        case 'reveal':
          _validateBatchLocate(parsed, mutating: true);
        case 'bounds':
          if (parsed.rest.length > 1 ||
              (parsed.option('target') != null && parsed.rest.isNotEmpty)) {
            throw const ScoutCliException(
              'batch_command_schema_invalid',
              '`bounds` accepts at most one target source.',
            );
          }
        case 'tap':
          _validateBatchTap(parsed);
        case 'tap-text':
          final option = parsed.option('text');
          if ((option == null || option.isEmpty) == parsed.rest.isEmpty) {
            throw const ScoutCliException(
              'batch_command_schema_invalid',
              '`tap-text` needs exactly one positional or --text source.',
            );
          }
          _validateBatchExpectations(parsed);
        case 'long-press':
          _validateBatchTargetOrCoordinates(parsed, command: command);
          _batchBoundedInt(
            parsed.option('duration-ms')!,
            1,
            60000,
            '--duration-ms',
          );
        case 'input':
          if (parsed.option('file') != null || parsed.flag('stdin')) {
            throw const ScoutCliException(
              'batch_nested_secret_source_forbidden',
              'Batch input must use a batch-level --var-file/--var-stdin placeholder, not a nested file or stdin source.',
            );
          }
          if (parsed.rest.isEmpty) {
            throw const ScoutCliException(
              'batch_command_schema_invalid',
              '`input` requires one positional value or placeholder.',
            );
          }
          _validateBatchExpectations(parsed);
        case 'fill':
          if (parsed.option('file') != null || parsed.flag('stdin')) {
            throw const ScoutCliException(
              'batch_nested_secret_source_forbidden',
              'Batch fill must use batch-level variables inside --json, not a nested file or stdin source.',
            );
          }
          final raw = parsed.option('json');
          if (raw == null || parsed.rest.isNotEmpty) {
            throw const ScoutCliException(
              'batch_command_schema_invalid',
              '`fill` requires exactly one --json object in batch mode.',
            );
          }
          _validateBoundedJsonText(raw, kind: 'batch_fill');
          final decoded = jsonDecode(raw);
          _validateBoundedJsonValue(decoded, kind: 'batch_fill');
          if (decoded is! Map ||
              decoded.isEmpty ||
              decoded.keys.any(
                (key) => key is! String || key.toString().isEmpty,
              ) ||
              decoded.values.any((value) => value is! String)) {
            throw const ScoutCliException(
              'batch_command_schema_invalid',
              '`fill --json` must contain a non-empty string-to-string JSON object with non-empty keys.',
            );
          }
          _validateBatchExpectations(parsed);
        case 'scroll':
        case 'swipe':
          if (parsed.rest.length > 1 ||
              (parsed.rest.isNotEmpty &&
                  !const {
                    'up',
                    'down',
                    'left',
                    'right',
                  }.contains(parsed.rest.single))) {
            throw const ScoutCliException(
              'batch_command_schema_invalid',
              'Scroll/swipe direction must be one of up, down, left, or right.',
            );
          }
          _batchFiniteOption(parsed.option('distance'), '--distance');
          _batchFiniteOption(parsed.option('x'), '--x');
          _batchFiniteOption(parsed.option('y'), '--y');
        case 'scroll-to':
          if (parsed.rest.length != 1 || parsed.rest.single.isEmpty) {
            throw const ScoutCliException(
              'batch_command_schema_invalid',
              '`scroll-to` requires exactly one target.',
            );
          }
          _batchBoundedInt(
            parsed.option('max-scrolls')!,
            1,
            100,
            '--max-scrolls',
          );
          final direction = parsed.option('direction');
          if (direction != null &&
              !const {'up', 'down', 'left', 'right'}.contains(direction)) {
            throw const ScoutCliException(
              'batch_command_schema_invalid',
              '`scroll-to --direction` is invalid.',
            );
          }
          _batchFiniteOption(parsed.option('distance'), '--distance');
        case 'back':
        case 'health':
          if (parsed.rest.isNotEmpty) {
            throw ScoutCliException(
              'batch_command_schema_invalid',
              '`$command` accepts no positional arguments.',
            );
          }
        case 'dismiss':
          _batchBoundedInt(parsed.option('wait-ms')!, 0, 60000, '--wait-ms');
          if (parsed.rest.isNotEmpty) {
            throw const ScoutCliException(
              'batch_command_schema_invalid',
              '`dismiss` accepts no positional arguments.',
            );
          }
        case 'wait':
          if (parsed.rest.isNotEmpty &&
              (parsed.rest.length != 1 || parsed.rest.single != 'stable')) {
            throw const ScoutCliException(
              'batch_command_schema_invalid',
              '`wait` accepts only the optional positional word `stable`.',
            );
          }
          _batchBoundedInt(parsed.option('timeout')!, 0, 120000, '--timeout');
        case 'wait-for':
          final conditions = <Object?>[
            parsed.option('text'),
            parsed.option('gone'),
            parsed.option('target'),
            parsed.option('selected'),
            parsed.option('screen'),
            parsed.option('view'),
            parsed.option('field'),
            if (parsed.rest.isNotEmpty) parsed.rest.join(' '),
          ].where((value) => value?.toString().isNotEmpty == true);
          if (conditions.isEmpty) {
            throw const ScoutCliException(
              'batch_command_schema_invalid',
              '`wait-for` requires at least one explicit condition.',
            );
          }
          _batchBoundedInt(parsed.option('timeout')!, 1, 120000, '--timeout');
          _batchBoundedInt(parsed.option('poll')!, 1, 10000, '--poll');
        case 'deeplink':
          if (parsed.rest.length != 1) {
            throw const ScoutCliException(
              'batch_command_schema_invalid',
              '`deeplink` requires exactly one URI.',
            );
          }
          _validateDeeplinkUrl(parsed.rest.single);
      }
    } on ScoutCliException catch (error) {
      throw ScoutCliException(
        error.code,
        'Batch step $step failed preflight: ${error.message}',
        details: error.details,
        additional: <String, Object?>{
          ...error.additional,
          'step': step,
          'command': command,
          'dispatch': 'not_dispatched',
        },
      );
    } on FormatException {
      throw ScoutCliException(
        'batch_command_schema_invalid',
        'Batch step $step contains malformed JSON. Nothing was dispatched.',
        additional: <String, Object?>{
          'step': step,
          'command': command,
          'dispatch': 'not_dispatched',
        },
      );
    }
  }

  ArgResults _parseBatchArguments(
    ArgParser parser,
    List<String> args,
    int step,
  ) {
    try {
      return parser.parse(args);
    } on FormatException {
      throw ScoutCliException(
        'batch_command_schema_invalid',
        'Batch step $step contains an unknown, duplicated, or incomplete option. Nothing was dispatched.',
        additional: <String, Object?>{
          'step': step,
          'dispatch': 'not_dispatched',
        },
      );
    }
  }

  ArgParser _batchParserFor(String command) {
    switch (command) {
      case 'inspect':
        return ArgParser()
          ..addFlag('brief', defaultsTo: false)
          ..addFlag('surface', defaultsTo: false)
          ..addOption('max-items')
          ..addOption('sections')
          ..addOption('since')
          ..addOption('max-response-bytes', defaultsTo: '65536')
          ..addFlag('include-stale', defaultsTo: false);
      case 'where':
        return ArgParser()
          ..addOption('max-response-bytes', defaultsTo: '65536');
      case 'locate':
        return ArgParser()
          ..addOption('text')
          ..addOption('target')
          ..addOption('within')
          ..addFlag('contains', defaultsTo: false, negatable: false)
          ..addOption('max-candidates', defaultsTo: '20')
          ..addOption('max-response-bytes', defaultsTo: '65536');
      case 'reveal':
        return ArgParser()
          ..addOption('text')
          ..addOption('target')
          ..addOption('within')
          ..addOption(
            'direction',
            defaultsTo: 'down',
            allowed: const <String>['up', 'down', 'left', 'right'],
          )
          ..addOption('max-actions', defaultsTo: '8')
          ..addOption('distance')
          ..addOption('max-distance')
          ..addOption('timeout', defaultsTo: '8000')
          ..addFlag('contains', defaultsTo: false, negatable: false)
          ..addOption('max-response-bytes', defaultsTo: '65536')
          ..addFlag('allow-errors', defaultsTo: false, negatable: false);
      case 'bounds':
        return ArgParser()..addOption('target');
      case 'tap':
        final parser = ArgParser()
          ..addOption('x')
          ..addOption('y')
          ..addOption('wait-ms', defaultsTo: '1500')
          ..addFlag('verbose', defaultsTo: false);
        _CliActions._addExpectOptions(parser);
        return parser;
      case 'tap-text':
        final parser = ArgParser()
          ..addOption('text')
          ..addOption('wait-ms', defaultsTo: '1500')
          ..addFlag('allow-mismatch', defaultsTo: false, negatable: false)
          ..addFlag('contains', defaultsTo: false, negatable: false)
          ..addFlag('verbose', defaultsTo: false);
        _CliActions._addExpectOptions(parser);
        return parser;
      case 'long-press':
        final parser = ArgParser()
          ..addOption('duration-ms', defaultsTo: '600')
          ..addOption('x')
          ..addOption('y')
          ..addFlag('verbose', defaultsTo: false);
        _CliActions._addAllowErrorsOption(parser);
        return parser;
      case 'input':
        final parser = ArgParser()
          ..addOption('target')
          ..addOption('file')
          ..addFlag('stdin', defaultsTo: false, negatable: false)
          ..addFlag('verbose', defaultsTo: false);
        _CliActions._addExpectOptions(parser);
        return parser;
      case 'fill':
        final parser = ArgParser()
          ..addOption('json')
          ..addOption('file')
          ..addFlag('stdin', defaultsTo: false, negatable: false)
          ..addFlag('verbose', defaultsTo: false);
        _CliActions._addExpectOptions(parser);
        return parser;
      case 'scroll':
      case 'swipe':
        final parser = ArgParser()
          ..addOption('target')
          ..addOption('distance')
          ..addOption('x')
          ..addOption('y')
          ..addOption('from')
          ..addOption('to')
          ..addFlag('verbose', defaultsTo: false);
        _CliActions._addAllowErrorsOption(parser);
        return parser;
      case 'scroll-to':
        final parser = ArgParser()
          ..addOption('max-scrolls', defaultsTo: '20')
          ..addOption('direction')
          ..addOption('distance')
          ..addFlag('verbose', defaultsTo: false);
        _CliActions._addAllowErrorsOption(parser);
        return parser;
      case 'back':
        final parser = ArgParser()..addFlag('verbose', defaultsTo: false);
        _CliActions._addAllowErrorsOption(parser);
        return parser;
      case 'dismiss':
        final parser = ArgParser()
          ..addOption('wait-ms', defaultsTo: '1500')
          ..addFlag('verbose', defaultsTo: false);
        _CliActions._addAllowErrorsOption(parser);
        return parser;
      case 'wait':
        return ArgParser()
          ..addOption('timeout', defaultsTo: '3000')
          ..addFlag('verbose', defaultsTo: false);
      case 'wait-for':
        return ArgParser()
          ..addOption('text')
          ..addOption('gone')
          ..addOption('target')
          ..addOption('selected')
          ..addOption('screen')
          ..addOption('view')
          ..addOption('field')
          ..addOption('timeout', defaultsTo: '5000')
          ..addOption('poll', defaultsTo: '150');
      case 'health':
        return ArgParser()..addFlag('include-stale', defaultsTo: false);
      case 'deeplink':
        return ArgParser();
    }
    throw StateError('Batch command was not allowlisted: $command');
  }

  void _validateBatchLocate(ArgResults parsed, {required bool mutating}) {
    if (parsed.rest.length > 1) {
      throw const ScoutCliException(
        'batch_command_schema_invalid',
        'Locate/reveal accepts at most one positional target.',
      );
    }
    final text = parsed.option('text');
    final optionTarget = parsed.option('target');
    if (optionTarget != null && parsed.rest.isNotEmpty) {
      throw const ScoutCliException(
        'batch_command_schema_invalid',
        'Choose --target or a positional target, not both.',
      );
    }
    final target =
        optionTarget ?? (parsed.rest.isEmpty ? null : parsed.rest.single);
    if ((text == null || text.isEmpty) == (target == null || target.isEmpty)) {
      throw const ScoutCliException(
        'batch_command_schema_invalid',
        'Provide exactly one text query or target handle.',
      );
    }
    _batchBoundedInt(
      parsed.option('max-response-bytes')!,
      4096,
      1048576,
      '--max-response-bytes',
    );
    if (!mutating) {
      _batchBoundedInt(
        parsed.option('max-candidates')!,
        1,
        100,
        '--max-candidates',
      );
      return;
    }
    _batchBoundedInt(parsed.option('max-actions')!, 1, 50, '--max-actions');
    _batchBoundedInt(parsed.option('timeout')!, 100, 12000, '--timeout');
    final distance = _batchFiniteOption(
      parsed.option('distance'),
      '--distance',
      minimum: 1,
      maximum: 5000,
    );
    _batchFiniteOption(
      parsed.option('max-distance'),
      '--max-distance',
      minimum: distance ?? 1,
      maximum: 100000,
    );
  }

  void _validateBatchTap(ArgResults parsed) {
    if (parsed.rest.length == 2 &&
        _isNumeric(parsed.rest[0]) &&
        _isNumeric(parsed.rest[1]) &&
        parsed.option('x') == null &&
        parsed.option('y') == null) {
      _batchFiniteOption(parsed.rest[0], 'tap x');
      _batchFiniteOption(parsed.rest[1], 'tap y');
    } else {
      _validateBatchTargetOrCoordinates(parsed, command: 'tap');
    }
    _batchBoundedInt(parsed.option('wait-ms')!, 0, 60000, '--wait-ms');
    _validateBatchExpectations(parsed);
  }

  void _validateBatchTargetOrCoordinates(
    ArgResults parsed, {
    required String command,
  }) {
    if (parsed.rest.length > 1) {
      throw ScoutCliException(
        'batch_command_schema_invalid',
        '`$command` accepts at most one target.',
      );
    }
    final hasTarget = parsed.rest.length == 1 && parsed.rest.single.isNotEmpty;
    final x = parsed.option('x');
    final y = parsed.option('y');
    final hasCoordinates = x != null || y != null;
    if (hasTarget == hasCoordinates ||
        (hasCoordinates && (x == null || y == null))) {
      throw ScoutCliException(
        'batch_command_schema_invalid',
        '`$command` requires exactly one target or one complete x/y pair.',
      );
    }
    _batchFiniteOption(x, '--x');
    _batchFiniteOption(y, '--y');
  }

  void _validateBatchExpectations(ArgResults parsed) {
    _batchBoundedInt(
      parsed.option('expect-timeout')!,
      1,
      120000,
      '--expect-timeout',
    );
    final field = parsed.option('expect-field');
    if (field != null && !field.contains('=')) {
      throw const ScoutCliException(
        'batch_command_schema_invalid',
        '`--expect-field` must use <handle>=<value>.',
      );
    }
    final capture = parsed.option('capture');
    if (capture != null && capture.isEmpty) {
      throw const ScoutCliException(
        'batch_command_schema_invalid',
        '`--capture` requires a non-empty path.',
      );
    }
  }

  int _batchBoundedInt(String value, int minimum, int maximum, String name) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed < minimum || parsed > maximum) {
      throw ScoutCliException(
        'batch_command_schema_invalid',
        '$name must be an integer from $minimum to $maximum.',
      );
    }
    return parsed;
  }

  double? _batchFiniteOption(
    String? value,
    String name, {
    double minimum = -10000000,
    double maximum = 10000000,
  }) {
    if (value == null) return null;
    final parsed = double.tryParse(value);
    if (parsed == null ||
        !parsed.isFinite ||
        parsed < minimum ||
        parsed > maximum) {
      throw ScoutCliException(
        'batch_command_schema_invalid',
        '$name must be a finite number from $minimum to $maximum.',
      );
    }
    return parsed;
  }

  /// Batch already provides the chronological context, so repeating every
  /// action's full after-summary makes a short flow unreadable. Keep only the
  /// facts needed to decide whether to continue; `--verbose` remains the
  /// escape hatch for the complete per-step responses.
  Map<String, Object?> _compactBatchStep(Map<String, dynamic> result) {
    final assessment = result.containsKey('dispatch')
        ? _assessReplayOutcome(Map<String, Object?>.from(result))
        : null;
    final after = result['afterSummary'];
    final afterSummary = after is Map
        ? {
            if (after['screen'] != null) 'screen': after['screen'],
            if (after['activeSurface'] != null)
              'activeSurface': after['activeSurface'],
            if (after['viewSignature'] != null)
              'viewSignature': after['viewSignature'],
            if (after['fieldValues'] != null)
              'fieldValues': after['fieldValues'],
          }
        : null;
    return {
      ..._compactProtocolSafetyEvidence(result),
      'ok': result['ok'],
      if (assessment != null) ...<String, Object?>{
        'outcomeStatus': assessment.status,
        'outcomeAccepted': assessment.accepted,
        'businessSuccessClaimed': assessment.businessSuccessClaimed,
      },
      if (result['action'] != null) 'action': result['action'],
      if (result['result'] != null) 'result': result['result'],
      if (result['stable'] != null) 'stable': result['stable'],
      if (result['target'] != null) 'target': result['target'],
      if (result['filled'] != null) 'filled': result['filled'],
      if (result['failed'] != null) 'failed': result['failed'],
      if (result['activation'] != null) 'activation': result['activation'],
      if (result['screen'] != null) 'screen': result['screen'],
      if (result['activeSurface'] != null)
        'activeSurface': result['activeSurface'],
      if (result['snapshotId'] != null) 'snapshotId': result['snapshotId'],
      if (result['sameSnapshot'] == true) 'sameSnapshot': true,
      if (afterSummary != null && afterSummary.isNotEmpty)
        'after': afterSummary,
      if (result['delta'] != null) 'delta': result['delta'],
      if (result['error'] != null) 'error': result['error'],
      if (result['expectation'] != null) 'expectation': result['expectation'],
      if (result['recentErrors'] != null)
        'recentErrors': result['recentErrors'],
      if (result['recentLogSignals'] != null)
        'recentLogSignals': result['recentLogSignals'],
    };
  }

  Future<void> _disposeCachedVmService() async {
    final cached = _cachedVmService;
    _cachedVmService = null;
    _cachedVmUri = null;
    if (cached != null) {
      try {
        await cached.dispose();
      } catch (_) {
        // A dead socket failing to close cleanly is not an error.
      }
    }
  }
}

extension _CliExportBatch on FlutterScoutCli {
  /// Reconstructs the session's recorded actions as a batch script — turning
  /// an interactive exploration into a replayable regression flow (a modern
  /// replacement for `replay`, composable with `--expect-*` gates).
  Future<int> _exportBatch(List<String> args) async {
    final parser = ArgParser()
      ..addOption('output', abbr: 'o')
      ..addOption(
        'retention',
        defaultsTo: 'session',
        allowed: const <String>['session', '24h', '7d', 'manual'],
        help: 'Retention label for the private exported script.',
      );
    final parsed = parser.parse(args);
    final actions = _readSessionActions();
    final commands = <String>[];
    final skipped = <Object?>[];
    for (final action in actions) {
      if (action is! Map) {
        skipped.add(action);
        continue;
      }
      final command = _commandForRecord(Map<String, Object?>.from(action));
      (command == null ? skipped : commands).add(command ?? action);
    }
    if (commands.isEmpty) {
      throw const ScoutCliException(
        'no_recorded_actions',
        'No exportable actions in .flutter_scout/session.json — run some '
            'tap/input/fill/scroll commands first.',
      );
    }
    final script = commands.join('\n');
    final requiredVariables = _requiredRecordVariables(actions);
    final output = parsed.option('output');
    final retention = _retentionOption(parsed);
    if (output != null && output.isNotEmpty) {
      _writePrivateArtifactBytes(output, utf8.encode('$script\n'));
      _writePrivateArtifactMetadata(output, retention);
    }
    _printJson({
      'ok': true,
      'commands': commands,
      'skipped': skipped.length,
      'requiredVariables': requiredVariables,
      if (output != null && output.isNotEmpty) 'path': output,
      if (output != null && output.isNotEmpty)
        'dataClassification': _privateApplicationData,
      if (output != null && output.isNotEmpty) 'retentionPolicy': retention,
      'runWith': output != null && output.isNotEmpty
          ? 'flutter-scout batch --file $output '
                '--var-file <0600-vars.json>'
          : 'flutter-scout batch \'<commands joined with ;>\'',
    });
    return 0;
  }

  /// One recorded action -> one batch command line, or null when the record
  /// is not replayable.
  String? _commandForRecord(Map<String, Object?> record) {
    final cmd = record['cmd']?.toString();
    if (cmd == null || cmd.isEmpty) return null;
    final params = {
      for (final entry in record.entries)
        if (entry.key != 'cmd' &&
            !entry.key.startsWith('_') &&
            entry.value != null)
          entry.key: entry.value.toString(),
    };
    final parts = <String>[cmd];
    void takePositional(String key) {
      final value = params.remove(key);
      if (value != null && value.isNotEmpty) {
        parts.add(FlutterScoutCli.quoteBatchArg(value));
      }
    }

    switch (cmd) {
      case 'tap':
      case 'long-press':
        if (params.containsKey('target')) {
          takePositional('target');
          params.remove('x');
          params.remove('y');
        } else {
          takePositional('x');
          takePositional('y');
        }
      case 'tap-text':
        final text = params.remove('text');
        if (text == null) return null;
        if (text.startsWith('-')) {
          parts.addAll(['--text', FlutterScoutCli.quoteBatchArg(text)]);
        } else {
          parts.add(FlutterScoutCli.quoteBatchArg(text));
        }
      case 'input':
        final target = params.remove('target');
        if (target != null && target != 'focused') {
          parts.addAll(['--target', FlutterScoutCli.quoteBatchArg(target)]);
        }
        takePositional('value');
      case 'fill':
        final rawValues = record['values'];
        params.remove('values');
        if (rawValues == null) return null;
        final values = rawValues is String ? rawValues : jsonEncode(rawValues);
        parts.addAll(['--json', FlutterScoutCli.quoteBatchArg(values)]);
      case 'scroll':
      case 'swipe':
        takePositional('direction');
      case 'scroll-to':
        takePositional('target');
      default:
        return null;
    }
    // Defaults add noise; drop them.
    if (params['waitMs'] == '1500') params.remove('waitMs');
    if (params['expectTimeoutMs'] == '5000') params.remove('expectTimeoutMs');
    if (params['pollMs'] == '150') params.remove('pollMs');
    for (final entry in params.entries) {
      final flag = _flagNameForParam(entry.key);
      if (entry.key == 'allowMismatch') {
        if (entry.value == 'true') parts.add('--allow-mismatch');
        continue;
      }
      parts.addAll(['--$flag', FlutterScoutCli.quoteBatchArg(entry.value)]);
    }
    return parts.join(' ');
  }

  String _flagNameForParam(String param) {
    // Param names that do not follow the plain camelCase->kebab-case rule.
    const special = {'expectTimeoutMs': 'expect-timeout', 'pollMs': 'poll'};
    final mapped = special[param];
    if (mapped != null) return mapped;
    return param.replaceAllMapped(
      RegExp('[A-Z]'),
      (match) => '-${match.group(0)!.toLowerCase()}',
    );
  }
}

/// Deterministic test surface for batch's compact safety projection.
extension FlutterScoutCliBatchTesting on FlutterScoutCli {
  Map<String, Object?> debugCompactBatchStep(Map<String, dynamic> result) =>
      _compactBatchStep(result);
}
