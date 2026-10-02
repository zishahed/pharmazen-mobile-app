import 'dart:io';

// `package:drift/drift.dart` is deliberately not imported unprefixed: it also
// exports isNull/isNotNull, which collide with flutter_test's matchers.
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharmazen_mobile_app/data/db/app_database.dart';

const _asset = 'assets/database/medicines.db';

void main() {
  group('parseSchemaVersion', () {
    test('reads the major component of a dotted version', () {
      // The asset stores '2.0'. int.parse('2.0') throws, which would have made
      // every device re-seed on every launch.
      expect(parseSchemaVersion('1.0'), 1);
      expect(parseSchemaVersion('2.0'), 2);
      expect(parseSchemaVersion('10.4'), 10);
    });

    test('accepts a bare integer', () {
      expect(parseSchemaVersion('1'), 1);
      expect(parseSchemaVersion('2'), 2);
    });

    test('treats missing or unparseable values as unversioned', () {
      expect(parseSchemaVersion(null), isNull);
      expect(parseSchemaVersion(''), isNull);
      expect(parseSchemaVersion('   '), isNull);
      expect(parseSchemaVersion('v2'), isNull);
    });
  });

  group('bundled asset', () {
    test('ships the Phase 4 columns on medicines', () async {
      // Unmigrated on purpose: see withUnmigratedAssetCopy.
      await withUnmigratedAssetCopy((db) async {
        final columns = await _columns(db, 'medicines');
        expect(
          columns.keys.toSet(),
          containsAll(kMedicineSyncColumns.keys),
          reason: 'assets/database/medicines.db must be migrated too, not just '
              'the on-device file',
        );
        expect(columns['remote_id'], 'TEXT');
        expect(columns['content_hash'], 'TEXT');
        expect(columns['synced_at'], 'TEXT');
        expect(columns['is_deleted'], 'INTEGER');
      });
    });

    test('ships sync_state seeded with the expected keys', () async {
      // Unmigrated on purpose. This test is the guard against a key being added
      // to kSyncStateKeys without also being added to
      // tool/phase4_asset_migration.sql; read through AppDatabase it could never
      // fail, because ensureSchema would insert the missing key first.
      await withUnmigratedAssetCopy((db) async {
        final keys = (await db.customSelect('SELECT key FROM sync_state').get())
            .map((row) => row.data['key'] as String)
            .toSet();
        expect(keys, kSyncStateKeys.toSet());

        expect(
          await _shippedSyncState(db, 'bundled_schema_version'),
          kBundledSchemaVersion.toString(),
        );
        expect(
          await _shippedSyncState(db, 'last_success_at'),
          isNull,
          reason: 'nothing has synced yet',
        );
        expect(await _shippedSyncState(db, 'last_manifest_count'), isNull);
        expect(
          await _shippedSyncState(db, 'last_manifest_at'),
          isNull,
          reason: 'the drift check has not run yet',
        );
      });
    });

    test('is stamped at the bundled generation', () async {
      await withAssetCopy((db, _) async {
        final rows = await db
            .customSelect("SELECT value FROM app_metadata WHERE key = 'database_version'")
            .get();
        expect(
          parseSchemaVersion(rows.single.data['value'] as String?),
          kBundledSchemaVersion,
        );

        final userVersion =
            await db.customSelect('PRAGMA user_version').getSingle();
        expect(userVersion.data.values.single, kBundledSchemaVersion);
      });
    });

    test('has no tombstones and no sync rows yet', () async {
      await withAssetCopy((db, _) async {
        // Phase 4 is schema only: nothing has been synced, and Phase 1B has not
        // enabled soft delete, so every row must still be live.
        final row = (await db.customSelect("""
          SELECT COUNT(*) AS total,
                 SUM(CASE WHEN is_deleted != 0 THEN 1 ELSE 0 END) AS deleted,
                 SUM(CASE WHEN remote_id IS NOT NULL THEN 1 ELSE 0 END) AS synced
          FROM medicines
        """).getSingle()).data;

        expect(row['total'], 21715);
        expect(row['deleted'], 0);
        expect(row['synced'], 0);
      });
    });
  });

  group('ensureSchema', () {
    test('upgrades a legacy database on first open', () async {
      await withLegacyCatalogFile((file) async {
        // Inspect the starting shape through a wrapper with no migration hook:
        // opening an AppDatabase would upgrade the file immediately.
        final raw = _FixtureDatabase(NativeDatabase(file));
        expect(
          (await _columns(raw, 'medicines')).keys.toSet(),
          isNot(contains('remote_id')),
        );
        expect(await _tableNames(raw), isNot(contains('sync_state')));
        await raw.close();

        final db = AppDatabase(NativeDatabase(file));
        addTearDown(db.close);

        // The first query runs beforeOpen -> ensureSchema.
        final after = await _columns(db, 'medicines');
        expect(after.keys.toSet(), containsAll(kMedicineSyncColumns.keys));
        expect(await _tableNames(db), contains('sync_state'));

        final keys = (await db.customSelect('SELECT key FROM sync_state').get())
            .map((row) => row.data['key'] as String)
            .toSet();
        expect(keys, kSyncStateKeys.toSet());
        expect(await db.readSyncState('bundled_schema_version'), '2');
      });
    });

    test('re-stamps database_version and user_version', () async {
      await withLegacyCatalog((db) async {
        await db.ensureSchema();

        final rows = await db.customSelect('''
          SELECT value FROM app_metadata WHERE key = 'database_version'
        ''').get();
        expect(
          parseSchemaVersion(rows.single.data['value'] as String?),
          kBundledSchemaVersion,
        );
        expect(
          (await db.customSelect('PRAGMA user_version').getSingle()).data.values.single,
          kBundledSchemaVersion,
        );
      });
    });

    test('converges a legacy database onto the asset column set', () async {
      // Guards against tool/phase4_asset_migration.sql and ensureSchema()
      // drifting apart: if the asset gains a column the runtime path forgets,
      // this fails.
      final assetColumns = await withAssetCopy<Map<String, String>>(
        (db, _) => _columns(db, 'medicines'),
      );

      await withLegacyCatalog((db) async {
        await db.ensureSchema();
        final upgraded = await _columns(db, 'medicines');
        expect(upgraded.keys.toSet(), assetColumns.keys.toSet());
      });
    });

    test('writes nothing when the file is already current', () async {
      await withAssetCopy((db, _) async {
        // Stamp a sentinel so a re-stamp is detectable: CURRENT_TIMESTAMP only
        // has one-second resolution, so comparing against "now" could pass by
        // coincidence within the same second.
        const sentinel = '1999-01-01 00:00:00';
        await db.customStatement(
          "UPDATE app_metadata SET updated_at = ? WHERE key = 'database_version'",
          [sentinel],
        );

        await db.ensureSchema();
        await db.ensureSchema();

        final after =
            (await db
                    .customSelect(
                      "SELECT updated_at FROM app_metadata WHERE key = 'database_version'",
                    )
                    .getSingle())
                .data
                .values
                .single;
        expect(
          after,
          sentinel,
          reason: 'ensureSchema must not re-stamp an already-current file',
        );
      });
    });

    test('is idempotent across repeated runs', () async {
      await withLegacyCatalog((db) async {
        await db.ensureSchema();
        await db.ensureSchema();
        await db.ensureSchema();

        final columns = await _columns(db, 'medicines');
        expect(columns.keys.toSet(), containsAll(kMedicineSyncColumns.keys));

        final keys = await db.customSelect('SELECT key FROM sync_state').get();
        expect(keys.map((r) => r.data['key']).toSet(), kSyncStateKeys.toSet());
      });
    });

    test('adds a newly introduced key to an already-installed catalog', () async {
      await withLegacyCatalog((db) async {
        // An install that predates the key, holding values for the old ones.
        await db.ensureSchema();
        await db.writeSyncState('last_success_at', '2026-01-02T00:00:00Z');
        await db.writeSyncState('last_manifest_count', '21715');
        await db.customStatement("DELETE FROM sync_state WHERE key = 'last_manifest_at'");

        await db.ensureSchema();

        final keys = (await db.customSelect('SELECT key FROM sync_state').get())
            .map((r) => r.data['key'])
            .toSet();
        expect(keys, kSyncStateKeys.toSet(), reason: 'the key must self-heal');
        expect(
          await db.readSyncState('last_manifest_at'),
          isNull,
          reason: 'a fabricated value would delay the first drift check by a day',
        );
        // The keys the install already relied on must survive untouched, or the
        // next sync would resend the whole catalogue.
        expect(await db.readSyncState('last_success_at'), '2026-01-02T00:00:00Z');
        expect(await db.readSyncState('last_manifest_count'), '21715');
        expect(
          await db.readSyncState('bundled_schema_version'),
          '$kBundledSchemaVersion',
        );
      });
    });

    test('preserves existing data', () async {
      await withLegacyCatalog((db) async {
        final before = await db.customSelect('SELECT COUNT(*) AS n FROM medicines')
            .getSingle();
        await db.ensureSchema();
        final after = await db.customSelect('SELECT COUNT(*) AS n FROM medicines')
            .getSingle();
        expect(after.data['n'], before.data['n']);
        expect(after.data['n'], 3);
      });
    });
  });

  group('sync_state', () {
    test('round-trips a value', () async {
      await withLegacyCatalog((db) async {
        await db.ensureSchema();
        await db.writeSyncState('last_success_at', '2026-10-02T08:00:00Z');
        expect(await db.readSyncState('last_success_at'),
            '2026-10-02T08:00:00Z');
      });
    });

    test('overwrites an existing value', () async {
      await withLegacyCatalog((db) async {
        await db.ensureSchema();
        await db.writeSyncState('last_manifest_count', '100');
        await db.writeSyncState('last_manifest_count', '250');
        expect(await db.readSyncState('last_manifest_count'), '250');
      });
    });

    test('stores null as a value rather than deleting the key', () async {
      await withLegacyCatalog((db) async {
        await db.ensureSchema();
        await db.writeSyncState('last_success_at', '2026-10-02T08:00:00Z');
        await db.writeSyncState('last_success_at', null);

        expect(await db.readSyncState('last_success_at'), isNull);
        final keys = await db
            .customSelect("SELECT key FROM sync_state WHERE key = 'last_success_at'")
            .get();
        expect(
          keys,
          hasLength(1),
          reason: 'null means "never synced", not "unknown key"',
        );
      });
    });

    test('returns null for an unknown key', () async {
      await withLegacyCatalog((db) async {
        await db.ensureSchema();
        expect(await db.readSyncState('no_such_key'), isNull);
      });
    });
  });

  group('version gate', () {
    test('reports the installed generation', () async {
      await withLegacyCatalogFile((file) async {
        expect(
          await readInstalledSchemaVersion(file),
          1,
          reason: 'must be below kBundledSchemaVersion so the gate re-seeds',
        );
      });
    });

    test('treats a missing file as unversioned', () async {
      final dir = await _tempDir();
      expect(await readInstalledSchemaVersion(File('${dir.path}/absent.db')),
          isNull);
    });

    test('treats a file with no app_metadata as unversioned', () async {
      final (file, db) = await withBareFile(
        'bare.db',
        'CREATE TABLE medicines (brand_id INTEGER PRIMARY KEY)',
      );
      await db.close();

      expect(await readInstalledSchemaVersion(file), isNull);
    });

    test('treats a corrupt file as unversioned', () async {
      final dir = await _tempDir();
      final file = File('${dir.path}/corrupt.db');
      await file.writeAsString('this is not a sqlite database');

      expect(await readInstalledSchemaVersion(file), isNull);
    });

    test('treats an unparseable version as unversioned', () async {
      final (file, db) = await withUnparseableVersion();
      await db.close();

      expect(await readInstalledSchemaVersion(file), isNull);
    });

    test('current asset is already at the bundled generation', () async {
      final version = await withAssetCopy<int?>(
        (_, file) => readInstalledSchemaVersion(file),
      );
      expect(
        version,
        kBundledSchemaVersion,
        reason: 'otherwise every fresh install re-seeds itself',
      );
    });

    test('discardCatalog removes the database and its sidecars', () async {
      final dir = await _tempDir();
      final file = File('${dir.path}/sidecar.db');
      await file.writeAsString('x');
      for (final suffix in ['-wal', '-shm', '-journal']) {
        await File('${file.path}$suffix').writeAsString('x');
      }

      await discardCatalog(file);

      expect(file.existsSync(), isFalse);
      for (final suffix in ['-wal', '-shm', '-journal']) {
        expect(
          File('${file.path}$suffix').existsSync(),
          isFalse,
          reason: 'a stale $suffix would corrupt the re-seeded database',
        );
      }
    });
  });
}

