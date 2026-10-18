//! Parametres de l'application, enregistres en JSON dans le dossier de l'application.

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
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
#[serde(default)]
pub struct Settings {
    pub omv: HostCfg,
    pub syno: HostCfg,
    /// Actualisation automatique (secondes)
    pub refresh_secs: u32,
    /// Executable ssh (vide = "ssh" du systeme, Windows : client OpenSSH integre)
    #[serde(default)]
    pub ssh_bin: String,
    /// "systeme", "clair" ou "sombre"
    #[serde(default = "default_theme")]
    pub theme: String,
    /// Mode lecture seule : aucune action sur les NAS
    #[serde(default)]
    pub read_only: bool,
    /// Derniere version lancee (affichage des nouveautes apres une mise a jour)
    #[serde(default)]
    pub last_version: String,
    /// Notifications Windows (fin de transfert, alertes, connexion perdue)
    #[serde(default = "yes")]
    pub notifications: bool,
    /// Fermer la fenetre = reduire dans la zone de notification
    #[serde(default = "yes")]
    pub close_to_tray: bool,
    /// Nom du site actif (couple OMV + Synology), ex. « Maison »
    #[serde(default = "default_site")]
    pub site: String,
    /// Autres sites enregistres
    #[serde(default)]
    pub sites: Vec<Site>,
    /// Recherche automatique des mises a jour de l'application
    #[serde(default = "yes")]
    pub auto_update: bool,
    #[serde(default)]
    pub last_update_check: i64,
    /// Langue de l'interface : "" (celle de Windows), "fr" ou "en"
    #[serde(default)]
    pub language: String,
    /// Taille du texte (zoom), 1.0 = normal
    #[serde(default = "one")]
    pub zoom: f32,
    /// Mots de passe de chiffrement notes en lieu sur (plus de rappel)
    #[serde(default)]
    pub passwords_noted: bool,
    /// Assistant de premier lancement deja fait
    #[serde(default)]
    pub wizard_done: bool,
}

/// Un site : un OMV et (eventuellement) un Synology
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Site {
    pub name: String,
    pub omv: HostCfg,
    pub syno: HostCfg,
}

fn default_site() -> String {
    "Maison".into()
}

fn one() -> f32 {
    1.0
}

fn yes() -> bool {
    true
}

fn default_theme() -> String {
    "systeme".into()
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
            theme: default_theme(),
            read_only: false,
            last_version: String::new(),
            notifications: true,
            close_to_tray: true,
            site: default_site(),
            sites: Vec::new(),
            auto_update: true,
            last_update_check: 0,
            language: String::new(),
            zoom: 1.0,
            passwords_noted: false,
            wizard_done: false,
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
    match std::fs::read_to_string(settings_path()) {
        Ok(s) => serde_json::from_str::<Settings>(&s)
            .map(|mut st| {
                // installation existante (cle deja creee) : pas d'assistant de premier lancement
                if app_dir().join("id_ed25519").exists() && st.omv.is_set() && !st.last_version.is_empty() {
                    st.wizard_done = true;
                }
                st
            })
            .unwrap_or_default(),
        Err(_) => Settings::default(),
    }
}

impl Settings {
    /// Noms de tous les sites (actif compris), dans l'ordre
    pub fn site_names(&self) -> Vec<String> {
        let mut v = vec![self.site.clone()];
        v.extend(self.sites.iter().map(|s| s.name.clone()));
        v.sort_by_key(|a| a.to_lowercase());
        v
    }

    /// Bascule sur un autre site : le site actif est range dans la liste
    pub fn switch_site(&mut self, name: &str) -> bool {
        let Some(i) = self.sites.iter().position(|s| s.name == name) else { return false };
        let next = self.sites.remove(i);
        let cur = Site { name: self.site.clone(), omv: self.omv.clone(), syno: self.syno.clone() };
        self.sites.push(cur);
        self.site = next.name;
        self.omv = next.omv;
        self.syno = next.syno;
        true
    }
}

pub fn save(s: &Settings) -> Result<(), String> {
    let dir = app_dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let txt = serde_json::to_string_pretty(s).map_err(|e| e.to_string())?;
    std::fs::write(settings_path(), txt).map_err(|e| e.to_string())
}

/// Parametres exportables (sans mot de passe)
pub fn export_json(s: &Settings) -> String {
    let mut c = s.clone();
    c.omv.saved_pass.clear();
    c.syno.saved_pass.clear();
    c.last_version.clear();
    serde_json::to_string_pretty(&c).unwrap_or_default()
}

pub fn import_json(txt: &str) -> Result<Settings, String> {
    let mut s: Settings = serde_json::from_str(txt).map_err(|e| tf("fichier invalide : {0}", &[&e]))?;
    s.omv.saved_pass.clear();
    s.syno.saved_pass.clear();
    Ok(s)
}
