//! Sauvegarde de ce PC vers le NAS (étape 7) : des dossiers du PC (Documents, Bureau…)
//! envoyés dans un dossier de l'OMV / Debian ou du Synology, en copie ou en miroir (avec une
//! corbeille datée sur le NAS), à heure fixe et / ou en temps réel. rclone tourne sur le PC
//! et passe par SFTP avec la clé SSH de l'application (identité du NAS déjà confirmée).
//! Réglages et historique dans sauvegarde-pc.json ; un créneau manqué (PC éteint ou
//! application fermée) est rattrapé au lancement suivant.

use crate::app::{App, BrowsePurpose, HostId};
use crate::config::app_dir;
use crate::fmt;
#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::pages::{badge, banner, card, danger_button, dot, primary_button, progress_bar};
use crate::pcmig::{command, find_rclone, parse_json_line, Stats};
use crate::sched::{BwEdit, SchedEdit};
use crate::theme::{ERR, IDLE, INFO, OK, WARN};
use eframe::egui::{self, RichText};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Fichiers jamais envoyés (systeme, temporaires, telechargements en cours)
const EXCL: &[&str] = &[
    "Thumbs.db",
    "desktop.ini",
    ".DS_Store",
    "~$*",
    "*.tmp",
    "*.crdownload",
    "*.part",
    "$RECYCLE.BIN/**",
    "System Volume Information/**",
];
/// Corbeille datee des sauvegardes miroir, dans le dossier du NAS
pub const TRASH: &str = ".corbeille-pc";
/// Temps reel : envoi apres X s sans nouveau changement, au plus tard apres Y s
const RT_QUIET: i64 = 30;
const RT_MAX_WAIT: i64 = 600;
/// NAS injoignable : nouvel essai apres
const RETRY_S: i64 = 1800;

// =====================================================================
//  Donnees gardees (sauvegarde-pc.json)
// =====================================================================

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct PcJob {
    pub name: String,
    /// dossiers du PC
    pub dirs: Vec<String>,
    /// "omv" (OMV / Debian) ou "syno"
    pub host_kind: String,
    pub host: String,
    pub port: u16,
    pub user: String,
    /// dossier de destination sur le NAS (chemin complet)
    pub dest: String,
    /// "copie" ou "miroir"
    pub mode: String,
    /// miroir : jours de corbeille sur le NAS (0 = suppression directe)
    pub trash_days: u32,
    /// horaire au format des sauvegardes programmees ("manuel", "12:30", "03:30/135"...)
    pub sched: String,
    pub realtime: bool,
    /// limite de debit (--bwlimit), vide = aucune
    pub bw: String,
    /// exclusions supplementaires, separees par « ; »
    pub excludes: String,
    pub enabled: bool,
    pub created: i64,
}

