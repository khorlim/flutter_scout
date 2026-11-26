## Unreleased

- An agent connection that only observes or waits no longer halts with
  `agent_event_overflow` on a busy screen: unread plain view updates
  coalesce into the newest `view` event (`coalescedViews` counts the ones it
  replaced). Only more than 64 unread receipts, condition or reaction
  results halt input, and that halt has its own `blockedBy.reason:
  'connection_overflow'` with a `nextStep` and `details {unreadAlerts,
  maxEvents, renderingAffected: false}`; a rejected input names it too.
  It previously read as a generic `agent_session_stopped`, and a real agent
  waited an hour for a window that was never hidden.
- The shell bridge replaces a `connection_overflow` connection on the next
  `observe`/`status` when no input is outstanding, reporting `bridge:
  {reconnected, reason: 'connection_overflow', previousLoss}`. Every bridge
  reconnect now waits (up to 5 s) for the previous agent process to exit,
  since it holds the app's agent lease until then; a reconnect straight
  after close otherwise failed with `agent_session_busy`.
- The skill says to wait with bounded `watch` `wait:true` chunks instead of a
  tight observe loop, and to branch on `blockedBy.reason`, not `actionable`.

- `foreground()` reads the frontmost app even after rendering looks active
  and returns `ok:false` (`rendering_still_suspended`, "screen is locked")
  while `loginwindow` is in front; it no longer succeeds behind a lock
  screen whose app never went hidden. A sleeping display is named as such.
- status/doctor `hostPower.now {displayAsleep, screenLocked,
  sessionLockFlag, loginWindowFrontmost, onConsole, hiddenReason}` are live
  facts, not only settings. A set lock flag on a sleeping display is
  `screenLocked: null` unless the lock delay is immediate.
- status `headlessDrive.appVisible` and the native-capture refusal follow
  the helper's combined verdict (`rendering.status` and `rendering.host`),
  not `framesEnabled`.
- A `rendering_suspended` refusal quotes what macOS reports (display asleep,
  screen locked) instead of "probably minimized", and its next step asks
  the user to wake and unlock the Mac.
- In-app screenshots and crops print the helper's `freshness`.

- `skills/flutter-scout/scripts/scout-call` sends the shell bridge's `call`
  and `stop` from zsh without starting node: about 5 ms per call against
  35 ms for `node agent_client.mjs call` on an idle M-series Mac, and no node
  page-in on a loaded one. It marks argv typed values inside params exactly
  as node's call does, so the bridge's stdin-only checks are unchanged, and
  falls back to node without zsh or for hashed socket names. The bridge
  applies `brief` itself when asked and writes `ok` first in each reply.
- `steps {viewRevision, actions}` (client `agent.steps`) runs 1-16
  exact-handle inputs decided from one scene in one call, each with its own
  receipt and settle. Every handle must be in that scene; before each later
  step the settled scene must still show the same screen, surface and
  controls (`steps_screen_changed`, `steps_target_changed`,
  `steps_view_unsettled`), and it stops at the first failure. Nothing is
  retried, skipped or reordered.
- act skips its one-interval unchanged wait when the receipt's `lateWindow`
  proved the input idle (`settle.basis: input_idle`) and lifts a receipt's
  `paintOnlyChange` into `settle.paintOnlyChange`.
- tap and tap-text take `params.lateWaitMs` / `--late-wait-ms` (0-1000) to
  shorten the late-change window; compact receipts keep `lateWindow` and
  `paintOnlyChange`, and brief scenes keep `stateHints`.

- The helper-readiness wait after a launch is no longer a fixed 20 s. It
  starts at 20 s, or as long as the post-build phase took (up to 120 s; one
  loaded Mac needed 131 s to sync files), and continues while the VM service
  answers and the app or runner prints, changes isolate state or uses CPU,
  never past `--launch-timeout`. It stops early when Flutter's extensions are
  up without Scout's, or the owned runner exited. `ensure` reuse and `attach`
  use the same rule (8 s base), and the macOS LaunchServices wait for the
  app's VM service (120 s base) extends while the opened app is busy. stderr
  gets `await_helper_ready`, `helper_wait_extended` and
  `helper_wait_heartbeat`; a failure carries `helperWait` (`stopReason`,
  `waitedMs`, `isolateState`, `lastProgress`) and a `failureCause` naming what
  was seen, how long Scout waited and why it stopped.
- A failed launch no longer loses a reachable app. The record stays
  `helper_not_ready` (written as `starting` during the wait) while the VM
  service answers or the owned run is alive, and `status` promotes it to
  `ready` (`promotedToReady`) once the helper answers. `status`, `ensure` and
  `attach` keep the VM address of a live owned run whose VM service missed a
  check (`sessionRecordKept`, and `vmServiceAnswering: false` in status)
  instead of clearing it, and `ensure` no longer falls back to a build (which
  stopped that run) while an app answers there or its owned run is alive: it
  fails with `helper_not_ready` or `vm_service_not_answering` and
  `launch: not_attempted`. A plain `launch` refuses such a session. An
  `ensure` that joins a launch in progress now waits for its final result
  (bounded by `--launch-timeout`, was a fixed 5 minutes), not only for a VM
  address whose helper may not answer yet.
