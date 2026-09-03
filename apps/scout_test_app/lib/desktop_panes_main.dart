import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

/// Desktop pane fixture: local surfaces must not lock their sibling navigator.
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const DesktopPanesApp());
}

class DesktopPanesApp extends StatefulWidget {
  const DesktopPanesApp({super.key});

  @override
  State<DesktopPanesApp> createState() => _DesktopPanesAppState();
}

class _DesktopPanesAppState extends State<DesktopPanesApp> {
  final _rootNavigator = GlobalKey<NavigatorState>();
  final _detailNavigator = GlobalKey<NavigatorState>();
  final _backCount = ValueNotifier(0);
  final _detailCount = ValueNotifier(0);

  @override
  void dispose() {
    _backCount.dispose();
    _detailCount.dispose();
    super.dispose();
  }

  void _confirm({required bool global}) => showDialog<void>(
    context: _detailNavigator.currentState!.context,
    useRootNavigator: global,
    builder: (context) => AlertDialog(
      title: Text(global ? 'Confirm all panes' : 'Confirm template'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close confirmation'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _rootNavigator,
    home: Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 240,
            child: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: Column(
                    children: [
                      TextButton(
                        onPressed: () => _backCount.value++,
                        child: const Text('Back'),
                      ),
                      ValueListenableBuilder(
                        valueListenable: _backCount,
                        builder: (_, count, _) => Text('Back count: $count'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Navigator(
              key: _detailNavigator,
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: DraggableScrollableSheet(
                    initialChildSize: 1,
                    builder: (_, controller) => Material(
                      child: ListView(
                        controller: controller,
                        children: [
                          const Text('Template'),
                          TextButton(
                            onPressed: () => _detailCount.value++,
                            child: const Text('Detail action'),
                          ),
                          ValueListenableBuilder(
                            valueListenable: _detailCount,
                            builder: (_, count, _) =>
                                Text('Detail count: $count'),
                          ),
                          TextButton(
                            onPressed: () => _confirm(global: false),
                            child: const Text('Open pane dialog'),
                          ),
                          TextButton(
                            onPressed: () => _confirm(global: true),
                            child: const Text('Open root dialog'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
