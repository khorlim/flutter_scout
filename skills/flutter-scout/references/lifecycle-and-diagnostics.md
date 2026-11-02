# Lifecycle and diagnostics

Use a unique `--name` for every task. `ensure` joins or reuses that named
session; `launch --replace` intentionally replaces it. Named runtime data lives
under the resolved Flutter project regardless of command cwd and is addressable
with global `--app`. Legacy duplicate roots for one label are reported with
their session directories and run IDs; Scout refuses to choose or launch until
the obsolete session is explicitly stopped or cleared.

`status` reports the session mode, owner PID, VM URI health, hot-update
capability, and persistent transport. A stale VM URI is refreshed from owned
logs when possible. If it cannot be refreshed, Scout marks the session stopped,
terminates its verified VM log listener, and clears stale runtime files.
For Scout-owned macOS launches, `status` also reports the per-run `launchd`
supervisor, its current worker state, and the last recorded Flutter-tool exit.
The supervisor survives terminal or agent cleanup and restarts an abnormally
lost worker. If the Flutter process survived, the new worker adopts it instead
of launching a duplicate. A normal Flutter-tool exit is recorded and returns a
successful supervisor result, so it does not create a relaunch loop or reset
the app unexpectedly. Other platforms retain the detached-worker fallback.
When a macOS build must inherit a temporarily unlocked signing Keychain, pass
`--inherit-launch-context` from inside the command that owns that Keychain.
Scout then uses the detached-worker fallback for that run. It preserves the
caller security context through signing, but has no launchd crash recovery and
does not survive logout.

On macOS, Scout builds with `flutter build macos --debug`, opens the app through
LaunchServices (`open -n`) and then runs `flutter attach` for reload and
restart. The app is therefore its own privacy (TCC) responsible process in the
user's GUI session: microphone, camera and Bluetooth prompts name the app, its
System Settings toggles apply, and Keychain access works without
`--inherit-launch-context`. Reload, restart, `stop` and app prints in `logs`
behave as with `flutter run`; `stop` also ends the exact app it opened. Flutter
accepts the app's VM-service URL for `attach` only as a process argument, so it
is visible to local process inspection while the run lives. Set
`FLUTTER_SCOUT_MACOS_DIRECT_RUN=1` to launch with `flutter run` instead; the app
is then a child of Scout's worker, which macOS treats as the responsible
process, so privacy-gated requests are denied without a prompt.
If the app remains reachable after its Scout-owned Flutter runner exits,
`status` reclassifies the session as attach-only and reports
`ownershipLossReason: owner_process_exited`. The app remains available for
inspection and actions, but Dart edits require a fresh Scout-owned launch.
When the URI file is missing but a verified Scout-owned run remains alive,
`status` restores it from that run's scoped log. From the app project, commands
also select the sole current named session automatically; multiple candidates
require an explicit `--app <name>`.

The VM log listener is owned by the exact Flutter-run PID and exact session
directory. It exits with its owner. Connection errors use exponential backoff
and periodic summaries instead of writing one line per retry.

One project and device can have only one live named session by default:
`launch` or `ensure` with a new name returns `project_in_use` and names the
running session, because both runs share the build output. Reuse that session
with `--app <name>`, stop it, or pass `--allow-parallel` deliberately. Without
`--app`, `status` lists the named sessions under the current project in
`projectSessions`. `apps` reports each registered session's `state`, `live`,
`device`, `ageSeconds` and `updatedAt`; `apps --running` lists only live ones.
A stopped or failed session with the same name in another project no longer
blocks a new session; only two live ones are ambiguous.

Useful commands:

```bash
flutter-scout devices
flutter-scout doctor --project <app> --device <id>
flutter-scout ensure --device <id> --project <app> --name <task>
flutter-scout --app <task> status
flutter-scout apps --running
flutter-scout apps
flutter-scout apps --all
flutter-scout apps --prune
flutter-scout --app <task> logs --summary
flutter-scout --app <task> stop --clear-session
flutter-scout --version
```

## Reading logs

Read runtime output with `logs`, not by opening `logs.txt` or per-run log
files. `logs` picks the active run's log, redacts VM capability URLs and
registered secrets, collapses duplicated app output, and drops known macOS
toolchain noise (reported as `suppressedNoiseLines`).

```bash
flutter-scout --app <task> logs --summary            # counts, signals, important lines
flutter-scout --app <task> logs --last 50            # newest 50 lines (max 1000)
flutter-scout --app <task> logs --contains 'Exception' --last 20
```

