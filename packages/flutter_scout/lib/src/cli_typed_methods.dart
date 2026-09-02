part of 'flutter_scout_cli.dart';

// Canonical persistent-agent method contracts. This is intentionally data,
// not prose adjacent to individual parsers: /v1/schema, pre-dispatch
// validation, the checked-in protocol catalog, and schema parity tests all
// consume the same descriptors.

enum _TypedJsonKind { boolean, integer, number, string, object }

class _TypedValueContract {
  const _TypedValueContract({
    required this.kind,
    this.required = false,
    this.defaultValue,
    this.minimum,
    this.maximum,
    this.minLength,
    this.maxLength,
    this.allowedValues,
    this.format,
    this.secrecy = 'public',
    this.objectStringValuesOnly = false,
  });

  final _TypedJsonKind kind;
  final bool required;
  final Object? defaultValue;
  final num? minimum;
  final num? maximum;
  final int? minLength;
  final int? maxLength;
  final List<String>? allowedValues;
  final String? format;
  final String secrecy;
  final bool objectStringValuesOnly;

  String get jsonType => switch (kind) {
    _TypedJsonKind.boolean => 'boolean',
    _TypedJsonKind.integer => 'integer',
    _TypedJsonKind.number => 'number',
    _TypedJsonKind.string => 'string',
    _TypedJsonKind.object => 'object',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'type': jsonType,
    'required': required,
    'default': defaultValue,
    'secrecy': secrecy,
    if (minimum != null) 'minimum': minimum,
    if (maximum != null) 'maximum': maximum,
    if (minLength != null) 'minLength': minLength,
    if (maxLength != null) 'maxLength': maxLength,
    if (allowedValues != null) 'enum': allowedValues,
    if (format != null) 'format': format,
    if (objectStringValuesOnly) 'additionalPropertyType': 'string',
  };

  Map<String, Object?> toJsonSchema({bool nullable = true}) {
    final schema = <String, Object?>{
      'type': nullable ? <String>[jsonType, 'null'] : jsonType,
      if (minimum != null) 'minimum': minimum,
      if (maximum != null) 'maximum': maximum,
      if (minLength != null) 'minLength': minLength,
      if (maxLength != null) 'maxLength': maxLength,
      if (allowedValues != null)
        'enum': <Object?>[...allowedValues!, if (nullable) null],
      if (objectStringValuesOnly)
        'additionalProperties': const <String, Object?>{'type': 'string'},
    };
    return schema;
  }

  bool accepts(Object? value) {
    if (value == null) return !required;
    switch (kind) {
      case _TypedJsonKind.boolean:
        return value is bool;
      case _TypedJsonKind.integer:
        if (value is! int) return false;
        return (minimum == null || value >= minimum!) &&
            (maximum == null || value <= maximum!);
      case _TypedJsonKind.number:
        if (value is! num || (value is double && !value.isFinite)) return false;
        return (minimum == null || value >= minimum!) &&
            (maximum == null || value <= maximum!);
      case _TypedJsonKind.string:
        if (value is! String || value.contains('\u0000')) return false;
        final length = value.runes.length;
        if ((minLength != null && length < minLength!) ||
            (maxLength != null && length > maxLength!)) {
          return false;
        }
        if (allowedValues != null && !allowedValues!.contains(value)) {
          return false;
        }
        return _matchesTypedFormat(value, format);
      case _TypedJsonKind.object:
        if (value is! Map || value.keys.any((key) => key is! String)) {
          return false;
        }
        if (objectStringValuesOnly &&
            value.values.any((item) => item is! String)) {
          return false;
        }
        return true;
    }
  }
}

bool _matchesTypedFormat(String value, String? format) {
  switch (format) {
    case null:
      return true;
    case 'finite-pair':
      final parts = value.split(',');
      if (parts.length != 2) return false;
      return parts.every((part) {
        final parsed = double.tryParse(part.trim());
        return parsed != null && parsed.isFinite;
      });
    case 'logical-rect':
      final parts = value.split(',');
      if (parts.length != 4) return false;
      final numbers = parts
          .map((part) => double.tryParse(part.trim()))
          .toList(growable: false);
      return numbers.every((number) => number != null && number.isFinite) &&
          numbers[0]! >= 0 &&
          numbers[1]! >= 0 &&
          numbers[2]! > 0 &&
          numbers[3]! > 0;
    case 'uri':
      final uri = Uri.tryParse(value);
      return uri != null && uri.scheme.isNotEmpty;
    default:
      return false;
  }
}

class _TypedArgumentContract {
  const _TypedArgumentContract(this.name, this.value, {this.variadic = false});

  final String name;
  final _TypedValueContract value;
  final bool variadic;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    ...value.toJson(),
    'variadic': variadic,
  };
}

class _TypedConstraintSet {
  const _TypedConstraintSet({
    this.atLeastOneOf = const <List<String>>[],
    this.exactlyOneOf = const <List<String>>[],
    this.requiredTogether = const <List<String>>[],
    this.mutuallyExclusive = const <List<String>>[],
  });

