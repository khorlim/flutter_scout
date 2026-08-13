part of 'flutter_scout_cli.dart';

// part: detached ownership of Scout-started Flutter tool processes.

extension _CliSupervisor on FlutterScoutCli {
  Future<String> _resolveFlutterExecutable() async {
    final result = await Process.run('which', ['flutter']);
    final resolved = '${result.stdout}'.trim();
    if (result.exitCode == 0 && resolved.isNotEmpty) return resolved;
    throw const ScoutCliException(
      'flutter_executable_not_found',
      'Flutter Scout could not resolve the Flutter executable before '
          'starting the detached runner.',
    );
  }

  Future<_RunnerSupervisor> _startFlutterRunnerSupervisor({
    required String configFile,
    required String runId,
    required String outputFile,
  }) async {
    if (Platform.isMacOS &&
        Platform.environment['FLUTTER_SCOUT_DISABLE_LAUNCHD'] != '1') {
      try {
        return await _startLaunchdRunnerSupervisor(
          configFile: configFile,
          runId: runId,
          outputFile: outputFile,
        );
      } catch (error) {
        final writer = _LockedLogWriter(outputFile);
        await writer.write(
          '[${DateTime.now().toUtc().toIso8601String()}] '
          '[flutter_scout] launchd supervisor unavailable; using detached '
          'worker: ${_redactSensitiveLogText(error.toString())}',
        );
        await writer.close();
      }
    }

    final process = await Process.start(Platform.resolvedExecutable, [
      Platform.script.toFilePath(),
      'flutter-run-worker',
      '--config',
      configFile,
    ], mode: ProcessStartMode.detached);
    return _RunnerSupervisor.detached(process);
  }

