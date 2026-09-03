# Flutter Scout — Architecture (agent navigation map)

Flutter Scout gives an AI agent "eyes and hands" for a Flutter app running on a
simulator/device. Two packages cooperate over the Dart VM service:

```
agent ──> flutter-scout CLI ──(VM service ext.flutter_scout.*)──> in-app runtime ──> Flutter app
          packages/flutter_scout            packages/flutter_scout_helper
```

The CLI is a stateless command process; the helper is a binding installed inside
the app that registers VM-service extensions and renders the annotation overlay.

## Request flow

1. The agent runs `flutter-scout <command>` (e.g. `tap btn.save`).
2. `FlutterScoutCli.run()` resolves the named session, repairs an interrupted
   temporary-helper transaction, and performs fail-closed registered-artifact
   expiry before reserving a durable, cursor-addressed command event. It then
   preloads protected secret input and dispatches to a command method.
3. A read passively samples current Flutter state and gets a typed protocol
   envelope; it never schedules or manually advances frames or installs UI.
   A mutation first performs a fresh inspect preflight, negotiates
   schema/protocol/capabilities, and binds one command/idempotency key to run,
   runtime, state generation, error cursor, and deadline.
4. In the app, `runtime_protocol.dart` serializes mutations and deduplicates the
   key. The handler uniquely resolves/revalidates the target immediately before
   one dispatch, observes stability/delta/signals, and returns a typed envelope.
5. The CLI validates the echoed identity, closes dispatch/observation/
   postcondition/runtime outcomes, commits replay and event evidence, then
   prints a bounded sanitized response. Evidence failure converts possible
   success into an explicit reconcile-before-retry outcome.

## packages/flutter_scout_helper (in-app runtime)

One library (`lib/src/flutter_scout_binding.dart`) split into `part` files. The
god class `FlutterScoutRuntime` keeps its fields + `install()` in the main file;
cohesive method groups live in `extension`s in part files (private fields stay
accessible because all parts share one library).

| File | Responsibility |
|------|----------------|
| `flutter_scout_binding.dart` | Entry points (`FlutterScoutBinding`, `FlutterScoutHelper`), `FlutterScoutRuntime` shell: fields, `install()`, error hooks, extension registration, `@visibleForTesting` debug hooks, `_handleInspect`. |
| `runtime_annotations.dart` | **Annotation workflow + in-app capture.** `_handleAnnotations` (list/wait/fixed/get-crop/signal-handoff), status transitions, `_captureRegion`/`_handleCapture`, passive Scout-launch badge + explicit interactive-overlay lifecycle, public `addAnnotation`/`annotationCandidatesAt`/`visibleAnnotationTargets`. |
| `runtime_actions.dart` | Interaction handlers: tap, tap-text, input, long-press, fill, scroll, swipe, scroll-to, held drags, back/dismiss, bounded waits, same-call expectation + frame capture, and the structural split between passive observation and frame-driving post-mutation settling. |
| `runtime_protocol.dart` | Schema/protocol envelopes, capability negotiation, monotonic state generation + SHA-256 identity, request/error cursors, mutation deadlines, serialization, and idempotent deduplication. |
| `runtime_timings.dart` | Request-local, exclusive monotonic timing for helper-owned `snapshot`/`match`/`dispatch`/`settle`/`delta` phases and exact unavailable-state closure. |
| `runtime_resolution.dart` | Central unique target/text resolution, ranked ambiguity evidence, active-surface/visibility/enabled/occlusion/hit-test checks, and immediate pre-dispatch revalidation. |
| `runtime_navigation.dart` | Read-only `where`/`locate`, bounded exactly-once `reveal`, scroll-region selection/restoration, and bounded snapshot history for `inspect --since`. |
| `runtime_snapshot.dart` | Fault-isolated widget-tree snapshots, scroll metrics, perception limitations/blind spots, annotation target collection, and hit testing. |
| `runtime_nodes.dart` | Node post-processing: compaction, label inference, id disambiguation, visual tree, geometry helpers. *(largest part; a future split candidate.)* |
| `runtime_switch_labels.dart` | Conservative structural label aliases for ordinary settings rows containing one switch. |
| `runtime_internals.dart` | Low-level pointer dispatch, tree walk, factual before/after delta, and `_ok`/`_fail` routing. |
| `runtime_privacy.dart` | Earliest-source sensitive-field classification, value tokens, recursive response redaction, and recorder/action echo protection. |
| `runtime_recorder.dart` | In-app flow capture plus private, atomic, lock-serialized helper persistence with safe CLI delegation. |
| `annotation_overlay.dart` | Overlay widgets: toggle pill, comment panel, pin popup, animated pin reticles, target painter. |
| `scout_design.dart` | The **"Recon HUD" design system** — tokens (`ScoutColors`/`Space`/`Radius`/`Type`/`Motion`) + primitives (`ScoutPanel`/`Button`/`Pill`/`Field`). Use it, not Material, for Scout chrome. See `docs/scout-design-system.md`. |
| `models.dart` | Data types: `ScoutSnapshot`, `ScoutNode`, `ScoutAnnotation`, `ScoutAnnotationTarget`, `_CaptureResult`, … |

