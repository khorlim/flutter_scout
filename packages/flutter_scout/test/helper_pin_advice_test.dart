import 'package:flutter_scout/flutter_scout.dart';
import 'package:test/test.dart';

String lock(String package, String body) =>
    'packages:\n  other:\n    dependency: transitive\n    source: hosted\n'
    '  $package:\n$body';

const appOld = 'd4dde80e6b381667b2be42cd89e9e1cfea4ec6a3';
const cliNew = '16700fb9b6a49b15b07e053a1e829e789faa6da6';

String gitBody(String ref) =>
    '    dependency: "direct main"\n    description:\n'
    '      path: "packages/flutter_scout_helper"\n      ref: $ref\n'
    '      resolved-ref: "$ref"\n'
    '      url: "https://github.com/khorlim/flutter_scout.git"\n'
    '    source: git\n    version: "0.2.0-dev.1"\n';

void main() {
  final cli = FlutterScoutCli();
  final installed = lock('flutter_scout', gitBody(cliNew));

  test('an app pinning an older helper is told where to bump it', () {
    final advice = cli.debugHelperPinAdvice(
      appLockText: lock('flutter_scout_helper', gitBody(appOld)),
      installedLockText: installed,
      appPubspecPath: '/app/apps/tunaipro/pubspec.yaml',
      isAncestor: (older, newer) => older == appOld && newer == cliNew,
    );
    expect(advice?['status'], 'app_helper_behind');
    expect(advice?['appHelperRef'], appOld);
    expect(advice?['installedScoutRef'], cliNew);
    expect(
      advice?['suggestion'],
      allOf(contains('/app/apps/tunaipro/pubspec.yaml'), contains(cliNew)),
    );
  });

  test('a matching pin, a path helper or an unknown CLI give no advice', () {
    expect(
      cli.debugHelperPinAdvice(
        appLockText: lock('flutter_scout_helper', gitBody(cliNew)),
        installedLockText: installed,
      ),
      isNull,
    );
    expect(
      cli.debugHelperPinAdvice(
        appLockText: lock(
          'flutter_scout_helper',
          '    dependency: "direct main"\n    description:\n'
              '      path: "../../packages/flutter_scout_helper"\n'
              '      relative: true\n    source: path\n',
        ),
        installedLockText: installed,
      ),
      isNull,
    );
    expect(
      cli.debugHelperPinAdvice(
        appLockText: lock('flutter_scout_helper', gitBody(appOld)),
        installedLockText: null,
      ),
      isNull,
    );
  });

  test('a newer CLI with an unchanged helper gives no advice', () {
    expect(
      cli.debugHelperPinAdvice(
        appLockText: lock('flutter_scout_helper', gitBody(appOld)),
        installedLockText: installed,
        isAncestor: (_, _) => true,
        helperChanged: (_, _) => false,
      ),
      isNull,
    );
  });

  test('without history the pins are reported as different', () {
    final advice = cli.debugHelperPinAdvice(
      appLockText: lock('flutter_scout_helper', gitBody(appOld)),
      installedLockText: installed,
    );
    expect(advice?['status'], 'differs');
  });
}
