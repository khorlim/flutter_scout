import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

/// Every input kind the "Scout is driving" overlay draws, on one screen: a
/// tap, a long press, a double tap, a right click, a slider drag, a scrolling
/// list, a plain text field, a PIN field, a keypad and a dialog to dismiss.
/// A dark-mode switch shows the overlay over light and dark apps.
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const DrivingOverlayApp());
}

class DrivingOverlayApp extends StatefulWidget {
  const DrivingOverlayApp({super.key});

  @override
  State<DrivingOverlayApp> createState() => _DrivingOverlayAppState();
}

class _DrivingOverlayAppState extends State<DrivingOverlayApp> {
  bool _dark = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.deepOrange),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.deepOrange,
      brightness: Brightness.dark,
    ),
    themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
    home: DrivingOverlayScreen(
      dark: _dark,
      onDarkChanged: (value) => setState(() => _dark = value),
    ),
  );
}

class DrivingOverlayScreen extends StatefulWidget {
  const DrivingOverlayScreen({
    super.key,
    required this.dark,
    required this.onDarkChanged,
  });

  final bool dark;
  final ValueChanged<bool> onDarkChanged;

  @override
  State<DrivingOverlayScreen> createState() => _DrivingOverlayScreenState();
}

class _DrivingOverlayScreenState extends State<DrivingOverlayScreen> {
  String _last = 'Nothing yet';
  int _saves = 0;
  double _volume = 20;
  String _amount = '';

  void _note(String value) => setState(() => _last = value);

  Future<void> _openDialog() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Discard draft?'),
      content: const Text('Dismiss this dialog to keep editing.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Keep'),
        ),
      ],
    ),
  );

  Future<void> _openMenu(Offset position) async {
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: const [
        PopupMenuItem(value: 'Copy', child: Text('Copy')),
        PopupMenuItem(value: 'Rename', child: Text('Rename')),
      ],
    );
    if (picked != null) _note('Menu: $picked');
  }

  Widget _tile(
    String label,
    IconData icon, {
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    VoidCallback? onDoubleTap,
    GestureTapDownCallback? onSecondaryTapDown,
  }) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      onDoubleTap: onDoubleTap,
      onSecondaryTapDown: onSecondaryTapDown,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [Icon(icon), const SizedBox(width: 16), Text(label)],
        ),
      ),
    ),
  );

  Widget _key(String key) => SizedBox(
    width: 56,
    height: 44,
    child: OutlinedButton(
      onPressed: () =>
          setState(() => _amount = key == 'C' ? '' : _amount + key),
      child: Text(key),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Driving overlay'),
      actions: [
        const Text('Dark'),
        Switch(value: widget.dark, onChanged: widget.onDarkChanged),
        const SizedBox(width: 12),
      ],
    ),
    body: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Last: $_last'),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () {
                  _saves++;
                  _note('Saved $_saves');
                },
                child: const Text('Save'),
              ),
              _tile(
                'Hold me',
                Icons.touch_app,
                onTap: () => _note('Tapped hold tile'),
                onLongPress: () => _note('Held'),
              ),
              _tile(
                'Double tap me',
                Icons.ads_click,
                onTap: () => _note('Tapped once'),
                onDoubleTap: () => _note('Double tapped'),
              ),
              _tile(
                'Right click me',
                Icons.mouse,
                onTap: () => _note('Left clicked'),
                onSecondaryTapDown: (details) =>
                    _openMenu(details.globalPosition),
              ),
              Slider(
                value: _volume,
                max: 100,
                label: 'Volume',
                onChanged: (value) => setState(() => _volume = value),
              ),
              Text('Volume: ${_volume.round()}'),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _openDialog,
                child: const Text('Open dialog'),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const TextField(
                  key: ValueKey('customer_name'),
                  decoration: InputDecoration(labelText: 'Customer name'),
                ),
                const TextField(
                  key: ValueKey('staff_pin'),
                  obscureText: true,
                  decoration: InputDecoration(labelText: 'Staff PIN'),
                ),
                const SizedBox(height: 12),
                Text('Amount: ${_amount.isEmpty ? '0' : _amount}'),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final key in [
                      '1',
                      '2',
                      '3',
                      '4',
                      '5',
                      '6',
                      '7',
                      '8',
                      '9',
                      'C',
                      '0',
                    ])
                      _key(key),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView.builder(
                    key: const ValueKey('orders'),
                    itemCount: 40,
                    itemBuilder: (context, index) => ListTile(
                      dense: true,
                      title: Text('Order #${index + 1}'),
                      onTap: () => _note('Order #${index + 1}'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
