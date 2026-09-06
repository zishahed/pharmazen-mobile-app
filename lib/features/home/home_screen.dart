import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_colors.dart';
import '../../data/repositories/medicine_repository.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _navIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _navIndex == 0 ? _buildHome(context) : _buildPlaceholder(context),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _navIndex,
        onDestinationSelected: (index) => setState(() => _navIndex = index),
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.lightGreen,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
          NavigationDestination(
            icon: Icon(Icons.shopping_cart_outlined),
            selectedIcon: Icon(Icons.shopping_cart),
            label: 'Cart',
          ),
          NavigationDestination(
            icon: Icon(Icons.description_outlined),
            selectedIcon: Icon(Icons.description_rounded),
            label: 'Prescription',
          ),
          NavigationDestination(
            icon: Icon(Icons.favorite_outline),
            selectedIcon: Icon(Icons.favorite),
            label: 'Favorites',
          ),
        ],
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
            style: Theme.of(context)
                .textTheme
                .headlineMedium
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
        1 => 'Profile',
        2 => 'Cart',
        3 => 'Prescription',
        _ => 'Favorites',
      };
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

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Row(
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
      ],
    );
  }
}