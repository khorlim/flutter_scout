import 'package:flutter/material.dart';

import '../widgets/scout_painters.dart';

// =============================================================================
// 1. Long list — 2,000 lazily-built rows with a single keyed target far down.
// Stresses scroll-to-find against widgets not built until scrolled into view.
// =============================================================================
class LongListScreen extends StatefulWidget {
  const LongListScreen({super.key});

  @override
  State<LongListScreen> createState() => _LongListScreenState();
}

class _LongListScreenState extends State<LongListScreen> {
  static const int _count = 2000;
  static const int _targetIndex = 1750;
  int _tapped = -1;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Long list'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(26),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 6),
              child: Text(
                'Last tapped: $_tapped',
                key: const ValueKey('long_list_status'),
              ),
            ),
          ),
        ),
      ),
      body: ListView.builder(
        key: const ValueKey('long_list_scroll'),
        itemCount: _count,
        itemBuilder: (context, index) {
          final isTarget = index == _targetIndex;
          return ListTile(
            // Only the far target is keyed; the rest are deliberately handle-less.
            key: isTarget ? const ValueKey('far_target') : null,
            leading: CircleAvatar(child: Text('${index % 100}')),
            title: Text(
              isTarget ? 'Golden ticket #$index' : 'Inventory $index',
            ),
            subtitle: Text(isTarget ? 'Far target row' : 'Lazy row $index'),
            trailing: isTarget
                ? const Icon(Icons.flag, color: Colors.amber)
                : const Icon(Icons.chevron_right),
            onTap: () => setState(() => _tapped = index),
          );
        },
      ),
    );
  }
}

// =============================================================================
// 2. Photo grid — painted, semantics-free tiles; only every 10th is keyed.
// =============================================================================
class PhotoGridScreen extends StatefulWidget {
  const PhotoGridScreen({super.key});

  @override
  State<PhotoGridScreen> createState() => _PhotoGridScreenState();
}

