# Flutter Scout Quality Standard

## Status and intent

This document defines the highest product, engineering, safety, performance,
evaluation, and release standards for Flutter Scout.

It is a target contract, not a claim that every requirement is already met.
Conformance must be demonstrated with reproducible evidence. Aggregate scores
must never override a safety or truthfulness failure.

The terms **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are
normative.

## North-star contract

Flutter Scout must behave like trustworthy instrumentation, not a clever screen
macro:

> Given a real Flutter app state, Scout must let an agent perceive the
> actionable state, dispatch exactly one intended interaction, and know the
> resulting state and hard failures—or explicitly report what is ambiguous,
> stale, unsupported, unavailable, or unknown.

Priorities are non-negotiable:

```text
truthfulness > actuation safety > recoverability > completeness > efficiency > speed
```

A precise refusal is always better than a plausible but incorrect success.

The core loop remains:

```text
attach or launch -> inspect -> act -> wait stable -> return delta + hard signals -> replay
```

Scout's core reports facts and provides deterministic perception and action
primitives. Subjective UX judgment, autonomous exploration, accessibility
audits, and visual-regression analysis belong in optional layers above the core.

## 1. Truthfulness and outcome semantics

### 1.1 Facts, inference, and unknowns

Scout MUST distinguish:

- directly observed facts;
- heuristic inferences;
- unavailable evidence;
- unsupported capabilities;
- stale evidence;
- unknown outcomes.

An inferred label, route guess, or confidence score MUST NOT be presented as
ground truth. Numeric confidence MUST be empirically calibrated. If it is not
calibrated, it MUST be described as a heuristic rank or score.

Scout MUST NOT claim visual quality without pixel evidence. Semantics-free
`CustomPaint` regions and opaque platform views MUST produce an explicit
perception gap and a focused crop or screenshot recommendation, not invented
meaning.

### 1.2 Command success is not task success

`ok: true` MUST NOT silently mean that a business operation succeeded. Every
mutation MUST report independent outcome dimensions:

```json
{
  "transport": "ok",
  "dispatch": "dispatched",
  "observation": "changed",
  "postcondition": "met",
  "runtimeHealth": "clean"
}
```

Closed outcome sets MUST distinguish at least:

- `not_dispatched`;
- `dispatched`;
- `dispatch_outcome_unknown`;
- `changed`;
- `completed_same_state`;
- `no_effect`;
- `observation_unavailable`;
- `postcondition_met`;
- `postcondition_not_met`;
- `postcondition_not_requested`;
- `runtime_clean`;
- `runtime_blocked`;
- `runtime_health_unknown`.

A transport timeout after dispatch MUST return `dispatch_outcome_unknown`. It
MUST NOT be represented as a safe failure or retried blindly.

### 1.3 Never compact away safety evidence

Fresh blocking errors, failed expectations, unknown dispatch outcomes,
ambiguity, stale identity, and missing observation MUST survive every compact
output mode.

## 2. Perception standard

### 2.1 Interaction hierarchy

The canonical context is:

```text
run
└── route or screen
    └── active surface
        └── region or scrollable
            └── row
                └── control
```

Snapshots MUST expose, when observable:

- route, screen, and active surface as separate concepts;
- selected tab and navigator context;
- modal, sheet, menu, overlay, and keyboard state;
- scroll regions, axis, bounds, and approximate position;
- visibility, clipping, occlusion, and hit-test state;
- enabled, selected, checked, expanded, and validation state;
- field labels and safely redacted values;
- handle provenance and alternate identities;
- logical coordinates, physical coordinates, device pixel ratio, insets,
  orientation, and window scaling;
- perception coverage, degraded nodes, omitted sections, and blind spots.

### 2.2 Snapshot identity

Each runtime MUST expose a monotonic state generation. Snapshot identity MUST
combine that generation with a collision-resistant digest of all
agent-relevant observed state.

