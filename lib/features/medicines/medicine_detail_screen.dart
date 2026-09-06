import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../data/providers/medicine_providers.dart';
import '../../domain/models/medicine.dart';
import '../../domain/models/medicine_details.dart';

class MedicineDetailScreen extends ConsumerStatefulWidget {
  const MedicineDetailScreen({super.key, required this.medicine});

  final Medicine medicine;

  @override
  ConsumerState<MedicineDetailScreen> createState() =>
      _MedicineDetailScreenState();
}

class _MedicineDetailScreenState extends ConsumerState<MedicineDetailScreen> {
  MedicineDetails? _details;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final details = await ref
          .read(medicineRepositoryProvider)
          .fetchDetails(widget.medicine.genericId!);
      if (!mounted) return;
      setState(() {
        _details = details;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.medicine;

    return Scaffold(
      appBar: AppBar(title: Text(m.brandName)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildError()
              : _buildContent(m),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, size: 48, color: AppColors.error),
          const SizedBox(height: 12),
          const Text(
            'Failed to load details.',
            style: TextStyle(color: AppColors.textSecondary),
          ),
          TextButton(onPressed: _fetch, child: const Text('Try again')),
        ],
      ),
    );
  }

  Widget _buildContent(Medicine m) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildHeader(m),
        const SizedBox(height: 20),
        _buildMetaRow(m),
        const SizedBox(height: 24),
        if (_details != null) ..._buildSections(),
      ],
    );
  }

  Widget _buildHeader(Medicine m) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                m.brandName,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            if (m.isSensitive)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppColors.error,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'Sensitive',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (m.genericName != null && m.genericName!.isNotEmpty)
          Text(
            m.genericName!,
            style: const TextStyle(
              fontSize: 15,
              color: AppColors.primaryBlue,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }

  Widget _buildMetaRow(Medicine m) {
    final meta = <MapEntry<String, IconData>>[];

    if (m.type != null && m.type!.isNotEmpty) {
      meta.add(MapEntry(m.type!, Icons.category_outlined));
    }
    if (m.dosageForm != null && m.dosageForm!.isNotEmpty) {
      meta.add(MapEntry(m.dosageForm!, Icons.medication_outlined));
    }
    if (m.strength != null && m.strength!.isNotEmpty) {
      meta.add(MapEntry(m.strength!, Icons.straighten));
    }
    if (m.manufacturer != null && m.manufacturer!.isNotEmpty) {
      meta.add(MapEntry(m.manufacturer!, Icons.business_outlined));
    }
    if (m.packageContainer != null && m.packageContainer!.isNotEmpty) {
      meta.add(MapEntry(m.packageContainer!, Icons.inventory_2_outlined));
    }
    if (m.packageSize != null && m.packageSize!.isNotEmpty) {
      meta.add(MapEntry(m.packageSize!, Icons.scale_outlined));
    }

    if (meta.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: meta
          .map(
            (e) => Chip(
              avatar: Icon(e.value, size: 16),
              label: Text(e.key, style: const TextStyle(fontSize: 12)),
              backgroundColor: AppColors.lightGreen,
              side: BorderSide.none,
              padding: EdgeInsets.zero,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          )
          .toList(),
    );
  }

  List<Widget> _buildSections() {
    final d = _details!;
    return [
      _Section(
        title: 'Indication',
        icon: Icons.healing_outlined,
        extra: d.indication,
        content: d.indicationDescription,
      ),
      _Section(
        title: 'Drug Class',
        icon: Icons.category_outlined,
        content: d.drugClass,
      ),
      _Section(
        title: 'Therapeutic Class',
        icon: Icons.medication_outlined,
        content: d.therapeuticClassDescription,
      ),
      _Section(
        title: 'Pharmacology',
        icon: Icons.science_outlined,
        content: d.pharmacologyDescription,
      ),
      _Section(
        title: 'Dosage',
        icon: Icons.timer_outlined,
        content: d.dosageDescription,
      ),
      _Section(
        title: 'Administration',
        icon: Icons.local_hospital_outlined,
        content: d.administrationDescription,
      ),
      _Section(
        title: 'Drug Interactions',
        icon: Icons.warning_amber_outlined,
        content: d.interactionDescription,
      ),
      _Section(
        title: 'Contraindications',
        icon: Icons.block_outlined,
        content: d.contraindicationsDescription,
      ),
      _Section(
        title: 'Side Effects',
        icon: Icons.report_outlined,
        content: d.sideEffectsDescription,
      ),
      _Section(
        title: 'Pregnancy & Lactation',
        icon: Icons.pregnant_woman_outlined,
        content: d.pregnancyAndLactationDescription,
      ),
      _Section(
        title: 'Precautions',
        icon: Icons.info_outline,
        content: d.precautionsDescription,
      ),
      _Section(
        title: 'Pediatric Usage',
        icon: Icons.child_care_outlined,
        content: d.pediatricUsageDescription,
      ),
      _Section(
        title: 'Overdose Effects',
        icon: Icons.dangerous_outlined,
        content: d.overdoseEffectsDescription,
      ),
      _Section(
        title: 'Duration of Treatment',
        icon: Icons.schedule_outlined,
        content: d.durationOfTreatmentDescription,
      ),
      _Section(
        title: 'Reconstitution',
        icon: Icons.water_drop_outlined,
        content: d.reconstitutionDescription,
      ),
      _Section(
        title: 'Storage Conditions',
        icon: Icons.inventory_outlined,
        content: d.storageConditionsDescription,
      ),
    ].where((w) => w.hasContent).toList();
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    this.content,
    this.extra,
  });

  final String title;
  final IconData icon;
  final String? content;
  final String? extra;

  bool get hasContent =>
      (content != null && content!.trim().isNotEmpty) ||
      (extra != null && extra!.trim().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final stripped = _stripHtml(content);
    final strippedExtra = _stripHtml(extra);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Card(
        child: ExpansionTile(
          leading: Icon(icon, color: AppColors.primaryBlue),
          title: Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          children: [
            if (strippedExtra != null && strippedExtra.isNotEmpty) ...[
              Text(
                strippedExtra,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                  height: 1.5,
                ),
              ),
              if (stripped != null && stripped.isNotEmpty)
                const SizedBox(height: 10),
            ],
            if (stripped != null && stripped.isNotEmpty)
              Text(
                stripped,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textPrimary,
                  height: 1.6,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String? _stripHtml(String? html) {
    if (html == null || html.trim().isEmpty) return null;
    return html
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</?li>'), '\n')
        .replaceAll(RegExp(r'</?p>'), '\n')
        .replaceAll(RegExp(r'</?strong>'), '')
        .replaceAll(RegExp(r'</?b>'), '')
        .replaceAll(RegExp(r'</?em>'), '')
        .replaceAll(RegExp(r'</?i>'), '')
        .replaceAll(RegExp(r'</?ul>'), '')
        .replaceAll(RegExp(r'</?ol>'), '')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'&nbsp;'), ' ')
        .replaceAll(RegExp(r'&amp;'), '&')
        .replaceAll(RegExp(r'&lt;'), '<')
        .replaceAll(RegExp(r'&gt;'), '>')
        .replaceAll(RegExp(r'&quot;'), '"')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }
}
