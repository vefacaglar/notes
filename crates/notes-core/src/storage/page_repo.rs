use chrono::{DateTime, Utc};
use rusqlite::{params, Connection, Row};
use uuid::Uuid;

use crate::error::{CoreError, Result};
use crate::model::page::{Page, PageLink};

/// Çevrimdışı senkronizasyon kuyruğu (`sync_outbox`) kayıt modeli.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutboxItem {
    pub id: Uuid,
    pub workspace_id: Uuid,
    pub doc_id: Uuid,
    pub envelope_bytes: Vec<u8>,
    pub retry_count: i64,
    pub last_error: Option<String>,
    pub created_at: i64,
}

/// Sayfalar, sayfa hiyerarşisi, bağlantılar, etiketler ve senkronizasyon outbox
/// veritabanı işlemlerini yürüten repository.
pub struct PageRepo<'a> {
    conn: &'a Connection,
}

impl<'a> PageRepo<'a> {
    /// Yeni bir `PageRepo` örneği oluşturur.
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    // ------------------------------------------------------------------------
    // Sayfa CRUD Metodları
    // ------------------------------------------------------------------------

    /// Yeni bir sayfayı veritabanına ekler.
    pub fn create_page(&self, page: &Page) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO pages (
                    id, workspace_id, parent_page_id, title, icon, cover_image,
                    is_database, is_pinned, is_deleted, created_at, updated_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![
                    page.id.to_string(),
                    page.workspace_id.to_string(),
                    page.parent_page_id.map(|u| u.to_string()),
                    page.title,
                    page.icon,
                    page.cover_image,
                    page.is_database as i32,
                    page.is_pinned as i32,
                    page.is_deleted as i32,
                    page.created_at.timestamp_millis(),
                    page.updated_at.timestamp_millis(),
                ],
            )
            .map_err(|e| CoreError::Database(format!("Sayfa oluşturulamadı: {}", e)))?;

