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
uses CPU. If a launch fails, read `error.message`, `failureMode` and
`failureCause` before retrying, and raise `--launch-idle-timeout <s>` or
`--launch-timeout <s>` only when they say a limit ended a live build.

Keep the launch process attached until its final envelope. Progress belongs
on stderr; do not merge it into JSON stdout. While heartbeats continue, do
not start parallel status polling or another launch. Use attach only to
preserve a human-started app; VM capability URLs must enter through a 0600
file or stdin, never process arguments. Read the setup skill when needed.

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
// Read outcome.ok, result, scene, and intervening events before deciding again.
```

### Shell-only agents (Claude Code)

When each shell command is a fresh process, keep the one connection in the
shipped bridge. `serve` returns once connected (with the first `scene`) and
keeps a background process behind a private 0600 Unix socket. Each `call`
prints one compact JSON line; exit code 0 means `ok:true`. `<client>` is this
skill's absolute scripts/agent_client.mjs path; spell it out in every command
because shell variables do not persist between tool calls.

```bash
node <client> serve --app task
node <client> call --app task observe
node <client> call --app task act '{"viewRevision":7,"action":{"method":"tap","args":["btn.save"]}}'
node <client> call --app task query '{"method":"locate","params":{"text":"Save"}}'
node <client> call --app task watch '{"condition":{"text":"Saved"},"timeoutMs":8000}'
node <client> call --app task next '{"timeoutMs":8000}'
node <client> call --app task act - <<'JSON'
{"viewRevision":8,"action":{"method":"input","args":["value"],"params":{"target":"field.email"}}}
JSON
node <client> call --app task disconnect   # before reload/restart
node <client> stop --app task              # closes Scout and the bridge
```

input/fill must use `-` with stdin; argv is refused. Other methods: status,
foreground, start, acknowledge, reconcile, react, cancel (same fields as the
client). After `disconnect` or a lost agent process, the next call reconnects
and reports `bridge.reconnected` with any `previousLoss`; until you observe,
revision-bound calls are refused (`bridge_reconnected`, nothing sent). An
in-flight input is never resent. A bridge idle for 30 minutes stops itself.

act performs one input, consumes its canonical receipt, acknowledges success,
and returns the latest scene. Eyes continue independently while the hand runs.
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
for a target; scout.query('inspect', {sections: 'interactables,scrollables',
maxItems: 100}) for selected detail. Query is read-only, not permission to act
on stale geometry: observe again and decide from the current scene.

Prefer exact observed handles, then unique visible text. Ambiguity requires
focused discovery, not another guess. For forms, `fill` takes an observed
field-to-value map: `{method:'fill', params:{json:{[fieldHandle]:value}}}`.
For one field, use `{method:'input', args:[value], params:{target:fieldHandle}}`.
The input target belongs in `params.target`, not in `args`. Omitting it types
only into an already focused field; opening a form does not imply focus.

Choose from reported candidates or narrow context. A stale state requires
fresh observation and a new decision, not replacement of the revision on an
old action. Coordinates are logical Flutter points, not screenshot pixels;
use them only when observed handle/text targeting cannot express the action.
For lazy lists, use region-scoped bounded reveal/scroll-to through act.

Sensitive input belongs in agent JSON stdin through the client, never shell
arguments or printed results. Do not use allowErrors, waitMs, expect flags,
file input or capture flags in actions; these are rejected.

## Completion and recovery

Input completion and business completion are separate. watch({text: 'Saved'},
8000) returns a ticket; consume next events until that condition's event.
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

Rendering suspended means restore app visibility. Never pump frames or treat
an old semantic tree as current pixels. An active framework frame does not
prove the native window is visible. Manual images are required for visual QA.
For a named macOS session, explicitly call `await scout.foreground()` to
activate only its observed app process, then check the returned fresh scene.
It uses normal OS activation, not a rendering override, and sends no UI input.
It refuses during input or an unread/unknown receipt. A received known failure
can restore visibility, but still needs explicit reconciliation; activation
never clears its halt or acknowledges its receipt.
Do not repeatedly steal focus from the user or treat activation as save success.

For an authorized time-sensitive response, react can issue one exact observed
tap or stop future input, bounded to 30 seconds. It cannot invent targets,
retry, cross surfaces, or cancel an already-started app operation.

## Changes, images, and handoff

Close the agent connection before reload/restart, then reconnect (bridge:
`disconnect`, reload, then `observe`; if a scene shows `hand.halted` after a
restart, `disconnect` and observe again). Use reload
for Dart changes; sourceVerification:mismatch is a failure. A rejected reload
does not imply the app died: check status and preserve a reachable session.
Native/plugin/pubspec changes need a full launch. Lifecycle and ownership
recovery details: [lifecycle-and-diagnostics.md](references/lifecycle-and-diagnostics.md).

Screenshots and crops stay manual. Capture only when appearance matters or
semantic evidence is insufficient, and inspect the image before claiming
visual verification. Details: [gestures-and-visuals.md](references/gestures-and-visuals.md).

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
