# PharmaZen Sync — Neon ➜ local `medicines.db`

## Problem

The local `medicines.db` is a pre-built, read-only asset copied to disk on first launch
(`lib/data/db/app_database.dart:22`). Nothing in it can detect remote changes, because
`medicines` and `generics` have **no `updated_at`, no version, and no tombstone** — only
`created_at`, which is identical on every row. A delta sync is therefore impossible to
compute until a change signal, a stable remote identity, and a mapping layer are added.

Three missing pieces:

1. **Change signal** — `updatedAt` / `isDeleted` columns on the Postgres models, consumed via a `?since=` cursor.
2. **Stable identity** — local PK is `brand_id INTEGER`, Neon's is `id UUID`. A local `remote_id` column bridges them so upserts are idempotent.
3. **Mapping layer** — Neon's `medicines` row is flat; the app needs `generic_name`, `dosage_form`, `manufacturer` and a `generic_id` FK into `generics`.

## Locked decisions

| Area | Decision |
|---|---|
| Source | Extend `pharmazen-backend` (Express + Prisma + Neon) |
| Direction | One-way pull, remote ➜ local |
| Mechanism | `?since=` cursor primary, manifest for repair |
| Repair trigger | Server sets `isFullResync` when cursor predates retention |
| Identity | Neon keeps UUID `medicines.id`; local gains `remote_id` bridge |
| Generics | Neon gets `Generic` model, `generic_id Int @id`, all 23 columns, 1:1 mirror |
| Medicines | Real columns added to Neon; `description` retained for the website |
| Deletions | Soft delete + client tombstone, guarded |
| Unmatched generics | Insert stub `generics` row (only needed if `generic_id` is NULL) |
| Price | Not synced; local `package_container` preserved |
| Auth | Public, rate-limited, ETag |
| Cadence | 15-min floor, single-flight mutex |
| Triggers | Cold start + connectivity regained + manual pull-to-refresh |
| Admin | Generics CRUD included in this scope |
| Asset handling | Bundled asset as seed, overlay deltas |

---

## Pre-flight — resolve the `medicine_groups` question

**This gates Phase 1 and must be answered first.**

`medicine_groups` / `medicine_variants` appear **nowhere** in the codebase — not in
`prisma/schema.prisma`, not in any script, not in `BACKEND-ARCHITECTURE.md`. The only
trace anywhere is `migration-optimized.log`, which reports "Found 1824 existing medicine
groups" and "Created 14233 medicine groups and variants". `prisma/migrations/` is also
absent, and `package.json` has no `migrate` script. This reads as an abandoned experiment
whose script was deleted.

But it is not bookkeeping. **You described `description` as 3 fields
(generic | form | manufacturer); `prisma/seed.js:60-65` writes 4** (it includes
`strength`). If `medicine_variants` holds form and strength as real columns, then
`description` was rewritten to 3 fields *because* that data moved into the variants table
— meaning the "optimized migration" may already have done most of what Phase 1 proposes,
possibly with better normalized structure.

### Step 1 — read-only inspection in the Neon console

```sql
SELECT table_name FROM information_schema.tables
WHERE table_schema='public' ORDER BY table_name;
```

```sql
SELECT 'medicines' AS t, count(*) FROM medicines
UNION ALL SELECT 'medicine_groups', count(*) FROM medicine_groups
UNION ALL SELECT 'medicine_variants', count(*) FROM medicine_variants;
```

The second query errors out if those tables do not exist — which is itself the answer.

