use uuid::Uuid;

use notes_core::crdt::PageCrdtDoc;
use notes_core::crypto::{encrypt, generate_nonce};
use notes_core::model::block::{Block, BlockType};
use notes_core::model::page::PageLink;
use notes_core::search::{extract_wiki_links, remove_block_index};
use notes_core::storage::{BlockRepo, OutboxItem, PageRepo};

use crate::state::{AppError, DesktopAppState};

/// Belirtilen sayfaya yeni bir blok ekler, şifreler, FTS ve bağlantı indekslerini günceller, outbox'a ekler.
pub fn cmd_insert_block(
    state: &DesktopAppState,
    page_id: Uuid,
    parent_block_id: Option<Uuid>,
    block_type: BlockType,
    content: serde_json::Value,
    properties: Option<serde_json::Value>,
    sort_order: f64,
) -> Result<Block, AppError> {
    let (dek, _, _, workspace_id) = state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let page_repo = PageRepo::new(store.conn());
    let block_repo = BlockRepo::new(store.conn());

    // Sayfanın varlığını doğrula
    let page = page_repo
        .get_page(page_id)?
        .ok_or_else(|| AppError::NotFound(format!("Sayfa bulunamadı: {page_id}")))?;

    let mut block = Block::new(page_id, block_type, sort_order);
    block.parent_block_id = parent_block_id;
    block.content = content;
    if let Some(props) = properties {
        block.properties = props;
    }

    // 1. SQLite Blok tablosuna ekle ve FTS5 indeksini güncelle
    block_repo.insert_block(&block, Some(&page.title))?;

    // 2. İçerikten [[Wikilink]] ve #etiket çıkarıp indeks tablolarına kaydet
    process_block_links_and_tags(&page_repo, workspace_id, &block, &page.title)?;

    // 3. CRDT doküman güncellemesini oluştur ve DEK ile zarflayarak sync_outbox kuyruğuna yaz
    enqueue_crdt_upsert(&page_repo, workspace_id, page_id, &block, &dek)?;

    Ok(block)
}

/// Mevcut bir bloğu günceller, FTS5 ve ilişki indekslerini tazeler, outbox'a ekler.
pub fn cmd_update_block(
    state: &DesktopAppState,
    block_id: Uuid,
    content: Option<serde_json::Value>,
    properties: Option<serde_json::Value>,
    sort_order: Option<f64>,
) -> Result<Block, AppError> {
    let (dek, _, _, workspace_id) = state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let page_repo = PageRepo::new(store.conn());
    let block_repo = BlockRepo::new(store.conn());

    let mut block = block_repo
        .get_block(block_id)?
        .ok_or_else(|| AppError::NotFound(format!("Blok bulunamadı: {block_id}")))?;

    let page = page_repo
        .get_page(block.page_id)?
        .ok_or_else(|| AppError::NotFound(format!("Sayfa bulunamadı: {}", block.page_id)))?;

    if let Some(c) = content {
        block.content = c;
    }
    if let Some(p) = properties {
        block.properties = p;
    }
    if let Some(s) = sort_order {
        block.sort_order = s;
    }
    block.touch();

    // 1. Blok güncelle ve FTS5 indeksini tazele
    block_repo.update_block(&block, Some(&page.title))?;

    // 2. Wikilink ve tag indekslerini tazele
    process_block_links_and_tags(&page_repo, workspace_id, &block, &page.title)?;

    // 3. CRDT outbox zarfını ekle
    enqueue_crdt_upsert(&page_repo, workspace_id, block.page_id, &block, &dek)?;

    Ok(block)
}

/// ID ile blok kaydını getirir.
pub fn cmd_get_block(state: &DesktopAppState, block_id: Uuid) -> Result<Block, AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let block_repo = BlockRepo::new(store.conn());

    block_repo
        .get_block(block_id)?
        .ok_or_else(|| AppError::NotFound(format!("Blok bulunamadı: {block_id}")))
}

/// Sayfadaki tüm blokları artan sort_order sırasında listeler.
pub fn cmd_list_blocks(state: &DesktopAppState, page_id: Uuid) -> Result<Vec<Block>, AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let block_repo = BlockRepo::new(store.conn());

    let blocks = block_repo.list_blocks_by_page(page_id)?;
    Ok(blocks)
}

