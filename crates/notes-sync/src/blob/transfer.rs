//! Şifreli CAS Blob aktarım istemcisi (`transfer`).
//!
//! Bu modül, yerel `BlobStore` ile entegre çalışarak şifrelenmiş medya ve dosya eklerini
//! sunucuya yükleyen ve sunucudan indirirken BLAKE3 içerik-adresli hash bütünlüğünü
//! doğrulayan `BlobTransferClient` bileşenini sunar.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use async_trait::async_trait;
use notes_core::storage::BlobStore;
use tokio::sync::RwLock;

use crate::client::SyncClientConfig;
use crate::error::{Result, SyncError};

/// Geriye dönük uyumluluk veya tip netliği için takma ad (alias).
pub type BlobTransferError = SyncError;

/// Şifreli blob ağ taşıma katmanı trait'i.
#[async_trait]
pub trait BlobTransport: Send + Sync {
    /// Şifreli blob içeriğini sunucuya iletir.
    async fn put_blob(&self, blob_hash: &str, payload: &[u8]) -> Result<()>;

    /// Şifreli blob içeriğini sunucudan indirir.
    async fn get_blob(&self, blob_hash: &str) -> Result<Vec<u8>>;

    /// Blob'un sunucuda mevcut olup olmadığını denetler.
    async fn has_blob(&self, blob_hash: &str) -> Result<bool>;
}

/// `reqwest` tabanlı gerçek HTTP blob taşıyıcısı.
#[derive(Debug, Clone)]
pub struct ReqwestBlobTransport {
    config: SyncClientConfig,
    client: reqwest::Client,
}

impl ReqwestBlobTransport {
    /// Yapılandırmadan yeni bir `ReqwestBlobTransport` oluşturur.
    pub fn new(config: SyncClientConfig) -> Result<Self> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_millis(config.timeout_ms))
            .build()?;

        Ok(Self { config, client })
    }

    /// Önceden özelleştirilmiş `reqwest::Client` ile taşıyıcı oluşturur.
    pub fn with_client(config: SyncClientConfig, client: reqwest::Client) -> Self {
        Self { config, client }
    }

    /// İstek oluşturucuya X-Device-Id, User-Agent ve tanımlıysa Bearer auth ekler.
    pub fn prepare_headers(&self, req: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        let mut builder = req
            .header("X-Device-Id", &self.config.device_id)
            .header("User-Agent", format!("notes-sync/{}", env!("CARGO_PKG_VERSION")));

        if let Some(token) = &self.config.auth_token {
            builder = builder.bearer_auth(token);
        }

        builder
    }
}

#[async_trait]
impl BlobTransport for ReqwestBlobTransport {
    async fn put_blob(&self, blob_hash: &str, payload: &[u8]) -> Result<()> {
        let url = format!("{}/api/v1/blobs/{}", self.config.server_url.trim_end_matches('/'), blob_hash);
        let req = self.client.put(&url)
            .header("Content-Type", "application/octet-stream")
            .body(payload.to_vec());
        let req = self.prepare_headers(req);

        let response = req.send().await?;
        let status = response.status();

        if status.is_success() {
            Ok(())
        } else {
            let message = response.text().await.unwrap_or_else(|_| "Bilinmeyen sunucu hatası".to_string());
            Err(SyncError::Server {
                status: status.as_u16(),
                message,
            })
        }
    }

    async fn get_blob(&self, blob_hash: &str) -> Result<Vec<u8>> {
        let url = format!("{}/api/v1/blobs/{}", self.config.server_url.trim_end_matches('/'), blob_hash);
        let req = self.client.get(&url);
        let req = self.prepare_headers(req);

        let response = req.send().await?;
        let status = response.status();

        if status.is_success() {
            let bytes = response.bytes().await?;
            Ok(bytes.to_vec())
        } else if status == reqwest::StatusCode::NOT_FOUND {
            Err(SyncError::NotFound(blob_hash.to_string()))
        } else {
            let message = response.text().await.unwrap_or_else(|_| "Bilinmeyen sunucu hatası".to_string());
            Err(SyncError::Server {
                status: status.as_u16(),
                message,
            })
        }
    }

    async fn has_blob(&self, blob_hash: &str) -> Result<bool> {
        let url = format!("{}/api/v1/blobs/{}", self.config.server_url.trim_end_matches('/'), blob_hash);
        let req = self.client.head(&url);
        let req = self.prepare_headers(req);

        let response = req.send().await?;
        let status = response.status();

        if status.is_success() {
            Ok(true)
        } else if status == reqwest::StatusCode::NOT_FOUND {
            Ok(false)
        } else {
            let message = response.text().await.unwrap_or_else(|_| "Bilinmeyen sunucu hatası".to_string());
            Err(SyncError::Server {
                status: status.as_u16(),
                message,
            })
        }
    }
}

/// Testler için bellek içi mock blob taşıyıcısı.
#[derive(Debug, Default, Clone)]
pub struct InMemoryBlobTransport {
    blobs: Arc<RwLock<HashMap<String, Vec<u8>>>>,
}

