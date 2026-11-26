part of 'flutter_scout_cli.dart';

// part: host free-memory facts and the low-memory warning on doctor, launch
// and ensure. Reads `memory_pressure -Q` on macOS and /proc/meminfo on
// Linux. Scout only warns: it never refuses a launch or stops a run because
// memory is low.

/// Below this share of free memory, doctor, launch and ensure warn. A 16 GB
/// Mac crashed twice with several simultaneous app runs.
const int _lowFreeMemoryPercent = 20;

class _HostMemory {
  const _HostMemory({
    required this.freePercent,
    required this.source,
    this.totalBytes,
  });

  final int freePercent;
  final int? totalBytes;
  final String source;

  Map<String, Object?> toJson() => {
    'freePercent': freePercent,
    'totalBytes': ?totalBytes,
    'source': source,
    'lowThresholdPercent': _lowFreeMemoryPercent,
  };
}

/// Parses `memory_pressure -Q`: "System-wide memory free percentage: 36%".
_HostMemory? _parseMemoryPressure(String output) {
  final percent = RegExp(
    r'System-wide memory free percentage:\s*(\d{1,3})%',
  ).firstMatch(output);
  final free = int.tryParse(percent?.group(1) ?? '');
  if (free == null || free > 100) return null;
  final total = RegExp(r'The system has (\d+) ').firstMatch(output);
  return _HostMemory(
    freePercent: free,
    totalBytes: int.tryParse(total?.group(1) ?? ''),
    source: 'memory_pressure',
  );
}

/// Parses /proc/meminfo: MemAvailable as a share of MemTotal (both in kB).
_HostMemory? _parseProcMeminfo(String text) {
  int? field(String name) => int.tryParse(
    RegExp(
          '^$name:\\s*(\\d+) kB',
          multiLine: true,
        ).firstMatch(text)?.group(1) ??
        '',
  );
  final total = field('MemTotal');
  final available = field('MemAvailable');
  if (total == null || total <= 0 || available == null) return null;
  return _HostMemory(
    freePercent: (available * 100 / total).floor().clamp(0, 100),
    totalBytes: total * 1024,
    source: 'proc_meminfo',
  );
}

/// The structured warning, or null when memory is not low or unknown.
Map<String, Object?>? _lowMemoryWarning(
  _HostMemory? memory, {
  required int? otherLiveRuns,
}) {
  if (memory == null || memory.freePercent >= _lowFreeMemoryPercent) {
    return null;
  }
  final others = otherLiveRuns == null || otherLiveRuns == 0
      ? ''
      : ' $otherLiveRuns other Scout-owned '
            '${otherLiveRuns == 1 ? 'run is' : 'runs are'} alive.';
  return {
    'code': 'low_free_memory',
    'message':
        'Only ${memory.freePercent}% of memory is free (warning below '
        '$_lowFreeMemoryPercent%).$others On a small machine (16 GB) run one '
        'app at a time: stop runs you no longer need before launching '
        'another. Scout does not stop anything for you.',
    'freePercent': memory.freePercent,
    'thresholdPercent': _lowFreeMemoryPercent,
    'totalBytes': ?memory.totalBytes,
    'otherLiveScoutRuns': ?otherLiveRuns,
    'source': memory.source,
  };
}

extension _CliHostMemory on FlutterScoutCli {
  Future<_HostMemory?> _readHostMemory() async {
    try {
      final override = FlutterScoutCli.debugHostMemorySource;
      if (override != null) {
        final raw = await override();
        if (raw == null) return null;
        return raw.source == 'proc_meminfo'
            ? _parseProcMeminfo(raw.text)
            : _parseMemoryPressure(raw.text);
      }
      if (Platform.isMacOS) {
        final result = await Process.run('/usr/bin/memory_pressure', [
          '-Q',
        ]).timeout(const Duration(seconds: 5));
        return result.exitCode == 0
            ? _parseMemoryPressure('${result.stdout}')
            : null;
      }
      if (Platform.isLinux) {
        return _parseProcMeminfo(await File('/proc/meminfo').readAsString());
      }
    } on Object {
      // A missing tool or unreadable file only means the fact is unknown.
    }
    return null;
  }

  /// Other registered named sessions whose owned process is alive. Only
  /// current records are checked, one `ps` each.
  Future<int> _otherLiveScoutRuns() async {
    var count = 0;
    for (final directory in _readScoutRegistry().values) {
      if (!Directory(directory).existsSync() ||
          _sameSessionDirectory(directory, _sessionDir.path) ||
          !_namedSessionIsCurrent(directory)) {
        continue;
      }
      if ((await _namedSessionSummary(directory))['live'] == true) count++;
    }
    return count;
  }

  /// Host memory facts and, when free memory is low, a warning that is also
  /// written once to stderr as a `low_free_memory` progress record.
  Future<({Map<String, Object?>? memory, Map<String, Object?>? warning})>
  _checkHostMemory() async {
    final memory = await _readHostMemory();
    if (memory == null) return (memory: null, warning: null);
    final warning = _lowMemoryWarning(
      memory,
      otherLiveRuns: memory.freePercent < _lowFreeMemoryPercent
          ? await _otherLiveScoutRuns()
          : null,
    );
    if (warning != null) _writeProgress('low_free_memory', warning);
    return (memory: memory.toJson(), warning: warning);
  }

  /// Runs the check once per launch or ensure command; the warning joins
  /// that command's final envelope (see [_writeCliResponse]).
  Future<void> _checkHostMemoryForLaunch() async {
    final commandId = _activeCommandId;
    if (commandId != null && _hostMemoryCheckedFor == commandId) return;
    _hostMemoryCheckedFor = commandId;
    _launchWarnings.clear();
    final warning = (await _checkHostMemory()).warning;
    if (warning != null) _launchWarnings.add(warning);
  }
}

extension FlutterScoutCliHostMemoryTesting on FlutterScoutCli {
  Map<String, Object?>? debugParseHostMemory(String source, String text) =>
      (source == 'proc_meminfo'
              ? _parseProcMeminfo(text)
              : _parseMemoryPressure(text))
          ?.toJson();

  Map<String, Object?>? debugLowMemoryWarning(
    String source,
    String text, {
    int? otherLiveRuns,
  }) => _lowMemoryWarning(
    source == 'proc_meminfo'
        ? _parseProcMeminfo(text)
        : _parseMemoryPressure(text),
    otherLiveRuns: otherLiveRuns,
  );
}
