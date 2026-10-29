//! Page « Sauvegardes temps réel » : un ou plusieurs dossiers surveillés en continu,
//! chaque changement envoyé au fil de l'eau (moteur `nas-debian temps-reel`).

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::app::{App, BrowsePurpose, HostId, Page};
use crate::fmt;
use crate::model::{OmvStatus, RtJob};
use crate::remote;
use crate::theme::{self, ERR, IDLE, INFO, OK, WARN};
use eframe::egui::{self, Color32, RichText};

/// Intervalles de rattrapage acceptes par le script (minutes, 0 = aucun)
pub const CATCH_CHOICES: [u32; 13] = [0, 5, 10, 15, 20, 30, 60, 120, 180, 240, 360, 720, 1440];

fn catch_label(m: u32) -> String {
    match m {
        0 => tr("aucun").into(),
        m if m < 60 => tf("toutes les {0} min", &[&m]),
        60 => tr("toutes les heures").into(),
        1440 => tr("une fois par jour").into(),
        m => tf("toutes les {0} h", &[&(m / 60)]),
    }
}

/// Destination lisible
pub fn dest_human(dest: &str) -> String {
    let (remote, path) = dest.split_once(':').unwrap_or((dest, ""));
    let path = path.trim_matches('/');
    let join = |base: &str| if path.is_empty() { base.to_string() } else { format!("{base}/{path}") };
    match remote {
        "gbackup" => tf("Drive : {0} (chiffré)", &[&join("NAS-chiffre")]),
        "gcrypt" => tf("Drive : {0} (chiffré)", &[&join("Cam-chiffre")]),
        "gdrive" => tf("Drive : {0}", &[&(if path.is_empty() { "/".to_string() } else { path.to_string() })]),
        _ => dest.to_string(),
    }
}

/// (0 chiffre, 1 en clair, 2 autre) + dossier
fn dest_parts(dest: &str) -> (u8, String) {
    if let Some(p) = dest.strip_prefix("gbackup:") {
        (0, p.trim_matches('/').to_string())
    } else if let Some(p) = dest.strip_prefix("gdrive:NAS/") {
        (1, p.trim_matches('/').to_string())
    } else {
        (2, String::new())
    }
}

pub fn deletion_label(j: &RtJob) -> String {
    match j.suppression.as_str() {
        "directe" => tr("Suppressions directes").into(),
        "corbeille" => tf("Corbeille {0} j", &[&j.corbeille]),
        _ => tr("Copie seule").into(),
    }
}

/// Couleur et texte de l'etat
pub fn state(j: &RtJob) -> (Color32, &'static str) {
    if j.pause.is_some() {
        (ERR, tr("En pause"))
    } else if j.actif {
        (OK, tr("Active"))
    } else if j.demarrage_auto {
        (ERR, tr("Arrêtée (anormal)"))
    } else {
        (IDLE, tr("Arrêtée"))
    }
}

/// Pastille du menu : sauvegardes en pause ou arretees anormalement
pub fn nav_badge(s: &OmvStatus) -> Option<(String, Color32)> {
    let paused = s.temps_reel.iter().filter(|j| j.pause.is_some()).count();
    let down = s.temps_reel.iter().filter(|j| j.pause.is_none() && !j.actif && j.demarrage_auto).count();
    if paused > 0 {
        Some((tf("{0} en pause", &[&paused]), ERR))
    } else if down > 0 || (s.cameras.installe && !s.cameras.actif) {
        Some((tr("arrêtée").into(), ERR))
    } else {
        None
    }
}

// ---------------------------------------------------------------------
//  Formulaire
// ---------------------------------------------------------------------

#[derive(Clone)]
pub struct RtForm {
    pub new: bool,
    pub name: String,
    pub dirs: Vec<String>,
    pub dest_mode: u8,
    pub folder: String,
    pub folder_touched: bool,
    pub dest_raw: String,
    /// 0 directe, 1 corbeille, 2 copie seule
    pub deletion: u8,
    pub trash_days: String,
    pub excl: String,
    pub types: String,
    pub delay: String,
    pub catchup: u32,
    pub anomaly_on: bool,
    pub anomaly: String,
    pub memory: String,
    pub bw: crate::sched::BwEdit,
    pub error: String,
}

