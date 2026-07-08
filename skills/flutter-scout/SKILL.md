---
name: flutter-scout
description: Use Flutter Scout to give AI agents eyes and hands for Flutter apps on simulators. Trigger when verifying Flutter UI/features after code changes, attaching to a running simulator app, launching a Flutter debug app for agent testing, inspecting screens, tapping/filling/scrolling through flows, collecting screenshots/crops, replaying verification steps, or checking hard runtime errors.
---

# Flutter Scout

Use Flutter Scout to verify Flutter changes on a simulator with a compact agent loop:

```text
named ensure/launch -> inspect -> act -> reload/restart after edits -> read delta/errors -> crop if needed -> replay
```

## Setup Check

Use the app as-is except for the main initializer:

```dart
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MyApp());
}
```

If the app does not include it, add `flutter_scout_helper` and call the initializer before `runApp`. Do not add per-screen wrappers or test-only widgets.

If the app already initializes another debug binding, keep that initializer and call `FlutterScoutHelper.ensureRegistered()` after it instead of replacing the binding.

## Command Form

From the CLI package source:

```bash
cd packages/flutter_scout
dart run bin/flutter_scout.dart <command>
```

If installed as an executable, use:

```bash
flutter-scout <command>
```

For local package development, refresh the fast executable shim after changing
Scout so normal `flutter-scout` calls do not go through `dart pub global run`:

```bash
/Users/han/flutter_packages/flutter_scout/tool/install-local-shim.sh
```

## Preferred Workflow

1. Prefer a named Scout-owned session for agent work:

```bash
flutter-scout ensure --device <simulator-id> --project <flutter-app-path> --name add-member
```

`ensure` is the default for agent loops: it reuses a ready Scout-owned VM service for that named session when possible and launches only when needed. Always pass `--name` (see below).

2. Launch directly when you intentionally need a fresh Scout-owned Flutter run:

```bash
flutter-scout launch --device <simulator-id> --project <flutter-app-path> --name add-member
```

Use `attach` only when the user explicitly wants you to preserve or inspect a human-started app state:

```bash
flutter-scout attach --device <simulator-id>
flutter-scout attach --debug-url <vm-service-url>
```

**Always name the session — never run the app unnamed.** Pass `--name <label>` on every `launch`/`ensure`, deriving the label from what you are working on *right now*: a short kebab-case slug of the feature or task in focus. Working on an add-member flow → `--name add-member`; fixing supplier search → `--name supplier-search`. If no single feature is in focus, fall back to the current git branch name (e.g. `git rev-parse --abbrev-ref HEAD`). Setting it on every run is worth it because the label:

- **registers the session in the global registry**, so any later command can address it with `--app add-member` from any directory without cd'ing into the project (`flutter-scout apps` lists the registered sessions);
- **paints a small labelled badge** on the debug build (bottom-left, debug only), so concurrent windows/worktrees — one per feature — stay distinguishable at a glance. Tapping the badge collapses it to a dot so it never blocks app UI.

`--name` works on both `launch` and `ensure`; Scout injects it as a `--dart-define`.

Launch validates the exact requested device and emits compact progress events. If launch was interrupted or you need to stop a Scout-owned run:

```bash
flutter-scout stop --clear-session
```

Launch, ensure, and attach responses include `ready` when they start or connect to a VM service. If `ready` is false, fix the reported setup reason before inspecting or acting. When `ensure` or `launch` starts a Scout-owned Flutter run, read the `timing` object if present; it reports launch cost such as `totalMs`, `buildDurationMs`, `firstSyncMs`, `vmServiceFoundMs`, and `readyMs`.

Use `status` when session ownership is unclear. It reports `session.mode` and `hotUpdate` capability so you know whether `reload` can use the VM service, whether `restart` can signal a Scout-owned Flutter run, or whether the owning IDE/terminal must perform restart. If Flutter moves the VM service after hot restart, `status` can refresh the stale saved URI from Scout logs or simulator log markers and reports `staleRefreshed:true`.

3. Inspect before acting:

```bash
flutter-scout inspect --brief
flutter-scout inspect --surface
flutter-scout inspect
flutter-scout inspect --sections textTargets,scrollables
```

