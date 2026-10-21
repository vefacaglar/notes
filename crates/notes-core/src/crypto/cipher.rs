use chacha20poly1305::{
    aead::{Aead, KeyInit, Payload},
    Key, XChaCha20Poly1305, XNonce,
};
use rand::{rngs::OsRng, RngCore};

use crate::error::{CoreError, Result};

/// XChaCha20-Poly1305 Nonce uzunluğu (24 bayt / 192-bit)
pub const NONCE_SIZE: usize = 24;
/// Simetrik anahtar uzunluğu (32 bayt / 256-bit)
pub const KEY_SIZE: usize = 32;
/// Poly1305 kimlik doğrulama etiketi boyutu (16 bayt / 128-bit)
pub const TAG_SIZE: usize = 16;

/// CSPRNG (`OsRng`) ile rastgele 24-baytlık XChaCha20 nonce üretir.
pub fn generate_nonce() -> [u8; NONCE_SIZE] {
    let mut nonce = [0u8; NONCE_SIZE];
    OsRng.fill_bytes(&mut nonce);
    nonce
}

/// AAD (Associated Data) desteğiyle XChaCha20-Poly1305 AEAD şifreleme yapar.
/// Çıktı: `ciphertext + tag` (Poly1305 MAC etiketi sona eklenir).
pub fn encrypt_aead(
    key: &[u8; KEY_SIZE],
    nonce: &[u8; NONCE_SIZE],
    plaintext: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>> {
    let cipher = XChaCha20Poly1305::new(Key::from_slice(key));
    let x_nonce = XNonce::from_slice(nonce);

    cipher
        .encrypt(
            x_nonce,
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|e| CoreError::Crypto(format!("XChaCha20-Poly1305 şifreleme hatası: {e}")))
}

/// AAD (Associated Data) doğrulamasıyla XChaCha20-Poly1305 AEAD şifresini çözer.
/// Etiket doğrulanmazsa veya veri bozulmuşsa hata döndürür.
pub fn decrypt_aead(
    key: &[u8; KEY_SIZE],
    nonce: &[u8; NONCE_SIZE],
    ciphertext: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>> {
    let cipher = XChaCha20Poly1305::new(Key::from_slice(key));
    let x_nonce = XNonce::from_slice(nonce);

    cipher
        .decrypt(
            x_nonce,
            Payload {
                msg: ciphertext,
                aad,
            },
        )
        .map_err(|e| CoreError::Crypto(format!("XChaCha20-Poly1305 deşifreleme hatası (bütünlük/etiket doğrulaması başarısız): {e}")))
}

/// Ek veri (AAD) olmaksızın XChaCha20-Poly1305 ile şifreleme yapar.
pub fn encrypt(
    key: &[u8; KEY_SIZE],
    nonce: &[u8; NONCE_SIZE],
    plaintext: &[u8],
) -> Result<Vec<u8>> {
    encrypt_aead(key, nonce, plaintext, &[])
}

/// Ek veri (AAD) olmaksızın XChaCha20-Poly1305 ile şifre çözer.
pub fn decrypt(
    key: &[u8; KEY_SIZE],
    nonce: &[u8; NONCE_SIZE],
    ciphertext: &[u8],
) -> Result<Vec<u8>> {
    decrypt_aead(key, nonce, ciphertext, &[])
}
