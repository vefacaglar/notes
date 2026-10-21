use thiserror::Error;
use uuid::Uuid;

/// `notes-sync` bileşenine özgü hata türleri.
#[derive(Error, Debug)]
pub enum SyncError {
    #[error("notes-core hatası: {0}")]
    Core(#[from] notes_core::CoreError),

    #[error("Serileştirme/ayrıştırma hatası: {0}")]
    Serialization(String),

    #[error("Ağ / taşıma (transport) hatası: {0}")]
    Transport(String),

    #[error("Kimlik doğrulama başarısız: {0}")]
    AuthFailed(String),

    #[error("Bütünlük (MAC / Hash) hatası: {0}")]
    IntegrityError(String),

    #[error("Maksimum yeniden deneme sınırı aşıldı: id={id}, retries={retries}")]
    MaxRetriesExceeded { id: Uuid, retries: u32 },

    #[error("Kuyruk işlem hatası: {0}")]
    Queue(String),

    #[error("Geçersiz protokol verisi: {0}")]
    Protocol(String),

    #[error("Kriptografi hatası: {0}")]
    Crypto(String),

    #[error("HTTP istek hatası: {0}")]
    Http(#[from] reqwest::Error),

    #[error("Sunucu hatası ({status}): {message}")]
    Server { status: u16, message: String },

    #[error("Kaynak veya blob bulunamadı: {0}")]
    NotFound(String),

    #[error("BLAKE3 hash bütünlük hatası! Beklenen: {expected}, Gerçekleşen: {actual}")]
    HashMismatch { expected: String, actual: String },
}

impl From<serde_json::Error> for SyncError {
    fn from(err: serde_json::Error) -> Self {
        SyncError::Serialization(err.to_string())
    }
}

pub type Result<T> = std::result::Result<T, SyncError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sync_error_display() {
        let err = SyncError::Transport("Bağlantı koptu".into());
        assert_eq!(err.to_string(), "Ağ / taşıma (transport) hatası: Bağlantı koptu");

        let err2 = SyncError::AuthFailed("Geçersiz token".into());
        assert_eq!(err2.to_string(), "Kimlik doğrulama başarısız: Geçersiz token");

        let test_id = Uuid::nil();
        let err3 = SyncError::MaxRetriesExceeded {
            id: test_id,
            retries: 5,
        };
        assert_eq!(
            err3.to_string(),
            format!("Maksimum yeniden deneme sınırı aşıldı: id={test_id}, retries=5")
        );

        let err4 = SyncError::Server {
            status: 500,
            message: "Internal Server Error".into(),
        };
        assert_eq!(err4.to_string(), "Sunucu hatası (500): Internal Server Error");

        let err5 = SyncError::HashMismatch {
            expected: "a".into(),
            actual: "b".into(),
        };
        assert_eq!(
            err5.to_string(),
            "BLAKE3 hash bütünlük hatası! Beklenen: a, Gerçekleşen: b"
        );
    }

    #[test]
    fn test_serde_json_error_conversion() {
        let bad_json = "{bad_json}";
        let res: std::result::Result<serde_json::Value, _> = serde_json::from_str(bad_json);
        let err: SyncError = res.unwrap_err().into();
        assert!(matches!(err, SyncError::Serialization(_)));
    }
}
