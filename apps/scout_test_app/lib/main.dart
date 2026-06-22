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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Suppliers')),
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
              alignment: Alignment.centerRight,
              child: TextButton(
                key: const ValueKey('trigger_error'),
                onPressed: () {
                  FlutterError.reportError(
                    FlutterErrorDetails(
                      exception: StateError('Scout synthetic framework error'),
                      library: 'scout_test_app',
                    ),
                  );
                },
                child: const Text('Trigger error'),
              ),
            ),
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