## packages/flutter_scout (CLI)

One library (`lib/src/flutter_scout_cli.dart`) split the same way. `run()`,
device discovery, the part declarations, macOS window discovery, and static log
classifiers stay in the shell; command/protocol/storage/native-platform
concerns live in extensions and top-level helpers.

| File | Responsibility |
|------|----------------|
| `flutter_scout_cli.dart` | `run()` dispatch and durable command reservation, device/VM discovery, process/log classifiers, usage, and the library shell. |
| `cli_session.dart` | Transactional launch / attach / ensure / status / doctor / stop: isolated named runtime directories, per-run logs, launch locks/joining, atomic metadata, delegation to temporary-helper lifecycle repair, and truthful exact-residue reporting for session clear. |
| `cli_temporary_helper.dart` | Temporary-helper write-ahead transaction, phase/checkpoint lifecycle, startup/status/doctor recovery, exact tracked-input restoration, live-owner preservation, and prioritized fail-closed repair results. |
| `cli_temporary_helper_storage.dart` | Bounded path/record validation, private integrity-checked backups, atomic digest-gated project-file replacement, symlink refusal, verification, and cleanup tombstones. |
| `cli_supervisor.dart` | Detached Flutter-runner ownership. On macOS, a per-run `launchd` agent survives terminal/agent cleanup, restarts only an abnormally lost worker, adopts a surviving Flutter PID, and is unloaded by exact identity on `stop`; other platforms use the detached-process fallback. |
| `cli_session_recovery.dart` | Safe implicit selection of a sole named session plus recovery of missing owned-run process/VM metadata. |
| `cli_annotations.dart` | `bounds`, `annotations` command + crop materialization (cache keyed by capture identity, native fallback). |
| `cli_actions.dart` | tap, input, tap-text, long-press, fill, wait, reload/restart, scroll/swipe/scroll-to, back, deeplink, logs, guarded capture/error options. |
| `cli_navigation.dart` | `where`, read-only ranked `locate`, bounded `reveal`, and navigation argument bounds. |
| `cli_capture.dart` | screenshot / crop, `_inAppCapture`, `_cropPngBytes`. |
| `cli_native_platform.dart` | Exact recorded-emulator capability routing, bounded local-argv platform processes (including explicit Android remote-shell URL encoding), full PNG decode/provenance, TERM-to-KILL containment, and deterministic process seams. |
| `cli_vm_transport.dart` | Central VM-service capability-URL validation, loopback-only transport policy, endpoint-only disclosure, guarded persistence, and deterministic no-egress probes. |
| `cli_evidence.dart` | Fresh, completion-gated retained evidence bundles, replay, and transcript formatting. |
| `cli_batch.dart` | Bounded command batching and private replay-script export. |
| `cli_record.dart` | Recording store/list/run plus retained owner-only export operations and the central JSON printer. |
| `cli_serve.dart` | Persistent HTTP bridge: legacy `/run`, typed `/v1/schema` + `/v1/call`, health, and shutdown. |
| `cli_results.dart` | VM connection/invocation, action evidence transaction, protocol diagnostics, runtime-loss mapping, and safety-preserving compaction. |
| `cli_protocol.dart` | CLI protocol envelope validation, mutation preflight/identity/deadline/idempotency construction, timeout reconciliation, and closed mutation outcomes. |
| `cli_response.dart` | Bounded additive response envelopes, structured errors/heartbeats, operability identity, and output serialization. |
| `cli_operability.dart` | Shared truthful status/doctor/health snapshots: binary/helper/protocol/session/runtime/device/ownership identity, artifact paths, active tool state, source freshness, and prioritized recovery. |
| `cli_timings.dart` | Canonical eight-phase validation/merge, CLI `connect`/`logs`/`serialize` boundaries, cross-call aggregation, and action overhead excluding app settling. |
| `cli_privacy.dart` | Registered-secret-first recursive redaction, encoded variants, safe command/event arguments, and flow/artifact sanitization. |
| `cli_secret_ingress.dart` | Bounded strict-UTF-8 stdin and owner-only `0600` file ingress for input/fill/replay variables, VM-service URLs, and deep-link URLs, with legacy-argv warnings. |
| `cli_storage.dart` | Private directory/file modes, caller-parent-preserving atomic writes, symlink refusal, blocking cross-process locks, event cursors, and the integrity-checked exact-path retention registry with expiry/session cleanup and bounded directory identities. |
| `cli_models.dart` | CLI value types (exception, discovery/ready results, device + macOS window descriptors). |

