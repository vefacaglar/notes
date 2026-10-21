use notes_core::storage::{LocalStore, OutboxItem, PageRepo};
use uuid::Uuid;

use crate::error::{Result, SyncError};
use crate::protocol::EncryptedUpdateEnvelope;
use crate::queue::retry::RetryPolicy;

/// Yerel SQLite `sync_outbox` tablosunu yöneten çevrimdışı outbox kuyruk motoru.
///
/// Ağ bağlantısı olmadığında yerel değişiklikleri (`EncryptedUpdateEnvelope`)
/// katı FIFO (`created_at ASC, id ASC`) sırasıyla saklar ve bağlantı sağlandığında
/// sunucuya iletilmek üzere sırayla tüketir.
pub struct OutboxQueue<'a> {
    store: &'a LocalStore,
    policy: RetryPolicy,
}

impl<'a> OutboxQueue<'a> {
    /// Varsayılan yeniden deneme politikası ile yeni bir `OutboxQueue` örneği oluşturur.
    pub fn new(store: &'a LocalStore) -> Self {
        Self {
            store,
            policy: RetryPolicy::default(),
        }
    }

    /// Özel bir `RetryPolicy` ile `OutboxQueue` örneği oluşturur.
    pub fn with_policy(store: &'a LocalStore, policy: RetryPolicy) -> Self {
        Self { store, policy }
    }

    /// Aktif yeniden deneme politikasını döndürür.
    pub fn policy(&self) -> &RetryPolicy {
        &self.policy
    }

    /// Şifrelenmiş güncelleme zarfını JSON olarak serileştirip `sync_outbox` tablosuna ekler.
    pub fn enqueue(&self, envelope: &EncryptedUpdateEnvelope) -> Result<Uuid> {
        let envelope_bytes = serde_json::to_vec(envelope)
            .map_err(|e| SyncError::Serialization(e.to_string()))?;

        let item = OutboxItem {
            id: envelope.id,
            workspace_id: envelope.workspace_id,
            doc_id: envelope.doc_id,
            envelope_bytes,
            retry_count: 0,
            last_error: None,
            created_at: envelope.created_at,
        };

        let repo = PageRepo::new(self.store.conn());
        repo.enqueue_outbox(&item).map_err(SyncError::Core)?;

        Ok(item.id)
    }

    /// Kuyruktaki ham kayıtları katı FIFO (`created_at ASC, id ASC`) sırasıyla getirir.
    pub fn peek_pending(&self, limit: usize) -> Result<Vec<OutboxItem>> {
        let repo = PageRepo::new(self.store.conn());
        repo.list_outbox_fifo(limit).map_err(SyncError::Core)
    }

    /// Kuyruktaki bekleyen kayıtları de-serileştirilmiş `EncryptedUpdateEnvelope` listesi olarak getirir.
    pub fn peek_pending_envelopes(
        &self,
        limit: usize,
    ) -> Result<Vec<(OutboxItem, EncryptedUpdateEnvelope)>> {
        let items = self.peek_pending(limit)?;
        let mut results = Vec::with_capacity(items.len());

        for item in items {
            let envelope: EncryptedUpdateEnvelope = serde_json::from_slice(&item.envelope_bytes)
                .map_err(|e| {
                    SyncError::Serialization(format!(
                        "Outbox zarfı (id={}) de-serileştirilemedi: {e}",
                        item.id
                    ))
                })?;
            results.push((item, envelope));
        }

        Ok(results)
    }

    /// Başarıyla sunucuya iletilen outbox kaydını kuyruktan siler (ACK).
    pub fn mark_success(&self, id: Uuid) -> Result<()> {
        let repo = PageRepo::new(self.store.conn());
        repo.remove_outbox(id).map_err(SyncError::Core)
    }