A short text hash or control count MAY be used for compact correlation, but it
MUST NOT authorize a mutation by itself.

### 2.3 Handle quality

Handles SHOULD be derived from, in descending order of reliability:

1. explicit stable keys;
2. semantics labels and roles;
3. visible text and tooltips;
4. control type and state;
5. row, field, and region context;
6. geometry and hit testing.

Every handle MUST be scoped to a run, runtime, and state generation. A handle
from an older state may be re-resolved only after identity validation.

Duplicate or ambiguous handles MUST NOT be presented as unique. When identity
is no longer unique, Scout MUST abstain and return ranked candidates with their
evidence.

### 2.4 Graceful degradation

A failing element, malformed semantics node, platform view, or unavailable
capture backend MUST degrade only the affected evidence. Scout SHOULD return
the remaining trustworthy snapshot plus structured limitations.

## 3. Actuation safety and exactly-once behavior

### 3.1 Pre-dispatch validation

Immediately before mutation, Scout MUST confirm that the target is:

- uniquely resolved;
- from the expected run, runtime, and state generation;
- on the active surface;
- visible and sufficiently exposed;
- enabled and hit-testable;
- unobscured at the selected safe point;
- still the same logical control.

If any condition fails, Scout MUST abstain and return structured evidence,
candidate targets, and a safe recovery action.

Scout MUST NOT:

- choose the first generic `Save`, `OK`, or repeated row;
- tap through a modal barrier;
- silently replace a stale handle with a different control;
- silently convert a failed semantic target into a coordinate tap;
- use the center of a partially visible or broadly enclosing target when a
  safer visible point exists;
- retry a mutation after an uncertain timeout without deduplication.

### 3.2 Mutation envelope

Every mutating request MUST carry:

```text
commandId
idempotencyKey
runId
runtimeInstanceId
expectedStateGeneration
deadline
```

The helper MUST deduplicate repeated idempotency keys and return the original
outcome. Reads MAY retry automatically. Mutations MAY retry only through this
deduplication mechanism.

Exactly-once identity MUST survive a short-lived CLI process and persistent
transport reconnect, not merely one VM-service call. Normal CLI commands and
authenticated `/v1/call` MUST accept a caller-supplied idempotency key; Scout
MUST generate one when omitted. Before dispatch, the CLI MUST atomically commit
an owner-only receipt containing the canonical business fingerprint and exact
invocation identity, but no raw business parameter, input value, or secret.
The same key and business fingerprint MUST reconcile or replay the original
outcome across processes. The same key with a different business request MUST
abstain with `idempotency_conflict`.

An uncertain receipt bound to a replaced runtime, an integrity failure, or a
pruned outcome MUST return `dispatch_outcome_unknown` and MUST NOT redispatch.
Batch and replay steps MUST derive stable per-step keys from one scope key.
Both durable receipts and helper memory MUST be bounded. Pruning MUST leave a
fail-safe tombstone (exact or no-false-negative probabilistic); reaching a
bound MUST reject new mutation identities rather than forget old ones and risk
a duplicate.

The helper business fingerprint MUST exclude volatile retry fields such as
command/deadline/error cursor/state preconditions while retaining extension,
method, business parameters, run identity, and runtime identity. A retry can
therefore change observation/deadline metadata without becoming a different
business mutation, while a real business-parameter change always conflicts.

Only one state-mutating action may execute on a runtime at a time. A held drag
MUST exclusively own its pointer lifecycle until completion or explicit
cancellation. Abandoned pointer state MUST be cancelled safely.

### 3.3 Coordinate fallback

Coordinate actions MUST be explicit. Their response MUST include logical and
physical positions, device pixel ratio, viewport, safe areas, and the hit-tested
target observed immediately before dispatch.

## 4. Evidence-producing actions

Every action MUST behave as one evidence-producing transaction:

```text
fresh snapshot
-> resolve target
-> dispatch once
-> observe activity
-> settle
-> calculate delta
-> collect fresh runtime and log signals
```

