//! Page « Destinations » : où partent les sauvegardes (Google Drive, OneDrive, disque USB,
//! autre NAS, Backblaze B2...), règle 3-2-1, et kit de secours (tout ce qu'il faut pour
//! reconstruire si le NAS est perdu).

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::app::{App, BrowsePurpose, HostId, OutputDialog, Page};
use crate::fmt;
use crate::install::GoogleFlow;
use crate::model::{Destination, OmvStatus};
use crate::remote;
use crate::theme::{self, ERR, IDLE, INFO, OK, WARN};
use eframe::egui::{self, Color32, RichText};
use std::collections::BTreeMap;

// ---------------------------------------------------------------------
//  Types de destinations
// ---------------------------------------------------------------------

/// Champ d'un formulaire de destination : (cle rclone, libelle, secret, aide, choix)
pub struct Field {
    pub key: &'static str,
    pub label: &'static str,
    pub secret: bool,
    pub hint: &'static str,
    pub choices: &'static [(&'static str, &'static str)],
    pub required: bool,
}

pub struct Kind {
    pub kind: &'static str,
    pub label: &'static str,
    pub desc: &'static str,
    /// connexion par la page du service (navigateur)
    pub oauth: bool,
    /// hors de la maison (pour la regle 3-2-1)
    pub offsite: bool,
    pub fields: &'static [Field],
}

const fn f(key: &'static str, label: &'static str, secret: bool, hint: &'static str, required: bool) -> Field {
    Field { key, label, secret, hint, choices: &[], required }
}

pub const KINDS: &[Kind] = &[
    Kind { kind: "drive", label: "Google Drive", desc: "Compte Google (connexion dans le navigateur).", oauth: true, offsite: true, fields: &[] },
    Kind { kind: "onedrive", label: "OneDrive", desc: "Compte Microsoft personnel ou professionnel (connexion dans le navigateur).", oauth: true, offsite: true, fields: &[] },
    Kind { kind: "dropbox", label: "Dropbox", desc: "Compte Dropbox (connexion dans le navigateur).", oauth: true, offsite: true, fields: &[] },
    Kind { kind: "pcloud", label: "pCloud", desc: "Compte pCloud (connexion dans le navigateur).", oauth: true, offsite: true, fields: &[] },
    Kind { kind: "box", label: "Box", desc: "Compte Box (connexion dans le navigateur).", oauth: true, offsite: true, fields: &[] },
    Kind {
        kind: "local",
        label: "Disque local ou USB",
        desc: "Un dossier sur un autre disque de la machine (disque USB branché sur le NAS, second disque).",
        oauth: false,
        offsite: false,
        fields: &[f("chemin", "Dossier", false, "/srv/dev-disk-by-uuid-…/Sauvegardes  ·  /media/usb/Sauvegardes", true)],
    },
    Kind {
        kind: "sftp",
        label: "Autre NAS ou serveur (SFTP)",
        desc: "Un autre NAS (chez un proche, au bureau…) joignable en SSH / SFTP.",
        oauth: false,
        offsite: true,
        fields: &[
            f("host", "Adresse", false, "192.168.1.50  ·  nas.exemple.fr  ·  100.x.y.z (Tailscale)", true),
            f("port", "Port", false, "22", false),
            f("user", "Utilisateur", false, "", true),
            f("pass", "Mot de passe", true, "", true),
            f("dossier", "Dossier sur le serveur", false, "/volume1/Sauvegardes (facultatif)", false),
        ],
    },
    Kind {
        kind: "smb",
        label: "Partage réseau (SMB)",
        desc: "Un dossier partagé d'un autre NAS ou d'un PC Windows du réseau.",
        oauth: false,
        offsite: false,
        fields: &[
            f("host", "Adresse", false, "192.168.1.50", true),
            f("user", "Utilisateur", false, "", true),
            f("pass", "Mot de passe", true, "", true),
            f("dossier", "Partage (et dossier)", false, "Sauvegardes  ·  Partage/NAS", true),
        ],
    },
    Kind {
        kind: "webdav",
        label: "WebDAV (Nextcloud, ownCloud, oCIS)",
        desc: "Un serveur WebDAV : Nextcloud, ownCloud, oCIS, ou un autre NAS.",
        oauth: false,
        offsite: true,
        fields: &[
            f("url", "Adresse WebDAV", false, "https://cloud.exemple.fr/remote.php/dav/files/moi", true),
            Field { key: "vendor", label: "Serveur", secret: false, hint: "", choices: &[("nextcloud", "Nextcloud"), ("owncloud", "ownCloud / oCIS"), ("other", "Autre")], required: true },
            f("user", "Utilisateur", false, "", true),
            f("pass", "Mot de passe (ou jeton d'application)", true, "", true),
        ],
    },
    Kind {
        kind: "b2",
        label: "Backblaze B2",
        desc: "Stockage en ligne à bas prix, facturé au volume.",
        oauth: false,
        offsite: true,
        fields: &[
            f("account", "keyID", false, "", true),
            f("key", "applicationKey", true, "", true),
            f("dossier", "Bucket (et dossier)", false, "mon-bucket  ·  mon-bucket/NAS", true),
        ],
    },
    Kind {
        kind: "s3",
        label: "S3 (Wasabi, Scaleway, AWS, MinIO…)",
        desc: "Stockage objet compatible S3.",
        oauth: false,
        offsite: true,
        fields: &[
            Field {
                key: "provider",
                label: "Fournisseur",
                secret: false,
                hint: "",
                choices: &[("AWS", "Amazon S3"), ("Wasabi", "Wasabi"), ("Scaleway", "Scaleway"), ("IDrive", "IDrive e2"), ("Minio", "MinIO"), ("Other", "Autre")],
                required: true,
            },
            f("access_key_id", "Clé d'accès", false, "", true),
            f("secret_access_key", "Clé secrète", true, "", true),
            f("region", "Région", false, "eu-west-3 (facultatif)", false),
            f("endpoint", "Adresse (endpoint)", false, "s3.fr-par.scw.cloud (sauf AWS)", false),
            f("dossier", "Bucket (et dossier)", false, "mon-bucket  ·  mon-bucket/NAS", true),
        ],
    },
];

