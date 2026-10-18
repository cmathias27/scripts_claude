//! Execution de scripts sur le NAS via le client OpenSSH du systeme
//! (integre a Windows 10/11 : C:\Windows\System32\OpenSSH\ssh.exe).
//!
//! Une connexion persistante par NAS (session) execute les commandes courtes
//! (etat, journaux, dossiers) sans renegocier SSH a chaque fois. Les commandes
//! longues, ou quand la session est occupee, passent par une connexion dediee.
//! L'identite (empreinte) de chaque NAS est confirmee par l'utilisateur a la
//! premiere connexion, puis verifiee strictement.

use crate::config::{app_dir, HostCfg};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

#[cfg(windows)]
use std::os::windows::process::CommandExt;
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
#[cfg(windows)]
const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;

#[derive(Debug, Clone)]
pub struct CmdOut {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl CmdOut {
    /// Sortie complete (stdout puis stderr), sans les codes couleur des scripts
    pub fn text(&self) -> String {
        let mut t = strip_ansi(&self.stdout);
        let e = strip_ansi(&self.stderr);
        if !e.trim().is_empty() {
            if !t.is_empty() && !t.ends_with('\n') {
                t.push('\n');
            }
            t.push_str(&e);
        }
        t.trim_end().to_string()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum SshError {
    /// La cle de l'application n'est pas autorisee sur le NAS
    KeyRefused,
    /// Mot de passe sudo absent ou faux
    SudoPassword,
    /// Hote injoignable / connexion impossible
    Unreachable(String),
    /// La cle d'hote du NAS a change
    HostKeyChanged,
    /// Empreinte du NAS pas encore confirmee par l'utilisateur
    HostUnknown,
    /// Client ssh introuvable sur le PC
    NoSshClient,
    Timeout,
    Other(String),
}

impl std::fmt::Display for SshError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SshError::KeyRefused => write!(f, "La clé de l'application n'est pas autorisée sur ce NAS (Paramètres > Autoriser la clé)."),
            SshError::SudoPassword => write!(f, "Mot de passe sudo manquant ou incorrect."),
            SshError::Unreachable(m) => write!(f, "NAS injoignable : {m}"),
            SshError::HostKeyChanged => write!(f, "L'identité SSH du NAS a changé (réinstallation ?). Si c'est normal : Paramètres > Oublier l'identité, puis confirmer la nouvelle empreinte."),
            SshError::HostUnknown => write!(f, "Identité du NAS à confirmer (empreinte SSH)."),
            SshError::NoSshClient => write!(f, "Client OpenSSH introuvable. Windows : Paramètres > Applications > Fonctionnalités facultatives > Client OpenSSH."),
            SshError::Timeout => write!(f, "Le NAS ne répond pas (délai dépassé)."),
            SshError::Other(m) => write!(f, "{m}"),
        }
    }
}

#[derive(Clone)]
pub struct Ssh {
    pub bin: String,
    pub key: PathBuf,
    pub known_hosts: PathBuf,
}

impl Ssh {
    pub fn new(bin: &str) -> Self {
        let dir = app_dir();
        Self {
            bin: if bin.trim().is_empty() { "ssh".into() } else { bin.trim().into() },
            key: dir.join("id_ed25519"),
            known_hosts: dir.join("known_hosts"),
        }
    }

    pub fn key_exists(&self) -> bool {
        self.key.exists() && self.pub_key_path().exists()
    }

    pub fn pub_key_path(&self) -> PathBuf {
        let mut p = self.key.clone().into_os_string();
        p.push(".pub");
        PathBuf::from(p)
    }


    /// Outil OpenSSH situe a cote de ssh (ssh-keygen, ssh-keyscan)
    fn tool(&self, name: &str) -> String {
        let p = PathBuf::from(&self.bin);
        match p.parent() {
            Some(dir) if !dir.as_os_str().is_empty() => {
                let n = if cfg!(windows) { format!("{name}.exe") } else { name.to_string() };
                dir.join(n).to_string_lossy().into_owned()
            }
            _ => name.into(),
        }
    }

