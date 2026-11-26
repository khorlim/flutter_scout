---
name: flutter-scout
description: Use Flutter Scout's persistent agent session to observe and operate real Flutter apps, verify changes, and collect manual visual evidence.
---

# Flutter Scout

All UI observation and input use one persistent agent connection. Standalone
inspect, tap/input/scroll, waits, live, serve, explore, batch, record and replay
commands have been removed. Do not recreate them in shell sequences or fall
back after a failure. Scout is model-independent: do not enable or require
ChatGPT/Codex Fast mode or change the user's model/service tier.

## Start or reuse the app

An app needs only FlutterScoutBinding.ensureInitialized() before runApp, or
FlutterScoutHelper.ensureRegistered() after an existing debug binding. Use a
debug build; profile/release registration is inert. No per-screen wrappers.

Name every owned run:

```bash
flutter-scout --single-json ensure --device macos --project <app> --name <task>
```

A cold build may be silent for minutes; Scout keeps waiting while the build
uses CPU. Every failed launch or ensure carries `error.message`, `failureMode`
and `failureCause` in its final envelope, and stderr gets one
`stage:'launch_failed'` record whose `cause` is a one-line summary. Read them
before retrying. Raise `--launch-idle-timeout <s>` or `--launch-timeout <s>`
only when they say a limit ended a live build. `failureMode:
'helper_not_ready'` means the app started but its helper did not answer. The
wait starts at 20 s (up to 120 s after a slow file sync) and continues while
the app prints, uses CPU or changes isolate state, within `--launch-timeout`;
`helperWait.stopReason` says why it ended. The session record is kept: run
`status`, which promotes it to ready once the helper answers, then reuse it
with `ensure` or `attach`. Do not `launch --replace` while it may still
become ready.

Run one app at a time on small machines (16 GB). `doctor`, `launch` and
`ensure` warn (`warnings[].code: 'low_free_memory'` plus one stderr record)
below 20% free memory, with the count of other live Scout-owned runs.

Keep the launch process attached until its final envelope. Progress belongs
on stderr; do not merge it into JSON stdout. While heartbeats continue, do
not start parallel status polling or another launch. Use attach only to
preserve a human-started app; VM capability URLs must enter through a 0600
file or stdin, never process arguments. Read the setup skill when needed.

When the final envelope has `helperPin` (status `app_helper_behind`), the app
pins an older flutter_scout_helper than the installed Scout, so recent helper
fixes are missing in it. Tell the user and offer to bump the `ref:` in the
named `appPubspec` to `installedScoutRef` (a change in the app repository),
then `flutter pub get` and a fresh launch. `cli_behind` means refresh the CLI.

## One eyes-and-hands connection

Read [agent-session.md](references/agent-session.md) before first use. Import
this skill's scripts/agent_client.mjs into a persistent Node tool session.
Keep the same object between decisions. Without a persistent Node tool, use
the shipped shell bridge below. Never launch Scout per request, hand-build
FIFO/REPL/TCP bridges, or use PTY echo for its JSONL transport.

```js
const { ScoutAgent } = await import('/absolute/path/to/skill/scripts/agent_client.mjs');
const scout = await ScoutAgent.connect({ app: 'task' });
const scene = await scout.observe();
// Pick an exact target from scene.view; never guess a handle.
const outcome = await scout.act(scene.viewRevision, {
  method: 'tap', args: [observedTarget],
});
// Read outcome.ok, error, dispatch, result, scene, and intervening events
// before deciding again. A failed input always carries a top-level error.
```

### Shell-only agents (Claude Code)

When each shell command is a fresh process, keep the one connection in the
shipped bridge. `serve` returns once connected (with the first `scene`) and
keeps a background process behind a private 0600 Unix socket. Each `call`
prints one JSON line; exit code 0 means `ok:true`. Pass `--brief` on every
call: it drops only repeated protocol metadata (capability tables, timings,
versions, IDs, coordinate-frame boilerplate) and keeps every outcome,
failure, omission and safety field, so a scene is read without a parsing
script. `<client>` is this skill's absolute scripts/agent_client.mjs path;
spell it out in every command because shell variables do not persist between
tool calls.

