pub mod commands;
pub mod state;
pub mod ui;

pub use commands::*;
pub use state::*;
pub use ui::*;

#[cfg(test)]
mod tests {
    use super::*;
    use notes_core::crypto::{decrypt, NONCE_SIZE};
    use notes_core::model::block::BlockType;
    use notes_core::model::database::ViewType;
    use notes_core::model::property::{DatabasePropertyDefinition, PropertyType};
    use notes_core::storage::PageRepo;
    use tempfile::tempdir;

    fn setup_test_state() -> (DesktopAppState, tempfile::TempDir) {
        let temp_dir = tempdir().expect("Geçici dizin oluşturulamadı");
        let state = DesktopAppState::new_in_memory(temp_dir.path()).expect("State başlatılamadı");
        (state, temp_dir)
    }

    #[test]
    fn test_vault_init_unlock_lock_and_access_denial() {
        let (state, _tmp) = setup_test_state();

        assert!(state.is_locked());

        // 1. Kasa henüz başlatılmamışken kilit açma denemesi başarısız olmalı
        let err = unlock_vault_fast(&state, "secret123");
        assert!(matches!(err, Err(AppError::VaultNotInitialized)));

        // 2. Kilitliyken korumalı komutlara erişim reddedilmeli
        let page_err = cmd_create_page(&state, "Gizli Not", None, None, None);
        assert!(matches!(page_err, Err(AppError::VaultLocked)));

        let search_err = cmd_search_fts(&state, "kelime", None);
        assert!(matches!(search_err, Err(AppError::VaultLocked)));

        // 3. Kasayı başlat
        let init_res = init_vault_fast(&state, "MasterPass!42", Some("Test Notlarım".into()))
            .expect("Vault init başarısız");
        assert_eq!(init_res.workspace_name, "Test Notlarım");
        assert!(!state.is_locked());

        // 4. Açıkken sayfa ve blok oluştur
        let page = cmd_create_page(&state, "Çok Gizli Başlık", None, Some("🔒".into()), None)
            .expect("Sayfa oluşturulamadı");
        assert_eq!(page.title, "Çok Gizli Başlık");

        let block = cmd_insert_block(
            &state,
            page.id,
            None,
            BlockType::Paragraph,
            serde_json::json!({ "text": "Kritik E2EE içeriği burada saklanır" }),
            None,
            1.0,
        )
        .expect("Blok eklenemedi");

        // FTS aramasının çalıştığını doğrula
        let search_res = cmd_search_fts(&state, "Kritik", None).expect("Arama hatası");
        assert_eq!(search_res.len(), 1);
        assert_eq!(search_res[0].block_id, block.id);

        // 5. Kasayı kilitle
        lock_vault(&state).expect("Kilitlenemedi");
        assert!(state.is_locked());

        // 6. Kilitliyken arama ve sayfa okuma reddedilmeli
        let lock_search = cmd_search_fts(&state, "Kritik", None);
        assert!(matches!(lock_search, Err(AppError::VaultLocked)));

        let lock_page = cmd_get_page(&state, page.id);
        assert!(matches!(lock_page, Err(AppError::VaultLocked)));

        // Kilit ekranında FTS sanal tablosu temizlenmiş olmalı
        {
            let store = state.store.lock().unwrap();
            let mut stmt = store
                .conn()
                .prepare("SELECT count(*) FROM fts_blocks")
                .unwrap();
            let count: i64 = stmt.query_row([], |r| r.get(0)).unwrap();
            assert_eq!(count, 0, "Kilit sonrasında FTS indeksi sıfırlanmalıdır");
        }

        // 7. Yanlış parola ile açma denemesi reddedilmeli
        let bad_pass_res = unlock_vault_fast(&state, "YanlisParola!");
        assert!(matches!(bad_pass_res, Err(AppError::InvalidPassword)));
        assert!(state.is_locked());

        // 8. Doğru parola ile tekrar aç
        let unlock_res = unlock_vault_fast(&state, "MasterPass!42").expect("Kilit açılamadı");
        assert_eq!(unlock_res.workspace_id, init_res.workspace_id);
        assert!(!state.is_locked());

        // Deşifre edilen sayfayı ve bloğu oku
        let fetched_page = cmd_get_page(&state, page.id).expect("Sayfa okunamadı");
        assert_eq!(fetched_page.title, "Çok Gizli Başlık");

        let fetched_blocks = cmd_list_blocks(&state, page.id).expect("Bloklar okunamadı");
        assert_eq!(fetched_blocks.len(), 1);
        assert_eq!(fetched_blocks[0].id, block.id);
    }

