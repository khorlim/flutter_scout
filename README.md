# Flutter Scout

Flutter Scout is an agent-oriented eyes-and-hands bridge for Flutter simulator apps.

The current vertical slice implements:

- a main-only Flutter helper initializer
- a registration initializer for apps that already create a custom debug binding
- VM service extensions for inspect, tap, tap-text, long press, input, fill, scroll, swipe, back, and wait-stable
- a Dart CLI that can ensure, launch, or attach to a simulator app
- stale session validation and exact device resolution for launch/attach
- `doctor`, `status`, `stop`, and `bounds` commands for setup and cleanup
- extension readiness preflight after launch/attach
- attach-first `ensure`, hot reload, and hot restart commands to avoid rebuilds
- status hot-update capability hints so agents know whether reload/restart can avoid a rebuild
- reload diagnostics that distinguish rejected VM reloads from reachable apps still running old code
- compact default action output, with full before/after data behind `--verbose`
- compact inspect snapshots
- addressable text targets for bounds/crops and safer `tap-text` activation through nearest actionable ancestors or visible text-point fallback
- split text visibility in inspect summaries with `visibleText`, `hitTestableText`, and `offscreenText`
- stable handles for common icon-only Material actions and glyph text such as add, back, save, duplicate, delete, download, search, close, edit, and more
- inferred button handles for unlabeled gesture targets with clear contained action text, such as payment, confirm, done, create order, login, and save actions
- stale helper diagnostics and CLI-side `tap-text` fallback for attached apps still running an older helper protocol
- duplicate-safe field handles and field values
- viewport-aware inspect metadata for offscreen or partially visible controls
- offscreen target protection: target taps fail with `target_not_visible` until the control has a visible safe tap point
- coordinate-aware scroll and swipe gestures
- per-field fill results and before/after action deltas
- screenshot capture through `xcrun simctl` for iOS Simulator sessions and app-window `screencapture` for macOS attach sessions
- targeted crops through `xcrun simctl` for iOS Simulator sessions
- log capture for Flutter Scout launches
- attach-aware log diagnostics for human/IDE-owned sessions
- evidence bundles that collect status, inspect, logs, screenshot, and session replay files
- hard runtime signal capture through Flutter/platform error hooks with severity, blocking, phase, age, and stale facts
- replayable sessions with a concise transcript in replay output
- launch timing metrics for Scout-owned launches, including total, build, sync, VM service, and ready timing
- an in-app annotation overlay for selecting visible widgets, adding comments, and exposing those comments to agents
- a sample Flutter app for simulator verification

## Packages

