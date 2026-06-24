# 2026-06-24 fresh macOS form retest

## Context
- App: Tunaipro macOS
- App path: `/Users/han/flutter_projects/tunaipro`
- Flutter Scout package: `/Users/han/flutter_packages/flutter_scout`
- Command used: `flutter-scout ensure --device macos --project /Users/han/flutter_projects/tunaipro`
- Scout launched a fresh macOS Flutter run and reported:

```json
{
  "launched": true,
  "ready": true,
  "device": "macos",
  "vmServiceUri": "ws://127.0.0.1:53970/TgUeGN1vWuU=/ws",
  "logFile": "/Users/han/flutter_projects/tunaipro/.flutter_scout/logs.txt"
}
```

## Direct retest flow after fixing Scout

Use this exact flow to verify the reported Scout problems:

1. Launch Tunaipro through Scout:

   ```bash
   cd /Users/han/flutter_projects/tunaipro
   flutter-scout ensure --device macos --project /Users/han/flutter_projects/tunaipro
   flutter-scout inspect --summary
   ```

2. On `HomeScreen`, open the member area:

   ```bash
   flutter-scout tap-text "Member" --verbose
   ```

   Expected after Scout fix: the command should activate the Member tile/card, not the full-screen outlet detector.

3. On `MemberListScreen`, use member `DEEDEE` / `•••••••0102`.

4. Open the form feature from the member details pane:

   ```bash
   flutter-scout tap-text "Form" --verbose
   ```

   If the form section is below the fold, first scroll the member details pane. Expected after Scout fix: scroll direction/result should be clear and `tap-text "Form"` should either tap the right actionable parent or provide an actionable target.

5. On `MRecordScreen`, select the existing `Hair Recovery` record from the left list. This is the key record for retesting because it has backdrop numbered locations `1` to `6`.

   ```bash
   flutter-scout tap-text "Hair Recovery" --verbose
   ```

6. Duplicate the selected form:

   ```bash
   flutter-scout tap btn.duplicate --verbose
   ```

   Expected after Scout fix: this should work without coordinate taps. In the failing run, only `flutter-scout tap 1072 28 --verbose` worked.

7. Enter a title and save:

   ```bash
   flutter-scout input --target field.enter_title "Scout macos hair recovery 2026-06-24" --verbose
   flutter-scout tap btn.save --verbose
   ```

8. If the app shows the generic error dialog, capture diagnostics:

   ```bash
   flutter-scout screenshot -o /tmp/tunaipro-fresh-macos-hair-recovery-error.png
   flutter-scout logs --last 300 --contains "validation"
   flutter-scout logs --last 300 --contains "templateLocationId"
   flutter-scout tap-text "OK" --verbose
   ```

   Expected after Scout fix:
   - screenshot should capture the Tunaipro macOS app window;
   - logs should read `.flutter_scout/logs.txt` for this Scout-owned run, or explain accurately why app logs are unavailable;
   - `tap-text "OK"` should dismiss the dialog without coordinates.

## Form retest result
- Started from `HomeScreen`.
- Navigated to `MemberListScreen`.
- Opened `MRecordScreen`.
- Selected the `Hair Recovery` form record, which has backdrop numbered locations `1` to `6`.
- Duplicated it into `New Form`.
- Entered title: `Scout macos hair recovery 2026-06-24`.
- Saved with `flutter-scout tap btn.save --verbose`.
- App showed generic error dialog:
  - `Something Went Wrong`
  - `An error occured. Please try again later.`

Scout did not expose the underlying API/server validation details. The test confirms the UI save still fails in the fresh macOS run, but does not prove whether the backend failure is still `templateLocationId: 0`.

## Verification After Scout Fix

Retested the same Tunaipro macOS flow with the local Flutter Scout changes before pushing:

- `tap-text "Member"` opened `MemberListScreen` and reported `screenChanged:true` with `activation.strategy:"broad_ancestor_text_point"`.
- `scroll down --from 700,500 --distance 650 --verbose` exposed `Form`, included `gestureStart`/`gestureEnd`, and reported `newText:["Form"]`.
- `tap-text "Form"` opened `MRecordScreen` using `activation.strategy:"visible_text_point"`.
- `tap-text "Hair Recovery"` selected the record with backdrop locations `1` to `6`.
- `tap btn.duplicate --verbose` worked without coordinates and targeted the duplicate glyph at `[1072,28]`.
- `tap btn.save --verbose` showed the same generic app error dialog.
- `screenshot -o /tmp/tunaipro-fresh-macos-hair-recovery-error-after-fix.png` captured the Tunaipro macOS window with `backend:"macos_window"`.
- `logs --contains "validation"` and `logs --contains "templateLocationId"` returned `available:true`, `matched:0`, and the no-lines-matched message.
- `tap-text "OK" --verbose` dismissed the dialog using `activation.strategy:"visible_text_point"`.

Remaining app result: saving the duplicated Hair Recovery form still shows the generic error dialog, and the Scout-owned Flutter log does not include backend validation details for that failure.

## New / remaining Flutter Scout issues

### ~~1. `screenshot` fails in Scout-owned macOS run~~

Resolution: fixed. macOS window discovery now tries the VM listener PID, the Scout-owned Flutter run PID, and their descendant app PIDs before reporting `screenshot_unsupported_target`. This covers Scout-owned macOS launches where the capturable app window is not owned by the VM listener PID directly.

After `ensure --device macos` launched the app successfully, this failed:

```bash
flutter-scout screenshot -o /tmp/tunaipro-fresh-macos-hair-recovery-error.png
```

Output:

```json
{
  "ok": false,
  "error": {
    "code": "screenshot_unsupported_target",
    "message": "No capturable macOS app window was found for `macOS`. Make sure the app window is open and not minimized."
  }
}
```

Impact: inspect/actions work through the VM service, but Scout cannot capture visual proof in a fresh Scout-owned macOS session. Previous attach-only testing did capture the Tunaipro window, so this appears specific to Scout-owned macOS launch/window discovery.

### ~~2. `flutter-scout logs` reports unavailable even though log file exists~~

Resolution: fixed. `logs --contains <text>` now keeps `available:true` for a non-empty Scout-owned log and reports `matched:0` with a no-lines-matched message when the filter has no hits. It no longer labels that case as attach-only or unavailable.

Scout launch reported:

```text
/Users/han/flutter_projects/tunaipro/.flutter_scout/logs.txt
```

The file exists and contains Flutter run output:

```bash
ls -l /Users/han/flutter_projects/tunaipro/.flutter_scout/logs.txt
```

But:

```bash
flutter-scout logs --last 300 --contains "validation"
```

returned:

```json
{
  "ok": true,
  "available": false,
  "source": "attach_only_or_empty_scout_log",
  "message": "No Scout-owned Flutter tool output has been captured for this session. Attach-only sessions cannot read the owning terminal or IDE console logs.",
  "lines": []
}
```

Impact: The session is Scout-owned, not attach-only, and the log file exists. The CLI should read the file or give a more accurate reason. This blocks confirming the API validation error behind the generic form save dialog.

### ~~3. Scout-owned log file did not include the form save API failure~~

Resolution: intentionally handled as an app logging boundary. Scout can read the Flutter tool stdout/stderr it owns, but it cannot show an API/server error that the app does not print to that stream. The docs now distinguish `available:false` from `available:true, matched:0`; if the log is available but the error is absent, the app needs broader logging or an app-side diagnostic hook for that failure.

Directly reading `.flutter_scout/logs.txt` showed launch output, member navigation logs, and a render overflow, but no form-save API error after the save dialog appeared.

Searches returned no matches:

```bash
rg -n "validation|templateLocationId|Failed to create m record|Tunai Error|Default error|create m record|member record" .flutter_scout/logs.txt
```

Impact: Even with a Scout-owned macOS run, the agent cannot inspect the underlying API/server error from Scout logs.

