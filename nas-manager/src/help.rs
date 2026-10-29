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

/// Un exemple de configuration : titre, explication, réglages, bouton qui pré-remplit le formulaire
fn example(ui: &mut egui::Ui, title: &str, why: &str, settings: &[(&str, String)], button: Option<&str>) -> bool {
    let mut go = false;
    egui::Frame::new()
        .stroke(egui::Stroke::new(1.0, ui.visuals().widgets.noninteractive.bg_stroke.color))
        .corner_radius(6.0)
        .inner_margin(egui::Margin::same(8))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.label(RichText::new(title).strong());
            ui.label(RichText::new(why).small());
            egui::Grid::new(("ex", title)).num_columns(2).spacing([12.0, 2.0]).show(ui, |ui| {
                for (k, v) in settings {
                    ui.label(RichText::new(*k).small().weak());
                    ui.label(RichText::new(v).small());
                    ui.end_row();
                }
            });
            if let Some(b) = button {
                if ui.small_button(b).clicked() {
                    go = true;
                }
            }
        });
    ui.add_space(4.0);
    go
}

/// Exemples prêts à l'emploi (programmées, temps réel, PC), avec pré-remplissage du formulaire
fn examples(app: &mut App, ui: &mut egui::Ui) {
    ui.label(tr("Quelques réglages qui marchent bien. Le bouton ouvre le formulaire déjà rempli : il reste à choisir le dossier, puis à enregistrer."));
    ui.add_space(4.0);
    let ready = app.omv.status.as_ref().map(|s| s.nb_installe).unwrap_or(false);
    let first_dest = crate::dests::available(app).first().map(|d| d.nom.clone()).unwrap_or_else(|| "gdrive".into());
    let has_usb = crate::dests::available(app).iter().any(|d| d.kind == "local");
    let btn = |label: &'static str| if ready { Some(tr(label)) } else { None };

    if example(
        ui,
        tr("Caméras : miroir chiffré en temps réel"),
        tr("Chaque vidéo part dès qu'elle est écrite ; les vidéos effacées par l'enregistreur le sont aussi sur la destination (pas de corbeille, pour ne pas doubler l'espace)."),
        &[
            (tr("Page"), tr("Sauvegardes temps réel").into()),
            (tr("Destination"), tr("Drive chiffré").into()),
            (tr("Fichiers supprimés"), tr("Suppression directe").into()),
            (tr("Types de fichiers"), "*.mp4 ; *.jpg".into()),
            (tr("Regroupement"), tr("envoi après 5 s, rattrapage toutes les 15 min").into()),
        ],
        btn("\u{E3EE} Créer cette sauvegarde temps réel…"),
    ) {
        let mut f = crate::realtime::RtForm::new_default();
        f.name = "Cameras".into();
        f.folder = "Cameras".into();
        f.deletion = 0;
        f.types = "*.mp4 ; *.jpg".into();
        f.delay = "5".into();
        f.catchup = 15;
        app.rt_form = Some(f);
        app.page = Page::Realtime;
    }
    if example(
        ui,
        tr("Documents : temps réel avec corbeille de 30 jours"),
        tr("Un document modifié part dans la minute ; un fichier effacé ou écrasé par erreur reste 30 jours dans la corbeille de la destination, et le retour à une date précise est possible."),
        &[
            (tr("Page"), tr("Sauvegardes temps réel").into()),
            (tr("Fichiers supprimés"), tr("Corbeille 30 jours").into()),
            (tr("Exclusions"), "~$* ; *.tmp ; .~lock.*".into()),
            (tr("Détection d'anomalie"), tr("pause au-delà de 300 changements en peu de temps (rançongiciel)").into()),
        ],
        btn("\u{E3EE} Créer cette sauvegarde temps réel…"),
    ) {
        let mut f = crate::realtime::RtForm::new_default();
        f.name = "Documents".into();
        f.folder = "Documents".into();
        f.deletion = 1;
        f.trash_days = "30".into();
        f.excl = "~$* ; *.tmp ; .~lock.*".into();
        app.rt_form = Some(f);
        app.page = Page::Realtime;
    }
    let photo_dests = if has_usb { tf("{0} (chiffré) + disque USB (en clair)", &[&first_dest]) } else { tf("{0} (chiffré)", &[&first_dest]) };
    if example(
        ui,
        tr("Photos : copie hebdomadaire vers deux destinations"),
        tr("Les photos changent peu : une copie chaque dimanche suffit. En copie, rien n'est jamais supprimé sur la destination (une photo effacée par erreur sur le NAS reste sauvegardée)."),
        &[
            (tr("Page"), tr("Sauvegardes programmées").into()),
            (tr("Mode"), tr("Copie").into()),
            (tr("Horaire"), tr("le dimanche à 02:00").into()),
            (tr("Destinations"), photo_dests),
            (tr("Débit"), tr("réglage de la machine (débit selon l'heure)").into()),
        ],
        btn("\u{E3EE} Créer cette sauvegarde programmée…"),
    ) {
        let mut dests = vec![(first_dest.clone(), true)];
        if let Some(u) = crate::dests::available(app).iter().find(|d| d.kind == "local") {
            dests.push((u.nom.clone(), false));
        }
        app.job_form = Some(crate::app::JobFormState {
            new: true,
            name: "Photos".into(),
            folder: "Photos".into(),
            folder_touched: true,
            mode: 1,
            dests,
            rot: crate::dests::rot_parse(""),
            sched: crate::sched::SchedEdit::parse("02:00/7"),
            trash_days: "30".into(),
            ..Default::default()
        });
        if !app.sources_loaded {
            app.load_backup_sources();
        }
        app.page = Page::Backups;
    }
    if example(
        ui,
        tr("Papiers importants : versionnée chaque nuit"),
        tr("Garde des versions datées (comme Hyper Backup) : retrouver un fichier tel qu'il était avant une erreur ou un rançongiciel, même des mois après."),
        &[
            (tr("Page"), tr("Sauvegardes programmées").into()),
            (tr("Mode"), tr("Versionnée").into()),
            (tr("Horaire"), tr("chaque jour à 03:30").into()),
            (tr("Versions gardées"), tr("7 quotidiennes, 4 hebdomadaires, 12 mensuelles").into()),
        ],
        btn("\u{E3EE} Créer cette sauvegarde programmée…"),
    ) {
        app.job_form = Some(crate::app::JobFormState {
            new: true,
            name: "Papiers".into(),
            folder: "Papiers".into(),
            folder_touched: true,
            mode: 2,
            dests: vec![(first_dest.clone(), true)],
            rot: crate::dests::rot_parse("7:4:12:0"),
            sched: crate::sched::SchedEdit::parse("03:30"),
            trash_days: "30".into(),
            ..Default::default()
        });
        if !app.sources_loaded {
            app.load_backup_sources();
        }
        app.page = Page::Backups;
    }
    if example(
        ui,
        tr("Ce PC : Documents et Bureau vers le NAS"),
        tr("Chaque jour à midi, plus les changements au fil de l'eau ; en miroir, un fichier supprimé du PC reste 30 jours dans la corbeille du NAS."),
        &[
            (tr("Page"), tr("Sauvegarde du PC").into()),
            (tr("Mode"), tr("Miroir, corbeille 30 jours").into()),
            (tr("Horaire"), tr("chaque jour à 12:30 + temps réel").into()),
        ],
        Some(tr("\u{E3EE} Créer cette sauvegarde du PC…")),
    ) {
        let home = std::env::var("USERPROFILE").or_else(|_| std::env::var("HOME")).unwrap_or_default();
        let dirs: Vec<String> = ["Documents", "Desktop"].iter().map(|d| std::path::Path::new(&home).join(d)).filter(|p| p.is_dir()).map(|p| p.display().to_string()).collect();
        app.pcbackup.form = Some(crate::pcbackup::PcForm {
            new: true,
            name: tr("Documents du PC").into(),
            dirs,
            host_kind: "omv".into(),
            mode: 1,
            trash_days: "30".into(),
            sched: crate::sched::SchedEdit::parse("12:30"),
            realtime: true,
            enabled: true,
            ..Default::default()
        });
        app.page = Page::PcBackup;
    }
    if example(
        ui,
        tr("Connexion Internet partagée : débit selon l'heure"),
        tr("Les sauvegardes ne ralentissent pas la maison en journée, et vont à pleine vitesse la nuit."),
        &[(tr("Page"), tr("Installation, carte 7").into()), (tr("Débit"), tr("2 Mo/s de 8 h à 23 h, sans limite la nuit").into())],
        Some(tr("\u{E3EE} Ouvrir le réglage…")),
    ) {
        app.install.ram[0].bw_loaded = true;
        app.install.ram[0].bw = crate::sched::BwEdit::parse("08:00,2M 23:00,off");
        app.page = Page::Install;
    }
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

    section(ui, tr("Exemples de configuration"), true, |ui| {
        examples(app, ui);
    });

    section(ui, tr("Sauvegarde de ce PC vers le NAS"), false, |ui| {
        ui.label(tr("Page « Sauvegarde du PC » : des dossiers du PC (Documents, Bureau, Images…) envoyés dans un dossier de l'OMV / Debian ou du Synology. rclone tourne sur le PC et passe par SFTP avec la clé de l'application : rien à installer sur le NAS."));
        step(ui, 1, tr("« + Nouvelle sauvegarde du PC » : dossiers du PC, NAS, dossier de destination (bouton Parcourir), mode, horaire."));
        step(ui, 2, tr("Copie : rien n'est jamais supprimé sur le NAS. Miroir : le NAS suit le PC ; ce qui est supprimé ou remplacé part dans .corbeille-pc/<date> sur le NAS, gardé le nombre de jours choisi."));
        step(ui, 3, tr("Temps réel (facultatif) : chaque changement part 30 s après le dernier, au plus tard 10 min après, tant que l'application est ouverte."));
        ui.label(RichText::new(tr("L'application doit être ouverte (même réduite dans la zone de notification) : active « Lancer au démarrage de Windows ». Un créneau manqué (PC éteint) est rattrapé au lancement suivant ; NAS injoignable (portable hors de la maison) : nouvel essai toutes les 30 minutes. Synology : activer le service SFTP dans DSM.")).small());
    });

    section(ui, tr("Débit selon l'heure, estimation, doublons"), false, |ui| {
        ui.label(RichText::new(tr("Débit selon l'heure")).strong());
        ui.label(tr("Page Installation, carte 7 : une limite commune à toutes les sauvegardes de la machine, différente le jour et la nuit (ex. 2 Mo/s de 8 h à 23 h, sans limite la nuit), réglée une fois pour toutes. Chaque sauvegarde peut garder « Réglage de la machine », avoir sa propre limite, ou être « Sans limite »."));
        ui.add_space(4.0);
        ui.label(RichText::new(tr("Estimation avant la première sauvegarde")).strong());
        ui.label(tr("Bouton « Estimer la première sauvegarde » (formulaire d'une nouvelle sauvegarde, ou carte d'une sauvegarde jamais lancée) : volume à envoyer et durée, selon le débit réel vers la destination (moyenne des sauvegardes déjà faites vers elle, sinon un envoi de test de 16 Mo), limite de débit comprise."));
        ui.add_space(4.0);
        ui.label(RichText::new(tr("Doublons")).strong());
        ui.label(tr("Page « Doublons » : les fichiers identiques au bit près dans les dossiers choisis (photos importées deux fois, copies de sauvegarde…). Dans chaque groupe, le plus ancien est gardé par défaut ; les autres partent dans la corbeille des doublons (.corbeille-doublons, sur le même disque), vidée après 30 jours. Chaque fichier est relu juste avant : il n'est déplacé que s'il est toujours identique à une copie qui reste en place."));
    });

    section(ui, tr("Piloter depuis Home Assistant"), false, |ui| {
        ui.label(tr("Page Installation, carte 6 : « Autoriser les actions depuis Home Assistant ». L'appareil du NAS reçoit un bouton « Lancer » par sauvegarde programmée, « Arrêter les sauvegardes », « Vérifier maintenant », et un interrupteur par sauvegarde temps réel (pause / reprise)."));
        ui.label(RichText::new(tr("Exemple d'automatisation : lancer la sauvegarde des photos quand tout le monde est parti, mettre les caméras en pause quand quelqu'un rentre (à adapter : noms des entités dans Paramètres > Appareils > NAS).")).small());
        code(ui, "automation:\n  - alias: Sauvegarde des photos en partant\n    trigger: [{ platform: state, entity_id: zone.home, to: \"0\" }]\n    action: [{ service: button.press, target: { entity_id: button.nas_lancer_photos } }]\n  - alias: Pause des caméras au retour\n    trigger: [{ platform: state, entity_id: zone.home, from: \"0\" }]\n    action: [{ service: switch.turn_off, target: { entity_id: switch.nas_temps_reel_actif_cameras } }]");
        ui.label(RichText::new(tr("Seules ces actions sont acceptées, pour des sauvegardes qui existent ; chacune est notée dans le journal du NAS. Toute personne ayant accès au serveur MQTT peut les déclencher : garde un compte MQTT dédié avec un mot de passe.")).small());
    });

    section(ui, tr("Sans PC Windows : NAS Manager en mode texte (SSH)"), false, |ui| {
        ui.label(tr("Page Installation, carte 10 : installe le programme « nas-manager » sur l'OMV / Debian et le Synology. Ensuite, depuis n'importe quel terminal SSH (Linux, Mac, téléphone avec Termius ou JuiceSSH) :"));
        code(ui, "ssh root@192.168.1.190\nnas-manager");
        ui.label(tr("Tableau de bord, sauvegardes (lancer, arrêter), temps réel (pause, reprise), historique, alertes (acquitter), transferts et journaux, au clavier : Tab ou les chiffres pour changer de page, ↑ ↓ pour choisir, ? pour l'aide, q pour quitter. Chaque action demande une confirmation."));
        ui.label(RichText::new(tr("Sur le Synology : sudo nas-manager. Pour suivre une autre machine du site : nas-manager --hote root@192.168.1.190 (clé SSH déjà autorisée). Sans couleurs : --sans-couleur ; en anglais : --lang en.")).small());
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

    section(ui, tr("S'assurer qu'on peut restaurer"), false, |ui| {
        ui.label(RichText::new(tr("Test de restauration à blanc")).strong());
        ui.label(tr("Une sauvegarde n'est utile que si on peut la relire. Le test restaure quelques fichiers pris au hasard depuis chaque destination (déchiffrés si besoin) dans un dossier temporaire, les compare octet par octet aux originaux, puis les efface. Seuls les fichiers plus anciens que la dernière sauvegarde réussie sont testés."));
        step(ui, 1, tr("À la demande : menu ⋯ de la sauvegarde > « Tester la restauration »."));
        step(ui, 2, tr("Automatique : page Sauvegardes programmées, « Test de restauration automatique » (par exemple chaque samedi, 5 fichiers par sauvegarde)."));
        ui.label(RichText::new(tr("Un écart (fichier absent ou différent) déclenche une alerte : lance une vérification d'intégrité, puis une sauvegarde.")).small());
        ui.add_space(4.0);
        ui.label(RichText::new(tr("Retour à une date précise")).strong());
        ui.label(tr("Menu ⋯ > Restaurer > « À une date » : remet un dossier (ou toute la sauvegarde) tel qu'il était à la date choisie, dans un dossier de restauration (les fichiers actuels ne sont pas touchés)."));
        ui.label(RichText::new(tr("Miroir avec corbeille : reconstitué à partir de la corbeille datée (fichiers supprimés depuis, anciennes versions des fichiers modifiés), aussi loin que la durée de la corbeille. Versionnée : la dernière version enregistrée avant la date. Copie : pas de retour possible (les anciennes versions ne sont pas gardées).")).small());
    });

    section(ui, tr("Machines en veille ou éteintes (Wake-on-LAN)"), false, |ui| {
        ui.label(tr("Une machine en veille ou éteinte peut être réveillée par le réseau (« paquet magique ») si le Wake-on-LAN est activé dans son BIOS et dans ses réglages réseau (OMV : Réseau > Interfaces > Wake-on-LAN ; Synology : Matériel et alimentation > Activer WOL)."));
        step(ui, 1, tr("Depuis ce PC : Paramètres > adresse MAC de la machine (bouton « Détecter » quand elle est allumée). Quand elle ne répond pas, le bouton « Réveiller » apparaît."));
        step(ui, 2, tr("Avant les sauvegardes : page Destinations > « Réveil (Wake-on-LAN) » sur un autre NAS ou un PC. La sauvegarde le réveille s'il dort, attend qu'il réponde, puis le laisse se rendormir (ou le remet en veille, ou l'éteint)."));
        step(ui, 3, tr("Avant les copies Synology → OMV : page Copie > « Réveil de l'OMV avant les copies »."));
        ui.label(RichText::new(tr("Une destination en veille avec réveil configuré ne déclenche pas d'alerte « injoignable » lors de la vérification horaire.")).small());
    });

    section(ui, tr("oCIS : migration et transferts"), false, |ui| {
        ui.label(RichText::new(tr("Migration vers oCIS")).strong());
        ui.label(tr("Page oCIS, onglet « Migration vers oCIS » : un dossier envoyé dans un espace oCIS (personnel ou projet), depuis le Synology, l'OMV / Debian ou ce PC. Chaque machine a sa propre connexion à oCIS (adresse, compte et jeton d'application)."));
        step(ui, 1, tr("Crée un jeton d'application dans oCIS et configure la connexion de la machine d'où part la migration."));
        step(ui, 2, tr("Choisis le dossier, l'espace oCIS (et un sous-dossier), puis ajoute-le à la file d'attente ; lance la file."));
        step(ui, 3, tr("En option, chaque fichier est contrôlé dans oCIS puis l'original est supprimé ; un fichier en défaut est renvoyé, et gardé s'il reste en défaut."));
        ui.label(RichText::new(tr("Depuis ce PC : rclone tourne sur le PC, qui doit rester allumé (il est tenu éveillé pendant la migration). Si l'application est fermée en cours de route, la migration reprend à son prochain lancement.")).small());
        ui.add_space(4.0);
        ui.label(RichText::new(tr("Transferts oCIS → NAS")).strong());
        ui.label(tr("Onglet « Transferts oCIS → NAS » : un dossier d'un espace oCIS recopié dans un dossier du Synology ou de l'OMV, par l'accès WebDAV d'oCIS, dates conservées. Ponctuel, à la demande ou programmé (sauvegarde régulière d'oCIS vers le NAS)."));
        ui.label(RichText::new(tr("Copie : rien n'est jamais supprimé sur le NAS. Miroir : le NAS suit oCIS ; ce qui y est supprimé ou remplacé est gardé quelques jours dans .corbeille-oCIS. Choisis un dossier dédié à chaque transfert miroir.")).small());
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
            (tr("NAS injoignable"), tr("Vérifie qu'il est allumé et sur le réseau ; hors de la maison, utilise un réseau privé (voir ci-dessus). En veille : bouton « Réveiller » (adresse MAC dans les Paramètres).")),
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
