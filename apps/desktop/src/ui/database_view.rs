use egui::{Color32, Frame, Margin, RichText, Stroke, Ui};
use uuid::Uuid;

use notes_core::model::database::{DatabaseSchema, DatabaseView, ViewType};
use notes_core::model::property::{DatabasePropertyDefinition, PropertyType};

use crate::commands::database::{
    cmd_create_database, cmd_create_database_view, cmd_delete_database_row, cmd_get_database,
    cmd_insert_database_row, cmd_list_database_views, cmd_query_database_view,
    cmd_update_database_row, DatabaseRow,
};
use crate::state::{AppError, DesktopAppState};

/// Notion tarzı veritabanı sayfası arayüz durumu.
pub struct DatabaseViewState {
    pub page_id: Option<Uuid>,
    pub schema: Option<DatabaseSchema>,
    pub views: Vec<DatabaseView>,
    pub active_view_type: ViewType,
    pub rows: Vec<DatabaseRow>,
    pub new_row_title: String,
    pub search_query: String,
    pub selected_row_for_navigation: Option<Uuid>,
}

impl Default for DatabaseViewState {
    fn default() -> Self {
        Self {
            page_id: None,
            schema: None,
            views: Vec::new(),
            active_view_type: ViewType::Table,
            rows: Vec::new(),
            new_row_title: String::new(),
            search_query: String::new(),
            selected_row_for_navigation: None,
        }
    }
}

impl DatabaseViewState {
    pub fn new() -> Self {
        Self::default()
    }

    /// Veritabanı şemasını, görünümlerini ve satırlarını yükler. Şema yoksa otomatik oluşturur.
    pub fn load_database(&mut self, state: &DesktopAppState, page_id: Uuid) -> Result<(), AppError> {
        self.page_id = Some(page_id);
        self.new_row_title.clear();
        self.search_query.clear();
        self.selected_row_for_navigation = None;

        // Şemayı getir veya yoksa oluştur
        let schema = match cmd_get_database(state, page_id) {
            Ok(s) => s,
            Err(_) => {
                // Varsayılan Notion özellikleri: Durum, Öncelik, Bitiş Tarihi
                let default_props = vec![
                    DatabasePropertyDefinition::new("Durum", PropertyType::Select)
                        .with_options(vec![
                            notes_core::model::property::SelectOption::new("Yapılacak"),
                            notes_core::model::property::SelectOption::new("Devam Ediyor"),
                            notes_core::model::property::SelectOption::new("Tamamlandı"),
                        ]),
                    DatabasePropertyDefinition::new("Öncelik", PropertyType::Select)
                        .with_options(vec![
                            notes_core::model::property::SelectOption::new("Düşük"),
                            notes_core::model::property::SelectOption::new("Orta"),
                            notes_core::model::property::SelectOption::new("Yüksek"),
                        ]),
                    DatabasePropertyDefinition::new("Bitiş Tarihi", PropertyType::Date),
                ];
                let s = cmd_create_database(state, page_id, default_props)?;
                let _ = cmd_create_database_view(state, s.id, "Kanban Panosu".into(), ViewType::Board);
                let _ = cmd_create_database_view(state, s.id, "Takvim Görünümü".into(), ViewType::Calendar);
                s
            }
        };

        let views = cmd_list_database_views(state, schema.id).unwrap_or_default();
        let default_view_id = views.first().map(|v| v.id).unwrap_or_default();

        let rows = if default_view_id != Uuid::nil() {
            cmd_query_database_view(state, schema.id, default_view_id)
                .map(|r| r.rows)
                .unwrap_or_default()
        } else {
            Vec::new()
        };

        self.schema = Some(schema);
        self.views = views;
        self.rows = rows;

        Ok(())
    }

    /// Satırları yeniden sorgular.
    pub fn reload_rows(&mut self, state: &DesktopAppState) {
        if let Some(ref schema) = self.schema {
            if let Some(view) = self.views.iter().find(|v| v.view_type == self.active_view_type).or_else(|| self.views.first()) {
                if let Ok(res) = cmd_query_database_view(state, schema.id, view.id) {
                    self.rows = res.rows;
                }
            }
        }
    }

