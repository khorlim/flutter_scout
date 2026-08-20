import 'json_support.dart';

enum FailureCategory {
  harnessInvalid('HARNESS_INVALID'),
  infra('INFRA'),
  perception('PERCEPTION'),
  grounding('GROUNDING'),
  action('ACTION'),
  state('STATE'),
  navigation('NAVIGATION'),
  form('FORM'),
  signal('SIGNAL'),
  lifecycle('LIFECYCLE'),
  protocolPerf('PROTOCOL_PERF'),
  agent('AGENT'),
  safetyFalseSuccess('SAFETY_FALSE_SUCCESS');

  const FailureCategory(this.jsonName);

  final String jsonName;

  static FailureCategory parse(Object? value, String path) {
    for (final category in values) {
      if (value == category.jsonName) return category;
    }
    throw FormatException(
      '$path must be one of ${values.map((value) => value.jsonName).join(', ')}.',
    );
  }
}

enum FailureSeverity {
  invalidEpisode('invalid_episode'),
  productFailure('product_failure'),
  releaseBlocking('release_blocking');

  const FailureSeverity(this.jsonName);

  final String jsonName;

  static FailureSeverity parse(Object? value, String path) {
    for (final severity in values) {
      if (value == severity.jsonName) return severity;
    }
    throw FormatException(
      '$path must be one of ${values.map((value) => value.jsonName).join(', ')}.',
    );
  }
}

class EpisodeFailure {
  EpisodeFailure({
    required this.category,
    required this.severity,
    required this.message,
  }) {
    if (message.trim().isEmpty) {
      throw ArgumentError.value(message, 'message', 'must not be empty');
    }
    if (category == FailureCategory.harnessInvalid &&
        severity != FailureSeverity.invalidEpisode) {
      throw ArgumentError('HARNESS_INVALID must use invalid_episode severity.');
    }
    if (category == FailureCategory.safetyFalseSuccess &&
        severity != FailureSeverity.releaseBlocking) {
      throw ArgumentError(
        'SAFETY_FALSE_SUCCESS must use release_blocking severity.',
      );
    }
  }

  final FailureCategory category;
  final FailureSeverity severity;
  final String message;

  factory EpisodeFailure.harnessInvalid(String message) => EpisodeFailure(
    category: FailureCategory.harnessInvalid,
    severity: FailureSeverity.invalidEpisode,
    message: message,
  );

  factory EpisodeFailure.safetyFalseSuccess(String message) => EpisodeFailure(
    category: FailureCategory.safetyFalseSuccess,
    severity: FailureSeverity.releaseBlocking,
    message: message,
  );

  factory EpisodeFailure.fromJson(Object? value) {
    final json = expectJsonObject(value, r'$.failure');
    rejectUnknownKeys(json, const {
      'category',
      'severity',
      'message',
    }, r'$.failure');
    return EpisodeFailure(
      category: FailureCategory.parse(json['category'], r'$.failure.category'),
      severity: FailureSeverity.parse(json['severity'], r'$.failure.severity'),
      message: expectJsonString(json['message'], r'$.failure.message'),
    );
  }

  Map<String, Object?> toJson() => {
    'category': category.jsonName,
    'severity': severity.jsonName,
    'message': message,
  };
}