pub fn kind_of(k: &str) -> Option<&'static Kind> {
    KINDS.iter().find(|x| x.kind == k)
}

pub fn kind_label(k: &str) -> &'static str {
    kind_of(k).map(|x| tr(x.label)).unwrap_or_else(|| tr("Autre"))
}

// ---------------------------------------------------------------------
//  Aides pour le formulaire de sauvegarde
// ---------------------------------------------------------------------

/// Destinations disponibles (script ancien : Google Drive seul)
pub fn available(app: &App) -> Vec<Destination> {
    let v = app.omv.status.as_ref().map(|s| s.destinations.clone()).unwrap_or_default();
    if v.is_empty() {
        vec![Destination { nom: "gdrive".into(), kind: "drive".into(), libelle: "Google Drive".into(), ..Default::default() }]
    } else {
        v
    }
}

/// Libelle court d'une destination : « Google Drive », « usb (Disque local ou USB) »
pub fn short_label(nom: &str, avail: &[Destination]) -> String {
    match avail.iter().find(|d| d.nom == nom) {
        Some(d) if d.nom == "gdrive" && d.kind == "drive" => "Google Drive".into(),
        Some(d) => format!("{} ({})", d.nom, kind_label(&d.kind)),
        None => nom.to_string(),
    }
}

/// Choix des destinations d'une sauvegarde ; renvoie true pour « Ajouter une destination »
pub fn job_dests_ui(ui: &mut egui::Ui, sel: &mut Vec<(String, bool)>, avail: &[Destination], versions: bool, multi: bool) -> bool {
    let mut add = false;
    let mut order: Vec<&Destination> = sel.iter().filter_map(|(n, _)| avail.iter().find(|d| &d.nom == n)).collect();
    for d in avail {
        if !order.iter().any(|o| o.nom == d.nom) {
            order.push(d);
        }
    }
    for d in order {
        let pos = sel.iter().position(|(n, _)| *n == d.nom);
        ui.horizontal(|ui| {
            let mut on = pos.is_some();
            let lab = short_label(&d.nom, avail);
            let resp = ui.add_enabled(multi || on || sel.is_empty(), egui::Checkbox::new(&mut on, lab));
            if !d.cible.is_empty() {
                resp.on_hover_text(&d.cible);
            }
            if on && pos.is_none() {
                sel.push((d.nom.clone(), true));
            } else if !on {
                if let Some(i) = pos {
                    sel.remove(i);
                }
            }
            if let Some(i) = sel.iter().position(|(n, _)| *n == d.nom) {
                if versions {
                    ui.label(RichText::new(tr("\u{E2FA} toujours chiffrée")).small().weak());
                } else {
                    ui.checkbox(&mut sel[i].1, tr("chiffrer"));
                }
                if i == 0 && sel.len() > 1 {
                    ui.label(RichText::new(tr("(principale)")).small().weak());
                }
            }
            if let Some(st) = &d.etat {
                if !st.ok {
                    ui.label(RichText::new(tr("injoignable")).small().color(ERR));
                }
            }
        });
    }
    if !multi {
        ui.label(RichText::new(tr("Plusieurs destinations : mets d'abord à jour le script nas-debian.")).small().weak());
    } else {
        ui.horizontal(|ui| {
            if ui.small_button(tr("+ Ajouter une destination…")).clicked() {
                add = true;
            }
            ui.label(RichText::new(tr("Envoyée vers chacune, l'une après l'autre (règle 3-2-1).")).small().weak());
        });
    }
    add
}

/// « remote:oui;remote2:non »
pub fn dests_build(sel: &[(String, bool)], versions: bool) -> String {
    sel.iter().map(|(n, e)| format!("{n}:{}", if *e || versions { "oui" } else { "non" })).collect::<Vec<_>>().join(";")
}

/// Versions gardees « J:S:M:A » -> 4 champs (defaut 7:4:12:0)
pub fn rot_parse(s: &str) -> [String; 4] {
    let p: Vec<&str> = s.split(':').collect();
    if p.len() == 4 && p.iter().all(|x| x.parse::<u32>().is_ok()) {
        [p[0].into(), p[1].into(), p[2].into(), p[3].into()]
    } else {
        ["7".into(), "4".into(), "12".into(), "0".into()]
    }
}

pub fn rot_build(r: &[String; 4]) -> Option<String> {
    let v: Vec<u32> = r.iter().map(|x| x.trim().parse::<u32>().ok()).collect::<Option<Vec<_>>>()?;
    if v.iter().all(|x| *x == 0) || v[0] > 999 || v[1] > 999 || v[2] > 999 || v[3] > 99 {
        return None;
    }
    Some(v.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(":"))
}

pub fn rot_human(s: &str) -> String {
    let r = rot_parse(s);
    let mut parts = Vec::new();
    for (v, one) in r.iter().zip([tr("{0} quotidienne(s)"), tr("{0} hebdomadaire(s)"), tr("{0} mensuelle(s)"), tr("{0} annuelle(s)")]) {
        if v != "0" {
            parts.push(tf(one, &[v]));
        }
    }
    parts.join(", ")
}

const PRESETS: &[(&str, &str)] = &[
    ("7:4:12:0", "Standard : 7 jours, 4 semaines, 12 mois"),
    ("14:8:24:5", "Longue : 14 jours, 8 semaines, 24 mois, 5 ans"),
    ("7:4:0:0", "Courte : 7 jours, 4 semaines"),
    ("30:0:0:0", "30 derniers jours"),
];