    /// Yeni bir satır ekler.
    pub fn add_row(
        &mut self,
        state: &DesktopAppState,
        title: &str,
        status: &str,
        priority: &str,
    ) -> Result<(), AppError> {
        if let Some(page_id) = self.page_id {
            let trimmed = title.trim();
            let final_title = if trimmed.is_empty() { "Başlıksız Kayıt" } else { trimmed };

            let props = serde_json::json!({
                "Durum": status,
                "Öncelik": priority,
                "Bitiş Tarihi": chrono::Local::now().format("%Y-%m-%d").to_string(),
            });

            cmd_insert_database_row(state, page_id, final_title, props)?;
            self.reload_rows(state);
            self.new_row_title.clear();
        }
        Ok(())
    }

    /// Satırın durumunu günceller.
    pub fn update_row_status(
        &mut self,
        state: &DesktopAppState,
        row_page_id: Uuid,
        new_status: &str,
    ) -> Result<(), AppError> {
        if let Some(row) = self.rows.iter_mut().find(|r| r.page_id == row_page_id) {
            let mut props = row.properties.clone();
            if let serde_json::Value::Object(ref mut map) = props {
                map.insert("Durum".to_string(), serde_json::Value::String(new_status.to_string()));
            }
            cmd_update_database_row(state, row_page_id, None, Some(props))?;
            self.reload_rows(state);
        }
        Ok(())
    }

    /// Satırın önceliğini günceller.
    pub fn update_row_priority(
        &mut self,
        state: &DesktopAppState,
        row_page_id: Uuid,
        new_priority: &str,
    ) -> Result<(), AppError> {
        if let Some(row) = self.rows.iter_mut().find(|r| r.page_id == row_page_id) {
            let mut props = row.properties.clone();
            if let serde_json::Value::Object(ref mut map) = props {
                map.insert("Öncelik".to_string(), serde_json::Value::String(new_priority.to_string()));
            }
            cmd_update_database_row(state, row_page_id, None, Some(props))?;
            self.reload_rows(state);
        }
        Ok(())
    }

    /// Satırı siler.
    pub fn delete_row(&mut self, state: &DesktopAppState, row_page_id: Uuid) -> Result<(), AppError> {
        cmd_delete_database_row(state, row_page_id)?;
        self.reload_rows(state);
        Ok(())
    }