    #[test]
    fn test_keychain_biometric_unlock() {
        let (state, _tmp) = setup_test_state();

        init_vault_fast(&state, "SuperSecret2026", None).unwrap();
        let ws_id = state.get_workspace_id().unwrap();

        // Kilitle
        lock_vault(&state).unwrap();
        assert!(state.is_locked());

        // Keychain ile aç
        let res = unlock_with_keychain(&state).expect("Keychain ile açılamadı");
        assert_eq!(res.workspace_id, ws_id);
        assert!(!state.is_locked());
    }

    #[test]
    fn test_page_hierarchy_and_tree() {
        let (state, _tmp) = setup_test_state();
        init_vault_fast(&state, "pass123", None).unwrap();

        // Kök sayfa
        let root = cmd_create_page(&state, "Ana Sayfa", None, Some("🏠".into()), None).unwrap();

        // İki alt sayfa
        let child1 =
            cmd_create_page(&state, "Çocuk 1", Some(root.id), Some("📁".into()), None).unwrap();
        let child2 =
            cmd_create_page(&state, "Çocuk 2", Some(root.id), Some("📁".into()), None).unwrap();

        // Bir torun sayfa
        let grandchild =
            cmd_create_page(&state, "Torun 1.1", Some(child1.id), Some("📄".into()), None)
                .unwrap();

        // Ağacı sorgula
        let tree = cmd_get_page_tree(&state, None, false).unwrap();
        assert_eq!(tree.len(), 1);
        assert_eq!(tree[0].page.id, root.id);
        assert_eq!(tree[0].children.len(), 2);

        // Çocuk 1'in torununu doğrula
        let c1_node = tree[0]
            .children
            .iter()
            .find(|c| c.page.id == child1.id)
            .unwrap();
        assert_eq!(c1_node.children.len(), 1);
        assert_eq!(c1_node.children[0].page.id, grandchild.id);

        // Sayfa taşıma: Torun 1.1'i Çocuk 2'nin altına taşı
        let moved = cmd_move_page(&state, grandchild.id, Some(child2.id)).unwrap();
        assert_eq!(moved.parent_page_id, Some(child2.id));

        let updated_tree = cmd_get_page_tree(&state, None, false).unwrap();
        let c2_node = updated_tree[0]
            .children
            .iter()
            .find(|c| c.page.id == child2.id)
            .unwrap();
        assert_eq!(c2_node.children.len(), 1);
        assert_eq!(c2_node.children[0].page.id, grandchild.id);

        // Soft delete ve restore
        cmd_soft_delete_page(&state, child1.id).unwrap();
        let active_pages = cmd_list_pages(&state, false).unwrap();
        assert!(!active_pages.iter().any(|p| p.id == child1.id));

        cmd_restore_page(&state, child1.id).unwrap();
        let restored_pages = cmd_list_pages(&state, false).unwrap();
        assert!(restored_pages.iter().any(|p| p.id == child1.id));
    }

