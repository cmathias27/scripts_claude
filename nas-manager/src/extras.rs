//! Fonctions transverses : identite des NAS (empreinte SSH), nouveautes,
//! rapport de diagnostic, export / import des parametres, raccourcis, theme.

use crate::app::{App, HostId, OutputDialog, Page};
use crate::config;
use crate::remote;
use crate::ssh::HostScan;
use crate::theme::{ERR, INFO, WARN};
use eframe::egui::{self, Color32, RichText};

pub const CHANGELOG: &str = include_str!("../CHANGELOG.md");
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Action a reprendre une fois l'identite du NAS confirmee
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AfterTrust {
    Nothing,
    InstallKey,
}

pub struct Fingerprint {
    pub host: HostId,
    pub scan: Option<HostScan>,
    pub error: String,
    pub then: AfterTrust,
}

// ---------------------------------------------------------------------
//  Empreinte SSH
// ---------------------------------------------------------------------

pub fn start_fingerprint(app: &mut App, host: HostId, then: AfterTrust) {
    if app.fingerprint.as_ref().map(|f| f.host == host).unwrap_or(false) {
        return;
    }
    let cfg = app.host_cfg(host).clone();
    app.fingerprint = Some(Fingerprint { host, scan: None, error: String::new(), then });
    let ssh = app.ssh.clone();
    let tx = app.tx.clone();
    let ctx = app.ctx.clone();
    std::thread::spawn(move || {
        let r = ssh.scan_host(&cfg);
        let h: crate::app::Handler = Box::new(move |app: &mut App, _| {
            if let Some(f) = &mut app.fingerprint {
                if f.host == host {
                    match r {
                        Ok(s) => f.scan = Some(s),
                        Err(e) => f.error = e,
                    }
                }
            }
        });
        let _ = tx.send(crate::app::Msg::Done(h, Err(crate::ssh::SshError::Other(String::new()))));
        ctx.request_repaint();
    });
}

pub fn fingerprint_window(app: &mut App, ctx: &egui::Context) {
    let Some(f) = &app.fingerprint else { return };
    let host = f.host;
    let cfg = app.host_cfg(host).clone();
    let (scan, error, then) = (f.scan.clone(), f.error.clone(), f.then);
    let mut accept = false;
    let mut refuse = false;
    let mut retry = false;
    egui::Window::new(RichText::new(format!("Identité du {} à confirmer", host.label())).strong())
        .id(egui::Id::unique("fingerprint"))
        .collapsible(false)
        .resizable(false)
        .default_width(560.0)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .show(ctx, |ui| {
            ui.label(format!(
                "Première connexion à {} ({}:{}). Pour être sûr de parler au bon appareil, compare l'empreinte ci-dessous avec celle du NAS.",
                host.label(),
                cfg.host.trim(),
                cfg.port
            ));
            ui.add_space(6.0);
            match (&scan, error.is_empty()) {
                (None, true) => {
                    ui.horizontal(|ui| {
                        ui.spinner();
                        ui.label("Lecture de l'identité du NAS…");
                    });
                }
                (None, false) => {
                    ui.colored_label(ERR, &error);
                    if ui.button("Réessayer").clicked() {
                        retry = true;
                    }
                }
                (Some(s), _) => {
                    egui::Frame::new()
                        .fill(ui.visuals().extreme_bg_color)
                        .corner_radius(6.0)
                        .inner_margin(egui::Margin::same(10))
                        .show(ui, |ui| {
                            for fp in &s.fingerprints {
                                ui.label(RichText::new(fp).monospace());
                            }
                        });
                    ui.label(
                        RichText::new("Pour vérifier, sur le NAS : ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub")
                            .small()
                            .weak(),
                    );
                    ui.label(
                        RichText::new("Sur ton réseau local, accepter sans vérifier est en général sans risque. Si cette fenêtre réapparaît plus tard sans raison (pas de réinstallation du NAS), refuse.")
                            .small()
                            .weak(),
                    );
                }
            }
            ui.add_space(8.0);
            ui.horizontal(|ui| {
                if ui
                    .add_enabled(scan.is_some(), egui::Button::new(RichText::new("✔ C'est bien mon NAS").color(Color32::WHITE)).fill(INFO))
                    .clicked()
                {
                    accept = true;
                }
                if ui.button("Refuser").clicked() {
                    refuse = true;
                }
            });
        });
    if retry {
        app.fingerprint = None;
        start_fingerprint(app, host, then);
    } else if accept {
        let scan = scan.unwrap();
        match app.ssh.trust_host(&cfg, &scan) {
            Ok(()) => {
                crate::log::info(&format!("identité confirmée pour {} : {}", cfg.target(), scan.fingerprints.join(", ")));
                app.fingerprint = None;
                app.fp_dismissed[idx(host)] = false;
                match host {
                    HostId::Omv => app.omv.error = None,
                    HostId::Syno => app.syno.error = None,
                }
                app.refresh(host);
                if then == AfterTrust::InstallKey {
                    open_key_console(app, host);
                }
            }
            Err(e) => app.toast(false, e),
        }
    } else if refuse {
        crate::log::warn(&format!("identité refusée pour {}", cfg.target()));
        app.fingerprint = None;
        app.fp_dismissed[idx(host)] = true;
    }
}

