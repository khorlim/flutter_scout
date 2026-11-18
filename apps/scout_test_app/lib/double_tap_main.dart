import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

/// Double-tap targets: a button that counts presses (an impatient cashier on
/// Confirm Payment), and a Submit button that the first press replaces with
/// an Undo button at the same spot, so a second tap lands on something else.
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MaterialApp(home: DoubleTapScreen()));
}

class DoubleTapScreen extends StatefulWidget {
  const DoubleTapScreen({super.key});

  @override
  State<DoubleTapScreen> createState() => _DoubleTapScreenState();
}

class _DoubleTapScreenState extends State<DoubleTapScreen> {
  int _payments = 0;
  int _submits = 0;
  int _undos = 0;
  bool _submitted = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Double tap')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton(
            onPressed: () => setState(() => _payments++),
            child: const Text('Confirm Payment'),
          ),
          const SizedBox(height: 8),
          Text('Payments: $_payments'),
          const SizedBox(height: 32),
          SizedBox(
            height: 48,
            child: _submitted
                ? OutlinedButton(
                    onPressed: () => setState(() {
                      _undos++;
                      _submitted = false;
                    }),
                    child: const Text('Undo'),
                  )
                : FilledButton(
                    onPressed: () => setState(() {
                      _submits++;
                      _submitted = true;
                    }),
                    child: const Text('Submit'),
                  ),
          ),
          const SizedBox(height: 8),
          Text('Submits: $_submits, Undos: $_undos'),
        ],
      ),
    ),
  );
}