impl Default for PcJob {
    fn default() -> Self {
        Self {
            name: String::new(),
            dirs: Vec::new(),
            host_kind: "omv".into(),
            host: String::new(),
            port: 22,
            user: String::new(),
            dest: String::new(),
            mode: "copie".into(),
            trash_days: 30,
            sched: "12:30".into(),
            realtime: false,
            bw: String::new(),
            excludes: String::new(),
            enabled: true,
            created: 0,
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct PcRun {
    pub name: String,
    pub start: i64,
    pub end: i64,
    pub ok: bool,
    pub files: u64,
    pub bytes: u64,
    pub errors: u64,
    pub detail: String,
    /// le NAS ne repondait pas (nouvel essai plus tard)
    pub unreachable: bool,
    /// "programmée", "temps réel", "manuelle", "rattrapage"
    pub trigger: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct Estimate {
    pub files: u64,
    pub bytes: u64,
    /// debit mesure vers le NAS (octets / s), 0 = non mesure
    pub speed: f64,
    pub at: i64,
    pub error: String,
}

impl Estimate {
    /// Duree estimee de l'envoi complet (secondes)
    pub fn eta(&self) -> Option<i64> {
        if self.speed > 0.0 {
            Some((self.bytes as f64 / self.speed) as i64 + self.files as i64 / 50)
        } else {
            None
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(default)]
pub struct Saved {
    pub jobs: Vec<PcJob>,
    pub last: BTreeMap<String, PcRun>,
    pub history: Vec<PcRun>,
    pub estimates: BTreeMap<String, Estimate>,
}

fn state_path() -> PathBuf {
    app_dir().join("sauvegarde-pc.json")
}

pub fn log_path() -> PathBuf {
    app_dir().join("sauvegarde-pc.log")
}

// =====================================================================
//  Etat partage avec les fils de travail
// =====================================================================

#[derive(Default)]
pub struct Live {
    pub running: Option<String>,
    pub stop: bool,
    pub phase: String,
    pub stats: Option<Stats>,
    /// dossier en cours (1..n)
    pub step: usize,
    pub count: usize,
    pub started: i64,
    pub log: VecDeque<String>,
}

#[derive(Default)]
pub struct Shared {
    pub saved: Saved,
    pub live: Live,
    /// sauvegardes en attente : (nom, declencheur)
    pub queue: VecDeque<(String, String)>,
    /// temps reel : (premier changement, dernier changement) en attente d'envoi
    pub dirty: HashMap<String, (i64, i64)>,
    /// NAS injoignable : prochain essai
    pub retry: HashMap<String, i64>,
    pub estimating: Option<String>,
    pub rclone: Option<(PathBuf, String)>,
    pub rclone_checked: bool,
    pub rclone_busy: bool,
    pub rclone_err: String,
    pub ctx: Option<egui::Context>,
    pub notify: bool,
    pub persist: bool,
}

impl Shared {
    fn save(&self) {
        if !self.persist {
            return;
        }
        let _ = std::fs::create_dir_all(app_dir());
        if let Ok(t) = serde_json::to_string_pretty(&self.saved) {
            let p = state_path();
            let tmp = p.with_extension("json.tmp");
            if std::fs::write(&tmp, t).is_ok() {
                let _ = std::fs::rename(&tmp, &p);
            }
        }
    }
    fn repaint(&self) {
        if let Some(c) = &self.ctx {
            c.request_repaint();
        }
    }
    fn log(&mut self, l: &str) {
        let line = format!("{} {l}", chrono::Local::now().format("%Y-%m-%d %H:%M:%S"));
        if self.persist {
            if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(log_path()) {
                let _ = writeln!(f, "{line}");
            }
        }
        self.live.log.push_back(line);
        while self.live.log.len() > 300 {
            self.live.log.pop_front();
        }
    }
    fn job(&self, name: &str) -> Option<PcJob> {
        self.saved.jobs.iter().find(|j| j.name == name).cloned()
    }
    fn enqueue(&mut self, name: &str, trigger: &str) {
        if self.live.running.as_deref() == Some(name) || self.queue.iter().any(|(n, _)| n == name) {
            return;
        }
        self.queue.push_back((name.to_string(), trigger.to_string()));
    }
}

pub type Sh = Arc<Mutex<Shared>>;

fn lock(sh: &Sh) -> std::sync::MutexGuard<'_, Shared> {
    sh.lock().unwrap_or_else(|e| e.into_inner())
}

/// Formulaire d'ajout / modification
#[derive(Clone, Default)]
pub struct PcForm {
    pub new: bool,
    pub orig: String,
    pub name: String,
    pub dirs: Vec<String>,
    pub host_kind: String,
    pub dest: String,
    pub mode: u8,
    pub trash_days: String,
    pub sched: SchedEdit,
    pub realtime: bool,
    pub bw: BwEdit,
    pub excludes: String,
    pub enabled: bool,
    pub error: String,
}

/// Cote interface : etat partage, formulaire, surveillance des dossiers (temps reel)
#[derive(Default)]
pub struct PcBackup {
    pub sh: Sh,
    pub form: Option<PcForm>,
    watchers: HashMap<String, (Vec<String>, notify::RecommendedWatcher)>,
    last_tick: Option<Instant>,
    started: bool,
}

impl PcBackup {
    pub fn load() -> Self {
        let saved = std::fs::read_to_string(state_path()).ok().and_then(|t| serde_json::from_str::<Saved>(&t).ok()).unwrap_or_default();
        let mut sh = Shared { saved, persist: true, ..Default::default() };
        // derniere sauvegarde en echec faute de NAS joignable : nouvel essai
        for r in sh.saved.last.values() {
            if !r.ok && r.unreachable {
                sh.retry.insert(r.name.clone(), r.end + RETRY_S);
            }
        }
        PcBackup { sh: Arc::new(Mutex::new(sh)), ..Default::default() }
    }
}

pub fn running(app: &App) -> Option<String> {
    lock(&app.pcbackup.sh).live.running.clone()
}

/// Pastille du menu : en cours, ou derniere sauvegarde en echec
pub fn nav_badge(app: &App) -> Option<(String, egui::Color32)> {
    let g = lock(&app.pcbackup.sh);
    if g.live.running.is_some() {
        return Some((tr("en cours").into(), INFO));
    }
    let ko = g.saved.jobs.iter().filter(|j| j.enabled && g.saved.last.get(&j.name).map(|r| !r.ok).unwrap_or(false)).count();
    if ko > 0 {
        Some((tf("{0} échec", &[&ko]), ERR))
    } else {
        None
    }
}

// =====================================================================
//  Chemins et commandes rclone
// =====================================================================

/// Nom du sous-dossier d'un dossier du PC sur le NAS : « Documents », « D » pour D:\
pub fn dir_label(d: &str) -> String {
    // separateurs Windows et Unix (le nom est aussi calcule hors de Windows, ex. tests)
    let t = d.trim_end_matches(['\\', '/']);
    let n = t.rsplit(['\\', '/']).next().unwrap_or(t).trim_end_matches(':').to_string();
    n.chars().map(|c| if "/\\:*?\"<>|".contains(c) { '_' } else { c }).collect()
}

/// Sous-dossiers distincts (« Photos », « Photos (2) »...)
pub fn labels(dirs: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for d in dirs {
        let base = dir_label(d);
        let mut l = base.clone();
        let mut k = 2;
        while out.iter().any(|o| o.eq_ignore_ascii_case(&l)) {
            l = format!("{base} ({k})");
            k += 1;
        }
        out.push(l);
    }
    out
}

/// Chemin vu par SFTP : sur le Synology, les dossiers partagés sont à la racine
/// (/volume1/Sauvegardes -> /Sauvegardes)
pub fn sftp_path(kind: &str, p: &str) -> String {
    let p = p.trim().trim_end_matches('/');
    if kind == "syno" {
        if let Some(rest) = p.strip_prefix("/volume") {
            let i = rest.find('/').unwrap_or(rest.len());
            if rest[..i].chars().all(|c| c.is_ascii_digit()) && i > 0 {
                let r = &rest[i..];
                return if r.is_empty() { "/".into() } else { r.to_string() };
            }
        }
    }
    if p.is_empty() {
        "/".into()
    } else {
        p.to_string()
    }
}

fn nas(j: &PcJob, sub: &str) -> String {
    let base = sftp_path(&j.host_kind, &j.dest);
    let base = base.trim_end_matches('/');
    if sub.is_empty() {
        format!("nas:{}", if base.is_empty() { "/" } else { base })
    } else {
        format!("nas:{base}/{sub}")
    }
}

/// rclone avec le distant « nas: » (SFTP, cle et identite connue de l'application)
fn rclone_nas(rc: &Path, j: &PcJob) -> Command {
    let mut c = command(rc);
    let dir = app_dir();
    let cfg = dir.join("rclone-pc.conf");
    if !cfg.exists() {
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(&cfg, "");
    }
    c.env("RCLONE_CONFIG", cfg)
        .env("RCLONE_CONFIG_NAS_TYPE", "sftp")
        .env("RCLONE_CONFIG_NAS_HOST", j.host.trim())
        .env("RCLONE_CONFIG_NAS_PORT", j.port.to_string())
        .env("RCLONE_CONFIG_NAS_USER", j.user.trim())
        .env("RCLONE_CONFIG_NAS_KEY_FILE", dir.join("id_ed25519"))
        .env("RCLONE_CONFIG_NAS_KNOWN_HOSTS_FILE", dir.join("known_hosts"))
        .env("RCLONE_CONFIG_NAS_SHELL_TYPE", "unix")
        .stdin(Stdio::null());
    c
}

fn excludes(j: &PcJob) -> Vec<String> {
    let mut v: Vec<String> = EXCL.iter().map(|s| s.to_string()).collect();
    v.extend(j.excludes.split(';').map(|s| s.trim().replace('\\', "/")).filter(|s| !s.is_empty()));
    v.push(format!("{TRASH}/**"));
    v
}

/// Message rclone -> NAS injoignable ?
pub fn unreachable_msg(m: &str) -> bool {
    let m = m.to_lowercase();
    ["connection refused", "no route to host", "i/o timeout", "network is unreachable", "couldn't connect ssh", "dial tcp", "connection timed out", "host is down", "no such host"]
        .iter()
        .any(|k| m.contains(k))
}

/// Lance rclone et suit ses statistiques ; renvoie (code, erreurs, derniere statistique)
fn run_rclone(sh: &Sh, mut cmd: Command) -> (i32, Vec<String>, Option<Stats>) {
    cmd.args(["--use-json-log", "--stats", "2s", "--stats-log-level", "NOTICE", "--log-level", "NOTICE"]).stdout(Stdio::null()).stderr(Stdio::piped());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return (-1, vec![e.to_string()], None),
    };
    let pf = app_dir().join("sauvegarde-pc.pid");
    if lock(sh).persist {
        let _ = std::fs::write(&pf, child.id().to_string());
    }
    let errs = Arc::new(Mutex::new(Vec::<String>::new()));
    let last = Arc::new(Mutex::new(None::<Stats>));
    let reader = child.stderr.take().map(|se| {
        let (sh, errs, last) = (sh.clone(), errs.clone(), last.clone());
        std::thread::spawn(move || {
            for l in BufReader::new(se).lines().map_while(Result::ok) {
                let (st, msg) = parse_json_line(&l);
                let mut g = lock(&sh);
                if let Some(st) = st {
                    *last.lock().unwrap_or_else(|e| e.into_inner()) = Some(st.clone());
                    g.live.stats = Some(st);
                    g.repaint();
                }
                if let Some((lvl, m)) = msg {
                    if m.is_empty() {
                        continue;
                    }
                    // erreur fatale (« Failed to create file system… ») : notee sans niveau
                    if lvl == "error" || lvl == "critical" || m.contains("Failed to") || m.contains("Fatal error") {
                        errs.lock().unwrap_or_else(|e| e.into_inner()).push(m.clone());
                    }
                    g.log(&format!("{} {m}", lvl.to_uppercase()));
                }
            }
        })
    });
    let code = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s.code().unwrap_or(-1),
            Ok(None) => {}
            Err(_) => break -1,
        }
        if lock(sh).live.stop {
            let _ = child.kill();
            let _ = child.wait();
            break -2;
        }
        std::thread::sleep(Duration::from_millis(300));
    };
    let _ = std::fs::remove_file(&pf);
    if let Some(r) = reader {
        let _ = r.join();
    }
    let e = errs.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let s = last.lock().unwrap_or_else(|e| e.into_inner()).clone();
    (code, e, s)
}

/// rclone lance par une session precedente (application fermee brutalement)
fn kill_orphan() {
    let pf = app_dir().join("sauvegarde-pc.pid");
    let Some(pid) = std::fs::read_to_string(&pf).ok().and_then(|t| t.trim().parse::<u32>().ok()) else { return };
    let _ = std::fs::remove_file(&pf);
    #[cfg(windows)]
    {
        let list = command("tasklist").args(["/FI", &format!("PID eq {pid}"), "/NH"]).output().map(|o| String::from_utf8_lossy(&o.stdout).to_lowercase()).unwrap_or_default();
        if list.contains("rclone") {
            let _ = command("taskkill").args(["/PID", &pid.to_string(), "/T", "/F"]).status();
        }
    }
    #[cfg(unix)]
    {
        if std::fs::read_to_string(format!("/proc/{pid}/comm")).map(|c| c.trim() == "rclone").unwrap_or(false) {
            let _ = Command::new("kill").arg(pid.to_string()).status();
        }
    }
}

// =====================================================================
//  Horaires
// =====================================================================

/// Dernier creneau de l'horaire passe a l'instant `now` (dans les 8 derniers jours)
pub fn last_due(sched: &str, now: i64) -> Option<i64> {
    use chrono::{Datelike, Local, TimeZone};
    if sched == "manuel" || sched.trim().is_empty() {
        return None;
    }
    let now_dt = Local.timestamp_opt(now, 0).single()?.naive_local();
    let mut best: Option<i64> = None;
    for sl in sched.split(';') {
        let (t, d) = sl.split_once('/').unwrap_or((sl, "1234567"));
        let Some((h, m)) = t.split_once(':') else { continue };
        let (Ok(h), Ok(m)) = (h.parse::<u32>(), m.parse::<u32>()) else { continue };
        for back in 0..8 {
            let day = now_dt.date() - chrono::Duration::days(back);
            let dow = day.weekday().number_from_monday();
            if !d.contains(char::from_digit(dow, 10).unwrap_or('0')) {
                continue;
            }
            let Some(at) = day.and_hms_opt(h, m, 0) else { continue };
            if at <= now_dt {
                if let Some(ts) = Local.from_local_datetime(&at).earliest().map(|x| x.timestamp()) {
                    if best.map(|b| ts > b).unwrap_or(true) {
                        best = Some(ts);
                    }
                }
                break;
            }
        }
    }
    best
}

// =====================================================================
//  Moteur
// =====================================================================

fn set_phase(sh: &Sh, p: &str) {
    let mut g = lock(sh);
    g.live.phase = p.to_string();
    g.live.stats = None;
    g.repaint();
}

/// Corbeille du NAS : retire les dossiers dates plus vieux que `days` jours
fn trash_purge(sh: &Sh, rc: &Path, j: &PcJob, now: i64) {
    let o = rclone_nas(rc, j).args(["lsf", "--dirs-only"]).arg(nas(j, TRASH)).stderr(Stdio::null()).output();
    let Ok(o) = o else { return };
    let limit = now - j.trash_days as i64 * 86400;
    for d in String::from_utf8_lossy(&o.stdout).lines() {
        let d = d.trim_end_matches('/');
        // nom : AAAA-MM-JJ_HHMMSS
        let Some(ts) = fmt::parse_local(d.get(..10).unwrap_or(""), "00:00") else { continue };
        if ts < limit {
            let st = rclone_nas(rc, j).arg("purge").arg(nas(j, &format!("{TRASH}/{d}"))).stderr(Stdio::null()).status();
            if st.map(|s| s.success()).unwrap_or(false) {
                lock(sh).log(&tf("corbeille : {0} retiré (plus de {1} jours)", &[&d, &(j.trash_days)]));
            }
        }
    }
}

/// Une sauvegarde complete (bloquant)
pub fn run_job(sh: &Sh, rc: &Path, j: &PcJob, trigger: &str) -> PcRun {
    let start = fmt::now();
    let mut run = PcRun { name: j.name.clone(), start, trigger: trigger.to_string(), ..Default::default() };
    let finish = |mut run: PcRun, ok: bool, detail: String| {
        run.end = fmt::now();
        run.ok = ok;
        run.detail = detail;
        run
    };
    let missing: Vec<&String> = j.dirs.iter().filter(|d| !Path::new(d.as_str()).is_dir()).collect();
    if j.dirs.is_empty() || missing.len() == j.dirs.len() {
        return finish(run, false, tf("dossier introuvable sur ce PC : {0}", &[&(j.dirs.first().cloned().unwrap_or_default())]));
    }
    // dossier de destination (et acces au NAS)
    set_phase(sh, "connexion");
    let (code, errs, _) = run_rclone(sh, {
        let mut c = rclone_nas(rc, j);
        c.arg("mkdir").arg(nas(j, "")).args(["--contimeout", "20s", "--retries", "1", "--low-level-retries", "2"]);
        c
    });
    if code == -2 {
        return finish(run, false, tr("arrêtée").into());
    }
    if code != 0 {
        let m = errs.last().cloned().unwrap_or_else(|| tf("rclone s'est arrêté (code {0})", &[&code]));
        run.unreachable = errs.iter().any(|e| unreachable_msg(e));
        let detail = if run.unreachable {
            tf("NAS injoignable ({0}) : nouvel essai dans 30 min", &[&(j.host)])
        } else if m.contains("unable to authenticate") || m.contains("handshake failed") {
            tr("Clé SSH refusée par le NAS : Paramètres > Autoriser la clé.").into()
        } else if m.contains("knownhosts") || m.contains("key mismatch") {
            tr("Identité du NAS non confirmée ou changée : Paramètres > Confirmer l'identité du NAS.").into()
        } else {
            m
        };
        return finish(run, false, detail);
    }
    let stamp = chrono::Local::now().format("%Y-%m-%d_%H%M%S").to_string();
    let labs = labels(&j.dirs);
    let ex = excludes(j);
    let mut errors_txt: Vec<String> = Vec::new();
    {
        let mut g = lock(sh);
        g.live.count = j.dirs.len();
    }
    for (i, (d, lab)) in j.dirs.iter().zip(labs.iter()).enumerate() {
        {
            let mut g = lock(sh);
            g.live.step = i + 1;
            g.log(&format!("--- {d} -> {}", nas(j, lab)));
        }
        if !Path::new(d).is_dir() {
            errors_txt.push(tf("dossier introuvable : {0}", &[d]));
            continue;
        }
        set_phase(sh, "envoi");
        let mut c = rclone_nas(rc, j);
        if j.mode == "miroir" {
            c.arg("sync").arg(d).arg(nas(j, lab));
            if j.trash_days > 0 {
                c.arg("--backup-dir").arg(nas(j, &format!("{TRASH}/{stamp}/{lab}")));
            }
        } else {
            c.arg("copy").arg(d).arg(nas(j, lab));
        }
        for e in &ex {
            c.args(["--exclude", e]);
        }
        c.args(["--transfers", "4", "--checkers", "8", "--retries", "3", "--low-level-retries", "10", "--contimeout", "20s", "--timeout", "5m"]);
        if !j.bw.trim().is_empty() && j.bw.trim() != "off" {
            c.arg("--bwlimit").arg(j.bw.trim());
        }
        let (code, errs, st) = run_rclone(sh, c);
        if let Some(s) = &st {
            run.files += s.transfers;
            run.bytes += s.bytes;
            run.errors += s.errors;
        }
        match code {
            0 => {}
            -2 => return finish(run, false, tr("arrêtée").into()),
            _ => {
                run.unreachable = run.unreachable || errs.iter().any(|e| unreachable_msg(e));
                errors_txt.push(format!("{lab} : {}", errs.last().cloned().unwrap_or_else(|| tf("rclone s'est arrêté (code {0})", &[&code]))));
            }
        }
    }
    if j.mode == "miroir" && j.trash_days > 0 {
        set_phase(sh, "corbeille");
        trash_purge(sh, rc, j, start);
    }
    let summary = if run.files == 0 {
        tr("Déjà à jour, aucun changement").to_string()
    } else {
        tf("{0} fichier(s) envoyé(s), {1}", &[&(run.files), &(fmt::bytes(run.bytes))])
    };
    if errors_txt.is_empty() {
        finish(run, true, summary)
    } else {
        let d = format!("{summary} · {}", errors_txt.join(" · "));
        finish(run, false, d)
    }
}

/// Traite la file d'attente (bloquant : a lancer dans un fil)
pub fn worker(sh: Sh) {
    let rc = {
        let mut g = lock(&sh);
        if g.rclone.is_none() {
            g.rclone = find_rclone();
        }
        g.rclone.clone()
    };
    let Some((rc, ver)) = rc else {
        let mut g = lock(&sh);
        g.log(tr("rclone n'est pas installé sur ce PC : sauvegardes impossibles."));
        g.queue.clear();
        g.live.running = None;
        g.repaint();
        return;
    };
    crate::pcmig::keep_awake(true);
    loop {
        let (name, trigger, job) = {
            let mut g = lock(&sh);
            if g.live.stop {
                g.queue.clear();
            }
            let Some((n, t)) = g.queue.pop_front() else {
                g.live.running = None;
                break;
            };
            let Some(j) = g.job(&n) else { continue };
            g.live.running = Some(n.clone());
            g.live.started = fmt::now();
            g.live.step = 0;
            g.live.stats = None;
            g.dirty.remove(&n);
            g.retry.remove(&n);
            let l = format!("=== {n} ({t}) · {ver}");
            g.log(&l);
            g.repaint();
            (n, t, j)
        };
        let run = run_job(&sh, &rc, &job, &trigger);
        let mut g = lock(&sh);
        g.log(&format!("=== {name} : {} — {}", if run.ok { "OK" } else { "ECHEC" }, run.detail));
        if run.unreachable && !run.ok {
            g.retry.insert(name.clone(), run.end + RETRY_S);
        }
        let stopped = g.live.stop;
        let prev_ok = g.saved.last.get(&name).map(|r| r.ok).unwrap_or(true);
        g.saved.last.insert(name.clone(), run.clone());
        g.saved.history.push(run.clone());
        let n = g.saved.history.len();
        if n > 300 {
            g.saved.history.drain(..n - 300);
        }
        g.save();
        // notification : echec (pas a chaque essai si le NAS reste injoignable), retour a la
        // normale, ou fin d'une sauvegarde lancee a la main
        if g.notify && !stopped {
            if let Some(ctx) = g.ctx.clone() {
                if !run.ok && (prev_ok || !run.unreachable) {
                    crate::tray::notify(&ctx, &tf("Sauvegarde du PC « {0} » : échec", &[&name]), &run.detail);
                } else if run.ok && (!prev_ok || trigger == "manuelle") {
                    crate::tray::notify(&ctx, &tf("Sauvegarde du PC « {0} » terminée", &[&name]), &run.detail);
                }
            }
        }
        if stopped {
            g.live.stop = false;
            g.queue.clear();
        }
    }
    crate::pcmig::keep_awake(false);
    let mut g = lock(&sh);
    g.live.running = None;
    g.live.stats = None;
    g.repaint();
}

fn start_worker(sh: &Sh) {
    {
        let mut g = lock(sh);
        if g.live.running.is_some() || g.queue.is_empty() {
            return;
        }
        // marque tout de suite : un seul fil de travail
        g.live.running = g.queue.front().map(|(n, _)| n.clone());
        g.live.stop = false;
    }
    let s = sh.clone();
    std::thread::spawn(move || worker(s));
}

/// Estimation : volume des dossiers et debit mesure vers le NAS (envoi d'un fichier de test)
pub fn estimate(rc: Option<&Path>, j: &PcJob) -> Estimate {
    let mut e = Estimate { at: fmt::now(), ..Default::default() };
    for d in &j.dirs {
        let (n, b) = crate::pcmig::dir_size(Path::new(d));
        e.files += n;
        e.bytes += b;
    }
    let Some(rc) = rc else {
        e.error = tr("rclone absent : débit non mesuré.").into();
        return e;
    };
    // 16 Mo peu compressibles
    let size = 16 * 1024 * 1024;
    let mut data = vec![0u8; size];
    let mut x: u64 = 0x9E37_79B9_7F4A_7C15 ^ fmt::now() as u64;
    for b in data.iter_mut() {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        *b = x as u8;
    }
    let tmp = std::env::temp_dir().join(format!("nas-manager-debit-{}.bin", std::process::id()));
    if std::fs::write(&tmp, &data).is_err() {
        e.error = tr("Fichier de test impossible à écrire.").into();
        return e;
    }
    let target = nas(j, ".nas-manager-test-debit.bin");
    let _ = rclone_nas(rc, j).arg("mkdir").arg(nas(j, "")).stderr(Stdio::null()).status();
    let t0 = Instant::now();
    let mut c = rclone_nas(rc, j);
    c.arg("copyto").arg(&tmp).arg(&target).args(["--retries", "1", "--contimeout", "20s"]);
    if !j.bw.trim().is_empty() && j.bw.trim() != "off" {
        c.arg("--bwlimit").arg(j.bw.trim());
    }
    let out = c.stderr(Stdio::piped()).output();
    let el = t0.elapsed().as_secs_f64().max(0.05);
    let _ = std::fs::remove_file(&tmp);
    match out {
        Ok(o) if o.status.success() => {
            e.speed = size as f64 / el;
            let _ = rclone_nas(rc, j).arg("deletefile").arg(&target).stderr(Stdio::null()).status();
        }
        Ok(o) => {
            let m = String::from_utf8_lossy(&o.stderr).lines().last().unwrap_or("").to_string();
            e.error = if unreachable_msg(&m) { tr("NAS injoignable : débit non mesuré.").into() } else { tf("Envoi de test impossible : {0}", &[&m]) };
        }
        Err(er) => e.error = er.to_string(),
    }
    e
}

// =====================================================================
//  Planification et temps reel (appele a chaque image, fenetre cachee comprise)
// =====================================================================

/// Fichier a ignorer pour le temps reel (temporaires d'Office, systeme)
fn ignored(p: &Path) -> bool {
    let n = p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    n.starts_with("~$") || n == "Thumbs.db" || n == "desktop.ini" || n.ends_with(".tmp") || n.ends_with(".crdownload") || n.ends_with(".part")
}

fn watch(sh: &Sh, name: &str, dirs: &[String]) -> Option<notify::RecommendedWatcher> {
    use notify::Watcher;
    let (s, n) = (sh.clone(), name.to_string());
    let mut w = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        let Ok(ev) = res else { return };
        if ev.kind.is_access() || ev.paths.iter().all(|p| ignored(p)) {
            return;
        }
        let now = fmt::now();
        let mut g = lock(&s);
        let e = g.dirty.entry(n.clone()).or_insert((now, now));
        e.1 = now;
    })
    .ok()?;
    let mut any = false;
    for d in dirs {
        if w.watch(Path::new(d), notify::RecursiveMode::Recursive).is_ok() {
            any = true;
        }
    }
    any.then_some(w)
}

