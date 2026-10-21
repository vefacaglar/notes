use std::time::Instant;
use egui::{Color32, RichText, Ui};
use uuid::Uuid;

use crate::commands::pages::{cmd_get_page, cmd_get_page_markdown, cmd_save_page_markdown, cmd_update_page};
use crate::state::{AppError, DesktopAppState};
use crate::ui::markdown_preview::{render_markdown_preview, toggle_task_checkbox_in_markdown, PreviewAction};

/// Editörün 3 farklı görünüm modu.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EditorViewMode {
    /// Tam ekran akıcı metin editörü (tüm metin seçilebilir, hızlı yazım)
    Edit,
    /// Solda canlı editör, sağda pulldown-cmark ile gerçek zamanlı zengin önizleme
    Split,
    /// Notion benzeri temiz zengin okuma ve interaktif görev kutucukları modu
    Preview,
}

/// Sayfa Markdown editör çalışma zamanı durumu.
pub struct EditorState {
    pub page_id: Option<Uuid>,
    pub title: String,
    pub icon: Option<String>,
    pub markdown: String,
    pub view_mode: EditorViewMode,
    pub is_dirty: bool,
    pub last_saved: Option<Instant>,
    pub last_edit: Option<Instant>,
    pub show_slash_menu: bool,
    pub slash_query: String,
    pub status_message: Option<(String, Instant)>,
}

impl Default for EditorState {
    fn default() -> Self {
        Self {
            page_id: None,
            title: String::new(),
            icon: Some("📄".to_string()),
            markdown: String::new(),
            view_mode: EditorViewMode::Edit,
            is_dirty: false,
            last_saved: None,
            last_edit: None,
            show_slash_menu: false,
            slash_query: String::new(),
            status_message: None,
        }
    }
}

impl EditorState {
    /// Yeni boş bir `EditorState` oluşturur.
    pub fn new() -> Self {
        Self::default()
    }

    /// Belirtilen sayfayı ve ilişkili Markdown gövdesini SQLite deposundan yükler.
    pub fn load_page(&mut self, state: &DesktopAppState, page_id: Uuid) -> Result<(), AppError> {
        let page = cmd_get_page(state, page_id)?;
        let md = cmd_get_page_markdown(state, page_id)?;

        self.page_id = Some(page.id);
        self.title = page.title;
        self.icon = page.icon.or_else(|| Some("📄".to_string()));
        self.markdown = md;
        self.is_dirty = false;
        self.last_saved = Some(Instant::now());
        self.last_edit = None;
        self.show_slash_menu = false;
        self.slash_query.clear();
        self.status_message = None;

        Ok(())
    }

    /// Yapılan değişiklikleri şifreli SQLite deposuna, FTS5 indeksine ve outbox'a kaydeder.
    pub fn save(&mut self, state: &DesktopAppState) -> Result<(), AppError> {
        if let Some(page_id) = self.page_id {
            // 1. Sayfa başlık veya ikonunu güncelle
            let _ = cmd_update_page(
                state,
                page_id,
                Some(self.title.clone()),
                self.icon.clone(),
                None,
            )?;

            // 2. Sayfanın markdown gövdesini blok, FTS5 ve outbox'a kaydet
            cmd_save_page_markdown(state, page_id, &self.markdown)?;

            self.is_dirty = false;
            self.last_saved = Some(Instant::now());
            self.last_edit = None;
            self.status_message = Some(("Otomatik kaydedildi ✓".to_string(), Instant::now()));
        }
        Ok(())
    }

    /// Metin içinde yazılan `/komut` tetikleyicilerini anında şablonla değiştirir.
    pub fn check_slash_commands(&mut self) -> bool {
        let replacements = [
            ("/h1 ", "# "),
            ("/h2 ", "## "),
            ("/h3 ", "### "),
            ("/todo ", "- [ ] "),
            ("/bullet ", "- "),
            ("/quote ", "> "),
            ("/code ", "```rust\n// kodunuzu buraya yazın\n```\n"),
            (
                "/table ",
                "| Kolon 1 | Kolon 2 | Kolon 3 |\n| --- | --- | --- |\n| Veri 1 | Veri 2 | Veri 3 |\n",
            ),
            ("/divider ", "---\n"),
            ("/callout ", "> 💡 **Not:** "),
            ("/link ", "[[Sayfa Bağlantısı]] "),
            ("/tag ", "#etiket "),
        ];

        let mut changed = false;
        for (pattern, template) in replacements {
            if self.markdown.contains(pattern) {
                self.markdown = self.markdown.replace(pattern, template);
                changed = true;
            }
        }

        if changed {
            self.is_dirty = true;
            self.last_edit = Some(Instant::now());
        }
        changed
    }