    #[test]
    fn test_blocks_fts_wikilinks_hashtags_and_crdt_outbox() {
        let (state, _tmp) = setup_test_state();
        init_vault_fast(&state, "pass123", None).unwrap();
        let (dek, _, _, _) = state.require_unlocked().unwrap();

        let page_target = cmd_create_page(&state, "Hedef Doküman", None, None, None).unwrap();
        let page_source = cmd_create_page(&state, "Kaynak Not", None, None, None).unwrap();

        // Blok ekle: Hem Wikilink hem #etiket içeriyor
        let text_content = format!(
            "Bu blokta [[{}|Önemli Referans]] ve #kriptografi #güvenlik etiketleri var.",
            page_target.id
        );
        let block = cmd_insert_block(
            &state,
            page_source.id,
            None,
            BlockType::Paragraph,
            serde_json::json!({ "text": text_content }),
            None,
            10.0,
        )
        .unwrap();

        // 1. FTS5 Arama Doğrulaması (Türkçe karakter ve aksan duyarsız)
        let fts_res = cmd_search_fts(&state, "guvenlik", None).unwrap();
        assert_eq!(fts_res.len(), 1);
        assert_eq!(fts_res[0].block_id, block.id);
        assert_eq!(fts_res[0].page_title, "Kaynak Not");

        // 2. Backlink Grafiği Doğrulaması
        let backlinks = cmd_get_backlinks(&state, page_target.id).unwrap();
        assert_eq!(backlinks.len(), 1);
        assert_eq!(backlinks[0].source_page_id, page_source.id);
        assert_eq!(backlinks[0].anchor_text.as_deref(), Some("Önemli Referans"));

        // 3. Etiket Sorgulama Doğrulaması
        let tag_pages = cmd_get_pages_by_tag(&state, "kriptografi").unwrap();
        assert_eq!(tag_pages, vec![page_source.id]);

        let all_tags = cmd_get_all_tags(&state).unwrap();
        assert!(all_tags.iter().any(|(t, c)| t == "güvenlik" && *c >= 1));

        // 4. CRDT Outbox Kuyruğu & DEK Şifreleme Doğrulaması
        let store = state.store.lock().unwrap();
        let page_repo = PageRepo::new(store.conn());
        let outbox = page_repo.list_outbox_fifo(10).unwrap();
        assert!(!outbox.is_empty());

        let last_item = outbox.last().unwrap();
        assert_eq!(last_item.doc_id, page_source.id);

        // Zarfı açıp doğrula: İlk 24 bayt nonce, kalanı ciphertext
        let raw_envelope = &last_item.envelope_bytes;
        assert!(raw_envelope.len() > NONCE_SIZE);

        let mut nonce = [0u8; NONCE_SIZE];
        nonce.copy_from_slice(&raw_envelope[..NONCE_SIZE]);
        let ciphertext = &raw_envelope[NONCE_SIZE..];

        let decrypted_crdt_update =
            decrypt(dek.as_bytes(), &nonce, ciphertext).expect("CRDT zarfı deşifre edilemedi");

        // Deşifre edilen CRDT güncellemesini bir doc'a uygula
        let mut crdt_check = notes_core::crdt::PageCrdtDoc::new();
        crdt_check
            .apply_update(&decrypted_crdt_update)
            .expect("CRDT update uygulanamadı");
        assert_eq!(crdt_check.block_count(), 1);
    }

