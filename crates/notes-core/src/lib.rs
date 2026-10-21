//! # Notes Core
//!
//! Bu crate, Notes uygulamasının temel domain modellerini, iş mantığını,
//! yerel SQLite veri erişim katmanını ve kriptografik ilkel yapılarını barındırır.

pub mod error;
pub mod model;

pub use error::{CoreError, Result};
pub use model::*;
