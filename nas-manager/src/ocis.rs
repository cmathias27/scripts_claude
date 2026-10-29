//! Page oCIS (étape 6) : migration d'un dossier vers oCIS, depuis le Synology, l'OMV / Debian
//! ou ce PC, et transferts oCIS -> Synology / OMV (sens inverse), ponctuels ou programmés.

use crate::app::{App, BrowsePurpose, HostId, MigForm, OutputDialog};
use crate::fmt;
#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::model::{Migration, Space, Transfert, Transferts};
use crate::pages::{badge, banner, card, danger_button, dot, hist_line, host_banner, mig_avancement, page_title, primary_button, progress_bar, syno_script_banner};
use crate::remote;
use crate::sched::{BwEdit, SchedEdit};
use crate::theme::{self, ERR, IDLE, INFO, OK, WARN};
use eframe::egui::{self, Color32, RichText};

/// Machine d'où part la migration
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Src {
    Syno,
    Omv,
    Pc,
}

#[derive(Default)]
pub struct OcisUi {
    /// 0 migration vers oCIS, 1 transferts oCIS -> NAS
    pub tab: u8,
    pub src: Option<Src>,
    pub tr_host: Option<HostId>,
    pub tr_form: Option<TrForm>,
}

#[derive(Clone)]
pub struct TrForm {
    pub host: HostId,
    pub new: bool,
    pub name: String,
    pub name_touched: bool,
    pub spaces: Vec<Space>,
    pub spaces_loading: bool,
    pub spaces_error: String,
    pub space_id: String,
    pub space_name: String,
    pub sub: String,
    /// parcours des dossiers de l'espace
    pub browse: bool,
    pub browse_path: String,
    pub browse_entries: Vec<String>,
    pub browse_loading: bool,
    pub dest: String,
    pub mirror: bool,
    pub trash: String,
    /// 0 ponctuel (tout de suite), 1 à la demande, 2 programmé
    pub when: u8,
    pub sched: SchedEdit,
    pub bw: BwEdit,
    pub error: String,
}

impl TrForm {
    fn new(host: HostId) -> Self {
        TrForm {
            host,
            new: true,
            name: String::new(),
            name_touched: false,
            spaces: Vec::new(),
            spaces_loading: false,
            spaces_error: String::new(),
            space_id: String::new(),
            space_name: String::new(),
            sub: String::new(),
            browse: false,
            browse_path: String::new(),
            browse_entries: Vec::new(),
            browse_loading: false,
            dest: String::new(),
            mirror: false,
            trash: "30".into(),
            when: 0,
            sched: SchedEdit { mode: 1, times: "02:30".into(), ..Default::default() },
            bw: BwEdit::default(),
            error: String::new(),
        }
    }

    fn from(host: HostId, t: &Transfert) -> Self {
        let mut f = TrForm::new(host);
        f.new = false;
        f.name = t.nom.clone();
        f.name_touched = true;
        f.space_id = t.espace_id.clone();
        f.space_name = t.espace.clone();
        f.sub = t.sous_dossier.clone();
        f.dest = t.destination.clone();
        f.mirror = t.mode == "miroir";
        f.trash = if t.corbeille > 0 { t.corbeille.to_string() } else { "30".into() };
        f.when = match t.horaire.as_str() {
            "une-fois" => 0,
            "manuel" => 1,
            _ => 2,
        };
        if f.when == 2 {
            f.sched = SchedEdit::parse(&t.horaire);
        }
        f.bw = BwEdit::parse(&t.debit);
        f
    }
}

fn label(h: HostId) -> &'static str {
    match h {
        HostId::Omv => tr("OMV / Debian"),
        HostId::Syno => "Synology",
    }
}

/// « sur le Synology », « sur l'OMV »
fn sur(h: HostId) -> &'static str {
    match h {
        HostId::Omv => tr("sur l'OMV"),
        HostId::Syno => tr("sur le Synology"),
    }
}

/// « du Synology », « de l'OMV »
fn du(h: HostId) -> &'static str {
    match h {
        HostId::Omv => tr("de l'OMV"),
        HostId::Syno => tr("du Synology"),
    }
}

/// Migration en cours (sur une machine ou depuis ce PC) : pastille du menu
pub fn nav_badge(app: &App) -> Option<(String, Color32)> {
    let syno = app.syno.status.as_ref();
    let omv = app.omv.status.as_ref();
    let running = syno.map(|s| s.migration.en_cours).unwrap_or(false) || omv.and_then(|s| s.migration.as_ref()).map(|m| m.en_cours).unwrap_or(false) || crate::pcmig::running(app);
    let tr_run = syno.and_then(|s| s.transferts.as_ref()).map(|t| t.en_cours.is_some()).unwrap_or(false)
        || omv.and_then(|s| s.transferts.as_ref()).map(|t| t.en_cours.is_some()).unwrap_or(false);
    let queued = syno.map(|s| s.migration.file.len()).unwrap_or(0) + omv.and_then(|s| s.migration.as_ref()).map(|m| m.file.len()).unwrap_or(0);
    if running || tr_run {
        Some((tr("en cours").into(), INFO))
    } else if queued > 0 {
        Some((tf("{0} en file", &[&queued]), WARN))
    } else {
        None
    }
}

pub fn page(app: &mut App, ui: &mut egui::Ui) {
    page_title(ui, tr("oCIS"), tr("Migration vers ownCloud Infinite Scale et transferts d'oCIS vers les NAS"));
    ui.horizontal(|ui| {
        ui.selectable_value(&mut app.ocis_ui.tab, 0, RichText::new(tr("\u{E1AC} Migration vers oCIS")).size(15.0));
        ui.selectable_value(&mut app.ocis_ui.tab, 1, RichText::new(tr("\u{E20C} Transferts oCIS → NAS")).size(15.0));
    });
    ui.add_space(6.0);
    if app.ocis_ui.tab == 0 {
        migration(app, ui);
    } else {
        transfers(app, ui);
    }
}

// =====================================================================
//  Migration vers oCIS
// =====================================================================

