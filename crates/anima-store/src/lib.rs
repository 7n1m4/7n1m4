// SPDX-License-Identifier: GPL-3.0-or-later
#![deny(missing_docs)]

//! AIRI SQLite persistence layer.
//!
//! `Mutex<Connection>` wrapper around `rusqlite` with WAL mode, migrations via
//! `PRAGMA user_version`, and typed repositories for settings, providers, cards,
//! sessions, messages, daily summaries, and the append-only journal.

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use dirs::data_dir;
use rusqlite::{Connection, OptionalExtension};

/// Re-exported for callers that write rows inside a shared transaction.
pub use rusqlite::params;
use serde::{de::DeserializeOwned, Deserialize, Serialize};

/// Current database schema version (user_version).
/// v2: lane ① (p7-memory-journal) — summaries/journal tables.
/// v3: lane ② (p7-retrieval) — `memory_embeddings` retrieval index.
/// v4: wave ④ (p9-data-vault) — `scrub_runs` optimization log.
/// v5: drop day-keyed summary embeddings (collided across summaries per day).
/// v6: local card metadata (liked/bookmarked flags owned by the daemon).
/// v7: character card documents (`cards`).
const SCHEMA_VERSION: i32 = 7;
/// Application data directory name.
const APP_DIR_NAME: &str = "airi-slint";
/// Database file name.
const DB_FILE_NAME: &str = "airi.sqlite";

/// Thread-safe SQLite database handle.
#[derive(Clone)]
pub struct Database {
    conn: Arc<Mutex<Connection>>,
}

impl Database {
    /// Open or create the database at the default platform data directory:
    /// `<data>/airi-slint/airi.sqlite`.
    pub fn open_default() -> Result<Self> {
        let base = data_dir().context("failed to resolve platform data directory")?;
        let dir = base.join(APP_DIR_NAME);
        std::fs::create_dir_all(&dir)
            .with_context(|| format!("failed to create data directory {}", dir.display()))?;
        Self::open(&dir.join(DB_FILE_NAME))
    }

    /// Open or create the database at a specific file path.
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        let conn = Connection::open(path)
            .with_context(|| format!("failed to open database {}", path.display()))?;
        // Concurrent openers (multi-process tests, second instance) race on the
        // WAL lock: `busy_timeout` makes SQLite retry instead of failing with
        // `database is locked`.
        conn.busy_timeout(std::time::Duration::from_secs(5))
            .context("failed to set SQLite busy timeout")?;
        conn.pragma_update(None, "journal_mode", "WAL")
            .context("failed to enable WAL mode")?;
        conn.pragma_update(None, "foreign_keys", "ON")
            .context("failed to enable foreign keys")?;

        let db = Self {
            conn: Arc::new(Mutex::new(conn)),
        };
        db.migrate()?;
        Ok(db)
    }

    fn migrate(&self) -> Result<()> {
        let conn = self.conn.lock().expect("database mutex poisoned");
        let current: i32 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap_or(0);
        if current >= SCHEMA_VERSION {
            return Ok(());
        }

        let tx = conn.unchecked_transaction()?;
        if current < 1 {
            tx.execute_batch(
                r#"
                create table if not exists settings (
                    key text primary key,
                    value text not null,
                    updated_at integer not null
                );
                create table if not exists providers (
                    id text primary key,
                    kind text not null,
                    config text not null,
                    enabled integer not null default 1,
                    updated_at integer not null
                );
                create table if not exists sessions (
                    id text primary key,
                    title text not null default '',
                    created_at integer not null,
                    updated_at integer not null,
                    metadata text not null default '{}'
                );
                create table if not exists messages (
                    id text primary key,
                    session_id text not null references sessions(id) on delete cascade,
                    role text not null,
                    content text not null,
                    created_at integer not null,
                    metadata text not null default '{}'
                );
                create index if not exists idx_messages_session_id on messages(session_id);
                create index if not exists idx_messages_created_at on messages(created_at);
                "#,
            )?;
        }
        if current < 2 {
            tx.execute_batch(
                r#"
                create table if not exists summaries (
                    id text primary key,
                    day text not null,
                    content text not null,
                    source_session_ids text not null default '[]',
                    token_estimate integer not null default 0,
                    created_at integer not null
                );
                create index if not exists idx_summaries_day on summaries(day);
                create table if not exists journal_entries (
                    id text primary key,
                    kind text not null default 'note',
                    content text not null,
                    embedding text,
                    created_at integer not null,
                    updated_at integer not null
                );
                create index if not exists idx_journal_created on journal_entries(created_at);
                "#,
            )?;
        }
        if current < 3 {
            tx.execute_batch(
                r#"
                create table if not exists memory_embeddings (
                    id text primary key,
                    kind text not null,
                    content text not null,
                    vector text not null,
                    created_at integer not null
                );
                create index if not exists idx_mem_emb_kind on memory_embeddings(kind);
                "#,
            )?;
        }
        if current < 4 {
            tx.execute_batch(
                r#"
                create table if not exists scrub_runs (
                    id text primary key,
                    started_at integer not null,
                    sessions_scanned integer not null default 0,
                    images_extracted integer not null default 0,
                    bytes_extracted integer not null default 0,
                    backup_path text
                );
                create index if not exists idx_scrub_runs_started on scrub_runs(started_at);
                "#,
            )?;
        }
        if current < 5 {
            // Old builds keyed summary embeddings by day; multiple summaries
            // on one day collided. Drop them so backfill re-embeds under
            // `summaries.id`, leaving no stale duplicates in retrieval.
            tx.execute_batch(
                "delete from memory_embeddings
                 where kind = 'summary'
                   and id in (select 'summary:' || day from summaries);",
            )?;
        }
        if current < 6 {
            // Local card metadata owned by the daemon. There is exactly one
            // row per card; an absent row means both flags are false.
            //
            // Beta builds may have created a differently-shaped table at this
            // version. Validate the actual columns before trusting
            // `IF NOT EXISTS`: create the canonical table when missing, and
            // rebuild it (preserving usable flags) when the shape is wrong.
            let table_exists: bool = tx.query_row(
                "select exists(select 1 from sqlite_master where type = 'table' and name = 'card_metadata')",
                [],
                |row| row.get::<_, i32>(0).map(|v| v != 0),
            )?;
            let mut columns = Vec::new();
            if table_exists {
                let mut stmt = tx.prepare("pragma table_info(card_metadata)")?;
                // Column name and declared type both matter: a beta table
                // with a `liked` TEXT column passed the old name-only check,
                // then rewrote flags via SQLite's lossy text→integer cast.
                let rows = stmt.query_map([], |row| {
                    Ok((
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?.to_ascii_lowercase(),
                    ))
                })?;
                for column in rows {
                    columns.push(column?);
                }
            }
            let canonical = [
                ("card_id", "text"),
                ("liked", "integer"),
                ("bookmarked", "integer"),
                ("updated_at", "integer"),
            ];
            let shape_ok = table_exists
                && columns.len() == canonical.len()
                && columns
                    .iter()
                    .all(|c| canonical.iter().any(|(n, t)| n == &c.0 && t == &c.1));
            if !shape_ok {
                if table_exists {
                    tx.execute_batch("alter table card_metadata rename to card_metadata_legacy;")?;
                }
                tx.execute_batch(
                    r#"
                    create table card_metadata (
                        card_id text primary key,
                        liked integer not null default 0,
                        bookmarked integer not null default 0,
                        updated_at integer not null
                    );
                    "#,
                )?;
                if table_exists {
                    // Copy rows whenever the legacy table can identify a card
                    // and holds at least one flag; a beta table with only
                    // `updated_at` still keeps its timestamps, and a table
                    // with unrelated columns is dropped. Missing columns are
                    // defaulted instead of dropping otherwise-usable rows.
                    let has_card_id = columns.iter().any(|c| c.0 == "card_id");
                    let has_liked = columns.iter().any(|c| c.0 == "liked");
                    let has_bookmarked = columns.iter().any(|c| c.0 == "bookmarked");
                    let has_updated_at = columns.iter().any(|c| c.0 == "updated_at");
                    if has_card_id && (has_liked || has_bookmarked) {
                        // Beta builds declared the flags as TEXT; cast safely
                        // so a non-numeric legacy value becomes false instead
                        // of aborting the migration or poisoning reads.
                        let liked_expr = if has_liked {
                            "case when typeof(liked) = 'integer' then liked else 0 end"
                        } else {
                            "0"
                        };
                        let bookmarked_expr = if has_bookmarked {
                            "case when typeof(bookmarked) = 'integer' then bookmarked else 0 end"
                        } else {
                            "0"
                        };
                        let updated_expr = if has_updated_at {
                            "coalesce(updated_at, 0)"
                        } else {
                            "0"
                        };
                        tx.execute_batch(&format!(
                            "insert into card_metadata (card_id, liked, bookmarked, updated_at)
                             select card_id, {liked_expr}, {bookmarked_expr}, {updated_expr}
                             from card_metadata_legacy;
                             drop table card_metadata_legacy;",
                        ))?;
                    } else {
                        tx.execute_batch("drop table card_metadata_legacy;")?;
                    }
                }
            }
        }
        if current < 7 {
            // Cards authored locally in the daemon. The document column stores
            // the AiriCard JSON verbatim for full fidelity (so nothing is lost
            // on round-trip), while `name` is a denormalized copy for listing.
            tx.execute_batch(
                r#"
                create table if not exists cards (
                    id text primary key,
                    name text not null,
                    document text not null,
                    created_at integer not null,
                    updated_at integer not null
                );
                create index if not exists idx_cards_updated_at on cards(updated_at);
                "#,
            )?;
        }
        tx.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        tx.commit()?;
        Ok(())
    }

    /// Access the inner connection under the mutex.
    pub fn with_connection<F, R>(&self, f: F) -> Result<R>
    where
        F: FnOnce(&Connection) -> Result<R>,
    {
        let conn = self.conn.lock().expect("database mutex poisoned");
        f(&conn)
    }
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

/// Escape `LIKE` metacharacters so a query string matches literally.
///
/// Paired with `LIKE ... ESCAPE '\'` in SQL. `%` and `_` are wildcards and
/// `\` is the escape character itself.
fn escape_like(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for ch in input.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '%' => out.push_str("\\%"),
            '_' => out.push_str("\\_"),
            _ => out.push(ch),
        }
    }
    out
}

// ============================================================================
// Settings
// ============================================================================

/// Typed key-value settings repository.
#[derive(Clone)]
pub struct SettingsRepo {
    db: Database,
}

