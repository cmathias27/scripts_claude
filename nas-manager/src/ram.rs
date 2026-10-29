//! Memoire attribuee a rclone : reglage de chaque machine (profil, limite en Mo,
//! fichiers en parallele) et surcharge par sauvegarde.

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::app::{App, HostId};
use crate::model::Perf;
use crate::ssh::sq;
use crate::theme::{ERR, OK, WARN};
use eframe::egui::{self, RichText};

pub const PROFILES: [&str; 4] = ["auto", "econome", "equilibre", "performant"];

pub fn profile_label(p: &str) -> &'static str {
    match p {
        "auto" => tr("Automatique (selon la mémoire de la machine)"),
        "econome" => tr("Économe (petit NAS)"),
        "equilibre" => tr("Équilibré"),
        "performant" => tr("Performant"),
        _ => tr("Réglage de la machine"),
    }
}

pub fn profile_short(p: &str) -> &'static str {
    match p {
        "auto" => tr("automatique"),
        "econome" => tr("économe"),
        "equilibre" => tr("équilibré"),
        "performant" => tr("performant"),
        _ => "",
    }
}

/// Texte d'une surcharge de sauvegarde ("" = machine)
pub fn job_memory_text(v: &str) -> String {
    if v.is_empty() {
        tr("réglage de la machine").into()
    } else if v.chars().all(|c| c.is_ascii_digit()) {
        tf("{0} Mo", &[&v])
    } else {
        profile_short(v).into()
    }
}

/// Choix de la memoire d'une sauvegarde : machine, profil ou nombre de Mo
pub fn job_memory_ui(ui: &mut egui::Ui, id: &str, v: &mut String) {
    let custom = !v.is_empty() && v.chars().all(|c| c.is_ascii_digit());
    ui.horizontal(|ui| {
        egui::ComboBox::from_id_salt(id)
            .width(230.0)
            .selected_text(if custom { tr("Limite en Mo").to_string() } else if v.is_empty() { tr("Réglage de la machine").to_string() } else { profile_label(v).to_string() })
            .show_ui(ui, |ui| {
                if ui.selectable_label(v.is_empty(), tr("Réglage de la machine")).clicked() {
                    v.clear();
                }
                for p in &PROFILES[1..] {
                    if ui.selectable_label(v == p, profile_label(p)).clicked() {
                        *v = p.to_string();
                    }
                }
                if ui.selectable_label(custom, tr("Limite en Mo")).clicked() && !custom {
                    *v = "256".into();
                }
            });
        if custom {
            ui.add(egui::TextEdit::singleline(v).desired_width(60.0));
            ui.label(tr("Mo"));
        }
    });
}

pub fn valid_job_memory(v: &str) -> bool {
    v.is_empty() || PROFILES.contains(&v) || v.parse::<u32>().map(|n| n >= 64).unwrap_or(false)
}

/// Formulaire de reglage d'une machine
#[derive(Clone, Default)]
pub struct RamEdit {
    pub loaded: bool,
    pub profil: String,
    pub manual: bool,
    pub mo: String,
    pub transferts: String,
    pub verifs: String,
    pub tampon: String,
    /// limite de debit commune (nas-debian 2.6+)
    pub bw: crate::sched::BwEdit,
    pub bw_loaded: bool,
}

impl RamEdit {
    fn from(p: &Perf) -> Self {
        Self {
            loaded: true,
            profil: if p.profil.is_empty() { "auto".into() } else { p.profil.clone() },
            manual: !p.mo.is_empty(),
            mo: if p.mo.is_empty() { p.effectif.mo.to_string() } else { p.mo.clone() },
            transferts: p.transferts.clone(),
            verifs: p.verifs.clone(),
            tampon: p.tampon.clone(),
            bw: crate::sched::BwEdit::parse(&p.debit),
            bw_loaded: false,
        }
    }
}

