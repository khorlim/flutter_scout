import 'dart:convert';

const int publicFixtureConfigurationSchemaVersion = 1;
const String publicFixtureRevision = 'public-fixture-v1';

const Set<String> publicFixtureFamilies = <String>{
  'forms',
  'lists',
  'grids',
  'nested_scroll',
  'tabs',
  'dialogs_sheets_menus',
  'pickers',
  'custom_painted',
  'gesture',
  'lifecycle_reconnect',
  'faults',
  'security_privacy',
};

const Set<String> publicFixturePerturbations = <String>{
  'viewport',
  'device_pixel_ratio',
  'orientation',
  'content_order',
  'content_length',
  'initial_scroll_state',
  'initial_tab_state',
  'initial_modal_state',
  'initial_focus_state',
  'animation_delay',
  'network_delay',
  'semantics_degradation',
  'key_degradation',
};

/// Strict evaluator-only configuration accepted by the verification app.
///
/// This type intentionally has no Flutter Scout dependency. The authenticated
/// evaluator extension supplies it out of band before each deterministic
/// reset; the running fixture never derives expected truth from Scout output.
class PublicFixtureConfiguration {
  PublicFixtureConfiguration._({
    required this.taskId,
    required this.templateId,
    required this.variantId,
    required this.seed,
    required this.family,
    required this.patternId,
    required this.title,
    required this.targetLabel,
    required this.decoyLabel,
    required this.inputLabel,
    required this.inputValue,
    required this.completionValue,
    required this.contentLength,
    required this.targetIndex,
    required this.initialPage,
    required this.delayMs,
    required this.initialModalOpen,
    required this.initialFocus,
    required this.labelOnlyTarget,
    required this.successPredicateId,
    required this.forbiddenPredicateId,
    required this.perturbations,
  });

  final String taskId;
  final String templateId;
  final String variantId;
  final int seed;
  final String family;
  final String patternId;
  final String title;
  final String targetLabel;
  final String decoyLabel;
  final String inputLabel;
  final String inputValue;
  final String completionValue;
  final int contentLength;
  final int targetIndex;
  final int initialPage;
  final int delayMs;
  final bool initialModalOpen;
  final bool initialFocus;
  final bool labelOnlyTarget;
  final String successPredicateId;
  final String forbiddenPredicateId;
  final Map<String, String> perturbations;

  factory PublicFixtureConfiguration.fromEncoded(String encoded) {
    if (encoded.isEmpty || encoded.length > 16 * 1024) {
      throw const FormatException(
        'The public fixture configuration must be bounded.',
      );
    }
    return PublicFixtureConfiguration.fromJson(jsonDecode(encoded));
  }

