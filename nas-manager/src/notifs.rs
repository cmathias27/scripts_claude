//! Page « Alertes & santé » : canaux de notification (ntfy, Telegram, Discord, e-mail,
//! Home Assistant), santé des disques (SMART, RAID) et rapport périodique.

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::app::{App, HostId, OutputDialog};
use crate::fmt;
use crate::model::{Canal, DiskHealth, NotifConf, RapportConf, SmartDisk};
use crate::remote;
use crate::theme::{ERR, IDLE, INFO, OK, WARN};
use eframe::egui::{self, Color32, RichText};
use std::collections::BTreeMap;

// ---------------------------------------------------------------------
//  Canaux
// ---------------------------------------------------------------------

pub struct ChannelKind {
    pub id: &'static str,
    pub icon: &'static str,
    pub label: &'static str,
    pub desc: &'static str,
}

pub const CHANNELS: &[ChannelKind] = &[
    ChannelKind {
        id: "ntfy",
        icon: "\u{E5E8}",
        label: "ntfy (application gratuite)",
        desc: "Notifications sur le téléphone avec l'application ntfy (Android, iPhone). Aucun compte : un nom de sujet secret suffit.",
    },
    ChannelKind {
        id: "telegram",
        icon: "\u{E5BC}",
        label: "Telegram",
        desc: "Un bot Telegram t'écrit. Crée-le en écrivant à @BotFather (commande /newbot), puis envoie un message à ton bot.",
    },
    ChannelKind {
        id: "discord",
        icon: "\u{E61A}",
        label: "Discord",
        desc: "Messages dans un salon Discord (webhook du salon).",
    },
    ChannelKind {
        id: "email",
        icon: "\u{E214}",
        label: "E-mail",
        desc: "Un e-mail par alerte, envoyé par ton serveur de messagerie (Gmail, Outlook, Free, Orange, OVH...).",
    },
    ChannelKind {
        id: "ha",
        icon: "\u{E2C2}",
        label: "Home Assistant",
        desc: "Notifications de l'application Home Assistant, par l'automatisation « NAS - Alertes sauvegardes ».",
    },
];

pub fn channel(id: &str) -> Option<&'static ChannelKind> {
    CHANNELS.iter().find(|c| c.id == id)
}

pub fn channel_label(id: &str) -> &'static str {
    channel(id).map(|c| tr(c.label)).unwrap_or("?")
}

/// Serveurs d'envoi courants : (libelle, serveur, port, securite, aide)
const MAIL_PRESETS: &[(&str, &str, &str, &str, &str)] = &[
    ("Gmail", "smtp.gmail.com", "587", "starttls", "Gmail : crée un « mot de passe d'application » (compte Google → Sécurité → Validation en deux étapes → Mots de passe des applications)."),
    ("Outlook / Hotmail", "smtp-mail.outlook.com", "587", "starttls", "Outlook : l'envoi par SMTP doit être autorisé dans les paramètres du compte."),
    ("Free", "smtp.free.fr", "465", "ssl", "Free : identifiant et mot de passe de l'adresse Free."),
    ("Orange", "smtp.orange.fr", "465", "ssl", "Orange : adresse e-mail Orange complète et son mot de passe."),
    ("OVH", "ssl0.ovh.net", "465", "ssl", "OVH : adresse e-mail complète et son mot de passe."),
    ("Autre", "", "587", "starttls", ""),
];

const SECU: &[(&str, &str)] = &[("starttls", "STARTTLS (port 587)"), ("ssl", "SSL/TLS (port 465)"), ("aucune", "Aucune (réseau local)")];

#[derive(Default, Clone)]
pub struct ChannelForm {
    /// canal choisi (vide : choix du canal)
    pub canal: String,
    /// "tout" ou "critique"
    pub niveau: String,
    pub values: BTreeMap<String, String>,
    pub editing: bool,
    pub busy: bool,
    pub error: String,
    pub preset: usize,
    /// conversations Telegram trouvees : (identifiant, nom)
    pub chats: Vec<(String, String)>,
}

impl ChannelForm {
    fn v(&mut self, k: &str) -> &mut String {
        self.values.entry(k.to_string()).or_default()
    }
}

#[derive(Default)]
pub struct NotifUi {
    pub form: Option<ChannelForm>,
    /// rapport en cours de modification
    pub report: Option<RapportConf>,
    /// seuils en cours de modification : (rappel h, espace %, retard h)
    pub thresholds: Option<(u32, u32, u32)>,
}

/// Sujet ntfy difficile a deviner
fn random_topic() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));
    let mut n = h.finish();
    let alpha = b"abcdefghijkmnpqrstuvwxyz23456789";
    let mut s = String::from("nas-");
    for _ in 0..12 {
        s.push(alpha[(n % alpha.len() as u64) as usize] as char);
        n /= alpha.len() as u64;
    }
    s
}

