#!/bin/bash
# =====================================================================
#  install-suivi-ha.sh  (v2 : synthese des transferts)
#  Publie l'etat des sauvegardes du NAS dans Home Assistant (MQTT)
#   - etat de chaque sauvegarde + bilan du dernier transfert
#     (fichiers envoyes, volume, duree, erreurs)
#   - avancement en direct de la sauvegarde en cours (%, vitesse, reste)
#   - cameras : videos et volume envoyes aujourd'hui / derniere heure / 7 jours
#  Prerequis : un utilisateur Home Assistant dedie (ex : "nas") pour MQTT
#              nas-backup a jour (bilan des transferts)
#  Usage : bash install-suivi-ha.sh        (en root)
#  A relancer apres une reinstallation de install-cam-sync.sh ou
#  install-alertes.sh (ils remplacent les scripts cameras).
# =====================================================================
set -uo pipefail
MQTT_HOST="${NAS_MQTT_HOST:-192.168.1.222}"
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
if [ -f /root/.config/mosquitto_pub ] && mosquitto_pub -t nas-omv/test -m ok 2>/dev/null; then
  vert "OK : connexion MQTT deja configuree (conservee)"
else
  if [ -n "${NAS_MQTT_USER:-}" ]; then
    MU="$NAS_MQTT_USER"; MP="${NAS_MQTT_PASS:-}"      # fournis par NAS Manager
  else
    read -r -p "Utilisateur MQTT : " MU
    read -r -s -p "Mot de passe     : " MP; echo
  fi
  mkdir -p /root/.config
  printf -- "-h %s\n-p %s\n-u %s\n-P %s\n" "$MQTT_HOST" "$MQTT_PORT" "$MU" "$MP" > /root/.config/mosquitto_pub
  chmod 600 /root/.config/mosquitto_pub
  if mosquitto_pub -t nas-omv/test -m ok; then
    vert "OK : connexion MQTT"
  else
    rm -f /root/.config/mosquitto_pub
    die "connexion MQTT refusee (utilisateur, mot de passe ou adresse). Relance le script."
  fi
fi

mkdir -p /var/lib/nas-backup
TR=/var/lib/nas-backup/cam-transferts.log

# --------------------------- Cameras : journal des transferts --------
# Chaque envoi / suppression est trace dans cam-transferts.log :
#   epoch|envoi|suppression|rattrapage|octets|ok|echec|nb_fichiers
if [ -f /usr/local/bin/cam-sync.sh ]; then
  echo "== Cameras : comptage des transferts =="
  CAM_SRC=$(grep -m1 '^SRC=' /usr/local/bin/cam-sync.sh | cut -d'"' -f2)
  CAM_DEST=$(grep -m1 '^DEST=' /usr/local/bin/cam-sync.sh | cut -d'"' -f2); CAM_DEST="${CAM_DEST:-gcrypt:}"
  [ -d "$CAM_SRC" ] || die "dossier cameras introuvable dans cam-sync.sh ($CAM_SRC)."

  # --- synchro temps reel
  cat > /usr/local/bin/cam-sync.sh.new <<EOF
#!/bin/bash
SRC="$CAM_SRC"
DEST="$CAM_DEST"
TR="$TR"
OPTS=(--retries 5 --log-file /var/log/cam-sync.log --log-level INFO)
EOF
  cat >> /usr/local/bin/cam-sync.sh.new <<'EOF'
trace() { echo "$(date +%s)|$1|${2:-0}|$3|${4:-1}" >> "$TR"; }   # trace <action> <octets> <ok|echec> [nb]

