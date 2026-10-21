use serde::{Deserialize, Serialize};
use uuid::Uuid;

use notes_core::crdt::PageCrdtDoc;
use notes_core::crypto::{encrypt, generate_nonce};
use notes_core::model::Page;
use notes_core::storage::{OutboxItem, PageRepo};

use crate::state::{AppError, DesktopAppState};

/// Hiyerarşik sayfa ağacı düğümü modeli.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PageTreeNode {
    pub page: Page,
    pub children: Vec<PageTreeNode>,
}

/// Yeni bir sayfa oluşturur, yerel SQLite'a kaydeder ve şifreli CRDT outbox kaydı üretir.
pub fn cmd_create_page(
    state: &DesktopAppState,
    title: &str,
    parent_page_id: Option<Uuid>,
    icon: Option<String>,
    cover_image: Option<String>,
) -> Result<Page, AppError> {
    let (dek, _, _, workspace_id) = state.require_unlocked()?;

    let trimmed = title.trim();
    if trimmed.is_empty() {
        return Err(AppError::ValidationError("Sayfa başlığı boş olamaz".into()));
    }

    let mut page = Page::new(workspace_id, trimmed);
    page.parent_page_id = parent_page_id;
    page.icon = icon;
    page.cover_image = cover_image;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let page_repo = PageRepo::new(store.conn());

    page_repo.create_page(&page)?;

    // CRDT dokümanı oluştur ve başlangıç güncellemesini mühürle
    let crdt_doc = PageCrdtDoc::new();
    crdt_doc.set_title(&page.title);
    if let Some(ref ic) = page.icon {
        crdt_doc.set_icon(Some(ic));
    }
    let update_bytes = crdt_doc.encode_full_update();

    let nonce = generate_nonce();
    let ciphertext = encrypt(dek.as_bytes(), &nonce, &update_bytes)?;

    let mut envelope_bytes = Vec::with_capacity(nonce.len() + ciphertext.len());
    envelope_bytes.extend_from_slice(&nonce);
    envelope_bytes.extend_from_slice(&ciphertext);

    let outbox_item = OutboxItem {
        id: Uuid::now_v7(),
        workspace_id,
        doc_id: page.id,
        envelope_bytes,
        retry_count: 0,
        last_error: None,
        created_at: chrono::Utc::now().timestamp_millis(),
    };

    page_repo.enqueue_outbox(&outbox_item)?;

    Ok(page)
}

/// ID'ye göre sayfa detayını getirir.
pub fn cmd_get_page(state: &DesktopAppState, page_id: Uuid) -> Result<Page, AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let page_repo = PageRepo::new(store.conn());

    page_repo
        .get_page(page_id)?
        .ok_or_else(|| AppError::NotFound(format!("Sayfa bulunamadı: {page_id}")))
}

/// Çalışma alanındaki sayfaları listeler.
pub fn cmd_list_pages(state: &DesktopAppState, include_deleted: bool) -> Result<Vec<Page>, AppError> {
    let (_, _, _, workspace_id) = state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let page_repo = PageRepo::new(store.conn());

    let pages = page_repo.list_workspace_pages(workspace_id, include_deleted)?;
    Ok(pages)
}

/// Hiyerarşik sayfa ağacını oluşturup döndürür.
pub fn cmd_get_page_tree(
    state: &DesktopAppState,
    root_page_id: Option<Uuid>,
    include_deleted: bool,
) -> Result<Vec<PageTreeNode>, AppError> {
    let (_, _, _, workspace_id) = state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let page_repo = PageRepo::new(store.conn());

    let all_pages = page_repo.list_workspace_pages(workspace_id, include_deleted)?;

    let tree = build_page_tree(&all_pages, root_page_id);
    Ok(tree)
}