    fn keygen_bin(&self) -> String {
        self.tool("ssh-keygen")
    }

    /// Nom de l'hote tel qu'il apparait dans known_hosts
    fn kh_name(h: &HostCfg) -> String {
        if h.port == 22 {
            h.host.trim().to_string()
        } else {
            format!("[{}]:{}", h.host.trim(), h.port)
        }
    }

    /// L'identite de ce NAS a-t-elle deja ete confirmee ?
    pub fn host_known(&self, h: &HostCfg) -> bool {
        let name = Self::kh_name(h);
        let txt = std::fs::read_to_string(&self.known_hosts).unwrap_or_default();
        if txt
            .lines()
            .any(|l| l.split_whitespace().next().unwrap_or("").split(',').any(|n| n == name))
        {
            return true;
        }
        // entrees hachees (HashKnownHosts) : ssh-keygen -F
        if txt.contains("|1|") {
            let mut c = Command::new(self.keygen_bin());
            c.arg("-F").arg(&name).arg("-f").arg(&self.known_hosts).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
            #[cfg(windows)]
            c.creation_flags(CREATE_NO_WINDOW);
            return c.status().map(|s| s.success()).unwrap_or(false);
        }
        false
    }

    /// Lit les cles publiques du NAS (ssh-keyscan) et leurs empreintes
    pub fn scan_host(&self, h: &HostCfg) -> Result<HostScan, String> {
        let mut cmd = Command::new(self.tool("ssh-keyscan"));
        cmd.args(["-T", "8", "-p", &h.port.to_string(), "-t", "ed25519,ecdsa,rsa"])
            .arg(h.host.trim())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        #[cfg(windows)]
        cmd.creation_flags(CREATE_NO_WINDOW);
        let out = cmd.output().map_err(|e| format!("ssh-keyscan introuvable : {e}"))?;
        let lines: Vec<String> = String::from_utf8_lossy(&out.stdout)
            .lines()
            .filter(|l| !l.starts_with('#') && l.split_whitespace().count() >= 3)
            .map(|l| l.trim().to_string())
            .collect();
        if lines.is_empty() {
            return Err(format!("{} injoignable sur le port {} (aucune réponse SSH).", h.host.trim(), h.port));
        }
        // empreintes SHA256 via ssh-keygen -lf
        let tmp = app_dir().join("scan.tmp");
        std::fs::create_dir_all(app_dir()).map_err(|e| e.to_string())?;
        std::fs::write(&tmp, lines.join("\n") + "\n").map_err(|e| e.to_string())?;
        let mut kg = Command::new(self.keygen_bin());
        kg.arg("-lf").arg(&tmp).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
        #[cfg(windows)]
        kg.creation_flags(CREATE_NO_WINDOW);
        let fp = kg.output().map_err(|e| e.to_string())?;
        let _ = std::fs::remove_file(&tmp);
        let fingerprints: Vec<String> = String::from_utf8_lossy(&fp.stdout)
            .lines()
            .filter_map(|l| {
                // "256 SHA256:xxxx host (ED25519)"
                let p: Vec<&str> = l.split_whitespace().collect();
                (p.len() >= 2).then(|| format!("{} {}", p.last().unwrap_or(&"").trim_matches(|c| c == '(' || c == ')'), p[1]))
            })
            .collect();
        let name = Self::kh_name(h);
        let entries = lines
            .iter()
            .map(|l| {
                let mut it = l.splitn(2, ' ');
                let _host = it.next();
                format!("{} {}", name, it.next().unwrap_or(""))
            })
            .collect();
        Ok(HostScan { entries, fingerprints })
    }

