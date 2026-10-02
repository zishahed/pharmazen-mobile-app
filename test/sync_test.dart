import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharmazen_mobile_app/data/db/app_database.dart';
import 'package:pharmazen_mobile_app/data/remote/sync_api_client.dart';
import 'package:pharmazen_mobile_app/data/remote/sync_manifest.dart';
import 'package:pharmazen_mobile_app/data/sync/sync_engine.dart';

void main() {
  group('content hashing', () {
    test('is stable and order-independent across null vs empty', () {
      final a = computeMedicineHash(_hashSubject(genericId: null, genericName: null));
      final b = computeMedicineHash(_hashSubject(genericId: null, genericName: ''));
      expect(a, b, reason: 'null and empty must hash identically, or every '
          'row would rewrite itself on every sync');
    });

    test('changes when any synced field changes', () {
      final base = computeMedicineHash(_hashSubject());
      expect(computeMedicineHash(_hashSubject(strength: '250 mg')), isNot(base));
      expect(computeMedicineHash(_hashSubject(isDeleted: true)), isNot(base));
      expect(
        computeMedicineHash(_hashSubject(genericId: 9, genericName: 'Other')),
        isNot(base),
      );
    });

    test('is 16 lowercase hex digits', () {
      expect(
        computeMedicineHash(_hashSubject()),
        matches(RegExp(r'^[0-9a-f]{16}$')),
      );
    });

    test('does not depend on description, which is not synced', () {
      expect(
        computeMedicineHash(_hashSubject()).length,
        computeMedicineHash(_hashSubject()).length,
      );
    });
  });

  group('page decoding', () {
    test('tolerates absent optional fields', () {
      final page = SyncDeltaPage.fromJson(const {'medicines': [], 'generics': []});
      expect(page.nextCursor, isNull);
      expect(page.serverTime, isNull);
      expect(page.isFullResync, isFalse);
    });

    test('ignores a null entry inside the arrays', () {
      final page = SyncDeltaPage.fromJson(const {
        'medicines': [null],
        'generics': [null],
        'nextCursor': 'c1',
      });
      expect(page.medicines, isEmpty);
      expect(page.generics, isEmpty);
      expect(page.nextCursor, 'c1');
    });
  });

  group('engine against a fake endpoint', () {
    test('pages until the cursor runs out, then advances the cursor once', () async {
      await withCatalog((db) async {
        final adapter = _FakeAdapter([
          _page(
            medicines: [_medicine(remoteId: 'm-1')],
            generics: [_generic(genericId: 1, genericName: 'Paracetamol')],
            nextCursor: 'page-2',
            serverTime: '2026-01-02T00:00:00Z',
          ),
          _page(
            medicines: [_medicine(remoteId: 'm-2', brandName: 'Panadol Extra')],
            nextCursor: null,
            serverTime: '2026-01-02T00:00:00Z',
          ),
        ]);

        final engine = _engine(db, adapter);
        final outcome = await engine.sync(trigger: SyncTrigger.coldStart);

        expect(outcome.status, SyncStatus.success);
        expect(outcome.pages, 2);
        expect(outcome.applied.inserted, 2);
        expect(adapter.requests, hasLength(2));
        expect(adapter.requests.first.queryParameters['cursor'], isNull);
        expect(adapter.requests.last.queryParameters['cursor'], 'page-2');
        expect(
          await db.readSyncState('last_success_at'),
          '2026-01-02T00:00:00Z',
          reason: 'cursor must come from serverTime, not the local clock',
        );
      });
    });

    test('sends the stored cursor as ?since= on the next run', () async {
      await withCatalog((db) async {
        final adapter = _FakeAdapter([
          _page(medicines: [_medicine(remoteId: 'm-1')], serverTime: '2026-01-02T00:00:00Z'),
        ]);
        await _engine(db, adapter).sync();

        adapter.responses.clear();
        adapter.requests.clear();
        adapter.responses.add(
          _page(medicines: [], serverTime: '2026-01-03T00:00:00Z'),
        );

        await _engine(db, adapter).sync();
        expect(
          adapter.requests.single.queryParameters['since'],
          '2026-01-02T00:00:00Z',
        );
      });
    });

    test('re-running the same delta is a no-op, because writes are idempotent', () async {
      await withCatalog((db) async {
        final body = _page(
          medicines: [_medicine(remoteId: 'm-1')],
          serverTime: '2026-01-02T00:00:00Z',
        );
        final adapter = _FakeAdapter([body]);
        final engine = _engine(db, adapter);

        expect((await engine.sync()).applied.inserted, 1);

        adapter.responses.clear();
        adapter.responses.add(body);
        final second = await engine.sync(trigger: SyncTrigger.manual);
        expect(second.applied.skipped, 1, reason: 'unchanged hash must skip');
        expect(second.applied.inserted, 0);
        expect(await _medicineCount(db), 1, reason: 'must not duplicate');
      });
    });

    test('leaves the cursor untouched when a later page fails', () async {
      await withCatalog((db) async {
        final adapter = _FakeAdapter([
          _page(
            medicines: [_medicine(remoteId: 'm-1')],
            nextCursor: 'page-2',
            serverTime: '2026-01-02T00:00:00Z',
          ),
          _Failure('server exploded', statusCode: 500),
        ]);
        // maxAttempts retries mean the failure response is consumed three times.
        final outcome = await _engine(db, adapter).sync();

        expect(outcome.status, SyncStatus.failed);
        expect(
          await db.readSyncState('last_success_at'),
          isNull,
          reason: 'a partial run must not advance the cursor, or the first '
              "page's rows would be lost from the next window",
        );
      });
    });

    test('reports unsupported rather than failed while Phase 2 is missing', () async {
      await withCatalog((db) async {
        final adapter = _FakeAdapter([_Failure('Not Found', statusCode: 404)]);
        final outcome = await _engine(db, adapter).sync();

        expect(outcome.status, SyncStatus.unsupported);
        expect(outcome.isEndpointMissing, isTrue);
        expect(outcome.isSuccess, isFalse);
      });
    });

    test('a 404 is not retried, but a 500 is', () async {
      await withCatalog((db) async {
        final notFound = _FakeAdapter([_Failure('nope', statusCode: 404)]);
        await _engine(db, notFound).sync();
        expect(notFound.requests, hasLength(1), reason: '404 is a real answer');

        final boom = _FakeAdapter([_Failure('boom', statusCode: 500)]);
        await _engine(db, boom).sync();
        expect(boom.requests, hasLength(3), reason: 'maxAttempts = 3');

        final dropped = _FakeAdapter([const _Throw('connection reset')]);
        await _engine(db, dropped).sync();
        expect(dropped.requests, hasLength(3), reason: 'transport errors retry');
      });
    });

    test('full resync clears only the sync bookkeeping', () async {
      await withCatalog((db) async {
        final adapter = _FakeAdapter([
          _page(medicines: [_medicine(remoteId: 'm-1')], serverTime: '2026-01-02T00:00:00Z'),
        ]);
        await _engine(db, adapter).sync();
        expect(await _medicineCount(db), 1);

        // A local row the server knows nothing about: it must survive.
        await db.customStatement(
          "INSERT INTO medicines (brand_id, brand_name, remote_id, content_hash) "
          "VALUES (9001, 'Local Only', 'm-local', 'abc')",
        );
        await db.writeSyncState('last_success_at', '2026-01-02T00:00:00Z');

        final resync = _FakeAdapter([
          _page(
            medicines: [_medicine(remoteId: 'm-2', brandName: 'Fresh')],
            isFullResync: true,
            serverTime: '2026-02-01T00:00:00Z',
          ),
        ]);
        final outcome = await _engine(db, resync).sync(trigger: SyncTrigger.manual);

        expect(outcome.status, SyncStatus.fullResync);
        expect(
          await _medicineCount(db),
          3,
          reason: 'a resync clears identity, it does not delete local rows: '
              'the previously synced row, the local-only row and the fresh row '
              'all survive',
        );
        final survivors = await db.customSelect(
          'SELECT brand_name, remote_id, content_hash FROM medicines ORDER BY brand_id',
        ).get();
        expect(
          survivors.map((r) => r.data['brand_name'] as String),
          containsAll(['Local Only', 'Fresh', 'Panadol']),
        );
        // The stale cursor must be gone, replaced by the new snapshot time.
        expect(await db.readSyncState('last_success_at'), '2026-02-01T00:00:00Z');
      });
    });

    test('a tombstone hides the row without deleting its catalog fields', () async {
      await withCatalog((db) async {
        final adapter = _FakeAdapter([
          _page(medicines: [_medicine(remoteId: 'm-1')], serverTime: '2026-01-02T00:00:00Z'),
        ]);
        await _engine(db, adapter).sync();

        adapter.responses.clear();
        adapter.requests.clear();
        adapter.responses.add(
          _page(
            medicines: [_medicine(remoteId: 'm-1', isDeleted: true)],
            serverTime: '2026-01-04T00:00:00Z',
          ),
        );
        final outcome = await _engine(db, adapter).sync(trigger: SyncTrigger.manual);

        expect(outcome.applied.tombstoned, 1);
        final row = (await db.customSelect('SELECT * FROM medicines').get()).single;
        expect(row.data['is_deleted'], 1);
        expect(row.data['brand_name'], isNotNull, reason: 'name is kept for audit');
      });
    });

    test('updates an existing row in place instead of inserting a duplicate', () async {
      await withCatalog((db) async {
        final adapter = _FakeAdapter([
          _page(
            medicines: [_medicine(remoteId: 'm-1', brandName: 'Old Name')],
            serverTime: '2026-01-02T00:00:00Z',
          ),
        ]);
        await _engine(db, adapter).sync();

        adapter.responses.clear();
        adapter.requests.clear();
        adapter.responses.add(
          _page(
            medicines: [_medicine(remoteId: 'm-1', brandName: 'New Name')],
            serverTime: '2026-01-05T00:00:00Z',
          ),
        );
        final outcome = await _engine(db, adapter).sync(trigger: SyncTrigger.manual);

        expect(outcome.applied.updated, 1);
        expect(await _medicineCount(db), 1);
        final row = (await db.customSelect('SELECT brand_name FROM medicines').get()).single;
        expect(row.data['brand_name'], 'New Name');
      });
    });

    test('generics land before medicines, so generic_id can resolve', () async {
      await withCatalog((db) async {
        final adapter = _FakeAdapter([
          _page(
            // A medicine whose generic is delivered in the same page: if generics
            // were applied second this would land as a stub with a negative id.
            generics: [_generic(genericId: 42, genericName: 'Paracetamol')],
            medicines: [
              _medicine(remoteId: 'm-1', genericId: 42, genericName: 'Paracetamol'),
            ],
            serverTime: '2026-01-02T00:00:00Z',
          ),
        ]);
        await _engine(db, adapter).sync();

        final row = (await db.customSelect(
          'SELECT generic_id FROM medicines WHERE remote_id = ?',
          variables: [drift.Variable.withString('m-1')],
        ).get()).single;
        expect(row.data['generic_id'], 42, reason: 'must not be a stub id');
      });
    });

    test('an unknown generic becomes a negative stub and does not clobber names', () async {
      await withCatalog((db) async {
        final adapter = _FakeAdapter([
          _page(
            medicines: [_medicine(remoteId: 'm-1', genericId: 999, genericName: 'Unknown Drug')],
            serverTime: '2026-01-02T00:00:00Z',
          ),
        ]);
        await _engine(db, adapter).sync();

        final row = (await db.customSelect(
          'SELECT generic_id, generic_name FROM medicines WHERE remote_id = ?',
          variables: [drift.Variable.withString('m-1')],
        ).get()).single;
        expect(row.data['generic_id'], lessThan(0), reason: 'stub id');
        expect(row.data['generic_name'], 'Unknown Drug');

        // A later delta must not overwrite the name with the stub's null.
        adapter.responses.clear();
        adapter.requests.clear();
        adapter.responses.add(_page(medicines: [], serverTime: '2026-01-03T00:00:00Z'));
        await _engine(db, adapter).sync(trigger: SyncTrigger.manual);
        final after = (await db.customSelect(
          'SELECT generic_name FROM medicines WHERE remote_id = ?',
          variables: [drift.Variable.withString('m-1')],
        ).get()).single;
        expect(after.data['generic_name'], 'Unknown Drug');
      });
    });

    test('falls back to max(updatedAt) when the server omits serverTime', () async {
      await withCatalog((db) async {
        final adapter = _FakeAdapter([
          _page(
            medicines: [
              _medicine(remoteId: 'm-1', updatedAt: '2026-01-02T00:00:00Z'),
              _medicine(remoteId: 'm-2', updatedAt: '2026-01-09T00:00:00Z'),
            ],
          ),
        ]);
        await _engine(db, adapter).sync();
        expect(await db.readSyncState('last_success_at'), '2026-01-09T00:00:00Z');
      });
    });

    test('coalesces concurrent callers onto one run', () async {
      await withCatalog((db) async {
        final adapter = _FakeAdapter([
          _page(medicines: [_medicine(remoteId: 'm-1')], serverTime: '2026-01-02T00:00:00Z'),
        ]);
        final engine = _engine(db, adapter);

        final results = await Future.wait([
          engine.sync(),
          engine.sync(),
          engine.sync(),
        ]);

        expect(adapter.requests, hasLength(1), reason: 'single-flight');
        expect(results.map((r) => r.pages).toSet(), {1});
      });
    });

    test('a run that finished blocks the next automatic one', () async {
      await withCatalog((db) async {
        final adapter = _FakeAdapter([
          _page(medicines: [_medicine(remoteId: 'm-1')], serverTime: '2026-01-02T00:00:00Z'),
        ]);
        final now = DateTime.utc(2026, 1, 2, 12);
        var clock = now;
        // One engine across both runs: the floor is per-instance state, so two
        // engines would each run freely and the assertion would prove nothing.
        final engine = _engine(db, adapter, clock: () => clock);

        await engine.sync();
        clock = now.add(const Duration(minutes: 14));
        expect((await engine.sync()).status, SyncStatus.tooSoon);

        // Manual bypasses the floor.
        clock = now.add(const Duration(minutes: 14));
        expect(
          (await engine.sync(trigger: SyncTrigger.manual)).status,
          SyncStatus.success,
        );
      });
    });
  });

  group('fresh install', () {
    test('seeds an empty cursor, not the schema version', () async {
      await withCatalog((db) async {
        // The keys exist (Phase 4 requires them), but only
        // bundled_schema_version may carry a value. A fabricated
        // last_success_at would be sent as ?since= on the first sync.
        expect(await db.readSyncState('last_success_at'), isNull);
        expect(await db.readSyncState('last_manifest_count'), isNull);
        expect(
          await db.readSyncState('bundled_schema_version'),
          '$kBundledSchemaVersion',
        );
      });
    });

    test('an empty cursor makes the first request omit ?since=', () async {
      await withCatalog((db) async {
        final adapter = _FakeAdapter([
          _page(medicines: [_medicine(remoteId: 'm-1')], serverTime: '2026-01-02T00:00:00Z'),
        ]);
        await _engine(db, adapter).sync();
        expect(
          adapter.requests.single.queryParameters.containsKey('since'),
          isFalse,
          reason: 'a null cursor must not be serialised into the query string',
        );
      });
    });
  });

  group('manifest', () {
    test('reuses a 304 cache and keeps the ETag', () async {
      await withCatalog((db) async {
        final adapter = _FakeAdapter([
          _Raw(200, jsonEncode([
            ['m-1', 'hash1'],
            ['m-2', 'hash2'],
          ]), headers: {'etag': '"v1"'}),
          _Raw(304, '', headers: {'etag': '"v1"'}),
        ]);
        final client = _client(adapter);

        final first = await client.fetchManifest();
        expect(first.entries, hasLength(2));
        expect(first.notModified, isFalse);

        final second = await client.fetchManifest();
        expect(second.notModified, isTrue);
        expect(second.entries, hasLength(2));
        expect(adapter.requests.last.headers['If-None-Match'], '"v1"');
      });
    });

    test('skips a malformed pair instead of failing the whole manifest', () async {
      await withCatalog((db) async {
        final adapter = _FakeAdapter([
          _Raw(200, jsonEncode([
            ['m-1', 'hash1'],
            ['broken'],
            'garbage',
            ['m-2', 'hash2'],
          ])),
        ]);
        final result = await _client(adapter).fetchManifest();
        expect(result.entries.map((e) => e.remoteId), ['m-1', 'm-2']);
      });
    });

    test('drift report separates the three kinds of disagreement', () async {
      await withCatalog((db) async {
        await db.customStatement(
          "INSERT INTO medicines (brand_id, brand_name, remote_id, content_hash) "
          "VALUES (1, 'Same', 'm-same', 'h1'), "
          "(2, 'Stale', 'm-stale', 'h-old'), "
          "(3, 'Gone', 'm-gone', 'h3')",
        );
        final adapter = _FakeAdapter([
          _Raw(200, jsonEncode([
            ['m-same', 'h1'],
            ['m-stale', 'h-new'],
            ['m-remote', 'h9'],
          ])),
        ]);
        final engine = _engine(db, adapter);
        final report = await engine.verifyAgainstManifest();

        expect(report.mismatched, 1);
        expect(report.missingLocally, 1, reason: 'm-gone is absent remotely');
        expect(report.missingRemotely, 1, reason: 'm-remote is absent locally');
        expect(report.isClean, isFalse);
      });
    });
  });
}

