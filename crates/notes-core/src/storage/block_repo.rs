use chrono::{DateTime, Utc};
use rusqlite::{params, Connection, Row};
use uuid::Uuid;

use crate::error::{CoreError, Result};
use crate::model::block::{Block, BlockType};

/// FTS5 tam metin arama sonucu modeli.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchResult {
    pub block_id: Uuid,
    pub page_id: Uuid,
    pub page_title: String,
    pub plain_text: String,
    pub snippet: String,
}

/// Blok CRUD, sıralama hiyerarşisi ve FTS5 indeksleme işlemlerini yürüten repository.
pub struct BlockRepo<'a> {
    conn: &'a Connection,
}

impl<'a> BlockRepo<'a> {
    /// Yeni bir `BlockRepo` örneği oluşturur.
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// Yeni bir bloğu veritabanına ekler ve FTS5 tam metin indeksine kaydeder.
    pub fn insert_block(&self, block: &Block, page_title: Option<&str>) -> Result<()> {
        let content_json = serde_json::to_string(&block.content)
            .map_err(|e| CoreError::Serialization(e.to_string()))?;
        let properties_json = serde_json::to_string(&block.properties)
            .map_err(|e| CoreError::Serialization(e.to_string()))?;

        self.conn
            .execute(
                "INSERT INTO blocks (
                    id, page_id, parent_block_id, block_type, content_json, properties_json,
                    sort_order, created_at, updated_at
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    block.id.to_string(),
                    block.page_id.to_string(),
                    block.parent_block_id.map(|u| u.to_string()),
                    block.block_type.as_str(),
                    content_json,
                    properties_json,
                    block.sort_order,
                    block.created_at.timestamp_millis(),
                    block.updated_at.timestamp_millis(),
                ],
            )
            .map_err(|e| CoreError::Database(format!("Blok eklenemedi: {}", e)))?;

        // FTS5 Sanal Tablosunu Güncelle
        let plain_text = block.extract_plain_text();
        let title = page_title.unwrap_or("");
        self.conn
            .execute(
                "INSERT INTO fts_blocks (block_id, page_id, page_title, plain_text) VALUES (?1, ?2, ?3, ?4)",
                params![block.id.to_string(), block.page_id.to_string(), title, plain_text],
            )
            .map_err(|e| CoreError::Database(format!("FTS indeksi eklenemedi: {}", e)))?;

