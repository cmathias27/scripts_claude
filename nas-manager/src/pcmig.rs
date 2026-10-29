//! Migration vers oCIS depuis un disque de ce PC (étape 6) : rclone tourne ici, sur le PC,
//! et envoie le dossier dans un espace oCIS par son accès WebDAV, comme le font les scripts
//! des NAS. File d'attente gardée dans migration-pc.json (reprise au prochain lancement si
//! l'application est fermée en cours de route), contrôle et suppression des originaux en
//! option, bilan, notifications. Le PC est tenu éveillé pendant la migration (Windows).

use crate::app::App;
use crate::config::app_dir;
use crate::fmt;
#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::model::Space;
use crate::pages::{badge, banner, card, danger_button, dot, progress_bar};
use crate::theme::{ERR, INFO, OK, WARN};
use eframe::egui::{self, Color32, RichText};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Exclusions (fichiers systeme de Windows / macOS, jamais utiles dans oCIS)
const EXCL: &[&str] = &["Thumbs.db", "desktop.ini", ".DS_Store", "~$*", "$RECYCLE.BIN/**", "System Volume Information/**"];
/// relances automatiques si rclone s'arrete en cours de transfert
const REPRISES: u32 = 5;

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

// =====================================================================
//  Donnees gardees (migration-pc.json)
// =====================================================================

#[derive(Serialize, Deserialize, Clone, Default, Debug)]
#[serde(default)]
pub struct PcConf {
    pub url: String,
    pub user: String,
    /// jeton d'application (chiffre DPAPI sous Windows)
    pub token: String,
    /// adresse locale d'oCIS pour les transferts (vide = l'adresse publique)
    pub local: String,
    pub insecure: bool,
    /// owncloud (WebDAV classique) ou infinitescale
    pub vendor: String,
}

impl PcConf {
    fn secret(&self) -> String {
        match self.token.strip_prefix("clair:") {
            Some(t) => t.to_string(),
            None => crate::secret::unprotect(&self.token).unwrap_or_default(),
        }
    }
    fn store_secret(t: &str) -> String {
        crate::secret::protect(t).unwrap_or_else(|| format!("clair:{t}"))
    }
    /// adresse utilisee pour les transferts
    fn base(&self) -> String {
        let b = if self.local.trim().is_empty() { &self.url } else { &self.local };
        b.trim().trim_end_matches('/').to_string()
    }
}

#[derive(Serialize, Deserialize, Clone, Default, Debug)]
#[serde(default)]
pub struct PcItem {
    pub src: String,
    pub label: String,
    pub space_id: String,
    pub space_name: String,
    pub dav: String,
    pub sub: String,
    /// 0 garder les originaux, 1 controler puis supprimer, 2 controle seul (deja migre)
    pub delete: u8,
    pub files: u64,
    pub total: u64,
}

#[derive(Serialize, Deserialize, Clone, Default, Debug)]
#[serde(default)]
pub struct PcResult {
    pub label: String,
    pub space: String,
    pub ok: bool,
    pub detail: String,
}

#[derive(Serialize, Deserialize, Clone, Default, Debug)]
#[serde(default)]
pub struct Saved {
    pub conf: Option<PcConf>,
    pub queue: Vec<PcItem>,
    /// une migration tournait quand l'application a ete fermee : reprise au lancement
    pub resume: bool,
    pub results: Vec<PcResult>,
    pub history: Vec<String>,
}

fn state_path() -> PathBuf {
    app_dir().join("migration-pc.json")
}

fn log_path() -> PathBuf {
    app_dir().join("migration-pc.log")
}

// =====================================================================
//  Etat partage avec les fils de travail
// =====================================================================

#[derive(Clone, Default, Debug, PartialEq)]
pub struct Stats {
    pub bytes: u64,
    pub total_bytes: u64,
    pub transfers: u64,
    pub total_transfers: u64,
    pub checks: u64,
    pub speed: f64,
    pub eta: Option<i64>,
    pub errors: u64,
}

#[derive(Default)]
pub struct Live {
    pub running: bool,
    pub stop: bool,
    pub item: Option<PcItem>,
    pub step: usize,
    pub count: usize,
    /// transfert, verification, relecture, suppression, renvoi, bilan
    pub phase: String,
    pub stats: Option<Stats>,
    pub attempt: u32,
    pub started: i64,
    pub log: VecDeque<String>,
}

#[derive(Default)]
pub struct Shared {
    pub saved: Saved,
    pub live: Live,
    pub spaces: Vec<(Space, String)>,
    pub spaces_busy: bool,
    pub spaces_err: String,
    pub conf_busy: bool,
    pub conf_msg: Option<(bool, String)>,
    pub rclone: Option<(PathBuf, String)>,
    pub rclone_checked: bool,
    pub rclone_busy: bool,
    pub rclone_err: String,
    pub sizing: Option<String>,
    pub ctx: Option<egui::Context>,
    pub notify: bool,
    /// etat garde dans migration-pc.json (pas dans les tests)
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
            let _ = std::fs::write(&p, t);
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600));
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
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(log_path()) {
            let _ = writeln!(f, "{line}");
        }
        self.live.log.push_back(line);
        while self.live.log.len() > 300 {
            self.live.log.pop_front();
        }
    }
}

type Sh = Arc<Mutex<Shared>>;

fn lock(sh: &Sh) -> std::sync::MutexGuard<'_, Shared> {
    sh.lock().unwrap_or_else(|e| e.into_inner())
}

/// Formulaire d'ajout et de connexion (cote interface)
#[derive(Default)]
pub struct PcMig {
    pub sh: Sh,
    pub src: String,
    pub label: String,
    pub space: Option<String>,
    pub sub: String,
    pub del_mode: u8,
    pub conf_open: bool,
    pub url: String,
    pub user: String,
    pub token: String,
    pub local: String,
    pub insecure: bool,
    started: bool,
}

impl PcMig {
    pub fn load() -> Self {
        let saved = std::fs::read_to_string(state_path()).ok().and_then(|t| serde_json::from_str::<Saved>(&t).ok()).unwrap_or_default();
        let sh = Shared { saved, persist: true, ..Default::default() };
        PcMig { sh: Arc::new(Mutex::new(sh)), ..Default::default() }
    }
}

pub fn running(app: &App) -> bool {
    lock(&app.pcmig.sh).live.running
}

// =====================================================================
//  Outils : rclone, curl
// =====================================================================

pub(crate) fn command(p: impl AsRef<std::ffi::OsStr>) -> Command {
    #[allow(unused_mut)]
    let mut c = Command::new(p);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(CREATE_NO_WINDOW);
    }
    c
}

fn exe(name: &str) -> String {
    if cfg!(windows) {
        format!("{name}.exe")
    } else {
        name.to_string()
    }
}

/// rclone de l'application (telecharge), sinon NAS_MANAGER_RCLONE, sinon celui du systeme
pub fn find_rclone() -> Option<(PathBuf, String)> {
    let mut cands = vec![app_dir().join("bin").join(exe("rclone"))];
    if let Ok(p) = std::env::var("NAS_MANAGER_RCLONE") {
        cands.insert(0, PathBuf::from(p));
    }
    cands.push(PathBuf::from(exe("rclone")));
    for c in cands {
        if let Ok(o) = command(&c).arg("version").stdin(Stdio::null()).output() {
            if o.status.success() {
                let v = String::from_utf8_lossy(&o.stdout).lines().next().unwrap_or("").to_string();
                return Some((c, v));
            }
        }
    }
    None
}

