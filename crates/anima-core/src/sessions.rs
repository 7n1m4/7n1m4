// SPDX-License-Identifier: GPL-3.0-or-later
#![deny(missing_docs)]

//! Session export/import helpers.
//!
//! JSON Lines (JSONL) snapshots of a session and its messages. Pure SQLite
//! access: no file or network I/O (callers decide where the payload goes).

use anima_store::{Database, MessageRepo, SessionRepo, StoredMessage, StoredSession};
use anyhow::{Context, Result};
use rusqlite::{params, OptionalExtension, TransactionBehavior};
use std::collections::HashMap;

/// Parse a stored metadata column, rejecting corrupt JSON instead of
/// silently treating it as empty metadata (which would misreport a
/// duplicate as a conflict or overwrite data on a newer revision).
fn parse_metadata(raw: &str, what: &str) -> Result<serde_json::Value> {
    serde_json::from_str(raw).with_context(|| format!("invalid {what} metadata"))
}

fn metadata_from_row(
    raw: &str,
    what: &str,
    column: usize,
) -> std::result::Result<serde_json::Value, rusqlite::Error> {
    parse_metadata(raw, what).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(
            column,
            rusqlite::types::Type::Text,
            Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                e.to_string(),
            )),
        )
    })
}

/// Compare metadata as JSON values, ignoring object key order. `Value`'s
/// derived `Eq` on the default (B-tree) backend is insertion-order sensitive,
/// so semantically identical metadata could otherwise be reported as a
/// conflict.
fn metadata_eq(left: &serde_json::Value, right: &serde_json::Value) -> bool {
    fn canonical(value: &serde_json::Value) -> serde_json::Value {
        match value {
            serde_json::Value::Object(map) => {
                let mut entries: Vec<_> = map.iter().collect();
                entries.sort_by(|(a, _), (b, _)| a.cmp(b));
                serde_json::Value::Object(
                    entries
                        .into_iter()
                        .map(|(k, v)| (k.clone(), canonical(v)))
                        .collect(),
                )
            }
            serde_json::Value::Array(items) => {
                serde_json::Value::Array(items.iter().map(canonical).collect())
            }
            other => other.clone(),
        }
    }

    canonical(left) == canonical(right)
}

/// Hard ceiling on the bytes one [`export_jsonl`] call may return.
pub const EXPORT_MAX_BYTES: usize = 8 * 1024 * 1024;

/// Error returned when a session snapshot exceeds [`EXPORT_MAX_BYTES`].
pub const EXPORT_TOO_LARGE: &str = "session export exceeds the 8 MiB limit";

/// Outcome of a bounded export.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExportOutcome {
    /// Complete snapshot.
    Complete(String),
    /// Snapshot is larger than [`EXPORT_MAX_BYTES`]; nothing is returned.
    TooLarge {
        /// Total bytes the snapshot would need.
        bytes: u64,
    },
}

impl ExportOutcome {
    /// The JSONL payload, or an error naming the bound.
    pub fn into_jsonl(self) -> Result<String> {
        match self {
            Self::Complete(jsonl) => Ok(jsonl),
            Self::TooLarge { bytes } => anyhow::bail!("{EXPORT_TOO_LARGE} (needs {bytes} bytes)"),
        }
    }
}

/// Compare full snapshot state for the duplicate/conflict decision.
fn snapshots_equal(
    incoming: &Snapshot,
    existing_session: &StoredSession,
    existing_messages: &[StoredMessage],
) -> bool {
    let session = &incoming.session;
    if session.id != existing_session.id
        || session.title != existing_session.title
        || session.created_at != existing_session.created_at
        || session.updated_at != existing_session.updated_at
        || !metadata_eq(&session.metadata, &existing_session.metadata)
        || incoming.messages.len() != existing_messages.len()
    {
        return false;
    }
    // Compare by message id: snapshot lines and the local `order by
    // created_at, rowid` query may order the same messages differently.
    incoming.messages.iter().all(|incoming_message| {
        existing_messages
            .iter()
            .find(|existing_message| existing_message.id == incoming_message.id)
            .is_some_and(|existing_message| {
                incoming_message.session_id == existing_message.session_id
                    && incoming_message.role == existing_message.role
                    && incoming_message.content == existing_message.content
                    && incoming_message.created_at == existing_message.created_at
                    && metadata_eq(&incoming_message.metadata, &existing_message.metadata)
            })
    })
}