impl RtForm {
    pub fn new_default() -> Self {
        Self {
            new: true,
            name: String::new(),
            dirs: Vec::new(),
            dest_mode: 0,
            folder: String::new(),
            folder_touched: false,
            dest_raw: String::new(),
            deletion: 1,
            trash_days: "30".into(),
            excl: String::new(),
            types: String::new(),
            delay: "10".into(),
            catchup: 15,
            anomaly_on: true,
            anomaly: "300".into(),
            memory: String::new(),
            bw: Default::default(),
            error: String::new(),
        }
    }

    pub fn from_job(j: &RtJob) -> Self {
        let (mode, folder) = dest_parts(&j.destination);
        Self {
            new: false,
            name: j.nom.clone(),
            dirs: j.dossiers.iter().map(|d| d.chemin.clone()).collect(),
            dest_mode: mode,
            folder,
            folder_touched: true,
            dest_raw: if mode == 2 { j.destination.clone() } else { String::new() },
            deletion: match j.suppression.as_str() {
                "directe" => 0,
                "corbeille" => 1,
                _ => 2,
            },
            trash_days: if j.corbeille > 0 { j.corbeille.to_string() } else { "30".into() },
            excl: j.exclusions.clone(),
            types: j.types.clone(),
            delay: j.delai.max(1).to_string(),
            catchup: j.rattrapage,
            anomaly_on: j.anomalie > 0,
            anomaly: if j.anomalie > 0 { j.anomalie.to_string() } else { "300".into() },
            memory: j.memoire.clone(),
            bw: crate::sched::BwEdit::parse(&j.debit),
            error: String::new(),
        }
    }

    fn dest(&self) -> Result<String, &'static str> {
        let f = self.folder.trim().trim_matches('/');
        match self.dest_mode {
            0 | 1 => {
                if f.is_empty() || f.contains('|') || f.contains("..") || f.starts_with("_corbeille") {
                    Err(tr("Dossier de destination invalide."))
                } else if self.dest_mode == 0 {
                    Ok(format!("gbackup:{f}"))
                } else {
                    Ok(format!("gdrive:NAS/{f}"))
                }
            }
            _ => {
                let r = self.dest_raw.trim();
                let ok = r.split_once(':').map(|(a, b)| !a.is_empty() && a.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') && !b.contains('|') && !b.contains("..")).unwrap_or(false);
                if ok {
                    Ok(r.to_string())
                } else {
                    Err(tr("Destination invalide : remote:chemin (ex. gdrive:NAS/Photos)."))
                }
            }
        }
    }
}

fn clean_list(s: &str) -> String {
    s.split([';', ',', '\n'])
        .map(|p| p.trim())
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join(";")
}

