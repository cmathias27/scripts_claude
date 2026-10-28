//! Page « Installation » : mise en place complete des NAS depuis l'application
//! (rclone, connexion Google Drive, scripts, synchro cameras, alertes, suivi Home Assistant).

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::app::{App, HostId, OutputDialog};
use crate::remote;
use crate::ssh::sq;
use crate::theme::{ERR, IDLE, OK, WARN};
use eframe::egui::{self, RichText};
use serde::Deserialize;
use std::io::BufRead;
#[allow(unused_imports)]
use crate::theme::INFO;


/// Etat de l'OMV / de la machine Debian
pub const OMV_INSTALL_STATUS: &str = r#####"
export LC_ALL=C
AG=/usr/local/bin/nas-debian
ot=""
if [ -x $AG ]; then timeout 20 $AG outils derniere >/dev/null 2>&1; ot=$($AG outils etat 2>/dev/null); fi
[ -n "$ot" ] || ot=null
py=$(command -v python3 >/dev/null && echo 1 || echo 0)
rc=$(command -v rclone >/dev/null && rclone version 2>/dev/null | head -n 1 | awk '{print $2}')
remotes=$(rclone listremotes 2>/dev/null | tr '\n' ' ')
gd=0; [ -n "$rc" ] && echo " $remotes" | grep -q ' gdrive: ' && gd=1
gdok=0; [ $gd = 1 ] && timeout 25 rclone lsd gdrive: --max-depth 1 >/dev/null 2>&1 && gdok=1
cam=0; [ -f /usr/local/bin/cam-sync.sh ] && cam=1
camact=$(systemctl is-active cam-sync 2>/dev/null)
camsrc=$(grep -m1 '^SRC=' /usr/local/bin/cam-sync.sh 2>/dev/null | cut -d'"' -f2)
al=0; [ -f /etc/nas-backup/notify.conf ] && al=1
haurl=$(grep -m1 '^HA_URL=' /etc/nas-backup/notify.conf 2>/dev/null | cut -d'"' -f2)
ha=0; [ -f /etc/cron.d/nas-ha-status ] && ha=1
mq=0; [ -f /root/.config/mosquitto_pub ] && mq=1
mqh=$(sed -n 's/^-h //p' /root/.config/mosquitto_pub 2>/dev/null | head -n 1)
printf '{"outils":%s,"python3":%s,"rclone":"%s","remotes":"%s","gdrive":%s,"gdrive_ok":%s,"cam":%s,"cam_actif":"%s","cam_src":"%s","alertes":%s,"ha_url":"%s","suivi_ha":%s,"mqtt":%s,"mqtt_host":"%s"}\n' \
  "$ot" "$py" "$rc" "$remotes" "$gd" "$gdok" "$cam" "$camact" "$camsrc" "$al" "$haurl" "$ha" "$mq" "$mqh"
"#####;

/// Etat du Synology
pub const SYNO_INSTALL_STATUS: &str = r#####"
export LC_ALL=C
AG=/usr/local/bin/nas-synology
ot=""; jt=""
if [ -x $AG ]; then timeout 20 $AG outils derniere >/dev/null 2>&1; ot=$($AG outils etat 2>/dev/null); jt=$(timeout 40 $AG migration jeton 2>/dev/null | tail -n 1); fi
[ -n "$ot" ] || ot=null
case "$jt" in \{*) ;; *) jt=null ;; esac
py=$(command -v python3 >/dev/null && echo 1 || echo 0)
rs=$(command -v rsync >/dev/null && echo 1 || echo 0)
dsm=$(grep -m1 '^productversion=' /etc.defaults/VERSION 2>/dev/null | cut -d'"' -f2)
printf '{"outils":%s,"jeton":%s,"python3":%s,"rsync":%s,"dsm":"%s"}\n' "$ot" "$jt" "$py" "$rs" "$dsm"
"#####;