Prefer `inspect --brief` for orientation: it returns the screen name, visible/hit-testable/offscreen text, compact interactables (id, kind, label, `selected` state), field values, structured rows, suggested actions, semantic quality, perception provenance, and errors at a fraction of the full payload size. Brief output omits anonymous generic gesture targets and reports `interactablesOmitted`; when many are omitted it adds an `inspectWarnings` item so you know semantics are weak without reading hundreds of `tap.gesturedetector_*` handles. Use `inspect --surface` when a modal, picker, dialog, or sheet is active and you want only the top surface's reachable text/actions. Use plain `inspect` or `--sections text,interactables,fields,textTargets,scrollables,overlays,visualTree,controlGroups,rows,annotations` when you need full geometry or a specific section. Prefer handles like `btn.save_supplier`, `field.supplier_name`, and `row.customer_name.more_actions` over coordinates.

Icon-only buttons are named from tooltips, `Semantics` labels, and the full Material/Cupertino icon tables, so an unlabeled admin icon surfaces as `btn.person_badge_plus` rather than `btn.cupertinobutton_2`. Interactables also expose `selected` (tab selected, switch on, checkbox checked) when determinable; tapping an already-selected control returns `result:"already_selected"` instead of `activated_no_observed_change`, so do not retry it. For CUSTOM segments/chips with no semantics, Scout infers selection heuristically: in a run of 3+ adjacent same-kind tappables where exactly one label color differs, that outlier is marked selected — treat inferred values as strong hints, not ground truth.

Interactables can also carry `altIds` — alternate handles from the other label sources (icon glyph, accessibility label, contained text). When a primary label drifts between snapshots (an async-loaded username appearing after first paint), any altId still resolves the same node, so recorded handles and replays keep working.

Snapshots include `viewSignature` (most prominent visible texts) and `visibleTextHash`: two states on the SAME route — an Operation/Admin flip, a swapped tab body — get different signatures even though `screen` is identical, and action deltas report `viewChanged` when the signature moves.

If `tap-text` fails with `text_not_found`, the error includes `didYouMean` near-matches — try one of those before re-inspecting. For labels the UI truncates with an ellipsis, pass `tap-text --contains "<full label>"` to match a shortened prefix.

`inspect` output includes `recentLogSignals` when Scout-owned logs contain factual runtime signals that the in-isolate crash handlers never saw — for example Flutter build errors, uncaught exceptions, RenderFlex overflows, high-severity app logs, denied permissions, or failed API/network requests. `recentLogErrors` remains as a line-only compatibility view. For a one-shot readout run `flutter-scout health`: it returns `{screen, viewSignature, degradedNodes, interactableCount, semanticQuality, blockingErrors, blockingLogSignals, recentLogSignals, healthy}` and marks `healthy:false` for fresh blocking log signals.

To close a screen without guessing between a system back and an in-app close button, use `flutter-scout dismiss`: it pops the top route (handles `showDialog`/`showModalBottomSheet`/pushed screens) and, if nothing pops, taps a close-like control (xmark/close/cancel) for custom overlay modals. It reports `strategy` (`popped_route` / `tapped_close` / `none`).

If one widget on the screen misbehaves, inspect reports `degradedNodes` with the count of skipped elements instead of failing outright — treat a non-zero value as "eyes are partial, not blind".

For a one-image overview, use a set-of-marks screenshot — numbered marks are drawn over every visible interactable and the JSON includes the `marks` legend mapping each number to its handle. Overlapping badges are suppressed so dense screens stay legible (the count appears as `marksOmitted`); use `--annotate-filter buttons|fields` to mark only one control type:

```bash
flutter-scout screenshot --annotated -o /tmp/marked.png
flutter-scout screenshot --annotated --annotate-filter buttons -o /tmp/buttons.png
```

A small keyed handle (an avatar or icon inside a whole tappable row/card) can be a no-op on its own; when so, its brief entry carries `enclosingTarget` — the larger tappable it sits inside — as a reliable fallback. Duplicate handles (`btn.edit`, `btn.edit_2`, …) each carry a compact `at` position hint (grid cell + top-left pixels) so you can pick "the one in row 2" without full geometry.

`structuredRows` groups list/table/card content into compact row objects with `text`, `primaryTarget`, row-scoped `actions`, and `handles`. Use `row.<label>` when the whole row is tappable, and `row.<label>.<action>` for row-local trailing actions such as menus. Row handles resolve through normal `tap`, `scroll-to`, and `wait-for --target` lookup, so prefer `row.acme_supplies.more_actions` over brittle coordinates when repeated row labels make generic handles ambiguous.

`semanticQuality` summarizes how agent-readable the current UI is: score, grade, counts for unlabeled or duplicate actions, non-hit-testable controls, low-confidence targets, fields, and structured rows. Low quality is not automatically a product bug, but it tells you to prefer keys/explicit handles and to be cautious with ambiguous gestures. `perception` states where Scout's evidence came from (`flutter_widget_tree`, widget/semantics labels, render-box geometry) and explicitly notes that screenshots/OCR are not in the inspect payload; request `screenshot`/`crop` when pixel-level visual confirmation matters.

