import 'package:flutter_scout/flutter_scout.dart';
import 'package:test/test.dart';

void main() {
  final cli = FlutterScoutCli();

  const memoryPressure = '''
The system has 17179869184 (1048576 pages with a page size of 16384).
System-wide memory free percentage: 12%
''';
  const meminfo = '''
MemTotal:       16303428 kB
MemFree:          401234 kB
MemAvailable:    4075857 kB
''';

  test('reads macOS memory_pressure and Linux meminfo', () {
    expect(cli.debugParseHostMemory('memory_pressure', memoryPressure), {
      'freePercent': 12,
      'totalBytes': 17179869184,
      'source': 'memory_pressure',
      'lowThresholdPercent': 20,
    });
    expect(
      cli.debugParseHostMemory('proc_meminfo', meminfo),
      containsPair('freePercent', 25),
    );
    expect(cli.debugParseHostMemory('memory_pressure', 'garbage'), isNull);
    expect(cli.debugParseHostMemory('proc_meminfo', 'MemTotal: 0 kB'), isNull);
  });

  test('warns only below 20% free and names other live Scout runs', () {
    final warning = cli.debugLowMemoryWarning(
      'memory_pressure',
      memoryPressure,
      otherLiveRuns: 2,
    )!;
    expect(warning['code'], 'low_free_memory');
    expect(warning['freePercent'], 12);
    expect(warning['thresholdPercent'], 20);
    expect(warning['otherLiveScoutRuns'], 2);
    expect(warning['message'], contains('2 other Scout-owned runs are alive'));
    expect(warning['message'], contains('one app at a time'));
    expect(warning['message'], isNot(contains('\u2014')));

    String pressure(int free) => 'System-wide memory free percentage: $free%\n';
    expect(cli.debugLowMemoryWarning('memory_pressure', pressure(20)), isNull);
    expect(
      cli.debugLowMemoryWarning('memory_pressure', pressure(19)),
      containsPair('code', 'low_free_memory'),
    );
    expect(cli.debugLowMemoryWarning('proc_meminfo', meminfo), isNull);
  });
}
