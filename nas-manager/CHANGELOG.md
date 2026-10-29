# Journal des modifications

## 1.7.1

Script nas-debian 2.7.0.

### Fichiers en parallèle par sauvegarde
- Nouveau réglage **« Fichiers en parallèle »** dans chaque **sauvegarde programmée** et chaque **sauvegarde temps réel** : **« Réglage de la machine »** (par défaut, valeur affichée) ou un **nombre choisi de 1 à 32**.
- Jusqu'ici, ce nombre ne se réglait que pour toute la machine (page Installation, « Mémoire de rclone »). Il peut maintenant être plus élevé pour une grosse sauvegarde de petits fichiers et plus bas pour une sauvegarde qui ne doit pas charger le NAS.
- S'applique au miroir, à la copie et aux sauvegardes **versionnées** (connexions de restic), ainsi qu'au rattrapage du temps réel. Le nombre de vérifications en parallèle suit automatiquement.
- **Avertissement** si la valeur dépasse ce que la mémoire de la machine permet sans risque ; après un manque de mémoire, la sauvegarde repasse comme avant à 1 fichier à la fois.
- Valeur affichée sur la carte de la sauvegarde et notée dans le journal à chaque lancement.

## 1.7.0

Étapes 7 et 8 de la feuille de route : nouvelles fonctions, confort et finitions (scripts nas-debian 2.6.0 et nas-synology 2.5.0).

