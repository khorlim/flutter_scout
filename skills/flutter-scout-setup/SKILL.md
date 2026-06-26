---
name: flutter-scout-setup
description: Install and wire Flutter Scout for a Flutter app. Trigger when setting up Flutter Scout for the first time, adding flutter_scout_helper to an app, installing or activating the flutter-scout CLI, configuring path or Git dependencies, preparing a simulator/debug session, finding device IDs or VM service URLs, or troubleshooting setup errors before using Flutter Scout.
---

# Flutter Scout Setup

Use this skill to install Flutter Scout and confirm the bridge is reachable before using it for feature verification.

## Decide Dependency Mode

Use local path dependencies when working from this repo:

```yaml
dependencies:
  flutter_scout_helper:
    path: /Users/han/flutter_packages/flutter_scout/packages/flutter_scout_helper
```

Use Git dependencies when wiring another project to the public repo:

```yaml
dependencies:
  flutter_scout_helper:
    git:
      url: https://github.com/khorlim/flutter_scout.git
      path: packages/flutter_scout_helper
```

Run:

```bash
flutter pub get
```

## Wire The App

Add only the main initializer:

```dart
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MyApp());
}
```

If the app already uses another debug binding, keep it and register Scout after it:

```dart
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

void main() {
  ExistingDebugBinding.ensureInitialized();
  FlutterScoutHelper.ensureRegistered();
  runApp(const MyApp());
}
```

Do not add screen wrappers, action wrappers, or test-only widgets.

## Install Or Run The CLI

For repo-local development:

```bash
cd /Users/han/flutter_packages/flutter_scout/packages/flutter_scout
dart pub get
dart run bin/flutter_scout.dart <command>
```

For global use from Git:

```bash
dart pub global activate --source git https://github.com/khorlim/flutter_scout.git --git-path packages/flutter_scout
```

If `flutter-scout` is not found, check that the pub cache bin directory is on `PATH`:

```bash
echo "$PATH"
dart pub global list
```

Then use:

```bash
flutter-scout <command>
```

## Prepare Simulator

List devices:

```bash
flutter devices
```

Use a booted simulator device ID. The app must run in debug or profile mode so the Dart VM service is available.

## First Connection

Prefer attaching to an app the human already started:

```bash
flutter-scout attach --device <simulator-id>
```

If attach cannot discover the VM service URL, copy it from Flutter/IDE/DevTools output:

```bash
flutter-scout attach --debug-url http://127.0.0.1:XXXXX/...
```

Use `ensure` when you want Scout to reuse a running app if possible and launch only when needed:

```bash
flutter-scout ensure --device <simulator-id> --project <flutter-app-path>
```

Launch through Flutter Scout when you intentionally need a new Scout-owned run:

```bash
flutter-scout launch --device <simulator-id> --project <flutter-app-path>
```

Confirm the bridge:

```bash
flutter-scout doctor --project <flutter-app-path> --device <simulator-id>
flutter-scout status
flutter-scout inspect
```

Successful setup means `status` reports running and `inspect` returns visible text, interactables, fields, field geometry, and no setup error.

`ensure`, `launch`, and `attach` report `ready` when they connect to or start a VM service. A `ready:false` response means the VM service is reachable but setup is incomplete; fix the reported `reason` before continuing.

After setup, run `flutter-scout status` when session ownership is unclear. The `hotUpdate` object reports whether reload can use the VM service and whether restart can signal a Scout-owned Flutter run. If Flutter moves the VM service after hot restart, `status` can refresh the stale saved URI from Scout logs or simulator log markers and reports `staleRefreshed:true`. Use `flutter-scout reload` for Dart-only edits and `flutter-scout restart` when Dart state must reset. If `reload` returns `reload_rejected`, the app is still reachable but is likely running previous code. `restart` requires a Scout-owned `ensure` or `launch` process; attach-only sessions can still inspect and act, but cannot signal the Flutter tool for restart. Use the owning Flutter terminal or IDE hot restart when attached to a human-started session.

