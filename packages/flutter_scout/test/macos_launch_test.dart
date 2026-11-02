import 'package:flutter_scout/flutter_scout.dart';
import 'package:test/test.dart';

void main() {
  final cli = FlutterScoutCli();

  test('macOS devices use LaunchServices unless direct run is requested', () {
    bool decide(String device, {Map<String, String> env = const {}}) =>
        cli.debugShouldLaunchMacosAppThroughLaunchServices(
          isMacOS: true,
          deviceId: device,
          environment: env,
        );
    expect(decide('macos'), isTrue);
    expect(
      decide('macos', env: {'FLUTTER_SCOUT_MACOS_DIRECT_RUN': '1'}),
      isFalse,
    );
    expect(decide('emulator-5554'), isFalse);
    expect(
      cli.debugShouldLaunchMacosAppThroughLaunchServices(
        isMacOS: false,
        deviceId: 'macos',
        environment: const {},
      ),
      isFalse,
    );
  });

  test('run argv splits into build, attach and engine switches', () {
    final plan = cli.debugMacosLaunchPlan([
      'run',
      '-d',
      'macos',
      '--enable-impeller',
      '--target',
      'lib/main_dev.dart',
      '--flavor',
      'dev',
      '--dart-define-from-file',
      '/private/defines.json',
      '--dart-define',
      'FLUTTER_SCOUT_RUN_ID=run-1',
      '--verbose',
      '--pid-file',
      '/private/run/flutter_tool.pid',
    ]);
    expect(plan['buildArgs'], [
      'build',
      'macos',
      '--debug',
      '--target',
      'lib/main_dev.dart',
      '--flavor',
      'dev',
      '--dart-define-from-file',
      '/private/defines.json',
      '--dart-define',
      'FLUTTER_SCOUT_RUN_ID=run-1',
      '--verbose',
    ]);
    // attach takes no flavor; the run ID define keeps the owned-tool
    // identity check valid for the attached tool.
    expect(plan['attachArgs'], [
      'attach',
      '-d',
      'macos',
      '--target',
      'lib/main_dev.dart',
      '--dart-define-from-file',
      '/private/defines.json',
      '--dart-define',
      'FLUTTER_SCOUT_RUN_ID=run-1',
      '--verbose',
      '--debug-url',
      '<uri>',
      '--pid-file',
      '/private/run/flutter_tool.pid',
    ]);
    expect(plan['openEnvironmentArgs'], [
      '--env',
      'FLUTTER_ENGINE_SWITCHES=4',
      '--env',
      'FLUTTER_ENGINE_SWITCH_1=enable-dart-profiling=true',
      '--env',
      'FLUTTER_ENGINE_SWITCH_2=enable-checked-mode=true',
      '--env',
      'FLUTTER_ENGINE_SWITCH_3=verify-entry-points=true',
      '--env',
      'FLUTTER_ENGINE_SWITCH_4=enable-impeller=true',
    ]);
  });

  test('unknown run options fail closed instead of being dropped', () {
    expect(
      () => cli.debugMacosLaunchPlan([
        'run',
        '-d',
        'macos',
        '--release',
        '--pid-file',
        '/p',
      ]),
      throwsA(isA<ScoutCliException>()),
    );
  });

  test('built app path and app VM-service redaction', () {
    expect(
      cli.debugBuiltMacosAppPath(
        '\u001b[32m✓\u001b[0m Built build/macos/Build/Products/Debug/My App.app',
        project: '/work/app',
      ),
      '/work/app/build/macos/Build/Products/Debug/My App.app',
    );
    expect(
      cli.debugBuiltMacosAppPath(
        '✓ Built build/macos/Build/Products/Debug-dev/a.app (12.3MB)',
        project: '/w',
      ),
      '/w/build/macos/Build/Products/Debug-dev/a.app',
    );
    expect(
      cli.debugBuiltMacosAppPath(
        'Building macOS application...',
        project: '/w',
      ),
      isNull,
    );
    expect(
      cli.debugRedactMacosAppVmServiceLine(
        'flutter: The Dart VM service is listening on http://127.0.0.1:5123/abc=/',
      ),
      'flutter: The Dart VM service is listening on <app-vm-service>',
    );
  });
}
