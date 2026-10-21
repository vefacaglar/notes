use std::sync::Arc;
use egui::{Color32, Context, RichText, Ui};
use uuid::Uuid;

use notes_core::model::Page;

use crate::commands::database::cmd_create_database;
use crate::commands::pages::{
    cmd_create_page, cmd_get_page, cmd_get_page_tree, cmd_soft_delete_page, PageTreeNode,
};
use crate::commands::search::cmd_get_all_tags;
use crate::commands::vault::{is_vault_initialized, lock_vault};
use crate::state::DesktopAppState;
use crate::ui::database_view::DatabaseViewState;
use crate::ui::editor::EditorState;
use crate::ui::markdown_preview::PreviewAction;
use crate::ui::modals::{seed_starter_pages, SearchModalState, SyncModalState, VaultModalState};

/// Notes Masaüstü Saf Rust Native macOS Uygulaması.
pub struct NotesApp {
    pub state: Arc<DesktopAppState>,
    pub active_page_id: Option<Uuid>,
    pub active_page: Option<Page>,
    pub page_tree: Vec<PageTreeNode>,
    pub editor_state: EditorState,
    pub database_state: DatabaseViewState,
    pub vault_modal: VaultModalState,
    pub search_modal: SearchModalState,
    pub sync_modal: SyncModalState,
    pub all_tags: Vec<(String, usize)>,
    pub filter_tag: Option<String>,
    pub show_new_page_modal: bool,
    pub new_page_title: String,
    pub new_page_is_db: bool,
    pub new_page_parent_id: Option<Uuid>,
}

impl NotesApp {
    /// Yeni bir `NotesApp` örneği oluşturur.
    pub fn new(cc: &eframe::CreationContext<'_>, state: Arc<DesktopAppState>) -> Self {
        // macOS için şık koyu tema ve kontrast ayarları
        let mut visuals = egui::Visuals::dark();
        visuals.window_rounding = 10.0.into();
        visuals.window_fill = Color32::from_rgb(24, 26, 33);
        visuals.panel_fill = Color32::from_rgb(20, 22, 28);
        cc.egui_ctx.set_visuals(visuals);

        let mut vault_modal = VaultModalState::new();
        vault_modal.refresh_init_status(&state);

        let is_locked = state.is_locked();

        let mut app = Self {
            state,
            active_page_id: None,
            active_page: None,
            page_tree: Vec::new(),
            editor_state: EditorState::new(),
            database_state: DatabaseViewState::new(),
            vault_modal,
            search_modal: SearchModalState::new(),
            sync_modal: SyncModalState::new(),
            all_tags: Vec::new(),
            filter_tag: None,
            show_new_page_modal: false,
            new_page_title: String::new(),
            new_page_is_db: false,
            new_page_parent_id: None,
        };

        if !is_locked {
            app.refresh_tree();
            if let Some(first_node) = app.page_tree.first() {
                app.select_page(first_node.page.id);
            }
        }

        app
    }

    /// Sayfa ağacını ve etiketleri yerel depodan yeniler.
    pub fn refresh_tree(&mut self) {
        if self.state.is_locked() {
            return;
        }
        self.page_tree = cmd_get_page_tree(&self.state, None, false).unwrap_or_default();
        self.all_tags = cmd_get_all_tags(&self.state).unwrap_or_default();
    }

    /// Belirtilen sayfayı yükler ve aktif hale getirir.
    pub fn select_page(&mut self, page_id: Uuid) {
        if let Ok(page) = cmd_get_page(&self.state, page_id) {
            if page.is_database {
                let _ = self.database_state.load_database(&self.state, page_id);
            } else {
                let _ = self.editor_state.load_page(&self.state, page_id);
            }
            self.active_page_id = Some(page_id);
            self.active_page = Some(page);
        }
    }

    /// Başlığa göre sayfayı arayıp seçer (Wikilink tıklamaları için).
    pub fn select_page_by_title(&mut self, title: &str) {
        if let Ok(pages) = crate::commands::pages::cmd_list_pages(&self.state, false) {
            if let Some(target) = pages.into_iter().find(|p| p.title.eq_ignore_ascii_case(title)) {
                self.select_page(target.id);
            }
        }
    }

