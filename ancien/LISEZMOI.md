# Anciens scripts (avant NAS Manager 1.1)

Ces scripts sont remplacés par deux scripts uniques, installés et mis à jour depuis NAS Manager :

| Ancien script | Remplacé par |
|---|---|
| `nas-backup.sh`, `install-alertes.sh` (nas-notify, nas-check), `install-suivi-ha.sh` (nas-ha-status) | `nas-debian.sh` (OMV et tout Debian) |
| `copie-omv.sh`, `migre-drive-ocis.sh` | `nas-synology.sh` |

Les anciens noms de commandes (`nas-backup`, `nas-notify`, `copie-omv`…) restent utilisables :
ce sont des liens vers les nouveaux scripts. La migration d'une installation existante se fait
depuis NAS Manager (page Installation), les anciens fichiers étant gardés dans
`/root/.nas-manager/ancien/` sur la machine.

Ils sont conservés ici pour référence et pour les tests (simulation d'une ancienne installation).
