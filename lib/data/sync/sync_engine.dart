import 'dart:async';

import '../../core/config/api_config.dart';
import '../db/app_database.dart';
import '../remote/sync_api_client.dart';
import '../remote/sync_manifest.dart';
import 'generic_resolver.dart';
import 'sync_applier.dart';

/// Why a sync was started. Only [manual] ignores the rate limit.
enum SyncTrigger { coldStart, connectivity, manual }

enum SyncStatus {
  /// The delta was fetched and applied.
  success,

  /// Skipped because the 15-minute floor had not elapsed.
  tooSoon,

  /// Skipped because no base URL is configured.
  notConfigured,

  /// The server said the `since` cursor predates retention.
  fullResync,

  /// The endpoint does not exist yet — Phase 2 has not shipped.
  unsupported,

  /// Transport failure, or the payload was unusable.
  failed,
}

/// Result of one [SyncEngine.sync] call.
class SyncOutcome {
  const SyncOutcome({
    required this.status,
    required this.trigger,
    this.pages = 0,
    this.applied = SyncApplyResult.empty,
    this.error,
  });

  final SyncStatus status;
  final SyncTrigger trigger;
  final int pages;
  final SyncApplyResult applied;
  final Object? error;

  bool get isSuccess =>
      status == SyncStatus.success ||
      status == SyncStatus.fullResync ||
      status == SyncStatus.tooSoon;

  /// True when the failure is plausibly "the server isn't there yet", which is
  /// the expected state until Phase 2 lands. Distinguishing it keeps the UI from
  /// showing an error for a missing optional feature.
  bool get isEndpointMissing =>
      status == SyncStatus.unsupported ||
      (error is SyncProtocolException) ||
      status == SyncStatus.notConfigured;

  @override
  String toString() =>
      'SyncOutcome(${status.name}, trigger: ${trigger.name}, pages: $pages, '
      'inserted: ${applied.inserted}, updated: ${applied.updated}, '
      'skipped: ${applied.skipped}, error: $error)';
}

/// Drives the `?since=` delta loop.
///
/// Invariants, in priority order:
///
/// 1. **The cursor only moves after the final page commits.** A crash or network
///    drop mid-run leaves `last_success_at` untouched, so the next run re-requests
///    the same range and replays it. Every write is an upsert keyed on
///    `remote_id` and a hash comparison, which makes replay free.
/// 2. **Single-flight.** Concurrent callers share one run rather than queuing;
///    a pull-to-refresh that lands on top of a cold-start sync waits for it and
///    reports its result, so the caller always knows whether data moved.
/// 3. **The rate limit applies to triggers, not to users.** [SyncTrigger.manual]
///    bypasses it; the other two do not, so a flapping connection cannot turn
///    into a request loop.
class SyncEngine {
  SyncEngine({
    required this.db,
    required this.client,
    SyncApplier? applier,
    DateTime Function()? clock,
  }) : _applier = applier ?? SyncApplier(db, GenericResolver(db)),
       _clock = clock ?? DateTime.now;

  final AppDatabase db;
  final SyncApiClient client;
  final SyncApplier _applier;
  final DateTime Function() _clock;

  Future<SyncOutcome>? _inFlight;
  DateTime? _lastAttemptAt;

  /// Coalesces concurrent calls onto one run. The second caller receives the
  /// first run's outcome instead of starting a competing one.
  Future<SyncOutcome> sync({SyncTrigger trigger = SyncTrigger.coldStart}) {
    final existing = _inFlight;
    if (existing != null) return existing;

    final run = _guardedSync(trigger);
    _inFlight = run;
    return run.whenComplete(() {
      if (identical(_inFlight, run)) _inFlight = null;
    });
  }

