use std::path::PathBuf;
use std::sync::Arc;

use notes_core::crypto::MacOsKeychain;
use notes_core::storage::{BlobStore, LocalStore};
use notes_desktop::state::DesktopAppState;
use notes_desktop::ui::NotesApp;

fn get_app_data_dir() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home)
                .join("Library")
                .join("Application Support")
                .join("NotesRs");
        }
    }

    std::env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join("local_data")
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let data_dir = get_app_data_dir();
    let blob_dir = data_dir.join("blobs");
    let db_path = data_dir.join("vault.db");

    std::fs::create_dir_all(&data_dir)?;
    std::fs::create_dir_all(&blob_dir)?;

    let store = LocalStore::open_path(&db_path)?;
    let blob_store = BlobStore::new(&blob_dir)?;
    let keychain = Box::new(MacOsKeychain::new());

    let app_state = Arc::new(DesktopAppState::new(store, blob_store, keychain));

    let native_options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Notes — Native macOS")
            .with_inner_size([1280.0, 800.0])
            .with_min_inner_size([850.0, 550.0]),
        ..Default::default()
    };

    eframe::run_native(
        "Notes — Native macOS",
        native_options,
        Box::new(move |cc| Ok(Box::new(NotesApp::new(cc, app_state)))),
    )?;

    Ok(())
}
