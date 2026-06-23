---
name: flutter-scout
description: Use Flutter Scout to give AI agents eyes and hands for Flutter apps on simulators. Trigger when verifying Flutter UI/features after code changes, attaching to a running simulator app, launching a Flutter debug app for agent testing, inspecting screens, tapping/filling/scrolling through flows, collecting screenshots/crops, replaying verification steps, or checking hard runtime errors.
---

# Flutter Scout

Use Flutter Scout to verify Flutter changes on a simulator with a compact agent loop:

```text
ensure or attach -> inspect -> act -> reload/restart after edits -> read delta/errors -> crop if needed -> replay
```

## Setup Check

Use the app as-is except for the main initializer:

```dart
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MyApp());
}
```

If the app does not include it, add `flutter_scout_helper` and call the initializer before `runApp`. Do not add per-screen wrappers or test-only widgets.

If the app already initializes another debug binding, keep that initializer and call `FlutterScoutHelper.ensureRegistered()` after it instead of replacing the binding.

## Command Form

From the CLI package source:

```bash
cd packages/flutter_scout
dart run bin/flutter_scout.dart <command>
```

If installed as an executable, use:

```bash
flutter-scout <command>
```

## Preferred Workflow

1. Prefer reusing an existing simulator app:

```bash
flutter-scout ensure --device <simulator-id> --project <flutter-app-path>
flutter-scout attach --device <simulator-id>
flutter-scout attach --debug-url <vm-service-url>
```

`ensure` is the default for agent loops: it reuses a ready Scout VM service when possible and launches only when needed.

2. Launch directly only when you intentionally need a new Scout-owned Flutter run:

```bash
flutter-scout launch --device <simulator-id> --project <flutter-app-path>
```

Launch validates the exact requested device and emits compact progress events. If launch was interrupted or you need to stop a Scout-owned run:

```bash
flutter-scout stop --clear-session
```

Launch, ensure, and attach responses include `ready` when they start or connect to a VM service. If `ready` is false, fix the reported setup reason before inspecting or acting.

3. Inspect before acting:

```bash
flutter-scout inspect
```

Use `visibleText`, `interactables`, `fields`, `fieldValues`, `fieldsById`, `scrollables`, `overlays`, `keyboard`, and `recentErrors` to orient yourself. Prefer handles like `btn.save_supplier` and `field.supplier_name` over coordinates.

Read viewport facts before tapping: `visibleRect`, `visibleFraction`, `offscreen`, `partiallyOffscreen`, `suggestedTapPoint`, and `hitTestable`. If a control is partially visible, prefer the Scout handle because Scout taps the visible safe point. If a control is offscreen, scroll first.

Duplicate unkeyed fields are suffixed in inspect output, for example `field.enter_duplicate_note` and `field.enter_duplicate_note_2`. Use the exact `fieldsById` key when filling or inputting duplicate labels.

4. Act in feature-sized steps:

```bash
flutter-scout tap btn.add_supplier
flutter-scout fill --json '{"Supplier name":"QA Supplier","Phone":"0123456789"}'
flutter-scout tap btn.save_supplier
```

After every action, read `result`, `delta`, `fieldValues`, and `recentErrors`. Do not run a separate screenshot or full inspect unless the delta is unclear.

Action output is compact by default. Add `--verbose` only when full before/after summaries are needed.

5. After Dart-only code edits, hot update instead of relaunching:

```bash
flutter-scout reload
flutter-scout restart
```

Prefer `reload` first because it preserves app state. Use `restart` when reload is rejected or state must reset. `restart` requires a Scout-owned `launch`/`ensure` process; attach-only sessions should use `reload` or run `ensure` to launch when needed. Native, plugin, asset, and `pubspec.yaml` changes can still require a full rebuild.

6. Use targeted visual evidence when layout matters:

```bash
flutter-scout bounds btn.save_supplier
flutter-scout crop btn.save_supplier -o /tmp/save_button.png
flutter-scout screenshot -o /tmp/current_screen.png
```

Prefer `bounds` and crops over full screenshots when inspecting one control or dialog.

7. Replay after a fix:

```bash
flutter-scout replay .flutter_scout/session.json
```

Replay should be the first check after changing code for a flow you already tested.

## Useful Commands

```bash
flutter-scout status
flutter-scout ensure --device <simulator-id> --project <flutter-app-path>
flutter-scout doctor --project <flutter-app-path> --device <simulator-id>
flutter-scout wait stable
flutter-scout reload
flutter-scout restart
flutter-scout input --target field.search "query"
flutter-scout tap-text "GoodJob"
flutter-scout long-press btn.more
flutter-scout scroll down --distance 300
flutter-scout scroll down --from 220,760 --distance 520
flutter-scout swipe left --distance 240
flutter-scout swipe left --from 380,500 --to 80,500
flutter-scout back
flutter-scout deeplink myapp://route
flutter-scout logs --summary
flutter-scout logs --last 20
flutter-scout stop --clear-session
```

## Agent Rules

- Treat Flutter Scout as eyes and hands, not a QA judge.
- Prefer `attach` to preserve human-in-the-loop state.
- Prefer `ensure` over repeated `launch`; repeated full launch causes slow native rebuilds.
- Start with `inspect`; avoid blind screenshots.
- After Dart-only edits, run `reload` or `restart` before replaying flows.
- Prefer `fill` for forms instead of tap/type/tap/type, but read per-field results and warnings.
- Trust action deltas for next-step planning.
- Treat `delta.changedGeometry` as a real change for scrolling or layout movement even when text and field values are unchanged.
- Trust `status` to clear stale VM session files; reattach if it reports `staleCleared`.
- Stop and fix code when `recentErrors` reports Flutter/platform errors.
- Use `tap-text` for visible text rows or picker rows when generic row handles are ambiguous.
- Use coordinate scroll/swipe starts when the default gesture may hit the wrong layer.
- Keep `.flutter_scout/` as runtime state; do not commit it.