pub fn tick(app: &mut App, ctx: &egui::Context) {
    let notify = app.settings.notifications;
    let pb = &mut app.pcbackup;
    let first = !pb.started;
    pb.started = true;
    {
        let mut g = lock(&pb.sh);
        g.ctx = Some(ctx.clone());
        g.notify = notify;
        if g.live.running.is_some() {
            ctx.request_repaint_after(Duration::from_secs(1));
        }
    }
    if first {
        kill_orphan();
    }
    if !first && pb.last_tick.map(|t| t.elapsed() < Duration::from_secs(5)).unwrap_or(false) {
        return;
    }
    pb.last_tick = Some(Instant::now());
    if app.settings.read_only {
        return;
    }
    let now = fmt::now();
    let jobs = lock(&pb.sh).saved.jobs.clone();
    // surveillance des dossiers (temps reel)
    let want: Vec<&PcJob> = jobs.iter().filter(|j| j.enabled && j.realtime).collect();
    pb.watchers.retain(|n, (dirs, _)| want.iter().any(|j| &j.name == n && &j.dirs == dirs));
    for j in &want {
        if !pb.watchers.contains_key(&j.name) {
            if let Some(w) = watch(&pb.sh, &j.name, &j.dirs) {
                pb.watchers.insert(j.name.clone(), (j.dirs.clone(), w));
            }
        }
    }
    let mut g = lock(&pb.sh);
    for j in jobs.iter().filter(|j| j.enabled) {
        let last = g.saved.last.get(&j.name).cloned();
        let last_start = last.as_ref().map(|r| r.start).unwrap_or(0);
        if let Some(due) = last_due(&j.sched, now) {
            if due > last_start && due > j.created {
                let trig = if now - due > 300 { "rattrapage" } else { "programmée" };
                if !(last.as_ref().map(|r| r.unreachable && !r.ok).unwrap_or(false) && g.retry.get(&j.name).map(|t| *t > now).unwrap_or(false)) {
                    g.enqueue(&j.name, trig);
                }
            }
        }
        if let Some(t) = g.retry.get(&j.name).copied() {
            if t <= now {
                g.retry.remove(&j.name);
                g.enqueue(&j.name, "nouvel essai");
            }
        }
        if j.realtime {
            if let Some((first_ch, last_ch)) = g.dirty.get(&j.name).copied() {
                let ended = last.as_ref().map(|r| r.end).unwrap_or(0);
                if (now - last_ch >= RT_QUIET || now - first_ch >= RT_MAX_WAIT) && now - ended >= 60 && !g.retry.contains_key(&j.name) {
                    g.enqueue(&j.name, "temps réel");
                }
            }
        }
    }
    drop(g);
    start_worker(&pb.sh);
}