/// Opens a byte-identical copy of the bundled asset.
///
/// Drift rewrites `PRAGMA user_version` on every open, so tests must never point
/// at the tracked 17MB binary directly — doing so would leave the working tree
/// dirty after a test run.
/// Reads a `sync_state` value straight from the file, bypassing
/// [AppDatabase.readSyncState] so the assertion sees what was shipped.
Future<String?> _shippedSyncState(drift.GeneratedDatabase db, String key) async {
  final rows = await db.customSelect(
    'SELECT value FROM sync_state WHERE key = ?',
    variables: [drift.Variable.withString(key)],
  ).get();
  return rows.isEmpty ? null : rows.single.data['value'] as String?;
}

/// The bundled asset as shipped, with nothing allowed to migrate it first.
///
/// [withAssetCopy] wraps the copy in an [AppDatabase], whose `beforeOpen` runs
/// `ensureSchema` — so a copy missing a `sync_state` key gets that key inserted
/// before any assertion runs, and a test about what the asset *ships* passes no
/// matter what it ships. This opens the copy through [_FixtureDatabase] instead,
/// which has no `beforeOpen` hook, so the file is inspected exactly as committed.
Future<T> withUnmigratedAssetCopy<T>(Future<T> Function(drift.GeneratedDatabase db) body) async {
  final dir = await _tempDir();
  final file = File('${dir.path}/medicines.db');
  await File(_asset).copy(file.path);

  final db = _FixtureDatabase(NativeDatabase(file));
  try {
    return await body(db);
  } finally {
    await db.close();
  }
}