### Step 2 — if present, inspect before deciding

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema='public' AND table_name LIKE 'medicine_%'
ORDER BY table_name, ordinal_position;
```

```sql
SELECT description FROM medicines LIMIT 10;
```

That last query settles the 3-vs-4 field question empirically.

### Step 3 — branch

| Result | Action |
|---|---|
| Tables absent | Migration was never applied or was rolled back. Ignore them; proceed with Phase 1 as written. |
| Present, holding richer normalized data | **Adopt them instead of extending flat `medicines`.** Rewrite Phase 1 to mirror that structure. Better than the current plan. |
| Present, stale duplicates | Leave orphaned and unreferenced. Do not drop them blind — first check whether `medicines.categoryId` was rewritten to point at them, which would make the flat table dependent. |

---

## Phase 1 — Neon schema (backend)

### New model

```prisma
model Generic {
  genericId      Int      @id @map("generic_id")
  genericName    String   @unique @map("generic_name")
  slug           String?
  monographLink  String?  @map("monograph_link")
  drugClass      String?  @map("drug_class")
  indication     String?
  indicationDescription           String? @map("indication_description")
  therapeuticClassDescription    String? @map("therapeutic_class_description")
  pharmacologyDescription        String? @map("pharmacology_description")
  dosageDescription              String? @map("dosage_description")
  administrationDescription      String? @map("administration_description")
  interactionDescription         String? @map("interaction_description")
  contraindicationsDescription   String? @map("contraindications_description")
  sideEffectsDescription         String? @map("side_effects_description")
  pregnancyAndLactationDescription String? @map("pregnancy_and_lactation_description")
  precautionsDescription          String? @map("precautions_description")
  pediatricUsageDescription      String? @map("pediatric_usage_description")
  overdoseEffectsDescription     String? @map("overdose_effects_description")
  durationOfTreatmentDescription String? @map("duration_of_treatment_description")
  reconstitutionDescription      String? @map("reconstitution_description")
  storageConditionsDescription   String? @map("storage_conditions_description")
  descriptionsCount Int        @default(0) @map("descriptions_count")
  createdAt      DateTime  @default(now()) @map("created_at")
  updatedAt      DateTime  @updatedAt @map("updated_at")
  isDeleted      Boolean   @default(false) @map("is_deleted")

  medicines      Medicine[]

  @@index([drugClass])
  @@index([indication])
  @@map("generics")
}
```

### Extended `Medicine`

Add to the existing model (all nullable, so no existing query breaks):

```prisma
  genericId       Int?     @map("generic_id")
  slug            String?
  type            String?
  dosageForm      String?  @map("dosage_form")
  strength        String?
  manufacturer    String?
  packageContainer String? @map("package_container")
  packageSize     String?  @map("package_size")
  isSensitive     Boolean  @default(false) @map("is_sensitive")
  updatedAt       DateTime @updatedAt @map("updated_at")
  isDeleted       Boolean  @default(false) @map("is_deleted")
