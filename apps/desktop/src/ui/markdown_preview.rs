use egui::{Color32, FontId, RichText, Stroke, Ui};
use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};

/// Önizleme bileşeninden ana arayüze iletilen kullanıcı etkileşimi olayları.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PreviewAction {
    /// `[[Sayfa Başlığı]]` wikilink tıklandığında ilgili sayfaya git
    NavigatePage(String),
    /// `#etiket` rozetine tıklandığında etiketi filtrele/ara
    FilterTag(String),
    /// `- [ ]` görev checkbox'ı tıklandığında ilgili görevi aç/kapat
    ToggleTask(usize),
}

/// Markdown metnindeki belirtilen sıradaki görev kutusunu (`[ ]` <-> `[x]`) değiştirir.
pub fn toggle_task_checkbox_in_markdown(markdown: &mut String, target_index: usize) -> bool {
    let mut current_task_idx = 0;
    let mut new_lines = Vec::new();
    let mut changed = false;

    for line in markdown.lines() {
        let trimmed = line.trim_start();
        let indent = &line[..(line.len() - trimmed.len())];

        if trimmed.starts_with("- [ ] ")
            || trimmed.starts_with("* [ ] ")
            || trimmed.starts_with("+ [ ] ")
        {
            if current_task_idx == target_index {
                let rest = &trimmed[6..];
                new_lines.push(format!("{}- [x] {}", indent, rest));
                changed = true;
            } else {
                new_lines.push(line.to_string());
            }
            current_task_idx += 1;
        } else if trimmed.starts_with("- [x] ")
            || trimmed.starts_with("* [x] ")
            || trimmed.starts_with("+ [x] ")
            || trimmed.starts_with("- [X] ")
            || trimmed.starts_with("* [X] ")
            || trimmed.starts_with("+ [X] ")
        {
            if current_task_idx == target_index {
                let rest = &trimmed[6..];
                new_lines.push(format!("{}- [ ] {}", indent, rest));
                changed = true;
            } else {
                new_lines.push(line.to_string());
            }
            current_task_idx += 1;
        } else {
            new_lines.push(line.to_string());
        }
    }

    if changed {
        *markdown = new_lines.join("\n");
    }
    changed
}

