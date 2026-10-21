use thiserror::Error;

/// notes-core bileşeni için temel hata türleri.
#[derive(Error, Debug, PartialEq)]
pub enum CoreError {
    #[error("Serileştirme/ayrıştırma hatası: {0}")]
    Serialization(String),

    #[error("Doğrulama hatası: {0}")]
    Validation(String),

    #[error("Kayıt bulunamadı: {0}")]
    NotFound(String),

    #[error("Geçersiz blok türü: {0}")]
    InvalidBlockType(String),

    #[error("Geçersiz özellik değeri veya türü: {0}")]
    InvalidProperty(String),

    #[error("Geçersiz etiket formatı: {0}")]
    InvalidTag(String),

    #[error("Geçersiz durum: {0}")]
    InvalidState(String),

    #[error("Kripto hatası: {0}")]
    Crypto(String),

    #[error("Veritabanı hatası: {0}")]
    Database(String),

    #[error("Dahili hata: {0}")]
    Internal(String),
}

impl From<serde_json::Error> for CoreError {
    fn from(err: serde_json::Error) -> Self {
        CoreError::Serialization(err.to_string())
    }
}

pub type Result<T> = std::result::Result<T, CoreError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_core_error_display() {
        let err = CoreError::Validation("Sayfa başlığı boş olamaz".into());
        assert_eq!(err.to_string(), "Doğrulama hatası: Sayfa başlığı boş olamaz");

        let err2 = CoreError::NotFound("Sayfa id=123".into());
        assert_eq!(err2.to_string(), "Kayıt bulunamadı: Sayfa id=123");
    }

    #[test]
    fn test_serde_error_conversion() {
        let bad_json = "{bad_json}";
        let res: std::result::Result<serde_json::Value, _> = serde_json::from_str(bad_json);
        let err: CoreError = res.unwrap_err().into();
        assert!(matches!(err, CoreError::Serialization(_)));
    }
}
