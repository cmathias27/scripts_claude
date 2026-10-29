//! Etat de l'application, communication avec les NAS, fenetres de dialogue.

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::config::{self, HostCfg, Settings};
use crate::model::*;
use crate::remote;
use crate::secret;
use crate::ssh::{CmdOut, Ssh, SshError};
use eframe::egui::{self, Color32, RichText};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum HostId {
    Omv,
    Syno,
}

impl HostId {
    pub fn label(self) -> &'static str {
        match self {
            HostId::Omv => "OMV",
            HostId::Syno => "Synology",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Page {
    Dashboard,
    Backups,
    Realtime,
    Destinations,
    History,
    Alerts,
    Copy,
    Migration,
    Logs,
    Install,
    Help,
    Settings,
}

pub type Handler = Box<dyn FnOnce(&mut App, Result<CmdOut, SshError>) + Send>;

pub enum Msg {
    Status(HostId, Result<CmdOut, SshError>),
    Done(Handler, Result<CmdOut, SshError>),
}

pub struct HostState<T> {
    pub status: Option<T>,
    pub error: Option<SshError>,
    pub last_ok: Option<Instant>,
    pub last_poll: Option<Instant>,
    pub polling: bool,
    pub pass: Option<String>,
}

impl<T> Default for HostState<T> {
    fn default() -> Self {
        Self {
            status: None,
            error: None,
            last_ok: None,
            last_poll: None,
            polling: false,
            pass: None,
        }
    }
}

pub struct Toast {
    pub text: String,
    pub ok: bool,
    pub at: Instant,
}

pub struct OutputDialog {
    pub title: String,
    pub text: String,
    pub ok: bool,
}

pub struct Confirm {
    pub title: String,
    pub text: String,
    pub danger: bool,
    /// Mot a taper pour confirmer (actions irreversibles)
    pub typed_required: Option<String>,
    pub typed: String,
    pub button: String,
    pub action: Option<Box<dyn FnOnce(&mut App)>>,
}

pub struct SudoPrompt {
    pub host: HostId,
    pub pass: String,
    pub remember: bool,
    pub error: bool,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BrowsePurpose {
    BackupSource,
    RestoreTarget,
    CopySource,
    CopyDest,
    MigSource,
    TrDest,
    PermsDir,
    RtSource,
    DestPath,
}

pub struct Browser {
    pub host: HostId,
    pub purpose: BrowsePurpose,
    pub cur: String,
    pub entries: Vec<String>,
    pub loading: bool,
    pub new_folder: String,
}

#[derive(Clone, Default)]
pub struct JobFormState {
    pub new: bool,
    pub name: String,
    pub source: String,
    pub folder: String,
    pub folder_touched: bool,
    /// 0 miroir, 1 copie, 2 versionnee (restic)
    pub mode: u8,
    /// destinations choisies (nom, chiffrer), la premiere sert a la simulation
    pub dests: Vec<(String, bool)>,
    /// versions gardees : jours, semaines, mois, annees
    pub rot: [String; 4],
    pub sched: crate::sched::SchedEdit,
    pub bw: crate::sched::BwEdit,
    pub trash_days: String,
    /// memoire de rclone ("" = reglage de la machine)
    pub memory: String,
    pub error: String,
}

pub use crate::restore::RestoreState;

#[derive(Clone, Default)]
pub struct CopyForm {
    pub src: String,
    pub dst: String,
    /// limite de debit en Mo/s (vide = aucune)
    pub bw: String,
    pub into_folder: bool,
    pub move_files: bool,
    pub src_size: Option<(u64, u64)>,
    pub dst_free: Option<u64>,
    pub sizing: bool,
}

#[derive(Clone, Default)]
pub struct MigForm {
    /// machine de la migration affichee (le formulaire repart de zero si elle change)
    pub host: Option<HostId>,
    pub src: String,
    pub label: String,
    pub sources: Vec<(String, String)>,
    pub spaces: Vec<Space>,
    pub space_idx: Option<usize>,
    pub sub: String,
    /// 0 = garder les originaux, 1 = controler puis supprimer, 2 = controle seul (deja migre)
    pub del_mode: u8,
    pub loading_spaces: bool,
    pub spaces_error: String,
    pub auto_loaded: bool,
}

#[derive(Clone, Default)]
pub struct OcisForm {
    pub open: bool,
    pub url: String,
    pub user: String,
    pub token: String,
    pub local: String,
    pub insecure: bool,
}

#[derive(Clone, Default)]
pub struct PermsForm {
    pub dir: String,
    pub owner: String,
    pub group: String,
}

pub struct LogView {
    pub source: usize,
    pub text: String,
    pub auto: bool,
    pub last_fetch: Option<Instant>,
    pub loading: bool,
    pub filter: String,
}

pub struct App {
    pub ctx: egui::Context,
    pub settings: Settings,
    pub edit: Settings,
    pub ssh: Ssh,
    pub tx: Sender<Msg>,
    pub rx: Receiver<Msg>,
    pub page: Page,
    pub omv: HostState<OmvStatus>,
    pub syno: HostState<SynoStatus>,
    pub busy: Vec<String>,
    pub toasts: Vec<Toast>,
    pub output: Option<OutputDialog>,
    pub confirm: Option<Confirm>,
    pub sudo: Option<SudoPrompt>,
    pub browser: Option<Browser>,
    pub job_form: Option<JobFormState>,
    pub restore: Option<RestoreState>,
    pub copy: CopyForm,
    pub mig: MigForm,
    pub ocis: OcisForm,
    pub perms: PermsForm,
    pub logs: LogView,
    pub backup_sources: Vec<String>,
    pub sources_loaded: bool,
    pub passwords: Option<String>,
    pub key_msg: String,
    pub fingerprint: Option<crate::extras::Fingerprint>,
    /// Identite refusee par l'utilisateur : ne plus la redemander automatiquement
    pub fp_dismissed: [bool; 2],
    pub show_news: bool,
    pub tray: Option<crate::tray::Tray>,
    pub hidden: bool,
    pub quitting: bool,
    /// Erreurs de connexion consecutives (notification "NAS injoignable")
    pub err_streak: [u32; 2],
    pub autostart: bool,
    pub history: crate::history::HistoryState,
    /// edition de la verification automatique : (jours, heure)
    pub verif_edit: Option<([bool; 7], String)>,
    pub update: crate::update::UpdateState,
    /// nom saisi pour un nouveau site
    pub new_site: String,
    pub install: crate::install::InstallState,
    /// assistant de premier lancement : etape affichee
    pub wizard: Option<u8>,
    /// scripts des NAS : versions publiees sur GitHub
    pub scripts: crate::scripts::ScriptsState,
    /// formulaire de sauvegarde temps reel ouvert
    pub rt_form: Option<crate::realtime::RtForm>,
    /// page Destinations : formulaire, connexion en cours, kit de secours
    pub dests: crate::dests::DestUi,
    /// page Alertes : canal en cours d'ajout, rapport, seuils
    pub notifs: crate::notifs::NotifUi,
    /// test de restauration, reveil des machines (etape 5)
    pub fiab: crate::fiabilite::FiabUi,
    pub ocis_ui: crate::ocis::OcisUi,
    pub pcmig: crate::pcmig::PcMig,
}

impl App {
    pub fn new(cc: &eframe::CreationContext<'_>) -> Self {
        crate::theme::apply(&cc.egui_ctx);
        let settings = config::load();
        let (tx, rx) = channel();
        let ssh = Ssh::new(&settings.ssh_bin);
        let mut app = Self {
            ctx: cc.egui_ctx.clone(),
            edit: settings.clone(),
            settings,
            ssh,
            tx,
            rx,
            page: Page::Dashboard,
            omv: HostState::default(),
            syno: HostState::default(),
            busy: Vec::new(),
            toasts: Vec::new(),
            output: None,
            confirm: None,
            sudo: None,
            browser: None,
            job_form: None,
            restore: None,
            copy: CopyForm {
                into_folder: true,
                ..Default::default()
            },
            mig: MigForm::default(),
            ocis: OcisForm::default(),
            perms: PermsForm {
                owner: "root".into(),
                group: "users".into(),
                ..Default::default()
            },
            logs: LogView {
                source: 0,
                text: String::new(),
                auto: true,
                last_fetch: None,
                loading: false,
                filter: String::new(),
            },
            backup_sources: Vec::new(),
            sources_loaded: false,
            passwords: None,
            key_msg: String::new(),
            fingerprint: None,
            fp_dismissed: [false, false],
            show_news: false,
            tray: None,
            hidden: std::env::args().any(|a| a == "--minimise"),
            quitting: false,
            err_streak: [0, 0],
            autostart: crate::tray::autostart_enabled(),
            history: Default::default(),
            verif_edit: None,
            update: Default::default(),
            new_site: String::new(),
            install: Default::default(),
            wizard: None,
            scripts: Default::default(),
            rt_form: None,
            dests: Default::default(),
            notifs: Default::default(),
            fiab: Default::default(),
            ocis_ui: Default::default(),
            pcmig: crate::pcmig::PcMig::load(),
        };
        crate::i18n::set_language(&app.settings.language);
        if !app.settings.wizard_done {
            app.wizard = Some(0);
            app.show_news = false;
        }
        crate::update::cleanup();
        if app.settings.auto_update && crate::fmt::now() - app.settings.last_update_check > 20 * 3600 {
            crate::update::start_check(&mut app, false);
        }
        app.tray = crate::tray::create(&app);
        crate::extras::apply_theme(&app.ctx, &app.settings.theme);
        app.ctx.set_zoom_factor(app.settings.zoom.clamp(0.8, 1.8));
        crate::log::info(&format!("démarrage de NAS Manager {}", crate::extras::VERSION));
        // Nouveautes affichees apres une mise a jour
        if app.settings.last_version != crate::extras::VERSION {
            // (pas au premier lancement : l'assistant s'affiche)
            app.show_news = app.wizard.is_none();
            app.settings.last_version = crate::extras::VERSION.to_string();
            app.edit.last_version = app.settings.last_version.clone();
            let _ = config::save(&app.settings);
        }
        // Mots de passe sudo memorises (DPAPI)
        if !app.settings.omv.saved_pass.is_empty() {
            app.omv.pass = secret::unprotect(&app.settings.omv.saved_pass);
        }
        if !app.settings.syno.saved_pass.is_empty() {
            app.syno.pass = secret::unprotect(&app.settings.syno.saved_pass);
        }
        if !app.ssh.key_exists() {
            if let Err(e) = app.ssh.generate_key() {
                app.key_msg = e;
            }
        }
        if !app.settings.omv.is_set() || !app.ssh.key_exists() {
            app.page = Page::Settings;
        }
        #[cfg(debug_assertions)]
        if let Ok(p) = std::env::var("NAS_MANAGER_TEST_SUDO") {
            app.syno.pass = Some(p);
        }
        // Page de depart (captures d'ecran / depannage)
        if let Ok(p) = std::env::var("NAS_MANAGER_PAGE") {
            app.page = match p.as_str() {
                "sauvegardes" => Page::Backups,
                "historique" => Page::History,
                "temps-reel" | "cameras" => Page::Realtime,
                "destinations" => Page::Destinations,
                "alertes" => Page::Alerts,
                "copie" => Page::Copy,
                "migration" | "ocis" => Page::Migration,
                "ocis-omv" | "ocis-pc" | "ocis-transferts" => {
                    app.ocis_ui.src = Some(if p == "ocis-pc" { crate::ocis::Src::Pc } else { crate::ocis::Src::Omv });
                    app.ocis_ui.tab = (p == "ocis-transferts") as u8;
                    app.ocis_ui.tr_host = Some(HostId::Omv);
                    Page::Migration
                }
                "journaux" => Page::Logs,
                "installation" => Page::Install,
                "aide" => Page::Help,
                "parametres" => Page::Settings,
                _ => Page::Dashboard,
            };
        }
        app
    }

    pub fn host_cfg(&self, h: HostId) -> &HostCfg {
        match h {
            HostId::Omv => &self.settings.omv,
            HostId::Syno => &self.settings.syno,
        }
    }

    fn pass_of(&self, h: HostId) -> Option<String> {
        match h {
            HostId::Omv => self.omv.pass.clone(),
            HostId::Syno => self.syno.pass.clone(),
        }
    }

    pub fn host_error(&self, h: HostId) -> Option<&SshError> {
        match h {
            HostId::Omv => self.omv.error.as_ref(),
            HostId::Syno => self.syno.error.as_ref(),
        }
    }

    pub fn host_connected(&self, h: HostId) -> bool {
        match h {
            HostId::Omv => self.omv.error.is_none() && self.omv.status.is_some(),
            HostId::Syno => self.syno.error.is_none() && self.syno.status.is_some(),
        }
    }

    // ------------------------------------------------------------------
    //  Execution des commandes
    // ------------------------------------------------------------------

    /// Execute un script sur un NAS en arriere-plan ; `handler` recoit le resultat.
    pub fn exec(&mut self, host: HostId, label: &str, script: String, timeout_s: u64, handler: Handler) {
        let cfg = self.host_cfg(host).clone();
        if cfg.sudo && self.pass_of(host).is_none() {
            self.ask_sudo(host, false);
            self.toast(false, tf("{0} : mot de passe sudo nécessaire.", &[&(host.label())]));
            return;
        }
        let pass = self.pass_of(host);
        let ssh = self.ssh.clone();
        let tx = self.tx.clone();
        let ctx = self.ctx.clone();
        let label = label.to_string();
        self.busy.push(label.clone());
        std::thread::spawn(move || {
            let r = ssh.run(&cfg, pass.as_deref(), &script, Duration::from_secs(timeout_s));
            let wrapped: Handler = Box::new(move |app: &mut App, res| {
                if let Some(i) = app.busy.iter().position(|b| *b == label) {
                    app.busy.remove(i);
                }
                if let Err(SshError::SudoPassword) = &res {
                    app.forget_pass(host);
                    app.ask_sudo(host, true);
                }
                handler(app, res)
            });
            let _ = tx.send(Msg::Done(wrapped, r));
            ctx.request_repaint();
        });
    }

    /// Mode lecture seule : refuse l'action (renvoie true si bloquee)
    pub fn blocked(&mut self) -> bool {
        if self.settings.read_only {
            self.toast(false, tr("Mode lecture seule : action désactivée (Paramètres).").into());
            true
        } else {
            false
        }
    }

    /// Action dont la sortie s'affiche dans une fenetre ; actualise ensuite l'etat.
    pub fn action_dialog(&mut self, host: HostId, title: &str, script: String, timeout_s: u64) {
        if self.blocked() {
            return;
        }
        crate::log::info(&format!("action « {title} » sur {}", host.label()));
        let t = title.to_string();
        self.exec(
            host,
            title,
            script,
            timeout_s,
            Box::new(move |app, r| {
                match r {
                    Ok(o) => {
                        let ok = o.code == 0;
                        let text = o.text();
                        if !ok {
                            crate::log::warn(&format!("« {t} » : code {} — {}", o.code, text.lines().last().unwrap_or("")));
                        }
                        app.output = Some(OutputDialog {
                            title: t,
                            text: if text.is_empty() { tr("Terminé.").into() } else { text },
                            ok,
                        });
                    }
                    Err(e) => {
                        crate::log::error(&format!("« {t} » : {e}"));
                        app.output = Some(OutputDialog { title: t, text: e.to_string(), ok: false })
                    }
                }
                app.refresh(host);
            }),
        );
    }

    /// Action dont la sortie (courte) s'affiche en notification ; actualise ensuite l'etat.
    pub fn action_toast(&mut self, host: HostId, label: &str, script: String, timeout_s: u64) {
        if self.blocked() {
            return;
        }
        crate::log::info(&format!("action « {label} » sur {}", host.label()));
        let lab = label.to_string();
        self.exec(
            host,
            label,
            script,
            timeout_s,
            Box::new(move |app, r| {
                match r {
                    Ok(o) => {
                        let text = o.text();
                        let ok = o.code == 0;
                        if !ok {
                            crate::log::warn(&format!("« {lab} » : code {} — {}", o.code, text.lines().last().unwrap_or("")));
                        }
                        if text.lines().count() > 3 {
                            app.output = Some(OutputDialog { title: tr("Résultat").into(), text, ok });
                        } else {
                            app.toast(ok, if text.is_empty() { tr("Fait.").into() } else { text });
                        }
                    }
                    Err(e) => {
                        crate::log::error(&format!("« {lab} » : {e}"));
                        app.toast(false, e.to_string())
                    }
                }
                app.refresh(host);
            }),
        );
    }

    pub fn toast(&mut self, ok: bool, text: String) {
        self.toasts.push(Toast { text, ok, at: Instant::now() });
        if self.toasts.len() > 5 {
            self.toasts.remove(0);
        }
    }

    pub fn ask_confirm(
        &mut self,
        title: &str,
        text: &str,
        button: &str,
        danger: bool,
        typed: Option<&str>,
        action: Box<dyn FnOnce(&mut App)>,
    ) {
        if self.blocked() {
            return;
        }
        self.confirm = Some(Confirm {
            title: title.into(),
            text: text.into(),
            danger,
            typed_required: typed.map(|s| s.to_string()),
            typed: String::new(),
            button: button.into(),
            action: Some(action),
        });
    }

    fn ask_sudo(&mut self, host: HostId, error: bool) {
        if self.sudo.is_none() {
            self.sudo = Some(SudoPrompt {
                host,
                pass: String::new(),
                remember: secret::can_store(),
                error,
            });
        } else if let Some(s) = &mut self.sudo {
            s.error = s.error || error;
        }
    }

    fn forget_pass(&mut self, host: HostId) {
        match host {
            HostId::Omv => {
                self.omv.pass = None;
                self.settings.omv.saved_pass.clear();
                self.edit.omv.saved_pass.clear();
            }
            HostId::Syno => {
                self.syno.pass = None;
                self.settings.syno.saved_pass.clear();
                self.edit.syno.saved_pass.clear();
            }
        }
        let _ = config::save(&self.settings);
    }

    // ------------------------------------------------------------------
    //  Actualisation de l'etat
    // ------------------------------------------------------------------

    pub fn refresh(&mut self, host: HostId) {
        match host {
            HostId::Omv => self.omv.last_poll = None,
            HostId::Syno => self.syno.last_poll = None,
        }
    }

    fn poll_interval(&self, host: HostId) -> Duration {
        let base = Duration::from_secs(self.settings.refresh_secs.max(2) as u64);
        let active = match host {
            HostId::Omv => self
                .omv
                .status
                .as_ref()
                .map(|s| {
                    s.any_job_running()
                        || s.cameras.rattrapage_en_cours
                        || s.any_rt_catchup()
                        || s.nas_check_en_cours
                        || s.restauration.as_ref().map(|r| r.etat == "en_cours").unwrap_or(false)
                        || s.migration.as_ref().map(|m| m.en_cours).unwrap_or(false)
                        || s.transferts.as_ref().map(|t| t.en_cours.is_some()).unwrap_or(false)
                })
                .unwrap_or(false),
            HostId::Syno => self
                .syno
                .status
                .as_ref()
                .map(|s| s.copie.en_cours || s.migration.en_cours || s.transferts.as_ref().map(|t| t.en_cours.is_some()).unwrap_or(false))
                .unwrap_or(false),
        };
        let err = match host {
            HostId::Omv => self.omv.error.is_some(),
            HostId::Syno => self.syno.error.is_some(),
        };
        if err {
            Duration::from_secs(30)
        } else if active {
            base.min(Duration::from_secs(4))
        } else {
            base
        }
    }

    fn maybe_poll(&mut self, host: HostId) {
        let cfg = self.host_cfg(host).clone();
        if !cfg.is_set() || !self.ssh.key_exists() {
            return;
        }
        // assistant de premier lancement : pas de connexion avant l'etape des cles
        if self.wizard.map(|s| s < 3).unwrap_or(false) {
            return;
        }
        let interval = self.poll_interval(host);
        let state_blocked = match host {
            HostId::Omv => matches!(self.omv.error, Some(SshError::SudoPassword)) && self.omv.pass.is_none(),
            HostId::Syno => matches!(self.syno.error, Some(SshError::SudoPassword)) && self.syno.pass.is_none(),
        };
        let (polling, last) = match host {
            HostId::Omv => (self.omv.polling, self.omv.last_poll),
            HostId::Syno => (self.syno.polling, self.syno.last_poll),
        };
        if polling || state_blocked {
            return;
        }
        if let Some(l) = last {
            if l.elapsed() < interval {
                return;
            }
        }
        // identite du NAS a confirmer avant toute connexion
        if !self.ssh.host_known(&cfg) {
            match host {
                HostId::Omv => {
                    self.omv.error = Some(SshError::HostUnknown);
                    self.omv.last_poll = Some(Instant::now());
                }
                HostId::Syno => {
                    self.syno.error = Some(SshError::HostUnknown);
                    self.syno.last_poll = Some(Instant::now());
                }
            }
            if !self.fp_dismissed[crate::extras::idx(host)] && self.fingerprint.is_none() {
                crate::extras::start_fingerprint(self, host, crate::extras::AfterTrust::Nothing);
            }
            return;
        }
        if cfg.sudo && self.pass_of(host).is_none() {
            match host {
                HostId::Omv => self.omv.error = Some(SshError::SudoPassword),
                HostId::Syno => self.syno.error = Some(SshError::SudoPassword),
            }
            self.ask_sudo(host, false);
            return;
        }
        let script = match host {
            HostId::Omv => remote::OMV_STATUS.as_str(),
            HostId::Syno => remote::SYNO_STATUS.as_str(),
        }
        .to_string();
        match host {
            HostId::Omv => {
                self.omv.polling = true;
                self.omv.last_poll = Some(Instant::now());
            }
            HostId::Syno => {
                self.syno.polling = true;
                self.syno.last_poll = Some(Instant::now());
            }
        }
        let pass = self.pass_of(host);
        let ssh = self.ssh.clone();
        let tx = self.tx.clone();
        let ctx = self.ctx.clone();
        std::thread::spawn(move || {
            let r = ssh.run(&cfg, pass.as_deref(), &script, Duration::from_secs(45));
            let _ = tx.send(Msg::Status(host, r));
            ctx.request_repaint();
        });
    }

    fn on_status(&mut self, host: HostId, r: Result<CmdOut, SshError>) {
        let parsed: Result<(), SshError> = match r {
            Ok(o) => {
                let line = o
                    .stdout
                    .lines()
                    .rev()
                    .find(|l| l.trim_start().starts_with('{'))
                    .unwrap_or("")
                    .to_string();
                match host {
                    HostId::Omv => match serde_json::from_str::<OmvStatus>(&line) {
                        Ok(s) => {
                            if let Some(e) = &s.erreur {
                                Err(SshError::Other(e.clone()))
                            } else {
                                if let Some(prev) = &self.omv.status {
                                    if self.settings.notifications {
                                        for (t, b) in crate::tray::diff_omv(prev, &s) {
                                            crate::tray::notify(&self.ctx, &t, &b);
                                        }
                                    }
                                }
                                self.omv.status = Some(s);
                                Ok(())
                            }
                        }
                        Err(e) => Err(SshError::Other(bad_output(&o, &e.to_string()))),
                    },
                    HostId::Syno => match serde_json::from_str::<SynoStatus>(&line) {
                        Ok(s) => {
                            if let Some(e) = &s.erreur {
                                Err(SshError::Other(e.clone()))
                            } else {
                                if let Some(prev) = &self.syno.status {
                                    if self.settings.notifications {
                                        for (t, b) in crate::tray::diff_syno(prev, &s) {
                                            crate::tray::notify(&self.ctx, &t, &b);
                                        }
                                    }
                                }
                                self.syno.status = Some(s);
                                Ok(())
                            }
                        }
                        Err(e) => Err(SshError::Other(bad_output(&o, &e.to_string()))),
                    },
                }
            }
            Err(e) => Err(e),
        };
        let st_err = parsed.err();
        let prev = match host {
            HostId::Omv => self.omv.error.clone(),
            HostId::Syno => self.syno.error.clone(),
        };
        // NAS injoignable depuis 3 actualisations / de nouveau joignable
        let k = crate::extras::idx(host);
        let conn_err = matches!(st_err, Some(SshError::Unreachable(_)) | Some(SshError::Timeout) | Some(SshError::KeyRefused) | Some(SshError::HostKeyChanged));
        if conn_err {
            self.err_streak[k] += 1;
            if self.err_streak[k] == 3 && self.settings.notifications {
                let msg = st_err.as_ref().map(|e| e.to_string()).unwrap_or_default();
                crate::tray::notify(&self.ctx, &tf("\u{E4E0} {0} injoignable", &[&(host.label())]), &msg);
            }
        } else if st_err.is_none() {
            if self.err_streak[k] >= 3 && self.settings.notifications {
                crate::tray::notify(&self.ctx, &tf("✅ {0} de nouveau joignable", &[&(host.label())]), "");
            }
            self.err_streak[k] = 0;
        }
        if prev != st_err {
            match &st_err {
                Some(e) => crate::log::warn(&format!("{} : {e}", host.label())),
                None => crate::log::info(&format!("{} : connecté", host.label())),
            }
        }
        if matches!(st_err, Some(SshError::HostUnknown)) && !self.fp_dismissed[crate::extras::idx(host)] {
            crate::extras::start_fingerprint(self, host, crate::extras::AfterTrust::Nothing);
        }
        if matches!(st_err, Some(SshError::SudoPassword)) {
            self.forget_pass(host);
            self.ask_sudo(host, true);
        }
        match host {
            HostId::Omv => {
                self.omv.polling = false;
                if st_err.is_none() {
                    self.omv.last_ok = Some(Instant::now());
                }
                self.omv.error = st_err;
            }
            HostId::Syno => {
                self.syno.polling = false;
                if st_err.is_none() {
                    self.syno.last_ok = Some(Instant::now());
                }
                self.syno.error = st_err;
            }
        }
    }

    fn process_messages(&mut self) {
        while let Ok(m) = self.rx.try_recv() {
            match m {
                Msg::Status(h, r) => self.on_status(h, r),
                Msg::Done(handler, r) => handler(self, r),
            }
        }
    }

    /// Bascule sur un autre site (autre couple OMV + Synology)
    pub fn switch_site(&mut self, name: &str) {
        crate::ssh::close_session(&self.settings.omv);
        crate::ssh::close_session(&self.settings.syno);
        if self.settings.switch_site(name) {
            self.edit = self.settings.clone();
            let _ = config::save(&self.settings);
            self.omv = HostState::default();
            self.syno = HostState::default();
            self.fp_dismissed = [false, false];
            self.err_streak = [0, 0];
            self.history = Default::default();
            self.backup_sources.clear();
            self.sources_loaded = false;
            self.mig = MigForm::default();
            if !self.settings.omv.saved_pass.is_empty() {
                self.omv.pass = secret::unprotect(&self.settings.omv.saved_pass);
            }
            if !self.settings.syno.saved_pass.is_empty() {
                self.syno.pass = secret::unprotect(&self.settings.syno.saved_pass);
            }
            crate::log::info(&format!("site actif : {name}"));
            self.toast(true, tf("Site « {0} »", &[&name]));
        }
    }

    pub fn save_settings(&mut self) {
        let omv_changed = self.edit.omv.host != self.settings.omv.host
            || self.edit.omv.port != self.settings.omv.port
            || self.edit.omv.user != self.settings.omv.user
            || self.edit.omv.sudo != self.settings.omv.sudo;
        let syno_changed = self.edit.syno.host != self.settings.syno.host
            || self.edit.syno.port != self.settings.syno.port
            || self.edit.syno.user != self.settings.syno.user
            || self.edit.syno.sudo != self.settings.syno.sudo;
        if omv_changed {
            crate::ssh::close_session(&self.settings.omv);
            self.edit.omv.saved_pass.clear();
            self.omv = HostState::default();
            self.fp_dismissed[0] = false;
        }
        if syno_changed {
            crate::ssh::close_session(&self.settings.syno);
            self.edit.syno.saved_pass.clear();
            self.syno = HostState::default();
            self.fp_dismissed[1] = false;
        }
        crate::extras::apply_theme(&self.ctx, &self.edit.theme);
        self.ctx.set_zoom_factor(self.edit.zoom.clamp(0.8, 1.8));
        crate::i18n::set_language(&self.edit.language);
        self.edit.refresh_secs = self.edit.refresh_secs.clamp(2, 300);
        self.settings = self.edit.clone();
        self.ssh = Ssh::new(&self.settings.ssh_bin);
        match config::save(&self.settings) {
            Ok(()) => self.toast(true, tr("Paramètres enregistrés.").into()),
            Err(e) => self.toast(false, tf("Enregistrement impossible : {0}", &[&e])),
        }
        self.refresh(HostId::Omv);
        self.refresh(HostId::Syno);
    }

    // ------------------------------------------------------------------
    //  Navigateur de dossiers
    // ------------------------------------------------------------------

    pub fn open_browser(&mut self, host: HostId, purpose: BrowsePurpose, start: &str) {
        self.browser = Some(Browser {
            host,
            purpose,
            cur: start.to_string(),
            entries: Vec::new(),
            loading: false,
            new_folder: String::new(),
        });
        self.browser_load(start.to_string());
    }

    pub fn browser_load(&mut self, dir: String) {
        let Some(b) = &mut self.browser else { return };
        b.cur = dir.clone();
        b.loading = true;
        b.entries.clear();
        let host = b.host;
        let script = match host {
            HostId::Omv => remote::omv_list_dirs(&dir),
            HostId::Syno => remote::syno_list_dirs(&dir),
        };
        self.exec(
            host,
            tr("Lecture des dossiers"),
            script,
            30,
            Box::new(move |app, r| {
                if let Some(b) = &mut app.browser {
                    if b.cur == dir {
                        b.loading = false;
                        match r {
                            Ok(o) => {
                                b.entries = o.stdout.lines().filter(|l| !l.trim().is_empty()).map(|l| l.to_string()).collect()
                            }
                            Err(e) => app.toast(false, e.to_string()),
                        }
                    }
                }
            }),
        );
    }

    pub fn browser_pick(&mut self, path: String) {
        let Some(b) = self.browser.take() else { return };
        match b.purpose {
            BrowsePurpose::BackupSource => {
                if let Some(f) = &mut self.job_form {
                    f.source = path.clone();
                    if !f.folder_touched {
                        f.folder = path.rsplit('/').next().unwrap_or("").to_string();
                    }
                }
            }
            BrowsePurpose::RestoreTarget => {
                if let Some(r) = &mut self.restore {
                    r.target = path;
                }
            }
            BrowsePurpose::CopySource => {
                self.copy.src = path;
                self.copy.src_size = None;
                self.compute_copy_size();
            }
            BrowsePurpose::CopyDest => {
                self.copy.dst = path;
                self.copy.dst_free = None;
                self.compute_copy_free();
            }
            BrowsePurpose::MigSource => {
                self.mig.label = path.rsplit('/').next().unwrap_or("").to_string();
                self.mig.src = path;
            }
            BrowsePurpose::TrDest => {
                if let Some(f) = &mut self.ocis_ui.tr_form {
                    f.dest = path.trim_end_matches('/').to_string();
                }
            }
            BrowsePurpose::PermsDir => self.perms.dir = path,
            BrowsePurpose::DestPath => {
                if let Some(f) = &mut self.dests.form {
                    f.values.insert("chemin".into(), path.trim_end_matches('/').to_string());
                }
            }
            BrowsePurpose::RtSource => {
                if let Some(f) = &mut self.rt_form {
                    let p = path.trim_end_matches('/').to_string();
                    if !f.dirs.contains(&p) {
                        if f.new && !f.folder_touched && f.dirs.is_empty() {
                            f.folder = p.rsplit('/').next().unwrap_or("").to_string();
                        }
                        f.dirs.push(p);
                    }
                }
            }
        }
    }

    pub fn compute_copy_size(&mut self) {
        let src = self.copy.src.clone();
        if src.is_empty() {
            return;
        }
        self.copy.sizing = true;
        self.exec(
            HostId::Syno,
            tr("Calcul de la taille"),
            remote::syno_size(&src),
            600,
            Box::new(move |app, r| {
                app.copy.sizing = false;
                if app.copy.src != src {
                    return;
                }
                if let Ok(o) = r {
                    let mut it = o.stdout.lines().map(|l| l.trim().parse::<u64>().unwrap_or(0));
                    let size = it.next().unwrap_or(0);
                    let nb = it.next().unwrap_or(0);
                    app.copy.src_size = Some((size, nb));
                }
            }),
        );
    }

    pub fn compute_copy_free(&mut self) {
        let dst = self.copy.dst.clone();
        if dst.is_empty() {
            return;
        }
        self.exec(
            HostId::Omv,
            tr("Espace libre"),
            remote::free_space(&dst),
            30,
            Box::new(move |app, r| {
                if app.copy.dst == dst {
                    if let Ok(o) = r {
                        app.copy.dst_free = o.stdout.trim().parse().ok();
                    }
                }
            }),
        );
    }

    pub fn load_backup_sources(&mut self) {
        self.sources_loaded = true;
        self.exec(
            HostId::Omv,
            tr("Dossiers de l'OMV"),
            remote::omv_list_backup_sources(),
            30,
            Box::new(|app, r| {
                if let Ok(o) = r {
                    app.backup_sources = o.stdout.lines().filter(|l| !l.is_empty()).map(String::from).collect();
                }
            }),
        );
    }

    // ------------------------------------------------------------------
    //  Fenetres
    // ------------------------------------------------------------------

    fn dialogs(&mut self, ctx: &egui::Context) {
        // Sortie d'une commande
        if let Some(d) = &self.output {
            let mut open = true;
            let mut close = false;
            let (title, text, ok) = (d.title.clone(), d.text.clone(), d.ok);
            egui::Window::new(RichText::new(&title).strong())
                .id(egui::Id::unique("output"))
                .collapsible(false)
                .resizable(true)
                .default_width(620.0)
                .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
                .open(&mut open)
                .show(ctx, |ui| {
                    ui.horizontal(|ui| {
                        if ok {
                            ui.label(RichText::new(tr("\u{E182} Terminé")).color(crate::theme::OK));
                        } else {
                            ui.label(RichText::new(tr("\u{E4E0} Problème")).color(crate::theme::ERR));
                        }
                    });
                    ui.add_space(4.0);
                    egui::ScrollArea::vertical().max_height(380.0).show(ui, |ui| {
                        let mut t = text.clone();
                        ui.add(
                            egui::TextEdit::multiline(&mut t)
                                .font(egui::TextStyle::Monospace)
                                .desired_width(f32::INFINITY)
                                .interactive(true),
                        );
                    });
                    ui.add_space(6.0);
                    ui.horizontal(|ui| {
                        if ui.button(tr("\u{E1CA} Copier")).clicked() {
                            ui.ctx().copy_text(text.clone());
                        }
                        if ui.button(tr("Fermer")).clicked() {
                            close = true;
                        }
                    });
                });
            if !open || close {
                self.output = None;
            }
        }

        // Confirmation
        let mut do_action = false;
        let mut cancel = false;
        if let Some(c) = &mut self.confirm {
            egui::Window::new(RichText::new(&c.title).strong())
                .id(egui::Id::unique("confirm"))
                .collapsible(false)
                .resizable(false)
                .default_width(460.0)
                .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
                .show(ctx, |ui| {
                    ui.label(&c.text);
                    let mut allowed = true;
                    if let Some(word) = &c.typed_required {
                        ui.add_space(6.0);
                        ui.label(tf("Tape {0} pour confirmer :", &[&word]));
                        ui.text_edit_singleline(&mut c.typed);
                        allowed = c.typed.trim() == word;
                    }
                    ui.add_space(8.0);
                    ui.horizontal(|ui| {
                        let txt = if c.danger {
                            RichText::new(&c.button).color(Color32::WHITE)
                        } else {
                            RichText::new(&c.button)
                        };
                        let mut btn = egui::Button::new(txt);
                        if c.danger {
                            btn = btn.fill(crate::theme::ERR);
                        }
                        if ui.add_enabled(allowed, btn).clicked() {
                            do_action = true;
                        }
                        if ui.button(tr("Annuler")).clicked() {
                            cancel = true;
                        }
                    });
                });
        }
        if do_action {
            if let Some(mut c) = self.confirm.take() {
                if let Some(a) = c.action.take() {
                    a(self);
                }
            }
        } else if cancel {
            self.confirm = None;
        }

        // Mot de passe sudo
        let mut submit = false;
        let mut dismiss = false;
        if let Some(s) = &mut self.sudo {
            let cfg = match s.host {
                HostId::Omv => &self.settings.omv,
                HostId::Syno => &self.settings.syno,
            };
            let who = tf("{0} sur {1} ({2})", &[&cfg.user, &(s.host.label()), &cfg.host]);
            egui::Window::new(RichText::new(tr("Mot de passe administrateur")).strong())
                .id(egui::Id::unique("sudo"))
                .collapsible(false)
                .resizable(false)
                .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
                .show(ctx, |ui| {
                    ui.label(tf("Mot de passe de {0}", &[&who]));
                    ui.label(
                        RichText::new(tr("Nécessaire pour lire l'état des copies et migrations (sudo)."))
                            .small()
                            .weak(),
                    );
                    if s.error {
                        ui.colored_label(crate::theme::ERR, tr("Mot de passe refusé, réessaie."));
                    }
                    let r = ui.add(egui::TextEdit::singleline(&mut s.pass).password(true).desired_width(260.0));
                    r.request_focus();
                    if r.lost_focus() && ui.input(|i| i.key_pressed(egui::Key::Enter)) {
                        submit = true;
                    }
                    if secret::can_store() {
                        ui.checkbox(&mut s.remember, tr("Mémoriser (chiffré avec ton compte Windows)"));
                    }
                    ui.horizontal(|ui| {
                        if ui.button(tr("Valider")).clicked() {
                            submit = true;
                        }
                        if ui.button(tr("Plus tard")).clicked() {
                            dismiss = true;
                        }
                    });
                });
        }
        if submit {
            if let Some(s) = self.sudo.take() {
                if !s.pass.is_empty() {
                    let stored = if s.remember { secret::protect(&s.pass) } else { None };
                    match s.host {
                        HostId::Omv => {
                            self.omv.pass = Some(s.pass.clone());
                            self.omv.error = None;
                            self.settings.omv.saved_pass = stored.clone().unwrap_or_default();
                            self.edit.omv.saved_pass = self.settings.omv.saved_pass.clone();
                        }
                        HostId::Syno => {
                            self.syno.pass = Some(s.pass.clone());
                            self.syno.error = None;
                            self.settings.syno.saved_pass = stored.clone().unwrap_or_default();
                            self.edit.syno.saved_pass = self.settings.syno.saved_pass.clone();
                        }
                    }
                    let _ = config::save(&self.settings);
                    self.refresh(s.host);
                }
            }
        } else if dismiss {
            self.sudo = None;
        }

        crate::pages::browser_window(self, ctx);
        crate::pages::job_form_window(self, ctx);
        crate::realtime::form_window(self, ctx);
        crate::dests::form_window(self, ctx);
        crate::notifs::form_window(self, ctx);
        crate::fiabilite::reveil_window(self, ctx);
        crate::ocis::tr_form_window(self, ctx);
        crate::pcmig::dialogs(self, ctx);
        crate::pages::restore_window(self, ctx);
        crate::pages::passwords_window(self, ctx);
        crate::extras::fingerprint_window(self, ctx);
        crate::extras::news_window(self, ctx);
        crate::help::wizard_window(self, ctx);
    }

    fn toasts_ui(&mut self, ctx: &egui::Context) {
        self.toasts.retain(|t| t.at.elapsed() < Duration::from_secs(7));
        if self.toasts.is_empty() && self.busy.is_empty() {
            return;
        }
        egui::Area::new(egui::Id::unique("toasts"))
            .anchor(egui::Align2::RIGHT_BOTTOM, [-14.0, -14.0])
            .order(egui::Order::Foreground)
            .show(ctx, |ui| {
                ui.set_max_width(420.0);
                if let Some(b) = self.busy.last() {
                    egui::Frame::popup(ui.style()).show(ui, |ui| {
                        ui.horizontal(|ui| {
                            ui.spinner();
                            ui.label(format!("{b}…"));
                        });
                    });
                }
                for t in &self.toasts {
                    egui::Frame::popup(ui.style()).show(ui, |ui| {
                        let col = if t.ok { crate::theme::OK } else { crate::theme::ERR };
                        ui.horizontal(|ui| {
                            ui.label(RichText::new(if t.ok { "\u{E182}" } else { "\u{E4E0}" }).color(col));
                            ui.label(&t.text);
                        });
                    });
                }
            });
        ctx.request_repaint_after(Duration::from_millis(500));
    }
}

impl App {
    /// Captures d'ecran de developpement : NAS_MANAGER_DEMO=restauration
    #[cfg(debug_assertions)]
    fn demo(&mut self) {
        if std::env::var("NAS_MANAGER_DEMO").as_deref() != Ok("restauration") || self.restore.is_some() {
            return;
        }
        static DONE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
        if DONE.load(std::sync::atomic::Ordering::SeqCst) {
            return;
        }
        if let Some(j) = self.omv.status.as_ref().and_then(|s| s.sauvegardes.first().cloned()) {
            DONE.store(true, std::sync::atomic::Ordering::SeqCst);
            let mut r = RestoreState::new(&j);
            r.tab = 1;
            self.restore = Some(r);
            crate::restore::demo_list(self, "2024".into());
        }
    }
}

fn bad_output(o: &CmdOut, err: &str) -> String {
    let t = o.text();
    let short: String = t.lines().rev().take(4).collect::<Vec<_>>().into_iter().rev().collect::<Vec<_>>().join(" | ");
    if short.is_empty() {
        tf("Réponse vide du NAS ({0}).", &[&err])
    } else {
        tf("Réponse inattendue du NAS : {0}", &[&short])
    }
}

impl eframe::App for App {
    /// Appele avant chaque affichage, et aussi fenetre cachee (zone de notification)
    fn logic(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.process_messages();
        self.maybe_poll(HostId::Omv);
        if self.settings.syno.is_set() {
            self.maybe_poll(HostId::Syno);
        }
        crate::tray::update(self, ctx);
        if self.wizard.is_none() {
            crate::scripts::auto_check(self);
            crate::dests::auto_kit(self);
        }
        #[cfg(debug_assertions)]
        self.demo();
        ctx.request_repaint_after(Duration::from_secs(1));
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        // fermeture : reduire dans la zone de notification
        if ctx.input(|i| i.viewport().close_requested()) && !self.quitting && self.settings.close_to_tray && self.tray.is_some() {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            crate::tray::hide_window(self, &ctx);
            if !self.settings.last_version.is_empty() && !self.toasts.iter().any(|t| t.text.contains("zone de notification")) {
                crate::log::info("fenêtre réduite dans la zone de notification");
            }
        }
        crate::extras::shortcuts(self, &ctx);
        crate::pages::top_bar(self, ui);
        crate::pages::nav(self, ui);
        egui::CentralPanel::default_margins().show(ui, |ui| {
            egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
                ui.add_space(4.0);
                match self.page {
                    Page::Dashboard => crate::pages::dashboard(self, ui),
                    Page::Backups => crate::pages::backups(self, ui),
                    Page::History => crate::history::page(self, ui),
                    Page::Realtime => crate::realtime::page(self, ui),
                    Page::Destinations => crate::dests::page(self, ui),
                    Page::Alerts => crate::pages::alerts(self, ui),
                    Page::Copy => crate::pages::copy(self, ui),
                    Page::Migration => crate::ocis::page(self, ui),
                    Page::Logs => crate::pages::logs(self, ui),
                    Page::Install => crate::install::page(self, ui),
                    Page::Help => crate::help::page(self, ui),
                    Page::Settings => crate::pages::settings(self, ui),
                }
                ui.add_space(30.0);
            });
        });
        self.dialogs(&ctx);
        self.toasts_ui(&ctx);
        ctx.request_repaint_after(Duration::from_secs(1));
    }
}
