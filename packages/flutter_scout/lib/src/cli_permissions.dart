part of 'flutter_scout_cli.dart';

// `permissions`: grant, revoke or reset an app's runtime permissions on the
// iOS Simulator (`xcrun simctl privacy`) or an Android emulator (`adb shell
// pm grant|revoke`, `appops set`) so a run needs no prompt. Explicit only;
// Scout never changes permissions on its own.

/// `simctl privacy` services (Xcode 26). `camera` works although simctl's
/// help omits it (verified on Xcode 26.6, iOS 26.4). Notifications, App
/// Tracking Transparency and Bluetooth have no service: those prompts are
/// answered with `system-tap`.
const Set<String> iosSimctlPrivacyServices = {
  'all',
  'camera',
  'calendar',
  'contacts-limited',
  'contacts',
  'location',
  'location-always',
  'photos-add',
  'photos',
  'media-library',
  'microphone',
  'motion',
  'reminders',
  'siri',
};

/// Services with no simulator pre-grant, and what to do instead.
const Map<String, String> iosUnsupportedPermissionServices = {
  'notifications':
      'simctl privacy has no notifications service; answer the prompt with '
      'system-tap or ask the user',
  'tracking':
      'simctl privacy has no App Tracking Transparency service; answer the '
      'prompt with system-tap or ask the user',
  'bluetooth':
      'simctl privacy has no Bluetooth service; answer the prompt with '
      'system-tap or ask the user',
};

/// Android runtime permissions behind each service name.
const Map<String, List<String>> androidPermissionServices = {
  'camera': ['android.permission.CAMERA'],
  'microphone': ['android.permission.RECORD_AUDIO'],
  'location': [
    'android.permission.ACCESS_FINE_LOCATION',
    'android.permission.ACCESS_COARSE_LOCATION',
  ],
  'location-always': ['android.permission.ACCESS_BACKGROUND_LOCATION'],
  'contacts': [
    'android.permission.READ_CONTACTS',
    'android.permission.WRITE_CONTACTS',
  ],
  'calendar': [
    'android.permission.READ_CALENDAR',
    'android.permission.WRITE_CALENDAR',
  ],
  'photos': [
    'android.permission.READ_MEDIA_IMAGES',
    'android.permission.READ_MEDIA_VIDEO',
  ],
  'notifications': ['android.permission.POST_NOTIFICATIONS'],
  'bluetooth': [
    'android.permission.BLUETOOTH_CONNECT',
    'android.permission.BLUETOOTH_SCAN',
  ],
};