impl SettingsRepo {
    /// Create a settings repository.
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// Get a setting by key.
    pub fn get<T: DeserializeOwned>(&self, key: &str) -> Result<Option<T>> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let value: Option<String> = conn
            .query_row(
                "select value from settings where key = ?1",
                params![key],
                |row| row.get(0),
            )
            .optional()?;
        match value {
            Some(v) => Ok(Some(serde_json::from_str(&v)?)),
            None => Ok(None),
        }
    }

    /// Get a setting or return default.
    pub fn get_or<T: DeserializeOwned>(&self, key: &str, default: T) -> Result<T> {
        Ok(self.get(key)?.unwrap_or(default))
    }

    /// Get a setting together with its `updated_at` stamp in one read.
    ///
    /// Both columns come from a single query, so a concurrent writer cannot
    /// land between reading the value and reading the stamp: the pair is a
    /// consistent snapshot suitable for a later [`Self::set_if_unchanged`]
    /// compare-and-swap.
    pub fn get_with_updated_at<T: DeserializeOwned>(&self, key: &str) -> Result<Option<(T, i64)>> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let row: Option<(String, i64)> = conn
            .query_row(
                "select value, updated_at from settings where key = ?1",
                params![key],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        match row {
            Some((value, updated_at)) => Ok(Some((serde_json::from_str(&value)?, updated_at))),
            None => Ok(None),
        }
    }

    /// Set a setting value.
    ///
    /// A write older than the stored row's `updated_at` is rejected with an
    /// error instead of being silently skipped: two processes can hold the
    /// same `airi.sqlite` open and the slower writer must not revert the other
    /// one's value, but the caller must learn that nothing was written.
    /// Same millisecond is last-writer-wins.
    pub fn set<T: Serialize>(&self, key: &str, value: &T) -> Result<()> {
        let json = serde_json::to_string(value)?;
        let ts = now_ms();
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let affected = conn.execute(
            "insert into settings (key, value, updated_at) values (?1, ?2, ?3)
             on conflict(key) do update set value = excluded.value, updated_at = excluded.updated_at
             where excluded.updated_at >= settings.updated_at",
            params![key, json, ts],
        )?;
        anyhow::ensure!(
            affected > 0,
            "setting `{key}` was not written: a newer value already exists"
        );
        Ok(())
    }

    /// Write a setting only while its stored `updated_at` still matches a
    /// snapshot obtained from [`Self::get_with_updated_at`].
    ///
    /// The comparison and the write are a single atomic upsert, so a stale
    /// writer fails loudly instead of reverting a newer concurrent value (a
    /// guard inside SQLite, not just this process's mutex). The new stamp is
    /// forced strictly past `expected_updated_at` so two consecutive CAS
    /// writes cannot collide on the same millisecond or reuse a future stamp.
    pub fn set_if_unchanged<T: Serialize>(
        &self,
        key: &str,
        value: &T,
        expected_updated_at: i64,
    ) -> Result<()> {
        let json = serde_json::to_string(value)?;
        let ts = now_ms().max(expected_updated_at.saturating_add(1));
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let affected = conn.execute(
            "insert into settings (key, value, updated_at) values (?1, ?2, ?3)
             on conflict(key) do update set value = excluded.value, updated_at = excluded.updated_at
             where settings.updated_at = ?4",
            params![key, json, ts, expected_updated_at],
        )?;
        anyhow::ensure!(
            affected > 0,
            "setting `{key}` was not written: stale snapshot (expected updated_at = {expected_updated_at})"
        );
        Ok(())
    }

    /// Delete a setting.
    pub fn delete(&self, key: &str) -> Result<bool> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let n = conn.execute("delete from settings where key = ?1", params![key])?;
        Ok(n > 0)
    }

    /// List all keys with an optional prefix.
    pub fn list_keys(&self, prefix: Option<&str>) -> Result<Vec<String>> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        if let Some(prefix) = prefix {
            let mut stmt =
                conn.prepare("select key from settings where key like ?1 order by key")?;
            let rows = stmt.query_map(params![format!("{prefix}%")], |row| row.get(0))?;
            rows.collect::<std::result::Result<Vec<_>, _>>()
                .map_err(Into::into)
        } else {
            let mut stmt = conn.prepare("select key from settings order by key")?;
            let rows = stmt.query_map([], |row| row.get(0))?;
            rows.collect::<std::result::Result<Vec<_>, _>>()
                .map_err(Into::into)
        }
    }
}

// ============================================================================
// Providers
// ============================================================================

/// Provider kind tag stored in DB.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProviderKind {
    /// OpenAI-compatible HTTP API.
    OpenAiCompatible,
    /// Anthropic Messages API.
    Anthropic,
    /// Google Gemini API.
    GoogleGemini,
    /// AWS Bedrock.
    AwsBedrock,
    /// Local server (Ollama/LM Studio/etc).
    LocalServer,
}

/// Stored provider record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredProvider {
    /// Provider id.
    pub id: String,
    /// Provider kind.
    pub kind: ProviderKind,
    /// JSON configuration blob (typed at higher layers later).
    pub config: serde_json::Value,
    /// Whether enabled.
    pub enabled: bool,
    /// Last update timestamp (ms).
    pub updated_at: i64,
}

/// Provider repository.
#[derive(Clone)]
pub struct ProviderRepo {
    db: Database,
}

impl ProviderRepo {
    /// Create provider repository.
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// List providers, newest first.
    pub fn list(&self) -> Result<Vec<StoredProvider>> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let mut stmt = conn.prepare(
            "select id, kind, config, enabled, updated_at from providers order by updated_at desc",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(ProviderRow {
                id: row.get(0)?,
                kind: row.get(1)?,
                config: row.get(2)?,
                enabled: row.get::<_, i64>(3)?,
                updated_at: row.get(4)?,
            })
        })?;
        rows.map(|r| r.map_err(Into::into).and_then(row_to_provider))
            .collect()
    }

    /// Get a provider by id.
    pub fn get(&self, id: &str) -> Result<Option<StoredProvider>> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let row = conn
            .query_row(
                "select id, kind, config, enabled, updated_at from providers where id = ?1",
                params![id],
                |row| {
                    Ok(ProviderRow {
                        id: row.get(0)?,
                        kind: row.get(1)?,
                        config: row.get(2)?,
                        enabled: row.get::<_, i64>(3)?,
                        updated_at: row.get(4)?,
                    })
                },
            )
            .optional()?;
        row.map(row_to_provider).transpose()
    }

    /// Upsert a provider.
    pub fn upsert(&self, provider: &StoredProvider) -> Result<()> {
        let kind = serde_json::to_string(&provider.kind)?;
        // serde_json::to_string on string-enum yields quoted string; store plain for readability.
        let kind_plain = kind.trim_matches('"').to_string();
        let config = serde_json::to_string(&provider.config)?;
        let ts = if provider.updated_at > 0 {
            provider.updated_at
        } else {
            now_ms()
        };
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        conn.execute(
            "insert into providers (id, kind, config, enabled, updated_at) values (?1, ?2, ?3, ?4, ?5)
             on conflict(id) do update set kind = excluded.kind, config = excluded.config,
             enabled = excluded.enabled, updated_at = excluded.updated_at",
            params![provider.id, kind_plain, config, provider.enabled as i64, ts],
        )?;
        Ok(())
    }

    /// Delete a provider.
    pub fn delete(&self, id: &str) -> Result<bool> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let n = conn.execute("delete from providers where id = ?1", params![id])?;
        Ok(n > 0)
    }
}

struct ProviderRow {
    id: String,
    kind: String,
    config: String,
    enabled: i64,
    updated_at: i64,
}

fn row_to_provider(row: ProviderRow) -> Result<StoredProvider> {
    // Accept both quoted json string and plain token for robustness.
    let kind: ProviderKind = serde_json::from_str(&format!("\"{}\"", row.kind.trim_matches('"')))
        .or_else(|_| serde_json::from_str(&row.kind))
        .with_context(|| format!("invalid provider kind '{}'", row.kind))?;
    let config: serde_json::Value = serde_json::from_str(&row.config)
        .with_context(|| format!("invalid provider config for '{}'", row.id))?;
    Ok(StoredProvider {
        id: row.id,
        kind,
        config,
        enabled: row.enabled != 0,
        updated_at: row.updated_at,
    })
}

// ============================================================================
// Sessions
// ============================================================================

/// Stored chat session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredSession {
    /// Session id.
    pub id: String,
    /// Title.
    pub title: String,
    /// Created timestamp (ms).
    pub created_at: i64,
    /// Updated timestamp (ms).
    pub updated_at: i64,
    /// Metadata JSON.
    pub metadata: serde_json::Value,
}

/// Session repository.
#[derive(Clone)]
pub struct SessionRepo {
    db: Database,
}

impl SessionRepo {
    /// Create session repository.
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// List sessions, newest first.
    pub fn list(&self) -> Result<Vec<StoredSession>> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let mut stmt = conn.prepare(
            "select id, title, created_at, updated_at, metadata from sessions order by updated_at desc",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(SessionRow {
                id: row.get(0)?,
                title: row.get(1)?,
                created_at: row.get(2)?,
                updated_at: row.get(3)?,
                metadata: row.get(4)?,
            })
        })?;
        rows.map(|r| r.map_err(Into::into).and_then(row_to_session))
            .collect()
    }

    /// List the most recent sessions by `updated_at`, capped by `limit`.
    pub fn list_recent(&self, limit: usize) -> Result<Vec<StoredSession>> {
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let mut stmt = conn.prepare(
            "select id, title, created_at, updated_at, metadata from sessions order by updated_at desc, rowid desc limit ?1",
        )?;
        let rows = stmt.query_map(params![limit], |row| {
            Ok(SessionRow {
                id: row.get(0)?,
                title: row.get(1)?,
                created_at: row.get(2)?,
                updated_at: row.get(3)?,
                metadata: row.get(4)?,
            })
        })?;
        rows.map(|r| r.map_err(Into::into).and_then(row_to_session))
            .collect()
    }

    /// Get a session by id.
    pub fn get(&self, id: &str) -> Result<Option<StoredSession>> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let row = conn
            .query_row(
                "select id, title, created_at, updated_at, metadata from sessions where id = ?1",
                params![id],
                |row| {
                    Ok(SessionRow {
                        id: row.get(0)?,
                        title: row.get(1)?,
                        created_at: row.get(2)?,
                        updated_at: row.get(3)?,
                        metadata: row.get(4)?,
                    })
                },
            )
            .optional()?;
        row.map(row_to_session).transpose()
    }

    /// Create a session.
    pub fn create(&self, id: &str, title: &str) -> Result<StoredSession> {
        let ts = now_ms();
        let session = StoredSession {
            id: id.to_string(),
            title: title.to_string(),
            created_at: ts,
            updated_at: ts,
            metadata: serde_json::json!({}),
        };
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        conn.execute(
            "insert into sessions (id, title, created_at, updated_at, metadata) values (?1, ?2, ?3, ?4, ?5)",
            params![
                session.id,
                session.title,
                session.created_at,
                session.updated_at,
                serde_json::to_string(&session.metadata)?
            ],
        )?;
        Ok(session)
    }

    /// Update session title and/or metadata.
    pub fn update(
        &self,
        id: &str,
        title: Option<&str>,
        metadata: Option<&serde_json::Value>,
    ) -> Result<bool> {
        let existing = self.get(id)?;
        let Some(mut s) = existing else {
            return Ok(false);
        };
        if let Some(t) = title {
            s.title = t.to_string();
        }
        if let Some(m) = metadata {
            s.metadata = m.clone();
        }
        s.updated_at = now_ms();
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let n = conn.execute(
            "update sessions set title = ?1, updated_at = ?2, metadata = ?3 where id = ?4",
            params![
                s.title,
                s.updated_at,
                serde_json::to_string(&s.metadata)?,
                id
            ],
        )?;
        Ok(n > 0)
    }

    /// Delete a session (cascades to messages).
    pub fn delete(&self, id: &str) -> Result<bool> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let n = conn.execute("delete from sessions where id = ?1", params![id])?;
        Ok(n > 0)
    }

    /// Search sessions by title, case-insensitive substring match.
    ///
    /// LIKE special characters (`\`, `%`, `_`) in the query are escaped; the
    /// pattern is bound as a parameter. Returns at most 50 rows, newest
    /// (most recently updated) first. An empty or whitespace-only query
    /// returns no rows. Case-insensitivity follows SQLite `LIKE` semantics
    /// (ASCII case folding).
    pub fn search(&self, query: &str) -> Result<Vec<StoredSession>> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }
        let escaped = escape_like(trimmed);
        let pattern = format!("%{escaped}%");
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let mut stmt = conn.prepare(
            "select id, title, created_at, updated_at, metadata from sessions \
             where title like ?1 escape '\\' order by updated_at desc limit 50",
        )?;
        let rows = stmt.query_map(params![pattern], |row| {
            Ok(SessionRow {
                id: row.get(0)?,
                title: row.get(1)?,
                created_at: row.get(2)?,
                updated_at: row.get(3)?,
                metadata: row.get(4)?,
            })
        })?;
        rows.map(|r| r.map_err(Into::into).and_then(row_to_session))
            .collect()
    }
}

struct SessionRow {
    id: String,
    title: String,
    created_at: i64,
    updated_at: i64,
    metadata: String,
}

fn row_to_session(row: SessionRow) -> Result<StoredSession> {
    Ok(StoredSession {
        id: row.id,
        title: row.title,
        created_at: row.created_at,
        updated_at: row.updated_at,
        metadata: serde_json::from_str(&row.metadata).unwrap_or_else(|_| serde_json::json!({})),
    })
}

// ============================================================================
// Messages
// ============================================================================

/// Stored chat message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredMessage {
    /// Message id.
    pub id: String,
    /// Session id.
    pub session_id: String,
    /// Role (user/assistant/system/tool/etc).
    pub role: String,
    /// Content payload.
    pub content: String,
    /// Created timestamp (ms).
    pub created_at: i64,
    /// Metadata JSON.
    pub metadata: serde_json::Value,
}

/// Message repository.
#[derive(Clone)]
pub struct MessageRepo {
    db: Database,
}