fn migration(app: &mut App, ui: &mut egui::Ui) {
    let syno_set = app.settings.syno.is_set();
    let src = *app.ocis_ui.src.get_or_insert(if syno_set { Src::Syno } else { Src::Omv });
    ui.horizontal(|ui| {
        ui.label(tr("Migrer depuis :"));
        let mut s = src;
        if syno_set {
            ui.selectable_value(&mut s, Src::Syno, tr("\u{E2A0} Synology"));
        }
        ui.selectable_value(&mut s, Src::Omv, tr("\u{E2A0} OMV / Debian"));
        ui.selectable_value(&mut s, Src::Pc, tr("\u{E560} Ce PC"));
        if s != src {
            app.ocis_ui.src = Some(s);
        }
    });
    ui.add_space(6.0);
    match app.ocis_ui.src.unwrap_or(Src::Omv) {
        Src::Syno => migration_host(app, ui, HostId::Syno),
        Src::Omv => migration_host(app, ui, HostId::Omv),
        Src::Pc => crate::pcmig::page(app, ui),
    }
}

/// Etat de la migration d'une machine ; None (et message) si le script ne la gere pas encore
fn mig_status(app: &mut App, ui: &mut egui::Ui, h: HostId) -> Option<(Migration, bool)> {
    match h {
        HostId::Syno => {
            let m = app.syno.status.as_ref()?.migration.clone();
            let ready = syno_script_banner(app, ui, m.installe, m.api, "migre-drive-ocis");
            Some((m, ready))
        }
        HostId::Omv => {
            let s = app.omv.status.clone()?;
            match s.migration {
                Some(m) => Some((m, true)),
                None => {
                    banner(ui, WARN, tr("Mets à jour le script nas-debian (2.5 ou plus) pour migrer un dossier de cette machine vers oCIS."));
                    crate::scripts::widget(app, ui, crate::scripts::Kind::Debian);
                    None
                }
            }
        }
    }
}

