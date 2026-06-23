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
- compact default action output, with full before/after data behind `--verbose`
- compact inspect snapshots
- duplicate-safe field handles and field values
- viewport-aware inspect metadata for offscreen or partially visible controls
- coordinate-aware scroll and swipe gestures
- per-field fill results and before/after action deltas
- screenshot capture and targeted crops through `xcrun simctl`
- log capture for Flutter Scout launches
- hard runtime signal capture through Flutter/platform error hooks
- replayable sessions
- a sample Flutter app for simulator verification

## Packages

```text
packages/flutter_scout_helper   Flutter helper package
packages/flutter_scout          CLI package
apps/scout_test_app             Verification app
skills/flutter-scout            Codex skill for agents using Flutter Scout
skills/flutter-scout-setup      Codex skill for installing Flutter Scout
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

`inspect` includes `fieldsById`, `visibleRect`, `visibleFraction`, `offscreen`, `partiallyOffscreen`, `suggestedTapPoint`, `hitTestable`, and `scrollables` so agents can avoid stale, hidden, or unsafe targets. Duplicate unkeyed fields are disambiguated by suffix, for example `field.enter_duplicate_note` and `field.enter_duplicate_note_2`.

Use compact logs for triage:

```bash
dart run bin/flutter_scout.dart logs --summary
dart run bin/flutter_scout.dart logs --last 20
```

Stop a Scout-owned launch process:

```bash
dart run bin/flutter_scout.dart stop --clear-session
```

## Current Limits

- Attach log discovery works with the helper marker on iOS Simulator, but explicit `--debug-url` remains the most deterministic path.
- Targeted crop is implemented for current inspect handles; changed-region crop is not implemented yet.
- Runtime hard-signal collection covers Flutter/platform errors and needs more coverage for image load failures and visible error banners.