/// Telecharge rclone (Windows) dans le dossier de l'application, avec curl.exe et tar.exe
pub(crate) fn download_rclone() -> Result<(), String> {
    let bin = app_dir().join("bin");
    let tmp = bin.join("telechargement");
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).map_err(|e| e.to_string())?;
    let arch = if cfg!(target_arch = "aarch64") { "arm64" } else { "amd64" };
    let os = if cfg!(windows) {
        "windows"
    } else if cfg!(target_os = "macos") {
        "osx"
    } else {
        "linux"
    };
    let url = format!("https://downloads.rclone.org/rclone-current-{os}-{arch}.zip");
    let zip = tmp.join("rclone.zip");
    let o = command("curl").args(["-fsSL", "--retry", "2", "-o"]).arg(&zip).arg(&url).output().map_err(|e| tf("curl introuvable : {0}", &[&e]))?;
    if !o.status.success() {
        return Err(tf("Téléchargement impossible : {0}", &[&(String::from_utf8_lossy(&o.stderr).trim())]));
    }
    let o = command("tar").arg("-xf").arg(&zip).arg("-C").arg(&tmp).output().map_err(|e| tf("tar introuvable : {0}", &[&e]))?;
    if !o.status.success() {
        return Err(tf("Archive illisible : {0}", &[&(String::from_utf8_lossy(&o.stderr).trim())]));
    }
    let found = std::fs::read_dir(&tmp)
        .map_err(|e| e.to_string())?
        .flatten()
        .map(|e| e.path().join(exe("rclone")))
        .find(|p| p.exists())
        .ok_or_else(|| tr("rclone absent de l'archive").to_string())?;
    let dst = bin.join(exe("rclone"));
    std::fs::rename(&found, &dst).or_else(|_| std::fs::copy(&found, &dst).map(|_| ())).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dst, std::fs::Permissions::from_mode(0o755));
    }
    let _ = std::fs::remove_dir_all(&tmp);
    Ok(())
}

/// Appel de l'API d'oCIS avec curl (le jeton passe par l'entree standard, pas la ligne de commande)
fn api_get(base: &str, user: &str, token: &str, insecure: bool, path: &str) -> Result<(u16, String), String> {
    let esc = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"");
    let mut c = command("curl");
    c.args(["-sS", "--max-time", "30", "-K", "-", "-w", "\n%{http_code}"]);
    if insecure {
        c.arg("-k");
    }
    c.arg(format!("{base}{path}"));
    let mut ch = c.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|e| tf("curl introuvable : {0}", &[&e]))?;
    if let Some(mut i) = ch.stdin.take() {
        let _ = writeln!(i, "user = \"{}:{}\"", esc(user), esc(token));
    }
    let o = ch.wait_with_output().map_err(|e| e.to_string())?;
    let out = String::from_utf8_lossy(&o.stdout).to_string();
    let (body, code) = out.rsplit_once('\n').unwrap_or(("", out.as_str()));
    let code = code.trim().parse::<u16>().unwrap_or(0);
    if code == 0 {
        return Err(tf("oCIS injoignable : {0}", &[&(String::from_utf8_lossy(&o.stderr).trim())]));
    }
    Ok((code, body.to_string()))
}

/// Remplace le debut (schema et hote) de l'adresse WebDAV donnee par oCIS par l'adresse utilisee
pub fn to_base(dav: &str, base: &str) -> String {
    let rest = dav.split_once("://").map(|(_, r)| r).unwrap_or(dav);
    let path = rest.find('/').map(|i| &rest[i..]).unwrap_or("");
    format!("{}{path}", base.trim_end_matches('/'))
}

/// Espaces (personnel en premier, puis projets) : (espace, adresse WebDAV)
pub fn parse_drives(body: &str) -> Vec<(Space, String)> {
    let v: serde_json::Value = serde_json::from_str(body).unwrap_or_default();
    let mut out: Vec<(Space, String)> = Vec::new();
    for d in v["value"].as_array().cloned().unwrap_or_default() {
        let kind = d["driveType"].as_str().unwrap_or("");
        if kind != "personal" && kind != "project" {
            continue;
        }
        let quota = d["quota"]["total"].as_i64().unwrap_or(0);
        let sp = Space {
            id: d["id"].as_str().unwrap_or("").to_string(),
            name: d["name"].as_str().unwrap_or("").to_string(),
            free: d["quota"]["remaining"].as_i64().unwrap_or(-1),
            quota,
            kind: kind.to_string(),
        };
        let dav = d["root"]["webDavUrl"].as_str().unwrap_or("").to_string();
        if !sp.id.is_empty() && !dav.is_empty() {
            out.push((sp, dav));
        }
    }
    out.sort_by_key(|(s, _)| (s.kind != "personal", s.name.to_lowercase()));
    out
}

pub fn fetch_spaces(c: &PcConf) -> Result<Vec<(Space, String)>, String> {
    let (code, body) = api_get(&c.url, &c.user, &c.secret(), c.insecure, "/graph/v1.0/me/drives")?;
    match code {
        200 => Ok(parse_drives(&body)),
        401 => Err(tr("Jeton refusé (401) : vérifie le compte et le jeton d'application.").into()),
        _ => Err(tf("Réponse inattendue d'oCIS (HTTP {0})", &[&code])),
    }
}

fn obscure(rclone: &Path, secret: &str) -> Result<String, String> {
    let mut ch = command(rclone).args(["obscure", "-"]).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().map_err(|e| e.to_string())?;
    if let Some(mut i) = ch.stdin.take() {
        let _ = i.write_all(secret.as_bytes());
    }
    let o = ch.wait_with_output().map_err(|e| e.to_string())?;
    let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
    if s.is_empty() {
        Err(tr("rclone obscure a échoué").into())
    } else {
        Ok(s)
    }
}

/// Commande rclone avec le distant « ocis: » (espace donne) dans l'environnement
fn rclone_cmd(rclone: &Path, c: &PcConf, obs: &str, dav: &str, vendor: &str) -> Command {
    let mut cmd = command(rclone);
    let cfg = app_dir().join("rclone-pc.conf");
    if !cfg.exists() {
        let _ = std::fs::write(&cfg, "");
    }
    cmd.env("RCLONE_CONFIG", cfg)
        .env("RCLONE_CONFIG_OCIS_TYPE", "webdav")
        .env("RCLONE_CONFIG_OCIS_URL", to_base(dav, &c.base()))
        .env("RCLONE_CONFIG_OCIS_VENDOR", vendor)
        .env("RCLONE_CONFIG_OCIS_USER", &c.user)
        .env("RCLONE_CONFIG_OCIS_PASS", obs)
        .stdin(Stdio::null());
    if c.insecure {
        cmd.arg("--no-check-certificate");
    }
    cmd
}

