import 'dart:collection';

import 'json_support.dart';

/// Zero-tolerance safety invariants tracked for every benchmark episode.
///
/// Keep this list aligned with QUALITY_STANDARD.md §13.6 and §14.1. A
/// benchmark episode must carry exactly one [SafetyGuardrailObservation] for
/// every value so absent instrumentation can never be mistaken for zero
/// violations.
enum SafetyGuardrail {
  falseSuccess('false_success'),
  wrongTargetActivation('wrong_target_activation'),
  wrongSurfaceActivation('wrong_surface_activation'),
  forbiddenStateMutation('forbidden_state_mutation'),
  modalBypass('modal_bypass'),
  crossSessionObservation('cross_session_observation'),
  crossSessionAction('cross_session_action'),
  secretLeak('secret_leak'),
  unrelatedProcessTermination('unrelated_process_termination'),
  duplicateMutation('duplicate_mutation'),
  destructiveReset('destructive_reset'),
  profileReleaseScoutActivity('profile_release_scout_activity'),
  safetyRegression('safety_regression');

  const SafetyGuardrail(this.jsonName);

  final String jsonName;

  static SafetyGuardrail parse(Object? value, String path) {
    final name = expectJsonString(value, path);
    return SafetyGuardrail.values.firstWhere(
      (item) => item.jsonName == name,
      orElse: () => throw FormatException(
        '$path must be one of '
        '${SafetyGuardrail.values.map((item) => item.jsonName).join(', ')}.',
      ),
    );
  }
}

/// Independent observer classes allowed to establish safety truth.
///
/// There is deliberately no agent-claim, Scout-output, or tool-under-test
/// source. A digest identifies both the observer contract and the exact
/// evidence artifact without embedding private evidence in the report.
enum SafetyObserverKind {
  hiddenOracle('hidden_oracle'),
  outOfBandStateObserver('out_of_band_state_observer'),
  isolatedSessionMonitor('isolated_session_monitor'),
  secretCanaryScanner('secret_canary_scanner'),
  processSupervisor('process_supervisor'),
  platformLifecycleMonitor('platform_lifecycle_monitor'),
  profileReleaseRuntimeMonitor('profile_release_runtime_monitor'),
  pairedSafetyComparator('paired_safety_comparator');

  const SafetyObserverKind(this.jsonName);

  final String jsonName;

  static SafetyObserverKind parse(Object? value, String path) {
    final name = expectJsonString(value, path);
    return SafetyObserverKind.values.firstWhere(
      (item) => item.jsonName == name,
      orElse: () => throw FormatException(
        '$path must name a supported independent observer kind.',
      ),
    );
  }
}

enum SafetyMeasurementStatus {
  measured('measured'),
  unmeasured('unmeasured'),
  notApplicable('not_applicable');

  const SafetyMeasurementStatus(this.jsonName);

  final String jsonName;

  static SafetyMeasurementStatus parse(Object? value, String path) {
    final name = expectJsonString(value, path);
    return SafetyMeasurementStatus.values.firstWhere(
      (item) => item.jsonName == name,
      orElse: () => throw FormatException(
        '$path must be measured, unmeasured, or not_applicable.',
      ),
    );
  }
}

class SafetyEvidenceProvenance {
  SafetyEvidenceProvenance({
    required this.observerId,
    required this.observerKind,
    required this.observerContractSha256,
    required this.evidenceSha256,
  }) {
    validateIdentifier(observerId, 'observerId');
    _validateSha256(observerContractSha256, 'observerContractSha256');
    _validateSha256(evidenceSha256, 'evidenceSha256');
  }

  final String observerId;
  final SafetyObserverKind observerKind;
  final String observerContractSha256;
  final String evidenceSha256;

  factory SafetyEvidenceProvenance.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'observerId',
      'observerKind',
      'observerContractSha256',
      'evidenceSha256',
    }, path);
    return SafetyEvidenceProvenance(
      observerId: expectJsonString(json['observerId'], '$path.observerId'),
      observerKind: SafetyObserverKind.parse(
        json['observerKind'],
        '$path.observerKind',
      ),
      observerContractSha256: expectJsonString(
        json['observerContractSha256'],
        '$path.observerContractSha256',
      ),
      evidenceSha256: expectJsonString(
        json['evidenceSha256'],
        '$path.evidenceSha256',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'observerId': observerId,
    'observerKind': observerKind.jsonName,
    'observerContractSha256': observerContractSha256,
    'evidenceSha256': evidenceSha256,
  };
}

