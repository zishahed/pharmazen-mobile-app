import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/widgets/skeletons.dart';
import '../../data/remote/admin_api_client.dart';

class AdminMedicinesScreen extends ConsumerStatefulWidget {
  const AdminMedicinesScreen({super.key});

  @override
  ConsumerState<AdminMedicinesScreen> createState() =>
      _AdminMedicinesScreenState();
}

class _AdminMedicinesScreenState extends ConsumerState<AdminMedicinesScreen> {
  List<AdminMedicine>? _items;
  String _search = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final items = await ref
          .read(adminApiClientProvider)
          .listMedicines(
            search: _search.trim().isEmpty ? null : _search.trim(),
          );
      if (mounted) setState(() => _items = items);
    } on AdminApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _edit([AdminMedicine? medicine]) async {
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _MedicineForm(medicine: medicine),
    );
    if (data == null || !mounted) return;
    try {
      await ref
          .read(adminApiClientProvider)
          .saveMedicine(data, id: medicine?.id);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              medicine == null ? 'Medicine added.' : 'Medicine updated.',
            ),
          ),
        );
      }
    } on AdminApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _delete(AdminMedicine medicine) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete medicine?'),
        content: Text('${medicine.name} will be hidden from the catalogue.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(adminApiClientProvider).deleteMedicine(medicine.id);
      await _load();
    } on AdminApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage medicines'),
        actions: [
          IconButton(
            onPressed: _edit,
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Add medicine',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _edit,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add medicine'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
          children: [
            TextField(
              onChanged: (value) => setState(() => _search = value),
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                hintText: 'Search medicines',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(
                  onPressed: _load,
                  icon: const Icon(Icons.arrow_forward_rounded),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (items == null && _error == null)
              const MedicineListSkeleton(count: 5)
            else if (_error != null && items == null)
              _ErrorMessage(message: _error!, onRetry: _load)
            else if (items!.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('No medicines found.'),
                ),
              )
            else
              for (final medicine in items)
                _MedicineCard(
                  medicine: medicine,
                  onEdit: () => _edit(medicine),
                  onDelete: () => _delete(medicine),
                ),
          ],
        ),
      ),
    );
  }
}

class _MedicineCard extends StatelessWidget {
  const _MedicineCard({
    required this.medicine,
    required this.onEdit,
    required this.onDelete,
  });

  final AdminMedicine medicine;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: AppColors.lightGreen,
          child: Icon(Icons.medication_outlined, color: AppColors.primaryGreen),
        ),
        title: Text(
          medicine.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '৳${medicine.price.toStringAsFixed(2)} • Stock ${medicine.stockQuantity}',
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) => value == 'edit' ? onEdit() : onDelete(),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Edit')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }
}

class _MedicineForm extends StatefulWidget {
  const _MedicineForm({this.medicine});

  final AdminMedicine? medicine;

  @override
  State<_MedicineForm> createState() => _MedicineFormState();
}

class _MedicineFormState extends State<_MedicineForm> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _category;
  late final TextEditingController _price;
  late final TextEditingController _stock;
  late final TextEditingController _expiry;
  late bool _requiresPrescription;

  @override
  void initState() {
    super.initState();
    final medicine = widget.medicine;
    _name = TextEditingController(text: medicine?.name);
    _description = TextEditingController(text: medicine?.description);
    _category = TextEditingController(text: medicine?.categoryId);
    _price = TextEditingController(text: medicine?.price.toString());
    _stock = TextEditingController(text: medicine?.stockQuantity.toString());
    _expiry = TextEditingController(
      text: medicine?.expiryDate?.toIso8601String().split('T').first,
    );
    _requiresPrescription = medicine?.requiresPrescription ?? false;
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _description,
      _category,
      _price,
      _stock,
      _expiry,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty ||
        _category.text.trim().isEmpty ||
        _price.text.trim().isEmpty ||
        _stock.text.trim().isEmpty) {
      return;
    }
    Navigator.pop(context, {
      'name': _name.text.trim(),
      'description': _description.text.trim(),
      'categoryId': _category.text.trim(),
      'price': double.tryParse(_price.text.trim()) ?? 0,
      'stockQuantity': int.tryParse(_stock.text.trim()) ?? 0,
      'expiryDate': _expiry.text.trim().isEmpty ? null : _expiry.text.trim(),
      'requiresPrescription': _requiresPrescription,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.medicine == null ? 'Add medicine' : 'Edit medicine'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: _description,
              decoration: const InputDecoration(labelText: 'Description'),
            ),
            TextField(
              controller: _category,
              decoration: const InputDecoration(labelText: 'Category ID'),
            ),
            TextField(
              controller: _price,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Price'),
            ),
            TextField(
              controller: _stock,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Stock quantity'),
            ),
            TextField(
              controller: _expiry,
              decoration: const InputDecoration(
                labelText: 'Expiry date (YYYY-MM-DD)',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Requires prescription'),
              value: _requiresPrescription,
              onChanged: (value) =>
                  setState(() => _requiresPrescription = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      children: [
        Text(message, textAlign: TextAlign.center),
        TextButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    ),
  );
}
