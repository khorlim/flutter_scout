part of 'flutter_scout_cli.dart';

// part: source redaction for action journals, replay artifacts, diagnostics,
// and private child-process credential handoff.

const String _kLegacyRecordRedactedPrefix = '\u0000VAR:';
const String _kSerializedRedaction = '<redacted>';

extension _CliPrivacy on FlutterScoutCli {
  void _registerSensitiveValue(Object? value) {
    if (value == null) return;
    if (value is Map) {
      for (final child in value.values) {
        _registerSensitiveValue(child);
      }
      return;
    }
    if (value is Iterable) {
      for (final child in value) {
        _registerSensitiveValue(child);
      }
      return;
    }
    final text = value.toString();
    if (text.isNotEmpty) _activeSensitiveValues.add(text);
  }

  void _registerVmUriCredentials(String vmUri) {
    _registerSensitiveValue(vmUri);
    final uri = Uri.tryParse(vmUri);
    if (uri == null) return;
    try {
      if (uri.userInfo.isNotEmpty) _registerSensitiveValue(uri.userInfo);
      for (final segment in uri.pathSegments) {
        if (segment.isNotEmpty && segment != 'ws') {
          _registerSensitiveValue(segment);
        }
      }
      for (final values in uri.queryParametersAll.values) {
        for (final value in values) {
          _registerSensitiveValue(value);
        }
      }
      for (final key in uri.queryParametersAll.keys) {
        if (key.isNotEmpty) _registerSensitiveValue(key);
      }
    } on FormatException {
      // The complete untrusted string was already registered above. Leave
      // structural rejection to the central typed URI validator without
      // allowing a malformed percent escape to bypass redaction.
    }
  }

  void _registerDeeplinkCredentials(String raw) {
    _registerSensitiveValue(raw);
    final uri = Uri.tryParse(raw);
    if (uri == null) return;
    try {
      if (uri.userInfo.isNotEmpty) _registerSensitiveValue(uri.userInfo);
      for (final segment in uri.pathSegments) {
        if (segment.isNotEmpty) _registerSensitiveValue(segment);
      }
      for (final entry in uri.queryParametersAll.entries) {
        if (entry.key.isNotEmpty) _registerSensitiveValue(entry.key);
        for (final value in entry.value) {
          if (value.isNotEmpty) _registerSensitiveValue(value);
        }
      }
      if (uri.fragment.isNotEmpty) _registerSensitiveValue(uri.fragment);
    } on FormatException {
      // The full deep link remains registered even when its decoded pieces
      // cannot be inspected safely.
    }
  }

