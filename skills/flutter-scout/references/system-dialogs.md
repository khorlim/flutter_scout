# Native system dialogs (permission prompts)

A runtime permission prompt (camera, photos, location, notifications,
contacts, microphone, tracking) is drawn by the OS above the Flutter app, so
the Flutter tree alone looks normal. Scout reports it in the scene, blocks
Flutter input while it is shown, and lets the agent answer it with one
explicit action. Scout never answers a dialog by itself.

Supported targets: the iOS Simulator and Android emulators recorded for the
named session. A physical device, macOS and other platforms are not probed.

## Seeing it

When a dialog covers the app, every scene carries `view.systemDialog`:

```json
{
  "present": true, "platform": "ios", "kind": "permission",
  "source": "SpringBoard",
  "title": "“Scout Test App” would like to access the Camera.",
  "message": "Take a profile photo.",
  "buttons": [{"handle": "sys.dont_allow", "label": "Don’t Allow"},
              {"handle": "sys.allow", "label": "Allow"}],
  "owner": {"name": "Scout Test App", "evidence": "quoted_app_name",
            "belongsToSessionApp": true},
  "flutterInputBlocked": true, "answerable": true
}
```

- The scene is `actionable:false` with `inputBlockedReason:'system_dialog'`,
  and `blockedBy.nextStep` names the choices. Flutter input is refused while
  the dialog is up: a person could not reach the app either.
- A pending `watch` ends with `status:'system_dialog'`.
- Android buttons carry `resourceId`. Known permission buttons have fixed
  handles: `sys.allow`, `sys.while_using` (While using the app),
  `sys.only_this_time`, `sys.dont_allow` (both deny variants),
  `sys.allow_always`, `sys.allow_all`, `sys.select_photos`,
  `sys.keep_while_using`. Other buttons are named from their label (`Allow
  Once` is `sys.allow_once`, `Allow While Using App` is `sys.while_using`).
- `owner` is the app the dialog is about: on iOS the quoted name in the
  title, on Android the package whose activity task holds the prompt.
  `belongsToSessionApp` is true, false (another app) or null (unproven).
- `kind:'credential'` (a password or text field, Apple Account, sign in) is
  reported with `answerable:false`. Scout never answers it: ask the user.

The tap that requests a permission usually returns before the prompt is up,
so observe again (or keep a `watch` open) after it.

Cost: the eyes probe the native layer only while Flutter reports the app not
`resumed` or not rendering, while a dialog was last seen, or on an explicit
query. A probe is reused for 1 s and, while the app stays inactive with no
dialog (backgrounded), the gap grows to 5 s. A resumed app with no dialog
seen is never probed.
A probe takes about 0.3-0.8 s on the iOS Simulator and 1-4 s on an Android
emulator. Force one with `query('system-dialog')` (bridge: `query
'{"method":"system-dialog"}'`), for example when a dialog of another app may
be up while the app still reports `resumed`.

## Answering it

```js
await scout.act(scene.viewRevision, {method: 'system-tap', args: ['sys.allow']});
```

```bash
node <client> call --app task --brief act '{"viewRevision":5,"action":{"method":"system-tap","args":["sys.allow"]}}'
```

Answer only when the user's task says which answer to give. `system-tap`
takes one handle from `view.systemDialog.buttons`. It is refused, with
nothing pressed, when:

- no dialog was observed at that `viewRevision`
  (`agent_system_dialog_not_observed`), or a different dialog is up now
  (`agent_system_dialog_changed`): observe and decide again;
- the handle is not one of its buttons, or two buttons share it
  (`..._button_not_observed`, `..._button_ambiguous`);
- it is a credential prompt (`agent_system_dialog_refused`);
- the dialog belongs to another app or to an unproven owner
  (`agent_system_dialog_other_app`). Answer one only when the task covers
  that app, with `params: {dialogOwner: '<owner.name>'}` (or `'unknown'`).

