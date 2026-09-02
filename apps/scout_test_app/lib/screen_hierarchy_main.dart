import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

/// Small real-tree fixture for nested screen orientation and modal isolation.
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MaterialApp(home: EditorScreen()));
}

class EditorScreen extends StatelessWidget {
  const EditorScreen({super.key});

  @override
  Widget build(BuildContext context) => const DetailsPage();
}

class DetailsPage extends StatelessWidget {
  const DetailsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Screen hierarchy fixture')),
    body: Center(
      child: FilledButton(
        key: const ValueKey('confirm_edit'),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Confirm edit'),
            actions: [
              TextButton(
                key: const ValueKey('close_confirmation'),
                onPressed: () => Navigator.pop(context),
                child: const Text('Close confirmation'),
              ),
            ],
          ),
        ),
        child: const Text('Confirm edit'),
      ),
    ),
  );
}