Future<T> withAssetCopy<T>(Future<T> Function(AppDatabase db, File file) body) async {
  final dir = await _tempDir();
  final file = File('${dir.path}/medicines.db');
  await File(_asset).copy(file.path);

  final db = AppDatabase(NativeDatabase(file));
  try {
    return await body(db, file);
  } finally {
    await db.close();
  }
}

/// Runs [body] against a freshly built pre-Phase-4 database, wrapped in an
/// AppDatabase so ensureSchema can be driven directly.
Future<void> withLegacyCatalog(Future<void> Function(AppDatabase db) body) async {
  await withLegacyCatalogFile((file) async {
    final db = AppDatabase(NativeDatabase(file));
    try {
      await body(db);
    } finally {
      await db.close();
    }
  });
}

/// Builds a database in the exact pre-Phase-4 shape: the 13 original `medicines`
/// columns, no sync columns, no sync_state, `database_version = '1.0'` and
/// `user_version = 1`. The column list is what makes the convergence test
/// meaningful, so it mirrors the real asset rather than a stub.
Future<void> withLegacyCatalogFile(Future<void> Function(File file) body) async {
  final dir = await _tempDir();
  final file = File('${dir.path}/legacy.db');

  final db = _FixtureDatabase(NativeDatabase(file));
  await db.customStatement('''
    CREATE TABLE generics (
      generic_id INTEGER PRIMARY KEY,
      generic_name TEXT NOT NULL UNIQUE,
      slug TEXT,
      drug_class TEXT,
      indication TEXT,
      descriptions_count INTEGER DEFAULT 0,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
  ''');
  await db.customStatement('''
    CREATE TABLE medicines (
      brand_id INTEGER PRIMARY KEY,
      brand_name TEXT NOT NULL,
      type TEXT,
      slug TEXT,
      dosage_form TEXT,
      generic_name TEXT,
      strength TEXT,
      manufacturer TEXT,
      package_container TEXT,
      package_size TEXT,
      generic_id INTEGER,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      isSensitive INTEGER DEFAULT 0,
      FOREIGN KEY (generic_id) REFERENCES generics(generic_id)
    )
  ''');
  await db.customStatement(
    'CREATE TABLE app_metadata ('
    'key TEXT PRIMARY KEY, value TEXT, '
    'updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)',
  );
  await db.customStatement(
    "INSERT INTO app_metadata (key, value) VALUES ('database_version', '1.0')",
  );
  await db.customStatement(
    "INSERT INTO medicines (brand_id, brand_name, generic_name, generic_id) "
    "VALUES (1, 'Panadol', 'Paracetamol', 1), (2, 'Aceclo', 'Aceclofenac', 2), "
    "(3, 'Morphine-R', 'Morphine', 3)",
  );
  await db.customStatement(
    "INSERT INTO generics (generic_id, generic_name) "
    "VALUES (1, 'Paracetamol'), (2, 'Aceclofenac'), (3, 'Morphine')",
  );
  await db.close();

  await body(file);
}