        Ok(())
    }

    /// ID ile sayfa kaydını getirir.
    pub fn get_page(&self, id: Uuid) -> Result<Option<Page>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, workspace_id, parent_page_id, title, icon, cover_image,
                        is_database, is_pinned, is_deleted, created_at, updated_at
                 FROM pages WHERE id = ?1",
            )
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let mut rows = stmt
            .query(params![id.to_string()])
            .map_err(|e| CoreError::Database(e.to_string()))?;

        if let Some(row) = rows.next().map_err(|e| CoreError::Database(e.to_string()))? {
            let page = Self::map_page_row(row).map_err(|e| CoreError::Database(e.to_string()))?;
            Ok(Some(page))
        } else {
            Ok(None)
        }
    }

    /// Mevcut bir sayfayı günceller.
    pub fn update_page(&self, page: &Page) -> Result<()> {
        let affected = self
            .conn
            .execute(
                "UPDATE pages SET
                    workspace_id = ?1,
                    parent_page_id = ?2,
                    title = ?3,
                    icon = ?4,
                    cover_image = ?5,
                    is_database = ?6,
                    is_pinned = ?7,
                    is_deleted = ?8,
                    updated_at = ?9
                 WHERE id = ?10",
                params![
                    page.workspace_id.to_string(),
                    page.parent_page_id.map(|u| u.to_string()),
                    page.title,
                    page.icon,
                    page.cover_image,
                    page.is_database as i32,
                    page.is_pinned as i32,
                    page.is_deleted as i32,
                    page.updated_at.timestamp_millis(),
                    page.id.to_string(),
                ],
            )
            .map_err(|e| CoreError::Database(format!("Sayfa güncellenemedi: {}", e)))?;

        if affected == 0 {
            return Err(CoreError::NotFound(format!("Sayfa bulunamadı: {}", page.id)));
        }

        Ok(())
    }

    /// Sayfayı çöp kutusuna taşır (soft-delete).
    pub fn soft_delete_page(&self, id: Uuid) -> Result<()> {
        let now = Utc::now().timestamp_millis();
        let affected = self
            .conn
            .execute(
                "UPDATE pages SET is_deleted = 1, updated_at = ?1 WHERE id = ?2",
                params![now, id.to_string()],
            )
            .map_err(|e| CoreError::Database(format!("Sayfa silinemedi: {}", e)))?;

        if affected == 0 {
            return Err(CoreError::NotFound(format!("Sayfa bulunamadı: {}", id)));
        }

        Ok(())
    }

    /// Çöp kutusundaki sayfayı geri yükler.
    pub fn restore_page(&self, id: Uuid) -> Result<()> {
        let now = Utc::now().timestamp_millis();
        let affected = self
            .conn
            .execute(
                "UPDATE pages SET is_deleted = 0, updated_at = ?1 WHERE id = ?2",
                params![now, id.to_string()],
            )
            .map_err(|e| CoreError::Database(format!("Sayfa geri yüklenemedi: {}", e)))?;

        if affected == 0 {
            return Err(CoreError::NotFound(format!("Sayfa bulunamadı: {}", id)));
        }

        Ok(())
    }

    /// Sayfayı ve bağlı verilerini veritabanından kalıcı olarak siler (hard delete).
    pub fn hard_delete_page(&self, id: Uuid) -> Result<()> {
        let affected = self
            .conn
            .execute("DELETE FROM pages WHERE id = ?1", params![id.to_string()])
            .map_err(|e| CoreError::Database(format!("Sayfa kalıcı olarak silinemedi: {}", e)))?;

        if affected == 0 {
            return Err(CoreError::NotFound(format!("Sayfa bulunamadı: {}", id)));
        }

        Ok(())
    }

    /// Bir çalışma alanındaki sayfaları listeler.
    pub fn list_workspace_pages(&self, workspace_id: Uuid, include_deleted: bool) -> Result<Vec<Page>> {
        let query = if include_deleted {
            "SELECT id, workspace_id, parent_page_id, title, icon, cover_image,
                    is_database, is_pinned, is_deleted, created_at, updated_at
             FROM pages WHERE workspace_id = ?1 ORDER BY created_at DESC"
        } else {
            "SELECT id, workspace_id, parent_page_id, title, icon, cover_image,
                    is_database, is_pinned, is_deleted, created_at, updated_at
             FROM pages WHERE workspace_id = ?1 AND is_deleted = 0 ORDER BY created_at DESC"
        };

        let mut stmt = self.conn.prepare(query).map_err(|e| CoreError::Database(e.to_string()))?;
        let rows = stmt
            .query_map(params![workspace_id.to_string()], Self::map_page_row)
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let mut pages = Vec::new();
        for r in rows {
            pages.push(r.map_err(|e| CoreError::Database(e.to_string()))?);
        }
        Ok(pages)
    }

    /// Bir üst sayfanın doğrudan altındaki sayfaları (çocukları) listeler.
    pub fn list_subpages(
        &self,
        parent_page_id: Option<Uuid>,
        workspace_id: Uuid,
    ) -> Result<Vec<Page>> {
        let (query, param_val) = match parent_page_id {
            Some(pid) => (
                "SELECT id, workspace_id, parent_page_id, title, icon, cover_image,
                        is_database, is_pinned, is_deleted, created_at, updated_at
                 FROM pages WHERE parent_page_id = ?1 AND workspace_id = ?2 AND is_deleted = 0
                 ORDER BY created_at ASC",
                pid.to_string(),
            ),
            None => (
                "SELECT id, workspace_id, parent_page_id, title, icon, cover_image,
                        is_database, is_pinned, is_deleted, created_at, updated_at
                 FROM pages WHERE parent_page_id IS NULL AND workspace_id = ?1 AND is_deleted = 0
                 ORDER BY created_at ASC",
                workspace_id.to_string(),
            ),
        };

        let mut stmt = self.conn.prepare(query).map_err(|e| CoreError::Database(e.to_string()))?;
        let rows = if parent_page_id.is_some() {
            stmt.query_map(params![param_val, workspace_id.to_string()], Self::map_page_row)
        } else {
            stmt.query_map(params![param_val], Self::map_page_row)
        }
        .map_err(|e| CoreError::Database(e.to_string()))?;

        let mut pages = Vec::new();
        for r in rows {
            pages.push(r.map_err(|e| CoreError::Database(e.to_string()))?);
        }
        Ok(pages)
    }

    /// Bir üst sayfanın doğrudan altındaki sayfaları (çocukları) listeler (`list_subpages` alias).
    pub fn list_child_pages(
        &self,
        parent_page_id: Option<Uuid>,
        workspace_id: Uuid,
    ) -> Result<Vec<Page>> {
        self.list_subpages(parent_page_id, workspace_id)
    }

    /// Recursive CTE ile bir sayfanın altındaki tüm alt sayfaları (torunlar dahil hiyerarşik ağaç) getirir.
    pub fn get_subpage_tree(&self, root_page_id: Uuid, include_deleted: bool) -> Result<Vec<Page>> {
        let query = "WITH RECURSIVE subpages AS (
                SELECT id, workspace_id, parent_page_id, title, icon, cover_image,
                       is_database, is_pinned, is_deleted, created_at, updated_at, 0 AS depth
                FROM pages
                WHERE id = ?1
                UNION ALL
                SELECT p.id, p.workspace_id, p.parent_page_id, p.title, p.icon, p.cover_image,
                       p.is_database, p.is_pinned, p.is_deleted, p.created_at, p.updated_at, s.depth + 1
                FROM pages p
                JOIN subpages s ON p.parent_page_id = s.id
                WHERE (?2 = 1 OR p.is_deleted = 0)
            )
            SELECT id, workspace_id, parent_page_id, title, icon, cover_image,
                   is_database, is_pinned, is_deleted, created_at, updated_at
            FROM subpages
            WHERE depth > 0
            ORDER BY depth ASC, created_at ASC";

        let mut stmt = self.conn.prepare(query).map_err(|e| CoreError::Database(e.to_string()))?;
        let rows = stmt
            .query_map(params![root_page_id.to_string(), include_deleted as i32], Self::map_page_row)
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let mut pages = Vec::new();
        for r in rows {
            pages.push(r.map_err(|e| CoreError::Database(e.to_string()))?);
        }
        Ok(pages)
    }

    // ------------------------------------------------------------------------
    // İki Yönlü Bağlantılar (PageLink)
    // ------------------------------------------------------------------------

    /// İki sayfa arasında bağlantı ekler.
    pub fn insert_link(&self, link: &PageLink) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO page_links (
                    id, source_page_id, target_page_id, source_block_id, anchor_text, created_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    link.id.to_string(),
                    link.source_page_id.to_string(),
                    link.target_page_id.to_string(),
                    link.source_block_id.map(|u| u.to_string()),
                    link.anchor_text,
                    link.created_at.timestamp_millis(),
                ],
            )
            .map_err(|e| CoreError::Database(format!("Bağlantı eklenemedi: {}", e)))?;
        Ok(())
    }

    /// Bir sayfaya gelen bağlantıları (Backlinks) getirir.
    pub fn get_backlinks(&self, target_page_id: Uuid) -> Result<Vec<PageLink>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, source_page_id, target_page_id, source_block_id, anchor_text, created_at
                 FROM page_links WHERE target_page_id = ?1 ORDER BY created_at DESC",
            )
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let rows = stmt
            .query_map(params![target_page_id.to_string()], Self::map_link_row)
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let mut links = Vec::new();
        for r in rows {
            links.push(r.map_err(|e| CoreError::Database(e.to_string()))?);
        }
        Ok(links)
    }

    /// Bir sayfadan çıkan bağlantıları (Outgoing links) getirir.
    pub fn get_outgoing_links(&self, source_page_id: Uuid) -> Result<Vec<PageLink>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, source_page_id, target_page_id, source_block_id, anchor_text, created_at
                 FROM page_links WHERE source_page_id = ?1 ORDER BY created_at DESC",
            )
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let rows = stmt
            .query_map(params![source_page_id.to_string()], Self::map_link_row)
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let mut links = Vec::new();
        for r in rows {
            links.push(r.map_err(|e| CoreError::Database(e.to_string()))?);
        }
        Ok(links)
    }

    /// Bir kaynaktan çıkan tüm bağlantıları siler (blok güncellemelerinde yeniden indeksleme için).
    pub fn delete_links_by_source(&self, source_page_id: Uuid) -> Result<()> {
        self.conn
            .execute(
                "DELETE FROM page_links WHERE source_page_id = ?1",
                params![source_page_id.to_string()],
            )
            .map_err(|e| CoreError::Database(e.to_string()))?;
        Ok(())
    }

    // ------------------------------------------------------------------------
    // Sayfa Etiketleri (Page Tags)
    // ------------------------------------------------------------------------

    /// Sayfaya etiket ekler.
    pub fn add_tag(&self, page_id: Uuid, tag: &str) -> Result<()> {
        let trimmed = tag.trim();
        if trimmed.is_empty() {
            return Err(CoreError::Validation("Etiket boş olamaz".into()));
        }

        self.conn
            .execute(
                "INSERT OR IGNORE INTO page_tags (page_id, tag) VALUES (?1, ?2)",
                params![page_id.to_string(), trimmed],
            )
            .map_err(|e| CoreError::Database(e.to_string()))?;
        Ok(())
    }

    /// Sayfadan etiketi kaldırır.
    pub fn remove_tag(&self, page_id: Uuid, tag: &str) -> Result<()> {
        self.conn
            .execute(
                "DELETE FROM page_tags WHERE page_id = ?1 AND tag = ?2",
                params![page_id.to_string(), tag.trim()],
            )
            .map_err(|e| CoreError::Database(e.to_string()))?;
        Ok(())
    }

    /// Sayfaya ait etiketleri getirir.
    pub fn get_page_tags(&self, page_id: Uuid) -> Result<Vec<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT tag FROM page_tags WHERE page_id = ?1 ORDER BY tag ASC")
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let rows = stmt
            .query_map(params![page_id.to_string()], |row| row.get::<_, String>(0))
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let mut tags = Vec::new();
        for r in rows {
            tags.push(r.map_err(|e| CoreError::Database(e.to_string()))?);
        }
        Ok(tags)
    }

    /// Belirtilen etikete sahip sayfaların kimliklerini listeler.
    pub fn list_pages_by_tag(&self, tag: &str) -> Result<Vec<Uuid>> {
        let mut stmt = self
            .conn
            .prepare("SELECT page_id FROM page_tags WHERE tag = ?1")
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let rows = stmt
            .query_map(params![tag.trim()], |row| row.get::<_, String>(0))
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let mut pages = Vec::new();
        for r in rows {
            let id_str = r.map_err(|e| CoreError::Database(e.to_string()))?;
            let u = Uuid::parse_str(&id_str)
                .map_err(|e| CoreError::Database(format!("Geçersiz sayfa UUID: {}", e)))?;
            pages.push(u);
        }
        Ok(pages)
    }

    // ------------------------------------------------------------------------
    // Senkronizasyon Kuyruğu (Offline Outbox) - Katı FIFO
    // ------------------------------------------------------------------------

    /// Kuyruğa yeni bir senkronizasyon zarfı ekler.
    pub fn enqueue_outbox(&self, item: &OutboxItem) -> Result<()> {
        self.conn
            .execute(
                "INSERT INTO sync_outbox (
                    id, workspace_id, doc_id, envelope_bytes, retry_count, last_error, created_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    item.id.to_string(),
                    item.workspace_id.to_string(),
                    item.doc_id.to_string(),
                    item.envelope_bytes,
                    item.retry_count,
                    item.last_error,
                    item.created_at,
                ],
            )
            .map_err(|e| CoreError::Database(format!("Outbox eklenemedi: {}", e)))?;

        Ok(())
    }

    /// Katı FIFO (`created_at ASC, id ASC`) sıralamasıyla kuyruktaki zarfları çeker.
    pub fn list_outbox_fifo(&self, limit: usize) -> Result<Vec<OutboxItem>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, workspace_id, doc_id, envelope_bytes, retry_count, last_error, created_at
                 FROM sync_outbox
                 ORDER BY created_at ASC, id ASC
                 LIMIT ?1",
            )
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let rows = stmt
            .query_map(params![limit as i64], |row| {
                let id_str: String = row.get(0)?;
                let ws_str: String = row.get(1)?;
                let doc_str: String = row.get(2)?;
                let envelope_bytes: Vec<u8> = row.get(3)?;
                let retry_count: i64 = row.get(4)?;
                let last_error: Option<String> = row.get(5)?;
                let created_at: i64 = row.get(6)?;

                Ok((
                    id_str,
                    ws_str,
                    doc_str,
                    envelope_bytes,
                    retry_count,
                    last_error,
                    created_at,
                ))
            })
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let mut items = Vec::new();
        for r in rows {
            let (id_str, ws_str, doc_str, envelope_bytes, retry_count, last_error, created_at) =
                r.map_err(|e| CoreError::Database(e.to_string()))?;

            let id = Uuid::parse_str(&id_str)
                .map_err(|e| CoreError::Database(format!("Geçersiz outbox id: {}", e)))?;
            let workspace_id = Uuid::parse_str(&ws_str)
                .map_err(|e| CoreError::Database(format!("Geçersiz outbox workspace_id: {}", e)))?;
            let doc_id = Uuid::parse_str(&doc_str)
                .map_err(|e| CoreError::Database(format!("Geçersiz outbox doc_id: {}", e)))?;

            items.push(OutboxItem {
                id,
                workspace_id,
                doc_id,
                envelope_bytes,
                retry_count,
                last_error,
                created_at,
            });
        }

        Ok(items)
    }

    /// Başarıyla sunucuya iletilen outbox kaydını siler.
    pub fn remove_outbox(&self, id: Uuid) -> Result<()> {
        self.conn
            .execute("DELETE FROM sync_outbox WHERE id = ?1", params![id.to_string()])
            .map_err(|e| CoreError::Database(e.to_string()))?;
        Ok(())
    }

    /// Başarısız gönderimde deneme sayısını ve hata mesajını günceller.
    pub fn mark_outbox_retry(&self, id: Uuid, last_error: &str) -> Result<()> {
        self.conn
            .execute(
                "UPDATE sync_outbox SET retry_count = retry_count + 1, last_error = ?1 WHERE id = ?2",
                params![last_error, id.to_string()],
            )
            .map_err(|e| CoreError::Database(e.to_string()))?;
        Ok(())
    }

    // ------------------------------------------------------------------------
    // Dahili Row Dönüştürücüler
    // ------------------------------------------------------------------------

    fn map_page_row(row: &Row<'_>) -> rusqlite::Result<Page> {
        let id_str: String = row.get(0)?;
        let ws_str: String = row.get(1)?;
        let parent_str: Option<String> = row.get(2)?;
        let title: String = row.get(3)?;
        let icon: Option<String> = row.get(4)?;
        let cover_image: Option<String> = row.get(5)?;
        let is_database_num: i32 = row.get(6)?;
        let is_pinned_num: i32 = row.get(7)?;
        let is_deleted_num: i32 = row.get(8)?;
        let created_at_ms: i64 = row.get(9)?;
        let updated_at_ms: i64 = row.get(10)?;

        let id = Uuid::parse_str(&id_str)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e)))?;
        let workspace_id = Uuid::parse_str(&ws_str)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(1, rusqlite::types::Type::Text, Box::new(e)))?;
        let parent_page_id = parent_str
            .map(|s| Uuid::parse_str(&s))
            .transpose()
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(2, rusqlite::types::Type::Text, Box::new(e)))?;

        let created_at = DateTime::from_timestamp_millis(created_at_ms).unwrap_or_else(Utc::now);
        let updated_at = DateTime::from_timestamp_millis(updated_at_ms).unwrap_or_else(Utc::now);

        Ok(Page {
            id,
            workspace_id,
            parent_page_id,
            title,
            icon,
            cover_image,
            is_database: is_database_num != 0,
            is_pinned: is_pinned_num != 0,
            is_deleted: is_deleted_num != 0,
            created_at,
            updated_at,
        })
    }

    fn map_link_row(row: &Row<'_>) -> rusqlite::Result<PageLink> {
        let id_str: String = row.get(0)?;
        let src_str: String = row.get(1)?;
        let tgt_str: String = row.get(2)?;
        let block_str: Option<String> = row.get(3)?;
        let anchor_text: Option<String> = row.get(4)?;
        let created_at_ms: i64 = row.get(5)?;

        let id = Uuid::parse_str(&id_str)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e)))?;
        let source_page_id = Uuid::parse_str(&src_str)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(1, rusqlite::types::Type::Text, Box::new(e)))?;
        let target_page_id = Uuid::parse_str(&tgt_str)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(2, rusqlite::types::Type::Text, Box::new(e)))?;
        let source_block_id = block_str
            .map(|s| Uuid::parse_str(&s))
            .transpose()
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(3, rusqlite::types::Type::Text, Box::new(e)))?;

        let created_at = DateTime::from_timestamp_millis(created_at_ms).unwrap_or_else(Utc::now);

        Ok(PageLink {
            id,
            source_page_id,
            target_page_id,
            source_block_id,
            anchor_text,
            created_at,
        })
    }
}