fn migration_host(app: &mut App, ui: &mut egui::Ui, h: HostId) {
    if !host_banner(app, ui, h) {
        return;
    }
    let Some((m, ready)) = mig_status(app, ui, h) else {
        return;
    };
    let now = match h {
        HostId::Syno => app.syno.status.as_ref().map(|s| s.maintenant).unwrap_or(0),
        HostId::Omv => app.omv.status.as_ref().map(|s| s.maintenant).unwrap_or(0),
    };
    if app.mig.host != Some(h) {
        app.mig = MigForm { host: Some(h), ..Default::default() };
        app.ocis.open = false;
    }
    if ready && m.config.is_some() && !app.mig.auto_loaded {
        app.mig.auto_loaded = true;
        load_spaces(app, h);
        if h == HostId::Syno {
            load_mig_sources(app, h);
        }
    }

    connection_card(app, ui, h, &m, ready);
    ui.add_space(10.0);

    // ---- Migration en cours
    if m.en_cours {
        card(ui, tr("Migration en cours"), |ui| {
            if let Some(e) = &m.etape {
                ui.label(RichText::new(format!("[{}/{}]  {}  →  {}", e.etape, m.nb, e.libelle, e.espace)).strong());
                ui.label(RichText::new(format!("{} · {}", e.source, fmt::bytes(e.total))).small().weak());
                let phase = match e.phase.as_str() {
                    "verification" => tr("Contrôle des empreintes dans oCIS").to_string(),
                    "relecture" => tr("Contrôle par relecture depuis oCIS").to_string(),
                    "suppression" => tr("Suppression des originaux contrôlés").to_string(),
                    "renvoi" => tr("Renvoi des fichiers en défaut").to_string(),
                    "bilan" => tf("Bilan : comptage des fichiers {0} et dans oCIS", &[&sur(h)]),
                    _ => tr("Transfert").to_string(),
                };
                ui.label(phase);
                if let Some(a) = &e.avancement {
                    mig_avancement(ui, a, true);
                } else if e.phase == "bilan" {
                    progress_bar(ui, None, tr("comptage…").into());
                } else {
                    let line = if e.ligne.is_empty() {
                        if e.phase.is_empty() {
                            tr("Comparaison avec ce qui est déjà dans oCIS…").into()
                        } else {
                            tr("démarrage…").into()
                        }
                    } else {
                        fmt::stats_line(&e.ligne)
                    };
                    progress_bar(ui, e.pct, line);
                }
                let mut extra = Vec::new();
                if let Some(r) = e.ram_mo {
                    extra.push(tf("RAM rclone {0} Mo", &[&r]));
                }
                if e.reprise > 0 {
                    extra.push(tf("reprise automatique {0}/5", &[&e.reprise]));
                }
                if e.suppression == "oui" {
                    extra.push(tr("+ suppression des originaux contrôlés").into());
                } else if e.suppression == "verif" {
                    extra.push(tr("contrôle + suppression sans transfert").into());
                }
                if !extra.is_empty() {
                    ui.label(RichText::new(extra.join(" · ")).small().color(if e.reprise > 0 { WARN } else { IDLE }));
                }
            }
            if m.debut > 0 {
                ui.label(RichText::new(tf("Lancée {0}", &[&(fmt::ago(m.debut, now))])).small().weak());
            }
            if danger_button(ui, tr("\u{E46C} Arrêter la migration")).clicked() {
                app.ask_confirm(
                    tr("Arrêter la migration"),
                    tr("La migration s'arrête ; les éléments non terminés sont remis en file d'attente et reprendront là où ils en étaient."),
                    tr("Arrêter"),
                    true,
                    None,
                    Box::new(move |app| app.action_toast(h, tr("Arrêt"), remote::migre_stop(h), 30)),
                );
            }
        });
        ui.add_space(10.0);
    }

    // ---- Resultats
    if !m.resultats.is_empty() {
        card(ui, tr("Résultats du dernier lancement"), |ui| {
            for r in &m.resultats {
                ui.horizontal_wrapped(|ui| {
                    dot(ui, if r.etat == "OK" { OK } else { ERR });
                    ui.label(RichText::new(format!("{} → {}", r.libelle, r.espace)).strong());
                    if !r.detail.is_empty() && r.etat == "OK" {
                        ui.label(RichText::new(&r.detail).small());
                    }
                });
                if r.etat != "OK" && !r.detail.is_empty() {
                    crate::explain::show(ui, &r.detail);
                }
            }
            if m.resultats.iter().any(|r| r.detail.contains("quota")) {
                ui.label(RichText::new(tr("Espace plein : dans oCIS, ouvre l'espace > \u{E1FE} > Modifier le quota > « Pas de restriction ».")).small().color(WARN));
            }
            if m.resultats.iter().any(|r| r.detail.contains("401")) {
                ui.label(RichText::new(tr("Jeton refusé : recrée un jeton et mets à jour la connexion ci-dessus.")).small().color(WARN));
            }
        });
        ui.add_space(10.0);
    }

    // ---- File d'attente
    card(ui, &tf("File d'attente ({0})", &[&(m.file.len())]), |ui| {
        if m.file.is_empty() {
            ui.label(RichText::new(tr("Vide : ajoute une migration ci-dessous.")).weak());
        }
        let mut remove: Option<usize> = None;
        for (i, q) in m.file.iter().enumerate() {
            ui.horizontal(|ui| {
                ui.label(RichText::new(format!("{}.", i + 1)).weak());
                ui.label(
                    RichText::new(format!("{}  →  {}{}", q.libelle, q.espace, if q.sous_dossier.is_empty() { String::new() } else { format!("/{}", q.sous_dossier) })).strong(),
                );
                ui.label(RichText::new(fmt::bytes(q.total)).small());
                match q.suppression.as_str() {
                    "oui" => badge(ui, tr("+ suppression des originaux"), ERR),
                    "verif" => badge(ui, tr("contrôle + suppression"), ERR),
                    _ => {}
                }
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.add_enabled(ready && !m.en_cours, egui::Button::new("\u{E4F6}").small()).on_hover_text(tr("Retirer de la file")).clicked() {
                        remove = Some(i + 1);
                    }
                });
            });
        }
        if let Some(n) = remove {
            app.action_toast(h, tr("Retrait"), remote::migre_remove(h, n), 30);
        }
        ui.add_space(4.0);
        if ui
            .add_enabled(ready && !m.en_cours && !m.file.is_empty(), egui::Button::new(RichText::new(tr("\u{E3D0} Lancer la file d'attente")).color(Color32::WHITE)).fill(INFO))
            .clicked()
        {
            let has_delete = m.file.iter().any(|q| q.suppression != "non");
            let extra = if has_delete { tf("\nCertaines suppriment les originaux {0} après contrôle dans oCIS.", &[&du(h)]) } else { String::new() };
            app.ask_confirm(
                tr("Lancer la migration"),
                &tf("{0} migration(s) vont être traitées l'une après l'autre, en arrière-plan {1}.{2}", &[&(m.file.len()), &sur(h), &extra]),
                tr("Lancer"),
                false,
                None,
                Box::new(move |app| app.action_toast(h, tr("Lancement"), remote::migre_start(h), 120)),
            );
        }
    });
    ui.add_space(10.0);

    // ---- Ajouter
    card(ui, tr("Ajouter une migration"), |ui| {
        ui.add_enabled_ui(ready && m.config.is_some(), |ui| {
            if m.config.is_none() {
                ui.colored_label(WARN, tr("Configure d'abord la connexion oCIS."));
            }
            ui.horizontal(|ui| {
                ui.label(tr("Source :"));
                if h == HostId::Syno {
                    let sel = if app.mig.src.is_empty() { tr("Choisir…").to_string() } else { app.mig.src.clone() };
                    let mut picked: Option<(String, String)> = None;
                    egui::ComboBox::from_id_salt("migsrc").width(360.0).selected_text(sel).show_ui(ui, |ui| {
                        if app.mig.sources.is_empty() {
                            ui.label(RichText::new(tr("(clique sur \u{E094} pour lister les Mon Drive)")).weak());
                        }
                        for (p, l) in &app.mig.sources {
                            if ui.selectable_label(app.mig.src == *p, tf("Mon Drive de {0}", &[&l])).clicked() {
                                picked = Some((p.clone(), l.clone()));
                            }
                        }
                    });
                    if let Some((p, l)) = picked {
                        app.mig.src = p;
                        app.mig.label = l;
                    }
                    if ui.button("\u{E094}").on_hover_text(tr("Lister les « Mon Drive »")).clicked() {
                        load_mig_sources(app, h);
                    }
                } else {
                    ui.add(egui::TextEdit::singleline(&mut app.mig.src).desired_width(360.0).hint_text(tr("dossier de la machine")));
                }
                if ui.button(tr("\u{E24A} Parcourir")).clicked() {
                    app.open_browser(h, BrowsePurpose::MigSource, "");
                }
            });
            space_picker(app, ui, h);
            ui.horizontal(|ui| {
                ui.label(tr("Sous-dossier dans l'espace :"));
                ui.add(egui::TextEdit::singleline(&mut app.mig.sub).hint_text(tr("vide = racine de l'espace")).desired_width(220.0));
                ui.label(tr("Libellé :"));
                ui.add(egui::TextEdit::singleline(&mut app.mig.label).desired_width(140.0));
            });
            ui.label(tr("Après le transfert :"));
            ui.radio_value(&mut app.mig.del_mode, 0, tf("Garder les originaux {0} (copie)", &[&sur(h)]));
            ui.radio_value(&mut app.mig.del_mode, 1, RichText::new(tf("Contrôler chaque fichier dans oCIS, puis SUPPRIMER l'original {0}", &[&du(h)])).color(ERR));
            ui.radio_value(&mut app.mig.del_mode, 2, RichText::new(tr("Déjà migré : contrôler et supprimer les originaux, sans transfert")).color(ERR));
            if app.mig.del_mode > 0 && app.mig.src.contains("/homes/") && app.mig.src.ends_with("/Drive") {
                ui.label(RichText::new(tr("C'est un « Mon Drive » : les ordinateurs synchronisés avec Synology Drive supprimeront aussi ces fichiers chez eux. Installe d'abord le client oCIS.")).small().color(ERR));
            }
            let sp = app.mig.space_idx.and_then(|i| app.mig.spaces.get(i)).cloned();
            let can = !app.mig.src.trim().is_empty() && sp.is_some();
            if ui.add_enabled(can, egui::Button::new(tr("+ Ajouter à la file d'attente"))).clicked() {
                let sp = sp.unwrap();
                let (src, sub, lab, mode) = (app.mig.src.trim().trim_end_matches('/').to_string(), app.mig.sub.trim().trim_matches('/').to_string(), app.mig.label.trim().to_string(), app.mig.del_mode);
                let del = match mode {
                    1 => "oui",
                    2 => "verif",
                    _ => "non",
                };
                let script = remote::migre_add(h, &src, &sp.id, &sub, del, &lab);
                if mode > 0 {
                    app.ask_confirm(
                        tr("Suppression des originaux"),
                        &tf("Seuls les fichiers dont la copie dans oCIS est contrôlée identique (empreinte) seront supprimés {0}. Un fichier absent, différent ou modifié entre-temps est gardé.", &[&du(h)]),
                        tr("Ajouter"),
                        true,
                        Some(tr("SUPPRIMER")),
                        Box::new(move |app| app.action_toast(h, tr("Ajout"), script, 900)),
                    );
                } else {
                    app.action_toast(h, tr("Ajout (calcul de la taille)"), script, 900);
                }
            }
        });
    });
    ui.add_space(10.0);

    egui::CollapsingHeader::new(tr("Journal de la migration (derniers événements)")).id_salt(("migjournal", h as u8)).show(ui, |ui| {
        for l in &m.journal {
            ui.label(RichText::new(l).monospace().size(12.0));
        }
    });
    card(ui, tr("Historique"), |ui| {
        if m.historique.is_empty() {
            ui.label(RichText::new(tr("Aucune migration.")).weak());
        }
        for l in m.historique.iter().rev() {
            ui.horizontal(|ui| {
                dot(ui, if l.contains("| OK") { OK } else { ERR });
                ui.label(RichText::new(l).small());
            });
        }
    });
}

