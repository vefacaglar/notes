//! # Notes Sync
//!
//! Bu crate, çevrimdışı outbox kuyruğu, yrs CRDT durum vektörü el sıkışması
//! ve kör senkronizasyon protokolü istemci bileşenlerini içerir.

pub fn sync_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sync_version() {
        assert_eq!(sync_version(), "0.1.0");
    }
}
