# Command reference

Core lifecycle: `devices`, `doctor`, `ensure`, `launch`, `attach`, `status`,
`apps`, `stop`, `version`.

Supply VM-service capability URLs with owner-only
`attach --debug-url-file <0600-path>` or `attach --debug-url-stdin`. Scout
accepts only explicit loopback hosts with an explicit port and never permits
remote VM-service egress. The legacy `--debug-url` form warns because argv can
be observed before Scout starts.

Eyes: `where`, `locate`, `inspect` (including `--since <snapshot-id>`),
`health`, `screenshot`, `crop`, `logs`, `evidence`, `annotations`.

Focused visual delta: `crop --changed-since <snapshot-id>` captures only a
complete bounded semantic/render changed-region union. It returns all snapshot,
logical/physical geometry, DPR, backend, capture-identity, and limit provenance,
and abstains instead of guessing when history, geometry, scope, coordinate
frame, output bounds, or atomic in-app capture cannot be proven.

Hands: `tap`, `tap-text`, `input`, `fill`, `long-press`, `scroll`, `scroll-to`,
`swipe`, `drag-start`, `drag-move`, `drag-status`, `drag-end`, `drag-cancel`,
`back`, `dismiss`, `deeplink`, and bounded `reveal`.

Synchronization: `wait`, `wait-for`, action `--expect-*`, `--expect-log`,
`--reject-log`, `--allow-errors`.

## Wait budgets

Action `--expect-timeout <ms>` controls how long Scout polls a same-call
postcondition (default 5000 ms). It is supported by `tap`, `tap-text`, `input`,
and `fill`. For a known local transition, choose a short bounded check:

```bash
flutter-scout --app template-save tap btn.details \
  --expect-text "Details" --expect-timeout 1000
flutter-scout --app template-save input --target field.name --stdin \
  --expect-field field.name=Ava --expect-timeout 1000
```

Use an observed text, target, or field value; do not guess a screen class for
`--expect-screen`. Preserve the default or allow longer for network requests
and other delayed work. A short timeout means the condition was not observed
within that window, not that the dispatched action failed or is safe to repeat.
Reconcile with `inspect --brief` or `inspect --since` first.

`--wait-ms`, on commands that support it, is a separate initial stability
allowance. It does not replace `--expect-timeout`, and `input` does not accept
it. Total command time can also include connection, dispatch, initial settling,
late-change observation, capture, and evidence persistence; neither option is
a whole-command deadline. Read `timings` and `expectation.waitedMs` to separate
these costs. Already-selected controls and temporarily quiet trees can still
trigger delayed work, so do not bypass a requested postcondition based on
either observation.

For state not caused by the current command, use `wait-for --timeout <ms>`.

## Other command contracts

Update: `reload`, `restart`.

Automation: `batch`, `serve`, `explore`, `record`, `export-batch`, `replay`.

Global exactly-once option: `--idempotency-key <1-128-safe-ASCII-chars>`.
Use one stable key when an orchestrator may retry a mutation. The same key and
business request replays/reconciles the original outcome across CLI processes;
the same key with different business parameters abstains. `/v1/call` exposes
the equivalent top-level `idempotencyKey` field. Batch, replay, and composite
commands such as direction-fallback `scroll-to` derive stable per-step keys
from the supplied scope key. Reload, restart, and deeplink use the same durable
receipt boundary; an unknown local receipt is never automatically dispatched
again.

Use `flutter-scout help <command>` or `flutter-scout <command> --help` for the
installed build's exact options. Command-scoped help never requires or contacts
an app session.
JSON is the source of truth. Nonzero exits mean the requested assertion or
operation failed; record replay uses exit code 2 when it could not start.
All machine responses carry a typed/versioned envelope. Preserve `commandId`,
run/runtime/state identity, `dispatch`, `observation`, `postcondition`,
`stability`, fresh signal cursors, and evidence status when compacting or
handing off. `dispatch_outcome_unknown` means reconcile state, not blind retry.