pub fn rot_ui(ui: &mut egui::Ui, r: &mut [String; 4]) {
    ui.vertical(|ui| {
        let cur = rot_build(r).unwrap_or_default();
        let sel = PRESETS.iter().find(|(v, _)| *v == cur).map(|(_, l)| tr(l)).unwrap_or_else(|| tr("Personnalisé"));
        egui::ComboBox::from_id_salt("rotpreset").width(320.0).selected_text(sel).show_ui(ui, |ui| {
            for (v, l) in PRESETS {
                if ui.selectable_label(cur == *v, tr(l)).clicked() {
                    *r = rot_parse(v);
                }
            }
        });
        ui.horizontal(|ui| {
            for (i, l) in [tr("jours"), tr("semaines"), tr("mois"), tr("années")].iter().enumerate() {
                ui.add(egui::TextEdit::singleline(&mut r[i]).desired_width(40.0));
                ui.label(*l);
            }
        });
        ui.label(
            RichText::new(tr("Comme Smart Recycle : toutes les versions des dernières 24 h, puis la dernière de chaque jour, semaine, mois et année. Le nettoyage des versions oubliées a lieu le dimanche matin."))
                .small()
                .weak(),
        );
    });
}

/// Destinations d'une sauvegarde, lisibles
pub fn job_dests_text(j: &crate::model::Job, avail: &[Destination]) -> String {
    j.dests()
        .iter()
        .map(|d| {
            let n = short_label(&d.nom, avail);
            if d.chiffre && !j.versions() {
                tf("{0} (chiffré)", &[&n])
            } else {
                n
            }
        })
        .collect::<Vec<_>>()
        .join(" + ")
}

/// Remote d'une destination de sauvegarde temps reel (remotes chiffres ramenes a leur destination)
pub fn rt_remote(dest: &str) -> String {
    let r = dest.split(':').next().unwrap_or("");
    match r {
        "gbackup" | "gcrypt" => "gdrive".into(),
        _ => r.strip_suffix("-chiffre").unwrap_or(r).to_string(),
    }
}

/// Sauvegardes (programmees et temps reel) qui utilisent une destination
pub fn users_of(s: &OmvStatus, nom: &str) -> Vec<String> {
    let mut v: Vec<String> = s.sauvegardes.iter().filter(|j| j.dests().iter().any(|d| d.nom == nom)).map(|j| j.nom.clone()).collect();
    for j in &s.temps_reel {
        if rt_remote(&j.destination) == nom {
            v.push(tf("{0} (temps réel)", &[&j.nom]));
        }
    }
    v
}

// ---------------------------------------------------------------------
//  Etat de la page
// ---------------------------------------------------------------------

#[derive(Default)]
pub struct DestUi {
    pub form: Option<DestForm>,
    /// connexion par le navigateur en cours (nom de la destination, etapes)
    pub oauth: Option<(String, GoogleFlow)>,
    pub kit_busy: bool,
    pub kit_restore: KitRestore,
}

#[derive(Clone, Default)]
pub struct DestForm {
    pub kind: String,
    pub name: String,
    pub values: BTreeMap<String, String>,
    pub system_ok: bool,
    pub error: String,
}

#[derive(Clone, Default)]
pub struct KitRestore {
    pub file: String,
    pub bytes: Option<Vec<u8>>,
    pub pass: String,
    pub crypt: String,
    pub salt: String,
    pub versions: String,
}

fn default_name(kind: &str, s: Option<&OmvStatus>) -> String {
    let base = match kind {
        "drive" => "gdrive",
        "local" => "usb",
        "sftp" => "nas2",
        "smb" => "partage",
        k => k,
    };
    let taken = |n: &str| s.map(|s| s.destinations.iter().any(|d| d.nom == n)).unwrap_or(false);
    if !taken(base) {
        return base.into();
    }
    (2..100).map(|i| format!("{base}{i}")).find(|n| !taken(n)).unwrap_or_else(|| base.into())
}

fn valid_name(n: &str) -> bool {
    let mut c = n.chars();
    matches!(c.next(), Some(x) if x.is_ascii_alphabetic()) && n.len() <= 30 && n.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') && !["gbackup", "gcrypt", "rclone", "NAS"].contains(&n)
}

// ---------------------------------------------------------------------
//  Page
// ---------------------------------------------------------------------

pub fn page(app: &mut App, ui: &mut egui::Ui) {
    crate::pages::page_title_pub(ui, tr("Destinations"), tr("Où partent les sauvegardes : clouds, disques USB, autres NAS — et le kit de secours"));
    if !crate::pages::host_banner_pub(app, ui, HostId::Omv) {
        return;
    }
    let s = app.omv.status.clone().unwrap();
    if !s.nb_installe || s.nb_api < 7 {
        crate::pages::info_banner(ui, tr("Les destinations demandent le script nas-debian à jour sur la machine (version 2.2 ou plus)."));
        crate::scripts::widget(app, ui, crate::scripts::Kind::Debian);
        return;
    }
    let now = s.maintenant.max(fmt::now());
    rule_321(ui, &s);
    ui.add_space(6.0);
    ui.horizontal(|ui| {
        if ui.add(egui::Button::new(RichText::new(tr("+ Ajouter une destination")).color(Color32::WHITE)).fill(INFO)).clicked() {
            app.dests.form = Some(DestForm::default());
        }
        if ui.button(tr("\u{E30C} Tout tester")).on_hover_text(tr("Connexion et espace libre de chaque destination")).clicked() {
            app.action_toast(HostId::Omv, tr("Test des destinations"), format!("{} destinations etat >/dev/null 2>&1; echo 'Destinations testées.'\n", remote::DEBIAN_BIN), 600);
        }
    });
    if let Some((n, g)) = app.dests.oauth.clone() {
        oauth_box(ui, &n, &g);
    }
    ui.add_space(6.0);
    if s.destinations.is_empty() {
        crate::pages::card_pub(ui, "", |ui| {
            ui.label(tr("Aucune destination. Commence par Google Drive (page Installation) ou ajoute-en une ici."));
        });
    }
    for d in &s.destinations {
        dest_card(app, ui, d, &s, now);
        ui.add_space(8.0);
    }
    ui.add_space(4.0);
    kit_card(app, ui, &s, now);
}