pub fn idx(h: HostId) -> usize {
    match h {
        HostId::Omv => 0,
        HostId::Syno => 1,
    }
}

/// « Autoriser la cle » : identite d'abord, puis console de saisie du mot de passe
pub fn authorize_key(app: &mut App, host: HostId) {
    let cfg = app.host_cfg(host).clone();
    if !app.ssh.host_known(&cfg) {
        app.fp_dismissed[idx(host)] = false;
        start_fingerprint(app, host, AfterTrust::InstallKey);
    } else {
        open_key_console(app, host);
    }
}

fn open_key_console(app: &mut App, host: HostId) {
    let cfg = app.host_cfg(host).clone();
    match app.ssh.open_key_install_console(&cfg) {
        Ok(m) => {
            app.output = Some(OutputDialog { title: format!("Autoriser la clé sur le {}", host.label()), text: m, ok: true })
        }
        Err(e) => app.toast(false, e),
    }
}

// ---------------------------------------------------------------------
//  Nouveautes
// ---------------------------------------------------------------------

/// Sections du journal des modifications : (version, texte)
pub fn changelog_sections() -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for line in CHANGELOG.lines() {
        if let Some(v) = line.strip_prefix("## ") {
            out.push((v.trim().to_string(), String::new()));
        } else if let Some((_, body)) = out.last_mut() {
            body.push_str(line);
            body.push('\n');
        }
    }
    out
}

pub fn news_window(app: &mut App, ctx: &egui::Context) {
    // l'identite des NAS passe avant
    if !app.show_news || app.fingerprint.is_some() {
        return;
    }
    let mut open = true;
    egui::Window::new(RichText::new(format!("Nouveautés — NAS Manager {VERSION}")).strong())
        .id(egui::Id::unique("news"))
        .collapsible(false)
        .resizable(true)
        .default_size([620.0, 480.0])
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            egui::ScrollArea::vertical().max_height(420.0).show(ui, |ui| {
                for (i, (v, body)) in changelog_sections().iter().enumerate() {
                    egui::CollapsingHeader::new(RichText::new(v).strong())
                        .default_open(i == 0)
                        .show(ui, |ui| {
                            for l in body.lines() {
                                let t = l.trim();
                                if t.is_empty() {
                                    continue;
                                }
                                if let Some(h) = t.strip_prefix("### ") {
                                    ui.add_space(4.0);
                                    ui.label(RichText::new(h).strong());
                                } else if let Some(item) = t.strip_prefix("- ") {
                                    ui.horizontal_wrapped(|ui| {
                                        ui.label("•");
                                        ui.label(item.replace("**", ""));
                                    });
                                } else {
                                    ui.label(t.replace("**", ""));
                                }
                            }
                        });
                }
            });
        });
    if !open {
        app.show_news = false;
    }
}

