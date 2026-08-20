# Releasing Flutter Scout

This is a fail-closed release checklist derived from
[QUALITY_STANDARD.md](QUALITY_STANDARD.md). It describes what must be true; it
does not certify the current repository. Any item marked **BLOCKER** prevents a
release candidate from being promoted.

The current source contract is response schema 1 and helper protocol 15. That
identity does not make it releasable: the cross-version matrix, simulator
evidence, benchmarks, and other blockers below still apply. See
[COMPATIBILITY.md](COMPATIBILITY.md) for the exact implemented and unratified
pairings.

## Release ownership and evidence

One release owner must record:

- candidate commit and clean worktree status;
- current-release comparison commit or signed tag;
- manual verification run URLs and all retained failing seeds;
- host hardware, OS, simulator/emulator image, device, viewport, locale, and
  build mode;
- exact Flutter and Dart output;
- package, schema, protocol, and negotiated capability versions;
- raw test, security, benchmark, performance, and endurance artifacts;
- every waiver decision. Safety, privacy, truthfulness, and zero-tolerance gates
  cannot be waived.

Do not discard failed runs after seeing the outcome. Harness-invalid episodes
must be reported separately and may be rerun only under a predeclared rule.

## Pinned toolchain

The manual verification workflow pins Flutter `3.44.2`; its bundled Dart SDK is
the pinned Dart toolchain. A release operator must use the same toolchain
locally or run the manual workflow and record:

```bash
flutter --version
dart --version
git rev-parse HEAD
git status --short
```

Stable and beta run only as compatibility canaries in the manual workflow. A
canary failure is not silently ignored: classify it, open follow-up work, and
record whether it changes the published support matrix.

Every third-party action in the workflow is pinned to a full immutable commit
SHA; the trailing major-version comment is descriptive only. Updating an action
pin requires reviewing its upstream diff and rerunning all release gates.

Changing the pinned toolchain requires a normal reviewed change with all gates
rerun. Do not weaken or float the pin during release preparation.

## Commands currently available

These commands exercise checks that exist today. Passing them is necessary but
does not satisfy the unimplemented gates below.

Repository formatting:

```bash
dart format --output=none --set-exit-if-changed \
  packages/flutter_scout/lib \
  packages/flutter_scout/test \
  packages/flutter_scout_helper/lib \
  packages/flutter_scout_helper/test \
  evaluation/lib \
  evaluation/bin \
  evaluation/test \
  tool/release \
  tool/verify_debug_only_build.dart
```

CLI package:

```bash
cd packages/flutter_scout
dart pub get
dart analyze --fatal-infos
dart test
```

Helper package:

```bash
cd packages/flutter_scout_helper
flutter pub get
flutter analyze
flutter test
```

Verification app:

```bash
cd apps/scout_test_app
flutter pub get
flutter analyze
flutter test
```

Debug-only compiled boundary (the debug artifact is the positive control):

```bash
cd apps/scout_test_app
flutter build apk --debug --target-platform android-arm64 --no-pub
flutter build apk --profile --target-platform android-arm64 --no-pub
flutter build apk --release --target-platform android-arm64 --no-pub
cd ../..
dart run tool/verify_debug_only_build.dart \
  --debug apps/scout_test_app/build/app/outputs/flutter-apk/app-debug.apk \
  --profile apps/scout_test_app/build/app/outputs/flutter-apk/app-profile.apk \
  --release apps/scout_test_app/build/app/outputs/flutter-apk/app-release.apk
```

The check must find every install-path sentinel in the debug kernel and none in
either AOT artifact. This is an Android compiled-boundary proof, not a substitute
for profile/release runtime probes on every declared Tier-1 target.

Evaluation contracts:

```bash
cd evaluation
dart pub get
dart analyze --fatal-infos
dart test
dart run bin/validate_catalog.dart /absolute/path/to/catalog
```

The catalog validator is usable, but no release benchmark corpus or score is
claimed merely because its contract tests pass.