impl MessageRepo {
    /// Create message repository.
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// List messages for a session, oldest first.
    pub fn list(&self, session_id: &str) -> Result<Vec<StoredMessage>> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let mut stmt = conn.prepare(
            "select id, session_id, role, content, created_at, metadata
             from messages where session_id = ?1 order by created_at asc, rowid asc",
        )?;
        let rows = stmt.query_map(params![session_id], |row| {
            Ok(MessageRow {
                id: row.get(0)?,
                session_id: row.get(1)?,
                role: row.get(2)?,
                content: row.get(3)?,
                created_at: row.get(4)?,
                metadata: row.get(5)?,
                rowid: None,
            })
        })?;
        rows.map(|r| r.map_err(Into::into).and_then(row_to_message))
            .collect()
    }

    /// Paginate messages for a session, oldest first.
    ///
    /// `before` is the `(created_at, rowid)` cursor of the last row of the
    /// previous page; paging never skips or repeats a row even when timestamps
    /// tie.
    pub fn list_page(
        &self,
        session_id: &str,
        limit: usize,
        before: Option<(i64, i64)>,
    ) -> Result<Vec<(StoredMessage, i64)>> {
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let mut out = Vec::new();
        match before {
            Some((created_at_cursor, rowid_cursor)) => {
                let mut stmt = conn.prepare(
                    "select id, session_id, role, content, created_at, metadata, rowid
                     from messages where session_id = ?1
                       and (created_at > ?2 or (created_at = ?2 and rowid > ?3))
                     order by created_at asc, rowid asc limit ?4",
                )?;
                let rows = stmt.query_map(
                    params![session_id, created_at_cursor, rowid_cursor, limit],
                    |row| {
                        Ok(MessageRow {
                            id: row.get(0)?,
                            session_id: row.get(1)?,
                            role: row.get(2)?,
                            content: row.get(3)?,
                            created_at: row.get(4)?,
                            metadata: row.get(5)?,
                            rowid: Some(row.get(6)?),
                        })
                    },
                )?;
                for row in rows {
                    let mr: MessageRow = row?;
                    let rowid = mr.rowid.unwrap_or(0);
                    let msg = row_to_message(mr)?;
                    out.push((msg, rowid));
                }
            }
            None => {
                let mut stmt = conn.prepare(
                    "select id, session_id, role, content, created_at, metadata, rowid
                     from messages where session_id = ?1
                     order by created_at asc, rowid asc limit ?2",
                )?;
                let rows = stmt.query_map(params![session_id, limit], |row| {
                    Ok(MessageRow {
                        id: row.get(0)?,
                        session_id: row.get(1)?,
                        role: row.get(2)?,
                        content: row.get(3)?,
                        created_at: row.get(4)?,
                        metadata: row.get(5)?,
                        rowid: Some(row.get(6)?),
                    })
                })?;
                for row in rows {
                    let mr: MessageRow = row?;
                    let rowid = mr.rowid.unwrap_or(0);
                    let msg = row_to_message(mr)?;
                    out.push((msg, rowid));
                }
            }
        }
        Ok(out)
    }

    ///
    /// Used by the data-vault export and the session-media scrub, which both
    /// need a full scan. Potentially large on long histories — callers should
    /// be prepared for that.
    pub fn list_all(&self) -> Result<Vec<StoredMessage>> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let mut stmt = conn.prepare(
            "select id, session_id, role, content, created_at, metadata
             from messages order by created_at asc, rowid asc",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(MessageRow {
                id: row.get(0)?,
                session_id: row.get(1)?,
                role: row.get(2)?,
                content: row.get(3)?,
                created_at: row.get(4)?,
                metadata: row.get(5)?,
                rowid: None,
            })
        })?;
        rows.map(|r| r.map_err(Into::into).and_then(row_to_message))
            .collect()
    }

    /// Get a message by id.
    pub fn get(&self, id: &str) -> Result<Option<StoredMessage>> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let row = conn
            .query_row(
                "select id, session_id, role, content, created_at, metadata from messages where id = ?1",
                params![id],
                |row| {
                    Ok(MessageRow {
                        id: row.get(0)?,
                        session_id: row.get(1)?,
                        role: row.get(2)?,
                        content: row.get(3)?,
                        created_at: row.get(4)?,
                        metadata: row.get(5)?,
                        rowid: None,
                    })
                },
            )
            .optional()?;
        row.map(row_to_message).transpose()
    }

    /// Insert a message and touch session updated_at atomically.
    pub fn insert(&self, msg: &StoredMessage) -> Result<()> {
        let metadata = serde_json::to_string(&msg.metadata)?;
        let mut conn = self.db.conn.lock().expect("database mutex poisoned");
        let tx = conn.transaction()?;
        tx.execute(
            "insert into messages (id, session_id, role, content, created_at, metadata)
             values (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                msg.id,
                msg.session_id,
                msg.role,
                msg.content,
                msg.created_at,
                metadata
            ],
        )?;
        tx.execute(
            "update sessions set updated_at = ?1 where id = ?2",
            params![msg.created_at, msg.session_id],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Insert a message, creating its session first when absent, in one
    /// transaction. A failed insert leaves neither a stray session nor a
    /// half-written message.
    pub fn insert_with_session(&self, title: &str, msg: &StoredMessage) -> Result<()> {
        let metadata = serde_json::to_string(&msg.metadata)?;
        let mut conn = self.db.conn.lock().expect("database mutex poisoned");
        let tx = conn.transaction()?;
        let ts = now_ms();
        tx.execute(
            "insert or ignore into sessions (id, title, created_at, updated_at, metadata)
             values (?1, ?2, ?3, ?4, '{}')",
            params![msg.session_id, title, ts, ts],
        )?;
        tx.execute(
            "insert into messages (id, session_id, role, content, created_at, metadata)
             values (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                msg.id,
                msg.session_id,
                msg.role,
                msg.content,
                msg.created_at,
                metadata
            ],
        )?;
        tx.execute(
            "update sessions set updated_at = ?1 where id = ?2",
            params![msg.created_at, msg.session_id],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Delete a message.
    pub fn delete(&self, id: &str) -> Result<bool> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let n = conn.execute("delete from messages where id = ?1", params![id])?;
        Ok(n > 0)
    }
}

struct MessageRow {
    id: String,
    session_id: String,
    role: String,
    content: String,
    created_at: i64,
    metadata: String,
    /// Only the paging query selects `rowid`, so the other queries leave it `None`.
    rowid: Option<i64>,
}

fn row_to_message(row: MessageRow) -> Result<StoredMessage> {
    Ok(StoredMessage {
        id: row.id,
        session_id: row.session_id,
        role: row.role,
        content: row.content,
        created_at: row.created_at,
        metadata: serde_json::from_str(&row.metadata).unwrap_or_else(|_| serde_json::json!({})),
    })
}

// ============================================================================
// Summaries (short-term memory daily blocks)
// ============================================================================

/// A daily short-term-memory summary block.
///
/// One row per summarization run; `day` is a local-calendar `YYYY-MM-DD`
/// key. `source_session_ids` records which sessions fed the summary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredSummary {
    /// Summary id.
    pub id: String,
    /// Local day key (`YYYY-MM-DD`).
    pub day: String,
    /// Summary body (markdown).
    pub content: String,
    /// Session ids distilled into this summary.
    pub source_session_ids: Vec<String>,
    /// Estimated token count of `content`.
    pub token_estimate: i64,
    /// Created timestamp (ms since epoch).
    pub created_at: i64,
}

/// Summary repository (short-term memory daily blocks).
#[derive(Clone)]
pub struct SummaryRepo {
    db: Database,
}

impl SummaryRepo {
    /// Create summary repository.
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// Insert a summary row, failing on a duplicate `id`.
    ///
    /// Use [`SummaryRepo::upsert`] for idempotent re-sends.
    pub fn insert(&self, summary: &StoredSummary) -> Result<()> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        conn.execute(
            "insert into summaries (id, day, content, source_session_ids, token_estimate, created_at)
             values (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                summary.id,
                summary.day,
                summary.content,
                serde_json::to_string(&summary.source_session_ids)?,
                summary.token_estimate,
                summary.created_at,
            ],
        )?;
        Ok(())
    }

    /// Upsert a summary row keyed by `id`.
    ///
    /// Mirrors [`MemoryEmbeddingRepo::upsert`]: a same-id block replaces the
    /// stored row instead of failing on the primary-key conflict, so a thin
    /// client can re-send a block without a read-modify-write.
    pub fn upsert(&self, summary: &StoredSummary) -> Result<()> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        conn.execute(
            "insert into summaries (id, day, content, source_session_ids, token_estimate, created_at)
             values (?1, ?2, ?3, ?4, ?5, ?6)
             on conflict(id) do update set day = excluded.day, content = excluded.content,
             source_session_ids = excluded.source_session_ids,
             token_estimate = excluded.token_estimate, created_at = excluded.created_at",
            params![
                summary.id,
                summary.day,
                summary.content,
                serde_json::to_string(&summary.source_session_ids)?,
                summary.token_estimate,
                summary.created_at,
            ],
        )?;
        Ok(())
    }

    /// List all summaries for one day, oldest first.
    pub fn list_by_day(&self, day: &str) -> Result<Vec<StoredSummary>> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let mut stmt = conn.prepare(
            "select id, day, content, source_session_ids, token_estimate, created_at
             from summaries where day = ?1 order by created_at asc, rowid asc",
        )?;
        let rows = stmt.query_map(params![day], |row| {
            Ok(SummaryRow {
                id: row.get(0)?,
                day: row.get(1)?,
                content: row.get(2)?,
                source_session_ids: row.get(3)?,
                token_estimate: row.get(4)?,
                created_at: row.get(5)?,
            })
        })?;
        rows.map(|r| r.map_err(Into::into).and_then(row_to_summary))
            .collect()
    }

    /// List the most recent summaries, newest day first (ties: newest
    /// `created_at` first).
    pub fn list_recent(&self, limit: usize) -> Result<Vec<StoredSummary>> {
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let mut stmt = conn.prepare(
            "select id, day, content, source_session_ids, token_estimate, created_at
             from summaries order by day desc, created_at desc, rowid desc limit ?1",
        )?;
        let rows = stmt.query_map(params![limit], |row| {
            Ok(SummaryRow {
                id: row.get(0)?,
                day: row.get(1)?,
                content: row.get(2)?,
                source_session_ids: row.get(3)?,
                token_estimate: row.get(4)?,
                created_at: row.get(5)?,
            })
        })?;
        rows.map(|r| r.map_err(Into::into).and_then(row_to_summary))
            .collect()
    }

    /// Number of stored summaries.
    pub fn count(&self) -> Result<u64> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let n: i64 = conn.query_row("select count(*) from summaries", [], |row| row.get(0))?;
        Ok(u64::try_from(n).unwrap_or(0))
    }

    /// Delete one summary by id. Returns `true` when a row was removed.
    ///
    /// The user-initiated delete path needs a durable daemon-side remove:
    /// re-upserting the surviving snapshot cannot distinguish an intentionally
    /// deleted id from a row that simply was not sent.
    pub fn delete(&self, id: &str) -> Result<bool> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let n = conn.execute("delete from summaries where id = ?1", params![id])?;
        Ok(n > 0)
    }

    /// Delete summaries whose day falls outside the newest 365 distinct days.
    ///
    /// The 365-day cap mirrors the short-term memory `maxDays` default.
    /// Returns the number of deleted rows.
    pub fn prune_over_365_days(&self) -> Result<usize> {
        self.prune_over_days(365)
    }

    /// Delete summaries whose day falls outside the newest `max_days`
    /// distinct days.
    ///
    /// `DISTINCT` keeps the newest `max_days` *days*, not the newest
    /// `max_days` rows. Returns the number of deleted rows. `max_days` of
    /// `0` deletes every summary.
    pub fn prune_over_days(&self, max_days: u32) -> Result<usize> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let limit = i64::from(max_days);
        let n = conn.execute(
            "delete from summaries where day not in (
                select distinct day from summaries order by day desc limit ?1
            )",
            params![limit],
        )?;
        Ok(n)
    }
}

struct SummaryRow {
    id: String,
    day: String,
    content: String,
    source_session_ids: String,
    token_estimate: i64,
    created_at: i64,
}

fn row_to_summary(row: SummaryRow) -> Result<StoredSummary> {
    Ok(StoredSummary {
        id: row.id,
        day: row.day,
        content: row.content,
        source_session_ids: serde_json::from_str(&row.source_session_ids).unwrap_or_default(),
        token_estimate: row.token_estimate,
        created_at: row.created_at,
    })
}

