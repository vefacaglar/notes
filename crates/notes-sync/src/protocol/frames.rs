use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::{Result, SyncError};

/// Zarf AAD (Associated Authenticated Data) bağlama fonksiyonu.
///
/// XChaCha20-Poly1305 AEAD şifrelemesinde ciphertext'in belirli bir
/// `workspace_id` ve `doc_id` ikilisine kriptografik olarak bağlanmasını
/// sağlar. Başka bir dokümana veya çalışma alanına taşınan zarflar
/// deşifre edilemez ve reddedilir.
pub fn envelope_aad(workspace_id: Uuid, doc_id: Uuid) -> Vec<u8> {
    format!("workspace_id:{}:doc_id:{}", workspace_id, doc_id).into_bytes()
}

/// DEK (Data Encryption Key) ile şifrelenmiş CRDT güncelleme zarfı.
///
/// Sunucu bu zarfın içeriğini göremez (Blind Relay). Yalnızca `id`, `workspace_id`,
/// `doc_id`, `client_id`, `clock_sequence` ve `created_at` meta verilerine erişir.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EncryptedUpdateEnvelope {
    /// Zaman sıralı benzersiz zarf kimliği (UUIDv7)
    pub id: Uuid,
    /// Zarfın ait olduğu çalışma alanı kimliği
    pub workspace_id: Uuid,
    /// İlgili sayfa / doküman kimliği (YDoc ID)
    pub doc_id: Uuid,
    /// yrs istemci tanımlayıcısı (client identifier)
    pub client_id: u64,
    /// İstemci bazlı artan mantıksal saat / sıra numarası
    pub clock_sequence: u64,
    /// XChaCha20 192-bit (24 bayt) kriptografik nonce
    pub nonce: [u8; 24],
    /// Şifrelenmiş yrs binary güncellemesi ve Poly1305 MAC etiketi
    pub ciphertext: Vec<u8>,
    /// Unix epoch milisaniye zaman damgası
    pub created_at: i64,
}

impl EncryptedUpdateEnvelope {
    /// Açık metin (plaintext) CRDT ikili güncellemesini çalışma alanı DEK'i ile
    /// mühürler (seal) ve yeni bir zarf üretir.
    pub fn seal_update(
        workspace_id: Uuid,
        doc_id: Uuid,
        client_id: u64,
        clock_sequence: u64,
        dek: &notes_core::crypto::DataEncryptionKey,
        plaintext_update: &[u8],
    ) -> Result<Self> {
        let nonce = notes_core::crypto::generate_nonce();
        let aad = envelope_aad(workspace_id, doc_id);

        let ciphertext =
            notes_core::crypto::encrypt_aead(dek.as_bytes(), &nonce, plaintext_update, &aad)
                .map_err(|e| SyncError::Crypto(e.to_string()))?;

        let id = Uuid::now_v7();
        let created_at = chrono::Utc::now().timestamp_millis();

        Ok(Self {
            id,
            workspace_id,
            doc_id,
            client_id,
            clock_sequence,
            nonce,
            ciphertext,
            created_at,
        })
    }

    /// Çalışma alanı DEK'i ile zarfın şifresini çözer ve CRDT ikili güncellemesini döner.
    ///
    /// Poly1305 MAC etiketi veya AAD doğrulaması başarısız olursa `SyncError::IntegrityError` döner.
    pub fn open_update(&self, dek: &notes_core::crypto::DataEncryptionKey) -> Result<Vec<u8>> {
        let aad = envelope_aad(self.workspace_id, self.doc_id);
        notes_core::crypto::decrypt_aead(dek.as_bytes(), &self.nonce, &self.ciphertext, &aad)
            .map_err(|e| {
                SyncError::IntegrityError(format!(
                    "Zarf deşifresi veya bütünlük (MAC) doğrulaması başarısız: {e}"
                ))
            })
    }

    /// Zarfı JSON baytlarına serileştirir.
    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        serde_json::to_vec(self).map_err(|e| SyncError::Serialization(e.to_string()))
    }

    /// JSON baytlarından zarfı de-serileştirir.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        serde_json::from_slice(bytes).map_err(|e| SyncError::Serialization(e.to_string()))
    }
}

/// İstemciden sunucuya gönderilen toplu güncelleme (Push) isteği.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SyncPushRequest {
    pub workspace_id: Uuid,
    pub client_id: u64,
    pub envelopes: Vec<EncryptedUpdateEnvelope>,
}

impl SyncPushRequest {
    pub fn new(
        workspace_id: Uuid,
        client_id: u64,
        envelopes: Vec<EncryptedUpdateEnvelope>,
    ) -> Self {
        Self {
            workspace_id,
            client_id,
            envelopes,
        }
    }
}

/// Sunucudan istemciye dönen Push yanıtı (ACK / NACK).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SyncPushResponse {
    pub workspace_id: Uuid,
    /// Sunucu tarafından başarıyla kabul edilen zarf kimlikleri
    pub accepted_ids: Vec<Uuid>,
    /// Reddedilen zarflar ve hata gerekçeleri
    pub rejected_ids: Vec<(Uuid, String)>,
}

impl SyncPushResponse {
    pub fn is_success(&self) -> bool {
        self.rejected_ids.is_empty()
    }
}

