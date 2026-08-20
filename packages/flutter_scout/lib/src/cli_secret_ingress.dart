part of 'flutter_scout_cli.dart';

// Protected, bounded secret ingress for values that must never appear in a
// Scout caller/worker/direct-Flutter argument vector. Caller-owned inputs are
// validated but never chmodded:
// changing an arbitrary path on the caller's behalf would silently widen the
// trust boundary and can itself race with a path replacement.

const int _maxProtectedIngressBytes = 1024 * 1024;
const int _maxProtectedVariableCount = 512;
const int _maxProtectedVariableNameLength = 256;
const String _protectedActionIngressKey = 'action';
const String _protectedVariableFileIngressKey = 'variables:file';
const String _protectedVariableStdinIngressKey = 'variables:stdin';
const String _protectedVmUriIngressKey = 'vm-service-uri';
const String _protectedDeeplinkIngressKey = 'deeplink-url';
const String _protectedDeeplinkSourceKey = 'deeplink-url-source';

final RegExp _secretDartDefineNameToken = RegExp(
  r'(^|_)(password|passwd|passcode|passphrase|pwd|secret|pin|cvv|cvc|otp|token|cookie|credential|authorization|auth|bearer)($|_)',
);
const Set<String> _secretDartDefineNameCompounds = <String>{
  'apikey',
  'accesstoken',
  'refreshtoken',
  'authtoken',
  'clientsecret',
  'privatekey',
  'accesskey',
  'sessionid',
  'securitycode',
  'cardnumber',
  'accountnumber',
  'onetimecode',
};
final RegExp _credentialLikeDartDefineValue = RegExp(
  r'^(?:bearer\s+\S+|basic\s+\S+|sk-(?:live-|test-)?[A-Za-z0-9_-]{12,}|[rs]k_(?:live|test)_[A-Za-z0-9_-]{12,}|gh[opsu]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{20,}|SK[0-9a-fA-F]{32})$',
  caseSensitive: false,
);
final RegExp _jwtLikeDartDefineValue = RegExp(
  r'^[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}$',
);
final RegExp _embeddedCredentialAssignment = RegExp(
  r'(?:^|[?&#;\s])(?:password|passwd|passcode|passphrase|pwd|secret|pin|cvv|cvc|otp|token|cookie|credential|authorization|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|session[_-]?id)\s*[:=]\s*[^\s&#;]+',
  caseSensitive: false,
);

extension _CliSecretIngress on FlutterScoutCli {
  void _preloadProtectedSecretIngress(String command, List<String> args) {
    if (command == 'launch' || command == 'ensure') {
      _prepareDartDefineFlutterArgs(
        inline: _multiOptionValues(args, 'dart-define'),
        files: _multiOptionValues(args, 'dart-define-from-file'),
      );
    }
    if (command == 'attach' || command == 'ensure') {
      _preloadProtectedVmUri(command, args);
    }
    if (command == 'deeplink') {
      _preloadProtectedDeeplink(args);
    }

    if (command == 'input' || command == 'fill') {
      final filePath = _protectedPathOption(args, 'file');
      final fromStdin = _protectedFlag(args, 'stdin');
      if (filePath != null && filePath.isNotEmpty) {
        final raw = _readOwnerOnlySecretFile(filePath);
        _protectedSecretIngress[_protectedActionIngressKey] = raw;
        if (command == 'fill') {
          _registerSensitiveValue(
            _decodeProtectedStringObject(
              raw,
              source: 'fill input',
              allowEmpty: false,
            ),
          );
        } else {
          _registerSensitiveValue(raw);
        }
      } else if (fromStdin) {
        final raw = _readBoundedProtectedStdin();
        _protectedSecretIngress[_protectedActionIngressKey] = raw;
        if (command == 'fill') {
          _registerSensitiveValue(
            _decodeProtectedStringObject(
              raw,
              source: 'fill input',
              allowEmpty: false,
            ),
          );
        } else {
          _registerSensitiveValue(raw);
        }
      }
    }

    if (!_acceptsReplayVariables(command, args)) return;
    final variableFile = _protectedPathOption(args, 'var-file');
    if (variableFile != null) {
      if (variableFile.isEmpty) {
        throw const ScoutCliException(
          'invalid_var_file',
          '`--var-file` requires a non-empty path.',
        );
      }
      final raw = _readOwnerOnlySecretFile(variableFile);
      _protectedSecretIngress[_protectedVariableFileIngressKey] = raw;
      _registerSensitiveValue(
        _decodeProtectedStringObject(
          raw,
          source: 'variable file',
          allowEmpty: true,
        ),
      );
    }
    if (_protectedFlag(args, 'var-stdin')) {
      final raw = _readBoundedProtectedStdin();
      _protectedSecretIngress[_protectedVariableStdinIngressKey] = raw;
      _registerSensitiveValue(
        _decodeProtectedStringObject(
          raw,
          source: 'variable standard input',
          allowEmpty: true,
        ),
      );
    }
  }

