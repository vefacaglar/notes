pub mod auth;
pub mod config;
pub mod error;
pub mod routes;
pub mod storage;

use std::sync::Arc;
use axum::routing::{get, post, put};
use axum::Router;
use tower_http::cors::CorsLayer;

use crate::auth::{AuthManager, AuthState};
use crate::config::ServerConfig;
use crate::routes::sync::SyncNotification;
use crate::storage::ServerStore;

/// Sunucu uygulama durumu.
#[derive(Clone)]
pub struct AppState {
    pub store: ServerStore,
    pub auth: Arc<AuthManager>,
    pub sync_tx: tokio::sync::broadcast::Sender<SyncNotification>,
    pub config: ServerConfig,
}

impl AppState {
    pub fn new(config: ServerConfig, store: ServerStore) -> Self {
        let (sync_tx, _) = tokio::sync::broadcast::channel(config.broadcast_capacity);
        let auth = Arc::new(AuthManager::new(config.token_ttl_seconds));
        Self {
            store,
            auth,
            sync_tx,
            config,
        }
    }

    /// Bellek içi test/geliştirme amaçlı AppState üretir.
    pub fn in_memory() -> Result<Self, error::ServerError> {
        let config = ServerConfig::default();
        let store = ServerStore::open_in_memory()?;
        Ok(Self::new(config, store))
    }
}

impl AuthState for AppState {
    fn auth_manager(&self) -> &AuthManager {
        &self.auth
    }
}

