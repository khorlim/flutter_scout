---
name: flutter-scout-annotations
description: 'Work through Flutter Scout annotation pins left on a running Flutter app. Use when the user says the app has annotations, asks to check/handle/address/action Scout pins/review markers/comments, or asks Codex to fix and clear annotations. The workflow is simple: check pins, fix each pin one by one, remove each fixed pin, then report what was fixed and what remains.'
---

# Flutter Scout: annotation pins

Use this skill when a reviewer has left Flutter Scout annotation pins on a running app. Keep the loop simple:

```text
check pins -> fix one pin -> delete that fixed pin -> repeat -> report
```

Assume a Scout session is already attached. For attach, launch, inspect, tap, reload, or setup mechanics, use the `flutter-scout` skill and `flutter-scout-setup` only if needed. Run commands as `flutter-scout <cmd>`, adding `--app <name>` when targeting a named session.

## 1. Check Pins

Read the current pins immediately:

```bash
flutter-scout annotations list
```

Then refresh live target status:

```bash
flutter-scout annotations check
```

For each pin, read:

- `id`
- `comment` and `note`
- `beforeCropPath`
- `target.key`, `target.label`, `target.text`, `target.widgetType`
- `target.screen`, `target.routeGuess`, `target.ancestorSummary`
- `status` and `liveStatus`

Open every `beforeCropPath` image before editing. The crop shows exactly what the reviewer marked.

If a pin is `stale_target` or `liveMatched:false`, navigate back to the flagged screen and run `annotations check` again before deciding whether it is fixed or gone.

## 2. Fix One Pin at a Time

Pick one open pin. Locate the widget from the target metadata, preferring `key`, then distinctive `label` or `text`, narrowed by the screen and ancestor summary.

Make the smallest code change that satisfies the pin comment. Reuse the app's existing widgets, styles, and design tokens.

If the comment is ambiguous or asks for a product decision you cannot infer, leave that pin open and report the question instead of guessing.

## 3. Remove the Fixed Pin

After Dart-only edits, hot reload only when it helps you keep your place or continue fixing nearby pins:

```bash
flutter-scout reload
```

Once you made the fix, delete that specific pin:

```bash
flutter-scout annotations delete ann_001
```

Delete only pins you personally fixed. Do not use blanket `annotations clear`.

If a pin cannot be fixed, leave it open. If you accidentally removed the wrong thing or need to undo a bad pin state, reopen it:

```bash
flutter-scout annotations reopen ann_001 --note "Still needs work because ..."
```

Then move to the next open pin and repeat the same loop.

## 4. Report

Report every pin you handled in this format:

- `ann_001` "<reviewer comment>" -> changed `<file>` so `<visible result>` -> fixed and deleted.
- `ann_002` "<reviewer comment>" -> could not fix because `<reason>` -> left open.

Include any delete `notFound` ids if the command reports them. Be explicit about pins left open and what the user needs to decide.

## Command Cheat Sheet

```bash
flutter-scout annotations list
flutter-scout annotations check
flutter-scout reload
flutter-scout annotations delete ann_001
flutter-scout annotations reopen ann_002 --note "..."
```
