//! Parametres de l'application, enregistres en JSON dans le dossier de l'application.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct HostCfg {
    pub host: String,
    pub port: u16,
    pub user: String,
    /// Passer par `sudo` (compte administrateur non root, ex. Synology)
    pub sudo: bool,
    /// Mot de passe sudo chiffre par Windows (DPAPI), en base64. Vide = non memorise.
    #[serde(default)]
    pub saved_pass: String,
}

impl HostCfg {
    pub fn is_set(&self) -> bool {
        !self.host.trim().is_empty() && !self.user.trim().is_empty()
    }
    pub fn target(&self) -> String {
        format!("{}@{}", self.user.trim(), self.host.trim())
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Settings {
    pub omv: HostCfg,
    pub syno: HostCfg,
    /// Actualisation automatique (secondes)
    pub refresh_secs: u32,
    /// Executable ssh (vide = "ssh" du systeme, Windows : client OpenSSH integre)
    #[serde(default)]
    pub ssh_bin: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            omv: HostCfg {
                host: "192.168.1.190".into(),
                port: 22,
                user: "root".into(),
                sudo: false,
                saved_pass: String::new(),
            },
            syno: HostCfg {
                host: String::new(),
                port: 22,
                user: String::new(),
                sudo: true,
                saved_pass: String::new(),
            },
            refresh_secs: 10,
            ssh_bin: String::new(),
        }
    }
}

/// Dossier de l'application : %APPDATA%\NasManager (Windows), ~/.config/nas-manager ailleurs.
/// La variable NAS_MANAGER_DIR permet de le changer.
pub fn app_dir() -> PathBuf {
    if let Ok(d) = std::env::var("NAS_MANAGER_DIR") {
        return PathBuf::from(d);
    }
    #[cfg(windows)]
    {
        if let Ok(a) = std::env::var("APPDATA") {
            return PathBuf::from(a).join("NasManager");
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".config").join("nas-manager")
}

fn settings_path() -> PathBuf {
    app_dir().join("parametres.json")
}

pub fn load() -> Settings {
    std::fs::read_to_string(settings_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub fn save(s: &Settings) -> Result<(), String> {
    let dir = app_dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let txt = serde_json::to_string_pretty(s).map_err(|e| e.to_string())?;
    std::fs::write(settings_path(), txt).map_err(|e| e.to_string())
}