/// Bir bloğu siler, FTS5 indeksinden temizler ve CRDT outbox kaydı üretir.
pub fn cmd_delete_block(state: &DesktopAppState, block_id: Uuid) -> Result<(), AppError> {
    let (dek, _, _, workspace_id) = state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let page_repo = PageRepo::new(store.conn());
    let block_repo = BlockRepo::new(store.conn());

    let block = block_repo
        .get_block(block_id)?
        .ok_or_else(|| AppError::NotFound(format!("Blok bulunamadı: {block_id}")))?;

    // 1. Blok kaydını ve FTS indeksini sil
    block_repo.delete_block(block_id)?;
    remove_block_index(store.conn(), block_id)?;

    // 2. CRDT outbox'a silme zarfı yaz
    let crdt_doc = PageCrdtDoc::new();
    crdt_doc.remove_block(&block_id.to_string());
    let update_bytes = crdt_doc.encode_full_update();

    let nonce = generate_nonce();
    let ciphertext = encrypt(dek.as_bytes(), &nonce, &update_bytes)?;

    let mut envelope_bytes = Vec::with_capacity(nonce.len() + ciphertext.len());
    envelope_bytes.extend_from_slice(&nonce);
    envelope_bytes.extend_from_slice(&ciphertext);

    let outbox_item = OutboxItem {
        id: Uuid::now_v7(),
        workspace_id,
        doc_id: block.page_id,
        envelope_bytes,
        retry_count: 0,
        last_error: None,
        created_at: chrono::Utc::now().timestamp_millis(),
    };

    page_repo.enqueue_outbox(&outbox_item)?;

    Ok(())
}

/// Bloğun sıralama değerini (sort_order) günceller.
pub fn cmd_reorder_block(
    state: &DesktopAppState,
    block_id: Uuid,
    new_sort_order: f64,
) -> Result<(), AppError> {
    state.require_unlocked()?;

    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let block_repo = BlockRepo::new(store.conn());

    block_repo.reorder_block(block_id, new_sort_order)?;
    Ok(())
}

fn process_block_links_and_tags(
    page_repo: &PageRepo<'_>,
    workspace_id: Uuid,
    block: &Block,
    _page_title: &str,
) -> Result<(), AppError> {
    let plain_text = block.extract_plain_text();

    // 1. Wikilinks [[Sayfa]]
    let links = extract_wiki_links(&plain_text);
    for link in links {
        let target_page_id = if let Some(target_id) = link.target_page_id {
            Some(target_id)
        } else {
            // Başlığa göre hedef sayfayı bul
            page_repo
                .list_workspace_pages(workspace_id, false)
                .ok()
                .and_then(|pages| {
                    pages
                        .into_iter()
                        .find(|p| p.title.eq_ignore_ascii_case(&link.target))
                        .map(|p| p.id)
                })
        };

        if let Some(target_id) = target_page_id {
            if target_id != block.page_id {
                let page_link = PageLink::new(block.page_id, target_id)
                    .with_source_block(block.id)
                    .with_anchor(&link.display_text);
                let _ = page_repo.insert_link(&page_link);
            }
        }
    }

    // 2. Hashtags #etiket
    let tags = extract_hashtags_safe(&plain_text);
    for tag in tags {
        let _ = page_repo.add_tag(block.page_id, &tag);
    }

    Ok(())
}

fn extract_hashtags_safe(text: &str) -> Vec<String> {
    use std::sync::LazyLock;
    use regex::Regex;
    use std::collections::HashSet;

    static SAFE_HASHTAG_REGEX: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?:^|[^\p{Alphabetic}\p{Number}_#])#([\p{Alphabetic}\p{Number}_][\p{Alphabetic}\p{Number}_-]*)")
            .expect("Geçersiz güvenli hashtag deseni")
    });

    let mut seen = HashSet::new();
    let mut tags = Vec::new();

    for cap in SAFE_HASHTAG_REGEX.captures_iter(text) {
        if let Some(matched) = cap.get(1) {
            let normalized = matched.as_str().to_lowercase();
            if seen.insert(normalized.clone()) {
                tags.push(normalized);
            }
        }
    }

    tags
}

fn enqueue_crdt_upsert(
    page_repo: &PageRepo<'_>,
    workspace_id: Uuid,
    page_id: Uuid,
    block: &Block,
    dek: &notes_core::crypto::DataEncryptionKey,
) -> Result<(), AppError> {
    let crdt_doc = PageCrdtDoc::new();
    crdt_doc.upsert_block(block)?;
    let update_bytes = crdt_doc.encode_full_update();

    let nonce = generate_nonce();
    let ciphertext = encrypt(dek.as_bytes(), &nonce, &update_bytes)?;

    let mut envelope_bytes = Vec::with_capacity(nonce.len() + ciphertext.len());
    envelope_bytes.extend_from_slice(&nonce);
    envelope_bytes.extend_from_slice(&ciphertext);

    let outbox_item = OutboxItem {
        id: Uuid::now_v7(),
        workspace_id,
        doc_id: page_id,
        envelope_bytes,
        retry_count: 0,
        last_error: None,
        created_at: chrono::Utc::now().timestamp_millis(),
    };

    page_repo.enqueue_outbox(&outbox_item)?;
    Ok(())
}
