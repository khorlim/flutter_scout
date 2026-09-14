import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/test_app_design.dart';

/// A deterministic concurrency probe, not a production app integration pattern.
/// Callback timestamps describe domain events, not first-pixel presentation.
class EyeHandProbeScreen extends StatefulWidget {
  const EyeHandProbeScreen({super.key, this.onEvent});

  final void Function(String event, int timestampMs)? onEvent;

  @override
  State<EyeHandProbeScreen> createState() => _EyeHandProbeScreenState();
}

class _EyeHandProbeScreenState extends State<EyeHandProbeScreen> {
  final List<Timer> _timers = [];
  final Map<String, int> _events = {};
  String _phase = 'Idle';
  String _notice = 'None';
  int _latePauses = 0;

  void _record(String name) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _events[name] = timestamp;
    widget.onEvent?.call(name, timestamp);
  }

  void _clearTimers() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
  }

  void _start(String mode) {
    _clearTimers();
    setState(() {
      _events.clear();
      _latePauses = 0;
      _phase = 'Working';
      _notice = 'None';
      _record('started');
    });
    if (mode != 'quiet') {
      _timers.add(
        Timer(const Duration(milliseconds: 1200), () {
          setState(() {
            _notice = 'Pause requested';
            _record('notice');
          });
        }),
      );
    }
    if (mode == 'flash') {
      _timers.add(
        Timer(const Duration(milliseconds: 2400), () {
          setState(() {
            _notice = 'None';
            _record('noticeCleared');
          });
        }),
      );
    }
    _timers.add(
      Timer(const Duration(seconds: 8), () {
        setState(() {
          _phase = 'Ready';
          _record('ready');
        });
      }),
    );
  }

  void _pause() {
    _clearTimers();
    setState(() {
      if (_phase == 'Ready') _latePauses++;
      _phase = 'Paused';
      _record('paused');
    });
  }

  @override
  void dispose() {
    _clearTimers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Eye-hand probe')),
      body: ListView(
        padding: TestAppLayout.screenPadding,
        children: [
          const Text(
            'Start work. Pause if a pause request appears, even briefly.',
          ),
          const SizedBox(height: TestAppLayout.contentGap),
          Text('Phase: $_phase'),
          Text('Notice: $_notice'),
          Text('Late pauses: $_latePauses'),
          const SizedBox(height: TestAppLayout.contentGap),
          for (final mode in ['quiet', 'hold', 'flash'])
            FilledButton.tonal(
              key: ValueKey('probe_start_$mode'),
              onPressed: _phase == 'Working' ? null : () => _start(mode),
              child: Text('Start $mode'),
            ),
          FilledButton(
            key: const ValueKey('probe_pause'),
            onPressed: _phase == 'Working' || _phase == 'Ready' ? _pause : null,
            child: const Text('Pause work'),
          ),
          for (final event in _events.entries)
            Text('Event ${event.key}: ${event.value}'),
        ],
      ),
    );
  }
}
