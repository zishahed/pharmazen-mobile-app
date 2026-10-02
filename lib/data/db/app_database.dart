import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Generation of the schema that `assets/database/medicines.db` is expected to
/// be at. Bump this whenever the asset gains tables or columns, and ship the
/// migrated asset in the same change — otherwise every existing install
/// re-seeds against a stale file on next launch.
const int kBundledSchemaVersion = 2;

/// New columns on `medicines`, in the order `tool/phase4_asset_migration.sql`
/// adds them. [AppDatabase.ensureSchema] replays this against files that predate
/// them.
///
/// `is_deleted` defaults to 0 so the tombstone flag stays inert until Phase 1B
/// enables soft delete on the server; every row in the asset is 0.
const Map<String, String> kMedicineSyncColumns = {
  'remote_id': 'TEXT',
  'content_hash': 'TEXT',
  'synced_at': 'TEXT',
  'is_deleted': 'INTEGER DEFAULT 0',
};

/// Keys seeded into `sync_state`. Phase 5 advances `last_success_at` only after
/// the final batch commits, so a crash mid-sync leaves the cursor untouched and
/// the run repeats safely.
const List<String> kSyncStateKeys = [
  'last_success_at',
  'last_manifest_count',
  'bundled_schema_version',
];

/// Reads the major version out of an `app_metadata.database_version` value.
///
/// The asset stores `'2.0'`, not `'2'`, so this cannot be a plain `int.parse`:
/// that throws on every device and the version gate would then re-seed forever.
/// A missing, empty or unparseable value yields null, which the caller treats as
/// "unversioned" and repairs by re-seeding.
int? parseSchemaVersion(String? raw) {
  if (raw == null) return null;
  final match = RegExp(r'^\s*(\d+)').firstMatch(raw);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

class AppDatabase extends GeneratedDatabase {
  AppDatabase(super.executor);

  @override
  int get schemaVersion => kBundledSchemaVersion;

  @override
  Iterable<TableInfo> get allTables => [];

  /// There are no Drift tables ([allTables] is empty), so Drift's own migration
  /// machinery has nothing to create and would raise `MissingSchemaError` on any
  /// version bump. DDL is hand-rolled in [ensureSchema] instead, wired to
  /// `beforeOpen` so it applies to every entry point — including tests that open
  /// an asset path directly — not just [openConnection].
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {},
    beforeOpen: (details) => ensureSchema(),
  );

  /// Applies the schema to whatever file this connection points at. Safe to call
  /// repeatedly: tables use `IF NOT EXISTS` and every `ALTER TABLE` is guarded by
  /// a `PRAGMA table_info` lookup.
  ///
  /// Works out what is missing first, then applies all of it in one transaction
  /// so a crash cannot leave a half-migrated file behind. When nothing is missing
  /// — the steady state, since the bundled asset ships already migrated — it
  /// performs no writes and opens no transaction, leaving
  /// `app_metadata.database_version` untouched.
  Future<void> ensureSchema() async {
    final createSyncState = !await _hasTable('sync_state');

    final missingColumns = <MapEntry<String, String>>[];
    if (await _hasTable('medicines')) {
      final existing = await _columnNames('medicines');
      missingColumns.addAll(
        kMedicineSyncColumns.entries.where((c) => !existing.contains(c.key)),
      );
    }

    final missingKeys = <String>[];
    if (createSyncState) {
      missingKeys.addAll(kSyncStateKeys);
    } else {
      for (final key in kSyncStateKeys) {
        final existing = await customSelect(
          'SELECT 1 FROM sync_state WHERE key = ?',
          variables: [Variable.withString(key)],
        ).get();
        if (existing.isEmpty) missingKeys.add(key);
      }
    }

    if (!createSyncState && missingColumns.isEmpty && missingKeys.isEmpty) {
      return;
    }

    await transaction(() async {
      if (createSyncState) {
        await customStatement('''
          CREATE TABLE sync_state (
            key TEXT PRIMARY KEY,
            value TEXT,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
          )
        ''');
      }

      for (final column in missingColumns) {
        await customStatement(
          'ALTER TABLE medicines ADD COLUMN ${column.key} ${column.value}',
        );
      }

      for (final key in missingKeys) {
        await customStatement('''
          INSERT INTO sync_state (key, value, updated_at)
          VALUES (?, ?, CURRENT_TIMESTAMP)
        ''', [key, '$kBundledSchemaVersion']);
      }

      await _stampSchemaVersion();
    });
  }

  Future<String?> readSyncState(String key) async {
    final rows = await customSelect(
      'SELECT value FROM sync_state WHERE key = ?',
      variables: [Variable.withString(key)],
    ).get();
    if (rows.isEmpty) return null;
    return rows.single.data['value'] as String?;
  }

  /// Null is a meaningful value, not a delete: it records "never synced" for
  /// [key] while keeping the key discoverable in `sync_state`.
  ///
  /// `Variable<T extends Object>` cannot carry a null, so NULL is written as a
  /// literal and left out of the bind list.
  Future<void> writeSyncState(String key, String? value) async {
    final arguments = <Object?>[key];
    final slot = value == null ? 'NULL' : '?';
    if (value != null) arguments.add(value);

    await customStatement(
      '''
      INSERT INTO sync_state (key, value, updated_at)
      VALUES (?, $slot, CURRENT_TIMESTAMP)
      ON CONFLICT (key) DO UPDATE SET
        value = excluded.value,
        updated_at = CURRENT_TIMESTAMP
      ''',
      arguments,
    );
  }

  Future<void> _stampSchemaVersion() async {
    if (await _hasTable('app_metadata')) {
      // The bundled app_metadata has updated_at, but a launch-time crash here
      // would be unrecoverable, so tolerate its absence rather than assume it.
      final columns = await _columnNames('app_metadata');
      final touch = columns.contains('updated_at')
          ? ', updated_at = CURRENT_TIMESTAMP'
          : '';
      await customStatement(
        '''
        UPDATE app_metadata SET value = ?$touch
        WHERE key = 'database_version'
      ''',
        ['$kBundledSchemaVersion.0'],
      );
    }
    await customStatement('PRAGMA user_version = $kBundledSchemaVersion');
  }

  Future<bool> _hasTable(String name) async {
    final rows = await customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(name)],
    ).get();
    return rows.isNotEmpty;
  }

  Future<Set<String>> _columnNames(String table) async {
    final rows = await customSelect('PRAGMA table_info($table)').get();
    return rows.map((row) => row.data['name'] as String).toSet();
  }
}

