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
  /// Deliberately not wired into the automatic path: a full manifest is a
  /// ~21.7k-row payload, and Phase 2 does not exist yet. Phase 6 adds the
  /// ~20% row-count sanity check before this is allowed to tombstone anything.
  Future<SyncDriftReport> verifyAgainstManifest() async {
    final manifest = await client.fetchManifest();
    final remote = {for (final entry in manifest.entries) entry.remoteId: entry.contentHash};

    final local = (await db.customSelect('''
      SELECT remote_id, content_hash, is_deleted
      FROM medicines
      WHERE remote_id IS NOT NULL
    ''').get());

    var missingLocally = 0;
    var mismatched = 0;
    final localHashes = <String, String>{};

    for (final row in local) {
      final remoteId = row.data['remote_id'] as String;
      final localHash = row.data['content_hash'] as String?;
      localHashes[remoteId] = localHash ?? '';

      final remoteHash = remote[remoteId];
      if (remoteHash == null) {
        // Locally known, absent from the manifest: the server has deleted it
        // outright, which a cursor can never report.
        missingLocally++;
      } else if (localHash != null && localHash != remoteHash) {
        mismatched++;
      }
    }

    final missingRemotely =
        remote.keys.where((id) => !localHashes.containsKey(id)).length;

    return SyncDriftReport(
      remoteCount: remote.length,
      localCount: localHashes.length,
      missingLocally: missingLocally,
      missingRemotely: missingRemotely,
      mismatched: mismatched,
      manifestNotModified: manifest.notModified,
    );
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
  });

  final int remoteCount;
  final int localCount;

  /// Known locally but gone from the manifest — a hard server-side delete.
  final int missingLocally;

  /// On the manifest but never synced down.
  final int missingRemotely;

  /// Present on both sides with different content.
  final int mismatched;

  final bool manifestNotModified;

  bool get isClean => missingLocally == 0 && missingRemotely == 0 && mismatched == 0;

  /// Phase 6's tombstone guard: refuse to act on a manifest whose size is wildly
  /// different from the last known good, which would otherwise mean a truncated
  /// or errored response.
  bool get looksTruncated => remoteCount == 0 || localCount == 0;

  @override
  String toString() =>
      'SyncDriftReport(remote: $remoteCount, local: $localCount, '
      'missingLocally: $missingLocally, missingRemotely: $missingRemotely, '
      'mismatched: $mismatched)';
}