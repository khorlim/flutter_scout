import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

/// Short-lived feedback an agent must still be able to confirm: a progress
/// capsule labelled "Data sync" that shows only a percentage and goes away
/// when the sync ends, and a "Saved Successfully" snackbar that disappears
/// within a second, shown a moment after Save like a server round trip. Also a plain name field and a PIN field, for typed input.
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MaterialApp(home: TransientFeedbackScreen()));
}

class TransientFeedbackScreen extends StatefulWidget {
  const TransientFeedbackScreen({super.key});

  @override
  State<TransientFeedbackScreen> createState() =>
      _TransientFeedbackScreenState();
}

class _TransientFeedbackScreenState extends State<TransientFeedbackScreen> {
  final _name = TextEditingController();
  final _pin = TextEditingController();
  Timer? _sync;
  int? _progress;
  int _saves = 0;

  void _startSync() {
    _sync?.cancel();
    setState(() => _progress = 0);
    _sync = Timer.periodic(const Duration(milliseconds: 400), (timer) {
      setState(() {
        final next = (_progress ?? 0) + 10;
        _progress = next > 100 ? null : next;
      });
      if (_progress == null) timer.cancel();
    });
  }

  Future<void> _save() async {
    setState(() => _saves++);
    // Like a server round trip: the toast shows after the tap has settled.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Saved Successfully'),
        duration: Duration(milliseconds: 700),
      ),
    );
  }

  @override
  void dispose() {
    _sync?.cancel();
    _name.dispose();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Transient feedback'),
      actions: [
        if (_progress != null)
          Semantics(
            label: 'Data sync',
            button: true,
            child: GestureDetector(
              onTap: () {},
              child: Container(
                margin: const EdgeInsets.only(right: 16),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.blue.shade100,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ExcludeSemantics(child: Text('$_progress%')),
              ),
            ),
          ),
      ],
    ),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton(onPressed: _startSync, child: const Text('Start sync')),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Customer name'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _pin,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Staff PIN'),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Save')),
          const SizedBox(height: 8),
          Text('Saves: $_saves'),
        ],
      ),
    ),
  );
}
