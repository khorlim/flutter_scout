# Endurance and resource evidence runner

The endurance runner implements the executable evidence contract behind
`QUALITY_STANDARD.md` §§11, 14.2, and 15. It is a harness, not a checked-in
performance result. Short deterministic tests use `mode: test_only` and are
structurally unable to produce a passing endurance gate.

## Immutable inputs

`schemas/v1/endurance_config.schema.json` and `EnduranceConfig` pin the full
Scout condition and performance environment, debug build mode, named session,
harness controller build and setup/teardown fixture digests, CPU/RSS/frame
collectors, fixed action plan, seed, command deadlines, liveness bounds,
memory-growth method, response bound, and archive bound. Unknown fields are
rejected.

The `fixed_cycle_v1` scheduler repeats the declared action sequence exactly.
For every mutating step it derives a unique caller idempotency key from the
config-bound plan digest, seed, endurance run id, and sequence number. The raw
key is passed only to Scout; the step archive records an argument digest. The
runner owns `--app` and `--idempotency-key`, and it rejects lifecycle commands
that could replace the anchored runtime.

Plans must use Scout's protected stdin/file ingress for sensitive input; do not
place secrets in the immutable config or process arguments.

A `release_evidence` config must preregister at least 60 minutes or 1,000
actions and may not weaken the 20 MiB incremental RSS guardrail. A shorter
config must say why it is `test_only`; its component status is always
`unmeasured`, regardless of how clean or fast its fake values look.

## Independent controller boundary

The runner accepts an `EnduranceHarnessController`. A real controller must use
an out-of-band app integration, profiler, process monitor, or device API; it
must not derive setup, liveness, resource, frame, or progress facts from Scout's
own claims. It provides three bounded hooks:

1. `setUp` performs and proves one fresh deterministic fixture reset, then
   anchors the exact session, run, runtime, process, and fixture generation.
2. `probe` samples that same identity after every successful Scout step and
   returns a digest-only progress signature plus pinned CPU, RSS, and frame-time
   provenance.
3. `tearDown` proves that the exact anchored fixture was cleaned and its reset
   generation advanced.

The `ScoutCommandExecutor` boundary is reused from the tool-simulator harness.
`ProcessScoutCommandExecutor` launches an executable and argument vector
directly; neither the action plan nor the endurance runner evaluates a shell
command string. Applications can supply an in-process controller or a strictly
typed process/device adapter without changing the runner.

## Per-step evidence and stopping rules

Before the measured interval, the runner performs a brief inspect and an
independent baseline probe. The outcome records separate harness and measured
UTC intervals, while `durationMs` covers only the latter (setup and teardown
cannot inflate eligibility). Every measured step then archives:

- exact bounded stdout/stderr bytes plus their SHA-256 digests and sizes;
- command, run, runtime, state-generation, and log-cursor correlation;
- all eight measured phases (`connect`, `snapshot`, `match`, `dispatch`,
  `settle`, `delta`, `logs`, `serialize`);
- total step latency and exact response bytes;
- CPU, RSS, and frame-time observations with pinned provenance;
- the out-of-band progress signature and no-progress streak;
- a SHA-256 link to the previous exact step record.

The runner stops immediately and preserves the first causal failure for an
uncertain dispatch, blocking signal, app crash, command timeout/deadlock,
session/run/runtime/process crossover, state or log-cursor regression,
repeated required-progress signature, malformed or truncated safety evidence,
hard-bound exhaustion, or resource breach. It never retries an uncertain
mutation.

RSS assessment retains only bounded head and tail windows. It reports median
positive growth, peak RSS, least-squares tail slope, and the fraction of
strictly increasing tail samples. Exceeding the absolute growth bound fails the
component; exceeding it together with the preregistered slope and a sustained
increasing tail is additionally classified as unbounded growth.

## Create-only archive

Each run claims a new id and creates an owner-only directory:

```text
<archive-parent>/
  <endurance-run-id>.claim
  <endurance-run-id>/
    manifest.json
    setup.json
    baseline.json
    steps/000001.json
    ...
    teardown.json
    outcome.json
```

Every file is create-only, flushed, indexed by exact byte length and SHA-256,
and never overwritten. The loader rereads stable regular files, rejects
symlinks/unindexed files, verifies the manifest/config/environment/plan pins,
requires the exact step count, validates the step hash chain, and recomputes
the archive digest. A partial directory or missing `outcome.json` is incomplete
evidence, not a pass.

The archive intentionally retains Scout's exact bounded stdout/stderr and can
therefore contain private app evidence. Keep the returned archive digest in the
release evidence index, store the directory under access control, and apply the
organization's explicit retention/deletion policy; the runner never silently
rewrites or prunes raw evidence.

Controlled cancellation is typed as `interrupted`. Setup, probe, teardown,
clock, or archive failures are `harness_invalid` unless independent facts show
the product caused the crash, deadlock, crossover, signal, or evidence loss.
Product endurance failures are kept distinct and release-blocking. Missing or
uncertain evidence never becomes success.

Even a valid `release_evidence` component pass sets `releaseClaimable: false`:
the runner proves only this endurance component. Full release eligibility still
requires all other Quality Standard gates and retained real iOS/Android
evidence.

## Verification

```bash
cd evaluation
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

The fake clock/executor/controller tests cover deterministic idempotency,
per-step evidence, exact archive validation, runtime crossover, uncertain
dispatch, no-progress detection, sustained memory growth, cancellation, fresh
setup, and teardown failure. They are harness tests only; they do not constitute
a 60-minute or 1,000-action empirical run.