  Future<SyncOutcome> _guardedSync(SyncTrigger trigger) async {
    if (!ApiConfig.isConfigured) {
      return SyncOutcome(status: SyncStatus.notConfigured, trigger: trigger);
    }

    // Rate limiting is skipped for manual runs, but an in-memory guard still
    // stops a user hammering "refresh" within the same second.
    final lastAttempt = _lastAttemptAt;
    if (trigger != SyncTrigger.manual &&
        lastAttempt != null &&
        _clock().difference(lastAttempt) < ApiConfig.minSyncInterval) {
      return SyncOutcome(status: SyncStatus.tooSoon, trigger: trigger);
    }
    _lastAttemptAt = _clock();

    final since = await db.readSyncState('last_success_at');
    var pages = 0;
    var totals = SyncApplyResult.empty;

    try {
      String? cursor;
      var sawFullResync = false;
      String? serverTime;
      var newestUpdatedAt = '';

      do {
        final page = await client.fetchDelta(since: since, cursor: cursor);
        pages++;

        // Only the first page can legitimately declare a full resync; the server
        // decides that from `since` before it starts paging. Honouring it later
        // would discard pages already applied.
        if (page.isFullResync && pages == 1) {
          await _applier.resetForFullResync();
          sawFullResync = true;
        }

        totals += await _applier.apply(page);
        if (page.serverTime != null) serverTime = page.serverTime;
        newestUpdatedAt = _newer(newestUpdatedAt, page.medicines);
        cursor = page.nextCursor;
      } while (cursor != null && cursor.isNotEmpty);

      // Reached only after every page committed.
      await _writeCursor(_resolveCursor(since, serverTime, newestUpdatedAt));

      // Repair runs after the cursor lands so it is comparing the catalogue the
      // delta just finished updating. A failure here leaves the cursor intact and
      // the next run repeats, so it must not be able to fail the sync itself —
      // the delta's work is already durable and correct.
      if (!sawFullResync && await isManifestCheckDue()) {
        try {
          await repairFromManifest();
        } on Object {
          // Deliberately swallowed: an unhandled throw here would be reported as
          // a failed sync, which would be a lie.
        }
      }

      return SyncOutcome(
        status: sawFullResync ? SyncStatus.fullResync : SyncStatus.success,
        trigger: trigger,
        pages: pages,
        applied: totals,
      );
    } on SyncProtocolException catch (error) {
      return SyncOutcome(
        status: SyncStatus.unsupported,
        trigger: trigger,
        pages: pages,
        applied: totals,
        error: error,
      );
    } on SyncNetworkException catch (error) {
      // Cursor untouched, so the next run replays this window.
      return SyncOutcome(
        status: SyncStatus.failed,
        trigger: trigger,
        pages: pages,
        applied: totals,
        error: error,
      );
    } on Object catch (error) {
      return SyncOutcome(
        status: SyncStatus.failed,
        trigger: trigger,
        pages: pages,
        applied: totals,
        error: error,
      );
    }
  }

  /// Picks the value for the next `?since=`.
  ///
  /// The server's snapshot time is authoritative: it marks the instant after
  /// which every change is guaranteed to surface in a later delta, including
  /// rows edited while the pages were being fetched. Deriving it from the newest
  /// `updatedAt` in the payload can skip a row that shares a timestamp with the
  /// final row of the final page. The local clock is the last resort — it can be
  /// ahead of the server, which only costs a redundant fetch, or behind it, which
  /// replays rows already applied (harmless, since every write is an upsert).
  static String _resolveCursor(
    String? since,
    String? serverTime,
    String newestUpdatedAt,
  ) {
    if (serverTime != null && serverTime.isNotEmpty) return serverTime;
    if (newestUpdatedAt.isNotEmpty) return newestUpdatedAt;
    if (since != null && since.isNotEmpty) return since;
    return DateTime.now().toUtc().toIso8601String();
  }

  /// ISO-8601 strings compare correctly with `>` because they are fixed-width
  /// UTC. Anything unparseable or oddly shaped is ignored rather than allowed to
  /// become the cursor.
  static String _newer(String current, List<SyncMedicine> rows) {
    var newest = current;
    for (final row in rows) {
      final updatedAt = row.updatedAt;
      if (updatedAt.isEmpty) continue;
      if (DateTime.tryParse(updatedAt) == null) continue;
      if (newest.isEmpty || updatedAt.compareTo(newest) > 0) newest = updatedAt;
    }
    return newest;
  }

  /// Advances the cursor only once the whole run has landed.
  ///
  /// Wrapped in a transaction so the cursor and the data it describes cannot be
  /// observed out of order by a reader.
  Future<void> _writeCursor(String cursor) async {
    await db.transaction(() async {
      await db.writeSyncState('last_success_at', cursor);
    });
  }

