//! Icone dans la zone de notification (Windows), notifications Windows,
//! demarrage avec Windows. Hors Windows : sans effet (journal uniquement).

#![cfg_attr(not(windows), allow(dead_code))]

use crate::app::{App, HostId};
use crate::model::{OmvStatus, SynoStatus};
use eframe::egui;
use std::sync::atomic::{AtomicBool, Ordering};

/// Demande d'affichage de la fenetre (clic sur une notification)
static SHOW_REQUEST: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Level {
    Ok,
    Busy,
    Warn,
    Problem,
}

/// Etat global et resume pour l'infobulle
pub fn summary(app: &App) -> (Level, String) {
    let mut problems: Vec<String> = Vec::new();
    let mut busy: Vec<String> = Vec::new();
    let mut lines: Vec<String> = Vec::new();
    for h in [HostId::Omv, HostId::Syno] {
        if !app.host_cfg(h).is_set() {
            continue;
        }
        if let Some(e) = app.host_error(h) {
            problems.push(format!("{} : {}", h.label(), short_err(&e.to_string())));
        }
    }
    if let Some(s) = &app.omv.status {
        let n = s.sauvegardes.len();
        let ko = s.sauvegardes.iter().filter(|j| !j.en_cours && j.dernier_etat.as_deref() == Some("ECHEC")).count();
        let run: Vec<&str> = s.sauvegardes.iter().filter(|j| j.en_cours).map(|j| j.nom.as_str()).collect();
        if ko > 0 {
            problems.push(format!("{ko} sauvegarde(s) en échec"));
        }
        if !run.is_empty() {
            busy.push(format!("sauvegarde {}", run.join(", ")));
        }
        if s.cameras.installe && !s.cameras.actif {
            problems.push("caméras arrêtées".into());
        }
        if !s.alertes.is_empty() {
            problems.push(format!("{} alerte(s)", s.alertes.len()));
        }
        lines.push(format!("{n} sauvegarde(s), {} OK", n - ko));
    }
    if let Some(s) = &app.syno.status {
        if s.copie.en_cours {
            busy.push(format!(
                "copie {}",
                s.copie.avancement.as_ref().map(|p| format!("{} %", p.pct)).unwrap_or_default()
            ));
        }
        if s.migration.en_cours {
            busy.push("migration oCIS".into());
        }
    }
    let level = if !problems.is_empty() {
        Level::Problem
    } else if !busy.is_empty() {
        Level::Busy
    } else if app.omv.status.is_none() && app.syno.status.is_none() {
        Level::Warn
    } else {
        Level::Ok
    };
    let mut tip = String::from("NAS Manager");
    for p in problems.iter().take(3) {
        tip.push_str(&format!("\n⚠ {p}"));
    }
    for b in busy.iter().take(2) {
        tip.push_str(&format!("\n▶ {b}"));
    }
    if problems.is_empty() && busy.is_empty() {
        for l in lines {
            tip.push_str(&format!("\n{l}"));
        }
    }
    // l'infobulle Windows est limitee a 127 caracteres
    let tip: String = tip.chars().take(120).collect();
    (level, tip)
}

fn short_err(e: &str) -> String {
    e.chars().take(40).collect()
}

/// Icone 32x32 : baies de disque + pastille de couleur selon l'etat
pub fn icon_rgba(level: Level) -> Vec<u8> {
    let n = 32usize;
    let mut rgba = vec![0u8; n * n * 4];
    let dot = match level {
        Level::Ok => [46, 160, 87, 255],
        Level::Busy => [52, 120, 220, 255],
        Level::Warn => [214, 145, 30, 255],
        Level::Problem => [208, 64, 64, 255],
    };
    for y in 0..n {
        for x in 0..n {
            let (fx, fy) = (x as f32 + 0.5, y as f32 + 0.5);
            let i = (y * n + x) * 4;
            let mut c = [0u8; 4];
            let r = 6.0;
            let cx = fx.clamp(r, n as f32 - r);
            let cy = fy.clamp(r, n as f32 - r);
            if (fx - cx).powi(2) + (fy - cy).powi(2) <= r * r {
                c = [37, 99, 235, 255];
                for k in 0..3 {
                    let top = 5.0 + k as f32 * 7.5;
                    if fx > 5.0 && fx < 27.0 && fy > top && fy < top + 5.5 {
                        c = [235, 241, 255, 255];
                    }
                }
            }
            // pastille en bas a droite
            let d = ((fx - 24.5).powi(2) + (fy - 24.5).powi(2)).sqrt();
            if d <= 7.5 {
                c = if d >= 6.0 { [255, 255, 255, 255] } else { dot };
            }
            rgba[i..i + 4].copy_from_slice(&c);
        }
    }
    rgba
}