pub fn form_window(app: &mut App, ctx: &egui::Context) {
    let Some(mut f) = app.rt_form.take() else { return };
    let api11 = app.omv.status.as_ref().map(|s| s.nb_api >= 11).unwrap_or(false);
    let mut open = true;
    let mut save = false;
    let mut cancel = false;
    let mut browse = false;
    egui::Window::new(RichText::new(if f.new { tr("Nouvelle sauvegarde temps réel") } else { tr("Modifier la sauvegarde temps réel") }).strong())
        .id(egui::Id::unique("rtform"))
        .collapsible(false)
        .resizable(false)
        .default_width(600.0)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            egui::ScrollArea::vertical().max_height((ctx.content_rect().height() - 160.0).max(200.0)).show(ui, |ui| {
                egui::Grid::new("rtgrid").num_columns(2).spacing([12.0, 10.0]).show(ui, |ui| {
                    ui.label(tr("Nom"));
                    ui.add_enabled(f.new, egui::TextEdit::singleline(&mut f.name).hint_text(tr("ex : Documents")).desired_width(300.0));
                    ui.end_row();

                    ui.label(tr("Dossiers surveillés"));
                    ui.vertical(|ui| {
                        let mut remove = None;
                        for (i, d) in f.dirs.iter().enumerate() {
                            ui.horizontal(|ui| {
                                ui.label(RichText::new(fmt::short_path(d)).monospace()).on_hover_text(d);
                                if ui.small_button("✕").on_hover_text(tr("Retirer ce dossier")).clicked() {
                                    remove = Some(i);
                                }
                            });
                        }
                        if let Some(i) = remove {
                            f.dirs.remove(i);
                        }
                        if f.dirs.is_empty() {
                            ui.label(RichText::new(tr("Aucun dossier choisi.")).weak());
                        }
                        if ui.button(tr("\u{E24A} Ajouter un dossier…")).clicked() {
                            browse = true;
                        }
                        if f.dirs.len() > 1 {
                            ui.label(RichText::new(tr("Plusieurs dossiers : chacun est envoyé dans un sous-dossier de son nom.")).small().weak());
                        }
                    });
                    ui.end_row();

                    ui.label(tr("Destination"));
                    ui.vertical(|ui| {
                        ui.horizontal(|ui| {
                            ui.radio_value(&mut f.dest_mode, 0, tr("Drive chiffré"));
                            ui.radio_value(&mut f.dest_mode, 1, tr("Drive en clair"));
                            ui.radio_value(&mut f.dest_mode, 2, tr("Autre (remote rclone)"));
                        });
                        if f.dest_mode < 2 {
                            ui.horizontal(|ui| {
                                ui.label(if f.dest_mode == 0 { "NAS-chiffre/" } else { "NAS/" });
                                if ui.add(egui::TextEdit::singleline(&mut f.folder).desired_width(220.0)).changed() {
                                    f.folder_touched = true;
                                }
                            });
                        } else {
                            ui.add(egui::TextEdit::singleline(&mut f.dest_raw).hint_text("gcrypt:  ·  gdrive:NAS/Photos").desired_width(300.0));
                        }
                    });
                    ui.end_row();

                    ui.label(tr("Fichiers supprimés"));
                    ui.vertical(|ui| {
                        ui.radio_value(&mut f.deletion, 1, tr("Corbeille : gardés sur la destination pendant"));
                        if f.deletion == 1 {
                            ui.horizontal(|ui| {
                                ui.add_space(24.0);
                                ui.add(egui::TextEdit::singleline(&mut f.trash_days).desired_width(50.0));
                                ui.label(tr("jours (les anciennes versions des fichiers modifiés aussi)"));
                            });
                        }
                        ui.radio_value(&mut f.deletion, 0, tr("Suppression directe : supprimés aussi sur la destination"));
                        ui.radio_value(&mut f.deletion, 2, tr("Copie seule : rien n'est jamais supprimé sur la destination"));
                    });
                    ui.end_row();

                    ui.label(tr("Exclusions"));
                    ui.vertical(|ui| {
                        ui.add(egui::TextEdit::singleline(&mut f.excl).hint_text("cache ; *.bak ; Corbeille/**").desired_width(300.0));
                        ui.label(RichText::new(tr("Dossiers ou motifs séparés par « ; » (fichiers temporaires et dossiers techniques déjà exclus).")).small().weak());
                    });
                    ui.end_row();

                    ui.label(tr("Types de fichiers"));
                    ui.vertical(|ui| {
                        ui.add(egui::TextEdit::singleline(&mut f.types).hint_text("*.mp4 ; *.jpg").desired_width(300.0));
                        ui.label(RichText::new(tr("Vide = tous les fichiers ; sinon seulement ces types.")).small().weak());
                    });
                    ui.end_row();

                    ui.label(tr("Regroupement"));
                    ui.vertical(|ui| {
                        ui.horizontal(|ui| {
                            ui.label(tr("envoi après"));
                            ui.add(egui::TextEdit::singleline(&mut f.delay).desired_width(50.0));
                            ui.label(tr("s sans nouveau changement"));
                        });
                        ui.label(RichText::new(tr("Un fichier modifié en boucle (document ouvert, base de données) part au plus toutes les 60 s.")).small().weak());
                    });
                    ui.end_row();

                    ui.label(tr("Rattrapage"));
                    ui.vertical(|ui| {
                        egui::ComboBox::from_id_salt("rtcatch").selected_text(catch_label(f.catchup)).show_ui(ui, |ui| {
                            for m in CATCH_CHOICES {
                                ui.selectable_value(&mut f.catchup, m, catch_label(m));
                            }
                        });
                        ui.label(RichText::new(tr("Comparaison complète périodique : rattrape ce que la surveillance aurait manqué (NAS redémarré, réseau coupé…).")).small().weak());
                    });
                    ui.end_row();

                    ui.label(tr("Détection d'anomalie"));
                    ui.vertical(|ui| {
                        ui.horizontal(|ui| {
                            ui.checkbox(&mut f.anomaly_on, tr("Mettre en pause si plus de"));
                            ui.add_enabled(f.anomaly_on, egui::TextEdit::singleline(&mut f.anomaly).desired_width(60.0));
                            ui.label(tr("fichiers supprimés ou modifiés en 10 minutes"));
                        });
                        ui.label(RichText::new(tr("Protection contre un rançongiciel ou une fausse manipulation : rien n'est répercuté, une alerte est envoyée. À désactiver pour les caméras (elles effacent régulièrement les anciennes vidéos).")).small().weak());
                    });
                    ui.end_row();

                    ui.label(tr("Mémoire de rclone"));
                    crate::ram::job_memory_ui(ui, "rtmem", &mut f.memory);
                    ui.end_row();

                    ui.label(tr("Limite de débit"));
                    f.bw.ui_with(ui, api11);
                    ui.end_row();
                });
            });
            if !f.new {
                ui.label(RichText::new(tr("Changer la destination : les fichiers déjà envoyés restent à l'ancien emplacement.")).small().weak());
            }
            if !f.error.is_empty() {
                ui.colored_label(ERR, &f.error);
            }
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                if ui.add(egui::Button::new(RichText::new(tr("Enregistrer")).color(Color32::WHITE)).fill(INFO)).clicked() {
                    save = true;
                }
                if ui.button(tr("Annuler")).clicked() {
                    cancel = true;
                }
            });
        });
    if browse {
        let start = f.dirs.last().and_then(|d| d.rsplit_once('/').map(|(a, _)| a.to_string())).unwrap_or_default();
        app.rt_form = Some(f);
        app.open_browser(HostId::Omv, BrowsePurpose::RtSource, &start);
        return;
    }
    if !open || cancel {
        return;
    }
    if save {
        if !f.new && f.folder.is_empty() && f.dest_mode < 2 {
            f.folder_touched = true;
        }
        let name = f.name.trim().to_string();
        let dest = f.dest();
        let bw = f.bw.build();
        let names: Vec<&str> = f.dirs.iter().map(|d| d.trim_end_matches('/').rsplit('/').next().unwrap_or("")).collect();
        let dup = names.iter().enumerate().any(|(i, n)| names[..i].contains(n));
        let err: String = if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
            tr("Nom invalide : lettres, chiffres, - et _ uniquement.").into()
        } else if f.dirs.is_empty() {
            tr("Choisis au moins un dossier à surveiller.").into()
        } else if dup {
            tr("Deux dossiers surveillés portent le même nom : la destination serait la même.").into()
        } else if let Err(e) = &dest {
            (*e).into()
        } else if f.deletion == 1 && f.trash_days.trim().parse::<u32>().map(|d| d == 0).unwrap_or(true) {
            tr("Nombre de jours de corbeille invalide (1 au minimum).").into()
        } else if f.delay.trim().parse::<u32>().map(|d| d == 0 || d > 3600).unwrap_or(true) {
            tr("Regroupement invalide (1 à 3600 secondes).").into()
        } else if f.anomaly_on && f.anomaly.trim().parse::<u32>().map(|d| d == 0).unwrap_or(true) {
            tr("Seuil d'anomalie invalide (nombre de fichiers).").into()
        } else if !crate::ram::valid_job_memory(f.memory.trim()) {
            tr("Mémoire de rclone invalide : un nombre de Mo, 64 au minimum.").into()
        } else if let Err(e) = &bw {
            e.clone()
        } else if f.excl.contains('|') || f.types.contains('|') {
            tr("Caractère | interdit dans les filtres.").into()
        } else {
            String::new()
        };
        if !err.is_empty() {
            f.error = err;
            app.rt_form = Some(f);
            return;
        }
        let script = remote::rt_save(
            f.new,
            &remote::RtSave {
                name: &name,
                dirs: &f.dirs.iter().map(|d| d.trim_end_matches('/').to_string()).collect::<Vec<_>>().join(";"),
                dest: &dest.unwrap_or_default(),
                deletion: ["directe", "corbeille", "copie"][f.deletion.min(2) as usize],
                trash_days: if f.deletion == 1 { f.trash_days.trim().parse().unwrap_or(30) } else { 0 },
                excl: &clean_list(&f.excl),
                types: &clean_list(&f.types),
                delay: f.delay.trim().parse().unwrap_or(10),
                catchup: f.catchup,
                anomaly: if f.anomaly_on { f.anomaly.trim().parse().unwrap_or(300) } else { 0 },
                memory: f.memory.trim(),
                bwlimit: &bw.unwrap_or_default(),
            },
        );
        let title = if f.new { tr("Nouvelle sauvegarde temps réel") } else { tr("Modification") };
        app.action_dialog(HostId::Omv, title, script, 180);
        return;
    }
    app.rt_form = Some(f);
}