    /// Enregistre l'identite confirmee du NAS
    pub fn trust_host(&self, h: &HostCfg, scan: &HostScan) -> Result<(), String> {
        self.forget_host(h)?;
        let mut txt = std::fs::read_to_string(&self.known_hosts).unwrap_or_default();
        for e in &scan.entries {
            txt.push_str(e);
            txt.push('\n');
        }
        std::fs::write(&self.known_hosts, txt).map_err(|e| e.to_string())?;
        close_session(h);
        Ok(())
    }

    /// Cree la cle de l'application (ed25519, sans phrase de passe)
    pub fn generate_key(&self) -> Result<(), String> {
        std::fs::create_dir_all(app_dir()).map_err(|e| e.to_string())?;
        if self.key_exists() {
            return Ok(());
        }
        let mut cmd = Command::new(self.keygen_bin());
        cmd.args(["-t", "ed25519", "-q", "-N", "", "-C", "nas-manager", "-f"])
            .arg(&self.key)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        #[cfg(windows)]
        cmd.creation_flags(CREATE_NO_WINDOW);
        let out = cmd.output().map_err(|e| format!("ssh-keygen introuvable : {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "ssh-keygen a échoué : {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        Ok(())
    }

    fn base_args(&self, h: &HostCfg) -> Vec<String> {
        vec![
            "-i".into(),
            self.key.to_string_lossy().into_owned(),
            "-p".into(),
            h.port.to_string(),
            "-o".into(),
            "BatchMode=yes".into(),
            "-o".into(),
            "ConnectTimeout=8".into(),
            "-o".into(),
            "ServerAliveInterval=15".into(),
            "-o".into(),
            "StrictHostKeyChecking=yes".into(),
            "-o".into(),
            format!("UserKnownHostsFile=\"{}\"", self.known_hosts.to_string_lossy()),
            "-o".into(),
            "IdentitiesOnly=yes".into(),
            "-o".into(),
            "LogLevel=ERROR".into(),
            "-T".into(),
        ]
    }

    /// Execute `script` (bash) sur le NAS. `pass` : mot de passe sudo si h.sudo.
    /// Commandes courtes : session persistante si elle est libre ; sinon connexion dediee.
    pub fn run(
        &self,
        h: &HostCfg,
        pass: Option<&str>,
        script: &str,
        timeout: Duration,
    ) -> Result<CmdOut, SshError> {
        if !h.is_set() {
            return Err(SshError::Other("Adresse ou utilisateur non renseigné (Paramètres).".into()));
        }
        if h.sudo && pass.map(|p| p.is_empty()).unwrap_or(true) {
            return Err(SshError::SudoPassword);
        }
        if !self.host_known(h) {
            return Err(SshError::HostUnknown);
        }
        if timeout <= Duration::from_secs(120) && std::env::var("NAS_MANAGER_NO_SESSION").is_err() {
            let slot = session_slot(h);
            if let Ok(mut guard) = slot.try_lock() {
                let id = session_id(h, pass);
                if guard.as_ref().map(|s| s.id != id).unwrap_or(false) {
                    if let Some(s) = guard.take() {
                        s.kill();
                    }
                }
                if guard.is_none() {
                    match Session::open(self, h, pass, id) {
                        Ok(sess) => *guard = Some(sess),
                        // erreurs definitives : inutile de retenter en connexion dediee
                        Err(e @ (SshError::KeyRefused
                        | SshError::SudoPassword
                        | SshError::HostKeyChanged
                        | SshError::NoSshClient
                        | SshError::Unreachable(_))) => return Err(e),
                        Err(_) => {}
                    }
                }
                if let Some(sess) = guard.as_mut() {
                    match sess.exec(script, timeout) {
                        Ok(o) => return Ok(o),
                        Err(e) => {
                            if let Some(s) = guard.take() {
                                s.kill();
                            }
                            if e == SshError::Timeout {
                                return Err(e);
                            }
                            crate::log::warn(&format!("session {} interrompue ({e}) : connexion dédiée", h.target()));
                        }
                    }
                }
            };
        }
        self.run_once(h, pass, script, timeout)
    }

    /// Connexion dediee pour une seule commande
    pub fn run_once(
        &self,
        h: &HostCfg,
        pass: Option<&str>,
        script: &str,
        timeout: Duration,
    ) -> Result<CmdOut, SshError> {
        let remote = if h.sudo {
            "sudo -S -k -p '' bash -s"
        } else {
            "bash -s"
        };
        let mut child = self.spawn_ssh(h, remote)?;

        let mut input = String::new();
        if h.sudo {
            input.push_str(pass.unwrap_or(""));
            input.push('\n');
        }
        input.push_str(script);
        if !input.ends_with('\n') {
            input.push('\n');
        }
        let mut stdin = child.stdin.take().expect("stdin");
        let writer = std::thread::spawn(move || {
            let _ = stdin.write_all(input.as_bytes());
            // fermeture de stdin a la fin du bloc : fin du script pour bash
        });
        let mut so = child.stdout.take().expect("stdout");
        let mut se = child.stderr.take().expect("stderr");
        let r_out = std::thread::spawn(move || {
            let mut b = Vec::new();
            let _ = so.read_to_end(&mut b);
            b
        });
        let r_err = std::thread::spawn(move || {
            let mut b = Vec::new();
            let _ = se.read_to_end(&mut b);
            b
        });

        let start = Instant::now();
        let status = loop {
            match child.try_wait() {
                Ok(Some(st)) => break st,
                Ok(None) => {
                    if start.elapsed() > timeout {
                        let _ = child.kill();
                        let _ = child.wait();
                        return Err(SshError::Timeout);
                    }
                    std::thread::sleep(Duration::from_millis(40));
                }
                Err(e) => return Err(SshError::Other(e.to_string())),
            }
        };
        let _ = writer.join();
        let stdout = String::from_utf8_lossy(&r_out.join().unwrap_or_default()).into_owned();
        let stderr = String::from_utf8_lossy(&r_err.join().unwrap_or_default()).into_owned();
        let code = status.code().unwrap_or(-1);

        if code == 255 {
            return Err(connection_error(&stderr));
        }
        if h.sudo {
            if let Some(e) = sudo_error(&stderr, h) {
                return Err(e);
            }
        }
        Ok(CmdOut { code, stdout, stderr })
    }

    fn spawn_ssh(&self, h: &HostCfg, remote: &str) -> Result<Child, SshError> {
        let mut cmd = Command::new(&self.bin);
        cmd.args(self.base_args(h))
            .arg(h.target())
            .arg(remote)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        #[cfg(windows)]
        cmd.creation_flags(CREATE_NO_WINDOW);
        cmd.spawn().map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                SshError::NoSshClient
            } else {
                SshError::Other(format!("ssh : {e}"))
            }
        })
    }

