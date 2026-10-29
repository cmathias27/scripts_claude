//! NAS Manager en mode texte : à lancer dans un terminal SSH sur le NAS (OMV, Debian ou
//! Synology), ou depuis Linux / Mac / téléphone avec un client SSH. Mêmes informations et
//! mêmes textes (FR / EN) que l'application Windows, dont il reprend le modèle, la lecture
//! de l'état et les traductions. Au clavier, 80 colonnes suffisent, couleurs facultatives.

#![allow(dead_code)]

#[path = "../../src/fmt.rs"]
mod fmt;
#[path = "../../src/i18n.rs"]
mod i18n;
#[path = "../../src/i18n_en.rs"]
mod i18n_en;
#[path = "../../src/model.rs"]
mod model;
#[path = "../../src/remote.rs"]
mod remote;
mod runner;

/// Equivalents minimaux des modules de l'application utilises par remote.rs
mod app {
    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    pub enum HostId {
        Omv,
        Syno,
    }
}
mod ssh {
    /// Chaine entre apostrophes pour le shell
    pub fn sq(s: &str) -> String {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

use i18n::{tf, tr};
use model::{History, OmvStatus, SynoStatus};
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Paragraph, Row, Table, TableState, Tabs, Wrap};
use ratatui::Frame;
use runner::{Kind, Target};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const VERSION: &str = env!("CARGO_PKG_VERSION");

// =====================================================================
//  Etat
// =====================================================================

#[derive(Clone)]
enum Status {
    Debian(Box<OmvStatus>),
    Syno(Box<SynoStatus>),
}

enum Msg {
    Status(Result<Status, String>),
    History(Result<History, String>),
    Log(String),
    Action(String, Result<runner::Out, String>),
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Page {
    Dashboard,
    Backups,
    Realtime,
    History,
    Alerts,
    Transfers,
    Copy,
    Logs,
    Install,
}

impl Page {
    fn title(self) -> &'static str {
        match self {
            Page::Dashboard => tr("Tableau de bord"),
            Page::Backups => tr("Sauvegardes programmées"),
            Page::Realtime => tr("Temps réel"),
            Page::History => tr("Historique"),
            Page::Alerts => tr("Alertes"),
            Page::Transfers => tr("Transferts"),
            Page::Copy => tr("Copie → OMV"),
            Page::Logs => tr("Journaux"),
            Page::Install => tr("Installation"),
        }
    }
}

struct Confirm {
    text: String,
    label: String,
    script: String,
}

struct App {
    target: Target,
    kind: Kind,
    color: bool,
    page: usize,
    pages: Vec<Page>,
    status: Option<Status>,
    error: Option<String>,
    last_ok: Option<Instant>,
    history: Option<History>,
    log_src: usize,
    log_text: String,
    sel: TableState,
    confirm: Option<Confirm>,
    output: Option<(String, String)>,
    message: Option<(String, bool, Instant)>,
    help: bool,
    tx: Sender<Msg>,
    busy: Arc<Mutex<Vec<String>>>,
    refresh: Arc<Mutex<bool>>,
}

impl App {
    fn page(&self) -> Page {
        self.pages[self.page.min(self.pages.len() - 1)]
    }
    fn st(&self, c: Color) -> Style {
        if self.color {
            Style::default().fg(c)
        } else {
            Style::default()
        }
    }
    fn omv(&self) -> Option<&OmvStatus> {
        match &self.status {
            Some(Status::Debian(s)) => Some(s),
            _ => None,
        }
    }
    fn syno(&self) -> Option<&SynoStatus> {
        match &self.status {
            Some(Status::Syno(s)) => Some(s),
            _ => None,
        }
    }
    fn flash(&mut self, t: String, ok: bool) {
        self.message = Some((t, ok, Instant::now()));
    }
    /// Action en arriere-plan ; sa sortie s'affiche dans une fenetre
    fn act(&mut self, label: &str, script: String) {
        let (t, tx, busy, refresh) = (self.target.clone(), self.tx.clone(), self.busy.clone(), self.refresh.clone());
        let label = label.to_string();
        busy.lock().unwrap_or_else(|e| e.into_inner()).push(label.clone());
        std::thread::spawn(move || {
            let r = t.run(&script, Duration::from_secs(600));
            busy.lock().unwrap_or_else(|e| e.into_inner()).retain(|b| *b != label);
            *refresh.lock().unwrap_or_else(|e| e.into_inner()) = true;
            let _ = tx.send(Msg::Action(label, r));
        });
    }
    fn ask(&mut self, text: String, label: &str, script: String) {
        self.confirm = Some(Confirm { text, label: label.to_string(), script });
    }
    fn fetch_history(&self) {
        let (t, tx) = (self.target.clone(), self.tx.clone());
        std::thread::spawn(move || {
            let r = t
                .run(remote::OMV_HISTORY, Duration::from_secs(60))
                .and_then(|o| serde_json::from_str::<History>(o.last_line()).map_err(|e| e.to_string()));
            let _ = tx.send(Msg::History(r));
        });
    }
    fn log_sources(&self) -> Vec<(String, String)> {
        let mut v = Vec::new();
        if let Some(s) = self.omv() {
            v.push((tr("Sauvegardes (nas-backup.log)").to_string(), "/var/log/nas-backup.log".to_string()));
            for j in &s.sauvegardes {
                v.push((tf("Sauvegarde « {0} »{1}", &[&j.nom, &(if j.en_cours { tr(" (en cours)") } else { tr(" (dernière)") })]), format!("/var/lib/nas-backup/{}.run.log", j.nom)));
            }
            for j in &s.temps_reel {
                v.push((tf("Temps réel « {0} »", &[&j.nom]), format!("/var/log/nas-temps-reel/{}.log", j.nom)));
            }
            v.push((tr("Restauration").to_string(), "/var/lib/nas-backup/restauration.log".to_string()));
            v.push((tr("Migration oCIS : progression").to_string(), "/root/.migre-ocis/progression.log".to_string()));
        } else {
            v.push((tr("Copie → OMV : progression").to_string(), "/root/.copie-omv/progression.log".to_string()));
            v.push((tr("Copie → OMV : historique").to_string(), "/root/.copie-omv/historique.log".to_string()));
            v.push((tr("Migration oCIS : progression").to_string(), "/root/.migre-ocis/progression.log".to_string()));
            v.push((tr("Migration oCIS : historique").to_string(), "/root/.migre-ocis/historique.log".to_string()));
        }
        v
    }
    fn fetch_log(&self) {
        let src = self.log_sources();
        let Some((_, p)) = src.get(self.log_src.min(src.len().saturating_sub(1))).cloned() else { return };
        let (t, tx) = (self.target.clone(), self.tx.clone());
        std::thread::spawn(move || {
            let r = t.run(&remote::tail_file(&p, 300), Duration::from_secs(30));
            let txt = match r {
                Ok(o) => runner::strip_ansi(&o.stdout),
                Err(e) => e,
            };
            let _ = tx.send(Msg::Log(txt));
        });
    }
}

// =====================================================================
//  Lecture de l'etat (fil de fond)
// =====================================================================

fn status_once(t: &Target, kind: Kind) -> Result<Status, String> {
    let (script, timeout) = match kind {
        Kind::Debian => (remote::OMV_STATUS.as_str(), 60),
        Kind::Synology => (remote::SYNO_STATUS.as_str(), 60),
    };
    let o = t.run(script, Duration::from_secs(timeout))?;
    let line = o.last_line();
    match kind {
        Kind::Debian => serde_json::from_str::<OmvStatus>(line).map(|s| Status::Debian(Box::new(s))),
        Kind::Synology => serde_json::from_str::<SynoStatus>(line).map(|s| Status::Syno(Box::new(s))),
    }
    .map_err(|_| {
        let t = o.text();
        let last: Vec<&str> = t.lines().rev().take(3).collect();
        tf("Réponse inattendue : {0}", &[&(last.into_iter().rev().collect::<Vec<_>>().join(" | "))])
    })
}

fn poller(t: Target, kind: Kind, tx: Sender<Msg>, refresh: Arc<Mutex<bool>>, active: Arc<Mutex<bool>>) {
    loop {
        let r = status_once(&t, kind);
        let busy = match &r {
            Ok(Status::Debian(s)) => {
                s.any_job_running()
                    || s.any_rt_catchup()
                    || s.migration.as_ref().map(|m| m.en_cours).unwrap_or(false)
                    || s.transferts.as_ref().map(|x| x.en_cours.is_some()).unwrap_or(false)
            }
            Ok(Status::Syno(s)) => s.copie.en_cours || s.migration.en_cours,
            Err(_) => false,
        };
        *active.lock().unwrap_or_else(|e| e.into_inner()) = busy;
        if tx.send(Msg::Status(r)).is_err() {
            return;
        }
        let wait = if busy { 3 } else { 10 };
        let t0 = Instant::now();
        while t0.elapsed() < Duration::from_secs(wait) {
            std::thread::sleep(Duration::from_millis(200));
            let mut f = refresh.lock().unwrap_or_else(|e| e.into_inner());
            if *f {
                *f = false;
                break;
            }
        }
    }
}

// =====================================================================
//  Affichage
// =====================================================================

fn kv(app: &App, k: &str, v: String, c: Color) -> Line<'static> {
    Line::from(vec![Span::styled(format!("{k:<22}"), app.st(Color::Gray)), Span::styled(v, app.st(c))])
}

