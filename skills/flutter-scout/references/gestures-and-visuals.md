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
flutter-scout input --target field.email --stdin
flutter-scout scroll-to row.acme
flutter-scout long-press row.task_1
flutter-scout swipe left --target row.task_1
flutter-scout dismiss
```

`scroll-to` searches lazy scrollables and can reverse direction automatically.
For a partially visible control, a handle uses Scout's safe visible point. An
offscreen handle fails with `target_not_visible` instead of tapping stale
geometry.

For complex or nested scrolling, orient read-only first and use a bounded,
region-scoped reveal:

```bash
flutter-scout where
flutter-scout locate row.acme
flutter-scout reveal row.acme --within scroll.suppliers --max-actions 8
```

Scout abstains when several scroll regions exist and `--within` is omitted. It
also stops on ambiguity, stale state, unsafe hit testing, repeated state, an
edge, or any declared action/distance/time bound, and reports whether the
starting scroll position was restored after failure.

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
flutter-scout crop --changed-since '<snapshot-id>' -o /tmp/changed.png
```

Screenshots/crops are private application data. Prefer a private destination
and keep the default `--retention session`; use longer retention only when the
task requires it.

Scout prefers in-app capture. A forced or required native full screenshot uses
the exact recorded emulator: `xcrun simctl` on iOS Simulator or local-argv
`adb exec-out screencap -p` on Android Emulator. Read `backend`, `provenance`,
`coordinateSpace`, and `limitations` from the result instead of inferring them.
A native targeted crop is emitted only when the helper's same-snapshot physical
viewport exactly matches the native PNG dimensions; treat
`native_crop_coordinate_frame_mismatch` as an abstention and use an in-app crop
or full native image rather than guessing status-bar/inset offsets.

Changed-region capture uses the retained baseline and the helper's
`delta.changedRegions`; it is not pixel differencing. A successful response
includes baseline/current/capture-verification snapshot scopes, complete
coverage, logical/physical union rects, DPR, capture identity, backend, and the
enforced count/padding/area/pixel limits. Stale history, incomplete or ambiguous
geometry, a screen/route/frame change, more than 16 regions, a padded union over
half the viewport, or output above 4096×4096 / 4,194,304 pixels is a typed
abstention. Platform-view/native fallback is also a typed abstention because a
host screenshot cannot be atomically tied to that helper snapshot.

For `deeplink`, a missing platform tool, stale recorded device, physical device,
or unreachable emulator returns `unsupported_capability` before app dispatch.
Pass the URL through owner-only `--url-file <0600-path>` or `--url-stdin` so a
token-bearing link is absent from the caller's argv. Scout keeps only a replay
placeholder and ingress provenance in durable records; legacy positional URLs
emit an `insecure_secret_source` warning.
Scout also abstains unless a fresh protocol-valid observation proves the exact
selected session immediately before dispatch. Android sends the URL through
ADB's remote shell with single-quote escaping and additionally requires Activity
Manager's `Status: ok`. An unknown
dispatch still requires state reconciliation under the original idempotency
key.

Annotated screenshots return a mark legend. Dense overlaps can be omitted;
filter to buttons or fields when necessary. Geometry and semantics are factual
signals, not proof of visual quality—inspect the produced image.
