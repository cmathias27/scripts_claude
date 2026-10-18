//! Les pages de l'application.

use crate::app::*;
use crate::fmt;
use crate::model::*;
use crate::remote;
use crate::secret;
use crate::ssh::SshError;
use crate::theme::{self, ERR, IDLE, INFO, OK, WARN};
use eframe::egui::{self, Color32, RichText};

// =====================================================================
//  Petits composants
// =====================================================================

fn dot(ui: &mut egui::Ui, col: Color32) {
    let (r, _) = ui.allocate_exact_size(egui::vec2(12.0, 12.0), egui::Sense::hover());
    ui.painter().circle_filled(r.center(), 5.0, col);
}

fn dot_label(ui: &mut egui::Ui, col: Color32, text: impl Into<RichText>) -> egui::Response {
    ui.horizontal(|ui| {
        dot(ui, col);
        ui.label(text.into());
    })
    .response
}

fn card<R>(ui: &mut egui::Ui, title: &str, add: impl FnOnce(&mut egui::Ui) -> R) -> R {
    theme::card_frame(ui)
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            if !title.is_empty() {
                ui.label(RichText::new(title).strong().size(15.5));
                ui.add_space(2.0);
            }
            add(ui)
        })
        .inner
}

fn page_title(ui: &mut egui::Ui, title: &str, subtitle: &str) {
    ui.heading(title);
    if !subtitle.is_empty() {
        ui.label(RichText::new(subtitle).weak());
    }
    ui.add_space(8.0);
}

fn badge(ui: &mut egui::Ui, text: &str, col: Color32) {
    egui::Frame::new()
        .fill(col.gamma_multiply(0.18))
        .corner_radius(10.0)
        .inner_margin(egui::Margin::symmetric(8, 2))
        .show(ui, |ui| {
            ui.label(RichText::new(text).small().color(col));
        });
}

fn banner(ui: &mut egui::Ui, col: Color32, text: &str) {
    egui::Frame::new()
        .fill(col.gamma_multiply(0.14))
        .stroke(egui::Stroke::new(1.0, col.gamma_multiply(0.6)))
        .corner_radius(6.0)
        .inner_margin(egui::Margin::same(10))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.label(RichText::new(text).color(ui.visuals().strong_text_color()));
        });
}

fn danger_button(ui: &mut egui::Ui, text: &str) -> egui::Response {
    ui.add(egui::Button::new(RichText::new(text).color(Color32::WHITE)).fill(ERR))
}

fn primary_button(ui: &mut egui::Ui, text: &str) -> egui::Response {
    ui.add(egui::Button::new(RichText::new(text).color(Color32::WHITE)).fill(INFO))
}

fn progress_bar(ui: &mut egui::Ui, pct: Option<i64>, text: String) {
    let f = pct.map(|p| (p as f32 / 100.0).clamp(0.0, 1.0));
    let mut bar = egui::ProgressBar::new(f.unwrap_or(0.0)).text(text).desired_height(20.0);
    if f.is_none() {
        bar = bar.animate(true);
    }
    ui.add(bar);
}

/// Bandeau quand un NAS n'est pas joignable ; renvoie false si aucune donnee n'est disponible.
fn host_banner(app: &mut App, ui: &mut egui::Ui, h: HostId) -> bool {
    let cfg = app.host_cfg(h).clone();
    if !cfg.is_set() {
        banner(ui, WARN, &format!("{} non configuré : renseigne son adresse dans les Paramètres.", h.label()));
        if ui.button("⚙ Ouvrir les paramètres").clicked() {
            app.page = Page::Settings;
        }
        return false;
    }
    let has = match h {
        HostId::Omv => app.omv.status.is_some(),
        HostId::Syno => app.syno.status.is_some(),
    };
    if let Some(e) = app.host_error(h).cloned() {
        banner(ui, ERR, &format!("{} : {}", h.label(), e));
        ui.horizontal(|ui| {
            if ui.button("⟳ Réessayer").clicked() {
                app.refresh(h);
            }
            if matches!(e, SshError::KeyRefused | SshError::HostKeyChanged) && ui.button("⚙ Paramètres").clicked() {
                app.page = Page::Settings;
            }
        });
        ui.add_space(6.0);
    } else if !has {
        ui.horizontal(|ui| {
            ui.spinner();
            ui.label(format!("Connexion au {}…", h.label()));
        });
    }
    has
}

fn job_dest(j: &Job) -> String {
    if j.chiffre {
        format!("NAS-chiffre/{}", j.dossier)
    } else {
        format!("NAS/{}", j.dossier)
    }
}

fn job_color(j: &Job) -> Color32 {
    if j.en_cours {
        INFO
    } else {
        match j.dernier_etat.as_deref() {
            Some("OK") => OK,
            Some("ECHEC") => ERR,
            Some("ARRETE") => WARN,
            _ => IDLE,
        }
    }
}

fn job_state_text(j: &Job) -> &'static str {
    if j.en_cours {
        "En cours"
    } else {
        match j.dernier_etat.as_deref() {
            Some("OK") => "OK",
            Some("ECHEC") => "Échec",
            Some("ARRETE") => "Arrêtée",
            _ => "Jamais lancée",
        }
    }
}

fn progress_text(p: &Progress) -> String {
    let mut t = format!(
        "{} / {}",
        fmt::rclone_units(&p.octets_faits),
        fmt::rclone_units(&p.octets_total)
    );
    if let Some(pc) = p.pct {
        t.push_str(&format!(" · {pc} %"));
    }
    t.push_str(&format!(" · {}", fmt::rclone_units(&p.vitesse)));
    if p.reste != "-" && !p.reste.is_empty() {
        t.push_str(&format!(" · reste {}", fmt::rclone_dur(&p.reste)));
    }
    t
}

fn progress_details(ui: &mut egui::Ui, p: &Progress) {
    let mut parts = Vec::new();
    if let (Some(a), Some(b)) = (p.fichiers_faits, p.fichiers_total) {
        parts.push(format!("{a} / {b} fichiers envoyés"));
    }
    if let (Some(a), Some(b)) = (p.verifs_faites, p.verifs_total) {
        parts.push(format!("{a} / {b} vérifiés"));
    }
    if let Some(e) = p.erreurs {
        if e > 0 {
            parts.push(format!("{e} erreur(s)"));
        }
    }
    if let Some(d) = &p.duree {
        parts.push(format!("depuis {}", fmt::rclone_dur(d)));
    }
    if !parts.is_empty() {
        ui.label(RichText::new(parts.join(" · ")).small().weak());
    }
    for f in &p.en_cours {
        ui.horizontal(|ui| {
            ui.add(
                egui::ProgressBar::new(f.pct as f32 / 100.0)
                    .desired_width(90.0)
                    .desired_height(10.0),
            );
            ui.label(
                RichText::new(format!(
                    "{}  ({} · {})",
                    f.fichier,
                    fmt::rclone_units(&f.taille),
                    fmt::rclone_units(&f.vitesse)
                ))
                .small(),
            );
        });
    }
}

fn bilan_text(b: &Bilan) -> String {
    let mut t = format!(
        "{} fichier{} envoyé{} ({})",
        b.fichiers_envoyes,
        if b.fichiers_envoyes > 1 { "s" } else { "" },
        if b.fichiers_envoyes > 1 { "s" } else { "" },
        fmt::bytes(b.volume_octets.max(0) as u64)
    );
    if b.retires > 0 {
        t.push_str(&format!(", {} retiré(s)", b.retires));
    }
    if b.erreurs > 0 {
        t.push_str(&format!(", {} erreur(s)", b.erreurs));
    }
    t.push_str(&format!(" · {:.0} min", b.duree_min));
    t
}

// =====================================================================
//  Barre du haut et navigation
// =====================================================================

pub fn top_bar(app: &mut App, ui: &mut egui::Ui) {
    egui::Panel::top("top").show(ui, |ui| {
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            ui.label(RichText::new("🗄 NAS Manager").strong().size(18.0));
            ui.add_space(18.0);
            for h in [HostId::Omv, HostId::Syno] {
                host_chip(app, ui, h);
                ui.add_space(8.0);
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.button("⟳ Actualiser").on_hover_text("Relire l'état des deux NAS").clicked() {
                    app.refresh(HostId::Omv);
                    app.refresh(HostId::Syno);
                }
            });
        });
        ui.add_space(4.0);
    });
}

fn host_chip(app: &mut App, ui: &mut egui::Ui, h: HostId) {
    let cfg = app.host_cfg(h).clone();
    let (col, txt, tip) = if !cfg.is_set() {
        (IDLE, format!("{} : non configuré", h.label()), "À renseigner dans les Paramètres".to_string())
    } else if let Some(e) = app.host_error(h) {
        if matches!(e, SshError::SudoPassword) {
            (WARN, format!("{} : mot de passe requis", h.label()), e.to_string())
        } else {
            (ERR, format!("{} : hors ligne", h.label()), e.to_string())
        }
    } else {
        let (last, polling) = match h {
            HostId::Omv => (app.omv.last_ok, app.omv.polling),
            HostId::Syno => (app.syno.last_ok, app.syno.polling),
        };
        match last {
            Some(t) => (
                OK,
                format!("{} : connecté", h.label()),
                format!("{} — mis à jour il y a {} s", cfg.target(), t.elapsed().as_secs()),
            ),
            None if polling => (WARN, format!("{} : connexion…", h.label()), cfg.target()),
            None => (IDLE, format!("{} : en attente", h.label()), cfg.target()),
        }
    };
    let r = ui
        .horizontal(|ui| {
            dot(ui, col);
            ui.label(txt);
        })
        .response
        .interact(egui::Sense::click())
        .on_hover_text(tip);
    if r.clicked() {
        app.refresh(h);
    }
}

pub fn nav(app: &mut App, ui: &mut egui::Ui) {
    let omv = app.omv.status.clone();
    let syno = app.syno.status.clone();
    let running_jobs = omv.as_ref().map(|s| s.sauvegardes.iter().filter(|j| j.en_cours).count()).unwrap_or(0);
    let failed_jobs = omv
        .as_ref()
        .map(|s| s.sauvegardes.iter().filter(|j| !j.en_cours && j.dernier_etat.as_deref() == Some("ECHEC")).count())
        .unwrap_or(0);
    let alerts = omv.as_ref().map(|s| s.alertes.len()).unwrap_or(0);
    let cam_bad = omv.as_ref().map(|s| s.cameras.installe && !s.cameras.actif).unwrap_or(false);
    let copy_run = syno.as_ref().map(|s| s.copie.en_cours).unwrap_or(false);
    let mig_run = syno.as_ref().map(|s| s.migration.en_cours).unwrap_or(false);
    let mig_q = syno.as_ref().map(|s| s.migration.file.len()).unwrap_or(0);

    egui::Panel::left("nav").exact_size(220.0).show(ui, |ui| {
        ui.add_space(10.0);
        let items: Vec<(Page, &str, Option<(String, Color32)>)> = vec![
            (Page::Dashboard, "🏠  Tableau de bord", None),
            (
                Page::Backups,
                "💾  Sauvegardes",
                if running_jobs > 0 {
                    Some((format!("{running_jobs} en cours"), INFO))
                } else if failed_jobs > 0 {
                    Some((format!("{failed_jobs} échec"), ERR))
                } else {
                    None
                },
            ),
            (Page::Cameras, "📹  Caméras", if cam_bad { Some(("arrêtée".into(), ERR)) } else { None }),
            (Page::Alerts, "🔔  Alertes", if alerts > 0 { Some((alerts.to_string(), ERR)) } else { None }),
            (Page::Copy, "📦  Copie → OMV", if copy_run { Some(("en cours".into(), INFO)) } else { None }),
            (
                Page::Migration,
                "☁  Migration oCIS",
                if mig_run {
                    Some(("en cours".into(), INFO))
                } else if mig_q > 0 {
                    Some((format!("{mig_q} en file"), WARN))
                } else {
                    None
                },
            ),
            (Page::Logs, "📜  Journaux", None),
            (Page::Settings, "⚙  Paramètres", None),
        ];
        for (p, label, b) in items {
            let sel = app.page == p;
            let mut btn = egui::Button::selectable(sel, RichText::new(label).size(14.5))
                .min_size(egui::vec2(ui.available_width() - 6.0, 32.0))
                .wrap_mode(egui::TextWrapMode::Extend);
            if let Some((t, c)) = b {
                btn = btn.right_text(RichText::new(t).small().strong().color(c));
            }
            if ui.add(btn).clicked() {
                app.page = p;
            }
        }
        ui.with_layout(egui::Layout::bottom_up(egui::Align::Min), |ui| {
            ui.add_space(8.0);
            ui.label(RichText::new(format!("v{}", env!("CARGO_PKG_VERSION"))).small().weak());
        });
    });
}