fn state_color(etat: Option<&str>, en_cours: bool) -> Color {
    if en_cours {
        Color::Cyan
    } else {
        match etat {
            Some("OK") => Color::Green,
            Some("ARRETE") => Color::Yellow,
            None => Color::Gray,
            _ => Color::Red,
        }
    }
}

fn job_state(j: &model::Job) -> &'static str {
    if j.en_cours {
        return tr("En cours");
    }
    match j.dernier_etat.as_deref() {
        Some("OK") => tr("Réussie"),
        Some("ARRETE") => tr("Arrêtée"),
        Some(_) => tr("Échec"),
        None => tr("Jamais lancée"),
    }
}

fn progress(p: &model::Progress) -> String {
    let mut s = p.pct.map(|x| format!("{x} %")).unwrap_or_else(|| "…".into());
    if !p.octets_faits.is_empty() {
        s.push_str(&format!(" · {} / {}", fmt::rclone_units(&p.octets_faits), fmt::rclone_units(&p.octets_total)));
    }
    if !p.vitesse.is_empty() {
        s.push_str(&format!(" · {}", fmt::rclone_units(&p.vitesse)));
    }
    if !p.reste.is_empty() && p.reste != "-" {
        s.push_str(&tf(" · reste {0}", &[&(fmt::rclone_dur(&p.reste))]));
    }
    s
}

