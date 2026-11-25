# Flutter Scout protocol changelog

## Unreleased

- Add stable error `expected_run_id_mismatch`: `attach`/`ensure --expect-run-id` was
  given, but the app's helper reported a different Scout run ID or none.
  Nothing was attached or persisted. `attach` and `ensure` responses add
  `runIdentityProof` (`session_record` or `expected_run_id`) beside
  `runIdentityRecovered`. Helper wire protocol is unchanged.
- Long sessions no longer stop accepting input after about 512 acts with
  `idempotency_registry_capacity_reached`. A receipt whose outcome is too
  large to store but whose dispatch is known now has the CLI receipt phase
  `committed_nonreplayable` (it was `outcome_unknown`) and is compacted
  oldest first into the tombstone filter like any closed receipt. A
  same-key retry is never sent again: while the receipt is kept it fails with
  the new stable error `idempotency_outcome_not_stored` (`dispatch` is the
  original one), and after compaction with `idempotency_outcome_pruned`.
  Receipts whose dispatch is unknown are still never evicted, and receipts
  written by older CLIs are read the same way. The capacity error, now only
  reachable when every receipt is unresolved, names the next step. The CLI and
  helper tombstone filters grow from 2^16 to 2^20 bits (an existing CLI filter
  is upscaled without losing a key), so fresh keys are not refused by filter
  collisions in long sessions. The CLI registry is written as compact JSON.
- Agent JSONL: request ids of the form `q<n>` (the shipped client's) must
  increase and have no per-connection count limit; other ids stay limited to
  10,000 unique ids per connection. The client no longer stops at 10,000
  requests.

- Add stable error `swipe_no_effect`: a swipe was dispatched but nothing on
  screen moved. It is a known dispatched outcome (observe, then reconcile).
  Scroll keeps `ok` with `result: unchanged` at the end of its content.

- Add optional helper `headlessDrive` request metadata and the
  `headlessDriveV1` capability. A session opted in with `--headless-drive`
  sends it on agent reads, mutations and captures; while Flutter has stopped
  frames because the app is not visible, the helper advances bounded frames
  itself, reports rendering status `driven` with a `headlessDrive` block
  (reason, loop state, App Nap) and lets `requireLiveRendering` pass. Without
  it, suspended rendering is reported and refused exactly as before.

- Add optional helper `freshTargets` mutation metadata and the
  `targetFreshnessV1` capability: an exact-target mutation survives a state
  generation change after preflight only when its target nodes, surface and
  field values are unchanged (`targetFreshness` in the response). Overlays and
  `activeSurface` carry an `instance` number per mounted dialog/sheet.

- Hard-cutover public CLI contract v2 lives under schemas/v2/. Agent JSONL
  protocol 2 adds query, acknowledge and reconcile, with exclusive ownership,
  receipt delivery gating and no legacy interaction entrypoints. Helper wire
  protocol 15/schema 1 is unchanged; old CLI/HTTP artifacts are historical.

- Add CLI `agent` JSONL session protocol 1, independent from persistent-call
  protocol 2, with bounded action tickets, observations, waits and reactions.
- Add optional helper `requireLiveRendering` mutation metadata, enforced
  immediately before dispatch when true, and optional inspect rendering facts.
  New capabilities are `renderingStateV1` and `liveRenderingGuardV1`. Existing
  protocol-15 calls remain compatible; agent actions require the new guard.

- Register the experimental CLI-only `live` semantic-view action loop and its
  fail-closed view/request errors. Screenshots remain manual; no helper wire
  field or protocol capability changed.
- Define the immutable schema-1 document set under `protocol/schemas/v1/` and
  bind every document to a deterministic release schema manifest.
- Coordinate protocol 15 across the CLI and helper, including typed envelopes,
  mutation identity, runtime and state preconditions, deduplication, hard-signal
  cursors, phase timings, source redaction, and capability negotiation.
- Publish the source-only protocol-15 compatibility matrix and explicit
  protocol-14/protocol-16 fail-closed pairings. Separately built artifacts and
  simulator exercises remain required before release ratification.
- Treat additions within schema 1 as optional-only. Missing required fields,
  unknown mutation fields, changed closed error semantics, or incompatible
  protocol ranges require pre-dispatch rejection; incompatible schema changes
  require a new versioned schema directory.
- Register stable `insecure_dart_define_secret` and
  `invalid_dart_define_source` semantics for fail-closed CLI compile-time-value
  ingress; no helper wire field or protocol capability changed.
- Publish per-method CLI and helper request descriptors and validate the same
  exact type, size, conflict, and side-effect contracts before dispatch.
- Register bounded runtime-log corruption/change/record-size failures and
  lossless event-journal capacity failure as stable machine errors.

This section is aligned with the CLI and helper `Unreleased` sections. It is a
source-change record, not a release date, signed tag, or compatibility claim.
