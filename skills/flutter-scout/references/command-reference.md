# Command reference

UI interaction is exclusively the agent protocol, independent of model or
service tier. Standalone inspect, where, locate, bounds, gestures/input,
wait/wait-for, deeplink, live, serve, explore, batch, record and replay are
removed. No legacy flag restores them.

## Agent protocol 2

Use the shipped scripts/agent_client.mjs over one persistent JSONL pipe.

- observe(): current revision, view age, screen, exact targets and safety.
- foreground(): explicit macOS activation of this session's connected app only,
  followed by fresh observation. Shares the hand; never sends UI input, fakes
  rendering, acknowledges receipts, or clears a failure halt.
- query(method, params, args): focused read-only inspect, where, locate, bounds,
  or drag-status. Parameters use camelCase; maxItems is 1..100. inspect accepts
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
- react(viewRevision, condition, reaction, timeoutMs): one explicitly authorized
  exact-target tap or stop-future-input rule; at most 30 s.
- cancel(scope, conditionId): cancel a wait/reaction or stop future actions.
- status(), close(): connection status and graceful drain/close, not app stop.

Actions: tap, tap-text, long-press, input, fill, scroll, swipe, scroll-to,
reveal, back, dismiss, drag-start, drag-move, drag-end, drag-cancel, deeplink.
Action parameters remain typed; no expect*, waitMs, allowErrors, file/stdin
source flags, verbose or automatic image capture. Text/input values travel in
the JSON pipe, not shell argv. Native deep links remain capability-gated.

Conditions accept exactly one of text, gone, screen or surfaceChanged:true.
A timeout does not cancel app work. Missing text in an omitted section does
not establish absence. Already-visible text does not prove a new operation.

## Finite lifecycle and manual diagnostics

Lifecycle: devices, doctor, ensure, launch, attach, status, apps, reload,
restart, stop, version. Annotation management: annotations. Manual evidence:
screenshot, crop, logs, health, evidence.

Supply VM capability URLs using attach --debug-url-file <0600-file> or
--debug-url-stdin. Only explicit loopback hosts with a port are supported.
Use --single-json first for one final envelope; stderr carries progress.
The prefix is not accepted by agent. Help does not contact a running app.

Retain commandId, run/runtime/state identity, dispatch, observation,
postcondition, runtimeHealth, stability, evidence and omission status when
summarizing. A final successful screenshot cannot make a preceding failed
input successful. Do not chain fallible operations without checking outcomes.