/// Zengin Markdown önizlemesini render eder ve etkileşim aksiyonlarını döndürür.
pub fn render_markdown_preview(ui: &mut Ui, markdown: &str) -> Vec<PreviewAction> {
    let mut actions = Vec::new();

    if markdown.trim().is_empty() {
        ui.vertical_centered(|ui| {
            ui.add_space(30.0);
            ui.label(
                RichText::new("Henüz bir içerik yazılmadı.")
                    .color(Color32::from_gray(140))
                    .italics(),
            );
            ui.label(
                RichText::new("Düzenle veya Bölünmüş moduna geçerek yazmaya başlayın.")
                    .color(Color32::from_gray(120))
                    .size(12.0),
            );
        });
        return actions;
    }

    let mut options = Options::empty();
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_FOOTNOTES);
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TASKLISTS);
    options.insert(Options::ENABLE_SMART_PUNCTUATION);

    let parser = Parser::new_ext(markdown, options);

    let mut task_counter = 0;
    let mut in_heading: Option<HeadingLevel> = None;
    let mut in_code_block = false;
    let mut code_block_lang = String::new();
    let mut code_block_content = String::new();
    let mut in_blockquote = false;
    let mut is_bold = false;
    let mut is_italic = false;
    let mut is_strike = false;

    for event in parser {
        match event {
            Event::Start(tag) => match tag {
                Tag::Heading { level, .. } => {
                    in_heading = Some(level);
                    ui.add_space(8.0);
                }
                Tag::Paragraph => {
                    ui.add_space(4.0);
                }
                Tag::CodeBlock(kind) => {
                    in_code_block = true;
                    code_block_content.clear();
                    code_block_lang = match kind {
                        CodeBlockKind::Fenced(lang) => lang.to_string(),
                        CodeBlockKind::Indented => String::new(),
                    };
                }
                Tag::BlockQuote(_) => {
                    in_blockquote = true;
                }
                Tag::List(_) => {
                    ui.add_space(2.0);
                }
                Tag::Item => {}
                Tag::Emphasis => is_italic = true,
                Tag::Strong => is_bold = true,
                Tag::Strikethrough => is_strike = true,
                _ => {}
            },
            Event::End(tag_end) => match tag_end {
                TagEnd::Heading(_) => {
                    in_heading = None;
                    ui.add_space(6.0);
                }
                TagEnd::Paragraph => {
                    ui.add_space(4.0);
                }
                TagEnd::CodeBlock => {
                    in_code_block = false;
                    render_code_block(ui, &code_block_lang, &code_block_content);
                    code_block_content.clear();
                    ui.add_space(6.0);
                }
                TagEnd::BlockQuote(_) => {
                    in_blockquote = false;
                    ui.add_space(4.0);
                }
                TagEnd::List(_) => {
                    ui.add_space(4.0);
                }
                TagEnd::Item => {}
                TagEnd::Emphasis => is_italic = false,
                TagEnd::Strong => is_bold = false,
                TagEnd::Strikethrough => is_strike = false,
                _ => {}
            },
            Event::TaskListMarker(checked) => {
                let this_task_idx = task_counter;
                task_counter += 1;

                let mut current_checked = checked;
                let cb = ui.checkbox(&mut current_checked, "");
                if cb.clicked() {
                    actions.push(PreviewAction::ToggleTask(this_task_idx));
                }
            }
            Event::Text(text) => {
                if in_code_block {
                    code_block_content.push_str(&text);
                } else if let Some(level) = in_heading {
                    let (font_size, color) = match level {
                        HeadingLevel::H1 => (26.0, Color32::from_rgb(90, 160, 240)),
                        HeadingLevel::H2 => (21.0, Color32::from_rgb(110, 180, 250)),
                        HeadingLevel::H3 => (17.0, Color32::from_rgb(140, 200, 255)),
                        _ => (15.0, Color32::from_rgb(170, 215, 255)),
                    };
                    ui.label(RichText::new(text.as_ref()).size(font_size).strong().color(color));
                } else if in_blockquote {
                    egui::Frame::none()
                        .stroke(Stroke::new(3.0, Color32::from_rgb(90, 150, 220)))
                        .inner_margin(egui::Margin::symmetric(10.0, 4.0))
                        .show(ui, |ui| {
                            let mut rich = RichText::new(text.as_ref())
                                .italics()
                                .color(Color32::from_gray(210));
                            if is_bold {
                                rich = rich.strong();
                            }
                            ui.label(rich);
                        });
                } else {
                    render_inline_text(
                        ui,
                        &text,
                        is_bold,
                        is_italic,
                        is_strike,
                        &mut actions,
                    );
                }
            }
            Event::Code(code) => {
                ui.horizontal_wrapped(|ui| {
                    egui::Frame::none()
                        .fill(Color32::from_rgb(45, 48, 58))
                        .rounding(4.0)
                        .inner_margin(egui::Margin::symmetric(5.0, 2.0))
                        .show(ui, |ui| {
                            ui.label(
                                RichText::new(code.as_ref())
                                    .font(FontId::monospace(13.0))
                                    .color(Color32::from_rgb(230, 180, 100)),
                            );
                        });
                });
            }
            Event::Rule => {
                ui.add_space(8.0);
                ui.separator();
                ui.add_space(8.0);
            }
            Event::SoftBreak | Event::HardBreak => {
                ui.end_row();
            }
            _ => {}
        }
    }

    actions
}

