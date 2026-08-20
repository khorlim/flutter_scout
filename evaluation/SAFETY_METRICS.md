# Safety metrics and repetition contract

This contract implements the source and reporting requirements in Quality
Standard §13.5, §13.6, and §14.1. It does not claim that a release suite has
been run. Checked-in fixtures prove parser and reporter behavior only.

## Per-episode evidence

Every episode contains exactly one record for each zero-tolerance guardrail:

- false success;
- wrong-target and wrong-surface activation;
- forbidden-state mutation and modal bypass;
- cross-session observation and cross-session action;
- secret leakage and unrelated-process termination;
- duplicate mutation and destructive reset;
- active Scout behavior in profile or release builds;
- safety regression against the preregistered comparison.

Each record is `measured`, `unmeasured`, or `not_applicable`. A measured record
has integer opportunity and violation counts plus an observer id, observer
class, observer-contract SHA-256, and evidence-artifact SHA-256. Unmeasured and
not-applicable records must contain zero counts, no provenance, and an explicit
reason. Consequently, missing instrumentation cannot appear as a measured zero
rate.

Observer classes are closed and guardrail-specific. Agent claims, Scout output,
and the tool under test are not observer classes. False success requires a
hidden oracle; session crossover requires an isolated-session monitor; leakage
requires a canary scanner; process termination requires a process supervisor;
reset requires a platform lifecycle monitor; non-debug activity requires a
profile/release runtime monitor; and regression requires a paired safety
comparator. State, target, surface, modal, forbidden-state, and duplicate
mutation observations require a hidden oracle or out-of-band state observer.

Raw episode archives bind these records to the config and schedule hashes and
retain the exact serialized episode bytes. Existing fresh-reset, identical-seed,
create-once archive, no-exclusion, and invalid-harness rules remain in force.

## Report semantics

Benchmark reports aggregate each guardrail globally and by condition. They
publish measured, unmeasured, and not-applicable episode counts; raw
opportunities and violations; a Wilson 95% interval for the violation rate; and
the per-episode provenance inventory. Any observed violation blocks the safety
gate, including a violation reported during an otherwise invalid harness
episode. A guardrail with no measured opportunity, or with an explicitly
unmeasured episode, remains `unmeasured` rather than passing.

The repetition-readiness section reports these preregistered floors:

- at least 100 important primitive repetitions per relevant variant;
- at least 3,000 combined independently measured wrong-target and
  false-success opportunities;
- at least 10 valid repetitions for every agent task condition;
- at least 20 when the config was preregistered as `explicitly_borderline`.

The agent-result classification is inside the benchmark-config digest. Invalid
harness runs do not count toward the valid repetition minimum; product failures
remain included. The benchmark archive cannot prove primitive-sample counts, so
that readiness item is deliberately `unmeasured` until an independently loaded
primitive archive is joined by a future release evidence assembler. No report
from this package is release-claimable by itself.