inotifywait -m -r -q \
  -e close_write -e moved_to -e delete -e moved_from \
  --exclude '(\.tmp$|\.part$|\.swp$|@eaDir|#recycle)' \
  --format '%e|%w%f' "$SRC" | while IFS='|' read -r EVENT FILE; do
    REL="${FILE#"$SRC"/}"
    case "$EVENT" in
      *ISDIR*)
        case "$EVENT" in
          *DELETE*|*MOVED_FROM*)
            rclone purge "$DEST$REL" "${OPTS[@]}" && trace suppression 0 ok || trace suppression 0 echec ;;
          *MOVED_TO*)
            SZ=$(du -sb "$FILE" 2>/dev/null | cut -f1); NB=$(find "$FILE" -type f 2>/dev/null | wc -l)
            rclone copy "$FILE" "$DEST$REL" "${OPTS[@]}" && trace envoi "${SZ:-0}" ok "$NB" || trace envoi 0 echec "$NB" ;;
        esac ;;
      *DELETE*|*MOVED_FROM*)
        rclone deletefile "$DEST$REL" "${OPTS[@]}" && trace suppression 0 ok || trace suppression 0 echec ;;
      *)
        SZ=$(stat -c %s "$FILE" 2>/dev/null || echo 0)
        rclone copyto "$FILE" "$DEST$REL" "${OPTS[@]}" && trace envoi "$SZ" ok || trace envoi "$SZ" echec ;;
    esac
done
EOF
  chmod 755 /usr/local/bin/cam-sync.sh.new

  # --- rattrapage periodique (avec alerte Home Assistant si nas-notify est installe)
  cat > /usr/local/bin/cam-sync-catchup.sh.new <<EOF
#!/bin/bash
# Rattrapage periodique des cameras : comptage des transferts + alerte Home Assistant
SRC="$CAM_SRC"
DEST="$CAM_DEST"
TR="$TR"
EOF
  cat >> /usr/local/bin/cam-sync-catchup.sh.new <<'EOF'
N=/usr/local/bin/nas-notify
TMP=$(mktemp)
rclone sync "$SRC" "$DEST" --min-age 2m --exclude '@eaDir/**' --exclude '\#recycle/**' \
  --log-file "$TMP" --log-level INFO
rc=$?
now=$(date +%s)
grep -E ' INFO +: .+: Copied \(' "$TMP" | sed -E 's/^.* INFO +: (.+): Copied \(.*$/\1/' |
  while IFS= read -r f; do echo "$now|envoi|$(stat -c %s "$SRC/$f" 2>/dev/null || echo 0)|ok|1"; done >> "$TR"
nd=$(grep -cE ' INFO +: .+: Deleted$' "$TMP")
[ "${nd:-0}" -gt 0 ] && echo "$now|suppression|0|ok|$nd" >> "$TR"
[ $rc -ne 0 ] && echo "$now|rattrapage|0|echec|1" >> "$TR"
cat "$TMP" >> /var/log/cam-sync.log; rm -f "$TMP"
if [ -x "$N" ]; then
  if [ $rc -eq 0 ]; then
    $N ok cam-sync "Caméras" "L'envoi des vidéos vers Google Drive fonctionne de nouveau."
  else
    $N critique cam-sync "Caméras : envoi en échec" "Les vidéos ne partent plus vers Google Drive. Détails : /var/log/cam-sync.log"
  fi
fi
exit $rc
EOF
  chmod 755 /usr/local/bin/cam-sync-catchup.sh.new

  # Remplacement sans perturber les transferts en cours :
  #  - attend la fin d'un rattrapage en cours (meme verrou que le cron) ;
  #  - mv = remplacement atomique : un script deja lance garde l'ancienne version.
  if ! flock -n /run/cam-sync-full.lock true; then
    jaune "Rattrapage cameras en cours : attente de sa fin avant la mise a jour..."
  fi
  flock /run/cam-sync-full.lock sh -c '
    mv -f /usr/local/bin/cam-sync.sh.new /usr/local/bin/cam-sync.sh
    mv -f /usr/local/bin/cam-sync-catchup.sh.new /usr/local/bin/cam-sync-catchup.sh'
  CATCHUP_MIN=$(grep -oE '^\*/[0-9]+' /etc/cron.d/cam-sync 2>/dev/null | tr -d '*/'); CATCHUP_MIN="${CATCHUP_MIN:-15}"
  echo "*/$CATCHUP_MIN * * * * root flock -n /run/cam-sync-full.lock /usr/local/bin/cam-sync-catchup.sh >/dev/null 2>&1" > /etc/cron.d/cam-sync
  chmod 644 /etc/cron.d/cam-sync

  cat > /etc/logrotate.d/cam-transferts <<EOF