fn new_form(canal: &str, app: &App) -> ChannelForm {
    let mut f = ChannelForm { canal: canal.into(), niveau: "tout".into(), ..Default::default() };
    match canal {
        "ntfy" => {
            f.values.insert("url".into(), format!("https://ntfy.sh/{}", random_topic()));
        }
        "email" => {
            f.niveau = "critique".into();
            f.values.insert("serveur".into(), MAIL_PRESETS[0].1.into());
            f.values.insert("port".into(), MAIL_PRESETS[0].2.into());
            f.values.insert("securite".into(), MAIL_PRESETS[0].3.into());
        }
        "ha" => {
            f.values.insert("ip".into(), app.install.ha_ip.clone());
            f.values.insert("webhook".into(), app.install.webhook.clone());
        }
        _ => {}
    }
    f
}

/// Formulaire pre-rempli pour modifier un canal (les secrets sont a ressaisir, sauf pour l'e-mail)
fn edit_form(canal: &str, c: &Canal, app: &App) -> ChannelForm {
    let mut f = new_form(canal, app);
    f.editing = true;
    f.niveau = if c.niveau.is_empty() { "tout".into() } else { c.niveau.clone() };
    match canal {
        "ntfy" => {
            f.values.insert("url".into(), c.cible.clone());
        }
        "telegram" => {
            f.values.insert("conversation".into(), c.cible.trim_start_matches("conversation ").to_string());
        }
        "email" => {
            for (k, v) in [
                ("destinataire", &c.destinataire),
                ("serveur", &c.serveur),
                ("port", &c.port),
                ("securite", &c.securite),
                ("utilisateur", &c.utilisateur),
                ("expediteur", &c.expediteur),
            ] {
                f.values.insert(k.into(), v.clone());
            }
            f.preset = MAIL_PRESETS.iter().position(|p| p.1 == c.serveur).unwrap_or(MAIL_PRESETS.len() - 1);
        }
        "ha" => {
            let host = c.cible.split("://").nth(1).unwrap_or(&c.cible).split([':', '/']).next().unwrap_or("").to_string();
            f.values.insert("ip".into(), host);
        }
        _ => {}
    }
    f
}

fn level_text(n: &str) -> &'static str {
    if n == "critique" {
        tr("alertes seulement")
    } else {
        tr("alertes et messages discrets")
    }
}

/// Carte « Notifications » : canaux configures, ajout, test, retrait
pub fn channels_card(app: &mut App, ui: &mut egui::Ui, conf: Option<&NotifConf>, api_ok: bool) {
    crate::pages::card_pub(ui, tr("\u{E1E0} Notifications sur le téléphone"), |ui| {
        if !api_ok {
            ui.label(tr("ntfy, Telegram, Discord et e-mail demandent le script nas-debian à jour (version 2.3 ou plus). Seul Home Assistant est disponible : page Installation."));
            return;
        }
        let Some(conf) = conf else {
            ui.label(RichText::new(tr("Lecture des réglages…")).weak());
            return;
        };
        if conf.canaux.is_empty() {
            crate::pages::dot_label_pub(ui, WARN, tr("Aucun canal : tu ne seras pas prévenu en cas de problème (les alertes restent visibles ici)."));
        }
        let mut action: Option<(&'static str, String)> = None;
        egui::Grid::new("canaux").num_columns(4).spacing([14.0, 6.0]).show(ui, |ui| {
            for (id, c) in &conf.canaux {
                let k = channel(id);
                ui.label(RichText::new(format!("{}  {}", k.map(|k| k.icon).unwrap_or(""), channel_label(id))).strong());
                let cible: String = if c.cible.chars().count() > 34 { c.cible.chars().take(33).collect::<String>() + "…" } else { c.cible.clone() };
                ui.label(RichText::new(cible).weak().small()).on_hover_text(&c.cible);
                let cur = if c.niveau.is_empty() { "tout" } else { c.niveau.as_str() };
                egui::ComboBox::from_id_salt(format!("niv-{id}")).width(185.0).selected_text(level_text(cur)).show_ui(ui, |ui| {
                    for n in ["tout", "critique"] {
                        if ui.selectable_label(cur == n, level_text(n)).clicked() && cur != n {
                            action = Some(if n == "tout" { ("tout", id.clone()) } else { ("critique", id.clone()) });
                        }
                    }
                });
                ui.horizontal(|ui| {
                    if ui.small_button(tr("Tester")).on_hover_text(tr("Envoie un message de test sur ce canal")).clicked() {
                        action = Some(("tester", id.clone()));
                    }
                    if ui.small_button("\u{E3B4}").on_hover_text(tr("Modifier")).clicked() {
                        action = Some(("modifier", id.clone()));
                    }
                    if ui.small_button("\u{E4A6}").on_hover_text(tr("Retirer ce canal")).clicked() {
                        action = Some(("retirer", id.clone()));
                    }
                });
                ui.end_row();
            }
        });
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            if ui.add(egui::Button::new(RichText::new(tr("+ Ajouter un canal")).color(Color32::WHITE)).fill(INFO)).clicked() {
                app.notifs.form = Some(ChannelForm::default());
            }
            if !conf.canaux.is_empty() && ui.button(tr("\u{E398} Tester tous les canaux")).clicked() {
                app.action_toast(HostId::Omv, tr("Notification de test"), remote::canal_test(""), 60);
            }
        });
        ui.label(
            RichText::new(tr("Alertes : sauvegarde en échec ou en retard, destination injoignable, disque en danger… puis « rétabli » quand tout revient. Messages discrets : tests et événements sans gravité."))
                .small()
                .weak(),
        );
        if !conf.erreurs.is_empty() {
            egui::CollapsingHeader::new(RichText::new(tf("Derniers envois en échec ({0})", &[&conf.erreurs.len()])).color(WARN).small())
                .id_salt("notif-err")
                .show(ui, |ui| {
                    for e in &conf.erreurs {
                        ui.label(RichText::new(e).monospace().size(11.0));
                    }
                });
        }
        match action {
            Some(("retirer", id)) => {
                let n = id.clone();
                app.ask_confirm(
                    tr("Retirer le canal"),
                    &tf("Plus aucune notification ne sera envoyée par « {0} ».", &[&channel_label(&id)]),
                    tr("Retirer"),
                    true,
                    None,
                    Box::new(move |app| app.action_toast(HostId::Omv, tr("Retrait du canal"), remote::canal_remove(&n), 30)),
                );
            }
            Some(("modifier", id)) => {
                if let Some(c) = conf.canaux.get(&id) {
                    let f = edit_form(&id, c, app);
                    app.notifs.form = Some(f);
                }
            }
            Some(("tester", id)) => app.action_toast(HostId::Omv, tr("Notification de test"), remote::canal_test(&id), 60),
            Some((niv, id)) => app.action_toast(HostId::Omv, tr("Notifications"), remote::canal_level(&id, niv), 30),
            None => {}
        }
    });
}

