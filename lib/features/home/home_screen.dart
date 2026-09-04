import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_colors.dart';

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

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  context.push('/medicines');
                },
                icon: const Icon(Icons.medication_outlined),
                label: const Text('Browse All Medicines'),
              ),
            ),

            const SizedBox(height: 36),

            Text(
              'Why PharmaZen?',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),

            const SizedBox(height: 16),

            const _FeatureCard(
              icon: Icons.offline_bolt_outlined,
              title: 'Works Offline',
              description:
                  'Search the local medicine database even without internet.',
            ),

            const SizedBox(height: 12),

            const _FeatureCard(
              icon: Icons.inventory_2_outlined,
              title: 'Live Stock When Online',
              description: 'Connect to PharmaZen services to check current availability.',
            ),

            const SizedBox(height: 12),

            const _FeatureCard(
              icon: Icons.receipt_long_outlined,
              title: 'Orders & Prescriptions',
              description: 'Order medicines and submit prescriptions securely when online.',
            ),
          ],
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

class _FeatureCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: AppColors.lightGreen,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.medication_outlined,
                color: AppColors.primaryGreen,
              ),
            ),

            const SizedBox(width: 16),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),

                  const SizedBox(height: 5),

                  Text(
                    description,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