  /// Compares the local catalog against `GET /api/sync/manifest` and reports what
  /// differs, without changing anything.
  ///
  /// A `304 Not Modified` short-circuits before any comparison: an empty body
  /// would otherwise read as "the server has no rows" and flag every local row
  /// for deletion.
  Future<SyncDriftReport> verifyAgainstManifest() async {
    final manifest = await client.fetchManifest();
    final baseline = int.tryParse((await db.readSyncState('last_manifest_count')) ?? '');

    if (manifest.notModified) {
      return const SyncDriftReport(
        remoteCount: 0,
        localCount: 0,
        missingLocally: 0,
        missingRemotely: 0,
        mismatched: 0,
        manifestNotModified: true,
        lastManifestCount: null,
        missingLocallyIds: [],
        mismatchedIds: [],
      );
    }

    final remote = {
      for (final entry in manifest.entries) entry.remoteId: entry.contentHash,
    };

    final local = (await db.customSelect('''
      SELECT remote_id, content_hash, is_deleted
      FROM medicines
      WHERE remote_id IS NOT NULL
    ''').get());

    var mismatched = 0;
    final missingLocallyIds = <String>[];
    final mismatchedIds = <String>[];
    final localIds = <String>{};

    for (final row in local) {
      final remoteId = row.data['remote_id'] as String;
      final localHash = row.data['content_hash'] as String?;
      final isDeleted = (row.data['is_deleted'] as int?) ?? 0;
      localIds.add(remoteId);

      final remoteHash = remote[remoteId];
      if (remoteHash == null) {
        // Locally known, absent from the manifest: the server has deleted it
        // outright, which a cursor can never report. A row already tombstoned by
        // an earlier check is excluded, otherwise the count would climb forever
        // and every run would retry work that already landed.
        if (isDeleted == 0) missingLocallyIds.add(remoteId);
      } else if (localHash != null && localHash != remoteHash) {
        mismatched++;
        mismatchedIds.add(remoteId);
      }
    }

    final missingRemotely = remote.keys.where((id) => !localIds.contains(id)).length;

    return SyncDriftReport(
      remoteCount: remote.length,
      localCount: localIds.length,
      missingLocally: missingLocallyIds.length,
      missingRemotely: missingRemotely,
      mismatched: mismatched,
      manifestNotModified: false,
      lastManifestCount: baseline,
      missingLocallyIds: missingLocallyIds,
      mismatchedIds: mismatchedIds,
    );
  }

  /// Whether the daily drift check should run after the delta that just landed.
  ///
  /// Skipped for a full resync: that already replayed the entire catalogue
  /// against the server, so the manifest would only confirm what it did.
  Future<bool> isManifestCheckDue() async {
    final raw = await db.readSyncState('last_manifest_at');
    if (raw == null || raw.isEmpty) return true;
    final last = DateTime.tryParse(raw);
    if (last == null) return true;
    return _clock().difference(last) >= ApiConfig.manifestInterval;
  }

  /// Repairs the drift a `?since=` delta cannot express.
  ///
  /// Two distinct failures, two distinct repairs:
  ///
  /// * A row the server hard-deleted. No timestamp will ever change again, so it
  ///   can never appear in a delta. It is tombstoned individually — never
  ///   deleted, and never in a bulk statement, because the manifest is the only
  ///   evidence and a bad response would otherwise wipe live rows.
  /// * A row whose content disagrees with the manifest. Its server `updatedAt`
  ///   is already at or before our cursor, so the next delta will skip it and it
  ///   stays wrong forever. Clearing `content_hash` does not help: the delta is
  ///   driven by timestamps, not hashes. Dropping the cursor instead replays the
  ///   catalogue, and because [SyncApplier.resetForFullResync] keeps the hashes,
  ///   the replay rewrites exactly these rows and skips the rest.
  ///
  /// Returns without touching the catalog when the manifest is not trustworthy —
  /// see [SyncDriftReport.isManifestTrustworthy].
  Future<SyncDriftReport> repairFromManifest() async {
    final report = await verifyAgainstManifest();

    if (report.manifestNotModified) {
      // No body means no new count, but the check itself succeeded and the
      // timestamp must advance or this would re-fire on every sync.
      await _stampManifestCheck(remoteCount: null);
      return report;
    }

    // First ever check: record the baseline and stop. Tombstoning against a
    // manifest nothing has ever vouched for would make the very first check the
    // riskiest one.
    if (!report.hasBaseline) {
      if (report.remoteCount > 0) {
        await _stampManifestCheck(remoteCount: report.remoteCount);
      }
      return report;
    }

    if (!report.isManifestTrustworthy) return report;

    final tombstoned = await _applier.tombstoneMissingLocally(report.missingLocallyIds);
    if (tombstoned != report.missingLocally) {
      throw StateError(
        'Tombstoned $tombstoned of ${report.missingLocally} rows the manifest '
        'no longer lists.',
      );
    }

    if (report.mismatchedIds.isNotEmpty) await _applier.resetForFullResync();

    await _stampManifestCheck(remoteCount: report.remoteCount);
    return report;
  }

