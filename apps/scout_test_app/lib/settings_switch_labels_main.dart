import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

/// Ordinary row labels and controls, without per-control Scout annotations.
void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const MaterialApp(home: SettingsSwitchLabelsScreen()));
}

class SettingsSwitchLabelsScreen extends StatefulWidget {
  const SettingsSwitchLabelsScreen({super.key});

  @override
  State<SettingsSwitchLabelsScreen> createState() =>
      _SettingsSwitchLabelsScreenState();
}

class _SettingsSwitchLabelsScreenState
    extends State<SettingsSwitchLabelsScreen> {
  bool _remark = true;
  bool _localized = false;

  Widget _row(String title, Widget control, {String? subtitle}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [Text(title), if (subtitle != null) Text(subtitle)],
          ),
        ),
        control,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings switch labels')),
    body: Column(
      children: [
        _row(
          'Enable Signature',
          CupertinoSwitch(value: true, onChanged: (_) {}),
        ),
        _row(
          'Enable Overall Remark',
          CupertinoSwitch(
            value: _remark,
            onChanged: (value) => setState(() => _remark = value),
          ),
          subtitle: 'Allow an overall note on this form',
        ),
        _row(
          '启用备注',
          Switch(
            value: _localized,
            onChanged: (value) => setState(() => _localized = value),
          ),
        ),
        _row(
          'Disabled setting',
          const CupertinoSwitch(value: false, onChanged: null),
        ),
        Text(_remark ? 'Overall remark enabled' : 'Overall remark disabled'),
        Text(
          _localized
              ? 'Localized setting enabled'
              : 'Localized setting disabled',
        ),
      ],
    ),
  );
}