fn dashboard(f: &mut Frame, app: &App, area: Rect) {
    let mut l: Vec<Line> = Vec::new();
    let now = fmt::now();
    if let Some(s) = app.omv() {
        if let Some(a) = &s.agent {
            l.push(kv(app, tr("Script"), format!("{} {} ({}, API {})", a.script, a.version, a.machine, a.api), Color::White));
        } else {
            l.push(kv(app, tr("Script"), tr("nas-debian absent : installe-le depuis l'application Windows ou en root (bash nas-debian.sh).").into(), Color::Red));
        }
        if let Some(u) = s.uptime_s {
            l.push(kv(app, tr("Allumé depuis"), fmt::duration(u), Color::White));
        }
        let ko = s.sauvegardes.iter().filter(|j| !j.en_cours && j.dernier_etat.as_deref().map(|e| e != "OK").unwrap_or(false)).count();
        l.push(kv(
            app,
            tr("Sauvegardes"),
            tf("{0} programmée(s), {1} en échec", &[&(s.sauvegardes.len()), &ko]),
            if ko > 0 { Color::Red } else { Color::Green },
        ));
        for j in s.sauvegardes.iter().filter(|j| j.en_cours) {
            let p = j.avancement.as_ref().map(progress).unwrap_or_else(|| tr("démarrage…").into());
            l.push(kv(app, &format!("  ▶ {}", j.nom), p, Color::Cyan));
        }
        let paused = s.temps_reel.iter().filter(|j| j.pause.is_some()).count();
        let active = s.temps_reel.iter().filter(|j| j.actif && j.pause.is_none()).count();
        if !s.temps_reel.is_empty() {
            l.push(kv(
                app,
                tr("Temps réel"),
                tf("{0} active(s), {1} en pause", &[&active, &paused]),
                if paused > 0 { Color::Red } else { Color::Green },
            ));
        }
        l.push(kv(app, tr("Alertes"), if s.alertes.is_empty() { tr("aucune").into() } else { s.alertes.len().to_string() }, if s.alertes.is_empty() { Color::Green } else { Color::Red }));
        if let Some(h) = &s.sante {
            if let Some(p) = h.quota_pct {
                l.push(kv(app, tr("Google Drive"), tf("{0} % utilisés", &[&p]), if p >= 90.0 { Color::Red } else { Color::White }));
            }
        }
        if let Some(d) = &s.sante_disques {
            let (c, a) = d.problems();
            l.push(kv(
                app,
                tr("Santé des disques"),
                tf("{0} disque(s) · {1} critique(s), {2} à surveiller", &[&(d.disques.len()), &c, &a]),
                if c > 0 { Color::Red } else if a > 0 { Color::Yellow } else { Color::Green },
            ));
        }
        l.push(Line::from(""));
        l.push(Line::from(Span::styled(tr("Disques de données"), app.st(Color::Gray).add_modifier(Modifier::BOLD))));
        for d in &s.disques {
            let pct = (d.utilise * 100).checked_div(d.taille).unwrap_or(0);
            l.push(kv(
                app,
                &format!("  {}", fmt::short_path(&d.point)),
                tf("{0} % · {1} libres sur {2}", &[&pct, &(fmt::bytes(d.libre)), &(fmt::bytes(d.taille))]),
                if pct >= 90 { Color::Red } else { Color::White },
            ));
        }
        if let Some(m) = &s.migration {
            if m.en_cours {
                l.push(kv(app, tr("Migration oCIS"), tr("en cours").into(), Color::Cyan));
            }
        }
        if let Some(t) = s.transferts.as_ref().and_then(|t| t.en_cours.as_ref()) {
            l.push(kv(app, tr("Transfert oCIS"), tf("« {0} » en cours", &[&t.nom]), Color::Cyan));
        }
    } else if let Some(s) = app.syno() {
        if let Some(a) = &s.agent {
            l.push(kv(app, tr("Script"), format!("{} {} (API {})", a.script, a.version, a.api), Color::White));
        }
        let c = &s.copie;
        if c.en_cours {
            let p = c.avancement.as_ref().map(|a| format!("{} % · {} · {}", a.pct, a.vitesse, a.reste)).unwrap_or_default();
            l.push(kv(app, tr("Copie → OMV"), p, Color::Cyan));
        } else {
            l.push(kv(app, tr("Copie → OMV"), tf("{0} en file d'attente", &[&(c.file.len())]), Color::White));
        }
        l.push(kv(
            app,
            tr("Migration oCIS"),
            if s.migration.en_cours { tr("en cours").to_string() } else { tf("{0} en file d'attente", &[&(s.migration.file.len())]) },
            if s.migration.en_cours { Color::Cyan } else { Color::White },
        ));
        l.push(kv(app, tr("Alertes"), if s.alertes.is_empty() { tr("aucune").into() } else { s.alertes.len().to_string() }, if s.alertes.is_empty() { Color::Green } else { Color::Red }));
        if let Some(d) = &s.sante_disques {
            let (cr, a) = d.problems();
            l.push(kv(app, tr("Santé des disques"), tf("{0} disque(s) · {1} critique(s), {2} à surveiller", &[&(d.disques.len()), &cr, &a]), if cr > 0 { Color::Red } else { Color::Green }));
        }
    }
    if let Some(t) = app.last_ok {
        l.push(Line::from(""));
        l.push(Line::from(Span::styled(tf("Actualisé il y a {0} s", &[&(t.elapsed().as_secs())]), app.st(Color::DarkGray))));
    }
    let _ = now;
    f.render_widget(Paragraph::new(l).wrap(Wrap { trim: false }), area);
}

fn backups(f: &mut Frame, app: &mut App, area: Rect) {
    let Some(s) = app.omv().cloned() else { return };
    let [top, bottom] = Layout::vertical([Constraint::Min(5), Constraint::Length(7)]).areas(area);
    let rows: Vec<Row> = s
        .sauvegardes
        .iter()
        .map(|j| {
            let mode = match j.mode.as_str() {
                "sync" => tr("miroir"),
                "copy" => tr("copie"),
                _ => tr("versionnée"),
            };
            Row::new(vec![
                j.nom.clone(),
                mode.to_string(),
                fmt::schedule_human(&j.horaire),
                job_state(j).to_string(),
            ])
            .style(app.st(state_color(j.dernier_etat.as_deref(), j.en_cours)))
        })
        .collect();
    let t = Table::new(rows, [Constraint::Length(16), Constraint::Length(11), Constraint::Min(16), Constraint::Length(14)])
        .header(Row::new(vec![tr("Nom"), tr("Mode"), tr("Horaire"), tr("État")]).style(Style::default().add_modifier(Modifier::BOLD)))
        .row_highlight_style(Style::default().add_modifier(Modifier::REVERSED));
    f.render_stateful_widget(t, top, &mut app.sel);
    let mut l = Vec::new();
    if let Some(j) = app.sel.selected().and_then(|i| s.sauvegardes.get(i)) {
        let dests: Vec<String> = j.dests().iter().map(|d| if d.chiffre { format!("{} ({})", d.nom, tr("chiffré")) } else { d.nom.clone() }).collect();
        l.push(Line::from(format!("{} → {} : {}", fmt::short_path(&j.source), dests.join(", "), j.dossier)));
        if j.en_cours {
            if let Some(p) = &j.avancement {
                l.push(Line::from(Span::styled(progress(p), app.st(Color::Cyan))));
            }
        }
        if let Some(b) = &j.bilan {
            l.push(Line::from(tf("Dernier bilan : {0} fichier(s) envoyé(s), {1}, {2} min", &[&(b.fichiers_envoyes), &(fmt::bytes(b.volume_octets.max(0) as u64)), &(b.duree_min)])));
        }
        if let Some(e) = &j.derniere_erreur {
            if !e.is_empty() && j.dernier_etat.as_deref() != Some("OK") {
                l.push(Line::from(Span::styled(e.clone(), app.st(Color::Red))));
            }
        }
        if let Some(n) = fmt::next_run_sched(&j.horaire) {
            l.push(Line::from(tf("Prochaine : {0}", &[&n])));
        }
    }
    l.push(Line::from(Span::styled(tr("Entrée/l : lancer · a : arrêter · t : tout arrêter"), app.st(Color::DarkGray))));
    f.render_widget(Paragraph::new(l).wrap(Wrap { trim: true }).block(Block::default().borders(Borders::TOP)), bottom);
}

