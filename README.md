# Flutter Scout

Flutter Scout is an agent-oriented **eyes-and-hands bridge** for Flutter simulator apps. An AI agent inspects the running app, drives real feature flows, reads exactly what changed after each action, and catches hard runtime errors — with no per-screen test scaffolding in the app.

```text
named ensure → where/inspect → locate/reveal → guarded act once
             → inspect --since + signals → crop/evidence → replay → exact stop
```

## Documentation map

Start here based on what you need:

| Goal | Read |
| --- | --- |
| Use Scout to verify a Flutter app (agent loop + command reference) | [`skills/flutter-scout/SKILL.md`](skills/flutter-scout/SKILL.md) |
| Install and wire Scout into an app | [`skills/flutter-scout-setup/SKILL.md`](skills/flutter-scout-setup/SKILL.md) |
| Modify Scout's own code (file map, request flow, conventions) | [`ARCHITECTURE.md`](ARCHITECTURE.md) |
| Understand the product goals and design rationale | [`goal.md`](goal.md) |
| Review the normative quality, safety, evaluation, and release contract | [`QUALITY_STANDARD.md`](QUALITY_STANDARD.md) |
| Understand the supported security boundary and private-artifact handling | [`SECURITY.md`](SECURITY.md) |
| Check CLI/helper/protocol/toolchain/platform compatibility and migrations | [`COMPATIBILITY.md`](COMPATIBILITY.md) |
| Prepare a fail-closed release and see every current blocker | [`RELEASING.md`](RELEASING.md) |
| Build independent-oracle benchmark catalogs and episode reports | [`evaluation/README.md`](evaluation/README.md) |
| Interpret the eight production timing phases and their measurement limits | [`docs/production-phase-timings.md`](docs/production-phase-timings.md) |
| Audit phase applicability for every public operation | [`docs/production-phase-timing-inventory.md`](docs/production-phase-timing-inventory.md) |

`SKILL.md` is the source of truth for agent-facing command behavior; the sections below are a human-readable overview.

## Capabilities

