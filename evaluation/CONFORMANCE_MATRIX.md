# Flutter Scout Quality Standard conformance matrix

This is the human-readable companion to
[`conformance_matrix.v1.json`](conformance_matrix.v1.json), which is the
canonical exhaustive, machine-readable ledger. Each row below maps one complete
requirement bundle from `QUALITY_STANDARD.md` to available proof, missing proof,
and release impact.

The machine ledger binds the exact standard bytes by SHA-256 and its integrity
test verifies that every cited source range remains inside the named section.

This matrix does **not** claim that Flutter Scout meets the standard. It audits
registered deterministic proof across the evaluation package, CLI, helper,
verification app, protocol artifacts, security corpus, CI configuration, and
release tooling. `implemented_proof` means tests or machine artifacts prove the
complete contract at their declared layer; environment-dependent or numeric
attainment still requires retained raw episodes. `unmeasured` means no
qualifying retained proof is registered here, not necessarily that product code
is absent.

Release impact means:

- `blocker`: missing/failing evidence blocks a release or gold-conformance claim.
- `conditional`: provisional target blocks after reference environment and
  baseline ratification, or when its stated condition applies.
- `advisory`: SHOULD-level evidence that remains visible but is not alone a
  MUST-level blocker.

Proof keys resolve to these files:

- `P-SCHEMAS`: versioned schemas in `schemas/v1/`.
- `P-ORACLE`: `lib/src/oracle.dart` and its false-claim test.
- `P-CATALOG`: catalog/task split validation and tests.
- `P-CORPUS`: machine-readable corpus policy/descriptor, release-readiness
  validator, deterministic public authoring generator, and tests.
- `P-CONFIG`: strict environment/config manifest and tests.
- `P-SCHEDULE`: deterministic paired schedule and tests.
- `P-CONTROLLED-COMPARISONS`: strict coordinate-only/current/candidate and
  optional perfect-handle roles, exact artifact/reset pins, equal-seed blocks,
  position-balanced randomization, all-role summaries, and tests.
- `P-ARCHIVE`: owner-only, create-once, bounded, stable raw-envelope loading,
  exact-byte hashing, symlink refusal, and tests.
- `P-REPORT`: strict report builder, CLI, and tests.
- `P-STATS`: Wilson/McNemar, template-cluster bootstrap, and Holm correction
  implementation and tests.
- `P-SAFETY-METRICS`: complete independently provenanced per-episode
  zero-tolerance guardrails, Wilson aggregates, fixed repetition readiness,
  fail-closed missing-monitor semantics, schemas, and tests; this key is not a
  retained release opportunity suite.
- `P-FAILURE`: episode invariants and first-causal taxonomy.
- `P-GUIDE`: `README.md` operating/retention guidance.
- `P-CLI-PROTOCOL`: CLI response, mutation-safety, compact-output, and schema
  contract tests.
- `P-COMMAND-GOLDENS`: independent catalogs for all 47 public commands and 331
  stable errors, bounded canonical envelope goldens, production drift checks,
  and a deterministic updater; this key is source-contract evidence, not
  release-versioned simulator transcripts.
- `P-HELPER-PROTOCOL`: helper mutation serialization, deduplication, identity,
  deadline, and pointer-lifecycle tests.
- `P-IDEMPOTENCY`: durable CLI receipt, stable child-key, bounded helper
  tombstone, fingerprint, and fail-closed retry contracts.
- `P-BOUNDED-INPUT`: bounded strict batch/replay parsing, complete preflight,
  allowlisted schemas, stable step keys, and closed aggregate outcome tests.
- `P-PERCEPTION`: helper snapshot, geometry, provenance, degradation, and icon
  freshness tests.
- `P-RESOLUTION`: helper stale/duplicate/occlusion/safe-point abstention tests.
- `P-NAVIGATION`: CLI/helper where/locate/reveal/since contracts and tests.
- `P-CHANGED-CAPTURE`: snapshot-bound semantic/render changed-region selection,
  post-raster identity recheck, strict geometry/pixel/byte bounds, typed
  abstention, schemas, and tests; this key is not real pixel/simulator evidence.
- `P-NATIVE-MOBILE`: source-level Android/iOS capability, bounded native
  process, screenshot/deeplink, scoped viewport/crop, and honest compatibility
  contracts; this key is not retained emulator/device parity evidence.
- `P-STABILITY-SIGNALS`: semantic stability and signal provenance/freshness
  tests.
