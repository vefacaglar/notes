use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::Instant;
use egui::{Color32, Context, Frame, Margin, RichText, Stroke};
use uuid::Uuid;

use notes_sync::client::{ReqwestSyncTransport, SyncClientConfig, SyncTransport};
use notes_sync::protocol::{EncryptedUpdateEnvelope, SyncPullRequest, SyncPushRequest};

use crate::commands::database::cmd_create_database;
use crate::commands::pages::{cmd_create_page, cmd_get_page_tree, cmd_save_page_markdown};
use crate::commands::search::{cmd_search_fts, SearchResultDto};
use crate::commands::vault::{init_vault_fast, unlock_vault_fast, is_vault_initialized};
use crate::state::{AppError, DesktopAppState};

/// Kasa kilit ve ilk başlatma modal durumu.
pub struct VaultModalState {
    pub workspace_name: String,
    pub password_input: String,
    pub password_confirm: String,
    pub error_message: Option<String>,
    pub is_initialized: bool,
}

impl Default for VaultModalState {
    fn default() -> Self {
        Self {
            workspace_name: "Kişisel Notlarım".to_string(),
            password_input: String::new(),
            password_confirm: String::new(),
            error_message: None,
            is_initialized: false,
        }
    }
}

impl VaultModalState {
    pub fn new() -> Self {
        Self::default()
    }

    /// Kasa durumunu yerel SQLite'tan denetler.
    pub fn refresh_init_status(&mut self, state: &DesktopAppState) {
        self.is_initialized = is_vault_initialized(state).unwrap_or(false);
    }