`screen` names the topmost modal surface (`Dialog`, `BottomSheet`, or the content widget) instead of a useless `RootWidget` when no `*Screen`/`*Page` widget exists — including custom modals detected via their blocking `ModalBarrier` scrim, which also appears in `overlays` as `kind:"modalBarrier"`. Generic transparent route barriers are ignored. Content that is visible and tappable is always inspectable even when its `TickerMode` is paused (backgrounded windows, inactive tab pages) — Scout no longer treats a disabled `TickerMode` as hidden.

If the user manually annotated the running app, read the annotations before editing:

```bash
flutter-scout annotations list
```

Annotations contain the user's comment plus the selected widget metadata. They are persistent review markers, so code fixes and hot reloads do not automatically remove them. `inspect` also includes top-level `annotationMode` and `annotations` fields, but `annotations list` is the clearest handoff from manual review to agent work.

**Manual annotation handoff.** After the user reviews the app and says annotations are ready, read the current pins:

```bash
flutter-scout annotations list
```

Then use `$flutter-scout-annotations`: fix one pin, delete that fixed pin, and repeat until no actionable pins remain.

**Crops (see what the user saw).** Each annotation carries an in-app screenshot of the flagged widget. `annotations list`/`wait` materialize them under `.flutter_scout/crops/` and expose `beforeCropPath` (captured when the annotation was created). Read that image to understand visual bugs ("too wide", "misaligned") that text alone can't convey. If `beforeCropNeedsNative` is true the widget is a platform view (map/webview); the CLI falls back to a native capture automatically, or sets `beforeCropMissing` when unavailable.

Read `target.snapshotRect` as the original captured geometry and `target.liveRect` as current matched geometry. If `target.liveMatched` is false, run `flutter-scout annotations check` to mark missing open targets as `stale_target`.

**Verify and close the loop.** After fixing a widget and hot-reloading, mark it fixed — this sets status `pending_review` and captures an `afterCropPath` so you (and the user) get a before/after:

```bash
flutter-scout annotations fixed ann_001 --note "Shortened label"
```

Then **clear the pins you handled** so the overlay does not accumulate stale review markers. Delete only the ids you actually addressed, and report each one to the user (id + comment + what you did). Capture the `fixed` before/after first (above) so the evidence survives in the conversation even though the pin is gone:

```bash
flutter-scout annotations delete ann_001 ann_003
```

`delete` hard-removes those ids and returns `removed` (deleted) and `notFound` (unknown id) lists — use them to report accurately, and never blanket-delete pins you did not address. Do not delete a pin you could not fix; leave it for the user (optionally `reopen`/`fixed` to reflect state).

If the user prefers to confirm fixes themselves, use the manual path instead of `delete`: `fixed` leaves an amber `pending_review` pin (vs teal for open), and the user closes it out:

```bash
flutter-scout annotations check
flutter-scout annotations resolve ann_001 --note "Fixed layout"
flutter-scout annotations dismiss ann_002 --note "No longer relevant"
flutter-scout annotations reopen ann_001
flutter-scout annotations clear --resolved
```

Treat `hitTestableText` as the safest text set for immediate `tap-text`. `offscreenText` is useful for planning, but it is not directly tappable until you scroll it into view.

Read viewport facts before tapping: `visibleRect`, `visibleFraction`, `offscreen`, `partiallyOffscreen`, `suggestedTapPoint`, and `hitTestable`. If a control is partially visible, prefer the Scout handle because Scout taps the visible safe point. If a control is offscreen, scroll first. Target taps require a visible safe point; if a handle exists but is offscreen, Scout returns `target_not_visible` instead of tapping an offscreen rect center.

To reach a handle that is offscreen or lazy-unbuilt (e.g. a keyed row deep in a long `ListView`/`GridView`), use `scroll-to` instead of emitting many manual scrolls. It scrolls the enclosing scrollable until the target builds and becomes hit-testable, then stops:

```bash
flutter-scout scroll-to far_target
flutter-scout scroll-to painted_tile_80 --max-scrolls 30
flutter-scout scroll-to side_panel_item --direction right
```

