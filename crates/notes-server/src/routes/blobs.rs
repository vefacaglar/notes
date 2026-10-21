use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::header::{HeaderMap, CONTENT_LENGTH, CONTENT_TYPE};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::{constant_time_eq_str, AuthenticatedUser};
use crate::error::{ServerError, ServerResult};
use crate::AppState;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlobUploadResponse {
    pub blob_hash: String,
    pub size_bytes: usize,
    pub created: bool,
}


/// `PUT /api/v1/blobs/{blob_hash}`
/// Şifreli CAS blob yükler. `blake3(body) == blob_hash` olduğunu doğrular; uyuşmazsa 400 Bad Request döner.
pub async fn put_blob(
    _user: AuthenticatedUser,
    State(state): State<AppState>,
    Path(blob_hash): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> ServerResult<impl IntoResponse> {
    if blob_hash.trim().is_empty() {
        return Err(ServerError::InvalidInput("blob_hash boş olamaz".into()));
    }

    // Hash doğrulaması (Content-Addressed Storage bütünlük kontrolü)
    let computed_hash = blake3::hash(&body).to_hex().to_string();
    if !constant_time_eq_str(&computed_hash, &blob_hash) {
        return Err(ServerError::InvalidInput(format!(
            "BLAKE3 hash doğrulaması başarısız: gönderilen hash '{}', hesaplanan '{}'",
            blob_hash, computed_hash
        )));
    }

    // Workspace ID: X-Workspace-Id başlığından al veya "default" kullan
    let workspace_id = headers
        .get("x-workspace-id")
        .and_then(|val| val.to_str().ok())
        .unwrap_or("default");

    let created = state.store.put_blob(&blob_hash, workspace_id, &body)?;

    let status = if created {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };

    Ok((
        status,
        Json(BlobUploadResponse {
            blob_hash,
            size_bytes: body.len(),
            created,
        }),
    ))
}

/// `GET /api/v1/blobs/{blob_hash}`
/// Şifreli CAS blob içeriğini binary olarak döner.
pub async fn get_blob(
    _user: AuthenticatedUser,
    State(state): State<AppState>,
    Path(blob_hash): Path<String>,
) -> ServerResult<Response> {
    let blob = state
        .store
        .get_blob(&blob_hash)?
        .ok_or_else(|| ServerError::NotFound(format!("Blob bulunamadı: {}", blob_hash)))?;

    let response = Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, "application/octet-stream")
        .header(CONTENT_LENGTH, blob.size_bytes.to_string())
        .header("x-workspace-id", blob.workspace_id)
        .body(axum::body::Body::from(blob.ciphertext))
        .map_err(|e| ServerError::Internal(format!("Yanıt gövdesi oluşturulamadı: {e}")))?;

    Ok(response)
}