// =====================================================================
//  Tableau de bord
// =====================================================================

pub fn dashboard(app: &mut App, ui: &mut egui::Ui) {
    page_title(ui, "Tableau de bord", "Vue d'ensemble des sauvegardes et transferts du NAS");
    let omv = app.omv.status.clone();
    let syno = app.syno.status.clone();
    if omv.is_none() {
        host_banner(app, ui, HostId::Omv);
    } else if let Some(e) = app.host_error(HostId::Omv).cloned() {
        banner(ui, ERR, &format!("OMV : {e} (dernières informations affichées)"));
    }
    let now = fmt::now();
    let ncol = if ui.available_width() > 980.0 { 3 } else { 2 };
    let mut goto: Option<Page> = None;

    ui.columns(ncol, |cols| {
        let mut i = 0;
        let mut next = |_cols: &mut [egui::Ui]| -> usize {
            let k = i % ncol;
            i += 1;
            k
        };

        // ---- Sauvegardes
        let k = next(cols);
        card(&mut cols[k], "💾 Sauvegardes Drive", |ui| {
            match &omv {
                None => {
                    ui.label(RichText::new("—").weak());
                }
                Some(s) => {
                    let n = s.sauvegardes.len();
                    let ok = s.sauvegardes.iter().filter(|j| j.dernier_etat.as_deref() == Some("OK")).count();
                    let ko = s.sauvegardes.iter().filter(|j| j.dernier_etat.as_deref() == Some("ECHEC")).count();
                    if n == 0 {
                        ui.label("Aucune sauvegarde configurée.");
                    } else {
                        dot_label(ui, if ko > 0 { ERR } else { OK }, format!("{n} sauvegarde(s) · {ok} OK · {ko} en échec"));
                    }
                    for j in s.sauvegardes.iter().filter(|j| j.en_cours) {
                        ui.label(RichText::new(format!("▶ {}", j.nom)).strong());
                        match &j.avancement {
                            Some(p) => progress_bar(
                                ui,
                                p.pct,
                                format!("{} % · {}", p.pct.unwrap_or(0), fmt::rclone_units(&p.vitesse)),
                            ),
                            None => progress_bar(ui, None, "Préparation…".into()),
                        }
                    }
                    if s.arret_demande {
                        ui.colored_label(WARN, "Arrêt demandé : plus de nouvelle sauvegarde jusqu'au prochain horaire.");
                    }
                    let next_runs: Vec<String> = s
                        .sauvegardes
                        .iter()
                        .filter(|j| j.horaire != "manuel" && !j.en_cours)
                        .filter_map(|j| fmt::next_run(&j.horaire).map(|t| format!("{} : {}", j.nom, t)))
                        .take(3)
                        .collect();
                    if !next_runs.is_empty() {
                        ui.label(RichText::new(format!("Prochaines : {}", next_runs.join(" · "))).small().weak());
                    }
                }
            }
            if ui.link("Gérer les sauvegardes →").clicked() {
                goto = Some(Page::Backups);
            }
        });
        cols[k].add_space(10.0);

        // ---- Cameras
        let k = next(cols);
        card(&mut cols[k], "📹 Caméras", |ui| {
            match omv.as_ref().map(|s| &s.cameras) {
                None => {
                    ui.label(RichText::new("—").weak());
                }
                Some(c) if !c.installe => {
                    ui.label(RichText::new("Synchro des caméras non installée.").weak());
                }
                Some(c) => {
                    dot_label(
                        ui,
                        if c.actif { OK } else { ERR },
                        if c.actif { "Synchro temps réel active" } else { "Synchro ARRÊTÉE" },
                    );
                    match c.dernier_envoi.as_deref().and_then(fmt::parse_rclone_ts) {
                        Some(t) => ui.label(format!("Dernière vidéo envoyée {}", fmt::ago(t, now))),
                        None => ui.label(RichText::new("Aucun envoi récent dans le journal").weak()),
                    };
                    ui.label(format!("{} envoi(s) aujourd'hui", c.envois_aujourdhui));
                    if c.erreurs_aujourdhui > 0 {
                        ui.colored_label(ERR, format!("{} erreur(s) aujourd'hui", c.erreurs_aujourdhui));
                    }
                    if c.rattrapage_en_cours {
                        ui.horizontal(|ui| {
                            ui.spinner();
                            ui.label("Rattrapage en cours");
                        });
                    }
                }
            }
            if ui.link("Voir les caméras →").clicked() {
                goto = Some(Page::Cameras);
            }
        });
        cols[k].add_space(10.0);

        // ---- Google Drive
        let k = next(cols);
        card(&mut cols[k], "☁ Google Drive", |ui| {
            match omv.as_ref().and_then(|s| s.sante.clone()) {
                None => {
                    ui.label(RichText::new("État inconnu (nas-check pas encore lancé).").weak());
                }
                Some(h) => {
                    dot_label(ui, if h.gdrive { OK } else { ERR }, if h.gdrive { "Connexion OK" } else { "Connexion en échec" });
                    if let Some(p) = h.quota_pct {
                        let col = if p >= 90.0 { ERR } else if p >= 75.0 { WARN } else { OK };
                        let txt = match (h.used_go, h.total_go) {
                            (Some(u), Some(t)) => format!("{:.0} % · {:.1} / {:.0} Go", p, u, t),
                            _ => format!("{p:.0} %"),
                        };
                        ui.add(egui::ProgressBar::new((p / 100.0) as f32).fill(col).text(txt));
                    }
                    if let Some(c) = &h.checked {
                        ui.label(RichText::new(format!("Vérifié : {}", c.replace('T', " ").chars().take(16).collect::<String>())).small().weak());
                    }
                }
            }
            if let Some(s) = &omv {
                if !s.alertes.is_empty() {
                    ui.colored_label(ERR, format!("🔔 {} alerte(s) en cours", s.alertes.len()));
                }
            }
            if ui.link("Alertes & santé →").clicked() {
                goto = Some(Page::Alerts);
            }
        });
        cols[k].add_space(10.0);

        // ---- Copie
        let k = next(cols);
        card(&mut cols[k], "📦 Copie Synology → OMV", |ui| {
            match &syno {
                None => {
                    ui.label(RichText::new(if app.settings.syno.is_set() { "Synology non joignable." } else { "Synology non configuré." }).weak());
                }
                Some(s) => {
                    let c = &s.copie;
                    if c.en_cours {
                        ui.label(RichText::new(format!(
                            "{} → {}",
                            c.source.as_deref().unwrap_or("?").rsplit('/').next().unwrap_or(""),
                            fmt::short_path(c.destination.as_deref().unwrap_or(""))
                        )).strong());
                        match &c.avancement {
                            Some(p) => progress_bar(ui, Some(p.pct), format!("{} % · {} · reste {}", p.pct, p.vitesse, p.reste)),
                            None => progress_bar(ui, None, "Préparation de la liste des fichiers…".into()),
                        }
                    } else {
                        dot_label(ui, IDLE, "Aucune copie en cours");
                        if let Some(l) = c.historique.last() {
                            ui.label(RichText::new(hist_line(l)).small().weak());
                        }
                    }
                }
            }
            if ui.link("Copies →").clicked() {
                goto = Some(Page::Copy);
            }
        });
        cols[k].add_space(10.0);

        // ---- Migration
        let k = next(cols);
        card(&mut cols[k], "☁ Migration Drive → oCIS", |ui| {
            match &syno {
                None => {
                    ui.label(RichText::new("—").weak());
                }
                Some(s) => {
                    let m = &s.migration;
                    if m.en_cours {
                        if let Some(e) = &m.etape {
                            ui.label(RichText::new(format!("[{}/{}] {} → {}", e.etape, m.nb, e.libelle, e.espace)).strong());
                            progress_bar(ui, e.pct, if e.ligne.is_empty() { "Comparaison avec oCIS…".into() } else { fmt::stats_line(&e.ligne) });
                        } else {
                            ui.label("Migration en cours…");
                        }
                    } else {
                        dot_label(ui, IDLE, "Aucune migration en cours");
                    }
                    if !m.file.is_empty() {
                        ui.label(format!("{} migration(s) en file d'attente", m.file.len()));
                    }
                }
            }
            if ui.link("Migration →").clicked() {
                goto = Some(Page::Migration);
            }
        });
        cols[k].add_space(10.0);

        // ---- Systeme
        let k = next(cols);
        card(&mut cols[k], "🖥 Serveur OMV", |ui| {
            match &omv {
                None => {
                    ui.label(RichText::new("—").weak());
                }
                Some(s) => {
                    ui.label(format!(
                        "{} · allumé depuis {}{}",
                        s.serveur,
                        fmt::duration(s.uptime_s.unwrap_or(0)),
                        s.charge.as_ref().map(|c| format!(" · charge {c}")).unwrap_or_default()
                    ));
                    for d in &s.disques {
                        let f = if d.taille > 0 { d.utilise as f32 / d.taille as f32 } else { 0.0 };
                        let col = if f > 0.9 { ERR } else if f > 0.8 { WARN } else { OK };
                        ui.label(RichText::new(fmt::short_path(&d.point)).small());
                        ui.add(
                            egui::ProgressBar::new(f)
                                .fill(col)
                                .text(format!("{} libres sur {}", fmt::bytes(d.libre), fmt::bytes(d.taille))),
                        );
                    }
                }
            }
        });
    });
    if let Some(p) = goto {
        app.page = p;
    }
}

// =====================================================================
//  Sauvegardes
// =====================================================================

pub fn backups(app: &mut App, ui: &mut egui::Ui) {
    page_title(ui, "Sauvegardes vers Google Drive", "Script nas-backup sur l'OMV");
    if !host_banner(app, ui, HostId::Omv) {
        return;
    }
    let s = app.omv.status.clone().unwrap();
    if !s.nb_installe || s.nb_api < remote::API_VERSION {
        banner(
            ui,
            WARN,
            if s.nb_installe {
                "La version de nas-backup installée sur l'OMV est ancienne : mets-la à jour pour pouvoir ajouter, modifier ou restaurer depuis l'application."
            } else {
                "nas-backup n'est pas installé sur l'OMV."
            },
        );
        if ui.button("⬆ Installer / mettre à jour nas-backup").clicked() {
            install_omv_script(app);
        }
        ui.add_space(6.0);
    }
    let any_running = s.any_job_running();
    ui.horizontal(|ui| {
        if primary_button(ui, "+ Nouvelle sauvegarde").clicked() {
            app.job_form = Some(JobFormState {
                new: true,
                mirror: true,
                encrypt: true,
                hour: "03:30".into(),
                trash_days: "30".into(),
                ..Default::default()
            });
            if !app.sources_loaded {
                app.load_backup_sources();
            }
        }
        if ui.add_enabled(!s.sauvegardes.is_empty(), egui::Button::new("▶ Tout lancer")).clicked() {
            app.ask_confirm(
                "Lancer toutes les sauvegardes",
                "Les sauvegardes vont être lancées l'une après l'autre.",
                "Lancer",
                false,
                None,
                Box::new(|app| app.action_toast(HostId::Omv, "Lancement", remote::nb_run_all(), 30)),
            );
        }
        if any_running && danger_button(ui, "⏹ Arrêter les sauvegardes en cours").clicked() {
            app.ask_confirm(
                "Arrêter les sauvegardes",
                "Les transferts en cours s'arrêtent proprement (fin des fichiers en cours d'envoi).\nAucune nouvelle sauvegarde ne démarre avant le prochain horaire prévu.",
                "Arrêter",
                true,
                None,
                Box::new(|app| app.action_dialog(HostId::Omv, "Arrêt des sauvegardes", remote::nb_stop(), 150)),
            );
        }
    });
    if s.arret_demande && !any_running {
        ui.colored_label(WARN, "Un arrêt a été demandé : les sauvegardes reprendront à leur prochain horaire (ou en les lançant ici).");
    }
    ui.add_space(6.0);

    // Restauration en cours / terminee
    if let Some(r) = &s.restauration {
        let show = r.etat == "en_cours"
            || r.fin.parse::<i64>().map(|f| fmt::now() - f < 86400).unwrap_or(false);
        if show {
            card(ui, "⤓ Restauration", |ui| {
                let (col, t) = match r.etat.as_str() {
                    "en_cours" => (INFO, "En cours"),
                    "ok" => (OK, "Terminée"),
                    "echec" => (ERR, "Échec"),
                    _ => (WARN, "Interrompue"),
                };
                dot_label(ui, col, format!("{t} : « {} » → {}", r.nom, r.cible));
                if let Some(p) = &r.avancement {
                    progress_bar(ui, p.pct, progress_text(p));
                } else if r.etat == "en_cours" {
                    progress_bar(ui, None, "Préparation…".into());
                }
            });
            ui.add_space(8.0);
        }
    }

    if s.sauvegardes.is_empty() {
        card(ui, "", |ui| {
            ui.label("Aucune sauvegarde configurée. Clique sur « Nouvelle sauvegarde » pour en créer une.");
        });
    }
    let now = s.maintenant.max(fmt::now());
    for j in &s.sauvegardes {
        job_card(app, ui, j, now, any_running);
        ui.add_space(8.0);
    }
}

