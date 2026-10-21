//! Scripts des machines (nas-debian pour OMV / Debian, nas-synology) :
//! version installee, derniere version publiee sur GitHub (versions-scripts.json),
//! bouton unique « Installer / À jour / Mettre à jour », retour a la version precedente.
//!
//! La version integree a l'application sert de secours quand GitHub est injoignable.

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::app::{App, HostId, OutputDialog};
use crate::remote;
use crate::ssh::sq;
use crate::theme::{ERR, IDLE, OK, WARN};
use eframe::egui::{self, RichText};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;

pub const RAW_BASE: &str = "https://raw.githubusercontent.com/cmathias27/scripts_claude/main/";
pub const MANIFEST_FILE: &str = "versions-scripts.json";
/// Manifeste integre (meme contenu que celui du depot au moment de la compilation)
pub const EMBEDDED_MANIFEST: &str = include_str!("../../versions-scripts.json");

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Debian,
    Synology,
}

impl Kind {
    pub fn name(self) -> &'static str {
        match self {
            Kind::Debian => "nas-debian",
            Kind::Synology => "nas-synology",
        }
    }
    pub fn host(self) -> HostId {
        match self {
            Kind::Debian => HostId::Omv,
            Kind::Synology => HostId::Syno,
        }
    }
    pub fn bin(self) -> &'static str {
        match self {
            Kind::Debian => remote::DEBIAN_BIN,
            Kind::Synology => remote::SYNO_BIN,
        }
    }
    pub fn embedded(self) -> &'static str {
        match self {
            Kind::Debian => remote::NAS_DEBIAN_SH,
            Kind::Synology => remote::NAS_SYNOLOGY_SH,
        }
    }
    fn idx(self) -> usize {
        match self {
            Kind::Debian => 0,
            Kind::Synology => 1,
        }
    }
}

#[derive(Deserialize, Clone, Debug, Default)]
#[serde(default)]
pub struct Entry {
    pub version: String,
    pub fichier: String,
    pub sha256: String,
    pub nouveautes: Vec<String>,
}

pub type Manifest = HashMap<String, Entry>;

#[derive(Default)]
pub struct ScriptsState {
    /// manifeste lu sur GitHub
    pub remote: Option<Manifest>,
    pub checking: bool,
    /// derniere erreur de verification (GitHub injoignable...)
    pub error: String,
    pub installing: [bool; 2],
}

/// Version d'un script (ligne SCRIPT_VERSION="x.y.z")
pub fn version_of(script: &str) -> String {
    script
        .lines()
        .find_map(|l| l.strip_prefix("SCRIPT_VERSION=\"").and_then(|v| v.split('"').next()))
        .unwrap_or("")
        .to_string()
}

pub fn embedded_version(k: Kind) -> String {
    version_of(k.embedded())
}

