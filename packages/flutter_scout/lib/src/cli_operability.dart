part of 'flutter_scout_cli.dart';

// part: truthful, bounded operability snapshots shared by status, doctor,
// health, and the persistent transport's /health endpoint.

const int _operabilityContractVersion = 1;
const Duration _operabilityReadTimeout = Duration(seconds: 3);

extension _CliOperability on FlutterScoutCli {
  Future<Map<String, Object?>> _persistentHealthPayload(int port) async {
    final appHealth = await _healthPayload(includeStale: false);
    return <String, Object?>{
      'ok': true,
      'healthy': appHealth['healthy'] == true,
      'transportHealthy': true,
      'appReachable': appHealth['appReachable'] == true,
      'port': port,
      'address': InternetAddress.loopbackIPv4.address,
      'authenticationRequired': true,
      'transport': const <String, Object?>{
        'status': 'ready',
        'kind': 'persistent_loopback_http',
      },
      'appHealth': appHealth,
      'session': appHealth['session'] ?? _sessionModeInfo(),
      if (appHealth['deviceInfo'] != null)
        'deviceInfo': appHealth['deviceInfo'],
      'runtimeObservation': appHealth['runtimeObservation'],
      'lastHotUpdate': appHealth['lastHotUpdate'],
    };
  }

  Future<Map<String, Object?>> _healthPayload({
    required bool includeStale,
  }) async {
    final inspect = await _safeOperabilityRead(
      'ext.flutter_scout.inspect',
      const <String, String>{'brief': 'true'},
    );
    final runtimeObservation = await _observeRuntimeOperability(
      inspect: inspect,
    );
    if (inspect['ok'] == false) {
      return <String, Object?>{
        ...inspect,
        'healthy': false,
        'appReachable': false,
        'session': _sessionModeInfo(),
        if (_readDeviceInfo() != null) 'deviceInfo': _readDeviceInfo(),
        'runtimeObservation': runtimeObservation,
        'lastHotUpdate': _readSessionMeta()?['lastHotUpdate'],
        'logCursor': _currentLogCursor(),
      };
    }

    final errors = inspect['recentErrors'];
    final errorList = errors is List ? errors : const <Object?>[];
    final blocking = <Object?>[
      for (final error in errorList)
        if (error is Map && error['blocking'] == true && error['stale'] != true)
          error,
    ];
    final interactables = inspect['interactables'];
    final allLogSignals = _recentLogSignals();
    final now = DateTime.now();
    final logSignals = includeStale
        ? allLogSignals
        : allLogSignals.where((signal) => !signal.isStale(now)).toList();
    final blockingLogSignals = <_LogSignal>[
      for (final signal in logSignals)
        if (signal.isFreshBlocking(now)) signal,
    ];
    final degradedNodes =
        _nullableNonNegativeInt(inspect['degradedNodes']) ?? 0;
    return <String, Object?>{
      'ok': true,
      'appReachable': true,
      'screen': inspect['screen'],
      'viewSignature': inspect['viewSignature'],
      'idle': inspect['idle'],
      if (degradedNodes != 0) 'degradedNodes': degradedNodes,
      'interactableCount': interactables is List ? interactables.length : 0,
      if (blocking.isNotEmpty) 'blockingErrors': blocking,
      if (blockingLogSignals.isNotEmpty)
        'blockingLogSignals': _logSignalMaps(
          blockingLogSignals,
          now: now,
          phase: 'health',
          actionCommandId: _activeCommandId,
        ),
      if (errorList.isNotEmpty) 'recentErrorCount': errorList.length,
      if (logSignals.isNotEmpty)
        'recentLogSignals': _logSignalMaps(
          logSignals,
          now: now,
          phase: 'health',
          actionCommandId: _activeCommandId,
        ),
      'logCursor': _currentLogCursor(),
      'runId': _nonEmptyString(inspect['runId']) ?? _currentRunIdFromSession(),
      'runtimeInstanceId': _nonEmptyString(inspect['runtimeInstanceId']),
      'stateGeneration': _nullableNonNegativeInt(inspect['stateGeneration']),
      'schemaVersion': _nullableNonNegativeInt(inspect['schemaVersion']),
      'helperPackageVersion': _nonEmptyString(inspect['helperPackageVersion']),
      'helperProtocolVersion': _nullableNonNegativeInt(
        inspect['helperProtocolVersion'],
      ),
      'protocolVersion': _nullableNonNegativeInt(inspect['protocolVersion']),
      'minSupportedProtocolVersion': _nullableNonNegativeInt(
        inspect['minSupportedProtocolVersion'],
      ),
      'maxSupportedProtocolVersion': _nullableNonNegativeInt(
        inspect['maxSupportedProtocolVersion'],
      ),
      'capabilities': inspect['capabilities'],
      'session': _sessionModeInfo(),
      if (_readDeviceInfo() != null) 'deviceInfo': _readDeviceInfo(),
      'runtimeObservation': runtimeObservation,
      'lastHotUpdate': _readSessionMeta()?['lastHotUpdate'],
      'healthy':
          blocking.isEmpty && blockingLogSignals.isEmpty && degradedNodes == 0,
    };
  }