/// Bir sayfayı başka bir üst sayfanın altına taşır veya kök seviyeye alır.
pub fn cmd_move_page(
    state: &DesktopAppState,
    page_id: Uuid,
    new_parent_id: Option<Uuid>,
) -> Result<Page, AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let page_repo = PageRepo::new(store.conn());

    // Sayfanın var olduğunu doğrula
    let mut page = page_repo
        .get_page(page_id)?
        .ok_or_else(|| AppError::NotFound(format!("Sayfa bulunamadı: {page_id}")))?;

    if Some(page_id) == new_parent_id {
        return Err(AppError::ValidationError("Sayfa kendi kendisinin üst sayfası olamaz".into()));
    }

    page.parent_page_id = new_parent_id;
    page.touch();
    page_repo.update_page(&page)?;

    Ok(page)
}

/// Sayfayı çöpe taşır (soft-delete).
pub fn cmd_soft_delete_page(state: &DesktopAppState, page_id: Uuid) -> Result<(), AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let page_repo = PageRepo::new(store.conn());

    page_repo.soft_delete_page(page_id)?;
    Ok(())
}

/// Çöpteki sayfayı geri yükler.
pub fn cmd_restore_page(state: &DesktopAppState, page_id: Uuid) -> Result<(), AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let page_repo = PageRepo::new(store.conn());

    page_repo.restore_page(page_id)?;
    Ok(())
}

/// Sayfayı ve altındaki blokları kalıcı olarak siler (hard-delete).
pub fn cmd_hard_delete_page(state: &DesktopAppState, page_id: Uuid) -> Result<(), AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let page_repo = PageRepo::new(store.conn());

    page_repo.hard_delete_page(page_id)?;
    Ok(())
}

/// Sayfa başlığını, simgesini veya kapak görselini günceller.
pub fn cmd_update_page(
    state: &DesktopAppState,
    page_id: Uuid,
    title: Option<String>,
    icon: Option<String>,
    cover_image: Option<String>,
) -> Result<Page, AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let page_repo = PageRepo::new(store.conn());

    let mut page = page_repo
        .get_page(page_id)?
        .ok_or_else(|| AppError::NotFound(format!("Sayfa bulunamadı: {page_id}")))?;

    if let Some(t) = title {
        let trimmed = t.trim();
        if !trimmed.is_empty() {
            page.title = trimmed.to_string();
        }
    }
    if let Some(ic) = icon {
        page.icon = Some(ic);
    }
    if let Some(cov) = cover_image {
        page.cover_image = Some(cov);
    }
    page.touch();
    page_repo.update_page(&page)?;

    Ok(page)
}

/// Sayfanın tüm bloklarını birleştirip tek gövde Markdown metni olarak döndürür.
pub fn cmd_get_page_markdown(state: &DesktopAppState, page_id: Uuid) -> Result<String, AppError> {
    let blocks = crate::commands::blocks::cmd_list_blocks(state, page_id)?;
    if blocks.is_empty() {
        return Ok(String::new());
    }

    let texts: Vec<String> = blocks.iter().map(|b| b.extract_plain_text()).collect();
    Ok(texts.join("\n\n"))
}

/// Sayfanın Markdown metnini blok tablosuna, FTS5 arama indeksine, wikilink grafiğine ve outbox'a kaydeder.
pub fn cmd_save_page_markdown(
    state: &DesktopAppState,
    page_id: Uuid,
    markdown: &str,
) -> Result<(), AppError> {
    let blocks = crate::commands::blocks::cmd_list_blocks(state, page_id)?;
    if let Some(first_block) = blocks.first() {
        crate::commands::blocks::cmd_update_block(
            state,
            first_block.id,
            Some(serde_json::json!({ "text": markdown })),
            None,
            None,
        )?;
        if blocks.len() > 1 {
            for extra_block in &blocks[1..] {
                crate::commands::blocks::cmd_delete_block(state, extra_block.id)?;
            }
        }
    } else {
        crate::commands::blocks::cmd_insert_block(
            state,
            page_id,
            None,
            notes_core::model::block::BlockType::Paragraph,
            serde_json::json!({ "text": markdown }),
            None,
            0.0,
        )?;
    }
    Ok(())
}

fn build_page_tree(pages: &[Page], parent_id: Option<Uuid>) -> Vec<PageTreeNode> {
    pages
        .iter()
        .filter(|p| p.parent_page_id == parent_id)
        .map(|p| PageTreeNode {
            page: p.clone(),
            children: build_page_tree(pages, Some(p.id)),
        })
        .collect()
}
