#!/bin/bash
# =====================================================================
#  nas-debian : script unique des machines Debian (OpenMediaVault compris)
#
#  Regroupe ce qui etait fait par plusieurs scripts :
#    nas-backup     sauvegardes programmees vers Google Drive (rclone)
#    nas-notify     notifications Home Assistant
#    nas-check      verification horaire (Drive, quota, retards...)
#    nas-ha-status  etat publie dans Home Assistant (MQTT)
#  Ces anciens noms restent utilisables : ce sont des liens vers ce script,
#  qui reconnait sous quel nom il est lance.
#
#  OMV est reconnu automatiquement (disques dans /srv/dev-disk-by-*) ;
#  sur un Debian classique (Ubuntu, Raspberry Pi OS...), tous les disques
#  montes sont proposes.
#
#  Lancement interactif (menu)   : nas-debian
#  Commandes (sans question, utilisees par l'application NAS Manager) :
#    version                        version du script (JSON)
#    installer                      dossiers, liens nas-backup/nas-notify/..., journaux
#    outils etat | installer | rclone-maj
#    reglages voir | ram <auto|econome|equilibre|performant> [Mo] [transferts] [verifs] [tampon]
#    racines | dossiers             disques de donnees | sous-dossiers proposes comme sources
#    migrer simulation | appliquer  reprise d'une installation avec les anciens scripts
#    alertes configurer <ip HA> <webhook> [o|n : alerte critique de test]
#    suivi configurer <serveur MQTT>   (utilisateur et mot de passe sur l'entree standard)
#    notify <critique|info|succes|ok> <tag> <titre> <message>
#    check                          verification (comme nas-check)
#    ha-status                      publication Home Assistant (comme nas-ha-status)
#    <commandes de nas-backup>      run, run-at, run-all, stop, save, delete, restore,
#                                   ls, simulate, verifier, verifier-tout, verif-plan,
#                                   gen-cron, list, api-version
# =====================================================================
set -uo pipefail

SCRIPT_VERSION="2.0.0"
API_VERSION=5

# --------------------------- Parametres ------------------------------
GDRIVE="gdrive"                  # remote Google Drive deja configure
CRYPT="gbackup"                  # remote chiffre (cree si absent)
CRYPT_FOLDER="NAS-chiffre"       # dossier Drive des sauvegardes chiffrees
PLAIN_FOLDER="NAS"               # dossier Drive des sauvegardes non chiffrees
DEFAULT_RET=30                   # jours de corbeille par defaut
DEFAULT_SCHED="03:30"            # horaire par defaut
CAM_PASS="/root/cam-crypt-motsdepasse.txt"   # mots de passe reutilises si presents
PASSFILE="/root/nas-backup-motsdepasse.txt"
HA_LIVE=60                       # avancement publie dans Home Assistant toutes les X secondes
# ---------------------------------------------------------------------

BIN_DIR="/usr/local/bin"
SELF="$BIN_DIR/nas-debian"
CONF_DIR="/etc/nas-backup"
JOBS="$CONF_DIR/jobs.conf"
AGENT_CONF="$CONF_DIR/agent.conf"
NOTIFY_CONF="$CONF_DIR/notify.conf"
STATE_DIR="/var/lib/nas-backup"
LOG="/var/log/nas-backup.log"
CRON_FILE="/etc/cron.d/nas-backup"
STOPF="$STATE_DIR/stop"          # present = arret demande (nas-backup stop)
OLD_DIR="/root/.nas-manager/ancien"   # anciens scripts gardes par la migration
EXCLUDES=(--exclude '@eaDir/**' --exclude '\#recycle/**' --exclude '.Trash-*/**')
LEGACY_NAMES=(nas-backup nas-notify nas-check nas-ha-status)

vert()  { echo -e "\e[32m$*\e[0m"; }
jaune() { echo -e "\e[33m$*\e[0m"; }
rouge() { echo -e "\e[31m$*\e[0m"; }
gras()  { echo -e "\e[1m$*\e[0m"; }
die()   { rouge "ERREUR : $*"; exit 1; }
logl()  { echo "$(date '+%Y-%m-%d %H:%M:%S') [nas-backup] $*" >> "$LOG"; }
notify() { notify_cmd "$@" >/dev/null 2>&1; return 0; }             # alertes Home Assistant
ha_status() { ha_status_cmd >/dev/null 2>&1; return 0; }            # tableau de bord HA
rd_() { local p="$1"; shift; read -r -p "$p" "$@" || { echo; exit 0; }; }
pause() { echo; rd_ "Entree pour continuer..." _; }
cnt() { [ -s "$1" ] && grep -c '' "$1" || echo 0; }

# =========================== Machine =================================
machine() {
  if [ -d /etc/openmediavault ] || command -v omv-confdbadm >/dev/null 2>&1; then echo omv; else echo debian; fi
}
MACHINE=$(machine)

# Dossiers de donnees : disques OMV, ou systemes de fichiers montes (Debian)
data_roots() {
  local d
  if [ "$MACHINE" = omv ]; then
    for d in /srv/dev-disk-by-uuid-* /srv/dev-disk-by-label-* /srv/mergerfs/*; do [ -d "$d" ] && echo "$d"; done
    return 0
  fi
  {
    # systemes de fichiers de donnees montes (/proc/mounts : espaces codes en \040)
    python3 - <<'PYM' 2>/dev/null
import re
FS = {"ext2", "ext3", "ext4", "xfs", "btrfs", "zfs", "f2fs", "ntfs", "ntfs3", "exfat", "vfat", "fuseblk",
      "nfs", "nfs4", "cifs", "fuse.mergerfs", "fuse.sshfs"}
for l in open("/proc/mounts"):
    p = l.split()
    if len(p) < 3 or p[2] not in FS:
        continue
    t = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), p[1])
    if re.match(r"^/(boot|efi)(/|$)|^/snap/", t):
        continue
    print(t)
PYM
    for d in /srv/* /mnt/* /media/*/* /home; do [ -d "$d" ] && echo "$d"; done
  } | awk '!vu[$0]++'
}

# Sous-dossiers proposes comme sources de sauvegarde
data_dirs() {
  local r d
  while IFS= read -r r; do
    [ "$r" = / ] && continue
    for d in "$r"/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"
      case "${d##*/}" in lost+found|@eaDir|'#recycle'|.Trash-*) continue ;; esac
      echo "$d"
    done
  done < <(data_roots)
}

short() {
  if [ "$MACHINE" = omv ]; then echo "$1" | sed -E 's#^/srv/dev-disk-by-(uuid|label)-[^/]+/#…/#'; else echo "$1"; fi
}

# =========================== Reglages rclone (memoire) ===============
# /etc/nas-backup/agent.conf :
#   RAM_PROFIL = auto | econome | equilibre | performant
#   RAM_MO     = limite de memoire en Mo (vide = selon le profil)
#   TRANSFERTS, VERIFS, TAMPON = vides = selon le profil
# Limite appliquee a rclone par GOMEMLIMIT (limite douce : rclone libere sa
# memoire en priorite pour rester en dessous).
ram_total_mo() { awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 2000; }
ram_dispo_mo() { awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0; }

agent_conf_load() {
  RAM_PROFIL=auto RAM_MO="" TRANSFERTS="" VERIFS="" TAMPON=""
  # shellcheck disable=SC1090
  [ -f "$AGENT_CONF" ] && . "$AGENT_CONF"
  return 0
}

# perf_load [surcharge]  surcharge = "" (reglage de la machine), un profil, ou un nombre de Mo
#  -> PERF_PROFIL, PERF_MEM (ex. 256MiB), PERF_FLAGS (options rclone)
perf_load() {
  agent_conf_load
  local over="${1:-}" prof="$RAM_PROFIL" mo="$RAM_MO" tot t c b lo hi div
  if [[ "$over" =~ ^[0-9]+$ ]]; then mo="$over"
  elif [[ "$over" =~ ^(auto|econome|equilibre|performant)$ ]]; then prof="$over"; mo=""; fi
  tot=$(ram_total_mo)
  if [ "$prof" = auto ] || [ -z "$prof" ]; then
    if [ "$tot" -lt 3000 ]; then prof=econome; elif [ "$tot" -lt 8000 ]; then prof=equilibre; else prof=performant; fi
  fi
  case "$prof" in
    econome)    t=1; c=2;  b=0;   div=8; lo=96;  hi=256 ;;
    performant) t=8; c=16; b=32M; div=3; lo=256; hi=4096 ;;
    *)          prof=equilibre; t=4; c=8; b=16M; div=5; lo=128; hi=1024 ;;
  esac
  if [ -z "$mo" ]; then
    mo=$(( tot / div )); [ "$mo" -gt "$hi" ] && mo=$hi; [ "$mo" -lt "$lo" ] && mo=$lo
  fi
  [ "$mo" -lt 64 ] && mo=64
  [[ "${TRANSFERTS:-}" =~ ^[0-9]+$ ]] && [ -z "$over" ] && t=$TRANSFERTS
  [[ "${VERIFS:-}" =~ ^[0-9]+$ ]] && [ -z "$over" ] && c=$VERIFS
  [ -n "${TAMPON:-}" ] && [ -z "$over" ] && b=$TAMPON
  PERF_PROFIL="$prof"; PERF_MO="$mo"; PERF_MEM="${mo}MiB"
  PERF_FLAGS=(--transfers "$t" --checkers "$c" --buffer-size "$b")
}

# rcl <etiquette> <arguments rclone...>
#   rclone avec les reglages memoire ; pic de memoire releve dans RCL_MAX (Mo)
#   et memoire en cours dans $STATE_DIR/<etiquette>.rss pendant l'execution.
rcl() {
  local tag="$1"; shift
  local pid rss max=0 rc
  [ -n "${PERF_MEM:-}" ] || perf_load
  GOGC=50 GOMEMLIMIT="$PERF_MEM" rclone "$@" "${PERF_FLAGS[@]}" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && ! grep -q '^State:.*Z' "/proc/$pid/status" 2>/dev/null; do
    rss=$(awk '/^VmRSS:/{print int($2/1024)}' "/proc/$pid/status" 2>/dev/null)
    if [ -n "$rss" ]; then
      [ "$rss" -gt "$max" ] && max=$rss
      [ -n "$tag" ] && echo "$rss $max $PERF_MO" > "$STATE_DIR/$tag.rss"
    fi
    sleep 2
  done
  wait "$pid"; rc=$?
  RCL_MAX=$max
  [ -n "$tag" ] && rm -f "$STATE_DIR/$tag.rss"
  return $rc
}

# Manque de memoire : rclone tue par le systeme, ou erreur d'allocation
oom_in() { grep -qiE 'out of memory|cannot allocate memory|fatal error: runtime' "$1" 2>/dev/null; }

