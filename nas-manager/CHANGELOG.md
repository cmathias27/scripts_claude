# Journal des modifications

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