    /// Birden fazla başarılı zarfı tek seferde kuyruktan siler.
    pub fn mark_success_batch(&self, ids: &[Uuid]) -> Result<()> {
        let repo = PageRepo::new(self.store.conn());
        for &id in ids {
            repo.remove_outbox(id).map_err(SyncError::Core)?;
        }
        Ok(())
    }

    /// Başarısız gönderimde deneme sayısını artırır ve hata mesajını günceller.
    ///
    /// Güncel deneme sayısı `policy.max_retries` eşiğine ulaştıysa veya aştıysa
    /// `SyncError::MaxRetriesExceeded { id, retries }` döndürür.
    pub fn mark_failed(&self, id: Uuid, error_msg: &str) -> Result<u32> {
        let repo = PageRepo::new(self.store.conn());

        // Mevcut retry sayısını sorgula
        let current_retries: i64 = self
            .store
            .conn()
            .query_row(
                "SELECT retry_count FROM sync_outbox WHERE id = ?1",
                rusqlite::params![id.to_string()],
                |row| row.get(0),
            )
            .map_err(|e| SyncError::Queue(format!("Kayıt retry_count sorgulanamadı (id={id}): {e}")))?;

        let new_count = (current_retries + 1) as u32;

        repo.mark_outbox_retry(id, error_msg)
            .map_err(SyncError::Core)?;

        if new_count >= self.policy.max_retries {
            return Err(SyncError::MaxRetriesExceeded {
                id,
                retries: new_count,
            });
        }

        Ok(new_count)
    }

    /// `mark_failed` için fonksiyon takma adı (alias).
    pub fn record_failure(&self, id: Uuid, error_msg: &str) -> Result<u32> {
        self.mark_failed(id, error_msg)
    }

    /// Geriye dönük uyumluluk için `mark_retry` fonksiyonu.
    pub fn mark_retry(&self, id: Uuid, error_msg: &str) -> Result<u32> {
        self.mark_failed(id, error_msg)
    }

    /// Belirtilen deneme sayısı için yeniden deneme bekleme süresini (exponential backoff + jitter) hesaplar.
    pub fn next_delay(&self, retry_count: u32) -> std::time::Duration {
        self.policy.calculate_delay_with_jitter(retry_count)
    }

    /// Kuyruktaki toplam bekleyen kayıt sayısını döndürür.
    pub fn count_pending(&self) -> Result<usize> {
        let count: i64 = self
            .store
            .conn()
            .query_row("SELECT COUNT(*) FROM sync_outbox", [], |row| row.get(0))
            .map_err(|e| SyncError::Queue(format!("Outbox kayıt sayısı sorgulanamadı: {e}")))?;

        Ok(count as usize)
    }

