# Flutter Scout

Flutter Scout is an agent-oriented eyes-and-hands bridge for Flutter simulator apps.

The current vertical slice implements:

- a main-only Flutter helper initializer
- VM service extensions for inspect, tap, long press, input, fill, scroll, swipe, back, and wait-stable
- a Dart CLI that can launch or attach to a simulator app
- compact inspect snapshots
- before/after action deltas
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
goal.md                         Product goals
```

## App Integration

```dart
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MyApp());
}
```

No per-screen or per-widget wrappers are required.

## Verified Simulator Flow

Launch the test app through Flutter Scout:

```bash
cd packages/flutter_scout
dart run bin/flutter_scout.dart launch --device <simulator-id> --project ../../apps/scout_test_app
```

Or attach to an already running app:

```bash
dart run bin/flutter_scout.dart attach --device <simulator-id> --debug-url <vm-service-url>
```

Drive the sample flow:

```bash
dart run bin/flutter_scout.dart inspect
dart run bin/flutter_scout.dart tap btn.add_supplier
dart run bin/flutter_scout.dart fill --json '{"Supplier name":"Replay Supplier","Phone":"555"}'
dart run bin/flutter_scout.dart tap btn.save_supplier
dart run bin/flutter_scout.dart screenshot -o /tmp/flutter_scout_test.png
dart run bin/flutter_scout.dart crop btn.add_supplier -o /tmp/flutter_scout_add_button_crop.png
dart run bin/flutter_scout.dart replay .flutter_scout/session.json
```

## Current Limits

- Launch keeps a `flutter run` process alive and records its PID, but there is not yet a polished `kill` command.
- Attach log discovery works with the helper marker on iOS Simulator, but explicit `--debug-url` remains the most deterministic path.
- Targeted crop is implemented for current inspect handles; changed-region crop is not implemented yet.
- Runtime hard-signal collection covers Flutter/platform errors and needs more coverage for image load failures and visible error banners.