/// Teste la connexion puis un vrai envoi dans l'espace personnel (WebDAV classique d'abord) :
/// renvoie le mode qui marche
pub fn test_conf(rclone: &Path, c: &PcConf) -> Result<String, String> {
    let spaces = fetch_spaces(c)?;
    if !c.local.trim().is_empty() {
        let (code, _) = api_get(c.local.trim().trim_end_matches('/'), &c.user, &c.secret(), c.insecure, "/graph/v1.0/me/drives").map_err(|e| tf("Adresse locale : {0}", &[&e]))?;
        if code != 200 {
            return Err(tf("L'adresse locale ne répond pas correctement (HTTP {0}).", &[&code]));
        }
    }
    let dav = spaces
        .iter()
        .find(|(s, _)| s.kind == "personal")
        .map(|(_, d)| d.clone())
        .ok_or_else(|| tr("Espace personnel du compte introuvable : test d'envoi impossible.").to_string())?;
    let obs = obscure(rclone, &c.secret())?;
    let tmp = std::env::temp_dir().join(format!("nas-manager-test-{}.txt", std::process::id()));
    std::fs::write(&tmp, format!("test migration {}", fmt::now())).map_err(|e| e.to_string())?;
    let mut ok = None;
    for v in ["owncloud", "infinitescale"] {
        let st = rclone_cmd(rclone, c, &obs, &dav, v).arg("copyto").arg(&tmp).arg("ocis:.test-migration-pc.txt").args(["--retries", "1", "-q"]).stderr(Stdio::null()).status();
        if st.map(|s| s.success()).unwrap_or(false) {
            let _ = rclone_cmd(rclone, c, &obs, &dav, v).args(["deletefile", "ocis:.test-migration-pc.txt", "-q"]).stderr(Stdio::null()).status();
            ok = Some(v.to_string());
            break;
        }
    }
    let _ = std::fs::remove_file(&tmp);
    ok.ok_or_else(|| tr("Le test d'envoi a échoué : vérifie les droits du compte et l'adresse d'oCIS.").into())
}

/// Ligne JSON de rclone (--use-json-log) : statistiques eventuelles et message
pub fn parse_json_line(l: &str) -> (Option<Stats>, Option<(String, String)>) {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(l) else {
        return (None, Some(("notice".into(), l.to_string())));
    };
    let st = v.get("stats").map(|s| Stats {
        bytes: s["bytes"].as_u64().unwrap_or(0),
        total_bytes: s["totalBytes"].as_u64().unwrap_or(0),
        transfers: s["transfers"].as_u64().unwrap_or(0),
        total_transfers: s["totalTransfers"].as_u64().unwrap_or(0),
        checks: s["checks"].as_u64().unwrap_or(0),
        speed: s["speed"].as_f64().unwrap_or(0.0),
        eta: s["eta"].as_i64(),
        errors: s["errors"].as_u64().unwrap_or(0),
    });
    let msg = if st.is_some() {
        None
    } else {
        let obj = v["object"].as_str().unwrap_or("");
        let m = v["msg"].as_str().unwrap_or("").trim();
        Some((v["level"].as_str().unwrap_or("").to_string(), if obj.is_empty() { m.to_string() } else { format!("{obj} : {m}") }))
    };
    (st, msg)
}

/// Taille d'un dossier (fichiers, octets), memes exclusions que rclone (a peu pres)
pub fn dir_size(p: &Path) -> (u64, u64) {
    let mut n = 0;
    let mut b = 0;
    let mut stack = vec![p.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() {
                if name != "$RECYCLE.BIN" && name != "System Volume Information" {
                    stack.push(e.path());
                }
            } else if ft.is_file() && name != "Thumbs.db" && name != "desktop.ini" && name != ".DS_Store" && !name.starts_with("~$") {
                n += 1;
                b += e.metadata().map(|m| m.len()).unwrap_or(0);
            }
        }
    }
    (n, b)
}

