//! Page « Doublons » (étape 8) : fichiers identiques dans les dossiers du NAS (photos
//! notamment), trouvés par `nas-debian doublons` (même taille puis même empreinte). Rien
//! n'est supprimé sans confirmation : les fichiers choisis vont dans une corbeille des
//! doublons sur le même disque, vidée après 30 jours.

use crate::app::{App, BrowsePurpose, HostId};
use crate::fmt;
#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::pages::{badge, banner, card, danger_button, primary_button, progress_bar};
use crate::remote;
use crate::ssh::sq;
use crate::theme::{ERR, INFO, OK, WARN};
use base64::Engine;
use eframe::egui::{self, RichText};
use serde::Deserialize;
use std::collections::BTreeSet;
use std::time::{Duration, Instant};

#[derive(Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct DupFile {
    pub chemin: String,
    pub date: i64,
}

#[derive(Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct DupGroup {
    pub taille: u64,
    pub empreinte: String,
    pub fichiers: Vec<DupFile>,
}

#[derive(Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct DupTrash {
    pub fichiers: u64,
    pub octets: u64,
    pub dates: Vec<String>,
}

/// Sortie de `nas-debian doublons etat | voir`
#[derive(Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct DupState {
    /// aucune, en_cours, fini, erreur, interrompue
    pub etat: String,
    pub etape: String,
    pub debut: i64,
    pub fin: i64,
    pub dossiers: Vec<String>,
    pub min_ko: u64,
    pub fichiers_vus: u64,
    pub octets_vus: u64,
    pub candidats: u64,
    pub pct: i64,
    pub nb_groupes: u64,
    pub fichiers_en_trop: u64,
    pub recuperable: u64,
    pub groupes: Vec<DupGroup>,
    pub corbeille: DupTrash,
    pub erreur: String,
}

pub struct DupUi {
    pub dirs: Vec<String>,
    pub min_kb: String,
    pub state: Option<DupState>,
    pub loading: bool,
    pub last_fetch: Option<Instant>,
    /// chemins choisis pour la corbeille
    pub selected: BTreeSet<String>,
    /// analyse dont la selection par defaut a ete faite (date de fin)
    pub selected_for: i64,
    pub filter: String,
    pub shown: usize,
}

impl Default for DupUi {
    fn default() -> Self {
        Self {
            dirs: Vec::new(),
            min_kb: "100".into(),
            state: None,
            loading: false,
            last_fetch: None,
            selected: BTreeSet::new(),
            selected_for: 0,
            filter: String::new(),
            shown: 50,
        }
    }
}

pub fn nav_badge(app: &App) -> Option<(String, egui::Color32)> {
    match app.dups.state.as_ref().map(|s| s.etat.as_str()) {
        Some("en_cours") => Some((tr("analyse").into(), INFO)),
        _ => None,
    }
}

/// Selection par defaut : dans chaque groupe, tout sauf le plus ancien (premier de la liste)
pub fn default_selection(groups: &[DupGroup]) -> BTreeSet<String> {
    groups.iter().flat_map(|g| g.fichiers.iter().skip(1).map(|f| f.chemin.clone())).collect()
}

/// Volume libere par une selection (un groupe entierement choisi ne compte pas : refuse)
pub fn selection_size(groups: &[DupGroup], sel: &BTreeSet<String>) -> (u64, u64, usize) {
    let (mut n, mut b, mut full) = (0, 0, 0);
    for g in groups {
        let k = g.fichiers.iter().filter(|f| sel.contains(&f.chemin)).count();
        if k == g.fichiers.len() && k > 0 {
            full += 1;
            continue;
        }
        n += k as u64;
        b += k as u64 * g.taille;
    }
    (n, b, full)
}

fn fetch(app: &mut App, groups: bool) {
    if app.dups.loading {
        return;
    }
    app.dups.loading = true;
    app.dups.last_fetch = Some(Instant::now());
    let script = format!("{} doublons {} 2>/dev/null\n", remote::DEBIAN_BIN, if groups { "voir 2000" } else { "etat" });
    app.exec(
        HostId::Omv,
        tr("Doublons"),
        script,
        60,
        Box::new(move |app, r| {
            app.dups.loading = false;
            match r {
                Ok(o) => match serde_json::from_str::<DupState>(o.stdout.lines().last().unwrap_or("")) {
                    Ok(mut st) => {
                        let prev_running = app.dups.state.as_ref().map(|s| s.etat == "en_cours").unwrap_or(false);
                        if !groups {
                            // etat seul : garder la liste deja lue
                            if let Some(old) = &app.dups.state {
                                if old.fin == st.fin {
                                    st.groupes = old.groupes.clone();
                                }
                            }
                        }
                        let finished_now = prev_running && st.etat == "fini";
                        if st.etat == "fini" && st.fin != app.dups.selected_for && !st.groupes.is_empty() {
                            app.dups.selected = default_selection(&st.groupes);
                            app.dups.selected_for = st.fin;
                            app.dups.shown = 50;
                        }
                        if app.dups.dirs.is_empty() {
                            app.dups.dirs = st.dossiers.clone();
                        }
                        app.dups.state = Some(st);
                        if finished_now {
                            app.dups.last_fetch = None;
                            fetch(app, true);
                        }
                    }
                    Err(_) => app.toast(false, tr("Réponse inattendue du NAS (doublons).").into()),
                },
                Err(e) => app.toast(false, e.to_string()),
            }
        }),
    );
}

