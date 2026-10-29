//! Execution des scripts d'etat et des actions : sur la machine elle-meme (sans SSH),
//! ou sur une autre machine du site par le client ssh du systeme (cle deja autorisee).

use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Clone, Debug, PartialEq)]
pub enum Target {
    /// cette machine ; `sudo` : passer par sudo -n (compte non root)
    Local { sudo: bool },
    /// autre machine : utilisateur@adresse, port, sudo
    Ssh { dest: String, port: u16, sudo: bool },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Debian,
    Synology,
}

pub struct Out {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl Out {
    /// Derniere ligne de la sortie (le JSON des scripts d'etat)
    pub fn last_line(&self) -> &str {
        self.stdout.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("")
    }
    /// Sortie lisible (sans les codes de couleur des scripts)
    pub fn text(&self) -> String {
        let t = format!("{}{}", self.stdout, self.stderr);
        strip_ansi(t.trim())
    }
}

pub fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars().peekable();
    while let Some(c) = it.next() {
        if c == '\u{1b}' {
            if it.peek() == Some(&'[') {
                it.next();
                for d in it.by_ref() {
                    if d.is_ascii_alphabetic() {
                        break;
                    }
                }
            }
            continue;
        }
        out.push(c);
    }
    out
}

/// Utilisateur courant root ?
pub fn is_root() -> bool {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|t| t.lines().find(|l| l.starts_with("Uid:")).map(|l| l.split_whitespace().nth(1) == Some("0")))
        .unwrap_or(false)
}

/// Type de la machine locale : Synology (DSM) ou Debian / OMV
pub fn local_kind() -> Kind {
    if std::path::Path::new("/etc/synoinfo.conf").exists() || std::path::Path::new("/usr/syno").is_dir() {
        Kind::Synology
    } else {
        Kind::Debian
    }
}

impl Target {
    pub fn label(&self) -> String {
        match self {
            Target::Local { .. } => std::fs::read_to_string("/proc/sys/kernel/hostname").map(|h| h.trim().to_string()).unwrap_or_else(|_| "local".into()),
            Target::Ssh { dest, .. } => dest.clone(),
        }
    }

    fn command(&self) -> Command {
        match self {
            Target::Local { sudo } => {
                if *sudo {
                    let mut c = Command::new("sudo");
                    c.args(["-n", "bash", "-s"]);
                    c
                } else {
                    let mut c = Command::new("bash");
                    c.arg("-s");
                    c
                }
            }
            Target::Ssh { dest, port, sudo } => {
                let mut c = Command::new("ssh");
                c.args(["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-p", &port.to_string(), dest]);
                c.arg(if *sudo { "sudo -n bash -s" } else { "bash -s" });
                c
            }
        }
    }

    /// Lance un script bash (sur l'entree standard) ; erreur si delai depasse
    pub fn run(&self, script: &str, timeout: Duration) -> Result<Out, String> {
        let mut child = self
            .command()
            .env("LC_ALL", "C.UTF-8")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("{e}"))?;
        if let Some(mut i) = child.stdin.take() {
            let _ = i.write_all(script.as_bytes());
        }
        let mut so = child.stdout.take();
        let mut se = child.stderr.take();
        let ro = std::thread::spawn(move || {
            let mut s = String::new();
            if let Some(o) = so.as_mut() {
                let _ = o.read_to_string(&mut s);
            }
            s
        });
        let re = std::thread::spawn(move || {
            let mut s = String::new();
            if let Some(o) = se.as_mut() {
                let _ = o.read_to_string(&mut s);
            }
            s
        });
        let t0 = Instant::now();
        let code = loop {
            match child.try_wait() {
                Ok(Some(s)) => break s.code().unwrap_or(-1),
                Ok(None) => {}
                Err(e) => return Err(e.to_string()),
            }
            if t0.elapsed() > timeout {
                let _ = child.kill();
                let _ = child.wait();
                return Err(crate::i18n::tf("délai dépassé ({0} s)", &[&(timeout.as_secs())]));
            }
            std::thread::sleep(Duration::from_millis(50));
        };
        let stdout = ro.join().unwrap_or_default();
        let stderr = re.join().unwrap_or_default();
        if code == 255 && matches!(self, Target::Ssh { .. }) {
            return Err(crate::i18n::tf("connexion SSH impossible : {0}", &[&(stderr.lines().last().unwrap_or("").trim())]));
        }
        if code == 1 && stderr.contains("a password is required") {
            return Err(crate::i18n::tr("sudo demande un mot de passe : lance « sudo nas-manager »").into());
        }
        Ok(Out { code, stdout, stderr })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn execution_locale() {
        let t = Target::Local { sudo: false };
        let o = t.run("echo bonjour; echo '{\"a\":1}'; echo erreur >&2; exit 3", Duration::from_secs(10)).unwrap();
        assert_eq!((o.code, o.last_line()), (3, "{\"a\":1}"));
        assert!(o.text().contains("erreur"));
        assert!(t.run("sleep 5", Duration::from_millis(300)).is_err());
        assert_eq!(strip_ansi("\u{1b}[32mOK\u{1b}[0m fini"), "OK fini");
    }
}
