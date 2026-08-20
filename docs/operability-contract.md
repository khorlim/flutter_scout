# Flutter Scout operability contract

`status`, `doctor`, `health`, and the persistent transport's `GET /health`
emit the same additive `operability` object. Its `contractVersion` is `1`.
The object is bounded by the normal CLI response limit and is sanitized before
serialization.

The contract reports facts in these domains:

- the running CLI binary and, only when observed from a helper response, the
  compiled `flutter_scout_helper` package version;
- the CLI-supported protocol range, the helper-observed range and
  capabilities, and the negotiated intersection;
- session, run, source, runtime, state-generation, device, runner, and
  supervisor identities;
- app reachability, log/event cursors, and log, recording, and evidence paths;
- the held-drag mutation-channel state and in-app recording state;
- the most recently persisted hot-update source verification; and
- exactly one prioritized recovery action when Scout can identify one.

Every optional domain has a `status`, `reachability`, or explicit `reason`.
Scout does not label a helper protocol as negotiated when no helper response
was observed, does not call recorded process metadata a live ownership proof,
and does not invent runtime or source identities. A missing fact remains
`unavailable` or `null`.

## Command meanings

- `status` examines the saved session, validates reachability, revalidates
  ownership where possible, and takes bounded read-only helper observations.
- `doctor` adds project integration, requested-device resolution, and
  temporary-helper recovery diagnostics to the same operability object.
- `health` reports current runtime errors, log signals, degraded observation,
  active drag, recording state, and whether the app is currently reachable.
- Authenticated persistent `GET /health` separates `transportHealthy` from
  `healthy` and `appReachable`. An alive loopback daemon therefore stays
  truthfully ready while an absent app is reported as unhealthy and
  unreachable. It uses the same ephemeral owner-only bearer credential as
  other state-bearing persistent calls.

Runtime operability observation uses `inspect --brief`, `drag-status`, and
`record status`. These are observation-only helper calls. Each read has a
three-second ceiling; a timeout becomes an explicit unavailable reason. The
diagnostic path never schedules a Flutter frame or performs an application
mutation.

## Source freshness

`reload` and `restart` persist a small, sanitized `lastHotUpdate` summary in
session metadata. `sourceFreshness` is populated only from that observation.
Before a hot update has produced source-verification evidence, the status is
`unavailable`; hot-update capability is not presented as proof that disk and
runtime source match.

## Persistent health example

```json
{
  "ok": true,
  "transportHealthy": true,
  "healthy": false,
  "appReachable": false,
  "authenticationRequired": true,
  "transport": {
    "status": "ready",
    "kind": "persistent_loopback_http"
  },
  "appHealth": {
    "ok": false,
    "healthy": false,
    "appReachable": false
  },
  "operability": {
    "contractVersion": 1,
    "prioritizedRecoveryAction": {
      "status": "recommended",
      "priority": 1,
      "action": "flutter-scout ensure --device <simulator-id> --project <path>",
      "reason": "app_unreachable"
    }
  }
}
```

This is a source-level and deterministic-test contract. It does not by itself
claim current simulator/device attainment.
