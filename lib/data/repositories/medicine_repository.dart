import 'package:drift/drift.dart';

import '../../domain/models/medicine.dart';
import '../../domain/models/medicine_details.dart';
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

  Future<MedicineDetails?> fetchDetails(int genericId) async {
    final rows = await _db.customSelect('''
      SELECT generic_id, generic_name, slug, monograph_link,
             drug_class, indication, indication_description,
             therapeutic_class_description, pharmacology_description,
             dosage_description, administration_description,
             interaction_description, contraindications_description,
             side_effects_description, pregnancy_and_lactation_description,
             precautions_description, pediatric_usage_description,
             overdose_effects_description, duration_of_treatment_description,
             reconstitution_description, storage_conditions_description
      FROM generics
      WHERE generic_id = ?
    ''', variables: [Variable.withInt(genericId)]).get();

    if (rows.isEmpty) return null;
    final data = rows.single.data;

    return MedicineDetails(
      genericId: data['generic_id'] as int,
      genericName: data['generic_name'] as String?,
      slug: data['slug'] as String?,
      monographLink: data['monograph_link'] as String?,
      drugClass: data['drug_class'] as String?,
      indication: data['indication'] as String?,
      indicationDescription: data['indication_description'] as String?,
      therapeuticClassDescription: data['therapeutic_class_description'] as String?,
      pharmacologyDescription: data['pharmacology_description'] as String?,
      dosageDescription: data['dosage_description'] as String?,
      administrationDescription: data['administration_description'] as String?,
      interactionDescription: data['interaction_description'] as String?,
      contraindicationsDescription:
          data['contraindications_description'] as String?,
      sideEffectsDescription: data['side_effects_description'] as String?,
      pregnancyAndLactationDescription:
          data['pregnancy_and_lactation_description'] as String?,
      precautionsDescription: data['precautions_description'] as String?,
      pediatricUsageDescription: data['pediatric_usage_description'] as String?,
      overdoseEffectsDescription: data['overdose_effects_description'] as String?,
      durationOfTreatmentDescription:
          data['duration_of_treatment_description'] as String?,
      reconstitutionDescription: data['reconstitution_description'] as String?,
      storageConditionsDescription:
          data['storage_conditions_description'] as String?,
    );
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