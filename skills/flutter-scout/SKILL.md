---
name: flutter-scout
description: "Use Flutter Scout to give AI agents factual eyes and hands for Flutter apps on simulators: launch or attach, inspect, act, reload, verify, record, and collect evidence."
---

# Flutter Scout

Use Scout when validating a Flutter feature on a simulator. Keep the core loop
short and evidence-based:

```text
named ensure -> where/inspect --brief -> locate/reveal if needed
             -> act once with a gate -> inspect --since + errors
             -> reload after edits -> replay/evidence -> exact stop
```

## Before acting

Scout requires one app initializer:

```dart
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MyApp());
}
```

If another debug binding already owns initialization, keep it and call
`FlutterScoutHelper.ensureRegistered()` after it. Never add per-screen wrappers
or test-only UI. Scout is intentionally inert in normal profile and release
builds; use a debug build for every Scout session.

Run `flutter-scout doctor --project <app>` when setup or protocol state is
unclear. For an app that is not integrated, prefer a zero-diff launch:

```bash
flutter-scout ensure --temporary-helper \
  --device <simulator-id> --project <app> --name <task-slug>
```

## Start or reuse a session

Always name agent-owned sessions with a short task slug:

```bash
flutter-scout ensure \
  --device <simulator-id> --project <app> --name template-save
```

`ensure` reuses a healthy named run. Use `launch --replace` only when a fresh
run is intentional. Use `attach` only to preserve a human-started app:

```bash
flutter-scout attach --device <simulator-id>
# Put the VM-service capability URL in an owner-only 0600 file first.
flutter-scout attach --debug-url-file /private/path/vm-service-url
```

Address named sessions from any directory with `--app <name>`. Use
`flutter-scout apps` for live entries, `apps --all` for missing entries, and
`apps --prune` to remove stale registry entries.
Named session storage and its launch lease are bound to the resolved
`--project`, not the command working directory. If Scout reports competing
roots for one label, inspect the listed run IDs and explicitly stop or clear
the obsolete session; Scout will not guess or start another build.

Inside an app project, commands reuse its sole current named session when there
is no default session. If several named sessions exist, Scout refuses to guess;
use `--app <name>` consistently.

Check `status` when ownership is unclear. Stop every Scout-owned run when done:

```bash
flutter-scout --app template-save stop --clear-session
```

Read the response's `operability` object when diagnosis matters. It separates
CLI-supported protocol from the helper range actually observed, live app
reachability from daemon readiness, and recorded ownership metadata from a
revalidated process proof. `actionState` reports an active held drag,
`recordingState` reports recorder state and storage, and
`prioritizedRecoveryAction` contains at most one next action. Treat every
`unavailable` fact as unknown; never infer a version, runtime, device, or source
match from absence.

A launch ends on silence, not on elapsed time: it fails once the runner prints
nothing for `--launch-idle-timeout` seconds (default 180), bounded by
`--launch-timeout` (default 1200). A cold first build that spends minutes in
`pod install` is therefore not killed while it is still progressing. On failure
read `failureMode` — `idle_timeout` or `hard_timeout` means Scout stopped a
runner that may still have been building, so raise the limit rather than
assuming the build broke.

On macOS, Scout-owned `launch`/`ensure` runs use a per-run `launchd`
supervisor. They normally survive the launching terminal or agent being
cleaned up, while explicit Ctrl-C during launch and `stop` still cancel the
exact session. `status` includes supervisor state and the last recorded Flutter
exit. A normal Flutter exit is diagnostic, not an automatic app relaunch.

## Inspect

Start with bounded output:

```bash
flutter-scout --app template-save inspect --brief
flutter-scout --app template-save inspect --surface
```

Request full or opt-in sections only when needed:

```bash
flutter-scout --app template-save inspect \
  --sections textTargets,scrollables,rows
```

Keep the returned `snapshotId`, then request a bounded relative observation
instead of repeatedly retransmitting the whole tree:

```bash
flutter-scout --app template-save inspect --since '<snapshot-id>'
```

When a localized visual fact changed, reuse that same retained baseline rather
than taking another broad screenshot:

```bash
flutter-scout --app template-save crop \
  --changed-since '<snapshot-id>' -o /private/path/changed.png
```

Trust the crop only when `changedRegionCoverage.status` is `complete` and the
baseline, current, and capture-verification scopes are present. Scout binds one
helper-side current observation to retained history, captures the bounded union,
then discards the raster if the snapshot changes during capture. It abstains on
stale/foreign history, ambiguous or unavailable geometry, screen/route/frame
changes, more than 16 regions, a padded union above 50% of the viewport,
padding above 256 logical pixels, or output above 4096×4096 / 4,194,304 pixels.
The regions are semantic/render geometry, not a pixel diff. Native/platform-view
fallback is intentionally unavailable because it cannot preserve the same
atomic helper snapshot; take a full native screenshot instead.