    #[test]
    fn test_database_views_and_properties() {
        let (state, _tmp) = setup_test_state();
        init_vault_fast(&state, "pass123", None).unwrap();

        // 1. Veritabanı sayfası oluştur
        let db_page = cmd_create_page(&state, "Proje Görevleri", None, Some("📊".into()), None).unwrap();

        let col_status = DatabasePropertyDefinition::new("Durum", PropertyType::Select);
        let col_done = DatabasePropertyDefinition::new("Tamamlandı", PropertyType::Checkbox);

        let schema =
            cmd_create_database(&state, db_page.id, vec![col_status, col_done]).unwrap();
        assert_eq!(schema.properties.len(), 2);

        // Varsayılan Tablo görünümünü kontrol et
        let views = cmd_list_database_views(&state, schema.id).unwrap();
        assert_eq!(views.len(), 1);
        assert_eq!(views[0].view_type, ViewType::Table);

        // 2. Kanban ve Takvim Görünümleri ekle
        let kanban_view = cmd_create_database_view(
            &state,
            schema.id,
            "Kanban Panosu".into(),
            ViewType::Board,
        )
        .unwrap();
        assert_eq!(kanban_view.view_type, ViewType::Board);

        let calendar_view = cmd_create_database_view(
            &state,
            schema.id,
            "Takvim Görünümü".into(),
            ViewType::Calendar,
        )
        .unwrap();
        assert_eq!(calendar_view.view_type, ViewType::Calendar);

        // 3. Yeni bir özellik ekle (Tarih)
        let col_date = DatabasePropertyDefinition::new("Bitiş Tarihi", PropertyType::Date);
        let updated_schema = cmd_add_database_property(&state, schema.id, col_date).unwrap();
        assert_eq!(updated_schema.properties.len(), 3);

        // 4. Görev satırları (alt sayfalar) ekle
        let row1 = cmd_create_page(&state, "Tauri IPC Kurulumu", Some(db_page.id), None, None).unwrap();
        let _row2 = cmd_create_page(&state, "Editör Entegrasyonu", Some(db_page.id), None, None).unwrap();

        // Satırlara blok ekle (özellik JSON'u barındıran)
        cmd_insert_block(
            &state,
            row1.id,
            None,
            BlockType::Paragraph,
            serde_json::json!({ "text": "Açıklama" }),
            Some(serde_json::json!({ "Durum": "Yapılıyor", "Tamamlandı": false })),
            1.0,
        )
        .unwrap();

        // 5. Görünüm sorgula
        let query_res = cmd_query_database_view(&state, schema.id, kanban_view.id).unwrap();
        assert_eq!(query_res.total_count, 2);
        assert_eq!(query_res.rows.len(), 2);
        assert_eq!(query_res.rows[0].title, "Tauri IPC Kurulumu");
        assert_eq!(query_res.rows[0].properties["Durum"], "Yapılıyor");
        assert_eq!(query_res.rows[1].title, "Editör Entegrasyonu");
    }

    #[test]
    fn test_blob_attachment_lifecycle() {
        let (state, _tmp) = setup_test_state();
        init_vault_fast(&state, "pass123", None).unwrap();

        let raw_file = b"Bu bir gizli PDF ekidir! E2EE sifreli saklanacaktir.";
        let filename = "gizli_rapor.pdf".to_string();

        // Ek yükle
        let meta = cmd_upload_attachment(&state, raw_file.to_vec(), filename.clone()).unwrap();
        assert_eq!(meta.filename, filename);
        assert_eq!(meta.size_bytes, raw_file.len());
        assert!(!meta.blob_hash.is_empty());

        // Varlık kontrolü
        assert!(cmd_has_attachment(&state, &meta.blob_hash).unwrap());

        // Deşifre edilmiş eki indir
        let downloaded = cmd_get_attachment(&state, &meta.blob_hash).unwrap();
        assert_eq!(downloaded, raw_file);

        // Kasayı kilitle ve erişim reddini doğrula
        lock_vault(&state).unwrap();
        let locked_err = cmd_get_attachment(&state, &meta.blob_hash);
        assert!(matches!(locked_err, Err(AppError::VaultLocked)));
    }

