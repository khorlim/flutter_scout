# Bounded batch and replay contract

Flutter Scout treats batch scripts and replay recordings as untrusted input.
It validates the complete plan before opening a VM-service connection or
dispatching the first action. A malformed late step therefore prevents every
earlier step from running.

## Input bounds

File-backed batch and replay inputs must be regular files. Scout does not
follow a final symbolic link. It reads at most 1 MiB, rejects a file that
changes while it is read, and decodes strict UTF-8 without replacement
characters.

The closed limits are:

- 256 batch commands or replay actions;
- 64 KiB per batch command;
- 256 arguments per batch command;
- 256 KiB per command argument or decoded JSON string;
- 32 JSON nesting levels; and
- 8,192 decoded JSON nodes.

An exceeded bound is a typed failure before any dispatch.

## Batch preflight

Batch accepts only these bounded UI commands:

`inspect`, `where`, `locate`, `reveal`, `bounds`, `tap`, `tap-text`,
`long-press`, `input`, `fill`, `scroll`, `swipe`, `scroll-to`, `back`,
`dismiss`, `wait`, `wait-for`, `health`, and `deeplink`.

Lifecycle, process, session, server, recording, replay, and nested batch
commands must run separately. Every option, positional argument, numeric
range, required field, expectation, URI, and fill object is checked before the
batch begins. `fill --json` must be a non-empty string-to-string object with
non-empty keys.

Protected replay placeholders are permitted only in an `input` positional
business value or a `fill --json` value. Nested `input --file`, `input
--stdin`, `fill --file`, and `fill --stdin` sources are forbidden inside a
batch; use batch-level `--var-file` or `--var-stdin` instead.

## Replay preflight

Replay requires one non-empty JSON array. Every array element must be an
object with string keys and an exact command-specific schema. Unknown fields,
nulls, unsupported commands, missing required fields, malformed values, and
missing protected variables fail the whole plan before dispatch.

Replay supports `tap`, `tap-text`, `input`, `fill`, `long-press`, `scroll`,
`swipe`, `scroll-to`, `back`, and `deeplink`. Lifecycle and infrastructure
operations are intentionally not replay actions. Input and fill values remain
source-redacted placeholders. Deep-link recordings must retain one
source-redacted URL placeholder; Scout resolves and validates it only after
every action and variable has passed preflight.

Each batch or replay step derives a deterministic idempotency key from one
scope key. Reconciliation and durable evidence behavior therefore remain
per-step even when the CLI process or transport is retried.

## Outcome and exit semantics

Mutation results keep transport, dispatch, observation, postcondition,
runtime health, and evidence-commit status independent in compact and verbose
output.

`businessSuccessClaimed: true` requires an explicitly met postcondition, a
clean runtime, committed evidence, a dispatched and observed mutation, and no
command failure. A successful unasserted mutation is
`completed_unasserted`: it may return exit code 0, but it never claims business
success. `no_effect`, unavailable observation, unknown dispatch, unmet
postcondition, blocked or unknown runtime health, transport failure, and
evidence-commit failure are closed failures and return exit code 1.

Batch additionally reports `okMeaning: all_batch_outcomes_accepted`,
`commandCompleted`, `verdict`, and per-mutation verified, unasserted, and
failed counts so `ok` cannot silently stand for task success.

The deterministic regression proof is
`packages/flutter_scout/test/bounded_batch_replay_test.dart`.
