---
name: ship-sync
description: Use for Flutter Scout repo work when the user wants the full issue/fix/review/test/docs/commit/push flow and post-push local refresh. Applies to updates in /Users/han/flutter_packages/flutter_scout involving code, docs, shipped skills, package behavior, issue notes, or local workflow instructions.
---

# Ship Sync

Use this skill only in the Flutter Scout repo:

```text
/Users/han/flutter_packages/flutter_scout
```

The goal is to finish a change end to end: validate the issue, fix it, review it, test it for real, update docs/skills, commit, push, then refresh the user's local installed skills and global package from the pushed Git commit.

This is a project-scoped workflow skill. Keep it in `skills/ship-sync/`; do not copy it into `/Users/han/.codex/skills`.

## Workflow

1. Read the relevant issue notes, `AGENTS.md`, repo docs, and owner files before editing.
2. Identify which reported issues are valid. Do not fix invalid reports unless the user asks for related cleanup.
3. Fix valid issues with scoped code, docs, skill, or issue-note changes.
4. If an issue checklist file is involved, cross out each fixed or intentionally handled issue and add a short resolution note.
5. Run a quick review pass on the diff for correctness, robustness, maintainability, efficiency, and test gaps.
6. Fix any critical review findings before testing.
7. Run real verification for the touched surface:
   - `packages/flutter_scout`: `dart format .`, `dart analyze`, `dart test`
   - `packages/flutter_scout_helper`: `dart format lib test`, `flutter analyze`, `flutter test`
   - `apps/scout_test_app`: `dart format lib test`, `flutter analyze`, `flutter test`
   - Simulator/runtime checks when behavior involves attach, launch, inspect, actions, screenshots, crops, reload, restart, logs, or replay.
8. Fix any issue found during verification and rerun the relevant checks.
9. Update related docs and shipped skills under `skills/`.
10. Stage only intended files and inspect `git status --short --branch`.
11. Commit with a clear message.
12. Push the branch.
13. Only after the push succeeds, refresh local installs.

## Post-Push Local Refresh

Run from the repo root after a successful push:

```bash
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
git status --short --branch
git rev-parse --short HEAD
git ls-remote origin refs/heads/main
```

## Rules

- Preserve the user's work. Do not revert unrelated changes.
- Do not commit `.flutter_scout/`, `.dart_tool/`, `build/`, `.idea/`, simulator artifacts, screenshots, or temporary files.
- Treat simulator verification as required when changing runtime control/perception behavior.
- Stop any Scout-owned `flutter run` process started during verification.
- Do not activate the global package before pushing; activation must come from the newest Git commit.
- Keep this skill project-scoped; do not install or sync it into `/Users/han/.codex/skills`.
- If the user asks only to draft or review the workflow, do not create files, commit, push, or refresh local installs.