pub fn page(app: &mut App, ui: &mut egui::Ui) {
    crate::pages::page_title_pub(ui, tr("Doublons"), tr("Fichiers identiques sur le NAS : libérer de la place et réduire le volume des sauvegardes"));
    if !crate::pages::host_banner_pub(app, ui, HostId::Omv) {
        return;
    }
    let api = app.omv.status.as_ref().map(|s| s.nb_api).unwrap_or(0);
    if api < 11 {
        crate::pages::info_banner(ui, tr("La recherche des doublons demande le script nas-debian 2.6 ou plus sur la machine."));
        crate::scripts::widget(app, ui, crate::scripts::Kind::Debian);
        return;
    }
    let running = app.dups.state.as_ref().map(|s| s.etat == "en_cours").unwrap_or(false);
    let every = if running { 3 } else { 60 };
    if app.dups.last_fetch.map(|t| t.elapsed() > Duration::from_secs(every)).unwrap_or(true) {
        let need_groups = app.dups.state.as_ref().map(|s| s.etat == "fini" && s.groupes.is_empty() && s.nb_groupes > 0).unwrap_or(true);
        fetch(app, need_groups);
    }
    banner(
        ui,
        INFO,
        tr("Fichiers identiques au bit près (même taille et même empreinte), quels que soient leur nom et leur dossier. Rien n'est supprimé sans ta confirmation : les fichiers choisis vont dans une corbeille des doublons, sur le même disque, vidée automatiquement après 30 jours."),
    );
    ui.add_space(6.0);

    // ---- analyse
    card(ui, tr("Analyser"), |ui| {
        let mut remove = None;
        for (i, d) in app.dups.dirs.iter().enumerate() {
            ui.horizontal(|ui| {
                ui.label(RichText::new(d).monospace());
                if ui.small_button("✕").on_hover_text(tr("Retirer ce dossier")).clicked() {
                    remove = Some(i);
                }
            });
        }
        if let Some(i) = remove {
            app.dups.dirs.remove(i);
        }
        let mut browse = false;
        ui.horizontal(|ui| {
            if ui.button(tr("\u{E24A} Ajouter un dossier…")).clicked() {
                browse = true;
            }
            ui.label(tr("Taille minimale :"));
            ui.add(egui::TextEdit::singleline(&mut app.dups.min_kb).desired_width(60.0));
            ui.label(tr("Ko"));
        });
        if browse {
            app.open_browser(HostId::Omv, BrowsePurpose::DupDir, "");
        }
        ui.label(RichText::new(tr("L'analyse tourne en arrière-plan sur le NAS, en priorité basse : elle peut prendre du temps sur un gros volume (chaque fichier de même taille qu'un autre est relu en entier).")).small().weak());
        let min_ok = app.dups.min_kb.trim().parse::<u32>().is_ok();
        ui.horizontal(|ui| {
            if running {
                if danger_button(ui, tr("\u{E46C} Arrêter l'analyse")).clicked() && !app.blocked() {
                    app.action_toast(HostId::Omv, tr("Doublons"), format!("{} doublons arreter 2>&1\n", remote::DEBIAN_BIN), 30);
                    app.dups.last_fetch = None;
                }
            } else if ui.add_enabled(!app.dups.dirs.is_empty() && min_ok, egui::Button::new(tr("\u{E30C} Lancer l'analyse"))).clicked() && !app.blocked() {
                let dirs: Vec<String> = app.dups.dirs.iter().map(|d| sq(d)).collect();
                let script = format!("{} doublons analyser --min {} {} 2>&1\n", remote::DEBIAN_BIN, app.dups.min_kb.trim(), dirs.join(" "));
                app.action_toast(HostId::Omv, tr("Doublons"), script, 60);
                app.dups.state = Some(DupState { etat: "en_cours".into(), ..Default::default() });
                app.dups.last_fetch = Some(Instant::now());
            }
        });
    });
    ui.add_space(8.0);

    let Some(st) = app.dups.state.clone() else {
        ui.spinner();
        return;
    };
    let now = fmt::now();
    match st.etat.as_str() {
        "en_cours" => {
            card(ui, tr("Analyse en cours"), |ui| {
                if st.etape == "empreintes" {
                    progress_bar(ui, Some(st.pct), tf("Comparaison du contenu : {0} fichier(s) de même taille", &[&(fmt::count(st.candidats))]));
                } else {
                    progress_bar(ui, None, tf("Inventaire : {0} fichier(s), {1}", &[&(fmt::count(st.fichiers_vus)), &(fmt::bytes(st.octets_vus))]));
                }
                if st.debut > 0 {
                    ui.label(RichText::new(tf("Lancée {0}", &[&(fmt::ago(st.debut, now))])).small().weak());
                }
            });
        }
        "erreur" => {
            banner(ui, ERR, &tf("L'analyse a échoué : {0}", &[&st.erreur]));
        }
        "interrompue" => {
            banner(ui, WARN, tr("L'analyse a été interrompue (NAS redémarré ?) : relance-la."));
        }
        "fini" => results(app, ui, &st, now),
        _ => {
            ui.label(RichText::new(tr("Aucune analyse pour l'instant : choisis un ou plusieurs dossiers (ex. Photos) puis lance l'analyse.")).weak());
        }
    }
    if st.corbeille.fichiers > 0 {
        ui.add_space(8.0);
        card(ui, tr("Corbeille des doublons"), |ui| {
            ui.label(tf(
                "{0} fichier(s), {1} · dossiers .corbeille-doublons des dossiers analysés · vidée automatiquement après 30 jours",
                &[&(fmt::count(st.corbeille.fichiers)), &(fmt::bytes(st.corbeille.octets))],
            ));
            ui.label(RichText::new(tr("Pour récupérer un fichier : le recopier depuis le dossier .corbeille-doublons/<date>/ (même arborescence).")).small().weak());
            if danger_button(ui, tr("Vider maintenant")).clicked() {
                app.ask_confirm(
                    tr("Vider la corbeille des doublons"),
                    &tf("{0} fichier(s) ({1}) seront supprimés définitivement.", &[&(st.corbeille.fichiers), &(fmt::bytes(st.corbeille.octets))]),
                    tr("Vider"),
                    true,
                    None,
                    Box::new(|app| {
                        app.action_toast(HostId::Omv, tr("Doublons"), format!("{} doublons vider 2>&1\n", remote::DEBIAN_BIN), 300);
                        app.dups.last_fetch = None;
                    }),
                );
            }
        });
    }
}

