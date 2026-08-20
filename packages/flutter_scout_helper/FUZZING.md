# Deterministic helper fuzzing

The helper's CI-safe property campaigns are ordinary seeded widget tests:

```bash
flutter test test/resolution_property_fuzz_test.dart
flutter test test/snapshot_state_property_fuzz_test.dart
flutter test test/protocol_property_fuzz_test.dart
```

Each assertion reports its seed and case index. Replay that exact generated
case with the command printed in the failure, for example:

```bash
SCOUT_FUZZ_SEED=6029694 SCOUT_FUZZ_CASE=7 \
  flutter test test/resolution_property_fuzz_test.dart \
  --plain-name 'seeded Unicode selectors remain exact and normalization collisions abstain'
```

`SCOUT_FUZZ_SEED` replaces a campaign's checked-in seed. `SCOUT_FUZZ_CASE`
selects one independently generated case and is optional. Keep default case
counts bounded for CI; investigate and preserve any failing seed before adding
it to the fixed regression corpus. These campaigns establish deterministic
contract examples, not cryptographic collision resistance or simulator/device
coverage.