    /// Ouvre une fenetre de console pour autoriser la cle de l'application sur le NAS
    /// (le mot de passe du compte est demande une seule fois, dans cette fenetre).
    pub fn open_key_install_console(&self, h: &HostCfg) -> Result<String, String> {
        if !h.is_set() {
            return Err("Adresse ou utilisateur non renseigné.".into());
        }
        self.generate_key()?;
        let remote = "umask 077; mkdir -p ~/.ssh && chmod go-w ~ ; cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo CLE-AUTORISEE";
        let kh = self.known_hosts.to_string_lossy().into_owned();
        let pubk = self.pub_key_path().to_string_lossy().into_owned();
        #[cfg(windows)]
        {
            let bat = app_dir().join("autoriser-cle.bat");
            let content = format!(
                "@echo off\r\nchcp 65001 >nul\r\ntitle Autorisation de la cle NAS Manager\r\n\
echo.\r\necho  Autorisation de la cle de NAS Manager sur {target}\r\n\
echo  Tape le mot de passe du compte {user} quand il est demande (une seule fois).\r\necho.\r\n\
type \"{pubk}\" | \"{ssh}\" -p {port} -o StrictHostKeyChecking=yes -o UserKnownHostsFile=\"{kh}\" -o PubkeyAuthentication=no {target} \"{remote}\"\r\n\
if errorlevel 1 (\r\n  echo.\r\n  echo  ECHEC : mot de passe refuse ou NAS injoignable.\r\n) else (\r\n  echo.\r\n  echo  OK : la cle est autorisee. Tu peux fermer cette fenetre et cliquer sur Tester.\r\n)\r\necho.\r\npause\r\n",
                target = h.target(),
                user = h.user,
                pubk = pubk,
                ssh = self.bin,
                port = h.port,
                kh = kh,
                remote = remote
            );
            std::fs::write(&bat, content).map_err(|e| e.to_string())?;
            Command::new("cmd")
                .arg("/c")
                .arg(&bat)
                .creation_flags(CREATE_NEW_CONSOLE)
                .spawn()
                .map_err(|e| e.to_string())?;
            Ok("Une fenêtre s'est ouverte : tape le mot de passe du compte, puis clique sur « Tester ».".into())
        }
        #[cfg(not(windows))]
        {
            Ok(format!(
                "Lance cette commande dans un terminal :\ncat '{pubk}' | {ssh} -p {port} -o StrictHostKeyChecking=yes -o UserKnownHostsFile='{kh}' {target} '{remote}'",
                ssh = self.bin,
                port = h.port,
                target = h.target()
            ))
        }
    }

