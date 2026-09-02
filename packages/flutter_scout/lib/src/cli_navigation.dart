part of 'flutter_scout_cli.dart';

// part: deterministic orientation, location, bounded reveal, and snapshot deltas.

extension _CliNavigation on FlutterScoutCli {
  Future<int> _where(List<String> args) async {
    final parser = ArgParser()
      ..addOption(
        'max-response-bytes',
        defaultsTo: '65536',
        help: 'Bound the helper payload (4096-1048576 bytes).',
      )
      ..addFlag(
        'verbose',
        defaultsTo: false,
        negatable: false,
        help: 'Print full navigation geometry and provenance.',
      );
    final parsed = parser.parse(args);
    if (parsed.rest.isNotEmpty) {
      throw const ScoutCliException(
        'usage',
        'where accepts no positional arguments.',
      );
    }
    final maxResponseBytes = _boundedNavigationInteger(
      parsed.option('max-response-bytes'),
      name: '--max-response-bytes',
      minimum: 4096,
      maximum: 1048576,
    );
    return _callAndPrint(
      'ext.flutter_scout.inspect',
      params: <String, String>{
        'navigationAction': 'where',
        'maxResponseBytes': '$maxResponseBytes',
      },
      assertNoErrors: false,
      outputTransform: parsed.flag('verbose') ? null : _compactWhere,
      prettyOutput: parsed.flag('verbose'),
    );
  }

  Future<int> _locate(List<String> args) async {
    final parser = ArgParser()
      ..addOption('text', help: 'Locate visible/built text without mutating.')
      ..addOption('target', help: 'Locate a Scout handle without mutating.')
      ..addOption(
        'within',
        help: 'Restrict candidates to one explicit scroll region handle.',
      )
      ..addFlag(
        'contains',
        defaultsTo: false,
        negatable: false,
        help: 'Allow the helper text resolver\'s bounded loose tier.',
      )
      ..addOption(
        'max-candidates',
        defaultsTo: '20',
        help: 'Maximum ranked candidates returned (1-100).',
      )
      ..addOption(
        'max-response-bytes',
        defaultsTo: '65536',
        help: 'Bound the helper payload (4096-1048576 bytes).',
      );
    final parsed = parser.parse(args);
    final positional = parsed.rest;
    if (positional.length > 1) {
      throw const ScoutCliException(
        'usage',
        'locate accepts at most one positional target handle.',
      );
    }
    final text = parsed.option('text');
    final explicitTarget = parsed.option('target');
    final positionalTarget = positional.isEmpty ? null : positional.single;
    if (explicitTarget != null && positionalTarget != null) {
      throw const ScoutCliException(
        'usage',
        'Choose --target or one positional target, not both.',
      );
    }
    final target = explicitTarget ?? positionalTarget;
    if ((text == null || text.isEmpty) == (target == null || target.isEmpty)) {
      throw const ScoutCliException(
        'usage',
        'Provide exactly one of --text <text>, --target <handle>, or a positional handle.',
      );
    }
    final maxCandidates = _boundedNavigationInteger(
      parsed.option('max-candidates'),
      name: '--max-candidates',
      minimum: 1,
      maximum: 100,
    );
    final maxResponseBytes = _boundedNavigationInteger(
      parsed.option('max-response-bytes'),
      name: '--max-response-bytes',
      minimum: 4096,
      maximum: 1048576,
    );
    return _callAndPrint(
      'ext.flutter_scout.inspect',
      params: <String, String>{
        'navigationAction': 'locate',
        if (text != null && text.isNotEmpty) 'text': text,
        if (target != null && target.isNotEmpty) 'target': target,
        if ((parsed.option('within') ?? '').isNotEmpty)
          'within': parsed.option('within')!,
        if (parsed.flag('contains')) 'contains': 'true',
        'maxCandidates': '$maxCandidates',
        'maxResponseBytes': '$maxResponseBytes',
      },
      assertNoErrors: false,
    );
  }

