use std::fs;
use std::path::{Path, PathBuf};
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};

use crate::crypto::{derive_blob_nonce, DataEncryptionKey, BLOB_NONCE_SIZE};
use crate::error::{CoreError, Result};

const NONCE_LEN: usize = BLOB_NONCE_SIZE;
const TAG_LEN: usize = 16;

/// İçerik-adresli ve deterministik tekilleştirmeli (CAS) şifreli medya blob depolama motoru.
#[derive(Debug, Clone)]
pub struct BlobStore {
    blobs_dir: PathBuf,
}

impl BlobStore {
    /// Belirtilen kök dizin altında `blobs/` klasörünü yöneten bir `BlobStore` oluşturur.
    pub fn new<P: AsRef<Path>>(base_dir: P) -> Result<Self> {
        let blobs_dir = base_dir.as_ref().join("blobs");
        fs::create_dir_all(&blobs_dir)
            .map_err(|e| CoreError::Database(format!("Blobs dizini oluşturulamadı: {}", e)))?;

        Ok(Self { blobs_dir })
    }

    /// Ham veriyi DEK ile şifreler, içerik-adresli hash'ini üretir ve `blobs/<blob_hash>.enc` olarak saklar.
    ///
    /// Algoritma (docs/ARCHITECTURE.md Bölüm 4.5):
    /// 1. `raw_hash = blake3(raw_bytes)`
    /// 2. `nonce = HKDF-SHA256(DEK, salt=raw_hash, info="notes-blob-nonce-v1")[0..24]`
    /// 3. `ciphertext = XChaCha20-Poly1305(raw_bytes, DEK, nonce)`
    /// 4. `payload = nonce || ciphertext`
    /// 5. `blob_hash = blake3(payload)`
    /// 6. `blobs/<blob_hash>.enc` diske yazılır.
    pub fn save(&self, raw_bytes: &[u8], dek: &[u8; 32]) -> Result<String> {
        // 1. Ham dosya blake3 özeti
        let raw_hash = blake3::hash(raw_bytes);

        // 2. Sentetik deterministik 24-bayt nonce türetimi (crypto motoru)
        let dek_key = DataEncryptionKey::from_bytes(*dek);
        let nonce_bytes = derive_blob_nonce(&dek_key, raw_hash.as_bytes())?;

        // 3. Simetrik şifreleme (XChaCha20-Poly1305)
        let cipher = XChaCha20Poly1305::new(dek.into());
        let nonce = XNonce::from_slice(&nonce_bytes);
        let ciphertext = cipher
            .encrypt(nonce, raw_bytes)
            .map_err(|e| CoreError::Crypto(format!("Blob şifreleme başarısız: {}", e)))?;

        // 4. Standart zarf formatı: nonce (24B) || ciphertext (tag dahil)
        let mut payload = Vec::with_capacity(NONCE_LEN + ciphertext.len());
        payload.extend_from_slice(&nonce_bytes);
        payload.extend_from_slice(&ciphertext);

        // 5. İçerik-adresli hash hesabı
        let blob_hash = blake3::hash(&payload).to_hex().to_string();

        // 6. Dosyaya yazma
        let file_path = self.blob_path(&blob_hash);
        fs::write(&file_path, &payload)
            .map_err(|e| CoreError::Database(format!("Blob diske yazılamadı: {}", e)))?;

        Ok(blob_hash)
    }

