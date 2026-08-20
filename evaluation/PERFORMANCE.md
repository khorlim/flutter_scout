# Performance and observation non-interference evidence

This harness implements the evidence contract for `QUALITY_STANDARD.md` §11,
the performance KPIs in §13.6, and the provisional gates in §14.2. It does not
contain measured product results. Checked-in fixtures are deterministic parser
and reporter tests, not device evidence.

## What is pinned

`schemas/v1/performance_config.schema.json` requires one immutable comparison
configuration to pin:

- hardware model, CPU, and RAM;
- host OS name, version, and architecture;
- Flutter, Dart, and platform SDK versions;
- app and Scout commits plus CLI, helper, and protocol versions;
- debug build mode, app fixture, exact tree size, device/platform/image, and one of
  the standard-screen inspect, large-tree inspect, or action-overhead scenarios;
- logical viewport and device pixel ratio;
- clock, collection method, collector/version, and token estimator;
- warmup count, measured repetitions, and comparison tolerance.

The canonical config digest binds every raw sample to all of those facts. A
sample produced under another environment therefore cannot be mixed into a
report by changing only its condition label.

These are active Scout scenarios and therefore require a debug app. The parser
rejects profile/release configs rather than implying that Scout may operate in a
normal production build; disabled-build verification remains a separate safety
suite.

## Required raw evidence

Each condition has exactly `repetitions` expected sample IDs:

```text
<condition-id>-r000001
<condition-id>-r000002
...
```

Every file must use that ID as its filename and conform to
`schemas/v1/performance_sample.schema.json`. A sample records the eight phases
independently in microseconds:

```text
connect -> snapshot -> match -> dispatch -> settle -> delta -> logs -> serialize
```

Action overhead is computed as every phase except `settle`; application settling
is never hidden inside the Scout overhead metric. Response tokens are an estimate
computed from exact response byte counts using the estimator pinned in the
config.

This package validates and reports those measurements; it does not instrument
the production CLI/helper or infer a missing phase from an aggregate duration.
Production code must expose or collect all eight phase timings independently
before real samples can satisfy this contract.

CPU, resident memory, frame-time, and endurance observations are mandatory. Each
resource measurement carries its own source, method, collector version, target,
and UTC timestamp. Missing resource facts, missing phases, negative/non-finite
values, or internally inconsistent values fail parsing.

The observation-effects record is also mandatory. It captures before/after
identity and mutation counts for focus, route, semantics, and business state;
pointer and gesture dispatch; overlay interception; and synthetic frames. Any
effect blocks the non-interference result even if every latency is fast.

## Exact-byte and selection integrity

The loader reads every regular `.json` file once, verifies it did not change
during the read, retains its exact bytes, and reports its SHA-256 and byte length.
Symlinks, non-JSON entries, filename/ID mismatches, duplicate IDs, missing
repetitions, extra repetitions, config mismatches, and warmup mismatches fail the
report. There is deliberately no exclusion option, so an observed slow or failed
sample cannot be removed after results are known.

Run the reporter with:

```bash
cd evaluation
dart run bin/performance.dart report \
  --config /absolute/path/performance-config.json \
  --samples /absolute/path/immutable-samples \
  --output /new/path/performance-report.json
```

The output path is create-only and is never overwritten. Exit `64` means input
or archive integrity failed. Exit `2` means a non-interference violation or a
failed ratified component gate. Exit `0` only means the report was constructed;
inspect its typed statuses.

The report provides empirical nearest-rank p50/p95/p99 distributions for every
phase, action overhead, total time, bytes, estimated tokens, and resource facts.
It compares baseline and candidate and flags metrics whose relative increase
exceeds the preregistered tolerance.

## Ratification and claim limits

The Quality Standard's numerical targets remain provisional until a reference
environment and baseline are explicitly frozen. A provisional config must use
`null` ratification fields. Its quantitative gates are always `unmeasured`, even
when fixture values are below every target.

A ratified config must name the ratification and pin the exact canonical
environment digest. It must also preserve at least 100 measured repetitions per
condition, matching the Standard's important tool-primitive floor. The parser
rejects a digest mismatch or an undersized ratified run. Numeric thresholds may
be stricter than §14.2 but cannot weaken its 300 ms standard inspect, 750 ms
large-tree inspect, 250 ms action overhead, 1,500-token payload, 1% idle CPU,
20 MB RSS, 5% frame-time, or endurance targets. Each inspect/action latency gate
is evaluated only by a config that pins its matching scenario. Ratification allows
this component report to say whether its performance gates pass or fail; it does
not make Flutter Scout release-eligible. `releaseAssessment.claimable` is always
`false`, because real device runs, safety and correctness suites, held-out agent
benchmarks, platform parity, and the other release requirements are separate
evidence.

Before using this for a release decision, collect fresh raw measurements on the
frozen iOS and Android reference devices (and every declared Tier-1 platform),
run sufficient repetitions after warmup, use the independently probed runner in
[`ENDURANCE.md`](ENDURANCE.md) for real 60-minute or 1,000-action sessions,
ratify the environment and baseline through the project release process, and
preserve the raw archive under an access-control and retention policy.
