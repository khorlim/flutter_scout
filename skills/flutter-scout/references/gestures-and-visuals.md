# Gestures and visual evidence

Prefer handles, then visible text, then coordinates.

Coordinates are logical points with the origin at the top left — not screenshot
pixels. On a scaled display a screenshot is larger than the view, so pixel
values land outside it. A gesture whose start point is outside the view fails
with `gesture_start_outside_viewport` and reports the viewport size; scale by
the device pixel ratio or use a handle. Scroll a specific list by passing
`--target <scroll handle>` from `inspect --sections scrollables`, so the gesture
cannot land on the wrong scrollable.

```bash
flutter-scout tap btn.save --expect-text Saved
flutter-scout tap-text "Save"
flutter-scout input --target field.email "a@example.com"
flutter-scout scroll-to row.acme
flutter-scout long-press row.task_1
flutter-scout swipe left --target row.task_1
flutter-scout dismiss
```

`scroll-to` searches lazy scrollables and can reverse direction automatically.
For a partially visible control, a handle uses Scout's safe visible point. An
offscreen handle fails with `target_not_visible` instead of tapping stale
geometry.

For a gesture that must remain down:

```bash
flutter-scout drag-start --target row.task_1
flutter-scout drag-move --by=-80,0 --screenshot /tmp/drag.png
flutter-scout drag-status
flutter-scout drag-end
```

Capture visual evidence when appearance matters:

```bash
flutter-scout screenshot -o /tmp/screen.png
flutter-scout screenshot --annotated -o /tmp/marks.png
flutter-scout screenshot --annotated --annotate-filter fields -o /tmp/fields.png
flutter-scout crop field.email -o /tmp/email.png
```

Annotated screenshots return a mark legend. Dense overlaps can be omitted;
filter to buttons or fields when necessary. Geometry and semantics are factual
signals, not proof of visual quality—inspect the produced image.