The response MUST contain:

- before and after state generations and snapshot identities;
- requested selector and actual resolved target;
- resolution strategy, provenance, candidates, and safe point;
- dispatch status;
- transient and late activity observations;
- stability status, stopping reason, and elapsed time;
- route, surface, field, validation, selection, enabled-state, geometry,
  scroll, and runtime deltas;
- postcondition details;
- fresh error and log cursors;
- phase timings;
- capture identity when an exact expectation frame was requested.

Scout MUST distinguish activity that returns to the starting state from a true
no-op. A gesture being dispatched MUST NOT count as evidence that its intended
effect occurred.

## 5. Complex navigation standard

Scout SHOULD provide bounded deterministic navigation primitives such as:

```bash
flutter-scout where
flutter-scout locate --text "Hair Recovery"
flutter-scout reveal --text "Hair Recovery" --within scroll.forms
flutter-scout inspect --since <snapshot-id>
```

A bounded locate or reveal operation MUST report:

- query and scope;
- search region and direction;
- starting state generation;
- action, distance, time, and response-size bounds;
- progress signatures;
- scroll regions attempted;
- repeated-state and loop detection;
- end-of-content detection;
- exact stopping reason;
- whether the original position was restored after failure.

Scout MUST support orientation facts for nested navigators, tabs, split panes,
modals, lazy lists, nested scrolling, expandable regions, moving targets, and
keyboard-driven layout changes.

Scout supplies facts, bounded search, and recovery primitives. The AI agent
remains the planner. A broad autonomous explorer MUST be optional and MUST NOT
weaken the deterministic core.

## 6. Stability and runtime-signal standard

### 6.1 Stability

Stability MUST be defined in terms of actionable and semantic quiescence, not
only the absence of a scheduled frame.

Scout MUST distinguish:

- stable state;
- transient activity still settling;
- continuous background animation with an otherwise actionable UI;
- never-settling state;
- app or runtime loss;
- observation unavailable.

Stability waits MUST be bounded and disclose their stopping reason.

### 6.2 Runtime signals

Supported hard-signal detection SHOULD cover:

- Flutter framework errors;
- uncaught Dart errors;
- platform dispatcher errors;
- `ErrorWidget` or visible Flutter error surfaces;
- `RenderFlex` and other framework overflows;
- image-loading failures;
- high-severity application log signals;
- permission and request failures;
- VM-service disconnects;
- app process death;
- Flutter build and hot-update rejection.

Each signal MUST include factual provenance, timestamp, severity, blocking
status, phase, age, staleness, deduplication identity, and its action/log cursor.
Old signals MUST NOT be attributed to a new action as fresh.

## 7. Lifecycle and ownership standard

### 7.1 State preservation

`attach` MUST preserve app, simulator, navigation, and data state by default.
It MUST NOT relaunch, reset, clear data, or take process ownership unless the
caller explicitly requests that behavior.

### 7.2 Session isolation

- Concurrent `ensure` calls for one name MUST produce exactly one owned runner.
- Named sessions MUST never cross-read or cross-act.
- Session metadata, registries, recordings, and evidence indexes MUST be
  transactional and crash-safe.
- Run, runtime, isolate, protocol, source, log, supervisor, and process
  ownership MUST remain explicit after attach, reconnect, reload, and restart.

### 7.3 Exact process ownership

Process ownership MUST validate more than PID existence. Run token, executable,
command identity, process start time, project, device, parentage, and supervisor
identity SHOULD agree before termination.

`stop` MUST terminate only exactly owned resources. Identity uncertainty means
`do not kill`.

### 7.4 Recovery

VM disconnect, changed VM port, stale URI, helper restart, daemon loss, corrupt
or partial metadata, full disk, permissions failure, runner death, and process
ID reuse MUST have deterministic, bounded recovery behavior.

