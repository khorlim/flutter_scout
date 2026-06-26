import 'package:flutter/material.dart';
import 'package:flutter_scout_helper/flutter_scout_helper.dart';

void main() {
  FlutterScoutBinding.ensureInitialized();
  runApp(const ScoutTestApp());
}

class ScoutTestApp extends StatelessWidget {
  const ScoutTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Scout Test App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: const SupplierListScreen(),
    );
  }
}

class SupplierListScreen extends StatefulWidget {
  const SupplierListScreen({super.key});

  @override
  State<SupplierListScreen> createState() => _SupplierListScreenState();
}

class _SupplierListScreenState extends State<SupplierListScreen> {
  final List<String> _suppliers = <String>[];
  int _duplicateActions = 0;
  int _glyphDuplicateActions = 0;
  String _customPhone = 'Not set';

  Future<void> _openAddSupplierDialog() async {
    final supplier = await showDialog<String>(
      context: context,
      builder: (context) => const AddSupplierDialog(),
    );
    if (supplier == null || supplier.isEmpty) return;
    setState(() {
      _suppliers.add(supplier);
    });
  }

  Future<void> _showOkDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Scout dialog'),
        content: const Text('Dialog opened'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _openCustomPhoneDialog() async {
    final phone = await showDialog<String>(
      context: context,
      builder: (context) => const CustomPhoneDialog(),
    );
    if (phone == null || phone.isEmpty) return;
    setState(() {
      _customPhone = phone;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Suppliers'),
        actions: [
          IconButton(
            onPressed: () {
              setState(() {
                _duplicateActions++;
              });
            },
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('supplier_search'),
              decoration: const InputDecoration(
                labelText: 'Search',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) {},
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                children: [
                  InkWell(
                    onTap: () {
                      setState(() {
                        _glyphDuplicateActions++;
                      });
                    },
                    child: Text(
                      String.fromCharCode(Icons.copy.codePoint),
                      style: const TextStyle(fontFamily: 'MaterialIcons'),
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('smoke_issues'),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SmokeIssuesScreen(),
                        ),
                      );
                    },
                    child: const Text('Smoke issues'),
                  ),
                  TextButton(
                    key: const ValueKey('trigger_error'),
                    onPressed: () {
                      FlutterError.reportError(
                        FlutterErrorDetails(
                          exception: StateError(
                            'Scout synthetic framework error',
                          ),
                          library: 'scout_test_app',
                        ),
                      );
                    },
                    child: const Text('Trigger error'),
                  ),
                  TextButton(
                    key: const ValueKey('show_ok_dialog'),
                    onPressed: _showOkDialog,
                    child: const Text('Show OK dialog'),
                  ),
                  TextButton(
                    key: const ValueKey('custom_phone'),
                    onPressed: _openCustomPhoneDialog,
                    child: const Text('Custom phone'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text('Duplicate actions: $_duplicateActions'),
            Text('Glyph duplicate actions: $_glyphDuplicateActions'),
            Text('Custom phone: $_customPhone'),
            const SizedBox(height: 16),
            Expanded(
              child: _suppliers.isEmpty
                  ? const Center(child: Text('No suppliers found'))
                  : ListView.builder(
                      itemCount: _suppliers.length,
                      itemBuilder: (context, index) =>
                          ListTile(title: Text(_suppliers[index])),
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('add_supplier'),
        onPressed: _openAddSupplierDialog,
        label: const Text('Add supplier'),
        icon: const Icon(Icons.add),
      ),
    );
  }
}

class CustomPhoneDialog extends StatefulWidget {
  const CustomPhoneDialog({super.key});

  @override
  State<CustomPhoneDialog> createState() => _CustomPhoneDialogState();
}

class _CustomPhoneDialogState extends State<CustomPhoneDialog> {
  String _value = '60';

  void _append(String digit) {
    setState(() {
      _value += digit;
    });
  }

  void _save() {
    Navigator.of(context).pop(_value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Phone Number'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_formatPhone(_value), key: const ValueKey('custom_phone_value')),
          const SizedBox(height: 12),
          SizedBox(
            width: 240,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final row in const [
                  ['1', '2', '3'],
                  ['4', '5', '6'],
                  ['7', '8', '9'],
                  ['', '0', ''],
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        for (final digit in row)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: digit.isEmpty
                                  ? const SizedBox(height: 44)
                                  : OutlinedButton(
                                      key: ValueKey('custom_digit_$digit'),
                                      onPressed: () => _append(digit),
                                      style: OutlinedButton.styleFrom(
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                      ),
                                      child: Text(digit),
                                    ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('custom_phone_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('custom_phone_save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

String _formatPhone(String value) {
  if (value.length <= 2) return value;
  if (value.length <= 4) {
    return value;
  }
  if (value.length <= 7) {
    return '(${value.substring(0, 4)}) ${value.substring(4)}';
  }
  return '(${value.substring(0, 4)}) ${value.substring(4, 7)}-${value.substring(7)}';
}

class SmokeIssuesScreen extends StatefulWidget {
  const SmokeIssuesScreen({super.key});

  @override
  State<SmokeIssuesScreen> createState() => _SmokeIssuesScreenState();
}

class _SmokeIssuesScreenState extends State<SmokeIssuesScreen> {
  final TextEditingController _choiceRemarkController = TextEditingController();
  final TextEditingController _overallRemarkController =
      TextEditingController();
  final TextEditingController _duplicateOneController = TextEditingController();
  final TextEditingController _duplicateTwoController = TextEditingController();
  final TextEditingController _answerController = TextEditingController();
  String _committedAnswer = '';
  String? _selectedStaff;
  String _saveStatus = 'Not saved';

  @override
  void dispose() {
    _choiceRemarkController.dispose();
    _overallRemarkController.dispose();
    _duplicateOneController.dispose();
    _duplicateTwoController.dispose();
    _answerController.dispose();
    super.dispose();
  }

  void _save() {
    setState(() {
      _saveStatus = [
        _choiceRemarkController.text,
        _overallRemarkController.text,
        _duplicateOneController.text,
        _duplicateTwoController.text,
        _committedAnswer,
        _selectedStaff ?? 'No staff',
      ].join(' | ');
    });
  }

  Future<void> _selectStaff() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('Select Staff')),
              for (final staff in const ['GoodJob', 'Scout Ops', 'Member QA'])
                ListTile(
                  key: ValueKey('staff_$staff'),
                  title: Text(staff),
                  onTap: () => Navigator.of(context).pop(staff),
                ),
              TextButton(
                key: const ValueKey('staff_done'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        );
      },
    );
    if (selected == null) return;
    setState(() {
      _selectedStaff = selected;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smoke issues'),
        actions: [
          IconButton(
            onPressed: () {
              setState(() {
                _duplicateOneController.text = _committedAnswer;
                _duplicateTwoController.text = _committedAnswer;
              });
            },
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
      body: SingleChildScrollView(
        key: const ValueKey('smoke_scroll'),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('choice_remark'),
              controller: _choiceRemarkController,
              decoration: const InputDecoration(
                labelText: 'Enter the remark',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('overall_remark'),
              controller: _overallRemarkController,
              decoration: const InputDecoration(
                labelText: 'Enter the remark',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _duplicateOneController,
              decoration: const InputDecoration(
                labelText: 'Enter duplicate note',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _duplicateTwoController,
              decoration: const InputDecoration(
                labelText: 'Enter duplicate note',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('committed_answer'),
              controller: _answerController,
              decoration: const InputDecoration(
                labelText: 'Enter your answer',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                setState(() {
                  _committedAnswer = value;
                });
              },
            ),
            const SizedBox(height: 8),
            Text('Committed answer: $_committedAnswer'),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('select_staff'),
              onPressed: _selectStaff,
              child: const Text('Select Staff'),
            ),
            Text('Selected staff: ${_selectedStaff ?? 'None'}'),
            const SizedBox(height: 420),
            TextField(
              key: const ValueKey('bottom_field'),
              decoration: const InputDecoration(
                labelText: 'Bottom field',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('save_smoke'),
              onPressed: _committedAnswer.isEmpty ? null : _save,
              child: const Text('Save smoke form'),
            ),
            const SizedBox(height: 8),
            Text('Save status: $_saveStatus'),
          ],
        ),
      ),
    );
  }
}

class AddSupplierDialog extends StatefulWidget {
  const AddSupplierDialog({super.key});

  @override
  State<AddSupplierDialog> createState() => _AddSupplierDialogState();
}

class _AddSupplierDialogState extends State<AddSupplierDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _error = 'Supplier name is required';
      });
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add supplier'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('supplier_name'),
            controller: _nameController,
            decoration: InputDecoration(
              labelText: 'Supplier name',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('supplier_phone'),
            controller: _phoneController,
            decoration: const InputDecoration(
              labelText: 'Phone',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('cancel_supplier'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('save_supplier'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
