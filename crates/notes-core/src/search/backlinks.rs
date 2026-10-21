use std::collections::HashSet;
use std::sync::LazyLock;

use regex::Regex;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::{CoreError, Result};
use crate::model::{PageLink, Tag};

/// Wiki bağlantısı regex deseni (`[[Hedef]]` veya `[[Hedef|Görünen Başlık]]`).
static WIKI_LINK_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[\[([^\]\r\n]+)\]\]").expect("Geçersiz wiki link regex deseni"));

/// Metin içi `#etiket` regex deseni.
/// Başlık (`## `) ve link içi URL fragment (`site.com#anchor`) durumlarını hariç tutar.
static HASHTAG_REGEX: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?:^|[^\p{Alphabetic}\p{Number}_#])#([\p{Alphabetic}\p{Number}_][\p{Alphabetic}\p{Number}_-]*)")
        .expect("Geçersiz hashtag regex deseni")
});

/// Metin içinden ayrıştırılan çift yönlü bağlantı (Wikilink) bilgisi.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParsedWikiLink {
    /// Bağlantının hedefi (UUID string veya sayfa başlığı).
    pub target: String,
    /// Eğer hedef geçerli bir UUID formatındaysa ayrıştırılmış kimlik.
    pub target_page_id: Option<Uuid>,
    /// Kullanıcı arayüzünde görüntülenecek metin / çapa (anchor text).
    pub display_text: String,
}

/// Metin içerisindeki tüm `[[Sayfa Başlığı]]` veya `[[page_id|Başlık]]`
/// biçimindeki wiki bağlantılarını ayrıştırır.
pub fn extract_wiki_links(text: &str) -> Vec<ParsedWikiLink> {
    let mut links = Vec::new();

    for cap in WIKI_LINK_REGEX.captures_iter(text) {
        if let Some(matched) = cap.get(1) {
            let inner = matched.as_str().trim();
            if inner.is_empty() {
                continue;
            }

            let (target, display_text) = if let Some((target_part, anchor_part)) = inner.split_once('|') {
                let t = target_part.trim();
                let a = anchor_part.trim();
                if t.is_empty() {
                    continue;
                }
                let disp = if a.is_empty() {
                    t.to_string()
                } else {
                    a.to_string()
                };
                (t.to_string(), disp)
            } else {
                (inner.to_string(), inner.to_string())
            };

            let target_page_id = Uuid::parse_str(&target).ok();

            links.push(ParsedWikiLink {
                target,
                target_page_id,
                display_text,
            });
        }
    }

    links
}

/// Metin içerisindeki tüm `#etiket` ifadelerini ayrıştırır.
///
/// Türkçe karakterleri ve altçizgi/tire kombinasyonlarını destekler.
/// Yinelenen etiketler sırası korunarak tekilleştirilir ve normalize edilir.
pub fn extract_hashtags(text: &str) -> Vec<String> {
    let mut tags = Vec::new();
    let mut seen = HashSet::new();

    for cap in HASHTAG_REGEX.captures_iter(text) {
        if let Some(matched) = cap.get(1) {
            let raw_match = matched.as_str().trim_end_matches(['-', '_']);
            // Türkçe büyük İ/I harflerinin Unicode standardında birleşik noktalı \u{307}
            // karakterine ayrışmasını önlemek için ön dönüşüm yapılır.
            let tr_prepared: String = raw_match
                .chars()
                .map(|c| match c {
                    'İ' => 'i',
                    'I' => 'ı',
                    other => other,
                })
                .collect();

            if let Ok(normalized) = Tag::normalize(&tr_prepared) {
                if seen.insert(normalized.clone()) {
                    tags.push(normalized);
                }
            }
        }
    }

    tags
}

/// `page_links` ve `page_tags` tablolarını ve gerekli indeksleri oluşturur.
///
/// `ARCHITECTURE.md` Bölüm 5.2 şemasına birebir uyar.
pub fn create_backlink_tables(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS page_links (
            id TEXT PRIMARY KEY NOT NULL,
            source_page_id TEXT NOT NULL,
            target_page_id TEXT NOT NULL,
            source_block_id TEXT,
            anchor_text TEXT,
            created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_links_target ON page_links(target_page_id);
        CREATE INDEX IF NOT EXISTS idx_links_source ON page_links(source_page_id);

        CREATE TABLE IF NOT EXISTS page_tags (
            page_id TEXT NOT NULL,
            tag TEXT NOT NULL,
            PRIMARY KEY(page_id, tag)
        );
        CREATE INDEX IF NOT EXISTS idx_tags_tag ON page_tags(tag);",
    )
    .map_err(|e| CoreError::Database(format!("Backlink tabloları oluşturulamadı: {e}")))?;

    Ok(())
}