Release-evidence tool:

```bash
dart analyze tool/release
dart tool/release/release_evidence_self_check.dart
```

The self-check proves SHA-256 known vectors, byte-for-byte deterministic output,
offline lockfile inventory and incomplete-composition SBOM generation, manifest
verification, cross-document source binding, and both byte-level and semantic
tamper detection. It also proves that generated signing and rollback records
remain explicitly unperformed. It does not prove that a candidate's release
artifacts, signature, provenance trust, or rollback exercise are complete.

## Repeated release-critical test gate

The manually dispatched verification workflow repeats the release-critical CLI,
helper, and verification-app subsets plus the complete evaluation/oracle/report suite three times, in
serial, with preregistered test-order seeds `1729`, `2718`, and `31415`. Each
suite attempt has a 20-minute deadline. A timeout or any non-zero attempt fails
the job even if a later attempt passes; rerunning the workflow must never erase
or reclassify that failure.

The gate writes the exact shell-escaped command and working directory, separate
stdout and stderr logs, seed, attempt number, exit code, and outcome for every
suite, plus the commit, worktree status, CI run identity, and Flutter/Dart
toolchain identity. The workflow uploads the complete owner-only working set with
`if: always()` and a 90-day retention period. The release owner must retain the
artifact URL and digest with the candidate evidence, and must preserve any
longer-lived failing seed or interleaving until the defect is resolved. A green
coverage percentage does not replace this gate.

These repetitions cover deterministic source-level safety, lifecycle,
protocol, privacy, retention, bounded-input, native-contract, resolver,
navigation, non-interference, property/fuzz, stability, recorder, and oracle
tests. They do not constitute Tier-1 simulator repetitions. A release still
requires the separately retained iOS Simulator and Android Emulator behavioral
matrix and any preregistered agent/performance/endurance repetitions.

Manual simulator smoke commands currently available:

```bash
flutter devices

cd packages/flutter_scout
dart run bin/flutter_scout.dart ensure \
  --name release-smoke \
  --device <device-id> \
  --project ../../apps/scout_test_app
dart run bin/flutter_scout.dart --app release-smoke status
dart run bin/flutter_scout.dart --app release-smoke inspect --brief
dart run bin/flutter_scout.dart --app release-smoke tap btn.add_supplier
dart run bin/flutter_scout.dart --app release-smoke wait stable
dart run bin/flutter_scout.dart --app release-smoke evidence \
  --output <private-output-directory>
dart run bin/flutter_scout.dart --app release-smoke stop --clear-session
```

Record the device, starting state, output, and cleanup result. A manual smoke run
does not replace the required automated Tier-1 behavioral suite.

Before signing:

```bash
git diff --check
git status --short
git log -1 --show-signature
```

## Zero-tolerance release gates

Any reproducible instance of the following blocks release, regardless of other
scores:

- false success;
- wrong-target or wrong-surface activation;
- modal bypass;
- duplicate mutation after retry or reconnect;
- forbidden-state mutation;
- cross-session observation or action;
- unrelated process termination;
- destructive simulator or app-data reset without explicit request;
- plaintext secret leakage;
- active Scout behavior in a normal profile or release build;
- unexplained regression in a safety metric.

Every invariant requires a deterministic fixture with 100% correctness. A
performance, payload-size, or agent-success improvement cannot compensate for a
safety, truthfulness, or privacy regression.

## Required release-candidate suites