Reload or restart success MUST require explicit Flutter-tool acknowledgement
and the expected runtime transition. An inspectable old isolate MUST NOT count
as restart success.

Temporary-helper mode MUST restore every tracked input after success, failure,
interruption, or recovery. An interrupted transaction MUST leave a discoverable
repair record.

## 8. Security and privacy standard

### 8.1 Debug-only operation

Normal profile and release builds MUST NOT register Scout service extensions,
error hooks, recorders, overlays, or network listeners.

A specifically guarded benchmark build MAY enable limited instrumentation for
measurement, but this MUST NOT change normal profile or release behavior.

### 8.2 Source redaction

Passwords, PINs, passcodes, OTPs, payment values, tokens, cookies, session IDs,
API keys, and fields marked `obscureText` MUST be redacted at the earliest
source.

Redaction MUST cover:

- inspect and brief summaries;
- before/after state and deltas;
- events and logs;
- recordings and replay scripts;
- evidence bundles and screenshots metadata;
- error messages, diagnostics, and heartbeats;
- command histories and process arguments.

For an obscured field Scout MAY report `redacted: true` and whether it is empty,
but MUST NOT expose plaintext or length.

Secrets SHOULD enter through protected standard input or owner-only variable
files rather than command-line arguments. Replay MUST preserve redacted
placeholders and request the value at execution time.

### 8.3 Local transport

Persistent transport MUST bind only to loopback or an owner-only Unix-domain
socket. It MUST also use an ephemeral session credential.

Mutations MUST be `POST` operations. Requests MUST enforce method allowlists,
content type, body-size limits, deadlines, path validation, and origin or CSRF
protection where relevant.

Legacy free-form command execution SHOULD be disabled by default. Typed methods
MUST validate strict allowlisted parameters.

### 8.4 Artifact handling

Session directories SHOULD use owner-only `0700` permissions and sensitive
files `0600`. Evidence and screenshots MUST be labelled as potentially
containing private application data and have explicit retention behavior.

No telemetry may leave the machine without explicit opt-in.

Logs MUST sanitize control characters and delimiters as well as known secret
patterns.

## 9. Protocol and compatibility standard

Every response MUST use a typed, versioned envelope containing:

```text
schemaVersion
protocolVersion
capabilities
commandId
runId
runtimeInstanceId
stateGeneration
result
structuredError
timings
```

CLI and helper compatibility MUST be negotiated in both directions with
minimum and maximum supported protocol versions plus feature capabilities. An
incompatible pair MUST fail before mutation.

Within one major protocol version:

- error codes MUST NOT change meaning;
- unknown optional fields MUST be tolerated;
- missing required fields MUST fail schema validation;
- additive changes MUST remain backward-compatible;
- payloads MUST be bounded;
- deadlines and cancellation behavior MUST be explicit;
- typed method schemas MUST be machine-readable;
- event ordering MUST be deterministic and cursor-addressable.

The project MUST publish an honest support matrix for CLI, helper, protocol,
Dart, Flutter, host OS, and target platform. Capabilities, not package-version
guesses, determine feature availability.

The current and previous helper protocol SHOULD be supported during a documented
migration window. Otherwise Scout MUST fail clearly before any action.

Package versions MUST follow a declared public API and Semantic Versioning.
CLI, helper, and protocol changes MUST have aligned changelogs and a documented
compatibility table.

## 10. Agent-efficiency standard

Scout MUST optimize successful task completion, not isolated command speed.

Compact output SHOULD contain only information needed for the next practical
decision. It MUST retain uncertainty and safety facts.

Scout SHOULD provide:

- bounded brief inspection with explicit omitted counts;
- snapshot-relative deltas;
- stable references for unchanged state;
- typed persistent transport;
- batch execution for guarded deterministic flows;
- exact same-call expectations and capture;
- factual next-best recovery actions;
- opt-in full sections and raw evidence;
- structured no-progress and repeated-action detection.