```

`description` stays as a derived, populated column so the React frontend's
`description contains` filters (`medicines.service.js:22-34`) keep matching.

### Three mandatory changes beyond the schema

#### 1. Soft delete

`medicines.service.js:248` currently does a hard delete (`prisma.medicine.delete`). A
`?since=` cursor can never observe a physically removed row, so deletions would silently
never reach devices. Change to `update({ where: { id }, data: { isDeleted: true } })`.

#### 2. `isDeleted: false` filters on all public read paths

Required on `getMedicines`, `getMaxPrice`, `getFilterOptions`, `getRestrictedMedicines`,
plus the cart and prescription read paths (see below). **The filters must never lag behind
the soft-delete switch** — that ordering is what Phase 1A / 1B exist to guarantee.

#### 3. Prisma singleton

Ten separate `new PrismaClient()` calls exist across `src/` (`auth`, `cart`, `categories`,
`medicines`, `orders`, `payments`, `prescriptions`, `admin`). Under Vercel serverless this
exhausts the Neon pooler. Extract to one shared module and import it everywhere.

### 1A / 1B — mandatory two-phase rollout

Changing `deleteMedicine` is not a one-line swap, because it alters which deletes
succeed. `CartItem.medicine` (`prisma/schema.prisma:153`) and `OrderItem.medicine`
(`:185`) declare **no `onDelete`**, so Postgres enforces `RESTRICT`. Consequences:

- **Today**, `deleteMedicine` already *fails* for any medicine present in a cart or in
  order history — the FK blocks the delete and the handler rethrows
  `'Failed to delete medicine'`. Admins cannot delete a sold medicine at all.
- **After soft delete**, the FK obstacle disappears and the delete *succeeds* where it
  previously errored. That is an improvement, but `getCart` will then return items whose
  medicine is soft-deleted, with no "unavailable" indication — shipping a broken cart.

Rollout order:

**Phase 1A — zero behavior change.** Add the `isDeleted` columns; add `isDeleted: false`
to every read query. Nothing is soft-deleted yet, so the filters are inert but already
deployed. Verify the website is unchanged before continuing.

**Phase 1B — enable soft delete.** In a single deploy:

- Switch `deleteMedicine` to `update({ isDeleted: true })`.
- Add `POST /api/admin/medicines/:id/restore` so deletes are reversible.
- Filter soft-deleted medicines out of cart joins, or surface them as unavailable in the
  cart UI. Decide which, but do not leave it unhandled.
- Run a one-off reconciliation query for medicines that are soft-deleted yet still
  referenced by active carts.

Two properties worth stating explicitly:

- Order history survives soft delete. `OrderItem` resolves through the live `medicine`
  relation, and `Prescription` already snapshots `medicineName` (`prisma/schema.prisma:106`),
  so no historical record dangles.
- The invariant to protect: **Phase 1A fully deployed and verified before Phase 1B ships.**
  Never both in one release.

### Backfill

`prisma/seed-sync-source.js` reads **this app's** `assets/database/medicines.db` — not the
6th-semester copy the current `prisma/seed.js` reads (`DB_PATH` resolves to
`../../medicines.db`) — and upserts both tables with real columns, in batches.

Importing through the existing lossy `seed.js` would defeat the purpose: it discards
`generic_id`, `brand_id`, `slug`, `dosage_form`, `strength`, `manufacturer`,
`package_container` and every monograph column, and regex-scrapes price
(`parsePrice`, `seed.js:8-11`).

---

## Phase 2 — `/api/sync` endpoints

- `GET /api/sync?since=<ISO>&cursor=<opaque>` →
  `{ nextCursor, serverTime, isFullResync, medicines[], generics[] }`, page-bounded.
  `vercel.json` declares no `maxDuration`, so page size must stay conservative.
- `GET /api/sync/manifest` → `[[remoteId, hash], …]`, used only for repair/drift detection.
- Public, no auth. Rate-limited, ETag on the manifest.
- `isFullResync: true` when the supplied `since` predates the server's retention window.
- **`serverTime` is required, not optional.** It is the server's clock at the instant
  the snapshot was taken, repeated on every page. The client stores it as
  `last_success_at` once the final page commits, and sends it back as the next `?since=`.
  It marks the instant after which *every* change is guaranteed to surface in a later
  delta — including rows edited while the pages were still being fetched, which is
  exactly what a cursor cannot otherwise express.

  Deriving the next cursor from `MAX(updatedAt)` in the payload instead is subtly wrong:
  a row sharing a timestamp with the final row of the final page can be skipped forever.
  The client tolerates its absence (it falls back to `MAX(updatedAt)`) so an incomplete
  server is still testable, but that fallback loses those rows until the next full
  resync. Take it from the database, not from `Date.now()` in Node, so clock skew on
  the server host cannot run the cursor backwards.

---

## Phase 3 — Admin CRUD for generics

New `src/modules/generics/{routes,controller,service}.js`, mounted in `src/app.js` in the
style of the existing modules, behind the existing `authenticate, authorize('admin')`
middleware.

Note: `admin.routes.js` currently has no medicines or generics CRUD at all — only
`/stats`, `/orders`, `/users`, `/sales`. Medicine CRUD lives in `medicines.routes.js`.

---

## Phase 4 — Flutter local schema

### New columns / tables

- `medicines`: `remote_id TEXT`, `content_hash TEXT`, `synced_at TEXT`, `is_deleted INTEGER DEFAULT 0`
- New `sync_state(key TEXT PRIMARY KEY, value TEXT, updated_at TEXT)` holding `last_success_at`, `last_manifest_count`, `bundled_schema_version`

### Two fixes in `app_database.dart`

1. **Version-gated re-seed.** Line 22's `if (!await file.exists())` means a newly bundled
   DB is never installed over an existing one. Read `app_metadata.database_version` on
   device; if `< kBundledSchemaVersion`, delete the file and re-copy the asset.

2. **Hand-rolled DDL.** `allTables => []` with no `migrationStrategies`
   (`app_database.dart:15-17`) means Drift migrates nothing. Add `ensureSchema()` with
   `CREATE TABLE IF NOT EXISTS` plus duplicate-column-guarded `ALTER TABLE`.

Apply the same migration to the asset file itself so first-run installs receive the new
columns. `test/medicine_repository_test.dart` opens the asset path directly and must stay
green.

---

## Phase 5 — Sync engine + triggers

```
lib/core/config/api_config.dart          String.fromEnvironment('API_BASE_URL')
lib/core/network/connectivity_service.dart
lib/data/remote/sync_api_client.dart     Dio, timeout, retry/backoff
lib/data/remote/sync_manifest.dart       DTO + contentHash factory
lib/data/sync/sync_engine.dart           fetch → diff → fetch changed → apply
lib/data/sync/sync_applier.dart          upsert by remote_id, tombstone
lib/data/sync/generic_resolver.dart      generic_name → generic_id, stub insert
```

No new pubspec dependencies — `dio`, `connectivity_plus`, `drift` are already present.
`--dart-define` avoids adding `flutter_dotenv`.

**Concurrency.** Drift runs on a background isolate (`createInBackground`,
`app_database.dart:26`), so a long write blocks readers. Apply in ~500-row batches with
short `BEGIN IMMEDIATE` transactions, and enable WAL (the asset is currently
`journal_mode = delete`).

**Idempotency.** Advance `sync_state.last_success_at` only after the final batch commits.
A crash mid-sync leaves the cursor unchanged, so the run is safely repeatable — every
write is an upsert keyed on `remote_id`.

**Triggers.** Post-first-frame on cold start, on connectivity regained, and manual
pull-to-refresh — all behind single-flight and a 15-minute minimum interval. Only the
manual trigger bypasses that interval; the interval is what debounces a connection that
is flapping rather than a separate timer, so a user cannot turn connectivity changes
into a request loop either.

---

## Phase 6 — Hardening

- ~~Add `<uses-permission android:name="android.permission.INTERNET"/>` to
  `android/app/src/main/AndroidManifest.xml`.~~ Done in Phase 5 — release builds are the
  only ones that lacked it, since the debug and profile manifests already declare it.
- Guard deletions: only tombstone after a *complete* manifest whose row count is within
  ~20% of `last_manifest_count`.
- Never bulk-delete. Tombstone individually.
- Handle `isFullResync` by wiping sync state and rebuilding from scratch.
- Stub `generics` rows have NULL `indication`, and `allValues` uses
  `SELECT DISTINCT ... WHERE column IS NOT NULL` (`medicine_repository.dart:60-65`), so they
  stay out of indication browse. But `app_metadata.descriptions_count` drifts — nothing
  reads it today.

---

## Execution order

**Pre-flight → Phase 1A → Phase 4 → Phase 5 → Phase 1B → Phase 2 → Phase 3**

Local schema work comes early: it is offline, independently testable, and unblocks
everything else. The Neon changes are split so that Phase 1A (inert filters, no behavior
change) lands well before Phase 1B (soft delete), since only those changes can affect the
live website.

---

## Open items

1. **`type` and `package_size` nullability in Neon.** The SQLite has both populated, but
   neither appears in the existing write shape (`medicines.service.js:227-236`), so live
   rows may be `NULL`. Decide whether they are nullable in the extended model.

2. **`description` must stay populated.** It is now a derived column kept only for the
   React frontend's `description contains` filters (`medicines.service.js:22-34`). Any
   admin CRUD path that edits `name`, `dosageForm`, `strength` or `manufacturer` must
   recompute `description`, or website search silently degrades.

3. **Generic CRUD deletion semantics.** Phase 3 needs the same 1A/1B treatment: a soft
   `isDeleted` on `generics` plus filters on the app's generic read paths, otherwise
   medicines keep resolving to hidden generics.


Notes worth carrying forward
- description was never 3 fields — it's 4 (generic | form | strength | manufacturer), confirmed against Neon. SYNC.md's premise for the pre-flight is wrong on that point, though the conclusion (abandoned migration) held.
- Open item #1 resolved: package_size is NULL for 7,779 asset rows so nullable was correct; type is 100% populated now. Both kept nullable, which is safe either way.
- Open item #2 satisfied: the backfill never writes description, so website search is untouched.
- The backfill is slow (~30 min for 21k rows — 500-statement round-trips). If you ever need to re-run it, expect that; a prisma.$executeRaw bulk UPDATE ... FROM (VALUES ...) would be far faster. Worth doing if Phase 1B needs another full pass.
- BACKEND-ARCHITECTURE.md is now stale: it documents the 9 separate PrismaClients and lists the payments.controller.js leak as an open issue that this commit fixes.
- Phase 1A is live and verified (commit a5ca612): 21,715 medicines loading, max-price 996.74, 1663 genericNames / 226 companies, 359 categories — all identical pre- and post-deploy.

Phase 4 — Flutter local schema: done, uncommitted
- `tool/phase4_asset_migration.sql` migrated the asset: 4 columns on `medicines`, `sync_state` seeded, `database_version` 1.0 -> 2.0, `PRAGMA user_version` 2, VACUUMed 17.8MB -> 17.1MB. `integrity_check` ok, 21,715 rows, 0 tombstones.
- `app_database.dart`: version-gated re-seed + `ensureSchema()`, both `CREATE TABLE IF NOT EXISTS` and column-guarded `ALTER TABLE`, applied in one transaction and only when something is actually missing.
- `test/app_database_test.dart` adds 24 tests; full suite 38 green.

Phase 4 gotchas worth remembering
- `app_metadata.database_version` is `'1.0'`, not `'1'`. `int.parse` throws on it and the gate would re-seed forever; `parseSchemaVersion` takes the leading integer instead.
- **Drift rewrites `PRAGMA user_version = schemaVersion` on every open, in both directions.** The version-gate probe must therefore declare `schemaVersion => kBundledSchemaVersion`, or every launch silently downgrades the installed file's `user_version`. `app_metadata.database_version` is the real gate, not the pragma.
- A bare `QueryExecutor` rejects statements until the delegating wrapper opens it; reading metadata through `AppDatabase` would instead run `ensureSchema` and make a stale file look current. Hence `_MetadataOnly`.
- `customStatement` takes raw Dart values; `customSelect` takes `Variable`s. `Variable<T extends Object>` cannot carry a null, so `writeSyncState` emits a literal `NULL`.
- With `allTables => []`, bumping `schemaVersion` makes drift throw `MissingSchemaError` on any version mismatch — hence the no-op `onUpgrade`.
- Tests must not open the tracked asset directly; `withAssetCopy` copies it. Verified the asset md5 is unchanged across a full run.
- Re-seeding is only safe while this file holds catalog data plus sync bookkeeping. Once Phase 5 adds a local order queue (e.g. `app_metadata.last_pushed_order_id`), a future `kBundledSchemaVersion` bump will wipe unpushed state — preserve `app_metadata` across the copy or gate the bump.
- Still to do later: `journal_mode` is `delete`, so Phase 5 must enable WAL, and `discardCatalog` now clears the `-wal`/`-shm` sidecars so that swap is safe.


Phase 5 is complete and verified: flutter analyze clean, 63 tests passing (38 pre-existing + 25 new), bundled asset untouched.
New files: lib/core/config/api_config.dart, lib/core/network/connectivity_service.dart, lib/data/remote/{sync_manifest,sync_api_client}.dart, lib/data/sync/{generic_resolver,sync_applier,sync_engine}.dart, lib/data/providers/sync_providers.dart, test/sync_test.dart.
Wired up: WAL on the on-device copy only, cold-start + connectivity triggers via syncTriggersProvider, pull-to-refresh on both result lists, and android.permission.INTERNET (release builds were the only ones missing it — debug/profile already had it).
Four real bugs the tests caught, now fixed:
1. ensureSchema seeded every sync_state key with the schema version, so a fresh install's first sync would have sent ?since=2 as its cursor (app_database.dart:37 — now per-key kSyncStateDefaults). This was Phase 4 code, not Phase 5.
2. SyncApplier._nextBrandId did (maxId ?? 0) < 0 ? 0 : maxId! + 1 — the ?? guarded the comparison but not the branch, crashing on an empty catalog.
3. _send returned an exhausted 5xx as if it were a valid response, and fetchDelta parsed the error body as an empty page — which would have advanced the cursor over data never fetched. Now the last retryable attempt throws, and non-2xx is rejected before parsing (404 → unsupported, not failed).
4. GenericResolver.resolveId trusted the server's generic_id without checking it exists locally, leaving dangling references. It now falls through to name resolution and a negative stub.
One contract change you need to action: I added serverTime to the /api/sync response and documented why in SYNC.md. Advancing the cursor to MAX(updatedAt) instead silently skips any row sharing a timestamp with the final row of the final page — serverTime is the snapshot instant that makes the cursor safe. The client tolerates its absence so Phase 2 can be built incrementally, but take it from the database rather than Date.now().
Two notes on scope: I did not wire verifyAgainstManifest() into the automatic path — a ~21.7k-row manifest on every sync isn't warranted, and the ~20% count guard that makes tombstoning safe is still Phase 6 work. And I left main.dart free of ProviderScope nesting by using UncontrolledProviderScope, which is what keeps widget_test.dart (which pumps PharmaZenApp with no container) passing. Nothing is committed yet.

---

Phase 1B — enable soft delete: done, committed but not deployed (backend repo, dcef5e7)
- `medicines.service.js`: `deleteMedicine` is now `updateMany({ where: { id, isDeleted: false }, data: { isDeleted: true } })` plus an unfiltered `findUnique` read-back. Returns the medicine, or `null` for an unknown id (controller turns that into 404). Added `restoreMedicine`, mirrored.
- `POST /api/admin/medicines/:id/restore` in admin.routes.js -> admin.controller.js, delegating to medicines.service so the soft-delete representation still lives in exactly one place. The DELETE itself stays on `/api/medicines/:id` with the other medicine CRUD.
- Cart: `assertMedicineAvailable()` guards `addToCart` and the update branch of `updateCartItemQuantity`. The `quantity <= 0` removal path is deliberately unguarded. Controllers now honour `error.status`, so a stale reference answers 404 instead of 500.
- `prisma/phase1b-cart-reconciliation.sql` — report then delete, in a transaction, `cart_items` only, never `order_items`. STEP 0 must read `soft_deleted_medicines = 0` on a fresh deploy, which is what makes running it immediately safe.
- Verified with a throwaway stubbed-Prisma harness (9 checks: flag flip, both idempotent no-ops, unknown-id 404 both directions, cart reject/accept, unguarded removal). The backend has no test runner (`npm test` is `echo Error: no test specified`), so this is not committed as a suite. Not yet deployed — Phase 2 and 3 remain.

Phase 1B gotchas worth remembering
- **The FK was silently doing the safety work.** `CartItem.medicine` has no `onDelete`, so a hard delete failed for any medicine in a cart or an order — admins could not delete a sold medicine at all. Phase 1A's cart filters were inert at the time, because no cart could reference a deleted medicine. Soft delete removes the FK obstacle, so the filters become load-bearing for the first time — and `addToCart`/`updateCartItemQuantity` needed new guards they did not need before. Anything else relying on a delete *failing* is now suspect; the audit found only these two paths.
- **Idempotency has to live in the `where`, not in a prior read.** `where: { id, isDeleted: false }` is what makes a repeated DELETE match 0 rows instead of bumping `updated_at`, which would manufacture a sync delta for every client on every retry. `@updatedAt` is applied by Prisma even to a no-op `updateMany`, so a guardless repeat is a real write.
- `updateMany` always issues the query, so "did it write?" cannot be inferred from the return value alone — `count` is the only signal.
- Restore had to go under `/api/admin` (per plan) while its service function lives in `medicines.service.js`, so `admin.controller.js` now requires a sibling module. No cycle: medicines.service only requires utils/prisma.
- `payments.service.js:93-115` decrements stock on order payment and is correctly left unfiltered — an order placed before a soft delete must still be fulfillable. Side effect: that write bumps `updated_at`, so a payment on a soft-deleted medicine emits a redundant tombstone delta. Harmless, but it is why the delta stream will not be perfectly quiet.
- `getMedicineById` and the `findUnique` read-backs are intentionally unfiltered so the restore endpoint and the admin edit form can resolve a soft-deleted row. Any *new* admin read that should not see deleted rows must filter.
- Phase 3 (generics CRUD) still carries the same 1A/1B obligation from open item #3 — a soft `isDeleted` on `generics` plus filters on the generic read paths, or medicines keep resolving to hidden generics.
---

Phase 2 — `/api/sync` endpoints: done, committed but not deployed (backend repo)
- New module `src/modules/sync/`: `content_hash.js`, `wire.js`, `cursor.js`, `sync.service.js`, `sync.controller.js`, `sync.routes.js`. Mounted `app.use('/api/sync', syncRoutes)` in `src/app.js`.
- `GET /api/sync?since=&cursor=` returns the raw root object `{nextCursor, serverTime, isFullResync, generics, medicines}` — no `success`/`data` envelope, because `SyncDeltaPage.fromJson` reads the root. `GET /api/sync/manifest` returns a raw `[[id, hash], ...]` array (21,715 pairs, ~1MB), with `ETag` and `If-None-Match` → 304. Both are public and unauthenticated: the catalogue is public data and a device must be able to sync before login, so `express-rate-limit` (240 requests / 5 min, `draft-7` headers, `Retry-After` on 429) is the substitute. The client caps `Retry-After` at 60s over `maxAttempts: 3`, so a throttled device recovers within its budget.
- Two-stage keyset paging: generics drained first, then medicines, both inside one window. Generics-before-medicines is not cosmetic — every medicine page then arrives after its generics, so `GenericResolver` can always resolve `generic_id` against rows already local.
- Config via env with range-checked fallbacks: `SYNC_PAGE_SIZE=500`, `SYNC_SNAPSHOT_LAG_SECONDS=5`, `SYNC_RETENTION_DAYS=30`, `SYNC_MANIFEST_TTL_MS=60000`.
- `prisma/phase2-sync-indexes.sql` adds `(updated_at, id)` on `medicines` and `(updated_at, generic_id)` on `generics`, both `CREATE INDEX IF NOT EXISTS`. **This file must be run against Neon before or with the deploy** — the endpoints are correct without it, just O(window x pages) instead of O(page). `prisma migrate diff` against live Neon emits exactly these two statements with these exact names and nothing else, so schema and SQL agree.

Verified against live Neon (read-only, 21,715 medicines / 1,711 generics) with a throwaway harness — 33 checks, all passing. A full run was 48 pages in ~11s, returned 21,715/21,715 medicines and 1,711/1,711 generics **exactly once each with no duplicates**, `serverTime` byte-identical across all 48 pages, `isFullResync` false throughout, and a follow-up `since=serverTime` came back empty and terminated in 2 requests. Content-hash parity with `sync_manifest.dart` passed 15/15 earlier. HTTP layer checked against a real listener: correct root shape, raw manifest array, 304 with an empty body, malformed cursor → 200, `/api/sync/nope` and `/api/syncX` → 404, and 429 with `Retry-After: 279` after 233 requests. Not deployed; Phase 3 remains.

Phase 2 gotchas worth remembering
- **The two sync tables disagree on their key, in two ways at once.** `Medicine.id` is a UUID and `Generic.genericId` is an INT, so a shared `keyset(state)` helper cannot hardcode the tiebreak field *or* the value type. Both crashed live: `Unknown argument 'id'` on the generics page, then `Expected Int or IntFieldRefInput, provided String` once the field name was fixed. The cursor keeps the id a string in both stages so it has one shape across two key types, and `keyset(state, keyField)` reconstructs the int at query time.
- **express-rate-limit v8 refuses to boot with a raw `req.ip` keyGenerator** (`ERR_ERL_KEY_GEN_IPV6`), which killed the whole server, not just the limiter. v8 folds an IPv6 address to its subnet prefix because one client is handed a whole /64 and could rotate addresses inside it to walk past the limit. Leave `keyGenerator` unset and the default already does the right thing — an explicit `req.ip` is both redundant and a crash.
- **An unsigned cursor can permanently blind a device, so its snapshot needs a bound.** `snapshot` becomes the response `serverTime`, which the client stores as its next `since`; a forged future snapshot means every later run asks for changes after an instant that has not happened yet, matches nothing, and stores another future value in reply — unrecoverable short of a reinstall. `decode()` now rejects a snapshot more than 5 minutes past the app clock. Using the app clock is correct *here* precisely because this is a rejection bound, not a served value; the snapshot a run reports still comes from `readSnapshot()`. The tolerance only has to absorb clock skew.
- A malformed cursor answers 200 and restarts at page 1, never 500 — a 500 would make the client's retry replay the same bad token indefinitely and blame the server for a malformed client request.
- **`since: null` is not `isFullResync`.** SYNC.md defines the flag purely as "the supplied `since` predates retention". A null `since` is already complete state, and flagging it would make every fresh install call `SyncApplier.resetForFullResync()` → `DELETE FROM sync_state` → `bundled_schema_version` wiped for nothing.
- Manifest hashes are computed from the *same* `toMedicineDto` the delta uses, so the two cannot drift; the harness asserts manifest hash === delta hash for the same row rather than trusting that by inspection. Soft-deleted medicines are included so `missingLocally` stays a pure hard-delete signal for Phase 6's ~20% count guard; `isDeleted` is inside the hash, so a device that has not yet seen a delete shows as `mismatched`.
- The composite index is **additive** — the single-column `updated_at` index stays on both tables. I first replaced it on `medicines` and kept it on `generics`, which contradicted the SQL file's own "drops nothing" claim; a composite index's leading column already serves an `updated_at` range scan, but dropping an index other queries may rely on is a separate decision, not something to bundle into Phase 2.
- Keyset paging is written as a Prisma `OR`, not row-wise `(updated_at, id) > ($1, $2)`. Row-wise is the textbook form but means hand-written SQL and a hand-maintained snake_case mapping into the DTOs; with the composite indexes this reaches the same plan, which is why the SQL file carries EXPLAINs to confirm the planner agrees.
- Generics drain to a medicines-stage cursor even when no medicines changed — one extra round trip, but it avoids a second "is anything left?" `count()` over the same window.
- `api/index.js` only exports the app and binds no port, so nothing can be curled without a listener; and `vercel.json`'s `"/(.*)" -> api/index.js` catch-all is what makes `/api/sync` reach Express at all. Worth re-reading both before debugging a deploy that 404s.
