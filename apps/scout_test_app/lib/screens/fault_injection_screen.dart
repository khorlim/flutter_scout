import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../widgets/test_app_design.dart';

/// Deterministic, labelled hard-signal fixtures for Scout's runtime and log
/// attribution tests. Every destructive fixture requires a second explicit
/// confirmation so an exploratory agent cannot terminate its own target by
/// selecting a generic button.
class FaultInjectionScreen extends StatefulWidget {
  const FaultInjectionScreen({super.key});

  @override
  State<FaultInjectionScreen> createState() => _FaultInjectionScreenState();
}

class _FaultInjectionScreenState extends State<FaultInjectionScreen> {
  static const double _imageFixtureExtent = 80;
  static const double _overflowViewportWidth = 40;
  static const double _overflowContentWidth = 320;

  bool _showErrorSurface = false;
  bool _showOverflow = false;
  bool _showBrokenImage = false;
  String _lastFixture = 'none';

  void _record(String fixture) {
    if (!mounted) return;
    setState(() => _lastFixture = fixture);
  }

  void _frameworkError() {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: StateError('SCOUT_FAULT_FRAMEWORK'),
        library: 'scout_fault_lab',
        context: ErrorDescription('running the framework-error fixture'),
      ),
    );
    _record('framework_error');
  }

  void _platformError() {
    final handler = ui.PlatformDispatcher.instance.onError;
    if (handler == null) {
      _record('platform_handler_unavailable');
      return;
    }
    handler(StateError('SCOUT_FAULT_PLATFORM'), StackTrace.current);
    _record('platform_error');
  }

  void _highSeverityLog() {
    developer.log(
      'SCOUT_FAULT_HIGH_SEVERITY application invariant failed',
      name: 'scout.fault_lab',
      level: 1000,
    );
    _record('high_severity_log');
  }

  void _permissionDeniedLog() {
    developer.log(
      'SCOUT_FAULT_PERMISSION camera permission denied',
      name: 'scout.fault_lab',
      level: 900,
    );
    _record('permission_denied');
  }

  void _requestFailureLog() {
    developer.log(
      'SCOUT_FAULT_REQUEST HTTP request failed with status 503',
      name: 'scout.fault_lab',
      level: 900,
    );
    _record('request_failure');
  }

  void _buildRejectionLog() {
    debugPrint(
      'SCOUT_FAULT_HOT_UPDATE Hot reload was rejected after fixing the above error',
    );
    _record('hot_update_rejected');
  }

  Future<void> _confirmAndTerminate() async {
    final confirmed = await _confirmDestructiveFixture(
      title: 'Terminate fixture app?',
      explanation:
          'This intentionally exits only the Scout Test App process so the '
          'lifecycle oracle can verify process-death reporting and recovery.',
      cancelKey: const ValueKey('fault_cancel_terminate'),
      confirmKey: const ValueKey('fault_confirm_terminate'),
      confirmLabel: 'Terminate test app',
    );
    if (confirmed == true) exit(86);
  }

  Future<void> _confirmAndDisconnectVmService() async {
    final confirmed = await _confirmDestructiveFixture(
      title: 'Disconnect VM service?',
      explanation:
          'This intentionally disables the fixture VM-service web server. A '
          'fresh launch is required before Scout can reconnect.',
      cancelKey: const ValueKey('fault_cancel_disconnect'),
      confirmKey: const ValueKey('fault_confirm_disconnect'),
      confirmLabel: 'Disconnect fixture',
    );
    if (confirmed != true) return;
    _record('vm_service_disconnecting');
    await developer.Service.controlWebServer(enable: false);
  }

  Future<bool?> _confirmDestructiveFixture({
    required String title,
    required String explanation,
    required Key cancelKey,
    required Key confirmKey,
    required String confirmLabel,
  }) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(explanation),
      actions: [
        TextButton(
          key: cancelKey,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: confirmKey,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fault injection')),
      body: ListView(
        key: const ValueKey('fault_lab_scroll'),
        padding: TestAppLayout.screenPadding,
        children: [
          Text(
            'Last fixture: $_lastFixture',
            key: const ValueKey('fault_lab_status'),
          ),
          const SizedBox(height: TestAppLayout.contentGap),
          _FaultLabSection(
            title: 'Runtime hooks',
            children: [
              FilledButton.tonal(
                key: const ValueKey('fault_framework_error'),
                onPressed: _frameworkError,
                child: const Text('Flutter framework error'),
              ),
              FilledButton.tonal(
                key: const ValueKey('fault_platform_error'),
                onPressed: _platformError,
                child: const Text('Platform dispatcher error'),
              ),
              FilledButton.tonal(
                key: const ValueKey('fault_error_widget'),
                onPressed: () => setState(() {
                  _showErrorSurface = !_showErrorSurface;
                  _lastFixture = 'error_widget';
                }),
                child: const Text('Toggle ErrorWidget surface'),
              ),
              FilledButton.tonal(
                key: const ValueKey('fault_render_overflow'),
                onPressed: () => setState(() {
                  _showOverflow = !_showOverflow;
                  _lastFixture = 'render_overflow';
                }),
                child: const Text('Toggle RenderFlex overflow'),
              ),
              FilledButton.tonal(
                key: const ValueKey('fault_image_failure'),
                onPressed: () => setState(() {
                  _showBrokenImage = !_showBrokenImage;
                  _lastFixture = 'image_failure';
                }),
                child: const Text('Toggle image failure'),
              ),
            ],
          ),
          const Divider(height: TestAppLayout.sectionGap),
          _FaultLabSection(
            title: 'Owned log signals',
            children: [
              OutlinedButton(
                key: const ValueKey('fault_high_severity_log'),
                onPressed: _highSeverityLog,
                child: const Text('High-severity app log'),
              ),
              OutlinedButton(
                key: const ValueKey('fault_permission_denied'),
                onPressed: _permissionDeniedLog,
                child: const Text('Permission denied'),
              ),
              OutlinedButton(
                key: const ValueKey('fault_request_failure'),
                onPressed: _requestFailureLog,
                child: const Text('Request failure'),
              ),
              OutlinedButton(
                key: const ValueKey('fault_hot_update_rejected'),
                onPressed: _buildRejectionLog,
                child: const Text('Hot-update rejection'),
              ),
            ],
          ),
          const Divider(height: TestAppLayout.sectionGap),
          _FaultLabSection(
            title: 'Destructive lifecycle fixtures (confirmation required)',
            children: [
              OutlinedButton(
                key: const ValueKey('fault_terminate_process'),
                onPressed: _confirmAndTerminate,
                child: const Text('Test app process death'),
              ),
              OutlinedButton(
                key: const ValueKey('fault_disconnect_vm_service'),
                onPressed: _confirmAndDisconnectVmService,
                child: const Text('VM-service disconnect'),
              ),
            ],
          ),
          const SizedBox(height: TestAppLayout.sectionGap),
          if (_showErrorSurface)
            ErrorWidget.withDetails(
              message: 'SCOUT_FAULT_ERROR_WIDGET visible error surface',
            ),
          if (_showOverflow)
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                key: const ValueKey('fault_overflow_surface'),
                width: _overflowViewportWidth,
                child: Row(
                  children: const [
                    SizedBox(
                      width: _overflowContentWidth,
                      child: Text('SCOUT_FAULT_OVERFLOW'),
                    ),
                  ],
                ),
              ),
            ),
          if (_showBrokenImage)
            Image.network(
              'http://127.0.0.1:1/scout-fault-image.png',
              key: const ValueKey('fault_broken_image'),
              width: _imageFixtureExtent,
              height: _imageFixtureExtent,
              errorBuilder: (context, error, stackTrace) {
                developer.log(
                  'SCOUT_FAULT_IMAGE image loading failed: '
                  '${error.runtimeType}',
                  name: 'scout.fault_lab',
                  level: 1000,
                );
                return const Text(
                  'Image load failed',
                  key: ValueKey('fault_broken_image_fallback'),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _FaultLabSection extends StatelessWidget {
  const _FaultLabSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: TestAppLayout.compactGap),
        Wrap(
          spacing: TestAppLayout.compactGap,
          runSpacing: TestAppLayout.compactGap,
          children: children,
        ),
      ],
    );
  }
}
