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
  test('unknown parameters list what the agent action accepts', () {
    expect(
      () => cli.debugValidateAgentAction({
        'method': 'scroll',
        'args': ['down'],
        'params': {'amount': 400},
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(
            startsWith('unknown_parameter: Parameter `amount`'),
            contains('Allowed parameters: distance, from, target, to, x, y.'),
            isNot(contains('allowErrors')),
            isNot(contains('verbose')),
          ),
        ),
      ),
    );
  });
  test('input cannot silently concatenate a mistaken field argument', () {
    expect(
      () => cli.debugValidateAgentAction({
        'method': 'input',
        'args': ['field.name', 'Actual value'],
      }),
      throwsFormatException,
    );
    expect(
      () => cli.debugValidateAgentAction({
        'method': 'input',
        'args': ['Actual value with spaces'],
        'params': {'target': 'field.name'},
      }),
      returnsNormally,
    );
  });
  test('an unknown action names the accepted ones and how to close', () {
    expect(
      () => cli.debugValidateAgentAction({
        'method': 'key',
        'args': ['escape'],
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(contains('dismiss'), contains('long-press'), contains('tap')),
        ),
      ),
    );
  });
  test('coordinates in args say they belong in params.x and params.y', () {
    expect(
      () => cli.debugValidateAgentAction({
        'method': 'tap',
        'args': [380, 215],
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('params.x and params.y'),
        ),
      ),
    );
    expect(
      () => cli.debugValidateAgentAction({
        'method': 'tap',
        'params': {'x': 380, 'y': 215, 'button': 'secondary'},
      }),
      returnsNormally,
    );
  });
}
