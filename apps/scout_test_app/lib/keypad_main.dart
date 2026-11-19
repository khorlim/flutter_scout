import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

/// A point-of-sale screen that never sits still, like TunaiPro's: a ticking
/// clock, a sync counter and a sync capsule change in the background. Two
/// keypads copy TunaiPro's own: an amount pad whose display is plain text and
/// a phone pad whose display is `SelectableText` with a member suggestion
/// that slides in. The day grid scrolls both ways.
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MaterialApp(home: KeypadScreen()));
}

class KeypadScreen extends StatefulWidget {
  const KeypadScreen({super.key});

  @override
  State<KeypadScreen> createState() => _KeypadScreenState();
}

class _KeypadScreenState extends State<KeypadScreen> {
  late final Timer _ticker;
  DateTime _now = DateTime.now();
  int _synced = 0;
  String _amount = '0.00';
  String _phone = '';

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 400), (_) {
      setState(() {
        _now = DateTime.now();
        _synced++;
      });
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  String get _clock =>
      '${_now.hour.toString().padLeft(2, '0')}:'
      '${_now.minute.toString().padLeft(2, '0')}:'
      '${_now.second.toString().padLeft(2, '0')}';

  Future<void> _openAmount() async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => const _AmountPad(),
    );
    if (value != null) setState(() => _amount = value);
  }

  Future<void> _openPhone() async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => const _PhonePad(),
    );
    if (value != null) setState(() => _phone = value);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Keypad'),
      actions: [
        // The sync capsule: a control whose label changes in place.
        TextButton(
          onPressed: () {},
          child: Text('Data sync ${(_synced * 7) % 100}%'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Center(child: Text(_clock)),
        ),
      ],
    ),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              FilledButton(
                onPressed: _openAmount,
                child: const Text('Cash amount'),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _openPhone,
                child: const Text('Member phone'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('Amount: $_amount  Phone: $_phone  Synced: $_synced'),
        ),
        const Divider(),
        Expanded(
          child: ListView.builder(
            key: const ValueKey('day_grid'),
            itemCount: 48,
            itemBuilder: (context, index) {
              final hour = 8 + index ~/ 4;
              final minute = (index % 4) * 15;
              final slot =
                  '${hour.toString().padLeft(2, '0')}:'
                  '${minute.toString().padLeft(2, '0')}';
              return ListTile(
                dense: true,
                title: Text('Slot $slot'),
                onTap: () {},
              );
            },
          ),
        ),
      ],
    ),
  );
}

/// TunaiPro's number pad key: a CupertinoButton tile under a Listener.
class _PadKey extends StatelessWidget {
  const _PadKey(this.title, this.onPressed);

  final String title;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) {},
    child: CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size.zero,
      onPressed: onPressed,
      child: Container(
        margin: const EdgeInsets.all(2.5),
        height: double.infinity,
        width: double.infinity,
        decoration: BoxDecoration(
          color: const Color(0x14000000),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: Text(
            title,
            style: const TextStyle(fontSize: 22, color: Color(0xFF000000)),
          ),
        ),
      ),
    ),
  );
}

class _PadGrid extends StatelessWidget {
  const _PadGrid({required this.onKey, required this.lastKey});

  final ValueChanged<String> onKey;
  final String lastKey;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 4 * 57,
    child: GridView(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisExtent: 57,
      ),
      children: [
        for (var digit = 1; digit <= 9; digit++)
          _PadKey('$digit', () => onKey('$digit')),
        _PadKey('CLR', () => onKey('CLR')),
        _PadKey('0', () => onKey('0')),
        _PadKey(lastKey, () => onKey(lastKey)),
      ],
    ),
  );
}

class _AmountPad extends StatefulWidget {
  const _AmountPad();

  @override
  State<_AmountPad> createState() => _AmountPadState();
}

class _AmountPadState extends State<_AmountPad> {
  int _cents = 0;

  void _key(String key) => setState(() {
    if (key == 'CLR') {
      _cents = 0;
    } else if (key == '00') {
      _cents = _cents * 100;
    } else {
      _cents = _cents * 10 + int.parse(key);
    }
  });

  String get _display =>
      '${_cents ~/ 100}.${(_cents % 100).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 360,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Custom Cash'),
            SizedBox(
              height: 70,
              child: Center(
                child: Text(_display, style: const TextStyle(fontSize: 34)),
              ),
            ),
            _PadGrid(onKey: _key, lastKey: '00'),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_display),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PhonePad extends StatefulWidget {
  const _PhonePad();

  @override
  State<_PhonePad> createState() => _PhonePadState();
}

class _PhonePadState extends State<_PhonePad> {
  String _digits = '';

  void _key(String key) => setState(() {
    if (key == 'CLR') {
      _digits = '';
    } else if (key == '<') {
      if (_digits.isNotEmpty) {
        _digits = _digits.substring(0, _digits.length - 1);
      }
    } else {
      _digits += key;
    }
  });

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 360,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 110,
              child: Center(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SelectableText(
                        '+60 $_digits',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 30),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 150),
                        child: _digits.length >= 4
                            ? TextButton(
                                onPressed: () {},
                                child: Text('Sofa +60 $_digits 4569'),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _PadGrid(onKey: _key, lastKey: '<'),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_digits),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ),
  );
}