## Protocol, evaluation, and release evidence

- `protocol/schemas/v1/` is the immutable machine-readable core contract for
  persistent calls, mutation requests/outcomes, navigation, helper responses,
  CLI envelopes, events, and heartbeats. Additive v1 changes must tolerate
  unknown optional fields; incompatible changes require a new schema directory.
- `evaluation/` is a separate pure-Dart package. It owns task/catalog/config/
  schedule/raw-episode/report schemas, an independent-oracle boundary,
  deterministic paired scheduling, immutable SHA-256 archives, Wilson/McNemar/
  clustered-bootstrap statistics, the corpus-readiness policy, and the
  tool-simulator runner. It must not derive pass/fail from Scout output.
- `security/` contains the generated adversarial privacy corpus and its explicit
  source/sink coverage ledger.
- `tool/release/` builds deterministic offline checksums, provenance, schema
  digests, dependency inventory, and a tamper-verifiable release manifest. It
  diagnoses a dirty checkout but cannot make one release-eligible.
- `QUALITY_STANDARD.md`, `COMPATIBILITY.md`, and `RELEASING.md` are normative;
  `evaluation/conformance_matrix.v1.json` is the exhaustive proof ledger and
  must remain honest about missing external evidence.

## Annotation handoff workflow (human → agent)

The headline feature. A person annotates the running app; the agent reads,
fixes, and verifies. See `skills/flutter-scout/SKILL.md` for the agent-facing
commands. Key pieces:

- **Capture** (`runtime_annotations.dart` → `_captureRegion`): rasterizes a
  widget region via the root layer. Bounds are PHYSICAL with `pixelRatio: 1.0`
  because the root `TransformLayer` already bakes in the device pixel ratio.
  Platform views are detected and the CLI falls back to a native screenshot.
- **Crops** are captured in-app at create (`before`) and `mark-fixed` (`after`),
  served via `get-crop`, and materialized to `.flutter_scout/crops/` by the CLI
  (`cli_annotations.dart`), cached by a capture-identity token to survive app
  restarts (IDs reset to `ann_001`).
- **Manual handoff**: the reviewer tells the agent annotations are ready; the
  CLI reads current pins with `annotations list` and manages lifecycle commands.
- **Verification**: `pending_review` status (amber pins) + before/after crops.

## Conventions for modifying this code

- Each `part` file is one concern — start there, not in the 1,300-line shells.
- The runtime is one library: any new private member is visible to all parts.
- Keep the public API (`run()`, `FlutterScoutRuntime` public methods, the
  `RuntimeAnnotations` extension) stable; tests call these directly.
- After changes, keep both packages green — the CLI is pure Dart, the helper is a
  Flutter package: `dart analyze`/`dart test` in `packages/flutter_scout`,
  `flutter analyze`/`flutter test` in `packages/flutter_scout_helper`. For behavior
  changes, smoke-test on a simulator (see SKILL.md).
