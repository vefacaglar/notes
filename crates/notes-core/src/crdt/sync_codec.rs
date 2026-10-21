//! CRDT senkronizasyon kodlayıcı ve çözücü (`sync_codec`).
//!
//! Bu modül, iki adımlı el sıkışma protokolü (handshake) için gerekli
//! StateVector üretimini, delta update hesaplamasını ve gelen güncellemelerin
//! yerel dokümana uygulanmasını (merge) sağlar.

use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{ReadTxn, StateVector, Transact, Update};

use crate::crdt::doc::PageCrdtDoc;
use crate::error::{CoreError, Result};

impl PageCrdtDoc {
    /// Yerel dokümanın mevcut durum vektörünü (StateVector v1 binary) serileştirir.
    pub fn state_vector(&self) -> Vec<u8> {
        let txn = self.doc().transact();
        txn.state_vector().encode_v1()
    }

    /// Uzak peer'ın sağladığı StateVector'e göre yereldeki eksik güncellemeleri (delta update v1 binary) üretir.
    /// `remote_sv` boş verilirse dokümanın başlangıçtan beri tüm geçmişini içeren tam güncelleme döner.
    pub fn encode_state_as_update(&self, remote_sv: &[u8]) -> Result<Vec<u8>> {
        let sv = if remote_sv.is_empty() {
            StateVector::default()
        } else {
            StateVector::decode_v1(remote_sv)
                .map_err(|e| CoreError::Serialization(format!("Geçersiz durum vektörü (StateVector) verisi: {e}")))?
        };

        let txn = self.doc().transact();
        Ok(txn.encode_diff_v1(&sv))
    }

    /// Uzaktan gelen ikili CRDT güncellemesini (update v1 binary) yerel dokümana uygular (çatışmasız merge).
    pub fn apply_update(&mut self, update: &[u8]) -> Result<()> {
        if update.is_empty() {
            return Ok(());
        }

        let parsed_update = Update::decode_v1(update)
            .map_err(|e| CoreError::Serialization(format!("Geçersiz CRDT güncelleme verisi: {e}")))?;

        let mut txn = self.doc().transact_mut();
        txn.apply_update(parsed_update)
            .map_err(|e| CoreError::InvalidState(format!("CRDT güncellemesi uygulanamadı: {e}")))?;

        Ok(())
    }

    /// Dokümanın tüm mevcut durumunu tek bir ikili güncelleme (full snapshot update) olarak serileştirir.
    pub fn encode_full_update(&self) -> Vec<u8> {
        self.encode_state_as_update(&[])
            .unwrap_or_default()
    }
}

/// Serbest fonksiyon: Dokümanın durum vektörünü üretir.
pub fn state_vector(doc: &PageCrdtDoc) -> Vec<u8> {
    doc.state_vector()
}

/// Serbest fonksiyon: Uzak durum vektörüne göre delta güncelleme üretir.
pub fn encode_state_as_update(doc: &PageCrdtDoc, remote_sv: &[u8]) -> Result<Vec<u8>> {
    doc.encode_state_as_update(remote_sv)
}

/// Serbest fonksiyon: İkili güncellemeyi dokümana uygular.
pub fn apply_update(doc: &mut PageCrdtDoc, update: &[u8]) -> Result<()> {
    doc.apply_update(update)
}