    /// Oublie l'identite enregistree d'un NAS (apres reinstallation)
    pub fn forget_host(&self, h: &HostCfg) -> Result<(), String> {
        if self.known_hosts.exists() {
            let txt = std::fs::read_to_string(&self.known_hosts).unwrap_or_default();
            let host = h.host.trim();
            let bracket = format!("[{}]:{}", host, h.port);
            let kept: Vec<&str> = txt
                .lines()
                .filter(|l| {
                    let first = l.split_whitespace().next().unwrap_or("");
                    !first.split(',').any(|n| n == host || n == bracket)
                })
                .collect();
            let mut out = kept.join("\n");
            if !out.is_empty() {
                out.push('\n');
            }
            std::fs::write(&self.known_hosts, out).map_err(|e| e.to_string())?;
            if txt.contains("|1|") {
                let mut c = Command::new(self.keygen_bin());
                c.arg("-R").arg(Self::kh_name(h)).arg("-f").arg(&self.known_hosts).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
                #[cfg(windows)]
                c.creation_flags(CREATE_NO_WINDOW);
                let _ = c.status();
                let mut old = self.known_hosts.clone().into_os_string();
                old.push(".old");
                let _ = std::fs::remove_file(old);
            }
        }
        close_session(h);
        Ok(())
    }
}

/// Cles publiques lues sur un NAS, a faire confirmer
#[derive(Clone, Debug)]
pub struct HostScan {
    pub entries: Vec<String>,
    pub fingerprints: Vec<String>,
}

fn connection_error(stderr: &str) -> SshError {
    let low = stderr.to_lowercase();
    if low.contains("permission denied") {
        return SshError::KeyRefused;
    }
    if low.contains("identification has changed") || low.contains("host key verification failed") {
        return SshError::HostKeyChanged;
    }
    let msg = stderr
        .lines()
        .filter(|l| !l.trim().is_empty())
        .last()
        .unwrap_or("connexion impossible")
        .trim()
        .to_string();
    SshError::Unreachable(msg)
}

fn sudo_error(stderr: &str, h: &HostCfg) -> Option<SshError> {
    let low = stderr.to_lowercase();
    if (low.contains("sudo") && low.contains("incorrect password"))
        || low.contains("sorry, try again")
        || low.contains("mot de passe incorrect")
        || low.contains("désolé, essayez de nouveau")
    {
        return Some(SshError::SudoPassword);
    }
    if low.contains("is not in the sudoers") || low.contains("may not run sudo") {
        return Some(SshError::Other(format!(
            "L'utilisateur {} n'a pas le droit d'utiliser sudo (groupe administrators sur le Synology).",
            h.user
        )));
    }
    None
}