class _PhotoGridScreenState extends State<PhotoGridScreen> {
  int _selected = -1;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Photo grid'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                'Selected: $_selected',
                key: const ValueKey('photo_grid_status'),
              ),
            ),
          ),
        ],
      ),
      body: GridView.builder(
        key: const ValueKey('painted_photo_grid'),
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: 90,
        itemBuilder: (context, index) {
          final keyed = index % 10 == 0;
          return GestureDetector(
            key: keyed ? ValueKey('painted_tile_$index') : null,
            onTap: () => setState(() => _selected = index),
            child: Stack(
              fit: StackFit.expand,
              children: [
                PaintedSwatch(
                  seed: index,
                  label: index.isEven ? null : '$index',
                ),
                if (_selected == index)
                  const Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.check_circle, color: Colors.white),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// =============================================================================
// 3. Nested scroll — collapsing SliverAppBar, horizontal carousels inside a
// vertical scroll, and a sliver grid. Stresses nested-scrollable detection.
// =============================================================================
class NestedScrollScreen extends StatefulWidget {
  const NestedScrollScreen({super.key});

  @override
  State<NestedScrollScreen> createState() => _NestedScrollScreenState();
}

class _NestedScrollScreenState extends State<NestedScrollScreen> {
  String _picked = 'none';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        key: const ValueKey('nested_scroll_root'),
        slivers: [
          SliverAppBar(
            key: const ValueKey('nested_app_bar'),
            pinned: true,
            expandedHeight: 160,
            flexibleSpace: FlexibleSpaceBar(
              title: const Text('Nested scroll'),
              background: CustomPaint(painter: _HeaderPainter()),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Last picked: $_picked',
                key: const ValueKey('nested_status'),
              ),
            ),
          ),
          for (final row in const ['Trending', 'For you', 'New'])
            SliverToBoxAdapter(child: _carousel(context, row)),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Grid section'),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) =>
                    PaintedSwatch(seed: index + 40, label: 'G$index'),
                childCount: 18,
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _carousel(BuildContext context, String title) {
    final slug = title.toLowerCase().replaceAll(' ', '_');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        SizedBox(
          height: 110,
          child: ListView.builder(
            key: ValueKey('carousel_$slug'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: 20,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: GestureDetector(
                onTap: () => setState(() => _picked = '$title #$index'),
                child: SizedBox(
                  width: 90,
                  child: PaintedSwatch(seed: index * 3, label: '$index'),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HeaderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = const LinearGradient(
        colors: [Colors.teal, Colors.indigo],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(_HeaderPainter oldDelegate) => false;
}

// =============================================================================
// 4. Tabs — five lazy tabs; off-tab content is not built until selected. Each
// tab has a tab-scoped keyed row to stress cross-tab disambiguation.
// =============================================================================
class TabsScreen extends StatelessWidget {
  const TabsScreen({super.key});

  static const _tabs = ['Inbox', 'Starred', 'Sent', 'Archive', 'Spam'];

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Tabs'),
          bottom: TabBar(
            key: const ValueKey('tabs_bar'),
            isScrollable: true,
            tabs: [
              for (final t in _tabs) Tab(key: ValueKey('tab_$t'), text: t),
            ],
          ),
        ),
        body: TabBarView(
          key: const ValueKey('tabs_view'),
          children: [for (final t in _tabs) _TabList(label: t)],
        ),
      ),
    );
  }
}

class _TabList extends StatelessWidget {
  const _TabList({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: ValueKey('tab_list_$label'),
      itemCount: 30,
      itemBuilder: (context, index) => ListTile(
        key: index == 3 ? ValueKey('${label}_row_3') : null,
        leading: Text(label.substring(0, 1)),
        title: Text('$label message $index'),
        subtitle: Text('Preview for $label item $index'),
      ),
    );
  }
}

// =============================================================================
// 5. Mega form — every common input type plus validation. Mixed keyed fields.
// =============================================================================
enum _Plan { free, pro, enterprise }

class MegaFormScreen extends StatefulWidget {
  const MegaFormScreen({super.key});

  @override
  State<MegaFormScreen> createState() => _MegaFormScreenState();
}

class _MegaFormScreenState extends State<MegaFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();

  String? _country;
  bool _notifications = true;
  bool _terms = false;
  _Plan _plan = _Plan.free;
  double _budget = 40;
  String? _priority = 'medium';
  final Set<String> _interests = {'flutter'};
  DateTime? _date;
  TimeOfDay? _time;
  String _status = 'Not submitted';

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      initialDate: DateTime(2026, 6, 27),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 0),
    );
    if (picked != null) setState(() => _time = picked);
  }

  void _submit() {
    if (!_formKey.currentState!.validate() || !_terms) {
      setState(() => _status = 'Validation failed');
      return;
    }
    setState(() {
      _status =
          'Submitted: ${_nameController.text}, $_country, ${_plan.name}, '
          'budget=${_budget.round()}, priority=$_priority, '
          'interests=${_interests.join('+')}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mega form')),
      body: Form(
        key: _formKey,
        child: ListView(
          key: const ValueKey('mega_form_scroll'),
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              key: const ValueKey('mega_name'),
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Customer name',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.isEmpty) ? 'Name is required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey('mega_email'),
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v != null && v.contains('@')) ? null : 'Invalid email',
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('mega_country'),
              initialValue: _country,
              decoration: const InputDecoration(
                labelText: 'Country',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'MY', child: Text('Malaysia')),
                DropdownMenuItem(value: 'SG', child: Text('Singapore')),
                DropdownMenuItem(value: 'US', child: Text('United States')),
              ],
              onChanged: (v) => setState(() => _country = v),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const ValueKey('mega_notifications'),
              title: const Text('Enable notifications'),
              value: _notifications,
              onChanged: (v) => setState(() => _notifications = v),
            ),
            CheckboxListTile(
              key: const ValueKey('mega_terms'),
              title: const Text('I accept the terms'),
              value: _terms,
              onChanged: (v) => setState(() => _terms = v ?? false),
            ),
            const SizedBox(height: 8),
            Text('Plan', style: Theme.of(context).textTheme.titleSmall),
            SegmentedButton<_Plan>(
              key: const ValueKey('mega_plan'),
              segments: const [
                ButtonSegment(value: _Plan.free, label: Text('Free')),
                ButtonSegment(value: _Plan.pro, label: Text('Pro')),
                ButtonSegment(
                  value: _Plan.enterprise,
                  label: Text('Enterprise'),
                ),
              ],
              selected: {_plan},
              onSelectionChanged: (s) => setState(() => _plan = s.first),
            ),
            const SizedBox(height: 16),
            Text('Budget: ${_budget.round()}'),
            Slider(
              key: const ValueKey('mega_budget'),
              value: _budget,
              max: 100,
              divisions: 20,
              label: '${_budget.round()}',
              onChanged: (v) => setState(() => _budget = v),
            ),
            const SizedBox(height: 8),
            Text('Priority', style: Theme.of(context).textTheme.titleSmall),
            RadioGroup<String>(
              groupValue: _priority,
              onChanged: (v) => setState(() => _priority = v),
              child: Column(
                children: [
                  for (final p in const ['low', 'medium', 'high'])
                    RadioListTile<String>(
                      key: ValueKey('priority_$p'),
                      title: Text(p),
                      value: p,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text('Interests', style: Theme.of(context).textTheme.titleSmall),
            Wrap(
              spacing: 8,
              children: [
                for (final tag in const ['flutter', 'dart', 'design', 'ml'])
                  FilterChip(
                    key: ValueKey('chip_$tag'),
                    label: Text(tag),
                    selected: _interests.contains(tag),
                    onSelected: (sel) => setState(() {
                      if (sel) {
                        _interests.add(tag);
                      } else {
                        _interests.remove(tag);
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('mega_pick_date'),
                    onPressed: _pickDate,
                    icon: const Icon(Icons.calendar_today),
                    label: Text(
                      _date == null
                          ? 'Pick date'
                          : '${_date!.year}-${_date!.month}-${_date!.day}',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('mega_pick_time'),
                    onPressed: _pickTime,
                    icon: const Icon(Icons.access_time),
                    label: Text(
                      _time == null ? 'Pick time' : _time!.format(context),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('mega_submit'),
              onPressed: _submit,
              child: const Text('Submit'),
            ),
            const SizedBox(height: 8),
            Text(_status, key: const ValueKey('mega_status')),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 6. Overlays — snackbar, popup menu, dropdown menu, nested dialogs, draggable
// sheet with a deep keyed target, and a tooltip.
// =============================================================================
class OverlaysScreen extends StatefulWidget {
  const OverlaysScreen({super.key});

  @override
  State<OverlaysScreen> createState() => _OverlaysScreenState();
}

class _OverlaysScreenState extends State<OverlaysScreen> {
  String _status = 'idle';

  void _set(String v) => setState(() => _status = v);

  Future<void> _nestedDialogs() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Outer dialog'),
        content: const Text('Open another dialog on top of this one.'),
        actions: [
          TextButton(
            key: const ValueKey('overlay_open_inner'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Inner dialog'),
                content: const Text('This dialog is stacked.'),
                actions: [
                  FilledButton(
                    key: const ValueKey('overlay_inner_close'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close inner'),
                  ),
                ],
              ),
            ),
            child: const Text('Open inner'),
          ),
          TextButton(
            key: const ValueKey('overlay_outer_close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _draggableSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        builder: (context, controller) => ListView.builder(
          key: const ValueKey('overlay_sheet_list'),
          controller: controller,
          itemCount: 40,
          itemBuilder: (context, index) => ListTile(
            key: index == 25 ? const ValueKey('overlay_sheet_target') : null,
            title: Text('Sheet row $index'),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Overlays'),
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey('overlay_popup'),
            onSelected: _set,
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Status: $_status', key: const ValueKey('overlay_status')),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('overlay_snackbar'),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Saved to drafts'),
                    action: SnackBarAction(
                      label: 'Undo',
                      onPressed: () => _set('undone'),
                    ),
                  ),
                );
                _set('snackbar shown');
              },
              child: const Text('Show snackbar'),
            ),
            const SizedBox(height: 12),
            DropdownMenu<String>(
              key: const ValueKey('overlay_dropdown_menu'),
              label: const Text('Choose region'),
              onSelected: (v) => _set('region:$v'),
              dropdownMenuEntries: const [
                DropdownMenuEntry(value: 'apac', label: 'APAC'),
                DropdownMenuEntry(value: 'emea', label: 'EMEA'),
                DropdownMenuEntry(value: 'amer', label: 'AMER'),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              key: const ValueKey('overlay_nested_dialog'),
              onPressed: _nestedDialogs,
              child: const Text('Nested dialogs'),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              key: const ValueKey('overlay_draggable_sheet'),
              onPressed: _draggableSheet,
              child: const Text('Draggable sheet'),
            ),
            const SizedBox(height: 12),
            Tooltip(
              message: 'This control has a tooltip',
              child: OutlinedButton(
                key: const ValueKey('overlay_tooltip'),
                onPressed: () => _set('tooltip target tapped'),
                child: const Text('Tooltip target'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// 7. Gestures — swipe-to-dismiss, reorderable rows, and long-press menus.
// =============================================================================
class GesturesScreen extends StatefulWidget {
  const GesturesScreen({super.key});

  @override
  State<GesturesScreen> createState() => _GesturesScreenState();
}

class _GesturesScreenState extends State<GesturesScreen> {
  final List<String> _items = List<String>.generate(12, (i) => 'Task ${i + 1}');
  String _status = 'idle';

  Future<void> _longPressMenu(String item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text('Actions for $item')),
            ListTile(
              key: const ValueKey('gesture_menu_pin'),
              leading: const Icon(Icons.push_pin),
              title: const Text('Pin'),
              onTap: () => Navigator.of(context).pop('pinned'),
            ),
            ListTile(
              key: const ValueKey('gesture_menu_share'),
              leading: const Icon(Icons.share),
              title: const Text('Share'),
              onTap: () => Navigator.of(context).pop('shared'),
            ),
          ],
        ),
      ),
    );
    if (action != null) setState(() => _status = '$item $action');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gestures'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(26),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 6),
              child: Text(
                'Status: $_status',
                key: const ValueKey('gesture_status'),
              ),
            ),
          ),
        ),
      ),
      body: ReorderableListView.builder(
        key: const ValueKey('gesture_reorder_list'),
        padding: const EdgeInsets.all(8),
        itemCount: _items.length,
        // ignore: deprecated_member_use
        onReorder: (oldIndex, newIndex) {
          setState(() {
            if (newIndex > oldIndex) newIndex -= 1;
            final moved = _items.removeAt(oldIndex);
            _items.insert(newIndex, moved);
            _status = 'reordered $moved';
          });
        },
        itemBuilder: (context, index) {
          final item = _items[index];
          return Dismissible(
            key: ValueKey('dismiss_$item'),
            background: Container(
              color: Colors.red,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 16),
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            onDismissed: (_) => setState(() {
              _items.removeAt(index);
              _status = 'dismissed $item';
            }),
            child: ListTile(
              tileColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              leading: const Icon(Icons.drag_handle),
              title: Text(item),
              subtitle: const Text('Swipe to delete, long-press for menu'),
              onLongPress: () => _longPressMenu(item),
            ),
          );
        },
      ),
    );
  }
}

// =============================================================================
// 8. Ambiguity hell — many near-identical controls; mixed keys + ancestors.
// =============================================================================
class AmbiguityScreen extends StatefulWidget {
  const AmbiguityScreen({super.key});

  @override
  State<AmbiguityScreen> createState() => _AmbiguityScreenState();
}

class _AmbiguityScreenState extends State<AmbiguityScreen> {
  String _status = 'none';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ambiguity hell')),
      body: ListView(
        key: const ValueKey('ambiguity_scroll'),
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            'Last action: $_status',
            key: const ValueKey('ambiguity_status'),
          ),
          const SizedBox(height: 12),
          const Text('Six identical unkeyed "Save" buttons:'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < 6; i++)
                ElevatedButton(
                  onPressed: () => setState(() => _status = 'unkeyed save #$i'),
                  child: const Text('Save'),
                ),
            ],
          ),
          const Divider(height: 32),
          const Text('Same label, distinct ancestor cards:'),
          const SizedBox(height: 8),
          for (final section in const ['Billing', 'Profile', 'Security'])
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(section),
                    TextButton(
                      onPressed: () =>
                          setState(() => _status = '$section edit'),
                      child: const Text('Edit'),
                    ),
                  ],
                ),
              ),
            ),
          const Divider(height: 32),
          const Text('Keyed vs unkeyed duplicates:'),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: const ValueKey('ambiguity_confirm_primary'),
                  onPressed: () => setState(() => _status = 'keyed confirm'),
                  child: const Text('Confirm'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () => setState(() => _status = 'unkeyed confirm'),
                  child: const Text('Confirm'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Text('Repeated text labels:'),
          const SizedBox(height: 8),
          for (var i = 0; i < 5; i++) const Text('Pending review'),
        ],
      ),
    );
  }
}

// =============================================================================
// 9. Moving targets — animated sliding box, shimmer placeholders, spinner.
// =============================================================================
class AnimatedScreen extends StatefulWidget {
  const AnimatedScreen({super.key});

  @override
  State<AnimatedScreen> createState() => _AnimatedScreenState();
}

class _AnimatedScreenState extends State<AnimatedScreen>
    with TickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat(reverse: true);
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  bool _loading = true;
  int _taps = 0;

  @override
  void dispose() {
    _slide.dispose();
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Moving targets'),
        actions: [
          IconButton(
            key: const ValueKey('animated_toggle_loading'),
            icon: Icon(_loading ? Icons.stop : Icons.play_arrow),
            onPressed: () => setState(() => _loading = !_loading),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Moving box taps: $_taps',
              key: const ValueKey('animated_status'),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 80,
              child: AnimatedBuilder(
                animation: _slide,
                builder: (context, child) => Align(
                  alignment: Alignment(_slide.value * 2 - 1, 0),
                  child: child,
                ),
                child: GestureDetector(
                  key: const ValueKey('animated_moving_box'),
                  onTap: () => setState(() => _taps++),
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.touch_app, color: Colors.white),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text('Loading content:'),
            const SizedBox(height: 8),
            if (_loading)
              for (var i = 0; i < 4; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _Shimmer(controller: _shimmer),
                )
            else
              const Card(
                child: ListTile(
                  key: ValueKey('animated_loaded_tile'),
                  leading: Icon(Icons.check_circle, color: Colors.green),
                  title: Text('Content loaded'),
                  subtitle: Text('The shimmer placeholders are gone.'),
                ),
              ),
            const SizedBox(height: 24),
            const Center(
              child: CircularProgressIndicator(
                key: ValueKey('animated_spinner'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Shimmer extends StatelessWidget {
  const _Shimmer({required this.controller});

  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final v = controller.value;
        return Container(
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            gradient: LinearGradient(
              begin: Alignment(-1 - v, 0),
              end: Alignment(1 - v, 0),
              colors: [
                Colors.grey.shade300,
                Colors.grey.shade100,
                Colors.grey.shade300,
              ],
            ),
          ),
        );
      },
    );
  }
}

// =============================================================================
// 10. Painted dashboard — gauges and charts via CustomPaint with tap regions
// that carry no visible text.
// =============================================================================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  String _metric = 'none';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Painted dashboard')),
      body: ListView(
        key: const ValueKey('dashboard_scroll'),
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Selected metric: $_metric',
            key: const ValueKey('dashboard_status'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _GaugeCard(
                  id: 'cpu',
                  label: 'CPU',
                  value: 0.72,
                  color: scheme.primary,
                  onTap: () => setState(() => _metric = 'cpu'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _GaugeCard(
                  id: 'memory',
                  label: 'Memory',
                  value: 0.45,
                  color: scheme.tertiary,
                  onTap: () => setState(() => _metric = 'memory'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Weekly throughput'),
                  const SizedBox(height: 12),
                  GestureDetector(
                    key: const ValueKey('dashboard_bar_chart'),
                    onTap: () => setState(() => _metric = 'throughput'),
                    child: SizedBox(
                      height: 140,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: BarChartPainter(
                          values: const [12, 28, 18, 34, 22, 30, 16],
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Palette (no labels):'),
          const SizedBox(height: 8),
          SizedBox(
            height: 64,
            child: Row(
              children: [
                for (var i = 0; i < 6; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: GestureDetector(
                        key: i == 3
                            ? const ValueKey('dashboard_swatch_mid')
                            : null,
                        onTap: () => setState(() => _metric = 'swatch_$i'),
                        child: PaintedSwatch(seed: i * 9 + 1),
                      ),
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

class _GaugeCard extends StatelessWidget {
  const _GaugeCard({
    required this.id,
    required this.label,
    required this.value,
    required this.color,
    required this.onTap,
  });

  final String id;
  final String label;
  final double value;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        key: ValueKey('gauge_$id'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              SizedBox(
                height: 100,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: const Size(100, 100),
                      painter: GaugePainter(value: value, color: color),
                    ),
                    Text('${(value * 100).round()}%'),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(label),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// 11. Hidden & offscreen — Offstage, Visibility, Opacity, and clipped overflow.
// =============================================================================
class OffscreenScreen extends StatefulWidget {
  const OffscreenScreen({super.key});

  @override
  State<OffscreenScreen> createState() => _OffscreenScreenState();
}

class _OffscreenScreenState extends State<OffscreenScreen> {
  bool _showOffstage = false;
  bool _visible = false;
  bool _opaque = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hidden & offscreen')),
      body: ListView(
        key: const ValueKey('offscreen_scroll'),
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            key: const ValueKey('toggle_offstage'),
            title: const Text('Reveal Offstage content'),
            value: _showOffstage,
            onChanged: (v) => setState(() => _showOffstage = v),
          ),
          Offstage(
            offstage: !_showOffstage,
            child: const Card(
              child: ListTile(
                key: ValueKey('offstage_content'),
                title: Text('Offstage content'),
                subtitle: Text('Not laid out until revealed.'),
              ),
            ),
          ),
          const Divider(),
          SwitchListTile(
            key: const ValueKey('toggle_visibility'),
            title: const Text('Reveal Visibility content'),
            value: _visible,
            onChanged: (v) => setState(() => _visible = v),
          ),
          Visibility(
            visible: _visible,
            child: const Card(
              child: ListTile(
                key: ValueKey('visibility_content'),
                title: Text('Visibility content'),
                subtitle: Text('Collapsed when hidden.'),
              ),
            ),
          ),
          const Divider(),
          SwitchListTile(
            key: const ValueKey('toggle_opacity'),
            title: const Text('Make Opacity content opaque'),
            value: _opaque,
            onChanged: (v) => setState(() => _opaque = v),
          ),
          Opacity(
            opacity: _opaque ? 1 : 0,
            child: Card(
              child: ListTile(
                key: const ValueKey('opacity_content'),
                title: const Text('Opacity content'),
                subtitle: const Text('Occupies space even at opacity 0.'),
                trailing: IconButton(
                  icon: const Icon(Icons.info),
                  onPressed: _opaque ? () {} : null,
                ),
              ),
            ),
          ),
          const Divider(),
          const Text('Horizontally clipped row (overflows off the right):'),
          const SizedBox(height: 8),
          ClipRect(
            child: SizedBox(
              height: 56,
              child: OverflowBox(
                maxWidth: 1200,
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    for (var i = 0; i < 20; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Chip(
                          key: i == 18
                              ? const ValueKey('clipped_chip_target')
                              : null,
                          label: Text('chip $i'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 900),
          const Text(
            'Deep visible target',
            key: ValueKey('deep_visible_target'),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// 12. Expansion — collapsible content via ExpansionTile and ExpansionPanelList.
// Keyed targets live inside collapsed sections.
// =============================================================================
class ExpansionScreen extends StatefulWidget {
  const ExpansionScreen({super.key});

  @override
  State<ExpansionScreen> createState() => _ExpansionScreenState();
}

class _ExpansionScreenState extends State<ExpansionScreen> {
  final List<bool> _panelOpen = [false, false, false];
  String _status = 'idle';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Expansion')),
      body: ListView(
        key: const ValueKey('expansion_scroll'),
        padding: const EdgeInsets.all(12),
        children: [
          Text('Status: $_status', key: const ValueKey('expansion_status')),
          const SizedBox(height: 12),
          Card(
            child: ExpansionTile(
              key: const ValueKey('expansion_tile_details'),
              title: const Text('Order details'),
              childrenPadding: const EdgeInsets.all(16),
              children: [
                const Text('Hidden until expanded.'),
                const SizedBox(height: 8),
                FilledButton(
                  key: const ValueKey('expansion_hidden_action'),
                  onPressed: () =>
                      setState(() => _status = 'hidden action tapped'),
                  child: const Text('Confirm order'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          ExpansionPanelList(
            expansionCallback: (index, isOpen) =>
                setState(() => _panelOpen[index] = isOpen),
            children: [
              for (var i = 0; i < _panelOpen.length; i++)
                ExpansionPanel(
                  isExpanded: _panelOpen[i],
                  headerBuilder: (context, isOpen) =>
                      ListTile(title: Text('Panel ${i + 1}')),
                  body: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: TextField(
                      key: ValueKey('panel_field_$i'),
                      decoration: InputDecoration(
                        labelText: 'Note for panel ${i + 1}',
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (v) => setState(() => _status = 'panel$i:$v'),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