```bash
node <client> serve --app task
node <client> call --app task --brief observe
node <client> call --app task --brief act '{"viewRevision":7,"action":{"method":"tap","args":["btn.save"]}}'
node <client> call --app task --brief taps '{"viewRevision":7,"targets":["btn.6","btn.0","btn.1","btn.5"],"allowUnrelatedChanges":true}'
node <client> call --app task --brief query '{"method":"locate","params":{"text":"Save"}}'
node <client> call --app task --brief act '{"viewRevision":8,"action":{"method":"input","args":["AI Smoke"],"params":{"target":"field.customer_name"}}}'
node <client> call --app task --brief act - <<'JSON'
{"viewRevision":9,"action":{"method":"input","args":["<pin>"],"params":{"target":"field.staff_pin"}}}
JSON
node <client> call --app task --brief watch '{"condition":{"gone":"Data sync"},"timeoutMs":90000,"wait":true}'
node <client> call --app task disconnect   # before reload/restart
node <client> stop --app task              # closes Scout and the bridge
```

Typed values may go on the command line when every target is an observed
field that is not secret. A password, PIN, OTP, card or other credential
field (by its handle, or because Scout redacts its value in `fieldValues`),
a field missing from the latest scene, or input without `params.target` is
refused with `bridge_stdin_required` and nothing is sent: resend the same
act JSON on stdin with `-`. Send `fill` maps with credentials the same way.
Other methods: status, next, foreground, start, acknowledge, reconcile,
react, cancel (same fields as the client). After `disconnect` or a lost agent process, the next call reconnects
and reports `bridge.reconnected` with any `previousLoss`; until you observe,
revision-bound calls are refused (`bridge_reconnected`, nothing sent). An
in-flight input is never resent. A bridge idle for 30 minutes stops itself.

act performs one input, consumes its canonical receipt, acknowledges success,
and returns the latest scene. Eyes continue independently while the hand runs.

Response shape: observe, watch, act and taps all carry the revision for your
next decision at the top level as `viewRevision`. The screen is `view` on
observe and watch, and `scene.view` on act, taps and rejected hand requests
(`scene.viewRevision` equals the top-level one). act and taps keep every
intervening alert in `events` and only count plain view updates
(`viewEvents`). Visible strings are in
`view.visibleText`, controls in `view.interactables` (each with `id`, `kind`,
`label` and `enabled`), typed values in `view.fieldValues`. A control reports
`enabled:false` when Flutter knows it is off (null onPressed/onTap/onChanged,
`Semantics(enabled: false)`, a read-only field); a button whose handler is set
but ignores taps (app-side validation) still reports `enabled:true`.
State Flutter knows is on the control too: `selected` (tab, chip, segment,
navigation destination, list tile, or the umbrella "on" fact), `checked`
(checkbox, radio), `toggled` (switch) and `expanded` (expansion tile), from
the widget or its `Semantics`. A state the app only paints (a coloured
border around a "points" chip, a segment thumb drawn by a custom pill bar)
has no such field: read it from a screenshot or crop, and suggest the app
add `Semantics(selected: ...)` to that control. `instance` is a number per
mounted control; it only tells two controls with one handle apart.

