import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';

void main() {
  test(
    'conformance ledger is exhaustive by section and never claims a pass',
    () {
      final matrix =
          jsonDecode(File('conformance_matrix.v1.json').readAsStringSync())
              as Map<String, Object?>;
      final entries = matrix['entries']! as List<Object?>;
      final ids = <String>{};
      final markdown = File('CONFORMANCE_MATRIX.md').readAsStringSync();
      final markdownRows = _markdownRows(markdown);
      expect(entries.length, greaterThanOrEqualTo(60));
      for (final raw in entries) {
        final entry = raw! as Map<String, Object?>;
        final id = entry['id']! as String;
        expect(ids.add(id), isTrue, reason: 'duplicate matrix id $id');
        final markdownRow = markdownRows[id];
        expect(markdownRow, isNotNull, reason: 'missing Markdown row $id');
        expect(const {
          'implemented_proof',
          'partial_proof',
          'unmeasured',
        }, contains(entry['status']));
        expect(entry['status'], isNot(anyOf('pass', 'met', 'conformant')));
        expect((entry['requirements']! as List<Object?>), isNotEmpty);
        expect(
          (entry['source']! as String),
          startsWith('QUALITY_STANDARD.md:'),
        );
        expect(
          markdownRow!.status,
          entry['status'],
          reason: '$id status differs between JSON and Markdown',
        );
        expect(
          markdownRow.proof,
          unorderedEquals((entry['proof']! as List<Object?>).cast<String>()),
          reason: '$id proof differs between JSON and Markdown',
        );
      }
      for (var section = 1; section <= 18; section++) {
        expect(
          ids.any((id) => id.startsWith('QS-$section')),
          isTrue,
          reason: 'QUALITY_STANDARD section $section is not mapped',
        );
      }
      expect(ids.where((id) => id.startsWith('QS-14.1-')), hasLength(10));
      for (final id in const <String>[
        'QS-13.2',
        'QS-13.3-SPLITS',
        'QS-14.2-ROBUSTNESS-DROP',
        'QS-14.2-PERFORMANCE',
        'QS-16.1',
        'QS-16.4',
        'QS-18.2',
      ]) {
        final entry = entries.cast<Map<String, Object?>>().singleWhere(
          (candidate) => candidate['id'] == id,
        );
        expect(
          entry['status'],
          id.startsWith('QS-13.3') || id == 'QS-13.2'
              ? 'partial_proof'
              : 'unmeasured',
          reason: '$id must not overclaim required missing evidence',
        );
      }
    },
  );

  test('proof registry is complete, concrete, and internally consistent', () {
    final matrix =
        jsonDecode(File('conformance_matrix.v1.json').readAsStringSync())
            as Map<String, Object?>;
    final references = matrix['proofReferences']! as Map<String, Object?>;
    final entries = matrix['entries']! as List<Object?>;
    final markdown = File('CONFORMANCE_MATRIX.md').readAsStringSync();
    expect(
      references.keys,
      containsAll(const <String>[
        'P-CLI-PROTOCOL',
        'P-HELPER-PROTOCOL',
        'P-IDEMPOTENCY',
        'P-PERCEPTION',
        'P-RESOLUTION',
        'P-NAVIGATION',
        'P-STABILITY-SIGNALS',
        'P-LIFECYCLE',
        'P-STORAGE',
        'P-TEMP-RECOVERY',
        'P-NONINTERFERENCE',
        'P-PERFORMANCE',
        'P-PRIVACY',
        'P-PROTOCOL-ARTIFACTS',
        'P-DEBUG-BUILD',
        'P-RELEASE',
        'P-RELEASE-SUPPLY-CHAIN',
        'P-CI',
        'P-TOOL-SIM',
      ]),
    );
    for (final reference in references.entries) {
      expect(markdown, contains('`${reference.key}`'));
      final rawPaths = reference.value! as List<Object?>;
      final seenPaths = <String>{};
      expect(rawPaths, isNotEmpty);
      for (final rawPath in rawPaths) {
        final path = rawPath! as String;
        expect(
          seenPaths.add(path),
          isTrue,
          reason: '${reference.key} repeats $path',
        );
        expect(File(path).existsSync(), isTrue, reason: path);
      }
    }
    for (final raw in entries) {
      final entry = raw! as Map<String, Object?>;
      final status = entry['status']! as String;
      final proof = (entry['proof']! as List<Object?>).cast<String>();
      expect(
        proof,
        status == 'unmeasured' ? isEmpty : isNotEmpty,
        reason: '${entry['id']} has status $status',
      );
      final evidencePaths = <String>[];
      for (final rawProof in proof) {
        expect(
          references,
          contains(rawProof),
          reason: '${entry['id']} uses unknown proof key $rawProof',
        );
        evidencePaths.addAll(
          (references[rawProof]! as List<Object?>).cast<String>(),
        );
      }
      if (status == 'implemented_proof') {
        expect(
          evidencePaths.any(_isDeterministicEvidence),
          isTrue,
          reason:
              '${entry['id']} claims implementation without a deterministic '
              'test or machine artifact',
        );
      }
    }
  });

  test(
    'ledger is bound to the exact standard and source ranges stay scoped',
    () {
      final matrix =
          jsonDecode(File('conformance_matrix.v1.json').readAsStringSync())
              as Map<String, Object?>;
      final standard = File(matrix['standard']! as String);
      final standardBytes = standard.readAsBytesSync();
      expect(
        crypto.sha256.convert(standardBytes).toString(),
        matrix['standardSha256'],
        reason:
            'QUALITY_STANDARD.md changed without a conformance-ledger audit',
      );

      final lines = standard.readAsLinesSync();
      final sectionStarts = <int, int>{};
      final heading = RegExp(r'^## (\d+)\.');
      for (var index = 0; index < lines.length; index += 1) {
        final match = heading.firstMatch(lines[index]);
        if (match != null)
          sectionStarts[int.parse(match.group(1)!)] = index + 1;
      }
      final entries = (matrix['entries']! as List<Object?>)
          .cast<Map<String, Object?>>();
      final sourcePattern = RegExp(r'^QUALITY_STANDARD\.md:(\d+)(?:-(\d+))?$');
      final idPattern = RegExp(r'^QS-(\d+)');
      for (final entry in entries) {
        final id = entry['id']! as String;
        final source = entry['source']! as String;
        final sourceMatch = sourcePattern.firstMatch(source);
        expect(
          sourceMatch,
          isNotNull,
          reason: '$id has malformed source $source',
        );
        final start = int.parse(sourceMatch!.group(1)!);
        final end = int.parse(sourceMatch.group(2) ?? sourceMatch.group(1)!);
        expect(start, inInclusiveRange(1, lines.length), reason: id);
        expect(end, inInclusiveRange(start, lines.length), reason: id);
        if (id == 'QS-NORTH-1') continue;
        final section = int.parse(idPattern.firstMatch(id)!.group(1)!);
        final sectionStart = sectionStarts[section]!;
        final nextSectionStart =
            sectionStarts[section + 1] ?? (lines.length + 1);
        expect(
          start,
          greaterThanOrEqualTo(sectionStart),
          reason: '$id: $source',
        );
        expect(end, lessThan(nextSectionStart), reason: '$id: $source');
      }
    },
  );
}