/// Export a session and its messages as JSON Lines in bounded form.
///
/// Returns either an [`ExportOutcome::Complete`](ExportOutcome::Complete)
/// snapshot or an [`ExportOutcome::TooLarge`](ExportOutcome::TooLarge) when the
/// snapshot exceeds [`EXPORT_MAX_BYTES`]; never a partial payload.
pub fn export_bounded(db: &Database, session_id: &str) -> Result<ExportOutcome> {
    const EXPORT_PAGE: usize = 256;

    let session = SessionRepo::new(db.clone())
        .get(session_id)?
        .with_context(|| format!("session not found: {session_id}"))?;
    let messages = MessageRepo::new(db.clone());

    let mut out = String::new();
    let mut total: u64 = 0;
    let header = serde_json::json!({ "type": "session", "session": session });
    let header_line = format!("{}\n", serde_json::to_string(&header)?);
    total += header_line.len() as u64;
    if total > EXPORT_MAX_BYTES as u64 {
        return Ok(ExportOutcome::TooLarge { bytes: total });
    }
    out.push_str(&header_line);

    let mut cursor: Option<(i64, i64)> = None;
    loop {
        let page = messages.list_page(session_id, EXPORT_PAGE, cursor)?;
        let short = page.len() < EXPORT_PAGE;
        for (message, rowid) in page {
            let created_at = message.created_at;
            let line = serde_json::json!({ "type": "message", "message": message });
            let msg_line = format!("{}\n", serde_json::to_string(&line)?);
            total += msg_line.len() as u64;
            if total > EXPORT_MAX_BYTES as u64 {
                return Ok(ExportOutcome::TooLarge { bytes: total });
            }
            out.push_str(&msg_line);
            cursor = Some((created_at, rowid));
        }
        if short {
            break;
        }
    }
    Ok(ExportOutcome::Complete(out))
}

/// Export a session and its messages as JSON Lines.
///
/// Errors when the session does not exist or exceeds [`EXPORT_MAX_BYTES`].
pub fn export_jsonl(db: &Database, session_id: &str) -> Result<String> {
    export_bounded(db, session_id)?.into_jsonl()
}

/// Outcome of importing a JSONL session snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImportStatus {
    /// Snapshot applied (new session or newer revision).
    Applied,
    /// Local session already has the same revision and content.
    Duplicate,
    /// Incoming revision is older than the local session.
    Older,
    /// Same revision but divergent content; local stays canonical.
    Conflict,
}

impl ImportStatus {
    /// Stable wire/status string.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Applied => "applied",
            Self::Duplicate => "duplicate",
            Self::Older => "older",
            Self::Conflict => "conflict",
        }
    }
}

/// Result of importing a JSONL session snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportOutcome {
    /// Applied status.
    pub status: ImportStatus,
    /// Revision (`sessions.updated_at`, ms) stored locally.
    pub revision: i64,
}

/// Parsed JSONL snapshot with deterministic message-ID dedupe.
#[derive(Debug, Clone)]
struct Snapshot {
    session: StoredSession,
    messages: Vec<StoredMessage>,
}

/// Import a JSONL snapshot produced by [`export_jsonl`].
///
/// Conflict policy: LWW by `session.updated_at`. A newer revision replaces
/// the local snapshot atomically; an identical equal-revision snapshot is a
/// no-op; an older or divergent equal-revision snapshot is rejected and the
/// local session stays canonical.
pub fn import_jsonl(db: &Database, jsonl: &str) -> Result<ImportOutcome> {
    let snapshot = parse_snapshot(jsonl)?;
    import_inner(db, snapshot)
}