## Troubleshooting

- `not_attached`: run `attach` or `launch` first.
- `vm_service_uri_not_found`: run the app in debug/profile mode, copy the VM service URL, then use `attach --debug-url`.
- `helper_extension_missing`: the VM service is reachable but Flutter Scout was not registered; add the helper initializer shown in `expected`.
- `helper_extension_check_failed`: retry `status` and `inspect`; if `inspect` works, the app is reachable and the readiness check likely raced startup. If `inspect` fails, relaunch or fix the reported helper initializer.
- `hot_restart_unavailable`: start or reconnect through `flutter-scout ensure --device <simulator-id> --project <path>` so Scout owns the Flutter tool process, or perform a normal relaunch.
- `reload_sources_failed` or `reload_rejected`: VM reload was rejected and the app is likely still running previous code; use the owning Flutter terminal/IDE hot reload, or relaunch/start a Scout-owned `ensure`/`launch` session.
- `vm_reload_unavailable`: the attached session cannot hot reload through VM service; use the owning Flutter terminal/IDE, use a Scout-owned `ensure`/`launch` session, or relaunch after non-Dart changes.
- `helperProtocol.status:"stale_or_old_helper"`: the CLI is newer than the helper extension running inside the attached app. Package/global CLI updates do not change code already loaded in a human-started Flutter process; hot reload/restart or relaunch the app from the owning Flutter terminal or IDE so it loads the updated `flutter_scout_helper`.
- `logs` returns `source:"attach_only_session"` and `available:false`: Scout is attached to a VS Code/Cursor/terminal-owned Flutter run. Scout can inspect and act, but cannot read the owner console logs. Use the owning console, run `flutter logs` separately, or start through `flutter-scout ensure`/`launch` when Scout should own log capture.
- `logs --contains` returns `matched:0`: Scout read a non-empty Scout-owned log, but no line matched the filter. Use a broader filter or add app-side logging for the event you need.
- `staleRefreshed:true`: the saved VM service URL was stale, but Scout discovered and saved the current URI; continue with `inspect` or actions.
- `stale_vm_service_uri` or `staleCleared`: the saved VM service URL was unreachable and Scout could not discover a replacement; run `attach` or `launch` again.
- `device_not_found`: pass an exact device ID or name from `flutter devices`.
- `flutter_scout_helper_not_registered`: add `flutter_scout_helper` and call `FlutterScoutBinding.ensureInitialized()` before `runApp`, or `FlutterScoutHelper.ensureRegistered()` after an existing debug binding.
- `flutter-scout: command not found`: use `dart run bin/flutter_scout.dart` from the CLI package or fix pub global `PATH`.
- No Flutter Scout extensions: confirm `FlutterScoutBinding.ensureInitialized()` runs before `runApp`.
- Scout-owned run still active: run `flutter-scout stop --clear-session`.
- `screenshot_unsupported_target`: no screenshot-capable target is recorded, or the macOS VM service is reachable but Scout cannot find a capturable open app window. For iOS Simulator, attach/launch with the simulator device id. For macOS, attach to the app VM service and keep the app window open and not minimized.
- `crop_unsupported_target`: targeted crops are currently iOS Simulator-only. Use `flutter-scout screenshot -o <path>` for a full macOS app-window capture.
- Simulator screenshot/crop failures: confirm `xcrun simctl` can see the booted simulator and that the session was attached/launched with the iOS Simulator device id.
- macOS screenshot failures: confirm `screencapture` has Screen Recording permission if macOS blocks capture, and that the attached VM service belongs to the visible Flutter `.app` process.

For handoff/debug evidence, run:

```bash
flutter-scout evidence -o /tmp/flutter_scout_evidence
```

It writes status, logs, inspect data when attached, the replay session when present, and a screenshot when the target supports capture.

After setup works, use `$flutter-scout` for the normal inspect/act/replay workflow.
