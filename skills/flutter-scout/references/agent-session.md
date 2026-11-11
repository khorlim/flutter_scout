# Concurrent hand/eye session

Use `flutter-scout --app <name> agent` for interactive exploration of an already
running named app. It maintains two independent VM connections: passive eyes
and one guarded hand. Screenshots remain explicit, manual commands. No app
wrappers or frame-pumping tricks are installed. Explicit `foreground()` uses
normal native macOS activation for this session's observed VM process only.
It shares the hand, preserves unresolved receipts/halts, sends no UI input,
and returns a freshly observed scene. It never automatically steals focus.

## macOS visibility and foreground()

A macOS Flutter window that is covered, minimized or on another Space stops
rendering, and the guard then rejects every input with
`error.reason:'agent_live_view_unavailable'`. Keep the window visible while
sending input. Other apps (for example several worktree builds running at
once) can take focus and cover it again. Focus itself is not needed: a partly
visible, unfocused window keeps rendering (lifecycle `inactive`), and Scout's
input goes to Flutter, not to the user's mouse or keyboard.

- `scene.blockedBy` (present only when `actionable:false`) and every input
  rejection carry `reason`, `message`, `nextStep` and `details`. Live-view
  reasons are `rendering_suspended`, `blocking_signals`, `app_errors`,
  `safety_evidence_incomplete` and `observation_unavailable`; details hold
  `rendering.status`, `framesEnabled`, `lifecycle`,
  `lastFrameworkFrameAgeMs`, `foregroundAvailable` and safety counts. A
  stopped, busy or receipt-bound hand uses `code:'agent_hand_unavailable'`.
- When a person is using the Mac, ask them to leave part of the window
  visible instead of calling foreground(). Only when nobody is using it, call
  `await scout.foreground()` once before a burst of input and again only
  when a rejection reports `rendering_suspended`. It takes focus away from
  the user, so never call it per action or in a retry loop.
- foreground() polls passive observations for up to 5 seconds until rendering
  is active. It never pumps frames. On failure it returns `ok:false` with
  `error.reason`, for example `rendering_still_suspended` (with lifecycle,
  `frontmostApp` and `frontmostIsTarget`) or a request rejection such as
  `agent_foreground_activation_refused`, `agent_foreground_app_unidentifiable`,
  `agent_foreground_app_not_running` or `agent_foreground_unsupported`.
  Follow `nextStep`: restore the window by hand instead of adding osascript
  activation or sleeps. A frontmost `loginwindow` means the screen is locked
  or asleep, and no window can render until the user unlocks it.

## Client

Import the shipped `scripts/agent_client.mjs` from this skill's directory in a
persistent Node process. `ScoutAgent.connect({app})` returns the initial scene in
`agent.latest`; optional `binary`, `cwd`, `intervalMs`, and `maxItems` configure
the process. The client requires Node with built-in ES module support and no
third-party dependencies. Keep the object between tool calls and close it at
the end. Do not restart the client for every action.

```js
const agent = await ScoutAgent.connect({app: 'task-slug'});
const scene = await agent.observe();
// Preferred one-input helper: checks the receipt, acknowledges success,
// returns a fresh scene and every intervening alert; never retries.
const outcome = await agent.act(scene.viewRevision, {
  method: 'tap', args: [observedTarget],
});
// Check outcome.ok, outcome.result and outcome.scene before another action.
// Low-level alternative for fine-grained concurrent control:
// Use the revision and exact target just observed, not a guessed identifier.
const lowLevelScene = await agent.observe();
const ticket = await agent.start(lowLevelScene.viewRevision, {
  method: 'tap', args: [observedTarget],
});
// ticket.phase === 'accepted' does NOT establish dispatch or success.
// Consume events, including view changes, until the matching actionId arrives.
const {event} = await agent.next(10000);
// Continue consuming until the matching action receipt. Check event.result.
// A successful receipt must be acknowledged before another action:
await agent.acknowledge(ticket.actionId);
await agent.close();
```

### Shell bridge (no persistent Node tool)

