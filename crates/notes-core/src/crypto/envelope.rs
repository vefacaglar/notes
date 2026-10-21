use serde::{Deserialize, Serialize};

use super::cipher::{decrypt, encrypt, generate_nonce, NONCE_SIZE};
use super::kdf::{DataEncryptionKey, KeyEncryptionKey, KEY_SIZE};
use crate::error::{CoreError, Result};

/// KEK ile şifrelenmiş ve doğrulanmış DEK zarfı.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WrappedDek {
    /// XChaCha20 için kullanılan 24 baytlık nonce
    pub nonce: [u8; NONCE_SIZE],
    /// KEK ile şifrelenmiş 32 baytlık DEK + 16 baytlık Poly1305 MAC etiketi (toplam 48 bayt)
    pub ciphertext: Vec<u8>,
}

impl WrappedDek {
    /// Yeni bir `WrappedDek` örneği oluşturur.
    pub fn new(nonce: [u8; NONCE_SIZE], ciphertext: Vec<u8>) -> Self {
        Self { nonce, ciphertext }
    }
}

/// Yeni rastgele bir çalışma alanı DEK'i üretir.
pub fn generate_dek() -> DataEncryptionKey {
    DataEncryptionKey::generate()
}

/// Verilen DEK'i, kullanıcının KEK'i ile XChaCha20-Poly1305 kullanarak mühürler / zarflar.
pub fn wrap_dek(kek: &KeyEncryptionKey, dek: &DataEncryptionKey) -> Result<WrappedDek> {
    let nonce = generate_nonce();
    let ciphertext = encrypt(kek.as_bytes(), &nonce, dek.as_bytes())?;
    Ok(WrappedDek { nonce, ciphertext })
}

/// Mühürlü DEK zarfını kullanıcının KEK'i ile çözer ve doğrular.
/// Şifre çözme veya MAC etiket doğrulaması başarısız olursa `CoreError::Crypto` döner.
pub fn unwrap_dek(kek: &KeyEncryptionKey, wrapped: &WrappedDek) -> Result<DataEncryptionKey> {
    let plaintext = decrypt(kek.as_bytes(), &wrapped.nonce, &wrapped.ciphertext)?;

    if plaintext.len() != KEY_SIZE {
        return Err(CoreError::Crypto(format!(
            "Geçersiz DEK anahtar uzunluğu: beklenen {KEY_SIZE}, alınan {}",
            plaintext.len()
        )));
    }

    let mut key_bytes = [0u8; KEY_SIZE];
    key_bytes.copy_from_slice(&plaintext);
    Ok(DataEncryptionKey::from_bytes(key_bytes))
}