// =====================================================================
//  Notifications : comparaison de l'etat precedent et du nouvel etat
// =====================================================================

pub fn diff_omv(prev: &OmvStatus, new: &OmvStatus) -> Vec<(String, String)> {
    let mut ev = Vec::new();
    for j in &new.sauvegardes {
        let Some(p) = prev.sauvegardes.iter().find(|p| p.nom == j.nom) else { continue };
        if p.en_cours && !j.en_cours {
            match j.dernier_etat.as_deref() {
                Some("OK") => ev.push((
                    format!("✅ Sauvegarde « {} » terminée", j.nom),
                    j.bilan
                        .as_ref()
                        .map(|b| format!("{} fichier(s) envoyé(s), {}", b.fichiers_envoyes, crate::fmt::bytes(b.volume_octets.max(0) as u64)))
                        .unwrap_or_default(),
                )),
                Some("ECHEC") => ev.push((format!("❌ Sauvegarde « {} » en échec", j.nom), "Voir le journal dans NAS Manager.".into())),
                Some("ARRETE") => ev.push((format!("⏹ Sauvegarde « {} » arrêtée", j.nom), String::new())),
                _ => {}
            }
        }
    }
    for a in &new.alertes {
        if !prev.alertes.iter().any(|p| p.tag == a.tag) {
            ev.push(("🔔 Nouvelle alerte".into(), crate::pages::alert_label(&a.tag)));
        }
    }
    if prev.cameras.installe && prev.cameras.actif && !new.cameras.actif {
        ev.push(("📹 Caméras : synchro arrêtée".into(), "Les vidéos ne partent plus vers le Drive en temps réel.".into()));
    }
    if prev.cameras.installe && !prev.cameras.actif && new.cameras.actif {
        ev.push(("📹 Caméras : synchro relancée".into(), String::new()));
    }
    if let (Some(p), Some(n)) = (&prev.restauration, &new.restauration) {
        if p.etat == "en_cours" && n.etat != "en_cours" {
            ev.push((
                if n.etat == "ok" { "✅ Restauration terminée".into() } else { "❌ Restauration en échec".into() },
                n.cible.clone(),
            ));
        }
    }
    ev
}

pub fn diff_syno(prev: &SynoStatus, new: &SynoStatus) -> Vec<(String, String)> {
    let mut ev = Vec::new();
    if prev.copie.en_cours && !new.copie.en_cours {
        let name = new.copie.source.as_deref().unwrap_or("").rsplit('/').next().unwrap_or("").to_string();
        match new.copie.code.as_deref() {
            Some("0") => ev.push(("✅ Copie vers l'OMV terminée".into(), name)),
            Some("stop") => ev.push(("⏹ Copie vers l'OMV arrêtée".into(), name)),
            _ => ev.push(("❌ Copie vers l'OMV en échec".into(), format!("{name} — la relancer reprendra où elle s'est arrêtée"))),
        }
    }
    if prev.migration.en_cours && !new.migration.en_cours {
        let ko = new.migration.resultats.iter().filter(|r| r.etat != "OK").count();
        let ok = new.migration.resultats.len() - ko;
        ev.push((
            if ko == 0 { "✅ Migration oCIS terminée".into() } else { "⚠ Migration oCIS terminée avec des erreurs".into() },
            format!("{ok} réussie(s), {ko} en échec"),
        ));
    }
    ev
}