  factory PublicFixtureConfiguration.fromJson(Object? value) {
    final json = _object(value, r'$');
    const allowed = <String>{
      'schemaVersion',
      'revision',
      'taskId',
      'templateId',
      'variantId',
      'seed',
      'family',
      'patternId',
      'title',
      'targetLabel',
      'decoyLabel',
      'inputLabel',
      'inputValue',
      'completionValue',
      'contentLength',
      'targetIndex',
      'initialPage',
      'delayMs',
      'initialModalOpen',
      'initialFocus',
      'labelOnlyTarget',
      'successPredicateId',
      'forbiddenPredicateId',
      'perturbations',
    };
    final unknown = json.keys.where((key) => !allowed.contains(key));
    if (unknown.isNotEmpty || json.length != allowed.length) {
      throw const FormatException(
        'The public fixture configuration fields are invalid.',
      );
    }
    if (json['schemaVersion'] != publicFixtureConfigurationSchemaVersion ||
        json['revision'] != publicFixtureRevision) {
      throw const FormatException(
        'The public fixture configuration version is unsupported.',
      );
    }
    final taskId = _identifier(json['taskId'], r'$.taskId');
    final templateId = _identifier(json['templateId'], r'$.templateId');
    final variantId = _identifier(json['variantId'], r'$.variantId');
    final seed = _integer(json['seed'], r'$.seed');
    final patternId = _identifier(json['patternId'], r'$.patternId');
    final completionValue = _string(
      json['completionValue'],
      r'$.completionValue',
      160,
    );
    final successPredicateId = _identifier(
      json['successPredicateId'],
      r'$.successPredicateId',
    );
    final forbiddenPredicateId = _identifier(
      json['forbiddenPredicateId'],
      r'$.forbiddenPredicateId',
    );
    if (taskId != '$templateId.$variantId' ||
        patternId != templateId ||
        !RegExp(r'^variant-[1-5]$').hasMatch(variantId) ||
        seed <= 0 ||
        seed > 1000000000 ||
        completionValue != 'fixture-complete.$taskId.$seed' ||
        successPredicateId != 'predicate.$taskId.completed' ||
        forbiddenPredicateId != 'predicate.$taskId.forbidden') {
      throw const FormatException(
        'The public fixture identity fields are inconsistent.',
      );
    }
    final family = _string(json['family'], r'$.family', 64);
    if (!publicFixtureFamilies.contains(family)) {
      throw const FormatException('The public fixture family is unsupported.');
    }
    final contentLength = _integer(json['contentLength'], r'$.contentLength');
    final targetIndex = _integer(json['targetIndex'], r'$.targetIndex');
    final initialPage = _integer(json['initialPage'], r'$.initialPage');
    final delayMs = _integer(json['delayMs'], r'$.delayMs');
    if (contentLength < 8 ||
        contentLength > 120 ||
        targetIndex < 0 ||
        targetIndex >= contentLength ||
        initialPage < 0 ||
        initialPage > 2 ||
        delayMs < 0 ||
        delayMs > 2000) {
      throw const FormatException(
        'The public fixture numeric bounds are invalid.',
      );
    }
    final perturbationJson = _object(json['perturbations'], r'$.perturbations');
    if (perturbationJson.isEmpty || perturbationJson.length > 13) {
      throw const FormatException(
        'The public fixture perturbations are invalid.',
      );
    }
    final perturbations = <String, String>{
      for (final entry in perturbationJson.entries)
        _identifier(entry.key, r'$.perturbations.key'): _string(
          entry.value,
          r'$.perturbations.${entry.key}',
          96,
        ),
    };
    if (perturbations.keys.any(
      (key) => !publicFixturePerturbations.contains(key),
    )) {
      throw const FormatException(
        'The public fixture perturbation set is unsupported.',
      );
    }
    return PublicFixtureConfiguration._(
      taskId: taskId,
      templateId: templateId,
      variantId: variantId,
      seed: seed,
      family: family,
      patternId: patternId,
      title: _string(json['title'], r'$.title', 160),
      targetLabel: _string(json['targetLabel'], r'$.targetLabel', 160),
      decoyLabel: _string(json['decoyLabel'], r'$.decoyLabel', 160),
      inputLabel: _string(json['inputLabel'], r'$.inputLabel', 160),
      inputValue: _string(json['inputValue'], r'$.inputValue', 160),
      completionValue: completionValue,
      contentLength: contentLength,
      targetIndex: targetIndex,
      initialPage: initialPage,
      delayMs: delayMs,
      initialModalOpen: _boolean(
        json['initialModalOpen'],
        r'$.initialModalOpen',
      ),
      initialFocus: _boolean(json['initialFocus'], r'$.initialFocus'),
      labelOnlyTarget: _boolean(json['labelOnlyTarget'], r'$.labelOnlyTarget'),
      successPredicateId: successPredicateId,
      forbiddenPredicateId: forbiddenPredicateId,
      perturbations: Map<String, String>.unmodifiable(perturbations),
    );
  }
}

Map<String, Object?> _object(Object? value, String path) {
  if (value is! Map) throw FormatException('$path must be an object.');
  return <String, Object?>{
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

String _string(Object? value, String path, int maximumLength) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > maximumLength ||
      value.codeUnits.any((unit) => unit == 0)) {
    throw FormatException('$path must be a bounded non-empty string.');
  }
  return value;
}

String _identifier(Object? value, String path) {
  final text = _string(value, path, 192);
  if (!RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(text)) {
    throw FormatException('$path must be an identifier.');
  }
  return text;
}

int _integer(Object? value, String path) {
  if (value is! int) throw FormatException('$path must be an integer.');
  return value;
}

bool _boolean(Object? value, String path) {
  if (value is! bool) throw FormatException('$path must be a boolean.');
  return value;
}
