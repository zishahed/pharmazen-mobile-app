import 'package:drift/drift.dart';

import '../../domain/models/medicine.dart';
import '../db/app_database.dart';

enum MedicineSearchMode { name, category, generic, indication }

extension MedicineSearchModeX on MedicineSearchMode {
  String get label => switch (this) {
        MedicineSearchMode.name => 'Browse medicine by name',
        MedicineSearchMode.category => 'Browse medicine by category',
        MedicineSearchMode.generic => 'Browse medicine by generic',
        MedicineSearchMode.indication => 'Browse medicine by indication',
      };

  String get hint => switch (this) {
        MedicineSearchMode.name => 'Search medicine names...',
        MedicineSearchMode.category => 'Search by category or drug class...',
        MedicineSearchMode.generic => 'Search generic names...',
        MedicineSearchMode.indication => 'Search by indication, e.g. fever...',
      };

  String get browseTitle => switch (this) {
        MedicineSearchMode.name => 'Search medicine',
        MedicineSearchMode.category => 'Drug by category',
        MedicineSearchMode.generic => 'Drug by generic',
        MedicineSearchMode.indication => 'Drug by Indication',
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

  Future<List<String>> allValues(MedicineSearchMode mode) async {
    final column = switch (mode) {
      MedicineSearchMode.generic => 'generic_name',
      MedicineSearchMode.category => 'drug_class',
      MedicineSearchMode.indication => 'indication',
      MedicineSearchMode.name => throw ArgumentError.value(
          mode,
          'mode',
          'Not a browseable search mode.',
        ),
    };

    final rows = await _db.customSelect('''
      SELECT DISTINCT $column AS value
      FROM generics
      WHERE $column IS NOT NULL AND TRIM($column) != ''
      ORDER BY $column COLLATE NOCASE ASC
    ''').get();

    return rows
        .map((row) => row.data['value'] as String)
        .toList(growable: false);
  }

  Future<List<Medicine>> searchByExact(
    String value,
    MedicineSearchMode mode,
  ) async {
    final rows = await _db
        .customSelect(
          _buildExactQuery(mode),
          variables: [Variable.withString(value.trim())],
        )
        .get();

    return rows.map(_toMedicine).toList(growable: false);
  }

  String _buildExactQuery(MedicineSearchMode mode) {
    return switch (mode) {
      MedicineSearchMode.category => '''
        SELECT m.brand_id, m.brand_name, m.type, m.slug, m.dosage_form,
               m.generic_name, m.strength, m.manufacturer,
               m.package_container, m.package_size, m.generic_id, m.isSensitive
        FROM medicines m
        INNER JOIN generics g ON g.generic_id = m.generic_id
        WHERE g.drug_class = ?
        ORDER BY m.generic_name COLLATE NOCASE ASC,
                m.brand_name COLLATE NOCASE ASC
      ''',
      MedicineSearchMode.indication => '''
        SELECT m.brand_id, m.brand_name, m.type, m.slug, m.dosage_form,
               m.generic_name, m.strength, m.manufacturer,
               m.package_container, m.package_size, m.generic_id, m.isSensitive
        FROM medicines m
        INNER JOIN generics g ON g.generic_id = m.generic_id
        WHERE g.indication = ?
        ORDER BY m.generic_name COLLATE NOCASE ASC,
                m.brand_name COLLATE NOCASE ASC
      ''',
      _ => '''
        SELECT brand_id, brand_name, type, slug, dosage_form,
               generic_name, strength, manufacturer,
               package_container, package_size, generic_id, isSensitive
        FROM medicines
        WHERE generic_name = ?
        ORDER BY generic_name COLLATE NOCASE ASC,
                brand_name COLLATE NOCASE ASC
      ''',
    };
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
      MedicineSearchMode.indication => '''
        SELECT m.brand_id, m.brand_name, m.type, m.slug, m.dosage_form,
               m.generic_name, m.strength, m.manufacturer,
               m.package_container, m.package_size, m.generic_id, m.isSensitive
        FROM medicines m
        INNER JOIN generics g ON g.generic_id = m.generic_id
        WHERE g.indication LIKE ?
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