fn job_card(app: &mut App, ui: &mut egui::Ui, j: &Job, now: i64, _any_running: bool) {
    theme::card_frame(ui).show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.horizontal(|ui| {
            dot(ui, job_color(j));
            ui.label(RichText::new(&j.nom).strong().size(16.0));
            badge(ui, job_state_text(j), job_color(j));
            badge(ui, if j.mode == "sync" { "Miroir" } else { "Copie" }, IDLE);
            if j.chiffre {
                badge(ui, "🔒 Chiffré", IDLE);
            }
            badge(
                ui,
                &if j.horaire == "manuel" { "Manuel".to_string() } else { format!("⏰ {}", j.horaire) },
                IDLE,
            );
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let name = j.nom.clone();
                ui.menu_button("⋯", |ui| {
                    if ui.button("⤓ Restaurer…").clicked() {
                        let base = j
                            .source
                            .strip_prefix("/srv/")
                            .and_then(|r| r.split('/').next())
                            .map(|d| format!("/srv/{d}"))
                            .unwrap_or_else(|| {
                                j.source.rsplit_once('/').map(|(a, _)| a.to_string()).unwrap_or_default()
                            });
                        let stamp = chrono::Local::now().format("%Y-%m-%d_%H%M");
                        app.restore = Some(RestoreState {
                            job: name.clone(),
                            source: j.source.clone(),
                            target: format!("{base}/Restauration/{}_{stamp}", name),
                        });
                        ui.close();
                    }
                    if ui.button("🗑 Supprimer la sauvegarde…").clicked() {
                        let n = name.clone();
                        app.ask_confirm(
                            "Supprimer la sauvegarde",
                            &format!("La sauvegarde « {n} » ne sera plus planifiée.\nLes fichiers déjà envoyés restent sur le Drive."),
                            "Supprimer",
                            true,
                            None,
                            Box::new(move |app| app.action_dialog(HostId::Omv, "Suppression", remote::nb_delete(&n, false), 60)),
                        );
                        ui.close();
                    }
                    if ui.button(RichText::new("🗑 Supprimer et effacer du Drive…").color(ERR)).clicked() {
                        let n = name.clone();
                        let word = name.clone();
                        let dest = job_dest(j);
                        app.ask_confirm(
                            "Supprimer et effacer du Drive",
                            &format!("La sauvegarde « {n} » est supprimée ET ses fichiers sont DÉFINITIVEMENT effacés du Drive ({dest}, corbeille comprise)."),
                            "Supprimer définitivement",
                            true,
                            Some(&word),
                            Box::new(move |app| app.action_dialog(HostId::Omv, "Suppression", remote::nb_delete(&n, true), 1800)),
                        );
                        ui.close();
                    }
                });
                if ui.button("✏ Modifier").clicked() {
                    app.job_form = Some(JobFormState {
                        new: false,
                        name: j.nom.clone(),
                        source: j.source.clone(),
                        folder: j.dossier.clone(),
                        folder_touched: true,
                        mirror: j.mode == "sync",
                        encrypt: j.chiffre,
                        manual: j.horaire == "manuel",
                        hour: if j.horaire == "manuel" { "03:30".into() } else { j.horaire.clone() },
                        trash_days: j.corbeille.to_string(),
                        error: String::new(),
                    });
                    if !app.sources_loaded {
                        app.load_backup_sources();
                    }
                }
                if ui.add_enabled(!j.en_cours, egui::Button::new("▶ Lancer")).clicked() {
                    app.action_toast(HostId::Omv, "Lancement", remote::nb_run(&name), 30);
                }
            });
        });
        ui.label(
            RichText::new(format!("{}  →  Drive : {}", fmt::short_path(&j.source), job_dest(j)))
                .color(ui.visuals().strong_text_color()),
        )
        .on_hover_text(&j.source);
        if !j.source_existe {
            ui.colored_label(ERR, "⚠ Dossier source introuvable (disque démonté ?)");
        }
        if j.en_cours {
            match &j.avancement {
                Some(p) => {
                    progress_bar(ui, p.pct, progress_text(p));
                    progress_details(ui, p);
                }
                None => progress_bar(ui, None, "Comparaison avec le Drive…".into()),
            }
            if let Some(d) = j.debut {
                ui.label(RichText::new(format!("Démarrée {}", fmt::ago(d, now))).small().weak());
            }
        } else {
            let mut parts = Vec::new();
            if let Some(d) = &j.derniere_execution {
                let when = fmt::parse_status_ts(d).map(fmt::date).unwrap_or_else(|| d.clone());
                parts.push(format!("Dernière exécution : {when}"));
            }
            if let Some(ok) = j.dernier_succes {
                if j.dernier_etat.as_deref() != Some("OK") {
                    parts.push(format!("dernier succès {}", fmt::ago(ok, now)));
                }
            }
            if j.horaire != "manuel" {
                if let Some(n) = fmt::next_run(&j.horaire) {
                    parts.push(format!("prochaine : {n}"));
                }
            }
            if !parts.is_empty() {
                ui.label(RichText::new(parts.join(" · ")).small());
            }
            if let Some(b) = &j.bilan {
                ui.label(RichText::new(format!("Bilan : {}", bilan_text(b))).small().weak());
            }
        }
        if j.mode == "sync" && j.corbeille > 0 {
            ui.label(
                RichText::new(format!("Fichiers supprimés/modifiés gardés {} jours dans la corbeille du Drive", j.corbeille))
                    .small()
                    .weak(),
            );
        }
    });
}

fn valid_hour(h: &str) -> bool {
    let b = h.as_bytes();
    b.len() == 5
        && b[2] == b':'
        && h[..2].parse::<u32>().map(|v| v < 24).unwrap_or(false)
        && h[3..].parse::<u32>().map(|v| v < 60).unwrap_or(false)
        && b[0].is_ascii_digit()
        && b[3].is_ascii_digit()
}

pub fn job_form_window(app: &mut App, ctx: &egui::Context) {
    let Some(mut f) = app.job_form.take() else { return };
    let mut open = true;
    let mut save = false;
    let mut cancel = false;
    let mut browse = false;
    let sources = app.backup_sources.clone();
    egui::Window::new(RichText::new(if f.new { "Nouvelle sauvegarde" } else { "Modifier la sauvegarde" }).strong())
        .id(egui::Id::unique("jobform"))
        .collapsible(false)
        .resizable(false)
        .default_width(520.0)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            egui::Grid::new("jobgrid").num_columns(2).spacing([12.0, 10.0]).show(ui, |ui| {
                ui.label("Nom");
                ui.add_enabled(f.new, egui::TextEdit::singleline(&mut f.name).hint_text("ex : Photos").desired_width(300.0));
                ui.end_row();

                ui.label("Dossier à sauvegarder");
                ui.vertical(|ui| {
                    ui.horizontal(|ui| {
                        egui::ComboBox::from_id_salt("srccombo")
                            .width(300.0)
                            .selected_text(if f.source.is_empty() { "Choisir…".to_string() } else { fmt::short_path(&f.source) })
                            .show_ui(ui, |ui| {
                                for s in &sources {
                                    if ui.selectable_label(f.source == *s, fmt::short_path(s)).clicked() {
                                        f.source = s.clone();
                                        if !f.folder_touched {
                                            f.folder = s.rsplit('/').next().unwrap_or("").to_string();
                                        }
                                    }
                                }
                            });
                        if ui.button("📁").on_hover_text("Parcourir les dossiers de l'OMV").clicked() {
                            browse = true;
                        }
                    });
                    ui.add(egui::TextEdit::singleline(&mut f.source).desired_width(340.0).font(egui::TextStyle::Small));
                });
                ui.end_row();

                ui.label("Dossier sur le Drive");
                if ui.add(egui::TextEdit::singleline(&mut f.folder).desired_width(300.0)).changed() {
                    f.folder_touched = true;
                }
                ui.end_row();

                ui.label("Mode");
                ui.vertical(|ui| {
                    ui.radio_value(&mut f.mirror, true, "Miroir : le Drive devient identique au NAS");
                    ui.radio_value(&mut f.mirror, false, "Copie : ajoute et met à jour, ne supprime jamais");
                });
                ui.end_row();

                if f.mirror {
                    ui.label("Corbeille (jours)");
                    ui.horizontal(|ui| {
                        ui.add(egui::TextEdit::singleline(&mut f.trash_days).desired_width(50.0));
                        ui.label(RichText::new("fichiers supprimés/modifiés gardés sur le Drive (0 = aucune)").small().weak());
                    });
                    ui.end_row();
                }

                ui.label("Chiffrement");
                ui.checkbox(&mut f.encrypt, "Chiffrer (illisible sur le Drive sans les mots de passe)");
                ui.end_row();

                ui.label("Horaire");
                ui.horizontal(|ui| {
                    ui.checkbox(&mut f.manual, "Manuel");
                    if !f.manual {
                        ui.label("chaque jour à");
                        ui.add(egui::TextEdit::singleline(&mut f.hour).desired_width(60.0).hint_text("03:30"));
                    }
                });
                ui.end_row();
            });
            if !f.new {
                ui.label(RichText::new("Changer le dossier Drive ou le chiffrement : les fichiers déjà envoyés restent à l'ancien emplacement.").small().weak());
            }
            if !f.error.is_empty() {
                ui.colored_label(ERR, &f.error);
            }
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                if primary_button(ui, "Enregistrer").clicked() {
                    save = true;
                }
                if ui.button("Annuler").clicked() {
                    cancel = true;
                }
            });
        });
    if browse {
        let start = if f.source.is_empty() { String::new() } else { f.source.rsplit_once('/').map(|(a, _)| a.to_string()).unwrap_or_default() };
        app.job_form = Some(f);
        app.open_browser(HostId::Omv, BrowsePurpose::BackupSource, &start);
        return;
    }
    if !open || cancel {
        return;
    }
    if save {
        let name = f.name.trim().to_string();
        let folder = f.folder.trim().trim_matches('/').to_string();
        let src = f.source.trim().trim_end_matches('/').to_string();
        let err = if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
            "Nom invalide : lettres, chiffres, - et _ uniquement."
        } else if src.is_empty() {
            "Choisis le dossier à sauvegarder."
        } else if folder.is_empty() || folder.contains('|') || folder.starts_with("_corbeille") {
            "Dossier Drive invalide."
        } else if !f.manual && !valid_hour(f.hour.trim()) {
            "Horaire invalide (format HH:MM, ex : 03:30)."
        } else if f.mirror && f.trash_days.trim().parse::<u32>().is_err() {
            "Nombre de jours de corbeille invalide."
        } else {
            ""
        };
        if !err.is_empty() {
            f.error = err.into();
            app.job_form = Some(f);
            return;
        }
        let sched = if f.manual { "manuel".to_string() } else { f.hour.trim().to_string() };
        let days = if f.mirror { f.trash_days.trim().parse().unwrap_or(0) } else { 0 };
        let script = remote::nb_save(
            f.new,
            &remote::JobForm {
                name: &name,
                source: &src,
                folder: &folder,
                mirror: f.mirror,
                encrypt: f.encrypt,
                schedule: &sched,
                trash_days: days,
            },
        );
        let title = if f.new { "Nouvelle sauvegarde" } else { "Modification" };
        app.action_dialog(HostId::Omv, title, script, 120);
        return;
    }
    app.job_form = Some(f);
}

