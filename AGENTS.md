# Agent Instructions

## After Pushing Changes

Whenever you update Flutter Scout code, docs, or shipped skills and then push those changes, update the user's local installation before finishing:

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
dart pub global list
flutter-scout --help
```

Do this after the push succeeds so the global `flutter_scout` executable is activated from the newest Git commit, not a stale checkout or previous global activation.