  /// Builds the exact user-supplied Flutter define arguments after applying
  /// Scout's protected-ingress policy. Production launch and the test probe
  /// share this builder so the persisted worker configuration and child argv
  /// cannot accidentally take a less-protected path.
  List<String> _prepareDartDefineFlutterArgs({
    required Iterable<String> inline,
    required Iterable<String> files,
  }) {
    final result = <String>[];
    for (final definition in inline) {
      _rejectSecretLookingInlineDartDefine(definition);
      result.addAll(<String>['--dart-define', definition]);
    }
    for (final path in files) {
      final absolute = _absoluteNormalized(path);
      final raw = _readOwnerOnlySecretFile(absolute);
      _registerDartDefineFileValues(raw);
      result.addAll(<String>['--dart-define-from-file', absolute]);
    }
    return result;
  }

  /// Revalidates protected define files in the detached worker immediately
  /// before it creates the Flutter process. The caller must keep each file
  /// private and stable until Flutter consumes it; the contents themselves
  /// are never copied into Scout state, the worker invocation, or the direct
  /// Flutter-tool argument vector Scout builds. Flutter's downstream tools are
  /// outside that guarantee, as documented in SECURITY.md.
  void _preflightWorkerDartDefineFiles(
    List<String> flutterArgs, {
    required String workingDirectory,
  }) {
    for (var index = 0; index < flutterArgs.length; index++) {
      final argument = flutterArgs[index];
      String? path;
      int? separatePathIndex;
      if (argument == '--dart-define-from-file') {
        if (index + 1 >= flutterArgs.length ||
            flutterArgs[index + 1].startsWith('--')) {
          throw const ScoutCliException(
            'invalid_worker_config',
            'A Flutter define-file option in the worker configuration has no path.',
          );
        }
        separatePathIndex = ++index;
        path = flutterArgs[separatePathIndex];
      } else if (argument.startsWith('--dart-define-from-file=')) {
        path = argument.substring('--dart-define-from-file='.length);
        if (path.isEmpty) {
          throw const ScoutCliException(
            'invalid_worker_config',
            'A Flutter define-file option in the worker configuration has no path.',
          );
        }
      }
      if (path == null) continue;
      final absolute = p.isAbsolute(path)
          ? _absoluteNormalized(path)
          : _absoluteNormalized(p.join(workingDirectory, path));
      if (separatePathIndex != null) {
        flutterArgs[separatePathIndex] = absolute;
      } else {
        flutterArgs[index] = '--dart-define-from-file=$absolute';
      }
      final raw = _readOwnerOnlySecretFile(absolute);
      _registerDartDefineFileValues(raw);
    }
  }

