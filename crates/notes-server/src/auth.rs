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

/// Kullanıcı oturumu. Token'ın BLAKE3 hash'i saklanır.
#[derive(Debug, Clone)]
pub struct Session {
    pub account_id: String,
    pub token_hash: [u8; 32],
    pub created_at: i64,
    pub expires_at: i64,
}

/// Bellek içi oturum ve ZK kimlik doğrulama yöneticisi.
#[derive(Clone)]
pub struct AuthManager {
    sessions: Arc<RwLock<Vec<Session>>>,
    pub token_ttl_seconds: i64,
}

impl AuthManager {
    pub fn new(token_ttl_seconds: i64) -> Self {
        Self {
            sessions: Arc::new(RwLock::new(Vec::new())),
            token_ttl_seconds,
        }
    }

    /// Yeni bir oturum üretir ve saklar. 32 baytlık kriptografik rastgele token döner.
    pub fn create_session(&self, account_id: &str) -> String {
        let mut token_bytes = [0u8; 32];
        OsRng.fill_bytes(&mut token_bytes);
        let token = hex::encode(token_bytes);

        let token_hash = *blake3::hash(token.as_bytes()).as_bytes();
        let now = Utc::now().timestamp();
        let expires_at = now + self.token_ttl_seconds;

        let session = Session {
            account_id: account_id.to_string(),
            token_hash,
            created_at: now,
            expires_at,
        };

        let mut sessions = self.sessions.write().unwrap();
        // Süresi dolmuş oturumları temizle
        sessions.retain(|s| s.expires_at >= now);
        sessions.push(session);

        token
    }

    /// Verilen Bearer token'ı sabit zamanlı BLAKE3 hash karşılaştırması ile doğrular.
    pub fn validate_token(&self, token: &str) -> Option<String> {
        let now = Utc::now().timestamp();
        let provided_token_hash = blake3::hash(token.as_bytes());
        let provided_bytes = provided_token_hash.as_bytes();

        let mut sessions = self.sessions.write().unwrap();
        sessions.retain(|s| s.expires_at >= now);

        let mut matched_account = None;

        for session in sessions.iter() {
            let is_match: bool = session.token_hash.ct_eq(provided_bytes).into();
            if is_match && session.expires_at >= now {
                matched_account = Some(session.account_id.clone());
            }
        }

        matched_account
    }

    /// Oturumu sonlandırır (logout). Sabit zamanlı karşılaştırma ile kaldırır.
    pub fn revoke_token(&self, token: &str) {
        let target_hash = blake3::hash(token.as_bytes());
        let target_bytes = target_hash.as_bytes();

        let mut sessions = self.sessions.write().unwrap();
        sessions.retain(|s| !bool::from(s.token_hash.ct_eq(target_bytes)));
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

/// Geriye dönük veya alternatif isimlendirme için alias.
pub type AuthenticatedAccount = AuthenticatedUser;

/// İstekten `AuthManager`'ı çıkartabilmek için durum trait'i.
pub trait AuthState {
    fn auth_manager(&self) -> &AuthManager;
}

/// Bearer token'ı sabit zamanlı BLAKE3 hash byte karşılaştırması ile doğrular.
pub fn authenticate_bearer(
    auth_mgr: &AuthManager,
    token: &str,
) -> ServerResult<AuthenticatedAccount> {
    if let Some(account_id) = auth_mgr.validate_token(token) {
        Ok(AuthenticatedAccount { account_id })
    } else {
        Err(ServerError::Unauthorized(
            "Geçersiz veya süresi dolmuş oturum token'ı".into(),
        ))
    }
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
        authenticate_bearer(auth_mgr, token)
    }
}

/// Kimlik doğrulayıcı veriden BLAKE3 hash'ini hesaplar.
pub fn compute_verifier_hash(verifier: &str) -> String {
    blake3::hash(verifier.as_bytes()).to_hex().to_string()
}

/// Sabit zamanlı byte dilimi karşılaştırması (timing attack önlemi).
pub fn constant_time_eq_bytes(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.ct_eq(b).into()
}

/// BLAKE3 hash karşılaştırmasını sabit zamanlı byte karşılaştırması ile yapar (timing attack önlemi).
pub fn constant_time_eq_hash(a: &str, b: &str) -> bool {
    match (blake3::Hash::from_hex(a), blake3::Hash::from_hex(b)) {
        (Ok(h1), Ok(h2)) => bool::from(h1.as_bytes().ct_eq(h2.as_bytes())),
        _ => constant_time_eq_bytes(a.as_bytes(), b.as_bytes()),
    }
}

/// String dizilerini sabit zamanlı olarak karşılaştırır.
pub fn constant_time_eq_str(a: &str, b: &str) -> bool {
    constant_time_eq_hash(a, b)
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

/// ZK kimlik doğrulayıcısını sabit zamanlı BLAKE3 byte karşılaştırması ile doğrular.
pub async fn verify_account(
    store: &ServerStore,
    auth_mgr: &AuthManager,
    req: VerifyRequest,
) -> ServerResult<VerifyResponse> {
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

    // Sabit zamanlı byte karşılaştırması ile timing attack önleme
    if !constant_time_eq_hash(&expected_hash, &provided_hash) {
        return Err(ServerError::Unauthorized(
            "Geçersiz hesap kimliği veya doğrulayıcı".into(),
        ));
    }

    let token = auth_mgr.create_session(&req.account_id);

    Ok(VerifyResponse {
        account_id: req.account_id,
        token,
        token_type: "Bearer".to_string(),
        expires_in: auth_mgr.token_ttl_seconds,
    })
}

/// `POST /api/v1/auth/verify`
pub async fn verify_handler(
    store: &ServerStore,
    auth_mgr: &AuthManager,
    req: VerifyRequest,
) -> ServerResult<impl IntoResponse> {
    let res = verify_account(store, auth_mgr, req).await?;
    Ok((StatusCode::OK, Json(res)))
}
