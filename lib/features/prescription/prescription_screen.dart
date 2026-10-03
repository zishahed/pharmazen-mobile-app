import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/theme/app_colors.dart';
import '../../data/providers/medicine_providers.dart';
import '../../data/remote/prescription_api_client.dart';
import '../../data/repositories/medicine_repository.dart';
import '../../domain/models/medicine.dart';
import '../auth/auth_providers.dart';
import 'prescription_providers.dart';

/// Prescription tab: submit a request and see past ones.
///
/// This is a *request*, not a file drop — the backend requires a medicine and a
/// course window alongside the image, because a pharmacist reviews the pair.
class PrescriptionScreen extends ConsumerStatefulWidget {
  const PrescriptionScreen({super.key});

  @override
  ConsumerState<PrescriptionScreen> createState() => _PrescriptionScreenState();
}

class _PrescriptionScreenState extends ConsumerState<PrescriptionScreen> {
  final _medicineQuery = TextEditingController();
  final _comment = TextEditingController();

  Medicine? _medicine;
  List<Medicine> _results = const <Medicine>[];
  List<PrescriptionAttachment> _files = const <PrescriptionAttachment>[];
  DateTime? _start;
  DateTime? _end;

  bool _searching = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _medicineQuery.dispose();
    _comment.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      setState(() => _results = const <Medicine>[]);
      return;
    }
    setState(() => _searching = true);
    try {
      final found = await ref
          .read(medicineRepositoryProvider)
          .search(trimmed, MedicineSearchMode.name);
      if (!mounted) return;
      setState(() => _results = found.take(20).toList(growable: false));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _pick(ImageSource source) async {
    final picker = ImagePicker();
    // No maxWidth here: `prepare` owns resizing, and a second resize pass would
    // discard detail before the compression step has decided what it needs.
    final picked = await picker.pickImage(source: source);
    if (picked == null || !mounted) return;

    if (_files.length >= kMaxUploadFiles) {
      setState(
        () => _error = 'You can attach at most $kMaxUploadFiles files.',
      );
      return;
    }

    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() {
      _files = [..._files, PrescriptionAttachment(
        bytes: bytes,
        filename: picked.name,
        mediaType: picked.mimeType ?? 'image/jpeg',
      )];
      _error = null;
    });
  }

  /// PDFs come from the file browser rather than `image_picker`: its
  /// `pickFile`/`FileType` API was removed in image_picker 1.2.x, and
  /// `pickMedia` cannot filter by media type.
  Future<void> _pickDocument() async {
    const group = XTypeGroup(
      label: 'Prescription PDF',
      extensions: <String>['pdf'],
    );
    final picked = await openFile(acceptedTypeGroups: const <XTypeGroup>[group]);
    if (picked == null || !mounted) return;
    if (_files.length >= kMaxUploadFiles) {
      setState(
        () => _error = 'You can attach at most $kMaxUploadFiles files.',
      );
      return;
    }
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() {
      _files = [..._files, PrescriptionAttachment(
        bytes: bytes,
        filename: picked.name,
        mediaType: 'application/pdf',
      )];
      _error = null;
    });
  }

  Future<void> _chooseDate({required bool isStart}) async {
    final now = DateTime.now();
    final initial = isStart
        ? (_start ?? now)
        : (_end ?? _start?.add(const Duration(days: 30)) ?? now);

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 2)),
    );
    if (picked == null || !mounted) return;

    setState(() {
      if (isStart) {
        _start = picked;
        // Keep the window coherent: an end before the start is rejected by the
        // server, so nudge it rather than letting the user submit an invalid
        // pair.
        if (_end != null && _end!.isBefore(picked)) {
          _end = picked.add(const Duration(days: 30));
        }
      } else {
        _end = picked;
      }
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_submitting) return;

    final medicine = _medicine;
    final start = _start;
    final end = _end;

    if (medicine == null) {
      setState(() => _error = 'Search for and select the medicine.');
      return;
    }
    if (medicine.remoteId == null) {
      setState(
        () => _error =
            'That medicine has not synced yet. Run a sync, then try again.',
      );
      return;
    }
    if (_files.isEmpty) {
      setState(() => _error = 'Attach a photo or PDF of the prescription.');
      return;
    }
    if (start == null || end == null) {
      setState(() => _error = 'Select the start and end dates.');
      return;
    }
    if (end.isBefore(start)) {
      setState(() => _error = 'The end date must be after the start date.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await ref.read(prescriptionApiClientProvider).upload(
        files: _files,
        medicineId: medicine.remoteId!,
        medicineName: medicine.brandName,
        startDate: start,
        endDate: end,
        comment: _comment.text,
      );
      if (!mounted) return;
      setState(() {
        _files = const <PrescriptionAttachment>[];
        _comment.clear();
        _medicine = null;
        _medicineQuery.clear();
        _results = const <Medicine>[];
        _start = null;
        _end = null;
      });
      await ref.read(myPrescriptionsProvider.notifier).refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Prescription sent for review.'),
        ),
      );
    } on PrescriptionException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      // `PrescriptionApiClient` words both a rejection and a transport failure,
      // so reaching here means the reply did not parse.
      if (mounted) {
        setState(() => _error = 'Upload failed. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    if (auth is! AuthSignedIn) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Sign in to upload a prescription.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(myPrescriptionsProvider.notifier).refresh(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const _SectionTitle('New prescription request'),
          const SizedBox(height: 12),
          _MedicinePicker(
            controller: _medicineQuery,
            selected: _medicine,
            results: _results,
            searching: _searching,
            onChanged: _search,
            onSelect: (m) => setState(() {
              _medicine = m;
              _results = const <Medicine>[];
              _medicineQuery.text = m.brandName;
              _error = null;
            }),
            onClear: () => setState(() {
              _medicine = null;
              _medicineQuery.clear();
            }),
          ),
          const SizedBox(height: 16),
          _DateRow(
            start: _start,
            end: _end,
            onStart: () => _chooseDate(isStart: true),
            onEnd: () => _chooseDate(isStart: false),
          ),
          const SizedBox(height: 16),
          _AttachmentPicker(
            files: _files,
            onCamera: () => _pick(ImageSource.camera),
            onGallery: () => _pick(ImageSource.gallery),
            onPdf: _pickDocument,
            onRemove: (i) => setState(() {
              final next = [..._files]..removeAt(i);
              _files = next;
            }),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _comment,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Note for the pharmacist (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            _ErrorText(_error!),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primaryBlue,
              minimumSize: const Size.fromHeight(50),
            ),
            child: _submitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Send for review'),
          ),
          const SizedBox(height: 32),
          const _SectionTitle('Your prescriptions'),
          const SizedBox(height: 12),
          const _PrescriptionList(),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.bold,
        color: AppColors.textPrimary,
      ),
    );
  }
}