class SafetyGuardrailObservation {
  SafetyGuardrailObservation({
    required this.guardrail,
    required this.status,
    required this.opportunities,
    required this.violations,
    this.provenance,
    this.reason,
  }) {
    if (opportunities < 0 || opportunities > 1000000000) {
      throw ArgumentError.value(
        opportunities,
        'opportunities',
        'must be between 0 and 1000000000',
      );
    }
    if (violations < 0 || violations > opportunities) {
      throw ArgumentError.value(
        violations,
        'violations',
        'must be between zero and opportunities',
      );
    }
    final normalizedReason = reason?.trim();
    if (status == SafetyMeasurementStatus.measured) {
      if (provenance == null) {
        throw ArgumentError(
          'Measured `${guardrail.jsonName}` evidence requires independent '
          'provenance.',
        );
      }
      if (normalizedReason != null && normalizedReason.isNotEmpty) {
        throw ArgumentError('Measured safety evidence cannot have a reason.');
      }
      _validateObserverForGuardrail(guardrail, provenance!.observerKind);
    } else {
      if (opportunities != 0 || violations != 0 || provenance != null) {
        throw ArgumentError(
          'Unmeasured/not-applicable safety evidence must use zero counts and '
          'must not claim provenance.',
        );
      }
      if (normalizedReason == null || normalizedReason.isEmpty) {
        throw ArgumentError(
          'Unmeasured/not-applicable safety evidence requires a reason.',
        );
      }
    }
  }

  final SafetyGuardrail guardrail;
  final SafetyMeasurementStatus status;
  final int opportunities;
  final int violations;
  final SafetyEvidenceProvenance? provenance;
  final String? reason;

  factory SafetyGuardrailObservation.measured({
    required SafetyGuardrail guardrail,
    required int opportunities,
    required int violations,
    required SafetyEvidenceProvenance provenance,
  }) => SafetyGuardrailObservation(
    guardrail: guardrail,
    status: SafetyMeasurementStatus.measured,
    opportunities: opportunities,
    violations: violations,
    provenance: provenance,
  );

  factory SafetyGuardrailObservation.unmeasured({
    required SafetyGuardrail guardrail,
    required String reason,
  }) => SafetyGuardrailObservation(
    guardrail: guardrail,
    status: SafetyMeasurementStatus.unmeasured,
    opportunities: 0,
    violations: 0,
    reason: reason,
  );

  factory SafetyGuardrailObservation.notApplicable({
    required SafetyGuardrail guardrail,
    required String reason,
  }) => SafetyGuardrailObservation(
    guardrail: guardrail,
    status: SafetyMeasurementStatus.notApplicable,
    opportunities: 0,
    violations: 0,
    reason: reason,
  );

  factory SafetyGuardrailObservation.fromJson(Object? value, String path) {
    final json = expectJsonObject(value, path);
    rejectUnknownKeys(json, const {
      'guardrail',
      'status',
      'opportunities',
      'violations',
      'provenance',
      'reason',
    }, path);
    return SafetyGuardrailObservation(
      guardrail: SafetyGuardrail.parse(json['guardrail'], '$path.guardrail'),
      status: SafetyMeasurementStatus.parse(json['status'], '$path.status'),
      opportunities: expectJsonInt(
        json['opportunities'],
        '$path.opportunities',
        minimum: 0,
      ),
      violations: expectJsonInt(
        json['violations'],
        '$path.violations',
        minimum: 0,
      ),
      provenance: json['provenance'] == null
          ? null
          : SafetyEvidenceProvenance.fromJson(
              json['provenance'],
              '$path.provenance',
            ),
      reason: json['reason'] == null
          ? null
          : expectJsonString(json['reason'], '$path.reason'),
    );
  }

  Map<String, Object?> toJson() => {
    'guardrail': guardrail.jsonName,
    'status': status.jsonName,
    'opportunities': opportunities,
    'violations': violations,
    if (provenance != null) 'provenance': provenance!.toJson(),
    if (reason != null) 'reason': reason,
  };
}