/// Espace oCIS de destination (liste lue sur la machine)
fn space_picker(app: &mut App, ui: &mut egui::Ui, h: HostId) {
    ui.horizontal(|ui| {
        ui.label(tr("Espace oCIS :"));
        let sel = app.mig.space_idx.and_then(|i| app.mig.spaces.get(i)).map(|s| s.name.clone()).unwrap_or_else(|| tr("Choisir…").into());
        let mut pick: Option<usize> = None;
        egui::ComboBox::from_id_salt("migspace").width(300.0).selected_text(sel).show_ui(ui, |ui| {
            for (i, sp) in app.mig.spaces.iter().enumerate() {
                let q = if sp.quota > 0 { tf("libre {0} / quota {1}", &[&(fmt::bytes(sp.free.max(0) as u64)), &(fmt::bytes(sp.quota as u64))]) } else { tr("sans limite").into() };
                if ui.selectable_label(app.mig.space_idx == Some(i), format!("{}  ({q})", sp.name)).clicked() {
                    pick = Some(i);
                }
            }
        });
        if let Some(i) = pick {
            app.mig.space_idx = Some(i);
        }
        if app.mig.loading_spaces {
            ui.spinner();
        } else if ui.button("\u{E094}").on_hover_text(tr("Lister les espaces projets")).clicked() {
            load_spaces(app, h);
        }
    });
    if !app.mig.spaces_error.is_empty() {
        ui.colored_label(ERR, &app.mig.spaces_error);
    }
}

/// Connexion à oCIS de la machine (une par machine)
fn connection_card(app: &mut App, ui: &mut egui::Ui, h: HostId, m: &Migration, ready: bool) {
    card(ui, &tf("Connexion oCIS ({0})", &[&label(h)]), |ui| {
        match &m.config {
            Some(c) => {
                ui.label(tf("{0}  ·  compte {1}", &[&c.url, &c.utilisateur]));
                ui.label(
                    RichText::new(tf(
                        "Transferts : {0}  ·  mode {1}",
                        &[
                            &(if c.locale.is_empty() { tr("via Internet").to_string() } else { tf("réseau local ({0})", &[&c.locale]) }),
                            &(if c.mode == "owncloud" { tr("WebDAV classique").to_string() } else { c.mode.clone() }),
                        ],
                    ))
                    .small()
                    .weak(),
                );
            }
            None => {
                ui.colored_label(WARN, tr("Pas encore configurée."));
            }
        }
        if ui.add_enabled(ready, egui::Button::new(if app.ocis.open { tr("Fermer") } else { tr("Modifier la connexion…") })).clicked() {
            app.ocis.open = !app.ocis.open;
            if app.ocis.open {
                if let Some(c) = &m.config {
                    app.ocis.url = c.url.clone();
                    app.ocis.user = c.utilisateur.clone();
                    app.ocis.local = c.locale.clone();
                    app.ocis.insecure = c.certificat_accepte;
                } else if app.ocis.local.is_empty() {
                    app.ocis.local = "https://192.168.1.53:9200".into();
                }
                app.ocis.token.clear();
            }
        }
        if app.ocis.open {
            egui::Grid::new("ocisgrid").num_columns(2).spacing([12.0, 8.0]).show(ui, |ui| {
                ui.label(tr("Adresse d'oCIS"));
                ui.add(egui::TextEdit::singleline(&mut app.ocis.url).hint_text("https://cloud.maison.fr").desired_width(320.0));
                ui.end_row();
                ui.label(tr("Utilisateur"));
                ui.add(egui::TextEdit::singleline(&mut app.ocis.user).desired_width(200.0));
                ui.end_row();
                ui.label(tr("Jeton d'application"));
                ui.add(egui::TextEdit::singleline(&mut app.ocis.token).password(true).desired_width(320.0));
                ui.end_row();
                ui.label(tr("Adresse locale"));
                ui.add(egui::TextEdit::singleline(&mut app.ocis.local).hint_text(tr("vide = passer par Internet")).desired_width(320.0));
                ui.end_row();
                ui.label("");
                ui.checkbox(&mut app.ocis.insecure, tr("Accepter un certificat non reconnu (auto-signé)"));
                ui.end_row();
            });
            ui.label(RichText::new(tr("Jeton : docker exec <conteneur-ocis> ocis auth-app create --user-name=<compte> --expiration=2160h")).small().monospace().weak());
            let can = !app.ocis.url.trim().is_empty() && !app.ocis.user.trim().is_empty() && !app.ocis.token.trim().is_empty();
            if ui.add_enabled(can, egui::Button::new(tr("Tester et enregistrer"))).clicked() {
                let f = app.ocis.clone();
                app.ocis.open = false;
                app.ocis.token.clear();
                app.mig.auto_loaded = false;
                app.action_dialog(h, tr("Connexion à oCIS"), remote::migre_configure(h, &f.url, &f.user, &f.token, &f.local, f.insecure), 300);
            }
        }
    });
}

fn load_spaces(app: &mut App, h: HostId) {
    app.mig.loading_spaces = true;
    app.mig.spaces_error.clear();
    app.exec(
        h,
        tr("Espaces oCIS"),
        remote::migre_spaces(h),
        60,
        Box::new(move |app, r| {
            if app.mig.host != Some(h) {
                return;
            }
            app.mig.loading_spaces = false;
            match r {
                Ok(o) if o.code == 0 => {
                    app.mig.spaces = crate::model::parse_spaces(&o.stdout);
                    if app.mig.spaces.is_empty() {
                        app.mig.spaces_error = tr("Aucun espace projet visible : ajoute le compte comme membre des espaces (Peut modifier / Gestionnaire).").into();
                    }
                    app.mig.space_idx = None;
                }
                Ok(o) => app.mig.spaces_error = o.text(),
                Err(e) => app.mig.spaces_error = e.to_string(),
            }
        }),
    );
}