// ============================================================================
// Journal entries (append-only text journal)
// ============================================================================

/// A stored journal entry.
///
/// `embedding` is the raw JSON array carried as text in the `embedding`
/// column; `None` means "not embedded". Lane ② (retrieval) may read it;
/// the write path owned by lane ① stores `NULL` unless the caller supplies
/// a vector.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StoredJournalEntry {
    /// Entry id.
    pub id: String,
    /// Entry kind: `note` | `dream` | `milestone` | `summary`.
    pub kind: String,
    /// Entry body.
    pub content: String,
    /// Embedding vector, when one was supplied at append time.
    pub embedding: Option<Vec<f32>>,
    /// Created timestamp (ms since epoch).
    pub created_at: i64,
    /// Updated timestamp (ms since epoch). Never exceeds `created_at`;
    /// append-only rows are never mutated after insert.
    pub updated_at: i64,
}

/// Append-only text journal repository.
///
/// Entries are immutable once written: no update method exists. The only
/// delete is [`JournalRepo::delete`], reserved for an explicit user action —
/// automated loops and assistant tools must stay append-only. `updated_at` is
/// stored equal to `created_at` at insert time for consumers that order by
/// recency across both columns.
#[derive(Clone)]
pub struct JournalRepo {
    db: Database,
}

/// Whitelisted values for the `kind` column.
const JOURNAL_KINDS: [&str; 4] = ["note", "dream", "milestone", "summary"];

impl JournalRepo {
    /// Create journal repository.
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// Append an entry; returns the new entry id.
    ///
    /// `kind` must be one of `note` | `dream` | `milestone` | `summary`.
    /// Empty or whitespace-only content is rejected; the content is stored
    /// verbatim otherwise. `created_at` and `updated_at` are set to the
    /// current time.
    pub fn append(&self, kind: &str, content: &str, embedding: Option<&[f32]>) -> Result<String> {
        if !JOURNAL_KINDS.contains(&kind) {
            return Err(anyhow::anyhow!(
                "invalid journal entry kind {kind:?} (expected one of: note, dream, milestone, summary)"
            ));
        }
        if content.trim().is_empty() {
            return Err(anyhow::anyhow!("journal entry content must not be empty"));
        }
        let id = new_row_id();
        let ts = now_ms();
        let embedding_json = embedding
            .map(serde_json::to_string)
            .transpose()
            .context("failed to serialize journal embedding")?;
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        conn.execute(
            "insert into journal_entries (id, kind, content, embedding, created_at, updated_at)
             values (?1, ?2, ?3, ?4, ?5, ?6)",
            params![id, kind, content, embedding_json, ts, ts],
        )?;
        Ok(id)
    }

    /// Delete one journal entry by id. Returns `true` when a row was removed.
    ///
    /// User-initiated only: callers must not invoke this from assistant tools
    /// or background workers (Sacred Journal Rule).
    pub fn delete(&self, id: &str) -> Result<bool> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let n = conn.execute("delete from journal_entries where id = ?1", params![id])?;
        Ok(n > 0)
    }

    /// List entries created within `[from_ms, to_ms]` (inclusive), oldest first.
    pub fn list_between(
        &self,
        from_ms: i64,
        to_ms: i64,
        limit: usize,
    ) -> Result<Vec<StoredJournalEntry>> {
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let mut stmt = conn.prepare(
            "select id, kind, content, embedding, created_at, updated_at
             from journal_entries
             where created_at >= ?1 and created_at <= ?2
             order by created_at asc, rowid asc limit ?3",
        )?;
        let rows = stmt.query_map(params![from_ms, to_ms, limit], |row| {
            Ok(JournalRow {
                id: row.get(0)?,
                kind: row.get(1)?,
                content: row.get(2)?,
                embedding: row.get(3)?,
                created_at: row.get(4)?,
                updated_at: row.get(5)?,
            })
        })?;
        rows.map(|r| r.map_err(Into::into).and_then(row_to_journal_entry))
            .collect()
    }

    /// List the most recent entries, newest first.
    pub fn list_recent(&self, limit: usize) -> Result<Vec<StoredJournalEntry>> {
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let mut stmt = conn.prepare(
            "select id, kind, content, embedding, created_at, updated_at
             from journal_entries order by created_at desc, rowid desc limit ?1",
        )?;
        let rows = stmt.query_map(params![limit], |row| {
            Ok(JournalRow {
                id: row.get(0)?,
                kind: row.get(1)?,
                content: row.get(2)?,
                embedding: row.get(3)?,
                created_at: row.get(4)?,
                updated_at: row.get(5)?,
            })
        })?;
        rows.map(|r| r.map_err(Into::into).and_then(row_to_journal_entry))
            .collect()
    }

    /// Number of stored journal entries.
    pub fn count(&self) -> Result<u64> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let n: i64 =
            conn.query_row("select count(*) from journal_entries", [], |row| row.get(0))?;
        Ok(u64::try_from(n).unwrap_or(0))
    }
}

fn new_row_id() -> String {
    // Time + pid keeps ids roughly sortable; the atomic counter guarantees
    // uniqueness even when two ids are minted within the same clock tick
    // (same scheme as anima-core::new_id).
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("{:x}{:x}-{:x}", n, std::process::id(), counter)
}

struct JournalRow {
    id: String,
    kind: String,
    content: String,
    embedding: Option<String>,
    created_at: i64,
    updated_at: i64,
}

fn row_to_journal_entry(row: JournalRow) -> Result<StoredJournalEntry> {
    let embedding = match row.embedding.as_deref() {
        Some(raw) => {
            Some(serde_json::from_str(raw).context("journal embedding is not valid JSON")?)
        }
        None => None,
    };
    Ok(StoredJournalEntry {
        id: row.id,
        kind: row.kind,
        content: row.content,
        embedding,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}

// ============================================================================
// Memory embeddings (retrieval index, migration v3 — p7-retrieval lane ②)
// ============================================================================

/// A stored embedding row in `memory_embeddings`.
///
/// `id` is the source row id: `journal_entries.id` for journal memories, or
/// `'summary:' || summaries.id` for daily summaries. Vectors are stored as
/// JSON arrays. Written by the retrieval lane (`airi-core::memory::retrieval`);
/// lane ①'s `journal_entries.embedding` column is unrelated and untouched.
#[derive(Debug, Clone, PartialEq)]
pub struct MemoryEmbeddingRecord {
    /// Source row id (`journal_entries.id` or `'summary:' || summaries.id`).
    pub id: String,
    /// `'journal'` | `'summary'`.
    pub kind: String,
    /// Embedded text (stored verbatim, so no join back to source tables is required).
    pub content: String,
    /// Embedding vector.
    pub vector: Vec<f32>,
    /// Insert timestamp (ms).
    pub created_at: i64,
}

/// A lane ① source row lacking an embedding, surfaced by
/// [`MemoryEmbeddingRepo::list_missing_sources`] for backfill.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MissingMemorySource {
    /// Source row id (`'summary:' || summaries.id` for summaries).
    pub id: String,
    /// `'journal'` | `'summary'`.
    pub kind: String,
    /// Text to embed.
    pub content: String,
}

/// Repository for the `memory_embeddings` retrieval index (migration v3).
#[derive(Clone)]
pub struct MemoryEmbeddingRepo {
    db: Database,
}

impl MemoryEmbeddingRepo {
    /// Create the repository.
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// Upsert an embedding row (keyed by `id`).
    pub fn upsert(&self, record: &MemoryEmbeddingRecord) -> Result<()> {
        let vector = serde_json::to_string(&record.vector)
            .context("failed to serialize embedding vector")?;
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        conn.execute(
            "insert into memory_embeddings (id, kind, content, vector, created_at)
             values (?1, ?2, ?3, ?4, ?5)
             on conflict(id) do update set kind = excluded.kind, content = excluded.content,
             vector = excluded.vector, created_at = excluded.created_at",
            params![
                record.id,
                record.kind,
                record.content,
                vector,
                record.created_at
            ],
        )?;
        Ok(())
    }

    /// List the most recent embeddings, newest first. `kind == None` selects
    /// both kinds. `limit` caps the rows returned.
    pub fn list_latest(
        &self,
        limit: usize,
        kind: Option<&str>,
    ) -> Result<Vec<MemoryEmbeddingRecord>> {
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let mut out = Vec::new();
        match kind {
            Some(kind) => {
                let mut stmt = conn.prepare(
                    "select id, kind, content, vector, created_at
                     from memory_embeddings where kind = ?1 order by created_at desc, rowid desc limit ?2",
                )?;
                let rows = stmt.query_map(params![kind, limit], read_embedding_row)?;
                for row in rows {
                    out.push(row?);
                }
            }
            None => {
                let mut stmt = conn.prepare(
                    "select id, kind, content, vector, created_at
                     from memory_embeddings order by created_at desc, rowid desc limit ?1",
                )?;
                let rows = stmt.query_map(params![limit], read_embedding_row)?;
                for row in rows {
                    out.push(row?);
                }
            }
        }
        out.into_iter().collect()
    }

    /// Delete an embedding row. Returns true when a row was deleted.
    pub fn delete(&self, id: &str) -> Result<bool> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let n = conn.execute("delete from memory_embeddings where id = ?1", params![id])?;
        Ok(n > 0)
    }

    /// Number of stored embeddings.
    pub fn count(&self) -> Result<u64> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let n: i64 = conn.query_row("select count(*) from memory_embeddings", [], |row| {
            row.get(0)
        })?;
        Ok(u64::try_from(n).unwrap_or(0))
    }

    /// Backfill helper: lane ① `journal_entries` / `summaries` rows that are
    /// not yet embedded in `memory_embeddings`.
    ///
    /// Both tables (migration v2) are probed via `sqlite_master`; an absent
    /// table is skipped and contributes zero rows. A table that exists but
    /// lacks the expected columns is a hard error — silently skipping it
    /// would hide schema drift between lanes.
    pub fn list_missing_sources(&self) -> Result<Vec<MissingMemorySource>> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let tables: Vec<String> = {
            let mut stmt = conn.prepare(
                "select name from sqlite_master where type = 'table' and name in ('journal_entries', 'summaries')",
            )?;
            let rows = stmt.query_map([], |row| row.get(0))?;
            rows.collect::<std::result::Result<_, _>>()?
        };
        let mut out = Vec::new();
        if tables.iter().any(|t| t == "journal_entries") {
            ensure_columns(&conn, "journal_entries", &["id", "content"])?;
            let mut stmt = conn.prepare(
                "select id, 'journal', content from journal_entries
                 where id not in (select id from memory_embeddings where kind = 'journal')",
            )?;
            let rows = stmt.query_map([], |row| {
                Ok(MissingMemorySource {
                    id: row.get(0)?,
                    kind: row.get(1)?,
                    content: row.get(2)?,
                })
            })?;
            for row in rows {
                out.push(row?);
            }
        }
        if tables.iter().any(|t| t == "summaries") {
            ensure_columns(&conn, "summaries", &["id", "content"])?;
            let mut stmt = conn.prepare(
                "select 'summary:' || id, 'summary', content from summaries
                 where 'summary:' || id not in (select id from memory_embeddings where kind = 'summary')",
            )?;
            let rows = stmt.query_map([], |row| {
                Ok(MissingMemorySource {
                    id: row.get(0)?,
                    kind: row.get(1)?,
                    content: row.get(2)?,
                })
            })?;
            for row in rows {
                out.push(row?);
            }
        }
        Ok(out)
    }
}

fn read_embedding_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Result<MemoryEmbeddingRecord>> {
    let id: String = row.get(0)?;
    let kind: String = row.get(1)?;
    let content: String = row.get(2)?;
    let vector_raw: String = row.get(3)?;
    let created_at: i64 = row.get(4)?;
    let vector = serde_json::from_str(&vector_raw)
        .with_context(|| format!("memory_embeddings row `{id}` has an invalid vector JSON"));
    Ok(vector.map(|vector| MemoryEmbeddingRecord {
        id,
        kind,
        content,
        vector,
        created_at,
    }))
}

