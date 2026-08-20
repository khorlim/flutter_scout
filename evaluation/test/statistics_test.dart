import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

void main() {
  group('Wilson 95% interval', () {
    test('matches the known 5 of 10 interval', () {
      final interval = WilsonInterval.confidence95(successes: 5, trials: 10);

      expect(interval.estimate, 0.5);
      expect(interval.lower, closeTo(0.236593, 0.000001));
      expect(interval.upper, closeTo(0.763407, 0.000001));
    });

    test('zero observations disclose total uncertainty', () {
      final interval = WilsonInterval.confidence95(successes: 0, trials: 0);

      expect(interval.estimate, isNull);
      expect(interval.lower, 0);
      expect(interval.upper, 1);
    });

    test('invalid counts fail', () {
      expect(
        () => WilsonInterval.confidence95(successes: 11, trials: 10),
        throwsArgumentError,
      );
    });
  });

  group('paired McNemar summary', () {
    test('reports paired cells, direction, exact p, and both intervals', () {
      final summary = McNemarSummary.fromPairs([
        const PairedOutcome(currentPassed: true, candidatePassed: true),
        const PairedOutcome(currentPassed: false, candidatePassed: false),
        for (var index = 0; index < 5; index++)
          const PairedOutcome(currentPassed: false, candidatePassed: true),
      ]);

      expect(summary.pairs, 7);
      expect(summary.bothPassed, 1);
      expect(summary.bothFailed, 1);
      expect(summary.currentOnlyPassed, 0);
      expect(summary.candidateOnlyPassed, 5);
      expect(summary.direction, 'candidate_better');
      expect(summary.continuityCorrectedChiSquare, closeTo(3.2, 1e-12));
      expect(summary.exactTwoSidedP, closeTo(0.0625, 1e-12));
      expect(summary.currentSuccess.trials, 7);
      expect(summary.candidateSuccess.trials, 7);
    });

    test('no discordant pairs is a factual tie with p equal to one', () {
      final summary = McNemarSummary.fromPairs([
        const PairedOutcome(currentPassed: true, candidatePassed: true),
        const PairedOutcome(currentPassed: false, candidatePassed: false),
      ]);

      expect(summary.discordantPairs, 0);
      expect(summary.direction, 'tied');
      expect(summary.continuityCorrectedChiSquare, 0);
      expect(summary.exactTwoSidedP, 1);
    });
  });

  test(
    'Holm correction is deterministic, monotonic, and multiplicity-safe',
    () {
      final adjusted = holmBonferroni({
        'third': 0.04,
        'first': 0.01,
        'second': 0.03,
      });

      expect(adjusted['first'], closeTo(0.03, 1e-12));
      expect(adjusted['second'], closeTo(0.06, 1e-12));
      expect(adjusted['third'], closeTo(0.06, 1e-12));
      expect(() => holmBonferroni({'invalid': 1.1}), throwsArgumentError);
    },
  );
}
