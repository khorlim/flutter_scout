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

To refresh the normal `flutter-scout` executable from the local checkout after
package changes, use the local activation script. It delegates to Pub's path
activation so commands use the compiled snapshot cache instead of recompiling
the source entrypoint on every invocation:

```bash
/Users/han/flutter_packages/flutter_scout/tool/install-local-shim.sh
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

Use a booted simulator device ID. The app must run in debug mode. Flutter Scout
is a deliberate no-op in normal profile and release builds, even if another
tool exposes a VM service there.

## First Connection

Prefer attaching to an app the human already started:

```bash
flutter-scout attach --device <simulator-id>
```

If attach cannot discover the VM service URL, copy it from Flutter/IDE/DevTools output:

```bash
# Save the URL in an owner-only 0600 file without pasting it into argv.
flutter-scout attach --debug-url-file /private/path/vm-service-url
```

Use `ensure` when you want Scout to reuse a running app if possible and launch only when needed:

```bash
flutter-scout ensure --device <simulator-id> --project <flutter-app-path> --name add-member
```

Named sessions use isolated runtime directories and per-run logs. Concurrent
`ensure` calls for one name join the current build. A second direct `launch`
does not replace a ready run unless you pass `--replace`. Long launches emit a
sanitized heartbeat every 15 seconds so build progress never goes silent.

Launch through Flutter Scout when you intentionally need a new Scout-owned run:

```bash
flutter-scout launch --device <simulator-id> --project <flutter-app-path> --name add-member
```

On macOS, when an outer command temporarily unlocks a signing Keychain, add
`--inherit-launch-context` to `launch` or `ensure` and keep the outer command
alive until Scout reports ready. This bypasses Scout's normal launchd security
context for that run, so it has no launchd crash recovery and will not survive
logout. Do not use it for ordinary builds.

If permanent integration is not appropriate yet, verify with a generated,
zero-diff bootstrap:

```bash
flutter-scout ensure --temporary-helper --device <simulator-id> --project <flutter-app-path> --name add-member
```

Scout durably records private original-file backups and their SHA-256 digests
before dependency resolution, restores `pubspec.yaml` and `pubspec.lock`
immediately, and removes the generated bootstrap on stop. Startup, `status`,
and `doctor` resume an interrupted transaction only when every current digest
matches Scout's exact restore plan. A different user-authored digest is
preserved and returned as a prioritized `temporary_helper_repair` action; do
not delete the repair record or retry setup until that conflict is resolved.
Use `--helper-path <path>` if automatic helper discovery fails.

Always pass `--name <feature>` when running the app — a short kebab-case slug of the feature/task in focus (`add-member`, `supplier-search`), or the current git branch when no single feature is. It registers the session so any later command can target it with `--app <feature>` from any directory, and labels the debug badge so concurrent runs stay distinguishable.

Confirm the bridge:

```bash
flutter-scout doctor --project <flutter-app-path> --device <simulator-id>
flutter-scout status
flutter-scout inspect
flutter-scout version
```

Successful setup means `status` reports running and `inspect` returns a typed
schema/protocol envelope with the expected run/runtime identity, negotiated
capabilities, visible text, interactables, fields, field geometry, and no setup
error.
For exploratory agent loops after setup, `flutter-scout explore --once` prints the persistent daemon command/endpoints without starting it; `flutter-scout explore --port-file /tmp/scout.port` starts the fast loop. While that daemon is active, normal inspect/action CLI commands automatically reuse it.

`ensure`, `launch`, and `attach` report `ready` when they connect to or start a VM service. A `ready:false` response means the VM service is reachable but setup is incomplete; fix the reported `reason` before continuing.

After setup, run `flutter-scout status` when session ownership is unclear. The `hotUpdate` object reports whether reload can use the VM service and whether restart can signal a Scout-owned Flutter run. Scout-owned reload/restart wait for Flutter-tool acknowledgement, and restart requires a new helper runtime before returning. If Flutter moves the VM service after hot restart, `status` refreshes the saved URI. Attach-only sessions can inspect and act but must use VM reload or the owning Flutter terminal/IDE for restart.
From the app project, Scout automatically selects the sole current named
session when no default session exists. If multiple names are current, pass
`--app <name>` so Scout never targets the wrong app.

## Troubleshooting

- `not_attached`: run `attach` or `launch` first.
- `vm_service_uri_not_found`: run the app in debug mode, save the VM service URL to an owner-only 0600 file, then use `attach --debug-url-file`. Scout supports only explicit loopback hosts with an explicit port; remote VM-service egress is unsupported.
- `helper_extension_missing`: the VM service is reachable but Flutter Scout was not registered; add the helper initializer shown in `expected`.
- `helper_extension_check_failed`: retry `status` and `inspect`; if `inspect` works, the app is reachable and the readiness check likely raced startup. If `inspect` fails, relaunch or fix the reported helper initializer.
- `hot_restart_unavailable`: start or reconnect through `flutter-scout ensure --device <simulator-id> --project <path>` so Scout owns the Flutter tool process, or perform a normal relaunch.
- `reload_sources_failed` or `reload_rejected`: VM reload was rejected and the app is likely still running previous code. Check the same named session with `status`; if it remains reachable, preserve it and retry through its Scout-owned Flutter tool or owning terminal. Relaunch only when the app is dead or the change requires rebuilding.
- `vm_reload_unavailable`: the attached session cannot hot reload through VM service; use the owning Flutter terminal/IDE, use a Scout-owned `ensure`/`launch` session, or relaunch after non-Dart changes.
- `helperProtocol.status:"stale_or_old_helper"`: the CLI is newer than the helper extension running inside the attached app. Package/global CLI updates do not change code already loaded in a human-started Flutter process; hot reload/restart or relaunch the app from the owning Flutter terminal or IDE so it loads the updated `flutter_scout_helper`.
- `incompatible_protocol`, `incompatible_schema`, or
  `missing_mutation_capability`: the pair cannot prove the current mutation
  contract. Scout intentionally abstains before dispatch; update both CLI and
  helper and perform a full debug relaunch.
- `mutation_dispatch_outcome_unknown`: transport was lost after dispatch may
  have occurred. Inspect the current state and original postcondition; do not
  retry with a new idempotency key.
- `logs` returns `source:"attach_only_session"` and `available:false`: Scout is attached to a VS Code/Cursor/terminal-owned Flutter run. Scout can inspect and act, but cannot read the owner console logs. Use the owning console, run `flutter logs` separately, or start through `flutter-scout ensure`/`launch` when Scout should own log capture.
- `logs --contains` returns `matched:0`: Scout read a non-empty Scout-owned log, but no line matched the filter. Use a broader filter or add app-side logging for the event you need.
- `staleRefreshed:true`: the saved VM service URL was stale, but Scout discovered and saved the current URI; continue with `inspect` or actions.
- `missingVmServiceUriRestored:true`: the URI file was missing, but Scout recovered it from the verified owned run log and kept the existing app.
- `session_selection_required`: more than one named session exists in this project; rerun with `--app <name>`.
- `stale_vm_service_uri` or `staleCleared`: the saved VM service URL was unreachable and Scout could not discover a replacement; run `attach` or `launch` again.
- `device_not_found`: pass an exact device ID or name from `flutter devices`.
- `flutter_scout_helper_not_registered`: add `flutter_scout_helper` and call `FlutterScoutBinding.ensureInitialized()` before `runApp`, or `FlutterScoutHelper.ensureRegistered()` after an existing debug binding.
- `flutter-scout: command not found`: use `dart run bin/flutter_scout.dart` from the CLI package or fix pub global `PATH`.
- No Flutter Scout extensions: confirm `FlutterScoutBinding.ensureInitialized()` runs before `runApp`.
- Scout-owned run still active: run `flutter-scout stop --clear-session`.
- `unsupported_capability` for native screenshot/deeplink: Scout could not prove an exact supported emulator and reachable platform tool before dispatch. Attach/launch with the exact iOS Simulator or Android Emulator device id; confirm `xcrun simctl` or `adb -s <id> get-state` can see it. Physical devices remain experimental. The same code is used when a macOS VM service is reachable but no capturable open app window is proven.
- `crop_unsupported_target`: the requested crop contains a platform view and no native crop backend is available. Normal in-app targeted crops work on macOS; use `flutter-scout screenshot -o <path>` when a platform view needs a full native macOS window capture.
- `native_crop_coordinate_frame_mismatch`: the native PNG size does not exactly match the scoped Flutter physical viewport (for example because of system chrome, insets, rotation, or letterboxing). Do not guess an offset; use in-app capture or inspect the full native screenshot.
- Simulator screenshot/crop failures: confirm `xcrun simctl` can see the exact booted iOS Simulator or `adb -s <id> get-state` returns `device` for the exact Android Emulator recorded by the session.
- macOS screenshot failures: confirm `screencapture` has Screen Recording permission if macOS blocks capture, and that the attached VM service belongs to the visible Flutter `.app` process.

For handoff/debug evidence, run:

```bash
flutter-scout evidence -o /private/path/flutter_scout_evidence \
  --retention session
```

It writes status, logs, inspect data when attached, the replay session when present, and a screenshot when the target supports capture.

After setup works, use `$flutter-scout` for the normal inspect/act/replay workflow.