class _MedicinePicker extends StatelessWidget {
  const _MedicinePicker({
    required this.controller,
    required this.selected,
    required this.results,
    required this.searching,
    required this.onChanged,
    required this.onSelect,
    required this.onClear,
  });

  final TextEditingController controller;
  final Medicine? selected;
  final List<Medicine> results;
  final bool searching;
  final ValueChanged<String> onChanged;
  final ValueChanged<Medicine> onSelect;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          onChanged: onChanged,
          decoration: InputDecoration(
            labelText: 'Medicine',
            prefixIcon: const Icon(Icons.medication_outlined),
            suffixIcon: selected != null
                ? IconButton(
                    onPressed: onClear,
                    icon: const Icon(Icons.close),
                    tooltip: 'Clear',
                  )
                : (searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null),
            border: const OutlineInputBorder(),
          ),
        ),
        if (results.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 4),
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: results.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final m = results[i];
                return ListTile(
                  dense: true,
                  title: Text(m.brandName),
                  subtitle: Text(
                    [
                      m.strength,
                      if (m.genericName != null) m.genericName,
                      if (m.remoteId == null) 'not synced',
                    ].whereType<String>().join(' - '),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  onTap: () => onSelect(m),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.start,
    required this.end,
    required this.onStart,
    required this.onEnd,
  });

  final DateTime? start;
  final DateTime? end;
  final VoidCallback onStart;
  final VoidCallback onEnd;

  String _fmt(DateTime? d) => d == null
      ? 'Select'
      : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.event_outlined, size: 18),
            label: Text('Start: ${_fmt(start)}'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: onEnd,
            icon: const Icon(Icons.event_available_outlined, size: 18),
            label: Text('End: ${_fmt(end)}'),
          ),
        ),
      ],
    );
  }
}

