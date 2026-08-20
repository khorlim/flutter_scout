# Flutter Scout protocol contracts

This directory is the immutable, machine-readable contract for Scout protocol
schema version 1 and helper protocol version 15. A published schema directory
is never edited incompatibly; breaking changes require a new schema directory.

The VM service method name is transported out of band by `vm_service`. The
request schemas represent that call as `{method, params}` so validators and
test harnesses can validate one complete document.

Files:

- `compatibility-matrix.v1.json` — source-contract-only `N`, `N-1`, and `N+1`
  pairing expectations, stable incompatibility errors, executable proof
  locations, and explicit release-evidence exclusions;
- `mutation-request.schema.json` — mandatory envelope for every helper mutation;
- `response.schema.json` — common helper response envelope;
- `cli-response.schema.json` — additive response envelope for local and
  helper-backed CLI commands, with explicit unavailable identities and bounded
  serialization;
- `cli-heartbeat.schema.json` — correlated progress records for every command
  that remains active beyond the heartbeat interval;
- `cli-event.schema.json` — deterministic event cursors plus explicit command,
  run, runtime, state, and log-cursor correlation;
- `mutation-outcome.schema.json` — CLI mutation response with independent,
  closed transport, dispatch, observation, postcondition, and runtime-health
  dimensions;
- `persistent-call.schema.json` — authenticated `/v1/call` request;
- `persistent-methods.json` — exact public method-to-parameter allowlist.
- `helper-methods.json` — exact VM-service method-to-parameter allowlist,
  structural bounds, and the two protocol-15 migration aliases.
- `public-cli-commands.json` — exact public CLI command catalog, machine/prose
  surface classification, operation class, persistent-method membership, and
  explicit current-source-only evidence scope.
- `stable-errors.json` — exhaustive stable structured-error codes and normative
  meanings, finite dynamic-code families, and separately classified warning,
  quality, limitation, and workflow-hint codes.
- `navigation-response.schema.json` — bounded `where`, `locate`, `reveal`, and
  snapshot-relative delta facts (including bounded `changedRegions`) and
  stopping evidence.

`ext.flutter_scout.capture` accepts `mode=changed-region` plus `since=<snapshot
identity>`. A successful response is typed by `response.schema.json` and binds
the retained baseline, current observation, and post-raster verification scope
to complete semantic/render regions, logical/physical union geometry, DPR,
backend, capture identity, and explicit count/padding/area/output bounds. The
read fails closed when any identity, history, geometry, coordinate frame, or
atomic in-app capture fact is unavailable; native fallback is not claimed.

Action and wait responses retain the legacy `stable` boolean and add a typed
`stability` observation. Its closed states distinguish semantic quiescence,
transient activity, actionable continuous animation, never-settling semantics,
runtime loss, and unavailable observation. Each observation is bounded and
includes its stopping reason, phase duration, semantic snapshot identities,
scheduler samples, actionability, and perception limitations.

Unknown optional response fields are allowed for additive evolution. Unknown
request fields and persistent method parameters are rejected by the runtime.
Protocol compatibility is negotiated from explicit minimum/maximum versions
and capabilities before any mutation.

Every helper service-extension request accepts only the common protocol
envelope plus the method-specific parameters in `helper-methods.json`.
`errorsSinceCursor` remains an alias for `errorCursor`, and `tapText.target`
remains an alias for `tapText.text`, only for the documented protocol-15
migration window. No other legacy or free-form parameter is accepted.

Direct helper requests are bounded before any handler or mutation registry is
entered: at most 64 parameters and 1 MiB of combined parameter UTF-8 data,
with 128-byte names and a 64 KiB default value limit. Only `records`, `value`,
and `values` use the documented 512 KiB bulk-value limit. Command, run, and
runtime identifiers are capped at 256, 128, and 128 UTF-8 bytes respectively.
Idempotency keys use the same exact CLI contract: 1-128 ASCII letters, digits,
`.`, `_`, `:`, or `-`, starting with a letter or digit. Invalid or oversized
mutations fail with `activation.dispatched:false`; raw idempotency keys are
never retained in response evidence.

CLI response envelopes retain all legacy fields at the top level. The typed
`result`, nullable `structuredError`, identity availability, and timings fields
are additive. Output is bounded to 4 MiB after source redaction; an oversized
payload fails closed with `response_payload_too_large` rather than emitting a
partial or unparseable JSON record. Any earlier collection, string, or depth
truncation also fails closed with `truncated_safety_evidence`, because omitted
data might contain a blocking error or uncertain-dispatch fact. Contract and
identity fields are reserved ahead of legacy fields and cannot be compacted
away.

Every helper and CLI machine envelope carries exactly eight records under
`timings.phases`: `connect`, `snapshot`, `match`, `dispatch`, `settle`, `delta`,
`logs`, and `serialize`. Each record is either a non-negative integer
measurement or `elapsedMs: null` with an unavailable reason. See
[`docs/production-phase-timings.md`](../docs/production-phase-timings.md) for
the ownership and aggregation rules.

The same 4 MiB encoded bound applies to direct helper VM-service responses.
Oversized or structurally unsafe helper results are replaced, without recursive
encoding, by a minimal typed failure that retains request/runtime identity,
dispatch uncertainty, error cursor, compact fresh/active hard-signal facts,
runtime health, and closed phase-timing availability. The oversized business
result is never emitted partially.

`help`, `--help`, `-h`, and invocation with no command are explicitly
human-rendered prose surfaces. They are not machine-response records. Unknown
commands return one typed error on stderr without a second usage stream.

[`public-contract-envelopes.v1.json`](../packages/flutter_scout/test/goldens/public-contract-envelopes.v1.json)
materializes one deterministic bounded canonical envelope for every machine
command and every stable error meaning. The `help` row is deliberately present
with a null envelope and its prose-only reason. Contract tests compare the
independent catalogs with the production command dispatcher, authenticated
persistent-method catalog, and source emission sites; an added, removed, or
reclassified command/code fails until the independent artifact and goldens are
reviewed together. These are source-envelope proofs only: they do not claim the
commands or errors were exercised on an app, simulator, device, or release
binary. Schema-v1 unknown optional response fields remain accepted, while every
missing required response field is rejected by the production compatibility
gate.
