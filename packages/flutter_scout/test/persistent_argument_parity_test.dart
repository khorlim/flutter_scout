import 'package:flutter_scout/flutter_scout.dart';
import 'package:test/test.dart';

void main() {
  final cli = FlutterScoutCli();

  group('persistent CLI argument parity', () {
    test('normalizes coordinate shorthand while preserving explicit gates', () {
      for (final args in <List<String>>[
        ['tap', '110', '127'],
        [
          'tap',
          '--expect-text',
          '110',
          '110',
          '--expect-timeout=1000',
          '127',
          '--wait-ms',
          '250',
          '--verbose',
        ],
        ['tap', '110.5', '127.25', '--expect-text', 'Saved'],
      ]) {
        final result = cli.debugValidatePersistentCliArguments(args);
        expect(result['valid'], isTrue, reason: args.toString());
        expect(result['positionalCount'], 0);
        expect(result['parameterNames'], containsAll(['x', 'y']));
        if (args.contains('--expect-text')) {
          expect(result['parameterNames'], contains('expectText'));
        }
        if (args.contains('--verbose')) {
          expect(
            result['parameterNames'],
            containsAll(['expectTimeout', 'waitMs', 'verbose']),
          );
        }
      }
    });

    test('preserves handle and explicit coordinate forms', () {
      final handle = cli.debugValidatePersistentCliArguments([
        'tap',
        'btn.save',
        '--expect-text',
        'Saved',
      ]);
      expect(handle['valid'], isTrue);
      expect(handle['positionalCount'], 1);
      expect(handle['parameterNames'], ['expectText']);
      expect(
        cli.debugValidatePersistentCliArguments([
          'tap',
          '--x',
          '110',
          '--y',
          '127',
        ])['valid'],
        isTrue,
      );
    });

    test('never relaxes ambiguity, nonfinite values, or typed API shape', () {
      for (final args in <List<String>>[
        ['tap', 'btn.save', '127'],
        ['tap', '110', '127', '140'],
        ['tap', '110', '127', '--x', '1', '--y', '2'],
        ['tap', 'NaN', '127'],
        ['tap', 'Infinity', '127'],
      ]) {
        final result = cli.debugValidatePersistentCliArguments(args);
        expect(result['valid'], isFalse, reason: args.toString());
        expect(result['handlerEntered'], isFalse);
      }
      expect(
        cli.debugValidatePersistentTypedCall({
          'method': 'tap',
          'args': ['110', '127'],
        })['valid'],
        isFalse,
      );
      expect(
        cli.debugValidatePersistentTypedCall({
          'method': 'tap',
          'params': {'x': '110', 'y': '127'},
        })['valid'],
        isFalse,
      );
    });

    test(
      'leaves malformed options to typed validation, not transport retry',
      () {
        for (final args in <List<String>>[
          ['tap', '110', '127', '--unsupported'],
          ['tap', '110', '127', '--expect-text'],
        ]) {
          final result = cli.debugValidatePersistentCliArguments(args);
          expect(result['valid'], isFalse);
          expect(result['handlerEntered'], isFalse);
        }
      },
    );

    test('parses integer options and explains their existing bounds', () {
      for (final count in [1, 12, 20, 100]) {
        expect(
          cli.debugValidatePersistentCliArguments([
            'inspect',
            '--sections',
            'textTargets,controlGroups',
            '--max-items',
            '$count',
          ])['valid'],
          isTrue,
        );
      }
      for (final count in ['0', '120', '12.5']) {
        final result = cli.debugValidatePersistentCliArguments([
          'inspect',
          '--max-items=$count',
        ]);
        expect(result['valid'], isFalse);
        expect(result['errorCode'], 'invalid_parameter_value');
        expect(result['message'], contains('minimum 1, maximum 100'));
        expect(result['handlerEntered'], isFalse);
      }
      expect(
        cli.debugValidatePersistentTypedCall({
          'method': 'inspect',
          'params': {'maxItems': '12'},
        })['valid'],
        isFalse,
      );
    });
  });
}
