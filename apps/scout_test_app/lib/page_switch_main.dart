import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

/// A Home/Admin page switch like a POS home screen: a segment in the bar
/// animates a non-swipeable PageView of kept-alive tile pages, and the screen
/// rebuilds from the controller's listener to show which page is current.
/// That rebuild lands while the PageView ignores pointers for the animation.
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MaterialApp(home: PageSwitchScreen()));
}

class PageSwitchScreen extends StatefulWidget {
  const PageSwitchScreen({super.key});

  @override
  State<PageSwitchScreen> createState() => _PageSwitchScreenState();
}

class _PageSwitchScreenState extends State<PageSwitchScreen> {
  final _pages = PageController();
  int _currentPage = 0;
  String _lastOpened = 'none';

  @override
  void initState() {
    super.initState();
    _pages.addListener(() {
      final page = _pages.page?.toInt() ?? 0;
      if (page != _currentPage) setState(() => _currentPage = page);
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _show(int page) => _pages.animateToPage(
    page,
    duration: const Duration(milliseconds: 250),
    curve: Curves.easeInOut,
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: 0, label: Text('Home')),
          ButtonSegment(value: 1, label: Text('Admin')),
        ],
        selected: {_currentPage},
        onSelectionChanged: (selection) => _show(selection.single),
      ),
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text('Opened: $_lastOpened'),
        ),
        Expanded(
          child: PageView(
            controller: _pages,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _TilePage(
                tiles: const ['Member', 'Orders', 'Attendance'],
                onOpen: (tile) => setState(() => _lastOpened = tile),
              ),
              _TilePage(
                tiles: const ['Settings', 'Staff', 'Report'],
                onOpen: (tile) => setState(() => _lastOpened = tile),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _TilePage extends StatefulWidget {
  const _TilePage({required this.tiles, required this.onOpen});

  final List<String> tiles;
  final ValueChanged<String> onOpen;

  @override
  State<_TilePage> createState() => _TilePageState();
}

class _TilePageState extends State<_TilePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final tile in widget.tiles)
            FilledButton.tonal(
              onPressed: () => widget.onOpen(tile),
              child: Text(tile),
            ),
        ],
      ),
    );
  }
}
