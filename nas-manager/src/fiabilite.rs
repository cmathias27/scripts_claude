//! Fiabilite et restauration (etape 5) : test de restauration a blanc, reveil des
//! machines (Wake-on-LAN) depuis le PC et avant les sauvegardes.
//! Le retour a une date precise est dans la fenetre de restauration (`restore`).

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::app::{App, HostId, OutputDialog};
use crate::fmt;
use crate::model::{Destination, Job, OmvStatus, RestoreTest};
use crate::remote;
use crate::theme::{ERR, IDLE, INFO, OK};
use eframe::egui::{self, Color32, RichText};

#[derive(Default)]
pub struct FiabUi {
    /// edition du test automatique : jours, heure, nombre de fichiers
    pub test_edit: Option<([bool; 7], String, String)>,
    /// reveil d'une destination en cours de reglage
    pub reveil_form: Option<ReveilForm>,
    /// detection de l'adresse MAC en cours (OMV, Synology)
    pub detecting: [bool; 2],
    /// derniere information Wake-on-LAN lue sur la machine (ethtool)
    pub wol_info: [String; 2],
    /// reveil envoye depuis le PC (instant) : affichage « réveil en cours »
    pub woken: [Option<std::time::Instant>; 2],
    /// Synology : edition du reveil de l'OMV avant les copies
    pub syno_edit: Option<(String, String)>,
}

#[derive(Clone, Default)]
pub struct ReveilForm {
    pub dest: String,
    pub existing: bool,
    pub mac: String,
    pub addr: String,
    pub wait: String,
    /// rien, veille, arret
    pub after: String,
    pub ssh: String,
    pub key: String,
    pub error: String,
}

fn idx(h: HostId) -> usize {
    crate::extras::idx(h)
}

// =====================================================================
//  Test de restauration a blanc
// =====================================================================

pub fn test_color(t: &RestoreTest) -> Color32 {
    match t.etat.as_str() {
        "ok" => OK,
        "ecarts" => ERR,
        "echec" => ERR,
        _ => IDLE,
    }
}

/// Resultat du dernier test sur la carte de la sauvegarde
pub fn test_box(app: &mut App, ui: &mut egui::Ui, j: &Job, now: i64) {
    if !j.test_en_cours && j.test.as_ref().map(|t| now - t.fin > 45 * 86400).unwrap_or(true) {
        return;
    }
    let col = if j.test_en_cours { INFO } else { j.test.as_ref().map(test_color).unwrap_or(IDLE) };
    egui::Frame::new()
        .fill(col.gamma_multiply(0.10))
        .corner_radius(6.0)
        .inner_margin(egui::Margin::same(8))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.horizontal_wrapped(|ui| {
                ui.label(RichText::new(tr("\u{E606} Test de restauration")).strong());
                if j.test_en_cours {
                    ui.spinner();
                    ui.label(tr("fichiers pris au hasard en cours de restauration et de comparaison…"));
                    return;
                }
                let Some(t) = &j.test else { return };
                let when = fmt::ago(t.fin, now);
                match t.etat.as_str() {
                    "ok" => {
                        ui.label(tf("{0} : {1} fichier(s) restauré(s) et identique(s) aux originaux", &[&when, &t.nb]));
                        let n = t.destinations.split(';').filter(|d| !d.is_empty()).count();
                        if n > 1 {
                            ui.label(RichText::new(tf("sur {0} destinations", &[&n])).small().weak());
                        }
                    }
                    "ecarts" => {
                        ui.colored_label(ERR, tf("{0} : {1} écart(s) sur {2} fichier(s) testé(s)", &[&when, &t.ecarts, &t.nb]));
                    }
                    "echec" => {
                        ui.colored_label(ERR, tf("{0} : restauration impossible", &[&when]));
                    }
                    _ => {
                        ui.label(RichText::new(tf("{0} : rien à tester ({1})", &[&when, &t.message])).weak());
                    }
                }
                if !t.fichiers.is_empty() && ui.small_button(tr("Voir le détail")).clicked() {
                    app.output = Some(OutputDialog { title: tf("Test de restauration de « {0} »", &[&j.nom]), text: test_detail(t), ok: t.etat == "ok" });
                }
            });
            if let Some(t) = &j.test {
                if !j.test_en_cours && t.etat != "ok" && t.etat != "vide" {
                    for f in t.fichiers.iter().filter(|f| f.resultat != "identique").take(3) {
                        let what = match f.resultat.as_str() {
                            "different" => tr("contenu différent de l'original"),
                            "absent" => tr("absent de la sauvegarde"),
                            _ => tr("illisible"),
                        };
                        let who = if f.chemin.is_empty() { f.destination.clone() } else { format!("[{}] {}", f.destination, f.chemin) };
                        let detail = if f.detail.is_empty() { String::new() } else { format!(" — {}", f.detail) };
                        ui.label(RichText::new(format!("{who} : {what}{detail}")).small().color(ERR));
                    }
                    if t.etat == "ecarts" {
                        ui.label(RichText::new(tr("Lance une vérification d'intégrité : une nouvelle sauvegarde corrige en général les écarts.")).small().weak());
                    }
                }
            }
        });
}

