use serde::{Deserialize, Serialize};
use uuid::Uuid;

use notes_core::crypto::{
    derive_auth_key, derive_kek, derive_master_key, derive_master_key_with_params,
    generate_dek, generate_salt, unwrap_dek, wrap_dek, AuthenticationKey,
    KeyEncryptionKey, WrappedDek, KEY_SIZE, NONCE_SIZE,
};
use notes_core::search::clear_all_index;
use notes_core::storage::WorkspaceRecord;

use crate::state::{AppError, DesktopAppState};

pub const KEYCHAIN_SERVICE: &str = "notes-desktop-app";
pub const ACCOUNT_SALT: &str = "vault-salt";
pub const ACCOUNT_KEK: &str = "vault-kek";
pub const ACCOUNT_AUTH_KEY: &str = "vault-auth-key";
pub const ACCOUNT_ACTIVE_WORKSPACE: &str = "vault-active-workspace";

/// Kasa başlatma yanıtı.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct InitVaultResponse {
    pub workspace_id: Uuid,
    pub workspace_name: String,
}

/// Kasa kilit açma yanıtı.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UnlockResponse {
    pub workspace_id: Uuid,
    pub workspace_name: String,
}

/// Yeni bir kasa ve varsayılan çalışma alanı oluşturup başlatır.
pub fn init_vault(
    state: &DesktopAppState,
    password: &str,
    workspace_name: Option<String>,
) -> Result<InitVaultResponse, AppError> {
    init_vault_internal(state, password, workspace_name, false)
}

/// Test ortamları için hızlı KDF (Argon2 düşük maliyet) ile kasayı başlatır.
pub fn init_vault_fast(
    state: &DesktopAppState,
    password: &str,
    workspace_name: Option<String>,
) -> Result<InitVaultResponse, AppError> {
    init_vault_internal(state, password, workspace_name, true)
}

fn init_vault_internal(
    state: &DesktopAppState,
    password: &str,
    workspace_name: Option<String>,
    fast_kdf: bool,
) -> Result<InitVaultResponse, AppError> {
    if password.trim().is_empty() {
        return Err(AppError::ValidationError("Parola boş olamaz".into()));
    }

    let salt = generate_salt();
    let master_key = if fast_kdf {
        derive_master_key_with_params(password, &salt, 64, 1, 1)?
    } else {
        derive_master_key(password, &salt)?
    };

    let kek = derive_kek(&master_key)?;
    let auth_key = derive_auth_key(&master_key)?;
    let dek = generate_dek();

    let wrapped_dek = wrap_dek(&kek, &dek)?;

    let ws_id = Uuid::now_v7();
    let ws_name = workspace_name.unwrap_or_else(|| "Kişisel Notlar".to_string());

    let record = WorkspaceRecord {
        id: ws_id,
        name: ws_name.clone(),
        encrypted_dek: wrapped_dek.ciphertext,
        dek_nonce: wrapped_dek.nonce.to_vec(),
        created_at: chrono::Utc::now().timestamp_millis(),
    };

    {
        let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
        store.create_workspace(&record)?;
    }

    // Keychain ve oturum tuzu kaydı
    let _ = state.keychain.set_key(KEYCHAIN_SERVICE, ACCOUNT_SALT, &salt);
    let _ = state.keychain.set_key(KEYCHAIN_SERVICE, ACCOUNT_KEK, kek.as_bytes());
    let _ = state.keychain.set_key(KEYCHAIN_SERVICE, ACCOUNT_AUTH_KEY, auth_key.as_bytes());
    let _ = state.keychain.set_key(KEYCHAIN_SERVICE, ACCOUNT_ACTIVE_WORKSPACE, ws_id.as_bytes());

    *state.salt.write().map_err(|e| AppError::Internal(e.to_string()))? = Some(salt);
    state.set_unlocked(dek, kek, auth_key, ws_id);

    Ok(InitVaultResponse {
        workspace_id: ws_id,
        workspace_name: ws_name,
    })
}

/// Parola ile kasayı açar, DEK'i deşifre eder ve oturum anahtarlarını yükler.
pub fn unlock_vault(state: &DesktopAppState, password: &str) -> Result<UnlockResponse, AppError> {
    unlock_vault_internal(state, password, false)
}

/// Test ortamları için hızlı KDF ile kilidi açar.
pub fn unlock_vault_fast(state: &DesktopAppState, password: &str) -> Result<UnlockResponse, AppError> {
    unlock_vault_internal(state, password, true)
}

