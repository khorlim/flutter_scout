# Flutter Scout Goal

## One-Line Goal

Flutter Scout gives AI agents efficient eyes and hands for Flutter apps running on simulators, so the agent can verify its own code changes before the human does final release judgment.

## Product Position

Flutter Scout is an upgrade over fdb for agent-driven Flutter work.

The upgrade is not a bigger wrapper layer, not a generic QA engine, and not more app-specific annotations. The upgrade is a tighter operating loop for agents:

```text
attach -> inspect -> act -> wait stable -> return delta + hard signals -> replay
```

The package should help an AI agent stay oriented, act precisely, notice hard failures, and avoid wasting tokens on raw widget-tree wandering or repeated full screenshots.

## Main Workflow

The primary workflow is human-in-the-loop development:

1. A human or AI agent starts the Flutter app on a simulator.
2. The AI agent edits or implements a feature.
3. The agent attaches to the running simulator app when possible.
4. The agent inspects the current screen and performs the feature flow.
5. Each action returns what changed, whether the app is stable, and whether hard errors appeared.
6. The agent fixes obvious UI/code issues and replays the same flow.
7. The human performs final verification on the same simulator.

Attach-to-running-app is first-class. Flutter Scout must not assume the agent owns the full app lifecycle.

## Integration Constraint

App integration must stay minimal.

The only required app change should be a main-level initializer:

```dart
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MyApp());
}
```

Do not require:

- `AgentScreen`
- `AgentAction`
- `AgentForm`
- per-screen wrappers
- per-widget action annotations
- test-only screen structure

The agent should test the real app code that is close to release.

Flutter Scout may use Flutter internals, VM service extensions, semantics, widget/render/focus trees, screenshots, simulator tools, and runtime error hooks. It should not require feature code to be rewritten around the tool.

## V1 Contract

Flutter Scout v1 should do one job very well: provide reliable agent eyes and hands.

V1 includes:

- attach to an already-running simulator app
- launch when no app is running
- inspect the current screen as a compact digest
- tap, long press, input, fill, scroll, swipe, back, and deep link
- wait until the app is stable
- return before/after deltas after actions
- capture hard runtime signals
- take screenshots and targeted crops on demand
- record and replay action sessions

V1 does not include broad built-in QA judgment.

Flutter Scout should report facts, not opinions. It can say "FlutterError occurred", "RenderFlex overflow was logged", "button is disabled", "field did not change", or "dialog opened". It should not claim "bad UX", "confusing screen", or "poor design" as a core v1 feature.

## Why Not Built-In QA First

Built-in QA sounds attractive, but it risks making the first version noisy and subjective.

For AI agents today, the most valuable primitive is not another critic. The valuable primitive is a dependable control and perception loop:

- What screen am I on?
- What can I interact with?
- Which field maps to this label?
- Did my tap do anything?
- What changed after the action?
- Is the app stable now?
- Did a hard runtime error happen?
- Can I replay this exact flow after a fix?
- Can I show a focused crop to inspect visual evidence?

Once this loop is reliable, QA features can be layered later as optional analysis. They should not weaken or complicate the core eyes-and-hands contract.

## Core Principle

Flutter Scout should reduce agent uncertainty at every step.

Every command should answer the agent's next practical question with compact, deterministic output.

## Command Shape

Example workflow:

```bash
flutter-scout attach --device <simulator-id>
flutter-scout inspect
flutter-scout tap btn.add_supplier
flutter-scout fill --json '{"Supplier name":"QA Supplier","Phone":"0123456789"}'
flutter-scout tap btn.save
flutter-scout crop dialog.current
flutter-scout replay .flutter_scout/session.json
```

Launch is also supported:

```bash
flutter-scout launch --device <simulator-id> --project .
```

Attach should preserve running app state by default. It should not restart the simulator, clear app data, or relaunch Flutter unless explicitly requested.

## Attach

`flutter-scout attach` should discover or accept the Dart VM service URI through multiple paths:

- explicit `--debug-url`
- helper-emitted VM URI markers
- Flutter/IDE/DevTools terminal output copied by the user
- simulator logs
- existing `.flutter_scout/vm_uri.txt`

Successful attach output should be explicit:

```json
{
  "attached": true,
  "reusedRunningApp": true,
  "device": "iPhone 17 Pro",
  "vmServiceUri": "ws://127.0.0.1:XXXXX/...",
  "appStatePreserved": true
}
```

Failed attach output should include the next best recovery action:

```json
{
  "attached": false,
  "reason": "vm_service_uri_not_found",
  "nextBestActions": [
    "Run the app in debug/profile mode and copy the VM Service URL",
    "flutter-scout attach --debug-url <url>",
    "flutter-scout launch --device <simulator-id> --project ."
  ]
}
```

## Inspect

`flutter-scout inspect` should return a compact screen digest:

```json
{
  "screen": "SupplierListScreen",
  "routeGuess": "supplier",
  "idle": true,
  "visibleText": ["Suppliers", "Search", "Add supplier"],
  "interactables": [
    {
      "id": "btn.add_supplier",
      "kind": "button",
      "label": "Add supplier",
      "enabled": true,
      "confidence": 0.98
    }
  ],
  "fields": [
    {
      "id": "field.search",
      "label": "Search",
      "value": ""
    }
  ],
  "overlays": [],
  "keyboard": {"visible": false},
  "recentErrors": []
}
```

Inspect should summarize:

- current screen guess
- route or route guess
- visible text
- interactable controls
- text fields and form-like regions
- dialogs, sheets, menus, overlays, and keyboard state
- disabled controls as factual state
- recent hard runtime signals

Raw widget trees and full screenshots can exist, but they are fallback tools.

