import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../remote/sync_manifest.dart';

/// Maintains the local `generics` table and maps server generics onto it.
///
/// Two jobs:
///
/// * Upsert generics that arrive in a delta page, and propagate a renamed generic
///   back onto the medicines that point at it. Neon's `generic_id` is used
///   verbatim as the local primary key, so no mapping table is needed.
/// * Resolve a medicine that has a `genericName` but no `genericId`, by looking
///   the name up and inserting a stub row when it is unknown.
///
/// **Deleted generics are intentionally not removed.** Local `generics` has no
/// `is_deleted` column, and `medicine_repository.dart` browses category and
/// indication with an `INNER JOIN generics` — dropping a generic would silently
/// remove every medicine that references it from those two browse modes. Server
/// side generic deletion semantics are Phase 3 (open item #3 in SYNC.md), which
/// adds both the column and the filter.
class GenericResolver {
  GenericResolver(this._db);

  final AppDatabase _db;

  /// Local column for each key in [SyncGeneric.descriptionColumns].
  static const Map<String, String> _descriptionColumns = {
    'indication': 'indication_description',
    'therapeuticClass': 'therapeutic_class_description',
    'pharmacology': 'pharmacology_description',
    'dosage': 'dosage_description',
    'administration': 'administration_description',
    'interaction': 'interaction_description',
    'contraindications': 'contraindications_description',
    'sideEffects': 'side_effects_description',
    'pregnancyAndLactation': 'pregnancy_and_lactation_description',
    'precautions': 'precautions_description',
    'pediatricUsage': 'pediatric_usage_description',
    'overdoseEffects': 'overdose_effects_description',
    'durationOfTreatment': 'duration_of_treatment_description',
    'reconstitution': 'reconstitution_description',
    'storageConditions': 'storage_conditions_description',
  };

  /// Upserts [generics] and backfills `medicines.generic_name` for any whose
  /// name changed.
  Future<void> applyGenerics(List<SyncGeneric> generics) async {
    if (generics.isEmpty) return;

    await _db.transaction(() async {
      for (final generic in generics) {
        final changed = await _upsert(generic);
        // A renamed generic has to reach existing medicines, otherwise searching
        // by the new name finds nothing until each medicine is itself touched.
        if (changed) {
          await _db.customStatement(
            'UPDATE medicines SET generic_name = ? WHERE generic_id = ?',
            [generic.genericName, generic.genericId],
          );
        }
      }
    });
  }

  /// Returns true when the stored name actually changed.
  Future<bool> _upsert(SyncGeneric generic) async {
    final existing = (await _db.customSelect(
      'SELECT generic_name FROM generics WHERE generic_id = ?',
      variables: [Variable.withInt(generic.genericId)],
    ).get()).singleOrNull;

    final arguments = <Object?>[generic.genericName];
    for (final column in SyncGeneric.descriptionColumns) {
      arguments.add(generic.descriptions[column]);
    }
    arguments.addAll([
      generic.slug,
      generic.monographLink,
      generic.drugClass,
      generic.indication,
      generic.descriptionsCount,
      generic.genericId,
    ]);

    await _db.customStatement('''
      INSERT INTO generics (
        generic_name,
        ${_descriptionColumns.values.join(', ')},
        slug, monograph_link, drug_class, indication,
        descriptions_count, generic_id
      )
      VALUES (
        ?,
        ${List.filled(SyncGeneric.descriptionColumns.length, '?').join(', ')},
        ?, ?, ?, ?,
        ?, ?
      )
      ON CONFLICT (generic_id) DO UPDATE SET
        generic_name = excluded.generic_name,
        ${_descriptionColumns.values.map((c) => '$c = excluded.$c').join(',\n        ')},
        slug = excluded.slug,
        monograph_link = excluded.monograph_link,
        drug_class = excluded.drug_class,
        indication = excluded.indication,
        descriptions_count = excluded.descriptions_count
    ''', arguments);

    return existing?.data['generic_name'] != generic.genericName;
  }

  /// Best local `generic_id` for a medicine.
  ///
  /// Prefers the server id. Falls back to a name lookup, creating a stub row
  /// when the name is unknown, so that a medicine with a null `genericId` is
  /// still reachable from generic browse.
  ///
  /// Stub ids are negative and count down, which keeps them clear of every
  /// server-assigned id without needing a separate namespace column.
  Future<int?> resolveId({int? genericId, String? genericName}) async {
    // The server's genericId is preferred, but only once it is confirmed to
    // exist locally. Trusting it blindly leaves the medicine pointing at a
    // dangling id — generics can legitimately arrive in a later page, or not at
    // all when the row has not been backfilled yet.
    if (genericId != null) {
      final known = (await _db.customSelect(
        'SELECT 1 FROM generics WHERE generic_id = ?',
        variables: [Variable.withInt(genericId)],
      ).get()).isNotEmpty;
      if (known) return genericId;
    }

    final name = genericName?.trim();
    if (name == null || name.isEmpty) return null;

    final match = (await _db.customSelect(
      'SELECT generic_id FROM generics WHERE generic_name = ? COLLATE NOCASE',
      variables: [Variable.withString(name)],
    ).get()).singleOrNull;
    if (match != null) return match.data['generic_id'] as int;

    final lowest = (await _db.customSelect(
      'SELECT MIN(generic_id) AS lowest FROM generics WHERE generic_id < 0',
    ).getSingle()).data['lowest'] as int?;

    final stubId = (lowest ?? 0) - 1;
    await _db.customStatement(
      '''
      INSERT OR IGNORE INTO generics (generic_id, generic_name, descriptions_count)
      VALUES (?, ?, 0)
      ''',
      [stubId, name],
    );
    return stubId;
  }

  /// Rewrites the medicines of a page so their denormalised `generic_name`
  /// agrees with the generics just applied.
  ///
  /// Without this, a medicine can be written before its generic arrives — page
  /// boundaries do not guarantee ordering — and stay without a searchable
  /// `generic_name` for good.
  Future<void> backfillGenericNames(List<SyncGeneric> generics) async {
    for (final generic in generics) {
      await _db.customStatement(
        '''
        UPDATE medicines SET generic_name = ?
        WHERE generic_id = ? AND (generic_name IS NULL OR generic_name != ?)
        ''',
        [generic.genericName, generic.genericId, generic.genericName],
      );
    }
  }
}