/// Affiche une notification Windows (sans effet ailleurs)
pub fn notify(ctx: &egui::Context, title: &str, body: &str) {
    crate::log::info(&format!("notification : {title} {body}"));
    #[cfg(windows)]
    {
        let (t, b, c) = (title.to_string(), body.to_string(), ctx.clone());
        std::thread::spawn(move || {
            use tauri_winrt_notification::Toast;
            // SAFETY: initialisation COM du fil (necessaire aux API WinRT)
            unsafe {
                windows_sys::Win32::System::Com::CoInitializeEx(
                    std::ptr::null(),
                    windows_sys::Win32::System::Com::COINIT_MULTITHREADED as u32,
                );
            }
            let mut toast = Toast::new(Toast::POWERSHELL_APP_ID).title(&t);
            if !b.is_empty() {
                toast = toast.text1(&b);
            }
            let toast = toast.on_activated(move |_| {
                SHOW_REQUEST.store(true, Ordering::SeqCst);
                c.request_repaint();
                Ok(())
            });
            if let Err(e) = toast.show() {
                crate::log::warn(&format!("notification impossible : {e:?}"));
            }
        });
    }
    #[cfg(not(windows))]
    {
        let _ = ctx;
    }
}

// =====================================================================
//  Icone de la zone de notification
// =====================================================================

#[cfg(windows)]
pub struct Tray {
    icon: tray_icon::TrayIcon,
    open_id: tray_icon::menu::MenuId,
    refresh_id: tray_icon::menu::MenuId,
    quit_id: tray_icon::menu::MenuId,
    level: Level,
    tip: String,
}

#[cfg(not(windows))]
pub struct Tray;

#[cfg(windows)]
pub fn create(app: &App) -> Option<Tray> {
    use tray_icon::menu::{Menu, MenuItem, PredefinedMenuItem};
    let (level, tip) = summary(app);
    let open = MenuItem::new("Ouvrir NAS Manager", true, None);
    let refresh = MenuItem::new("Actualiser", true, None);
    let quit = MenuItem::new("Quitter", true, None);
    let menu = Menu::new();
    let ok = menu.append(&open).is_ok()
        && menu.append(&refresh).is_ok()
        && menu.append(&PredefinedMenuItem::separator()).is_ok()
        && menu.append(&quit).is_ok();
    if !ok {
        return None;
    }
    let icon = tray_icon::Icon::from_rgba(icon_rgba(level), 32, 32).ok()?;
    match tray_icon::TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_menu_on_left_click(false)
        .with_tooltip(&tip)
        .with_icon(icon)
        .build()
    {
        Ok(t) => Some(Tray {
            icon: t,
            open_id: open.id().clone(),
            refresh_id: refresh.id().clone(),
            quit_id: quit.id().clone(),
            level,
            tip,
        }),
        Err(e) => {
            crate::log::warn(&format!("icône de notification impossible : {e}"));
            None
        }
    }
}

#[cfg(not(windows))]
pub fn create(_app: &App) -> Option<Tray> {
    None
}

/// Evenements de l'icone et mise a jour de son etat (appele a chaque tour)
pub fn update(app: &mut App, ctx: &egui::Context) {
    if SHOW_REQUEST.swap(false, Ordering::SeqCst) {
        show_window(app, ctx);
    }
    #[cfg(windows)]
    {
        use tray_icon::menu::MenuEvent;
        use tray_icon::{MouseButton, MouseButtonState, TrayIconEvent};
        let (level, tip) = summary(app);
        let mut actions: Vec<u8> = Vec::new();
        if let Some(t) = &mut app.tray {
            while let Ok(ev) = TrayIconEvent::receiver().try_recv() {
                match ev {
                    TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } => actions.push(0),
                    TrayIconEvent::DoubleClick { .. } => actions.push(0),
                    _ => {}
                }
            }
            while let Ok(ev) = MenuEvent::receiver().try_recv() {
                if ev.id == t.open_id {
                    actions.push(0);
                } else if ev.id == t.refresh_id {
                    actions.push(1);
                } else if ev.id == t.quit_id {
                    actions.push(2);
                }
            }
            if level != t.level {
                if let Ok(i) = tray_icon::Icon::from_rgba(icon_rgba(level), 32, 32) {
                    let _ = t.icon.set_icon(Some(i));
                }
                t.level = level;
            }
            if tip != t.tip {
                let _ = t.icon.set_tooltip(Some(&tip));
                t.tip = tip;
            }
        }
        for a in actions {
            match a {
                0 => show_window(app, ctx),
                1 => {
                    app.refresh(HostId::Omv);
                    app.refresh(HostId::Syno);
                }
                _ => {
                    app.quitting = true;
                    ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
            }
        }
    }
}

