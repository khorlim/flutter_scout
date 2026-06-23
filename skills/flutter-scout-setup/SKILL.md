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

Launch through Flutter Scout when no app is running:

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

`launch` and `attach` also report `ready`. A `ready:false` response means the VM service is reachable but setup is incomplete; fix the reported `reason` before continuing.

## Troubleshooting

- `not_attached`: run `attach` or `launch` first.
- `vm_service_uri_not_found`: run the app in debug/profile mode, copy the VM service URL, then use `attach --debug-url`.
- `helper_extension_missing`: the VM service is reachable but Flutter Scout was not registered; add the helper initializer shown in `expected`.
- `helper_extension_check_failed`: retry `status` and `inspect`; if `inspect` works, the app is reachable and the readiness check likely raced startup. If `inspect` fails, relaunch or fix the reported helper initializer.
- `stale_vm_service_uri` or `staleCleared`: the saved VM service URL was unreachable; run `attach` or `launch` again.
- `device_not_found`: pass an exact device ID or name from `flutter devices`.
- `flutter_scout_helper_not_registered`: add `flutter_scout_helper` and call `FlutterScoutBinding.ensureInitialized()` before `runApp`, or `FlutterScoutHelper.ensureRegistered()` after an existing debug binding.
- `flutter-scout: command not found`: use `dart run bin/flutter_scout.dart` from the CLI package or fix pub global `PATH`.
- No Flutter Scout extensions: confirm `FlutterScoutBinding.ensureInitialized()` runs before `runApp`.
- Scout-owned run still active: run `flutter-scout stop --clear-session`.
- Simulator screenshot/crop failures: confirm `xcrun simctl` can see the booted simulator.

After setup works, use `$flutter-scout` for the normal inspect/act/replay workflow.
