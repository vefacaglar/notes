use std::collections::HashMap;
use std::sync::RwLock;

use crate::error::{CoreError, Result};

/// Keychain / Donanım anahtar kasası soyutlama arayüzü.
pub trait KeychainStore: Send + Sync {
    /// Belirtilen servis ve hesap için saklanan anahtar baytlarını getirir.
    /// Kayıt bulunamazsa `Ok(None)` döndürür.
    fn get_key(&self, service: &str, account: &str) -> Result<Option<Vec<u8>>>;

    /// Belirtilen servis ve hesap için anahtar verisini güvenli olarak saklar.
    /// Varsa mevcut kaydı günceller.
    fn set_key(&self, service: &str, account: &str, key_data: &[u8]) -> Result<()>;

    /// Belirtilen servis ve hesap için anahtarı siler.
    fn delete_key(&self, service: &str, account: &str) -> Result<()>;
}

/// Testler, CI/CD ortamları ve Keychain erişiminin olmadığı durumlar için
/// bellek içi (in-memory) güvenli Keychain simülatörü.
#[derive(Default, Debug)]
pub struct InMemoryKeychain {
    store: RwLock<HashMap<(String, String), Vec<u8>>>,
}

impl InMemoryKeychain {
    pub fn new() -> Self {
        Self {
            store: RwLock::new(HashMap::new()),
        }
    }

    /// Bellekteki tüm anahtarları temizler.
    pub fn clear(&self) -> Result<()> {
        let mut map = self
            .store
            .write()
            .map_err(|e| CoreError::Crypto(format!("InMemoryKeychain kilit hatası: {e}")))?;
        map.clear();
        Ok(())
    }
}

impl KeychainStore for InMemoryKeychain {
    fn get_key(&self, service: &str, account: &str) -> Result<Option<Vec<u8>>> {
        let map = self
            .store
            .read()
            .map_err(|e| CoreError::Crypto(format!("InMemoryKeychain okuma kilidi hatası: {e}")))?;
        let key = (service.to_string(), account.to_string());
        Ok(map.get(&key).cloned())
    }

    fn set_key(&self, service: &str, account: &str, key_data: &[u8]) -> Result<()> {
        let mut map = self
            .store
            .write()
            .map_err(|e| CoreError::Crypto(format!("InMemoryKeychain yazma kilidi hatası: {e}")))?;
        let key = (service.to_string(), account.to_string());
        map.insert(key, key_data.to_vec());
        Ok(())
    }

    fn delete_key(&self, service: &str, account: &str) -> Result<()> {
        let mut map = self
            .store
            .write()
            .map_err(|e| CoreError::Crypto(format!("InMemoryKeychain silme kilidi hatası: {e}")))?;
        let key = (service.to_string(), account.to_string());
        map.remove(&key);
        Ok(())
    }
}

/// macOS Keychain Access ile yerel işletim sistemi CLI (`/usr/bin/security`) üzerinden
/// entegrasyon sağlayan yapı.
#[derive(Default, Debug, Clone)]
pub struct MacOsKeychain;

impl MacOsKeychain {
    pub fn new() -> Self {
        Self
    }

    fn to_hex(bytes: &[u8]) -> String {
        let mut s = String::with_capacity(bytes.len() * 2);
        for b in bytes {
            use std::fmt::Write;
            let _ = write!(s, "{:02x}", b);
        }
        s
    }

    fn from_hex(hex_str: &str) -> Result<Vec<u8>> {
        let clean = hex_str.trim();
        if !clean.len().is_multiple_of(2) {
            return Err(CoreError::Crypto("Geçersiz hex uzunluğu".into()));
        }

        let mut bytes = Vec::with_capacity(clean.len() / 2);
        for i in (0..clean.len()).step_by(2) {
            let byte_str = &clean[i..i + 2];
            let byte = u8::from_str_radix(byte_str, 16)
                .map_err(|e| CoreError::Crypto(format!("Geçersiz hex verisi: {e}")))?;
            bytes.push(byte);
        }
        Ok(bytes)
    }
}

impl KeychainStore for MacOsKeychain {
    fn get_key(&self, service: &str, account: &str) -> Result<Option<Vec<u8>>> {
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (service, account);
            Err(CoreError::Crypto(
                "MacOsKeychain yalnızca macOS ortamında desteklenir".into(),
            ))
        }

        #[cfg(target_os = "macos")]
        {
            let output = std::process::Command::new("security")
                .arg("find-generic-password")
                .arg("-s")
                .arg(service)
                .arg("-a")
                .arg(account)
                .arg("-w")
                .output()
                .map_err(|e| {
                    CoreError::Crypto(format!("macOS security komutu çalıştırılamadı: {e}"))
                })?;

            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                // errSecItemNotFound (44) veya "could not be found"
                if stderr.contains("could not be found")
                    || stderr.contains("44")
                    || output.status.code() == Some(44)
                {
                    return Ok(None);
                }
                return Err(CoreError::Crypto(format!(
                    "macOS Keychain okuma hatası: {stderr}"
                )));
            }

            let stdout = String::from_utf8_lossy(&output.stdout);
            let bytes = Self::from_hex(stdout.trim())?;
            Ok(Some(bytes))
        }
    }

    fn set_key(&self, service: &str, account: &str, key_data: &[u8]) -> Result<()> {
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (service, account, key_data);
            Err(CoreError::Crypto(
                "MacOsKeychain yalnızca macOS ortamında desteklenir".into(),
            ))
        }

        #[cfg(target_os = "macos")]
        {
            let hex_val = Self::to_hex(key_data);

            let output = std::process::Command::new("security")
                .arg("add-generic-password")
                .arg("-U") // Varsa güncelle
                .arg("-s")
                .arg(service)
                .arg("-a")
                .arg(account)
                .arg("-w")
                .arg(&hex_val)
                .output()
                .map_err(|e| {
                    CoreError::Crypto(format!("macOS security komutu çalıştırılamadı: {e}"))
                })?;

            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                return Err(CoreError::Crypto(format!(
                    "macOS Keychain yazma hatası: {stderr}"
                )));
            }

            Ok(())
        }
    }

    fn delete_key(&self, service: &str, account: &str) -> Result<()> {
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (service, account);
            Err(CoreError::Crypto(
                "MacOsKeychain yalnızca macOS ortamında desteklenir".into(),
            ))
        }

        #[cfg(target_os = "macos")]
        {
            let output = std::process::Command::new("security")
                .arg("delete-generic-password")
                .arg("-s")
                .arg(service)
                .arg("-a")
                .arg(account)
                .output()
                .map_err(|e| {
                    CoreError::Crypto(format!("macOS security komutu çalıştırılamadı: {e}"))
                })?;

            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                if stderr.contains("could not be found")
                    || stderr.contains("44")
                    || output.status.code() == Some(44)
                {
                    return Ok(());
                }
                return Err(CoreError::Crypto(format!(
                    "macOS Keychain silme hatası: {stderr}"
                )));
            }

            Ok(())
        }
    }
}