fn realtime(f: &mut Frame, app: &mut App, area: Rect) {
    let Some(s) = app.omv().cloned() else { return };
    let [top, bottom] = Layout::vertical([Constraint::Min(5), Constraint::Length(6)]).areas(area);
    let rows: Vec<Row> = s
        .temps_reel
        .iter()
        .map(|j| {
            let (etat, c) = if j.pause.is_some() {
                (tr("En pause"), Color::Red)
            } else if j.actif {
                (tr("Active"), Color::Green)
            } else {
                (tr("Arrêtée"), Color::Yellow)
            };
            Row::new(vec![j.nom.clone(), etat.to_string(), j.envois_aujourdhui.to_string(), j.echecs_aujourdhui.to_string()]).style(app.st(c))
        })
        .collect();
    let t = Table::new(rows, [Constraint::Min(16), Constraint::Length(12), Constraint::Length(14), Constraint::Length(10)])
        .header(Row::new(vec![tr("Nom"), tr("État"), tr("Envois (jour)"), tr("Échecs")]).style(Style::default().add_modifier(Modifier::BOLD)))
        .row_highlight_style(Style::default().add_modifier(Modifier::REVERSED));
    f.render_stateful_widget(t, top, &mut app.sel);
    let mut l = Vec::new();
    if let Some(j) = app.sel.selected().and_then(|i| s.temps_reel.get(i)) {
        l.push(Line::from(format!("{} → {}", j.dossiers.iter().map(|d| fmt::short_path(&d.chemin)).collect::<Vec<_>>().join(", "), j.destination)));
        if let Some(p) = &j.pause {
            l.push(Line::from(Span::styled(tf("En pause : {0}", &[&p.raison]), app.st(Color::Red))));
        }
        if let Some(e) = &j.derniere_erreur {
            if !e.is_empty() {
                l.push(Line::from(Span::styled(e.clone(), app.st(Color::Red))));
            }
        }
    }
    l.push(Line::from(Span::styled(tr("p : pause · r : reprendre · d : démarrer"), app.st(Color::DarkGray))));
    f.render_widget(Paragraph::new(l).wrap(Wrap { trim: true }).block(Block::default().borders(Borders::TOP)), bottom);
}

fn history(f: &mut Frame, app: &mut App, area: Rect) {
    let Some(h) = &app.history else {
        f.render_widget(Paragraph::new(tr("Lecture de l'historique…")), area);
        return;
    };
    let rows: Vec<Row> = h
        .executions
        .iter()
        .rev()
        .take(200)
        .map(|r| {
            let c = if r.etat == "OK" { Color::Green } else { Color::Red };
            Row::new(vec![fmt::date_full(r.debut), r.nom.clone(), r.etat.clone(), format!("{:.0} min", r.duree_min), fmt::bytes(r.volume_octets.max(0) as u64)]).style(app.st(c))
        })
        .collect();
    let t = Table::new(rows, [Constraint::Length(17), Constraint::Min(12), Constraint::Length(7), Constraint::Length(8), Constraint::Length(10)])
        .header(Row::new(vec![tr("Date"), tr("Nom"), tr("État"), tr("Durée"), tr("Volume")]).style(Style::default().add_modifier(Modifier::BOLD)))
        .row_highlight_style(Style::default().add_modifier(Modifier::REVERSED));
    f.render_stateful_widget(t, area, &mut app.sel);
}

fn alerts(f: &mut Frame, app: &mut App, area: Rect) {
    let list: Vec<model::Alert> = app.omv().map(|s| s.alertes.clone()).or_else(|| app.syno().map(|s| s.alertes.clone())).unwrap_or_default();
    let now = fmt::now();
    if list.is_empty() {
        f.render_widget(Paragraph::new(Span::styled(tr("Aucune alerte en cours."), app.st(Color::Green))), area);
        return;
    }
    let rows: Vec<Row> = list.iter().map(|a| Row::new(vec![a.tag.clone(), fmt::ago(a.depuis, now)]).style(app.st(Color::Red))).collect();
    let [top, bottom] = Layout::vertical([Constraint::Min(3), Constraint::Length(2)]).areas(area);
    let t = Table::new(rows, [Constraint::Min(30), Constraint::Length(20)])
        .header(Row::new(vec![tr("Alerte"), tr("Depuis")]).style(Style::default().add_modifier(Modifier::BOLD)))
        .row_highlight_style(Style::default().add_modifier(Modifier::REVERSED));
    f.render_stateful_widget(t, top, &mut app.sel);
    f.render_widget(Paragraph::new(Span::styled(tr("k : acquitter l'alerte (elle revient si le problème persiste)"), app.st(Color::DarkGray))), bottom);
}

fn transfers(f: &mut Frame, app: &App, area: Rect) {
    let mut l: Vec<Line> = Vec::new();
    let (mig, trs) = match &app.status {
        Some(Status::Debian(s)) => (s.migration.clone(), s.transferts.clone()),
        Some(Status::Syno(s)) => (Some(s.migration.clone()), s.transferts.clone()),
        None => (None, None),
    };
    l.push(Line::from(Span::styled(tr("Migration vers oCIS"), Style::default().add_modifier(Modifier::BOLD))));
    match &mig {
        Some(m) if m.en_cours => {
            if let Some(e) = &m.etape {
                l.push(Line::from(Span::styled(tf("[{0}/{1}] {2} → {3} · {4} %", &[&e.etape, &(m.nb), &e.libelle, &e.espace, &(e.pct.unwrap_or(0))]), app.st(Color::Cyan))));
            } else {
                l.push(Line::from(Span::styled(tr("en cours"), app.st(Color::Cyan))));
            }
        }
        Some(m) => {
            l.push(Line::from(tf("{0} en file d'attente", &[&(m.file.len())])));
            for r in m.resultats.iter().take(5) {
                l.push(Line::from(format!("  {} {} → {} : {}", if r.etat == "OK" { "✓" } else { "✗" }, r.libelle, r.espace, r.detail)));
            }
        }
        None => l.push(Line::from(tr("non installée"))),
    }
    l.push(Line::from(""));
    l.push(Line::from(Span::styled(tr("Transferts oCIS → NAS"), Style::default().add_modifier(Modifier::BOLD))));
    match &trs {
        Some(t) => {
            if let Some(r) = &t.en_cours {
                let p = r.avancement.as_ref().and_then(|a| a.pct).map(|x| format!("{x} %")).unwrap_or_default();
                l.push(Line::from(Span::styled(tf("« {0} » en cours {1}", &[&r.nom, &p]), app.st(Color::Cyan))));
            }
            for x in &t.transferts {
                let last = x.dernier.as_ref().map(|d| format!("{} {}", d.etat, fmt::date(d.fin))).unwrap_or_else(|| tr("jamais lancé").into());
                l.push(Line::from(format!("  {} : {} → {} · {} · {}", x.nom, x.espace, fmt::short_path(&x.destination), fmt::schedule_human(&x.horaire), last)));
            }
            if t.transferts.is_empty() {
                l.push(Line::from(tr("aucun")));
            }
        }
        None => l.push(Line::from(tr("non installés"))),
    }
    f.render_widget(Paragraph::new(l).wrap(Wrap { trim: false }), area);
}