/// Outils de la machine (`nas-debian outils etat` / `nas-synology outils etat`)
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Tools {
    pub machine: String,
    pub arch: String,
    pub ram_total_mo: i64,
    pub ram_dispo_mo: i64,
    pub python3: bool,
    pub rclone: String,
    pub rclone_source: String,
    pub rclone_derniere: String,
    pub curl: bool,
    pub unzip: bool,
    pub inotifywait: bool,
    pub mosquitto_pub: bool,
    pub openssl: bool,
    pub flock: bool,
    pub logrotate: bool,
    pub inotify_max: i64,
    pub rsync: bool,
    pub ssh: bool,
    pub cle_omv: bool,
    /// sauvegardes versionnees (script 2.2+)
    pub restic: Option<String>,
    pub restic_derniere: String,
    pub bzip2: Option<bool>,
}

impl Tools {
    pub fn restic_update(&self) -> Option<String> {
        let cur = self.restic.as_deref().unwrap_or("");
        if !cur.is_empty() && !self.restic_derniere.is_empty() && crate::update::is_newer(&self.restic_derniere, cur) {
            Some(self.restic_derniere.clone())
        } else {
            None
        }
    }

    pub fn rclone_update(&self) -> Option<String> {
        if !self.rclone.is_empty() && !self.rclone_derniere.is_empty() && crate::update::is_newer(&self.rclone_derniere, self.rclone.trim_end_matches("-faux")) {
            Some(self.rclone_derniere.clone())
        } else {
            None
        }
    }
}

/// Jeton d'application oCIS (`nas-synology migration jeton`)
#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct Token {
    pub etat: String,
    pub expire: Option<i64>,
    pub nb: i64,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct OmvInstall {
    pub outils: Option<Tools>,
    pub python3: u8,
    pub rclone: String,
    pub remotes: String,
    pub gdrive: u8,
    pub gdrive_ok: u8,
    pub cam: u8,
    pub cam_actif: String,
    pub cam_src: String,
    pub alertes: u8,
    pub ha_url: String,
    pub suivi_ha: u8,
    pub mqtt: u8,
    pub mqtt_host: String,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct SynoInstall {
    pub outils: Option<Tools>,
    pub jeton: Option<Token>,
    pub python3: u8,
    pub rsync: u8,
    pub dsm: String,
}

pub struct InstallState {
    pub omv: Option<OmvInstall>,
    pub syno: Option<SynoInstall>,
    pub loading: bool,
    pub ha_ip: String,
    pub webhook: String,
    pub mqtt_host: String,
    pub mqtt_user: String,
    pub mqtt_pass: String,
    /// autorisation Google en cours : URL a ouvrir
    pub google: Option<GoogleFlow>,
    /// reglage memoire de rclone en cours d'edition (OMV, Synology)
    pub ram: [crate::ram::RamEdit; 2],
}

impl Default for InstallState {
    fn default() -> Self {
        Self {
            omv: None,
            syno: None,
            loading: false,
            ha_ip: "192.168.1.222".into(),
            webhook: "nas-c09f382daf2d01deb430abbd".into(),
            mqtt_host: "192.168.1.222".into(),
            mqtt_user: String::new(),
            mqtt_pass: String::new(),
            google: None,
            ram: Default::default(),
        }
    }
}

#[derive(Clone, Default)]
pub struct GoogleFlow {
    pub url: String,
    pub step: String,
    pub done: bool,
    pub error: String,
}

pub fn refresh(app: &mut App) {
    if app.install.loading {
        return;
    }
    app.install.loading = true;
    app.exec(
        HostId::Omv,
        tr("Vérification de la machine"),
        OMV_INSTALL_STATUS.to_string(),
        90,
        Box::new(|app, r| {
            app.install.loading = false;
            match r {
                Ok(o) => {
                    if let Some(l) = o.stdout.lines().rev().find(|l| l.starts_with('{')) {
                        match serde_json::from_str::<OmvInstall>(l) {
                            Ok(s) => {
                                if let Some(h) = s.ha_url.split("://").nth(1) {
                                    app.install.ha_ip = h.split(':').next().unwrap_or("").to_string();
                                }
                                if !s.mqtt_host.is_empty() {
                                    app.install.mqtt_host = s.mqtt_host.clone();
                                }
                                app.install.omv = Some(s);
                            }
                            Err(e) => crate::log::warn(&format!("état d'installation illisible : {e}")),
                        }
                    }
                }
                Err(e) => app.toast(false, e.to_string()),
            }
        }),
    );
    if app.settings.syno.is_set() {
        app.exec(
            HostId::Syno,
            tr("Vérification du Synology"),
            SYNO_INSTALL_STATUS.to_string(),
            90,
            Box::new(|app, r| {
                if let Ok(o) = r {
                    if let Some(l) = o.stdout.lines().rev().find(|l| l.starts_with('{')) {
                        app.install.syno = serde_json::from_str(l).ok();
                    }
                }
            }),
        );
    }
}

fn row(ui: &mut egui::Ui, state: Option<bool>, title: &str, detail: &str) {
    ui.horizontal(|ui| {
        let (col, sym) = match state {
            Some(true) => (OK, "\u{E182}"),
            Some(false) => (ERR, "\u{E4F6}"),
            None => (IDLE, "…"),
        };
        ui.label(RichText::new(sym).color(col).strong());
        ui.label(RichText::new(title).strong());
        if !detail.is_empty() {
            ui.label(RichText::new(detail).small().weak());
        }
    });
}

/// Nom de la machine « OMV » : OMV ou Debian selon ce que le script a reconnu
pub fn server_label(app: &App) -> &'static str {
    match app.omv.status.as_ref().and_then(|s| s.agent.as_ref()).map(|a| a.machine.as_str()) {
        Some("debian") => "Debian",
        _ => "OMV",
    }
}

