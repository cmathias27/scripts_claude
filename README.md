# Scripts NAS — sauvegardes, migration et supervision

Ensemble de scripts Bash (avec un peu de Python) pour gérer l'infrastructure de stockage de la maison :

- **migrer** les données de l'ancien NAS **Synology** vers le nouveau NAS **OpenMediaVault (OMV)** et vers **ownCloud Infinite Scale (oCIS)** ;
- **sauvegarder** l'OMV vers **Google Drive**, avec chiffrement, via `rclone` ;
- **synchroniser en temps réel** les vidéos des caméras vers Google Drive ;
- **superviser** le tout : notifications sur le téléphone (ntfy, Telegram, Discord, e-mail ou **Home Assistant**),
  santé des disques (SMART, RAID), rapport hebdomadaire ou mensuel, tableau de bord Home Assistant.

Tous les scripts sont interactifs, en français, et pensés pour être lancés en SSH sans connaître les commandes sous-jacentes.

---

## Sommaire

Depuis NAS Manager 1.1, **un seul script par type de machine**, installé et mis à jour depuis l'application :

| Script | Machine | Rôle |
|---|---|---|
| [`nas-debian.sh`](#nas-debiansh) | OMV et tout Debian (Ubuntu, Raspberry Pi OS…) | Sauvegardes programmées et [temps réel](#sauvegardes-temps-réel-nas-debian-temps-reel) vers Google Drive, alertes et suivi Home Assistant, outils, mémoire de rclone |
| [`nas-synology.sh`](#nas-synologysh) | Synology (DSM 7) | Copie vers l'OMV, migration des « Mon Drive » vers oCIS |

Les anciens scripts (`nas-backup.sh`, `install-alertes.sh`, `install-suivi-ha.sh`, `install-cam-sync.sh`,
`copie-omv.sh`, `migre-drive-ocis.sh`) sont rangés dans [`ancien/`](ancien/). Depuis la 1.2, la
synchro des caméras est une sauvegarde temps réel comme les autres. Leurs **noms de commandes restent
utilisables** (`nas-backup`, `nas-notify`, `nas-check`, `nas-ha-status`, `copie-omv`, `migre-drive-ocis`) :
ce sont des liens vers les nouveaux scripts, qui reconnaissent sous quel nom ils sont lancés.
Les détails ci-dessous décrivent chaque fonction sous son ancien nom.

[`versions-scripts.json`](versions-scripts.json) donne la version et l'empreinte SHA-256 de chaque
script : NAS Manager le lit pour proposer les mises à jour. Après une modification d'un script,
augmenter `SCRIPT_VERSION` puis lancer `python3 maj-versions-scripts.py` (vérifié par GitHub Actions).

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

## Installation

**Depuis NAS Manager** (page Installation) : un clic installe le script de la machine et **tous les outils
nécessaires** (rclone officiel, inotify-tools, client MQTT…), puis connecte Google Drive, les alertes et
le suivi Home Assistant. Une installation faite avec les anciens scripts est **reprise** (bouton
« Migrer ») : les anciens fichiers sont gardés dans `/root/.nas-manager/ancien/`.

**À la main** (en root) : `bash nas-debian.sh` sur l'OMV / Debian (menu ; il s'installe dans
`/usr/local/bin/nas-debian`), `sudo bash nas-synology.sh` sur le Synology.

## `nas-debian.sh`

Commandes principales (toutes sans question, utilisées par NAS Manager) :

| Commande | Effet |
|---|---|
| `nas-debian version` | version du script et machine reconnue (`omv` ou `debian`), en JSON |
| `nas-debian outils etat \| installer [suivi] \| rclone-maj` | état des outils, installation de ce qui manque, mise à jour de rclone |
| `nas-debian reglages voir \| ram <profil> [Mo] [transferts] [verifs] [tampon]` | mémoire attribuée à rclone |
| `nas-debian racines` / `dossiers` | disques de données / dossiers proposés comme sources |
| `nas-debian migrer simulation \| appliquer` | reprise d'une installation faite avec les anciens scripts |
| `nas-debian alertes configurer <ip HA> <webhook>` | alertes Home Assistant (ex-`install-alertes.sh`) |
| `nas-debian alertes voir \| canal <canal> [niveau] \| niveau \| retirer \| tester \| telegram \| seuils` | [canaux de notification](#canaux-de-notification-nas-debian-alertes-canal) : ntfy, Telegram, Discord, e-mail, Home Assistant |
| `nas-debian disques verifier \| etat` | [santé des disques](#santé-des-disques-nas-debian-disques) (SMART, RAID) |
| `nas-debian rapport voir \| envoyer \| planifier <hebdo\|mensuel\|non> [jour] [HH:MM] [canaux]` | [rapport périodique](#rapport-périodique-nas-debian-rapport) |
| `nas-debian suivi configurer <serveur MQTT>` | tableau de bord Home Assistant (ex-`install-suivi-ha.sh`) |
| `nas-debian temps-reel liste \| save \| pause \| reprendre \| …` | sauvegardes temps réel (voir plus bas) |
| `nas-debian destinations liste \| etat [NOM] \| creer NOM TYPE \| jeton NOM TYPE \| supprimer NOM` | [destinations](#destinations-nas-debian-destinations) des sauvegardes (remotes rclone) |
| `nas-debian versions liste \| ls \| restaurer \| entretien` | [sauvegardes versionnées](#sauvegardes-versionnées-restic) (restic) |
| `nas-debian secours etat \| sauvegarder [force] \| telecharger \| restaurer FICHIER [appliquer] \| mots-de-passe` | [kit de secours](#kit-de-secours-nas-debian-secours) |
| `nas-debian mots-de-passe` | tous les mots de passe à noter hors du NAS (chiffrement, versions, kit) |
| `nas-debian run \| save \| restore \| …` | toutes les commandes de `nas-backup` (voir plus bas) |

**Mémoire de rclone** (`/etc/nas-backup/agent.conf`) : profil *économe* (1 fichier à la fois, 1/8 de la
RAM entre 96 et 256 Mo), *équilibré* (4 fichiers, 1/5 de la RAM entre 128 Mo et 1 Go), *performant*
(8 fichiers, 1/3 de la RAM entre 256 Mo et 4 Go) ou *automatique* (selon la RAM de la machine) ;
limite fixe en Mo possible. La limite est appliquée par `GOMEMLIMIT` (limite douce). Chaque
sauvegarde peut avoir son propre réglage (9ᵉ colonne de `jobs.conf`). Après un manque de mémoire, la
sauvegarde reprend automatiquement avec un seul fichier à la fois ; le pic de mémoire est gardé dans
le bilan.

## Destinations (`nas-debian destinations`)

Une destination est un remote rclone : Google Drive (`gdrive`), OneDrive, Dropbox, pCloud, Box, un
disque local ou USB, un autre NAS (SFTP ou SMB), un serveur WebDAV (Nextcloud, ownCloud, oCIS),
Backblaze B2 ou un stockage S3. Elles se créent depuis NAS Manager (page **Destinations**) : les
services à connexion par navigateur (Google, Microsoft, Dropbox…) passent par `rclone authorize` dans
un tunnel SSH, comme Google Drive ; les autres par `destinations creer NOM TYPE` avec les paramètres
`cle=valeur` (mots de passe compris) sur l'entrée standard, suivi d'un **test d'envoi réel**.

Organisation sur chaque destination :

| Emplacement | Contenu |
|---|---|
| `<remote>:NAS/<dossier>` | sauvegardes en clair (corbeille : `NAS/_corbeille/<nom>`) |
| `<remote>-chiffre:<dossier>` | sauvegardes chiffrées : remote crypt sur `<remote>:NAS-chiffre`, **mêmes mots de passe** que `gbackup` (le remote chiffré de `gdrive`) |
| `<remote>:NAS-versions/<dossier>` | dépôts restic des sauvegardes versionnées |
| `<remote>:NAS-secours/` | kit de secours (+ `LISEZMOI.txt`, anciens kits 120 jours) |

Bucket (B2, S3), partage (SMB) ou sous-dossier : remote `<nom>-base` + alias `<nom>`. Un **disque
local** est un alias vers un dossier : refusé s'il est sur le disque système (sauf confirmation), et
une sauvegarde vers un disque débranché échoue au lieu de recréer le dossier sur le disque système.
`nas-check` teste toutes les destinations chaque heure (état et espace dans
`/var/lib/nas-backup/destinations.json`, alertes `dest-<nom>` / `quota-<nom>` ; Google Drive garde
`gdrive` / `quota` et `health.json`). Une destination utilisée par une sauvegarde ne peut pas être
retirée.

## Sauvegardes versionnées (restic)

Troisième mode des sauvegardes programmées, à côté de miroir et copie : chaque exécution enregistre
une **version** complète du dossier dans un dépôt restic (`rclone:<remote>:NAS-versions/<dossier>`),
avec déduplication et chiffrement. Le mot de passe des dépôts est dans `/etc/nas-backup/restic.pass`.

- Rotation après chaque sauvegarde (`restic forget`) : toutes les versions des dernières 24 h, puis
  `jours:semaines:mois:annees` (11ᵉ colonne de `jobs.conf`, par défaut `7:4:12:0`).
- Entretien le dimanche à 5 h 15 (`versions entretien`) : `prune` puis `check --read-data-subset=2%` ;
  alerte `versions-<nom>` en cas d'échec. « Vérifier l'intégrité » lance `check --read-data-subset=5%`.
- `versions liste NOM [DEST]` (JSON), `versions ls NOM DEST VERSION [CHEMIN]`,
  `versions restaurer NOM DEST VERSION DOSSIER [ELEMENT]` (restauration d'un fichier, d'un dossier ou
  de tout, à la date choisie).
- restic est installé par `outils installer` (version officielle de GitHub, celle des paquets
  si GitHub est injoignable) ; `outils restic-maj` le met à jour.

## Kit de secours (`nas-debian secours`)

Tout ce qu'il faut pour reconstruire si le NAS est perdu : `rclone.conf`, mots de passe de chiffrement
(rclone crypt, caméras, restic), `jobs.conf`, `temps-reel.conf`, `agent.conf`, `notify.conf`, réglages
de vérification et connexion MQTT. Archive chiffrée par `openssl` (AES-256-CBC, PBKDF2 200 000
itérations) avec le **mot de passe du kit** (`/etc/nas-backup/secours.pass`, 6 groupes de 4
caractères, affiché par `mots-de-passe`).

- Construit chaque jour à 5 h 40 ; envoyé vers chaque destination s'il a changé, ou chaque semaine
  (`NAS-secours/kit-secours-<machine>.tar.gz.enc`, en clair dans la destination : téléchargeable
  depuis le site du cloud). NAS Manager en garde une copie sur le PC.
- `secours restaurer FICHIER` (mot de passe sur l'entrée standard) liste ce qui serait remis en place ;
  `appliquer` le fait (anciens fichiers gardés dans `/root/.nas-manager/avant-secours-*`), régénère
  les planifications et redémarre les sauvegardes temps réel dont les dossiers existent.
- Sans kit : `secours mots-de-passe` enregistre les mots de passe notés (chiffrement, sel, versions).
- À la main : `openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -md sha256 -in kit-secours-NAS.tar.gz.enc | tar xzv`.

## `nas-synology.sh`

`nas-synology copie <commande>` (ex-`copie-omv`) et `nas-synology migration <commande>`
(ex-`migre-drive-ocis`), plus `version`, `outils etat | installer | rclone-maj`,
`reglages voir | ram … | omv <adresse> | ha <adresse> <webhook>` (fichier `/root/.nas-synology/config` :
plus besoin de modifier le script), `migration jeton` (expiration du jeton d'application oCIS) et
`disques verifier | etat` (santé des disques et du RAID, `/root/.nas-synology/disques.json` ; NAS Manager
la fait vérifier au plus une fois par heure, alertes `disque-<série>` / `raid-<grappe>` envoyées à Home
Assistant si `reglages ha` est renseigné).
Sur le Synology, le profil *automatique* correspond à *équilibré* (2 fichiers à la fois, 1/5 de la RAM
entre 128 et 512 Mo).

---

## `copie-omv` (`nas-synology copie`)

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

## `migre-drive-ocis` (`nas-synology migration`)

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

## `nas-backup` (`nas-debian`)

**À lancer sur l'OMV** : `bash nas-backup.sh` (première fois), puis simplement `nas-backup`.

Gestionnaire de sauvegardes **OMV → Google Drive** avec `rclone` : on définit autant de « sauvegardes » que voulu (un dossier source chacune), chacune avec son mode, son chiffrement, son horaire et sa corbeille.

### Une sauvegarde = une ligne de `/etc/nas-backup/jobs.conf`

```
NOM|SOURCE|DOSSIER|MODE(sync/copy/versions)|CHIFFRE(oui/non)|HORAIRE(HH:MM/manuel)|CORBEILLE_JOURS|DEBIT|MEMOIRE|DESTINATIONS|ROTATION
```

`DESTINATIONS` (script 2.2+) : `remote:oui|non` séparés par `;` (ex. `gdrive:oui;usb:non`), chacune
avec son chiffrement ; vide = Google Drive seul, chiffré selon `CHIFFRE`. Les destinations sont
faites l'une après l'autre ; le bilan (`<nom>.bilan.json`) a une entrée par destination et la
sauvegarde est en échec si l'une d'elles échoue (les autres sont faites quand même).

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

## Sauvegardes temps réel (`nas-debian temps-reel`)

Un ou plusieurs dossiers **surveillés en continu** (`inotifywait`) : chaque fichier créé, modifié ou
supprimé est répercuté sur la destination quelques secondes plus tard. Exemples : les vidéos des
caméras, un dossier de documents. Elles se créent depuis NAS Manager (page « Sauvegardes temps réel »).

### Une sauvegarde = une ligne de `/etc/nas-backup/temps-reel.conf`

`NOM|DOSSIERS|DESTINATION|SUPPRESSION|CORBEILLE_JOURS|EXCLUSIONS|TYPES|DELAI_S|RATTRAPAGE_MIN|ANOMALIE|MEMOIRE|DEBIT`

| Champ | Rôle |
|---|---|
| `DOSSIERS` | un ou plusieurs dossiers séparés par `;` ; avec plusieurs dossiers, chacun va dans un sous-dossier de son nom |
| `DESTINATION` | remote rclone et chemin : `gbackup:Bureau` (Drive chiffré), `gdrive:NAS/Photos`, `gcrypt:` (caméras)… |
| `SUPPRESSION` | `corbeille` : fichiers supprimés **et anciennes versions** gardés `CORBEILLE_JOURS` jours dans `_corbeille/temps-reel/<nom>/<date>` à côté de la destination · `directe` : supprimés aussi sur la destination · `copie` : rien n'est jamais supprimé |
| `EXCLUSIONS`, `TYPES` | motifs séparés par `;` (ex. `cache;*.bak`) ; `TYPES` vide = tous les fichiers. Fichiers temporaires (`*.tmp`, `*.part`, `~$*`…) et dossiers techniques (`@eaDir`, `#recycle`…) toujours exclus |
| `DELAI_S` | regroupement : envoi après X s sans nouveau changement (un fichier modifié en boucle part au plus toutes les 60 s) |
| `RATTRAPAGE_MIN` | `rclone sync`/`copy` complet périodique (fichiers de plus de 2 min) pour ce que la surveillance aurait manqué |
| `ANOMALIE` | seuil de **détection d'anomalie** (0 = désactivée) |
| `MEMOIRE`, `DEBIT` | réglage mémoire de rclone propre à cette sauvegarde, limite de débit |

### Détection d'anomalie

Si plus de `ANOMALIE` fichiers sont supprimés ou modifiés en 10 minutes (rançongiciel, fausse
manipulation), ou si un rattrapage s'apprête à en supprimer autant d'un coup, la sauvegarde **se met
en pause sans rien répercuter** et une alerte critique est envoyée (rappelée tant qu'elle dure).
`nas-debian temps-reel reprendre <nom>` (bouton « Reprendre » de l'application) confirme que les
changements sont voulus : l'état actuel du dossier est alors répercuté tout de suite. À désactiver
pour les caméras, qui effacent régulièrement leurs anciennes vidéos.

### Fonctionnement

| Élément | Rôle |
|---|---|
| Service systemd `nas-temps-reel@<nom>` | surveillance (démarre avec la machine, redémarre en cas d'arrêt) |
| `/etc/cron.d/nas-temps-reel` | rattrapage périodique de chaque sauvegarde (et purge de la corbeille) |
| `/var/log/nas-temps-reel/<nom>.log` | journal (rotation hebdomadaire) |
| `/var/lib/nas-backup/rt-<nom>.*` | envois du jour (`transferts.log`), pause, mémoire utilisée |

La corbeille est purgée **selon la date de suppression** (nom du dossier daté), pas selon la date du
fichier : un vieux fichier supprimé aujourd'hui reste bien X jours. Même règle pour les sauvegardes
programmées depuis la 1.2.

Commandes : `liste`, `save nouveau|modif …`, `supprimer <nom> [effacer-destination]`, `demarrer`,
`arreter`, `redemarrer`, `pause`, `reprendre`, `rattrapage`, `envoi-complet` (tous les fichiers déjà
présents).

### Reprise de l'ancienne synchro des caméras

`nas-debian migrer appliquer` (page Installation, « Migrer ») transforme l'ancienne synchro
`cam-sync` (installée par [`ancien/install-cam-sync.sh`](ancien/install-cam-sync.sh)) en sauvegarde
temps réel « Cameras » : même dossier, même destination chiffrée `gcrypt:` (mêmes mots de passe
dans `/root/cam-crypt-motsdepasse.txt`), suppressions directes et rattrapage comme avant, historique
des envois conservé. L'envoi d'une vidéo en cours est attendu ; les anciens fichiers sont gardés
dans `/root/.nas-manager/ancien`.

> ⚠️ **Sans les mots de passe de chiffrement, les fichiers du Drive sont définitivement illisibles.** Les recopier hors du NAS.

---

## Alertes (`nas-debian alertes`, ex-`install-alertes.sh`)

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

1. **Sauvegardes temps réel** : surveillance active, pas de pause (et ancienne synchro `cam-sync` si elle est encore en place).
2. **Google Drive** accessible (`rclone lsd gdrive:`) ? Sinon, alerte avec la commande `rclone config reconnect gdrive:`.
3. **Espace Drive** : alerte au-delà de 90 % (`QUOTA_ALERT`).
4. **Sauvegardes en retard** : alerte si une sauvegarde planifiée n'a pas réussi depuis 50 h (`LATE_HOURS`).
5. Écrit l'état dans `/var/lib/nas-backup/health.json` et rafraîchit `nas-ha-status`.

### Rattrapage caméras avec alerte

Si `cam-sync` est installé, le cron de rattrapage est remplacé par `/usr/local/bin/cam-sync-catchup.sh`, qui fait le même `rclone sync` mais envoie une alerte critique s'il échoue (et « rétabli » quand ça repart). Si `install-suivi-ha.sh` a déjà installé sa version (alertes + comptage des transferts), elle est conservée.

### Côté Home Assistant

Une automatisation (« NAS - Alertes sauvegardes ») doit écouter les deux webhooks `…-critique` et `…-info` et transformer `title` / `message` / `tag` en notification mobile. Le script envoie une notification de test, et propose une alerte critique de test.

Paramètres : `HA_IP`, `WEBHOOK`, `REPEAT_HOURS`, `QUOTA_ALERT`, `LATE_HOURS`.

### Canaux de notification (`nas-debian alertes canal`)

Home Assistant n'est plus obligatoire : les notifications partent vers un ou plusieurs canaux
(`/etc/nas-backup/canaux.conf`, droits 600), réglés depuis NAS Manager (page Alertes & santé) ou par :

```
printf 'url=https://ntfy.sh/mon-sujet-secret\n' | nas-debian alertes canal ntfy tout
printf 'jeton=123456:ABC...\nconversation=42\n' | nas-debian alertes canal telegram critique
printf 'url=https://discord.com/api/webhooks/...\n' | nas-debian alertes canal discord
printf 'destinataire=moi@exemple.fr\nserveur=smtp.gmail.com\nport=587\nsecurite=starttls\nutilisateur=moi@gmail.com\nmot_de_passe=...\n' \
  | nas-debian alertes canal email
```

- Les paramètres passent par l'entrée standard (jamais dans la liste des processus). Un message de test
  part à l'enregistrement ; `alertes tester [canal]` en renvoie un.
- Niveau par canal : `tout` (alertes et messages discrets) ou `critique` (alertes et « rétabli »
  seulement ; par défaut pour l'e-mail). `alertes niveau <canal> <niveau>` le change.
- `alertes telegram` (jeton du bot sur l'entrée standard) liste les conversations qui ont écrit au bot.
- `alertes voir` : canaux (secrets masqués), seuils, rapport et derniers envois en échec (JSON).
- Une alerte est toujours notée dans `/var/lib/nas-backup/alertes/`, même sans canal ; si tous les envois
  échouent, elle est renvoyée à la vérification suivante. Échecs dans `/var/lib/nas-backup/notifications.log`.
- `alertes seuils <rappel h> <espace %> <retard h>` : rappel d'une alerte non résolue, seuil
  « destination presque pleine », délai avant « sauvegarde en retard ».
- `nas-check` est planifié dès l'installation (cron `/etc/cron.d/nas-check`, hh:07), avec ou sans canal.

### Santé des disques (`nas-debian disques`)

`nas-check` lit chaque heure l'état **SMART** des disques (`smartctl`, paquet `smartmontools` installé
par `outils installer`) sans réveiller ceux qui sont en veille, et l'état du **RAID** (`/proc/mdstat`,
pools ZFS). Résultat dans `/var/lib/nas-backup/disques.json`.

| État | Quand |
|---|---|
| à surveiller | secteurs réalloués, erreurs non corrigées, SSD usé à 80 % ; événement notifié quand ils apparaissent ou augmentent |
| en danger (alerte `disque-<série>`) | secteurs instables ou illisibles, test SMART en échec, SSD usé ou sans réserve, avertissement critique NVMe |
| RAID dégradé (alerte `raid-<grappe>`) | disque en panne ou manquant, grappe arrêtée ; reconstruction suivie |

Les erreurs de transmission en hausse (câble SATA) sont signalées par un événement.

### Rapport périodique (`nas-debian rapport`)

`rapport planifier hebdo 1 08:30` (lundi 8 h 30 ; `mensuel` = le 1er du mois, `non` = arrêt), canaux
au choix en fin de ligne (tous par défaut). Le rapport résume la période : sauvegardes programmées
(réussites, échecs, volumes), temps réel, destinations, espace (relevé toutes les 6 h dans
`espace.jsonl`), disques et alertes. `rapport voir` l'affiche, `rapport envoyer` l'envoie tout de suite.

---

## Suivi Home Assistant (`nas-debian suivi`, ex-`install-suivi-ha.sh`)

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
| Problème de sauvegarde | binary_sensor (problem) | ON si alerte en cours, sauvegarde en échec, sauvegarde temps réel en pause ou arrêtée, caméras arrêtées ou Drive injoignable |
| Connexion Google Drive | binary_sensor (connectivity) | Résultat du dernier `nas-check` |
| Espace Google Drive | sensor (%) | Taux de remplissage ; attributs : Go utilisés / total |
| Dernière vérification | sensor (timestamp) | Heure du dernier `nas-check` |
| Synchro caméras | binary_sensor (running) | Sauvegarde temps réel des caméras (ou ancienne synchro cam-sync) active |
| Dernière vidéo envoyée | sensor (timestamp) | Dernier envoi réussi (`cam-transferts.log`) |
| Vidéos envoyées aujourd'hui | sensor (vidéos) | Remis à zéro à minuit ; attributs : volume du jour, dernière heure (vidéos / volume), suppressions du jour, 7 derniers jours, dernier échec |
| Volume caméras aujourd'hui | sensor (GB) | Volume envoyé depuis minuit |
| Échecs d'envoi caméras (jour) | sensor | Envois / suppressions / rattrapages en échec depuis minuit |
| Sauvegarde en cours | sensor | Nom de la sauvegarde en cours ou `Aucune` ; attributs : progression, transféré / total, vitesse, reste, fichiers envoyés, depuis (min) |
| Progression de la sauvegarde | sensor (%) | 0 hors sauvegarde |
| Volume sauvegardé (24 h) | sensor (GB) | Somme des bilans des sauvegardes terminées dans les 24 h |
| Fichiers sauvegardés (24 h) | sensor (fichiers) | Idem, en nombre de fichiers |
| Sauvegarde `<nom>` | sensor, une par sauvegarde | `OK` / `Échec` / `En cours` / `Jamais lancée` ; attributs : dernière exécution, dernier succès, source, destination, mode, chiffrement, horaire, jours de corbeille, **bilan du dernier transfert** (date, fichiers envoyés / nouveaux / remplacés / retirés, volume, durée, erreurs) et, pendant l'exécution, `en_cours` |
| Temps réel `<nom>` | sensor, une par sauvegarde temps réel | `Actif` / `En pause` / `Arrêté` ; attributs : raison de la pause, dossiers, destination, mode de suppression, envois et volume du jour, dernière heure, suppressions et échecs du jour, dernier envoi, 7 derniers jours |

Les entités passent en *indisponible* si le NAS ne publie plus pendant 20 min, et les entités des sauvegardes supprimées sont retirées automatiquement de HA.

Prérequis : le broker MQTT de HA (`MQTT_HOST`, `MQTT_PORT`), la version de `nas-backup` qui écrit les bilans et, pour l'état Google Drive, la version de `install-alertes.sh` qui écrit `health.json`.

### Carte de tableau de bord

[`carte-transferts-ha.yaml`](carte-transferts-ha.yaml) : carte Markdown de synthèse (sauvegarde en cours, tableau des sauvegardes avec leur dernier transfert, totaux caméras du jour / dernière heure / 7 jours). À coller dans *Modifier le tableau de bord > Ajouter une carte > Manuel*.

---

## Fichiers installés sur l'OMV (récapitulatif)

| Chemin | Créé par |
|---|---|
| `/usr/local/bin/nas-backup` | nas-backup.sh |
| `/usr/local/bin/nas-debian` (+ liens `nas-backup`, `nas-notify`, `nas-check`, `nas-ha-status`) | NAS Manager (page Installation) |
| `/etc/nas-backup/temps-reel.conf`, `/etc/systemd/system/nas-temps-reel@.service`, `/etc/cron.d/nas-temps-reel` | sauvegardes temps réel (nas-debian) |
| `/usr/local/bin/cam-sync.sh`, `/etc/systemd/system/cam-sync.service` | ancien install-cam-sync.sh (repris par la migration) |
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

## Application Windows : NAS Manager

Le dossier [`nas-manager/`](nas-manager/README.md) contient une application Windows (Rust) qui suit et gère
toutes ces synchros sans session SSH : sauvegardes Drive, caméras, alertes, copie Synology → OMV et migration
oCIS. Elle utilise les commandes « sans question » ajoutées à `nas-backup`, `copie-omv` et `migre-drive-ocis`
(les menus interactifs sont inchangés). Le `.exe` est compilé par GitHub Actions (onglet *Actions*).
