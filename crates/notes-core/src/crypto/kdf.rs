use argon2::{Algorithm, Argon2, Params, Version};
use hkdf::Hkdf;
use rand::{rngs::OsRng, RngCore};
use sha2::Sha256;
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::error::{CoreError, Result};

/// Argon2id varsayılan bellek maliyeti: 64 MB (65536 KiB)
pub const ARGON2_M_COST_DEFAULT: u32 = 65536;
/// Argon2id varsayılan zaman maliyeti: 3 iterasyon
pub const ARGON2_T_COST_DEFAULT: u32 = 3;
/// Argon2id varsayılan paralellik: 4 şerit/iş parçacığı
pub const ARGON2_P_COST_DEFAULT: u32 = 4;
/// Tuz uzunluğu (32 bayt CSPRNG)
pub const SALT_SIZE: usize = 32;
/// Anahtar boyutu (32 bayt / 256-bit)
pub const KEY_SIZE: usize = 32;
/// CAS Blob Nonce boyutu (24 bayt / 192-bit)
pub const BLOB_NONCE_SIZE: usize = 24;

/// Argon2id ile ana paroladan türetilen 256-bit Master Key.
/// Bellek güvenliği için `Zeroize` ve `ZeroizeOnDrop` uygular.
#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct MasterKey([u8; KEY_SIZE]);

impl MasterKey {
    /// Ham bayt dizisinden yeni `MasterKey` üretir.
    pub fn from_bytes(bytes: [u8; KEY_SIZE]) -> Self {
        Self(bytes)
    }

    /// Anahtar baytlarına değişmez referans döndürür.
    pub fn as_bytes(&self) -> &[u8; KEY_SIZE] {
        &self.0
    }

    /// Anahtar baytlarının bir kopyasını döndürür.
    pub fn to_bytes(&self) -> [u8; KEY_SIZE] {
        self.0
    }
}

impl std::fmt::Debug for MasterKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "MasterKey([REDACTED])")
    }
}

/// HKDF-SHA256 ile MasterKey'den türetilen Key Encryption Key (KEK - 256-bit).
/// DEK zarflamada ve yerel Keychain saklamada kullanılır.
#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct KeyEncryptionKey([u8; KEY_SIZE]);

impl KeyEncryptionKey {
    pub fn from_bytes(bytes: [u8; KEY_SIZE]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; KEY_SIZE] {
        &self.0
    }

    pub fn to_bytes(&self) -> [u8; KEY_SIZE] {
        self.0
    }
}

impl std::fmt::Debug for KeyEncryptionKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "KeyEncryptionKey([REDACTED])")
    }
}

/// HKDF-SHA256 ile MasterKey'den türetilen Authentication Key (AuthKey - 256-bit).
/// Kör sunucu kimlik doğrulamasında kullanılır.
#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct AuthenticationKey([u8; KEY_SIZE]);

impl AuthenticationKey {
    pub fn from_bytes(bytes: [u8; KEY_SIZE]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; KEY_SIZE] {
        &self.0
    }

    pub fn to_bytes(&self) -> [u8; KEY_SIZE] {
        self.0
    }
}

impl std::fmt::Debug for AuthenticationKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "AuthenticationKey([REDACTED])")
    }
}

/// Her çalışma alanı için rastgele üretilen Data Encryption Key (DEK - 256-bit).
/// Sayfa bloklarını, CRDT güncellemelerini ve blob eklerini şifreler.
#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct DataEncryptionKey([u8; KEY_SIZE]);

impl DataEncryptionKey {
    /// CSPRNG (`OsRng`) ile yeni rastgele bir DEK oluşturur.
    pub fn generate() -> Self {
        let mut bytes = [0u8; KEY_SIZE];
        OsRng.fill_bytes(&mut bytes);
        Self(bytes)
    }

    pub fn from_bytes(bytes: [u8; KEY_SIZE]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; KEY_SIZE] {
        &self.0
    }

    pub fn to_bytes(&self) -> [u8; KEY_SIZE] {
        self.0
    }
}