fn perf_of(app: &App, h: HostId) -> Option<(Perf, i64)> {
    match h {
        HostId::Omv => app.omv.status.as_ref().and_then(|s| s.perf.clone().map(|p| (p, s.memoire.total_mo))),
        HostId::Syno => app.syno.status.as_ref().and_then(|s| s.perf.clone().map(|p| (p, s.memoire.total_mo))),
    }
}

/// Carte « Mémoire de rclone » d'une machine
pub fn card(app: &mut App, ui: &mut egui::Ui, h: HostId) {
    let i = crate::extras::idx(h);
    let Some((perf, total)) = perf_of(app, h) else {
        ui.label(RichText::new(tr("Disponible une fois le script de la machine installé.")).weak());
        return;
    };
    if !app.install.ram[i].loaded {
        // le debit se recharge a part (carte « Débit selon l'heure ») : edition en cours gardee
        let keep = (app.install.ram[i].bw.clone(), app.install.ram[i].bw_loaded);
        app.install.ram[i] = RamEdit::from(&perf);
        if keep.1 {
            (app.install.ram[i].bw, app.install.ram[i].bw_loaded) = keep;
        }
    }
    let total = if total > 0 { total } else { perf.ram_total_mo };
    ui.label(tf(
        "Mémoire de la machine : {0} Mo ({1} Mo libres) · rclone utilise actuellement : profil {2}, limite {3} Mo ({4})",
        &[&total, &perf.ram_dispo_mo, &(profile_short(&perf.effectif.profil)), &perf.effectif.mo, &perf.effectif.options],
    ));
    let e = &mut app.install.ram[i];
    ui.add_space(4.0);
    for p in PROFILES {
        if h == HostId::Syno && p == "auto" {
            ui.radio_value(&mut e.profil, p.to_string(), tr("Automatique (équilibré sur le Synology)"));
        } else {
            ui.radio_value(&mut e.profil, p.to_string(), profile_label(p));
        }
    }
    ui.horizontal(|ui| {
        ui.checkbox(&mut e.manual, tr("Limite de mémoire fixe :"));
        ui.add_enabled(e.manual, egui::TextEdit::singleline(&mut e.mo).desired_width(60.0));
        ui.label(tr("Mo"));
    });
    egui::CollapsingHeader::new(tr("Avancé")).id_salt(("ramadv", i)).show(ui, |ui| {
        egui::Grid::new(("ramgrid", i)).num_columns(2).spacing([10.0, 6.0]).show(ui, |ui| {
            ui.label(tr("Fichiers envoyés en parallèle"));
            ui.add(egui::TextEdit::singleline(&mut e.transferts).hint_text(tr("selon le profil")).desired_width(90.0));
            ui.end_row();
            ui.label(tr("Vérifications en parallèle"));
            ui.add(egui::TextEdit::singleline(&mut e.verifs).hint_text(tr("selon le profil")).desired_width(90.0));
            ui.end_row();
            if h == HostId::Omv {
                ui.label(tr("Tampon de lecture"));
                ui.add(egui::TextEdit::singleline(&mut e.tampon).hint_text(tr("ex. 0, 16M")).desired_width(90.0));
                ui.end_row();
            }
        });
    });
    let mo: Option<u32> = if e.manual { e.mo.trim().parse().ok() } else { None };
    let err = if e.manual && mo.map(|m| m < 64).unwrap_or(true) {
        tr("Limite invalide : un nombre de Mo, 64 au minimum.")
    } else if !e.transferts.trim().is_empty() && e.transferts.trim().parse::<u8>().map(|n| n == 0 || n > 99).unwrap_or(true) {
        tr("Nombre de fichiers en parallèle invalide (1 à 99).")
    } else if !e.verifs.trim().is_empty() && e.verifs.trim().parse::<u8>().map(|n| n == 0 || n > 99).unwrap_or(true) {
        tr("Nombre de vérifications invalide (1 à 99).")
    } else {
        ""
    };
    if !err.is_empty() {
        ui.colored_label(ERR, err);
    } else if let Some(m) = mo {
        if total > 0 && m as i64 > total * 3 / 4 {
            ui.colored_label(WARN, tf("Attention : {0} Mo, c'est plus des 3/4 de la mémoire de la machine ({1} Mo) : risque de blocage.", &[&m, &total]));
        }
    }
    ui.label(
        RichText::new(tr("Limite « douce » : rclone libère sa mémoire en priorité pour rester en dessous. Après un manque de mémoire, la sauvegarde reprend automatiquement avec un seul fichier à la fois. Chaque sauvegarde peut avoir son propre réglage."))
            .small()
            .weak(),
    );
    let e = e.clone();
    ui.horizontal(|ui| {
        if ui.add_enabled(err.is_empty(), egui::Button::new(tr("Appliquer"))).clicked() {
            let bin = if h == HostId::Omv { crate::remote::DEBIAN_BIN } else { crate::remote::SYNO_BIN };
            let d = |s: &str| if s.trim().is_empty() { "-".to_string() } else { s.trim().to_string() };
            let script = format!(
                "{bin} reglages ram {} {} {} {} {} 2>&1\n",
                sq(&e.profil),
                sq(&mo.map(|m| m.to_string()).unwrap_or_else(|| "-".into())),
                sq(&d(&e.transferts)),
                sq(&d(&e.verifs)),
                sq(&d(&e.tampon))
            );
            app.install.ram[i].loaded = false;
            app.action_toast(h, tr("Mémoire de rclone"), script, 30);
        }
        if ui.small_button(tr("Annuler les modifications")).clicked() {
            app.install.ram[i].loaded = false;
        }
    });
    let _ = OK;
}

