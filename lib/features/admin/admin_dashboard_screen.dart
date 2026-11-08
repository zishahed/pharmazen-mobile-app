import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/widgets/skeletons.dart';
import '../../data/remote/admin_api_client.dart';
import '../prescription/pharmacist_prescriptions_screen.dart';
import 'admin_medicines_screen.dart';
import 'admin_orders_screen.dart';

class AdminDashboardScreen extends ConsumerStatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  ConsumerState<AdminDashboardScreen> createState() =>
      _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends ConsumerState<AdminDashboardScreen> {
  AdminStats? _stats;
  List<AdminUser> _users = const <AdminUser>[];
  bool _loading = true;
  String? _error;
  String _roleFilter = 'all';
  String _peopleSearch = '';

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
      final api = ref.read(adminApiClientProvider);
      final results = await Future.wait([api.getStats(), api.listUsers()]);
      if (!mounted) return;
      setState(() {
        _stats = results[0] as AdminStats;
        _users = results[1] as List<AdminUser>;
        _loading = false;
      });
    } on AdminApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _changeStatus(AdminUser user) async {
    final action = user.isActive ? 'deactivate' : 'reactivate';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${_title(action)} ${user.name}?'),
        content: Text(
          user.isActive
              ? 'This keeps the account record but prevents the user from signing in.'
              : 'This allows the user to sign in again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: user.isActive
                ? FilledButton.styleFrom(backgroundColor: AppColors.error)
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(_title(action)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await ref
          .read(adminApiClientProvider)
          .setUserActive(id: user.id, isActive: !user.isActive);
      await _load();
    } on AdminApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _stats == null) {
      return const _AdminDashboardSkeleton();
    }
    if (_error != null && _stats == null) {
      return _ErrorState(message: _error!, onRetry: _load);
    }

    final stats = _stats!;
    final users = _users
        .where((user) => _roleFilter == 'all' || user.role == _roleFilter)
        .where((user) {
          final query = _peopleSearch.trim().toLowerCase();
          return query.isEmpty ||
              user.name.toLowerCase().contains(query) ||
              user.email.toLowerCase().contains(query);
        })
        .toList(growable: false);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Admin workspace',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Monitor the pharmacy and manage access.',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh_rounded),
                tooltip: 'Refresh dashboard',
              ),
            ],
          ),
          const SizedBox(height: 20),
          _OverviewCard(
            icon: Icons.medication_outlined,
            label: 'Medicines',
            value: '${stats.totalMedicines}',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AdminMedicinesScreen(),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _MetricCard(
                  icon: Icons.pending_actions_outlined,
                  label: 'Pending reviews',
                  value: '${stats.pendingPrescriptions}',
                  accent: AppColors.primaryGreen,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const PharmacistPrescriptionsScreen(),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MetricCard(
                  icon: Icons.shopping_bag_outlined,
                  label: 'Orders',
                  value: '${stats.totalOrders}',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AdminOrdersScreen(),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: Text(
                  'People',
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                onPressed: () => showSearch<void>(
                  context: context,
                  delegate: _PeopleSearchDelegate(_users),
                ),
                icon: const Icon(Icons.search_rounded),
                tooltip: 'Search people',
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            onChanged: (value) => setState(() => _peopleSearch = value),
            decoration: const InputDecoration(
              hintText: 'Find by name or email',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'all', label: Text('All')),
              ButtonSegment(value: 'customer', label: Text('Customers')),
              ButtonSegment(value: 'pharmacist', label: Text('Pharmacists')),
            ],
            selected: {_roleFilter},
            onSelectionChanged: (selection) =>
                setState(() => _roleFilter = selection.first),
          ),
          const SizedBox(height: 12),
          if (users.isEmpty)
            const _EmptyUsers()
          else
            for (final user in users)
              _UserCard(user: user, onStatusChange: () => _changeStatus(user)),
        ],
      ),
    );
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.primaryBlue,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: Colors.white24,
                child: Icon(icon, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(label, style: const TextStyle(color: Colors.white70)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    this.accent = AppColors.primaryBlue,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: accent),
              const SizedBox(height: 12),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({required this.user, required this.onStatusChange});

  final AdminUser user;
  final VoidCallback onStatusChange;

  @override
  Widget build(BuildContext context) {
    final role = switch (user.role) {
      'pharmacist' => 'Pharmacist',
      'admin' => 'Administrator',
      _ => 'Customer',
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: user.isActive
              ? AppColors.lightGreen
              : AppColors.border,
          foregroundColor: user.isActive
              ? AppColors.primaryGreen
              : AppColors.textSecondary,
          child: Icon(switch (user.role) {
            'pharmacist' => Icons.local_pharmacy_outlined,
            'admin' => Icons.admin_panel_settings_outlined,
            _ => Icons.person_outline_rounded,
          }),
        ),
        title: Text(
          user.name.isEmpty ? 'Unnamed user' : user.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '${user.email}\n$role • ${user.isActive ? 'Active' : 'Inactive'}',
          style: TextStyle(
            color: user.isActive ? AppColors.textSecondary : AppColors.error,
            height: 1.4,
          ),
        ),
        isThreeLine: true,
        trailing: IconButton(
          onPressed: onStatusChange,
          tooltip: user.isActive ? 'Deactivate user' : 'Reactivate user',
          color: user.isActive ? AppColors.error : AppColors.primaryGreen,
          icon: Icon(
            user.isActive
                ? Icons.person_remove_outlined
                : Icons.person_add_alt_1_outlined,
          ),
        ),
      ),
    );
  }
}