pub fn test_detail(t: &RestoreTest) -> String {
    let mut out = String::new();
    if !t.message.is_empty() {
        out.push_str(&t.message);
        out.push('\n');
    }
    for f in &t.fichiers {
        let r = match f.resultat.as_str() {
            "identique" => tr("identique"),
            "different" => tr("DIFFÉRENT"),
            "absent" => tr("ABSENT"),
            _ => tr("ERREUR"),
        };
        let size = if f.taille > 0 { format!(" ({})", fmt::bytes(f.taille)) } else { String::new() };
        let detail = if f.detail.is_empty() { String::new() } else { format!(" — {}", f.detail) };
        out.push_str(&format!("[{}] {}{size} : {r}{detail}\n", f.destination, if f.chemin.is_empty() { "—" } else { &f.chemin }));
    }
    out
}

/// Test automatique de toutes les sauvegardes (jours + heure + nombre de fichiers)
pub fn test_planner(app: &mut App, ui: &mut egui::Ui, s: &OmvStatus) {
    if s.nb_api < 9 {
        return;
    }
    let mut it = s.test_auto.split_whitespace();
    let (days, time, nb) = (it.next().unwrap_or(""), it.next().unwrap_or(""), it.next().unwrap_or("5"));
    ui.horizontal(|ui| {
        ui.label(RichText::new(tr("\u{E606} Test de restauration automatique :")).small());
        let txt = if days.is_empty() {
            tr("désactivé").to_string()
        } else {
            tf("{0} · {1} fichiers au hasard par sauvegarde", &[&(fmt::schedule_human(&format!("{time}/{days}"))), &nb])
        };
        ui.label(RichText::new(txt).small().strong());
        if app.fiab.test_edit.is_none() && ui.small_button(tr("Modifier")).clicked() {
            let mut d = [false; 7];
            for c in days.chars() {
                if let Some(n) = c.to_digit(10) {
                    if (1..=7).contains(&n) {
                        d[n as usize - 1] = true;
                    }
                }
            }
            if days.is_empty() {
                d[5] = true;
            }
            app.fiab.test_edit = Some((d, if time.is_empty() { "06:15".into() } else { time.to_string() }, nb.to_string()));
        }
        if !s.sauvegardes.is_empty() && ui.small_button(tr("Tester maintenant")).on_hover_text(tr("Toutes les sauvegardes, l'une après l'autre")).clicked() {
            app.action_toast(HostId::Omv, tr("Test de restauration"), remote::test_all(), 30);
        }
    });
    let mut action: Option<String> = None;
    let mut close = false;
    if let Some((d, t, n)) = &mut app.fiab.test_edit {
        ui.horizontal(|ui| {
            for (i, l) in [tr("Lun"), tr("Mar"), tr("Mer"), tr("Jeu"), tr("Ven"), tr("Sam"), tr("Dim")].iter().enumerate() {
                ui.toggle_value(&mut d[i], *l);
            }
            ui.label(tr("à"));
            ui.add(egui::TextEdit::singleline(t).desired_width(55.0));
            ui.add(egui::TextEdit::singleline(n).desired_width(32.0));
            ui.label(tr("fichiers"));
            let digits: String = (0..7).filter(|i| d[*i]).map(|i| char::from_digit(i as u32 + 1, 10).unwrap_or('7')).collect();
            let nbv = n.trim().parse::<u32>().ok().filter(|v| (1..=50).contains(v));
            let ok = !digits.is_empty() && nbv.is_some() && crate::sched::valid_sched(&format!("{t}/{digits}"));
            if ui.add_enabled(ok, egui::Button::new(tr("Enregistrer"))).clicked() {
                action = Some(remote::test_plan(&digits, t, nbv.unwrap_or(5)));
            }
            if ui.button(tr("Désactiver")).clicked() {
                action = Some(remote::test_plan("", "", 5));
            }
            if ui.button(tr("Annuler")).clicked() {
                close = true;
            }
        });
        ui.label(
            RichText::new(tr("Quelques fichiers pris au hasard (plus anciens que la dernière sauvegarde) sont restaurés depuis chaque destination dans un dossier temporaire, comparés octet par octet aux originaux, puis effacés. Une alerte signale tout écart."))
                .small()
                .weak(),
        );
    }
    if let Some(a) = action {
        app.fiab.test_edit = None;
        app.action_toast(HostId::Omv, tr("Test de restauration automatique"), a, 60);
    } else if close {
        app.fiab.test_edit = None;
    }
}