pub fn show_window(app: &mut App, ctx: &egui::Context) {
    app.hidden = false;
    ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
    ctx.send_viewport_cmd(egui::ViewportCommand::Minimized(false));
    ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
}

pub fn hide_window(app: &mut App, ctx: &egui::Context) {
    app.hidden = true;
    ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
}

// =====================================================================
//  Demarrage avec Windows (cle Run du registre, via reg.exe)
// =====================================================================

const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
const RUN_NAME: &str = "NAS Manager";

#[cfg(windows)]
fn reg(args: &[&str]) -> bool {
    use std::os::windows::process::CommandExt;
    std::process::Command::new("reg")
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .creation_flags(0x0800_0000)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub fn autostart_supported() -> bool {
    cfg!(windows)
}

pub fn autostart_enabled() -> bool {
    #[cfg(windows)]
    {
        reg(&["query", RUN_KEY, "/v", RUN_NAME])
    }
    #[cfg(not(windows))]
    {
        false
    }
}

pub fn set_autostart(on: bool) -> Result<(), String> {
    #[cfg(windows)]
    {
        let ok = if on {
            let exe = std::env::current_exe().map_err(|e| e.to_string())?;
            let value = format!("\"{}\" --minimise", exe.display());
            reg(&["add", RUN_KEY, "/v", RUN_NAME, "/t", "REG_SZ", "/d", &value, "/f"])
        } else {
            reg(&["delete", RUN_KEY, "/v", RUN_NAME, "/f"])
        };
        if ok {
            Ok(())
        } else {
            Err("modification du registre impossible".into())
        }
    }
    #[cfg(not(windows))]
    {
        let _ = (on, RUN_KEY, RUN_NAME);
        Err("disponible uniquement sous Windows".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::*;

    #[test]
    fn notifications_fin_de_transfert() {
        let job = |run: bool, st: &str| Job { nom: "Photos".into(), en_cours: run, dernier_etat: Some(st.into()), ..Default::default() };
        let prev = OmvStatus { sauvegardes: vec![job(true, "OK")], ..Default::default() };
        let mut new = OmvStatus { sauvegardes: vec![job(false, "ECHEC")], ..Default::default() };
        new.alertes.push(Alert { tag: "job-Photos".into(), depuis: 0 });
        let ev = diff_omv(&prev, &new);
        assert_eq!(ev.len(), 2);
        assert!(ev[0].0.contains("échec"));
        assert!(ev[1].1.contains("Photos"));
        // rien a signaler si l'etat ne change pas
        assert!(diff_omv(&new, &new).is_empty());
        let mut p = SynoStatus::default();
        p.copie.en_cours = true;
        let mut n = SynoStatus::default();
        n.copie.code = Some("0".into());
        n.copie.source = Some("/volume1/photo".into());
        let ev = diff_syno(&p, &n);
        assert_eq!(ev, vec![("✅ Copie vers l'OMV terminée".to_string(), "photo".to_string())]);
    }

    #[test]
    fn icone() {
        let a = icon_rgba(Level::Ok);
        let b = icon_rgba(Level::Problem);
        assert_eq!(a.len(), 32 * 32 * 4);
        assert_ne!(a, b);
    }
}
