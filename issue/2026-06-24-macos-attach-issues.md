# Flutter Scout Issues From macOS Attach Session

Context:
- Project under test: `/Users/han/flutter_projects/tunaipro`
- Attached app: macOS Flutter app, package `tunaipro`
- VM service: `ws://127.0.0.1:52158/00pTPy7QdhU=/ws`
- Flutter run process: `flutter run --machine --start-paused -d macos`
- Session screen reported by Scout: `MRecordScreen`

## ~~1. `reload` reports failure even though the app remains inspectable~~

Resolution: fixed. VM reload fallback now includes `reloadReport`, `appReachable`, `state`, and `result:"reload_rejected"` when `reloadSources` fails while the app remains inspectable.

Command:

```sh
flutter-scout reload
```

Observed:

```json
{
  "ok": false,
  "action": "reload",
  "method": "vm_service_reload_sources",
  "result": "unchanged",
  "error": {
    "code": "reload_sources_failed",
    "message": "VM service reloadSources reported failure."
  }
}
```

The command exited with code `1`, but the response still included a valid before/after screen snapshot and `recentErrors: []`.

Expected:
- If reload fails, explain whether the running app still has the old code or whether the reload was simply a no-op.
- Distinguish `unchanged` from a true reload failure.
- Include the VM service error details returned by `reloadSources`, if available.

Why it matters:
- During bug verification, it is unclear whether the attached session is running the latest local Dart changes.

## ~~2. `screenshot` captures the iOS Simulator home screen while attached to macOS app~~

Resolution: fixed as unsupported-target behavior. Screenshot/crop now require an iOS Simulator session and return `screenshot_unsupported_target` for macOS attach instead of capturing a different simulator.

Commands:

```sh
flutter-scout status
flutter-scout inspect --summary
flutter-scout screenshot -o /tmp/tunaipro-mrecord-macos.png
```

Observed:
- `status` reported the macOS VM service.
- `inspect` reported the macOS app screen: `MRecordScreen`.
- `screenshot` produced an image of the iOS Simulator home screen instead of the attached macOS app window.

Expected:
- `screenshot` should capture the currently attached Flutter target.
- If screenshots are not supported for macOS attach sessions, the command should fail with a clear unsupported-target message instead of capturing a different device.

Why it matters:
- It creates false visual evidence. Inspect says one app is attached, but screenshot shows another app/device.

## ~~3. `tap-text` can return `ok: true` without activating anything~~

Resolution: fixed. `tap-text` now activates the nearest actionable ancestor, returns `target`, `textTarget`, and `activation`, and returns `text_not_actionable` when no actionable ancestor exists.

Command:

```sh
flutter-scout tap-text "Edit Form"
```

Observed:
- Returned `ok: true`.
- `result: "unchanged"`.
- The UI did not change.
- No actionable warning was reported.

Expected:
- If the text node is not actionable, tap the nearest actionable ancestor.
- Or return a warning/error that the matched text was not itself tappable and no actionable parent was found.

Why it matters:
- A successful command result is misleading when it does not actually activate the visible UI.

## ~~4. Text target found by `tap-text` is not addressable by `bounds`~~

Resolution: fixed. Inspect now includes `textTargets`, and `bounds`/`crop` can resolve those text target ids.

Commands:

```sh
flutter-scout tap-text "Edit Form"
flutter-scout bounds "text.edit_form"
```

Observed:
- `tap-text` reported target id `text.edit_form`.
- `bounds "text.edit_form"` then failed:

```json
{
  "ok": false,
  "error": {
    "code": "target_not_found",
    "message": "No inspect target matched `text.edit_form`."
  }
}
```

Expected:
- Target ids emitted by one command should be usable by related commands where possible.
- If text targets are intentionally excluded from `bounds`, document that in the command response or help text.

Why it matters:
- It prevents the normal inspect -> bounds -> tap debugging flow.

## ~~5. Coordinate tap syntax failure is not self-correcting~~

Resolution: fixed. `tap <x> <y>` is accepted as coordinate shorthand, and multi-argument misuse returns coordinate-specific usage guidance.

Command:

```sh
flutter-scout tap 1036 589
```

Observed:

```json
{
  "ok": false,
  "error": {
    "code": "target_not_found",
    "message": "No tappable target matched `1036`."
  }
}
```

Expected:
- Either accept `tap x y` as a coordinate shorthand, or return a targeted hint:

```text
For coordinates, use: flutter-scout tap --x 1036 --y 589
```

Why it matters:
- The current error makes it look like Scout tried to resolve a widget target named `1036`, which is technically true but not helpful.

## ~~6. App bar controls are missing or not discoverable in `inspect`~~

Resolution: fixed for the valid generic cases. Button text, keys, tooltips, and `tap-text` actionable ancestors are exposed as stable inspect targets; unlabeled icon-only controls still need app tooltips/keys for meaningful labels.

Screen state:
- Real macOS window showed app bar controls including back/search/add and an edit/create form header.
- Code path includes app bar actions such as duplicate and save buttons in `EditMRecordScreen` / `CreateMRecordScreen`.

Command:

```sh
flutter-scout inspect | jq '.interactables[] | {id,label,key,widgetType,rect,visibleFraction,hitTestable,enabled}'
```

Observed:
- Inspect mostly returned form rows, backdrop cells, tags, and text fields.
- The app bar action buttons were not exposed with useful labels or stable targets.
- A coordinate tap against the expected app bar action area returned `ok: true` but `result: "unchanged"`.

Expected:
- App bar buttons should appear as interactables with labels/tooltips/keys where available.
- `TextButt(text: t.save)` should be exposed as a tappable target with text/label `Save`.
- `IconButt` actions should expose icon semantics, tooltip, key, or at least stable app-bar action ordinals.

