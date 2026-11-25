import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

/// Runtime permission prompts for system-dialog verification. Each Request
/// button asks the platform for one permission, which shows the native
/// prompt above Flutter; the status line shows the platform's answer. The
/// channel is implemented in ios/Runner/AppDelegate.swift and
/// android/.../MainActivity.kt, with no plugin dependency.
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MaterialApp(home: SystemDialogsScreen()));
}

const _channel = MethodChannel('scout_test_app/permissions');
const _kinds = ['camera', 'microphone', 'notifications'];

class SystemDialogsScreen extends StatefulWidget {
  const SystemDialogsScreen({super.key});

  @override
  State<SystemDialogsScreen> createState() => _SystemDialogsScreenState();
}

class _SystemDialogsScreenState extends State<SystemDialogsScreen>
    with WidgetsBindingObserver {
  final Map<String, String> _status = {};
  final Map<String, String> _lastRequest = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // A permission granted outside the app (simctl privacy, pm grant) shows
  // when the app becomes active again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    for (final kind in _kinds) {
      String status;
      try {
        status = await _channel.invokeMethod<String>('status', kind) ?? '?';
      } on Object catch (error) {
        status = 'error: $error';
      }
      if (mounted) setState(() => _status[kind] = status);
    }
  }

  Future<void> _request(String kind) async {
    setState(() => _lastRequest[kind] = 'requesting');
    String result;
    try {
      result = await _channel.invokeMethod<String>('request', kind) ?? '?';
    } on Object catch (error) {
      result = 'error: $error';
    }
    if (!mounted) return;
    setState(() {
      _lastRequest[kind] = result;
      _status[kind] = result;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('System dialogs')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final kind in _kinds)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$kind: ${_status[kind] ?? 'unknown'}'),
                  if (_lastRequest[kind] != null)
                    Text('Last $kind request: ${_lastRequest[kind]}'),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: () => _request(kind),
                    child: Text('Request $kind'),
                  ),
                ],
              ),
            ),
          ),
        TextButton(onPressed: _refresh, child: const Text('Refresh status')),
      ],
    ),
  );
}
