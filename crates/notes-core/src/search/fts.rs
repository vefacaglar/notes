use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::{CoreError, Result};
use crate::model::Block;

/// FTS5 tam metin arama sonuç modeli.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SearchResult {
    /// Eşleşen bloğun kimliği.
    pub block_id: Uuid,
    /// Bloğun ait olduğu sayfanın kimliği.
    pub page_id: Uuid,
    /// Eşleşen sayfanın başlığı.
    pub page_title: String,
    /// `<mark>...</mark>` ile vurgulanmış eşleşme pasajı (snippet).
    pub snippet: String,
    /// BM25 alaka düzeyi skoru (FTS5'te daha küçük/negatif değerler daha yüksek alaka anlamına gelir).
    pub rank: f64,
}

/// FTS5 `fts_blocks` sanal tablosunu oluşturur.
///
/// `ARCHITECTURE.md` Bölüm 5.2 şemasına uygun olarak `unicode61 remove_diacritics 2`
/// tokenleştiricisi kullanılır. Bu sayede Türkçe karakterler (ç, ğ, ö, ş, ü ve bunların aksansız halleri)
/// duyarsız olarak eşleştirilir.
pub fn create_fts_table(conn: &Connection) -> Result<()> {
    conn.execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS fts_blocks USING fts5(
            block_id UNINDEXED,
            page_id UNINDEXED,
            page_title,
            plain_text,
            tokenize = 'unicode61 remove_diacritics 2'
        )",
        [],
    )
    .map_err(|e| CoreError::Database(format!("FTS5 tablosu oluşturulamadı: {e}")))?;

    Ok(())
}

/// Bir bloğu veya sayfa başlığını FTS5 arama indeksine ekler veya günceller.
///
/// Sıfır-bilgi (Zero-Knowledge) mimarisi gereği deşifre edilmiş açık metin
/// yalnızca yerel SQLite FTS5 tablosunda saklanır, asla uzak sunucuya iletilmez.
pub fn index_block(
    conn: &Connection,
    block_id: Uuid,
    page_id: Uuid,
    page_title: &str,
    plain_text: &str,
) -> Result<()> {
    // Varsa eski blok kaydını silerek mükerrerliği önle
    remove_block_index(conn, block_id)?;

    conn.execute(
        "INSERT INTO fts_blocks (block_id, page_id, page_title, plain_text)
         VALUES (?1, ?2, ?3, ?4)",
        params![
            block_id.to_string(),
            page_id.to_string(),
            page_title,
            plain_text,
        ],
    )
    .map_err(|e| CoreError::Database(format!("Blok indekslenemedi: {e}")))?;

    Ok(())
}

/// [`Block`] domain modeli üzerinden blok içeriğini FTS5 indeksine ekler.
pub fn index_block_model(conn: &Connection, block: &Block, page_title: &str) -> Result<()> {
    let plain_text = block.extract_plain_text();
    index_block(conn, block.id, block.page_id, page_title, &plain_text)
}

/// Bir bloğu FTS5 arama indeksinden kaldırır.
pub fn remove_block_index(conn: &Connection, block_id: Uuid) -> Result<()> {
    conn.execute(
        "DELETE FROM fts_blocks WHERE block_id = ?1",
        params![block_id.to_string()],
    )
    .map_err(|e| CoreError::Database(format!("Blok indeksi silinemedi: {e}")))?;

    Ok(())
}

/// Bir sayfaya ait tüm blok indekslerini FTS5 tablosundan kaldırır.
pub fn remove_page_index(conn: &Connection, page_id: Uuid) -> Result<()> {
    conn.execute(
        "DELETE FROM fts_blocks WHERE page_id = ?1",
        params![page_id.to_string()],
    )
    .map_err(|e| CoreError::Database(format!("Sayfa blok indeksleri silinemedi: {e}")))?;

    Ok(())
}

