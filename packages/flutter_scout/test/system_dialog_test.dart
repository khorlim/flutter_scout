import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/src/agent_session.dart';
import 'package:flutter_scout/src/flutter_scout_cli.dart';
import 'package:flutter_scout/src/system_dialog.dart';
import 'package:test/test.dart';

const androidApp = SystemDialogApp(id: 'com.example.scout_test_app');
const iosApp = SystemDialogApp(
  id: 'com.example.scoutTestApp',
  names: ['Scout Test App', 'scout_test_app'],
);

String fixture(String name) =>
    File('test/fixtures/system_dialog/$name').readAsStringSync();

/// A minimal `uiautomator dump` of one foreign window.
String androidDump(String package, List<String> nodes) =>
    '<?xml version="1.0"?><hierarchy rotation="0">'
    '<node class="android.widget.FrameLayout" package="$package" '
    'clickable="false" enabled="true" bounds="[0,0][1080,2400]">'
    '${nodes.join()}</node></hierarchy>';

String androidNode({
  required String package,
  String text = '',
  String id = '',
  String cls = 'android.widget.Button',
  bool clickable = true,
  bool password = false,
  String bounds = '[100,1000][500,1100]',
}) =>
    '<node text="$text" resource-id="$id" class="$cls" package="$package" '
    'clickable="$clickable" enabled="true" password="$password" '
    'bounds="$bounds" />';

AgentView appView(int generation, {AgentView? dialog}) => {
  'ok': true,
  'runId': 'run',
  'runtimeInstanceId': 'one',
  'snapshotId': 'g$generation',
  'screen': 'System dialogs',
  'visibleText': const ['camera: not_determined'],
  'safetyEvidenceStatus': 'complete',
  'rendering': {
    'status': 'active',
    'framesEnabled': true,
    'lifecycle': dialog == null ? 'resumed' : 'inactive',
  },
  'interactables': const [
    {'id': 'btn.request_camera', 'label': 'Request camera'},
  ],
  'systemDialog': ?dialog,
};

AgentView dialogJson(SystemDialog dialog) =>
    jsonDecode(jsonEncode(dialog.toJson())) as AgentView;

