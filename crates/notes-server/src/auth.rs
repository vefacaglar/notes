use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use axum::async_trait;
use axum::extract::FromRequestParts;
use axum::http::request::Parts;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;

use chrono::Utc;
use rand::rngs::OsRng;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use subtle::ConstantTimeEq;

use crate::error::{ServerError, ServerResult};
use crate::storage::ServerStore;

/// Kullanıcı oturumu.
#[derive(Debug, Clone)]
pub struct Session {
    pub account_id: String,
    pub created_at: i64,
    pub expires_at: i64,
}

/// Bellek içi oturum ve ZK kimlik doğrulama yöneticisi.
#[derive(Clone)]
pub struct AuthManager {
    sessions: Arc<RwLock<HashMap<String, Session>>>,
    token_ttl_seconds: i64,
}

impl AuthManager {
    pub fn new(token_ttl_seconds: i64) -> Self {
        Self {
            sessions: Arc::new(RwLock::new(HashMap::new())),
            token_ttl_seconds,
        }
    }

    /// Yeni bir oturum üretir ve saklar. 32 baytlık kriptografik rastgele token döner.
    pub fn create_session(&self, account_id: &str) -> String {
        let mut token_bytes = [0u8; 32];
        OsRng.fill_bytes(&mut token_bytes);
        let token = hex::encode(token_bytes);

        let now = Utc::now().timestamp();
        let expires_at = now + self.token_ttl_seconds;

        let session = Session {
            account_id: account_id.to_string(),
            created_at: now,
            expires_at,
        };

        let mut sessions = self.sessions.write().unwrap();
        sessions.insert(token.clone(), session);

        token
    }

    /// Verilen Bearer token'ı doğrular ve ilişkili `account_id`yi döner.
    pub fn validate_token(&self, token: &str) -> Option<String> {
        let mut sessions = self.sessions.write().unwrap();
        if let Some(session) = sessions.get(token) {
            let now = Utc::now().timestamp();
            if session.expires_at >= now {
                return Some(session.account_id.clone());
            }
        }
        // Süresi dolmuşsa veya yoksa temizle
        sessions.remove(token);
        None
    }

    /// Oturumu sonlandırır (logout).
    pub fn revoke_token(&self, token: &str) {
        let mut sessions = self.sessions.write().unwrap();
        sessions.remove(token);
    }
}

// Byte dizisini hex string'e çeviren yardımcı modül
mod hex {
    pub fn encode<T: AsRef<[u8]>>(data: T) -> String {
        data.as_ref().iter().map(|b| format!("{:02x}", b)).collect()
    }
}

/// ZK kayıt isteği.
#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    pub account_id: String,
    pub auth_verifier: Option<String>,
    pub auth_verifier_hash: Option<String>,
}

/// ZK kayıt yanıtı.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisterResponse {
    pub account_id: String,
    pub status: String,
}

/// ZK giriş / doğrulama isteği.
#[derive(Debug, Deserialize)]
pub struct VerifyRequest {
    pub account_id: String,
    pub auth_verifier: Option<String>,
    pub auth_verifier_hash: Option<String>,
}

/// ZK doğrulama yanıtı (Bearer token içerir).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VerifyResponse {
    pub account_id: String,
    pub token: String,
    pub token_type: String,
    pub expires_in: i64,
}


/// Kimliği doğrulanmış kullanıcı Axum Extractor'ı.
#[derive(Debug, Clone)]
pub struct AuthenticatedUser {
    pub account_id: String,
}

/// İstekten `AuthManager`'ı çıkartabilmek için durum trait'i.
pub trait AuthState {
    fn auth_manager(&self) -> &AuthManager;
}

#[async_trait]
impl<S> FromRequestParts<S> for AuthenticatedUser
where
    S: Send + Sync + AuthState,
{
    type Rejection = ServerError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        let auth_header = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|val| val.to_str().ok());

        let token = match auth_header {
            Some(header) if header.starts_with("Bearer ") => &header[7..],
            _ => {
                return Err(ServerError::Unauthorized(
                    "Yetkilendirme başlığı eksik veya geçersiz (Bearer <token> bekleniyor)".into(),
                ));
            }
        };

        let auth_mgr = state.auth_manager();
        if let Some(account_id) = auth_mgr.validate_token(token) {
            Ok(AuthenticatedUser { account_id })
        } else {
            Err(ServerError::Unauthorized(
                "Geçersiz veya süresi dolmuş oturum token'ı".into(),
            ))
        }
    }
}

/// Kimlik doğrulayıcı veriden BLAKE3 hash'ini hesaplar.
pub fn compute_verifier_hash(verifier: &str) -> String {
    blake3::hash(verifier.as_bytes()).to_hex().to_string()
}

/// Sabit zamanlı eşitlik karşılaştırması.
pub fn constant_time_eq_str(a: &str, b: &str) -> bool {
    let a_bytes = a.as_bytes();
    let b_bytes = b.as_bytes();
    if a_bytes.len() != b_bytes.len() {
        return false;
    }
    a_bytes.ct_eq(b_bytes).into()
}

/// `POST /api/v1/auth/register`
pub async fn register_handler(
    store: &ServerStore,
    req: RegisterRequest,
) -> ServerResult<impl IntoResponse> {
    if req.account_id.trim().is_empty() {
        return Err(ServerError::InvalidInput("account_id boş olamaz".into()));
    }

    let verifier_hash = match (&req.auth_verifier_hash, &req.auth_verifier) {
        (Some(hash), _) if !hash.is_empty() => hash.clone(),
        (_, Some(verifier)) if !verifier.is_empty() => compute_verifier_hash(verifier),
        _ => {
            return Err(ServerError::InvalidInput(
                "auth_verifier veya auth_verifier_hash sağlanmalıdır".into(),
            ));
        }
    };

    store.insert_account(&req.account_id, &verifier_hash)?;

    Ok((
        StatusCode::CREATED,
        Json(RegisterResponse {
            account_id: req.account_id,
            status: "registered".to_string(),
        }),
    ))
}

/// `POST /api/v1/auth/verify`
pub async fn verify_handler(
    store: &ServerStore,
    auth_mgr: &AuthManager,
    req: VerifyRequest,
) -> ServerResult<impl IntoResponse> {
    if req.account_id.trim().is_empty() {
        return Err(ServerError::InvalidInput("account_id boş olamaz".into()));
    }

    let expected_hash = store
        .get_account_verifier_hash(&req.account_id)?
        .ok_or_else(|| {
            ServerError::Unauthorized("Geçersiz hesap kimliği veya doğrulayıcı".into())
        })?;

    let provided_hash = match (&req.auth_verifier_hash, &req.auth_verifier) {
        (Some(hash), _) if !hash.is_empty() => hash.clone(),
        (_, Some(verifier)) if !verifier.is_empty() => compute_verifier_hash(verifier),
        _ => {
            return Err(ServerError::InvalidInput(
                "auth_verifier veya auth_verifier_hash sağlanmalıdır".into(),
            ));
        }
    };

    if !constant_time_eq_str(&expected_hash, &provided_hash) {
        return Err(ServerError::Unauthorized(
            "Geçersiz hesap kimliği veya doğrulayıcı".into(),
        ));
    }

    let token = auth_mgr.create_session(&req.account_id);

    Ok((
        StatusCode::OK,
        Json(VerifyResponse {
            account_id: req.account_id,
            token,
            token_type: "Bearer".to_string(),
            expires_in: auth_mgr.token_ttl_seconds,
        }),
    ))
}