    /// Yeni sayfa veya veritabanı oluşturur.
    pub fn create_page(&mut self, title: &str, is_db: bool, parent_id: Option<Uuid>) {
        let trimmed = title.trim();
        let final_title = if trimmed.is_empty() {
            if is_db { "Yeni Veritabanı" } else { "Yeni Not" }
        } else {
            trimmed
        };

        let icon = if is_db { "📋" } else { "📄" };

        if let Ok(page) = cmd_create_page(&self.state, final_title, parent_id, Some(icon.to_string()), None) {
            if is_db {
                let default_props = vec![
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
                ];
                let _ = cmd_create_database(&self.state, page.id, default_props);
            }

            self.refresh_tree();
            self.select_page(page.id);
        }
    }

    /// Bir sayfayı çöp kutusuna taşır.
    pub fn delete_page(&mut self, page_id: Uuid) {
        let _ = cmd_soft_delete_page(&self.state, page_id);
        self.refresh_tree();
        if self.active_page_id == Some(page_id) {
            self.active_page_id = None;
            self.active_page = None;
            if let Some(first_node) = self.page_tree.first() {
                self.select_page(first_node.page.id);
            }
        }
    }
}

impl eframe::App for NotesApp {
    fn update(&mut self, ctx: &Context, _frame: &mut eframe::Frame) {
        // macOS Klavye Kısayolları
        ctx.input(|i| {
            if i.modifiers.command && i.key_pressed(egui::Key::K) {
                self.search_modal.open();
            }
            if i.modifiers.command && i.key_pressed(egui::Key::N) {
                self.show_new_page_modal = true;
                self.new_page_parent_id = None;
                self.new_page_title.clear();
                self.new_page_is_db = false;
            }
            if i.modifiers.command && i.key_pressed(egui::Key::L) {
                let _ = lock_vault(&self.state);
                self.active_page_id = None;
                self.active_page = None;
            }
        });

        // 1. Kasa Kilitli veya Henüz Başlatılmamış ise Kilit Ekranını Göster
        if self.state.is_locked() || !is_vault_initialized(&self.state).unwrap_or(false) {
            let unlocked = self.vault_modal.render(ctx, &self.state);
            if unlocked {
                // Kilit yeni açıldı: Başlangıç sayfalarını doğrula ve ilk sayfayı seç
                let _ = seed_starter_pages(&self.state);
                self.refresh_tree();
                if let Some(first_node) = self.page_tree.first() {
                    self.select_page(first_node.page.id);
                }
            }
            return;
        }

        // 2. Sol Kenar Çubuğu (Sidebar)
        egui::SidePanel::left("sidebar_panel")
            .default_width(260.0)
            .width_range(200.0..=400.0)
            .show(ctx, |ui| {
                ui.add_space(8.0);

                // Çalışma Alanı Başlığı & İşlem Butonları
                ui.horizontal(|ui| {
                    ui.label(RichText::new("📓").size(18.0));
                    ui.label(RichText::new("Notes").strong().size(16.0).color(Color32::from_rgb(220, 230, 245)));

                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        // Kasa Kilitleme Butonu
                        if ui.button("🔒").on_hover_text("Kasayı Kilitle (Cmd+L)").clicked() {
                            let _ = lock_vault(&self.state);
                            self.active_page_id = None;
                            self.active_page = None;
                        }

                        // Cloud Sync Butonu
                        if ui.button("☁").on_hover_text("Cloud Senkronizasyon").clicked() {
                            self.sync_modal.open();
                        }
                    });
                });

                ui.add_space(10.0);

                // Cmd+K Hızlı Arama Butonu
                if ui
                    .button(RichText::new("🔍 Hızlı Arama (Cmd+K)").color(Color32::from_gray(180)))
                    .clicked()
                {
                    self.search_modal.open();
                }

                ui.add_space(6.0);

                // Yeni Sayfa & Yeni Veritabanı Butonları
                ui.horizontal(|ui| {
                    if ui.button(RichText::new("+ Yeni Not").strong()).clicked() {
                        self.show_new_page_modal = true;
                        self.new_page_parent_id = None;
                        self.new_page_title.clear();
                        self.new_page_is_db = false;
                    }

                    if ui.button(RichText::new("+ Veritabanı").strong().color(Color32::from_rgb(110, 180, 255))).clicked() {
                        self.show_new_page_modal = true;
                        self.new_page_parent_id = None;
                        self.new_page_title.clear();
                        self.new_page_is_db = true;
                    }
                });

                ui.add_space(8.0);
                ui.separator();
                ui.add_space(4.0);

                // Sayfa Hiyerarşisi Ağacı (Tree View)
                ui.label(RichText::new("SAYFALAR").size(11.0).color(Color32::from_gray(140)).strong());

                egui::ScrollArea::vertical()
                    .id_salt("sidebar_tree_scroll")
                    .auto_shrink([false, false])
                    .max_height(ui.available_height() - 140.0)
                    .show(ui, |ui| {
                        let mut target_select = None;
                        let mut target_delete = None;
                        let mut target_add_child = None;

                        render_tree_recursive(
                            ui,
                            &self.page_tree,
                            0,
                            self.active_page_id,
                            &mut target_select,
                            &mut target_delete,
                            &mut target_add_child,
                        );

                        if let Some(id) = target_select {
                            self.select_page(id);
                        }
                        if let Some(id) = target_delete {
                            self.delete_page(id);
                        }
                        if let Some(parent_id) = target_add_child {
                            self.show_new_page_modal = true;
                            self.new_page_parent_id = Some(parent_id);
                            self.new_page_title.clear();
                            self.new_page_is_db = false;
                        }
                    });

                ui.separator();

                // Etiketler (Tags) Bölümü
                ui.label(RichText::new("ETİKETLER").size(11.0).color(Color32::from_gray(140)).strong());

                let mut clear_filter = false;
                if let Some(ref active_filter) = self.filter_tag {
                    ui.horizontal(|ui| {
                        ui.label(RichText::new(format!("Filtre: #{}", active_filter)).color(Color32::from_rgb(130, 210, 140)));
                        if ui.button("Temizle").clicked() {
                            clear_filter = true;
                        }
                    });
                }
                if clear_filter {
                    self.filter_tag = None;
                }

                ui.horizontal_wrapped(|ui| {
                    let mut chosen_tag = None;
                    for (tag, count) in &self.all_tags {
                        let btn = ui.button(RichText::new(format!("#{} ({})", tag, count)).size(11.5));
                        if btn.clicked() {
                            chosen_tag = Some(tag.clone());
                        }
                    }
                    if let Some(t) = chosen_tag {
                        self.filter_tag = Some(t);
                    }
                });

                // Alt Kısım Bilgi Rozeti
                ui.with_layout(egui::Layout::bottom_up(egui::Align::Min), |ui| {
                    ui.add_space(4.0);
                    ui.label(
                        RichText::new("🔒 Yerel Şifreli Kasa • E2EE")
                            .size(10.5)
                            .color(Color32::from_gray(130)),
                    );
                });
            });

        // 3. Merkez Çalışma Alanı (Central Panel)
        egui::CentralPanel::default().show(ctx, |ui| {
            if let Some(ref page) = self.active_page {
                if page.is_database {
                    self.database_state.render(ui, &self.state);
                    if let Some(row_id) = self.database_state.selected_row_for_navigation {
                        self.select_page(row_id);
                        self.database_state.selected_row_for_navigation = None;
                    }
                } else {
                    let actions = self.editor_state.render(ui, &self.state);
                    for action in actions {
                        match action {
                            PreviewAction::NavigatePage(title) => {
                                self.select_page_by_title(&title);
                            }
                            PreviewAction::FilterTag(tag) => {
                                self.filter_tag = Some(tag);
                                self.search_modal.open();
                                self.search_modal.query = format!("#{}", self.filter_tag.as_deref().unwrap_or(""));
                            }
                            _ => {}
                        }
                    }
                }
            } else {
                ui.centered_and_justified(|ui| {
                    ui.vertical_centered(|ui| {
                        ui.label(RichText::new("📓").size(48.0));
                        ui.add_space(10.0);
                        ui.label(
                            RichText::new("Bir not seçin veya yeni bir sayfa oluşturun")
                                .size(18.0)
                                .color(Color32::from_gray(180)),
                        );
                        ui.add_space(10.0);
                        if ui.button(RichText::new("+ Yeni Not Oluştur").size(14.0).strong()).clicked() {
                            self.show_new_page_modal = true;
                            self.new_page_parent_id = None;
                            self.new_page_title.clear();
                            self.new_page_is_db = false;
                        }
                    });
                });
            }
        });

        // 4. Modallar
        // Cmd+K Arama Modalı
        let mut target_search_id = None;
        self.search_modal.render(ctx, &self.state, &mut target_search_id);
        if let Some(id) = target_search_id {
            self.select_page(id);
        }

        // Cloud Sync Modalı
        self.sync_modal.render(ctx, &self.state);

        // Yeni Sayfa Ekleme Diyaloğu
        if self.show_new_page_modal {
            egui::Window::new(if self.new_page_is_db { "Yeni Veritabanı Oluştur" } else { "Yeni Sayfa Oluştur" })
                .collapsible(false)
                .resizable(false)
                .min_width(320.0)
                .show(ctx, |ui| {
                    ui.label("Başlık:");
                    ui.add(egui::TextEdit::singleline(&mut self.new_page_title).desired_width(f32::INFINITY));

                    ui.add_space(6.0);
                    ui.checkbox(&mut self.new_page_is_db, "Notion Tarzı Veritabanı Sayfası");

                    ui.add_space(10.0);
                    ui.horizontal(|ui| {
                        if ui.button("Oluştur").clicked() {
                            let title = self.new_page_title.clone();
                            let is_db = self.new_page_is_db;
                            let parent_id = self.new_page_parent_id;
                            self.create_page(&title, is_db, parent_id);
                            self.show_new_page_modal = false;
                        }
                        if ui.button("İptal").clicked() {
                            self.show_new_page_modal = false;
                        }
                    });
                });
        }
    }
}