| Gate | Required evidence | Current readiness |
| --- | --- | --- |
| Formatting and fatal static analysis | All commands above pass on the pinned toolchain. | Available; must pass. |
| Package and test-app tests | CLI, helper, app, and evaluation suites pass without flakes. | Available; must pass. |
| Protocol contract and cross-version compatibility | Immutable request/response schemas, every command/error golden, and CLI/helper current, previous, and next-version compatibility. Incompatibility must fail before mutation. | **BLOCKER:** schema-1/protocol-15 contracts and a deterministic source-fixture `N`/`N-1`/`N+1` matrix exist, but every-command goldens and retained runs using separately built release artifacts are not complete. Source-configured peers are not release-binary interoperability evidence. |
| Lifecycle fault injection | Deterministic interruption of launch, attach, reload, restart, stop, temporary-helper cleanup, metadata writes, daemon supervision, PID reuse, full disk, and permissions failure. | **BLOCKER:** full matrix is not implemented. |
| Tier-1 simulator behavior | The same visibility, occlusion, modal, hit-test, input, scrolling, signal, capture, lifecycle, and cleanup contract on iOS Simulator and Android Emulator; macOS only if declared Tier 1. | **BLOCKER:** no complete automated cross-platform suite. |
| Redaction and local transport security | Generated adversarial secret corpus; zero plaintext leaks across every output/artifact; authenticated-loopback, method, origin, parameter, body, deadline, path, and legacy-mode tests. | The deterministic 132-case source/sink/artifact corpus and focused transport/storage controls are implemented; **BLOCKER:** retained screenshot/OCR and cross-platform process-boundary evidence is incomplete. |
| Debug-only operation | Positive-control debug build plus profile/release compiled and runtime absence on each declared Tier-1 target. | Android debug/profile/release APK sentinel scan is available in the manual verification workflow; **BLOCKER:** retained runtime and iOS/Tier-1 parity evidence is incomplete. |
| Candidate benchmark | Raw paired current/candidate episodes with independent hidden oracles, fixed model/configuration/budgets, and public/private/frozen template separation. | **BLOCKER:** evaluation foundation exists; benchmark sets and scored runs do not. |
| Performance and non-interference | Pinned phase timings, CPU, memory, frame-time, payload/token, observation-interference, and regression comparison. | **BLOCKER:** reference benchmark and baseline are not frozen. |
| Endurance | 60 minutes or 1,000 actions without crash, crossover, deadlock, resource leak, or unbounded growth. | A deterministic correlated runner, independent probes, teardown checks, and tamper-evident archive contract are implemented; **BLOCKER:** no retained eligible 60-minute or 1,000-action run exists. |
| Upgrade, downgrade, and rollback | Current-to-candidate upgrade, candidate-to-current downgrade, incompatible helper behavior, and tested rollback procedure. | **BLOCKER:** no completed release exercise. |

Until every blocker in this table is closed with retained evidence, the
repository may produce development builds but must not claim gold-standard
conformance or publish benchmark-backed improvement claims.

## Provisional quantitative gates

These targets are aspirational until the reference environment and baseline are
frozen. Once ratified, they become blocking and must not be weakened silently.
Rate gates use the lower 95% confidence bound unless otherwise stated.

| Area | Required target after ratification |
| --- | ---: |
| Deterministic primitive reliability | at least 99.9% |
| Visible-control perception precision and recall | at least 99.5% |
| Active-surface correctness in the modal corpus | 100% |
| Stale-handle abstention without dispatch | 100% |
| Critical route, surface, field, and error delta recall | 100% |
| Overall delta precision and recall | at least 99.5% |
| Supported injected-fault recall | 100% |
| Runtime-signal precision | at least 99.5% |
| False-stable rate | below 0.1% |
| Bounded locate/reveal success for reachable unique targets | at least 99% |
| Lifecycle-fault recovery without duplicate mutation | at least 99% |
| Deterministic replay success | at least 99.5% |
| Clean held-out agent task success | at least 95% |
| Perturbed held-out task success | at least 90% |
| Worst task-family success | at least 80% |
| Perturbation drop from clean success | at most 5 percentage points |
| Warm brief inspect, standard reference screen | p95 at most 300 ms |
| Warm brief inspect, large-tree stress fixture | p95 at most 750 ms |
| Scout action overhead excluding app settling | p95 at most 250 ms |
| Typical brief payload | p95 at most 1,500 tokens |
| Idle CPU overhead | below 1% |
| Incremental resident memory | below 20 MB |
| Median frame-time regression | below 5% |
| Endurance | 60 minutes or 1,000 actions without crash, crossover, deadlock, or unbounded growth |

