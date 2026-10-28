//! Restauration : tout, un element choisi en parcourant le Drive (dechiffre),
//! un fichier de la corbeille du Drive (supprime / ancienne version), ou l'etat
//! d'un dossier a une date precise (corbeille datee ou versions).

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
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

/// Une version d'une sauvegarde versionnee (versions liste)
#[derive(Deserialize, Clone, Debug, Default)]
#[serde(default)]
pub struct Snapshot {
    pub id: String,
    pub court: String,
    pub date: i64,
    pub chemin: String,
    pub fichiers: Option<u64>,
    pub taille: Option<u64>,
    pub ajoute: Option<u64>,
}

/// Dates auxquelles on peut revenir (date plage)
#[derive(Deserialize, Clone, Debug, Default)]
#[serde(default)]
pub struct DateRange {
    /// corbeille, versions ou aucune
    pub methode: String,
    pub min: Option<i64>,
    pub max: Option<i64>,
    pub points: Vec<i64>,
    pub jours: Option<i64>,
}

/// Apercu d'une restauration a une date (date apercu)
#[derive(Deserialize, Clone, Debug, Default)]
#[serde(default)]
pub struct DatePreview {
    pub methode: String,
    pub fichiers: Option<u64>,
    pub octets: Option<u64>,
    pub depuis_corbeille: Option<u64>,
    pub version: Option<String>,
    pub date_version: Option<i64>,
}

#[derive(Clone, Default)]
pub struct RestoreState {
    pub job: String,
    pub source: String,
    pub target: String,
    /// 0 = tout, 1 = parcourir la destination, 2 = corbeille
    pub tab: u8,
    pub has_trash: bool,
    pub path: String,
    pub entries: Vec<DriveEntry>,
    pub loading: bool,
    pub error: String,
    pub selected: Option<String>,
    /// restaurer a l'emplacement d'origine (ecrase les fichiers locaux)
    pub to_origin: bool,
    /// destinations de la sauvegarde ; restauration depuis la n° `dest`
    pub dests: Vec<crate::model::JobDest>,
    pub dest: usize,
    /// sauvegarde versionnee : versions disponibles, version choisie
    pub versions: bool,
    pub snaps: Vec<Snapshot>,
    pub snap: Option<String>,
    pub snaps_loading: bool,
    /// retour a une date (onglet 3, script 2.4+) : possible pour cette sauvegarde
    pub has_date: bool,
    pub day: String,
    pub time: String,
    /// dossier a remettre dans son etat (vide = tout)
    pub folder: String,
    pub range: Option<DateRange>,
    pub range_loading: bool,
    pub preview: Option<DatePreview>,
    pub preview_loading: bool,
    pub date_error: String,
    /// parcourir la destination pour choisir le dossier
    pub date_browse: bool,
}

impl RestoreState {
    pub fn new(j: &crate::model::Job) -> Self {
        let (job, source) = (j.nom.as_str(), j.source.as_str());
        let base = source
            .strip_prefix("/srv/")
            .and_then(|r| r.split('/').next())
            .map(|d| format!("/srv/{d}"))
            .unwrap_or_else(|| source.rsplit_once('/').map(|(a, _)| a.to_string()).unwrap_or_default());
        let stamp = chrono::Local::now().format("%Y-%m-%d_%H%M");
        let hier = chrono::Local::now() - chrono::Duration::days(1);
        RestoreState {
            job: job.into(),
            source: source.into(),
            target: format!("{base}/Restauration/{job}_{stamp}"),
            has_trash: j.mode == "sync" && j.corbeille > 0,
            dests: j.dests(),
            versions: j.versions(),
            has_date: (j.mode == "sync" && j.corbeille > 0) || j.versions(),
            day: hier.format("%Y-%m-%d").to_string(),
            time: "12:00".into(),
            ..Default::default()
        }
    }
}

