## Unreleased

- Identify this incompatible protocol-15 candidate as `2.0.0-dev.1`; it is a
  prerelease marker only and does not imply release qualification.
- Publish independent machine-readable catalogs for all public CLI commands
  and 331 stable structured-error meanings, distinguish prose-only help and
  non-error diagnostics, and golden-test one bounded canonical envelope per
  machine command/error against the production dispatcher, persistent method
  allowlist, and source emission sites. This is deterministic source-contract
  coverage, not app, simulator, device, or release-binary execution evidence.
- Validate authenticated persistent calls against one per-method typed runtime
  contract before handler entry, and publish the same argument, parameter,
  bounds, conflict, secrecy, and side-effect descriptors through `/v1/schema`.
- Replace the unbounded rewrite-on-update event file with a lossless bounded
  segmented operation journal and a separately verified 256-row projection.
  Runtime log reads now accept only the exact Scout-owned run log, return
  complete-record byte cursors, bound records and windows, and fail closed on
  corruption, replacement, truncation, or metadata path escape.
- Give `status`, `doctor`, `health`, and persistent `GET /health` one bounded
  truthful operability contract covering observed binary/helper/protocol,
  session/runtime/source/device/ownership identities, artifact paths, active
  drag/recording state, persisted hot-update freshness, and one prioritized
  recovery action. Authenticated persistent health now separates daemon
  readiness from app reachability.
- Add `crop --changed-since <snapshot-id>`: one helper-side retained-baseline
  observation/capture contract with complete semantic changed regions,
  baseline/current/verification identities, logical/physical/DPR/backend
  provenance, strict region/union/padding/output bounds, corrupt-response
  rejection, and typed abstention instead of native or coordinate guessing.
- Adopt schema-1/protocol-15 typed envelopes with bidirectional range and
  capability preflight, correlated command/run/runtime/state identities,
  idempotent mutation reconciliation, and independent closed outcome fields.
- Publish a machine-readable, source-only protocol compatibility matrix and
  deterministic `N`/`N-1`/`N+1` fixtures. Require every typed helper response
  slot and mutation capability before dispatch while tolerating unknown
  optional schema-1 response fields; release-binary interoperability remains
  unratified until separately built artifacts are retained and exercised.
- Close every machine response, compact action result, JSONL action event, and
  durable mutation outcome with canonical `connect`/`snapshot`/`match`/
  `dispatch`/`settle`/`delta`/`logs`/`serialize` records. Measure CLI-owned
  boundaries separately, preserve helper preflight and replay timings, and
  report action overhead without app-settling time.
- Add caller-supplied keys for normal CLI and authenticated persistent calls,
  plus pre-dispatch owner-only durable receipts, cross-process outcome replay,
  deterministic batch/replay step keys, conflict abstention, bounded outcome
  tombstones, deterministic composite-action children, durable local
  reload/restart/deeplink receipts, and fail-closed runtime-replacement
  recovery without raw request persistence.
- Fail closed before mutation for incompatible, stale, cross-runtime, expired,
  ambiguous, hidden, disabled, occluded, or otherwise unsafe targets; never
  repeat a coordinate fallback after an uncertain dispatch.
- Redact secrets at source and at every CLI sink, persist input values only as
  explicit variable placeholders, and preflight replay/batch variables before
  the first mutation. Add bounded `fill`/`input` protected file and standard
  input, plus owner-only `--var-file`/`--var-stdin` ingress for replay, record
  run, and batch; legacy argv sources now emit an explicit deprecation warning.
- Protect Flutter compile-time values with bounded, strict-UTF-8, owner-only
  `--dart-define-from-file` ingress that is validated before state creation and
  revalidated in the detached worker. Persist and forward only the path, reject
  secret-looking inline defines, and warn on legacy nonsecret inline defines.
- Constrain every explicit, discovered, and saved VM-service capability URL to
  a validated explicit loopback endpoint before connection or persistence.
  Add bounded owner-only `attach --debug-url-file`/`--debug-url-stdin` ingress,
  endpoint-only output and metadata, legacy-source warnings, and adversarial
  no-egress/no-credential-leak checks.
- Treat deep-link URLs as credentials with protected bounded
  `deeplink --url-file`/`--url-stdin` ingress, legacy positional warnings, and
  placeholder-only journals and durable receipts.
- Harden session and supervisor ownership with exact Scout-owned Flutter process
  identities, attach-only protection, and identity-checked recovery.
- Serialize launches with a stable owner-only kernel lease and separate atomic
  diagnostic metadata, preventing duplicate launches after partial metadata
  writes while allowing automatic recovery when the owner process crashes.
- Make session metadata, registries, logs, recordings, crops, and evidence
  owner-only, atomic, symlink-safe, retention-labelled, and concurrency-safe.
  Add an integrity-checked exact-path retention registry, automatic `24h`/`7d`
  expiry, exact `stop --clear-session` cleanup, manual preservation, bounded
  directory manifests, caller-parent permission preservation, and typed
  fail-closed handling for replacements, links, corruption, and residue. Record
  exports now accept the same explicit `--retention` policies.
- Authenticate the loopback persistent transport with rotated owner-only bearer
  credentials, typed allowlists, bounded requests, deadlines, and an opt-in-only
  legacy endpoint.
- Add immutable protocol schemas, deterministic evaluation contracts, a
  fail-closed compatibility/release policy, and offline release provenance,
  checksum, release-schema/alignment, incomplete-composition SBOM,
  unsigned-signing, and unexercised-rollback evidence contracts with semantic
  tamper verification.
- Preserve separate helper/CLI recording-persistence provenance and make the
  private CLI store canonical, with explicit failure when its atomic commit is
  unavailable.
- Preserve typed semantic stability in full, compact, and durable action
  evidence; map transport loss to `runtime_lost` and retain unknown/non-stable
  observations instead of collapsing them into the legacy boolean.
- Make temporary-helper setup a private, integrity-checked write-ahead
  transaction: tracked inputs restore by verified digest after success,
  failure, or interruption; startup resumes idempotent cleanup and preserves
  user-diverged files with a typed prioritized repair action.
- Make evidence bundles self-describing with explicit tool/protocol/runtime,
  source, toolchain, platform, timing, privacy, and missing-evidence facts.
  Owned launches persist the exact app commit, hashed dirty-worktree status,
  and Flutter/Dart/engine identities without persisting changed file names.
- Suppress Flutter analytics on every Scout-spawned Flutter tool process and
  create the macOS window probe only inside a randomized owner-only temporary
  directory that is removed after use.
- Treat currently visible Flutter `ErrorWidget` surfaces as deduplicated active
  blocking runtime signals, so they continue to fail asserted actions even
  after the original error cursor has aged or been consumed.
- Add fail-closed Android Emulator native operations from exact recorded device
  metadata: bounded local-argv ADB deep links with explicit remote-shell URL
  quoting and Activity Manager acknowledgement, bounded fully decoded PNG
  screenshot capture, atomic owner-only artifacts, TERM-to-KILL native-process
  containment, backend/provenance/coordinate disclosures, and exact
  physical-viewport validation before native crop materialization. This is
  implemented source capability, not Tier-1 simulator ratification.

## 1.2.0

- Add redacted JSONL command/action evidence with real timing facts.
- Fail actions on fresh blocking errors by default and add log expectations.
- Harden named-session listener cleanup and stale registry handling.
- Automatically enable expiring persistent transport for exploratory loops.
- Verify changed Dart source against the VM after hot updates.
- Add contextual field/row handles and retroactive `record save-last`.

## 1.0.0

- Initial version.