pub fn restore_window(app: &mut App, ctx: &egui::Context) {
    let Some(mut r) = app.restore.take() else { return };
    let mut open = true;
    let mut go = false;
    let mut cancel = false;
    let mut browse = false;
    egui::Window::new(RichText::new(format!("Restaurer « {} »", r.job)).strong())
        .id(egui::Id::unique("restore"))
        .collapsible(false)
        .resizable(false)
        .default_width(560.0)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            ui.label("Les fichiers du Drive sont recopiés (déchiffrés si besoin) dans ce dossier de l'OMV :");
            ui.horizontal(|ui| {
                ui.add(egui::TextEdit::singleline(&mut r.target).desired_width(440.0));
                if ui.button("📁").clicked() {
                    browse = true;
                }
            });
            if r.target.trim_end_matches('/') == r.source.trim_end_matches('/') {
                ui.colored_label(ERR, "⚠ C'est le dossier source : les fichiers locaux seront écrasés par ceux du Drive.");
            }
            ui.label(RichText::new("La restauration tourne en arrière-plan ; son avancement s'affiche sur la page Sauvegardes.").small().weak());
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                if primary_button(ui, "⤓ Restaurer").clicked() {
                    go = true;
                }
                if ui.button("Annuler").clicked() {
                    cancel = true;
                }
            });
        });
    if browse {
        let start = r.target.rsplit_once('/').map(|(a, _)| a.to_string()).unwrap_or_default();
        app.restore = Some(r);
        app.open_browser(HostId::Omv, BrowsePurpose::RestoreTarget, &start);
        return;
    }
    if !open || cancel {
        return;
    }
    if go && !r.target.trim().is_empty() {
        app.action_toast(HostId::Omv, "Restauration", remote::nb_restore(&r.job, r.target.trim()), 30);
        return;
    }
    app.restore = Some(r);
}

pub fn browser_window(app: &mut App, ctx: &egui::Context) {
    let Some(b) = &app.browser else { return };
    let (host, cur, entries, loading, purpose) = (b.host, b.cur.clone(), b.entries.clone(), b.loading, b.purpose);
    let mut new_folder = b.new_folder.clone();
    let mut open = true;
    let mut go: Option<String> = None;
    let mut pick: Option<String> = None;
    let mut mkdir = false;
    let root_label = match host {
        HostId::Omv => "Disques de l'OMV",
        HostId::Syno => "Dossiers partagés du Synology",
    };
    let can_mkdir = matches!(purpose, BrowsePurpose::CopyDest | BrowsePurpose::RestoreTarget);
    egui::Window::new(RichText::new(format!("Choisir un dossier — {}", host.label())).strong())
        .id(egui::Id::unique("browser"))
        .collapsible(false)
        .resizable(true)
        .default_size([560.0, 460.0])
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            ui.horizontal(|ui| {
                if ui.add_enabled(!cur.is_empty() && cur != "/", egui::Button::new("⬆ Remonter")).clicked() {
                    let up = match host {
                        HostId::Omv => {
                            if cur.matches('/').count() <= 2 {
                                String::new()
                            } else {
                                cur.rsplit_once('/').map(|(a, _)| a.to_string()).unwrap_or_default()
                            }
                        }
                        HostId::Syno => {
                            if cur.matches('/').count() <= 2 {
                                String::new()
                            } else {
                                cur.rsplit_once('/').map(|(a, _)| a.to_string()).unwrap_or_default()
                            }
                        }
                    };
                    go = Some(up);
                }
                ui.label(RichText::new(if cur.is_empty() { root_label.to_string() } else { cur.clone() }).strong());
            });
            ui.separator();
            egui::ScrollArea::vertical().max_height(300.0).auto_shrink([false, true]).show(ui, |ui| {
                if loading {
                    ui.spinner();
                } else if entries.is_empty() {
                    ui.label(RichText::new("(aucun sous-dossier)").weak());
                }
                for e in &entries {
                    let name = if cur.is_empty() {
                        match host {
                            HostId::Omv => fmt::short_path(e),
                            HostId::Syno => e.clone(),
                        }
                    } else {
                        e.rsplit('/').next().unwrap_or(e).to_string()
                    };
                    let r = ui.add(egui::Button::selectable(false, format!("📁 {name}")));
                    if r.clicked() {
                        go = Some(e.clone());
                    }
                }
            });
            ui.separator();
            if can_mkdir && !cur.is_empty() {
                ui.horizontal(|ui| {
                    ui.add(egui::TextEdit::singleline(&mut new_folder).hint_text("nouveau dossier").desired_width(200.0));
                    if ui.add_enabled(!new_folder.trim().is_empty() && !new_folder.contains('/'), egui::Button::new("Créer")).clicked() {
                        mkdir = true;
                    }
                });
            }
            ui.horizontal(|ui| {
                if ui
                    .add_enabled(!cur.is_empty(), egui::Button::new(RichText::new("✔ Choisir ce dossier").color(Color32::WHITE)).fill(INFO))
                    .clicked()
                {
                    pick = Some(cur.clone());
                }
                if ui.button("Annuler").clicked() {
                    app.browser = None;
                }
            });
        });
    if let Some(b) = &mut app.browser {
        b.new_folder = new_folder.clone();
    }
    if !open {
        app.browser = None;
        return;
    }
    if let Some(p) = pick {
        app.browser_pick(p);
    } else if let Some(g) = go {
        app.browser_load(g);
    } else if mkdir {
        let path = format!("{}/{}", cur, new_folder.trim());
        let script = format!("mkdir -p {} && echo ok\n", crate::ssh::sq(&path));
        if let Some(b) = &mut app.browser {
            b.new_folder.clear();
        }
        app.exec(
            host,
            "Création du dossier",
            script,
            20,
            Box::new(move |app, r| match r {
                Ok(o) if o.code == 0 => app.browser_load(path),
                Ok(o) => app.toast(false, o.text()),
                Err(e) => app.toast(false, e.to_string()),
            }),
        );
    }
}

// =====================================================================
//  Cameras
// =====================================================================

pub fn cameras(app: &mut App, ui: &mut egui::Ui) {
    page_title(ui, "Caméras", "Synchro temps réel chiffrée du dossier des caméras vers Google Drive");
    if !host_banner(app, ui, HostId::Omv) {
        return;
    }
    let s = app.omv.status.clone().unwrap();
    let c = s.cameras.clone();
    if !c.installe {
        banner(ui, IDLE, "La synchro des caméras n'est pas installée sur l'OMV (script install-cam-sync.sh).");
        return;
    }
    let now = s.maintenant.max(fmt::now());
    ui.columns(3, |cols| {
        card(&mut cols[0], "Service temps réel", |ui| {
            dot_label(ui, if c.actif { OK } else { ERR }, RichText::new(if c.actif { "Actif" } else { "Arrêté" }).strong());
            ui.label(RichText::new(if c.demarrage_auto { "Démarre avec l'OMV" } else { "Ne démarre PAS avec l'OMV" }).small().weak());
            if c.actif && !c.actif_depuis.is_empty() {
                ui.label(RichText::new(format!("Depuis {}", c.actif_depuis)).small().weak());
            }
        });
        card(&mut cols[1], "Envois", |ui| {
            match c.dernier_envoi.as_deref().and_then(fmt::parse_rclone_ts) {
                Some(t) => ui.label(RichText::new(format!("Dernière vidéo {}", fmt::ago(t, now))).strong()),
                None => ui.label(RichText::new("Aucun envoi récent").weak()),
            };
            ui.label(format!("{} vidéo(s) envoyée(s) aujourd'hui", c.envois_aujourdhui));
        });
        card(&mut cols[2], "Rattrapage (toutes les 15 min)", |ui| {
            if c.rattrapage_en_cours {
                ui.horizontal(|ui| {
                    ui.spinner();
                    ui.label("En cours");
                });
            } else {
                ui.label("En attente");
            }
            if c.erreurs_aujourdhui > 0 {
                ui.colored_label(ERR, format!("{} erreur(s) aujourd'hui", c.erreurs_aujourdhui));
            } else {
                ui.label(RichText::new("Aucune erreur aujourd'hui").small().weak());
            }
        });
    });
    ui.add_space(8.0);
    ui.horizontal(|ui| {
        if c.actif {
            if ui.button("⟳ Redémarrer le service").clicked() {
                app.action_toast(HostId::Omv, "Redémarrage", remote::cam_service("restart"), 40);
            }
            if danger_button(ui, "⏹ Arrêter").clicked() {
                app.ask_confirm(
                    "Arrêter la synchro des caméras",
                    "Les nouvelles vidéos ne partiront plus vers le Drive en temps réel (le rattrapage toutes les 15 min continue).",
                    "Arrêter",
                    true,
                    None,
                    Box::new(|app| app.action_toast(HostId::Omv, "Arrêt", remote::cam_service("stop"), 40)),
                );
            }
        } else if primary_button(ui, "▶ Démarrer le service").clicked() {
            app.action_toast(HostId::Omv, "Démarrage", remote::cam_service("start"), 40);
        }
        if ui.add_enabled(!c.rattrapage_en_cours, egui::Button::new("☁ Lancer un rattrapage maintenant")).clicked() {
            app.action_toast(HostId::Omv, "Rattrapage", remote::cam_catchup(), 30);
        }
        if ui.button("📜 Journal complet").clicked() {
            app.page = Page::Logs;
            app.logs.source = log_sources(app).iter().position(|l| l.path == "/var/log/cam-sync.log").unwrap_or(0);
            app.logs.last_fetch = None;
        }
    });
    if !c.dossier.is_empty() {
        ui.label(RichText::new(format!("Dossier surveillé : {}", c.dossier)).small().weak());
    }
    ui.add_space(8.0);
    if let Some(e) = &c.derniere_erreur {
        banner(ui, ERR, &format!("Dernière erreur : {e}"));
        ui.add_space(6.0);
    }
    card(ui, "Derniers événements", |ui| {
        if c.evenements.is_empty() {
            ui.label(RichText::new("(rien dans le journal)").weak());
        }
        for e in c.evenements.iter().rev() {
            let col = if e.contains(" ERROR ") {
                ERR
            } else if e.contains("Deleted") {
                WARN
            } else {
                ui.visuals().text_color()
            };
            ui.label(RichText::new(e).monospace().size(12.0).color(col));
        }
    });
}

// =====================================================================
//  Alertes et sante
// =====================================================================

pub fn alerts(app: &mut App, ui: &mut egui::Ui) {
    page_title(ui, "Alertes & santé", "Vérifications horaires (nas-check) et notifications Home Assistant");
    if !host_banner(app, ui, HostId::Omv) {
        return;
    }
    let s = app.omv.status.clone().unwrap();
    let now = s.maintenant.max(fmt::now());
    if !s.alertes_installees {
        banner(ui, WARN, "Les alertes ne sont pas installées sur l'OMV (script install-alertes.sh).");
        ui.add_space(6.0);
    }
    ui.columns(2, |cols| {
        card(&mut cols[0], "☁ Google Drive", |ui| match &s.sante {
            None => {
                ui.label(RichText::new("Pas encore vérifié.").weak());
            }
            Some(h) => {
                dot_label(ui, if h.gdrive { OK } else { ERR }, if h.gdrive { "Connexion OK" } else { "Connexion en échec" });
                if !h.gdrive {
                    ui.label(RichText::new("Sur l'OMV : rclone config reconnect gdrive:").small().monospace());
                }
                if let Some(p) = h.quota_pct {
                    let col = if p >= 90.0 { ERR } else if p >= 75.0 { WARN } else { OK };
                    ui.add(egui::ProgressBar::new((p / 100.0) as f32).fill(col).text(match (h.used_go, h.total_go) {
                        (Some(u), Some(t)) => format!("{p:.0} % utilisé · {u:.1} Go sur {t:.0} Go"),
                        _ => format!("{p:.0} % utilisé"),
                    }));
                }
                if let Some(c) = &h.checked {
                    ui.label(RichText::new(format!("Dernière vérification : {}", c.replace('T', " ").chars().take(16).collect::<String>())).small().weak());
                }
            }
        });
        card(&mut cols[1], "Actions", |ui| {
            ui.horizontal_wrapped(|ui| {
                if ui.add_enabled(s.alertes_installees && !s.nas_check_en_cours, egui::Button::new("🔍 Vérifier maintenant")).clicked() {
                    app.action_toast(HostId::Omv, "Vérification", remote::nas_check(), 30);
                }
                if s.nas_check_en_cours {
                    ui.spinner();
                }
                if ui.add_enabled(s.alertes_installees, egui::Button::new("📱 Notification de test")).clicked() {
                    app.action_toast(HostId::Omv, "Notification", remote::notify_test(), 30);
                }
                if ui.button("🔑 Mots de passe de chiffrement").on_hover_text("Indispensables pour relire les sauvegardes chiffrées").clicked() {
                    app.exec(
                        HostId::Omv,
                        "Lecture",
                        remote::show_passwords(),
                        20,
                        Box::new(|app, r| match r {
                            Ok(o) => app.passwords = Some(o.text()),
                            Err(e) => app.toast(false, e.to_string()),
                        }),
                    );
                }
            });
            ui.label(RichText::new(if s.suivi_ha { "Suivi Home Assistant (MQTT) installé." } else { "Suivi Home Assistant (MQTT) non installé." }).small().weak());
        });
    });
    ui.add_space(8.0);
    card(ui, &format!("🔔 Alertes en cours ({})", s.alertes.len()), |ui| {
        if s.alertes.is_empty() {
            dot_label(ui, OK, "Aucune alerte en cours.");
        }
        for a in &s.alertes {
            ui.horizontal(|ui| {
                dot(ui, ERR);
                ui.label(RichText::new(alert_label(&a.tag)).strong());
                ui.label(RichText::new(format!("depuis {}", fmt::ago(a.depuis, now).replace("il y a ", ""))).weak());
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui
                        .button("Acquitter")
                        .on_hover_text("Retire l'alerte. Si le problème persiste, elle reviendra à la prochaine vérification.")
                        .clicked()
                    {
                        app.action_toast(HostId::Omv, "Acquittement", remote::ack_alert(&a.tag), 20);
                    }
                });
            });
        }
        ui.label(RichText::new("Une alerte non résolue est rappelée sur le téléphone toutes les 12 h.").small().weak());
    });
}