$TR {
  weekly
  rotate 1
  missingok
  notifempty
  copytruncate
}
EOF
  touch "$TR"
  # Redemarrage du temps reel entre deux envois (attente max 10 min si une video part)
  cam_rclone() {
    local p
    for p in $(cat /sys/fs/cgroup/system.slice/cam-sync.service/cgroup.procs 2>/dev/null); do
      [ "$(cat /proc/$p/comm 2>/dev/null)" = rclone ] && return 0
    done
    return 1
  }
  if cam_rclone; then
    jaune "Envoi d'une video en cours : attente de la fin avant de redemarrer cam-sync..."
    for _ in $(seq 600); do cam_rclone || break; sleep 1; done
  fi
  systemctl restart cam-sync && vert "OK : comptage des transferts cameras (service cam-sync redemarre)" \
                             || rouge "Le service cam-sync ne redemarre pas : journalctl -u cam-sync -n 50"
else
  jaune "Synchro cameras non installee : comptage cameras ignore."
fi

# --------------------------- Script de publication -------------------
echo "== Script de publication =="
cat > /usr/local/bin/nas-ha-status <<'PYEOF'
#!/usr/bin/env python3
# =====================================================================
#  nas-ha-status : publie l'etat et la synthese des transferts du NAS
#  vers Home Assistant (MQTT discovery). Lance toutes les 5 min par cron,
#  apres chaque sauvegarde et toutes les minutes pendant une sauvegarde
#  par nas-backup.
# =====================================================================
import json, os, re, subprocess, time
from datetime import datetime

STATE_DIR = "/var/lib/nas-backup"
JOBS = "/etc/nas-backup/jobs.conf"
HEALTH = f"{STATE_DIR}/health.json"
PUBLISHED = f"{STATE_DIR}/mqtt-jobs.json"
CAM_TR = f"{STATE_DIR}/cam-transferts.log"
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
NOW = time.time()
MIDNIGHT = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()


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


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def hs(b):
    b = float(b or 0)
    for u in ("o", "Ko", "Mo", "Go"):
        if b < 1024:
            return f"{b:.0f} {u}" if u == "o" else f"{b:.1f} {u}"
        b /= 1024
    return f"{b:.2f} To"


def go(b):
    return round((b or 0) / 1e9, 2)


def running_since(name):
    """Debut de la sauvegarde si elle tourne encore, sinon None."""
    try:
        pid, t0 = read(f"{STATE_DIR}/{name}.running").split()[:2]
        os.kill(int(pid), 0)
        return int(t0)
    except (OSError, ValueError):
        return None


STAT_RE = re.compile(r"^Transferred:\s+([\d.]+\s*\S+)\s*/\s*([\d.]+\s*\S+),\s*(\d+)%,\s*([\d.]+\s*\S+/s),\s*ETA\s*(\S+)")


def live(name, t0):
    """Avancement d'une sauvegarde en cours, d'apres son journal."""
    envoyes, st = 0, None
    try:
        with open(f"{STATE_DIR}/{name}.run.log", errors="ignore") as f:
            for line in f:
                if ": Copied (" in line:
                    envoyes += 1
                else:
                    m = STAT_RE.match(line.strip())
                    if m:
                        st = m.groups()
    except OSError:
        pass
    d = {"fichiers_envoyes": envoyes, "depuis_min": round((NOW - t0) / 60)}
    if st:
        d.update({"transfere": st[0], "total": st[1], "progression": int(st[2]), "vitesse": st[3], "reste": st[4]})
    return d


