# Production phase timing inventory

This inventory maps every public Flutter Scout CLI operation to the canonical
phase contract. It is a truth table, not a promise that every phase applies to
every command. Every machine response is structurally closed with exactly:

```text
connect, snapshot, match, dispatch, settle, delta, logs, serialize
```

A measured phase carries a non-negative integer `elapsedMs`. An unavailable
phase carries `elapsedMs: null` and a non-empty reason. A missing or malformed
upstream record is normalized to an explicit `*_phase_missing_from_response`
or `invalid_*_phase_record` reason; Scout never substitutes zero for missing
work.

## Instrumented transaction families

| Public operations | Classification | Applicable phase facts |
| --- | --- | --- |
| `tap`, `tap-text`, `long-press`, `input`, `fill`, `scroll`, `scroll-to`, `swipe`, `drag-start`, `drag-move`, `drag-end`, `drag-cancel`, `back`, `dismiss`, `reveal` | Helper mutation | CLI measures `connect`, bounded `logs`, and final `serialize`. The helper measures every phase it actually reaches. Selector-free or split-gesture phases are unavailable with an explicit `not_applicable:*` reason. |
| `annotations enable`, `disable`, `clear`, `delete`, `resolve`, `dismiss`, `reopen`, `fixed`, `check`, `signal-handoff` | Helper tool-state mutation | The protocol safety precondition is `snapshot`; actual annotation writes are `dispatch`; overlay/frame observation is `settle`; returned fresh annotation state is `delta`. There is no widget selector, so `match` is explicitly unavailable. Action-result evidence retains the same closed timing set. |
| `record start`, `stop`, `pause`, `resume`, `undo` | Helper recorder-state/storage mutation | The protocol safety precondition plus start/resume baselines and stop flush work are `snapshot`; actual recorder or storage writes are `dispatch`; overlay reconciliation is `settle`; the post-dispatch protocol identity observation is `delta` because recorder state is canonical agent-visible state. Selector `match` is explicitly unavailable. |
| `reload`, `restart` | CLI-native mutation | Pre-update inspect contributes `snapshot`; signal/VM update is `dispatch`; acknowledgement and quiescence are isolated in `settle`; post-update source/state verification is `delta`; recent-log collection is `logs`. `match` is explicitly unavailable because there is no selector. |
| `deeplink` | CLI-native mutation | Pre-open inspect is `snapshot`; the platform URL open is `dispatch`; helper quiescence is `settle`; post-open inspect and factual comparison are `delta`; there is no selector `match`. iOS simulator and Android ADB dispatch use the same timing contract. |
| `batch`, `explore`, `replay`, `record run` | Composite orchestrator | Each child mutation retains its own canonical timing transaction and durable identity. The aggregate command response is not treated as a fictitious overlapping ninth transaction; unavailable aggregate buckets say that per-step timing is authoritative. Cached VM-service connection reuse is measured for each child as an explicit reuse decision. |

Mutation preflight is a separate, earlier helper call. Its exclusive
`snapshot` and helper `serialize` intervals are added to the action call using
`exclusive_non_overlapping_cross_call_sum`, with `preflightElapsedMs` and
`actionElapsedMs` retained. Native composites use the same rule for sequential
pre-action and post-action observations; post-dispatch inspect work is
reclassified as `delta`, never counted again as `snapshot`.

## Read and observation operations