- `P-LIFECYCLE`: CLI attach/session/supervisor/process ownership, stable kernel
  launch-lease contention/crash recovery, and lifecycle recovery tests.
- `P-STORAGE`: owner-only, atomic, lock-safe, and symlink-resistant storage
  tests.
- `P-RETENTION`: exact identity-bound artifact registry and cleanup, bounded
  directory manifests, corrupt-registry abstention, expiry/session/manual
  policy, and external-parent preservation tests.
- `P-TEMP-RECOVERY`: temporary-helper write-ahead-log, rollback, repair-record,
  and interruption tests.
- `P-NONINTERFERENCE`: helper observation-effect instrumentation and paused-frame
  non-interference tests.
- `P-PHASE-TIMINGS`: production CLI/helper exclusive eight-phase
  instrumentation, schemas, command inventory, and focused contract tests.
- `P-PERFORMANCE`: strict pinned performance/non-interference evidence schemas,
  immutable loader, reporter, CLI, and tests; this key is not a measured product
  result.
- `P-ENDURANCE`: strict correlated endurance configuration, independent probes,
  deterministic runner, tamper-evident archive, schemas, and tests; this key is
  not a retained 60-minute or 1,000-action result.
- `P-FUZZ`: 214 deterministic seeded resolution, snapshot/state-identity, and
  protocol-bound/cycle cases with exact seed/case replay instructions.
- `P-PRIVACY`: CLI/helper redaction tests, protected Dart-define sink/argv
  proofs, plus machine adversarial corpus and coverage artifact.
- `P-SECURE-INGRESS`: protected VM/deeplink/value/define-file ingress, exact
  loopback validation, one private capability store, no-argv evaluator handoff,
  and recursive raw/encoded credential-leak tests.
- `P-NO-EGRESS`: default-deny direct-network inventory and source gate; this
  key is not independent runtime proof that no OS process made an outbound
  connection.
- `P-SERVE`: authenticated bounded loopback transport contract tests.
- `P-PROTOCOL-ARTIFACTS`: published machine protocol schemas and method catalog.
- `P-CROSS-VERSION`: explicit current-source protocol-14/15/16 pairings,
  bilateral pre-dispatch gates, required-field/capability semantics, and tests;
  this key is not separately built release-binary interoperability evidence.
- `P-DEBUG-BUILD`: debug-only verifier, app oracle boundary tests, and CI build
  mode configuration; this key is not a retained successful build result.
- `P-RELEASE`: release-evidence tooling, compatibility/release policy, and both
  package changelogs; this key is not an actual release evidence bundle.
- `P-RELEASE-SUPPLY-CHAIN`: deterministic release-contract catalog, schema and
  changelog alignment, incomplete-composition SBOM, unsigned provenance,
  artifact digests, rollback/signing state, and semantic tamper self-check;
  this key is not a finalized, signed, independently verified release.
- `P-CI`: repository CI workflow configuration; this key is not a retained
  successful CI run.
- `P-OPERABILITY`: shared bounded status/doctor/health contract, compiled helper
  identity, observed/unavailable goldens, production health builder, and tests.
- `P-TOOL-SIM`: public Supplier evaluator controller, schemas, fixtures, runner,
  fresh setup/teardown validation, separation tests, and typed episode tests.
- `P-APP-FAULTS`: verification-app fault fixtures and widget tests.

The compact “missing proof” text is a reviewer aid. The JSON ledger preserves
all clauses in each bundle and the full missing-proof statement.

## Product, safety, privacy, and operability requirements