    /// Veritabanı görünümünü render eder.
    pub fn render(&mut self, ui: &mut Ui, state: &DesktopAppState) {
        if self.page_id.is_none() {
            ui.label("Veritabanı seçilmedi.");
            return;
        }

        // --- 1. Üst Kontrol & Sekme Çubuğu ---
        ui.horizontal(|ui| {
            let is_table = self.active_view_type == ViewType::Table;
            let is_board = self.active_view_type == ViewType::Board;
            let is_calendar = self.active_view_type == ViewType::Calendar;

            if ui.selectable_label(is_table, "⊞ Tablo").clicked() {
                self.active_view_type = ViewType::Table;
                self.reload_rows(state);
            }
            if ui.selectable_label(is_board, "▥ Kanban Panosu").clicked() {
                self.active_view_type = ViewType::Board;
                self.reload_rows(state);
            }
            if ui.selectable_label(is_calendar, "📅 Takvim").clicked() {
                self.active_view_type = ViewType::Calendar;
                self.reload_rows(state);
            }

            ui.separator();

            // Arama Kutusu
            ui.label("🔍");
            ui.add(
                egui::TextEdit::singleline(&mut self.search_query)
                    .hint_text("Kayıtlarda ara...")
                    .desired_width(180.0),
            );

            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.button("+ Yeni Kayıt Ekle").clicked() {
                    let _ = self.add_row(state, "Yeni Görev", "Yapılacak", "Orta");
                }
            });
        });

        ui.add_space(8.0);

        // Arama filtresi uygula
        let filter_q = self.search_query.trim().to_lowercase();
        let filtered_rows: Vec<DatabaseRow> = self
            .rows
            .iter()
            .filter(|r| {
                if filter_q.is_empty() {
                    true
                } else {
                    r.title.to_lowercase().contains(&filter_q)
                        || r.properties.to_string().to_lowercase().contains(&filter_q)
                }
            })
            .cloned()
            .collect();

        // --- 2. Seçili Görünüme Göre İçerik ---
        match self.active_view_type {
            ViewType::Table => {
                self.render_table_view(ui, state, &filtered_rows);
            }
            ViewType::Board => {
                self.render_board_view(ui, state, &filtered_rows);
            }
            ViewType::Calendar => {
                self.render_calendar_view(ui, state, &filtered_rows);
            }
            _ => {
                self.render_table_view(ui, state, &filtered_rows);
            }
        }
    }

    fn render_table_view(&mut self, ui: &mut Ui, state: &DesktopAppState, rows: &[DatabaseRow]) {
        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .show(ui, |ui| {
                Frame::none()
                    .fill(Color32::from_rgb(26, 28, 35))
                    .rounding(6.0)
                    .inner_margin(Margin::same(10.0))
                    .show(ui, |ui| {
                        // Tablo Başlığı
                        ui.horizontal(|ui| {
                            ui.label(RichText::new("Başlık").strong().size(13.0));
                            ui.add_space(180.0);
                            ui.label(RichText::new("Durum").strong().size(13.0));
                            ui.add_space(80.0);
                            ui.label(RichText::new("Öncelik").strong().size(13.0));
                            ui.add_space(60.0);
                            ui.label(RichText::new("Bitiş Tarihi").strong().size(13.0));
                            ui.add_space(60.0);
                            ui.label(RichText::new("İşlemler").strong().size(13.0));
                        });

                        ui.separator();

                        let mut action_status = None;
                        let mut action_priority = None;
                        let mut action_delete = None;
                        let mut action_navigate = None;

                        if rows.is_empty() {
                            ui.add_space(15.0);
                            ui.label(
                                RichText::new("Bu görünümde henüz kayıt bulunmuyor.")
                                    .color(Color32::from_gray(140))
                                    .italics(),
                            );
                        }

                        for row in rows {
                            ui.horizontal(|ui| {
                                // Başlık (tıklanabilir alt sayfa açar)
                                let title_btn = ui.button(
                                    RichText::new(format!("📄 {}", row.title))
                                        .color(Color32::from_rgb(100, 180, 255)),
                                );
                                if title_btn.clicked() {
                                    action_navigate = Some(row.page_id);
                                }

                                ui.add_space(10.0);

                                // Durum Seçici
                                let status_val = row
                                    .properties
                                    .get("Durum")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("Yapılacak");

                                let status_color = match status_val {
                                    "Tamamlandı" => Color32::from_rgb(80, 190, 110),
                                    "Devam Ediyor" => Color32::from_rgb(220, 160, 50),
                                    _ => Color32::from_rgb(170, 175, 190),
                                };

                                let next_status = match status_val {
                                    "Yapılacak" => "Devam Ediyor",
                                    "Devam Ediyor" => "Tamamlandı",
                                    _ => "Yapılacak",
                                };

                                if ui
                                    .button(
                                        RichText::new(format!("● {}", status_val))
                                            .color(status_color)
                                            .size(12.0),
                                    )
                                    .clicked()
                                {
                                    action_status = Some((row.page_id, next_status.to_string()));
                                }

                                ui.add_space(10.0);

                                // Öncelik Seçici
                                let priority_val = row
                                    .properties
                                    .get("Öncelik")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("Orta");

                                let priority_color = match priority_val {
                                    "Yüksek" => Color32::from_rgb(230, 80, 80),
                                    "Orta" => Color32::from_rgb(220, 180, 60),
                                    _ => Color32::from_rgb(120, 170, 210),
                                };

                                let next_priority = match priority_val {
                                    "Düşük" => "Orta",
                                    "Orta" => "Yüksek",
                                    _ => "Düşük",
                                };

                                if ui
                                    .button(
                                        RichText::new(priority_val)
                                            .color(priority_color)
                                            .size(12.0),
                                    )
                                    .clicked()
                                {
                                    action_priority = Some((row.page_id, next_priority.to_string()));
                                }

                                ui.add_space(10.0);

                                // Tarih
                                let date_val = row
                                    .properties
                                    .get("Bitiş Tarihi")
                                    .and_then(|v| v.as_str())
                                    .unwrap_or("-");
                                ui.label(RichText::new(date_val).size(12.0).color(Color32::from_gray(170)));

                                ui.add_space(10.0);

                                // Sil Butonu
                                if ui.button(RichText::new("🗑").size(12.0)).clicked() {
                                    action_delete = Some(row.page_id);
                                }
                            });
                            ui.separator();
                        }

                        // Hızlı Yeni Satır Ekleme Çubuğu
                        ui.add_space(4.0);
                        ui.horizontal(|ui| {
                            ui.add(
                                egui::TextEdit::singleline(&mut self.new_row_title)
                                    .hint_text("+ Yeni satır ekle...")
                                    .desired_width(260.0),
                            );
                            if ui.button("Ekle").clicked() && !self.new_row_title.trim().is_empty() {
                                let title = self.new_row_title.clone();
                                let _ = self.add_row(state, &title, "Yapılacak", "Orta");
                            }
                        });

                        // Eylemleri uygula
                        if let Some((id, status)) = action_status {
                            let _ = self.update_row_status(state, id, &status);
                        }
                        if let Some((id, priority)) = action_priority {
                            let _ = self.update_row_priority(state, id, &priority);
                        }
                        if let Some(id) = action_delete {
                            let _ = self.delete_row(state, id);
                        }
                        if let Some(id) = action_navigate {
                            self.selected_row_for_navigation = Some(id);
                        }
                    });
            });
    }

    fn render_board_view(&mut self, ui: &mut Ui, state: &DesktopAppState, rows: &[DatabaseRow]) {
        let columns = ["Yapılacak", "Devam Ediyor", "Tamamlandı"];
        let avail_width = ui.available_width();
        let col_width = (avail_width - 32.0) / 3.0;

        let mut action_status = None;
        let mut action_delete = None;
        let mut action_navigate = None;
        let mut add_to_status = None;

        ui.horizontal(|ui| {
            for &col_status in &columns {
                let col_rows: Vec<&DatabaseRow> = rows
                    .iter()
                    .filter(|r| {
                        r.properties
                            .get("Durum")
                            .and_then(|v| v.as_str())
                            .unwrap_or("Yapılacak")
                            == col_status
                    })
                    .collect();

                let col_color = match col_status {
                    "Tamamlandı" => Color32::from_rgb(80, 190, 110),
                    "Devam Ediyor" => Color32::from_rgb(220, 160, 50),
                    _ => Color32::from_rgb(120, 160, 220),
                };

                ui.allocate_ui_with_layout(
                    egui::vec2(col_width, ui.available_height()),
                    egui::Layout::top_down(egui::Align::Min),
                    |ui| {
                        // Kolon Başlığı
                        Frame::none()
                            .fill(Color32::from_rgb(30, 32, 40))
                            .rounding(4.0)
                            .inner_margin(Margin::symmetric(8.0, 6.0))
                            .show(ui, |ui| {
                                ui.horizontal(|ui| {
                                    ui.label(
                                        RichText::new(col_status)
                                            .strong()
                                            .color(col_color)
                                            .size(13.0),
                                    );
                                    ui.label(
                                        RichText::new(format!("({})", col_rows.len()))
                                            .color(Color32::from_gray(140))
                                            .size(12.0),
                                    );
                                });
                            });

                        ui.add_space(6.0);

                        // Kartlar Listesi
                        egui::ScrollArea::vertical()
                            .id_salt(format!("kanban_col_{}", col_status))
                            .auto_shrink([false, false])
                            .show(ui, |ui| {
                                for row in col_rows {
                                    Frame::none()
                                        .fill(Color32::from_rgb(38, 41, 52))
                                        .rounding(6.0)
                                        .stroke(Stroke::new(1.0, Color32::from_rgb(52, 56, 70)))
                                        .inner_margin(Margin::same(8.0))
                                        .show(ui, |ui| {
                                            ui.horizontal(|ui| {
                                                let card_btn = ui.button(
                                                    RichText::new(&row.title)
                                                        .strong()
                                                        .color(Color32::from_rgb(225, 230, 240)),
                                                );
                                                if card_btn.clicked() {
                                                    action_navigate = Some(row.page_id);
                                                }
                                                ui.with_layout(
                                                    egui::Layout::right_to_left(egui::Align::Center),
                                                    |ui| {
                                                        if ui.button("🗑").clicked() {
                                                            action_delete = Some(row.page_id);
                                                        }
                                                    },
                                                );
                                            });

                                            ui.add_space(4.0);

                                            // Öncelik ve Tarih Bilgisi
                                            ui.horizontal(|ui| {
                                                let priority = row
                                                    .properties
                                                    .get("Öncelik")
                                                    .and_then(|v| v.as_str())
                                                    .unwrap_or("Orta");
                                                let p_color = match priority {
                                                    "Yüksek" => Color32::from_rgb(220, 90, 90),
                                                    "Orta" => Color32::from_rgb(210, 160, 60),
                                                    _ => Color32::from_rgb(120, 180, 210),
                                                };
                                                ui.label(
                                                    RichText::new(priority)
                                                        .size(11.0)
                                                        .color(p_color)
                                                        .strong(),
                                                );

                                                if let Some(date) = row
                                                    .properties
                                                    .get("Bitiş Tarihi")
                                                    .and_then(|v| v.as_str())
                                                {
                                                    ui.label(
                                                        RichText::new(format!("📅 {}", date))
                                                            .size(11.0)
                                                            .color(Color32::from_gray(140)),
                                                    );
                                                }
                                            });

                                            ui.add_space(4.0);

                                            // Taşıma Butonları (← / →)
                                            ui.horizontal(|ui| {
                                                if col_status == "Devam Ediyor" || col_status == "Tamamlandı" {
                                                    let prev = if col_status == "Tamamlandı" { "Devam Ediyor" } else { "Yapılacak" };
                                                    if ui.button(format!("← {}", prev)).clicked() {
                                                        action_status = Some((row.page_id, prev.to_string()));
                                                    }
                                                }
                                                if col_status == "Yapılacak" || col_status == "Devam Ediyor" {
                                                    let next = if col_status == "Yapılacak" { "Devam Ediyor" } else { "Tamamlandı" };
                                                    if ui.button(format!("{} →", next)).clicked() {
                                                        action_status = Some((row.page_id, next.to_string()));
                                                    }
                                                }
                                            });
                                        });

                                    ui.add_space(6.0);
                                }

                                // Kolon altına hızlı kart ekle butonu
                                if ui.button(format!("+ {} Kartı Ekle", col_status)).clicked() {
                                    add_to_status = Some(col_status.to_string());
                                }
                            });
                    },
                );

                ui.separator();
            }
        });

        if let Some((id, status)) = action_status {
            let _ = self.update_row_status(state, id, &status);
        }
        if let Some(id) = action_delete {
            let _ = self.delete_row(state, id);
        }
        if let Some(id) = action_navigate {
            self.selected_row_for_navigation = Some(id);
        }
        if let Some(status) = add_to_status {
            let _ = self.add_row(state, "Yeni Kart", &status, "Orta");
        }
    }

    fn render_calendar_view(&mut self, ui: &mut Ui, state: &DesktopAppState, rows: &[DatabaseRow]) {
        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .show(ui, |ui| {
                Frame::none()
                    .fill(Color32::from_rgb(26, 28, 35))
                    .rounding(6.0)
                    .inner_margin(Margin::same(12.0))
                    .show(ui, |ui| {
                        ui.horizontal(|ui| {
                            ui.label(RichText::new("📅 Takvim ve Zaman Çizelgesi").strong().size(15.0));
                            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                                if ui.button("+ Takvime Etkinlik Ekle").clicked() {
                                    let _ = self.add_row(state, "Yeni Takvim Görevi", "Yapılacak", "Orta");
                                }
                            });
                        });

                        ui.add_space(8.0);
                        ui.separator();

                        if rows.is_empty() {
                            ui.add_space(20.0);
                            ui.label(RichText::new("Takvime bağlı kayıt bulunamadı.").color(Color32::from_gray(140)).italics());
                        }

                        // Tarihe göre sıralı listeleme
                        let mut sorted_rows = rows.to_vec();
                        sorted_rows.sort_by_key(|r| {
                            r.properties
                                .get("Bitiş Tarihi")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string()
                        });

                        for row in sorted_rows {
                            let date_str = row
                                .properties
                                .get("Bitiş Tarihi")
                                .and_then(|v| v.as_str())
                                .unwrap_or("Tarihsiz");

                            let status_str = row
                                .properties
                                .get("Durum")
                                .and_then(|v| v.as_str())
                                .unwrap_or("Yapılacak");

                            ui.horizontal(|ui| {
                                Frame::none()
                                    .fill(Color32::from_rgb(45, 49, 62))
                                    .rounding(4.0)
                                    .inner_margin(Margin::symmetric(6.0, 3.0))
                                    .show(ui, |ui| {
                                        ui.label(RichText::new(format!("📅 {}", date_str)).size(12.0).color(Color32::from_rgb(220, 180, 100)));
                                    });

                                ui.add_space(8.0);

                                if ui.button(RichText::new(&row.title).strong().color(Color32::from_rgb(110, 180, 255))).clicked() {
                                    self.selected_row_for_navigation = Some(row.page_id);
                                }

                                ui.label(RichText::new(format!("({})", status_str)).size(12.0).color(Color32::from_gray(140)));
                            });
                            ui.separator();
                        }
                    });
            });
    }
}
