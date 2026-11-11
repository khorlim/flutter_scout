# Agent Instructions

This repo is **Flutter Scout** — an agent-oriented eyes-and-hands bridge for Flutter
simulator apps. Two packages cooperate over the Dart VM service:

- `packages/flutter_scout` — the persistent agent-session CLI (**pure Dart**).
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

All UI navigation uses the agent session. Standalone interaction, waits,
live/serve/explore/batch/record/replay are removed. Do not enable model Fast mode
or change a user's service tier to use Scout. Consult the current shipped skill,
not historical command examples in old protocol/evaluation documents.

## After pushing changes

Whenever you update Flutter Scout code, docs, or shipped skills and then push those
changes, update the user's local installation before finishing. Installed skills
live in `/Users/han/.agents/skills/` (`~/.claude/skills/` symlinks to them):

```bash
cd /Users/han/flutter_packages/flutter_scout
for s in flutter-scout flutter-scout-setup flutter-scout-annotations; do
  rsync -a --delete --exclude .flutter_scout "skills/$s/" "/Users/han/.agents/skills/$s/"
done
dart pub global activate --source git https://github.com/khorlim/flutter_scout.git --git-path packages/flutter_scout
```

Verify the refresh:

```bash
for s in flutter-scout flutter-scout-setup flutter-scout-annotations; do
  diff -rq --exclude .flutter_scout "skills/$s" "/Users/han/.agents/skills/$s"
done
test ! -e /Users/han/.agents/skills/ship-sync
grep resolved-ref ~/.pub-cache/global_packages/flutter_scout/pubspec.lock  # equals pushed HEAD
git rev-parse HEAD
flutter-scout --help
```

Do this after the push succeeds so the global `flutter_scout` executable is activated
from the newest Git commit, not a stale checkout or previous global activation.
