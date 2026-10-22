//! Page « Aide » et assistant de premier lancement.

#[allow(unused_imports)]
use crate::i18n::{tf, tr};
use crate::app::{App, HostId, Page};
use crate::theme::{self, ERR, INFO, OK, WARN};
use eframe::egui::{self, Color32, RichText};

fn section(ui: &mut egui::Ui, title: &str, open: bool, add: impl FnOnce(&mut egui::Ui)) {
    theme::card_frame(ui).show(ui, |ui| {
        ui.set_width(ui.available_width());
        egui::CollapsingHeader::new(RichText::new(title).strong().size(15.0)).default_open(open).show(ui, add);
    });
    ui.add_space(6.0);
}

fn step(ui: &mut egui::Ui, n: usize, text: &str) {
    ui.horizontal_wrapped(|ui| {
        ui.label(RichText::new(format!("{n}.")).strong().color(INFO));
        ui.label(text);
    });
}

fn code(ui: &mut egui::Ui, c: &str) {
    ui.horizontal(|ui| {
        egui::Frame::new()
            .fill(ui.visuals().extreme_bg_color)
            .corner_radius(4.0)
            .inner_margin(egui::Margin::symmetric(6, 3))
            .show(ui, |ui| {
                ui.label(RichText::new(c).monospace());
            });
        if ui.small_button(tr("\u{E1CA}")).on_hover_text(tr("Copier")).clicked() {
            ui.ctx().copy_text(c.to_string());
        }
    });
}