/// Builds a database with a single table and no app_metadata, to exercise the
/// "predates versioning" path of the gate.
Future<(File, _FixtureDatabase)> withBareFile(String name, String ddl) async {
  final dir = await _tempDir();
  final file = File('${dir.path}/$name');
  final db = _FixtureDatabase(NativeDatabase(file));
  await db.customStatement(ddl);
  return (file, db);
}

/// Builds a database whose `database_version` cannot be parsed.
Future<(File, _FixtureDatabase)> withUnparseableVersion() async {
  final (file, db) = await withBareFile(
    'weird.db',
    'CREATE TABLE app_metadata (key TEXT PRIMARY KEY, value TEXT)',
  );
  await db.customStatement(
    "INSERT INTO app_metadata (key, value) "
    "VALUES ('database_version', 'vNext')",
  );
  return (file, db);
}

/// Drift database with no migration hook, for building fixtures. AppDatabase is
/// unsuitable here: opening one would run ensureSchema and mutate the fixture
/// before the test could inspect its starting shape. The no-op onUpgrade keeps
/// drift from objecting to the fixtures' `user_version` of 0.
class _FixtureDatabase extends drift.GeneratedDatabase {
  _FixtureDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  Iterable<drift.TableInfo> get allTables => const [];

  @override
  drift.MigrationStrategy get migration =>
      drift.MigrationStrategy(onUpgrade: (m, from, to) async {});
}

Future<Map<String, String>> _columns(drift.GeneratedDatabase db, String table) async {
  final rows = await db.customSelect('PRAGMA table_info($table)').get();
  return {for (final row in rows) row.data['name'] as String: row.data['type'] as String};
}

Future<List<String>> _tableNames(drift.GeneratedDatabase db) async {
  final rows = await db
      .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
      .get();
  return rows.map((row) => row.data['name'] as String).toList();
}

Future<Directory> _tempDir() =>
    Directory.systemTemp.createTemp('pharmazen_phase4_');
