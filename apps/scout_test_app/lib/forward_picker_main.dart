import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

/// A chat whose bubbles are SelectableText (copyable, as desktop chat apps
/// render them) and a forward picker whose rows are pressables built on raw
/// pointer events, as ripple packages and press-effect wrappers are. Only
/// their Semantics declares them buttons.
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MaterialApp(home: ForwardPickerScreen()));
}

class ForwardPickerScreen extends StatefulWidget {
  const ForwardPickerScreen({super.key});

  @override
  State<ForwardPickerScreen> createState() => _ForwardPickerScreenState();
}

class _ForwardPickerScreenState extends State<ForwardPickerScreen> {
  static const _messages = ['Hi! Thanks for checking in.', 'Ya'];
  String _lastAction = 'No forward yet';

  Future<void> _forward(String message) async {
    final picked = await showDialog<List<String>>(
      context: context,
      builder: (_) => const _ForwardDialog(),
    );
    if (picked == null || !mounted) return;
    setState(() => _lastAction = 'Forwarded "$message" to ${picked.join(', ')}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mercy')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.all(12), child: Text(_lastAction)),
          for (final message in _messages)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onSecondaryTapDown: (_) => _forward(message),
              onLongPress: () => _forward(message),
              child: Container(
                margin: const EdgeInsets.all(8),
                padding: const EdgeInsets.all(12),
                color: const Color(0xFFE8F5E9),
                child: SelectableText(message),
              ),
            ),
        ],
      ),
    );
  }
}

class _ForwardDialog extends StatefulWidget {
  const _ForwardDialog();

  @override
  State<_ForwardDialog> createState() => _ForwardDialogState();
}

class _ForwardDialogState extends State<_ForwardDialog> {
  static const _chats = ['Zern Yet', 'LimHan', 'Raymond'];
  final _picked = <String>[];

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Forward to'),
            ),
            for (final chat in _chats)
              _RawPressable(
                label: chat,
                selected: _picked.contains(chat),
                onPressed: () => setState(
                  () => _picked.contains(chat)
                      ? _picked.remove(chat)
                      : _picked.add(chat),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton(
                onPressed: _picked.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(_picked),
                child: Text('Send to ${_picked.length}'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// No GestureDetector, InkWell or button: a raw Listener, as a ripple
/// package uses. Its Semantics is the only declaration that it is a button.
class _RawPressable extends StatelessWidget {
  const _RawPressable({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerUp: (_) => onPressed(),
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              const SizedBox(width: 16),
              Expanded(child: Text(label)),
              Icon(selected ? Icons.check_box : Icons.check_box_outline_blank),
              const SizedBox(width: 16),
            ],
          ),
        ),
      ),
    );
  }
}
