use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Serialize;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ServerError {
    #[error("Veritabanı hatası: {0}")]
    Database(#[from] rusqlite::Error),

    #[error("Yetkilendirme hatası: {0}")]
    Unauthorized(String),

    #[error("Erişim engellendi: {0}")]
    Forbidden(String),

    #[error("Kayıt bulunamadı: {0}")]
    NotFound(String),

    #[error("Çakışma: {0}")]
    Conflict(String),

    #[error("Geçersiz girdi: {0}")]
    InvalidInput(String),

    #[error("Sunucu dahili hatası: {0}")]
    Internal(String),
}

#[derive(Serialize)]
struct ErrorResponseBody {
    error: String,
    code: u16,
}

impl IntoResponse for ServerError {
    fn into_response(self) -> Response {
        let (status, message) = match &self {
            ServerError::Database(err) => {
                tracing::error!("Veritabanı hatası oluştu: {:?}", err);
                (StatusCode::INTERNAL_SERVER_ERROR, "Veritabanı işlemi başarısız".to_string())
            }
            ServerError::Unauthorized(msg) => (StatusCode::UNAUTHORIZED, msg.clone()),
            ServerError::Forbidden(msg) => (StatusCode::FORBIDDEN, msg.clone()),
            ServerError::NotFound(msg) => (StatusCode::NOT_FOUND, msg.clone()),
            ServerError::Conflict(msg) => (StatusCode::CONFLICT, msg.clone()),
            ServerError::InvalidInput(msg) => (StatusCode::BAD_REQUEST, msg.clone()),
            ServerError::Internal(msg) => {
                tracing::error!("Sunucu dahili hatası: {}", msg);
                (StatusCode::INTERNAL_SERVER_ERROR, "Sunucu içi beklenmeyen bir hata meydana geldi".to_string())
            }
        };

        let body = Json(ErrorResponseBody {
            error: message,
            code: status.as_u16(),
        });

        (status, body).into_response()
    }
}

pub type ServerResult<T> = Result<T, ServerError>;