fn field(ui: &mut egui::Ui, f: &mut ChannelForm, key: &str, label: &str, hint: &str, secret: bool, width: f32) {
    ui.label(label);
    ui.add(egui::TextEdit::singleline(f.v(key)).password(secret).hint_text(hint).desired_width(width));
    ui.end_row();
}

/// Parametres envoyes au script pour le canal du formulaire ; erreur lisible si incomplet
fn form_params(f: &ChannelForm) -> Result<Vec<(&'static str, String)>, &'static str> {
    let g = |k: &str| f.values.get(k).map(|s| s.trim().to_string()).unwrap_or_default();
    let p: Vec<(&'static str, String)> = match f.canal.as_str() {
        "ntfy" => {
            let u = g("url");
            if !u.starts_with("http") || u.trim_end_matches('/').rsplit('/').next().unwrap_or("").len() < 6 {
                return Err(tr("Adresse ntfy invalide : https://ntfy.sh/ suivi d'un nom de sujet (6 caractères au moins)."));
            }
            vec![("url", u.trim_end_matches('/').to_string()), ("jeton", g("jeton"))]
        }
        "telegram" => {
            if g("jeton").is_empty() {
                return Err(tr("Colle le jeton du bot (donné par @BotFather)."));
            }
            if g("conversation").is_empty() {
                return Err(tr("Identifiant de conversation manquant : envoie un message à ton bot, puis « Trouver »."));
            }
            vec![("jeton", g("jeton")), ("conversation", g("conversation"))]
        }
        "discord" => {
            if !g("url").contains("/api/webhooks/") {
                return Err(tr("Colle l'adresse du webhook Discord (https://discord.com/api/webhooks/...)."));
            }
            vec![("url", g("url"))]
        }
        "email" => {
            if !g("destinataire").contains('@') {
                return Err(tr("Adresse du destinataire invalide."));
            }
            if g("serveur").is_empty() {
                return Err(tr("Serveur d'envoi (SMTP) manquant."));
            }
            if !f.editing && !g("utilisateur").is_empty() && g("mot_de_passe").is_empty() {
                return Err(tr("Mot de passe du compte e-mail manquant."));
            }
            ["destinataire", "serveur", "port", "securite", "utilisateur", "mot_de_passe", "expediteur"].iter().map(|k| (*k, g(k))).collect()
        }
        "ha" => {
            if g("ip").is_empty() || g("webhook").is_empty() {
                return Err(tr("Adresse de Home Assistant et identifiant du webhook nécessaires."));
            }
            vec![("ip", g("ip")), ("webhook", g("webhook"))]
        }
        _ => return Err(""),
    };
    Ok(p)
}

pub fn form_window(app: &mut App, ctx: &egui::Context) {
    let Some(mut f) = app.notifs.form.take() else { return };
    let mut open = true;
    let mut save = false;
    let mut find_chats = false;
    let mut close = false;
    egui::Window::new(RichText::new(if f.editing { tr("Modifier le canal") } else { tr("Ajouter un canal de notification") }).strong())
        .id(egui::Id::unique("notifform"))
        .collapsible(false)
        .resizable(false)
        .default_width(600.0)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            if f.canal.is_empty() {
                ui.label(tr("Comment veux-tu être prévenu ?"));
                ui.add_space(4.0);
                for k in CHANNELS {
                    let r = ui.add(egui::Button::new(RichText::new(format!("{}  {}", k.icon, tr(k.label))).strong()).min_size(egui::vec2(ui.available_width(), 0.0)));
                    ui.label(RichText::new(tr(k.desc)).small().weak());
                    if r.clicked() {
                        f = new_form(k.id, app);
                    }
                    ui.add_space(2.0);
                }
                return;
            }
            let Some(k) = channel(&f.canal) else { return };
            ui.horizontal(|ui| {
                if !f.editing && ui.small_button("←").on_hover_text(tr("Changer de canal")).clicked() {
                    f = ChannelForm::default();
                }
                ui.label(RichText::new(format!("{}  {}", k.icon, tr(k.label))).strong());
            });
            if f.canal.is_empty() {
                return;
            }
            ui.label(RichText::new(tr(k.desc)).small().weak());
            ui.add_space(6.0);
            match f.canal.as_str() {
                "ntfy" => {
                    ui.label(tr("1. Installe l'application ntfy sur ton téléphone (Play Store, App Store ou F-Droid)."));
                    ui.label(tr("2. Dans l'application : bouton +, puis le nom du sujet ci-dessous (même nom exactement)."));
                    ui.label(RichText::new(tr("Garde ce nom secret : qui le connaît peut lire tes notifications.")).small().color(WARN));
                    ui.add_space(4.0);
                    egui::Grid::new("ntfygrid").num_columns(2).spacing([10.0, 6.0]).show(ui, |ui| {
                        ui.label(tr("Adresse du sujet"));
                        ui.horizontal(|ui| {
                            ui.add(egui::TextEdit::singleline(f.v("url")).desired_width(330.0));
                            let topic = f.v("url").trim_end_matches('/').rsplit('/').next().unwrap_or("").to_string();
                            if ui.small_button("\u{E1CA}").on_hover_text(tr("Copier le nom du sujet")).clicked() {
                                ui.ctx().copy_text(topic);
                            }
                        });
                        ui.end_row();
                        field(ui, &mut f, "jeton", tr("Jeton d'accès"), tr("facultatif (serveur ntfy protégé)"), true, 330.0);
                    });
                }
                "telegram" => {
                    egui::Grid::new("tggrid").num_columns(2).spacing([10.0, 6.0]).show(ui, |ui| {
                        field(ui, &mut f, "jeton", tr("Jeton du bot"), "123456789:AAH...", true, 330.0);
                        ui.label(tr("Conversation"));
                        ui.horizontal(|ui| {
                            ui.add(egui::TextEdit::singleline(f.v("conversation")).desired_width(160.0).hint_text("123456789"));
                            if ui.add_enabled(!f.busy, egui::Button::new(tr("\u{E30C} Trouver"))).on_hover_text(tr("Cherche les conversations qui ont écrit au bot")).clicked() {
                                find_chats = true;
                            }
                        });
                        ui.end_row();
                    });
                    ui.label(RichText::new(tr("Envoie d'abord un message (par exemple « bonjour ») à ton bot dans Telegram, puis clique sur « Trouver ».")).small().weak());
                    let chats = f.chats.clone();
                    for (id, name) in chats {
                        if ui.selectable_label(f.values.get("conversation") == Some(&id), format!("{name}  ({id})")).clicked() {
                            f.values.insert("conversation".into(), id);
                        }
                    }
                }
                "discord" => {
                    ui.label(tr("Dans Discord : paramètres du salon → Intégrations → Webhooks → Nouveau webhook → Copier l'URL du webhook."));
                    egui::Grid::new("dcgrid").num_columns(2).spacing([10.0, 6.0]).show(ui, |ui| {
                        field(ui, &mut f, "url", tr("Adresse du webhook"), "https://discord.com/api/webhooks/...", true, 380.0);
                    });
                }
                "email" => {
                    egui::Grid::new("mailgrid").num_columns(2).spacing([10.0, 6.0]).show(ui, |ui| {
                        field(ui, &mut f, "destinataire", tr("Envoyer à"), "moi@exemple.fr", false, 280.0);
                        ui.label(tr("Messagerie"));
                        let mut p = f.preset;
                        egui::ComboBox::from_id_salt("mailpreset").selected_text(MAIL_PRESETS[p].0).show_ui(ui, |ui| {
                            for (i, m) in MAIL_PRESETS.iter().enumerate() {
                                ui.selectable_value(&mut p, i, m.0);
                            }
                        });
                        if p != f.preset {
                            f.preset = p;
                            let m = MAIL_PRESETS[p];
                            if !m.1.is_empty() {
                                f.values.insert("serveur".into(), m.1.into());
                            }
                            f.values.insert("port".into(), m.2.into());
                            f.values.insert("securite".into(), m.3.into());
                        }
                        ui.end_row();
                        field(ui, &mut f, "serveur", tr("Serveur d'envoi (SMTP)"), "smtp.exemple.fr", false, 220.0);
                        field(ui, &mut f, "port", tr("Port"), "587", false, 60.0);
                        ui.label(tr("Sécurité"));
                        let cur = f.v("securite").clone();
                        egui::ComboBox::from_id_salt("mailsecu").selected_text(SECU.iter().find(|s| s.0 == cur).map(|s| tr(s.1)).unwrap_or("STARTTLS")).show_ui(ui, |ui| {
                            for (c, l) in SECU {
                                ui.selectable_value(f.values.entry("securite".into()).or_default(), c.to_string(), tr(l));
                            }
                        });
                        ui.end_row();
                        field(ui, &mut f, "utilisateur", tr("Identifiant"), tr("souvent l'adresse e-mail"), false, 280.0);
                        let hint = if f.editing { tr("inchangé si vide") } else { "" };
                        field(ui, &mut f, "mot_de_passe", tr("Mot de passe"), hint, true, 220.0);
                        field(ui, &mut f, "expediteur", tr("Expéditeur"), tr("facultatif (l'identifiant par défaut)"), false, 280.0);
                    });
                    let help = MAIL_PRESETS[f.preset].4;
                    if !help.is_empty() {
                        ui.label(RichText::new(tr(help)).small().weak());
                    }
                }
                "ha" => {
                    egui::Grid::new("hagrid").num_columns(2).spacing([10.0, 6.0]).show(ui, |ui| {
                        field(ui, &mut f, "ip", tr("Adresse de Home Assistant"), "192.168.1.10", false, 200.0);
                        field(ui, &mut f, "webhook", tr("Identifiant du webhook"), "", false, 260.0);
                    });
                    ui.label(RichText::new(tr("Le webhook est celui de l'automatisation Home Assistant « NAS - Alertes sauvegardes » (déclencheurs <id>-critique et <id>-info).")).small().weak());
                }
                _ => {}
            }
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                ui.label(tr("Envoyer"));
                for n in ["critique", "tout"] {
                    ui.radio_value(&mut f.niveau, n.to_string(), level_text(n));
                }
            });
            if !f.error.is_empty() {
                ui.colored_label(ERR, &f.error);
            }
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                if ui.add_enabled(!f.busy, egui::Button::new(RichText::new(tr("Tester et enregistrer")).color(Color32::WHITE)).fill(INFO)).clicked() {
                    save = true;
                }
                if ui.button(tr("Annuler")).clicked() {
                    close = true;
                }
                if f.busy {
                    ui.spinner();
                }
            });
        });
    if !open || close {
        return;
    }
    if find_chats {
        let tok = f.values.get("jeton").cloned().unwrap_or_default();
        if tok.trim().is_empty() {
            f.error = tr("Colle d'abord le jeton du bot.").into();
        } else {
            f.busy = true;
            f.error.clear();
            app.exec(
                HostId::Omv,
                tr("Conversations Telegram"),
                remote::telegram_chats(&tok),
                40,
                Box::new(|app, r| {
                    let Some(f) = app.notifs.form.as_mut() else { return };
                    f.busy = false;
                    match r {
                        Ok(o) if o.code == 0 => {
                            f.chats = o.stdout.lines().filter_map(|l| l.split_once('|')).map(|(a, b)| (a.trim().to_string(), b.trim().to_string())).collect();
                            if f.chats.len() == 1 {
                                f.values.insert("conversation".into(), f.chats[0].0.clone());
                            }
                        }
                        Ok(o) => f.error = o.text().lines().last().unwrap_or("").to_string(),
                        Err(e) => f.error = e.to_string(),
                    }
                }),
            );
        }
    }
    if save {
        match form_params(&f) {
            Err(e) => f.error = e.into(),
            Ok(p) if !app.blocked() => {
                f.busy = true;
                f.error.clear();
                let canal = f.canal.clone();
                app.exec(
                    HostId::Omv,
                    tr("Canal de notification"),
                    remote::canal_set(&f.canal, &f.niveau, &p),
                    90,
                    Box::new(move |app, r| {
                        match r {
                            Ok(o) if o.code == 0 => {
                                app.notifs.form = None;
                                app.toast(true, tf("Canal « {0} » enregistré : message de test envoyé.", &[&channel_label(&canal)]));
                            }
                            Ok(o) => {
                                let t = o.text();
                                let msg = t.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").replace("ERREUR : ", "");
                                if let Some(f) = app.notifs.form.as_mut() {
                                    f.busy = false;
                                    f.error = msg;
                                }
                            }
                            Err(e) => {
                                if let Some(f) = app.notifs.form.as_mut() {
                                    f.busy = false;
                                    f.error = e.to_string();
                                }
                            }
                        }
                        app.refresh(HostId::Omv);
                    }),
                );
            }
            Ok(_) => {}
        }
    }
    app.notifs.form = Some(f);
}