After an input that dispatched and changed the view, act waits until the
passive eyes see no view change for two samples (at most 3 s) before taking
the returned scene, because the receipt is taken right after dispatch and
an app often applies its effect a moment later (a cart total recomputed, a
button enabled, a list loading on a new screen). When nothing changed (the
receipt saw no change and the scene after it still has the revision from
before the input), it waits one eyes interval (250 ms by default) for
a change about to land and, if none comes, returns at once with `status:
unchanged`. An effect slower than that (a server round trip) is for
`watchUntil` on the content you expect. It reports `settle: {status,
trigger, waitedMs, viewChanges, sinceInput}`. `trigger` is what the receipt
saw: `screen` (new screen, route or surface), `in_place` (a change on the
same screen) or `none` (no change yet). `sinceInput` lists what differs
from the view before the input: `appearedText`, `goneText`,
`appearedControls`, `goneControls`, `changedControls` (with `before` and
`after` of `enabled`, `selected`, `checked`, `toggled`, `expanded`, `label`)
and `changedFields`, at most 8 each. `settled` and `unchanged` mean that
revision is current for your next act; `still_changing` means the screen
kept changing (observe again or watch for the content you need). A failed or rejected
input returns its scene at once. Nothing is pumped or retried.
It never retries or waits for business completion. A start acceptance ticket
is not dispatch or success. Use start/next/acknowledge directly when you need
fine-grained concurrent control. Only one event consumer is allowed.

Return compact decision evidence to the model: ok, actionId, dispatch,
runtimeHealth, error, scene revision/screen, relevant targets/text, and any
intervening alerts. Do not print repetitive full envelopes or silently remove
failure, omission, or safety fields. Full canonical receipts remain in the
private journal. Close the connection before unrelated long coding work.

## Locate and act deliberately

Use scout.query('where') for layout; scout.query('locate', {text: 'Name'})
for a target; scout.query('inspect', {sections: 'interactables,scrollables'})
for selected detail. A named section is never cut; `maxItems` (1-500) only
bounds brief lists. A scene that was cut says so in `view.omitted` (counts
per list, such as `scrollables: 3`) with `recoverWith`, the exact query
that reads the cut lists in full: `query(recoverWith.method,
recoverWith.params)`. Query is read-only, not permission to act
on stale geometry: observe again and decide from the current scene. A
`locate` answer's `result` is only its status (`unique`, `ambiguous`,
`notFound`, ...); the match, its rect and the candidates are in `resolution`.
A handle is an interactable's `id` (for example `btn.save`, `tap.raymond`).

Targets come from Flutter's tap widgets and from `Semantics(button: true)` or
`Semantics(onTap: ...)`. A custom pressable built on raw pointers (a ripple
package, a press-effect wrapper) is a target only when the app gives it that
Semantics; until then tap its visible text, and suggest the app add the
Semantics, which also serves accessibility. `SelectableText` (chat bubbles,
copyable values) is text, so `locate` finds its words.
A row inside a swipe wrapper (`Slidable`, `Dismissible`) keeps its own
handle: tap it, or reveal its actions with `{method:'swipe', args:['left'],
params:{target: handle, distance: 150}}` and tap the action from the next scene.
A row covered by a floating button has no handle until it is scrolled clear.
A swipe that moves nothing fails with `swipe_no_effect` (its `target` names
the widget it landed on): observe, reconcile, bring the row into view and
swipe the row's own handle.

Context menus: `{method:'long-press', args:[handle]}` presses and holds, and
`{method:'tap', args:[handle], params:{button:'secondary'}}` is a mouse right
click (desktop `onSecondaryTap*` menus). Read the menu from the next scene.
Feature keys: an app may put `ValueKey('feature.<id>')` on a control or a
few levels above it. The control then also answers to `<kind>.feature_<id>`
(dots become `_`, e.g. `btn.feature_home_tile_member`) as an alternate handle
next to its label handle, so a spec can name it whatever its label says.

Double tap: add `params:{taps:2}` to `tap` (handle or `x`/`y`) or `tap-text`.
Both taps go out in one dispatch at one point, 100 ms apart (`intervalMs`
0-1000), with one receipt. Use it for `onDoubleTap` controls and to test an
impatient user (a double-tapped submit must create one record); two separate
`act` taps land hundreds of ms apart. The second tap is never retried or
retargeted: if the first tap changed the screen, it lands on whatever is now
at that point, and `activation.secondTap.targetStillHit: false` plus a warning
say so. Check the business outcome (one sale, one order) yourself.

