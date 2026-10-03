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
- ~~Guard deletions: only tombstone after a *complete* manifest whose row count is within
  ~20% of `last_manifest_count`.~~ Done — `SyncDriftReport.isManifestTrustworthy`.
- ~~Never bulk-delete. Tombstone individually.~~ Done — `SyncApplier.tombstoneMissingLocally`.
- ~~Handle `isFullResync` by wiping sync state and rebuilding from scratch.~~ Done, and it
  was **wrong as written** — see the phase log below.
- Stub `generics` rows have NULL `indication`, and `allValues` uses
  `SELECT DISTINCT ... WHERE column IS NOT NULL` (`medicine_repository.dart:60-65`), so they
  stay out of indication browse. But `app_metadata.descriptions_count` drifts — nothing
  reads it today.

---

## Phase 7 — Prescription gate + Cloudinary hardening (backend)

`is_sensitive` was added in Phase 1A as a sync column, and it has quietly become the
source of truth for everything that matters: `MEDICINE_SELECT` (`sync/wire.js`) ships
`isSensitive` and *not* `requiresPrescription`, `content_hash.js:102` hashes `isSensitive`
and *not* `requiresPrescription`, and the app holds zero references to
`requires_prescription`. `requires_prescription` is a legacy duplicate that only the
backend and the React frontend still read.

Measured across all 21,715 live medicines, the two columns are identical — 21,624 false /
91 true, zero divergence. So moving the gate is behavior-preserving, and because no
content hash changes, **no device resyncs** and the 17.1MB bundled asset stays valid.

### Unify the gate on `is_sensitive`, then drop the column later

Sites to switch to `isSensitive`: `cart.service.js:27,50`,
`medicines.service.js:55-57,177,229,251`, `medicines.controller.js:18`,
`orders.service.js:28,37,106`, plus `AdminDashboard`, `MedicineCard` and `CheckoutPage`
in the React frontend.

**The drop is split across three deploys on purpose.** `MedicineCard.jsx:10,116`
destructures `requiresPrescription` to render the restricted badge and `CheckoutPage`
depends on `item.requiresPrescription` from `cart.service.js:50`. Dropping the field out
of the API response before the frontend is updated would silently remove every badge on
the live website — a regression that is invisible in tests and obvious to customers. So:

1. Backend serves **both** `isSensitive` (authoritative) and `requiresPrescription`
   (derived from it), and gates internally on `isSensitive`. Website unaffected.
2. Frontend reads `isSensitive`, still falling back to `requiresPrescription`.
3. Only after the frontend deploy is verified does the column actually drop, along with
   the derived alias.

Steps 1 and 2 are safe in either deploy order; step 3 is not, which is why it is separate.

### The real upload limit is 4.5MB for the whole request, not per file

`prescriptions.routes.js` allows 10MB × 4 files = 40MB, buffered by
`multer.memoryStorage`. Probing the deployed backend:

```
1MB   -> 401   (request reached the app)
3MB   -> 401
4MB   -> 401
4.5MB -> 413   (rejected at the edge, app never runs)
12MB  -> 413
```

Vercel caps the **entire multipart body**, so the existing contract is unreachable by a
wide margin — even four 1MB files overflow it. This is why compression is not a
nice-to-have but the thing that makes upload possible at all: a 12MP phone photo is
3-8MB, and resized to ~1600px at JPEG q80 it is 200-400KB.

- Size the multer cap to fit inside the measured envelope including multipart overhead.
- Add a `PayloadTooLargeError` handler returning a clear 413 instead of a generic 500.
- `PrescriptionUploadPage.jsx` compresses client-side before upload.

### Cloudinary assets currently leak on every partial failure

`prescriptions.controller.js:36` uploads with `Promise.all` and writes the DB row
afterwards. If file 3 of 4 fails, files 1-2 are already in Cloudinary with no DB row
pointing at them. If the `prisma.prescription.create` then fails, *every* uploaded file
is orphaned. `cloudinary_public_id` is stored on every row and never read — which is the
only reason to store it.

- Sequential upload with compensating `destroy()` on any later failure, DB write included.
- A delete endpoint that actually uses the stored `cloudinary_public_id`.
- Cleanup wired into user deletion; `onDelete: Cascade` removes DB rows today while the
  Cloudinary originals survive forever.
- Uploads switched to `access_mode: 'authenticated'`.

