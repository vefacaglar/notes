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
    pub account_id: String,
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
    pub account_id: String,
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

            CREATE TABLE IF NOT EXISTS workspaces (
                workspace_id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS encrypted_updates (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                update_id TEXT UNIQUE NOT NULL,
                workspace_id TEXT NOT NULL,
                account_id TEXT NOT NULL,
                doc_id TEXT NOT NULL,
                client_id INTEGER NOT NULL,
                nonce BLOB NOT NULL,
                ciphertext BLOB NOT NULL,
                created_at INTEGER NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_encrypted_updates_workspace_seq 
                ON encrypted_updates (workspace_id, seq);

            CREATE INDEX IF NOT EXISTS idx_encrypted_updates_account_workspace_seq 
                ON encrypted_updates (account_id, workspace_id, seq);

            CREATE TABLE IF NOT EXISTS encrypted_blobs (
                blob_hash TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                account_id TEXT NOT NULL,
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

    /// Workspace sahipliğini doğrular veya ilk kayıt ise sahiplik oluşturur.
    pub fn ensure_workspace_owner(&self, account_id: &str, workspace_id: &str) -> ServerResult<()> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            "SELECT account_id FROM workspaces WHERE workspace_id = ?1",
        )?;
        let owner: Option<String> = stmt
            .query_row(params![workspace_id], |row| row.get(0))
            .optional()?;

        match owner {
            Some(owner_id) => {
                if owner_id != account_id {
                    return Err(ServerError::Forbidden(format!(
                        "Bu çalışma alanına ('{}') erişim yetkiniz yok",
                        workspace_id
                    )));
                }
                Ok(())
            }
            None => {
                let now = Utc::now().timestamp_millis();
                let mut insert_stmt = conn.prepare_cached(
                    "INSERT INTO workspaces (workspace_id, account_id, created_at) VALUES (?1, ?2, ?3)",
                )?;
                insert_stmt.execute(params![workspace_id, account_id, now])?;
                Ok(())
            }
        }
    }

    /// Workspace erişimini doğrular. Eğer workspace kayıtlıysa ve sahibi başka hesapsa Forbidden döner.
    pub fn check_workspace_access(&self, account_id: &str, workspace_id: &str) -> ServerResult<()> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            "SELECT account_id FROM workspaces WHERE workspace_id = ?1",
        )?;
        let owner: Option<String> = stmt
            .query_row(params![workspace_id], |row| row.get(0))
            .optional()?;

        if let Some(owner_id) = owner {
            if owner_id != account_id {
                return Err(ServerError::Forbidden(format!(
                    "Bu çalışma alanına ('{}') erişim yetkiniz yok",
                    workspace_id
                )));
            }
        }
        Ok(())
    }

    /// Tek bir güncellemeyi idempotent ve hesap izolasyonlu olarak kaydeder.
    pub fn insert_update(
        &self,
        account_id: &str,
        update: &IncomingEnvelope,
    ) -> ServerResult<(i64, bool)> {
        let results = self.batch_insert_updates(account_id, std::slice::from_ref(update))?;
        let item = &results[0];
        Ok((item.seq, item.status == "inserted"))
    }

    /// Birden fazla güncellemeyi tek transaction içerisinde idempotent ve hesap izolasyonlu kaydeder.
    pub fn batch_insert_updates(
        &self,
        account_id: &str,
        updates: &[IncomingEnvelope],
    ) -> ServerResult<Vec<PushResultItem>> {
        let mut conn = self.conn.lock().unwrap();
        let now = Utc::now().timestamp_millis();

        let tx = conn.transaction()?;
        let mut results = Vec::with_capacity(updates.len());

        {
            let mut check_ws_stmt = tx.prepare_cached(
                "SELECT account_id FROM workspaces WHERE workspace_id = ?1",
            )?;
            let mut insert_ws_stmt = tx.prepare_cached(
                "INSERT INTO workspaces (workspace_id, account_id, created_at) VALUES (?1, ?2, ?3)",
            )?;
            let mut check_stmt = tx.prepare_cached(
                "SELECT seq, account_id FROM encrypted_updates WHERE update_id = ?1",
            )?;
            let mut insert_stmt = tx.prepare_cached(
                r#"
                INSERT INTO encrypted_updates (update_id, workspace_id, account_id, doc_id, client_id, nonce, ciphertext, created_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                "#,
            )?;

            for update in updates {
                // 1. Workspace sahiplik doğrulaması
                let ws_owner: Option<String> = check_ws_stmt
                    .query_row(params![&update.workspace_id], |row| row.get(0))
                    .optional()?;

                match ws_owner {
                    Some(owner) => {
                        if owner != account_id {
                            return Err(ServerError::Forbidden(format!(
                                "Bu çalışma alanına ('{}') erişim yetkiniz yok",
                                update.workspace_id
                            )));
                        }
                    }
                    None => {
                        insert_ws_stmt.execute(params![&update.workspace_id, account_id, now])?;
                    }
                }

                // 2. Güncelleme idempotency kontrolü
                let existing: Option<(i64, String)> = check_stmt
                    .query_row(params![&update.update_id], |row| {
                        Ok((row.get(0)?, row.get(1)?))
                    })
                    .optional()?;

                if let Some((seq, existing_account)) = existing {
                    if existing_account != account_id {
                        return Err(ServerError::Forbidden(format!(
                            "Bu güncellemeye ('{}') erişim yetkiniz yok",
                            update.update_id
                        )));
                    }
                    results.push(PushResultItem {
                        update_id: update.update_id.clone(),
                        seq,
                        status: "already_exists".to_string(),
                    });
                } else {
                    insert_stmt.execute(params![
                        &update.update_id,
                        &update.workspace_id,
                        account_id,
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

    /// Belirtilen `account_id`, `workspace_id` ve `since_seq` değerinden sonraki güncellemeleri sıralı çeker.
    /// Başka bir hesaba ait workspace talep edilirse Forbidden döner.
    pub fn pull_updates(
        &self,
        account_id: &str,
        workspace_id: &str,
        since_seq: i64,
        limit: usize,
    ) -> ServerResult<Vec<EncryptedEnvelopeRecord>> {
        let conn = self.conn.lock().unwrap();

        // 1. Workspace sahiplik doğrulaması
        let mut check_ws = conn.prepare_cached(
            "SELECT account_id FROM workspaces WHERE workspace_id = ?1",
        )?;
        let owner: Option<String> = check_ws
            .query_row(params![workspace_id], |row| row.get(0))
            .optional()?;

        if let Some(owner_id) = owner {
            if owner_id != account_id {
                return Err(ServerError::Forbidden(format!(
                    "Bu çalışma alanına ('{}') erişim yetkiniz yok",
                    workspace_id
                )));
            }
        } else {
            // Workspace veritabanında henüz mevcut değilse boş liste döner
            return Ok(Vec::new());
        }

        // 2. Güncellemeleri çek
        let mut stmt = conn.prepare_cached(
            r#"
            SELECT seq, update_id, workspace_id, account_id, doc_id, client_id, nonce, ciphertext, created_at
            FROM encrypted_updates
            WHERE workspace_id = ?1 AND account_id = ?2 AND seq > ?3
            ORDER BY seq ASC
            LIMIT ?4
            "#,
        )?;

        let rows = stmt.query_map(params![workspace_id, account_id, since_seq, limit as i64], |row| {
            let client_id_i64: i64 = row.get(5)?;
            Ok(EncryptedEnvelopeRecord {
                seq: row.get(0)?,
                update_id: row.get(1)?,
                workspace_id: row.get(2)?,
                account_id: row.get(3)?,
                doc_id: row.get(4)?,
                client_id: client_id_i64 as u64,
                nonce: row.get(6)?,
                ciphertext: row.get(7)?,
                created_at: row.get(8)?,
            })
        })?;

        let mut envelopes = Vec::new();
        for row in rows {
            envelopes.push(row?);
        }

        Ok(envelopes)
    }

    /// Çalışma alanındaki en yüksek `seq` numarasını döner.
    pub fn get_max_seq(&self, account_id: &str, workspace_id: &str) -> ServerResult<i64> {
        let conn = self.conn.lock().unwrap();

        let mut check_ws = conn.prepare_cached(
            "SELECT account_id FROM workspaces WHERE workspace_id = ?1",
        )?;
        let owner: Option<String> = check_ws
            .query_row(params![workspace_id], |row| row.get(0))
            .optional()?;

        if let Some(owner_id) = owner {
            if owner_id != account_id {
                return Err(ServerError::Forbidden(format!(
                    "Bu çalışma alanına ('{}') erişim yetkiniz yok",
                    workspace_id
                )));
            }
        }

        let mut stmt = conn.prepare_cached(
            "SELECT COALESCE(MAX(seq), 0) FROM encrypted_updates WHERE workspace_id = ?1 AND account_id = ?2",
        )?;

        let max_seq = stmt.query_row(params![workspace_id, account_id], |row| row.get(0))?;
        Ok(max_seq)
    }

    /// Şifreli CAS blob saklar. Idempotent ve hesap sahipliği denetimli çalışır.
    pub fn put_blob(
        &self,
        account_id: &str,
        blob_hash: &str,
        workspace_id: &str,
        ciphertext: &[u8],
    ) -> ServerResult<bool> {
        let conn = self.conn.lock().unwrap();
        let now = Utc::now().timestamp_millis();
        let size_bytes = ciphertext.len() as i64;

        // Blob zaten var mı ve sahibi kim?
        let mut check_stmt = conn.prepare_cached(
            "SELECT account_id FROM encrypted_blobs WHERE blob_hash = ?1",
        )?;
        let existing_owner: Option<String> = check_stmt
            .query_row(params![blob_hash], |row| row.get(0))
            .optional()?;

        if let Some(owner) = existing_owner {
            if owner != account_id {
                return Err(ServerError::Forbidden(format!(
                    "Bu bloba ('{}') erişim yetkiniz yok",
                    blob_hash
                )));
            }
            // Aynı hesap zaten yüklemişse idempotent
            return Ok(false);
        }

        let mut stmt = conn.prepare_cached(
            r#"
            INSERT INTO encrypted_blobs (blob_hash, workspace_id, account_id, ciphertext, size_bytes, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
        )?;

        stmt.execute(params![blob_hash, workspace_id, account_id, ciphertext, size_bytes, now])?;
        Ok(true)
    }

    /// Şifreli CAS blob içeriğini hash ile sorgular. Başka bir hesabın blob'u ise Forbidden döner.
    pub fn get_blob(&self, account_id: &str, blob_hash: &str) -> ServerResult<Option<EncryptedBlobRecord>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            r#"
            SELECT blob_hash, workspace_id, account_id, ciphertext, size_bytes, created_at
            FROM encrypted_blobs
            WHERE blob_hash = ?1
            "#,
        )?;

        let blob = stmt
            .query_row(params![blob_hash], |row| {
                Ok(EncryptedBlobRecord {
                    blob_hash: row.get(0)?,
                    workspace_id: row.get(1)?,
                    account_id: row.get(2)?,
                    ciphertext: row.get(3)?,
                    size_bytes: row.get(4)?,
                    created_at: row.get(5)?,
                })
            })
            .optional()?;

        if let Some(ref record) = blob {
            if record.account_id != account_id {
                return Err(ServerError::Forbidden(format!(
                    "Bu bloba ('{}') erişim yetkiniz yok",
                    blob_hash
                )));
            }
        }

        Ok(blob)
    }

    /// Blob'un var olup olmadığını sorgular (hesap izolasyonlu).
    pub fn blob_exists(&self, account_id: &str, blob_hash: &str) -> ServerResult<bool> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            "SELECT account_id FROM encrypted_blobs WHERE blob_hash = ?1",
        )?;

        let owner: Option<String> = stmt
            .query_row(params![blob_hash], |row| row.get(0))
            .optional()?;

        match owner {
            Some(owner_id) if owner_id == account_id => Ok(true),
            _ => Ok(false),
        }
    }
}
