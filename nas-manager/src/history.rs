//! Page « Historique » : executions des sauvegardes, volumes, taux de reussite,
//! evolution de l'espace (Google Drive et disques de l'OMV).

use crate::app::{App, HostId};
use crate::charts::{self, Series};
use crate::fmt;
use crate::model::{History, Run};
use crate::remote;
use crate::theme::{self, ERR, INFO, OK, WARN};
use chrono::{Local, TimeZone};
use eframe::egui::{self, Color32, RichText};

#[derive(Default)]
pub struct HistoryState {
    pub data: Option<History>,
    pub loading: bool,
    pub error: String,
    pub job: String,
    pub last_fetch: Option<std::time::Instant>,
    pub days: u32,
}

pub fn load(app: &mut App) {
    if app.history.loading {
        return;
    }
    app.history.loading = true;
    app.history.last_fetch = Some(std::time::Instant::now());
    app.exec(
        HostId::Omv,
        "Lecture de l'historique",
        remote::OMV_HISTORY.to_string(),
        60,
        Box::new(|app, r| {
            app.history.loading = false;
            match r {
                Ok(o) => match o.stdout.lines().rev().find(|l| l.starts_with('{')).map(serde_json::from_str::<History>) {
                    Some(Ok(h)) => {
                        app.history.data = Some(h);
                        app.history.error.clear();
                    }
                    _ => app.history.error = format!("Réponse inattendue : {}", o.text().lines().last().unwrap_or("")),
                },
                Err(e) => app.history.error = e.to_string(),
            }
        }),
    );
}

fn day_key(ts: i64) -> String {
    Local.timestamp_opt(ts, 0).single().map(|d| d.format("%Y-%m-%d").to_string()).unwrap_or_default()
}

fn short_day(ts: i64) -> String {
    Local.timestamp_opt(ts, 0).single().map(|d| d.format("%d/%m").to_string()).unwrap_or_default()
}

fn run_color(r: &Run) -> Color32 {
    match r.etat.as_str() {
        "OK" => OK,
        "ECHEC" => ERR,
        "ARRETE" => WARN,
        _ => theme::IDLE,
    }
}

fn kpi(ui: &mut egui::Ui, title: &str, value: String, col: Color32) {
    theme::card_frame(ui).show(ui, |ui| {
        ui.set_min_width(150.0);
        ui.label(RichText::new(title).small().weak());
        ui.label(RichText::new(value).size(20.0).strong().color(col));
    });
}