# =========================== Notifications (nas-notify) ==============
#   critique : alerte prioritaire (rappel toutes les REPEAT_HOURS si non resolue)
#   info     : notification discrete
#   succes   : notification discrete, ou "retabli" si une alerte etait en cours
#   ok       : silencieux, sauf "retabli" si une alerte etait en cours
notify_cmd() {
  [ -f "$NOTIFY_CONF" ] || return 0
  local HA_URL="" WEBHOOK="" REPEAT_HOURS=12
  # shellcheck disable=SC1090
  . "$NOTIFY_CONF"
  local level="${1:-info}" tag="${2:-nas}" title="${3:-NAS}" msg="${4:-}" f
  tag=$(printf '%s' "$tag" | tr -c 'A-Za-z0-9_-' '_')
  f="$STATE_DIR/alertes/$tag"
  mkdir -p "$STATE_DIR/alertes"
  _send() {  # _send <critique|info> <titre> <message>
    local json
    json=$(python3 -c 'import json,sys;print(json.dumps({"title":sys.argv[1],"message":sys.argv[2],"tag":sys.argv[3]}))' "$2" "$3" "$tag")
    curl -sk -m 15 -o /dev/null -f -X POST -H 'Content-Type: application/json' -d "$json" "$HA_URL/api/webhook/${WEBHOOK}-$1"
  }
  case "$level" in
    critique)
      if [ -f "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -lt $(( ${REPEAT_HOURS:-12} * 3600 )) ]; then return 0; fi
      _send critique "$title" "$msg" && touch "$f" ;;
    succes)
      if [ -f "$f" ]; then rm -f "$f"; _send info "✅ Rétabli : $title" "$msg"
      else _send info "$title" "$msg"; fi ;;
    ok)
      [ -f "$f" ] || return 0
      rm -f "$f"; _send info "✅ Rétabli : $title" "$msg" ;;
    info)
      _send info "$title" "$msg" ;;
    *) echo "Usage : nas-notify <critique|info|succes|ok> <tag> <titre> <message>"; return 1 ;;
  esac
}

# Configuration des alertes : adresse de Home Assistant et webhook
alertes_configurer() {  # alertes_configurer <ip HA> <webhook> [o|n]
  local ip="${1:-}" wh="${2:-}" crit="${3:-n}" url="" code u
  [ -n "$ip" ] && [ -n "$wh" ] || die "usage : nas-debian alertes configurer <ip HA> <webhook> [o|n]"
  [[ "$wh" =~ ^[A-Za-z0-9_-]+$ ]] || die "identifiant de webhook invalide."
  outils_requis curl python3 || die "outils manquants : lance d'abord « nas-debian outils installer »."
  echo "== Recherche de Home Assistant sur $ip =="
  for u in "http://$ip:8123" "http://$ip" "https://$ip:8123" "https://$ip"; do
    code=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 "$u/api/" || true)
    if [ "$code" != "000" ]; then url="$u"; break; fi
  done
  [ -n "$url" ] || die "Home Assistant injoignable sur $ip (ports 8123 et 80 testes)."
  vert "OK : Home Assistant repond sur $url"
  mkdir -p "$CONF_DIR" "$STATE_DIR/alertes"
  local rep=12 quota=90 late=50
  if [ -f "$NOTIFY_CONF" ]; then
    rep=$(grep -m1 '^REPEAT_HOURS=' "$NOTIFY_CONF" | cut -d= -f2); rep="${rep:-12}"
    quota=$(grep -m1 '^QUOTA_ALERT=' "$NOTIFY_CONF" | cut -d= -f2); quota="${quota:-90}"
    late=$(grep -m1 '^LATE_HOURS=' "$NOTIFY_CONF" | cut -d= -f2); late="${late:-50}"
  fi
  printf 'HA_URL="%s"\nWEBHOOK="%s"\nREPEAT_HOURS=%s\nQUOTA_ALERT=%s\nLATE_HOURS=%s\n' "$url" "$wh" "$rep" "$quota" "$late" > "$NOTIFY_CONF"
  chmod 600 "$NOTIFY_CONF"
  echo "7 * * * * root $BIN_DIR/nas-check >/dev/null 2>&1" > /etc/cron.d/nas-check
  chmod 644 /etc/cron.d/nas-check
  vert "OK : verification toutes les heures (nas-check)"
  if notify_cmd info test "NAS" "Les alertes de sauvegarde sont actives ✅"; then
    vert "Notification discrete envoyee : verifie ton telephone."
  else
    rouge "Echec de l'envoi vers Home Assistant ($url)."
  fi
  if [[ "$crit" =~ ^[oOyY]$ ]]; then
    notify_cmd critique test-critique "Test d'alerte" "Ceci est un test, tout va bien." && vert "Alerte critique envoyee."
    rm -f "$STATE_DIR/alertes/test-critique"
  fi
}

# =========================== Verification (nas-check) ================
check_cmd() {
  [ -f "$NOTIFY_CONF" ] || { jaune "Alertes non configurees (nas-debian alertes configurer)."; }
  local QUOTA_ALERT=90 LATE_HOURS=50
  # shellcheck disable=SC1090
  [ -f "$NOTIFY_CONF" ] && . "$NOTIFY_CONF"
  local N=notify_cmd
  mkdir -p "$STATE_DIR"

  # 1. Synchro temps reel des cameras (installation precedente)
  if systemctl is-enabled --quiet cam-sync 2>/dev/null; then
    if systemctl is-active --quiet cam-sync; then
      $N ok cam-service "Caméras" "La synchro temps réel des caméras fonctionne de nouveau."
    else
      $N critique cam-service "Caméras : synchro arrêtée" "Le service cam-sync est arrêté sur le NAS. Sur le NAS : systemctl restart cam-sync"
    fi
  fi

  # 2. Connexion Google Drive et espace
  local GD=false pct="" used_go="" total_go="" json
  if command -v rclone >/dev/null && timeout 120 rclone lsd "$GDRIVE:" >/dev/null 2>&1; then
    GD=true
    $N ok gdrive "Google Drive" "La connexion à Google Drive fonctionne de nouveau."
    if json=$(timeout 120 rclone about "$GDRIVE:" --json 2>/dev/null); then
      read -r pct used_go total_go < <(python3 -c '
import json,sys
try:
    d=json.load(sys.stdin); t=d.get("total") or 0; u=d.get("used",0)
    print(int(u*100/t) if t else 0, round(u/1e9,1), round(t/1e9,1))
except Exception:
    print(0, 0, 0)' <<< "$json" 2>/dev/null)
      if [ "${pct:-0}" -ge "${QUOTA_ALERT:-90}" ]; then
        $N critique quota "Google Drive presque plein" "Espace utilisé : ${pct} %. Les prochaines sauvegardes risquent d'échouer."
      else
        $N ok quota "Google Drive" "Espace utilisé : ${pct} %."
      fi
    fi
  elif command -v rclone >/dev/null && rclone listremotes 2>/dev/null | grep -qx "$GDRIVE:"; then
    $N critique gdrive "Google Drive inaccessible" "rclone n'arrive plus à se connecter à Google Drive. Reconnecte-le depuis NAS Manager (page Installation)."
  fi

  # 3. Sauvegardes planifiees en retard
  if [ -f "$JOBS" ]; then
    local n s sub m e sch r age lim
    while IFS='|' read -r n s sub m e sch r _; do
      [[ -z "$n" || "$n" == \#* || "$sch" == manuel ]] && continue
      [ -f "$STATE_DIR/$n.lastok" ] || continue
      age=$(( ( $(date +%s) - $(cat "$STATE_DIR/$n.lastok") ) / 3600 ))
      lim=$(cat "$STATE_DIR/$n.maxage" 2>/dev/null)
      if [ "$age" -ge "${lim:-${LATE_HOURS:-50}}" ]; then
        $N critique "retard-$n" "Sauvegarde « $n » en retard" "Aucune sauvegarde réussie depuis ${age} h (horaire : $sch)."
      else
        $N ok "retard-$n" "Sauvegarde « $n »" "La sauvegarde est de nouveau à jour."
      fi
    done < "$JOBS"
  fi

  # 4. Entretien : nouvelle version de rclone (une fois par jour)
  outils_rclone_derniere >/dev/null 2>&1

  # 5. Etat pour le tableau de bord Home Assistant
  python3 -c '
import json,sys
from datetime import datetime
gd,pct,u,t,out=sys.argv[1:6]
num=lambda x:(float(x) if x else None)
json.dump({"gdrive":gd=="true","quota_pct":int(num(pct)) if pct else None,"used_go":num(u),"total_go":num(t),
           "checked":datetime.now().astimezone().isoformat(timespec="seconds")},open(out,"w"))
' "$GD" "$pct" "$used_go" "$total_go" "$STATE_DIR/health.json"
  ha_status
  return 0
}

# =========================== Home Assistant (nas-ha-status) ==========
ha_slug() {
  if [ "$MACHINE" = omv ]; then echo omv; else hostname -s 2>/dev/null | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '_' | head -c 30; fi
}

ha_status_cmd() {
  [ -f /root/.config/mosquitto_pub ] || return 0
  command -v mosquitto_pub >/dev/null || return 0
  NAS_HA_SLUG="$(ha_slug)" NAS_HA_NOM="$( [ "$MACHINE" = omv ] && echo "NAS OMV Sauvegardes" || echo "NAS $(hostname -s) Sauvegardes")" \
  NAS_HA_MODELE="$( [ "$MACHINE" = omv ] && echo OpenMediaVault || echo Debian)" python3 - <<'PYEOF'
# Publie l'etat et la synthese des transferts vers Home Assistant (MQTT discovery).
import json, os, re, subprocess, time
from datetime import datetime

STATE_DIR = "/var/lib/nas-backup"
JOBS = "/etc/nas-backup/jobs.conf"
HEALTH = f"{STATE_DIR}/health.json"
PUBLISHED = f"{STATE_DIR}/mqtt-jobs.json"
CAM_TR = f"{STATE_DIR}/cam-transferts.log"
CAM_SCRIPT = "/usr/local/bin/cam-sync.sh"
SLUG = os.environ.get("NAS_HA_SLUG", "omv") or "omv"
DISC = "homeassistant"
TOPIC = f"nas-{SLUG}/sauvegardes/etat"
EXPIRE = 1200  # entites indisponibles si le NAS ne publie plus pendant 20 min
OBJ = f"nas_{SLUG}"
EID = "nas" if SLUG == "omv" else f"nas_{SLUG}"

DEVICE = {
    "identifiers": [f"nas_{SLUG}_sauvegardes"],
    "name": os.environ.get("NAS_HA_NOM", "NAS OMV Sauvegardes"),
    "manufacturer": os.environ.get("NAS_HA_MODELE", "OpenMediaVault"),
    "model": "rclone vers Google Drive",
}
NOW = time.time()
MIDNIGHT = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()


def pub(topic, payload, retain=True):
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
    try:
        pid, t0 = read(f"{STATE_DIR}/{name}.running").split()[:2]
        os.kill(int(pid), 0)
        return int(t0)
    except (OSError, ValueError):
        return None


STAT_RE = re.compile(r"^Transferred:\s+([\d.]+\s*\S+)\s*/\s*([\d.]+\s*\S+),\s*(\d+)%,\s*([\d.]+\s*\S+/s),\s*ETA\s*(\S+)")


def live(name, t0):
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
        status = read(f"{STATE_DIR}/{name}.status")
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
            "source": re.sub(r"^/srv/dev-disk-by-(uuid|label)-[^/]+/", "", src),
            "destination": ("NAS-chiffre/" if enc == "oui" else "NAS/") + sub,
            "mode": "miroir" if mode == "sync" else "copie",
            "chiffre": enc == "oui",
            "horaire": sched,
            "corbeille_jours": int(ret) if ret.isdigit() else 0,
            "dernier_transfert": iso(b.get("fin")),
            "fichiers_envoyes": b.get("fichiers_envoyes"),
            "fichiers_nouveaux": b.get("nouveaux"),
            "fichiers_remplaces": b.get("remplaces"),
            "fichiers_retires": b.get("retires"),
            "erreurs": b.get("erreurs"),
            "volume": hs(b.get("volume_octets")) if b else None,
            "volume_go": go(b.get("volume_octets")) if b else None,
            "duree_min": b.get("duree_min"),
            "ram_max_mo": b.get("ram_max_mo"),
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
    "en_cours": ", ".join(n for n, _ in en_cours) if en_cours else "Aucune",
    "en_cours_pct": ec.get("progression", 0),
    "en_cours_detail": ec,
    "sauv_volume_24h_go": go(vol24),
    "sauv_fichiers_24h": fic24,
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
    "gdrive": "ON" if health.get("gdrive") else "OFF",
    "gdrive_pct": health.get("quota_pct"),
    "gdrive_utilise_go": health.get("used_go"),
    "gdrive_total_go": health.get("total_go"),
    "derniere_verification": health.get("checked"),
    "publie": iso(NOW),
}


def entity(domain, key, name, extra):
    cfg = {
        "name": name,
        "unique_id": f"{OBJ}_{key}",
        "default_entity_id": f"{domain}.{EID}_{key}",
        "state_topic": TOPIC,
        "expire_after": EXPIRE,
        "device": DEVICE,
    }
    cfg.update(extra)
    pub(f"{DISC}/{domain}/{OBJ}/{key}/config", json.dumps(cfg))


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

try:
    old = set(json.load(open(PUBLISHED)))
except (OSError, ValueError):
    old = set()
for key in old - set(jobs):
    pub(f"{DISC}/sensor/{OBJ}/sauvegarde_{key}/config", "")
with open(PUBLISHED, "w") as f:
    json.dump(sorted(jobs), f)

pub(TOPIC, json.dumps(state, ensure_ascii=False))
PYEOF
}

suivi_configurer() {  # suivi_configurer <serveur MQTT>   (utilisateur / mot de passe sur stdin)
  local host="${1:-}" port=1883 mu="" mp=""
  [ -n "$host" ] || die "usage : nas-debian suivi configurer <serveur MQTT>"
  outils_requis mosquitto_pub python3 || die "outils manquants : lance d'abord « nas-debian outils installer suivi »."
  if [ ! -t 0 ]; then read -r mu || true; read -r mp || true; fi
  echo "== Connexion au serveur MQTT de Home Assistant ($host) =="
  if [ -z "$mu" ] && [ -f /root/.config/mosquitto_pub ] && mosquitto_pub -t "nas-$(ha_slug)/test" -m ok 2>/dev/null; then
    vert "OK : connexion MQTT deja configuree (conservee)"
  else
    [ -n "$mu" ] || die "utilisateur MQTT manquant."
    mkdir -p /root/.config
    printf -- "-h %s\n-p %s\n-u %s\n-P %s\n" "$host" "$port" "$mu" "$mp" > /root/.config/mosquitto_pub.new
    chmod 600 /root/.config/mosquitto_pub.new
    mv -f /root/.config/mosquitto_pub.new /root/.config/mosquitto_pub
    if mosquitto_pub -t "nas-$(ha_slug)/test" -m ok; then
      vert "OK : connexion MQTT"
    else
      rm -f /root/.config/mosquitto_pub
      die "connexion MQTT refusee (utilisateur, mot de passe ou adresse)."
    fi
  fi
  echo "*/5 * * * * root $BIN_DIR/nas-ha-status >/dev/null 2>&1" > /etc/cron.d/nas-ha-status
  chmod 644 /etc/cron.d/nas-ha-status
  vert "OK : publication toutes les 5 minutes (toutes les minutes pendant une sauvegarde)"
  if ha_status_cmd; then vert "OK : les entites sont visibles dans Home Assistant."; else rouge "Echec de la publication."; fi
}

# =========================== Outils ==================================
outils_requis() { local t; for t in "$@"; do command -v "$t" >/dev/null || return 1; done; return 0; }

rclone_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; armv7l|armv7*) echo arm-v7 ;;
    armv6l) echo arm-v6 ;; i?86) echo 386 ;; *) return 1 ;;
  esac
}

