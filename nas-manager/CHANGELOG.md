# Journal des modifications

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