fn ensure_columns(conn: &Connection, table: &str, required: &[&str]) -> Result<()> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let columns: Vec<String> = stmt
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<std::result::Result<_, _>>()?;
    for column in required {
        anyhow::ensure!(
            columns.iter().any(|c| c == column),
            "table `{table}` exists but lacks expected column `{column}`"
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn test_db() -> Database {
        let dir = tempdir().expect("tempdir");
        Database::open(&dir.path().join("test.sqlite")).expect("open db")
    }

    #[test]
    fn settings_crud_and_json() {
        let db = test_db();
        let repo = SettingsRepo::new(db);

        repo.set("test.key", &"hello").unwrap();
        let val: Option<String> = repo.get("test.key").unwrap();
        assert_eq!(val.as_deref(), Some("hello"));
        assert_eq!(repo.get_or("missing", 7_i32).unwrap(), 7);

        #[derive(Serialize, Deserialize, PartialEq, Debug)]
        struct Cfg {
            enabled: bool,
            count: i32,
        }
        let cfg = Cfg {
            enabled: true,
            count: 42,
        };
        repo.set("cfg", &cfg).unwrap();
        let loaded: Cfg = repo.get("cfg").unwrap().unwrap();
        assert_eq!(loaded, cfg);

        let keys = repo.list_keys(Some("test")).unwrap();
        assert_eq!(keys, vec!["test.key".to_string()]);
        assert!(repo.delete("test.key").unwrap());
        assert!(repo.get::<String>("test.key").unwrap().is_none());
    }

    #[test]
    fn settings_set_rejects_older_write_loudly() {
        let db = test_db();
        // Keep a handle for the raw connection; repos take ownership of their clone.
        let repo = SettingsRepo::new(db.clone());
        let conn = db.conn.lock().expect("database mutex poisoned");
        conn.execute(
            "insert into settings (key, value, updated_at) values ('theme', '\"dark\"', ?1)",
            params![now_ms() + 60_000],
        )
        .unwrap();
        drop(conn);

        // The stored row is newer than this write: reject loudly instead of
        // silently succeeding with nothing written.
        let err = repo
            .set("theme", &"light")
            .expect_err("older write rejected");
        assert!(err.to_string().contains("theme"), "error: {err:#}");
        assert_eq!(
            repo.get::<String>("theme").unwrap().as_deref(),
            Some("dark")
        );
    }

    #[test]
    fn settings_set_if_unchanged_rejects_stale_snapshot() {
        let db = test_db();
        let repo = SettingsRepo::new(db.clone());
        let conn = db.conn.lock().expect("database mutex poisoned");
        conn.execute(
            "insert into settings (key, value, updated_at) values ('cas', '\"kept\"', 2)",
            [],
        )
        .unwrap();
        drop(conn);

        // The caller's snapshot (1) is older than the stored stamp (2).
        let err = repo
            .set_if_unchanged("cas", &"replacement", 1)
            .expect_err("stale snapshot rejected");
        assert!(err.to_string().contains("stale"), "error: {err:#}");

        // Nothing was written: both the value and the stamp survive.
        let (value, updated_at): (String, i64) = repo
            .get_with_updated_at("cas")
            .unwrap()
            .expect("row exists");
        assert_eq!(value, "kept");
        assert_eq!(updated_at, 2);
    }

    #[test]
    fn settings_set_if_unchanged_succeeds_on_matching_snapshot() {
        let db = test_db();
        let repo = SettingsRepo::new(db.clone());
        let conn = db.conn.lock().expect("database mutex poisoned");
        conn.execute(
            "insert into settings (key, value, updated_at) values ('cas-ok', '\"before\"', 10)",
            [],
        )
        .unwrap();
        drop(conn);

        repo.set_if_unchanged("cas-ok", &"after", 10).unwrap();
        let (value, updated_at): (String, i64) = repo
            .get_with_updated_at("cas-ok")
            .unwrap()
            .expect("row exists");
        assert_eq!(value, "after");
        assert!(updated_at > 10, "stamp must strictly advance: {updated_at}");
    }

    #[test]
    fn settings_set_if_unchanged_is_stale_across_database_handles() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("cas.sqlite");
        // Two independent handles onto the same file stand in for two processes.
        let first = SettingsRepo::new(Database::open(&path).expect("open first handle"));
        let second = SettingsRepo::new(Database::open(&path).expect("open second handle"));

        first.set("shared", &"initial").unwrap();
        let (_, expected): (String, i64) = second
            .get_with_updated_at("shared")
            .unwrap()
            .expect("row exists");

        // The other handle advances the stamp strictly past `expected`.
        second
            .set_if_unchanged("shared", &"newer", expected)
            .unwrap();

        // The first handle's snapshot is now stale: its CAS must fail and must
        // not revert the other handle's value. This is what the in-process
        // mutex cannot help with, so the guard must live in SQLite itself.
        let err = first
            .set_if_unchanged("shared", &"stale", expected)
            .expect_err("cross-handle stale snapshot rejected");
        assert!(err.to_string().contains("stale"), "error: {err:#}");

        let (value, _): (String, i64) = second
            .get_with_updated_at("shared")
            .unwrap()
            .expect("row exists");
        assert_eq!(value, "newer");
    }

    #[test]
    fn list_recent_returns_only_the_requested_rows() {
        let db = test_db();
        for i in 0..12 {
            SessionRepo::new(db.clone())
                .create(&format!("s{i}"), &format!("session {i}"))
                .unwrap();
        }
        let rows = SessionRepo::new(db).list_recent(5).unwrap();
        assert_eq!(rows.len(), 5);
        let ids: Vec<&str> = rows.iter().map(|r| r.id.as_str()).collect();
        assert_eq!(ids, vec!["s11", "s10", "s9", "s8", "s7"]);
    }

    #[test]
    fn insert_with_session_rolls_back_together() {
        let db = test_db();
        let sessions = SessionRepo::new(db.clone());
        let messages = MessageRepo::new(db);
        let msg = StoredMessage {
            id: "m1".to_string(),
            session_id: "new".to_string(),
            role: "user".to_string(),
            content: "hello".to_string(),
            created_at: now_ms(),
            metadata: serde_json::json!({}),
        };
        sessions.create("new", "new").unwrap();
        // A duplicate message id fails after the session insert; neither row
        // may survive the failed transaction.
        messages.insert(&msg).unwrap();
        let other = StoredMessage {
            id: "m1".to_string(),
            session_id: "new-other".to_string(),
            ..msg.clone()
        };
        assert!(messages.insert_with_session("new-other", &other).is_err());
        assert!(sessions.get("new-other").unwrap().is_none());
        assert!(messages.list("new-other").unwrap().is_empty());

        // A fresh turn into an existing session creates exactly one message.
        messages
            .insert_with_session(
                "fresh",
                &StoredMessage {
                    id: "m2".to_string(),
                    session_id: "fresh".to_string(),
                    ..msg
                },
            )
            .unwrap();
        assert!(sessions.get("fresh").unwrap().is_some());
        assert_eq!(messages.list("fresh").unwrap().len(), 1);
    }

    #[test]
    fn message_list_page_walks_every_row_without_repeats() {
        let db = test_db();
        let sessions = SessionRepo::new(db.clone());
        let messages = MessageRepo::new(db.clone());
        sessions.create("s1", "Test").unwrap();
        sessions.create("s2", "Other").unwrap();
        for i in 0..7 {
            messages
                .insert(&StoredMessage {
                    id: format!("m{i}"),
                    session_id: "s1".to_string(),
                    role: "user".to_string(),
                    content: format!("msg {i}"),
                    created_at: 10 + i,
                    metadata: serde_json::json!({}),
                })
                .unwrap();
        }
        messages
            .insert(&StoredMessage {
                id: "other".to_string(),
                session_id: "s2".to_string(),
                role: "user".to_string(),
                content: "other".to_string(),
                created_at: 10,
                metadata: serde_json::json!({}),
            })
            .unwrap();

        let expected: Vec<String> = messages
            .list("s1")
            .unwrap()
            .into_iter()
            .map(|m| m.id)
            .collect();

        let mut collected: Vec<String> = Vec::new();
        let mut cursor: Option<(i64, i64)> = None;
        loop {
            let page = messages.list_page("s1", 3, cursor).unwrap();
            let short = page.len() < 3;
            for (msg, rowid) in page {
                collected.push(msg.id);
                cursor = Some((msg.created_at, rowid));
            }
            if short {
                break;
            }
        }
        assert_eq!(collected, expected);
        assert!(!collected.iter().any(|id| id == "other"));
    }

    #[test]
    fn provider_repo_crud() {
        let db = test_db();
        let repo = ProviderRepo::new(db);
        let p = StoredProvider {
            id: "openrouter".to_string(),
            kind: ProviderKind::OpenAiCompatible,
            config: serde_json::json!({"base_url":"https://openrouter.ai/api/v1","api_key":"sk-test"}),
            enabled: true,
            updated_at: 1,
        };
        repo.upsert(&p).unwrap();
        let loaded = repo.get("openrouter").unwrap().unwrap();
        assert_eq!(loaded.id, "openrouter");
        assert_eq!(loaded.kind, ProviderKind::OpenAiCompatible);
        assert_eq!(loaded.config["base_url"], "https://openrouter.ai/api/v1");
        assert_eq!(repo.list().unwrap().len(), 1);
        assert!(repo.delete("openrouter").unwrap());
        assert!(repo.get("openrouter").unwrap().is_none());
    }

    #[test]
    fn sessions_messages_cascade() {
        let db = test_db();
        let sessions = SessionRepo::new(db.clone());
        let messages = MessageRepo::new(db);

        let s = sessions.create("s1", "Test").unwrap();
        assert_eq!(s.title, "Test");
        assert!(sessions.get("s1").unwrap().is_some());

        messages
            .insert(&StoredMessage {
                id: "m1".to_string(),
                session_id: "s1".to_string(),
                role: "user".to_string(),
                content: "Hello".to_string(),
                created_at: 10,
                metadata: serde_json::json!({"a":1}),
            })
            .unwrap();
        messages
            .insert(&StoredMessage {
                id: "m2".to_string(),
                session_id: "s1".to_string(),
                role: "assistant".to_string(),
                content: "Hi".to_string(),
                created_at: 20,
                metadata: serde_json::json!({}),
            })
            .unwrap();

        let listed = messages.list("s1").unwrap();
        assert_eq!(listed.len(), 2);
        assert_eq!(listed[0].content, "Hello");
        assert_eq!(listed[1].role, "assistant");

        assert!(sessions.update("s1", Some("Renamed"), None).unwrap());
        assert_eq!(sessions.get("s1").unwrap().unwrap().title, "Renamed");

        assert!(sessions.delete("s1").unwrap());
        assert!(sessions.get("s1").unwrap().is_none());
        assert!(messages.list("s1").unwrap().is_empty());
    }

    // ROOT CAUSE:
    //
    // `MessageRepo::insert` inserted the message in one autocommit statement and
    // touched `sessions.updated_at` in a second. If the touch failed, the
    // message survived without the revision bump, corrupting session ordering
    // and LWW conflict decisions.
    #[test]
    fn message_insert_rolls_back_when_session_touch_fails() {
        let db = test_db();
        let sessions = SessionRepo::new(db.clone());
        let messages = MessageRepo::new(db.clone());

        let session = sessions.create("s1", "Test").unwrap();
        // Fault injection at the persistence boundary: abort the session touch
        // after the message insert has had a chance to commit on its own.
        db.with_connection(|conn| {
            conn.execute_batch(
                "create trigger block_session_touch before update on sessions
                 begin
                     select raise(abort, 'session touch blocked');
                 end;",
            )?;
            Ok(())
        })
        .unwrap();

        let err = messages
            .insert(&StoredMessage {
                id: "m1".to_string(),
                session_id: "s1".to_string(),
                role: "user".to_string(),
                content: "Hello".to_string(),
                created_at: session.updated_at + 1_000,
                metadata: serde_json::json!({}),
            })
            .expect_err("session touch failure must propagate");
        assert!(
            err.to_string().contains("session touch blocked"),
            "unexpected error: {err:#}"
        );

        assert!(
            messages.get("m1").unwrap().is_none(),
            "message must not survive a failed session touch"
        );
        assert_eq!(
            sessions.get("s1").unwrap().unwrap().updated_at,
            session.updated_at,
            "session revision must not change when the touch fails"
        );
    }

    #[test]
    fn fresh_database_is_schema_v7_with_memory_and_scrub_tables() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("fresh.sqlite");
        let db = Database::open(&path).expect("open db");

        let version: i32 = db
            .with_connection(|c| Ok(c.query_row("PRAGMA user_version", [], |row| row.get(0))?))
            .expect("read user_version");
        assert_eq!(version, 7);

        let summaries = SummaryRepo::new(db.clone());
        summaries
            .insert(&StoredSummary {
                id: "sum1".to_string(),
                day: "2026-11-10".to_string(),
                content: "did things".to_string(),
                source_session_ids: vec!["s1".to_string()],
                token_estimate: 4,
                created_at: 10,
            })
            .unwrap();
        assert_eq!(summaries.count().unwrap(), 1);

        let journal = JournalRepo::new(db);
        let id = journal.append("note", "hello", None).unwrap();
        assert!(!id.is_empty());
        assert_eq!(journal.count().unwrap(), 1);
    }

    #[test]
    fn migration_from_v1_recreates_memory_tables_and_keeps_data() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("upgrade.sqlite");
        {
            let db = Database::open(&path).expect("open db");
            SessionRepo::new(db.clone())
                .create("keep-me", "Legacy session")
                .expect("seed session");
            // Simulate a v1 file: drop the v2 objects and reset user_version.
            db.with_connection(|c| {
                c.execute_batch(
                    "drop table if exists summaries;
                     drop table if exists journal_entries;
                     drop index if exists idx_summaries_day;
                     drop index if exists idx_journal_created;",
                )?;
                c.pragma_update(None, "user_version", 1_i32)?;
                Ok(())
            })
            .expect("downgrade to v1");
        }

        let db = Database::open(&path).expect("reopen and migrate");
        let version: i32 = db
            .with_connection(|c| Ok(c.query_row("PRAGMA user_version", [], |row| row.get(0))?))
            .expect("read user_version");
        assert_eq!(version, 7);

        // v1 data survived the upgrade.
        let session = SessionRepo::new(db.clone());
        assert_eq!(
            session.get("keep-me").unwrap().unwrap().title,
            "Legacy session"
        );

        // v2 tables are usable.
        let summaries = SummaryRepo::new(db.clone());
        assert_eq!(summaries.count().unwrap(), 0);
        let journal = JournalRepo::new(db);
        assert_eq!(journal.count().unwrap(), 0);
    }

    #[test]
    fn migration_is_idempotent_on_reopen() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("reopen.sqlite");
        {
            let db = Database::open(&path).expect("open db");
            JournalRepo::new(db)
                .append("note", "persisted", None)
                .expect("append");
        }
        let db = Database::open(&path).expect("reopen");
        let version: i32 = db
            .with_connection(|c| Ok(c.query_row("PRAGMA user_version", [], |row| row.get(0))?))
            .expect("read user_version");
        assert_eq!(version, 7);
        let entries = JournalRepo::new(db).list_recent(10).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].content, "persisted");
    }

    #[test]
    fn summary_repo_insert_list_recent_and_by_day() {
        let db = test_db();
        let repo = SummaryRepo::new(db);
        let summary = |id: &str, day: &str, created_at: i64| StoredSummary {
            id: id.to_string(),
            day: day.to_string(),
            content: format!("summary for {day}"),
            source_session_ids: vec!["s-a".to_string(), "s-b".to_string()],
            token_estimate: 42,
            created_at,
        };
        repo.insert(&summary("a", "2026-11-08", 100)).unwrap();
        repo.insert(&summary("b", "2026-11-09", 200)).unwrap();
        repo.insert(&summary("c", "2026-11-09", 300)).unwrap();
        repo.insert(&summary("d", "2026-11-10", 400)).unwrap();

        assert_eq!(repo.count().unwrap(), 4);

        let recent = repo.list_recent(2).unwrap();
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[0].day, "2026-11-10");
        assert_eq!(recent[1].day, "2026-11-09");
        assert_eq!(recent[1].id, "c"); // newest created_at first within a day

        let by_day = repo.list_by_day("2026-11-09").unwrap();
        assert_eq!(by_day.len(), 2);
        assert_eq!(by_day[0].id, "b");
        assert_eq!(by_day[1].id, "c");
        assert_eq!(
            by_day[0].source_session_ids,
            vec!["s-a".to_string(), "s-b".to_string()]
        );
        assert_eq!(by_day[0].token_estimate, 42);

        assert!(repo.list_by_day("1999-01-01").unwrap().is_empty());
    }

    #[test]
    fn summary_repo_delete_removes_one_row_by_id() {
        let db = test_db();
        let repo = SummaryRepo::new(db);
        for id in ["a", "b"] {
            repo.upsert(&StoredSummary {
                id: id.to_string(),
                day: "2026-11-25".to_string(),
                content: "x".to_string(),
                source_session_ids: vec![],
                token_estimate: 0,
                created_at: 1,
            })
            .unwrap();
        }
        assert!(repo.delete("a").unwrap());
        assert!(!repo.delete("a").unwrap());
        assert_eq!(repo.count().unwrap(), 1);
        assert_eq!(repo.list_recent(10).unwrap()[0].id, "b");
    }

    #[test]
    fn journal_repo_delete_only_removes_the_named_entry() {
        let db = test_db();
        let repo = JournalRepo::new(db);
        let gone = repo.append("note", "forget me", None).unwrap();
        let kept = repo.append("note", "keep me", None).unwrap();
        assert!(repo.delete(&gone).unwrap());
        assert!(!repo.delete(&gone).unwrap());
        assert_eq!(repo.count().unwrap(), 1);
        assert_eq!(repo.list_recent(10).unwrap()[0].id, kept);
    }

    #[test]
    fn summary_repo_prune_keeps_newest_365_distinct_days() {
        let db = test_db();
        let repo = SummaryRepo::new(db);
        // 400 distinct days: 2024-000 .. 2024-399 (fixed-width keys sort lexically).
        for i in 0..400 {
            repo.insert(&StoredSummary {
                id: format!("s-{i:03}"),
                day: format!("2024-{i:03}"),
                content: format!("day {i}"),
                source_session_ids: vec![],
                token_estimate: 1,
                created_at: i64::from(i),
            })
            .unwrap();
        }
        // A second summary on the newest day must survive the prune.
        repo.insert(&StoredSummary {
            id: "dup".to_string(),
            day: "2024-399".to_string(),
            content: "dup".to_string(),
            source_session_ids: vec![],
            token_estimate: 1,
            created_at: 1000,
        })
        .unwrap();
        assert_eq!(repo.count().unwrap(), 401);

        let deleted = repo.prune_over_365_days().unwrap();
        assert_eq!(deleted, 35);
        assert_eq!(repo.count().unwrap(), 366);
        assert_eq!(repo.list_by_day("2024-034").unwrap().len(), 0);
        assert_eq!(repo.list_by_day("2024-035").unwrap().len(), 1);
        assert_eq!(repo.list_by_day("2024-399").unwrap().len(), 2);
    }

    #[test]
    fn journal_repo_appends_and_reads_back() {
        let db = test_db();
        let repo = JournalRepo::new(db);

        assert!(repo.append("bogus", "x", None).is_err());
        assert!(repo.append("note", "   ", None).is_err());

        let id1 = repo.append("note", "first", None).unwrap();
        let id2 = repo
            .append("milestone", "second", Some(&[0.5_f32, 1.25, -0.75]))
            .unwrap();
        let id3 = repo.append("dream", "third", None).unwrap();
        let id4 = repo.append("summary", "fourth", None).unwrap();

        assert_eq!(repo.count().unwrap(), 4);

        let recent = repo.list_recent(2).unwrap();
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[0].id, id4);
        assert_eq!(recent[1].id, id3);

        let all = repo.list_between(0, i64::MAX, 10).unwrap();
        assert_eq!(all.len(), 4);
        assert_eq!(all[0].id, id1);
        assert_eq!(all[1].id, id2);
        assert_eq!(all[3].id, id4);
        assert_eq!(all[1].embedding, Some(vec![0.5_f32, 1.25, -0.75]));
        assert_eq!(all[0].embedding, None);
        assert_eq!(all[0].kind, "note");
        // Append-only rows are never mutated: updated_at == created_at.
        assert!(all.iter().all(|e| e.updated_at == e.created_at));

        // Far-future window excludes everything.
        assert!(repo
            .list_between(i64::MAX - 1, i64::MAX, 10)
            .unwrap()
            .is_empty());
        // Limited windows respect the limit.
        assert_eq!(repo.list_between(0, i64::MAX, 2).unwrap().len(), 2);
    }

    #[test]
    fn new_row_id_is_unique_in_a_tight_loop() {
        // Regression: the old time+pid scheme collided within a single clock
        // tick, causing INSERT to fail UNIQUE and lose the row.
        use std::collections::HashSet;
        let ids: HashSet<String> = (0..20_000).map(|_| new_row_id()).collect();
        assert_eq!(ids.len(), 20_000, "new_row_id() produced duplicate ids");
    }

    #[test]
    fn journal_append_many_in_tight_loop_persists_every_row() {
        // End-to-end: rapid appends must not silently fail on a duplicate key.
        let repo = JournalRepo::new(test_db());
        for i in 0..500 {
            repo.append("note", &format!("entry {i}"), None).unwrap();
        }
        assert_eq!(repo.count().unwrap(), 500);
    }

    #[test]
    fn session_search_case_insensitive_escaped_and_limited() {
        let db = test_db();
        let sessions = SessionRepo::new(db);
        sessions.create("a", "Rust UI Megathread").unwrap();
        sessions.create("b", "rust notes").unwrap();
        sessions.create("c", "100% complete").unwrap();
        sessions.create("d", "under_score").unwrap();
        sessions.create("e", "unrelated").unwrap();

        assert_eq!(sessions.search("rust").unwrap().len(), 2);
        assert_eq!(sessions.search("RUST").unwrap().len(), 2);
        assert_eq!(sessions.search("").unwrap().len(), 0);
        assert_eq!(sessions.search("   ").unwrap().len(), 0);
        // LIKE wildcards in the query match literally.
        assert_eq!(sessions.search("100%").unwrap().len(), 1);
        assert_eq!(sessions.search("%").unwrap().len(), 1);
        assert_eq!(sessions.search("under_score").unwrap().len(), 1);
        assert_eq!(sessions.search("_").unwrap().len(), 1);
        assert_eq!(sessions.search("zzz").unwrap().len(), 0);
    }

    #[test]
    fn session_search_caps_at_50_rows() {
        let db = test_db();
        let sessions = SessionRepo::new(db);
        for i in 0..55 {
            sessions
                .create(&format!("s-{i:02}"), &format!("common topic {i:02}"))
                .unwrap();
        }
        assert_eq!(sessions.search("common topic").unwrap().len(), 50);
    }

    #[test]
    fn migration_v3_memory_embeddings_applies_and_is_idempotent() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("v3.sqlite");
        {
            let db = Database::open(&path).expect("open db");
            let version: i32 = db
                .with_connection(|c| Ok(c.query_row("PRAGMA user_version", [], |row| row.get(0))?))
                .expect("read user_version");
            assert_eq!(version, 7);
            let table_count: i64 = db
                .with_connection(|c| {
                    Ok(c.query_row(
                        "select count(*) from sqlite_master where type = 'table'
                         and name in ('memory_embeddings', 'journal_entries', 'summaries', 'scrub_runs')",
                        [],
                        |row| row.get(0),
                    )?)
                })
                .expect("inspect sqlite_master");
            assert_eq!(table_count, 4);
            MemoryEmbeddingRepo::new(db)
                .upsert(&MemoryEmbeddingRecord {
                    id: "j1".to_string(),
                    kind: "journal".to_string(),
                    content: "embedded".to_string(),
                    vector: vec![0.1, 0.2, 0.3],
                    created_at: 5,
                })
                .expect("upsert");
        }
        // Reopen applies migrations idempotently and preserves rows.
        let db = Database::open(&path).expect("reopen");
        let rows = MemoryEmbeddingRepo::new(db)
            .list_latest(10, None)
            .expect("list");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].vector, vec![0.1_f32, 0.2, 0.3]);
    }

    #[test]
    fn memory_embedding_repo_upsert_list_filter_delete() {
        let db = test_db();
        let repo = MemoryEmbeddingRepo::new(db);
        for (id, kind, created_at) in [
            ("j1", "journal", 10_i64),
            ("summary:2026-11-09", "summary", 20_i64),
            ("j2", "journal", 30_i64),
        ] {
            repo.upsert(&MemoryEmbeddingRecord {
                id: id.to_string(),
                kind: kind.to_string(),
                content: format!("content of {id}"),
                vector: vec![1.0, 0.0],
                created_at,
            })
            .expect("upsert");
        }
        assert_eq!(repo.count().unwrap(), 3);
        let journals = repo.list_latest(10, Some("journal")).unwrap();
        assert_eq!(
            journals.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(),
            vec!["j2", "j1"]
        );
        // Upsert overwrites by id.
        repo.upsert(&MemoryEmbeddingRecord {
            id: "j1".to_string(),
            kind: "journal".to_string(),
            content: "updated".to_string(),
            vector: vec![0.0, 1.0],
            created_at: 40,
        })
        .unwrap();
        let all = repo.list_latest(10, None).unwrap();
        assert_eq!(all[0].id, "j1");
        assert_eq!(all[0].content, "updated");
        assert!(repo.delete("j1").unwrap());
        assert!(!repo.delete("j1").unwrap());
        assert_eq!(repo.count().unwrap(), 2);
    }

    #[test]
    fn list_missing_sources_finds_unindexed_journal_and_summary_rows() {
        let db = test_db();
        let journal_id = JournalRepo::new(db.clone())
            .append("note", "the user's cat is named Miso", None)
            .expect("append journal");
        SummaryRepo::new(db.clone())
            .insert(&StoredSummary {
                id: "sum1".to_string(),
                day: "2026-11-10".to_string(),
                content: "discussed Miso".to_string(),
                source_session_ids: vec!["s1".to_string()],
                token_estimate: 4,
                created_at: 10,
            })
            .expect("insert summary");
        let repo = MemoryEmbeddingRepo::new(db);
        let missing = repo.list_missing_sources().expect("missing");
        let ids: Vec<&str> = missing.iter().map(|m| m.id.as_str()).collect();
        assert!(ids.contains(&journal_id.as_str()), "missing: {ids:?}");
        assert!(ids.contains(&"summary:sum1"), "missing: {ids:?}");
        // Backfill both, then nothing is missing.
        for m in &missing {
            repo.upsert(&MemoryEmbeddingRecord {
                id: m.id.clone(),
                kind: m.kind.clone(),
                content: m.content.clone(),
                vector: vec![1.0],
                created_at: 100,
            })
            .expect("upsert");
        }
        assert!(repo
            .list_missing_sources()
            .expect("missing again")
            .is_empty());
    }

    // Contract: `SummaryRepo::upsert` replaces a same-id block in place, so a
    // re-sent block never fails on the primary key and never duplicates.
    #[test]
    fn summary_repo_upsert_replaces_by_id() {
        let db = test_db();
        let repo = SummaryRepo::new(db);
        repo.upsert(&StoredSummary {
            id: "sum-1".to_string(),
            day: "2026-11-10".to_string(),
            content: "first".to_string(),
            source_session_ids: vec!["s1".to_string()],
            token_estimate: 4,
            created_at: 10,
        })
        .expect("first upsert");
        repo.upsert(&StoredSummary {
            id: "sum-1".to_string(),
            day: "2026-11-10".to_string(),
            content: "second".to_string(),
            source_session_ids: vec![],
            token_estimate: 9,
            created_at: 20,
        })
        .expect("same-id upsert replaces");

        assert_eq!(repo.count().unwrap(), 1);
        let rows = repo.list_by_day("2026-11-10").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].content, "second");
        assert_eq!(rows[0].token_estimate, 9);
        assert_eq!(rows[0].created_at, 20);
        assert!(rows[0].source_session_ids.is_empty());
    }

    #[test]
    fn list_missing_sources_keys_summaries_by_id_not_day() {
        let db = test_db();
        let summaries = SummaryRepo::new(db.clone());
        for (id, content) in [
            ("sum-a", "first summary for the day"),
            ("sum-b", "second summary for the day"),
        ] {
            summaries
                .insert(&StoredSummary {
                    id: id.to_string(),
                    day: "2026-11-10".to_string(),
                    content: content.to_string(),
                    source_session_ids: vec![],
                    token_estimate: 4,
                    created_at: 10,
                })
                .expect("insert summary");
        }
        let repo = MemoryEmbeddingRepo::new(db);
        let missing = repo.list_missing_sources().expect("missing");
        let mut summaries: Vec<(&str, &str)> = missing
            .iter()
            .filter(|m| m.kind == "summary")
            .map(|m| (m.id.as_str(), m.content.as_str()))
            .collect();
        summaries.sort_unstable();
        assert_eq!(
            summaries,
            vec![
                ("summary:sum-a", "first summary for the day"),
                ("summary:sum-b", "second summary for the day"),
            ],
            "two summaries on one day must get distinct embedding ids"
        );
    }

    #[test]
    fn card_metadata_defaults_to_false_and_survives_reopen() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("card-metadata.sqlite");

        let db = Database::open(&path).expect("open db");
        let repo = CardMetadataRepo::new(db.clone());
        assert_eq!(repo.get("never-seen").unwrap(), CardMetadata::default());

        repo.set("card-1", true, false).unwrap();
        assert_eq!(
            repo.get("card-1").unwrap(),
            CardMetadata {
                liked: true,
                bookmarked: false,
            }
        );

        repo.set("card-1", false, true).unwrap();
        assert_eq!(
            repo.get("card-1").unwrap(),
            CardMetadata {
                liked: false,
                bookmarked: true,
            }
        );
        drop(db);

        let reopened = Database::open(&path).expect("reopen db");
        assert_eq!(
            CardMetadataRepo::new(reopened).get("card-1").unwrap(),
            CardMetadata {
                liked: false,
                bookmarked: true,
            },
            "flags must survive a restart of the daemon store"
        );
    }

    #[test]
    fn migration_v6_rebuilds_legacy_card_metadata_without_updated_at() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("legacy-card.sqlite");

        // Simulate a partially-migrated beta DB: card_metadata has card_id,
        // liked, bookmarked but NOT updated_at.
        {
            let conn = rusqlite::Connection::open(&path).expect("open raw conn");
            conn.execute_batch(
                "create table card_metadata (
                    card_id text primary key,
                    liked integer not null default 0,
                    bookmarked integer not null default 0
                 );",
            )
            .expect("create legacy table");
            conn.execute(
                "insert into card_metadata (card_id, liked, bookmarked) values (?1, ?2, ?3)",
                rusqlite::params!["legacy-card", 1_i64, 0_i64],
            )
            .expect("insert legacy row");
            conn.pragma_update(None, "user_version", 5_i32)
                .expect("set v5");
        }

        // Reopen with anima-store: migration v6 should rebuild the table.
        let db = Database::open(&path).expect("reopen and migrate");

        // Row is preserved with updated_at = 0.
        let repo = CardMetadataRepo::new(db.clone());
        let metadata = repo.get("legacy-card").expect("get legacy card");
        assert!(metadata.liked);
        assert!(!metadata.bookmarked);

        // Verify updated_at is 0.
        let updated_at: i64 = db
            .with_connection(|conn| {
                Ok(conn.query_row(
                    "select updated_at from card_metadata where card_id = ?1",
                    rusqlite::params!["legacy-card"],
                    |row| row.get(0),
                )?)
            })
            .expect("read updated_at");
        assert_eq!(updated_at, 0, "missing updated_at defaults to 0");
    }

    #[test]
    fn card_metadata_set_rejects_older_write_loudly() {
        let db = test_db();
        let repo = CardMetadataRepo::new(db.clone());
        repo.set_at("card-1", true, false, 1_000).unwrap();

        // An older event from another process must not revert the stored row.
        let err = repo
            .set_at("card-1", false, true, 999)
            .expect_err("older write rejected");
        assert!(err.to_string().contains("card-1"), "error: {err:#}");
        assert_eq!(
            repo.get("card-1").unwrap(),
            CardMetadata {
                liked: true,
                bookmarked: false,
            }
        );

        // Equal timestamp is last-writer-wins, like SettingsRepo::set.
        repo.set_at("card-1", false, true, 1_000).unwrap();
        assert_eq!(
            repo.get("card-1").unwrap(),
            CardMetadata {
                liked: false,
                bookmarked: true,
            }
        );
    }

    #[test]
    fn migration_v6_preserves_legacy_rows_with_mixed_flag_columns() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("legacy-mixed-card.sqlite");
        {
            let conn = rusqlite::Connection::open(&path).expect("open raw conn");
            conn.execute_batch(
                "create table card_metadata (
                    card_id text primary key,
                    bookmarked integer not null default 0,
                    updated_at integer not null default 500
                 );",
            )
            .expect("create legacy table");
            conn.execute(
                "insert into card_metadata (card_id, bookmarked, updated_at) values (?1, ?2, ?3)",
                rusqlite::params!["legacy-card", 1_i64, 500_i64],
            )
            .expect("insert legacy row");
            conn.pragma_update(None, "user_version", 5_i32)
                .expect("set v5");
        }

        let db = Database::open(&path).expect("reopen and migrate");
        let repo = CardMetadataRepo::new(db.clone());
        let metadata = repo.get("legacy-card").expect("get legacy card");
        assert!(!metadata.liked, "missing flag defaults to false");
        assert!(metadata.bookmarked, "surviving flag is preserved");

        // The preserved timestamp still participates in the LWW guard.
        let err = repo
            .set_at("legacy-card", true, false, 499)
            .expect_err("older write rejected");
        assert!(err.to_string().contains("legacy-card"), "error: {err:#}");
        repo.set_at("legacy-card", true, false, 500).unwrap();
        assert_eq!(
            repo.get("legacy-card").unwrap(),
            CardMetadata {
                liked: true,
                bookmarked: false,
            }
        );
    }

    #[test]
    fn migration_v6_rebuilds_wrong_column_types_and_preserves_usable_flags() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("legacy-text-card.sqlite");
        {
            let conn = rusqlite::Connection::open(&path).expect("open raw conn");
            conn.execute_batch(
                "create table card_metadata (
                    card_id text primary key,
                    liked text not null default '0',
                    bookmarked integer not null default 0,
                    updated_at integer not null default 10
                 );",
            )
            .expect("create wrong-type table");
            conn.execute(
                "insert into card_metadata (card_id, liked, bookmarked, updated_at)
                 values (?1, ?2, ?3, ?4)",
                rusqlite::params!["legacy-card", "not-a-boolean", 1_i64, 10_i64],
            )
            .expect("insert legacy row");
            conn.pragma_update(None, "user_version", 5_i32)
                .expect("set v5");
        }

        let db = Database::open(&path).expect("reopen and migrate");
        let columns: Vec<(String, String)> = db
            .with_connection(|conn| {
                let mut stmt = conn.prepare("pragma table_info(card_metadata)")?;
                let rows = stmt
                    .query_map([], |row| {
                        Ok((row.get::<_, String>(1)?, row.get::<_, String>(2)?))
                    })?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                Ok(rows)
            })
            .expect("read canonical schema");
        assert_eq!(columns[1], ("liked".to_string(), "INTEGER".to_string()));

        // A non-numeric legacy flag cannot be interpreted: the card and its
        // usable bookmark flag still survive instead of the whole row vanishing.
        let metadata = CardMetadataRepo::new(db.clone())
            .get("legacy-card")
            .expect("get legacy card");
        assert!(!metadata.liked);
        assert!(metadata.bookmarked);
    }

    #[test]
    fn card_repo_round_trips_document_verbatim() {
        let db = test_db();
        let repo = CardRepo::new(db.clone());
        let doc = r#"{"name":"Lain","extensions":{"airi":{"modules":{"memory":true}},"unknown":"x"},"unknownTopLevel":42}"#;
        let card = repo.insert("c1", doc, "Lain").unwrap();
        let got = repo.get("c1").unwrap().unwrap();
        assert_eq!(got.id, "c1");
        assert_eq!(got.name, "Lain");
        assert_eq!(got.document, doc);
        assert_eq!(got.created_at, card.created_at);
        assert_eq!(got.updated_at, card.updated_at);
        let recent = repo.list_recent(10).unwrap();
        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].document, doc);
    }

    #[test]
    fn card_repo_list_recent_orders_newest_first_and_honours_limit() {
        let db = test_db();
        let repo = CardRepo::new(db);
        for i in 1..=3 {
            repo.insert(&format!("c{i}"), &format!("doc {i}"), &format!("Card {i}"))
                .unwrap();
        }
        let recent = repo.list_recent(2).unwrap();
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[0].id, "c3");
        assert_eq!(recent[1].id, "c2");
        assert!(repo.list_recent(0).unwrap().is_empty());
    }

    #[test]
    fn card_repo_unique_name_appends_incrementing_suffix() {
        let db = test_db();
        let repo = CardRepo::new(db);
        assert_eq!(repo.unique_name("Lain").unwrap(), "Lain");
        assert!(!repo.name_exists("Lain").unwrap());
        repo.insert("a", "{}", "Lain").unwrap();
        repo.insert("b", "{}", "Lain (2)").unwrap();
        assert!(repo.name_exists("Lain").unwrap());
        assert!(repo.name_exists("Lain (2)").unwrap());
        assert_eq!(repo.unique_name("Lain").unwrap(), "Lain (3)");
    }

    #[test]
    fn card_repo_update_replaces_document_and_stamps_now() {
        let db = test_db();
        let repo = CardRepo::new(db);
        let card = repo.insert("c1", "old doc", "Old").unwrap();
        let new_doc = "new doc";
        assert!(repo.update("c1", new_doc, "New").unwrap());
        let got = repo.get("c1").unwrap().unwrap();
        assert_eq!(got.document, new_doc);
        assert_eq!(got.name, "New");
        assert!(got.updated_at >= got.created_at);
        assert!(got.updated_at >= card.updated_at);
        assert!(!repo.update("missing", "x", "X").unwrap());
    }

    #[test]
    fn card_repo_delete_is_idempotent() {
        let db = test_db();
        let repo = CardRepo::new(db);
        repo.insert("c1", "doc", "Card").unwrap();
        assert!(repo.delete("c1").unwrap());
        assert!(!repo.delete("c1").unwrap());
        assert!(repo.get("c1").unwrap().is_none());
    }

    #[test]
    fn migration_from_v6_adds_cards_and_keeps_metadata() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("v6.sqlite");
        {
            let conn = rusqlite::Connection::open(&path).expect("open raw conn");
            conn.execute_batch(
                "create table card_metadata (
                    card_id text primary key,
                    liked integer not null default 0,
                    bookmarked integer not null default 0,
                    updated_at integer not null
                );
                insert into card_metadata (card_id, liked, bookmarked, updated_at) values ('c1', 1, 0, 5);",
            )
            .expect("seed v6");
            conn.pragma_update(None, "user_version", 6_i32)
                .expect("set v6");
        }
        let db = Database::open(&path).expect("reopen and migrate");
        let version: i32 = db
            .with_connection(|c| Ok(c.query_row("PRAGMA user_version", [], |row| row.get(0))?))
            .expect("read user_version");
        assert_eq!(version, 7);
        let exists: i64 = db
            .with_connection(|c| {
                Ok(c.query_row(
                    "select count(*) from sqlite_master where type='table' and name='cards'",
                    [],
                    |row| row.get(0),
                )?)
            })
            .expect("inspect");
        assert_eq!(exists, 1);
        assert!(CardRepo::new(db.clone())
            .list_recent(10)
            .unwrap()
            .is_empty());
        assert!(CardMetadataRepo::new(db).get("c1").unwrap().liked);
    }

    #[test]
    fn cards_table_is_created_only_once_and_reopen_is_idempotent() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("reopen-cards.sqlite");
        let db = Database::open(&path).expect("open db");
        CardRepo::new(db.clone())
            .insert("c1", "doc", "Card")
            .unwrap();
        drop(db);
        let db = Database::open(&path).expect("reopen db");
        let version: i32 = db
            .with_connection(|c| Ok(c.query_row("PRAGMA user_version", [], |row| row.get(0))?))
            .expect("read user_version");
        assert_eq!(version, 7);
        assert_eq!(CardRepo::new(db).get("c1").unwrap().unwrap().name, "Card");
    }
}

