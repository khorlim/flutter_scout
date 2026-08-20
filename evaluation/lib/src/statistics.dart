import 'dart:math' as math;

class WilsonInterval {
  const WilsonInterval({
    required this.successes,
    required this.trials,
    required this.estimate,
    required this.lower,
    required this.upper,
    required this.confidenceLevel,
  });

  final int successes;
  final int trials;
  final double? estimate;
  final double lower;
  final double upper;
  final double confidenceLevel;

  factory WilsonInterval.confidence95({
    required int successes,
    required int trials,
  }) {
    if (trials < 0 || successes < 0 || successes > trials) {
      throw ArgumentError(
        'Expected 0 <= successes <= trials; got $successes/$trials.',
      );
    }
    if (trials == 0) {
      return const WilsonInterval(
        successes: 0,
        trials: 0,
        estimate: null,
        lower: 0,
        upper: 1,
        confidenceLevel: 0.95,
      );
    }

    const z = 1.959963984540054;
    final n = trials.toDouble();
    final proportion = successes / n;
    final zSquared = z * z;
    final denominator = 1 + zSquared / n;
    final center = (proportion + zSquared / (2 * n)) / denominator;
    final margin =
        z *
        math.sqrt(
          (proportion * (1 - proportion) / n) + (zSquared / (4 * n * n)),
        ) /
        denominator;
    return WilsonInterval(
      successes: successes,
      trials: trials,
      estimate: proportion,
      lower: math.max(0, center - margin),
      upper: math.min(1, center + margin),
      confidenceLevel: 0.95,
    );
  }

  Map<String, Object?> toJson() => {
    'successes': successes,
    'trials': trials,
    'estimate': estimate,
    'lower': lower,
    'upper': upper,
    'confidenceLevel': confidenceLevel,
  };
}

class PairedOutcome {
  const PairedOutcome({
    required this.currentPassed,
    required this.candidatePassed,
  });

  final bool currentPassed;
  final bool candidatePassed;
}

class McNemarSummary {
  const McNemarSummary({
    required this.pairs,
    required this.bothPassed,
    required this.bothFailed,
    required this.currentOnlyPassed,
    required this.candidateOnlyPassed,
    required this.currentSuccess,
    required this.candidateSuccess,
    required this.candidateMinusCurrent,
    required this.continuityCorrectedChiSquare,
    required this.exactTwoSidedP,
  });

  final int pairs;
  final int bothPassed;
  final int bothFailed;
  final int currentOnlyPassed;
  final int candidateOnlyPassed;
  final WilsonInterval currentSuccess;
  final WilsonInterval candidateSuccess;
  final double? candidateMinusCurrent;
  final double continuityCorrectedChiSquare;
  final double exactTwoSidedP;

  int get discordantPairs => currentOnlyPassed + candidateOnlyPassed;

  String get direction {
    if (candidateOnlyPassed > currentOnlyPassed) return 'candidate_better';
    if (candidateOnlyPassed < currentOnlyPassed) return 'current_better';
    return 'tied';
  }

  factory McNemarSummary.fromPairs(Iterable<PairedOutcome> outcomes) {
    var bothPassed = 0;
    var bothFailed = 0;
    var currentOnly = 0;
    var candidateOnly = 0;
    for (final outcome in outcomes) {
      if (outcome.currentPassed && outcome.candidatePassed) {
        bothPassed++;
      } else if (!outcome.currentPassed && !outcome.candidatePassed) {
        bothFailed++;
      } else if (outcome.currentPassed) {
        currentOnly++;
      } else {
        candidateOnly++;
      }
    }

    final pairs = bothPassed + bothFailed + currentOnly + candidateOnly;
    final discordant = currentOnly + candidateOnly;
    final correctedDifference = math.max(
      0,
      (currentOnly - candidateOnly).abs() - 1,
    );
    final chiSquare = discordant == 0
        ? 0.0
        : correctedDifference * correctedDifference / discordant;
    final currentPasses = bothPassed + currentOnly;
    final candidatePasses = bothPassed + candidateOnly;
    return McNemarSummary(
      pairs: pairs,
      bothPassed: bothPassed,
      bothFailed: bothFailed,
      currentOnlyPassed: currentOnly,
      candidateOnlyPassed: candidateOnly,
      currentSuccess: WilsonInterval.confidence95(
        successes: currentPasses,
        trials: pairs,
      ),
      candidateSuccess: WilsonInterval.confidence95(
        successes: candidatePasses,
        trials: pairs,
      ),
      candidateMinusCurrent: pairs == 0
          ? null
          : (candidatePasses - currentPasses) / pairs,
      continuityCorrectedChiSquare: chiSquare,
      exactTwoSidedP: _exactTwoSidedBinomial(currentOnly, candidateOnly),
    );
  }

  Map<String, Object?> toJson() => {
    'pairs': pairs,
    'bothPassed': bothPassed,
    'bothFailed': bothFailed,
    'currentOnlyPassed': currentOnlyPassed,
    'candidateOnlyPassed': candidateOnlyPassed,
    'discordantPairs': discordantPairs,
    'direction': direction,
    'candidateMinusCurrent': candidateMinusCurrent,
    'continuityCorrectedChiSquare': continuityCorrectedChiSquare,
    'exactTwoSidedP': exactTwoSidedP,
    'currentSuccess': currentSuccess.toJson(),
    'candidateSuccess': candidateSuccess.toJson(),
  };
}

double _exactTwoSidedBinomial(int firstDiscordant, int secondDiscordant) {
  final total = firstDiscordant + secondDiscordant;
  if (total == 0) return 1;
  final tailEnd = math.min(firstDiscordant, secondDiscordant);
  var tail = 0.0;
  for (var successes = 0; successes <= tailEnd; successes++) {
    tail += math.exp(_logCombination(total, successes) - total * math.ln2);
  }
  return math.min(1, 2 * tail);
}

double _logCombination(int n, int k) {
  final smaller = math.min(k, n - k);
  var value = 0.0;
  for (var index = 1; index <= smaller; index++) {
    value += math.log(n - smaller + index) - math.log(index);
  }
  return value;
}

/// Holm-Bonferroni adjusted p-values for a preregistered family of secondary
/// hypotheses. The step-down monotonic maximum prevents a later, larger raw
/// p-value from receiving a smaller adjusted value.
Map<String, double> holmBonferroni(Map<String, double> rawPValues) {
  for (final entry in rawPValues.entries) {
    if (!entry.value.isFinite || entry.value < 0 || entry.value > 1) {
      throw ArgumentError.value(
        entry.value,
        entry.key,
        'p-value must be finite and between zero and one',
      );
    }
  }
  final ordered = rawPValues.entries.toList()
    ..sort((first, second) {
      final byValue = first.value.compareTo(second.value);
      return byValue != 0 ? byValue : first.key.compareTo(second.key);
    });
  final adjusted = <String, double>{};
  var monotonicFloor = 0.0;
  for (var index = 0; index < ordered.length; index++) {
    final entry = ordered[index];
    final candidate = math.min(1.0, entry.value * (ordered.length - index));
    monotonicFloor = math.max(monotonicFloor, candidate);
    adjusted[entry.key] = monotonicFloor;
  }
  return adjusted;
}
