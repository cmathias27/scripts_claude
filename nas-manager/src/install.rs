//! Page « Installation » : mise en place complete des NAS depuis l'application
//! (rclone, connexion Google Drive, scripts, synchro cameras, alertes, suivi Home Assistant).

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::app::{App, BrowsePurpose, HostId, OutputDialog};
use crate::remote;
use crate::ssh::sq;
use crate::theme::{ERR, IDLE, OK, WARN};
use eframe::egui::{self, RichText};
use serde::Deserialize;
use std::io::BufRead;

pub const CAM_SH: &str = include_str!("../../install-cam-sync.sh");
pub const ALERTES_SH: &str = include_str!("../../install-alertes.sh");
pub const SUIVI_HA_SH: &str = include_str!("../../install-suivi-ha.sh");

/// Etat des composants de l'OMV
pub const OMV_INSTALL_STATUS: &str = r#####"
export LC_ALL=C
py=$(command -v python3 >/dev/null && echo 1 || echo 0)
rc=$(command -v rclone >/dev/null && rclone version 2>/dev/null | head -n 1 | awk '{print $2}')
remotes=$(rclone listremotes 2>/dev/null | tr '\n' ' ')
gd=0; [ -n "$rc" ] && echo " $remotes" | grep -q ' gdrive: ' && gd=1
gdok=0; [ $gd = 1 ] && timeout 25 rclone lsd gdrive: --max-depth 1 >/dev/null 2>&1 && gdok=1
nb=$(grep -m1 '^API_VERSION=' /usr/local/bin/nas-backup 2>/dev/null | cut -d= -f2)
cam=0; [ -f /usr/local/bin/cam-sync.sh ] && cam=1
camact=$(systemctl is-active cam-sync 2>/dev/null)
camsrc=$(grep -m1 '^SRC=' /usr/local/bin/cam-sync.sh 2>/dev/null | cut -d'"' -f2)
al=0; [ -x /usr/local/bin/nas-check ] && al=1
haurl=$(grep -m1 '^HA_URL=' /etc/nas-backup/notify.conf 2>/dev/null | cut -d'"' -f2)
ha=0; [ -x /usr/local/bin/nas-ha-status ] && ha=1
mq=0; [ -f /root/.config/mosquitto_pub ] && mq=1
printf '{"python3":%s,"rclone":"%s","remotes":"%s","gdrive":%s,"gdrive_ok":%s,"nb_api":"%s","cam":%s,"cam_actif":"%s","cam_src":"%s","alertes":%s,"ha_url":"%s","suivi_ha":%s,"mqtt":%s}\n' \
  "$py" "$rc" "$remotes" "$gd" "$gdok" "$nb" "$cam" "$camact" "$camsrc" "$al" "$haurl" "$ha" "$mq"
"#####;

/// Etat du Synology
pub const SYNO_INSTALL_STATUS: &str = r#####"
export LC_ALL=C
py=$(command -v python3 >/dev/null && echo 1 || echo 0)
rs=$(command -v rsync >/dev/null && echo 1 || echo 0)
dsm=$(grep -m1 '^productversion=' /etc.defaults/VERSION 2>/dev/null | cut -d'"' -f2)
printf '{"python3":%s,"rsync":%s,"dsm":"%s"}\n' "$py" "$rs" "$dsm"
"#####;

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct OmvInstall {
    pub python3: u8,
    pub rclone: String,
    pub remotes: String,
    pub gdrive: u8,
    pub gdrive_ok: u8,
    pub nb_api: String,
    pub cam: u8,
    pub cam_actif: String,
    pub cam_src: String,
    pub alertes: u8,
    pub ha_url: String,
    pub suivi_ha: u8,
    pub mqtt: u8,
}

#[derive(Deserialize, Default, Clone, Debug)]
#[serde(default)]
pub struct SynoInstall {
    pub python3: u8,
    pub rsync: u8,
    pub dsm: String,
}

pub struct InstallState {
    pub omv: Option<OmvInstall>,
    pub syno: Option<SynoInstall>,
    pub loading: bool,
    pub cam_src: String,
    pub cam_initial: bool,
    pub ha_ip: String,
    pub webhook: String,
    pub mqtt_host: String,
    pub mqtt_user: String,
    pub mqtt_pass: String,
    /// autorisation Google en cours : URL a ouvrir
    pub google: Option<GoogleFlow>,
}