/// Bilan de la regle 3-2-1 : copies hors de la maison, sauvegardes avec une seule destination
fn rule_321(ui: &mut egui::Ui, s: &OmvStatus) {
    let offsite = |n: &str| s.destinations.iter().find(|d| d.nom == n).map(|d| kind_of(&d.kind).map(|k| k.offsite).unwrap_or(true)).unwrap_or(true);
    let single: Vec<&str> = s.sauvegardes.iter().filter(|j| j.dests().len() < 2).map(|j| j.nom.as_str()).collect();
    let no_off: Vec<&str> = s.sauvegardes.iter().filter(|j| !j.dests().iter().any(|d| offsite(&d.nom))).map(|j| j.nom.as_str()).collect();
    theme::card_frame(ui).show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.label(RichText::new(tr("Règle 3-2-1")).strong());
        ui.label(RichText::new(tr("3 copies des données (le NAS + 2 sauvegardes), sur 2 supports différents, dont 1 hors de la maison (cloud, NAS d'un proche).")).small());
        if s.sauvegardes.is_empty() {
            return;
        }
        if single.is_empty() && no_off.is_empty() {
            crate::pages::dot_label_pub(ui, OK, RichText::new(tr("Toutes les sauvegardes programmées ont au moins deux destinations, dont une hors de la maison.")).small());
        } else {
            if !single.is_empty() {
                crate::pages::dot_label_pub(ui, WARN, RichText::new(tf("Une seule destination : {0}", &[&(single.join(", "))])).small());
            }
            if !no_off.is_empty() {
                crate::pages::dot_label_pub(ui, WARN, RichText::new(tf("Aucune copie hors de la maison : {0}", &[&(no_off.join(", "))])).small());
            }
        }
    });
}

fn dest_card(app: &mut App, ui: &mut egui::Ui, d: &Destination, s: &OmvStatus, now: i64) {
    let users = users_of(s, &d.nom);
    let (col, st) = match &d.etat {
        Some(e) if e.ok => (OK, tr("Joignable")),
        Some(_) => (ERR, tr("Injoignable")),
        None => (IDLE, tr("Pas encore testée")),
    };
    theme::card_frame(ui).show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.horizontal(|ui| {
            ui.label(RichText::new("●").color(col));
            ui.label(RichText::new(&d.nom).strong().size(16.0));
            crate::pages::badge_pub(ui, kind_label(&d.kind), IDLE);
            crate::pages::badge_pub(ui, st, col);
            if kind_of(&d.kind).map(|k| !k.offsite).unwrap_or(false) {
                crate::pages::badge_pub(ui, tr("à la maison"), IDLE);
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let n = d.nom.clone();
                if ui
                    .add_enabled(users.is_empty(), egui::Button::new(tr("\u{E4A6} Retirer…")))
                    .on_disabled_hover_text(tr("Utilisée par des sauvegardes : retire-la d'abord de ces sauvegardes."))
                    .clicked()
                {
                    app.ask_confirm(
                        tr("Retirer la destination"),
                        &tf("La destination « {0} » est retirée de la machine. Les fichiers déjà envoyés restent sur place.", &[&n]),
                        tr("Retirer"),
                        true,
                        None,
                        Box::new(move |app| app.action_dialog(HostId::Omv, tr("Retrait de la destination"), remote::dest_delete(&n), 60)),
                    );
                }
                if kind_of(&d.kind).map(|k| k.oauth).unwrap_or(false) && ui.button(tr("\u{E2D6} Reconnecter")).clicked() {
                    start_oauth(app, &d.nom, &d.kind);
                }
                if ui.button(tr("\u{E30C} Tester")).clicked() {
                    app.action_toast(HostId::Omv, tr("Test de la destination"), remote::dest_check(&d.nom) + "echo 'Test terminé.'\n", 300);
                }
            });
        });
        if !d.cible.is_empty() {
            ui.label(RichText::new(&d.cible).color(ui.visuals().strong_text_color()));
        }
        if let Some(e) = &d.etat {
            if let (Some(t), Some(u)) = (e.total, e.utilise) {
                if t > 0 {
                    let fr = u as f32 / t as f32;
                    let c = if fr > 0.9 { ERR } else if fr > 0.75 { WARN } else { OK };
                    ui.add(egui::ProgressBar::new(fr).fill(c).text(tf("{0} utilisés sur {1} · {2} libres", &[&(fmt::bytes(u)), &(fmt::bytes(t)), &(fmt::bytes(e.libre.unwrap_or(t.saturating_sub(u))))])));
                }
            }
            if let Some(err) = &e.erreur {
                crate::explain::show(ui, err);
            }
            ui.label(RichText::new(tf("Testée {0}", &[&(fmt::ago(e.verifie, now))])).small().weak());
        }
        ui.label(
            RichText::new(if users.is_empty() { tr("Utilisée par aucune sauvegarde.").to_string() } else { tf("Utilisée par : {0}", &[&(users.join(", "))]) })
                .small(),
        );
        crate::fiabilite::dest_line(app, ui, d, s);
    });
}

fn oauth_box(ui: &mut egui::Ui, name: &str, g: &GoogleFlow) {
    egui::Frame::new().fill(INFO.gamma_multiply(0.12)).corner_radius(6).inner_margin(10).show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.horizontal(|ui| {
            if !g.done {
                ui.spinner();
            }
            ui.label(RichText::new(tf("Connexion de « {0} »", &[&name])).strong());
        });
        if !g.step.is_empty() {
            ui.label(&g.step);
        }
        if !g.url.is_empty() && !g.done {
            ui.horizontal(|ui| {
                ui.label(RichText::new(tr("Si le navigateur ne s'est pas ouvert :")).small());
                if ui.small_button(tr("Ouvrir la page")).clicked() {
                    crate::install::open_url(&g.url);
                }
                if ui.small_button(tr("\u{E1CA} Copier l'adresse")).clicked() {
                    ui.ctx().copy_text(g.url.clone());
                }
            });
        }
        if !g.error.is_empty() {
            ui.colored_label(ERR, &g.error);
        }
    });
}