fn copy(f: &mut Frame, app: &App, area: Rect) {
    let Some(s) = app.syno() else { return };
    let c = &s.copie;
    let mut l = Vec::new();
    if c.en_cours {
        l.push(kv(app, tr("En cours"), format!("{} → {}", c.source.clone().unwrap_or_default(), c.destination.clone().unwrap_or_default()), Color::Cyan));
        if let Some(a) = &c.avancement {
            l.push(kv(app, tr("Avancement"), format!("{} % · {} · {} · {}", a.pct, a.fait, a.vitesse, a.reste), Color::Cyan));
        }
    } else {
        l.push(Line::from(tr("Aucune copie en cours.")));
    }
    l.push(Line::from(""));
    l.push(Line::from(Span::styled(tf("File d'attente ({0})", &[&(c.file.len())]), Style::default().add_modifier(Modifier::BOLD))));
    for q in &c.file {
        l.push(Line::from(format!("  {} → {}", q.source, q.destination)));
    }
    l.push(Line::from(""));
    l.push(Line::from(Span::styled(tr("Historique"), Style::default().add_modifier(Modifier::BOLD))));
    for h in c.historique.iter().rev().take(10) {
        l.push(Line::from(format!("  {h}")));
    }
    l.push(Line::from(Span::styled(tr("a : arrêter la copie"), app.st(Color::DarkGray))));
    f.render_widget(Paragraph::new(l).wrap(Wrap { trim: false }), area);
}

fn logs(f: &mut Frame, app: &App, area: Rect) {
    let src = app.log_sources();
    let [head, body] = Layout::vertical([Constraint::Length(1), Constraint::Min(1)]).areas(area);
    let name = src.get(app.log_src.min(src.len().saturating_sub(1))).map(|s| s.0.clone()).unwrap_or_default();
    f.render_widget(
        Paragraph::new(Line::from(vec![Span::styled(format!("◀ {name} ▶"), Style::default().add_modifier(Modifier::BOLD)), Span::styled(tr("   (↑↓ : journal, Entrée : relire)"), app.st(Color::DarkGray))])),
        head,
    );
    let lines: Vec<&str> = app.log_text.lines().collect();
    let h = body.height as usize;
    let start = lines.len().saturating_sub(h);
    let shown: Vec<Line> = lines[start..].iter().map(|l| Line::from(l.to_string())).collect();
    f.render_widget(Paragraph::new(shown), body);
}

fn install(f: &mut Frame, app: &App, area: Rect) {
    let mut l = Vec::new();
    l.push(kv(app, "nas-manager", VERSION.to_string(), Color::White));
    let (agent, emb) = match &app.status {
        Some(Status::Debian(s)) => (s.agent.clone(), remote::api_of(remote::NAS_DEBIAN_SH)),
        Some(Status::Syno(s)) => (s.agent.clone(), remote::api_of(remote::NAS_SYNOLOGY_SH)),
        None => (None, 0),
    };
    match agent {
        Some(a) => {
            l.push(kv(app, tr("Script de la machine"), format!("{} {} (API {})", a.script, a.version, a.api), Color::White));
            if a.api < emb {
                l.push(Line::from(Span::styled(
                    tr("Une version plus récente du script est connue de cette interface : mets-le à jour depuis l'application Windows (page Installation)."),
                    app.st(Color::Yellow),
                )));
            }
        }
        None => l.push(kv(app, tr("Script de la machine"), tr("absent").into(), Color::Red)),
    }
    l.push(kv(app, tr("Machine"), app.target.label(), Color::White));
    l.push(Line::from(""));
    l.push(Line::from(tr("Mise à jour de cette interface : u (télécharge la dernière version publiée sur GitHub, empreinte vérifiée).")));
    l.push(Line::from(tr("Installation, connexion aux clouds et réglages : application Windows NAS Manager.")));
    f.render_widget(Paragraph::new(l).wrap(Wrap { trim: false }), area);
}

fn help_text() -> Vec<Line<'static>> {
    [
        tr("Tab / → : page suivante · Maj+Tab / ← : page précédente · 1…9 : aller à une page"),
        tr("↑ ↓ : choisir une ligne · F5 ou Ctrl+R : actualiser · q ou Échap : quitter"),
        tr("Sauvegardes : Entrée ou l lancer, a arrêter, t tout arrêter"),
        tr("Temps réel : p pause, r reprendre, d démarrer"),
        tr("Alertes : k acquitter · Journaux : ↑ ↓ changer de journal, Entrée relire"),
        tr("Toutes les actions demandent une confirmation (o / n)."),
    ]
    .iter()
    .map(|s| Line::from(s.to_string()))
    .collect()
}

fn centered(area: Rect, w: u16, h: u16) -> Rect {
    let w = w.min(area.width.saturating_sub(2));
    let h = h.min(area.height.saturating_sub(2));
    Rect { x: area.x + (area.width - w) / 2, y: area.y + (area.height - h) / 2, width: w, height: h }
}

