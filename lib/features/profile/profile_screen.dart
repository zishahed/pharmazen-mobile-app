import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../data/remote/auth_api_client.dart';
import '../auth/auth_providers.dart';
import '../auth/login_screen.dart';
import 'order_providers.dart';
import 'widgets/order_history.dart';

/// The Profile tab.
///
/// It is the only place authentication appears now: signed out it *is* the
/// sign-in form, signed in it is the account summary. There is no redirect to a
/// separate login route, so browsing the catalogue never depends on a session.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(authProvider)) {
      // Restoring a persisted session; show neither the form nor stale details.
      AuthUnknown() => const Center(child: CircularProgressIndicator()),
      AuthSignedOut() => const LoginForm(),
      AuthSignedIn(:final user) => _ProfileView(user: user),
    };
  }
}

class _ProfileView extends ConsumerWidget {
  const _ProfileView({required this.user});

  final AuthUser user;

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    await ref.read(authProvider.notifier).signOut();
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Signed out.')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RefreshIndicator(
      onRefresh: () => ref.read(myOrdersProvider.notifier).refresh(),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        children: [
          _Avatar(name: user.name),
          const SizedBox(height: 20),
          Text(
            user.name.isEmpty ? 'PharmaZen user' : user.name,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Center(child: _RoleChip(role: user.role)),
          const SizedBox(height: 28),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(
              children: [
                _InfoTile(
                  icon: Icons.badge_outlined,
                  label: 'User ID',
                  value: user.id,
                  selectable: true,
                ),
                const _TileDivider(),
                _InfoTile(
                  icon: Icons.mail_outline_rounded,
                  label: 'Email',
                  value: user.email.isEmpty ? 'Not provided' : user.email,
                ),
                const _TileDivider(),
                _InfoTile(
                  icon: Icons.verified_user_outlined,
                  label: 'Role',
                  value: _titleCase(user.role),
                ),
                const _TileDivider(),
                _InfoTile(
                  icon: Icons.calendar_today_outlined,
                  label: 'Member since',
                  value: _formatDate(user.createdAt),
                ),
              ],
            ),
          ),
          const SizedBox(height: 36),
          const OrderHistory(),
          const SizedBox(height: 28),
          OutlinedButton.icon(
            onPressed: () => _signOut(context, ref),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.error,
              side: BorderSide(color: AppColors.error.withValues(alpha: 0.4)),
              minimumSize: const Size.fromHeight(50),
            ),
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part[0].toUpperCase())
        .join();

    return Center(
      child: CircleAvatar(
        radius: 44,
        backgroundColor: AppColors.lightGreen,
        child: Text(
          initials.isEmpty ? '?' : initials,
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w800,
            color: AppColors.primaryGreen,
          ),
        ),
      ),
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.role});

  final String role;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.lightGreen,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _titleCase(role),
        style: const TextStyle(
          color: AppColors.primaryGreen,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    this.selectable = false,
  });

  final IconData icon;
  final String label;
  final String value;

  /// A UUID is worth copying, so the id is selectable and monospaced.
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final valueStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: AppColors.textPrimary,
      fontFamily: selectable ? 'monospace' : null,
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.lightGreen,
            child: Icon(icon, size: 18, color: AppColors.primaryGreen),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 11,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 4),
                selectable
                    ? SelectableText(value, style: valueStyle)
                    : Text(value, style: valueStyle),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TileDivider extends StatelessWidget {
  const _TileDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, indent: 16, endIndent: 16);
  }
}

const _months = [
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

String _titleCase(String value) {
  if (value.isEmpty) return value;
  return value[0].toUpperCase() + value.substring(1);
}

/// Formats the server's ISO timestamp as `January 1, 2025`.
///
/// The refresh response omits `createdAt`, so a restored session can have no
/// date; that is reported rather than shown as a broken value.
String _formatDate(String? iso) {
  if (iso == null) return 'Unknown';
  final parsed = DateTime.tryParse(iso)?.toLocal();
  if (parsed == null) return 'Unknown';
  return '${_months[parsed.month - 1]} ${parsed.day}, ${parsed.year}';
}
