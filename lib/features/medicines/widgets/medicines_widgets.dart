import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../domain/models/medicine.dart';

class MedicineTile extends StatelessWidget {
  const MedicineTile({super.key, required this.medicine});

  final Medicine medicine;

  @override
  Widget build(BuildContext context) {
    final meta = [
      medicine.strength,
      medicine.dosageForm,
    ].where((line) => line != null && line.isNotEmpty).join(' • ');

    return Card(
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: AppColors.lightGreen,
          foregroundColor: AppColors.primaryGreen,
          child: Icon(Icons.medication_outlined),
        ),
        title: Text(
          medicine.brandName,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (medicine.genericName != null &&
                medicine.genericName!.isNotEmpty)
              Text(
                medicine.genericName!,
                style: const TextStyle(color: AppColors.primaryBlue),
              ),
            if (meta.isNotEmpty)
              Text(meta, style: const TextStyle(fontSize: 12)),
          ],
        ),
        isThreeLine: meta.isNotEmpty &&
            (medicine.genericName?.isNotEmpty ?? false),
      ),
    );
  }
}

class MessagePlaceholder extends StatelessWidget {
  const MessagePlaceholder({
    super.key,
    required this.icon,
    required this.message,
    this.trailing,
  });

  final IconData icon;
  final String message;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: AppColors.border),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          if (trailing != null) ...[
            const SizedBox(height: 4),
            trailing!,
          ],
        ],
      ),
    );
  }
}