/// Versions disponibles sur la destination choisie
pub fn load_snaps(app: &mut App) {
    let Some(r) = &mut app.restore else { return };
    r.snaps_loading = true;
    r.snaps.clear();
    r.snap = None;
    r.entries.clear();
    r.error.clear();
    let (job, dest) = (r.job.clone(), r.dest);
    app.exec(
        HostId::Omv,
        tr("Lecture des versions"),
        remote::versions_list(&job, dest),
        180,
        Box::new(move |app, res| {
            let Some(r) = &mut app.restore else { return };
            if r.job != job || r.dest != dest {
                return;
            }
            r.snaps_loading = false;
            match res {
                Ok(o) => match serde_json::from_str::<Vec<Snapshot>>(o.stdout.trim()) {
                    Ok(v) => {
                        r.snap = v.first().map(|s| s.id.clone());
                        r.snaps = v;
                        if r.snaps.is_empty() {
                            r.error = tr("Aucune version sur cette destination pour l'instant.").into();
                        }
                    }
                    Err(_) => r.error = o.text().lines().last().unwrap_or(tr("Lecture impossible")).to_string(),
                },
                Err(e) => r.error = e.to_string(),
            }
            let need = r.tab == 1 && r.snap.is_some();
            if need {
                list(app, String::new());
            }
        }),
    );
}

pub fn snap_label(s: &Snapshot) -> String {
    let mut t = format!("{} · {}", fmt::date(s.date), s.court);
    if let Some(n) = s.fichiers {
        t.push_str(&tf(" · {0} fichiers", &[&n]));
    }
    if let Some(b) = s.taille {
        t.push_str(&format!(" · {}", fmt::bytes(b)));
    }
    t
}

/// Dates possibles pour le retour a une date (destination choisie)
fn load_range(app: &mut App) {
    let Some(r) = &mut app.restore else { return };
    r.range_loading = true;
    r.range = None;
    r.preview = None;
    r.date_error.clear();
    let (job, dest) = (r.job.clone(), r.dest);
    app.exec(
        HostId::Omv,
        tr("Dates disponibles"),
        remote::date_range(&job, dest),
        300,
        Box::new(move |app, res| {
            let Some(r) = &mut app.restore else { return };
            if r.job != job || r.dest != dest {
                return;
            }
            r.range_loading = false;
            match res {
                Ok(o) => match serde_json::from_str::<DateRange>(o.stdout.trim().lines().last().unwrap_or("")) {
                    Ok(v) => r.range = Some(v),
                    Err(_) => r.date_error = o.text().lines().last().unwrap_or(tr("Lecture impossible")).to_string(),
                },
                Err(e) => r.date_error = e.to_string(),
            }
        }),
    );
}

fn date_ts(r: &RestoreState) -> Option<i64> {
    fmt::parse_local(&r.day, &r.time)
}

fn load_preview(app: &mut App) {
    let Some(r) = &mut app.restore else { return };
    let Some(ts) = date_ts(r) else { return };
    r.preview_loading = true;
    r.preview = None;
    r.date_error.clear();
    let (job, dest, folder) = (r.job.clone(), r.dest, r.folder.trim().trim_matches('/').to_string());
    app.exec(
        HostId::Omv,
        tr("Aperçu"),
        remote::date_preview(&job, dest, ts, &folder),
        900,
        Box::new(move |app, res| {
            let Some(r) = &mut app.restore else { return };
            if r.job != job {
                return;
            }
            r.preview_loading = false;
            match res {
                Ok(o) if o.code == 0 => match serde_json::from_str::<DatePreview>(o.stdout.trim().lines().last().unwrap_or("")) {
                    Ok(v) => r.preview = Some(v),
                    Err(_) => r.date_error = o.text().lines().last().unwrap_or(tr("Lecture impossible")).to_string(),
                },
                Ok(o) => r.date_error = o.text().lines().last().unwrap_or("").replace("ERREUR : ", ""),
                Err(e) => r.date_error = e.to_string(),
            }
        }),
    );
}

