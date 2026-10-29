//! Connexion oCIS unique (adresse, compte, jeton, adresse locale, certificat) : réglée une
//! seule fois dans l'application, utilisée par la migration depuis ce PC et recopiée
//! automatiquement sur le Synology et l'OMV / Debian (migration et transferts oCIS -> NAS).
//!
//! - gardée dans `ocis-connexion.json` (jeton chiffré DPAPI sous Windows) ;
//! - chaque machine garde une copie (le script en a besoin pour travailler seul) avec une
//!   empreinte `OCIS_SIG` : dès qu'elle diffère de celle de l'application (connexion modifiée
//!   ici, ou à la main dans le menu du script), la connexion commune y est recopiée ;
//! - au premier lancement, la connexion déjà réglée (ce PC, sinon une machine) est reprise.

use crate::app::{App, HostId, OcisForm};
use crate::config::app_dir;
#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::model::OcisConf;
use crate::pcmig::PcConf;
use crate::remote;
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

const HOSTS: [HostId; 2] = [HostId::Syno, HostId::Omv];

fn path() -> PathBuf {
    app_dir().join("ocis-connexion.json")
}

fn read_file() -> Option<PcConf> {
    std::fs::read_to_string(path()).ok().and_then(|t| serde_json::from_str::<PcConf>(&t).ok()).filter(|c| !c.url.trim().is_empty())
}

fn cell() -> &'static Mutex<Option<PcConf>> {
    static CONN: OnceLock<Mutex<Option<PcConf>>> = OnceLock::new();
    CONN.get_or_init(|| Mutex::new(read_file()))
}

fn lock() -> std::sync::MutexGuard<'static, Option<PcConf>> {
    cell().lock().unwrap_or_else(|e| e.into_inner())
}

/// Connexion commune (None = pas encore réglée)
pub fn get() -> Option<PcConf> {
    lock().clone()
}

/// Enregistre la connexion commune (ne la recopie pas : voir `apply`)
pub fn set(c: Option<PcConf>) {
    *lock() = c.clone();
    persist(c.as_ref());
}

/// Mode d'envoi trouvé par rclone sur ce PC (owncloud ou infinitescale)
pub fn set_vendor(v: &str) {
    let mut g = lock();
    if let Some(c) = g.as_mut() {
        c.vendor = v.to_string();
        let c = c.clone();
        drop(g);
        persist(Some(&c));
    }
}

fn persist(c: Option<&PcConf>) {
    let p = path();
    match c {
        None => {
            let _ = std::fs::remove_file(&p);
        }
        Some(c) => {
            let _ = std::fs::create_dir_all(app_dir());
            if let Ok(t) = serde_json::to_string_pretty(c) {
                let _ = std::fs::write(&p, t);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ = std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600));
                }
            }
        }
    }
}

/// Empreinte de la connexion (jeton compris) : 16 caractères hexadécimaux.
/// Gardée sur chaque machine (OCIS_SIG) pour savoir si sa copie est à jour.
pub fn sig(c: &PcConf) -> String {
    let h = Sha256::digest(format!("{}\n{}\n{}\n{}\n{}", c.url.trim(), c.user.trim(), c.secret(), c.local.trim(), c.insecure as u8).as_bytes());
    h.iter().take(8).map(|b| format!("{b:02x}")).collect()
}

/// Adresse normalisée (https:// ajouté, sans / final)
pub fn norm_url(u: &str) -> String {
    let u = u.trim().trim_end_matches('/');
    if u.is_empty() || u.starts_with("http://") || u.starts_with("https://") {
        u.to_string()
    } else {
        format!("https://{u}")
    }
}

// =====================================================================
//  Recopie sur les machines
// =====================================================================

/// État de la copie de la connexion sur une machine
#[derive(Default, Clone)]
pub struct HostSync {
    pub busy: bool,
    /// empreinte déjà envoyée (ou trouvée à jour) pendant cette session
    pub sent: String,
    pub err: Option<String>,
    import_tried: bool,
}

#[derive(Default)]
pub struct Sync {
    pub hosts: [HostSync; 2],
    /// test de la connexion saisie (depuis ce PC) en cours
    pub testing: bool,
    pub msg: Option<(bool, String)>,
    result: Arc<Mutex<Option<Result<PcConf, String>>>>,
    importing: bool,
}

