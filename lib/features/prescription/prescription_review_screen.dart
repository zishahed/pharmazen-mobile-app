import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme/app_colors.dart';
import '../../data/remote/prescription_api_client.dart';
import 'prescription_providers.dart';

/// One pending request, opened from the pharmacist queue.
///
/// It is a full page rather than a panel so the AppBar's back button returns to
/// the queue without extra navigation state.
class PrescriptionReviewScreen extends ConsumerWidget {
  const PrescriptionReviewScreen({super.key, required this.prescriptionId});

  final String prescriptionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(prescriptionDetailProvider(prescriptionId));

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Prescription review'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
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
                const Text(
                  'Could not load this prescription.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () =>
                      ref.invalidate(prescriptionDetailProvider(prescriptionId)),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
        data: (prescription) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              if (!prescription.isPending) ...[
                _DecisionCard(prescription: prescription),
                const SizedBox(height: 16),
              ],
              _PatientCard(prescription: prescription),
              const SizedBox(height: 12),
              _RequestCard(prescription: prescription),
              const SizedBox(height: 12),
              _Attachments(urls: prescription.fileUrls),
              if (prescription.isPending) ...[
                const SizedBox(height: 16),
                _ReviewForm(prescription: prescription),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _PatientCard extends StatelessWidget {
  const _PatientCard({required this.prescription});

  final Prescription prescription;

  @override
  Widget build(BuildContext context) {
    final name = prescription.customerName?.trim();
    final email = prescription.customerEmail?.trim();

    return _SectionCard(
      title: 'Patient',
      child: Column(
        children: [
          _InfoRow(
            label: 'Name',
            value: name == null || name.isEmpty ? 'Unknown' : name,
          ),
          const SizedBox(height: 8),
          _InfoRow(
            label: 'Email',
            value: email == null || email.isEmpty ? 'Not provided' : email,
          ),
        ],
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.prescription});

  final Prescription prescription;

  @override
  Widget build(BuildContext context) {
    final comment = prescription.comment?.trim();

    return _SectionCard(
      title: 'Request',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(label: 'Medicine', value: prescription.medicineName),
          const SizedBox(height: 8),
          _InfoRow(
            label: 'Course',
            value:
                '${_fmtDate(prescription.startDate)} - '
                '${_fmtDate(prescription.endDate)}',
          ),
          const SizedBox(height: 8),
          _InfoRow(
            label: 'Submitted',
            value: _fmtDateTime(prescription.createdAt),
          ),
          if (comment != null && comment.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              'CUSTOMER NOTE',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              comment,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Attachments extends StatelessWidget {
  const _Attachments({required this.urls});

  final List<String> urls;

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Could not open the file.')));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Could not open the file.')));
      }
    }
  }

  void _previewImage(BuildContext context, String url) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                child: Center(
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Text(
                      'Could not load this image.',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: SafeArea(
                child: IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white),
                  tooltip: 'Close',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Attachments',
      child: urls.isEmpty
          ? const Text(
              'No files attached.',
              style: TextStyle(color: AppColors.textSecondary),
            )
          : Column(
              children: [
                for (var i = 0; i < urls.length; i++)
                  Padding(
                    padding: EdgeInsets.only(bottom: i == urls.length - 1 ? 0 : 10),
                    child: _isPdf(urls[i])
                        ? ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: _FileIcon(
                              icon: Icons.picture_as_pdf_outlined,
                              color: AppColors.error,
                            ),
                            title: Text(
                              'Prescription PDF ${i + 1}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            subtitle: const Text(
                              'Tap to open the document',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.textSecondary,
                              ),
                            ),
                            trailing: const Icon(Icons.open_in_new_rounded),
                            onTap: () => _open(context, urls[i]),
                          )
                        : InkWell(
                            onTap: () => _previewImage(context, urls[i]),
                            borderRadius: BorderRadius.circular(12),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Stack(
                                alignment: Alignment.bottomRight,
                                children: [
                                  Image.network(
                                    urls[i],
                                    height: 180,
                                    width: double.infinity,
                                    fit: BoxFit.cover,
                                    loadingBuilder: (context, child, progress) {
                                      if (progress == null) return child;
                                      return const SizedBox(
                                        height: 180,
                                        child: Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                      );
                                    },
                                    errorBuilder: (_, _, _) => Container(
                                      height: 180,
                                      alignment: Alignment.center,
                                      color: AppColors.background,
                                      child: const Text(
                                        'Could not load this image.',
                                        style: TextStyle(
                                          color: AppColors.textSecondary,
                                        ),
                                      ),
                                    ),
                                  ),
                                  Container(
                                    margin: const EdgeInsets.all(8),
                                    padding: const EdgeInsets.all(6),
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.zoom_in_rounded,
                                      size: 18,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),
              ],
            ),
    );
  }
}

class _FileIcon extends StatelessWidget {
  const _FileIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 20,
      backgroundColor: color.withValues(alpha: 0.12),
      child: Icon(icon, color: color),
    );
  }
}

class _ReviewForm extends ConsumerStatefulWidget {
  const _ReviewForm({required this.prescription});

  final Prescription prescription;

  @override
  ConsumerState<_ReviewForm> createState() => _ReviewFormState();
}

class _ReviewFormState extends ConsumerState<_ReviewForm> {
  late final TextEditingController _note;
  late final TextEditingController _quantity;

  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _note = TextEditingController(text: widget.prescription.reviewNote ?? '');
    _quantity = TextEditingController(
      text: widget.prescription.maxQuantity.toString(),
    );
  }

  @override
  void dispose() {
    _note.dispose();
    _quantity.dispose();
    super.dispose();
  }

  Future<void> _submit(String status) async {
    if (_submitting) return;

    final note = _note.text.trim();
    if (status == 'rejected' && note.isEmpty) {
      setState(
        () => _error =
            'Add a reason for the rejection. The customer will see this note.',
      );
      return;
    }

    int? quantity;
    if (status == 'approved') {
      quantity = int.tryParse(_quantity.text.trim());
      if (quantity == null || quantity < 1) {
        setState(() => _error = 'Authorised quantity must be a whole number.');
        return;
      }
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await ref.read(prescriptionApiClientProvider).review(
        id: widget.prescription.id,
        status: status,
        reviewNote: note,
        maxQuantity: quantity,
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        status == 'approved'
            ? 'Prescription approved.'
            : 'Prescription rejected.',
      );
    } on PrescriptionException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not submit the review. Try again.');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Your decision',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _quantity,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Authorised quantity (units)',
              helperText:
                  'How many units this approval allows the customer to order.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _note,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Note for the customer',
              helperText:
                  'Required when rejecting — the customer sees this reason.',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  size: 18,
                  color: AppColors.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: AppColors.error,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _submitting ? null : () => _submit('rejected'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: BorderSide(
                      color: AppColors.error.withValues(alpha: 0.5),
                    ),
                    minimumSize: const Size.fromHeight(48),
                  ),
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('Reject'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _submitting ? null : () => _submit('approved'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primaryBlue,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  icon: _submitting
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.check_rounded),
                  label: const Text('Approve'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DecisionCard extends StatelessWidget {
  const _DecisionCard({required this.prescription});

  final Prescription prescription;

  @override
  Widget build(BuildContext context) {
    final rejected = prescription.isRejected;
    final color = rejected ? AppColors.error : AppColors.primaryGreen;
    final note = prescription.reviewNote?.trim();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                rejected ? Icons.cancel_outlined : Icons.verified_rounded,
                color: color,
              ),
              const SizedBox(width: 8),
              Text(
                rejected ? 'Rejected' : 'Approved',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ],
          ),
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              note,
              style: const TextStyle(
                fontSize: 13,
                color: AppColors.textPrimary,
              ),
            ),
          ],
          if (prescription.isApproved) ...[
            const SizedBox(height: 8),
            Text(
              '${prescription.remainingQuantity ?? prescription.maxQuantity} '
              'of ${prescription.maxQuantity} units remaining',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

bool _isPdf(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  return path.endsWith('.pdf') || path.contains('/raw/upload/');
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