        Ok(())
    }

    /// ID ile blok kaydını getirir.
    pub fn get_block(&self, id: Uuid) -> Result<Option<Block>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, page_id, parent_block_id, block_type, content_json, properties_json,
                        sort_order, created_at, updated_at
                 FROM blocks WHERE id = ?1",
            )
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let mut rows = stmt
            .query(params![id.to_string()])
            .map_err(|e| CoreError::Database(e.to_string()))?;

        if let Some(row) = rows.next().map_err(|e| CoreError::Database(e.to_string()))? {
            let block = Self::map_block_row(row).map_err(|e| CoreError::Database(e.to_string()))?;
            Ok(Some(block))
        } else {
            Ok(None)
        }
    }

    /// Bloğu günceller ve FTS5 indeksindeki metnini yeniler.
    pub fn update_block(&self, block: &Block, page_title: Option<&str>) -> Result<()> {
        let content_json = serde_json::to_string(&block.content)
            .map_err(|e| CoreError::Serialization(e.to_string()))?;
        let properties_json = serde_json::to_string(&block.properties)
            .map_err(|e| CoreError::Serialization(e.to_string()))?;

        let affected = self
            .conn
            .execute(
                "UPDATE blocks SET
                    parent_block_id = ?1,
                    block_type = ?2,
                    content_json = ?3,
                    properties_json = ?4,
                    sort_order = ?5,
                    updated_at = ?6
                 WHERE id = ?7",
                params![
                    block.parent_block_id.map(|u| u.to_string()),
                    block.block_type.as_str(),
                    content_json,
                    properties_json,
                    block.sort_order,
                    block.updated_at.timestamp_millis(),
                    block.id.to_string(),
                ],
            )
            .map_err(|e| CoreError::Database(format!("Blok güncellenemedi: {}", e)))?;

        if affected == 0 {
            return Err(CoreError::NotFound(format!("Blok bulunamadı: {}", block.id)));
        }

        // FTS İndeksini Yenile
        let plain_text = block.extract_plain_text();
        let title = page_title.unwrap_or("");
        let _ = self.conn.execute(
            "DELETE FROM fts_blocks WHERE block_id = ?1",
            params![block.id.to_string()],
        );
        self.conn
            .execute(
                "INSERT INTO fts_blocks (block_id, page_id, page_title, plain_text) VALUES (?1, ?2, ?3, ?4)",
                params![block.id.to_string(), block.page_id.to_string(), title, plain_text],
            )
            .map_err(|e| CoreError::Database(format!("FTS indeksi güncellenemedi: {}", e)))?;

        Ok(())
    }

    /// Bir bloğu ve FTS indeksini siler.
    pub fn delete_block(&self, id: Uuid) -> Result<()> {
        let affected = self
            .conn
            .execute("DELETE FROM blocks WHERE id = ?1", params![id.to_string()])
            .map_err(|e| CoreError::Database(format!("Blok silinemedi: {}", e)))?;

        if affected == 0 {
            return Err(CoreError::NotFound(format!("Blok bulunamadı: {}", id)));
        }

        let _ = self.conn.execute(
            "DELETE FROM fts_blocks WHERE block_id = ?1",
            params![id.to_string()],
        );

        Ok(())
    }

    /// Bir sayfaya ait tüm blokları `sort_order ASC` sıralamasıyla listeler.
    pub fn list_blocks_by_page(&self, page_id: Uuid) -> Result<Vec<Block>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, page_id, parent_block_id, block_type, content_json, properties_json,
                        sort_order, created_at, updated_at
                 FROM blocks WHERE page_id = ?1 ORDER BY sort_order ASC",
            )
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let rows = stmt
            .query_map(params![page_id.to_string()], Self::map_block_row)
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let mut blocks = Vec::new();
        for r in rows {
            blocks.push(r.map_err(|e| CoreError::Database(e.to_string()))?);
        }
        Ok(blocks)
    }

    /// Bir üst bloğun doğrudan altındaki çocuk blokları listeler.
    pub fn list_child_blocks(&self, parent_block_id: Uuid) -> Result<Vec<Block>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, page_id, parent_block_id, block_type, content_json, properties_json,
                        sort_order, created_at, updated_at
                 FROM blocks WHERE parent_block_id = ?1 ORDER BY sort_order ASC",
            )
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let rows = stmt
            .query_map(params![parent_block_id.to_string()], Self::map_block_row)
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let mut blocks = Vec::new();
        for r in rows {
            blocks.push(r.map_err(|e| CoreError::Database(e.to_string()))?);
        }
        Ok(blocks)
    }

    /// Bir sayfaya ait tüm blokları ve ilgili FTS indekslerini temizler.
    pub fn delete_blocks_by_page(&self, page_id: Uuid) -> Result<()> {
        let pid_str = page_id.to_string();
        self.conn
            .execute("DELETE FROM blocks WHERE page_id = ?1", params![pid_str])
            .map_err(|e| CoreError::Database(e.to_string()))?;

        let _ = self.conn.execute("DELETE FROM fts_blocks WHERE page_id = ?1", params![pid_str]);

        Ok(())
    }

    /// Bloğun sıralama değerini (sort_order) günceller.
    pub fn reorder_block(&self, id: Uuid, new_sort_order: f64) -> Result<()> {
        let now = Utc::now().timestamp_millis();
        let affected = self
            .conn
            .execute(
                "UPDATE blocks SET sort_order = ?1, updated_at = ?2 WHERE id = ?3",
                params![new_sort_order, now, id.to_string()],
            )
            .map_err(|e| CoreError::Database(format!("Sıralama güncellenemedi: {}", e)))?;

        if affected == 0 {
            return Err(CoreError::NotFound(format!("Blok bulunamadı: {}", id)));
        }
        Ok(())
    }

    /// FTS5 arama motorunda tam metin araması gerçekleştirir ve vurgulanmış snippet döndürür.
    pub fn search_fts(&self, query: &str, limit: usize) -> Result<Vec<SearchResult>> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }

        // FTS5 MATCH formatına uygun hale getirme: tırnak içermeyen kelimeleri prefix aramaya dönüştürme
        let sanitized_query = if trimmed.contains('"') || trimmed.contains('*') {
            trimmed.to_string()
        } else {
            let terms: Vec<String> = trimmed
                .split_whitespace()
                .map(|t| format!("{}*", t))
                .collect();
            terms.join(" ")
        };

        let mut stmt = self
            .conn
            .prepare(
                "SELECT block_id, page_id, page_title, plain_text,
                        snippet(fts_blocks, 3, '<b>', '</b>', '...', 10)
                 FROM fts_blocks
                 WHERE fts_blocks MATCH ?1
                 ORDER BY rank
                 LIMIT ?2",
            )
            .map_err(|e| CoreError::Database(format!("FTS arama hazırlığı başarısız: {}", e)))?;

        let rows = stmt
            .query_map(params![sanitized_query, limit as i64], |row| {
                let block_id_str: String = row.get(0)?;
                let page_id_str: String = row.get(1)?;
                let page_title: String = row.get(2)?;
                let plain_text: String = row.get(3)?;
                let snippet: String = row.get(4)?;

                Ok((block_id_str, page_id_str, page_title, plain_text, snippet))
            })
            .map_err(|e| CoreError::Database(format!("FTS arama sorgusu başarısız: {}", e)))?;

        let mut results = Vec::new();
        for r in rows {
            let (b_str, p_str, page_title, plain_text, snippet) =
                r.map_err(|e| CoreError::Database(e.to_string()))?;

            let block_id = Uuid::parse_str(&b_str)
                .map_err(|e| CoreError::Database(format!("Geçersiz block UUID: {}", e)))?;
            let page_id = Uuid::parse_str(&p_str)
                .map_err(|e| CoreError::Database(format!("Geçersiz page UUID: {}", e)))?;

            results.push(SearchResult {
                block_id,
                page_id,
                page_title,
                plain_text,
                snippet,
            });
        }

        Ok(results)
    }

    // ------------------------------------------------------------------------
    // Dahili Row Dönüştürücü
    // ------------------------------------------------------------------------

    fn map_block_row(row: &Row<'_>) -> rusqlite::Result<Block> {
        let id_str: String = row.get(0)?;
        let page_id_str: String = row.get(1)?;
        let parent_str: Option<String> = row.get(2)?;
        let block_type_str: String = row.get(3)?;
        let content_json_str: String = row.get(4)?;
        let properties_json_str: String = row.get(5)?;
        let sort_order: f64 = row.get(6)?;
        let created_at_ms: i64 = row.get(7)?;
        let updated_at_ms: i64 = row.get(8)?;

        let id = Uuid::parse_str(&id_str)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e)))?;
        let page_id = Uuid::parse_str(&page_id_str)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(1, rusqlite::types::Type::Text, Box::new(e)))?;
        let parent_block_id = parent_str
            .map(|s| Uuid::parse_str(&s))
            .transpose()
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(2, rusqlite::types::Type::Text, Box::new(e)))?;

        let block_type = parse_block_type(&block_type_str)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(3, rusqlite::types::Type::Text, Box::new(e)))?;

        let content: serde_json::Value = serde_json::from_str(&content_json_str)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(4, rusqlite::types::Type::Text, Box::new(e)))?;

        let properties: serde_json::Value = serde_json::from_str(&properties_json_str)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(5, rusqlite::types::Type::Text, Box::new(e)))?;

        let created_at = DateTime::from_timestamp_millis(created_at_ms).unwrap_or_else(Utc::now);
        let updated_at = DateTime::from_timestamp_millis(updated_at_ms).unwrap_or_else(Utc::now);

        Ok(Block {
            id,
            page_id,
            parent_block_id,
            block_type,
            content,
            properties,
            sort_order,
            created_at,
            updated_at,
        })
    }
}

fn parse_block_type(s: &str) -> Result<BlockType> {
    match s {
        "paragraph" => Ok(BlockType::Paragraph),
        "heading1" => Ok(BlockType::Heading1),
        "heading2" => Ok(BlockType::Heading2),
        "heading3" => Ok(BlockType::Heading3),
        "bullet_list_item" => Ok(BlockType::BulletListItem),
        "numbered_list_item" => Ok(BlockType::NumberedListItem),
        "todo_item" => Ok(BlockType::TodoItem),
        "code_block" => Ok(BlockType::CodeBlock),
        "quote" => Ok(BlockType::Quote),
        "callout" => Ok(BlockType::Callout),
        "divider" => Ok(BlockType::Divider),
        "image" => Ok(BlockType::Image),
        "file" => Ok(BlockType::File),
        "database_inline" => Ok(BlockType::DatabaseInline),
        other => Err(CoreError::InvalidBlockType(other.to_string())),
    }
}
