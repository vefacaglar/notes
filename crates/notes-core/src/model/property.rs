use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Veritabanı sütun / özellik türleri.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PropertyType {
    Text,
    Number,
    Select,
    MultiSelect,
    Date,
    Checkbox,
    Url,
    Email,
    Relation,
    CreatedTime,
    LastEditedTime,
}

/// Select ve MultiSelect alanları için seçenek tanımı.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SelectOption {
    pub id: String,
    pub name: String,
    pub color: Option<String>,
}

impl SelectOption {
    /// Yeni bir seçenek oluşturur (id otomatik türetilir).
    pub fn new(name: impl Into<String>) -> Self {
        let name_str = name.into();
        let slug = name_str
            .to_lowercase()
            .replace(' ', "_")
            .replace(|c: char| !c.is_alphanumeric() && c != '_', "");
        Self {
            id: if slug.is_empty() {
                Uuid::now_v7().to_string()
            } else {
                slug
            },
            name: name_str,
            color: None,
        }
    }

    /// Özel bir id ile seçenek oluşturur.
    pub fn with_id(mut self, id: impl Into<String>) -> Self {
        self.id = id.into();
        self
    }

    /// Seçenek rengini atar (örn. "blue", "red", "#ff0000").
    pub fn with_color(mut self, color: impl Into<String>) -> Self {
        self.color = Some(color.into());
        self
    }
}

/// Veritabanı sütun tanımı (Database Schema Property).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DatabasePropertyDefinition {
    pub id: String,
    pub name: String,
    pub property_type: PropertyType,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub options: Option<Vec<SelectOption>>,
}

impl DatabasePropertyDefinition {
    /// Yeni bir sütun tanımı oluşturur.
    pub fn new(name: impl Into<String>, property_type: PropertyType) -> Self {
        let name_str = name.into();
        let id = format!(
            "col_{}",
            name_str
                .to_lowercase()
                .replace(' ', "_")
                .replace(|c: char| !c.is_alphanumeric() && c != '_', "")
        );
        Self {
            id,
            name: name_str,
            property_type,
            options: None,
        }
    }

    /// Özel bir sütun ID'si atar.
    pub fn with_id(mut self, id: impl Into<String>) -> Self {
        self.id = id.into();
        self
    }

    /// Select seçeneklerini atar.
    pub fn with_options(mut self, options: Vec<SelectOption>) -> Self {
        self.options = Some(options);
        self
    }

    /// Mevcut seçeneklere yeni bir seçenek ekler.
    pub fn add_option(&mut self, option: SelectOption) {
        if let Some(opts) = &mut self.options {
            opts.push(option);
        } else {
            self.options = Some(vec![option]);
        }
    }
}

/// Tip güvenli hücre / özellik değeri (Notion property values).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "value", rename_all = "snake_case")]
pub enum PropertyValue {
    Text(String),
    Number(f64),
    Select(String),
    MultiSelect(Vec<String>),
    Date(DateTime<Utc>),
    Checkbox(bool),
    Url(String),
    Email(String),
    Relation(Vec<Uuid>),
    CreatedTime(DateTime<Utc>),
    LastEditedTime(DateTime<Utc>),
    Empty,
}

impl PropertyValue {
    /// Değerin boş olup olmadığını kontrol eder.
    pub fn is_empty(&self) -> bool {
        match self {
            PropertyValue::Empty => true,
            PropertyValue::Text(s) | PropertyValue::Select(s) | PropertyValue::Url(s) | PropertyValue::Email(s) => {
                s.trim().is_empty()
            }
            PropertyValue::MultiSelect(vec) => vec.is_empty(),
            PropertyValue::Relation(vec) => vec.is_empty(),
            _ => false,
        }
    }

    /// Özellik değerinin verilen PropertyType ile uyumlu olup olmadığını doğrular.
    pub fn matches_type(&self, prop_type: &PropertyType) -> bool {
        if matches!(self, PropertyValue::Empty) {
            return true;
        }
        matches!(
            (self, prop_type),
            (PropertyValue::Text(_), PropertyType::Text)
                | (PropertyValue::Number(_), PropertyType::Number)
                | (PropertyValue::Select(_), PropertyType::Select)
                | (PropertyValue::MultiSelect(_), PropertyType::MultiSelect)
                | (PropertyValue::Date(_), PropertyType::Date)
                | (PropertyValue::Checkbox(_), PropertyType::Checkbox)
                | (PropertyValue::Url(_), PropertyType::Url)
                | (PropertyValue::Email(_), PropertyType::Email)
                | (PropertyValue::Relation(_), PropertyType::Relation)
                | (PropertyValue::CreatedTime(_), PropertyType::CreatedTime)
                | (PropertyValue::LastEditedTime(_), PropertyType::LastEditedTime)
        )
    }

    /// Metin değeri olarak okur.
    pub fn as_text(&self) -> Option<&str> {
        match self {
            PropertyValue::Text(s) | PropertyValue::Select(s) | PropertyValue::Url(s) | PropertyValue::Email(s) => {
                Some(s.as_str())
            }
            _ => None,
        }
    }

    /// Sayısal değer olarak okur.
    pub fn as_number(&self) -> Option<f64> {
        match self {
            PropertyValue::Number(n) => Some(*n),
            _ => None,
        }
    }

    /// Boole değer olarak okur.
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            PropertyValue::Checkbox(b) => Some(*b),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_select_option_creation() {
        let opt = SelectOption::new("Devam Ediyor").with_color("blue");
        assert_eq!(opt.name, "Devam Ediyor");
        assert_eq!(opt.id, "devam_ediyor");
        assert_eq!(opt.color.as_deref(), Some("blue"));
    }

    #[test]
    fn test_property_definition_and_options() {
        let mut prop = DatabasePropertyDefinition::new("Durum", PropertyType::Select);
        assert_eq!(prop.id, "col_durum");
        assert_eq!(prop.property_type, PropertyType::Select);

        prop.add_option(SelectOption::new("Yapılacak").with_color("gray"));
        prop.add_option(SelectOption::new("Tamamlandı").with_color("green"));

        assert_eq!(prop.options.as_ref().unwrap().len(), 2);
    }

    #[test]
    fn test_property_value_type_matching() {
        let txt = PropertyValue::Text("Not".into());
        assert!(txt.matches_type(&PropertyType::Text));
        assert!(!txt.matches_type(&PropertyType::Number));

        let num = PropertyValue::Number(42.5);
        assert!(num.matches_type(&PropertyType::Number));
        assert_eq!(num.as_number(), Some(42.5));

        let chk = PropertyValue::Checkbox(true);
        assert!(chk.matches_type(&PropertyType::Checkbox));
        assert_eq!(chk.as_bool(), Some(true));

        let empty = PropertyValue::Empty;
        assert!(empty.matches_type(&PropertyType::Text));
        assert!(empty.matches_type(&PropertyType::Date));
        assert!(empty.is_empty());
    }

    #[test]
    fn test_property_value_json_roundtrip() {
        let val = PropertyValue::MultiSelect(vec!["rust".into(), "crypto".into()]);
        let json = serde_json::to_string(&val).expect("Serileştirilemedi");
        let deserialized: PropertyValue = serde_json::from_str(&json).expect("Ayrıştırılamadı");

        assert_eq!(val, deserialized);
    }
}