pub fn page(app: &mut App, ui: &mut egui::Ui) {
    ui.heading("Historique");
    ui.label(RichText::new("Exécutions des sauvegardes et évolution de l'espace").weak());
    ui.add_space(8.0);
    if app.history.days == 0 {
        app.history.days = 30;
    }
    let stale = app.history.last_fetch.map(|t| t.elapsed().as_secs() > 300).unwrap_or(true);
    if stale && app.host_connected(HostId::Omv) {
        load(app);
    }
    ui.horizontal(|ui| {
        if ui.button("⟳ Actualiser").clicked() {
            load(app);
        }
        if app.history.loading {
            ui.spinner();
        }
        let jobs: Vec<String> = app.omv.status.as_ref().map(|s| s.sauvegardes.iter().map(|j| j.nom.clone()).collect()).unwrap_or_default();
        egui::ComboBox::from_id_salt("histjob")
            .selected_text(if app.history.job.is_empty() { "Toutes les sauvegardes".to_string() } else { app.history.job.clone() })
            .show_ui(ui, |ui| {
                ui.selectable_value(&mut app.history.job, String::new(), "Toutes les sauvegardes");
                for j in jobs {
                    ui.selectable_value(&mut app.history.job, j.clone(), j);
                }
            });
        for d in [7u32, 30, 90, 365] {
            ui.selectable_value(&mut app.history.days, d, format!("{d} j"));
        }
    });
    if !app.history.error.is_empty() {
        ui.colored_label(ERR, &app.history.error);
    }
    let Some(h) = app.history.data.clone() else {
        if !app.host_connected(HostId::Omv) {
            ui.label(RichText::new("OMV non connecté.").weak());
        }
        return;
    };
    let now = fmt::now();
    let since = now - app.history.days as i64 * 86400;
    let mut runs: Vec<&Run> = h
        .executions
        .iter()
        .filter(|r| r.fin >= since && (app.history.job.is_empty() || r.nom == app.history.job))
        .collect();
    runs.sort_by_key(|r| r.fin);
    ui.add_space(6.0);

    if h.executions.is_empty() {
        crate::pages::info_banner(
            ui,
            "L'historique se remplit à chaque sauvegarde depuis la mise à jour de nas-backup (version 2). \
Installe-la depuis Paramètres > Scripts sur les NAS si ce n'est pas déjà fait.",
        );
    }

    // ---- indicateurs
    let ok = runs.iter().filter(|r| r.etat == "OK").count();
    let ko = runs.iter().filter(|r| r.etat == "ECHEC").count();
    let vol: i64 = runs.iter().map(|r| r.volume_octets.max(0)).sum();
    let files: i64 = runs.iter().map(|r| r.fichiers_envoyes).sum();
    let avg = if runs.is_empty() { 0.0 } else { runs.iter().map(|r| r.duree_min).sum::<f64>() / runs.len() as f64 };
    ui.horizontal_wrapped(|ui| {
        kpi(ui, "Exécutions", runs.len().to_string(), INFO);
        let rate = if runs.is_empty() { 0.0 } else { ok as f64 * 100.0 / runs.len() as f64 };
        kpi(
            ui,
            "Taux de réussite",
            if runs.is_empty() { "—".into() } else { format!("{rate:.0} %") },
            if ko == 0 { OK } else if rate >= 80.0 { WARN } else { ERR },
        );
        kpi(ui, "Volume envoyé", fmt::bytes(vol as u64), INFO);
        kpi(ui, "Fichiers envoyés", files.to_string(), INFO);
        kpi(ui, "Durée moyenne", format!("{avg:.0} min"), INFO);
    });
    ui.add_space(8.0);

    // ---- volume par jour
    crate::pages::card_pub(ui, "Volume envoyé par jour", |ui| {
        let days = app.history.days.min(90) as i64;
        let mut items = Vec::new();
        for d in (0..days).rev() {
            let t = now - d * 86400;
            let key = day_key(t);
            let day_runs: Vec<&&Run> = runs.iter().filter(|r| day_key(r.fin) == key).collect();
            let v: i64 = day_runs.iter().map(|r| r.volume_octets.max(0)).sum();
            let failed = day_runs.iter().any(|r| r.etat == "ECHEC");
            let col = if failed { ERR } else if day_runs.is_empty() { theme::IDLE } else { INFO };
            let mut tip = format!("{} : {}", short_day(t), fmt::bytes(v as u64));
            for r in &day_runs {
                tip.push_str(&format!("\n· {} — {} ({})", r.nom, r.etat, fmt::bytes(r.volume_octets.max(0) as u64)));
            }
            items.push((short_day(t), v as f64, col, tip));
        }
        charts::bars(ui, &items, 160.0, &|v| fmt::bytes(v as u64));
        charts::legend(ui, &[("Envoyé".into(), INFO), ("Jour avec un échec".into(), ERR)]);
    });
    ui.add_space(8.0);

    // ---- executions
    crate::pages::card_pub(ui, &format!("Dernières exécutions ({})", runs.len()), |ui| {
        if runs.is_empty() {
            ui.label(RichText::new("Aucune exécution sur la période.").weak());
        }
        egui::Grid::new("runs").striped(true).num_columns(7).spacing([14.0, 6.0]).show(ui, |ui| {
            for t in ["Date", "Sauvegarde", "État", "Durée", "Fichiers", "Volume", "Supprimés"] {
                ui.label(RichText::new(t).small().strong());
            }
            ui.end_row();
            for r in runs.iter().rev().take(60) {
                ui.label(fmt::date(r.fin));
                ui.label(&r.nom);
                ui.horizontal(|ui| {
                    let (rect, _) = ui.allocate_exact_size(egui::vec2(10.0, 10.0), egui::Sense::hover());
                    ui.painter().circle_filled(rect.center(), 4.5, run_color(r));
                    let l = ui.label(match r.etat.as_str() {
                        "OK" => "OK",
                        "ECHEC" => "Échec",
                        "ARRETE" => "Arrêtée",
                        e => e,
                    });
                    if !r.erreur.is_empty() {
                        l.on_hover_ui(|ui| {
                            ui.set_max_width(420.0);
                            crate::explain::show(ui, &r.erreur);
                        });
                    }
                });
                ui.label(format!("{:.0} min", r.duree_min));
                ui.label(r.fichiers_envoyes.to_string());
                ui.label(fmt::bytes(r.volume_octets.max(0) as u64));
                ui.label(r.retires.to_string());
                ui.end_row();
            }
        });
        if runs.iter().any(|r| !r.erreur.is_empty()) {
            ui.label(RichText::new("Survole un échec pour voir son explication.").small().weak());
        }
    });
    ui.add_space(8.0);

    // ---- espace
    crate::pages::card_pub(ui, "Évolution de l'espace", |ui| {
        let pts: Vec<_> = h.espace.iter().filter(|p| p.t >= since).collect();
        let xl = |x: f64| short_day(x as i64);
        // Google Drive
        let drive: Vec<(f64, f64)> = pts.iter().filter_map(|p| p.drive_go.map(|g| (p.t as f64, g))).collect();
        let total = pts.iter().rev().find_map(|p| p.drive_total_go);
        ui.label(RichText::new("Google Drive").strong());
        charts::lines(
            ui,
            &[Series { name: "Utilisé".into(), color: INFO, points: drive.clone() }],
            130.0,
            &|v| format!("{v:.0} Go"),
            &xl,
            total,
        );
        if let (Some(tot), Some(last)) = (total, drive.last()) {
            match charts::slope(&drive) {
                Some(s) if s > 0.0 => {
                    let days = (tot - last.1) / (s * 86400.0);
                    let col = if days < 30.0 { ERR } else if days < 120.0 { WARN } else { OK };
                    ui.colored_label(
                        col,
                        format!(
                            "{:.1} Go utilisés sur {:.0} Go · +{:.1} Go par mois · plein dans environ {}",
                            last.1,
                            tot,
                            s * 86400.0 * 30.0,
                            if days > 3650.0 { "plus de 10 ans".to_string() } else { fmt::duration((days * 86400.0) as i64) }
                        ),
                    );
                }
                _ => {
                    ui.label(RichText::new(format!("{:.1} Go utilisés sur {:.0} Go · stable", last.1, tot)).small());
                }
            }
        }
        ui.add_space(8.0);
        // disques de l'OMV (%)
        ui.label(RichText::new("Disques de l'OMV (% utilisé)").strong());
        let palette = [INFO, OK, WARN, Color32::from_rgb(150, 100, 220), Color32::from_rgb(40, 170, 170)];
        let mut names: Vec<String> = Vec::new();
        for p in &pts {
            for d in &p.disques {
                if !names.contains(&d.p) {
                    names.push(d.p.clone());
                }
            }
        }
        let series: Vec<Series> = names
            .iter()
            .enumerate()
            .map(|(i, n)| Series {
                name: fmt::short_path(n),
                color: palette[i % palette.len()],
                points: pts
                    .iter()
                    .filter_map(|p| p.disques.iter().find(|d| &d.p == n).filter(|d| d.s > 0).map(|d| (p.t as f64, d.u as f64 * 100.0 / d.s as f64)))
                    .collect(),
            })
            .collect();
        charts::lines(ui, &series, 130.0, &|v| format!("{v:.0} %"), &xl, Some(100.0));
        charts::legend(ui, &series.iter().map(|s| (s.name.clone(), s.color)).collect::<Vec<_>>());
    });
}
