import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../data/remote/admin_api_client.dart';

class AdminMedicineFormScreen extends StatefulWidget {
  const AdminMedicineFormScreen({
    super.key,
    required this.options,
    this.medicine,
  });

  final AdminMedicineOptions options;
  final AdminMedicine? medicine;

  @override
  State<AdminMedicineFormScreen> createState() =>
      _AdminMedicineFormScreenState();
}

class _AdminMedicineFormScreenState extends State<AdminMedicineFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _fields;
  late String? _categoryId;
  late int? _genericId;
  late bool _requiresPrescription;

  TextEditingController _controller(String key) => _fields[key]!;

  @override
  void initState() {
    super.initState();
    final medicine = widget.medicine;
    final parts = (medicine?.description ?? '').split('|');
    String part(int index, String? fallback) {
      final value =
          fallback ?? (index < parts.length ? parts[index].trim() : '');
      return value;
    }

    _fields = {
      'name': TextEditingController(text: medicine?.name ?? ''),
      'genericName': TextEditingController(text: part(0, null)),
      'dosageForm': TextEditingController(text: part(1, medicine?.dosageForm)),
      'strength': TextEditingController(text: part(2, medicine?.strength)),
      'manufacturer': TextEditingController(
        text: part(3, medicine?.manufacturer),
      ),
      'packageContainer': TextEditingController(
        text: medicine?.packageContainer ?? '',
      ),
      'packageSize': TextEditingController(text: medicine?.packageSize ?? ''),
      'slug': TextEditingController(text: medicine?.slug ?? ''),
      'type': TextEditingController(text: medicine?.type ?? ''),
      'price': TextEditingController(text: medicine?.price.toString() ?? ''),
      'stockQuantity': TextEditingController(
        text: medicine?.stockQuantity.toString() ?? '',
      ),
      'expiryDate': TextEditingController(
        text: medicine?.expiryDate?.toIso8601String().split('T').first ?? '',
      ),
    };
    _categoryId = medicine?.categoryId;
    _genericId = widget.options.generics
        .where(
          (generic) =>
              generic.id == medicine?.genericId ||
              generic.name.toLowerCase() == part(0, null).toLowerCase(),
        )
        .map((generic) => generic.id)
        .firstOrNull;
    _requiresPrescription = medicine?.requiresPrescription ?? false;
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Required' : null;

  String? _integer(String? value) {
    if (_required(value) != null) return 'Required';
    return int.tryParse(value!.trim()) == null ? 'Enter a whole number' : null;
  }

  String? _decimal(String? value) {
    if (_required(value) != null) return 'Required';
    return double.tryParse(value!.trim()) == null
        ? 'Enter a valid price'
        : null;
  }

  String? _date(String? value) {
    if (_required(value) != null) return 'Required';
    return DateTime.tryParse(value!.trim()) == null
        ? 'Use the date picker'
        : null;
  }

  Future<void> _pickExpiry() async {
    final initial =
        DateTime.tryParse(_controller('expiryDate').text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: initial,
    );
    if (picked != null) {
      _controller('expiryDate').text = picked
          .toIso8601String()
          .split('T')
          .first;
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate() ||
        _categoryId == null ||
        _genericId == null) {
      setState(() {});
      return;
    }
    final description = [
      _controller('genericName').text.trim(),
      _controller('dosageForm').text.trim(),
      _controller('strength').text.trim(),
      _controller('manufacturer').text.trim(),
    ].join(' | ');
    Navigator.pop(context, {
      'name': _controller('name').text.trim(),
      'description': description,
      'categoryId': _categoryId,
      'genericId': _genericId,
      'slug': _controller('slug').text.trim(),
      'type': _controller('type').text.trim(),
      'dosageForm': _controller('dosageForm').text.trim(),
      'strength': _controller('strength').text.trim(),
      'manufacturer': _controller('manufacturer').text.trim(),
      'packageContainer': _controller('packageContainer').text.trim(),
      'packageSize': _controller('packageSize').text.trim(),
      'price': double.parse(_controller('price').text.trim()),
      'stockQuantity': int.parse(_controller('stockQuantity').text.trim()),
      'expiryDate': _controller('expiryDate').text.trim(),
      'requiresPrescription': _requiresPrescription,
    });
  }

  Widget _text(
    String key,
    String label, {
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    VoidCallback? onTap,
    bool readOnly = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: _controller(key),
        keyboardType: keyboardType,
        validator: validator ?? _required,
        readOnly: readOnly,
        onTap: onTap,
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: onTap == null
              ? null
              : const Icon(Icons.calendar_today_outlined),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.medicine == null ? 'Add medicine' : 'Edit medicine'),
        actions: [
          IconButton(onPressed: _save, icon: const Icon(Icons.check_rounded)),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            const Text(
              'Medicine details',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            _text('name', 'Brand name'),
            _autocompleteGeneric(),
            _text('dosageForm', 'Dosage form'),
            _text('strength', 'Strength'),
            _autocompleteManufacturer(),
            _text('packageContainer', 'Package container'),
            _text('packageSize', 'Package size'),
            _text('type', 'Type'),
            _autocompleteCategory(),
            _autocompleteSlug(),
            _text(
              'price',
              'Price',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              validator: _decimal,
            ),
            _text(
              'stockQuantity',
              'Stock quantity',
              keyboardType: TextInputType.number,
              validator: _integer,
            ),
            _text(
              'expiryDate',
              'Expiry date',
              readOnly: true,
              onTap: _pickExpiry,
              validator: _date,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Requires prescription'),
              value: _requiresPrescription,
              onChanged: (value) =>
                  setState(() => _requiresPrescription = value),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(
                widget.medicine == null ? 'Add medicine' : 'Save changes',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primaryBlue,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _autocompleteCategory() {
    final selected = widget.options.categories.where(
      (c) => c.id == _categoryId,
    );
    final initial = selected.isEmpty ? '' : selected.first.name;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Autocomplete<AdminCategory>(
        initialValue: TextEditingValue(text: initial),
        displayStringForOption: (option) => option.name,
        optionsBuilder: (value) {
          final query = value.text.toLowerCase();
          return widget.options.categories.where(
            (category) => category.name.toLowerCase().contains(query),
          );
        },
        onSelected: (category) => setState(() => _categoryId = category.id),
        fieldViewBuilder: (context, controller, focusNode, onSubmitted) =>
            TextFormField(
              controller: controller,
              focusNode: focusNode,
              validator: (_) =>
                  _categoryId == null ? 'Select a category' : null,
              onChanged: (_) => setState(() => _categoryId = null),
              decoration: const InputDecoration(
                labelText: 'Category',
                suffixIcon: Icon(Icons.arrow_drop_down_rounded),
              ),
            ),
      ),
    );
  }

  Widget _autocompleteGeneric() {
    final initial = _controller('genericName').text;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Autocomplete<AdminGeneric>(
        initialValue: TextEditingValue(text: initial),
        displayStringForOption: (option) => option.name,
        optionsBuilder: (value) {
          final query = value.text.toLowerCase();
          return widget.options.generics.where(
            (generic) => generic.name.toLowerCase().contains(query),
          );
        },
        onSelected: (generic) {
          _genericId = generic.id;
          _controller('genericName').text = generic.name;
        },
        fieldViewBuilder: (context, controller, focusNode, onSubmitted) =>
            TextFormField(
              controller: controller,
              focusNode: focusNode,
              validator: (_) =>
                  _genericId == null ? 'Select a generic name' : null,
              onChanged: (value) {
                _genericId = null;
                _controller('genericName').text = value;
              },
              decoration: const InputDecoration(
                labelText: 'Generic name',
                suffixIcon: Icon(Icons.arrow_drop_down_rounded),
              ),
            ),
      ),
    );
  }

  Widget _autocompleteSlug() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Autocomplete<String>(
        initialValue: TextEditingValue(text: _controller('slug').text),
        optionsBuilder: (value) {
          final query = value.text.toLowerCase();
          return widget.options.slugs.where(
            (slug) => slug.toLowerCase().contains(query),
          );
        },
        onSelected: (slug) => _controller('slug').text = slug,
        fieldViewBuilder: (context, controller, focusNode, onSubmitted) =>
            TextFormField(
              controller: controller,
              focusNode: focusNode,
              validator: _required,
              onChanged: (value) => _controller('slug').text = value,
              decoration: const InputDecoration(
                labelText: 'Slug',
                suffixIcon: Icon(Icons.arrow_drop_down_rounded),
              ),
            ),
      ),
    );
  }

  Widget _autocompleteManufacturer() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Autocomplete<String>(
        initialValue: TextEditingValue(text: _controller('manufacturer').text),
        optionsBuilder: (value) {
          final query = value.text.toLowerCase();
          return widget.options.manufacturers.where(
            (manufacturer) => manufacturer.toLowerCase().contains(query),
          );
        },
        onSelected: (manufacturer) =>
            _controller('manufacturer').text = manufacturer,
        fieldViewBuilder: (context, controller, focusNode, onSubmitted) =>
            TextFormField(
              controller: controller,
              focusNode: focusNode,
              validator: _required,
              onChanged: (value) => _controller('manufacturer').text = value,
              decoration: const InputDecoration(
                labelText: 'Manufacturer',
                suffixIcon: Icon(Icons.arrow_drop_down_rounded),
              ),
            ),
      ),
    );
  }
}