// ---------------------------------------------------------------------
//  Sante des disques
// ---------------------------------------------------------------------

fn state_color(etat: &str) -> Color32 {
    match etat {
        "ok" => OK,
        "attention" | "reconstruction" => WARN,
        "" => IDLE,
        _ => ERR,
    }
}

fn kind_text(k: &str) -> &'static str {
    match k {
        "nvme" => "SSD NVMe",
        "ssd" => "SSD",
        _ => tr("disque dur"),
    }
}

fn age_text(h: i64) -> String {
    if h >= 24 * 365 {
        tf("{0} ans de fonctionnement", &[&format!("{:.1}", h as f64 / (24.0 * 365.0)).replace('.', ",")])
    } else if h >= 24 * 30 {
        tf("{0} mois de fonctionnement", &[&(h / (24 * 30))])
    } else {
        tf("{0} h de fonctionnement", &[&h])
    }
}

fn disk_row(ui: &mut egui::Ui, d: &SmartDisk) {
    ui.horizontal(|ui| {
        crate::pages::dot_label_pub(
            ui,
            state_color(&d.etat),
            RichText::new(format!("{}  {}", d.dev.trim_start_matches("/dev/"), if d.modele.is_empty() { "?" } else { &d.modele })).strong(),
        );
        let mut info = vec![kind_text(&d.kind).to_string()];
        if let Some(t) = d.taille {
            info.push(fmt::bytes(t));
        }
        if let Some(t) = d.temp {
            info.push(format!("{t} °C"));
        }
        if let Some(h) = d.heures {
            info.push(age_text(h));
        }
        if let Some(u) = d.usure {
            info.push(tf("usure {0} %", &[&u]));
        }
        ui.label(RichText::new(info.join(" · ")).weak().small());
        if d.veille {
            ui.label(RichText::new(tr("en veille (dernières valeurs)")).small().color(IDLE));
        }
        if let Some(t) = d.temp {
            if t >= 55 {
                ui.label(RichText::new(tr("\u{E5C6} chaud")).small().color(WARN)).on_hover_text(tr("Au-delà de 55 °C, la durée de vie d'un disque dur baisse : vérifie l'aération du NAS."));
            }
        }
    });
    if !d.raisons.is_empty() {
        let col = state_color(&d.etat);
        ui.label(RichText::new(format!("      {}", d.raisons.join(" ; "))).small().color(col));
        if d.etat == "critique" {
            ui.label(RichText::new(tr("      Ce disque peut lâcher à tout moment : vérifie que les sauvegardes sont à jour et prévois son remplacement.")).small().color(ERR));
        }
    }
}