/// Onglet « À une date »
fn date_tab(ui: &mut egui::Ui, r: &mut RestoreState, nav: &mut Option<String>, preview: &mut bool) {
    ui.label(RichText::new(if r.versions {
        tr("Remet le dossier tel qu'il était à la date choisie : la dernière version enregistrée avant cette date est restaurée.")
    } else {
        tr("Reconstitue le dossier tel qu'il était à la date choisie, grâce à la corbeille datée de la destination : fichiers supprimés depuis, anciennes versions des fichiers modifiés, sans les fichiers créés après.")
    })
    .small());
    match (&r.range, r.range_loading) {
        (_, true) => {
            ui.horizontal(|ui| {
                ui.spinner();
                ui.label(RichText::new(tr("Lecture des dates disponibles…")).small());
            });
        }
        (Some(g), _) if g.methode == "aucune" => {
            ui.colored_label(WARN, tr("Pas de retour à une date pour cette sauvegarde (il faut le mode miroir avec corbeille, ou versionné)."));
        }
        (Some(g), _) => {
            if let Some(min) = g.min {
                let txt = if g.methode == "versions" {
                    tf("Possible du {0} à aujourd'hui ({1} version(s)).", &[&(fmt::date_full(min)), &(g.points.len())])
                } else {
                    tf("Possible du {0} à aujourd'hui (corbeille de {1} jours) · {2} sauvegarde(s) avec des changements.", &[&(fmt::date_full(min)), &(g.jours.unwrap_or(0)), &(g.points.len())])
                };
                ui.label(RichText::new(txt).small().color(INFO));
            } else if g.methode == "versions" {
                ui.colored_label(WARN, tr("Aucune version enregistrée pour l'instant."));
            }
        }
        _ => {}
    }
    ui.horizontal(|ui| {
        ui.label(tr("Date :"));
        let a = ui.add(egui::TextEdit::singleline(&mut r.day).desired_width(95.0).hint_text("AAAA-MM-JJ"));
        ui.label(tr("heure :"));
        let b = ui.add(egui::TextEdit::singleline(&mut r.time).desired_width(50.0).hint_text("HH:MM"));
        if a.changed() || b.changed() {
            r.preview = None;
        }
        for (lab, days) in [(tr("hier"), 1), (tr("il y a 1 semaine"), 7), (tr("il y a 1 mois"), 30)] {
            if ui.small_button(lab).clicked() {
                r.day = (chrono::Local::now() - chrono::Duration::days(days)).format("%Y-%m-%d").to_string();
                r.preview = None;
            }
        }
    });
    let ts = date_ts(r);
    match ts {
        None => {
            ui.colored_label(ERR, tr("Date ou heure invalide (AAAA-MM-JJ et HH:MM)."));
        }
        Some(t) if t > fmt::now() => {
            ui.colored_label(ERR, tr("La date est dans le futur."));
        }
        Some(t) => {
            if let Some(min) = r.range.as_ref().and_then(|g| g.min) {
                if t < min {
                    ui.colored_label(WARN, tr("Date plus ancienne que ce que garde la sauvegarde : le résultat sera incomplet."));
                }
            }
        }
    }
    ui.horizontal(|ui| {
        ui.label(tr("Dossier :"));
        let resp = ui.add(egui::TextEdit::singleline(&mut r.folder).desired_width(300.0).hint_text(tr("vide = toute la sauvegarde")));
        if resp.changed() {
            r.preview = None;
        }
        if !r.versions && ui.small_button(if r.date_browse { tr("Fermer") } else { tr("Choisir…") }).clicked() {
            r.date_browse = !r.date_browse;
            if r.date_browse {
                *nav = Some(String::new());
            }
        }
    });
    if r.date_browse && !r.versions {
        ui.horizontal(|ui| {
            if ui.add_enabled(!r.path.is_empty(), egui::Button::new("\u{E08E}")).on_hover_text(tr("Remonter")).clicked() {
                *nav = Some(r.path.rsplit_once('/').map(|(a, _)| a.to_string()).unwrap_or_default());
            }
            ui.label(RichText::new(if r.path.is_empty() { tr("(racine)").to_string() } else { format!("/{}", r.path) }).strong());
            if r.loading {
                ui.spinner();
            }
        });
        egui::Frame::new().fill(ui.visuals().extreme_bg_color).corner_radius(6.0).inner_margin(egui::Margin::same(6)).show(ui, |ui| {
            egui::ScrollArea::vertical().max_height(160.0).auto_shrink([false, true]).show(ui, |ui| {
                for e in r.entries.iter().filter(|e| e.is_dir) {
                    let full = join(&r.path, &e.name);
                    ui.horizontal(|ui| {
                        if ui.add(egui::Button::selectable(r.folder == full, format!("\u{E24A} {}", e.name)).min_size(egui::vec2(300.0, 0.0))).clicked() {
                            r.folder = full.clone();
                            r.preview = None;
                        }
                        if ui.small_button(tr("Ouvrir")).clicked() {
                            *nav = Some(full.clone());
                        }
                    });
                }
            });
        });
        ui.label(RichText::new(tr("Dossiers présents aujourd'hui ; un dossier supprimé depuis peut être tapé à la main.")).small().weak());
    }
    ui.horizontal(|ui| {
        if r.preview_loading {
            ui.spinner();
            ui.label(RichText::new(tr("Calcul…")).small());
        } else if ui.add_enabled(ts.map(|t| t <= fmt::now()).unwrap_or(false), egui::Button::new(tr("Aperçu"))).clicked() {
            *preview = true;
        }
        if let Some(p) = &r.preview {
            let txt = if p.methode == "versions" {
                tf("Version du {0} ({1})", &[&(p.date_version.map(fmt::date_full).unwrap_or_default()), &(p.version.clone().unwrap_or_default().get(..8).unwrap_or("").to_string())])
            } else {
                tf("{0} fichier(s), {1}, dont {2} repris de la corbeille", &[&(p.fichiers.unwrap_or(0)), &(fmt::bytes(p.octets.unwrap_or(0))), &(p.depuis_corbeille.unwrap_or(0))])
            };
            ui.label(RichText::new(txt).strong().color(INFO));
        }
    });
    if !r.date_error.is_empty() {
        ui.colored_label(WARN, &r.date_error);
    }
}