  final List<List<String>> atLeastOneOf;
  final List<List<String>> exactlyOneOf;
  final List<List<String>> requiredTogether;
  final List<List<String>> mutuallyExclusive;

  Map<String, Object?> toJson() => <String, Object?>{
    'atLeastOneOf': atLeastOneOf,
    'exactlyOneOf': exactlyOneOf,
    'requiredTogether': requiredTogether,
    'mutuallyExclusive': mutuallyExclusive,
  };
}

class _TypedMethodContract {
  const _TypedMethodContract({
    required this.operation,
    this.arguments = const <_TypedArgumentContract>[],
    this.parameters = const <String, _TypedValueContract>{},
    this.constraints = const _TypedConstraintSet(),
    this.sideEffects = const <String>[],
  });

  final String operation;
  final List<_TypedArgumentContract> arguments;
  final Map<String, _TypedValueContract> parameters;
  final _TypedConstraintSet constraints;
  final List<String> sideEffects;

  int get minimumArgumentCount {
    var count = 0;
    for (final argument in arguments) {
      if (!argument.value.required) break;
      count += 1;
    }
    return count;
  }

  int get maximumArgumentCount =>
      arguments.isNotEmpty && arguments.last.variadic ? 128 : arguments.length;

  Map<String, Object?> toJson() => <String, Object?>{
    'operation': operation,
    'arguments': <String, Object?>{
      'minimumCount': minimumArgumentCount,
      'maximumCount': maximumArgumentCount,
      'items': <Map<String, Object?>>[
        for (final argument in arguments) argument.toJson(),
      ],
    },
    'parameters': <String, Object?>{
      for (final entry in parameters.entries) entry.key: entry.value.toJson(),
    },
    'constraints': constraints.toJson(),
    'sideEffects': sideEffects,
  };
}

const _publicText = _TypedValueContract(
  kind: _TypedJsonKind.string,
  minLength: 1,
  maxLength: 16384,
);
const _optionalText = _TypedValueContract(
  kind: _TypedJsonKind.string,
  minLength: 1,
  maxLength: 16384,
);
const _path = _TypedValueContract(
  kind: _TypedJsonKind.string,
  minLength: 1,
  maxLength: 4096,
);
const _boolFalse = _TypedValueContract(
  kind: _TypedJsonKind.boolean,
  defaultValue: false,
);
const _boolTrue = _TypedValueContract(
  kind: _TypedJsonKind.boolean,
  defaultValue: true,
);
const _coordinate = _TypedValueContract(
  kind: _TypedJsonKind.number,
  minimum: -100000,
  maximum: 100000,
);
const _distance = _TypedValueContract(
  kind: _TypedJsonKind.number,
  minimum: 0,
  maximum: 100000,
);
const _waitMs = _TypedValueContract(
  kind: _TypedJsonKind.integer,
  minimum: 0,
  maximum: 600000,
  defaultValue: 1500,
);
const _expectTimeout = _TypedValueContract(
  kind: _TypedJsonKind.integer,
  minimum: 0,
  maximum: 600000,
  defaultValue: 5000,
);
const _point = _TypedValueContract(
  kind: _TypedJsonKind.string,
  minLength: 3,
  maxLength: 128,
  format: 'finite-pair',
);
const _retention = _TypedValueContract(
  kind: _TypedJsonKind.string,
  defaultValue: 'session',
  allowedValues: <String>['session', '24h', '7d', 'manual'],
);
const _directionDown = _TypedValueContract(
  kind: _TypedJsonKind.string,
  defaultValue: 'down',
  allowedValues: <String>['up', 'down', 'left', 'right'],
);
const _directionLeft = _TypedValueContract(
  kind: _TypedJsonKind.string,
  defaultValue: 'left',
  allowedValues: <String>['up', 'down', 'left', 'right'],
);

Map<String, _TypedValueContract> _persistentExpectParameters() =>
    const <String, _TypedValueContract>{
      'expectText': _optionalText,
      'expectGone': _optionalText,
      'expectTarget': _optionalText,
      'expectSelected': _optionalText,
      'expectScreen': _optionalText,
      'expectView': _optionalText,
      'expectField': _TypedValueContract(
        kind: _TypedJsonKind.string,
        minLength: 1,
        maxLength: 16384,
        secrecy: 'sensitive',
      ),
      'expectTimeout': _expectTimeout,
      'capture': _path,
      'allowErrors': _boolFalse,
      'assertNoErrors': _boolTrue,
      'expectLog': _optionalText,
      'rejectLog': _optionalText,
    };