## Action Delta

Every action should return what happened.

Example:

```bash
flutter-scout tap btn.add_supplier
```

Expected output shape:

```json
{
  "action": "tap btn.add_supplier",
  "result": "changed",
  "before": {"screen": "SupplierListScreen"},
  "after": {"screen": "AddSupplierDialog"},
  "delta": {
    "dialogOpened": true,
    "newText": ["Supplier name", "Phone", "Save"],
    "newFields": ["field.supplier_name", "field.phone"]
  },
  "recentErrors": []
}
```

This should prevent the inefficient fdb-style loop where the agent runs an action, then separately inspects, checks logs, takes screenshots, and still may not know whether anything changed.

## Smart Handles

Flutter Scout should generate meaningful temporary handles:

```json
{
  "id": "btn.save",
  "fallbackId": "i4",
  "label": "Save",
  "kind": "button",
  "rect": [742, 88, 138, 40],
  "enabled": true,
  "confidence": 0.96
}
```

Handles should be inferred from:

- semantics labels
- visible text
- keys when present
- widget type
- nearby labels
- role-like behavior
- rect and hit-test data

If a handle becomes stale, the CLI may attempt fallback matching by label, type, rect, or fallback ID.

## Forms

Agents should not need to tap and type field by field for normal forms.

```bash
flutter-scout fill --json '{"Supplier name":"QA Supplier","Phone":"0123456789"}'
```

The bridge should match fields by label, hint, semantics, nearby text, keys, focus traversal, and visible layout.

The result should report exactly what was filled:

```json
{
  "filled": ["Supplier name", "Phone"],
  "failed": [],
  "delta": {
    "changedFields": ["field.supplier_name", "field.phone"]
  },
  "recentErrors": []
}
```

## Stability

Every action should automatically wait for a stable state:

- route transition complete
- animations mostly settled
- keyboard animation complete
- next frame rendered
- no immediate Flutter framework error

There should also be an explicit command:

```bash
flutter-scout wait stable
```

If the app does not become stable, output should say why when the reason is factual:

```json
{
  "stable": false,
  "reason": "frames_still_changing",
  "durationMs": 10000
}
```

## Hard Runtime Signals

Flutter Scout v1 should capture hard signals that agents often miss:

- Flutter framework errors
- uncaught Dart errors
- platform dispatcher errors
- RenderFlex overflow messages
- failed image load errors
- VM service disconnects
- app process death
- visible Flutter error screen/banner when detectable

These are factual signals. They are part of the eyes-and-hands layer, not a subjective QA layer.

## Visual Evidence

Screenshots are useful, but they should be deliberate.

Supported commands:

```bash
flutter-scout screenshot
flutter-scout screenshot --target btn.save
flutter-scout crop btn.save
```

Targeted crops should work for widgets, fields, dialogs, and changed regions. A crop is often more useful to an agent than a full simulator image because it is cheaper to inspect and easier to discuss.

## Replay

Every session should record replayable actions:

```json
[
  {"cmd": "tap", "target": "btn.add_supplier"},
  {"cmd": "fill", "values": {"Supplier name": "QA Supplier"}},
  {"cmd": "tap", "target": "btn.save"}
]
```

Replay should run the same flow after a fix:

```bash
flutter-scout replay .flutter_scout/session.json
```

Replay results should include the same deltas and hard runtime signals as live actions.

## Architecture

### `flutter_scout_helper`

The Flutter helper package should:

- register VM service extensions
- expose inspect, action, fill, and wait endpoints
- inspect semantics, widget, render, and focus trees
- dispatch Flutter-level gestures and text input
- capture hard runtime signals
- provide target metadata for screenshots and crops

### `flutter_scout`

The CLI package should:

- launch and attach to Flutter apps
- reuse already-running simulator apps without resetting state
- discover VM service URIs from logs, helper markers, session files, or explicit debug URLs
- manage `.flutter_scout/` session files
- connect to the VM service
- call helper extensions
- take simulator screenshots
- crop evidence images
- collect logs
- record and replay sessions
- output deterministic JSON and compact text

### Session Directory

Use:

```text
.flutter_scout/
  session.json
  vm_uri.txt
  device.txt
  platform.txt
  logs.txt
  screenshots/
  crops/
```

Process cleanup must be safer than fdb:

- never kill a PID based only on PID existence
- verify process identity before killing
- keep simulator/app data reset separate from cache cleanup
- avoid destructive cleanup unless explicitly requested

## Non-Goals

Do not optimize v1 around:

- broad bad-UX detection
- subjective design scoring
- automatic feature QA reports
- tap target size grading
- duplicate label warnings
- unlabeled-field warnings
- validation UX judgment
- deterministic exploration planning
- production-device automation before simulator workflows are excellent

Do not require:

- per-screen wrappers
- action annotations in feature code
- replacing integration tests
- raw screenshots as the primary interface
- raw widget trees as the primary interface

## Success Criteria

Flutter Scout succeeds when an AI agent can:

- attach to a simulator app the human already started
- launch the app when needed
- inspect the current screen without getting lost
- interact through stable, meaningful handles
- fill common forms efficiently
- understand what changed after every action
- see hard runtime errors quickly
- collect screenshots or crops when needed
- replay the same flow after a fix
- preserve a fast human-in-the-loop workflow

The agent should do this with fewer tool calls, fewer screenshots, less token waste, and better confidence than with fdb.

## Later

After the eyes-and-hands layer is reliable, Flutter Scout can grow optional higher-level modules:

- accessibility checks
- visual regression comparison
- flow exploration
- heuristic UX review
- auto-generated QA summaries
- CI-oriented scenario packs

These must remain optional layers above the core operating loop.
