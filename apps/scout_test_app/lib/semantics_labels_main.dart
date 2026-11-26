import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

/// Controls an app names with Semantics while they draw a glyph, as a POS
/// order screen does: a member card that shows only a gender glyph, a cart
/// line's capsule of glyph buttons, and a product tile whose photo is a
/// placeholder glyph. The handles must come from the app's labels and the
/// tile's text, not from the glyphs.
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MaterialApp(home: SemanticsLabelsScreen()));
}

class SemanticsLabelsScreen extends StatefulWidget {
  const SemanticsLabelsScreen({super.key});

  @override
  State<SemanticsLabelsScreen> createState() => _SemanticsLabelsScreenState();
}

class _SemanticsLabelsScreenState extends State<SemanticsLabelsScreen> {
  String _status = 'Nothing opened';
  String? _redeem;

  void _say(String status) => setState(() => _status = status);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Semantics labels')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_status),
          const SizedBox(height: 16),
          // A member card that shows only the member's gender glyph, named
          // on a Semantics around its tap.
          Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              label: 'Member Profile, Aisha Tan',
              child: InkWell(
                onTap: () => _say('Opened Aisha Tan'),
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.male, size: 32),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // A cart line the user taps to edit, with a capsule of redeem
          // options. Each option is a press-effect pressable: its label is on
          // the Semantics above the GestureDetector, its title is drawn only
          // while picked.
          InkWell(
            onTap: () => _say('Editing Thai Yoga'),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Expanded(child: Text('Thai Yoga')),
                  for (final (title, glyph) in const [
                    ('Credit', CupertinoIcons.money_dollar),
                    ('10 pts', CupertinoIcons.star_fill),
                    ('Voucher', CupertinoIcons.ticket),
                    ('Gift card', CupertinoIcons.gift),
                  ])
                    _RedeemOption(
                      title: title,
                      glyph: glyph,
                      picked: _redeem == title,
                      onPressed: () => setState(() {
                        _redeem = _redeem == title ? null : title;
                        _status = 'Redeem: ${_redeem ?? 'none'}';
                      }),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // A product tile with no photo: a placeholder glyph above its name.
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 140,
              height: 160,
              child: GestureDetector(
                onTap: () => _say('Added Foot Massage'),
                child: const Card(
                  child: Column(
                    children: [
                      Expanded(
                        child: Icon(CupertinoIcons.cube_box_fill, size: 56),
                      ),
                      Text('Foot Massage'),
                      Text('RM 80.00'),
                      SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A press-effect pressable as a design system builds one: a raw pointer
/// listener for the press animation, the button Semantics with the name, and
/// the GestureDetector that takes the tap.
class _RedeemOption extends StatelessWidget {
  const _RedeemOption({
    required this.title,
    required this.glyph,
    required this.picked,
    required this.onPressed,
  });

  final String title;
  final IconData glyph;
  final bool picked;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: picked,
      child: Listener(
        onPointerDown: (_) {},
        child: Semantics(
          button: true,
          label: title,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
            child: Container(
              height: 32,
              constraints: const BoxConstraints(minWidth: 36),
              padding: EdgeInsets.symmetric(horizontal: picked ? 8 : 0),
              decoration: BoxDecoration(
                color: picked ? Colors.orange : null,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(glyph, size: 18),
                  ClipRect(
                    child: Align(
                      widthFactor: picked ? 1 : 0,
                      child: Opacity(
                        opacity: picked ? 1 : 0,
                        // The option's label already says it.
                        child: ExcludeSemantics(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Text(title),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
