# Flutter Scout evaluation and paired-report foundation

This pure-Dart package supplies the measurement contracts required before
Flutter Scout can make benchmark or release claims. It is a harness foundation,
not a benchmark result, and it publishes no scores.

The strict performance and observation non-interference contract is documented
separately in [`PERFORMANCE.md`](PERFORMANCE.md). Its typed config, immutable raw
samples, schemas, and reporter cover §11/§13.6 evidence without treating the
checked-in deterministic fixtures as measurements.

The long-running resource harness is documented in
[`ENDURANCE.md`](ENDURANCE.md). It executes a deterministic, bounded action
plan against a fresh independently observed fixture and writes a create-only,
hash-chained exact-byte archive. Its short fake tests can never claim empirical
endurance conformance.

The four-role agent evaluation contract is documented in
[`CONTROLLED_COMPARISONS.md`](CONTROLLED_COMPARISONS.md). It additively
preregisters screenshot/coordinate-only, current Scout, candidate Scout, and an
optional genuine perfect-handle ceiling without treating schema or fake-test
coverage as empirical attainment.

The independently provenanced safety-opportunity and repetition contract is in
[`SAFETY_METRICS.md`](SAFETY_METRICS.md). Missing monitors stay explicitly
unmeasured, every observed zero-tolerance violation blocks, and readiness floors
are reported without turning deterministic fixtures into release evidence.

The exhaustive proof ledger is available in human-readable
[`CONFORMANCE_MATRIX.md`](CONFORMANCE_MATRIX.md) and machine-readable
[`conformance_matrix.v1.json`](conformance_matrix.v1.json) forms. Missing proof
is explicitly release-blocking where the Quality Standard requires it.

## Guarantees in this foundation

- Versioned JSON Schemas for task manifests, agent-visible tasks, episode
  results, benchmark config, randomized schedule, scheduled raw episodes, and
  reports live in `schemas/v1/`.
- Templates are assigned to exactly one of `public`, `private`, or `frozen`.
  Validation is by `templateId`, so moving only seeds or variants cannot leak a
  template across splits.
- The versioned gold corpus policy makes breadth auditable instead of
  aspirational: at least 60 templates, five distinct variants per template,
  all 12 required task families, all 13 perturbation dimensions per template,
  every split populated, and at least two explicit real-application identities
  beyond Stress Lab. A catalog that misses any item is never release eligible.
- A corpus descriptor joins every task and variant to an explicit app identity,
  family, semantics-preserving declaration, and perturbation dimensions. The
  validator cross-checks all joins, distinct variant ids/seeds, app-identity
  consistency, and the existing split-disjointness rules.
- `TaskManifest.toAgentView()` is the only task projection intended for the
  agent. It excludes split, template, variant, setup, teardown, oracle, success,
  and forbidden-predicate data.
- `HiddenOracle` receives only out-of-band application state. It has no Scout
  claim, inspect, delta, or screenshot input. `EpisodeEvaluator` compares the
  independent verdict with the separately supplied claim.
- Every failed episode has one first-causal category and severity. A success
  claim contradicted by the oracle becomes release-blocking
  `SAFETY_FALSE_SUCCESS`; oracle/setup failures become invalid
  `HARNESS_INVALID` episodes rather than product failures.
- `RawEpisodeArchive` requires an owner-only directory, creates one owner-only
  bounded immutable JSON file per episode, refuses symlink/non-regular paths
  and overwrites, and performs stable bounded reads. Raw agent, tool, claim,
  harness, and private-oracle events are preserved for later audit.
- Wilson 95% intervals and paired McNemar summaries operate on raw counts.
  Success and per-success costs also receive deterministic task-template-
  clustered bootstrap intervals, while preregistered family comparisons use
  Holm-Bonferroni correction. None of these turn an interval or p-value into an
  improvement claim.
- A strict benchmark config pins both Scout commits, model/provider/snapshot,
  reasoning, prompt and tool-schema SHA-256 digests, app commit, complete host
  and simulator environment, Flutter/Dart/platform toolchains, all budgets,
  task regime, selected splits, repetition count, randomization seed, and
  template-family membership. Unknown fields are rejected.
- An optional controlled-comparison block pins exact tool-schema and
  implementation digests for screenshot/coordinate-only, current Scout,
  candidate Scout, and an optional perfect-handle ceiling, plus the exact reset
  protocol. It cannot disable equal task seeds or per-episode fresh resets.
