use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::Result;
use crate::protocol::frames::EncryptedUpdateEnvelope;

/// Tek bir dokümanın CRDT durum vektörü (StateVector v1 binary) temsili.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DocStateVector {
    pub doc_id: Uuid,
    /// yrs `StateVector::encode_v1` ikili çıktısı
    pub state_vector: Vec<u8>,
}

impl DocStateVector {
    pub fn new(doc_id: Uuid, state_vector: Vec<u8>) -> Self {
        Self {
            doc_id,
            state_vector,
        }
    }
}

/// İstemcinin yerel durum vektörlerini sunucuya bildirdiği el sıkışma isteği (Faz 1).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SyncHandshakeRequest {
    pub workspace_id: Uuid,
    pub client_id: u64,
    /// İstemcinin takip ettiği dokümanlara ait durum vektörleri
    pub state_vectors: Vec<DocStateVector>,
}

impl SyncHandshakeRequest {
    pub fn new(
        workspace_id: Uuid,
        client_id: u64,
        state_vectors: Vec<DocStateVector>,
    ) -> Self {
        Self {
            workspace_id,
            client_id,
            state_vectors,
        }
    }
}

/// Sunucunun istemciye eksik zarfları bildirdiği el sıkışma yanıtı.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SyncHandshakeResponse {
    pub workspace_id: Uuid,
    /// Sunucuda bulunan ancak istemcinin durum vektöründe eksik olan şifreli zarflar
    pub missing_envelopes: Vec<EncryptedUpdateEnvelope>,
}

impl SyncHandshakeResponse {
    pub fn new(
        workspace_id: Uuid,
        missing_envelopes: Vec<EncryptedUpdateEnvelope>,
    ) -> Self {
        Self {
            workspace_id,
            missing_envelopes,
        }
    }
}

/// Doküman ID ve durum vektörlerinden kolayca bir el sıkışma isteği oluşturur.
pub fn create_handshake_request(
    workspace_id: Uuid,
    client_id: u64,
    docs: &[(Uuid, Vec<u8>)],
) -> SyncHandshakeRequest {
    let state_vectors = docs
        .iter()
        .map(|(doc_id, sv)| DocStateVector::new(*doc_id, sv.clone()))
        .collect();

    SyncHandshakeRequest::new(workspace_id, client_id, state_vectors)
}

/// Gelen eksik şifreli zarfları çalışma alanı DEK'i ile açarak doküman güncellemelerini döner.
pub fn open_handshake_envelopes(
    envelopes: &[EncryptedUpdateEnvelope],
    dek: &notes_core::crypto::DataEncryptionKey,
) -> Result<Vec<(Uuid, Vec<u8>)>> {
    let mut updates = Vec::with_capacity(envelopes.len());
    for env in envelopes {
        let plaintext = env.open_update(dek)?;
        updates.push((env.doc_id, plaintext));
    }
    Ok(updates)
}

#[cfg(test)]
mod tests {
    use super::*;
    use notes_core::crypto::generate_dek;

    #[test]
    fn test_handshake_request_serialization() {
        let ws_id = Uuid::now_v7();
        let doc1 = Uuid::now_v7();
        let doc2 = Uuid::now_v7();

        let req = create_handshake_request(
            ws_id,
            42,
            &[(doc1, vec![1, 2, 3]), (doc2, vec![4, 5, 6])],
        );

        assert_eq!(req.state_vectors.len(), 2);
        assert_eq!(req.state_vectors[0].doc_id, doc1);

        let json = serde_json::to_string(&req).expect("JSON serileştirme");
        let decoded: SyncHandshakeRequest = serde_json::from_str(&json).expect("JSON çözümleme");
        assert_eq!(req, decoded);
    }

    #[test]
    fn test_open_handshake_envelopes() {
        let ws_id = Uuid::now_v7();
        let doc_id = Uuid::now_v7();
        let dek = generate_dek();

        let env = EncryptedUpdateEnvelope::seal_update(
            ws_id,
            doc_id,
            1,
            10,
            &dek,
            b"handshake update bytes",
        )
        .unwrap();

        let opened = open_handshake_envelopes(&[env], &dek).expect("Zarflar açılmalı");
        assert_eq!(opened.len(), 1);
        assert_eq!(opened[0].0, doc_id);
        assert_eq!(opened[0].1, b"handshake update bytes");
    }
}
