//! Execution de scripts sur le NAS via le client OpenSSH du systeme
//! (integre a Windows 10/11 : C:\Windows\System32\OpenSSH\ssh.exe).
//!
//! Chaque commande ouvre une connexion, envoie un script bash sur l'entree
//! standard (precede du mot de passe sudo si besoin) et recupere la sortie.

use crate::config::{app_dir, HostCfg};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
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
            SshError::HostKeyChanged => write!(f, "L'identité SSH du NAS a changé (réinstallation ?). Paramètres > Oublier l'identité du NAS."),
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


    fn keygen_bin(&self) -> String {
        // ssh-keygen se trouve a cote de ssh
        let p = PathBuf::from(&self.bin);
        match p.parent() {
            Some(dir) if !dir.as_os_str().is_empty() => {
                let name = if cfg!(windows) { "ssh-keygen.exe" } else { "ssh-keygen" };
                dir.join(name).to_string_lossy().into_owned()
            }
            _ => "ssh-keygen".into(),
        }
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
            "StrictHostKeyChecking=accept-new".into(),
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
        let remote = if h.sudo {
            "sudo -S -k -p '' bash -s"
        } else {
            "bash -s"
        };
        let mut cmd = Command::new(&self.bin);
        cmd.args(self.base_args(h))
            .arg(h.target())
            .arg(remote)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        #[cfg(windows)]
        cmd.creation_flags(CREATE_NO_WINDOW);
        let mut child = cmd.spawn().map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                SshError::NoSshClient
            } else {
                SshError::Other(format!("ssh : {e}"))
            }
        })?;

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
            let low = stderr.to_lowercase();
            if low.contains("permission denied") {
                return Err(SshError::KeyRefused);
            }
            if low.contains("host key verification failed") || low.contains("identification has changed") {
                return Err(SshError::HostKeyChanged);
            }
            let msg = stderr
                .lines()
                .filter(|l| !l.trim().is_empty())
                .last()
                .unwrap_or("connexion impossible")
                .trim()
                .to_string();
            return Err(SshError::Unreachable(msg));
        }
        if h.sudo {
            let low = stderr.to_lowercase();
            if (low.contains("sudo") && (low.contains("incorrect password") || low.contains("sorry, try again")))
                || low.contains("mot de passe incorrect")
            {
                return Err(SshError::SudoPassword);
            }
            if low.contains("is not in the sudoers") || low.contains("may not run sudo") {
                return Err(SshError::Other(format!(
                    "L'utilisateur {} n'a pas le droit d'utiliser sudo (groupe administrators sur le Synology).",
                    h.user
                )));
            }
        }
        Ok(CmdOut { code, stdout, stderr })
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
type \"{pubk}\" | \"{ssh}\" -p {port} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=\"{kh}\" -o PubkeyAuthentication=no {target} \"{remote}\"\r\n\
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
                "Lance cette commande dans un terminal :\ncat '{pubk}' | {ssh} -p {port} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile='{kh}' {target} '{remote}'",
                ssh = self.bin,
                port = h.port,
                target = h.target()
            ))
        }
    }

    /// Oublie l'identite enregistree d'un NAS (apres reinstallation)
    pub fn forget_host(&self, h: &HostCfg) -> Result<(), String> {
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
        std::fs::write(&self.known_hosts, out).map_err(|e| e.to_string())
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