/// Tüm API rotalarını içeren Axum Router oluşturur.
pub fn build_router(state: AppState) -> Router {
    Router::new()
        // Sağlık kontrolü
        .route("/health", get(routes::health::health_check))
        .route("/api/v1/health", get(routes::health::health_check))
        // ZK Kimlik Doğrulama
        .route("/api/v1/auth/register", post(routes::register))
        .route("/api/v1/auth/verify", post(routes::verify))
        // Şifreli CRDT Senkronizasyonu
        .route("/api/v1/sync/push", post(routes::sync::push_updates))
        .route("/api/v1/sync/pull", get(routes::sync::pull_updates))
        // Şifreli İçerik-Adresli Depolama (CAS Blobs)
        .route(
            "/api/v1/blobs/:blob_hash",
            put(routes::blobs::put_blob).get(routes::blobs::get_blob),
        )
        // CORS
        .layer(
            CorsLayer::new()
                .allow_origin(tower_http::cors::Any)
                .allow_methods(tower_http::cors::Any)
                .allow_headers(tower_http::cors::Any),
        )
        .with_state(state)
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::{to_bytes, Body};
    use axum::http::{header, Request, StatusCode};
    use serde_json::json;
    use tower::ServiceExt;

    use crate::auth::{RegisterResponse, VerifyResponse};
    use crate::routes::blobs::BlobUploadResponse;
    use crate::routes::health::HealthResponse;
    use crate::routes::sync::{PullResponse, PushResponse};
    use crate::storage::IncomingEnvelope;

    /// Test için yardımcı: geçerli bir kullanıcı kaydeder, doğrular ve Bearer token döner.
    async fn setup_auth_token(app: &Router, account_id: &str, verifier: &str) -> String {
        // 1. Register
        let register_req = Request::builder()
            .method("POST")
            .uri("/api/v1/auth/register")
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                json!({
                    "account_id": account_id,
                    "auth_verifier": verifier
                })
                .to_string(),
            ))
            .unwrap();

        let resp = app.clone().oneshot(register_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);

        // 2. Verify
        let verify_req = Request::builder()
            .method("POST")
            .uri("/api/v1/auth/verify")
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                json!({
                    "account_id": account_id,
                    "auth_verifier": verifier
                })
                .to_string(),
            ))
            .unwrap();

        let resp = app.clone().oneshot(verify_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let body_bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let verify_res: VerifyResponse = serde_json::from_slice(&body_bytes).unwrap();
        verify_res.token
    }

    #[tokio::test]
    async fn test_health_check() {
        let state = AppState::in_memory().unwrap();
        let app = build_router(state);

        let req = Request::builder()
            .uri("/health")
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let body_bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let health: HealthResponse = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(health.status, "ok");
    }

    #[tokio::test]
    async fn test_auth_register_verify_and_rejections() {
        let state = AppState::in_memory().unwrap();
        let app = build_router(state);

        let account = "user-123";
        let secret_verifier = "my-zk-auth-secret-key-salt";

        // 1. Başarılı Kayıt
        let reg_req = Request::builder()
            .method("POST")
            .uri("/api/v1/auth/register")
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                json!({
                    "account_id": account,
                    "auth_verifier": secret_verifier
                })
                .to_string(),
            ))
            .unwrap();
        let resp = app.clone().oneshot(reg_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
        let body_bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let reg_res: RegisterResponse = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(reg_res.account_id, account);
        assert_eq!(reg_res.status, "registered");

        // 2. Tekrar kayıt -> Conflict 409
        let reg_conflict = Request::builder()
            .method("POST")
            .uri("/api/v1/auth/register")
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                json!({
                    "account_id": account,
                    "auth_verifier": secret_verifier
                })
                .to_string(),
            ))
            .unwrap();
        let resp = app.clone().oneshot(reg_conflict).await.unwrap();
        assert_eq!(resp.status(), StatusCode::CONFLICT);

        // 3. Yanlış verifier ile verify -> Unauthorized 401
        let verify_bad = Request::builder()
            .method("POST")
            .uri("/api/v1/auth/verify")
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                json!({
                    "account_id": account,
                    "auth_verifier": "wrong-secret"
                })
                .to_string(),
            ))
            .unwrap();
        let resp = app.clone().oneshot(verify_bad).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

        // 4. Doğru verifier ile verify -> OK 200
        let verify_ok = Request::builder()
            .method("POST")
            .uri("/api/v1/auth/verify")
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                json!({
                    "account_id": account,
                    "auth_verifier": secret_verifier
                })
                .to_string(),
            ))
            .unwrap();
        let resp = app.clone().oneshot(verify_ok).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body_bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let verify_res: VerifyResponse = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(verify_res.token_type, "Bearer");
        assert!(!verify_res.token.is_empty());
    }

    #[tokio::test]
    async fn test_sync_push_idempotency_pull_and_broadcast() {
        let state = AppState::in_memory().unwrap();
        let mut broadcast_rx = state.sync_tx.subscribe();
        let app = build_router(state);

        let token = setup_auth_token(&app, "sync-user", "sync-verifier").await;
        let auth_header = format!("Bearer {}", token);

        let workspace_id = "ws-test-1";
        let doc_id = "doc-test-1";

        // 1. Yetkisiz push denemesi -> 401 Unauthorized
        let unauthorized_push = Request::builder()
            .method("POST")
            .uri("/api/v1/sync/push")
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(json!({ "updates": [] }).to_string()))
            .unwrap();
        let resp = app.clone().oneshot(unauthorized_push).await.unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

        // 2. İlk güncelleme push
        let env1 = IncomingEnvelope {
            update_id: "upd-001".to_string(),
            workspace_id: workspace_id.to_string(),
            doc_id: doc_id.to_string(),
            client_id: 42,
            nonce: vec![1, 2, 3, 4],
            ciphertext: vec![10, 20, 30, 40],
        };

        let push_req1 = Request::builder()
            .method("POST")
            .uri("/api/v1/sync/push")
            .header(header::AUTHORIZATION, &auth_header)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                json!({
                    "updates": [env1]
                })
                .to_string(),
            ))
            .unwrap();

        let resp = app.clone().oneshot(push_req1).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body_bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let push_res: PushResponse = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(push_res.inserted, 1);
        assert_eq!(push_res.results[0].update_id, "upd-001");
        assert_eq!(push_res.results[0].status, "inserted");
        let first_seq = push_res.results[0].seq;

        // Broadcast bildirimi geldi mi?
        let notification = broadcast_rx.try_recv().expect("Bildirim bekleniyordu");
        assert_eq!(notification.update_id, "upd-001");
        assert_eq!(notification.seq, first_seq);

        // 3. Aynı güncellemenin tekrar push edilmesi (Idempotency testi)
        let duplicate_env = IncomingEnvelope {
            update_id: "upd-001".to_string(),
            workspace_id: workspace_id.to_string(),
            doc_id: doc_id.to_string(),
            client_id: 42,
            nonce: vec![1, 2, 3, 4],
            ciphertext: vec![10, 20, 30, 40],
        };

        let push_dup_req = Request::builder()
            .method("POST")
            .uri("/api/v1/sync/push")
            .header(header::AUTHORIZATION, &auth_header)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                json!({
                    "updates": [duplicate_env]
                })
                .to_string(),
            ))
            .unwrap();

        let resp = app.clone().oneshot(push_dup_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body_bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let push_res: PushResponse = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(push_res.inserted, 0); // Yeni eklenmedi
        assert_eq!(push_res.results[0].status, "already_exists");
        assert_eq!(push_res.results[0].seq, first_seq); // Aynı seq dönmeli!

        // Yeni broadcast gitmemeli (status already_exists)
        assert!(broadcast_rx.try_recv().is_err());

        // 4. İkinci farklı bir güncelleme push et
        let env2 = IncomingEnvelope {
            update_id: "upd-002".to_string(),
            workspace_id: workspace_id.to_string(),
            doc_id: doc_id.to_string(),
            client_id: 42,
            nonce: vec![5, 6, 7, 8],
            ciphertext: vec![50, 60, 70, 80],
        };

        let push_req2 = Request::builder()
            .method("POST")
            .uri("/api/v1/sync/push")
            .header(header::AUTHORIZATION, &auth_header)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                json!({
                    "updates": [env2]
                })
                .to_string(),
            ))
            .unwrap();

        let resp = app.clone().oneshot(push_req2).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body_bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let push_res: PushResponse = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(push_res.inserted, 1);
        let second_seq = push_res.results[0].seq;
        assert!(second_seq > first_seq);

        // 5. Pull güncellemeleri: since_seq = 0 (tüm 2 güncellemeyi almalı)
        let pull_all_req = Request::builder()
            .method("GET")
            .uri(format!("/api/v1/sync/pull?workspace_id={}&since_seq=0", workspace_id))
            .header(header::AUTHORIZATION, &auth_header)
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(pull_all_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body_bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let pull_res: PullResponse = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(pull_res.updates.len(), 2);
        assert_eq!(pull_res.updates[0].update_id, "upd-001");
        assert_eq!(pull_res.updates[1].update_id, "upd-002");
        assert_eq!(pull_res.max_seq, second_seq);

        // 6. Pull güncellemeleri: since_seq = first_seq (yalnızca 2. güncellemeyi almalı)
        let pull_delta_req = Request::builder()
            .method("GET")
            .uri(format!(
                "/api/v1/sync/pull?workspace_id={}&since_seq={}",
                workspace_id, first_seq
            ))
            .header(header::AUTHORIZATION, &auth_header)
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(pull_delta_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body_bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let pull_res: PullResponse = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(pull_res.updates.len(), 1);
        assert_eq!(pull_res.updates[0].update_id, "upd-002");
    }

    #[tokio::test]
    async fn test_cas_blob_upload_tamper_rejection_and_download() {
        let state = AppState::in_memory().unwrap();
        let app = build_router(state);

        let token = setup_auth_token(&app, "blob-user", "blob-verifier").await;
        let auth_header = format!("Bearer {}", token);

        let ciphertext_payload = b"enc-blob-encrypted-cas-payload-data-xchacha20";
        let valid_hash = blake3::hash(ciphertext_payload).to_hex().to_string();
        let tampered_hash = "0000000000000000000000000000000000000000000000000000000000000000";

        // 1. Tahrif edilmiş / uyuşmayan hash ile yükleme -> 400 Bad Request
        let tamper_req = Request::builder()
            .method("PUT")
            .uri(format!("/api/v1/blobs/{}", tampered_hash))
            .header(header::AUTHORIZATION, &auth_header)
            .header(header::CONTENT_TYPE, "application/octet-stream")
            .body(Body::from(ciphertext_payload.to_vec()))
            .unwrap();

        let resp = app.clone().oneshot(tamper_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

        // 2. Doğru hash ile yükleme -> 201 Created
        let upload_req = Request::builder()
            .method("PUT")
            .uri(format!("/api/v1/blobs/{}", valid_hash))
            .header(header::AUTHORIZATION, &auth_header)
            .header(header::CONTENT_TYPE, "application/octet-stream")
            .header("x-workspace-id", "ws-blobs-1")
            .body(Body::from(ciphertext_payload.to_vec()))
            .unwrap();

        let resp = app.clone().oneshot(upload_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);
        let body_bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let upload_res: BlobUploadResponse = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(upload_res.blob_hash, valid_hash);
        assert_eq!(upload_res.size_bytes, ciphertext_payload.len());
        assert!(upload_res.created);

        // 3. Aynı blob'u tekrar yükleme -> 200 OK (idempotent, created: false)
        let dup_upload_req = Request::builder()
            .method("PUT")
            .uri(format!("/api/v1/blobs/{}", valid_hash))
            .header(header::AUTHORIZATION, &auth_header)
            .header(header::CONTENT_TYPE, "application/octet-stream")
            .body(Body::from(ciphertext_payload.to_vec()))
            .unwrap();

        let resp = app.clone().oneshot(dup_upload_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body_bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let upload_res: BlobUploadResponse = serde_json::from_slice(&body_bytes).unwrap();
        assert!(!upload_res.created);

        // 4. Blob'u geri indirme -> 200 OK ve birebir aynı binary veri
        let download_req = Request::builder()
            .method("GET")
            .uri(format!("/api/v1/blobs/{}", valid_hash))
            .header(header::AUTHORIZATION, &auth_header)
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(download_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(
            resp.headers().get(header::CONTENT_TYPE).unwrap(),
            "application/octet-stream"
        );
        let downloaded_bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        assert_eq!(downloaded_bytes.as_ref(), ciphertext_payload);

        // 5. Olmayan blob sorgulama -> 404 Not Found
        let not_found_req = Request::builder()
            .method("GET")
            .uri(format!("/api/v1/blobs/{}", tampered_hash))
            .header(header::AUTHORIZATION, &auth_header)
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(not_found_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_workspace_and_blob_cross_account_isolation_forbidden() {
        let state = AppState::in_memory().unwrap();
        let app = build_router(state);

        let alice_token = setup_auth_token(&app, "alice", "alice-secret-verifier").await;
        let alice_auth = format!("Bearer {}", alice_token);

        let bob_token = setup_auth_token(&app, "bob", "bob-secret-verifier").await;
        let bob_auth = format!("Bearer {}", bob_token);

        let alice_ws = "ws-alice-private";

        // 1. Alice kendi çalışma alanına bir güncelleme push eder -> 200 OK
        let env_alice = IncomingEnvelope {
            update_id: "upd-alice-1".to_string(),
            workspace_id: alice_ws.to_string(),
            doc_id: "doc-alice-1".to_string(),
            client_id: 101,
            nonce: vec![1, 1, 1, 1],
            ciphertext: vec![10, 11, 12, 13],
        };

        let push_alice_req = Request::builder()
            .method("POST")
            .uri("/api/v1/sync/push")
            .header(header::AUTHORIZATION, &alice_auth)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                json!({
                    "updates": [env_alice]
                })
                .to_string(),
            ))
            .unwrap();

        let resp = app.clone().oneshot(push_alice_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body_bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let push_res: PushResponse = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(push_res.inserted, 1);

        // 2. Bob, Alice'in çalışma alanına push yapmaya çalışır -> 403 Forbidden!
        let env_bob_intrusion = IncomingEnvelope {
            update_id: "upd-bob-intrude".to_string(),
            workspace_id: alice_ws.to_string(),
            doc_id: "doc-alice-1".to_string(),
            client_id: 202,
            nonce: vec![2, 2, 2, 2],
            ciphertext: vec![20, 21, 22, 23],
        };

        let push_bob_forbidden_req = Request::builder()
            .method("POST")
            .uri("/api/v1/sync/push")
            .header(header::AUTHORIZATION, &bob_auth)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                json!({
                    "updates": [env_bob_intrusion]
                })
                .to_string(),
            ))
            .unwrap();

        let resp = app.clone().oneshot(push_bob_forbidden_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::FORBIDDEN);

        // 3. Bob, Alice'in çalışma alanından pull yapmaya çalışır -> 403 Forbidden!
        let pull_bob_forbidden_req = Request::builder()
            .method("GET")
            .uri(format!("/api/v1/sync/pull?workspace_id={}&since_seq=0", alice_ws))
            .header(header::AUTHORIZATION, &bob_auth)
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(pull_bob_forbidden_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::FORBIDDEN);

        // 4. Alice kendi çalışma alanından pull yapar -> 200 OK
        let pull_alice_req = Request::builder()
            .method("GET")
            .uri(format!("/api/v1/sync/pull?workspace_id={}&since_seq=0", alice_ws))
            .header(header::AUTHORIZATION, &alice_auth)
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(pull_alice_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body_bytes = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        let pull_res: PullResponse = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(pull_res.updates.len(), 1);
        assert_eq!(pull_res.updates[0].update_id, "upd-alice-1");

        // 5. Blob izolasyonu: Alice bir blob yükler
        let ciphertext_payload = b"secret-payload-of-alice";
        let blob_hash = blake3::hash(ciphertext_payload).to_hex().to_string();

        let upload_req = Request::builder()
            .method("PUT")
            .uri(format!("/api/v1/blobs/{}", blob_hash))
            .header(header::AUTHORIZATION, &alice_auth)
            .header(header::CONTENT_TYPE, "application/octet-stream")
            .header("x-workspace-id", alice_ws)
            .body(Body::from(ciphertext_payload.to_vec()))
            .unwrap();

        let resp = app.clone().oneshot(upload_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::CREATED);

        // 6. Bob, Alice'in blob'unu çekmeye çalışır -> 403 Forbidden!
        let get_blob_bob_req = Request::builder()
            .method("GET")
            .uri(format!("/api/v1/blobs/{}", blob_hash))
            .header(header::AUTHORIZATION, &bob_auth)
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(get_blob_bob_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::FORBIDDEN);

        // 7. Bob, Alice'in workspace'ine blob yüklemeye çalışır -> 403 Forbidden!
        let dummy_payload = b"bob-blob-content";
        let dummy_hash = blake3::hash(dummy_payload).to_hex().to_string();
        let put_blob_bob_req = Request::builder()
            .method("PUT")
            .uri(format!("/api/v1/blobs/{}", dummy_hash))
            .header(header::AUTHORIZATION, &bob_auth)
            .header(header::CONTENT_TYPE, "application/octet-stream")
            .header("x-workspace-id", alice_ws)
            .body(Body::from(dummy_payload.to_vec()))
            .unwrap();

        let resp = app.clone().oneshot(put_blob_bob_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::FORBIDDEN);

        // 8. Bob, var olan bir blob_hash'i kendi hesabına yeniden yazmaya / ele geçirmeye çalışır -> 403 Forbidden!
        let hijack_blob_bob_req = Request::builder()
            .method("PUT")
            .uri(format!("/api/v1/blobs/{}", blob_hash))
            .header(header::AUTHORIZATION, &bob_auth)
            .header(header::CONTENT_TYPE, "application/octet-stream")
            .header("x-workspace-id", "ws-bob-priv")
            .body(Body::from(ciphertext_payload.to_vec()))
            .unwrap();

        let resp = app.clone().oneshot(hijack_blob_bob_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::FORBIDDEN);

        // 9. Alice kendi blob'unu çeker -> 200 OK
        let get_blob_alice_req = Request::builder()
            .method("GET")
            .uri(format!("/api/v1/blobs/{}", blob_hash))
            .header(header::AUTHORIZATION, &alice_auth)
            .body(Body::empty())
            .unwrap();

        let resp = app.clone().oneshot(get_blob_alice_req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let downloaded = to_bytes(resp.into_body(), usize::MAX).await.unwrap();
        assert_eq!(downloaded.as_ref(), ciphertext_payload);
    }
}