class _AttachmentPicker extends StatelessWidget {
  const _AttachmentPicker({
    required this.files,
    required this.onCamera,
    required this.onGallery,
    required this.onPdf,
    required this.onRemove,
  });

  final List<PrescriptionAttachment> files;
  final VoidCallback onCamera;
  final VoidCallback onGallery;
  final VoidCallback onPdf;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: files.length >= kMaxUploadFiles ? null : onCamera,
              icon: const Icon(Icons.photo_camera_outlined, size: 18),
              label: const Text('Camera'),
            ),
            OutlinedButton.icon(
              onPressed: files.length >= kMaxUploadFiles ? null : onGallery,
              icon: const Icon(Icons.photo_library_outlined, size: 18),
              label: const Text('Gallery'),
            ),
            OutlinedButton.icon(
              onPressed: files.length >= kMaxUploadFiles ? null : onPdf,
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
              label: const Text('PDF'),
            ),
          ],
        ),
        if (files.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (var i = 0; i < files.length; i++)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                files[i].isPdf
                    ? Icons.picture_as_pdf_outlined
                    : Icons.image_outlined,
              ),
              title: Text(
                files[i].filename,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                '${(files[i].bytes.length / 1024).round()} KB',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                ),
              ),
              trailing: IconButton(
                onPressed: () => onRemove(i),
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Remove',
              ),
            ),
        ],
      ],
    );
  }
}

class _PrescriptionList extends ConsumerWidget {
  const _PrescriptionList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myPrescriptionsProvider);

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'Could not load your prescriptions.',
          style: const TextStyle(color: AppColors.error),
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No prescriptions yet.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          );
        }
        return Column(
          children: [for (final p in items) _PrescriptionTile(prescription: p)],
        );
      },
    );
  }
}

class _PrescriptionTile extends StatelessWidget {
  const _PrescriptionTile({required this.prescription});

  final Prescription prescription;

  Color _statusColor() {
    if (prescription.isApproved) return AppColors.primaryGreen;
    if (prescription.isRejected) return AppColors.error;
    return AppColors.textSecondary;
  }

  String _statusLabel() {
    if (prescription.isApproved) return 'Approved';
    if (prescription.isRejected) return 'Rejected';
    return 'Pending review';
  }

  @override
  Widget build(BuildContext context) {
    final p = prescription;
    final remaining = p.remainingQuantity;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    p.medicineName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                Text(
                  _statusLabel(),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _statusColor(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${_fmt(p.startDate)} to ${_fmt(p.endDate)}',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
            if (remaining != null) ...[
              const SizedBox(height: 4),
              Text(
                '$remaining of ${p.maxQuantity} remaining'
                '${p.consumedQuantity > 0 ? ' (${p.consumedQuantity} used)' : ''}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
            if (p.isRejected && p.reviewNote != null) ...[
              const SizedBox(height: 8),
              Text(
                p.reviewNote!,
                style: const TextStyle(fontSize: 12, color: AppColors.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline_rounded,
            size: 18, color: AppColors.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(color: AppColors.error, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

String _fmt(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';