// ---------------------------------------------------------------------
//  Page
// ---------------------------------------------------------------------

pub fn page(app: &mut App, ui: &mut egui::Ui) {
    crate::pages::page_title_pub(ui, tr("Sauvegardes temps réel"), tr("Chaque fichier créé, modifié ou supprimé dans les dossiers surveillés part au fil de l'eau"));
    if !crate::pages::host_banner_pub(app, ui, HostId::Omv) {
        return;
    }
    let s = app.omv.status.clone().unwrap();
    let ready = s.nb_installe && s.nb_api >= remote::nb_api();
    if !ready {
        crate::pages::info_banner(ui, tr("Les sauvegardes temps réel demandent le script nas-debian à jour sur la machine."));
        crate::scripts::widget(app, ui, crate::scripts::Kind::Debian);
        ui.add_space(8.0);
    }
    if s.anciens.iter().any(|a| a == "cam-sync") {
        egui::Frame::new().fill(WARN.gamma_multiply(0.15)).corner_radius(6).inner_margin(10).show(ui, |ui| {
            ui.label(RichText::new(tr("L'ancienne synchro des caméras (cam-sync) est encore en place.")).strong());
            ui.label(tr("La migration la transforme en sauvegarde temps réel « Cameras » : même dossier, même destination chiffrée, suppressions directes comme avant, historique des envois conservé."));
            if ready {
                crate::scripts::widget(app, ui, crate::scripts::Kind::Debian);
            }
        });
        ui.add_space(8.0);
    }
    ui.horizontal(|ui| {
        if ui.add_enabled(ready, egui::Button::new(RichText::new(tr("+ Nouvelle sauvegarde temps réel")).color(Color32::WHITE)).fill(INFO)).clicked() {
            app.rt_form = Some(RtForm::new_default());
        }
        if ui.button(tr("\u{EB7A} Journaux")).clicked() {
            app.page = Page::Logs;
        }
    });
    ui.add_space(6.0);
    if s.temps_reel.is_empty() && !s.cameras.installe {
        crate::pages::card_pub(ui, "", |ui| {
            ui.label(tr("Aucune sauvegarde temps réel. Exemples : les vidéos des caméras (suppressions directes, sans détection d'anomalie), ou un dossier de documents (corbeille de 30 jours, détection d'anomalie)."));
        });
    }
    let now = s.maintenant.max(fmt::now());
    for j in &s.temps_reel {
        job_card(app, ui, j, now, j.nom == s.cam_job);
        ui.add_space(8.0);
    }
    if s.cameras.installe {
        crate::pages::cameras_legacy(app, ui, &s);
    }
}