  List<String> _multiOptionValues(List<String> args, String name) {
    final values = <String>[];
    for (var index = 0; index < args.length; index++) {
      final argument = args[index];
      if (argument == '--$name') {
        if (index + 1 >= args.length || args[index + 1].startsWith('--')) {
          throw ScoutCliException(
            'invalid_dart_define_source',
            '`--$name` requires a non-empty value.',
          );
        }
        values.add(args[++index]);
      } else if (argument.startsWith('--$name=')) {
        final value = argument.substring(name.length + 3);
        if (value.isEmpty) {
          throw ScoutCliException(
            'invalid_dart_define_source',
            '`--$name` requires a non-empty value.',
          );
        }
        values.add(value);
      }
    }
    return values;
  }

  void _rejectSecretLookingInlineDartDefine(String definition) {
    final separator = definition.indexOf('=');
    final name = separator < 0
        ? definition
        : definition.substring(0, separator);
    final value = separator < 0 ? '' : definition.substring(separator + 1);
    if (!_isSecretLookingDartDefineName(name) &&
        !_isSecretLookingDartDefineValue(value)) {
      return;
    }

    // Register before throwing so the generic structured-error sink cannot
    // echo the rejected process argument through an encoded diagnostic.
    _registerSensitiveValue(definition);
    _registerSensitiveValue(value);
    throw const ScoutCliException(
      'insecure_dart_define_secret',
      'A secret-looking Dart define was rejected before Scout created session '
          'state or a child process. Put compile-time defines in an owner-only '
          'regular non-symlink 0600 file and use '
          '`--dart-define-from-file <path>`. Scout passes only that path to '
          'Flutter; keep the file private and stable until Flutter reads it.',
      details: <String, Object?>{
        'dispatch': 'not_attempted',
        'recovery': 'use_owner_only_dart_define_file',
      },
    );
  }

  bool _isSecretLookingDartDefineName(String name) {
    final snake = name
        .replaceAllMapped(
          RegExp(r'([a-z0-9])([A-Z])'),
          (match) => '${match.group(1)}_${match.group(2)}',
        )
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (_secretDartDefineNameToken.hasMatch(snake)) return true;
    final compact = snake.replaceAll('_', '');
    return _secretDartDefineNameCompounds.any(
      (candidate) =>
          compact == candidate ||
          compact.startsWith(candidate) ||
          compact.endsWith(candidate),
    );
  }