- `flutter_runner_pid_not_found` is now a final launch envelope whose
  `failureMode` names what ended the wait (idle, hard limit, runner exit).
- `doctor` reports `hostMemory`, and `doctor`, `launch` and `ensure` add a
  `low_free_memory` entry to `warnings` (plus one stderr record) below 20% free
  memory (`memory_pressure -Q` on macOS, `/proc/meminfo` on Linux), with the
  number of other live Scout-owned runs. Run one app at a time on a 16 GB
  machine. Scout only warns.
- `act` and `taps` (shipped client and bridge) keep the full settle (two
  quiet eyes samples, at least 500 ms) only when the view changed. When the
  receipt saw no change and the scene after it still has the view revision
  from before the input, they wait one eyes interval (250 ms by default)
  and, with no change, return that scene with `settle.status: unchanged`;
  a change in that interval gets the full settle. An effect slower than
  that is for `watchUntil`.
- Read-only queries (`where`, `locate`, `drag-status`) no longer wait out
  the 150 ms log-settle window meant for inputs. They dispatch nothing, so
  they report the logs already written and return; a `locate` with a run
  log took about 160 ms of logs phase before, now under 30 ms.
- `tap-text` receipts keep the helper's phase timings (snapshot, match,
  dispatch, settle, delta) and measure `logs`, as `tap` does. They used to
  replace them with `vmCallMs`/`totalMs` only, so every phase but connect
  read `helper_phase_missing_from_response`.
- The agent scene no longer cuts brief scrollables to 3 and structured rows
  to 4 after the helper bounded them; it keeps the helper's bounds (at most
  8 lists, 6 rows) and adds anything it still cuts to `omitted`.
- `inspect` accepts `maxItems` up to 500 (was 100, which made a larger
  query fail); it bounds only brief lists, and named sections are never cut.
- `act` and `taps` (shipped client and bridge) now settle after every input
  that dispatched, not only after a new screen, route or surface. The receipt
  is taken right after dispatch, so an in-place effect the app applies a
  moment later (a cart total, a Payment button becoming enabled) was missing
  from the returned scene. `settle` adds `trigger` (`screen`, `in_place`,
  `none`) and `sinceInput` (texts, controls, control state and field values
  that differ from the view before the input, at most 8 each). Same budget:
  two quiet samples, at most 3 s; nothing pumped or retried. A failed or
  rejected input returns its scene at once.
- A stale-decision rejection (`agent_view_changed`, `live_view_changed`) adds
  `details.staleChanges`: each changed field with its observed and current
  value (`rendering.lifecycle: resumed -> hidden`), and the texts or controls
  that appeared or went, instead of only "rendering changed".

- Let the same installed Scout build be stopped, relaunched outside Scout and
  re-attached any number of times. An adopted run keeps its Scout-launch
  lineage in the session record, `ensure --debug-url-file` uses the same rule,
  and responses report `runIdentityProof`. Add `--expect-run-id <id>` to
  `attach` and `ensure` to adopt a cached build's run in a later session only
  when the helper reports exactly that ID; otherwise fail with
  `expected_run_id_mismatch` and change nothing. `ensure --expect-run-id`
  never builds. An unproven helper run is still refused with `run_mismatch`.
- Fix agent sessions refusing every input after about 512 acts with
  `idempotency_registry_capacity_reached`: receipts too large to replay but
  known to have dispatched are compacted like other closed receipts, and a
  retried key answers `idempotency_outcome_not_stored` instead of running
  again. Unknown-dispatch receipts are still kept. Larger tombstone filter,
  compact registry JSON, and no request-count limit for the shipped client's
  agent connection.
- Preserve the agent lease inode during session cleanup, recognizing it as a
  serialization control rather than unknown residue. Never unlink a live lock.
- Add explicit macOS `foreground()` on the persistent agent connection. Activate
  only the connected VM's app process, then observe actual rendering; preserve
  exclusive-hand, receipt and failure guards without automatic focus stealing.
- Hard cutover to agent session protocol 2 (CLI 2.0.0-dev.2). Remove standalone
  UI observation/input/waits and live/serve/explore/batch/record/replay entrypoints;
  no legacy override or automatic server fallback. Lifecycle, annotations and
  manual evidence remain available. The serialized live-loop implementation is
  removed; v1 command/HTTP artifacts describe historical contracts.
- Require delivered input receipts to be acknowledged before another input.
  Known failures require explicit fresh reconciliation; unknown outcomes stay
  halted. Allow only one agent connection per named app.