fn dest_step(app: &mut App, f: &dyn Fn(&mut GoogleFlow)) {
    if let Some((_, g)) = &mut app.dests.oauth {
        f(g);
    }
}

/// Connexion d'un service par le navigateur : jeton obtenu par `rclone authorize`, puis
/// enregistre sur la machine (`destinations jeton`)
pub fn start_oauth(app: &mut App, name: &str, kind: &str) {
    if app.blocked() {
        return;
    }
    if app.dests.oauth.as_ref().map(|(_, g)| !g.done).unwrap_or(false) {
        app.toast(false, tr("Une connexion est déjà en cours.").into());
        return;
    }
    if name == "gdrive" && kind == "drive" {
        app.page = Page::Install;
        crate::install::start_google(app);
        return;
    }
    let (cfg, pass, ssh, tx, ctx) = (app.settings.omv.clone(), app.omv.pass.clone(), app.ssh.clone(), app.tx.clone(), app.ctx.clone());
    let (name, kind) = (name.to_string(), kind.to_string());
    app.dests.oauth = Some((name.clone(), GoogleFlow { step: tr("Préparation de la connexion…").into(), ..Default::default() }));
    crate::log::info(&format!("connexion de la destination {name} ({kind}) : début"));
    let send = move |h: crate::app::Handler| {
        let _ = tx.send(crate::app::Msg::Done(h, Err(crate::ssh::SshError::Other(String::new()))));
        ctx.request_repaint();
    };
    std::thread::spawn(move || {
        let res = crate::install::oauth_token(&ssh, &cfg, pass.as_deref(), &kind, &send, &dest_step).and_then(|token| {
            send(Box::new(|app: &mut App, _| dest_step(app, &|g: &mut GoogleFlow| g.step = tr("Enregistrement sur la machine…").into())));
            let o = ssh.run(&cfg, pass.as_deref(), &remote::dest_token(&name, &kind, &token), std::time::Duration::from_secs(180)).map_err(|e| e.to_string())?;
            if o.code == 0 {
                Ok(o.text())
            } else {
                Err(o.text())
            }
        });
        send(Box::new(move |app: &mut App, _| {
            match res {
                Ok(msg) => {
                    crate::log::info("connexion de la destination : terminée");
                    dest_step(app, &|g: &mut GoogleFlow| {
                        g.done = true;
                        g.step = tr("Connectée.").into();
                    });
                    app.output = Some(OutputDialog { title: tr("Destination connectée").into(), text: msg, ok: true });
                }
                Err(e) => {
                    crate::log::error(&format!("connexion de la destination : {e}"));
                    dest_step(app, &|g: &mut GoogleFlow| {
                        g.done = true;
                        g.error = e.clone();
                        g.step.clear();
                    });
                }
            }
            app.refresh(HostId::Omv);
        }));
    });
}

// ---------------------------------------------------------------------
//  Formulaire « Ajouter une destination »
// ---------------------------------------------------------------------

