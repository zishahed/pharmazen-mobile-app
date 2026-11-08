import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/widgets/skeletons.dart';
import '../../data/remote/admin_api_client.dart';

class AdminOrdersScreen extends ConsumerStatefulWidget {
  const AdminOrdersScreen({super.key});

  @override
  ConsumerState<AdminOrdersScreen> createState() => _AdminOrdersScreenState();
}

class _AdminOrdersScreenState extends ConsumerState<AdminOrdersScreen> {
  List<AdminOrder>? _orders;
  DateTime? _from;
  DateTime? _to;
  String _customer = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final orders = await ref
          .read(adminApiClientProvider)
          .listOrders(
            customer: _customer.trim().isEmpty ? null : _customer.trim(),
          );
      if (mounted) setState(() => _orders = orders);
    } on AdminApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _pickDate({required bool from}) async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDate: from ? (_from ?? DateTime.now()) : (_to ?? DateTime.now()),
    );
    if (picked == null) return;
    setState(() {
      if (from) {
        _from = picked;
      } else {
        _to = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = (_orders ?? const <AdminOrder>[])
        .where((order) {
          final afterFrom = _from == null || !order.createdAt.isBefore(_from!);
          final beforeTo =
              _to == null ||
              order.createdAt.isBefore(_to!.add(const Duration(days: 1)));
          return afterFrom && beforeTo;
        })
        .toList(growable: false);
    final totals = <String, num>{};
    for (final order in visible) {
      totals[order.customerName] =
          (totals[order.customerName] ?? 0) + order.totalAmount;
    }
    final topCustomer = totals.entries.isEmpty
        ? null
        : (totals.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
              .first;

    return Scaffold(
      appBar: AppBar(title: const Text('Orders & sales')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            TextField(
              onChanged: (value) => setState(() => _customer = value),
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                hintText: 'Search customer name',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(
                  onPressed: _load,
                  icon: const Icon(Icons.arrow_forward_rounded),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickDate(from: true),
                    icon: const Icon(Icons.calendar_today_outlined),
                    label: Text(_from == null ? 'From date' : _date(_from!)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickDate(from: false),
                    icon: const Icon(Icons.calendar_today_outlined),
                    label: Text(_to == null ? 'To date' : _date(_to!)),
                  ),
                ),
              ],
            ),
            if (_from != null || _to != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => setState(() {
                    _from = null;
                    _to = null;
                  }),
                  child: const Text('Clear dates'),
                ),
              ),
            const SizedBox(height: 8),
            if (_orders == null && _error == null)
              const MedicineListSkeleton(count: 4)
            else if (_error != null && _orders == null)
              Text(_error!, textAlign: TextAlign.center)
            else ...[
              if (topCustomer != null)
                Card(
                  color: AppColors.lightGreen,
                  child: ListTile(
                    leading: const Icon(
                      Icons.emoji_events_outlined,
                      color: AppColors.primaryGreen,
                    ),
                    title: const Text('Highest sales customer'),
                    subtitle: Text(topCustomer.key),
                    trailing: Text(
                      '৳${topCustomer.value.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              for (final order in visible)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Text(
                      order.customerName,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      '${order.customerEmail}\n${_date(order.createdAt)} • ${order.status}',
                    ),
                    isThreeLine: true,
                    trailing: Text(
                      '৳${order.totalAmount.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              if (visible.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('No orders match these filters.')),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

String _date(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