| Public operations | Applicable phase facts | Forced-unavailable facts |
| --- | --- | --- |
| `inspect`, `where`, `locate`, `bounds` | A helper snapshot is measured when the helper is queried; `connect` and final CLI `serialize` are measured at their boundaries. | Mutation-only `dispatch`, `settle`, and `delta` are unavailable for a plain read. Resolver work is `match` only when that path actually enters the resolver. CLI projections that intentionally construct a smaller local result can report the upstream helper phases as unavailable rather than inventing measurements. |
| `annotations list`, `targets`, `wait`; `record status` | Every tracked helper response measures the fresh protocol identity `snapshot`; annotation wait also measures its bounded observation work. | No write is timed as `dispatch`. Recorder metadata reads mark `match`, `dispatch`, `settle`, and `delta` `not_applicable_for_read:record`. |
| `drag-status` | Connection and output serialization are measured. | The held-pointer status read performs no snapshot, match, dispatch, settle, or delta. |
| `wait`, `wait-for` | The bounded polling/observation interval is measured as `settle`; `wait` can also measure the final response `snapshot` after that interval closes. | No app interaction is reported as `dispatch`. Poll-time snapshots and condition checks inherit the outer `settle` interval, so they are not double-counted as `snapshot` or `match`. |
| `screenshot`, `crop` | Final CLI serialization is measured. Helper-backed capture/locate subcalls retain their own snapshot/connect measurements while native iOS/Android capture reports factual capture metadata. | A capture is observation, not an app mutation. Platform process and file-write latency is not relabeled as interaction dispatch. |
| `logs` | Log cursor/file collection is the applicable `logs` phase; final output JSON is `serialize`. | Helper action phases are not applicable. |
| `status`, `doctor`, `health`, `devices`, `apps`, `evidence`, `export-batch`, `record list`, `record show`, `record export`, `version` | Final machine-output `serialize` is measured. Command-specific whole-operation durations remain available as `timings.totalMs`. | Canonical interaction phases are unavailable because these are local/session/process/evidence reads, not app action transactions. |

`help` is the one explicitly human-rendered surface; it does not claim a
machine response envelope. `serve` emits canonical timing records on each JSON
HTTP response and heartbeat. `vm-log-listener` and `flutter-run-worker` are
internal infrastructure commands rather than public app transactions.

## Lifecycle and local-storage operations

The remaining public commands are still closed structurally, but they are not
misrepresented as Flutter interaction transactions:

| Public operations | Timing disposition |
| --- | --- |
| `launch`, `ensure`, `attach`, `stop`, `cleanup` | Process/session lifecycle duration is reported by the command timer. Canonical action phases that were not captured are unavailable with reasons; no process launch or session-file edit is labeled as widget `dispatch`. |
| `record rename`, `record delete`, `record save-last` | Local recording-store work is not app dispatch. The response has all eight records; interaction-only phases remain unavailable. |
| `serve` | Server startup is lifecycle work; each served machine response independently measures final CLI serialization. Proxied app actions retain the action's own timing transaction. |

This distinction is deliberate. The canonical eight phases describe an agent
interaction with a running Flutter app. Whole-command lifecycle and filesystem
benchmarks require their own named measurements rather than silently widening
`dispatch` or `settle`.

## Evidence, failures, and replay

- Every helper response, CLI response, compact action result, action-result
  JSONL event, and durable mutation outcome is normalized to the exact eight
  keys.
- Protocol rejection, preflight failure, timeout, transport loss, oversized
  bounded fallback, evidence-write failure, and emergency helper fallback keep
  the timing set. Phases not reached before failure remain unavailable with a
  reason.
- Completed durable outcomes persist the canonical phase records. A replay
  returns those original measurements; it does not time a second dispatch.
  A measured original `connect` record is retained and adds
  `replayDeliveryConnection: skipped`; if no original connection measurement
  exists, the phase is unavailable with the exact durable-replay reason.
- Default compact output preserves `timings`; compaction never drops the phase
  set to save bytes.
- The generic `type: command` JSONL row is a lifecycle reservation, not action
  evidence. It carries all eight phases as unavailable with reason
  `lifecycle_reservation_not_action_evidence`; the separate `action_result`
  row owns the real mutation measurements.

## Serialization boundary

The helper JSON-encodes and UTF-8-measures the VM extension response before the
CLI sees it. It therefore performs a bounded first canonical encode, inserts
that measured helper component, then performs the final bounded encode. The
CLI later performs the same two-pass technique for the actual stdout, stderr,
heartbeat, HTTP, or action-event boundary.

The public `serialize` phase is the non-overlapping sum of those helper and CLI
encode probes and retains `helperElapsedMs` and `cliElapsedMs` when both exist.
The final stream/socket/file write latency is explicitly excluded and exposed
as `finalWriteLatencyIncluded: false`; Scout does not silently claim to have
measured a write that causally occurs after the response was constructed.
