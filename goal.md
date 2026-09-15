# Flutter Scout goal

Flutter Scout gives AI agents factual eyes and guarded hands for real Flutter
apps, with a tight persistent loop before human release judgment.

## One interaction architecture

Named ensure/attach → agent connection → passive observations alongside one
input → canonical receipt → acknowledgement → next deliberate decision.
Business completion is a separate bounded condition observation. Screenshots
remain manual. The agent protocol does not select a model, reasoning effort,
or paid service tier; it must never require ChatGPT/Codex Fast mode.

Standalone interaction commands and alternative live/HTTP/batch/replay modes
are removed. Current usage lives in skills/flutter-scout/SKILL.md and its
agent-session reference. Historical protocol/evaluation documents are evidence,
not supported command recipes.

## Scope and invariants

- One main-level debug initializer; no per-screen wrappers or action annotations.
- Preserve human-started app state. Attach is first-class; named ensure may
  reuse a healthy owned run. Never clear app data implicitly.
- Observe passively. Do not schedule frames, force lifecycle changes, or equate
  framework/semantic freshness with compositor pixels.
- Compact factual screen, surface, text, field, target and scroll information.
  Query selected sections only when necessary, not repeated raw-tree dumps.
- Prefer exact observed semantic targets. Resolve ambiguity explicitly; do not
  silently fuzzy-fallback a typed identity or retry a stale decision.
- Validate fresh run/runtime/snapshot, rendering and target safety at dispatch.
- Serialize input without blocking observations. Acceptance is not success;
  acknowledgement cannot hide a failed or unknown canonical receipt.
- Reconciliation requires fresh safe state and a known outcome. No automatic
  retry, no safety override, and no claim that cancelled waits cancel app work.
- Time-bounded local reactions require explicit authority for one observed
  exact tap or stopping future input. Never autonomous route exploration.
- Privacy and evidence are part of correctness: JSON stdin for sensitive input,
  private files, redaction, bounded retained events, no silent safety loss.
- Native screenshots and crops are explicit and provenance-labelled. Inspect
  images when making appearance claims. Geometry is not visual verification.
- Reload verifies loaded source; preserve reachable sessions after a rejected
  reload. Native/plugin changes require rebuild. Stop only exactly owned runs.

## Non-goals

Scout is not a subjective UX grader, a general QA planner, a human-speed claim,
or a replacement for integration tests and human judgment. It does not make
an agent reason faster or prove causality from already-visible text.

## Success measures

Verify actual user flows with fewer unnecessary calls, shorter input receipts,
useful concurrent observations, and correctly handled failures. Measure end-to-
end task time separately from command latency and model/tool gaps. Benchmark
realistic screens, not only tiny fixtures. Report misses and limitations as
well as successful runs; never infer general speedups from unmatched trials.