fn tools_rows(ui: &mut egui::Ui, t: &Tools, linux: bool, mqtt: bool) -> bool {
    let mut missing = false;
    let mut r = |ui: &mut egui::Ui, ok: bool, name: &str, detail: &str| {
        if !ok {
            missing = true;
        }
        row(ui, Some(ok), name, detail);
    };
    let rc = if t.rclone.is_empty() {
        tr("absent").to_string()
    } else if t.rclone_source == "paquet" {
        tf("{0} (version des paquets, ancienne : la version officielle sera installée)", &[&t.rclone])
    } else {
        t.rclone.clone()
    };
    r(ui, !t.rclone.is_empty() && t.rclone_source != "paquet", "rclone", &rc);
    r(ui, t.python3, "python3", tr("suivi, notifications"));
    r(ui, t.curl, "curl", tr("téléchargements, Home Assistant"));
    if linux {
        r(ui, t.unzip, "unzip", "");
        r(ui, t.inotifywait, "inotify-tools", tr("sauvegardes temps réel"));
        r(ui, t.openssl, "openssl", tr("mots de passe de chiffrement"));
        r(ui, t.flock, "flock", "");
        r(ui, t.logrotate, "logrotate", tr("rotation des journaux"));
        r(ui, t.inotify_max >= 524288, tr("Limite de surveillance de fichiers"), &t.inotify_max.to_string());
        if let Some(rv) = &t.restic {
            r(ui, !rv.is_empty(), "restic", &if rv.is_empty() { tr("sauvegardes versionnées").to_string() } else { tf("{0} · sauvegardes versionnées", &[rv]) });
        }
        if mqtt {
            r(ui, t.mosquitto_pub, "mosquitto-clients", tr("tableau de bord Home Assistant"));
        }
    } else {
        r(ui, t.rsync, "rsync", tr("copie vers l'OMV"));
        r(ui, t.ssh, "ssh", "");
        r(ui, t.cle_omv, tr("Clé SSH du Synology vers l'OMV"), "");
    }
    missing
}