  bool _isSecretLookingDartDefineValue(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.contains('-----BEGIN PRIVATE KEY-----') ||
        trimmed.contains('-----BEGIN RSA PRIVATE KEY-----') ||
        trimmed.contains('-----BEGIN EC PRIVATE KEY-----') ||
        trimmed.contains('-----BEGIN OPENSSH PRIVATE KEY-----') ||
        _credentialLikeDartDefineValue.hasMatch(trimmed) ||
        _jwtLikeDartDefineValue.hasMatch(trimmed) ||
        _embeddedCredentialAssignment.hasMatch(trimmed) ||
        trimmed.startsWith('https://hooks.slack.com/services/') ||
        trimmed.startsWith('https://discord.com/api/webhooks/') ||
        RegExp(
          r'^https://api\.telegram\.org/bot[^/\s]+',
          caseSensitive: false,
        ).hasMatch(trimmed)) {
      return true;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.scheme.isEmpty) return false;
    try {
      if (uri.userInfo.isNotEmpty) return true;
      for (final entry in uri.queryParametersAll.entries) {
        if (entry.value.any((candidate) => candidate.isNotEmpty) &&
            _isSecretLookingDartDefineName(entry.key)) {
          return true;
        }
      }
    } on FormatException {
      // Malformed percent escapes are not enough to classify an otherwise
      // ordinary value as a secret. The concrete prefix matchers above remain
      // fail-closed for known credential forms.
    }
    return false;
  }

  void _registerDartDefineFileValues(String raw) {
    // The complete bounded source catches verbatim echoes. Parsed leaf values
    // catch the far more common Flutter/tool diagnostic form without imposing
    // a content schema that could narrow Flutter's JSON/.env semantics.
    _registerSensitiveValue(raw);
    try {
      _registerSensitiveValue(jsonDecode(raw));
      return;
    } catch (_) {
      // Flutter also accepts dotenv-like name=value define files.
    }
    for (final line in const LineSplitter().convert(raw)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final separator = trimmed.indexOf('=');
      if (separator < 0) continue;
      final value = trimmed.substring(separator + 1);
      _registerSensitiveValue(value);
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        _registerSensitiveValue(value.substring(1, value.length - 1));
      }
    }
  }

  void _preloadProtectedVmUri(String command, List<String> args) {
    final legacy = _singleSecretOptionValue(args, 'debug-url');
    final filePath = _protectedPathOption(args, 'debug-url-file');
    final fromStdin = _protectedFlag(args, 'debug-url-stdin');
    final sourceCount = <bool>[
      legacy != null,
      filePath != null,
      fromStdin,
    ].where((present) => present).length;
    if (sourceCount > 1) {
      throw ScoutCliException(
        'conflicting_vm_service_uri_sources',
        '`$command` accepts only one of --debug-url, --debug-url-file, or '
            '--debug-url-stdin.',
      );
    }
    String? raw;
    if (legacy != null) {
      raw = legacy;
    } else if (filePath != null) {
      raw = _readOwnerOnlySecretFile(filePath);
    } else if (fromStdin) {
      raw = _readBoundedProtectedStdin();
    }
    if (raw == null) return;
    final normalized = _normalizeVmUri(raw);
    _protectedSecretIngress[_protectedVmUriIngressKey] = normalized;
  }

  void _preloadProtectedDeeplink(List<String> args) {
    final filePath = _protectedPathOption(args, 'url-file');
    final fromStdin = _protectedFlag(args, 'url-stdin');
    final positional = _deeplinkPositionalValues(args);
    for (final value in positional) {
      _registerDeeplinkCredentials(value);
    }
    final sourceCount = <bool>[
      positional.isNotEmpty,
      filePath != null,
      fromStdin,
    ].where((present) => present).length;
    if (sourceCount > 1 || positional.length > 1) {
      throw const ScoutCliException(
        'conflicting_deeplink_url_sources',
        'Supply exactly one deep-link URL using a legacy positional value, '
            '--url-file, or --url-stdin.',
      );
    }
    String? raw;
    String? source;
    if (positional.length == 1) {
      raw = positional.single;
      source = 'legacy_process_argv';
    } else if (filePath != null) {
      raw = _readOwnerOnlySecretFile(filePath);
      source = 'protected_owner_only_file';
    } else if (fromStdin) {
      raw = _readBoundedProtectedStdin();
      source = 'protected_stdin';
    }
    if (raw == null) return;
    final validated = _validateDeeplinkUrl(raw.trim());
    _registerDeeplinkCredentials(validated);
    _protectedSecretIngress[_protectedDeeplinkIngressKey] = validated;
    _protectedSecretIngress[_protectedDeeplinkSourceKey] = source!;
  }

  String? _singleSecretOptionValue(List<String> args, String name) {
    String? result;
    for (var index = 0; index < args.length; index++) {
      final argument = args[index];
      String? value;
      if (argument == '--$name') {
        if (index + 1 >= args.length || args[index + 1].startsWith('--')) {
          throw ScoutCliException(
            'invalid_secret_source',
            '`--$name` requires a non-empty value.',
          );
        }
        value = args[index + 1];
      } else if (argument.startsWith('--$name=')) {
        value = argument.substring(name.length + 3);
        if (value.isEmpty) {
          throw ScoutCliException(
            'invalid_secret_source',
            '`--$name` requires a non-empty value.',
          );
        }
      }
      if (value == null) continue;
      if (result != null) {
        throw ScoutCliException(
          'duplicate_secret_source',
          '`--$name` may be supplied at most once.',
        );
      }
      result = value;
    }
    return result;
  }

  List<String> _deeplinkPositionalValues(List<String> args) {
    final values = <String>[];
    var skipNext = false;
    for (final argument in args) {
      if (skipNext) {
        skipNext = false;
        continue;
      }
      if (argument == '--url-file') {
        skipNext = true;
        continue;
      }
      if (argument.startsWith('--url-file=') || argument == '--url-stdin') {
        continue;
      }
      if (!argument.startsWith('-')) values.add(argument);
    }
    return values;
  }

  bool _acceptsReplayVariables(String command, List<String> args) =>
      command == 'batch' ||
      command == 'replay' ||
      (command == 'record' && args.isNotEmpty && args.first == 'run');

  bool _hasExactFlag(List<String> args, String name) =>
      args.any((argument) => argument == '--$name');

  bool _protectedFlag(List<String> args, String name) {
    final count = args.where((argument) => argument == '--$name').length;
    if (count > 1) {
      throw ScoutCliException(
        'duplicate_secret_source',
        '`--$name` may be supplied at most once.',
      );
    }
    return count == 1;
  }

  String? _protectedPathOption(List<String> args, String name) {
    String? result;
    for (var index = 0; index < args.length; index++) {
      final argument = args[index];
      if (argument == '--$name') {
        if (index + 1 >= args.length || args[index + 1].startsWith('--')) {
          throw ScoutCliException(
            'invalid_secret_file',
            '`--$name` requires a non-empty path.',
          );
        }
        if (result != null) {
          throw ScoutCliException(
            'duplicate_secret_source',
            '`--$name` may be supplied at most once.',
          );
        }
        result = args[index + 1];
      }
      if (argument.startsWith('--$name=')) {
        final value = argument.substring(name.length + 3);
        if (value.isEmpty) {
          throw ScoutCliException(
            'invalid_secret_file',
            '`--$name` requires a non-empty path.',
          );
        }
        if (result != null) {
          throw ScoutCliException(
            'duplicate_secret_source',
            '`--$name` may be supplied at most once.',
          );
        }
        result = value;
      }
    }
    return result;
  }

  bool _usesProtectedStdin(String command, List<String> args) =>
      (command == 'input' || command == 'fill') &&
          _hasExactFlag(args, 'stdin') ||
      _acceptsReplayVariables(command, args) &&
          _hasExactFlag(args, 'var-stdin') ||
      (command == 'attach' || command == 'ensure') &&
          _hasExactFlag(args, 'debug-url-stdin') ||
      command == 'deeplink' && _hasExactFlag(args, 'url-stdin');

  String? _protectedVmUriInput(ArgResults parsed) {
    if (parsed.option('debug-url') == null &&
        parsed.option('debug-url-file') == null &&
        !parsed.flag('debug-url-stdin')) {
      return null;
    }
    final value = _protectedSecretIngress[_protectedVmUriIngressKey];
    if (value == null) {
      throw const ScoutCliException(
        'protected_input_unavailable',
        'The protected VM-service URL was not available for connection.',
      );
    }
    return value;
  }

  ({String url, String source}) _protectedDeeplinkInput() {
    final url = _protectedSecretIngress[_protectedDeeplinkIngressKey];
    final source = _protectedSecretIngress[_protectedDeeplinkSourceKey];
    if (url == null || source == null) {
      throw const ScoutCliException(
        'protected_input_unavailable',
        'The protected deep-link URL was not available for dispatch.',
      );
    }
    return (url: url, source: source);
  }

  String _protectedActionInput(String command) {
    final value = _protectedSecretIngress[_protectedActionIngressKey];
    if (value == null) {
      throw ScoutCliException(
        'protected_input_unavailable',
        'The protected $command input was not available for dispatch.',
      );
    }
    return value;
  }

  void _addReplayVariableOptions(ArgParser parser) {
    parser
      ..addMultiOption(
        'var',
        splitCommas: false,
        help:
            'Deprecated for secrets: resolve name=value from process argv. '
            'Prefer --var-file or --var-stdin.',
      )
      ..addOption(
        'var-file',
        help:
            'Read variables from an owner-only 0600 JSON object of '
            'string name/value pairs.',
      )
      ..addFlag(
        'var-stdin',
        defaultsTo: false,
        negatable: false,
        help:
            'Read variables from one bounded JSON object on protected '
            'standard input.',
      );
  }

  Map<String, String> _replayVariablesFromSources(ArgResults parsed) {
    final variables = <String, String>{};
    final inline = _parseReplayVariables(parsed.multiOption('var'));
    for (final entry in inline.entries) {
      _putReplayVariable(variables, entry.key, entry.value, source: '--var');
    }

    final variableFile = parsed.option('var-file');
    if (variableFile != null) {
      final raw = _protectedSecretIngress[_protectedVariableFileIngressKey];
      if (raw == null) {
        throw const ScoutCliException(
          'protected_input_unavailable',
          'The protected variable file was not available for execution.',
        );
      }
      final decoded = _decodeProtectedStringObject(
        raw,
        source: 'variable file',
        allowEmpty: true,
      );
      for (final entry in decoded.entries) {
        _putReplayVariable(
          variables,
          entry.key,
          entry.value,
          source: '--var-file',
        );
      }
    }

    if (parsed.flag('var-stdin')) {
      final raw = _protectedSecretIngress[_protectedVariableStdinIngressKey];
      if (raw == null) {
        throw const ScoutCliException(
          'protected_input_unavailable',
          'Protected variable standard input was not available for execution.',
        );
      }
      final decoded = _decodeProtectedStringObject(
        raw,
        source: 'variable standard input',
        allowEmpty: true,
      );
      for (final entry in decoded.entries) {
        _putReplayVariable(
          variables,
          entry.key,
          entry.value,
          source: '--var-stdin',
        );
      }
    }
    return variables;
  }

  void _putReplayVariable(
    Map<String, String> variables,
    String name,
    String value, {
    required String source,
  }) {
    _validateProtectedVariableName(name);
    if (!_isWellFormedUnicode(value)) {
      throw const ScoutCliException(
        'invalid_var_value',
        'Variable values must contain well-formed Unicode.',
      );
    }
    if (utf8.encode(value).length > _maxProtectedIngressBytes) {
      throw const ScoutCliException(
        'secret_input_too_large',
        'A replay variable exceeds the 1 MiB limit.',
      );
    }
    if (variables.containsKey(name)) {
      throw ScoutCliException(
        'duplicate_var',
        'Variable `$name` was supplied more than once; remove the duplicate '
            'from $source before any action can run.',
      );
    }
    if (variables.length >= _maxProtectedVariableCount) {
      throw const ScoutCliException(
        'too_many_vars',
        'At most 512 replay variables may be supplied.',
      );
    }
    variables[name] = value;
    _registerSensitiveValue(value);
  }

  void _validateProtectedVariableName(String name) {
    if (name.isEmpty || name.trim() != name) {
      throw const ScoutCliException(
        'invalid_var_name',
        'Variable names must be non-empty and have no leading or trailing '
            'whitespace.',
      );
    }
    if (name.length > _maxProtectedVariableNameLength) {
      throw const ScoutCliException(
        'invalid_var_name',
        'Variable names may contain at most 256 characters.',
      );
    }
    if (!_isWellFormedUnicode(name) ||
        name.contains('=') ||
        RegExp(r'[\u0000-\u001f\u007f-\u009f]').hasMatch(name)) {
      throw const ScoutCliException(
        'invalid_var_name',
        'Variable names must not contain `=` or C0/C1 control characters.',
      );
    }
  }

  bool _isWellFormedUnicode(String value) {
    final units = value.codeUnits;
    for (var index = 0; index < units.length; index++) {
      final unit = units[index];
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (index + 1 >= units.length) return false;
        final next = units[++index];
        if (next < 0xdc00 || next > 0xdfff) return false;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return false;
      }
    }
    return true;
  }

  Map<String, String> _decodeProtectedStringObject(
    String raw, {
    required String source,
    required bool allowEmpty,
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw ScoutCliException(
        'invalid_protected_json',
        'The protected $source must be valid UTF-8 JSON. Input content was '
            'not included in this diagnostic.',
      );
    }
    if (decoded is! Map) {
      throw ScoutCliException(
        'invalid_protected_json',
        'The protected $source must be one JSON object.',
      );
    }
    if (!allowEmpty && decoded.isEmpty) {
      throw ScoutCliException(
        'invalid_protected_json',
        'The protected $source JSON object must not be empty.',
      );
    }
    if (decoded.length > _maxProtectedVariableCount) {
      throw ScoutCliException(
        'invalid_protected_json',
        'The protected $source contains more than 512 entries.',
      );
    }
    final result = <String, String>{};
    for (final entry in decoded.entries) {
      final name = entry.key.toString();
      _validateProtectedVariableName(name);
      if (entry.value is! String) {
        throw ScoutCliException(
          'invalid_protected_json_value',
          'Every value in the protected $source must be a JSON string.',
        );
      }
      result[name] = entry.value! as String;
    }
    return result;
  }

  String _readOwnerOnlySecretFile(String path) {
    final absolute = _absoluteNormalized(path);
    final initialType = FileSystemEntity.typeSync(absolute, followLinks: false);
    if (initialType == FileSystemEntityType.link) {
      throw const ScoutCliException(
        'unsafe_secret_file',
        'Protected input files must not be symbolic links.',
      );
    }
    if (initialType == FileSystemEntityType.notFound) {
      throw const ScoutCliException(
        'secret_file_not_found',
        'The protected input file was not found. Its path was omitted from '
            'this diagnostic.',
      );
    }
    if (initialType != FileSystemEntityType.file) {
      throw const ScoutCliException(
        'invalid_secret_file_type',
        'Protected input must be a regular file.',
      );
    }

    final before = FileStat.statSync(absolute);
    _validateSecretFileStat(before);
    final handle = File(absolute).openSync(mode: FileMode.read);
    final builder = BytesBuilder(copy: false);
    try {
      while (true) {
        final remaining = _maxProtectedIngressBytes + 1 - builder.length;
        if (remaining <= 0) break;
        final chunk = handle.readSync(min(8192, remaining));
        if (chunk.isEmpty) break;
        builder.add(chunk);
      }
    } finally {
      handle.closeSync();
    }
    final bytes = builder.takeBytes();
    if (bytes.length > _maxProtectedIngressBytes) {
      throw const ScoutCliException(
        'secret_input_too_large',
        'Protected input exceeds the 1 MiB limit.',
      );
    }

    final finalType = FileSystemEntity.typeSync(absolute, followLinks: false);
    if (finalType != FileSystemEntityType.file) {
      throw const ScoutCliException(
        'secret_file_changed',
        'Protected input changed type while it was being read.',
      );
    }
    final after = FileStat.statSync(absolute);
    _validateSecretFileStat(after);
    if (before.size != after.size ||
        before.modified != after.modified ||
        before.changed != after.changed ||
        before.mode != after.mode) {
      throw const ScoutCliException(
        'secret_file_changed',
        'Protected input changed while it was being read; no action ran.',
      );
    }
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      throw const ScoutCliException(
        'invalid_secret_input_utf8',
        'Protected input must be valid UTF-8.',
      );
    }
  }

  void _validateSecretFileStat(FileStat stat) {
    if (stat.type != FileSystemEntityType.file) {
      throw const ScoutCliException(
        'invalid_secret_file_type',
        'Protected input must be a regular file.',
      );
    }
    if (stat.size > _maxProtectedIngressBytes) {
      throw const ScoutCliException(
        'secret_input_too_large',
        'Protected input exceeds the 1 MiB limit.',
      );
    }
    if (_supportsPosixModes && (stat.mode & 0xfff) != _privateFileMode) {
      throw const ScoutCliException(
        'insecure_secret_file_permissions',
        'Protected input must already have exact owner-only 0600 permissions. '
            'Scout did not change the caller-owned file.',
      );
    }
  }

  String _readBoundedProtectedStdin() {
    if (stdin.hasTerminal) {
      throw const ScoutCliException(
        'protected_stdin_requires_pipe',
        'Protected standard input must be piped; interactive terminal input '
            'could be echoed or captured by terminal history.',
      );
    }
    final builder = BytesBuilder(copy: false);
    while (true) {
      final value = stdin.readByteSync();
      if (value < 0) break;
      if (builder.length >= _maxProtectedIngressBytes) {
        throw const ScoutCliException(
          'secret_input_too_large',
          'Protected standard input exceeds the 1 MiB limit.',
        );
      }
      builder.addByte(value);
    }
    try {
      return utf8.decode(builder.takeBytes(), allowMalformed: false);
    } catch (_) {
      throw const ScoutCliException(
        'invalid_secret_input_utf8',
        'Protected standard input must be valid UTF-8.',
      );
    }
  }

  void _warnAboutLegacySecretIngress(String command, List<String> args) {
    final sources = <String>{};
    if ((command == 'launch' || command == 'ensure') &&
        _multiOptionValues(args, 'dart-define').isNotEmpty) {
      sources.add('$command --dart-define');
    }
    if ((command == 'attach' || command == 'ensure') &&
        _optionValue(args, 'debug-url') != null) {
      sources.add('$command --debug-url');
    }
    if (command == 'deeplink' && _deeplinkPositionalValues(args).isNotEmpty) {
      sources.add('deeplink positional URL');
    }
    if (command == 'input' &&
        _optionValue(args, 'file') == null &&
        !_hasExactFlag(args, 'stdin')) {
      sources.add('input positional value');
    }
    if (command == 'fill' && _optionValue(args, 'json') != null) {
      sources.add('fill --json');
    }
    if (_acceptsReplayVariables(command, args) &&
        args.any(
          (argument) => argument == '--var' || argument.startsWith('--var='),
        )) {
      sources.add('--var');
    }
    if (command == 'batch') {
      String? script;
      final filePath = _optionValue(args, 'file');
      if (filePath != null && filePath.isNotEmpty) {
        try {
          script = File(filePath).readAsStringSync();
        } catch (_) {
          // The batch parser reports the authoritative file error.
        }
      } else {
        final positional = <String>[];
        var skipNext = false;
        for (final argument in args) {
          if (skipNext) {
            skipNext = false;
            continue;
          }
          if (argument == '--file' ||
              argument == '--var' ||
              argument == '--var-file') {
            skipNext = true;
            continue;
          }
          if (!argument.startsWith('-')) positional.add(argument);
        }
        if (positional.isNotEmpty) script = positional.join(' ');
      }
      if (script != null) {
        for (final line in FlutterScoutCli.splitBatchScript(script)) {
          final nested = FlutterScoutCli.splitCommandLine(line);
          if (nested.isEmpty) continue;
          final nestedCommand = nested.first;
          final nestedArgs = nested.skip(1).toList(growable: false);
          if (nestedCommand == 'input' &&
              _optionValue(nestedArgs, 'file') == null &&
              !_hasExactFlag(nestedArgs, 'stdin')) {
            sources.add('batch input positional value');
          }
          if (nestedCommand == 'fill' &&
              _optionValue(nestedArgs, 'json') != null) {
            sources.add('batch fill --json');
          }
        }
      }
    }
    if (sources.isEmpty) return;
    _writeStructuredWarning(<String, Object?>{
      'code': 'insecure_secret_source',
      'deprecated': true,
      'sources': sources.toList(growable: false)..sort(),
      'message':
          'A value entered through process argv may already be visible '
          'to shell history or same-user process inspection. Use '
          '--file/--stdin for input or fill and '
          '--var-file/--var-stdin for replay variables, '
          '--debug-url-file/--debug-url-stdin for VM-service URLs, and '
          '--url-file/--url-stdin for deep-link URLs. For Flutter compile-time '
          'values, use an owner-only `--dart-define-from-file`; secret-looking '
          'inline Dart defines are rejected.',
    });
  }
}