/// Sayfalar arası yeni bir bağlantıyı `page_links` tablosuna kaydeder.
pub fn insert_page_link(conn: &Connection, link: &PageLink) -> Result<()> {
    conn.execute(
        "INSERT INTO page_links (id, source_page_id, target_page_id, source_block_id, anchor_text, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            link.id.to_string(),
            link.source_page_id.to_string(),
            link.target_page_id.to_string(),
            link.source_block_id.map(|id| id.to_string()),
            link.anchor_text.as_deref(),
            link.created_at.timestamp_millis(),
        ],
    )
    .map_err(|e| CoreError::Database(format!("Sayfa bağlantısı eklenemedi: {e}")))?;

    Ok(())
}

/// Belirtilen bağlantıyı kimliğine göre siler.
pub fn delete_page_link(conn: &Connection, link_id: Uuid) -> Result<()> {
    conn.execute(
        "DELETE FROM page_links WHERE id = ?1",
        params![link_id.to_string()],
    )
    .map_err(|e| CoreError::Database(format!("Sayfa bağlantısı silinemedi: {e}")))?;

    Ok(())
}

/// Kaynak sayfadan çıkan tüm bağlantıları siler.
pub fn delete_page_links_for_source(conn: &Connection, source_page_id: Uuid) -> Result<()> {
    conn.execute(
        "DELETE FROM page_links WHERE source_page_id = ?1",
        params![source_page_id.to_string()],
    )
    .map_err(|e| CoreError::Database(format!("Kaynak sayfa bağlantıları silinemedi: {e}")))?;

    Ok(())
}

/// Belirli bir bloktan türetilmiş tüm bağlantıları siler.
pub fn delete_page_links_for_block(conn: &Connection, source_block_id: Uuid) -> Result<()> {
    conn.execute(
        "DELETE FROM page_links WHERE source_block_id = ?1",
        params![source_block_id.to_string()],
    )
    .map_err(|e| CoreError::Database(format!("Blok bağlantıları silinemedi: {e}")))?;

    Ok(())
}

/// Kaynak sayfaya ait bağlantıları yenileriyle atomik olarak günceller.
pub fn sync_page_links(
    conn: &Connection,
    source_page_id: Uuid,
    links: &[PageLink],
) -> Result<()> {
    delete_page_links_for_source(conn, source_page_id)?;
    for link in links {
        insert_page_link(conn, link)?;
    }
    Ok(())
}

/// Bir bloğa ait bağlantıları günceller (blok yeniden düzenlendiğinde).
pub fn sync_block_links(
    conn: &Connection,
    source_block_id: Uuid,
    links: &[PageLink],
) -> Result<()> {
    delete_page_links_for_block(conn, source_block_id)?;
    for link in links {
        insert_page_link(conn, link)?;
    }
    Ok(())
}

/// Bir sayfaya gelen tüm çift yönlü bağlantıları (Backlinks) listeler.
pub fn get_backlinks_for_page(
    conn: &Connection,
    target_page_id: Uuid,
) -> Result<Vec<PageLink>> {
    let mut stmt = conn
        .prepare(
            "SELECT id, source_page_id, target_page_id, source_block_id, anchor_text, created_at
             FROM page_links
             WHERE target_page_id = ?1
             ORDER BY created_at DESC",
        )
        .map_err(|e| CoreError::Database(format!("Backlink sorgusu hazırlanamadı: {e}")))?;

    let rows = stmt
        .query_map(params![target_page_id.to_string()], |row| {
            let id_str: String = row.get(0)?;
            let src_str: String = row.get(1)?;
            let tgt_str: String = row.get(2)?;
            let block_str: Option<String> = row.get(3)?;
            let anchor_text: Option<String> = row.get(4)?;
            let ts: i64 = row.get(5)?;

            Ok((id_str, src_str, tgt_str, block_str, anchor_text, ts))
        })
        .map_err(|e| CoreError::Database(format!("Backlinkler çekilemedi: {e}")))?;

    let mut links = Vec::new();
    for row in rows {
        let (id_str, src_str, tgt_str, block_str, anchor_text, ts) =
            row.map_err(|e| CoreError::Database(format!("Satır okuma hatası: {e}")))?;

        let id = Uuid::parse_str(&id_str)
            .map_err(|e| CoreError::Database(format!("Geçersiz id UUID: {e}")))?;
        let source_page_id = Uuid::parse_str(&src_str)
            .map_err(|e| CoreError::Database(format!("Geçersiz source_page_id UUID: {e}")))?;
        let target_page_id = Uuid::parse_str(&tgt_str)
            .map_err(|e| CoreError::Database(format!("Geçersiz target_page_id UUID: {e}")))?;
        let source_block_id = match block_str {
            Some(s) if !s.is_empty() => Some(
                Uuid::parse_str(&s)
                    .map_err(|e| CoreError::Database(format!("Geçersiz source_block_id UUID: {e}")))?,
            ),
            _ => None,
        };
        let created_at = chrono::DateTime::from_timestamp_millis(ts)
            .or_else(|| chrono::DateTime::from_timestamp(ts, 0))
            .unwrap_or_else(chrono::Utc::now);

        links.push(PageLink {
            id,
            source_page_id,
            target_page_id,
            source_block_id,
            anchor_text,
            created_at,
        });
    }

    Ok(links)
}