pub fn page(app: &mut App, ui: &mut egui::Ui) {
    ui.heading(tr("Installation des NAS"));
    ui.label(RichText::new(tr("Tout ce qu'il faut sur les machines, installé depuis l'application (rien à taper en SSH).")).weak());
    ui.add_space(8.0);
    if !app.host_connected(HostId::Omv) {
        crate::pages::info_banner(ui, tr("Connecte d'abord l'OMV (Paramètres : adresse, autoriser la clé, tester)."));
        if ui.button(tr("\u{E270} Paramètres")).clicked() {
            app.page = crate::app::Page::Settings;
        }
        return;
    }
    if app.install.omv.is_none() && !app.install.loading {
        refresh(app);
    }
    ui.horizontal(|ui| {
        if ui.button(tr("\u{E094} Vérifier à nouveau")).clicked() {
            refresh(app);
        }
        if app.install.loading {
            ui.spinner();
        }
    });
    let st = app.install.omv.clone().unwrap_or_default();
    let known = app.install.omv.is_some();
    let k = |b: bool| if known { Some(b) } else { None };
    let agent = app.omv.status.as_ref().map(|s| s.agent.is_some()).unwrap_or(false);
    let srv = server_label(app);

    // ---- 1. scripts
    crate::pages::card_pub(ui, tr("1. Scripts des machines"), |ui| {
        crate::scripts::card(app, ui);
    });
    ui.add_space(8.0);

    // ---- 2. outils
    crate::pages::card_pub(ui, &tf("2. Outils nécessaires ({0})", &[&srv]), |ui| {
        let Some(t) = st.outils.clone() else {
            ui.label(RichText::new(if agent || !known { tr("…") } else { tr("Installe d'abord le script de la machine (ci-dessus) : il installe aussi tous les outils.") }).weak());
            return;
        };
        let missing = tools_rows(ui, &t, true, st.mqtt == 1);
        ui.horizontal_wrapped(|ui| {
            if missing && ui.button(RichText::new(tr("\u{E08E} Installer ce qui manque")).strong()).clicked() {
                let opt = if st.mqtt == 1 { " suivi" } else { "" };
                app.action_dialog(HostId::Omv, tr("Installation des outils"), format!("{} outils installer{opt} 2>&1\n", remote::DEBIAN_BIN), 1800);
            }
            if let Some(v) = t.rclone_update() {
                if ui.button(tf("Mettre à jour rclone {0} → {1}", &[&t.rclone, &v])).clicked() {
                    app.action_dialog(HostId::Omv, tr("Mise à jour de rclone"), format!("{} outils rclone-maj 2>&1\n", remote::DEBIAN_BIN), 600);
                }
            }
            if let Some(v) = t.restic_update() {
                if ui.button(tf("Mettre à jour restic {0} → {1}", &[&(t.restic.clone().unwrap_or_default()), &v])).clicked() {
                    app.action_dialog(HostId::Omv, tr("Mise à jour de restic"), format!("{} outils restic-maj 2>&1\n", remote::DEBIAN_BIN), 600);
                }
            }
        });
        if !missing {
            ui.label(RichText::new(tr("Tout est installé.")).small().color(OK));
        }
    });
    ui.add_space(8.0);

    // ---- 3. Google Drive
    crate::pages::card_pub(ui, tr("3. Connexion Google Drive"), |ui| {
        let detail = if st.gdrive_ok == 1 {
            tr("connectée").to_string()
        } else if st.gdrive == 1 {
            tr("configurée mais refusée par Google (autorisation expirée ?)").to_string()
        } else {
            tr("pas encore configurée").to_string()
        };
        row(ui, k(st.gdrive_ok == 1), tr("Remote rclone « gdrive »"), &detail);
        ui.label(
            RichText::new(
                tr("L'application ouvre la page de connexion Google dans ton navigateur ; l'autorisation est transmise à la machine par la connexion SSH (rien à copier)."),
            )
            .small()
            .weak(),
        );
        ui.label(RichText::new(tr("Autres destinations (OneDrive, Dropbox, disque USB, autre NAS, Backblaze B2…) : page Destinations. Google Drive est facultatif.")).small().weak());
        let busy = app.install.google.as_ref().map(|g| !g.done).unwrap_or(false);
        ui.horizontal(|ui| {
            let label = if st.gdrive == 1 { tr("\u{E2D6} Reconnecter Google Drive") } else { tr("\u{E2D6} Connecter Google Drive") };
            if ui.add_enabled(known && !st.rclone.is_empty() && !busy, egui::Button::new(label)).clicked() {
                start_google(app);
            }
            if busy {
                ui.spinner();
            }
        });
        if known && st.rclone.is_empty() {
            ui.label(RichText::new(tr("Installe d'abord rclone (outils ci-dessus).")).small().color(WARN));
        }
        if let Some(g) = app.install.google.clone() {
            if !g.step.is_empty() {
                ui.label(&g.step);
            }
            if !g.url.is_empty() && !g.done {
                ui.horizontal(|ui| {
                    ui.label(RichText::new(tr("Si le navigateur ne s'est pas ouvert :")).small());
                    if ui.small_button(tr("Ouvrir la page")).clicked() {
                        open_url(&g.url);
                    }
                    if ui.small_button(tr("\u{E1CA} Copier l'adresse")).clicked() {
                        ui.ctx().copy_text(g.url.clone());
                    }
                });
            }
            if !g.error.is_empty() {
                ui.colored_label(ERR, &g.error);
            }
        }
    });
    ui.add_space(8.0);

    // ---- 4. sauvegardes temps reel (cameras comprises)
    crate::pages::card_pub(ui, tr("4. Sauvegardes temps réel (caméras comprises)"), |ui| {
        let rt = app.omv.status.as_ref().map(|s| s.temps_reel.len()).unwrap_or(0);
        if st.cam == 1 {
            row(
                ui,
                k(st.cam_actif == "active"),
                tr("Ancienne synchro des caméras (cam-sync)"),
                tr("la migration (carte 1) la transforme en sauvegarde temps réel"),
            );
        }
        row(ui, if agent { Some(true) } else { None }, tr("Moteur temps réel (nas-debian)"), &tf("{0} sauvegarde(s) temps réel", &[&rt]));
        ui.label(
            RichText::new(tr("Rien à installer en plus : les sauvegardes temps réel (un ou plusieurs dossiers surveillés, dont les caméras) se créent sur la page « Sauvegardes temps réel »."))
                .small()
                .weak(),
        );
        if ui.add_enabled(agent, egui::Button::new(tr("Ouvrir la page Sauvegardes temps réel"))).clicked() {
            app.page = crate::app::Page::Realtime;
        }
        if known && st.gdrive != 1 {
            ui.label(RichText::new(tr("Connecte d'abord Google Drive (carte 3).")).small().color(WARN));
        }
    });
    ui.add_space(8.0);

    // ---- 5. alertes
    crate::pages::card_pub(ui, tr("5. Alertes Home Assistant (notifications sur le téléphone)"), |ui| {
        row(ui, k(st.alertes == 1), tr("Alertes (nas-check / nas-notify)"), &if st.ha_url.is_empty() { String::new() } else { st.ha_url.clone() });
        egui::Grid::new("alertgrid").num_columns(2).spacing([10.0, 6.0]).show(ui, |ui| {
            ui.label(tr("Adresse de Home Assistant"));
            ui.add(egui::TextEdit::singleline(&mut app.install.ha_ip).desired_width(160.0));
            ui.end_row();
            ui.label(tr("Identifiant du webhook"));
            ui.add(egui::TextEdit::singleline(&mut app.install.webhook).desired_width(260.0));
            ui.end_row();
        });
        ui.label(
            RichText::new(tr("Le webhook est celui de l'automatisation Home Assistant « NAS - Alertes sauvegardes » (déclencheurs <id>-critique et <id>-info)."))
                .small()
                .weak(),
        );
        if ui.add_enabled(known && agent && !app.install.ha_ip.trim().is_empty(), egui::Button::new(tr("Installer / mettre à jour les alertes"))).clicked() {
            let script = format!(
                "{} alertes configurer {} {} n 2>&1\n",
                remote::DEBIAN_BIN,
                sq(app.install.ha_ip.trim()),
                sq(app.install.webhook.trim())
            );
            app.action_dialog(HostId::Omv, tr("Installation des alertes"), script, 120);
        }
    });
    ui.add_space(8.0);

    // ---- 6. suivi HA
    crate::pages::card_pub(ui, tr("6. Tableau de bord Home Assistant (MQTT)"), |ui| {
        row(ui, k(st.suivi_ha == 1 && st.mqtt == 1), "nas-ha-status", if st.mqtt == 1 { tr("connexion MQTT configurée") } else { "" });
        egui::Grid::new("mqttgrid").num_columns(2).spacing([10.0, 6.0]).show(ui, |ui| {
            ui.label(tr("Serveur MQTT"));
            ui.add(egui::TextEdit::singleline(&mut app.install.mqtt_host).desired_width(160.0));
            ui.end_row();
            ui.label(tr("Utilisateur MQTT"));
            ui.add(egui::TextEdit::singleline(&mut app.install.mqtt_user).desired_width(160.0));
            ui.end_row();
            ui.label(tr("Mot de passe"));
            ui.add(egui::TextEdit::singleline(&mut app.install.mqtt_pass).password(true).desired_width(160.0));
            ui.end_row();
        });
        ui.label(RichText::new(tr("Utilisateur Home Assistant dédié (ex. « nas »). Laisser vide si la connexion MQTT est déjà configurée.")).small().weak());
        if ui.add_enabled(known && agent, egui::Button::new(tr("Installer / mettre à jour le suivi"))).clicked() {
            let clean = |s: &str| s.replace(['\n', '\r'], "");
            let script = format!(
                "{bin} outils installer suivi >/dev/null 2>&1 || {bin} outils installer suivi 2>&1\n{bin} suivi configurer {} 2>&1 <<'NASMGR_EOF'\n{}\n{}\nNASMGR_EOF\n",
                sq(app.install.mqtt_host.trim()),
                clean(app.install.mqtt_user.trim()),
                clean(&app.install.mqtt_pass),
                bin = remote::DEBIAN_BIN
            );
            app.install.mqtt_pass.clear();
            app.action_dialog(HostId::Omv, tr("Installation du suivi Home Assistant"), script, 900);
        }
    });
    ui.add_space(8.0);

    // ---- 7. memoire de rclone (OMV / Debian)
    crate::pages::card_pub(ui, &tf("7. Mémoire de rclone ({0})", &[&srv]), |ui| {
        crate::ram::card(app, ui, HostId::Omv);
    });
    ui.add_space(8.0);

    // ---- 8. Synology
    crate::pages::card_pub(ui, tr("8. Synology (copie vers l'OMV, migration oCIS)"), |ui| {
        if !app.settings.syno.is_set() {
            ui.label(RichText::new(tr("Synology non configuré (facultatif) : Paramètres > Synology.")).weak());
            return;
        }
        let sy = app.install.syno.clone();
        let s2 = sy.clone().unwrap_or_default();
        if let Some(dsm) = Some(&s2.dsm).filter(|d| !d.is_empty()) {
            ui.label(RichText::new(tf("DSM {0}", &[dsm])).small().weak());
        }
        match &s2.outils {
            Some(t) => {
                let missing = tools_rows(ui, t, false, false);
                ui.horizontal_wrapped(|ui| {
                    if missing && ui.button(tr("\u{E08E} Installer ce qui manque")).clicked() {
                        app.action_dialog(HostId::Syno, tr("Installation des outils"), format!("{} outils installer 2>&1\n", remote::SYNO_BIN), 600);
                    }
                    if let Some(v) = t.rclone_update() {
                        if ui.button(tf("Mettre à jour rclone {0} → {1}", &[&t.rclone, &v])).clicked() {
                            app.action_dialog(HostId::Syno, tr("Mise à jour de rclone"), format!("{} outils rclone-maj 2>&1\n", remote::SYNO_BIN), 600);
                        }
                    }
                });
                if missing {
                    ui.label(RichText::new(tr("python3 et rsync s'activent dans DSM (Centre de paquets, Services de fichiers) ; le reste est installé par le script.")).small().weak());
                }
            }
            None => {
                ui.label(RichText::new(if sy.is_some() { tr("Installe d'abord le script du Synology (carte 1).") } else { tr("…") }).weak());
            }
        }
        if let Some(j) = &s2.jeton {
            token_row(ui, j);
        }
        ui.separator();
        ui.label(RichText::new(tr("Mémoire de rclone (migration oCIS)")).strong());
        crate::ram::card(app, ui, HostId::Syno);
    });
    ui.add_space(8.0);

    // ---- 9. reconstruction apres une panne
    crate::pages::card_pub(ui, &tf("9. Reconstruire après une panne ({0})", &[&srv]), |ui| {
        crate::dests::rebuild_card(app, ui);
    });
}

