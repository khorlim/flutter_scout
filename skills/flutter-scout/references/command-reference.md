# Command reference

UI interaction is exclusively the agent protocol, independent of model or
service tier. Standalone inspect, where, locate, bounds, gestures/input,
wait/wait-for, deeplink, live, serve, explore, batch, record and replay are
removed. No legacy flag restores them.

## Agent protocol 2

Use the shipped scripts/agent_client.mjs over one persistent JSONL pipe.

- observe(): current revision, view age, screen, exact targets and safety.
- foreground(): explicit macOS activation of this session's connected app only,
  then up to 5 seconds of passive observation until rendering is active.
  Shares the hand and takes focus from the user; never sends UI input, fakes
  rendering, acknowledges receipts, or clears a failure halt. A failure names
  its cause in error.reason and the recovery in error.nextStep.
- query(method, params, args): focused read-only inspect, where, locate, bounds,
  drag-status, or system-dialog (a fresh native probe; no params). Parameters use camelCase; maxItems is 1..100. inspect accepts
  brief, surface, sections and since. It does not accept depth, maxNodes,
  waitForIdle or compact. Observe again after focused queries before deciding.
- act(viewRevision, {method,args,params}): one guarded input with independent
  observations, canonical receipt checking, success acknowledgement and a fresh
  returned scene. No retry or business-completion wait. Returns ok:false on
  failure; inspect result and events. Default whole-operation budget 45 s.
- start(viewRevision, action): low-level acceptance ticket, not success.
- next(timeoutMs): consume retained events; one consumer only.
- acknowledge(actionId): requires delivery of the successful canonical receipt.
- reconcile(actionId, viewRevision): explicit recovery from a known failed
  dispatch after fresh safe observation. Never retries; unknown stays halted.
- watch(condition, timeoutMs): asynchronous bounded condition ticket, not input.
- watchUntil(condition, timeoutMs): watch that returns the condition's end
  (bridge: watch with wait:true); ok only when met.
- react(viewRevision, condition, reaction, timeoutMs): one explicitly authorized
  exact-target tap or stop-future-input rule; at most 30 s.
- cancel(scope, conditionId): cancel a wait/reaction or stop future actions.
- status(), close(): connection status and graceful drain/close, not app stop.

Actions: tap, tap-text, long-press, input, fill, scroll, swipe, scroll-to,
reveal, back, dismiss, drag-start, drag-move, drag-end, drag-cancel, deeplink,
system-tap. `system-tap` takes one observed `view.systemDialog` button handle
in args (`['sys.allow']`) and optional `params.dialogOwner` for another app's
dialog; see system-dialogs.md.
`tap` takes `params.button: 'secondary'` for a mouse right click.
`tap` and `tap-text` take `params.taps: 2` for a double tap (two complete
taps at one point in one dispatch and one receipt) and `params.intervalMs`
(0-1000, default 100) for the gap from the first up to the second down. The
receipt's `activation.secondTap` reports `targetStillHit` (handle and text
targets) and `sameHitPathAsFirstTap`, with the new `hitPath` when it changed.
Action parameters remain typed; no expect*, waitMs, allowErrors, file/stdin
source flags, verbose or automatic image capture. Text/input values travel in
the JSON pipe, not shell argv. Native deep links remain capability-gated.

Conditions accept exactly one of text, gone, screen or surfaceChanged:true.
text/gone match visible text, interactable labels and handles exactly.
observe() lists texts that came and went since the last observe in
transientText.
A timeout does not cancel app work. Missing text in an omitted section does
not establish absence. Already-visible text does not prove a new operation.

## Finite lifecycle and manual diagnostics

Lifecycle: devices, doctor, ensure, launch, attach, status, apps, reload,
restart, stop, version, permissions (`permissions grant|revoke|reset
<service>... [--app-id] [--device] [--allow-app-termination]`, `permissions
list`; system-dialogs.md). Annotation management: annotations. Manual evidence:
screenshot, crop, logs, health, evidence. screenshot and crop take
`--with-overlay` to keep the in-app driving overlay (left out by default).

Logs: `logs --summary`, `logs --last <n>` (default 20, max 1000) and
`logs --contains <text>`. Use these instead of reading log files directly;
there is no `--tail`. Details: lifecycle-and-diagnostics.md.

Supply VM capability URLs using attach --debug-url-file <0600-file> or
--debug-url-stdin. Only explicit loopback hosts with a port are supported.
attach has no --name or --project; to attach a human-started app as a named
session, use `ensure --project <app> --name <task> --debug-url-file <file>`.
A stopped Scout build relaunched outside Scout re-attaches under its own run
when the session record names it; after the record is cleared, pass the
launch's recorded `runId` with `ensure --name <task> --debug-url-file <file>
--expect-run-id <runId>` (or `attach --expect-run-id` while the session is
still registered). Details:
lifecycle-and-diagnostics.md.

Global options go before the command, in any order: `--app <name>`,
`--single-json`, `--idempotency-key <key>`. Use --single-json for one final
envelope; stderr carries progress. It is not accepted by agent. Every command
has its own help (`flutter-scout <command> --help` or `help <command>`), which
lists its real options and does not contact a running app. An unknown option
fails with `unknown_parameter` and lists that command's valid options.

### Reading finite command output

- With `--single-json`, stdout holds exactly one line: the final envelope
  (`messageType:"response"`). Progress goes to stderr.
- Without it, stdout is JSONL. Every `messageType:"heartbeat"` line carries
  `ok:true` by contract while the command is still running; it is progress,
  not an outcome. Read only the `messageType:"response"` line for success.
- Envelope keys lead with `messageType`, `ok`, `commandName`, `error` (on
  failure) and `result`; bulky `timings`, `payloadBounds` and `capabilities`
  come last, so read fields by name instead of truncating output by bytes.
- `result` is usually the command's payload object, also flattened at the top
  level. `reload` and `restart` are the exception: `result` is a string,
  `changed`, `unchanged` or `reload_rejected`, and the details such as
  `sourceVerification`, `reloadReport`, `appReachable` and `delta` are
  top-level fields.

Retain commandId, run/runtime/state identity, dispatch, observation,
postcondition, runtimeHealth, stability, evidence and omission status when
summarizing. A final successful screenshot cannot make a preceding failed
input successful. Do not chain fallible operations without checking outcomes.
