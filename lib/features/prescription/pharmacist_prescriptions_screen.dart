import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/widgets/skeletons.dart';
import '../../data/remote/prescription_api_client.dart';
import 'prescription_providers.dart';
import 'prescription_review_screen.dart';

/// The Prescription tab for a pharmacist: the shared pending-review queue.
///
/// Customers get the upload form instead; [PrescriptionScreen] picks the layout
/// from the signed-in role.
class PharmacistPrescriptionsScreen extends ConsumerWidget {
  const PharmacistPrescriptionsScreen({super.key});

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    Prescription prescription,
  ) async {
    final message = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            PrescriptionReviewScreen(prescriptionId: prescription.id),
      ),
    );
    if (message == null) return;

    await ref.read(pendingPrescriptionsProvider.notifier).refresh();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(pendingPrescriptionsProvider);

    return RefreshIndicator(
      onRefresh: () =>
          ref.read(pendingPrescriptionsProvider.notifier).refresh(),
      child: async.when(
        loading: () => const _ReviewQueueSkeleton(),
        error: (error, _) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 48),
            const Icon(
              Icons.cloud_off_rounded,
              size: 48,
              color: AppColors.border,
            ),
            const SizedBox(height: 12),
            const Text(
              'Could not load the review queue.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: OutlinedButton(
                onPressed: () =>
                    ref.read(pendingPrescriptionsProvider.notifier).refresh(),
                child: const Text('Try again'),
              ),
            ),
          ],
        ),
        data: (items) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Prescription reviews',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: AppColors.textPrimary,
                              ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Requests from customers waiting for a decision.',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _CountBadge(count: items.length),
                ],
              ),
              const SizedBox(height: 20),
              if (items.isEmpty)
                const _EmptyQueue()
              else
                for (final prescription in items)
                  _PendingCard(
                    prescription: prescription,
                    onTap: () => _open(context, ref, prescription),
                  ),
            ],
          );
        },
      ),
    );
  }
}

class _ReviewQueueSkeleton extends StatelessWidget {
  const _ReviewQueueSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      children: const [
        Row(
          children: [
            Expanded(child: SkeletonBox(width: double.infinity, height: 24)),
            SizedBox(width: 16),
            SkeletonBox(width: 72, height: 28, radius: 999),
          ],
        ),
        SizedBox(height: 8),
        SkeletonBox(width: 260, height: 13),
        SizedBox(height: 20),
        _ReviewSkeletonCard(),
        SizedBox(height: 12),
        _ReviewSkeletonCard(),
        SizedBox(height: 12),
        _ReviewSkeletonCard(),
      ],
    );
  }
}

class _ReviewSkeletonCard extends StatelessWidget {
  const _ReviewSkeletonCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(14),
        child: Row(
          children: [
            SkeletonBox(width: 44, height: 44, radius: 22),
            SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(width: 170, height: 16),
                  SizedBox(height: 8),
                  SkeletonBox(width: 220, height: 12),
                  SizedBox(height: 6),
                  SkeletonBox(width: 130, height: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.lightGreen,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count pending',
        style: const TextStyle(
          color: AppColors.primaryGreen,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 64),
      child: Column(
        children: const [
          Icon(Icons.task_alt_rounded, size: 56, color: AppColors.border),
          SizedBox(height: 14),
          Text(
            'No pending prescriptions to review.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingCard extends StatelessWidget {
  const _PendingCard({required this.prescription, required this.onTap});

  final Prescription prescription;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = prescription;
    final patient = p.customerName?.trim();
    final files = p.fileUrls.length;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppColors.lightGreen,
                child: const Icon(
                  Icons.person_outline_rounded,
                  color: AppColors.primaryGreen,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            p.medicineName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.lightGreen,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Text(
                            'Pending',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primaryGreen,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      patient == null || patient.isEmpty ? 'Customer' : patient,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (p.customerEmail != null &&
                        p.customerEmail!.trim().isNotEmpty)
                      Text(
                        p.customerEmail!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    const SizedBox(height: 8),
                    _MetaLine(
                      icon: Icons.event_outlined,
                      text: '${_fmtDate(p.startDate)} - ${_fmtDate(p.endDate)}',
                    ),
                    const SizedBox(height: 3),
                    _MetaLine(
                      icon: Icons.schedule_rounded,
                      text: 'Submitted ${_fmtDateTime(p.createdAt)}',
                    ),
                    if (files > 0) ...[
                      const SizedBox(height: 3),
                      _MetaLine(
                        icon: Icons.attach_file_rounded,
                        text: '$files attachment${files == 1 ? '' : 's'}',
                      ),
                    ],
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 18),
                child: Icon(
                  Icons.chevron_right_rounded,
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

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: AppColors.textSecondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

String _fmtDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

String _fmtDateTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour < 12 ? 'AM' : 'PM';
  return '${_fmtDate(local)} $hour:$minute $period';
}