/// Etat du jeton d'application oCIS
fn token_row(ui: &mut egui::Ui, j: &Token) {
    let now = crate::fmt::now();
    match j.etat.as_str() {
        "refuse" => {
            ui.colored_label(ERR, tr("Jeton oCIS refusé (expiré ou révoqué) : crée un nouveau jeton et mets-le à jour (page Migration)."));
        }
        "ok" => match j.expire {
            Some(t) if t - now < 7 * 86400 => {
                ui.colored_label(WARN, tf("Jeton oCIS : expire {0} — pense à le renouveler (page Migration).", &[&(crate::fmt::ago(t, now))]));
            }
            Some(t) => {
                ui.label(RichText::new(tf("Jeton oCIS valable jusqu'au {0}", &[&(crate::fmt::date(t))])).small().color(OK));
            }
            None => {
                ui.label(RichText::new(tr("Jeton oCIS accepté (date d'expiration non communiquée par oCIS).")).small().weak());
            }
        },
        "non_configure" => {}
        _ => {
            ui.label(RichText::new(tr("Jeton oCIS : état inconnu (oCIS injoignable ?).")).small().weak());
        }
    }
}

// ---------------------------------------------------------------------
//  Autorisation Google Drive (rclone authorize via un tunnel SSH)
// ---------------------------------------------------------------------

