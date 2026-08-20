import 'package:flutter_scout/flutter_scout.dart';
import 'package:test/test.dart';

void main() {
  test('every Flutter tool subprocess environment suppresses analytics', () {
    final environment = FlutterScoutCli().debugFlutterToolEnvironment(
      const <String, String>{
        'PATH': '/fixture/bin',
        'FLUTTER_SUPPRESS_ANALYTICS': 'false',
      },
    );

    expect(environment['PATH'], '/fixture/bin');
    expect(environment['FLUTTER_SUPPRESS_ANALYTICS'], 'true');
  });
}