  Future<_RunnerSupervisor> _startLaunchdRunnerSupervisor({
    required String configFile,
    required String runId,
    required String outputFile,
  }) async {
    final uidResult = await Process.run('id', ['-u']);
    if (uidResult.exitCode != 0) {
      throw ScoutCliException(
        'launchd_uid_unavailable',
        'Could not resolve the current macOS user id: ${uidResult.stderr}',
      );
    }
    final uid = '${uidResult.stdout}'.trim();
    if (!RegExp(r'^\d+$').hasMatch(uid)) {
      throw const ScoutCliException(
        'launchd_uid_invalid',
        'macOS returned an invalid user id for the runner supervisor.',
      );
    }
    final safeRunId = runId.replaceAll(RegExp(r'[^A-Za-z0-9.-]'), '-');
    final label = 'dev.flutter-scout.runner.$safeRunId';
    final domain = 'gui/$uid';
    final plistFile = File(
      p.join(p.dirname(configFile), 'flutter_runner.plist'),
    );
    plistFile.writeAsStringSync(
      _launchdRunnerPlist(
        label: label,
        configFile: configFile,
        outputFile: outputFile,
      ),
      flush: true,
    );

    final bootstrap = await Process.run('launchctl', [
      'bootstrap',
      domain,
      plistFile.path,
    ]);
    if (bootstrap.exitCode != 0) {
      throw ScoutCliException(
        'launchd_bootstrap_failed',
        'Could not start the macOS runner supervisor: '
            '${bootstrap.stderr.toString().trim()}',
      );
    }

    int? workerPid;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      workerPid = await _launchdServicePid(domain: domain, label: label);
      if (workerPid != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return _RunnerSupervisor.launchd(
      domain: domain,
      label: label,
      plistFile: plistFile.path,
      workerPid: workerPid,
    );
  }

  String _launchdRunnerPlist({
    required String label,
    required String configFile,
    required String outputFile,
  }) {
    final arguments = <String>[
      Platform.resolvedExecutable,
      Platform.script.toFilePath(),
      'flutter-run-worker',
      '--config',
      configFile,
    ];
    final argumentXml = arguments
        .map((value) => '    <string>${_xmlEscape(value)}</string>')
        .join('\n');
    final path =
        Platform.environment['PATH'] ??
        '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin';
    final home = Platform.environment['HOME'];
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${_xmlEscape(label)}</string>
  <key>ProgramArguments</key>
  <array>
$argumentXml
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${_xmlEscape(path)}</string>
${home == null || home.isEmpty ? '' : '    <key>HOME</key>\n    <string>${_xmlEscape(home)}</string>\n'}  </dict>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Background</string>
  <key>ThrottleInterval</key>
  <integer>2</integer>
  <key>StandardOutPath</key>
  <string>${_xmlEscape(outputFile)}</string>
  <key>StandardErrorPath</key>
  <string>${_xmlEscape(outputFile)}</string>
</dict>
</plist>
''';
  }

  String _xmlEscape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  Future<int?> _launchdServicePid({
    required String domain,
    required String label,
  }) async {
    final result = await Process.run('launchctl', ['print', '$domain/$label']);
    if (result.exitCode != 0) return null;
    final match = RegExp(
      r'^\s*pid\s*=\s*(\d+)\s*$',
      multiLine: true,
    ).firstMatch('${result.stdout}');
    return int.tryParse(match?.group(1) ?? '');
  }

  Future<bool> _runnerSupervisorAlive(_RunnerSupervisor supervisor) async {
    if (supervisor.type == 'launchd') {
      final domain = supervisor.domain;
      final label = supervisor.label;
      if (domain == null || label == null) return false;
      final result = await Process.run('launchctl', [
        'print',
        '$domain/$label',
      ]);
      return result.exitCode == 0;
    }
    final workerPid = supervisor.workerPid;
    return workerPid != null && await _processExists(workerPid);
  }

  List<StreamSubscription<ProcessSignal>> _installRunnerSignalHandlers(
    _RunnerSupervisor supervisor,
  ) {
    void stopForInterrupt(ProcessSignal signal) {
      final domain = supervisor.domain;
      final label = supervisor.label;
      if (supervisor.type == 'launchd' && domain != null && label != null) {
        unawaited(Process.run('launchctl', ['bootout', '$domain/$label']));
      } else {
        supervisor.process?.kill();
      }
      _deleteFileIfExists(_pidFile);
      _writeProgress('stopped_child_process', {
        'signal': signal.toString(),
        'pid': ?supervisor.workerPid,
        'supervisor': supervisor.type,
      });
    }

    // SIGINT is an explicit Ctrl-C cancellation. SIGTERM commonly represents
    // the owning terminal or agent session being cleaned up; the detached
    // supervisor must survive that event and keep `flutter run` available.
    return [ProcessSignal.sigint.watch().listen(stopForInterrupt)];
  }

  Future<Map<String, Object?>> _stopRunnerSupervisor(
    Map<String, dynamic>? meta,
  ) async {
    final supervisor = meta?['supervisor'];
    if (!Platform.isMacOS || supervisor is! Map) {
      return const {'configured': false, 'stopped': false};
    }
    final type = supervisor['type']?.toString();
    final domain = supervisor['domain']?.toString();
    final label = supervisor['label']?.toString();
    final plistFile = supervisor['plistFile']?.toString();
    final trusted =
        type == 'launchd' &&
        domain != null &&
        RegExp(r'^gui/\d+$').hasMatch(domain) &&
        label != null &&
        label.startsWith('dev.flutter-scout.runner.') &&
        plistFile != null &&
        p.isWithin(_sessionDir.path, plistFile);
    if (!trusted) {
      return const {
        'configured': true,
        'stopped': false,
        'reason': 'supervisor_identity_mismatch',
      };
    }
    final result = await Process.run('launchctl', [
      'bootout',
      '$domain/$label',
    ]);
    final message = '${result.stderr}'.trim();
    final alreadyStopped =
        result.exitCode != 0 &&
        (message.contains('Could not find service') ||
            message.contains('No such process'));
    return {
      'configured': true,
      'stopped': result.exitCode == 0 || alreadyStopped,
      'label': label,
      if (result.exitCode != 0 && !alreadyStopped) 'error': message,
    };
  }
}

class _RunnerSupervisor {
  const _RunnerSupervisor._({
    required this.type,
    this.process,
    this.domain,
    this.label,
    this.plistFile,
    this.workerPid,
  });

  factory _RunnerSupervisor.detached(Process process) => _RunnerSupervisor._(
    type: 'detached_process',
    process: process,
    workerPid: process.pid,
  );

  factory _RunnerSupervisor.launchd({
    required String domain,
    required String label,
    required String plistFile,
    required int? workerPid,
  }) => _RunnerSupervisor._(
    type: 'launchd',
    domain: domain,
    label: label,
    plistFile: plistFile,
    workerPid: workerPid,
  );

  final String type;
  final Process? process;
  final String? domain;
  final String? label;
  final String? plistFile;
  final int? workerPid;

  Map<String, Object?> toJson() => {
    'type': type,
    if (domain != null) 'domain': domain,
    if (label != null) 'label': label,
    if (plistFile != null) 'plistFile': plistFile,
    if (workerPid != null) 'workerPid': workerPid,
  };
}