| ID / source | Requirement bundle | Status | Proof | Missing proof | Impact |
| --- | --- | --- | --- | --- | --- |
| `QS-NORTH-1` 15–41 | Trustworthy eyes/hands, explicit uncertainty, truth-first priority, canonical loop, optional subjective layers | partial | P-ORACLE, P-REPORT, P-CLI-PROTOCOL, P-HELPER-PROTOCOL, P-PERCEPTION, P-RESOLUTION, P-STABILITY-SIGNALS | Full retained exactly-once simulator loop and complete uncertainty proof | blocker |
| `QS-1.1` 45–63 | Facts vs inference/unknown/stale/unsupported; calibrated confidence; pixel-grounded visual claims/gaps | partial | P-CLI-PROTOCOL, P-PERCEPTION, P-CHANGED-CAPTURE | Independent labelled simulator perception/calibration episodes | blocker |
| `QS-1.2` 65–97 | Independent mutation outcomes and closed sets; unknown dispatch on post-dispatch timeout | partial | P-ORACLE, P-FAILURE, P-CLI-PROTOCOL, P-HELPER-PROTOCOL, P-BOUNDED-INPUT | Retained simulator fault injection for every closed outcome | blocker |
| `QS-1.3` 99–103 | Compact modes preserve every safety/uncertainty signal | implemented | P-CLI-PROTOCOL | — | blocker |
| `QS-2.1` 107–132 | Canonical interaction hierarchy and every required snapshot fact/limitation | partial | P-PERCEPTION, P-HELPER-PROTOCOL | Labelled simulator corpus covering every field | blocker |
| `QS-2.2` 134–141 | Monotonic generation + collision-resistant state digest; short hash never authorizes mutation | partial | P-HELPER-PROTOCOL, P-CLI-PROTOCOL, P-PERCEPTION, P-FUZZ | Cryptographic collision proof, broader scale, and retained simulator authorization episodes | blocker |
| `QS-2.3` 143–159 | Handle reliability order, run/runtime/generation scope, stale validation, ambiguity abstention | partial | P-RESOLUTION, P-PERCEPTION, P-CLI-PROTOCOL, P-FUZZ | Larger-scale handle campaigns and labelled simulator corpus | blocker |
| `QS-2.4` 161–165 | Evidence-local graceful degradation | partial | P-PERCEPTION, P-CHANGED-CAPTURE | Retained real platform-view and capture-backend failure simulator episodes | blocker |
| `QS-3.1` 169–192 | All immediate pre-dispatch checks, abstention evidence/recovery, and prohibited unsafe selection/fallback/retry | partial | P-RESOLUTION, P-PERCEPTION, P-CLI-PROTOCOL | 3,000 retained labelled simulator opportunities | blocker |
| `QS-3.2` 194–237 | Durable cross-process/reconnect exactly-once receipts and child keys, bounded fail-safe tombstones/fingerprints, serialized mutation, exclusive/cancelled pointer | partial | P-CLI-PROTOCOL, P-HELPER-PROTOCOL, P-IDEMPOTENCY, P-BOUNDED-INPUT, P-PROTOCOL-ARTIFACTS | Unrestricted CLI suite and retained reconnect/crash simulator episodes | blocker |
| `QS-3.3` 239–243 | Explicit coordinate fallback with complete coordinate/hit-test provenance | partial | P-RESOLUTION, P-PERCEPTION, P-CLI-PROTOCOL, P-NATIVE-MOBILE, P-CHANGED-CAPTURE | Retained cross-device DPR/orientation episodes | blocker |
| `QS-4` 245–276 | Evidence-producing action transaction, every response field, return-to-start vs no-op | partial | P-ORACLE, P-REPORT, P-CLI-PROTOCOL, P-HELPER-PROTOCOL, P-STABILITY-SIGNALS, P-CHANGED-CAPTURE | Complete retained simulator transactions | blocker |
| `QS-5.1` 278–287 | Bounded deterministic where/locate/reveal/since primitives | implemented | P-NAVIGATION, P-PROTOCOL-ARTIFACTS | — | advisory |
| `QS-5.2` 289–300 | Locate/reveal reports all bounds/progress/regions/loop/end/stop/restoration facts | partial | P-NAVIGATION | Retained nested/lazy simulator traces | blocker |
| `QS-5.3` 302–308 | Complex-navigation orientation facts; agent plans; broad explorer stays optional | partial | P-NAVIGATION, P-PERCEPTION | Complex-app corpus and optional-explorer evidence | blocker |
| `QS-6.1` 312–326 | Semantic/actionable stability states and bounded disclosed waits | partial | P-STABILITY-SIGNALS, P-HELPER-PROTOCOL | Retained app/process/VM-loss simulator episodes | blocker |
| `QS-6.2` 328–346 | Full hard-signal coverage, provenance, freshness and cursor semantics | partial | P-STABILITY-SIGNALS, P-CLI-PROTOCOL, P-APP-FAULTS | Labelled precision/recall/latency simulator episodes for every signal | blocker |
| `QS-7.1` 350–354 | Attach preserves all state/ownership unless explicit | partial | P-LIFECYCLE, P-SECURE-INGRESS | Retained state-preservation simulator episodes | blocker |
| `QS-7.2` 356–363 | Exactly-one ensure, no cross-session access, crash-safe metadata, explicit lifecycle ownership | partial | P-LIFECYCLE, P-STORAGE, P-RETENTION, P-TEMP-RECOVERY | Multi-device crash/reconnect simulator evidence | blocker |
| `QS-7.3` 365–372 | Exact multi-factor process identity; uncertain stop never kills | implemented | P-LIFECYCLE | — | blocker |
| `QS-7.4` 374–386 | Bounded recovery for every listed fault; acknowledged transitions; temporary-helper rollback/repair record | partial | P-LIFECYCLE, P-STORAGE, P-RETENTION, P-TEMP-RECOVERY | Full VM/daemon/disk/permission simulator fault suite | blocker |
| `QS-8.1` 390–396 | No Scout activity in normal profile/release; guarded benchmark build cannot alter them | partial | P-DEBUG-BUILD, P-CI | Retained successful binary inspection and runtime-absence result | blocker |
| `QS-8.2` 398–419 | Earliest-source secret redaction across every listed sink; no length; protected input/replay placeholders | partial | P-PRIVACY, P-SECURE-INGRESS, P-STORAGE, P-BOUNDED-INPUT | Screenshot/OCR and cross-platform process-boundary episodes | blocker |
| `QS-8.3` 421–431 | Loopback/owner-only authenticated transport; POST/method/body/deadline/path/origin controls; strict typed methods | partial | P-SERVE, P-SECURE-INGRESS, P-CLI-PROTOCOL | Independent penetration evidence | blocker |
| `QS-8.4` 433–442 | 0700/0600 artifacts, privacy labels/retention, opt-in telemetry, control/delimiter/secret sanitization | partial | P-ARCHIVE, P-GUIDE, P-STORAGE, P-RETENTION, P-PRIVACY, P-NO-EGRESS | Independent runtime network/process-boundary and cross-platform cleanup episodes | blocker |
| `QS-9.1` 444–459 | Required typed/versioned response envelope fields | partial | P-SCHEMAS, P-PROTOCOL-ARTIFACTS, P-CLI-PROTOCOL, P-HELPER-PROTOCOL, P-COMMAND-GOLDENS | Release-versioned simulator transcripts for every command | blocker |
| `QS-9.2` 461–474 | Bidirectional negotiation and all within-major compatibility/bounds/deadline/schema/event rules | partial | P-SCHEMAS, P-PROTOCOL-ARTIFACTS, P-CROSS-VERSION, P-CLI-PROTOCOL, P-HELPER-PROTOCOL, P-BOUNDED-INPUT, P-COMMAND-GOLDENS | Retained N/N-1/N+1 release-binary interoperability | blocker |
| `QS-9.3` 476–483 | Honest capability-based support matrix, migration window/fail-fast, declared API/SemVer | partial | P-RELEASE, P-PROTOCOL-ARTIFACTS, P-CROSS-VERSION, P-NATIVE-MOBILE | Published history and retained release-binary/support-matrix execution | blocker |
| `QS-9.4` 484–485 | Aligned CLI/helper/protocol changelogs and compatibility table | partial | P-RELEASE, P-RELEASE-SUPPLY-CHAIN, P-CROSS-VERSION | Finalized release-tagged alignment evidence bundle | blocker |
| `QS-10` 487–506 | Optimize task success; safe compact output; all agent-efficiency affordances; essential facts are structured | partial | P-CLI-PROTOCOL, P-NAVIGATION, P-CHANGED-CAPTURE, P-STABILITY-SIGNALS, P-BOUNDED-INPUT, P-CONTROLLED-COMPARISONS, P-TOOL-SIM | Real pinned-agent ablations and retained task/token/call cohorts | blocker |
| `QS-11.1` 508–517 | Separate phase timings and fully pinned measurement environment/method | partial | P-CONFIG, P-REPORT, P-PERFORMANCE, P-PHASE-TIMINGS | Retained real-device samples and frozen baseline | blocker |
| `QS-11.2` 519–525 | Observation non-interference; performance targets bind only after freeze | partial | P-NONINTERFERENCE, P-PERFORMANCE | Retained independent iOS/Android oracle episodes and frozen baseline | blocker |
| `QS-12.1` 527–538 | Doctor/status/health expose every required identity/capability/ownership/recovery fact | implemented | P-OPERABILITY, P-LIFECYCLE, P-CLI-PROTOCOL | Retained live-socket and simulator observation remains additional empirical evidence | advisory |
| `QS-12.2` 540–550 | Correlated/lossless/concurrent events, structured heartbeats, self-describing evidence, non-mutating diagnostics | partial | P-CONFIG, P-ARCHIVE, P-REPORT, P-CLI-PROTOCOL, P-LIFECYCLE, P-STORAGE, P-OPERABILITY, P-CHANGED-CAPTURE | Concurrent losslessness and diagnostic non-interference episodes | blocker |