  /// Records that a check completed, so the next one waits out
  /// [ApiConfig.manifestInterval].
  ///
  /// [remoteCount] is null for a `304`, which leaves the stored baseline
  /// untouched — a response that carries no rows says nothing about their number.
  Future<void> _stampManifestCheck({required int? remoteCount}) async {
    await db.transaction(() async {
      if (remoteCount != null) {
        await db.writeSyncState('last_manifest_count', '$remoteCount');
      }
      await db.writeSyncState('last_manifest_at', _clock().toUtc().toIso8601String());
    });
  }
}

/// Difference between the local catalog and the remote manifest.
class SyncDriftReport {
  const SyncDriftReport({
    required this.remoteCount,
    required this.localCount,
    required this.missingLocally,
    required this.missingRemotely,
    required this.mismatched,
    required this.manifestNotModified,
    required this.lastManifestCount,
    required this.missingLocallyIds,
    required this.mismatchedIds,
  });

  /// Number of rows in the accepted manifest at the previous check, or null when
  /// no baseline has been recorded yet. This — not the local count — is the
  /// reference the tolerance is measured against: the local count is exactly what
  /// a truncated manifest would make it wrong.
  final int? lastManifestCount;

  final int remoteCount;
  final int localCount;

  /// Known locally but gone from the manifest — a hard server-side delete.
  final int missingLocally;

  /// On the manifest but never synced down.
  final int missingRemotely;

  /// Present on both sides with different content.
  final int mismatched;

  final bool manifestNotModified;

  /// The `remote_id`s behind [missingLocally] and [mismatched], so repair writes
  /// the exact rows that were compared rather than re-deriving them from a second
  /// query that could disagree.
  final List<String> missingLocallyIds;
  final List<String> mismatchedIds;

  bool get isClean => missingLocally == 0 && missingRemotely == 0 && mismatched == 0;

  /// True once a manifest count has been recorded, so a size change has something
  /// to be measured against.
  bool get hasBaseline => (lastManifestCount ?? 0) > 0;

  /// How far the manifest's size differs from the baseline, as a fraction.
  /// Null when there is no baseline to measure against.
  double? get sizeDeviation {
    final baseline = lastManifestCount;
    if (baseline == null || baseline <= 0) return null;
    return (remoteCount - baseline).abs() / baseline;
  }

  /// Whether this manifest may be acted on.
  ///
  /// The failure mode being guarded against is one-directional: an incomplete or
  /// truncated body makes every row it happens to omit look deleted, and acting on
  /// that tombstones live catalogue rows. There is no delta that would bring them
  /// back, because a hard delete is invisible to `?since=`.
  bool get isManifestTrustworthy {
    if (manifestNotModified) return true;
    // An empty body with no 304 means the catalogue came back with nothing in it.
    if (remoteCount == 0) return false;
    if (!hasBaseline) return false;
    return sizeDeviation! <= ApiConfig.manifestRowTolerance;
  }

  @override
  String toString() =>
      'SyncDriftReport(remote: $remoteCount, local: $localCount, '
      'missingLocally: $missingLocally, missingRemotely: $missingRemotely, '
      'mismatched: $mismatched, baseline: $lastManifestCount, '
      'trustworthy: $isManifestTrustworthy)';
}
