import 'dart:convert';
import 'dart:io';

import 'package:flutter_scout/flutter_scout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'a stopped session with the same name in another project does not block',
    () async {
      final root = await Directory.systemTemp.createTemp('scout_stale_name_');
      addTearDown(() async {
        FlutterScoutCli.debugRegistryPathOverride = null;
        if (root.existsSync()) await root.delete(recursive: true);
      });
      Directory sessionIn(String project, String state) {
        final app = Directory(p.join(root.path, project))
          ..createSync(recursive: true);
        File(p.join(app.path, '.git')).writeAsStringSync('gitdir: test');
        final session = Directory(
          p.join(app.path, '.flutter_scout', 'sessions', 'main'),
        )..createSync(recursive: true);
        File(p.join(session.path, 'session_meta.json')).writeAsStringSync(
          jsonEncode({
            'name': 'main',
            'project': app.path,
            'runId': '$project-run',
            'state': state,
          }),
        );
        return session;
      }

      final stale = sessionIn('tunai_staff2', 'stopped');
      final fresh = sessionIn('tunai_pos', 'building');
      FlutterScoutCli.debugRegistryPathOverride = p.join(
        root.path,
        'registry.json',
      );
      File(
        FlutterScoutCli.debugRegistryPathOverride!,
      ).writeAsStringSync(jsonEncode({'main': stale.path}));

      final cli = FlutterScoutCli();
      cli.debugRegisterScoutSession(
        'main',
        fresh.path,
        project: p.join(root.path, 'tunai_pos'),
      );
      final registry =
          jsonDecode(
                File(
                  FlutterScoutCli.debugRegistryPathOverride!,
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(
        Directory(registry['main'] as String).resolveSymbolicLinksSync(),
        fresh.resolveSymbolicLinksSync(),
      );
    },
  );

  test(
    'a live session on the same project and device blocks a second launch',
    () async {
      final project = await Directory.systemTemp.createTemp('scout_in_use_');
      addTearDown(() => project.delete(recursive: true));
      final session = Directory(
        p.join(project.path, '.flutter_scout', 'sessions', 'styling'),
      )..createSync(recursive: true);
      File(p.join(session.path, 'session_meta.json')).writeAsStringSync(
        jsonEncode({
          'mode': 'scout_owned_flutter_run',
          'state': 'ready',
          'device': 'macos',
          'pid': pid, // this test process: alive
          'createdAt': DateTime.now().toIso8601String(),
        }),
      );
      final cli = FlutterScoutCli();
      await expectLater(
        cli.debugRequireProjectDeviceAvailable(
          project: project.path,
          device: 'macos',
        ),
        throwsA(
          isA<ScoutCliException>().having(
            (e) => e.code,
            'code',
            'project_in_use',
          ),
        ),
      );
      // Another device builds into separate output and is allowed.
      await cli.debugRequireProjectDeviceAvailable(
        project: project.path,
        device: 'emulator-5554',
      );
    },
  );
}