void main() {
  group('handles', () {
    test('labels fold to stable sys.* handles', () {
      expect(systemButtonHandle('Allow'), 'sys.allow');
      expect(systemButtonHandle('Don’t Allow'), 'sys.dont_allow');
      expect(systemButtonHandle("Don't allow"), 'sys.dont_allow');
      expect(systemButtonHandle('Allow Once'), 'sys.allow_once');
      expect(systemButtonHandle('Allow While Using App'), 'sys.while_using');
      expect(
        systemButtonHandle('Ask App Not to Track'),
        'sys.ask_app_not_to_track',
      );
      expect(systemButtonHandle('Limit Access…'), 'sys.limit_access');
      expect(systemButtonHandle('  ✓  '), 'sys.button');
      expect(systemButtonHandle('a' * 60).length, 'sys.'.length + 40);
    });
  });

  group('Android', () {
    test('a real API 36 camera prompt parses with resource-id handles', () {
      final dialog = parseAndroidSystemDialog(
        fixture('android_api36_camera_prompt.xml'),
        app: androidApp,
        taskPackages: const {
          'com.google.android.permissioncontroller',
          'com.example.scout_test_app',
        },
      )!;
      expect(dialog.platform, 'android');
      expect(dialog.kind, 'permission');
      expect(dialog.source, 'com.google.android.permissioncontroller');
      expect(
        dialog.title,
        'Allow scout_test_app to take pictures and record video?',
      );
      expect(
        [for (final b in dialog.buttons) b.handle],
        ['sys.while_using', 'sys.only_this_time', 'sys.dont_allow'],
      );
      expect(
        dialog.buttons.first.resourceId,
        'permission_allow_foreground_only_button',
      );
      expect(dialog.buttons.first.label, 'While using the app');
      // Physical pixels, the units of `adb shell input tap`.
      expect(dialog.buttons.first.tapPoint.x, greaterThan(100));
      expect(dialog.belongsToSessionApp, isTrue);
      expect(dialog.ownerEvidence, 'activity_task');
      expect(dialog.answerable, isTrue);
    });

    test('the session app own window is not a system dialog', () {
      final xml = androidDump('com.example.scout_test_app', [
        androidNode(package: 'com.example.scout_test_app', text: 'OK'),
      ]);
      expect(parseAndroidSystemDialog(xml, app: androidApp), isNull);
    });

    test('a window without buttons is not reported', () {
      const pkg = 'com.google.android.apps.nexuslauncher';
      final xml = androidDump(pkg, [
        androidNode(
          package: pkg,
          text: 'Clock',
          cls: 'android.widget.TextView',
          clickable: false,
        ),
      ]);
      expect(parseAndroidSystemDialog(xml, app: androidApp), isNull);
    });

    test('a prompt in another app task names that app as owner', () {
      const pkg = 'com.google.android.permissioncontroller';
      final xml = androidDump(pkg, [
        androidNode(
          package: pkg,
          text: 'Allow Other to send you notifications?',
          id: 'com.android.permissioncontroller:id/permission_message',
          cls: 'android.widget.TextView',
          clickable: false,
        ),
        androidNode(
          package: pkg,
          text: 'Allow',
          id: 'com.android.permissioncontroller:id/permission_allow_button',
        ),
      ]);
      final dialog = parseAndroidSystemDialog(
        xml,
        app: androidApp,
        taskPackages: const {pkg, 'com.other.app'},
      )!;
      expect(dialog.ownerName, 'com.other.app');
      expect(dialog.belongsToSessionApp, isFalse);
      // A prompt whose requester is gone (only the controller is left in
      // the task) has no proven owner.
      final orphan = parseAndroidSystemDialog(
        xml,
        app: androidApp,
        taskPackages: const {pkg},
      )!;
      expect(orphan.ownerName, isNull);
      expect(orphan.belongsToSessionApp, isNull);
    });

    test('password fields make a credential prompt', () {
      const pkg = 'com.google.android.gms';
      final xml = androidDump(pkg, [
        androidNode(
          package: pkg,
          cls: 'android.widget.EditText',
          password: true,
        ),
        androidNode(package: pkg, text: 'Next'),
      ]);
      final dialog = parseAndroidSystemDialog(xml, app: androidApp)!;
      expect(dialog.kind, 'credential');
      expect(dialog.answerable, isFalse);
    });

    test('focus and task parsing from dumpsys output', () {
      const focus =
          '  mCurrentFocus=Window{895ceb8 u0 com.google.android.permissioncontroller/com.android.permissioncontroller.permission.ui.GrantPermissionsActivity}\n'
          '  mFocusedApp=ActivityRecord{41726930 u0 com.google.android.permissioncontroller/com.android.permissioncontroller.permission.ui.GrantPermissionsActivity t48}';
      final parsed = parseAndroidFocus(focus);
      expect(parsed.package, 'com.google.android.permissioncontroller');
      expect(parsed.task, 48);
      const activities =
          '    * Hist  #1: ActivityRecord{41726930 u0 com.google.android.permissioncontroller/com.android.permissioncontroller.permission.ui.GrantPermissionsActivity t48}\n'
          '      resultTo=ActivityRecord{79747713 u0 com.example.scout_test_app/.MainActivity t48}\n'
          '    * Hist  #0: ActivityRecord{218459965 u0 io.example.other/.MainActivity t46}';
      expect(androidTaskPackages(activities, 48), {
        'com.google.android.permissioncontroller',
        'com.example.scout_test_app',
      });
    });
  });

  group('iOS', () {
    test('a SpringBoard camera alert of the session app', () {
      final tree = jsonDecode(fixture('ios26_camera_prompt.json'));
      expect(iosFrontmostBundle(tree), 'com.example.scoutTestApp');
      final dialog = parseIosSystemDialog(tree, app: iosApp)!;
      expect(dialog.platform, 'ios');
      expect(dialog.kind, 'permission');
      expect(dialog.title, '“Scout Test App” would like to access the Camera.');
      expect(
        dialog.message,
        'Scout system-dialog verification requests camera access.',
      );
      // App buttons inside the scene card and scroll bars are not dialog
      // buttons.
      expect(
        [for (final b in dialog.buttons) b.handle],
        ['sys.dont_allow', 'sys.allow'],
      );
      expect(dialog.button('sys.allow')!.tapPoint, (x: 275.0, y: 560.7));
      expect(dialog.belongsToSessionApp, isTrue);
      expect(dialog.ownerEvidence, 'quoted_app_name');
    });

    test('an alert quoting another app is owned by that app', () {
      final text = fixture(
        'ios26_camera_prompt.json',
      ).replaceAll('“Scout Test App”', '“Other App”');
      final dialog = parseIosSystemDialog(jsonDecode(text), app: iosApp)!;
      expect(dialog.ownerName, 'Other App');
      expect(dialog.belongsToSessionApp, isFalse);
    });

    test('no alert, only the app scene, is no dialog', () {
      final tree = jsonDecode(fixture('ios26_camera_prompt.json')) as List;
      final root = tree.first as Map;
      (root['children'] as List).removeLast();
      expect(parseIosSystemDialog(tree, app: iosApp), isNull);
    });

    test('Apple Account sign-in prompts are credential prompts', () {
      final tree = [
        {
          'type': 'Alert',
          'AXLabel': 'Sign In to Apple Account',
          'children': [
            {'type': 'SecureTextField', 'AXLabel': 'Password', 'children': []},
            {
              'type': 'Button',
              'AXLabel': 'Sign In',
              'frame': {'x': 0, 'y': 0, 'width': 100, 'height': 40},
              'children': [],
            },
          ],
        },
      ];
      final dialog = parseIosSystemDialog(tree, app: iosApp)!;
      expect(dialog.kind, 'credential');
      expect(dialog.answerable, isFalse);
      expect(dialog.belongsToSessionApp, isNull);
    });
  });

  group('refusal rules', () {
    SystemDialog ios({
      String quoted = 'Scout Test App',
      bool twoAllows = false,
    }) {
      final tree = jsonDecode(
        fixture('ios26_camera_prompt.json')
            .replaceAll('“Scout Test App”', '“$quoted”')
            .replaceAll('Don’t Allow', twoAllows ? 'Allow' : 'Don’t Allow'),
      );
      return parseIosSystemDialog(tree, app: iosApp)!;
    }

    test('the session app dialog may be answered with an observed handle', () {
      expect(systemTapRefusal(ios(), 'sys.allow'), isNull);
      expect(
        systemTapRefusal(ios(), 'sys.later')!.code,
        'system_dialog_button_not_observed',
      );
    });

    test('another app dialog needs its exact owner name', () {
      final other = ios(quoted: 'Other App');
      expect(
        systemTapRefusal(other, 'sys.allow')!.code,
        'system_dialog_other_app',
      );
      expect(
        systemTapRefusal(other, 'sys.allow', dialogOwner: 'Another')!.code,
        'system_dialog_other_app',
      );
      expect(
        systemTapRefusal(other, 'sys.allow', dialogOwner: 'Other App'),
        isNull,
      );
    });

    test('duplicate labels are reported but never pressed', () {
      final dialog = ios(twoAllows: true);
      expect(dialog.buttons.every((b) => b.ambiguous), isTrue);
      expect(
        systemTapRefusal(dialog, 'sys.allow')!.code,
        'system_dialog_button_ambiguous',
      );
    });
  });

  group('agent session', () {
    final dialog = dialogJson(
      parseIosSystemDialog(
        jsonDecode(fixture('ios26_camera_prompt.json')),
        app: iosApp,
      )!,
    );
    final otherDialog = dialogJson(
      parseIosSystemDialog(
        jsonDecode(
          fixture(
            'ios26_camera_prompt.json',
          ).replaceAll('“Scout Test App”', '“Other App”'),
        ),
        app: iosApp,
      )!,
    );

    test('a dialog blocks Flutter input and names system-tap', () async {
      final s = AgentSession(
        read: () async => appView(1, dialog: dialog),
        validate: (_) {},
        act: (_, _) async => throw StateError('nothing may dispatch'),
      );
      addTearDown(s.close);
      final opened = await s.open();
      expect(opened['actionable'], isFalse);
      expect(opened['inputBlockedReason'], 'system_dialog');
      expect(opened['blockedBy']['reason'], 'system_dialog');
      expect(opened['blockedBy']['nextStep'], contains('system-tap'));
      expect(
        () => s.start(opened['viewRevision'] as int, {
          'method': 'tap',
          'args': ['btn.request_camera'],
        }),
        throwsA(isA<AgentRejection>()),
      );
      expect(s.actions, 0);
    });

    test('system-tap goes through the hand with a receipt', () async {
      var current = appView(1, dialog: dialog);
      AgentView? sent;
      final s = AgentSession(
        read: () async => current,
        validate: (_) {},
        act: (action, observed) async {
          sent = action;
          expect(
            observed['systemDialog']['fingerprint'],
            dialog['fingerprint'],
          );
          current = appView(2);
          return {
            'ok': true,
            'dispatch': 'dispatched',
            'dialogAfter': 'dismissed',
          };
        },
      );
      addTearDown(s.close);
      final opened = await s.open();
      final ticket = s.start(opened['viewRevision'] as int, {
        'method': 'system-tap',
        'args': ['sys.allow'],
      });
      expect(ticket['ok'], isTrue);
      AgentView receipt;
      do {
        receipt = await s.nextEvent(1000);
      } while (receipt['type'] != 'action');
      expect(receipt['result']['dialogAfter'], 'dismissed');
      expect(sent!['args'], ['sys.allow']);
      s.acknowledge(ticket['actionId'] as String);
      expect(s.scene['actionable'], isTrue);
    });

    test(
      'another app dialog, a stale or unobserved dialog are refused',
      () async {
        var current = appView(1, dialog: otherDialog);
        final s = AgentSession(
          read: () async => current,
          validate: (_) {},
          act: (_, _) async => {'ok': true, 'dispatch': 'dispatched'},
        );
        addTearDown(s.close);
        final opened = await s.open();
        final revision = opened['viewRevision'] as int;
        String reason(AgentView action, int at) {
          try {
            s.start(at, action);
          } on AgentRejection catch (error) {
            return error.code;
          }
          return 'accepted';
        }

        expect(
          reason({
            'method': 'system-tap',
            'args': ['sys.allow'],
          }, revision),
          'agent_system_dialog_other_app',
        );
        // The dialog changes before the decision is sent.
        current = appView(2, dialog: dialog);
        await s.observe();
        expect(
          reason({
            'method': 'system-tap',
            'args': ['sys.allow'],
            'params': {'dialogOwner': 'Other App'},
          }, revision),
          'agent_system_dialog_changed',
        );
        current = appView(3);
        final cleared = await s.observe();
        expect(
          reason({
            'method': 'system-tap',
            'args': ['sys.allow'],
          }, cleared['viewRevision'] as int),
          'agent_system_dialog_not_observed',
        );
        expect(s.actions, 0);
      },
    );

    test('an explicit owner answers another app dialog', () async {
      final s = AgentSession(
        read: () async => appView(1, dialog: otherDialog),
        validate: (_) {},
        act: (_, _) async => {'ok': true, 'dispatch': 'dispatched'},
      );
      addTearDown(s.close);
      final opened = await s.open();
      expect(
        s.start(opened['viewRevision'] as int, {
          'method': 'system-tap',
          'args': ['sys.dont_allow'],
          'params': {'dialogOwner': 'Other App'},
        })['ok'],
        isTrue,
      );
    });

    test('a waiting watch ends when a dialog appears', () async {
      var current = appView(1);
      final s = AgentSession(
        interval: const Duration(milliseconds: 20),
        read: () async => current,
        validate: (_) {},
        act: (_, _) async => {'ok': true, 'dispatch': 'dispatched'},
      );
      addTearDown(s.close);
      await s.open();
      s.watch({'text': 'Saved'}, 5000);
      current = appView(2, dialog: dialog);
      AgentView event;
      do {
        event = await s.nextEvent(1000);
      } while (event['type'] != 'condition');
      expect(event['status'], 'system_dialog');
    });
  });

  test('Android permissions are read from dumpsys package', () {
    const text = '''
    declared permissions:
      com.example.scout_test_app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION: prot=signature
    requested permissions:
      android.permission.POST_NOTIFICATIONS
      android.permission.CAMERA
      android.permission.RECORD_AUDIO
    install permissions:
      android.permission.INTERNET: granted=true
    User 0: ceDataInode=1
      runtime permissions:
        android.permission.POST_NOTIFICATIONS: granted=false, flags=[ USER_SET ]
        android.permission.CAMERA: granted=true, flags=[ USER_SET ]
''';
    final parsed = parseAndroidPackagePermissions(text);
    expect(parsed.requested, {
      'android.permission.POST_NOTIFICATIONS',
      'android.permission.CAMERA',
      'android.permission.RECORD_AUDIO',
    });
    expect(parsed.granted['android.permission.CAMERA'], isTrue);
    expect(parsed.granted['android.permission.POST_NOTIFICATIONS'], isFalse);
    expect(
      parsed.granted.containsKey('android.permission.RECORD_AUDIO'),
      isFalse,
    );
  });

  test('flutter devices --machine targetPlatform records a mobile target', () {
    final android = FlutterScoutCli.debugFlutterDeviceFromMachine({
      'id': 'emulator-5554',
      'name': 'sdk gphone64 arm64',
      'targetPlatform': 'android-arm64',
      'emulator': true,
    });
    expect(android['platform'], 'android-arm64');
    expect(android['category'], 'mobile');
    expect(android['emulator'], isTrue);
    final desktop = FlutterScoutCli.debugFlutterDeviceFromMachine({
      'id': 'macos',
      'name': 'macOS',
      'targetPlatform': 'darwin',
    });
    expect(desktop['category'], isNull);
  });
}
