import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

/// A chat list whose rows open a menu at the pointer, the way desktop and
/// phone inboxes do: a long press (onLongPressStart, for its position) or a
/// right click (onSecondaryTapDown). The menu opens on its own route, over
/// the rows beneath it.
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MaterialApp(home: ContextMenuScreen()));
}

class ContextMenuScreen extends StatefulWidget {
  const ContextMenuScreen({super.key});

  @override
  State<ContextMenuScreen> createState() => _ContextMenuScreenState();
}

class _ContextMenuScreenState extends State<ContextMenuScreen> {
  static const _chats = ['Mercy', 'Raymond', 'Moon', '+60 15 000 9699'];
  final _archived = <String>{};
  String _lastAction = 'No action yet';

  Future<void> _openMenu(String chat, Offset position, String via) async {
    final choice = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss menu',
      barrierColor: Colors.transparent,
      pageBuilder: (context, _, _) => Stack(
        children: [
          Positioned(
            left: position.dx,
            top: position.dy,
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 220,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final item in ['Archive', 'Pin', 'Mute'])
                      _MenuItem(
                        key: GlobalObjectKey('menu-$item'),
                        title: item,
                        onPressed: () => Navigator.of(context).pop(item),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    setState(() {
      if (choice == 'Archive') _archived.add(chat);
      _lastAction = '$choice $chat via $via';
    });
  }

  @override
  Widget build(BuildContext context) {
    final chats = _chats.where((chat) => !_archived.contains(chat)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Chats')),
      body: Column(
        children: [
          Padding(padding: const EdgeInsets.all(12), child: Text(_lastAction)),
          Expanded(
            child: ListView(
              children: [
                for (final chat in chats)
                  // The row's own tap opens the chat; the menu needs the
                  // pointer position, so it listens to onLongPressStart and
                  // onSecondaryTapDown instead of onLongPress.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onLongPressStart: (details) =>
                        _openMenu(chat, details.globalPosition, 'long press'),
                    onSecondaryTapDown: (details) =>
                        _openMenu(chat, details.globalPosition, 'right click'),
                    child: ListTile(
                      title: Text(chat),
                      subtitle: const Text('Last message preview'),
                      onTap: () => setState(() => _lastAction = 'Open $chat'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A design-system style menu row: keyed, its title several layouts deep.
class _MenuItem extends StatelessWidget {
  const _MenuItem({super.key, required this.title, required this.onPressed});

  final String title;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.circle_outlined, size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: DefaultTextStyle.merge(
                  style: const TextStyle(fontSize: 15),
                  child: Text(title),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
