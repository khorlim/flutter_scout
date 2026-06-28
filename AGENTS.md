# Agent Instructions

This repo is **Flutter Scout** — an agent-oriented eyes-and-hands bridge for Flutter
simulator apps. Two packages cooperate over the Dart VM service:

- `packages/flutter_scout` — the `flutter-scout` CLI (stateless command process, **pure Dart**).
- `packages/flutter_scout_helper` — the in-app binding that registers VM service
  extensions and renders the annotation overlay (**Flutter** package).

Plus `apps/scout_test_app` (verification app) and `skills/` (shipped agent skills).

## Where to start

- **Modifying Scout's code** → read [`ARCHITECTURE.md`](ARCHITECTURE.md) first: request
  flow, the part-file map for each package, and conventions. Each part file is one
  concern — start there, not in the ~1,300-line shells.
- **Scout's command behavior / agent loop** → [`skills/flutter-scout/SKILL.md`](skills/flutter-scout/SKILL.md).
- **Product goals and non-goals** → [`goal.md`](goal.md).

## Verify changes

Both packages must stay green. The CLI is pure Dart; the helper is a Flutter package:

```bash
cd packages/flutter_scout        && dart analyze    && dart test
cd packages/flutter_scout_helper && flutter analyze && flutter test
```

For behavior changes, smoke-test on a simulator using the flow in `SKILL.md`.

## After pushing changes

Whenever you update Flutter Scout code, docs, or shipped skills and then push those
changes, update the user's local installation before finishing:

```bash
cd /Users/han/flutter_packages/flutter_scout
cp skills/flutter-scout/SKILL.md /Users/han/.codex/skills/flutter-scout/SKILL.md
cp skills/flutter-scout-setup/SKILL.md /Users/han/.codex/skills/flutter-scout-setup/SKILL.md
dart pub global activate --source git https://github.com/khorlim/flutter_scout.git --git-path packages/flutter_scout
```

Verify the refresh:

```bash
diff -u skills/flutter-scout/SKILL.md /Users/han/.codex/skills/flutter-scout/SKILL.md
diff -u skills/flutter-scout-setup/SKILL.md /Users/han/.codex/skills/flutter-scout-setup/SKILL.md
test ! -e /Users/han/.codex/skills/ship-sync
dart pub global list
flutter-scout --help
```

Do this after the push succeeds so the global `flutter_scout` executable is activated
from the newest Git commit, not a stale checkout or previous global activation.
