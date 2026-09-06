import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/providers/medicine_providers.dart';
import '../../data/repositories/medicine_repository.dart';
import '../../domain/models/medicine.dart';
import '../medicines/widgets/medicines_widgets.dart';

class BrowseResultsScreen extends ConsumerStatefulWidget {
  const BrowseResultsScreen({
    super.key,
    required this.mode,
    required this.value,
  });

  final MedicineSearchMode mode;
  final String value;

  @override
  ConsumerState<BrowseResultsScreen> createState() =>
      _BrowseResultsScreenState();
}

class _BrowseResultsScreenState extends ConsumerState<BrowseResultsScreen> {
  List<Medicine>? _results;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await ref
          .read(medicineRepositoryProvider)
          .searchByExact(widget.value, widget.mode);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _buildBody(),
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
        message: 'Something went wrong while loading.',
        trailing: TextButton(onPressed: _load, child: const Text('Try again')),
      );
    }

    final results = _results ?? const [];
    if (results.isEmpty) {
      return const MessagePlaceholder(
        icon: Icons.medication_outlined,
        message: 'No medicines found.',
      );
    }

    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) => MedicineTile(
        medicine: results[index],
        onTap: () => context.push('/medicine', extra: results[index]),
      ),
    );
  }
}