part of 'flutter_scout_cli.dart';

// VM-service credentials are capability URLs. They may be persisted only in
// the dedicated owner-only vm_uri.txt credential file and may connect only to
// an explicit loopback endpoint. No DNS name other than exact `localhost` is
// accepted, which removes DNS-rebinding and accidental remote-egress ambiguity.

const int _maxVmServiceUriBytes = 16 * 1024;

class _ValidatedVmServiceUri {
  const _ValidatedVmServiceUri({
    required this.normalized,
    required this.endpoint,
  });

  final String normalized;
  final Map<String, Object?> endpoint;
}

extension VmTransportDebug on FlutterScoutCli {
  Map<String, Object?> debugValidateVmServiceUri(String raw) {
    final validated = _validatedVmServiceUri(raw);
    return <String, Object?>{
      'normalized': validated.normalized,
      'endpoint': validated.endpoint,
    };
  }

  Future<void> debugAttemptVmServiceConnection(String raw) async {
    final service = await _connect(raw);
    await service.dispose();
  }

  Map<String, Object?> debugSanitizeVmServicePayload(
    Map<String, Object?> payload,
  ) => Map<String, Object?>.from(_sanitizeForSerialization(payload)! as Map);

  void debugPersistVmServiceUri(String raw) => _persistValidatedVmUri(raw);

  void debugWriteVmServiceSessionMetadata(String raw) =>
      _writeSessionMeta(<String, Object?>{
        'mode': 'attach_only',
        'state': 'ready',
        'runId': 'vm-transport-debug-run',
        'vmServiceUri': raw,
      });

  String get debugVmServiceCredentialPath => _vmUriFile;

  String get debugVmServiceSessionMetadataPath => _sessionMetaFile;
}

extension _CliVmTransport on FlutterScoutCli {
  _ValidatedVmServiceUri _validatedVmServiceUri(String raw) {
    final candidate = raw.trim();
    _registerVmUriCredentials(candidate);

    Never reject(String code, String message, {required String reason}) {
      throw ScoutCliException(
        code,
        message,
        details: <String, Object?>{
          'reason': reason,
          'transportPolicy': 'loopback_only',
          'egress': 'not_attempted',
          'persistence': 'not_written',
        },
      );
    }

    if (candidate.isEmpty ||
        candidate.length > _maxVmServiceUriBytes ||
        utf8.encode(candidate).length > _maxVmServiceUriBytes ||
        candidate.codeUnits.any((unit) => unit <= 0x20 || unit == 0x7f) ||
        candidate.contains(r'\') ||
        RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(candidate)) {
      reject(
        'invalid_vm_service_uri',
        'The VM-service URL is empty, oversized, malformed, or contains '
            'unsafe characters.',
        reason: 'invalid_bounded_uri_text',
      );
    }

    final uri = Uri.tryParse(candidate);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      reject(
        'invalid_vm_service_uri',
        'The VM-service URL is malformed or has no authority.',
        reason: 'malformed_or_missing_authority',
      );
    }
    final scheme = uri.scheme.toLowerCase();
    if (!const <String>{'ws', 'wss', 'http', 'https'}.contains(scheme)) {
      reject(
        'unsupported_vm_service_transport',
        'VM-service transport supports only ws, wss, http, or https URLs.',
        reason: 'unsupported_scheme',
      );
    }
    if (uri.userInfo.isNotEmpty) {
      reject(
        'invalid_vm_service_uri',
        'VM-service URLs must not contain user information.',
        reason: 'userinfo_not_allowed',
      );
    }
    if (uri.hasFragment) {
      reject(
        'invalid_vm_service_uri',
        'VM-service URLs must not contain a fragment.',
        reason: 'fragment_not_allowed',
      );
    }
    if (!uri.hasPort) {
      reject(
        'invalid_vm_service_uri',
        'VM-service URLs must contain an explicit port.',
        reason: 'explicit_port_required',
      );
    }
    late final int port;
    try {
      port = uri.port;
    } on FormatException {
      reject(
        'invalid_vm_service_uri',
        'The VM-service URL contains a malformed port.',
        reason: 'invalid_port',
      );
    }
    if (port <= 0 || port > 65535) {
      reject(
        'invalid_vm_service_uri',
        'The VM-service URL port must be between 1 and 65535.',
        reason: 'invalid_port',
      );
    }
    final host = uri.host.toLowerCase();
    if (!_isStrictVmLoopbackHost(host)) {
      reject(
        'unsupported_vm_service_transport',
        'Remote VM-service connections are unsupported; use an explicit '
            'loopback URL from the local Flutter tool.',
        reason: 'non_loopback_host',
      );
    }

    final normalizedPath = uri.path.endsWith('/ws')
        ? uri.path
        : uri.path.endsWith('/')
        ? '${uri.path}ws'
        : '${uri.path}/ws';
    final normalizedUri = uri.replace(
      scheme: scheme == 'http'
          ? 'ws'
          : scheme == 'https'
          ? 'wss'
          : scheme,
      path: normalizedPath.isEmpty ? '/ws' : normalizedPath,
    );
    final normalized = normalizedUri.toString();
    _registerVmUriCredentials(normalized);
    final credentialPresent =
        uri.pathSegments.any(
          (segment) => segment.isNotEmpty && segment != 'ws',
        ) ||
        uri.hasQuery;
    return _ValidatedVmServiceUri(
      normalized: normalized,
      endpoint: <String, Object?>{
        'scheme': normalizedUri.scheme,
        'host': host,
        'port': port,
        'credentialPresent': credentialPresent,
        'transportPolicy': 'loopback_only',
        'egress': 'local_loopback',
      },
    );
  }

  Map<String, Object?> _safeVmServiceEndpointIdentity(String raw) {
    _registerVmUriCredentials(raw);
    try {
      return _validatedVmServiceUri(raw).endpoint;
    } on ScoutCliException {
      final parsed = Uri.tryParse(raw.trim());
      var credentialPresent = false;
      if (parsed != null) {
        try {
          credentialPresent =
              parsed.userInfo.isNotEmpty ||
              parsed.pathSegments.any(
                (segment) => segment.isNotEmpty && segment != 'ws',
              ) ||
              parsed.hasQuery;
        } on FormatException {
          credentialPresent = true;
        }
      }
      return <String, Object?>{
        'status': 'rejected',
        'credentialPresent': credentialPresent,
        'transportPolicy': 'loopback_only',
        'egress': 'not_attempted',
      };
    }
  }

  void _persistValidatedVmUri(String raw) {
    final validated = _validatedVmServiceUri(raw);
    _writePrivateSessionString(_vmUriFile, validated.normalized);
  }
}

bool _isStrictVmLoopbackHost(String host) {
  if (host == 'localhost' || host == '::1') return true;
  final parts = host.split('.');
  if (parts.length != 4 || parts.first != '127') return false;
  for (final part in parts) {
    if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part)) return false;
    final octet = int.tryParse(part);
    if (octet == null || octet > 255) return false;
  }
  return true;
}
