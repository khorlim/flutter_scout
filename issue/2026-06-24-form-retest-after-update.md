# 2026-06-24 form retest after Flutter Scout update

## Context
- App: Tunaipro macOS
- Attach VM service: `ws://127.0.0.1:52158/00pTPy7QdhU=/ws`
- Flow tested: Member page -> Form -> duplicate existing form -> save new form
- Screenshot captured by Scout: `/tmp/tunaipro-form-save-error.png`

## What improved
- `flutter-scout screenshot` now captures the Tunaipro app window in the attach-only macOS session.
- The screenshot backend reported `backend: macos_window`, `ownerName: tunaipro`, and the resulting image showed the app, not Codex.
- `tap-text "Form"` and `tap-text "Save"` were able to drive the app in this session.

## Remaining issues / limitations

### ~~1. Attached app still reports stale helper protocol after package update~~

Resolution: intentionally handled as expected attach-only behavior. Updating the package and global CLI cannot change code already loaded in a human-started Flutter process. Scout already reports `helperProtocol.status:"stale_or_old_helper"` and next actions; the running app must hot restart/relaunch from the owning Flutter terminal or IDE before new helper protocol features are available.

`flutter-scout inspect --summary` still reported:

```json
{
  "helperProtocol": {
    "status": "stale_or_old_helper",
    "missing": ["textTargets"],
    "nextBestActions": [
      "Run flutter-scout reload",
      "If reload does not update helper behavior, hot restart from the owning Flutter terminal or relaunch the app"
    ]
  }
}
```

Running `flutter-scout reload` was rejected:

```json
{
  "ok": false,
  "state": "reload_rejected_running_app_still_available_with_previous_code",
  "result": "reload_rejected"
}
```

Impact: Scout can still inspect and tap the app, but it cannot guarantee the attached app is running the latest helper protocol or latest app code without a hot restart/relaunch from the owning Flutter terminal.

### ~~2. Attach-only logs cannot expose the API failure details~~

Resolution: intentionally handled as an attach-only ownership boundary. Scout can read logs for Scout-owned `launch`/`ensure` sessions, but it cannot read another terminal or IDE's stdout/stderr from an attached VM service. The skills/docs now emphasize using the owning Flutter terminal or IDE console when `logs` reports `available:false`.

The form save displayed the generic app error dialog:

- `Something Went Wrong`
- `An error occured. Please try again later.`

But `flutter-scout logs --last 200 --contains "validation"` returned:

```json
{
  "ok": true,
  "available": false,
  "source": "scout_owned_flutter_run",
  "message": "No Scout-owned flutter run log file exists. Attach-only sessions cannot read the owning terminal or IDE console logs.",
  "lines": []
}
```

Impact: In an attach-only session, Scout can confirm the UI failure, but cannot show the underlying API/server validation message from the owning Flutter terminal. This makes it hard to distinguish a stale-app failure from a real backend validation failure.

### ~~3. Icon-only toolbar actions forced coordinate tapping~~

Resolution: fixed. Scout now derives stable labels from common Material icon glyphs in icon-only controls, including add, back, save, duplicate, delete, download, search, close, edit, and more. Target matching is also tolerant of kind prefixes, so a custom tappable icon exposed as `tap.duplicate` can still be targeted with `btn.duplicate` when that is the agent's natural guess.

The duplicate form action had to be triggered with a coordinate tap:

```bash
flutter-scout tap 1070 31 --verbose
```

This worked, but it is inefficient and fragile. The duplicate button is an icon-only toolbar action, and the attached helper did not expose a stable semantic/actionable target for it. A better Scout loop should allow something like:

```bash
flutter-scout tap btn.duplicate_form
flutter-scout tap icon.duplicate
```

Impact: Coordinate taps depend on the current window size, toolbar layout, and macOS title-bar offset. They are harder to replay safely and make agent testing slower because the agent must inspect screenshots or infer positions.

Suggested improvement: expose stable target handles for icon-only controls, either through Flutter `Key`s, `Semantics` labels, tooltips, or Scout-side icon/action discovery. For Tunaipro form testing, important toolbar actions should have stable handles for add, back, save, duplicate, delete, and download.

## Form retest result
- Navigated to `MRecordScreen`.
- Duplicated the existing `Hair Recovery` form into `New Form`.
- Entered title: `Scout backdrop test 2026-06-24`.
- Tapped `Save`.
- App showed the generic error dialog.
- Because the running app was stale and attach-only logs were unavailable, this test could not conclusively verify whether the previously fixed `templateLocationId: 0` payload issue is still present in the latest code.
