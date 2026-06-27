# Refactor: optimize code structure for AI-agent navigability

## Problem

Two god files dominate the codebase, each a single ~3,400-line class:

- `packages/flutter_scout_helper/lib/src/flutter_scout_binding.dart` — **4,455 lines**.
  `FlutterScoutRuntime` is one class with **~134 methods** spanning error hooks,
  every VM-service extension (inspect, tap, input, fill, scroll, capture,
  annotations, …), widget-tree snapshotting, hit-testing, annotation target
  collection, in-app capture, and overlay installation. Plus 5 overlay widget
  classes and 9 data classes in the same file.
- `packages/flutter_scout/lib/src/flutter_scout_cli.dart` — **3,770 lines**.
  `FlutterScoutCli` is one class with every command (launch/attach/ensure/
  status/doctor/inspect/annotations/tap/…), VM connection, screenshot/crop,
  device resolution, and macOS window discovery.

For an AI agent this means: to touch one concern (e.g. "annotation crops") it
must load a 4,455-line file and scan a 134-method class. Finding, understanding,
and safely modifying code is slow and error-prone.

## Goal

Smaller, topically-named files grouped by concern, with explicit navigation aids
— **without changing any runtime behavior**. Verified by `flutter analyze` +
`flutter test` after every step, and an end-to-end smoke test at the end.

## Mechanism (Dart-safe, behavior-preserving)

Dart privacy is library-level, so we keep each library as ONE library split
across `part`/`part of` files. Verified facts (tested in a scratch project):

- An `extension _X on FlutterScoutRuntime` declared in a `part` file can read AND
  mutate the class's private fields and be called with implicit `this` from the
  class's own methods. No call sites need to change.
- Whole classes (widgets, data models) move to `part` files freely.

So the god *class* keeps its fields + constructor + a few core methods in the
main file; cohesive method groups move into `extension`s in part files. No
public API changes, no behavior changes.

## Plan — binding (`flutter_scout_helper`)

Convert `flutter_scout_binding.dart` into a library with parts:

1. `src/models.dart` (part) ← data classes: `ScoutSnapshot`, `ScoutNode`,
   `ScoutAnnotation`, `ScoutAnnotationTarget`, `_CaptureResult`,
   `_EditableCandidate`, `_TextTargetMatch`, `_CustomInputSurface`,
   `_ActionSnapshotResult`. *(whole-class moves — lowest risk)*
2. `src/annotation_overlay.dart` (part) ← overlay widgets:
   `_FlutterScoutAnnotationOverlay(+State)`, `_AnnotationToggleButton`,
   `_AnnotationHandoffButton`, `_AnnotationCommentPanel`,
   `_FlutterScoutAnnotationPainter`. *(whole-class moves)*
3. `src/runtime_annotations.dart` (part) ← `extension` with the annotation +
   capture handlers and state (`_handleAnnotations`, `_annotationCropResponse`,
   `_updateAnnotationStatus`, `_refreshStaleAnnotationStatuses`,
   `_setAnnotationMode`, `_signalAnnotationHandoff`, `_annotationsStateJson`,
   `_annotationPins`, `annotationCandidatesAt`, `_captureAnnotationCrop`,
   capture: `_primaryRenderView`, `_captureRegion`, `_regionHasPlatformView`,
   `_handleCapture`, overlay install).
4. `src/runtime_actions.dart` (part) ← `extension` with action handlers
   (`_handleTap`/`TapText`/`Input`/`LongPress`/`Fill`/`Scroll`/`Swipe`/
   `ScrollTo`/`Back`/`WaitStable`, `_drag`, dispatch + snapshot-after-action).
5. `src/runtime_inspection.dart` (part) ← `extension` with `_snapshot`,
   annotation target collection + hit-testing, node compaction/label
   inference/disambiguation, visual tree, geometry helpers.
6. Keep in `flutter_scout_binding.dart`: imports, `part` directives, entry
   classes `FlutterScoutBinding`/`FlutterScoutHelper`, and `FlutterScoutRuntime`
   shell (fields, `install()`, `@visibleForTesting` debug hooks, `_ok`/`_fail`,
   `_walk`, error hooks, registration).

## Plan — CLI (`flutter_scout`)

Convert `flutter_scout_cli.dart` into a library with parts:

1. `src/cli_models.dart` (part) ← `ScoutCliException`, `_AttachDiscovery`,
   `_DiscoveredVmUri`, `_VmUriValidation`, `_ScoutReady`, `_LaunchTiming`,
   `_FlutterDevice`, `_MacosWindowTarget`.
2. `src/cli_session.dart` (part) ← `extension`: launch/attach/ensure/status/
   doctor/stop + device resolution + VM connect (`_call`, `_connect`, …).
3. `src/cli_actions.dart` (part) ← `extension`: inspect/annotations/tap/tap-text/
   input/fill/scroll/swipe/back/wait + crop materialization.
4. `src/cli_capture.dart` (part) ← `extension`: screenshot/crop/`_inAppCapture`/
   `_cropPngBytes`/native screenshot + macOS window discovery.
5. Keep the dispatch `run()` + helpers + session-dir getters in the main file.

## Navigation aids (highest value-per-risk)

- `ARCHITECTURE.md` at repo root: package map, where each concern lives, the
  request flow (CLI command → VM service extension → runtime handler), and the
  annotation handoff workflow.
- A short `// part: <responsibility>` header doc comment atop each part file.

## Execution order & safety

Execute bottom-up by line range (so line numbers above a cut stay stable) and
run `flutter analyze` after every extraction; run `flutter test` after each file
is fully split. Whole-class moves first (lowest risk), then method-group
extensions. A mid-method cut surfaces immediately as an analyze error.

Stop conditions: any behavior change, any test failure that can't be traced to a
mechanical slip, or analyze errors that imply the approach doesn't hold.

## Verification

- `flutter analyze` clean on both packages after each step.
- `flutter test` green on both packages.
- Full e2e smoke test on iOS Simulator (launch + core actions + annotation
  workflow) after the refactor.
