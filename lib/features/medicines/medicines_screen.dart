import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../data/providers/medicine_providers.dart';
import '../../data/repositories/medicine_repository.dart';
import '../../domain/models/medicine.dart';
import 'widgets/medicines_widgets.dart';

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
      return MessagePlaceholder(
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
      return MessagePlaceholder(
        icon: Icons.search_rounded,
        message: 'Start typing to see matching medicines.',
      );
    }

    if (results.isEmpty) {
      return MessagePlaceholder(
        icon: Icons.medication_outlined,
        message: 'No medicines found for "${_controller.text.trim()}".',
      );
    }

    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) => MedicineTile(medicine: results[index]),
    );
  }
}