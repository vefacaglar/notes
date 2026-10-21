use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::{CoreError, Result};

/// Blok türleri (TipTap ve Notion veri modelleriyle uyumlu).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BlockType {
    Paragraph,
    Heading1,
    Heading2,
    Heading3,
    BulletListItem,
    NumberedListItem,
    TodoItem,
    CodeBlock,
    Quote,
    Callout,
    Divider,
    Image,
    File,
    DatabaseInline,
}

impl BlockType {
    pub fn as_str(&self) -> &'static str {
        match self {
            BlockType::Paragraph => "paragraph",
            BlockType::Heading1 => "heading1",
            BlockType::Heading2 => "heading2",
            BlockType::Heading3 => "heading3",
            BlockType::BulletListItem => "bullet_list_item",
            BlockType::NumberedListItem => "numbered_list_item",
            BlockType::TodoItem => "todo_item",
            BlockType::CodeBlock => "code_block",
            BlockType::Quote => "quote",
            BlockType::Callout => "callout",
            BlockType::Divider => "divider",
            BlockType::Image => "image",
            BlockType::File => "file",
            BlockType::DatabaseInline => "database_inline",
        }
    }
}

/// Sayfa içi blok veri modeli.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Block {
    pub id: Uuid,
    pub page_id: Uuid,
    pub parent_block_id: Option<Uuid>,
    pub block_type: BlockType,
    pub content: serde_json::Value,
    pub properties: serde_json::Value,
    pub sort_order: f64,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl Block {
    /// Temel blok oluşturur.
    pub fn new(page_id: Uuid, block_type: BlockType, sort_order: f64) -> Self {
        let now = Utc::now();
        Self {
            id: Uuid::now_v7(),
            page_id,
            parent_block_id: None,
            block_type,
            content: serde_json::json!({}),
            properties: serde_json::json!({}),
            sort_order,
            created_at: now,
            updated_at: now,
        }
    }

    /// Paragraf bloğu oluşturur.
    pub fn paragraph(page_id: Uuid, text: impl Into<String>, sort_order: f64) -> Self {
        let mut block = Self::new(page_id, BlockType::Paragraph, sort_order);
        block.content = serde_json::json!({ "text": text.into() });
        block
    }

    /// Başlık bloğu (1, 2 veya 3) oluşturur.
    pub fn heading(page_id: Uuid, level: u8, text: impl Into<String>, sort_order: f64) -> Result<Self> {
        let block_type = match level {
            1 => BlockType::Heading1,
            2 => BlockType::Heading2,
            3 => BlockType::Heading3,
            _ => {
                return Err(CoreError::Validation(format!(
                    "Geçersiz başlık seviyesi: {}. Seviye 1..=3 arasında olmalıdır",
                    level
                )))
            }
        };

        let mut block = Self::new(page_id, block_type, sort_order);
        block.content = serde_json::json!({ "text": text.into() });
        Ok(block)
    }

    /// Yapılacak iş (todo) bloğu oluşturur.
    pub fn todo(page_id: Uuid, text: impl Into<String>, checked: bool, sort_order: f64) -> Self {
        let mut block = Self::new(page_id, BlockType::TodoItem, sort_order);
        block.content = serde_json::json!({ "text": text.into() });
        block.properties = serde_json::json!({ "checked": checked });
        block
    }

    /// Kod bloğu oluşturur.
    pub fn code(
        page_id: Uuid,
        code: impl Into<String>,
        language: Option<&str>,
        sort_order: f64,
    ) -> Self {
        let mut block = Self::new(page_id, BlockType::CodeBlock, sort_order);
        block.content = serde_json::json!({ "code": code.into() });
        if let Some(lang) = language {
            block.properties = serde_json::json!({ "language": lang });
        }
        block
    }

    /// Alıntı (Quote) bloğu oluşturur.
    pub fn quote(page_id: Uuid, text: impl Into<String>, sort_order: f64) -> Self {
        let mut block = Self::new(page_id, BlockType::Quote, sort_order);
        block.content = serde_json::json!({ "text": text.into() });
        block
    }

    /// Ayırıcı çizgi (Divider) bloğu oluşturur.
    pub fn divider(page_id: Uuid, sort_order: f64) -> Self {
        Self::new(page_id, BlockType::Divider, sort_order)
    }

    /// İç içe hiyerarşi için üst blok kimliğini atar.
    pub fn with_parent(mut self, parent_block_id: Uuid) -> Self {
        self.parent_block_id = Some(parent_block_id);
        self
    }

    /// Blok içeriğini atar.
    pub fn with_content(mut self, content: serde_json::Value) -> Self {
        self.content = content;
        self
    }

    /// Blok ek özelliklerini atar.
    pub fn with_properties(mut self, properties: serde_json::Value) -> Self {
        self.properties = properties;
        self
    }

    /// İçeriği günceller ve zaman damgasını yeniler.
    pub fn set_content(&mut self, content: serde_json::Value) {
        self.content = content;
        self.touch();
    }

    /// Sıra numarasını günceller.
    pub fn set_sort_order(&mut self, sort_order: f64) {
        self.sort_order = sort_order;
        self.touch();
    }

    /// `updated_at` zaman damgasını geçerli zamana günceller.
    pub fn touch(&mut self) {
        self.updated_at = Utc::now();
    }

    /// FTS5 arama indeksi için JSON içerikten düz metin (plain text) çıkarır.
    pub fn extract_plain_text(&self) -> String {
        Self::extract_text_from_value(&self.content)
    }

    fn extract_text_from_value(value: &serde_json::Value) -> String {
        match value {
            serde_json::Value::String(s) => s.clone(),
            serde_json::Value::Object(map) => {
                if let Some(text_val) = map.get("text").and_then(|t| t.as_str()) {
                    return text_val.to_string();
                }
                if let Some(code_val) = map.get("code").and_then(|c| c.as_str()) {
                    return code_val.to_string();
                }

                let mut parts = Vec::new();
                for val in map.values() {
                    let extracted = Self::extract_text_from_value(val);
                    if !extracted.is_empty() {
                        parts.push(extracted);
                    }
                }
                parts.join(" ")
            }
            serde_json::Value::Array(arr) => {
                let parts: Vec<String> = arr
                    .iter()
                    .map(Self::extract_text_from_value)
                    .filter(|s| !s.is_empty())
                    .collect();
                parts.join(" ")
            }
            _ => String::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_block_creation_and_helpers() {
        let page_id = Uuid::now_v7();
        let p_block = Block::paragraph(page_id, "Merhaba Dünya", 10.0);

        assert_eq!(p_block.page_id, page_id);
        assert_eq!(p_block.block_type, BlockType::Paragraph);
        assert_eq!(p_block.sort_order, 10.0);
        assert_eq!(p_block.extract_plain_text(), "Merhaba Dünya");

        let h1 = Block::heading(page_id, 1, "Başlık 1", 20.0).unwrap();
        assert_eq!(h1.block_type, BlockType::Heading1);
        assert_eq!(h1.extract_plain_text(), "Başlık 1");

        let invalid_h = Block::heading(page_id, 4, "Geçersiz", 30.0);
        assert!(invalid_h.is_err());

        let todo = Block::todo(page_id, "Ekmek al", false, 40.0);
        assert_eq!(todo.block_type, BlockType::TodoItem);
        assert_eq!(todo.properties["checked"], false);

        let code = Block::code(page_id, "fn main() {}", Some("rust"), 50.0);
        assert_eq!(code.block_type, BlockType::CodeBlock);
        assert_eq!(code.properties["language"], "rust");
        assert_eq!(code.extract_plain_text(), "fn main() {}");
    }

    #[test]
    fn test_extract_plain_text_nested_tiptap() {
        let page_id = Uuid::now_v7();
        let tiptap_content = serde_json::json!({
            "type": "doc",
            "content": [
                {
                    "type": "paragraph",
                    "content": [
                        { "type": "text", "text": "Notion benzeri" },
                        { "type": "text", "text": "blok editörü" }
                    ]
                }
            ]
        });

        let mut block = Block::new(page_id, BlockType::Paragraph, 1.0);
        block.content = tiptap_content;

        let plain = block.extract_plain_text();
        assert!(plain.contains("Notion benzeri"));
        assert!(plain.contains("blok editörü"));
    }

    #[test]
    fn test_block_json_roundtrip() {
        let page_id = Uuid::now_v7();
        let block = Block::paragraph(page_id, "Deneme", 1.5).with_parent(Uuid::now_v7());

        let json = serde_json::to_string(&block).expect("Serileştirilemedi");
        let deserialized: Block = serde_json::from_str(&json).expect("Ayrıştırılamadı");

        assert_eq!(block.id, deserialized.id);
        assert_eq!(block.block_type, deserialized.block_type);
        assert_eq!(block.sort_order, deserialized.sort_order);
        assert_eq!(block.parent_block_id, deserialized.parent_block_id);
    }
}
