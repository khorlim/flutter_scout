import 'dart:io';
import 'dart:math';

const String scoutFuzzSeedEnvironment = 'SCOUT_FUZZ_SEED';
const String scoutFuzzCaseEnvironment = 'SCOUT_FUZZ_CASE';

int fuzzSeed(int fallback) {
  final configured = Platform.environment[scoutFuzzSeedEnvironment];
  if (configured == null || configured.isEmpty) return fallback;
  return int.parse(configured);
}

Iterable<int> fuzzCases(int count) sync* {
  final configured = Platform.environment[scoutFuzzCaseEnvironment];
  if (configured != null && configured.isNotEmpty) {
    final selected = int.parse(configured);
    if (selected < 0 || selected >= count) {
      throw RangeError.range(selected, 0, count - 1, scoutFuzzCaseEnvironment);
    }
    yield selected;
    return;
  }
  for (var index = 0; index < count; index += 1) {
    yield index;
  }
}

Random fuzzRandom(int seed, int caseIndex) {
  // Each case owns an independent stream, so SCOUT_FUZZ_CASE can replay it
  // without first consuming every earlier case.
  var mixed = (seed ^ (caseIndex * 0x45d9f3b)) & 0x7fffffff;
  mixed = ((mixed ^ (mixed >> 16)) * 0x45d9f3b) & 0x7fffffff;
  mixed ^= mixed >> 16;
  return Random(mixed & 0x7fffffff);
}

String fuzzReplay({
  required String file,
  required int seed,
  required int caseIndex,
  required String testName,
}) =>
    'seed=$seed case=$caseIndex; replay: '
    '$scoutFuzzSeedEnvironment=$seed '
    '$scoutFuzzCaseEnvironment=$caseIndex '
    "flutter test test/$file --plain-name '${testName.replaceAll("'", "'\\''")}'";