// =====================================================================
//  Session persistante
// =====================================================================

type Slot = Arc<Mutex<Option<Session>>>;

fn pool() -> &'static Mutex<HashMap<String, Slot>> {
    static POOL: OnceLock<Mutex<HashMap<String, Slot>>> = OnceLock::new();
    POOL.get_or_init(|| Mutex::new(HashMap::new()))
}

fn slot_key(h: &HostCfg) -> String {
    format!("{}:{}", h.target(), h.port)
}

fn session_slot(h: &HostCfg) -> Slot {
    let mut p = pool().lock().unwrap_or_else(|e| e.into_inner());
    p.entry(slot_key(h)).or_insert_with(|| Arc::new(Mutex::new(None))).clone()
}

fn session_id(h: &HostCfg, pass: Option<&str>) -> String {
    use std::hash::{Hash, Hasher};
    let mut hs = std::collections::hash_map::DefaultHasher::new();
    pass.unwrap_or("").hash(&mut hs);
    format!("{}|{}|{}|{:x}", h.target(), h.port, h.sudo, hs.finish())
}

/// Ferme la session d'un NAS (changement de parametres, d'identite...)
pub fn close_session(h: &HostCfg) {
    let slot = session_slot(h);
    let s = slot.lock().unwrap_or_else(|e| e.into_inner()).take();
    if let Some(s) = s {
        s.kill();
    }
}

struct Session {
    id: String,
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
    stderr: Arc<Mutex<String>>,
    counter: u64,
}

const READY: &str = "__NASMGR_READY__";

