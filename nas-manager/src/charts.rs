//! Petits graphiques dessines a la main (barres et courbes), sans dependance.

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use eframe::egui::{self, Color32, Pos2, Rect, Stroke, StrokeKind};

/// Barres verticales ; chaque barre : (etiquette sous l'axe, valeur, couleur, infobulle)
pub fn bars(ui: &mut egui::Ui, items: &[(String, f64, Color32, String)], height: f32, unit: &dyn Fn(f64) -> String) {
    let width = ui.available_width();
    let (resp, painter) = ui.allocate_painter(egui::vec2(width, height + 34.0), egui::Sense::hover());
    let r = resp.rect;
    let plot = Rect::from_min_max(Pos2::new(r.left() + 56.0, r.top() + 6.0), Pos2::new(r.right() - 6.0, r.top() + height));
    let vis = ui.visuals();
    let grid = vis.widgets.noninteractive.bg_stroke.color;
    let text = vis.weak_text_color();
    let max = items.iter().map(|i| i.1).fold(0.0_f64, f64::max).max(1e-9);
    // graduations
    for k in 0..=4 {
        let v = max * k as f64 / 4.0;
        let y = plot.bottom() - plot.height() * k as f32 / 4.0;
        painter.line_segment([Pos2::new(plot.left(), y), Pos2::new(plot.right(), y)], Stroke::new(0.5, grid));
        painter.text(Pos2::new(plot.left() - 6.0, y), egui::Align2::RIGHT_CENTER, unit(v), egui::FontId::proportional(10.5), text);
    }
    if items.is_empty() {
        painter.text(plot.center(), egui::Align2::CENTER_CENTER, tr("Pas encore de données"), egui::FontId::proportional(13.0), text);
        return;
    }
    let n = items.len() as f32;
    let slot = plot.width() / n;
    let bw = (slot * 0.7).clamp(2.0, 28.0);
    let hover = resp.hover_pos();
    let label_every = ((n / 10.0).ceil() as usize).max(1);
    for (i, (lab, v, col, tip)) in items.iter().enumerate() {
        let cx = plot.left() + slot * (i as f32 + 0.5);
        let h = (plot.height() as f64 * (v / max)) as f32;
        let bar = Rect::from_min_max(Pos2::new(cx - bw / 2.0, plot.bottom() - h.max(1.0)), Pos2::new(cx + bw / 2.0, plot.bottom()));
        let hovered = hover.map(|p| p.x >= cx - slot / 2.0 && p.x < cx + slot / 2.0 && plot.expand(4.0).contains(Pos2::new(p.x, p.y.min(plot.bottom())))).unwrap_or(false);
        painter.rect_filled(bar, 2.0, if hovered { col.gamma_multiply(1.3) } else { *col });
        if i % label_every == 0 {
            painter.text(Pos2::new(cx, plot.bottom() + 4.0), egui::Align2::CENTER_TOP, lab, egui::FontId::proportional(10.0), text);
        }
        if hovered && !tip.is_empty() {
            resp.clone().on_hover_text_at_pointer(tip);
        }
    }
    painter.rect_stroke(plot, 0.0, Stroke::new(0.5, grid), StrokeKind::Inside);
}

pub struct Series {
    pub name: String,
    pub color: Color32,
    pub points: Vec<(f64, f64)>,
}