fn idx(h: HostId) -> usize {
    match h {
        HostId::Syno => 0,
        HostId::Omv => 1,
    }
}

impl Sync {
    pub fn host(&self, h: HostId) -> &HostSync {
        &self.hosts[idx(h)]
    }
    fn host_mut(&mut self, h: HostId) -> &mut HostSync {
        &mut self.hosts[idx(h)]
    }
}

/// Copie de la connexion sur la machine : (le script sait la recevoir, connexion actuelle).
/// None : machine injoignable, ou mot de passe sudo pas encore saisi (rien n'est lancé
/// sans lui, pour ne pas ouvrir de fenêtre de mot de passe au démarrage).
pub fn host_conf(app: &App, h: HostId) -> Option<(bool, Option<OcisConf>)> {
    if !app.host_connected(h) || (app.host_cfg(h).sudo && app.pass_of(h).is_none()) {
        return None;
    }
    match h {
        HostId::Syno => app.syno.status.as_ref().map(|s| (s.migration.installe, s.migration.config.clone())),
        HostId::Omv => app.omv.status.as_ref().map(|s| match &s.migration {
            Some(m) => (true, m.config.clone()),
            None => (false, None),
        }),
    }
}

/// État affiché pour une machine
pub enum HostState {
    /// machine non suivie ou injoignable
    Offline,
    /// script trop ancien pour la migration oCIS
    OldScript,
    Busy,
    Error(String),
    UpToDate,
    /// copie différente, pas encore recopiée (lecture seule)
    Pending,
}

pub fn host_state(app: &App, h: HostId) -> HostState {
    let Some(c) = get() else { return HostState::Pending };
    let Some((ok, conf)) = host_conf(app, h) else { return HostState::Offline };
    if !ok {
        return HostState::OldScript;
    }
    let st = app.ocis_sync.host(h);
    if st.busy {
        return HostState::Busy;
    }
    if let Some(e) = &st.err {
        return HostState::Error(e.clone());
    }
    let s = sig(&c);
    if conf.map(|x| x.signature == s).unwrap_or(false) || st.sent == s {
        HostState::UpToDate
    } else {
        HostState::Pending
    }
}

/// Nouvelle connexion commune : enregistrée, utilisée par ce PC, recopiée sur les machines
pub fn apply(app: &mut App, c: Option<PcConf>) {
    set(c.clone());
    crate::pcmig::set_conf(app, c);
    for h in HOSTS {
        let st = app.ocis_sync.host_mut(h);
        st.err = None;
        st.sent.clear();
    }
}

/// Renvoie la connexion à une machine (après un échec)
pub fn retry(app: &mut App, h: HostId) {
    let st = app.ocis_sync.host_mut(h);
    st.err = None;
    st.sent.clear();
}

/// Appelé à chaque image : résultat du test, reprise d'une connexion existante, recopie
pub fn tick(app: &mut App) {
    // ---- résultat du test de la connexion saisie
    let res = app.ocis_sync.result.lock().unwrap_or_else(|e| e.into_inner()).take();
    if let Some(r) = res {
        app.ocis_sync.testing = false;
        match r {
            Ok(c) => {
                app.ocis_sync.msg = Some((true, tr("Connexion OK : enregistrée pour ce PC et recopiée sur les machines.").into()));
                crate::log::info("connexion oCIS commune modifiée");
                apply(app, Some(c));
            }
            Err(e) => app.ocis_sync.msg = Some((false, e)),
        }
    }
    if app.ocis_sync.testing {
        return;
    }
    match get() {
        None => import(app),
        Some(c) => push(app, &c),
    }
}