- A stable, SDK-independent randomizer preserves the legacy balanced pair
  schedule and uses position-balanced role rotations for controlled schedules.
  Every comparison block has identical task/variant/repetition seeds across
  roles, and every scheduled episode requires a fresh reset.
- A scheduled episode binds its full result to the config and schedule hashes.
  Catalog, episode, and performance loaders bound traversal count, file size,
  and aggregate bytes; accept only stable regular JSON files with strict UTF-8;
  retain exact bytes; and reject symlinks, clutter, duplicate ids, or invalid
  envelopes.
- Reporting fails on missing, extra, duplicate, or mismatched episodes. There
  is deliberately no exclusion flag. Invalid harness episodes remain in the
  archive and are reported separately from product success and McNemar pairs.
- Reports include raw counts, Wilson intervals, the complete failure taxonomy,
  cost per successful task, paired McNemar results, clustered bootstrap
  intervals, multiplicity-corrected family comparisons, and candidate
  worst-case template-family performance.
- Every episode carries a complete, typed safety-guardrail inventory. Measured
  opportunity/violation counts require guardrail-appropriate independent
  observer and artifact digests; absent instrumentation is explicit. Reports
  aggregate counts and Wilson intervals globally and per condition, and any
  observed zero-tolerance violation blocks.
- Repetition readiness separately reports the 100-per-primitive-variant,
  3,000 combined wrong-target/false-success opportunity, 10 agent repetition,
  and preregistered 20-repetition borderline floors. Primitive readiness stays
  unmeasured because agent episode archives cannot prove primitive samples.
- The performance reporter requires all eight timing phases, exact-byte sample
  hashes, complete CPU/RSS/frame/endurance provenance, and explicit observation
  effects. It compares p50/p95/p99 baseline and candidate distributions, while
  provisional thresholds remain `unmeasured` and full release eligibility is
  always unclaimable.
- The endurance runner pins the condition/environment/controller/collectors,
  anchors exact session/run/runtime/process identity, probes CPU/RSS/frame and
  out-of-band progress after every successful step, detects crossover/crash/
  deadlock/no-progress/resource growth, always attempts teardown, and verifies
  a create-only exact-byte archive before returning a component result.

The out-of-band controller implementing an oracle must not call Flutter Scout
for ground truth. Use an integration-test driver, app-owned test endpoint,
database assertion, or another channel that the evaluated agent cannot query.

Raw episodes can contain private app data. The archive enforces owner-only
filesystem permissions on supported POSIX hosts; callers must still choose an
access-controlled location and apply an explicit retention policy in the
eventual benchmark runner.

## Catalog layout and validation

Place full v1 task manifests under split directories:

```text
catalog/
  corpus_descriptor.v1.json
  public/
  private/
  frozen/
```

`corpus_descriptor.v1.json` is evaluator-only metadata conforming to
`schemas/v1/corpus_descriptor.schema.json`. It must describe every catalog task
exactly once. Each template declares:

- an app id, display name, `stress_lab` or `real_application` kind, source, and
  exact revision;
- one or more required task families;
- every variant's task id, variant id, semantics-preserving status, and covered
  perturbation dimensions.

The checked-in `policies/gold_conformance.v1.json` conforms to
`schemas/v1/corpus_policy.schema.json`. Validate parsing, joins, declared
buckets, unique task IDs, disjoint templates, and corpus readiness with:

```bash
cd evaluation
dart pub get
dart run bin/validate_catalog.dart /absolute/path/to/catalog
dart run bin/validate_catalog.dart \
  --catalog /absolute/path/to/catalog \
  --require-release-eligible
```

The validator prints deterministic JSON plus canonical SHA-256 pins for the
catalog, descriptor, and policy. Structural invalidity exits `1`. With
`--require-release-eligible`, any missing threshold, required split, family,
dimension, semantics-preserving declaration, or real-app identity exits `2`.
Without that flag, a structurally valid public authoring catalog may validate
while still reporting `releaseEligible: false`.

`--policy` may point to a stricter organization policy, but code-level gold
floors cannot be weakened: fewer than 60 templates, fewer than five variants,
omitting any standard family/dimension/split, reclassifying the official Stress
Lab identity, or requiring fewer than two real apps makes the policy itself
invalid and can never yield `releaseEligible: true`.

