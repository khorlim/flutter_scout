// Native system dialogs (runtime permission prompts and other system alerts)
// that sit above a Flutter app on the iOS Simulator or an Android emulator.
//
// Pure parsing and decision rules, so they are testable without a device:
// - Android: `uiautomator dump` XML of the focused window, plus the focused
//   activity's task to learn which app the dialog belongs to.
// - iOS Simulator: the accessibility tree AXe (`axe describe-ui`) reads from
//   SpringBoard.
// Scout never answers a dialog by itself. An agent presses one named button
// of a dialog it observed (`system-tap`); these rules decide what is refused.

import 'dart:convert';

/// The app a Scout session drives, as the platform names it.
class SystemDialogApp {
  const SystemDialogApp({required this.id, this.names = const []});

  /// iOS bundle identifier or Android package name.
  final String id;

  /// Names the platform shows for the app in its prompts (iOS display name
  /// and bundle name). Empty on Android, where the dialog's task proves the
  /// owner instead.
  final List<String> names;

  Map<String, Object?> toJson() => {
    'id': id,
    if (names.isNotEmpty) 'names': names,
  };
}

class SystemDialogButton {
  const SystemDialogButton({
    required this.handle,
    required this.label,
    required this.rect,
    this.resourceId,
    this.ambiguous = false,
  });

  /// Stable handle such as `sys.allow`, `sys.dont_allow`, `sys.while_using`.
  final String handle;
  final String label;

  /// Android resource id (`permission_allow_button`), when present.
  final String? resourceId;

  /// Device-tool coordinates: logical points on iOS (AXe), physical pixels
  /// on Android (uiautomator and `input tap`).
  final ({double x, double y, double width, double height}) rect;

  /// Another button of the same dialog has the same handle; it is reported
  /// but never pressed, because Scout cannot tell which one is meant.
  final bool ambiguous;

  ({double x, double y}) get tapPoint =>
      (x: rect.x + rect.width / 2, y: rect.y + rect.height / 2);

  SystemDialogButton _withAmbiguous() => SystemDialogButton(
    handle: handle,
    label: label,
    rect: rect,
    resourceId: resourceId,
    ambiguous: true,
  );

  Map<String, Object?> toJson() => {
    'handle': handle,
    'label': label,
    if (resourceId != null) 'resourceId': resourceId,
    if (ambiguous) 'ambiguous': true,
  };
}

class SystemDialog {
  const SystemDialog({
    required this.platform,
    required this.kind,
    required this.source,
    required this.title,
    required this.message,
    required this.buttons,
    required this.ownerName,
    required this.ownerEvidence,
    required this.belongsToSessionApp,
    this.textEntry = false,
  });

  /// `ios` or `android`.
  final String platform;

  /// `permission`, `credential` or `system`.
  final String kind;

  /// The process or package that draws it (`SpringBoard`,
  /// `com.google.android.permissioncontroller`, ...).
  final String source;
  final String? title;
  final String? message;
  final List<SystemDialogButton> buttons;

  /// The app the dialog is about: the quoted name of an iOS prompt, or the
  /// package whose task an Android dialog runs in. Null when unproven.
  final String? ownerName;

  /// How [ownerName] was established (`quoted_app_name`, `activity_task`)
  /// or `unknown`.
  final String ownerEvidence;

  /// True when the owner is proven to be the session's app, false when it
  /// is proven to be another one, null when unknown.
  final bool? belongsToSessionApp;

  /// The dialog has a text or password field (a sign-in prompt).
  final bool textEntry;

  /// Scout never answers credential or Apple Account prompts.
  bool get answerable => kind != 'credential';

  /// Identity of what the agent decided on. A different value at dispatch
  /// means the dialog changed and nothing is pressed.
  String get fingerprint => jsonEncode([
    platform,
    kind,
    source,
    title,
    message,
    ownerName,
    [
      for (final b in buttons) [b.handle, b.label, b.resourceId],
    ],
  ]);