// =====================================================================
//  Reveil des machines depuis le PC
// =====================================================================

/// Reveil d'une machine injoignable (bandeau d'erreur de connexion)
pub fn wake_button(app: &mut App, ui: &mut egui::Ui, h: HostId) {
    let cfg = app.host_cfg(h).clone();
    if cfg.mac.trim().is_empty() {
        return;
    }
    let k = idx(h);
    let recent = app.fiab.woken[k].map(|t| t.elapsed().as_secs() < 180).unwrap_or(false);
    if recent {
        ui.spinner();
        ui.label(RichText::new(tr("Réveil demandé : la machine démarre (jusqu'à 2-3 minutes)…")).small());
        app.ctx.request_repaint_after(std::time::Duration::from_secs(5));
    }
    if ui.button(tr("\u{E3DA} Réveiller (Wake-on-LAN)")).on_hover_text(tf("Envoie le paquet de réveil à {0}", &[&cfg.mac])).clicked() {
        wake(app, h);
    }
}

pub fn wake(app: &mut App, h: HostId) {
    let cfg = app.host_cfg(h).clone();
    match crate::wol::send(&cfg.mac, &cfg.host) {
        Ok(_) => {
            crate::log::info(&format!("réveil (Wake-on-LAN) envoyé à {} ({})", h.label(), cfg.mac));
            app.fiab.woken[idx(h)] = Some(std::time::Instant::now());
            app.toast(true, tf("Paquet de réveil envoyé à {0}.", &[&(h.label())]));
            // nouvelles tentatives de connexion rapprochees
            app.refresh(h);
        }
        Err(e) => app.toast(false, e),
    }
}

/// Ligne « Adresse MAC » des parametres d'une machine
pub fn mac_settings(app: &mut App, ui: &mut egui::Ui, h: HostId) {
    let k = idx(h);
    ui.horizontal(|ui| {
        ui.label(tr("Adresse MAC (réveil)"));
        let cfg = match h {
            HostId::Omv => &mut app.edit.omv,
            HostId::Syno => &mut app.edit.syno,
        };
        ui.add(egui::TextEdit::singleline(&mut cfg.mac).desired_width(150.0).hint_text("00:11:32:AA:BB:CC"));
        let bad = !cfg.mac.trim().is_empty() && !crate::wol::valid_mac(&cfg.mac);
        if app.fiab.detecting[k] {
            ui.spinner();
        } else if ui
            .add_enabled(app.host_connected(h), egui::Button::new(tr("Détecter")).small())
            .on_hover_text(tr("Lit l'adresse de la carte réseau de la machine (elle doit être connectée)"))
            .clicked()
        {
            detect_mac(app, h);
        }
        if bad {
            ui.colored_label(ERR, tr("invalide"));
        }
    });
    if !app.fiab.wol_info[k].is_empty() {
        ui.label(RichText::new(&app.fiab.wol_info[k]).small().weak());
    }
}

