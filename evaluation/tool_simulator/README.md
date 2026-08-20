# Public tool-simulator evaluation slice

This directory includes the original deterministic **Add supplier** fixture and
the runner used by every generated `public-fixture-v1` manifest. It is an
implementation proof for running real `flutter-scout` process commands while
judging results from an independent app-owned oracle. It is not a hidden
corpus, a real-app benchmark, or evidence that Flutter Scout is
release-eligible.

## Separation contract

- The agent receives only `TaskManifest.toAgentView()` and may use exactly the
  `flutter-scout` tool.
- Scout command output is archived as a tool claim but is never used as the
  pass/fail source.
- A separate evaluator process talks directly to two authenticated VM service
  extensions for reset and state. The oracle capability and raw observations
  are never passed to the action planner, a Scout command, or an agent/tool
  event.
- Oracle observations live only in the private `harnessEvents` section of the
  typed `EpisodeResult` archive.
- Every episode must prove one clean reset generation before planning. Runtime
  replacement, missing attachment, reset mismatch, oracle failure, or command
  process failure invalidates the harness rather than becoming a product score.
- Action and wall-time limits are enforced before dispatch and with per-process
  deadlines. Plans above the action/token budget dispatch no task actions.

For the generated corpus, an authenticated reset carries a strict evaluator-only
fixture configuration. The verification app renders the requested task and
variant, then records modal state, an opaque app-owned completion event,
duplicate actions, and unrelated/wrong actions. Task-specific predicate results
are exposed only through the protected oracle channel. Scout output is never
an oracle input.

## Run the public fixture

Create an owner-only evaluator configuration outside the repository. Use a
random token of at least 32 characters:

```json
{
  "FLUTTER_SCOUT_EVALUATOR_ENABLED": "true",
  "FLUTTER_SCOUT_EVALUATOR_TOKEN": "replace-with-a-random-32-plus-character-token"
}
```

```bash
chmod 600 /private/tmp/flutter-scout-evaluator.json
flutter run -d <simulator-id> \
  --dart-define-from-file=/private/tmp/flutter-scout-evaluator.json \
  --target apps/scout_test_app/lib/main.dart
```

Capture the loopback VM service URI from that debug run, then execute:

```bash
umask 077
read -r -s SCOUT_VM_SERVICE_URI
printf '%s' "$SCOUT_VM_SERVICE_URI" > /private/tmp/flutter-scout-vm-uri
unset SCOUT_VM_SERVICE_URI
chmod 600 /private/tmp/flutter-scout-vm-uri
cd evaluation
dart run bin/run_tool_simulator_episode.dart \
  --manifest tool_simulator/fixtures/supplier_add_manifest.v1.json \
  --plan tool_simulator/fixtures/supplier_add_plan.v1.json \
  --vm-uri-file /private/tmp/flutter-scout-vm-uri \
  --oracle-config /private/tmp/flutter-scout-evaluator.json \
  --archive /absolute/private/path/to/raw-episodes
```

The runner creates an isolated temporary Scout session, attaches it to the
given VM URI, proves a fresh oracle reset, executes the bounded plan without a
shell, queries the oracle out of band, and immutably archives one typed episode.
Both the runner and its child Scout invocation consume the capability-bearing
URI through exact-0600 files; neither retains the URI in process arguments or
tool-event evidence.
Its stdout contains only an evaluator summary and archive path—not the raw
oracle payload or capability.

The app channel exists only when both evaluator defines are present in a debug
build, and its registration is assertion-gated. Profile and release builds do
not register it. The VM client accepts loopback endpoints only. Keep the raw
episode archive and evaluator configuration access-controlled; harness events
contain private oracle evidence.

## Schemas and limits

- `schemas/v1/tool_simulator_plan.schema.json` defines the bounded process plan.
- `schemas/v1/supplier_oracle_observation.schema.json` defines evaluator-only
  reset/state evidence.
- `schemas/v1/episode_result.schema.json` defines the immutable episode stored
  by `RawEpisodeArchive`.

This slice intentionally accepts only the public-development manifest below.
It does not satisfy private-validation, frozen-hidden, two-real-app, statistical
power, perturbation, long-haul, or release-gate requirements.
