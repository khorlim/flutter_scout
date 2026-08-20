part of 'flutter_scout_binding.dart';

// Canonical VM-service method descriptors. VM-service parameters are encoded
// as strings, but their semantic type is not: these contracts are enforced
// before a handler or mutation queue can be entered and are published in the
// protocol catalog for agents and compatibility tooling.

enum _HelperValueKind {
  boolean,
  integer,
  number,
  string,
  jsonObject,
  jsonArray,
}

class _HelperParameterContract {
  const _HelperParameterContract({
    required this.kind,
    this.required = false,
    this.defaultValue,
    this.minimum,
    this.maximum,
    this.minLength = 0,
    this.maximumUtf8Bytes = _maxProtocolRequestValueBytes,
    this.allowedValues,
    this.format,
    this.secrecy = 'public',
    this.objectStringValuesOnly = false,
  });

  final _HelperValueKind kind;
  final bool required;
  final String? defaultValue;
  final num? minimum;
  final num? maximum;
  final int minLength;
  final int maximumUtf8Bytes;
  final List<String>? allowedValues;
  final String? format;
  final String secrecy;
  final bool objectStringValuesOnly;

  String get semanticType => switch (kind) {
    _HelperValueKind.boolean => 'boolean',
    _HelperValueKind.integer => 'integer',
    _HelperValueKind.number => 'number',
    _HelperValueKind.string => 'string',
    _HelperValueKind.jsonObject => 'object',
    _HelperValueKind.jsonArray => 'array',
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'encoding': 'string',
    'semanticType': semanticType,
    'required': required,
    'default': defaultValue,
    'minimumLength': minLength,
    'maximumUtf8Bytes': maximumUtf8Bytes,
    'secrecy': secrecy,
    if (minimum != null) 'minimum': minimum,
    if (maximum != null) 'maximum': maximum,
    if (allowedValues != null) 'enum': allowedValues,
    if (format != null) 'format': format,
    if (objectStringValuesOnly) 'additionalPropertyType': 'string',
  };

  bool accepts(String value) {
    final bytes = _boundedHelperUtf8Length(value, maximumUtf8Bytes);
    if (bytes == null || value.runes.length < minLength) return false;
    switch (kind) {
      case _HelperValueKind.boolean:
        return value == 'true' || value == 'false';
      case _HelperValueKind.integer:
        if (!RegExp(r'^-?[0-9]+$').hasMatch(value)) return false;
        final parsed = int.tryParse(value);
        return parsed != null &&
            (minimum == null || parsed >= minimum!) &&
            (maximum == null || parsed <= maximum!);
      case _HelperValueKind.number:
        final parsed = double.tryParse(value);
        return parsed != null &&
            parsed.isFinite &&
            (minimum == null || parsed >= minimum!) &&
            (maximum == null || parsed <= maximum!);
      case _HelperValueKind.string:
        if (allowedValues != null && !allowedValues!.contains(value)) {
          return false;
        }
        return _matchesHelperFormat(value, format);
      case _HelperValueKind.jsonObject:
        try {
          final decoded = jsonDecode(value);
          return decoded is Map &&
              decoded.keys.every((key) => key is String) &&
              (!objectStringValuesOnly ||
                  decoded.values.every((item) => item is String));
        } catch (_) {
          return false;
        }
      case _HelperValueKind.jsonArray:
        try {
          return jsonDecode(value) is List;
        } catch (_) {
          return false;
        }
    }
  }
}

int? _boundedHelperUtf8Length(String value, int maximumBytes) {
  if (value.codeUnits.length > maximumBytes) return null;
  final bytes = utf8.encode(value).length;
  return bytes <= maximumBytes ? bytes : null;
}

bool _matchesHelperFormat(String value, String? format) {
  switch (format) {
    case null:
      return !value.contains('\u0000');
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
    case 'comma-list':
      return value
          .split(',')
          .map((item) => item.trim())
          .every((item) => item.isNotEmpty);
    default:
      return false;
  }
}

