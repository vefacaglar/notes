use std::path::PathBuf;
use notes_core::crypto::MacOsKeychain;
use notes_core::storage::{BlobStore, LocalStore};
use notes_desktop::state::DesktopAppState;

fn get_app_data_dir() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home)
                .join("Library")
                .join("Application Support")
                .join("Notes");
        }
    }

    std::env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join(".notes-data")
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let data_dir = get_app_data_dir();
    let db_path = data_dir.join("notes.sqlite");
    let blob_dir = data_dir.join("blobs");

    println!("Notes Masaüstü Çekirdeği Başlatılıyor...");
    println!("Veri dizini: {}", data_dir.display());

    let store = LocalStore::open_path(&db_path)?;
    let blob_store = BlobStore::new(&blob_dir)?;
    let keychain = Box::new(MacOsKeychain::new());

    let _app_state = DesktopAppState::new(store, blob_store, keychain);

    println!("Notes Masaüstü Servisi hazır. IPC komut dinleyicisi başlatıldı.");
    Ok(())
}