/// Bloc « santé des disques » d'une machine
pub fn disks_block(app: &mut App, ui: &mut egui::Ui, host: HostId, dh: Option<&DiskHealth>, now: i64) {
    let syno = host == HostId::Syno;
    ui.horizontal(|ui| {
        ui.label(RichText::new(host.label()).strong());
        if let Some(h) = dh {
            if h.verifie > 0 {
                ui.label(RichText::new(tf("vérifié {0}", &[&fmt::ago(h.verifie, now)])).small().weak());
            }
        }
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if ui.small_button(tr("\u{E30C} Vérifier maintenant")).clicked() {
                app.action_toast(host, tr("Santé des disques"), remote::disks_check(syno), 180);
            }
        });
    });
    let Some(h) = dh else {
        ui.label(RichText::new(tr("Pas encore vérifié (vérification automatique toutes les heures).")).weak().small());
        return;
    };
    if !h.smart {
        crate::pages::dot_label_pub(
            ui,
            WARN,
            RichText::new(if syno {
                tr("smartctl introuvable sur le Synology : l'état SMART des disques n'est pas lu.")
            } else {
                tr("smartctl n'est pas installé : installe les outils (page Installation) pour surveiller les disques.")
            })
            .small(),
        );
    } else if h.disques.is_empty() {
        ui.label(RichText::new(tr("Aucun disque lisible (machine virtuelle ou contrôleur sans SMART).")).weak().small());
    }
    for d in &h.disques {
        disk_row(ui, d);
    }
    for r in &h.raid {
        ui.horizontal(|ui| {
            let (txt, col) = match r.etat.as_str() {
                "ok" => (tr("complet"), OK),
                "reconstruction" => (tr("reconstruction en cours"), WARN),
                "arrete" => (tr("arrêté"), ERR),
                _ => (tr("DÉGRADÉ : plus de redondance"), ERR),
            };
            crate::pages::dot_label_pub(ui, col, RichText::new(format!("RAID {} ({})", r.nom, if r.kind.is_empty() { "?" } else { &r.kind })).strong());
            ui.label(RichText::new(txt).color(col).small());
            if !r.disques.is_empty() {
                ui.label(RichText::new(r.disques.join(", ")).weak().small());
            }
        });
        if let Some(p) = r.avancement {
            let op = match r.operation.as_deref() {
                Some("recovery") => tr("reconstruction"),
                Some("resync") => tr("synchronisation"),
                Some("reshape") => tr("réorganisation"),
                Some("check") => tr("vérification"),
                _ => "",
            };
            ui.add(egui::ProgressBar::new((p / 100.0) as f32).text(tf("{0} : {1} %", &[&op, &format!("{p:.1}")])).desired_width(320.0));
        }
        if !r.en_panne.is_empty() {
            ui.label(RichText::new(tf("      Disque(s) en panne : {0}", &[&r.en_panne.join(", ")])).small().color(ERR));
        }
    }
}