  void _registerSensitiveCommandArgs(String command, List<String> args) {
    if (command == 'attach' || command == 'ensure') {
      final value = _optionValue(args, 'debug-url');
      if (value != null) _registerVmUriCredentials(value);
    } else if (command == 'deeplink') {
      for (final value in _deeplinkPositionalValues(args)) {
        _registerDeeplinkCredentials(value);
      }
    } else if (command == 'input') {
      final filePath = _optionValue(args, 'file');
      if (filePath != null && filePath.isNotEmpty) {
        // Protected ingress was validated, bounded, cached, and registered
        // before this sink guard runs. Never re-open a caller-owned path here:
        // doing so would reintroduce a TOCTOU window and an unbounded read.
        _registerSensitiveValue(
          _protectedSecretIngress[_protectedActionIngressKey],
        );
        return;
      }
      final positional = <String>[];
      const optionsWithValues = {
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
      var skipsNext = false;
      for (final arg in args) {
        if (skipsNext) {
          skipsNext = false;
          continue;
        }
        if (optionsWithValues.contains(arg.toLowerCase())) {
          skipsNext = true;
          continue;
        }
        if (!arg.startsWith('-')) positional.add(arg);
      }
      if (positional.isNotEmpty) {
        for (final value in positional) {
          _registerSensitiveValue(value);
        }
        _registerSensitiveValue(positional.join(' '));
      }
    } else if (command == 'fill') {
      final raw = _optionValue(args, 'json');
      if (raw != null && raw.isNotEmpty) {
        try {
          _registerSensitiveValue(jsonDecode(raw));
        } catch (_) {
          _registerSensitiveValue(raw);
        }
      }
    } else if (command == 'batch') {
      String? script;
      final filePath = _optionValue(args, 'file');
      if (filePath != null && filePath.isNotEmpty) {
        // Read once through the same bounded no-symlink/strict-UTF-8 boundary
        // used by batch execution. Caching these exact bytes also closes the
        // redaction-vs-dispatch TOCTOU gap: the script registered here is the
        // script `_batch` will execute.
        script = _readBoundedCommandFile(filePath, kind: 'batch-file');
        _protectedSecretIngress[_boundedBatchFileIngressKey] = script;
      } else {
        final positional = <String>[];
        var skipsNext = false;
        for (final arg in args) {
          if (skipsNext) {
            skipsNext = false;
            continue;
          }
          if (arg == '--var' || arg == '--file' || arg == '--var-file') {
            skipsNext = true;
            continue;
          }
          if (!arg.startsWith('-')) positional.add(arg);
        }
        if (positional.isNotEmpty) script = positional.join(' ');
      }
      if (script != null) {
        for (final line in FlutterScoutCli.splitBatchScript(script)) {
          final nested = FlutterScoutCli.splitCommandLine(line);
          if (nested.isEmpty || nested.first == 'batch') continue;
          _registerSensitiveCommandArgs(
            nested.first,
            nested.skip(1).toList(growable: false),
          );
        }
      }
    }

    // Replay/record/batch variables are secrets by definition. Register them
    // before proxying or dispatch so even a remote helper echo is scrubbed.
    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      String? assignment;
      if (arg == '--var' && index + 1 < args.length) {
        assignment = args[++index];
      } else if (arg.startsWith('--var=')) {
        assignment = arg.substring('--var='.length);
      }
      if (assignment == null) continue;
      final equals = assignment.indexOf('=');
      if (equals >= 0) {
        _registerSensitiveValue(assignment.substring(equals + 1));
      }
    }
  }