fn alert_label(tag: &str) -> String {
    if let Some(n) = tag.strip_prefix("job-") {
        return format!("Sauvegarde « {n} » en échec");
    }
    if let Some(n) = tag.strip_prefix("retard-") {
        return format!("Sauvegarde « {n} » en retard");
    }
    match tag {
        "gdrive" => "Google Drive inaccessible".into(),
        "quota" => "Google Drive presque plein".into(),
        "cam-service" => "Caméras : service arrêté".into(),
        "cam-sync" => "Caméras : envoi en échec".into(),
        t => t.to_string(),
    }
}

pub fn passwords_window(app: &mut App, ctx: &egui::Context) {
    let Some(t) = app.passwords.clone() else { return };
    let mut open = true;
    egui::Window::new(RichText::new("🔑 Mots de passe de chiffrement").strong())
        .id(egui::Id::unique("pwd"))
        .collapsible(false)
        .default_width(600.0)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            banner(ui, WARN, "Sans ces mots de passe, les sauvegardes chiffrées du Drive sont définitivement illisibles. Garde-les en lieu sûr, hors du NAS (gestionnaire de mots de passe).");
            ui.add_space(6.0);
            let mut tt = t.clone();
            ui.add(egui::TextEdit::multiline(&mut tt).font(egui::TextStyle::Monospace).desired_width(f32::INFINITY));
            ui.horizontal(|ui| {
                if ui.button("📋 Copier").clicked() {
                    ui.ctx().copy_text(t.clone());
                }
                if ui.button("Fermer").clicked() {
                    app.passwords = None;
                }
            });
        });
    if !open {
        app.passwords = None;
    }
}

// =====================================================================
//  Copie Synology -> OMV
// =====================================================================

fn syno_script_banner(app: &mut App, ui: &mut egui::Ui, installed: bool, api: u32, name: &str) -> bool {
    if installed && api >= remote::API_VERSION {
        return true;
    }
    banner(
        ui,
        WARN,
        &if installed {
            format!("La version de {name} installée sur le Synology est ancienne : mets-la à jour pour la piloter depuis l'application.")
        } else {
            format!("{name} n'est pas encore installé dans /usr/local/bin sur le Synology (les copies et l'historique faits avec l'ancien script restent visibles).")
        },
    );
    if ui.button("⬆ Installer / mettre à jour les scripts du Synology").clicked() {
        install_syno_scripts(app);
    }
    ui.add_space(6.0);
    false
}

pub fn copy(app: &mut App, ui: &mut egui::Ui) {
    page_title(ui, "Copie Synology → OMV", "Copie ou déplacement d'un dossier du Synology vers l'OMV (rsync)");
    if !host_banner(app, ui, HostId::Syno) {
        return;
    }
    let s = app.syno.status.clone().unwrap();
    let c = s.copie.clone();
    let ready = syno_script_banner(app, ui, c.installe, c.api, "copie-omv");
    if !c.cle_omv {
        banner(ui, WARN, "Le Synology n'a pas encore de connexion automatique vers l'OMV.");
        if ui.button("🔑 Autoriser le Synology à écrire sur l'OMV").clicked() {
            authorize_syno_to_omv(app);
        }
        ui.add_space(6.0);
    }

    // ---- Copie en cours / derniere copie
    if c.source.is_some() {
        card(ui, if c.en_cours { "Copie en cours" } else { "Dernière copie" }, |ui| {
            let src = c.source.clone().unwrap_or_default();
            ui.label(RichText::new(format!("{}  →  OMV : {}", src, c.destination.clone().unwrap_or_default())).strong());
            ui.label(
                RichText::new(format!(
                    "{} · {} · {} fichiers",
                    if c.mode.as_deref() == Some("deplacement") { "Déplacement (originaux supprimés)" } else { "Copie" },
                    fmt::bytes(c.total),
                    c.nb_fichiers
                ))
                .small(),
            );
            if c.en_cours {
                match &c.avancement {
                    Some(p) => progress_bar(
                        ui,
                        Some(p.pct),
                        format!("{} % · {} copiés · {} · reste {}", p.pct, p.fait, p.vitesse, p.reste),
                    ),
                    None => progress_bar(ui, None, "Préparation de la liste des fichiers…".into()),
                }
                if c.debut > 0 {
                    ui.label(RichText::new(format!("Lancée {}", fmt::ago(c.debut, s.maintenant))).small().weak());
                }
                if danger_button(ui, "⏹ Arrêter la copie").clicked() {
                    app.ask_confirm(
                        "Arrêter la copie",
                        "La copie s'arrête. La relancer (même source, même destination) reprendra là où elle s'est arrêtée.",
                        "Arrêter",
                        true,
                        None,
                        Box::new(|app| app.action_toast(HostId::Syno, "Arrêt", remote::copie_stop(), 30)),
                    );
                }
            } else {
                match c.code.as_deref() {
                    Some("0") => dot_label(ui, OK, "Terminée avec succès"),
                    Some("stop") => dot_label(ui, WARN, "Arrêtée manuellement"),
                    Some(code) => dot_label(ui, ERR, format!("Terminée avec une erreur (code {code}) — la relancer reprendra où elle s'est arrêtée")),
                    None => dot_label(ui, WARN, "Interrompue"),
                };
                for l in &c.erreurs {
                    ui.label(RichText::new(l).monospace().size(12.0).color(ERR));
                }
                if ready
                    && ui
                        .button("⟳ Relancer la même copie")
                        .on_hover_text("Reprend là où elle s'était arrêtée")
                        .clicked()
                {
                    // destination finale -> dossier parent + placement
                    let src = c.source.clone().unwrap_or_default();
                    let dst = c.destination.clone().unwrap_or_default();
                    let name = src.rsplit('/').next().unwrap_or("").to_string();
                    let (parent, into) = match dst.rsplit_once('/') {
                        Some((p, last)) if last == name => (p.to_string(), true),
                        _ => (dst.clone(), false),
                    };
                    app.copy.src = src;
                    app.copy.dst = parent;
                    app.copy.into_folder = into;
                    app.copy.move_files = c.mode.as_deref() == Some("deplacement");
                    app.copy.src_size = None;
                    app.copy.dst_free = None;
                    app.compute_copy_free();
                }
            }
        });
        ui.add_space(10.0);
    }

    // ---- Nouvelle copie
    let running = c.en_cours;
    card(ui, "Nouvelle copie", |ui| {
        ui.add_enabled_ui(!running && ready, |ui| {
            egui::Grid::new("copygrid").num_columns(2).spacing([12.0, 10.0]).show(ui, |ui| {
                ui.label("Dossier du Synology");
                ui.horizontal(|ui| {
                    let r = ui.add(egui::TextEdit::singleline(&mut app.copy.src).desired_width(380.0).hint_text("/volume1/…"));
                    if r.lost_focus() && r.changed() {
                        app.copy.src_size = None;
                    }
                    if ui.button("📁 Parcourir").clicked() {
                        app.open_browser(HostId::Syno, BrowsePurpose::CopySource, "");
                    }
                });
                ui.end_row();
                ui.label("");
                ui.horizontal(|ui| match (app.copy.src_size, app.copy.sizing) {
                    (_, true) => {
                        ui.spinner();
                        ui.label(RichText::new("Calcul de la taille…").small());
                    }
                    (Some((sz, nb)), _) => {
                        ui.label(RichText::new(format!("{} · {} fichiers", fmt::bytes(sz), nb)).small());
                    }
                    (None, _) => {
                        if ui.add_enabled(!app.copy.src.is_empty(), egui::Button::new("Calculer la taille").small()).clicked() {
                            app.compute_copy_size();
                        }
                    }
                });
                ui.end_row();

                ui.label("Dossier de l'OMV");
                ui.horizontal(|ui| {
                    let r = ui.add(egui::TextEdit::singleline(&mut app.copy.dst).desired_width(380.0).hint_text("/srv/dev-disk-by-uuid-…/…"));
                    if r.lost_focus() && r.changed() {
                        app.copy.dst_free = None;
                        app.compute_copy_free();
                    }
                    if ui.button("📁 Parcourir").clicked() {
                        app.open_browser(HostId::Omv, BrowsePurpose::CopyDest, "");
                    }
                });
                ui.end_row();
                if let Some(f) = app.copy.dst_free {
                    ui.label("");
                    let enough = app.copy.src_size.map(|(sz, _)| sz <= f).unwrap_or(true);
                    if enough {
                        ui.label(RichText::new(format!("{} libres sur l'OMV", fmt::bytes(f))).small());
                    } else {
                        ui.colored_label(ERR, format!("Pas assez de place : {} libres sur l'OMV", fmt::bytes(f)));
                    }
                    ui.end_row();
                }

                let mut name = app.copy.src.trim_end_matches('/').rsplit('/').next().unwrap_or("").to_string();
                if name.is_empty() {
                    name = "dossier".into();
                }
                let mut dst = app.copy.dst.trim_end_matches('/').to_string();
                if dst.is_empty() {
                    dst = "destination".into();
                }
                ui.label("Placement");
                ui.vertical(|ui| {
                    ui.radio_value(&mut app.copy.into_folder, true, format!("Dans un dossier « {name} »  →  {}/{name}/…", fmt::short_path(&dst)));
                    ui.radio_value(&mut app.copy.into_folder, false, format!("Directement dans le dossier choisi  →  {}/…", fmt::short_path(&dst)));
                    if !name.is_empty() && dst.ends_with(&format!("/{name}")) && app.copy.into_folder {
                        ui.label(RichText::new(format!("(même nom des deux côtés : « directement » évite un dossier {name}/{name})")).small().color(WARN));
                    }
                });
                ui.end_row();

                ui.label("Mode");
                ui.vertical(|ui| {
                    ui.radio_value(&mut app.copy.move_files, false, "Copier : les originaux restent sur le Synology");
                    ui.radio_value(&mut app.copy.move_files, true, RichText::new("Déplacer : les originaux sont SUPPRIMÉS du Synology après copie").color(ERR));
                });
                ui.end_row();
            });
            ui.label(
                RichText::new("Si la destination contient déjà des fichiers : fusion (rien n'y est supprimé, les fichiers de même nom mais différents sont remplacés). Les fichiers prennent les droits du dossier de destination.")
                    .small()
                    .weak(),
            );
            ui.add_space(6.0);
            let can = !app.copy.src.trim().is_empty() && !app.copy.dst.trim().is_empty();
            if ui.add_enabled(can, egui::Button::new(RichText::new("▶ Lancer").color(Color32::WHITE)).fill(INFO)).clicked() {
                let (src, dst, into, mv) = (
                    app.copy.src.trim().trim_end_matches('/').to_string(),
                    app.copy.dst.trim().trim_end_matches('/').to_string(),
                    app.copy.into_folder,
                    app.copy.move_files,
                );
                let final_dst = if into { format!("{dst}/{}", src.rsplit('/').next().unwrap_or("")) } else { dst.clone() };
                let text = format!(
                    "{}\n{}\n  →  OMV : {}",
                    if mv { "DÉPLACEMENT (les originaux seront effacés du Synology au fur et à mesure) :" } else { "Copie :" },
                    src,
                    final_dst
                );
                app.ask_confirm(
                    if mv { "Déplacer vers l'OMV" } else { "Copier vers l'OMV" },
                    &text,
                    "Lancer",
                    mv,
                    if mv { Some("DEPLACER") } else { None },
                    Box::new(move |app| {
                        app.action_dialog(HostId::Syno, "Lancement de la copie", remote::copie_launch(&src, &dst, into, mv), 1200)
                    }),
                );
            }
        });
        if running {
            ui.label(RichText::new("Une copie est en cours : attends sa fin ou arrête-la pour en lancer une autre.").small().weak());
        }
    });
    ui.add_space(10.0);

    egui::CollapsingHeader::new("🛠 Réparer les droits d'un dossier sur l'OMV").show(ui, |ui| {
        ui.horizontal(|ui| {
            ui.add(egui::TextEdit::singleline(&mut app.perms.dir).desired_width(380.0).hint_text("dossier de l'OMV"));
            if ui.button("📁").clicked() {
                app.open_browser(HostId::Omv, BrowsePurpose::PermsDir, "");
            }
        });
        ui.horizontal(|ui| {
            ui.label("Propriétaire");
            ui.add(egui::TextEdit::singleline(&mut app.perms.owner).desired_width(90.0));
            ui.label("Groupe");
            ui.add(egui::TextEdit::singleline(&mut app.perms.group).desired_width(90.0));
            if ui.add_enabled(!app.perms.dir.is_empty(), egui::Button::new("Appliquer")).clicked() {
                let (d, o, g) = (app.perms.dir.clone(), app.perms.owner.clone(), app.perms.group.clone());
                app.ask_confirm(
                    "Réparer les droits",
                    &format!("Sur tout le contenu de {d} : propriétaire {o}:{g}, dossiers 2775, fichiers 664."),
                    "Appliquer",
                    false,
                    None,
                    Box::new(move |app| app.action_dialog(HostId::Omv, "Réparation des droits", remote::fix_perms(&d, &o, &g), 1800)),
                );
            }
        });
        ui.label(RichText::new("Groupe « users » = tous les utilisateurs du partage OMV.").small().weak());
    });
    ui.add_space(10.0);

    card(ui, "Historique", |ui| {
        if c.historique.is_empty() {
            ui.label(RichText::new("Aucune copie.").weak());
        }
        for l in c.historique.iter().rev() {
            let col = if l.contains("| OK |") {
                OK
            } else if l.contains("ARRETEE") {
                WARN
            } else {
                ERR
            };
            ui.horizontal(|ui| {
                dot(ui, col);
                ui.label(RichText::new(hist_line(l)).small()).on_hover_text(l);
            });
        }
    });
}

