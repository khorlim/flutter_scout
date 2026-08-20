import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout_evaluation/flutter_scout_evaluation.dart';
import 'package:test/test.dart';

void main() {
  test('tool-simulator schemas are strict version-one JSON documents', () {
    for (final path in const <String>[
      'schemas/v1/tool_simulator_plan.schema.json',
      'schemas/v1/supplier_oracle_observation.schema.json',
    ]) {
      final schema = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(schema[r'$schema'], contains('2020-12'));
      expect(schema[r'$id'], contains('/v1/'));
      expect(schema['additionalProperties'], isFalse);
      expect((schema['properties'] as Map)['schemaVersion'], {'const': 1});
    }
    expect(toolSimulatorPlanSchemaVersion, 1);
    expect(supplierOracleObservationSchemaVersion, 1);
  });

  test('checked-in public Supplier manifest and plan parse exactly', () {
    final manifest = TaskManifest.fromJson(
      jsonDecode(
        File(
          'tool_simulator/fixtures/supplier_add_manifest.v1.json',
        ).readAsStringSync(),
      ),
    );
    final plan = ToolSimulatorPlan.fromJson(
      jsonDecode(
        File(
          'tool_simulator/fixtures/supplier_add_plan.v1.json',
        ).readAsStringSync(),
      ),
    );

    expect(manifest.split, BenchmarkSplit.publicDevelopment);
    expect(manifest.hiddenHarness.oracleId, supplierWorkflowOracleId);
    expect(plan.actions, hasLength(3));
    expect(
      ToolSimulatorPlan.fromJson(
        jsonDecode(jsonEncode(plan.toJson())),
      ).toJson(),
      plan.toJson(),
    );
  });

  test('plan rejects commands outside the bounded Scout-only surface', () {
    expect(
      () => ToolSimulatorAction(const <String>[
        supplierWorkflowOracleStateMethod,
      ]),
      throwsArgumentError,
    );
    expect(
      () => ToolSimulatorAction(const <String>['stop', '--clear-session']),
      throwsArgumentError,
    );
  });

  test('runner exposes only protected VM URI ingress', () async {
    final process = await Process.run(Platform.resolvedExecutable, <String>[
      'run',
      'bin/run_tool_simulator_episode.dart',
      '--help',
    ]);

    expect(process.exitCode, 0, reason: process.stderr.toString());
    final help = process.stdout.toString();
    expect(help, contains('--vm-uri-file OWNER_ONLY_URI'));
    expect(help, isNot(contains('--vm-uri URI')));
  });
}