impl std::fmt::Debug for DataEncryptionKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "DataEncryptionKey([REDACTED])")
    }
}

/// CSPRNG kullanarak 32 baytlık rastgele bir tuz (salt) üretir.
pub fn generate_salt() -> [u8; SALT_SIZE] {
    let mut salt = [0u8; SALT_SIZE];
    OsRng.fill_bytes(&mut salt);
    salt
}

/// Özel maliyet parametreleri ile Argon2id kullanarak paroladan MasterKey türetir.
/// Testlerde hızlı çalıştırma veya gelecekte parametre yükseltmeleri için kullanılır.
pub fn derive_master_key_with_params(
    password: &str,
    salt: &[u8],
    m_cost: u32,
    t_cost: u32,
    p_cost: u32,
) -> Result<MasterKey> {
    if salt.len() < 16 {
        return Err(CoreError::Crypto(
            "Tuz uzunluğu en az 16 bayt olmalıdır".into(),
        ));
    }

    let params = Params::new(m_cost, t_cost, p_cost, Some(KEY_SIZE))
        .map_err(|e| CoreError::Crypto(format!("Geçersiz Argon2 parametreleri: {e}")))?;

    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut out = [0u8; KEY_SIZE];

    argon2
        .hash_password_into(password.as_bytes(), salt, &mut out)
        .map_err(|e| CoreError::Crypto(format!("Argon2id anahtar türetme hatası: {e}")))?;

    Ok(MasterKey::from_bytes(out))
}

/// Varsayılan mimari parametreleriyle (`m=64MB`, `t=3`, `p=4`, 32B salt) MasterKey türetir.
pub fn derive_master_key(password: &str, salt: &[u8; SALT_SIZE]) -> Result<MasterKey> {
    derive_master_key_with_params(
        password,
        salt,
        ARGON2_M_COST_DEFAULT,
        ARGON2_T_COST_DEFAULT,
        ARGON2_P_COST_DEFAULT,
    )
}

/// RFC 5869 HKDF-SHA256 ile MasterKey'den KEK (`info="notes-kek-v1"`) türetir.
pub fn derive_kek(master_key: &MasterKey) -> Result<KeyEncryptionKey> {
    let hk = Hkdf::<Sha256>::new(None, master_key.as_bytes());
    let mut okm = [0u8; KEY_SIZE];
    hk.expand(b"notes-kek-v1", &mut okm)
        .map_err(|e| CoreError::Crypto(format!("HKDF KEK türetme hatası: {e}")))?;
    Ok(KeyEncryptionKey::from_bytes(okm))
}

/// RFC 5869 HKDF-SHA256 ile MasterKey'den AuthKey (`info="notes-auth-v1"`) türetir.
pub fn derive_auth_key(master_key: &MasterKey) -> Result<AuthenticationKey> {
    let hk = Hkdf::<Sha256>::new(None, master_key.as_bytes());
    let mut okm = [0u8; KEY_SIZE];
    hk.expand(b"notes-auth-v1", &mut okm)
        .map_err(|e| CoreError::Crypto(format!("HKDF AuthKey türetme hatası: {e}")))?;
    Ok(AuthenticationKey::from_bytes(okm))
}

/// CAS içerik-adresli depolama için deterministik 24-bayt nonce türetir.
/// `nonce = HKDF-SHA256(DEK, salt=raw_hash, info="notes-blob-nonce-v1")[0..24]`
pub fn derive_blob_nonce(
    dek: &DataEncryptionKey,
    raw_blake3_hash: &[u8; 32],
) -> Result<[u8; BLOB_NONCE_SIZE]> {
    let hk = Hkdf::<Sha256>::new(Some(raw_blake3_hash), dek.as_bytes());
    let mut okm = [0u8; BLOB_NONCE_SIZE];
    hk.expand(b"notes-blob-nonce-v1", &mut okm)
        .map_err(|e| CoreError::Crypto(format!("HKDF blob nonce türetme hatası: {e}")))?;
    Ok(okm)
}