rclone_source() {
  local p; p=$(command -v rclone 2>/dev/null) || { echo absent; return; }
  if dpkg -S "$(readlink -f "$p")" >/dev/null 2>&1; then echo paquet; else echo officiel; fi
}

# Installe la version officielle de rclone dans /usr/local/bin (plus recente que celle des paquets)
rclone_officiel() {
  local arch tmp
  arch=$(rclone_arch) || die "architecture $(uname -m) non prise en charge par rclone."
  outils_requis curl unzip || apt_install curl unzip
  tmp=$(mktemp -d)
  echo "Telechargement de rclone ($arch)..."
  if ! curl -fsSL -o "$tmp/rclone.zip" "https://downloads.rclone.org/rclone-current-linux-$arch.zip"; then
    rm -rf "$tmp"; die "telechargement de rclone impossible (downloads.rclone.org)."
  fi
  unzip -q -o "$tmp/rclone.zip" -d "$tmp" || { rm -rf "$tmp"; die "archive rclone illisible."; }
  install -m 755 "$tmp"/rclone-*/rclone "$BIN_DIR/rclone.new" && mv -f "$BIN_DIR/rclone.new" "$BIN_DIR/rclone"
  rm -rf "$tmp"
  hash -r
  vert "OK : $("$BIN_DIR/rclone" version 2>/dev/null | head -n 1)"
}