No agent should need to parse prose for an essential state or error fact.

## 11. Performance and non-interference standard

Scout MUST measure its own phases separately from application settling:

```text
connect -> snapshot -> match -> dispatch -> settle -> delta -> logs -> serialize
```

Performance measurements MUST pin hardware, OS, Flutter version, build mode,
app fixture, tree size, viewport, and measurement method.

The helper MUST NOT introduce focus changes, gestures, route changes, semantics
changes, persistent overlay interception, or business-state mutation during
observation.

Provisional reference-device targets are defined in the release-gate section.
They become binding only after the benchmark environment and baseline are
frozen.

## 12. Operability and evidence standard

`doctor`, `status`, and `health` SHOULD expose:

- binary and package identity;
- protocol compatibility and capabilities;
- session and process ownership;
- VM and runtime identity and reachability;
- supervisor state;
- logs and capture availability;
- source-code freshness after hot update;
- one prioritized recovery action.

Every event MUST be correlated with command, run, runtime, state, and log cursor
identities. Logs and JSONL events MUST be concurrency-safe, ordered, sanitized,
cursor-addressable, and lossless under simultaneous writers.

Long operations MUST emit structured heartbeats with stage, elapsed time, and
sanitized progress.

Evidence bundles MUST be self-describing and include tool versions, commits,
platform, device, Flutter version, schema and protocol versions, seed,
timestamps, action transcript, and explicit reasons for missing evidence.
Diagnostic collection MUST NOT mutate app state.

## 13. Evaluation standard

### 13.1 Four evaluation layers

The following layers MUST be scored separately:

| Layer | Purpose |
| --- | --- |
| Protocol and unit | Schema, matching, delta, redaction, and lifecycle invariants |
| Tool-only simulator | Known targets and outcomes without AI involvement |
| Agent benchmark | Natural-language tasks executed by a pinned model |
| Real-app benchmark | Long workflows in at least two non-fixture Flutter apps |

### 13.2 Independent oracles

The evaluator MUST NOT use Scout's own inspect output, delta, screenshot, or
claimed result as ground truth.

Each task MUST have out-of-band setup, hidden functional success predicates,
forbidden-state predicates, and teardown. The agent MUST NOT be able to query
the oracle.

A task passes only when:

- all hidden success predicates are true;
- no forbidden predicate is true;
- no fresh blocking runtime fault occurred;
- every declared action, time, and token budget was respected.

Oracle or setup failure is an invalid benchmark episode. Scout launch, attach,
action, observation, or recovery failure is a product failure.

### 13.3 Benchmark sets

Maintain three disjoint sets split by task template, not merely by random seed:

1. public development;
2. private validation;
3. frozen hidden release.

A mature gold-conformance suite SHOULD contain at least 60 task templates and
cover:

- standard Flutter controls and forms;
- lazy lists and large trees;
- nested and horizontal scrolling;
- tabs, split panes, expansion, and nested navigators;
- menus, sheets, dialogs, and stacked overlays;
- duplicated and truncated labels;
- moving targets, debouncing, loading, and continuous animation;
- custom painters, missing semantics, and platform views;
- keyboard, focus, validation, text scale, RTL, and localization;
- stale handles, rebuilds, hot reload, hot restart, and reconnect;
- app death, runtime faults, source mismatch, and multi-session isolation.

Each template SHOULD have at least five semantics-preserving variants covering
viewport, device pixel ratio, orientation, content order and length, initial
scroll/tab/modal/focus state, animation or network delay, and semantics/key
degradation.

Stress Lab is necessary but insufficient. Release scoring MUST include real
applications to prevent fixture overfitting.

### 13.4 Controlled comparisons

Agent evaluations SHOULD compare:

```text
screenshot and coordinate tools only
current released Flutter Scout
candidate Flutter Scout
perfect-handle ceiling, when available
```