// =====================================================================
//  Interface
// =====================================================================

fn phase_text(p: &str) -> &'static str {
    match p {
        "connexion" => tr("Connexion au NAS"),
        "corbeille" => tr("Nettoyage de la corbeille du NAS"),
        _ => tr("Envoi"),
    }
}

fn trigger_text(t: &str) -> &'static str {
    match t {
        "programmée" => tr("programmée"),
        "temps réel" => tr("temps réel"),
        "rattrapage" => tr("rattrapage d'un créneau manqué"),
        "nouvel essai" => tr("nouvel essai"),
        _ => tr("manuelle"),
    }
}

fn user_dir(sub: &str) -> Option<String> {
    let home = std::env::var("USERPROFILE").or_else(|_| std::env::var("HOME")).ok()?;
    let p = Path::new(&home).join(sub);
    p.is_dir().then(|| p.display().to_string())
}

fn host_cfg(app: &App, kind: &str) -> crate::config::HostCfg {
    if kind == "syno" {
        app.settings.syno.clone()
    } else {
        app.settings.omv.clone()
    }
}

pub fn estimate_text(e: &Estimate) -> String {
    let mut t = tf("{0} fichier(s), {1}", &[&(fmt::count(e.files)), &(fmt::bytes(e.bytes))]);
    match e.eta() {
        Some(s) => t.push_str(&tf(" · débit mesuré {0}/s · première sauvegarde ≈ {1}", &[&(fmt::bytes(e.speed as u64)), &(fmt::duration(s.max(60)))])),
        None if !e.error.is_empty() => t.push_str(&format!(" · {}", e.error)),
        None => {}
    }
    t
}