# Derniere version de rclone (verifiee au plus une fois par jour) -> stdout
outils_rclone_derniere() {
  local f="$STATE_DIR/rclone-derniere" v
  mkdir -p "$STATE_DIR"
  if [ -f "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -lt 86400 ]; then cat "$f"; return 0; fi
  command -v curl >/dev/null || return 1
  v=$(curl -fsSL -m 15 https://downloads.rclone.org/version.txt 2>/dev/null | awk '{print $2}' | tr -d 'v\r')
  [ -n "$v" ] || return 1
  echo "$v" > "$f"; echo "$v"
}

apt_install() {
  command -v apt-get >/dev/null || die "apt-get introuvable : installe a la main : $*"
  echo "Installation : $*"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null || die "installation impossible : $*"
}

# Etat des outils (JSON)
outils_etat() {
  local rc=""; command -v rclone >/dev/null && rc=$(rclone version 2>/dev/null | head -n 1 | awk '{print $2}' | tr -d 'v')
  local last; last=$(cat "$STATE_DIR/rclone-derniere" 2>/dev/null)
  local watches; watches=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
  local b; b() { command -v "$1" >/dev/null && echo true || echo false; }
  printf '{"machine":"%s","arch":"%s","ram_total_mo":%s,"ram_dispo_mo":%s,"python3":%s,"rclone":"%s","rclone_source":"%s","rclone_derniere":"%s","curl":%s,"unzip":%s,"inotifywait":%s,"mosquitto_pub":%s,"openssl":%s,"flock":%s,"logrotate":%s,"inotify_max":%s}\n' \
    "$MACHINE" "$(uname -m)" "$(ram_total_mo)" "$(ram_dispo_mo)" "$(b python3)" "$rc" "$(rclone_source)" "$last" \
    "$(b curl)" "$(b unzip)" "$(b inotifywait)" "$(b mosquitto_pub)" "$(b openssl)" "$(b flock)" "$( [ -x /usr/sbin/logrotate ] && echo true || echo false)" "$watches"
}

# Installe tout ce qui manque. Options : suivi (client MQTT pour Home Assistant)
outils_installer() {
  local -a pk=()
  outils_requis python3 || pk+=(python3)
  outils_requis curl    || pk+=(curl)
  outils_requis unzip   || pk+=(unzip)
  outils_requis openssl || pk+=(openssl)
  outils_requis flock   || pk+=(util-linux)
  outils_requis inotifywait || pk+=(inotify-tools)
  [ -x /usr/sbin/logrotate ] || pk+=(logrotate)
  [ -d /etc/ssl/certs ] || pk+=(ca-certificates)
  if [[ " $* " == *" suivi "* ]] || [ -f /root/.config/mosquitto_pub ]; then outils_requis mosquitto_pub || pk+=(mosquitto-clients); fi
  if [ ${#pk[@]} -gt 0 ]; then apt_install "${pk[@]}"; vert "OK : ${pk[*]}"; else vert "OK : paquets deja presents"; fi
  if ! command -v rclone >/dev/null; then
    rclone_officiel
  elif [ "$(rclone_source)" = paquet ]; then
    jaune "rclone vient des paquets ($(rclone version | head -n 1)) : installation de la version officielle, plus recente."
    rclone_officiel
  else
    vert "OK : $(rclone version | head -n 1)"
  fi
  # surveillance de nombreux fichiers (sauvegardes temps reel)
  if [ "$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)" -lt 524288 ]; then
    echo "fs.inotify.max_user_watches=524288" > /etc/sysctl.d/99-inotify.conf
    sysctl -q -w fs.inotify.max_user_watches=524288 2>/dev/null || sysctl --system >/dev/null 2>&1
    vert "OK : limite de surveillance de fichiers relevee (524288)"
  fi
  install_base >/dev/null
  vert "Tous les outils necessaires sont installes."
}

outils_rclone_maj() {
  command -v rclone >/dev/null || { rclone_officiel; return; }
  if [ "$(rclone_source)" = paquet ] || [ "$(readlink -f "$(command -v rclone)")" != "$BIN_DIR/rclone" ]; then
    rclone_officiel
  else
    rclone selfupdate --stable 2>&1 | tail -n 3 || rclone_officiel
  fi
  rm -f "$STATE_DIR/rclone-derniere"
}

# =========================== Installation / migration ================
install_base() {
  mkdir -p "$CONF_DIR" "$STATE_DIR/alertes"
  [ -f "$JOBS" ] || echo "# NOM|SOURCE|DOSSIER_DRIVE|MODE(sync/copy)|CHIFFRE(oui/non)|HORAIRE(HH:MM/manuel)|CORBEILLE_JOURS|DEBIT|MEMOIRE" > "$JOBS"
  touch "$LOG"
  [ -f /etc/logrotate.d/nas-backup ] || printf "%s {\n  weekly\n  rotate 8\n  compress\n  missingok\n  notifempty\n  copytruncate\n}\n" "$LOG" > /etc/logrotate.d/nas-backup
  # anciens noms : liens vers ce script (sauf anciens scripts encore en place : voir « migrer »)
  local n
  for n in "${LEGACY_NAMES[@]}"; do
    if [ ! -e "$BIN_DIR/$n" ] || [ -L "$BIN_DIR/$n" ]; then ln -sfn nas-debian "$BIN_DIR/$n"; fi
  done
  echo "Installation de base prete ($MACHINE)."
}

is_legacy() { [ -f "$BIN_DIR/$1" ] && [ ! -L "$BIN_DIR/$1" ]; }

migrer() {  # migrer <simulation|appliquer>
  local mode="${1:-simulation}" n todo=0 dest
  [ -x "$SELF" ] || die "installe d'abord nas-debian dans $SELF."
  gras "== Reprise de l'installation existante ($MACHINE) =="
  for n in "${LEGACY_NAMES[@]}"; do
    is_legacy "$n" || continue
    todo=1
    echo "- $BIN_DIR/$n : ancien script remplace par un lien vers nas-debian (ancien garde dans $OLD_DIR)"
  done
  if grep -qs "$BIN_DIR/nas-backup run-at" "$CRON_FILE"; then
    todo=1; echo "- planification des sauvegardes : regeneree pour nas-debian"
  fi
  [ -f "$JOBS" ] && echo "- sauvegardes programmees conservees : $(grep -cvE '^#|^$' "$JOBS") (reglages et historique inchanges)"
  [ -f "$NOTIFY_CONF" ] && echo "- alertes Home Assistant conservees ($(grep -m1 '^HA_URL=' "$NOTIFY_CONF" | cut -d'"' -f2))"
  [ -f /root/.config/mosquitto_pub ] && echo "- connexion MQTT conservee"
  [ -f /usr/local/bin/cam-sync.sh ] && echo "- synchro des cameras : laissee en place (reprise par les sauvegardes temps reel dans une prochaine version)"
  if [ $todo = 0 ]; then vert "Rien a migrer : l'installation utilise deja nas-debian."; return 0; fi
  [ "$mode" = appliquer ] || { echo; jaune "Simulation : rien n'a ete modifie."; return 0; }

  echo
  dest="$OLD_DIR/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$dest"
  for n in "${LEGACY_NAMES[@]}"; do
    is_legacy "$n" || continue
    cp -p "$BIN_DIR/$n" "$dest/$n"
    # remplacement atomique : un script deja lance (sauvegarde en cours) garde l'ancienne version
    ln -sfn nas-debian "$BIN_DIR/$n.lien" && mv -f "$BIN_DIR/$n.lien" "$BIN_DIR/$n"
    vert "OK : $n -> nas-debian"
  done
  install_base >/dev/null
  gen_cron
  logl "migration vers nas-debian $SCRIPT_VERSION (anciens scripts dans $dest)"
  vert "Migration terminee. Anciens scripts gardes dans $dest"
}

# =========================== Sauvegardes (nas-backup) ================
need_rclone() {
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  command -v rclone >/dev/null || die "rclone n'est pas installe (nas-debian outils installer)."
  rclone listremotes 2>/dev/null | grep -x "${GDRIVE}:" >/dev/null || die "remote '${GDRIVE}' introuvable : connecte Google Drive depuis NAS Manager (page Installation)."
}

nb_init() {
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  mkdir -p "$CONF_DIR" "$STATE_DIR"
  [ -f "$JOBS" ] || echo "# NOM|SOURCE|DOSSIER_DRIVE|MODE(sync/copy)|CHIFFRE(oui/non)|HORAIRE(HH:MM/manuel)|CORBEILLE_JOURS|DEBIT|MEMOIRE" > "$JOBS"
  touch "$LOG"
  if [ ! -f /etc/logrotate.d/nas-backup ]; then
    printf "%s {\n  weekly\n  rotate 8\n  compress\n  missingok\n  notifempty\n  copytruncate\n}\n" "$LOG" > /etc/logrotate.d/nas-backup
  fi
}

self_install() {
  local me; me=$(readlink -f "$0")
  if [ "$me" != "$SELF" ]; then
    install -m 755 "$me" "$SELF.new" && mv -f "$SELF.new" "$SELF"
    vert "Script installe dans $SELF : relance-le simplement avec la commande 'nas-debian'."
    install_base >/dev/null
    echo
  fi
}

ensure_crypt() {
  rclone listremotes 2>/dev/null | grep -x "${CRYPT}:" >/dev/null && return 0
  local P1 P2
  if [ -f "$CAM_PASS" ]; then
    P1=$(awk -F': ' '/^Mot de passe/{print $2}' "$CAM_PASS")
    P2=$(awk -F': ' '/^Sel/{print $2}' "$CAM_PASS")
  fi
  if [ -z "${P1:-}" ] || [ -z "${P2:-}" ]; then
    P1=$(openssl rand -base64 24); P2=$(openssl rand -base64 24)
  fi
  rclone config create "$CRYPT" crypt remote="${GDRIVE}:${CRYPT_FOLDER}" \
    filename_encryption=standard directory_name_encryption=true \
    password="$P1" password2="$P2" --obscure >/dev/null || die "creation du remote chiffre impossible."
  {
    echo "Remote rclone : ${CRYPT}  ->  ${GDRIVE}:${CRYPT_FOLDER}"
    echo "Mot de passe        : $P1"
    echo "Sel (password2)     : $P2"
    echo "Cree le             : $(date)"
  } > "$PASSFILE"
  chmod 600 "$PASSFILE"
  echo
  rouge "=== Remote chiffre '${CRYPT}' cree. NOTE CES MOTS DE PASSE EN LIEU SUR (hors du NAS) ==="
  cat "$PASSFILE"
  [ -f "$CAM_PASS" ] && jaune "(Ce sont les memes que ceux des cameras.)"
  echo
}

job_names() { grep -v '^#' "$JOBS" | grep -v '^$' | cut -d'|' -f1; }
job_exists() { grep -q "^$1|" "$JOBS"; }

job_get() {
  local line; line=$(grep -m1 "^$1|" "$JOBS") || return 1
  IFS='|' read -r J_NAME J_SRC J_SUB J_MODE J_ENC J_SCHED J_RET J_BW J_PERF <<< "$line"
  J_BW="${J_BW:-}"; J_PERF="${J_PERF:-}"
}

job_save() {
  local tmp; tmp=$(mktemp)
  grep -v "^$J_NAME|" "$JOBS" > "$tmp"
  echo "$J_NAME|$J_SRC|$J_SUB|$J_MODE|$J_ENC|$J_SCHED|$J_RET|${J_BW:-}|${J_PERF:-}" >> "$tmp"
  cat "$tmp" > "$JOBS"; rm -f "$tmp"
}

job_del() {
  local tmp; tmp=$(mktemp)
  grep -v "^$1|" "$JOBS" > "$tmp"; cat "$tmp" > "$JOBS"; rm -f "$tmp"
  rm -f "$STATE_DIR/$1.status" "$STATE_DIR/$1.lastok" "$STATE_DIR/alertes/job-$1" "$STATE_DIR/alertes/retard-$1" \
        "$STATE_DIR/$1.bilan.json" "$STATE_DIR/$1.run.log" "$STATE_DIR/$1.running" "$STATE_DIR/$1.maxage"
}

dest_of()  { [ "$1" = oui ] && echo "${CRYPT}:$2" || echo "${GDRIVE}:${PLAIN_FOLDER}/$2"; }
trash_of() { [ "$1" = oui ] && echo "${CRYPT}:_corbeille/$2" || echo "${GDRIVE}:${PLAIN_FOLDER}/_corbeille/$2"; }

valid_sched() {
  [ "$1" = manuel ] && return 0
  [ -n "$1" ] || return 1
  local IFS=';' sl
  for sl in $1; do [[ "$sl" =~ ^([01][0-9]|2[0-3]):[0-5][0-9](/[1-7]+)?$ ]] || return 1; done
  return 0
}

valid_perf() { [ -z "$1" ] || [[ "$1" =~ ^(auto|econome|equilibre|performant)$ ]] || { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 64 ]; }; }

slot_matches() {
  [ "$1" = manuel ] && return 1
  local IFS=';' sl
  for sl in $1; do
    [ "${sl%%/*}" = "$2" ] || continue
    [[ "$sl" != */* ]] && return 0
    [[ "${sl#*/}" == *"$3"* ]] && return 0
  done
  return 1
}

max_age() {
  python3 - "$1" <<'PYAGE'
import sys
s = sys.argv[1]
if s == "manuel":
    print(0); sys.exit()
days = set()
for sl in s.split(";"):
    days |= {int(c) for c in sl.split("/")[1]} if "/" in sl else set(range(1, 8))
d = sorted(days)
gaps = [((d[(i + 1) % len(d)] - d[i]) % 7) or 7 for i in range(len(d))]
print(max(gaps) * 24 + 26)
PYAGE
}

gen_cron() {
  mkdir -p "$STATE_DIR"
  {
    echo "# Genere automatiquement par nas-debian - ne pas modifier a la main"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    local n s sub m e sch r h mi sl t
    local -a slots
    local -A seen=()
    while IFS='|' read -r n s sub m e sch r _ || [ -n "$n" ]; do
      [[ -z "$n" || "$n" == \#* ]] && continue
      if [ "$sch" = manuel ]; then rm -f "$STATE_DIR/$n.maxage"; continue; fi
      max_age "$sch" > "$STATE_DIR/$n.maxage" 2>/dev/null
      IFS=';' read -ra slots <<< "$sch"
      for sl in "${slots[@]}"; do
        t=${sl%%/*}
        [ -n "${seen[$t]:-}" ] && continue
        seen[$t]=1
        h=${t%%:*}; mi=${t##*:}
        echo "$((10#$mi)) $((10#$h)) * * * root $SELF run-at $t >/dev/null 2>&1"
      done
    done < "$JOBS"
    if [ -f "$CONF_DIR/verification" ]; then
      local vd vt
      read -r vd vt < "$CONF_DIR/verification"
      [[ "$vd" =~ ^[1-7]+$ && "$vt" =~ ^[0-9]{2}:[0-9]{2}$ ]] && \
        echo "$((10#${vt##*:})) $((10#${vt%%:*})) * * $(echo "$vd" | sed 's/./&,/g; s/,$//; s/7/0/') root $SELF verifier-tout >/dev/null 2>&1"
    fi
  } > "$CRON_FILE.new"
  chmod 644 "$CRON_FILE.new"; mv -f "$CRON_FILE.new" "$CRON_FILE"
  ha_status
}

ask() {
  local q="$1" d="${2:-}"
  if [ -n "$d" ]; then rd_ "$q [$d] : " ANS; ANS="${ANS:-$d}"
  else rd_ "$q : " ANS; fi
}

ask_yn() {
  local d="${2:-n}" a
  rd_ "$1 [$( [ "$d" = o ] && echo O/n || echo o/N )] : " a
  a="${a:-$d}"; [[ "$a" =~ ^[oOyY] ]]
}

pick_source() {
  local def="${1:-}" i=1 d choice
  local -a dirs=()
  mapfile -t dirs < <(data_dirs)
  echo "Dossiers disponibles :"
  for d in "${dirs[@]}"; do printf "  %2d) %s\n" "$i" "$(short "$d")"; i=$((i+1)); done
  echo "   c) Saisir un chemin complet"
  while true; do
    if [ -n "$def" ]; then rd_ "Choix [actuel : $(short "$def")] : " choice
    else rd_ "Choix : " choice; fi
    if [ -z "$choice" ] && [ -n "$def" ]; then ANS="$def"; return; fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#dirs[@]}" ]; then
      ANS="${dirs[$((choice-1))]}"; return
    fi
    if [[ "$choice" =~ ^[cC]$ ]]; then
      rd_ "Chemin : " ANS; ANS="${ANS%/}"
      [ -d "$ANS" ] && return
      rouge "Dossier introuvable."
      continue
    fi
    rouge "Choix invalide."
  done
}

form() {
  local def
  pick_source "${J_SRC:-}"; J_SRC="$ANS"
  while true; do
    ask "Dossier sur le Drive" "${J_SUB:-$(basename "$J_SRC")}"
    ANS="${ANS#/}"; ANS="${ANS%/}"
    if [[ -z "$ANS" || "$ANS" == *"|"* || "$ANS" == _corbeille* ]]; then rouge "Nom invalide."; continue; fi
    J_SUB="$ANS"; break
  done
  echo "Mode :"
  echo "  1) Miroir : le Drive devient identique au NAS (suppressions repercutees)"
  echo "  2) Copie  : ajoute et met a jour, ne supprime jamais rien sur le Drive"
  def=1; [ "${J_MODE:-sync}" = copy ] && def=2
  while true; do
    ask "Choix" "$def"
    case "$ANS" in 1) J_MODE=sync; break ;; 2) J_MODE=copy; break ;; *) rouge "Choix invalide." ;; esac
  done
  if ask_yn "Chiffrer (illisible sur le Drive sans les mots de passe) ?" "$( [ "${J_ENC:-oui}" = oui ] && echo o || echo n )"
  then J_ENC=oui; else J_ENC=non; fi
  if [ "$J_MODE" = sync ]; then
    while true; do
      ask "Jours de corbeille pour les fichiers supprimes/modifies (0 = aucune)" "${J_RET:-$DEFAULT_RET}"
      [[ "$ANS" =~ ^[0-9]+$ ]] && { J_RET="$ANS"; break; }
      rouge "Nombre invalide."
    done
  else
    J_RET=0
  fi
  while true; do
    ask "Horaire HH:MM (tous les jours), HH:MM/JOURS (1=lundi, ex. 03:30/135), plusieurs separes par ; ou 'manuel'" "${J_SCHED:-$DEFAULT_SCHED}"
    if valid_sched "$ANS"; then J_SCHED="$ANS"; break; fi
    rouge "Format invalide (ex : 03:30, 03:30/67, 03:30;15:00 ou manuel)."
  done
}

check_overlap() {
  local n s sub m e sch r
  while IFS='|' read -r n s sub m e sch r _; do
    [[ -z "$n" || "$n" == \#* || "$n" == "$J_NAME" ]] && continue
    if [ "$e" = "$J_ENC" ] && { [[ "$sub" == "$J_SUB" ]] || [[ "$sub" == "$J_SUB/"* ]] || [[ "$J_SUB" == "$sub/"* ]]; }; then
      jaune "Attention : la sauvegarde '$n' utilise deja le dossier Drive '$sub'."
      ask_yn "Continuer quand meme ?" n || return 1
    fi
  done < "$JOBS"
  return 0
}

list_jobs() {
  if [ -z "$(job_names)" ]; then jaune "Aucune sauvegarde configuree."; return; fi
  printf "\e[1m%-14s %-24s %-24s %-7s %-6s %-8s %s\e[0m\n" "NOM" "SOURCE" "DRIVE" "MODE" "CHIFFRE" "HORAIRE" "DERNIERE EXECUTION"
  local n s sub m e sch r st mode
  while IFS='|' read -r n s sub m e sch r _ || [ -n "$n" ]; do
    [[ -z "$n" || "$n" == \#* ]] && continue
    st="jamais"; [ -f "$STATE_DIR/$n.status" ] && st=$(cat "$STATE_DIR/$n.status")
    mode="copie"; [ "$m" = sync ] && mode="miroir"
    printf "%-14s %-24s %-24s %-7s %-7s %-8s %s\n" "$n" "$(short "$s")" "$( [ "$e" = oui ] && echo "$CRYPT_FOLDER" || echo "$PLAIN_FOLDER")/$sub" "$mode" "$e" "$sch" "$st"
  done < "$JOBS"
}

choose_job() {
  local -a names; mapfile -t names < <(job_names)
  [ "${#names[@]}" -gt 0 ] || { jaune "Aucune sauvegarde configuree."; return 1; }
  local i=1 n c
  for n in "${names[@]}"; do printf "  %2d) %s\n" "$i" "$n"; i=$((i+1)); done
  rd_ "${1:-Choix} (Entree = annuler) : " c
  [ -z "$c" ] && return 1
  if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "${#names[@]}" ]; then ANS="${names[$((c-1))]}"; return 0; fi
  job_exists "$c" && { ANS="$c"; return 0; }
  rouge "Choix invalide."; return 1
}

add_job() {
  gras "== Nouvelle sauvegarde =="
  J_NAME="" J_SRC="" J_SUB="" J_MODE="" J_ENC="" J_SCHED="" J_RET="" J_BW="" J_PERF=""
  while true; do
    ask "Nom (lettres, chiffres, - et _)"
    if [[ ! "$ANS" =~ ^[A-Za-z0-9_-]+$ ]]; then rouge "Nom invalide."; continue; fi
    job_exists "$ANS" && { rouge "Ce nom existe deja."; continue; }
    J_NAME="$ANS"; break
  done
  form
  check_overlap || { jaune "Annule."; return; }
  [ "$J_ENC" = oui ] && ensure_crypt
  job_save; gen_cron
  vert "Sauvegarde '$J_NAME' ajoutee -> $(dest_of "$J_ENC" "$J_SUB")"
  ask_yn "La lancer maintenant ?" o && run_job_locked "$J_NAME"
}

edit_job() {
  gras "== Modifier une sauvegarde =="
  choose_job "Laquelle" || return
  job_get "$ANS"
  local old_dest; old_dest=$(dest_of "$J_ENC" "$J_SUB")
  local old_trash; old_trash=$(trash_of "$J_ENC" "$J_NAME")
  echo "(Entree = garder la valeur actuelle)"
  form
  check_overlap || { jaune "Annule."; return; }
  [ "$J_ENC" = oui ] && ensure_crypt
  job_save; gen_cron
  vert "Sauvegarde '$J_NAME' modifiee."
  local new_dest; new_dest=$(dest_of "$J_ENC" "$J_SUB")
  if [ "$new_dest" != "$old_dest" ]; then
    jaune "La destination a change : $old_dest -> $new_dest"
    jaune "Les fichiers deja envoyes sont restes a l'ancien emplacement."
    if ask_yn "Supprimer l'ancien emplacement sur le Drive ?" n; then
      rclone purge "$old_dest" -q 2>/dev/null; rclone purge "$old_trash" -q 2>/dev/null
      vert "Ancien emplacement supprime."
    fi
    ask_yn "Lancer la sauvegarde vers la nouvelle destination maintenant ?" o && run_job_locked "$J_NAME"
  fi
}

delete_job() {
  gras "== Supprimer une sauvegarde =="
  choose_job "Laquelle" || return
  job_get "$ANS"
  ask_yn "Supprimer la sauvegarde '$J_NAME' ?" n || { jaune "Annule."; return; }
  local dest trash; dest=$(dest_of "$J_ENC" "$J_SUB"); trash=$(trash_of "$J_ENC" "$J_NAME")
  job_del "$J_NAME"; gen_cron
  vert "Sauvegarde '$J_NAME' supprimee (plus de planification)."
  echo
  jaune "Les fichiers sur le Drive sont conserves : $dest"
  if ask_yn "Effacer aussi DEFINITIVEMENT ces fichiers du Drive ?" n; then
    rd_ "Tape le nom '$J_NAME' pour confirmer : " c
    if [ "$c" = "$J_NAME" ]; then
      rclone purge "$dest" -q 2>/dev/null; rclone purge "$trash" -q 2>/dev/null
      logl "$J_NAME : donnees supprimees du Drive"
      vert "Fichiers effaces du Drive."
    else
      jaune "Confirmation incorrecte, fichiers conserves."
    fi
  fi
}

# Bilan d'un transfert d'apres son journal rclone -> $STATE_DIR/<nom>.bilan.json
# Affiche un resume d'une ligne ("12 fichiers envoyes (1.3 Go)", ou "aucun changement")
bilan() {  # bilan <journal> <debut> <code> [ram max Mo]
  python3 - "$1" "$J_SRC" "$STATE_DIR/$J_NAME.bilan.json" "$2" "$3" "${J_RET:-0}" "${4:-0}" <<'PY' 2>/dev/null
import json, os, re, sys, time
log, src, out = sys.argv[1:4]
t0, rc, ret, ram = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6] or 0), int(sys.argv[7] or 0)
act = re.compile(r" INFO\s+: (.+): (Copied \((new|replaced existing)\)|Deleted|Moved \(server-side\))")
b = {"nouveaux": 0, "remplaces": 0, "retires": 0, "erreurs": 0, "octets": 0}
try:
    with open(log, errors="ignore") as f:
        for line in f:
            if " ERROR : " in line and "Attempt " not in line:
                b["erreurs"] += 1
                continue
            m = act.search(line)
            if not m:
                continue
            if m.group(2).startswith("Copied"):
                b["nouveaux" if m.group(3) == "new" else "remplaces"] += 1
                try:
                    b["octets"] += os.path.getsize(os.path.join(src, m.group(1)))
                except OSError:
                    pass
            else:
                b["retires"] += 1
except OSError:
    pass
fin = int(time.time())
env = b["nouveaux"] + b["remplaces"]
d = {"debut": t0, "fin": fin, "duree_min": round((fin - t0) / 60, 1), "code": rc,
     "fichiers_envoyes": env, "nouveaux": b["nouveaux"], "remplaces": b["remplaces"],
     "retires": b["retires"], "erreurs": b["erreurs"], "volume_octets": b["octets"]}
if ram:
    d["ram_max_mo"] = ram
json.dump(d, open(out, "w"))
v = float(b["octets"])
for u in ("o", "Ko", "Mo", "Go", "To"):
    if v < 1024 or u == "To":
        break
    v /= 1024
pl = lambda n: "s" if n > 1 else ""
if env == 0 and b["retires"] == 0:
    txt = "aucun changement"
else:
    if env:
        txt = "%d fichier%s envoyé%s (%s)" % (env, pl(env), pl(env),
                                            "%d o" % v if u == "o" else "%.1f %s" % (v, u))
    else:
        txt = "rien à envoyer"
    if b["retires"]:
        r = b["retires"]
        txt += ", %d fichier%s supprimé%s du Drive" % (r, pl(r), pl(r))
        if ret > 0:
            txt += " (gardé%s %d j dans la corbeille)" % (pl(r), ret)
print(txt)
PY
}

duree_txt() {
  local s=$1
  if [ "$s" -lt 60 ]; then echo "moins d'une minute"
  elif [ "$s" -lt 3600 ]; then echo "$(( s / 60 )) min"
  else printf '%d h %02d\n' $(( s / 3600 )) $(( s % 3600 / 60 )); fi
}

# Transfert d'une sauvegarde (rclone) -> code de retour
nb_transfer() {  # nb_transfer <dest> <corbeille> <jour> <journal> <options...>
  local dest="$1" trash="$2" jour="$3" runlog="$4"; shift 4
  local rc
  if [ "$J_MODE" = sync ]; then
    if [ "${J_RET:-0}" -gt 0 ]; then
      rcl "$J_NAME" sync "$J_SRC" "$dest" --backup-dir "$trash/$jour" "$@"; rc=$?
    else
      rcl "$J_NAME" sync "$J_SRC" "$dest" "$@"; rc=$?
    fi
  else
    rcl "$J_NAME" copy "$J_SRC" "$dest" "$@"; rc=$?
  fi
  return $rc
}

run_job() {
  job_get "$1" || { rouge "Sauvegarde '$1' introuvable."; return 1; }
  local dest trash jour rc
  dest=$(dest_of "$J_ENC" "$J_SUB"); trash=$(trash_of "$J_ENC" "$J_NAME"); jour=$(date +%Y-%m-%d_%H%M)
  local runlog="$STATE_DIR/$J_NAME.run.log" runf="$STATE_DIR/$J_NAME.running"
  local -a opts=("${EXCLUDES[@]}" --log-file "$runlog" --log-level INFO)
  if [ -t 1 ]; then opts+=(-P); else opts+=(--stats 30s); fi
  [ -n "${J_BW:-}" ] && opts+=(--bwlimit "$J_BW")
  local jstop="$STATE_DIR/$J_NAME.stop"
  rm -f "$jstop"

  if [ ! -d "$J_SRC" ]; then
    rouge "Source introuvable : $J_SRC"; logl "$J_NAME : ECHEC (source introuvable)"
    echo "$(date '+%Y-%m-%d %H:%M') ECHEC" > "$STATE_DIR/$J_NAME.status"
    notify critique "job-$J_NAME" "Sauvegarde « $J_NAME » en échec" "Dossier source introuvable : $J_SRC (disque démonté ?)"
    return 1
  fi
  [ "$J_ENC" = oui ] && ensure_crypt
  perf_load "$J_PERF"

  local t0; t0=$(date +%s)
  gras "-> $J_NAME : $(short "$J_SRC")  =>  $dest"
  logl "$J_NAME : debut ($J_MODE, memoire $PERF_PROFIL $PERF_MO Mo) $J_SRC -> $dest"

  : > "$runlog"; echo "$$ $t0" > "$runf"
  ha_status
  ( while sleep "$HA_LIVE"; do
      [ -f "$runf" ] && kill -0 $$ 2>/dev/null || exit 0
      ha_status
    done ) 9>&- &
  local live=$!

  nb_transfer "$dest" "$trash" "$jour" "$runlog" "${opts[@]}"; rc=$?
  local ram=$RCL_MAX
  # manque de memoire : nouvel essai avec un seul fichier a la fois
  if [ "$rc" -ne 0 ] && [ ! -f "$STOPF" ] && [ ! -f "$jstop" ] && { [ "$rc" -ge 128 ] || oom_in "$runlog"; }; then
    logl "$J_NAME : manque de memoire (code $rc, $ram Mo) : reprise avec 1 fichier a la fois"
    jaune "Manque de memoire : reprise avec 1 fichier a la fois."
    # le journal du premier essai va dans le journal general ; le bilan ne compte que la reprise
    cat "$runlog" >> "$LOG"; : > "$runlog"
    perf_load econome
    nb_transfer "$dest" "$trash" "$jour" "$runlog" "${opts[@]}"; rc=$?
    [ "$RCL_MAX" -gt "$ram" ] && ram=$RCL_MAX
  fi
  if [ "$J_MODE" = sync ] && [ "${J_RET:-0}" -gt 0 ] && [ ! -f "$STOPF" ] && [ ! -f "$jstop" ]; then
    rclone delete "$trash" --min-age "${J_RET}d" -q 2>/dev/null
    rclone rmdirs "$trash" --leave-root -q 2>/dev/null
  fi

  rm -f "$runf"; kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
  cat "$runlog" >> "$LOG"
  local resume; resume=$(bilan "$runlog" "$t0" "$rc" "$ram")

  local duree=$(( ($(date +%s) - t0) / 60 ))
  if [ "$rc" -ne 0 ] && { [ -f "$STOPF" ] || [ -f "$jstop" ]; }; then
    echo "$(date '+%Y-%m-%d %H:%M') ARRETE" > "$STATE_DIR/$J_NAME.status"
    logl "$J_NAME : ARRETEE manuellement apres ${duree} min${resume:+ - $resume}"
    jaune "Arretee : $J_NAME${resume:+ - $resume}"
    notify info "stop-$J_NAME" "Sauvegarde « $J_NAME » arrêtée" "Arrêtée manuellement après ${duree} min. Elle reprendra à la prochaine exécution."
  elif [ "$rc" -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M') OK" > "$STATE_DIR/$J_NAME.status"
    date +%s > "$STATE_DIR/$J_NAME.lastok"
    logl "$J_NAME : OK${resume:+ - $resume}"; vert "OK : $J_NAME${resume:+ - $resume}"
    local quand; quand=$(duree_txt $(( $(date +%s) - t0 )))
    if [ "$resume" = "aucun changement" ]; then
      notify succes "job-$J_NAME" "Sauvegarde « $J_NAME »" "Déjà à jour : aucun changement depuis la dernière sauvegarde (vérifié en $quand)."
    else
      notify succes "job-$J_NAME" "Sauvegarde « $J_NAME »" "Terminée avec succès en $quand${resume:+ : $resume}."
    fi
  else
    echo "$(date '+%Y-%m-%d %H:%M') ECHEC" > "$STATE_DIR/$J_NAME.status"
    logl "$J_NAME : ECHEC (code $rc)"; rouge "ECHEC : $J_NAME (voir $LOG)"
    local err; err=$(grep -E 'ERROR|CRITICAL' "$runlog" | tail -n 1 | sed -E 's/^[0-9\/ :]+//' | cut -c1-200)
    oom_in "$runlog" && err="Mémoire insuffisante pour rclone ($ram Mo utilisés). Choisis un réglage mémoire plus économe."
    notify critique "job-$J_NAME" "Sauvegarde « $J_NAME » en échec" "Code $rc. ${err:-Voir $LOG sur le NAS.}"
  fi
  rm -f "$jstop"
  historise "$runlog"
  ha_status
  return "$rc"
}

stop_job() {
  local pat="rclone .*--log-file $STATE_DIR/$1.run.log" i
  job_exists "$1" || die "sauvegarde '$1' introuvable."
  if ! pgrep -f "$pat" >/dev/null; then vert "La sauvegarde '$1' n'est pas en cours."; return 0; fi
  touch "$STATE_DIR/$1.stop"
  logl "$1 : arret demande"
  pkill -TERM -f "$pat"
  for i in $(seq 30); do pgrep -f "$pat" >/dev/null || break; sleep 1; done
  if pgrep -f "$pat" >/dev/null; then pkill -KILL -f "$pat"; sleep 2; fi
  for i in $(seq 40); do flock -n "/run/nas-backup-$1.lock" true 2>/dev/null && break; sleep 1; done
  vert "Sauvegarde '$1' arretee. Elle reprendra a sa prochaine execution."
}

api_simulate() {
  job_get "$1" || die "sauvegarde '$1' introuvable."
  local out="$STATE_DIR/$J_NAME.simulation" dest cmd=sync rc
  dest=$(dest_of "$J_ENC" "$J_SUB")
  [ "$J_MODE" = copy ] && cmd=copy
  exec 8>"/run/nas-backup-simulation-$J_NAME.lock"
  flock -n 8 || die "une simulation de '$J_NAME' est deja en cours."
  [ -d "$J_SRC" ] || die "dossier source introuvable : $J_SRC"
  perf_load "$J_PERF"
  printf 'ETAT=en_cours\nDEBUT=%s\n' "$(date +%s)" > "$out.status"
  : > "$out.log"
  rcl "" "$cmd" "$J_SRC" "$dest" "${EXCLUDES[@]}" --dry-run --log-level NOTICE --log-file "$out.log" < /dev/null; rc=$?
  python3 - "$out.log" "$out.txt" "$out.status" "$rc" <<'PYSIM'
import re, sys, time
log, txt, st, rc = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
units = {"": 1, "k": 1024, "ki": 1024, "m": 1024**2, "mi": 1024**2, "g": 1024**3, "gi": 1024**3, "t": 1024**4, "ti": 1024**4}
env = sup = octets = 0
lines = []
rx = re.compile(r"NOTICE: (.+?): Skipped (copy|delete|move)\b.*?(?:\(size ([\d.]+)\s*([KMGT]?i?)\))?\s*$", re.I)
for l in open(log, errors="ignore"):
    m = rx.search(l.rstrip())
    if not m:
        continue
    kind = m.group(2).lower()
    if kind == "copy":
        env += 1
        if m.group(3):
            octets += int(float(m.group(3)) * units.get((m.group(4) or "").lower(), 1))
        lines.append("+ " + m.group(1))
    else:
        sup += 1
        lines.append("- " + m.group(1))
with open(txt, "w") as f:
    f.write("\n".join(lines[:2000]) + ("\n" if lines else ""))
with open(st, "w") as f:
    f.write("ETAT=%s\nFIN=%d\nENVOIS=%d\nSUPPRESSIONS=%d\nOCTETS=%d\n" % ("ok" if rc == 0 else "echec", time.time(), env, sup, octets))
PYSIM
  vert "Simulation de '$J_NAME' terminee."
}

historise() {
  local h="$STATE_DIR/historique.jsonl" st err
  st=$(awk '{print $NF}' "$STATE_DIR/$J_NAME.status" 2>/dev/null)
  err=$(grep -E 'ERROR|CRITICAL' "$1" 2>/dev/null | grep -v 'Attempt [0-9]' | tail -n 1 | sed -E 's/^[0-9\/ :]+//' | cut -c1-300)
  python3 - "$STATE_DIR/$J_NAME.bilan.json" "$J_NAME" "${st:-?}" "$err" "$h" <<'PY2' 2>/dev/null
import json, sys
bilan, nom, etat, err, out = sys.argv[1:6]
try:
    d = json.load(open(bilan))
except Exception:
    d = {}
d.update({"nom": nom, "etat": etat, "erreur": err})
with open(out, "a") as f:
    f.write(json.dumps(d, ensure_ascii=False) + "\n")
PY2
  if [ "$(wc -l < "$h" 2>/dev/null || echo 0)" -gt 3000 ]; then
    tail -n 2500 "$h" > "$h.tmp" && mv -f "$h.tmp" "$h"
  fi
}

run_job_locked() {
  [ -f "$STOPF" ] && { jaune "Arret demande : '$1' n'est pas lancee."; return 1; }
  ( flock -n 9 || { jaune "La sauvegarde '$1' est deja en cours."; exit 1; }
    run_job "$1" ) 9>"/run/nas-backup-$1.lock"
}

run_at() {
  local n rc=0 dow
  dow=$(date +%u)
  rm -f "$STOPF"
  for n in $(job_names); do
    job_get "$n" || continue
    [ -f "$STOPF" ] && break
    slot_matches "$J_SCHED" "$1" "$dow" && { run_job_locked "$n" || rc=1; }
  done
  return $rc
}

run_all() {
  local n rc=0
  rm -f "$STOPF"
  for n in $(job_names); do
    [ -f "$STOPF" ] && break
    run_job_locked "$n" || rc=1
  done
  return $rc
}

stop_all() {
  local pat="rclone .*--log-file $STATE_DIR/" i
  if ! pgrep -f "$pat" >/dev/null && ! pgrep -f "nas-(backup|debian) run" >/dev/null; then
    vert "Aucune sauvegarde en cours."; return 0
  fi
  touch "$STOPF"
  logl "arret demande (nas-backup stop)"
  jaune "Arret demande : aucune nouvelle sauvegarde ne sera lancee."
  pkill -TERM -f "$pat"
  for i in $(seq 30); do pgrep -f "$pat" >/dev/null || break; sleep 1; done
  if pgrep -f "$pat" >/dev/null; then
    jaune "rclone ne s'est pas ferme en 30 s : arret force."
    pkill -KILL -f "$pat"; sleep 2
  fi
  for i in $(seq 30); do pgrep -f "nas-(backup|debian) run" >/dev/null || break; sleep 1; done
  if pgrep -f "$pat" >/dev/null; then
    rouge "Un transfert tourne encore : pgrep -af rclone"; return 1
  fi
  vert "Sauvegardes arretees. Elles reprendront au prochain horaire prevu."
}

restore_job() {
  gras "== Restaurer une sauvegarde =="
  choose_job "Laquelle" || return
  job_get "$ANS"
  local dest base target
  dest=$(dest_of "$J_ENC" "$J_SUB")
  base=$(echo "$J_SRC" | grep -oE '^/srv/dev-disk-by-(uuid|label)-[^/]+' || dirname "$J_SRC")
  ask "Dossier de restauration" "$base/Restauration/${J_NAME}_$(date +%Y-%m-%d_%H%M)"
  target="${ANS%/}"
  if [ "$target" = "$J_SRC" ]; then
    jaune "Restaurer directement dans le dossier source ecrasera les fichiers locaux."
    ask_yn "Continuer ?" n || return
  fi
  mkdir -p "$target"
  perf_load "$J_PERF"
  rcl "" copy "$dest" "$target" "${EXCLUDES[@]}" -P && vert "Restauration terminee : $target" || rouge "Echec de la restauration."
}

show_log() {
  tail -n 40 "$LOG"
  echo
  echo "(pendant une sauvegarde, son detail est dans $STATE_DIR/<NOM>.run.log)"
  ask_yn "Suivre en direct (Ctrl+C pour arreter) ?" n && tail -f "$LOG" "$STATE_DIR"/*.run.log
}

show_tools() {
  gras "== Outils et version =="
  echo "nas-debian $SCRIPT_VERSION ($MACHINE, $(uname -m), $(ram_total_mo) Mo de RAM)"
  perf_load
  echo "Memoire de rclone : profil $PERF_PROFIL, limite $PERF_MO Mo (${PERF_FLAGS[*]})"
  outils_etat | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("  %-14s %s" % (k, v)) for k, v in d.items()]'
}

menu() {
  while true; do
    clear
    gras "========== SAUVEGARDES NAS -> GOOGLE DRIVE ($MACHINE) =========="
    echo
    list_jobs
    echo
    echo "  1) Ajouter une sauvegarde"
    echo "  2) Modifier une sauvegarde"
    echo "  3) Supprimer une sauvegarde"
    echo "  4) Lancer une sauvegarde maintenant"
    echo "  5) Lancer toutes les sauvegardes"
    echo "  6) Restaurer une sauvegarde"
    echo "  7) Voir le journal"
    echo "  8) Arreter les sauvegardes en cours"
    echo "  9) Outils, version et memoire de rclone"
    echo "  0) Quitter"
    echo
    rd_ "Choix : " c
    echo
    case "$c" in
      1) add_job; pause ;;
      2) edit_job; pause ;;
      3) delete_job; pause ;;
      4) choose_job "Laquelle" && { rm -f "$STOPF"; run_job_locked "$ANS"; }; pause ;;
      5) run_all; pause ;;
      6) restore_job; pause ;;
      7) show_log; pause ;;
      8) stop_all; pause ;;
      9) show_tools; pause ;;
      0|q|Q) exit 0 ;;
      *) ;;
    esac
  done
}

# --------------------------- Commandes sans question -----------------
api_save() {  # api_save <nouveau|modif> NOM SOURCE DOSSIER_DRIVE MODE CHIFFRE HORAIRE CORBEILLE [DEBIT] [MEMOIRE]
  local kind="$1"; shift
  [ $# -ge 7 ] && [ $# -le 9 ] || die "usage : nas-backup save <nouveau|modif> NOM SOURCE DOSSIER MODE CHIFFRE HORAIRE CORBEILLE [DEBIT] [MEMOIRE]"
  J_NAME="$1" J_SRC="${2%/}" J_SUB="$3" J_MODE="$4" J_ENC="$5" J_SCHED="$6" J_RET="$7" J_BW="${8:-}" J_PERF="${9:-}"
  J_SUB="${J_SUB#/}"; J_SUB="${J_SUB%/}"
  [[ "$J_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "nom invalide (lettres, chiffres, - et _)."
  case "$kind" in
    nouveau) job_exists "$J_NAME" && die "une sauvegarde '$J_NAME' existe deja." ;;
    modif)   job_exists "$J_NAME" || die "sauvegarde '$J_NAME' introuvable." ;;
    *)       die "type inconnu : $kind" ;;
  esac
  [[ "$J_SRC" != *"|"* && -d "$J_SRC" ]] || die "dossier source introuvable : $J_SRC"
  [[ -z "$J_SUB" || "$J_SUB" == *"|"* || "$J_SUB" == _corbeille* ]] && die "dossier Drive invalide."
  [[ "$J_MODE" =~ ^(sync|copy)$ ]] || die "mode invalide (sync ou copy)."
  [[ "$J_ENC" =~ ^(oui|non)$ ]] || die "chiffrement invalide (oui ou non)."
  valid_sched "$J_SCHED" || die "horaire invalide (HH:MM, HH:MM/JOURS, plusieurs separes par ; ou manuel)."
  [[ -z "$J_BW" || "$J_BW" =~ ^[0-9A-Za-z:.,\ -]+$ ]] || die "limite de debit invalide (ex. 5M)."
  [[ "$J_RET" =~ ^[0-9]+$ ]] || die "nombre de jours de corbeille invalide."
  valid_perf "$J_PERF" || die "reglage memoire invalide (auto, econome, equilibre, performant ou un nombre de Mo >= 64)."
  [ "$J_MODE" = copy ] && J_RET=0
  local n s sub m e sch r
  while IFS='|' read -r n s sub m e sch r _ || [ -n "$n" ]; do
    [[ -z "$n" || "$n" == \#* || "$n" == "$J_NAME" ]] && continue
    if [ "$e" = "$J_ENC" ] && { [[ "$sub" == "$J_SUB" ]] || [[ "$sub" == "$J_SUB/"* ]] || [[ "$J_SUB" == "$sub/"* ]]; }; then
      jaune "Attention : la sauvegarde '$n' utilise deja le dossier Drive '$sub'."
    fi
  done < "$JOBS"
  local old_dest=""
  if [ "$kind" = modif ]; then
    local nm="$J_NAME" a b c d f g h
    IFS='|' read -r a b c d f g h _ <<< "$(grep -m1 "^$nm|" "$JOBS")"
    old_dest=$(dest_of "$f" "$c")
  fi
  [ "$J_ENC" = oui ] && ensure_crypt
  job_save; gen_cron
  logl "$J_NAME : configuration enregistree (application)"
  vert "Sauvegarde '$J_NAME' enregistree -> $(dest_of "$J_ENC" "$J_SUB")"
  if [ -n "$old_dest" ] && [ "$old_dest" != "$(dest_of "$J_ENC" "$J_SUB")" ]; then
    jaune "La destination a change : les fichiers deja envoyes restent dans $old_dest"
  fi
}

api_delete() {
  job_get "$1" || die "sauvegarde '$1' introuvable."
  local dest trash; dest=$(dest_of "$J_ENC" "$J_SUB"); trash=$(trash_of "$J_ENC" "$J_NAME")
  job_del "$J_NAME"; gen_cron
  logl "$J_NAME : sauvegarde supprimee (application)"
  vert "Sauvegarde '$J_NAME' supprimee (plus de planification)."
  if [ "${2:-}" = effacer-drive ]; then
    rclone purge "$dest" -q 2>/dev/null; rclone purge "$trash" -q 2>/dev/null
    logl "$J_NAME : donnees supprimees du Drive"
    vert "Fichiers effaces du Drive : $dest"
  else
    jaune "Les fichiers sur le Drive sont conserves : $dest"
  fi
}

safe_rel() {
  local r="${1#/}"; r="${r%/}"
  [[ "/$r/" == *"/../"* || "$r" == *"|"* ]] && die "chemin invalide : $1"
  REL="$r"
}

api_restore() {
  local st="$STATE_DIR/restauration.status" rlog="$STATE_DIR/restauration.log"
  job_get "$1" || die "sauvegarde '$1' introuvable."
  local target="${2%/}" dest rc rel
  [ -n "$target" ] || die "dossier de restauration manquant."
  safe_rel "${3:-}"; rel="$REL"
  if [ "${4:-}" = corbeille ]; then dest=$(trash_of "$J_ENC" "$J_NAME"); else dest=$(dest_of "$J_ENC" "$J_SUB"); fi
  [ -n "$rel" ] && dest="$dest/$rel"
  exec 9>/run/nas-backup-restauration.lock
  flock -n 9 || die "une restauration est deja en cours."
  mkdir -p "$target" || die "impossible de creer $target"
  perf_load "$J_PERF"
  : > "$rlog"
  printf 'ETAT=en_cours\nNOM=%q\nCIBLE=%q\nELEMENT=%q\nDEBUT=%s\n' "$J_NAME" "$target" "$rel" "$(date +%s)" > "$st"
  logl "$J_NAME : restauration vers $target"
  if [ -n "$rel" ] && rclone lsf "$dest" --max-depth 1 2>/dev/null | grep -x "${rel##*/}" >/dev/null; then
    rcl restauration copyto "$dest" "$target/${rel##*/}" --stats 10s --log-file "$rlog" --log-level INFO; rc=$?
  elif [ -n "$rel" ]; then
    rcl restauration copy "$dest" "$target/${rel##*/}" "${EXCLUDES[@]}" --stats 10s --log-file "$rlog" --log-level INFO; rc=$?
  else
    rcl restauration copy "$dest" "$target" "${EXCLUDES[@]}" --stats 10s --log-file "$rlog" --log-level INFO; rc=$?
  fi
  if [ $rc -eq 0 ]; then
    printf 'ETAT=ok\nNOM=%q\nCIBLE=%q\nELEMENT=%q\nFIN=%s\n' "$J_NAME" "$target" "$rel" "$(date +%s)" > "$st"
    logl "$J_NAME : restauration terminee ($target)"
    notify info "restore-$J_NAME" "Restauration « $J_NAME » terminée" "Fichiers restaurés dans $target"
  else
    printf 'ETAT=echec\nNOM=%q\nCIBLE=%q\nELEMENT=%q\nFIN=%s\nCODE=%s\n' "$J_NAME" "$target" "$rel" "$(date +%s)" "$rc" > "$st"
    logl "$J_NAME : restauration en ECHEC (code $rc)"
    notify critique "restore-$J_NAME" "Restauration « $J_NAME » en échec" "Code $rc. Détails : $rlog"
  fi
  return $rc
}

api_ls() {
  job_get "$1" || die "sauvegarde '$1' introuvable."
  local rel dest
  safe_rel "${2:-}"; rel="$REL"
  if [ "${3:-}" = corbeille ]; then dest=$(trash_of "$J_ENC" "$J_NAME"); else dest=$(dest_of "$J_ENC" "$J_SUB"); fi
  [ -n "$rel" ] && dest="$dest/$rel"
  rclone lsjson "$dest" --max-depth 1 --no-mimetype "${EXCLUDES[@]}" 2>&1
}

api_verify() {
  job_get "$1" || die "sauvegarde '$1' introuvable."
  local out="$STATE_DIR/$J_NAME.verif" dest rc
  dest=$(dest_of "$J_ENC" "$J_SUB")
  exec 7>"/run/nas-backup-verif-$J_NAME.lock"
  flock -n 7 || die "une verification de '$J_NAME' est deja en cours."
  [ -d "$J_SRC" ] || die "dossier source introuvable : $J_SRC"
  perf_load "$J_PERF"
  mkdir -p "$out.d"; rm -f "$out.d"/*
  printf 'ETAT=en_cours\nDEBUT=%s\n' "$(date +%s)" > "$out.status"
  local -a o=(--one-way "${EXCLUDES[@]}" --match "$out.d/identiques" --differ "$out.d/differents"
              --missing-on-dst "$out.d/manquants" --error "$out.d/erreurs" --log-file "$out.log" --log-level NOTICE)
  [ "$J_MODE" = sync ] && o=("${o[@]:1}" --missing-on-src "$out.d/en-trop")
  if [ "$J_ENC" = oui ]; then
    rcl "" cryptcheck "$J_SRC" "$dest" "${o[@]}" < /dev/null; rc=$?
  else
    rcl "" check "$J_SRC" "$dest" "${o[@]}" < /dev/null; rc=$?
  fi
  local c_ok c_diff c_miss c_extra c_err
  c_ok=$(cnt "$out.d/identiques"); c_diff=$(cnt "$out.d/differents"); c_miss=$(cnt "$out.d/manquants")
  c_extra=$(cnt "$out.d/en-trop"); c_err=$(cnt "$out.d/erreurs")
  local etat=ok
  [ $((c_diff + c_miss + c_extra + c_err)) -gt 0 ] && etat=ecarts
  [ "$rc" -ne 0 ] && [ "$etat" = ok ] && etat=echec
  printf 'ETAT=%s\nFIN=%s\nIDENTIQUES=%s\nDIFFERENTS=%s\nMANQUANTS=%s\nEN_TROP=%s\nERREURS=%s\n' \
    "$etat" "$(date +%s)" "$c_ok" "$c_diff" "$c_miss" "$c_extra" "$c_err" > "$out.status"
  logl "$J_NAME : verification $etat ($c_ok identiques, $c_diff differents, $c_miss manquants sur le Drive, $c_extra en trop, $c_err erreurs)"
  if [ "$etat" = ok ]; then
    notify ok "verif-$J_NAME" "Vérification « $J_NAME »" "La sauvegarde est de nouveau identique au NAS."
  else
    notify critique "verif-$J_NAME" "Vérification « $J_NAME » : écarts" "$c_diff différent(s), $c_miss manquant(s) sur le Drive, $c_err erreur(s). Une nouvelle sauvegarde les corrige en général."
  fi
  vert "Verification de '$J_NAME' : $etat"
}

VERIF_CONF="$CONF_DIR/verification"
api_verify_plan() {
  if [ "$1" = off ]; then rm -f "$VERIF_CONF"; gen_cron; vert "Verification automatique desactivee."; return; fi
  [[ "$1" =~ ^[1-7]+$ ]] || die "jours invalides (1 = lundi ... 7 = dimanche)."
  [[ "${2:-}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "heure invalide (HH:MM)."
  echo "$1 $2" > "$VERIF_CONF"; gen_cron
  vert "Verification automatique : jours $1 a $2."
}
verify_all() {
  local n
  for n in $(job_names); do ( api_verify "$n" ) || true; done
}

# =========================== Reglages ================================
reglages() {  # reglages voir | ram <profil> [Mo] [transferts] [verifs] [tampon]
  case "${1:-voir}" in
    voir)
      agent_conf_load; perf_load
      printf '{"profil":"%s","mo":"%s","transferts":"%s","verifs":"%s","tampon":"%s","effectif":{"profil":"%s","mo":%s,"options":"%s"},"ram_total_mo":%s,"ram_dispo_mo":%s}\n' \
        "$RAM_PROFIL" "$RAM_MO" "$TRANSFERTS" "$VERIFS" "$TAMPON" "$PERF_PROFIL" "$PERF_MO" "${PERF_FLAGS[*]}" "$(ram_total_mo)" "$(ram_dispo_mo)" ;;
    ram)
      local p="${2:-auto}" mo="${3:-}" t="${4:-}" c="${5:-}" b="${6:-}"
      [[ "$p" =~ ^(auto|econome|equilibre|performant)$ ]] || die "profil invalide (auto, econome, equilibre, performant)."
      [ "$mo" = - ] && mo=""; [ "$t" = - ] && t=""; [ "$c" = - ] && c=""; [ "$b" = - ] && b=""
      [ -z "$mo" ] || { [[ "$mo" =~ ^[0-9]+$ ]] && [ "$mo" -ge 64 ]; } || die "limite de memoire invalide (nombre de Mo, 64 au minimum)."
      [ -z "$t" ] || [[ "$t" =~ ^[1-9][0-9]?$ ]] || die "nombre de transferts invalide (1 a 99)."
      [ -z "$c" ] || [[ "$c" =~ ^[1-9][0-9]?$ ]] || die "nombre de verifications invalide (1 a 99)."
      [ -z "$b" ] || [[ "$b" =~ ^[0-9]+[KMG]?$ ]] || die "tampon invalide (ex. 0, 16M)."
      local tot; tot=$(ram_total_mo)
      if [ -n "$mo" ] && [ "$mo" -gt $(( tot * 3 / 4 )) ]; then
        jaune "Attention : $mo Mo, c'est plus des 3/4 de la memoire de la machine ($tot Mo)."
      fi
      mkdir -p "$CONF_DIR"
      printf 'RAM_PROFIL=%s\nRAM_MO=%s\nTRANSFERTS=%s\nVERIFS=%s\nTAMPON=%s\n' "$p" "$mo" "$t" "$c" "$b" > "$AGENT_CONF"
      perf_load
      vert "Memoire de rclone : profil $PERF_PROFIL, limite $PERF_MO Mo (${PERF_FLAGS[*]})." ;;
    *) die "usage : nas-debian reglages voir | ram <profil> [Mo] [transferts] [verifs] [tampon]" ;;
  esac
}

version_json() {
  printf '{"script":"nas-debian","version":"%s","api":%s,"machine":"%s"}\n' "$SCRIPT_VERSION" "$API_VERSION" "$MACHINE"
}

# =========================== Point d'entree ==========================
backup_main() {
  nb_init
  case "${1:-}" in
    "")       self_install; need_rclone; gen_cron; menu ;;
    run)      [ -n "${2:-}" ] || die "usage : nas-backup run <NOM>"; need_rclone; rm -f "$STOPF"; run_job_locked "$2" ;;
    run-at)   [ -n "${2:-}" ] || die "usage : nas-backup run-at <HH:MM>"; need_rclone; run_at "$2" ;;
    run-all)  need_rclone; run_all ;;
    list)     list_jobs ;;
    stop)     if [ -n "${2:-}" ]; then stop_job "$2"; else stop_all; fi ;;
    simulate) [ -n "${2:-}" ] || die "usage : nas-backup simulate <NOM>"; need_rclone; api_simulate "$2" ;;
    save)     shift; need_rclone; api_save "$@" ;;
    delete)   [ -n "${2:-}" ] || die "usage : nas-backup delete <NOM> [effacer-drive]"; [ "${3:-}" = effacer-drive ] && need_rclone; api_delete "$2" "${3:-}" ;;
    restore)  [ -n "${3:-}" ] || die "usage : nas-backup restore <NOM> <DOSSIER> [ELEMENT] [corbeille]"; need_rclone; api_restore "$2" "$3" "${4:-}" "${5:-}" ;;
    ls)       [ -n "${2:-}" ] || die "usage : nas-backup ls <NOM> [CHEMIN] [corbeille]"; need_rclone; api_ls "$2" "${3:-}" "${4:-}" ;;
    verifier) [ -n "${2:-}" ] || die "usage : nas-backup verifier <NOM>"; need_rclone; api_verify "$2" ;;
    verifier-tout) need_rclone; verify_all ;;
    verif-plan) api_verify_plan "${2:-}" "${3:-}" ;;
    gen-cron) gen_cron ;;
    api-version) echo "$API_VERSION" ;;
    *)        echo "Usage : nas-backup [run <NOM> | run-at <HH:MM> | run-all | list | stop | save ... | delete <NOM> | restore <NOM> <DOSSIER>]"; exit 1 ;;
  esac
}

agent_main() {
  case "${1:-}" in
    version)   version_json ;;
    installer) [ "$(id -u)" -eq 0 ] || die "lance ce script en root."; install_base ;;
    outils)
      case "${2:-etat}" in
        etat)       outils_etat ;;
        installer)  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."; shift 2; outils_installer "$@" ;;
        rclone-maj) outils_rclone_maj ;;
        derniere)   outils_rclone_derniere ;;
        *) die "usage : nas-debian outils etat | installer [suivi] | rclone-maj" ;;
      esac ;;
    reglages)  shift; reglages "$@" ;;
    racines)   data_roots ;;
    dossiers)  data_dirs ;;
    migrer)    migrer "${2:-simulation}" ;;
    alertes)   [ "${2:-}" = configurer ] || die "usage : nas-debian alertes configurer <ip HA> <webhook> [o|n]"; alertes_configurer "${3:-}" "${4:-}" "${5:-n}" ;;
    suivi)     [ "${2:-}" = configurer ] || die "usage : nas-debian suivi configurer <serveur MQTT>"; suivi_configurer "${3:-}" ;;
    notify)    shift; notify_cmd "$@" ;;
    check)     check_cmd ;;
    ha-status) ha_status_cmd ;;
    *)         backup_main "$@" ;;
  esac
}

case "$(basename "$0")" in
  nas-backup)    backup_main "$@" ;;
  nas-notify)    notify_cmd "$@" ;;
  nas-check)     check_cmd ;;
  nas-ha-status) ha_status_cmd ;;
  *)             agent_main "$@" ;;
esac
