import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

/// Focused simulator fixture for ordinary localized text, with no per-control
/// Scout annotations or explicit semantics labels.
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MaterialApp(home: MultilingualLabelsScreen()));
}

class MultilingualLabelsScreen extends StatefulWidget {
  const MultilingualLabelsScreen({super.key});

  @override
  State<MultilingualLabelsScreen> createState() =>
      _MultilingualLabelsScreenState();
}

class _MultilingualLabelsScreenState extends State<MultilingualLabelsScreen> {
  int _step = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Multilingual labels')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('保存する · حفظ · 저장 · บันทึก'),
            if (_step == 0)
              GestureDetector(
                onTap: () => setState(() => _step = 1),
                child: const SizedBox(
                  width: 160,
                  height: 100,
                  child: Column(
                    children: [
                      Icon(Icons.menu),
                      Padding(padding: EdgeInsets.all(8), child: Text('菜单')),
                    ],
                  ),
                ),
              ),
            if (_step == 1)
              CupertinoButton(
                onPressed: () => setState(() => _step = 2),
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [SizedBox(height: 4), Text('添加服务')],
                  ),
                ),
              ),
            if (_step == 2)
              CupertinoButton(
                onPressed: () => setState(() => _step = 3),
                child: const Text('保存'),
              ),
            if (_step == 3) const Text('已保存'),
          ],
        ),
      ),
    );
  }
}