pub fn open_url(url: &str) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let _ = std::process::Command::new("rundll32").args(["url.dll,FileProtocolHandler", url]).creation_flags(0x0800_0000).spawn();
    }
    #[cfg(not(windows))]
    {
        let _ = std::process::Command::new("xdg-open").arg(url).spawn();
    }
}

fn set_step(app: &mut App, f: impl FnOnce(&mut GoogleFlow)) {
    if let Some(g) = &mut app.install.google {
        f(g);
    }
}

pub fn start_google(app: &mut App) {
    if app.blocked() {
        return;
    }
    let cfg = app.settings.omv.clone();
    let pass = app.omv.pass.clone();
    let ssh = app.ssh.clone();
    let tx = app.tx.clone();
    let ctx = app.ctx.clone();
    app.install.google = Some(GoogleFlow { step: tr("Préparation de l'autorisation Google…").into(), ..Default::default() });
    crate::log::info("autorisation Google Drive : début");
    let send = move |h: crate::app::Handler| {
        let _ = tx.send(crate::app::Msg::Done(h, Err(crate::ssh::SshError::Other(String::new()))));
        ctx.request_repaint();
    };
    std::thread::spawn(move || {
        let result = google_flow(&ssh, &cfg, pass.as_deref(), &send);
        send(Box::new(move |app: &mut App, _| {
            match result {
                Ok(msg) => {
                    crate::log::info("autorisation Google Drive : terminée");
                    set_step(app, |g| {
                        g.done = true;
                        g.step = msg.clone();
                    });
                    app.output = Some(OutputDialog { title: tr("Google Drive").into(), text: msg, ok: true });
                    refresh(app);
                }
                Err(e) => {
                    crate::log::error(&format!("autorisation Google Drive : {e}"));
                    set_step(app, |g| {
                        g.done = true;
                        g.error = e;
                        g.step.clear();
                    });
                }
            }
        }));
    });
}