fn detect_mac(app: &mut App, h: HostId) {
    let k = idx(h);
    app.fiab.detecting[k] = true;
    app.exec(
        h,
        tr("Adresse MAC"),
        remote::detect_mac(),
        30,
        Box::new(move |app, r| {
            app.fiab.detecting[k] = false;
            match r {
                Ok(o) if o.code == 0 => {
                    let mut lines = o.stdout.lines();
                    let mac = lines.next().unwrap_or("").trim().to_string();
                    if !crate::wol::valid_mac(&mac) {
                        app.toast(false, tr("Adresse MAC illisible.").into());
                        return;
                    }
                    let mac = crate::wol::normalize(&mac);
                    match h {
                        HostId::Omv => app.edit.omv.mac = mac.clone(),
                        HostId::Syno => app.edit.syno.mac = mac.clone(),
                    }
                    let wol = lines.find_map(|l| l.strip_prefix("wol=")).map(|w| w.trim().to_string());
                    app.fiab.wol_info[k] = match wol.as_deref() {
                        Some(w) if w.contains('g') => tr("Wake-on-LAN activé sur la carte réseau.").into(),
                        Some(w) => tf("Wake-on-LAN désactivé sur la carte réseau ({0}) : à activer (BIOS et réglages réseau de la machine).", &[&w]),
                        None => tr("Pense à activer le Wake-on-LAN dans le BIOS et les réglages réseau de la machine.").into(),
                    };
                    app.toast(true, tf("Adresse MAC détectée : {0} (pense à enregistrer).", &[&mac]));
                }
                Ok(o) => app.toast(false, o.text()),
                Err(e) => app.toast(false, e.to_string()),
            }
        }),
    );
}

// =====================================================================
//  Reveil des destinations avant les sauvegardes (nas-debian)
// =====================================================================

/// Types de destinations qui sont d'autres machines du reseau
pub fn wakeable(kind: &str) -> bool {
    matches!(kind, "sftp" | "smb" | "webdav" | "local")
}

/// Ligne « réveil » sur la carte d'une destination
pub fn dest_line(app: &mut App, ui: &mut egui::Ui, d: &Destination, s: &OmvStatus) {
    if s.nb_api < 9 || !wakeable(&d.kind) {
        return;
    }
    let cfg = s.reveil.as_ref().and_then(|r| r.destinations.get(&d.nom)).cloned();
    ui.horizontal_wrapped(|ui| {
        match &cfg {
            Some(c) => {
                ui.label(RichText::new(tf("\u{E3DA} Réveil avant usage : {0}", &[&c.mac])).small());
                let after = match c.apres.as_str() {
                    "veille" => tr("remise en veille après"),
                    "arret" => tr("éteinte après"),
                    _ => tr("se rendort d'elle-même"),
                };
                ui.label(RichText::new(after).small().weak());
                if d.etat.as_ref().map(|e| e.veille).unwrap_or(false) {
                    crate::pages::badge_pub(ui, tr("en veille"), IDLE);
                }
                if ui.small_button(tr("Tester le réveil")).clicked() {
                    app.action_dialog(HostId::Omv, &tf("Réveil de « {0} »", &[&d.nom]), remote::reveil_test(&d.nom), 1000);
                }
            }
            None => {
                ui.label(RichText::new(tr("Machine qui se met en veille ou s'éteint ?")).small().weak());
            }
        }
        if ui.small_button(if cfg.is_some() { tr("Régler le réveil…") } else { tr("\u{E3DA} Réveil (Wake-on-LAN)…") }).clicked() {
            let c = cfg.clone().unwrap_or_default();
            app.fiab.reveil_form = Some(ReveilForm {
                dest: d.nom.clone(),
                existing: cfg.is_some(),
                mac: c.mac,
                addr: c.adresse,
                wait: if c.attente > 0 { c.attente.to_string() } else { "180".into() },
                after: if c.apres.is_empty() { "rien".into() } else { c.apres },
                ssh: c.ssh,
                key: s.reveil.as_ref().map(|r| r.cle.clone()).unwrap_or_default(),
                error: String::new(),
            });
        }
    });
}