final Map<String, _TypedMethodContract> _typedMethodContracts =
    <String, _TypedMethodContract>{
      'annotations': const _TypedMethodContract(
        operation: 'mixed',
        arguments: <_TypedArgumentContract>[
          _TypedArgumentContract(
            'action',
            _TypedValueContract(
              kind: _TypedJsonKind.string,
              defaultValue: 'list',
              allowedValues: <String>[
                'list',
                'targets',
                'enable',
                'disable',
                'clear',
                'delete',
                'resolve',
                'dismiss',
                'reopen',
                'fixed',
                'check',
                'wait',
                'signal-handoff',
              ],
            ),
          ),
          _TypedArgumentContract('annotationId', _publicText, variadic: true),
        ],
        parameters: <String, _TypedValueContract>{
          'dismissed': _boolFalse,
          'note': _optionalText,
          'poll': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 16,
            maximum: 60000,
            defaultValue: 1000,
          ),
          'resolved': _boolFalse,
          'status': _optionalText,
          'timeout': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 0,
            maximum: 86400,
            defaultValue: 600,
          ),
        },
        constraints: _TypedConstraintSet(
          mutuallyExclusive: <List<String>>[
            <String>['param:resolved', 'param:dismissed'],
            <String>['param:resolved', 'param:status'],
            <String>['param:dismissed', 'param:status'],
          ],
        ),
      ),
      'apps': const _TypedMethodContract(
        operation: 'mixed',
        parameters: <String, _TypedValueContract>{
          'all': _boolFalse,
          'prune': _boolFalse,
        },
        sideEffects: <String>['session_registry_prune_when_requested'],
      ),
      'back': _TypedMethodContract(
        operation: 'mutation',
        parameters: <String, _TypedValueContract>{
          'allowErrors': _boolFalse,
          'verbose': _boolFalse,
        },
      ),
      'bounds': const _TypedMethodContract(
        operation: 'read',
        arguments: <_TypedArgumentContract>[
          _TypedArgumentContract('target', _publicText),
        ],
        parameters: <String, _TypedValueContract>{'target': _optionalText},
        constraints: _TypedConstraintSet(
          mutuallyExclusive: <List<String>>[
            <String>['arg:target', 'param:target'],
          ],
        ),
      ),
      'crop': const _TypedMethodContract(
        operation: 'read',
        arguments: <_TypedArgumentContract>[
          _TypedArgumentContract('target', _publicText),
        ],
        parameters: <String, _TypedValueContract>{
          'annotated': _boolFalse,
          'changedSince': _optionalText,
          'contains': _boolFalse,
          'native': _boolFalse,
          'output': _path,
          'padding': _TypedValueContract(
            kind: _TypedJsonKind.number,
            minimum: 0,
            maximum: 256,
            defaultValue: 12,
          ),
          'rect': _TypedValueContract(
            kind: _TypedJsonKind.string,
            minLength: 7,
            maxLength: 256,
            format: 'logical-rect',
          ),
          'retention': _retention,
          'target': _optionalText,
          'text': _optionalText,
        },
        constraints: _TypedConstraintSet(
          exactlyOneOf: <List<String>>[
            <String>[
              'arg:target',
              'param:target',
              'param:text',
              'param:rect',
              'param:changedSince',
            ],
          ],
        ),
        sideEffects: <String>['local_private_artifact_write'],
      ),
      'deeplink': const _TypedMethodContract(
        operation: 'mutation',
        arguments: <_TypedArgumentContract>[
          _TypedArgumentContract(
            'url',
            _TypedValueContract(
              kind: _TypedJsonKind.string,
              minLength: 1,
              maxLength: 8192,
              format: 'uri',
              secrecy: 'sensitive',
            ),
          ),
        ],
        parameters: <String, _TypedValueContract>{
          'urlFile': _TypedValueContract(
            kind: _TypedJsonKind.string,
            minLength: 1,
            maxLength: 4096,
            secrecy: 'secret_source_path',
          ),
        },
        constraints: _TypedConstraintSet(
          exactlyOneOf: <List<String>>[
            <String>['arg:url', 'param:urlFile'],
          ],
        ),
      ),
      'drag-cancel': const _TypedMethodContract(operation: 'mutation'),
      'drag-end': const _TypedMethodContract(
        operation: 'mutation',
        parameters: <String, _TypedValueContract>{
          'allowErrors': _boolFalse,
          'by': _point,
          'to': _point,
          'verbose': _boolFalse,
          'x': _coordinate,
          'y': _coordinate,
        },
        constraints: _TypedConstraintSet(
          requiredTogether: <List<String>>[
            <String>['param:x', 'param:y'],
          ],
          mutuallyExclusive: <List<String>>[
            <String>['param:to', 'param:by'],
            <String>['param:to', 'param:x'],
            <String>['param:by', 'param:x'],
          ],
        ),
      ),
      'drag-move': const _TypedMethodContract(
        operation: 'mutation',
        parameters: <String, _TypedValueContract>{
          'allowErrors': _boolFalse,
          'by': _point,
          'screenshot': _path,
          'to': _point,
          'verbose': _boolFalse,
          'x': _coordinate,
          'y': _coordinate,
        },
        constraints: _TypedConstraintSet(
          atLeastOneOf: <List<String>>[
            <String>['param:to', 'param:by', 'param:x'],
          ],
          requiredTogether: <List<String>>[
            <String>['param:x', 'param:y'],
          ],
          mutuallyExclusive: <List<String>>[
            <String>['param:to', 'param:by'],
            <String>['param:to', 'param:x'],
            <String>['param:by', 'param:x'],
          ],
        ),
      ),
      'drag-start': const _TypedMethodContract(
        operation: 'mutation',
        arguments: <_TypedArgumentContract>[
          _TypedArgumentContract('target', _publicText),
        ],
        parameters: <String, _TypedValueContract>{
          'allowErrors': _boolFalse,
          'from': _point,
          'target': _optionalText,
          'verbose': _boolFalse,
          'x': _coordinate,
          'y': _coordinate,
        },
        constraints: _TypedConstraintSet(
          requiredTogether: <List<String>>[
            <String>['param:x', 'param:y'],
          ],
          mutuallyExclusive: <List<String>>[
            <String>['arg:target', 'param:target'],
            <String>['arg:target', 'param:from'],
            <String>['arg:target', 'param:x'],
            <String>['param:target', 'param:from'],
            <String>['param:target', 'param:x'],
            <String>['param:from', 'param:x'],
          ],
        ),
      ),
      'drag-status': const _TypedMethodContract(
        operation: 'read',
        parameters: <String, _TypedValueContract>{'verbose': _boolFalse},
      ),
      'dismiss': const _TypedMethodContract(
        operation: 'mutation',
        parameters: <String, _TypedValueContract>{
          'allowErrors': _boolFalse,
          'verbose': _boolFalse,
          'waitMs': _waitMs,
        },
      ),
      'fill': _TypedMethodContract(
        operation: 'mutation',
        parameters: <String, _TypedValueContract>{
          ..._persistentExpectParameters(),
          'file': const _TypedValueContract(
            kind: _TypedJsonKind.string,
            minLength: 1,
            maxLength: 4096,
            secrecy: 'secret_source_path',
          ),
          'json': const _TypedValueContract(
            kind: _TypedJsonKind.object,
            secrecy: 'secret',
            objectStringValuesOnly: true,
          ),
          'verbose': _boolFalse,
        },
        constraints: const _TypedConstraintSet(
          exactlyOneOf: <List<String>>[
            <String>['param:file', 'param:json'],
          ],
        ),
      ),
      'health': const _TypedMethodContract(
        operation: 'read',
        parameters: <String, _TypedValueContract>{'includeStale': _boolFalse},
      ),
      'input': _TypedMethodContract(
        operation: 'mutation',
        arguments: const <_TypedArgumentContract>[
          _TypedArgumentContract(
            'value',
            _TypedValueContract(
              kind: _TypedJsonKind.string,
              minLength: 0,
              maxLength: 1048576,
              secrecy: 'secret',
            ),
            variadic: true,
          ),
        ],
        parameters: <String, _TypedValueContract>{
          ..._persistentExpectParameters(),
          'file': const _TypedValueContract(
            kind: _TypedJsonKind.string,
            minLength: 1,
            maxLength: 4096,
            secrecy: 'secret_source_path',
          ),
          'target': const _TypedValueContract(
            kind: _TypedJsonKind.string,
            minLength: 1,
            maxLength: 16384,
            defaultValue: 'focused',
          ),
          'verbose': _boolFalse,
        },
        constraints: const _TypedConstraintSet(
          exactlyOneOf: <List<String>>[
            <String>['arg:value', 'param:file'],
          ],
        ),
      ),
      'inspect': const _TypedMethodContract(
        operation: 'read',
        parameters: <String, _TypedValueContract>{
          'brief': _boolFalse,
          'includeStale': _boolFalse,
          'maxItems': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 1,
            maximum: 100,
            defaultValue: 20,
          ),
          'maxResponseBytes': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 4096,
            maximum: 1048576,
            defaultValue: 65536,
          ),
          'sections': _optionalText,
          'since': _optionalText,
          'surface': _boolFalse,
        },
        constraints: _TypedConstraintSet(
          mutuallyExclusive: <List<String>>[
            <String>['param:since', 'param:brief'],
            <String>['param:since', 'param:surface'],
            <String>['param:since', 'param:sections'],
            <String>['param:since', 'param:maxItems'],
          ],
        ),
      ),
      'locate': const _TypedMethodContract(
        operation: 'read',
        arguments: <_TypedArgumentContract>[
          _TypedArgumentContract('target', _publicText),
        ],
        parameters: <String, _TypedValueContract>{
          'contains': _boolFalse,
          'maxCandidates': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 1,
            maximum: 100,
            defaultValue: 20,
          ),
          'maxResponseBytes': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 4096,
            maximum: 1048576,
            defaultValue: 65536,
          ),
          'target': _optionalText,
          'text': _optionalText,
          'within': _optionalText,
        },
        constraints: _TypedConstraintSet(
          exactlyOneOf: <List<String>>[
            <String>['arg:target', 'param:target', 'param:text'],
          ],
        ),
      ),
      'logs': const _TypedMethodContract(
        operation: 'read',
        parameters: <String, _TypedValueContract>{
          'contains': _optionalText,
          'last': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 0,
            maximum: 10000,
            defaultValue: 20,
          ),
          'summary': _boolFalse,
        },
      ),
      'long-press': const _TypedMethodContract(
        operation: 'mutation',
        arguments: <_TypedArgumentContract>[
          _TypedArgumentContract('target', _publicText),
        ],
        parameters: <String, _TypedValueContract>{
          'allowErrors': _boolFalse,
          'durationMs': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 1,
            maximum: 600000,
            defaultValue: 600,
          ),
          'verbose': _boolFalse,
          'x': _coordinate,
          'y': _coordinate,
        },
        constraints: _TypedConstraintSet(
          atLeastOneOf: <List<String>>[
            <String>['arg:target', 'param:x'],
          ],
          requiredTogether: <List<String>>[
            <String>['param:x', 'param:y'],
          ],
          mutuallyExclusive: <List<String>>[
            <String>['arg:target', 'param:x'],
            <String>['arg:target', 'param:y'],
          ],
        ),
      ),
      'reload': const _TypedMethodContract(
        operation: 'mutation',
        parameters: <String, _TypedValueContract>{'verbose': _boolFalse},
      ),
      'restart': const _TypedMethodContract(
        operation: 'mutation',
        parameters: <String, _TypedValueContract>{'verbose': _boolFalse},
      ),
      'reveal': const _TypedMethodContract(
        operation: 'mutation',
        arguments: <_TypedArgumentContract>[
          _TypedArgumentContract('target', _publicText),
        ],
        parameters: <String, _TypedValueContract>{
          'allowErrors': _boolFalse,
          'contains': _boolFalse,
          'direction': _directionDown,
          'distance': _TypedValueContract(
            kind: _TypedJsonKind.number,
            minimum: 1,
            maximum: 5000,
          ),
          'maxActions': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 1,
            maximum: 50,
            defaultValue: 8,
          ),
          'maxDistance': _TypedValueContract(
            kind: _TypedJsonKind.number,
            minimum: 1,
            maximum: 100000,
          ),
          'maxResponseBytes': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 4096,
            maximum: 1048576,
            defaultValue: 65536,
          ),
          'target': _optionalText,
          'text': _optionalText,
          'timeout': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 100,
            maximum: 12000,
            defaultValue: 8000,
          ),
          'within': _optionalText,
        },
        constraints: _TypedConstraintSet(
          exactlyOneOf: <List<String>>[
            <String>['arg:target', 'param:target', 'param:text'],
          ],
        ),
      ),
      'screenshot': const _TypedMethodContract(
        operation: 'read',
        parameters: <String, _TypedValueContract>{
          'annotated': _boolFalse,
          'native': _boolFalse,
          'output': _path,
          'retention': _retention,
          'target': _optionalText,
        },
        sideEffects: <String>['local_private_artifact_write'],
      ),
      'scroll': const _TypedMethodContract(
        operation: 'mutation',
        arguments: <_TypedArgumentContract>[
          _TypedArgumentContract(
            'direction',
            _TypedValueContract(
              kind: _TypedJsonKind.string,
              allowedValues: <String>['up', 'down', 'left', 'right'],
            ),
          ),
        ],
        parameters: <String, _TypedValueContract>{
          'allowErrors': _boolFalse,
          'distance': _distance,
          'from': _point,
          'target': _optionalText,
          'to': _point,
          'verbose': _boolFalse,
          'x': _coordinate,
          'y': _coordinate,
        },
        constraints: _TypedConstraintSet(
          requiredTogether: <List<String>>[
            <String>['param:x', 'param:y'],
          ],
          mutuallyExclusive: <List<String>>[
            <String>['param:target', 'param:from'],
            <String>['param:target', 'param:x'],
            <String>['param:from', 'param:x'],
          ],
        ),
      ),
      'scroll-to': const _TypedMethodContract(
        operation: 'mutation',
        arguments: <_TypedArgumentContract>[
          _TypedArgumentContract(
            'target',
            _TypedValueContract(
              kind: _TypedJsonKind.string,
              required: true,
              minLength: 1,
              maxLength: 16384,
            ),
          ),
        ],
        parameters: <String, _TypedValueContract>{
          'allowErrors': _boolFalse,
          'direction': _directionDown,
          'distance': _distance,
          'maxScrolls': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 1,
            maximum: 1000,
            defaultValue: 20,
          ),
          'verbose': _boolFalse,
        },
      ),
      'status': const _TypedMethodContract(operation: 'read'),
      'swipe': const _TypedMethodContract(
        operation: 'mutation',
        arguments: <_TypedArgumentContract>[
          _TypedArgumentContract('direction', _directionLeft),
        ],
        parameters: <String, _TypedValueContract>{
          'allowErrors': _boolFalse,
          'distance': _distance,
          'from': _point,
          'target': _optionalText,
          'to': _point,
          'verbose': _boolFalse,
          'x': _coordinate,
          'y': _coordinate,
        },
        constraints: _TypedConstraintSet(
          requiredTogether: <List<String>>[
            <String>['param:x', 'param:y'],
          ],
          mutuallyExclusive: <List<String>>[
            <String>['param:target', 'param:from'],
            <String>['param:target', 'param:x'],
            <String>['param:from', 'param:x'],
          ],
        ),
      ),
      'tap': _TypedMethodContract(
        operation: 'mutation',
        arguments: const <_TypedArgumentContract>[
          _TypedArgumentContract('target', _publicText),
        ],
        parameters: <String, _TypedValueContract>{
          ..._persistentExpectParameters(),
          'verbose': _boolFalse,
          'waitMs': _waitMs,
          'x': _coordinate,
          'y': _coordinate,
        },
        constraints: const _TypedConstraintSet(
          atLeastOneOf: <List<String>>[
            <String>['arg:target', 'param:x'],
          ],
          requiredTogether: <List<String>>[
            <String>['param:x', 'param:y'],
          ],
          mutuallyExclusive: <List<String>>[
            <String>['arg:target', 'param:x'],
            <String>['arg:target', 'param:y'],
          ],
        ),
      ),
      'tap-text': _TypedMethodContract(
        operation: 'mutation',
        arguments: const <_TypedArgumentContract>[
          _TypedArgumentContract('text', _publicText, variadic: true),
        ],
        parameters: <String, _TypedValueContract>{
          ..._persistentExpectParameters(),
          'allowMismatch': _boolFalse,
          'contains': _boolFalse,
          'text': _optionalText,
          'verbose': _boolFalse,
          'waitMs': _waitMs,
        },
        constraints: const _TypedConstraintSet(
          exactlyOneOf: <List<String>>[
            <String>['arg:text', 'param:text'],
          ],
        ),
      ),
      'wait': const _TypedMethodContract(
        operation: 'read',
        arguments: <_TypedArgumentContract>[
          _TypedArgumentContract(
            'mode',
            _TypedValueContract(
              kind: _TypedJsonKind.string,
              allowedValues: <String>['stable'],
              defaultValue: 'stable',
            ),
          ),
        ],
        parameters: <String, _TypedValueContract>{
          'timeout': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 0,
            maximum: 600000,
            defaultValue: 3000,
          ),
          'verbose': _boolFalse,
        },
      ),
      'wait-for': const _TypedMethodContract(
        operation: 'read',
        arguments: <_TypedArgumentContract>[
          _TypedArgumentContract('text', _publicText, variadic: true),
        ],
        parameters: <String, _TypedValueContract>{
          'field': _TypedValueContract(
            kind: _TypedJsonKind.string,
            minLength: 1,
            maxLength: 16384,
            secrecy: 'sensitive',
          ),
          'gone': _optionalText,
          'poll': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 16,
            maximum: 2000,
            defaultValue: 150,
          ),
          'screen': _optionalText,
          'selected': _optionalText,
          'target': _optionalText,
          'text': _optionalText,
          'timeout': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 0,
            maximum: 600000,
            defaultValue: 5000,
          ),
          'view': _optionalText,
        },
        constraints: _TypedConstraintSet(
          atLeastOneOf: <List<String>>[
            <String>[
              'arg:text',
              'param:text',
              'param:gone',
              'param:target',
              'param:selected',
              'param:screen',
              'param:view',
              'param:field',
            ],
          ],
          mutuallyExclusive: <List<String>>[
            <String>['arg:text', 'param:text'],
          ],
        ),
      ),
      'where': const _TypedMethodContract(
        operation: 'read',
        parameters: <String, _TypedValueContract>{
          'maxResponseBytes': _TypedValueContract(
            kind: _TypedJsonKind.integer,
            minimum: 4096,
            maximum: 1048576,
            defaultValue: 65536,
          ),
        },
      ),
    };

