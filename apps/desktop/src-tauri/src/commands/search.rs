use serde::{Deserialize, Serialize};
use uuid::Uuid;

use notes_core::model::page::PageLink;
use notes_core::search::get_all_tags_with_counts;
use notes_core::storage::{BlockRepo, PageRepo};

use crate::state::{AppError, DesktopAppState};

/// FTS5 tam metin arama sonucu DTO modeli.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SearchResultDto {
    pub block_id: Uuid,
    pub page_id: Uuid,
    pub page_title: String,
    pub plain_text: String,
    pub snippet: String,
}

/// FTS5 tam metin araması yapar (Türkçe diyakritik/aksan duyarsız).
pub fn cmd_search_fts(
    state: &DesktopAppState,
    query: &str,
    limit: Option<usize>,
) -> Result<Vec<SearchResultDto>, AppError> {
    state.require_unlocked()?;

    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let block_repo = BlockRepo::new(store.conn());

    let results = block_repo.search_fts(trimmed, limit.unwrap_or(20))?;

    let dtos = results
        .into_iter()
        .map(|r| SearchResultDto {
            block_id: r.block_id,
            page_id: r.page_id,
            page_title: r.page_title,
            plain_text: r.plain_text,
            snippet: r.snippet,
        })
        .collect();

    Ok(dtos)
}

/// Belirtilen sayfaya gelen iki yönlü bağlantıları (Backlinks) getirir.
pub fn cmd_get_backlinks(
    state: &DesktopAppState,
    page_id: Uuid,
) -> Result<Vec<PageLink>, AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let page_repo = PageRepo::new(store.conn());

    let backlinks = page_repo.get_backlinks(page_id)?;
    Ok(backlinks)
}

/// Belirtilen etikete (#tag) sahip sayfaların UUID listesini döndürür.
pub fn cmd_get_pages_by_tag(
    state: &DesktopAppState,
    tag: &str,
) -> Result<Vec<Uuid>, AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let page_repo = PageRepo::new(store.conn());

    let pages = page_repo.list_pages_by_tag(tag)?;
    Ok(pages)
}

/// Sistemdeki tüm etiketleri ve kullanım sayılarını döndürür.
pub fn cmd_get_all_tags(
    state: &DesktopAppState,
) -> Result<Vec<(String, usize)>, AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let stats = get_all_tags_with_counts(store.conn())?;
    Ok(stats)
}