fn start_estimate(app: &mut App, j: PcJob) {
    let sh = app.pcbackup.sh.clone();
    {
        let mut g = lock(&sh);
        if g.estimating.is_some() {
            return;
        }
        g.estimating = Some(j.name.clone());
    }
    std::thread::spawn(move || {
        let rc = { lock(&sh).rclone.clone() }.or_else(find_rclone).map(|r| r.0);
        let e = estimate(rc.as_deref(), &j);
        let mut g = lock(&sh);
        g.estimating = None;
        g.saved.estimates.insert(j.name.clone(), e);
        g.save();
        g.repaint();
    });
}

pub fn page(app: &mut App, ui: &mut egui::Ui) {
    crate::pages::page_title_pub(ui, tr("Sauvegarde de ce PC"), tr("Dossiers du PC envoyés sur le NAS, à heure fixe ou en temps réel"));
    let sh = app.pcbackup.sh.clone();
    {
        let mut g = lock(&sh);
        if !g.rclone_checked {
            g.rclone_checked = true;
            g.rclone = find_rclone();
        }
    }
    banner(
        ui,
        INFO,
        tr("rclone tourne sur ce PC et envoie les fichiers au NAS par SFTP, avec la clé de l'application. L'application doit être ouverte (même réduite dans la zone de notification) ; un créneau manqué, PC éteint, est rattrapé au lancement suivant."),
    );
    if !app.autostart && crate::tray::autostart_supported() {
        ui.horizontal(|ui| {
            ui.label(RichText::new(tr("Conseil : lancer NAS Manager au démarrage de Windows.")).small());
            if ui.small_button(tr("Activer")).clicked() {
                match crate::tray::set_autostart(true) {
                    Ok(()) => app.autostart = true,
                    Err(e) => app.toast(false, e),
                }
            }
        });
    }
    ui.add_space(6.0);

    // ---- rclone
    let (rclone, rbusy, rerr) = {
        let g = lock(&sh);
        (g.rclone.clone(), g.rclone_busy, g.rclone_err.clone())
    };
    if rclone.is_none() {
        card(ui, tr("rclone"), |ui| {
            ui.colored_label(WARN, tr("rclone n'est pas installé sur ce PC."));
            ui.horizontal(|ui| {
                if rbusy {
                    ui.spinner();
                    ui.label(tr("Téléchargement depuis downloads.rclone.org…"));
                } else if ui.button(tr("\u{E20C} Télécharger rclone")).clicked() {
                    lock(&sh).rclone_busy = true;
                    let s = sh.clone();
                    std::thread::spawn(move || {
                        let r = crate::pcmig::download_rclone();
                        let mut g = lock(&s);
                        g.rclone_busy = false;
                        match r {
                            Ok(()) => {
                                g.rclone = find_rclone();
                                g.rclone_err = if g.rclone.is_none() { tr("rclone téléchargé mais impossible à lancer.").into() } else { String::new() };
                            }
                            Err(e) => g.rclone_err = e,
                        }
                        g.repaint();
                    });
                }
            });
            if !rerr.is_empty() {
                ui.colored_label(ERR, &rerr);
            }
        });
        ui.add_space(10.0);
    }

    let (saved, running, queue, phase, stats, step, count, started, estimating, dirty, retry) = {
        let g = lock(&sh);
        (
            g.saved.clone(),
            g.live.running.clone(),
            g.queue.iter().map(|(n, _)| n.clone()).collect::<Vec<_>>(),
            g.live.phase.clone(),
            g.live.stats.clone(),
            g.live.step,
            g.live.count,
            g.live.started,
            g.estimating.clone(),
            g.dirty.clone(),
            g.retry.clone(),
        )
    };
    let now = fmt::now();

    // ---- en cours
    if let Some(n) = &running {
        card(ui, &tf("En cours : « {0} »", &[n]), |ui| {
            if count > 1 {
                ui.label(tf("Dossier {0} / {1} · {2}", &[&step, &count, &(phase_text(&phase))]));
            } else {
                ui.label(phase_text(&phase));
            }
            match &stats {
                Some(s) if s.total_bytes > 0 || s.transfers > 0 => {
                    let pct = if s.total_bytes > 0 { Some(((s.bytes as f64 / s.total_bytes as f64) * 100.0).min(100.0) as i64) } else { None };
                    let mut line = tf("{0} / {1} envoyés · {2} fichier(s)", &[&(fmt::bytes(s.bytes)), &(fmt::bytes(s.total_bytes)), &(s.transfers)]);
                    if s.speed > 0.0 {
                        line.push_str(&format!(" · {}/s", fmt::bytes(s.speed as u64)));
                    }
                    if let Some(e) = s.eta {
                        line.push_str(&tf(" · reste {0}", &[&(fmt::duration(e))]));
                    }
                    progress_bar(ui, pct, line);
                }
                Some(s) => progress_bar(ui, None, tf("Comparaison avec le NAS… {0} fichier(s) vérifié(s)", &[&(s.checks)])),
                None => progress_bar(ui, None, tr("démarrage…").into()),
            }
            ui.label(RichText::new(tf("Lancée {0}", &[&(fmt::ago(started, now))])).small().weak());
            if danger_button(ui, tr("\u{E46C} Arrêter")).clicked() {
                lock(&sh).live.stop = true;
            }
        });
        ui.add_space(10.0);
    }

    // ---- sauvegardes
    ui.horizontal(|ui| {
        ui.heading(tf("Sauvegardes ({0})", &[&(saved.jobs.len())]));
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if primary_button(ui, tr("+ Nouvelle sauvegarde du PC")).clicked() && !app.blocked() {
                let kind = "omv".to_string();
                app.pcbackup.form = Some(PcForm {
                    new: true,
                    host_kind: kind,
                    mode: 0,
                    trash_days: "30".into(),
                    sched: SchedEdit::parse("12:30"),
                    enabled: true,
                    dirs: user_dir("Documents").into_iter().collect(),
                    ..Default::default()
                });
            }
        });
    });
    ui.add_space(4.0);
    if saved.jobs.is_empty() {
        card(ui, "", |ui| {
            ui.label(RichText::new(tr("Aucune sauvegarde du PC. Exemple : Documents et Bureau envoyés chaque jour à 12:30 dans /srv/…/Sauvegardes/PC, en miroir avec une corbeille de 30 jours.")).weak());
        });
    }
    let mut action: Option<(String, u8)> = None;
    for j in &saved.jobs {
        let last = saved.last.get(&j.name);
        let col = if !j.enabled {
            IDLE
        } else if running.as_deref() == Some(j.name.as_str()) {
            INFO
        } else {
            match last {
                Some(r) if r.ok => OK,
                Some(_) => ERR,
                None => WARN,
            }
        };
        card(ui, "", |ui| {
            ui.horizontal(|ui| {
                dot(ui, col);
                ui.label(RichText::new(&j.name).strong().size(15.0));
                badge(ui, if j.mode == "miroir" { tr("miroir") } else { tr("copie") }, INFO);
                if j.realtime {
                    badge(ui, tr("temps réel"), OK);
                }
                if !j.enabled {
                    badge(ui, tr("désactivée"), IDLE);
                }
                if queue.contains(&j.name) {
                    badge(ui, tr("en attente"), WARN);
                }
            });
            let labs = labels(&j.dirs);
            for (d, l) in j.dirs.iter().zip(labs.iter()) {
                ui.label(RichText::new(format!("{d}  →  {}:{}/{l}", if j.host_kind == "syno" { "Synology" } else { "OMV" }, j.dest.trim_end_matches('/'))).monospace().size(12.5));
            }
            let mut cfg = vec![crate::fmt::schedule_human(&j.sched)];
            if let Some(n) = fmt::next_run_sched(&j.sched).filter(|_| j.enabled) {
                cfg.push(tf("prochaine : {0}", &[&n]));
            }
            if j.mode == "miroir" {
                cfg.push(if j.trash_days > 0 { tf("corbeille {0} j sur le NAS", &[&(j.trash_days)]) } else { tr("suppressions directes").into() });
            }
            if !j.bw.is_empty() {
                cfg.push(tf("débit : {0}", &[&(fmt::bw_human(&j.bw))]));
            }
            ui.label(RichText::new(cfg.join(" · ")).small().weak());
            match last {
                Some(r) => {
                    ui.horizontal_wrapped(|ui| {
                        ui.label(RichText::new(tf("Dernière : {0} ({1}, {2})", &[&(fmt::ago(r.start, now)), &(trigger_text(&r.trigger)), &(fmt::duration((r.end - r.start).max(1)))])).small());
                        ui.label(RichText::new(&r.detail).small().color(if r.ok { OK } else { ERR }));
                    });
                }
                None => {
                    ui.label(RichText::new(tr("Jamais lancée.")).small().color(WARN));
                }
            }
            if let Some(t) = retry.get(&j.name) {
                ui.label(RichText::new(tf("Nouvel essai {0}", &[&(fmt::date(*t))])).small().color(WARN));
            }
            if let Some((_, l)) = dirty.get(&j.name) {
                ui.label(RichText::new(tf("Changements détectés {0} : envoi dès que le dossier est calme", &[&(fmt::ago(*l, now))])).small().color(INFO));
            }
            if let Some(e) = saved.estimates.get(&j.name) {
                ui.label(RichText::new(tf("Estimation ({0}) : {1}", &[&(fmt::ago(e.at, now)), &(estimate_text(e))])).small().weak());
            }
            ui.horizontal(|ui| {
                let busy = running.as_deref() == Some(j.name.as_str()) || queue.contains(&j.name);
                if ui.add_enabled(!busy && rclone.is_some() && j.enabled, egui::Button::new(tr("\u{E3D0} Lancer"))).clicked() {
                    action = Some((j.name.clone(), 0));
                }
                if ui.add_enabled(running.is_none(), egui::Button::new(tr("\u{E3EE} Modifier"))).clicked() {
                    action = Some((j.name.clone(), 1));
                }
                if estimating.as_deref() == Some(j.name.as_str()) {
                    ui.spinner();
                    ui.label(RichText::new(tr("Estimation…")).small());
                } else if ui.add_enabled(estimating.is_none(), egui::Button::new(tr("Estimer"))).on_hover_text(tr("Volume des dossiers et débit réel vers le NAS (envoi d'un fichier de test de 16 Mo)")).clicked() {
                    action = Some((j.name.clone(), 3));
                }
                if ui.add_enabled(!busy, egui::Button::new(tr("\u{E4A6} Supprimer"))).clicked() {
                    action = Some((j.name.clone(), 2));
                }
            });
        });
        ui.add_space(6.0);
    }
    if let Some((n, a)) = action {
        match a {
            0 => {
                if !app.blocked() {
                    lock(&sh).enqueue(&n, "manuelle");
                    start_worker(&sh);
                }
            }
            1 => {
                if let Some(j) = saved.jobs.iter().find(|j| j.name == n) {
                    app.pcbackup.form = Some(PcForm {
                        new: false,
                        orig: j.name.clone(),
                        name: j.name.clone(),
                        dirs: j.dirs.clone(),
                        host_kind: j.host_kind.clone(),
                        dest: j.dest.clone(),
                        mode: (j.mode == "miroir") as u8,
                        trash_days: j.trash_days.to_string(),
                        sched: SchedEdit::parse(&j.sched),
                        realtime: j.realtime,
                        bw: BwEdit::parse(&j.bw),
                        excludes: j.excludes.clone(),
                        enabled: j.enabled,
                        error: String::new(),
                    });
                }
            }
            2 => {
                let s = sh.clone();
                let n2 = n.clone();
                app.ask_confirm(
                    tr("Supprimer la sauvegarde du PC"),
                    &tf("« {0} » ne sera plus lancée. Les fichiers déjà envoyés restent sur le NAS.", &[&n]),
                    tr("Supprimer"),
                    true,
                    None,
                    Box::new(move |_| {
                        let mut g = lock(&s);
                        g.saved.jobs.retain(|j| j.name != n2);
                        g.saved.last.remove(&n2);
                        g.saved.estimates.remove(&n2);
                        g.queue.retain(|(x, _)| *x != n2);
                        g.dirty.remove(&n2);
                        g.retry.remove(&n2);
                        g.save();
                    }),
                );
            }
            _ => {
                if let Some(j) = saved.jobs.iter().find(|j| j.name == n).cloned() {
                    start_estimate(app, j);
                }
            }
        }
    }
    ui.add_space(6.0);

    egui::CollapsingHeader::new(tr("Journal (derniers événements)")).id_salt("pcbjournal").show(ui, |ui| {
        let g = lock(&sh);
        ui.label(RichText::new(tf("Journal complet : {0}", &[&(log_path().display())])).small().weak());
        for l in g.live.log.iter().rev().take(80) {
            ui.label(RichText::new(l).monospace().size(12.0));
        }
    });
    card(ui, tr("Historique"), |ui| {
        if saved.history.is_empty() {
            ui.label(RichText::new(tr("Aucune sauvegarde du PC pour l'instant.")).weak());
        }
        egui::Grid::new("pcbhist").striped(true).num_columns(5).spacing([12.0, 4.0]).show(ui, |ui| {
            for r in saved.history.iter().rev().take(40) {
                dot(ui, if r.ok { OK } else { ERR });
                ui.label(RichText::new(fmt::date_full(r.start)).small());
                ui.label(RichText::new(&r.name).small().strong());
                ui.label(RichText::new(trigger_text(&r.trigger)).small().weak());
                ui.label(RichText::new(&r.detail).small());
                ui.end_row();
            }
        });
    });
}