extension _CliPermissions on FlutterScoutCli {
  Future<int> _permissions(List<String> args) async {
    final parser = ArgParser()
      ..addOption('device')
      ..addOption('app-id')
      ..addFlag('allow-app-termination', negatable: false);
    final parsed = parser.parse(args);
    final rest = parsed.rest;
    const actions = {'grant', 'revoke', 'reset', 'list'};
    if (rest.isEmpty ||
        !actions.contains(rest.first) ||
        (rest.first == 'list') != (rest.length == 1)) {
      throw const ScoutCliException(
        'usage',
        'permissions grant|revoke|reset <service>... [--app-id <id>] '
            '[--device <id>] [--allow-app-termination], or permissions list.',
      );
    }
    final action = rest.first;
    final device = await _permissionsTarget(parsed.option('device'));
    final android = device.kind == _NativeMobilePlatform.androidEmulator;
    if (action == 'list') {
      _printJson({
        'ok': true,
        'platform': android ? 'android' : 'ios',
        'device': device.id,
        'mechanism': android ? 'adb_pm' : 'simctl_privacy',
        'services': android
            ? {
                for (final entry in androidPermissionServices.entries)
                  entry.key: entry.value,
                'android.permission.<NAME>': 'that runtime permission',
                'appop:<OP>': 'appops set <package> <OP> allow|deny|default',
              }
            : {
                for (final service in iosSimctlPrivacyServices)
                  service: 'simctl privacy',
              },
        if (!android) 'unsupported': iosUnsupportedPermissionServices,
      });
      return 0;
    }
    final services = rest.skip(1).toList();
    if (services.isEmpty || services.length > 16) {
      throw const ScoutCliException(
        'usage',
        'permissions needs 1..16 services (see `permissions list`).',
      );
    }
    for (final service in services) {
      final known = android
          ? androidPermissionServices.containsKey(service) ||
                RegExp(
                  r'^android\.permission\.[A-Z0-9_]{1,64}$',
                ).hasMatch(service) ||
                RegExp(r'^appop:[A-Z0-9_]{1,64}$').hasMatch(service)
          : iosSimctlPrivacyServices.contains(service);
      if (!known) {
        throw ScoutCliException(
          'permission_service_unsupported',
          android
              ? 'Unknown Android permission service `$service`.'
              : iosUnsupportedPermissionServices[service] != null
              ? 'iOS Simulator cannot pre-grant `$service`: '
                    '${iosUnsupportedPermissionServices[service]}.'
              : 'Unknown iOS Simulator privacy service `$service`.',
          details: {
            'service': service,
            'supported': android
                ? androidPermissionServices.keys.toList()
                : iosSimctlPrivacyServices.toList(),
            'nothingChanged': true,
          },
        );
      }
    }
    // The running session app, when there is one, decides the app id and
    // whether a change could terminate it.
    final probe = _SystemDialogProbe(this, vmPid: _sessionAppVmPid);
    final sessionApp = _readVmUri() == null || probe.target?.id != device.id
        ? null
        : await probe._sessionApp(device);
    final requested = parsed.option('app-id');
    final appId = requested ?? sessionApp?.id;
    if (appId == null ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$').hasMatch(appId)) {
      throw const ScoutCliException(
        'usage',
        'permissions needs the app: pass --app-id <bundle id or package>, '
            'or run it for a named session whose app is running.',
      );
    }
    final appRunning = sessionApp?.id == appId;
    // iOS may terminate the app for any change; Android kills it when a
    // runtime permission is revoked.
    final mayTerminate = !android || action != 'grant';
    if (appRunning && mayTerminate && !parsed.flag('allow-app-termination')) {
      throw ScoutCliException(
        'permission_change_may_terminate_app',
        '${android ? 'Android' : 'The iOS Simulator'} may terminate the '
            'running app for `permissions $action`, losing its state. Pass '
            '--allow-app-termination when that is intended, or make the '
            'change before the run.',
        details: {'appId': appId, 'nothingChanged': true},
      );
    }
    final results = <Map<String, Object?>>[];
    for (final service in services) {
      if (!android) {
        final run = await _runBoundedNativeProcess(
          'xcrun',
          ['simctl', 'privacy', device.id, action, service, appId],
          timeout: _nativeDeeplinkTimeout,
          maxStdoutBytes: _maxNativeToolTextBytes,
          maxStderrBytes: _maxNativeToolTextBytes,
        );
        results.add({
          'service': service,
          'ok': run.exitCode == 0 && !run.timedOut,
          if (run.exitCode != 0 || run.timedOut)
            'message': _firstLine(
              utf8.decode(run.stderrBytes, allowMalformed: true) +
                  run.stdoutText,
            ),
        });
        continue;
      }
      if (service.startsWith('appop:')) {
        final mode = const {
          'grant': 'allow',
          'revoke': 'deny',
          'reset': 'default',
        }[action]!;
        results.add({
          'service': service,
          ...await _adbPermissionStep(device, [
            'appops',
            'set',
            appId,
            service.substring(6),
            mode,
          ]),
        });
        continue;
      }
      final permissions =
          androidPermissionServices[service] ?? <String>[service];
      final items = <Map<String, Object?>>[];
      // `pm grant` of a permission the app does not declare exits 0 and
      // changes nothing (API 36), so read what the app requests first and
      // verify every change afterwards.
      final before = await _androidPermissionState(device, appId);
      for (final permission in permissions) {
        if (before != null && !before.requested.contains(permission)) {
          items.add({
            'permission': permission,
            'ok': false,
            'skipped': 'not_requested_by_app',
          });
          continue;
        }
        final step = await _adbPermissionStep(device, [
          'pm',
          action == 'grant' ? 'grant' : 'revoke',
          appId,
          permission,
        ]);
        if (step['ok'] == true && action == 'reset') {
          // Forget "don't ask again", so the next request prompts.
          step.addAll(
            await _adbPermissionStep(device, [
              'pm',
              'clear-permission-flags',
              appId,
              permission,
              'user-set',
              'user-fixed',
            ]),
          );
        }
        items.add({'permission': permission, ...step});
      }
      final after = await _androidPermissionState(device, appId);
      for (final item in items) {
        if (item['ok'] != true || after == null) continue;
        final granted = after.granted[item['permission']];
        final verified = granted == (action == 'grant');
        item['granted'] = granted;
        if (!verified) {
          item['ok'] = false;
          item['message'] =
              'the permission state did not change (granted: $granted)';
        }
      }
      final applied = items.where((item) => item['ok'] == true).length;
      final undeclared = items.where(
        (item) =>
            item['skipped'] == 'not_requested_by_app' ||
            '${item['message']}'.contains('has not requested'),
      );
      results.add({
        'service': service,
        // A service is applied when every permission the app declares was
        // changed; ones it does not declare are listed, not failures.
        'ok': applied > 0 && applied + undeclared.length == items.length,
        'permissions': items,
      });
    }
    final ok = results.every((result) => result['ok'] == true);
    final payload = <String, Object?>{
      'action': action,
      'platform': android ? 'android' : 'ios',
      'device': device.id,
      'appId': appId,
      'mechanism': android ? 'adb_pm' : 'simctl_privacy',
      'results': results,
      'appWasRunning': appRunning,
      if (appRunning && mayTerminate)
        'note':
            'The platform may have terminated the app. Check `status`; '
            'relaunch with ensure if it is gone.',
    };
    if (!ok) {
      throw ScoutCliException(
        'permission_change_incomplete',
        'Not every permission change took effect; read details.results. '
            'Nothing is retried. A permission the app does not declare in '
            'its manifest cannot be granted.',
        details: payload,
      );
    }
    _printJson({'ok': true, ...payload});
    return 0;
  }