  SystemDialogButton? button(String handle) {
    for (final candidate in buttons) {
      if (candidate.handle == handle) return candidate;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'present': true,
    'platform': platform,
    'kind': kind,
    'source': source,
    'title': title,
    'message': message,
    'buttons': [for (final b in buttons) b.toJson()],
    'owner': {
      'name': ownerName,
      'evidence': ownerEvidence,
      'belongsToSessionApp': belongsToSessionApp,
    },
    'flutterInputBlocked': true,
    'answerable': answerable,
    if (!answerable)
      'refusal':
          'Scout never answers credential, password or Apple Account '
          'prompts; ask the user.',
    'fingerprint': fingerprint,
  };
}

/// Why a `system-tap` must not be dispatched, or null when it may be.
/// [dialogOwner] is the caller's explicit `params.dialogOwner`.
({String code, String message})? systemTapRefusal(
  SystemDialog dialog,
  String handle, {
  String? dialogOwner,
}) {
  if (!dialog.answerable) {
    return (
      code: 'system_dialog_credential_refused',
      message:
          'the dialog asks for credentials (${dialog.title ?? 'untitled'}); '
          'Scout never answers credential, password or Apple Account '
          'prompts. Ask the user.',
    );
  }
  final button = dialog.button(handle);
  if (button == null) {
    return (
      code: 'system_dialog_button_not_observed',
      message:
          '$handle is not a button of the observed dialog; its buttons are '
          '${[for (final b in dialog.buttons) b.handle].join(', ')}.',
    );
  }
  if (button.ambiguous) {
    return (
      code: 'system_dialog_button_ambiguous',
      message:
          'more than one button of the dialog is named $handle '
          '("${button.label}"); Scout does not guess which one is meant. '
          'Answer it by hand or ask the user.',
    );
  }
  if (dialog.belongsToSessionApp != true) {
    final owner = dialog.ownerName ?? 'unknown';
    if (dialogOwner != owner) {
      return (
        code: 'system_dialog_other_app',
        message: dialog.belongsToSessionApp == false
            ? 'the dialog belongs to "$owner", not to this session\'s app. '
                  'Answer it only when the task covers that app, by passing '
                  'params.dialogOwner: "$owner".'
            : 'Scout could not prove which app the dialog belongs to. Answer '
                  'it only when the task covers it, by passing '
                  'params.dialogOwner: "unknown".',
      );
    }
  }
  return null;
}

/// Stable handles for the buttons of known permission prompts, by Android
/// resource id. Other buttons are named from their label.
const Map<String, String> androidPermissionButtonHandles = {
  'permission_allow_button': 'sys.allow',
  'permission_allow_foreground_only_button': 'sys.while_using',
  'permission_allow_one_time_button': 'sys.only_this_time',
  'permission_deny_button': 'sys.dont_allow',
  'permission_deny_and_dont_ask_again_button': 'sys.dont_allow',
  'permission_allow_always_button': 'sys.allow_always',
  'permission_allow_all_button': 'sys.allow_all',
  'permission_allow_selected_button': 'sys.select_photos',
  'permission_dont_allow_more_selected_button': 'sys.dont_select_more',
  'permission_no_upgrade_button': 'sys.keep_while_using',
  'permission_no_upgrade_and_dont_ask_again_button': 'sys.keep_while_using',
  'permission_no_upgrade_one_time_button': 'sys.keep_only_this_time',
};

/// iOS labels whose slug would not match the Android name of the same
/// choice.
const Map<String, String> _iosLabelHandles = {
  'allow_while_using_app': 'sys.while_using',
};

/// `sys.<slug>` from a visible label: lower case, apostrophes dropped, other
/// punctuation and spaces folded to `_`, at most 40 characters.
String systemButtonHandle(String label) {
  final slug = label
      .toLowerCase()
      .replaceAll(RegExp('[\'’‘`]'), '')
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  final bounded = slug.length > 40
      ? slug.substring(0, 40).replaceAll(RegExp(r'_+$'), '')
      : slug;
  if (bounded.isEmpty) return 'sys.button';
  return _iosLabelHandles[bounded] ?? 'sys.$bounded';
}

List<SystemDialogButton> _markAmbiguous(List<SystemDialogButton> buttons) {
  final counts = <String, int>{};
  for (final b in buttons) {
    counts[b.handle] = (counts[b.handle] ?? 0) + 1;
  }
  return [
    for (final b in buttons) counts[b.handle]! > 1 ? b._withAmbiguous() : b,
  ];
}

final RegExp _credentialText = RegExp(
  r'apple account|apple id|password|passcode|sign in|sign-in|log in|icloud',
  caseSensitive: false,
);

String _kind({
  required bool textEntry,
  required List<String?> texts,
  required bool permission,
}) {
  if (textEntry || texts.any((t) => t != null && _credentialText.hasMatch(t))) {
    return 'credential';
  }
  return permission ? 'permission' : 'system';
}

// ---------------------------------------------------------------- Android --

/// Packages that draw Android runtime permission prompts.
const Set<String> androidPermissionPackages = {
  'com.google.android.permissioncontroller',
  'com.android.permissioncontroller',
  'com.android.packageinstaller',
  'com.google.android.packageinstaller',
};

/// The focused window and its activity task, from
/// `dumpsys window | grep -E 'mCurrentFocus|mFocusedApp'`.
({String? package, int? task}) parseAndroidFocus(String text) {
  String? package;
  int? task;
  final focus = RegExp(
    r'mCurrentFocus=Window\{\S+ \S+ ([A-Za-z0-9_.]+)(?:/|\})',
  ).firstMatch(text);
  package = focus?[1];
  final app = RegExp(
    r'mFocusedApp=ActivityRecord\{\S+ \S+ ([A-Za-z0-9_.]+)/\S+ t(\d+)',
  ).firstMatch(text);
  if (app != null) {
    package ??= app[1];
    task = int.tryParse(app[2]!);
  }
  return (package: package, task: task);
}

/// Packages with an activity in task [task], from the `ActivityRecord{...}`
/// lines of `dumpsys activity activities`.
Set<String> androidTaskPackages(String text, int task) => {
  for (final match in RegExp(
    r'ActivityRecord\{\S+ \S+ ([A-Za-z0-9_.]+)/\S+ t(\d+)',
  ).allMatches(text))
    if (int.tryParse(match[2]!) == task) match[1]!,
};

class _AndroidNode {
  _AndroidNode(this.attributes);
  final Map<String, String> attributes;
  String attr(String name) => attributes[name] ?? '';
  String get resourceIdName {
    final id = attr('resource-id');
    final slash = id.indexOf(':id/');
    return slash < 0 ? id : id.substring(slash + 4);
  }