fn load_mig_sources(app: &mut App, h: HostId) {
    app.exec(
        h,
        tr("Mon Drive"),
        remote::migre_sources(h),
        30,
        Box::new(|app, r| match r {
            Ok(o) => {
                app.mig.sources = o.stdout.lines().filter_map(|l| l.split_once('|').map(|(a, b)| (a.to_string(), b.to_string()))).collect();
                if app.mig.sources.is_empty() {
                    app.toast(false, tr("Aucun « Mon Drive » trouvé (/volume*/homes/*/Drive).").into());
                }
            }
            Err(e) => app.toast(false, e.to_string()),
        }),
    );
}

// =====================================================================
//  Transferts oCIS -> NAS
// =====================================================================

fn tr_status(app: &App, h: HostId) -> Option<Transferts> {
    match h {
        HostId::Syno => app.syno.status.as_ref().and_then(|s| s.transferts.clone()),
        HostId::Omv => app.omv.status.as_ref().and_then(|s| s.transferts.clone()),
    }
}

pub fn sched_text(s: &str) -> String {
    match s {
        "une-fois" => tr("Ponctuel").into(),
        "manuel" => tr("À la demande").into(),
        _ => format!("\u{E19A} {}", fmt::schedule_human(s)),
    }
}

fn transfers(app: &mut App, ui: &mut egui::Ui) {
    let syno_set = app.settings.syno.is_set();
    let h = *app.ocis_ui.tr_host.get_or_insert(if syno_set { HostId::Syno } else { HostId::Omv });
    ui.horizontal(|ui| {
        ui.label(tr("Vers :"));
        let mut s = h;
        if syno_set {
            ui.selectable_value(&mut s, HostId::Syno, tr("\u{E2A0} Synology"));
        }
        ui.selectable_value(&mut s, HostId::Omv, tr("\u{E2A0} OMV / Debian"));
        if s != h {
            app.ocis_ui.tr_host = Some(s);
        }
    });
    ui.label(RichText::new(tr("Un dossier d'un espace oCIS (personnel ou projet) recopié dans un dossier de la machine, par l'accès WebDAV d'oCIS (jamais en lisant directement son stockage), dates de modification conservées. Ponctuel, à la demande ou programmé (sauvegarde régulière d'oCIS vers le NAS).")).small().weak());
    ui.add_space(6.0);
    let h = app.ocis_ui.tr_host.unwrap_or(HostId::Omv);
    if !host_banner(app, ui, h) {
        return;
    }
    let Some(t) = tr_status(app, h) else {
        banner(
            ui,
            WARN,
            &tf("Mets à jour le script de la machine ({0}) pour les transferts depuis oCIS.", &[&(if h == HostId::Syno { "nas-synology 2.4" } else { "nas-debian 2.5" })]),
        );
        crate::scripts::widget(app, ui, if h == HostId::Syno { crate::scripts::Kind::Synology } else { crate::scripts::Kind::Debian });
        return;
    };
    let now = fmt::now();
    if !t.config {
        banner(ui, WARN, &tf("Connexion à oCIS à configurer d'abord sur cette machine ({0}).", &[&label(h)]));
        if ui.button(tr("Configurer la connexion oCIS…")).clicked() {
            app.ocis_ui.tab = 0;
            app.ocis_ui.src = Some(if h == HostId::Syno { Src::Syno } else { Src::Omv });
            app.ocis.open = true;
        }
        ui.add_space(6.0);
    }
    ui.horizontal(|ui| {
        if ui.add_enabled(t.config, egui::Button::new(RichText::new(tr("+ Nouveau transfert")).color(Color32::WHITE)).fill(INFO)).clicked() {
            let mut f = TrForm::new(h);
            if h == HostId::Omv {
                f.dest = app.backup_sources.first().map(|d| d.rsplit_once('/').map(|(a, _)| format!("{a}/oCIS")).unwrap_or_default()).unwrap_or_default();
            }
            app.ocis_ui.tr_form = Some(f);
            load_tr_spaces(app);
        }
    });
    ui.add_space(6.0);

    // ---- en cours
    if let Some(c) = &t.en_cours {
        card(ui, &tf("En cours : « {0} »", &[&c.nom]), |ui| {
            ui.label(
                RichText::new(format!("{}{}  →  {}", c.espace, if c.sous_dossier.is_empty() { String::new() } else { format!("/{}", c.sous_dossier) }, c.destination)).strong(),
            );
            match &c.avancement {
                Some(a) => mig_avancement(ui, a, true),
                None => progress_bar(ui, None, tr("Comparaison avec la destination…").into()),
            }
            let mut extra = vec![tf("Lancé {0}", &[&(fmt::ago(c.debut, now))])];
            if let Some(r) = c.ram_mo {
                extra.push(tf("RAM rclone {0} Mo", &[&r]));
            }
            if c.reprise > 0 {
                extra.push(tf("reprise automatique {0}/5", &[&c.reprise]));
            }
            ui.label(RichText::new(extra.join(" · ")).small().color(if c.reprise > 0 { WARN } else { IDLE }));
            if danger_button(ui, tr("\u{E46C} Arrêter")).clicked() {
                app.ask_confirm(
                    tr("Arrêter le transfert"),
                    tr("Le transfert s'arrête et la file d'attente est vidée. Le relancer reprendra là où il s'est arrêté."),
                    tr("Arrêter"),
                    true,
                    None,
                    Box::new(move |app| app.action_toast(h, tr("Arrêt"), remote::tr_stop(h), 90)),
                );
            }
        });
        ui.add_space(8.0);
    }
    if !t.file.is_empty() {
        ui.label(RichText::new(tf("File d'attente : {0}", &[&(t.file.join(", "))])).color(WARN));
        ui.add_space(6.0);
    }

    if t.transferts.is_empty() {
        card(ui, "", |ui| {
            ui.label(tr("Aucun transfert. « Nouveau transfert » : choisis l'espace oCIS, le dossier, puis le dossier de destination sur la machine."));
        });
    }
    for tf_ in &t.transferts {
        transfer_card(app, ui, h, tf_, &t, now);
        ui.add_space(8.0);
    }

    egui::CollapsingHeader::new(tr("Journal du dernier transfert (événements)")).id_salt(("trjournal", h as u8)).show(ui, |ui| {
        for l in &t.journal {
            ui.label(RichText::new(l).monospace().size(12.0));
        }
    });
    card(ui, tr("Historique"), |ui| {
        if t.historique.is_empty() {
            ui.label(RichText::new(tr("Aucun transfert.")).weak());
        }
        for l in t.historique.iter().rev() {
            let col = if l.contains("| OK") {
                OK
            } else if l.contains("| ARRETE") {
                WARN
            } else {
                ERR
            };
            ui.horizontal(|ui| {
                dot(ui, col);
                ui.label(RichText::new(hist_line(l)).small()).on_hover_text(l);
            });
        }
    });
}

