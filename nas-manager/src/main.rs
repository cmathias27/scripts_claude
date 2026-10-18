//! NAS Manager : suivi et gestion des sauvegardes / synchronisations du NAS
//! (OMV + Synology) depuis Windows, sans ouvrir de session SSH.

#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]

mod app;
mod charts;
mod explain;
mod history;
mod config;
mod extras;
mod fmt;
mod log;
mod model;
mod pages;
mod remote;
mod restore;
mod sched;
mod secret;
mod ssh;
mod theme;
mod tray;

use eframe::egui;

/// Icone de la fenetre dessinee a la main (disque + fleche de synchro)
fn icon() -> egui::IconData {
    let n = 64usize;
    let mut rgba = vec![0u8; n * n * 4];
    for y in 0..n {
        for x in 0..n {
            let (fx, fy) = (x as f32 + 0.5, y as f32 + 0.5);
            let i = (y * n + x) * 4;
            // fond arrondi bleu
            let r = 14.0;
            let cx = fx.clamp(r, n as f32 - r);
            let cy = fy.clamp(r, n as f32 - r);
            let inside = (fx - cx).powi(2) + (fy - cy).powi(2) <= r * r;
            if !inside {
                continue;
            }
            let mut c = [37u8, 99, 235, 255];
            // trois baies de disque
            for k in 0..3 {
                let top = 12.0 + k as f32 * 14.0;
                if fx > 12.0 && fx < 52.0 && fy > top && fy < top + 10.0 {
                    c = [235, 241, 255, 255];
                    if fx > 42.0 && fx < 47.0 && fy > top + 3.0 && fy < top + 7.0 {
                        c = [34, 197, 94, 255];
                    }
                }
            }
            rgba[i..i + 4].copy_from_slice(&c);
        }
    }
    egui::IconData { rgba, width: n as u32, height: n as u32 }
}

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("NAS Manager")
            .with_inner_size([1240.0, 800.0])
            .with_min_inner_size([900.0, 560.0])
            .with_icon(icon())
            .with_visible(!std::env::args().any(|a| a == "--minimise")),
        persist_window: true,
        ..Default::default()
    };
    eframe::run_native(
        "NAS Manager",
        options,
        Box::new(|cc| Ok(Box::new(app::App::new(cc)))),
    )
}