// ============================================================================
// Scrub runs (data-vault session-media optimization log, migration v4)
// ============================================================================

/// A record of one scrub pass over the chat history.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredScrubRun {
    /// Unique run id.
    pub id: String,
    /// Start timestamp (ms).
    pub started_at: i64,
    /// Sessions scanned that contained at least one inline image.
    pub sessions_scanned: u64,
    /// Number of inline images extracted to storage.
    pub images_extracted: u64,
    /// Total decoded bytes extracted.
    pub bytes_extracted: u64,
    /// Path of the pre-scrub backup archive, when one was requested.
    pub backup_path: Option<String>,
}

/// Repository for [`StoredScrubRun`].
#[derive(Clone)]
pub struct ScrubRunRepo {
    db: Database,
}

impl ScrubRunRepo {
    /// Create the repository.
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// Record a completed scrub run.
    pub fn insert(&self, run: &StoredScrubRun) -> Result<()> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        conn.execute(
            "insert into scrub_runs (id, started_at, sessions_scanned, images_extracted, bytes_extracted, backup_path)
             values (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                run.id,
                run.started_at,
                run.sessions_scanned,
                run.images_extracted,
                run.bytes_extracted,
                run.backup_path,
            ],
        )?;
        Ok(())
    }

    /// Most recent scrub runs, newest first.
    pub fn list_recent(&self, limit: usize) -> Result<Vec<StoredScrubRun>> {
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let mut stmt = conn.prepare(
            "select id, started_at, sessions_scanned, images_extracted, bytes_extracted, backup_path
             from scrub_runs order by started_at desc, rowid desc limit ?1",
        )?;
        let rows = stmt
            .query_map(params![limit], |row| {
                Ok(StoredScrubRun {
                    id: row.get(0)?,
                    started_at: row.get(1)?,
                    sessions_scanned: row.get::<_, i64>(2)? as u64,
                    images_extracted: row.get::<_, i64>(3)? as u64,
                    bytes_extracted: row.get::<_, i64>(4)? as u64,
                    backup_path: row.get(5)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    }
}

// ============================================================================
// Card metadata (local liked/bookmarked flags owned by the daemon)
// ============================================================================

/// Local, daemon-owned metadata for one card.
///
/// An absent row is equivalent to [`CardMetadata::default`]: both flags false.
/// There is deliberately no user id or social count here — likes/bookmarks are
/// one-local-user state, not a hosted community graph.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CardMetadata {
    /// Whether the local user liked the card.
    pub liked: bool,
    /// Whether the local user bookmarked the card.
    pub bookmarked: bool,
}

/// Repository for [`CardMetadata`].
#[derive(Clone)]
pub struct CardMetadataRepo {
    db: Database,
}

impl CardMetadataRepo {
    /// Create the repository.
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// Read a card's metadata; missing rows return the all-false default.
    pub fn get(&self, card_id: &str) -> Result<CardMetadata> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let row = conn
            .query_row(
                "select liked, bookmarked from card_metadata where card_id = ?1",
                params![card_id],
                |row| {
                    Ok(CardMetadata {
                        liked: row.get::<_, i64>(0)? != 0,
                        bookmarked: row.get::<_, i64>(1)? != 0,
                    })
                },
            )
            .optional()?;
        Ok(row.unwrap_or_default())
    }

    /// Upsert a card's metadata with explicit flag values, stamped with now.
    ///
    /// The booleans are applied verbatim: a stale client must never turn into
    /// an unintended toggle. Writes older than the row's `updated_at` are
    /// rejected loudly, matching [`SettingsRepo::set`]; same-millisecond
    /// writes are last-writer-wins. Callers with a source timestamp should use
    /// [`Self::set_at`] to make the ordering explicit.
    pub fn set(&self, card_id: &str, liked: bool, bookmarked: bool) -> Result<()> {
        self.set_at(card_id, liked, bookmarked, now_ms())
    }
    /// Update a card's metadata with an explicit logical timestamp.
    ///
    /// Mirrors [`SettingsRepo::set`]: a write older than the stored
    /// `updated_at` is rejected loudly instead of silently reverting a newer
    /// value written by another process sharing the same database. Equal
    /// timestamps are last-writer-wins. Use this overload when a caller has a
    /// timestamp from the source event; otherwise [`Self::set`] stamps now.
    pub fn set_at(
        &self,
        card_id: &str,
        liked: bool,
        bookmarked: bool,
        updated_at_ms: i64,
    ) -> Result<()> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let affected = conn.execute(
            "insert into card_metadata (card_id, liked, bookmarked, updated_at)
             values (?1, ?2, ?3, ?4)
             on conflict(card_id) do update set
                 liked = excluded.liked,
                 bookmarked = excluded.bookmarked,
                 updated_at = excluded.updated_at
             where excluded.updated_at >= card_metadata.updated_at",
            params![card_id, liked as i64, bookmarked as i64, updated_at_ms],
        )?;
        anyhow::ensure!(
            affected > 0,
            "card metadata `{card_id}` was not written: a newer value already exists"
        );
        Ok(())
    }
}