  Future<int> _reveal(List<String> args) async {
    final parser = ArgParser()
      ..addOption('text', help: 'Reveal text using the central resolver.')
      ..addOption('target', help: 'Reveal a Scout handle.')
      ..addOption(
        'within',
        help:
            'Explicit scroll region. Required whenever more than one is visible.',
      )
      ..addOption(
        'direction',
        defaultsTo: 'down',
        allowed: const ['up', 'down', 'left', 'right'],
      )
      ..addOption(
        'max-actions',
        defaultsTo: '8',
        help: 'Maximum exact scroll-position mutations (1-50).',
      )
      ..addOption(
        'distance',
        help: 'Distance per action in logical Flutter pixels (1-5000).',
      )
      ..addOption(
        'max-distance',
        help: 'Total logical-pixel search bound (up to 100000).',
      )
      ..addOption(
        'timeout',
        defaultsTo: '8000',
        help: 'Helper search deadline in milliseconds (100-12000).',
      )
      ..addFlag(
        'contains',
        defaultsTo: false,
        negatable: false,
        help: 'Allow the helper text resolver\'s bounded loose tier.',
      )
      ..addOption(
        'max-response-bytes',
        defaultsTo: '65536',
        help: 'Bound the helper payload (4096-1048576 bytes).',
      )
      ..addFlag(
        'allow-errors',
        defaultsTo: false,
        negatable: false,
        help: 'Allow fresh blocking runtime/log errors.',
      );
    final parsed = parser.parse(args);
    final positional = parsed.rest;
    if (positional.length > 1) {
      throw const ScoutCliException(
        'usage',
        'reveal accepts at most one positional target handle.',
      );
    }
    final text = parsed.option('text');
    final explicitTarget = parsed.option('target');
    final positionalTarget = positional.isEmpty ? null : positional.single;
    if (explicitTarget != null && positionalTarget != null) {
      throw const ScoutCliException(
        'usage',
        'Choose --target or one positional target, not both.',
      );
    }
    final target = explicitTarget ?? positionalTarget;
    if ((text == null || text.isEmpty) == (target == null || target.isEmpty)) {
      throw const ScoutCliException(
        'usage',
        'Provide exactly one of --text <text>, --target <handle>, or a positional handle.',
      );
    }
    final maxActions = _boundedNavigationInteger(
      parsed.option('max-actions'),
      name: '--max-actions',
      minimum: 1,
      maximum: 50,
    );
    final timeoutMs = _boundedNavigationInteger(
      parsed.option('timeout'),
      name: '--timeout',
      minimum: 100,
      maximum: 12000,
    );
    final maxResponseBytes = _boundedNavigationInteger(
      parsed.option('max-response-bytes'),
      name: '--max-response-bytes',
      minimum: 4096,
      maximum: 1048576,
    );
    final distance = _boundedNavigationDouble(
      parsed.option('distance'),
      name: '--distance',
      minimum: 1,
      maximum: 5000,
    );
    final maxDistance = _boundedNavigationDouble(
      parsed.option('max-distance'),
      name: '--max-distance',
      minimum: distance ?? 1,
      maximum: 100000,
    );
    return _callAndPrint(
      'ext.flutter_scout.reveal',
      params: <String, String>{
        if (text != null && text.isNotEmpty) 'text': text,
        if (target != null && target.isNotEmpty) 'target': target,
        if ((parsed.option('within') ?? '').isNotEmpty)
          'within': parsed.option('within')!,
        'direction': parsed.option('direction')!,
        'maxActions': '$maxActions',
        if (distance != null) 'distance': '$distance',
        if (maxDistance != null) 'maxDistance': '$maxDistance',
        'timeoutMs': '$timeoutMs',
        if (parsed.flag('contains')) 'contains': 'true',
        'maxResponseBytes': '$maxResponseBytes',
      },
      callTimeout: Duration(milliseconds: timeoutMs + 8000),
      assertNoErrors: !parsed.flag('allow-errors'),
    );
  }

  int _boundedNavigationInteger(
    String? value, {
    required String name,
    required int minimum,
    required int maximum,
  }) {
    final parsed = int.tryParse(value ?? '');
    if (parsed == null || parsed < minimum || parsed > maximum) {
      throw ScoutCliException(
        'usage',
        '$name must be an integer from $minimum to $maximum.',
      );
    }
    return parsed;
  }

  double? _boundedNavigationDouble(
    String? value, {
    required String name,
    required double minimum,
    required double maximum,
  }) {
    if (value == null || value.isEmpty) return null;
    final parsed = double.tryParse(value);
    if (parsed == null ||
        !parsed.isFinite ||
        parsed < minimum ||
        parsed > maximum) {
      throw ScoutCliException(
        'usage',
        '$name must be a finite number from $minimum to $maximum.',
      );
    }
    return parsed;
  }
}