  String _redactActiveSensitiveText(String value) {
    // Replace registered values before pattern-based redaction. A secret may
    // itself contain a record delimiter (for example a newline in an
    // Authorization value); applying the generic matcher first could mutate
    // only its prefix and prevent the exact value from matching afterwards.
    var safe = value;
    final variants = <String>{};
    for (final secret in _activeSensitiveValues) {
      if (secret.isEmpty) continue;
      final hex = utf8
          .encode(secret)
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      variants
        ..add(secret)
        ..add(Uri.encodeComponent(secret))
        ..add(base64.encode(utf8.encode(secret)))
        ..add(base64Url.encode(utf8.encode(secret)))
        ..add(hex)
        ..add(hex.toUpperCase());
      final jsonString = jsonEncode(secret);
      if (jsonString.length >= 2) {
        variants.add(jsonString.substring(1, jsonString.length - 1));
      }
    }
    final secrets = variants.toList(growable: false)
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final secret in secrets) {
      if (secret.isNotEmpty) {
        safe = safe.replaceAll(secret, _kSerializedRedaction);
      }
    }
    return _redactSensitiveLogText(safe);
  }

  Object? _sanitizeForSerialization(Object? value) {
    if (value is Map) {
      final stringMap = <String, Object?>{
        for (final entry in value.entries) entry.key.toString(): entry.value,
      };
      for (final entry in stringMap.entries) {
        if (_vmServiceEndpointKey(entry.key) != null && entry.value is String) {
          _registerVmUriCredentials(entry.value! as String);
        }
      }
      final cmd = stringMap['cmd']?.toString();
      if (cmd == 'input' || cmd == 'fill') {
        return _redactRecordedAction(stringMap);
      }
      final out = <String, Object?>{};
      for (final entry in stringMap.entries) {
        final endpointKey = _vmServiceEndpointKey(entry.key);
        if (endpointKey != null && entry.value is String) {
          out[endpointKey] = _safeVmServiceEndpointIdentity(
            entry.value! as String,
          );
        } else {
          out[entry.key] = _sanitizeForSerialization(entry.value);
        }
      }
      return out;
    }
    if (value is Iterable) {
      return <Object?>[
        for (final child in value) _sanitizeForSerialization(child),
      ];
    }
    if (value is String) return _redactActiveSensitiveText(value);
    return value;
  }

  Object? _sanitizeForArtifact(Object? value, {bool fieldContext = false}) {
    if (value is Map) {
      final stringMap = <String, Object?>{
        for (final entry in value.entries) entry.key.toString(): entry.value,
      };
      for (final entry in stringMap.entries) {
        if (_vmServiceEndpointKey(entry.key) != null && entry.value is String) {
          _registerVmUriCredentials(entry.value! as String);
        }
      }
      final cmd = stringMap['cmd']?.toString();
      if (cmd == 'input' || cmd == 'fill') {
        return _redactRecordedAction(stringMap);
      }
      final isField =
          fieldContext ||
          stringMap['kind'] == 'field' ||
          stringMap.containsKey('obscured') ||
          stringMap.containsKey('obscureText');
      final out = <String, Object?>{};
      for (final entry in stringMap.entries) {
        final endpointKey = _vmServiceEndpointKey(entry.key);
        if (endpointKey != null && entry.value is String) {
          out[endpointKey] = _safeVmServiceEndpointIdentity(
            entry.value! as String,
          );
        } else if (entry.key == 'fieldValues' && entry.value is Map) {
          out[entry.key] = <String, Object?>{
            for (final field in (entry.value as Map).entries)
              field.key.toString(): <String, Object?>{
                'redacted': true,
                'isEmpty': field.value?.toString().isEmpty ?? true,
                'hasValue': field.value?.toString().isNotEmpty ?? false,
              },
          };
        } else if (entry.key == 'fieldsById' && entry.value is Map) {
          out[entry.key] = <String, Object?>{
            for (final field in (entry.value as Map).entries)
              field.key.toString(): _sanitizeForArtifact(
                field.value,
                fieldContext: true,
              ),
          };
        } else if (entry.key == 'fields' && entry.value is Iterable) {
          out[entry.key] = <Object?>[
            for (final field in entry.value as Iterable)
              _sanitizeForArtifact(field, fieldContext: true),
          ];
        } else if (entry.key == 'value' && isField) {
          final text = entry.value?.toString() ?? '';
          out['redacted'] = true;
          out['isEmpty'] = text.isEmpty;
          out['hasValue'] = text.isNotEmpty;
        } else {
          out[entry.key] = _sanitizeForArtifact(entry.value);
        }
      }
      return out;
    }
    if (value is Iterable) {
      return <Object?>[for (final child in value) _sanitizeForArtifact(child)];
    }
    if (value is String) return _redactActiveSensitiveText(value);
    return value;
  }

  Map<String, Object?> _redactRecordedAction(Map<String, Object?> action) {
    final out = <String, Object?>{
      for (final entry in action.entries)
        entry.key: _sanitizeNonActionValue(entry.value),
    };
    final cmd = out['cmd']?.toString();
    if (cmd == 'input') {
      final target = action['target']?.toString() ?? 'focused';
      out['target'] = _redactSensitiveLogText(target);
      out['value'] = '$_kRecordRedactedPrefix${_recordVariableKey(target)}';
      out['_redacted'] = 'true';
      out['_redactedFields'] = const <String>['value'];
      out['_redactionPolicy'] = 'source';
    } else if (cmd == 'fill') {
      final decoded = _decodeRecordedFillValues(action['values']);
      if (decoded is Map) {
        out['values'] = <String, Object?>{
          for (final entry in decoded.entries)
            entry.key.toString():
                '$_kRecordRedactedPrefix${_recordVariableKey(entry.key.toString())}',
        };
        out['_redactedFields'] = <String>[
          for (final key in decoded.keys) 'values.${key.toString()}',
        ];
      } else {
        out['values'] = '${_kRecordRedactedPrefix}fill.values';
        out['_redactedFields'] = const <String>['values'];
      }
      out['_redacted'] = 'true';
      out['_redactionPolicy'] = 'source';
    }
    return out;
  }

  Object? _sanitizeNonActionValue(Object? value) {
    if (value is Map) {
      final stringMap = <String, Object?>{
        for (final entry in value.entries) entry.key.toString(): entry.value,
      };
      for (final entry in stringMap.entries) {
        if (_vmServiceEndpointKey(entry.key) != null && entry.value is String) {
          _registerVmUriCredentials(entry.value! as String);
        }
      }
      final out = <String, Object?>{};
      for (final entry in stringMap.entries) {
        final endpointKey = _vmServiceEndpointKey(entry.key);
        if (endpointKey != null && entry.value is String) {
          out[endpointKey] = _safeVmServiceEndpointIdentity(
            entry.value! as String,
          );
        } else {
          out[entry.key] = _sanitizeNonActionValue(entry.value);
        }
      }
      return out;
    }
    if (value is Iterable) {
      return <Object?>[
        for (final child in value) _sanitizeNonActionValue(child),
      ];
    }
    if (value is String) return _redactActiveSensitiveText(value);
    return value;
  }

  String? _vmServiceEndpointKey(String key) => switch (key) {
    'vmServiceUri' => 'vmServiceEndpoint',
    'staleVmServiceUri' => 'staleVmServiceEndpoint',
    'previousVmServiceUri' => 'previousVmServiceEndpoint',
    'vmUri' => 'vmEndpoint',
    _ => null,
  };

  Object? _decodeRecordedFillValues(Object? raw) {
    if (raw is! String) return raw;
    if (_isRecordVariable(raw)) return raw;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  String _recordVariableKey(String raw) {
    final safe = raw
        .trim()
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f=]+'), '_')
        .replaceAll(RegExp(r'\s+'), ' ');
    if (safe.isEmpty) return 'value';
    return safe.length <= 120 ? safe : safe.substring(0, 120);
  }

  bool _isRecordVariable(Object? value) {
    if (value is! String) return false;
    return value.startsWith(_kRecordRedactedPrefix) ||
        value.startsWith(_kLegacyRecordRedactedPrefix);
  }

  String _recordVariableName(String placeholder) {
    if (placeholder.startsWith(_kLegacyRecordRedactedPrefix)) {
      return placeholder.substring(_kLegacyRecordRedactedPrefix.length).trim();
    }
    return placeholder.substring(_kRecordRedactedPrefix.length).trim();
  }

  Map<String, String> _parseReplayVariables(Iterable<String> assignments) {
    final vars = <String, String>{};
    for (final assignment in assignments) {
      final equals = assignment.indexOf('=');
      if (equals <= 0) {
        throw ScoutCliException(
          'invalid_var',
          'Replay variables must use --var <name>=<value>. The rejected '
              'process-argument content was omitted from this diagnostic.',
        );
      }
      final name = assignment.substring(0, equals);
      final value = assignment.substring(equals + 1);
      _putReplayVariable(vars, name, value, source: '--var');
    }
    return vars;
  }

  Object? _resolveRecordVariables(
    Object? value,
    Map<String, String> vars, {
    required bool redacted,
  }) {
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key.toString(): _resolveRecordVariables(
            entry.value,
            vars,
            redacted: redacted,
          ),
      };
    }
    if (value is Iterable) {
      return <Object?>[
        for (final child in value)
          _resolveRecordVariables(child, vars, redacted: redacted),
      ];
    }
    if (redacted && _isRecordVariable(value)) {
      final name = _recordVariableName(value! as String);
      final supplied = vars[name];
      if (supplied == null) {
        throw ScoutCliException(
          'missing_var',
          'This recording needs `--var $name=<value>` for a redacted field.',
        );
      }
      _registerSensitiveValue(supplied);
      return supplied;
    }
    return value;
  }

  List<String> _requiredRecordVariables(Object? value) {
    final names = <String>{};
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
    final sorted = names.toList(growable: false)..sort();
    return sorted;
  }

  void _requireRecordVariables(Object? value, Map<String, String> vars) {
    final missing = _requiredRecordVariables(
      value,
    ).where((name) => !vars.containsKey(name)).toList(growable: false);
    if (missing.isEmpty) return;
    throw ScoutCliException(
      'missing_var',
      'This replay needs ${missing.map((name) => '`--var $name=<value>`').join(', ')} before any step can run.',
    );
  }

  List<String> _resolveBatchArguments(
    List<String> arguments,
    Map<String, String> vars,
  ) {
    return <String>[
      for (final argument in arguments) _resolveBatchArgument(argument, vars),
    ];
  }

  String _resolveBatchArgument(String argument, Map<String, String> vars) {
    if (_isRecordVariable(argument)) {
      return _resolveRecordVariables(
        argument,
        vars,
        redacted: true,
      )!.toString();
    }
    if (argument.startsWith('{') || argument.startsWith('[')) {
      try {
        final decoded = jsonDecode(argument);
        final resolved = _resolveRecordVariables(decoded, vars, redacted: true);
        return jsonEncode(resolved);
      } catch (error) {
        if (error is ScoutCliException) rethrow;
        // It is a normal, non-JSON command argument.
      }
    }
    return argument;
  }

  Map<String, Object?> _redactFlowForStorage(Map<String, Object?> flow) {
    final out = <String, Object?>{
      for (final entry in flow.entries)
        entry.key: _sanitizeNonActionValue(entry.value),
    };
    final steps = flow['steps'];
    if (steps is List) {
      out['steps'] = <Object?>[
        for (final step in steps)
          step is Map
              ? _redactRecordedAction(Map<String, Object?>.from(step))
              : _sanitizeNonActionValue(step),
      ];
    }
    final sourceRetention = flow['retentionPolicy'];
    final recordedCreatedAt = sourceRetention is Map
        ? sourceRetention['createdAt']?.toString()
        : flow['createdAt']?.toString();
    out.addAll(
      _privateArtifactMetadata(
        'manual',
        createdAt: DateTime.tryParse(recordedCreatedAt ?? ''),
      ),
    );
    return out;
  }

  _VmLogListenerLaunchSpec _prepareVmLogListenerLaunchSpec({
    required String vmUri,
    required String logFile,
    required int ownerPid,
  }) {
    final validated = _validatedVmServiceUri(vmUri);
    _ensureSessionDir();
    final privateDirectory = Directory(p.join(_sessionDir.path, '.private'));
    _ensurePrivateDirectory(privateDirectory.path, boundary: _sessionDir.path);
    final nonce = Random.secure().nextInt(0x100000000).toRadixString(16);
    final uriFile = File(
      p.join(privateDirectory.path, 'vm_listener_uri_${pid}_$nonce'),
    );
    _atomicWritePrivateString(
      uriFile.path,
      validated.normalized,
      boundary: _sessionDir.path,
    );
    return _VmLogListenerLaunchSpec(
      uriFile: uriFile.path,
      arguments: <String>[
        Platform.script.toFilePath(),
        'vm-log-listener',
        '--vm-uri-file',
        uriFile.path,
        '--log-file',
        logFile,
        '--session-dir',
        _sessionDir.path,
        '--owner-pid',
        '$ownerPid',
      ],
    );
  }
}

class _VmLogListenerLaunchSpec {
  const _VmLogListenerLaunchSpec({
    required this.uriFile,
    required this.arguments,
  });

  final String uriFile;
  final List<String> arguments;

  Map<String, Object?> toJson() => <String, Object?>{
    'uriFile': uriFile,
    'arguments': arguments,
  };
}
