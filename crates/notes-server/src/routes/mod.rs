pub mod blobs;
pub mod health;
pub mod sync;

use axum::extract::State;
use axum::response::IntoResponse;
use axum::Json;

use crate::auth::{register_handler, verify_handler, RegisterRequest, VerifyRequest};
use crate::error::ServerResult;
use crate::AppState;

pub async fn register(
    State(state): State<AppState>,
    Json(payload): Json<RegisterRequest>,
) -> ServerResult<impl IntoResponse> {
    register_handler(&state.store, payload).await
}

pub async fn verify(
    State(state): State<AppState>,
    Json(payload): Json<VerifyRequest>,
) -> ServerResult<impl IntoResponse> {
    verify_handler(&state.store, &state.auth, payload).await
}