`node agent_client.mjs serve --app <name> [--socket <path>]` detaches a
process that owns one `ScoutAgent` and listens on a Unix socket (default
`$TMPDIR/flutter-scout-<uid>/<name>.sock`, directory 0700, socket 0600). It
prints `{type:'serving', socket, pid, log, scene}` once connected, or the
connect error, and reuses a live bridge for the same app. `call --app <name>
<method> [json|-]` sends one request and prints one JSON line (exit 0 iff
`ok:true`). Methods mirror the client with named fields: `act {viewRevision,
action, timeoutMs}`, `start`, `acknowledge {actionId}`, `reconcile {actionId,
viewRevision}`, `next {timeoutMs}`, `watch {condition, timeoutMs}`, `react`,
`cancel {scope, conditionId}`, `query {method, params, args}`, `observe`,
`status`, `foreground`, plus `bridge` (bridge status), `disconnect` (close
Scout, keep the bridge) and `close`/`stop` (close Scout and end the bridge).
`-` reads the JSON from stdin; input/fill actions must use it.

The bridge never retries or queues. When the agent process exits (or after
`disconnect`), the next call opens a new connection and adds
`bridge: {reconnected, reason, previousLoss}`. Revisions, action and condition
ids restart per connection, so only observe/status/query are served until the
caller has observed; other calls return `bridge_reconnected` with nothing sent.
`previousLoss.dispatch: dispatch_outcome_unknown` means the earlier input may
have run: check the fresh scene before deciding. disconnect/close are refused
while an input is running. An idle bridge stops after 30 minutes.

`next()` can remain pending while `observe`, `start`, `watch`, `react`, or
`cancel` requests run. Use only one event consumer and route events by
`actionId`/`conditionId`; do not discard unrelated alerts while waiting for one
receipt. New observations reach the agent through awaited tool results. This
does not by itself wake or interrupt a model that is still reasoning.

## Three independent outcomes

1. `start(viewRevision, {method,args,params})` accepts one action and returns a
   ticket immediately. `dispatch:not_yet_established` is not success. A second
   action while the hand is occupied is rejected, never queued.
2. An `action` event carries the normal canonical dispatch, observation, runtime
   health, evidence and postcondition fields in `result`. It uses short input
   settling (`waitMs:0` where supported), not a business-completion wait. The
   normal safety/evidence work is still required; zero settling is not zero
   execution time. The next input is blocked until the matching event has been
   delivered and acknowledge(actionId) succeeds. A `dispatch:not_dispatched`
   failure (such as `live_view_changed`) sent nothing: once its receipt is
   delivered the hand is free for a new decision, with no acknowledge or
   reconcile. Other failures cannot be acknowledged: inspect the receipt,
   observe, then call reconcile(actionId, scene.viewRevision). Reconciliation
   never retries. Unknown dispatch stays halted; check app state, then close
   and reconnect. Rejected hand requests name the action and recovery call and
   include the current `scene` for one new decision.
3. `watch({text:'Ready'}, 8000)` returns a condition ticket; its later
   `condition` event says `met`, `timeout`, `observation_unavailable`, `stopped`,
   or `cancelled`. It doesn't occupy the hand. This proves observed state only,
   not causality: already-visible "Ready" is not proof a new save completed.

Supported actions are tap, tap-text, long-press, input, fill, scroll, swipe,
scroll-to, back, dismiss, reveal, drag-start, drag-move, drag-end, drag-cancel and deeplink,
with normal typed parameters (examples for tap by handle or `params:{x,y}`,
input, scroll, swipe and reconcile are in gestures-and-visuals.md). Agent mode rejects
expectation parameters, safety overrides, file input, capture and screenshots.
Pass sensitive input through JSON stdin, never process arguments. Standalone
interaction commands and alternate transports are removed, not fallback paths.

Use query(method, params, args) for focused read-only inspect, where, locate,
bounds and drag-status. For example query('locate', {text: 'Save'}) or
query('inspect', {sections: 'interactables,scrollables', maxItems: 100}). It
returns a canonical read result, not fresh authorization for another input;
observe and decide again after using it. No arbitrary command is accepted.

## Local reactions: explicit, bounded authorization

```js
const rule = await agent.react(scene.viewRevision,
  {text: 'Notice: Pause requested'},
  {type: 'tap', target: observedPauseHandle}, 10000);
```

Only register a tap rule when the user's task authorizes that exact response.
The target must already appear uniquely in the observed view. The condition
must still hold on a fresh observation, on the same screen and active surface,
with the same unique target, before the normal guarded mutation path dispatches.
One match allows at most one tap. No scripts, route guessing, fuzzy reactions,
retries, or unbounded sequences. A busy hand produces `hand_busy` evidence;
Scout rechecks later and never executes a disappeared, queued trigger.