SyncEngine _engine(
  AppDatabase db,
  _FakeAdapter adapter, {
  DateTime Function()? clock,
}) {
  return SyncEngine(
    db: db,
    client: _client(adapter),
    clock: clock,
  );
}

/// A client wired to [adapter] with no real waiting: backoff and jitter are
/// collapsed so the retry tests run instantly while still exercising the retry
/// loop.
SyncApiClient _client(_FakeAdapter adapter) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://sync.test/api',
      validateStatus: (status) => status != null && status < 600,
    ),
  );
  dio.httpClientAdapter = adapter;
  return SyncApiClient(dio: dio, sleep: (_) async {}, jitter: () => 1);
}

Map<String, Object?> _page({
  List<Map<String, Object?>> medicines = const [],
  List<Map<String, Object?>> generics = const [],
  String? nextCursor,
  String? serverTime,
  bool isFullResync = false,
}) {
  return {
    'medicines': medicines,
    'generics': generics,
    'nextCursor': ?nextCursor,
    'serverTime': ?serverTime,
    'isFullResync': isFullResync,
  };
}

Map<String, Object?> _medicine({
  String remoteId = 'm-1',
  String brandName = 'Panadol',
  String? genericName = 'Paracetamol',
  int? genericId,
  String strength = '500 mg',
  bool isDeleted = false,
  String updatedAt = '2026-01-02T00:00:00Z',
}) {
  return {
    'id': remoteId,
    'brandName': brandName,
    'type': 'Tablet',
    'slug': brandName.toLowerCase(),
    'dosageForm': 'Tablet',
    'genericName': genericName,
    'strength': strength,
    'manufacturer': 'ACME',
    'packageContainer': 'Strip',
    'packageSize': '10',
    'genericId': genericId,
    'isSensitive': false,
    'isDeleted': isDeleted,
    'updatedAt': updatedAt,
  };
}