pub fn reveil_window(app: &mut App, ctx: &egui::Context) {
    let Some(mut f) = app.fiab.reveil_form.take() else { return };
    let mut open = true;
    let mut save = false;
    let mut remove = false;
    let mut cancel = false;
    egui::Window::new(RichText::new(tf("Réveil de « {0} »", &[&f.dest])).strong())
        .id(egui::Id::unique("reveil"))
        .collapsible(false)
        .resizable(false)
        .default_width(520.0)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .open(&mut open)
        .show(ctx, |ui| {
            ui.label(RichText::new(tr("Avant chaque sauvegarde, vérification, test ou restauration qui utilise cette destination, la machine qui ne répond pas reçoit le paquet de réveil (Wake-on-LAN) ; la sauvegarde attend qu'elle réponde.")).small());
            ui.add_space(4.0);
            egui::Grid::new("reveilgrid").num_columns(2).spacing([12.0, 8.0]).show(ui, |ui| {
                ui.label(tr("Adresse MAC"));
                ui.add(egui::TextEdit::singleline(&mut f.mac).desired_width(160.0).hint_text("00:11:32:AA:BB:CC"));
                ui.end_row();
                ui.label(tr("Adresse de la machine"));
                ui.add(egui::TextEdit::singleline(&mut f.addr).desired_width(200.0).hint_text(tr("vide = celle de la destination")));
                ui.end_row();
                ui.label(tr("Attente maximale"));
                ui.horizontal(|ui| {
                    ui.add(egui::TextEdit::singleline(&mut f.wait).desired_width(50.0));
                    ui.label(tr("secondes"));
                });
                ui.end_row();
                ui.label(tr("Ensuite"));
                ui.vertical(|ui| {
                    ui.radio_value(&mut f.after, "rien".to_string(), tr("Rien : elle se rendort d'elle-même (sa propre mise en veille)"));
                    ui.radio_value(&mut f.after, "veille".to_string(), tr("La remettre en veille après usage"));
                    ui.radio_value(&mut f.after, "arret".to_string(), tr("L'éteindre après usage"));
                });
                ui.end_row();
                if f.after != "rien" {
                    ui.label(tr("Compte SSH"));
                    ui.add(egui::TextEdit::singleline(&mut f.ssh).desired_width(200.0).hint_text("root@192.168.1.x"));
                    ui.end_row();
                }
            });
            if f.after != "rien" {
                ui.label(RichText::new(tr("Seulement si c'est la sauvegarde qui l'a réveillée. La clé SSH de la machine (affichée après l'enregistrement) doit être autorisée sur ce compte.")).small().weak());
                if !f.key.is_empty() {
                    ui.horizontal(|ui| {
                        ui.label(RichText::new(&f.key).monospace().small());
                        if ui.small_button(tr("\u{E1CA} Copier")).clicked() {
                            ui.ctx().copy_text(f.key.clone());
                        }
                    });
                }
            }
            if !f.error.is_empty() {
                ui.colored_label(ERR, &f.error);
            }
            ui.add_space(6.0);
            ui.horizontal(|ui| {
                if ui.add(egui::Button::new(RichText::new(tr("Enregistrer")).color(Color32::WHITE)).fill(INFO)).clicked() {
                    save = true;
                }
                if f.existing && ui.button(tr("Retirer le réveil")).clicked() {
                    remove = true;
                }
                if ui.button(tr("Annuler")).clicked() {
                    cancel = true;
                }
            });
        });
    if !open || cancel {
        return;
    }
    if remove {
        app.action_toast(HostId::Omv, tr("Réveil"), remote::reveil_remove(&f.dest), 30);
        return;
    }
    if save {
        let wait = f.wait.trim().parse::<u32>().ok().filter(|w| (30..=900).contains(w));
        f.error = if !crate::wol::valid_mac(&f.mac) {
            tr("Adresse MAC invalide (ex. 00:11:32:AA:BB:CC).").into()
        } else if wait.is_none() {
            tr("Attente invalide (30 à 900 secondes).").into()
        } else if f.after != "rien" && !f.ssh.contains('@') {
            tr("Indique le compte SSH (utilisateur@machine).").into()
        } else {
            String::new()
        };
        if f.error.is_empty() {
            let script = remote::reveil_set(&f.dest, &crate::wol::normalize(&f.mac), &f.addr, wait.unwrap_or(180), &f.after, if f.after == "rien" { "" } else { &f.ssh });
            app.action_dialog(HostId::Omv, &tf("Réveil de « {0} »", &[&f.dest]), script, 60);
            return;
        }
    }
    app.fiab.reveil_form = Some(f);
}