System permission prompts (iOS Simulator, Android emulator): when one covers
the app, the scene has `view.systemDialog` (title, owner, button handles such
as `sys.allow`, `sys.dont_allow`, `sys.while_using`) and refuses Flutter input
with `inputBlockedReason:'system_dialog'`. Answer it only when the task says
which answer to give: `{method:'system-tap', args:['sys.allow']}`. A dialog of
another app needs `params.dialogOwner`; credential and Apple Account prompts
are never answered. Observe again after a tap that requests a permission: the
prompt appears after the receipt. To avoid prompts, pre-grant with
`flutter-scout --app <task> permissions grant camera` (the iOS Simulator
terminates the running app for any change). iOS needs AXe
(`brew install cameroncooke/axe/axe`). Details and the per-platform service
table: [system-dialogs.md](references/system-dialogs.md).

Close a menu, popover, sheet or dialog with `{method:'dismiss'}`; there is no
key-press action. An open text-selection toolbar or context menu closes first
(as Escape does), so dismiss never pops the screen under it. A menu opened before a hot reload keeps the items it was
built with: dismiss and reopen it to see reloaded code.

Prefer exact observed handles, then unique visible text. Ambiguity requires
focused discovery, not another guess. When duplicates match but only one can
take input (the others sit behind the open sheet or dialog, or are off
screen), that one is used and the resolution's `reason` says so.
A control is named from its own visible text, however deep the app draws
it (`btn.thai_yoga`, `btn.advanced_edit`), or its `Semantics` label; a
switch or checkbox from its list tile title or the caption stacked above
it (`btn.roundup`). Symbols that change meaning stay in the handle
(`<180 days` is `tap.lt_180_days`, `>180 days` is `tap.gt_180_days`). Only
an app-chosen string key replaces the name (`ValueKey('save_button')` is
`btn.save_button`); GlobalKeys and numeric keys never do. Icon-only
controls are named from their icon (`btn.cart`): Material/Cupertino
glyphs, and bundled PNG or SVG asset file names.
Equal names are numbered in screen order (`btn.save`, `btn.save_2`), and a
number stays with its control while that control is mounted: a cart row
that appears above a grid tile of the same name becomes `btn.thai_yoga_2`
and the tile keeps `btn.thai_yoga`. When a handle you decided on now names
another control (the old one was replaced), the input is refused as stale
(`target <id> changed`, `staleChanges` shows the `instance` change) instead
of landing on the new one; observe and decide again. For forms, `fill` takes an observed
field-to-value map: `{method:'fill', params:{json:{[fieldHandle]:value}}}`.
For one field, use `{method:'input', args:[value], params:{target:fieldHandle}}`.
The input target belongs in `params.target`, not in `args`. Omitting it types
only into an already focused field; opening a form does not imply focus.

Choose from reported candidates or narrow context. A stale state requires
fresh observation and a new decision, not replacement of the revision on an
old action. Coordinates are logical Flutter points, not screenshot pixels;
use them only when observed handle/text targeting cannot express the action.
They go in `params.x` and `params.y` as numbers, never in `args`
(`{method:'tap', params:{x:380, y:215, button:'secondary'}}`). Take them from
an observed `rect`/`suggestedTapPoint`, not from a screenshot: a screenshot is
in physical pixels and may be scaled for display.
For lazy lists, use region-scoped bounded reveal/scroll-to through act.

Sensitive input belongs in agent JSON stdin through the client, never shell
arguments or printed results. Values typed into credential fields (password,
PIN, OTP, token, card number, or a field the app marks sensitive) are scrubbed
from all later output; other typed text (names, notes, amounts) stays
readable so you can confirm it on screen. Do not use allowErrors, waitMs,
expect flags, file input or capture flags in actions; these are rejected.