Model snapshot, reasoning setting, system prompt, tool schema, app commit,
hardware, simulator image, task seed, and budgets MUST be fixed. Execution order
SHOULD be randomized.

### 13.5 Repetition and statistics

- Important tool-only primitives SHOULD run at least 100 repetitions per
  relevant variant.
- The release safety suite SHOULD contain at least 3,000 wrong-target and
  false-success opportunities.
- Agent task conditions SHOULD run 10 independent repetitions, increasing to
  20 for borderline results.
- Every episode MUST start from a fresh deterministic reset.
- Current and candidate versions MUST use identical task-seed pairs.
- Rates SHOULD include Wilson or exact binomial confidence intervals.
- Paired binary outcomes SHOULD use a paired comparison such as McNemar's test.
- Success, latency, calls, tokens, and bytes SHOULD include task-template-
  clustered bootstrap intervals.
- Secondary comparisons SHOULD correct for multiplicity.
- Failed runs MUST NOT be discarded after results are observed.
- Invalid harness runs MUST be reported separately with reasons.

### 13.6 Required KPIs

Primary KPIs:

1. clean hidden-oracle task success rate;
2. perturbed or robust task success rate;
3. tool calls, tokens, bytes, screenshots, and wall time per successful task.

Safety guardrails:

- false-success rate;
- wrong-target activation rate;
- forbidden-state rate;
- modal-bypass and cross-session action rate;
- secret-leak rate;
- unrelated process termination rate.

Diagnostic metrics:

- actionable-target discovery precision and recall;
- target activation accuracy;
- handle stability across rebuild, scroll, and restart;
- delta precision and recall;
- runtime-signal precision, recall, and detection latency;
- false-stable rate and stability latency;
- locate/reveal success and wrong-scroll-region rate;
- lifecycle recovery success;
- no-progress loops, retries, fallbacks, and redundant actions;
- connect, snapshot, matching, dispatch, settle, delta, logs, and serialization
  latency;
- response bytes and estimated tokens;
- idle and active CPU, memory, and frame-time overhead.

### 13.7 Failure taxonomy

Every failed episode MUST have one first-causal category and severity:

- `HARNESS_INVALID`;
- `INFRA`;
- `PERCEPTION`;
- `GROUNDING`;
- `ACTION`;
- `STATE`;
- `NAVIGATION`;
- `FORM`;
- `SIGNAL`;
- `LIFECYCLE`;
- `PROTOCOL_PERF`;
- `AGENT`;
- `SAFETY_FALSE_SUCCESS`.

`SAFETY_FALSE_SUCCESS`, secret leakage, unrelated process termination, modal
bypass, and cross-session mutation are always release-blocking.

## 14. Release gates

### 14.1 Zero-tolerance invariants

A release MUST be blocked by any reproducible instance of:

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

### 14.2 Provisional quantitative gates

The following targets are aspirational until a reference environment and
baseline are recorded. Once ratified, they MUST NOT be weakened silently.
Confidence-bound requirements apply to the lower 95% bound unless stated
otherwise.

| Area | Gold-standard target |
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

Deterministic safety fixtures require 100% correctness. Percentages are mainly
for timing-sensitive, device-sensitive, stochastic, and model-driven suites.

### 14.3 Candidate promotion

A candidate MUST preserve current-release success within a pre-registered
non-inferiority margin. Initially, the lower confidence bound of the paired
success delta SHOULD be greater than negative one percentage point.

An improvement claim SHOULD require one of:

- at least five percentage points higher robust success with an interval that
  excludes zero; or
- at least 20% lower cost per successful task while the success lower bound
  remains within the non-inferiority margin.

No performance or compactness improvement can compensate for a safety,
truthfulness, or privacy regression.

## 15. Required test architecture

The project SHOULD maintain:

- protocol contract and golden tests for every command and error envelope;
- CLI/helper `N`, `N-1`, and `N+1` compatibility tests;
- property and fuzz tests for parsing, handles, redaction, paths, process
  identity, lock races, malformed payloads, and snapshot deltas;