// ---------------------------------------------------------------------
//  Rapport de diagnostic
// ---------------------------------------------------------------------

fn ssh_version(app: &App) -> String {
    let mut c = std::process::Command::new(&app.ssh.bin);
    c.arg("-V").stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000);
    }
    match c.output() {
        Ok(o) => format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr)).trim().to_string(),
        Err(e) => format!("introuvable ({e})"),
    }
}

pub fn diagnostic_report(app: &App) -> String {
    let mut r = String::new();
    let now = chrono::Local::now().format("%Y-%m-%d %H:%M:%S");
    r.push_str(&format!("=== Rapport de diagnostic NAS Manager {VERSION} — {now}\n"));
    r.push_str(&format!("Système : {} {}\n", std::env::consts::OS, std::env::consts::ARCH));
    r.push_str(&format!("Client SSH : {}\n", ssh_version(app)));
    r.push_str(&format!("Clé de l'application : {}\n", if app.ssh.key_exists() { "présente" } else { "ABSENTE" }));
    r.push_str(&format!(
        "Mode lecture seule : {} · thème : {} · actualisation : {} s\n",
        if app.settings.read_only { "oui" } else { "non" },
        app.settings.theme,
        app.settings.refresh_secs
    ));
    for h in [HostId::Omv, HostId::Syno] {
        let c = app.host_cfg(h);
        r.push_str(&format!("\n--- {}\n", h.label()));
        if !c.is_set() {
            r.push_str("non configuré\n");
            continue;
        }
        r.push_str(&format!(
            "{}:{} · sudo : {} · mot de passe mémorisé : {}\n",
            c.target(),
            c.port,
            if c.sudo { "oui" } else { "non" },
            if c.saved_pass.is_empty() { "non" } else { "oui" }
        ));
        r.push_str(&format!("Identité confirmée : {}\n", if app.ssh.host_known(c) { "oui" } else { "non" }));
        match app.host_error(h) {
            Some(e) => r.push_str(&format!("État : ERREUR — {e}\n")),
            None if app.host_connected(h) => r.push_str("État : connecté\n"),
            None => r.push_str("État : pas encore connecté\n"),
        }
    }
    if let Some(s) = &app.omv.status {
        r.push_str(&format!(
            "\n--- OMV ({})\nnas-backup : {} (API {}) · sauvegardes : {} · en cours : {} · alertes : {}\n",
            s.serveur,
            if s.nb_installe { "installé" } else { "absent" },
            s.nb_api,
            s.sauvegardes.len(),
            s.sauvegardes.iter().filter(|j| j.en_cours).count(),
            s.alertes.iter().map(|a| a.tag.clone()).collect::<Vec<_>>().join(", ")
        ));
        for j in &s.sauvegardes {
            r.push_str(&format!(
                "  · {} : {} · horaire {} · dernière exécution {}\n",
                j.nom,
                j.dernier_etat.as_deref().unwrap_or("jamais"),
                j.horaire,
                j.derniere_execution.as_deref().unwrap_or("-")
            ));
        }
        r.push_str(&format!(
            "Caméras : installé {} · actif {} · dernier envoi {}\n",
            s.cameras.installe,
            s.cameras.actif,
            s.cameras.dernier_envoi.as_deref().unwrap_or("-")
        ));
    }
    if let Some(s) = &app.syno.status {
        r.push_str(&format!(
            "\n--- Synology ({})\ncopie-omv : {} (API {}) · clé vers l'OMV : {} · copie en cours : {}\nmigre-drive-ocis : {} (API {}) · migration en cours : {} · file : {}\n",
            s.serveur,
            if s.copie.installe { "installé" } else { "absent" },
            s.copie.api,
            s.copie.cle_omv,
            s.copie.en_cours,
            if s.migration.installe { "installé" } else { "absent" },
            s.migration.api,
            s.migration.en_cours,
            s.migration.file.len()
        ));
    }
    r.push_str(&format!("\nScripts fournis : API {}\n", remote::API_VERSION));
    r.push_str("\n=== Journal de l'application (200 dernières lignes)\n");
    r.push_str(&crate::log::tail(200));
    r.push('\n');
    // par prudence : aucun mot de passe ne doit apparaitre
    for p in [&app.omv.pass, &app.syno.pass].into_iter().flatten() {
        if !p.is_empty() {
            r = r.replace(p.as_str(), "********");
        }
    }
    r
}