pub fn form_window(app: &mut App, ctx: &egui::Context) {
    let Some(mut f) = app.dests.form.take() else { return };
    let mut open = true;
    let mut save = false;
    let mut cancel = false;
    let mut browse = false;
    let status = app.omv.status.clone();
    egui::Window::new(RichText::new(tr("Ajouter une destination")).strong())
        .id(egui::Id::unique("destform"))
        .collapsible(false)
        .resizable(false)
        .default_width(620.0)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            egui::ScrollArea::vertical().max_height((ctx.content_rect().height() - 160.0).max(200.0)).show(ui, |ui| {
                if f.kind.is_empty() {
                    ui.label(tr("Où envoyer les sauvegardes ?"));
                    ui.add_space(4.0);
                    for k in KINDS {
                        let r = ui.add(egui::Button::new(RichText::new(tr(k.label)).strong()).min_size(egui::vec2(ui.available_width(), 0.0)));
                        ui.label(RichText::new(tr(k.desc)).small().weak());
                        if r.clicked() {
                            f.kind = k.kind.into();
                            f.name = default_name(k.kind, status.as_ref());
                            for fl in k.fields {
                                if let Some((v, _)) = fl.choices.first() {
                                    f.values.insert(fl.key.into(), (*v).into());
                                }
                            }
                        }
                        ui.add_space(2.0);
                    }
                    return;
                }
                let Some(k) = kind_of(&f.kind) else { return };
                ui.horizontal(|ui| {
                    if ui.small_button("←").on_hover_text(tr("Changer de type")).clicked() {
                        f.kind.clear();
                        f.values.clear();
                    }
                    ui.label(RichText::new(tr(k.label)).strong());
                });
                ui.label(RichText::new(tr(k.desc)).small().weak());
                ui.add_space(4.0);
                egui::Grid::new("destgrid").num_columns(2).spacing([12.0, 8.0]).show(ui, |ui| {
                    ui.label(tr("Nom"));
                    ui.vertical(|ui| {
                        ui.add(egui::TextEdit::singleline(&mut f.name).desired_width(200.0));
                        ui.label(RichText::new(tr("Lettres, chiffres et _ (ex. usb, onedrive, nas_papa).")).small().weak());
                    });
                    ui.end_row();
                    for fl in k.fields {
                        ui.label(tr(fl.label));
                        let v = f.values.entry(fl.key.to_string()).or_default();
                        if !fl.choices.is_empty() {
                            let cur = fl.choices.iter().find(|(c, _)| *c == v.as_str()).map(|(_, l)| tr(l)).unwrap_or("");
                            egui::ComboBox::from_id_salt(fl.key).selected_text(cur).show_ui(ui, |ui| {
                                for (c, l) in fl.choices {
                                    ui.selectable_value(v, c.to_string(), tr(l));
                                }
                            });
                        } else {
                            ui.horizontal(|ui| {
                                ui.add(egui::TextEdit::singleline(v).password(fl.secret).hint_text(fl.hint).desired_width(320.0));
                                if fl.key == "chemin" && ui.button("\u{E24A}").on_hover_text(tr("Parcourir les disques de la machine")).clicked() {
                                    browse = true;
                                }
                            });
                        }
                        ui.end_row();
                    }
                });
                if k.kind == "local" {
                    ui.checkbox(&mut f.system_ok, tr("Accepter un dossier du disque système (déconseillé : ce n'est pas un second support)"));
                    ui.label(RichText::new(tr("Si le disque est débranché, les sauvegardes vers lui échouent (rien n'est écrit ailleurs).")).small().weak());
                }
                if k.oauth {
                    ui.label(tr("La page de connexion du service s'ouvre dans ton navigateur ; l'autorisation est transmise à la machine par la connexion SSH (rien à copier)."));
                }
                if !f.error.is_empty() {
                    ui.colored_label(ERR, &f.error);
                }
            });
            if f.kind.is_empty() {
                return;
            }
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                let lab = if kind_of(&f.kind).map(|k| k.oauth).unwrap_or(false) { tr("\u{E2D6} Se connecter…") } else { tr("Tester et ajouter") };
                if ui.add(egui::Button::new(RichText::new(lab).color(Color32::WHITE)).fill(INFO)).clicked() {
                    save = true;
                }
                if ui.button(tr("Annuler")).clicked() {
                    cancel = true;
                }
            });
        });
    if browse {
        let start = f.values.get("chemin").cloned().unwrap_or_default();
        let start = start.rsplit_once('/').map(|(a, _)| a.to_string()).unwrap_or_default();
        app.dests.form = Some(f);
        app.open_browser(HostId::Omv, BrowsePurpose::DestPath, &start);
        return;
    }
    if !open || cancel {
        return;
    }
    if save {
        let Some(k) = kind_of(&f.kind) else { return };
        let name = f.name.trim().to_string();
        let taken = status.as_ref().map(|s| s.destinations.iter().any(|d| d.nom == name)).unwrap_or(false);
        let missing = k.fields.iter().find(|fl| fl.required && f.values.get(fl.key).map(|v| v.trim().is_empty()).unwrap_or(true));
        f.error = if !valid_name(&name) {
            tr("Nom invalide : lettres, chiffres et _, commence par une lettre (30 au plus).").into()
        } else if taken {
            tr("Ce nom est déjà utilisé par une autre destination.").into()
        } else if let Some(fl) = missing {
            tf("À remplir : {0}", &[&tr(fl.label)])
        } else {
            String::new()
        };
        if !f.error.is_empty() {
            app.dests.form = Some(f);
            return;
        }
        if k.oauth {
            start_oauth(app, &name, k.kind);
            return;
        }
        let mut params: Vec<(String, String)> = f.values.iter().map(|(a, b)| (a.clone(), b.trim().to_string())).collect();
        if k.kind == "local" && f.system_ok {
            params.push(("systeme".into(), "oui".into()));
        }
        app.action_dialog(HostId::Omv, tr("Nouvelle destination"), remote::dest_create(&name, k.kind, &params), 300);
        return;
    }
    app.dests.form = Some(f);
}

// ---------------------------------------------------------------------
//  Kit de secours
// ---------------------------------------------------------------------

fn kit_dir(app: &App) -> std::path::PathBuf {
    let site: String = app.settings.site.chars().map(|c| if c.is_alphanumeric() || c == '-' || c == '_' { c } else { '_' }).collect();
    crate::config::app_dir().join("secours").join(if site.is_empty() { "site".into() } else { site })
}

/// Empreinte du kit deja copie sur ce PC
fn kit_pc(app: &App) -> Option<(String, i64)> {
    let d = kit_dir(app);
    let h = std::fs::read_to_string(d.join("empreinte.txt")).ok()?;
    let t = std::fs::metadata(d.join("empreinte.txt")).ok()?.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs() as i64;
    Some((h.trim().to_string(), t))
}

/// Telecharge le kit ; `save_as` : choisir ou l'enregistrer, sinon copie automatique sur le PC
pub fn kit_download(app: &mut App, save_as: bool) {
    if app.dests.kit_busy {
        return;
    }
    app.dests.kit_busy = true;
    let dir = kit_dir(app);
    app.exec(
        HostId::Omv,
        tr("Téléchargement du kit de secours"),
        remote::secours_download(),
        300,
        Box::new(move |app, r| {
            app.dests.kit_busy = false;
            let o = match r {
                Ok(o) if o.code == 0 => o,
                Ok(o) => return app.toast(false, o.text()),
                Err(e) => return app.toast(false, e.to_string()),
            };
            let mut lines = o.stdout.lines();
            let head = lines.next().unwrap_or("");
            let hash = head.split_whitespace().find_map(|w| w.strip_prefix("EMPREINTE=")).unwrap_or("").to_string();
            let name = head.split_whitespace().find_map(|w| w.strip_prefix("NOM=")).unwrap_or("kit-secours.tar.gz.enc").to_string();
            use base64::Engine;
            let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(lines.next().unwrap_or("").trim()) else {
                return app.toast(false, tr("Kit de secours illisible.").into());
            };
            if save_as {
                if let Some(path) = rfd::FileDialog::new().set_file_name(&name).save_file() {
                    match std::fs::write(&path, &bytes) {
                        Ok(()) => app.toast(true, tf("Kit enregistré : {0}", &[&(path.display())])),
                        Err(e) => app.toast(false, e.to_string()),
                    }
                }
                return;
            }
            let res = (|| -> std::io::Result<()> {
                std::fs::create_dir_all(&dir)?;
                let p = dir.join(&name);
                if p.exists() {
                    let _ = std::fs::rename(&p, dir.join(format!("{name}.precedent")));
                }
                std::fs::write(&p, &bytes)?;
                std::fs::write(dir.join("empreinte.txt"), &hash)
            })();
            match res {
                Ok(()) => crate::log::info(&format!("kit de secours copié sur le PC ({})", dir.display())),
                Err(e) => crate::log::error(&format!("copie du kit de secours sur le PC : {e}")),
            }
        }),
    );
}