    /// Kilit veya ilk kurulum penceresini çizer.
    pub fn render(&mut self, ctx: &Context, state: &DesktopAppState) -> bool {
        let mut unlocked_now = false;

        egui::CentralPanel::default().show(ctx, |ui| {
            ui.centered_and_justified(|ui| {
                Frame::none()
                    .fill(Color32::from_rgb(28, 30, 38))
                    .stroke(Stroke::new(1.0, Color32::from_rgb(50, 55, 70)))
                    .rounding(10.0)
                    .inner_margin(Margin::same(24.0))
                    .show(ui, |ui| {
                        ui.set_max_width(400.0);

                        if !self.is_initialized {
                            // --- Yeni Kasa Oluşturma Ekranı ---
                            ui.vertical_centered(|ui| {
                                ui.label(RichText::new("📓").size(36.0));
                                ui.add_space(6.0);
                                ui.label(
                                    RichText::new("Notes — Yeni Kasa Kurulumu")
                                        .size(20.0)
                                        .strong()
                                        .color(Color32::from_rgb(220, 230, 245)),
                                );
                                ui.label(
                                    RichText::new(
                                        "Verileriniz XChaCha20-Poly1305 ve Argon2id ile şifrelenir.",
                                    )
                                    .size(12.0)
                                    .color(Color32::from_gray(150)),
                                );
                            });

                            ui.add_space(16.0);

                            ui.label("Çalışma Alanı Adı:");
                            ui.add(
                                egui::TextEdit::singleline(&mut self.workspace_name)
                                    .desired_width(f32::INFINITY),
                            );

                            ui.add_space(8.0);
                            ui.label("Ana Parola:");
                            ui.add(
                                egui::TextEdit::singleline(&mut self.password_input)
                                    .password(true)
                                    .desired_width(f32::INFINITY),
                            );

                            ui.add_space(8.0);
                            ui.label("Parolayı Onaylayın:");
                            ui.add(
                                egui::TextEdit::singleline(&mut self.password_confirm)
                                    .password(true)
                                    .desired_width(f32::INFINITY),
                            );

                            if let Some(ref err) = self.error_message {
                                ui.add_space(8.0);
                                ui.label(
                                    RichText::new(err)
                                        .color(Color32::from_rgb(240, 80, 80))
                                        .size(12.5),
                                );
                            }

                            ui.add_space(16.0);
                            if ui
                                .button(
                                    RichText::new("Kasayı Başlat ve Şifrele")
                                        .strong()
                                        .size(14.0),
                                )
                                .clicked()
                            {
                                if self.password_input.trim().is_empty() {
                                    self.error_message = Some("Parola boş olamaz!".to_string());
                                } else if self.password_input != self.password_confirm {
                                    self.error_message =
                                        Some("Parolalar birbiriyle eşleşmiyor!".to_string());
                                } else {
                                    match init_vault_fast(
                                        state,
                                        &self.password_input,
                                        Some(self.workspace_name.clone()),
                                    ) {
                                        Ok(_) => {
                                            self.is_initialized = true;
                                            self.error_message = None;
                                            self.password_input.clear();
                                            self.password_confirm.clear();
                                            // Başlangıç örnek sayfalarını oluştur
                                            let _ = seed_starter_pages(state);
                                            unlocked_now = true;
                                        }
                                        Err(e) => {
                                            self.error_message =
                                                Some(format!("Kasa oluşturulamadı: {}", e));
                                        }
                                    }
                                }
                            }
                        } else {
                            // --- Mevcut Kasa Kilit Açma Ekranı ---
                            ui.vertical_centered(|ui| {
                                ui.label(RichText::new("🔒").size(36.0));
                                ui.add_space(6.0);
                                ui.label(
                                    RichText::new("Kasa Kilitli")
                                        .size(20.0)
                                        .strong()
                                        .color(Color32::from_rgb(220, 230, 245)),
                                );
                                ui.label(
                                    RichText::new(
                                        "Lütfen notlarınıza erişmek için ana parolanızı girin.",
                                    )
                                    .size(12.0)
                                    .color(Color32::from_gray(150)),
                                );
                            });

                            ui.add_space(16.0);
                            ui.label("Ana Parola:");
                            let pass_resp = ui.add(
                                egui::TextEdit::singleline(&mut self.password_input)
                                    .password(true)
                                    .desired_width(f32::INFINITY),
                            );

                            let enter_pressed = pass_resp.lost_focus()
                                && ui.input(|i| i.key_pressed(egui::Key::Enter));

                            if let Some(ref err) = self.error_message {
                                ui.add_space(8.0);
                                ui.label(
                                    RichText::new(err)
                                        .color(Color32::from_rgb(240, 80, 80))
                                        .size(12.5),
                                );
                            }

                            ui.add_space(16.0);
                            if ui
                                .button(RichText::new("Kilidi Aç").strong().size(14.0))
                                .clicked()
                                || enter_pressed
                            {
                                match unlock_vault_fast(state, &self.password_input) {
                                    Ok(_) => {
                                        self.error_message = None;
                                        self.password_input.clear();
                                        unlocked_now = true;
                                    }
                                    Err(_) => {
                                        self.error_message =
                                            Some("Geçersiz parola. Lütfen tekrar deneyin.".into());
                                    }
                                }
                            }
                        }
                    });
            });
        });

        unlocked_now
    }
}

/// Cmd+K Hızlı Arama Modal Durumu.
#[derive(Default)]
pub struct SearchModalState {
    pub is_open: bool,
    pub query: String,
    pub results: Vec<SearchResultDto>,
}