fn results(app: &mut App, ui: &mut egui::Ui, st: &DupState, now: i64) {
    let (n, b, full) = selection_size(&st.groupes, &app.dups.selected);
    card(ui, tr("Résultat"), |ui| {
        ui.horizontal_wrapped(|ui| {
            ui.label(RichText::new(tf("{0} groupe(s) de doublons", &[&(fmt::count(st.nb_groupes))])).strong());
            badge(ui, &tf("{0} fichier(s) en trop", &[&(fmt::count(st.fichiers_en_trop))]), WARN);
            badge(ui, &tf("{0} récupérables", &[&(fmt::bytes(st.recuperable))]), OK);
        });
        ui.label(
            RichText::new(tf(
                "Analyse {0} · {1} fichier(s) examiné(s) ({2}) · fichiers de plus de {3} Ko",
                &[&(fmt::ago(st.fin, now)), &(fmt::count(st.fichiers_vus)), &(fmt::bytes(st.octets_vus)), &(st.min_ko)],
            ))
            .small()
            .weak(),
        );
        if st.groupes.is_empty() {
            if st.nb_groupes == 0 {
                ui.colored_label(OK, tr("Aucun doublon trouvé."));
            } else {
                ui.spinner();
            }
            return;
        }
        ui.add_space(4.0);
        ui.horizontal_wrapped(|ui| {
            if ui.button(tr("Garder le plus ancien de chaque groupe")).clicked() {
                app.dups.selected = default_selection(&st.groupes);
            }
            if ui.button(tr("Ne rien sélectionner")).clicked() {
                app.dups.selected.clear();
            }
            ui.label(tr("Filtrer :"));
            ui.add(egui::TextEdit::singleline(&mut app.dups.filter).hint_text(tr("nom ou dossier")).desired_width(180.0));
        });
        if full > 0 {
            ui.colored_label(ERR, tf("{0} groupe(s) entièrement sélectionné(s) : au moins une copie doit rester, ils seront ignorés.", &[&full]));
        }
        ui.horizontal(|ui| {
            let label = tf("Mettre {0} fichier(s) à la corbeille des doublons (libère {1})", &[&n, &(fmt::bytes(b))]);
            if ui.add_enabled(n > 0, egui::Button::new(RichText::new(label).color(egui::Color32::WHITE)).fill(ERR)).clicked() {
                let list: Vec<String> = st
                    .groupes
                    .iter()
                    .filter(|g| g.fichiers.iter().any(|f| !app.dups.selected.contains(&f.chemin)))
                    .flat_map(|g| g.fichiers.iter().filter(|f| app.dups.selected.contains(&f.chemin)).map(|f| f.chemin.clone()))
                    .collect();
                let b64 = base64::engine::general_purpose::STANDARD.encode(list.join("\n") + "\n");
                let script = format!("echo {} | base64 -d | {} doublons supprimer 2>&1\n", sq(&b64), remote::DEBIAN_BIN);
                app.ask_confirm(
                    tr("Corbeille des doublons"),
                    &tf(
                        "{0} fichier(s) ({1}) vont être déplacés dans la corbeille des doublons. Chacun est relu juste avant : il n'est déplacé que s'il est toujours identique à une copie qui reste en place. Corbeille vidée après 30 jours.",
                        &[&n, &(fmt::bytes(b))],
                    ),
                    tr("Déplacer"),
                    true,
                    None,
                    Box::new(move |app| {
                        app.action_dialog(HostId::Omv, tr("Doublons"), script, 1800);
                        app.dups.last_fetch = None;
                        if let Some(s) = app.dups.state.as_mut() {
                            s.groupes.clear();
                        }
                    }),
                );
            }
        });
    });
    ui.add_space(6.0);
    let filt = app.dups.filter.to_lowercase();
    let groups: Vec<&DupGroup> = st.groupes.iter().filter(|g| filt.is_empty() || g.fichiers.iter().any(|f| f.chemin.to_lowercase().contains(&filt))).collect();
    let total = groups.len();
    for (gi, g) in groups.iter().take(app.dups.shown).enumerate() {
        let name = g.fichiers.first().map(|f| f.chemin.rsplit('/').next().unwrap_or("").to_string()).unwrap_or_default();
        let head = tf("{0} × {1} — {2}", &[&(g.fichiers.len()), &(fmt::bytes(g.taille)), &name]);
        egui::CollapsingHeader::new(RichText::new(head).strong()).id_salt(("dupg", gi, &g.empreinte)).default_open(gi < 5).show(ui, |ui| {
            for f in &g.fichiers {
                let mut on = app.dups.selected.contains(&f.chemin);
                ui.horizontal(|ui| {
                    if ui.checkbox(&mut on, "").on_hover_text(tr("Coché = mis à la corbeille des doublons")).changed() {
                        if on {
                            app.dups.selected.insert(f.chemin.clone());
                        } else {
                            app.dups.selected.remove(&f.chemin);
                        }
                    }
                    let col = if on { ERR } else { OK };
                    ui.label(RichText::new(if on { tr("corbeille") } else { tr("gardé") }).small().color(col));
                    ui.label(RichText::new(&f.chemin).monospace().size(12.5));
                    ui.label(RichText::new(fmt::date(f.date)).small().weak());
                });
            }
        });
    }
    if total > app.dups.shown && ui.button(tf("Afficher plus ({0} groupe(s) restant(s))", &[&(total - app.dups.shown)])).clicked() {
        app.dups.shown += 100;
    }
    let _ = primary_button;
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn selection() {
        let st: DupState = serde_json::from_str(
            r#"{"etat":"fini","groupes":[{"taille":10,"empreinte":"a","fichiers":[{"chemin":"/p/1.jpg","date":1},{"chemin":"/p/2.jpg","date":2},{"chemin":"/p/3.jpg","date":3}]},{"taille":5,"empreinte":"b","fichiers":[{"chemin":"/p/x","date":1},{"chemin":"/p/y","date":2}]}],"corbeille":{"fichiers":0,"octets":0,"dates":[]}}"#,
        )
        .unwrap();
        let sel = default_selection(&st.groupes);
        assert_eq!(sel.iter().cloned().collect::<Vec<_>>(), vec!["/p/2.jpg", "/p/3.jpg", "/p/y"]);
        assert_eq!(selection_size(&st.groupes, &sel), (3, 25, 0));
        let mut all = sel.clone();
        all.insert("/p/x".into());
        // groupe b entierement choisi : ignore
        assert_eq!(selection_size(&st.groupes, &all), (2, 20, 1));
    }
}