fn render_tree_recursive(
    ui: &mut Ui,
    nodes: &[PageTreeNode],
    depth: usize,
    active_page_id: Option<Uuid>,
    target_select: &mut Option<Uuid>,
    target_delete: &mut Option<Uuid>,
    target_add_child: &mut Option<Uuid>,
) {
    for node in nodes {
        let is_selected = active_page_id == Some(node.page.id);
        let indent = depth as f32 * 14.0;

        ui.horizontal(|ui| {
            ui.add_space(indent);

            let icon = node.page.icon.as_deref().unwrap_or(if node.page.is_database { "📋" } else { "📄" });
            let label_text = format!("{} {}", icon, node.page.title);

            let mut rich = RichText::new(label_text).size(13.0);
            if is_selected {
                rich = rich.strong().color(Color32::from_rgb(110, 180, 255));
            } else {
                rich = rich.color(Color32::from_gray(210));
            }

            let btn = ui.selectable_label(is_selected, rich);
            if btn.clicked() {
                *target_select = Some(node.page.id);
            }

            // Hover Eylemleri (+ ve 🗑)
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.button("🗑").on_hover_text("Sayfayı Sil").clicked() {
                    *target_delete = Some(node.page.id);
                }
                if ui.button("+").on_hover_text("Alt Sayfa Ekle").clicked() {
                    *target_add_child = Some(node.page.id);
                }
            });
        });

        // Alt sayfaları özyinelemeli render et
        if !node.children.is_empty() {
            render_tree_recursive(
                ui,
                &node.children,
                depth + 1,
                active_page_id,
                target_select,
                target_delete,
                target_add_child,
            );
        }
    }
}