  Future<Map<String, Object?>> _observeRuntimeOperability({
    Map<String, dynamic>? inspect,
    String? unavailableReason,
  }) async {
    final observedInspect =
        inspect ??
        await _safeOperabilityRead(
          'ext.flutter_scout.inspect',
          const <String, String>{'brief': 'true'},
        );
    if (observedInspect['ok'] == false) {
      return <String, Object?>{
        'status': 'unavailable',
        'appReachability': 'unreachable',
        'reason':
            unavailableReason ??
            _operabilityErrorCode(observedInspect) ??
            'runtime_observation_failed',
        'helper': const <String, Object?>{
          'status': 'unavailable',
          'reason': 'helper_response_not_observed',
        },
        'protocol': const <String, Object?>{
          'status': 'unavailable',
          'reason': 'helper_protocol_not_observed',
        },
        'identity': const <String, Object?>{
          'status': 'unavailable',
          'runtimeInstanceId': null,
          'stateGeneration': null,
        },
        'actionState': const <String, Object?>{
          'status': 'unavailable',
          'activeDrag': null,
          'reason': 'runtime_not_observed',
        },
        'recording': const <String, Object?>{
          'status': 'unavailable',
          'active': null,
          'reason': 'runtime_not_observed',
        },
      };
    }

    final toolStates = await Future.wait<Map<String, dynamic>>(
      <Future<Map<String, dynamic>>>[
        _safeOperabilityRead(
          'ext.flutter_scout.dragStatus',
          const <String, String>{},
        ),
        _safeOperabilityRead('ext.flutter_scout.record', const <String, String>{
          'action': 'status',
        }),
      ],
    );
    final drag = toolStates[0];
    final recording = toolStates[1];
    final dragObserved = drag['ok'] != false;
    final recordingObserved = recording['ok'] != false;
    final dragActive = dragObserved ? drag['active'] == true : null;
    final recordingActive = recordingObserved
        ? recording['recording'] == true
        : null;
    final recordingPaused = recordingObserved
        ? recording['paused'] == true
        : null;

    return <String, Object?>{
      'status': 'observed',
      'appReachability': 'reachable',
      'helper': <String, Object?>{
        'status': 'observed',
        'package': 'flutter_scout_helper',
        'packageVersion': _nonEmptyString(
          observedInspect['helperPackageVersion'],
        ),
      },
      'protocol': <String, Object?>{
        'status': 'observed',
        'schemaVersion': _nullableNonNegativeInt(
          observedInspect['schemaVersion'],
        ),
        'protocolVersion': _nullableNonNegativeInt(
          observedInspect['protocolVersion'],
        ),
        'minimum': _nullableNonNegativeInt(
          observedInspect['minSupportedProtocolVersion'],
        ),
        'maximum': _nullableNonNegativeInt(
          observedInspect['maxSupportedProtocolVersion'],
        ),
        'capabilities': observedInspect['capabilities'] is Map
            ? <String, Object?>{
                for (final entry
                    in (observedInspect['capabilities'] as Map).entries)
                  entry.key.toString(): entry.value,
              }
            : const <String, Object?>{},
      },
      'identity': <String, Object?>{
        'status':
            _nonEmptyString(observedInspect['runtimeInstanceId']) != null &&
                _nullableNonNegativeInt(observedInspect['stateGeneration']) !=
                    null
            ? 'observed'
            : 'partial',
        'runId': _nonEmptyString(observedInspect['runId']),
        'runtimeInstanceId': _nonEmptyString(
          observedInspect['runtimeInstanceId'],
        ),
        'stateGeneration': _nullableNonNegativeInt(
          observedInspect['stateGeneration'],
        ),
        'snapshotId': _nonEmptyString(observedInspect['snapshotId']),
      },
      'screen': <String, Object?>{
        'status': _nonEmptyString(observedInspect['screen']) == null
            ? 'unavailable'
            : 'observed',
        'name': _nonEmptyString(observedInspect['screen']),
        'viewSignature': _nonEmptyString(observedInspect['viewSignature']),
        'idle': observedInspect['idle'] is bool
            ? observedInspect['idle']
            : null,
      },
      'actionState': dragObserved
          ? <String, Object?>{
              'status': dragActive == true ? 'held_drag_active' : 'idle',
              'activeDrag': dragActive,
              if (dragActive == true) ...<String, Object?>{
                'position': drag['position'],
                'gestureStart': drag['gestureStart'],
                'elapsedMs': _nullableNonNegativeInt(drag['elapsedMs']),
                'allowedNextActions': const <String>[
                  'drag-move',
                  'drag-end',
                  'drag-cancel',
                ],
              },
              if (dragActive == false)
                'allowedNextActions': const <String>['any_supported_action'],
            }
          : <String, Object?>{
              'status': 'unavailable',
              'activeDrag': null,
              'reason':
                  _operabilityErrorCode(drag) ?? 'drag_status_not_observed',
            },
      'recording': recordingObserved
          ? <String, Object?>{
              'status': recordingActive == true
                  ? recordingPaused == true
                        ? 'paused'
                        : 'recording'
                  : 'idle',
              'active': recordingActive,
              'paused': recordingPaused,
              'name': _nonEmptyString(recording['name']),
              'feature': _nonEmptyString(recording['feature']),
              'stepCount': _nullableNonNegativeInt(recording['stepCount']),
            }
          : <String, Object?>{
              'status': 'unavailable',
              'active': null,
              'reason':
                  _operabilityErrorCode(recording) ??
                  'recording_status_not_observed',
            },
    };
  }

