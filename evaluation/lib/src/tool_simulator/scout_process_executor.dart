import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class ScoutCommandResult {
  const ScoutCommandResult({
    required this.arguments,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.elapsedMs,
    required this.timedOut,
    required this.outputTruncated,
  });

  final List<String> arguments;
  final int exitCode;
  final String stdout;
  final String stderr;
  final int elapsedMs;
  final bool timedOut;
  final bool outputTruncated;

  bool get succeeded => exitCode == 0 && !timedOut;

  Map<String, Object?> toToolEvent() => <String, Object?>{
    'type': 'scout_command',
    'arguments': List<String>.from(arguments),
    'exitCode': exitCode,
    'elapsedMs': elapsedMs,
    'timedOut': timedOut,
    'outputTruncated': outputTruncated,
    'stdout': stdout,
    'stderr': stderr,
  };
}

abstract interface class ScoutCommandExecutor {
  Future<ScoutCommandResult> attach({
    required String vmServiceUri,
    required Duration timeout,
  });

  Future<ScoutCommandResult> execute({
    required List<String> arguments,
    required Duration timeout,
  });
}

class ProcessScoutCommandExecutor implements ScoutCommandExecutor {
  ProcessScoutCommandExecutor({
    required this.workingDirectory,
    this.executable = 'flutter-scout',
    this.executableArguments = const <String>[],
    this.maxOutputBytes = 1024 * 1024,
  }) {
    if (!workingDirectory.existsSync()) {
      throw ArgumentError.value(
        workingDirectory.path,
        'workingDirectory',
        'does not exist',
      );
    }
    if (executable.trim().isEmpty) {
      throw ArgumentError.value(executable, 'executable');
    }
    if (maxOutputBytes < 1024) {
      throw ArgumentError.value(maxOutputBytes, 'maxOutputBytes');
    }
    final workingType = FileSystemEntity.typeSync(
      workingDirectory.path,
      followLinks: false,
    );
    if (workingType != FileSystemEntityType.directory) {
      throw ArgumentError.value(
        workingDirectory.path,
        'workingDirectory',
        'must be a real, non-symlink directory',
      );
    }
    if (!Platform.isWindows &&
        ((workingDirectory.statSync().mode & 0x1ff) & 0x3f) != 0) {
      throw ArgumentError.value(
        workingDirectory.path,
        'workingDirectory',
        'must be owner-only before it can receive protected input',
      );
    }
  }

  final Directory workingDirectory;
  final String executable;
  final List<String> executableArguments;
  final int maxOutputBytes;

  @override
  Future<ScoutCommandResult> attach({
    required String vmServiceUri,
    required Duration timeout,
  }) async {
    final uriBytes = utf8.encode(vmServiceUri);
    if (vmServiceUri.trim() != vmServiceUri ||
        uriBytes.isEmpty ||
        uriBytes.length > 4096 ||
        vmServiceUri.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw const FormatException(
        'VM service URI must be bounded printable text without whitespace.',
      );
    }
    final random = Random.secure();
    final nonce = List<int>.generate(
      16,
      (_) => random.nextInt(256),
      growable: false,
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final uriFile = File(
      '${workingDirectory.path}${Platform.pathSeparator}.scout_vm_uri_$nonce',
    );
    try {
      await uriFile.create(exclusive: true);
      await _makeOwnerOnly(uriFile);
      final handle = await uriFile.open(mode: FileMode.writeOnly);
      try {
        await handle.writeFrom(uriBytes);
        await handle.flush();
      } finally {
        await handle.close();
      }
      return await _run(
        <String>['attach', '--debug-url-file', uriFile.path],
        timeout,
        recordedArguments: const <String>[
          'attach',
          '--debug-url-file',
          '<protected-owner-only-file>',
        ],
      );
    } finally {
      if (await FileSystemEntity.type(uriFile.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await uriFile.delete();
      }
    }
  }

  @override
  Future<ScoutCommandResult> execute({
    required List<String> arguments,
    required Duration timeout,
  }) => _run(arguments, timeout);

  Future<ScoutCommandResult> _run(
    List<String> scoutArguments,
    Duration timeout, {
    List<String>? recordedArguments,
  }) async {
    if (timeout <= Duration.zero) {
      return ScoutCommandResult(
        arguments: List<String>.unmodifiable(
          recordedArguments ?? scoutArguments,
        ),
        exitCode: 124,
        stdout: '',
        stderr: 'Evaluator action deadline was already exhausted.',
        elapsedMs: 0,
        timedOut: true,
        outputTruncated: false,
      );
    }
    final stopwatch = Stopwatch()..start();
    final process = await Process.start(
      executable,
      <String>[...executableArguments, ...scoutArguments],
      workingDirectory: workingDirectory.path,
      mode: ProcessStartMode.normal,
    );
    final stdoutFuture = _collectBounded(process.stdout, maxOutputBytes);
    final stderrFuture = _collectBounded(process.stderr, maxOutputBytes);
    var timedOut = false;
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException catch (_) {
      timedOut = true;
      process.kill(ProcessSignal.sigterm);
      try {
        exitCode = await process.exitCode.timeout(
          const Duration(milliseconds: 250),
        );
      } on TimeoutException catch (_) {
        process.kill(ProcessSignal.sigkill);
        exitCode = await process.exitCode;
      }
    }
    final outputs = await Future.wait(<Future<_BoundedOutput>>[
      stdoutFuture,
      stderrFuture,
    ]);
    stopwatch.stop();
    return ScoutCommandResult(
      arguments: List<String>.unmodifiable(recordedArguments ?? scoutArguments),
      exitCode: timedOut ? 124 : exitCode,
      stdout: outputs[0].text,
      stderr: outputs[1].text,
      elapsedMs: stopwatch.elapsedMilliseconds,
      timedOut: timedOut,
      outputTruncated: outputs.any((output) => output.truncated),
    );
  }

  Future<void> _makeOwnerOnly(File file) async {
    if (Platform.isWindows) return;
    final result = await Process.run('/bin/chmod', <String>['600', file.path]);
    if (result.exitCode != 0 || ((await file.stat()).mode & 0x1ff) != 0x180) {
      throw StateError('Could not protect the evaluator VM URI file.');
    }
  }
}

class _BoundedOutput {
  const _BoundedOutput(this.text, this.truncated);

  final String text;
  final bool truncated;
}

Future<_BoundedOutput> _collectBounded(
  Stream<List<int>> stream,
  int limit,
) async {
  final bytes = <int>[];
  var truncated = false;
  await for (final chunk in stream) {
    final remaining = limit - bytes.length;
    if (remaining > 0) {
      bytes.addAll(chunk.length <= remaining ? chunk : chunk.take(remaining));
    }
    if (chunk.length > remaining) truncated = true;
  }
  return _BoundedOutput(utf8.decode(bytes, allowMalformed: true), truncated);
}