/// Parse and normalize JSONL, deduplicating repeated message IDs.
///
/// If multiple lines have the same message ID, the last occurrence wins
/// (matching TS `new Map(entries)` semantics), preserving first-seen order.
fn parse_snapshot(jsonl: &str) -> Result<Snapshot> {
    let mut lines = jsonl.lines().filter(|line| !line.trim().is_empty());
    let header_line = lines.next().context("missing session header")?;
    let header: serde_json::Value =
        serde_json::from_str(header_line).context("invalid session header")?;
    if header.get("type").and_then(|v| v.as_str()) != Some("session") {
        anyhow::bail!("first line must be a session header");
    }
    let session: StoredSession = serde_json::from_value(
        header
            .get("session")
            .cloned()
            .context("missing session header body")?,
    )
    .context("invalid session header body")?;

    let mut messages = Vec::new();
    let mut index_by_id: HashMap<String, usize> = HashMap::new();
    for line in lines {
        let value: serde_json::Value =
            serde_json::from_str(line).context("invalid message line")?;
        if value.get("type").and_then(|v| v.as_str()) != Some("message") {
            anyhow::bail!("expected message line");
        }
        let message: StoredMessage = serde_json::from_value(
            value
                .get("message")
                .cloned()
                .context("missing message body")?,
        )
        .context("invalid message body")?;
        if message.session_id != session.id {
            anyhow::bail!("message session_id does not match header session");
        }
        if let Some(&idx) = index_by_id.get(&message.id) {
            messages[idx] = message;
        } else {
            index_by_id.insert(message.id.clone(), messages.len());
            messages.push(message);
        }
    }

    Ok(Snapshot { session, messages })
}

fn import_inner(db: &Database, snapshot: Snapshot) -> Result<ImportOutcome> {
    let session = snapshot.session;
    let messages = snapshot.messages;

    db.with_connection(|conn| {
        let tx = rusqlite::Transaction::new_unchecked(conn, TransactionBehavior::Immediate)?;

        // Read existing session row for LWW comparison.
        let existing: Option<StoredSession> = tx
            .query_row(
                "select id, title, created_at, updated_at, metadata from sessions where id = ?1",
                params![session.id],
                |row| {
                    let metadata_str: String = row.get(4)?;
                    Ok(StoredSession {
                        id: row.get(0)?,
                        title: row.get(1)?,
                        created_at: row.get(2)?,
                        updated_at: row.get(3)?,
                        metadata: metadata_from_row(&metadata_str, "session", 4)?,
                    })
                },
            )
            .optional()?;

        let Some(existing) = existing else {
            tx.execute(
                "insert into sessions (id, title, created_at, updated_at, metadata) values (?1, ?2, ?3, ?4, ?5)",
                params![
                    session.id,
                    session.title,
                    session.created_at,
                    session.updated_at,
                    serde_json::to_string(&session.metadata)?,
                ],
            )?;
            insert_messages(&tx, &messages)?;
            tx.commit()?;
            return Ok(ImportOutcome {
                status: ImportStatus::Applied,
                revision: session.updated_at,
            });
        };

        if session.updated_at < existing.updated_at {
            return Ok(ImportOutcome {
                status: ImportStatus::Older,
                revision: existing.updated_at,
            });
        }

        if session.updated_at == existing.updated_at {
            // Content equality ignores JSON object key order: semantically
            // identical metadata must not be reported as a conflict.
            let existing_messages = load_messages(&tx, &session.id)?;
            let incoming = Snapshot {
                session: session.clone(),
                messages: messages.clone(),
            };
            if snapshots_equal(&incoming, &existing, &existing_messages) {
                return Ok(ImportOutcome {
                    status: ImportStatus::Duplicate,
                    revision: existing.updated_at,
                });
            }
            return Ok(ImportOutcome {
                status: ImportStatus::Conflict,
                revision: existing.updated_at,
            });
        }

        // Newer revision: guarded update on observed updated_at.
        let changed = tx.execute(
            "update sessions set title = ?1, created_at = ?2, updated_at = ?3, metadata = ?4 \
             where id = ?5 and updated_at = ?6",
            params![
                session.title,
                session.created_at,
                session.updated_at,
                serde_json::to_string(&session.metadata)?,
                session.id,
                existing.updated_at,
            ],
        )?;
        if changed == 0 {
            anyhow::bail!("concurrent session modification detected");
        }

        tx.execute(
            "delete from messages where session_id = ?1",
            params![session.id],
        )?;
        insert_messages(&tx, &messages)?;
        tx.commit()?;

        Ok(ImportOutcome {
            status: ImportStatus::Applied,
            revision: session.updated_at,
        })
    })
}

