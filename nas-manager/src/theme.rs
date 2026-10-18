//! Apparence : couleurs d'etat, tailles de texte, espacements.

use eframe::egui::{self, Color32, FontFamily, FontId, TextStyle};

pub const OK: Color32 = Color32::from_rgb(46, 160, 87);
pub const WARN: Color32 = Color32::from_rgb(214, 145, 30);
pub const ERR: Color32 = Color32::from_rgb(208, 64, 64);
pub const INFO: Color32 = Color32::from_rgb(52, 120, 220);
pub const IDLE: Color32 = Color32::from_rgb(140, 140, 150);

/// Polices du systeme : Segoe UI (texte) + Segoe UI Symbol / Emoji (icones) sous Windows.
fn load_fonts(ctx: &egui::Context) {
    let windir = std::env::var("WINDIR").unwrap_or_else(|_| "C:\\Windows".into());
    let win = |f: &str| format!("{windir}\\Fonts\\{f}");
    // (nom, fichiers candidats, en tete de liste ?)
    let mut text: Vec<String> = vec![win("segoeui.ttf"), "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf".into()];
    let mut symbols: Vec<String> = vec![
        win("seguisym.ttf"),
        win("seguiemj.ttf"),
        "/usr/share/fonts/truetype/libreoffice/opens___.ttf".into(),
    ];
    if let Ok(extra) = std::env::var("NAS_MANAGER_EXTRA_FONT") {
        symbols.insert(0, extra);
    }
    let mut fonts = egui::FontDefinitions::default();
    let add = |path: &str, first: bool, fonts: &mut egui::FontDefinitions| -> bool {
        let Ok(bytes) = std::fs::read(path) else { return false };
        let name = format!("sys:{path}");
        fonts
            .font_data
            .insert(name.clone(), std::sync::Arc::new(egui::FontData::from_owned(bytes)));
        let fam = fonts.families.entry(FontFamily::Proportional).or_default();
        if first {
            fam.insert(0, name.clone());
        } else {
            fam.push(name.clone());
        }
        // icones aussi disponibles en police a chasse fixe
        fonts.families.entry(FontFamily::Monospace).or_default().push(name);
        true
    };
    // une seule police de texte (la premiere trouvee)
    text.retain(|p| std::path::Path::new(p).exists());
    if let Some(p) = text.first() {
        add(p, true, &mut fonts);
    }
    for p in &symbols {
        add(p, false, &mut fonts);
    }
    ctx.set_fonts(fonts);
}

pub fn apply(ctx: &egui::Context) {
    load_fonts(ctx);
    ctx.all_styles_mut(|style| {
        style.text_styles = [
            (TextStyle::Heading, FontId::new(21.0, FontFamily::Proportional)),
            (TextStyle::Body, FontId::new(14.5, FontFamily::Proportional)),
            (TextStyle::Monospace, FontId::new(13.0, FontFamily::Monospace)),
            (TextStyle::Button, FontId::new(14.5, FontFamily::Proportional)),
            (TextStyle::Small, FontId::new(12.0, FontFamily::Proportional)),
        ]
        .into();
        style.spacing.item_spacing = egui::vec2(8.0, 7.0);
        style.spacing.button_padding = egui::vec2(10.0, 5.0);
        style.spacing.interact_size.y = 26.0;
    });
}

/// Fond discret pour les cartes
pub fn card_frame(ui: &egui::Ui) -> egui::Frame {
    let v = ui.visuals();
    egui::Frame::new()
        .fill(v.faint_bg_color)
        .stroke(egui::Stroke::new(1.0, v.widgets.noninteractive.bg_stroke.color))
        .corner_radius(8.0)
        .inner_margin(egui::Margin::same(12))
}