pub fn page(app: &mut App, ui: &mut egui::Ui) {
    ui.heading(tr("Aide"));
    ui.label(RichText::new(tf("NAS Manager {0} — suivi et gestion des sauvegardes et synchros du NAS", &[&(crate::extras::VERSION)])).weak());
    ui.add_space(8.0);
    ui.horizontal_wrapped(|ui| {
        if ui.button(tr("\u{E3FC} Relancer l'assistant de démarrage")).clicked() {
            app.wizard = Some(0);
        }
        if ui.button(tr("\u{E6A2} Nouveautés")).clicked() {
            app.show_news = true;
        }
        if ui.button(tr("\u{E7EA} Rapport de diagnostic…")).clicked() {
            crate::extras::export_diagnostic(app);
        }
        if ui.button(tr("\u{E5DE} Page du projet (GitHub)")).clicked() {
            crate::install::open_url(&format!("https://github.com/{}", crate::update::REPO));
        }
    });
    ui.add_space(8.0);

    section(ui, tr("Premiers pas"), true, |ui| {
        step(ui, 1, tr("Paramètres : adresse de l'OMV (compte root) et, si tu l'utilises, du Synology (compte administrateur, « Passer par sudo »)."));
        step(ui, 2, tr("Confirme l'identité de chaque NAS (empreinte SSH), puis « Autoriser la clé » : tape une seule fois le mot de passe du compte dans la fenêtre qui s'ouvre."));
        step(ui, 3, tr("Page Installation : rclone, connexion Google Drive, scripts, alertes et suivi Home Assistant."));
        step(ui, 4, tr("Page Sauvegardes programmées : sauvegardes à heure fixe ou à la demande (dossier, mode miroir ou copie, chiffrement, horaire)."));
        step(ui, 5, tr("Page Sauvegardes temps réel : dossiers surveillés en continu (caméras, documents…), chaque changement part au fil de l'eau."));
        step(ui, 6, tr("Note les mots de passe de chiffrement hors du NAS (Alertes > Mots de passe de chiffrement)."));
    });

    section(ui, tr("Sauvegardes programmées ou temps réel ?"), false, |ui| {
        ui.label(RichText::new(tr("Programmées")).strong());
        ui.label(tr("Une copie complète du dossier à heure fixe (par exemple chaque nuit). Idéal pour de gros volumes qui changent peu : photos, musique, archives."));
        ui.add_space(4.0);
        ui.label(RichText::new(tr("Temps réel")).strong());
        ui.label(tr("Les dossiers sont surveillés en continu : un fichier créé, modifié ou supprimé part quelques secondes plus tard. Un rattrapage périodique envoie ce qui aurait été manqué (NAS redémarré, coupure réseau)."));
        ui.label(tr("Fichiers supprimés : « Corbeille » les garde X jours sur la destination (avec les anciennes versions des fichiers modifiés), « Suppression directe » les supprime aussi sur la destination, « Copie seule » ne supprime jamais rien."));
        ui.label(tr("Détection d'anomalie : si trop de fichiers sont supprimés ou modifiés en 10 minutes (rançongiciel, fausse manipulation), la sauvegarde se met en pause sans rien répercuter et une alerte est envoyée. Vérifie le dossier, puis « Reprendre »."));
        ui.label(RichText::new(tr("Exemples : caméras = temps réel, suppression directe, sans détection d'anomalie · documents = temps réel, corbeille 30 jours, détection d'anomalie · photos = programmée chaque nuit, chiffrée.")).small());
    });

    section(ui, tr("Accès depuis l'extérieur (Tailscale ou WireGuard)"), false, |ui| {
        ui.label(tr("Pour suivre les NAS hors de la maison sans ouvrir de port SSH sur Internet, utilise un réseau privé :"));
        ui.label(RichText::new(tr("Tailscale (le plus simple)")).strong());
        step(ui, 1, tr("Crée un compte sur tailscale.com et installe Tailscale sur ce PC."));
        step(ui, 2, tr("Sur l'OMV, en SSH une seule fois :"));
        code(ui, "curl -fsSL https://tailscale.com/install.sh | sh && tailscale up");
        step(ui, 3, tr("Sur le Synology : Centre de paquets > Tailscale, puis connecte-le au même compte."));
        step(ui, 4, tr("Ajoute un site « À distance » (Paramètres > Sites) avec les adresses Tailscale des NAS (100.x.y.z ou nom MagicDNS)."));
        ui.add_space(4.0);
        ui.label(RichText::new(tr("WireGuard")).strong());
        ui.label(tr("Si ta box ou Home Assistant propose WireGuard : active le tunnel sur ce PC, puis utilise les adresses locales habituelles des NAS."));
        ui.label(RichText::new(tr("Dans tous les cas, ne redirige jamais le port SSH (22) de ta box vers un NAS.")).color(WARN));
    });

    section(ui, tr("Erreurs fréquentes"), false, |ui| {
        for (title, text) in [
            (tr("Identité du NAS à confirmer / a changé"), tr("Normal à la première connexion. Si elle change sans réinstallation du NAS, refuse. Après une réinstallation : Paramètres > Oublier l'identité, puis confirme la nouvelle.")),
            (tr("La clé de l'application n'est pas autorisée"), tr("Paramètres > Autoriser la clé. Sur le Synology, le service « Accueil de l'utilisateur » doit être activé (dossier personnel).")),
            (tr("Mot de passe sudo refusé"), tr("Le compte du Synology doit appartenir au groupe administrators.")),
            (tr("Google Drive inaccessible"), tr("Page Installation > Reconnecter Google Drive (l'autorisation Google expire parfois).")),
            (tr("Sauvegarde en échec"), tr("L'explication s'affiche sous la sauvegarde. Le journal complet est dans Journaux.")),
            (tr("NAS injoignable"), tr("Vérifie qu'il est allumé et sur le réseau ; hors de la maison, utilise un réseau privé (voir ci-dessus).")),
            (tr("L'avertissement Windows SmartScreen"), tr("L'exécutable n'est pas signé : « Informations complémentaires » puis « Exécuter quand même ».")),
        ] {
            ui.label(RichText::new(title).strong());
            ui.label(RichText::new(text).small());
            ui.add_space(4.0);
        }
    });

    section(ui, tr("Raccourcis et astuces"), false, |ui| {
        ui.label(tr("F5 : actualiser · Ctrl+1 à Ctrl+9 : changer de page."));
        ui.label(tr("Fermer la fenêtre la réduit dans la zone de notification ; clic droit sur l'icône pour Quitter."));
        ui.label(tr("Taille du texte, thème, notifications, démarrage avec Windows : Paramètres > Préférences."));
        ui.label(tr("Plusieurs NAS (le tien, celui d'un proche) : Paramètres > Sites."));
    });

    section(ui, tr("Fichiers de l'application"), false, |ui| {
        ui.label(tf("Dossier : {0}", &[&(crate::config::app_dir().display())]));
        ui.label(tr("parametres.json (réglages), id_ed25519 (clé SSH), known_hosts (identités des NAS), journal.log (journal)."));
        ui.label(tr("Supprimer ce dossier remet l'application à zéro (la clé devra être réautorisée)."));
    });
}

// =====================================================================
//  Assistant de premier lancement
// =====================================================================