### Sauvegarde de ce PC vers le NAS
- Nouvelle page **« Sauvegarde du PC »** : des dossiers du PC (Documents, Bureau, Images… ou n'importe quel dossier) envoyés dans un dossier de l'**OMV / Debian** ou du **Synology**. rclone tourne sur le PC (téléchargé en un clic s'il manque) et passe par **SFTP avec la clé de l'application** : rien à installer sur le NAS.
- **Copie** (rien n'est jamais supprimé sur le NAS) ou **miroir** avec une **corbeille datée** sur le NAS (`.corbeille-pc/<date>`, durée au choix, nettoyée automatiquement).
- **À heure fixe** (mêmes horaires que les sauvegardes programmées) et / ou **en temps réel** : chaque changement part 30 s après le dernier (au plus tard 10 min), tant que l'application est ouverte, même réduite.
- Un créneau manqué (PC éteint, application fermée) est **rattrapé au lancement suivant** ; NAS injoignable (portable hors de la maison) : nouvel essai toutes les 30 minutes, une seule notification. Le PC est tenu éveillé pendant l'envoi.
- Limite de débit, exclusions, suivi en direct, arrêt, historique, journal, notifications Windows (échec, retour à la normale, fin d'une sauvegarde lancée à la main), **estimation** du volume et de la durée de la première sauvegarde.

### NAS Manager en mode texte (SSH)
- Nouveau programme **`nas-manager`** pour un terminal SSH sur l'OMV / Debian ou le Synology (ou depuis Linux, Mac, téléphone) : tableau de bord, sauvegardes programmées (lancer, arrêter), temps réel (pause, reprise, démarrage), historique, alertes (acquitter), transferts (copie, migration et transferts oCIS), journaux suivis en direct.
- Au clavier (Tab ou chiffres pour les pages, ↑ ↓, ? pour l'aide), 80 colonnes suffisent, couleurs facultatives (`--sans-couleur`), français ou anglais (`--lang en`). Chaque action demande une confirmation ; sans les droits root, lecture seule.
- Mêmes textes, même lecture de l'état et mêmes commandes que l'application Windows (code partagé). Suit aussi une autre machine du site : `nas-manager --hote root@192.168.1.190`.
- Programme unique pour amd64, arm64 et armv7, publié avec chaque version ; installé et mis à jour depuis la page Installation (carte 10) ou par `nas-debian tui installer` / `nas-synology tui installer` (empreinte SHA-256 vérifiée).

### Autres clouds
- Nouvelles destinations : **Yandex Disk** et **HiDrive** (connexion dans le navigateur, comme Google Drive), **MEGA**, **Koofr / Digi Storage** et **Proton Drive** (formulaire, test d'envoi réel).

### Débit selon l'heure
- Page Installation, carte 7 : **limite commune** à toutes les sauvegardes de la machine, différente **le jour et la nuit** (ex. 2 Mo/s de 8 h à 23 h, sans limite la nuit), réglée une fois pour toutes. Heures et débits au choix.
- Dans chaque sauvegarde programmée ou temps réel : **« Réglage de la machine »** (par défaut), **« Sans limite »**, une limite fixe ou sa propre plage horaire. Les restaurations et vérifications restent à pleine vitesse.

### Estimation avant la première sauvegarde
- Bouton **« Estimer la première sauvegarde »** dans le formulaire d'une nouvelle sauvegarde et sur la carte d'une sauvegarde jamais lancée : volume à envoyer, nombre de fichiers et **durée estimée** selon le débit réel vers la destination (moyenne des sauvegardes déjà faites vers elle, sinon un envoi de test de 16 Mo), limite de débit comprise.

### Doublons
- Nouvelle page **« Doublons »** : fichiers identiques au bit près (même taille puis même empreinte) dans les dossiers choisis, en arrière-plan sur le NAS en priorité basse ; liens physiques et dossiers techniques ignorés.
- Groupes triés par place récupérable, le plus ancien gardé par défaut, sélection fichier par fichier, filtre. **Rien n'est supprimé sans confirmation** : les fichiers choisis partent dans une **corbeille des doublons** sur le même disque (vidée après 30 jours), après une relecture qui vérifie qu'une copie identique reste en place. Un groupe entièrement choisi est refusé.

### Actions depuis Home Assistant
- Page Installation, carte 6 : **« Autoriser les actions depuis Home Assistant »**. L'appareil du NAS reçoit (découverte MQTT) un bouton **« Lancer »** par sauvegarde programmée, **« Arrêter les sauvegardes »**, **« Vérifier maintenant »** et un **interrupteur par sauvegarde temps réel** (pause / reprise), utilisables dans des automatisations.
- Écoute par un service dédié sur la même connexion MQTT que le suivi, relancé par la vérification horaire. Liste fermée d'actions, noms vérifiés, double appui ignoré, chaque action notée dans le journal.

### Aide
- Section **« Exemples de configuration »** : caméras en miroir chiffré, documents en temps réel avec corbeille, photos en copie hebdomadaire vers deux destinations, papiers en versionnée, ce PC vers le NAS, débit selon l'heure — chaque exemple ouvre le formulaire déjà rempli.
- Sections « Sauvegarde de ce PC », « Débit selon l'heure, estimation, doublons », « Piloter depuis Home Assistant » (avec un exemple d'automatisation) et « NAS Manager en mode texte ».

### Aussi
- Tests automatiques : sauvegarde du PC contre le faux NAS (SFTP), `tests/confort.sh` (débit, estimation, doublons, actions MQTT avec un vrai serveur mosquitto, installation de l'interface texte, nouvelles destinations), rendu de l'interface texte ; compilation de l'interface texte pour les trois architectures dans GitHub.
- Le faux NAS des tests accepte SFTP.

## 1.6.0

Étape 6 de la feuille de route, première partie : migration et transferts oCIS (scripts nas-debian 2.5.0 et nas-synology 2.4.0).

### Migration vers oCIS depuis l'OMV / Debian ou ce PC
- La page **« Migration oCIS »** devient **« oCIS »**, avec deux onglets. Onglet **« Migration vers oCIS »** : choix de la machine d'où part la migration, **Synology**, **OMV / Debian** ou **Ce PC**.
- **OMV / Debian** : la migration est exécutée par le script de la machine, avec les mêmes options que sur le Synology (file d'attente, suivi sur la vraie taille de la source, reprise automatique, dates conservées, contrôle de chaque fichier puis suppression des originaux en option avec renvoi des fichiers en défaut, bilan de fin). Le dossier se choisit avec l'explorateur de dossiers. Chaque machine a sa propre connexion à oCIS.
- **Ce PC** (dossier local, disque USB branché au PC) : rclone tourne sur le PC (téléchargé en un clic depuis downloads.rclone.org s'il manque). Connexion oCIS propre au PC (jeton chiffré avec le compte Windows), choix de l'espace (personnel ou projet), file d'attente, suivi, reprise automatique, contrôle puis suppression des originaux en option, bilan, notification à la fin.
- Le PC doit rester allumé : il est tenu éveillé pendant la migration, et si l'application est fermée en cours de route, la migration reprend à son prochain lancement.

### Transferts oCIS → Synology / OMV
- Onglet **« Transferts oCIS → NAS »** : un dossier d'un espace oCIS (personnel ou projet, sous-dossier choisi avec un explorateur des dossiers d'oCIS) recopié dans un dossier du Synology ou de l'OMV / Debian.
- Toujours par l'accès WebDAV d'oCIS (jamais de lecture directe de son stockage), dates de modification conservées, reprise en cas d'interruption, un transfert à la fois par machine (les autres attendent dans la file), suivi détaillé, journal, historique, notification à la fin.
- **Ponctuel** (lancé tout de suite, retiré de la liste après un succès), **à la demande**, ou **programmé** (jours et heures, comme les sauvegardes programmées : sauvegarde régulière d'oCIS vers le NAS). **Copie** ou **miroir** (ce qui est supprimé dans oCIS l'est aussi sur le NAS, gardé quelques jours dans une corbeille `.corbeille-oCIS`), limite de débit.

### Aussi
- Code oCIS commun aux deux scripts (`commun/ocis.sh`, recopié dans chaque script par `maj-versions-scripts.py`).
- Aide : section « oCIS : migration et transferts ».
- Tests automatiques avec un faux serveur oCIS et le vrai rclone (`tests/ocis.sh`, migration depuis le PC dans les tests de l'application).

## 1.5.0

Étape 5 de la feuille de route : fiabilité et restauration (scripts nas-debian 2.4.0 et nas-synology 2.3.0).

### Test de restauration à blanc
- Menu ⋯ d'une sauvegarde > **« Tester la restauration »** : quelques fichiers pris au hasard (plus anciens que la dernière sauvegarde réussie) sont restaurés depuis **chaque destination** (déchiffrés si besoin) dans un dossier temporaire, comparés octet par octet aux originaux, puis effacés.
- **Test automatique** de toutes les sauvegardes (page Sauvegardes programmées) : jours, heure et nombre de fichiers par sauvegarde.
- Résultat sur la carte de la sauvegarde (fichiers identiques, différents, absents de la sauvegarde, destination illisible) avec le détail ; **alerte critique** en cas d'écart, levée au test réussi suivant. Sauvegardes versionnées comprises (dernière version).

### Retour à une date précise
- Fenêtre de restauration, onglet **« À une date »** : un dossier (ou toute la sauvegarde) remis tel qu'il était à la date choisie, dans un dossier de restauration (les fichiers actuels ne sont pas touchés).
- Sauvegarde **miroir avec corbeille** : reconstitué à partir de la corbeille datée (fichiers supprimés depuis, anciennes versions des fichiers modifiés, sans les fichiers créés après), aussi loin que la durée de la corbeille. Sauvegarde **versionnée** : la dernière version avant la date.
- Dates possibles affichées, **aperçu** (nombre de fichiers, volume, part reprise de la corbeille) avant de lancer ; dates de modification conservées.

### Réveil des machines (Wake-on-LAN)
- **Depuis ce PC** : adresse MAC de chaque machine dans les Paramètres (bouton « Détecter ») ; quand elle ne répond pas, bouton **« Réveiller »**.
- **Avant les sauvegardes** : page Destinations > « Réveil (Wake-on-LAN) » pour un autre NAS ou un PC. Une destination qui ne répond pas est réveillée avant chaque sauvegarde, vérification, test ou restauration ; la sauvegarde attend qu'elle réponde, puis la laisse se rendormir, la remet en veille ou l'éteint (au choix).
- **Copies Synology → OMV** : l'OMV est réveillé avant la copie s'il dort, et peut être remis en veille ou éteint après la dernière copie de la file.
- Une destination en veille avec réveil configuré ne déclenche plus d'alerte « injoignable » lors de la vérification horaire ; le temps réel ne la réveille que s'il y a quelque chose à envoyer.

### Aussi
- Aide : sections « S'assurer qu'on peut restaurer » et « Machines en veille ou éteintes ».
- Tests automatiques du moteur avec les vrais rclone et restic (`tests/restauration.sh`).

## 1.4.0

Étape 4 de la feuille de route : être prévenu et surveiller (scripts nas-debian 2.3.0 et nas-synology 2.2.0).

### Notifications sans Home Assistant
- Page Alertes & santé, **« Ajouter un canal »** : **ntfy** (application gratuite, sans compte : un nom de sujet secret est proposé), **Telegram** (bouton « Trouver » pour l'identifiant de conversation), **Discord** (webhook du salon), **e-mail** (Gmail, Outlook, Free, Orange, OVH ou autre serveur) et **Home Assistant**, combinables.
- Pour chaque canal : **alertes seulement** ou **alertes et messages discrets** ; « Tester », « Modifier », « Retirer ». Un message de test part à l'enregistrement.
- Une alerte dont l'envoi a échoué est renvoyée à la vérification suivante ; les derniers envois en échec sont affichés. Sans aucun canal, les alertes restent visibles dans l'application.
- Réglages des alertes modifiables : rappel d'une alerte non résolue, seuil « destination presque pleine », délai avant « sauvegarde en retard ».
- La vérification horaire est toujours installée (état des destinations et des disques), même sans Home Assistant.

### Santé des disques
- Lecture **SMART** de chaque disque toutes les heures, sur l'OMV/Debian et le Synology : modèle, taille, température, âge, usure des SSD, secteurs réalloués, instables ou illisibles.
- **Alerte avant la panne** : disque « à surveiller » dès les premiers secteurs réalloués (et quand ils augmentent), « en danger » dès des secteurs instables, un test SMART en échec ou un SSD usé ; erreurs de câble signalées.
- **RAID** (mdadm, ZFS) : alerte si une grappe est dégradée, avancement de la reconstruction.
- Les disques en veille ne sont pas réveillés (dernières valeurs gardées).
- Résumé sur le tableau de bord ; alertes du Synology dans la page Alertes, l'icône de notification et les notifications Windows.
- smartmontools installé avec les outils (page Installation).

### Rapport de la semaine ou du mois
- Résumé envoyé sur les canaux choisis : sauvegardes réussies ou en échec, volumes, temps réel, espace des destinations et des disques, santé des disques, alertes de la période.
- Jour et heure au choix, « Aperçu » et « Envoyer maintenant ».

### Aussi
- Aide : section « Être prévenu : notifications, disques, rapport ».
- Correction : adresse de Home Assistant affichée correctement dans la page Installation après un nouvel enregistrement.

## 1.3.0

Étape 3 de la feuille de route : destinations et sécurité des données (script nas-debian 2.2.0).

### Destinations (nouvelle page)
- **Autres destinations que Google Drive** : OneDrive, Dropbox, pCloud, Box (connexion dans le navigateur, comme Google Drive), disque local ou USB, autre NAS en SFTP, partage réseau SMB, WebDAV (Nextcloud, ownCloud, oCIS), Backblaze B2, stockage S3 (Wasabi, Scaleway, AWS, MinIO…).
- Ajout depuis l'application avec un **test d'envoi réel** ; état, espace utilisé et sauvegardes qui l'utilisent pour chaque destination ; « Tester », « Reconnecter », « Retirer » (refusé tant qu'une sauvegarde l'utilise).
- Vérification de chaque destination toutes les heures (connexion, espace) avec alerte si elle devient injoignable ou presque pleine.
- Disque USB : refusé s'il est sur le disque système ; débranché, la sauvegarde vers lui échoue au lieu de remplir le disque système.
- Bilan de la **règle 3-2-1** : sauvegardes avec une seule destination, ou sans copie hors de la maison.

### Sauvegardes vers plusieurs destinations
- Une sauvegarde programmée part vers **une ou plusieurs destinations**, l'une après l'autre, avec le **chiffrement au choix pour chacune** (mêmes mots de passe partout).
- Avancement « Destination 2/3 », bilan et état par destination ; une destination en échec n'empêche pas les autres.
- Restauration et parcours depuis la destination choisie ; vérification d'intégrité sur chaque destination.

### Sauvegardes versionnées (type Hyper Backup)
- Troisième mode à côté de miroir et copie, basé sur **restic** : une version complète à chaque sauvegarde, déduplication (seuls les morceaux modifiés partent), chiffrement intégré, vers n'importe quelle destination.
- Rotation façon Smart Recycle avec modèles (7 jours / 4 semaines / 12 mois…) : toutes les versions des dernières 24 h, puis une par jour, semaine, mois, année.
- **Versions et restauration** : choisir la version (date), parcourir son contenu, restaurer un fichier, un dossier ou tout.
- Nettoyage et contrôle des dépôts chaque dimanche matin, « Vérifier l'intégrité » à la demande ; simulation avant lancement.
- restic installé et mis à jour par l'application (page Installation > Outils).

### Kit de secours
- **Tout ce qu'il faut pour reconstruire** si le NAS est perdu (connexions aux destinations, mots de passe de chiffrement, sauvegardes, réglages), chiffré avec un mot de passe unique à noter.
- Envoyé chaque jour s'il a changé dans le dossier NAS-secours de chaque destination, et **copié automatiquement sur le PC**.
- Page Installation > **Reconstruire après une panne** : choisir le kit, vérifier, restaurer sur la nouvelle machine ; ou saisir les mots de passe notés si on n'a pas de kit.
- Aide : guide « **Mon NAS est mort : reconstruire** », destinations et règle 3-2-1, sauvegardes versionnées.

### Aussi
- Les mots de passe affichés (Alertes > Mots de passe de chiffrement) comprennent ceux des versions et du kit.
- Google Drive devient facultatif ; erreurs expliquées pour les nouvelles situations (mot de passe des versions refusé, disque débranché, destination retirée…).
- Raccourcis : Ctrl+4 Destinations, Ctrl+0 Paramètres.

## 1.2.1

Migration Drive → oCIS : un suivi qui ne prête plus à confusion (script nas-synology 2.1.0).

### Avancement
- **Calculé sur la vraie taille de la source** : au début de chaque migration, la source est mesurée avec les mêmes exclusions que rclone (nombre de fichiers et taille). La barre affiche « 431 176 / 452 310 fichiers » au lieu du pourcentage de rclone, dont le total grossit tant qu'il parcourt le dossier.
- **Reste estimé** sur les 5 dernières minutes, en fichiers et en débit (le plus long des deux), au lieu de l'ETA de rclone qui sautait de 2 h à 6 h d'une seconde à l'autre avec les petits fichiers.
- Données envoyées et taille de la source, débit, fichiers par minute.

### Signalements
- « rclone parcourt encore la source » tant que son total grossit.
- « Au moins X renvoyés » quand rclone a envoyé plus que la taille de la source (nouveaux essais) : c'est ce qui faisait dépasser la taille du dossier d'origine.
- Nouveaux essais de rclone et fichiers en erreur, avec leur liste dans un fichier à part (erreurs-<libellé>.txt).

### Bilan de fin d'étape
- Fichiers et taille sur le Synology et dans oCIS, comptés de la même façon : identique, fichiers manquants (avec alerte Home Assistant) ou fichiers en plus déjà présents dans la destination.
- Nouveaux essais, fichiers en erreur, reprises automatiques et durée. Le résumé apparaît aussi dans l'historique.

### Journal
- Le journal de la page Migration ne montre plus que les événements (étapes, erreurs, nouveaux essais, bilan) : l'avancement est déjà dans la barre.
- rclone écrit ses statistiques toutes les 10 s au lieu de 2 s (journal 5 fois plus léger).
- S'applique aux migrations lancées après la mise à jour du script ; une migration déjà en cours garde l'ancien affichage.

## 1.2.0

Étape 2 de la feuille de route : sauvegardes programmées et sauvegardes temps réel.

### Deux types de sauvegardes
- **Sauvegardes programmées** (ex-page « Sauvegardes ») : à heure fixe ou à la demande, comme avant.
- **Sauvegardes temps réel** (nouvelle page, remplace « Caméras ») : un ou plusieurs dossiers surveillés en continu, chaque fichier créé, modifié ou supprimé part quelques secondes plus tard.
- Menu, raccourcis, tableau de bord, aide et version anglaise renommés en conséquence. Le menu s'élargit pour que les libellés ne soient jamais coupés.

### Sauvegardes temps réel
- **N'importe quel(s) dossier(s)**, vers le Drive chiffré, le Drive en clair ou un autre remote rclone. Avec plusieurs dossiers, chacun va dans un sous-dossier de son nom.
- **Fichiers supprimés au choix** : corbeille de X jours (les anciennes versions des fichiers modifiés sont gardées aussi), suppression directe, ou copie seule (rien n'est jamais supprimé).
- **Réglages fins** : exclusions, types de fichiers, regroupement des envois (un fichier modifié en boucle part au plus toutes les 60 s), rattrapage périodique, mémoire de rclone et limite de débit propres à chaque sauvegarde.
- **Détection d'anomalie** : si trop de fichiers sont supprimés ou modifiés en 10 minutes, ou si un rattrapage s'apprête à en supprimer trop d'un coup, la sauvegarde se met en pause sans rien répercuter et une alerte est envoyée. Bouton « Reprendre » une fois le dossier vérifié.
- Démarrer, arrêter, mettre en pause, rattrapage immédiat, « Tout envoyer maintenant », journal et derniers événements, envois du jour, mémoire utilisée.
- Alertes : sauvegarde en pause, surveillance arrêtée, envois en échec ; une entité Home Assistant par sauvegarde temps réel ; icône et notifications Windows.

### Caméras
- La synchro des caméras devient une **sauvegarde temps réel « Cameras »** : la migration (page Installation) la reprend telle quelle (même dossier, même destination chiffrée, suppressions directes, historique des envois conservé).
- L'ancien installateur install-cam-sync.sh est retiré (rangé dans ancien/).

### Corrections
- Corbeille des sauvegardes programmées : la durée est maintenant comptée **depuis la suppression** du fichier. Avant, un vieux fichier supprimé pouvait disparaître de la corbeille dès la sauvegarde suivante.
- Script nas-debian : la vérification du remote rclone pouvait échouer au hasard (« remote introuvable »), et l'alerte « Google Drive inaccessible » pouvait ne pas partir.

## 1.1.0

Étape 1 de la feuille de route : les fondations.

### Un seul script par machine
- **nas-debian** pour l'OMV et tout Debian (Ubuntu, Raspberry Pi OS…, PC classique ou ARM) : il remplace nas-backup, nas-notify, nas-check et nas-ha-status. OMV est reconnu automatiquement ; sur un Debian classique, tous les disques montés sont proposés.
- **nas-synology** pour le Synology : il remplace copie-omv et migre-drive-ocis. L'adresse de l'OMV et de Home Assistant se règle sans modifier le script.
- Les anciens noms de commandes restent utilisables (liens vers les nouveaux scripts) : rien ne change pour les tâches planifiées ni pour Home Assistant.
- **Migration de l'installation existante** (page Installation) : « Voir ce qui va changer », puis « Migrer ». Réglages, historique et sauvegardes en cours sont conservés, les anciens scripts gardés dans /root/.nas-manager/ancien.

### Installer / mettre à jour les scripts
- Un bouton unique par machine : **Installer**, **À jour (vX)** ou **Mettre à jour vX → vY** avec les nouveautés.
- Les scripts sont récupérés sur GitHub, ce qui permet de les corriger sans republier l'application ; leur empreinte (SHA-256) est vérifiée avant installation. Sans accès à GitHub, la version fournie avec l'application est installée.
- Vérification automatique au démarrage puis toutes les 12 heures (réglable, désactivable), « Vérifier maintenant », notification Windows quand une mise à jour est disponible.
- **Retour à la version précédente** en un clic. Une sauvegarde ou une migration en cours continue avec l'ancienne version.

### Installation automatique de tous les outils
- L'installation du script installe aussi tout ce qui manque : rclone officiel (à la place d'une ancienne version des paquets), curl, unzip, inotify-tools, openssl, logrotate, client MQTT si besoin, limite de surveillance de fichiers.
- Page Installation : liste des outils de chaque machine, « Installer ce qui manque », **mise à jour de rclone** quand une nouvelle version sort.
- Synology : téléchargement de rclone, clé SSH vers l'OMV, et **contrôle du jeton oCIS** (refusé, ou expiration proche).

### Mémoire de rclone
- Réglable par machine : **Automatique**, **Économe**, **Équilibré**, **Performant**, ou limite fixe en Mo ; fichiers et vérifications en parallèle, tampon de lecture (avancé). Avertissement si la limite dépasse les 3/4 de la mémoire.
- Réglable aussi **par sauvegarde** (formulaire de la sauvegarde).
- Appliqué à toutes les opérations rclone (sauvegardes, simulations, vérifications, restaurations, migration oCIS).
- Mémoire utilisée affichée pendant une sauvegarde et **pic gardé dans le bilan**.
- Après un manque de mémoire, la sauvegarde reprend automatiquement avec un seul fichier à la fois.

## 1.0.0

Version 1.0 : dernière étape (ouverture et finitions). Elle rassemble tout ce qui a été livré dans les versions 1.0.0-beta.1 à beta.5.

### Installation des NAS depuis l'application (nouvelle page)
- Première installation sur des NAS vierges, sans rien taper en SSH : rclone, connexion Google Drive, nas-backup, synchro des caméras (dossier au choix, envoi des vidéos existantes en arrière-plan), alertes Home Assistant, tableau de bord Home Assistant (MQTT), scripts du Synology.
- Connexion Google Drive : la page d'autorisation Google s'ouvre dans le navigateur du PC, l'autorisation est transmise à l'OMV par la connexion SSH.
- État de chaque élément (installé, version, à mettre à jour) et bouton pour installer ou réinstaller.

### Assistant de premier lancement
- Langue, adresses des NAS, autorisation de la clé, puis direction la page Installation.
- Relançable depuis la page Aide.

### Anglais
- Interface entièrement disponible en anglais (Paramètres > Préférences > Langue), par défaut la langue de Windows.
- Les messages produits par les scripts des NAS restent en français.

### Aide (nouvelle page)
- Premiers pas, accès à distance sécurisé (Tailscale ou WireGuard, sans ouvrir de port SSH), erreurs fréquentes, raccourcis, fichiers de l'application.

### Aussi dans cette version
- Mise à jour de l'application depuis l'application (recherche une fois par jour, installation en un clic, redémarrage).
- Plusieurs sites (un OMV et un Synology chacun, ex. chez un proche) avec sélecteur en haut de la fenêtre.
- Taille du texte réglable, icônes dessinées à la place des emojis.
- Coffre des mots de passe de chiffrement : rappel tant qu'ils ne sont pas notés, enregistrement dans un fichier.
- install-cam-sync.sh, install-alertes.sh, install-suivi-ha.sh : utilisables sans question (installation depuis l'application), toujours utilisables à la main en SSH.

## 1.0.0-beta.5

Étape 5 sur 6 de la version 1.0 : restauration.

### Restaurer
- Parcourir le contenu du Drive d'une sauvegarde (déchiffré) et restaurer un seul fichier ou dossier.
- Restaurer depuis la corbeille du Drive : fichiers supprimés ou anciennes versions gardés par les sauvegardes miroir, rangés par date.
- Restaurer dans un autre dossier, ou à l'emplacement d'origine (avec confirmation, les fichiers locaux de même nom étant remplacés).

### Vérifier
- Vérification d'intégrité d'une sauvegarde (menu ⋯) : chaque fichier du NAS est comparé à sa copie sur le Drive (empreintes, déchiffrement pour les sauvegardes chiffrées). Résultat sur la carte de la sauvegarde, avec le détail des écarts.
- Vérification automatique de toutes les sauvegardes, les jours et à l'heure choisis, avec notification en cas d'écart.

### Corrections
- nas-backup : échec aléatoire possible « remote 'gdrive' introuvable » au lancement d'une commande (également corrigé dans install-cam-sync.sh).

nas-backup passe en version 4 : mets-le à jour depuis Paramètres > Scripts sur les NAS.

## 1.0.0-beta.4

Étape 4 sur 6 de la version 1.0 : gérer plus finement.

### Sauvegardes
- Planification souple : tous les jours, certains jours seulement (ex. lundi, mercredi, vendredi), plusieurs heures par jour, ou un horaire avancé. L'alerte de retard tient compte de ces jours.
- Arrêter une seule sauvegarde (bouton « Arrêter » sur sa carte) : les autres continuent, elle reprendra à sa prochaine exécution.
- Limite de débit : toujours, ou seulement en journée (8 h – 23 h) pour ne pas saturer Internet, pleine vitesse la nuit.
- Simulation (menu ⋯) : liste ce qu'une sauvegarde enverrait et surtout supprimerait sur le Drive, sans rien faire.

### Copie Synology → OMV
- File d'attente : plusieurs copies programmées à la suite, la suivante part quand la précédente se termine avec succès.
- Limite de débit pour chaque copie.

nas-backup passe en version 3 et copie-omv en version 2 : mets-les à jour depuis Paramètres > Scripts sur les NAS.
Si les alertes sont installées, le seuil de retard de nas-check est adapté automatiquement à la mise à jour.

## 1.0.0-beta.3

Étape 3 sur 6 de la version 1.0 : mieux comprendre ce qui s'est passé.

### Historique (nouvelle page, Ctrl+3)
- Chaque exécution de sauvegarde est enregistrée : date, durée, fichiers, volume, fichiers retirés, erreur.
- Indicateurs sur 7, 30, 90 ou 365 jours : exécutions, taux de réussite, volume et fichiers envoyés, durée moyenne.
- Graphique du volume envoyé par jour (jours avec un échec en rouge), filtrable par sauvegarde.

### Explication des erreurs
- Les erreurs courantes sont expliquées en français avec la marche à suivre : autorisation Google expirée, Drive ou espace oCIS plein, limite de débit de Google, disque démonté, Internet coupé, jeton oCIS refusé, mémoire insuffisante, droits…
- Affichées sous une sauvegarde en échec, sur la page Caméras, pour une copie en échec et dans les résultats de migration.

### Évolution de l'espace
- Courbe d'occupation du Google Drive avec la date estimée où il sera plein, et courbe des disques de l'OMV (un relevé toutes les 6 h).

### Corrections
- nas-backup : une sauvegarde terminée pouvait rester vue « en cours » (et refuser d'être relancée) jusqu'à une minute après sa fin.

nas-backup passe en version 2 : mets-le à jour depuis Paramètres > Scripts sur les NAS.

## 1.0.0-beta.2

Étape 2 sur 6 de la version 1.0 : être prévenu sans regarder l'application.

### Zone de notification
- Icône à côté de l'horloge : pastille verte (tout va bien), bleue (transfert en cours), rouge (problème), avec un résumé au survol.
- Fermer la fenêtre la réduit dans la zone de notification : la surveillance continue. Clic sur l'icône pour la rouvrir, clic droit pour Actualiser ou Quitter.

### Notifications Windows
- Fin d'une sauvegarde (avec son bilan), d'une restauration, d'une copie vers l'OMV, d'une migration oCIS.
- Nouvelle alerte, caméras arrêtées ou relancées, NAS injoignable puis de nouveau joignable.
- Clic sur une notification : ouvre l'application. Désactivables dans les Paramètres.

### Démarrage avec Windows
- Option dans les Paramètres : NAS Manager se lance réduit dans la zone de notification.

## 1.0.0-beta.1

Étape 1 sur 6 de la version 1.0 : fondations et confort.

### Fondations
- Numéros de version : chaque version a sa Release GitHub et sa page de nouveautés (cette fenêtre).
- Tests automatiques dans GitHub à chaque modification, contre un faux OMV et un faux Synology, avant de publier l'exécutable.
- Journal de l'application et bouton « Exporter un rapport de diagnostic » (Paramètres), sans aucun mot de passe.
- Identité des NAS confirmée à la première connexion (empreinte SSH), puis vérifiée strictement.
- Connexion persistante à chaque NAS : actualisations plus rapides et moins de charge.

### Confort
- Raccourcis clavier : F5 actualise, Ctrl+1 à Ctrl+8 changent de page.
- Thème clair, sombre ou automatique.
- Mode lecture seule : consultation sans aucune action possible.
- Export / import des paramètres (pour un autre PC).

## 0.9 (bêta)
- Première version : sauvegardes Drive, caméras, alertes, copie Synology → OMV, migration oCIS, journaux, installation des scripts.