/// Deroule l'autorisation Google Drive ; `send` transmet les etapes a l'interface
pub fn google_flow(
    ssh: &crate::ssh::Ssh,
    cfg: &crate::config::HostCfg,
    pass: Option<&str>,
    send: &dyn Fn(crate::app::Handler),
) -> Result<String, String> {
    let token = oauth_token(ssh, cfg, pass, "drive", send, &google_step)?;
    send(Box::new(|app: &mut App, _| set_step(app, |g| g.step = tr("Enregistrement de la connexion sur l'OMV…").into())));
    let script = format!(
        "T={}\nif rclone listremotes 2>/dev/null | grep -x 'gdrive:' >/dev/null; then\n  rclone config update gdrive token \"$T\" --non-interactive >/dev/null 2>&1 || rclone config update gdrive token \"$T\" >/dev/null\nelse\n  rclone config create gdrive drive scope drive token \"$T\" --non-interactive >/dev/null 2>&1 || rclone config create gdrive drive scope drive token \"$T\" >/dev/null\nfi\nif timeout 30 rclone lsd gdrive: --max-depth 1 >/dev/null 2>&1; then echo 'Google Drive est connecté.'; [ -x {bin} ] && {bin} destinations etat gdrive >/dev/null 2>&1; else echo 'Connexion enregistrée, mais Google Drive ne répond pas encore.'; exit 1; fi\n",
        sq(&token),
        bin = remote::DEBIAN_BIN
    );
    let o = ssh.run(cfg, pass, &script, std::time::Duration::from_secs(120)).map_err(|e| e.to_string())?;
    if o.code == 0 {
        Ok(o.text())
    } else {
        Err(o.text())
    }
}