  Future<Map<String, dynamic>> _safeOperabilityRead(
    String method,
    Map<String, String> params,
  ) async {
    try {
      return await _call(method, params, _operabilityReadTimeout);
    } on TimeoutException {
      return <String, dynamic>{
        'ok': false,
        'structuredError': const <String, Object?>{
          'code': 'operability_observation_timeout',
          'message': 'The bounded runtime operability observation timed out.',
        },
      };
    } catch (error) {
      return <String, dynamic>{
        'ok': false,
        'structuredError': <String, Object?>{
          'code': 'operability_observation_failed',
          'message': _redactSensitiveLogText(error.toString()),
        },
      };
    }
  }

  Map<String, Object?> _unavailableRuntimeOperability(
    String reason,
  ) => <String, Object?>{
    'status': 'unavailable',
    'appReachability': 'unreachable',
    'reason': reason,
    'helper': <String, Object?>{'status': 'unavailable', 'reason': reason},
    'protocol': <String, Object?>{'status': 'unavailable', 'reason': reason},
    'identity': const <String, Object?>{
      'status': 'unavailable',
      'runId': null,
      'runtimeInstanceId': null,
      'stateGeneration': null,
      'snapshotId': null,
    },
    'screen': <String, Object?>{
      'status': 'unavailable',
      'reason': reason,
      'name': null,
      'viewSignature': null,
      'idle': null,
    },
    'actionState': <String, Object?>{
      'status': 'unavailable',
      'activeDrag': null,
      'reason': reason,
    },
    'recording': <String, Object?>{
      'status': 'unavailable',
      'active': null,
      'reason': reason,
    },
  };