impl SearchModalState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn open(&mut self) {
        self.is_open = true;
        self.query.clear();
        self.results.clear();
    }

    pub fn render(
        &mut self,
        ctx: &Context,
        state: &DesktopAppState,
        active_page_id: &mut Option<Uuid>,
    ) {
        if !self.is_open {
            return;
        }

        let mut should_close = false;
        let mut target_page_id = None;

        egui::Window::new("🔍 Hızlı Arama (FTS5)")
            .open(&mut self.is_open)
            .collapsible(false)
            .resizable(false)
            .min_width(520.0)
            .anchor(egui::Align2::CENTER_TOP, egui::vec2(0.0, 100.0))
            .show(ctx, |ui| {
                let search_input = ui.add(
                    egui::TextEdit::singleline(&mut self.query)
                        .hint_text("Not başlıklarında veya içeriğinde ara...")
                        .desired_width(f32::INFINITY),
                );

                if search_input.changed() {
                    if self.query.trim().is_empty() {
                        self.results.clear();
                    } else if let Ok(res) = cmd_search_fts(state, &self.query, Some(10)) {
                        self.results = res;
                    }
                }

                ui.add_space(8.0);
                ui.separator();

                egui::ScrollArea::vertical()
                    .max_height(350.0)
                    .show(ui, |ui| {
                        if self.results.is_empty() {
                            ui.add_space(20.0);
                            ui.label(
                                RichText::new(if self.query.trim().is_empty() {
                                    "Aramak için bir kelime veya etiket yazın."
                                } else {
                                    "Eşleşen sonuç bulunamadı."
                                })
                                .color(Color32::from_gray(140))
                                .italics(),
                            );
                        }

                        for item in &self.results {
                            Frame::none()
                                .fill(Color32::from_rgb(34, 36, 46))
                                .rounding(6.0)
                                .inner_margin(Margin::same(8.0))
                                .show(ui, |ui| {
                                    if ui
                                        .button(
                                            RichText::new(format!("📄 {}", item.page_title))
                                                .strong()
                                                .color(Color32::from_rgb(110, 180, 255)),
                                        )
                                        .clicked()
                                    {
                                        target_page_id = Some(item.page_id);
                                        should_close = true;
                                    }

                                    ui.add_space(2.0);
                                    let snippet_clean =
                                        item.snippet.replace("<b>", "").replace("</b>", "");
                                    ui.label(
                                        RichText::new(snippet_clean)
                                            .size(12.0)
                                            .color(Color32::from_gray(180)),
                                    );
                                });
                            ui.add_space(4.0);
                        }
                    });

                if ui.input(|i| i.key_pressed(egui::Key::Escape)) {
                    should_close = true;
                }
            });

        if let Some(id) = target_page_id {
            *active_page_id = Some(id);
        }
        if should_close {
            self.is_open = false;
        }
    }
}

/// Senkronizasyon geri bildirim mesajları.
enum SyncMsg {
    Health(bool),
    Pushed(Vec<Uuid>),
    SyncComplete(Result<String, String>),
}

/// ☁ Cloud Sync Ayarları ve Senkronizasyon Modalı.
pub struct SyncModalState {
    pub is_open: bool,
    pub server_url: String,
    pub device_id: String,
    pub is_online: Option<bool>,
    pub status_message: Option<(String, Instant)>,
    pub pending_count: usize,
    sync_rx: Receiver<SyncMsg>,
    sync_tx: Sender<SyncMsg>,
}

impl Default for SyncModalState {
    fn default() -> Self {
        let (tx, rx) = channel();
        Self {
            is_open: false,
            server_url: "http://127.0.0.1:8080".to_string(),
            device_id: Uuid::new_v4().to_string(),
            is_online: None,
            status_message: None,
            pending_count: 0,
            sync_rx: rx,
            sync_tx: tx,
        }
    }
}