Map<String, Object?> _persistentTypedMethodCatalog() => <String, Object?>{
  for (final entry in _typedMethodContracts.entries)
    entry.key: entry.value.toJson(),
};

class _TypedContractIssue {
  const _TypedContractIssue(this.code, this.message);

  final String code;
  final String message;
}

class _ValidatedTypedCall {
  const _ValidatedTypedCall({
    required this.method,
    required this.contract,
    required this.positional,
    required this.parameters,
  });

  final String method;
  final _TypedMethodContract contract;
  final List<String> positional;
  final Map<String, Object?> parameters;
}

({_ValidatedTypedCall? call, _TypedContractIssue? issue})
_validatePersistentTypedPayload(Map<dynamic, dynamic> decoded) {
  final rawMethod = decoded['method'];
  if (rawMethod is! String || rawMethod.isEmpty) {
    return (
      call: null,
      issue: const _TypedContractIssue(
        'missing_method',
        'The typed request requires a non-empty string `method`.',
      ),
    );
  }
  final contract = _typedMethodContracts[rawMethod];
  if (contract == null) {
    return (
      call: null,
      issue: _TypedContractIssue(
        'unknown_method',
        'Method `$rawMethod` is not exposed by the persistent typed protocol.',
      ),
    );
  }

  final rawArgs = decoded['args'];
  if (rawArgs != null && rawArgs is! List) {
    return (
      call: null,
      issue: const _TypedContractIssue(
        'invalid_args',
        '`args` must be a JSON array.',
      ),
    );
  }
  final rawParams = decoded['params'];
  if (rawParams != null && rawParams is! Map) {
    return (
      call: null,
      issue: const _TypedContractIssue(
        'invalid_params',
        '`params` must be a JSON object.',
      ),
    );
  }

  final parameters = <String, Object?>{};
  if (rawParams is Map) {
    for (final entry in rawParams.entries) {
      final name = entry.key;
      if (name is! String || !contract.parameters.containsKey(name)) {
        return (
          call: null,
          issue: _TypedContractIssue(
            'unknown_parameter',
            'Parameter `${name.toString()}` is not allowed for `$rawMethod`.',
          ),
        );
      }
      if (entry.value != null) parameters[name] = entry.value;
    }
  }

  final positional = <String>[];
  final argv = rawArgs is List ? rawArgs : const <Object?>[];
  if (argv.length > 128) {
    return (
      call: null,
      issue: const _TypedContractIssue(
        'too_many_args',
        'Typed requests accept at most 128 arguments.',
      ),
    );
  }
  for (var index = 0; index < argv.length; index++) {
    final value = argv[index];
    if (value is! String || value.length > 16384 || value.contains('\u0000')) {
      return (
        call: null,
        issue: const _TypedContractIssue(
          'invalid_arg',
          'Every argument must be a string of at most 16384 characters.',
        ),
      );
    }
    if (!value.startsWith('-') || value == '-') {
      positional.add(value);
      continue;
    }
    String rawName;
    Object? optionValue;
    if (value == '-o') {
      rawName = 'output';
    } else if (value.startsWith('--')) {
      final option = value.substring(2);
      final separator = option.indexOf('=');
      rawName = separator < 0 ? option : option.substring(0, separator);
      if (separator >= 0) optionValue = option.substring(separator + 1);
      rawName = rawName.replaceAllMapped(
        RegExp(r'-([a-z0-9])'),
        (match) => match.group(1)!.toUpperCase(),
      );
    } else {
      return (
        call: null,
        issue: _TypedContractIssue(
          'unknown_parameter',
          'Option `$value` is not allowed for `$rawMethod`.',
        ),
      );
    }
    final descriptor = contract.parameters[rawName];
    if (descriptor == null) {
      return (
        call: null,
        issue: _TypedContractIssue(
          'unknown_parameter',
          'Parameter `$rawName` is not allowed for `$rawMethod`.',
        ),
      );
    }
    if (parameters.containsKey(rawName)) {
      return (
        call: null,
        issue: _TypedContractIssue(
          'invalid_request',
          'Parameter `$rawName` was supplied more than once.',
        ),
      );
    }
    if (descriptor.kind == _TypedJsonKind.boolean) {
      if (optionValue != null) {
        if (optionValue != 'true' && optionValue != 'false') {
          return (
            call: null,
            issue: _TypedContractIssue(
              'invalid_parameter_value',
              'Parameter `$rawName` must be a boolean.',
            ),
          );
        }
        parameters[rawName] = optionValue == 'true';
      } else {
        parameters[rawName] = true;
      }
      continue;
    }
    if (optionValue == null) {
      if (index + 1 >= argv.length) {
        return (
          call: null,
          issue: _TypedContractIssue(
            'invalid_parameter_value',
            'Parameter `$rawName` requires a value.',
          ),
        );
      }
      optionValue = argv[++index];
      if (optionValue is! String) {
        return (
          call: null,
          issue: _TypedContractIssue(
            'invalid_parameter_value',
            'Parameter `$rawName` has an unsupported value shape.',
          ),
        );
      }
    }
    parameters[rawName] = _coerceLegacyTypedOption(optionValue, descriptor);
  }

  if (positional.length < contract.minimumArgumentCount ||
      positional.length > contract.maximumArgumentCount) {
    return (
      call: null,
      issue: _TypedContractIssue(
        'invalid_parameter_value',
        'Method `$rawMethod` accepts ${contract.minimumArgumentCount} through '
            '${contract.maximumArgumentCount} positional argument(s).',
      ),
    );
  }
  for (var index = 0; index < positional.length; index++) {
    final descriptor = index < contract.arguments.length
        ? contract.arguments[index]
        : contract.arguments.last;
    if (!descriptor.value.accepts(positional[index])) {
      return (
        call: null,
        issue: _TypedContractIssue(
          'invalid_parameter_value',
          'Positional argument `${descriptor.name}` violates its typed contract.',
        ),
      );
    }
  }
  for (final entry in contract.parameters.entries) {
    final value = parameters[entry.key];
    if (value == null && entry.value.required) {
      return (
        call: null,
        issue: _TypedContractIssue(
          'invalid_parameter_value',
          'Parameter `${entry.key}` is required for `$rawMethod`.',
        ),
      );
    }
    if (value != null && !entry.value.accepts(value)) {
      final bounds = <String>[
        if (entry.value.minimum != null) 'minimum ${entry.value.minimum}',
        if (entry.value.maximum != null) 'maximum ${entry.value.maximum}',
      ];
      return (
        call: null,
        issue: _TypedContractIssue(
          'invalid_parameter_value',
          'Parameter `${entry.key}` violates its ${entry.value.jsonType} '
              'contract${bounds.isEmpty ? '' : ' (${bounds.join(', ')})'}.',
        ),
      );
    }
  }

  final present = <String>{
    for (var index = 0; index < positional.length; index++)
      'arg:${index < contract.arguments.length ? contract.arguments[index].name : contract.arguments.last.name}',
    for (final entry in parameters.entries)
      if (entry.value != null && entry.value != false) 'param:${entry.key}',
  };
  _TypedContractIssue? constraintIssue(
    List<List<String>> groups,
    bool Function(int count, int length) invalid,
    String code,
    String description,
  ) {
    for (final group in groups) {
      final count = group.where(present.contains).length;
      if (invalid(count, group.length)) {
        return _TypedContractIssue(
          code,
          'Method `$rawMethod` requires $description: ${group.join(', ')}.',
        );
      }
    }
    return null;
  }

  final issue =
      constraintIssue(
        contract.constraints.atLeastOneOf,
        (count, _) => count == 0,
        'invalid_parameter_value',
        'at least one choice',
      ) ??
      constraintIssue(
        contract.constraints.exactlyOneOf,
        (count, _) => count != 1,
        'invalid_parameter_value',
        'exactly one choice',
      ) ??
      constraintIssue(
        contract.constraints.requiredTogether,
        (count, length) => count != 0 && count != length,
        'invalid_parameter_value',
        'all fields in the group together',
      ) ??
      constraintIssue(
        contract.constraints.mutuallyExclusive,
        (count, _) => count > 1,
        'invalid_parameter_value',
        'mutually exclusive fields',
      );
  if (issue != null) return (call: null, issue: issue);

  return (
    call: _ValidatedTypedCall(
      method: rawMethod,
      contract: contract,
      positional: positional,
      parameters: parameters,
    ),
    issue: null,
  );
}

