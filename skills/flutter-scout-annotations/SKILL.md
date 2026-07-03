---
name: flutter-scout-annotations
description: Work through the annotation pins a human left on a running Flutter app with Flutter Scout — read each flagged widget, fix it in code, verify the fix on the simulator, then clear only the pins you actually resolved. Use this whenever the user says the app has been annotated, asks you to "check/handle/address/action the annotations (or Scout pins/review markers/comments)", says they tapped "Send to agent", or asks you to fix and clear annotations after fixing. Reach for it even if they don't name Flutter Scout, as long as the request is about acting on annotation pins on a running app.
---

# Flutter Scout: fix & clear annotations

A human reviewed the running app, dropped **annotation pins** on widgets that need work, and handed them to you. Each pin carries a comment, a screenshot of the flagged widget (the "before" crop), and metadata locating it. Your job is a tight, honest loop:

```text
collect pins -> understand each -> fix in code -> reload -> verify -> mark fixed (captures after) -> delete only what you fixed -> report
```

This skill is the **procedure and policy** for that loop. It assumes a Scout session is already attached — for attach/launch/inspect/act/reload mechanics and the full command surface, use the **flutter-scout** skill (and **flutter-scout-setup** if nothing is running yet). Run commands as `flutter-scout <cmd>` (or `dart run bin/flutter_scout.dart <cmd>` from `packages/flutter_scout`), adding `--app <name>` to address a named session.

## 1. Collect the pins

If the user has been annotating live, block on the handoff instead of polling — this returns the moment they tap **"Send to agent"**:

```bash
flutter-scout annotations wait --timeout 600 --poll 1000
```

Otherwise just read the current set:

```bash
flutter-scout annotations list
```

Both materialize the crops under `.flutter_scout/crops/` and attach `beforeCropPath` to each pin. **Read that image for every pin** — comments like "too wide", "wrong colour", "misaligned" only make sense visually, and the crop is exactly what the reviewer saw.

## 2. Understand each pin

Each annotation gives you everything needed to locate the widget in code without guessing:

- `comment` — what the reviewer wants (and `note` if one was added). This is the source of truth for "done".
- `beforeCropPath` — the flagged widget's pixels. If `beforeCropNeedsNative` was set (map/webview/native view) the CLI already fell back to a native capture, or set `beforeCropMissing`.
- `target.label` / `target.text` / `target.key` / `target.widgetType` — handles into the code. A `key` or a distinctive `label`/`text` is usually greppable straight to the widget.
- `target.screen` / `target.routeGuess` / `target.ancestorSummary` — which screen/route and where in the tree, to disambiguate a label that appears more than once.
- `status` / `liveStatus` — see the status table below.

Before you start fixing, refresh which targets still exist on screen:

```bash
flutter-scout annotations check
```

| status | meaning | what to do |
|---|---|---|
| `open` | live, needs work | fix it |
| `stale_target` (`liveMatched:false`) | the widget isn't on screen right now | navigate back to `target.screen` and re-`check`; only then decide if it's already fixed or genuinely gone |
| `pending_review` | you (or someone) marked it fixed; after-crop captured | the reviewer confirms, or you `delete` once verified |
| `resolved` / `dismissed` | closed out | leave it; `clear --resolved` / `clear --dismissed` sweeps these if asked |

A `stale_target` does **not** mean "already fixed" — it usually means the app navigated away. Get the flagged screen showing again (`tap`/`tap-text`/`deeplink`) and re-run `annotations check` before judging it.

## 3. Fix in code

Locate the widget from the target metadata (prefer `key`, then a unique `label`/`text`, narrowed by `screen`/`ancestorSummary`), then make the smallest change that satisfies the comment. Follow the repo's Flutter quality skills (**good-flutter**, **flutter-reuse-first**) — reuse existing widgets and design tokens rather than inventing new ones.

If a comment is genuinely ambiguous ("make this nicer") or asks for a product decision you can't infer, **ask the user rather than guess-fixing** — a wrong fix that then gets its pin deleted is worse than an open pin.

## 4. Reload, don't restart

After Dart-only edits:

```bash
flutter-scout reload
```

Prefer `reload` while working annotations: it keeps the app on the flagged screen so live targets keep matching and the pins and their before-crops stay in place. A `restart` re-runs the app and resets navigation, so every target goes `stale_target` (`liveMatched:false`) until you manually navigate back — extra work and a chance to lose your place. Native/asset/pubspec changes still need a full rebuild; if you must restart, expect to re-navigate to each flagged screen before verifying.

## 5. Verify, then capture the before/after

Confirm the fix actually addresses the comment — re-`inspect --brief`, re-read `delta`, or `crop` the widget and look. Don't trust "I edited the code"; trust what the app now shows.

Once verified, mark it fixed. This sets status `pending_review` **and captures the "after" crop**, giving you and the reviewer a real before/after:

```bash
flutter-scout annotations fixed ann_001 --note "Shortened label to fit one line"
```

Do this **before** deleting — the before/after evidence lives on the pin, so capturing it first means the proof survives in the conversation even after the pin is gone.

## 6. Clear only what you fixed

Delete the pins you actually resolved and verified, by id:

```bash
flutter-scout annotations delete ann_001 ann_003
```

`delete` hard-removes those ids and returns `removed` and `notFound` lists — use them to report accurately. This is the whole point of the loop: leave the overlay clean, with no stale review markers, once the work is done.

**Guard rails — these keep the reviewer's trust:**

- **Never blanket-delete.** Delete only the specific ids you fixed and verified. `annotations clear` with no filter wipes *everything*, including pins you never looked at — don't use it to "tidy up".
- **Don't delete what you couldn't fix or verify.** Leave it `open` (or `reopen` it) with a note, and tell the user why. An honest open pin beats a deleted-but-broken one.
- **Capture `fixed` before `delete`** so the before/after evidence isn't lost.
- **Never fabricate a fix for a `stale_target`.** Bring the screen back and re-`check` first.

If the user would rather confirm fixes themselves, stop at `fixed` (leaves an amber `pending_review` pin) and let them close it out — they can `resolve`/`dismiss`/`reopen` or `clear --resolved`. Only take the delete path when they've asked you to fix *and clear*.

## 7. Report back

For every pin, tell the user plainly: **id → the reviewer's comment → what you changed (or why you didn't) → its final state**. Reference the before/after crops. Be explicit about anything left open and the `notFound` ids from `delete`. Example:

- `ann_001` "Label wraps to two lines" → shortened the button text in `supplier_form.dart`, verified single line → fixed & deleted.
- `ann_002` "Should this be disabled offline?" → product decision, needs your call → left open.

## Command cheat sheet

```bash
flutter-scout annotations wait --timeout 600 --poll 1000   # block until "Send to agent"
flutter-scout annotations list                             # current pins + beforeCropPath
flutter-scout annotations check                            # refresh stale/live targets
flutter-scout reload                                       # after Dart edits (preferred)
flutter-scout annotations fixed ann_001 --note "..."       # -> pending_review + after crop
flutter-scout annotations delete ann_001 ann_003           # hard-remove the ids you fixed
flutter-scout annotations reopen ann_002 --note "..."      # couldn't fix / regressed
flutter-scout annotations resolve ann_001 --note "..."     # manual close (user-confirm path)
flutter-scout annotations dismiss ann_002 --note "..."     # won't fix
flutter-scout annotations clear --resolved                 # sweep already-closed pins only
```
