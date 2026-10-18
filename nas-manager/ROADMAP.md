# NAS Manager — feuille de route

## V1 (livrée)

Suivi et gestion sans SSH : sauvegardes Drive, caméras, alertes, copie Synology → OMV,
migration oCIS, journaux, installation / mise à jour des scripts sur les NAS.

## V2 (à réaliser)

### Demandé
- [ ] **Mise à jour de l'application depuis l'application** : détection d'une nouvelle version
      (Release GitHub `nas-manager-latest`), téléchargement et remplacement du `.exe`, redémarrage.
- [ ] **Première installation des scripts depuis l'application** : installation complète sur des NAS
      vierges (rclone, remote `gdrive`, synchro caméras, alertes, suivi Home Assistant), pas seulement
      la mise à jour de scripts déjà présents.
- [ ] **Application bilingue français / anglais** : choix de la langue dans les Paramètres
      (par défaut : langue de Windows).

### Être prévenu sans regarder l'application
- [ ] **Icône dans la zone de notification** (à côté de l'horloge) : verte / orange / rouge selon l'état,
      infobulle de synthèse, l'application continue de surveiller fenêtre fermée. *(priorité 1)*
- [ ] **Notifications Windows** : fin de sauvegarde, de copie, de migration, nouvelle alerte. *(priorité 1)*
- [ ] **Lancement au démarrage de Windows**, réduite dans la zone de notification (case à cocher).

### Mieux comprendre ce qui s'est passé
- [ ] **Historique des sauvegardes** : une ligne par exécution (date, durée, fichiers, volume, erreurs),
      graphique sur 30 jours. Nécessite de conserver les bilans côté OMV. *(priorité 2)*
- [ ] **Explication des échecs en français** : erreurs rclone courantes (jeton Google expiré, quota,
      limite de débit, disque démonté) traduites, avec la marche à suivre et un bouton d'action
      quand c'est possible. *(priorité 2)*
- [ ] **Évolution de l'espace** : courbe d'occupation du Google Drive et des disques de l'OMV,
      estimation de la date de remplissage.

### Gérer plus finement
- [ ] **Planification plus souple** : choix des jours, plusieurs horaires par jour, hebdomadaire. *(priorité 3)*
- [ ] **Arrêter une seule sauvegarde** au lieu de toutes celles en cours.
- [ ] **Limite de débit** pour les sauvegardes et les copies (ex. en journée).
- [ ] **Simulation avant lancement** : ce qu'une sauvegarde miroir enverrait et supprimerait, sans rien faire.
- [ ] **Copie Synology → OMV en file d'attente**, comme la migration.

### Restauration
- [ ] **Parcourir le contenu du Drive** (déchiffré) et restaurer un seul fichier ou dossier.
- [ ] **Restaurer depuis la corbeille du Drive** : fichier supprimé ou ancienne version.
- [ ] **Vérification d'intégrité** NAS ↔ Drive, à la demande ou planifiée.

### Sécurité et confort
- [ ] **Export / import des paramètres** (les mots de passe chiffrés par Windows sont redemandés).
- [ ] **Coffre des mots de passe de chiffrement** : rappel tant qu'ils ne sont pas notés ailleurs,
      export dans un fichier protégé.
- [ ] **Mode lecture seule** (actions masquées).
- [ ] **Thème clair / sombre forcé**.

### Versions
- [ ] **Numéros de version** (1.0.0, 1.1.0…) : une Release GitHub par version avec sa page
      « Nouveautés », version affichée dans l'application. Base de la mise à jour automatique.

### Fiabilité
- [ ] **Journal de l'application** sur le PC et bouton **« Exporter un rapport de diagnostic »**
      (versions, état des connexions, dernières erreurs, sans aucun mot de passe).
- [ ] **Tests automatiques dans GitHub** à chaque envoi : tests unitaires + tests contre un faux NAS
      (OMV et Synology simulés), avant de publier le `.exe`.
- [ ] **Vérification de l'identité du NAS** : empreinte SSH affichée et confirmée à la première connexion
      (au lieu de l'accepter automatiquement), alerte claire si elle change.
- [ ] **Connexion SSH persistante** au lieu d'une connexion par actualisation (plus rapide, moins de charge).

### Ergonomie
- [ ] **Assistant de premier lancement** : adresses → autorisation de la clé → test → installation des scripts.
- [ ] **Raccourcis clavier** (F5 actualiser, Ctrl+1…8 pages) et mémorisation de la fenêtre.
- [ ] **Icônes dessinées** à la place des emojis (rendu identique quelles que soient les polices).
- [ ] **Accessibilité** : contrastes vérifiés, taille du texte réglable, lecteur d'écran.

### Ouverture
- [ ] **Plusieurs NAS** : plusieurs OMV / Synology (ex. chez un proche), sélecteur en haut de l'application.
- [ ] **Accès à distance sécurisé** via Tailscale ou WireGuard, sans ouvrir de port SSH sur Internet.
- [ ] **Documentation utilisateur** illustrée (captures, FAQ des erreurs courantes) et bouton « Aide ».

### Écarté
- Signature du `.exe` (certificat payant).
- Installateur MSI / setup : l'application reste un `.exe` unique, sans installation.