## Evaluation requirements

| ID / source | Requirement bundle | Status | Proof | Missing proof | Impact |
| --- | --- | --- | --- | --- | --- |
| `QS-13.1` 554–563 | Score protocol/unit, tool-simulator, agent, and real-app layers separately | partial | P-CONFIG, P-REPORT, P-CLI-PROTOCOL, P-HELPER-PROTOCOL, P-TOOL-SIM | Complete agent and real-app corpora/results | blocker |
| `QS-13.2` 565–582 | Independent inaccessible oracle, complete hidden task lifecycle/predicates, exact pass rule, invalid-vs-product failure | partial | P-ORACLE, P-FAILURE, P-SCHEMAS, P-TOOL-SIM | Private, frozen-hidden, and real-app controllers | blocker |
| `QS-13.3-SPLITS` 584–590 | Three catalog sets disjoint by template | partial | P-CATALOG, P-SCHEMAS | Populated/frozen private release catalogs | blocker |
| `QS-13.3-CORPUS` 592–613 | 60-template breadth, five variants each, real apps beyond Stress Lab | partial | P-CORPUS, P-SCHEMAS | Runnable task-specific fixtures/oracles, populated private/frozen catalogs, and two real-app integrations | blocker |
| `QS-13.4` 615–628 | Controlled comparison conditions; every model/prompt/tool/app/environment/seed/budget pin; randomized order | partial | P-CONFIG, P-SCHEDULE, P-CONTROLLED-COMPARISONS | Real pinned-model/simulator controlled run and retained episodes | blocker |
| `QS-13.5-REPETITION` 630–639 | 100 primitive reps, 3,000 safety opportunities, 10/20 agent reps, fresh resets, identical pairs | partial | P-CONFIG, P-SCHEDULE, P-ARCHIVE, P-TOOL-SIM, P-SAFETY-METRICS | Retained release primitive samples and qualifying opportunity/repetition counts | blocker |
| `QS-13.5-STATISTICS` 640–644 | Wilson/exact, paired test, template-cluster bootstrap, multiplicity correction | implemented | P-STATS, P-REPORT, P-SAFETY-METRICS | — | advisory |
| `QS-13.5-INTEGRITY` 645–646 | Never post-hoc discard; invalid harness runs separate with reasons | implemented | P-SCHEDULE, P-ARCHIVE, P-REPORT, P-SAFETY-METRICS | — | blocker |
| `QS-13.6-PRIMARY` 648–657 | Clean/perturbed success and calls/tokens/bytes/screenshots/time per successful task | implemented | P-REPORT, P-STATS | Actual complete raw episodes | blocker |
| `QS-13.6-SAFETY` 658–666 | Every listed safety guardrail count | implemented | P-REPORT, P-FAILURE, P-TOOL-SIM, P-PRIVACY, P-LIFECYCLE, P-SAFETY-METRICS | Actual preregistered release opportunities remain absent; no rate attainment claimed | blocker |
| `QS-13.6-DIAGNOSTIC` 667–679 | Every listed perception/action/handle/delta/signal/stability/navigation/lifecycle/loop/latency/resource metric | partial | P-PERCEPTION, P-RESOLUTION, P-NAVIGATION, P-STABILITY-SIGNALS, P-LIFECYCLE, P-PHASE-TIMINGS | Independent labels, profilers, and retained aggregate episodes | blocker |
| `QS-13.7` 681–700 | One first-causal category/severity; required safety failures release-blocking | implemented | P-FAILURE, P-REPORT, P-SCHEMAS | More typed safety subcategories | blocker |

