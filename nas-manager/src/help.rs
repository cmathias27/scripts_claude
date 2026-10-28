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
        step(ui, 7, tr("Page Destinations : ajoute une deuxième destination (disque USB, autre NAS, OneDrive…) et note le mot de passe du kit de secours."));
    });

    section(ui, tr("Destinations et règle 3-2-1"), false, |ui| {
        ui.label(tr("Une destination, c'est l'endroit où partent les sauvegardes : Google Drive, OneDrive, Dropbox, pCloud, Box, un disque USB branché sur le NAS, un autre NAS (SFTP ou partage SMB), un serveur WebDAV (Nextcloud, ownCloud, oCIS), Backblaze B2 ou un stockage S3."));
        ui.label(tr("Règle 3-2-1 : garder 3 copies des données (le NAS + 2 sauvegardes), sur 2 supports différents, dont 1 hors de la maison. Une sauvegarde programmée peut partir vers plusieurs destinations, l'une après l'autre ; le chiffrement se choisit pour chacune."));
        ui.label(RichText::new(tr("Exemple : photos → Google Drive (chiffré) + disque USB (en clair, relisible directement en cas de besoin).")).small());
        ui.label(RichText::new(tr("Un disque USB débranché fait échouer la sauvegarde vers lui (alerte), sans rien écrire sur le disque système ; les autres destinations sont faites quand même.")).small());
    });

    section(ui, tr("Sauvegardes versionnées"), false, |ui| {
        ui.label(tr("Le mode « Versionnée » garde des versions datées du dossier, comme Hyper Backup : on peut retrouver un fichier ou tout le dossier tel qu'il était à une date donnée (avant un effacement, un rançongiciel, une mauvaise manipulation)."));
        ui.label(tr("Seuls les morceaux modifiés sont envoyés et stockés (déduplication) et tout est chiffré. Les versions gardées suivent une rotation (ex. 7 quotidiennes, 4 hebdomadaires, 12 mensuelles) ; le nettoyage des anciennes versions et un contrôle des données ont lieu chaque dimanche matin."));
        ui.label(tr("Différence avec miroir / copie : les fichiers ne sont pas lisibles un par un sur la destination, on les récupère avec « Versions et restauration » (menu ⋯ de la sauvegarde). Sans le mot de passe des versions, les versions sont illisibles : il est dans le kit de secours et dans les mots de passe de chiffrement."));
    });

    section(ui, tr("Mon NAS est mort : reconstruire"), false, |ui| {
        ui.label(tr("Ce qu'il faut : le kit de secours (copié sur ce PC et dans le dossier NAS-secours de chaque destination) et son mot de passe (6 groupes de 4 caractères)."));
        step(ui, 1, tr("Installe Debian ou OpenMediaVault sur la nouvelle machine, monte les disques de données et active SSH (compte root)."));
        step(ui, 2, tr("Paramètres : remplace l'adresse de l'OMV par celle de la nouvelle machine, puis « Oublier l'identité » et « Autoriser la clé »."));
        step(ui, 3, tr("Page Installation, carte 1 : installe le script nas-debian (il installe aussi rclone, restic et les outils)."));
        step(ui, 4, tr("Page Installation, carte 9 : choisis le kit de secours, tape son mot de passe, « Vérifier le kit » puis « Restaurer sur cette machine ». Connexions aux destinations, mots de passe, sauvegardes et réglages reviennent."));
        step(ui, 5, tr("Si les disques ont changé de chemin, corrige le dossier source des sauvegardes (bouton Modifier), puis restaure les données : menu ⋯ > Restaurer (ou Versions et restauration)."));
        step(ui, 6, tr("Page Destinations : « Tout tester ». Une destination refusée (autorisation expirée) se reconnecte avec « Reconnecter »."));
        ui.add_space(4.0);
        ui.label(RichText::new(tr("Kit introuvable sur le PC ? Télécharge-le depuis le site du cloud (dossier NAS-secours) ou depuis le disque USB. Pas de kit du tout ? Reconnecte les destinations, puis saisis les mots de passe notés (Installation, carte 9 > « Pas de kit ? »).")).small());
        ui.label(RichText::new(tr("Sans NAS Manager, sur un PC Linux ou WSL, le kit s'ouvre avec :")).small());
        code(ui, "openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -in kit-secours-NAS.tar.gz.enc | tar xzv");
    });

    section(ui, tr("Être prévenu : notifications, disques, rapport"), false, |ui| {
        ui.label(tr("Chaque heure, le NAS vérifie les sauvegardes, les destinations, l'espace libre et la santé des disques. Un problème déclenche une alerte, rappelée tant qu'il n'est pas résolu, puis un message « rétabli »."));
        step(ui, 1, tr("Page Alertes & santé, « Ajouter un canal » : ntfy (le plus simple : application gratuite, sans compte), Telegram, Discord, e-mail ou Home Assistant. Plusieurs canaux peuvent être combinés."));
        step(ui, 2, tr("Chaque canal reçoit soit les alertes seulement, soit aussi les messages discrets. Un message de test part à l'enregistrement."));
        step(ui, 3, tr("Rapport : un résumé chaque semaine ou chaque mois (sauvegardes, espace, disques, alertes). « Aperçu » le montre sans l'envoyer."));
        ui.add_space(4.0);
        ui.label(RichText::new(tr("Santé des disques")).strong());
        ui.label(tr("Les disques préviennent souvent avant de lâcher : secteurs réalloués (à surveiller), secteurs instables ou illisibles, test SMART en échec (à remplacer vite). Un RAID qui perd un disque n'a plus de redondance : remplace le disque en panne au plus vite. Les disques en veille ne sont pas réveillés pour la vérification."));
        ui.label(RichText::new(tr("Les alertes du Synology (disques, RAID) s'affichent ici et passent par Home Assistant s'il est configuré sur le Synology.")).small());
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
        ui.label(tr("F5 : actualiser · Ctrl+1 à Ctrl+9 puis Ctrl+0 : changer de page (Ctrl+0 : Paramètres)."));
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