- widget tests for duplicates, nested navigators, modal barriers, occlusion,
  lazy lists, nested scrolling, focus, validation, animation, platform views,
  custom painters, RTL, degraded nodes, and never-settling UI;
- lifecycle fault tests that interrupt launch, attach, reload, restart, stop,
  temporary-helper cleanup, metadata writes, and daemon supervision;
- Tier-1 simulator suites for perception, actions, input, capture, lifecycle,
  errors, replay, and cleanup;
- agent benchmarks with hidden functional oracles and fixed configurations;
- performance-regression benchmarks;
- generated adversarial redaction and security corpora;
- long-running endurance and resource-leak tests.

Flakes are defects. Release-critical suites MUST preserve failing seeds and pass
repeated runs. Coverage percentage alone is not a quality gate.

## 16. Platform-support standard

Tier-1 platforms MUST pass the same behavioral contract for visibility,
occlusion, modal scoping, hit testing, text input, scrolling, error detection,
capture provenance, lifecycle, and cleanup.

iOS Simulator and Android Emulator SHOULD be Tier 1. macOS desktop MAY be Tier
1 while it remains a core development workflow. Windows, Linux, web, and
physical devices MUST be described as experimental until the same behavioral
suite passes there.

Unsupported behavior MUST return `unsupported_capability` before mutation.
Platform-specific fallbacks MUST disclose their backend, provenance, coordinate
semantics, and limitations.

No more than a small, pre-registered success-rate gap SHOULD exist between
Tier-1 platforms. A three-percentage-point gap is the initial provisional
target.

## 17. Release discipline

Blocking CI MUST use a pinned Flutter and Dart toolchain. Current stable and beta
SHOULD run as non-blocking compatibility canaries.

A release candidate MUST pass:

- formatting and fatal static analysis;
- all package and test-app tests;
- protocol and cross-version compatibility tests;
- lifecycle fault injection;
- Tier-1 simulator smoke and behavioral suites;
- redaction and local-transport security tests;
- benchmark comparison against the current release;
- endurance and performance-regression checks;
- upgrade, downgrade, and rollback exercises.

Each release MUST provide:

- immutable typed schemas;
- aligned CLI/helper/protocol changelogs;
- support and compatibility matrix;
- migration notes for behavior or schema changes;
- checksums and build provenance;
- dependency inventory or SBOM;
- signed version tag;
- documented rollback procedure.

The public package API and versioning policy SHOULD follow Semantic Versioning.

## 18. Definition of done

A feature is done only when:

1. it addresses a reproducible agent uncertainty or failure;
2. its owner layer is explicit;
3. its contract and failure modes are typed and documented;
4. focused deterministic tests cover its important behavior;
5. simulator evidence covers behavior that cannot be proven statically;
6. its benchmark delta is measured against the current release;
7. it introduces no safety, privacy, compatibility, or performance regression;
8. help, schemas, skills, and evidence output agree with the implementation.

The project reaches the gold standard when:

> On every step of a held-out complex workflow, Scout is either demonstrably
> correct or safely uncertain—never confidently wrong.

## References

- [Flutter Scout product goal](goal.md)
- [Flutter Scout architecture](ARCHITECTURE.md)
- [Flutter Scout verified behavior and current limits](README.md)
- [AndroidWorld: reproducible agent tasks with setup, success checks, and teardown](https://arxiv.org/abs/2405.14573)
- [OSWorld: execution-based evaluation in real computer environments](https://arxiv.org/abs/2404.07972)
- [WebArena: functional correctness for realistic long-horizon agent tasks](https://arxiv.org/abs/2307.13854)
- [Flutter performance profiling](https://docs.flutter.dev/perf/ui-performance)
- [OWASP Logging Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html)
- [Semantic Versioning 2.0.0](https://semver.org/)