impl SyncModalState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn open(&mut self) {
        self.is_open = true;
    }

    /// Senkronizasyon penceresini çizer.
    pub fn render(&mut self, ctx: &Context, state: &DesktopAppState) {
        // Asenkron iş parçacıklarından gelen yanıtları tüket
        while let Ok(msg) = self.sync_rx.try_recv() {
            match msg {
                SyncMsg::Health(ok) => {
                    self.is_online = Some(ok);
                    self.status_message = Some((
                        if ok {
                            "Sunucu çevrimiçi ✓".to_string()
                        } else {
                            "Sunucuya erişilemiyor ✗".to_string()
                        },
                        Instant::now(),
                    ));
                }
                SyncMsg::Pushed(ids) => {
                    if let Ok(store) = state.store.lock() {
                        let page_repo = notes_core::storage::PageRepo::new(store.conn());
                        for id in ids {
                            let _ = page_repo.remove_outbox(id);
                        }
                    }
                }
                SyncMsg::SyncComplete(res) => match res {
                    Ok(m) => {
                        self.status_message = Some((m, Instant::now()));
                    }
                    Err(e) => {
                        self.status_message = Some((format!("Hata: {}", e), Instant::now()));
                    }
                },
            }
        }

        if !self.is_open {
            return;
        }

        // Bekleyen outbox sayısını kontrol et
        if let Ok(store) = state.store.lock() {
            let count: i64 = store
                .conn()
                .query_row("SELECT count(*) FROM sync_outbox", [], |r| r.get(0))
                .unwrap_or(0);
            self.pending_count = count as usize;
        }

        egui::Window::new("☁ Self-Hosted Cloud Senkronizasyon")
            .open(&mut self.is_open)
            .collapsible(false)
            .resizable(false)
            .min_width(420.0)
            .show(ctx, |ui| {
                ui.label(
                    RichText::new("Notes Cloud API Entegrasyonu")
                        .size(15.0)
                        .strong(),
                );
                ui.label(
                    RichText::new("Uçtan uca şifreli (E2EE) veriler kör röle (Blind Relay) ile eşitlenir.")
                        .size(12.0)
                        .color(Color32::from_gray(150)),
                );

                ui.add_space(10.0);

                ui.label("Sunucu Adresi (API URL):");
                ui.add(
                    egui::TextEdit::singleline(&mut self.server_url)
                        .hint_text("http://127.0.0.1:8080")
                        .desired_width(f32::INFINITY),
                );

                ui.add_space(6.0);
                ui.label("Cihaz Kimliği (Device ID):");
                ui.add(
                    egui::TextEdit::singleline(&mut self.device_id)
                        .desired_width(f32::INFINITY),
                );

                ui.add_space(10.0);

                // Durum Göstergesi
                ui.horizontal(|ui| {
                    ui.label("Sunucu Durumu:");
                    match self.is_online {
                        Some(true) => {
                            ui.label(
                                RichText::new("● Çevrimiçi")
                                    .color(Color32::from_rgb(80, 200, 100))
                                    .strong(),
                            );
                        }
                        Some(false) => {
                            ui.label(
                                RichText::new("● Çevrimdışı")
                                    .color(Color32::from_rgb(230, 80, 80))
                                    .strong(),
                            );
                        }
                        None => {
                            ui.label(
                                RichText::new("● Bilinmiyor")
                                    .color(Color32::from_gray(140)),
                            );
                        }
                    }

                    ui.separator();
                    ui.label(format!("Kuyrukta Bekleyen: {} paket", self.pending_count));
                });

                if let Some((ref msg, _)) = self.status_message {
                    ui.add_space(4.0);
                    ui.label(RichText::new(msg).size(12.5).color(Color32::from_rgb(220, 190, 80)));
                }

                ui.add_space(14.0);

                ui.horizontal(|ui| {
                    let tx_health = self.sync_tx.clone();
                    let url_health = self.server_url.clone();
                    let dev_health = self.device_id.clone();

                    if ui.button("Bağlantıyı Test Et").clicked() {
                        std::thread::spawn(move || {
                            let rt = tokio::runtime::Builder::new_current_thread()
                                .enable_all()
                                .build();
                            if let Ok(rt) = rt {
                                rt.block_on(async {
                                    let config = SyncClientConfig::new(url_health, dev_health);
                                    if let Ok(transport) = ReqwestSyncTransport::new(config) {
                                        let healthy = transport.check_health().await.unwrap_or(false);
                                        let _ = tx_health.send(SyncMsg::Health(healthy));
                                    } else {
                                        let _ = tx_health.send(SyncMsg::Health(false));
                                    }
                                });
                            }
                        });
                    }

                    let tx_sync = self.sync_tx.clone();
                    let url_sync = self.server_url.clone();
                    let dev_sync = self.device_id.clone();

                    if ui
                        .button(RichText::new("🔄 Şimdi Senkronize Et (Push & Pull)").strong())
                        .clicked()
                    {
                        // State'ten outbox zarflarını yalnızca butona basıldığında oku
                        let mut outbox_envelopes = Vec::new();
                        let mut pushed_record_ids = Vec::new();
                        let ws_id = state.get_workspace_id().unwrap_or_default();

                        if let Ok(store) = state.store.lock() {
                            let page_repo = notes_core::storage::PageRepo::new(store.conn());
                            if let Ok(items) = page_repo.list_outbox_fifo(50) {
                                for item in items {
                                    if let Ok(env) = EncryptedUpdateEnvelope::from_bytes(&item.envelope_bytes) {
                                        pushed_record_ids.push(item.id);
                                        outbox_envelopes.push(env);
                                    }
                                }
                            }
                        }

                        std::thread::spawn(move || {
                            let rt = tokio::runtime::Builder::new_current_thread()
                                .enable_all()
                                .build();
                            if let Ok(rt) = rt {
                                rt.block_on(async {
                                    let config = SyncClientConfig::new(url_sync, dev_sync);
                                    let transport = match ReqwestSyncTransport::new(config) {
                                        Ok(t) => t,
                                        Err(e) => {
                                            let _ = tx_sync.send(SyncMsg::SyncComplete(Err(e.to_string())));
                                            return;
                                        }
                                    };

                                    // 1. Push
                                    let push_count = outbox_envelopes.len();
                                    if !outbox_envelopes.is_empty() {
                                        let push_req = SyncPushRequest {
                                            workspace_id: ws_id,
                                            client_id: 1,
                                            envelopes: outbox_envelopes,
                                        };
                                        if let Err(e) = transport.push_envelopes(&push_req).await {
                                            let _ = tx_sync.send(SyncMsg::SyncComplete(Err(format!("Push başarısız: {}", e))));
                                            return;
                                        }
                                        // Push başarılı: iletilen outbox kayıtlarının silinmesi için ana iş parçacığına bildir
                                        let _ = tx_sync.send(SyncMsg::Pushed(pushed_record_ids));
                                    }

                                    // 2. Pull
                                    let pull_req = SyncPullRequest {
                                        workspace_id: ws_id,
                                        doc_ids: None,
                                        since_timestamp: None,
                                        limit: Some(100),
                                    };
                                    let pull_res = transport.pull_envelopes(&pull_req).await;
                                    let pulled_count = pull_res.map(|r| r.envelopes.len()).unwrap_or(0);

                                    let _ = tx_sync.send(SyncMsg::SyncComplete(Ok(format!(
                                        "Senkronizasyon tamamlandı: {} gönderildi, {} alındı.",
                                        push_count, pulled_count
                                    ))));
                                });
                            }
                        });
                    }
                });
            });
    }
}