fn google_step(app: &mut App, f: &dyn Fn(&mut GoogleFlow)) {
    set_step(app, |g| f(g))
}

/// Mise a jour de l'etape affichee (fenetre d'autorisation)
pub type StepFn = dyn Fn(&mut App, &dyn Fn(&mut GoogleFlow)) + Send + Sync;

/// Autorisation OAuth d'un service (drive, onedrive, dropbox, pcloud, box) :
/// `rclone authorize` sur le NAS, page de connexion ouverte sur le PC par un tunnel SSH.
/// Renvoie le jeton (JSON).
pub fn oauth_token(
    ssh: &crate::ssh::Ssh,
    cfg: &crate::config::HostCfg,
    pass: Option<&str>,
    kind: &str,
    send: &dyn Fn(crate::app::Handler),
    step: &'static StepFn,
) -> Result<String, String> {
    let kind: String = kind.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    let mut child = ssh
        .spawn_tunnel(cfg, pass, 53682, 53682, &format!("rclone authorize {kind} --auth-no-open-browser 2>&1"))
        .map_err(|e| e.to_string())?;
    let out = child.stdout.take().ok_or(tr("sortie indisponible"))?;
    let reader = std::io::BufReader::new(out);
    let mut token = String::new();
    let mut in_token = false;
    let mut opened = false;
    let start = std::time::Instant::now();
    for line in reader.lines() {
        let Ok(line) = line else { break };
        if start.elapsed() > std::time::Duration::from_secs(600) {
            break;
        }
        if !opened {
            if let Some(i) = line.find("http://127.0.0.1:53682/") {
                let url: String = line[i..].split_whitespace().next().unwrap_or("").to_string();
                opened = true;
                open_url(&url);
                send(Box::new(move |app: &mut App, _| {
                    step(app, &|g: &mut GoogleFlow| {
                        g.url = url.clone();
                        g.step = tr("Connecte-toi dans le navigateur qui vient de s'ouvrir, puis autorise rclone.").into();
                    })
                }));
            }
        }
        if line.contains("--->") {
            in_token = true;
            continue;
        }
        if line.contains("<---") {
            break;
        }
        if in_token {
            token.push_str(line.trim());
        }
        if line.contains("Failed") || line.contains("CRITICAL") || line.contains("bind: address already in use") {
            let _ = child.kill();
            return Err(tf("rclone : {0}", &[&(line.trim())]));
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    let mut err = String::new();
    if let Some(mut e) = child.stderr.take() {
        use std::io::Read;
        let _ = e.read_to_string(&mut err);
    }
    if token.is_empty() || !token.starts_with('{') {
        if err.contains("Address already in use") || err.contains("cannot listen") || err.contains("forwarding") {
            return Err(tr("Le port 53682 est déjà utilisé sur ce PC (une autre autorisation rclone ouverte ?).").into());
        }
        return Err(tf("Autorisation non reçue (fenêtre fermée ou délai dépassé).{0}", &[&(err.lines().last().map(|l| format!(" {l}")).unwrap_or_default())]));
    }
    Ok(token)
}