/// Copie automatique du kit sur le PC quand il a change sur la machine
pub fn auto_kit(app: &mut App) {
    if !app.settings.kit_pc || app.dests.kit_busy || app.settings.read_only {
        return;
    }
    let Some(h) = app.omv.status.as_ref().and_then(|s| s.secours.as_ref()).and_then(|k| k.empreinte.clone()) else { return };
    if h.is_empty() || kit_pc(app).map(|(p, _)| p == h).unwrap_or(false) {
        return;
    }
    static LAST: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(0);
    let now = fmt::now();
    if now - LAST.load(std::sync::atomic::Ordering::Relaxed) < 600 {
        return;
    }
    LAST.store(now, std::sync::atomic::Ordering::Relaxed);
    kit_download(app, false);
}

fn kit_card(app: &mut App, ui: &mut egui::Ui, s: &OmvStatus, now: i64) {
    crate::pages::card_pub(ui, tr("\u{E594} Kit de secours"), |ui| {
        ui.label(tr("Tout ce qu'il faut pour reconstruire si le NAS est perdu : connexions aux destinations, mots de passe de chiffrement, liste des sauvegardes et réglages. Chiffré avec le mot de passe du kit, envoyé chaque jour (s'il a changé) dans le dossier NAS-secours de chaque destination, et copié sur ce PC."));
        if !app.settings.kit_noted {
            ui.add_space(4.0);
            egui::Frame::new().fill(WARN.gamma_multiply(0.15)).corner_radius(6).inner_margin(8).show(ui, |ui| {
                ui.set_width(ui.available_width());
                ui.label(RichText::new(tr("Note le mot de passe du kit hors du NAS (papier, gestionnaire de mots de passe) : c'est le seul à retenir pour tout reconstruire.")).strong());
                ui.horizontal(|ui| {
                    if ui.button(tr("Voir le mot de passe du kit")).clicked() {
                        crate::pages::open_passwords(app);
                    }
                    let mut n = app.settings.kit_noted;
                    if ui.checkbox(&mut n, tr("Je l'ai noté")).changed() {
                        app.settings.kit_noted = n;
                        app.edit.kit_noted = n;
                        let _ = crate::config::save(&app.settings);
                    }
                });
            });
        }
        ui.add_space(4.0);
        match &s.secours {
            Some(k) if k.date.is_some() => {
                ui.label(tf("Kit à jour du {0} ({1})", &[&(fmt::date(k.date.unwrap_or(0))), &(fmt::bytes(k.taille.unwrap_or(0)))]));
                for (n, d) in &k.destinations {
                    let (c, t) = if d.ok { (OK, tf("{0} : envoyé {1}", &[n, &(fmt::ago(d.date, now))])) } else { (ERR, tf("{0} : envoi impossible ({1})", &[n, &(d.erreur.clone().unwrap_or_default())])) };
                    crate::pages::dot_label_pub(ui, c, RichText::new(t).small());
                }
                if k.destinations.is_empty() {
                    ui.label(RichText::new(tr("Pas encore envoyé vers les destinations (chaque jour à 5 h 40, ou « Envoyer maintenant »).")).small().weak());
                }
            }
            _ => {
                ui.label(RichText::new(tr("Pas encore de kit : il est créé chaque jour à 5 h 40 dès qu'une sauvegarde existe, ou maintenant.")).weak());
            }
        }
        match kit_pc(app) {
            Some((h, t)) => {
                let up = s.secours.as_ref().and_then(|k| k.empreinte.as_ref()).map(|e| *e == h).unwrap_or(true);
                crate::pages::dot_label_pub(
                    ui,
                    if up { OK } else { WARN },
                    RichText::new(if up { tf("Copie sur ce PC : {0}", &[&(fmt::ago(t, now))]) } else { tf("Copie sur ce PC : ancienne ({0}), mise à jour en attente", &[&(fmt::ago(t, now))]) }).small(),
                );
            }
            None => {
                ui.label(RichText::new(tr("Pas encore de copie sur ce PC.")).small().weak());
            }
        }
        ui.horizontal_wrapped(|ui| {
            if ui.button(tr("\u{E08E} Créer et envoyer maintenant")).clicked() {
                app.action_toast(HostId::Omv, tr("Kit de secours"), remote::secours_save(true), 30);
            }
            if ui.add_enabled(!app.dests.kit_busy, egui::Button::new(tr("\u{E248} Enregistrer une copie…"))).on_hover_text(tr("Par exemple sur une clé USB rangée en lieu sûr")).clicked() {
                kit_download(app, true);
            }
            if ui.button(tr("\u{E24A} Ouvrir le dossier sur ce PC")).clicked() {
                let d = kit_dir(app);
                let _ = std::fs::create_dir_all(&d);
                crate::install::open_url(&d.display().to_string());
            }
            if app.dests.kit_busy {
                ui.spinner();
            }
        });
        let mut auto = app.settings.kit_pc;
        if ui.checkbox(&mut auto, tr("Copier automatiquement le kit sur ce PC quand il change")).changed() {
            app.settings.kit_pc = auto;
            app.edit.kit_pc = auto;
            let _ = crate::config::save(&app.settings);
        }
        ui.label(RichText::new(tr("NAS perdu ? Aide > « Mon NAS est mort : reconstruire », puis page Installation > Reconstruire après une panne.")).small().weak());
    });
}

