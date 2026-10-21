//! CRDT tabanlı sayfa doküman motoru (`PageCrdtDoc`).
//!
//! Bu modül, sayfa meta verilerini, blok koleksiyonunu ve blok içi zengin
//! metinleri (`yrs::TextRef`) yöneten çatışmasız replike edilebilir veri yapısını (CRDT) sunar.

use std::sync::Arc;
use chrono::Utc;
use yrs::{
    types::map::Map,
    types::text::Text,
    Any, Doc, GetString, MapRef, Out, ReadTxn, TextRef, Transact,
};

use crate::error::{CoreError, Result};
use crate::model::Block;

/// Sayfa düzeyinde CRDT doküman yapısı (`yrs::Doc` üzerinde kurulu).
///
/// İçerik Yapısı:
/// - `meta`: Sayfa meta verileri (Map: `title`, `icon`, `updated_at`)
/// - `blocks`: Blok ID -> Blok JSON eşleştirmesi (Map)
/// - `block_text:<id>`: Her blok için bağımsız karakter düzeyinde zengin metin (`TextRef`)
#[derive(Debug, Clone)]
pub struct PageCrdtDoc {
    doc: Doc,
    meta: MapRef,
    blocks: MapRef,
}

impl Default for PageCrdtDoc {
    fn default() -> Self {
        Self::new()
    }
}

impl PageCrdtDoc {
    /// Rastgele bir `client_id` ile yeni bir CRDT dokümanı oluşturur.
    pub fn new() -> Self {
        let doc = Doc::new();
        Self::from_doc(doc)
    }

    /// Belirtilen benzersiz `client_id` ile doküman oluşturur.
    /// Eşzamanlı replikalarda her istemcinin benzersiz bir client_id'ye sahip olması gerekir.
    pub fn with_client_id(client_id: u64) -> Self {
        let doc = Doc::with_client_id(client_id);
        Self::from_doc(doc)
    }

    /// Mevcut bir `yrs::Doc` nesnesinden `PageCrdtDoc` sarmalayıcısı üretir.
    pub fn from_doc(doc: Doc) -> Self {
        let meta = doc.get_or_insert_map("meta");
        let blocks = doc.get_or_insert_map("blocks");
        Self { doc, meta, blocks }
    }

    /// Alttaki `yrs::Doc` referansını döndürür.
    pub fn doc(&self) -> &Doc {
        &self.doc
    }

    /// İstemci (peer) kimlik numarasını döndürür.
    pub fn client_id(&self) -> u64 {
        self.doc.client_id()
    }

    // =========================================================================
    // Meta Veri Metodları (`meta` Map)
    // =========================================================================

    /// Sayfa başlığını ayarlar ve `updated_at` zaman damgasını günceller.
    pub fn set_title(&self, title: &str) {
        let mut txn = self.doc.transact_mut();
        self.meta.insert(&mut txn, "title", title);
        let now = Utc::now().timestamp_millis();
        self.meta.insert(&mut txn, "updated_at", now);
    }

    /// Sayfa başlığını okur. Başlık ayarlanmamışsa `None` döndürür.
    pub fn get_title(&self) -> Option<String> {
        let txn = self.doc.transact();
        match self.meta.get(&txn, "title") {
            Some(Out::Any(Any::String(s))) => Some(s.to_string()),
            _ => None,
        }
    }

    /// Kolaylık metodu: Ayarlanmış başlığı veya boş dizeyi (`""`) döndürür.
    pub fn title(&self) -> String {
        self.get_title().unwrap_or_default()
    }

    /// Sayfa simgesini (emoji veya ikon slug'ı) ayarlar/kaldırır.
    pub fn set_icon(&self, icon: Option<&str>) {
        let mut txn = self.doc.transact_mut();
        match icon {
            Some(ic) => {
                self.meta.insert(&mut txn, "icon", ic);
            }
            None => {
                self.meta.remove(&mut txn, "icon");
            }
        }
        let now = Utc::now().timestamp_millis();
        self.meta.insert(&mut txn, "updated_at", now);
    }

    /// Sayfa simgesini okur.
    pub fn get_icon(&self) -> Option<String> {
        let txn = self.doc.transact();
        match self.meta.get(&txn, "icon") {
            Some(Out::Any(Any::String(s))) => Some(s.to_string()),
            _ => None,
        }
    }

    /// `updated_at` zaman damgasını (milisaniye cinsinden Unix epoch) ayarlar.
    pub fn set_updated_at(&self, timestamp_ms: i64) {
        let mut txn = self.doc.transact_mut();
        self.meta.insert(&mut txn, "updated_at", timestamp_ms);
    }

    /// `updated_at` zaman damgasını okur.
    pub fn get_updated_at(&self) -> Option<i64> {
        let txn = self.doc.transact();
        match self.meta.get(&txn, "updated_at") {
            Some(Out::Any(Any::BigInt(ts))) => Some(ts),
            Some(Out::Any(Any::Number(n))) => Some(n as i64),
            _ => None,
        }
    }

    // =========================================================================
    // Zengin Metin Metodları (`yrs::TextRef`)
    // =========================================================================

    fn block_text_key(block_id: &str) -> String {
        format!("block_text:{block_id}")
    }