/// rclone lance par une session precedente de l'application (fermee brutalement) : arrete
/// avant de reprendre, pour ne pas avoir deux envois en parallele
fn kill_orphan() {
    let pf = app_dir().join("migration-pc.pid");
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

fn read_list(p: &Path) -> Vec<String> {
    std::fs::read_to_string(p).map(|t| t.lines().filter(|l| !l.is_empty()).map(String::from).collect()).unwrap_or_default()
}

// =====================================================================
//  Moteur
// =====================================================================

enum Outcome {
    Ok(String),
    Failed(String),
    Stopped,
}

/// Lance rclone, suit ses statistiques ; renvoie (code, erreurs du journal, tous les messages)
fn run_rclone(sh: &Sh, mut cmd: Command) -> (i32, Vec<String>, Vec<String>) {
    cmd.args(["--use-json-log", "--stats", "2s", "--stats-log-level", "NOTICE", "--log-level", "NOTICE"]).stdout(Stdio::null()).stderr(Stdio::piped());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return (-1, vec![e.to_string()], Vec::new()),
    };
    let pf = app_dir().join("migration-pc.pid");
    let _ = std::fs::write(&pf, child.id().to_string());
    let errs = Arc::new(Mutex::new(Vec::<String>::new()));
    let all = Arc::new(Mutex::new(Vec::<String>::new()));
    let reader = child.stderr.take().map(|se| {
        let (sh, errs, all) = (sh.clone(), errs.clone(), all.clone());
        std::thread::spawn(move || {
            for l in BufReader::new(se).lines().map_while(Result::ok) {
                let (st, msg) = parse_json_line(&l);
                let mut g = lock(&sh);
                if let Some(st) = st {
                    g.live.stats = Some(st);
                    g.repaint();
                }
                if let Some((lvl, m)) = msg {
                    if m.is_empty() {
                        continue;
                    }
                    all.lock().unwrap_or_else(|e| e.into_inner()).push(m.clone());
                    if lvl == "error" || lvl == "critical" {
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
    let a = all.lock().unwrap_or_else(|e| e.into_inner()).clone();
    (code, e, a)
}

fn excl(cmd: &mut Command) {
    for e in EXCL {
        cmd.args(["--exclude", e]);
    }
}

fn set_phase(sh: &Sh, p: &str) {
    let mut g = lock(sh);
    g.live.phase = p.to_string();
    g.live.stats = None;
    g.repaint();
}

fn copy_pass(sh: &Sh, rc: &Path, c: &PcConf, obs: &str, it: &PcItem, files_from: Option<&Path>) -> Result<(), Outcome> {
    let mut last = String::new();
    for attempt in 1..=REPRISES + 1 {
        lock(sh).live.attempt = attempt - 1;
        let mut cmd = rclone_cmd(rc, c, obs, &it.dav, &c.vendor);
        cmd.arg("copy").arg(&it.src).arg(format!("ocis:{}", it.sub));
        excl(&mut cmd);
        cmd.args(["--create-empty-src-dirs", "--transfers", "4", "--checkers", "8", "--retries", "3", "--low-level-retries", "20", "--disable-http2"]);
        if let Some(f) = files_from {
            cmd.arg("--files-from-raw").arg(f).arg("--ignore-times");
        }
        let (code, errs, _) = run_rclone(sh, cmd);
        match code {
            0 => return Ok(()),
            -2 => return Err(Outcome::Stopped),
            _ => {
                last = errs.last().cloned().unwrap_or_else(|| tf("rclone s'est arrêté (code {0})", &[&code]));
                if errs.iter().any(|e| e.contains("401") || e.contains("Unauthorized")) {
                    return Err(Outcome::Failed(tr("Jeton refusé (401) : recrée un jeton et mets à jour la connexion.").into()));
                }
                if errs.iter().any(|e| e.contains("507") || e.to_lowercase().contains("quota")) {
                    return Err(Outcome::Failed(tr("Espace oCIS plein (quota) : agrandis le quota de l'espace.").into()));
                }
                if attempt <= REPRISES {
                    lock(sh).log(&tf("reprise automatique {0}/{1} dans 15 s : {2}", &[&attempt, &REPRISES, &last]));
                    for _ in 0..50 {
                        if lock(sh).live.stop {
                            return Err(Outcome::Stopped);
                        }
                        std::thread::sleep(Duration::from_millis(300));
                    }
                }
            }
        }
    }
    Err(Outcome::Failed(last))
}

/// Controle dans oCIS puis suppression des originaux identiques ; les fichiers en defaut
/// sont renvoyes puis recontroles (2 fois au plus). Renvoie (supprimes, gardes)
fn verify_delete(sh: &Sh, rc: &Path, c: &PcConf, obs: &str, it: &PcItem) -> Result<(u64, u64), Outcome> {
    let d = app_dir().join("verif-pc");
    let _ = std::fs::create_dir_all(&d);
    let mut deleted = 0;
    let mut download = false;
    let mut kept = 0;
    for pass in 0..3 {
        set_phase(sh, if download { "relecture" } else { "verification" });
        for f in ["ok", "diff", "absent", "err"] {
            let _ = std::fs::remove_file(d.join(f));
        }
        let mut cmd = rclone_cmd(rc, c, obs, &it.dav, &c.vendor);
        cmd.arg("check").arg(&it.src).arg(format!("ocis:{}", it.sub)).arg("--one-way");
        excl(&mut cmd);
        cmd.args(["--checkers", "4", "--disable-http2"])
            .arg("--match")
            .arg(d.join("ok"))
            .arg("--differ")
            .arg(d.join("diff"))
            .arg("--missing-on-dst")
            .arg(d.join("absent"))
            .arg("--error")
            .arg(d.join("err"));
        if download {
            cmd.arg("--download");
        }
        let (code, _, msgs) = run_rclone(sh, cmd);
        if code == -2 {
            return Err(Outcome::Stopped);
        }
        // oCIS n'a pas fourni d'empreinte pour tout : la taille seule ne suffit pas pour supprimer
        if !download && msgs.iter().any(|e| e.contains("no common hash") || e.contains("could not be checked")) {
            lock(sh).log(tr("empreintes incomplètes côté oCIS : contrôle par relecture complète"));
            download = true;
            continue;
        }
        let ok = read_list(&d.join("ok"));
        let bad: Vec<String> = ["diff", "absent", "err"].iter().flat_map(|f| read_list(&d.join(f))).collect();
        lock(sh).log(&tf("contrôle : {0} identique(s), {1} en défaut", &[&(ok.len()), &(bad.len())]));
        if !ok.is_empty() {
            set_phase(sh, "suppression");
            let mut cmd = command(rc);
            cmd.env("RCLONE_CONFIG", app_dir().join("rclone-pc.conf")).arg("delete").arg(&it.src).arg("--files-from-raw").arg(d.join("ok")).stdin(Stdio::null());
            let (code, _, _) = run_rclone(sh, cmd);
            if code == 0 {
                deleted += ok.len() as u64;
                let _ = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(app_dir().join("migration-pc-supprimes.txt"))
                    .and_then(|mut f| writeln!(f, "# {} {}\n{}", fmt::date_full(fmt::now()), it.src, ok.join("\n")));
            }
        }
        kept = bad.len() as u64;
        if bad.is_empty() || pass == 2 {
            break;
        }
        set_phase(sh, "renvoi");
        let list = d.join("renvoi");
        let _ = std::fs::write(&list, bad.join("\n"));
        copy_pass(sh, rc, c, obs, it, Some(&list))?;
    }
    // dossiers devenus vides
    let _ = command(rc).env("RCLONE_CONFIG", app_dir().join("rclone-pc.conf")).arg("rmdirs").arg(&it.src).arg("--leave-root").stdin(Stdio::null()).stderr(Stdio::null()).status();
    Ok((deleted, kept))
}

fn process(sh: &Sh, rc: &Path, c: &PcConf, obs: &str, it: &PcItem) -> Outcome {
    if !Path::new(&it.src).is_dir() {
        return Outcome::Failed(tf("dossier source introuvable : {0}", &[&it.src]));
    }
    if it.delete != 2 {
        set_phase(sh, "transfert");
        if let Err(o) = copy_pass(sh, rc, c, obs, it, None) {
            return o;
        }
    }
    let mut detail = String::new();
    if it.delete > 0 {
        match verify_delete(sh, rc, c, obs, it) {
            Ok((del, kept)) => {
                detail = if kept > 0 {
                    tf("{0} original(aux) supprimé(s), {1} gardé(s) (contrôle en défaut)", &[&del, &kept])
                } else {
                    tf("{0} original(aux) contrôlé(s) et supprimé(s)", &[&del])
                };
                if kept > 0 {
                    return Outcome::Failed(detail);
                }
            }
            Err(o) => return o,
        }
    }
    // bilan : fichiers dans oCIS
    set_phase(sh, "bilan");
    let mut cmd = rclone_cmd(rc, c, obs, &it.dav, &c.vendor);
    cmd.args(["size", "--json"]).arg(format!("ocis:{}", it.sub)).stderr(Stdio::null());
    let dst =
        cmd.output().ok().and_then(|o| serde_json::from_slice::<serde_json::Value>(&o.stdout).ok()).map(|v| (v["count"].as_u64().unwrap_or(0), v["bytes"].as_u64().unwrap_or(0)));
    let mut b = match dst {
        Some((n, by)) => tf("{0} fichier(s), {1} dans oCIS", &[&n, &(fmt::bytes(by))]),
        None => String::new(),
    };
    if it.delete == 0 {
        if let Some((n, _)) = dst {
            if n < it.files {
                b = tf("{0} (source : {1} fichier(s))", &[&b, &(it.files)]);
            }
        }
    }
    if !detail.is_empty() {
        b = if b.is_empty() { detail } else { format!("{b} · {detail}") };
    }
    Outcome::Ok(b)
}

#[cfg(windows)]
pub(crate) fn keep_awake(on: bool) {
    use windows_sys::Win32::System::Power::{SetThreadExecutionState, ES_CONTINUOUS, ES_SYSTEM_REQUIRED};
    // SAFETY: appel sans pointeur ; tient le PC eveille tant que ce fil le demande
    unsafe {
        SetThreadExecutionState(if on { ES_CONTINUOUS | ES_SYSTEM_REQUIRED } else { ES_CONTINUOUS });
    }
}
#[cfg(not(windows))]
pub(crate) fn keep_awake(_on: bool) {}

/// Traite la file d'attente (bloquant : a lancer dans un fil)
pub fn worker(sh: Sh) {
    let rc = {
        let mut g = lock(&sh);
        if g.rclone.is_none() {
            g.rclone = find_rclone();
        }
        g.rclone.clone()
    };
    let conf = lock(&sh).saved.conf.clone();
    let fail_all = |msg: String| {
        let mut g = lock(&sh);
        g.log(&msg);
        g.live.running = false;
        g.saved.resume = false;
        g.saved.results = vec![PcResult { label: tr("Migration").into(), space: String::new(), ok: false, detail: msg }];
        g.save();
        g.repaint();
    };
    let (Some((rc, ver)), Some(conf)) = (rc, conf) else {
        fail_all(tr("rclone ou la connexion oCIS manque sur ce PC.").into());
        return;
    };
    let obs = match obscure(&rc, &conf.secret()) {
        Ok(o) => o,
        Err(e) => return fail_all(e),
    };
    keep_awake(true);
    {
        let mut g = lock(&sh);
        g.saved.results.clear();
        g.saved.resume = true;
        g.live.count = g.saved.queue.len();
        g.live.step = 0;
        g.live.started = fmt::now();
        g.log(&format!("=== {ver}"));
        g.save();
    }
    let stopped;
    loop {
        let it = {
            let mut g = lock(&sh);
            if g.live.stop || g.saved.queue.is_empty() {
                stopped = g.live.stop;
                break;
            }
            g.live.step += 1;
            g.live.attempt = 0;
            let it = g.saved.queue[0].clone();
            let l = format!("=== [{}] {} -> {}{}", g.live.step, it.src, it.space_name, if it.sub.is_empty() { String::new() } else { format!("/{}", it.sub) });
            g.log(&l);
            g.live.item = Some(it.clone());
            g.repaint();
            it
        };
        let t0 = fmt::now();
        let out = process(&sh, &rc, &conf, &obs, &it);
        let mut g = lock(&sh);
        let space = if it.sub.is_empty() { it.space_name.clone() } else { format!("{}/{}", it.space_name, it.sub) };
        let (ok, detail) = match out {
            Outcome::Stopped => {
                g.log(tr("arrêtée : l'élément reste en file d'attente"));
                stopped = true;
                break;
            }
            Outcome::Ok(d) => (true, d),
            Outcome::Failed(d) => (false, d),
        };
        g.saved.queue.remove(0);
        let l = format!("=== [{}] {} : {detail}", g.live.step, if ok { "OK" } else { "ECHEC" });
        g.log(&l);
        g.saved.history.push(format!(
            "{} | {} -> {} | {} | {} min | {}",
            fmt::date_full(t0),
            it.label,
            space,
            if ok { "OK" } else { "ECHEC" },
            (fmt::now() - t0 + 59) / 60,
            detail
        ));
        let n = g.saved.history.len();
        if n > 100 {
            g.saved.history.drain(..n - 100);
        }
        g.saved.results.push(PcResult { label: it.label.clone(), space, ok, detail });
        g.save();
    }
    keep_awake(false);
    let mut g = lock(&sh);
    g.live.running = false;
    g.live.stop = false;
    g.live.item = None;
    g.live.stats = None;
    g.saved.resume = false;
    g.save();
    let ko = g.saved.results.iter().filter(|r| !r.ok).count();
    let okn = g.saved.results.len() - ko;
    if g.notify {
        if let Some(ctx) = g.ctx.clone() {
            let (t, b) = if stopped {
                (tr("Migration depuis le PC arrêtée"), tr("Les éléments non terminés restent en file d'attente.").to_string())
            } else if ko > 0 {
                (tr("Migration depuis le PC : échec"), tf("{0} réussie(s), {1} en échec", &[&okn, &ko]))
            } else {
                (tr("Migration depuis le PC terminée"), tf("{0} dossier(s) migré(s) vers oCIS", &[&okn]))
            };
            crate::tray::notify(&ctx, t, &b);
        }
    }
    g.repaint();
}

fn start(sh: &Sh) {
    {
        let mut g = lock(sh);
        if g.live.running || g.saved.queue.is_empty() {
            return;
        }
        g.live.running = true;
        g.live.stop = false;
    }
    let s = sh.clone();
    std::thread::spawn(move || worker(s));
}

// =====================================================================
//  Interface
// =====================================================================

/// Appele a chaque image : contexte, reprise automatique au lancement
pub fn dialogs(app: &mut App, ctx: &egui::Context) {
    let notify = app.settings.notifications;
    let first = !app.pcmig.started;
    app.pcmig.started = true;
    let sh = app.pcmig.sh.clone();
    let resume = {
        let mut g = lock(&sh);
        g.ctx = Some(ctx.clone());
        g.notify = notify;
        first && g.saved.resume && !g.saved.queue.is_empty()
    };
    if resume {
        kill_orphan();
        lock(&sh).log(tr("reprise de la migration interrompue (application fermée en cours de route)"));
        start(&sh);
    }
    if lock(&sh).live.running {
        ctx.request_repaint_after(Duration::from_secs(1));
    }
}

fn phase_text(p: &str) -> &'static str {
    match p {
        "verification" => tr("Contrôle des empreintes dans oCIS"),
        "relecture" => tr("Contrôle par relecture depuis oCIS"),
        "suppression" => tr("Suppression des originaux contrôlés"),
        "renvoi" => tr("Renvoi des fichiers en défaut"),
        "bilan" => tr("Bilan : comptage des fichiers dans oCIS"),
        _ => tr("Transfert"),
    }
}

pub fn page(app: &mut App, ui: &mut egui::Ui) {
    let sh = app.pcmig.sh.clone();
    {
        let mut g = lock(&sh);
        if !g.rclone_checked {
            g.rclone_checked = true;
            g.rclone = find_rclone();
        }
    }
    banner(ui, INFO, tr("rclone tourne sur ce PC : il doit rester allumé, l'application ouverte (même réduite dans la zone de notification). Le PC est tenu éveillé pendant la migration ; si l'application est fermée, la migration reprend à son prochain lancement."));
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
                        let r = download_rclone();
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
        return;
    }
    let ready = rclone.is_some();

    let (saved, live_running, spaces, spaces_busy, spaces_err, conf_busy, conf_msg, sizing) = {
        let g = lock(&sh);
        (g.saved.clone(), g.live.running, g.spaces.clone(), g.spaces_busy, g.spaces_err.clone(), g.conf_busy, g.conf_msg.clone(), g.sizing.clone())
    };

    // ---- connexion
    card(ui, tr("Connexion oCIS (ce PC)"), |ui| {
        match &saved.conf {
            Some(c) => {
                ui.label(tf("{0}  ·  compte {1}", &[&c.url, &c.user]));
                ui.label(
                    RichText::new(tf(
                        "Transferts : {0}  ·  {1}",
                        &[
                            &(if c.local.is_empty() { tr("via Internet").to_string() } else { tf("réseau local ({0})", &[&c.local]) }),
                            &(rclone.as_ref().map(|r| r.1.clone()).unwrap_or_default()),
                        ],
                    ))
                    .small()
                    .weak(),
                );
            }
            None => {
                ui.colored_label(WARN, tr("Pas encore configurée."));
            }
        }
        let f = &mut app.pcmig;
        ui.horizontal(|ui| {
            if ui.add_enabled(!conf_busy && !live_running, egui::Button::new(if f.conf_open { tr("Fermer") } else { tr("Modifier la connexion…") })).clicked() {
                f.conf_open = !f.conf_open;
                if f.conf_open {
                    if let Some(c) = &saved.conf {
                        f.url = c.url.clone();
                        f.user = c.user.clone();
                        f.local = c.local.clone();
                        f.insecure = c.insecure;
                    }
                    f.token.clear();
                }
            }
            if conf_busy {
                ui.spinner();
                ui.label(tr("Test de la connexion et d'un envoi…"));
            }
        });
        if let Some((ok, m)) = &conf_msg {
            ui.colored_label(if *ok { OK } else { ERR }, m);
        }
        if f.conf_open {
            egui::Grid::new("pcocis").num_columns(2).spacing([12.0, 8.0]).show(ui, |ui| {
                ui.label(tr("Adresse d'oCIS"));
                ui.add(egui::TextEdit::singleline(&mut f.url).hint_text("https://cloud.maison.fr").desired_width(320.0));
                ui.end_row();
                ui.label(tr("Utilisateur"));
                ui.add(egui::TextEdit::singleline(&mut f.user).desired_width(200.0));
                ui.end_row();
                ui.label(tr("Jeton d'application"));
                ui.add(egui::TextEdit::singleline(&mut f.token).password(true).desired_width(320.0).hint_text(if saved.conf.is_some() {
                    tr("vide = garder le jeton actuel")
                } else {
                    ""
                }));
                ui.end_row();
                ui.label(tr("Adresse locale"));
                ui.add(egui::TextEdit::singleline(&mut f.local).hint_text(tr("vide = passer par Internet")).desired_width(320.0));
                ui.end_row();
                ui.label("");
                ui.checkbox(&mut f.insecure, tr("Accepter un certificat non reconnu (auto-signé)"));
                ui.end_row();
            });
            if !crate::secret::can_store() {
                ui.label(RichText::new(tr("Hors Windows, le jeton est gardé en clair dans le dossier de l'application (lisible par ton compte seulement).")).small().weak());
            }
            let has_token = !f.token.trim().is_empty() || saved.conf.is_some();
            let can = !f.url.trim().is_empty() && !f.user.trim().is_empty() && has_token;
            if ui.add_enabled(can, egui::Button::new(tr("Tester et enregistrer"))).clicked() {
                let norm = |u: &str| {
                    let u = u.trim().trim_end_matches('/');
                    if u.is_empty() || u.starts_with("http://") || u.starts_with("https://") {
                        u.to_string()
                    } else {
                        format!("https://{u}")
                    }
                };
                let token = if f.token.trim().is_empty() { saved.conf.as_ref().map(|c| c.token.clone()).unwrap_or_default() } else { PcConf::store_secret(f.token.trim()) };
                let mut c = PcConf { url: norm(&f.url), user: f.user.trim().to_string(), token, local: norm(&f.local), insecure: f.insecure, vendor: String::new() };
                f.conf_open = false;
                f.token.clear();
                let rc = rclone.clone().map(|r| r.0).unwrap_or_default();
                {
                    let mut g = lock(&sh);
                    g.conf_busy = true;
                    g.conf_msg = None;
                }
                let s = sh.clone();
                std::thread::spawn(move || {
                    let r = test_conf(&rc, &c);
                    let mut g = lock(&s);
                    g.conf_busy = false;
                    match r {
                        Ok(v) => {
                            c.vendor = v.clone();
                            g.saved.conf = Some(c.clone());
                            g.save();
                            g.conf_msg = Some((
                                true,
                                if v == "owncloud" {
                                    tr("Connexion et envoi OK (WebDAV classique).").into()
                                } else {
                                    tr("Envoi OK en mode oCIS natif seulement : rclone y consomme beaucoup de mémoire.").into()
                                },
                            ));
                            drop(g);
                            load_spaces(&s);
                            return;
                        }
                        Err(e) => g.conf_msg = Some((false, e)),
                    }
                    g.repaint();
                });
            }
        }
    });
    ui.add_space(10.0);
    if saved.conf.is_some() && spaces.is_empty() && !spaces_busy && spaces_err.is_empty() {
        load_spaces(&sh);
    }

    // ---- en cours
    if live_running {
        let (it, step, count, phase, stats, attempt, started) = {
            let g = lock(&sh);
            (g.live.item.clone(), g.live.step, g.live.count, g.live.phase.clone(), g.live.stats.clone(), g.live.attempt, g.live.started)
        };
        card(ui, tr("Migration en cours (depuis ce PC)"), |ui| {
            if let Some(it) = &it {
                ui.label(
                    RichText::new(format!("[{step}/{count}]  {}  →  {}{}", it.label, it.space_name, if it.sub.is_empty() { String::new() } else { format!("/{}", it.sub) }))
                        .strong(),
                );
                ui.label(RichText::new(format!("{} · {}", it.src, tf("{0} fichier(s), {1}", &[&it.files, &(fmt::bytes(it.total))]))).small().weak());
                ui.label(phase_text(&phase));
                match &stats {
                    Some(s) => {
                        let total = if phase == "transfert" { it.total.max(s.total_bytes) } else { s.total_bytes };
                        let pct = if total > 0 { Some(((s.bytes as f64 / total as f64) * 100.0).min(100.0) as i64) } else { None };
                        let mut line = tf("{0} / {1} envoyés · {2} fichier(s)", &[&(fmt::bytes(s.bytes)), &(fmt::bytes(total)), &(s.transfers)]);
                        if s.speed > 0.0 {
                            line.push_str(&format!(" · {}/s", fmt::bytes(s.speed as u64)));
                        }
                        if let Some(e) = s.eta {
                            line.push_str(&tf(" · reste {0}", &[&(fmt::duration(e))]));
                        }
                        if s.checks > 0 && phase != "transfert" {
                            line = tf("{0} contrôlé(s) · {1}", &[&(s.checks), &line]);
                        }
                        if s.errors > 0 {
                            line.push_str(&tf(" · {0} erreur(s)", &[&(s.errors)]));
                        }
                        progress_bar(ui, pct, line);
                    }
                    None => progress_bar(ui, None, tr("démarrage…").into()),
                }
                if attempt > 0 {
                    ui.label(RichText::new(tf("reprise automatique {0}/5", &[&attempt])).small().color(WARN));
                }
            }
            ui.label(RichText::new(tf("Lancée {0}", &[&(fmt::ago(started, fmt::now()))])).small().weak());
            if danger_button(ui, tr("\u{E46C} Arrêter la migration")).clicked() {
                lock(&sh).live.stop = true;
            }
        });
        ui.add_space(10.0);
    }

    // ---- resultats
    if !saved.results.is_empty() && !live_running {
        card(ui, tr("Résultats du dernier lancement"), |ui| {
            for r in &saved.results {
                ui.horizontal_wrapped(|ui| {
                    dot(ui, if r.ok { OK } else { ERR });
                    ui.label(RichText::new(format!("{} → {}", r.label, r.space)).strong());
                    ui.label(RichText::new(&r.detail).small());
                });
            }
        });
        ui.add_space(10.0);
    }

    // ---- file d'attente
    card(ui, &tf("File d'attente ({0})", &[&(saved.queue.len())]), |ui| {
        if saved.queue.is_empty() {
            ui.label(RichText::new(tr("Vide : ajoute une migration ci-dessous.")).weak());
        }
        let mut remove = None;
        for (i, q) in saved.queue.iter().enumerate() {
            ui.horizontal(|ui| {
                ui.label(RichText::new(format!("{}.", i + 1)).weak());
                ui.label(RichText::new(format!("{}  →  {}{}", q.label, q.space_name, if q.sub.is_empty() { String::new() } else { format!("/{}", q.sub) })).strong())
                    .on_hover_text(&q.src);
                ui.label(RichText::new(fmt::bytes(q.total)).small());
                match q.delete {
                    1 => badge(ui, tr("+ suppression des originaux"), ERR),
                    2 => badge(ui, tr("contrôle + suppression"), ERR),
                    _ => {}
                }
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.add_enabled(!live_running, egui::Button::new("\u{E4F6}").small()).on_hover_text(tr("Retirer de la file")).clicked() {
                        remove = Some(i);
                    }
                });
            });
        }
        if let Some(i) = remove {
            let mut g = lock(&sh);
            if i < g.saved.queue.len() && !g.live.running {
                g.saved.queue.remove(i);
                g.save();
            }
        }
        ui.add_space(4.0);
        if ui
            .add_enabled(
                ready && saved.conf.is_some() && !live_running && !saved.queue.is_empty(),
                egui::Button::new(RichText::new(tr("\u{E3D0} Lancer la file d'attente")).color(Color32::WHITE)).fill(INFO),
            )
            .clicked()
        {
            let del = saved.queue.iter().any(|q| q.delete > 0);
            let s = sh.clone();
            app.ask_confirm(
                tr("Lancer la migration"),
                &tf(
                    "{0} migration(s) vont être traitées l'une après l'autre depuis ce PC, qui doit rester allumé.{1}",
                    &[&(saved.queue.len()), &(if del { tr("\nCertaines suppriment les originaux de ce PC après contrôle dans oCIS.") } else { "" })],
                ),
                tr("Lancer"),
                false,
                None,
                Box::new(move |_| start(&s)),
            );
        }
    });
    ui.add_space(10.0);

    // ---- ajouter
    let mut pending: Option<(PcItem, bool)> = None;
    card(ui, tr("Ajouter une migration"), |ui| {
        ui.add_enabled_ui(saved.conf.is_some(), |ui| {
            if saved.conf.is_none() {
                ui.colored_label(WARN, tr("Configure d'abord la connexion oCIS."));
            }
            let f = &mut app.pcmig;
            ui.horizontal(|ui| {
                ui.label(tr("Dossier du PC :"));
                ui.add(egui::TextEdit::singleline(&mut f.src).desired_width(360.0).hint_text("D:\\Photos"));
                if ui.button(tr("\u{E24A} Parcourir")).clicked() {
                    if let Some(p) = rfd::FileDialog::new().pick_folder() {
                        f.src = p.display().to_string();
                        f.label = p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                    }
                }
            });
            ui.horizontal(|ui| {
                ui.label(tr("Espace oCIS :"));
                let sel = f.space.as_ref().and_then(|id| spaces.iter().find(|(s, _)| s.id == *id)).map(|(s, _)| s.name.clone()).unwrap_or_else(|| tr("Choisir…").into());
                egui::ComboBox::from_id_salt("pcspace").width(300.0).selected_text(sel).show_ui(ui, |ui| {
                    for (sp, _) in &spaces {
                        let q = if sp.quota > 0 { tf("libre {0}", &[&(fmt::bytes(sp.free.max(0) as u64))]) } else { tr("sans limite").into() };
                        let lab = if sp.kind == "personal" { format!("\u{E4C2} {}  ({q})", sp.name) } else { format!("{}  ({q})", sp.name) };
                        if ui.selectable_label(f.space.as_deref() == Some(sp.id.as_str()), lab).clicked() {
                            f.space = Some(sp.id.clone());
                        }
                    }
                });
                if spaces_busy {
                    ui.spinner();
                } else if ui.button("\u{E094}").on_hover_text(tr("Relire les espaces")).clicked() {
                    load_spaces(&sh);
                }
            });
            if !spaces_err.is_empty() {
                ui.colored_label(ERR, &spaces_err);
            }
            ui.horizontal(|ui| {
                ui.label(tr("Sous-dossier dans l'espace :"));
                ui.add(egui::TextEdit::singleline(&mut f.sub).hint_text(tr("vide = racine de l'espace")).desired_width(220.0));
                ui.label(tr("Libellé :"));
                ui.add(egui::TextEdit::singleline(&mut f.label).desired_width(140.0));
            });
            ui.label(tr("Après le transfert :"));
            ui.radio_value(&mut f.del_mode, 0, tr("Garder les originaux sur ce PC (copie)"));
            ui.radio_value(&mut f.del_mode, 1, RichText::new(tr("Contrôler chaque fichier dans oCIS, puis SUPPRIMER l'original de ce PC")).color(ERR));
            ui.radio_value(&mut f.del_mode, 2, RichText::new(tr("Déjà migré : contrôler et supprimer les originaux, sans transfert")).color(ERR));
            let sp = f.space.as_ref().and_then(|id| spaces.iter().find(|(s, _)| s.id == *id)).cloned();
            let can = !f.src.trim().is_empty() && sp.is_some() && sizing.is_none();
            ui.horizontal(|ui| {
                if ui.add_enabled(can, egui::Button::new(tr("+ Ajouter à la file d'attente"))).clicked() {
                    let (sp, dav) = sp.unwrap();
                    let src = f.src.trim().trim_end_matches(['/', '\\']).to_string();
                    let src = if src.ends_with(':') { format!("{src}\\") } else { src };
                    let label = if f.label.trim().is_empty() {
                        Path::new(&src).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| src.clone())
                    } else {
                        f.label.trim().to_string()
                    };
                    let it = PcItem {
                        src,
                        label,
                        space_id: sp.id.clone(),
                        space_name: sp.name.clone(),
                        dav,
                        sub: f.sub.trim().trim_matches('/').to_string(),
                        delete: f.del_mode,
                        files: 0,
                        total: 0,
                    };
                    pending = Some((it, f.del_mode > 0));
                    f.src.clear();
                    f.label.clear();
                    f.sub.clear();
                    f.del_mode = 0;
                }
                if let Some(l) = &sizing {
                    ui.spinner();
                    ui.label(tf("Calcul de la taille de « {0} »…", &[l]));
                }
            });
        });
    });
    if let Some((it, del)) = pending {
        let s = sh.clone();
        let add = move |_: &mut App| {
            lock(&s).sizing = Some(it.label.clone());
            let s2 = s.clone();
            std::thread::spawn(move || {
                let mut it = it;
                let ok = Path::new(&it.src).is_dir();
                if ok {
                    let (n, b) = dir_size(Path::new(&it.src));
                    it.files = n;
                    it.total = b;
                }
                let mut g = lock(&s2);
                g.sizing = None;
                if ok {
                    g.saved.queue.push(it);
                    g.save();
                } else {
                    g.spaces_err = tf("Dossier introuvable : {0}", &[&it.src]);
                }
                g.repaint();
            });
        };
        if del {
            app.ask_confirm(
                            tr("Suppression des originaux"),
                            tr("Seuls les fichiers dont la copie dans oCIS est contrôlée identique (empreinte) seront supprimés de ce PC. Un fichier absent, différent ou modifié entre-temps est gardé."),
                            tr("Ajouter"),
                            true,
                            Some(tr("SUPPRIMER")),
                            Box::new(add),
                        );
        } else {
            add(app);
        }
    }
    ui.add_space(10.0);

    egui::CollapsingHeader::new(tr("Journal de la migration (derniers événements)")).id_salt("pcjournal").show(ui, |ui| {
        let g = lock(&sh);
        if g.live.log.is_empty() {
            ui.label(RichText::new(tf("Journal complet : {0}", &[&(log_path().display())])).small().weak());
        }
        for l in g.live.log.iter().rev().take(80) {
            ui.label(RichText::new(l).monospace().size(12.0));
        }
    });
    card(ui, tr("Historique"), |ui| {
        if saved.history.is_empty() {
            ui.label(RichText::new(tr("Aucune migration.")).weak());
        }
        for l in saved.history.iter().rev() {
            ui.horizontal(|ui| {
                dot(ui, if l.contains("| OK") { OK } else { ERR });
                ui.label(RichText::new(l).small());
            });
        }
    });
}

fn load_spaces(sh: &Sh) {
    let conf = {
        let mut g = lock(sh);
        if g.spaces_busy {
            return;
        }
        g.spaces_busy = true;
        g.spaces_err.clear();
        g.saved.conf.clone()
    };
    let s = sh.clone();
    std::thread::spawn(move || {
        let r = conf.ok_or_else(|| tr("Connexion oCIS non configurée.").to_string()).and_then(|c| fetch_spaces(&c));
        let mut g = lock(&s);
        g.spaces_busy = false;
        match r {
            Ok(v) if v.is_empty() => g.spaces_err = tr("Aucun espace oCIS visible pour ce compte.").into(),
            Ok(v) => g.spaces = v,
            Err(e) => g.spaces_err = e,
        }
        g.repaint();
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn analyse() {
        assert_eq!(to_base("https://cloud.exemple.fr/dav/spaces/abc$def", "http://127.0.0.1:9231"), "http://127.0.0.1:9231/dav/spaces/abc$def");
        let d = parse_drives(
            r#"{"value":[{"id":"p1","driveType":"project","name":"Zeta","quota":{"total":10,"remaining":4},"root":{"webDavUrl":"https://x/dav/spaces/p1"}},{"id":"v","driveType":"virtual","name":"Partages","root":{"webDavUrl":"https://x/dav/spaces/v"}},{"id":"me","driveType":"personal","name":"Alice","root":{"webDavUrl":"https://x/dav/spaces/me"}}]}"#,
        );
        assert_eq!(d.iter().map(|(s, _)| s.id.as_str()).collect::<Vec<_>>(), vec!["me", "p1"]);
        assert_eq!((d[1].0.free, d[1].0.quota), (4, 10));
        let (s, m) = parse_json_line(
            r#"{"level":"notice","msg":"stats","stats":{"bytes":100,"totalBytes":400,"transfers":2,"totalTransfers":8,"speed":12.5,"eta":30,"errors":0,"checks":1}}"#,
        );
        assert_eq!(s.map(|s| (s.bytes, s.total_bytes, s.eta)), Some((100, 400, Some(30))));
        assert!(m.is_none());
        let (s, m) = parse_json_line(r#"{"level":"error","msg":"Failed to copy: 401 Unauthorized","object":"a/b.jpg"}"#);
        assert!(s.is_none());
        assert_eq!(m, Some(("error".into(), "a/b.jpg : Failed to copy: 401 Unauthorized".into())));
    }

    /// Contre le faux oCIS (tests/faux-ocis.py) : NAS_MANAGER_LIVE_TEST=1 et rclone installe
    #[test]
    fn pc_live() {
        if std::env::var("NAS_MANAGER_LIVE_TEST").is_err() {
            return;
        }
        // le vrai rclone (celui du faux NAS, dans le PATH, ne fait que simuler)
        let Some((rc, ver)) = ["/usr/bin/rclone"].iter().map(PathBuf::from).find(|p| p.exists()).map(|p| (p, "test".to_string())).or_else(find_rclone) else { return };
        let w = std::env::temp_dir().join(format!("pcmig-{}", std::process::id()));
        let (esp, src) = (w.join("espaces"), w.join("source"));
        std::fs::create_dir_all(src.join("sous")).unwrap();
        std::fs::write(src.join("a.txt"), "bonjour").unwrap();
        std::fs::write(src.join("sous/b.bin"), vec![7u8; 300_000]).unwrap();
        std::fs::write(src.join("Thumbs.db"), "x").unwrap();
        let py = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/faux-ocis.py");
        let port = 9241;
        let mut srv =
            Command::new("python3").arg(py).arg(port.to_string()).arg(&esp).arg(&rc).args(["alice", "secret"]).stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap();
        let url = format!("http://127.0.0.1:{port}");
        for _ in 0..100 {
            if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        std::thread::sleep(Duration::from_millis(500));
        let res = std::panic::catch_unwind(|| {
            let mut c = PcConf { url: url.clone(), user: "alice".into(), token: "clair:secret".into(), ..Default::default() };
            let bad = PcConf { token: "clair:faux".into(), ..c.clone() };
            assert!(fetch_spaces(&bad).unwrap_err().contains("401"));
            c.vendor = test_conf(&rc, &c).unwrap();
            assert_eq!(c.vendor, "owncloud");
            let sp = fetch_spaces(&c).unwrap();
            assert_eq!(sp.len(), 3);
            let (photos, dav) = sp.iter().find(|(s, _)| s.id == "projet-photos").cloned().unwrap();
            let (n, b) = dir_size(&src);
            assert_eq!((n, b), (2, 300_007));
            let item = PcItem {
                src: src.display().to_string(),
                label: "source".into(),
                space_id: photos.id.clone(),
                space_name: photos.name.clone(),
                dav,
                sub: "Import".into(),
                delete: 1,
                files: n,
                total: b,
            };
            let sh: Sh = Arc::new(Mutex::new(Shared::default()));
            {
                let mut g = lock(&sh);
                g.saved.conf = Some(c.clone());
                g.saved.queue = vec![item];
                g.live.running = true;
                g.rclone = Some((rc.clone(), ver.clone()));
            }
            // pas d'ecriture dans le vrai dossier de l'application : NAS_MANAGER_DIR pointe ailleurs
            worker(sh.clone());
            let g = lock(&sh);
            assert!(g.saved.queue.is_empty());
            assert_eq!(g.saved.results.len(), 1, "{:?}", g.live.log);
            assert!(g.saved.results[0].ok, "{:?} {:?}", g.saved.results, g.live.log);
            assert!(g.saved.results[0].detail.contains("2 original(aux)"), "{}", g.saved.results[0].detail);
            // le faux oCIS ne donne pas d'empreinte : controle par relecture avant toute suppression
            assert!(g.live.log.iter().any(|l| l.contains("relecture")), "{:?}", g.live.log);
            assert_eq!(std::fs::read_to_string(esp.join("projet-photos/Import/a.txt")).unwrap(), "bonjour");
            assert_eq!(std::fs::metadata(esp.join("projet-photos/Import/sous/b.bin")).unwrap().len(), 300_000);
            assert!(!esp.join("projet-photos/Import/Thumbs.db").exists());
            // originaux controles supprimes, fichier exclu garde, dossiers vides retires
            assert!(!src.join("a.txt").exists() && !src.join("sous").exists());
            assert!(src.join("Thumbs.db").exists());
        });
        let _ = srv.kill();
        let _ = srv.wait();
        let _ = std::fs::remove_dir_all(&w);
        if let Err(e) = res {
            std::panic::resume_unwind(e);
        }
    }
}
