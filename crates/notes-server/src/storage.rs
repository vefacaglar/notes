use std::path::Path;
use std::sync::{Arc, Mutex};
use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::error::{ServerError, ServerResult};

/// Veritabanında saklanan ve istemcilere iletilen şifreli CRDT güncelleme kaydı.
/// Sıralı `seq` numarası sunucu tarafından tekil olarak atanır.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EncryptedEnvelopeRecord {
    pub seq: i64,
    pub update_id: String,
    pub workspace_id: String,
    pub doc_id: String,
    pub client_id: u64,
    pub nonce: Vec<u8>,
    pub ciphertext: Vec<u8>,
    pub created_at: i64,
}

/// İstemciden gelen şifreli güncelleme zarfı.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IncomingEnvelope {
    pub update_id: String,
    pub workspace_id: String,
    pub doc_id: String,
    pub client_id: u64,
    pub nonce: Vec<u8>,
    pub ciphertext: Vec<u8>,
}

/// Push işleminde her bir zarf için dönen sonuç.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PushResultItem {
    pub update_id: String,
    pub seq: i64,
    pub status: String, // "inserted" veya "already_exists"
}

/// Şifreli CAS blob kaydı.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EncryptedBlobRecord {
    pub blob_hash: String,
    pub workspace_id: String,
    pub ciphertext: Vec<u8>,
    pub size_bytes: i64,
    pub created_at: i64,
}

/// Rusqlite tabanlı sıfır bilgi sunucu depolama motoru.
#[derive(Clone)]
pub struct ServerStore {
    conn: Arc<Mutex<Connection>>,
}

impl ServerStore {
    /// Bellek içi (in-memory) geçici SQLite deposu açar.
    pub fn open_in_memory() -> ServerResult<Self> {
        let conn = Connection::open_in_memory()?;
        let store = Self {
            conn: Arc::new(Mutex::new(conn)),
        };
        store.init_schema()?;
        Ok(store)
    }

    /// Verilen dosya yolunda SQLite deposu açar.
    pub fn open_path<P: AsRef<Path>>(path: P) -> ServerResult<Self> {
        if let Some(parent) = path.as_ref().parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let conn = Connection::open(path)?;
        let store = Self {
            conn: Arc::new(Mutex::new(conn)),
        };
        store.init_schema()?;
        Ok(store)
    }

    /// Şema ve indeksleri ilklendirir.
    fn init_schema(&self) -> ServerResult<()> {
        let conn = self.conn.lock().unwrap();

        // Performans ayarları
        conn.execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            "#,
        )?;

        // Tablolar
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS accounts (
                account_id TEXT PRIMARY KEY,
                auth_verifier_hash TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS encrypted_updates (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                update_id TEXT UNIQUE NOT NULL,
                workspace_id TEXT NOT NULL,
                doc_id TEXT NOT NULL,
                client_id INTEGER NOT NULL,
                nonce BLOB NOT NULL,
                ciphertext BLOB NOT NULL,
                created_at INTEGER NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_encrypted_updates_workspace_seq 
                ON encrypted_updates (workspace_id, seq);

            CREATE TABLE IF NOT EXISTS encrypted_blobs (
                blob_hash TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                ciphertext BLOB NOT NULL,
                size_bytes INTEGER NOT NULL,
                created_at INTEGER NOT NULL
            );
            "#,
        )?;

        Ok(())
    }

    /// Yeni bir ZK hesabı kaydeder. Hesap zaten varsa Conflict döner.
    pub fn insert_account(&self, account_id: &str, auth_verifier_hash: &str) -> ServerResult<()> {
        let conn = self.conn.lock().unwrap();
        let now = Utc::now().timestamp_millis();

        let mut stmt = conn.prepare_cached(
            "INSERT INTO accounts (account_id, auth_verifier_hash, created_at) VALUES (?1, ?2, ?3)",
        )?;

        match stmt.execute(params![account_id, auth_verifier_hash, now]) {
            Ok(_) => Ok(()),
            Err(rusqlite::Error::SqliteFailure(err, _))
                if err.code == rusqlite::ErrorCode::ConstraintViolation =>
            {
                Err(ServerError::Conflict(format!("Hesap zaten mevcut: {}", account_id)))
            }
            Err(e) => Err(ServerError::Database(e)),
        }
    }

