# NAS Manager (Windows)

Application Windows en Rust pour **suivre et gérer toutes les synchros du NAS sans ouvrir de session SSH** :

| Page | Script piloté | Ce qu'on peut faire |
|---|---|---|
| Tableau de bord | tous | état d'ensemble, transferts en cours, Drive, disques |
| Sauvegardes | `nas-backup` (OMV) | suivre l'avancement en direct (Go, %, débit, fichiers en cours), lancer, tout lancer, arrêter, ajouter, modifier, supprimer (avec ou sans effacement du Drive), restaurer |
| Caméras | `cam-sync` (OMV) | état du service, dernière vidéo envoyée, erreurs, démarrer / arrêter / redémarrer, lancer un rattrapage |
| Alertes | `nas-check`, `nas-notify` (OMV) | connexion et quota Google Drive, alertes en cours (acquitter), vérifier maintenant, notification de test, afficher les mots de passe de chiffrement |
| Copie → OMV | `copie-omv` (Synology) | suivre / arrêter la copie, en lancer une nouvelle avec navigateur de dossiers des deux NAS, historique, réparer les droits |
| Migration oCIS | `migre-drive-ocis` (Synology) | connexion oCIS, file d'attente (ajouter / retirer / lancer), suivi en direct, arrêt, résultats, historique |
| Historique | `nas-backup` (OMV) | exécutions, taux de réussite, volumes, évolution de l'espace |
| Journaux | tous | dernières lignes de chaque journal, suivi en direct, filtre |
| Installation | tous | première installation sur des NAS vierges : rclone, connexion Google Drive, scripts, caméras, alertes, suivi Home Assistant |
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
nas-backup save <nouveau|modif> NOM SOURCE DOSSIER sync|copy oui|non HH:MM|manuel JOURS
nas-backup delete <NOM> [effacer-drive]
nas-backup restore <NOM> <DOSSIER>
nas-backup gen-cron
copie-omv lancer <source> <dossier OMV> <dossier|contenu> <copie|deplacement>
copie-omv arreter
migre-drive-ocis espaces | sources | ajouter ... | retirer <n> | lancer | arreter | configurer
```

Les menus interactifs des scripts restent identiques : on peut toujours les utiliser en SSH.

## Mise en route

Au premier lancement, un **assistant** guide pas à pas :

1. adresse de l'OMV (`root`) et, si besoin, du Synology (compte administrateur, « Passer par sudo » coché ;
   activer SSH : DSM > Panneau de configuration > Terminal & SNMP) ;
2. confirmation de l'identité de chaque NAS (empreinte SSH), puis **Autoriser la clé** : une fenêtre s'ouvre,
   taper une seule fois le mot de passe du compte ;
3. page **Installation** : rclone, connexion Google Drive (la page Google s'ouvre dans le navigateur du PC,
   rien à copier), `nas-backup`, synchro des caméras, alertes et suivi Home Assistant, scripts du Synology.

Le mot de passe administrateur du Synology (pour `sudo`) est demandé au premier accès ; il peut être mémorisé,
chiffré avec le compte Windows (DPAPI). Les mises à jour des scripts se font depuis Paramètres > Scripts sur les NAS
(l'ancienne version est gardée en `.bak`, les transferts en cours ne sont pas interrompus).
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