/// Empreinte SHA-256 (fins de ligne Unix, comme a l'installation)
pub fn sha256_hex(content: &str) -> String {
    let mut h = Sha256::new();
    h.update(content.replace("\r\n", "\n").as_bytes());
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

pub fn parse_manifest(txt: &str) -> Result<Manifest, String> {
    serde_json::from_str(txt).map_err(|e| tf("liste des versions illisible : {0}", &[&e]))
}

/// Version installee : None = machine non connectee, Some(None) = script absent
pub fn installed(app: &App, k: Kind) -> Option<Option<String>> {
    match k {
        Kind::Debian => app.omv.status.as_ref().map(|s| s.agent.as_ref().map(|a| a.version.clone())),
        Kind::Synology => app.syno.status.as_ref().map(|s| s.agent.as_ref().map(|a| a.version.clone())),
    }
}

pub fn backup_version(app: &App, k: Kind) -> String {
    match k {
        Kind::Debian => app.omv.status.as_ref().map(|s| s.agent_bak.clone()).unwrap_or_default(),
        Kind::Synology => app.syno.status.as_ref().map(|s| s.agent_bak.clone()).unwrap_or_default(),
    }
}

pub fn migration_needed(app: &App, k: Kind) -> bool {
    match k {
        Kind::Debian => app.omv.status.as_ref().map(|s| s.migration_requise).unwrap_or(false),
        Kind::Synology => app.syno.status.as_ref().map(|s| s.migration_requise).unwrap_or(false),
    }
}

/// Derniere version connue : GitHub si lu, sinon la version integree
pub fn latest(app: &App, k: Kind) -> (String, Vec<String>, bool) {
    if let Some(e) = app.scripts.remote.as_ref().and_then(|m| m.get(k.name())) {
        return (e.version.clone(), e.nouveautes.clone(), true);
    }
    let notes = parse_manifest(EMBEDDED_MANIFEST).ok().and_then(|m| m.get(k.name()).map(|e| e.nouveautes.clone())).unwrap_or_default();
    (embedded_version(k), notes, false)
}

/// Etat du bouton
#[derive(Debug, PartialEq)]
pub enum Button {
    /// machine non connectee
    Unknown,
    Install(String),
    UpToDate(String),
    Update(String, String),
}

pub fn button_state(app: &App, k: Kind) -> Button {
    let (last, _, _) = latest(app, k);
    match installed(app, k) {
        None => Button::Unknown,
        Some(None) => Button::Install(last),
        Some(Some(v)) => {
            if crate::update::is_newer(&last, &v) {
                Button::Update(v, last)
            } else {
                Button::UpToDate(v)
            }
        }
    }
}

// ---------------------------------------------------------------------
//  Verification sur GitHub
// ---------------------------------------------------------------------

fn fetch(url: &str, timeout_s: u32) -> Result<String, String> {
    let out = crate::update::curl()
        .args(["-sSfL", "-m", &timeout_s.to_string(), "-H", "User-Agent: nas-manager", "-H", "Cache-Control: no-cache"])
        .arg(url)
        .output()
        .map_err(|e| tf("curl introuvable : {0}", &[&e]))?;
    if !out.status.success() {
        return Err(tf("GitHub injoignable : {0}", &[&(String::from_utf8_lossy(&out.stderr).trim())]));
    }
    String::from_utf8(out.stdout).map_err(|e| e.to_string())
}

pub fn start_check(app: &mut App, manual: bool) {
    if app.scripts.checking {
        return;
    }
    app.scripts.checking = true;
    let tx = app.tx.clone();
    let ctx = app.ctx.clone();
    std::thread::spawn(move || {
        let r = fetch(&format!("{RAW_BASE}{MANIFEST_FILE}"), 20).and_then(|t| parse_manifest(&t));
        let h: crate::app::Handler = Box::new(move |app: &mut App, _| {
            app.scripts.checking = false;
            app.settings.scripts_last_check = crate::fmt::now();
            app.edit.scripts_last_check = app.settings.scripts_last_check;
            let _ = crate::config::save(&app.settings);
            match r {
                Ok(m) => {
                    app.scripts.error.clear();
                    app.scripts.remote = Some(m);
                    notify_updates(app);
                    if manual {
                        let any = [Kind::Debian, Kind::Synology].iter().any(|k| matches!(button_state(app, *k), Button::Update(..)));
                        app.toast(true, if any { tr("Une mise à jour des scripts est disponible.").into() } else { tr("Scripts : aucune nouvelle version.").into() });
                    }
                }
                Err(e) => {
                    crate::log::warn(&format!("versions des scripts : {e}"));
                    app.scripts.error = e.clone();
                    if manual {
                        app.toast(false, e);
                    }
                }
            }
        });
        let _ = tx.send(crate::app::Msg::Done(h, Err(crate::ssh::SshError::Other(String::new()))));
        ctx.request_repaint();
    });
}

/// Verification automatique (appelee a chaque image) : au demarrage puis toutes les X heures
pub fn auto_check(app: &mut App) {
    if !app.settings.scripts_auto_check || app.scripts.checking {
        return;
    }
    let every = app.settings.scripts_check_hours.clamp(1, 168) as i64 * 3600;
    if crate::fmt::now() - app.settings.scripts_last_check >= every || app.scripts.remote.is_none() && app.settings.scripts_last_check == 0 {
        start_check(app, false);
    }
    // une fois la version installee connue, prevenir d'une mise a jour (une seule fois par version)
    if app.scripts.remote.is_some() {
        notify_updates(app);
    }
}

fn notify_updates(app: &mut App) {
    for k in [Kind::Debian, Kind::Synology] {
        if let Button::Update(from, to) = button_state(app, k) {
            let key = format!("{}={to}", k.name());
            if !app.settings.scripts_notified.split(';').any(|s| s == key) {
                if app.settings.notifications {
                    crate::tray::notify(&app.ctx, &tf("Mise à jour de {0} disponible", &[&(k.name())]), &tf("Version {0} → {1} (page Installation)", &[&from, &to]));
                }
                crate::log::info(&format!("mise à jour disponible : {} {from} -> {to}", k.name()));
                let mut v: Vec<String> = app.settings.scripts_notified.split(';').filter(|s| !s.is_empty() && !s.starts_with(&format!("{}=", k.name()))).map(String::from).collect();
                v.push(key);
                app.settings.scripts_notified = v.join(";");
                app.edit.scripts_notified = app.settings.scripts_notified.clone();
                let _ = crate::config::save(&app.settings);
            }
        }
    }
}

// ---------------------------------------------------------------------
//  Installation
// ---------------------------------------------------------------------

/// Commandes lancees apres l'installation du script
fn post_install(app: &App, k: Kind) -> String {
    let bin = k.bin();
    match k {
        Kind::Debian => format!(
            "{bin} installer\necho\necho '== Outils nécessaires =='\n{bin} outils installer 2>&1 || echo 'Certains outils n ont pas pu être installés (voir ci-dessus).'\n{bin} gen-cron >/dev/null 2>&1 || true\n"
        ),
        Kind::Synology => {
            let mut s = format!("{bin} installer\n");
            let omv = app.settings.omv.host.trim();
            if !omv.is_empty() {
                s.push_str(&format!("{bin} reglages omv {}\n", sq(omv)));
            }
            s.push_str(&format!("echo\necho '== Outils nécessaires =='\n{bin} outils installer 2>&1 || true\n"));
            s
        }
    }
}

/// Installe (ou met a jour) le script : derniere version GitHub si possible, sinon la version integree
pub fn start_install(app: &mut App, k: Kind, force_embedded: bool) {
    if app.blocked() || app.scripts.installing[k.idx()] {
        return;
    }
    let entry = if force_embedded { None } else { app.scripts.remote.as_ref().and_then(|m| m.get(k.name()).cloned()) };
    let post = post_install(app, k);
    let embedded = k.embedded().to_string();
    let emb_ver = embedded_version(k);
    app.scripts.installing[k.idx()] = true;
    let tx = app.tx.clone();
    let ctx = app.ctx.clone();
    std::thread::spawn(move || {
        // contenu a installer + provenance
        let (content, from) = match entry {
            Some(e) if e.version != emb_ver || e.sha256 != sha256_hex(&embedded) => {
                match fetch(&format!("{RAW_BASE}{}", e.fichier), 60) {
                    Ok(c) if sha256_hex(&c) == e.sha256 && version_of(&c) == e.version => (Ok(c), tf("GitHub, version {0}", &[&e.version])),
                    Ok(_) => (Err(tr("le fichier téléchargé ne correspond pas à son empreinte (téléchargement incomplet ou modifié) : installation annulée.").to_string()), String::new()),
                    Err(err) => (Err(err), String::new()),
                }
            }
            _ => (Ok(embedded.clone()), tf("version fournie avec l'application ({0})", &[&emb_ver])),
        };
        let h: crate::app::Handler = Box::new(move |app: &mut App, _| {
            app.scripts.installing[k.idx()] = false;
            match content {
                Ok(c) => {
                    crate::log::info(&format!("installation de {} ({from})", k.name()));
                    let script = format!("echo {}\n", sq(&tf("Installation de {0} : {1}", &[&(k.name()), &from])))
                        + &remote::install_file(k.bin(), &c)
                        + &post;
                    app.action_dialog(k.host(), &tf("Installation de {0}", &[&(k.name())]), script, 1800);
                }
                Err(e) => {
                    crate::log::error(&format!("installation de {} : {e}", k.name()));
                    app.output = Some(OutputDialog { title: tf("Installation de {0}", &[&(k.name())]), text: e, ok: false });
                }
            }
        });
        let _ = tx.send(crate::app::Msg::Done(h, Err(crate::ssh::SshError::Other(String::new()))));
        ctx.request_repaint();
    });
}

/// Retour a la version precedente (.bak), echangee avec la version actuelle
pub fn rollback(app: &mut App, k: Kind) {
    let bin = k.bin();
    let prev = backup_version(app, k);
    let script = format!(
        "set -e\nb={b}\n[ -f \"$b.bak\" ] || {{ echo 'Aucune version précédente gardée.'; exit 1; }}\ncp -p \"$b\" \"$b.recent\"\ncp -p \"$b.bak\" \"$b.new\" && mv -f \"$b.new\" \"$b\"\nmv -f \"$b.recent\" \"$b.bak\"\necho \"Version précédente remise en place : $(grep -m1 '^SCRIPT_VERSION=' \"$b\" | cut -d'\"' -f2)\"\n\"$b\" installer >/dev/null 2>&1 || true\n",
        b = sq(bin)
    );
    app.ask_confirm(
        &tf("Revenir à {0} {1}", &[&(k.name()), &prev]),
        tr("La version actuelle est gardée de côté : tu pourras y revenir de la même façon."),
        tr("Revenir en arrière"),
        false,
        None,
        Box::new(move |app| app.action_dialog(k.host(), &tf("Retour arrière de {0}", &[&(k.name())]), script, 120)),
    );
}

/// Reprise d'une installation faite avec les anciens scripts
pub fn migrate(app: &mut App, k: Kind, apply: bool) {
    let bin = k.bin();
    if !apply {
        app.action_dialog(k.host(), tr("Ce que la migration va changer"), format!("{bin} migrer simulation 2>&1\n"), 60);
        return;
    }
    app.ask_confirm(
        tr("Migrer vers le nouveau script"),
        tr("Les anciens scripts sont remplacés par des liens vers le nouveau (les anciens fichiers sont gardés dans /root/.nas-manager/ancien).\nRéglages, historique et sauvegardes en cours sont conservés."),
        tr("Migrer"),
        false,
        None,
        Box::new(move |app| app.action_dialog(k.host(), tr("Migration"), format!("{bin} migrer appliquer 2>&1\n"), 300)),
    );
}

// ---------------------------------------------------------------------
//  Affichage
// ---------------------------------------------------------------------

/// Ligne « script » avec le bouton dont le libelle suit l'etat
pub fn widget(app: &mut App, ui: &mut egui::Ui, k: Kind) {
    let state = button_state(app, k);
    let (last, notes, from_github) = latest(app, k);
    let busy = app.scripts.installing[k.idx()];
    let bak = backup_version(app, k);
    ui.horizontal_wrapped(|ui| {
        let (col, txt) = match &state {
            Button::Unknown => (IDLE, tr("machine non connectée").to_string()),
            Button::Install(_) => (WARN, tr("non installé").to_string()),
            Button::UpToDate(v) => (OK, tf("version {0}", &[v])),
            Button::Update(v, _) => (WARN, tf("version {0}", &[v])),
        };
        ui.label(RichText::new("●").color(col));
        ui.label(RichText::new(k.name()).strong());
        ui.label(RichText::new(txt).small().weak());
        if busy {
            ui.spinner();
            ui.label(RichText::new(tr("installation…")).small());
            return;
        }
        if app.scripts.checking {
            ui.add_enabled(false, egui::Button::new(tr("Vérification…")));
            return;
        }
        match &state {
            Button::Unknown => {
                ui.add_enabled(false, egui::Button::new(tr("Installer")));
            }
            Button::Install(v) => {
                if ui.button(RichText::new(tf("\u{E08E} Installer (v{0})", &[v])).strong()).clicked() {
                    start_install(app, k, false);
                }
            }
            Button::UpToDate(v) => {
                ui.add_enabled(false, egui::Button::new(tf("\u{E182} À jour (v{0})", &[v])));
                ui.menu_button("⋯", |ui| {
                    if ui.button(tr("Réinstaller")).clicked() {
                        ui.close();
                        start_install(app, k, false);
                    }
                    if !bak.is_empty() && ui.button(tf("Revenir à la version précédente ({0})", &[&bak])).clicked() {
                        ui.close();
                        rollback(app, k);
                    }
                });
            }
            Button::Update(a, b) => {
                let r = ui.add(egui::Button::new(RichText::new(tf("\u{E08E} Mettre à jour v{0} → v{1}", &[a, b])).color(egui::Color32::WHITE)).fill(crate::theme::INFO));
                let r = if notes.is_empty() { r } else { r.on_hover_text(notes.iter().map(|n| format!("• {n}")).collect::<Vec<_>>().join("\n")) };
                if r.clicked() {
                    start_install(app, k, false);
                }
                if !bak.is_empty() {
                    ui.menu_button("⋯", |ui| {
                        if ui.button(tf("Revenir à la version précédente ({0})", &[&bak])).clicked() {
                            ui.close();
                            rollback(app, k);
                        }
                    });
                }
            }
        }
    });
    if let Button::Update(..) = state {
        if !notes.is_empty() {
            egui::CollapsingHeader::new(RichText::new(tf("Nouveautés de la version {0}", &[&last])).small()).id_salt(("notes", k.name())).show(ui, |ui| {
                for n in &notes {
                    ui.label(RichText::new(format!("• {n}")).small());
                }
            });
        }
    }
    if !from_github && !app.scripts.error.is_empty() && !matches!(state, Button::Unknown) {
        ui.label(RichText::new(tf("GitHub injoignable : installation possible avec la version fournie avec l'application ({0}).", &[&(embedded_version(k))])).small().color(WARN));
    }
    if migration_needed(app, k) {
        egui::Frame::new().fill(WARN.gamma_multiply(0.18)).corner_radius(6).inner_margin(8).show(ui, |ui| {
            ui.label(RichText::new(tr("Anciens scripts encore en place : la migration les remplace par le nouveau script (réglages et historique conservés).")).color(WARN));
            ui.horizontal(|ui| {
                if ui.button(tr("Voir ce qui va changer")).clicked() {
                    migrate(app, k, false);
                }
                if ui.button(RichText::new(tr("Migrer")).strong()).clicked() {
                    migrate(app, k, true);
                }
            });
        });
    }
    let _ = ERR;
}

/// Carte « Scripts » : les deux machines + verification
pub fn card(app: &mut App, ui: &mut egui::Ui) {
    widget(app, ui, Kind::Debian);
    if app.settings.syno.is_set() {
        ui.separator();
        widget(app, ui, Kind::Synology);
    }
    ui.separator();
    ui.horizontal_wrapped(|ui| {
        if app.scripts.checking {
            ui.spinner();
        } else if ui.button(tr("\u{E094} Vérifier maintenant")).clicked() {
            start_check(app, true);
        }
        let t = app.settings.scripts_last_check;
        ui.label(RichText::new(if t > 0 { tf("Dernière vérification : {0}", &[&(crate::fmt::ago(t, crate::fmt::now()))]) } else { tr("Pas encore vérifié").to_string() }).small().weak());
    });
    ui.horizontal_wrapped(|ui| {
        let mut a = app.settings.scripts_auto_check;
        if ui.checkbox(&mut a, tr("Vérifier automatiquement toutes les")).changed() {
            app.settings.scripts_auto_check = a;
            app.edit.scripts_auto_check = a;
            let _ = crate::config::save(&app.settings);
        }
        let mut h = app.settings.scripts_check_hours as f32;
        if ui.add_enabled(a, egui::DragValue::new(&mut h).range(1.0..=168.0).speed(0.2)).changed() {
            app.settings.scripts_check_hours = h.round() as u32;
            app.edit.scripts_check_hours = app.settings.scripts_check_hours;
            let _ = crate::config::save(&app.settings);
        }
        ui.label(tr("heures"));
    });
    ui.label(RichText::new(tr("Les scripts sont récupérés sur GitHub (empreinte vérifiée avant installation). Une sauvegarde ou une migration en cours continue avec l'ancienne version, gardée pour revenir en arrière.")).small().weak());
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn manifeste_coherent() {
        // versions-scripts.json doit correspondre aux scripts integres (python3 maj-versions-scripts.py)
        let m = parse_manifest(EMBEDDED_MANIFEST).expect("manifeste");
        for k in [Kind::Debian, Kind::Synology] {
            let e = m.get(k.name()).expect("entree");
            assert_eq!(e.version, embedded_version(k), "{} : version", k.name());
            assert_eq!(e.sha256, sha256_hex(k.embedded()), "{} : empreinte (relancer maj-versions-scripts.py)", k.name());
            assert!(!e.nouveautes.is_empty());
        }
    }
    #[test]
    fn empreinte_lf() {
        assert_eq!(sha256_hex("a\r\nb\n"), sha256_hex("a\nb\n"));
        assert_eq!(version_of("#!/bin/bash\nSCRIPT_VERSION=\"2.1.0\"\n"), "2.1.0");
    }
}
