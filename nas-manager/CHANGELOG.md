# Journal des modifications

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
