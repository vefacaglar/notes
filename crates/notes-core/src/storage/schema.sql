-- ============================================================================
-- Notes Yerel SQLite Şeması
-- Local-First, Zero-Knowledge E2EE & CRDT Senkronizasyon Veri Katmanı
-- ============================================================================

-- 1. Çalışma Alanları (Yerel Depolama)
CREATE TABLE IF NOT EXISTS workspaces (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    encrypted_dek BLOB NOT NULL,
    dek_nonce BLOB NOT NULL,
    created_at INTEGER NOT NULL
);

-- 2. Sayfalar
CREATE TABLE IF NOT EXISTS pages (
    id TEXT PRIMARY KEY NOT NULL,
    workspace_id TEXT NOT NULL,
    parent_page_id TEXT,
    title TEXT NOT NULL,
    icon TEXT,
    cover_image TEXT,
    is_database INTEGER NOT NULL DEFAULT 0,
    is_pinned INTEGER NOT NULL DEFAULT 0,
    is_deleted INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY(workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE,
    FOREIGN KEY(parent_page_id) REFERENCES pages(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_pages_workspace ON pages(workspace_id);
CREATE INDEX IF NOT EXISTS idx_pages_parent ON pages(parent_page_id);
CREATE INDEX IF NOT EXISTS idx_pages_deleted ON pages(workspace_id, is_deleted);

-- 3. Bloklar (Yerel materialize edilmiş görünüm)
CREATE TABLE IF NOT EXISTS blocks (
    id TEXT PRIMARY KEY NOT NULL,
    page_id TEXT NOT NULL,
    parent_block_id TEXT,
    block_type TEXT NOT NULL,
    content_json TEXT NOT NULL,
    properties_json TEXT NOT NULL DEFAULT '{}',
    sort_order REAL NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY(page_id) REFERENCES pages(id) ON DELETE CASCADE,
    FOREIGN KEY(parent_block_id) REFERENCES blocks(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_blocks_page_sort ON blocks(page_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_blocks_parent ON blocks(parent_block_id);

-- 4. Veritabanları (Database Şemaları)
CREATE TABLE IF NOT EXISTS databases (
    id TEXT PRIMARY KEY NOT NULL,
    page_id TEXT NOT NULL,
    properties_json TEXT NOT NULL DEFAULT '[]',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY(page_id) REFERENCES pages(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_databases_page ON databases(page_id);

-- 5. Veritabanı Görünümleri (Views: Table, Board, Calendar vb.)
CREATE TABLE IF NOT EXISTS database_views (
    id TEXT PRIMARY KEY NOT NULL,
    database_id TEXT NOT NULL,
    title TEXT NOT NULL,
    view_type TEXT NOT NULL,
    filter_groups_json TEXT NOT NULL DEFAULT '[]',
    sort_rules_json TEXT NOT NULL DEFAULT '[]',
    visible_properties_json TEXT NOT NULL DEFAULT '[]',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    FOREIGN KEY(database_id) REFERENCES databases(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_views_database ON database_views(database_id);

-- 6. İki Yönlü Bağlantılar (Backlinks & Wikilinks)
CREATE TABLE IF NOT EXISTS page_links (
    id TEXT PRIMARY KEY NOT NULL,
    source_page_id TEXT NOT NULL,
    target_page_id TEXT NOT NULL,
    source_block_id TEXT,
    anchor_text TEXT,
    created_at INTEGER NOT NULL,
    FOREIGN KEY(source_page_id) REFERENCES pages(id) ON DELETE CASCADE,
    FOREIGN KEY(target_page_id) REFERENCES pages(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_links_target ON page_links(target_page_id);
CREATE INDEX IF NOT EXISTS idx_links_source ON page_links(source_page_id);

-- 7. Sayfa Etiketleri (Tags)
CREATE TABLE IF NOT EXISTS page_tags (
    page_id TEXT NOT NULL,
    tag TEXT NOT NULL,
    PRIMARY KEY(page_id, tag),
    FOREIGN KEY(page_id) REFERENCES pages(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_tags_tag ON page_tags(tag);

-- 8. Senkronizasyon Kuyruğu (Offline Outbox)
-- Kuyruk tüketiminde katı FIFO sıralaması (created_at ASC, id ASC) garanti edilir.
-- id kolonu UUIDv7 (zaman sıralı ve monoton artan) olduğundan, aynı milisaniyedeki kayıtlarda da deterministik FIFO korunur.
CREATE TABLE IF NOT EXISTS sync_outbox (
    id TEXT PRIMARY KEY NOT NULL,
    workspace_id TEXT NOT NULL,
    doc_id TEXT NOT NULL,
    envelope_bytes BLOB NOT NULL,
    retry_count INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_outbox_fifo ON sync_outbox(created_at ASC, id ASC);

-- 9. FTS5 Tam Metin Arama Sanal Tablosu
CREATE VIRTUAL TABLE IF NOT EXISTS fts_blocks USING fts5(
    block_id UNINDEXED,
    page_id UNINDEXED,
    page_title,
    plain_text,
    tokenize = 'unicode61 remove_diacritics 2'
);
