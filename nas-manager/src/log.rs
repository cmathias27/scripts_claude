//! Journal de l'application : %APPDATA%\NasManager\journal.log (1 Mo max, une archive).

use crate::config::app_dir;
use std::io::Write;
use std::sync::Mutex;

static LOCK: Mutex<()> = Mutex::new(());
const MAX: u64 = 1_000_000;

pub fn path() -> std::path::PathBuf {
    app_dir().join("journal.log")
}

fn write(level: &str, msg: &str) {
    let _g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let p = path();
    let _ = std::fs::create_dir_all(app_dir());
    if std::fs::metadata(&p).map(|m| m.len() > MAX).unwrap_or(false) {
        let _ = std::fs::rename(&p, app_dir().join("journal.1.log"));
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&p) {
        let line = msg.replace('\n', " | ");
        let _ = writeln!(f, "{} [{level}] {line}", chrono::Local::now().format("%Y-%m-%d %H:%M:%S"));
    }
}

pub fn info(msg: &str) {
    write("INFO", msg);
}

pub fn warn(msg: &str) {
    write("ATTENTION", msg);
}

pub fn error(msg: &str) {
    write("ERREUR", msg);
}

/// Dernieres lignes du journal
pub fn tail(n: usize) -> String {
    let _g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let t = std::fs::read_to_string(path()).unwrap_or_default();
    let lines: Vec<&str> = t.lines().collect();
    lines[lines.len().saturating_sub(n)..].join("\n")
}
