//! Senkronizasyon istemcisi modülü (`client`).
//!
//! Bu modül, sıfır-bilgi (Zero-Knowledge) şifrelenmiş CRDT güncelleme zarflarını
//! istemci ile senkronizasyon sunucusu arasında aktaran taşıma katmanını sağlar.

pub mod http_client;

pub use http_client::{
    InMemorySyncTransport, ReqwestSyncTransport, SyncClientConfig, SyncTransport,
};

pub use crate::error::SyncError as SyncClientError;
pub use crate::protocol::{
    DocStateVector, EncryptedUpdateEnvelope, SyncPullRequest, SyncPullResponse, SyncPushRequest,
    SyncPushResponse,
};
