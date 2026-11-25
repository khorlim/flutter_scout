import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

/// A POS order screen shaped like TunaiPro's, for the Scout gaps found
/// there: product tiles and member cards are custom press-effect cards
/// (`Semantics(button)` over a raw `Listener`, the label text ~20 levels
/// down, a placeholder and a stock glyph beside it); menu rows are
/// `CupertinoButton(key: GlobalKey())` with a hidden checkmark; a "Points"
/// chip shows its mode only by a painted border while "Credit" states it in
/// Semantics; `<180 days`/`>180 days` filters; a "Roundup" caption over a
/// switch; the cart sits above the grid and recomputes its total a moment
/// after an item is added; item and member popups have app bar titles over
/// bold labels; and there are more lists than a scene shows.
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MaterialApp(home: OrderScreen()));
}

const products = [
  'Thai Yoga',
  'Foot Massage',
  'Hot Stone',
  'Body Scrub',
  'Facial',
  'Head Spa',
];

class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key});

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  final List<String> _cart = [];
  // The total is recomputed after the cart changes, as an app's pricing
  // service would; the receipt of the tap is taken before it lands.
  String _total = 'RM 0.00';
  bool _points = false;
  bool _credit = false;
  bool _roundup = false;
  String _range = '<180 days';
  String _sort = 'Name';

  void _add(String product) {
    setState(() => _cart.add(product));
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      setState(() => _total = 'RM ${(_cart.length * 120).toStringAsFixed(2)}');
    });
  }

  Future<void> _openMenu() => showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close menu',
    pageBuilder: (context, _, _) => Align(
      alignment: Alignment.topRight,
      child: Material(
        child: SizedBox(
          width: 240,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final option in ['Name', 'Price'])
                _MenuRow(
                  icon: CupertinoIcons.sort_down,
                  title: 'Sort by $option',
                  checked: _sort == option,
                  onPressed: () {
                    setState(() => _sort = option);
                    Navigator.of(context).pop();
                  },
                ),
              _MenuRow(
                icon: CupertinoIcons.pencil,
                title: 'Advanced Edit',
                checked: false,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _openItem(String item) => showDialog<void>(
    context: context,
    builder: (context) => _TitledPopover(
      title: item,
      body: [
        const ListTile(title: Text('Quantity'), trailing: Text('1')),
        const ListTile(title: Text('Price'), trailing: Text('RM 120.00')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    ),
  );

  Future<void> _openMember() => showDialog<void>(
    context: context,
    builder: (context) => _TitledPopover(
      title: 'Member Detail',
      body: [
        const Text(
          'OUTSTANDING',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
        ),
        const Text('RM 0.00'),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Order'),
        actions: [
          CupertinoButton(
            onPressed: _openMenu,
            child: const Icon(CupertinoIcons.ellipsis_circle),
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            child: Column(
              children: [
                SizedBox(
                  height: 64,
                  child: _PressCard(
                    onTap: _openMember,
                    child: const Row(
                      children: [
                        CircleAvatar(child: Text('ZY')),
                        SizedBox(width: 8),
                        Text('Zern Yet'),
                        Icon(Icons.male),
                      ],
                    ),
                  ),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    // Selection only painted, as in TunaiPro.
                    _PaintedChip(
                      label: 'Points',
                      selected: _points,
                      onTap: () => setState(() => _points = !_points),
                    ),
                    // The same chip stating its state in Semantics.
                    Semantics(
                      selected: _credit,
                      child: _PaintedChip(
                        label: 'Credit',
                        selected: _credit,
                        onTap: () => setState(() => _credit = !_credit),
                      ),
                    ),
                    for (final range in ['<180 days', '>180 days'])
                      GestureDetector(
                        onTap: () => setState(() => _range = range),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            range,
                            style: TextStyle(
                              color: _range == range ? Colors.green : null,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                Text(_points ? 'Redeem with points' : 'Pay with cash'),
                Expanded(
                  child: GridView.count(
                    crossAxisCount: 3,
                    childAspectRatio: 2.4,
                    children: [
                      for (final product in products)
                        _PressCard(
                          onTap: () => _add(product),
                          child: Row(
                            children: [
                              const Icon(CupertinoIcons.cube_box_fill),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(product),
                                    const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text('RM 120'),
                                        Icon(CupertinoIcons.cube_box, size: 12),
                                        Text('5'),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                // More lists than a scene shows.
                for (var shelf = 1; shelf <= 5; shelf++)
                  SizedBox(
                    height: 28,
                    child: ListView(
                      key: ValueKey('shelf_$shelf'),
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (var i = 1; i <= 12; i++)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Text('Shelf $shelf item $i'),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 280,
            child: Column(
              children: [
                const Text('Cart'),
                Expanded(
                  child: ListView(
                    key: const ValueKey('cart'),
                    children: [
                      for (final (index, item) in _cart.indexed)
                        SizedBox(
                          key: ValueKey('cart_$index'),
                          height: 48,
                          child: _PressCard(
                            semanticsLabel: item,
                            onTap: () => _openItem(item),
                            child: Text(item),
                          ),
                        ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('Roundup'),
                    CupertinoSwitch(
                      value: _roundup,
                      onChanged: (value) => setState(() => _roundup = value),
                    ),
                  ],
                ),
                Text('Total $_total'),
                FilledButton(
                  onPressed: _total == 'RM 0.00' ? null : () {},
                  child: _total == 'RM 0.00'
                      ? const SizedBox.shrink()
                      : const Text('Payment'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A press-effect card: a semantic button over raw pointer handling, with
/// ripple, rim, shadow and clip layers between it and its content.
class _PressCard extends StatelessWidget {
  const _PressCard({
    required this.onTap,
    required this.child,
    this.semanticsLabel,
  });

  final VoidCallback onTap;
  final Widget child;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    Widget content = child;
    for (var layer = 0; layer < 18; layer++) {
      content = Padding(padding: EdgeInsets.zero, child: content);
    }
    return Semantics(
      button: true,
      selected: false,
      label: semanticsLabel,
      onTap: onTap,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerUp: (_) => onTap(),
        child: Card(child: content),
      ),
    );
  }
}

class _PaintedChip extends StatelessWidget {
  const _PaintedChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(
          color: selected ? Colors.green : Colors.transparent,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label),
    ),
  );
}

class _MenuRow extends StatelessWidget {
  _MenuRow({
    required this.icon,
    required this.title,
    required this.checked,
    required this.onPressed,
  });

  // A GlobalKey to anchor a sub-menu, as TunaiPro's menu rows have.
  final GlobalKey _anchor = GlobalKey();
  final IconData icon;
  final String title;
  final bool checked;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => CupertinoButton(
    key: _anchor,
    onPressed: onPressed,
    child: Row(
      children: [
        AnimatedOpacity(
          opacity: checked ? 1 : 0,
          duration: Duration.zero,
          child: const Icon(CupertinoIcons.checkmark),
        ),
        Icon(icon),
        const SizedBox(width: 8),
        Expanded(child: Text(title)),
      ],
    ),
  );
}

/// A popover page with an app bar title over its body.
class _TitledPopover extends StatelessWidget {
  const _TitledPopover({required this.title, required this.body});

  final String title;
  final List<Widget> body;

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 360,
      height: 320,
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListView(children: body),
      ),
    ),
  );
}