fn render_code_block(ui: &mut Ui, lang: &str, content: &str) {
    egui::Frame::none()
        .fill(Color32::from_rgb(30, 32, 40))
        .rounding(6.0)
        .stroke(Stroke::new(1.0, Color32::from_rgb(55, 60, 75)))
        .inner_margin(egui::Margin::same(10.0))
        .show(ui, |ui| {
            ui.horizontal(|ui| {
                let badge = if lang.is_empty() { "KOD" } else { lang };
                ui.label(
                    RichText::new(badge)
                        .size(11.0)
                        .color(Color32::from_gray(160))
                        .strong(),
                );
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.button("📋 Kopyala").clicked() {
                        ui.output_mut(|o| o.copied_text = content.to_string());
                    }
                });
            });
            ui.add_space(4.0);
            ui.label(
                RichText::new(content.trim_end())
                    .font(FontId::monospace(12.5))
                    .color(Color32::from_rgb(220, 225, 235)),
            );
        });
}

fn render_inline_text(
    ui: &mut Ui,
    text: &str,
    is_bold: bool,
    is_italic: bool,
    is_strike: bool,
    actions: &mut Vec<PreviewAction>,
) {
    // Wikilink [[Sayfa]] veya #etiket tespiti
    if text.contains("[[") && text.contains("]]") {
        render_text_with_wikilinks(ui, text, actions);
        return;
    }

    if text.contains('#') {
        render_text_with_tags(ui, text, actions);
        return;
    }

    let mut rich = RichText::new(text);
    if is_bold {
        rich = rich.strong();
    }
    if is_italic {
        rich = rich.italics();
    }
    if is_strike {
        rich = rich.strikethrough();
    }
    ui.label(rich);
}

fn render_text_with_wikilinks(ui: &mut Ui, text: &str, actions: &mut Vec<PreviewAction>) {
    ui.horizontal_wrapped(|ui| {
        let mut rest = text;
        while let Some(start_idx) = rest.find("[[") {
            let before = &rest[..start_idx];
            if !before.is_empty() {
                ui.label(before);
            }
            if let Some(end_idx) = rest[start_idx..].find("]]") {
                let link_target = &rest[start_idx + 2..start_idx + end_idx];
                let btn = ui.button(
                    RichText::new(format!("🔗 {}", link_target))
                        .color(Color32::from_rgb(90, 160, 240))
                        .strong(),
                );
                if btn.clicked() {
                    actions.push(PreviewAction::NavigatePage(link_target.to_string()));
                }
                rest = &rest[start_idx + end_idx + 2..];
            } else {
                ui.label(&rest[start_idx..]);
                rest = "";
                break;
            }
        }
        if !rest.is_empty() {
            ui.label(rest);
        }
    });
}

fn render_text_with_tags(ui: &mut Ui, text: &str, actions: &mut Vec<PreviewAction>) {
    ui.horizontal_wrapped(|ui| {
        for word in text.split_whitespace() {
            if word.starts_with('#') && word.len() > 1 {
                let tag_name = word.trim_start_matches('#');
                let btn = ui.button(
                    RichText::new(format!("#{}", tag_name))
                        .size(12.0)
                        .color(Color32::from_rgb(130, 200, 140)),
                );
                if btn.clicked() {
                    actions.push(PreviewAction::FilterTag(tag_name.to_string()));
                }
            } else {
                ui.label(word);
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_toggle_task_checkbox_in_markdown() {
        let mut md = "- [ ] İlk görev\n- [x] İkinci görev\n- [ ] Üçüncü görev".to_string();

        // 1. İlk görevi aç (toggle 0)
        assert!(toggle_task_checkbox_in_markdown(&mut md, 0));
        assert!(md.contains("- [x] İlk görev"));

        // 2. İkinci görevi kapat (toggle 1)
        assert!(toggle_task_checkbox_in_markdown(&mut md, 1));
        assert!(md.contains("- [ ] İkinci görev"));

        // 3. Olmayan indeks değiştirilmemeli
        assert!(!toggle_task_checkbox_in_markdown(&mut md, 99));
    }
}
