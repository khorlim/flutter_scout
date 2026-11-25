part of 'flutter_scout_cli.dart';

// Durable, privacy-preserving exactly-once receipts.
//
// The helper is the final in-runtime deduplication boundary. This journal is
// the cross-process boundary: it is committed before a mutation can be sent,
// so a CLI crash, HTTP disconnect, or a new CLI process can only reconcile the
// original invocation. It never stores business parameters or an
// idempotency-key value. Only SHA-256 fingerprints, exact protocol identity,
// and a source-redacted bounded outcome are retained.

const int _idempotencyRegistrySchemaVersion = 1;
const int _maxIdempotencyReceipts = 512;
const int _maxReplayableIdempotencyOutcomes = 64;
const int _maxIdempotencyRegistryBytes = 16 * 1024 * 1024;
const int _maxStoredIdempotencyOutcomeBytes = 128 * 1024;
// 2^20 bits keeps a long session's false-positive refusals negligible: about
// one in 40,000 fresh keys after 20,000 compacted receipts. The original
// 2^16-bit filter refused about one fresh key in 300 after 5,000 receipts, and
// a refused fresh key halts an agent hand as an unknown outcome.
const int _idempotencyTombstoneFilterBitCount = 1 << 20;
const int _legacyIdempotencyTombstoneFilterBitCount = 1 << 16;
const int _idempotencyTombstoneFilterHashCount = 4;
const int _idempotencyTombstoneFilterByteCount =
    _idempotencyTombstoneFilterBitCount ~/ 8;

/// Receipt phase for a closed mutation whose dispatch status is known but
/// whose outcome exceeded the stored-outcome bound. It is never replayed or
/// redispatched, and it is safe to compact into the tombstone filter.
const String _nonreplayableReceiptPhase = 'committed_nonreplayable';
const String _outcomeStorageLimitReason = 'bounded_outcome_storage_limit';

final Expando<_CliIdempotencyContext> _cliIdempotencyContexts =
    Expando<_CliIdempotencyContext>('flutter_scout_cli_idempotency');

class _CliIdempotencyContext {
  String? callerKey;
  bool generatedByScout = false;
}

class _IdempotencyExtraction {
  const _IdempotencyExtraction({required this.args, required this.key});

  final List<String> args;
  final String? key;
}

class _DurableInvocationDecision {
  const _DurableInvocationDecision({
    this.invocation,
    this.replay,
    this.failure,
  });

  final _MutationInvocation? invocation;
  final Map<String, dynamic>? replay;
  final Map<String, dynamic>? failure;
}

class _DurableOutcomeCommit {
  const _DurableOutcomeCommit({required this.outcome, this.failure});

  final Map<String, dynamic> outcome;
  final Map<String, dynamic>? failure;
}

class _PreTransportIdempotencyDecision {
  const _PreTransportIdempotencyDecision({
    this.immediate,
    this.uncertainInvocation,
  });

  final Map<String, dynamic>? immediate;
  final _MutationInvocation? uncertainInvocation;
}

/// Compact no-false-negative memory for receipts removed from the exact
/// registry. A false positive only abstains with `idempotency_outcome_pruned`;
/// a false negative would be unsafe because it could redispatch a mutation.
class _IdempotencyTombstoneFilter {
  _IdempotencyTombstoneFilter([Uint8List? bytes])
    : _bytes = bytes ?? Uint8List(_idempotencyTombstoneFilterByteCount) {
    if (_bytes.length != _idempotencyTombstoneFilterByteCount) {
      throw const ScoutCliException(
        'idempotency_registry_corrupt',
        'The durable idempotency tombstone filter has an invalid size. Scout '
            'will not dispatch a mutation.',
      );
    }
  }

  final Uint8List _bytes;

  Iterable<int> _positions(String keyDigest) sync* {
    final digest = crypto.sha256.convert(utf8.encode(keyDigest)).bytes;
    for (
      var offset = 0;
      offset < _idempotencyTombstoneFilterHashCount;
      offset++
    ) {
      final value =
          (digest[offset * 4] << 24) |
          (digest[offset * 4 + 1] << 16) |
          (digest[offset * 4 + 2] << 8) |
          digest[offset * 4 + 3];
      yield value & (_idempotencyTombstoneFilterBitCount - 1);
    }
  }

  void add(String keyDigest) {
    for (final position in _positions(keyDigest)) {
      final byte = position ~/ 8;
      _bytes[byte] |= 1 << (position % 8);
    }
  }

  bool mightContain(String keyDigest) {
    for (final position in _positions(keyDigest)) {
      final byte = position ~/ 8;
      if ((_bytes[byte] & (1 << (position % 8))) == 0) return false;
    }
    return true;
  }

  String encode() => base64UrlEncode(_bytes);

  /// A position is the same 32-bit hash value masked to the bit count, so a
  /// key's large-filter position is congruent to its legacy position modulo
  /// the legacy size. Copying the legacy bits into every congruent slot keeps
  /// every remembered key (no false negative) when an older registry is read.
  static Uint8List _upscaleLegacyFilter(Uint8List legacy) {
    final upscaled = Uint8List(_idempotencyTombstoneFilterByteCount);
    for (var offset = 0; offset < upscaled.length; offset += legacy.length) {
      upscaled.setRange(offset, offset + legacy.length, legacy);
    }
    return upscaled;
  }

  static _IdempotencyTombstoneFilter decode(Object? encoded) {
    if (encoded == null) return _IdempotencyTombstoneFilter();
    if (encoded is! String || encoded.isEmpty) {
      throw const ScoutCliException(
        'idempotency_registry_corrupt',
        'The durable idempotency tombstone filter is invalid. Scout will not '
            'dispatch a mutation.',
      );
    }
    try {
      final bytes = base64Url.decode(encoded);
      if (bytes.length == _legacyIdempotencyTombstoneFilterBitCount ~/ 8) {
        return _IdempotencyTombstoneFilter(_upscaleLegacyFilter(bytes));
      }
      return _IdempotencyTombstoneFilter(bytes);
    } on FormatException {
      throw const ScoutCliException(
        'idempotency_registry_corrupt',
        'The durable idempotency tombstone filter is not valid base64. Scout '
            'will not dispatch a mutation.',
      );
    }
  }
}

extension _CliIdempotency on FlutterScoutCli {
  _CliIdempotencyContext get _idempotencyContext =>
      _cliIdempotencyContexts[this] ??= _CliIdempotencyContext();

  String? get _activeCallerIdempotencyKey => _idempotencyContext.callerKey;

  set _activeCallerIdempotencyKey(String? value) {
    _idempotencyContext
      ..callerKey = value
      ..generatedByScout = false;
  }

  bool get _activeIdempotencyKeyWasGenerated =>
      _idempotencyContext.generatedByScout;

  void _adoptGeneratedIdempotencyKey(String key) {
    _idempotencyContext
      ..callerKey = _validateCallerIdempotencyKey(key)
      ..generatedByScout = true;
  }

  _IdempotencyExtraction _extractIdempotencyKey(List<String> input) {
    final args = <String>[];
    String? key;
    for (var index = 0; index < input.length; index++) {
      final value = input[index];
      String? candidate;
      if (value == '--idempotency-key') {
        if (index + 1 >= input.length) {
          throw const ScoutCliException(
            'missing_idempotency_key',
            '`--idempotency-key` requires a value.',
          );
        }
        candidate = input[++index];
      } else if (value.startsWith('--idempotency-key=')) {
        candidate = value.substring('--idempotency-key='.length);
      } else {
        args.add(value);
        continue;
      }
      if (key != null) {
        throw const ScoutCliException(
          'duplicate_idempotency_key',
          'Supply `--idempotency-key` at most once.',
        );
      }
      key = _validateCallerIdempotencyKey(candidate);
    }
    return _IdempotencyExtraction(
      args: List<String>.unmodifiable(args),
      key: key,
    );
  }

