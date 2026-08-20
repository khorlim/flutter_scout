# Controlled comparison preregistration

This document defines the evaluation contract for `QUALITY_STANDARD.md` §13.4.
It is a design and validation contract, not evidence that any comparison has
been executed or that Flutter Scout meets a benchmark threshold.

## Backward-compatible modes

A v1 benchmark config without `controlledComparison` keeps the original paired
current-versus-candidate schedule and its exact JSON shape.

Adding `controlledComparison` opts into one comparison block per task and
repetition. Every block contains these roles:

1. `screenshot_coordinate_only`;
2. `current_released_scout`;
3. `candidate_scout`;
4. `perfect_handle_ceiling`, only when a real ceiling implementation exists.

The screenshot, current, and candidate roles are mandatory. The perfect-handle
role is optional; it MUST NOT be represented by a fabricated or approximate
implementation.

## Preregistered pins

The surrounding `benchmark_config.schema.json` fixes one provider, model,
model snapshot, reasoning setting, system-prompt digest, app repository and
commit, host hardware and OS, simulator image/device/viewport/locale, Flutter,
Dart and platform toolchains, task regime, catalog digest, repetitions,
randomization seed, and every action/time/token/tool/byte/screenshot budget for
all roles.

The controlled block additionally requires, for each role:

- a unique condition id;
- the exact tool-schema id and SHA-256 digest exposed to the agent;
- the exact role adapter/runner implementation id and SHA-256 digest.

It also pins the deterministic reset protocol by id and SHA-256. The current
and candidate role condition ids must equal the existing current and candidate
condition ids. The candidate role's tool-schema pin must equal the legacy
`agent.toolSchema` pin, preventing two conflicting candidate definitions.
Current and candidate Scout Git commits remain mandatory and distinct.

Unknown fields, abbreviated Git commits, malformed digests, duplicate roles,
duplicate condition ids, missing core roles, mismatched Scout condition ids,
and any attempt to disable equal seeds or fresh resets are rejected before a
schedule is generated.

## Deterministic randomized schedule

`stable_balanced_role_rotation_v1` is an SDK-independent algorithm. It:

- deterministically shuffles task/repetition blocks from the preregistered
  seed;
- deterministically shuffles a base role order;
- assigns shuffled cyclic rotations of that order across blocks, so each role
  appears in every execution position equally when the block count is a
  multiple of the role count, and differs by at most one otherwise;
- derives one repetition seed from benchmark seed, task id, variant seed, and
  repetition, then uses that exact seed for every role in the block;
- marks every scheduled episode `freshResetRequired: true`.

The generated schedule records the condition-to-role map. Schedule validation
requires every block to contain every configured role exactly once, use a
contiguous execution order, share task and seed identity, and require a fresh
reset. Scheduled episode envelopes accept orders one through four and bind the
observed reset fact to the config and schedule hashes.

## Analysis contract

All configured roles receive per-condition raw counts, Wilson intervals,
failure taxonomy, safety signals, and per-success cost summaries. The primary
paired analysis remains current released Scout versus candidate Scout:

- McNemar input uses the identical task/repetition block and seed;
- only a harness-invalid current or candidate episode invalidates that Scout
  pair;
- an auxiliary-role harness failure is still retained and reported, but does
  not erase an otherwise valid current/candidate pair;
- all harness-invalid episodes still make the overall release assessment
  blocked and unclaimable.

Auxiliary comparisons are descriptive in this v1 contract. No post-hoc role
removal or failed-run exclusion is available. A normal report build means only
that the preregistered archive was complete and structurally valid. The report
always keeps full release conformance `claimable: false`.

## Minimal controlled block

```json
{
  "randomizationAlgorithm": "stable_balanced_role_rotation_v1",
  "freshResetPerEpisode": true,
  "identicalTaskSeedsAcrossRoles": true,
  "resetProtocol": {
    "id": "app-reset-v1",
    "sha256": "<64 lowercase hex characters>"
  },
  "conditions": [
    {
      "role": "screenshot_coordinate_only",
      "conditionId": "coordinates",
      "toolSchema": { "id": "coordinate-tools-v1", "sha256": "<sha256>" },
      "implementation": { "id": "coordinate-runner-v1", "sha256": "<sha256>" }
    },
    {
      "role": "current_released_scout",
      "conditionId": "current",
      "toolSchema": { "id": "current-tools-v1", "sha256": "<sha256>" },
      "implementation": { "id": "current-release-v1", "sha256": "<sha256>" }
    },
    {
      "role": "candidate_scout",
      "conditionId": "candidate",
      "toolSchema": { "id": "candidate-tools-v1", "sha256": "<sha256>" },
      "implementation": { "id": "candidate-build-v1", "sha256": "<sha256>" }
    }
  ]
}
```

`<sha256>` is explanatory notation only and is not valid input. A real config
must contain the exact lowercase 64-character digest.

## Remaining empirical evidence

The repository does not contain completed controlled episodes from a pinned
model service, simulator, current release artifact, candidate artifact,
coordinate-only runner, or perfect-handle ceiling. Before §13.4 can be claimed,
an independent controller must execute the frozen schedule with the pinned
reset protocol, retain every raw episode, verify actual environment identities,
and produce a complete unclaimable-by-default report for release review.