# --------------------------- Sauvegardes -----------------------------
jobs, en_cours = {}, []
vol24 = fic24 = 0
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
            etat = {"OK": "OK", "ARRETE": "Arrêtée"}.get(parts[-1], "Échec")
        b = load(f"{STATE_DIR}/{name}.bilan.json")
        j = {
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
            # Bilan du dernier transfert
            "dernier_transfert": iso(b.get("fin")),
            "fichiers_envoyes": b.get("fichiers_envoyes"),
            "fichiers_nouveaux": b.get("nouveaux"),
            "fichiers_remplaces": b.get("remplaces"),
            "fichiers_retires": b.get("retires"),
            "erreurs": b.get("erreurs"),
            "volume": hs(b.get("volume_octets")) if b else None,
            "volume_go": go(b.get("volume_octets")) if b else None,
            "duree_min": b.get("duree_min"),
        }
        if b and b.get("fin", 0) >= NOW - 86400:
            vol24 += b.get("volume_octets", 0)
            fic24 += b.get("fichiers_envoyes", 0)
        t0 = running_since(name)
        if t0:
            j["etat"] = "En cours"
            j["en_cours"] = live(name, t0)
            en_cours.append((name, j["en_cours"]))
        jobs[slug(name)] = j

# --------------------------- Cameras ---------------------------------
cam_installed = os.path.exists(CAM_SCRIPT)
cam_actif = subprocess.run(["systemctl", "is-active", "--quiet", "cam-sync"]).returncode == 0
cam = {"jour": 0, "jour_o": 0, "heure": 0, "heure_o": 0, "sem": 0, "sem_o": 0,
       "suppr": 0, "echecs": 0, "dernier": None, "dernier_echec": None}
for path in (CAM_TR + ".1", CAM_TR):
    try:
        with open(path) as f:
            for line in f:
                p = line.strip().split("|")
                if len(p) < 4 or not p[0].isdigit():
                    continue
                ts, action, ok = int(p[0]), p[1], p[3] == "ok"
                size = int(p[2]) if p[2].isdigit() else 0
                nb = int(p[4]) if len(p) > 4 and p[4].isdigit() else 1
                if ts < NOW - 7 * 86400:
                    continue
                if not ok:
                    if ts >= MIDNIGHT:
                        cam["echecs"] += 1
                    cam["dernier_echec"] = max(cam["dernier_echec"] or 0, ts)
                    continue
                if action == "envoi":
                    cam["sem"] += nb; cam["sem_o"] += size
                    cam["dernier"] = max(cam["dernier"] or 0, ts)
                    if ts >= MIDNIGHT:
                        cam["jour"] += nb; cam["jour_o"] += size
                    if ts >= NOW - 3600:
                        cam["heure"] += nb; cam["heure_o"] += size
                elif action == "suppression" and ts >= MIDNIGHT:
                    cam["suppr"] += nb
    except OSError:
        pass

# --------------------------- Sante (nas-check) -----------------------
health = load(HEALTH)

alertes = sorted(os.listdir(f"{STATE_DIR}/alertes")) if os.path.isdir(f"{STATE_DIR}/alertes") else []
probleme = bool(alertes) or any(j["etat"] == "Échec" for j in jobs.values()) \
    or (cam_installed and not cam_actif) or health.get("gdrive") is False

