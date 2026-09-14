# Live agent view (experimental)

This is the earlier serialized comparison interface. For concurrent hand/eye
operation, use the shipped [agent session](../skills/flutter-scout/references/agent-session.md).

`flutter-scout --app <name> live` keeps one VM-service connection open and a
bounded latest semantic view ready while an agent decides its next action.
Screenshots remain manual. This is an interactive JSONL session, not a recording.
The app must already be launched/attached under that named session.

The first stdout JSON response includes `viewId`, `view`, and `images: manual`.
Send one JSON request per stdin line:

```json
{"method":"tap","viewId":1,"args":["btn.notifications"]}
{"method":"observe"}
{"method":"wait","viewId":2,"timeoutMs":10000}
{"method":"close"}
```

Use the actual integer `viewId` returned by the previous response and an observed
target. Actions return their ordinary safety outcomes plus the resulting current
view in the same response. Make the next decision from that view; an extra inspect
is unnecessary unless the returned view is incomplete for the task. `params` use
the existing typed API's names and value types. Supported actions: tap, tap-text,
long-press, input, fill, scroll, swipe, scroll-to, back and dismiss. Input/fill
values may be passed inside stdin JSON (not process arguments); Scout's existing
input registration and redaction still apply.

In a tool environment, prefer a persistent process pipe that resolves one
awaited request when the complete response arrives. A terminal is also supported: disable
echo if using a PTY. Short terminal write waits may require an additional poll;
longer waits can avoid that poll but still add idle latency.
Do not use `--single-json`, which is for finite commands. Consume the normal
envelope's `result` once; do not retransmit the duplicate compatibility fields.

## Freshness and failure behavior

- Background observation defaults to every 1,000 ms (`--interval-ms` 250–10,000).
  It coalesces identical views and never emits unsolicited stdout floods.
- A background update does not mean the agent has read it. An action carrying an
  older view ID returns `live_view_changed`, no dispatch, and the latest view.
- Even when the buffered ID matches, the ordinary mutation preflight compares
  the agent's run/runtime/snapshot to a fresh helper observation. The helper's
  existing generation and immediate target checks cover subsequent races.
- A stale-view response is a request to reconsider the action, not permission
  to automatically repeat it with the new ID.
- Background reads and actions are serialized. No read backlog is accumulated
  while an action is in flight. `wait` wakes when an observed view changes.
- When a successful expectation returns transient stability, a bounded 1,500 ms
  passive readiness wait precedes the next working view. Its `settling` evidence
  is separate from the original action outcome. A failed/unactionable readiness
  observation makes the combined result unsuccessful without retrying the action.
- Runtime loss invalidates the buffer. Unknown dispatch, failed postconditions,
  runtime errors and failed evidence persistence retain their ordinary failure
  meanings. No action is automatically retried by the live loop.
- Full action evidence remains in Scout's normal session journal. The working
  response omits its bulky old geometry delta and timing table because the new
  view is supplied directly. Ordinary inspect/log/evidence commands remain usable.
- `close` or EOF stops the observer and closes its VM connection, leaving the
  app running. Use the ordinary exact-session stop when the task is finished.

## Limits

This is a latest-view handoff into tool responses, not host-driven model wakeup
or continuous visual perception. Background UI changes can still happen while
the agent reasons; they are caught before the old decision dispatches. Strict
snapshot comparison may cause extra reconsiderations on frequently changing
screens. Brief view omissions are explicitly reported (`--max-items`, default
30, range 1–100). Images, custom paint and other pixel-only changes are not
observed. Sampling still traverses the app tree; CPU/frame impact and ideal
sampling rate need wider measurement. Requests are bounded to 64 KiB per line.