class _EmptyUsers extends StatelessWidget {
  const _EmptyUsers();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(32),
      child: Center(
        child: Text(
          'No users in this group.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      ),
    );
  }
}

class _AdminDashboardSkeleton extends StatelessWidget {
  const _AdminDashboardSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      children: const [
        SkeletonBox(width: 190, height: 28),
        SizedBox(height: 8),
        SkeletonBox(width: 250, height: 14),
        SizedBox(height: 24),
        SkeletonBox(width: double.infinity, height: 96),
        SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: SkeletonBox(width: double.infinity, height: 112)),
            SizedBox(width: 12),
            Expanded(child: SkeletonBox(width: double.infinity, height: 112)),
          ],
        ),
        SizedBox(height: 28),
        SkeletonBox(width: 100, height: 22),
        SizedBox(height: 12),
        SkeletonBox(width: double.infinity, height: 52),
        SizedBox(height: 12),
        SkeletonBox(width: double.infinity, height: 72),
        SizedBox(height: 10),
        SkeletonBox(width: double.infinity, height: 72),
      ],
    );
  }
}

class _PeopleSearchDelegate extends SearchDelegate<AdminUser?> {
  _PeopleSearchDelegate(this.users);

  final List<AdminUser> users;

  @override
  List<Widget>? buildActions(BuildContext context) => [
    if (query.isNotEmpty)
      IconButton(onPressed: () => query = '', icon: const Icon(Icons.clear)),
  ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
    onPressed: () => close(context, null),
    icon: const Icon(Icons.arrow_back),
  );

  @override
  Widget buildResults(BuildContext context) => _buildList(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildList(context);

  Widget _buildList(BuildContext context) {
    final normalized = query.trim().toLowerCase();
    final matches = users.where(
      (user) =>
          normalized.isEmpty ||
          user.name.toLowerCase().contains(normalized) ||
          user.email.toLowerCase().contains(normalized),
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final user in matches)
          ListTile(
            leading: const Icon(Icons.person_outline_rounded),
            title: Text(user.name.isEmpty ? 'Unnamed user' : user.name),
            subtitle: Text(user.email),
            onTap: () => close(context, user),
          ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 48,
              color: AppColors.border,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

String _title(String value) => value[0].toUpperCase() + value.substring(1);