  ({double x, double y, double width, double height})? get rect {
    final m = RegExp(
      r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]',
    ).firstMatch(attr('bounds'));
    if (m == null) return null;
    final x1 = double.parse(m[1]!), y1 = double.parse(m[2]!);
    final x2 = double.parse(m[3]!), y2 = double.parse(m[4]!);
    if (x2 <= x1 || y2 <= y1) return null;
    return (x: x1, y: y1, width: x2 - x1, height: y2 - y1);
  }
}

String _xmlUnescape(String value) => value.replaceAllMapped(
  RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);'),
  (m) {
    final entity = m[1]!;
    if (entity.startsWith('#x')) {
      return String.fromCharCode(int.parse(entity.substring(2), radix: 16));
    }
    if (entity.startsWith('#')) {
      return String.fromCharCode(int.parse(entity.substring(1)));
    }
    return const {
      'amp': '&',
      'lt': '<',
      'gt': '>',
      'quot': '"',
      'apos': "'",
    }[entity]!;
  },
);

List<_AndroidNode> _androidNodes(String xml) => [
  for (final tag in RegExp(r'<node\b([^>]*?)/?>').allMatches(xml))
    _AndroidNode({
      for (final a in RegExp(r'([\w:-]+)="([^"]*)"').allMatches(tag[1]!))
        a[1]!: _xmlUnescape(a[2]!),
    }),
];

