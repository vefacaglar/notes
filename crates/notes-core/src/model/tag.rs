use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::{CoreError, Result};

/// Sayfa etiketi (Tag) veri modeli.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Tag {
    pub page_id: Uuid,
    pub tag: String,
    pub created_at: DateTime<Utc>,
}

impl Tag {
    /// Yeni bir sayfa etiketi oluşturur ve etiketi normalize eder.
    pub fn new(page_id: Uuid, raw_tag: impl Into<String>) -> Result<Self> {
        let normalized = Self::normalize(&raw_tag.into())?;
        Ok(Self {
            page_id,
            tag: normalized,
            created_at: Utc::now(),
        })
    }

    /// Etiket metnini normalize eder (başındaki '#' kaldırılır, küçük harfe çevrilir, boşluklar kontrol edilir).
    pub fn normalize(raw: &str) -> Result<String> {
        let trimmed = raw.trim().trim_start_matches('#').trim();
        if trimmed.is_empty() {
            return Err(CoreError::InvalidTag("Etiket metni boş olamaz".into()));
        }

        // Boşluk veya yasaklı karakter kontrolü
        if trimmed.chars().any(|c| c.is_whitespace() || c == '/' || c == '\\') {
            return Err(CoreError::InvalidTag(format!(
                "Etiket boşluk veya geçersiz karakter içeremez: '{}'",
                raw
            )));
        }

        Ok(trimmed.to_lowercase())
    }

    /// Etiketin hash sembollü halini döndürür (örn. "#proje").
    pub fn display_tag(&self) -> String {
        format!("#{}", self.tag)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tag_normalization_and_validation() {
        let page_id = Uuid::now_v7();

        let tag1 = Tag::new(page_id, "#Rust").unwrap();
        assert_eq!(tag1.tag, "rust");
        assert_eq!(tag1.display_tag(), "#rust");

        let tag2 = Tag::new(page_id, "  #NotesApp  ").unwrap();
        assert_eq!(tag2.tag, "notesapp");

        // Geçersiz durumlar
        assert!(Tag::new(page_id, "").is_err());
        assert!(Tag::new(page_id, "###").is_err());
        assert!(Tag::new(page_id, "iki kelime").is_err());
        assert!(Tag::new(page_id, "etiket/test").is_err());
    }

    #[test]
    fn test_tag_json_roundtrip() {
        let page_id = Uuid::now_v7();
        let tag = Tag::new(page_id, "kriptografi").unwrap();

        let json = serde_json::to_string(&tag).expect("Serileştirilemedi");
        let deserialized: Tag = serde_json::from_str(&json).expect("Ayrıştırılamadı");

        assert_eq!(tag, deserialized);
    }
}