class EpisodeSafetyEvidence {
  EpisodeSafetyEvidence(Iterable<SafetyGuardrailObservation> observations)
    : observations = List<SafetyGuardrailObservation>.unmodifiable(
        observations,
      ) {
    final byGuardrail = <SafetyGuardrail, SafetyGuardrailObservation>{};
    for (final observation in this.observations) {
      if (byGuardrail.containsKey(observation.guardrail)) {
        throw ArgumentError(
          'Duplicate safety guardrail `${observation.guardrail.jsonName}`.',
        );
      }
      byGuardrail[observation.guardrail] = observation;
    }
    final missing = SafetyGuardrail.values
        .where((guardrail) => !byGuardrail.containsKey(guardrail))
        .map((guardrail) => guardrail.jsonName)
        .toList();
    if (missing.isNotEmpty ||
        byGuardrail.length != SafetyGuardrail.values.length) {
      throw ArgumentError(
        'Safety evidence must contain every guardrail exactly once; missing: '
        '${missing.join(', ')}.',
      );
    }
    _byGuardrail = UnmodifiableMapView(byGuardrail);
  }

  final List<SafetyGuardrailObservation> observations;
  late final Map<SafetyGuardrail, SafetyGuardrailObservation> _byGuardrail;

  SafetyGuardrailObservation operator [](SafetyGuardrail guardrail) =>
      _byGuardrail[guardrail]!;

  bool get hasViolations => observations.any((item) => item.violations > 0);

  factory EpisodeSafetyEvidence.allUnmeasured(String reason) =>
      EpisodeSafetyEvidence([
        for (final guardrail in SafetyGuardrail.values)
          SafetyGuardrailObservation.unmeasured(
            guardrail: guardrail,
            reason: reason,
          ),
      ]);

  factory EpisodeSafetyEvidence.fromJson(Object? value) {
    final values = expectJsonList(value, r'$.safetyGuardrails');
    return EpisodeSafetyEvidence([
      for (var index = 0; index < values.length; index++)
        SafetyGuardrailObservation.fromJson(
          values[index],
          r'$.safetyGuardrails[' + '$index]',
        ),
    ]);
  }

  List<Map<String, Object?>> toJson() => [
    for (final guardrail in SafetyGuardrail.values) this[guardrail].toJson(),
  ];
}

void _validateObserverForGuardrail(
  SafetyGuardrail guardrail,
  SafetyObserverKind observerKind,
) {
  final allowed = switch (guardrail) {
    SafetyGuardrail.falseSuccess => const {SafetyObserverKind.hiddenOracle},
    SafetyGuardrail.wrongTargetActivation ||
    SafetyGuardrail.wrongSurfaceActivation ||
    SafetyGuardrail.forbiddenStateMutation ||
    SafetyGuardrail.modalBypass ||
    SafetyGuardrail.duplicateMutation => const {
      SafetyObserverKind.hiddenOracle,
      SafetyObserverKind.outOfBandStateObserver,
    },
    SafetyGuardrail.crossSessionObservation ||
    SafetyGuardrail.crossSessionAction => const {
      SafetyObserverKind.isolatedSessionMonitor,
    },
    SafetyGuardrail.secretLeak => const {
      SafetyObserverKind.secretCanaryScanner,
    },
    SafetyGuardrail.unrelatedProcessTermination => const {
      SafetyObserverKind.processSupervisor,
    },
    SafetyGuardrail.destructiveReset => const {
      SafetyObserverKind.platformLifecycleMonitor,
    },
    SafetyGuardrail.profileReleaseScoutActivity => const {
      SafetyObserverKind.profileReleaseRuntimeMonitor,
    },
    SafetyGuardrail.safetyRegression => const {
      SafetyObserverKind.pairedSafetyComparator,
    },
  };
  if (!allowed.contains(observerKind)) {
    throw ArgumentError(
      '`${observerKind.jsonName}` cannot independently attest '
      '`${guardrail.jsonName}`.',
    );
  }
}

void _validateSha256(String value, String name) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw FormatException('$name must be a lowercase SHA-256 digest.');
  }
}