// ============================================================================
// Card documents (migration v7)
// ============================================================================

/// A locally authored character card document.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredCard {
    /// Card id.
    pub id: String,
    /// Denormalized card name for listing.
    pub name: String,
    /// Verbatim AiriCard JSON text.
    pub document: String,
    /// Created timestamp (ms).
    pub created_at: i64,
    /// Updated timestamp (ms).
    pub updated_at: i64,
}

/// Card repository.
#[derive(Clone)]
pub struct CardRepo {
    db: Database,
}

impl CardRepo {
    /// Create card repository.
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// List most recent cards by updated_at.
    pub fn list_recent(&self, limit: usize) -> Result<Vec<StoredCard>> {
        let limit = i64::try_from(limit).unwrap_or(i64::MAX);
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let mut stmt = conn.prepare(
            "select id, name, document, created_at, updated_at from cards order by updated_at desc, rowid desc limit ?1",
        )?;
        let rows = stmt.query_map(params![limit], |row| {
            Ok(CardRow {
                id: row.get(0)?,
                name: row.get(1)?,
                document: row.get(2)?,
                created_at: row.get(3)?,
                updated_at: row.get(4)?,
            })
        })?;
        rows.map(|r| r.map_err(Into::into).and_then(row_to_card))
            .collect()
    }