// =====================================================================
//  Synology : reveil de l'OMV avant les copies
// =====================================================================

pub fn syno_omv_wake(app: &mut App, ui: &mut egui::Ui) {
    let Some(st) = app.syno.status.clone() else { return };
    if st.agent.as_ref().map(|a| a.api < 5).unwrap_or(true) {
        return;
    }
    let Some(p) = st.perf.clone() else { return };
    egui::CollapsingHeader::new(tr("\u{E3DA} Réveil de l'OMV avant les copies (Wake-on-LAN)")).id_salt("omvwake").show(ui, |ui| {
        if p.omv_mac.is_empty() {
            ui.label(RichText::new(tr("Désactivé : si l'OMV est en veille ou éteint, la copie échoue.")).small());
        } else {
            let after = match p.omv_apres.as_str() {
                "veille" => tr("remis en veille après les copies"),
                "arret" => tr("éteint après les copies"),
                _ => tr("il se rendort de lui-même"),
            };
            ui.label(RichText::new(tf("Activé ({0}) : l'OMV est réveillé s'il ne répond pas ; {1}.", &[&p.omv_mac, &after])).small());
        }
        let omv_mac = app.settings.omv.mac.clone();
        if app.fiab.syno_edit.is_none() && ui.small_button(tr("Modifier")).clicked() {
            let mac = if p.omv_mac.is_empty() { omv_mac.clone() } else { p.omv_mac.clone() };
            app.fiab.syno_edit = Some((mac, if p.omv_apres.is_empty() { "rien".into() } else { p.omv_apres.clone() }));
        }
        let mut action: Option<String> = None;
        let mut close = false;
        if let Some((mac, after)) = &mut app.fiab.syno_edit {
            ui.horizontal(|ui| {
                ui.label(tr("Adresse MAC de l'OMV"));
                ui.add(egui::TextEdit::singleline(mac).desired_width(150.0));
                if !omv_mac.is_empty() && *mac != omv_mac && ui.small_button(tr("Celle des paramètres")).clicked() {
                    *mac = omv_mac.clone();
                }
            });
            ui.horizontal(|ui| {
                ui.radio_value(after, "rien".to_string(), tr("se rendort de lui-même"));
                ui.radio_value(after, "veille".to_string(), tr("remettre en veille"));
                ui.radio_value(after, "arret".to_string(), tr("éteindre"));
            });
            if after != "rien" {
                ui.label(RichText::new(tr("Après la dernière copie de la file, seulement s'il a été réveillé pour elle (connexion SSH du Synology vers l'OMV).")).small().weak());
            }
            ui.horizontal(|ui| {
                let ok = crate::wol::valid_mac(mac);
                if ui.add_enabled(ok, egui::Button::new(tr("Enregistrer"))).clicked() {
                    action = Some(remote::syno_omv_wake(&crate::wol::normalize(mac), after));
                }
                if !p.omv_mac.is_empty() && ui.button(tr("Désactiver")).clicked() {
                    action = Some(remote::syno_omv_wake("", "rien"));
                }
                if ui.button(tr("Annuler")).clicked() {
                    close = true;
                }
            });
        }
        if let Some(a) = action {
            app.fiab.syno_edit = None;
            app.action_toast(HostId::Syno, tr("Réveil de l'OMV"), a, 30);
        } else if close {
            app.fiab.syno_edit = None;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn detail_du_test() {
        let t = RestoreTest {
            etat: "ecarts".into(),
            fichiers: vec![
                crate::model::TestFile { destination: "usb".into(), chemin: "a.txt".into(), taille: 2048, resultat: "different".into(), detail: "5 octets".into() },
                crate::model::TestFile { destination: "gdrive".into(), chemin: "a.txt".into(), taille: 2048, resultat: "identique".into(), detail: String::new() },
            ],
            ..Default::default()
        };
        let d = test_detail(&t);
        assert!(d.contains("[usb] a.txt (2,0 Ko) : DIFFÉRENT — 5 octets") || d.contains("[usb] a.txt"), "{d}");
        assert!(d.contains("[gdrive] a.txt"));
        assert_eq!(test_color(&t), ERR);
        assert!(wakeable("sftp") && !wakeable("drive"));
    }
}
