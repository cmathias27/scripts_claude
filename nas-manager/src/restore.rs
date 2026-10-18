//! Restauration : tout, un element choisi en parcourant le Drive (dechiffre),
//! ou un fichier de la corbeille du Drive (supprime / ancienne version).

use crate::app::{App, BrowsePurpose, HostId};
use crate::fmt;
use crate::remote;
use crate::theme::{ERR, INFO, WARN};
use eframe::egui::{self, Color32, RichText};
use serde::Deserialize;

#[derive(Deserialize, Clone, Debug, Default)]
#[serde(default, rename_all = "PascalCase")]
pub struct DriveEntry {
    pub name: String,
    pub size: i64,
    pub mod_time: String,
    pub is_dir: bool,
}

#[derive(Clone, Default)]
pub struct RestoreState {
    pub job: String,
    pub source: String,
    pub target: String,
    /// 0 = tout, 1 = parcourir le Drive, 2 = corbeille
    pub tab: u8,
    pub has_trash: bool,
    pub path: String,
    pub entries: Vec<DriveEntry>,
    pub loading: bool,
    pub error: String,
    pub selected: Option<String>,
    /// restaurer a l'emplacement d'origine (ecrase les fichiers locaux)
    pub to_origin: bool,
}

impl RestoreState {
    pub fn new(job: &str, source: &str, has_trash: bool) -> Self {
        let base = source
            .strip_prefix("/srv/")
            .and_then(|r| r.split('/').next())
            .map(|d| format!("/srv/{d}"))
            .unwrap_or_else(|| source.rsplit_once('/').map(|(a, _)| a.to_string()).unwrap_or_default());
        let stamp = chrono::Local::now().format("%Y-%m-%d_%H%M");
        RestoreState {
            job: job.into(),
            source: source.into(),
            target: format!("{base}/Restauration/{job}_{stamp}"),
            has_trash,
            ..Default::default()
        }
    }
}

fn list(app: &mut App, path: String) {
    let Some(r) = &mut app.restore else { return };
    r.path = path.clone();
    r.loading = true;
    r.error.clear();
    r.entries.clear();
    r.selected = None;
    let (job, trash) = (r.job.clone(), r.tab == 2);
    app.exec(
        HostId::Omv,
        "Lecture du Drive",
        remote::nb_ls(&job, &path, trash),
        120,
        Box::new(move |app, res| {
            let Some(r) = &mut app.restore else { return };
            if r.path != path {
                return;
            }
            r.loading = false;
            match res {
                Ok(o) => {
                    let line = o.stdout.trim();
                    match serde_json::from_str::<Vec<DriveEntry>>(line) {
                        Ok(mut v) => {
                            v.sort_by(|a, b| b.is_dir.cmp(&a.is_dir).then(a.name.to_lowercase().cmp(&b.name.to_lowercase())));
                            r.entries = v;
                        }
                        Err(_) => {
                            r.error = if line.contains("directory not found") {
                                if trash { "La corbeille est vide.".into() } else { "Dossier vide ou absent du Drive.".into() }
                            } else {
                                o.text().lines().last().unwrap_or("Lecture impossible").to_string()
                            }
                        }
                    }
                }
                Err(e) => r.error = e.to_string(),
            }
        }),
    );
}

#[cfg(debug_assertions)]
pub fn demo_list(app: &mut App, path: String) {
    list(app, path);
}

fn join(a: &str, b: &str) -> String {
    if a.is_empty() {
        b.to_string()
    } else {
        format!("{a}/{b}")
    }
}

