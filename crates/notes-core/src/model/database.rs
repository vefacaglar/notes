use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::{CoreError, Result};
use crate::model::property::DatabasePropertyDefinition;

/// Veritabanı görünüm türleri (Notion görünümleri).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ViewType {
    Table,
    Board,
    Calendar,
    List,
    Gallery,
}

/// Veritabanı şeması modeli (kolon tanımları ve meta veri).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DatabaseSchema {
    pub id: Uuid,
    pub page_id: Uuid,
    pub properties: Vec<DatabasePropertyDefinition>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl DatabaseSchema {
    /// Yeni bir veritabanı şeması oluşturur.
    pub fn new(page_id: Uuid) -> Self {
        let now = Utc::now();
        Self {
            id: Uuid::now_v7(),
            page_id,
            properties: Vec::new(),
            created_at: now,
            updated_at: now,
        }
    }

    /// Yeni bir özellik (kolon) ekler.
    pub fn add_property(&mut self, property: DatabasePropertyDefinition) {
        self.properties.push(property);
        self.touch();
    }

    /// ID'ye göre özellik tanımını getirir.
    pub fn get_property(&self, id: &str) -> Option<&DatabasePropertyDefinition> {
        self.properties.iter().find(|p| p.id == id)
    }

    /// ID'ye göre özellik tanımını mut referans olarak getirir.
    pub fn get_property_mut(&mut self, id: &str) -> Option<&mut DatabasePropertyDefinition> {
        self.touch();
        self.properties.iter_mut().find(|p| p.id == id)
    }

    /// ID'ye göre özelliği kaldırır.
    pub fn remove_property(&mut self, id: &str) -> Option<DatabasePropertyDefinition> {
        if let Some(pos) = self.properties.iter().position(|p| p.id == id) {
            self.touch();
            Some(self.properties.remove(pos))
        } else {
            None
        }
    }

    /// Özelliği yeniden adlandırır.
    pub fn rename_property(&mut self, id: &str, new_name: impl Into<String>) -> Result<()> {
        let name_str = new_name.into();
        if name_str.trim().is_empty() {
            return Err(CoreError::Validation("Kolon adı boş olamaz".into()));
        }

        if let Some(prop) = self.get_property_mut(id) {
            prop.name = name_str;
            Ok(())
        } else {
            Err(CoreError::NotFound(format!("Kolon bulunamadı: {}", id)))
        }
    }

    /// `updated_at` zaman damgasını günceller.
    pub fn touch(&mut self) {
        self.updated_at = Utc::now();
    }
}

/// Veritabanı görünümü modeli (Filtreler, Sıralama kuralları, Görünür kolonlar).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DatabaseView {
    pub id: Uuid,
    pub database_id: Uuid,
    pub title: String,
    pub view_type: ViewType,
    pub filter_groups: serde_json::Value,
    pub sort_rules: serde_json::Value,
    pub visible_properties: Vec<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl DatabaseView {
    /// Yeni bir veritabanı görünümü oluşturur.
    pub fn new(database_id: Uuid, title: impl Into<String>, view_type: ViewType) -> Self {
        let now = Utc::now();
        Self {
            id: Uuid::now_v7(),
            database_id,
            title: title.into(),
            view_type,
            filter_groups: serde_json::json!([]),
            sort_rules: serde_json::json!([]),
            visible_properties: Vec::new(),
            created_at: now,
            updated_at: now,
        }
    }

    /// Görünür kolonları yapılandırır.
    pub fn with_visible_properties(mut self, properties: Vec<String>) -> Self {
        self.visible_properties = properties;
        self
    }

    /// Filtre gruplarını yapılandırır.
    pub fn with_filter_groups(mut self, filter_groups: serde_json::Value) -> Self {
        self.filter_groups = filter_groups;
        self
    }

    /// Sıralama kurallarını yapılandırır.
    pub fn with_sort_rules(mut self, sort_rules: serde_json::Value) -> Self {
        self.sort_rules = sort_rules;
        self
    }

    /// Başlığı günceller.
    pub fn set_title(&mut self, title: impl Into<String>) {
        self.title = title.into();
        self.touch();
    }

    /// Görünür kolon listesini günceller.
    pub fn set_visible_properties(&mut self, properties: Vec<String>) {
        self.visible_properties = properties;
        self.touch();
    }

    /// `updated_at` zaman damgasını günceller.
    pub fn touch(&mut self) {
        self.updated_at = Utc::now();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::property::PropertyType;

    #[test]
    fn test_database_schema_operations() {
        let page_id = Uuid::now_v7();
        let mut schema = DatabaseSchema::new(page_id);

        let col1 = DatabasePropertyDefinition::new("Görev Adı", PropertyType::Text);
        let col1_id = col1.id.clone();
        let col2 = DatabasePropertyDefinition::new("Tamamlandı", PropertyType::Checkbox);

        schema.add_property(col1);
        schema.add_property(col2);

        assert_eq!(schema.properties.len(), 2);
        assert!(schema.get_property(&col1_id).is_some());

        // Yeniden adlandırma
        let res = schema.rename_property(&col1_id, "Başlık");
        assert!(res.is_ok());
        assert_eq!(schema.get_property(&col1_id).unwrap().name, "Başlık");

        // Geçersiz adlandırma
        let invalid = schema.rename_property(&col1_id, "   ");
        assert!(invalid.is_err());

        // Özellik kaldırma
        let removed = schema.remove_property(&col1_id);
        assert!(removed.is_some());
        assert_eq!(schema.properties.len(), 1);
    }

    #[test]
    fn test_database_view_builder_and_json() {
        let db_id = Uuid::now_v7();
        let view = DatabaseView::new(db_id, "Varsayılan Tablo", ViewType::Table)
            .with_visible_properties(vec!["col_ad".into(), "col_durum".into()])
            .with_sort_rules(serde_json::json!([
                { "property": "col_ad", "direction": "ascending" }
            ]));

        assert_eq!(view.view_type, ViewType::Table);
        assert_eq!(view.visible_properties.len(), 2);

        let json = serde_json::to_string(&view).expect("Serileştirilemedi");
        let deserialized: DatabaseView = serde_json::from_str(&json).expect("Ayrıştırılamadı");

        assert_eq!(view.id, deserialized.id);
        assert_eq!(view.title, deserialized.title);
        assert_eq!(view.view_type, deserialized.view_type);
        assert_eq!(view.visible_properties, deserialized.visible_properties);
    }
}
