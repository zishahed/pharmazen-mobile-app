import 'package:drift/drift.dart';

import '../../core/config/api_config.dart';
import '../db/app_database.dart';
import '../remote/sync_manifest.dart';
import 'generic_resolver.dart';

/// Counts from one apply run, for logging and tests.
class SyncApplyResult {
  const SyncApplyResult({
    required this.inserted,
    required this.updated,
    required this.skipped,
    required this.tombstoned,
  });

  static const empty = SyncApplyResult(
    inserted: 0,
    updated: 0,
    skipped: 0,
    tombstoned: 0,
  );

  final int inserted;

  /// Rows rewritten because their content hash moved.
  final int updated;

  /// Rows whose hash already matched, so no write was needed.
  final int skipped;

  /// Of the updated rows, how many were tombstones.
  final int tombstoned;

  int get changed => inserted + updated;

  SyncApplyResult operator +(SyncApplyResult other) => SyncApplyResult(
    inserted: inserted + other.inserted,
    updated: updated + other.updated,
    skipped: skipped + other.skipped,
    tombstoned: tombstoned + other.tombstoned,
  );
}

/// Writes remote rows into the local catalog.
///
/// Identity is `medicines.remote_id` (the Neon UUID), not `brand_id`. That
/// matters because **Neon has no `brand_id`** — it is an app-only primary key —
/// so a medicine created server-side after a device installed has no
/// `brand_id` yet and the applier allocates one.
///
/// Writes are chunked into short transactions ([ApiConfig.applyBatchSize]) so
/// the background isolate does not hold the write lock long enough to stall
/// concurrent searches.
class SyncApplier {
  SyncApplier(this._db, this._resolver);

  final AppDatabase _db;
  final GenericResolver _resolver;

  /// Applies generics before medicines: a medicine can arrive in an earlier page
  /// than the generic it points at, and [`GenericResolver.backfillGenericNames`]
  /// repairs that afterwards.
  Future<SyncApplyResult> apply(SyncDeltaPage page) async {
    await _resolver.applyGenerics(page.generics);
    await _resolver.backfillGenericNames(page.generics);
    final medicines = await applyMedicines(page.medicines);
    return medicines;
  }

  Future<SyncApplyResult> applyMedicines(List<SyncMedicine> rows) async {
    if (rows.isEmpty) return SyncApplyResult.empty;

    var inserted = 0;
    var updated = 0;
    var skipped = 0;
    var tombstoned = 0;

    // On a first-ever sync there is nothing to match against, so the per-row
    // existence probe can be skipped entirely. 21,715 probes is the difference
    // between a few seconds and a minute on a cold install.
    final localSynced = (await _db.customSelect(
      'SELECT COUNT(*) AS synced FROM medicines WHERE remote_id IS NOT NULL',
    ).getSingle()).data['synced'] as int;
    final knownRowsExist = localSynced > 0;

    var nextBrandId = await _nextBrandId();

    for (var offset = 0; offset < rows.length; offset += ApiConfig.applyBatchSize) {
      final end = (offset + ApiConfig.applyBatchSize).clamp(0, rows.length);
      final chunk = rows.sublist(offset, end);

      await _db.transaction(() async {
        for (final row in chunk) {
          final existing = knownRowsExist
              ? (await _db.customSelect(
                  'SELECT brand_id, content_hash FROM medicines WHERE remote_id = ?',
                  variables: [Variable.withString(row.id)],
                ).get()).singleOrNull
              : null;

          final hash = row.contentHash;

          if (existing == null) {
            final genericId = await _resolver.resolveId(
              genericId: row.genericId,
              genericName: row.genericName,
            );
            await _db.customStatement(
              '''
              INSERT INTO medicines (
                brand_id, brand_name, type, slug, dosage_form, generic_name,
                strength, manufacturer, package_container, package_size,
                generic_id, isSensitive, remote_id, content_hash, synced_at, is_deleted
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, ?)
              ''',
              [
                nextBrandId++,
                row.brandName,
                row.type,
                row.slug,
                row.dosageForm,
                row.genericName,
                row.strength,
                row.manufacturer,
                row.packageContainer,
                row.packageSize,
                genericId,
                row.isSensitive ? 1 : 0,
                row.id,
                hash,
                row.isDeleted ? 1 : 0,
              ],
            );
            inserted++;
            if (row.isDeleted) tombstoned++;
            continue;
          }

          // Unchanged rows are the common case in a healthy device and must not
          // cost a write, let alone block a reader.
          if (existing.data['content_hash'] == hash) {
            skipped++;
            continue;
          }

          final genericId = await _resolver.resolveId(
            genericId: row.genericId,
            genericName: row.genericName,
          );
          await _db.customStatement(
            '''
            UPDATE medicines SET
              brand_name = ?, type = ?, slug = ?, dosage_form = ?, generic_name = ?,
              strength = ?, manufacturer = ?, package_container = ?, package_size = ?,
              generic_id = ?, isSensitive = ?, content_hash = ?,
              synced_at = CURRENT_TIMESTAMP, is_deleted = ?
            WHERE remote_id = ?
            ''',
            [
              row.brandName,
              row.type,
              row.slug,
              row.dosageForm,
              row.genericName,
              row.strength,
              row.manufacturer,
              row.packageContainer,
              row.packageSize,
              genericId,
              row.isSensitive ? 1 : 0,
              hash,
              row.isDeleted ? 1 : 0,
              row.id,
            ],
          );
          updated++;
          if (row.isDeleted) tombstoned++;
        }
      });
    }

    return SyncApplyResult(
      inserted: inserted,
      updated: updated,
      skipped: skipped,
      tombstoned: tombstoned,
    );
  }

  /// Next free local primary key. Ids are only ever allocated inside a write
  /// transaction, and Drift serialises writes, so the read-then-increment cannot
  /// race with another writer.
  Future<int> _nextBrandId() async {
    final row = await _db.customSelect(
      'SELECT MAX(brand_id) AS max_id FROM medicines',
    ).getSingle();
    final maxId = row.data['max_id'] as int?;
    // -1 seeds brand_id at 0 for an empty catalog. Written this way round because
    // `(maxId ?? 0) < 0 ? 0 : maxId! + 1` crashes on the null case: the ?? guards
    // the comparison, not the branch that follows it.
    final next = (maxId ?? -1) + 1;
    return next < 0 ? 0 : next;
  }

  /// Removes every trace of server-assigned sync state so a full resync starts
  /// from the bundled asset's content rather than layering deltas on stale rows.
  ///
  /// `brand_id`, `brand_name` and the catalogue columns are deliberately kept:
  /// `sync_state.last_success_at` drives which rows a `?since=` delta returns, so
  /// wiping it alone would not re-fetch anything, and discarding the bundled
  /// names would leave a gap until the server caught up.
  Future<void> resetForFullResync() async {
    await _db.transaction(() async {
      await _db.customStatement(
        'UPDATE medicines SET remote_id = NULL, content_hash = NULL, '
        'synced_at = NULL, is_deleted = 0',
      );
      await _db.customStatement('DELETE FROM sync_state');
    });
  }
}