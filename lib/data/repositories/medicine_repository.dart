import 'package:drift/drift.dart';

import '../../domain/models/medicine.dart';
import '../db/app_database.dart';

enum MedicineSearchMode { name, category, generic }

extension MedicineSearchModeX on MedicineSearchMode {
  String get label => switch (this) {
        MedicineSearchMode.name => 'Browse medicine by name',
        MedicineSearchMode.category => 'Browse medicine by category',
        MedicineSearchMode.generic => 'Browse medicine by generic',
      };

  String get hint => switch (this) {
        MedicineSearchMode.name => 'Search medicine names...',
        MedicineSearchMode.category => 'Search by category or drug class...',
        MedicineSearchMode.generic => 'Search generic names...',
      };
}

class MedicineRepository {
  MedicineRepository(this._db);

  final AppDatabase _db;

  Future<List<Medicine>> search(String query, MedicineSearchMode mode) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final rows = await _db
        .customSelect(_buildQuery(mode), variables: [Variable.withString('%$trimmed%')])
        .get();

    return rows.map(_toMedicine).toList(growable: false);
  }

  String _buildQuery(MedicineSearchMode mode) {
    const select = '''
      SELECT brand_id, brand_name, type, slug, dosage_form, generic_name,
             strength, manufacturer, package_container, package_size,
             generic_id, isSensitive
      FROM medicines
    ''';

    return switch (mode) {
      MedicineSearchMode.name => '''
        $select
        WHERE brand_name LIKE ?
        ORDER BY brand_name COLLATE NOCASE ASC
        LIMIT 100
      ''',
      MedicineSearchMode.generic => '''
        $select
        WHERE generic_name LIKE ?
        ORDER BY generic_name COLLATE NOCASE ASC,
                brand_name COLLATE NOCASE ASC
        LIMIT 100
      ''',
      MedicineSearchMode.category => '''
        SELECT m.brand_id, m.brand_name, m.type, m.slug, m.dosage_form,
               m.generic_name, m.strength, m.manufacturer,
               m.package_container, m.package_size, m.generic_id, m.isSensitive
        FROM medicines m
        INNER JOIN generics g ON g.generic_id = m.generic_id
        WHERE g.drug_class LIKE ?
        ORDER BY m.generic_name COLLATE NOCASE ASC,
                m.brand_name COLLATE NOCASE ASC
        LIMIT 100
      ''',
    };
  }

  Medicine _toMedicine(QueryRow row) {
    final data = row.data;
    return Medicine(
      brandId: data['brand_id'] as int,
      brandName: data['brand_name'] as String,
      type: data['type'] as String?,
      slug: data['slug'] as String?,
      dosageForm: data['dosage_form'] as String?,
      genericName: data['generic_name'] as String?,
      strength: data['strength'] as String?,
      manufacturer: data['manufacturer'] as String?,
      packageContainer: data['package_container'] as String?,
      packageSize: data['package_size'] as String?,
      genericId: data['generic_id'] as int?,
      isSensitive: (data['isSensitive'] as int) == 1,
    );
  }
}