  Future<Map<String, Object?>> _adbPermissionStep(
    _NativeMobileTarget device,
    List<String> command,
  ) async {
    final run = await _runBoundedNativeProcess(
      'adb',
      ['-s', device.id, 'shell', ...command],
      timeout: _nativeDeeplinkTimeout,
      maxStdoutBytes: _maxNativeToolTextBytes,
      maxStderrBytes: _maxNativeToolTextBytes,
    );
    final output =
        run.stdoutText + utf8.decode(run.stderrBytes, allowMalformed: true);
    // `pm` prints failures (often with exit 0 on older images).
    final failed =
        run.exitCode != 0 ||
        run.timedOut ||
        RegExp(r'Exception|Error|Unknown|not a changeable').hasMatch(output);
    return {'ok': !failed, if (failed) 'message': _firstLine(output)};
  }

  /// Requested permissions and runtime grant states of [appId], from
  /// `dumpsys package`; null when they cannot be read.
  Future<({Set<String> requested, Map<String, bool> granted})?>
  _androidPermissionState(_NativeMobileTarget device, String appId) async {
    final run = await _runBoundedNativeProcess(
      'adb',
      ['-s', device.id, 'shell', 'dumpsys', 'package', appId],
      timeout: _nativeDeeplinkTimeout,
      maxStdoutBytes: _maxSystemDialogToolBytes,
      maxStderrBytes: _maxNativeToolTextBytes,
    );
    if (run.exitCode != 0 || run.timedOut || run.outputExceeded) return null;
    return parseAndroidPackagePermissions(run.stdoutText);
  }

  /// The session's recorded emulator, or an explicit `--device` proven to be
  /// a booted iOS Simulator or an Android emulator.
  Future<_NativeMobileTarget> _permissionsTarget(String? explicit) async {
    if (explicit == null || explicit.isEmpty) {
      return _requireNativeMobileTarget(operation: 'permissions');
    }
    if (explicit.length > 256 ||
        explicit.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
      throw const ScoutCliException('usage', 'Invalid --device value.');
    }
    final simulator = await _runBoundedNativeProcess(
      'xcrun',
      ['simctl', 'getenv', explicit, 'SIMULATOR_UDID'],
      timeout: _nativePreflightTimeout,
      maxStdoutBytes: _maxNativeToolTextBytes,
      maxStderrBytes: _maxNativeToolTextBytes,
    );
    if (simulator.exitCode == 0 && simulator.stdoutText.trim() == explicit) {
      return _NativeMobileTarget(
        id: explicit,
        name: explicit,
        platform: 'ios',
        category: 'mobile',
        kind: _NativeMobilePlatform.iosSimulator,
      );
    }
    final emulator = await _runBoundedNativeProcess(
      'adb',
      // ro.kernel.qemu on older images, ro.boot.qemu on newer ones.
      ['-s', explicit, 'shell', 'getprop ro.kernel.qemu; getprop ro.boot.qemu'],
      timeout: _nativePreflightTimeout,
      maxStdoutBytes: _maxNativeToolTextBytes,
      maxStderrBytes: _maxNativeToolTextBytes,
    );
    if (emulator.exitCode == 0 &&
        emulator.stdoutText.split('\n').any((line) => line.trim() == '1')) {
      return _NativeMobileTarget(
        id: explicit,
        name: explicit,
        platform: 'android',
        category: 'mobile',
        kind: _NativeMobilePlatform.androidEmulator,
      );
    }
    throw ScoutCliException(
      'unsupported_capability',
      'permissions works only on a booted iOS Simulator or an Android '
          'emulator; `$explicit` is neither. Physical devices are not '
          'changed.',
      details: {'device': explicit, 'nothingChanged': true},
    );
  }
}

/// The `requested permissions:` list and the `<permission>: granted=<bool>`
/// states of one `dumpsys package <package>` output.
({Set<String> requested, Map<String, bool> granted})
parseAndroidPackagePermissions(String text) {
  final requested = <String>{};
  var inRequested = false;
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed == 'requested permissions:') {
      inRequested = true;
      continue;
    }
    if (inRequested) {
      final name = RegExp(r'^([A-Za-z0-9_.]+)(?::.*)?$').firstMatch(trimmed);
      if (name == null || trimmed.endsWith('permissions:')) {
        inRequested = false;
      } else {
        requested.add(name[1]!);
        continue;
      }
    }
  }
  final granted = <String, bool>{
    for (final match in RegExp(
      r'^\s*([A-Za-z0-9_.]+): granted=(true|false)',
      multiLine: true,
    ).allMatches(text))
      match[1]!: match[2] == 'true',
  };
  return (requested: requested, granted: granted);
}
