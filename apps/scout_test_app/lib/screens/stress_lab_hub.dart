import 'package:flutter/material.dart';

import 'stress_lab_screens.dart';

/// A destination in the stress lab.
class _Destination {
  const _Destination({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.builder,
  });

  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final WidgetBuilder builder;
}

final List<_Destination> _destinations = [
  _Destination(
    id: 'long_list',
    title: 'Long list',
    subtitle: '2,000 lazy rows; keyed target far off-screen',
    icon: Icons.list,
    builder: (_) => const LongListScreen(),
  ),
  _Destination(
    id: 'photo_grid',
    title: 'Photo grid',
    subtitle: 'CustomPaint tiles with no semantics',
    icon: Icons.grid_view,
    builder: (_) => const PhotoGridScreen(),
  ),
  _Destination(
    id: 'nested_scroll',
    title: 'Nested scroll',
    subtitle: 'Slivers + horizontal carousels + collapsing header',
    icon: Icons.view_carousel,
    builder: (_) => const NestedScrollScreen(),
  ),
  _Destination(
    id: 'tabs',
    title: 'Tabs',
    subtitle: 'Lazy TabBarView with off-tab content',
    icon: Icons.tab,
    builder: (_) => const TabsScreen(),
  ),
  _Destination(
    id: 'mega_form',
    title: 'Mega form',
    subtitle: 'Every input type + validation',
    icon: Icons.dynamic_form,
    builder: (_) => const MegaFormScreen(),
  ),
  _Destination(
    id: 'overlays',
    title: 'Overlays',
    subtitle: 'Menus, snackbars, sheets, nested dialogs',
    icon: Icons.layers,
    builder: (_) => const OverlaysScreen(),
  ),
  _Destination(
    id: 'gestures',
    title: 'Gestures',
    subtitle: 'Swipe-to-dismiss, reorder, long-press',
    icon: Icons.gesture,
    builder: (_) => const GesturesScreen(),
  ),
  _Destination(
    id: 'ambiguity',
    title: 'Ambiguity hell',
    subtitle: 'Many identical labels; mixed keys',
    icon: Icons.content_copy,
    builder: (_) => const AmbiguityScreen(),
  ),
  _Destination(
    id: 'animated',
    title: 'Moving targets',
    subtitle: 'Animations, shimmer, spinners',
    icon: Icons.animation,
    builder: (_) => const AnimatedScreen(),
  ),
  _Destination(
    id: 'dashboard',
    title: 'Painted dashboard',
    subtitle: 'Gauges + charts via CustomPaint',
    icon: Icons.dashboard,
    builder: (_) => const DashboardScreen(),
  ),
  _Destination(
    id: 'offscreen',
    title: 'Hidden & offscreen',
    subtitle: 'Offstage, Visibility, Opacity, clipped',
    icon: Icons.visibility_off,
    builder: (_) => const OffscreenScreen(),
  ),
  _Destination(
    id: 'expansion',
    title: 'Expansion',
    subtitle: 'Collapsible content hidden until expanded',
    icon: Icons.expand_more,
    builder: (_) => const ExpansionScreen(),
  ),
];

/// Hub linking to every stress screen. Rendered as a card grid so the hub is
/// itself a grid-navigation stress case.
class StressLabHub extends StatelessWidget {
  const StressLabHub({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scout Stress Lab')),
      body: GridView.builder(
        key: const ValueKey('lab_grid'),
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 280,
          mainAxisExtent: 132,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: _destinations.length,
        itemBuilder: (context, index) {
          final dest = _destinations[index];
          return Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('lab_${dest.id}'),
              onTap: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: dest.builder)),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      dest.icon,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      dest.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: Text(
                        dest.subtitle,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