/// Ligne du tableau de bord : etat des disques des deux machines
pub fn dash_line(ui: &mut egui::Ui, omv: Option<&DiskHealth>, syno: Option<&DiskHealth>) {
    let hs: Vec<&DiskHealth> = [omv, syno].into_iter().flatten().filter(|h| h.verifie > 0).collect();
    if hs.is_empty() {
        return;
    }
    let (crit, att) = hs.iter().fold((0, 0), |(c, a), h| {
        let (x, y) = h.problems();
        (c + x, a + y)
    });
    let n: usize = hs.iter().map(|h| h.disques.len()).sum();
    if crit > 0 {
        crate::pages::dot_label_pub(ui, ERR, RichText::new(tf("\u{E2A0} Disques : {0} en danger", &[&crit])).small().strong());
    } else if att > 0 {
        crate::pages::dot_label_pub(ui, WARN, RichText::new(tf("\u{E2A0} Disques : {0} à surveiller", &[&att])).small());
    } else if n > 0 {
        crate::pages::dot_label_pub(ui, OK, RichText::new(tf("\u{E2A0} Disques : {0} OK", &[&n])).small());
    }
}

pub fn disks_card(app: &mut App, ui: &mut egui::Ui, omv: Option<&DiskHealth>, omv_ok: bool, syno: Option<&DiskHealth>, syno_ok: bool, now: i64) {
    crate::pages::card_pub(ui, tr("\u{E2A0} Santé des disques"), |ui| {
        ui.label(
            RichText::new(tr("Les disques préviennent souvent avant de lâcher (secteurs réalloués ou instables). Tu es alerté dès les premiers signes, et si un RAID perd sa redondance."))
                .small()
                .weak(),
        );
        ui.add_space(4.0);
        if omv_ok {
            disks_block(app, ui, HostId::Omv, omv, now);
        }
        if syno_ok {
            if omv_ok {
                ui.separator();
            }
            disks_block(app, ui, HostId::Syno, syno, now);
            ui.label(RichText::new(tr("Alertes du Synology : affichées ici, et envoyées par Home Assistant s'il est configuré sur le Synology.")).small().weak());
        }
        if !omv_ok && !syno_ok {
            ui.label(RichText::new(tr("Demande le script à jour : nas-debian 2.3 ou nas-synology 2.2 (ou plus).")).weak());
        }
    });
}