**BLOCKER:** no reference environment and baseline have been ratified, so none of
these targets may currently be reported as passed.

## Candidate promotion rule

Pre-register the comparison, seeds, budgets, invalid-run rule, and
non-inferiority margin before running the candidate. Initially, the lower
confidence bound of the paired candidate-minus-current success difference
should be greater than negative one percentage point.

An improvement claim additionally requires either:

- at least five percentage points higher robust success with an interval that
  excludes zero; or
- at least 20% lower cost per successful task while the success lower bound
  remains within the non-inferiority margin.

Use paired current/candidate episodes and report Wilson intervals and the paired
McNemar summary from the raw data. Also report failures, invalid harness runs,
worst task family, calls, tokens, bytes, screenshots, wall time, and safety
guardrails. Do not infer practical improvement from a p-value alone.

**BLOCKER:** no candidate may be promoted under this rule until the corpus,
current-release baseline, reference environment, and raw paired runs exist.

## Version and compatibility alignment

Before release:

1. Decide whether the CLI, helper, public Dart APIs, schemas, or behavior changed.
2. Apply Semantic Versioning to each affected package.
3. Align the CLI and helper changelogs with the same release intent and date.
4. Document every behavior/schema migration and the safe upgrade/downgrade path.
5. Publish a compatibility table covering CLI, helper, schema,
   protocol, Dart, Flutter, host OS, and target platform.
6. Verify capabilities at runtime; never infer support only from a package
   version.
7. Support the current and previous helper contract during a documented
   migration window, or fail clearly before any action.

Both package changelogs now have an aligned `Unreleased` section, but no
candidate versions or release date have been selected. Applying and reviewing
the correct Semantic Versioning changes remains a **BLOCKER**.

The support matrix must explicitly classify iOS Simulator and Android Emulator,
and may classify macOS desktop only after the same behavioral contract passes.
Windows, Linux, web, physical devices, and any unverified capability remain
experimental. Unsupported operations must return `unsupported_capability`
before mutation and disclose fallback provenance and coordinate semantics.

[COMPATIBILITY.md](COMPATIBILITY.md) records implemented pairings and labels all
unproven targets as experimental. The matrix is not yet release-ratified because
the cross-version and Tier-1 behavioral suites are incomplete. That is a
**BLOCKER**.

## Required release artifacts

Every release must include all of the following:

- immutable typed core protocol schemas;
- aligned CLI/helper/schema/protocol changelogs;
- support and compatibility matrix;
- migration notes for behavioral or schema changes;
- checksums and build provenance tied to the candidate commit and CI run;
- dependency inventory or SPDX/CycloneDX SBOM for every package and released
  artifact;
- signed, immutable version tag;
- documented and rehearsed rollback procedure;
- private locations and retention periods for raw security, benchmark,
  screenshot, and evaluation evidence.

The evaluation schemas do not substitute for core CLI/helper protocol schemas.
`pubspec.lock` and dependency output are inputs to an inventory, not an SBOM by
themselves.

Generate evidence from a clean candidate checkout into a new private directory
outside the repository. Give every released artifact a stable logical filename:

```bash
dart tool/release/generate_release_evidence.dart \
  --output /absolute/private/flutter-scout-release-evidence \
  --artifact flutter_scout-source.tar.gz=/absolute/artifacts/flutter_scout-source.tar.gz \
  --artifact flutter_scout-cli.tar.gz=/absolute/artifacts/flutter_scout-cli.tar.gz
```

The command fails on a dirty worktree by default and never performs package
resolution or network access. Its timestamp is `SOURCE_DATE_EPOCH` when set and
otherwise the candidate commit time, so the same inputs and environment produce
byte-identical output. On macOS and Linux it enforces `0700` on the evidence
directory and `0600` on every evidence file; other hosts record that owner-only
POSIX modes were unavailable and remain unratified. It emits:

- `manifest.json` with checksums of every generated evidence file and
  `manifest.sha256` for independent recording in the signed release record;
- `provenance.json` with commit/tree/worktree, CI, host, package, schema, and
  local Flutter/Dart identities or an explicit collection error;
- `provenance-statement.intoto.json`, an unsigned local in-toto/SLSA-v1-shaped
  statement binding the candidate source set and supplied artifact subjects;
- `source-checksums.sha256` and `artifact-checksums.sha256`;
- `schema-digests.json` with individual and aggregate schema SHA-256 values;
- `release-schema-manifest.json`, which binds every immutable protocol schema
  and typed catalog to the live schema/protocol identity and the versioned
  release-evidence contract catalog;
- `release-alignment.json`, which checks CLI/helper/protocol changelog intent,
  package versions, the compatibility matrix, and upgrade/downgrade notes while
  reporting separately whether release versions and dated headings are final;
- `dependency-inventory.cdx.json`, a CycloneDX-shaped resolved-component
  inventory derived from checked-in lockfiles;
- `dependency-sbom.cdx.json`, a deterministic CycloneDX 1.5 SBOM containing
  source packages, resolved lockfile components, and supplied artifacts, with
  its composition explicitly marked incomplete;
- `artifacts.json` with logical names, sizes, individual digests, and one
  deterministic aggregate digest;
- `signing-verification.json`, an unsigned pre-sign contract listing the exact
  manifest/tag/key/independent-verifier checks still required; and
- `rollback-plan.json`, a machine-readable safe rollback procedure whose
  known-good release and exercise state remain explicitly unverified and
  unexercised.

The SBOM is valid inventory evidence, not a license, vulnerability, or
complete-dependency-graph attestation: pub lockfiles do not retain the complete
edge graph or license findings. Its CycloneDX composition and properties say so
directly. If release policy requires complete graph, license, or vulnerability
findings, add a reviewed offline enrichment step and retain its output as a
separately named, checksummed artifact. Never change `incomplete` to `complete`
without proving those inputs.

Verify in a separate clean checkout, supplying the exact artifacts again:

```bash
dart tool/release/generate_release_evidence.dart \
  --verify /absolute/private/flutter-scout-release-evidence \
  --artifact flutter_scout-source.tar.gz=/absolute/artifacts/flutter_scout-source.tar.gz \
  --artifact flutter_scout-cli.tar.gz=/absolute/artifacts/flutter_scout-cli.tar.gz
```

Verification must return `"ok": true`. Inspect `provenance.json` and reject the
candidate if `cleanWorktree` is false, a required toolchain identity has a
collection error, the CI commit differs, any artifact is absent, or the pinned
toolchain does not match. Verification recalculates source, schema, package,
protocol, compatibility, lockfile, SBOM, artifact, provenance-statement,
signing-template, and rollback-template bindings; merely recomputing
`manifest.sha256` after editing a semantic fact does not make it valid.
`--allow-dirty` is only for diagnostic development bundles and can never make
one release-eligible.

Useful inventory commands currently available are:

```bash
(cd packages/flutter_scout && dart pub deps --json)
(cd packages/flutter_scout_helper && flutter pub deps --json)
(cd apps/scout_test_app && flutter pub deps --json)
(cd evaluation && dart pub deps --json)
```

These are optional diagnostics and may depend on an already-resolved package
configuration. They are not inputs to the offline generator and do not replace
its checked-in-lockfile inventory.

The generator's SHA-256 implementation is covered by published known vectors in
its self-check. A release owner must still review the generator and release
contract digests recorded in provenance and retain the exact
generation/verification commands. The generated in-toto statement is
deliberately `unsigned_local_statement`; it becomes trusted provenance only
through an approved signing and independent-verification process outside this
pre-sign generator.

## Signed tag creation and verification

Sign only after every gate passes and the verified candidate commit equals the
commit in `manifest.json`. Use an annotated tag and an approved signing key:

```bash
git status --short
git show --no-patch --format=fuller <candidate-commit>
git tag -s -m "Flutter Scout <version>" \
  -m "release-manifest-sha256: <sha256>" \
  <version-tag> <candidate-commit>
git verify-tag --raw <version-tag>
git rev-list -n 1 <version-tag>
git cat-file -t <version-tag>
```

The release owner must verify all of the following before pushing the tag:

1. `git status --short` is empty and the resolved tag commit exactly equals the
   manifest candidate commit.
2. `git cat-file -t` reports `tag`, not `commit`; this proves the tag is an
   annotated tag object rather than a lightweight tag.
3. `git verify-tag --raw` succeeds and the displayed signing fingerprint exactly
   matches the independently recorded release-key fingerprint. A good signature
   from an unexpected key is a failure.
4. The annotated message records the verified `manifest.sha256` value, and its
   version, package versions, changelogs, schemas, and compatibility matrix
   identify the same release.
5. A second trusted environment fetches the exact tag object from the intended
   remote, repeats `git verify-tag --raw`, resolves the same commit, and verifies
   the evidence manifest and artifacts.

Record the tag-object ID, resolved commit, signer fingerprint, verification
tool/version, and second-verifier result in private release evidence. Never
force, delete, reuse, or move a published version tag. If signing or independent
verification fails, do not publish artifacts under that version; fix the cause
and create a new candidate/tag name.

There is no approved release key, signed known-good tag, independent-verifier
record, or automated package-publication/provenance pipeline today. Those are
**BLOCKERS** for an external release.

## Upgrade and downgrade exercise

Follow the complete steps in [COMPATIBILITY.md](COMPATIBILITY.md). A release
exercise must retain evidence for both directions:

1. current signed pair to candidate protocol-15 pair, including the expected
   fail-closed mixed-version interval and full helper relaunch;
2. candidate pair back to the current signed pair, again using a full helper
   relaunch rather than hot reload;
3. deliberate protocol-range and missing-capability incompatibilities proving
   zero mutation; and
4. state-preserving attach, one guarded action, evidence capture, and exact
   process cleanup after each transition.

Never downgrade only one side and continue mutating. Do not reset app/simulator
data to make the exercise pass. There is no completed signed-pair exercise
today, so this gate remains a **BLOCKER**.

## Rollback procedure

Before promotion, record and independently verify a known-good signed tag, then
prove this procedure in a clean environment:

1. Stop distribution of the candidate; do not mutate or replace its tag.
2. Reactivate the known-good CLI from its immutable tag:

   ```bash
   dart pub global activate \
     --source git https://github.com/khorlim/flutter_scout.git \
     --git-ref <known-good-tag> \
     --git-path packages/flutter_scout
   ```

3. Verify the known-good tag signature and resolved commit again. Pin consuming
   apps to its documented compatible helper tag/commit, resolve dependencies
   from the reviewed lockfile, and fully relaunch the debug app. A hot reload is
   not a dependency downgrade.
4. Verify `flutter-scout version`, `doctor`, `status`, attach, inspect, one guarded
   action, evidence collection, and exact owned-process cleanup.
5. Verify the restored CLI/helper protocol and capabilities match the
   known-good matrix. Preserve the failing candidate evidence privately and
   issue a new signed patch release only after root cause and regression tests
   are complete.

Rollback must not reset simulator or app data, kill an attach-only human-owned
process, or replay an uncertain mutation. If compatibility or ownership is
uncertain, stop and request operator action.

**BLOCKER:** this rollback has not yet been exercised as a release gate.

## Final sign-off

The release owner may sign off only when:

- every zero-tolerance fixture passes;
- every required suite and artifact above is present;
- no blocker remains;
- all help, schemas, skills, changelogs, security guidance, and evidence output
  agree with the implementation;
- the candidate introduces no unexplained safety, privacy, compatibility, or
  performance regression.

Otherwise the honest outcome is: **not releasable yet**.