    /// Hesabın auth_verifier_hash bilgisini sorgular.
    pub fn get_account_verifier_hash(&self, account_id: &str) -> ServerResult<Option<String>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            "SELECT auth_verifier_hash FROM accounts WHERE account_id = ?1",
        )?;

        let hash = stmt
            .query_row(params![account_id], |row| row.get::<_, String>(0))
            .optional()?;

        Ok(hash)
    }

    /// Hesabın var olup olmadığını kontrol eder.
    pub fn account_exists(&self, account_id: &str) -> ServerResult<bool> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            "SELECT 1 FROM accounts WHERE account_id = ?1",
        )?;

        let exists = stmt
            .query_row(params![account_id], |_| Ok(()))
            .optional()?
            .is_some();

        Ok(exists)
    }

    /// Tek bir güncellemeyi idempotent olarak kaydeder.
    /// Güncelleme zaten varsa mevcut `seq` ve `false` (yeni eklenmedi) döner.
    /// Yeni eklendiyse yeni `seq` ve `true` döner.
    pub fn insert_update(&self, update: &IncomingEnvelope) -> ServerResult<(i64, bool)> {
        let conn = self.conn.lock().unwrap();
        let now = Utc::now().timestamp_millis();

        // 1. Zaten var mı kontrol et
        let mut check_stmt = conn.prepare_cached(
            "SELECT seq FROM encrypted_updates WHERE update_id = ?1",
        )?;
        let existing_seq = check_stmt
            .query_row(params![&update.update_id], |row| row.get::<_, i64>(0))
            .optional()?;

        if let Some(seq) = existing_seq {
            return Ok((seq, false));
        }

        // 2. Yeni güncelleme ekle
        let mut insert_stmt = conn.prepare_cached(
            r#"
            INSERT INTO encrypted_updates (update_id, workspace_id, doc_id, client_id, nonce, ciphertext, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
        )?;

        insert_stmt.execute(params![
            &update.update_id,
            &update.workspace_id,
            &update.doc_id,
            update.client_id as i64,
            &update.nonce,
            &update.ciphertext,
            now,
        ])?;

        let new_seq = conn.last_insert_rowid();
        Ok((new_seq, true))
    }

    /// Birden fazla güncellemeyi tek transaction içerisinde idempotent olarak kaydeder.
    pub fn batch_insert_updates(
        &self,
        updates: &[IncomingEnvelope],
    ) -> ServerResult<Vec<PushResultItem>> {
        let mut conn = self.conn.lock().unwrap();
        let now = Utc::now().timestamp_millis();

        let tx = conn.transaction()?;
        let mut results = Vec::with_capacity(updates.len());

        {
            let mut check_stmt = tx.prepare_cached(
                "SELECT seq FROM encrypted_updates WHERE update_id = ?1",
            )?;
            let mut insert_stmt = tx.prepare_cached(
                r#"
                INSERT INTO encrypted_updates (update_id, workspace_id, doc_id, client_id, nonce, ciphertext, created_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                "#,
            )?;

            for update in updates {
                let existing_seq = check_stmt
                    .query_row(params![&update.update_id], |row| row.get::<_, i64>(0))
                    .optional()?;

                if let Some(seq) = existing_seq {
                    results.push(PushResultItem {
                        update_id: update.update_id.clone(),
                        seq,
                        status: "already_exists".to_string(),
                    });
                } else {
                    insert_stmt.execute(params![
                        &update.update_id,
                        &update.workspace_id,
                        &update.doc_id,
                        update.client_id as i64,
                        &update.nonce,
                        &update.ciphertext,
                        now,
                    ])?;
                    let seq = tx.last_insert_rowid();
                    results.push(PushResultItem {
                        update_id: update.update_id.clone(),
                        seq,
                        status: "inserted".to_string(),
                    });
                }
            }
        }

        tx.commit()?;
        Ok(results)
    }

    /// Belirtilen `workspace_id` ve `since_seq` değerinden sonraki güncellemeleri sıralı çeker.
    pub fn pull_updates(
        &self,
        workspace_id: &str,
        since_seq: i64,
        limit: usize,
    ) -> ServerResult<Vec<EncryptedEnvelopeRecord>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            r#"
            SELECT seq, update_id, workspace_id, doc_id, client_id, nonce, ciphertext, created_at
            FROM encrypted_updates
            WHERE workspace_id = ?1 AND seq > ?2
            ORDER BY seq ASC
            LIMIT ?3
            "#,
        )?;

        let rows = stmt.query_map(params![workspace_id, since_seq, limit as i64], |row| {
            let client_id_i64: i64 = row.get(4)?;
            Ok(EncryptedEnvelopeRecord {
                seq: row.get(0)?,
                update_id: row.get(1)?,
                workspace_id: row.get(2)?,
                doc_id: row.get(3)?,
                client_id: client_id_i64 as u64,
                nonce: row.get(5)?,
                ciphertext: row.get(6)?,
                created_at: row.get(7)?,
            })
        })?;

        let mut envelopes = Vec::new();
        for row in rows {
            envelopes.push(row?);
        }

        Ok(envelopes)
    }

    /// Çalışma alanındaki en yüksek `seq` numarasını döner.
    pub fn get_max_seq(&self, workspace_id: &str) -> ServerResult<i64> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            "SELECT COALESCE(MAX(seq), 0) FROM encrypted_updates WHERE workspace_id = ?1",
        )?;

        let max_seq = stmt.query_row(params![workspace_id], |row| row.get(0))?;
        Ok(max_seq)
    }

    /// Şifreli CAS blob saklar. Idempotent çalışır (varsa üzerine yazmaz, `false` döner).
    pub fn put_blob(
        &self,
        blob_hash: &str,
        workspace_id: &str,
        ciphertext: &[u8],
    ) -> ServerResult<bool> {
        let conn = self.conn.lock().unwrap();
        let now = Utc::now().timestamp_millis();
        let size_bytes = ciphertext.len() as i64;

        let mut stmt = conn.prepare_cached(
            r#"
            INSERT OR IGNORE INTO encrypted_blobs (blob_hash, workspace_id, ciphertext, size_bytes, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5)
            "#,
        )?;

        let changes = stmt.execute(params![blob_hash, workspace_id, ciphertext, size_bytes, now])?;
        Ok(changes > 0)
    }

    /// Şifreli CAS blob içeriğini hash ile sorgular.
    pub fn get_blob(&self, blob_hash: &str) -> ServerResult<Option<EncryptedBlobRecord>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            r#"
            SELECT blob_hash, workspace_id, ciphertext, size_bytes, created_at
            FROM encrypted_blobs
            WHERE blob_hash = ?1
            "#,
        )?;

        let blob = stmt
            .query_row(params![blob_hash], |row| {
                Ok(EncryptedBlobRecord {
                    blob_hash: row.get(0)?,
                    workspace_id: row.get(1)?,
                    ciphertext: row.get(2)?,
                    size_bytes: row.get(3)?,
                    created_at: row.get(4)?,
                })
            })
            .optional()?;

        Ok(blob)
    }

    /// Blob'un var olup olmadığını sorgular.
    pub fn blob_exists(&self, blob_hash: &str) -> ServerResult<bool> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            "SELECT 1 FROM encrypted_blobs WHERE blob_hash = ?1",
        )?;

        let exists = stmt
            .query_row(params![blob_hash], |_| Ok(()))
            .optional()?
            .is_some();

        Ok(exists)
    }
}