```text
packages/flutter_scout_helper   Flutter helper package
packages/flutter_scout          CLI package
apps/scout_test_app             Verification app
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

## Verified Simulator Flow

Prefer `ensure` for day-to-day verification. It reuses a running Scout session when possible and launches only when needed:

```bash
cd packages/flutter_scout
dart run bin/flutter_scout.dart ensure --device <simulator-id> --project ../../apps/scout_test_app
```

Use `launch` when you explicitly need Scout to start a new Flutter run:

```bash
dart run bin/flutter_scout.dart launch --device <simulator-id> --project ../../apps/scout_test_app
```

Successful launch and attach responses include `ready`. If the VM service is available but the helper extension is missing, the command returns `ready:false` with `reason:"helper_extension_missing"` and the expected initializer.

Or attach to an already running app:

```bash
dart run bin/flutter_scout.dart attach --device <simulator-id> --debug-url <vm-service-url>
```

Check setup and the current session:

```bash
dart run bin/flutter_scout.dart doctor --project ../../apps/scout_test_app --device <simulator-id>
dart run bin/flutter_scout.dart status
```

Drive the sample flow:

```bash
dart run bin/flutter_scout.dart inspect
dart run bin/flutter_scout.dart tap btn.add_supplier
dart run bin/flutter_scout.dart fill --json '{"Supplier name":"Replay Supplier","Phone":"555"}'
dart run bin/flutter_scout.dart tap btn.save_supplier
dart run bin/flutter_scout.dart bounds btn.add_supplier
dart run bin/flutter_scout.dart screenshot -o /tmp/flutter_scout_test.png
dart run bin/flutter_scout.dart crop btn.add_supplier -o /tmp/flutter_scout_add_button_crop.png
dart run bin/flutter_scout.dart evidence -o /tmp/flutter_scout_evidence
dart run bin/flutter_scout.dart replay .flutter_scout/session.json
```

After Dart-only code changes, avoid a full rebuild:

```bash
dart run bin/flutter_scout.dart reload
dart run bin/flutter_scout.dart restart
```

`reload` preserves app state. `restart` resets Dart state without reinstalling, and requires a Scout-owned `launch`/`ensure` process so Scout can signal the Flutter tool. Native, plugin, asset, or `pubspec.yaml` changes can still require a full relaunch/rebuild.

Drive the smoke-regression screen when changing form, text, row, or scroll behavior:

```bash
dart run bin/flutter_scout.dart tap btn.smoke_issues
dart run bin/flutter_scout.dart fill --json '{"field.enter_duplicate_note":"One","field.enter_duplicate_note_2":"Two","field.committed_answer":"Committed"}'
dart run bin/flutter_scout.dart tap btn.select_staff
dart run bin/flutter_scout.dart tap-text GoodJob
dart run bin/flutter_scout.dart scroll down --from 220,760 --distance 520
```

Action commands return compact JSON by default: result, stability, delta, recent errors, and a small after summary. Add `--verbose` to action commands or `replay` when full before/after payloads are needed.

Scout-owned `launch` and `ensure` responses include a `timing` object when they start Flutter, for example `totalMs`, `buildDurationMs`, `firstSyncMs`, `vmServiceFoundMs`, and `readyMs`. Use this to tell rebuild cost from app startup or VM-service wait time.

`inspect` includes `fieldsById`, `textTargets`, `visibleText`, `hitTestableText`, `offscreenText`, `visibleRect`, `visibleFraction`, `offscreen`, `partiallyOffscreen`, `suggestedTapPoint`, `hitTestable`, `scrollables`, `overlays`, `visualTree`, and `controlGroups` so agents can avoid stale, hidden, modal-blocked, or unsafe targets while still visualizing the UI hierarchy. Duplicate unkeyed fields are disambiguated by suffix, for example `field.enter_duplicate_note` and `field.enter_duplicate_note_2`. Icon-only controls should use keys, tooltips, or semantics when possible; Scout also derives handles for common Material icon widgets and glyph text, for example `btn.duplicate` from `Icons.copy`. Unlabeled gesture targets that contain clear action text can be promoted to `btn.*` handles, such as `btn.confirm_payment`, `btn.done`, or `btn.save_smoke`.

`fill` and `input` are for real editable text fields only. Custom controls such as numeric keypads are exposed in `visualTree` and `controlGroups`, for example a dialog region with title, display text, a `numeric_keypad` control group, key children like `key.1`, and commit actions like `btn.save`. Agents should operate those controls with explicit `tap` commands, the same way a human would press visible buttons.

Target taps require a visible safe point. If a handle exists but is currently offscreen, `tap <handle>` returns `target_not_visible` instead of dispatching a gesture to an offscreen rect center. Scroll the control into view first, then tap the same handle.

`tap-text` activates the nearest safe actionable ancestor for visible text and returns both the activated `target` and the matched `textTarget`. Very short text such as `OK` must match exactly. If the text appears to map to a different semantic action, such as `Select Room` inside a `Confirm` button region, Scout refuses with `tap_text_target_mismatch` instead of submitting the wrong action. Use the explicit target handle or `--allow-mismatch` only when that mismatch is intentional. If the only safe actionable ancestor is much larger than the text, Scout taps the text point instead of the broad ancestor center. If no actionable ancestor exists but the visible text point is hit-testable, Scout can still tap that point and reports `activation.strategy:"visible_text_point"`. If an attached app is still running an older helper that returns a raw text target, the CLI warns about the stale helper protocol and retries against the best overlapping actionable inspect target when possible.

When a submit action reveals field validation, action deltas include `newValidationMessages` and `validationCandidates` so agents can identify the missing field without guessing from raw text.

Drag commands return `result:"navigated"` when the gesture changes screens. Verbose output includes `gestureStart`, `gestureEnd`, and the normal delta so agents can distinguish scrolling from a drag that triggered navigation.

Coordinate taps accept either `tap --x <x> --y <y>` or the shorthand `tap <x> <y>`.

When an action transition lands after the initial stability wait, action output can include `lateChangeObserved:true` so agents know the returned `afterSummary` includes a delayed route, modal, or overlay change.

Use compact logs for triage:

```bash
dart run bin/flutter_scout.dart logs --summary
dart run bin/flutter_scout.dart logs --last 20
```

When `logs --contains <text>` finds no matching lines in a non-empty Scout-owned log, the command keeps `available:true`, reports `matched:0`, and says no lines matched the filter.

For attach-only sessions started by VS Code, Cursor, or another terminal, `logs` reports `source:"attach_only_session"` with `available:false`; Scout can still inspect and act through the VM service, but the owning process keeps the console logs. Start with `flutter-scout ensure` or `flutter-scout launch` when Scout should own log capture.

Use `status` before hot updates when the session origin is unclear. It reports `hotUpdate.reload` and `hotUpdate.restart` capability, including whether restart requires the owning Flutter terminal/IDE or a Scout-owned run. If a hot restart moves the VM service to a new port, `status` tries to refresh a stale saved URI from the latest Scout-owned log or simulator log marker and reports `staleRefreshed:true` when it rewrites the session.

Collect a shareable run bundle:

```bash
dart run bin/flutter_scout.dart evidence -o /tmp/flutter_scout_evidence
```

The bundle writes `summary.json`, `status.json`, `logs.json`, optional `inspect.json`, optional `session.json`, and a screenshot when the current target supports capture. Unsupported screenshots or missing attach logs are recorded as structured evidence instead of failing the command.

`recentErrors` reports runtime facts from Flutter/platform hooks. Entries include `severity`, `blocking`, `phase`, `ageMs`, and `stale` so agents can separate fresh blocking failures from older non-blocking startup noise.

Replay output includes both `results` and a concise `transcript` array. The transcript is intended for quick run reports, while `results` keeps the structured command evidence.

## Annotation Mode

When an app runs with `flutter_scout_helper`, Scout injects a small debug overlay button. Tap it to enter annotation mode, then tap a visible widget to select it. Repeated taps in the same spot cycle through stacked candidates, such as text, button, section, or screen-level targets. Add a comment and save it; the comment is kept in the running app and exposed to the CLI:

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

Annotations are persistent review markers. Code changes, hot reloads, and hot restarts do not automatically remove them. `annotations list` and `inspect` include both the captured `snapshotRect` and the current `liveRect` when Scout can match the target again, plus `liveMatched`, `geometryChanged`, and `geometryDelta`. Use `annotations check` to refresh `open` annotations whose targets disappeared into `stale_target`, and use `resolve`, `dismiss`, or `reopen` for explicit lifecycle changes. Resolved and dismissed annotations stay in CLI history but are hidden from the in-app overlay marker count and pins.

Stop a Scout-owned launch process:

```bash
dart run bin/flutter_scout.dart stop --clear-session
```

## Current Limits

- Attach log discovery works with the helper marker on iOS Simulator, but explicit `--debug-url` remains the most deterministic path.
- Full screenshots use `xcrun simctl` for iOS Simulator sessions and app-window `screencapture` for macOS attach sessions.
- Targeted crops currently support iOS Simulator sessions only; macOS attach sessions return `crop_unsupported_target` for crops instead of producing misaligned content.
- Attach-only sessions cannot read the owning IDE or terminal console logs. `logs` reports that limitation unless Scout owns the `flutter run` process.
- Attach-only hot restart still requires the owning Flutter tool or a Scout-owned `ensure`/`launch`; Scout reports the VM listener process and next actions when restart is unavailable.
- Package or helper updates do not change code already loaded in an attached human-started Flutter process; hot restart or relaunch that app when `helperProtocol.status` reports `stale_or_old_helper`.
- Targeted crop is implemented for current inspect handles; changed-region crop is not implemented yet.
- Runtime hard-signal collection covers Flutter/platform errors and needs more coverage for image load failures and visible error banners.