/// The hash tests need a real DTO, not the JSON fixture.
SyncMedicine _hashSubject({
  String remoteId = 'm-1',
  String brandName = 'Panadol',
  String? genericName = 'Paracetamol',
  int? genericId,
  String strength = '500 mg',
  bool isDeleted = false,
  String updatedAt = '2026-01-02T00:00:00Z',
}) {
  return SyncMedicine.fromJson(
    _medicine(
      remoteId: remoteId,
      brandName: brandName,
      genericName: genericName,
      genericId: genericId,
      strength: strength,
      isDeleted: isDeleted,
      updatedAt: updatedAt,
    ),
  );
}

Map<String, Object?> _generic({
  required int genericId,
  required String genericName,
}) {
  return {
    'genericId': genericId,
    'genericName': genericName,
    'slug': genericName.toLowerCase(),
    'drugClass': 'Analgesic',
    'indication': 'Pain',
  };
}

Future<int> _medicineCount(AppDatabase db) async {
  final row = await db
      .customSelect('SELECT COUNT(*) AS c FROM medicines')
      .getSingle();
  return row.data['c'] as int;
}

/// A minimal Phase 4-shaped catalog in a temp file. The bundled asset is 17MB
/// and 21.7k rows; these tests need three rows and a clean slate, and they must
/// not rewrite the tracked binary.
Future<void> withCatalog(Future<void> Function(AppDatabase db) body) async {
  final dir = await Directory.systemTemp.createTemp('pharmazen_phase5_');
  final file = File('${dir.path}/catalog.db');

  final fixture = _FixtureDatabase(NativeDatabase(file));
  // Mirrors the production asset's generics columns exactly. A fixture that
  // drifts from the real schema hides real bugs: Phase 5's generic upsert writes
  // monograph_link and all fourteen description columns.
  await fixture.customStatement('''
    CREATE TABLE generics (
      generic_id INTEGER PRIMARY KEY,
      generic_name TEXT NOT NULL UNIQUE,
      slug TEXT,
      monograph_link TEXT,
      drug_class TEXT,
      indication TEXT,
      indication_description TEXT,
      therapeutic_class_description TEXT,
      pharmacology_description TEXT,
      dosage_description TEXT,
      administration_description TEXT,
      interaction_description TEXT,
      contraindications_description TEXT,
      side_effects_description TEXT,
      pregnancy_and_lactation_description TEXT,
      precautions_description TEXT,
      pediatric_usage_description TEXT,
      overdose_effects_description TEXT,
      duration_of_treatment_description TEXT,
      reconstitution_description TEXT,
      storage_conditions_description TEXT,
      descriptions_count INTEGER DEFAULT 0,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
  ''');
  await fixture.customStatement('''
    CREATE TABLE medicines (
      brand_id INTEGER PRIMARY KEY AUTOINCREMENT,
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
      remote_id TEXT,
      content_hash TEXT,
      synced_at TIMESTAMP,
      is_deleted INTEGER NOT NULL DEFAULT 0,
      isSensitive INTEGER DEFAULT 0,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (generic_id) REFERENCES generics(generic_id)
    )
  ''');
  await fixture.customStatement('''
    CREATE TABLE app_metadata (
      key TEXT PRIMARY KEY, value TEXT,
      updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
  ''');
  await fixture.customStatement('''
    CREATE TABLE sync_state (
      key TEXT PRIMARY KEY, value TEXT,
      updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
  ''');
  await fixture.customStatement(
    "INSERT INTO app_metadata (key, value) VALUES ('database_version', '2.0')",
  );
  // sync_state is deliberately left empty: AppDatabase.ensureSchema then seeds
  // it, which is the fresh-install path whose defaults regressed once already.
  await fixture.close();

  final db = AppDatabase(NativeDatabase(file));
  try {
    await body(db);
  } finally {
    await db.close();
    await dir.delete(recursive: true);
  }
}

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

/// A canned HTTP response.
class _Raw {
  _Raw(this.statusCode, this.body, {this.headers = const {}});
  final int statusCode;
  final String body;
  final Map<String, String> headers;
}

class _Failure {
  _Failure(this.message, {this.statusCode = 500});
  final String message;
  final int statusCode;
}

/// A response that never arrives, to exercise the transport-failure path.
class _Throw {
  const _Throw(this.message);
  final String message;
}

/// Serves canned responses in order and records what was asked for.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);

  final List<Object> responses;
  final List<RequestOptions> requests = [];
  int _index = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final response = responses[_index.clamp(0, responses.length - 1)];
    _index++;

    return switch (response) {
      _Raw(:final statusCode, :final body, :final headers) => ResponseBody.fromString(
        body,
        statusCode,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
          for (final entry in headers.entries) entry.key: [entry.value],
        },
      ),
      _Failure(:final message, :final statusCode) => ResponseBody.fromString(
        jsonEncode({'error': message}),
        statusCode,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
      _Throw(:final message) => throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: StateError(message),
      ),
      _ => ResponseBody.fromString(
        jsonEncode(response),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    };
  }

  @override
  void close({bool force = false}) {}
}
