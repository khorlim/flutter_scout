---
name: flutter-scout
description: Use Flutter Scout to give AI agents factual eyes and hands for Flutter apps on simulators: launch or attach, inspect, act, reload, verify, record, and collect evidence.
---

# Flutter Scout

Use Scout when validating a Flutter feature on a simulator. Keep the core loop
short and evidence-based:

```text
named ensure -> inspect --brief -> act with a gate -> inspect delta/errors
             -> reload after edits -> replay/evidence -> stop
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
or test-only UI.

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
flutter-scout attach --debug-url <vm-service-url>
```

Address named sessions from any directory with `--app <name>`. Use
`flutter-scout apps` for live entries, `apps --all` for missing entries, and
`apps --prune` to remove stale registry entries.

Inside an app project, commands reuse its sole current named session when there
is no default session. If several named sessions exist, Scout refuses to guess;
use `--app <name>` consistently.

Check `status` when ownership is unclear. Stop every Scout-owned run when done:

```bash
flutter-scout --app template-save stop --clear-session
```

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

Prefer semantic handles (`btn.save`, `field.template_name`,
`row.customer.more_actions`) over coordinates. Fields can inherit nearby
labels; row actions expose stable intent aliases such as `.open` and
`.more_actions`. Read `selected`, `enabled`, `hitTestable`, `visibleFraction`,
`enclosingTarget`, `altIds`, and `didYouMean` before guessing.

## Act and verify atomically

Put the success condition on the action:

```bash
flutter-scout tap btn.save --expect-text "Saved"
flutter-scout tap btn.create \
  --expect-log "Created template" \
  --reject-log "validation_failed"
flutter-scout input --target field.name "Ava" --expect-field field.name=Ava
flutter-scout fill --json '{"field.name":"Ava"}' --expect-text "Ready"
```

Actions fail by default when fresh blocking runtime or log errors appear. Use
`--allow-errors` only when the error is deliberately part of the scenario.
Action JSON includes VM, log-settle, and total timings.

Use `wait-for` for a state not caused by the current command:

```bash
flutter-scout wait-for --text "Loaded" --timeout 8000
flutter-scout wait-for --gone "Loading"
```

Use `scroll-to <handle>` for offscreen/lazy controls, `dismiss` for the top
route or close control, and `tap-text --contains` for truncated labels. Use
coordinates only after handle/text targeting cannot express the action.

## After code edits

```bash
flutter-scout --app <task-slug> reload
flutter-scout --app <task-slug> restart
```

Read `sourceVerification`: `verified` compares changed Dart files on disk with
the VM's loaded source; `mismatch` is a hard failure; `partially_verified`
lists scripts the VM did not expose. Native/plugin/pubspec changes require a
fresh launch.

If reload is rejected, do not clear the session or relaunch immediately. Use
this recovery ladder:

1. Run `flutter-scout --app <task-slug> status`.
2. If `appReachable:true` or `running:true`, keep the existing app and inspect
   the reload error; it is still running the previous code.
3. Run the same named `ensure` to repair/reuse the session when ownership or the
   saved VM URI is unclear.
4. If the VM URI is known, reattach that same named session explicitly. Scout
   preserves ownership only when the URI matches its verified owned run.
5. Use restart when Scout still owns the Flutter tool and Dart state must reset.
6. Use a fresh launch only when the app is dead or native/plugin/pubspec changes
   require rebuilding.

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
flutter-scout evidence -o /tmp/template-create-evidence
```

The bundle includes status, inspect, logs, screenshot, session replay data, and
the JSONL event journal when available.

## Safety and completion

- Inspect before the first action and after meaningful transitions.
- Treat structured `ok:false`, fresh blocking errors, rejected logs, protocol
  mismatch, source mismatch, and failed expectations as failures.
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