pub fn window(app: &mut App, ctx: &egui::Context) {
    let Some(mut r) = app.restore.take() else { return };
    let mut open = true;
    let mut go = false;
    let mut cancel = false;
    let mut browse_target = false;
    let mut nav: Option<String> = None;
    let mut tab_changed = false;
    egui::Window::new(RichText::new(format!("Restaurer « {} »", r.job)).strong())
        .id(egui::Id::unique("restore"))
        .collapsible(false)
        .resizable(true)
        .default_width(640.0)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            ui.horizontal(|ui| {
                tab_changed |= ui.selectable_value(&mut r.tab, 0, "Tout restaurer").changed();
                tab_changed |= ui.selectable_value(&mut r.tab, 1, "📂 Un fichier ou un dossier").changed();
                if r.has_trash {
                    tab_changed |= ui.selectable_value(&mut r.tab, 2, "🗑 Corbeille du Drive").changed();
                }
            });
            ui.separator();
            if r.tab == 0 {
                ui.label("Tout le contenu de la sauvegarde est recopié (déchiffré si besoin) dans le dossier ci-dessous.");
            } else {
                if r.tab == 2 {
                    ui.label(RichText::new("Fichiers supprimés ou remplacés par les sauvegardes miroir, rangés par date. Choisis la date puis le fichier.").small());
                }
                ui.horizontal(|ui| {
                    if ui.add_enabled(!r.path.is_empty(), egui::Button::new("⬆")).on_hover_text("Remonter").clicked() {
                        nav = Some(r.path.rsplit_once('/').map(|(a, _)| a.to_string()).unwrap_or_default());
                    }
                    ui.label(RichText::new(if r.path.is_empty() { "(racine)".to_string() } else { format!("/{}", r.path) }).strong());
                    if r.loading {
                        ui.spinner();
                    }
                });
                egui::Frame::new().fill(ui.visuals().extreme_bg_color).corner_radius(6.0).inner_margin(egui::Margin::same(6)).show(ui, |ui| {
                    egui::ScrollArea::vertical().max_height(260.0).auto_shrink([false, true]).show(ui, |ui| {
                        if !r.error.is_empty() {
                            ui.colored_label(WARN, &r.error);
                        }
                        for e in &r.entries {
                            let full = join(&r.path, &e.name);
                            let sel = r.selected.as_deref() == Some(full.as_str());
                            ui.horizontal(|ui| {
                                let label = if e.is_dir { format!("📁 {}", e.name) } else { format!("📄 {}", e.name) };
                                let resp = ui.add(egui::Button::selectable(sel, label).min_size(egui::vec2(330.0, 0.0)));
                                if resp.clicked() {
                                    r.selected = Some(full.clone());
                                }
                                if resp.double_clicked() && e.is_dir {
                                    nav = Some(full.clone());
                                }
                                if !e.is_dir {
                                    ui.label(RichText::new(fmt::bytes(e.size.max(0) as u64)).small().weak());
                                }
                                ui.label(RichText::new(e.mod_time.get(..16).unwrap_or("").replace('T', " ")).small().weak());
                                if e.is_dir && ui.small_button("Ouvrir").clicked() {
                                    nav = Some(full.clone());
                                }
                            });
                        }
                    });
                });
                match &r.selected {
                    Some(s) => {
                        ui.label(RichText::new(format!("Sélection : {s}")).strong().color(INFO));
                    }
                    None => {
                        ui.label(RichText::new("Clique sur un élément pour le sélectionner, double-clic pour ouvrir un dossier.").small().weak());
                    }
                }
            }
            ui.add_space(6.0);
            ui.label("Restaurer dans :");
            ui.horizontal(|ui| {
                ui.add_enabled(!r.to_origin, egui::TextEdit::singleline(&mut r.target).desired_width(480.0));
                if ui.add_enabled(!r.to_origin, egui::Button::new("📁")).clicked() {
                    browse_target = true;
                }
            });
            if r.tab != 2 {
                ui.checkbox(&mut r.to_origin, "À son emplacement d'origine sur l'OMV");
            }
            let dest = effective_target(&r);
            if r.to_origin || dest.trim_end_matches('/') == r.source.trim_end_matches('/') {
                ui.colored_label(ERR, "⚠ Les fichiers locaux de même nom seront remplacés par ceux du Drive.");
            }
            ui.label(RichText::new("La restauration tourne en arrière-plan ; son avancement s'affiche sur la page Sauvegardes.").small().weak());
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                let can = r.tab == 0 || r.selected.is_some();
                if ui
                    .add_enabled(can && !dest.trim().is_empty(), egui::Button::new(RichText::new("📥 Restaurer").color(Color32::WHITE)).fill(INFO))
                    .clicked()
                {
                    go = true;
                }
                if ui.button("Annuler").clicked() {
                    cancel = true;
                }
            });
        });
    if browse_target {
        let start = r.target.rsplit_once('/').map(|(a, _)| a.to_string()).unwrap_or_default();
        app.restore = Some(r);
        app.open_browser(HostId::Omv, BrowsePurpose::RestoreTarget, &start);
        return;
    }
    if !open || cancel {
        return;
    }
    if go {
        let item = if r.tab == 0 { String::new() } else { r.selected.clone().unwrap_or_default() };
        let target = effective_target(&r);
        let label = if item.is_empty() { r.job.clone() } else { item.clone() };
        let script = remote::nb_restore(&r.job, &target, &item, r.tab == 2);
        let overwrite = r.to_origin || target.trim_end_matches('/') == r.source.trim_end_matches('/');
        if overwrite {
            app.ask_confirm(
                "Restaurer à l'emplacement d'origine",
                &format!("« {label} » va être recopié dans {target} : les fichiers locaux de même nom seront remplacés."),
                "Restaurer",
                true,
                None,
                Box::new(move |app| app.action_toast(HostId::Omv, "Restauration", script, 30)),
            );
        } else {
            app.action_toast(HostId::Omv, "Restauration", script, 30);
        }
        return;
    }
    let need_list = tab_changed && r.tab != 0;
    app.restore = Some(r);
    if need_list {
        list(app, String::new());
    } else if let Some(p) = nav {
        list(app, p);
    }
}

/// Dossier ou le fichier / dossier choisi sera recopie
fn effective_target(r: &RestoreState) -> String {
    if r.to_origin && r.tab == 1 {
        // element choisi : dans son dossier d'origine
        let parent = r.selected.as_deref().and_then(|s| s.rsplit_once('/')).map(|(a, _)| a).unwrap_or("");
        if parent.is_empty() {
            r.source.clone()
        } else {
            format!("{}/{parent}", r.source)
        }
    } else if r.to_origin {
        r.source.clone()
    } else {
        r.target.trim().to_string()
    }
}
