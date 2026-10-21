//! Şifreli medya ve ek blobları aktarım modülü (`blob`).
//!
//! Bu modül, sıfır-bilgi (Zero-Knowledge) BLAKE3 içerik-adresli depolama (CAS)
//! mimarisine uygun şifreli ikili medya aktarım istemcisini içerir.

pub mod transfer;

pub use transfer::{
    BlobTransferClient, BlobTransferError, BlobTransport, InMemoryBlobTransport,
    ReqwestBlobTransport,
};