/// İstemcinin sunucudan eksik güncellemeleri talep ettiği Pull isteği.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SyncPullRequest {
    pub workspace_id: Uuid,
    /// Belirli dokümanların güncellemeleri isteniyorsa (boş ise tüm çalışma alanı)
    pub doc_ids: Option<Vec<Uuid>>,
    /// Belirli bir zamandan sonraki güncellemeler (milisaniye)
    pub since_timestamp: Option<i64>,
    /// Maksimum çekilecek zarf sayısı
    pub limit: Option<usize>,
}

/// Sunucunun Pull isteğine cevaben gönderdiği paket.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SyncPullResponse {
    pub workspace_id: Uuid,
    pub envelopes: Vec<EncryptedUpdateEnvelope>,
    pub has_more: bool,
    pub latest_timestamp: i64,
}

/// İçerik-adresli medya blobu yükleme/indirme meta verisi.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BlobUploadMeta {
    pub workspace_id: Uuid,
    /// BLAKE3 şifreli içerik karması (hex formatı)
    pub blob_hash: String,
    /// Şifreli dosyanın bayt boyutu
    pub size_bytes: u64,
    /// İsteğe bağlı MIME türü (şifrelenmemiş bilgi vermez, generic olabilir)
    pub mime_type: Option<String>,
    /// Oluşturulma zamanı (Unix milisaniye)
    pub created_at: i64,
}

impl BlobUploadMeta {
    pub fn new(
        workspace_id: Uuid,
        blob_hash: impl Into<String>,
        size_bytes: u64,
        mime_type: Option<String>,
    ) -> Self {
        Self {
            workspace_id,
            blob_hash: blob_hash.into(),
            size_bytes,
            mime_type,
            created_at: chrono::Utc::now().timestamp_millis(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use notes_core::crypto::generate_dek;

    #[test]
    fn test_seal_and_open_update_roundtrip() {
        let ws_id = Uuid::now_v7();
        let doc_id = Uuid::now_v7();
        let dek = generate_dek();
        let client_id = 12345;
        let clock_seq = 1;
        let payload = b"CRDT binary update test payload \x01\x02\x03";

        let envelope =
            EncryptedUpdateEnvelope::seal_update(ws_id, doc_id, client_id, clock_seq, &dek, payload)
                .expect("Zarf başarıyla mühürlenmeli");

        assert_eq!(envelope.workspace_id, ws_id);
        assert_eq!(envelope.doc_id, doc_id);
        assert_eq!(envelope.client_id, client_id);
        assert_eq!(envelope.clock_sequence, clock_seq);
        assert_ne!(envelope.ciphertext, payload);

        let decrypted = envelope.open_update(&dek).expect("Zarf açılabilmeli");
        assert_eq!(decrypted, payload);
    }

    #[test]
    fn test_open_with_wrong_dek_fails() {
        let ws_id = Uuid::now_v7();
        let doc_id = Uuid::now_v7();
        let dek1 = generate_dek();
        let dek2 = generate_dek();
        let payload = b"Top secret data";

        let envelope =
            EncryptedUpdateEnvelope::seal_update(ws_id, doc_id, 1, 1, &dek1, payload).unwrap();

        let err = envelope.open_update(&dek2);
        assert!(err.is_err());
        assert!(matches!(err.unwrap_err(), SyncError::IntegrityError(_)));
    }

    #[test]
    fn test_tampered_ciphertext_fails() {
        let ws_id = Uuid::now_v7();
        let doc_id = Uuid::now_v7();
        let dek = generate_dek();
        let payload = b"Original CRDT data";

        let mut envelope =
            EncryptedUpdateEnvelope::seal_update(ws_id, doc_id, 1, 1, &dek, payload).unwrap();

        // 1 baytı boz
        let last = envelope.ciphertext.len() - 1;
        envelope.ciphertext[last] ^= 0x55;

        let err = envelope.open_update(&dek);
        assert!(err.is_err());
        assert!(matches!(err.unwrap_err(), SyncError::IntegrityError(_)));
    }

    #[test]
    fn test_aad_mismatch_fails() {
        let ws_id = Uuid::now_v7();
        let doc_id = Uuid::now_v7();
        let fake_doc_id = Uuid::now_v7();
        let dek = generate_dek();
        let payload = b"Target doc payload";

        let mut envelope =
            EncryptedUpdateEnvelope::seal_update(ws_id, doc_id, 1, 1, &dek, payload).unwrap();

        // Zarfın doc_id alanını değiştir (replay / substitution attack simülasyonu)
        envelope.doc_id = fake_doc_id;

        let err = envelope.open_update(&dek);
        assert!(err.is_err());
        assert!(matches!(err.unwrap_err(), SyncError::IntegrityError(_)));
    }

    #[test]
    fn test_envelope_serialization_roundtrip() {
        let ws_id = Uuid::now_v7();
        let doc_id = Uuid::now_v7();
        let dek = generate_dek();
        let envelope =
            EncryptedUpdateEnvelope::seal_update(ws_id, doc_id, 42, 99, &dek, b"serialize me")
                .unwrap();

        let bytes = envelope.to_bytes().expect("Zarf serileştirilmeli");
        let decoded =
            EncryptedUpdateEnvelope::from_bytes(&bytes).expect("Zarf geri çözülmeli");

        assert_eq!(envelope, decoded);
    }
}