At dispatch Scout reads the dialog again and presses only if it is unchanged
(`system_dialog_changed`, `system_dialog_gone` otherwise). The receipt is an
ordinary act receipt: `dispatch:'dispatched'`, `systemTap` (handle, label,
point, mechanism) and `dialogAfter` (`dismissed`, `replaced`,
`still_present` or `unknown`, observed for up to 3 s, never retried). A tool
failure is `system_tap_outcome_unknown` (the touch may have been sent):
check the screen. Business completion is still yours to check, for example
the app's own permission status text. `system-tap` is never a `react` rule.

## Pre-granting instead

To avoid the prompt, change the permission before or during a run:

```bash
flutter-scout --app <task> permissions grant camera microphone
flutter-scout --app <task> permissions revoke location --allow-app-termination
flutter-scout --app <task> permissions reset camera --allow-app-termination
flutter-scout permissions grant photos --device <udid-or-serial> --app-id <bundle-or-package>
flutter-scout --app <task> permissions list
```

The app defaults to the running session app; `--app-id` names one that is
not running (it must be installed). `--device` takes a booted simulator or
emulator outside a session.

| Service | iOS Simulator (`simctl privacy`) | Android emulator (`pm grant`) |
|---|---|---|
| camera | yes (simctl's help omits it; works on Xcode 26.6) | CAMERA |
| microphone | yes | RECORD_AUDIO |
| photos, photos-add, media-library | yes | photos: READ_MEDIA_IMAGES, READ_MEDIA_VIDEO |
| location, location-always | yes | FINE + COARSE; BACKGROUND |
| contacts, contacts-limited | yes | contacts: READ/WRITE_CONTACTS |
| calendar, reminders, motion, siri, all | yes | calendar: READ/WRITE_CALENDAR |
| notifications | no: answer the prompt | POST_NOTIFICATIONS (API 33+) |
| tracking (ATT), bluetooth | no: answer the prompt | bluetooth: BLUETOOTH_CONNECT, BLUETOOTH_SCAN |
| any runtime permission | - | `android.permission.<NAME>` |
| app ops | - | `appop:<OP>` (allow, deny, default) |

- Termination: the iOS Simulator terminates the running app for any change,
  grant included, and Android kills it when a permission is revoked or
  reset. While the session app runs, those need `--allow-app-termination`
  (`permission_change_may_terminate_app` otherwise; nothing changed).
  Relaunch with `ensure` afterwards. An Android grant keeps the app running;
  the app sees the change the next time it checks.
- Android `reset` revokes and clears the user-set/user-fixed flags, so the
  next request prompts again. Each Android change is verified from `dumpsys
  package`. A permission the app does not declare is skipped
  (`not_requested_by_app`) and the command fails with
  `permission_change_incomplete` listing every result.

## Requirements and limits

- iOS Simulator needs AXe (`brew install cameroncooke/axe/axe`, maintained,
  validated with Xcode 26 and 27; `FLUTTER_SCOUT_AXE` names another binary).
  Without it, `systemDialog` says `status:'probe_unavailable'` with the
  install hint; `doctor` reports `systemDialogs.available`. AXe reads the
  simulator's accessibility tree and sends touches through CoreSimulator; it
  needs no macOS Accessibility permission and never moves the host mouse.
- Android uses only `adb` (`dumpsys window`, `uiautomator dump`, `input
  tap`). A prompt whose requesting app was killed stays on screen with no
  provable owner; it is reported with `owner.name:null`.
- Physical iPhone or iPad: no host tool can press SpringBoard alerts without
  an XCUITest runner, and simctl cannot pre-grant. Ask the user to answer the
  prompt, or to set the permission in Settings before the run.
- macOS desktop TCC prompts (camera, microphone, Bluetooth) are not handled.
- A native alert the app itself presents (a plugin's UIAlertController) is
  part of the app scene on iOS and is not reported as a system dialog.
