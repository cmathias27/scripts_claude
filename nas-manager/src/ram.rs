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
        app.install.ram[i] = RamEdit::from(&perf);
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