// ---------------------------------------------------------------------
//  Rapport periodique
// ---------------------------------------------------------------------

const DAYS: [&str; 7] = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"];

pub fn report_card(app: &mut App, ui: &mut egui::Ui, conf: &NotifConf) {
    crate::pages::card_pub(ui, tr("\u{E198} Rapport de la semaine ou du mois"), |ui| {
        ui.label(
            RichText::new(tr("Un résumé envoyé sur tes canaux : sauvegardes réussies ou non, espace des destinations, santé des disques, alertes de la période."))
                .small()
                .weak(),
        );
        let mut r = app.notifs.report.clone().unwrap_or_else(|| conf.rapport.clone());
        let mut changed = false;
        egui::Grid::new("rapgrid").num_columns(2).spacing([10.0, 6.0]).show(ui, |ui| {
            ui.label(tr("Fréquence"));
            ui.horizontal(|ui| {
                for (v, l) in [("non", tr("jamais")), ("hebdo", tr("chaque semaine")), ("mensuel", tr("chaque mois (le 1er)"))] {
                    changed |= ui.radio_value(&mut r.frequence, v.to_string(), l).changed();
                }
            });
            ui.end_row();
            if r.frequence != "non" {
                if r.frequence == "hebdo" {
                    ui.label(tr("Jour"));
                    let i = (r.jour.clamp(1, 7) - 1) as usize;
                    egui::ComboBox::from_id_salt("rapjour").selected_text(tr(DAYS[i])).show_ui(ui, |ui| {
                        for (n, d) in DAYS.iter().enumerate() {
                            changed |= ui.selectable_value(&mut r.jour, n as u32 + 1, tr(d)).changed();
                        }
                    });
                    ui.end_row();
                }
                ui.label(tr("Heure"));
                changed |= ui.add(egui::TextEdit::singleline(&mut r.heure).desired_width(60.0)).changed();
                ui.end_row();
                if conf.canaux.len() > 1 {
                    ui.label(tr("Canaux"));
                    ui.horizontal_wrapped(|ui| {
                        for id in conf.canaux.keys() {
                            let mut on = r.canaux.is_empty() || r.canaux.contains(id);
                            if ui.checkbox(&mut on, channel_label(id)).changed() {
                                if r.canaux.is_empty() {
                                    r.canaux = conf.canaux.keys().cloned().collect();
                                }
                                r.canaux.retain(|c| c != id);
                                if on {
                                    r.canaux.push(id.clone());
                                }
                                if r.canaux.len() == conf.canaux.len() {
                                    r.canaux.clear();
                                }
                                changed = true;
                            }
                        }
                    });
                    ui.end_row();
                }
            }
        });
        let dirty = app.notifs.report.is_some() || changed;
        let valid = r.heure.len() == 5 && r.heure.as_bytes()[2] == b':' && r.heure.chars().filter(|c| c.is_ascii_digit()).count() == 4;
        ui.horizontal(|ui| {
            if ui.add_enabled(dirty && valid, egui::Button::new(tr("Enregistrer"))).clicked() {
                app.action_toast(HostId::Omv, tr("Rapport"), remote::report_plan(&r.frequence, r.jour, &r.heure, &r.canaux), 30);
                app.notifs.report = None;
                return;
            }
            let freq = if r.frequence == "mensuel" { "mensuel" } else { "hebdo" };
            if ui.button(tr("\u{E220} Aperçu")).clicked() {
                let title = tr("Aperçu du rapport");
                app.exec(
                    HostId::Omv,
                    title,
                    remote::report_view(freq),
                    60,
                    Box::new(move |app, res| {
                        let (text, ok) = match res {
                            Ok(o) => (o.text(), o.code == 0),
                            Err(e) => (e.to_string(), false),
                        };
                        app.output = Some(OutputDialog { title: title.into(), text, ok });
                    }),
                );
            }
            if ui.add_enabled(!conf.canaux.is_empty(), egui::Button::new(tr("\u{E398} Envoyer maintenant"))).clicked() {
                app.action_toast(HostId::Omv, tr("Rapport"), remote::report_send(freq), 90);
            }
            if dirty && !valid {
                ui.colored_label(ERR, tr("Heure au format HH:MM"));
            }
        });
        if dirty {
            app.notifs.report = Some(r);
        }
    });
}