  String? _operabilityErrorCode(Map<Object?, Object?> value) {
    final structured = value['structuredError'];
    if (structured is Map) return _nonEmptyString(structured['code']);
    final error = value['error'];
    if (error is Map) return _nonEmptyString(error['code']);
    return _nonEmptyString(error ?? value['reason']);
  }

  Map<String, Object?> _cliOperabilityFacts(
    Map<String, Object?> legacy, {
    required String commandName,
    required String? runId,
    required String? runtimeInstanceId,
    required int? stateGeneration,
    required Map<String, Object?> capabilities,
    required Map<String, Object?>? structuredError,
  }) {
    final meta = _safeResponseSessionMeta();
    final commandSession = _operabilityMap(legacy['session']);
    final session = _operabilityMap(legacy['sessionState']) ?? commandSession;
    final nestedAppHealth = _operabilityMap(legacy['appHealth']);
    final runtimeObservation = _operabilityMap(
      legacy['runtimeObservation'] ?? nestedAppHealth?['runtimeObservation'],
    );
    final runtimeIdentity = _operabilityMap(runtimeObservation?['identity']);
    final helperIdentity = _operabilityMap(runtimeObservation?['helper']);
    final helperProtocol = _operabilityMap(runtimeObservation?['protocol']);
    final deviceInfo =
        _operabilityMap(legacy['deviceInfo']) ??
        _operabilityMap(_operabilityMap(legacy['device'])?['resolved']);
    final hotUpdate = _operabilityMap(legacy['hotUpdate']);
    final lastHotUpdate =
        _operabilityMap(legacy['lastHotUpdate']) ??
        _operabilityMap(meta?['lastHotUpdate']);
    final sourceVerification =
        _operabilityMap(legacy['sourceVerification']) ??
        _operabilityMap(lastHotUpdate?['sourceVerification']);
    final sessionMode =
        _nonEmptyString(session?['mode']) ?? _nonEmptyString(meta?['mode']);
    final appReachable =
        legacy['appReachable'] == true ||
        nestedAppHealth?['appReachable'] == true ||
        runtimeObservation?['appReachability'] == 'reachable';
    final reachabilityObserved =
        legacy.containsKey('appReachable') ||
        nestedAppHealth?.containsKey('appReachable') == true ||
        runtimeObservation?['appReachability'] != null ||
        legacy.containsKey('running');
    final helperMin =
        _nullableNonNegativeInt(helperProtocol?['minimum']) ??
        _nullableNonNegativeInt(legacy['minSupportedProtocolVersion']);
    final helperMax =
        _nullableNonNegativeInt(helperProtocol?['maximum']) ??
        _nullableNonNegativeInt(legacy['maxSupportedProtocolVersion']);
    final helperVersion =
        _nullableNonNegativeInt(helperProtocol?['protocolVersion']) ??
        _nullableNonNegativeInt(legacy['helperProtocolVersion']);
    final helperCapabilities =
        _operabilityMap(helperProtocol?['capabilities']) ??
        _operabilityMap(legacy['capabilities']);
    final helperObserved =
        runtimeObservation?['status'] == 'observed' ||
        helperIdentity?['status'] == 'observed' ||
        legacy['helperProtocolVersion'] != null;
    final compatible = helperObserved && helperMin != null && helperMax != null
        ? helperMax >= _scoutCliProtocolMin && helperMin <= _scoutCliProtocolMax
        : null;
    final negotiatedVersion = compatible == true
        ? min(_scoutCliProtocolMax, helperMax!)
        : null;
    final negotiatedCapabilities =
        compatible == true && helperCapabilities != null
        ? <String, Object?>{
            for (final entry in helperCapabilities.entries)
              if (entry.value == true &&
                  _scoutCliProtocolCapabilities[entry.key] == true)
                entry.key: true,
          }
        : null;
    final artifactFacts = _operabilityArtifactFacts();
    final actionState =
        _operabilityMap(runtimeObservation?['actionState']) ??
        const <String, Object?>{
          'status': 'unavailable',
          'activeDrag': null,
          'reason': 'runtime_action_state_not_observed',
        };
    final recordingState =
        _operabilityMap(runtimeObservation?['recording']) ??
        const <String, Object?>{
          'status': 'unavailable',
          'active': null,
          'reason': 'runtime_recording_state_not_observed',
        };
    final ownership = _operabilityOwnership(
      mode: sessionMode,
      meta: meta,
      session: session,
      hotUpdate: hotUpdate,
    );
    final vmEndpoint =
        _operabilityMap(legacy['vmServiceEndpoint']) ??
        _operabilityMap(meta?['vmServiceEndpoint']);
    final runtimeId =
        _nonEmptyString(runtimeIdentity?['runtimeInstanceId']) ??
        runtimeInstanceId;
    final generation =
        _nullableNonNegativeInt(runtimeIdentity?['stateGeneration']) ??
        stateGeneration;
    final resolvedRunId =
        _nonEmptyString(runtimeIdentity?['runId']) ??
        runId ??
        _nonEmptyString(session?['runId']) ??
        _nonEmptyString(meta?['runId']);
    final freshnessRuntimeId = _nonEmptyString(
      lastHotUpdate?['runtimeInstanceId'],
    );
    final freshnessRunId = _nonEmptyString(lastHotUpdate?['runId']);
    final sourceFreshness = sourceVerification == null
        ? const <String, Object?>{
            'status': 'unavailable',
            'reason': 'no_hot_update_source_verification_observed',
          }
        : runtimeId == null || freshnessRuntimeId == null
        ? <String, Object?>{
            'status': 'unavailable',
            'lastObservedStatus': sourceVerification['status'],
            'reason': 'source_verification_runtime_scope_unavailable',
            'observedAt': lastHotUpdate?['observedAt'],
            'action': lastHotUpdate?['action'],
          }
        : freshnessRuntimeId != runtimeId ||
              (freshnessRunId != null && freshnessRunId != resolvedRunId)
        ? <String, Object?>{
            'status': 'stale_runtime',
            'lastObservedStatus': sourceVerification['status'],
            'reason': 'runtime_replaced_since_source_verification',
            'observedAt': lastHotUpdate?['observedAt'],
            'action': lastHotUpdate?['action'],
          }
        : <String, Object?>{
            ...sourceVerification,
            'observedAt': lastHotUpdate?['observedAt'],
            'action': lastHotUpdate?['action'],
          };
    final recovery = _operabilityRecovery(
      commandName: commandName,
      structuredError: structuredError,
      appReachable: appReachable,
      reachabilityObserved: reachabilityObserved,
      compatible: compatible,
      ownership: ownership,
      sourceFreshness: sourceFreshness,
      actionState: actionState,
    );
    final sourceIdentity = _operabilityMap(meta?['sourceIdentity']);
    final inAppCaptureObserved =
        helperCapabilities?['inAppCapture'] == true ||
        helperCapabilities?['changedRegionCaptureV1'] == true;
    final observedHelperPackageVersion = _nonEmptyString(
      helperIdentity?['packageVersion'] ?? legacy['helperPackageVersion'],
    );
    final sessionObserved =
        meta != null ||
        (session != null &&
            (_nonEmptyString(session['name']) != null ||
                _nonEmptyString(session['runId']) != null ||
                _nonEmptyString(session['state']) != null ||
                (sessionMode != null && sessionMode != 'unknown')));
    final supervisor = <String, Object?>{
      'status': session?['supervisor'] != null || meta?['supervisor'] != null
          ? 'metadata_available'
          : 'unavailable',
      'identity': session?['supervisor'] ?? meta?['supervisor'],
      'state': session?['supervisorState'],
      'lastRunnerExit': session?['lastRunnerExit'],
      if (session?['supervisor'] == null && meta?['supervisor'] == null)
        'reason': 'supervisor_not_recorded',
    };

    return <String, Object?>{
      'contractVersion': _operabilityContractVersion,
      'command': commandName,
      'binary': <String, Object?>{
        'status': 'observed',
        'cli': <String, Object?>{
          'package': 'flutter_scout',
          'packageVersion': FlutterScoutCli.packageVersion,
          'executable': Platform.resolvedExecutable,
          'script': Platform.script.toString(),
          'dartRuntime': Platform.version,
          'processId': pid,
        },
        'helper': helperObserved
            ? <String, Object?>{
                'status': 'observed',
                'package': 'flutter_scout_helper',
                'packageVersion': observedHelperPackageVersion,
                'packageVersionStatus': observedHelperPackageVersion == null
                    ? 'unavailable'
                    : 'observed',
                if (observedHelperPackageVersion == null)
                  'reason': 'helper_package_version_not_reported',
              }
            : const <String, Object?>{
                'status': 'unavailable',
                'package': 'flutter_scout_helper',
                'packageVersion': null,
                'packageVersionStatus': 'unavailable',
                'reason': 'running_helper_not_observed',
              },
      },
      'protocol': <String, Object?>{
        'status': compatible == null
            ? 'unavailable'
            : compatible
            ? 'compatible'
            : 'incompatible',
        'cliSupported': const <String, Object?>{
          'schemaVersion': _scoutCliSchemaVersion,
          'minimum': _scoutCliProtocolMin,
          'maximum': _scoutCliProtocolMax,
          'capabilities': _scoutCliProtocolCapabilities,
        },
        'helperObserved': helperObserved
            ? <String, Object?>{
                'schemaVersion': _nullableNonNegativeInt(
                  helperProtocol?['schemaVersion'] ?? legacy['schemaVersion'],
                ),
                'protocolVersion': helperVersion,
                'minimum': helperMin,
                'maximum': helperMax,
                'capabilities': helperCapabilities,
              }
            : const <String, Object?>{
                'status': 'unavailable',
                'reason': 'helper_protocol_not_observed',
              },
        'negotiated': <String, Object?>{
          'status': compatible == null
              ? 'unavailable'
              : compatible
              ? 'compatible'
              : 'incompatible',
          'selectedVersion': negotiatedVersion,
          'capabilities': negotiatedCapabilities,
        },
      },
      'session': <String, Object?>{
        'status': sessionObserved ? 'observed' : 'unavailable',
        'name': session?['name'] ?? meta?['name'],
        'mode': sessionMode,
        'state': session?['state'] ?? meta?['state'],
        'runId': resolvedRunId,
        'project': meta?['project'],
        'sourceIdentity':
            sourceIdentity ??
            const <String, Object?>{
              'status': 'unavailable',
              'reason': 'launch_source_identity_not_recorded',
            },
        if (!sessionObserved) 'reason': 'session_identity_not_recorded',
      },
      'device': deviceInfo == null
          ? <String, Object?>{
              'status': 'unavailable',
              'requestedOrRecordedId': legacy['device'] ?? meta?['device'],
              'reason': 'resolved_device_identity_not_recorded',
            }
          : <String, Object?>{
              'status': 'observed',
              'id': deviceInfo['id'],
              'name': deviceInfo['name'],
              'platform': deviceInfo['platform'],
              'category': deviceInfo['category'],
              'emulator': deviceInfo['emulator'],
              'capabilities': deviceInfo['capabilities'],
            },
      'app': <String, Object?>{
        'reachability': reachabilityObserved
            ? appReachable
                  ? 'reachable'
                  : 'unreachable'
            : 'unavailable',
        'helperExtension': helperObserved ? 'registered' : 'unavailable',
      },
      'runnerOwnership': ownership,
      'supervisor': supervisor,
      'runtime': <String, Object?>{
        'status': runtimeId != null || generation != null
            ? 'observed'
            : 'unavailable',
        'runId': resolvedRunId,
        'runtimeInstanceId': runtimeId,
        'stateGeneration': generation,
        'snapshotId': runtimeIdentity?['snapshotId'],
        'screen': runtimeObservation?['screen'],
        'vmServiceEndpoint': vmEndpoint,
        if (runtimeId == null && generation == null)
          'reason': 'runtime_identity_not_observed',
      },
      'artifacts': artifactFacts,
      'actionState': actionState,
      'recordingState': <String, Object?>{
        ...recordingState,
        'store': artifactFacts['recordings'],
      },
      'sourceFreshness': sourceFreshness,
      'prioritizedRecoveryAction': recovery,
      // Compatibility aliases retained for existing v1 consumers.
      'processOwnership': ownership,
      'vm': <String, Object?>{
        'uriAvailable': _safeResponseVmUriAvailable(),
        'reachable': reachabilityObserved ? appReachable : null,
        'runtimeInstanceId': runtimeId,
        'stateGeneration': generation,
        'endpoint': vmEndpoint,
      },
      'logs': artifactFacts['logs'],
      'capture': <String, Object?>{
        'status': helperObserved
            ? inAppCaptureObserved
                  ? 'available'
                  : 'capability_not_observed'
            : 'unavailable',
        'capabilityObserved': inAppCaptureObserved,
      },
    };
  }