Background churn: when a progress toast, clock or live list keeps changing
the screen, an exact-handle action (tap, long-press, input or fill on an
observed handle, or scroll/swipe with `params.target`) can add
`"allowUnrelatedChanges": true` beside `method`. It still dispatches only if
every target is unchanged, enabled and hit-testable on the same surface; the
app's hit test then checks nothing covers it. A rejection names the cause in
`details.staleReason` and lists each changed field with its observed and
current value in `details.staleChanges` (for example
`{field:'rendering.lifecycle', before:'resumed', after:'hidden'}`, or the
texts and controls that `appeared` and `disappeared`). Use it only for
changes you have judged unrelated.
Keypads, PIN pads and steppers: send the keys in one `taps` call (bridge
`taps {viewRevision, targets, allowUnrelatedChanges}`, client
`scout.taps(revision, targets, {allowUnrelatedChanges: true})`, 1 to 32
observed handles). Each key is an ordinary exact-handle tap decided from that
revision, with its own canonical receipt; the flag lets the display the
previous key updated not invalidate the next key. It stops at the first tap
that fails or is rejected and never retries or skips: read `completed`,
`taps[]` (`target`, `ok`, `actionId`, `dispatch`; the last attempted tap keeps
its full `result`), `error`, then one final `scene`. A tap that navigates
makes the rest fail as stale, by design. Read the typed value afterwards.

Scroll both ways: `args: ['up'|'down'|'left'|'right']` sets the direction
(default down) and a negative `distance` reverses it:

```js
{ method: 'scroll', params: { target: 'scroll.day_grid', distance: 600 } }  // down
{ method: 'scroll', params: { target: 'scroll.day_grid', distance: -600 } } // back up
```

Known app errors: a caller that has judged a recurring app error harmless
(for example a printer plugin missing on a simulator) sets
`FLUTTER_SCOUT_TOLERATED_ERRORS` to one regular expression in the environment
that starts the client. Matching errors move to `toleratedErrors` (still
reported, so list them as app findings) and no longer halt input. Never use
it to hide an error you have not understood.

## Completion and recovery

Input completion and business completion are separate. A condition is one
of `{text: s}` (on screen), `{gone: s}` (no longer on screen), `{screen: s}`
or `{surfaceChanged: true}`. `text` and `gone` compare `s` exactly with each
visible text, interactable label and handle, so `{gone: 'Data sync'}` waits
for a capsule labelled "Data sync" that shows only "45%". `gone` waits while
a brief list it needs was cut (`omitted`); a timeout then names it in
`absenceUnproven`.

`scout.watchUntil(condition, timeoutMs)` (bridge: `watch` with `"wait":true`)
blocks until the condition ends and returns that end: `ok:true` with
`status:'met'`, the matching `viewRevision` and `view`; otherwise `ok:false`
with `status` (`timeout`, `observation_unavailable`, ...). Other events it
read are in `events`; plain view updates are only counted (`viewEvents`). It
is the event consumer meanwhile, so do not run act or next alongside it.
Keep one blocking call under your shell tool's time limit (about 90,000 ms
for a 2-minute limit) and repeat it while it times out. Plain
`watch(condition, timeoutMs)` still returns a ticket at once; then consume
`next` events (each waits at most 30,000 ms) until that condition's event.
A plain watch may run up to 600,000 ms (a first data sync); one with a
reaction stays within 30,000 ms.

Short-lived text: a toast or snackbar can vanish before your next observe.
Each `observe` (and the scene `act` returns) carries `transientText`: texts
that appeared and disappeared since your previous observe, with `shownMs`
and `goneAgoMs`, newest last (at most 12, `transientTextOmitted` counts the
rest). Eyes sample every 250 ms, so text shown for less than that can still
be missed. To wait for a message that is about to appear, a watch for its
`text` started before the act also works.
Do not wait for a success screen after a rejected input. Already-visible text
proves observed state, not that a new save succeeded. A timeout is not evidence
that an app operation was cancelled or safe to repeat.

