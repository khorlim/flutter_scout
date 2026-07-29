# Annotations

When the user says annotation pins are ready:

```bash
flutter-scout annotations list
```

Each pin includes the comment, widget facts, original snapshot geometry, live
matching state, and materialized `beforeCropPath` when available. Read the crop
for appearance problems.

Fix one actionable pin at a time. After reloading and verifying:

```bash
flutter-scout annotations fixed ann_001 --note "Shortened label"
flutter-scout annotations delete ann_001
```

`fixed` captures after evidence; deleting removes only handled pins. Never
blanket-delete pins or remove an unresolved pin.

If the user wants to review the fix:

```bash
flutter-scout annotations fixed ann_001
flutter-scout annotations check
flutter-scout annotations resolve ann_001 --note "Confirmed"
flutter-scout annotations dismiss ann_002 --note "No longer relevant"
flutter-scout annotations reopen ann_001
flutter-scout annotations clear --resolved
```

Use the dedicated `flutter-scout-annotations` skill for the full pin-by-pin
workflow when it is available.