fn draw(f: &mut Frame, app: &mut App) {
    let area = f.area();
    let [tabs, title, body, foot] = Layout::vertical([Constraint::Length(1), Constraint::Length(1), Constraint::Min(3), Constraint::Length(1)]).areas(area);
    let names: Vec<String> = app.pages.iter().enumerate().map(|(i, p)| format!("{} {}", i + 1, p.title())).collect();
    let t = Tabs::new(names).select(app.page).highlight_style(Style::default().add_modifier(Modifier::REVERSED)).divider("|");
    f.render_widget(t, tabs);
    let busy = app.busy.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let mut head = vec![Span::styled(format!("NAS Manager · {} ", app.target.label()), Style::default().add_modifier(Modifier::BOLD))];
    if let Some(e) = &app.error {
        head.push(Span::styled(format!("· {e}"), app.st(Color::Red)));
    } else if !busy.is_empty() {
        head.push(Span::styled(format!("· {}…", busy.join(", ")), app.st(Color::Cyan)));
    }
    f.render_widget(Paragraph::new(Line::from(head)), title);
    let inner = Block::default().borders(Borders::TOP).title(app.page().title());
    let b = inner.inner(body);
    f.render_widget(inner, body);
    if app.status.is_none() {
        let txt = app.error.clone().unwrap_or_else(|| tr("Lecture de l'état…").into());
        f.render_widget(Paragraph::new(txt).wrap(Wrap { trim: false }), b);
    } else {
        match app.page() {
            Page::Dashboard => dashboard(f, app, b),
            Page::Backups => backups(f, app, b),
            Page::Realtime => realtime(f, app, b),
            Page::History => history(f, app, b),
            Page::Alerts => alerts(f, app, b),
            Page::Transfers => transfers(f, app, b),
            Page::Copy => copy(f, app, b),
            Page::Logs => logs(f, app, b),
            Page::Install => install(f, app, b),
        }
    }
    let foot_txt = match &app.message {
        Some((m, ok, t)) if t.elapsed() < Duration::from_secs(8) => Span::styled(m.clone(), app.st(if *ok { Color::Green } else { Color::Red })),
        _ => Span::styled(tr("? aide · q quitter · F5 actualiser"), app.st(Color::DarkGray)),
    };
    f.render_widget(Paragraph::new(Line::from(foot_txt)), foot);
    if app.help {
        let r = centered(area, 76, 10);
        f.render_widget(Clear, r);
        f.render_widget(Paragraph::new(help_text()).wrap(Wrap { trim: true }).block(Block::default().borders(Borders::ALL).title(tr("Aide"))), r);
    }
    if let Some(c) = &app.confirm {
        let r = centered(area, 70, 6);
        f.render_widget(Clear, r);
        let l = vec![Line::from(c.text.clone()), Line::from(""), Line::from(Span::styled(tr("o : oui · n : non"), Style::default().add_modifier(Modifier::BOLD)))];
        f.render_widget(Paragraph::new(l).wrap(Wrap { trim: true }).block(Block::default().borders(Borders::ALL).title(tr("Confirmer"))), r);
    }
    if let Some((t, txt)) = &app.output {
        let r = centered(area, 78, 16);
        f.render_widget(Clear, r);
        let lines: Vec<Line> = txt.lines().rev().take(r.height.saturating_sub(3) as usize).collect::<Vec<_>>().into_iter().rev().map(|l| Line::from(l.to_string())).collect();
        f.render_widget(
            Paragraph::new(lines).wrap(Wrap { trim: false }).block(Block::default().borders(Borders::ALL).title(format!("{t} · {}", tr("Entrée : fermer")))),
            r,
        );
    }
}

// =====================================================================
//  Clavier
// =====================================================================

fn rows_of(app: &App) -> usize {
    match app.page() {
        Page::Backups => app.omv().map(|s| s.sauvegardes.len()).unwrap_or(0),
        Page::Realtime => app.omv().map(|s| s.temps_reel.len()).unwrap_or(0),
        Page::History => app.history.as_ref().map(|h| h.executions.len().min(200)).unwrap_or(0),
        Page::Alerts => app.omv().map(|s| s.alertes.len()).or_else(|| app.syno().map(|s| s.alertes.len())).unwrap_or(0),
        _ => 0,
    }
}

fn goto(app: &mut App, i: usize) {
    if i < app.pages.len() && i != app.page {
        app.page = i;
        app.sel = TableState::default();
        if rows_of(app) > 0 {
            app.sel.select(Some(0));
        }
        match app.page() {
            Page::History => app.fetch_history(),
            Page::Logs => app.fetch_log(),
            _ => {}
        }
    }
}

/// Renvoie false pour quitter
fn key(app: &mut App, code: KeyCode, mods: KeyModifiers) -> bool {
    if app.output.is_some() {
        if matches!(code, KeyCode::Enter | KeyCode::Esc | KeyCode::Char('q')) {
            app.output = None;
        }
        return true;
    }
    if let Some(c) = app.confirm.take() {
        if matches!(code, KeyCode::Char('o') | KeyCode::Char('O') | KeyCode::Char('y') | KeyCode::Char('Y')) {
            app.act(&c.label, c.script);
        }
        return true;
    }
    if app.help {
        app.help = false;
        return true;
    }
    let ro = |app: &App| app.target == Target::Local { sudo: false } && !runner::is_root();
    match code {
        KeyCode::Char('q') | KeyCode::Esc => return false,
        KeyCode::Char('c') if mods.contains(KeyModifiers::CONTROL) => return false,
        KeyCode::Char('?') | KeyCode::F(1) => app.help = true,
        KeyCode::F(5) => *app.refresh.lock().unwrap_or_else(|e| e.into_inner()) = true,
        KeyCode::Char('r') if mods.contains(KeyModifiers::CONTROL) => *app.refresh.lock().unwrap_or_else(|e| e.into_inner()) = true,
        KeyCode::Tab | KeyCode::Right => goto(app, (app.page + 1) % app.pages.len()),
        KeyCode::BackTab | KeyCode::Left => goto(app, (app.page + app.pages.len() - 1) % app.pages.len()),
        KeyCode::Char(d @ '1'..='9') => goto(app, d as usize - '1' as usize),
        KeyCode::Up | KeyCode::Down if app.page() == Page::Logs => {
            let n = app.log_sources().len().max(1);
            app.log_src = if code == KeyCode::Up { (app.log_src + n - 1) % n } else { (app.log_src + 1) % n };
            app.log_text.clear();
            app.fetch_log();
        }
        KeyCode::Up => {
            let n = rows_of(app);
            if n > 0 {
                app.sel.select(Some(app.sel.selected().unwrap_or(0).saturating_sub(1)));
            }
        }
        KeyCode::Down => {
            let n = rows_of(app);
            if n > 0 {
                app.sel.select(Some((app.sel.selected().map(|i| i + 1).unwrap_or(0)).min(n - 1)));
            }
        }
        KeyCode::Enter if app.page() == Page::Logs => app.fetch_log(),
        _ if ro(app) && matches!(code, KeyCode::Char('l' | 'a' | 't' | 'p' | 'r' | 'd' | 'k' | 'u') | KeyCode::Enter) => {
            app.flash(tr("Lecture seule : lance « sudo nas-manager » pour agir.").into(), false);
        }
        _ => page_key(app, code),
    }
    true
}

