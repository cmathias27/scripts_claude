# NAS Manager — feuille de route

## 0.9 (bêta, livrée)

Suivi et gestion sans SSH : sauvegardes Drive, caméras, alertes, copie Synology → OMV,
migration oCIS, journaux, installation / mise à jour des scripts sur les NAS.

## 1.0 (livrée)

### Demandé
- [x] **Mise à jour de l'application depuis l'application** : détection d'une nouvelle version
      (Release GitHub `nas-manager-latest`), téléchargement et remplacement du `.exe`, redémarrage.
- [x] **Première installation des scripts depuis l'application** : installation complète sur des NAS
      vierges (rclone, remote `gdrive`, synchro caméras, alertes, suivi Home Assistant), pas seulement
      la mise à jour de scripts déjà présents.
- [x] **Application bilingue français / anglais** : choix de la langue dans les Paramètres
      (par défaut : langue de Windows).

### Être prévenu sans regarder l'application
- [x] **Icône dans la zone de notification** (à côté de l'horloge) : verte / orange / rouge selon l'état,
      infobulle de synthèse, l'application continue de surveiller fenêtre fermée. *(priorité 1)*
- [x] **Notifications Windows** : fin de sauvegarde, de copie, de migration, nouvelle alerte. *(priorité 1)*
- [x] **Lancement au démarrage de Windows**, réduite dans la zone de notification (case à cocher).

### Mieux comprendre ce qui s'est passé
- [x] **Historique des sauvegardes** : une ligne par exécution (date, durée, fichiers, volume, erreurs),
      graphique sur 30 jours. Nécessite de conserver les bilans côté OMV. *(priorité 2)*
- [x] **Explication des échecs en français** : erreurs rclone courantes (jeton Google expiré, quota,
      limite de débit, disque démonté) traduites, avec la marche à suivre et un bouton d'action
      quand c'est possible. *(priorité 2)*
- [x] **Évolution de l'espace** : courbe d'occupation du Google Drive et des disques de l'OMV,
      estimation de la date de remplissage.

### Gérer plus finement
- [x] **Planification plus souple** : choix des jours, plusieurs horaires par jour, hebdomadaire. *(priorité 3)*
- [x] **Arrêter une seule sauvegarde** au lieu de toutes celles en cours.
- [x] **Limite de débit** pour les sauvegardes et les copies (ex. en journée).
- [x] **Simulation avant lancement** : ce qu'une sauvegarde miroir enverrait et supprimerait, sans rien faire.
- [x] **Copie Synology → OMV en file d'attente**, comme la migration.

### Restauration
- [x] **Parcourir le contenu du Drive** (déchiffré) et restaurer un seul fichier ou dossier.
- [x] **Restaurer depuis la corbeille du Drive** : fichier supprimé ou ancienne version.
- [x] **Vérification d'intégrité** NAS ↔ Drive, à la demande ou planifiée.

### Sécurité et confort
- [x] **Export / import des paramètres** (les mots de passe chiffrés par Windows sont redemandés).
- [x] **Coffre des mots de passe de chiffrement** : rappel tant qu'ils ne sont pas notés ailleurs,
      export dans un fichier protégé.
- [x] **Mode lecture seule** (actions masquées).
- [x] **Thème clair / sombre forcé**.

### Versions
- [x] **Numéros de version** (1.0.0, 1.1.0…) : une Release GitHub par version avec sa page
      « Nouveautés », version affichée dans l'application. Base de la mise à jour automatique.

### Fiabilité
- [x] **Journal de l'application** sur le PC et bouton **« Exporter un rapport de diagnostic »**
      (versions, état des connexions, dernières erreurs, sans aucun mot de passe).
- [x] **Tests automatiques dans GitHub** à chaque envoi : tests unitaires + tests contre un faux NAS
      (OMV et Synology simulés), avant de publier le `.exe`.
- [x] **Vérification de l'identité du NAS** : empreinte SSH affichée et confirmée à la première connexion
      (au lieu de l'accepter automatiquement), alerte claire si elle change.
- [x] **Connexion SSH persistante** au lieu d'une connexion par actualisation (plus rapide, moins de charge).

### Ergonomie
- [x] **Assistant de premier lancement** : adresses → autorisation de la clé → test → installation des scripts.
- [x] **Raccourcis clavier** (F5 actualiser, Ctrl+1…8 pages) et mémorisation de la fenêtre.
- [x] **Icônes dessinées** à la place des emojis (rendu identique quelles que soient les polices).
- [x] **Accessibilité** : contrastes vérifiés, taille du texte réglable, lecteur d'écran.

### Ouverture
- [x] **Plusieurs NAS** : plusieurs OMV / Synology (ex. chez un proche), sélecteur en haut de l'application.
- [x] **Accès à distance sécurisé** via Tailscale ou WireGuard, sans ouvrir de port SSH sur Internet.
- [x] **Documentation utilisateur** illustrée (captures, FAQ des erreurs courantes) et bouton « Aide ».

## Après la 1.0

Idées en attente, à décider selon l'usage.

### Prochaine mise à jour (demandé)

#### Ordre de réalisation
Une version testable par étape (1.1, 1.2…).

1. **Fondations** *(1.1.0)* : un seul script par machine (OMV, Synology, Debian) + migration des installations
   actuelles · bouton « Installer / Mettre à jour » depuis GitHub (vérification automatique et forcée)
   · installation automatique de tous les outils · entretien des outils et connexion aux clouds depuis
   l'application · contrôle de la RAM attribuée à rclone.
2. **Sauvegardes programmées / temps réel** *(1.2.0)* : séparation des deux types et renommage des pages ·
   temps réel sur n'importe quel(s) dossier(s) · modes de suppression et réglages fins du temps réel ·
   détection d'anomalie.
3. **Destinations et sécurité des données** *(1.3.0)* : autres destinations · multi-destinations chiffrées ·
   sauvegardes versionnées (restic) · sauvegarde de ce qui permet de restaurer.
4. **Être prévenu et surveiller** *(1.4.0)* : notifications ntfy / Telegram / Discord / e-mail · santé des
   disques · rapport hebdomadaire / mensuel.
5. **Fiabilité et restauration** : test de restauration à blanc · retour à une date précise ·
   Wake-on-LAN.
6. **Nouvelles fonctions** : transferts oCIS → Synology / Debian · sauvegarde du PC Windows ·
   version SSH de NAS Manager.
7. **Confort et finitions** : débit selon l'heure, estimation, doublons · actions depuis Home
   Assistant · page d'aide avec exemples de configuration.

#### Détail
- [x] **Distinguer deux types de sauvegardes** dans l'application :
  - **Sauvegardes programmées** : celles d'aujourd'hui (`nas-backup`, lancées à horaire fixe ou à la main).
  - **Sauvegardes temps réel** : envoi au fil de l'eau dès qu'un fichier est créé, modifié ou supprimé
    (fonctionnement actuel de la synchro caméras : `inotifywait` + rattrapage périodique).
- [x] **Ouvrir le temps réel à n'importe quel dossier** : la synchro caméras devient un cas parmi d'autres.
  - Choisir **un ou plusieurs dossiers à surveiller**.
  - La synchro caméras existante est reprise comme une sauvegarde temps réel parmi les autres.
- [x] **Renommer les pages en conséquence** (menu, raccourcis, aide, traduction anglaise) :
  - « Caméras » → **« Sauvegardes temps réel »** (*Real-time backups*).
  - « Sauvegardes » → **« Sauvegardes programmées »** (*Scheduled backups*).
- [x] **Installation automatique de TOUS les outils nécessaires** : l'application détecte ce qui manque
      sur le NAS et l'installe elle-même (rclone, `inotify-tools`, remotes, service systemd, cron,
      limite `inotify`, logrotate…), sans aucune commande à taper.
- [ ] **Page d'aide dédiée avec des exemples de configuration** (programmées et temps réel), par exemple :
      caméras en miroir chiffré, documents en temps réel, photos en copie hebdomadaire.
- [x] **Un seul script par type de machine** au lieu des scripts actuels :
  - **OMV** : remplace `nas-backup`, `cam-sync`, `nas-check`, `nas-notify`, `nas-ha-status`
    (sous-commandes : sauvegarde, temps réel, vérification, notification, état Home Assistant).
  - **Synology** : remplace `copie-omv` et `migre-drive-ocis` (pas d'`apt`, rclone téléchargé à part).
  - **Debian** (nouveau) : même rôle que le script OMV sur un serveur Debian classique
    (chemins de disques libres au lieu de `/srv/dev-disk-by-uuid-*`, pas d'interface OMV).
    OMV étant basé sur Debian, partager le maximum de code entre les deux.
    Doit fonctionner sur **n'importe quelle distribution de la famille Debian** (Debian, Ubuntu,
    Raspberry Pi OS…) et toutes les architectures (amd64, arm64, armv7) : objectif, ouvrir l'outil
    au maximum de machines.
  - Les scripts `install-*.sh` disparaissent : l'installation est faite par l'application.
  - Un numéro de version par script, vérifié et mis à jour par l'application.
  - **Migration automatique** des installations actuelles : reprise de `jobs.conf`, des remotes et
    des mots de passe, puis suppression des anciens services et crons (pas de doublons comme
    aujourd'hui entre `install-cam-sync.sh` et `install-alertes.sh`).
  - Tests contre le faux NAS pour les trois scripts (ajouter un faux Debian).
- [x] **Bouton unique « Installer / Mettre à jour » par script**, dont le libellé suit l'état :
  - **Installer** : script absent de la machine (première fois).
  - **À jour (vX)** : version installée = dernière version publiée sur GitHub (bouton grisé,
    « Réinstaller » disponible dans un menu).
  - **Mettre à jour vX → vY** : nouvelle version disponible sur GitHub, avec la liste des nouveautés.
  - **Vérification…** pendant le contrôle, **GitHub injoignable** si le contrôle échoue
    (installation possible avec la version intégrée à l'application).
  - Les scripts ne sont plus seulement intégrés au `.exe` : ils sont **récupérés sur GitHub**,
    ce qui permet de corriger un script sans republier l'application.
  - Numéro de version dans chaque script + fichier de versions sur GitHub (version, empreinte
    SHA-256, nouveautés) ; empreinte vérifiée avant installation.
  - **Vérification automatique** : au démarrage puis toutes les X heures (réglable dans les
    Paramètres, désactivable), notification Windows quand une mise à jour est disponible.
  - **Vérification forcée** : bouton « Vérifier maintenant ».
  - Mise à jour sans casser ce qui tourne : une sauvegarde ou une migration en cours garde
    l'ancienne version jusqu'à sa fin (remplacement atomique, comme aujourd'hui).
  - Ancienne version gardée sur la machine pour **revenir en arrière** en un clic.

- [ ] **Version SSH de NAS Manager (interface en mode texte)** : utilisable directement dans un terminal
  SSH sur le NAS (ou depuis Linux / Mac / téléphone avec un client SSH), sans PC Windows.
  - Menus au clavier en plein écran (tableau de bord, sauvegardes programmées et temps réel,
    historique, alertes, transferts, journaux, installation), mêmes textes FR / EN que l'application.
  - En Rust avec une bibliothèque d'interface texte (ex. ratatui), en partageant le modèle,
    la lecture de l'état, les explications d'erreurs et les traductions avec l'application Windows.
  - Binaire unique amd64 / arm64 / armv7, installé et mis à jour par l'application ou par
    une commande unique ; fonctionne sur OMV, Synology et Debian.
  - Tourne sur la machine elle-même : lit l'état et appelle le script local sans SSH ;
    peut aussi suivre les autres machines du site en SSH.
  - Fonctionne dans un terminal simple (80 colonnes, sans souris, couleurs facultatives).

#### Sécurité des données
- [x] **Suppressions en temps réel au choix**, réglable par sauvegarde :
  - **suppression directe** (fonctionnement actuel des caméras) ;
  - **corbeille de X jours** sur la destination, comme les sauvegardes programmées ;
  - **copie seule** : rien n'est jamais supprimé sur la destination.
- [x] **Détection d'anomalie** : si beaucoup de fichiers sont supprimés ou modifiés en peu de temps
      (seuil réglable), la synchro se met en pause et une alerte critique est envoyée, au lieu de tout
      répercuter (protection contre les rançongiciels et les fausses manipulations). Reprise manuelle.
- [x] **Sauvegarde de ce qui permet de restaurer** *(1.3.0)* : `rclone.conf`, mots de passe de chiffrement,
      `jobs.conf` et configuration de l'outil, sauvegardés automatiquement, chiffrés, hors du NAS.
      Plus un guide « mon NAS est mort, je reconstruis » dans l'aide.

#### Sauvegardes versionnées (type Hyper Backup)
- [x] **Troisième mode de sauvegarde « Versionnée »** *(1.3.0)*, à côté de miroir et copie, pour les données
      importantes. Basé sur **restic**, qui stocke via rclone : toutes les destinations prévues
      (Drive, OneDrive, B2, SFTP, oCIS…). Binaire unique amd64 / arm64 / armv7 : OMV, Synology, Debian.
  - Instantanés complets, **déduplication** (seuls les morceaux modifiés sont envoyés et stockés),
    chiffrement intégré.
  - **Rotation intelligente** façon Smart Recycle, avec modèles prêts à l'emploi et réglables
    (ex. 7 quotidiennes, 4 hebdomadaires, 12 mensuelles).
  - **Liste des versions** dans l'application : restaurer un fichier, un dossier ou tout,
    à la date choisie.
  - Vérification d'intégrité programmée + test de restauration à blanc.
  - Nettoyage des vieilles versions (opération lourde) programmé la nuit, par ex. hebdomadaire.
  - Mot de passe du dépôt dans le coffre de l'application, avec rappel tant qu'il n'est pas noté
    ailleurs (mot de passe perdu = dépôt entier illisible).
  - Surveiller la mémoire sur le Synology (2 Go) : restic garde son index en mémoire.
  - Expliquer dans l'aide la différence avec miroir / copie : fichiers non lisibles un par un sur
    la destination, restauration uniquement par l'outil.

#### Destinations
- [x] **Autres destinations que Google Drive** *(1.3.0)* : tout ce que gère rclone (OneDrive, Dropbox,
      Backblaze B2, S3, autre NAS en SFTP, WebDAV / oCIS…), choisies par sauvegarde,
      configurées depuis l'application.
- [x] **Multi-destinations (3-2-1)** *(1.3.0)* : une même sauvegarde envoyée vers plusieurs supports
      (ex. Drive + disque USB + autre NAS). **Chiffrement au choix pour chaque destination**,
      si l'utilisateur le demande.

#### Transferts
- [ ] **Copie Synology → OMV d'un seul fichier** (ex. une archive compressée .zip / .7z / .tar.gz),
      et plus seulement d'un dossier entier :
  - l'explorateur permet de choisir un fichier ou un dossier ;
  - le fichier est copié dans le dossier de destination choisi sur l'OMV, sous le même nom ;
  - mêmes options que pour un dossier : file d'attente, suivi (taille réelle du fichier),
    reprise d'un gros fichier interrompu, contrôle puis suppression de l'original en option
    (mode « déplacer »).
- [ ] **Migration vers oCIS depuis d'autres sources que le Synology** : choisir le dossier à migrer
      (avec le même explorateur de dossiers que pour les sauvegardes) :
  - **sur le serveur local** (OMV / Debian), et plus seulement sur le Synology distant :
    la migration est alors exécutée par le script de cette machine ;
  - **sur le disque dur du PC** (dossier local Windows, disque USB branché au PC) : envoi
    depuis l'application, par le même moteur (rclone vers WebDAV d'oCIS).
  - Mêmes options que la migration actuelle : file d'attente, suivi sur la vraie taille de la
    source, reprise après interruption, dates conservées, contrôle de chaque fichier puis
    suppression des originaux en option (renvoi des fichiers en défaut), bilan de fin.
  - Pour le PC : prévenir que le PC doit rester allumé pendant la migration ; reprise
    automatique au redémarrage de l'application.
- [ ] **Transferts oCIS → dossier Synology (DSM) ou Debian** : sens inverse de la migration actuelle.
      Choix de l'espace oCIS (personnel ou projet) et d'un sous-dossier, puis du dossier de destination
      sur le Synology ou la machine Debian. Passage par l'API WebDAV d'oCIS (jamais de lecture directe
      du stockage oCIS), dates de modification conservées, reprise en cas d'interruption,
      file d'attente et suivi comme la migration, notification à la fin.
      **Deux modes au choix** : transfert ponctuel, ou transfert **programmé** (sauvegarde régulière
      de l'oCIS vers le NAS, avec les mêmes options que les sauvegardes programmées).

#### Surveillance
- [x] **Santé des disques** *(1.4.0)* : état SMART, température, secteurs défectueux, état du RAID,
      sur toutes les machines suivies ; alerte avant la panne.
- [x] **Rapport hebdomadaire / mensuel** *(1.4.0)* envoyé sur le téléphone : volumes envoyés, échecs,
      espace restant, santé des disques.

#### Fiabilité
- [ ] **Réveil des machines (Wake-on-LAN)** : réveiller le NAS de destination en veille ou éteint
      avant une sauvegarde ou un transfert, option pour le laisser se rendormir ensuite.
- [ ] **Retour à une date précise** : grâce aux corbeilles datées, restaurer un dossier tel qu'il
      était à une date choisie (« mes documents au 3 octobre »).
- [x] **Contrôle de la mémoire (RAM) attribuée à rclone**, réglable depuis l'application :
  - Par machine, avec possibilité de surcharger par sauvegarde / transfert.
  - Mode **automatique** (comme aujourd'hui pour la migration oCIS : 1/5 de la RAM, entre 128 et
    512 Mo) ou **manuel** (limite en Mo), appliqué à **toutes** les opérations rclone (sauvegardes,
    temps réel, copies, migrations, vérifications), pas seulement à la migration.
  - Réglages associés : nombre de fichiers en parallèle (transfers / checkers), tampon de lecture.
  - Préréglages simples : « Économe » (petit NAS, ex. Synology 2 Go), « Équilibré », « Performant ».
  - Affichage de la RAM totale / libre de la machine et de la mémoire réellement utilisée par rclone
    pendant une opération (pic conservé dans l'historique).
  - Avertissement si la valeur choisie est trop haute pour la machine, et repli automatique sur
    1 fichier à la fois après un manque de mémoire (déjà fait pour la migration, à généraliser).
- [ ] **Test de restauration à blanc** : régulièrement, quelques fichiers au hasard sont restaurés
      dans un dossier temporaire, comparés aux originaux puis effacés ; alerte en cas d'écart.

#### PC Windows
- [ ] **Sauvegarde du PC vers le NAS** depuis l'application : dossiers au choix (Documents, Bureau…),
      programmée ou en temps réel, mêmes options que les autres sauvegardes.

#### Notifications
- [x] **Autres canaux que Home Assistant** *(1.4.0)* : ntfy, Telegram, Discord, e-mail, au choix et combinables.
      Home Assistant devient une option : l'outil doit fonctionner sans lui.

#### Plus aucune ligne de commande
- [x] **Connexion aux clouds depuis l'application** *(Google Drive : 1.0 ; OneDrive, Dropbox, pCloud, Box : 1.3.0)* : la page de connexion (Google, OneDrive,
      Dropbox…) s'ouvre sur le PC, l'application récupère le jeton et l'envoie au NAS.
      Remplace `rclone config reconnect gdrive:` en SSH.
- [x] **Entretien des outils** : vérification de la version de rclone sur chaque machine avec mise à
      jour proposée ; alerte avant l'expiration d'un jeton (Google, mot de passe d'application oCIS…).

#### Confort
- [ ] **Débit selon l'heure** : limites différentes jour / nuit (ex. 2 Mo/s de 8 h à 23 h,
      sans limite la nuit), réglées une fois pour toutes.
- [ ] **Estimation avant la première sauvegarde** : volume à envoyer et durée estimée selon
      le débit réel de la connexion.
- [ ] **Détection des doublons** sur le NAS (photos notamment), pour libérer de la place et
      réduire le volume envoyé. Suppression uniquement après confirmation.
- [x] **Réglages fins du temps réel** : exclusions par dossier, filtre par type de fichier,
      regroupement des envois d'un fichier modifié en boucle (document en cours d'édition).
- [ ] **Actions depuis Home Assistant** : boutons MQTT pour lancer une sauvegarde, mettre en pause
      ou reprendre le temps réel (utilisables dans des automatisations).

### Plus tard
- **Moteur de transfert unique, de n'importe où vers n'importe où** :
  - Des « points » (dossier sur une machine suivie OMV / Synology / Debian, ou stockage distant :
    Drive, oCIS, OneDrive…) et des transferts entre deux points : source, destination, mode
    (copie / miroir / déplacement), chiffrement, ponctuel ou programmé, filtres, limite de débit.
  - La machine qui exécute est choisie automatiquement : NAS → cloud = NAS source (rclone) ;
    cloud → NAS = NAS destination (rclone) ; NAS → NAS = NAS source (rsync, plus léger,
    important pour le Synology à 2 Go) ; cloud → cloud = un NAS au choix.
  - Un seul écran « Transferts » (file d'attente, suivi, historique, notifications).
    Les fonctions actuelles deviennent des modèles : « Synology → OMV », « Synology Drive → oCIS »,
    « oCIS → NAS ».
  - Identifiants des clouds déposés chiffrés sur la machine qui exécute ; mode déplacement
    uniquement avec confirmation explicite.

- **Application Android** (préférée au dashboard web) :
  - Le téléphone parle directement aux NAS en SSH, comme l'application Windows : rien à installer
    ni à exposer sur le NAS. Hors de la maison : via l'application Tailscale.
  - Réutiliser le code Rust / egui (modèle, lecture de l'état, explications d'erreurs, traductions).
  - SSH par une bibliothèque Rust (ex. russh) au lieu du `ssh.exe` de Windows ;
    clé rangée dans le coffre sécurisé d'Android (Keystore).
  - Écrans repensés pour le tactile.
  - Périmètre : **consulter** (état, historique, alertes, espace) et **piloter** (lancer, arrêter,
    mettre en pause). Configuration et mots de passe de chiffrement restent dans l'application Windows.
  - Notifications envoyées par le NAS via ntfy (pas d'interrogation permanente qui vide la batterie).
  - Distribution : APK publié sur GitHub (comme le `.exe`), mise à jour depuis l'application.
    Pas de Play Store pour l'instant. iPhone non couvert.

### Pas pour l'instant
- Sauvegarde des volumes Docker (arrêt / relance du conteneur pendant la copie).
- Rétention indépendante des vidéos caméras sur la destination.
- Interface web servie par le NAS (consultation depuis le téléphone, Mac, Linux).

### Écarté
- Signature du `.exe` (certificat payant).
- Installateur MSI / setup : l'application reste un `.exe` unique, sans installation.
