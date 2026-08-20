import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const Set<String> _networkPrimitives = <String>{
  'HttpClient(',
  'HttpServer.bind(',
  'Image.network(',
  'NetworkImage(',
  'RawSocket.connect(',
  'ServerSocket.bind(',
  'Socket.connect(',
  'WebSocket.connect(',
  'vmServiceConnectUri(',
};

const Set<String> _localDestinations = <String>{
  'loopback_client',
  'loopback_fault_fixture',
  'loopback_listener',
  'loopback_vm_service',
};

const List<String> _forbiddenProductionImports = <String>[
  "package:amplitude_",
  "package:appcenter_",
  "package:datadog_",
  "package:dio/",
  "package:firebase_analytics/",
  "package:grpc/",
  "package:http/",
  "package:mixpanel_",
  "package:posthog_",
  "package:sentry_",
  "package:telemetry/",
];

void main() {
  test('production network access is default-deny and loopback-only', () {
    final repository = Directory.current.parent;
    final policyFile = File(
      '${repository.path}/security/network_egress_policy.v1.json',
    );
    final decoded = jsonDecode(policyFile.readAsStringSync());
    expect(decoded, isA<Map<Object?, Object?>>());
    final policy = Map<String, Object?>.from(decoded as Map);

    expect(policy.keys.toSet(), <String>{
      'schemaVersion',
      'policy',
      'telemetry',
      'scannedRoots',
      'allowedConnections',
    });
    expect(policy['schemaVersion'], 1);
    expect(policy['policy'], 'default_deny');
    expect(policy['telemetry'], <String, Object?>{
      'implemented': false,
      'optInRequired': true,
    });

    final scannedRoots = _strictStringList(policy['scannedRoots']);
    expect(scannedRoots, isNotEmpty);
    final sourceFiles = <File>[];
    for (final relativeRoot in scannedRoots) {
      final root = Directory('${repository.path}/$relativeRoot');
      expect(root.existsSync(), isTrue, reason: relativeRoot);
      sourceFiles.addAll(
        root
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart')),
      );
    }
    sourceFiles.sort((left, right) => left.path.compareTo(right.path));

    final allowed = <({String path, String primitive}), _Allowance>{};
    final rawAllowed = policy['allowedConnections'];
    expect(rawAllowed, isA<List<Object?>>());
    for (final rawEntry in rawAllowed! as List<Object?>) {
      expect(rawEntry, isA<Map<Object?, Object?>>());
      final entry = Map<String, Object?>.from(rawEntry! as Map);
      expect(entry.keys.toSet(), <String>{
        'path',
        'primitive',
        'occurrences',
        'destination',
        'purpose',
        'requiredEvidence',
      });
      final path = _strictString(entry['path'], 'path');
      final primitive = _strictString(entry['primitive'], 'primitive');
      final occurrences = entry['occurrences'];
      final destination = _strictString(entry['destination'], 'destination');
      final purpose = _strictString(entry['purpose'], 'purpose');
      final requiredEvidence = _strictStringList(entry['requiredEvidence']);
      expect(_networkPrimitives, contains(primitive));
      expect(occurrences, isA<int>());
      expect(occurrences as int, greaterThan(0));
      expect(_localDestinations, contains(destination));
      expect(purpose, isNotEmpty);
      expect(requiredEvidence, isNotEmpty);
      final key = (path: path, primitive: primitive);
      expect(allowed, isNot(contains(key)), reason: 'duplicate $key');
      allowed[key] = _Allowance(
        occurrences: occurrences,
        requiredEvidence: requiredEvidence,
      );
    }

    final observed = <({String path, String primitive}), int>{};
    for (final file in sourceFiles) {
      final relativePath = _relativePath(repository, file);
      final source = file.readAsStringSync();
      for (final forbidden in _forbiddenProductionImports) {
        expect(
          source,
          isNot(contains(forbidden)),
          reason: 'unapproved network/telemetry dependency in $relativePath',
        );
      }
      for (final primitive in _networkPrimitives) {
        final count = RegExp(
          '(?<![A-Za-z0-9_])${RegExp.escape(primitive)}',
        ).allMatches(source).length;
        if (count == 0) continue;
        final key = (path: relativePath, primitive: primitive);
        expect(
          allowed,
          contains(key),
          reason: 'unreviewed network primitive $primitive in $relativePath',
        );
        observed[key] = count;
      }
    }

    expect(observed.keys.toSet(), allowed.keys.toSet());
    for (final entry in allowed.entries) {
      expect(
        observed[entry.key],
        entry.value.occurrences,
        reason: 'network occurrence drift for ${entry.key}',
      );
      final source = File(
        '${repository.path}/${entry.key.path}',
      ).readAsStringSync();
      for (final evidence in entry.value.requiredEvidence) {
        expect(
          source,
          contains(evidence),
          reason: 'missing local-only evidence for ${entry.key}',
        );
      }
    }
  });
}

final class _Allowance {
  const _Allowance({required this.occurrences, required this.requiredEvidence});

  final int occurrences;
  final List<String> requiredEvidence;
}

String _strictString(Object? value, String field) {
  if (value is! String || value.isEmpty || value.trim() != value) {
    throw FormatException('$field must be a non-empty trimmed string');
  }
  return value;
}

List<String> _strictStringList(Object? value) {
  if (value is! List || value.isEmpty || value.any((item) => item is! String)) {
    throw const FormatException('Expected a non-empty string list');
  }
  final result = value.cast<String>();
  if (result.any((item) => item.isEmpty || item.trim() != item) ||
      result.toSet().length != result.length) {
    throw const FormatException('String lists must be trimmed and unique');
  }
  return List<String>.unmodifiable(result);
}

String _relativePath(Directory repository, File file) {
  final prefix = '${repository.absolute.path}${Platform.pathSeparator}';
  final absolute = file.absolute.path;
  if (!absolute.startsWith(prefix)) {
    throw StateError('Scanned file escaped repository: $absolute');
  }
  return absolute.substring(prefix.length).replaceAll('\\', '/');
}