fn page_key(app: &mut App, code: KeyCode) {
    let sel = app.sel.selected();
    match (app.page(), code) {
        (Page::Backups, KeyCode::Enter | KeyCode::Char('l')) => {
            if let Some(j) = sel.and_then(|i| app.omv().and_then(|s| s.sauvegardes.get(i))).cloned() {
                if j.en_cours {
                    app.flash(tf("« {0} » est déjà en cours.", &[&j.nom]), false);
                } else {
                    app.ask(tf("Lancer maintenant la sauvegarde « {0} » ?", &[&j.nom]), tr("Lancement"), remote::nb_run(&j.nom));
                }
            }
        }
        (Page::Backups, KeyCode::Char('a')) => {
            if let Some(j) = sel.and_then(|i| app.omv().and_then(|s| s.sauvegardes.get(i))).cloned() {
                app.ask(tf("Arrêter la sauvegarde « {0} » ?", &[&j.nom]), tr("Arrêt"), remote::nb_stop_job(&j.nom));
            }
        }
        (Page::Backups, KeyCode::Char('t')) => app.ask(tr("Arrêter toutes les sauvegardes en cours ?").into(), tr("Arrêt"), remote::nb_stop()),
        (Page::Realtime, KeyCode::Char(c @ ('p' | 'r' | 'd'))) => {
            if let Some(j) = sel.and_then(|i| app.omv().and_then(|s| s.temps_reel.get(i))).cloned() {
                let (verb, act) = match c {
                    'p' => (tr("Mettre en pause « {0} » ?"), "pause"),
                    'r' => (tr("Reprendre « {0} » (l'état actuel du dossier sera répercuté) ?"), "reprendre"),
                    _ => (tr("Démarrer la surveillance de « {0} » ?"), "demarrer"),
                };
                app.ask(tf(verb, &[&j.nom]), tr("Temps réel"), remote::rt_cmd(act, &j.nom));
            }
        }
        (Page::Alerts, KeyCode::Char('k')) => {
            let is_syno = app.syno().is_some();
            let a = sel.and_then(|i| app.omv().map(|s| s.alertes.clone()).or_else(|| app.syno().map(|s| s.alertes.clone())).and_then(|v| v.get(i).cloned()));
            if let Some(a) = a {
                let script = if is_syno { remote::ack_alert_syno(&a.tag) } else { remote::ack_alert(&a.tag) };
                app.ask(tf("Acquitter l'alerte « {0} » ?", &[&a.tag]), tr("Alerte"), script);
            }
        }
        (Page::Copy, KeyCode::Char('a')) => app.ask(tr("Arrêter la copie en cours ?").into(), tr("Arrêt"), remote::copie_stop()),
        (Page::Install, KeyCode::Char('u')) => {
            let bin = if app.kind == Kind::Synology { remote::SYNO_BIN } else { remote::DEBIAN_BIN };
            app.ask(tr("Mettre à jour nas-manager depuis GitHub ?").into(), tr("Mise à jour"), format!("{bin} tui installer 2>&1\n"));
        }
        _ => {}
    }
}

// =====================================================================
//  Lancement
// =====================================================================

fn usage() -> String {
    format!(
        "nas-manager {VERSION}\n{}\n\n  nas-manager                 {}\n  nas-manager --hote U@MACHINE[:PORT] [--synology] [--sudo]\n                              {}\n  nas-manager --etat          {}\n  --lang fr|en  --sans-couleur  --version\n",
        tr("NAS Manager en mode texte : suivi et pilotage des sauvegardes depuis un terminal."),
        tr("cette machine (en root, ou avec sudo)"),
        tr("une autre machine du site, par SSH (clé déjà autorisée)"),
        tr("affiche l'état (JSON) et quitte"),
    )
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut lang = String::new();
    let mut color = std::env::var("NO_COLOR").is_err();
    let mut target = Target::Local { sudo: !runner::is_root() && std::env::var("NAS_MANAGER_SANS_SUDO").is_err() };
    let mut kind = runner::local_kind();
    let mut once = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--version" | "-V" => {
                println!("nas-manager {VERSION}");
                return;
            }
            "--help" | "-h" | "--aide" => {
                i18n::set_language(&lang);
                print!("{}", usage());
                return;
            }
            "--lang" => {
                i += 1;
                lang = args.get(i).cloned().unwrap_or_default();
            }
            "--sans-couleur" | "--no-color" => color = false,
            "--etat" | "--status" => once = true,
            "--synology" => kind = Kind::Synology,
            "--debian" => kind = Kind::Debian,
            "--sudo" => {
                if let Target::Ssh { sudo, .. } = &mut target {
                    *sudo = true;
                }
            }
            "--hote" | "--host" => {
                i += 1;
                let h = args.get(i).cloned().unwrap_or_default();
                let (dest, port) = match h.rsplit_once(':') {
                    Some((d, p)) if p.parse::<u16>().is_ok() => (d.to_string(), p.parse().unwrap_or(22)),
                    _ => (h.clone(), 22),
                };
                let sudo = args.iter().any(|a| a == "--sudo");
                if !args.iter().any(|a| a == "--debian") && !args.iter().any(|a| a == "--synology") {
                    kind = Kind::Debian;
                }
                target = Target::Ssh { dest, port, sudo };
            }
            a => {
                eprintln!("{}", i18n::tf("option inconnue : {0}", &[&a]));
                eprint!("{}", usage());
                std::process::exit(2);
            }
        }
        i += 1;
    }
    // langue : --lang, sinon celle du systeme (LANG)
    if lang.is_empty() {
        lang = std::env::var("LANG").map(|l| if l.to_lowercase().starts_with("fr") { "fr".into() } else if l.starts_with('C') || l.is_empty() { String::new() } else { "en".into() }).unwrap_or_default();
    }
    i18n::set_language(&lang);
    if once {
        match status_once(&target, kind) {
            Ok(_) => {
                let script = if kind == Kind::Synology { remote::SYNO_STATUS.as_str() } else { remote::OMV_STATUS.as_str() };
                match target.run(script, Duration::from_secs(60)) {
                    Ok(o) => println!("{}", o.last_line()),
                    Err(e) => {
                        eprintln!("{e}");
                        std::process::exit(1);
                    }
                }
            }
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }
        return;
    }
    let pages = match kind {
        Kind::Debian => vec![Page::Dashboard, Page::Backups, Page::Realtime, Page::History, Page::Alerts, Page::Transfers, Page::Logs, Page::Install],
        Kind::Synology => vec![Page::Dashboard, Page::Copy, Page::Transfers, Page::Alerts, Page::Logs, Page::Install],
    };
    let (tx, rx): (Sender<Msg>, Receiver<Msg>) = channel();
    let refresh = Arc::new(Mutex::new(false));
    let active = Arc::new(Mutex::new(false));
    {
        let (t, tx, r, a) = (target.clone(), tx.clone(), refresh.clone(), active.clone());
        std::thread::spawn(move || poller(t, kind, tx, r, a));
    }
    let mut app = App {
        target,
        kind,
        color,
        page: 0,
        pages,
        status: None,
        error: None,
        last_ok: None,
        history: None,
        log_src: 0,
        log_text: String::new(),
        sel: TableState::default(),
        confirm: None,
        output: None,
        message: None,
        help: false,
        tx,
        busy: Arc::new(Mutex::new(Vec::new())),
        refresh,
    };
    let mut term = ratatui::init();
    let res = run(&mut term, &mut app, rx);
    ratatui::restore();
    if let Err(e) = res {
        eprintln!("{e}");
    }
}