Prefer semantic handles (`btn.save`, `field.template_name`,
`row.customer.more_actions`) over coordinates. Fields can inherit nearby
labels; row actions expose stable intent aliases such as `.open` and
`.more_actions`. Read `selected`, `enabled`, `hitTestable`, `visibleFraction`,
`enclosingTarget`, `altIds`, and `didYouMean` before guessing.

Typed handles (`btn.*`, `tap.*`, `field.*`, `text.*`, `scroll.*`, `row.*`)
require an exact published identity, alias, or same-kind widget key. Missing
handles do not fall back to similar labels or a different kind. Use an untyped
query for fuzzy matching, or `--text`/`tap-text` for literal text.

Use the observed `screen` for `--expect-screen`, not a guessed class name.
`screenEvidence.screenCandidates` preserves a bounded nearest-first ancestry
for widget-inferred screens; parent candidates are orientation hints, not
aliases accepted by the exact screen guard. A visible-text guard can be more
useful when nested pages or modal surfaces change the reported screen.

## Orient and navigate with bounds

Use read-only orientation and location before exploratory scrolling:

```bash
flutter-scout --app template-save where
flutter-scout --app template-save locate --target row.customer_acme
flutter-scout --app template-save locate --text "Acme" --contains
```

`where` is compact by default. Use `where --verbose` only when its bounded
scroll-region, pane, surface, and navigator facts do not contain the geometry
or provenance needed for the next decision. Compact `where` and
`inspect --brief` output is one machine-JSON line; parse it as JSON rather than
requesting verbose output for formatting.

If a unique target is not built or visible, use bounded `reveal`. When more
than one scroll region exists, pass the exact region returned by `where` or
`inspect --sections scrollables`; Scout refuses to guess.

```bash
flutter-scout --app template-save reveal row.customer_acme \
  --within scroll.suppliers --max-actions 8 --timeout 8000
```

Read `stoppingReason`, bounds, regions, progress, restoration, ambiguity, and
state identity before choosing the next step. `reveal` restores the starting
position after any post-dispatch failure. Do not turn it into an unbounded
autonomous explorer.

## Act and verify atomically

Put the success condition on the action:

```bash
flutter-scout tap btn.save --expect-text "Saved"
flutter-scout tap btn.create \
  --expect-log "Created template" \
  --reject-log "validation_failed"
flutter-scout input --target field.name --stdin --expect-field field.name=Ava
flutter-scout fill --file /private/path/owner-only-values.json \
  --expect-text "Ready"
```