impl Session {
    fn open(ssh: &Ssh, h: &HostCfg, pass: Option<&str>, id: String) -> Result<Session, SshError> {
        let remote = if h.sudo { "sudo -S -k -p '' bash -s" } else { "bash -s" };
        let mut child = ssh.spawn_ssh(h, remote)?;
        let mut stdin = child.stdin.take().expect("stdin");
        let stdout = child.stdout.take().expect("stdout");
        let mut se = child.stderr.take().expect("stderr");
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            let mut r = BufReader::new(stdout);
            let mut buf = Vec::new();
            loop {
                buf.clear();
                match r.read_until(b'\n', &mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {
                        let line = String::from_utf8_lossy(&buf).trim_end_matches(['\n', '\r']).to_string();
                        if tx.send(line).is_err() {
                            break;
                        }
                    }
                }
            }
        });
        let errbuf = Arc::new(Mutex::new(String::new()));
        let eb = errbuf.clone();
        std::thread::spawn(move || {
            let mut b = [0u8; 4096];
            loop {
                match se.read(&mut b) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => eb.lock().unwrap_or_else(|e| e.into_inner()).push_str(&String::from_utf8_lossy(&b[..n])),
                }
            }
        });
        let mut init = String::new();
        if h.sudo {
            init.push_str(pass.unwrap_or(""));
            init.push('\n');
        }
        init.push_str("export LC_ALL=C; NASMGR_ERR=$(mktemp 2>/dev/null || echo /tmp/nasmgr.err.$$); echo ");
        init.push_str(READY);
        init.push('\n');
        if stdin.write_all(init.as_bytes()).and_then(|_| stdin.flush()).is_err() {
            let _ = child.kill();
            return Err(connection_error(&errbuf.lock().unwrap_or_else(|e| e.into_inner())));
        }
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match rx.recv_timeout(left.min(Duration::from_millis(200))) {
                Ok(l) if l == READY => break,
                Ok(_) => continue,
                Err(RecvTimeoutError::Timeout) => {
                    let err = errbuf.lock().unwrap_or_else(|e| e.into_inner()).clone();
                    if h.sudo {
                        if let Some(e) = sudo_error(&err, h) {
                            let _ = child.kill();
                            return Err(e);
                        }
                    }
                    if let Ok(Some(_)) = child.try_wait() {
                        return Err(connection_error(&err));
                    }
                    if Instant::now() >= deadline {
                        let _ = child.kill();
                        return Err(SshError::Timeout);
                    }
                }
                Err(RecvTimeoutError::Disconnected) => {
                    let _ = child.wait();
                    let err = errbuf.lock().unwrap_or_else(|e| e.into_inner()).clone();
                    if h.sudo {
                        if let Some(e) = sudo_error(&err, h) {
                            return Err(e);
                        }
                    }
                    return Err(connection_error(&err));
                }
            }
        }
        errbuf.lock().unwrap_or_else(|e| e.into_inner()).clear();
        Ok(Session { id, child, stdin, lines: rx, stderr: errbuf, counter: 0 })
    }

    /// Execute un script dans un sous-shell (un `exit` ou `set -e` n'arrete pas la session)
    fn exec(&mut self, script: &str, timeout: Duration) -> Result<CmdOut, SshError> {
        self.counter += 1;
        let tok = format!("{:x}{:x}", self.counter, Instant::now().elapsed().as_nanos() ^ 0x5eed);
        let end = format!("__NASMGR_END_{tok}__");
        let eend = format!("__NASMGR_EEND_{tok}__");
        let mut body = script.to_string();
        if !body.ends_with('\n') {
            body.push('\n');
        }
        let req = format!(
            "(\n{body}) 2>\"$NASMGR_ERR\" </dev/null\nprintf '\\n{end} %s\\n' \"$?\"\nsed 's/^/E:/' \"$NASMGR_ERR\"; echo {eend}\n"
        );
        self.stdin
            .write_all(req.as_bytes())
            .and_then(|_| self.stdin.flush())
            .map_err(|e| SshError::Other(format!("session : {e}")))?;
        let deadline = Instant::now() + timeout;
        let mut out: Vec<String> = Vec::new();
        let mut err: Vec<String> = Vec::new();
        let mut code: Option<i32> = None;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(SshError::Timeout);
            }
            match self.lines.recv_timeout(left) {
                Ok(l) => {
                    if code.is_none() {
                        if let Some(rest) = l.strip_prefix(&end) {
                            code = Some(rest.trim().parse().unwrap_or(-1));
                        } else {
                            out.push(l);
                        }
                    } else if l == eend {
                        break;
                    } else {
                        err.push(l.strip_prefix("E:").unwrap_or(&l).to_string());
                    }
                }
                Err(RecvTimeoutError::Timeout) => return Err(SshError::Timeout),
                Err(RecvTimeoutError::Disconnected) => {
                    let e = self.stderr.lock().unwrap_or_else(|e| e.into_inner()).clone();
                    return Err(SshError::Other(format!("session fermée : {}", e.trim())));
                }
            }
        }
        // la ligne vide ajoutee avant le marqueur
        if out.last().map(|l| l.is_empty()).unwrap_or(false) {
            out.pop();
        }
        let mut stdout = out.join("\n");
        if !stdout.is_empty() {
            stdout.push('\n');
        }
        let mut stderr = err.join("\n");
        if !stderr.is_empty() {
            stderr.push('\n');
        }
        Ok(CmdOut { code: code.unwrap_or(-1), stdout, stderr })
    }

    fn kill(mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Retire les sequences de couleur ANSI (\e[...m) des sorties des scripts
pub fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars().peekable();
    while let Some(c) = it.next() {
        if c == '\u{1b}' {
            if it.peek() == Some(&'[') {
                it.next();
                while let Some(&n) = it.peek() {
                    it.next();
                    if n.is_ascii_alphabetic() {
                        break;
                    }
                }
            }
            continue;
        }
        if c == '\r' {
            continue;
        }
        out.push(c);
    }
    out
}

/// Protection d'une valeur pour le shell (entre apostrophes)
pub fn sq(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}
