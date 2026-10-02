-- Phase 4 — Flutter local schema.
--
-- One-time migration of assets/database/medicines.db so that first-run installs
-- receive the sync columns. Devices that already have a copy are upgraded by the
-- version-gated re-seed in lib/data/db/app_database.dart, not by this file.
--
-- This is the "asset" twin of ensureSchema() in app_database.dart. That function
-- is the idempotent runtime version (it guards every ADD COLUMN); this script is
-- the one-shot version for the known pre-Phase-4 state, where none of the columns
-- or the table exist. test/app_database_test.dart asserts the two agree.
--
-- Verify prerequisites first (expected: 0 and no such table):
--   sqlite3 assets/database/medicines.db \
--     "SELECT COUNT(*) FROM pragma_table_info('medicines')
--       WHERE name IN ('remote_id','content_hash','synced_at','is_deleted');"
--   sqlite3 assets/database/medicines.db \
--     "SELECT COUNT(*) FROM sqlite_master WHERE name='sync_state';"

PRAGMA foreign_keys = OFF;
BEGIN IMMEDIATE;

-- Sync bookkeeping. Phase 5 writes last_success_at only after the final batch
-- commits, so a crash mid-sync leaves the cursor untouched and the run repeats
-- safely. Both columns are nullable precisely so that "never synced" and
-- "synced, count unknown" are both representable without a sentinel.
--
-- Every key in kSyncStateKeys (app_database.dart) must appear here. A key that
-- only exists in Dart leaves the bundled asset behind kSyncStateKeys, and
-- AppDatabase.ensureSchema then writes to the shipped file on every open --
-- including when a test opens it directly, which shows up as a modified 17MB
-- binary in git status.
CREATE TABLE IF NOT EXISTS sync_state (
  key TEXT PRIMARY KEY,
  value TEXT,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT OR IGNORE INTO sync_state (key, value, updated_at)
  VALUES ('bundled_schema_version', '2', CURRENT_TIMESTAMP);
INSERT OR IGNORE INTO sync_state (key, value, updated_at)
  VALUES ('last_success_at', NULL, CURRENT_TIMESTAMP);
INSERT OR IGNORE INTO sync_state (key, value, updated_at)
  VALUES ('last_manifest_count', NULL, CURRENT_TIMESTAMP);
-- Phase 6: when the daily drift check last ran. NULL until then.
INSERT OR IGNORE INTO sync_state (key, value, updated_at)
  VALUES ('last_manifest_at', NULL, CURRENT_TIMESTAMP);

-- Local identity bridge + change detection for Phase 2/3.
--   remote_id      server-side Medicine.id (uuid); the sync upsert key
--   content_hash   manifest hash, so unchanged rows skip the write
--   synced_at      when this row last agreed with the server
--   is_deleted     tombstone; inert until Phase 1B lands (0 on every row now)
ALTER TABLE medicines ADD COLUMN remote_id TEXT;
ALTER TABLE medicines ADD COLUMN content_hash TEXT;
ALTER TABLE medicines ADD COLUMN synced_at TEXT;
ALTER TABLE medicines ADD COLUMN is_deleted INTEGER DEFAULT 0;

-- Stamp the file as the bundled generation so the device gate in
-- app_database.dart treats it as current and leaves it alone.
UPDATE app_metadata SET value = '2.0', updated_at = CURRENT_TIMESTAMP
  WHERE key = 'database_version';

COMMIT;

-- Must match kBundledSchemaVersion in app_database.dart, otherwise drift will
-- try to run a migration on every open of this file.
PRAGMA user_version = 2;

-- Reclaim the ~17MB of free pages the new columns left behind rather than
-- shipping a bloated asset. VACUUM cannot run inside a transaction.
VACUUM;