/// Pas encore de connexion dans l'application : reprend celle d'une machine qui en a une
fn import(app: &mut App) {
    if app.ocis_sync.importing {
        return;
    }
    for h in HOSTS {
        let has = host_conf(app, h).and_then(|(_, c)| c).map(|c| !c.url.is_empty()).unwrap_or(false);
        if !has || app.ocis_sync.host(h).import_tried {
            continue;
        }
        app.ocis_sync.host_mut(h).import_tried = true;
        app.ocis_sync.importing = true;
        app.exec(
            h,
            tr("Connexion oCIS"),
            remote::migre_export(),
            30,
            Box::new(move |app, r| {
                app.ocis_sync.importing = false;
                let Ok(o) = r else { return };
                let l: Vec<&str> = o.stdout.lines().collect();
                if o.code != 0 || l.len() < 5 || l[0].trim().is_empty() || l[2].is_empty() || get().is_some() {
                    return;
                }
                let c = PcConf {
                    url: norm_url(l[0]),
                    user: l[1].trim().to_string(),
                    token: PcConf::store_secret(l[2]),
                    local: norm_url(l[3]),
                    insecure: l[4].trim() == "1",
                    vendor: String::new(),
                };
                crate::log::info(&format!("connexion oCIS commune reprise de {}", h.label()));
                apply(app, Some(c));
                app.toast(true, tf("Connexion oCIS reprise de {0} : elle est maintenant commune à toutes les machines.", &[&h.label()]));
            }),
        );
        return;
    }
}

fn push(app: &mut App, c: &PcConf) {
    let s = sig(c);
    for h in HOSTS {
        let Some((ok, conf)) = host_conf(app, h) else { continue };
        let st = app.ocis_sync.host(h);
        if !ok || st.busy || st.sent == s {
            continue;
        }
        if conf.as_ref().map(|x| x.signature == s).unwrap_or(false) {
            let st = app.ocis_sync.host_mut(h);
            st.sent = s.clone();
            st.err = None;
            continue;
        }
        if app.settings.read_only {
            continue;
        }
        {
            let st = app.ocis_sync.host_mut(h);
            st.busy = true;
            st.sent = s.clone();
            st.err = None;
        }
        crate::log::info(&format!("connexion oCIS commune recopiée sur {}", h.label()));
        let script = remote::migre_configure(h, &c.url, &c.user, &c.secret(), &c.local, c.insecure, &s);
        app.exec(
            h,
            tr("Connexion oCIS"),
            script,
            300,
            Box::new(move |app, r| {
                let st = app.ocis_sync.host_mut(h);
                st.busy = false;
                match r {
                    Ok(o) if o.code == 0 => {
                        st.err = None;
                        app.mig.auto_loaded = false;
                        app.refresh(h);
                    }
                    Ok(o) => st.err = Some(o.text().trim().lines().last().unwrap_or("").to_string()),
                    Err(e) => st.err = Some(e.to_string()),
                }
            }),
        );
    }
}

/// Teste la connexion saisie depuis ce PC (sans rien enregistrer) ; le résultat arrive dans `tick`
pub fn test_and_save(app: &mut App, f: &OcisForm) {
    let token = if f.token.trim().is_empty() { get().map(|c| c.token).unwrap_or_default() } else { PcConf::store_secret(f.token.trim()) };
    let c = PcConf { url: norm_url(&f.url), user: f.user.trim().to_string(), token, local: norm_url(&f.local), insecure: f.insecure, vendor: String::new() };
    app.ocis_sync.testing = true;
    app.ocis_sync.msg = None;
    let out = app.ocis_sync.result.clone();
    let ctx = app.ctx.clone();
    std::thread::spawn(move || {
        let r = crate::pcmig::check_api(&c).map(|_| c);
        *out.lock().unwrap_or_else(|e| e.into_inner()) = Some(r);
        ctx.request_repaint();
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empreinte() {
        let a = PcConf { url: "https://cloud.maison.fr".into(), user: "alice".into(), token: "clair:secret".into(), local: "https://192.168.1.53:9200".into(), insecure: true, vendor: "owncloud".into() };
        let s = sig(&a);
        assert_eq!(s.len(), 16);
        assert!(s.chars().all(|c| c.is_ascii_hexdigit()));
        // le mode d'envoi propre à ce PC ne compte pas ; le jeton, si
        assert_eq!(sig(&PcConf { vendor: String::new(), ..a.clone() }), s);
        assert_ne!(sig(&PcConf { token: "clair:autre".into(), ..a.clone() }), s);
        assert_ne!(sig(&PcConf { local: String::new(), ..a.clone() }), s);
        assert_eq!(norm_url("cloud.maison.fr/"), "https://cloud.maison.fr");
        assert_eq!(norm_url("http://192.168.1.53:9200"), "http://192.168.1.53:9200");
        assert_eq!(norm_url(" "), "");
    }
}
