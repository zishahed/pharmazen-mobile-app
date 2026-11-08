import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_colors.dart';
import '../../data/providers/sync_providers.dart';
import '../../data/repositories/medicine_repository.dart';
import '../../data/sync/sync_engine.dart';
import '../admin/admin_dashboard_screen.dart';
import '../cart/cart_providers.dart';
import '../cart/cart_screen.dart';
import '../auth/auth_providers.dart';
import '../prescription/prescription_screen.dart';
import '../prescription/pharmacist_prescriptions_screen.dart';
import '../profile/profile_screen.dart';
import 'widgets/connectivity_banner.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _navIndex = 0;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final isAdmin = auth is AuthSignedIn && auth.user.isAdmin;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const ConnectivityBanner(),
            Expanded(
              child: switch (_navIndex) {
                0 => _buildHome(context),
                1 =>
                  isAdmin ? const AdminDashboardScreen() : const CartScreen(),
                2 =>
                  isAdmin
                      ? const PharmacistPrescriptionsScreen()
                      : const PrescriptionScreen(),
                3 => const ProfileScreen(),
                _ => _buildPlaceholder(context),
              },
            ),
          ],
        ),
      ),
      bottomNavigationBar: Consumer(
        builder: (context, ref, _) {
          final count = ref.watch(cartCountProvider);
          return NavigationBar(
            selectedIndex: _navIndex,
            onDestinationSelected: (index) => setState(() => _navIndex = index),
            backgroundColor: AppColors.surface,
            indicatorColor: AppColors.lightGreen,
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Home',
              ),
              if (isAdmin) ...[
                const NavigationDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard_rounded),
                  label: 'Admin',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.fact_check_outlined),
                  selectedIcon: Icon(Icons.fact_check_rounded),
                  label: 'Reviews',
                ),
              ] else ...[
                NavigationDestination(
                  icon: _CartIcon(
                    icon: Icons.shopping_cart_outlined,
                    count: count,
                  ),
                  selectedIcon: _CartIcon(
                    icon: Icons.shopping_cart,
                    count: count,
                  ),
                  label: 'Cart',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.description_outlined),
                  selectedIcon: Icon(Icons.description_rounded),
                  label: 'Prescription',
                ),
              ],
              const NavigationDestination(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(Icons.person_rounded),
                label: 'Profile',
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHome(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const _Header(),

        const SizedBox(height: 32),

        RichText(
          text: TextSpan(
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.w800),
            children: const [
              TextSpan(
                text: 'Your Trusted\nOnline ',
                style: TextStyle(color: AppColors.primaryBlue),
              ),
              TextSpan(
                text: 'Pharmacy',
                style: TextStyle(color: AppColors.primaryGreen),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        const Text(
          'Search medicines and access essential '
          'medicine information anytime.',
          style: TextStyle(
            color: AppColors.textSecondary,
            fontSize: 15,
            height: 1.5,
          ),
        ),

        const SizedBox(height: 28),

        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () => context.push('/medicines'),
            icon: const Icon(Icons.search_rounded),
            label: const Text('Search'),
          ),
        ),

        const SizedBox(height: 16),

        Row(
          children: const [
            Expanded(
              child: _BrowseTile(
                label: 'Drug by generic',
                mode: MedicineSearchMode.generic,
                icon: Icons.medication_outlined,
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              child: _BrowseTile(
                label: 'Drug by category',
                mode: MedicineSearchMode.category,
                icon: Icons.category_outlined,
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              child: _BrowseTile(
                label: 'Drug by Indication',
                mode: MedicineSearchMode.indication,
                icon: Icons.healing_outlined,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    final label = _navLabel(_navIndex);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.construction_rounded,
            size: 48,
            color: AppColors.border,
          ),
          const SizedBox(height: 12),
          Text(
            '$label coming soon',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _navLabel(int index) => switch (index) {
    0 => 'Home',
    1 => 'Cart',
    2 => 'Prescription',
    _ => 'Profile',
  };
}

class _CartIcon extends StatelessWidget {
  const _CartIcon({required this.icon, required this.count});

  final IconData icon;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Badge.count(
      count: count,
      isLabelVisible: count > 0,
      child: Icon(icon),
    );
  }
}

class _BrowseTile extends StatelessWidget {
  const _BrowseTile({
    required this.label,
    required this.mode,
    required this.icon,
  });

  final String label;
  final MedicineSearchMode mode;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: () => context.push('/browse?type=${mode.name}'),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: AppColors.lightGreen,
                child: Icon(icon, color: AppColors.primaryGreen),
              ),
              const SizedBox(height: 10),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends ConsumerStatefulWidget {
  const _Header();

  @override
  ConsumerState<_Header> createState() => _HeaderState();
}

class _HeaderState extends ConsumerState<_Header>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation;
  late final SyncEngine _engine;

  @override
  void initState() {
    super.initState();
    _rotation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _engine = ref.read(syncEngineProvider);
    _engine.syncActivity.addListener(_syncChanged);
    _syncChanged();
  }

  void _syncChanged() {
    if (!mounted) return;
    final syncing = _engine.syncActivity.value;
    if (syncing) {
      _rotation.repeat();
    } else {
      _rotation.stop();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _engine.syncActivity.removeListener(_syncChanged);
    _rotation.dispose();
    super.dispose();
  }

  Future<void> _sync() async {
    await _engine.sync(trigger: SyncTrigger.manual);
  }

  @override
  Widget build(BuildContext context) {
    final syncing = _engine.syncActivity.value;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        RichText(
          text: const TextSpan(
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
            children: [
              TextSpan(
                text: 'PHARMA',
                style: TextStyle(color: AppColors.primaryBlue),
              ),
              TextSpan(
                text: 'Zen',
                style: TextStyle(color: AppColors.primaryGreen),
              ),
            ],
          ),
        ),
        OutlinedButton.icon(
          onPressed: syncing ? null : _sync,
          icon: RotationTransition(
            turns: _rotation,
            child: const Icon(Icons.sync_rounded),
          ),
          label: const Text('SYNC'),
        ),
      ],
    );
  }
}