There is no `--tail` or `--follow`. Results include `cursor` and `truncated`.
Attach-only sessions report `available:false`, because Scout cannot read the
owning IDE or terminal console.

Attach-only sessions can inspect and use VM-service reload, but hot restart
requires a Scout-owned Flutter process. A changed native plugin, asset pipeline,
build setting, or pubspec requires relaunch.

A rejected reload does not mean the app died. Check `status`, reuse/repair the
same named session, and reserve `stop --clear-session` plus relaunch for a dead
run or a rebuild-requiring change.

## Reload and restart outcomes

Every `reload` and `restart` result has a compact top-level `timing`:
`ackMs` (signal until Flutter acknowledged), `postAckStableMs` (helper
reachability plus one short stability observation, or null if not reached),
`sourceVerificationMs`, `totalMs`, `commandMs`, and, when Flutter printed its
own duration, `flutterReportedMs` and `scoutOverheadMs`. The `stability` field
is the helper's own observation. When the helper cannot provide one, Scout
does not wait longer and `timing.stabilityObservation` is `unavailable`.
Source verification still runs.

- `reload_rejected`: `error.message` includes Flutter's full reason, and
  `error.rejectionDetails` lists its lines. `error.suggestedCommand: "restart"`
  means Flutter said a hot restart is required (for example, a changed field
  type). Compile errors carry `compilerDiagnostics` instead; fix the code.
- `reload_source_mismatch` / `restart_source_mismatch`: `error.mismatchedFiles`
  lists the project-relative Dart files the VM still runs differently. Save
  them and repeat the command; if a reload mismatch persists, restart.
- `reload_ack_timeout` / `restart_ack_timeout`: `error.toolState` says why.
  - `not_alive`: the Flutter tool exited. Relaunch with `ensure`.
  - `in_progress`: the tool is still working (it printed output, used CPU, or
    the app already runs a new runtime). Do not send another signal: Flutter
    ignores reload and restart signals while one is running. Check
    `logs --contains "Restarted application"` (or `"Reloaded"`) or `status`,
    and retry only after it finished or failed.
  - `silent`: the tool printed nothing and used no CPU since the signal. It
    may be hung. Check logs once more, then `stop --clear-session` and relaunch.

  `lastToolLine`, `secondsSinceSignal`, `toolCpuSecondsSinceSignal` and
  `processState` are the facts behind that classification. The next `reload`
  or `restart` reports `previousHotUpdate.status` (`completed_late`,
  `rejected_late` or `still_pending`) for the timed-out one. `status` does not
  report it yet.

When `status` reports ownership loss, `ensure` preserves the running app and
the ownership-loss diagnosis instead of claiming Scout still owns it. Use
`launch --replace` only when replacing that app with a fresh reload-capable run
is acceptable.

Always stop Scout-owned sessions. Verify the reported Flutter PID and listener
PID are gone; do not kill unrelated IDE or human-owned Flutter processes. On
macOS, `stop` first unloads the exact trusted `launchd` service identity, then
terminates the verified Flutter process.

## Launch timeouts

A launch waits for silence, not for the clock. It gives up after
`--launch-idle-timeout` seconds without new runner output (default 180) and is
bounded by `--launch-timeout` (default 1200). Both are accepted by `launch` and
`ensure`, and `ensure` forwards them to the launch it falls back to.

A cold first iOS or macOS build can spend minutes inside `pod install` or Swift
package resolution without printing. While the runner is silent, Scout samples
the CPU time of the runner's process tree; a build that keeps using CPU counts
as progress, so only a stalled build hits the idle limit.

When a launch fails, `error.message` names what ended the wait, the last output
time and line, and the option to change. `failureMode` is `idle_timeout`,
`hard_timeout`, `runner_exited` (the runner stopped) or `runner_probe_failed`
(Scout could not confirm the runner for 30 s, usually under heavy machine load).
When the log shows a known cause, `failureCause` gives `cause`, the `evidence`
line and a `hint`: `device_unavailable`, `install_failed_insufficient_storage`,
`dart_compile_failed`, `cocoapods_failed`, `gradle_build_failed`,
`native_build_failed`, `app_exited_during_launch` or a `macos_app_*` code. A
shut-down iOS Simulator fails at once with `device_not_booted` and the boot
command. Read these fields instead of repeating the same launch.

If the app launched but the helper was not reachable, the result is `ok:false`
with `launched:true`, `ready:false`, `reason` and `detail`. The run stays owned;
check `status` before relaunching.

`stop --clear-session` escalates to SIGKILL for an exact owned Flutter tool
that ignores SIGTERM, including one orphaned after its worker died.
