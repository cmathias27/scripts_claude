//! Les pages de l'application.

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
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

pub fn card_pub<R>(ui: &mut egui::Ui, title: &str, add: impl FnOnce(&mut egui::Ui) -> R) -> R {
    card(ui, title, add)
}

pub fn page_title_pub(ui: &mut egui::Ui, title: &str, subtitle: &str) {
    page_title(ui, title, subtitle)
}

pub fn host_banner_pub(app: &mut App, ui: &mut egui::Ui, h: HostId) -> bool {
    host_banner(app, ui, h)
}

pub fn badge_pub(ui: &mut egui::Ui, text: &str, col: Color32) {
    badge(ui, text, col)
}

pub fn dot_label_pub(ui: &mut egui::Ui, col: Color32, text: impl Into<RichText>) -> egui::Response {
    dot_label(ui, col, text)
}

pub fn info_banner(ui: &mut egui::Ui, text: &str) {
    banner(ui, INFO, text);
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
        banner(ui, WARN, &tf("{0} non configuré : renseigne son adresse dans les Paramètres.", &[&(h.label())]));
        if ui.button(tr("\u{E270} Ouvrir les paramètres")).clicked() {
            app.page = Page::Settings;
        }
        return false;
    }
    let has = match h {
        HostId::Omv => app.omv.status.is_some(),
        HostId::Syno => app.syno.status.is_some(),
    };
    if let Some(e) = app.host_error(h).cloned() {
        let col = if matches!(e, SshError::HostUnknown | SshError::SudoPassword) { WARN } else { ERR };
        banner(ui, col, &format!("{} : {}", h.label(), e));
        ui.horizontal(|ui| {
            if ui.button(tr("\u{E094} Réessayer")).clicked() {
                app.refresh(h);
            }
            if matches!(e, SshError::HostUnknown) && ui.button(tr("\u{E23E} Confirmer l'identité du NAS")).clicked() {
                app.fp_dismissed[crate::extras::idx(h)] = false;
                crate::extras::start_fingerprint(app, h, crate::extras::AfterTrust::Nothing);
            }
            if matches!(e, SshError::KeyRefused | SshError::HostKeyChanged) && ui.button(tr("\u{E270} Paramètres")).clicked() {
                app.page = Page::Settings;
            }
        });
        ui.add_space(6.0);
    } else if !has {
        ui.horizontal(|ui| {
            ui.spinner();
            ui.label(tf("Connexion au {0}…", &[&(h.label())]));
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
        tr("En cours")
    } else {
        match j.dernier_etat.as_deref() {
            Some("OK") => "OK",
            Some("ECHEC") => tr("Échec"),
            Some("ARRETE") => tr("Arrêtée"),
            _ => tr("Jamais lancée"),
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
        t.push_str(&tf(" · {0} %", &[&pc]));
    }
    t.push_str(&format!(" · {}", fmt::rclone_units(&p.vitesse)));
    if p.reste != "-" && !p.reste.is_empty() {
        t.push_str(&tf(" · reste {0}", &[&(fmt::rclone_dur(&p.reste))]));
    }
    t
}

fn progress_details(ui: &mut egui::Ui, p: &Progress) {
    let mut parts = Vec::new();
    if let (Some(a), Some(b)) = (p.fichiers_faits, p.fichiers_total) {
        parts.push(tf("{0} / {1} fichiers envoyés", &[&a, &b]));
    }
    if let (Some(a), Some(b)) = (p.verifs_faites, p.verifs_total) {
        parts.push(tf("{0} / {1} vérifiés", &[&a, &b]));
    }
    if let Some(e) = p.erreurs {
        if e > 0 {
            parts.push(tf("{0} erreur(s)", &[&e]));
        }
    }
    if let Some(d) = &p.duree {
        parts.push(tf("depuis {0}", &[&(fmt::rclone_dur(d))]));
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
    let mut t = if b.fichiers_envoyes == 0 && b.retires == 0 && b.erreurs == 0 {
        tr("Déjà à jour, aucun changement").to_string()
    } else if b.fichiers_envoyes == 0 {
        tr("Rien à envoyer").to_string()
    } else {
        tf("{0} fichier{1} envoyé{1} ({2})", &[&b.fichiers_envoyes, &(if b.fichiers_envoyes > 1 { "s" } else { "" }), &(fmt::bytes(b.volume_octets.max(0) as u64))])
    };
    if b.retires > 0 {
        t.push_str(&tf(", {0} supprimé(s) du Drive", &[&b.retires]));
    }
    if b.erreurs > 0 {
        t.push_str(&tf(", {0} erreur(s)", &[&b.erreurs]));
    }
    if b.duree_min < 1.0 {
        t.push_str(tr(" · moins d'une minute"));
    } else {
        t.push_str(&tf(" · {0} min", &[&format!("{:.0}", b.duree_min)]));
    }
    if let Some(m) = b.ram_max_mo {
        t.push_str(&tf(" · RAM max {0} Mo", &[&m]));
    }
    t
}

// =====================================================================
//  Barre du haut et navigation
// =====================================================================

pub fn top_bar(app: &mut App, ui: &mut egui::Ui) {
    egui::Panel::top("top").show(ui, |ui| {
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            ui.label(RichText::new(tr("\u{E2A0} NAS Manager")).strong().size(18.0));
            ui.add_space(18.0);
            if !app.settings.sites.is_empty() {
                let names = app.settings.site_names();
                let cur = app.settings.site.clone();
                let mut pick: Option<String> = None;
                egui::ComboBox::from_id_salt("site")
                    .selected_text(RichText::new(tf("\u{E2C2} {0}", &[&cur])).strong())
                    .show_ui(ui, |ui| {
                        for n in names {
                            if ui.selectable_label(n == cur, &n).clicked() && n != cur {
                                pick = Some(n);
                            }
                        }
                    });
                if let Some(n) = pick {
                    app.switch_site(&n);
                }
                ui.add_space(6.0);
            }
            for h in [HostId::Omv, HostId::Syno] {
                host_chip(app, ui, h);
                ui.add_space(8.0);
            }
            crate::extras::read_only_badge(app, ui);
            if let Some(u) = app.update.available.clone() {
                if !app.update.dismissed {
                    let busy = app.update.installing;
                    egui::Frame::new()
                        .fill(INFO.gamma_multiply(0.2))
                        .corner_radius(10.0)
                        .inner_margin(egui::Margin::symmetric(8, 2))
                        .show(ui, |ui| {
                            ui.horizontal(|ui| {
                                ui.label(RichText::new(tf("\u{E6A2} Version {0} disponible", &[&u.version])).small().color(INFO));
                                if busy {
                                    ui.spinner();
                                } else if ui.small_button(tr("Installer")).clicked() {
                                    crate::update::start_install(app);
                                }
                                if ui.small_button(tr("Nouveautés")).clicked() {
                                    app.output = Some(OutputDialog {
                                        title: tf("Version {0}", &[&u.version]),
                                        text: u.notes.replace("**", ""),
                                        ok: true,
                                    });
                                }
                                if !busy && ui.small_button("\u{E4F6}").on_hover_text(tr("Plus tard")).clicked() {
                                    app.update.dismissed = true;
                                }
                            });
                        });
                }
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.button(tr("\u{E094} Actualiser")).on_hover_text(tr("Relire l'état des deux NAS (F5)")).clicked() {
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
    // machine Debian reconnue par le script : « Debian » au lieu de « OMV »
    let lbl = if h == HostId::Omv { crate::install::server_label(app) } else { h.label() };
    let (col, txt, tip) = if !cfg.is_set() {
        (IDLE, tf("{0} : non configuré", &[&lbl]), tr("À renseigner dans les Paramètres").to_string())
    } else if let Some(e) = app.host_error(h) {
        if matches!(e, SshError::SudoPassword) {
            (WARN, tf("{0} : mot de passe requis", &[&lbl]), e.to_string())
        } else if matches!(e, SshError::HostUnknown) {
            (WARN, tf("{0} : identité à confirmer", &[&lbl]), e.to_string())
        } else {
            (ERR, tf("{0} : hors ligne", &[&lbl]), e.to_string())
        }
    } else {
        let (last, polling) = match h {
            HostId::Omv => (app.omv.last_ok, app.omv.polling),
            HostId::Syno => (app.syno.last_ok, app.syno.polling),
        };
        match last {
            Some(t) => (
                OK,
                tf("{0} : connecté", &[&lbl]),
                tf("{0} — mis à jour il y a {1} s", &[&(cfg.target()), &(t.elapsed().as_secs())]),
            ),
            None if polling => (WARN, tf("{0} : connexion…", &[&lbl]), cfg.target()),
            None => (IDLE, tf("{0} : en attente", &[&lbl]), cfg.target()),
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
    let rt_badge = omv.as_ref().and_then(crate::realtime::nav_badge);
    let copy_run = syno.as_ref().map(|s| s.copie.en_cours).unwrap_or(false);
    let mig_run = syno.as_ref().map(|s| s.migration.en_cours).unwrap_or(false);
    let mig_q = syno.as_ref().map(|s| s.migration.file.len()).unwrap_or(0);

    let items: Vec<(Page, &str, Option<(String, Color32)>)> = vec![
        (Page::Dashboard, tr("\u{E2C2}  Tableau de bord"), None),
        (
            Page::Backups,
            tr("\u{E248}  Sauvegardes programmées"),
            if running_jobs > 0 {
                Some((tf("{0} en cours", &[&running_jobs]), INFO))
            } else if failed_jobs > 0 {
                Some((tf("{0} échec", &[&failed_jobs]), ERR))
            } else {
                None
            },
        ),
        (Page::Realtime, tr("\u{E094}  Sauvegardes temps réel"), rt_badge),
        (Page::History, tr("\u{E154}  Historique"), None),
        (Page::Alerts, tr("\u{E0CE}  Alertes"), if alerts > 0 { Some((alerts.to_string(), ERR)) } else { None }),
        (Page::Copy, tr("\u{E390}  Copie → OMV"), if copy_run { Some((tr("en cours").into(), INFO)) } else { None }),
        (
            Page::Migration,
            tr("\u{E1AA}  Migration oCIS"),
            if mig_run {
                Some((tr("en cours").into(), INFO))
            } else if mig_q > 0 {
                Some((tf("{0} en file", &[&mig_q]), WARN))
            } else {
                None
            },
        ),
        (Page::Logs, tr("\u{EB7A}  Journaux"), None),
        (Page::Install, tr("\u{ECA0}  Installation"), None),
        (Page::Help, tr("\u{E63A}  Aide"), None),
        (Page::Settings, tr("\u{E270}  Paramètres"), None),
    ];
    // largeur du menu : le libelle le plus long (et sa pastille) tient sans etre coupe,
    // quelle que soit la langue ; 220 au minimum, 340 au maximum
    let small = egui::TextStyle::Small.resolve(ui.style());
    let need = ui.ctx().fonts_mut(|f| {
        items
            .iter()
            .map(|(_, l, b)| {
                let w = f.layout_no_wrap((*l).to_string(), egui::FontId::proportional(14.5), Color32::WHITE).size().x;
                let bw = b.as_ref().map(|(t, _)| f.layout_no_wrap(t.clone(), small.clone(), Color32::WHITE).size().x + 14.0).unwrap_or(0.0);
                w + bw
            })
            .fold(0.0_f32, f32::max)
    });
    let width = (need + 40.0).clamp(220.0, 340.0);

    egui::Panel::left("nav").exact_size(width).show(ui, |ui| {
        ui.add_space(10.0);
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
            if ui.link(RichText::new(tf("v{0} · Nouveautés", &[&(env!("CARGO_PKG_VERSION"))])).small()).clicked() {
                app.show_news = true;
            }
        });
    });
}

// =====================================================================
//  Tableau de bord
// =====================================================================

pub fn dashboard(app: &mut App, ui: &mut egui::Ui) {
    page_title(ui, tr("Tableau de bord"), tr("Vue d'ensemble des sauvegardes et transferts du NAS"));
    let omv = app.omv.status.clone();
    let syno = app.syno.status.clone();
    if omv.is_none() {
        host_banner(app, ui, HostId::Omv);
    } else if let Some(e) = app.host_error(HostId::Omv).cloned() {
        banner(ui, ERR, &tf("OMV : {0} (dernières informations affichées)", &[&e]));
    }
    if let Some(s) = &omv {
        let uses_crypt = s.sauvegardes.iter().any(|j| j.chiffre) || s.cameras.installe || s.temps_reel.iter().any(|j| j.chiffre);
        if uses_crypt && !app.settings.passwords_noted {
            ui.horizontal(|ui| {
                banner(ui, WARN, tr("\u{E2D6} As-tu noté les mots de passe de chiffrement hors du NAS ? Sans eux, les sauvegardes chiffrées sont illisibles si le NAS tombe en panne."));
            });
            if ui.button(tr("Voir les mots de passe")).clicked() {
                open_passwords(app);
            }
            ui.add_space(6.0);
        }
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
        card(&mut cols[k], tr("\u{E248} Sauvegardes programmées"), |ui| {
            match &omv {
                None => {
                    ui.label(RichText::new("—").weak());
                }
                Some(s) => {
                    let n = s.sauvegardes.len();
                    let ok = s.sauvegardes.iter().filter(|j| j.dernier_etat.as_deref() == Some("OK")).count();
                    let ko = s.sauvegardes.iter().filter(|j| j.dernier_etat.as_deref() == Some("ECHEC")).count();
                    if n == 0 {
                        ui.label(tr("Aucune sauvegarde configurée."));
                    } else {
                        dot_label(ui, if ko > 0 { ERR } else { OK }, tf("{0} sauvegarde(s) · {1} OK · {2} en échec", &[&n, &ok, &ko]));
                    }
                    for j in s.sauvegardes.iter().filter(|j| j.en_cours) {
                        ui.label(RichText::new(format!("\u{E3D0} {}", j.nom)).strong());
                        match &j.avancement {
                            Some(p) => progress_bar(
                                ui,
                                p.pct,
                                format!("{} % · {}", p.pct.unwrap_or(0), fmt::rclone_units(&p.vitesse)),
                            ),
                            None => progress_bar(ui, None, tr("Préparation…").into()),
                        }
                    }
                    if s.arret_demande {
                        ui.colored_label(WARN, tr("Arrêt demandé : plus de nouvelle sauvegarde jusqu'au prochain horaire."));
                    }
                    let next_runs: Vec<String> = s
                        .sauvegardes
                        .iter()
                        .filter(|j| j.horaire != "manuel" && !j.en_cours)
                        .filter_map(|j| fmt::next_run_sched(&j.horaire).map(|t| format!("{} : {}", j.nom, t)))
                        .take(3)
                        .collect();
                    if !next_runs.is_empty() {
                        ui.label(RichText::new(tf("Prochaines : {0}", &[&(next_runs.join(" · "))])).small().weak());
                    }
                }
            }
            if ui.link(tr("Gérer les sauvegardes programmées →")).clicked() {
                goto = Some(Page::Backups);
            }
        });
        cols[k].add_space(10.0);

        // ---- Sauvegardes temps reel
        let k = next(cols);
        card(&mut cols[k], tr("\u{E094} Sauvegardes temps réel"), |ui| {
            if crate::realtime::dashboard_card(ui, omv.as_ref(), now) {
                goto = Some(Page::Realtime);
            }
        });
        cols[k].add_space(10.0);

        // ---- Google Drive
        let k = next(cols);
        card(&mut cols[k], tr("\u{E1AA} Google Drive"), |ui| {
            match omv.as_ref().and_then(|s| s.sante.clone()) {
                None => {
                    ui.label(RichText::new(tr("État inconnu (nas-check pas encore lancé).")).weak());
                }
                Some(h) => {
                    dot_label(ui, if h.gdrive { OK } else { ERR }, if h.gdrive { tr("Connexion OK") } else { tr("Connexion en échec") });
                    if let Some(p) = h.quota_pct {
                        let col = if p >= 90.0 { ERR } else if p >= 75.0 { WARN } else { OK };
                        let txt = match (h.used_go, h.total_go) {
                            (Some(u), Some(t)) => tf("{0} % · {1} / {2} Go", &[&format!("{:.0}", p), &format!("{:.1}", u), &format!("{:.0}", t)]),
                            _ => format!("{p:.0} %"),
                        };
                        ui.add(egui::ProgressBar::new((p / 100.0) as f32).fill(col).text(txt));
                    }
                    if let Some(c) = &h.checked {
                        ui.label(RichText::new(tf("Vérifié : {0}", &[&(c.replace('T', " ").chars().take(16).collect::<String>())])).small().weak());
                    }
                }
            }
            if let Some(s) = &omv {
                if !s.alertes.is_empty() {
                    ui.colored_label(ERR, tf("\u{E0CE} {0} alerte(s) en cours", &[&(s.alertes.len())]));
                }
            }
            if ui.link(tr("Alertes & santé →")).clicked() {
                goto = Some(Page::Alerts);
            }
        });
        cols[k].add_space(10.0);

        // ---- Copie
        let k = next(cols);
        card(&mut cols[k], tr("\u{E390} Copie Synology → OMV"), |ui| {
            match &syno {
                None => {
                    ui.label(RichText::new(if app.settings.syno.is_set() { tr("Synology non joignable.") } else { tr("Synology non configuré.") }).weak());
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
                            Some(p) => progress_bar(ui, Some(p.pct), tf("{0} % · {1} · reste {2}", &[&p.pct, &p.vitesse, &p.reste])),
                            None => progress_bar(ui, None, tr("Préparation de la liste des fichiers…").into()),
                        }
                    } else {
                        dot_label(ui, IDLE, tr("Aucune copie en cours"));
                        if let Some(l) = c.historique.last() {
                            ui.label(RichText::new(hist_line(l)).small().weak());
                        }
                    }
                }
            }
            if ui.link(tr("Copies →")).clicked() {
                goto = Some(Page::Copy);
            }
        });
        cols[k].add_space(10.0);

        // ---- Migration
        let k = next(cols);
        card(&mut cols[k], tr("\u{E1AA} Migration Drive → oCIS"), |ui| {
            match &syno {
                None => {
                    ui.label(RichText::new("—").weak());
                }
                Some(s) => {
                    let m = &s.migration;
                    if m.en_cours {
                        if let Some(e) = &m.etape {
                            ui.label(RichText::new(format!("[{}/{}] {} → {}", e.etape, m.nb, e.libelle, e.espace)).strong());
                            progress_bar(ui, e.pct, if e.ligne.is_empty() { tr("Comparaison avec oCIS…").into() } else { fmt::stats_line(&e.ligne) });
                        } else {
                            ui.label(tr("Migration en cours…"));
                        }
                    } else {
                        dot_label(ui, IDLE, tr("Aucune migration en cours"));
                    }
                    if !m.file.is_empty() {
                        ui.label(tf("{0} migration(s) en file d'attente", &[&(m.file.len())]));
                    }
                }
            }
            if ui.link(tr("Migration →")).clicked() {
                goto = Some(Page::Migration);
            }
        });
        cols[k].add_space(10.0);

        // ---- Systeme
        let k = next(cols);
        card(&mut cols[k], tr("\u{E560} Serveur OMV"), |ui| {
            match &omv {
                None => {
                    ui.label(RichText::new("—").weak());
                }
                Some(s) => {
                    ui.label(tf("{0} · allumé depuis {1}{2}", &[&s.serveur, &(fmt::duration(s.uptime_s.unwrap_or(0))), &(s.charge.as_ref().map(|c| tf(" · charge {0}", &[&c])).unwrap_or_default())]));
                    for d in &s.disques {
                        let f = if d.taille > 0 { d.utilise as f32 / d.taille as f32 } else { 0.0 };
                        let col = if f > 0.9 { ERR } else if f > 0.8 { WARN } else { OK };
                        ui.label(RichText::new(fmt::short_path(&d.point)).small());
                        ui.add(
                            egui::ProgressBar::new(f)
                                .fill(col)
                                .text(tf("{0} libres sur {1}", &[&(fmt::bytes(d.libre)), &(fmt::bytes(d.taille))])),
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
    page_title(ui, tr("Sauvegardes programmées"), tr("Sauvegardes vers Google Drive à heure fixe ou à la demande"));
    if !host_banner(app, ui, HostId::Omv) {
        return;
    }
    let s = app.omv.status.clone().unwrap();
    if !s.nb_installe || s.nb_api < remote::nb_api() {
        banner(
            ui,
            WARN,
            if s.nb_installe {
                tr("La version du script installée sur la machine est ancienne : mets-la à jour pour pouvoir ajouter, modifier ou restaurer depuis l'application.")
            } else {
                tr("Le script nas-debian n'est pas encore installé sur la machine (il remplace nas-backup).")
            },
        );
        crate::scripts::widget(app, ui, crate::scripts::Kind::Debian);
        ui.add_space(6.0);
    } else if s.migration_requise {
        crate::scripts::widget(app, ui, crate::scripts::Kind::Debian);
        ui.add_space(6.0);
    }
    let any_running = s.any_job_running();
    ui.horizontal(|ui| {
        if primary_button(ui, tr("+ Nouvelle sauvegarde")).clicked() {
            app.job_form = Some(JobFormState {
                new: true,
                mirror: true,
                encrypt: true,
                trash_days: "30".into(),
                ..Default::default()
            });
            if !app.sources_loaded {
                app.load_backup_sources();
            }
        }
        if ui.add_enabled(!s.sauvegardes.is_empty(), egui::Button::new(tr("\u{E3D0} Tout lancer"))).clicked() {
            app.ask_confirm(
                tr("Lancer toutes les sauvegardes"),
                tr("Les sauvegardes vont être lancées l'une après l'autre."),
                tr("Lancer"),
                false,
                None,
                Box::new(|app| app.action_toast(HostId::Omv, tr("Lancement"), remote::nb_run_all(), 30)),
            );
        }
        if any_running && danger_button(ui, tr("\u{E46C} Arrêter les sauvegardes en cours")).clicked() {
            app.ask_confirm(
                tr("Arrêter les sauvegardes"),
                tr("Les transferts en cours s'arrêtent proprement (fin des fichiers en cours d'envoi).\nAucune nouvelle sauvegarde ne démarre avant le prochain horaire prévu."),
                tr("Arrêter"),
                true,
                None,
                Box::new(|app| app.action_dialog(HostId::Omv, tr("Arrêt des sauvegardes"), remote::nb_stop(), 150)),
            );
        }
    });
    verif_planner(app, ui, &s.verif_auto);
    if s.arret_demande && !any_running {
        ui.colored_label(WARN, tr("Un arrêt a été demandé : les sauvegardes reprendront à leur prochain horaire (ou en les lançant ici)."));
    }
    ui.add_space(6.0);

    // Restauration en cours / terminee
    if let Some(r) = &s.restauration {
        let show = r.etat == "en_cours"
            || r.fin.parse::<i64>().map(|f| fmt::now() - f < 86400).unwrap_or(false);
        if show {
            card(ui, tr("\u{E20C} Restauration"), |ui| {
                let (col, t) = match r.etat.as_str() {
                    "en_cours" => (INFO, tr("En cours")),
                    "ok" => (OK, tr("Terminée")),
                    "echec" => (ERR, tr("Échec")),
                    _ => (WARN, tr("Interrompue")),
                };
                let what = if r.element.is_empty() { r.nom.clone() } else { format!("{} / {}", r.nom, r.element) };
                dot_label(ui, col, tf("{0} : « {1} » → {2}", &[&t, &what, &r.cible]));
                if let Some(p) = &r.avancement {
                    progress_bar(ui, p.pct, progress_text(p));
                } else if r.etat == "en_cours" {
                    progress_bar(ui, None, tr("Préparation…").into());
                }
            });
            ui.add_space(8.0);
        }
    }

    if s.sauvegardes.is_empty() {
        card(ui, "", |ui| {
            ui.label(tr("Aucune sauvegarde configurée. Clique sur « Nouvelle sauvegarde » pour en créer une."));
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
            badge(ui, if j.mode == "sync" { tr("Miroir") } else { tr("Copie") }, IDLE);
            if j.chiffre {
                badge(ui, tr("\u{E2FA} Chiffré"), IDLE);
            }
            badge(
                ui,
                &if j.horaire == "manuel" { tr("Manuel").to_string() } else { format!("\u{E19A} {}", fmt::schedule_human(&j.horaire)) },
                IDLE,
            );
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let name = j.nom.clone();
                ui.menu_button(tr("\u{E1FE}"), |ui| {
                    if ui
                        .add_enabled(!j.en_cours && j.simulation.as_ref().map(|s| s.etat != "en_cours").unwrap_or(true), egui::Button::new(tr("\u{E30C} Simuler (sans rien envoyer)")))
                        .on_hover_text(tr("Liste ce que la sauvegarde enverrait et supprimerait sur le Drive"))
                        .clicked()
                    {
                        app.action_toast(HostId::Omv, tr("Simulation"), remote::nb_simulate(&name), 30);
                        ui.close();
                    }
                    if ui.button(tr("\u{E20C} Restaurer…")).clicked() {
                        app.restore = Some(RestoreState::new(&name, &j.source, j.mode == "sync" && j.corbeille > 0));
                        ui.close();
                    }
                    if ui
                        .add_enabled(
                            j.verification.as_ref().map(|v| v.etat != "en_cours").unwrap_or(true),
                            egui::Button::new(tr("\u{E40C} Vérifier l'intégrité")),
                        )
                        .on_hover_text(tr("Compare chaque fichier du NAS avec sa copie sur le Drive (empreintes, déchiffrement si besoin)"))
                        .clicked()
                    {
                        app.action_toast(HostId::Omv, tr("Vérification"), remote::nb_verify(&name), 30);
                        ui.close();
                    }
                    if ui.button(tr("\u{E4A6} Supprimer la sauvegarde…")).clicked() {
                        let n = name.clone();
                        app.ask_confirm(
                            tr("Supprimer la sauvegarde"),
                            &tf("La sauvegarde « {0} » ne sera plus planifiée.\nLes fichiers déjà envoyés restent sur le Drive.", &[&n]),
                            tr("Supprimer"),
                            true,
                            None,
                            Box::new(move |app| app.action_dialog(HostId::Omv, tr("Suppression"), remote::nb_delete(&n, false), 60)),
                        );
                        ui.close();
                    }
                    if ui.button(RichText::new(tr("\u{E4A6} Supprimer et effacer du Drive…")).color(ERR)).clicked() {
                        let n = name.clone();
                        let word = name.clone();
                        let dest = job_dest(j);
                        app.ask_confirm(
                            tr("Supprimer et effacer du Drive"),
                            &tf("La sauvegarde « {0} » est supprimée ET ses fichiers sont DÉFINITIVEMENT effacés du Drive ({1}, corbeille comprise).", &[&n, &dest]),
                            tr("Supprimer définitivement"),
                            true,
                            Some(&word),
                            Box::new(move |app| app.action_dialog(HostId::Omv, tr("Suppression"), remote::nb_delete(&n, true), 1800)),
                        );
                        ui.close();
                    }
                });
                if ui.button(tr("\u{E3B4} Modifier")).clicked() {
                    app.job_form = Some(JobFormState {
                        new: false,
                        name: j.nom.clone(),
                        source: j.source.clone(),
                        folder: j.dossier.clone(),
                        folder_touched: true,
                        mirror: j.mode == "sync",
                        encrypt: j.chiffre,
                        sched: crate::sched::SchedEdit::parse(&j.horaire),
                        bw: crate::sched::BwEdit::parse(&j.debit),
                        trash_days: j.corbeille.to_string(),
                        memory: j.memoire.clone(),
                        error: String::new(),
                    });
                    if !app.sources_loaded {
                        app.load_backup_sources();
                    }
                }
                if j.en_cours {
                    if ui.button(tr("\u{E46C} Arrêter")).on_hover_text(tr("Arrête cette sauvegarde seulement ; elle reprendra à sa prochaine exécution")).clicked() {
                        let n = name.clone();
                        app.ask_confirm(
                            tr("Arrêter la sauvegarde"),
                            &tf("La sauvegarde « {0} » s'arrête proprement (fin des fichiers en cours d'envoi). Les autres continuent.", &[&n]),
                            tr("Arrêter"),
                            true,
                            None,
                            Box::new(move |app| app.action_toast(HostId::Omv, tr("Arrêt"), remote::nb_stop_job(&n), 90)),
                        );
                    }
                } else if ui.button(tr("\u{E3D0} Lancer")).clicked() {
                    app.action_toast(HostId::Omv, tr("Lancement"), remote::nb_run(&name), 30);
                }
            });
        });
        ui.label(
            RichText::new(tf("{0}  →  Drive : {1}", &[&(fmt::short_path(&j.source)), &(job_dest(j))]))
                .color(ui.visuals().strong_text_color()),
        )
        .on_hover_text(&j.source);
        if !j.source_existe {
            ui.colored_label(ERR, tr("\u{E4E0} Dossier source introuvable (disque démonté ?)"));
        }
        if !j.en_cours && j.dernier_etat.as_deref() == Some("ECHEC") {
            if let Some(e) = &j.derniere_erreur {
                crate::explain::show(ui, e);
                if crate::explain::explain(e).and_then(|x| x.command).map(|c| c.contains("reconnect")).unwrap_or(false)
                    && ui.button(tr("\u{E2D6} Reconnecter Google Drive")).clicked()
                {
                    app.page = Page::Install;
                    crate::install::start_google(app);
                }
            }
        }
        if j.en_cours {
            match &j.avancement {
                Some(p) => {
                    progress_bar(ui, p.pct, progress_text(p));
                    progress_details(ui, p);
                }
                None => progress_bar(ui, None, tr("Comparaison avec le Drive…").into()),
            }
            if let Some(d) = j.debut {
                let ram = j.ram_mo.map(|m| tf(" · rclone utilise {0} Mo", &[&m])).unwrap_or_default();
                ui.label(RichText::new(format!("{}{ram}", tf("Démarrée {0}", &[&(fmt::ago(d, now))]))).small().weak());
            }
        } else {
            let mut parts = Vec::new();
            if let Some(d) = &j.derniere_execution {
                let when = fmt::parse_status_ts(d).map(fmt::date).unwrap_or_else(|| d.clone());
                parts.push(tf("Dernière exécution : {0}", &[&when]));
            }
            if let Some(ok) = j.dernier_succes {
                if j.dernier_etat.as_deref() != Some("OK") {
                    parts.push(tf("dernier succès {0}", &[&(fmt::ago(ok, now))]));
                }
            }
            if j.horaire != "manuel" {
                if let Some(n) = fmt::next_run_sched(&j.horaire) {
                    parts.push(tf("prochaine : {0}", &[&n]));
                }
            }
            if !parts.is_empty() {
                ui.label(RichText::new(parts.join(" · ")).small());
            }
            if let Some(b) = &j.bilan {
                ui.label(RichText::new(tf("Bilan : {0}", &[&(bilan_text(b))])).small().weak());
            }
        }
        if !j.debit.is_empty() {
            ui.label(RichText::new(tf("Débit limité : {0}", &[&(fmt::bw_human(&j.debit))])).small().weak());
        }
        if !j.memoire.is_empty() {
            ui.label(RichText::new(tf("Mémoire de rclone : {0}", &[&(crate::ram::job_memory_text(&j.memoire))])).small().weak());
        }
        if let Some(sim) = &j.simulation {
            simulation_box(app, ui, &j.nom, sim);
        }
        if let Some(v) = &j.verification {
            verification_box(app, ui, &j.nom, v);
        }
        if j.mode == "sync" && j.corbeille > 0 {
            ui.label(
                RichText::new(tf("Fichiers supprimés/modifiés gardés {0} jours dans la corbeille du Drive", &[&j.corbeille]))
                    .small()
                    .weak(),
            );
        }
    });
}

/// Verification automatique de toutes les sauvegardes (jours + heure)
fn verif_planner(app: &mut App, ui: &mut egui::Ui, current: &str) {
    let (days, time) = current.split_once(' ').unwrap_or(("", ""));
    ui.horizontal(|ui| {
        ui.label(RichText::new(tr("\u{E40C} Vérification automatique de l'intégrité :")).small());
        let txt = if days.is_empty() {
            tr("désactivée").to_string()
        } else {
            fmt::schedule_human(&format!("{time}/{days}"))
        };
        ui.label(RichText::new(txt).small().strong());
        if app.verif_edit.is_none() && ui.small_button(tr("Modifier")).clicked() {
            let mut d = [false; 7];
            for c in days.chars() {
                if let Some(n) = c.to_digit(10) {
                    if (1..=7).contains(&n) {
                        d[n as usize - 1] = true;
                    }
                }
            }
            if days.is_empty() {
                d[6] = true;
            }
            app.verif_edit = Some((d, if time.is_empty() { "05:00".into() } else { time.to_string() }));
        }
    });
    let mut action: Option<String> = None;
    let mut close = false;
    if let Some((d, t)) = &mut app.verif_edit {
        ui.horizontal(|ui| {
            for (i, n) in [tr("Lun"), tr("Mar"), tr("Mer"), tr("Jeu"), tr("Ven"), tr("Sam"), tr("Dim")].iter().enumerate() {
                ui.toggle_value(&mut d[i], *n);
            }
            ui.label(tr("à"));
            ui.add(egui::TextEdit::singleline(t).desired_width(55.0));
            let digits: String = (0..7).filter(|i| d[*i]).map(|i| char::from_digit(i as u32 + 1, 10).unwrap_or('7')).collect();
            let ok = !digits.is_empty() && crate::sched::valid_sched(&format!("{t}/{digits}"));
            if ui.add_enabled(ok, egui::Button::new(tr("Enregistrer"))).clicked() {
                action = Some(remote::nb_verify_plan(&digits, t));
            }
            if ui.button(tr("Désactiver")).clicked() {
                action = Some(remote::nb_verify_plan("", ""));
            }
            if ui.button(tr("Annuler")).clicked() {
                close = true;
            }
        });
        ui.label(RichText::new(tr("Compare chaque fichier du NAS avec le Drive (lit tout le Drive : à prévoir la nuit). Une notification signale les écarts.")).small().weak());
    }
    if let Some(a) = action {
        app.verif_edit = None;
        app.action_toast(HostId::Omv, tr("Vérification automatique"), a, 60);
    } else if close {
        app.verif_edit = None;
    }
}

fn verification_box(app: &mut App, ui: &mut egui::Ui, name: &str, v: &Verification) {
    if v.etat != "en_cours" && fmt::now() - v.fin > 30 * 86400 {
        return;
    }
    let col = match v.etat.as_str() {
        "ok" => OK,
        "en_cours" => INFO,
        "ecarts" => WARN,
        _ => ERR,
    };
    egui::Frame::new()
        .fill(col.gamma_multiply(0.10))
        .corner_radius(6.0)
        .inner_margin(egui::Margin::same(8))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.horizontal_wrapped(|ui| {
                ui.label(RichText::new(tr("\u{E40C} Intégrité")).strong());
                match v.etat.as_str() {
                    "en_cours" => {
                        ui.spinner();
                        ui.label(tr("comparaison fichier par fichier avec le Drive…"));
                    }
                    "ok" => {
                        ui.label(tf("vérifiée {0} : les {1} fichiers sont identiques sur le Drive", &[&(fmt::ago(v.fin, fmt::now())), &v.identiques]));
                    }
                    "ecarts" => {
                        let mut parts = Vec::new();
                        if v.differents > 0 {
                            parts.push(tf("{0} différent(s)", &[&v.differents]));
                        }
                        if v.manquants > 0 {
                            parts.push(tf("{0} absent(s) du Drive", &[&v.manquants]));
                        }
                        if v.en_trop > 0 {
                            parts.push(tf("{0} en trop sur le Drive", &[&v.en_trop]));
                        }
                        if v.erreurs > 0 {
                            parts.push(tf("{0} illisible(s)", &[&v.erreurs]));
                        }
                        ui.label(tf("{0} : {1} identiques, {2}", &[&(fmt::ago(v.fin, fmt::now())), &v.identiques, &(parts.join(", "))]));
                        if ui.small_button(tr("Voir le détail")).clicked() {
                            let n = name.to_string();
                            let d = format!("/var/lib/nas-backup/{n}.verif.d");
                            let script = format!(
                                "for f in differents manquants en-trop erreurs; do [ -s {d}/$f ] || continue; echo \"=== $f\"; head -n 500 {d}/$f; echo; done\n"
                            );
                            app.exec(
                                HostId::Omv,
                                tr("Lecture de la vérification"),
                                script,
                                30,
                                Box::new(move |app, r| {
                                    let t = r.map(|o| o.stdout).unwrap_or_else(|e| e.to_string());
                                    app.output = Some(OutputDialog {
                                        title: tf("Vérification de « {0} »", &[&n]),
                                        text: tf("{0}\nUne nouvelle sauvegarde corrige en général ces écarts (fichiers modifiés ou ajoutés depuis la dernière sauvegarde).", &[&t]),
                                        ok: false,
                                    });
                                }),
                            );
                        }
                    }
                    _ => {
                        ui.colored_label(ERR, tr("la vérification n'a pas pu aboutir (voir les journaux)"));
                    }
                }
            });
        });
}

fn simulation_box(app: &mut App, ui: &mut egui::Ui, name: &str, sim: &Simulation) {
    let recent = fmt::now() - sim.fin < 7 * 86400 || sim.etat == "en_cours";
    if !recent {
        return;
    }
    egui::Frame::new()
        .fill(INFO.gamma_multiply(0.10))
        .corner_radius(6.0)
        .inner_margin(egui::Margin::same(8))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.horizontal_wrapped(|ui| {
                ui.label(RichText::new(tr("\u{E30C} Simulation")).strong());
                match sim.etat.as_str() {
                    "en_cours" => {
                        ui.spinner();
                        ui.label(tr("comparaison avec le Drive en cours…"));
                    }
                    "ok" => {
                        ui.label(tf("{0} : {1} fichier(s) à envoyer ({2}), {3} à retirer du Drive", &[&(fmt::ago(sim.fin, fmt::now())), &sim.envois, &(fmt::bytes(sim.octets)), &sim.suppressions]));
                        if ui.small_button(tr("Voir le détail")).clicked() {
                            let n = name.to_string();
                            app.exec(
                                HostId::Omv,
                                tr("Lecture de la simulation"),
                                remote::tail_file(&format!("/var/lib/nas-backup/{n}.simulation.txt"), 2000),
                                30,
                                Box::new(move |app, r| {
                                    let t = r.map(|o| o.stdout).unwrap_or_else(|e| e.to_string());
                                    app.output = Some(OutputDialog {
                                        title: tf("Simulation de « {0} » (+ envoyé, - retiré du Drive)", &[&n]),
                                        text: if t.trim().is_empty() { tr("Rien à envoyer ni à retirer : le Drive est à jour.").into() } else { t },
                                        ok: true,
                                    });
                                }),
                            );
                        }
                    }
                    _ => {
                        ui.colored_label(ERR, tr("échec de la simulation (voir les journaux)"));
                    }
                }
            });
        });
}


pub fn job_form_window(app: &mut App, ctx: &egui::Context) {
    let Some(mut f) = app.job_form.take() else { return };
    let mut open = true;
    let mut save = false;
    let mut cancel = false;
    let mut browse = false;
    let sources = app.backup_sources.clone();
    egui::Window::new(RichText::new(if f.new { tr("Nouvelle sauvegarde") } else { tr("Modifier la sauvegarde") }).strong())
        .id(egui::Id::unique("jobform"))
        .collapsible(false)
        .resizable(false)
        .default_width(520.0)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            egui::Grid::new("jobgrid").num_columns(2).spacing([12.0, 10.0]).show(ui, |ui| {
                ui.label(tr("Nom"));
                ui.add_enabled(f.new, egui::TextEdit::singleline(&mut f.name).hint_text(tr("ex : Photos")).desired_width(300.0));
                ui.end_row();

                ui.label(tr("Dossier à sauvegarder"));
                ui.vertical(|ui| {
                    ui.horizontal(|ui| {
                        egui::ComboBox::from_id_salt("srccombo")
                            .width(300.0)
                            .selected_text(if f.source.is_empty() { tr("Choisir…").to_string() } else { fmt::short_path(&f.source) })
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
                        if ui.button("\u{E24A}").on_hover_text(tr("Parcourir les dossiers de l'OMV")).clicked() {
                            browse = true;
                        }
                    });
                    ui.add(egui::TextEdit::singleline(&mut f.source).desired_width(340.0).font(egui::TextStyle::Small));
                });
                ui.end_row();

                ui.label(tr("Dossier sur le Drive"));
                if ui.add(egui::TextEdit::singleline(&mut f.folder).desired_width(300.0)).changed() {
                    f.folder_touched = true;
                }
                ui.end_row();

                ui.label(tr("Mode"));
                ui.vertical(|ui| {
                    ui.radio_value(&mut f.mirror, true, tr("Miroir : le Drive devient identique au NAS"));
                    ui.radio_value(&mut f.mirror, false, tr("Copie : ajoute et met à jour, ne supprime jamais"));
                });
                ui.end_row();

                if f.mirror {
                    ui.label(tr("Corbeille (jours)"));
                    ui.horizontal(|ui| {
                        ui.add(egui::TextEdit::singleline(&mut f.trash_days).desired_width(50.0));
                        ui.label(RichText::new(tr("fichiers supprimés/modifiés gardés sur le Drive (0 = aucune)")).small().weak());
                    });
                    ui.end_row();
                }

                ui.label(tr("Chiffrement"));
                ui.checkbox(&mut f.encrypt, tr("Chiffrer (illisible sur le Drive sans les mots de passe)"));
                ui.end_row();

                ui.label(tr("Horaire"));
                f.sched.ui(ui);
                ui.end_row();

                ui.label(tr("Limite de débit"));
                f.bw.ui(ui);
                ui.end_row();

                ui.label(tr("Mémoire de rclone"));
                crate::ram::job_memory_ui(ui, "jobmem", &mut f.memory);
                ui.end_row();
            });
            if !f.new {
                ui.label(RichText::new(tr("Changer le dossier Drive ou le chiffrement : les fichiers déjà envoyés restent à l'ancien emplacement.")).small().weak());
            }
            if !f.error.is_empty() {
                ui.colored_label(ERR, &f.error);
            }
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                if primary_button(ui, tr("Enregistrer")).clicked() {
                    save = true;
                }
                if ui.button(tr("Annuler")).clicked() {
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
            tr("Nom invalide : lettres, chiffres, - et _ uniquement.")
        } else if src.is_empty() {
            tr("Choisis le dossier à sauvegarder.")
        } else if folder.is_empty() || folder.contains('|') || folder.starts_with("_corbeille") {
            tr("Dossier Drive invalide.")
        } else if let Err(e) = f.sched.build() {
            f.error = e;
            app.job_form = Some(f);
            return;
        } else if let Err(e) = f.bw.build() {
            f.error = e;
            app.job_form = Some(f);
            return;
        } else if f.mirror && f.trash_days.trim().parse::<u32>().is_err() {
            tr("Nombre de jours de corbeille invalide.")
        } else if !crate::ram::valid_job_memory(f.memory.trim()) {
            tr("Mémoire de rclone invalide : un nombre de Mo, 64 au minimum.")
        } else {
            ""
        };
        if !err.is_empty() {
            f.error = err.into();
            app.job_form = Some(f);
            return;
        }
        let sched = f.sched.build().unwrap_or_else(|_| "manuel".into());
        let bw = f.bw.build().unwrap_or_default();
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
                bwlimit: &bw,
                memory: f.memory.trim(),
            },
        );
        let title = if f.new { tr("Nouvelle sauvegarde") } else { tr("Modification") };
        app.action_dialog(HostId::Omv, title, script, 120);
        return;
    }
    app.job_form = Some(f);
}

pub fn restore_window(app: &mut App, ctx: &egui::Context) {
    crate::restore::window(app, ctx);
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
        HostId::Omv => tr("Disques de l'OMV"),
        HostId::Syno => tr("Dossiers partagés du Synology"),
    };
    let can_mkdir = matches!(purpose, BrowsePurpose::CopyDest | BrowsePurpose::RestoreTarget) && !app.settings.read_only;
    egui::Window::new(RichText::new(tf("Choisir un dossier — {0}", &[&(host.label())])).strong())
        .id(egui::Id::unique("browser"))
        .collapsible(false)
        .resizable(true)
        .default_size([560.0, 460.0])
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            ui.horizontal(|ui| {
                if ui.add_enabled(!cur.is_empty() && cur != "/", egui::Button::new(tr("\u{E08E} Remonter"))).clicked() {
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
                    ui.label(RichText::new(tr("(aucun sous-dossier)")).weak());
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
                    let r = ui.add(egui::Button::selectable(false, tf("\u{E24A} {0}", &[&name])));
                    if r.clicked() {
                        go = Some(e.clone());
                    }
                }
            });
            ui.separator();
            if can_mkdir && !cur.is_empty() {
                ui.horizontal(|ui| {
                    ui.add(egui::TextEdit::singleline(&mut new_folder).hint_text(tr("nouveau dossier")).desired_width(200.0));
                    if ui.add_enabled(!new_folder.trim().is_empty() && !new_folder.contains('/'), egui::Button::new(tr("Créer"))).clicked() {
                        mkdir = true;
                    }
                });
            }
            ui.horizontal(|ui| {
                if ui
                    .add_enabled(!cur.is_empty(), egui::Button::new(RichText::new(tr("\u{E182} Choisir ce dossier")).color(Color32::WHITE)).fill(INFO))
                    .clicked()
                {
                    pick = Some(cur.clone());
                }
                if ui.button(tr("Annuler")).clicked() {
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
            tr("Création du dossier"),
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

/// Ancienne synchro des cameras (install-cam-sync.sh), tant qu'elle n'est pas migree
pub fn cameras_legacy(app: &mut App, ui: &mut egui::Ui, s: &OmvStatus) {
    let c = s.cameras.clone();
    ui.add_space(4.0);
    ui.label(RichText::new(tr("Ancienne synchro des caméras (cam-sync)")).strong().size(16.0));
    let now = s.maintenant.max(fmt::now());
    ui.columns(3, |cols| {
        card(&mut cols[0], tr("Service cam-sync"), |ui| {
            dot_label(ui, if c.actif { OK } else { ERR }, RichText::new(if c.actif { tr("Actif") } else { tr("Arrêté") }).strong());
            ui.label(RichText::new(if c.demarrage_auto { tr("Démarre avec l'OMV") } else { tr("Ne démarre PAS avec l'OMV") }).small().weak());
            if c.actif && !c.actif_depuis.is_empty() {
                ui.label(RichText::new(tf("Depuis {0}", &[&c.actif_depuis])).small().weak());
            }
        });
        card(&mut cols[1], tr("Envois"), |ui| {
            match c.dernier_envoi.as_deref().and_then(fmt::parse_rclone_ts) {
                Some(t) => ui.label(RichText::new(tf("Dernière vidéo {0}", &[&(fmt::ago(t, now))])).strong()),
                None => ui.label(RichText::new(tr("Aucun envoi récent")).weak()),
            };
            ui.label(tf("{0} vidéo(s) envoyée(s) aujourd'hui", &[&c.envois_aujourdhui]));
        });
        card(&mut cols[2], tr("Rattrapage (toutes les 15 min)"), |ui| {
            if c.rattrapage_en_cours {
                ui.horizontal(|ui| {
                    ui.spinner();
                    ui.label(tr("En cours"));
                });
            } else {
                ui.label(tr("En attente"));
            }
            if c.erreurs_aujourdhui > 0 {
                ui.colored_label(ERR, tf("{0} erreur(s) aujourd'hui", &[&c.erreurs_aujourdhui]));
            } else {
                ui.label(RichText::new(tr("Aucune erreur aujourd'hui")).small().weak());
            }
        });
    });
    ui.add_space(8.0);
    ui.horizontal(|ui| {
        if c.actif {
            if ui.button(tr("\u{E094} Redémarrer le service")).clicked() {
                app.action_toast(HostId::Omv, tr("Redémarrage"), remote::cam_service("restart"), 40);
            }
            if danger_button(ui, tr("\u{E46C} Arrêter")).clicked() {
                app.ask_confirm(
                    tr("Arrêter la synchro des caméras"),
                    tr("Les nouvelles vidéos ne partiront plus vers le Drive en temps réel (le rattrapage toutes les 15 min continue)."),
                    tr("Arrêter"),
                    true,
                    None,
                    Box::new(|app| app.action_toast(HostId::Omv, tr("Arrêt"), remote::cam_service("stop"), 40)),
                );
            }
        } else if primary_button(ui, tr("\u{E3D0} Démarrer le service")).clicked() {
            app.action_toast(HostId::Omv, tr("Démarrage"), remote::cam_service("start"), 40);
        }
        if ui.add_enabled(!c.rattrapage_en_cours, egui::Button::new(tr("\u{E1AA} Lancer un rattrapage maintenant"))).clicked() {
            app.action_toast(HostId::Omv, tr("Rattrapage"), remote::cam_catchup(), 30);
        }
        if ui.button(tr("\u{EB7A} Journal complet")).clicked() {
            app.page = Page::Logs;
            app.logs.source = log_sources(app).iter().position(|l| l.path == "/var/log/cam-sync.log").unwrap_or(0);
            app.logs.last_fetch = None;
        }
    });
    if !c.dossier.is_empty() {
        ui.label(RichText::new(tf("Dossier surveillé : {0}", &[&c.dossier])).small().weak());
    }
    ui.add_space(8.0);
    if let Some(e) = &c.derniere_erreur {
        ui.label(RichText::new(tr("Dernière erreur")).strong());
        crate::explain::show(ui, e);
        ui.add_space(6.0);
    }
    card(ui, tr("Derniers événements"), |ui| {
        if c.evenements.is_empty() {
            ui.label(RichText::new(tr("(rien dans le journal)")).weak());
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
    page_title(ui, tr("Alertes & santé"), tr("Vérifications horaires (nas-check) et notifications Home Assistant"));
    if !host_banner(app, ui, HostId::Omv) {
        return;
    }
    let s = app.omv.status.clone().unwrap();
    let now = s.maintenant.max(fmt::now());
    if !s.alertes_installees {
        banner(ui, WARN, tr("Les alertes ne sont pas encore configurées (page Installation, carte « Alertes Home Assistant »)."));
        ui.add_space(6.0);
    }
    ui.columns(2, |cols| {
        card(&mut cols[0], tr("\u{E1AA} Google Drive"), |ui| match &s.sante {
            None => {
                ui.label(RichText::new(tr("Pas encore vérifié.")).weak());
            }
            Some(h) => {
                dot_label(ui, if h.gdrive { OK } else { ERR }, if h.gdrive { tr("Connexion OK") } else { tr("Connexion en échec") });
                if !h.gdrive {
                    ui.label(RichText::new(tr("Sur l'OMV : rclone config reconnect gdrive:")).small().monospace());
                }
                if let Some(p) = h.quota_pct {
                    let col = if p >= 90.0 { ERR } else if p >= 75.0 { WARN } else { OK };
                    ui.add(egui::ProgressBar::new((p / 100.0) as f32).fill(col).text(match (h.used_go, h.total_go) {
                        (Some(u), Some(t)) => tf("{0} % utilisé · {1} Go sur {2} Go", &[&format!("{:.0}", p), &format!("{:.1}", u), &format!("{:.0}", t)]),
                        _ => tf("{0} % utilisé", &[&format!("{:.0}", p)]),
                    }));
                }
                if let Some(c) = &h.checked {
                    ui.label(RichText::new(tf("Dernière vérification : {0}", &[&(c.replace('T', " ").chars().take(16).collect::<String>())])).small().weak());
                }
            }
        });
        card(&mut cols[1], tr("Actions"), |ui| {
            ui.horizontal_wrapped(|ui| {
                if ui.add_enabled(s.alertes_installees && !s.nas_check_en_cours, egui::Button::new(tr("\u{E30C} Vérifier maintenant"))).clicked() {
                    app.action_toast(HostId::Omv, tr("Vérification"), remote::nas_check(), 30);
                }
                if s.nas_check_en_cours {
                    ui.spinner();
                }
                if ui.add_enabled(s.alertes_installees, egui::Button::new(tr("\u{E1E0} Notification de test"))).clicked() {
                    app.action_toast(HostId::Omv, tr("Notification"), remote::notify_test(), 30);
                }
                if ui.button(tr("\u{E2D6} Mots de passe de chiffrement")).on_hover_text(tr("Indispensables pour relire les sauvegardes chiffrées")).clicked() {
                    open_passwords(app);
                }
            });
            ui.label(RichText::new(if s.suivi_ha { tr("Suivi Home Assistant (MQTT) installé.") } else { tr("Suivi Home Assistant (MQTT) non installé.") }).small().weak());
        });
    });
    ui.add_space(8.0);
    card(ui, &tf("\u{E0CE} Alertes en cours ({0})", &[&(s.alertes.len())]), |ui| {
        if s.alertes.is_empty() {
            dot_label(ui, OK, tr("Aucune alerte en cours."));
        }
        for a in &s.alertes {
            ui.horizontal(|ui| {
                dot(ui, ERR);
                ui.label(RichText::new(alert_label(&a.tag)).strong());
                ui.label(RichText::new(tf("depuis {0}", &[&(fmt::ago(a.depuis, now).replace("il y a ", ""))])).weak());
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui
                        .button(tr("Acquitter"))
                        .on_hover_text(tr("Retire l'alerte. Si le problème persiste, elle reviendra à la prochaine vérification."))
                        .clicked()
                    {
                        app.action_toast(HostId::Omv, tr("Acquittement"), remote::ack_alert(&a.tag), 20);
                    }
                });
            });
        }
        ui.label(RichText::new(tr("Une alerte non résolue est rappelée sur le téléphone toutes les 12 h.")).small().weak());
    });
}

pub fn alert_label(tag: &str) -> String {
    if let Some(n) = tag.strip_prefix("job-") {
        return tf("Sauvegarde « {0} » en échec", &[&n]);
    }
    if let Some(n) = tag.strip_prefix("retard-") {
        return tf("Sauvegarde « {0} » en retard", &[&n]);
    }
    if let Some(n) = tag.strip_prefix("rt-pause-") {
        return tf("Temps réel « {0} » en pause (anomalie)", &[&n]);
    }
    if let Some(n) = tag.strip_prefix("rt-service-") {
        return tf("Temps réel « {0} » arrêté", &[&n]);
    }
    if let Some(n) = tag.strip_prefix("rt-") {
        return tf("Temps réel « {0} » : envoi en échec", &[&n]);
    }
    match tag {
        "gdrive" => tr("Google Drive inaccessible").into(),
        "quota" => tr("Google Drive presque plein").into(),
        "cam-service" => tr("Caméras : service arrêté").into(),
        "cam-sync" => tr("Caméras : envoi en échec").into(),
        t => t.to_string(),
    }
}

pub fn passwords_window(app: &mut App, ctx: &egui::Context) {
    let Some(t) = app.passwords.clone() else { return };
    let mut open = true;
    egui::Window::new(RichText::new(tr("\u{E2D6} Mots de passe de chiffrement")).strong())
        .id(egui::Id::unique("pwd"))
        .collapsible(false)
        .default_width(600.0)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            banner(ui, WARN, tr("Sans ces mots de passe, les sauvegardes chiffrées du Drive sont définitivement illisibles (panne ou perte du NAS). Garde-les hors du NAS : gestionnaire de mots de passe, clé USB rangée, papier dans un lieu sûr."));
            ui.add_space(6.0);
            let mut tt = t.clone();
            ui.add(egui::TextEdit::multiline(&mut tt).font(egui::TextStyle::Monospace).desired_width(f32::INFINITY));
            ui.horizontal(|ui| {
                if ui.button(tr("\u{E1CA} Copier")).clicked() {
                    ui.ctx().copy_text(t.clone());
                }
                if ui.button(tr("\u{E248} Enregistrer dans un fichier…")).on_hover_text(tr("Par exemple sur une clé USB rangée en lieu sûr")).clicked() {
                    if let Some(path) = rfd::FileDialog::new().set_file_name("mots-de-passe-sauvegardes-NAS.txt").add_filter("Texte", &["txt"]).save_file() {
                        let content = tf("Mots de passe de chiffrement des sauvegardes du NAS (rclone crypt)\r\nExportés par NAS Manager le {0}\r\nÀ CONSERVER EN LIEU SÛR, HORS DU NAS.\r\n\r\n{1}\r\n", &[&(chrono::Local::now().format("%d/%m/%Y")), &(t.replace('\n', "\r\n"))]);
                        match std::fs::write(&path, content) {
                            Ok(()) => app.toast(true, tf("Enregistré : {0}", &[&(path.display())])),
                            Err(e) => app.toast(false, e.to_string()),
                        }
                    }
                }
                if ui.button(tr("Fermer")).clicked() {
                    app.passwords = None;
                }
            });
            ui.separator();
            let mut noted = app.settings.passwords_noted;
            if ui.checkbox(&mut noted, tr("Je les ai notés en lieu sûr (ne plus me le rappeler)")).changed() {
                app.settings.passwords_noted = noted;
                app.edit.passwords_noted = noted;
                let _ = crate::config::save(&app.settings);
            }
        });
    if !open {
        app.passwords = None;
    }
}

pub fn open_passwords(app: &mut App) {
    app.exec(
        HostId::Omv,
        tr("Lecture"),
        remote::show_passwords(),
        20,
        Box::new(|app, r| match r {
            Ok(o) => app.passwords = Some(o.text()),
            Err(e) => app.toast(false, e.to_string()),
        }),
    );
}

// =====================================================================
//  Copie Synology -> OMV
// =====================================================================

fn syno_script_banner(app: &mut App, ui: &mut egui::Ui, installed: bool, api: u32, _name: &str) -> bool {
    let expected = remote::copie_api();
    let migr = app.syno.status.as_ref().map(|s| s.migration_requise).unwrap_or(false);
    if installed && api >= expected {
        if migr {
            crate::scripts::widget(app, ui, crate::scripts::Kind::Synology);
            ui.add_space(6.0);
        }
        return true;
    }
    banner(
        ui,
        WARN,
        if installed {
            tr("La version du script installée sur le Synology est ancienne : mets-la à jour pour la piloter depuis l'application.")
        } else {
            tr("Le script nas-synology n'est pas encore installé sur le Synology (il remplace copie-omv et migre-drive-ocis ; les copies et l'historique déjà faits restent visibles).")
        },
    );
    crate::scripts::widget(app, ui, crate::scripts::Kind::Synology);
    ui.add_space(6.0);
    false
}

pub fn copy(app: &mut App, ui: &mut egui::Ui) {
    page_title(ui, tr("Copie Synology → OMV"), tr("Copie ou déplacement d'un dossier du Synology vers l'OMV (rsync)"));
    if !host_banner(app, ui, HostId::Syno) {
        return;
    }
    let s = app.syno.status.clone().unwrap();
    let c = s.copie.clone();
    let ready = syno_script_banner(app, ui, c.installe, c.api, "copie-omv");
    if !c.cle_omv {
        banner(ui, WARN, tr("Le Synology n'a pas encore de connexion automatique vers l'OMV."));
        if ui.button(tr("\u{E2D6} Autoriser le Synology à écrire sur l'OMV")).clicked() {
            authorize_syno_to_omv(app);
        }
        ui.add_space(6.0);
    }

    // ---- Copie en cours / derniere copie
    if c.source.is_some() {
        card(ui, if c.en_cours { tr("Copie en cours") } else { tr("Dernière copie") }, |ui| {
            let src = c.source.clone().unwrap_or_default();
            ui.label(RichText::new(tf("{0}  →  OMV : {1}", &[&src, &(c.destination.clone().unwrap_or_default())])).strong());
            ui.label(
                RichText::new(tf("{0} · {1} · {2} fichiers", &[&(if c.mode.as_deref() == Some("deplacement") { tr("Déplacement (originaux supprimés)") } else { tr("Copie") }), &(fmt::bytes(c.total)), &c.nb_fichiers]))
                .small(),
            );
            if c.en_cours {
                match &c.avancement {
                    Some(p) => progress_bar(
                        ui,
                        Some(p.pct),
                        tf("{0} % · {1} copiés · {2} · reste {3}", &[&p.pct, &p.fait, &p.vitesse, &p.reste]),
                    ),
                    None => progress_bar(ui, None, tr("Préparation de la liste des fichiers…").into()),
                }
                if c.debut > 0 {
                    ui.label(RichText::new(tf("Lancée {0}", &[&(fmt::ago(c.debut, s.maintenant))])).small().weak());
                }
                if danger_button(ui, tr("\u{E46C} Arrêter la copie")).clicked() {
                    app.ask_confirm(
                        tr("Arrêter la copie"),
                        tr("La copie s'arrête. La relancer (même source, même destination) reprendra là où elle s'est arrêtée."),
                        tr("Arrêter"),
                        true,
                        None,
                        Box::new(|app| app.action_toast(HostId::Syno, tr("Arrêt"), remote::copie_stop(), 30)),
                    );
                }
            } else {
                match c.code.as_deref() {
                    Some("0") => dot_label(ui, OK, tr("Terminée avec succès")),
                    Some("stop") => dot_label(ui, WARN, tr("Arrêtée manuellement")),
                    Some(code) => dot_label(ui, ERR, tf("Terminée avec une erreur (code {0}) — la relancer reprendra où elle s'est arrêtée", &[&code])),
                    None => dot_label(ui, WARN, tr("Interrompue")),
                };
                if let Some(l) = c.erreurs.iter().rev().find(|l| crate::explain::explain(l).is_some()) {
                    crate::explain::show(ui, l);
                }
                for l in &c.erreurs {
                    ui.label(RichText::new(l).monospace().size(12.0).color(ERR));
                }
                if ready
                    && ui
                        .button(tr("\u{E094} Relancer la même copie"))
                        .on_hover_text(tr("Reprend là où elle s'était arrêtée"))
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
    card(ui, tr("Nouvelle copie"), |ui| {
        ui.add_enabled_ui(ready, |ui| {
            egui::Grid::new("copygrid").num_columns(2).spacing([12.0, 10.0]).show(ui, |ui| {
                ui.label(tr("Dossier du Synology"));
                ui.horizontal(|ui| {
                    let r = ui.add(egui::TextEdit::singleline(&mut app.copy.src).desired_width(380.0).hint_text("/volume1/…"));
                    if r.lost_focus() && r.changed() {
                        app.copy.src_size = None;
                    }
                    if ui.button(tr("\u{E24A} Parcourir")).clicked() {
                        app.open_browser(HostId::Syno, BrowsePurpose::CopySource, "");
                    }
                });
                ui.end_row();
                ui.label("");
                ui.horizontal(|ui| match (app.copy.src_size, app.copy.sizing) {
                    (_, true) => {
                        ui.spinner();
                        ui.label(RichText::new(tr("Calcul de la taille…")).small());
                    }
                    (Some((sz, nb)), _) => {
                        ui.label(RichText::new(tf("{0} · {1} fichiers", &[&(fmt::bytes(sz)), &nb])).small());
                    }
                    (None, _) => {
                        if ui.add_enabled(!app.copy.src.is_empty(), egui::Button::new(tr("Calculer la taille")).small()).clicked() {
                            app.compute_copy_size();
                        }
                    }
                });
                ui.end_row();

                ui.label(tr("Dossier de l'OMV"));
                ui.horizontal(|ui| {
                    let r = ui.add(egui::TextEdit::singleline(&mut app.copy.dst).desired_width(380.0).hint_text("/srv/dev-disk-by-uuid-…/…"));
                    if r.lost_focus() && r.changed() {
                        app.copy.dst_free = None;
                        app.compute_copy_free();
                    }
                    if ui.button(tr("\u{E24A} Parcourir")).clicked() {
                        app.open_browser(HostId::Omv, BrowsePurpose::CopyDest, "");
                    }
                });
                ui.end_row();
                if let Some(f) = app.copy.dst_free {
                    ui.label("");
                    let enough = app.copy.src_size.map(|(sz, _)| sz <= f).unwrap_or(true);
                    if enough {
                        ui.label(RichText::new(tf("{0} libres sur l'OMV", &[&(fmt::bytes(f))])).small());
                    } else {
                        ui.colored_label(ERR, tf("Pas assez de place : {0} libres sur l'OMV", &[&(fmt::bytes(f))]));
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
                ui.label(tr("Placement"));
                ui.vertical(|ui| {
                    ui.radio_value(&mut app.copy.into_folder, true, tf("Dans un dossier « {0} »  →  {1}/{0}/…", &[&name, &(fmt::short_path(&dst))]));
                    ui.radio_value(&mut app.copy.into_folder, false, tf("Directement dans le dossier choisi  →  {0}/…", &[&(fmt::short_path(&dst))]));
                    if !name.is_empty() && dst.ends_with(&format!("/{name}")) && app.copy.into_folder {
                        ui.label(RichText::new(tf("(même nom des deux côtés : « directement » évite un dossier {0}/{0})", &[&name])).small().color(WARN));
                    }
                });
                ui.end_row();

                ui.label(tr("Mode"));
                ui.vertical(|ui| {
                    ui.radio_value(&mut app.copy.move_files, false, tr("Copier : les originaux restent sur le Synology"));
                    ui.radio_value(&mut app.copy.move_files, true, RichText::new(tr("Déplacer : les originaux sont SUPPRIMÉS du Synology après copie")).color(ERR));
                });
                ui.end_row();

                ui.label(tr("Limite de débit"));
                ui.horizontal(|ui| {
                    ui.add(egui::TextEdit::singleline(&mut app.copy.bw).desired_width(70.0).hint_text("—"));
                    ui.label("Mo/s");
                    ui.label(RichText::new(tr("vide = pleine vitesse")).small().weak());
                });
                ui.end_row();
            });
            ui.label(
                RichText::new(tr("Si la destination contient déjà des fichiers : fusion (rien n'y est supprimé, les fichiers de même nom mais différents sont remplacés). Les fichiers prennent les droits du dossier de destination."))
                    .small()
                    .weak(),
            );
            ui.add_space(6.0);
            let can = !app.copy.src.trim().is_empty() && !app.copy.dst.trim().is_empty();
            let bw: Option<u32> = app.copy.bw.trim().replace(',', ".").parse::<f64>().ok().filter(|v| *v > 0.0).map(|v| (v * 1024.0) as u32);
            let bw_bad = !app.copy.bw.trim().is_empty() && bw.is_none();
            if bw_bad {
                ui.colored_label(ERR, tr("Limite de débit invalide (en Mo/s, ex : 20)."));
            }
            ui.horizontal(|ui| {
            if ui.add_enabled(can && !bw_bad && !running, egui::Button::new(RichText::new(tr("\u{E3D0} Lancer")).color(Color32::WHITE)).fill(INFO)).clicked() {
                let (src, dst, into, mv) = (
                    app.copy.src.trim().trim_end_matches('/').to_string(),
                    app.copy.dst.trim().trim_end_matches('/').to_string(),
                    app.copy.into_folder,
                    app.copy.move_files,
                );
                let final_dst = if into { format!("{dst}/{}", src.rsplit('/').next().unwrap_or("")) } else { dst.clone() };
                let text = tf("{0}\n{1}\n  →  OMV : {2}", &[&(if mv { tr("DÉPLACEMENT (les originaux seront effacés du Synology au fur et à mesure) :") } else { tr("Copie :") }), &src, &final_dst]);
                app.ask_confirm(
                    if mv { tr("Déplacer vers l'OMV") } else { tr("Copier vers l'OMV") },
                    &text,
                    tr("Lancer"),
                    mv,
                    if mv { Some(tr("DEPLACER")) } else { None },
                    Box::new(move |app| {
                        app.action_dialog(HostId::Syno, tr("Lancement de la copie"), remote::copie_launch(&src, &dst, into, mv, bw), 1200)
                    }),
                );
            }
            if ui
                .add_enabled(can && !bw_bad, egui::Button::new(tr("+ Ajouter à la file d'attente")))
                .on_hover_text(tr("Les copies de la file partent l'une après l'autre, après celle en cours"))
                .clicked()
            {
                let (src, dst, into, mv) = (
                    app.copy.src.trim().trim_end_matches('/').to_string(),
                    app.copy.dst.trim().trim_end_matches('/').to_string(),
                    app.copy.into_folder,
                    app.copy.move_files,
                );
                let script = remote::copie_queue_add(&src, &dst, into, mv, bw);
                if mv {
                    app.ask_confirm(
                        tr("Déplacement en file d'attente"),
                        &tf("{0} sera DÉPLACÉ vers l'OMV (originaux effacés du Synology) quand son tour viendra.", &[&src]),
                        tr("Ajouter"),
                        true,
                        Some(tr("DEPLACER")),
                        Box::new(move |app| app.action_toast(HostId::Syno, tr("Ajout"), script, 30)),
                    );
                } else {
                    app.action_toast(HostId::Syno, tr("Ajout"), script, 30);
                }
            }
            });
        });
        if running {
            ui.label(RichText::new(tr("Une copie est en cours : ajoute les suivantes à la file d'attente, elles partiront après.")).small().weak());
        }
    });
    ui.add_space(10.0);

    // ---- file d'attente des copies
    if !c.file.is_empty() {
        card(ui, &tf("File d'attente ({0})", &[&(c.file.len())]), |ui| {
            let mut remove: Option<usize> = None;
            for (i, q) in c.file.iter().enumerate() {
                ui.horizontal(|ui| {
                    ui.label(RichText::new(format!("{}.", i + 1)).weak());
                    let name = q.source.rsplit('/').next().unwrap_or("");
                    ui.label(RichText::new(format!(
                        "{}  →  {}{}",
                        q.source,
                        fmt::short_path(&q.destination),
                        if q.dans_dossier { format!("/{name}") } else { String::new() }
                    )).strong());
                    if q.deplacement {
                        badge(ui, tr("déplacement"), ERR);
                    }
                    if !q.debit.is_empty() {
                        let mo = q.debit.parse::<f64>().map(|k| k / 1024.0).unwrap_or(0.0);
                        badge(ui, &tf("{0} Mo/s max", &[&(tf("{0}", &[&format!("{:.1}", mo)]).trim_end_matches(".0").replace('.', ","))]), IDLE);
                    }
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.add_enabled(ready, egui::Button::new("\u{E4F6}").small()).on_hover_text(tr("Retirer de la file")).clicked() {
                            remove = Some(i + 1);
                        }
                    });
                });
            }
            if let Some(n) = remove {
                app.action_toast(HostId::Syno, tr("Retrait"), remote::copie_queue_remove(n), 30);
            }
            if !running && ui.add_enabled(ready, egui::Button::new(tr("\u{E3D0} Lancer la file d'attente"))).clicked() {
                app.action_toast(HostId::Syno, tr("Lancement"), remote::copie_queue_next(), 1200);
            }
            ui.label(RichText::new(tr("La copie suivante part automatiquement quand la précédente se termine avec succès.")).small().weak());
        });
    }
    ui.add_space(10.0);

    egui::CollapsingHeader::new(tr("\u{E5D4} Réparer les droits d'un dossier sur l'OMV")).show(ui, |ui| {
        ui.horizontal(|ui| {
            ui.add(egui::TextEdit::singleline(&mut app.perms.dir).desired_width(380.0).hint_text(tr("dossier de l'OMV")));
            if ui.button("\u{E24A}").clicked() {
                app.open_browser(HostId::Omv, BrowsePurpose::PermsDir, "");
            }
        });
        ui.horizontal(|ui| {
            ui.label(tr("Propriétaire"));
            ui.add(egui::TextEdit::singleline(&mut app.perms.owner).desired_width(90.0));
            ui.label(tr("Groupe"));
            ui.add(egui::TextEdit::singleline(&mut app.perms.group).desired_width(90.0));
            if ui.add_enabled(!app.perms.dir.is_empty(), egui::Button::new(tr("Appliquer"))).clicked() {
                let (d, o, g) = (app.perms.dir.clone(), app.perms.owner.clone(), app.perms.group.clone());
                app.ask_confirm(
                    tr("Réparer les droits"),
                    &tf("Sur tout le contenu de {0} : propriétaire {1}:{2}, dossiers 2775, fichiers 664.", &[&d, &o, &g]),
                    tr("Appliquer"),
                    false,
                    None,
                    Box::new(move |app| app.action_dialog(HostId::Omv, tr("Réparation des droits"), remote::fix_perms(&d, &o, &g), 1800)),
                );
            }
        });
        ui.label(RichText::new(tr("Groupe « users » = tous les utilisateurs du partage OMV.")).small().weak());
    });
    ui.add_space(10.0);

    card(ui, tr("Historique"), |ui| {
        if c.historique.is_empty() {
            ui.label(RichText::new(tr("Aucune copie.")).weak());
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
    tf("{0} · {1}{2} · {3}  →  {4} · {5}", &[&when, &(p[1]), &extra, &src, &(fmt::short_path(dst)), &dur])
}

// =====================================================================
//  Migration oCIS
// =====================================================================

pub fn migration(app: &mut App, ui: &mut egui::Ui) {
    page_title(ui, tr("Migration Synology Drive → oCIS"), tr("Transfert des « Mon Drive » vers des espaces projets ownCloud Infinite Scale"));
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
    card(ui, tr("Connexion oCIS"), |ui| {
        match &m.config {
            Some(c) => {
                ui.label(tf("{0}  ·  compte {1}", &[&c.url, &c.utilisateur]));
                ui.label(
                    RichText::new(tf("Transferts : {0}  ·  mode {1}", &[&(if c.locale.is_empty() { tr("via Internet").to_string() } else { tf("réseau local ({0})", &[&c.locale]) }), &(if c.mode == "owncloud" { tr("WebDAV classique").to_string() } else { c.mode.clone() })]))
                    .small()
                    .weak(),
                );
            }
            None => {
                ui.colored_label(WARN, tr("Pas encore configurée."));
            }
        }
        if ui.add_enabled(ready, egui::Button::new(if app.ocis.open { tr("Fermer") } else { tr("Modifier la connexion…") })).clicked() {
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
                ui.label(tr("Adresse d'oCIS"));
                ui.add(egui::TextEdit::singleline(&mut app.ocis.url).hint_text("https://cloud.maison.fr").desired_width(320.0));
                ui.end_row();
                ui.label(tr("Utilisateur"));
                ui.add(egui::TextEdit::singleline(&mut app.ocis.user).desired_width(200.0));
                ui.end_row();
                ui.label(tr("Jeton d'application"));
                ui.add(egui::TextEdit::singleline(&mut app.ocis.token).password(true).desired_width(320.0));
                ui.end_row();
                ui.label(tr("Adresse locale"));
                ui.add(egui::TextEdit::singleline(&mut app.ocis.local).hint_text(tr("vide = passer par Internet")).desired_width(320.0));
                ui.end_row();
                ui.label("");
                ui.checkbox(&mut app.ocis.insecure, tr("Accepter un certificat non reconnu (auto-signé)"));
                ui.end_row();
            });
            ui.label(RichText::new(tr("Jeton : docker exec <conteneur-ocis> ocis auth-app create --user-name=<compte> --expiration=2160h")).small().monospace().weak());
            let can = !app.ocis.url.trim().is_empty() && !app.ocis.user.trim().is_empty() && !app.ocis.token.trim().is_empty();
            if ui.add_enabled(can, egui::Button::new(tr("Tester et enregistrer"))).clicked() {
                let f = app.ocis.clone();
                app.ocis.open = false;
                app.ocis.token.clear();
                app.action_dialog(
                    HostId::Syno,
                    tr("Connexion à oCIS"),
                    remote::migre_configure(&f.url, &f.user, &f.token, &f.local, f.insecure),
                    300,
                );
            }
        }
    });
    ui.add_space(10.0);

    // ---- Migration en cours
    if m.en_cours {
        card(ui, tr("Migration en cours"), |ui| {
            if let Some(e) = &m.etape {
                ui.label(RichText::new(format!("[{}/{}]  {}  →  {}", e.etape, m.nb, e.libelle, e.espace)).strong());
                ui.label(RichText::new(format!("{} · {}", e.source, fmt::bytes(e.total))).small().weak());
                let phase = match e.phase.as_str() {
                    "verification" => tr("Contrôle des empreintes dans oCIS"),
                    "relecture" => tr("Contrôle par relecture depuis oCIS"),
                    "suppression" => tr("Suppression des originaux contrôlés"),
                    "renvoi" => tr("Renvoi des fichiers en défaut"),
                    _ => tr("Transfert"),
                };
                ui.label(phase);
                let line = if e.ligne.is_empty() {
                    if e.phase.is_empty() { tr("Comparaison avec ce qui est déjà dans oCIS…").into() } else { tr("démarrage…").into() }
                } else {
                    fmt::stats_line(&e.ligne)
                };
                progress_bar(ui, e.pct, line);
                let mut extra = Vec::new();
                if let Some(r) = e.ram_mo {
                    extra.push(tf("RAM rclone {0} Mo", &[&r]));
                }
                if e.reprise > 0 {
                    extra.push(tf("reprise automatique {0}/5", &[&e.reprise]));
                }
                if e.suppression == "oui" {
                    extra.push(tr("+ suppression des originaux contrôlés").into());
                } else if e.suppression == "verif" {
                    extra.push(tr("contrôle + suppression sans transfert").into());
                }
                if !extra.is_empty() {
                    ui.label(RichText::new(extra.join(" · ")).small().color(if e.reprise > 0 { WARN } else { IDLE }));
                }
            }
            if m.debut > 0 {
                ui.label(RichText::new(tf("Lancée {0}", &[&(fmt::ago(m.debut, s.maintenant))])).small().weak());
            }
            if danger_button(ui, tr("\u{E46C} Arrêter la migration")).clicked() {
                app.ask_confirm(
                    tr("Arrêter la migration"),
                    tr("La migration s'arrête ; les éléments non terminés sont remis en file d'attente et reprendront là où ils en étaient."),
                    tr("Arrêter"),
                    true,
                    None,
                    Box::new(|app| app.action_toast(HostId::Syno, tr("Arrêt"), remote::migre_stop(), 30)),
                );
            }
        });
        ui.add_space(10.0);
    }

    // ---- Resultats
    if !m.resultats.is_empty() {
        card(ui, tr("Résultats du dernier lancement"), |ui| {
            for r in &m.resultats {
                ui.horizontal_wrapped(|ui| {
                    dot(ui, if r.etat == "OK" { OK } else { ERR });
                    ui.label(RichText::new(format!("{} → {}", r.libelle, r.espace)).strong());
                    if !r.detail.is_empty() && r.etat == "OK" {
                        ui.label(RichText::new(&r.detail).small());
                    }
                });
                if r.etat != "OK" && !r.detail.is_empty() {
                    crate::explain::show(ui, &r.detail);
                }
            }
            if m.resultats.iter().any(|r| r.detail.contains("quota")) {
                ui.label(RichText::new(tr("Espace plein : dans oCIS, ouvre l'espace > \u{E1FE} > Modifier le quota > « Pas de restriction ».")).small().color(WARN));
            }
            if m.resultats.iter().any(|r| r.detail.contains("401")) {
                ui.label(RichText::new(tr("Jeton refusé : recrée un jeton et mets à jour la connexion ci-dessus.")).small().color(WARN));
            }
        });
        ui.add_space(10.0);
    }

    // ---- File d'attente
    card(ui, &tf("File d'attente ({0})", &[&(m.file.len())]), |ui| {
        if m.file.is_empty() {
            ui.label(RichText::new(tr("Vide : ajoute une migration ci-dessous.")).weak());
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
                    "oui" => badge(ui, tr("+ suppression des originaux"), ERR),
                    "verif" => badge(ui, tr("contrôle + suppression"), ERR),
                    _ => {}
                }
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.add_enabled(ready && !m.en_cours, egui::Button::new("\u{E4F6}").small()).on_hover_text(tr("Retirer de la file")).clicked() {
                        remove = Some(i + 1);
                    }
                });
            });
        }
        if let Some(n) = remove {
            app.action_toast(HostId::Syno, tr("Retrait"), remote::migre_remove(n), 30);
        }
        ui.add_space(4.0);
        if ui
            .add_enabled(ready && !m.en_cours && !m.file.is_empty(), egui::Button::new(RichText::new(tr("\u{E3D0} Lancer la file d'attente")).color(Color32::WHITE)).fill(INFO))
            .clicked()
        {
            let has_delete = m.file.iter().any(|q| q.suppression != "non");
            app.ask_confirm(
                tr("Lancer la migration"),
                &tf("{0} migration(s) vont être traitées l'une après l'autre, en arrière-plan sur le Synology.{1}", &[&(m.file.len()), &(if has_delete { tr("\nCertaines suppriment les originaux du Synology après contrôle dans oCIS.") } else { "" })]),
                tr("Lancer"),
                false,
                None,
                Box::new(|app| app.action_toast(HostId::Syno, tr("Lancement"), remote::migre_start(), 120)),
            );
        }
    });
    ui.add_space(10.0);

    // ---- Ajouter
    card(ui, tr("Ajouter une migration"), |ui| {
        ui.add_enabled_ui(ready && m.config.is_some(), |ui| {
            if m.config.is_none() {
                ui.colored_label(WARN, tr("Configure d'abord la connexion oCIS."));
            }
            ui.horizontal(|ui| {
                ui.label(tr("Source :"));
                let sel = if app.mig.src.is_empty() { tr("Choisir…").to_string() } else { app.mig.src.clone() };
                let mut picked: Option<(String, String)> = None;
                egui::ComboBox::from_id_salt("migsrc").width(360.0).selected_text(sel).show_ui(ui, |ui| {
                    if app.mig.sources.is_empty() {
                        ui.label(RichText::new(tr("(clique sur \u{E094} pour lister les Mon Drive)")).weak());
                    }
                    for (p, l) in &app.mig.sources {
                        if ui.selectable_label(app.mig.src == *p, tf("Mon Drive de {0}", &[&l])).clicked() {
                            picked = Some((p.clone(), l.clone()));
                        }
                    }
                });
                if let Some((p, l)) = picked {
                    app.mig.src = p;
                    app.mig.label = l;
                }
                if ui.button("\u{E094}").on_hover_text(tr("Lister les « Mon Drive »")).clicked() {
                    load_mig_sources(app);
                }
                if ui.button(tr("\u{E24A} Parcourir")).clicked() {
                    app.open_browser(HostId::Syno, BrowsePurpose::MigSource, "");
                }
            });
            ui.horizontal(|ui| {
                ui.label(tr("Espace oCIS :"));
                let sel = app
                    .mig
                    .space_idx
                    .and_then(|i| app.mig.spaces.get(i))
                    .map(|s| s.name.clone())
                    .unwrap_or_else(|| tr("Choisir…").into());
                let mut pick: Option<usize> = None;
                egui::ComboBox::from_id_salt("migspace").width(300.0).selected_text(sel).show_ui(ui, |ui| {
                    for (i, sp) in app.mig.spaces.iter().enumerate() {
                        let q = if sp.quota > 0 {
                            tf("libre {0} / quota {1}", &[&(fmt::bytes(sp.free.max(0) as u64)), &(fmt::bytes(sp.quota as u64))])
                        } else {
                            tr("sans limite").into()
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
                } else if ui.button("\u{E094}").on_hover_text(tr("Lister les espaces projets")).clicked() {
                    load_spaces(app);
                }
            });
            if !app.mig.spaces_error.is_empty() {
                ui.colored_label(ERR, &app.mig.spaces_error);
            }
            ui.horizontal(|ui| {
                ui.label(tr("Sous-dossier dans l'espace :"));
                ui.add(egui::TextEdit::singleline(&mut app.mig.sub).hint_text(tr("vide = racine de l'espace")).desired_width(220.0));
                ui.label(tr("Libellé :"));
                ui.add(egui::TextEdit::singleline(&mut app.mig.label).desired_width(140.0));
            });
            ui.label(tr("Après le transfert :"));
            ui.radio_value(&mut app.mig.del_mode, 0, tr("Garder les originaux sur le Synology (copie)"));
            ui.radio_value(&mut app.mig.del_mode, 1, RichText::new(tr("Contrôler chaque fichier dans oCIS, puis SUPPRIMER l'original du Synology")).color(ERR));
            ui.radio_value(&mut app.mig.del_mode, 2, RichText::new(tr("Déjà migré : contrôler et supprimer les originaux, sans transfert")).color(ERR));
            if app.mig.del_mode > 0 && app.mig.src.contains("/homes/") && app.mig.src.ends_with("/Drive") {
                ui.label(RichText::new(tr("C'est un « Mon Drive » : les ordinateurs synchronisés avec Synology Drive supprimeront aussi ces fichiers chez eux. Installe d'abord le client oCIS.")).small().color(ERR));
            }
            let sp = app.mig.space_idx.and_then(|i| app.mig.spaces.get(i)).cloned();
            let can = !app.mig.src.is_empty() && sp.is_some();
            if ui.add_enabled(can, egui::Button::new(tr("+ Ajouter à la file d'attente"))).clicked() {
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
                        tr("Suppression des originaux"),
                        tr("Seuls les fichiers dont la copie dans oCIS est contrôlée identique (empreinte) seront supprimés du Synology. Un fichier absent, différent ou modifié entre-temps est gardé."),
                        tr("Ajouter"),
                        true,
                        Some(tr("SUPPRIMER")),
                        Box::new(move |app| app.action_toast(HostId::Syno, tr("Ajout"), script, 900)),
                    );
                } else {
                    app.action_toast(HostId::Syno, tr("Ajout (calcul de la taille)"), script, 900);
                }
            }
        });
    });
    ui.add_space(10.0);

    egui::CollapsingHeader::new(tr("Journal de la migration (dernières lignes)")).show(ui, |ui| {
        for l in &m.journal {
            ui.label(RichText::new(l).monospace().size(12.0));
        }
    });
    card(ui, tr("Historique"), |ui| {
        if m.historique.is_empty() {
            ui.label(RichText::new(tr("Aucune migration.")).weak());
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
        tr("Espaces oCIS"),
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
                        app.mig.spaces_error = tr("Aucun espace projet visible : ajoute le compte comme membre des espaces (Peut modifier / Gestionnaire).").into();
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
        tr("Mon Drive"),
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
                    app.toast(false, tr("Aucun « Mon Drive » trouvé (/volume*/homes/*/Drive).").into());
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
        label: tr("Sauvegardes (nas-backup.log)").into(),
        host: HostId::Omv,
        path: "/var/log/nas-backup.log".into(),
    }];
    if let Some(s) = &app.omv.status {
        for j in &s.sauvegardes {
            v.push(LogSource {
                label: tf("Sauvegarde « {0} »{1}", &[&j.nom, &(if j.en_cours { tr(" (en cours)") } else { tr(" (dernière)") })]),
                host: HostId::Omv,
                path: format!("/var/lib/nas-backup/{}.run.log", j.nom),
            });
        }
    }
    if let Some(s) = &app.omv.status {
        for j in &s.temps_reel {
            v.push(LogSource { label: tf("Temps réel « {0} »", &[&j.nom]), host: HostId::Omv, path: format!("/var/log/nas-temps-reel/{}.log", j.nom) });
        }
        if s.cameras.installe {
            v.push(LogSource { label: tr("Caméras (cam-sync.log)").into(), host: HostId::Omv, path: "/var/log/cam-sync.log".into() });
        }
    }
    v.push(LogSource { label: tr("Restauration").into(), host: HostId::Omv, path: "/var/lib/nas-backup/restauration.log".into() });
    if app.settings.syno.is_set() {
        v.push(LogSource { label: tr("Copie → OMV : progression").into(), host: HostId::Syno, path: "/root/.copie-omv/progression.log".into() });
        v.push(LogSource { label: tr("Copie → OMV : historique").into(), host: HostId::Syno, path: "/root/.copie-omv/historique.log".into() });
        v.push(LogSource { label: tr("Migration oCIS : progression").into(), host: HostId::Syno, path: "/root/.migre-ocis/progression.log".into() });
        v.push(LogSource { label: tr("Migration oCIS : historique").into(), host: HostId::Syno, path: "/root/.migre-ocis/historique.log".into() });
    }
    v
}

pub fn logs(app: &mut App, ui: &mut egui::Ui) {
    page_title(ui, tr("Journaux"), tr("Dernières lignes des journaux des scripts"));
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
        if ui.button("\u{E094}").clicked() {
            changed = true;
        }
        ui.checkbox(&mut app.logs.auto, tr("Suivre en direct"));
        ui.add(egui::TextEdit::singleline(&mut app.logs.filter).hint_text(tr("filtrer…")).desired_width(160.0));
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
            tr("Lecture du journal"),
            remote::tail_file(&path, 600),
            30,
            Box::new(move |app, r| {
                app.logs.loading = false;
                if app.logs.source != idx {
                    return;
                }
                app.logs.text = match r {
                    Ok(o) => crate::ssh::strip_ansi(&o.stdout),
                    Err(e) => tf("(lecture impossible : {0})", &[&e]),
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
        ui.label(tr("Adresse IP / nom"));
        ui.add(egui::TextEdit::singleline(&mut h.host).desired_width(220.0).hint_text("192.168.1.x"));
        ui.end_row();
        ui.label(tr("Port SSH"));
        let mut p = h.port.to_string();
        if ui.add(egui::TextEdit::singleline(&mut p).desired_width(70.0)).changed() {
            if let Ok(v) = p.trim().parse() {
                h.port = v;
            }
        }
        ui.end_row();
        ui.label(tr("Utilisateur"));
        ui.add(egui::TextEdit::singleline(&mut h.user).desired_width(160.0));
        ui.end_row();
        ui.label("");
        ui.checkbox(&mut h.sudo, tr("Passer par sudo")).on_hover_text(sudo_hint);
        ui.end_row();
    });
}

pub fn settings(app: &mut App, ui: &mut egui::Ui) {
    page_title(ui, tr("Paramètres"), tr("Connexion aux NAS, clé SSH et scripts"));

    card(ui, tr("1. Clé SSH de l'application"), |ui| {
        if app.ssh.key_exists() {
            dot_label(ui, OK, tr("Clé créée sur ce PC"));
            ui.label(RichText::new(app.ssh.key.to_string_lossy()).small().weak());
        } else {
            dot_label(ui, ERR, tr("Clé absente"));
            if !app.key_msg.is_empty() {
                ui.colored_label(ERR, &app.key_msg);
            }
            if ui.button(tr("Créer la clé")).clicked() {
                match app.ssh.generate_key() {
                    Ok(()) => app.key_msg.clear(),
                    Err(e) => app.key_msg = e,
                }
            }
        }
        ui.label(
            RichText::new(tr("L'application se connecte aux NAS avec cette clé : le mot de passe des comptes n'est demandé qu'une fois, pour l'autoriser."))
                .small()
                .weak(),
        );
    });
    ui.add_space(10.0);

    let mut save = false;
    ui.columns(2, |cols| {
        card(&mut cols[0], tr("2. OMV / Debian (sauvegardes programmées et temps réel, alertes)"), |ui| {
            host_settings(ui, "omvset", &mut app.edit.omv, tr("Si l'utilisateur n'est pas root"));
        });
        card(&mut cols[1], tr("3. Synology (copie vers l'OMV, migration oCIS)"), |ui| {
            host_settings(ui, "synoset", &mut app.edit.syno, tr("Compte administrateur du Synology (la connexion root est désactivée par défaut sur DSM)"));
            ui.label(RichText::new(tr("Service SSH à activer : DSM > Panneau de configuration > Terminal & SNMP.")).small().weak());
        });
    });
    ui.add_space(10.0);
    card(ui, tr("Préférences"), |ui| {
        ui.horizontal(|ui| {
            ui.label(tr("Actualisation toutes les"));
            let mut r = app.edit.refresh_secs.to_string();
            if ui.add(egui::TextEdit::singleline(&mut r).desired_width(40.0)).changed() {
                if let Ok(v) = r.trim().parse() {
                    app.edit.refresh_secs = v;
                }
            }
            ui.label(tr("secondes (4 s pendant un transfert)"));
        });
        egui::CollapsingHeader::new(tr("Avancé")).show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.label(tr("Client ssh :"));
                ui.add(egui::TextEdit::singleline(&mut app.edit.ssh_bin).hint_text(tr("ssh (client OpenSSH de Windows)")).desired_width(320.0));
            });
        });
        ui.horizontal(|ui| {
            ui.label(tr("Thème :"));
            for (v, l) in [("systeme", tr("Automatique (Windows)")), ("clair", tr("Clair")), ("sombre", tr("Sombre"))] {
                ui.radio_value(&mut app.edit.theme, v.to_string(), l);
            }
        });
        ui.horizontal(|ui| {
        ui.label(tr("Langue :"));
        ui.radio_value(&mut app.edit.language, String::new(), tr("Automatique (Windows)"));
        ui.radio_value(&mut app.edit.language, "fr".to_string(), tr("Français"));
        ui.radio_value(&mut app.edit.language, "en".to_string(), tr("English"));
    });
    ui.horizontal(|ui| {
        ui.label(tr("Taille du texte :"));
        ui.add(egui::Slider::new(&mut app.edit.zoom, 0.8..=1.8).step_by(0.1).custom_formatter(|v, _| format!("{:.0} %", v * 100.0)));
        if ui.small_button("100 %").clicked() {
            app.edit.zoom = 1.0;
        }
    });
    ui.checkbox(&mut app.edit.read_only, tr("Mode lecture seule (consultation uniquement, aucune action sur les NAS)"));
        ui.checkbox(&mut app.edit.notifications, tr("Notifications Windows (fin de sauvegarde, de copie, de migration, alertes, NAS injoignable)"));
        ui.checkbox(&mut app.edit.close_to_tray, tr("Fermer la fenêtre = la réduire dans la zone de notification (la surveillance continue)"));
        if crate::tray::autostart_supported() {
            let mut a = app.autostart;
            if ui.checkbox(&mut a, tr("Lancer NAS Manager au démarrage de Windows (dans la zone de notification)")).changed() {
                match crate::tray::set_autostart(a) {
                    Ok(()) => {
                        app.autostart = a;
                        crate::log::info(&format!("démarrage avec Windows : {}", if a { "activé" } else { "désactivé" }));
                    }
                    Err(e) => app.toast(false, e),
                }
            }
        }
        if ui.small_button(tr("Tester une notification")).clicked() {
            crate::tray::notify(&app.ctx, tr("NAS Manager"), tr("Les notifications fonctionnent."));
        }
    });
    ui.add_space(6.0);
    let dirty = app.edit.omv != app.settings.omv
        || app.edit.syno != app.settings.syno
        || app.edit.refresh_secs != app.settings.refresh_secs
        || app.edit.ssh_bin != app.settings.ssh_bin
        || app.edit.theme != app.settings.theme
        || app.edit.read_only != app.settings.read_only
        || app.edit.notifications != app.settings.notifications
        || app.edit.close_to_tray != app.settings.close_to_tray
        || app.edit.site != app.settings.site
        || (app.edit.zoom - app.settings.zoom).abs() > 0.01
        || app.edit.language != app.settings.language;
    ui.horizontal(|ui| {
        if ui.add_enabled(dirty, egui::Button::new(RichText::new(tr("\u{E248} Enregistrer")).color(Color32::WHITE)).fill(INFO)).clicked() {
            save = true;
        }
        if dirty {
            ui.label(RichText::new(tr("Modifications non enregistrées")).color(WARN));
        }
    });
    if save {
        app.save_settings();
    }
    ui.add_space(10.0);

    card(ui, tr("4. Autoriser la clé et tester"), |ui| {
        for h in [HostId::Omv, HostId::Syno] {
            let cfg = app.host_cfg(h).clone();
            ui.horizontal(|ui| {
                ui.label(RichText::new(format!("{} ({})", h.label(), if cfg.is_set() { cfg.target() } else { tr("non configuré").into() })).strong());
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.add_enabled(cfg.is_set(), egui::Button::new(tr("Oublier l'identité"))).on_hover_text(tr("Après une réinstallation du NAS")).clicked() {
                        match app.ssh.forget_host(&cfg) {
                            Ok(()) => {
                                crate::log::info(&format!("identité oubliée pour {}", cfg.target()));
                                app.toast(true, tr("Identité oubliée : la nouvelle empreinte va être demandée.").into());
                                app.fp_dismissed[crate::extras::idx(h)] = false;
                                app.refresh(h);
                            }
                            Err(e) => app.toast(false, e),
                        }
                    }
                    if ui.add_enabled(cfg.is_set(), egui::Button::new(tr("\u{E946} Tester"))).clicked() {
                        test_connection(app, h);
                    }
                    if ui.add_enabled(cfg.is_set(), egui::Button::new(tr("\u{E2D6} Autoriser la clé…"))).clicked() {
                        crate::extras::authorize_key(app, h);
                    }
                });
            });
            let (col, txt) = if !cfg.is_set() {
                (IDLE, "—".to_string())
            } else if let Some(e) = app.host_error(h) {
                (ERR, e.to_string())
            } else if app.host_connected(h) {
                (OK, tr("Connecté").to_string())
            } else {
                (IDLE, tr("Pas encore testé").to_string())
            };
            dot_label(ui, col, RichText::new(txt).small());
            if cfg.sudo {
                let has = match h {
                    HostId::Omv => app.omv.pass.is_some(),
                    HostId::Syno => app.syno.pass.is_some(),
                };
                ui.horizontal(|ui| {
                    ui.label(RichText::new(if has { tr("Mot de passe sudo : en mémoire") } else { tr("Mot de passe sudo : non saisi") }).small().weak());
                    if has && ui.small_button(tr("Oublier")).clicked() {
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
                        ui.label(RichText::new(tr("(il sera demandé et pourra être mémorisé)")).small().weak());
                    }
                });
            }
            ui.separator();
        }
        ui.label(
            RichText::new(tr("« Autoriser la clé » ouvre une fenêtre où tu tapes une seule fois le mot de passe du compte. Ensuite plus besoin de SSH."))
                .small()
                .weak(),
        );
    });
    ui.add_space(10.0);

    card(ui, tr("5. Scripts sur les NAS"), |ui| {
        crate::scripts::card(app, ui);
    });
    ui.add_space(10.0);
    sites_card(app, ui);
    ui.add_space(10.0);
    update_card(app, ui);
    ui.add_space(10.0);
    maintenance_card(app, ui);
}

fn sites_card(app: &mut App, ui: &mut egui::Ui) {
    card(ui, tr("Sites (plusieurs NAS)"), |ui| {
        ui.label(
            RichText::new(tr("Un site = un OMV et un Synology (le tien, celui d'un proche…). Les réglages ci-dessus sont ceux du site actif."))
                .small()
                .weak(),
        );
        ui.horizontal(|ui| {
            ui.label(tr("Site actif :"));
            ui.add(egui::TextEdit::singleline(&mut app.edit.site).desired_width(160.0));
        });
        let mut switch: Option<String> = None;
        let mut delete: Option<String> = None;
        for s in app.settings.sites.clone() {
            ui.horizontal(|ui| {
                ui.label(RichText::new(format!("\u{E2C2} {}", s.name)).strong());
                ui.label(
                    RichText::new(tf("OMV {0} · Synology {1}", &[&(if s.omv.is_set() { s.omv.host.clone() } else { "—".into() }), &(if s.syno.is_set() { s.syno.host.clone() } else { "—".into() })]))
                    .small()
                    .weak(),
                );
                if ui.small_button(tr("Activer")).clicked() {
                    switch = Some(s.name.clone());
                }
                if ui.small_button(tr("Supprimer")).clicked() {
                    delete = Some(s.name.clone());
                }
            });
        }
        ui.horizontal(|ui| {
            ui.add(egui::TextEdit::singleline(&mut app.new_site).hint_text(tr("nom du nouveau site")).desired_width(180.0));
            let name = app.new_site.trim().to_string();
            let taken = app.settings.site_names().iter().any(|n| n.eq_ignore_ascii_case(&name));
            if ui.add_enabled(!name.is_empty() && !taken, egui::Button::new(tr("+ Ajouter un site"))).clicked() {
                app.settings.sites.push(crate::config::Site {
                    name: name.clone(),
                    omv: crate::config::HostCfg { host: String::new(), port: 22, user: "root".into(), sudo: false, saved_pass: String::new() },
                    syno: crate::config::HostCfg { host: String::new(), port: 22, user: String::new(), sudo: true, saved_pass: String::new() },
                });
                app.edit.sites = app.settings.sites.clone();
                let _ = crate::config::save(&app.settings);
                app.new_site.clear();
                switch = Some(name);
            }
        });
        if let Some(n) = switch {
            app.switch_site(&n);
        }
        if let Some(n) = delete {
            app.ask_confirm(
                tr("Supprimer le site"),
                &tf("Le site « {0} » et ses réglages de connexion sont oubliés (rien n'est modifié sur ses NAS).", &[&n]),
                tr("Supprimer"),
                true,
                None,
                Box::new(move |app| {
                    app.settings.sites.retain(|s| s.name != n);
                    app.edit.sites = app.settings.sites.clone();
                    let _ = crate::config::save(&app.settings);
                }),
            );
        }
    });
}

fn update_card(app: &mut App, ui: &mut egui::Ui) {
    card(ui, tr("Mises à jour de NAS Manager"), |ui| {
        ui.horizontal(|ui| {
            ui.label(tf("Version installée : {0}", &[&(crate::extras::VERSION)]));
            if app.update.checking {
                ui.spinner();
            } else if ui.button(tr("Rechercher une mise à jour")).clicked() {
                crate::update::start_check(app, true);
            }
            if let Some(u) = app.update.available.clone() {
                if app.update.installing {
                    ui.spinner();
                    ui.label(tr("installation…"));
                } else if primary_button(ui, &tf("Installer la version {0}", &[&u.version])).clicked() {
                    crate::update::start_install(app);
                }
            }
        });
        if !app.update.message.is_empty() {
            ui.label(RichText::new(&app.update.message).small().weak());
        }
        let mut a = app.settings.auto_update;
        if ui.checkbox(&mut a, tr("Rechercher automatiquement les mises à jour (une fois par jour)")).changed() {
            app.settings.auto_update = a;
            app.edit.auto_update = a;
            let _ = crate::config::save(&app.settings);
        }
        ui.label(RichText::new(tr("La mise à jour remplace l'exécutable et relance l'application ; les paramètres sont conservés.")).small().weak());
    });
}

fn maintenance_card(app: &mut App, ui: &mut egui::Ui) {
    card(ui, tr("6. Diagnostic et sauvegarde des paramètres"), |ui| {
        ui.horizontal_wrapped(|ui| {
            if ui.button(tr("\u{E7EA} Exporter un rapport de diagnostic…")).on_hover_text(tr("Versions, état des connexions, dernières erreurs — sans aucun mot de passe")).clicked() {
                crate::extras::export_diagnostic(app);
            }
            if ui.button(tr("\u{EB7A} Journal de l'application")).clicked() {
                app.output = Some(OutputDialog {
                    title: tr("Journal de l'application").into(),
                    text: {
                        let t = crate::log::tail(300);
                        if t.is_empty() { tr("(vide)").into() } else { t }
                    },
                    ok: true,
                });
            }
            if ui.button(tr("\u{EAF0} Exporter les paramètres…")).clicked() {
                crate::extras::export_settings(app);
            }
            if ui.button(tr("\u{E20C} Importer des paramètres…")).clicked() {
                crate::extras::import_settings(app);
            }
            if ui.button(tr("\u{E6A2} Nouveautés")).clicked() {
                app.show_news = true;
            }
        });
        ui.label(RichText::new(tf("Dossier de l'application : {0}", &[&(crate::config::app_dir().display())])).small().weak());
        ui.label(RichText::new(tr("Raccourcis : F5 actualiser · Ctrl+1 à Ctrl+9 changer de page")).small().weak());
    });
}

fn test_connection(app: &mut App, h: HostId) {
    let script = "echo \"Connecté à $(hostname) en tant que $(id -un)\"\ncommand -v python3 >/dev/null && echo 'python3 : OK' || echo 'python3 : ABSENT (nécessaire)'\ncommand -v rclone >/dev/null && echo 'rclone : OK' || echo 'rclone : absent'\n".to_string();
    app.action_dialog(h, &tf("Test de connexion — {0}", &[&(h.label())]), script, 30);
}

/// Cle root du Synology (utilisee par copie-omv) autorisee sur l'OMV
fn authorize_syno_to_omv(app: &mut App) {
    let script = "[ -f /root/.ssh/id_copie_omv ] || { mkdir -p /root/.ssh && chmod 700 /root/.ssh && ssh-keygen -t ed25519 -N '' -C \"copie-omv@$(hostname)\" -f /root/.ssh/id_copie_omv -q; }\ncat /root/.ssh/id_copie_omv.pub\n".to_string();
    app.exec(
        HostId::Syno,
        tr("Clé du Synology"),
        script,
        30,
        Box::new(|app, r| match r {
            Ok(o) if o.code == 0 => {
                let key = o.stdout.lines().find(|l| l.starts_with("ssh-")).unwrap_or("").trim().to_string();
                if key.is_empty() {
                    app.toast(false, tr("Clé du Synology illisible.").into());
                    return;
                }
                let s = format!(
                    "umask 077; mkdir -p /root/.ssh; touch /root/.ssh/authorized_keys\nk={}\ngrep -qxF \"$k\" /root/.ssh/authorized_keys || echo \"$k\" >> /root/.ssh/authorized_keys\nchmod 600 /root/.ssh/authorized_keys\necho 'Le Synology peut maintenant écrire sur l OMV (clé autorisée pour root).'\n",
                    crate::ssh::sq(&key)
                );
                app.action_dialog(HostId::Omv, tr("Autorisation sur l'OMV"), s, 30);
                app.refresh(HostId::Syno);
            }
            Ok(o) => app.toast(false, o.text()),
            Err(e) => app.toast(false, e.to_string()),
        }),
    );
}