- Add focused read-only queries and a bounded one-input client helper, retain
  intervening alerts, prevent out-of-order reads from regressing the latest
  view, and preserve query correlation around canonical response envelopes.
- Rewrite current usage guidance around the sole session contract. Do not
  require or change any model or Fast/priority service setting.

- Add `agent`: independent passive eyes and a single guarded hand, immediate
  acceptance tickets, short canonical input receipts, independent condition
  waits, explicit cancellation scope, bounded retained events and one-shot
  authorized reactions. Ship a persistent Node client and usage contract.
  Rendering is rechecked by both CLI preflight and the helper at dispatch;
  screenshots remain manual and no action is automatically retried.

- Add experimental `live` JSONL navigation with a serialized latest semantic
  view, bundled post-action observations, and stale-decision rejection. Images
  stay manual. The initial macOS agent comparison did not show a speed benefit;
  this is not a replacement default or continuous model perception.
- Observe bounded readiness before handing off a transient live action's next
  view, retaining its original outcome and separate settling evidence. Add a
  local direct-pipe Node experiment to avoid terminal write/poll latency.

- Wait for Flutter signal-handler registration within the launch idle/hard limits instead of stopping a healthy app three seconds after early VM discovery.

## Unreleased

- Recover and stop exactly recorded Flutter workers from per-run ownership
  state when top-level session metadata is missing. New launches now refuse to
  replace unresolved live-run records, and `stop --clear-session` preserves
  them unless every recorded writer is proven quiescent.
- Revalidate the exact Flutter tool after its recorded `env`/shell launcher
  execs into `dartvm`, while still requiring the same PID, parent, start time,
  process role, and run/project/device command tokens before signaling it.

- Start every Scout-owned `flutter run` with Flutter's dedicated signal PID
  file, require its handler-registration acknowledgement before declaring the
  session ready, and use that exact PID for `SIGUSR1` hot reload and `SIGUSR2`
  hot restart. This restores truthful hot-update acknowledgement for detached
  and inherited-launch-context macOS sessions.

- Preserve a temporary-helper bootstrap while its exact detached or launchd
  build worker is still alive. A follow-up `status` or `doctor` command can no
  longer mistake an interrupted launch command for an abandoned build and
  delete the Dart target while Xcode is compiling it.

- Add an opt-in leading `--single-json` prefix for finite commands: emit one
  compact final response on stdout after evidence completion, including errors,
  while retaining progress, warnings, and intermediate responses on stderr.
  Default output and persistent HTTP contracts remain unchanged.

- Allow Scout-owned hot reloads up to 60 seconds to receive the Flutter tool's
  terminal acknowledgement, preventing slow but successful reloads from being
  reported as `reload_ack_timeout` while keeping the operation bounded.

- Allow acknowledged reloads and restarts to wait for bounded slow helper
  inspection on large healthy apps instead of reporting a false timeout.

- Bound `inspect --brief` and the default `where` output in the CLI even when
  an already-running app still uses an older helper that returns full
  perception, geometry, or provenance payloads. `where --verbose` preserves
  opt-in access to the complete navigation observation. Compact observation
  commands emit one machine-JSON line instead of thousands of indentation-only
  lines.

- Bind named launch/ensure storage and launch leases to the resolved Flutter
  project instead of the command working directory. Duplicate legacy roots for
  one label now fail with their competing session/run identities instead of
  silently switching the global registry or starting another build.

- Treat Dart frontend compiler diagnostics as an immediate rejected hot-update
  acknowledgement, even when newer Flutter tools omit their former terminal
  rejection line. Rejected Scout-owned reloads now return a bounded,
  redacted `compilerDiagnostics` block instead of waiting for an
  acknowledgement timeout with no actionable compile error.

- Fixed a launch race where the runner could be rejected during the narrow
  in-place Dart-to-VM executable transition before supervisor state existed.

- Keep macOS launches waiting through the Dart launcher-to-VM executable
  transition by validating the live worker against its exact post-exec
  supervisor identity instead of prematurely reporting `runner_exited`.
- Restore compiled-snapshot local activation and remove repeated hot-path work:
  event projections are recoverable non-durable caches with process-local
  reuse, encoded secret matchers are compiled once per secret set, response
  timing/encoding no longer recursively re-sanitizes proven-safe envelopes,
  and no-op retention cleanup does not rewrite its durable registry.
- Materialize post-action captures from both compatibility and typed response
  slots, so large PNG payloads are written once to private storage instead of
  overflowing the bounded CLI evidence envelope.
- Treat URI query names as routing metadata rather than secret values, avoiding
  false substring redaction of factual response values such as `heuristic`.

- Let detached VM-log and Flutter-run workers start from launchd's root
  working directory without bootstrapping an unrelated `/.flutter_scout`
  store; internal workers now rely only on their validated absolute config
  paths.
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
