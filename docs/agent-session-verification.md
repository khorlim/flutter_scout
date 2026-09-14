# Agent session verification — 2026-09-15

Scope: local macOS debug build of `apps/scout_test_app`, the shipped Node
client, and a compiled candidate CLI. These are development checks, not release
ratification, a protected holdout, or proof of human-equivalent navigation.

## Actual macOS operation

Navigated Supplier list → Stress Lab → Eye-hand probe from observed targets and
visible text through the new API. A real handshake exposed missing canonical
`ok` propagation in the client and missing compact safety metadata in the
observer; both were repaired before the successful trials below. The client
test fixture now models canonical envelope metadata separately from `result`.

`node tool/agent_runtime_smoke.mjs <session> <candidate> hold flash quiet hold flash`
ran five successful trials at 250 ms sampling, screenshots manual:

| Trial | Acceptance | Verified start receipt | Pause after notice | Input actions |
| --- | ---: | ---: | ---: | ---: |
| Persistent notice 1 | 1 ms | 217 ms | 187 ms | 2 |
| Transient notice 1 | 1 ms | 211 ms | 210 ms | 2 |
| No notice | 1 ms | 218 ms | No pause | 1 |
| Persistent notice 2 | 1 ms | 212 ms | 227 ms | 2 |
| Transient notice 2 | 1 ms | 237 ms | 196 ms | 2 |

After closing a legacy-argument safety-override gap, a newly compiled final
candidate repeated hold/flash/quiet successfully: tickets 1/1/1 ms, receipts
268/255/273 ms, notice-to-pause 252/227 ms, and no quiet-case pause. Eight total
successful runs; the final repeat ran while the full CLI suite was active.

All four notice trials paused before work completed, with no late/duplicate
pauses. The quiet trial reached Ready without a speculative pause; its local
rule expired at three seconds while the independent completion wait remained
active. Each action's canonical receipt succeeded. Timing is from the app's
callback timestamps, **not first-pixel presentation**. These local reactions
execute an exact authorized response, not a new model decision.

The app initially reported a transient launch failure while its owned worker
continued; read-only status recovered the same reachable run without launching
a duplicate. Rendering reported frames enabled with unknown lifecycle on this
Mac. That is framework availability, not proof of foreground/compositor pixels.
An additional cancellation check obtained a new observation in 51 ms while
the hand still reported a pending action. Cancelling a separate wait and then
stopping future input left that one in-flight input to finish successfully.
Computer Use reported the Mac locked, so native minimize/restore and visual
confirmation were unavailable. Suspended-rendering rejection was verified at
the helper boundary in tests, not presented as a live window check.

## Automated boundaries

- CLI tests cover one hand with concurrent reads, retained transient views,
  stale revisions, runtime replacement, malformed observations, unknown action
  outcomes, wait/stop cancellation, explicit overflow, exact-target one-shot
  rules, context changes, quiet timeouts and omitted-text abstention.
- Helper tests cover passive frame/lifecycle observations and the immediate
  suspended-rendering mutation guard without dispatch or Scout-driven frames.
- Node tests cover out-of-order correlated replies, historical-view ordering,
  transport loss without retry, malformed output and orderly close.
- Existing full CLI, helper and verification-app suites are also run. A
  pre-existing semantic-stability test's unawaited `pump` raced under concurrent
  suite load; it passed focused and the full helper suite passed with test
  concurrency one. No production workaround was added for that test race.

## Interpretation

The implementation removes a model round trip for the explicitly preauthorized
response and keeps business waits independent from input. It does not prove a
universal speed winner: model decision time, sampling gaps, rendering
suspension, complex target discovery and pixel-only content still matter.
Active continuous sampling is bounded; consumer overflow stops further input.
Use manual screenshots for appearance and native/custom-paint content.