/// Carte de la page Installation : restaurer un kit de secours sur une nouvelle machine
pub fn rebuild_card(app: &mut App, ui: &mut egui::Ui) {
    ui.label(RichText::new(tr("Nouvelle machine après une panne : remet les connexions aux destinations, les mots de passe, les sauvegardes et les réglages de l'ancien NAS. Installe d'abord le script (carte 1).")).small());
    let ready = app.omv.status.as_ref().map(|s| s.nb_api >= 7).unwrap_or(false);
    let r = &mut app.dests.kit_restore;
    ui.horizontal(|ui| {
        if ui.button(tr("\u{E24A} Choisir le kit…")).clicked() {
            if let Some(p) = rfd::FileDialog::new().add_filter(tr("Kit de secours"), &["enc"]).pick_file() {
                r.bytes = std::fs::read(&p).ok();
                r.file = p.display().to_string();
            }
        }
        ui.label(RichText::new(if r.file.is_empty() { tr("aucun fichier").to_string() } else { r.file.clone() }).small());
    });
    ui.label(RichText::new(tf("Sur ce PC : {0} — ou dans le dossier NAS-secours d'une destination (site du cloud, disque USB).", &[&(kit_dir(app).display())])).small().weak());
    let r = &mut app.dests.kit_restore;
    ui.horizontal(|ui| {
        ui.label(tr("Mot de passe du kit"));
        ui.add(egui::TextEdit::singleline(&mut r.pass).password(true).hint_text("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX").desired_width(260.0));
    });
    let can = ready && r.bytes.is_some() && !r.pass.trim().is_empty();
    let (bytes, pass) = (r.bytes.clone().unwrap_or_default(), r.pass.trim().to_string());
    ui.horizontal(|ui| {
        if ui.add_enabled(can, egui::Button::new(tr("Vérifier le kit"))).on_hover_text(tr("Ouvre le kit et liste ce qui serait remis en place, sans rien modifier")).clicked() {
            app.action_dialog(HostId::Omv, tr("Kit de secours (vérification)"), remote::secours_restore(&bytes, &pass, false), 120);
        }
        if ui.add_enabled(can, egui::Button::new(RichText::new(tr("Restaurer sur cette machine")).color(Color32::WHITE)).fill(ERR)).clicked() {
            let (b, p) = (bytes.clone(), pass.clone());
            app.ask_confirm(
                tr("Restaurer le kit de secours"),
                tr("Les réglages actuels de la machine (connexions rclone, sauvegardes, mots de passe) sont remplacés par ceux du kit. Les fichiers remplacés sont gardés dans /root/.nas-manager."),
                tr("Restaurer"),
                true,
                None,
                Box::new(move |app| {
                    app.dests.kit_restore.pass.clear();
                    app.action_dialog(HostId::Omv, tr("Kit de secours"), remote::secours_restore(&b, &p, true), 300);
                }),
            );
        }
    });
    if !ready {
        ui.label(RichText::new(tr("Installe d'abord le script nas-debian à jour (carte 1).")).small().color(WARN));
    }
    egui::CollapsingHeader::new(RichText::new(tr("Pas de kit ? Saisir les mots de passe notés")).small()).show(ui, |ui| {
        ui.label(RichText::new(tr("Sans kit, reconnecte d'abord les destinations (page Destinations), puis saisis les mots de passe notés pour relire les sauvegardes chiffrées et versionnées. Champ vide = inchangé.")).small());
        let r = &mut app.dests.kit_restore;
        egui::Grid::new("pwgrid").num_columns(2).spacing([10.0, 6.0]).show(ui, |ui| {
            ui.label(tr("Mot de passe du chiffrement"));
            ui.add(egui::TextEdit::singleline(&mut r.crypt).password(true).desired_width(300.0));
            ui.end_row();
            ui.label(tr("Sel (password2)"));
            ui.add(egui::TextEdit::singleline(&mut r.salt).password(true).desired_width(300.0));
            ui.end_row();
            ui.label(tr("Mot de passe des versions"));
            ui.add(egui::TextEdit::singleline(&mut r.versions).password(true).desired_width(300.0));
            ui.end_row();
        });
        let ok = ready && ((!r.crypt.trim().is_empty() && !r.salt.trim().is_empty()) || !r.versions.trim().is_empty());
        if ui.add_enabled(ok, egui::Button::new(tr("Enregistrer sur la machine"))).clicked() {
            let script = remote::secours_passwords(r.crypt.trim(), r.salt.trim(), r.versions.trim());
            r.crypt.clear();
            r.salt.clear();
            r.versions.clear();
            app.action_dialog(HostId::Omv, tr("Mots de passe"), script, 60);
        }
    });
}

/// Pastille du menu : destination injoignable
pub fn nav_badge(s: &OmvStatus) -> Option<(String, Color32)> {
    let ko = s.destinations.iter().filter(|d| d.etat.as_ref().map(|e| !e.ok).unwrap_or(false)).count();
    if ko > 0 {
        Some((tf("{0} injoignable", &[&ko]), ERR))
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rotation() {
        assert_eq!(rot_build(&rot_parse("7:4:12:0")).as_deref(), Some("7:4:12:0"));
        assert_eq!(rot_parse("n'importe"), rot_parse(""));
        assert!(rot_build(&["0".into(), "0".into(), "0".into(), "0".into()]).is_none());
        assert!(rot_build(&["x".into(), "1".into(), "0".into(), "0".into()]).is_none());
        assert_eq!(dests_build(&[("gdrive".into(), true), ("usb".into(), false)], false), "gdrive:oui;usb:non");
        assert_eq!(dests_build(&[("usb".into(), false)], true), "usb:oui");
        assert_eq!(rt_remote("gcrypt:"), "gdrive");
        assert_eq!(rt_remote("usb-chiffre:Docs"), "usb");
        assert_eq!(rt_remote("gdrive:NAS/Docs"), "gdrive");
        assert!(valid_name("nas_papa") && !valid_name("a-b") && !valid_name("1usb") && !valid_name("gbackup"));
    }
}