  Map<String, Object?>? _operabilityMap(Object? value) => value is Map
      ? <String, Object?>{
          for (final entry in value.entries) entry.key.toString(): entry.value,
        }
      : null;

  Map<String, Object?> _operabilityArtifactFacts() {
    final logPath = _logFile;
    final recordingsPath = p.join(_sessionDir.path, 'recordings');
    final evidencePath = p.join(_sessionDir.path, 'evidence');
    return <String, Object?>{
      'logs': <String, Object?>{
        ..._operabilityPath(logPath, directory: false),
        'cursor': _safeCurrentLogCursor(),
      },
      'recordings': _operabilityPath(recordingsPath, directory: true),
      'evidence': <String, Object?>{
        ..._operabilityPath(evidencePath, directory: true),
        'indexPath': p.join(evidencePath, 'index.json'),
      },
      'events': <String, Object?>{
        ..._operabilityPath(_eventsFile, directory: false),
        'cursorAddressable': true,
      },
    };
  }

  Map<String, Object?> _operabilityPath(
    String path, {
    required bool directory,
  }) {
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      final expected = directory
          ? FileSystemEntityType.directory
          : FileSystemEntityType.file;
      return <String, Object?>{
        'status': type == FileSystemEntityType.notFound
            ? 'absent'
            : type == expected
            ? 'available'
            : 'unexpected_filesystem_object',
        'path': path,
        'exists': type != FileSystemEntityType.notFound,
      };
    } catch (_) {
      return <String, Object?>{
        'status': 'unavailable',
        'path': path,
        'exists': null,
        'reason': 'filesystem_identity_probe_failed',
      };
    }
  }

  Map<String, Object?> _operabilityOwnership({
    required String? mode,
    required Map<String, dynamic>? meta,
    required Map<String, Object?>? session,
    required Map<String, Object?>? hotUpdate,
  }) {
    if (mode == 'attach_only') {
      return <String, Object?>{
        'status': 'not_owned',
        'mode': mode,
        'pid': null,
        'proof': 'attach_preserves_external_process_ownership',
      };
    }
    if (mode != 'scout_owned_flutter_run') {
      return <String, Object?>{
        'status': 'unavailable',
        'mode': mode,
        'pid': session?['pid'] ?? _readPid(),
        'proof': null,
        'reason': 'owned_runner_not_recorded',
      };
    }
    final proof = _nonEmptyString(hotUpdate?['ownershipProof']);
    return <String, Object?>{
      'status': proof == 'exact_process_identity' ? 'verified' : 'unverified',
      'mode': mode,
      'pid': session?['pid'] ?? _readPid(),
      'proof':
          proof ??
          (meta?['processIdentity'] is Map
              ? 'recorded_identity_not_revalidated_for_this_response'
              : null),
      'processIdentityRecorded': meta?['processIdentity'] is Map,
      if (proof != 'exact_process_identity')
        'reason': 'exact_live_process_identity_not_proven',
    };
  }

  Map<String, Object?> _operabilityRecovery({
    required String commandName,
    required Map<String, Object?>? structuredError,
    required bool appReachable,
    required bool reachabilityObserved,
    required bool? compatible,
    required Map<String, Object?> ownership,
    required Map<String, Object?> sourceFreshness,
    required Map<String, Object?> actionState,
  }) {
    if (compatible == false) {
      return const <String, Object?>{
        'status': 'recommended',
        'priority': 1,
        'action': 'flutter-scout doctor',
        'reason': 'helper_protocol_incompatible',
      };
    }
    if (structuredError != null) {
      return <String, Object?>{
        'status': 'recommended',
        'priority': 1,
        'action': 'flutter-scout doctor',
        'reason': structuredError['code'] ?? 'command_failed',
      };
    }
    if (reachabilityObserved && !appReachable) {
      return const <String, Object?>{
        'status': 'recommended',
        'priority': 1,
        'action':
            'flutter-scout ensure --device <simulator-id> --project <path>',
        'reason': 'app_unreachable',
      };
    }
    if (!reachabilityObserved && commandName == 'health') {
      return const <String, Object?>{
        'status': 'recommended',
        'priority': 1,
        'action': 'flutter-scout status',
        'reason': 'app_reachability_not_observed',
      };
    }
    if (ownership['status'] == 'unverified' ||
        ownership['status'] == 'unavailable') {
      return const <String, Object?>{
        'status': 'recommended',
        'priority': 1,
        'action': 'flutter-scout status',
        'reason': 'runner_ownership_unverified',
      };
    }
    if (sourceFreshness['status'] == 'mismatch') {
      return const <String, Object?>{
        'status': 'recommended',
        'priority': 1,
        'action':
            'flutter-scout launch --replace --device <simulator-id> --project <path>',
        'reason': 'loaded_source_mismatch',
      };
    }
    if (sourceFreshness['status'] == 'stale_runtime') {
      return const <String, Object?>{
        'status': 'recommended',
        'priority': 1,
        'action': 'flutter-scout reload',
        'reason': 'source_verification_scoped_to_replaced_runtime',
      };
    }
    if (actionState['status'] == 'held_drag_active') {
      return const <String, Object?>{
        'status': 'recommended',
        'priority': 1,
        'action': 'flutter-scout drag-status',
        'reason': 'held_drag_exclusively_owns_mutation_channel',
      };
    }
    return const <String, Object?>{
      'status': 'not_required',
      'priority': null,
      'action': null,
      'reason': null,
    };
  }

  Map<String, dynamic> _persistHotUpdateOperability(
    Map<String, dynamic> result,
  ) {
    final meta = _readSessionMeta();
    if (meta == null) {
      return <String, dynamic>{
        ...result,
        'operabilityPersistence': const <String, Object?>{
          'status': 'unavailable',
          'reason': 'session_metadata_unavailable',
        },
      };
    }
    final source = _operabilityMap(result['sourceVerification']);
    final after = _operabilityMap(result['after']);
    final safeSource = source == null
        ? const <String, Object?>{
            'status': 'unavailable',
            'reason': 'source_verification_not_reached',
          }
        : <String, Object?>{
            'status': source['status'],
            if (source['reason'] != null)
              'reason': _redactSensitiveLogText(source['reason'].toString()),
            for (final key in const <String>[
              'files',
              'verified',
              'mismatched',
              'notLoaded',
              'skipped',
            ])
              if (source[key] is List)
                '${key}Count': min((source[key] as List).length, 1000000),
          };
    try {
      _writeSessionMeta(<String, Object?>{
        ...meta,
        'lastHotUpdate': <String, Object?>{
          'observedAt': DateTime.now().toUtc().toIso8601String(),
          'action': result['action'],
          'ok': result['ok'] == true,
          'runId': _currentRunIdFromSession(),
          'dispatch': result['dispatch'],
          'method': result['method'],
          'appReachable': result['appReachable'] ?? after?['ok'],
          'runtimeInstanceId': after?['runtimeInstanceId'],
          'stateGeneration': after?['stateGeneration'],
          'sourceVerification': safeSource,
        },
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
      return <String, dynamic>{
        ...result,
        'operabilityPersistence': const <String, Object?>{
          'status': 'persisted',
          'path': 'session_metadata.lastHotUpdate',
        },
      };
    } catch (_) {
      return <String, dynamic>{
        ...result,
        'operabilityPersistence': const <String, Object?>{
          'status': 'unavailable',
          'reason': 'session_metadata_write_failed',
        },
      };
    }
  }
}