After a failed action, examine its receipt and the fresh scene. A
`dispatch:not_dispatched` failure (for example `live_view_changed`) sent
nothing and leaves the hand free: decide again from outcome.scene. For a
failure that dispatched, explicitly reconcile(actionId, scene.viewRevision)
after checking app state. Reconciliation does not repeat input. Unknown
dispatch, runtime replacement, or lost evidence stays halted; investigate
before opening another connection. Never suppress errors to keep navigating.
Exact-handle taps, input and fill tolerate unrelated text ticks (clocks,
countdowns); real screen, surface or target changes are still rejected.

Rendering suspended means restore app visibility (or, only when the user
asked for it, use headless drive below). Never pump frames yourself or treat
an old semantic tree as current pixels. An active framework frame does not
prove the native window is visible. Manual images are required for visual QA.
When a scene has `actionable:false`, read `scene.blockedBy`: `reason` says
whether rendering (`rendering_suspended`) or safety blocks input, `details`
holds the rendering facts, and `nextStep` is the literal recovery. A rejected
input carries the same fields in `error.reason`, `error.nextStep` and
`error.details`.

On macOS, keep the app window visible (not covered, minimized or on another
Space) while sending input; a covered window stops rendering and every input
is rejected. Focus is not needed: a partly visible window keeps rendering
(lifecycle `inactive`) and Scout's input never moves the user's mouse or
keyboard. When a person is using the Mac, ask them to leave part of the window
visible (beside their work or on another display) instead of taking focus.
Only when nobody is using it, call `await scout.foreground()` once before a
burst of input, and again only when a rejection reports `rendering_suspended`.
It activates only the observed app process and takes focus away from the
user, so do not call it per tap or in a loop. A frontmost `loginwindow` means
the screen is locked; ask the user to unlock it. It waits up
to 5 seconds for a fresh scene with active rendering, uses normal OS
activation (not a rendering override) and sends no UI input. A failure names
its cause, such as `rendering_still_suspended` with the lifecycle and the
frontmost app: restore the window by hand rather than adding osascript or
sleeps. It refuses during input or an unread/unknown receipt. A received known
failure can restore visibility, but still needs explicit reconciliation;
activation never clears its halt or acknowledges its receipt. Never treat
activation as save success.

### Headless drive (macOS debug apps, opt-in)

When the user wants the agent to keep working while the app is hidden,
covered, minimized, the display is asleep or the screen is locked, start the
run with `ensure|launch|attach --headless-drive` (or
`FLUTTER_SCOUT_HEADLESS_DRIVE=1`). Off is the default; the latest
launch/ensure/attach decides, and the agent connection picks it up when it
connects (reconnect after changing it). While Flutter has stopped frames
because the app is not visible, the helper then drives bounded frames itself
for as long as the agent stays connected: `rendering.status` is `driven`,
input is accepted, and every scene carries `headless: {driving, reason,
lifecycle, notice}` with `reason` `app_hidden`, `display_asleep` or
`screen_locked`. Say so in your report. Costs and caveats:

- CPU, battery and heat: one frame per observation plus up to 20 frames per
  second while the app animates (a focused field's caret blinks). It stops
  within 5 s of disconnecting and as soon as the window is visible again.
- It is not a visible app: the lifecycle really is `hidden`, so app code
  reacting to that (pausing video, sockets, timers) still runs; vsync-timed
  behaviour and platform views differ.
- You act on a live app nobody is watching. Keep to the user's task.
- System sleep or a closed lid still suspends the app and Scout. Check
  `status`/`doctor` `hostPower` and ask the user to keep the Mac awake
  (for example `caffeinate -i -w <app pid>`).
- Screenshots and crops use the in-app capture; `--native` is refused with
  `native_capture_unavailable_headless` while the app is hidden or locked.
- `foreground()` still succeeds only when the window really renders.

For an authorized time-sensitive response, react can issue one exact observed
tap or stop future input, bounded to 30 seconds. It cannot invent targets,
retry, cross surfaces, or cancel an already-started app operation.

## What a person watching sees

While the agent connection is attached, the app shows an "AI is driving"
overlay for people watching: a calm edge glow; the session label in the
lower-left corner reading "Scout · <name> · controlling" (it says
"observing" once no input has arrived for about 15 s, so it holds steady
between turns while the glow and cursor calm down after about 2.4 s); a
cursor tagged "Scout" on desktop or a touch dot on
iOS/Android that glides to each target; a ripple at the hit point (two for
a double tap, a square one plus a "Right click" chip for a secondary
click); a filling ring for a long press; a trail for drags and scrolls with
a direction chevron; the typed field highlighted with the text arriving in
a chip inside the field (credential fields show dots only, never the value
or its length); and short back/dismiss cues. Visuals play once an act has
answered, so they trail the app by the act's duration.

It never affects you: it takes no hits, is absent from `view` (text,
interactables, fields, screen, surface) and from semantics, never delays or
moves input, is not counted as app activity by settle or stability, and its
frames do not slow observation (acts take the same time with it on).
Scout screenshots and crops leave it out; add `--with-overlay` to keep it.
Turn it off with `flutter-scout agent --no-overlay`, `ScoutAgent.connect({
overlay: false})`, `serve --no-overlay`, or `FLUTTER_SCOUT_OVERLAY=0` in
the environment that starts the client (`=reduced` for reduced motion; the
platform's reduce-motion setting is also respected).

## Changes, images, and handoff

Close the agent connection before reload/restart, then reconnect (bridge:
`disconnect`, reload, then `observe`; if a scene shows `hand.halted` after a
restart, `disconnect` and observe again). Use reload
for Dart changes; sourceVerification:mismatch is a failure. A rejected reload
does not imply the app died: check status and preserve a reachable session.
Follow `error.suggestedCommand` when present. After an `*_ack_timeout`, read
`error.toolState`: never resend while it is `in_progress`.
Native/plugin/pubspec changes need a full launch. Read runtime output with
`flutter-scout --app <task> logs --summary` (or `--last <n>`, `--contains
<text>`), never by opening log files. Lifecycle and ownership
recovery details: [lifecycle-and-diagnostics.md](references/lifecycle-and-diagnostics.md).

Screenshots and crops stay manual. Capture only when appearance matters or
semantic evidence is insufficient, and inspect the image before claiming
visual verification. Details: [gestures-and-visuals.md](references/gestures-and-visuals.md).
Instead of `sleep` before a screenshot, wait for the end state with a `watch`
condition or a fresh observation. Scout has no frame-sequence capture; do not
slow animations with `timeDilation` in an app a person is also using.

Use `--retention manual` for screenshots you must keep after
`stop --clear-session` (reports, test evidence); `session` images are deleted.

```bash
flutter-scout --app <task> screenshot -o /private/path/screen.png --retention session
flutter-scout --app <task> crop --changed-since '<snapshot-id>' -o /private/path/change.png
```

Annotation pins: [annotations.md](references/annotations.md). Remaining API:
[command-reference.md](references/command-reference.md).

Finish with scout.close() (bridge: `stop`), then stop the exact owned run unless the user wants
it left open for immediate testing:

```bash
flutter-scout --app <task> stop --clear-session
```

Require ok:true, sessionCleared:true, and recordedRuns.unresolved:[] before
claiming cleanup. Never stop a human-owned or another task's run.

## Outside Scout

Scout sees and drives the Flutter tree of a debug app, plus native system
dialogs above it on the iOS Simulator and Android emulators (see above). It
does not handle system dialogs on physical devices or macOS (TCC prompts),
other native UIKit/AppKit controls or sheets, device rotation or performance
profiling. On a physical iPhone, ask the user to answer the prompt or set the
permission in Settings. Use the simulator tooling (`xcrun simctl`, the host's
simulator or desktop control tool) for other system UI and rotation, and
`flutter run --profile` with DevTools for frame timing; say so in the report
instead of retrying through Scout.