fn transfer_card(app: &mut App, ui: &mut egui::Ui, h: HostId, t: &Transfert, all: &Transferts, now: i64) {
    let running = all.en_cours.as_ref().map(|c| c.nom == t.nom).unwrap_or(false);
    let queued = all.file.contains(&t.nom);
    theme::card_frame(ui).show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.horizontal(|ui| {
            let (col, st) = if running {
                (INFO, tr("En cours").to_string())
            } else if queued {
                (WARN, tr("Dans la file").to_string())
            } else {
                match t.dernier.as_ref().map(|d| d.etat.as_str()) {
                    Some("OK") => (OK, tr("OK").to_string()),
                    Some("ECHEC") => (ERR, tr("Échec").to_string()),
                    Some("ARRETE") => (WARN, tr("Arrêté").to_string()),
                    _ => (IDLE, tr("Jamais lancé").to_string()),
                }
            };
            dot(ui, col);
            ui.label(RichText::new(&t.nom).strong().size(16.0));
            badge(ui, &st, col);
            badge(ui, if t.mode == "miroir" { tr("Miroir") } else { tr("Copie") }, IDLE);
            badge(ui, &sched_text(&t.horaire), IDLE);
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let name = t.nom.clone();
                ui.menu_button(tr("\u{E1FE}"), |ui| {
                    if ui.button(tr("\u{EB7A} Journal")).clicked() {
                        let n = name.clone();
                        app.exec(
                            h,
                            tr("Journal"),
                            remote::tr_log(&n),
                            30,
                            Box::new(move |app, r| {
                                let txt = r.map(|o| o.stdout).unwrap_or_else(|e| e.to_string());
                                app.output = Some(OutputDialog { title: tf("Journal du transfert « {0} »", &[&n]), text: txt, ok: true });
                            }),
                        );
                        ui.close();
                    }
                    if ui.add_enabled(!running, egui::Button::new(tr("\u{E4A6} Supprimer…"))).clicked() {
                        let n = name.clone();
                        app.ask_confirm(
                            tr("Supprimer le transfert"),
                            &tf("Le transfert « {0} » est supprimé (et sa planification). Les fichiers déjà copiés restent en place.", &[&n]),
                            tr("Supprimer"),
                            true,
                            None,
                            Box::new(move |app| app.action_toast(h, tr("Suppression"), remote::tr_delete(h, &n), 30)),
                        );
                        ui.close();
                    }
                });
                if ui.button(tr("\u{E3B4} Modifier")).clicked() {
                    app.ocis_ui.tr_form = Some(TrForm::from(h, t));
                    load_tr_spaces(app);
                }
                if ui.add_enabled(!running && !queued, egui::Button::new(tr("\u{E3D0} Lancer"))).clicked() {
                    app.action_toast(h, tr("Lancement"), remote::tr_launch(h, &name), 30);
                }
            });
        });
        ui.label(
            RichText::new(format!(
                "{}{}  →  {}",
                t.espace,
                if t.sous_dossier.is_empty() { String::new() } else { format!("/{}", t.sous_dossier) },
                fmt::short_path(&t.destination)
            ))
            .color(ui.visuals().strong_text_color()),
        )
        .on_hover_text(&t.destination);
        if t.mode == "miroir" {
            ui.label(
                RichText::new(if t.corbeille > 0 {
                    tf("Miroir : ce qui est supprimé dans oCIS l'est aussi ici, gardé {0} jours dans .corbeille-oCIS", &[&t.corbeille])
                } else {
                    tr("Miroir : ce qui est supprimé dans oCIS l'est aussi ici (sans corbeille)").into()
                })
                .small()
                .weak(),
            );
        }
        if let Some(d) = &t.dernier {
            if !running {
                let txt = tf("Dernier passage {0} : {1}", &[&(fmt::ago(d.fin, now)), &d.detail]);
                match d.etat.as_str() {
                    "OK" => {
                        ui.label(RichText::new(txt).small());
                    }
                    "ECHEC" => {
                        ui.colored_label(ERR, RichText::new(txt).small());
                        crate::explain::show(ui, &d.detail);
                    }
                    _ => {
                        ui.colored_label(WARN, RichText::new(txt).small());
                    }
                }
            }
        }
        if !t.debit.is_empty() {
            ui.label(RichText::new(tf("Débit limité : {0}", &[&(fmt::bw_human(&t.debit))])).small().weak());
        }
        if t.horaire != "manuel" && t.horaire != "une-fois" {
            if let Some(n) = fmt::next_run_sched(&t.horaire) {
                ui.label(RichText::new(tf("Prochain passage : {0}", &[&n])).small().weak());
            }
        }
    });
}

fn load_tr_spaces(app: &mut App) {
    let Some(f) = &mut app.ocis_ui.tr_form else {
        return;
    };
    f.spaces_loading = true;
    f.spaces_error.clear();
    let h = f.host;
    app.exec(
        h,
        tr("Espaces oCIS"),
        remote::tr_spaces(h),
        60,
        Box::new(move |app, r| {
            let Some(f) = &mut app.ocis_ui.tr_form else {
                return;
            };
            f.spaces_loading = false;
            match r {
                Ok(o) if o.code == 0 => {
                    f.spaces = crate::model::parse_spaces(&o.stdout);
                    if f.spaces.is_empty() {
                        f.spaces_error = tr("Aucun espace oCIS visible pour ce compte.").into();
                    }
                }
                Ok(o) => f.spaces_error = o.text(),
                Err(e) => f.spaces_error = e.to_string(),
            }
        }),
    );
}

fn browse_tr(app: &mut App, path: String) {
    let Some(f) = &mut app.ocis_ui.tr_form else {
        return;
    };
    if f.space_id.is_empty() {
        return;
    }
    f.browse_path = path.clone();
    f.browse_loading = true;
    f.browse_entries.clear();
    let (h, sp) = (f.host, f.space_id.clone());
    app.exec(
        h,
        tr("Dossiers de l'espace oCIS"),
        remote::tr_browse(h, &sp, &path),
        120,
        Box::new(move |app, r| {
            let Some(f) = &mut app.ocis_ui.tr_form else {
                return;
            };
            if f.browse_path != path {
                return;
            }
            f.browse_loading = false;
            match r {
                Ok(o) if o.code == 0 => f.browse_entries = o.stdout.lines().filter(|l| !l.trim().is_empty()).map(String::from).collect(),
                Ok(o) => f.spaces_error = o.text(),
                Err(e) => f.spaces_error = e.to_string(),
            }
        }),
    );
}