ec = en_cours[0][1] if en_cours else {}
state = {
    "etat": "Problème" if probleme else "OK",
    "probleme": "ON" if probleme else "OFF",
    "alertes": alertes,
    "nb_sauvegardes": len(jobs),
    "jobs": jobs,
    # Synthese des sauvegardes
    "en_cours": ", ".join(n for n, _ in en_cours) if en_cours else "Aucune",
    "en_cours_pct": ec.get("progression", 0),
    "en_cours_detail": ec,
    "sauv_volume_24h_go": go(vol24),
    "sauv_fichiers_24h": fic24,
    # Cameras
    "cam_installe": cam_installed,
    "cam_actif": "ON" if cam_actif else "OFF",
    "cam_dernier_envoi": iso(cam["dernier"]),
    "cam_videos_jour": cam["jour"],
    "cam_volume_jour_go": go(cam["jour_o"]),
    "cam_echecs_jour": cam["echecs"],
    "cam_detail": {
        "volume_jour": hs(cam["jour_o"]),
        "videos_derniere_heure": cam["heure"],
        "volume_derniere_heure": hs(cam["heure_o"]),
        "suppressions_jour": cam["suppr"],
        "videos_7_jours": cam["sem"],
        "volume_7_jours": hs(cam["sem_o"]),
        "dernier_echec": iso(cam["dernier_echec"]),
    },
    # Google Drive
    "gdrive": "ON" if health.get("gdrive") else "OFF",
    "gdrive_pct": health.get("quota_pct"),
    "gdrive_utilise_go": health.get("used_go"),
    "gdrive_total_go": health.get("total_go"),
    "derniere_verification": health.get("checked"),
    "publie": iso(NOW),
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

# Synthese des transferts : sauvegardes
entity("sensor", "sauvegarde_en_cours", "Sauvegarde en cours", {
    "value_template": "{{ value_json.en_cours }}",
    "json_attributes_topic": TOPIC,
    "json_attributes_template": "{{ value_json.en_cours_detail | default({}) | tojson }}",
    "icon": "mdi:progress-upload",
})
entity("sensor", "sauvegarde_progression", "Progression de la sauvegarde", {
    "value_template": "{{ value_json.en_cours_pct | default(0) }}",
    "unit_of_measurement": "%",
    "icon": "mdi:percent-circle",
})
entity("sensor", "sauvegardes_volume_24h", "Volume sauvegardé (24 h)", {
    "value_template": "{{ value_json.sauv_volume_24h_go }}",
    "unit_of_measurement": "GB",
    "device_class": "data_size",
    "suggested_display_precision": 2,
    "icon": "mdi:cloud-upload",
})
entity("sensor", "sauvegardes_fichiers_24h", "Fichiers sauvegardés (24 h)", {
    "value_template": "{{ value_json.sauv_fichiers_24h }}",
    "unit_of_measurement": "fichiers",
    "icon": "mdi:file-upload",
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
    # Synthese des transferts : cameras
    entity("sensor", "cam_videos_jour", "Vidéos envoyées aujourd'hui", {
        "value_template": "{{ value_json.cam_videos_jour }}",
        "unit_of_measurement": "vidéos",
        "state_class": "total_increasing",
        "icon": "mdi:filmstrip",
        "json_attributes_topic": TOPIC,
        "json_attributes_template": "{{ value_json.cam_detail | default({}) | tojson }}",
    })
    entity("sensor", "cam_volume_jour", "Volume caméras aujourd'hui", {
        "value_template": "{{ value_json.cam_volume_jour_go }}",
        "unit_of_measurement": "GB",
        "device_class": "data_size",
        "state_class": "total_increasing",
        "suggested_display_precision": 2,
        "icon": "mdi:cctv",
    })
    entity("sensor", "cam_echecs_jour", "Échecs d'envoi caméras (jour)", {
        "value_template": "{{ value_json.cam_echecs_jour }}",
        "icon": "mdi:alert-circle-outline",
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
vert "OK : publication toutes les 5 minutes (toutes les minutes pendant une sauvegarde)"

if [ -x /usr/local/bin/nas-backup ] && ! grep -q 'bilan.json' /usr/local/bin/nas-backup; then
  jaune "nas-backup n'est pas a jour : lance la nouvelle version (bash nas-backup.sh) pour le bilan des sauvegardes."
fi

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
