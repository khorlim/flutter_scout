import 'package:flutter_scout/flutter_scout.dart';
import 'package:test/test.dart';

void main() {
  final cli = FlutterScoutCli();
  test(
    'legacy args cannot smuggle waits or overrides into an agent action',
    () {
      for (final args in [
        ['btn.save', '--expect-text', 'Ready'],
        ['btn.save', '--allow-errors'],
        ['btn.save', '--wait-ms', '5000'],
        ['btn.save', '--capture'],
      ]) {
        expect(
          () => cli.debugValidateAgentAction({'method': 'tap', 'args': args}),
          throwsFormatException,
        );
      }
    },
  );
  test('agent forbids safety override params and extra authority fields', () {
    for (final action in <Map<String, dynamic>>[
      {
        'method': 'tap',
        'args': ['btn.save'],
        'params': {'allowErrors': true},
      },
      {
        'method': 'tap',
        'args': ['btn.save'],
        'app': 'different',
      },
      {
        'method': 'tap',
        'args': ['btn.save'],
        'idempotencyKey': 'repeat',
      },
      {
        'method': 'tap',
        'args': ['btn.save'],
        'params': {'waitMs': null},
      },
    ]) {
      expect(() => cli.debugValidateAgentAction(action), throwsFormatException);
    }
  });
  test('plain scoped actions retain their normal typed contract', () {
    expect(
      () => cli.debugValidateAgentAction({
        'method': 'tap',
        'args': ['btn.save'],
      }),
      returnsNormally,
    );
    expect(
      () => cli.debugValidateAgentAction({
        'method': 'input',
        'args': ['Test'],
        'params': {'target': 'field.name'},
      }),
      returnsNormally,
    );
  });
}
