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
| Journaux | tous | dernières lignes de chaque journal, suivi en direct, filtre |

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

1. **Paramètres** : adresse de l'OMV (`root`) et du Synology (compte administrateur, « Passer par sudo » coché).
   Sur le Synology, activer SSH : DSM > Panneau de configuration > Terminal & SNMP.
2. **Autoriser la clé…** sur chaque NAS : une fenêtre s'ouvre, taper une seule fois le mot de passe du compte,
   puis **Tester**.
3. Synology : le mot de passe administrateur (pour `sudo`) est demandé au premier accès ; il peut être mémorisé,
   chiffré avec le compte Windows (DPAPI).
4. **Scripts sur les NAS > Installer / mettre à jour** : installe `nas-backup` sur l'OMV et `copie-omv`,
   `migre-drive-ocis` dans `/usr/local/bin` du Synology (l'ancienne version est gardée en `.bak`, les transferts
   en cours ne sont pas interrompus). L'adresse de l'OMV des paramètres est reprise dans `copie-omv`.
5. Page **Copie → OMV** : si besoin, **Autoriser le Synology à écrire sur l'OMV** (clé root du Synology
   ajoutée sur l'OMV, plus besoin de la première copie en SSH).

Prérequis côté NAS : `python3` (présent sur OMV et DSM 7).

## Compiler

**Avec GitHub** : pousser le dépôt ; le workflow `.github/workflows/nas-manager.yml` compile sous Windows.
Le fichier `nas-manager.exe` est dans l'onglet *Actions* > dernier run > *Artifacts*
(ou dans une *Release* en poussant un tag `nas-manager-v1.0.0`).

**Sur le PC Windows** : installer Rust (<https://rustup.rs>, avec les « Visual Studio Build Tools » proposés),
puis double-cliquer sur `compiler.bat`, ou :

```
cd nas-manager
cargo build --release
```

L'exécutable est `target\release\nas-manager.exe` (un seul fichier, rien à installer).

## Fichiers de l'application

`%APPDATA%\NasManager\` : `parametres.json`, la clé SSH (`id_ed25519`), `known_hosts`.
Supprimer ce dossier remet l'application à zéro.

## Tests (développeurs)

`cargo test` : tests unitaires. Avec un NAS de test (voir `src/remote.rs`, module `live`) :
`NAS_MANAGER_LIVE_TEST=1 NAS_MANAGER_DIR=<dossier de test> cargo test -- --test-threads=1`.