`{type:'stop'}` instead stops future Scout input without pretending to cancel
an already-dispatched action. Conditions accept exactly one of `text`, `gone`,
`screen`, or `surfaceChanged:true`. Text/screen matching is exact; missing text
in an omitted brief section is not proof of `gone`. Maximum eight active jobs,
each 1–30,000 ms; screen/surface changes retire tap rules. Timeout does nothing.

Cancellation is deliberately explicit:

- `cancel('wait', conditionId)` stops only that condition wait.
- `cancel('reaction', conditionId)` removes only that rule.
- `cancel('actions')` stops future Scout input; there is no automatic resume.
- Cancelling an app operation requires its own authorized app action.
- `close()` drains the current action, closes both connections, and leaves the
  Flutter app running. Afterwards use the exact named `stop --clear-session`.
- Transport abort/loss is not app-operation cancellation. Reconcile any
  in-flight action before opening a new client or issuing further input.

## Observation and bounds

`inspect` reports `rendering.status`, `framesEnabled`, lifecycle, completed
framework-frame count, and age of the last observed framework frame. An old
frame can be a quiet screen. Disabled frames are suspended rendering, not a
healthy unchanged screen. `pixelFreshness:not_observed` explicitly excludes
compositor and platform-view pixels. Agent input requires active rendering and
the helper's `liveRenderingGuardV1` capability. Old helpers remain observable;
update the helper and fully relaunch for agent input. Every scene carries
`inputBlockedReason` (null when `actionable`), e.g. `rendering_suspended`,
`helper_capability_missing`, `receipt_unacknowledged` or a halt reason.

Sampling defaults to 250 ms (configurable 100–10,000); reads are deduplicated,
not piled up. Identical semantic/safety/rendering state is coalesced. Up to 64
observed transitions/events are retained. Overflow halts further input and
reserves terminal evidence, rather than silently losing alerts. Consume events
continuously during a task; this is not indefinite unattended monitoring.
Polling can miss transitions shorter than a sample, and an event is evidence
of a past observation, not a reusable current action authorization.

All actions carry the decision's `viewRevision`; a changed revision is
rejected, with one exception. tap or long-press on one exact observed handle,
input with `params.target`, and fill keyed by handles still proceed when the
only change is in-place text outside those targets, such as a clock or a
countdown label. Route, surface, rendering, safety evidence, field values,
scroll state, the kind and state of every control, and the target nodes must
be unchanged, and text must not appear or disappear. Text-target, coordinate,
gesture, navigation and deeplink actions need the exact revision. Fresh CLI
preflight verifies run/runtime and rendering and repeats the same comparison
against the decision view; the helper checks generation, target safety, and
rendering again at dispatch.
No frame age heuristic authorizes a stale decision. Runtime replacement,
unavailable reads, unknown action outcomes, or incomplete safety stop the loop.
Make a fresh deliberate decision after reconciliation, never just replace the
revision on the old action.

## Raw JSONL contract (agentProtocol 2)

The first line is a `type:ready` response. Subsequent requests require a unique
`id` (1–64 ASCII letters/digits/underscore/hyphen), `method`, and only the fields
shown above. Replies may arrive out of order and echo `id`. Consume the normal
Scout envelope's `result` once. Methods: observe, status, start, watch, react,
foreground (no parameters), next (`timeoutMs` 0–30,000), acknowledge (`actionId`), reconcile (`actionId`,
`viewRevision`), query (`query: {method,args,params}`), cancel, close.
Raw request lines are at most 64 KiB;
at most 16 requests in flight and 10,000 request identities per connection.
Malformed/uncorrelated output, child exit or transport timeout invalidates the
shipped client. Its error has a distinct `code` (`scout_agent_exited`,
`scout_agent_protocol_error`, `scout_agent_request_timeout`, ...) plus
`exitCode`, `signal` and the last CLI `stderr` line. `dispatch` is
`dispatch_outcome_unknown` only when an input (start/act, unread receipt or
armed reaction) was in flight; otherwise `not_dispatched`. Connect failures keep
the CLI cause: `session_not_registered`, `agent_session_busy`,
`scout_helper_missing`, `scout_app_unreachable`, `scout_agent_protocol_mismatch`.
No retries are implemented.

Do not use `--single-json`, nested `flutter-scout serve`/`batch`, a Scout
process per request, or PTY echo for this stream. Use one persistent pipe (the
client or its shell bridge) and manual screenshots when
appearance, custom paint, or native content matters.
