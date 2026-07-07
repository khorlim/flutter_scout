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
2. `FlutterScoutCli.run()` dispatches to a command method.
3. That method calls `_call('ext.flutter_scout.<x>', params)` over the VM service.
4. In the app, `FlutterScoutRuntime._handle<X>` runs, mutates/reads the widget
   tree, and returns JSON.
5. The CLI post-processes (compaction, crop materialization) and prints JSON.

## packages/flutter_scout_helper (in-app runtime)

One library (`lib/src/flutter_scout_binding.dart`) split into `part` files. The
god class `FlutterScoutRuntime` keeps its fields + `install()` in the main file;
cohesive method groups live in `extension`s in part files (private fields stay
accessible because all parts share one library).

| File | Responsibility |
|------|----------------|
| `flutter_scout_binding.dart` | Entry points (`FlutterScoutBinding`, `FlutterScoutHelper`), `FlutterScoutRuntime` shell: fields, `install()`, error hooks, extension registration, `@visibleForTesting` debug hooks, `_handleInspect`. |
| `runtime_annotations.dart` | **Annotation workflow + in-app capture.** `_handleAnnotations` (list/wait/fixed/get-crop/signal-handoff), status transitions, `_captureRegion`/`_handleCapture`, overlay install, public `addAnnotation`/`annotationCandidatesAt`/`visibleAnnotationTargets`. |
| `runtime_actions.dart` | Interaction handlers: tap, tap-text, input, long-press, fill, scroll, swipe, scroll-to, back, wait-stable, pointer dispatch. |
| `runtime_snapshot.dart` | `_snapshot` (reads the widget tree) + annotation target collection + hit testing. |
| `runtime_nodes.dart` | Node post-processing: compaction, label inference, id disambiguation, visual tree, geometry helpers. *(largest part; a future split candidate.)* |
| `runtime_internals.dart` | Low-level pointer dispatch, tree walk, snapshot delta, `_ok`/`_fail` JSON responses. |
| `annotation_overlay.dart` | Overlay widgets: toggle pill, comment panel, pin popup, animated pin reticles, target painter. |
| `scout_design.dart` | The **"Recon HUD" design system** — tokens (`ScoutColors`/`Space`/`Radius`/`Type`/`Motion`) + primitives (`ScoutPanel`/`Button`/`Pill`/`Field`). Use it, not Material, for Scout chrome. See `docs/scout-design-system.md`. |
| `models.dart` | Data types: `ScoutSnapshot`, `ScoutNode`, `ScoutAnnotation`, `ScoutAnnotationTarget`, `_CaptureResult`, … |

## packages/flutter_scout (CLI)

One library (`lib/src/flutter_scout_cli.dart`) split the same way. `run()`,
VM connection, device discovery, session-file IO, and `static` helpers stay in
the shell; command groups are `extension`s.

| File | Responsibility |
|------|----------------|
| `flutter_scout_cli.dart` | `run()` dispatch, `_call`/`_connect`, device resolution, VM-uri discovery, session-file IO, process inspection, usage. Top-level `_sessionDir` getters. |
| `cli_session.dart` | launch / attach / ensure / status / doctor / stop. |
| `cli_annotations.dart` | `bounds`, `annotations` command + crop materialization (cache keyed by capture identity, native fallback). |
| `cli_actions.dart` | tap, input, tap-text, long-press, fill, wait, reload/restart, scroll/swipe/scroll-to, back, deeplink, logs. |
| `cli_capture.dart` | screenshot / crop, `_inAppCapture`, `_cropPngBytes`. |
| `cli_evidence.dart` | evidence bundle, replay, transcript formatting. |
| `cli_results.dart` | VM response printing, protocol diagnostics, result compaction. |
| `cli_models.dart` | CLI value types (exception, discovery/ready results, device + macOS window descriptors). |

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