### Prescription images stop being public URLs

`secure_url` is unauthenticated and permanent, and `orders.service.js:207` echoes a raw
`fileUrl` into the order response. These are scans of medical documents, reachable by
anyone who ever holds the link.

- New authenticated endpoint returning a short-lived signed URL, scoped to the prescription
  owner or a pharmacist/admin.
- Stop emitting raw `secure_url` in prescription and order payloads.
- Migrate the 17 existing files to authenticated access mode. Production is not empty —
  there are 10 prescriptions / 17 files today (5 approved, 3 pending, 2 rejected), so this
  is a one-way migration on live assets: any link already shared with a pharmacist stops
  resolving. Accepted.

### Stop trusting the client

- Validate `medicineId` exists and is actually sensitive;
  `PrescriptionUploadPage.jsx:176` sends `medicineName` and the backend stores it verbatim.
- Derive `medicineName` server-side.
- Validate `endDate >= startDate`.

### Phase 7b — prescription dispensing limits

The gate above asks only "is there an approved, in-date prescription?". It never asks
how much of it was already used, so one approval authorised **unlimited** repeat orders
for the whole date range. That is not hypothetical: of the 5 approved prescriptions in
production, one authorised 4 orders and another 2.

An approval is now a budget rather than a boolean.

**Units, not orders.** A prescription is a course of treatment ("1 tab twice daily × 30
days" = 60 tablets) and a patient may legitimately split that across several orders, so
counting orders would either block legitimate refills or bound nothing. Capping units
bounds the order count implicitly, since every order needs at least one unit.

- `prescriptions.max_quantity` — what the pharmacist authorises on approval.
- `prescriptions.consumed_quantity` — dispensed so far.
- `order_items.prescription_id` — which prescription authorised each line.

**One enforcement point, so this cannot be app-only.** `createOrderFromCart` has exactly
one caller (`orders.controller.js:7` → `POST /api/orders`), shared by the website and the
app. Forking the rule so only the app honoured a limit would mean two contradictory
compliance answers to the same account data, decided by which client the patient happened
to use. The limit therefore lives in the shared backend and applies to both — and the
website is not "broken" by it, it simply starts honouring the rule it always meant to.

**The reservation is atomic.** Reading `consumed_quantity` and writing `+ n` would let
two simultaneous checkouts both pass the check and together overshoot. `reserveUnits`
instead issues one conditional UPDATE with the capacity test in the `WHERE` clause, so
the database re-evaluates it against the committed row and the loser claims 0 rows.
Verified on a scratch Postgres: 10 concurrent reservations of 2 units against a limit of
10 yielded exactly 5 successes and consumed exactly 10.

Reservations happen inside the same transaction as the order insert, so a failed order
rolls back the allowance instead of silently burning it. `cancelOrder` releases the units
via the line-level `prescription_id`, and its status flip is a conditional `updateMany`
so two concurrent cancels cannot both refund.

**The default cannot break anyone.** All 10 prescriptions in production have
`end_date < now()`, so none can authorise an order today and none is touched by the
backfill. `DEFAULT_AUTHORIZED_QUANTITY` is 5 — deliberately equal to the existing
per-order `MAX_QUANTITY`, so "no figure stated" means one cart's worth rather than an
arbitrary number. The backfill records real pre-existing over-use in `consumed_quantity`
rather than resetting it to 0, which can leave `consumed > max` on historical rows; the
API clamps `remaining` at 0 rather than showing a negative.

**Rejected checkouts now answer 409, not 500.** Both prescription rejections carry
`error.status`. A routine business refusal was reporting as a server outage in error
monitoring. Safe to change because `CheckoutPage.jsx:59` branches on
`result.message.includes('prescription')` and never reads the HTTP status — so the warning
banner is unchanged, and both messages deliberately keep the word "prescription".

### Deliberately not in this phase

`orders.service.js:57` assigns `prescriptionId` inside a loop over restricted medicines,
so an order containing several restricted medicines records only the *last* prescription.
`Order.prescriptionId` is a single FK, so the audit trail is incomplete. Fixing it needs
an order↔prescription join table, a Prisma model, and changes to three order response
shapes — real breakage risk for the SDP-I website, and cart is explicitly out of scope for
now. **Deferred to its own phase**, with the `requires_prescription` drop, once both can be
verified against the deployed website.

---

## Phase 8 — Prescription upload in the app (online-only)

The app is a read-only offline catalogue today: `lib/features/` holds only `browse`,
`home` and `medicines`, and `sync_api_client.dart:26` documents that the sync endpoints
need no auth. Prescription upload is the first authenticated write, so it brings a login
subsystem with it.

### New dependencies

`image_picker`, `image` (resize/encode), `flutter_secure_storage`. Everything else needed
is already present — `dio`, `flutter_riverpod`, `go_router`, `connectivity_plus`.

### Auth

Reuse `/api/auth/login` + `/refresh` + `/me`; the app does not get its own account system.
Access tokens expire in **15 minutes** (`utils/jwt.js:11`), so a Dio interceptor must
attach the access token and refresh transparently on 401 — without that, a slow
prescription flow fails mid-way for reasons that look like network errors.

Tokens go in `flutter_secure_storage`, never `shared_preferences`.

### Online-only by design

`connectivity_plus` gates the upload with an explicit offline message rather than a
timeout. Picking the medicine still works offline: the local SQLite copy already carries
`is_sensitive`, so the restricted list can be rendered with no network at all. Only the
upload itself requires connectivity.

### The screen

Capture or pick → compress → choose a medicine from local SQLite where
`is_sensitive = 1` → start/end dates → multipart POST to `/api/prescriptions`. One
prescription per upload, matching the existing schema and the pharmacist review flow.

Plus a "my prescriptions" list showing review status, and `go_router` + Riverpod
wiring with tests for the compression step and the multipart payload shape.

---

## Execution order

**Pre-flight → Phase 1A → Phase 4 → Phase 5 → Phase 1B → Phase 2 → Phase 3**

Phases 7 and 8 come after Phase 6 and are independent of it — the sync pipeline is done,
so they no longer interact. Within Phase 7 the order is load-bearing: compression and the
size cap first (nothing uploads otherwise), then orphan cleanup, then signed URLs, and the
`requires_prescription` drop last and only after the frontend deploy is verified.

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

---

Phase 3 — Admin CRUD for generics: done, committed but not deployed (backend repo)
- New `src/modules/generics/{routes,controller,service}.js`, mounted at `/api/generics`, every route behind `authenticate, authorize('admin')` per-route in the admin.routes.js style. `GET /` (search / drugClass / indication filters, pagination, `includeDeleted`), `GET /:id`, `POST /`, `PUT /:id`, `DELETE /:id` (soft). Restore went to `POST /api/admin/generics/:id/restore`, mirroring Phase 1B's medicine restore, so there is still one place per resource that knows how its soft delete is represented.
- Admin-only reads, deliberately: no public consumer exists — the React frontend derives generic names out of the denormalised `medicine.description` string, and the app gets generics from `/api/sync`. Keeping the surface closed means a soft-deleted generic has no anonymous reader to leak to.
- `prisma/phase3-generics-autoincrement.sql` adds a sequence and a DEFAULT on `generics.generic_id`, so an admin creating a generic does not hand-pick a unique integer. **Run it before deploying Phase 3.** No schema work was needed for the soft delete itself: `is_deleted` and `updated_at` already exist from Phase 1A.
- Verified with a throwaway stubbed-Prisma harness (30 checks, in-memory, nothing written to Neon) plus read-only live probes through a real listener with a signed JWT. The harness covers soft-delete flag flip, idempotent repeat delete/restore writing *nothing* (no phantom `updated_at` delta), unknown-id nulls, count recomputation, and the unique-name 409. The live probes covered the auth gate (401 no token / 403 customer on list, create, delete and restore), list total agreeing with Neon at 1,711, search, paging, and every error path (`/abc`, `/1.5`, `/0`, `/999999` → 400/400/400/404; POST with no name → 400; PUT/DELETE/restore unknown → 404). Neon was re-checked afterwards: 1,711 generics, 0 soft-deleted, so nothing leaked in.

Phase 3 gotchas worth remembering
- **Prisma's generated migration for this change is silently wrong for a table that already has data.** `migrate diff` emits exactly three statements and stops — sequence, column DEFAULT, `OWNED BY` — with **no `setval`**. Ids currently run 3..2072, so an unseeded sequence hands out 1, 2, **3**: the first two creates are fine and the third collides on an existing id. That surfaces as a duplicate-key error on the third insert and reads like a data bug, not a migration bug. The SQL file adds the `setval(..., false)` line and says so explicitly, so do not let anyone regenerate that file from Prisma alone.
- **`descriptions_count` is a denormalised counter that nothing in the codebase computes**, so it has to be recomputed on every generic write or it goes stale. It came from the legacy source SQLite via `seed-sync-source.js`, which copied the value verbatim. Verified against Neon that it *is* derivable: all 1,711 rows satisfy `descriptions_count = (count of populated description columns)`, spanning 1..15. Staleness would not be cosmetic — it is one of the six identity fields in `computeGenericHash`, so a generic whose text was edited but whose count was not ships a hash that does not describe its own content and every device flags it as mismatched forever. Same obligation as open item #2 for `medicines.description`.
- The service counts **non-blank** (trimmed) while the SQL derivation that produced the stored values counts non-empty. They differ only for whitespace-only text, of which the table currently holds zero, so the stricter rule reproduces all 1,711 stored counts exactly. Worth re-checking if a bulk edit ever writes `' '`.
- A partial update must count against the **merged** row, not just the edited columns, or clearing one description silently recounts the other fourteen as absent. `buildData(body, existing)` copies the untouched description columns across before counting.
- Update distinguishes *absent* from *cleared*: absent leaves a column alone, an explicit `null` or `""` clears it (blank normalises to null so the column does not store `""`).
- **`genericName` is `@unique` and the flag does not free the value**, so a soft-deleted generic still blocks its own name — creating a replacement answers 409, not 500, with a message that says the name may be held by a deleted row. Prisma tags this P2002; the service maps it to `error.status = 409`, reusing the cart controller's `error.status` convention. This is the first place in the backend that maps a Prisma error code rather than letting it become a 500.
- The reason generics must be soft-deleted is sharper than for medicines: `medicines.generic_id` is `ON DELETE SET NULL`, so a **hard** delete would quietly null the FK on every medicine pointing at it. No medicine row changes, so no medicine delta is emitted, and every device's `GenericResolver.resolveId` would find `generic_id = ?` missing and fall through to a negative stub id. Soft delete is load-bearing, not preference.
- `genericId` needed a `:id` parse in two places — the controller and the admin restore handler, because the admin module has no shared param helper. Unvalidated it reaches Prisma as a string and returns P2025, which the catch-all would report as a 500; `parseId` makes it a 400.

Open item #3 is now only half closed — and the remaining half is on the client
- Done server-side: generics have admin CRUD, a soft delete, a restore, and the read paths filter `isDeleted`. `sync.service.js:158-168` stays deliberately **unfiltered**, mirroring the medicine tombstone argument: the flag is the change signal, it rides to the device inside `GENERIC_SELECT`/`toGenericDto`, and `isDeleted` is the last field of `computeGenericHash`.
- **Still open, and it means a soft-deleted generic is currently invisible to devices.** The local `generics` table has no `is_deleted` column — only `medicines` got one in `tool/phase4_asset_migration.sql` — so `GenericResolver._upsert` has nowhere to write the flag and drops it. And `resolveId` selects from `generics` with no tombstone filter in either of its two lookups. So this phase's stated goal is not yet observable on a phone: deleting a generic hides it from the admin list and from nothing else.
- Deferred on purpose (agreed): doing it properly means adding `is_deleted` to the local `generics` table, bumping the bundled schema version and migrating the tracked asset, writing the flag in `_upsert`, and filtering it in `resolveId`. The Phase 4 notes warn that a bundled-schema-version bump can wipe `app_metadata`, so that deserves its own phase rather than riding along with admin CRUD.

---

## Phase 6 log

The drift check that Phase 5 deliberately left unwired is now wired, and turning it on
exposed a bug in the full-resync path that had never been exercised.

### The `isFullResync` path duplicated the entire catalogue

`SyncApplier.resetForFullResync` nulled `remote_id` and `content_hash` on every row before
the replay. That is exactly what makes `applyMedicines` take its INSERT branch: `knownRowsExist`
is false when no row carries a `remote_id`, so every replayed row is treated as new. A
retention-cutoff resync of the 21,715-row catalogue would have left 21,715 bundled rows beside
21,715 freshly inserted ones.

Confirmed rather than reasoned about: a throwaway test asserted one row after
`resetForFullResync()` plus a replay of the same row, and got two. The pre-existing test
`full resync clears only the sync bookkeeping` did not catch it because its replay sent a
*different* `remoteId` — which inserts either way — so the count came out at 3 under both the
old and the new behaviour.

The fix is to keep `remote_id` and `content_hash` and clear only `sync_state.last_success_at`,
which is what actually drives a `?since=` delta. A full resync then becomes "rewrite the rows
that differ": the hash comparison in `applyMedicines` skips everything already correct, so a
healthy catalogue pays 48 pages and zero writes. The old test name is now wrong and says so.

`last_manifest_count` and `bundled_schema_version` survive too. The first describes the
server's catalogue size, which a client-side replay does not change, and the second gates
re-seeding rather than fetching.

### A mismatched row cannot be repaired by clearing its hash

`mismatched` rows are present on both sides with different content. The obvious repair —
null `content_hash` so the next sync rewrites the row — does not work, because the delta is
driven by `updatedAt > since`, not by hash. A row whose server `updatedAt` is already at or
before our cursor is simply never sent again, so it stays wrong for the life of the install.

Repair therefore drops the cursor instead, which replays the catalogue. Combined with hashes
being preserved, the replay rewrites exactly the drifted rows and skips the rest. Agreed with
the user as the repair policy for this phase.

### The guard

`isManifestTrustworthy` is what gates every tombstone, and it rejects:

- an empty body that is not a `304` — the catalogue came back with nothing in it;
- a manifest with no established baseline. The first check records `last_manifest_count` and
  stops. Tombstoning against a manifest nothing has vouched for would make the very first
  check the riskiest one;
- a body more than `ApiConfig.manifestRowTolerance` (20%) away from the baseline. The
  boundary is inclusive: exactly 20% lost is catalogue churn, not truncation.

A `304` short-circuits in `verifyAgainstManifest` *before* any comparison. Without that, an
empty body reads as "the server has no rows", every local row is flagged, and
`isManifestTrustworthy` returns true for a 304 — the one path that would have tombstoned the
whole catalogue.

The reference for the tolerance is the previous accepted count, not the local count. The local
count is precisely what a truncated manifest would corrupt.

### Already-tombstoned rows are excluded from the report

A row tombstoned by an earlier check is absent from the manifest on every subsequent run, so
counting it again would grow `missingLocally` forever and retry work that already landed. The
report skips rows where `is_deleted != 0`, which also makes repair idempotent.

### Cadence

`last_manifest_at` is a new `sync_state` key checked against
`ApiConfig.manifestInterval` (24h) after each successful delta. It is deliberately **not**
keyed off `last_success_at`: that is in server time and jumps backwards on clock skew, while
the manifest interval is a client-side pacing decision. A `304` refreshes the timestamp but
leaves `last_manifest_count` alone, since a response with no rows says nothing about how many
there are.

Adding the key needed no schema-version bump. `ensureSchema` already inserts any
`sync_state` key missing from an installed file, and the bundled asset is unchanged — the
file gains a row, not a column. Pinned by
`ensureSchema adds a newly introduced key to an already-installed catalog`, which also asserts
the pre-existing keys survive intact, since a clobbered `last_success_at` would resend the
whole catalogue.

The repair runs after `_writeCursor`, so it compares the catalogue the delta just finished
updating, and inside a `try` that swallows everything: the delta's work is already durable
and correct, so a repair failure must not be reported as a failed sync.

### Test fixture change

`_FakeAdapter` routes `/sync/manifest` by path instead of drawing from its ordered response
list. Without that, the engine's daily check consumed the next delta page and four unrelated
tests broke on request counts. `deltaRequests` filters the manifest out for sync-paging
assertions.

### The bundled asset shipped one key behind, and a test could not have noticed

Adding `last_manifest_at` to `kSyncStateKeys` left `assets/database/medicines.db` — which
is a tracked binary generated by `tool/phase4_asset_migration.sql` — still carrying only the
old three keys. That is worse than a stale artefact, because it turns opening the asset into
a write: `AppDatabase.ensureSchema` runs in `beforeOpen` on every connection, sees the key
missing, and inserts it. Any test opening the asset through `AppDatabase` — `browse_screen_test`
and `medicine_repository_test` both did — therefore rewrote the shipped 17MB file, and
`git status` showed a modified binary after a test run.

It stayed latent until now only because the asset happened to be exactly in step with
`kSyncStateKeys`. The rule is that every key in `kSyncStateKeys` must appear in the migration
script; a key that exists only in Dart makes every asset open a write.

Fixed at the source rather than papered over in the tests: the migration script now seeds
`last_manifest_at`, and the asset carries it. Adding the key is a single-row `INSERT OR IGNORE`
— `medicines` (21,715 rows), `generics`, `app_metadata`, `user_version` and
`PRAGMA integrity_check` are all unchanged, so no schema-version bump is involved and
`app_metadata` is untouched. `medicine_repository_test` was also moved onto a temp copy.

The test that should have caught this could not. `ships sync_state seeded with the expected
keys` opened the asset through `withAssetCopy`, which wraps it in an `AppDatabase` — so
`ensureSchema` inserted the missing key *before* the assertion ran, and the test passed
against an asset that genuinely lacked it. Both `bundled asset` tests now go through
`withUnmigratedAssetCopy`, which opens a copy through `_FixtureDatabase` and so has no
`beforeOpen` hook to repair the file first. Verified by deleting `last_manifest_at` from the
asset and watching the test fail.

### Verification

flutter analyze clean, 80 tests passing (13 new). Not yet committed.

## Phase 8 log

The first authenticated write in the app. Reading the endpoints before writing the UI changed
the shape of the work twice, and one test caught a bug that would have shipped.

### Dio has no cookie jar, so the refresh token was unreachable

The backend issues the refresh token as an httpOnly cookie and never in the response body —
correct for a browser, wrong for Dart, which has nowhere to put it. Dio does not persist
cookies on its own: without a jar, `POST /api/auth/refresh` finds no credential, every 15
minutes the session dies mid-request, and the app bounces to login for no visible reason.

This is the same class of defect that produced the website's 401s, and it was designed in
rather than discovered later: `PersistCookieJar` sits behind `CookieManager` on both the main
and the refresh Dio. The refresh call runs on a *separate* Dio with no auth interceptor, so a
401 from refresh itself cannot recurse into another refresh.

Concurrent refreshes are collapsed into one in-flight future. Rotation is the reason: a
second parallel refresh would try to redeem a token the first had already rotated away, and
log the user out for it.

### This is a medication request, not a file drop

`POST /api/prescriptions` requires `medicineId`, `startDate` and `endDate` alongside the
files — a pharmacist reviews the medicine against the script, so the pair is the unit. The
form is medicine → date window → attachment, not a camera button.

Two consequences that are easy to get wrong:

* `medicineId` is a `@db.Uuid`. The local catalogue is integer-keyed, so the app cannot send
  `brand_id`. `remote_id` is the Neon UUID (already synced), but `Medicine` never exposed it —
  added to the model and to all four `SELECT` lists in `medicine_repository.dart`. A medicine
  with no `remote_id` is refused with "run a sync", rather than sending an id the server
  cannot resolve.
* `startDate`/`endDate` are `@db.Date`. They are sent as `YYYY-MM-DD`, not timestamps, so a
  user west of UTC does not get the course start shifted by a day.

### The test caught the same bug I had criticised on the website

The first `prepare()` stepped JPEG quality down to 40 and then threw
"still too large after compression". A noise-image fixture — dense, detail-heavy, the shape
of a real camera-roll photo — proved that path fails, so precisely the files this feature
exists for would have been rejected.

Compression now shrinks geometrically when quality bottoms out (2000px → ~630px over four
passes). A prescription is legible at 1200px, so trading resolution for an accepted upload is
the right trade, and it is the opposite of the website's "reject anything over 2MB".

Compression runs *before* the size check, never after, which is why the 2MB limit is a check
on the encode rather than a gate on selection.

### Three packages moved under me

* `flutter_secure_storage` 11 dropped `encryptedSharedPreferences`; AES-GCM storage with an
  RSA key cipher is now the default, and `resetOnError` handles a corrupt entry.
* `image_picker` 1.2 removed `pickFile`/`FileType`, and `pickMedia` cannot filter by media
  type — so PDFs come from `file_selector` instead.
* `dio` 5.11 types `contentType` as `DioMediaType`, not `String`.

So six packages were added, not the three planned: `image_picker`, `image`,
`flutter_secure_storage`, `dio_cookie_manager`, `cookie_jar`, `file_selector`.

### The gate sits in `MaterialApp.builder`, and that has a cost

`appRouter` is a global with no `ref`, so a `redirect` cannot watch auth without a
`refreshListenable` bridge — more machinery than one condition deserves. The gate is a
`builder` that returns the login screen or the router's child.

Because the signed-out branch *replaces* the Navigator, there is no Overlay for a `Tooltip` to
render into, and the password-visibility button threw on first pump. It uses `Semantics` now,
which is the better fit for a screen-reader label anyway.

`AuthUnknown` is a distinct third state from `AuthSignedOut`: waiting for `restoreSession`
avoids flashing the login form on every cold start.

### Errors arrive under two different keys

The auth controller answers `{ message }`; the prescriptions controller answers `{ error }`.
Both are read, so the server's own wording reaches the UI instead of a generic string.

Note the auth controller returns **401 for every login failure**, including a genuine server
fault. Rendering that as "wrong password" would blame the user for an outage.

### Two deliberate departures from the plan above

* The screen searches **all** medicines, not only `is_sensitive = 1`. The endpoint does not
  restrict which medicines may carry a prescription, and a user legitimately needs to attach a
  script for a medicine they already order. Gating the picker to restricted medicines would
  block valid uploads.
* The planned `connectivity_plus` gate is **not** wired. Without it the failure surfaces as an
  upload error, which is worse but not wrong; it is the first thing to add.

### The login response token was thrown away

The first run of the app could not get past the sign-in screen, and the cause was mine.
`AuthApiClient.login` received the access token, checked it was non-empty, and returned the
user without storing it. `writeAccessToken` existed in exactly one place — inside
`_performRefresh` — so `TokenStore` stayed empty after a perfectly good login.

The consequence is not obvious from the symptom. Sign-in *succeeded*: the gate saw
`AuthSignedIn` and let you through. It was every request afterwards that was anonymous,
because `_onRequest` builds the `Authorization` header by reading the token back out of
`TokenStore` and found nothing there. The app recovered only if some later call happened to
401 and stumble into the refresh path, which is why it looked intermittent rather than
broken.

Introduced by the refactor that moved the Dio into a shared `ApiClient`: `login` used to write
the token itself and stopped doing so when the writer became private to the other class. The
code that lost the call is code that still compiles, still returns the right type, and still
passes every test that was written before it — which is the whole argument for the tests
below.

The fix is `ApiClient.adoptAccessToken`, called from `login`. `auth_session_test.dart` covers
it, and the coverage is deliberately behavioural rather than structural: it asserts the token
is readable from the store afterwards, and that a subsequent request carries
`Authorization: Bearer the-access-token`. Verified by reverting the one line and watching two
of them fail, so they are not passing by accident.

Worth recording: the temporary bypass offered while diagnosing this was not needed. The
symptom pointed at "the sign in page does not connect with the server", but `curl` against
`/api/auth/login` answered `401 {"error":"Invalid email or password"}` in ~2s — the network was
never the problem. Checking the server before rewriting the client is what turned a guess into
a one-line fix.

### Sign-in never sent a request, and the message blamed the network

The next symptom was the one the fix above could not explain: **no account could sign in at
all**, correct password or not, and the banner read "Could not reach the server. Check your
connection." The Phase 8 cookie jar was the cause, and it is worth spelling out because
`cookie_jar`'s default is quietly unusable on Android.

`PersistCookieJar()` takes its storage as a constructor argument. Left unset — which is what
`ApiClient` did — `FileStorage` falls back to the *relative* path `.cookies/4/ie0_ps1/`, and
`Directory.current` for an Android process is `/`, which is read-only. Reproduced outside the
app, from a read-only working directory:

```
cwd: /tmp/opencode/ro
loadForRequest THREW: PathAccessException: Creation failed, path = '.cookies' (OS Error: Permission denied, errno = 13)
```

`loadForRequest` is what `CookieManager.onRequest` calls *before every request*, so the throw
happened for all of them, and `CookieManager` reports a failed storage as a failed request.
Nothing was ever sent, and the app had no way to say so. This is the same design-in defect as
the missing jar in the section above: the code compiles, the type is right, and the tests pass
because `CookieManager` is not in the path a stubbed adapter exercises.

The fix is `AppCookieStorage`, a `Storage` that resolves `getApplicationSupportDirectory()` and
hands it to `FileStorage`. `path_provider` answers asynchronously and `FileStorage`'s path
cannot, so the directory is resolved in `init` — the one storage method the jar already awaits
before touching the filesystem — which keeps `ApiClient` constructible synchronously. Where no
directory can be created the storage degrades to a map: the session then ends at restart
instead of every request failing, which is the recoverable half of that trade.

### `validateStatus` had made every server rejection look like an outage

Fixing the storage is what made sign-in work; it did not explain the message. `baseOptions`
sets `validateStatus` to 2xx-only so that a 401 reaches `_onError` and can be refreshed — and
Dio therefore *throws* `DioException.badResponse` for a 401 before `AuthApiClient.login` reaches
its own `if (response.statusCode != 200)`. That branch was unreachable, and worse, Dio discards
the error body unless `receiveDataWhenStatusError` is set, so `{"message":"Invalid email or
password"}` never reached the screen. `login_screen`'s generic `catch` then rendered "Could not
reach the server" for a rejected password, a rejected file type, and a 500 alike.

The comment above `validateStatus` claimed the opposite ("so callers can read the server's own
message"), which is the kind of comment that survives review because it is not checked against
the library. Fixed at both ends:

* `receiveDataWhenStatusError: true`, so the body is on `error.response.data` — the comment now
  says why it is there;
* the Dio → domain conversion moved to where the distinction is actually known.
  `ApiClient.serverMessageOf` / `ApiClient.wasAnswered` answer two questions — did a server say
  anything, and what did it say — and `AuthApiClient.login`, `PrescriptionApiClient.upload` and
  `listMine` word the result. "Could not reach the server" is now reachable only when nothing
  answered at all; each screen's fallback catches an unparseable reply instead and says so.

`ApiClient.baseOptions()` became public for this. `validateStatus` decides whether a rejection
arrives as a response or an exception, so the auth tests had to build their Dio from the app's
own options — on Dio's defaults they were testing a configuration the app never runs.

### Not verified

No request has been sent to the live API. Response shapes and status codes were read from
backend source, not observed, so a wrong assumption here is entirely possible. Untested:

* the real multipart round trip, including Cloudinary accepting the compressed bytes;
* cookie persistence across an app restart, and refresh-on-401 in practice;
* **two-file uploads.** Two 1.8MB encodes plus multipart overhead is ~3.6MB against the ~4.5MB
  Vercel ceiling — probably fine, genuinely untested, and the first thing to check;
* a sign-in against a real account. `curl` confirms the endpoint answers
  `401 {"success":false,"message":"Invalid email or password"}` in ~2s from this machine, so the
  URL and the deployed route are right, but nothing has exercised the success path end to end —
  the `Set-Cookie` the jar is now able to persist has only ever come from a stub.

### Verification

`flutter analyze` clean, 104 tests passing (24 new since Phase 7: 11 compression and DTO parsing,
1 signed-out gate, 5 session/Bearer, 7 sign-in and cookie storage). `flutter build apk --debug`
succeeds.

* `cookie_storage_test.dart` — a jar over `AppCookieStorage` keeps cookies across a *restart*
  (a second jar over the same directory, nothing carried in memory), because that is the only
  copy of the refresh token; a directory that cannot be created does not fail `loadForRequest`;
  a `path_provider` that cannot answer degrades to memory instead of throwing.
* `auth_session_test.dart` — sign-in completes and the refresh cookie lands in the injected
  directory, with only the *storage* injected so the jar under test is the app's own
  composition; a 401 surfaces "Invalid email or password" with status 401 and stores no token;
  a request that never left the device and one that was rejected are worded differently.

Not passing by accident, both checked by reverting:

* putting `PersistCookieJar()` back as the default fails *persists the refresh cookie in the
  directory it was given* — no file appears, because the storage it was handed is ignored;
* restoring the old `login` — status check, no catch — fails both wording tests, one because a
  `DioException` escapes instead of an `AuthException`, one because the connection message is
  not the one the screen now depends on.

The login round trip is still unverified against a live account — the tests drive a stubbed
adapter, not Vercel. What they establish is that the token is stored and attached, which was the
first defect, and that a request actually leaves the device, which was the second.

The unrelated `browse_screen.dart` work and `test/browse_screen_test.dart` remain uncommitted
and untouched.
