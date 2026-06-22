---
name: flutter-scout-maintainer
description: Maintain and evolve the Flutter Scout codebase. Use when adding Flutter Scout features, fixing Flutter Scout bugs, changing its CLI/helper packages, updating the verification app, improving inspect/action/replay/screenshot behavior, debugging simulator attachment, or preparing changes to the public Flutter Scout repo.
---

# Flutter Scout Maintainer

Use this skill when modifying Flutter Scout itself. Keep the package focused on one job: efficient eyes and hands for AI agents testing Flutter apps on simulators.

## Read First

- `goal.md` for product direction and non-goals.
- `README.md` for current package layout and verified workflow.
- `packages/flutter_scout/lib/src/flutter_scout_cli.dart` for CLI behavior.
- `packages/flutter_scout_helper/lib/src/flutter_scout_binding.dart` for VM extensions and Flutter runtime behavior.
- `apps/scout_test_app/lib/main.dart` for the simulator verification surface.

## Architecture Boundaries

- Put app-side VM extensions and Flutter tree/gesture/error logic in `flutter_scout_helper`.
- Put process launch, attach, VM service calls, screenshots, crops, logs, sessions, and replay in `flutter_scout`.
- Keep the test app small but representative; add screens only when they prove a Flutter Scout capability.
- Do not add per-screen wrappers, `AgentScreen`, `AgentAction`, or app-code annotations.
- Keep `.flutter_scout/` runtime state out of git.

## Change Rules

- Preserve the main-only app integration:

```dart
FlutterScoutBinding.ensureInitialized();
runApp(const MyApp());
```

- Prefer compact, deterministic JSON over verbose dumps.
- Every action should wait for stability and return `before`, `after`, `delta`, and `recentErrors`.
- Prefer semantic handles from keys, labels, roles, and rects. Use coordinates only as fallback.
- Add field/action data only when it helps the agent decide the next step.
- Treat runtime signals as facts; do not add subjective QA scoring to the core package.
- Keep launch/attach non-destructive. Never reset simulator/app state unless the user explicitly asks.

## Implementation Pattern

1. Reproduce the bug or define the missing behavior with the test app.
2. Change the narrowest layer that owns the behavior.
3. Add or update focused tests where possible.
4. Run static checks for touched packages.
5. Verify with a real simulator when the behavior involves VM service, gestures, screenshots, attach, launch, or replay.
6. Update README/goal only when public behavior or direction changes.

## Verification Ladder

Use the smallest reliable check first, then climb only as needed.

```bash
cd packages/flutter_scout
dart format .
dart analyze
dart test

cd ../flutter_scout_helper
dart format lib test
flutter analyze
flutter test

cd ../../apps/scout_test_app
dart format lib test
flutter analyze
flutter test
```

For runtime behavior, use a booted iOS simulator:

```bash
cd packages/flutter_scout
dart run bin/flutter_scout.dart launch --device <sim-id> --project ../../apps/scout_test_app
dart run bin/flutter_scout.dart inspect
dart run bin/flutter_scout.dart tap btn.add_supplier
dart run bin/flutter_scout.dart fill --json '{"Supplier name":"QA Supplier","Phone":"0123456789"}'
dart run bin/flutter_scout.dart tap btn.save_supplier
dart run bin/flutter_scout.dart crop btn.add_supplier -o /tmp/flutter_scout_crop.png
dart run bin/flutter_scout.dart replay .flutter_scout/session.json
```

Also verify attach reuse when changing launch/attach/session code:

```bash
rm .flutter_scout/vm_uri.txt
dart run bin/flutter_scout.dart attach --device <sim-id>
dart run bin/flutter_scout.dart status
```

Stop any `flutter run` process you started before finishing.

## Common Pitfalls

- Do not close log sinks while stream listeners can still write to them.
- Do not let stale `.flutter_scout/vm_uri.txt` make tests pass accidentally.
- Do not make inspect output grow into a raw widget tree.
- Do not return `unchanged` for meaningful text-field changes; field values must participate in deltas.
- Do not duplicate nested controls when a real button and inner tap target overlap.
- Do not assume `Navigator.maybeOf(rootElement)` targets the active dialog route.
- Do not commit generated build folders, `.dart_tool/`, `.idea/`, or `.flutter_scout/`.

## Public Repo Hygiene

- Keep commits small and named for behavior.
- Run validation before pushing.
- If adding a user-facing command, update `packages/flutter_scout/README.md`, root `README.md`, and this skill when relevant.
- If changing how agents should use the package, update `skills/flutter-scout/SKILL.md`.