Why it matters:
- It blocks reliable automation of save/create flows without falling back to fragile coordinate taps.

## ~~7. Visual and semantic state can diverge during macOS attach testing~~

Resolution: fixed as target validation. Screenshot/crop validate the recorded target and refuse unsupported macOS sessions instead of returning visual evidence from a different backend.

Observed:
- Scout semantic inspection reported a stable `MRecordScreen` with fields and values.
- Scout screenshot showed the wrong device.
- Native macOS screencapture showed the real Tunaipro window and confirmed the form screen visually.

Expected:
- Scout should provide a single consistent view of the attached target.
- If screenshots are delegated to a different backend than VM inspection, the target identity should be validated before returning success.

Why it matters:
- It makes test conclusions uncertain unless the operator cross-checks with OS-level screenshots.

## ~~8. Save coordinate tap returned `unchanged` even though it executed~~

Resolution: fixed. Gesture actions that dispatch successfully but do not observe a synchronous UI change now return `activated_no_observed_change` plus `activation` and `warnings`.

Command:

```sh
flutter-scout tap --x 1068 --y 28
```

Observed:
- Scout returned `ok: true`, `stable: true`, and `result: "unchanged"`.
- The app did execute the `Save` action.
- An async error dialog appeared after the command returned:
  - `Something Went Wrong`
  - `An error occured. Please try again later.`
- OS-level screenshot and the IDE console confirmed the failed save request.

Expected:
- A tap that triggers an async UI state change should either wait long enough to observe the dialog, or report that the tap target was activated but no synchronous tree change was detected.
- `result: "unchanged"` is misleading when the action did run.

Why it matters:
- It can cause the tester to retry or tap other controls even though a mutation request is already in flight.

## ~~9. Alert dialog text is visible, but `overlays` remains empty~~

Resolution: fixed. `inspect` now reports dialog and bottom-sheet overlay entries.

Command:

```sh
flutter-scout inspect --summary
```

Observed:
- `visibleText` included:
  - `Something Went Wrong`
  - `An error occured. Please try again later.`
  - `OK`
- `overlays` was still `[]`.

Expected:
- Modal dialogs should be represented in `overlays`, or there should be a separate modal/dialog section.

Why it matters:
- Agents cannot reliably distinguish a blocked modal state from normal screen text.

## ~~10. `tap-text "OK"` does not dismiss the alert~~

Resolution: fixed for the generic cause. `tap-text` activates dialog button ancestors, and short labels like `OK` must match exactly so they do not hit unrelated containing text.

Command:

```sh
flutter-scout tap-text "OK"
```

Observed:
- Returned `ok: true`, `result: "unchanged"`.
- The alert stayed open.
- Coordinate tap against the dialog button worked:

```sh
flutter-scout tap --x 550 --y 359
```

Expected:
- `tap-text "OK"` should activate the dialog button, or return a clear error that the text node is not actionable.

Why it matters:
- Common modal recovery actions require fragile coordinates.

## ~~11. Scout logs are empty while the attached debug console has the failure~~

Resolution: fixed as explicit limitation. `logs` now reports `available:false` with an attach-only/empty-log explanation when Scout does not own the Flutter tool output.

Command:

```sh
flutter-scout logs --last 80
```

Observed:

```json
{
  "ok": true,
  "path": "/Users/han/flutter_projects/tunaipro/.flutter_scout/logs.txt",
  "lines": []
}
```

At the same time, the IDE debug console showed the failed create request, including the validation failure and payload with `templateLocationId: 0`.

Expected:
- Scout logs should capture Flutter app logs/errors from the attached VM service, or report that log collection is unavailable for attach-only sessions.

Why it matters:
- The app failure could not be diagnosed from Scout output alone.

## ~~12. Attach-only session cannot be restarted, leaving no fallback when reload fails~~

Resolution: fixed as clearer fallback guidance. Attach-only restart output now includes `attachOnly`, `vmServiceUri`, `vmServiceListenerPid`, and next actions for using the owning Flutter terminal/IDE or a Scout-owned run.

Command:

```sh
flutter-scout restart
```

Observed:

```json
{
  "ok": false,
  "method": "unavailable_without_scout_owned_flutter_run",
  "error": {
    "code": "hot_restart_unavailable",
    "message": "Hot restart requires a Scout-owned flutter run process. Attach-only sessions can inspect and act, but cannot restart the Flutter tool process."
  }
}
```

This behavior is understandable, but combined with `reload` returning `reload_sources_failed`, Scout has no way to get local Dart fixes into the current attached macOS session.

Expected:
- Provide a stronger attach-mode fallback, such as:
  - explain how to trigger hot reload through the owning Flutter tool process when discoverable,
  - surface the owning process/terminal details,
  - or clearly state that the session is stale and must be relaunched by the owner.

Why it matters:
- In this session, the source fix existed locally, but the attached app still submitted the old payload with `templateLocationId: 0`.

## ~~13. Verbose reload does not add useful reload failure diagnostics~~

Resolution: fixed. Reload failure output now prioritizes VM reload status, app reachability, and stale-code guidance; compact output also preserves the useful diagnostics.

Command:

```sh
flutter-scout reload --verbose
```

Observed:
- Output was extremely large because it included full before/after inspect payloads.
- It still only reported:

```json
{
  "error": {
    "code": "reload_sources_failed",
    "message": "VM service reloadSources reported failure."
  }
}
```

Expected:
- Verbose reload should prioritize the VM service reload error details and compiler messages.
- Full UI snapshots should be optional or summarized when reload itself fails.

Why it matters:
- The extra output does not help determine whether the app failed to compile, rejected reload, or simply had no updated sources.