### ~~4. Icon-only toolbar aliases still do not resolve~~

Resolution: fixed. Scout now derives stable labels from common Material icon widgets, common Material glyph text controls, and the observed Tunaipro toolbar glyphs. Target matching still accepts kind-prefixed guesses, so `btn.duplicate` can resolve to a custom tappable or glyph text target.

On `MRecordScreen`, the duplicate toolbar action was visible as a glyph text target, but these failed:

```bash
flutter-scout tap btn.duplicate --verbose
flutter-scout tap btn.copy --verbose
flutter-scout tap btn.clone --verbose
flutter-scout tap icon.duplicate --verbose
flutter-scout tap btn.back --verbose
```

Example output:

```json
{
  "ok": false,
  "error": {
    "code": "target_not_found",
    "message": "No tappable target matched `btn.duplicate`."
  }
}
```

The test had to use coordinate taps:

```bash
flutter-scout tap 1072 28 --verbose
flutter-scout tap 328 28 --verbose
```

Impact: The updated skill recommends `btn.duplicate`, `btn.back`, etc., but the CLI/helper still cannot discover those icon-only toolbar controls in this app. This keeps replay fragile.

### ~~5. Visible dialog/text targets sometimes have no actionable ancestor~~

Resolution: fixed. `tap-text` now falls back to a hit-testable visible text point when no actionable ancestor is exposed. It also uses the text point instead of a broad ancestor center when the nearest actionable ancestor is much larger than the matched text.

Examples:

```bash
flutter-scout tap-text "OK" --verbose
```

returned:

```json
{
  "ok": false,
  "error": {
    "code": "text_not_actionable",
    "message": "Text `OK` is visible, but no actionable ancestor was found."
  }
}
```

The agent had to inspect the text target and tap the suggested point:

```bash
flutter-scout tap 550 359 --verbose
```

Impact: Dialog confirmation buttons should be actionable through `tap-text`, especially for common labels like `OK`.

### ~~6. Home/member navigation target selection is still inefficient~~

Resolution: fixed for the broad-ancestor class of failures. `tap-text` now avoids tapping the center of very large actionable ancestors and instead taps the matched text point, which is safer for nested cards inside broad gesture regions.

From `HomeScreen`, `tap-text "Member"` and `tap-text "•••••••6197"` matched the text but activated the full-screen outlet gesture detector (`tap.outlet_6937`) and reported no observed change.

The member page did eventually open after coordinate/gesture attempts, but the action reporting was confusing: one later coordinate tap reported `activated_no_observed_change` while the `before` summary was already `MemberListScreen`.

Impact: On screens with broad parent gesture detectors and nested cards, Scout should prefer the smallest actionable ancestor or expose better card targets.

### ~~7. Scroll direction/result reporting was confusing~~

Resolution: fixed. Drag commands now return `result:"navigated"` when the gesture changes screens and include `gestureEnd` alongside `gestureStart`, making it clearer when a gesture caused navigation rather than an ordinary scroll.

On `MemberListScreen`, trying to access the form section:

```bash
flutter-scout scroll down --from 700,500 --distance 650 --verbose
flutter-scout scroll down --from 700,300 --distance 700 --verbose
```

reported `unchanged`.

This command moved into the form screen:

```bash
flutter-scout scroll up --from 700,500 --distance 650 --verbose
```

but the command result was reported as a scroll/geometry change on `MRecordScreen`, not as a clear navigation/tap transition.

Impact: Direction semantics and result reporting make it hard to reason about whether the gesture scrolled, tapped a visible affordance, or triggered navigation.

## App issue observed during Scout run

The fresh macOS log captured a Flutter render overflow:

```text
A RenderFlex overflowed by 3.0 pixels on the bottom.
Column:file:///Users/han/flutter_projects/tunaipro/lib/general_module/member_module/member_detail_screen/widget/member_data_summary_widget/member_remark_widget.dart:157:20
```

This appears to be an app layout issue, not a Scout issue, but it was observed during the Scout-owned macOS run.