/// "2026-10-18 12:38 | OK | copie | /src -> /dst | 3 min" -> forme courte
fn hist_line(l: &str) -> String {
    let p: Vec<&str> = l.split(" | ").collect();
    if p.len() < 4 {
        return l.to_string();
    }
    let when = fmt::parse_status_ts(p[0]).map(fmt::date).unwrap_or_else(|| p[0].to_string());
    let (src, dst) = p[p.len() - 2].split_once(" -> ").unwrap_or((p[p.len() - 2], ""));
    let dur = p.last().unwrap_or(&"");
    let extra = if p.len() >= 5 { format!(" · {}", p[2]) } else { String::new() };
    format!("{when} · {}{extra} · {}  →  {} · {dur}", p[1], src, fmt::short_path(dst))
}

// =====================================================================
//  Migration oCIS
// =====================================================================

pub fn migration(app: &mut App, ui: &mut egui::Ui) {
    page_title(ui, "Migration Synology Drive → oCIS", "Transfert des « Mon Drive » vers des espaces projets ownCloud Infinite Scale");
    if !host_banner(app, ui, HostId::Syno) {
        return;
    }
    let s = app.syno.status.clone().unwrap();
    let m = s.migration.clone();
    let ready = syno_script_banner(app, ui, m.installe, m.api, "migre-drive-ocis");
    if ready && m.config.is_some() && !app.mig.auto_loaded {
        app.mig.auto_loaded = true;
        load_spaces(app);
        load_mig_sources(app);
    }

    // ---- Connexion oCIS
    card(ui, "Connexion oCIS", |ui| {
        match &m.config {
            Some(c) => {
                ui.label(format!("{}  ·  compte {}", c.url, c.utilisateur));
                ui.label(
                    RichText::new(format!(
                        "Transferts : {}  ·  mode {}",
                        if c.locale.is_empty() { "via Internet".to_string() } else { format!("réseau local ({})", c.locale) },
                        if c.mode == "owncloud" { "WebDAV classique".to_string() } else { c.mode.clone() }
                    ))
                    .small()
                    .weak(),
                );
            }
            None => {
                ui.colored_label(WARN, "Pas encore configurée.");
            }
        }
        if ui.add_enabled(ready, egui::Button::new(if app.ocis.open { "Fermer" } else { "Modifier la connexion…" })).clicked() {
            app.ocis.open = !app.ocis.open;
            if app.ocis.open {
                if let Some(c) = &m.config {
                    app.ocis.url = c.url.clone();
                    app.ocis.user = c.utilisateur.clone();
                    app.ocis.local = c.locale.clone();
                    app.ocis.insecure = c.certificat_accepte;
                } else if app.ocis.local.is_empty() {
                    app.ocis.local = "https://192.168.1.53:9200".into();
                }
                app.ocis.token.clear();
            }
        }
        if app.ocis.open {
            egui::Grid::new("ocisgrid").num_columns(2).spacing([12.0, 8.0]).show(ui, |ui| {
                ui.label("Adresse d'oCIS");
                ui.add(egui::TextEdit::singleline(&mut app.ocis.url).hint_text("https://cloud.maison.fr").desired_width(320.0));
                ui.end_row();
                ui.label("Utilisateur");
                ui.add(egui::TextEdit::singleline(&mut app.ocis.user).desired_width(200.0));
                ui.end_row();
                ui.label("Jeton d'application");
                ui.add(egui::TextEdit::singleline(&mut app.ocis.token).password(true).desired_width(320.0));
                ui.end_row();
                ui.label("Adresse locale");
                ui.add(egui::TextEdit::singleline(&mut app.ocis.local).hint_text("vide = passer par Internet").desired_width(320.0));
                ui.end_row();
                ui.label("");
                ui.checkbox(&mut app.ocis.insecure, "Accepter un certificat non reconnu (auto-signé)");
                ui.end_row();
            });
            ui.label(RichText::new("Jeton : docker exec <conteneur-ocis> ocis auth-app create --user-name=<compte> --expiration=2160h").small().monospace().weak());
            let can = !app.ocis.url.trim().is_empty() && !app.ocis.user.trim().is_empty() && !app.ocis.token.trim().is_empty();
            if ui.add_enabled(can, egui::Button::new("Tester et enregistrer")).clicked() {
                let f = app.ocis.clone();
                app.ocis.open = false;
                app.ocis.token.clear();
                app.action_dialog(
                    HostId::Syno,
                    "Connexion à oCIS",
                    remote::migre_configure(&f.url, &f.user, &f.token, &f.local, f.insecure),
                    300,
                );
            }
        }
    });
    ui.add_space(10.0);

    // ---- Migration en cours
    if m.en_cours {
        card(ui, "Migration en cours", |ui| {
            if let Some(e) = &m.etape {
                ui.label(RichText::new(format!("[{}/{}]  {}  →  {}", e.etape, m.nb, e.libelle, e.espace)).strong());
                ui.label(RichText::new(format!("{} · {}", e.source, fmt::bytes(e.total))).small().weak());
                let phase = match e.phase.as_str() {
                    "verification" => "Contrôle des empreintes dans oCIS",
                    "relecture" => "Contrôle par relecture depuis oCIS",
                    "suppression" => "Suppression des originaux contrôlés",
                    _ => "Transfert",
                };
                ui.label(phase);
                let line = if e.ligne.is_empty() {
                    if e.phase.is_empty() { "Comparaison avec ce qui est déjà dans oCIS…".into() } else { "démarrage…".into() }
                } else {
                    fmt::stats_line(&e.ligne)
                };
                progress_bar(ui, e.pct, line);
                let mut extra = Vec::new();
                if let Some(r) = e.ram_mo {
                    extra.push(format!("RAM rclone {r} Mo"));
                }
                if e.reprise > 0 {
                    extra.push(format!("reprise automatique {}/5", e.reprise));
                }
                if e.suppression == "oui" {
                    extra.push("+ suppression des originaux contrôlés".into());
                } else if e.suppression == "verif" {
                    extra.push("contrôle + suppression sans transfert".into());
                }
                if !extra.is_empty() {
                    ui.label(RichText::new(extra.join(" · ")).small().color(if e.reprise > 0 { WARN } else { IDLE }));
                }
            }
            if m.debut > 0 {
                ui.label(RichText::new(format!("Lancée {}", fmt::ago(m.debut, s.maintenant))).small().weak());
            }
            if danger_button(ui, "⏹ Arrêter la migration").clicked() {
                app.ask_confirm(
                    "Arrêter la migration",
                    "La migration s'arrête ; les éléments non terminés sont remis en file d'attente et reprendront là où ils en étaient.",
                    "Arrêter",
                    true,
                    None,
                    Box::new(|app| app.action_toast(HostId::Syno, "Arrêt", remote::migre_stop(), 30)),
                );
            }
        });
        ui.add_space(10.0);
    }

    // ---- Resultats
    if !m.resultats.is_empty() {
        card(ui, "Résultats du dernier lancement", |ui| {
            for r in &m.resultats {
                ui.horizontal_wrapped(|ui| {
                    dot(ui, if r.etat == "OK" { OK } else { ERR });
                    ui.label(RichText::new(format!("{} → {}", r.libelle, r.espace)).strong());
                    if !r.detail.is_empty() {
                        ui.label(RichText::new(&r.detail).small());
                    }
                });
            }
            if m.resultats.iter().any(|r| r.detail.contains("quota")) {
                ui.label(RichText::new("Espace plein : dans oCIS, ouvre l'espace > ⋯ > Modifier le quota > « Pas de restriction ».").small().color(WARN));
            }
            if m.resultats.iter().any(|r| r.detail.contains("401")) {
                ui.label(RichText::new("Jeton refusé : recrée un jeton et mets à jour la connexion ci-dessus.").small().color(WARN));
            }
        });
        ui.add_space(10.0);
    }

    // ---- File d'attente
    card(ui, &format!("File d'attente ({})", m.file.len()), |ui| {
        if m.file.is_empty() {
            ui.label(RichText::new("Vide : ajoute une migration ci-dessous.").weak());
        }
        let mut remove: Option<usize> = None;
        for (i, q) in m.file.iter().enumerate() {
            ui.horizontal(|ui| {
                ui.label(RichText::new(format!("{}.", i + 1)).weak());
                ui.label(RichText::new(format!(
                    "{}  →  {}{}",
                    q.libelle,
                    q.espace,
                    if q.sous_dossier.is_empty() { String::new() } else { format!("/{}", q.sous_dossier) }
                )).strong());
                ui.label(RichText::new(fmt::bytes(q.total)).small());
                match q.suppression.as_str() {
                    "oui" => badge(ui, "+ suppression des originaux", ERR),
                    "verif" => badge(ui, "contrôle + suppression", ERR),
                    _ => {}
                }
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.add_enabled(ready && !m.en_cours, egui::Button::new("✖").small()).on_hover_text("Retirer de la file").clicked() {
                        remove = Some(i + 1);
                    }
                });
            });
        }
        if let Some(n) = remove {
            app.action_toast(HostId::Syno, "Retrait", remote::migre_remove(n), 30);
        }
        ui.add_space(4.0);
        if ui
            .add_enabled(ready && !m.en_cours && !m.file.is_empty(), egui::Button::new(RichText::new("▶ Lancer la file d'attente").color(Color32::WHITE)).fill(INFO))
            .clicked()
        {
            let has_delete = m.file.iter().any(|q| q.suppression != "non");
            app.ask_confirm(
                "Lancer la migration",
                &format!(
                    "{} migration(s) vont être traitées l'une après l'autre, en arrière-plan sur le Synology.{}",
                    m.file.len(),
                    if has_delete { "\nCertaines suppriment les originaux du Synology après contrôle dans oCIS." } else { "" }
                ),
                "Lancer",
                false,
                None,
                Box::new(|app| app.action_toast(HostId::Syno, "Lancement", remote::migre_start(), 120)),
            );
        }
    });
    ui.add_space(10.0);

    // ---- Ajouter
    card(ui, "Ajouter une migration", |ui| {
        ui.add_enabled_ui(ready && m.config.is_some(), |ui| {
            if m.config.is_none() {
                ui.colored_label(WARN, "Configure d'abord la connexion oCIS.");
            }
            ui.horizontal(|ui| {
                ui.label("Source :");
                let sel = if app.mig.src.is_empty() { "Choisir…".to_string() } else { app.mig.src.clone() };
                let mut picked: Option<(String, String)> = None;
                egui::ComboBox::from_id_salt("migsrc").width(360.0).selected_text(sel).show_ui(ui, |ui| {
                    if app.mig.sources.is_empty() {
                        ui.label(RichText::new("(clique sur ⟳ pour lister les Mon Drive)").weak());
                    }
                    for (p, l) in &app.mig.sources {
                        if ui.selectable_label(app.mig.src == *p, format!("Mon Drive de {l}")).clicked() {
                            picked = Some((p.clone(), l.clone()));
                        }
                    }
                });
                if let Some((p, l)) = picked {
                    app.mig.src = p;
                    app.mig.label = l;
                }
                if ui.button("⟳").on_hover_text("Lister les « Mon Drive »").clicked() {
                    load_mig_sources(app);
                }
                if ui.button("📁 Parcourir").clicked() {
                    app.open_browser(HostId::Syno, BrowsePurpose::MigSource, "");
                }
            });
            ui.horizontal(|ui| {
                ui.label("Espace oCIS :");
                let sel = app
                    .mig
                    .space_idx
                    .and_then(|i| app.mig.spaces.get(i))
                    .map(|s| s.name.clone())
                    .unwrap_or_else(|| "Choisir…".into());
                let mut pick: Option<usize> = None;
                egui::ComboBox::from_id_salt("migspace").width(300.0).selected_text(sel).show_ui(ui, |ui| {
                    for (i, sp) in app.mig.spaces.iter().enumerate() {
                        let q = if sp.quota > 0 {
                            format!("libre {} / quota {}", fmt::bytes(sp.free.max(0) as u64), fmt::bytes(sp.quota as u64))
                        } else {
                            "sans limite".into()
                        };
                        if ui.selectable_label(app.mig.space_idx == Some(i), format!("{}  ({q})", sp.name)).clicked() {
                            pick = Some(i);
                        }
                    }
                });
                if let Some(i) = pick {
                    app.mig.space_idx = Some(i);
                }
                if app.mig.loading_spaces {
                    ui.spinner();
                } else if ui.button("⟳").on_hover_text("Lister les espaces projets").clicked() {
                    load_spaces(app);
                }
            });
            if !app.mig.spaces_error.is_empty() {
                ui.colored_label(ERR, &app.mig.spaces_error);
            }
            ui.horizontal(|ui| {
                ui.label("Sous-dossier dans l'espace :");
                ui.add(egui::TextEdit::singleline(&mut app.mig.sub).hint_text("vide = racine de l'espace").desired_width(220.0));
                ui.label("Libellé :");
                ui.add(egui::TextEdit::singleline(&mut app.mig.label).desired_width(140.0));
            });
            ui.label("Après le transfert :");
            ui.radio_value(&mut app.mig.del_mode, 0, "Garder les originaux sur le Synology (copie)");
            ui.radio_value(&mut app.mig.del_mode, 1, RichText::new("Contrôler chaque fichier dans oCIS, puis SUPPRIMER l'original du Synology").color(ERR));
            ui.radio_value(&mut app.mig.del_mode, 2, RichText::new("Déjà migré : contrôler et supprimer les originaux, sans transfert").color(ERR));
            if app.mig.del_mode > 0 && app.mig.src.contains("/homes/") && app.mig.src.ends_with("/Drive") {
                ui.label(RichText::new("C'est un « Mon Drive » : les ordinateurs synchronisés avec Synology Drive supprimeront aussi ces fichiers chez eux. Installe d'abord le client oCIS.").small().color(ERR));
            }
            let sp = app.mig.space_idx.and_then(|i| app.mig.spaces.get(i)).cloned();
            let can = !app.mig.src.is_empty() && sp.is_some();
            if ui.add_enabled(can, egui::Button::new("+ Ajouter à la file d'attente")).clicked() {
                let sp = sp.unwrap();
                let (src, sub, label, mode) = (app.mig.src.clone(), app.mig.sub.trim().trim_matches('/').to_string(), app.mig.label.trim().to_string(), app.mig.del_mode);
                let del = match mode {
                    1 => "oui",
                    2 => "verif",
                    _ => "non",
                }
                .to_string();
                let script = remote::migre_add(&src, &sp.id, &sub, &del, &label);
                if mode > 0 {
                    app.ask_confirm(
                        "Suppression des originaux",
                        "Seuls les fichiers dont la copie dans oCIS est contrôlée identique (empreinte) seront supprimés du Synology. Un fichier absent, différent ou modifié entre-temps est gardé.",
                        "Ajouter",
                        true,
                        Some("SUPPRIMER"),
                        Box::new(move |app| app.action_toast(HostId::Syno, "Ajout", script, 900)),
                    );
                } else {
                    app.action_toast(HostId::Syno, "Ajout (calcul de la taille)", script, 900);
                }
            }
        });
    });
    ui.add_space(10.0);

    egui::CollapsingHeader::new("Journal de la migration (dernières lignes)").show(ui, |ui| {
        for l in &m.journal {
            ui.label(RichText::new(l).monospace().size(12.0));
        }
    });
    card(ui, "Historique", |ui| {
        if m.historique.is_empty() {
            ui.label(RichText::new("Aucune migration.").weak());
        }
        for l in m.historique.iter().rev() {
            ui.horizontal(|ui| {
                dot(ui, if l.contains("| OK") { OK } else { ERR });
                ui.label(RichText::new(l).small());
            });
        }
    });
}

