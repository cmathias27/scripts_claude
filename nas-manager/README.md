# NAS Manager (Windows)

Application Windows en Rust pour **suivre et gérer toutes les synchros du NAS sans ouvrir de session SSH** :

| Page | Script piloté | Ce qu'on peut faire |
|---|---|---|
| Tableau de bord | tous | état d'ensemble, transferts en cours, Drive, disques |
| Sauvegardes programmées | `nas-debian` (OMV / Debian) | miroir, copie ou versionnée (restic), vers une ou plusieurs destinations ; suivre l'avancement en direct, lancer, arrêter, ajouter, modifier, supprimer, restaurer (fichier, dossier ou version datée) |
| Caméras | `cam-sync` (OMV) | état du service, dernière vidéo envoyée, erreurs, démarrer / arrêter / redémarrer, lancer un rattrapage |
| Destinations | `nas-debian destinations`, `secours` | clouds, disques USB, autres NAS (connexion par le navigateur ou formulaire, test d'envoi), règle 3-2-1, kit de secours (copie sur le PC) |
| Alertes | `nas-debian` (`nas-check`, `nas-notify`) | connexion et quota Google Drive, alertes en cours (acquitter), vérifier maintenant, notification de test, afficher les mots de passe de chiffrement |
| Copie → OMV | `nas-synology copie` | suivre / arrêter la copie, en lancer une nouvelle avec navigateur de dossiers des deux NAS, historique, réparer les droits |
| Migration oCIS | `nas-synology migration` | connexion oCIS, file d'attente (ajouter / retirer / lancer), suivi en direct, arrêt, résultats, historique |
| Historique | `nas-debian` (OMV / Debian) | exécutions, taux de réussite, volumes, évolution de l'espace |
| Journaux | tous | dernières lignes de chaque journal, suivi en direct, filtre |
| Installation | tous | scripts des machines (installer / mettre à jour depuis GitHub, revenir en arrière, migrer une ancienne installation), tous les outils nécessaires, connexion Google Drive, caméras, alertes, suivi Home Assistant, mémoire de rclone |
| Aide | — | premiers pas, accès à distance (Tailscale / WireGuard), erreurs fréquentes, raccourcis |

Interface en **français ou en anglais** (Paramètres > Préférences, par défaut la langue de Windows).
L'application se met à jour d'elle-même (Paramètres > Mises à jour), gère **plusieurs sites** (un OMV et un Synology
chacun) et reste dans la zone de notification avec des notifications Windows.

## Comment ça marche

L'application utilise le **client OpenSSH intégré à Windows 10/11** (`ssh.exe`) avec sa propre clé
(`%APPDATA%\NasManager\id_ed25519`). Toutes les quelques secondes elle envoie au NAS un petit script
qui lit l'état (fichiers d'état et journaux des scripts) et le renvoie en JSON. Les actions passent par
des commandes « sans question » ajoutées aux scripts :

```
nas-debian save <nouveau|modif> NOM SOURCE DOSSIER sync|copy|versions oui|non HORAIRE JOURS [DEBIT] [MEMOIRE] [DESTINATIONS] [ROTATION]
nas-debian delete <NOM> [effacer-drive]
nas-debian restore <NOM> <DOSSIER> [ELEMENT] [corbeille] [DESTINATION]
nas-debian versions liste | ls | restaurer ...      destinations liste | etat | creer | jeton | supprimer
nas-debian secours etat | sauvegarder | telecharger | restaurer
nas-debian version | outils etat | outils installer | reglages ram ... | migrer appliquer
nas-synology copie lancer <source> <dossier OMV> <dossier|contenu> <copie|deplacement>
nas-synology migration espaces | sources | ajouter ... | retirer <n> | lancer | arreter | configurer | jeton
```

Les menus interactifs des scripts restent identiques : on peut toujours les utiliser en SSH.

## Mise en route

Au premier lancement, un **assistant** guide pas à pas :

1. adresse de l'OMV (`root`) et, si besoin, du Synology (compte administrateur, « Passer par sudo » coché ;
   activer SSH : DSM > Panneau de configuration > Terminal & SNMP) ;
2. confirmation de l'identité de chaque NAS (empreinte SSH), puis **Autoriser la clé** : une fenêtre s'ouvre,
   taper une seule fois le mot de passe du compte ;
3. page **Installation** : rclone, connexion Google Drive (la page Google s'ouvre dans le navigateur du PC,
   rien à copier), scripts `nas-debian` et `nas-synology` (avec tous les outils nécessaires), synchro des caméras,
   alertes et suivi Home Assistant.

Le mot de passe administrateur du Synology (pour `sudo`) est demandé au premier accès ; il peut être mémorisé,
chiffré avec le compte Windows (DPAPI). Les scripts des NAS sont vérifiés sur GitHub au démarrage puis toutes les 12 heures (réglable, ou « Vérifier
maintenant ») : le bouton passe de **Installer** à **À jour** ou **Mettre à jour vX → vY**. L'empreinte est
vérifiée avant installation, l'ancienne version est gardée (retour arrière en un clic) et les transferts en
cours ne sont pas interrompus.
Page **Copie → OMV** : si besoin, **Autoriser le Synology à écrire sur l'OMV**.

Prérequis côté NAS : `python3` (présent sur OMV et DSM 7).

## Télécharger

Dernière version : <https://github.com/cmathias27/scripts_claude/releases/latest> (fichier `nas-manager.exe`).
Chaque version a sa page avec ses nouveautés (aussi affichées dans l'application après une mise à jour).

## Compiler

**Avec GitHub** : à chaque envoi, le workflow `.github/workflows/nas-manager.yml`
1. teste l'application sous Linux contre un faux OMV et un faux Synology (`tests/faux-nas.sh`) ;
2. la teste et la compile sous Windows ;
3. publie la Release `vX.Y.Z` (version de `Cargo.toml`, nouveautés de `CHANGELOG.md`).

Nouvelle version : augmenter `version` dans `Cargo.toml` et ajouter sa section en tête de `CHANGELOG.md`.

**Sur le PC Windows** : installer Rust (<https://rustup.rs>), puis `compiler.bat` ou `cargo build --release`.

## Fichiers de l'application

`%APPDATA%\NasManager\` : `parametres.json`, la clé SSH (`id_ed25519`), `known_hosts` (identités confirmées des NAS),
`journal.log` (journal de l'application).
Supprimer ce dossier remet l'application à zéro.

## Tests (développeurs)

`cargo test` : tests unitaires. Avec un NAS de test (voir `src/remote.rs`, module `live`) :
`NAS_MANAGER_LIVE_TEST=1 NAS_MANAGER_DIR=<dossier de test> cargo test -- --test-threads=1`.
