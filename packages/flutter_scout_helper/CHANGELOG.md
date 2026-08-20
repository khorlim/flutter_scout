## Unreleased

* Accept Dart VM service `isolateId` routing metadata at the strict request
  boundary, bound it independently, and exclude it from Scout mutation
  business fingerprints so real VM extension calls reach their handlers.
* Publish helper-visible stable structured-error meanings in the shared v1
  error catalog and include every one in deterministic CLI envelope goldens;
  source-emission drift is blocking, while no runtime or release-binary
  execution is implied by these contract fixtures.
* Publish per-extension typed argument contracts and enforce their exact keys,
  JSON shapes, bounds, conflicts, and mutation legality before any read handler
  or mutation dispatch.

* Identify this pre-1.0 compatibility-boundary candidate as `0.2.0-dev.1`;
  the prerelease marker does not imply release qualification.
* Identify the compiled helper package version in every typed runtime response
  so CLI operability diagnostics do not infer it from the source checkout.
* Publish bounded `delta.changedRegions` and snapshot-bound changed-region
  capture. Retained baseline/current identities, complete semantic/render
  geometry, DPR, backend, capture identity, and every count/area/pixel bound
  remain explicit; stale, ambiguous, global, oversized, platform-view, or
  capture-race cases fail closed without returning pixels. In-app rasterization
  now skips needless chrome frames when no Scout overlay exists and restores an
  opted-in overlay before the mandatory post-raster identity check.
* Bump the helper protocol to 15 with typed v1 response envelopes, negotiated
  protocol ranges, capabilities, runtime/run correlation, phase timing, and
  cursor-addressable runtime errors.
* Publish the aligned source-only `N`/`N-1`/`N+1` compatibility matrix and
  fixtures, and make every pre-handler mutation failure explicitly report
  `dispatch:not_dispatched` plus `activation.dispatched:false`. Separately
  built release artifacts and simulator runs remain required for ratification.
* Measure helper-owned action phases on one request-local exclusive monotonic
  timeline, keep application quiescence isolated in `settle`, close reads and
  failures with exact unavailable reasons, and retain all eight phase keys in
  bounded and emergency responses.
* Add monotonic state generations and SHA-256 identities over canonical,
  redacted agent-observable state. Full, brief, and action snapshots now carry
  the generation, digest, and combined snapshot identity.
* Require strict safety envelopes for every mutation, serialize all mutations,
  deduplicate concurrent and completed retries exactly once, reject stale or
  cross-runtime requests before dispatch, and give held drags exclusive
  mutation ownership.
* Canonicalize idempotency fingerprints over stable business identity (not
  retry deadlines, cursors, commands, or state preconditions), bound completed
  outcomes, and retain fail-safe tombstones so cache pressure can never turn a
  retry into a second dispatch.
* Source-redact obscured and sensitive field values across snapshots, deltas,
  recording, errors, visual/control structures, and debug responses while
  retaining only redacted presence metadata.
* Centralize handle resolution for all targeted mutations. Duplicate exact
  handles and fuzzy matches now abstain with ranked, snapshot-scoped evidence;
  dispatch requires the unique control to remain on the active surface,
  visible, enabled, and hit-tested at a safe point on a fresh snapshot.
* Report logical/physical coordinate frames, viewport, device pixel ratio, and
  immediate hit-test evidence for explicit-coordinate gesture actions.
* Include the locate snapshot's logical/physical Flutter-view coordinate frame,
  metrics provenance, and native-image matching contract so the CLI can fail
  closed instead of guessing system-bar or inset offsets for native crops.
* Add bounded semantic stability observations with closed stable, transient,
  continuous-animation, never-settling, runtime-loss, and unavailable states;
  action results retain the legacy `stable` flag plus actionable semantics,
  stopping reason, timing, samples, and generation-bound snapshot identities.
* Distinguish loss of an already observed app/root as `runtime_lost` from an
  initially unavailable observation, isolate malformed Semantics elements from
  healthy sibling evidence, and exercise capture-backend and opaque
  platform-view degradation through production paths without assigning pixel
  meaning.
* Label screen and targeting inferences explicitly, replace uncalibrated
  confidence/quality claims with named heuristic scores, and report immutable
  logical/physical view metrics, insets, keyboard evidence, orientation, and
  per-node physical geometry.
* Disclose observed CustomPaint, Texture, platform-view, image-pixel, and
  ErrorWidget perception gaps with scoped geometry, capture-backend coverage,
  pixel-evidence recommendations, and locally isolated degradation. Compact
  inspect output retains these limitations instead of implying full coverage.
* Report scroll regions as nested, uniquely scoped observations with logical
  and physical bounds, axis/direction, live Flutter ScrollPosition metrics,
  viewport/extents, derived normalized position, endpoint facts, and explicit
  availability/provenance in inspect and bounded-navigation responses.
* Persist helper-side recordings only when private storage can be guaranteed:
  source-placeholder all input/fill values, enforce owner-only permissions,
  reject unsafe paths and links, use atomic writes and a blocking index lock,
  bound recovery scans, and otherwise delegate the redacted flow to the CLI.
* Make observation non-interfering by construction: inspect, where, locate,
  snapshot-relative inspect, wait, drag-status, annotation reads, and recorder
  reads never schedule or manually advance frames. Only explicitly labelled
  post-mutation settling may advance disabled frames. Annotation/recording
  overlay chrome is absent at attach, installed only after explicit UI opt-in,
  and removed when both modes are inactive.
* Promote a currently visible Flutter `ErrorWidget` to a deduplicated active
  blocking signal with widget-tree provenance. The signal remains active until
  the surface disappears, while rendered diagnostic text is omitted and
  source-redacted from snapshots and protocol responses.
* Reject every unknown VM-service parameter before read or mutation dispatch
  against a published per-method allowlist. Enforce finite request count, name,
  identifier, total, and per-value byte limits plus the exact safe-ASCII
  idempotency-key contract before any handler or mutation cache. Bound every
  encoded helper response to 4 MiB and fail closed on oversized, deep, cyclic,
  or otherwise unsafe payloads while retaining compact identity, dispatch,
  cursor, truthful active-versus-blocking runtime health, hard-signal, and
  phase-timing evidence.
* Add bounded, seeded property campaigns for Unicode and duplicate selector
  abstention, ambiguity ranking, geometry isolation, canonical state identity,
  and protocol request/response limits, with exact seed/case replay documented
  in `FUZZING.md`.

## 0.0.1

* Initial helper package skeleton.
