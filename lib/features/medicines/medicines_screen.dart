import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../data/providers/medicine_providers.dart';
import '../../data/repositories/medicine_repository.dart';
import '../../domain/models/medicine.dart';

class MedicinesScreen extends ConsumerStatefulWidget {
  const MedicinesScreen({super.key, required this.mode});

  final MedicineSearchMode mode;

  @override
  ConsumerState<MedicinesScreen> createState() => _MedicinesScreenState();
}

class _MedicinesScreenState extends ConsumerState<MedicinesScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;

  List<Medicine>? _results;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _performSearch(value),
    );
  }

  Future<void> _performSearch(String value) async {
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _results = null;
        _loading = false;
        _error = null;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await ref
          .read(medicineRepositoryProvider)
          .search(query, widget.mode);
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _clear() {
    _controller.clear();
    setState(() {
      _results = null;
      _loading = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.mode.label),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _controller,
                autofocus: true,
                onChanged: _onChanged,
                decoration: InputDecoration(
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: AppColors.primaryBlue,
                  ),
                  hintText: widget.mode.hint,
                  suffixIcon: _controller.text.isEmpty
                      ? null
                      : IconButton(
                          onPressed: _clear,
                          icon: const Icon(Icons.close_rounded),
                        ),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _MessagePlaceholder(
        icon: Icons.error_outline_rounded,
        message: 'Something went wrong while searching.',
        trailing: TextButton(
          onPressed: () => _performSearch(_controller.text),
          child: const Text('Try again'),
        ),
      );
    }

    final results = _results;
    if (results == null) {
      return _MessagePlaceholder(
        icon: Icons.search_rounded,
        message: 'Start typing to see matching medicines.',
      );
    }

    if (results.isEmpty) {
      return _MessagePlaceholder(
        icon: Icons.medication_outlined,
        message: 'No medicines found for "${_controller.text.trim()}".',
      );
    }

    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) =>
          _MedicineTile(medicine: results[index]),
    );
  }
}

class _MedicineTile extends StatelessWidget {
  const _MedicineTile({required this.medicine});

  final Medicine medicine;

  @override
  Widget build(BuildContext context) {
    final meta = [
      medicine.strength,
      medicine.dosageForm,
    ].where((line) => line != null && line.isNotEmpty).join(' • ');

    return Card(
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: AppColors.lightGreen,
          foregroundColor: AppColors.primaryGreen,
          child: Icon(Icons.medication_outlined),
        ),
        title: Text(
          medicine.brandName,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (medicine.genericName != null &&
                medicine.genericName!.isNotEmpty)
              Text(
                medicine.genericName!,
                style: const TextStyle(color: AppColors.primaryBlue),
              ),
            if (meta.isNotEmpty)
              Text(meta, style: const TextStyle(fontSize: 12)),
          ],
        ),
        isThreeLine: meta.isNotEmpty &&
            (medicine.genericName?.isNotEmpty ?? false),
      ),
    );
  }
}

class _MessagePlaceholder extends StatelessWidget {
  const _MessagePlaceholder({
    required this.icon,
    required this.message,
    this.trailing,
  });

  final IconData icon;
  final String message;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: AppColors.border),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          if (trailing != null) ...[
            const SizedBox(height: 4),
            trailing!,
          ],
        ],
      ),
    );
  }
}