/// Opens the on-device catalog, installing the bundled asset when needed.
///
/// The file is replaced rather than patched whenever it is older than
/// [kBundledSchemaVersion], which is what makes a newly bundled asset actually
/// reach existing installs. Only cached catalog data and sync bookkeeping live
/// in this file — carts, orders and prescriptions are all server-side — so the
/// swap is cheap. Anything not yet pushed is lost; see the note in SYNC.md about
/// re-seeding once local order queues exist.
LazyDatabase openConnection() {
  return LazyDatabase(() async {
    final appDir = await getApplicationDocumentsDirectory();
    final file = File(p.join(appDir.path, 'medicines.db'));

    final installed = await readInstalledSchemaVersion(file);
    if (installed == null || installed < kBundledSchemaVersion) {
      await discardCatalog(file);
      final data = await rootBundle.load('assets/database/medicines.db');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }

    return NativeDatabase.createInBackground(file);
  });
}

/// Reads the schema generation of an already-installed catalog file.
///
/// Returns null — meaning "unversioned, replace it" — when the file is absent,
/// unreadable, corrupt, or predates `app_metadata`. Exposed so the gate in
/// [openConnection] stays testable without platform channels.
Future<int?> readInstalledSchemaVersion(File file) async {
  if (!await file.exists()) return null;

  final probe = _MetadataOnly(NativeDatabase(file));
  try {
    final rows = await probe.customSelect('''
      SELECT value FROM app_metadata WHERE key = 'database_version'
    ''').get();
    if (rows.isEmpty) return null;
    return parseSchemaVersion(rows.single.data['value'] as String?);
  } on Object {
    return null;
  } finally {
    try {
      await probe.close();
    } on Object {
      // Closing a corrupt file can fail too; the null verdict already stands.
    }
  }
}

/// Deletes the catalog together with its WAL sidecars.
///
/// Removing only the main file would leave a stale `-wal` from the previous
/// generation to be replayed onto the freshly copied one, corrupting it in ways
/// that surface much later.
Future<void> discardCatalog(File file) async {
  if (await file.exists()) await file.delete();
  for (final suffix in ['-wal', '-shm', '-journal']) {
    final sidecar = File('${file.path}$suffix');
    if (await sidecar.exists()) await sidecar.delete();
  }
}

/// Bare Drift database used purely to read schema metadata.
///
/// Using [AppDatabase] here would fire [AppDatabase.ensureSchema] and upgrade the
/// very file whose version is being inspected, which would make a stale catalog
/// look current and skip the re-seed.
///
/// Drift unconditionally writes `PRAGMA user_version = schemaVersion` on every
/// open, so [schemaVersion] must be [kBundledSchemaVersion]: any other value
/// would silently downgrade the installed file's `user_version` on every launch.
/// That pragma is not the gate — `app_metadata.database_version` is, and it
/// lives in a normal table that this probe never writes. `onUpgrade` is a no-op
/// so a mismatch cannot throw.
class _MetadataOnly extends GeneratedDatabase {
  _MetadataOnly(super.executor);

  @override
  int get schemaVersion => kBundledSchemaVersion;

  @override
  Iterable<TableInfo> get allTables => const [];

  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onUpgrade: (m, from, to) async {});
}