/// Bir sayfadan çıkan giden bağlantıları (Outgoing Links) listeler.
pub fn get_outgoing_links_for_page(
    conn: &Connection,
    source_page_id: Uuid,
) -> Result<Vec<PageLink>> {
    let mut stmt = conn
        .prepare(
            "SELECT id, source_page_id, target_page_id, source_block_id, anchor_text, created_at
             FROM page_links
             WHERE source_page_id = ?1
             ORDER BY created_at ASC",
        )
        .map_err(|e| CoreError::Database(format!("Giden bağlantı sorgusu hazırlanamadı: {e}")))?;

    let rows = stmt
        .query_map(params![source_page_id.to_string()], |row| {
            let id_str: String = row.get(0)?;
            let src_str: String = row.get(1)?;
            let tgt_str: String = row.get(2)?;
            let block_str: Option<String> = row.get(3)?;
            let anchor_text: Option<String> = row.get(4)?;
            let ts: i64 = row.get(5)?;

            Ok((id_str, src_str, tgt_str, block_str, anchor_text, ts))
        })
        .map_err(|e| CoreError::Database(format!("Giden bağlantılar çekilemedi: {e}")))?;

    let mut links = Vec::new();
    for row in rows {
        let (id_str, src_str, tgt_str, block_str, anchor_text, ts) =
            row.map_err(|e| CoreError::Database(format!("Satır okuma hatası: {e}")))?;

        let id = Uuid::parse_str(&id_str)
            .map_err(|e| CoreError::Database(format!("Geçersiz id UUID: {e}")))?;
        let source_page_id = Uuid::parse_str(&src_str)
            .map_err(|e| CoreError::Database(format!("Geçersiz source_page_id UUID: {e}")))?;
        let target_page_id = Uuid::parse_str(&tgt_str)
            .map_err(|e| CoreError::Database(format!("Geçersiz target_page_id UUID: {e}")))?;
        let source_block_id = match block_str {
            Some(s) if !s.is_empty() => Some(
                Uuid::parse_str(&s)
                    .map_err(|e| CoreError::Database(format!("Geçersiz source_block_id UUID: {e}")))?,
            ),
            _ => None,
        };
        let created_at = chrono::DateTime::from_timestamp_millis(ts)
            .or_else(|| chrono::DateTime::from_timestamp(ts, 0))
            .unwrap_or_else(chrono::Utc::now);

        links.push(PageLink {
            id,
            source_page_id,
            target_page_id,
            source_block_id,
            anchor_text,
            created_at,
        });
    }

    Ok(links)
}

/// Bir sayfaya tekil bir etiket ekler.
pub fn add_page_tag(conn: &Connection, page_id: Uuid, raw_tag: &str) -> Result<()> {
    let normalized = Tag::normalize(raw_tag)?;
    conn.execute(
        "INSERT OR IGNORE INTO page_tags (page_id, tag) VALUES (?1, ?2)",
        params![page_id.to_string(), normalized],
    )
    .map_err(|e| CoreError::Database(format!("Sayfa etiketi eklenemedi: {e}")))?;

    Ok(())
}