It returns `result:"reached"` with `scrollsUsed` and the matched `target` on success, `result:"already_visible"` when no scroll was needed, and fails with `reason:"reached_scroll_end"` (hit an edge) or `reason:"target_not_reached"` (exhausted `--max-scrolls`; raise it for deeper targets). When a plain `tap`/`long-press` cannot find a handle and the screen has a scrollable, the `target_not_found` failure includes `reason:"maybe_offscreen_or_lazy"` and `reachHint:"scroll-to <target>"` — follow it rather than assuming the handle is wrong.

If you omit `--direction`, `scroll-to` starts downward and automatically retries the opposite direction when it reaches the scroll edge without finding the target. Use an explicit `--direction` only when you know which way the target lives.

Explicit widget `Key`s are always surfaced as handles in `interactables` (for example a keyed `InkWell`, `ListTile`, or `GestureDetector` appears as `tap.<key>`), and they win over text-derived ids, so prefer keyed handles when present. Handle matching is kind-prefix agnostic: `btn.gesture_menu_pin`, `tap.gesture_menu_pin`, and the bare `gesture_menu_pin` all resolve to the same keyed node.

`swipe` and `long-press` accept a handle via `--target`/positional target (resolved to the target's safe point), so prefer `swipe left --target tap.task_1` or `long-press tap.task_2` over hand-computed coordinates for Dismissible rows, reorder handles, and context menus.

After an action, read `delta.changedText` for keyed `Text` widgets — it reports `{key, from, to}` so a tap that only updates a status label is self-confirming without a follow-up `inspect`.

Icon-only controls can expose handles from keys, tooltips, semantics, common Material icon widgets, or common Material glyph text. Try handles such as `btn.duplicate`, `btn.save`, `btn.delete`, `btn.download`, `btn.back`, or `btn.search` before falling back to coordinates; Scout can match a kind-prefixed guess like `btn.duplicate` to a custom tappable exposed as `tap.duplicate`. Unlabeled gesture targets with clear contained action text can also appear as `btn.*` handles, such as `btn.payment`, `btn.confirm_payment`, `btn.done`, `btn.create_order`, or `btn.save_smoke`.

Duplicate unkeyed fields are suffixed in inspect output, for example `field.enter_duplicate_note` and `field.enter_duplicate_note_2`. Use the exact `fieldsById` key when filling or inputting duplicate labels.

Use `fill` and `input` only for real editable text fields. If inspect shows `visualTree` or `controlGroups` for a custom control such as a numeric keypad, operate it explicitly with `tap` commands. Control group children can expose aliases such as `key.1`, `key.5`, and commit actions such as `btn.save`; tap them in the order a human would. Read `suggestedActions` for general forms and pickers too: it can suggest `fillForm`, `setDateRange`, `selectOption`, `enterValue`, and `submitForm` intents with concrete targets/options.

4. Act in feature-sized steps:

```bash
flutter-scout tap btn.add_supplier
flutter-scout fill --json '{"Supplier name":"QA Supplier","Phone":"0123456789"}'
flutter-scout tap btn.save_supplier
```

After every action, read `result`, `delta`, `fieldValues`, `recentErrors`, and `recentLogSignals`. Do not run a separate screenshot or full inspect unless the delta is unclear.

Action output is compact by default, including failures; failed expectations include compact before/after summaries, target, expectation, delta, warnings, and recent errors instead of dumping full inspect trees. Add `--verbose` only when full before/after summaries are needed.

When an action reports `activated_no_observed_change`, Scout dispatched the gesture but did not observe a synchronous Flutter tree, field, text, or geometry change before the wait timeout. Check `activation`, `warnings`, `recentErrors`, overlays, and logs before retrying. A tap on an already-selected tab/toggle instead reports `result:"already_selected"` — that is expected behavior, not a failure; do not retry it.

If action output includes `lateChangeObserved:true`, trust the returned `afterSummary`; Scout waited past the first stable check and observed a delayed route, modal, or overlay change.

**Prefer act+gate in one command.** Every action (`tap`, `tap-text`, `input`, `fill`) accepts `--expect-text/--expect-gone/--expect-target/--expect-selected/--expect-screen/--expect-field` (+ `--expect-timeout`): the action dispatches and then waits — in the same VM call — for the expected UI state. This removes the inter-command gap where timing-sensitive UI (auto-reverting views, short toasts) drifts away:

```bash
flutter-scout tap btn.save --expect-text "Saved"
flutter-scout tap-text "Setting" --expect-text "Branding"
flutter-scout input --target field.name "QA" --expect-field field.name=QA
```

A met expectation adds `expectation.met:true` with `waitedMs`; an unmet one fails with `expectation_not_met` (the action result and final `visibleText` are included, so you know whether the tap itself worked).

For standalone waits, `wait-for` supports the same condition set:

```bash
flutter-scout wait-for --text "Saved" --timeout 8000
flutter-scout wait-for --gone "Loading"
flutter-scout wait-for --target btn.menu
flutter-scout wait-for --selected tap.t_c
flutter-scout wait-for --screen SettingScreen --field field.name=QA
flutter-scout wait-for --view "Admin"       # viewSignature contains (same-route view swaps)
```

Text matching is case-insensitive; success returns `result:"met"` with `waitedMs`, timeout fails with `wait_for_timeout` (including final `visibleText`), and a fresh blocking error exits early with `blocking_error_during_wait`.

For exploratory loops (inspect, think, act, think), run the **`explore`/`serve` daemon** instead of separate CLI invocations — one persistent VM connection, each step a ~ms HTTP call instead of a fresh process. Use `explore --once` when you want a machine-readable setup hint without starting the daemon:

```bash
flutter-scout explore --once
flutter-scout --app my-app explore --port-file /tmp/scout.port &
flutter-scout --app my-app serve --port-file /tmp/scout.port &
curl "localhost:$(cat /tmp/scout.port)/run?cmd=inspect%20--brief"
curl "localhost:$(cat /tmp/scout.port)/run" --data 'tap btn.save --expect-text Saved'
curl "localhost:$(cat /tmp/scout.port)/stop"
```

Each `/run` response is `{"exitCode": N, "result": {...}}` — the command's JSON is nested as a parsed object under `result` (raw text under `output` only when the command didn't print JSON), so parse the response once. Always `/stop` the daemon when the loop ends — a leaked daemon holds a VM connection open, and a later `stop`/relaunch orphans it. Don't spin up `serve` for a single command or a 2–3 step known sequence; the daemon lifecycle costs more than it saves there.