Object? _coerceLegacyTypedOption(
  Object? value,
  _TypedValueContract descriptor,
) {
  if (value is! String) return value;
  return switch (descriptor.kind) {
    _TypedJsonKind.integer => int.tryParse(value) ?? value,
    _TypedJsonKind.number => num.tryParse(value) ?? value,
    _TypedJsonKind.object => _tryDecodeTypedObject(value),
    _ => value,
  };
}

Object? _tryDecodeTypedObject(String value) {
  try {
    return jsonDecode(value);
  } catch (_) {
    return value;
  }
}

Map<String, Object?> _persistentCallDiscriminators() => <String, Object?>{
  'oneOf': <Map<String, Object?>>[
    for (final entry in _typedMethodContracts.entries)
      <String, Object?>{
        'title': entry.key,
        'properties': <String, Object?>{
          'method': <String, Object?>{'const': entry.key},
          'args': <String, Object?>{
            'type': 'array',
            'minItems': entry.value.minimumArgumentCount,
            'maxItems': 128,
            'items': const <String, Object?>{
              'type': 'string',
              'maxLength': 16384,
            },
          },
          'params': <String, Object?>{
            'type': 'object',
            'additionalProperties': false,
            'maxProperties': 64,
            'properties': <String, Object?>{
              for (final parameter in entry.value.parameters.entries)
                parameter.key: parameter.value.toJsonSchema(),
            },
            if (entry.value.parameters.entries
                .where((parameter) => parameter.value.required)
                .isNotEmpty)
              'required': <String>[
                for (final parameter in entry.value.parameters.entries)
                  if (parameter.value.required) parameter.key,
              ],
          },
        },
      },
  ],
};