    /// İlgili blok için doğrudan `yrs::TextRef` erişimi sağlar.
    pub fn get_block_text_ref(&self, block_id: &str) -> TextRef {
        self.doc.get_or_insert_text(Self::block_text_key(block_id))
    }

    /// Bloğun zengin metin alanına belirtilen indekste karakter/metin parçası ekler.
    pub fn insert_block_text(&self, block_id: &str, index: u32, chunk: &str) {
        if chunk.is_empty() {
            return;
        }
        let text_ref = self.get_block_text_ref(block_id);
        let mut txn = self.doc.transact_mut();
        let current_len = text_ref.len(&txn);
        let safe_index = index.min(current_len);
        text_ref.insert(&mut txn, safe_index, chunk);

        let now = Utc::now().timestamp_millis();
        self.meta.insert(&mut txn, "updated_at", now);
    }

    /// Bloğun zengin metin sonuna metin ekler.
    pub fn push_block_text(&self, block_id: &str, chunk: &str) {
        if chunk.is_empty() {
            return;
        }
        let text_ref = self.get_block_text_ref(block_id);
        let mut txn = self.doc.transact_mut();
        text_ref.push(&mut txn, chunk);

        let now = Utc::now().timestamp_millis();
        self.meta.insert(&mut txn, "updated_at", now);
    }

    /// Bloğun mevcut zengin metin içeriğini `String` olarak okur.
    pub fn get_block_text(&self, block_id: &str) -> String {
        let text_ref = self.get_block_text_ref(block_id);
        let txn = self.doc.transact();
        text_ref.get_string(&txn)
    }

    // =========================================================================
    // Blok Koleksiyonu Metodları (`blocks` Map)
    // =========================================================================

    /// Belirtilen blok ID'sine ait JSON dizesini ekler veya günceller (upsert).
    /// `block_json` geçerli JSON olmalıdır, aksi halde `CoreError::Serialization` döner.
    pub fn upsert_block_json(&self, block_id: &str, block_json: &str) -> Result<()> {
        // JSON doğrulaması
        let _parsed: serde_json::Value = serde_json::from_str(block_json)
            .map_err(|e| CoreError::Serialization(format!("Geçersiz blok JSON formatı: {e}")))?;

        let mut txn = self.doc.transact_mut();
        self.blocks.insert(&mut txn, block_id, block_json);

        let now = Utc::now().timestamp_millis();
        self.meta.insert(&mut txn, "updated_at", now);
        Ok(())
    }

    /// Domain `Block` yapısını doğrudan ekler veya günceller.
    pub fn upsert_block(&self, block: &Block) -> Result<()> {
        let json_str = serde_json::to_string(block)?;
        self.upsert_block_json(&block.id.to_string(), &json_str)
    }

    /// Belirtilen blok ID'sini kaldırır. Blok mevcut idiyse `true`, değilse `false` döner.
    pub fn remove_block(&self, block_id: &str) -> bool {
        let mut txn = self.doc.transact_mut();
        let removed = self.blocks.remove(&mut txn, block_id).is_some();
        if removed {
            let now = Utc::now().timestamp_millis();
            self.meta.insert(&mut txn, "updated_at", now);
        }
        removed
    }

    /// Belirtilen blok ID'sine ait JSON dizesini getirir.
    pub fn get_block_json(&self, block_id: &str) -> Option<String> {
        let txn = self.doc.transact();
        match self.blocks.get(&txn, block_id) {
            Some(Out::Any(Any::String(s))) => Some(s.to_string()),
            _ => None,
        }
    }

    /// Tüm blokları `sort_order` değerine göre (artan sırada) sıralı JSON listesi olarak döndürür.
    /// `sort_order` bulunamazsa `block_id` ikincil anahtar olarak kullanılır.
    pub fn list_blocks_json(&self) -> Vec<String> {
        let txn = self.doc.transact();
        let mut entries: Vec<(f64, String, String)> = Vec::new();

        for (key, out) in self.blocks.iter(&txn) {
            if let Out::Any(Any::String(s)) = out {
                let json_str = s.to_string();
                let sort_order = serde_json::from_str::<serde_json::Value>(&json_str)
                    .ok()
                    .and_then(|v| v.get("sort_order").and_then(|so| so.as_f64()))
                    .unwrap_or(f64::INFINITY);
                entries.push((sort_order, key.to_string(), json_str));
            }
        }

        entries.sort_by(|a, b| {
            a.0.partial_cmp(&b.0)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.1.cmp(&b.1))
        });

        entries.into_iter().map(|(_, _, json)| json).collect()
    }

    /// Tüm blokları ayrıştırılmış `Block` modelleri olarak sıralı döndürür.
    pub fn list_blocks(&self) -> Result<Vec<Block>> {
        let jsons = self.list_blocks_json();
        let mut blocks = Vec::with_capacity(jsons.len());
        for json in jsons {
            let block: Block = serde_json::from_str(&json)?;
            blocks.push(block);
        }
        Ok(blocks)
    }

    /// Dokümandaki toplam blok sayısını döndürür.
    pub fn block_count(&self) -> usize {
        let txn = self.doc.transact();
        self.blocks.len(&txn) as usize
    }
}