fn load_spaces(app: &mut App) {
    app.mig.loading_spaces = true;
    app.mig.spaces_error.clear();
    app.exec(
        HostId::Syno,
        "Espaces oCIS",
        remote::migre_spaces(),
        60,
        Box::new(|app, r| {
            app.mig.loading_spaces = false;
            match r {
                Ok(o) if o.code == 0 => {
                    app.mig.spaces = o
                        .stdout
                        .lines()
                        .filter_map(|l| {
                            let p: Vec<&str> = l.split('|').collect();
                            (p.len() >= 5).then(|| Space {
                                id: p[0].to_string(),
                                name: p[1].to_string(),
                                free: p[3].trim().parse().unwrap_or(-1),
                                quota: p[4].trim().parse().unwrap_or(0),
                            })
                        })
                        .collect();
                    if app.mig.spaces.is_empty() {
                        app.mig.spaces_error = "Aucun espace projet visible : ajoute le compte comme membre des espaces (Peut modifier / Gestionnaire).".into();
                    }
                    app.mig.space_idx = None;
                }
                Ok(o) => app.mig.spaces_error = o.text(),
                Err(e) => app.mig.spaces_error = e.to_string(),
            }
        }),
    );
}

fn load_mig_sources(app: &mut App) {
    app.exec(
        HostId::Syno,
        "Mon Drive",
        remote::migre_sources(),
        30,
        Box::new(|app, r| match r {
            Ok(o) => {
                app.mig.sources = o
                    .stdout
                    .lines()
                    .filter_map(|l| l.split_once('|').map(|(a, b)| (a.to_string(), b.to_string())))
                    .collect();
                if app.mig.sources.is_empty() {
                    app.toast(false, "Aucun « Mon Drive » trouvé (/volume*/homes/*/Drive).".into());
                }
            }
            Err(e) => app.toast(false, e.to_string()),
        }),
    );
}

// =====================================================================
//  Journaux
// =====================================================================

pub struct LogSource {
    pub label: String,
    pub host: HostId,
    pub path: String,
}

pub fn log_sources(app: &App) -> Vec<LogSource> {
    let mut v = vec![LogSource {
        label: "Sauvegardes (nas-backup.log)".into(),
        host: HostId::Omv,
        path: "/var/log/nas-backup.log".into(),
    }];
    if let Some(s) = &app.omv.status {
        for j in &s.sauvegardes {
            v.push(LogSource {
                label: format!("Sauvegarde « {} »{}", j.nom, if j.en_cours { " (en cours)" } else { " (dernière)" }),
                host: HostId::Omv,
                path: format!("/var/lib/nas-backup/{}.run.log", j.nom),
            });
        }
    }
    v.push(LogSource { label: "Caméras (cam-sync.log)".into(), host: HostId::Omv, path: "/var/log/cam-sync.log".into() });
    v.push(LogSource { label: "Restauration".into(), host: HostId::Omv, path: "/var/lib/nas-backup/restauration.log".into() });
    if app.settings.syno.is_set() {
        v.push(LogSource { label: "Copie → OMV : progression".into(), host: HostId::Syno, path: "/root/.copie-omv/progression.log".into() });
        v.push(LogSource { label: "Copie → OMV : historique".into(), host: HostId::Syno, path: "/root/.copie-omv/historique.log".into() });
        v.push(LogSource { label: "Migration oCIS : progression".into(), host: HostId::Syno, path: "/root/.migre-ocis/progression.log".into() });
        v.push(LogSource { label: "Migration oCIS : historique".into(), host: HostId::Syno, path: "/root/.migre-ocis/historique.log".into() });
    }
    v
}

pub fn logs(app: &mut App, ui: &mut egui::Ui) {
    page_title(ui, "Journaux", "Dernières lignes des journaux des scripts");
    let sources = log_sources(app);
    if app.logs.source >= sources.len() {
        app.logs.source = 0;
    }
    let mut changed = false;
    ui.horizontal(|ui| {
        egui::ComboBox::from_id_salt("logsrc")
            .width(330.0)
            .selected_text(&sources[app.logs.source].label)
            .show_ui(ui, |ui| {
                for (i, s) in sources.iter().enumerate() {
                    if ui.selectable_value(&mut app.logs.source, i, format!("{} — {}", s.host.label(), s.label)).clicked() {
                        changed = true;
                    }
                }
            });
        if ui.button("⟳").clicked() {
            changed = true;
        }
        ui.checkbox(&mut app.logs.auto, "Suivre en direct");
        ui.add(egui::TextEdit::singleline(&mut app.logs.filter).hint_text("filtrer…").desired_width(160.0));
        if app.logs.loading {
            ui.spinner();
        }
    });
    let due = app.logs.last_fetch.map(|t| app.logs.auto && t.elapsed().as_secs() >= 5).unwrap_or(true);
    if (changed || due) && !app.logs.loading {
        let src = &sources[app.logs.source];
        let (host, path, idx) = (src.host, src.path.clone(), app.logs.source);
        app.logs.loading = true;
        app.logs.last_fetch = Some(std::time::Instant::now());
        app.exec(
            host,
            "Lecture du journal",
            remote::tail_file(&path, 600),
            30,
            Box::new(move |app, r| {
                app.logs.loading = false;
                if app.logs.source != idx {
                    return;
                }
                app.logs.text = match r {
                    Ok(o) => crate::ssh::strip_ansi(&o.stdout),
                    Err(e) => format!("(lecture impossible : {e})"),
                };
            }),
        );
    }
    let filter = app.logs.filter.to_lowercase();
    let text: String = if filter.is_empty() {
        app.logs.text.clone()
    } else {
        app.logs.text.lines().filter(|l| l.to_lowercase().contains(&filter)).collect::<Vec<_>>().join("\n")
    };
    theme::card_frame(ui).show(ui, |ui| {
        ui.set_width(ui.available_width());
        egui::ScrollArea::vertical()
            .max_height((ui.available_height() - 20.0).max(300.0))
            .stick_to_bottom(true)
            .auto_shrink([false, false])
            .show(ui, |ui| {
                for l in text.lines() {
                    let col = if l.contains("ERROR") || l.contains("ECHEC") || l.contains("CRITICAL") {
                        ERR
                    } else if l.contains("NOTICE") || l.contains("ARRET") {
                        WARN
                    } else {
                        ui.visuals().text_color()
                    };
                    ui.label(RichText::new(l).monospace().size(12.0).color(col));
                }
            });
    });
}

// =====================================================================
//  Parametres
// =====================================================================