/// The dialog in a `uiautomator dump` of the focused window, or null when
/// the window belongs to [app] or has no buttons. [taskPackages] are the
/// packages with an activity in the focused window's task (the requesting
/// app runs in the same task as its permission prompt).
SystemDialog? parseAndroidSystemDialog(
  String xml, {
  required SystemDialogApp? app,
  Set<String> taskPackages = const {},
}) {
  final nodes = _androidNodes(xml);
  if (nodes.isEmpty) return null;
  final source = nodes.first.attr('package');
  if (source.isEmpty || source == app?.id) return null;
  final foreign = [
    for (final n in nodes)
      if (n.attr('package') == source) n,
  ];
  final buttons = <SystemDialogButton>[];
  for (final node in foreign) {
    final rect = node.rect;
    final label = node.attr('text').trim().isNotEmpty
        ? node.attr('text').trim()
        : node.attr('content-desc').trim();
    final isButton =
        node.attr('class').endsWith('Button') ||
        node.resourceIdName.endsWith('_button');
    if (!isButton ||
        node.attr('clickable') != 'true' ||
        node.attr('enabled') == 'false' ||
        rect == null ||
        label.isEmpty) {
      continue;
    }
    final id = node.resourceIdName;
    buttons.add(
      SystemDialogButton(
        handle: androidPermissionButtonHandles[id] ?? systemButtonHandle(label),
        label: label,
        resourceId: id.isEmpty ? null : id,
        rect: rect,
      ),
    );
  }
  if (buttons.isEmpty) return null;
  String? textOf(bool Function(_AndroidNode) test) {
    for (final node in foreign) {
      if (test(node) && node.attr('text').trim().isNotEmpty) {
        return node.attr('text').trim();
      }
    }
    return null;
  }

  final buttonLabels = {for (final b in buttons) b.label};
  final permissionMessage = textOf(
    (n) => n.resourceIdName == 'permission_message',
  );
  final title =
      permissionMessage ??
      textOf((n) => n.resourceIdName == 'alertTitle') ??
      textOf(
        (n) =>
            n.attr('class').endsWith('TextView') &&
            !buttonLabels.contains(n.attr('text').trim()),
      );
  final message =
      textOf((n) => n.resourceIdName == 'detail_message') ??
      textOf((n) => n.resourceIdName == 'message' && n.attr('text') != title);
  final textEntry = foreign.any(
    (n) => n.attr('password') == 'true' || n.attr('class').endsWith('EditText'),
  );
  // The prompt runs in the requesting app's task; the session app among the
  // task's other packages proves ownership.
  final others = {...taskPackages}..remove(source);
  final String? owner;
  final String evidence;
  final bool? belongs;
  if (app != null && others.contains(app.id)) {
    (owner, evidence, belongs) = (app.id, 'activity_task', true);
  } else if (others.length == 1) {
    (owner, evidence, belongs) = (others.single, 'activity_task', false);
  } else {
    (owner, evidence, belongs) = (null, 'unknown', null);
  }
  return SystemDialog(
    platform: 'android',
    kind: _kind(
      textEntry: textEntry,
      texts: [title, message],
      permission: androidPermissionPackages.contains(source),
    ),
    source: source,
    title: title,
    message: message,
    buttons: _markAmbiguous(buttons),
    ownerName: owner,
    ownerEvidence: evidence,
    belongsToSessionApp: belongs,
    textEntry: textEntry,
  );
}

// -------------------------------------------------------------------- iOS --

