# Production phase timings

Flutter Scout reports one canonical timing record for each phase of a request:

```text
connect -> snapshot -> match -> dispatch -> settle -> delta -> logs -> serialize
```

These timings are operational evidence, not a claim that the application is
fast. In particular, `settle` is application-observation time and is kept
separate from Scout action overhead.

## Phase definitions

| Phase | Owner | Measured scope |
| --- | --- | --- |
| `connect` | CLI | VM-service connection establishment or explicit reuse decision before the request. |
| `snapshot` | helper | Fresh observations made before the first dispatch, including immediate state validation. |
| `match` | helper | Selector matching, ranked resolution, safety checks, and immediate revalidation. |
| `dispatch` | helper | The one intended interaction or state-operation dispatch, including a gesture's bounded pointer lifecycle. |
| `settle` | helper | Post-dispatch activity observation, frame settling, condition waits, and semantic quiescence. |
| `delta` | helper | Post-dispatch observations and factual before/after delta construction. |
| `logs` | CLI | Bounded log-cursor collection, its intentional log-settle window, and log expectation checks. |
| `serialize` | helper + CLI | The helper's bounded VM-response encoding probe plus bounded response normalization and JSON serialization at the final output boundary. |

The helper uses one monotonic exclusive timeline. Entering a phase closes the
preceding interval at the same clock reading. Nested work inherits its outer
phase: for example, snapshots sampled by the stability observer belong only to
`settle`; they are never double-counted as `snapshot` or `delta`. Repeated
navigation passes may revisit phases, and their exclusive intervals are added
to that phase's total. Phase-name order is the canonical interpretation order,
not a claim that a composite navigation transaction can enter each bucket only
once. Every individual interval is monotonic and non-overlapping.

Mutation preflight and the action are two sequential VM calls. Their like-named
exclusive intervals are summed and retain separate `preflightElapsedMs` and
`actionElapsedMs` facts. A native mutation's post-dispatch inspect is
reclassified from `snapshot` to `delta` before the same sequential aggregation.

## Machine contract

Every response carries all eight keys under `timings.phases`. A phase is either:

```json
{
  "status": "measured",
  "elapsedMs": 12,
  "owner": "helper",
  "clock": "monotonic_stopwatch",
  "aggregation": "exclusive_non_overlapping"
}
```

or:

```json
{
  "status": "unavailable",
  "elapsedMs": null,
  "owner": "helper",
  "reason": "phase_not_reached_before_response"
}
```

`elapsedMs` is always a non-negative integer when measured and is always null
when unavailable. An unavailable phase always includes a non-empty reason.
Reads can truthfully report a phase as unavailable with a
`not_applicable_for_read:<command>` reason. A helper response marks CLI-owned
`connect` and `logs` phases `measured_at_cli_boundary`; the CLI replaces those
records before final output and evidence persistence. The helper measures its
own `serialize` component, and the CLI adds its non-overlapping final-output
component to that canonical phase.

`timings.actionOverheadExcludingSettleMs`, when present, is the sum of the
exclusive measured phases other than `settle`. If a required phase is missing
or invalid, the numeric field is omitted and
`timings.actionOverheadExcludingSettle` names the unavailable phases instead of
inventing a partial total.

## Interpretation limits

- Millisecond values are rounded down from monotonic microsecond accumulation;
  fast measured work can therefore be `0`, which is distinct from unavailable.
- A response cannot contain the elapsed time of the very encoding operation
  that created it without a causal loop. Both boundaries therefore measure a
  first canonical bounded encode and insert that measurement into a second,
  structurally equivalent final encoding. The measured scope says `probe`
  explicitly; final stream or socket write latency is not included.
- Phase totals describe Scout's instrumented transaction. Benchmark reports
  remain authoritative for whole-process wall time, CPU, memory, frame time,
  hardware, OS, Flutter version, build mode, fixture, viewport, and tree size.
- A measured dispatch proves that Scout attempted the reported interaction. It
  does not prove a business postcondition; dispatch, observation,
  postcondition, and runtime-health outcomes remain independent fields.

See [the public-operation inventory](production-phase-timing-inventory.md) for
the applicable and explicitly unavailable phases of every CLI command,
including native mutations, mixed read/write endpoints, composite operations,
failures, compact evidence, and durable replay.
