use std::path::Path;
use rusqlite::Connection;
use uuid::Uuid;

use crate::error::{CoreError, Result};

pub const SCHEMA_SQL: &str = include_str!("schema.sql");

/// Yerel çalışma alanı meta veri kaydı.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceRecord {
    pub id: Uuid,
    pub name: String,
    pub encrypted_dek: Vec<u8>,
    pub dek_nonce: Vec<u8>,
    pub created_at: i64,
}

/// SQLite veritabanı bağlantısını ve şema yönetimini sarmalayan ana depolama yapısı.
pub struct LocalStore {
    conn: Connection,
}

impl LocalStore {
    /// Bellek içi (in-memory) bir SQLite veritabanı oluşturur ve şemayı uygular.
    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory().map_err(|e| CoreError::Database(e.to_string()))?;
        conn.pragma_update(None, "foreign_keys", "ON")
            .map_err(|e| CoreError::Database(format!("Foreign keys pragma ayarlanamadı: {}", e)))?;
        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    /// Belirtilen dosya yolunda SQLite veritabanı açar (yoksa oluşturur), WAL modunu aktif eder ve şemayı uygular.
    pub fn open_path<P: AsRef<Path>>(path: P) -> Result<Self> {
        let p = path.as_ref();
        if let Some(parent) = p.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)
                    .map_err(|e| CoreError::Database(format!("Dizin oluşturulamadı: {}", e)))?;
            }
        }

        let conn = Connection::open(p).map_err(|e| CoreError::Database(e.to_string()))?;
        conn.pragma_update(None, "journal_mode", "WAL")
            .map_err(|e| CoreError::Database(format!("WAL modu ayarlanamadı: {}", e)))?;
        conn.pragma_update(None, "synchronous", "NORMAL")
            .map_err(|e| CoreError::Database(format!("Synchronous pragma ayarlanamadı: {}", e)))?;
        conn.pragma_update(None, "foreign_keys", "ON")
            .map_err(|e| CoreError::Database(format!("Foreign keys pragma ayarlanamadı: {}", e)))?;
        conn.pragma_update(None, "busy_timeout", 5000)
            .map_err(|e| CoreError::Database(format!("Busy timeout ayarlanamadı: {}", e)))?;

        let store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    /// `schema.sql` dosyasındaki tabloları ve indeksleri uygular.
    pub fn migrate(&self) -> Result<()> {
        self.conn
            .execute_batch(SCHEMA_SQL)
            .map_err(|e| CoreError::Database(format!("Şema migrasyonu başarısız: {}", e)))?;
        Ok(())
    }

    /// Dahili SQLite bağlantısına salt-okunur referans döndürür.
    pub fn conn(&self) -> &Connection {
        &self.conn
    }

    /// Dahili SQLite bağlantısına değiştirilebilir referans döndürür.
    pub fn conn_mut(&mut self) -> &mut Connection {
        &mut self.conn
    }

    /// `rusqlite::Connection` nesnesini tüketerek döndürür.
    pub fn into_inner(self) -> Connection {
        self.conn
    }

    /// Yeni bir çalışma alanı kaydeder.
    pub fn create_workspace(&self, ws: &WorkspaceRecord) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO workspaces (id, name, encrypted_dek, dek_nonce, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
                rusqlite::params![
                    ws.id.to_string(),
                    ws.name,
                    ws.encrypted_dek,
                    ws.dek_nonce,
                    ws.created_at,
                ],
            )
            .map_err(|e| CoreError::Database(format!("Çalışma alanı eklenemedi: {}", e)))?;
        Ok(())
    }

    /// ID'ye göre çalışma alanını getirir.
    pub fn get_workspace(&self, id: Uuid) -> Result<Option<WorkspaceRecord>> {
        let mut stmt = self
            .conn
            .prepare("SELECT id, name, encrypted_dek, dek_nonce, created_at FROM workspaces WHERE id = ?1")
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let mut rows = stmt
            .query(rusqlite::params![id.to_string()])
            .map_err(|e| CoreError::Database(e.to_string()))?;

        if let Some(row) = rows.next().map_err(|e| CoreError::Database(e.to_string()))? {
            let id_str: String = row.get(0).map_err(|e| CoreError::Database(e.to_string()))?;
            let parsed_id = Uuid::parse_str(&id_str)
                .map_err(|e| CoreError::Database(format!("Geçersiz workspace UUID: {}", e)))?;
            let name: String = row.get(1).map_err(|e| CoreError::Database(e.to_string()))?;
            let encrypted_dek: Vec<u8> = row.get(2).map_err(|e| CoreError::Database(e.to_string()))?;
            let dek_nonce: Vec<u8> = row.get(3).map_err(|e| CoreError::Database(e.to_string()))?;
            let created_at: i64 = row.get(4).map_err(|e| CoreError::Database(e.to_string()))?;

            Ok(Some(WorkspaceRecord {
                id: parsed_id,
                name,
                encrypted_dek,
                dek_nonce,
                created_at,
            }))
        } else {
            Ok(None)
        }
    }

    /// Tüm çalışma alanlarını listeler.
    pub fn list_workspaces(&self) -> Result<Vec<WorkspaceRecord>> {
        let mut stmt = self
            .conn
            .prepare("SELECT id, name, encrypted_dek, dek_nonce, created_at FROM workspaces ORDER BY created_at ASC")
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let rows = stmt
            .query_map([], |row| {
                let id_str: String = row.get(0)?;
                let name: String = row.get(1)?;
                let encrypted_dek: Vec<u8> = row.get(2)?;
                let dek_nonce: Vec<u8> = row.get(3)?;
                let created_at: i64 = row.get(4)?;
                Ok((id_str, name, encrypted_dek, dek_nonce, created_at))
            })
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let mut list = Vec::new();
        for item in rows {
            let (id_str, name, encrypted_dek, dek_nonce, created_at) =
                item.map_err(|e| CoreError::Database(e.to_string()))?;
            let parsed_id = Uuid::parse_str(&id_str)
                .map_err(|e| CoreError::Database(format!("Geçersiz workspace UUID: {}", e)))?;
            list.push(WorkspaceRecord {
                id: parsed_id,
                name,
                encrypted_dek,
                dek_nonce,
                created_at,
            });
        }
        Ok(list)
    }

    /// Bir çalışma alanını ve cascade ile bağlı tüm kayıtlarını siler.
    pub fn delete_workspace(&self, id: Uuid) -> Result<()> {
        let affected = self
            .conn
            .execute("DELETE FROM workspaces WHERE id = ?1", rusqlite::params![id.to_string()])
            .map_err(|e| CoreError::Database(format!("Çalışma alanı silinemedi: {}", e)))?;

        if affected == 0 {
            return Err(CoreError::NotFound(format!("Çalışma alanı bulunamadı: {}", id)));
        }
        Ok(())
    }
}