    /// Get a card by id.
    pub fn get(&self, id: &str) -> Result<Option<StoredCard>> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let row = conn
            .query_row(
                "select id, name, document, created_at, updated_at from cards where id = ?1",
                params![id],
                |row| {
                    Ok(CardRow {
                        id: row.get(0)?,
                        name: row.get(1)?,
                        document: row.get(2)?,
                        created_at: row.get(3)?,
                        updated_at: row.get(4)?,
                    })
                },
            )
            .optional()?;
        row.map(row_to_card).transpose()
    }

    /// Insert a card document under a caller-minted id (`id` must be unique; a duplicate is a loud insert error).
    pub fn insert(&self, id: &str, document: &str, name: &str) -> Result<StoredCard> {
        let ts = now_ms();
        let card = StoredCard {
            id: id.to_string(),
            name: name.to_string(),
            document: document.to_string(),
            created_at: ts,
            updated_at: ts,
        };
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        conn.execute(
            "insert into cards (id, name, document, created_at, updated_at) values (?1, ?2, ?3, ?4, ?5)",
            params![card.id, card.name, card.document, card.created_at, card.updated_at],
        )?;
        Ok(card)
    }

    /// Replace a card's document and denormalized name, stamped with now.
    pub fn update(&self, id: &str, document: &str, name: &str) -> Result<bool> {
        let ts = now_ms();
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let n = conn.execute(
            "update cards set name = ?1, document = ?2, updated_at = ?3 where id = ?4",
            params![name, document, ts, id],
        )?;
        Ok(n > 0)
    }

    /// Delete a card.
    pub fn delete(&self, id: &str) -> Result<bool> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let n = conn.execute("delete from cards where id = ?1", params![id])?;
        conn.execute("delete from card_metadata where card_id = ?1", params![id])?;
        Ok(n > 0)
    }

    /// Whether a card with the given name already exists.
    pub fn name_exists(&self, name: &str) -> Result<bool> {
        let conn = self.db.conn.lock().expect("database mutex poisoned");
        let n: i64 = conn.query_row(
            "select count(*) from cards where name = ?1",
            params![name],
            |row| row.get(0),
        )?;
        Ok(n > 0)
    }

    /// Produce a unique name, appending a suffix when needed.
    pub fn unique_name(&self, name: &str) -> Result<String> {
        if !self.name_exists(name)? {
            return Ok(name.to_string());
        }
        let mut i = 2;
        loop {
            let candidate = format!("{name} ({i})");
            if !self.name_exists(&candidate)? {
                return Ok(candidate);
            }
            i += 1;
        }
    }
}

struct CardRow {
    id: String,
    name: String,
    document: String,
    created_at: i64,
    updated_at: i64,
}

fn row_to_card(row: CardRow) -> Result<StoredCard> {
    Ok(StoredCard {
        id: row.id,
        name: row.name,
        document: row.document,
        created_at: row.created_at,
        updated_at: row.updated_at,
    })
}
