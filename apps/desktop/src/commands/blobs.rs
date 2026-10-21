use serde::{Deserialize, Serialize};

use crate::state::{AppError, DesktopAppState};

/// Yüklenen medya/dosya ekinin meta verileri.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AttachmentMetadata {
    pub blob_hash: String,
    pub filename: String,
    pub size_bytes: usize,
}

/// Ham dosya baytlarını DEK ile şifreleyerek CAS (Content-Addressed Storage) blob deposuna yazar.
pub fn cmd_upload_attachment(
    state: &DesktopAppState,
    raw_bytes: Vec<u8>,
    filename: String,
) -> Result<AttachmentMetadata, AppError> {
    let (dek, _, _, _) = state.require_unlocked()?;

    if raw_bytes.is_empty() {
        return Err(AppError::ValidationError("Dosya içeriği boş olamaz".into()));
    }

    let size_bytes = raw_bytes.len();
    let blob_hash = state.blob_store.save(&raw_bytes, dek.as_bytes())?;

    Ok(AttachmentMetadata {
        blob_hash,
        filename,
        size_bytes,
    })
}

/// BLAKE3 hash'i verilen şifreli eki okur, DEK ile deşifre eder ve ham baytları döner.
pub fn cmd_get_attachment(
    state: &DesktopAppState,
    blob_hash: &str,
) -> Result<Vec<u8>, AppError> {
    let (dek, _, _, _) = state.require_unlocked()?;

    let trimmed = blob_hash.trim();
    if trimmed.is_empty() {
        return Err(AppError::ValidationError("Blob hash boş olamaz".into()));
    }

    let raw_bytes = state.blob_store.read(trimmed, dek.as_bytes())?;
    Ok(raw_bytes)
}

/// BLAKE3 hash'ine sahip bir ekin yerel depoda bulunup bulunmadığını kontrol eder.
pub fn cmd_has_attachment(
    state: &DesktopAppState,
    blob_hash: &str,
) -> Result<bool, AppError> {
    state.require_unlocked()?;
    Ok(state.blob_store.has_blob(blob_hash))
}
