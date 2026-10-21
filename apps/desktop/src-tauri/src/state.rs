use std::sync::{Mutex, RwLock};
use uuid::Uuid;

use notes_core::crypto::{
    AuthenticationKey, DataEncryptionKey, KeyEncryptionKey, KeychainStore, SALT_SIZE,
};
use notes_core::error::CoreError;
use notes_core::storage::{BlobStore, LocalStore};

/// Masaüstü IPC ve servis hata tipi.
#[derive(Debug, thiserror::Error, serde::Serialize, serde::Deserialize, Clone, PartialEq, Eq)]
pub enum AppError {
    #[error("Kasa kilitli. Lütfen önce parolanızla kilidi açın.")]
    VaultLocked,

    #[error("Kasa zaten açık durumda.")]
    VaultAlreadyUnlocked,

    #[error("Kasa henüz başlatılmamış. Lütfen yeni bir çalışma alanı oluşturun.")]
    VaultNotInitialized,

    #[error("Geçersiz parola veya bozuk anahtar zarfı.")]
    InvalidPassword,

    #[error("Keychain hatası: {0}")]
    KeychainError(String),

    #[error("Veritabanı hatası: {0}")]
    DatabaseError(String),

    #[error("Kriptografi hatası: {0}")]
    CryptoError(String),

    #[error("Kayıt bulunamadı: {0}")]
    NotFound(String),

    #[error("Doğrulama hatası: {0}")]
    ValidationError(String),

    #[error("Dahili hata: {0}")]
    Internal(String),
}

impl From<CoreError> for AppError {
    fn from(err: CoreError) -> Self {
        match err {
            CoreError::Crypto(msg) => AppError::CryptoError(msg),
            CoreError::Database(msg) => AppError::DatabaseError(msg),
            CoreError::NotFound(msg) => AppError::NotFound(msg),
            CoreError::Validation(msg) => AppError::ValidationError(msg),
            CoreError::Serialization(msg) => AppError::Internal(msg),
            CoreError::InvalidBlockType(msg) => AppError::ValidationError(msg),
            CoreError::InvalidProperty(msg) => AppError::ValidationError(msg),
            CoreError::InvalidTag(msg) => AppError::ValidationError(msg),
            CoreError::InvalidState(msg) => AppError::Internal(msg),
            CoreError::Internal(msg) => AppError::Internal(msg),
        }
    }
}

/// Kasa kilit durumu modeli.
#[derive(Debug, Clone)]
pub enum VaultLockState {
    Locked,
    Unlocked {
        dek: DataEncryptionKey,
        kek: KeyEncryptionKey,
        auth_key: AuthenticationKey,
        workspace_id: Uuid,
    },
}

/// Masaüstü uygulamasının paylaşımlı çalışma zamanı durumu.
pub struct DesktopAppState {
    /// SQLite yerel veri deposu (thread-safe Mutex sarmalayıcı)
    pub store: Mutex<LocalStore>,
    /// İçerik-adresli dosya/ek deposu (CAS Blob Store)
    pub blob_store: BlobStore,
    /// OS Keychain veya InMemory Keychain soyutlaması
    pub keychain: Box<dyn KeychainStore>,
    /// Güncel kasa kilit ve oturum anahtarları durumu
    pub lock_state: RwLock<VaultLockState>,
    /// Bellekte veya oturum süresince tutulan KDF tuzu
    pub salt: RwLock<Option<[u8; SALT_SIZE]>>,
}

impl DesktopAppState {
    /// Yeni bir `DesktopAppState` oluşturur.
    pub fn new(
        store: LocalStore,
        blob_store: BlobStore,
        keychain: Box<dyn KeychainStore>,
    ) -> Self {
        Self {
            store: Mutex::new(store),
            blob_store,
            keychain,
            lock_state: RwLock::new(VaultLockState::Locked),
            salt: RwLock::new(None),
        }
    }

    /// Testler için in-memory SQLite ve geçici blob deposu ile yeni state oluşturur.
    pub fn new_in_memory(blob_dir: &std::path::Path) -> Result<Self, AppError> {
        let store = LocalStore::open_in_memory()?;
        let blob_store = BlobStore::new(blob_dir)?;
        let keychain = Box::new(notes_core::crypto::InMemoryKeychain::new());
        Ok(Self::new(store, blob_store, keychain))
    }

    /// Kasanın kilitli olup olmadığını döndürür.
    pub fn is_locked(&self) -> bool {
        let guard = self.lock_state.read().expect("Lock state okunamadı");
        matches!(*guard, VaultLockState::Locked)
    }

    /// Kilit açık ise aktif çalışma alanı UUID'sini döndürür.
    pub fn get_workspace_id(&self) -> Result<Uuid, AppError> {
        let guard = self.lock_state.read().expect("Lock state okunamadı");
        match &*guard {
            VaultLockState::Unlocked { workspace_id, .. } => Ok(*workspace_id),
            VaultLockState::Locked => Err(AppError::VaultLocked),
        }
    }

    /// Kasanın açık olduğunu doğrular ve oturum anahtarlarını klonlayarak döndürür.
    pub fn require_unlocked(
        &self,
    ) -> Result<(DataEncryptionKey, KeyEncryptionKey, AuthenticationKey, Uuid), AppError> {
        let guard = self.lock_state.read().expect("Lock state okunamadı");
        match &*guard {
            VaultLockState::Unlocked {
                dek,
                kek,
                auth_key,
                workspace_id,
            } => Ok((dek.clone(), kek.clone(), auth_key.clone(), *workspace_id)),
            VaultLockState::Locked => Err(AppError::VaultLocked),
        }
    }

    /// Kasayı açık duruma getirir ve oturum anahtarlarını yükler.
    pub fn set_unlocked(
        &self,
        dek: DataEncryptionKey,
        kek: KeyEncryptionKey,
        auth_key: AuthenticationKey,
        workspace_id: Uuid,
    ) {
        let mut guard = self.lock_state.write().expect("Lock state yazılamadı");
        *guard = VaultLockState::Unlocked {
            dek,
            kek,
            auth_key,
            workspace_id,
        };
    }

    /// Kasayı kilitler. Bellekteki oturum anahtarları `Zeroize` edilerek düşürülür.
    pub fn set_locked(&self) {
        let mut guard = self.lock_state.write().expect("Lock state yazılamadı");
        *guard = VaultLockState::Locked;
    }
}