    #[test]
    fn test_seed_starter_pages_and_markdown_integration() {
        let (state, _tmp) = setup_test_state();

        assert!(!is_vault_initialized(&state).unwrap());
        init_vault_fast(&state, "MasterKey!42", Some("Test Alanı".into())).unwrap();
        assert!(is_vault_initialized(&state).unwrap());

        // 1. Seed verilerini oluştur
        seed_starter_pages(&state).expect("Seed başarısız olmamalı");

        // 2. Sayfa ağacını kontrol et
        let tree = cmd_get_page_tree(&state, None, false).unwrap();
        assert_eq!(tree.len(), 2);

        // "Hoş Geldiniz" sayfasını bul ve markdown gövdesini doğrula
        let welcome = tree.iter().find(|n| n.page.title.contains("Hoş Geldiniz")).unwrap();
        let md = cmd_get_page_markdown(&state, welcome.page.id).unwrap();
        assert!(md.contains("# Hoş Geldiniz — Notes Native macOS"));
        assert!(md.contains("[[Proje Görevleri DB]]"));
        assert!(md.contains("#rust"));

        // FTS5 aramasının çalıştığını doğrula
        let search_hits = cmd_search_fts(&state, "XChaCha20", None).unwrap();
        assert!(!search_hits.is_empty());

        // 3. Markdown düzenleme ve otomatik kaydetme testi
        let updated_md = format!("{}\n\n- [ ] Ekstra yapılacak test görevi", md);
        cmd_save_page_markdown(&state, welcome.page.id, &updated_md).unwrap();

        let retrieved_md = cmd_get_page_markdown(&state, welcome.page.id).unwrap();
        assert!(retrieved_md.contains("Ekstra yapılacak test görevi"));

        // 4. Veritabanı sayfasını kontrol et
        let db_node = tree.iter().find(|n| n.page.title == "Proje Görevleri DB").unwrap();
        assert!(db_node.page.is_database);

        let schema = cmd_get_database(&state, db_node.page.id).unwrap();
        let views = cmd_list_database_views(&state, schema.id).unwrap();
        assert!(views.len() >= 3); // Table, Board, Calendar

        // Satır sorgulama
        let query_res = cmd_query_database_view(&state, schema.id, views[0].id).unwrap();
        assert_eq!(query_res.rows.len(), 3);
        assert_eq!(query_res.rows[0].title, "Native macOS eframe arayüzü");

        // Satır durum güncellemesi
        let row_id = query_res.rows[0].page_id;
        cmd_update_database_row(
            &state,
            row_id,
            Some("Native macOS eframe arayüzü (Tamamlandı)".into()),
            Some(serde_json::json!({ "Durum": "Tamamlandı", "Öncelik": "Yüksek" })),
        )
        .unwrap();

        let re_query = cmd_query_database_view(&state, schema.id, views[0].id).unwrap();
        assert_eq!(re_query.rows[0].title, "Native macOS eframe arayüzü (Tamamlandı)");
        assert_eq!(re_query.rows[0].properties["Durum"], "Tamamlandı");
    }

    #[test]
    fn test_cmd_save_page_markdown_extra_blocks_and_wikilink_workspace() {
        let (state, _tmp) = setup_test_state();
        init_vault_fast(&state, "pass123", None).unwrap();

        let page_target = cmd_create_page(&state, "Hedef Sayfa", None, None, None).unwrap();
        let page_main = cmd_create_page(&state, "Ana Doküman", None, None, None).unwrap();

        // 3 ayrı blok ekleyelim
        cmd_insert_block(
            &state,
            page_main.id,
            None,
            BlockType::Paragraph,
            serde_json::json!({ "text": "Blok 1 [[Hedef Sayfa]]" }),
            None,
            1.0,
        )
        .unwrap();
        cmd_insert_block(
            &state,
            page_main.id,
            None,
            BlockType::Paragraph,
            serde_json::json!({ "text": "Blok 2" }),
            None,
            2.0,
        )
        .unwrap();
        cmd_insert_block(
            &state,
            page_main.id,
            None,
            BlockType::Paragraph,
            serde_json::json!({ "text": "Blok 3" }),
            None,
            3.0,
        )
        .unwrap();

        let blocks = cmd_list_blocks(&state, page_main.id).unwrap();
        assert_eq!(blocks.len(), 3);

        // Wikilink başlığa göre doğru çözümlenmiş olmalı
        let backlinks = cmd_get_backlinks(&state, page_target.id).unwrap();
        assert_eq!(backlinks.len(), 1);
        assert_eq!(backlinks[0].source_page_id, page_main.id);

        // Şimdi tek gövde markdown ile kaydet
        cmd_save_page_markdown(&state, page_main.id, "# Birleştirilmiş Metin").unwrap();

        // Fazlalık bloklar silinmiş ve sadece 1 blok kalmış olmalı
        let remaining_blocks = cmd_list_blocks(&state, page_main.id).unwrap();
        assert_eq!(remaining_blocks.len(), 1);
        assert_eq!(remaining_blocks[0].extract_plain_text(), "# Birleştirilmiş Metin");

        // Outbox temizliğini doğrula
        let store = state.store.lock().unwrap();
        let page_repo = PageRepo::new(store.conn());
        let items = page_repo.list_outbox_fifo(100).unwrap();
        assert!(!items.is_empty());
        for item in &items {
            page_repo.remove_outbox(item.id).unwrap();
        }
        let after_removal = page_repo.list_outbox_fifo(100).unwrap();
        assert!(after_removal.is_empty());
    }
}
