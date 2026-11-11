# Gestures and visual evidence

Prefer handles, then visible text, then coordinates.

Coordinates are logical points with the origin at the top left — not screenshot
pixels. On a scaled display a screenshot is larger than the view, so pixel
values land outside it. A gesture whose start point is outside the view fails
with `gesture_start_outside_viewport` and reports the viewport size; scale by
the device pixel ratio or use a handle. Scroll a specific list with an observed scroll handle from an agent query, so the gesture
cannot land on the wrong scrollable.

All gestures use scout.act(currentRevision, {method,args,params}) through the
persistent client. Read scout.query('where') or focused inspect sections when
layout/scroll regions are unclear. Take a fresh observation before choosing.

Examples of action objects (targets must come from the actual current scene):

```js
{ method: 'tap', args: [observedHandle] }               // tap by handle
{ method: 'tap', params: { x: 120, y: 340 } }           // tap by logical point
{ method: 'tap', args: [observedHandle], params: { button: 'secondary' } } // right click
{ method: 'long-press', args: [observedHandle] }        // press and hold
{ method: 'input', args: [value], params: { target: observedField } }
{ method: 'scroll', args: ['down'], params: { target: observedScroll, distance: 400 } }
{ method: 'swipe', args: ['left'], params: { target: observedHandle, distance: 300 } }
{ method: 'reveal', args: [observedTarget], params: { within: observedScroll, maxActions: 8 } }
{ method: 'drag-start', params: { target: observedHandle } }
{ method: 'drag-move', params: { by: '-80,0' } }
{ method: 'drag-end' }
```

Coordinates are numbers in `params.x`/`params.y`, never a target string.
Scroll and swipe also accept `params.from`/`params.to` as `'x,y'` strings
instead of a target. Scroll distance is `distance`; there is no `amount`.
An unknown parameter fails with `unknown_parameter` and lists the parameters
the method accepts.

After each input, check its canonical receipt. When `act` returns `ok:false`
for a known dispatch outcome, observe, check the app state, then reconcile
against the fresh revision before deciding again. Reconcile never retries:

```js
const outcome = await scout.act(scene.viewRevision, action);
if (!outcome.ok) {
  const fresh = await scout.observe();
  // Decide from fresh.view whether the failed input changed anything.
  await scout.reconcile(outcome.actionId, fresh.viewRevision);
}
```

Custom PIN/OTP widgets (such as pin_code_fields) paint boxes over a
transparent text field, so targeted input fails with
`reason:'target_not_hit_testable'` and a `suggestedActions` entry
`tapCoveringControlThenFocusedInput`. Follow it: tap the visible box, observe
until the keyboard is visible or the field reports focus, then send
`{ method: 'input', args: [value] }` with no target. Focused input still
checks surface, visibility, editability and focus before typing.

For a held drag, query
'drag-status' for its current state; end/cancel it explicitly. A held gesture
is not cancelled by cancelling a condition wait or closing the transport.
An offscreen target is not permission to tap its old geometry. Bounded reveal
reports failure/restoration and never chooses among ambiguous scroll regions.

Capture visual evidence when appearance matters:

```bash
flutter-scout --app <task> screenshot
flutter-scout --app <task> screenshot -o /tmp/scout/screen.png
flutter-scout --app <task> screenshot --annotated -o /tmp/scout/marks.png
flutter-scout --app <task> crop field.email -o /tmp/scout/email.png
flutter-scout --app <task> crop --changed-since '<snapshot-id>' -o /tmp/scout/changed.png
```

Without `-o`, the image goes to the session's private `screenshots/`
directory; read the written location from the result's `path`. With `-o`, the
parent directory must exist, or be one missing leaf that Scout creates as
`0700`. The system alias `/tmp` (macOS `/private/tmp`) is accepted. Any other
symbolic-link parent is refused with `unsafe_storage_path`, and the message
names the resolved directory to pass instead.

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

Native deeplink is an agent action. Its URL travels through the JSON pipe;
never print it or put token-bearing URLs in shell argv. It requires an exact
supported emulator, platform-tool reachability and the same actively rendering
agent view immediately before dispatch. Unknown dispatch remains unknown.

Annotated screenshots return a mark legend. Dense overlaps can be omitted from
the rendered marks and legend. Geometry and semantics are factual signals, not
proof of visual quality—inspect the produced image.