  String _validateCallerIdempotencyKey(String raw) {
    final key = raw.trim();
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(key)) {
      throw const ScoutCliException(
        'invalid_idempotency_key',
        'Idempotency keys must contain 1-128 ASCII letters, digits, `.`, '
            '`_`, `:`, or `-`, and must start with a letter or digit.',
      );
    }
    return key;
  }

  String _derivedStepIdempotencyKey({
    required String scope,
    required int step,
    required Object? businessRequest,
  }) {
    final digest = _sha256Canonical(<String, Object?>{
      'scope': scope,
      'step': step,
      'request': businessRequest,
    });
    return 'step-${step + 1}-${digest.substring(0, 48)}';
  }

  Future<T> _withCallerIdempotencyKey<T>(
    String key,
    Future<T> Function() body,
  ) async {
    final previous = _activeCallerIdempotencyKey;
    final previousWasGenerated = _activeIdempotencyKeyWasGenerated;
    _activeCallerIdempotencyKey = _validateCallerIdempotencyKey(key);
    try {
      return await body();
    } finally {
      _activeCallerIdempotencyKey = previous;
      if (previous != null && previousWasGenerated) {
        _adoptGeneratedIdempotencyKey(previous);
      }
    }
  }

  String _mutationBusinessFingerprint({
    required String method,
    required String runId,
    required Map<String, String> params,
  }) => _sha256Canonical(<String, Object?>{
    'extension': method,
    'method': method,
    'runId': runId,
    'params': params,
  });

  _PreTransportIdempotencyDecision? _inspectReceiptBeforeTransport({
    required String method,
    required Map<String, String> businessParams,
  }) {
    final key = _activeCallerIdempotencyKey;
    final runId = _currentRunIdFromSession();
    if (key == null || runId == null || runId.isEmpty) return null;
    final keyDigest = _idempotencyKeyDigest(key);
    final fingerprint = _mutationBusinessFingerprint(
      method: method,
      runId: runId,
      params: businessParams,
    );
    try {
      final registryFile = File(_idempotencyRegistryPath);
      if (!registryFile.existsSync()) return null;
      _ensurePrivateDirectory(
        _idempotencyDirectory.path,
        boundary: _sessionDir.path,
      );
      return _withPrivateFileLock<_PreTransportIdempotencyDecision?>(
        _idempotencyRegistryLockPath,
        boundary: _sessionDir.path,
        body: () {
          final registry = _readIdempotencyRegistry();
          final records = registry['records']! as Map<String, Object?>;
          final tombstoneFilter = _readIdempotencyTombstoneFilter(registry);
          final rawReceipt = records[keyDigest];
          if (rawReceipt is! Map) {
            if (!tombstoneFilter.mightContain(keyDigest)) return null;
            return _PreTransportIdempotencyDecision(
              immediate: _idempotencyUnknownWithoutInvocation(
                code: 'idempotency_outcome_pruned',
                message:
                    'The bounded outcome was pruned. Scout will not redispatch.',
                method: method,
                runId: runId,
                idempotencyKey: key,
                idempotencyKeyDigest: keyDigest,
              ),
            );
          }
          final receipt = Map<String, Object?>.from(rawReceipt);
          if (receipt['businessFingerprint'] != fingerprint) {
            return _PreTransportIdempotencyDecision(
              immediate: _notDispatchedProtocolFailure(
                code: 'idempotency_conflict',
                message:
                    'This idempotency key was already reserved for a different business request. Nothing was dispatched.',
                method: method,
                runId: runId,
                details: <String, Object?>{
                  'idempotencyKeyDigest': keyDigest,
                  'storedBusinessFingerprint': receipt['businessFingerprint'],
                  'receivedBusinessFingerprint': fingerprint,
                },
              ),
            );
          }
          final stored = _invocationFromReceiptIdentity(
            receipt,
            key: key,
            keyDigest: keyDigest,
            businessFingerprint: fingerprint,
            businessParams: businessParams,
            callerSupplied: !_activeIdempotencyKeyWasGenerated,
          );
          final phase = receipt['phase']?.toString();
          if (phase == 'completed') {
            final outcome = receipt['outcome'];
            if (outcome is! Map ||
                receipt['outcomeDigest'] != _sha256Canonical(outcome)) {
              return _PreTransportIdempotencyDecision(
                immediate: stored == null
                    ? _idempotencyUnknownWithoutInvocation(
                        code: 'idempotency_outcome_corrupt',
                        message:
                            'The durable mutation outcome failed integrity validation. Scout will not redispatch.',
                        method: method,
                        runId: runId,
                        idempotencyKey: key,
                        idempotencyKeyDigest: keyDigest,
                      )
                    : _unknownDispatchProtocolFailure(
                        code: 'idempotency_outcome_corrupt',
                        message:
                            'The durable mutation outcome failed integrity validation. Scout will not redispatch.',
                        invocation: stored,
                      ),
              );
            }
            final restoredOutcome = _restoreBusinessValuesFromReceipt(
              outcome,
              businessParams,
            );
            if (restoredOutcome is! Map) {
              return _PreTransportIdempotencyDecision(
                immediate: _idempotencyUnknownWithoutInvocation(
                  code: 'idempotency_outcome_corrupt',
                  message:
                      'The durable mutation outcome could not be reconstructed. Scout will not redispatch.',
                  method: method,
                  runId: runId,
                  idempotencyKey: key,
                  idempotencyKeyDigest: keyDigest,
                ),
              );
            }
            final invocation = receipt['invocation'];
            return _PreTransportIdempotencyDecision(
              immediate: <String, dynamic>{
                for (final entry in restoredOutcome.entries)
                  entry.key.toString(): entry.value,
                'idempotencyKey': key,
                'idempotencyKeyDigest': keyDigest,
                'idempotency': <String, Object?>{
                  'status': 'replayed',
                  'durability': 'cross_process_receipt',
                  'keySource': _activeIdempotencyKeyWasGenerated
                      ? 'generated'
                      : 'caller',
                  'businessFingerprint': fingerprint,
                  'idempotencyKeyDigest': keyDigest,
                  if (invocation is Map)
                    'originalCommandId': invocation['commandId'],
                },
              },
            );
          }
          if (_receiptDispatchKnownWithoutOutcome(receipt)) {
            return _PreTransportIdempotencyDecision(
              immediate: _idempotencyOutcomeNotStored(
                receipt,
                invocation: stored,
                method: method,
                runId: runId,
                idempotencyKey: key,
                idempotencyKeyDigest: keyDigest,
                businessFingerprint: fingerprint,
                keySource: _activeIdempotencyKeyWasGenerated
                    ? 'generated'
                    : 'caller',
              ),
            );
          }
          if (phase == 'reserved' || phase == 'outcome_unknown') {
            return stored == null
                ? _PreTransportIdempotencyDecision(
                    immediate: _idempotencyUnknownWithoutInvocation(
                      code: 'idempotency_receipt_corrupt',
                      message:
                          'A possibly dispatched receipt has incomplete invocation identity. Scout will not redispatch.',
                      method: method,
                      runId: runId,
                      idempotencyKey: key,
                      idempotencyKeyDigest: keyDigest,
                    ),
                  )
                : _PreTransportIdempotencyDecision(uncertainInvocation: stored);
          }
          if (phase == 'tombstone') {
            return _PreTransportIdempotencyDecision(
              immediate: stored == null
                  ? _idempotencyUnknownWithoutInvocation(
                      code: 'idempotency_outcome_pruned',
                      message:
                          'The bounded outcome was pruned and its invocation identity is unavailable. Scout will not redispatch.',
                      method: method,
                      runId: runId,
                      idempotencyKey: key,
                      idempotencyKeyDigest: keyDigest,
                    )
                  : _unknownDispatchProtocolFailure(
                      code: 'idempotency_outcome_pruned',
                      message:
                          'The bounded outcome was pruned. Scout will not redispatch.',
                      invocation: stored,
                      details: <String, Object?>{
                        'outcomeDigest': receipt['outcomeDigest'],
                        'prunedAt': receipt['prunedAt'],
                      },
                    ),
            );
          }
          return _PreTransportIdempotencyDecision(
            immediate: _idempotencyUnknownWithoutInvocation(
              code: 'idempotency_receipt_corrupt',
              message:
                  'The durable receipt has an unknown phase. Scout will not redispatch.',
              method: method,
              runId: runId,
              idempotencyKey: key,
              idempotencyKeyDigest: keyDigest,
            ),
          );
        },
      );
    } catch (error) {
      return _PreTransportIdempotencyDecision(
        immediate: _idempotencyUnknownWithoutInvocation(
          code: 'idempotency_registry_integrity_unknown',
          message:
              'The durable receipt registry could not be validated. Scout will not risk redispatching a prior mutation.',
          method: method,
          runId: runId,
          idempotencyKey: key,
          idempotencyKeyDigest: keyDigest,
          details: <String, Object?>{
            'cause': error is ScoutCliException
                ? error.code
                : error.runtimeType.toString(),
          },
        ),
      );
    }
  }

  String _idempotencyKeyDigest(String key) =>
      crypto.sha256.convert(utf8.encode(key)).toString();

  String _sha256Canonical(Object? value) => crypto.sha256
      .convert(utf8.encode(jsonEncode(_canonicalIdempotencyValue(value))))
      .toString();

  Object? _canonicalIdempotencyValue(Object? value) {
    if (value is Map) {
      final entries = <MapEntry<String, Object?>>[
        for (final entry in value.entries)
          MapEntry(
            entry.key.toString(),
            _canonicalIdempotencyValue(entry.value),
          ),
      ]..sort((first, second) => first.key.compareTo(second.key));
      return <String, Object?>{
        for (final entry in entries) entry.key: entry.value,
      };
    }
    if (value is Iterable) {
      return <Object?>[
        for (final item in value) _canonicalIdempotencyValue(item),
      ];
    }
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    return value.toString();
  }

  Directory get _idempotencyDirectory =>
      Directory(p.join(_sessionDir.path, 'idempotency'));

  String get _idempotencyRegistryPath =>
      p.join(_idempotencyDirectory.path, 'registry.json');

  String get _idempotencyRegistryLockPath =>
      p.join(_idempotencyDirectory.path, 'registry.lock');

  Map<String, Object?> _emptyIdempotencyRegistry() => <String, Object?>{
    'schemaVersion': _idempotencyRegistrySchemaVersion,
    'records': <String, Object?>{},
    'dataClassification': _privateApplicationData,
    'containsRawBusinessParameters': false,
    'containsRawIdempotencyKeys': false,
    'telemetryCollected': false,
  };

  Map<String, Object?> _readIdempotencyRegistry() {
    final path = _idempotencyRegistryPath;
    _assertPrivateFilePath(path, boundary: _sessionDir.path);
    final file = File(path);
    if (!file.existsSync()) return _emptyIdempotencyRegistry();
    _securePrivateFile(path, boundary: _sessionDir.path);
    final length = file.lengthSync();
    if (length <= 0 || length > _maxIdempotencyRegistryBytes) {
      throw const ScoutCliException(
        'idempotency_registry_corrupt',
        'The durable idempotency registry is empty or exceeds its hard bound. '
            'Scout will not dispatch a mutation.',
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } catch (_) {
      throw const ScoutCliException(
        'idempotency_registry_corrupt',
        'The durable idempotency registry is not valid JSON. Scout will not '
            'dispatch a mutation.',
      );
    }
    if (decoded is! Map ||
        decoded['schemaVersion'] != _idempotencyRegistrySchemaVersion ||
        decoded['records'] is! Map) {
      throw const ScoutCliException(
        'idempotency_registry_corrupt',
        'The durable idempotency registry has an incompatible shape. Scout '
            'will not dispatch a mutation.',
      );
    }
    _IdempotencyTombstoneFilter.decode(decoded['tombstoneFilter']);
    final records = <String, Object?>{};
    for (final entry in (decoded['records'] as Map).entries) {
      final digest = entry.key.toString();
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) || entry.value is! Map) {
        throw const ScoutCliException(
          'idempotency_registry_corrupt',
          'The durable idempotency registry contains an invalid receipt. '
              'Scout will not dispatch a mutation.',
        );
      }
      records[digest] = <String, Object?>{
        for (final item in (entry.value as Map).entries)
          item.key.toString(): item.value,
      };
    }
    if (records.length > _maxIdempotencyReceipts) {
      throw const ScoutCliException(
        'idempotency_registry_corrupt',
        'The durable idempotency registry exceeds its receipt bound. Scout '
            'will not dispatch a mutation.',
      );
    }
    return <String, Object?>{
      for (final entry in decoded.entries) entry.key.toString(): entry.value,
      'records': records,
    };
  }

  _IdempotencyTombstoneFilter _readIdempotencyTombstoneFilter(
    Map<String, Object?> registry,
  ) => _IdempotencyTombstoneFilter.decode(registry['tombstoneFilter']);

  void _writeIdempotencyRegistry(Map<String, Object?> registry) {
    // Compact JSON: the bound then holds by construction, since stored
    // outcomes are measured with the same encoding and at most
    // 64 of them keep their outcome.
    final encoded = jsonEncode(registry);
    if (utf8.encode(encoded).length > _maxIdempotencyRegistryBytes) {
      throw ScoutCliException(
        'idempotency_registry_capacity_reached',
        'The durable idempotency registry reached its hard byte bound. Scout '
            'will not dispatch a new mutation. $_idempotencyCapacityNextStep',
      );
    }
    _atomicWritePrivateString(
      _idempotencyRegistryPath,
      encoded,
      boundary: _sessionDir.path,
    );
  }

  _DurableInvocationDecision _reserveDurableMutationInvocation({
    required _MutationInvocation proposed,
    required String method,
    required Map<String, String> businessParams,
  }) {
    _ensurePrivateDirectory(
      _idempotencyDirectory.path,
      boundary: _sessionDir.path,
    );
    return _withPrivateFileLock<_DurableInvocationDecision>(
      _idempotencyRegistryLockPath,
      boundary: _sessionDir.path,
      body: () {
        final registry = _readIdempotencyRegistry();
        final records = registry['records']! as Map<String, Object?>;
        final tombstoneFilter = _readIdempotencyTombstoneFilter(registry);
        final existingValue = records[proposed.idempotencyKeyDigest];
        if (existingValue is Map) {
          final existing = Map<String, Object?>.from(existingValue);
          if (existing['businessFingerprint'] != proposed.businessFingerprint) {
            return _DurableInvocationDecision(
              failure: _notDispatchedProtocolFailure(
                code: 'idempotency_conflict',
                message:
                    'This idempotency key was already reserved for a different business request. Nothing was dispatched.',
                method: method,
                runId: proposed.runId,
                details: <String, Object?>{
                  'idempotencyKeyDigest': proposed.idempotencyKeyDigest,
                  'storedBusinessFingerprint': existing['businessFingerprint'],
                  'receivedBusinessFingerprint': proposed.businessFingerprint,
                },
              ),
            );
          }
          final stored = _invocationFromReceipt(
            existing,
            key: proposed.idempotencyKey,
            businessParams: businessParams,
            fallback: proposed,
          );
          if (stored == null) {
            return _DurableInvocationDecision(
              failure: _unknownDispatchProtocolFailure(
                code: 'idempotency_receipt_corrupt',
                message:
                    'A durable receipt exists for this key, but its exact invocation identity is incomplete. Scout will not redispatch.',
                invocation: proposed,
                details: <String, Object?>{
                  'idempotencyKeyDigest': proposed.idempotencyKeyDigest,
                },
              ),
            );
          }
          final phase = existing['phase']?.toString();
          if (phase == 'completed') {
            final outcome = existing['outcome'];
            if (outcome is Map &&
                existing['outcomeDigest'] == _sha256Canonical(outcome)) {
              final restoredOutcome = _restoreBusinessValuesFromReceipt(
                outcome,
                businessParams,
              );
              if (restoredOutcome is! Map) {
                return _DurableInvocationDecision(
                  failure: _unknownDispatchProtocolFailure(
                    code: 'idempotency_outcome_corrupt',
                    message:
                        'The durable outcome could not be reconstructed from the matching business request. Scout will not redispatch.',
                    invocation: stored,
                  ),
                );
              }
              return _DurableInvocationDecision(
                replay: <String, dynamic>{
                  for (final entry in restoredOutcome.entries)
                    entry.key.toString(): entry.value,
                  'idempotencyKey': proposed.idempotencyKey,
                  'idempotencyKeyDigest': proposed.idempotencyKeyDigest,
                  'idempotency': <String, Object?>{
                    'status': 'replayed',
                    'durability': 'cross_process_receipt',
                    'keySource': proposed.callerSuppliedIdempotencyKey
                        ? 'caller'
                        : 'generated',
                    'businessFingerprint': proposed.businessFingerprint,
                    'idempotencyKeyDigest': proposed.idempotencyKeyDigest,
                    'originalCommandId': stored.commandId,
                  },
                },
              );
            }
            return _DurableInvocationDecision(
              failure: _unknownDispatchProtocolFailure(
                code: 'idempotency_outcome_corrupt',
                message:
                    'The durable outcome for this idempotency key failed integrity validation. Scout will not redispatch.',
                invocation: stored,
              ),
            );
          }
          if (phase == 'tombstone') {
            return _DurableInvocationDecision(
              failure: _unknownDispatchProtocolFailure(
                code: 'idempotency_outcome_pruned',
                message:
                    'The original mutation receipt is retained, but its bounded replay outcome was pruned. Scout will not redispatch.',
                invocation: stored,
                details: <String, Object?>{
                  'outcomeDigest': existing['outcomeDigest'],
                  'prunedAt': existing['prunedAt'],
                },
              ),
            );
          }
          if (_receiptDispatchKnownWithoutOutcome(existing)) {
            return _DurableInvocationDecision(
              failure: _idempotencyOutcomeNotStored(
                existing,
                invocation: stored,
                method: method,
                runId: proposed.runId,
                idempotencyKey: proposed.idempotencyKey,
                idempotencyKeyDigest: proposed.idempotencyKeyDigest,
                businessFingerprint: proposed.businessFingerprint,
                keySource: proposed.callerSuppliedIdempotencyKey
                    ? 'caller'
                    : 'generated',
              ),
            );
          }
          if (stored.runtimeInstanceId != proposed.runtimeInstanceId) {
            return _DurableInvocationDecision(
              failure: _unknownDispatchProtocolFailure(
                code: 'idempotency_runtime_replaced',
                message:
                    'The original mutation outcome is uncertain and the helper runtime was replaced. Scout cannot safely redispatch it.',
                invocation: stored,
                details: <String, Object?>{
                  'currentRuntimeInstanceId': proposed.runtimeInstanceId,
                  'receiptRuntimeInstanceId': stored.runtimeInstanceId,
                },
              ),
            );
          }
          // Same runtime + exact business fingerprint: send the exact original
          // envelope. The helper either replays its record or rejects the
          // expired pre-dispatch deadline; no new mutation identity exists.
          return _DurableInvocationDecision(invocation: stored);
        }

        if (tombstoneFilter.mightContain(proposed.idempotencyKeyDigest)) {
          return _DurableInvocationDecision(
            failure: _unknownDispatchProtocolFailure(
              code: 'idempotency_outcome_pruned',
              message:
                  'The bounded outcome was pruned. Scout will not redispatch.',
              invocation: proposed,
            ),
          );
        }

        if (records.length >= _maxIdempotencyReceipts) {
          final compacted = _compactIdempotencyReceipts(
            records,
            tombstoneFilter,
          );
          if (compacted) {
            registry['tombstoneFilter'] = tombstoneFilter.encode();
          }
        }
        if (records.length >= _maxIdempotencyReceipts) {
          // Only receipts whose dispatch is still unknown remain: forgetting
          // one could let its retry dispatch the same input twice.
          return _DurableInvocationDecision(
            failure: _notDispatchedProtocolFailure(
              code: 'idempotency_registry_capacity_reached',
              message:
                  'Nothing was dispatched. All $_maxIdempotencyReceipts '
                  'durable receipts in this session are inputs whose dispatch '
                  'outcome is still unknown, and Scout will not forget one '
                  'because its retry could dispatch the same input twice. '
                  '$_idempotencyCapacityNextStep',
              method: method,
              runId: proposed.runId,
              details: <String, Object?>{
                'receipts': records.length,
                'maxReceipts': _maxIdempotencyReceipts,
                'unresolvedReceipts': records.values
                    .where(
                      (receipt) =>
                          receipt is Map &&
                          !_receiptIsCompactable(
                            Map<String, Object?>.from(receipt),
                          ),
                    )
                    .length,
                'nextStep': _idempotencyCapacityNextStep,
              },
            ),
          );
        }
        final now = DateTime.now().toUtc().toIso8601String();
        records[proposed.idempotencyKeyDigest] = <String, Object?>{
          'schemaVersion': _idempotencyRegistrySchemaVersion,
          'phase': 'reserved',
          'createdAt': now,
          'updatedAt': now,
          'idempotencyKeyDigest': proposed.idempotencyKeyDigest,
          'businessFingerprint': proposed.businessFingerprint,
          'businessParametersPersisted': false,
          'method': method,
          'invocation': _invocationIdentityForReceipt(proposed),
        };
        registry['records'] = records;
        registry['updatedAt'] = now;
        _writeIdempotencyRegistry(registry);
        return _DurableInvocationDecision(invocation: proposed);
      },
    );
  }

  bool _compactIdempotencyReceipts(
    Map<String, Object?> records,
    _IdempotencyTombstoneFilter tombstoneFilter,
  ) {
    final compactable =
        records.entries.where((entry) {
          final receipt = entry.value;
          return receipt is Map &&
              _receiptIsCompactable(Map<String, Object?>.from(receipt));
        }).toList()..sort((first, second) {
          String timestamp(Map<String, Object?> entry) =>
              (entry['updatedAt'] ?? entry['createdAt'] ?? '').toString();
          final byTime = timestamp(
            first.value as Map<String, Object?>,
          ).compareTo(timestamp(second.value as Map<String, Object?>));
          return byTime != 0 ? byTime : first.key.compareTo(second.key);
        });

    var compacted = false;
    for (final entry in compactable) {
      if (records.length < _maxIdempotencyReceipts) break;
      tombstoneFilter.add(entry.key);
      records.remove(entry.key);
      compacted = true;
    }
    return compacted;
  }

  /// A closed receipt whose dispatch status is known can be compacted into
  /// the tombstone filter: a late retry of its key is still refused. A
  /// reserved or genuinely unknown receipt stays until it is reconciled.
  bool _receiptIsCompactable(Map<String, Object?> receipt) {
    final phase = receipt['phase'];
    return phase == 'completed' ||
        phase == 'tombstone' ||
        _receiptDispatchKnownWithoutOutcome(receipt);
  }

  /// Also reads receipts written before [_nonreplayableReceiptPhase] existed:
  /// they used `outcome_unknown` with the storage-limit reason even though
  /// their dispatch was known.
  bool _receiptDispatchKnownWithoutOutcome(Map<String, Object?> receipt) {
    final phase = receipt['phase'];
    return phase == _nonreplayableReceiptPhase ||
        (phase == 'outcome_unknown' &&
            receipt['outcomeUnavailableReason'] == _outcomeStorageLimitReason);
  }

  String get _idempotencyCapacityNextStep {
    final name = _readSessionMeta()?['name']?.toString();
    final app = name == null || name.isEmpty ? '<name>' : name;
    return 'Check the app for the effect of the unresolved inputs, then run '
        '`flutter-scout --app $app stop --clear-session` and launch again; '
        'clearing forgets those receipts, so do not repeat an input whose '
        'effect you have not checked.';
  }

  /// The answer to a retried key whose earlier dispatch is known but whose
  /// outcome was too large to store: nothing is sent again.
  Map<String, dynamic> _idempotencyOutcomeNotStored(
    Map<String, Object?> receipt, {
    required _MutationInvocation? invocation,
    required String method,
    required String runId,
    required String idempotencyKey,
    required String idempotencyKeyDigest,
    required String businessFingerprint,
    required String keySource,
  }) {
    const nextStep =
        'Observe the app to learn the result of the original input. Use a new '
        'idempotency key only for a new, deliberate input.';
    final storedDispatch = receipt['dispatch'];
    final dispatch =
        storedDispatch == 'dispatched' || storedDispatch == 'not_dispatched'
        ? storedDispatch as String
        // Receipts from before the dispatch field had a known, non-unknown
        // dispatch; `dispatched` is the conservative reading.
        : 'dispatched';
    final message =
        'This idempotency key already ran (dispatch: $dispatch). Its outcome '
        'was too large to store, so Scout cannot replay it and did not send '
        'the input again. $nextStep';
    final details = <String, Object?>{
      'originalDispatch': dispatch,
      'outcomeDigest': receipt['outcomeDigest'],
      'outcomeBytes': receipt['outcomeBytes'],
      'completedAt': receipt['completedAt'],
      'replayUnavailableReason': _outcomeStorageLimitReason,
      'nextStep': nextStep,
    };
    final base = invocation == null
        ? _idempotencyUnknownWithoutInvocation(
            code: 'idempotency_outcome_not_stored',
            message: message,
            method: method,
            runId: runId,
            idempotencyKey: idempotencyKey,
            idempotencyKeyDigest: idempotencyKeyDigest,
            keySource: keySource,
            details: details,
          )
        : _unknownDispatchProtocolFailure(
            code: 'idempotency_outcome_not_stored',
            message: message,
            invocation: invocation,
            transport: 'ok',
            details: details,
          );
    final identity = receipt['invocation'];
    return <String, dynamic>{
      ...base,
      'transport': 'ok',
      'dispatch': dispatch,
      'method': method,
      'idempotencyKey': idempotencyKey,
      'idempotencyKeyDigest': idempotencyKeyDigest,
      'idempotency': <String, Object?>{
        'status': 'committed_nonreplayable',
        'durability': 'cross_process_receipt',
        'replayability': 'unavailable',
        'replayUnavailableReason': _outcomeStorageLimitReason,
        'keySource': keySource,
        'businessFingerprint': businessFingerprint,
        'idempotencyKeyDigest': idempotencyKeyDigest,
        if (identity is Map) 'originalCommandId': identity['commandId'],
      },
    };
  }

  Map<String, Object?> _invocationIdentityForReceipt(
    _MutationInvocation invocation,
  ) => <String, Object?>{
    'commandId': invocation.commandId,
    'idempotencyKeyDigest': invocation.idempotencyKeyDigest,
    'runId': invocation.runId,
    'runtimeInstanceId': invocation.runtimeInstanceId,
    'expectedStateGeneration': invocation.expectedStateGeneration,
    'deadlineEpochMs': invocation.deadlineEpochMs,
    'errorCursor': invocation.errorCursor,
  };

  _MutationInvocation? _invocationFromReceipt(
    Map<String, Object?> receipt, {
    required String key,
    required Map<String, String> businessParams,
    required _MutationInvocation fallback,
  }) => _invocationFromReceiptIdentity(
    receipt,
    key: key,
    keyDigest: fallback.idempotencyKeyDigest,
    businessFingerprint: fallback.businessFingerprint,
    businessParams: businessParams,
    callerSupplied: fallback.callerSuppliedIdempotencyKey,
  );

  _MutationInvocation? _invocationFromReceiptIdentity(
    Map<String, Object?> receipt, {
    required String key,
    required String keyDigest,
    required String businessFingerprint,
    required Map<String, String> businessParams,
    required bool callerSupplied,
  }) {
    final raw = receipt['invocation'];
    if (raw is! Map) return null;
    final commandId = raw['commandId']?.toString();
    final storedKeyDigest = raw['idempotencyKeyDigest']?.toString();
    final runId = raw['runId']?.toString();
    final runtimeInstanceId = raw['runtimeInstanceId']?.toString();
    final expectedStateGeneration = switch (raw['expectedStateGeneration']) {
      final int value => value,
      final num value => value.toInt(),
      final String value => int.tryParse(value),
      _ => null,
    };
    final deadlineEpochMs = switch (raw['deadlineEpochMs']) {
      final int value => value,
      final num value => value.toInt(),
      final String value => int.tryParse(value),
      _ => null,
    };
    final errorCursor = switch (raw['errorCursor']) {
      final int value => value,
      final num value => value.toInt(),
      final String value => int.tryParse(value),
      _ => null,
    };
    if (commandId == null ||
        commandId.isEmpty ||
        storedKeyDigest == null ||
        storedKeyDigest != keyDigest ||
        runId == null ||
        runId.isEmpty ||
        runtimeInstanceId == null ||
        runtimeInstanceId.isEmpty ||
        expectedStateGeneration == null ||
        expectedStateGeneration < 0 ||
        deadlineEpochMs == null ||
        deadlineEpochMs < 0) {
      return null;
    }
    final envelope = <String, String>{
      ...businessParams,
      'schemaVersion': '$_scoutCliSchemaVersion',
      'clientProtocolMin': '$_scoutCliProtocolMin',
      'clientProtocolMax': '$_scoutCliProtocolMax',
      'commandId': commandId,
      'idempotencyKey': key,
      'runId': runId,
      'runtimeInstanceId': runtimeInstanceId,
      'expectedStateGeneration': '$expectedStateGeneration',
      'deadlineEpochMs': '$deadlineEpochMs',
      if (errorCursor != null) 'errorCursor': '$errorCursor',
    };
    return _MutationInvocation(
      commandId: commandId,
      idempotencyKey: key,
      idempotencyKeyDigest: keyDigest,
      businessFingerprint: businessFingerprint,
      callerSuppliedIdempotencyKey: callerSupplied,
      runId: runId,
      runtimeInstanceId: runtimeInstanceId,
      expectedStateGeneration: expectedStateGeneration,
      deadlineEpochMs: deadlineEpochMs,
      errorCursor: errorCursor,
      params: Map<String, String>.unmodifiable(envelope),
    );
  }

  Map<String, dynamic> _idempotencyReconciliationUnavailable(
    _MutationInvocation invocation, {
    required String connectionStage,
    Object? cause,
  }) {
    final failure = _unknownDispatchProtocolFailure(
      code: 'idempotency_reconciliation_unavailable',
      message:
          'A durable receipt shows that this mutation may already have been dispatched, but Scout cannot reach the original runtime to reconcile it. Scout will not redispatch.',
      invocation: invocation,
      transport: 'failed',
      details: <String, Object?>{
        'connectionStage': connectionStage,
        if (cause != null) 'failureType': cause.runtimeType.toString(),
      },
    );
    return <String, dynamic>{
      ...failure,
      'idempotencyKeyDigest': invocation.idempotencyKeyDigest,
      'idempotency': <String, Object?>{
        'status': 'outcome_unknown',
        'durability': 'cross_process_receipt',
        'keySource': invocation.callerSuppliedIdempotencyKey
            ? 'caller'
            : 'generated',
        'businessFingerprint': invocation.businessFingerprint,
        'idempotencyKeyDigest': invocation.idempotencyKeyDigest,
        'originalCommandId': invocation.commandId,
      },
    };
  }

  Map<String, dynamic> _idempotencyUnknownWithoutInvocation({
    required String code,
    required String message,
    required String method,
    required String runId,
    required String idempotencyKey,
    required String idempotencyKeyDigest,
    String? keySource,
    Map<String, Object?> details = const <String, Object?>{},
  }) => <String, dynamic>{
    'ok': false,
    'schemaVersion': _scoutCliSchemaVersion,
    'protocolVersion': _scoutCliProtocolMax,
    'minSupportedProtocolVersion': _scoutCliProtocolMin,
    'maxSupportedProtocolVersion': _scoutCliProtocolMax,
    'capabilities': _scoutCliProtocolCapabilities,
    'capabilitySource': 'cli',
    'commandId': _activeCommandId ?? _newProtocolIdentifier('command'),
    'runId': runId,
    'runtimeInstanceId': null,
    'stateGeneration': null,
    'identityStatus': 'unavailable',
    'result': null,
    'structuredError': <String, Object?>{
      'code': code,
      'message': message,
      if (details.isNotEmpty) 'details': details,
    },
    'error': <String, Object?>{'code': code, 'message': message},
    'transport': 'failed',
    'dispatch': 'dispatch_outcome_unknown',
    'observation': 'observation_unavailable',
    'postcondition': 'postcondition_not_requested',
    'runtimeHealth': 'runtime_health_unknown',
    'stable': false,
    'stability': _unavailableCliStability(
      transport: 'failed',
      stoppingReason: 'idempotency_receipt_identity_unavailable',
    ),
    // The caller already knows this value and needs it to reconcile. It is
    // intentionally excluded from every persisted evidence projection.
    'idempotencyKey': idempotencyKey,
    'idempotencyKeyDigest': idempotencyKeyDigest,
    'idempotency': <String, Object?>{
      'status': 'outcome_unknown',
      'durability': 'cross_process_receipt',
      'keySource':
          keySource ??
          (_activeIdempotencyKeyWasGenerated ? 'generated' : 'caller'),
      'idempotencyKeyDigest': idempotencyKeyDigest,
    },
    'expectedStateGeneration': null,
    'deadlineEpochMs': null,
    'errorCursor': null,
    'errorsSinceCursor': null,
    'method': method,
    'timings': const <String, Object?>{},
  };

  Future<Map<String, dynamic>> _runDurableLocalMutation({
    required String method,
    required Map<String, String> businessParams,
    required Future<Map<String, dynamic>> Function() dispatch,
    required String Function(Map<String, dynamic> result) classifyDispatch,
  }) async {
    final runId = _currentRunIdFromSession();
    if (runId == null || runId.isEmpty) {
      return _notDispatchedProtocolFailure(
        code: 'missing_session_run_id',
        message:
            'This session has no run identity. Reattach or relaunch before mutating local application state.',
        method: method,
      );
    }
    final callerKey = _activeCallerIdempotencyKey;
    final key = callerKey ?? _newProtocolIdentifier('idem-local');
    final keyDigest = _idempotencyKeyDigest(key);
    final meta = _readSessionMeta() ?? const <String, dynamic>{};
    final runtimeInstanceId =
        'local-${_sha256Canonical(<String, Object?>{'runId': runId, 'device': _readDevice(), 'pid': _readPid(), 'vmServiceUri': _readVmUri(), 'mode': meta['mode']}).substring(0, 48)}';
    final deadlineEpochMs = DateTime.now()
        .add(const Duration(minutes: 2))
        .millisecondsSinceEpoch;
    final commandId = _newProtocolIdentifier(
      _activeCommandId == null
          ? 'local-mutation'
          : 'local-mutation-$_activeCommandId',
    );
    final fingerprint = _mutationBusinessFingerprint(
      method: method,
      runId: runId,
      params: businessParams,
    );
    final proposed = _MutationInvocation(
      commandId: commandId,
      idempotencyKey: key,
      idempotencyKeyDigest: keyDigest,
      businessFingerprint: fingerprint,
      callerSuppliedIdempotencyKey:
          callerKey != null && !_activeIdempotencyKeyWasGenerated,
      runId: runId,
      runtimeInstanceId: runtimeInstanceId,
      expectedStateGeneration: 0,
      deadlineEpochMs: deadlineEpochMs,
      errorCursor: null,
      params: Map<String, String>.unmodifiable(<String, String>{
        ...businessParams,
        'schemaVersion': '$_scoutCliSchemaVersion',
        'clientProtocolMin': '$_scoutCliProtocolMin',
        'clientProtocolMax': '$_scoutCliProtocolMax',
        'commandId': commandId,
        'idempotencyKey': key,
        'runId': runId,
        'runtimeInstanceId': runtimeInstanceId,
        'expectedStateGeneration': '0',
        'deadlineEpochMs': '$deadlineEpochMs',
      }),
    );

    late final _DurableInvocationDecision durable;
    try {
      durable = _reserveDurableMutationInvocation(
        proposed: proposed,
        method: method,
        businessParams: businessParams,
      );
    } catch (error) {
      if (callerKey != null) {
        return _idempotencyUnknownWithoutInvocation(
          code: 'idempotency_registry_integrity_unknown',
          message:
              'Scout could not validate the durable receipt registry and will not risk repeating a local mutation.',
          method: method,
          runId: runId,
          idempotencyKey: key,
          idempotencyKeyDigest: keyDigest,
          details: <String, Object?>{
            'failureType': error.runtimeType.toString(),
          },
        );
      }
      return _notDispatchedProtocolFailure(
        code: 'idempotency_receipt_reservation_failed',
        message:
            'Scout could not durably reserve the local mutation identity. Nothing was dispatched.',
        method: method,
        runId: runId,
        transport: 'failed',
        details: <String, Object?>{
          'failureType': error.runtimeType.toString(),
          'idempotencyKeyDigest': keyDigest,
        },
      );
    }
    final failure = durable.failure;
    if (failure != null) return failure;
    final replay = durable.replay;
    if (replay != null) return replay;
    final invocation = durable.invocation!;
    if (invocation.commandId != proposed.commandId) {
      return _idempotencyReconciliationUnavailable(
        invocation,
        connectionStage: 'local_mutation_receipt',
      );
    }

    try {
      final raw = await dispatch();
      final dispatchStatus = classifyDispatch(raw);
      final stability =
          raw['stability'] ??
          _unavailableCliStability(
            transport: raw['transport']?.toString() ?? 'ok',
            stoppingReason: 'local_mutation_semantic_observation_unavailable',
            deadlineEpochMs: invocation.deadlineEpochMs,
            initialStateGeneration: 0,
          );
      final closed = <String, dynamic>{
        ...raw,
        'schemaVersion': _scoutCliSchemaVersion,
        'protocolVersion': _scoutCliProtocolMax,
        'minSupportedProtocolVersion': _scoutCliProtocolMin,
        'maxSupportedProtocolVersion': _scoutCliProtocolMax,
        'capabilities': _scoutCliProtocolCapabilities,
        'capabilitySource': 'cli',
        'commandId': invocation.commandId,
        'runId': invocation.runId,
        'runtimeInstanceId': invocation.runtimeInstanceId,
        'stateGeneration': 0,
        'identityStatus': 'validated_pre_dispatch',
        'transport': raw['transport'] ?? 'ok',
        'dispatch': dispatchStatus,
        'observation': raw['observation'] ?? 'observation_unavailable',
        'postcondition': raw['postcondition'] ?? 'postcondition_not_requested',
        'runtimeHealth': raw['runtimeHealth'] ?? 'runtime_health_unknown',
        'stable': _truthfulLegacyStable(raw['stable'], stability),
        'stability': stability,
        'idempotencyKey': invocation.idempotencyKey,
        'idempotencyKeyDigest': invocation.idempotencyKeyDigest,
        'expectedStateGeneration': 0,
        'deadlineEpochMs': invocation.deadlineEpochMs,
        'errorCursor': null,
        'errorsSinceCursor': null,
        'timings': raw['timings'] ?? const <String, Object?>{},
      };
      if (dispatchStatus == 'dispatch_outcome_unknown') {
        return _closeDurableMutationOutcome(invocation, <String, dynamic>{
          ...closed,
          'ok': false,
          'structuredError':
              closed['structuredError'] ??
              <String, Object?>{
                'code': 'local_mutation_dispatch_outcome_unknown',
                'message':
                    'The local mutation outcome could not be proven. Scout will not redispatch it.',
              },
        });
      }
      return _closeDurableMutationOutcome(invocation, closed);
    } catch (error) {
      return _closeDurableMutationOutcome(
        invocation,
        _unknownDispatchProtocolFailure(
          code: 'local_mutation_dispatch_outcome_unknown',
          message:
              'The local mutation transport failed after dispatch may have occurred. Scout will not retry with a new identity.',
          invocation: invocation,
          transport: 'failed',
          details: <String, Object?>{
            'failureType': error.runtimeType.toString(),
          },
        ),
      );
    }
  }

  _DurableOutcomeCommit _commitDurableMutationOutcome(
    _MutationInvocation invocation,
    Map<String, dynamic> rawOutcome,
  ) {
    try {
      final sanitized = _sanitizeForSerialization(rawOutcome);
      if (sanitized is! Map) {
        throw const ScoutCliException(
          'idempotency_outcome_serialization_failed',
          'The mutation outcome could not be serialized as an object.',
        );
      }
      final safeOutcome = <String, dynamic>{
        for (final entry in sanitized.entries)
          entry.key.toString(): entry.value,
      };
      final storedOutcome = Map<String, dynamic>.from(
        _redactBusinessValuesForReceipt(
              _redactIdempotencyKeyFromReceipt(
                safeOutcome,
                invocation.idempotencyKey,
              ),
              _businessParamsFromInvocation(invocation),
            )
            as Map,
      )..remove('idempotencyKey');
      final outcomeDigest = _sha256Canonical(storedOutcome);
      final encodedOutcomeBytes = utf8.encode(jsonEncode(storedOutcome)).length;
      final dispatchOutcomeUnknown =
          rawOutcome['dispatch'] == 'dispatch_outcome_unknown';
      final replayable =
          !dispatchOutcomeUnknown &&
          encodedOutcomeBytes <= _maxStoredIdempotencyOutcomeBytes;
      _withPrivateFileLock<void>(
        _idempotencyRegistryLockPath,
        boundary: _sessionDir.path,
        body: () {
          final registry = _readIdempotencyRegistry();
          final records = registry['records']! as Map<String, Object?>;
          final rawReceipt = records[invocation.idempotencyKeyDigest];
          if (rawReceipt is! Map) {
            throw const ScoutCliException(
              'idempotency_receipt_missing',
              'The pre-dispatch idempotency receipt is missing.',
            );
          }
          final receipt = Map<String, Object?>.from(rawReceipt);
          if (receipt['businessFingerprint'] !=
              invocation.businessFingerprint) {
            throw const ScoutCliException(
              'idempotency_receipt_conflict',
              'The durable receipt changed before outcome commit.',
            );
          }
          final identity = receipt['invocation'];
          if (identity is! Map ||
              identity['commandId'] != invocation.commandId ||
              identity['idempotencyKeyDigest'] !=
                  invocation.idempotencyKeyDigest ||
              identity['runtimeInstanceId'] != invocation.runtimeInstanceId ||
              identity['runId'] != invocation.runId ||
              identity['expectedStateGeneration'] !=
                  invocation.expectedStateGeneration ||
              identity['deadlineEpochMs'] != invocation.deadlineEpochMs ||
              identity['errorCursor'] != invocation.errorCursor) {
            throw const ScoutCliException(
              'idempotency_receipt_identity_mismatch',
              'The durable receipt no longer matches the dispatched invocation.',
            );
          }
          final now = DateTime.now().toUtc().toIso8601String();
          receipt
            ..['phase'] = replayable
                ? 'completed'
                : dispatchOutcomeUnknown
                ? 'outcome_unknown'
                : _nonreplayableReceiptPhase
            ..['updatedAt'] = now
            ..['completedAt'] = now
            ..['outcomeDigest'] = outcomeDigest
            ..['outcomeBytes'] = encodedOutcomeBytes;
          if (replayable) {
            receipt['outcome'] = storedOutcome;
          } else {
            receipt.remove('outcome');
            receipt['outcomeUnavailableReason'] = dispatchOutcomeUnknown
                ? 'dispatch_outcome_unknown'
                : _outcomeStorageLimitReason;
            if (!dispatchOutcomeUnknown) {
              receipt['dispatch'] = rawOutcome['dispatch']?.toString();
            }
          }
          records[invocation.idempotencyKeyDigest] = receipt;
          _pruneReplayableOutcomes(
            records,
            preserve: invocation.idempotencyKeyDigest,
          );
          registry['records'] = records;
          registry['updatedAt'] = now;
          _writeIdempotencyRegistry(registry);
        },
      );
      return _DurableOutcomeCommit(
        outcome: <String, dynamic>{
          ...safeOutcome,
          'idempotencyKey': invocation.idempotencyKey,
          'idempotencyKeyDigest': invocation.idempotencyKeyDigest,
          'idempotency': <String, Object?>{
            // A bounded receipt can omit a *known* full response, which
            // prevents replay but does not make the completed dispatch
            // uncertain. A genuinely unknown dispatch must remain unknown
            // so callers never infer a mutation happened.
            'status': replayable
                ? 'committed'
                : dispatchOutcomeUnknown
                ? 'outcome_unknown'
                : 'committed_nonreplayable',
            'durability': 'cross_process_receipt',
            'replayability': replayable ? 'replayable' : 'unavailable',
            if (!replayable)
              'replayUnavailableReason': dispatchOutcomeUnknown
                  ? 'dispatch_outcome_unknown'
                  : _outcomeStorageLimitReason,
            'keySource': invocation.callerSuppliedIdempotencyKey
                ? 'caller'
                : 'generated',
            'businessFingerprint': invocation.businessFingerprint,
            'idempotencyKeyDigest': invocation.idempotencyKeyDigest,
          },
        },
      );
    } catch (error) {
      return _DurableOutcomeCommit(
        outcome: rawOutcome,
        failure: _unknownDispatchProtocolFailure(
          code: 'idempotency_outcome_commit_failed',
          message:
              'Scout obtained a mutation outcome but could not durably commit its exactly-once receipt. Reconcile with the same key; do not create a new mutation identity.',
          invocation: invocation,
          details: <String, Object?>{'cause': error.toString()},
        ),
      );
    }
  }

  Object? _redactIdempotencyKeyFromReceipt(Object? value, String key) {
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key.toString(): _redactIdempotencyKeyFromReceipt(
            entry.value,
            key,
          ),
      };
    }
    if (value is Iterable) {
      return <Object?>[
        for (final item in value) _redactIdempotencyKeyFromReceipt(item, key),
      ];
    }
    if (value is String && key.isNotEmpty && value.contains(key)) {
      return value.replaceAll(key, '[IDEMPOTENCY_KEY]');
    }
    return value;
  }

  String? _resultIdempotencyKeyDigest(Map<String, dynamic> result) {
    final direct = result['idempotencyKeyDigest']?.toString();
    if (direct != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(direct)) {
      return direct;
    }
    final metadata = result['idempotency'];
    final nested = metadata is Map
        ? metadata['idempotencyKeyDigest']?.toString()
        : null;
    if (nested != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(nested)) {
      return nested;
    }
    final rawKey = result['idempotencyKey'];
    return rawKey is String && rawKey.isNotEmpty
        ? _idempotencyKeyDigest(rawKey)
        : null;
  }

  String? _resultIdempotencyKeySource(Map<String, dynamic> result) {
    final metadata = result['idempotency'];
    final source = metadata is Map ? metadata['keySource']?.toString() : null;
    if (source == 'caller' || source == 'generated') return source;
    final rawKey = result['idempotencyKey'];
    if (rawKey is! String || rawKey.isEmpty) return null;
    return rawKey == _activeCallerIdempotencyKey ? 'caller' : 'generated';
  }

  Object? _idempotencySafeEvidenceValue(
    Map<String, dynamic> result,
    Object? value,
  ) {
    final rawKey = result['idempotencyKey'];
    if (rawKey is! String || rawKey.isEmpty) return value;
    Object? redact(Object? candidate) {
      if (candidate is Map) {
        return <String, Object?>{
          for (final entry in candidate.entries)
            entry.key.toString().replaceAll(rawKey, '[IDEMPOTENCY_KEY]'):
                redact(entry.value),
        };
      }
      if (candidate is Iterable) {
        return <Object?>[for (final item in candidate) redact(item)];
      }
      if (candidate is String && candidate.contains(rawKey)) {
        return candidate.replaceAll(rawKey, '[IDEMPOTENCY_KEY]');
      }
      return candidate;
    }

    return redact(value);
  }

  Map<String, String> _businessParamsFromInvocation(
    _MutationInvocation invocation,
  ) {
    const envelopeFields = <String>{
      'schemaVersion',
      'clientProtocolMin',
      'clientProtocolMax',
      'commandId',
      'idempotencyKey',
      'runId',
      'runtimeInstanceId',
      'expectedStateGeneration',
      'deadlineEpochMs',
      'errorCursor',
      'errorsSinceCursor',
    };
    return <String, String>{
      for (final entry in invocation.params.entries)
        if (!envelopeFields.contains(entry.key)) entry.key: entry.value,
    };
  }

  String _businessValueToken(String value) =>
      '[BUSINESS_VALUE:${crypto.sha256.convert(utf8.encode(value))}]';

  Object? _redactBusinessValuesForReceipt(
    Object? value,
    Map<String, String> businessParams,
  ) {
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          _redactBusinessStringForReceipt(entry.key.toString(), businessParams):
              _redactBusinessValuesForReceipt(entry.value, businessParams),
      };
    }
    if (value is Iterable) {
      return <Object?>[
        for (final item in value)
          _redactBusinessValuesForReceipt(item, businessParams),
      ];
    }
    if ((value is num || value is bool) &&
        businessParams.values.contains(value.toString())) {
      return <String, Object?>{
        r'$flutterScoutBusinessValue': _sha256Canonical(value.toString()),
        'type': value is bool
            ? 'bool'
            : value is int
            ? 'int'
            : 'double',
      };
    }
    if (value is! String || value.isEmpty) return value;
    return _redactBusinessStringForReceipt(value, businessParams);
  }

  String _redactBusinessStringForReceipt(
    String value,
    Map<String, String> businessParams,
  ) {
    var redacted = value;
    final values =
        businessParams.values
            .where((item) => item.isNotEmpty)
            .toSet()
            .toList(growable: false)
          ..sort((first, second) => second.length.compareTo(first.length));
    for (final businessValue in values) {
      redacted = redacted.replaceAll(
        businessValue,
        _businessValueToken(businessValue),
      );
    }
    return redacted;
  }

  Object? _restoreBusinessValuesFromReceipt(
    Object? value,
    Map<String, String> businessParams,
  ) {
    if (value is Map) {
      final marker = value[r'$flutterScoutBusinessValue'];
      final markerType = value['type'];
      if (value.length == 2 && marker is String && markerType is String) {
        for (final businessValue in businessParams.values) {
          if (_sha256Canonical(businessValue) != marker) continue;
          return switch (markerType) {
            'bool' => bool.tryParse(businessValue),
            'int' => int.tryParse(businessValue),
            'double' => double.tryParse(businessValue),
            _ => null,
          };
        }
        return null;
      }
      return <String, Object?>{
        for (final entry in value.entries)
          _restoreBusinessStringFromReceipt(
            entry.key.toString(),
            businessParams,
          ): _restoreBusinessValuesFromReceipt(
            entry.value,
            businessParams,
          ),
      };
    }
    if (value is Iterable) {
      return <Object?>[
        for (final item in value)
          _restoreBusinessValuesFromReceipt(item, businessParams),
      ];
    }
    if (value is! String || value.isEmpty) return value;
    return _restoreBusinessStringFromReceipt(value, businessParams);
  }

  String _restoreBusinessStringFromReceipt(
    String value,
    Map<String, String> businessParams,
  ) {
    var restored = value;
    for (final businessValue in businessParams.values.toSet()) {
      if (businessValue.isEmpty) continue;
      restored = restored.replaceAll(
        _businessValueToken(businessValue),
        businessValue,
      );
    }
    return restored;
  }

  Map<String, dynamic> _closeDurableMutationOutcome(
    _MutationInvocation invocation,
    Map<String, dynamic> outcome,
  ) {
    final timedOutcome = _withInvocationPhaseTimings(outcome, invocation);
    final committed = _commitDurableMutationOutcome(invocation, timedOutcome);
    final failure = committed.failure;
    return failure == null
        ? committed.outcome
        : _withInvocationPhaseTimings(failure, invocation);
  }

  void _pruneReplayableOutcomes(
    Map<String, Object?> records, {
    required String preserve,
  }) {
    final completed =
        <MapEntry<String, Map<String, Object?>>>[
          for (final entry in records.entries)
            if (entry.value is Map &&
                (entry.value as Map)['phase'] == 'completed' &&
                (entry.value as Map)['outcome'] is Map)
              MapEntry(
                entry.key,
                Map<String, Object?>.from(entry.value as Map),
              ),
        ]..sort((first, second) {
          final firstAt = first.value['completedAt']?.toString() ?? '';
          final secondAt = second.value['completedAt']?.toString() ?? '';
          return firstAt.compareTo(secondAt);
        });
    while (completed.length > _maxReplayableIdempotencyOutcomes) {
      var index = completed.indexWhere((entry) => entry.key != preserve);
      if (index < 0) index = 0;
      final oldest = completed.removeAt(index);
      final receipt = oldest.value
        ..['phase'] = 'tombstone'
        ..['prunedAt'] = DateTime.now().toUtc().toIso8601String()
        ..remove('outcome');
      records[oldest.key] = receipt;
    }
  }
}