fn clean_name(s: &str) -> String {
    let mut n: String = s
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else if c.is_alphabetic() {
                deaccent(c)
            } else {
                '_'
            }
        })
        .collect();
    while n.contains("__") {
        n = n.replace("__", "_");
    }
    n.trim_matches('_').chars().take(30).collect()
}

fn deaccent(c: char) -> char {
    match c {
        'à' | 'â' | 'ä' | 'á' => 'a',
        'é' | 'è' | 'ê' | 'ë' => 'e',
        'î' | 'ï' => 'i',
        'ô' | 'ö' => 'o',
        'ù' | 'û' | 'ü' => 'u',
        'ç' => 'c',
        'À' | 'Â' => 'A',
        'É' | 'È' | 'Ê' => 'E',
        _ => '_',
    }
}

pub fn tr_form_window(app: &mut App, ctx: &egui::Context) {
    let Some(mut f) = app.ocis_ui.tr_form.take() else {
        return;
    };
    let mut open = true;
    let mut save = false;
    let mut cancel = false;
    let mut browse_dest = false;
    let mut nav: Option<String> = None;
    let mut reload = false;
    egui::Window::new(RichText::new(if f.new { tf("Nouveau transfert oCIS → {0}", &[&label(f.host)]) } else { tf("Modifier le transfert « {0} »", &[&f.name]) }).strong())
        .id(egui::Id::unique("trform"))
        .collapsible(false)
        .resizable(false)
        .default_width(620.0)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            egui::ScrollArea::vertical().max_height((ctx.content_rect().height() - 160.0).max(200.0)).show(ui, |ui| {
                egui::Grid::new("trgrid").num_columns(2).spacing([12.0, 10.0]).show(ui, |ui| {
                    ui.label(tr("Espace oCIS"));
                    ui.horizontal(|ui| {
                        let sel = if f.space_name.is_empty() { tr("Choisir…").to_string() } else { f.space_name.clone() };
                        let mut pick: Option<Space> = None;
                        egui::ComboBox::from_id_salt("trspace").width(300.0).selected_text(sel).show_ui(ui, |ui| {
                            for sp in &f.spaces {
                                let lab = if sp.kind == "personal" { format!("\u{E4C2} {}", sp.name) } else { sp.name.clone() };
                                if ui.selectable_label(f.space_id == sp.id, lab).clicked() {
                                    pick = Some(sp.clone());
                                }
                            }
                        });
                        if let Some(sp) = pick {
                            if sp.id != f.space_id {
                                f.space_id = sp.id.clone();
                                f.space_name = sp.name.clone();
                                f.sub.clear();
                                f.browse_entries.clear();
                                if f.browse {
                                    nav = Some(String::new());
                                }
                                if f.new && !f.name_touched {
                                    f.name = clean_name(&sp.name);
                                }
                            }
                        }
                        if f.spaces_loading {
                            ui.spinner();
                        } else if ui.button("\u{E094}").on_hover_text(tr("Relire les espaces")).clicked() {
                            reload = true;
                        }
                    });
                    ui.end_row();

                    ui.label(tr("Dossier dans l'espace"));
                    ui.horizontal(|ui| {
                        ui.add(egui::TextEdit::singleline(&mut f.sub).desired_width(300.0).hint_text(tr("vide = tout l'espace")));
                        if ui.add_enabled(!f.space_id.is_empty(), egui::Button::new(if f.browse { tr("Fermer") } else { tr("\u{E24A} Parcourir") })).clicked() {
                            f.browse = !f.browse;
                            if f.browse {
                                nav = Some(f.sub.trim_matches('/').to_string());
                            }
                        }
                    });
                    ui.end_row();
                    if f.browse {
                        ui.label("");
                        ui.vertical(|ui| {
                            ui.horizontal(|ui| {
                                if ui.add_enabled(!f.browse_path.is_empty(), egui::Button::new("\u{E08E}")).on_hover_text(tr("Remonter")).clicked() {
                                    nav = Some(f.browse_path.rsplit_once('/').map(|(a, _)| a.to_string()).unwrap_or_default());
                                }
                                ui.label(RichText::new(if f.browse_path.is_empty() { tr("(racine de l'espace)").to_string() } else { format!("/{}", f.browse_path) }).strong());
                                if f.browse_loading {
                                    ui.spinner();
                                }
                                if ui.small_button(tr("Choisir ce dossier")).clicked() {
                                    f.sub = f.browse_path.clone();
                                    f.browse = false;
                                }
                            });
                            egui::Frame::new().fill(ui.visuals().extreme_bg_color).corner_radius(6.0).inner_margin(egui::Margin::same(6)).show(ui, |ui| {
                                egui::ScrollArea::vertical().max_height(150.0).auto_shrink([false, true]).show(ui, |ui| {
                                    if f.browse_entries.is_empty() && !f.browse_loading {
                                        ui.label(RichText::new(tr("(aucun sous-dossier)")).weak());
                                    }
                                    for e in &f.browse_entries {
                                        let full = if f.browse_path.is_empty() { e.clone() } else { format!("{}/{e}", f.browse_path) };
                                        if ui.add(egui::Button::selectable(f.sub == full, format!("\u{E24A} {e}")).min_size(egui::vec2(300.0, 0.0))).double_clicked() {
                                            nav = Some(full.clone());
                                        } else if ui.ctx().input(|_| false) {
                                        }
                                    }
                                });
                            });
                            ui.label(RichText::new(tr("Double-clic pour ouvrir un dossier, puis « Choisir ce dossier ».")).small().weak());
                        });
                        ui.end_row();
                    }

                    ui.label(tf("Destination ({0})", &[&label(f.host)]));
                    ui.horizontal(|ui| {
                        ui.add(egui::TextEdit::singleline(&mut f.dest).desired_width(300.0).hint_text(if f.host == HostId::Syno {
                            "/volume1/…"
                        } else {
                            "/srv/dev-disk-by-uuid-…/…"
                        }));
                        if ui.button(tr("\u{E24A} Parcourir")).clicked() {
                            browse_dest = true;
                        }
                    });
                    ui.end_row();
                    if !f.space_name.is_empty() && !f.dest.trim().is_empty() {
                        ui.label("");
                        ui.label(
                            RichText::new(tf(
                                "Le contenu de « {0} » arrive directement dans {1} (dossier créé s'il manque).",
                                &[&(if f.sub.trim().is_empty() { f.space_name.clone() } else { f.sub.trim().to_string() }), &(f.dest.trim())],
                            ))
                            .small()
                            .weak(),
                        );
                        ui.end_row();
                    }

                    ui.label(tr("Mode"));
                    ui.vertical(|ui| {
                        ui.radio_value(&mut f.mirror, false, tr("Copie : rien n'est jamais supprimé dans la destination"));
                        ui.radio_value(&mut f.mirror, true, tr("Miroir : la destination suit oCIS (ce qui y est supprimé l'est aussi ici)"));
                        if f.mirror {
                            ui.horizontal(|ui| {
                                ui.label(tr("Garder les fichiers supprimés ou remplacés"));
                                ui.add(egui::TextEdit::singleline(&mut f.trash).desired_width(40.0));
                                ui.label(tr("jours (0 = pas de corbeille)"));
                            });
                        }
                    });
                    ui.end_row();

                    ui.label(tr("Quand"));
                    ui.vertical(|ui| {
                        ui.radio_value(&mut f.when, 0, tr("Ponctuel : maintenant, une seule fois (retiré de la liste après un succès)"));
                        ui.radio_value(&mut f.when, 1, tr("À la demande (bouton Lancer)"));
                        ui.radio_value(&mut f.when, 2, tr("Programmé : sauvegarde régulière d'oCIS vers le NAS"));
                        if f.when == 2 {
                            f.sched.ui(ui);
                        }
                    });
                    ui.end_row();

                    ui.label(tr("Limite de débit"));
                    f.bw.ui(ui);
                    ui.end_row();

                    ui.label(tr("Nom"));
                    ui.add_enabled_ui(f.new, |ui| {
                        if ui.add(egui::TextEdit::singleline(&mut f.name).desired_width(200.0).hint_text("Photos-oCIS")).changed() {
                            f.name_touched = true;
                        }
                    });
                    ui.end_row();
                });
                if !f.spaces_error.is_empty() {
                    ui.colored_label(ERR, &f.spaces_error);
                }
                ui.label(
                    RichText::new(tr("Un seul transfert à la fois par machine : les autres attendent dans la file. Une notification signale la fin (ou un échec).")).small().weak(),
                );
                if !f.error.is_empty() {
                    ui.colored_label(ERR, &f.error);
                }
                ui.add_space(6.0);
                ui.horizontal(|ui| {
                    let txt = if f.when == 0 && f.new { tr("Enregistrer et lancer") } else { tr("Enregistrer") };
                    if primary_button(ui, txt).clicked() {
                        save = true;
                    }
                    if ui.button(tr("Annuler")).clicked() {
                        cancel = true;
                    }
                });
            });
        });
    if !open || cancel {
        return;
    }
    if browse_dest {
        let start = f.dest.trim().rsplit_once('/').map(|(a, _)| a.to_string()).unwrap_or_default();
        let h = f.host;
        app.ocis_ui.tr_form = Some(f);
        app.open_browser(h, BrowsePurpose::TrDest, &start);
        return;
    }
    if save {
        let sched = match f.when {
            0 => Ok("une-fois".to_string()),
            1 => Ok("manuel".to_string()),
            _ => f.sched.build(),
        };
        let trash = f.trash.trim().parse::<u32>();
        let trash_n = trash.as_ref().ok().copied().unwrap_or(0);
        let valid_name = !f.name.is_empty() && f.name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
        f.error = if f.space_id.is_empty() {
            tr("Choisis l'espace oCIS.").into()
        } else if !f.dest.trim().starts_with('/') || f.dest.trim() == "/" {
            tr("Choisis le dossier de destination (chemin complet).").into()
        } else if !valid_name {
            tr("Nom invalide (lettres, chiffres, - et _).").into()
        } else if f.mirror && trash.is_err() {
            tr("Nombre de jours invalide.").into()
        } else if let Err(e) = &sched {
            e.clone()
        } else if let Err(e) = f.bw.build() {
            e
        } else {
            String::new()
        };
        if f.error.is_empty() {
            let schedule = sched.unwrap_or_default();
            let bw = f.bw.build().unwrap_or_default();
            let dest = f.dest.trim().trim_end_matches('/').to_string();
            let sub = f.sub.trim().trim_matches('/').to_string();
            let script = remote::tr_save(
                f.host,
                f.new,
                &remote::TrSave {
                    name: &f.name,
                    space: &f.space_id,
                    sub: &sub,
                    dest: &dest,
                    mode: if f.mirror { "miroir" } else { "copie" },
                    trash_days: if f.mirror { trash_n } else { 0 },
                    schedule: &schedule,
                    bwlimit: &bw,
                },
            );
            let h = f.host;
            let name = f.name.clone();
            let title = if f.new { tf("Nouveau transfert « {0} »", &[&name]) } else { tf("Transfert « {0} »", &[&name]) };
            if f.mirror {
                app.ask_confirm(
                    tr("Transfert miroir"),
                    &tf(
                        "En miroir, ce qui n'est pas (ou plus) dans oCIS est retiré de {0}{1}. Choisis un dossier dédié à ce transfert.",
                        &[&dest, &(if trash_n > 0 { tf(" (gardé {0} jours dans .corbeille-oCIS)", &[&trash_n]) } else { String::new() })],
                    ),
                    tr("Enregistrer"),
                    true,
                    None,
                    Box::new(move |app| app.action_dialog(h, &title, script, 120)),
                );
            } else {
                app.action_dialog(h, &title, script, 120);
            }
            return;
        }
    }
    app.ocis_ui.tr_form = Some(f);
    if reload {
        load_tr_spaces(app);
    }
    if let Some(p) = nav {
        browse_tr(app, p);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn noms() {
        assert_eq!(clean_name("Documents partagés"), "Documents_partages");
        assert_eq!(clean_name("Été 2024 / photos"), "Ete_2024_photos");
        assert_eq!(sched_text("manuel"), "À la demande");
        let s = crate::model::parse_spaces("a|Perso|https://x/dav/spaces/a|9|10|personal\nb|Projet|https://x/dav/spaces/b|-1|0\n");
        assert_eq!((s.len(), s[0].kind.as_str(), s[1].kind.as_str(), s[1].quota), (2, "personal", "project", 0));
    }
}
