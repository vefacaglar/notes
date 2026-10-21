//! # E2EE Kriptografi Motoru
//!
//! Bu modül Notes uygulamasının uçtan uca şifreleme (Zero-Knowledge E2EE) temelini oluşturur.
//!
//! - **Argon2id:** Master Password -> 256-bit `MasterKey`
//! - **HKDF-SHA256:** `MasterKey` -> `KEK` (Key Encryption Key) ve `AuthKey` (Authentication Key)
//! - **XChaCha20-Poly1305:** 192-bit nonce ile AEAD simetrik şifreleme
//! - **Envelope Encryption:** Çalışma alanı DEK (Data Encryption Key) zarflama ve çözme
//! - **CAS Nonce Türetimi:** İçerik-adresli dosya depolama için deterministik 24B nonce
//! - **Keychain:** Donanım / macOS Keychain anahtar saklama soyutlaması

pub mod cipher;
pub mod envelope;
pub mod kdf;
pub mod keychain;

pub use cipher::{
    decrypt, decrypt_aead, encrypt, encrypt_aead, generate_nonce, KEY_SIZE, NONCE_SIZE, TAG_SIZE,
};
pub use envelope::{generate_dek, unwrap_dek, wrap_dek, WrappedDek};
pub use kdf::{
    derive_auth_key, derive_blob_nonce, derive_kek, derive_master_key,
    derive_master_key_with_params, generate_salt, AuthenticationKey, DataEncryptionKey,
    KeyEncryptionKey, MasterKey, ARGON2_M_COST_DEFAULT, ARGON2_P_COST_DEFAULT,
    ARGON2_T_COST_DEFAULT, BLOB_NONCE_SIZE, SALT_SIZE,
};
pub use keychain::{InMemoryKeychain, KeychainStore, MacOsKeychain};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_kdf_fast_params_and_hkdf() {
        let password = "SuperSecretPassword123!";
        let salt = [42u8; SALT_SIZE];

        // Testlerde hızlı çalışması için düşük maliyetli parametreler
        let master_key =
            derive_master_key_with_params(password, &salt, 64, 1, 1).expect("MasterKey türetilmeli");

        let kek = derive_kek(&master_key).expect("KEK türetilmeli");
        let auth_key = derive_auth_key(&master_key).expect("AuthKey türetilmeli");

        // KEK ve AuthKey 32 bayt olmalı ve birbirinden tamamen farklı olmalı
        assert_eq!(kek.as_bytes().len(), 32);
        assert_eq!(auth_key.as_bytes().len(), 32);
        assert_ne!(kek.as_bytes(), auth_key.as_bytes());
        assert_ne!(kek.as_bytes(), master_key.as_bytes());

        // Determinizm: Aynı parola ve tuz ile tamamen aynı anahtarlar türetilmeli
        let master_key2 =
            derive_master_key_with_params(password, &salt, 64, 1, 1).expect("MasterKey2");
        let kek2 = derive_kek(&master_key2).expect("KEK2");
        let auth_key2 = derive_auth_key(&master_key2).expect("AuthKey2");

        assert_eq!(master_key.as_bytes(), master_key2.as_bytes());
        assert_eq!(kek.as_bytes(), kek2.as_bytes());
        assert_eq!(auth_key.as_bytes(), auth_key2.as_bytes());
    }

    #[test]
    fn test_cipher_encrypt_decrypt_roundtrip() {
        let key = [7u8; KEY_SIZE];
        let nonce = generate_nonce();
        let message = b"Local-first Zero-Knowledge E2EE Not Alma Uygulamasi";

        let ciphertext = encrypt(&key, &nonce, message).expect("Şifreleme başarılı olmalı");
        assert_ne!(ciphertext, message);
        // Ciphertext uzunluğu plaintext + 16 bayt Poly1305 etiketine eşit olmalı
        assert_eq!(ciphertext.len(), message.len() + TAG_SIZE);

        let decrypted = decrypt(&key, &nonce, &ciphertext).expect("Deşifreleme başarılı olmalı");
        assert_eq!(decrypted, message);
    }

    #[test]
    fn test_cipher_aead_with_associated_data() {
        let key = [0x5au8; KEY_SIZE];
        let nonce = generate_nonce();
        let message = b"Gorev listesi ve veritabani satirlari";
        let aad = b"workspace_id:12345:doc_id:67890";

        let ciphertext =
            encrypt_aead(&key, &nonce, message, aad).expect("AEAD şifreleme başarılı olmalı");

        // Doğru AAD ile çözme
        let decrypted = decrypt_aead(&key, &nonce, &ciphertext, aad).expect("AEAD deşifre başarılı olmalı");
        assert_eq!(decrypted, message);

        // Yanlış AAD ile çözme denenirse Poly1305 MAC etiket doğrulaması başarısız olmalı
        let bad_aad = b"workspace_id:12345:doc_id:HACKED";
        let err = decrypt_aead(&key, &nonce, &ciphertext, bad_aad);
        assert!(err.is_err());
    }

    #[test]
    fn test_cipher_tamper_detection() {
        let key = [0xabu8; KEY_SIZE];
        let nonce = generate_nonce();
        let message = b"Degistirilemez kritik veri";

        let mut ciphertext = encrypt(&key, &nonce, message).expect("Şifreleme");

        // 1 baytı boz
        let last_idx = ciphertext.len() - 1;
        ciphertext[last_idx] ^= 0x01;

        let res = decrypt(&key, &nonce, &ciphertext);
        assert!(res.is_err(), "Bozuk ciphertext reddedilmeliydi");
    }

    #[test]
    fn test_envelope_wrap_and_unwrap_cycle() {
        let kek = KeyEncryptionKey::from_bytes([0x11u8; KEY_SIZE]);
        let dek = generate_dek();

        let wrapped = wrap_dek(&kek, &dek).expect("DEK sarılmalı");
        assert_eq!(wrapped.nonce.len(), NONCE_SIZE);
        assert_eq!(wrapped.ciphertext.len(), KEY_SIZE + TAG_SIZE);

        let unwrapped = unwrap_dek(&kek, &wrapped).expect("DEK açılmalı");
        assert_eq!(unwrapped.as_bytes(), dek.as_bytes());
    }

    #[test]
    fn test_envelope_unwrap_with_invalid_kek_fails() {
        let kek_valid = KeyEncryptionKey::from_bytes([0x11u8; KEY_SIZE]);
        let kek_invalid = KeyEncryptionKey::from_bytes([0x22u8; KEY_SIZE]);
        let dek = generate_dek();

        let wrapped = wrap_dek(&kek_valid, &dek).expect("DEK sarılmalı");

        let err = unwrap_dek(&kek_invalid, &wrapped);
        assert!(err.is_err(), "Yanlış KEK ile DEK açılamamalı");
    }

    #[test]
    fn test_cas_blob_deterministic_nonce() {
        let dek = generate_dek();
        let file_content_1 = b"resim-verisi-12345";
        let file_content_2 = b"farkli-resim-verisi-67890";

        let hash_1 = blake3::hash(file_content_1);
        let hash_2 = blake3::hash(file_content_2);

        let nonce_1a = derive_blob_nonce(&dek, hash_1.as_bytes()).expect("Nonce 1a");
        let nonce_1b = derive_blob_nonce(&dek, hash_1.as_bytes()).expect("Nonce 1b");
        let nonce_2 = derive_blob_nonce(&dek, hash_2.as_bytes()).expect("Nonce 2");

        // Aynı dosya hash'i ve aynı DEK ile her zaman birebir aynı nonce üretilmeli
        assert_eq!(nonce_1a, nonce_1b);

        // Farklı dosya için farklı nonce üretilmeli
        assert_ne!(nonce_1a, nonce_2);

        // Farklı DEK ile aynı dosya için farklı nonce üretilmeli
        let dek_other = generate_dek();
        let nonce_other_dek =
            derive_blob_nonce(&dek_other, hash_1.as_bytes()).expect("Nonce other DEK");
        assert_ne!(nonce_1a, nonce_other_dek);
    }

    #[test]
    fn test_in_memory_keychain() {
        let keychain = InMemoryKeychain::new();
        let service = "notes-app";
        let account = "master-kek";
        let key_data = vec![1, 2, 3, 4, 5, 42];

        // Başlangıçta kayıt yok
        assert_eq!(keychain.get_key(service, account).unwrap(), None);

        // Kaydet
        keychain.set_key(service, account, &key_data).unwrap();
        assert_eq!(
            keychain.get_key(service, account).unwrap(),
            Some(key_data.clone())
        );

        // Sil
        keychain.delete_key(service, account).unwrap();
        assert_eq!(keychain.get_key(service, account).unwrap(), None);
    }

    #[test]
    fn test_redacted_debug_formatting() {
        let mk = MasterKey::from_bytes([0xaa; KEY_SIZE]);
        let kek = KeyEncryptionKey::from_bytes([0xbb; KEY_SIZE]);
        let dek = DataEncryptionKey::from_bytes([0xcc; KEY_SIZE]);
        let auth = AuthenticationKey::from_bytes([0xdd; KEY_SIZE]);

        assert_eq!(format!("{mk:?}"), "MasterKey([REDACTED])");
        assert_eq!(format!("{kek:?}"), "KeyEncryptionKey([REDACTED])");
        assert_eq!(format!("{dek:?}"), "DataEncryptionKey([REDACTED])");
        assert_eq!(format!("{auth:?}"), "AuthenticationKey([REDACTED])");
    }
}