impl Default for InstallState {
    fn default() -> Self {
        Self {
            omv: None,
            syno: None,
            loading: false,
            cam_src: String::new(),
            cam_initial: false,
            ha_ip: "192.168.1.222".into(),
            webhook: "nas-c09f382daf2d01deb430abbd".into(),
            mqtt_host: "192.168.1.222".into(),
            mqtt_user: String::new(),
            mqtt_pass: String::new(),
            google: None,
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
        tr("Vérification de l'OMV"),
        OMV_INSTALL_STATUS.to_string(),
        60,
        Box::new(|app, r| {
            app.install.loading = false;
            match r {
                Ok(o) => {
                    if let Some(l) = o.stdout.lines().rev().find(|l| l.starts_with('{')) {
                        if let Ok(s) = serde_json::from_str::<OmvInstall>(l) {
                            if app.install.cam_src.is_empty() {
                                app.install.cam_src = s.cam_src.clone();
                            }
                            if let Some(h) = s.ha_url.split("://").nth(1) {
                                app.install.ha_ip = h.split(':').next().unwrap_or("").to_string();
                            }
                            app.install.omv = Some(s);
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
            30,
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

/// Envoie un script d'installation sur l'OMV et l'execute avec des variables d'environnement
fn run_install_script(app: &mut App, title: &str, name: &str, content: &str, env: &[(&str, String)]) {
    let path = format!("/root/.nas-manager/{name}");
    let mut script = remote::install_file(&path, content);
    let vars: String = env.iter().map(|(k, v)| format!("{k}={} ", sq(v))).collect();
    script.push_str(&format!("cd /root/.nas-manager && {vars}bash {} 2>&1 < /dev/null\n", sq(&path)));
    app.action_dialog(HostId::Omv, title, script, 1800);
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

pub fn page(app: &mut App, ui: &mut egui::Ui) {
    ui.heading(tr("Installation des NAS"));
    ui.label(RichText::new(tr("Tout ce qu'il faut sur l'OMV et le Synology, installé depuis l'application (rien à taper en SSH).")).weak());
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

    // ---- 1. outils de base
    crate::pages::card_pub(ui, tr("1. Outils de l'OMV"), |ui| {
        row(ui, k(st.python3 == 1), "python3", tr("nécessaire au suivi"));
        row(ui, k(!st.rclone.is_empty()), "rclone", &if st.rclone.is_empty() { tr("absent").to_string() } else { st.rclone.clone() });
        if known && st.rclone.is_empty() {
            if ui.button(tr("Installer rclone")).clicked() {
                let script = "set -e\napt-get update -qq\napt-get install -y -qq curl unzip python3 >/dev/null\ncurl -fsSL https://rclone.org/install.sh | bash\nrclone version | head -n 1\n".to_string();
                app.action_dialog(HostId::Omv, tr("Installation de rclone"), script, 900);
            }
        }
    });
    ui.add_space(8.0);

    // ---- 2. Google Drive
    crate::pages::card_pub(ui, tr("2. Connexion Google Drive"), |ui| {
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
                tr("L'application ouvre la page de connexion Google dans ton navigateur ; l'autorisation est transmise à l'OMV par la connexion SSH (rien à copier)."),
            )
            .small()
            .weak(),
        );
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

    // ---- 3. sauvegardes
    crate::pages::card_pub(ui, tr("3. Sauvegardes (nas-backup)"), |ui| {
        let ok = st.nb_api.parse::<u32>().map(|v| v >= remote::nb_api()).unwrap_or(false);
        row(ui, k(ok), "nas-backup", &if st.nb_api.is_empty() { "absent".to_string() } else { tf("version {0}", &[&st.nb_api]) });
        if ui.add_enabled(known && st.gdrive == 1, egui::Button::new(tr("Installer / mettre à jour"))).clicked() {
            let script = remote::install_file(remote::NB_BIN, remote::NAS_BACKUP_SH) + &format!("{} gen-cron >/dev/null 2>&1 && echo 'Planification prête.' || true\n", remote::NB_BIN);
            app.action_dialog(HostId::Omv, tr("Installation de nas-backup"), script, 120);
        }
        if known && st.gdrive != 1 {
            ui.label(RichText::new(tr("Connecte d'abord Google Drive.")).small().color(WARN));
        }
    });
    ui.add_space(8.0);

    // ---- 4. cameras
    crate::pages::card_pub(ui, tr("4. Synchro des caméras (temps réel, chiffrée)"), |ui| {
        row(
            ui,
            k(st.cam == 1 && st.cam_actif == "active"),
            "cam-sync",
            &if st.cam == 1 { tf("service {0}", &[&(if st.cam_actif == "active" { "actif" } else { tr("arrêté") })]) } else { tr("non installée").to_string() },
        );
        ui.horizontal(|ui| {
            ui.label(tr("Dossier des caméras :"));
            ui.add(egui::TextEdit::singleline(&mut app.install.cam_src).desired_width(360.0));
            if ui.button("\u{E24A}").clicked() {
                app.open_browser(HostId::Omv, BrowsePurpose::CamSource, "");
            }
        });
        ui.checkbox(&mut app.install.cam_initial, tr("Envoyer aussi les vidéos déjà présentes (en arrière-plan)"));
        let can = known && st.gdrive == 1 && !app.install.cam_src.trim().is_empty();
        if ui.add_enabled(can, egui::Button::new(if st.cam == 1 { tr("Réinstaller / changer de dossier") } else { tr("Installer la synchro des caméras") })).clicked() {
            let env = [
                ("CAM_SRC", app.install.cam_src.trim().to_string()),
                ("CAM_PREMIER_ENVOI", if app.install.cam_initial { "o".into() } else { "n".into() }),
            ];
            run_install_script(app, tr("Installation de la synchro des caméras"), "install-cam-sync.sh", CAM_SH, &env);
        }
        ui.label(RichText::new(tr("Les mots de passe de chiffrement créés s'affichent à la fin : note-les en lieu sûr.")).small().color(WARN));
    });
    ui.add_space(8.0);

    // ---- 5. alertes
    crate::pages::card_pub(ui, tr("5. Alertes Home Assistant (notifications sur le téléphone)"), |ui| {
        row(ui, k(st.alertes == 1), tr("nas-check / nas-notify"), &if st.ha_url.is_empty() { String::new() } else { st.ha_url.clone() });
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
        if ui.add_enabled(known && !app.install.ha_ip.trim().is_empty(), egui::Button::new(tr("Installer / mettre à jour les alertes"))).clicked() {
            let env = [
                ("NAS_HA_IP", app.install.ha_ip.trim().to_string()),
                ("NAS_WEBHOOK", app.install.webhook.trim().to_string()),
                ("NAS_TEST_CRITIQUE", "n".into()),
            ];
            run_install_script(app, tr("Installation des alertes"), "install-alertes.sh", ALERTES_SH, &env);
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
        if ui.add_enabled(known, egui::Button::new(tr("Installer / mettre à jour le suivi"))).clicked() {
            let mut env = vec![("NAS_MQTT_HOST", app.install.mqtt_host.trim().to_string())];
            if !app.install.mqtt_user.trim().is_empty() {
                env.push(("NAS_MQTT_USER", app.install.mqtt_user.trim().to_string()));
                env.push(("NAS_MQTT_PASS", app.install.mqtt_pass.clone()));
            }
            app.install.mqtt_pass.clear();
            run_install_script(app, tr("Installation du suivi Home Assistant"), "install-suivi-ha.sh", SUIVI_HA_SH, &env);
        }
    });
    ui.add_space(8.0);

    // ---- 7. Synology
    crate::pages::card_pub(ui, tr("7. Synology (copie vers l'OMV, migration oCIS)"), |ui| {
        if !app.settings.syno.is_set() {
            ui.label(RichText::new(tr("Synology non configuré (facultatif) : Paramètres > Synology.")).weak());
            return;
        }
        let sy = app.install.syno.clone();
        let sk = sy.is_some();
        let s2 = sy.unwrap_or_default();
        let kk = |b: bool| if sk { Some(b) } else { None };
        row(ui, kk(s2.python3 == 1), "python3", tr("fourni par DSM 7"));
        row(ui, kk(s2.rsync == 1), "rsync", "");
        if !s2.dsm.is_empty() {
            ui.label(RichText::new(tf("DSM {0}", &[&s2.dsm])).small().weak());
        }
        let ss = app.syno.status.clone();
        row(
            ui,
            ss.as_ref().map(|s| s.copie.installe && s.copie.api >= remote::copie_api() && s.migration.installe && s.migration.api >= remote::migre_api()),
            tr("Scripts copie-omv et migre-drive-ocis"),
            "",
        );
        row(ui, ss.as_ref().map(|s| s.copie.cle_omv), tr("Connexion automatique Synology → OMV"), "");
        ui.label(RichText::new(tr("Installation des scripts : Paramètres > Scripts sur les NAS · clé vers l'OMV : page Copie → OMV · oCIS : page Migration.")).small().weak());
    });
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

/// Deroule l'autorisation ; `send` transmet les etapes a l'interface
pub fn google_flow(
    ssh: &crate::ssh::Ssh,
    cfg: &crate::config::HostCfg,
    pass: Option<&str>,
    send: &dyn Fn(crate::app::Handler),
) -> Result<String, String> {
    let mut child = ssh
        .spawn_tunnel(cfg, pass, 53682, 53682, "rclone authorize drive --auth-no-open-browser 2>&1")
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
                    set_step(app, |g| {
                        g.url = url.clone();
                        g.step = tr("Connecte-toi à Google dans le navigateur qui vient de s'ouvrir, puis autorise rclone.").into();
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
    send(Box::new(|app: &mut App, _| set_step(app, |g| g.step = tr("Enregistrement de la connexion sur l'OMV…").into())));
    let script = format!(
        "T={}\nif rclone listremotes 2>/dev/null | grep -x 'gdrive:' >/dev/null; then\n  rclone config update gdrive token \"$T\" --non-interactive >/dev/null 2>&1 || rclone config update gdrive token \"$T\" >/dev/null\nelse\n  rclone config create gdrive drive scope drive token \"$T\" --non-interactive >/dev/null 2>&1 || rclone config create gdrive drive scope drive token \"$T\" >/dev/null\nfi\nif timeout 30 rclone lsd gdrive: --max-depth 1 >/dev/null 2>&1; then echo 'Google Drive est connecté.'; else echo 'Connexion enregistrée, mais Google Drive ne répond pas encore.'; exit 1; fi\n",
        sq(&token)
    );
    let o = ssh.run(cfg, pass, &script, std::time::Duration::from_secs(90)).map_err(|e| e.to_string())?;
    if o.code == 0 {
        Ok(o.text())
    } else {
        Err(o.text())
    }
}