    /// Tüm outbox kuyruğunu boşaltır.
    pub fn clear(&self) -> Result<()> {
        self.store
            .conn()
            .execute("DELETE FROM sync_outbox", [])
            .map_err(|e| SyncError::Queue(format!("Outbox temizlenemedi: {e}")))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use notes_core::crypto::generate_dek;
    use notes_core::storage::WorkspaceRecord;

    fn setup_test_workspace(store: &LocalStore) -> Uuid {
        let ws_id = Uuid::now_v7();
        let ws = WorkspaceRecord {
            id: ws_id,
            name: "Outbox Test WS".to_string(),
            encrypted_dek: vec![1, 2, 3],
            dek_nonce: vec![0; 24],
            created_at: chrono::Utc::now().timestamp_millis(),
        };
        store.create_workspace(&ws).unwrap();
        ws_id
    }

    #[test]
    fn test_enqueue_and_peek_strict_fifo() {
        let store = LocalStore::open_in_memory().expect("In-memory SQLite");
        let ws_id = setup_test_workspace(&store);
        let doc_id = Uuid::now_v7();
        let dek = generate_dek();

        let queue = OutboxQueue::new(&store);

        // 3 farklı zarf oluştur
        let mut env1 = EncryptedUpdateEnvelope::seal_update(
            ws_id,
            doc_id,
            1,
            1,
            &dek,
            b"update-1",
        )
        .unwrap();
        env1.created_at = 1000;

        let mut env2 = EncryptedUpdateEnvelope::seal_update(
            ws_id,
            doc_id,
            1,
            2,
            &dek,
            b"update-2",
        )
        .unwrap();
        env2.created_at = 2000;

        let mut env3 = EncryptedUpdateEnvelope::seal_update(
            ws_id,
            doc_id,
            1,
            3,
            &dek,
            b"update-3",
        )
        .unwrap();
        env3.created_at = 3000;

        // Karışık sırada ekle
        queue.enqueue(&env2).unwrap();
        queue.enqueue(&env1).unwrap();
        queue.enqueue(&env3).unwrap();

        assert_eq!(queue.count_pending().unwrap(), 3);

        // Katı FIFO sıralamasıyla çek
        let pending = queue.peek_pending_envelopes(10).unwrap();
        assert_eq!(pending.len(), 3);
        assert_eq!(pending[0].1.id, env1.id);
        assert_eq!(pending[1].1.id, env2.id);
        assert_eq!(pending[2].1.id, env3.id);

        // Plaintext içeriklerin doğrulanması
        let payload1 = pending[0].1.open_update(&dek).unwrap();
        assert_eq!(payload1, b"update-1");
        let payload2 = pending[1].1.open_update(&dek).unwrap();
        assert_eq!(payload2, b"update-2");
    }

    #[test]
    fn test_mark_success_and_batch() {
        let store = LocalStore::open_in_memory().unwrap();
        let ws_id = setup_test_workspace(&store);
        let dek = generate_dek();
        let queue = OutboxQueue::new(&store);

        let env1 =
            EncryptedUpdateEnvelope::seal_update(ws_id, Uuid::now_v7(), 1, 1, &dek, b"a").unwrap();
        let env2 =
            EncryptedUpdateEnvelope::seal_update(ws_id, Uuid::now_v7(), 1, 2, &dek, b"b").unwrap();

        queue.enqueue(&env1).unwrap();
        queue.enqueue(&env2).unwrap();
        assert_eq!(queue.count_pending().unwrap(), 2);

        // Tekil silme
        queue.mark_success(env1.id).unwrap();
        assert_eq!(queue.count_pending().unwrap(), 1);

        // Toplu silme
        queue.mark_success_batch(&[env2.id]).unwrap();
        assert_eq!(queue.count_pending().unwrap(), 0);
    }

    #[test]
    fn test_mark_retry_and_max_retries_exceeded() {
        let store = LocalStore::open_in_memory().unwrap();
        let ws_id = setup_test_workspace(&store);
        let dek = generate_dek();

        let policy = RetryPolicy::default().with_max_retries(3);
        let queue = OutboxQueue::with_policy(&store, policy);

        let env =
            EncryptedUpdateEnvelope::seal_update(ws_id, Uuid::now_v7(), 1, 1, &dek, b"fail test")
                .unwrap();
        let env_id = queue.enqueue(&env).unwrap();

        // 1. Başarısızlık: retry_count = 1 (< 3)
        let count1 = queue.mark_failed(env_id, "503 Service Unavailable").unwrap();
        assert_eq!(count1, 1);

        // 2. Başarısızlık (record_failure takma adı ile): retry_count = 2 (< 3)
        let count2 = queue.record_failure(env_id, "Connection Timeout").unwrap();
        assert_eq!(count2, 2);

        // 3. Başarısızlık: retry_count = 3 (== max_retries) -> MaxRetriesExceeded hatası dönmeli
        let res3 = queue.mark_failed(env_id, "Fatal network error");
        assert!(res3.is_err());
        match res3.unwrap_err() {
            SyncError::MaxRetriesExceeded { id, retries } => {
                assert_eq!(id, env_id);
                assert_eq!(retries, 3);
            }
            other => panic!("Beklenmeyen hata türü: {other:?}"),
        }
    }
}