## Release gates

| ID / source | Requirement bundle | Status | Proof | Missing proof | Impact |
| --- | --- | --- | --- | --- | --- |
| `QS-14.1-FALSE-SUCCESS` 704–718 | Any reproducible false success blocks | implemented | P-ORACLE, P-REPORT, P-TOOL-SIM, P-SAFETY-METRICS | Complete preregistered release opportunity suite | blocker |
| `QS-14.1-TARGET-SURFACE` 704–718 | Wrong target/surface or modal bypass blocks | partial | P-REPORT, P-FAILURE, P-RESOLUTION, P-PERCEPTION, P-TOOL-SIM, P-SAFETY-METRICS | Preregistered simulator opportunity corpus | blocker |
| `QS-14.1-DUPLICATE` 704–718 | Duplicate mutation after retry/reconnect blocks | partial | P-CLI-PROTOCOL, P-HELPER-PROTOCOL, P-TOOL-SIM, P-SAFETY-METRICS | Retained retry/reconnect simulator opportunities | blocker |
| `QS-14.1-FORBIDDEN` 704–718 | Forbidden-state mutation blocks | implemented | P-ORACLE, P-REPORT, P-TOOL-SIM, P-SAFETY-METRICS | Complete release fixture set | blocker |
| `QS-14.1-ISOLATION` 704–718 | Cross-session observation/action blocks | partial | P-LIFECYCLE, P-STORAGE, P-SAFETY-METRICS | Multi-device crossover oracle/stress suite | blocker |
| `QS-14.1-PROCESS` 704–718 | Unrelated process termination blocks | implemented | P-LIFECYCLE, P-SAFETY-METRICS | — | blocker |
| `QS-14.1-DESTRUCTIVE-RESET` 704–718 | Unrequested destructive reset blocks | partial | P-LIFECYCLE, P-TOOL-SIM, P-SAFETY-METRICS | Retained simulator data canaries for every lifecycle path | blocker |
| `QS-14.1-SECRET` 704–718 | Plaintext secret leak blocks | partial | P-PRIVACY, P-SECURE-INGRESS, P-STORAGE, P-SAFETY-METRICS | Screenshot/OCR, process-boundary, and real-device episodes | blocker |
| `QS-14.1-DEBUG-ONLY` 704–718 | Active Scout in normal profile/release blocks | partial | P-DEBUG-BUILD, P-CI, P-SAFETY-METRICS | Retained successful binary/runtime absence result | blocker |
| `QS-14.1-SAFETY-REGRESSION` 704–718 | Unexplained safety regression blocks | partial | P-SCHEDULE, P-REPORT, P-STATS, P-SAFETY-METRICS | Retained preregistered current/candidate safety archives | blocker |
| `QS-14.2-TASK-RATES` 720–754 | Lower-95 clean ≥95%, perturbed ≥90%, worst family ≥80% | implemented evaluator | P-REPORT, P-STATS | Complete preregistered archives; no scores claimed | conditional |
| `QS-14.2-TOOL-CORRECTNESS` 720–754 | Every primitive/perception/modal/stale/delta/fault/signal/stability/locate/lifecycle/replay target | partial | P-TOOL-SIM, P-RESOLUTION, P-NAVIGATION, P-STABILITY-SIGNALS, P-STATS, P-SAFETY-METRICS | Opportunity-labelled simulator suites and intervals for every target | conditional |
| `QS-14.2-ROBUSTNESS-DROP` 720–754 | Perturbation drop ≤5 points | unmeasured | — | Joint clean/perturbed cohorts | conditional |
| `QS-14.2-PERFORMANCE` 720–754 | Inspect/action/payload/CPU/memory/frame/endurance targets | unmeasured | — | Frozen environment, production samples, and real 60min/1000-action archive | conditional |
| `QS-14.2-RATIFICATION` 720–755 | Aspirational-until-frozen, no silent weakening, lower-95 rule, 100% deterministic safety | partial | P-CONFIG, P-REPORT, P-RELEASE, P-SAFETY-METRICS | Signed frozen baseline/change-control record | conditional |
| `QS-14.3` 757–771 | Paired non-inferiority, strict improvement claims, no safety/privacy compensation | partial | P-REPORT, P-STATS, P-CONTROLLED-COMPARISONS, P-SAFETY-METRICS | Real paired-delta/cost intervals and retained safety/privacy episodes | blocker |