fn unlock_vault_internal(
    state: &DesktopAppState,
    password: &str,
    fast_kdf: bool,
) -> Result<UnlockResponse, AppError> {
    if password.trim().is_empty() {
        return Err(AppError::ValidationError("Parola boş olamaz".into()));
    }

    // Tuzu tespit et: Önce State, yoksa Keychain
    let salt = {
        let guard = state.salt.read().map_err(|e| AppError::Internal(e.to_string()))?;
        *guard
    };

    let salt = match salt {
        Some(s) => s,
        None => {
            let from_keychain = state
                .keychain
                .get_key(KEYCHAIN_SERVICE, ACCOUNT_SALT)
                .map_err(|e| AppError::KeychainError(e.to_string()))?;
            match from_keychain {
                Some(bytes) if bytes.len() == notes_core::crypto::SALT_SIZE => {
                    let mut s = [0u8; notes_core::crypto::SALT_SIZE];
                    s.copy_from_slice(&bytes);
                    *state.salt.write().map_err(|e| AppError::Internal(e.to_string()))? = Some(s);
                    s
                }
                _ => return Err(AppError::VaultNotInitialized),
            }
        }
    };

    let master_key = if fast_kdf {
        derive_master_key_with_params(password, &salt, 64, 1, 1)?
    } else {
        derive_master_key(password, &salt)?
    };

    let kek = derive_kek(&master_key)?;
    let auth_key = derive_auth_key(&master_key)?;

    // Aktif çalışma alanını bul
    let (ws_record, wrapped_dek) = get_target_workspace_and_wrapped_dek(state)?;

    let dek = unwrap_dek(&kek, &wrapped_dek).map_err(|_| AppError::InvalidPassword)?;

    // Keychain'i güncelle
    let _ = state.keychain.set_key(KEYCHAIN_SERVICE, ACCOUNT_KEK, kek.as_bytes());
    let _ = state.keychain.set_key(KEYCHAIN_SERVICE, ACCOUNT_AUTH_KEY, auth_key.as_bytes());
    let _ = state.keychain.set_key(
        KEYCHAIN_SERVICE,
        ACCOUNT_ACTIVE_WORKSPACE,
        ws_record.id.as_bytes(),
    );

    let res = UnlockResponse {
        workspace_id: ws_record.id,
        workspace_name: ws_record.name,
    };

    state.set_unlocked(dek, kek, auth_key, ws_record.id);

    Ok(res)
}

/// Keychain'de saklanan KEK ile biyometrik / parolasız kilit açma.
pub fn unlock_with_keychain(state: &DesktopAppState) -> Result<UnlockResponse, AppError> {
    let kek_bytes = state
        .keychain
        .get_key(KEYCHAIN_SERVICE, ACCOUNT_KEK)
        .map_err(|e| AppError::KeychainError(e.to_string()))?
        .ok_or_else(|| AppError::KeychainError("Keychain'de KEK kaydı bulunamadı".into()))?;

    if kek_bytes.len() != KEY_SIZE {
        return Err(AppError::KeychainError("Geçersiz KEK uzunluğu".into()));
    }

    let auth_bytes = state
        .keychain
        .get_key(KEYCHAIN_SERVICE, ACCOUNT_AUTH_KEY)
        .map_err(|e| AppError::KeychainError(e.to_string()))?
        .ok_or_else(|| AppError::KeychainError("Keychain'de AuthKey kaydı bulunamadı".into()))?;

    if auth_bytes.len() != KEY_SIZE {
        return Err(AppError::KeychainError("Geçersiz AuthKey uzunluğu".into()));
    }

    let mut kek_arr = [0u8; KEY_SIZE];
    kek_arr.copy_from_slice(&kek_bytes);
    let kek = KeyEncryptionKey::from_bytes(kek_arr);

    let mut auth_arr = [0u8; KEY_SIZE];
    auth_arr.copy_from_slice(&auth_bytes);
    let auth_key = AuthenticationKey::from_bytes(auth_arr);

    let (ws_record, wrapped_dek) = get_target_workspace_and_wrapped_dek(state)?;

    let dek = unwrap_dek(&kek, &wrapped_dek).map_err(|_| AppError::InvalidPassword)?;

    let res = UnlockResponse {
        workspace_id: ws_record.id,
        workspace_name: ws_record.name,
    };

    state.set_unlocked(dek, kek, auth_key, ws_record.id);

    Ok(res)
}

/// Kasayı kilitler: Oturum anahtarlarını bellekten siler (zeroize) ve FTS indeksini sıfırlar.
pub fn lock_vault(state: &DesktopAppState) -> Result<(), AppError> {
    // 1. Durumu Locked yap (ZeroizeOnDrop otomatik işletilir)
    state.set_locked();

    // 2. FTS5 sanal tablosundaki tüm düz metinleri temizle
    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    clear_all_index(store.conn())?;

    Ok(())
}

/// Kasanın yerel depoda başlatılıp başlatılmadığını (workspace kaydı var mı) denetler.
pub fn is_vault_initialized(state: &DesktopAppState) -> Result<bool, AppError> {
    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let workspaces = store.list_workspaces()?;
    Ok(!workspaces.is_empty())
}

fn get_target_workspace_and_wrapped_dek(
    state: &DesktopAppState,
) -> Result<(WorkspaceRecord, WrappedDek), AppError> {
    let store = state.store.lock().map_err(|e| AppError::Internal(e.to_string()))?;
    let workspaces = store.list_workspaces()?;

    if workspaces.is_empty() {
        return Err(AppError::VaultNotInitialized);
    }

    // Varsa keychain'deki aktif workspace id
    let target_ws_id = state
        .keychain
        .get_key(KEYCHAIN_SERVICE, ACCOUNT_ACTIVE_WORKSPACE)
        .ok()
        .flatten()
        .and_then(|bytes| {
            if bytes.len() == 16 {
                let mut b = [0u8; 16];
                b.copy_from_slice(&bytes);
                Some(Uuid::from_bytes(b))
            } else {
                None
            }
        });

    let ws = match target_ws_id {
        Some(id) => workspaces
            .into_iter()
            .find(|w| w.id == id)
            .or_else(|| store.list_workspaces().ok()?.into_iter().next())
            .ok_or(AppError::VaultNotInitialized)?,
        None => workspaces.into_iter().next().ok_or(AppError::VaultNotInitialized)?,
    };

    if ws.dek_nonce.len() != NONCE_SIZE {
        return Err(AppError::CryptoError("Geçersiz DEK nonce uzunluğu".into()));
    }

    let mut nonce = [0u8; NONCE_SIZE];
    nonce.copy_from_slice(&ws.dek_nonce);

    let wrapped_dek = WrappedDek::new(nonce, ws.encrypted_dek.clone());
    Ok((ws, wrapped_dek))
}
