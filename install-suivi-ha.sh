#!/bin/bash
# =====================================================================
#  install-suivi-ha.sh
#  Publie l'etat des sauvegardes du NAS dans Home Assistant (MQTT)
#  Prerequis : un utilisateur Home Assistant dedie (ex : "nas") pour MQTT
#  Usage : bash install-suivi-ha.sh        (en root)
# =====================================================================
set -uo pipefail
MQTT_HOST="192.168.1.222"
MQTT_PORT=1883

vert()  { echo -e "\e[32m$*\e[0m"; }
jaune() { echo -e "\e[33m$*\e[0m"; }
rouge() { echo -e "\e[31m$*\e[0m"; }
die()   { rouge "ERREUR : $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "lance ce script en root."

echo "== Outils =="
apt-get update -qq && apt-get install -y -qq mosquitto-clients python3 >/dev/null || die "installation de mosquitto-clients impossible."
vert "OK : mosquitto-clients"

echo "== Connexion au serveur MQTT de Home Assistant ($MQTT_HOST) =="
read -r -p "Utilisateur MQTT : " MU
read -r -s -p "Mot de passe     : " MP; echo
mkdir -p /root/.config
printf -- "-h %s\n-p %s\n-u %s\n-P %s\n" "$MQTT_HOST" "$MQTT_PORT" "$MU" "$MP" > /root/.config/mosquitto_pub
chmod 600 /root/.config/mosquitto_pub
if mosquitto_pub -t nas-omv/test -m ok; then
  vert "OK : connexion MQTT"
else
  rm -f /root/.config/mosquitto_pub
  die "connexion MQTT refusee (utilisateur, mot de passe ou adresse). Relance le script."
fi

echo "== Script de publication =="
mkdir -p /var/lib/nas-backup
cat > /usr/local/bin/nas-ha-status <<'PYEOF'
#!/usr/bin/env python3
# =====================================================================
#  nas-ha-status : publie l'etat des sauvegardes du NAS vers Home Assistant
#  (MQTT discovery). Lance toutes les 5 min par cron, et apres chaque
#  sauvegarde par nas-backup.
# =====================================================================
import json, os, re, subprocess, time
from datetime import datetime

STATE_DIR = "/var/lib/nas-backup"
JOBS = "/etc/nas-backup/jobs.conf"
HEALTH = f"{STATE_DIR}/health.json"
PUBLISHED = f"{STATE_DIR}/mqtt-jobs.json"
CAM_LOG = "/var/log/cam-sync.log"
CAM_SCRIPT = "/usr/local/bin/cam-sync.sh"
DISC = "homeassistant"
TOPIC = "nas-omv/sauvegardes/etat"
EXPIRE = 1200  # entites indisponibles si le NAS ne publie plus pendant 20 min

DEVICE = {
    "identifiers": ["nas_omv_sauvegardes"],
    "name": "NAS OMV Sauvegardes",
    "manufacturer": "OpenMediaVault",
    "model": "rclone vers Google Drive",
}


def pub(topic, payload, retain=True):
    # Serveur et identifiants lus dans /root/.config/mosquitto_pub
    args = ["mosquitto_pub", "-t", topic, "-m", payload]
    if retain:
        args.append("-r")
    subprocess.run(args, check=True, timeout=20)


def iso(ts):
    return datetime.fromtimestamp(ts).astimezone().isoformat(timespec="seconds") if ts else None


def slug(name):
    return re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


# --------------------------- Sauvegardes -----------------------------
jobs = {}
if os.path.exists(JOBS):
    for line in open(JOBS):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        p = line.split("|")
        if len(p) < 7:
            continue
        name, src, sub, mode, enc, sched, ret = p[:7]
        status = read(f"{STATE_DIR}/{name}.status")      # "2026-10-13 19:56 OK"
        lastok = read(f"{STATE_DIR}/{name}.lastok")
        last_run = None
        etat = "Jamais lancée"
        if status:
            parts = status.split()
            try:
                last_run = iso(time.mktime(time.strptime(" ".join(parts[:2]), "%Y-%m-%d %H:%M")))
            except (ValueError, IndexError):
                pass
            etat = "OK" if parts[-1] == "OK" else "Échec"
        jobs[slug(name)] = {
            "nom": name,
            "etat": etat,
            "derniere_execution": last_run,
            "dernier_succes": iso(int(lastok)) if lastok.isdigit() else None,
            "source": re.sub(r"^/srv/dev-disk-by-uuid-[^/]+/", "", src),
            "destination": ("NAS-chiffre/" if enc == "oui" else "NAS/") + sub,
            "mode": "miroir" if mode == "sync" else "copie",
            "chiffre": enc == "oui",
            "horaire": sched,
            "corbeille_jours": int(ret) if ret.isdigit() else 0,
        }

# --------------------------- Cameras ---------------------------------
cam_installed = os.path.exists(CAM_SCRIPT)
cam_actif = subprocess.run(["systemctl", "is-active", "--quiet", "cam-sync"]).returncode == 0
cam_dernier = None
try:
    with open(CAM_LOG, "rb") as f:
        f.seek(0, 2)
        f.seek(max(0, f.tell() - 200000))
        for raw in reversed(f.read().decode(errors="ignore").splitlines()):
            if ": Copied" in raw:
                cam_dernier = iso(time.mktime(time.strptime(raw[:19], "%Y/%m/%d %H:%M:%S")))
                break
except (OSError, ValueError):
    pass

# --------------------------- Sante (nas-check) -----------------------
health = {}
try:
    health = json.load(open(HEALTH))
except (OSError, ValueError):
    pass

alertes = sorted(os.listdir(f"{STATE_DIR}/alertes")) if os.path.isdir(f"{STATE_DIR}/alertes") else []
probleme = bool(alertes) or any(j["etat"] == "Échec" for j in jobs.values()) \
    or (cam_installed and not cam_actif) or health.get("gdrive") is False

state = {
    "etat": "Problème" if probleme else "OK",
    "probleme": "ON" if probleme else "OFF",
    "alertes": alertes,
    "nb_sauvegardes": len(jobs),
    "jobs": jobs,
    "cam_installe": cam_installed,
    "cam_actif": "ON" if cam_actif else "OFF",
    "cam_dernier_envoi": cam_dernier,
    "gdrive": "ON" if health.get("gdrive") else "OFF",
    "gdrive_pct": health.get("quota_pct"),
    "gdrive_utilise_go": health.get("used_go"),
    "gdrive_total_go": health.get("total_go"),
    "derniere_verification": health.get("checked"),
    "publie": iso(time.time()),
}


# --------------------------- Discovery -------------------------------
def entity(domain, key, name, extra):
    cfg = {
        "name": name,
        "unique_id": f"nas_omv_{key}",
        "default_entity_id": f"{domain}.nas_{key}",
        "state_topic": TOPIC,
        "expire_after": EXPIRE,
        "device": DEVICE,
    }
    cfg.update(extra)
    pub(f"{DISC}/{domain}/nas_omv/{key}/config", json.dumps(cfg))


entity("sensor", "sauvegardes_etat", "État des sauvegardes", {
    "value_template": "{{ value_json.etat }}",
    "json_attributes_topic": TOPIC,
    "json_attributes_template": "{{ {'alertes': value_json.alertes, 'nb_sauvegardes': value_json.nb_sauvegardes} | tojson }}",
    "icon": "mdi:backup-restore",
})
entity("binary_sensor", "sauvegardes_probleme", "Problème de sauvegarde", {
    "value_template": "{{ value_json.probleme }}",
    "device_class": "problem",
})
entity("binary_sensor", "google_drive", "Connexion Google Drive", {
    "value_template": "{{ value_json.gdrive }}",
    "device_class": "connectivity",
})
entity("sensor", "google_drive_espace", "Espace Google Drive", {
    "value_template": "{{ value_json.gdrive_pct }}",
    "unit_of_measurement": "%",
    "state_class": "measurement",
    "icon": "mdi:google-drive",
    "json_attributes_topic": TOPIC,
    "json_attributes_template": "{{ {'utilise_go': value_json.gdrive_utilise_go, 'total_go': value_json.gdrive_total_go} | tojson }}",
})
entity("sensor", "derniere_verification", "Dernière vérification", {
    "value_template": "{{ value_json.derniere_verification }}",
    "device_class": "timestamp",
    "entity_category": "diagnostic",
})
if cam_installed:
    entity("binary_sensor", "cam_sync", "Synchro caméras", {
        "value_template": "{{ value_json.cam_actif }}",
        "device_class": "running",
        "icon": "mdi:cctv",
    })
    entity("sensor", "cam_dernier_envoi", "Dernière vidéo envoyée", {
        "value_template": "{{ value_json.cam_dernier_envoi }}",
        "device_class": "timestamp",
        "icon": "mdi:cloud-upload",
    })

for key, j in jobs.items():
    entity("sensor", f"sauvegarde_{key}", f"Sauvegarde {j['nom']}", {
        "value_template": "{{ value_json.jobs['%s'].etat if '%s' in value_json.jobs else none }}" % (key, key),
        "json_attributes_topic": TOPIC,
        "json_attributes_template": "{{ value_json.jobs['%s'] | default({}) | tojson }}" % key,
        "icon": "mdi:folder-sync",
    })

# Retire les entites des sauvegardes supprimees
try:
    old = set(json.load(open(PUBLISHED)))
except (OSError, ValueError):
    old = set()
for key in old - set(jobs):
    pub(f"{DISC}/sensor/nas_omv/sauvegarde_{key}/config", "")
with open(PUBLISHED, "w") as f:
    json.dump(sorted(jobs), f)

pub(TOPIC, json.dumps(state, ensure_ascii=False))
PYEOF
chmod 755 /usr/local/bin/nas-ha-status
echo "*/5 * * * * root /usr/local/bin/nas-ha-status >/dev/null 2>&1" > /etc/cron.d/nas-ha-status
chmod 644 /etc/cron.d/nas-ha-status
vert "OK : publication toutes les 5 minutes"

echo "== Premiere publication =="
if [ -x /usr/local/bin/nas-check ] && grep -q health.json /usr/local/bin/nas-check; then
  /usr/local/bin/nas-check
else
  jaune "nas-check n'est pas a jour : relance install-alertes.sh (nouvelle version) pour l'etat Google Drive."
fi
if /usr/local/bin/nas-ha-status; then
  vert "OK : les entites 'NAS OMV Sauvegardes' sont visibles dans Home Assistant."
else
  rouge "Echec de la publication."
fi