fn insert_messages(tx: &rusqlite::Transaction<'_>, messages: &[StoredMessage]) -> Result<()> {
    for message in messages {
        tx.execute(
            "insert into messages (id, session_id, role, content, created_at, metadata) values (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                message.id,
                message.session_id,
                message.role,
                message.content,
                message.created_at,
                serde_json::to_string(&message.metadata)?,
            ],
        )?;
    }
    Ok(())
}

fn load_messages(tx: &rusqlite::Transaction<'_>, session_id: &str) -> Result<Vec<StoredMessage>> {
    let mut stmt = tx.prepare(
        "select id, session_id, role, content, created_at, metadata \
         from messages where session_id = ?1 order by created_at asc, rowid asc",
    )?;
    let rows = stmt.query_map(params![session_id], |row| {
        let metadata_str: String = row.get(5)?;
        Ok(StoredMessage {
            id: row.get(0)?,
            session_id: row.get(1)?,
            role: row.get(2)?,
            content: row.get(3)?,
            created_at: row.get(4)?,
            metadata: metadata_from_row(&metadata_str, "message", 5)?,
        })
    })?;
    let mut result = Vec::new();
    for row in rows {
        result.push(row?);
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn export_jsonl_emits_session_header_then_messages() {
        let dir = tempdir().expect("tempdir");
        let db = Database::open(&dir.path().join("export.sqlite")).expect("open db");
        let sessions = SessionRepo::new(db.clone());
        sessions.create("s1", "Export me").expect("create session");
        let messages = MessageRepo::new(db.clone());
        messages
            .insert(&anima_store::StoredMessage {
                id: "m1".to_string(),
                session_id: "s1".to_string(),
                role: "user".to_string(),
                content: "hello".to_string(),
                created_at: 10,
                metadata: serde_json::json!({}),
            })
            .expect("insert m1");
        messages
            .insert(&anima_store::StoredMessage {
                id: "m2".to_string(),
                session_id: "s1".to_string(),
                role: "assistant".to_string(),
                content: "hi there".to_string(),
                created_at: 20,
                metadata: serde_json::json!({"finishReason": "stop"}),
            })
            .expect("insert m2");

        let jsonl = export_jsonl(&db, "s1").expect("export");
        let lines: Vec<&str> = jsonl.lines().collect();
        assert_eq!(lines.len(), 3);

        let header: serde_json::Value = serde_json::from_str(lines[0]).expect("header parses");
        assert_eq!(header["type"], "session");
        assert_eq!(header["session"]["id"], "s1");
        assert_eq!(header["session"]["title"], "Export me");

        let first: serde_json::Value = serde_json::from_str(lines[1]).expect("message parses");
        assert_eq!(first["type"], "message");
        assert_eq!(first["message"]["role"], "user");
        assert_eq!(first["message"]["content"], "hello");

        let second: serde_json::Value = serde_json::from_str(lines[2]).expect("message parses");
        assert_eq!(second["message"]["role"], "assistant");
        assert_eq!(second["message"]["id"], "m2");

        assert!(jsonl.ends_with('\n'));
    }

    #[test]
    fn export_jsonl_errors_for_missing_session() {
        let dir = tempdir().expect("tempdir");
        let db = Database::open(&dir.path().join("export.sqlite")).expect("open db");
        let err = export_jsonl(&db, "nope").expect_err("missing session must error");
        assert!(format!("{err:#}").contains("nope"));
    }

    #[test]
    fn import_jsonl_round_trip_duplicate_older_and_newer() {
        let dir = tempdir().expect("tempdir");
        let source = Database::open(&dir.path().join("source.sqlite")).expect("source db");
        SessionRepo::new(source.clone())
            .create("s1", "Snapshot")
            .expect("create source session");
        MessageRepo::new(source.clone())
            .insert(&StoredMessage {
                id: "m1".to_string(),
                session_id: "s1".to_string(),
                role: "user".to_string(),
                content: "hello".to_string(),
                created_at: 10,
                metadata: serde_json::json!({}),
            })
            .expect("insert source message");
        let snapshot = export_jsonl(&source, "s1").expect("export source");

        let dest = Database::open(&dir.path().join("dest.sqlite")).expect("dest db");
        let imported = import_jsonl(&dest, &snapshot).expect("import new session");
        assert_eq!(imported.status, ImportStatus::Applied);
        assert_eq!(export_jsonl(&dest, "s1").expect("export dest"), snapshot);

        let duplicate = import_jsonl(&dest, &snapshot).expect("duplicate import");
        assert_eq!(duplicate.status, ImportStatus::Duplicate);

        let older = format!(
            "{}\n",
            serde_json::json!({
                "type": "session",
                "session": {
                    "id": "s1",
                    "title": "Older",
                    "created_at": 5,
                    "updated_at": 5,
                    "metadata": {},
                },
            })
        );
        let older = import_jsonl(&dest, &older).expect("older import");
        assert_eq!(older.status, ImportStatus::Older);
        assert_eq!(
            SessionRepo::new(dest.clone())
                .get("s1")
                .unwrap()
                .unwrap()
                .title,
            "Snapshot"
        );

        let newer = format!(
            "{}\n{}",
            serde_json::json!({
                "type": "session",
                "session": {
                    "id": "s1",
                    "title": "Newer",
                    "created_at": 10,
                    "updated_at": 20,
                    "metadata": {},
                },
            }),
            serde_json::json!({
                "type": "message",
                "message": {
                    "id": "m2",
                    "session_id": "s1",
                    "role": "assistant",
                    "content": "new content",
                    "created_at": 20,
                    "metadata": {},
                },
            }),
        );
        let newer = import_jsonl(&dest, &newer).expect("newer import");
        assert_eq!(newer.status, ImportStatus::Applied);
        assert_eq!(newer.revision, 20);
        assert_eq!(
            SessionRepo::new(dest.clone())
                .get("s1")
                .unwrap()
                .unwrap()
                .title,
            "Newer"
        );
        assert_eq!(
            MessageRepo::new(dest)
                .list("s1")
                .unwrap()
                .iter()
                .map(|m| m.content.as_str())
                .collect::<Vec<_>>(),
            vec!["new content"]
        );
    }

    #[test]
    fn import_jsonl_equal_revision_divergent_snapshot_is_conflict() {
        let dir = tempdir().expect("tempdir");
        let source = Database::open(&dir.path().join("source.sqlite")).expect("source db");
        SessionRepo::new(source.clone())
            .create("s1", "Snapshot")
            .expect("create source session");
        MessageRepo::new(source.clone())
            .insert(&StoredMessage {
                id: "m1".to_string(),
                session_id: "s1".to_string(),
                role: "user".to_string(),
                content: "hello".to_string(),
                created_at: 10,
                metadata: serde_json::json!({}),
            })
            .expect("insert source message");
        let snapshot = export_jsonl(&source, "s1").expect("export source");

        let dest = Database::open(&dir.path().join("dest.sqlite")).expect("dest db");
        import_jsonl(&dest, &snapshot).expect("seed dest");

        let divergent = snapshot.replace("hello", "divergent");
        let conflict = import_jsonl(&dest, &divergent).expect("conflict import");
        assert_eq!(conflict.status, ImportStatus::Conflict);
        assert_eq!(export_jsonl(&dest, "s1").expect("export dest"), snapshot);
    }

    #[test]
    fn import_jsonl_rejects_malformed_snapshot() {
        let dir = tempdir().expect("tempdir");
        let db = Database::open(&dir.path().join("bad.sqlite")).expect("db");
        let err = import_jsonl(&db, "not json\n").expect_err("malformed snapshot");
        assert!(format!("{err:#}").contains("invalid session header"));
    }

    #[test]
    fn import_jsonl_dedupes_repeated_message_ids() {
        let dir = tempdir().expect("tempdir");
        let db = Database::open(&dir.path().join("dedupe.sqlite")).expect("db");
        let snapshot = format!(
            "{}\n{}\n{}\n",
            serde_json::json!({
                "type": "session",
                "session": {
                    "id": "s1",
                    "title": "Dedupe",
                    "created_at": 10,
                    "updated_at": 20,
                    "metadata": {},
                },
            }),
            serde_json::json!({
                "type": "message",
                "message": {
                    "id": "m1",
                    "session_id": "s1",
                    "role": "user",
                    "content": "first",
                    "created_at": 10,
                    "metadata": {},
                },
            }),
            serde_json::json!({
                "type": "message",
                "message": {
                    "id": "m1",
                    "session_id": "s1",
                    "role": "user",
                    "content": "second",
                    "created_at": 10,
                    "metadata": {},
                },
            }),
        );
        let result = import_jsonl(&db, &snapshot).expect("import dedupes");
        assert_eq!(result.status, ImportStatus::Applied);

        let messages = MessageRepo::new(db).list("s1").expect("list messages");
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].content, "second", "last occurrence wins");
    }

    #[test]
    fn import_jsonl_detects_reformatted_identical_snapshot() {
        let dir = tempdir().expect("tempdir");
        let source = Database::open(&dir.path().join("source.sqlite")).expect("source db");
        SessionRepo::new(source.clone())
            .create("s1", "Reformatted")
            .expect("create session");
        MessageRepo::new(source.clone())
            .insert(&StoredMessage {
                id: "m1".to_string(),
                session_id: "s1".to_string(),
                role: "user".to_string(),
                content: "test".to_string(),
                created_at: 10,
                metadata: serde_json::json!({}),
            })
            .expect("insert");
        let snapshot = export_jsonl(&source, "s1").expect("export");

        let dest = Database::open(&dir.path().join("dest.sqlite")).expect("dest db");
        import_jsonl(&dest, &snapshot).expect("seed dest");

        // Reformat: add extra whitespace and rewrap header.
        let lines: Vec<&str> = snapshot.lines().collect();
        let header: serde_json::Value = serde_json::from_str(lines[0]).expect("parse header");
        let message: serde_json::Value = serde_json::from_str(lines[1]).expect("parse message");
        let reformatted = format!(
            "{}\n{}\n",
            serde_json::to_string(&header).expect("pretty header"),
            serde_json::to_string(&message).expect("pretty message"),
        );
        let result = import_jsonl(&dest, &reformatted).expect("import reformatted");
        assert_eq!(
            result.status,
            ImportStatus::Duplicate,
            "reformatted but content-identical snapshot should be duplicate, not conflict"
        );
    }

    #[test]
    fn import_jsonl_persists_across_reopen() {
        let dir = tempdir().expect("tempdir");
        let path = dir.path().join("persist.sqlite");
        let snapshot = {
            let source = Database::open(&dir.path().join("source.sqlite")).expect("source");
            SessionRepo::new(source.clone())
                .create("s1", "Persist")
                .expect("create");
            MessageRepo::new(source.clone())
                .insert(&StoredMessage {
                    id: "m1".to_string(),
                    session_id: "s1".to_string(),
                    role: "user".to_string(),
                    content: "durable".to_string(),
                    created_at: 10,
                    metadata: serde_json::json!({}),
                })
                .expect("insert");
            export_jsonl(&source, "s1").expect("export")
        };

        {
            let db = Database::open(&path).expect("open db");
            import_jsonl(&db, &snapshot).expect("import");
        }

        let reopened = Database::open(&path).expect("reopen db");
        let sessions = SessionRepo::new(reopened.clone());
        assert_eq!(sessions.list().expect("list").len(), 1);

        let messages = MessageRepo::new(reopened)
            .list("s1")
            .expect("list messages");
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].content, "durable");
    }

    #[test]
    fn import_jsonl_ignores_message_order() {
        let dir = tempdir().expect("tempdir");
        let source = Database::open(&dir.path().join("source.sqlite")).expect("source db");
        SessionRepo::new(source.clone())
            .create("s1", "Order")
            .expect("create");
        let messages = MessageRepo::new(source.clone());
        for (id, created_at) in [("m1", 10), ("m2", 20)] {
            messages
                .insert(&StoredMessage {
                    id: id.to_string(),
                    session_id: "s1".to_string(),
                    role: "user".to_string(),
                    content: id.to_string(),
                    created_at,
                    metadata: serde_json::json!({}),
                })
                .expect("insert");
        }
        let snapshot = export_jsonl(&source, "s1").expect("export");

        let dest = Database::open(&dir.path().join("dest.sqlite")).expect("dest db");
        import_jsonl(&dest, &snapshot).expect("seed dest");

        let mut lines: Vec<&str> = snapshot.lines().collect();
        lines.swap(1, 2);
        let reversed = format!("{}\n", lines.join("\n"));
        let result = import_jsonl(&dest, &reversed).expect("reordered import");
        assert_eq!(
            result.status,
            ImportStatus::Duplicate,
            "message order should not affect content equality"
        );
    }

    #[test]
    fn import_jsonl_rejects_corrupt_stored_metadata() {
        let dir = tempdir().expect("tempdir");
        let db = Database::open(&dir.path().join("corrupt-stored.sqlite")).expect("db");
        db.with_connection(|conn| {
            conn.execute(
                "insert into sessions (id, title, created_at, updated_at, metadata) \
                 values ('s1', 'Corrupt', 10, 20, ?1)",
                params!["{not json"],
            )?;
            conn.execute(
                "insert into messages (id, session_id, role, content, created_at, metadata) \
                 values ('m1', 's1', 'user', 'hello', 10, ?1)",
                params!["{not json"],
            )?;
            Ok(())
        })
        .expect("seed corrupt rows");

        let snapshot = format!(
            "{}\n{}\n",
            serde_json::json!({
                "type": "session",
                "session": {
                    "id": "s1",
                    "title": "Corrupt",
                    "created_at": 10,
                    "updated_at": 20,
                    "metadata": {},
                },
            }),
            serde_json::json!({
                "type": "message",
                "message": {
                    "id": "m1",
                    "session_id": "s1",
                    "role": "user",
                    "content": "hello",
                    "created_at": 10,
                    "metadata": {},
                },
            })
        );
        let err = import_jsonl(&db, &snapshot).expect_err("corrupt local session metadata");
        assert!(
            format!("{err:#}").contains("invalid session metadata"),
            "unexpected error: {err:#}"
        );
    }

    #[test]
    fn import_jsonl_ignores_metadata_object_key_order() {
        let dir = tempdir().expect("tempdir");
        let source = Database::open(&dir.path().join("source.sqlite")).expect("source db");
        SessionRepo::new(source.clone())
            .create("s1", "Key order")
            .expect("create");
        MessageRepo::new(source.clone())
            .insert(&StoredMessage {
                id: "m1".to_string(),
                session_id: "s1".to_string(),
                role: "user".to_string(),
                content: "hello".to_string(),
                created_at: 10,
                metadata: serde_json::json!({"a": 1, "b": {"x": true, "y": [1, 2]}}),
            })
            .expect("insert");
        let snapshot = export_jsonl(&source, "s1").expect("export");

        let dest = Database::open(&dir.path().join("dest.sqlite")).expect("dest db");
        import_jsonl(&dest, &snapshot).expect("seed dest");

        let reordered = snapshot.replace(
            r#"{"a":1,"b":{"x":true,"y":[1,2]}}"#,
            r#"{"b":{"y":[1,2],"x":true},"a":1}"#,
        );
        let result = import_jsonl(&dest, &reordered).expect("reordered import");
        assert_eq!(
            result.status,
            ImportStatus::Duplicate,
            "reordered metadata keys should not cause a conflict"
        );
    }
}
