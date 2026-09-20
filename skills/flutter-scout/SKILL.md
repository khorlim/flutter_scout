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

Keep the launch process attached until its final envelope. Progress belongs
on stderr; do not merge it into JSON stdout. While heartbeats continue, do
not start parallel status polling or another launch. Use attach only to
preserve a human-started app; VM capability URLs must enter through a 0600
file or stdin, never process arguments. Read the setup skill when needed.

## One eyes-and-hands connection

Read [agent-session.md](references/agent-session.md) before first use. Import
this skill's scripts/agent_client.mjs into a persistent Node tool session.
Keep the same object between decisions. If no persistent Node tool is
available, keep a Node process alive with Scout connected by ordinary pipes;
do not launch Scout per request or use PTY echo for its JSONL transport.
For an interactive Node terminal fallback, request a short output yield
(250–1000 ms) on each write, then read again only if the awaited result is
still pending. A 30-second terminal yield waits even after Scout has replied;
it is not an app-settling requirement. Prefer direct awaited Node tool calls
when available.

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
For an observed unwrapped custom field whose own render object is not safely
hittable, supply its separately observed user-like activation handle in the
same action: `{method:'input', args:[value], params:{target:fieldHandle,
activationTarget:tapHandle}}`. Scout guards and taps only that explicit handle,
then types only if the exact field is the unique focused editable. Never infer
an activation handle from ancestry or reuse one after a changed revision.

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

After a failed action, examine its receipt and the fresh scene. For a known
dispatch outcome only, explicitly reconcile(actionId, scene.viewRevision)
after checking app state. Reconciliation does not repeat input. Unknown
dispatch, runtime replacement, or lost evidence stays halted; investigate
before opening another connection. Never suppress errors to keep navigating.

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

Close the agent connection before reload/restart, then reconnect. Use reload
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

Finish with scout.close(), then stop the exact owned run unless the user wants
it left open for immediate testing:

```bash
flutter-scout --app <task> stop --clear-session
```

Require ok:true, sessionCleared:true, and recordedRuns.unresolved:[] before
claiming cleanup. Never stop a human-owned or another task's run.
