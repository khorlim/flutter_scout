import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

/// Reproduces eager scroll content painted beneath a fixed footer's region.
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MaterialApp(home: ClippedRevealScreen()));
}

class ClippedRevealScreen extends StatefulWidget {
  const ClippedRevealScreen({super.key});

  @override
  State<ClippedRevealScreen> createState() => _ClippedRevealScreenState();
}

class _ClippedRevealScreenState extends State<ClippedRevealScreen> {
  var opened = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 350,
          height: 420,
          child: SingleChildScrollView(
            key: const ValueKey('outer-scroll'),
            child: Column(
              children: [
                SizedBox(
                  height: 300,
                  child: SingleChildScrollView(
                    key: const ValueKey('inner-scroll'),
                    child: Column(
                      children: [
                        const SizedBox(
                          height: 100,
                          child: Center(child: Text('Clipped reveal fixture')),
                        ),
                        const SizedBox(height: 250),
                        SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            key: const ValueKey('clipped-form'),
                            onPressed: () => setState(() => opened = true),
                            child: const Text('Form'),
                          ),
                        ),
                        const SizedBox(height: 250),
                      ],
                    ),
                  ),
                ),
                Container(
                  height: 100,
                  width: double.infinity,
                  color: Colors.blue.shade100,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(opened ? 'Form opened' : 'Fixed footer'),
                      TextButton(
                        key: const ValueKey('open-modal'),
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Blocking confirmation'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Close confirmation'),
                              ),
                            ],
                          ),
                        ),
                        child: const Text('Open modal'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 300),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