- **Sessions & lifecycle** — isolated named sessions and run logs, launch locking/joining, explicit replacement, crash-repairable zero-diff temporary helper injection, exact device resolution, `doctor`/`status`/`stop`, and launch timing metrics.
- **Perception** — compact `inspect` snapshots with generation-bound SHA-256 identities, unique scoped handles, top-modal scoping, split text visibility (`visibleText`/`hitTestableText`/`offscreenText`), logical/physical viewport facts, explicit visual blind spots/degradation, nested scroll metrics, and duplicate abstention.
- **Navigation** — read-only `where` and ranked `locate`, bounded exactly-once `reveal` with explicit scroll-region scope/restoration, and `inspect --since <snapshot-id>` relative observations.
- **Acting** — tap, tap-text, long-press, protected input/fill, coordinate-aware scroll/swipe, scroll-to, back; unique revalidation immediately before one dispatch, same-call expectations/capture, and closed before/after outcomes (`--verbose` for full payloads).
- **Hot update** — reload/restart with capability hints and reload diagnostics that separate rejected VM reloads from apps still running old code.
- **Visual & log evidence** — in-app and native screenshots/crops, attach-aware log capture, and shareable `evidence` / `evidence --audit` bundles.
- **Runtime signals** — cursor-scoped Flutter/platform/log/transport error capture with source provenance, run/runtime/state/action correlation, severity, blocking status, phase, age, staleness, and explicit non-causal attribution.
- **Safety protocol** — typed schema-1/protocol-15 envelopes, capability negotiation, state/runtime/run preconditions, serialized idempotent mutations, bounded deadlines, unknown-dispatch reconciliation, and durable evidence before success output.
- **Privacy/storage** — earliest-source redaction, protected stdin/`0600` file ingress, encoded-secret/control-character sanitization, private atomic artifacts with retention labels, and authenticated loopback transport.
- **Annotation handoff** — an in-app overlay where a human flags widgets and comments, then hands off to the agent (see [Annotation Mode](#annotation-mode)).
- **Replay** — record sessions and replay flows after a fix, with a concise transcript.

Two initializers cover integration: a main-only helper for fresh apps, and a registration call for apps that already create a custom debug binding (see [App Integration](#app-integration)). A sample app for simulator verification lives in `apps/scout_test_app`.

## Packages

```text
packages/flutter_scout_helper   Flutter helper package
packages/flutter_scout          CLI package
apps/scout_test_app             Verification app
evaluation                      Independent benchmark contracts and statistics
skills/flutter-scout            Codex skill for agents using Flutter Scout
skills/flutter-scout-setup      Codex skill for installing Flutter Scout
skills/ship-sync                Project skill for fix/test/docs/push/local refresh workflow
goal.md                         Product goals
```

## App Integration

```dart
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MyApp());
}
```

If another debug binding is already initialized, keep it and register Scout after it:

```dart
void main() {
  ExistingDebugBinding.ensureInitialized();
  FlutterScoutHelper.ensureRegistered();
  runApp(const MyApp());
}
```

No per-screen or per-widget wrappers are required.
Both initializers are true no-ops in normal profile and release builds. Scout
sessions intentionally require a debug build.

## Verified Simulator Flow

Prefer named `ensure` for day-to-day agent verification. It reuses a ready Scout-owned session for that name when possible and launches only when needed:

```bash
cd packages/flutter_scout
dart run bin/flutter_scout.dart ensure --device <simulator-id> --project ../../apps/scout_test_app --name smoke-test
```

Each name owns a separate runtime directory and every launch owns a unique run
log. Concurrent `ensure` calls for the same name join the active build instead
of starting a second `flutter run`. A direct second `launch` fails clearly; use
`launch --replace` only when replacing the ready run is intentional.
On macOS, Scout places its Flutter worker under a per-run `launchd` agent, so
closing the launching terminal or losing the agent process does not normally
remove hot reload/restart ownership. The supervisor restarts only an abnormally
lost worker; a normal Flutter-tool exit is recorded and is not relaunched. A
replacement worker adopts a still-running Flutter process instead of starting
a duplicate. `status` exposes `supervisor`, `supervisorState`, and
`lastRunnerExit` diagnostics.
`status`, `doctor`, `health`, and persistent `GET /health` also share a bounded
truthful [operability contract](docs/operability-contract.md): unobserved
helper/runtime/source facts remain explicitly unavailable, and daemon readiness
is separate from app reachability.
From the app project, session commands automatically reuse the sole current
named session when no default session exists. When several named sessions are
available, Scout refuses to guess and asks for `--app <name>`.
Named `launch` and `ensure` sessions are rooted at the resolved `--project`
directory, independent of the caller's working directory. If legacy data makes
one label point at multiple session roots, Scout lists the competing roots and
run IDs and refuses to select or launch until the obsolete session is cleared.

Use `launch` when you explicitly need Scout to start a fresh Flutter run:

```bash
dart run bin/flutter_scout.dart launch --device <simulator-id> --project ../../apps/scout_test_app --name smoke-test
```

For a project that is not permanently integrated yet, Scout can prepare a
generated bootstrap and helper dependency without leaving changes in
`pubspec.yaml` or `pubspec.lock`:

```bash
dart run bin/flutter_scout.dart ensure --temporary-helper --device <simulator-id> --project <flutter-app-path> --name smoke-test
```

Scout writes an owner-only, integrity-checked repair transaction before the
first tracked-file change, restores `pubspec.yaml` and `pubspec.lock`
immediately, and removes the generated bootstrap when the session stops. A
later command safely resumes interrupted cleanup. If a tracked file changed
outside Scout, recovery fails closed, preserves that user version, and reports
the prioritized repair record through `status`/`doctor`; it never guesses which
content to overwrite. Use `--helper-path <path>` when local discovery cannot
find `flutter_scout_helper`.

Use `attach` only when you intentionally need to preserve or inspect a human-started app state:

```bash
# Store the capability URL in an owner-only 0600 file first.
dart run bin/flutter_scout.dart attach --device <simulator-id> --debug-url-file /private/path/vm-service-url
```

Pass `--name <label>` on every `launch` or `ensure` to distinguish concurrent sessions — e.g. one debug window per worktree on macOS/desktop. Scout injects it as a `--dart-define`; every Scout-owned launch shows that label in a passive, pointer-transparent bottom-left badge. Without `--name`, the badge reads `SCOUT`. Human-started apps reached through attach do not gain a badge:

```bash
dart run bin/flutter_scout.dart launch --device macos --project ../../apps/scout_test_app --name feature-a
```

Successful launch and attach responses include `ready`. If the VM service is available but the helper extension is missing, the command returns `ready:false` with `reason:"helper_extension_missing"` and the expected initializer.

Or attach to an already running app:

```bash
dart run bin/flutter_scout.dart attach --device <simulator-id> --debug-url-file /private/path/vm-service-url
```

Check setup and the current session:

```bash
dart run bin/flutter_scout.dart doctor --project ../../apps/scout_test_app --device <simulator-id>
dart run bin/flutter_scout.dart status
```

For local package development, activate the CLI from this checkout. The
installer compiles the CLI and replaces Pub's path-activation wrapper, so each
subsequent `flutter-scout` invocation keeps stdout reserved for its JSON
response (and does not re-resolve dependencies):

```bash
tool/install-local-shim.sh
```

Drive the sample flow:

```bash
dart run bin/flutter_scout.dart where
dart run bin/flutter_scout.dart inspect
dart run bin/flutter_scout.dart inspect --surface
dart run bin/flutter_scout.dart locate btn.add_supplier
dart run bin/flutter_scout.dart tap btn.add_supplier
dart run bin/flutter_scout.dart tap btn.add_supplier --expect-text "Supplier name" --capture /tmp/add-supplier.png
# Prepare /private/tmp/scout-fill.json as an owner-only 0600 JSON file.
dart run bin/flutter_scout.dart fill --file /private/tmp/scout-fill.json
dart run bin/flutter_scout.dart tap btn.save_supplier
dart run bin/flutter_scout.dart bounds btn.add_supplier
dart run bin/flutter_scout.dart screenshot -o /tmp/flutter_scout_test.png
dart run bin/flutter_scout.dart crop btn.add_supplier -o /tmp/flutter_scout_add_button_crop.png
dart run bin/flutter_scout.dart crop --text "-Hair Dye - Plum" -o /tmp/flutter_scout_label_crop.png
# Reuse a previously retained inspect snapshot to capture only a bounded,
# snapshot-bound semantic changed-region union.
dart run bin/flutter_scout.dart crop --changed-since 'g7:<64-hex-digest>' -o /tmp/flutter_scout_changed.png
dart run bin/flutter_scout.dart evidence -o /private/path/flutter_scout_evidence --retention session
dart run bin/flutter_scout.dart evidence --audit -o /private/path/flutter_scout_evidence --retention session
dart run bin/flutter_scout.dart replay .flutter_scout/session.json
```

Sensitive values belong in protected input, never process arguments. `input`
and `fill` accept bounded `--file`/`--stdin` sources; `replay`, `record run`,
and `batch` accept `--var-file`/`--var-stdin` JSON string objects. On POSIX,
caller-owned files must already be exactly `0600`. Legacy positional input,
`fill --json`, and `--var name=value` remain compatible but emit a structured
insecure-source deprecation warning. See [SECURITY.md](SECURITY.md).

For Flutter compile-time values, `launch` and `ensure` accept
`--dart-define-from-file <path>`. Scout validates a bounded, strict-UTF-8,
regular non-symlink file with exact `0600` POSIX permissions before creating
session state, then the detached worker revalidates it immediately before
starting Flutter. Scout's worker configuration and direct Flutter-tool argv
contain only the absolute file path, not the file contents; Flutter reads the
caller-owned file through its native define-file interface, so keep it private
and stable until that read completes. Flutter may materialize compile-time
values in its own downstream tool processes or the built app. Dart defines are
therefore not a secure application secret store, and Scout does not claim to
protect copies outside its direct process and persistence boundary.
Inline `--dart-define` remains temporarily compatible for nonsecret values and
emits a structured warning. A secret-looking inline name or value is rejected
before Scout writes session state or starts a child process.

VM-service capability URLs use `attach --debug-url-file` or
`--debug-url-stdin`; deep-link URLs use `deeplink --url-file` or `--url-stdin`.
Scout accepts VM transport only to explicit loopback ws/wss/http/https
endpoints with a valid port. Raw VM/deep-link credentials are redacted from
responses, event/session journals, and encoded variants.

After Dart-only code changes, avoid a full rebuild:

```bash
dart run bin/flutter_scout.dart reload
dart run bin/flutter_scout.dart restart
```

`reload` preserves app state. `restart` resets Dart state without reinstalling, and requires a Scout-owned `launch`/`ensure` process so Scout can signal the Flutter tool. Both commands wait for an explicit Flutter-tool acknowledgement; reload allows up to 60 seconds so a slow but successful Flutter reassembly does not produce a false timeout. Dart frontend diagnostics also close the outcome as rejected when Flutter omits a terminal rejection line, with bounded details under `acknowledgement.compilerDiagnostics`. Restart additionally requires a newly registered helper runtime, so an inspectable old isolate can no longer produce a false early success. Native, plugin, asset, or `pubspec.yaml` changes can still require a full relaunch/rebuild.

Drive the smoke-regression screen when changing form, text, row, or scroll behavior:

```bash
dart run bin/flutter_scout.dart tap btn.smoke_issues
# Prepare /private/tmp/scout-smoke-fill.json as an owner-only 0600 JSON file.
dart run bin/flutter_scout.dart fill --file /private/tmp/scout-smoke-fill.json
dart run bin/flutter_scout.dart tap btn.select_staff
dart run bin/flutter_scout.dart tap-text GoodJob
dart run bin/flutter_scout.dart tap-text --text "-Hair Dye - Plum"
dart run bin/flutter_scout.dart scroll down --from 220,760 --distance 520
dart run bin/flutter_scout.dart drag-start --target tap.dismiss_task_1
dart run bin/flutter_scout.dart drag-move --by=-80,0 --screenshot /tmp/drag-midpoint.png
dart run bin/flutter_scout.dart drag-move --by=30,0
dart run bin/flutter_scout.dart drag-end
```

Machine-readable commands return an additive typed/versioned envelope with
command/run/runtime/state identity, result vs structured error, capabilities,
phase timings, and explicit unknowns. Action output separately closes dispatch,
observation, postcondition, stability, runtime health, and evidence persistence.
Identical final state is represented as `sameSnapshot:true` instead of repeated
summaries. An async operation that visibly works and settles back to its
starting state returns `completed_same_state` with `activityObserved:true`.
Guard `tap`, `tap-text`, `input`, and `fill` with `--expect-*`, `--expect-log`,
or `--reject-log`; add `--capture <path>` to save the exact expectation frame.
Fresh blocking errors fail actions by default. If dispatch is unknown or durable
evidence cannot be committed after a possible mutation, inspect/reconcile state
instead of retrying with a new identity. Add `--verbose` only when full
before/after payloads are needed.

For a mutation that may be retried by an orchestrator, supply one stable global
key (it may appear before or after the command):

```bash
flutter-scout --idempotency-key save-order-42 tap btn.save
```

Scout atomically reserves the key before dispatch without persisting raw action
parameters. Reusing it with the same business request reconciles or replays the
original outcome across CLI processes; reusing it for a different request
abstains. Generated keys remain the default for one-shot commands. Batch,
replay, and composite fallback actions derive deterministic per-step keys from
their scope key. Local reload, restart, and deeplink mutations are also
reserved before dispatch and replay completed receipts; an uncertain local
receipt returns `dispatch_outcome_unknown` without redispatch.

Scout-owned `launch` and `ensure` responses include a `timing` object when they start Flutter, for example `totalMs`, `buildDurationMs`, `firstSyncMs`, `vmServiceFoundMs`, and `readyMs`. During long builds they emit a compact `launch_heartbeat` every 15 seconds with elapsed time and the latest sanitized build line.

`inspect` includes a generation-bound `snapshotId`, `fieldsById`, text targets,
geometry, overlays, visual tree, control groups, perception limitations, and
scroll-region facts. `inspect --brief` is a bounded operational digest scoped
to the active top modal/picker/dialog/sheet. Use `--max-items <1-100>`, request
specific `--sections`, and use `inspect --since <snapshot-id>` for a bounded
relative observation. `where` exposes navigation/surface/scroll orientation;
`locate` ranks without mutation; `reveal` is bounded and requires `--within`
when multiple scroll regions exist.

`crop --changed-since <snapshot-id>` derives regions from the helper's retained
snapshot-relative semantic/render delta, then captures their bounded union and
verifies the current snapshot identity again before returning pixels. Its JSON
records baseline/current/verification scopes, logical and physical rects, DPR,
backend, capture identity, limits, and provenance. It fails closed for stale or
foreign history, incomplete or ambiguous geometry, screen/route or coordinate
frame changes, more than 16 regions, padded unions above 50% of the viewport,
padding above 256 logical pixels, or rasters above 4096×4096 / 4,194,304
pixels. This is not pixel differencing. A platform view requires a full native
screenshot because native changed-region fallback cannot be atomically bound
to the same helper snapshot.

For a persistent agent integration, `serve` binds to loopback and exposes an
authenticated typed JSON protocol. It writes a fresh bearer header to an
owner-only credential file; the legacy free-form endpoint is disabled unless
`--allow-legacy-run` is explicitly supplied:

```bash
flutter-scout serve --port-file /tmp/scout.port \
  --credential-file /tmp/scout.credential
curl -H @/tmp/scout.credential \
  "localhost:$(cat /tmp/scout.port)/v1/schema"
curl -X POST -H @/tmp/scout.credential \
  -H 'content-type: application/json' \
  -H 'x-flutter-scout-deadline-ms: 5000' \
  --data '{"method":"tap","args":["btn.save"],"params":{"expectText":"Saved","capture":"/tmp/saved.png","assertNoErrors":true}}' \
  "localhost:$(cat /tmp/scout.port)/v1/call"
```

While a session’s daemon is active, ordinary `flutter-scout inspect` and action commands automatically proxy through it. Agents can keep using the normal CLI syntax without paying a new VM/WebSocket connection cost for each command.

Use `flutter-scout version`, `flutter-scout help <command>` (or
`flutter-scout <command> --help`), and
`flutter-scout doctor` to verify the CLI identity, protocol compatibility, and
resolved helper package before debugging an app.

`fill` and `input` are for real editable text fields only. Custom controls such as numeric keypads are exposed in `visualTree` and `controlGroups`, for example a dialog region with title, display text, a `numeric_keypad` control group, key children like `key.1`, and commit actions like `btn.save`. Agents should operate those controls with explicit `tap` commands, the same way a human would press visible buttons.

Target taps require a visible safe point. If a handle exists but is currently offscreen, `tap <handle>` returns `target_not_visible` instead of dispatching a gesture to an offscreen rect center. Scroll the control into view first, then tap the same handle.

`tap-text` resolves visible text and its actionable owner through the same
uniqueness, active-surface, visibility, occlusion, and immediate hit-test gate
as handle actions. It returns both the activated `target` and matched
`textTarget`. Use `tap-text --text "<visible text>"` for a label that begins
with `-`. Very short text such as `OK` must match exactly. A semantic mismatch
fails with `tap_text_target_mismatch`; use the explicit handle or
`--allow-mismatch` only when intentional. Scout never issues a second fallback
tap after a legacy/incomplete helper response, because the first dispatch may
already have taken effect. Update/relaunch the helper instead.

When a submit action reveals field validation, action deltas include `newValidationMessages` and `validationCandidates` so agents can identify the missing field without guessing from raw text.

Drag commands return `result:"navigated"` when the gesture changes screens. Verbose output includes `gestureStart`, `gestureEnd`, and the normal delta so agents can distinguish scrolling from a drag that triggered navigation.

For interactions whose UI follows the finger, use the held-drag lifecycle. `drag-start` keeps one synthetic touch down, each `drag-move` advances that same pointer (including direction reversals), and `drag-end` releases it and waits for the settling animation. Add `--screenshot <path>` to any move to capture the exact intermediate frame. The final verbose response includes `gesturePath` samples with positions, elapsed time, screen, view signature, and text hash. Scout automatically cancels an abandoned held drag after two minutes.

Brief inspect includes scoped scroll-region handles such as
`scroll.appointments`, nesting/parent context, axis, bounds, current pixels,
extents, viewport dimension, normalized approximate position, edge status, and
provenance when Flutter exposes them. Use a region with `scroll --target`,
`drag-start --target`, or `reveal --within` rather than guessing coordinates.
Unavailable position facts remain explicitly unavailable.

`inspect`, actions, and `health` hide log signals older than 30 seconds by default so a past startup failure does not pollute current verification. Use `inspect --include-stale`, `health --include-stale`, or `logs --summary` when investigating history. `wait stable` is compact by default; pass `--verbose` for its full snapshot.

Coordinate taps accept either `tap --x <x> --y <y>` or the shorthand `tap <x> <y>`.

When an action transition lands after the initial stability wait, action output can include `lateChangeObserved:true`. Transient loading/saving/refreshing states are sampled during the wait, allowing Scout to distinguish a true no-op from an operation that settles back to the original UI.

Use compact logs for triage:

```bash
dart run bin/flutter_scout.dart logs --summary
dart run bin/flutter_scout.dart logs --last 20
```

`logs --summary` classifies Scout-owned VM/flutter log output into structured
`recentLogSignals`, including framework build errors, uncaught exceptions,
RenderFlex overflows, native Flutter errors, high-severity app logs, and
permission/request failures. Fresh blocking signals also appear as
`blockingLogSignals`, so agents can stop on hard facts without grepping
`logs.txt` manually. Every Scout-owned line is timestamped, assigned a byte cursor, and redacted for common credentials before it is written. Action output includes only signals after its starting cursor; legacy untimestamped history is treated as stale rather than permanently fresh.

When `logs --contains <text>` finds no matching lines in a non-empty Scout-owned log, the command keeps `available:true`, reports `matched:0`, and says no lines matched the filter.

For attach-only sessions started by VS Code, Cursor, or another terminal, `logs` reports `source:"attach_only_session"` with `available:false`; Scout can still inspect and act through the VM service, but the owning process keeps the console logs. Start with `flutter-scout ensure` or `flutter-scout launch` when Scout should own log capture.

Use `status` before hot updates when the session origin is unclear. It reports `hotUpdate.reload` and `hotUpdate.restart` capability, including whether restart requires the owning Flutter terminal/IDE or a Scout-owned run. If a hot restart moves the VM service to a new port, `status` tries to refresh a stale saved URI from the latest Scout-owned log or simulator log marker and reports `staleRefreshed:true` when it rewrites the session.
If a Scout-owned run is still alive but its saved VM URI was removed, `status`
recovers the URI and ownership from that run's scoped log instead of reporting
an unattached session. An explicit reattach to the URI recorded by the same
owned run also preserves restart and log-capture ownership.

Collect a private run bundle:

```bash
dart run bin/flutter_scout.dart evidence \
  -o /private/path/flutter_scout_evidence --retention session
```

The bundle writes `summary.json`, `status.json`, `logs.json`, optional `inspect.json`, optional `session.json`, optional `transcript.txt`, and a screenshot when the current target supports capture. Add `--audit` to also write an `audit.md` scaffold with current state, transcript, and finding placeholders. Unsupported screenshots or missing attach logs are recorded as structured evidence instead of failing the command.

`recentErrors` reports runtime facts from Flutter/platform hooks;
`recentLogSignals` classifies Scout-owned logs when errors do not reach those
hooks. Entries carry capture/source provenance, timestamp, severity, blocking
status, phase, age/freshness, stable deduplication identity, run/runtime/state,
and action/error/log cursors. Correlation explicitly says observation does not
establish causality. Cursor windows prevent historical signals from being
attributed to a new action as fresh.

Replay output includes both `results` and a concise `transcript` array. The transcript is intended for quick run reports, while `results` keeps the structured command evidence.

## Annotation Mode

Scout-owned launches show a passive session badge for window identification;
it is excluded from hit testing and semantics. Scout does not install that
badge merely because the helper attaches. Run `annotations enable` to make the
badge interactive and opt into the annotation UI (or start a recording to opt
into its HUD). Disabling annotation mode returns the launch badge to passive
mode when recording is also inactive. In annotation mode, tap a visible widget to select it. Repeated taps
in the same spot cycle through stacked candidates, such as text, button,
section, or screen-level targets. Add a comment and save it; the comment is kept
in the running app and exposed to the CLI:

```bash
dart run bin/flutter_scout.dart annotations list
dart run bin/flutter_scout.dart annotations targets
dart run bin/flutter_scout.dart annotations enable
dart run bin/flutter_scout.dart annotations disable
dart run bin/flutter_scout.dart annotations check
dart run bin/flutter_scout.dart annotations resolve ann_001 --note "Fixed layout"
dart run bin/flutter_scout.dart annotations dismiss ann_002 --note "No longer relevant"
dart run bin/flutter_scout.dart annotations reopen ann_001
dart run bin/flutter_scout.dart annotations clear --resolved
dart run bin/flutter_scout.dart annotations clear
```

`inspect` also includes top-level `annotationMode` and `annotations` fields so agents can see user comments during the normal inspect loop. Annotation targets are intentionally collected separately from normal `inspect` interactables so Scout keeps its compact action-oriented view while annotation mode can identify non-actionable visible widgets.

Annotations are persistent review markers. The CLI stores their metadata and materialised crops in `.flutter_scout/annotations.json`; after a hot restart or relaunch, the next annotation command restores active pins into the new helper runtime before reporting state. `annotations list` and `inspect` include both the captured `snapshotRect` and the current `liveRect` when Scout can match the target again, plus `liveMatched`, `geometryChanged`, and `geometryDelta`. Use `annotations check` to refresh `open` annotations whose targets disappeared into `stale_target`, and use `resolve`, `dismiss`, or `reopen` for explicit lifecycle changes. Resolved and dismissed annotations stay in CLI history but are hidden from the in-app overlay marker count and pins.

Stop a Scout-owned launch process:

```bash
dart run bin/flutter_scout.dart stop --clear-session
```

On macOS this first unloads the exact per-run `launchd` agent, then terminates
the verified Flutter process. Do not unload Scout launch agents manually; the
session identity checks in `stop` prevent unrelated services from being
targeted.

## Current Limits

- Attach log discovery works with the helper marker on iOS Simulator, but explicit protected `--debug-url-file`/`--debug-url-stdin` ingress remains the most deterministic path. Remote VM-service transport is unsupported.
- Full screenshots use `xcrun simctl` for an exactly recorded iOS Simulator,
  `adb exec-out screencap -p` for an exactly recorded Android Emulator, and
  app-window `screencapture` for macOS attach sessions. Native output is
  size-bounded and fully decoded before an owner-only atomic artifact write, and the
  response identifies its backend, device, pixel space, provenance, and known
  limitations.
- Native mobile deep links are capability-preflighted against the exact recorded
  emulator, then require a live protocol-valid observation from the exact
  session immediately before dispatch. Android invokes `adb shell am start -W`
  through a local argv vector, single-quotes the URL for the remote device shell,
  and requires Activity Manager's `Status: ok`; iOS uses local argv-only
  `simctl openurl`. A missing tool,
  unsupported platform, physical device, stale device id, or unreachable
  emulator returns `unsupported_capability` before application dispatch.
- In-app targeted crops work on desktop, simulator, and device sessions. A crop
  containing a platform view may require the native fallback. Native mobile
  crops proceed only when the helper's same-snapshot physical viewport exactly
  matches the captured image; system chrome, insets, rotation, or letterboxing
  produce a typed coordinate-frame mismatch instead of a guessed offset. Native
  macOS window crops remain unavailable, so use an in-app crop or a full native
  screenshot for that case.
- Android native capture/deep-link source contracts and deterministic process
  tests are implemented, but Android Emulator remains experimental until the
  complete retained Tier-1 simulator suite passes; this is not a parity or
  release-ratification claim.
- Attach-only sessions cannot read the owning IDE or terminal console logs. `logs` reports that limitation unless Scout owns the `flutter run` process.
- Attach-only hot restart still requires the owning Flutter tool or a Scout-owned `ensure`/`launch`; Scout reports the VM listener process and next actions when restart is unavailable.
- Package or helper updates do not change code already loaded in an attached human-started Flutter process; hot restart or relaunch that app when `helperProtocol.status` reports `stale_or_old_helper`.
- Snapshot-bound changed-region crop is available for complete in-app
  semantic/render geometry. It deliberately abstains for stale history,
  global/frame changes, incomplete geometry, oversized unions, and platform
  views; use a full screenshot when the typed failure recommends one.
- Runtime hard-signal source contracts cover Flutter/Dart/platform errors,
  visible `ErrorWidget` surfaces, render overflows, image/request/permission
  failures, high-severity logs, and build/hot-update rejection with provenance,
  freshness, deduplication identity, and cursors. Retained simulator
  precision/recall/latency episodes remain absent.