/// Courbes temps -> valeur ; `limit` : ligne horizontale (capacite) ; `projection` : (serie, t_fin)
pub fn lines(
    ui: &mut egui::Ui,
    series: &[Series],
    height: f32,
    unit: &dyn Fn(f64) -> String,
    x_label: &dyn Fn(f64) -> String,
    y_max: Option<f64>,
) {
    let width = ui.available_width();
    let (resp, painter) = ui.allocate_painter(egui::vec2(width, height + 30.0), egui::Sense::hover());
    let r = resp.rect;
    let plot = Rect::from_min_max(Pos2::new(r.left() + 64.0, r.top() + 6.0), Pos2::new(r.right() - 8.0, r.top() + height));
    let vis = ui.visuals();
    let grid = vis.widgets.noninteractive.bg_stroke.color;
    let text = vis.weak_text_color();
    let pts: Vec<&(f64, f64)> = series.iter().flat_map(|s| s.points.iter()).collect();
    if pts.len() < 2 {
        painter.rect_stroke(plot, 0.0, Stroke::new(0.5, grid), StrokeKind::Inside);
        painter.text(plot.center(), egui::Align2::CENTER_CENTER, tr("Pas encore assez de relevés (un toutes les 6 h)"), egui::FontId::proportional(13.0), text);
        return;
    }
    let x0 = pts.iter().map(|p| p.0).fold(f64::MAX, f64::min);
    let x1 = pts.iter().map(|p| p.0).fold(f64::MIN, f64::max).max(x0 + 1.0);
    let ymax = y_max.unwrap_or_else(|| pts.iter().map(|p| p.1).fold(0.0, f64::max) * 1.1).max(1e-9);
    let tx = |x: f64| plot.left() + ((x - x0) / (x1 - x0)) as f32 * plot.width();
    let ty = |y: f64| plot.bottom() - (y / ymax).clamp(0.0, 1.05) as f32 * plot.height();
    for k in 0..=4 {
        let v = ymax * k as f64 / 4.0;
        let y = ty(v);
        painter.line_segment([Pos2::new(plot.left(), y), Pos2::new(plot.right(), y)], Stroke::new(0.5, grid));
        painter.text(Pos2::new(plot.left() - 6.0, y), egui::Align2::RIGHT_CENTER, unit(v), egui::FontId::proportional(10.5), text);
    }
    for k in 0..=4 {
        let x = x0 + (x1 - x0) * k as f64 / 4.0;
        painter.text(Pos2::new(tx(x), plot.bottom() + 4.0), egui::Align2::CENTER_TOP, x_label(x), egui::FontId::proportional(10.0), text);
    }
    for s in series {
        let line: Vec<Pos2> = s.points.iter().map(|p| Pos2::new(tx(p.0), ty(p.1))).collect();
        if line.len() >= 2 {
            painter.add(egui::Shape::line(line, Stroke::new(2.0, s.color)));
        }
    }
    painter.rect_stroke(plot, 0.0, Stroke::new(0.5, grid), StrokeKind::Inside);
    // valeur au survol
    if let Some(p) = resp.hover_pos() {
        if plot.contains(p) {
            let x = x0 + ((p.x - plot.left()) / plot.width()) as f64 * (x1 - x0);
            painter.line_segment([Pos2::new(p.x, plot.top()), Pos2::new(p.x, plot.bottom())], Stroke::new(0.5, text));
            let mut tip = x_label(x);
            for s in series {
                if let Some(q) = s.points.iter().min_by(|a, b| (a.0 - x).abs().total_cmp(&(b.0 - x).abs())) {
                    tip.push_str(&format!("\n{} : {}", s.name, unit(q.1)));
                }
            }
            resp.on_hover_text_at_pointer(tip);
        }
    }
}

/// Regression lineaire (pente par seconde) sur les points
pub fn slope(points: &[(f64, f64)]) -> Option<f64> {
    if points.len() < 3 {
        return None;
    }
    let n = points.len() as f64;
    let mx = points.iter().map(|p| p.0).sum::<f64>() / n;
    let my = points.iter().map(|p| p.1).sum::<f64>() / n;
    let num: f64 = points.iter().map(|p| (p.0 - mx) * (p.1 - my)).sum();
    let den: f64 = points.iter().map(|p| (p.0 - mx).powi(2)).sum();
    (den > 0.0).then(|| num / den)
}

/// Legende : pastilles de couleur et noms
pub fn legend(ui: &mut egui::Ui, items: &[(String, Color32)]) {
    ui.horizontal_wrapped(|ui| {
        for (n, c) in items {
            let (r, _) = ui.allocate_exact_size(egui::vec2(14.0, 4.0), egui::Sense::hover());
            ui.painter().rect_filled(r, 1.0, *c);
            ui.label(egui::RichText::new(n).small());
            ui.add_space(8.0);
        }
    });
}
