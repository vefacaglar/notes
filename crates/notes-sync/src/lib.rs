//! # Notes Sync
//!
//! Bu crate, çevrimdışı outbox kuyruğu, yrs CRDT durum vektörü el sıkışması
//! ve kör senkronizasyon (Blind Relay) protokolü istemci bileşenlerini içerir.

pub mod blob;
pub mod client;
pub mod error;
pub mod protocol;
pub mod queue;

pub use blob::{
    BlobTransferClient, BlobTransferError, BlobTransport, InMemoryBlobTransport,
    ReqwestBlobTransport,
};
pub use client::{
    InMemorySyncTransport, ReqwestSyncTransport, SyncClientConfig, SyncClientError, SyncTransport,
};
pub use error::{Result, SyncError};
pub use protocol::{
    create_handshake_request, envelope_aad, open_handshake_envelopes, BlobUploadMeta,
    DocStateVector, EncryptedUpdateEnvelope, SyncHandshakeRequest, SyncHandshakeResponse,
    SyncPullRequest, SyncPullResponse, SyncPushRequest, SyncPushResponse,
};
pub use queue::{OutboxQueue, RetryPolicy};

pub fn sync_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;
    use notes_core::crdt::doc::PageCrdtDoc;
    use notes_core::crypto::generate_dek;
    use notes_core::storage::{LocalStore, WorkspaceRecord};
    use uuid::Uuid;

    #[test]
    fn test_sync_version() {
        assert_eq!(sync_version(), "0.1.0");
    }

    #[test]
    fn test_e2e_crdt_envelope_outbox_flow() {
        // 1. Yerel veritabanı ve DEK kurulumu
        let store = LocalStore::open_in_memory().unwrap();
        let ws_id = Uuid::now_v7();
        let ws = WorkspaceRecord {
            id: ws_id,
            name: "E2E Test Workspace".to_string(),
            encrypted_dek: vec![1, 2, 3],
            dek_nonce: vec![0; 24],
            created_at: 1000,
        };
        store.create_workspace(&ws).unwrap();
        let dek = generate_dek();

        // 2. İki farklı istemci YDoc'u oluştur
        let client_a_id: u64 = 1001;
        let client_b_id: u64 = 1002;
        let doc_id = Uuid::now_v7();

        let doc_a = PageCrdtDoc::with_client_id(client_a_id);
        let mut doc_b = PageCrdtDoc::with_client_id(client_b_id);

        // İstemci A yerelde değişiklik yapar
        doc_a.set_title("E2EE Başlık A");
        let update_a = doc_a.encode_state_as_update(&[]).unwrap();

        // 3. İstemci A değişikliği mühürleyip outbox kuyruğuna ekler
        let envelope_a = EncryptedUpdateEnvelope::seal_update(
            ws_id,
            doc_id,
            client_a_id,
            1,
            &dek,
            &update_a,
        )
        .expect("Zarf mühürlenmeli");

        let queue = OutboxQueue::new(&store);
        let queued_id = queue.enqueue(&envelope_a).unwrap();
        assert_eq!(queue.count_pending().unwrap(), 1);

        // 4. Outbox'tan bekleyen zarfları çek (Ağ simülasyonu)
        let pending = queue.peek_pending_envelopes(10).unwrap();
        assert_eq!(pending.len(), 1);
        let (item, fetched_envelope) = &pending[0];
        assert_eq!(item.id, queued_id);

        // İstemci B zarfı alır ve açar
        let decrypted_update = fetched_envelope.open_update(&dek).unwrap();
        doc_b.apply_update(&decrypted_update).unwrap();

        // İstemci B'nin başlığı güncellenmiş olmalı
        assert_eq!(doc_b.title(), "E2EE Başlık A");

        // 5. Sunucu ACK'si sonrası kuyruktan sil
        queue.mark_success(queued_id).unwrap();
        assert_eq!(queue.count_pending().unwrap(), 0);
    }
}
