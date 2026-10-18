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
- [ ] **Distinguer deux types de sauvegardes** dans l'application :
  - **Sauvegardes programmées** : celles d'aujourd'hui (`nas-backup`, lancées à horaire fixe ou à la main).
  - **Sauvegardes temps réel** : envoi au fil de l'eau dès qu'un fichier est créé, modifié ou supprimé
    (fonctionnement actuel de la synchro caméras : `inotifywait` + rattrapage périodique).
- [ ] **Ouvrir le temps réel à n'importe quel dossier** : la synchro caméras devient un cas parmi d'autres.
  - Choisir **un ou plusieurs dossiers à surveiller**.
  - La synchro caméras existante est reprise comme une sauvegarde temps réel parmi les autres.
- [ ] **Renommer les pages en conséquence** (menu, raccourcis, aide, traduction anglaise) :
  - « Caméras » → **« Sauvegardes temps réel »** (*Real-time backups*).
  - « Sauvegardes » → **« Sauvegardes programmées »** (*Scheduled backups*).
- [ ] **Installation automatique de TOUS les outils nécessaires** : l'application détecte ce qui manque
      sur le NAS et l'installe elle-même (rclone, `inotify-tools`, remotes, service systemd, cron,
      limite `inotify`, logrotate…), sans aucune commande à taper.
- [ ] **Page d'aide dédiée avec des exemples de configuration** (programmées et temps réel), par exemple :
      caméras en miroir chiffré, documents en temps réel, photos en copie hebdomadaire.
- [ ] **Un seul script par type de machine** au lieu des scripts actuels :
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

### Écarté
- Signature du `.exe` (certificat payant).
- Installateur MSI / setup : l'application reste un `.exe` unique, sans installation.