Choose a gate from observed UI facts, not a guessed screen class. For a known
local transition, a short explicit `--expect-timeout 1000` can bound an
exploratory check; keep or increase the default 5000 ms for asynchronous work
such as network-backed saves. This bounds the expectation wait, not total
command time. `--wait-ms`, where supported, controls separate action settling;
it is not an expectation timeout. See the
[wait-budget guidance](references/command-reference.md#wait-budgets).
If a gate fails after dispatch, inspect the resulting state before any retry.
A stable tree or `already_selected` result does not prove delayed work cannot
still complete.

Use `--stdin` or an owner-only regular `0600` file for any secret. Use direct
value/`--json` arguments only for deliberately non-sensitive data; process
arguments can be observed by other local tooling. Replay variables follow the
same rule through `--var-stdin` or `--var-file`.

Treat VM-service and deep-link URLs as credentials too. Use
`attach --debug-url-file`/`--debug-url-stdin` and
`deeplink --url-file`/`--url-stdin`; never paste token-bearing URLs into argv.
Scout deliberately rejects non-loopback VM-service endpoints.

Actions fail by default when fresh blocking runtime or log errors appear. Use
`--allow-errors` only when the error is deliberately part of the scenario.
Action JSON uses a typed/versioned envelope and independently reports dispatch,
observation, postcondition, stability, runtime health, evidence persistence,
and phase timings. If dispatch is `dispatch_outcome_unknown` or evidence
persistence fails after a possible mutation, inspect/reconcile current state;
never retry under a fresh identity merely because transport timed out.

Default action output summarizes snapshot details inside failures too. Read
`*Omitted` counts as presentation limits, not proof that a delta is complete;
use a fresh `inspect --brief` or selected sections to reconcile current state.
Choose `--verbose` before an action only when full diagnostics are needed;
never repeat a mutation just to obtain a larger response.

Use `wait-for` for a state not caused by the current command:

```bash
flutter-scout wait-for --text "Loaded" --timeout 8000
flutter-scout wait-for --gone "Loading"
```

Use `scroll-to <handle>` for offscreen/lazy controls, `dismiss` for the top
route or close control, and `tap-text --contains` for truncated labels. Use
coordinates only after handle/text targeting cannot express the action.

Coordinates are logical points, not screenshot pixels. A gesture starting
outside the view fails with `gesture_start_outside_viewport` and reports the
viewport size; scale by the device pixel ratio or use a handle instead. Text
that is not on screen fails with `text_not_found` — scroll it into view with
`scroll-to` first rather than assuming the list has ended.

## After code edits

```bash
flutter-scout --app <task-slug> reload
flutter-scout --app <task-slug> restart
```

Read `sourceVerification`: `verified` compares changed Dart files on disk with
the VM's loaded source; `mismatch` is a hard failure; `partially_verified`
lists scripts the VM did not expose. Test sources are reported under `skipped`
rather than `notLoaded`, because a running app never loads them. Native/plugin/pubspec changes require a
fresh launch.

Scout-owned reloads wait up to 60 seconds for the Flutter tool's terminal
acknowledgement. A large app may spend tens of seconds compiling and
reassembling without producing another log line; leave the command running
while it remains inside that bound.

If reload is rejected, do not clear the session or relaunch immediately. Use
this recovery ladder:

1. Run `flutter-scout --app <task-slug> status`.
2. If `appReachable:true` or `running:true`, keep the existing app and inspect
   the reload error; it is still running the previous code. For a Dart compile
   failure, fix the bounded lines in
   `acknowledgement.compilerDiagnostics`, then reload the same session again.
   If `sessionOwnershipLost:true` or
   `ownershipLossReason:owner_process_exited`, the app is inspectable but the
   original Flutter compiler process is gone, so Dart edits cannot be reloaded.
   On macOS, also inspect `supervisorState` and `lastRunnerExit`; the supervisor
   may have adopted a surviving Flutter tool after its worker was replaced.
3. Run the same named `ensure` to repair/reuse the session when ownership or the
   saved VM URI is unclear.
4. If the VM URI is known, reattach that same named session explicitly. Scout
   preserves ownership only when the URI matches its verified owned run.
5. Use restart when Scout still owns the Flutter tool and Dart state must reset.
6. Use a fresh launch only when the app is dead, ownership was lost, or
   native/plugin/pubspec changes require rebuilding.

Never use `stop --clear-session` solely because a Dart reload was rejected.

## Fast exploratory loops

After three successful plain CLI actions, Scout automatically starts a
persistent transport for the named session and reuses it for follow-up
commands. It expires after ten idle minutes. `batch` remains best for a known
sequence:

```bash
flutter-scout batch \
  'tap btn.save --expect-text Saved; inspect --brief'
```

## Record and preserve evidence

Every command appends a redacted `.flutter_scout/events.jsonl` event with
timestamps, duration, session/run/transport, outcome, and snapshot/runtime
facts. Successful replay inputs remain in `session.json`.

Turn the last successful actions into a reusable flow:

```bash
flutter-scout record save-last template-create --last 6 --feature forms
flutter-scout record run template-create --feature forms
```

Collect a bundle when handing off:

```bash
flutter-scout evidence -o /private/path/template-create-evidence \
  --retention session
```

The bundle includes status, inspect, logs, screenshot, session replay data, and
the JSONL event journal when available. Artifacts are private application data;
the safe default retention is the session. Select `24h`, `7d`, or `manual` only
when the task explicitly needs longer retention.

## Safety and completion

- Inspect before the first action and after meaningful transitions.
- Treat structured `ok:false`, fresh blocking errors, rejected logs, protocol
  mismatch, source mismatch, and failed expectations as failures.
- Treat ambiguity, stale identity, unavailable observation, unknown dispatch,
  and uncommitted evidence as abstention/reconciliation states, never success.
- Do not infer visual quality from geometry or semantics alone; capture and
  inspect images when appearance matters.
- Never claim a simulator check that was not run.
- Stop Scout-owned Flutter and listener processes before finishing.

## Routed references

Read only what the task needs:

- [Lifecycle and diagnostics](references/lifecycle-and-diagnostics.md) for
  setup, named sessions, attach/launch ownership, registry, logs, and cleanup.
- [Gestures and visual evidence](references/gestures-and-visuals.md) for
  screenshots, crops, scrolling, held drags, swipes, and coordinate fallback.
- [Recording and replay](references/recording-and-replay.md) for flow capture,
  retroactive extraction, batch, replay variables, and evidence bundles.
- [Annotations](references/annotations.md) when the user left annotation pins.
- [Command reference](references/command-reference.md) when an option or
  return contract is not covered above.
