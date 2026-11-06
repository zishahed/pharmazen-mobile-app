import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import 'order_providers.dart';
import 'widgets/order_history.dart';

class PurchaseHistoryScreen extends ConsumerStatefulWidget {
  const PurchaseHistoryScreen({super.key});

  @override
  ConsumerState<PurchaseHistoryScreen> createState() =>
      _PurchaseHistoryScreenState();
}

class _PurchaseHistoryScreenState
    extends ConsumerState<PurchaseHistoryScreen> {
  DateTime? _selectedDay;

  DateTime _dayOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  void _moveDay(int offset) {
    final current = _selectedDay ?? _dayOnly(DateTime.now());
    setState(() {
      _selectedDay = current.add(Duration(days: offset));
    });
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDay ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      helpText: 'Select purchase date',
    );
    if (picked != null && mounted) {
      setState(() => _selectedDay = _dayOnly(picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedDay = _selectedDay;
    return Scaffold(
      appBar: AppBar(title: const Text('Purchase history')),
      body: RefreshIndicator(
        onRefresh: () => ref.read(myOrdersProvider.notifier).refresh(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            _CalendarToolbar(
              selectedDay: selectedDay,
              onPrevious: () => _moveDay(-1),
              onNext: () => _moveDay(1),
              onPick: _pickDay,
              onShowAll: () => setState(() => _selectedDay = null),
            ),
            const SizedBox(height: 20),
            OrderHistory(selectedDay: selectedDay),
          ],
        ),
      ),
    );
  }
}

class _CalendarToolbar extends StatelessWidget {
  const _CalendarToolbar({
    required this.selectedDay,
    required this.onPrevious,
    required this.onNext,
    required this.onPick,
    required this.onShowAll,
  });

  final DateTime? selectedDay;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onPick;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final label = selectedDay == null
        ? 'All purchases'
        : '${_monthName(selectedDay!.month)} ${selectedDay!.day}, '
              '${selectedDay!.year}';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Previous day',
            onPressed: selectedDay == null ? null : onPrevious,
            icon: const Icon(Icons.chevron_left_rounded),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                TextButton.icon(
                  onPressed: onPick,
                  icon: const Icon(Icons.calendar_month_outlined, size: 17),
                  label: const Text('Choose date'),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Next day',
            onPressed: selectedDay == null ? null : onNext,
            icon: const Icon(Icons.chevron_right_rounded),
          ),
          if (selectedDay != null)
            IconButton(
              tooltip: 'Show all purchases',
              onPressed: onShowAll,
              icon: const Icon(Icons.clear_rounded),
            ),
        ],
      ),
    );
  }
}

const _months = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _monthName(int month) => _months[month - 1];
