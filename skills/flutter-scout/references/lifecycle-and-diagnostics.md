# Lifecycle and diagnostics

Use a unique `--name` for every task. `ensure` joins or reuses that named
session; `launch --replace` intentionally replaces it. Named runtime data lives
outside the app worktree and is addressable with global `--app`.

`status` reports the session mode, owner PID, VM URI health, hot-update
capability, and persistent transport. A stale VM URI is refreshed from owned
logs when possible. If it cannot be refreshed, Scout marks the session stopped,
terminates its verified VM log listener, and clears stale runtime files.
When the URI file is missing but a verified Scout-owned run remains alive,
`status` restores it from that run's scoped log. From the app project, commands
also select the sole current named session automatically; multiple candidates
require an explicit `--app <name>`.

The VM log listener is owned by the exact Flutter-run PID and exact session
directory. It exits with its owner. Connection errors use exponential backoff
and periodic summaries instead of writing one line per retry.

Useful commands:

```bash
flutter-scout devices
flutter-scout doctor --project <app> --device <id>
flutter-scout ensure --device <id> --project <app> --name <task>
flutter-scout --app <task> status
flutter-scout apps
flutter-scout apps --all
flutter-scout apps --prune
flutter-scout --app <task> logs --summary
flutter-scout --app <task> stop --clear-session
flutter-scout --version
```

Attach-only sessions can inspect and use VM-service reload, but hot restart
requires a Scout-owned Flutter process. A changed native plugin, asset pipeline,
build setting, or pubspec requires relaunch.

A rejected reload does not mean the app died. Check `status`, reuse/repair the
same named session, and reserve `stop --clear-session` plus relaunch for a dead
run or a rebuild-requiring change.

Always stop Scout-owned sessions. Verify the reported Flutter PID and listener
PID are gone; do not kill unrelated IDE or human-owned Flutter processes.