fn job_card(app: &mut App, ui: &mut egui::Ui, j: &RtJob, now: i64, is_cam: bool) {
    let (col, st) = state(j);
    theme::card_frame(ui).show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.horizontal(|ui| {
            ui.label(RichText::new("●").color(col));
            ui.label(RichText::new(&j.nom).strong().size(16.0));
            crate::pages::badge_pub(ui, st, col);
            crate::pages::badge_pub(ui, &deletion_label(j), IDLE);
            if j.chiffre {
                crate::pages::badge_pub(ui, tr("\u{E2FA} Chiffré"), IDLE);
            }
            if is_cam {
                crate::pages::badge_pub(ui, tr("Caméras"), IDLE);
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let name = j.nom.clone();
                ui.menu_button("\u{E1FE}", |ui| {
                    if ui.add_enabled(!j.rattrapage_en_cours && j.pause.is_none(), egui::Button::new(tr("\u{E1AA} Rattrapage maintenant"))).clicked() {
                        app.action_toast(HostId::Omv, tr("Rattrapage"), remote::rt_catchup(&name, false), 30);
                        ui.close();
                    }
                    if ui
                        .add_enabled(!j.rattrapage_en_cours && j.pause.is_none(), egui::Button::new(tr("\u{E08E} Tout envoyer maintenant")))
                        .on_hover_text(tr("Envoie tous les fichiers déjà présents (première sauvegarde, ou après un long arrêt)"))
                        .clicked()
                    {
                        app.action_toast(HostId::Omv, tr("Envoi complet"), remote::rt_catchup(&name, true), 30);
                        ui.close();
                    }
                    if ui.add_enabled(j.pause.is_none(), egui::Button::new(tr("Mettre en pause"))).clicked() {
                        app.action_toast(HostId::Omv, tr("Pause"), remote::rt_cmd("pause", &name), 30);
                        ui.close();
                    }
                    if ui.button(tr("\u{E094} Redémarrer la surveillance")).clicked() {
                        app.action_toast(HostId::Omv, tr("Redémarrage"), remote::rt_cmd("redemarrer", &name), 60);
                        ui.close();
                    }
                    if ui.button(tr("\u{E4A6} Supprimer la sauvegarde…")).clicked() {
                        let n = name.clone();
                        app.ask_confirm(
                            tr("Supprimer la sauvegarde temps réel"),
                            &tf("La surveillance de « {0} » s'arrête. Les fichiers déjà envoyés restent sur la destination.", &[&n]),
                            tr("Supprimer"),
                            true,
                            None,
                            Box::new(move |app| app.action_dialog(HostId::Omv, tr("Suppression"), remote::rt_delete(&n, false), 120)),
                        );
                        ui.close();
                    }
                    if ui.button(RichText::new(tr("\u{E4A6} Supprimer et effacer la destination…")).color(ERR)).clicked() {
                        let n = name.clone();
                        let dest = dest_human(&j.destination);
                        app.ask_confirm(
                            tr("Supprimer et effacer la destination"),
                            &tf("La sauvegarde « {0} » est supprimée ET ses fichiers sont DÉFINITIVEMENT effacés de la destination ({1}, corbeille comprise).", &[&n, &dest]),
                            tr("Supprimer définitivement"),
                            true,
                            Some(&name),
                            Box::new(move |app| app.action_dialog(HostId::Omv, tr("Suppression"), remote::rt_delete(&n, true), 1800)),
                        );
                        ui.close();
                    }
                });
                if ui.button(tr("\u{E3B4} Modifier")).clicked() {
                    app.rt_form = Some(RtForm::from_job(j));
                }
                if j.pause.is_some() {
                    if ui.add(egui::Button::new(RichText::new(tr("\u{E3D0} Reprendre")).color(Color32::WHITE)).fill(INFO)).clicked() {
                        let n = name.clone();
                        app.ask_confirm(
                            tr("Reprendre la sauvegarde"),
                            &tf("Vérifie d'abord le dossier : en reprenant, l'état actuel de « {0} » est répercuté tout de suite sur la destination (fichiers supprimés ou modifiés compris{1}).", &[&n, &(if j.suppression == "corbeille" { tr(", gardés dans la corbeille") } else { "" })]),
                            tr("Reprendre"),
                            j.suppression == "directe",
                            None,
                            Box::new(move |app| app.action_toast(HostId::Omv, tr("Reprise"), remote::rt_cmd("reprendre", &n), 30)),
                        );
                    }
                } else if j.actif {
                    if ui.button(tr("\u{E46C} Arrêter")).clicked() {
                        let n = name.clone();
                        app.ask_confirm(
                            tr("Arrêter la surveillance"),
                            &tf("Les changements de « {0} » ne partiront plus en temps réel (le rattrapage périodique continue).", &[&n]),
                            tr("Arrêter"),
                            true,
                            None,
                            Box::new(move |app| app.action_toast(HostId::Omv, tr("Arrêt"), remote::rt_cmd("arreter", &n), 60)),
                        );
                    }
                } else if ui.button(tr("\u{E3D0} Démarrer")).clicked() {
                    app.action_toast(HostId::Omv, tr("Démarrage"), remote::rt_cmd("demarrer", &name), 60);
                }
            });
        });
        let dirs: Vec<String> = j.dossiers.iter().map(|d| fmt::short_path(&d.chemin)).collect();
        ui.label(RichText::new(tf("{0}  →  {1}", &[&(dirs.join(", ")), &(dest_human(&j.destination))])).color(ui.visuals().strong_text_color()))
            .on_hover_text(j.dossiers.iter().map(|d| d.chemin.clone()).collect::<Vec<_>>().join("\n"));
        for d in j.dossiers.iter().filter(|d| !d.existe) {
            ui.colored_label(ERR, tf("\u{E4E0} Dossier introuvable (disque démonté ?) : {0}", &[&d.chemin]));
        }
        if let Some(p) = &j.pause {
            egui::Frame::new().fill(ERR.gamma_multiply(0.15)).corner_radius(6).inner_margin(8).show(ui, |ui| {
                ui.label(RichText::new(tf("En pause depuis {0}", &[&(fmt::ago(p.depuis, now))])).strong().color(ERR));
                ui.label(&p.raison);
                ui.label(RichText::new(tr("Rien n'est répercuté sur la destination tant que la sauvegarde est en pause. Si les changements sont voulus, clique sur « Reprendre ».")).small());
            });
        }
        let mut parts = vec![tf("Aujourd'hui : {0} fichier(s) envoyé(s) ({1})", &[&j.envois_aujourdhui, &(fmt::bytes(j.volume_aujourdhui.max(0) as u64))])];
        if j.suppressions_aujourdhui > 0 {
            parts.push(tf("{0} supprimé(s)", &[&j.suppressions_aujourdhui]));
        }
        if let Some(t) = j.dernier_envoi {
            parts.push(tf("dernier envoi {0}", &[&(fmt::ago(t, now))]));
        }
        ui.label(RichText::new(parts.join(" · ")).small());
        if j.echecs_aujourdhui > 0 {
            ui.colored_label(ERR, tf("{0} échec(s) d'envoi aujourd'hui (renvoyés au prochain rattrapage)", &[&j.echecs_aujourdhui]));
        }
        if j.rattrapage_en_cours {
            ui.horizontal(|ui| {
                ui.spinner();
                let ram = j.ram_mo.map(|m| tf(" · rclone utilise {0} Mo", &[&m])).unwrap_or_default();
                ui.label(RichText::new(format!("{}{ram}", tr("Rattrapage en cours"))).small());
            });
        }
        if let Some(e) = &j.derniere_erreur {
            egui::CollapsingHeader::new(RichText::new(tr("Dernière erreur")).small()).id_salt(("rterr", &j.nom)).show(ui, |ui| {
                crate::explain::show(ui, e);
            });
        }
        let mut cfg = vec![tf("regroupement {0} s", &[&j.delai]), tf("rattrapage {0}", &[&(catch_label(j.rattrapage))])];
        cfg.push(if j.anomalie > 0 { tf("pause au-delà de {0} fichiers supprimés/modifiés en 10 min", &[&j.anomalie]) } else { tr("sans détection d'anomalie").into() });
        if !j.types.is_empty() {
            cfg.push(tf("types : {0}", &[&(j.types.replace(';', ", "))]));
        }
        if !j.exclusions.is_empty() {
            cfg.push(tf("exclusions : {0}", &[&(j.exclusions.replace(';', ", "))]));
        }
        if !j.memoire.is_empty() {
            cfg.push(tf("mémoire : {0}", &[&(crate::ram::job_memory_text(&j.memoire))]));
        }
        if !j.debit.is_empty() {
            cfg.push(tf("débit : {0}", &[&(fmt::bw_human(&j.debit))]));
        }
        ui.label(RichText::new(cfg.join(" · ")).small().weak());
        egui::CollapsingHeader::new(RichText::new(tr("Derniers événements")).small()).id_salt(("rtev", &j.nom)).show(ui, |ui| {
            if j.evenements.is_empty() {
                ui.label(RichText::new(tr("(rien dans le journal)")).weak());
            }
            for e in j.evenements.iter().rev() {
                let c = if e.contains(" ERROR ") || e.contains("PAUSE") {
                    ERR
                } else if e.contains("Deleted") || e.contains("Moved") {
                    WARN
                } else {
                    ui.visuals().text_color()
                };
                ui.label(RichText::new(e).monospace().size(12.0).color(c));
            }
        });
    });
}