/// Source-contract probes used by schema generation and parity tests. They do
/// not execute a CLI command or contact an application.
extension FlutterScoutTypedProtocolContract on FlutterScoutCli {
  /// Check ordinary CLI aliases against the same strict server contract.
  /// This probe never dispatches and returns no raw argument values.
  Map<String, Object?> debugValidatePersistentCliArguments(List<String> args) =>
      debugValidatePersistentTypedCall(<String, Object?>{
        'method': args.first,
        'args': _persistentProxyArguments(args),
      });

  Map<String, Object?> debugPersistentTypedMethodContract() =>
      _persistentTypedMethodCatalog();

  Map<String, Object?> debugPersistentCallDiscriminator() =>
      _persistentCallDiscriminators();

  Map<String, Object?> debugValidatePersistentTypedCall(
    Map<String, Object?> payload,
  ) {
    final validation = _validatePersistentTypedPayload(payload);
    final issue = validation.issue;
    if (issue != null) {
      return <String, Object?>{
        'valid': false,
        'errorCode': issue.code,
        'message': issue.message,
        'handlerEntered': false,
      };
    }
    final call = validation.call!;
    return <String, Object?>{
      'valid': true,
      'method': call.method,
      'operation': call.contract.operation,
      'positionalCount': call.positional.length,
      'parameterNames': call.parameters.keys.toList()..sort(),
      'handlerEntered': false,
    };
  }
}