/// The bundle id of the frontmost app scene in an AXe tree, from its
/// `card:<bundle id>:sceneID:...` element, or null.
String? iosFrontmostBundle(Object? tree) {
  String? found;
  void walk(Object? node) {
    if (found != null) return;
    if (node is List) {
      for (final child in node) {
        walk(child);
      }
      return;
    }
    if (node is! Map) return;
    final id = node['AXUniqueId'];
    if (id is String && id.startsWith('card:')) {
      final rest = id.substring(5);
      final end = rest.indexOf(':');
      found = end < 0 ? rest : rest.substring(0, end);
      return;
    }
    walk(node['children']);
  }

  walk(tree);
  return found;
}

/// The first system alert in an AXe `describe-ui` tree (decoded JSON), or
/// null. App content (the `card:` scene elements) is never a system dialog.
SystemDialog? parseIosSystemDialog(
  Object? tree, {
  required SystemDialogApp? app,
}) {
  Map? alert;
  void find(Object? node) {
    if (alert != null) return;
    if (node is List) {
      for (final child in node) {
        find(child);
      }
      return;
    }
    if (node is! Map) return;
    final id = node['AXUniqueId'];
    if (id is String && id.startsWith('card:')) return;
    final type = node['type'];
    final role = node['role'];
    if ((type == 'Sheet' ||
            type == 'Alert' ||
            type == 'Dialog' ||
            role == 'AXSheet' ||
            role == 'AXDialog' ||
            node['subrole'] == 'AXDialog') &&
        _iosDescendants(node).any((n) => n['type'] == 'Button')) {
      alert = node;
      return;
    }
    find(node['children']);
  }

  find(tree);
  final dialog = alert;
  if (dialog == null) return null;
  final descendants = _iosDescendants(dialog).toList();
  final texts = <String>[
    for (final n in descendants)
      if (n['type'] == 'StaticText' && _label(n) != null) _label(n)!,
  ];
  final buttons = <SystemDialogButton>[];
  for (final n in descendants) {
    final label = _label(n);
    final frame = n['frame'];
    if (n['type'] != 'Button' || label == null || frame is! Map) continue;
    if (n['enabled'] == false) continue;
    final rect = (
      x: (frame['x'] as num).toDouble(),
      y: (frame['y'] as num).toDouble(),
      width: (frame['width'] as num).toDouble(),
      height: (frame['height'] as num).toDouble(),
    );
    if (rect.width <= 0 || rect.height <= 0) continue;
    buttons.add(
      SystemDialogButton(
        handle: systemButtonHandle(label),
        label: label,
        rect: rect,
      ),
    );
  }
  if (buttons.isEmpty) return null;
  final title = _label(dialog) ?? (texts.isEmpty ? null : texts.first);
  final message = texts.where((t) => t != title).firstOrNull;
  final textEntry = descendants.any(
    (n) =>
        const {'TextField', 'SecureTextField', 'TextArea'}.contains(n['type']),
  );
  // Permission prompts quote the requesting app's display name:
  // “Huuk” would like to access the Camera. / Allow “Huuk” to use ...
  final quoted = title == null
      ? null
      : RegExp('[“"]([^”"]{1,128})[”"]').firstMatch(title)?[1];
  final bool? belongs = quoted == null || app == null
      ? null
      : app.names.contains(quoted);
  return SystemDialog(
    platform: 'ios',
    kind: _kind(
      textEntry: textEntry,
      texts: [title, message, for (final b in buttons) b.label],
      permission: quoted != null,
    ),
    source: 'SpringBoard',
    title: title,
    message: message,
    buttons: _markAmbiguous(buttons),
    ownerName: quoted,
    ownerEvidence: quoted == null ? 'unknown' : 'quoted_app_name',
    belongsToSessionApp: belongs,
    textEntry: textEntry,
  );
}

String? _label(Map node) {
  final label = node['AXLabel'];
  if (label is! String) return null;
  final trimmed = label.trim();
  return trimmed.isEmpty ? null : trimmed;
}

Iterable<Map> _iosDescendants(Map node) sync* {
  final children = node['children'];
  if (children is! List) return;
  for (final child in children) {
    if (child is! Map) continue;
    yield child;
    yield* _iosDescendants(child);
  }
}