pub fn export_diagnostic(app: &mut App) {
    let report = diagnostic_report(app);
    let name = format!("nas-manager-diagnostic-{}.txt", chrono::Local::now().format("%Y%m%d-%H%M"));
    if let Some(path) = rfd::FileDialog::new().set_file_name(&name).add_filter("Texte", &["txt"]).save_file() {
        match std::fs::write(&path, report) {
            Ok(()) => app.toast(true, format!("Rapport enregistré : {}", path.display())),
            Err(e) => app.toast(false, format!("Enregistrement impossible : {e}")),
        }
    }
}

pub fn export_settings(app: &mut App) {
    if let Some(path) = rfd::FileDialog::new()
        .set_file_name("nas-manager-parametres.json")
        .add_filter("JSON", &["json"])
        .save_file()
    {
        match std::fs::write(&path, config::export_json(&app.settings)) {
            Ok(()) => app.toast(true, "Paramètres exportés (sans mot de passe).".into()),
            Err(e) => app.toast(false, e.to_string()),
        }
    }
}

pub fn import_settings(app: &mut App) {
    if let Some(path) = rfd::FileDialog::new().add_filter("JSON", &["json"]).pick_file() {
        match std::fs::read_to_string(&path).map_err(|e| e.to_string()).and_then(|t| config::import_json(&t)) {
            Ok(mut s) => {
                s.last_version = app.settings.last_version.clone();
                app.edit = s;
                app.save_settings();
                app.toast(true, "Paramètres importés. Les mots de passe sudo seront redemandés.".into());
            }
            Err(e) => app.toast(false, e),
        }
    }
}

// ---------------------------------------------------------------------
//  Theme et raccourcis
// ---------------------------------------------------------------------

pub fn apply_theme(ctx: &egui::Context, theme: &str) {
    ctx.set_theme(match theme {
        "clair" => egui::ThemePreference::Light,
        "sombre" => egui::ThemePreference::Dark,
        _ => egui::ThemePreference::System,
    });
}

pub fn shortcuts(app: &mut App, ctx: &egui::Context) {
    // pas de raccourci pendant la saisie dans un champ
    if ctx.egui_wants_keyboard_input() {
        return;
    }
    let pages = [
        Page::Dashboard,
        Page::Backups,
        Page::Cameras,
        Page::Alerts,
        Page::Copy,
        Page::Migration,
        Page::Logs,
        Page::Settings,
    ];
    let keys = [
        egui::Key::Num1,
        egui::Key::Num2,
        egui::Key::Num3,
        egui::Key::Num4,
        egui::Key::Num5,
        egui::Key::Num6,
        egui::Key::Num7,
        egui::Key::Num8,
    ];
    ctx.input_mut(|i| {
        if i.consume_key(egui::Modifiers::NONE, egui::Key::F5) {
            app.refresh(HostId::Omv);
            app.refresh(HostId::Syno);
            app.logs.last_fetch = None;
        }
        for (k, p) in keys.iter().zip(pages) {
            if i.consume_key(egui::Modifiers::COMMAND, *k) {
                app.page = p;
            }
        }
    });
}

/// Bandeau « lecture seule »
pub fn read_only_badge(app: &App, ui: &mut egui::Ui) {
    if app.settings.read_only {
        egui::Frame::new()
            .fill(WARN.gamma_multiply(0.2))
            .corner_radius(10.0)
            .inner_margin(egui::Margin::symmetric(8, 2))
            .show(ui, |ui| {
                ui.label(RichText::new("🔒 Lecture seule").small().color(WARN));
            });
    }
}