/// Carte du tableau de bord ; renvoie true si le lien a ete clique
pub fn dashboard_card(ui: &mut egui::Ui, s: Option<&OmvStatus>, now: i64) -> bool {
    match s {
        None => {
            ui.label(RichText::new("—").weak());
        }
        Some(s) if s.temps_reel.is_empty() && !s.cameras.installe => {
            ui.label(RichText::new(tr("Aucune sauvegarde temps réel.")).weak());
        }
        Some(s) => {
            for j in s.temps_reel.iter().take(5) {
                let (col, st) = state(j);
                ui.horizontal(|ui| {
                    ui.label(RichText::new("●").color(col));
                    ui.label(RichText::new(&j.nom).strong());
                    ui.label(RichText::new(st).small().color(col));
                });
                let last = j.dernier_envoi.map(|t| tf(" · dernier {0}", &[&(fmt::ago(t, now))])).unwrap_or_default();
                ui.label(RichText::new(format!("{}{last}", tf("{0} envoi(s) aujourd'hui", &[&j.envois_aujourdhui]))).small().weak());
            }
            if s.temps_reel.len() > 5 {
                ui.label(RichText::new(tf("… et {0} autre(s)", &[&(s.temps_reel.len() - 5)])).small().weak());
            }
            if s.cameras.installe {
                let c = &s.cameras;
                crate::pages::dot_label_pub(ui, if c.actif { OK } else { ERR }, if c.actif { tr("Ancienne synchro des caméras active") } else { tr("Ancienne synchro des caméras ARRÊTÉE") });
            }
        }
    }
    ui.link(tr("Voir les sauvegardes temps réel →")).clicked()
}
