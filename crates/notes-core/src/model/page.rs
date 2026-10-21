use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Not sayfası veri modeli.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Page {
    pub id: Uuid,
    pub workspace_id: Uuid,
    pub parent_page_id: Option<Uuid>,
    pub title: String,
    pub icon: Option<String>,
    pub cover_image: Option<String>,
    pub is_database: bool,
    pub is_pinned: bool,
    pub is_deleted: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl Page {
    /// Yeni bir standart not sayfası oluşturur (UUIDv7 ve geçerli UTC zamanı ile).
    pub fn new(workspace_id: Uuid, title: impl Into<String>) -> Self {
        let now = Utc::now();
        Self {
            id: Uuid::now_v7(),
            workspace_id,
            parent_page_id: None,
            title: title.into(),
            icon: None,
            cover_image: None,
            is_database: false,
            is_pinned: false,
            is_deleted: false,
            created_at: now,
            updated_at: now,
        }
    }

    /// Yeni bir veritabanı sayfası oluşturur.
    pub fn new_database(workspace_id: Uuid, title: impl Into<String>) -> Self {
        let mut page = Self::new(workspace_id, title);
        page.is_database = true;
        page
    }

    /// Üst sayfa (parent_page_id) atar.
    pub fn with_parent(mut self, parent_page_id: Uuid) -> Self {
        self.parent_page_id = Some(parent_page_id);
        self
    }

    /// Sayfa simgesi (emoji veya ikon slug'ı) atar.
    pub fn with_icon(mut self, icon: impl Into<String>) -> Self {
        self.icon = Some(icon.into());
        self
    }

    /// Sayfa kapak görseli URL veya blob hash'i atar.
    pub fn with_cover_image(mut self, cover: impl Into<String>) -> Self {
        self.cover_image = Some(cover.into());
        self
    }

    /// Sayfayı yeniden adlandırır ve `updated_at` damgasını günceller.
    pub fn rename(&mut self, new_title: impl Into<String>) {
        self.title = new_title.into();
        self.touch();
    }

    /// Sabitleme durumunu değiştirir.
    pub fn set_pinned(&mut self, pinned: bool) {
        if self.is_pinned != pinned {
            self.is_pinned = pinned;
            self.touch();
        }
    }

    /// Sayfayı çöp kutusuna taşır (soft delete).
    pub fn soft_delete(&mut self) {
        if !self.is_deleted {
            self.is_deleted = true;
            self.touch();
        }
    }

    /// Sayfayı çöp kutusundan geri yükler.
    pub fn restore(&mut self) {
        if self.is_deleted {
            self.is_deleted = false;
            self.touch();
        }
    }

    /// Sayfanın üst dizinini değiştirir.
    pub fn move_to_parent(&mut self, parent_id: Option<Uuid>) {
        if self.parent_page_id != parent_id {
            self.parent_page_id = parent_id;
            self.touch();
        }
    }

    /// `updated_at` zamanını geçerli zamana ayarlar.
    pub fn touch(&mut self) {
        self.updated_at = Utc::now();
    }
}

/// İki yönlü bağlantı (Backlink & Wikilink) modeli.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PageLink {
    pub id: Uuid,
    pub source_page_id: Uuid,
    pub target_page_id: Uuid,
    pub source_block_id: Option<Uuid>,
    pub anchor_text: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl PageLink {
    /// İki sayfa arasında yeni bir bağlantı oluşturur.
    pub fn new(source_page_id: Uuid, target_page_id: Uuid) -> Self {
        Self {
            id: Uuid::now_v7(),
            source_page_id,
            target_page_id,
            source_block_id: None,
            anchor_text: None,
            created_at: Utc::now(),
        }
    }

    /// Bağlantının kaynaklandığı blok kimliğini atar.
    pub fn with_source_block(mut self, block_id: Uuid) -> Self {
        self.source_block_id = Some(block_id);
        self
    }

    /// Bağlantı metnini (anchor text) atar.
    pub fn with_anchor(mut self, anchor: impl Into<String>) -> Self {
        self.anchor_text = Some(anchor.into());
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_page_lifecycle_and_helpers() {
        let ws_id = Uuid::now_v7();
        let mut page = Page::new(ws_id, "Başlangıç Notu")
            .with_icon("📝")
            .with_cover_image("cover.jpg");

        assert_eq!(page.title, "Başlangıç Notu");
        assert_eq!(page.icon.as_deref(), Some("📝"));
        assert_eq!(page.cover_image.as_deref(), Some("cover.jpg"));
        assert!(!page.is_database);
        assert!(!page.is_pinned);
        assert!(!page.is_deleted);
        assert_eq!(page.parent_page_id, None);

        let initial_updated_at = page.updated_at;

        // Yeniden adlandırma
        page.rename("Güncellenmiş Not");
        assert_eq!(page.title, "Güncellenmiş Not");
        assert!(page.updated_at >= initial_updated_at);

        // Sabitleme
        page.set_pinned(true);
        assert!(page.is_pinned);

        // Üst sayfaya taşıma
        let parent_id = Uuid::now_v7();
        page.move_to_parent(Some(parent_id));
        assert_eq!(page.parent_page_id, Some(parent_id));

        // Soft delete ve restore
        page.soft_delete();
        assert!(page.is_deleted);
        page.restore();
        assert!(!page.is_deleted);
    }

    #[test]
    fn test_database_page_creation() {
        let ws_id = Uuid::now_v7();
        let db_page = Page::new_database(ws_id, "Görev Tablosu");
        assert!(db_page.is_database);
        assert_eq!(db_page.title, "Görev Tablosu");
    }

    #[test]
    fn test_page_json_roundtrip() {
        let ws_id = Uuid::now_v7();
        let page = Page::new(ws_id, "JSON Test")
            .with_icon("⚡")
            .with_parent(Uuid::now_v7());

        let json = serde_json::to_string(&page).expect("JSON'a serileştirilemedi");
        let deserialized: Page = serde_json::from_str(&json).expect("JSON'dan ayrıştırılamadı");

        assert_eq!(page.id, deserialized.id);
        assert_eq!(page.title, deserialized.title);
        assert_eq!(page.workspace_id, deserialized.workspace_id);
        assert_eq!(page.parent_page_id, deserialized.parent_page_id);
        assert_eq!(page.icon, deserialized.icon);
    }

    #[test]
    fn test_page_link_lifecycle_and_json() {
        let src = Uuid::now_v7();
        let tgt = Uuid::now_v7();
        let block_id = Uuid::now_v7();

        let link = PageLink::new(src, tgt)
            .with_source_block(block_id)
            .with_anchor("Detaylar");

        assert_eq!(link.source_page_id, src);
        assert_eq!(link.target_page_id, tgt);
        assert_eq!(link.source_block_id, Some(block_id));
        assert_eq!(link.anchor_text.as_deref(), Some("Detaylar"));

        let json = serde_json::to_string(&link).expect("JSON serileştirme hatası");
        let deserialized: PageLink = serde_json::from_str(&json).expect("JSON ayrıştırma hatası");
        assert_eq!(link.id, deserialized.id);
        assert_eq!(link.anchor_text, deserialized.anchor_text);
    }
}