/// Reglages des alertes : rappel, seuil d'espace, retard
pub fn thresholds(app: &mut App, ui: &mut egui::Ui, conf: &NotifConf) {
    egui::CollapsingHeader::new(RichText::new(tr("\u{E432} Réglages des alertes")).strong()).id_salt("seuils").show(ui, |ui| {
        let mut t = app.notifs.thresholds.unwrap_or((conf.rappel_h, conf.quota_pct, conf.retard_h));
        egui::Grid::new("seuilgrid").num_columns(2).spacing([10.0, 6.0]).show(ui, |ui| {
            ui.label(tr("Rappel d'une alerte non résolue"));
            ui.add(egui::DragValue::new(&mut t.0).range(1..=168).suffix(" h"));
            ui.end_row();
            ui.label(tr("Destination presque pleine à partir de"));
            ui.add(egui::DragValue::new(&mut t.1).range(50..=100).suffix(" %"));
            ui.end_row();
            ui.label(tr("Sauvegarde en retard après"));
            ui.add(egui::DragValue::new(&mut t.2).range(6..=720).suffix(" h"));
            ui.end_row();
        });
        let dirty = t != (conf.rappel_h, conf.quota_pct, conf.retard_h);
        if ui.add_enabled(dirty, egui::Button::new(tr("Enregistrer"))).clicked() {
            app.action_toast(HostId::Omv, tr("Réglages des alertes"), remote::alert_thresholds(t.0, t.1, t.2), 30);
            app.notifs.thresholds = None;
        } else {
            app.notifs.thresholds = if dirty { Some(t) } else { None };
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sujet_ntfy() {
        let a = random_topic();
        assert!(a.starts_with("nas-") && a.len() == 16, "{a}");
        assert!(a.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'));
    }

    #[test]
    fn parametres() {
        let mut f = ChannelForm { canal: "ntfy".into(), niveau: "tout".into(), ..Default::default() };
        f.values.insert("url".into(), "https://ntfy.sh/nas-abcdefgh/".into());
        let p = form_params(&f).unwrap();
        assert_eq!(p[0], ("url", "https://ntfy.sh/nas-abcdefgh".to_string()));
        f.values.insert("url".into(), "https://ntfy.sh/ab".into());
        assert!(form_params(&f).is_err());
        let mut d = ChannelForm { canal: "discord".into(), ..Default::default() };
        d.values.insert("url".into(), "https://discord.com/x".into());
        assert!(form_params(&d).is_err());
        let s = remote::canal_set("email", "critique", &[("destinataire", "a@b.fr".into()), ("mot_de_passe", String::new())]);
        assert!(s.contains("alertes canal email critique") && s.contains("destinataire=a@b.fr\n") && !s.contains("mot_de_passe"), "{s}");
    }
}