/// Kilit ekranına (Lock Screen) geçildiğinde veya oturum kapatıldığında
/// bellek ve disk güvenliği gereği yerel FTS5 tablosundaki tüm açık metin indekslerini temizler.
pub fn clear_all_index(conn: &Connection) -> Result<()> {
    conn.execute("DELETE FROM fts_blocks", [])
        .map_err(|e| CoreError::Database(format!("FTS5 indeksi temizlenemedi: {e}")))?;

    Ok(())
}

/// Kullanıcı sorgusunu FTS5 uyumlu ve güvenli hale getirir.
///
/// Özel FTS5 operatörlerini temizler ve her terime önek (`*`) joker karakteri
/// ekleyerek yazarken anlık arama (search-as-you-type) deneyimini destekler.
pub fn sanitize_fts5_query(raw_query: &str) -> String {
    let trimmed = raw_query.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    let tokens: Vec<String> = trimmed
        .split_whitespace()
        .filter_map(|word| {
            // FTS5 syntax bozucu özel sembolleri temizle
            let cleaned: String = word
                .chars()
                .filter(|c| {
                    !matches!(
                        c,
                        '"' | '*' | ':' | '^' | '(' | ')' | '{' | '}' | '+' | '~' | '?' | '[' | ']'
                    )
                })
                .collect();

            let cleaned = cleaned.trim();
            if cleaned.is_empty() {
                None
            } else {
                Some(format!("\"{}\"*", cleaned))
            }
        })
        .collect();

    tokens.join(" ")
}

/// Ham bir FTS5 sorgusuyla arama yapar.
pub fn search_blocks_raw(
    conn: &Connection,
    fts_match_query: &str,
    limit: usize,
) -> Result<Vec<SearchResult>> {
    let trimmed = fts_match_query.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }

    let actual_limit = if limit == 0 { 50 } else { limit };

    let mut stmt = conn
        .prepare(
            "SELECT
                block_id,
                page_id,
                page_title,
                snippet(fts_blocks, -1, '<mark>', '</mark>', '...', 16) AS snippet,
                bm25(fts_blocks) AS rank
             FROM fts_blocks
             WHERE fts_blocks MATCH ?1
             ORDER BY rank ASC
             LIMIT ?2",
        )
        .map_err(|e| CoreError::Database(format!("FTS5 arama sorgusu hazırlanamadı: {e}")))?;

    let rows = stmt
        .query_map(params![trimmed, actual_limit as i64], |row| {
            let block_id_str: String = row.get(0)?;
            let page_id_str: String = row.get(1)?;
            let page_title: String = row.get(2)?;
            let snippet: String = row.get(3)?;
            let rank: f64 = row.get(4)?;

            Ok((block_id_str, page_id_str, page_title, snippet, rank))
        })
        .map_err(|e| CoreError::Database(format!("FTS5 arama yürütülemedi: {e}")))?;

    let mut results = Vec::new();
    for row in rows {
        let (block_id_str, page_id_str, page_title, snippet, rank) =
            row.map_err(|e| CoreError::Database(format!("FTS5 satır okuma hatası: {e}")))?;

        let block_id = Uuid::parse_str(&block_id_str)
            .map_err(|e| CoreError::Database(format!("Geçersiz block_id UUID: {e}")))?;
        let page_id = Uuid::parse_str(&page_id_str)
            .map_err(|e| CoreError::Database(format!("Geçersiz page_id UUID: {e}")))?;

        results.push(SearchResult {
            block_id,
            page_id,
            page_title,
            snippet,
            rank,
        });
    }

    Ok(results)
}

/// SQLite FTS5 sanal tablosu üzerinde BM25 sıralamalı ve `<mark>` snippet vurgulamalı
/// tam metin arama gerçekleştirir.
///
/// Sorgu terimleri otomatik olarak sanitize edilir ve önek eşleşmeli hale getirilir.
pub fn search_blocks(
    conn: &Connection,
    query: &str,
    limit: usize,
) -> Result<Vec<SearchResult>> {
    let sanitized = sanitize_fts5_query(query);
    search_blocks_raw(conn, &sanitized, limit)
}