bool _isDeterministicEvidence(String path) =>
    path.endsWith('_test.dart') ||
    path.endsWith('.schema.json') ||
    path.endsWith('.json') ||
    path.endsWith('.yml');

Map<String, _MarkdownRow> _markdownRows(String markdown) {
  final rows = <String, _MarkdownRow>{};
  for (final line in const LineSplitter().convert(markdown)) {
    if (!line.startsWith('| `QS-')) continue;
    final cells = line.split('|').map((cell) => cell.trim()).toList();
    final idMatch = RegExp(r'^`([^`]+)`').firstMatch(cells[1]);
    if (idMatch == null) continue;
    final id = idMatch.group(1)!;
    final rawStatus = cells[3];
    final status = switch (rawStatus) {
      'partial' => 'partial_proof',
      'unmeasured' => 'unmeasured',
      _ when rawStatus.startsWith('implemented') => 'implemented_proof',
      _ => rawStatus,
    };
    final proof = cells[4] == '—'
        ? const <String>[]
        : cells[4].split(',').map((key) => key.trim()).toList();
    expect(rows.containsKey(id), isFalse, reason: 'duplicate Markdown row $id');
    rows[id] = _MarkdownRow(status: status, proof: proof);
  }
  return rows;
}

class _MarkdownRow {
  const _MarkdownRow({required this.status, required this.proof});

  final String status;
  final List<String> proof;
}