fn list(app: &mut App, path: String) {
    let Some(r) = &mut app.restore else { return };
    if r.versions && r.snap.is_none() {
        return;
    }
    r.path = path.clone();
    r.loading = true;
    r.error.clear();
    r.entries.clear();
    r.selected = None;
    let (job, trash) = (r.job.clone(), r.tab == 2);
    let script = if r.versions {
        remote::versions_ls(&job, r.dest, r.snap.as_deref().unwrap_or(""), &path)
    } else {
        remote::nb_ls(&job, &path, trash, r.dest)
    };
    app.exec(
        HostId::Omv,
        tr("Lecture de la sauvegarde"),
        script,
        300,
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
                                if trash { tr("La corbeille est vide.").into() } else { tr("Dossier vide ou absent de la destination.").into() }
                            } else {
                                o.text().lines().last().unwrap_or(tr("Lecture impossible")).to_string()
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
    let mut dest_changed = false;
    let mut snap_changed = false;
    let mut reload_snaps = false;
    let mut want_preview = false;
    let date_api = app.omv.status.as_ref().map(|s| s.nb_api >= 9).unwrap_or(false);
    egui::Window::new(RichText::new(if r.versions { tf("Versions de « {0} »", &[&r.job]) } else { tf("Restaurer « {0} »", &[&r.job]) }).strong())
        .id(egui::Id::unique("restore"))
        .collapsible(false)
        .resizable(true)
        .default_width(640.0)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            if r.dests.len() > 1 {
                ui.horizontal(|ui| {
                    ui.label(tr("Depuis la destination :"));
                    let cur = r.dests.get(r.dest).map(|d| d.nom.clone()).unwrap_or_default();
                    egui::ComboBox::from_id_salt("rdest").selected_text(cur).show_ui(ui, |ui| {
                        for (i, d) in r.dests.iter().enumerate() {
                            let lab = if d.chiffre && !r.versions { tf("{0} (chiffrée)", &[&d.nom]) } else { d.nom.clone() };
                            dest_changed |= ui.selectable_value(&mut r.dest, i, lab).changed();
                        }
                    });
                });
            }
            if r.versions {
                ui.horizontal(|ui| {
                    ui.label(tr("Version :"));
                    let cur = r.snaps.iter().find(|s| Some(&s.id) == r.snap.as_ref()).map(snap_label).unwrap_or_else(|| if r.snaps_loading { tr("lecture…").into() } else { "—".into() });
                    egui::ComboBox::from_id_salt("rsnap").width(420.0).selected_text(cur).show_ui(ui, |ui| {
                        for sn in &r.snaps {
                            if ui.selectable_label(Some(&sn.id) == r.snap.as_ref(), snap_label(sn)).clicked() && Some(&sn.id) != r.snap.as_ref() {
                                r.snap = Some(sn.id.clone());
                                snap_changed = true;
                            }
                        }
                    });
                    if r.snaps_loading {
                        ui.spinner();
                    } else if ui.small_button("\u{E094}").on_hover_text(tr("Relire les versions")).clicked() {
                        reload_snaps = true;
                    }
                });
                if !r.snaps.is_empty() {
                    ui.label(RichText::new(tf("{0} version(s) gardée(s), de la plus récente à la plus ancienne.", &[&r.snaps.len()])).small().weak());
                }
            }
            ui.horizontal(|ui| {
                tab_changed |= ui.selectable_value(&mut r.tab, 0, if r.versions { tr("Toute la version") } else { tr("Tout restaurer") }).changed();
                tab_changed |= ui.selectable_value(&mut r.tab, 1, tr("\u{E256} Un fichier ou un dossier")).changed();
                if r.has_trash {
                    tab_changed |= ui.selectable_value(&mut r.tab, 2, tr("\u{E4A6} Corbeille")).changed();
                }
                if r.has_date && date_api {
                    tab_changed |= ui.selectable_value(&mut r.tab, 3, tr("\u{E1A0} À une date")).changed();
                }
            });
            ui.separator();
            if r.tab == 3 {
                date_tab(ui, &mut r, &mut nav, &mut want_preview);
            } else if r.tab == 0 {
                ui.label(if r.versions {
                    tr("Tout le dossier, tel qu'il était à la date de la version choisie, est recopié dans le dossier ci-dessous.")
                } else {
                    tr("Tout le contenu de la sauvegarde est recopié (déchiffré si besoin) dans le dossier ci-dessous.")
                });
            } else {
                if r.tab == 2 {
                    ui.label(RichText::new(tr("Fichiers supprimés ou remplacés par les sauvegardes miroir, rangés par date. Choisis la date puis le fichier.")).small());
                }
                ui.horizontal(|ui| {
                    if ui.add_enabled(!r.path.is_empty(), egui::Button::new("\u{E08E}")).on_hover_text(tr("Remonter")).clicked() {
                        nav = Some(r.path.rsplit_once('/').map(|(a, _)| a.to_string()).unwrap_or_default());
                    }
                    ui.label(RichText::new(if r.path.is_empty() { tr("(racine)").to_string() } else { format!("/{}", r.path) }).strong());
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
                                let label = if e.is_dir { format!("\u{E24A} {}", e.name) } else { format!("\u{E230} {}", e.name) };
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
                                if e.is_dir && ui.small_button(tr("Ouvrir")).clicked() {
                                    nav = Some(full.clone());
                                }
                            });
                        }
                    });
                });
                match &r.selected {
                    Some(s) => {
                        ui.label(RichText::new(tf("Sélection : {0}", &[&s])).strong().color(INFO));
                    }
                    None => {
                        ui.label(RichText::new(tr("Clique sur un élément pour le sélectionner, double-clic pour ouvrir un dossier.")).small().weak());
                    }
                }
            }
            ui.add_space(6.0);
            ui.label(tr("Restaurer dans :"));
            ui.horizontal(|ui| {
                ui.add_enabled(!r.to_origin, egui::TextEdit::singleline(&mut r.target).desired_width(480.0));
                if ui.add_enabled(!r.to_origin, egui::Button::new("\u{E24A}")).clicked() {
                    browse_target = true;
                }
            });
            if r.tab != 2 && r.tab != 3 {
                ui.checkbox(&mut r.to_origin, tr("À son emplacement d'origine sur l'OMV"));
            }
            if r.tab == 3 {
                r.to_origin = false;
            }
            let dest = effective_target(&r);
            if r.to_origin || dest.trim_end_matches('/') == r.source.trim_end_matches('/') {
                ui.colored_label(ERR, tr("\u{E4E0} Les fichiers locaux de même nom seront remplacés par ceux de la sauvegarde."));
            }
            ui.label(RichText::new(tr("La restauration tourne en arrière-plan ; son avancement s'affiche sur la page Sauvegardes.")).small().weak());
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                let can = if r.tab == 3 {
                    date_ts(&r).map(|t| t <= fmt::now()).unwrap_or(false) && r.range.as_ref().map(|g| g.methode != "aucune").unwrap_or(false)
                } else {
                    (r.tab == 0 || r.selected.is_some()) && (!r.versions || r.snap.is_some())
                };
                if ui
                    .add_enabled(can && !dest.trim().is_empty(), egui::Button::new(RichText::new(tr("\u{E20C} Restaurer")).color(Color32::WHITE)).fill(INFO))
                    .clicked()
                {
                    go = true;
                }
                if ui.button(tr("Annuler")).clicked() {
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
    if go && r.tab == 3 {
        let ts = date_ts(&r).unwrap_or(0);
        let folder = r.folder.trim().trim_matches('/').to_string();
        let target = effective_target(&r);
        let label = if folder.is_empty() { r.job.clone() } else { folder.clone() };
        let script = remote::date_restore(&r.job, r.dest, ts, &target, &folder);
        app.ask_confirm(
            tr("Revenir à une date"),
            &tf("« {0} » tel qu'il était le {1} va être recopié dans {2}. Les fichiers actuels ne sont pas modifiés.", &[&label, &(fmt::date_full(ts)), &target]),
            tr("Restaurer"),
            false,
            None,
            Box::new(move |app| app.action_toast(HostId::Omv, tr("Restauration"), script, 30)),
        );
        return;
    }
    if go {
        let item = if r.tab == 0 { String::new() } else { r.selected.clone().unwrap_or_default() };
        let target = effective_target(&r);
        let label = if item.is_empty() { r.job.clone() } else { item.clone() };
        let script = if r.versions {
            remote::versions_restore(&r.job, r.dest, r.snap.as_deref().unwrap_or(""), &target, &item)
        } else {
            remote::nb_restore(&r.job, &target, &item, r.tab == 2, r.dest)
        };
        let overwrite = r.to_origin || target.trim_end_matches('/') == r.source.trim_end_matches('/');
        if overwrite {
            app.ask_confirm(
                tr("Restaurer à l'emplacement d'origine"),
                &tf("« {0} » va être recopié dans {1} : les fichiers locaux de même nom seront remplacés.", &[&label, &target]),
                tr("Restaurer"),
                true,
                None,
                Box::new(move |app| app.action_toast(HostId::Omv, tr("Restauration"), script, 30)),
            );
        } else {
            app.action_toast(HostId::Omv, tr("Restauration"), script, 30);
        }
        return;
    }
    let need_range = r.tab == 3 && (dest_changed || (tab_changed && r.range.is_none())) && !r.range_loading;
    if r.tab == 3 && dest_changed {
        r.preview = None;
    }
    let need_snaps = r.versions && r.tab != 3 && (dest_changed || reload_snaps || (r.snaps.is_empty() && !r.snaps_loading && r.error.is_empty()));
    let need_list = (tab_changed || dest_changed || snap_changed) && r.tab != 0 && r.tab != 3;
    app.restore = Some(r);
    if need_range {
        load_range(app);
    }
    if want_preview {
        load_preview(app);
        return;
    }
    if need_snaps {
        load_snaps(app);
    } else if need_list {
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
