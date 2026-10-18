# Scripts NAS — sauvegardes, migration et supervision

Ensemble de scripts Bash (avec un peu de Python) pour gérer l'infrastructure de stockage de la maison :

- **migrer** les données de l'ancien NAS **Synology** vers le nouveau NAS **OpenMediaVault (OMV)** et vers **ownCloud Infinite Scale (oCIS)** ;
- **sauvegarder** l'OMV vers **Google Drive**, avec chiffrement, via `rclone` ;
- **synchroniser en temps réel** les vidéos des caméras vers Google Drive ;
- **superviser** le tout depuis **Home Assistant** (notifications sur le téléphone + tableau de bord).

Tous les scripts sont interactifs, en français, et pensés pour être lancés en SSH sans connaître les commandes sous-jacentes.

---

## Sommaire

| Script | Machine | Rôle en une ligne |
|---|---|---|
| [`copie-omv.sh`](#copie-omvsh) | Synology | Copier ou déplacer un dossier du Synology vers l'OMV (rsync, en arrière-plan) |
| [`migre-drive-ocis.sh`](#migre-drive-ocissh) | Synology | Migrer les « Mon Drive » Synology vers des espaces projets oCIS |
| [`nas-backup.sh`](#nas-backupsh) | OMV | Gestionnaire de sauvegardes planifiées OMV → Google Drive |
| [`install-cam-sync.sh`](#install-cam-syncsh) | OMV | Synchro temps réel chiffrée du dossier caméras → Google Drive |
| [`install-alertes.sh`](#install-alertessh) | OMV | Notifications Home Assistant (échecs, retards, Drive plein…) |
| [`install-suivi-ha.sh`](#install-suivi-hash) | OMV | Entités Home Assistant (MQTT) : état des sauvegardes et synthèse des transferts (sauvegardes + caméras) |

## Vue d'ensemble

```
                        ┌──────────────────────┐
   copie-omv.sh  ──────▶│   OMV (192.168.1.190)│──── nas-backup ───────┐
   (rsync / SSH)        │                      │                       ▼
 ┌──────────────┐       │  dossier Cam ────────┼── cam-sync ─────▶  Google Drive
 │   Synology   │       │                      │   (temps réel)     NAS/ , NAS-chiffre/
 │  (ancien NAS)│       │  nas-check (horaire) │                    Cam-chiffre/
 └──────┬───────┘       │  nas-ha-status (5min)│
        │               └─────────┬────────────┘
        │ migre-drive-ocis.sh     │ webhooks (alertes)  +  MQTT (état)
        │ (WebDAV / rclone)       ▼
        ▼               ┌──────────────────────┐
 ┌──────────────┐       │ Home Assistant       │
 │ oCIS (Docker)│       │ (192.168.1.222)      │
 │ 192.168.1.53 │       └──────────────────────┘
 └──────────────┘
```

## Ordre d'installation conseillé (OMV)

Prérequis communs : être `root`, avoir `rclone` installé et un remote **`gdrive`** fonctionnel (`rclone config`).

1. `bash install-cam-sync.sh` — si tu as des caméras à synchroniser.
2. `bash nas-backup.sh` — s'installe tout seul dans `/usr/local/bin/nas-backup`, puis créer ses sauvegardes depuis le menu.
3. `bash install-alertes.sh` — après les deux premiers : il remplace le rattrapage caméras par une version qui alerte.
4. `bash install-suivi-ha.sh` — en dernier : il lit l'état produit par tous les autres.

Côté Synology, `copie-omv.sh` et `migre-drive-ocis.sh` sont indépendants : `sudo bash <script>` suffit.

---

## `copie-omv.sh`

**À lancer sur le Synology** : `sudo bash copie-omv.sh`

Copie (ou déplace) un dossier du Synology vers l'OMV avec `rsync` over SSH, et affiche l'avancement en direct.

### Fonctionnement

- **Clé SSH automatique** : au premier lancement, il génère une clé `ed25519` (`/root/.ssh/id_copie_omv`) et l'installe sur l'OMV. Le mot de passe root de l'OMV n'est demandé qu'une fois. Il installe `rsync` sur l'OMV s'il manque.
- **Navigateur de dossiers** : on choisit la source en parcourant les dossiers partagés du Synology (`/volumeX/...`), puis la destination en parcourant `/srv/dev-disk-by-uuid-*` sur l'OMV (avec possibilité de créer un nouveau dossier). Les dossiers techniques (`@eaDir`, `#recycle`, `#snapshot`…) sont masqués et exclus.
- **Récapitulatif avant lancement** : taille, nombre de fichiers, espace libre sur l'OMV (avec alerte s'il manque de la place), et signalement si la destination contient déjà des fichiers (fusion : rien n'est supprimé côté OMV).
- **Placement** : contenu mis dans un sous-dossier du même nom, ou directement dans la destination (proposé automatiquement si les deux dossiers ont le même nom, pour éviter `Photos/Photos`).
- **Deux modes** :
  - *Copier* : les originaux restent sur le Synology ;
  - *Déplacer* : chaque fichier est supprimé du Synology après avoir été copié (`--remove-source-files`), puis les dossiers vides sont nettoyés. Il faut taper `DEPLACER` pour confirmer.
- **Droits adaptés à OMV** : les fichiers prennent le propriétaire/groupe du dossier de destination (groupe `users` si c'était `root`), dossiers en `2775`, fichiers en `664`, au lieu des ACL Synology.
- **Arrière-plan** : la copie tourne via `nohup setsid`, elle survit à la fermeture de la session SSH. `Ctrl+C` n'arrête que l'affichage.
- **Reprise** : `rsync --partial` — relancer la même copie reprend où elle s'était arrêtée.
- **Notification de fin** : un processus surveille la fin, écrit dans l'historique et envoie une notification Home Assistant (succès = info, échec = critique).

### Menu et commandes

| Commande / menu | Effet |
|---|---|
| `1` Nouvelle copie | Assistant complet décrit ci-dessus |
| `2` / `sudo bash copie-omv.sh suivi` | Reprendre l'affichage de la copie en cours (barre de progression, débit, temps restant) |
| `3` / `sudo bash copie-omv.sh stop` | Arrêter proprement la copie en cours |
| `4` Historique | 20 dernières copies (date, résultat, mode, durée) |
| `5` Réparer les droits | Applique `chown -R` + `2775`/`664` sur un dossier de l'OMV (utile pour des données copiées autrement) |

### Paramètres (en tête du script)

`OMV_HOST`, `OMV_USER`, `OMV_ROOT`, `HA_HOST` (vide = pas de notification), `HA_WEBHOOK`.

### Fichiers

`/root/.copie-omv/` : `en-cours` (copie active), `progression.log`, `historique.log`, `code` (code retour).

---

## `migre-drive-ocis.sh`

**À lancer sur le Synology** : `sudo bash migre-drive-ocis.sh`

Migre le contenu de **Synology Drive** (les « Mon Drive » de chaque utilisateur, ou n'importe quel dossier) vers des **espaces projets oCIS**, avec une file d'attente de migrations.

### Principes

- **Passage par l'API WebDAV d'oCIS** uniquement — jamais d'écriture directe dans le stockage d'oCIS — en conservant les dates de modification.
- **rclone autonome** : si `rclone` n'est pas présent sur le Synology, il est téléchargé dans `/root/.migre-ocis/bin` selon l'architecture (amd64, arm64, armv7).
- **Arrière-plan + reprise** : la file tourne en tâche de fond ; une migration relancée saute les fichiers déjà présents et identiques.
- **Originaux conservés par défaut**. La suppression est une option explicite, contrôlée fichier par fichier (voir plus bas).

### Connexion à oCIS (premier lancement / menu 7)

1. Adresse publique d'oCIS, utilisateur et **jeton d'application** (ou mot de passe si l'auth basique est activée). Le certificat auto-signé peut être accepté.
2. Test de l'API Graph (`/graph/v1.0/me/drives`). En cas de `401`, le script rappelle les variables à activer côté oCIS (`OCIS_ADD_RUN_SERVICES=auth-app`, `PROXY_ENABLE_APP_AUTH=true`) et la commande pour créer un jeton longue durée (`ocis auth-app create … --expiration=2160h`).
3. **Adresse locale** (par défaut `https://192.168.1.53:9200`) : les transferts passent alors directement par le réseau de la maison au lieu d'Internet/Cloudflare — beaucoup plus rapide. Les URL renvoyées par oCIS sont réécrites vers cette adresse.
4. **Test d'envoi réel** dans l'espace personnel du compte, d'abord en WebDAV classique (`vendor=owncloud`), et seulement en dernier recours en mode oCIS natif (`infinitescale`, envoi TUS) qui a un bug connu de consommation mémoire (rclone#8945), fatal sur un NAS à 2 Go. Une ancienne config en mode natif est migrée automatiquement.

La configuration est enregistrée dans `/root/.migre-ocis/config` (droits `600`).

### Ajouter une migration (menu 1)

- **Source** : liste des `Mon Drive` trouvés dans `/volume*/homes/*/Drive` avec leur taille, ou navigation dans les dossiers du NAS, ou chemin saisi.
- **Destination** : liste des espaces projets dont le compte est membre, avec espace libre et quota. Si l'espace est trop petit, le script prévient (les nouveaux espaces oCIS ont 1 Go par défaut) et indique comment lever le quota.
- **Sous-dossier** optionnel dans l'espace.
- **Après le transfert** :
  1. garder les originaux (copie) ;
  2. **contrôler chaque fichier dans oCIS puis supprimer l'original** (confirmation en tapant `SUPPRIMER`). Avertissement spécifique pour les « Mon Drive » : les PC synchronisés avec Synology Drive supprimeraient aussi ces fichiers chez eux — installer d'abord le client oCIS.

### Contrôle et suppression des originaux

Après le transfert, `rclone check --one-way` compare chaque fichier du Synology à sa copie dans oCIS :

- par **empreinte** (SHA1/MD5) quand oCIS en fournit ;
- sinon par **relecture complète** depuis oCIS (`--download`), octet par octet.

Seuls les fichiers **identiques** sont supprimés du Synology. Les fichiers absents, différents ou en erreur sont gardés, et la migration est remise en file pour un nouveau passage. Les vignettes `@eaDir` orphelines et les dossiers vides sont nettoyés ensuite. La liste des fichiers supprimés est conservée dans `/root/.migre-ocis/supprimes-<date>-<nom>.txt`, et les listes du contrôle dans `/root/.migre-ocis/verif-<nom>/`.

**Menu 8 — migration déjà faite** : propose les migrations réussies de l'historique (dont la source existe encore) ou un choix manuel, puis ajoute à la file un contrôle + suppression **sans transfert**. Si des fichiers manquent dans oCIS, ils sont transférés puis contrôlés au passage suivant.

### Robustesse et mémoire

Pensé pour un Synology avec peu de RAM :

- `GOMEMLIMIT` = 1/5 de la RAM (entre 128 et 512 Mo), `GOGC=50`, pas de HTTP/2, pas de tampon de lecture, `TRANSFERS=2` / `CHECKERS=4` ;
- la mémoire réelle de rclone est relevée toutes les 3 s et notée dans le journal ;
- **5 reprises automatiques** (30 s d'intervalle) si rclone s'arrête ; après un manque de mémoire, la suite passe à 1 seul fichier à la fois ;
- **diagnostic de l'arrêt** écrit dans le journal et l'historique : OOM (lecture de `dmesg`), plantage, quota plein (`507`), jeton expiré (`401`), oCIS injoignable, dossier source introuvable… Les erreurs non récupérables (quota, jeton) ne déclenchent pas de reprise inutile.
- notification Home Assistant à la fin du lot (succès ou erreurs).

### Menu et commandes

| Menu | Effet |
|---|---|
| `1` | Ajouter une migration à la file d'attente |
| `2` | Retirer une migration de la file |
| `3` | Lancer la file (en arrière-plan) |
| `4` / `suivi` | Suivre la migration en cours (étape, barre de progression, reprises) |
| `5` / `stop` | Arrêter ; les migrations non terminées retournent dans la file |
| `6` | Historique (30 dernières) |
| `7` | Modifier la connexion oCIS |
| `8` | Contrôler et supprimer les originaux d'une migration déjà faite |

### Fichiers

`/root/.migre-ocis/` : `config`, `file-attente`, `lot`, `en-cours`, `etape`, `progression.log` (+ `.precedent`), `historique.log`, `rclone-err.log`, `supprimes-*.txt`, `verif-*/`, `bin/rclone`.

---

## `nas-backup.sh`

**À lancer sur l'OMV** : `bash nas-backup.sh` (première fois), puis simplement `nas-backup`.

Gestionnaire de sauvegardes **OMV → Google Drive** avec `rclone` : on définit autant de « sauvegardes » que voulu (un dossier source chacune), chacune avec son mode, son chiffrement, son horaire et sa corbeille.

### Une sauvegarde = une ligne de `/etc/nas-backup/jobs.conf`

```
NOM|SOURCE|DOSSIER_DRIVE|MODE(sync/copy)|CHIFFRE(oui/non)|HORAIRE(HH:MM/manuel)|CORBEILLE_JOURS
```

| Champ | Détail |
|---|---|
| Source | Choisie dans la liste des dossiers `/srv/dev-disk-by-uuid-*/*` ou saisie |
| Dossier Drive | Sous-dossier de `NAS/` (en clair) ou du remote chiffré (`NAS-chiffre/`) |
| Mode **miroir** (`sync`) | Le Drive devient identique au NAS ; les suppressions sont répercutées |
| Mode **copie** (`copy`) | Ajoute et met à jour, ne supprime jamais rien sur le Drive |
| Chiffré | Noms et contenus illisibles sur le Drive sans les mots de passe |
| Horaire | Exécution quotidienne à `HH:MM`, ou `manuel` |
| Corbeille | En mode miroir : les fichiers supprimés/écrasés sont déplacés dans `_corbeille/<nom>/<date>` et purgés après N jours (`--backup-dir`) |

### Fonctionnement

- **Auto-installation** dans `/usr/local/bin/nas-backup`, rotation des journaux (`/var/log/nas-backup.log`).
- **Remote chiffré `gbackup`** (→ `gdrive:NAS-chiffre`) créé à la première sauvegarde chiffrée. S'il existe déjà des mots de passe caméras (`/root/cam-crypt-motsdepasse.txt`), ils sont **réutilisés** — un seul jeu de mots de passe pour tout. Ils sont écrits dans `/root/nas-backup-motsdepasse.txt` et affichés : **à noter hors du NAS**.
- **Planification** : `/etc/cron.d/nas-backup` est régénéré à chaque modification. Une seule ligne par horaire : les sauvegardes prévues à la même heure sont lancées **l'une après l'autre** (`run-at`), pas en parallèle — moins de limitations Google Drive, moins de mémoire, journal lisible.
- **Garde-fous** : avertissement si deux sauvegardes écrivent dans le même dossier Drive ; un verrou (`flock`) empêche de lancer deux fois la même sauvegarde ; alerte si le disque source est démonté.
- **Modification** : si la destination change, proposition de supprimer l'ancien emplacement et de relancer.
- **Suppression** : la planification est retirée ; les fichiers du Drive sont conservés sauf confirmation explicite (retaper le nom).
- **Restauration** : copie du Drive vers un dossier `Restauration/<nom>_<date>` sur le même disque (ou ailleurs ; avertissement si on restaure par-dessus la source).
- **Intégration** : appelle `nas-notify` (succès avec le résumé « N fichiers envoyés (volume) » / échec avec la dernière erreur rclone) et `nas-ha-status` après chaque exécution, s'ils sont installés.
- **Suivi des transferts** : pendant une sauvegarde, `nas-ha-status` est relancé toutes les minutes (`HA_LIVE`) pour publier l'avancement dans HA (%, vitesse, reste — en exécution planifiée, rclone écrit ses statistiques toutes les 30 s). À la fin, un bilan est écrit dans `<nom>.bilan.json`.

### Menu et commandes

| Menu / commande | Effet |
|---|---|
| `nas-backup` | Menu : ajouter, modifier, supprimer, lancer une/toutes, restaurer, voir le journal |
| `nas-backup run <NOM>` | Lancer une sauvegarde |
| `nas-backup run-at <HH:MM>` | Lancer à la suite toutes les sauvegardes de cet horaire (utilisé par cron) |
| `nas-backup run-all` | Lancer toutes les sauvegardes |
| `nas-backup stop` | Arrêter proprement les sauvegardes en cours (aussi option 8 du menu) : rclone termine ses envois, aucune sauvegarde suivante n'est lancée, état « ARRETE » sans alerte critique. Les caméras ne sont pas touchées |
| `nas-backup list` | Tableau des sauvegardes et de leur dernière exécution |

### Paramètres

`GDRIVE`, `CRYPT`, `CRYPT_FOLDER`, `PLAIN_FOLDER`, `DEFAULT_RET` (30 j), `DEFAULT_SCHED` (03:30), `HA_LIVE` (60 s).

### État

`/var/lib/nas-backup/<nom>.status` (dernière exécution + OK/ECHEC) et `<nom>.lastok` (horodatage du dernier succès), lus par `nas-check` et `nas-ha-status`.

Suivi des transferts : `<nom>.run.log` (journal rclone de la dernière exécution, recopié ensuite dans `/var/log/nas-backup.log`), `<nom>.running` (présent pendant l'exécution) et `<nom>.bilan.json` (fichiers envoyés / nouveaux / remplacés / retirés, volume, durée, erreurs).

---

## `install-cam-sync.sh`

**À lancer sur l'OMV** : `bash install-cam-sync.sh` — désinstallation : `bash install-cam-sync.sh --uninstall`

Installe une **synchronisation temps réel et chiffrée** du dossier des caméras vers Google Drive, en **miroir exact** : une vidéo supprimée localement (rotation des enregistrements) est aussi supprimée du Drive.

### Ce qui est installé

| Élément | Rôle |
|---|---|
| Remote rclone **`gcrypt`** → `gdrive:Cam-chiffre` | Chiffrement des noms de fichiers, de dossiers et des contenus. Mots de passe générés aléatoirement, enregistrés dans `/root/cam-crypt-motsdepasse.txt` et affichés à la fin |
| `/usr/local/bin/cam-sync.sh` | Boucle `inotifywait` sur le dossier : fichier fermé/déplacé → `rclone copyto` ; fichier supprimé → `rclone deletefile` ; dossier supprimé → `rclone purge`. Ignore `.tmp`, `.part`, `.swp`, `@eaDir`, `#recycle` |
| Service systemd `cam-sync` | Lance la surveillance au démarrage, redémarre automatiquement en cas d'arrêt |
| `/etc/cron.d/cam-sync` | **Rattrapage** toutes les 15 min : `rclone sync` complet (fichiers de plus de 2 min) pour ce que le temps réel aurait raté (coupure réseau, redémarrage…) |
| `/etc/sysctl.d/99-inotify.conf` | Augmente `fs.inotify.max_user_watches` pour les arborescences volumineuses |
| logrotate | Rotation hebdomadaire de `/var/log/cam-sync.log` |

À la fin, le script propose d'envoyer tout de suite les vidéos existantes (sinon le rattrapage s'en charge). La désinstallation retire le service mais conserve le remote, les mots de passe et les vidéos du Drive.

> ⚠️ **Sans les mots de passe, les vidéos du Drive sont définitivement illisibles.** Les recopier hors du NAS.

Lire les vidéos en clair : `rclone ls gcrypt:` / `rclone copy gcrypt:chemin ./`.

---

## `install-alertes.sh`

**À lancer sur l'OMV** : `bash install-alertes.sh`

Branche les sauvegardes sur **Home Assistant** pour recevoir des notifications sur le téléphone. Il détecte l'adresse de HA (ports 8123/80, http/https) et enregistre les réglages dans `/etc/nas-backup/notify.conf`.

### `nas-notify` — envoi des notifications

`nas-notify <niveau> <tag> <titre> <message>` envoie un JSON au webhook HA `<WEBHOOK>-critique` ou `<WEBHOOK>-info`. Chaque alerte a un *tag* ; un fichier dans `/var/lib/nas-backup/alertes/` mémorise les alertes en cours.

| Niveau | Comportement |
|---|---|
| `critique` | Alerte prioritaire ; **rappel toutes les 12 h** tant que le problème n'est pas résolu (pas de spam entre-temps) |
| `succes` | Notification discrète, ou « ✅ Rétabli » si une alerte était en cours |
| `ok` | Silencieux, sauf « ✅ Rétabli » si une alerte était en cours |
| `info` | Notification discrète simple |

### `nas-check` — vérification toutes les heures (cron à hh:07)

1. **Service caméras** : `cam-sync` actif ?
2. **Google Drive** accessible (`rclone lsd gdrive:`) ? Sinon, alerte avec la commande `rclone config reconnect gdrive:`.
3. **Espace Drive** : alerte au-delà de 90 % (`QUOTA_ALERT`).
4. **Sauvegardes en retard** : alerte si une sauvegarde planifiée n'a pas réussi depuis 50 h (`LATE_HOURS`).
5. Écrit l'état dans `/var/lib/nas-backup/health.json` et rafraîchit `nas-ha-status`.

### Rattrapage caméras avec alerte

Si `cam-sync` est installé, le cron de rattrapage est remplacé par `/usr/local/bin/cam-sync-catchup.sh`, qui fait le même `rclone sync` mais envoie une alerte critique s'il échoue (et « rétabli » quand ça repart). Si `install-suivi-ha.sh` a déjà installé sa version (alertes + comptage des transferts), elle est conservée.

### Côté Home Assistant

Une automatisation (« NAS - Alertes sauvegardes ») doit écouter les deux webhooks `…-critique` et `…-info` et transformer `title` / `message` / `tag` en notification mobile. Le script envoie une notification de test, et propose une alerte critique de test.

Paramètres : `HA_IP`, `WEBHOOK`, `REPEAT_HOURS`, `QUOTA_ALERT`, `LATE_HOURS`.

---

## `install-suivi-ha.sh`

**À lancer sur l'OMV** : `bash install-suivi-ha.sh`

Publie l'**état de toutes les sauvegardes** dans Home Assistant via **MQTT discovery** : les entités apparaissent toutes seules, regroupées sous l'appareil **« NAS OMV Sauvegardes »**.

### Installation

- Installe `mosquitto-clients` ;
- demande l'utilisateur/mot de passe MQTT (un utilisateur HA dédié, ex. `nas`), les stocke dans `/root/.config/mosquitto_pub` (`600`) et teste la connexion ;
- installe `/usr/local/bin/nas-ha-status` (Python) et le lance **toutes les 5 minutes** par cron (il est aussi appelé après chaque sauvegarde, toutes les minutes pendant une sauvegarde, et après chaque `nas-check`) ;
- si `cam-sync` est installé, remplace `/usr/local/bin/cam-sync.sh` et `/usr/local/bin/cam-sync-catchup.sh` par des versions qui tracent chaque envoi / suppression dans `/var/lib/nas-backup/cam-transferts.log` (`horodatage|action|octets|ok/echec|nb`, rotation hebdomadaire), puis redémarre `cam-sync`. Le rattrapage garde l'alerte HA. **À relancer après une réinstallation de `install-cam-sync.sh`.**

La connexion MQTT déjà configurée est conservée quand on relance le script.

### Entités créées

| Entité | Type | Contenu |
|---|---|---|
| État des sauvegardes | sensor | `OK` / `Problème` ; attributs : alertes en cours, nombre de sauvegardes |
| Problème de sauvegarde | binary_sensor (problem) | ON si alerte en cours, sauvegarde en échec, caméras arrêtées ou Drive injoignable |
| Connexion Google Drive | binary_sensor (connectivity) | Résultat du dernier `nas-check` |
| Espace Google Drive | sensor (%) | Taux de remplissage ; attributs : Go utilisés / total |
| Dernière vérification | sensor (timestamp) | Heure du dernier `nas-check` |
| Synchro caméras | binary_sensor (running) | Si cam-sync est installé |
| Dernière vidéo envoyée | sensor (timestamp) | Dernier envoi réussi (`cam-transferts.log`) |
| Vidéos envoyées aujourd'hui | sensor (vidéos) | Remis à zéro à minuit ; attributs : volume du jour, dernière heure (vidéos / volume), suppressions du jour, 7 derniers jours, dernier échec |
| Volume caméras aujourd'hui | sensor (GB) | Volume envoyé depuis minuit |
| Échecs d'envoi caméras (jour) | sensor | Envois / suppressions / rattrapages en échec depuis minuit |
| Sauvegarde en cours | sensor | Nom de la sauvegarde en cours ou `Aucune` ; attributs : progression, transféré / total, vitesse, reste, fichiers envoyés, depuis (min) |
| Progression de la sauvegarde | sensor (%) | 0 hors sauvegarde |
| Volume sauvegardé (24 h) | sensor (GB) | Somme des bilans des sauvegardes terminées dans les 24 h |
| Fichiers sauvegardés (24 h) | sensor (fichiers) | Idem, en nombre de fichiers |
| Sauvegarde `<nom>` | sensor, une par sauvegarde | `OK` / `Échec` / `En cours` / `Jamais lancée` ; attributs : dernière exécution, dernier succès, source, destination, mode, chiffrement, horaire, jours de corbeille, **bilan du dernier transfert** (date, fichiers envoyés / nouveaux / remplacés / retirés, volume, durée, erreurs) et, pendant l'exécution, `en_cours` |

Les entités passent en *indisponible* si le NAS ne publie plus pendant 20 min, et les entités des sauvegardes supprimées sont retirées automatiquement de HA.

Prérequis : le broker MQTT de HA (`MQTT_HOST`, `MQTT_PORT`), la version de `nas-backup` qui écrit les bilans et, pour l'état Google Drive, la version de `install-alertes.sh` qui écrit `health.json`.

### Carte de tableau de bord

[`carte-transferts-ha.yaml`](carte-transferts-ha.yaml) : carte Markdown de synthèse (sauvegarde en cours, tableau des sauvegardes avec leur dernier transfert, totaux caméras du jour / dernière heure / 7 jours). À coller dans *Modifier le tableau de bord > Ajouter une carte > Manuel*.

---

## Fichiers installés sur l'OMV (récapitulatif)

| Chemin | Créé par |
|---|---|
| `/usr/local/bin/nas-backup` | nas-backup.sh |
| `/usr/local/bin/cam-sync.sh`, `/etc/systemd/system/cam-sync.service` | install-cam-sync.sh |
| `/usr/local/bin/cam-sync-catchup.sh` | install-alertes.sh, remplacé par install-suivi-ha.sh (comptage) |
| `/usr/local/bin/nas-notify`, `/usr/local/bin/nas-check` | install-alertes.sh |
| `/usr/local/bin/nas-ha-status` | install-suivi-ha.sh |
| `/etc/nas-backup/jobs.conf`, `notify.conf` | nas-backup.sh, install-alertes.sh |
| `/etc/cron.d/nas-backup`, `cam-sync`, `nas-check`, `nas-ha-status` | (un par script) |
| `/var/lib/nas-backup/` | état des sauvegardes, alertes en cours, `health.json` |
| `/var/log/nas-backup.log`, `/var/log/cam-sync.log` | journaux (rotation logrotate) |
| `/root/cam-crypt-motsdepasse.txt`, `/root/nas-backup-motsdepasse.txt` | **mots de passe de chiffrement — à sauvegarder hors du NAS** |

## Sécurité

- Les fichiers de mots de passe et de configuration sont en `chmod 600`, réservés à root.
- Les sauvegardes chiffrées utilisent `rclone crypt` (noms et contenus) : **perdre les mots de passe = perdre les données**.
- Les adresses IP, l'identifiant de webhook Home Assistant et les chemins de disques sont propres à cette installation : adapter les paramètres en tête de chaque script avant de les réutiliser ailleurs.