    /// Belirtilen `blob_hash` içeriğini doğrular, deşifre eder ve açık bayt dizisini döndürür.
    ///
    /// Doğrulama adımları:
    /// - Diskteki dosyanın blake3 özeti `blob_hash` ile uyuşmalıdır.
    /// - Nonce ve DEK ile Poly1305 tag doğrulanarak şifre çözülür.
    /// - Açılan ham veriden türetilen sentetik nonce kontrol edilir.
    pub fn read(&self, blob_hash: &str, dek: &[u8; 32]) -> Result<Vec<u8>> {
        let file_path = self.blob_path(blob_hash);
        if !file_path.exists() {
            return Err(CoreError::NotFound(format!("Blob bulunamadı: {}", blob_hash)));
        }

        let payload = fs::read(&file_path)
            .map_err(|e| CoreError::Database(format!("Blob okunamadı: {}", e)))?;

        // 1. Hash Bütünlük Doğrulaması (İçerik-adres kontrolü)
        let actual_hash = blake3::hash(&payload).to_hex().to_string();
        if actual_hash != blob_hash {
            return Err(CoreError::Crypto(format!(
                "Blob hash uyuşmazlığı / bozuk veri! Beklenen: {}, Gerçekleşen: {}",
                blob_hash, actual_hash
            )));
        }

        // 2. Minimum boyut kontrolü (24 bayt nonce + 16 bayt auth tag)
        if payload.len() < NONCE_LEN + TAG_LEN {
            return Err(CoreError::Crypto("Geçersiz blob formatı (yetersiz bayt boyutu)".into()));
        }

        let (nonce_bytes, ciphertext) = payload.split_at(NONCE_LEN);
        let nonce = XNonce::from_slice(nonce_bytes);
        let cipher = XChaCha20Poly1305::new(dek.into());

        // 3. Deşifre etme (Poly1305 MAC doğrulaması dahildir)
        let raw_bytes = cipher
            .decrypt(nonce, ciphertext)
            .map_err(|_| CoreError::Crypto("Blob deşifre edilemedi (yanlış DEK veya bozuk içerik)".into()))?;

        // 4. Sentetik Nonce Bütünlük Doğrulaması (Çift katmanlı denetim)
        let raw_hash = blake3::hash(&raw_bytes);
        let dek_key = DataEncryptionKey::from_bytes(*dek);
        let expected_nonce = derive_blob_nonce(&dek_key, raw_hash.as_bytes())?;

        if expected_nonce != nonce_bytes {
            return Err(CoreError::Crypto("Sentetik nonce uyuşmazlığı (veri manipülasyonu)".into()));
        }

        Ok(raw_bytes)
    }

    /// Şifreli ham blob verisini doğrudan saklar (sunucudan indirilen hazır bloblar için).
    pub fn save_raw_encrypted(&self, blob_hash: &str, payload: &[u8]) -> Result<()> {
        let actual_hash = blake3::hash(payload).to_hex().to_string();
        if actual_hash != blob_hash {
            return Err(CoreError::Crypto(format!(
                "Ham blob hash uyuşmazlığı! Beklenen: {}, Gerçekleşen: {}",
                blob_hash, actual_hash
            )));
        }

        let file_path = self.blob_path(blob_hash);
        fs::write(&file_path, payload)
            .map_err(|e| CoreError::Database(format!("Ham blob diske yazılamadı: {}", e)))?;
        Ok(())
    }

    /// Şifreli ham blob baytlarını döndürür (sunucuya yükleme veya aktarma için).
    pub fn read_raw_encrypted(&self, blob_hash: &str) -> Result<Vec<u8>> {
        let file_path = self.blob_path(blob_hash);
        if !file_path.exists() {
            return Err(CoreError::NotFound(format!("Blob bulunamadı: {}", blob_hash)));
        }

        let payload = fs::read(&file_path)
            .map_err(|e| CoreError::Database(format!("Blob okunamadı: {}", e)))?;

        let actual_hash = blake3::hash(&payload).to_hex().to_string();
        if actual_hash != blob_hash {
            return Err(CoreError::Crypto("Blob hash uyuşmazlığı".into()));
        }

        Ok(payload)
    }

    /// Bloğun yerel depoda bulunup bulunmadığını kontrol eder.
    pub fn has_blob(&self, blob_hash: &str) -> bool {
        self.blob_path(blob_hash).exists()
    }

    /// Bloğu diskten siler.
    pub fn delete_blob(&self, blob_hash: &str) -> Result<()> {
        let file_path = self.blob_path(blob_hash);
        if file_path.exists() {
            fs::remove_file(&file_path)
                .map_err(|e| CoreError::Database(format!("Blob silinemedi: {}", e)))?;
        }
        Ok(())
    }

    /// Bloğun mutlak dosya yolunu üretir: `<blobs_dir>/<blob_hash>.enc`.
    pub fn blob_path(&self, blob_hash: &str) -> PathBuf {
        self.blobs_dir.join(format!("{}.enc", blob_hash))
    }

    /// Depodaki tüm blob hash'lerini listeler.
    pub fn list_blobs(&self) -> Result<Vec<String>> {
        let entries = fs::read_dir(&self.blobs_dir)
            .map_err(|e| CoreError::Database(format!("Blobs dizini okunamadı: {}", e)))?;

        let mut hashes = Vec::new();
        for entry in entries {
            let entry = entry.map_err(|e| CoreError::Database(e.to_string()))?;
            let path = entry.path();
            if path.is_file() && path.extension().and_then(|s| s.to_str()) == Some("enc") {
                if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                    hashes.push(stem.to_string());
                }
            }
        }
        Ok(hashes)
    }
}
