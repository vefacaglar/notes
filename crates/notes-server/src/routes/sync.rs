use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::auth::AuthenticatedAccount;
use crate::error::{ServerError, ServerResult};
use crate::storage::{EncryptedEnvelopeRecord, IncomingEnvelope, PushResultItem};
use crate::AppState;

/// Canlı dinleyicilere (WebSocket / SSE) yayınlanan bildirim mesajı.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncNotification {
    pub workspace_id: String,
    pub doc_id: String,
    pub seq: i64,
    pub update_id: String,
}

/// Push isteği gövdesi: `{ "updates": [...] }`, `[...]` veya tekil obje formatlarını destekler.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum PushPayload {
    Batch { updates: Vec<IncomingEnvelope> },
    List(Vec<IncomingEnvelope>),
    Single(IncomingEnvelope),
}

impl PushPayload {
    pub fn into_envelopes(self) -> Vec<IncomingEnvelope> {
        match self {
            PushPayload::Batch { updates } => updates,
            PushPayload::List(updates) => updates,
            PushPayload::Single(envelope) => vec![envelope],
        }
    }
}

/// Push işlem yanıtı.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PushResponse {
    pub inserted: usize,
    pub results: Vec<PushResultItem>,
}

/// Pull sorgu parametreleri: `GET /api/v1/sync/pull?workspace_id=...&since_seq=0&limit=100`
#[derive(Debug, Deserialize)]
pub struct PullQuery {
    pub workspace_id: String,
    pub since_seq: Option<i64>,
    pub limit: Option<usize>,
}

/// Pull işlem yanıtı.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PullResponse {
    pub updates: Vec<EncryptedEnvelopeRecord>,
    pub max_seq: i64,
    pub has_more: bool,
}

/// `POST /api/v1/sync/push`
/// İstemciden gelen şifreli update zarflarını idempotent ve hesap yetkilendirmesiyle kaydeder.
pub async fn push_updates(
    account: AuthenticatedAccount,
    State(state): State<AppState>,
    Json(payload): Json<PushPayload>,
) -> ServerResult<impl IntoResponse> {
    let envelopes = payload.into_envelopes();
    if envelopes.is_empty() {
        return Ok((
            StatusCode::OK,
            Json(PushResponse {
                inserted: 0,
                results: Vec::new(),
            }),
        ));
    }

    // Doğrulama: zorunlu alanlar
    for env in &envelopes {
        if env.update_id.trim().is_empty() {
            return Err(ServerError::InvalidInput("update_id boş olamaz".into()));
        }
        if env.workspace_id.trim().is_empty() {
            return Err(ServerError::InvalidInput("workspace_id boş olamaz".into()));
        }
        if env.doc_id.trim().is_empty() {
            return Err(ServerError::InvalidInput("doc_id boş olamaz".into()));
        }
    }

    let results = state.store.batch_insert_updates(&account.account_id, &envelopes)?;
    let mut inserted_count = 0;

    // Yayın bildirimi gönder (tokio broadcast)
    for (env, res) in envelopes.iter().zip(results.iter()) {
        if res.status == "inserted" {
            inserted_count += 1;
            let _ = state.sync_tx.send(SyncNotification {
                workspace_id: env.workspace_id.clone(),
                doc_id: env.doc_id.clone(),
                seq: res.seq,
                update_id: env.update_id.clone(),
            });
        }
    }

    Ok((
        StatusCode::OK,
        Json(PushResponse {
            inserted: inserted_count,
            results,
        }),
    ))
}

/// `GET /api/v1/sync/pull`
/// İstemcinin eksik olduğu şifreli zarfları sıralı ve hesap izolasyonuyla döner.
pub async fn pull_updates(
    account: AuthenticatedAccount,
    State(state): State<AppState>,
    Query(query): Query<PullQuery>,
) -> ServerResult<impl IntoResponse> {
    if query.workspace_id.trim().is_empty() {
        return Err(ServerError::InvalidInput("workspace_id parametresi zorunludur".into()));
    }

    let since_seq = query.since_seq.unwrap_or(0);
    let limit = query.limit.unwrap_or(100).clamp(1, 1000);

    let updates = state
        .store
        .pull_updates(&account.account_id, &query.workspace_id, since_seq, limit)?;
    let max_seq = state
        .store
        .get_max_seq(&account.account_id, &query.workspace_id)?;
    let has_more = updates.last().map(|u| u.seq < max_seq).unwrap_or(false);

    Ok((
        StatusCode::OK,
        Json(PullResponse {
            updates,
            max_seq,
            has_more,
        }),
    ))
}