class _HelperConstraintSet {
  const _HelperConstraintSet({
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

class _HelperMethodContract {
  const _HelperMethodContract({
    required this.operation,
    this.parameters = const <String, _HelperParameterContract>{},
    this.constraints = const _HelperConstraintSet(),
  });

  final String operation;
  final Map<String, _HelperParameterContract> parameters;
  final _HelperConstraintSet constraints;

  Map<String, Object?> toJson() => <String, Object?>{
    'operation': operation,
    'parameters': parameters.keys.toList()..sort(),
    'parameterDescriptors': <String, Object?>{
      for (final entry in parameters.entries) entry.key: entry.value.toJson(),
    },
    'constraints': constraints.toJson(),
  };
}

const _helperText = _HelperParameterContract(
  kind: _HelperValueKind.string,
  minLength: 1,
);
const _helperBoolFalse = _HelperParameterContract(
  kind: _HelperValueKind.boolean,
  defaultValue: 'false',
);
const _helperCoordinate = _HelperParameterContract(
  kind: _HelperValueKind.number,
  minimum: -100000,
  maximum: 100000,
);
const _helperPoint = _HelperParameterContract(
  kind: _HelperValueKind.string,
  minLength: 3,
  maximumUtf8Bytes: 128,
  format: 'finite-pair',
);
const _helperWaitMs = _HelperParameterContract(
  kind: _HelperValueKind.integer,
  minimum: 0,
  maximum: 600000,
  defaultValue: '1500',
);
const _helperDirectionDown = _HelperParameterContract(
  kind: _HelperValueKind.string,
  defaultValue: 'down',
  allowedValues: <String>['up', 'down', 'left', 'right'],
);
const _helperDirectionLeft = _HelperParameterContract(
  kind: _HelperValueKind.string,
  defaultValue: 'left',
  allowedValues: <String>['up', 'down', 'left', 'right'],
);

Map<String, _HelperParameterContract> _helperExpectationParameters() =>
    const <String, _HelperParameterContract>{
      'expectText': _helperText,
      'expectGone': _helperText,
      'expectTarget': _helperText,
      'expectSelected': _helperText,
      'expectScreen': _helperText,
      'expectView': _helperText,
      'expectField': _HelperParameterContract(
        kind: _HelperValueKind.string,
        minLength: 1,
        secrecy: 'sensitive',
      ),
      'expectTimeoutMs': _HelperParameterContract(
        kind: _HelperValueKind.integer,
        minimum: 0,
        maximum: 600000,
        defaultValue: '5000',
      ),
      'pollMs': _HelperParameterContract(
        kind: _HelperValueKind.integer,
        minimum: 16,
        maximum: 2000,
        defaultValue: '150',
      ),
      'capture': _helperBoolFalse,
    };

final Map<String, _HelperParameterContract> _commonHelperParameterContracts =
    const <String, _HelperParameterContract>{
      'schemaVersion': _HelperParameterContract(
        kind: _HelperValueKind.integer,
        minimum: 1,
        maximum: 1,
      ),
      'clientProtocolMin': _HelperParameterContract(
        kind: _HelperValueKind.integer,
        minimum: 1,
        maximum: 1000000,
      ),
      'clientProtocolMax': _HelperParameterContract(
        kind: _HelperValueKind.integer,
        minimum: 1,
        maximum: 1000000,
      ),
      'commandId': _HelperParameterContract(
        kind: _HelperValueKind.string,
        minLength: 1,
        maximumUtf8Bytes: _maxProtocolCommandIdBytes,
      ),
      'deadlineEpochMs': _HelperParameterContract(
        kind: _HelperValueKind.integer,
        minimum: 0,
        maximum: 9007199254740991,
      ),
      'errorCursor': _HelperParameterContract(
        kind: _HelperValueKind.integer,
        minimum: 0,
        maximum: 9007199254740991,
      ),
      'errorsSinceCursor': _HelperParameterContract(
        kind: _HelperValueKind.integer,
        minimum: 0,
        maximum: 9007199254740991,
      ),
      'expectedStateGeneration': _HelperParameterContract(
        kind: _HelperValueKind.integer,
        minimum: 0,
        maximum: 9007199254740991,
      ),
      'idempotencyKey': _HelperParameterContract(
        kind: _HelperValueKind.string,
        minLength: 1,
        maximumUtf8Bytes: 128,
      ),
      'runId': _HelperParameterContract(
        kind: _HelperValueKind.string,
        minLength: 1,
        maximumUtf8Bytes: _maxProtocolRunIdBytes,
      ),
      'runtimeInstanceId': _HelperParameterContract(
        kind: _HelperValueKind.string,
        minLength: 1,
        maximumUtf8Bytes: _maxProtocolRuntimeIdBytes,
      ),
    };

final Map<String, _HelperMethodContract> _helperMethodContracts =
    <String, _HelperMethodContract>{
      'annotations': const _HelperMethodContract(
        operation: 'mixed',
        parameters: <String, _HelperParameterContract>{
          'action': _HelperParameterContract(
            kind: _HelperValueKind.string,
            defaultValue: 'list',
            allowedValues: <String>[
              'list',
              'targets',
              'enable',
              'disable',
              'clear',
              'delete',
              'restore',
              'resolve',
              'dismiss',
              'reopen',
              'check',
              'mark-fixed',
              'get-crop',
              'signal-handoff',
            ],
          ),
          'id': _helperText,
          'ids': _HelperParameterContract(
            kind: _HelperValueKind.string,
            minLength: 1,
            format: 'comma-list',
          ),
          'note': _HelperParameterContract(
            kind: _HelperValueKind.string,
            minLength: 1,
            secrecy: 'sensitive',
          ),
          'records': _HelperParameterContract(
            kind: _HelperValueKind.jsonArray,
            maximumUtf8Bytes: _maxProtocolRequestBulkValueBytes,
            secrecy: 'sensitive',
          ),
          'slot': _HelperParameterContract(
            kind: _HelperValueKind.string,
            defaultValue: 'before',
            allowedValues: <String>['before', 'after'],
          ),
          'status': _helperText,
        },
        constraints: _HelperConstraintSet(
          mutuallyExclusive: <List<String>>[
            <String>['id', 'ids'],
          ],
        ),
      ),
      'back': const _HelperMethodContract(
        operation: 'mutation',
        parameters: <String, _HelperParameterContract>{'waitMs': _helperWaitMs},
      ),
      'capture': const _HelperMethodContract(
        operation: 'read',
        parameters: <String, _HelperParameterContract>{
          'annotate': _helperBoolFalse,
          'annotateFilter': _HelperParameterContract(
            kind: _HelperValueKind.string,
            defaultValue: 'all',
            allowedValues: <String>['all', 'buttons', 'fields'],
          ),
          'mode': _HelperParameterContract(
            kind: _HelperValueKind.string,
            defaultValue: 'screen',
            allowedValues: <String>['screen', 'crop', 'changed-region'],
          ),
          'native': _HelperParameterContract(
            kind: _HelperValueKind.string,
            defaultValue: 'auto',
            allowedValues: <String>['auto', 'on', 'off'],
          ),
          'padding': _HelperParameterContract(
            kind: _HelperValueKind.number,
            minimum: 0,
            maximum: 256,
            defaultValue: '0',
          ),
          'pixelRatio': _HelperParameterContract(
            kind: _HelperValueKind.number,
            minimum: 0.01,
            maximum: 16,
          ),
          'rect': _HelperParameterContract(
            kind: _HelperValueKind.string,
            minLength: 7,
            maximumUtf8Bytes: 256,
            format: 'logical-rect',
          ),
          'since': _helperText,
        },
      ),
      'dismiss': const _HelperMethodContract(
        operation: 'mutation',
        parameters: <String, _HelperParameterContract>{
          'lateWaitMs': _helperWaitMs,
          'waitMs': _helperWaitMs,
        },
      ),
      'dragCancel': const _HelperMethodContract(
        operation: 'mutation',
        parameters: <String, _HelperParameterContract>{'waitMs': _helperWaitMs},
      ),
      'dragEnd': const _HelperMethodContract(
        operation: 'mutation',
        parameters: <String, _HelperParameterContract>{
          'by': _helperPoint,
          'to': _helperPoint,
          'toX': _helperCoordinate,
          'toY': _helperCoordinate,
          'waitMs': _helperWaitMs,
          'x': _helperCoordinate,
          'y': _helperCoordinate,
        },
        constraints: _HelperConstraintSet(
          requiredTogether: <List<String>>[
            <String>['x', 'y'],
            <String>['toX', 'toY'],
          ],
          mutuallyExclusive: <List<String>>[
            <String>['to', 'by'],
            <String>['to', 'toX'],
            <String>['to', 'x'],
            <String>['by', 'toX'],
            <String>['by', 'x'],
            <String>['toX', 'x'],
          ],
        ),
      ),
      'dragMove': const _HelperMethodContract(
        operation: 'mutation',
        parameters: <String, _HelperParameterContract>{
          'by': _helperPoint,
          'to': _helperPoint,
          'toX': _helperCoordinate,
          'toY': _helperCoordinate,
          'x': _helperCoordinate,
          'y': _helperCoordinate,
        },
        constraints: _HelperConstraintSet(
          atLeastOneOf: <List<String>>[
            <String>['to', 'by', 'toX', 'x'],
          ],
          requiredTogether: <List<String>>[
            <String>['x', 'y'],
            <String>['toX', 'toY'],
          ],
          mutuallyExclusive: <List<String>>[
            <String>['to', 'by'],
            <String>['to', 'toX'],
            <String>['to', 'x'],
            <String>['by', 'toX'],
            <String>['by', 'x'],
            <String>['toX', 'x'],
          ],
        ),
      ),
      'dragStart': const _HelperMethodContract(
        operation: 'mutation',
        parameters: <String, _HelperParameterContract>{
          'point': _helperPoint,
          'target': _helperText,
          'x': _helperCoordinate,
          'y': _helperCoordinate,
        },
        constraints: _HelperConstraintSet(
          requiredTogether: <List<String>>[
            <String>['x', 'y'],
          ],
          mutuallyExclusive: <List<String>>[
            <String>['target', 'point'],
            <String>['target', 'x'],
            <String>['point', 'x'],
          ],
        ),
      ),
      'dragStatus': const _HelperMethodContract(operation: 'read'),
      'fill': _HelperMethodContract(
        operation: 'mutation',
        parameters: <String, _HelperParameterContract>{
          ..._helperExpectationParameters(),
          'values': const _HelperParameterContract(
            kind: _HelperValueKind.jsonObject,
            required: true,
            maximumUtf8Bytes: _maxProtocolRequestBulkValueBytes,
            secrecy: 'secret',
            objectStringValuesOnly: true,
          ),
          'waitMs': _helperWaitMs,
        },
      ),
      'input': _HelperMethodContract(
        operation: 'mutation',
        parameters: <String, _HelperParameterContract>{
          ..._helperExpectationParameters(),
          'target': const _HelperParameterContract(
            kind: _HelperValueKind.string,
            minLength: 1,
            defaultValue: 'focused',
          ),
          'value': const _HelperParameterContract(
            kind: _HelperValueKind.string,
            required: true,
            maximumUtf8Bytes: _maxProtocolRequestBulkValueBytes,
            secrecy: 'secret',
          ),
          'waitMs': _helperWaitMs,
        },
      ),
      'inspect': const _HelperMethodContract(
        operation: 'read',
        parameters: <String, _HelperParameterContract>{
          'brief': _helperBoolFalse,
          'contains': _helperBoolFalse,
          'maxCandidates': _HelperParameterContract(
            kind: _HelperValueKind.integer,
            minimum: 1,
            maximum: 100,
            defaultValue: '20',
          ),
          'maxItems': _HelperParameterContract(
            kind: _HelperValueKind.integer,
            minimum: 1,
            maximum: 100,
            defaultValue: '20',
          ),
          'maxResponseBytes': _HelperParameterContract(
            kind: _HelperValueKind.integer,
            minimum: 4096,
            maximum: 1048576,
            defaultValue: '65536',
          ),
          'navigationAction': _HelperParameterContract(
            kind: _HelperValueKind.string,
            allowedValues: <String>['where', 'locate'],
          ),
          'sections': _helperText,
          'since': _helperText,
          'surfaceOnly': _helperBoolFalse,
          'target': _helperText,
          'text': _helperText,
          'within': _helperText,
        },
        constraints: _HelperConstraintSet(
          mutuallyExclusive: <List<String>>[
            <String>['since', 'brief'],
            <String>['since', 'surfaceOnly'],
            <String>['since', 'sections'],
            <String>['since', 'maxItems'],
            <String>['text', 'target'],
          ],
        ),
      ),
      'longPress': const _HelperMethodContract(
        operation: 'mutation',
        parameters: <String, _HelperParameterContract>{
          'durationMs': _HelperParameterContract(
            kind: _HelperValueKind.integer,
            minimum: 1,
            maximum: 600000,
            defaultValue: '600',
          ),
          'target': _helperText,
          'waitMs': _helperWaitMs,
          'x': _helperCoordinate,
          'y': _helperCoordinate,
        },
        constraints: _HelperConstraintSet(
          atLeastOneOf: <List<String>>[
            <String>['target', 'x'],
          ],
          requiredTogether: <List<String>>[
            <String>['x', 'y'],
          ],
          mutuallyExclusive: <List<String>>[
            <String>['target', 'x'],
            <String>['target', 'y'],
          ],
        ),
      ),
      'record': const _HelperMethodContract(
        operation: 'mixed',
        parameters: <String, _HelperParameterContract>{
          'action': _HelperParameterContract(
            kind: _HelperValueKind.string,
            defaultValue: 'status',
            allowedValues: <String>[
              'start',
              'stop',
              'pause',
              'resume',
              'undo',
              'status',
              'steps',
            ],
          ),
          'discard': _helperBoolFalse,
          'feature': _HelperParameterContract(
            kind: _HelperValueKind.string,
            minLength: 1,
            secrecy: 'sensitive',
          ),
          'name': _HelperParameterContract(
            kind: _HelperValueKind.string,
            minLength: 1,
            secrecy: 'sensitive',
          ),
          'title': _HelperParameterContract(
            kind: _HelperValueKind.string,
            minLength: 1,
            secrecy: 'sensitive',
          ),
        },
      ),
      'reveal': const _HelperMethodContract(
        operation: 'mutation',
        parameters: <String, _HelperParameterContract>{
          'contains': _helperBoolFalse,
          'direction': _helperDirectionDown,
          'distance': _HelperParameterContract(
            kind: _HelperValueKind.number,
            minimum: 1,
            maximum: 5000,
          ),
          'maxActions': _HelperParameterContract(
            kind: _HelperValueKind.integer,
            minimum: 1,
            maximum: 50,
            defaultValue: '8',
          ),
          'maxDistance': _HelperParameterContract(
            kind: _HelperValueKind.number,
            minimum: 1,
            maximum: 100000,
          ),
          'maxResponseBytes': _HelperParameterContract(
            kind: _HelperValueKind.integer,
            minimum: 4096,
            maximum: 1048576,
            defaultValue: '65536',
          ),
          'target': _helperText,
          'text': _helperText,
          'timeoutMs': _HelperParameterContract(
            kind: _HelperValueKind.integer,
            minimum: 100,
            maximum: 12000,
            defaultValue: '8000',
          ),
          'within': _helperText,
        },
        constraints: _HelperConstraintSet(
          exactlyOneOf: <List<String>>[
            <String>['text', 'target'],
          ],
        ),
      ),
      'scroll': const _HelperMethodContract(
        operation: 'mutation',
        parameters: <String, _HelperParameterContract>{
          'direction': _helperDirectionDown,
          'distance': _HelperParameterContract(
            kind: _HelperValueKind.number,
            minimum: 0,
            maximum: 100000,
            defaultValue: '280',
          ),
          'point': _helperPoint,
          'target': _helperText,
          'to': _helperPoint,
          'toX': _helperCoordinate,
          'toY': _helperCoordinate,
          'waitMs': _helperWaitMs,
          'x': _helperCoordinate,
          'y': _helperCoordinate,
        },
        constraints: _HelperConstraintSet(
          requiredTogether: <List<String>>[
            <String>['x', 'y'],
            <String>['toX', 'toY'],
          ],
          mutuallyExclusive: <List<String>>[
            <String>['target', 'point'],
            <String>['target', 'x'],
            <String>['point', 'x'],
            <String>['to', 'toX'],
          ],
        ),
      ),
      'scrollTo': const _HelperMethodContract(
        operation: 'mutation',
        parameters: <String, _HelperParameterContract>{
          'direction': _helperDirectionDown,
          'distance': _HelperParameterContract(
            kind: _HelperValueKind.number,
            minimum: 0,
            maximum: 100000,
          ),
          'maxScrolls': _HelperParameterContract(
            kind: _HelperValueKind.integer,
            minimum: 1,
            maximum: 1000,
            defaultValue: '20',
          ),
          'target': _HelperParameterContract(
            kind: _HelperValueKind.string,
            required: true,
            minLength: 1,
          ),
          'waitMs': _helperWaitMs,
        },
      ),
      'swipe': const _HelperMethodContract(
        operation: 'mutation',
        parameters: <String, _HelperParameterContract>{
          'direction': _helperDirectionLeft,
          'distance': _HelperParameterContract(
            kind: _HelperValueKind.number,
            minimum: 0,
            maximum: 100000,
            defaultValue: '320',
          ),
          'point': _helperPoint,
          'target': _helperText,
          'to': _helperPoint,
          'toX': _helperCoordinate,
          'toY': _helperCoordinate,
          'waitMs': _helperWaitMs,
          'x': _helperCoordinate,
          'y': _helperCoordinate,
        },
        constraints: _HelperConstraintSet(
          requiredTogether: <List<String>>[
            <String>['x', 'y'],
            <String>['toX', 'toY'],
          ],
          mutuallyExclusive: <List<String>>[
            <String>['target', 'point'],
            <String>['target', 'x'],
            <String>['point', 'x'],
            <String>['to', 'toX'],
          ],
        ),
      ),
      'tap': _HelperMethodContract(
        operation: 'mutation',
        parameters: <String, _HelperParameterContract>{
          ..._helperExpectationParameters(),
          'lateWaitMs': _helperWaitMs,
          'target': const _HelperParameterContract(
            kind: _HelperValueKind.string,
            minLength: 1,
          ),
          'waitMs': _helperWaitMs,
          'x': _helperCoordinate,
          'y': _helperCoordinate,
        },
        constraints: const _HelperConstraintSet(
          atLeastOneOf: <List<String>>[
            <String>['target', 'x'],
          ],
          requiredTogether: <List<String>>[
            <String>['x', 'y'],
          ],
          mutuallyExclusive: <List<String>>[
            <String>['target', 'x'],
            <String>['target', 'y'],
          ],
        ),
      ),
      'tapText': _HelperMethodContract(
        operation: 'mutation',
        parameters: <String, _HelperParameterContract>{
          ..._helperExpectationParameters(),
          'allowMismatch': _helperBoolFalse,
          'contains': _helperBoolFalse,
          'lateWaitMs': _helperWaitMs,
          'target': const _HelperParameterContract(
            kind: _HelperValueKind.string,
            minLength: 1,
          ),
          'text': const _HelperParameterContract(
            kind: _HelperValueKind.string,
            minLength: 1,
          ),
          'waitMs': _helperWaitMs,
        },
        constraints: const _HelperConstraintSet(
          exactlyOneOf: <List<String>>[
            <String>['text', 'target'],
          ],
        ),
      ),
      'waitFor': const _HelperMethodContract(
        operation: 'read',
        parameters: <String, _HelperParameterContract>{
          'field': _HelperParameterContract(
            kind: _HelperValueKind.string,
            minLength: 1,
            secrecy: 'sensitive',
          ),
          'gone': _helperText,
          'pollMs': _HelperParameterContract(
            kind: _HelperValueKind.integer,
            minimum: 16,
            maximum: 2000,
            defaultValue: '150',
          ),
          'screen': _helperText,
          'selected': _helperText,
          'target': _helperText,
          'text': _helperText,
          'timeoutMs': _HelperParameterContract(
            kind: _HelperValueKind.integer,
            minimum: 0,
            maximum: 600000,
            defaultValue: '5000',
          ),
          'view': _helperText,
        },
        constraints: _HelperConstraintSet(
          atLeastOneOf: <List<String>>[
            <String>[
              'text',
              'gone',
              'target',
              'selected',
              'screen',
              'view',
              'field',
            ],
          ],
        ),
      ),
      'waitStable': const _HelperMethodContract(
        operation: 'read',
        parameters: <String, _HelperParameterContract>{
          'timeoutMs': _HelperParameterContract(
            kind: _HelperValueKind.integer,
            minimum: 0,
            maximum: 600000,
            defaultValue: '3000',
          ),
        },
      ),
    };

Map<String, Object?> _helperTypedMethodCatalog() => <String, Object?>{
  for (final entry in _helperMethodContracts.entries)
    'ext.flutter_scout.${entry.key}': entry.value.toJson(),
};

({String code, String message, Map<String, Object?> details})?
_helperTypedSemanticIssue(String command, Map<String, String> params) {
  final method = _helperMethodContracts[command];
  if (method == null) return null;
  for (final entry in <String, _HelperParameterContract>{
    ..._commonHelperParameterContracts,
    ...method.parameters,
  }.entries) {
    final value = params[entry.key];
    if (value == null) {
      if (entry.value.required) {
        return (
          code: 'invalid_parameter_value',
          message: 'The typed helper request is missing a required parameter.',
          details: <String, Object?>{
            'method': 'ext.flutter_scout.$command',
            'parameter': entry.key,
            'expectedSemanticType': entry.value.semanticType,
            'handlerEntered': false,
          },
        );
      }
      continue;
    }
    if (!entry.value.accepts(value)) {
      return (
        code: 'invalid_parameter_value',
        message:
            'A typed helper parameter violates its declared semantic type or bound.',
        details: <String, Object?>{
          'method': 'ext.flutter_scout.$command',
          'parameter': entry.key,
          'expectedSemanticType': entry.value.semanticType,
          'handlerEntered': false,
        },
      );
    }
  }

  final present = params.entries
      .where((entry) => entry.value.isNotEmpty && entry.value != 'false')
      .map((entry) => entry.key)
      .toSet();
  ({String code, String message, Map<String, Object?> details})? check(
    List<List<String>> groups,
    bool Function(int count, int length) invalid,
    String description,
  ) {
    for (final group in groups) {
      final count = group.where(present.contains).length;
      if (invalid(count, group.length)) {
        return (
          code: 'invalid_parameter_value',
          message: 'Typed helper parameters violate $description.',
          details: <String, Object?>{
            'method': 'ext.flutter_scout.$command',
            'constraint': description,
            'parameters': group,
            'handlerEntered': false,
          },
        );
      }
    }
    return null;
  }

  return check(
        method.constraints.atLeastOneOf,
        (count, _) => count == 0,
        'atLeastOneOf',
      ) ??
      check(
        method.constraints.exactlyOneOf,
        (count, _) => count != 1,
        'exactlyOneOf',
      ) ??
      check(
        method.constraints.requiredTogether,
        (count, length) => count != 0 && count != length,
        'requiredTogether',
      ) ??
      check(
        method.constraints.mutuallyExclusive,
        (count, _) => count > 1,
        'mutuallyExclusive',
      );
}
