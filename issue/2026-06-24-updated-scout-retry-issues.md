# Flutter Scout Issues After Updated Package Retry

Context:
- Project under test: `/Users/han/flutter_projects/tunaipro`
- Attached app: macOS Flutter app, package `tunaipro`
- VM service: `ws://127.0.0.1:52158/00pTPy7QdhU=/ws`
- Retry happened after the Flutter Scout package was updated.

## ~~1. Close-button tap reported stale screen state~~

Resolution: fixed. Tap actions now poll briefly when the first post-action snapshot is unchanged, and report `lateChangeObserved:true` when a delayed route/modal/overlay change is captured in `afterSummary`.

Command:

```sh
flutter-scout tap 31 31
```

Observed:
- The WhatsApp overlay closed in the real app.
- Scout returned `ok: true`, `result: "unchanged"`.
- Scout `afterSummary.screen` still reported `WhatsAppScreen`.
- A later command showed the app was already on `HomeScreen`.

Expected:
- If the tap closes a modal/overlay, Scout should report a screen/text delta or at least the correct post-action screen.
- If the UI transition finishes after the normal wait, Scout should expose a wait timeout / late-change warning.

Why it matters:
- The agent continued as if the overlay was still open even though the user could see it was closed.

## ~~2. `tap-text "Member"` still reports success without activating the parent tile~~

Resolution: fixed. Current helper behavior still activates nearest actionable ancestors; the CLI now also detects stale helper responses that return raw text targets and retries against the best overlapping actionable inspect target when possible.

Command:

```sh
flutter-scout tap-text "Member" --verbose
```

Observed:
- Scout returned `ok: true`, `result: "unchanged"`.
- The target was the raw text node:

```json
{
  "id": "text.member",
  "kind": "text",
  "widgetType": "Text",
  "hitTestable": true
}
```

- The Member screen did not open.

Expected:
- Per updated skill guidance, `tap-text` should activate the nearest actionable ancestor, or return `text_not_actionable`.

Why it matters:
- Visible text navigation still requires fragile coordinate taps.

## ~~3. `inspect` does not expose `textTargets`~~

Resolution: fixed. Current helper output includes `textTargets`; the CLI now warns with `helperProtocol.status:"stale_or_old_helper"` and injects an empty `textTargets` key when an attached app is still running an older helper protocol.

Command:

```sh
flutter-scout inspect
```

Observed:
- The updated skill says `inspect` includes `textTargets`.
- The actual inspect output had no `textTargets` key.

Expected:
- Either include `textTargets` in inspect output, or update the skill/docs to match the installed CLI.

Why it matters:
- The documented workflow for text target discovery cannot be followed.

## ~~4. CLI help still documents old coordinate tap syntax~~

Resolution: fixed. CLI help now documents `tap <x> <y>` alongside `tap <target>` and `--x/--y`.

Command:

```sh
flutter-scout --help
```

Observed:
- Help still says:

```text
flutter-scout tap <target> | --x <x> --y <y> [--verbose]
```

- Updated skill says coordinate shorthand is supported:

```sh
flutter-scout tap 1036 589
```

Expected:
- Help output should include the supported coordinate shorthand if the CLI accepts it.

Why it matters:
- The skill and CLI help disagree, making it unclear which command form is canonical.

## ~~5. macOS attach screenshot is unsupported instead of capturing the app~~

Resolution: fixed. macOS app-window screenshots are now supported by resolving the attached VM service listener process to its CoreGraphics window and capturing that window with `screencapture -l`. Targeted macOS crops remain unsupported and return `crop_unsupported_target`.

Command:

```sh
flutter-scout screenshot -o /tmp/tunaipro-scout-screenshot-retry.png
```

Observed:

```json
{
  "ok": false,
  "error": {
    "code": "screenshot_unsupported_target",
    "message": "No simulator device is recorded for this session. Attach with --device <ios-simulator-id> or launch/ensure through Flutter Scout before taking screenshots."
  }
}
```

This is better than the previous behavior where Scout captured the wrong iOS Simulator screen. Scout now captures the attached macOS Flutter app window for full screenshots.

Expected:
- Scout should capture the attached macOS Flutter app window, independent of which desktop app the user is currently viewing.
- If macOS screenshots are intentionally unsupported, the message should mention macOS explicitly and not suggest only iOS Simulator attachment.

Why it matters:
- The user may be looking at Codex or another app while testing. Scout screenshots should be app-targeted, not dependent on the currently focused desktop window.