## Test architecture, platforms, release discipline, and definition of done

| ID / source | Requirement bundle | Status | Proof | Missing proof | Impact |
| --- | --- | --- | --- | --- | --- |
| `QS-15.1` 773–792 | Maintain every listed contract, compatibility, fuzz, widget, lifecycle, simulator, agent, performance, security and endurance suite | partial | P-ORACLE, P-CATALOG, P-SCHEDULE, P-CONTROLLED-COMPARISONS, P-REPORT, P-SAFETY-METRICS, P-CLI-PROTOCOL, P-COMMAND-GOLDENS, P-HELPER-PROTOCOL, P-CROSS-VERSION, P-PERCEPTION, P-RESOLUTION, P-NAVIGATION, P-CHANGED-CAPTURE, P-NATIVE-MOBILE, P-STABILITY-SIGNALS, P-LIFECYCLE, P-STORAGE, P-RETENTION, P-PRIVACY, P-SECURE-INGRESS, P-BOUNDED-INPUT, P-NO-EGRESS, P-OPERABILITY, P-TOOL-SIM, P-PERFORMANCE, P-ENDURANCE, P-PHASE-TIMINGS, P-FUZZ, P-RELEASE-SUPPLY-CHAIN | Cross-version binaries, cross-platform simulator, agent, real-app, larger-scale fuzz, and retained empirical performance/endurance evidence | advisory |
| `QS-15.2` 793–794 | Flakes are defects; preserve failing seeds and repeated passes; coverage alone not gate | partial | P-SCHEDULE, P-ARCHIVE, P-LIFECYCLE, P-CI, P-FUZZ | Retained successful candidate repetition artifact and critical Tier-1 simulator repetitions | blocker |
| `QS-16.1` 796–800 | Same behavioral contract on every Tier-1 platform | unmeasured | — | Cross-platform result matrix | blocker |
| `QS-16.2` 802–805 | iOS/Android Tier 1 recommendation and honest experimental labels until passing | partial | P-RELEASE, P-NATIVE-MOBILE | Retained per-platform behavioral suites required for Tier-1 designation | blocker |
| `QS-16.3` 807–809 | Unsupported-before-mutation and fully disclosed platform fallback | partial | P-CLI-PROTOCOL, P-NATIVE-MOBILE | Equivalent retained fallback coverage on every platform | blocker |
| `QS-16.4` 811–813 | Preregistered small Tier-1 gap; initial ≤3 points | unmeasured | — | Matched cross-platform pairs | advisory |
| `QS-17.1` 815–818 | Pinned blocking toolchain and stable/beta canaries | partial | P-CONFIG, P-CI | Retained successful CI run artifacts | blocker |
| `QS-17.2` 820–830 | Every listed release-candidate gate passes | partial | P-REPORT, P-SCHEDULE, P-CONTROLLED-COMPARISONS, P-CROSS-VERSION, P-COMMAND-GOLDENS, P-CI, P-DEBUG-BUILD, P-RELEASE, P-RELEASE-SUPPLY-CHAIN | Retained controlled-run, cross-version-binary, simulator, performance, platform, and full release-candidate artifacts | blocker |
| `QS-17.3` 832–841 | Every listed schema/changelog/matrix/migration/provenance/SBOM/signing/rollback artifact | partial | P-SCHEMAS, P-PROTOCOL-ARTIFACTS, P-RELEASE, P-RELEASE-SUPPLY-CHAIN | Finalized release archives, approved signature and independent verification, complete SBOM inputs, trusted CI provenance, and rehearsed rollback | blocker |
| `QS-17.4` 843 | Public API/versioning follows SemVer | partial | P-RELEASE | Published multi-release history audit | advisory |
| `QS-18.1` 845–856 | All eight feature definition-of-done conditions | partial | P-SCHEMAS, P-SCHEDULE, P-REPORT, P-CLI-PROTOCOL, P-COMMAND-GOLDENS, P-HELPER-PROTOCOL, P-CHANGED-CAPTURE, P-CI, P-RELEASE, P-RELEASE-SUPPLY-CHAIN | Feature simulator evidence, real deltas, performance regression, repository-wide synchronization audit | blocker |
| `QS-18.2` 858–861 | Every held-out workflow step correct or safely uncertain, never confidently wrong | unmeasured | — | Complete step-level hidden-oracle suite | blocker |

## Current release conclusion

This ledger has many `blocker` rows with `partial` or `unmeasured` proof.
Therefore it cannot support a Flutter Scout gold-conformance or release-pass
claim. The paired runner can produce honest scoped measurements, but the
remaining product, simulator, security, compatibility, performance, platform,
and endurance evidence must be supplied and linked before promotion.
