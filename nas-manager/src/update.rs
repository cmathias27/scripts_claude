//! Mise a jour de l'application depuis les Releases GitHub, sans installateur :
//! le nouvel executable est telecharge (curl.exe, integre a Windows 10/11),
//! remplace l'ancien (un exe en cours d'execution peut etre renomme) et relance.

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::app::App;
use serde::Deserialize;

pub const REPO: &str = "cmathias27/scripts_claude";
const ASSET: &str = "nas-manager.exe";

#[derive(Clone, Debug, Default)]
pub struct UpdateInfo {
    pub version: String,
    pub notes: String,
    pub url: String,

}

#[derive(Default)]
pub struct UpdateState {
    pub checking: bool,
    pub available: Option<UpdateInfo>,
    pub installing: bool,
    pub message: String,
    pub dismissed: bool,
}

#[derive(Deserialize)]
struct Release {
    tag_name: String,
    #[serde(default)]
    body: String,
    #[serde(default)]
    assets: Vec<Asset>,
}

#[derive(Deserialize)]
struct Asset {
    name: String,
    browser_download_url: String,
}

/// "1.0.0-beta.5" -> ([1,0,0], Some(5)) ; une version finale est plus recente que ses betas
fn parse(v: &str) -> (Vec<u64>, Option<u64>) {
    let v = v.trim().trim_start_matches('v');
    let (main, pre) = match v.split_once('-') {
        Some((m, p)) => (m, Some(p)),
        None => (v, None),
    };
    let nums = main.split('.').map(|x| x.parse().unwrap_or(0)).collect();
    let pre = pre.map(|p| p.rsplit('.').next().and_then(|n| n.parse().ok()).unwrap_or(0));
    (nums, pre)
}

pub fn is_newer(candidate: &str, current: &str) -> bool {
    let (a, ap) = parse(candidate);
    let (b, bp) = parse(current);
    if a != b {
        return a > b;
    }
    match (ap, bp) {
        (None, Some(_)) => true,
        (Some(x), Some(y)) => x > y,
        _ => false,
    }
}

fn curl() -> std::process::Command {
    let mut c = std::process::Command::new(if cfg!(windows) { "curl.exe" } else { "curl" });
    c.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000);
    }
    c
}

/// Derniere version publiee (None si deja a jour)
pub fn check(current: &str) -> Result<Option<UpdateInfo>, String> {
    let out = curl()
        .args(["-sSfL", "-m", "20", "-H", "Accept: application/vnd.github+json", "-H", "User-Agent: nas-manager"])
        .arg(format!("https://api.github.com/repos/{REPO}/releases/latest"))
        .output()
        .map_err(|e| tf("curl introuvable : {0}", &[&e]))?;
    if !out.status.success() {
        return Err(tf("GitHub injoignable : {0}", &[&(String::from_utf8_lossy(&out.stderr).trim())]));
    }
    let r: Release = serde_json::from_slice(&out.stdout).map_err(|e| tf("réponse GitHub inattendue : {0}", &[&e]))?;
    let version = r.tag_name.trim_start_matches('v').to_string();
    if !is_newer(&version, current) {
        return Ok(None);
    }
    let url = r
        .assets
        .iter()
        .find(|a| a.name == ASSET)
        .map(|a| a.browser_download_url.clone())
        .ok_or(tr("exécutable absent de la dernière version"))?;
    Ok(Some(UpdateInfo { version, notes: r.body, url }))
}

/// Telecharge et met en place la nouvelle version ; renvoie le chemin de l'executable a relancer
pub fn install(info: &UpdateInfo) -> Result<std::path::PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let dir = exe.parent().ok_or(tr("dossier de l'application introuvable"))?.to_path_buf();
    let new = dir.join("nas-manager.new.exe");
    let old = dir.join("nas-manager.old.exe");
    let out = curl()
        .args(["-sSfL", "-m", "300", "-o"])
        .arg(&new)
        .arg(&info.url)
        .output()
        .map_err(|e| tf("curl introuvable : {0}", &[&e]))?;
    if !out.status.success() {
        let _ = std::fs::remove_file(&new);
        return Err(tf("téléchargement impossible : {0}", &[&(String::from_utf8_lossy(&out.stderr).trim())]));
    }
    // controle : un executable Windows commence par « MZ » et pese plusieurs Mo
    let head = std::fs::read(&new).map_err(|e| e.to_string())?;
    if head.len() < 1_000_000 || &head[..2] != b"MZ" {
        let _ = std::fs::remove_file(&new);
        return Err(tr("fichier téléchargé invalide").into());
    }
    let _ = std::fs::remove_file(&old);
    std::fs::rename(&exe, &old).map_err(|e| {
        let _ = std::fs::remove_file(&new);
        tf("remplacement impossible ({0}) : le dossier de l'application est-il protégé en écriture ?", &[&e])
    })?;
    if let Err(e) = std::fs::rename(&new, &exe) {
        let _ = std::fs::rename(&old, &exe);
        return Err(tf("remplacement impossible : {0}", &[&e]));
    }
    Ok(exe)
}

