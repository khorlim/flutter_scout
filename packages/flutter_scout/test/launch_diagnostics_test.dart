import 'package:flutter_scout/flutter_scout.dart';
import 'package:test/test.dart';

void main() {
  final cli = FlutterScoutCli();

  test('ps CPU times parse in every ps layout', () {
    expect(cli.debugParsePsCpuTime('0:01.50'), 1.5);
    expect(cli.debugParsePsCpuTime('12:03.00'), 723);
    expect(cli.debugParsePsCpuTime('1:00:00'), 3600);
    expect(cli.debugParsePsCpuTime('2-01:00:00'), 176400);
    expect(cli.debugParsePsCpuTime('garbage'), isNull);
  });

  test('process tree CPU includes every descendant of the runner', () {
    const ps = '''
  100     1   0:01.00
  200   100   1:00.00
  300   200   0:30.00
  400     1   9:00.00
''';
    expect(cli.debugProcessTreeCpuSeconds(ps, 100), 91);
    expect(cli.debugProcessTreeCpuSeconds(ps, 999), isNull);
  });

  test('a failed launch or ensure always names its cause', () {
    // A thrown launch step carries only its structured error.
    final rejected = cli.debugLaunchFailureReport({
      'messageType': 'response',
      'ok': false,
      'commandName': 'launch',
      'structuredError': {
        'code': 'flutter_runner_pid_not_found',
        'message': 'Flutter did not confirm its hot-update handlers.',
      },
    })!;
    expect(rejected['failureMode'], 'launch_error');
    expect(
      rejected['failureCause'],
      containsPair('cause', 'flutter_runner_pid_not_found'),
    );
    expect(
      rejected['line'],
      'Launch failed (launch_error, flutter_runner_pid_not_found): '
      'Flutter did not confirm its hot-update handlers.',
    );
    // A wait that set its own mode and cause keeps them.
    final waited = cli.debugLaunchFailureReport({
      'messageType': 'response',
      'ok': false,
      'commandName': 'ensure',
      'failureMode': 'helper_not_ready',
      'failureCause': {'cause': 'helper_extension_check_timeout'},
      'structuredError': {
        'code': 'helper_extension_check_timeout',
        'message': 'Launch failed (helper_not_ready): run status first.',
      },
    })!;
    expect(waited['failureMode'], 'helper_not_ready');
    expect(
      waited['line'],
      'Launch failed (helper_not_ready): run status first.',
    );
    for (final other in [
      {'messageType': 'response', 'ok': true, 'commandName': 'launch'},
      {'messageType': 'response', 'ok': false, 'commandName': 'status'},
    ]) {
      expect(cli.debugLaunchFailureReport(other), isNull);
    }
  });

  test('launch failures are classified from the runner log', () {
    Map<String, Object?>? classify(String line) =>
        cli.debugClassifyLaunchFailure([
          '[2026-10-16T06:51:00Z] [FLUTTER_STDOUT] $line',
        ]);
    expect(
      classify(
        "No supported devices found with name or id matching 'BD593483'.",
      )?['cause'],
      'device_unavailable',
    );
    expect(
      classify(
        'adb: failed to install app.apk: Failure [INSUFFICIENT_STORAGE]',
      )?['cause'],
      'install_failed_insufficient_storage',
    );
    expect(
      classify('FAILURE: Build failed with an exception.')?['cause'],
      'gradle_build_failed',
    );
    expect(
      classify("lib/main.dart:3:5: Error: Expected ';' after this.")?['cause'],
      'dart_compile_failed',
    );
    expect(
      classify(
        '[flutter_scout] macos_app_open_failed: LaunchServices could not open',
      )?['cause'],
      'macos_app_open_failed',
    );
    expect(classify('Building macOS application...'), isNull);
  });

  test('simulator state is read from simctl JSON', () {
    const json = '''
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[
  {"udid":"BD593483-0000-0000-0000-000000000001","state":"Shutdown"},
  {"udid":"BD593483-0000-0000-0000-000000000002","state":"Booted"}]}}''';
    expect(
      cli.debugSimulatorState(json, 'bd593483-0000-0000-0000-000000000001'),
      'Shutdown',
    );
    expect(
      cli.debugSimulatorState(json, 'BD593483-0000-0000-0000-000000000002'),
      'Booted',
    );
    expect(cli.debugSimulatorState(json, 'missing'), isNull);
  });
}