impl InMemoryBlobTransport {
    /// Yeni bir `InMemoryBlobTransport` örneği oluşturur.
    pub fn new() -> Self {
        Self {
            blobs: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Bellekte kayıtlı blob sayısını döndürür.
    pub async fn stored_count(&self) -> usize {
        self.blobs.read().await.len()
    }

    /// Bellekteki tüm blob verilerini temizler.
    pub async fn clear(&self) {
        self.blobs.write().await.clear();
    }
}

#[async_trait]
impl BlobTransport for InMemoryBlobTransport {
    async fn put_blob(&self, blob_hash: &str, payload: &[u8]) -> Result<()> {
        let mut store = self.blobs.write().await;
        store.insert(blob_hash.to_string(), payload.to_vec());
        Ok(())
    }

    async fn get_blob(&self, blob_hash: &str) -> Result<Vec<u8>> {
        let store = self.blobs.read().await;
        match store.get(blob_hash) {
            Some(data) => Ok(data.clone()),
            None => Err(SyncError::NotFound(blob_hash.to_string())),
        }
    }

    async fn has_blob(&self, blob_hash: &str) -> Result<bool> {
        let store = self.blobs.read().await;
        Ok(store.contains_key(blob_hash))
    }
}

/// Yerel `BlobStore` ile senkronizasyon sunucusu arasında güvenli blob transfer yöneticisi.
pub struct BlobTransferClient<T: BlobTransport = ReqwestBlobTransport> {
    blob_store: BlobStore,
    transport: T,
}

impl<T: BlobTransport> BlobTransferClient<T> {
    /// Verilen yerel `BlobStore` ve taşıyıcı ile yeni bir aktarım istemcisi oluşturur.
    pub fn new(blob_store: BlobStore, transport: T) -> Self {
        Self {
            blob_store,
            transport,
        }
    }

    /// İstemcinin bağlı olduğu yerel `BlobStore` referansı.
    pub fn blob_store(&self) -> &BlobStore {
        &self.blob_store
    }

    /// İstemcinin kullandığı ağ taşıyıcısı referansı.
    pub fn transport(&self) -> &T {
        &self.transport
    }

    /// Yerel `BlobStore`'daki şifreli blob'u sunucuya yükler.
    ///
    /// İşlem adımları:
    /// 1. Yerel depodan şifreli veri okunur (`read_raw_encrypted`).
    /// 2. Verinin BLAKE3 hash'i doğrulanır.
    /// 3. Şifreli içerik ağ taşıyıcısı üzerinden sunucuya iletilir (`put_blob`).
    pub async fn upload_encrypted_blob(&self, blob_hash: &str) -> Result<()> {
        let payload = self.blob_store.read_raw_encrypted(blob_hash)?;

        let computed_hash = blake3::hash(&payload).to_hex().to_string();
        if computed_hash != blob_hash {
            return Err(SyncError::HashMismatch {
                expected: blob_hash.to_string(),
                actual: computed_hash,
            });
        }

        self.transport.put_blob(blob_hash, &payload).await?;
        Ok(())
    }

    /// Şifreli blob'u sunucudan indirir, BLAKE3 bütünlüğünü doğrular ve yerel `BlobStore`'a kaydeder.
    ///
    /// İşlem adımları:
    /// 1. Ağ taşıyıcısından veri indirilir (`get_blob`).
    /// 2. İndirilen verinin BLAKE3 hash'i beklenen `blob_hash` ile karşılaştırılır (Sıfır-Bilgi Bütünlük Güvencesi).
    /// 3. Doğrulanmış şifreli veri yerel depoya kaydedilir (`save_raw_encrypted`).
    /// 4. Doğrulanmış şifreli bayt dizisi döndürülür.
    pub async fn download_encrypted_blob(&self, blob_hash: &str) -> Result<Vec<u8>> {
        let payload = self.transport.get_blob(blob_hash).await?;

        let computed_hash = blake3::hash(&payload).to_hex().to_string();
        if computed_hash != blob_hash {
            return Err(SyncError::HashMismatch {
                expected: blob_hash.to_string(),
                actual: computed_hash,
            });
        }

        self.blob_store.save_raw_encrypted(blob_hash, &payload)?;
        Ok(payload)
    }

    /// Blob'un sunucuda mevcut olup olmadığını sorgular.
    pub async fn has_remote_blob(&self, blob_hash: &str) -> Result<bool> {
        self.transport.has_blob(blob_hash).await
    }
}

impl BlobTransferClient<ReqwestBlobTransport> {
    /// `SyncClientConfig` kullanarak `ReqwestBlobTransport` tabanlı bir istemci oluşturur.
    pub fn with_reqwest(blob_store: BlobStore, config: SyncClientConfig) -> Result<Self> {
        let transport = ReqwestBlobTransport::new(config)?;
        Ok(Self::new(blob_store, transport))
    }
}

impl BlobTransferClient<InMemoryBlobTransport> {
    /// Testler için bellek içi taşıyıcıya sahip bir `BlobTransferClient` oluşturur.
    pub fn in_memory(blob_store: BlobStore) -> Self {
        Self::new(blob_store, InMemoryBlobTransport::new())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use uuid::Uuid;

    fn temp_test_dir(label: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("notes_blob_test_{}_{}", label, Uuid::new_v4()));
        let _ = fs::create_dir_all(&dir);
        dir
    }

    #[tokio::test]
    async fn test_blob_transfer_upload_and_download_roundtrip() {
        let dir1 = temp_test_dir("source");
        let dir2 = temp_test_dir("dest");

        let store1 = BlobStore::new(&dir1).unwrap();
        let store2 = BlobStore::new(&dir2).unwrap();

        let transport = InMemoryBlobTransport::new();
        let client1 = BlobTransferClient::new(store1.clone(), transport.clone());
        let client2 = BlobTransferClient::new(store2.clone(), transport.clone());

        let test_dek = [42u8; 32];
        let raw_data = b"Cok gizli notlar ve gorsel veriler!";

        // 1. store1'e şifreli blob yaz
        let blob_hash = store1.save(raw_data, &test_dek).unwrap();
        assert!(store1.has_blob(&blob_hash));
        assert!(!store2.has_blob(&blob_hash));

        // 2. client1 ile sunucuya (transport) yükle
        client1.upload_encrypted_blob(&blob_hash).await.unwrap();
        assert!(client1.has_remote_blob(&blob_hash).await.unwrap());
        assert_eq!(transport.stored_count().await, 1);

        // 3. client2 ile sunucudan indir ve doğrula
        let downloaded = client2.download_encrypted_blob(&blob_hash).await.unwrap();
        assert!(!downloaded.is_empty());
        assert!(store2.has_blob(&blob_hash));

        // 4. store2'de şifre çözümü yap ve ham veriyi teyit et
        let decrypted = store2.read(&blob_hash, &test_dek).unwrap();
        assert_eq!(decrypted, raw_data);

        // Temizlik
        let _ = fs::remove_dir_all(dir1);
        let _ = fs::remove_dir_all(dir2);
    }

    #[tokio::test]
    async fn test_blob_transfer_hash_mismatch_security() {
        let dir = temp_test_dir("mismatch");
        let store = BlobStore::new(&dir).unwrap();

        // Bozuk veri döndüren mock taşıyıcı
        #[derive(Debug, Clone)]
        struct CorruptedTransport;

        #[async_trait]
        impl BlobTransport for CorruptedTransport {
            async fn put_blob(&self, _hash: &str, _payload: &[u8]) -> Result<()> {
                Ok(())
            }
            async fn get_blob(&self, _hash: &str) -> Result<Vec<u8>> {
                // Beklenen hash ile uyuşmayacak sahte baytlar
                Ok(b"Bu veri manipule edilmis veya bozulmus!".to_vec())
            }
            async fn has_blob(&self, _hash: &str) -> Result<bool> {
                Ok(true)
            }
        }

        let client = BlobTransferClient::new(store.clone(), CorruptedTransport);
        let fake_target_hash = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";

        let result = client.download_encrypted_blob(fake_target_hash).await;
        assert!(result.is_err());

        match result {
            Err(SyncError::HashMismatch { expected, actual }) => {
                assert_eq!(expected, fake_target_hash);
                assert_ne!(actual, fake_target_hash);
            }
            other => panic!("Beklenmeyen hata türü: {:?}", other),
        }

        // Bozuk verinin diske kaydedilmediğini doğrula
        assert!(!store.has_blob(fake_target_hash));

        let _ = fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn test_blob_transfer_not_found() {
        let dir = temp_test_dir("notfound");
        let store = BlobStore::new(&dir).unwrap();
        let client = BlobTransferClient::in_memory(store);

        let missing_hash = "0000000000000000000000000000000000000000000000000000000000000000";
        let res = client.download_encrypted_blob(missing_hash).await;

        match res {
            Err(SyncError::NotFound(h)) => assert_eq!(h, missing_hash),
            other => panic!("Beklenmeyen sonuç: {:?}", other),
        }

        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn test_reqwest_blob_transport_creation() {
        let config = SyncClientConfig::default();
        let transport = ReqwestBlobTransport::new(config);
        assert!(transport.is_ok());
    }

    #[test]
    fn test_reqwest_blob_transport_headers() {
        let config = SyncClientConfig::new("https://sync.example.com", "device-xyz-987")
            .with_auth_token("secret-blob-token");
        let transport = ReqwestBlobTransport::new(config).unwrap();

        let req_builder = transport.client.get("https://sync.example.com/api/v1/blobs/test");
        let prepared = transport.prepare_headers(req_builder);
        let req = prepared.build().unwrap();

        let device_header = req.headers().get("X-Device-Id").unwrap();
        assert_eq!(device_header.to_str().unwrap(), "device-xyz-987");

        let auth_header = req.headers().get("Authorization").unwrap();
        assert_eq!(auth_header.to_str().unwrap(), "Bearer secret-blob-token");
    }
}
