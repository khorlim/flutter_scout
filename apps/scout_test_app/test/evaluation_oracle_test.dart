import 'dart:async';
import 'dart:convert';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart'
    as evaluation;
import 'package:flutter_test/flutter_test.dart';
import 'package:scout_test_app/evaluation_oracle/public_fixture_configuration.dart';
import 'package:scout_test_app/evaluation_oracle/supplier_workflow_oracle.dart';

const String _capability = '0123456789abcdef0123456789abcdef';

void main() {
  test('oracle is disabled without evaluator build defines', () {
    installDebugSupplierWorkflowOracle();
    expect(debugSupplierWorkflowOracle, isNull);
  });

  test(
    'oracle rejects unauthenticated and malformed requests without state',
    () {
      final controller = SupplierWorkflowOracleController(
        capability: _capability,
        runtimeId: 'runtime-test',
      );

      expect(
        () => controller.handleState(const {'requestId': 'request-1'}),
        throwsA(
          isA<SupplierWorkflowOracleRequestException>()
              .having((error) => error.code, 'code', 'unauthorized')
              .having(
                (error) => error.toString(),
                'message',
                isNot(contains(_capability)),
              ),
        ),
      );
      expect(
        () => controller.handleState(const {
          'capability': _capability,
          'requestId': 'request-1',
          'unexpected': 'value',
        }),
        throwsA(
          isA<SupplierWorkflowOracleRequestException>().having(
            (error) => error.code,
            'code',
            'invalid_parameters',
          ),
        ),
      );
    },
  );

  test(
    'reset is fresh, closes the modal, and clears forbidden counters',
    () async {
      final controller = SupplierWorkflowOracleController(
        capability: _capability,
        runtimeId: 'runtime-test',
      );
      var resetCalls = 0;
      controller.attach(
        owner: controller,
        reset: (_) async {
          resetCalls++;
        },
      );
      controller
        ..recordModalOpened()
        ..recordSupplierAdded('Acme')
        ..recordSupplierAdded('Acme')
        ..recordForbiddenWrongAction();

      final before = await controller.handleState(const {
        'capability': _capability,
        'requestId': 'before',
      });
      final reset = await controller.handleReset(const {
        'capability': _capability,
        'requestId': 'reset-1',
      });

      expect(resetCalls, 1);
      expect(before['resetGeneration'], 0);
      expect(reset['operation'], 'reset');
      expect(reset['resetPerformed'], isTrue);
      expect(reset['resetGeneration'], 1);
      expect(reset['runtimeId'], before['runtimeId']);
      expect(reset['state'], {
        'modal': 'closed',
        'supplierAdditionCount': 0,
        'supplierNames': <String>[],
        'forbiddenDuplicateActionCount': 0,
        'forbiddenWrongActionCount': 0,
        'predicateResults': <String, bool>{},
      });
    },
  );

  test(
    'state records domain additions separately from forbidden actions',
    () async {
      final controller = SupplierWorkflowOracleController(
        capability: _capability,
        runtimeId: 'runtime-test',
      );
      controller.attach(owner: controller, reset: (_) async {});
      controller
        ..recordModalOpened()
        ..recordModalClosed()
        ..recordSupplierAdded('Benchmark Supplier')
        ..recordForbiddenDuplicateAction()
        ..recordForbiddenWrongAction();

      final response = await controller.handleState(const {
        'capability': _capability,
        'requestId': 'state-1',
      });

      expect(response.keys, {
        'schemaVersion',
        'channel',
        'operation',
        'requestId',
        'runtimeId',
        'workflowAttached',
        'resetGeneration',
        'state',
      });
      expect(response['state'], {
        'modal': 'closed',
        'supplierAdditionCount': 1,
        'supplierNames': <String>['Benchmark Supplier'],
        'forbiddenDuplicateActionCount': 1,
        'forbiddenWrongActionCount': 1,
        'predicateResults': <String, bool>{},
      });
    },
  );

  test(
    'authenticated reset selects a task and exposes private predicates',
    () async {
      final evaluatorFixture =
          evaluation.PublicFixtureConfiguration.fromManifest(
            const evaluation.PublicAuthoringCatalogGenerator()
                .generate()
                .catalog
                .publicDevelopment
                .first,
          );
      final controller = SupplierWorkflowOracleController(
        capability: _capability,
        runtimeId: 'runtime-test',
      );
      PublicFixtureConfiguration? selected;
      controller.attach(
        owner: controller,
        reset: (fixture) async => selected = fixture,
      );

      final reset = await controller.handleReset(<String, String>{
        'capability': _capability,
        'requestId': 'fixture-reset',
        'fixture': jsonEncode(evaluatorFixture.toJson()),
      });
      expect(selected?.taskId, evaluatorFixture.taskId);
      expect((reset['state']! as Map)['activeTaskId'], evaluatorFixture.taskId);
      expect(
        ((reset['state']! as Map)['predicateResults']!
            as Map)[evaluatorFixture.successPredicateId],
        isFalse,
      );

      controller.recordFixtureCompletion(evaluatorFixture.completionValue);
      final completed = await controller.handleState(const <String, String>{
        'capability': _capability,
        'requestId': 'fixture-state',
      });
      final state = completed['state']! as Map;
      expect(state['activeTaskId'], evaluatorFixture.taskId);
      expect(state['supplierAdditionCount'], 1);
      expect(
        (state['predicateResults']!
            as Map)[evaluatorFixture.successPredicateId],
        isTrue,
      );
      expect(
        (state['predicateResults']!
            as Map)[evaluatorFixture.forbiddenPredicateId],
        isFalse,
      );
    },
  );

  test('a concurrent reset fails closed', () async {
    final resetGate = Completer<void>();
    final controller = SupplierWorkflowOracleController(
      capability: _capability,
      runtimeId: 'runtime-test',
    );
    controller.attach(owner: controller, reset: (_) => resetGate.future);
    final first = controller.handleReset(const {
      'capability': _capability,
      'requestId': 'reset-1',
    });
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      controller.handleReset(const {
        'capability': _capability,
        'requestId': 'reset-2',
      }),
      throwsA(
        isA<SupplierWorkflowOracleRequestException>().having(
          (error) => error.code,
          'code',
          'reset_in_progress',
        ),
      ),
    );
    resetGate.complete();
    await first;
  });
}