    /// İmlecin veya metnin sonuna biçimlendirme öğesi ekler.
    pub fn insert_snippet(&mut self, snippet: &str) {
        if !self.markdown.ends_with('\n') && !self.markdown.is_empty() {
            self.markdown.push('\n');
        }
        self.markdown.push_str(snippet);
        self.is_dirty = true;
        self.last_edit = Some(Instant::now());
    }

    /// Editör arayüzünü çizer.
    pub fn render(&mut self, ui: &mut Ui, state: &DesktopAppState) -> Vec<PreviewAction> {
        let mut forward_actions = Vec::new();

        if self.page_id.is_none() {
            ui.centered_and_justified(|ui| {
                ui.label(RichText::new("Lütfen kenar çubuğundan bir sayfa seçin veya yeni bir sayfa oluşturun.").size(16.0));
            });
            return forward_actions;
        }

        // --- 1. Üst Başlık & Mod Seçim Çubuğu ---
        ui.horizontal(|ui| {
            // Sayfa Simgesi
            let icon_text = self.icon.as_deref().unwrap_or("📄");
            if ui.button(RichText::new(icon_text).size(20.0)).clicked() {
                // İkon döngüsü (hızlı emoji değiştirici)
                let icons = ["📄", "📝", "💡", "🚀", "📌", "⭐", "🎯", "🔥", "📂", "💼"];
                let current_idx = icons.iter().position(|&x| x == icon_text).unwrap_or(0);
                let next_icon = icons[(current_idx + 1) % icons.len()];
                self.icon = Some(next_icon.to_string());
                self.is_dirty = true;
                self.last_edit = Some(Instant::now());
            }

            // Sayfa Başlığı TextEdit
            let title_edit = egui::TextEdit::singleline(&mut self.title)
                .font(egui::FontId::proportional(22.0))
                .desired_width(ui.available_width() - 320.0);
            if ui.add(title_edit).changed() {
                self.is_dirty = true;
                self.last_edit = Some(Instant::now());
            }

            // Sağ Taraf: Kayıt Durumu & Görünüm Modu Düğmeleri
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                // Mod Seçiciler
                let preview_active = self.view_mode == EditorViewMode::Preview;
                let split_active = self.view_mode == EditorViewMode::Split;
                let edit_active = self.view_mode == EditorViewMode::Edit;

                if ui
                    .selectable_label(preview_active, "👁 Önizleme")
                    .clicked()
                {
                    self.view_mode = EditorViewMode::Preview;
                }

                if ui.selectable_label(split_active, "◫ Bölünmüş").clicked() {
                    self.view_mode = EditorViewMode::Split;
                }

                if ui.selectable_label(edit_active, "✏ Düzenle").clicked() {
                    self.view_mode = EditorViewMode::Edit;
                }

                ui.separator();

                // Kayıt Durum Rozeti
                if self.is_dirty {
                    ui.label(
                        RichText::new("● Kaydedilmemiş değişiklikler")
                            .size(11.5)
                            .color(Color32::from_rgb(230, 160, 60)),
                    );
                } else if let Some((ref msg, instant)) = self.status_message {
                    if instant.elapsed().as_secs() < 3 {
                        ui.label(
                            RichText::new(msg)
                                .size(11.5)
                                .color(Color32::from_rgb(100, 200, 120)),
                        );
                    }
                } else {
                    ui.label(
                        RichText::new("✓ Senkronize")
                            .size(11.5)
                            .color(Color32::from_gray(140)),
                    );
                }
            });
        });

        ui.add_space(6.0);

        // --- 2. Zengin Biçimlendirme & Slash Hızlı Ekleme Araç Çubuğu ---
        egui::Frame::none()
            .fill(Color32::from_rgb(32, 34, 42))
            .rounding(6.0)
            .inner_margin(egui::Margin::symmetric(8.0, 5.0))
            .show(ui, |ui| {
                ui.horizontal_wrapped(|ui| {
                    if ui.button(RichText::new("# H1").strong()).clicked() {
                        self.insert_snippet("# ");
                    }
                    if ui.button(RichText::new("## H2").strong()).clicked() {
                        self.insert_snippet("## ");
                    }
                    if ui.button(RichText::new("### H3").strong()).clicked() {
                        self.insert_snippet("### ");
                    }

                    ui.separator();

                    if ui.button(RichText::new("B").strong()).clicked() {
                        self.insert_snippet("**Kalın Metin**");
                    }
                    if ui.button(RichText::new("I").italics()).clicked() {
                        self.insert_snippet("*İtalik Metin*");
                    }

                    ui.separator();

                    if ui.button("• Liste").clicked() {
                        self.insert_snippet("- Liste maddesi\n");
                    }
                    if ui.button("☑ Todo").clicked() {
                        self.insert_snippet("- [ ] Yeni görev\n");
                    }
                    if ui.button("❝ Alıntı").clicked() {
                        self.insert_snippet("> Önemli bir not veya alıntı\n");
                    }
                    if ui.button("</> Kod").clicked() {
                        self.insert_snippet("```rust\nfn main() {\n    // Kod\n}\n```\n");
                    }
                    if ui.button("⊞ Tablo").clicked() {
                        self.insert_snippet(
                            "| Başlık 1 | Başlık 2 | Başlık 3 |\n| --- | --- | --- |\n| Veri 1 | Veri 2 | Veri 3 |\n",
                        );
                    }

                    ui.separator();

                    if ui
                        .button(RichText::new("🔗 [[Sayfa]]").color(Color32::from_rgb(110, 180, 255)))
                        .clicked()
                    {
                        self.insert_snippet("[[Sayfa Adı]]");
                    }

                    if ui
                        .button(RichText::new("🏷 #etiket").color(Color32::from_rgb(130, 210, 150)))
                        .clicked()
                    {
                        self.insert_snippet("#etiket ");
                    }

                    if ui.button("📎 Ek/Görsel").clicked() {
                        self.insert_snippet("![Görsel Açıklaması](ekler/ornek.png)\n");
                    }

                    ui.separator();

                    // Slash menü tetikleyici
                    if ui
                        .button(RichText::new("⚡ / Slash Menü").color(Color32::from_rgb(240, 190, 80)))
                        .clicked()
                    {
                        self.show_slash_menu = !self.show_slash_menu;
                    }

                    // Manuel Kaydet Butonu
                    if ui.button("💾 Kaydet").clicked() {
                        let _ = self.save(state);
                    }
                });
            });

        // Slash Komut Açılır Popover
        if self.show_slash_menu {
            egui::Window::new("⚡ Hızlı Slash Şablonları")
                .collapsible(false)
                .resizable(false)
                .min_width(280.0)
                .show(ui.ctx(), |ui| {
                    ui.label(RichText::new("Metin içinde /yazarak da hızlıca ekleyebilirsiniz:").size(11.5).color(Color32::from_gray(160)));
                    ui.add_space(4.0);

                    let slash_items = [
                        ("/h1", "Büyük Başlık (H1)", "# "),
                        ("/h2", "Orta Başlık (H2)", "## "),
                        ("/h3", "Küçük Başlık (H3)", "### "),
                        ("/todo", "Yapılacak Görev Listesi", "- [ ] Görev\n"),
                        ("/bullet", "Madde İmli Liste", "- Madde\n"),
                        ("/quote", "Alıntı Bloğu", "> Alıntı metni\n"),
                        ("/code", "Programlama Kod Bloğu", "```rust\n// Kodunuz\n```\n"),
                        ("/table", "Notion Tarzı Markdown Tablosu", "| Kolon 1 | Kolon 2 |\n| --- | --- |\n| Değer 1 | Değer 2 |\n"),
                        ("/divider", "Yatay Ayırıcı Çizgi", "---\n"),
                        ("/callout", "Vurgu / Uyarı Kutusu", "> 💡 **Önemli:** Detaylar buraya\n"),
                    ];

                    for (cmd, label, snippet) in slash_items {
                        if ui.button(format!("{} — {}", cmd, label)).clicked() {
                            self.insert_snippet(snippet);
                            self.show_slash_menu = false;
                        }
                    }

                    ui.separator();
                    if ui.button("Kapat (Esc)").clicked() {
                        self.show_slash_menu = false;
                    }
                });
        }

        ui.add_space(6.0);

        // --- 3. Seçili Moda Göre Gövde Alanı ---
        match self.view_mode {
            EditorViewMode::Edit => {
                egui::ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        let text_edit = egui::TextEdit::multiline(&mut self.markdown)
                            .desired_width(f32::INFINITY)
                            .desired_rows(35)
                            .lock_focus(true)
                            .font(egui::FontId::monospace(14.0));

                        let resp = ui.add(text_edit);
                        if resp.changed() {
                            self.is_dirty = true;
                            self.last_edit = Some(Instant::now());
                            self.check_slash_commands();
                        }
                    });
            }
            EditorViewMode::Split => {
                let avail_width = ui.available_width();
                let col_width = (avail_width - 16.0) / 2.0;

                ui.horizontal(|ui| {
                    // Sol: Canlı Editör
                    ui.allocate_ui_with_layout(
                        egui::vec2(col_width, ui.available_height()),
                        egui::Layout::top_down(egui::Align::Min),
                        |ui| {
                            ui.label(RichText::new("Markdown Kaynağı").size(12.0).color(Color32::from_gray(160)));
                            egui::ScrollArea::vertical()
                                .id_salt("editor_split_left")
                                .auto_shrink([false, false])
                                .show(ui, |ui| {
                                    let text_edit = egui::TextEdit::multiline(&mut self.markdown)
                                        .desired_width(f32::INFINITY)
                                        .desired_rows(35)
                                        .lock_focus(true)
                                        .font(egui::FontId::monospace(13.5));

                                    let resp = ui.add(text_edit);
                                    if resp.changed() {
                                        self.is_dirty = true;
                                        self.last_edit = Some(Instant::now());
                                        self.check_slash_commands();
                                    }
                                });
                        },
                    );

                    ui.separator();

                    // Sağ: Canlı Zengin Önizleme
                    ui.allocate_ui_with_layout(
                        egui::vec2(col_width, ui.available_height()),
                        egui::Layout::top_down(egui::Align::Min),
                        |ui| {
                            ui.label(RichText::new("Zengin Önizleme").size(12.0).color(Color32::from_gray(160)));
                            egui::ScrollArea::vertical()
                                .id_salt("editor_split_right")
                                .auto_shrink([false, false])
                                .show(ui, |ui| {
                                    let actions = render_markdown_preview(ui, &self.markdown);
                                    for act in actions {
                                        if let PreviewAction::ToggleTask(task_idx) = act {
                                            if toggle_task_checkbox_in_markdown(&mut self.markdown, task_idx) {
                                                self.is_dirty = true;
                                                let _ = self.save(state);
                                            }
                                        } else {
                                            forward_actions.push(act);
                                        }
                                    }
                                });
                        },
                    );
                });
            }
            EditorViewMode::Preview => {
                egui::ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .show(ui, |ui| {
                        let actions = render_markdown_preview(ui, &self.markdown);
                        for act in actions {
                            if let PreviewAction::ToggleTask(task_idx) = act {
                                if toggle_task_checkbox_in_markdown(&mut self.markdown, task_idx) {
                                    self.is_dirty = true;
                                    let _ = self.save(state);
                                }
                            } else {
                                forward_actions.push(act);
                            }
                        }
                    });
            }
        }

        // Otomatik kaydetme kontrolü: 1 saniye (1000ms) hareketsizlik sonrasında kaydet
        if self.is_dirty {
            if let Some(last_edit) = self.last_edit {
                if last_edit.elapsed().as_millis() > 1000 {
                    let _ = self.save(state);
                }
            }
        }

        forward_actions
    }
}