/// Au demarrage : supprime l'ancien executable laisse par une mise a jour
pub fn cleanup() {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(d) = exe.parent() {
            let _ = std::fs::remove_file(d.join("nas-manager.old.exe"));
            let _ = std::fs::remove_file(d.join("nas-manager.new.exe"));
        }
    }
}

/// Recherche en arriere-plan (au demarrage, une fois par jour, ou a la demande)
pub fn start_check(app: &mut App, manual: bool) {
    if app.update.checking {
        return;
    }
    app.update.checking = true;
    app.update.message.clear();
    let tx = app.tx.clone();
    let ctx = app.ctx.clone();
    std::thread::spawn(move || {
        let r = check(crate::extras::VERSION);
        let h: crate::app::Handler = Box::new(move |app: &mut App, _| {
            app.update.checking = false;
            app.settings.last_update_check = crate::fmt::now();
            app.edit.last_update_check = app.settings.last_update_check;
            let _ = crate::config::save(&app.settings);
            match r {
                Ok(Some(i)) => {
                    crate::log::info(&format!("mise à jour disponible : {}", i.version));
                    app.update.message.clear();
                    app.update.available = Some(i);
                    app.update.dismissed = false;
                }
                Ok(None) => {
                    app.update.message = tr("NAS Manager est à jour.").into();
                    if manual {
                        app.toast(true, tr("NAS Manager est à jour.").into());
                    }
                }
                Err(e) => {
                    app.update.message = e.clone();
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

pub fn start_install(app: &mut App) {
    let Some(info) = app.update.available.clone() else { return };
    if app.update.installing {
        return;
    }
    app.update.installing = true;
    crate::log::info(&format!("installation de la version {}", info.version));
    let tx = app.tx.clone();
    let ctx = app.ctx.clone();
    std::thread::spawn(move || {
        let r = install(&info);
        let h: crate::app::Handler = Box::new(move |app: &mut App, _| {
            app.update.installing = false;
            match r {
                Ok(exe) => {
                    crate::log::info("mise à jour installée : redémarrage");
                    let _ = std::process::Command::new(exe).spawn();
                    app.quitting = true;
                    app.ctx.send_viewport_cmd(eframe::egui::ViewportCommand::Close);
                }
                Err(e) => {
                    crate::log::error(&format!("mise à jour : {e}"));
                    app.toast(false, tf("Mise à jour impossible : {0}", &[&e]));
                }
            }
        });
        let _ = tx.send(crate::app::Msg::Done(h, Err(crate::ssh::SshError::Other(String::new()))));
        ctx.request_repaint();
    });
}

#[cfg(test)]
mod tests {
    use super::is_newer;
    #[test]
    fn versions() {
        assert!(is_newer("1.0.0", "1.0.0-beta.5"));
        assert!(is_newer("1.0.0-beta.6", "1.0.0-beta.5"));
        assert!(is_newer("v1.1.0", "1.0.0"));
        assert!(!is_newer("1.0.0-beta.5", "1.0.0-beta.5"));
        assert!(!is_newer("1.0.0-beta.9", "1.0.0"));
        assert!(!is_newer("0.9", "1.0.0-beta.1"));
    }
}

#[cfg(test)]
mod live {
    /// Interroge vraiment GitHub (NAS_MANAGER_LIVE_TEST)
    #[test]
    fn github() {
        if std::env::var("NAS_MANAGER_LIVE_TEST").is_err() {
            return;
        }
        match super::check("0.0.1") {
            Ok(Some(i)) => assert!(i.url.ends_with("nas-manager.exe"), "{}", i.url),
            Ok(None) => panic!("une version devrait etre plus recente que 0.0.1"),
            // GitHub peut limiter les requetes anonymes : on ne fait pas echouer les tests pour ca
            Err(e) => eprintln!("GitHub indisponible : {e}"),
        }
        assert!(super::check("999.0.0").map(|r| r.is_none()).unwrap_or(true));
    }
}