/// Yeni oluşturulan kasaya örnek başlangıç sayfalarını ve veritabanını ekler.
pub fn seed_starter_pages(state: &DesktopAppState) -> Result<(), AppError> {
    // Zaten sayfa varsa seed ekleme
    let existing_tree = cmd_get_page_tree(state, None, false).unwrap_or_default();
    if !existing_tree.is_empty() {
        return Ok(());
    }

    // 1. Örnek Zengin Başlangıç Sayfası
    let welcome_page = cmd_create_page(
        state,
        "Hoş Geldiniz — Notes Native macOS",
        None,
        Some("🚀".to_string()),
        None,
    )?;

    let welcome_markdown = r#"# Hoş Geldiniz — Notes Native macOS 🚀

Notes, macOS üzerinde çalışan, **%100 saf Rust**, yerel öncelikli (**local-first**), uçtan uca şifreli (**E2EE**) Notion tarzı bir not alma ve bilgi yönetim uygulamasıdır.

## 🎯 Öne Çıkan Özellikler
- **Tek Gövde Akıcı Markdown Editörü:** Tüm metni `Cmd+A` ile seçin, kopyalayın, yapıştırın ve gecikmesiz yazın.
- **Biçimlendirme & Slash Menü:** Üst araç çubuğunu kullanın veya metin içinde `/h1`, `/todo`, `/code`, `/quote`, `/table` yazarak anında şablon ekleyin.
- **3 Sekmeli Görünüm:**
  1. `✏ Düzenle`: Tam ekran akıcı yazım modu.
  2. `◫ Bölünmüş`: Solda Markdown kaynağı, sağda gerçek zamanlı render.
  3. `👁 Önizleme`: Temiz okuma modu ve interaktif tıklanabilir görev kutucukları.

## 📋 Hızlı Görev Listesi
- [x] Saf Rust ve Native macOS Penceresi (`eframe` + `egui`)
- [x] XChaCha20-Poly1305 ve Argon2id yerel kasa şifreleme
- [ ] Proje Görevleri veritabanını incele: [[Proje Görevleri DB]]
- [ ] İlk kendi sayfanı oluştur ve düşüncelerini yaz

## 💡 İpuçları
> **Hızlı Arama:** `Cmd+K` tuş kombinasyonuna basarak tüm notlarınızda Türkçe diyakritik duyarsız tam metin araması yapabilirsiniz.

Notlarınızı etiketleyerek gruplandırın: #rust #macos #e2ee #localfirst

```rust
fn main() {
    println!("Saf Rust ile geliştirilen akıcı masaüstü deneyimi!");
}
```
"#;

    cmd_save_page_markdown(state, welcome_page.id, welcome_markdown)?;

    // 2. Örnek Notion Tarzı Veritabanı Sayfası
    let db_page = cmd_create_page(
        state,
        "Proje Görevleri DB",
        None,
        Some("📋".to_string()),
        None,
    )?;

    let db_props = vec![
        notes_core::model::property::DatabasePropertyDefinition::new(
            "Durum",
            notes_core::model::property::PropertyType::Select,
        )
        .with_options(vec![
            notes_core::model::property::SelectOption::new("Yapılacak"),
            notes_core::model::property::SelectOption::new("Devam Ediyor"),
            notes_core::model::property::SelectOption::new("Tamamlandı"),
        ]),
        notes_core::model::property::DatabasePropertyDefinition::new(
            "Öncelik",
            notes_core::model::property::PropertyType::Select,
        )
        .with_options(vec![
            notes_core::model::property::SelectOption::new("Düşük"),
            notes_core::model::property::SelectOption::new("Orta"),
            notes_core::model::property::SelectOption::new("Yüksek"),
        ]),
        notes_core::model::property::DatabasePropertyDefinition::new(
            "Bitiş Tarihi",
            notes_core::model::property::PropertyType::Date,
        ),
    ];

    let db_schema = cmd_create_database(state, db_page.id, db_props)?;
    let _ = crate::commands::database::cmd_create_database_view(
        state,
        db_schema.id,
        "Kanban Panosu".to_string(),
        notes_core::model::database::ViewType::Board,
    );
    let _ = crate::commands::database::cmd_create_database_view(
        state,
        db_schema.id,
        "Takvim Görünümü".to_string(),
        notes_core::model::database::ViewType::Calendar,
    );

    // Örnek 3 Görev Satırı
    let _ = crate::commands::database::cmd_insert_database_row(
        state,
        db_page.id,
        "Native macOS eframe arayüzü",
        serde_json::json!({
            "Durum": "Tamamlandı",
            "Öncelik": "Yüksek",
            "Bitiş Tarihi": "2026-10-25"
        }),
    );

    let _ = crate::commands::database::cmd_insert_database_row(
        state,
        db_page.id,
        "Markdown canlı render motoru",
        serde_json::json!({
            "Durum": "Devam Ediyor",
            "Öncelik": "Yüksek",
            "Bitiş Tarihi": "2026-10-28"
        }),
    );

    let _ = crate::commands::database::cmd_insert_database_row(
        state,
        db_page.id,
        "Self-hosted Sync sunucu bağlantısı",
        serde_json::json!({
            "Durum": "Yapılacak",
            "Öncelik": "Orta",
            "Bitiş Tarihi": "2026-11-05"
        }),
    );

    Ok(())
}
