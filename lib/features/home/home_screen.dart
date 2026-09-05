import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_colors.dart';
import '../../data/repositories/medicine_repository.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
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

            TextField(
              readOnly: true,
              onTap: () => context.push('/medicines'),
              decoration: const InputDecoration(
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: AppColors.primaryBlue,
                ),
                hintText: 'Search medicines, generic names...',
              ),
            ),

            const SizedBox(height: 16),

            _BrowseButton(
              icon: Icons.medication_outlined,
              label: MedicineSearchMode.name.label,
              mode: MedicineSearchMode.name,
            ),

            const SizedBox(height: 12),

            _BrowseButton(
              icon: Icons.category_outlined,
              label: MedicineSearchMode.category.label,
              mode: MedicineSearchMode.category,
            ),

            const SizedBox(height: 12),

            _BrowseButton(
              icon: Icons.medication_liquid_outlined,
              label: MedicineSearchMode.generic.label,
              mode: MedicineSearchMode.generic,
            ),
          ],
        ),
      ),
    );
  }
}

class _BrowseButton extends StatelessWidget {
  const _BrowseButton({
    required this.icon,
    required this.label,
    required this.mode,
  });

  final IconData icon;
  final String label;
  final MedicineSearchMode mode;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () => context.push('/medicines?mode=${mode.name}'),
        icon: Icon(icon),
        label: Text(label),
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

        const Spacer(),

        IconButton(
          onPressed: () {},
          icon: const Icon(
            Icons.shopping_cart_outlined,
            color: AppColors.primaryBlue,
          ),
        ),

        IconButton(
          onPressed: () {},
          icon: const Icon(
            Icons.person_outline_rounded,
            color: AppColors.primaryBlue,
          ),
        ),
      ],
    );
  }
}