/// Fenetre du formulaire
pub fn form_window(app: &mut App, ctx: &egui::Context) {
    let Some(mut f) = app.pcbackup.form.take() else { return };
    let mut open = true;
    let mut save = false;
    let mut cancel = false;
    let mut browse = false;
    let mut est = false;
    let syno_set = app.settings.syno.is_set();
    let sh = app.pcbackup.sh.clone();
    let (estimating, est_res) = {
        let g = lock(&sh);
        (g.estimating.clone(), g.saved.estimates.get(&format!("\u{1}{}", f.name)).cloned())
    };
    egui::Window::new(RichText::new(if f.new { tr("Nouvelle sauvegarde du PC") } else { tr("Modifier la sauvegarde du PC") }).strong())
        .id(egui::Id::unique("pcbform"))
        .collapsible(false)
        .resizable(false)
        .default_width(640.0)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            egui::ScrollArea::vertical().max_height((ctx.content_rect().height() - 160.0).max(200.0)).show(ui, |ui| {
                egui::Grid::new("pcbgrid").num_columns(2).spacing([12.0, 10.0]).show(ui, |ui| {
                    ui.label(tr("Nom"));
                    ui.add(egui::TextEdit::singleline(&mut f.name).hint_text(tr("ex : Documents du PC")).desired_width(300.0));
                    ui.end_row();

                    ui.label(tr("Dossiers du PC"));
                    ui.vertical(|ui| {
                        let mut remove = None;
                        for (i, d) in f.dirs.iter().enumerate() {
                            ui.horizontal(|ui| {
                                ui.label(RichText::new(d).monospace());
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
                        ui.horizontal_wrapped(|ui| {
                            if ui.button(tr("\u{E24A} Ajouter un dossier…")).clicked() {
                                if let Some(p) = rfd::FileDialog::new().pick_folder() {
                                    let p = p.display().to_string();
                                    if !f.dirs.contains(&p) {
                                        f.dirs.push(p);
                                    }
                                }
                            }
                            for (sub, lab) in [("Documents", tr("Documents")), ("Desktop", tr("Bureau")), ("Pictures", tr("Images")), ("Music", tr("Musique")), ("Videos", tr("Vidéos"))] {
                                if let Some(p) = user_dir(sub) {
                                    if !f.dirs.contains(&p) && ui.small_button(format!("+ {lab}")).clicked() {
                                        f.dirs.push(p);
                                    }
                                }
                            }
                        });
                        if f.dirs.len() > 1 {
                            ui.label(RichText::new(tr("Chaque dossier est envoyé dans un sous-dossier de son nom.")).small().weak());
                        }
                    });
                    ui.end_row();

                    ui.label(tr("NAS"));
                    ui.vertical(|ui| {
                        ui.horizontal(|ui| {
                            ui.radio_value(&mut f.host_kind, "omv".to_string(), format!("OMV / Debian ({})", app.settings.omv.target()));
                            if syno_set {
                                ui.radio_value(&mut f.host_kind, "syno".to_string(), format!("Synology ({})", app.settings.syno.target()));
                            }
                        });
                        if f.host_kind == "syno" {
                            ui.label(RichText::new(tr("Synology : activer le service SFTP (DSM > Panneau de configuration > Services de fichiers > FTP > SFTP).")).small().weak());
                        }
                    });
                    ui.end_row();

                    ui.label(tr("Dossier sur le NAS"));
                    ui.horizontal(|ui| {
                        ui.add(egui::TextEdit::singleline(&mut f.dest).hint_text("/srv/dev-disk-by-uuid-…/Sauvegardes/PC").desired_width(330.0));
                        if ui.button(tr("\u{E24A} Parcourir")).clicked() {
                            browse = true;
                        }
                    });
                    ui.end_row();

                    ui.label(tr("Mode"));
                    ui.vertical(|ui| {
                        ui.radio_value(&mut f.mode, 0, tr("Copie : les fichiers supprimés du PC restent sur le NAS"));
                        ui.radio_value(&mut f.mode, 1, tr("Miroir : le NAS suit le PC (suppressions comprises)"));
                        if f.mode == 1 {
                            ui.horizontal(|ui| {
                                ui.add_space(24.0);
                                ui.label(tr("Corbeille sur le NAS :"));
                                ui.add(egui::TextEdit::singleline(&mut f.trash_days).desired_width(44.0));
                                ui.label(tr("jours (0 = suppression directe)"));
                            });
                        }
                    });
                    ui.end_row();

                    ui.label(tr("Horaire"));
                    f.sched.ui(ui);
                    ui.end_row();

                    ui.label(tr("Temps réel"));
                    ui.vertical(|ui| {
                        ui.checkbox(&mut f.realtime, tr("Envoyer aussi chaque changement au fil de l'eau"));
                        ui.label(RichText::new(tf("Envoi {0} s après le dernier changement (au plus tard 10 min), application ouverte.", &[&RT_QUIET])).small().weak());
                    });
                    ui.end_row();

                    ui.label(tr("Limite de débit"));
                    f.bw.ui(ui);
                    ui.end_row();

                    ui.label(tr("Exclusions"));
                    ui.vertical(|ui| {
                        ui.add(egui::TextEdit::singleline(&mut f.excludes).hint_text("node_modules/** ; *.iso ; Jeux/**").desired_width(330.0));
                        ui.label(RichText::new(tr("Motifs séparés par « ; » (fichiers temporaires et système déjà exclus).")).small().weak());
                    });
                    ui.end_row();

                    ui.label("");
                    ui.checkbox(&mut f.enabled, tr("Active"));
                    ui.end_row();
                });
                ui.add_space(6.0);
                ui.horizontal_wrapped(|ui| {
                    if estimating.is_some() {
                        ui.spinner();
                        ui.label(tr("Estimation…"));
                    } else if ui.button(tr("Estimer la première sauvegarde")).on_hover_text(tr("Volume des dossiers et débit réel vers le NAS (envoi d'un fichier de test de 16 Mo)")).clicked() {
                        est = true;
                    }
                    if let Some(e) = &est_res {
                        ui.label(RichText::new(estimate_text(e)).small());
                    }
                });
                if !f.error.is_empty() {
                    ui.colored_label(ERR, &f.error);
                }
                ui.add_space(4.0);
                ui.horizontal(|ui| {
                    if primary_button(ui, tr("Enregistrer")).clicked() {
                        save = true;
                    }
                    if ui.button(tr("Annuler")).clicked() {
                        cancel = true;
                    }
                });
            });
        });
    let built = build_job(app, &f);
    if est {
        match &built {
            Ok(j) => {
                let mut j = j.clone();
                // resultat range sous un nom technique tant que la sauvegarde n'existe pas
                j.name = format!("\u{1}{}", f.name);
                start_estimate(app, j);
            }
            Err(e) => f.error = e.clone(),
        }
    }
    if browse {
        let h = if f.host_kind == "syno" { HostId::Syno } else { HostId::Omv };
        let start = if f.dest.trim().is_empty() { String::new() } else { f.dest.clone() };
        app.pcbackup.form = Some(f);
        app.open_browser(h, BrowsePurpose::PcDest, &start);
        return;
    }
    if save {
        match built {
            Ok(mut j) => {
                let mut g = lock(&sh);
                if g.saved.jobs.iter().any(|x| x.name.eq_ignore_ascii_case(&j.name) && (f.new || x.name != f.orig)) {
                    f.error = tr("Une sauvegarde du PC porte déjà ce nom.").into();
                    drop(g);
                    app.pcbackup.form = Some(f);
                    return;
                }
                if let Some(e) = g.saved.estimates.remove(&format!("\u{1}{}", f.name)) {
                    g.saved.estimates.insert(j.name.clone(), e);
                }
                if f.new {
                    j.created = fmt::now();
                    g.saved.jobs.push(j);
                } else if let Some(x) = g.saved.jobs.iter_mut().find(|x| x.name == f.orig) {
                    j.created = x.created;
                    *x = j.clone();
                    if f.orig != j.name {
                        if let Some(r) = g.saved.last.remove(&f.orig) {
                            g.saved.last.insert(j.name.clone(), r);
                        }
                        if let Some(e) = g.saved.estimates.remove(&f.orig) {
                            g.saved.estimates.insert(j.name.clone(), e);
                        }
                    }
                }
                g.saved.jobs.sort_by_key(|j| j.name.to_lowercase());
                g.save();
                return;
            }
            Err(e) => f.error = e,
        }
    }
    if open && !cancel {
        app.pcbackup.form = Some(f);
    } else {
        // formulaire ferme sans enregistrer : estimation provisoire oubliee
        lock(&sh).saved.estimates.retain(|k, _| !k.starts_with('\u{1}'));
    }
}

/// Sauvegarde decrite par le formulaire, ou message d'erreur
fn build_job(app: &App, f: &PcForm) -> Result<PcJob, String> {
    let name = f.name.trim();
    if name.is_empty() || name.len() > 40 || name.contains(['|', '/', '\\', '\u{1}']) {
        return Err(tr("Nom invalide (40 caractères au plus, sans / \\ |).").into());
    }
    if f.dirs.is_empty() {
        return Err(tr("Choisis au moins un dossier du PC.").into());
    }
    if let Some(d) = f.dirs.iter().find(|d| !Path::new(d.as_str()).is_dir()) {
        return Err(tf("Dossier introuvable : {0}", &[d]));
    }
    let dest = f.dest.trim().trim_end_matches('/').to_string();
    if !dest.starts_with('/') || dest.contains("..") || dest.len() < 2 {
        return Err(tr("Dossier sur le NAS : chemin complet, ex. /srv/dev-disk-by-uuid-…/Sauvegardes/PC.").into());
    }
    let cfg = host_cfg(app, &f.host_kind);
    if !cfg.is_set() {
        return Err(tr("NAS non configuré (Paramètres).").into());
    }
    if !app.ssh.host_known(&cfg) {
        return Err(tr("Identité du NAS non confirmée : connecte-toi d'abord une fois au NAS depuis l'application.").into());
    }
    let trash: u32 = if f.mode == 1 { f.trash_days.trim().parse().map_err(|_| tr("Corbeille : nombre de jours invalide.").to_string())? } else { 0 };
    if trash > 3650 {
        return Err(tr("Corbeille : nombre de jours invalide.").into());
    }
    let sched = f.sched.build()?;
    let bw = f.bw.build()?;
    if sched == "manuel" && !f.realtime && f.enabled {
        // autorise : lancement a la main seulement
    }
    Ok(PcJob {
        name: name.to_string(),
        dirs: f.dirs.clone(),
        host_kind: f.host_kind.clone(),
        host: cfg.host.trim().to_string(),
        port: cfg.port,
        user: cfg.user.trim().to_string(),
        dest,
        mode: if f.mode == 1 { "miroir".into() } else { "copie".into() },
        trash_days: trash,
        sched,
        realtime: f.realtime,
        bw,
        excludes: f.excludes.trim().to_string(),
        enabled: f.enabled,
        created: 0,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chemins() {
        assert_eq!(dir_label("C:\\Users\\moi\\Documents"), "Documents");
        assert_eq!(dir_label("D:\\"), "D");
        assert_eq!(dir_label("/home/moi/Photos/"), "Photos");
        assert_eq!(labels(&["/a/Photos".into(), "/b/photos".into(), "/c/Docs".into()]), vec!["Photos", "photos (2)", "Docs"]);
        assert_eq!(sftp_path("syno", "/volume1/Sauvegardes/PC/"), "/Sauvegardes/PC");
        assert_eq!(sftp_path("syno", "/volume12"), "/");
        assert_eq!(sftp_path("syno", "/volumeX/a"), "/volumeX/a");
        assert_eq!(sftp_path("omv", "/srv/dev-disk-by-uuid-1/PC"), "/srv/dev-disk-by-uuid-1/PC");
        let j = PcJob { dest: "/srv/x/PC/".into(), ..Default::default() };
        assert_eq!(nas(&j, "Documents"), "nas:/srv/x/PC/Documents");
        assert_eq!(nas(&j, ""), "nas:/srv/x/PC");
        assert!(unreachable_msg("couldn't connect SSH: dial tcp 1.2.3.4:22: connect: connection refused"));
        assert!(!unreachable_msg("permission denied"));
    }

    #[test]
    fn creneaux() {
        use chrono::{Local, TimeZone};
        let ts = |d: u32, h: u32, m: u32| Local.with_ymd_and_hms(2026, 10, d, h, m, 0).earliest().unwrap().timestamp();
        // jeudi 29 octobre 2026, 10:00
        let now = ts(29, 10, 0);
        assert_eq!(last_due("12:30", now), Some(ts(28, 12, 30)));
        assert_eq!(last_due("03:30;12:30", now), Some(ts(29, 3, 30)));
        // lundi et mercredi seulement
        assert_eq!(last_due("09:00/13", now), Some(ts(28, 9, 0)));
        assert_eq!(last_due("10:00", now), Some(ts(29, 10, 0)));
        assert_eq!(last_due("manuel", now), None);
        let e = Estimate { files: 100, bytes: 10_000_000, speed: 1_000_000.0, ..Default::default() };
        assert_eq!(e.eta(), Some(12));
    }

    /// Contre le faux NAS (sshd local, tests/faux-nas.sh) : NAS_MANAGER_LIVE_TEST=1
    #[test]
    fn pc_live() {
        if std::env::var("NAS_MANAGER_LIVE_TEST").is_err() || std::env::var("NAS_MANAGER_DIR").is_err() {
            return;
        }
        let Some((rc, _)) = ["/usr/bin/rclone"].iter().map(PathBuf::from).find(|p| p.exists()).map(|p| (p, String::new())).or_else(find_rclone) else { return };
        let w = std::env::temp_dir().join(format!("pcbackup-{}", std::process::id()));
        let (src, dst) = (w.join("Documents"), w.join("nas"));
        let _ = std::fs::remove_dir_all(&w);
        std::fs::create_dir_all(src.join("sous")).unwrap();
        std::fs::create_dir_all(&dst).unwrap();
        std::fs::write(src.join("a.txt"), "bonjour").unwrap();
        std::fs::write(src.join("sous/b.bin"), vec![3u8; 200_000]).unwrap();
        std::fs::write(src.join("~$brouillon.docx"), "x").unwrap();
        let j = PcJob {
            name: "Test".into(),
            dirs: vec![src.display().to_string()],
            host: "127.0.0.1".into(),
            port: 2222,
            user: "root".into(),
            dest: dst.join("PC").display().to_string(),
            mode: "miroir".into(),
            trash_days: 30,
            ..Default::default()
        };
        let sh: Sh = Arc::new(Mutex::new(Shared::default()));
        let r = run_job(&sh, &rc, &j, "manuelle");
        assert!(r.ok, "{r:?} {:?}", lock(&sh).live.log);
        assert_eq!(r.files, 2, "{r:?}");
        assert_eq!(std::fs::read_to_string(dst.join("PC/Documents/a.txt")).unwrap(), "bonjour");
        assert!(!dst.join("PC/Documents/~$brouillon.docx").exists());
        // miroir : fichier supprime du PC -> corbeille datee du NAS
        std::fs::remove_file(src.join("a.txt")).unwrap();
        let r = run_job(&sh, &rc, &j, "programmée");
        assert!(r.ok, "{r:?}");
        assert!(!dst.join("PC/Documents/a.txt").exists());
        let trash: Vec<_> = std::fs::read_dir(dst.join("PC").join(TRASH)).unwrap().flatten().collect();
        assert_eq!(trash.len(), 1);
        assert!(trash[0].path().join("Documents/a.txt").exists());
        // rien de change : deja a jour
        let r = run_job(&sh, &rc, &j, "temps réel");
        assert!(r.ok && r.files == 0, "{r:?}");
        // estimation : volume et debit mesure
        let e = estimate(Some(&rc), &j);
        assert_eq!((e.files, e.bytes), (1, 200_000), "{e:?}");
        assert!(e.speed > 0.0 && e.error.is_empty(), "{e:?}");
        assert!(!dst.join("PC/.nas-manager-test-debit.bin").exists());
        // NAS injoignable
        let bad = PcJob { port: 2299, ..j.clone() };
        let r = run_job(&sh, &rc, &bad, "programmée");
        assert!(!r.ok && r.unreachable, "{r:?}");
        let _ = std::fs::remove_dir_all(&w);
    }
}
