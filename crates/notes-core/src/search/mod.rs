//! # Arama ve Bağlantı Grafiği Modülü
//!
//! Bu modül, Notes uygulamasının yerel SQLite tabanlı FTS5 tam metin arama motorunu
//! (`fts`), `[[Sayfa Başlığı]]` biçimindeki iki yönlü bağlantıları (Backlinks) ve
//! `#etiket` grafiğini (`backlinks`) yönetir.

pub mod backlinks;
pub mod fts;

pub use backlinks::*;
pub use fts::*;

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use uuid::Uuid;

    use crate::model::{Block, PageLink};

    fn setup_in_memory_db() -> Connection {
        let conn = Connection::open_in_memory().expect("In-memory SQLite açılamadı");
        create_fts_table(&conn).expect("FTS5 tablosu oluşturulamadı");
        create_backlink_tables(&conn).expect("Backlink tabloları oluşturulamadı");
        conn
    }

    #[test]
    fn test_fts_turkish_character_search() {
        let conn = setup_in_memory_db();

        let page_id = Uuid::now_v7();
        let b1 = Uuid::now_v7();
        let b2 = Uuid::now_v7();

        // Türkçe karakter içeren metinler ekle
        index_block(
            &conn,
            b1,
            page_id,
            "Türkçe Şifreli Notlar",
            "Bu ağaç çeşidi ve ılık su şifreli sistem için önemlidir.",
        )
        .expect("b1 indekslenemedi");

        index_block(
            &conn,
            b2,
            page_id,
            "Rust Programlama",
            "Güçlü tip sistemi ve sıfır-maliyetli soyutlamalar sunar.",
        )
        .expect("b2 indekslenemedi");

        // unicode61 remove_diacritics 2 sayesinde aksansız arama aksanlı metni bulmalıdır
        // "turkce" -> "Türkçe"
        let res = search_blocks(&conn, "turkce", 10).expect("Arama başarısız");
        assert_eq!(res.len(), 1);
        assert_eq!(res[0].block_id, b1);
        assert!(res[0].snippet.contains("<mark>Türkçe</mark>"));

        // "sifreli" -> "Şifreli" / "şifreli"
        let res_sifreli = search_blocks(&conn, "sifreli", 10).expect("Arama başarısız");
        assert_eq!(res_sifreli.len(), 1);
        assert_eq!(res_sifreli[0].block_id, b1);
        assert!(res_sifreli[0].snippet.contains("<mark>"));

        // "agac" -> "ağaç"
        let res_agac = search_blocks(&conn, "agac", 10).expect("Arama başarısız");
        assert_eq!(res_agac.len(), 1);
        assert_eq!(res_agac[0].block_id, b1);

        // "cesidi" -> "çeşidi"
        let res_cesidi = search_blocks(&conn, "cesidi", 10).expect("Arama başarısız");
        assert_eq!(res_cesidi.len(), 1);
        assert_eq!(res_cesidi[0].block_id, b1);

        // "guclu" -> "Güçlü"
        let res_guclu = search_blocks(&conn, "guclu", 10).expect("Arama başarısız");
        assert_eq!(res_guclu.len(), 1);
        assert_eq!(res_guclu[0].block_id, b2);

        // Önek (prefix) araması: "prog*" -> "Programlama"
        let res_prefix = search_blocks(&conn, "prog", 10).expect("Arama başarısız");
        assert_eq!(res_prefix.len(), 1);
        assert_eq!(res_prefix[0].block_id, b2);
    }

    #[test]
    fn test_fts_block_lifecycle_and_lock_screen_clear() {
        let conn = setup_in_memory_db();
        let page_id = Uuid::now_v7();
        let block_id = Uuid::now_v7();

        let block = Block::paragraph(page_id, "Kriptografik anahtar türetimi HKDF", 1.0);
        let block_id = block.id;

        // Model ile indeksleme
        index_block_model(&conn, &block, "Güvenlik Mimarisi").expect("İndekslenemedi");

        let res = search_blocks(&conn, "kriptografik", 10).expect("Arama başarısız");
        assert_eq!(res.len(), 1);
        assert_eq!(res[0].block_id, block_id);

        // Bloğu güncelle
        let mut updated_block = block.clone();
        updated_block.content = serde_json::json!({ "text": "Güncellenmiş içerik Argon2id" });
        index_block_model(&conn, &updated_block, "Güvenlik Mimarisi").expect("Güncellenemedi");

        // Eski içerik artık çıkmamalı
        let old_res = search_blocks(&conn, "kriptografik", 10).expect("Arama hatası");
        assert_eq!(old_res.len(), 0);

        // Yeni içerik çıkmalı
        let new_res = search_blocks(&conn, "Argon2id", 10).expect("Arama hatası");
        assert_eq!(new_res.len(), 1);

        // Tekil blok silme testi
        remove_block_index(&conn, block_id).expect("Silinemedi");
        let after_delete = search_blocks(&conn, "Argon2id", 10).expect("Arama hatası");
        assert_eq!(after_delete.len(), 0);

        // Tekrar ekleyip kilit ekranı temizliği (clear_all_index) testi
        index_block_model(&conn, &updated_block, "Güvenlik Mimarisi").expect("Tekrar eklenemedi");
        assert_eq!(search_blocks(&conn, "Argon2id", 10).unwrap().len(), 1);

        clear_all_index(&conn).expect("Temizlenemedi");
        assert_eq!(search_blocks(&conn, "Argon2id", 10).unwrap().len(), 0);
    }

    #[test]
    fn test_wiki_link_extraction() {
        let target_uuid = Uuid::now_v7();
        let text = format!(
            "Bu dökümanda [[Mevcut Not]], [[{target_uuid}|Hedef Not Başlığı]] ve [[Mimari|]] bağlantıları var. \
             Ayrıca geçersiz [[]] ve [[   ]] bağlantıları elenmelidir."
        );

        let links = extract_wiki_links(&text);
        assert_eq!(links.len(), 3);

        assert_eq!(links[0].target, "Mevcut Not");
        assert_eq!(links[0].display_text, "Mevcut Not");
        assert_eq!(links[0].target_page_id, None);

        assert_eq!(links[1].target, target_uuid.to_string());
        assert_eq!(links[1].display_text, "Hedef Not Başlığı");
        assert_eq!(links[1].target_page_id, Some(target_uuid));

        assert_eq!(links[2].target, "Mimari");
        assert_eq!(links[2].display_text, "Mimari");
        assert_eq!(links[2].target_page_id, None);
    }

    #[test]
    fn test_hashtag_extraction() {
        let text = "Bugün #rust ve #türkiye_notları üzerinde çalıştık. (#günlük-not) \
                    ## Markdown Başlığı etiket değildir. http://test.com#bolum hariç tutulur. \
                    Son olarak tekrar #rust ve #GÜVENLİK!";

        let tags = extract_hashtags(text);
        // "rust" tekilleştirilmeli, "GÜVENLİK" küçük harfe çevrilmeli
        assert_eq!(
            tags,
            vec!["rust", "türkiye_notları", "günlük-not", "güvenlik"]
        );
    }

    #[test]
    fn test_backlink_graph_database() {
        let conn = setup_in_memory_db();

        let page_a = Uuid::now_v7();
        let page_b = Uuid::now_v7();
        let target_page_c = Uuid::now_v7();
        let block_1 = Uuid::now_v7();

        // Sayfa A -> Sayfa C bağlantısı
        let link_a_to_c = PageLink::new(page_a, target_page_c)
            .with_source_block(block_1)
            .with_anchor("C'ye Referans");
        insert_page_link(&conn, &link_a_to_c).expect("Link eklenemedi");

        // Sayfa B -> Sayfa C bağlantısı
        let link_b_to_c = PageLink::new(page_b, target_page_c).with_anchor("B'den C'ye Bağlantı");
        insert_page_link(&conn, &link_b_to_c).expect("Link eklenemedi");

        // Sayfa A -> Sayfa B bağlantısı
        let link_a_to_b = PageLink::new(page_a, page_b);
        insert_page_link(&conn, &link_a_to_b).expect("Link eklenemedi");

        // Sayfa C'ye gelen backlink'ler (Sayfa A ve Sayfa B)
        let backlinks = get_backlinks_for_page(&conn, target_page_c).expect("Backlinkler alınamadı");
        assert_eq!(backlinks.len(), 2);
        assert!(backlinks.iter().any(|l| l.source_page_id == page_a));
        assert!(backlinks.iter().any(|l| l.source_page_id == page_b));

        // Sayfa A'dan çıkan giden bağlantılar (Sayfa C ve Sayfa B)
        let outgoing = get_outgoing_links_for_page(&conn, page_a).expect("Giden bağlantılar alınamadı");
        assert_eq!(outgoing.len(), 2);

        // Atomik senkronizasyon testi: Sayfa A'nın tüm linklerini tek bir yeni linkle değiştir
        let new_links = vec![PageLink::new(page_a, target_page_c).with_anchor("Tek Güncel Link")];
        sync_page_links(&conn, page_a, &new_links).expect("Senkronizasyon başarısız");

        let updated_outgoing = get_outgoing_links_for_page(&conn, page_a).expect("Giden linkler");
        assert_eq!(updated_outgoing.len(), 1);
        assert_eq!(updated_outgoing[0].anchor_text.as_deref(), Some("Tek Güncel Link"));
    }

    #[test]
    fn test_page_tags_database() {
        let conn = setup_in_memory_db();

        let page_1 = Uuid::now_v7();
        let page_2 = Uuid::now_v7();

        add_page_tag(&conn, page_1, "#Rust").expect("Etiket eklenemedi");
        add_page_tag(&conn, page_1, "kriptografi").expect("Etiket eklenemedi");
        add_page_tag(&conn, page_2, "rust").expect("Etiket eklenemedi");

        // Sayfa 1 etiketleri
        let p1_tags = get_tags_for_page(&conn, page_1).expect("Etiketler alınamadı");
        assert_eq!(p1_tags, vec!["kriptografi", "rust"]);

        // "rust" etiketli sayfalar
        let rust_pages = get_pages_by_tag(&conn, "#RUST").expect("Sayfalar alınamadı");
        assert_eq!(rust_pages.len(), 2);
        assert!(rust_pages.contains(&page_1));
        assert!(rust_pages.contains(&page_2));

        // Etiket istatistikleri
        let stats = get_all_tags_with_counts(&conn).expect("İstatistik alınamadı");
        assert_eq!(stats, vec![("rust".to_string(), 2), ("kriptografi".to_string(), 1)]);

        // Etiket kaldırma
        remove_page_tag(&conn, page_1, "kriptografi").expect("Silinemedi");
        let p1_tags_after = get_tags_for_page(&conn, page_1).expect("Etiketler alınamadı");
        assert_eq!(p1_tags_after, vec!["rust"]);

        // Etiket senkronizasyonu
        sync_page_tags(&conn, page_1, &["yeni-etiket".into(), "proje".into()]).expect("Sync");
        let p1_synced = get_tags_for_page(&conn, page_1).expect("Etiketler alınamadı");
        assert_eq!(p1_synced, vec!["proje", "yeni-etiket"]);
    }
}