/// « Débit selon l'heure » d'une machine Debian / OMV : limite commune à toutes les
/// sauvegardes (programmées, temps réel, versionnées) qui n'ont pas la leur
pub fn bw_card(app: &mut App, ui: &mut egui::Ui) {
    let api = app.omv.status.as_ref().map(|s| s.nb_api).unwrap_or(0);
    let Some((perf, _)) = perf_of(app, HostId::Omv) else {
        ui.label(RichText::new(tr("Disponible une fois le script de la machine installé.")).weak());
        return;
    };
    if api < 11 {
        ui.label(RichText::new(tr("Mets à jour le script de la machine (carte 1) pour régler le débit selon l'heure.")).weak());
        return;
    }
    let e = &mut app.install.ram[0];
    if !e.bw_loaded {
        e.bw = crate::sched::BwEdit::parse(&perf.debit);
        e.bw_loaded = true;
    }
    ui.label(match perf.debit.as_str() {
        "" | "off" => tr("Actuellement : aucune limite commune.").to_string(),
        d => tf("Actuellement : {0}", &[&(crate::fmt::bw_human(d))]),
    });
    if e.bw.mode == 0 && perf.debit.is_empty() {
        // premier reglage : proposer le cas courant (2 Mo/s de 8 h a 23 h)
        e.bw.value = if e.bw.value.is_empty() { "2".into() } else { e.bw.value.clone() };
    }
    e.bw.ui(ui);
    ui.label(
        RichText::new(tr("S'applique aux sauvegardes programmées et temps réel de la machine qui n'ont pas leur propre limite (formulaire de chaque sauvegarde : « Réglage de la machine »). Les restaurations et vérifications restent à pleine vitesse."))
            .small()
            .weak(),
    );
    let built = e.bw.build();
    if let Err(m) = &built {
        ui.colored_label(ERR, m);
    }
    ui.horizontal(|ui| {
        if ui.add_enabled(built.is_ok(), egui::Button::new(tr("Appliquer"))).clicked() {
            let v = built.clone().unwrap_or_default();
            let script = format!("{} reglages debit {} 2>&1\n", crate::remote::DEBIAN_BIN, sq(if v.is_empty() { "-" } else { &v }));
            app.install.ram[0].bw_loaded = false;
            app.action_toast(HostId::Omv, tr("Débit selon l'heure"), script, 30);
        }
        if ui.small_button(tr("Annuler les modifications")).clicked() {
            app.install.ram[0].bw_loaded = false;
        }
    });
}