/// Bir sayfadan belirtilen etiketi kaldırır.
pub fn remove_page_tag(conn: &Connection, page_id: Uuid, raw_tag: &str) -> Result<()> {
    let normalized = Tag::normalize(raw_tag)?;
    conn.execute(
        "DELETE FROM page_tags WHERE page_id = ?1 AND tag = ?2",
        params![page_id.to_string(), normalized],
    )
    .map_err(|e| CoreError::Database(format!("Sayfa etiketi silinemedi: {e}")))?;

    Ok(())
}

/// Bir sayfanın etiketlerini verilen yeni liste ile atomik olarak günceller.
pub fn sync_page_tags(conn: &Connection, page_id: Uuid, tags: &[String]) -> Result<()> {
    conn.execute(
        "DELETE FROM page_tags WHERE page_id = ?1",
        params![page_id.to_string()],
    )
    .map_err(|e| CoreError::Database(format!("Mevcut etiketler temizlenemedi: {e}")))?;

    let mut stmt = conn
        .prepare("INSERT OR IGNORE INTO page_tags (page_id, tag) VALUES (?1, ?2)")
        .map_err(|e| CoreError::Database(format!("Etiket sorgusu hazırlanamadı: {e}")))?;

    for raw_tag in tags {
        if let Ok(normalized) = Tag::normalize(raw_tag) {
            stmt.execute(params![page_id.to_string(), normalized])
                .map_err(|e| CoreError::Database(format!("Etiket eklenemedi: {e}")))?;
        }
    }

    Ok(())
}

/// Bir sayfaya atanmış tüm etiketleri alfabetik sırada döndürür.
pub fn get_tags_for_page(conn: &Connection, page_id: Uuid) -> Result<Vec<String>> {
    let mut stmt = conn
        .prepare("SELECT tag FROM page_tags WHERE page_id = ?1 ORDER BY tag ASC")
        .map_err(|e| CoreError::Database(format!("Sayfa etiketleri sorgusu hazırlanamadı: {e}")))?;

    let rows = stmt
        .query_map(params![page_id.to_string()], |row| row.get(0))
        .map_err(|e| CoreError::Database(format!("Sayfa etiketleri çekilemedi: {e}")))?;

    let mut tags = Vec::new();
    for tag_res in rows {
        tags.push(tag_res.map_err(|e| CoreError::Database(e.to_string()))?);
    }

    Ok(tags)
}

/// Belirtilen etikete sahip tüm sayfa kimliklerini döndürür.
pub fn get_pages_by_tag(conn: &Connection, raw_tag: &str) -> Result<Vec<Uuid>> {
    let normalized = Tag::normalize(raw_tag)?;
    let mut stmt = conn
        .prepare("SELECT page_id FROM page_tags WHERE tag = ?1 ORDER BY page_id ASC")
        .map_err(|e| CoreError::Database(format!("Etiketli sayfalar sorgusu hazırlanamadı: {e}")))?;

    let rows = stmt
        .query_map(params![normalized], |row| row.get::<_, String>(0))
        .map_err(|e| CoreError::Database(format!("Etiketli sayfalar çekilemedi: {e}")))?;

    let mut page_ids = Vec::new();
    for id_res in rows {
        let id_str = id_res.map_err(|e| CoreError::Database(e.to_string()))?;
        let page_id = Uuid::parse_str(&id_str)
            .map_err(|e| CoreError::Database(format!("Geçersiz page_id UUID: {e}")))?;
        page_ids.push(page_id);
    }

    Ok(page_ids)
}

/// Tüm etiketleri kullanım frekansına göre (çoktan aza) ve alfabetik olarak listeler.
pub fn get_all_tags_with_counts(conn: &Connection) -> Result<Vec<(String, usize)>> {
    let mut stmt = conn
        .prepare(
            "SELECT tag, COUNT(page_id) AS cnt
             FROM page_tags
             GROUP BY tag
             ORDER BY cnt DESC, tag ASC",
        )
        .map_err(|e| CoreError::Database(format!("Etiket istatistik sorgusu hazırlanamadı: {e}")))?;

    let rows = stmt
        .query_map([], |row| {
            let tag: String = row.get(0)?;
            let count: i64 = row.get(1)?;
            Ok((tag, count as usize))
        })
        .map_err(|e| CoreError::Database(format!("Etiket istatistikleri çekilemedi: {e}")))?;

    let mut stats = Vec::new();
    for stat_res in rows {
        stats.push(stat_res.map_err(|e| CoreError::Database(e.to_string()))?);
    }

    Ok(stats)
}
