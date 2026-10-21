//! CRDT (Conflict-free Replicated Data Types) Doküman Motoru ve Senkronizasyon Modülü.
//!
//! Bu modül, sayfa içeriklerinin ve bloklarının yerel veya dağıtık ortamda
//! çatışmasız replikasyonunu (`yrs` v0.21+) sağlayan doküman yapısını ve
//! durum vektörü tabanlı el sıkışma (handshake) codec'ini barındırır.

pub mod doc;
pub mod sync_codec;

pub use doc::PageCrdtDoc;
pub use sync_codec::{apply_update, encode_state_as_update, state_vector};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::CoreError;
    use crate::model::{Block, BlockType};
    use uuid::Uuid;

    #[test]
    fn test_page_crdt_metadata_crud() {
        let doc = PageCrdtDoc::with_client_id(1);

        assert_eq!(doc.get_title(), None);
        assert_eq!(doc.title(), "");
        assert_eq!(doc.get_icon(), None);
        assert_eq!(doc.get_updated_at(), None);

        doc.set_title("Benim Notum");
        assert_eq!(doc.get_title().as_deref(), Some("Benim Notum"));
        assert_eq!(doc.title(), "Benim Notum");
        assert!(doc.get_updated_at().is_some());

        doc.set_icon(Some("📝"));
        assert_eq!(doc.get_icon().as_deref(), Some("📝"));

        doc.set_icon(None);
        assert_eq!(doc.get_icon(), None);

        doc.set_updated_at(1_700_000_000_000);
        assert_eq!(doc.get_updated_at(), Some(1_700_000_000_000));
    }

    #[test]
    fn test_page_crdt_block_crud_and_deterministic_sorting() {
        let doc = PageCrdtDoc::with_client_id(2);

        // 3 blok ekle: sort_order değerleri 30.0, 10.0, 20.0
        let b1 = serde_json::json!({
            "id": "block-3",
            "sort_order": 30.0,
            "text": "Üçüncü blok"
        });
        let b2 = serde_json::json!({
            "id": "block-1",
            "sort_order": 10.0,
            "text": "Birinci blok"
        });
        let b3 = serde_json::json!({
            "id": "block-2",
            "sort_order": 20.0,
            "text": "İkinci blok"
        });

        doc.upsert_block_json("block-3", &b1.to_string()).unwrap();
        doc.upsert_block_json("block-1", &b2.to_string()).unwrap();
        doc.upsert_block_json("block-2", &b3.to_string()).unwrap();

        assert_eq!(doc.block_count(), 3);

        // list_blocks_json artan sırada dönmeli (10.0, 20.0, 30.0)
        let blocks = doc.list_blocks_json();
        assert_eq!(blocks.len(), 3);

        let v1: serde_json::Value = serde_json::from_str(&blocks[0]).unwrap();
        let v2: serde_json::Value = serde_json::from_str(&blocks[1]).unwrap();
        let v3: serde_json::Value = serde_json::from_str(&blocks[2]).unwrap();

        assert_eq!(v1["id"], "block-1");
        assert_eq!(v2["id"], "block-2");
        assert_eq!(v3["id"], "block-3");

        // Blok güncelleme (upsert)
        let b2_updated = serde_json::json!({
            "id": "block-2",
            "sort_order": 5.0, // Başa taşındı
            "text": "İkinci blok (güncellendi)"
        });
        doc.upsert_block_json("block-2", &b2_updated.to_string()).unwrap();

        let updated_blocks = doc.list_blocks_json();
        let uv1: serde_json::Value = serde_json::from_str(&updated_blocks[0]).unwrap();
        assert_eq!(uv1["id"], "block-2"); // Artık en başta

        // Blok silme
        assert!(doc.remove_block("block-3"));
        assert!(!doc.remove_block("olmayan-blok"));
        assert_eq!(doc.block_count(), 2);

        // Geçersiz JSON hata kontrolü
        let bad_json = "{gecersiz_json}";
        let res = doc.upsert_block_json("bad", bad_json);
        assert!(matches!(res, Err(CoreError::Serialization(_))));
    }

    #[test]
    fn test_domain_block_model_integration() {
        let doc = PageCrdtDoc::with_client_id(3);
        let page_id = Uuid::now_v7();

        let mut b1 = Block::paragraph(page_id, "Paragraf 1", 100.0);
        let mut b2 = Block::paragraph(page_id, "Paragraf 2", 200.0);

        doc.upsert_block(&b1).unwrap();
        doc.upsert_block(&b2).unwrap();

        let loaded = doc.list_blocks().unwrap();
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].id, b1.id);
        assert_eq!(loaded[1].id, b2.id);

        b1.content = serde_json::json!({ "text": "Güncellenmiş içerik" });
        doc.upsert_block(&b1).unwrap();

        let loaded_after = doc.list_blocks().unwrap();
        assert_eq!(loaded_after[0].content["text"], "Güncellenmiş içerik");
    }

    #[test]
    fn test_rich_text_operations() {
        let doc = PageCrdtDoc::with_client_id(4);
        let block_id = "text-block-1";

        assert_eq!(doc.get_block_text(block_id), "");

        doc.insert_block_text(block_id, 0, "Merhaba");
        assert_eq!(doc.get_block_text(block_id), "Merhaba");

        doc.insert_block_text(block_id, 7, " Dünya");
        assert_eq!(doc.get_block_text(block_id), "Merhaba Dünya");

        doc.push_block_text(block_id, "!");
        assert_eq!(doc.get_block_text(block_id), "Merhaba Dünya!");

        // Güvenli sınır kontrolü: Uzun indeks metnin sonuna eklemeli
        doc.insert_block_text(block_id, 9999, " (ek)");
        assert_eq!(doc.get_block_text(block_id), "Merhaba Dünya! (ek)");
    }

    #[test]
    fn test_offline_two_way_delta_sync_convergence() {
        // İki farklı eş (peer) oluştur
        let mut peer_a = PageCrdtDoc::with_client_id(1001);
        let mut peer_b = PageCrdtDoc::with_client_id(1002);

        // 1. Faz: Peer A başlangıç durumunu oluşturur
        peer_a.set_title("Mimarisi Notu");
        peer_a.set_icon(Some("🏛️"));
        let b1 = serde_json::json!({
            "id": "b-common",
            "sort_order": 1.0,
            "type": "paragraph"
        });
        peer_a.upsert_block_json("b-common", &b1.to_string()).unwrap();
        peer_a.insert_block_text("b-common", 0, "Giriş metni");

        // 2. Faz: İlk tam senkronizasyon (A -> B)
        let sv_b = peer_b.state_vector();
        let delta_a_to_b = peer_a.encode_state_as_update(&sv_b).unwrap();
        peer_b.apply_update(&delta_a_to_b).unwrap();

        // Her iki tarafın başlangıçta eşit olduğunu doğrula
        assert_eq!(peer_a.get_title(), peer_b.get_title());
        assert_eq!(peer_a.get_icon(), peer_b.get_icon());
        assert_eq!(peer_a.get_block_text("b-common"), peer_b.get_block_text("b-common"));
        assert_eq!(peer_a.list_blocks_json(), peer_b.list_blocks_json());
        assert_eq!(peer_a.state_vector(), peer_b.state_vector());

        // 3. Faz: Her iki taraf çevrimdışı (offline) farklı değişiklikler yapar
        // Peer A:
        peer_a.set_title("Mimarisi Notu - A Tarafından Düzenlendi");
        peer_a.insert_block_text("b-common", 11, " [A eki]");
        let b_a = serde_json::json!({
            "id": "b-peer-a",
            "sort_order": 2.0,
            "type": "heading1"
        });
        peer_a.upsert_block_json("b-peer-a", &b_a.to_string()).unwrap();
        peer_a.insert_block_text("b-peer-a", 0, "A Başlığı");

        // Peer B (A'dan habersiz eşzamanlı çevrimdışı):
        peer_b.set_icon(Some("🚀"));
        peer_b.insert_block_text("b-common", 11, " [B eki]");
        let b_b = serde_json::json!({
            "id": "b-peer-b",
            "sort_order": 0.5, // En başa yerleşmeli
            "type": "bullet_list_item"
        });
        peer_b.upsert_block_json("b-peer-b", &b_b.to_string()).unwrap();
        peer_b.insert_block_text("b-peer-b", 0, "B Maddesi");

        // Bu aşamada durum vektörleri ve içerikler farklı olmalıdır
        assert_ne!(peer_a.state_vector(), peer_b.state_vector());
        assert_ne!(peer_a.get_title(), peer_b.get_title());
        assert_ne!(peer_a.get_icon(), peer_b.get_icon());
        assert_ne!(peer_a.list_blocks_json(), peer_b.list_blocks_json());

        // 4. Faz: İki yönlü el sıkışma (Handshake & Delta Update Exchange)
        let pre_sync_sv_a = peer_a.state_vector();
        let pre_sync_sv_b = peer_b.state_vector();

        // A, B'nin bilmediği farkları üretir
        let delta_a = peer_a.encode_state_as_update(&pre_sync_sv_b).unwrap();
        // B, A'nın bilmediği farkları üretir
        let delta_b = peer_b.encode_state_as_update(&pre_sync_sv_a).unwrap();

        // Karşılıklı güncellemeleri uygula (merge)
        peer_b.apply_update(&delta_a).unwrap();
        peer_a.apply_update(&delta_b).unwrap();

        // 5. Faz: KESİN UYUM (CONVERGENCE) DOĞRULAMASI
        // a) Başlık ve simge eşitliği
        assert_eq!(peer_a.get_title(), peer_b.get_title());
        assert_eq!(peer_a.get_icon(), peer_b.get_icon());
        assert_eq!(peer_a.get_icon().as_deref(), Some("🚀"));

        // b) Zengin metin çatışmasız birleşimi (her iki ek de korunmalı ve sıraları birebir aynı olmalı)
        let text_a = peer_a.get_block_text("b-common");
        let text_b = peer_b.get_block_text("b-common");
        assert_eq!(text_a, text_b);
        assert!(text_a.contains("[A eki]"));
        assert!(text_a.contains("[B eki]"));

        // c) Diğer blokların metinleri
        assert_eq!(peer_a.get_block_text("b-peer-a"), "A Başlığı");
        assert_eq!(peer_b.get_block_text("b-peer-a"), "A Başlığı");
        assert_eq!(peer_a.get_block_text("b-peer-b"), "B Maddesi");
        assert_eq!(peer_b.get_block_text("b-peer-b"), "B Maddesi");

        // d) Blok listesi sıralı ve birebir aynı olmalı (0.5, 1.0, 2.0 sıralaması)
        let blocks_a = peer_a.list_blocks_json();
        let blocks_b = peer_b.list_blocks_json();
        assert_eq!(blocks_a, blocks_b);
        assert_eq!(blocks_a.len(), 3);

        let parsed_b0: serde_json::Value = serde_json::from_str(&blocks_a[0]).unwrap();
        let parsed_b1: serde_json::Value = serde_json::from_str(&blocks_a[1]).unwrap();
        let parsed_b2: serde_json::Value = serde_json::from_str(&blocks_a[2]).unwrap();

        assert_eq!(parsed_b0["id"], "b-peer-b"); // 0.5
        assert_eq!(parsed_b1["id"], "b-common"); // 1.0
        assert_eq!(parsed_b2["id"], "b-peer-a"); // 2.0

        // e) StateVector tam eşitliği (her iki eş de birbirinin tüm operasyonlarını gördü)
        assert_eq!(peer_a.state_vector(), peer_b.state_vector());
    }

    #[test]
    fn test_block_deletion_convergence() {
        let mut peer_a = PageCrdtDoc::with_client_id(2001);
        let mut peer_b = PageCrdtDoc::with_client_id(2002);

        // Ortak 2 blok oluştur ve eşitle
        let b1 = serde_json::json!({ "id": "block-x", "sort_order": 1.0 });
        let b2 = serde_json::json!({ "id": "block-y", "sort_order": 2.0 });
        peer_a.upsert_block_json("block-x", &b1.to_string()).unwrap();
        peer_a.upsert_block_json("block-y", &b2.to_string()).unwrap();

        let initial_update = peer_a.encode_state_as_update(&[]).unwrap();
        peer_b.apply_update(&initial_update).unwrap();

        // Çevrimdışı: A blok-x'i siler, B ise blok-y'nin içeriğini günceller
        peer_a.remove_block("block-x");

        let b2_mod = serde_json::json!({ "id": "block-y", "sort_order": 2.0, "updated": true });
        peer_b.upsert_block_json("block-y", &b2_mod.to_string()).unwrap();

        // Değişim
        let sv_a = peer_a.state_vector();
        let sv_b = peer_b.state_vector();

        let update_a = peer_a.encode_state_as_update(&sv_b).unwrap();
        let update_b = peer_b.encode_state_as_update(&sv_a).unwrap();

        peer_a.apply_update(&update_b).unwrap();
        peer_b.apply_update(&update_a).unwrap();

        // Her iki tarafta da block-x silinmiş olmalı, block-y güncellenmiş olmalı
        assert_eq!(peer_a.block_count(), 1);
        assert_eq!(peer_b.block_count(), 1);
        assert_eq!(peer_a.get_block_json("block-x"), None);
        assert_eq!(peer_b.get_block_json("block-x"), None);

        let y_a = peer_a.get_block_json("block-y").unwrap();
        let y_b = peer_b.get_block_json("block-y").unwrap();
        assert_eq!(y_a, y_b);
        assert!(y_a.contains("\"updated\":true"));

        assert_eq!(peer_a.state_vector(), peer_b.state_vector());
    }

    #[test]
    fn test_sync_codec_idempotency() {
        let mut peer_a = PageCrdtDoc::with_client_id(3001);
        let mut peer_b = PageCrdtDoc::with_client_id(3002);

        peer_a.set_title("Tekrarlı Güncelleme Testi");
        let update = peer_a.encode_full_update();

        // Aynı güncelleme birden çok kez uygulanır
        peer_b.apply_update(&update).unwrap();
        let sv1 = peer_b.state_vector();

        peer_b.apply_update(&update).unwrap();
        let sv2 = peer_b.state_vector();

        peer_b.apply_update(&update).unwrap();
        let sv3 = peer_b.state_vector();

        assert_eq!(sv1, sv2);
        assert_eq!(sv2, sv3);
        assert_eq!(peer_b.get_title().as_deref(), Some("Tekrarlı Güncelleme Testi"));
    }

    #[test]
    fn test_sync_codec_error_handling() {
        let mut doc = PageCrdtDoc::with_client_id(4001);

        // Boş güncelleme hatasız dönmeli (no-op)
        assert!(doc.apply_update(&[]).is_ok());

        // Boş state vector tam güncelleme üretmeli
        let full_update = doc.encode_state_as_update(&[]);
        assert!(full_update.is_ok());

        // Bozuk state vector verisi CoreError::Serialization dönmeli
        let bad_sv = vec![0xFF, 0xFF, 0xFF, 0xFF];
        let res_sv = doc.encode_state_as_update(&bad_sv);
        assert!(matches!(res_sv, Err(CoreError::Serialization(_))));

        // Bozuk CRDT update verisi CoreError::Serialization dönmeli
        let bad_update = vec![0xFE, 0xED, 0xBE, 0xEF];
        let res_update = doc.apply_update(&bad_update);
        assert!(matches!(res_update, Err(CoreError::Serialization(_))));
    }
}
