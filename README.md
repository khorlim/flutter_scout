# Flutter Scout

Factual eyes and guarded hands for real Flutter apps. One main-level debug
initializer, one persistent agent connection, manual images.

## Hard cutover: agent protocol 2

All observation and UI input now use flutter-scout --app <name> agent.
Standalone inspect/actions/waits and live, serve, explore, batch, export-batch,
record and replay are removed. Old scripts fail with agent_session_required;
there is no compatibility switch or implicit transport fallback.

This is an interaction-protocol change, not ChatGPT/Codex Fast mode. Scout
works independently of model, reasoning effort, and service tier.

## Setup

```dart
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MyApp());
}
```

If a custom debug binding already exists, keep it and call
FlutterScoutHelper.ensureRegistered() after its initialization. No per-screen
wrappers. Scout remains inert in normal profile/release builds.

```bash
dart pub global activate --source git https://github.com/khorlim/flutter_scout.git --git-path packages/flutter_scout
flutter-scout --single-json ensure --device macos --project <app> --name <task>
```

Keep launch stdout/stderr separate; keep the command attached until final ready.
Attach can preserve a human-started app. Capability URLs enter through protected
stdin or an owner-only 0600 file, never process argv. Full wiring/ownership:
[setup skill](skills/flutter-scout-setup/SKILL.md).

## Operate through one connection

Import [the shipped Node client](skills/flutter-scout/scripts/agent_client.mjs)
into a persistent Node session. Read [the usage skill](skills/flutter-scout/SKILL.md)
and [agent contract](skills/flutter-scout/references/agent-session.md).

```js
const scout = await ScoutAgent.connect({app: 'task'});
const scene = await scout.observe();
const outcome = await scout.act(scene.viewRevision, {
  method: 'tap', args: [handleObservedInScene],
});
// Check outcome.ok, result, fresh scene, and intervening alerts.
await scout.close();
```

Independent passive eyes continue while the single hand is in flight. Short
input receipts retain normal safety/evidence work; they do not assert business
completion. Failed input cannot be acknowledged as success. Explicit fresh
reconciliation is available for known outcomes, never automatic retries.
Focused queries locate controls and inspect selected sections. Bounded watch
conditions and explicitly authorized one-shot reactions do not block the hand.

## Lifecycle and manual evidence remain

ensure, launch, attach, status, doctor, devices, apps, reload, restart, stop,
annotations, screenshot, crop, logs, health, evidence, version and help.

Close the connection before reload/restart and reconnect afterwards. Dart reload
checks sourceVerification; native/plugin changes need a rebuild. Do not tear
an app down simply because reload was rejected.

Screenshots/crops remain manual and private. Capture and inspect them for visual
claims; semantic geometry is not compositor evidence. Use named --app and exact
ownership for cleanup:

```bash
flutter-scout --app <task> stop --clear-session
```

Require ok:true, sessionCleared:true and recordedRuns.unresolved:[]; leave an
app open when the user explicitly asks for immediate testing.

## Packages and contracts

- packages/flutter_scout: pure-Dart CLI, persistent agent coordination,
  guarded dispatch and private evidence.
- packages/flutter_scout_helper: app-side inspection, rendering metadata,
  target resolution, gestures, signals and annotation UI.
- apps/scout_test_app: real Flutter verification fixtures.
- skills/: shipped usage, setup and annotation instructions.

[Architecture](ARCHITECTURE.md), [goals](goal.md),
[compatibility](COMPATIBILITY.md), [quality](QUALITY_STANDARD.md),
[release process](RELEASING.md). Historical v1 protocol/evaluation artifacts
remain evidence of their versions, not supported legacy command recipes.
