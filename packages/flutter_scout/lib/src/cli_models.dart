part of 'flutter_scout_cli.dart';

// part: CLI value types (exception, discovery/validation/ready results, device + macOS window descriptors).

class ScoutCliException implements Exception {
  const ScoutCliException(this.code, this.message);

  final String code;
  final String message;
}

class _AttachDiscovery {
  const _AttachDiscovery({
    this.uri,
    this.reason,
    this.staleUri,
    this.staleCleared = false,
  });

  final String? uri;
  final String? reason;
  final String? staleUri;
  final bool staleCleared;
}

class _DiscoveredVmUri {
  const _DiscoveredVmUri({required this.uri, required this.source});

  final String uri;
  final String source;
}

class _VmUriValidation {
  const _VmUriValidation({required this.ok, this.error});

  final bool ok;
  final String? error;
}

class _ScoutReady {
  const _ScoutReady({
    required this.ready,
    this.reason,
    this.expected,
    this.detail,
  });

  final bool ready;
  final String? reason;
  final String? expected;
  final String? detail;
}

class _LaunchTiming {
  _LaunchTiming({required this.startedAt});

  final DateTime startedAt;
  DateTime? buildStartedAt;
  DateTime? buildDoneAt;
  DateTime? firstSyncAt;
  DateTime? vmServiceFoundAt;
  DateTime? readyAt;

  void observeLine(String line) {
    final lower = line.toLowerCase();
    final now = DateTime.now();
    if ((lower.contains('running xcode build') ||
            lower.contains('building ') ||
            lower.contains('gradle task')) &&
        buildStartedAt == null) {
      buildStartedAt = now;
    }
    if ((lower.contains('xcode build done') ||
            lower.contains('built build/') ||
            (lower.contains('gradle task') && lower.contains('done'))) &&
        buildDoneAt == null) {
      buildDoneAt = now;
    }
    if (lower.contains('syncing files to device') && firstSyncAt == null) {
      firstSyncAt = now;
    }
    if ((line.contains('[FLUTTER_SCOUT_VM_URI]') ||
            line.contains('Dart VM Service') ||
            line.contains('vmservice') ||
            line.contains('/ws')) &&
        vmServiceFoundAt == null) {
      vmServiceFoundAt = now;
    }
  }

  Map<String, Object?> toJson({DateTime? completedAt}) {
    final completed = completedAt ?? readyAt ?? DateTime.now();
    return {
      'totalMs': completed.difference(startedAt).inMilliseconds,
      if (buildStartedAt != null)
        'buildStartMs': buildStartedAt!.difference(startedAt).inMilliseconds,
      if (buildStartedAt != null && buildDoneAt != null)
        'buildDurationMs': buildDoneAt!
            .difference(buildStartedAt!)
            .inMilliseconds,
      if (buildDoneAt != null)
        'buildDoneMs': buildDoneAt!.difference(startedAt).inMilliseconds,
      if (firstSyncAt != null)
        'firstSyncMs': firstSyncAt!.difference(startedAt).inMilliseconds,
      if (vmServiceFoundAt != null)
        'vmServiceFoundMs': vmServiceFoundAt!
            .difference(startedAt)
            .inMilliseconds,
      if (readyAt != null)
        'readyMs': readyAt!.difference(startedAt).inMilliseconds,
    };
  }
}

class _FlutterDevice {
  const _FlutterDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.category,
    required this.emulator,
  });

  final String id;
  final String name;
  final String? platform;
  final String? category;
  final bool emulator;

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'platform': platform,
      'category': category,
      'emulator': emulator,
    };
  }
}

class _MacosWindowTarget {
  const _MacosWindowTarget({
    required this.windowId,
    required this.pid,
    required this.ownerName,
    required this.windowName,
    required this.bounds,
  });

  factory _MacosWindowTarget.fromJson(Map<String, dynamic> json) {
    return _MacosWindowTarget(
      windowId: (json['windowId'] as num).toInt(),
      pid: (json['pid'] as num).toInt(),
      ownerName: json['ownerName']?.toString() ?? '',
      windowName: json['windowName']?.toString(),
      bounds: json['bounds'] is List
          ? List<Object?>.from(json['bounds'] as List)
          : null,
    );
  }

  final int windowId;
  final int pid;
  final String ownerName;
  final String? windowName;
  final List<Object?>? bounds;
}