Only the result of `manifest.toAgentView().toJson()` may be passed to an agent.
Never send a full manifest or the corpus descriptor: both contain evaluator
metadata, and the full manifest also contains hidden harness definitions.

## Deterministic runnable public corpus

Corpus authors can generate a deterministic 60-template × five-variant public
Stress Lab corpus spanning forms, lists, grids, nested scrolling, tabs,
dialogs/sheets/menus, pickers, custom painting, gestures,
lifecycle/reconnect, simulated fault recovery, and security/privacy:

```bash
cd evaluation
dart run bin/generate_public_catalog.dart /new/empty/catalog
dart run bin/validate_catalog.dart /new/empty/catalog
```

The generator refuses to overwrite a non-empty directory. Every manifest maps
to a strict `public-fixture-v1` configuration rendered by the verification
app. An authenticated evaluator reset selects that exact task and variant; the
app-owned oracle records completion and forbidden actions from domain callbacks
and never consumes Scout output. The opaque completion value and predicate
identifiers remain in evaluator-only variant metadata and are absent from
`toAgentView()`.

This is runnable public fixture infrastructure, not scored benchmark evidence.
No execution episode is manufactured by generation, fault fixtures are plainly
labelled simulations, and private/frozen catalogs plus real-app integrations
remain absent. The command and validator therefore both report
`releaseEligible: false`; `--require-release-eligible` fails as intended.

## Reproducible paired benchmark flow

1. Validate the catalog and obtain the canonical digest:

   ```bash
   cd evaluation
   dart run bin/validate_catalog.dart /absolute/path/to/catalog
   dart run bin/benchmark.dart catalog-digest \
     --catalog /absolute/path/to/catalog
   ```

2. Create a config conforming to
   `schemas/v1/benchmark_config.schema.json`. Put the printed digest in
   `catalogSha256`; use full Git commit digests and SHA-256 prompt/tool pins.
   Every selected task's action, wall-time, and token budgets must exactly
   match the pinned benchmark budgets. Every selected template must belong to
   exactly one configured family.
   To run the §13.4 design, add the strict `controlledComparison` block
   described in `CONTROLLED_COMPARISONS.md`; omitting it keeps the legacy paired
   schedule unchanged.

3. Generate and freeze the execution schedule:

   ```bash
   dart run bin/benchmark.dart schedule \
     --config /absolute/path/to/config.json \
     --catalog /absolute/path/to/catalog \
     --output /absolute/path/to/schedule.json
   ```

4. Execute entries in schedule order. Start each condition from the requested
   deterministic reset and archive one
   `schemas/v1/benchmark_episode.schema.json` envelope per entry. The envelope
   must carry the schedule/config hashes and exact pair metadata. Preserve this
   directory as append-only, access-controlled raw evidence.

5. Build the report from the complete directory:

   ```bash
   dart run bin/benchmark.dart report \
     --config /absolute/path/to/config.json \
     --catalog /absolute/path/to/catalog \
     --episodes /absolute/path/to/raw-episodes \
     --output /absolute/path/to/report.json
   ```

   The command exits `64` for malformed/incomplete/mismatched inputs and `2`
   when a safety blocker or invalid harness episode is present. A normal exit
   means the report was constructed; it does not mean every release gate passed.

## Verify this package

```bash
cd evaluation
dart format --output=none --set-exit-if-changed .
dart analyze
dart test
```

The deterministic tests include a deliberately false Scout `ok: true` claim
while out-of-band state says the save did not occur. The hidden oracle must—and
does—classify that episode as release-blocking `SAFETY_FALSE_SUCCESS`.

## Honest limits before benchmark scores

This package is a deterministic scheduler, archive validator, corpus-policy
validator, public authoring-scaffold generator, statistical reporter, and
endurance-runner foundation. It does not provide runnable task-specific
fixtures/oracles, populated private or frozen held-out catalogs,
simulator/model controllers, two real-app suites, platform-specific
resource-profiling controllers, real resource measurements, or a
preregistered non-inferiority confidence interval. Its checked-in performance
files and short endurance runs are parser/runner tests only.
Those external corpus assets remain explicit release blockers. The report
therefore keeps the corresponding Quality Standard gates `unmeasured` and
always sets `claimable: false` for a full release decision. No benchmark score
is included in this repository.