pub fn wizard_window(app: &mut App, ctx: &egui::Context) {
    let Some(step) = app.wizard else { return };
    // l'identite d'un NAS a confirmer passe devant
    if app.fingerprint.is_some() {
        return;
    }
    let mut next: Option<Option<u8>> = None;
    let mut save = false;
    egui::Window::new(RichText::new(tr("Bienvenue dans NAS Manager")).strong())
        .id(egui::Id::unique("wizard"))
        .collapsible(false)
        .resizable(false)
        .default_width(580.0)
        .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
        .show(ctx, |ui| {
            ui.label(RichText::new(tf("Étape {0} sur 4", &[&(step + 1)])).small().weak());
            ui.add_space(4.0);
            match step {
                0 => {
                    ui.label(RichText::new(tr("Suivre et gérer les sauvegardes du NAS, sans SSH.")).size(16.0).strong());
                    ui.add_space(4.0);
                    ui.label(tr("NAS Manager se connecte à l'OMV (sauvegardes programmées et temps réel, alertes) et, si tu en as un, au Synology (copie vers l'OMV, migration oCIS)."));
                    ui.label(tr("Cet assistant prend deux minutes : adresses des NAS, autorisation de la clé de l'application, puis installation des outils."));
                    ui.add_space(6.0);
                    ui.horizontal(|ui| {
                        ui.label(tr("Langue / Language :"));
                        let mut lang = app.edit.language.clone();
                        ui.radio_value(&mut lang, String::new(), tr("Automatique"));
                        ui.radio_value(&mut lang, "fr".to_string(), tr("Français"));
                        ui.radio_value(&mut lang, "en".to_string(), tr("English"));
                        if lang != app.edit.language {
                            app.edit.language = lang.clone();
                            app.settings.language = lang;
                            let _ = crate::config::save(&app.settings);
                            crate::i18n::set_language(&app.settings.language);
                        }
                    });
                }
                1 => {
                    ui.label(RichText::new(tr("L'OMV")).size(16.0).strong());
                    ui.label(tr("Adresse de l'OMV sur ton réseau (compte root)."));
                    host_fields(ui, "wz_omv", &mut app.edit.omv);
                }
                2 => {
                    ui.label(RichText::new(tr("Le Synology (facultatif)")).size(16.0).strong());
                    ui.label(tr("Compte administrateur du Synology ; laisse vide si tu n'en as pas. Active SSH dans DSM : Panneau de configuration > Terminal & SNMP."));
                    host_fields(ui, "wz_syno", &mut app.edit.syno);
                }
                _ => {
                    ui.label(RichText::new(tr("Autoriser la clé de l'application")).size(16.0).strong());
                    ui.label(tr("Pour chaque NAS : confirme son identité, puis tape une seule fois le mot de passe du compte dans la fenêtre qui s'ouvre."));
                    ui.add_space(4.0);
                    for h in [HostId::Omv, HostId::Syno] {
                        let cfg = app.host_cfg(h).clone();
                        if !cfg.is_set() {
                            continue;
                        }
                        ui.horizontal(|ui| {
                            let (col, txt) = if app.host_connected(h) {
                                (OK, tr("connecté").to_string())
                            } else if let Some(e) = app.host_error(h) {
                                (if matches!(e, crate::ssh::SshError::KeyRefused) { WARN } else { ERR }, e.to_string())
                            } else {
                                (INFO, tr("connexion…").to_string())
                            };
                            ui.label(RichText::new(format!("{} ({})", h.label(), cfg.target())).strong());
                            ui.label(RichText::new(txt).small().color(col));
                        });
                        ui.horizontal(|ui| {
                            if ui.button(tr("\u{E2D6} Autoriser la clé…")).clicked() {
                                crate::extras::authorize_key(app, h);
                            }
                            if ui.button(tr("\u{E094} Réessayer")).clicked() {
                                app.refresh(h);
                            }
                        });
                        ui.add_space(4.0);
                    }
                    ui.label(RichText::new(tr("Ensuite, la page Installation met en place rclone, Google Drive et les scripts.")).small().weak());
                }
            }
            ui.add_space(10.0);
            ui.horizontal(|ui| {
                if step > 0 && ui.button(tr("← Précédent")).clicked() {
                    next = Some(Some(step - 1));
                }
                if step < 3 {
                    let ok = step != 1 || app.edit.omv.is_set();
                    if ui.add_enabled(ok, egui::Button::new(RichText::new(tr("Suivant →")).color(Color32::WHITE)).fill(INFO)).clicked() {
                        if step == 1 || step == 2 {
                            save = true;
                        }
                        next = Some(Some(step + 1));
                    }
                } else if ui.add(egui::Button::new(RichText::new(tr("Terminer et aller à l'installation")).color(Color32::WHITE)).fill(INFO)).clicked() {
                    next = Some(None);
                    app.page = Page::Install;
                }
                if ui.button(tr("Passer")).on_hover_text(tr("Configurer plus tard dans les Paramètres")).clicked() {
                    next = Some(None);
                }
            });
        });
    if save {
        app.save_settings();
    }
    if let Some(n) = next {
        app.wizard = n;
        if n.is_none() {
            app.settings.wizard_done = true;
            app.edit.wizard_done = true;
            let _ = crate::config::save(&app.settings);
        }
    }
}

fn host_fields(ui: &mut egui::Ui, id: &str, h: &mut crate::config::HostCfg) {
    egui::Grid::new(id).num_columns(2).spacing([12.0, 8.0]).show(ui, |ui| {
        ui.label(tr("Adresse IP / nom"));
        ui.add(egui::TextEdit::singleline(&mut h.host).desired_width(200.0).hint_text("192.168.1.x"));
        ui.end_row();
        ui.label(tr("Utilisateur"));
        ui.add(egui::TextEdit::singleline(&mut h.user).desired_width(160.0));
        ui.end_row();
        ui.label(tr("Port SSH"));
        let mut p = h.port.to_string();
        if ui.add(egui::TextEdit::singleline(&mut p).desired_width(60.0)).changed() {
            if let Ok(v) = p.trim().parse() {
                h.port = v;
            }
        }
        ui.end_row();
    });
}