fn host_settings(ui: &mut egui::Ui, id: &str, h: &mut crate::config::HostCfg, sudo_hint: &str) {
    egui::Grid::new(id).num_columns(2).spacing([12.0, 8.0]).show(ui, |ui| {
        ui.label("Adresse IP / nom");
        ui.add(egui::TextEdit::singleline(&mut h.host).desired_width(220.0).hint_text("192.168.1.x"));
        ui.end_row();
        ui.label("Port SSH");
        let mut p = h.port.to_string();
        if ui.add(egui::TextEdit::singleline(&mut p).desired_width(70.0)).changed() {
            if let Ok(v) = p.trim().parse() {
                h.port = v;
            }
        }
        ui.end_row();
        ui.label("Utilisateur");
        ui.add(egui::TextEdit::singleline(&mut h.user).desired_width(160.0));
        ui.end_row();
        ui.label("");
        ui.checkbox(&mut h.sudo, "Passer par sudo").on_hover_text(sudo_hint);
        ui.end_row();
    });
}

pub fn settings(app: &mut App, ui: &mut egui::Ui) {
    page_title(ui, "Paramètres", "Connexion aux NAS, clé SSH et scripts");

    card(ui, "1. Clé SSH de l'application", |ui| {
        if app.ssh.key_exists() {
            dot_label(ui, OK, "Clé créée sur ce PC");
            ui.label(RichText::new(app.ssh.key.to_string_lossy()).small().weak());
        } else {
            dot_label(ui, ERR, "Clé absente");
            if !app.key_msg.is_empty() {
                ui.colored_label(ERR, &app.key_msg);
            }
            if ui.button("Créer la clé").clicked() {
                match app.ssh.generate_key() {
                    Ok(()) => app.key_msg.clear(),
                    Err(e) => app.key_msg = e,
                }
            }
        }
        ui.label(
            RichText::new("L'application se connecte aux NAS avec cette clé : le mot de passe des comptes n'est demandé qu'une fois, pour l'autoriser.")
                .small()
                .weak(),
        );
    });
    ui.add_space(10.0);

    let mut save = false;
    ui.columns(2, |cols| {
        card(&mut cols[0], "2. OMV (sauvegardes, caméras, alertes)", |ui| {
            host_settings(ui, "omvset", &mut app.edit.omv, "Si l'utilisateur n'est pas root");
        });
        card(&mut cols[1], "3. Synology (copie vers l'OMV, migration oCIS)", |ui| {
            host_settings(ui, "synoset", &mut app.edit.syno, "Compte administrateur du Synology (la connexion root est désactivée par défaut sur DSM)");
            ui.label(RichText::new("Service SSH à activer : DSM > Panneau de configuration > Terminal & SNMP.").small().weak());
        });
    });
    ui.add_space(6.0);
    ui.horizontal(|ui| {
        ui.label("Actualisation toutes les");
        let mut r = app.edit.refresh_secs.to_string();
        if ui.add(egui::TextEdit::singleline(&mut r).desired_width(40.0)).changed() {
            if let Ok(v) = r.trim().parse() {
                app.edit.refresh_secs = v;
            }
        }
        ui.label("secondes (4 s pendant un transfert)");
    });
    egui::CollapsingHeader::new("Avancé").show(ui, |ui| {
        ui.horizontal(|ui| {
            ui.label("Client ssh :");
            ui.add(egui::TextEdit::singleline(&mut app.edit.ssh_bin).hint_text("ssh (client OpenSSH de Windows)").desired_width(320.0));
        });
    });
    let dirty = app.edit.omv != app.settings.omv
        || app.edit.syno != app.settings.syno
        || app.edit.refresh_secs != app.settings.refresh_secs
        || app.edit.ssh_bin != app.settings.ssh_bin;
    ui.horizontal(|ui| {
        if ui.add_enabled(dirty, egui::Button::new(RichText::new("💾 Enregistrer").color(Color32::WHITE)).fill(INFO)).clicked() {
            save = true;
        }
        if dirty {
            ui.label(RichText::new("Modifications non enregistrées").color(WARN));
        }
    });
    if save {
        app.save_settings();
    }
    ui.add_space(10.0);

    card(ui, "4. Autoriser la clé et tester", |ui| {
        for h in [HostId::Omv, HostId::Syno] {
            let cfg = app.host_cfg(h).clone();
            ui.horizontal(|ui| {
                ui.label(RichText::new(format!("{} ({})", h.label(), if cfg.is_set() { cfg.target() } else { "non configuré".into() })).strong());
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.add_enabled(cfg.is_set(), egui::Button::new("Oublier l'identité")).on_hover_text("Après une réinstallation du NAS").clicked() {
                        match app.ssh.forget_host(&cfg) {
                            Ok(()) => {
                                app.toast(true, "Identité oubliée : elle sera réenregistrée à la prochaine connexion.".into());
                                app.refresh(h);
                            }
                            Err(e) => app.toast(false, e),
                        }
                    }
                    if ui.add_enabled(cfg.is_set(), egui::Button::new("🔌 Tester")).clicked() {
                        test_connection(app, h);
                    }
                    if ui.add_enabled(cfg.is_set(), egui::Button::new("🔑 Autoriser la clé…")).clicked() {
                        match app.ssh.open_key_install_console(&cfg) {
                            Ok(m) => app.output = Some(OutputDialog { title: format!("Autoriser la clé sur le {}", h.label()), text: m, ok: true }),
                            Err(e) => app.toast(false, e),
                        }
                    }
                });
            });
            let (col, txt) = if !cfg.is_set() {
                (IDLE, "—".to_string())
            } else if let Some(e) = app.host_error(h) {
                (ERR, e.to_string())
            } else if app.host_connected(h) {
                (OK, "Connecté".to_string())
            } else {
                (IDLE, "Pas encore testé".to_string())
            };
            dot_label(ui, col, RichText::new(txt).small());
            if cfg.sudo {
                let has = match h {
                    HostId::Omv => app.omv.pass.is_some(),
                    HostId::Syno => app.syno.pass.is_some(),
                };
                ui.horizontal(|ui| {
                    ui.label(RichText::new(if has { "Mot de passe sudo : en mémoire" } else { "Mot de passe sudo : non saisi" }).small().weak());
                    if has && ui.small_button("Oublier").clicked() {
                        match h {
                            HostId::Omv => {
                                app.omv.pass = None;
                                app.settings.omv.saved_pass.clear();
                                app.edit.omv.saved_pass.clear();
                            }
                            HostId::Syno => {
                                app.syno.pass = None;
                                app.settings.syno.saved_pass.clear();
                                app.edit.syno.saved_pass.clear();
                            }
                        }
                        let _ = crate::config::save(&app.settings);
                    }
                    if !has && secret::can_store() {
                        ui.label(RichText::new("(il sera demandé et pourra être mémorisé)").small().weak());
                    }
                });
            }
            ui.separator();
        }
        ui.label(
            RichText::new("« Autoriser la clé » ouvre une fenêtre où tu tapes une seule fois le mot de passe du compte. Ensuite plus besoin de SSH.")
                .small()
                .weak(),
        );
    });
    ui.add_space(10.0);

    card(ui, "5. Scripts sur les NAS", |ui| {
        let omv = app.omv.status.clone();
        let syno = app.syno.status.clone();
        let ver = |inst: bool, api: u32| -> (Color32, String) {
            if !inst {
                (IDLE, "non installé".into())
            } else if api >= remote::API_VERSION {
                (OK, "à jour".into())
            } else {
                (WARN, "ancienne version (sans commandes pour l'application)".into())
            }
        };
        ui.horizontal(|ui| {
            match &omv {
                Some(s) => {
                    let (c, t) = ver(s.nb_installe, s.nb_api);
                    dot_label(ui, c, format!("OMV · nas-backup : {t}"));
                }
                None => {
                    dot_label(ui, IDLE, "OMV · nas-backup : (non connecté)");
                }
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.add_enabled(omv.is_some(), egui::Button::new("⬆ Installer / mettre à jour")).clicked() {
                    install_omv_script(app);
                }
            });
        });
        ui.horizontal(|ui| {
            match &syno {
                Some(s) => {
                    let (c1, t1) = ver(s.copie.installe, s.copie.api);
                    let (c2, t2) = ver(s.migration.installe, s.migration.api);
                    ui.vertical(|ui| {
                        dot_label(ui, c1, format!("Synology · copie-omv : {t1}"));
                        dot_label(ui, c2, format!("Synology · migre-drive-ocis : {t2}"));
                    });
                }
                None => {
                    dot_label(ui, IDLE, "Synology : (non connecté)");
                }
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.add_enabled(syno.is_some(), egui::Button::new("⬆ Installer / mettre à jour")).clicked() {
                    install_syno_scripts(app);
                }
            });
        });
        ui.label(
            RichText::new(
                "Installe les versions fournies avec l'application (avec les commandes sans question qu'elle utilise). \
L'ancienne version est gardée en .bak. Les copies, migrations et réglages en cours sont conservés.",
            )
            .small()
            .weak(),
        );
    });
}

fn test_connection(app: &mut App, h: HostId) {
    let script = "echo \"Connecté à $(hostname) en tant que $(id -un)\"\ncommand -v python3 >/dev/null && echo 'python3 : OK' || echo 'python3 : ABSENT (nécessaire)'\ncommand -v rclone >/dev/null && echo 'rclone : OK' || echo 'rclone : absent'\n".to_string();
    app.action_dialog(h, &format!("Test de connexion — {}", h.label()), script, 30);
}

fn install_omv_script(app: &mut App) {
    app.ask_confirm(
        "Installer nas-backup sur l'OMV",
        "Le script /usr/local/bin/nas-backup est remplacé par la version fournie avec l'application (l'ancienne est gardée en nas-backup.bak).\nLes sauvegardes en cours continuent avec l'ancienne version.",
        "Installer",
        false,
        None,
        Box::new(|app| {
            let script = remote::install_file(remote::NB_BIN, remote::NAS_BACKUP_SH) + &format!("{} gen-cron >/dev/null 2>&1 && echo 'Planification régénérée.' || true\n", remote::NB_BIN);
            app.action_dialog(HostId::Omv, "Installation de nas-backup", script, 60);
        }),
    );
}

fn install_syno_scripts(app: &mut App) {
    let omv_host = app.settings.omv.host.clone();
    app.ask_confirm(
        "Installer les scripts sur le Synology",
        &format!(
            "copie-omv et migre-drive-ocis sont installés dans /usr/local/bin du Synology (adresse de l'OMV : {omv_host}).\nLes copies et migrations en cours ne sont pas interrompues."
        ),
        "Installer",
        false,
        None,
        Box::new(move |app| {
            let script = remote::install_file(remote::COPIE_BIN, &remote::copie_script_for(&omv_host))
                + &remote::install_file(remote::MIGRE_BIN, remote::MIGRE_OCIS_SH);
            app.action_dialog(HostId::Syno, "Installation des scripts", script, 60);
        }),
    );
}

/// Cle root du Synology (utilisee par copie-omv) autorisee sur l'OMV
fn authorize_syno_to_omv(app: &mut App) {
    let script = "[ -f /root/.ssh/id_copie_omv ] || { mkdir -p /root/.ssh && chmod 700 /root/.ssh && ssh-keygen -t ed25519 -N '' -C \"copie-omv@$(hostname)\" -f /root/.ssh/id_copie_omv -q; }\ncat /root/.ssh/id_copie_omv.pub\n".to_string();
    app.exec(
        HostId::Syno,
        "Clé du Synology",
        script,
        30,
        Box::new(|app, r| match r {
            Ok(o) if o.code == 0 => {
                let key = o.stdout.lines().find(|l| l.starts_with("ssh-")).unwrap_or("").trim().to_string();
                if key.is_empty() {
                    app.toast(false, "Clé du Synology illisible.".into());
                    return;
                }
                let s = format!(
                    "umask 077; mkdir -p /root/.ssh; touch /root/.ssh/authorized_keys\nk={}\ngrep -qxF \"$k\" /root/.ssh/authorized_keys || echo \"$k\" >> /root/.ssh/authorized_keys\nchmod 600 /root/.ssh/authorized_keys\necho 'Le Synology peut maintenant écrire sur l OMV (clé autorisée pour root).'\n",
                    crate::ssh::sq(&key)
                );
                app.action_dialog(HostId::Omv, "Autorisation sur l'OMV", s, 30);
                app.refresh(HostId::Syno);
            }
            Ok(o) => app.toast(false, o.text()),
            Err(e) => app.toast(false, e.to_string()),
        }),
    );
}
