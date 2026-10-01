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
  `{ nextCursor, isFullResync, medicines[], generics[] }`, page-bounded.
  `vercel.json` declares no `maxDuration`, so page size must stay conservative.
- `GET /api/sync/manifest` → `[[remoteId, hash], …]`, used only for repair/drift detection.
- Public, no auth. Rate-limited, ETag on the manifest.
- `isFullResync: true` when the supplied `since` predates the server's retention window.

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

**Triggers.** Post-first-frame on cold start, debounced on connectivity regained, and
manual pull-to-refresh — all behind a single-flight mutex and a 15-minute minimum interval.

---

## Phase 6 — Hardening

- Add `<uses-permission android:name="android.permission.INTERNET"/>` to
  `android/app/src/main/AndroidManifest.xml`. It is absent today; every request fails without it.
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