If compact action output includes `workflowHints` with `code:"consider_serve"`,
switch to `explore`/`serve` for the rest of that exploratory loop.

**Choosing between `serve`, `batch`, and plain commands** — the deciding factor is whether you know the sequence in advance, not how many steps it is. Ask: *"Could I write this whole sequence to a file right now, before running anything?"*

- **No — each step depends on what the previous step showed** (you're discovering the app; your own reasoning is the branch): use **`serve`**. `batch` is a fixed list and cannot branch on results.
- **Yes, and it's more than ~3 steps** (verification flow, setup, replay): use **`batch`** — simpler than a daemon, and its one-shot summary reports failures and timings.
- **Yes, and it's 1–3 steps**: just run the commands directly.

So: discovering → `serve`; scripted → `batch`; one-off → a plain command. Once a `serve` exploration is done, `export-batch` freezes it into a `batch` script (the sequence is now known).

**Chain whole flows with `batch`** — one process, one VM connection, no startup overhead or timing gaps between steps; stops at the first failed step unless `--keep-going`:

```bash
flutter-scout batch 'tap btn.admin --expect-text Setting; tap-text Setting --expect-text Branding; tap-text "T&C"; tap btn.save --expect-text Saved'
flutter-scout batch --file /tmp/flow.scout   # one command per line, # comments
```

The batch summary reports `failed` (step index, cmd, exitCode), per-step `stepTimingsMs`, and `totalMs` — read it to pinpoint what broke without re-running. After a successful interactive session, `flutter-scout export-batch -o flow.scout` converts the recorded actions (including any `--expect-*` gates you used) into a replayable batch script — the modern replacement for `replay`.

**Address sessions by name from anywhere** — `launch`/`ensure --name <label>` registers the session globally; any command then takes `--app <label>` without cd'ing to the project, and `flutter-scout apps` lists registered sessions:

```bash
flutter-scout --app test-flutter-scout inspect --brief
flutter-scout --app test-flutter-scout batch 'tap btn.save --expect-text Saved'
```

Scout's own overlay chrome (the annotation FAB, instance badge, pins) is invisible to agent gestures and excluded from inspect: a tap aimed at an app control under the FAB lands on the app control, and Scout chrome never surfaces as tappable handles.

5. After Dart-only code edits, hot update instead of relaunching:

```bash
flutter-scout reload
flutter-scout restart
```

Prefer `reload` first because it preserves app state. Use `restart` when reload is rejected or state must reset. If `reload` returns `reload_rejected`, treat the app as still running previous code unless the owning Flutter tool reports otherwise. `restart` requires a Scout-owned `launch`/`ensure` process; attach-only sessions should use `reload`, use the owning Flutter terminal or IDE hot restart, or run `ensure` to launch when needed. Native, plugin, asset, and `pubspec.yaml` changes can still require a full rebuild.

6. Use targeted visual evidence when layout matters:

```bash
flutter-scout bounds btn.save_supplier
flutter-scout crop btn.save_supplier -o /tmp/save_button.png
flutter-scout crop --text "-Hair Dye - Plum" -o /tmp/appointment_label.png
flutter-scout crop --rect 900,0,200,90 -o /tmp/top_right.png
flutter-scout screenshot -o /tmp/current_screen.png
flutter-scout screenshot --annotated -o /tmp/marked.png
```

`crop --text "<visible text>"` crops the matched visible text bounds directly, which is useful when a label has no stable handle or starts with `-`. `crop --rect x,y,w,h` captures an arbitrary logical region without needing a handle — useful for corners and composite areas. `crop --annotated` draws numbered marks over interactables inside the region and prints the legend.

For long or multi-line text, `input --target <field> --file /path/to/text.txt` reads the value from a file — no shell-quoting battles.

Prefer `bounds` and crops over full screenshots when inspecting one control or dialog. `screenshot` and `crop` render in-app by default (works on any platform, including physical devices), and report `"backend": "in_app_capture"`. When the captured region contains a platform view (map, webview, native video) that would render blank, Scout automatically falls back to a native capture. Pass `--native` to force the native backend (iOS Simulator `simctl` / macOS app-window `screencapture`); native crops remain iOS Simulator-only and macOS attach returns `crop_unsupported_target`.

`tap-text` activates the nearest safe actionable ancestor and returns both `target` and `textTarget`. Use `tap-text --text "<visible text>"` when the label starts with `-` or another shell-sensitive token. Short labels like `OK` require exact matches. If the matched text maps to a different semantic action, Scout returns `tap_text_target_mismatch` instead of tapping. Use the explicit handle reported in the error, coordinates, or `tap-text --allow-mismatch` only when that mismatch is intentional. If a broad ancestor would be unsafe, Scout can tap the visible text point and report `activation.strategy:"broad_ancestor_text_point"`; if no actionable ancestor exists but the text point is hit-testable, it reports `activation.strategy:"visible_text_point"`.

When a submit reveals validation, read `delta.newValidationMessages` and `delta.validationCandidates`; they identify the field id, label, and validation message that appeared.

`tap-text` ranks duplicate visible text matches before tapping: hit-testable/actionable targets beat covered text and broad ambiguous ancestors. Every `tap-text` response includes `activation.risk` with a level, confidence, and reasons. Treat medium/high risk as a sign to prefer an explicit handle from `inspect` when repeating the action.

If a response reports `helperProtocol.status:"older_than_cli"` (or `"stale_or_old_helper"` from very old helpers), the attached app compiled an older flutter_scout_helper than this CLI expects. Hot reload cannot refresh a git/pub-cache dependency — bump the dependency (or patch the resolved pub-cache checkout) and fully relaunch with `stop --clear-session` + `launch`.

7. Replay after a fix:

```bash
flutter-scout replay .flutter_scout/session.json
```

Replay should be the first check after changing code for a flow you already tested. Replay output includes a `transcript` array plus structured `results`; use the transcript for concise reporting and the results for evidence.

## Useful Commands

```bash
flutter-scout status
flutter-scout ensure --device <simulator-id> --project <flutter-app-path> --name add-member
flutter-scout launch --device <simulator-id> --project <flutter-app-path> --name add-member
flutter-scout doctor --project <flutter-app-path> --device <simulator-id>
flutter-scout annotations list
flutter-scout annotations wait --timeout 600 --poll 1000
flutter-scout annotations targets
flutter-scout annotations enable
flutter-scout annotations disable
flutter-scout annotations check
flutter-scout annotations fixed ann_001 --note "Shortened label"
flutter-scout annotations delete ann_001 ann_003
flutter-scout annotations resolve ann_001 --note "Fixed"
flutter-scout annotations dismiss ann_002
flutter-scout annotations clear --resolved
flutter-scout wait stable
flutter-scout wait-for --text "Saved" --timeout 8000
flutter-scout wait-for --gone "Loading"
flutter-scout wait-for --target btn.menu --selected tap.t_c
flutter-scout tap btn.save --expect-text "Saved"
flutter-scout tap-text "Setting" --expect-text "Branding"
flutter-scout input --target field.tnc --file /tmp/tnc.txt --expect-text "rev. 5"
flutter-scout batch 'tap btn.a --expect-text B; tap-text C --expect-screen DScreen'
flutter-scout explore --once
flutter-scout --app my-session explore --port-file /tmp/scout.port
flutter-scout apps
flutter-scout --app my-session inspect --brief
flutter-scout inspect --brief
flutter-scout inspect --surface
flutter-scout inspect --sections textTargets,scrollables,rows
flutter-scout screenshot --annotated -o /tmp/marked.png
flutter-scout crop --rect 900,0,200,90 -o /tmp/region.png
flutter-scout reload
flutter-scout restart
flutter-scout input --target field.search "query"
flutter-scout tap-text "GoodJob"
flutter-scout tap-text --text "-Hair Dye - Plum"
flutter-scout tap 1036 589
flutter-scout long-press btn.more
flutter-scout scroll down --distance 300
flutter-scout scroll down --from 220,760 --distance 520
flutter-scout scroll-to far_target
flutter-scout scroll-to painted_tile_80 --max-scrolls 30 --direction down
flutter-scout swipe left --distance 240
flutter-scout swipe left --from 380,500 --to 80,500
flutter-scout swipe left --target tap.task_1
flutter-scout back
flutter-scout deeplink myapp://route
flutter-scout logs --summary
flutter-scout logs --last 20
flutter-scout evidence -o /tmp/flutter_scout_evidence
flutter-scout evidence --audit -o /tmp/flutter_scout_evidence
flutter-scout stop --clear-session
```

For Scout-owned `launch`/`ensure` sessions, `logs` captures `print`, `debugPrint`, and `dart:developer` `log()` output. Capture runs over a dedicated VM-service listener (Stdout, Stderr, and Logging streams), so it keeps working across hot reload, hot restart, and app backgrounding rather than depending on the fragile Flutter tool console.

`logs --summary` includes `recentLogSignals` and `blockingLogSignals`: structured classifications of hard evidence in Scout-owned logs. This catches cases where the app logs a build/framework error, but the helper's `recentErrors` list is empty because the app swallowed or reformatted the exception. Treat fresh `blocking:true` log signals as hard failures.

If `logs` reports `source:"attach_only_session"` and `available:false`, Scout is attached to a VS Code/Cursor/terminal-owned Flutter run. Scout can still inspect and act, but cannot read that owner console. Use the owning terminal or IDE console for those app logs, run `flutter logs` separately, or start with `flutter-scout ensure`/`launch` when Scout should own log capture.

If `logs --contains <text>` reports `available:true` and `matched:0`, Scout did read a non-empty Scout-owned log but no lines matched that filter. Broaden the search or inspect the app's own logging path.

Use `evidence` at the end of a significant run to collect `summary.json`, `status.json`, `logs.json`, optional `inspect.json`, optional `session.json`, `transcript.txt`, and a screenshot when supported. Add `--audit` to also write an `audit.md` scaffold with current state, transcript, and finding placeholders. Missing attach logs or unsupported screenshots are recorded as structured evidence rather than making the command fail.

`recentErrors` entries include severity facts such as `severity`, `blocking`, `phase`, `ageMs`, and `stale`. `recentLogSignals` entries use the same idea for Scout-owned log evidence and include `kind`, `message`, `line`, and compact stack/context when available. Treat fresh `blocking:true` errors or log signals as hard failures. Older or non-blocking startup/network entries may be relevant context, but they do not automatically mean the current flow failed.

## Agent Rules

- Treat Flutter Scout as eyes and hands, not a QA judge.
- Prefer named `ensure`/`launch` for agent-run verification sessions so Scout owns logs, restart, and session identity.
- Use `attach` only to preserve human-in-the-loop state or when the user explicitly asks for it.
- Prefer `ensure` over repeated `launch`; repeated full launch causes slow native rebuilds.
- Always pass `--name <feature>` when running the app via `launch`/`ensure` — never run unnamed. Use a kebab-case slug of the feature/task currently in focus (e.g. `add-member`), or the current git branch when no single feature is. Then address that session anywhere with `--app <feature>`.
- Start with `inspect --brief`; use `inspect --surface` for active modals/pickers/dialogs; use full `inspect` or `--sections` only when the compact payload is not enough. Read `semanticQuality`, `perception`, `structuredRows`, and `suggestedActions` before deciding whether to use handles, row aliases, form fill, picker options, or visual crops. Avoid blind screenshots — but when you do need a visual map, prefer `screenshot --annotated` (numbered marks + handle legend) over a plain screenshot.
- Treat `result:"already_selected"` as success-no-op (the tab/toggle was already in that state); never retry it.
- Prefer `--expect-*` flags on actions over separate wait-for calls: act + gate in one VM call, no inter-command gap for timing-sensitive UI to drift through. Use standalone `wait-for` (text/gone/target/selected/screen/field) when no action precedes the wait.
- Pick the execution mode by whether the sequence is known in advance: discovering the app step-by-step (each action depends on the last snapshot) → run an `explore`/`serve` daemon and `/stop` it when done; a known multi-step flow → `batch` (one process, one connection); a one-off → a plain command. `batch` cannot branch on results — that is what the persistent daemon is for.
- Use `--app <name>` to address a named session from any directory; `export-batch` after a `serve` exploration to freeze it into a replayable `batch` script.
- Treat non-zero `degradedNodes` as partial eyes: the listed nodes are trustworthy, but a few elements could not be read.
- After Dart-only edits, run `reload` or `restart` before replaying flows.
- Prefer `fill` for real text fields, but do not use it for custom pickers, keypads, steppers, calendars, or segmented controls.
- For custom controls, read `visualTree`, `controlGroups`, and `suggestedActions`, then use explicit `tap`/`tap-text`/scroll commands.
- For repeated list/table/card content, prefer `structuredRows` aliases (`row.<label>` / `row.<label>.<action>`) over coordinates or generic repeated handles.
- Treat low `semanticQuality` as a warning that handles may be ambiguous or missing; prefer keys, row aliases, crops, or explicit coordinates only after inspecting the evidence.
- Treat `perception.visual.ocrInPayload:false` as a reminder that inspect is widget/render evidence, not OCR; use `crop`/`screenshot` when visual appearance matters.
- Trust action deltas for next-step planning.
- Use `scroll-to <handle>` to reach an offscreen or lazy-unbuilt target instead of emitting many manual `scroll` calls; raise `--max-scrolls` for deep targets.
- When `tap`/`long-press` returns `target_not_found` with `reason:"maybe_offscreen_or_lazy"`, follow the `reachHint` (`scroll-to <target>`) before concluding the handle is wrong.
- Prefer keyed handles surfaced in `interactables` (`tap.<key>`/`btn.<key>`); handle matching ignores the kind prefix, so a `btn.`/`tap.` guess and the bare key all resolve.
- Pass a handle to `swipe`/`long-press` via `--target` for Dismissible rows, reorder, and menus rather than computing coordinates.
- Read `delta.changedText` (`{key, from, to}`) to confirm a tap that only updated a keyed status label, without a follow-up `inspect`.
- Read `activation` and `warnings` when an action reports `activated_no_observed_change`.
- For `tap-text`, read `activation.risk`; medium/high risk means Scout used a broad, inferred, or non-hit-testable path, so prefer an explicit handle next time.
- Treat `tap_text_target_mismatch` as a safety stop; do not retry blindly. Use an explicit handle or `--allow-mismatch` only after confirming the target is intended.
- Read `delta.newValidationMessages` after save/confirm actions before guessing which required field is missing.
- Treat `lateChangeObserved:true` as a real observed post-action change, not a stale screen.
- Treat `delta.changedGeometry` as a real change for scrolling or layout movement even when text and field values are unchanged.
- Treat drag `result:"navigated"` as a real route/screen transition caused by the gesture, not a plain scroll.
- Trust `status` to refresh stale VM service URIs when it reports `staleRefreshed:true`; reattach only if it reports `staleCleared` or cannot discover a current URI.
- Stop and fix code when `recentErrors` reports Flutter/platform errors.
- Stop and fix code when `recentLogSignals` reports a fresh blocking Flutter build/framework/native error, even if helper `recentErrors` is empty.
- Treat fresh `recentErrors` or `recentLogSignals` with `blocking:true` as hard failures; separate stale/non-blocking startup errors from the current flow.
- Use `tap-text` for visible text rows or picker rows when generic row handles are ambiguous; it returns an actionable `target` and the matched `textTarget`.
- When `tap-text` falls back because the helper is stale, follow the warning and restart/reload the attached app before relying on further text-target behavior.
- Use coordinate scroll/swipe starts when the default gesture may hit the wrong layer.
- Use `tap <x> <y>` or `tap --x <x> --y <y>` for coordinate taps.
- Keep `.flutter_scout/` as runtime state; do not commit it.
- Annotations do not disappear on their own after fixes; use `snapshotRect` versus `liveRect` for evidence, mark each handled pin `fixed` to capture the before/after, then `delete` the ids you addressed (report `removed`/`notFound`) so the overlay stays clean. Never blanket-delete pins you did not fix.