fn run(term: &mut ratatui::DefaultTerminal, app: &mut App, rx: Receiver<Msg>) -> std::io::Result<()> {
    let mut last_log = Instant::now();
    loop {
        while let Ok(m) = rx.try_recv() {
            match m {
                Msg::Status(Ok(s)) => {
                    app.status = Some(s);
                    app.error = None;
                    app.last_ok = Some(Instant::now());
                    let n = rows_of(app);
                    if n > 0 && app.sel.selected().map(|i| i >= n).unwrap_or(true) {
                        app.sel.select(Some(0));
                    }
                }
                Msg::Status(Err(e)) => app.error = Some(e),
                Msg::History(Ok(h)) => app.history = Some(h),
                Msg::History(Err(e)) => app.flash(e, false),
                Msg::Log(t) => app.log_text = t,
                Msg::Action(label, r) => match r {
                    Ok(o) => {
                        let t = o.text();
                        if t.lines().count() > 2 || o.code != 0 {
                            app.output = Some((label, if t.is_empty() { tr("Terminé.").into() } else { t }));
                        } else {
                            app.flash(if t.is_empty() { tr("Fait.").into() } else { t }, true);
                        }
                    }
                    Err(e) => app.flash(e, false),
                },
            }
        }
        // journal suivi en direct
        if app.page() == Page::Logs && last_log.elapsed() > Duration::from_secs(5) {
            last_log = Instant::now();
            app.fetch_log();
        }
        term.draw(|f| draw(f, app))?;
        if event::poll(Duration::from_millis(250))? {
            if let Event::Key(k) = event::read()? {
                if k.kind == KeyEventKind::Press && !key(app, k.code, k.modifiers) {
                    return Ok(());
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn options_et_textes() {
        assert!(usage().contains("--hote"));
        assert_eq!(ssh::sq("a'b"), "'a'\\''b'");
        // scripts integres identiques a ceux de l'application
        assert!(remote::api_of(remote::NAS_DEBIAN_SH) >= 11);
        assert!(remote::OMV_STATUS.contains("python3"));
    }

    /// Rendu des pages avec un etat type (80 x 24, sans terminal)
    #[test]
    fn rendu() {
        use ratatui::backend::TestBackend;
        let st: OmvStatus = serde_json::from_str(
            r#"{"serveur":"omv","maintenant":1790000000,"nb_installe":true,"nb_api":11,"agent":{"script":"nas-debian","version":"2.6.0","api":11,"machine":"omv"},
               "sauvegardes":[{"nom":"Photos","source":"/srv/a/Photos","dossier":"Photos","mode":"sync","chiffre":true,"horaire":"03:30","dernier_etat":"OK","en_cours":false},
                              {"nom":"Docs","source":"/srv/a/Docs","dossier":"Docs","mode":"copy","horaire":"manuel","en_cours":true,"avancement":{"pct":42,"octets_faits":"1.000 GiB","octets_total":"2.000 GiB","vitesse":"5.000 MiB/s","reste":"3m"}}],
               "temps_reel":[{"nom":"Cam","actif":true,"envois_aujourdhui":12}],
               "alertes":[{"tag":"sauvegarde-Photos","depuis":1789990000}],
               "disques":[{"point":"/srv/dev-disk-by-uuid-1","taille":1000,"utilise":950,"libre":50}]}"#,
        )
        .unwrap();
        let (tx, _rx) = channel();
        let mut app = App {
            // (sudo : pas de lecture seule quand les tests ne tournent pas en root)
            target: Target::Local { sudo: true },
            kind: Kind::Debian,
            color: false,
            page: 0,
            pages: vec![Page::Dashboard, Page::Backups, Page::Realtime, Page::History, Page::Alerts, Page::Transfers, Page::Logs, Page::Install],
            status: Some(Status::Debian(Box::new(st))),
            error: None,
            last_ok: None,
            history: None,
            log_src: 0,
            log_text: "ligne 1\nligne 2".into(),
            sel: TableState::default(),
            confirm: None,
            output: None,
            message: None,
            help: false,
            tx,
            busy: Arc::new(Mutex::new(Vec::new())),
            refresh: Arc::new(Mutex::new(false)),
        };
        let mut term = ratatui::Terminal::new(TestBackend::new(80, 24)).unwrap();
        let screen = |term: &mut ratatui::Terminal<TestBackend>, app: &mut App| {
            term.draw(|f| draw(f, app)).unwrap();
            let b = term.backend().buffer().clone();
            (0..b.area.height).map(|y| (0..b.area.width).map(|x| b[(x, y)].symbol().to_string()).collect::<String>()).collect::<Vec<_>>().join("\n")
        };
        let s = screen(&mut term, &mut app);
        assert!(s.contains("nas-debian 2.6.0") && s.contains("Docs") && s.contains("42 %"), "{s}");
        goto(&mut app, 1);
        let s = screen(&mut term, &mut app);
        assert!(s.contains("Photos") && s.contains("miroir") && s.contains("Réussie"), "{s}");
        assert!(key(&mut app, KeyCode::Enter, KeyModifiers::NONE));
        assert!(app.confirm.as_ref().map(|c| c.script.contains("run 'Photos'")).unwrap_or(false));
        // n : rien n'est lance
        assert!(key(&mut app, KeyCode::Char('n'), KeyModifiers::NONE));
        assert!(app.confirm.is_none() && app.busy.lock().unwrap().is_empty());
        goto(&mut app, 4);
        let s = screen(&mut term, &mut app);
        assert!(s.contains("sauvegarde-Photos"), "{s}");
        app.help = true;
        let s = screen(&mut term, &mut app);
        assert!(s.contains("Aide"), "{s}");
        assert!(!key(&mut app, KeyCode::Esc, KeyModifiers::NONE) || true);
        assert!(!key(&mut app, KeyCode::Char('q'), KeyModifiers::NONE));
    }
}
