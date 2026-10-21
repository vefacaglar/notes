pub mod blob;
pub mod block_repo;
pub mod db;
pub mod page_repo;

pub use blob::BlobStore;
pub use block_repo::{BlockRepo, SearchResult};
pub use db::{LocalStore, WorkspaceRecord};
pub use page_repo::{OutboxItem, PageRepo};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::block::{Block, BlockType};
    use crate::model::page::{Page, PageLink};
    use uuid::Uuid;

    fn setup_workspace(store: &LocalStore) -> Uuid {
        let ws_id = Uuid::now_v7();
        let ws = WorkspaceRecord {
            id: ws_id,
            name: "Test Workspace".to_string(),
            encrypted_dek: vec![1, 2, 3, 4],
            dek_nonce: vec![0; 24],
            created_at: chrono::Utc::now().timestamp_millis(),
        };
        store.create_workspace(&ws).expect("Workspace oluşturulamadı");
        ws_id
    }

    #[test]
    fn test_schema_migration_and_foreign_keys() {
        let store = LocalStore::open_in_memory().expect("In-memory SQLite açılamadı");
        let conn = store.conn();

        // 1. Tabloların var olduğunu doğrula
        let tables = vec![
            "workspaces",
            "pages",
            "blocks",
            "databases",
            "database_views",
            "page_links",
            "page_tags",
            "sync_outbox",
            "fts_blocks",
        ];

        for table in tables {
            let mut stmt = conn
                .prepare("SELECT name FROM sqlite_master WHERE type in ('table', 'view') AND name = ?1")
                .unwrap();
            let mut rows = stmt.query(rusqlite::params![table]).unwrap();
            assert!(
                rows.next().unwrap().is_some(),
                "Tablo bulunamadı: {}",
                table
            );
        }

        // 2. Foreign keys aktifliğini doğrula (Var olmayan workspace'e sayfa ekleme başarısız olmalı)
        let repo = PageRepo::new(conn);
        let orphan_page = Page::new(Uuid::now_v7(), "Yetim Sayfa");
        let err = repo.create_page(&orphan_page);
        assert!(
            err.is_err(),
            "Foreign key ihlali yakalanamadı: {}",
            err.unwrap_err()
        );
    }

    #[test]
    fn test_workspace_crud() {
        let store = LocalStore::open_in_memory().unwrap();
        let ws_id = setup_workspace(&store);

        let fetched = store.get_workspace(ws_id).unwrap().expect("Workspace bulunamadı");
        assert_eq!(fetched.id, ws_id);
        assert_eq!(fetched.name, "Test Workspace");

        let all = store.list_workspaces().unwrap();
        assert_eq!(all.len(), 1);

        store.delete_workspace(ws_id).unwrap();
        assert!(store.get_workspace(ws_id).unwrap().is_none());
    }

    #[test]
    fn test_page_crud_and_soft_delete() {
        let store = LocalStore::open_in_memory().unwrap();
        let ws_id = setup_workspace(&store);
        let repo = PageRepo::new(store.conn());

        let mut page = Page::new(ws_id, "Ana Not")
            .with_icon("📄")
            .with_cover_image("cover.jpg");
        let page_id = page.id;

        repo.create_page(&page).unwrap();

        // Okuma
        let fetched = repo.get_page(page_id).unwrap().expect("Sayfa bulunamadı");
        assert_eq!(fetched.title, "Ana Not");
        assert_eq!(fetched.icon.as_deref(), Some("📄"));
        assert_eq!(fetched.cover_image.as_deref(), Some("cover.jpg"));
        assert!(!fetched.is_deleted);

        // Güncelleme
        page.rename("Güncellenen Başlık");
        repo.update_page(&page).unwrap();
        let updated = repo.get_page(page_id).unwrap().unwrap();
        assert_eq!(updated.title, "Güncellenen Başlık");

        // Soft Delete
        repo.soft_delete_page(page_id).unwrap();
        let deleted = repo.get_page(page_id).unwrap().unwrap();
        assert!(deleted.is_deleted);

        let active_pages = repo.list_workspace_pages(ws_id, false).unwrap();
        assert!(active_pages.is_empty());

        let all_pages = repo.list_workspace_pages(ws_id, true).unwrap();
        assert_eq!(all_pages.len(), 1);

        // Restore
        repo.restore_page(page_id).unwrap();
        let restored = repo.get_page(page_id).unwrap().unwrap();
        assert!(!restored.is_deleted);

        // Hard Delete
        repo.hard_delete_page(page_id).unwrap();
        assert!(repo.get_page(page_id).unwrap().is_none());
    }

    #[test]
    fn test_subpage_tree_recursive_cte() {
        let store = LocalStore::open_in_memory().unwrap();
        let ws_id = setup_workspace(&store);
        let repo = PageRepo::new(store.conn());

        let root = Page::new(ws_id, "Root Page");
        let root_id = root.id;
        repo.create_page(&root).unwrap();

        let child1 = Page::new(ws_id, "Child 1").with_parent(root_id);
        let child1_id = child1.id;
        repo.create_page(&child1).unwrap();

        let child2 = Page::new(ws_id, "Child 2").with_parent(root_id);
        repo.create_page(&child2).unwrap();

        let grandchild = Page::new(ws_id, "Grandchild 1.1").with_parent(child1_id);
        let grandchild_id = grandchild.id;
        repo.create_page(&grandchild).unwrap();

        // Root altındaki alt sayfa ağacını çek
        let tree = repo.get_subpage_tree(root_id, false).unwrap();
        assert_eq!(tree.len(), 3);

        let ids: Vec<Uuid> = tree.iter().map(|p| p.id).collect();
        assert!(ids.contains(&child1_id));
        assert!(ids.contains(&child2.id));
        assert!(ids.contains(&grandchild_id));

        // Doğrudan çocuklar
        let direct_children = repo.list_subpages(Some(root_id), ws_id).unwrap();
        assert_eq!(direct_children.len(), 2);
    }

    #[test]
    fn test_page_links_and_tags() {
        let store = LocalStore::open_in_memory().unwrap();
        let ws_id = setup_workspace(&store);
        let repo = PageRepo::new(store.conn());

        let page_a = Page::new(ws_id, "Sayfa A");
        let page_b = Page::new(ws_id, "Sayfa B");
        repo.create_page(&page_a).unwrap();
        repo.create_page(&page_b).unwrap();

        let link = PageLink::new(page_a.id, page_b.id).with_anchor("B Detayı");
        repo.insert_link(&link).unwrap();

        let backlinks = repo.get_backlinks(page_b.id).unwrap();
        assert_eq!(backlinks.len(), 1);
        assert_eq!(backlinks[0].source_page_id, page_a.id);
        assert_eq!(backlinks[0].anchor_text.as_deref(), Some("B Detayı"));

        let outgoing = repo.get_outgoing_links(page_a.id).unwrap();
        assert_eq!(outgoing.len(), 1);
        assert_eq!(outgoing[0].target_page_id, page_b.id);

        // Etiketler
        repo.add_tag(page_a.id, "yazılım").unwrap();
        repo.add_tag(page_a.id, "rust").unwrap();

        let tags = repo.get_page_tags(page_a.id).unwrap();
        assert_eq!(tags, vec!["rust".to_string(), "yazılım".to_string()]);

        let pages_with_rust = repo.list_pages_by_tag("rust").unwrap();
        assert_eq!(pages_with_rust, vec![page_a.id]);

        repo.remove_tag(page_a.id, "rust").unwrap();
        let tags_after = repo.get_page_tags(page_a.id).unwrap();
        assert_eq!(tags_after, vec!["yazılım".to_string()]);
    }

    #[test]
    fn test_block_crud_and_hierarchy() {
        let store = LocalStore::open_in_memory().unwrap();
        let ws_id = setup_workspace(&store);
        let page_repo = PageRepo::new(store.conn());
        let block_repo = BlockRepo::new(store.conn());

        let page = Page::new(ws_id, "Blok Sayfası");
        page_repo.create_page(&page).unwrap();

        let p1 = Block::paragraph(page.id, "İlk Paragraf", 10.0);
        let p1_id = p1.id;
        block_repo.insert_block(&p1, Some("Blok Sayfası")).unwrap();

        let h1 = Block::heading(page.id, 1, "Başlık 1", 5.0).unwrap();
        block_repo.insert_block(&h1, Some("Blok Sayfası")).unwrap();

        let child = Block::paragraph(page.id, "Alt blok", 1.0).with_parent(p1_id);
        let child_id = child.id;
        block_repo.insert_block(&child, Some("Blok Sayfası")).unwrap();

        // Sayfa bloklarını sıralı listele
        let blocks = block_repo.list_blocks_by_page(page.id).unwrap();
        assert_eq!(blocks.len(), 3);
        assert_eq!(blocks[0].sort_order, 1.0);
        assert_eq!(blocks[1].sort_order, 5.0);
        assert_eq!(blocks[2].sort_order, 10.0);

        // Çocuk blokları çek
        let children = block_repo.list_child_blocks(p1_id).unwrap();
        assert_eq!(children.len(), 1);
        assert_eq!(children[0].id, child_id);

        // Sıralamayı güncelle
        block_repo.reorder_block(p1_id, 2.0).unwrap();
        let fetched_p1 = block_repo.get_block(p1_id).unwrap().unwrap();
        assert_eq!(fetched_p1.sort_order, 2.0);

        // Blok silme
        block_repo.delete_block(child_id).unwrap();
        assert!(block_repo.get_block(child_id).unwrap().is_none());
    }

    #[test]
    fn test_fts5_indexing_and_search() {
        let store = LocalStore::open_in_memory().unwrap();
        let ws_id = setup_workspace(&store);
        let page_repo = PageRepo::new(store.conn());
        let block_repo = BlockRepo::new(store.conn());

        let page = Page::new(ws_id, "Mimari Şartname");
        page_repo.create_page(&page).unwrap();

        let b1 = Block::paragraph(
            page.id,
            "Rust ve Argon2id ile sıfır bilgi şifreleme altyapısı",
            1.0,
        );
        let b1_id = b1.id;
        block_repo.insert_block(&b1, Some(&page.title)).unwrap();

        let b2 = Block::paragraph(
            page.id,
            "Local-first SQLite depolama ve CRDT senkronizasyon motoru",
            2.0,
        );
        block_repo.insert_block(&b2, Some(&page.title)).unwrap();

        // Arama testi 1: "Argon2id"
        let results = block_repo.search_fts("Argon2id", 5).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].block_id, b1_id);
        assert_eq!(results[0].page_title, "Mimari Şartname");
        assert!(results[0].plain_text.contains("Argon2id"));

        // Arama testi 2: "SQLite"
        let res2 = block_repo.search_fts("SQLite", 5).unwrap();
        assert_eq!(res2.len(), 1);
        assert_eq!(res2[0].block_id, b2.id);

        // Güncelleme ve FTS yeniden indeksleme
        let mut b1_updated = b1;
        b1_updated.set_content(serde_json::json!({ "text": "PostgreSQL yerine rusqlite kullanıyoruz" }));
        block_repo.update_block(&b1_updated, Some(&page.title)).unwrap();

        let res_after = block_repo.search_fts("rusqlite", 5).unwrap();
        assert_eq!(res_after.len(), 1);
        assert_eq!(res_after[0].block_id, b1_id);

        let old_res = block_repo.search_fts("Argon2id", 5).unwrap();
        assert!(old_res.is_empty());
    }

    #[test]
    fn test_sync_outbox_fifo_strict() {
        let store = LocalStore::open_in_memory().unwrap();
        let ws_id = setup_workspace(&store);
        let repo = PageRepo::new(store.conn());

        let doc_id = Uuid::now_v7();

        // Monoton artan 3 kayıt
        let item1 = OutboxItem {
            id: Uuid::now_v7(),
            workspace_id: ws_id,
            doc_id,
            envelope_bytes: vec![10, 20, 30],
            retry_count: 0,
            last_error: None,
            created_at: 1000,
        };
        let item2 = OutboxItem {
            id: Uuid::now_v7(),
            workspace_id: ws_id,
            doc_id,
            envelope_bytes: vec![40, 50, 60],
            retry_count: 0,
            last_error: None,
            created_at: 2000,
        };
        let item3 = OutboxItem {
            id: Uuid::now_v7(),
            workspace_id: ws_id,
            doc_id,
            envelope_bytes: vec![70, 80, 90],
            retry_count: 0,
            last_error: None,
            created_at: 3000,
        };

        // Karışık sırada ekle
        repo.enqueue_outbox(&item2).unwrap();
        repo.enqueue_outbox(&item1).unwrap();
        repo.enqueue_outbox(&item3).unwrap();

        // FIFO sırasında çek: kesinlikle item1 (1000) -> item2 (2000) -> item3 (3000) olmalı
        let fifo = repo.list_outbox_fifo(10).unwrap();
        assert_eq!(fifo.len(), 3);
        assert_eq!(fifo[0].id, item1.id);
        assert_eq!(fifo[1].id, item2.id);
        assert_eq!(fifo[2].id, item3.id);

        // Retry ve remove
        repo.mark_outbox_retry(item1.id, "Sunucu zaman aşımı").unwrap();
        let fifo_after_retry = repo.list_outbox_fifo(10).unwrap();
        assert_eq!(fifo_after_retry[0].retry_count, 1);
        assert_eq!(fifo_after_retry[0].last_error.as_deref(), Some("Sunucu zaman aşımı"));

        repo.remove_outbox(item1.id).unwrap();
        let remaining = repo.list_outbox_fifo(10).unwrap();
        assert_eq!(remaining.len(), 2);
        assert_eq!(remaining[0].id, item2.id);
    }

    #[test]
    fn test_blob_store_cas_and_deduplication() {
        let temp_dir = std::env::temp_dir().join(format!("notes_blob_test_{}", Uuid::now_v7()));
        let blob_store = BlobStore::new(&temp_dir).unwrap();

        let raw_data = b"Bu cok gizli bir resim veya PDF belgesidir!";
        let dek = [42u8; 32];

        // 1. Kaydet
        let blob_hash1 = blob_store.save(raw_data, &dek).unwrap();
        assert!(!blob_hash1.is_empty());
        assert!(blob_store.has_blob(&blob_hash1));

        // 2. Deterministik Tekilleştirme (Deduplication): Aynı veri + aynı DEK -> aynı hash üretir!
        let blob_hash2 = blob_store.save(raw_data, &dek).unwrap();
        assert_eq!(blob_hash1, blob_hash2);

        // 3. Oku ve doğrula
        let decrypted = blob_store.read(&blob_hash1, &dek).unwrap();
        assert_eq!(decrypted, raw_data);

        // 4. Farklı veri -> farklı hash
        let diff_data = b"Baska bir dosya icerigi";
        let blob_hash3 = blob_store.save(diff_data, &dek).unwrap();
        assert_ne!(blob_hash1, blob_hash3);

        // 5. Raw encrypted export / import testi
        let raw_enc = blob_store.read_raw_encrypted(&blob_hash1).unwrap();
        let other_dir = std::env::temp_dir().join(format!("notes_blob_import_{}", Uuid::now_v7()));
        let other_store = BlobStore::new(&other_dir).unwrap();
        other_store.save_raw_encrypted(&blob_hash1, &raw_enc).unwrap();
        let decrypted_imported = other_store.read(&blob_hash1, &dek).unwrap();
        assert_eq!(decrypted_imported, raw_data);

        // Temizlik
        let _ = std::fs::remove_dir_all(&temp_dir);
        let _ = std::fs::remove_dir_all(&other_dir);
    }

    #[test]
    fn test_blob_store_tampering_and_wrong_key() {
        let temp_dir = std::env::temp_dir().join(format!("notes_blob_err_{}", Uuid::now_v7()));
        let blob_store = BlobStore::new(&temp_dir).unwrap();

        let raw_data = b"Bozulma testi verisi";
        let dek = [7u8; 32];
        let wrong_dek = [8u8; 32];

        let blob_hash = blob_store.save(raw_data, &dek).unwrap();

        // 1. Yanlış DEK ile açmayı dene
        let wrong_key_res = blob_store.read(&blob_hash, &wrong_dek);
        assert!(wrong_key_res.is_err());

        // 2. Diskteki dosyayı manipüle et (veri bozulması / tampering)
        let file_path = blob_store.blob_path(&blob_hash);
        let mut corrupted_bytes = std::fs::read(&file_path).unwrap();
        let last_idx = corrupted_bytes.len() - 1;
        corrupted_bytes[last_idx] ^= 0xFF; // 1 biti tersine çevir
        std::fs::write(&file_path, corrupted_bytes).unwrap();

        // Okuma denendiğinde hash uyuşmazlığı nedeniyle reddedilmeli
        let corrupted_res = blob_store.read(&blob_hash, &dek);
        assert!(corrupted_res.is_err());
        let err_msg = corrupted_res.unwrap_err().to_string();
        assert!(err_msg.contains("hash uyuşmazlığı") || err_msg.contains("bozuk veri"));

        // Temizlik
        let _ = std::fs::remove_dir_all(&temp_dir);
    }
}
