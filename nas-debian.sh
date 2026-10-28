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
#    alertes voir | canal <ha|ntfy|telegram|discord|email> [tout|critique] | niveau <canal> <niveau>
#            | retirer <canal> | tester [canal] | telegram | seuils <rappel h> <espace %> <retard h>
#                                   canaux de notification (parametres cle=valeur sur l'entree standard)
#    disques verifier | etat        sante des disques (SMART) et du RAID
#    rapport voir | envoyer [hebdo|mensuel] | planifier <hebdo|mensuel|non> [jour] [HH:MM] [canaux]
#    suivi configurer <serveur MQTT>   (utilisateur et mot de passe sur l'entree standard)
#    notify <critique|info|succes|ok> <tag> <titre> <message>
#    check                          verification (comme nas-check)
#    ha-status                      publication Home Assistant (comme nas-ha-status)
#    destinations liste | etat [NOM] | creer NOM TYPE | jeton NOM TYPE | supprimer NOM
#                                   destinations des sauvegardes (remotes rclone)
#    versions liste | ls | restaurer | entretien   sauvegardes versionnees (restic)
#    secours etat | sauvegarder | telecharger | restaurer | mots-de-passe
#                                   kit de secours (ce qui permet de tout reconstruire)
#    mots-de-passe                  mots de passe de chiffrement (affichage)
#    <commandes de nas-backup>      run, run-at, run-all, stop, save, delete, restore,
#                                   ls, simulate, verifier, verifier-tout, verif-plan,
#                                   gen-cron, list, api-version
# =====================================================================
set -uo pipefail

SCRIPT_VERSION="2.3.0"
API_VERSION=8

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
# destinations, sauvegardes versionnees, kit de secours
VERSIONS_FOLDER="NAS-versions"   # depots restic sur chaque destination
SECOURS_FOLDER="NAS-secours"     # kit de secours sur chaque destination (chiffre par openssl)
DEFAULT_ROT="7:4:12:0"           # versions gardees : jours, semaines, mois, annees
RESTIC_PASS="$CONF_DIR/restic.pass"
SECOURS_PASS="$CONF_DIR/secours.pass"
SECOURS_DIR="$STATE_DIR/secours"
DEST_JSON="$STATE_DIR/destinations.json"
RESTIC_CACHE="/var/cache/nas-backup/restic"

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
  RAM_PROFIL=auto RAM_MO="" TRANSFERTS="" VERIFS="" TAMPON="" CAM_JOB=""
  # shellcheck disable=SC1090
  [ -f "$AGENT_CONF" ] && . "$AGENT_CONF"
  return 0
}

agent_conf_set() {  # agent_conf_set <CLE> <valeur> (les autres reglages sont gardes)
  mkdir -p "$CONF_DIR"; touch "$AGENT_CONF"
  grep -v "^$1=" "$AGENT_CONF" > "$AGENT_CONF.new"
  printf '%s=%q\n' "$1" "$2" >> "$AGENT_CONF.new"
  mv -f "$AGENT_CONF.new" "$AGENT_CONF"
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
  [ -n "${PERF_MEM:-}" ] || perf_load
  gorun "$tag" rclone "$@" "${PERF_FLAGS[@]}"
}

# gorun <etiquette> <programme> <arguments...> : programme Go (rclone, restic) avec la
# limite de memoire ; pic dans RCL_MAX, memoire en cours dans $STATE_DIR/<etiquette>.rss
gorun() {
  local tag="$1"; shift
  local pid rss max=0 rc
  [ -n "${PERF_MEM:-}" ] || perf_load
  GOGC=50 GOMEMLIMIT="$PERF_MEM" "$@" &
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
# Canaux, au choix et combinables : Home Assistant (notify.conf : HA_URL, WEBHOOK),
# ntfy, Telegram, Discord, e-mail (canaux.conf). Home Assistant n'est plus obligatoire.
#   critique : alerte prioritaire (rappel toutes les REPEAT_HOURS si non resolue) -> tous les canaux
#   succes   : notification discrete, ou "retabli" si une alerte etait en cours
#   ok       : silencieux, sauf "retabli" si une alerte etait en cours
#   info     : notification discrete (canaux reglés sur « tout »)
# L'alerte en cours est toujours notee (alertes/<tag>), meme sans canal : NAS Manager l'affiche.
CANAUX_CONF="$CONF_DIR/canaux.conf"
RAPPORT_CONF="$CONF_DIR/rapport.conf"
CANAUX=(ha ntfy telegram discord email)

# conf_set_file <fichier> <CLE> <valeur> : reglage d'un fichier « source » (les autres sont gardes)
conf_set_file() {
  mkdir -p "$(dirname "$1")"; touch "$1"; chmod 600 "$1"
  grep -v "^$2=" "$1" > "$1.new"
  [ -n "$3" ] && printf '%s=%q\n' "$2" "$3" >> "$1.new"
  mv -f "$1.new" "$1"; chmod 600 "$1"
}

# Canaux configures (ha ntfy telegram discord email), un par ligne
canaux_actifs() {
  (
    HA_URL="" WEBHOOK="" NTFY_URL="" TELEGRAM_TOKEN="" TELEGRAM_CHAT="" DISCORD_URL="" MAIL_TO="" SMTP_HOST=""
    # shellcheck disable=SC1090
    [ -f "$NOTIFY_CONF" ] && . "$NOTIFY_CONF"
    # shellcheck disable=SC1090
    [ -f "$CANAUX_CONF" ] && . "$CANAUX_CONF"
    [ -n "$HA_URL" ] && [ -n "$WEBHOOK" ] && echo ha
    [ -n "$NTFY_URL" ] && echo ntfy
    [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT" ] && echo telegram
    [ -n "$DISCORD_URL" ] && echo discord
    [ -n "$MAIL_TO" ] && [ -n "$SMTP_HOST" ] && echo email
  )
  return 0
}

# notif_send <critique|retabli|info|rapport> <titre> <message> [canal]
#   envoie vers les canaux (ou le seul canal indique) ; une ligne « canal|ok » ou « canal|erreur »
#   par canal sur la sortie ; code 0 si au moins un envoi a reussi
notif_send() {
  [ -f "$NOTIFY_CONF" ] || [ -f "$CANAUX_CONF" ] || return 1
  (
    # shellcheck disable=SC1090
    [ -f "$NOTIFY_CONF" ] && . "$NOTIFY_CONF"
    # shellcheck disable=SC1090
    [ -f "$CANAUX_CONF" ] && . "$CANAUX_CONF"
    # shellcheck disable=SC1090
    [ -f "$RAPPORT_CONF" ] && . "$RAPPORT_CONF"
    export HA_URL WEBHOOK NTFY_URL NTFY_TOKEN NTFY_NIVEAU TELEGRAM_TOKEN TELEGRAM_CHAT TELEGRAM_NIVEAU \
      DISCORD_URL DISCORD_NIVEAU MAIL_TO MAIL_FROM SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_SECU MAIL_NIVEAU \
      HA_NIVEAU RAPPORT_CANAUX
    python3 - "$1" "$2" "$3" "${4:-}" "$(hostname -s 2>/dev/null)" "$STATE_DIR/notifications.log" <<'PYN'
import json, os, smtplib, ssl, sys, time, urllib.request
from email.message import EmailMessage
level, title, msg, only, host, logf = sys.argv[1:7]
E = lambda k: os.environ.get(k, "") or ""
TG_API = os.environ.get("NAS_TELEGRAM_API", "https://api.telegram.org")
ctx = ssl.create_default_context()
insecure = ssl.create_default_context(); insecure.check_hostname = False; insecure.verify_mode = ssl.CERT_NONE

def post(url, data, headers=None, verify=True):
    h = {"Content-Type": "application/json", "User-Agent": "nas-debian"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=json.dumps(data).encode() if not isinstance(data, bytes) else data, headers=h, method="POST")
    with urllib.request.urlopen(req, timeout=20, context=ctx if verify else insecure) as r:
        return r.status

icon = {"critique": "🚨 ", "retabli": "", "info": "", "rapport": "📋 "}.get(level, "")

def ha():
    kind = "critique" if level == "critique" else "info"
    post("%s/api/webhook/%s-%s" % (E("HA_URL"), E("WEBHOOK"), kind), {"title": title, "message": msg, "tag": os.environ.get("NAS_TAG", "")}, verify=False)

def ntfy():
    base, _, topic = E("NTFY_URL").rstrip("/").rpartition("/")
    prio = {"critique": 5, "retabli": 3, "info": 3, "rapport": 2}.get(level, 3)
    tags = {"critique": ["rotating_light"], "retabli": ["white_check_mark"], "rapport": ["clipboard"]}.get(level, [])
    hd = {"Authorization": "Bearer " + E("NTFY_TOKEN")} if E("NTFY_TOKEN") else {}
    post(base, {"topic": topic, "title": title, "message": msg[:3900], "priority": prio, "tags": tags}, hd)

def telegram():
    post("%s/bot%s/sendMessage" % (TG_API, E("TELEGRAM_TOKEN")),
         {"chat_id": E("TELEGRAM_CHAT"), "text": ("%s%s\n%s" % (icon, title, msg))[:4000], "disable_notification": level not in ("critique",)})

def discord():
    post(E("DISCORD_URL"), {"content": ("%s**%s**\n%s" % (icon, title, msg))[:1990]})

def email():
    m = EmailMessage()
    m["Subject"] = "[NAS %s] %s%s" % (host, icon, title)
    m["From"] = E("MAIL_FROM") or E("SMTP_USER") or E("MAIL_TO")
    m["To"] = E("MAIL_TO")
    m.set_content(msg + "\n\n-- \nnas-debian (%s)\n" % host)
    port = int(E("SMTP_PORT") or (465 if E("SMTP_SECU") == "ssl" else 587 if E("SMTP_SECU") != "aucune" else 25))
    if E("SMTP_SECU") == "ssl":
        s = smtplib.SMTP_SSL(E("SMTP_HOST"), port, timeout=30, context=ctx)
    else:
        s = smtplib.SMTP(E("SMTP_HOST"), port, timeout=30)
        if E("SMTP_SECU") != "aucune":
            s.starttls(context=ctx)
    with s:
        if E("SMTP_USER"):
            s.login(E("SMTP_USER"), E("SMTP_PASS"))
        s.send_message(m)

SEND = {"ha": ha, "ntfy": ntfy, "telegram": telegram, "discord": discord, "email": email}
conf = {"ha": E("HA_URL") and E("WEBHOOK"), "ntfy": E("NTFY_URL"), "telegram": E("TELEGRAM_TOKEN") and E("TELEGRAM_CHAT"),
        "discord": E("DISCORD_URL"), "email": E("MAIL_TO") and E("SMTP_HOST")}
lvl = {"ha": E("HA_NIVEAU") or "tout", "ntfy": E("NTFY_NIVEAU") or "tout", "telegram": E("TELEGRAM_NIVEAU") or "tout",
       "discord": E("DISCORD_NIVEAU") or "tout", "email": E("MAIL_NIVEAU") or "critique"}
rapport = E("RAPPORT_CANAUX").split()
ok = 0
for c, fn in SEND.items():
    if only and c != only:
        continue
    if not conf[c]:
        if only:
            print("%s|non configure" % c)
        continue
    if not only:
        if level == "info" and lvl[c] != "tout":
            continue
        if level == "rapport" and rapport and c not in rapport:
            continue
    try:
        fn()
        ok += 1
        print("%s|ok" % c)
    except Exception as e:
        err = str(getattr(e, "reason", "") or e)[:200] or type(e).__name__
        print("%s|%s" % (c, err))
        try:
            with open(logf, "a") as f:
                f.write("%s %s %s : %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), c, title, err))
        except OSError:
            pass
sys.exit(0 if ok else 1)
PYN
  )
}

notify_cmd() {
  local REPEAT_HOURS=12
  # shellcheck disable=SC1090
  [ -f "$NOTIFY_CONF" ] && . "$NOTIFY_CONF"
  local level="${1:-info}" tag="${2:-nas}" title="${3:-NAS}" msg="${4:-}" f
  tag=$(printf '%s' "$tag" | tr -c 'A-Za-z0-9_-' '_')
  f="$STATE_DIR/alertes/$tag"
  mkdir -p "$STATE_DIR/alertes"
  export NAS_TAG="$tag"
  case "$level" in
    critique)
      # deja signalee (et bien envoyee) depuis moins de REPEAT_HOURS : pas de rappel
      if [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null)" != echec ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -lt $(( ${REPEAT_HOURS:-12} * 3600 )) ]; then return 0; fi
      # (echec : l'heure de debut de l'alerte est gardee, l'envoi est retente a chaque verification)
      if notif_send critique "$title" "$msg" >/dev/null; then : > "$f"; elif [ ! -f "$f" ]; then echo echec > "$f"; fi ;;
    succes)
      if [ -f "$f" ]; then rm -f "$f"; notif_send retabli "✅ Rétabli : $title" "$msg" >/dev/null
      else notif_send info "$title" "$msg" >/dev/null; fi ;;
    ok)
      [ -f "$f" ] || return 0
      rm -f "$f"; notif_send retabli "✅ Rétabli : $title" "$msg" >/dev/null ;;
    info)
      notif_send info "$title" "$msg" >/dev/null ;;
    rapport)
      notif_send rapport "$title" "$msg" >/dev/null ;;
    evenement)
      # evenement ponctuel important (ex. secteurs realloues en hausse) : tous les canaux, sans suivi
      notif_send critique "$title" "$msg" >/dev/null ;;
    *) echo "Usage : nas-notify <critique|info|succes|ok|rapport|evenement> <tag> <titre> <message>"; return 1 ;;
  esac
  return 0
}

# Planification de la verification horaire (nas-check) : toujours en place (etat des
# destinations et des disques pour NAS Manager, alertes)
check_cron() {
  [ -f /etc/cron.d/nas-check ] && grep -q "$BIN_DIR/nas-check" /etc/cron.d/nas-check && return 0
  echo "7 * * * * root $BIN_DIR/nas-check >/dev/null 2>&1" > /etc/cron.d/nas-check
  chmod 644 /etc/cron.d/nas-check
}

# Configuration des alertes Home Assistant : adresse de Home Assistant et webhook
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
  conf_set_file "$NOTIFY_CONF" HA_URL "$url"
  conf_set_file "$NOTIFY_CONF" WEBHOOK "$wh"
  grep -q '^REPEAT_HOURS=' "$NOTIFY_CONF" || conf_set_file "$NOTIFY_CONF" REPEAT_HOURS 12
  grep -q '^QUOTA_ALERT=' "$NOTIFY_CONF" || conf_set_file "$NOTIFY_CONF" QUOTA_ALERT 90
  grep -q '^LATE_HOURS=' "$NOTIFY_CONF" || conf_set_file "$NOTIFY_CONF" LATE_HOURS 50
  check_cron
  vert "OK : verification toutes les heures (nas-check)"
  if notif_send info "NAS" "Les alertes de sauvegarde sont actives ✅" ha >/dev/null; then
    vert "Notification discrete envoyee : verifie ton telephone."
  else
    rouge "Echec de l'envoi vers Home Assistant ($url)."
  fi
  if [[ "$crit" =~ ^[oOyY]$ ]]; then
    notif_send critique "Test d'alerte" "Ceci est un test, tout va bien." ha >/dev/null && vert "Alerte critique envoyee."
  fi
}

# Description d'un canal (sans secret) pour l'application
alertes_voir() {
  (
    HA_URL="" WEBHOOK="" NTFY_URL="" NTFY_TOKEN="" TELEGRAM_TOKEN="" TELEGRAM_CHAT="" DISCORD_URL="" MAIL_TO="" SMTP_HOST="" \
    SMTP_PORT="" SMTP_USER="" SMTP_SECU="" MAIL_FROM="" REPEAT_HOURS=12 QUOTA_ALERT=90 LATE_HOURS=50 \
    HA_NIVEAU="" NTFY_NIVEAU="" TELEGRAM_NIVEAU="" DISCORD_NIVEAU="" MAIL_NIVEAU="" FREQ=non JOUR=1 HEURE=08:30 RAPPORT_CANAUX=""
    # shellcheck disable=SC1090
    [ -f "$NOTIFY_CONF" ] && . "$NOTIFY_CONF"
    # shellcheck disable=SC1090
    [ -f "$CANAUX_CONF" ] && . "$CANAUX_CONF"
    # shellcheck disable=SC1090
    [ -f "$RAPPORT_CONF" ] && . "$RAPPORT_CONF"
    export HA_URL WEBHOOK NTFY_URL NTFY_TOKEN TELEGRAM_TOKEN TELEGRAM_CHAT DISCORD_URL MAIL_TO SMTP_HOST SMTP_PORT SMTP_USER SMTP_SECU \
      MAIL_FROM REPEAT_HOURS QUOTA_ALERT LATE_HOURS HA_NIVEAU NTFY_NIVEAU TELEGRAM_NIVEAU DISCORD_NIVEAU MAIL_NIVEAU FREQ JOUR HEURE RAPPORT_CANAUX
    python3 - "$STATE_DIR/notifications.log" <<'PYV'
import json, os, re
E = lambda k: os.environ.get(k, "") or ""
def cache(u):
    return re.sub(r"//[^/@]*@", "//", u)
c = {}
if E("HA_URL") and E("WEBHOOK"):
    c["ha"] = {"cible": E("HA_URL"), "niveau": E("HA_NIVEAU") or "tout"}
if E("NTFY_URL"):
    c["ntfy"] = {"cible": cache(E("NTFY_URL")), "niveau": E("NTFY_NIVEAU") or "tout", "jeton": bool(E("NTFY_TOKEN"))}
if E("TELEGRAM_TOKEN") and E("TELEGRAM_CHAT"):
    c["telegram"] = {"cible": "conversation " + E("TELEGRAM_CHAT"), "niveau": E("TELEGRAM_NIVEAU") or "tout"}
if E("DISCORD_URL"):
    c["discord"] = {"cible": E("DISCORD_URL").split("/api/webhooks/")[0] + "/api/webhooks/…", "niveau": E("DISCORD_NIVEAU") or "tout"}
if E("MAIL_TO") and E("SMTP_HOST"):
    c["email"] = {"cible": "%s (via %s:%s)" % (E("MAIL_TO"), E("SMTP_HOST"), E("SMTP_PORT") or "?"), "niveau": E("MAIL_NIVEAU") or "critique",
                  "serveur": E("SMTP_HOST"), "port": E("SMTP_PORT"), "securite": E("SMTP_SECU") or "starttls", "utilisateur": E("SMTP_USER"),
                  "destinataire": E("MAIL_TO"), "expediteur": E("MAIL_FROM")}
last = []
try:
    last = [l.rstrip("\n") for l in open(__import__("sys").argv[1], errors="ignore").readlines()[-5:]]
except OSError:
    pass
print(json.dumps({"canaux": c, "rappel_h": int(E("REPEAT_HOURS") or 12), "quota_pct": int(E("QUOTA_ALERT") or 90),
                  "retard_h": int(E("LATE_HOURS") or 50), "erreurs": last,
                  "rapport": {"frequence": E("FREQ") or "non", "jour": int(E("JOUR") or 1), "heure": E("HEURE") or "08:30",
                              "canaux": E("RAPPORT_CANAUX").split()}}, ensure_ascii=False))
PYV
  )
}

# alertes canal <ha|ntfy|telegram|discord|email> <tout|critique>   parametres cle=valeur sur l'entree standard
alertes_canal() {
  local c="${1:-}" niv="${2:-}" line k v
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  [[ " ${CANAUX[*]} " == *" $c "* ]] || die "canal inconnu : $c (ha, ntfy, telegram, discord, email)."
  [[ -z "$niv" || "$niv" =~ ^(tout|critique)$ ]] || die "niveau invalide (tout ou critique)."
  local -A P=()
  if [ ! -t 0 ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      k="${line%%=*}"; v="${line#*=}"
      [[ "$k" =~ ^[a-z_]+$ && "$line" == *=* ]] || die "parametre invalide : $k"
      P[$k]="$v"
    done
  fi
  mkdir -p "$CONF_DIR" "$STATE_DIR/alertes"
  local -a keys=()
  case "$c" in
    ha)
      [ -n "${P[ip]:-}" ] && [ -n "${P[webhook]:-}" ] || die "adresse de Home Assistant et webhook necessaires."
      alertes_configurer "${P[ip]}" "${P[webhook]}" n
      [ -n "$niv" ] && conf_set_file "$CANAUX_CONF" HA_NIVEAU "$niv"
      return 0 ;;
    ntfy)
      [[ "${P[url]:-}" =~ ^https?://[^/]+/[A-Za-z0-9_-]{1,64}$ ]] || die "adresse ntfy invalide (ex. https://ntfy.sh/mon-sujet)."
      conf_set_file "$CANAUX_CONF" NTFY_URL "${P[url]}"
      [ -n "${P[jeton]+x}" ] && conf_set_file "$CANAUX_CONF" NTFY_TOKEN "${P[jeton]}"
      keys=(NTFY_NIVEAU) ;;
    telegram)
      [[ "${P[jeton]:-}" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "jeton du bot Telegram invalide (ex. 123456:ABC-def...)."
      [[ "${P[conversation]:-}" =~ ^-?[0-9]+$ ]] || die "identifiant de conversation Telegram invalide (un nombre)."
      conf_set_file "$CANAUX_CONF" TELEGRAM_TOKEN "${P[jeton]}"
      conf_set_file "$CANAUX_CONF" TELEGRAM_CHAT "${P[conversation]}"
      keys=(TELEGRAM_NIVEAU) ;;
    discord)
      [[ "${P[url]:-}" =~ ^https://(discord|discordapp)\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ || "${P[url]:-}" =~ ^https?://127\.0\.0\.1 ]] \
        || die "adresse de webhook Discord invalide (https://discord.com/api/webhooks/...)."
      conf_set_file "$CANAUX_CONF" DISCORD_URL "${P[url]}"
      keys=(DISCORD_NIVEAU) ;;
    email)
      [[ "${P[destinataire]:-}" =~ ^[^@\ ]+@[^@\ ]+$ ]] || die "adresse e-mail du destinataire invalide."
      [[ "${P[serveur]:-}" =~ ^[A-Za-z0-9.-]+$ ]] || die "serveur SMTP invalide."
      [[ -z "${P[port]:-}" || "${P[port]}" =~ ^[0-9]{1,5}$ ]] || die "port SMTP invalide."
      [[ "${P[securite]:-starttls}" =~ ^(starttls|ssl|aucune)$ ]] || die "securite invalide (starttls, ssl ou aucune)."
      conf_set_file "$CANAUX_CONF" MAIL_TO "${P[destinataire]}"
      conf_set_file "$CANAUX_CONF" SMTP_HOST "${P[serveur]}"
      conf_set_file "$CANAUX_CONF" SMTP_PORT "${P[port]:-}"
      conf_set_file "$CANAUX_CONF" SMTP_SECU "${P[securite]:-starttls}"
      conf_set_file "$CANAUX_CONF" SMTP_USER "${P[utilisateur]:-}"
      [ -n "${P[mot_de_passe]+x}" ] && conf_set_file "$CANAUX_CONF" SMTP_PASS "${P[mot_de_passe]}"
      conf_set_file "$CANAUX_CONF" MAIL_FROM "${P[expediteur]:-}"
      keys=(MAIL_NIVEAU) ;;
  esac
  [ -n "$niv" ] && conf_set_file "$CANAUX_CONF" "${keys[0]}" "$niv"
  check_cron
  logl "canal de notification $c configure"
  echo "== Test du canal =="
  local r; r=$(notif_send info "NAS" "Les notifications « $c » fonctionnent ✅" "$c")
  if [[ "$r" == *"|ok"* ]]; then
    vert "Canal « $c » configure : message de test envoye."
  else
    rouge "Canal « $c » enregistre, mais le test a echoue : ${r#*|}"
    return 1
  fi
}

alertes_canal_supprimer() {
  local c="${1:-}" k
  [[ " ${CANAUX[*]} " == *" $c "* ]] || die "canal inconnu : $c"
  case "$c" in
    ha)       for k in HA_URL WEBHOOK; do conf_set_file "$NOTIFY_CONF" "$k" ""; done; conf_set_file "$CANAUX_CONF" HA_NIVEAU "" ;;
    ntfy)     for k in NTFY_URL NTFY_TOKEN NTFY_NIVEAU; do conf_set_file "$CANAUX_CONF" "$k" ""; done ;;
    telegram) for k in TELEGRAM_TOKEN TELEGRAM_CHAT TELEGRAM_NIVEAU; do conf_set_file "$CANAUX_CONF" "$k" ""; done ;;
    discord)  for k in DISCORD_URL DISCORD_NIVEAU; do conf_set_file "$CANAUX_CONF" "$k" ""; done ;;
    email)    for k in MAIL_TO MAIL_FROM SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_SECU MAIL_NIVEAU; do conf_set_file "$CANAUX_CONF" "$k" ""; done ;;
  esac
  logl "canal de notification $c retire"
  vert "Canal « $c » retire."
}

# Telegram : conversations ayant ecrit au bot (pour trouver l'identifiant)
telegram_chats() {  # jeton du bot sur l'entree standard
  local tok; IFS= read -r tok || true
  [[ "$tok" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "jeton du bot Telegram invalide."
  python3 - "$tok" <<'PYT'
import json, os, sys, urllib.request
api = os.environ.get("NAS_TELEGRAM_API", "https://api.telegram.org")
try:
    with urllib.request.urlopen("%s/bot%s/getUpdates" % (api, sys.argv[1]), timeout=20) as r:
        d = json.load(r)
except Exception as e:
    print("ERREUR : Telegram refuse le jeton ou est injoignable (%s)" % e); sys.exit(1)
vus = {}
for u in d.get("result", []):
    m = u.get("message") or u.get("channel_post") or u.get("my_chat_member") or {}
    c = m.get("chat") or {}
    if "id" in c:
        vus[c["id"]] = c.get("title") or " ".join(x for x in (c.get("first_name"), c.get("last_name")) if x) or c.get("username", "")
if not vus:
    print("Aucune conversation : envoie d'abord un message a ton bot dans Telegram, puis recommence."); sys.exit(1)
for k, v in vus.items():
    print("%s|%s" % (k, v))
PYT
}

alertes_seuils() {  # alertes_seuils <rappel h> <espace %> <retard h>
  [[ "${1:-}" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 168 ]] || die "rappel invalide (1 a 168 heures)."
  [[ "${2:-}" =~ ^[0-9]+$ && "$2" -ge 50 && "$2" -le 100 ]] || die "seuil d'espace invalide (50 a 100 %)."
  [[ "${3:-}" =~ ^[0-9]+$ && "$3" -ge 6 ]] || die "retard invalide (6 heures au moins)."
  conf_set_file "$NOTIFY_CONF" REPEAT_HOURS "$1"; conf_set_file "$NOTIFY_CONF" QUOTA_ALERT "$2"; conf_set_file "$NOTIFY_CONF" LATE_HOURS "$3"
  vert "Reglages des alertes enregistres."
}

alertes_main() {
  case "${1:-}" in
    configurer) alertes_configurer "${2:-}" "${3:-}" "${4:-n}" ;;
    voir)       alertes_voir ;;
    canal)      alertes_canal "${2:-}" "${3:-}" ;;
    retirer)    alertes_canal_supprimer "${2:-}" ;;
    tester)     notif_send info "NAS" "Test depuis NAS Manager ✅" "${2:-}"; local rc=$?; [ $rc -eq 0 ] || echo "Aucun envoi n'a reussi."; return $rc ;;
    telegram)   telegram_chats ;;
    niveau)     # niveau <canal> <tout|critique>
      [[ " ${CANAUX[*]} " == *" ${2:-} "* ]] || die "canal inconnu : ${2:-}"
      [[ "${3:-}" =~ ^(tout|critique)$ ]] || die "niveau invalide (tout ou critique)."
      canaux_actifs | grep -qx "$2" || die "canal « $2 » non configure."
      local kn; kn="$(echo "$2" | tr '[:lower:]' '[:upper:]')_NIVEAU"; [ "$2" = email ] && kn=MAIL_NIVEAU
      conf_set_file "$CANAUX_CONF" "$kn" "$3"
      vert "Canal « $2 » : $( [ "$3" = tout ] && echo "toutes les notifications" || echo "alertes seulement")." ;;
    seuils)     alertes_seuils "${2:-}" "${3:-}" "${4:-}" ;;
    *) die "usage : nas-debian alertes configurer | voir | canal <canal> [niveau] | niveau <canal> <tout|critique> | retirer <canal> | tester [canal] | telegram | seuils" ;;
  esac
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

  # 1 bis. Sauvegardes temps reel : surveillance active, pas de pause
  local rn
  for rn in $(rt_names); do
    rt_get "$rn" || continue
    if rt_paused; then
      $N critique "rt-pause-$rn" "Sauvegarde temps réel « $rn » en pause" "$(cut -d'|' -f2- "$STATE_DIR/rt-$rn.pause"). Reprends-la depuis NAS Manager une fois le dossier vérifié."
    elif has_systemd && ! systemctl is-enabled --quiet "nas-temps-reel@$rn" 2>/dev/null; then
      :   # arretee volontairement
    elif rt_active "$rn"; then
      $N ok "rt-service-$rn" "Sauvegarde temps réel « $rn »" "La surveillance fonctionne de nouveau."
    else
      $N critique "rt-service-$rn" "Sauvegarde temps réel « $rn » arrêtée" "La surveillance de ${R_DIRS//;/, } ne tourne plus. Redémarre-la depuis NAS Manager (page Sauvegardes temps réel)."
    fi
  done

  # 2. Destinations : connexion et espace (Google Drive : aussi dans health.json, comme avant)
  local GD=false pct="" used_go="" total_go="" d q
  if command -v rclone >/dev/null; then
    for d in $(dest_list 2>/dev/null | python3 -c 'import json,sys; print(" ".join(x["nom"] for x in json.load(sys.stdin)))' 2>/dev/null); do
      local tg="dest-$d" tq="quota-$d" lab="Destination « $d »"
      [ "$d" = "$GDRIVE" ] && { tg=gdrive; tq=quota; lab="Google Drive"; }
      if dest_check "$d"; then
        [ "$d" = "$GDRIVE" ] && GD=true
        $N ok "$tg" "$lab" "La connexion fonctionne de nouveau."
        local u t
        read -r q u t < <(python3 -c '
import json, sys
try:
    e = json.load(open(sys.argv[1]))[sys.argv[2]]
    t, u = e.get("total") or 0, e.get("utilise") or 0
    print(int(u * 100 / t) if t else "-", round(u / 1e9, 1), round(t / 1e9, 1))
except Exception:
    print("-", "", "")' "$DEST_JSON" "$d")
        [ "$d" = "$GDRIVE" ] && { used_go="$u"; total_go="$t"; }
        if [ "$q" != "-" ]; then
          [ "$d" = "$GDRIVE" ] && pct="$q"
          if [ "$q" -ge "${QUOTA_ALERT:-90}" ]; then
            $N critique "$tq" "$lab presque plein" "Espace utilisé : ${q} %. Les prochaines sauvegardes risquent d'échouer."
          else
            $N ok "$tq" "$lab" "Espace utilisé : ${q} %."
          fi
        fi
      elif [ "$d" = "$GDRIVE" ]; then
        $N critique gdrive "Google Drive inaccessible" "rclone n'arrive plus à se connecter à Google Drive. Reconnecte-le depuis NAS Manager (page Destinations)."
      else
        $N critique "$tg" "$lab inaccessible" "$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))[sys.argv[2]].get("erreur", ""))
except Exception: print("")' "$DEST_JSON" "$d" | cut -c1-200) Disque débranché, NAS éteint ou autorisation expirée ? Voir NAS Manager (page Destinations)."
      fi
    done
  fi
  [ "$GD" = true ] || { used_go=""; total_go=""; }

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

  # 4. Entretien : nouvelle version de rclone et de restic (une fois par jour)
  outils_rclone_derniere >/dev/null 2>&1
  outils_restic_derniere >/dev/null 2>&1

  # 4 bis. Sante des disques (SMART, RAID) : alerte avant la panne
  disques_verifier

  # 5. Etat pour le tableau de bord Home Assistant
  python3 -c '
import json,sys
from datetime import datetime
gd,pct,u,t,out,conf=sys.argv[1:7]
num=lambda x:(float(x) if x else None)
json.dump({"gdrive":gd=="true","quota_pct":int(num(pct)) if pct else None,"used_go":num(u),"total_go":num(t),
           "gdrive_configure":conf=="1","checked":datetime.now().astimezone().isoformat(timespec="seconds")},open(out,"w"))
' "$GD" "$pct" "$used_go" "$total_go" "$STATE_DIR/health.json" "$(remote_exists "$GDRIVE" && echo 1 || echo 0)"
  espace_releve
  ha_status
  return 0
}

# =========================== Sante des disques =======================
# Sante des disques (SMART) et des grappes RAID (mdadm, ZFS) -> JSON + lignes d'alerte :
#   ALERTE|tag|titre|message   probleme durable (disque critique, RAID degrade)
#   OK|tag|titre|message       plus de probleme pour ce tag
#   EVENEMENT|titre|message    evenement ponctuel (secteurs realloues en hausse, nouvelle anomalie...)
# Les disques en veille ne sont pas reveilles (smartctl -n standby) : leurs dernieres valeurs sont gardees.
disk_health_py() {  # disk_health_py <fichier json> <smartctl> <nom de la machine>
  python3 - "$1" "$2" "$3" <<'PYDISK'
import glob, json, os, re, subprocess, sys, time
out_path, smart, host = sys.argv[1], sys.argv[2], sys.argv[3]
MDSTAT = os.environ.get("NAS_MDSTAT", "/proc/mdstat")
try:
    prev = json.load(open(out_path))
except (OSError, ValueError):
    prev = {}
prevd = {(d.get("serie") or d.get("dev")): d for d in prev.get("disques", [])}
lines = []

def run(args, t=90):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=t)
        return p.returncode, p.stdout + p.stderr
    except Exception:
        return -1, ""

def scan():
    devs = []
    if smart:
        _, o = run([smart, "--scan"])
        for l in o.splitlines():
            m = re.match(r"^(/dev/\S+)\s+-d\s+(\S+)", l)
            if m and m.group(1) not in [d[0] for d in devs]:
                devs.append((m.group(1), m.group(2)))
    if not devs:
        for p in sorted(glob.glob("/dev/sd[a-z]") + glob.glob("/dev/sata[0-9]*") + glob.glob("/dev/nvme[0-9]n1")):
            if re.match(r"^/dev/(sd[a-z]|sata\d+|nvme\d+n1)$", p):
                devs.append((p, ""))
    return devs

def num(x):
    try:
        return int(str(x).replace(",", "").split()[0])
    except (ValueError, IndexError, TypeError):
        return None

def from_json(j):
    d = {"modele": j.get("model_name") or j.get("model_family") or "", "serie": j.get("serial_number", ""),
         "taille": (j.get("user_capacity") or {}).get("bytes") or j.get("nvme_total_capacity")}
    proto = (j.get("device") or {}).get("protocol", "")
    d["type"] = "nvme" if proto == "NVMe" else ("ssd" if j.get("rotation_rate") == 0 else "hdd")
    st = j.get("smart_status") or {}
    d["smart_ok"] = st.get("passed")
    d["temp"] = (j.get("temperature") or {}).get("current")
    d["heures"] = (j.get("power_on_time") or {}).get("hours")
    tab = (j.get("ata_smart_attributes") or {}).get("table", [])
    raw = {a.get("id"): (a.get("raw") or {}).get("value") for a in tab}
    norm = {a.get("id"): a.get("value") for a in tab}
    d.update(realloues=raw.get(5), en_attente=raw.get(197), irreparables=raw.get(198), crc=raw.get(199), non_corriges=raw.get(187))
    nv = j.get("nvme_smart_health_information_log")
    if nv:
        d.update(usure=nv.get("percentage_used"), alerte_nvme=nv.get("critical_warning"), erreurs_media=nv.get("media_errors"),
                 reserve=nv.get("available_spare"), reserve_seuil=nv.get("available_spare_threshold"))
        if d["temp"] is None:
            d["temp"] = nv.get("temperature")
        if d["heures"] is None:
            d["heures"] = nv.get("power_on_hours")
    elif d["type"] == "ssd":
        for i in (177, 231, 233, 202):        # usure des SSD SATA (selon les marques)
            if norm.get(i) is not None and 0 < norm[i] <= 100:
                d["usure"] = 100 - norm[i]
                break
    return d

def from_text(t):
    g = lambda rx: (lambda m: m.group(1).strip() if m else None)(re.search(rx, t, re.M))
    d = {"modele": g(r"^(?:Device Model|Model Number|Product):\s*(.+)$") or "", "serie": g(r"^Serial [Nn]umber:\s*(.+)$") or ""}
    cap = g(r"^(?:User Capacity|Total NVM Capacity|Namespace 1 Size/Capacity):\s*([\d,.\s]+) bytes")
    d["taille"] = num(re.sub(r"[^\d]", "", cap)) if cap else None
    h = g(r"SMART overall-health self-assessment test result:\s*(\S+)") or g(r"SMART Health Status:\s*(\S+)")
    d["smart_ok"] = None if h is None else h.upper() in ("PASSED", "OK")
    rot = g(r"^Rotation Rate:\s*(.+)$")
    nvme = bool(re.search(r"^(NVMe Version|PCI Vendor/Subsystem ID)", t, re.M))
    d["type"] = "nvme" if nvme else ("ssd" if rot and "Solid State" in rot else "hdd")
    attrs = {}
    for m in re.finditer(r"^\s*(\d{1,3})\s+\S+\s+0x[0-9a-fA-F]+\s+(\d+)\s+\d+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\d+)", t, re.M):
        attrs[int(m.group(1))] = (int(m.group(2)), int(m.group(3)))
    raw = lambda i: attrs[i][1] if i in attrs else None
    d.update(realloues=raw(5), en_attente=raw(197), irreparables=raw(198), crc=raw(199), non_corriges=raw(187))
    tmp = num(g(r"^(?:Temperature|Current Drive Temperature):\s*(\d+)")) or raw(194) or raw(190)
    d["temp"] = tmp if tmp is not None and tmp < 120 else None
    d["heures"] = raw(9) if raw(9) is not None else num(g(r"^Power On Hours:\s*([\d,]+)"))
    if nvme:
        d.update(usure=num(g(r"^Percentage Used:\s*(\d+)%")), alerte_nvme=(lambda v: int(v, 16) if v else None)(g(r"^Critical Warning:\s*(0x[0-9a-fA-F]+)")),
                 erreurs_media=num(g(r"^Media and Data Integrity Errors:\s*([\d,]+)")), reserve=num(g(r"^Available Spare:\s*(\d+)%")),
                 reserve_seuil=num(g(r"^Available Spare Threshold:\s*(\d+)%")))
    elif d["type"] == "ssd":
        for i in (177, 231, 233, 202):
            if i in attrs and 0 < attrs[i][0] <= 100:
                d["usure"] = 100 - attrs[i][0]
                break
    return d

def read_disk(dev, typ):
    base = [smart] + (["-d", typ] if typ else [])
    rc, o = run(base + ["-a", "-j", "-n", "standby", dev])
    j = None
    if o.lstrip().startswith("{"):
        try:
            j = json.loads(o)
        except ValueError:
            j = None
    if j is not None:
        msgs = " ".join(m.get("string", "") for m in (j.get("smartctl") or {}).get("messages", []))
        if "STANDBY" in msgs.upper() or "SLEEP" in msgs.upper():
            return "veille"
        if not j.get("serial_number") and not j.get("model_name") and rc & 2:
            return None
        return from_json(j)
    rc, o = run(base + ["-a", "-n", "standby", dev])
    if re.search(r"STANDBY|SLEEP", o) and "SMART" not in o[200:]:
        return "veille"
    if "Serial" not in o and "Model" not in o:
        return None
    return from_text(o)

def evaluate(d, p):
    crit, att, ev = [], [], []
    if d.get("smart_ok") is False:
        crit.append("test SMART en échec : le disque annonce sa panne, remplace-le")
    if d.get("en_attente"):
        crit.append("%d secteur(s) instable(s) en attente de réallocation" % d["en_attente"])
    if d.get("irreparables"):
        crit.append("%d secteur(s) illisible(s)" % d["irreparables"])
    r, pr = d.get("realloues") or 0, (p or {}).get("realloues") or 0
    if r:
        att.append("%d secteur(s) réalloué(s)" % r)
        if p and r > pr:
            ev.append("secteurs réalloués en hausse : %d (avant : %d). Signe d'usure : vérifie les sauvegardes et prévois le remplacement." % (r, pr))
    if d.get("non_corriges"):
        att.append("%d erreur(s) non corrigée(s)" % d["non_corriges"])
    c, pc = d.get("crc") or 0, (p or {}).get("crc") or 0
    if p and c > pc:
        ev.append("erreurs de transmission en hausse (%d) : câble SATA ou connecteur à vérifier." % c)
    if d.get("alerte_nvme"):
        crit.append("le SSD signale un problème (avertissement critique %d)" % d["alerte_nvme"])
    if d.get("reserve") is not None and d.get("reserve_seuil") is not None and d["reserve"] <= d["reserve_seuil"]:
        crit.append("réserve du SSD épuisée (%d %%)" % d["reserve"])
    u = d.get("usure")
    if u is not None and u >= 100:
        crit.append("SSD usé (%d %%)" % u)
    elif u is not None and u >= 80:
        att.append("SSD usé à %d %%" % u)
    if d.get("erreurs_media"):
        att.append("%d erreur(s) d'intégrité des données" % d["erreurs_media"])
    t = d.get("temp")
    hot = (60, 50) if d.get("type") == "hdd" else (75, 65)
    if t is not None and t >= hot[0]:
        crit.append("température élevée : %d °C (ventilation ?)" % t)
    elif t is not None and t >= hot[1]:
        att.append("température : %d °C" % t)
    d["etat"] = "critique" if crit else ("attention" if att else "ok")
    d["raisons"] = crit + att
    return ev

def nom(d):
    return "%s (%s%s)" % (d["dev"], d.get("modele") or "disque", ", n° " + d["serie"] if d.get("serie") else "")

disques = []
present = bool(smart)
for dev, typ in (scan() if present else []):
    r = read_disk(dev, typ)
    if r is None:
        continue
    key_prev = None
    if r == "veille":
        p = next((x for x in prevd.values() if x.get("dev") == dev), None)
        if not p:
            disques.append({"dev": dev, "veille": True, "etat": "inconnu", "raisons": []})
            continue
        d = dict(p); d["veille"] = True
        disques.append(d)
        continue
    d = r; d["dev"] = dev; d["veille"] = False
    p = prevd.get(d.get("serie") or dev)
    for e in evaluate(d, p):
        lines.append("EVENEMENT|Disque %s : à surveiller|%s" % (d["dev"], e))
    tag = "disque-" + re.sub(r"[^A-Za-z0-9_-]", "_", d.get("serie") or dev.split("/")[-1])[:40]
    d["tag"] = tag
    if d["etat"] == "critique":
        lines.append("ALERTE|%s|Disque %s en danger|%s : %s. Vérifie les sauvegardes et prévois de remplacer le disque." % (tag, d["dev"], nom(d), " ; ".join(d["raisons"])))
    else:
        lines.append("OK|%s|Disque %s|Le disque %s ne signale plus de problème grave." % (tag, d["dev"], nom(d)))
        norm = lambda v: {re.sub(r"\d+", "#", x) for x in v}
        if d["etat"] == "attention" and norm(d["raisons"]) - norm((p or {}).get("raisons", [])) and not any(l.startswith("EVENEMENT|Disque %s " % d["dev"]) for l in lines):
            lines.append("EVENEMENT|Disque %s : à surveiller|%s : %s." % (d["dev"], nom(d), " ; ".join(d["raisons"])))
    disques.append(d)

# grappes RAID logicielles (mdadm)
raid = []
try:
    t = open(MDSTAT).read()
except OSError:
    t = ""
for b in re.split(r"\n(?=md\d+\s*:)", t):
    m = re.match(r"(md\d+)\s*:\s*(\S+)\s+(?:\((?:auto-)?read-only\)\s+)?(raid\d+|linear)?\s*([^\n]*)", b)
    if not m:
        continue
    name, active, level, rest = m.groups()
    members = re.findall(r"(\w+)\[\d+\](\([FS]\))?", rest)
    st = re.search(r"\[(\d+)/(\d+)\]\s*\[([U_]+)\]", b)
    etat, pct = "ok", None
    if active not in ("active", "active-idle"):
        etat = "arrete"
    if (st and (int(st.group(2)) < int(st.group(1)) or "_" in st.group(3))) or any(f == "(F)" for _, f in members):
        etat = "degrade"
    pr = re.search(r"(recovery|resync|reshape|check)\s*=\s*([\d.]+)%", b)
    if pr:
        pct = float(pr.group(2))
        if pr.group(1) in ("recovery", "reshape"):
            etat = "reconstruction" if etat != "arrete" else etat
    raid.append({"nom": name, "type": level or "", "etat": etat, "disques": [x for x, _ in members],
                 "en_panne": [x for x, f in members if f == "(F)"], "avancement": pct, "operation": pr.group(1) if pr else None})
# pools ZFS
if subprocess.run(["sh", "-c", "command -v zpool >/dev/null"]).returncode == 0:
    _, o = run(["zpool", "list", "-H", "-o", "name,health"])
    for l in o.splitlines():
        p = l.split("\t")
        if len(p) == 2:
            raid.append({"nom": p[0], "type": "zfs", "etat": "ok" if p[1] == "ONLINE" else "degrade", "disques": [], "en_panne": [],
                         "avancement": None, "operation": None})
prevr = {x["nom"]: x for x in prev.get("raid", [])}
for a in raid:
    tag = "raid-" + a["nom"]
    if a["etat"] in ("degrade", "reconstruction", "arrete"):
        extra = " (reconstruction : %.0f %%)" % a["avancement"] if a.get("avancement") is not None and a["etat"] == "reconstruction" else ""
        lines.append("ALERTE|%s|RAID %s dégradé|La grappe %s (%s) fonctionne sans redondance%s%s. Un disque de plus en panne = données perdues : remplace le disque en défaut au plus vite." % (
            tag, a["nom"], a["nom"], a["type"], extra, (" ; disque(s) en panne : " + ", ".join(a["en_panne"])) if a["en_panne"] else ""))
    else:
        lines.append("OK|%s|RAID %s|La grappe %s est de nouveau complète." % (tag, a["nom"], a["nom"]))
    pa = prevr.get(a["nom"])
    if a["etat"] == "reconstruction" and (not pa or pa.get("etat") != "reconstruction"):
        lines.append("EVENEMENT|RAID %s : reconstruction en cours|La grappe %s se reconstruit (%.0f %%). Évite d'arrêter le NAS d'ici la fin." % (a["nom"], a["nom"], a.get("avancement") or 0))

for gone in set(prevr) - {a["nom"] for a in raid}:   # grappe supprimee : son alerte est levee
    lines.append("OK|raid-%s|RAID %s|La grappe %s n'existe plus." % (gone, gone, gone))
res = {"verifie": int(time.time()), "machine": host, "smart": present, "disques": disques, "raid": raid}
tmp = out_path + ".new"
json.dump(res, open(tmp, "w"), ensure_ascii=False)
os.replace(tmp, out_path)
print("\n".join(lines))
PYDISK
}

DISQUES_JSON="$STATE_DIR/disques.json"

smartctl_bin() { command -v smartctl 2>/dev/null || { [ -x /usr/sbin/smartctl ] && echo /usr/sbin/smartctl; } || true; }

# Verification de la sante des disques et du RAID, alertes (appelee par nas-check chaque heure)
disques_verifier() {
  mkdir -p "$STATE_DIR"
  exec 4>"/run/nas-disques.lock"
  flock -w 120 4 || return 0
  local kind a b c
  while IFS='|' read -r kind a b c; do
    case "$kind" in
      ALERTE)    notify critique "$a" "$b" "$c" ;;
      OK)        notify ok "$a" "$b" "$c" ;;
      EVENEMENT) notify evenement disques "$a" "$b" ;;
    esac
  done < <(disk_health_py "$DISQUES_JSON" "$(smartctl_bin)" "$(hostname -s 2>/dev/null)")
  exec 4>&-
  return 0
}

disques_main() {
  case "${1:-etat}" in
    verifier) [ "$(id -u)" -eq 0 ] || die "lance ce script en root."; disques_verifier; cat "$DISQUES_JSON" ;;
    etat)     cat "$DISQUES_JSON" 2>/dev/null || echo '{}' ;;
    *) die "usage : nas-debian disques verifier | etat" ;;
  esac
}

# =========================== Rapport periodique ======================
# Resume de la semaine ou du mois (sauvegardes, temps reel, destinations, espace, disques,
# alertes, kit de secours), envoye par les canaux de notification.
# /etc/nas-backup/rapport.conf : FREQ (hebdo, mensuel, non), JOUR (1 = lundi), HEURE, RAPPORT_CANAUX
rapport_texte() {  # rapport_texte <hebdo|mensuel> -> titre (1re ligne) puis le rapport
  python3 - "${1:-hebdo}" "$(hostname -s 2>/dev/null)" "$STATE_DIR" "$JOBS" "$RT_CONF" <<'PYR'
import json, os, re, sys, time
period, host, S, JOBS, RT = sys.argv[1:6]
days = 30 if period == "mensuel" else 7
now = time.time()
t0 = now - days * 86400

def hs(b):
    b = float(b or 0)
    for u in ("o", "Ko", "Mo", "Go", "To"):
        if b < 1024 or u == "To":
            return ("%d %s" % (b, u)) if u == "o" else ("%.1f %s" % (b, u)).replace(".", ",")
        b /= 1024

def ago(ts):
    d = max(0, now - ts)
    if d < 3600:
        return "il y a %d min" % (d // 60)
    if d < 86400:
        return "il y a %d h" % (d // 3600)
    return "il y a %d j" % (d // 86400)

def jsonl(p):
    out = []
    try:
        for l in open(p, errors="ignore"):
            try:
                out.append(json.loads(l))
            except ValueError:
                pass
    except OSError:
        pass
    return out

def rd(p):
    try:
        return json.load(open(p))
    except Exception:
        return None

def lines(p):
    try:
        return [l.rstrip("\n") for l in open(p) if l.strip() and not l.startswith("#")]
    except OSError:
        return []

L, pb = [], [0]
def bad(n=1):
    pb[0] += n

# ---- sauvegardes programmees
jobs = [l.split("|") for l in lines(JOBS) if len(l.split("|")) >= 7]
runs = [r for r in jsonl(S + "/historique.jsonl") if (r.get("fin") or 0) >= t0]
if jobs:
    ok = sum(1 for r in runs if r.get("etat") == "OK")
    ko = sum(1 for r in runs if r.get("etat") == "ECHEC")
    L.append("SAUVEGARDES PROGRAMMÉES : %d exécution(s), %d réussie(s), %d en échec, %s envoyés"
             % (len(runs), ok, ko, hs(sum(r.get("volume_octets", 0) or 0 for r in runs))))
    for p in jobs:
        n, sched = p[0], p[5]
        rr = [r for r in runs if r.get("nom") == n]
        if not rr:
            if sched != "manuel":
                bad()
                L.append("  ⚠ %s : aucune exécution sur la période" % n)
            else:
                L.append("  · %s : manuelle, pas lancée" % n)
            continue
        k = sum(1 for r in rr if r.get("etat") == "ECHEC")
        last = max(rr, key=lambda r: r.get("fin", 0))
        ver = (", %s version(s)" % last["versions"]) if last.get("versions") is not None else ""
        if k:
            bad()
            err = (" — " + last["erreur"][:140]) if last.get("erreur") and last.get("etat") != "OK" else ""
            L.append("  ✗ %s : %d échec(s) sur %d, dernière : %s%s" % (n, k, len(rr), "OK" if last.get("etat") == "OK" else "ÉCHEC", err))
        else:
            L.append("  ✓ %s : %d/%d OK, %s envoyés%s, dernière %s"
                     % (n, len(rr), len(rr), hs(sum(r.get("volume_octets", 0) or 0 for r in rr)), ver, ago(last.get("fin", now))))

# ---- temps reel
rts = [l.split("|")[0] for l in lines(RT)]
if rts:
    L.append("")
    L.append("TEMPS RÉEL :")
    for n in rts:
        env = vol = ech = 0
        oldest = now
        for f in ("%s/rt-%s.transferts.log.1" % (S, n), "%s/rt-%s.transferts.log" % (S, n)):
            try:
                for l in open(f, errors="ignore"):
                    q = l.strip().split("|")
                    if len(q) < 4 or not q[0].isdigit():
                        continue
                    ts = int(q[0])
                    oldest = min(oldest, ts)
                    if ts < t0:
                        continue
                    nb = int(q[4]) if len(q) > 4 and q[4].isdigit() else 1
                    if q[3] != "ok":
                        ech += 1
                    elif q[1] == "envoi":
                        env += nb
                        vol += int(q[2]) if q[2].isdigit() else 0
            except OSError:
                pass
        pause = os.path.exists("%s/rt-%s.pause" % (S, n))
        if pause or ech:
            bad()
        part = (" (journaux depuis le %s)" % time.strftime("%d/%m", time.localtime(oldest))) if oldest > t0 + 86400 else ""
        L.append("  %s %s : %d envoi(s), %s%s%s%s" % ("✗" if pause or ech else "✓", n, env, hs(vol),
                                                  (", %d échec(s)" % ech) if ech else "", part, " — EN PAUSE" if pause else ""))

# ---- destinations
de = rd(S + "/destinations.json") or {}
if de:
    L.append("")
    L.append("DESTINATIONS :")
    for n, e in sorted(de.items()):
        if not e.get("ok"):
            bad()
            L.append("  ✗ %s : injoignable (%s)" % (n, (e.get("erreur") or "?")[:120]))
            continue
        t, u = e.get("total"), e.get("utilise")
        L.append("  ✓ %s : joignable%s" % (n, (", %d %% utilisé (%s sur %s)" % (u * 100 // t, hs(u), hs(t))) if t and u is not None else ""))

# ---- evolution de l'espace
pts = [p for p in jsonl(S + "/espace.jsonl") if p.get("t", 0) >= t0]
esp = []
if len(pts) >= 2:
    a, b = pts[0], pts[-1]
    span = max(1, (b["t"] - a["t"]) / 86400)
    if a.get("drive_go") is not None and b.get("drive_go") is not None:
        dg = b["drive_go"] - a["drive_go"]
        t = ("  Google Drive : %+.1f Go sur la période" % dg).replace(".", ",")
        if dg > 0 and b.get("drive_total_go"):
            rest = (b["drive_total_go"] - b["drive_go"]) / (dg / span)
            if rest < 3650:
                t += ", plein dans environ %d jours au rythme actuel" % rest
        esp.append(t)
    for d in b.get("disques", []):
        da = next((x for x in a.get("disques", []) if x.get("p") == d.get("p")), None)
        if d.get("s"):
            nm = re.sub(r"^/srv/dev-disk-by-(uuid|label)-([^/]{0,8})[^/]*", r"disque \2…", d["p"])
            pct = d["u"] * 100 // d["s"]
            if pct >= 90:
                bad()
            esp.append(("  %s : %d %% utilisé%s" % (nm, pct, (" (%+.1f Go)" % ((d["u"] - da["u"]) / 1e9)) if da else "")).replace(".", ","))
if esp:
    L.append("")
    L.append("ESPACE :")
    L.extend(esp)

# ---- disques
dk = rd(S + "/disques.json") or {}
if dk.get("disques") or dk.get("raid"):
    L.append("")
    L.append("DISQUES :")
    ds = dk.get("disques", [])
    pbs = [d for d in ds if d.get("etat") in ("critique", "attention")]
    temps = [d["temp"] for d in ds if d.get("temp") is not None]
    if not pbs:
        L.append("  ✓ %d disque(s) en bon état%s" % (len(ds), (", %d à %d °C" % (min(temps), max(temps))) if temps else ""))
    for d in pbs:
        bad(1 if d["etat"] == "critique" else 0)
        L.append("  %s %s (%s) : %s" % ("✗" if d["etat"] == "critique" else "⚠", d.get("dev"), d.get("modele", ""), " ; ".join(d.get("raisons", []))))
    for a in dk.get("raid", []):
        if a["etat"] != "ok":
            bad()
        st = {"ok": "complet", "degrade": "DÉGRADÉ", "arrete": "ARRÊTÉ",
              "reconstruction": "reconstruction %.0f %%" % (a.get("avancement") or 0)}.get(a["etat"], a["etat"])
        L.append("  %s RAID %s (%s) : %s" % ("✓" if a["etat"] == "ok" else "✗", a["nom"], a.get("type", ""), st))
elif dk and not dk.get("smart"):
    L.append("")
    L.append("DISQUES : smartmontools absent (NAS Manager > Installation > Outils)")

# ---- alertes en cours
al = sorted(os.listdir(S + "/alertes")) if os.path.isdir(S + "/alertes") else []
if al:
    L.append("")
    L.append("ALERTES EN COURS (%d) : %s" % (len(al), ", ".join(al)))

# ---- kit de secours
ks = rd(S + "/secours/secours.json") or {}
try:
    cree = int(open(S + "/secours/cree").read().strip())
except (OSError, ValueError):
    cree = 0
L.append("")
if cree:
    okd = [n for n, e in ks.get("destinations", {}).items() if e.get("ok")]
    kod = [n for n, e in ks.get("destinations", {}).items() if not e.get("ok")]
    if kod:
        bad()
    L.append("KIT DE SECOURS : à jour du %s, envoyé vers %s%s" % (time.strftime("%d/%m/%Y", time.localtime(cree)), ", ".join(okd) or "aucune destination",
                                                             (" — échec vers " + ", ".join(kod)) if kod else ""))
elif jobs or rts:
    L.append("KIT DE SECOURS : pas encore créé")

head = "Tout va bien." if pb[0] == 0 else "%d point(s) à vérifier." % pb[0]
print(("Rapport de la semaine" if days == 7 else "Rapport du mois") + " — NAS " + host)
print("Du %s au %s : %s" % (time.strftime("%d/%m", time.localtime(t0)), time.strftime("%d/%m/%Y", time.localtime(now)), head))
print("")
print("\n".join(L))
PYR
}

rapport_main() {
  case "${1:-voir}" in
    voir)    rapport_texte "${2:-hebdo}" ;;
    envoyer)
      local t title
      t=$(rapport_texte "${2:-hebdo}") || die "rapport impossible."
      title=$(echo "$t" | head -n 1)
      printf '%s\n' "$t" > "$STATE_DIR/rapport.txt"
      if [ -z "$(canaux_actifs)" ]; then die "aucun canal de notification : configure-en un (NAS Manager, page Alertes)."; fi
      local r; r=$(notif_send rapport "$title" "$(echo "$t" | tail -n +2)")
      logl "rapport ${2:-hebdo} envoye ($(echo "$r" | tr '\n' ' '))"
      if [[ "$r" == *"|ok"* ]]; then vert "Rapport envoye : $(echo "$r" | grep '|ok' | cut -d'|' -f1 | paste -sd, -)"; else rouge "Envoi du rapport en echec : $r"; return 1; fi ;;
    planifier)  # planifier <hebdo|mensuel|non> [jour 1-7] [HH:MM] [canaux...]
      [[ "${2:-}" =~ ^(hebdo|mensuel|non)$ ]] || die "frequence invalide (hebdo, mensuel ou non)."
      [[ -z "${3:-}" || "$3" =~ ^[1-7]$ ]] || die "jour invalide (1 = lundi ... 7 = dimanche)."
      [[ -z "${4:-}" || "$4" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "heure invalide (HH:MM)."
      local c; for c in "${@:5}"; do [[ " ${CANAUX[*]} " == *" $c "* ]] || die "canal inconnu : $c"; done
      conf_set_file "$RAPPORT_CONF" FREQ "$2"
      conf_set_file "$RAPPORT_CONF" JOUR "${3:-1}"
      conf_set_file "$RAPPORT_CONF" HEURE "${4:-08:30}"
      conf_set_file "$RAPPORT_CONF" RAPPORT_CANAUX "${*:5}"
      gen_cron
      if [ "$2" = non ]; then vert "Rapport periodique desactive."; else vert "Rapport $2 planifie (${4:-08:30})."; fi ;;
    *) die "usage : nas-debian rapport voir | envoyer [hebdo|mensuel] | planifier <hebdo|mensuel|non> [jour] [HH:MM] [canaux...]" ;;
  esac
}

# Releve de l'espace (Drive, disques) pour le rapport et l'historique : un point toutes les 6 h
espace_releve() {
  python3 - "$STATE_DIR" "$(data_roots | paste -sd'|' -)" <<'PYE' 2>/dev/null
import json, os, subprocess, sys, time
S, roots = sys.argv[1], [r for r in sys.argv[2].split("|") if r]
E = S + "/espace.jsonl"
last = 0
try:
    with open(E, "rb") as f:
        f.seek(0, 2); f.seek(max(0, f.tell() - 4000))
        ls = f.read().decode(errors="ignore").splitlines()
        last = json.loads(ls[-1]).get("t", 0) if ls else 0
except (OSError, ValueError, IndexError):
    pass
if time.time() - last < 6 * 3600:
    sys.exit(0)
try:
    h = json.load(open(S + "/health.json"))
except Exception:
    h = {}
dk, vus = [], set()
if roots:
    o = subprocess.run(["df", "-B1", "--output=target,size,used"] + roots, capture_output=True, text=True).stdout.splitlines()[1:]
    for l in o:
        p = l.rsplit(None, 2)
        if len(p) == 3 and p[0] not in vus:
            vus.add(p[0]); dk.append({"p": p[0], "u": int(p[2]), "s": int(p[1])})
with open(E, "a") as f:
    f.write(json.dumps({"t": int(time.time()), "drive_go": h.get("used_go"), "drive_total_go": h.get("total_go"), "disques": dk}) + "\n")
with open(E) as f:
    al = f.readlines()
if len(al) > 1500:
    with open(E, "w") as f:
        f.writelines(al[-1500:])
PYE
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
            "destination": (", ".join(d.split(":")[0] + (" (chiffré)" if d.endswith(":oui") else "")
                                      for d in (p[9] if len(p) > 9 and p[9] else "gdrive:" + enc).split(";") if d) + " : " + sub),
            "mode": {"sync": "miroir", "copy": "copie", "versions": "versions"}.get(mode, mode),
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

def tr_stats(base):
    """Synthese d'un journal de transferts (epoch|action|octets|ok|nb) sur 7 jours."""
    st = {"jour": 0, "jour_o": 0, "heure": 0, "heure_o": 0, "sem": 0, "sem_o": 0,
          "suppr": 0, "echecs": 0, "dernier": None, "dernier_echec": None}
    for path in (base + ".1", base):
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
                            st["echecs"] += 1
                        st["dernier_echec"] = max(st["dernier_echec"] or 0, ts)
                        continue
                    if action == "envoi":
                        st["sem"] += nb; st["sem_o"] += size
                        st["dernier"] = max(st["dernier"] or 0, ts)
                        if ts >= MIDNIGHT:
                            st["jour"] += nb; st["jour_o"] += size
                        if ts >= NOW - 3600:
                            st["heure"] += nb; st["heure_o"] += size
                    elif action in ("suppression", "corbeille") and ts >= MIDNIGHT:
                        st["suppr"] += nb
        except OSError:
            pass
    return st


def conf_val(path, key):
    for l in read(path).splitlines():
        if l.startswith(key + "="):
            return l.split("=", 1)[1].strip().strip("'\"")
    return ""


def active(unit):
    return subprocess.run(["systemctl", "is-active", "--quiet", unit], stderr=subprocess.DEVNULL).returncode == 0


def enabled(unit):
    return subprocess.run(["systemctl", "is-enabled", "--quiet", unit], stderr=subprocess.DEVNULL).returncode == 0


# Sauvegardes temps reel
CAM_JOB = conf_val("/etc/nas-backup/agent.conf", "CAM_JOB")
rt, rt_probleme = {}, False
for line in read("/etc/nas-backup/temps-reel.conf").splitlines():
    if not line.strip() or line.startswith("#"):
        continue
    p = line.split("|")
    if len(p) < 4:
        continue
    name = p[0]
    unit = f"nas-temps-reel@{name}"
    act = active(unit)
    paused = read(f"{STATE_DIR}/rt-{name}.pause")
    st = tr_stats(f"{STATE_DIR}/rt-{name}.transferts.log")
    if paused or (not act and enabled(unit)):
        rt_probleme = True
    rt[slug(name)] = {
        "nom": name, "etat": "En pause" if paused else ("Actif" if act else "Arrêté"),
        "pause": paused.split("|", 1)[1] if "|" in paused else None,
        "dossiers": p[1].split(";"), "destination": p[2], "suppression": p[3],
        "envois_jour": st["jour"], "volume_jour": hs(st["jour_o"]), "volume_jour_go": go(st["jour_o"]),
        "envois_derniere_heure": st["heure"], "suppressions_jour": st["suppr"], "echecs_jour": st["echecs"],
        "dernier_envoi": iso(st["dernier"]), "dernier_echec": iso(st["dernier_echec"]),
        "envois_7_jours": st["sem"], "volume_7_jours": hs(st["sem_o"]), "_st": st, "_actif": act,
    }

# Cameras : sauvegarde temps reel reprise de l'ancienne synchro, ou ancienne synchro
camj = rt.get(slug(CAM_JOB)) if CAM_JOB else None
if camj:
    cam_installed, cam_actif, cam = True, camj["_actif"] and not camj["pause"], camj["_st"]
else:
    cam_installed = os.path.exists(CAM_SCRIPT)
    cam_actif = active("cam-sync")
    cam = tr_stats(CAM_TR)
for j in rt.values():
    j.pop("_st"); j.pop("_actif")

health = load(HEALTH)
alertes = sorted(os.listdir(f"{STATE_DIR}/alertes")) if os.path.isdir(f"{STATE_DIR}/alertes") else []
probleme = bool(alertes) or any(j["etat"] == "Échec" for j in jobs.values()) \
    or (cam_installed and not cam_actif) or health.get("gdrive") is False or rt_probleme

ec = en_cours[0][1] if en_cours else {}
state = {
    "etat": "Problème" if probleme else "OK",
    "probleme": "ON" if probleme else "OFF",
    "alertes": alertes,
    "nb_sauvegardes": len(jobs),
    "jobs": jobs,
    "temps_reel": rt,
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

for key, j in rt.items():
    entity("sensor", f"temps_reel_{key}", f"Temps réel {j['nom']}", {
        "value_template": "{{ value_json.temps_reel['%s'].etat if '%s' in value_json.temps_reel else none }}" % (key, key),
        "json_attributes_topic": TOPIC,
        "json_attributes_template": "{{ value_json.temps_reel['%s'] | default({}) | tojson }}" % key,
        "icon": "mdi:sync",
    })

# Retire les entites des sauvegardes supprimees
try:
    old = json.load(open(PUBLISHED))
except (OSError, ValueError):
    old = []
old_jobs, old_rt = (set(old), set()) if isinstance(old, list) else (set(old.get("jobs", [])), set(old.get("temps_reel", [])))
for key in old_jobs - set(jobs):
    pub(f"{DISC}/sensor/{OBJ}/sauvegarde_{key}/config", "")
for key in old_rt - set(rt):
    pub(f"{DISC}/sensor/{OBJ}/temps_reel_{key}/config", "")
with open(PUBLISHED, "w") as f:
    json.dump({"jobs": sorted(jobs), "temps_reel": sorted(rt)}, f)

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

# restic (sauvegardes versionnees) : version officielle (GitHub), plus recente que celle des paquets
restic_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; armv7l|armv7*|armv6l) echo arm ;; i?86) echo 386 ;; *) return 1 ;;
  esac
}

restic_version() { command -v restic >/dev/null && restic version 2>/dev/null | awk '{print $2; exit}'; }

# Derniere version de restic (verifiee au plus une fois par jour) -> stdout
outils_restic_derniere() {
  local f="$STATE_DIR/restic-derniere" v
  mkdir -p "$STATE_DIR"
  if [ -f "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -lt 86400 ]; then cat "$f"; return 0; fi
  command -v curl >/dev/null || return 1
  v=$(curl -fsSL -m 15 https://api.github.com/repos/restic/restic/releases/latest 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))' 2>/dev/null)
  [ -n "$v" ] || return 1
  echo "$v" > "$f"; echo "$v"
}

restic_officiel() {
  local arch v tmp
  arch=$(restic_arch) || { jaune "architecture $(uname -m) : restic des paquets."; apt_install restic; return; }
  outils_requis curl bunzip2 || apt_install curl bzip2
  rm -f "$STATE_DIR/restic-derniere"
  v=$(outils_restic_derniere) || v=""
  if [ -z "$v" ]; then jaune "GitHub injoignable : restic des paquets."; apt_install restic; return; fi
  tmp=$(mktemp -d)
  echo "Telechargement de restic $v ($arch)..."
  if ! curl -fsSL -o "$tmp/restic.bz2" "https://github.com/restic/restic/releases/download/v$v/restic_${v}_linux_$arch.bz2" \
     || ! bunzip2 -f "$tmp/restic.bz2"; then
    rm -rf "$tmp"; jaune "telechargement de restic impossible : restic des paquets."; apt_install restic; return
  fi
  install -m 755 "$tmp/restic" "$BIN_DIR/restic.new" && mv -f "$BIN_DIR/restic.new" "$BIN_DIR/restic"
  rm -rf "$tmp"; hash -r
  vert "OK : $("$BIN_DIR/restic" version 2>/dev/null | head -n 1)"
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
  local sm=false; { command -v smartctl >/dev/null || [ -x /usr/sbin/smartctl ]; } && sm=true
  printf '{"machine":"%s","arch":"%s","ram_total_mo":%s,"ram_dispo_mo":%s,"python3":%s,"rclone":"%s","rclone_source":"%s","rclone_derniere":"%s","curl":%s,"unzip":%s,"inotifywait":%s,"mosquitto_pub":%s,"openssl":%s,"flock":%s,"logrotate":%s,"inotify_max":%s,"restic":"%s","restic_derniere":"%s","bzip2":%s,"smartctl":%s}\n' \
    "$MACHINE" "$(uname -m)" "$(ram_total_mo)" "$(ram_dispo_mo)" "$(b python3)" "$rc" "$(rclone_source)" "$last" \
    "$(b curl)" "$(b unzip)" "$(b inotifywait)" "$(b mosquitto_pub)" "$(b openssl)" "$(b flock)" "$( [ -x /usr/sbin/logrotate ] && echo true || echo false)" "$watches" \
    "$(restic_version)" "$(cat "$STATE_DIR/restic-derniere" 2>/dev/null)" "$(b bunzip2)" "$sm"
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
  outils_requis bunzip2 || pk+=(bzip2)
  outils_requis smartctl || [ -x /usr/sbin/smartctl ] || pk+=(smartmontools)
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
  # restic (sauvegardes versionnees) : version officielle ; celle des paquets est remplacee
  # si elle est trop ancienne (avant 0.16 : pas de restauration d'un sous-dossier)
  local rv; rv=$(restic_version)
  if [ -z "$rv" ] || [ "$(printf '%s\n0.16.0\n' "$rv" | sort -V | head -n 1)" != 0.16.0 ]; then
    ( restic_officiel ) || jaune "restic n'a pas pu etre installe (sauvegardes versionnees indisponibles)."
    hash -r
  else
    vert "OK : restic $rv"
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

outils_restic_maj() {
  if [ "$(readlink -f "$(command -v restic 2>/dev/null)")" = "$BIN_DIR/restic" ] && restic self-update >/dev/null 2>&1; then
    vert "OK : $(restic version | head -n 1)"
  else
    restic_officiel
  fi
  rm -f "$STATE_DIR/restic-derniere"
}

# Corbeille : supprime les dossiers dates (AAAA-MM-JJ_HHMM...) de plus de <jours> jours.
# La date est celle du dossier (jour de la suppression ou du remplacement), pas celle
# du fichier : un vieux fichier supprime aujourd'hui reste bien <jours> jours.
trash_purge() {  # trash_purge <corbeille> <jours>
  local tr="$1" days="$2" cut d
  [ "$days" -gt 0 ] 2>/dev/null || return 0
  cut=$(date -d "-$days days" +%Y-%m-%d_%H%M)
  while IFS= read -r d; do
    d="${d%/}"
    [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4} ]] || continue
    [[ "${d:0:15}" < "$cut" ]] && rclone purge "$tr/$d" -q 2>/dev/null
  done < <(rclone lsf --dirs-only "$tr" 2>/dev/null < /dev/null)
  return 0
}

# =========================== Destinations ============================
# Une destination = un remote rclone (Google Drive « gdrive », OneDrive, disque USB,
# autre NAS en SFTP, Backblaze B2...). Organisation sur chaque destination :
#   <remote>:NAS/<dossier>             sauvegardes en clair (corbeille : NAS/_corbeille/<nom>)
#   <remote>-chiffre:<dossier>         sauvegardes chiffrees (remote crypt sur <remote>:NAS-chiffre,
#                                      memes mots de passe partout ; pour gdrive : gbackup)
#   <remote>:NAS-versions/<dossier>    sauvegardes versionnees (depot restic)
#   <remote>:NAS-secours/              kit de secours
# Destinations sur un bucket (B2, S3), un partage (SMB) ou un sous-dossier : remote
# « <nom>-base » + alias « <nom> » vers <nom>-base:<bucket/dossier>.
DEST_TYPES=" drive onedrive dropbox pcloud box b2 s3 sftp webdav smb local "
DEST_OAUTH=" drive onedrive dropbox pcloud box "

remote_exists() { rclone listremotes 2>/dev/null | grep -qxF "$1:"; }
crypt_of() { if [ "$1" = "$GDRIVE" ]; then echo "$CRYPT"; else echo "$1-chiffre"; fi; }
rclone_conf_file() { rclone config file 2>/dev/null | tail -n 1; }

# Mots de passe du chiffrement (les memes pour toutes les destinations) -> P1, P2
crypt_passwords() {
  P1=""; P2=""
  if [ -f "$PASSFILE" ]; then
    P1=$(awk -F': ' '/^Mot de passe/{print $2; exit}' "$PASSFILE"); P2=$(awk -F': ' '/^Sel/{print $2; exit}' "$PASSFILE")
  fi
  if { [ -z "$P1" ] || [ -z "$P2" ]; } && [ -f "$CAM_PASS" ]; then
    P1=$(awk -F': ' '/^Mot de passe/{print $2; exit}' "$CAM_PASS"); P2=$(awk -F': ' '/^Sel/{print $2; exit}' "$CAM_PASS")
  fi
  CRYPT_NEW=0
  if [ -z "$P1" ] || [ -z "$P2" ]; then P1=$(openssl rand -base64 24); P2=$(openssl rand -base64 24); CRYPT_NEW=1; fi
}

# Remote chiffre d'une destination (cree au premier besoin)
ensure_crypt_for() {
  local r="$1" c new=0
  c=$(crypt_of "$r")
  rclone listremotes 2>/dev/null | grep -qxF "$c:" && return 0
  crypt_passwords
  rclone config create "$c" crypt remote="${r}:${CRYPT_FOLDER}" \
    filename_encryption=standard directory_name_encryption=true \
    password="$P1" password2="$P2" --obscure >/dev/null || die "creation du remote chiffre '$c' impossible."
  if [ ! -s "$PASSFILE" ]; then
    new=1
    {
      echo "Remote rclone : ${c}  ->  ${r}:${CRYPT_FOLDER}"
      echo "Mot de passe        : $P1"
      echo "Sel (password2)     : $P2"
      echo "Cree le             : $(date)"
    } > "$PASSFILE"
    chmod 600 "$PASSFILE"
  else
    echo "Aussi utilise par   : ${c}  ->  ${r}:${CRYPT_FOLDER}" >> "$PASSFILE"
  fi
  logl "remote chiffre $c cree (${r}:${CRYPT_FOLDER})"
  if [ $new = 1 ] && [ "$CRYPT_NEW" = 1 ]; then
    echo
    rouge "=== Remote chiffre '${c}' cree. NOTE CES MOTS DE PASSE EN LIEU SUR (hors du NAS) ==="
    cat "$PASSFILE"
    echo
  fi
  return 0
}

# Liste des destinations (JSON, sans aucun secret) : nom, type, description, chiffrement pret
dest_list() {
  python3 - "$(rclone_conf_file)" "$GDRIVE" "$CRYPT" <<'PYDL'
import configparser, json, re, sys
path, gd, cr = sys.argv[1:4]
cp = configparser.RawConfigParser(strict=False, interpolation=None)
try:
    cp.read(path)
except Exception:
    pass
secs = {s: dict(cp.items(s)) for s in cp.sections()}
NOMS = {"drive": "Google Drive", "onedrive": "OneDrive", "dropbox": "Dropbox", "pcloud": "pCloud", "box": "Box",
        "b2": "Backblaze B2", "s3": "S3", "sftp": "SFTP", "webdav": "WebDAV", "smb": "SMB", "local": "Disque local"}
def describe(t, c):
    if t == "onedrive":
        return "OneDrive" + (" (%s)" % c["drive_type"] if c.get("drive_type") else "")
    if t == "s3":
        return " ".join(x for x in (c.get("provider", "S3"), c.get("endpoint") or c.get("region", "")) if x)
    if t == "sftp":
        return "%s@%s%s" % (c.get("user", ""), c.get("host", ""), ":" + c["port"] if c.get("port") else "")
    if t == "webdav":
        return re.sub(r"//[^/@]*@", "//", c.get("url", ""))
    if t == "smb":
        return "%s@%s" % (c.get("user", ""), c.get("host", ""))
    return NOMS.get(t, t)
bases = {r.split(":", 1)[0] for r in (c.get("remote", "") for c in secs.values() if c.get("type") == "alias") if ":" in r}
out = []
for name, c in secs.items():
    t = c.get("type", "")
    if t == "crypt" or (name.endswith("-base") and name in bases):
        continue
    kind, cible = t, describe(t, c)
    if t == "alias":
        r = c.get("remote", "")
        base, _, sub = r.partition(":")
        if sub and base in secs:
            kind = secs[base].get("type", "")
            cible = describe(kind, secs[base]) + " : " + sub
        else:
            kind, cible = "local", r
    crypt = (name == gd and cr in secs) or (name + "-chiffre") in secs
    out.append({"nom": name, "type": kind, "libelle": NOMS.get(kind, kind), "cible": cible, "chiffre_pret": crypt})
print(json.dumps(out, ensure_ascii=False))
PYDL
}

# Test d'une destination ; resultat garde dans destinations.json -> 0 si joignable
dest_check() {  # dest_check <nom>
  local n="$1" ok=false err="" about=""
  if ! err=$(dest_ready "$n"); then
    :
  elif err=$(timeout 120 rclone lsf "$n:" --max-depth 1 2>&1 >/dev/null < /dev/null) || echo "$err" | grep -qi 'directory not found'; then
    ok=true; err=""
    about=$(timeout 60 rclone about "$n:" --json 2>/dev/null < /dev/null) || about=""
  else
    err=$(echo "$err" | grep -E 'ERROR|CRITICAL|Failed' | tail -n 1 | sed -E 's/^[0-9\/ :]+//' | cut -c1-250)
    [ -n "$err" ] || err="destination injoignable (delai depasse)"
  fi
  [ "$ok" = true ] || [ -n "$err" ] || err="destination injoignable"
  mkdir -p "$STATE_DIR"
  ( flock 5
    python3 - "$DEST_JSON" "$n" "$ok" "$err" "$about" <<'PYDC'
import json, sys, time
path, n, ok, err, about = sys.argv[1:6]
try:
    d = json.load(open(path))
except Exception:
    d = {}
e = {"ok": ok == "true", "verifie": int(time.time())}
if err:
    e["erreur"] = err
try:
    a = json.loads(about) if about else {}
    for k, v in (("total", "total"), ("utilise", "used"), ("libre", "free")):
        if a.get(v) is not None:
            e[k] = int(a[v])
except ValueError:
    pass
d[n] = e
json.dump(d, open(path + ".new", "w"))
import os
os.replace(path + ".new", path)
PYDC
  ) 5>"$DEST_JSON.lock"
  [ "$ok" = true ]
}

# Questions de la configuration rclone : reponses par defaut (jeton deja fourni : pas de navigateur)
dest_continue() {  # dest_continue <remote>   (sortie JSON de rclone --non-interactive sur stdin)
  python3 - "$1" <<'PYCONT'
import json, subprocess, sys
name = sys.argv[1]
out = sys.stdin.read()
FIXE = {"config_refresh_token": "false", "config_is_local": "false", "config_change_team_drive": "false"}
for _ in range(20):
    i = out.find("{")
    if i < 0:
        break
    try:
        q = json.loads(out[i:])
    except ValueError:
        break
    if q.get("Error"):
        print("Configuration refusee : %s" % q["Error"])
        sys.exit(1)
    st = q.get("State") or ""
    if not st:
        break
    opt = q.get("Option") or {}
    res = FIXE.get(opt.get("Name", ""), opt.get("Default"))
    if res is None or res == "":
        ex = opt.get("Examples") or []
        res = ex[0].get("Value", "") if ex else ""
    if isinstance(res, bool):
        res = "true" if res else "false"
    out = subprocess.run(["rclone", "config", "update", name, "--continue", "--state", st, "--result", str(res),
                          "--non-interactive"], capture_output=True, text=True).stdout
PYCONT
}

dest_valid_name() {
  [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_]{0,29}$ ]] || die "nom de destination invalide (lettres, chiffres et _, 30 au plus, commence par une lettre)."
  case "$1" in "$CRYPT"|gcrypt|rclone|NAS) die "nom reserve : $1" ;; esac
}

# Ecriture d'un petit fichier puis suppression : la destination accepte bien les envois
dest_write_test() {
  local f=".nas-manager-test-$$" out
  out=$(echo "test NAS Manager $(date)" | timeout 120 rclone rcat "$1:$f" 2>&1) || { echo "$out" | tail -n 3; return 1; }
  timeout 60 rclone deletefile "$1:$f" >/dev/null 2>&1
  return 0
}

dest_create() {  # dest_create <nom> <type>   parametres « cle=valeur » sur l'entree standard
  local n="$1" t="$2" line k v dossier target out
  need_root_rclone
  dest_valid_name "$n"
  [[ "$DEST_TYPES" == *" $t "* ]] || die "type de destination inconnu : $t"
  [[ "$DEST_OAUTH" == *" $t "* ]] && die "$t : connexion par le navigateur (NAS Manager, page Destinations)."
  remote_exists "$n" && die "une destination '$n' existe deja."
  local -A P=()
  if [ ! -t 0 ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      k="${line%%=*}"; v="${line#*=}"
      [[ "$k" =~ ^[a-z0-9_]+$ && "$line" == *=* ]] || die "parametre invalide : $k"
      P[$k]="$v"
    done
  fi
  if [ "$t" = local ]; then
    v="${P[chemin]:-}"; v="${v%/}"
    [[ "$v" == /* && "$v" != *..* && "$v" != *"|"* ]] || die "chemin du disque invalide (chemin complet, ex. /media/usb/Sauvegardes)."
    k="$v"; while [ ! -d "$k" ]; do k=$(dirname "$k"); done
    # disque debranche = point de montage vide : refuser d'ecrire sur le disque systeme
    if [ "$(df --output=target "$k" 2>/dev/null | tail -n 1)" = / ] && [ "${P[systeme]:-}" != oui ]; then
      die "$v est sur le disque systeme de la machine : choisis un disque de donnees ou un disque USB monte."
    fi
    mkdir -p "$v" 2>/dev/null; [ -d "$v" ] || die "dossier introuvable : $v (disque branche et monte ?)"
    rclone config create "$n" alias remote="$v" >/dev/null || die "creation impossible."
  else
    dossier="${P[dossier]:-}"; unset 'P[dossier]'
    dossier="${dossier#/}"; dossier="${dossier%/}"
    [[ "$dossier" == *..* ]] && die "dossier invalide."
    case "$t" in
      b2|s3) [ -n "$dossier" ] || die "indique le bucket (et un dossier facultatif : bucket/dossier)." ;;
      smb)   [ -n "$dossier" ] || die "indique le partage (et un dossier facultatif : partage/dossier)." ;;
    esac
    target="$n"; [ -n "$dossier" ] && target="$n-base"
    remote_exists "$target" && die "un remote '$target' existe deja."
    local -a args=()
    for k in "${!P[@]}"; do args+=("$k=${P[$k]}"); done
    out=$(rclone config create "$target" "$t" "${args[@]}" --obscure --non-interactive 2>&1 < /dev/null)
    if ! echo "$out" | dest_continue "$target"; then rclone config delete "$target" >/dev/null 2>&1; die "configuration refusee par rclone."; fi
    remote_exists "$target" || die "creation impossible : $(echo "$out" | tail -n 3)"
    [ -n "$dossier" ] && { rclone config create "$n" alias remote="$target:$dossier" >/dev/null || die "creation impossible."; }
  fi
  echo "== Test d'envoi vers « $n » =="
  if ! out=$(dest_write_test "$n"); then
    rouge "La destination ne repond pas ou refuse l'envoi :"
    echo "$out" | sed -E 's/^[0-9\/ :]+//'
    rclone config delete "$n" >/dev/null 2>&1; [ -n "${dossier:-}" ] && rclone config delete "$n-base" >/dev/null 2>&1
    die "destination non creee (verifie l'adresse, l'identifiant et le mot de passe)."
  fi
  dest_check "$n" >/dev/null || true
  logl "destination $n ($t) creee"
  vert "Destination « $n » prete : les sauvegardes peuvent maintenant l'utiliser."
}

dest_token() {  # dest_token <nom> <type>   jeton OAuth (JSON) sur l'entree standard
  local n="$1" t="$2" tok out
  need_root_rclone
  [[ "$DEST_OAUTH" == *" $t "* ]] || die "type sans connexion par navigateur : $t"
  [ "$n" = "$GDRIVE" ] || dest_valid_name "$n"
  IFS= read -r tok || true
  [[ "$tok" == \{* ]] || die "jeton absent ou invalide."
  local -a extra=(config_refresh_token=false)
  [ "$t" = drive ] && extra+=(scope=drive)
  if remote_exists "$n"; then
    out=$(rclone config update "$n" token "$tok" config_refresh_token=false --non-interactive 2>&1 < /dev/null)
  else
    out=$(rclone config create "$n" "$t" token="$tok" "${extra[@]}" --non-interactive 2>&1 < /dev/null)
  fi
  echo "$out" | dest_continue "$n" || die "configuration refusee par rclone."
  remote_exists "$n" || die "connexion non enregistree : $(echo "$out" | tail -n 2)"
  if dest_check "$n"; then
    logl "destination $n ($t) connectee"
    vert "Destination « $n » connectee."
  else
    die "connexion enregistree, mais « $n » ne repond pas encore."
  fi
}

# Destination prete a recevoir : un disque local (alias vers un dossier) doit etre branche,
# sinon rclone recreerait le dossier sur le disque systeme
dest_ready() {  # dest_ready <remote> -> 0 si utilisable ; message sinon
  local p
  p=$(rclone config show "$1" 2>/dev/null | awk -F' = ' '$1=="type"{t=$2} $1=="remote"{r=$2} END{if (t=="alias" && substr(r,1,1)=="/") print r}')
  [ -z "$p" ] || [ -d "$p" ] || { echo "le dossier $p est introuvable (disque debranche ou non monte ?)"; return 1; }
  return 0
}

# Sauvegardes (programmees ou temps reel) qui utilisent une destination
dest_users() {  # dest_users <remote>
  local r="$1" n s sub m e sch ret bw perf dests d c
  c=$(crypt_of "$r")
  if [ -f "$JOBS" ]; then
    while IFS='|' read -r n s sub m e sch ret bw perf dests _ || [ -n "$n" ]; do
      [[ -z "$n" || "$n" == \#* ]] && continue
      [ -n "$dests" ] || dests="$GDRIVE:$e"
      for d in ${dests//;/ }; do [ "${d%%:*}" = "$r" ] && { echo "$n"; break; }; done
    done < "$JOBS"
  fi
  if [ -f "$RT_CONF" ]; then
    while IFS='|' read -r n s d _ || [ -n "$n" ]; do
      [[ -z "$n" || "$n" == \#* ]] && continue
      d="${d%%:*}"
      { [ "$d" = "$r" ] || [ "$d" = "$c" ] || { [ "$r" = "$GDRIVE" ] && [ "$d" = gcrypt ]; }; } && echo "$n (temps reel)"
    done < "$RT_CONF"
  fi
  return 0
}

dest_delete() {  # dest_delete <nom>
  local n="$1" u
  need_root_rclone
  remote_exists "$n" || die "destination '$n' introuvable."
  u=$(dest_users "$n")
  [ -z "$u" ] || die "destination utilisee par : $(echo "$u" | paste -sd, -). Retire-la d'abord de ces sauvegardes."
  rclone config delete "$n" || die "suppression impossible."
  remote_exists "$n-base" && rclone config delete "$n-base"
  remote_exists "$(crypt_of "$n")" && [ "$n" != "$GDRIVE" ] && rclone config delete "$(crypt_of "$n")"
  python3 - "$DEST_JSON" "$n" <<'PYDD' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1])); d.pop(sys.argv[2], None); json.dump(d, open(sys.argv[1], "w"))
except Exception:
    pass
PYDD
  logl "destination $n supprimee (donnees laissees en place)"
  vert "Destination « $n » retiree. Les fichiers deja envoyes restent sur place."
}

destinations_main() {
  case "${1:-liste}" in
    liste)     need_root_rclone; dest_list ;;
    etat)      need_root_rclone
               if [ -n "${2:-}" ]; then dest_check "$2" || true
               else local d; for d in $(dest_list | python3 -c 'import json,sys; print(" ".join(x["nom"] for x in json.load(sys.stdin)))'); do dest_check "$d" || true; done; fi
               cat "$DEST_JSON" 2>/dev/null || echo '{}' ;;
    creer)     [ -n "${3:-}" ] || die "usage : destinations creer <NOM> <TYPE>  (parametres cle=valeur sur l'entree standard)"; dest_create "$2" "$3" ;;
    jeton)     [ -n "${3:-}" ] || die "usage : destinations jeton <NOM> <TYPE>  (jeton sur l'entree standard)"; dest_token "$2" "$3" ;;
    supprimer) [ -n "${2:-}" ] || die "usage : destinations supprimer <NOM>"; dest_delete "$2" ;;
    *) die "usage : nas-debian destinations liste | etat [NOM] | creer NOM TYPE | jeton NOM TYPE | supprimer NOM" ;;
  esac
}

need_root_rclone() {
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  command -v rclone >/dev/null || die "rclone n'est pas installe (nas-debian outils installer)."
  mkdir -p "$CONF_DIR" "$STATE_DIR"
}

# =========================== Sauvegardes temps reel ==================
# Un dossier (ou plusieurs) surveille en continu : chaque fichier cree, modifie
# ou supprime est repercute sur la destination, par lots (regroupement).
# /etc/nas-backup/temps-reel.conf, une ligne par sauvegarde :
#   NOM|DOSSIERS (separes par ;)|DESTINATION (remote rclone)|SUPPRESSION (directe,
#   corbeille, copie)|CORBEILLE_JOURS|EXCLUSIONS (;)|TYPES (;)|DELAI_S|RATTRAPAGE_MIN|
#   ANOMALIE (seuil, 0 = aucun)|MEMOIRE|DEBIT
# Un service systemd par sauvegarde (nas-temps-reel@NOM) + un rattrapage periodique (cron).
RT_CONF="$CONF_DIR/temps-reel.conf"
RT_CRON="/etc/cron.d/nas-temps-reel"
RT_UNIT="/etc/systemd/system/nas-temps-reel@.service"
RT_LOG_DIR="/var/log/nas-temps-reel"
RT_MAXWAIT=60          # un fichier modifie en boucle part au plus tard apres 60 s
RT_FENETRE=600         # detection d'anomalie : nombre de fichiers sur 10 minutes
RT_CATCH_OK=(0 5 10 15 20 30 60 120 180 240 360 720 1440)
# toujours exclus : dossiers techniques, fichiers temporaires
RT_EXCL_DIRS=('@eaDir' '#recycle' '.Trash-*' '#snapshot' '.SynologyWorkingDirectory')
RT_EXCL_FILES=('*.tmp' '*.part' '*.swp' '*.crdownload' '.~lock.*' '~$*' '.DS_Store' 'Thumbs.db' 'desktop.ini')

rt_names() { [ -f "$RT_CONF" ] && grep -v '^#' "$RT_CONF" | grep -v '^$' | cut -d'|' -f1; return 0; }
rt_exists() { [ -f "$RT_CONF" ] && grep -q "^$1|" "$RT_CONF"; }

rt_get() {  # rt_get <nom> -> R_*
  local line; line=$(grep -m1 "^$1|" "$RT_CONF" 2>/dev/null) || return 1
  IFS='|' read -r R_NAME R_DIRS R_DEST R_DEL R_RET R_EXCL R_TYPES R_DELAY R_CATCH R_ANOM R_PERF R_BW <<< "$line"
  R_RET=${R_RET:-0}; R_DELAY=${R_DELAY:-10}; R_CATCH=${R_CATCH:-15}; R_ANOM=${R_ANOM:-0}
  R_EXCL=${R_EXCL:-}; R_TYPES=${R_TYPES:-}; R_PERF=${R_PERF:-}; R_BW=${R_BW:-}
  IFS=';' read -ra R_SRCS <<< "$R_DIRS"
  return 0
}

rt_save_line() {
  mkdir -p "$CONF_DIR"
  [ -f "$RT_CONF" ] || echo "# NOM|DOSSIERS|DESTINATION|SUPPRESSION|CORBEILLE_JOURS|EXCLUSIONS|TYPES|DELAI_S|RATTRAPAGE_MIN|ANOMALIE|MEMOIRE|DEBIT" > "$RT_CONF"
  local tmp; tmp=$(mktemp)
  grep -v "^$R_NAME|" "$RT_CONF" > "$tmp"
  echo "$R_NAME|$R_DIRS|$R_DEST|$R_DEL|$R_RET|$R_EXCL|$R_TYPES|$R_DELAY|$R_CATCH|$R_ANOM|$R_PERF|$R_BW" >> "$tmp"
  cat "$tmp" > "$RT_CONF"; rm -f "$tmp"
}

rt_log() { mkdir -p "$RT_LOG_DIR"; echo "$(date '+%Y/%m/%d %H:%M:%S') NOTICE: [$R_NAME] $*" >> "$RT_LOG_DIR/$R_NAME.log"; }
rt_trace() { echo "$(date +%s)|$1|${2:-0}|$3|${4:-1}" >> "$STATE_DIR/rt-$R_NAME.transferts.log"; }   # <action> <octets> <ok|echec> [nb]

# Destination d'un dossier surveille : la destination, ou destination/<nom du dossier> s'il y en a plusieurs
rt_dest_of() {
  if [ ${#R_SRCS[@]} -le 1 ]; then echo "$R_DEST"; return; fi
  local b="${1%/}"; b="${b##*/}"
  case "$R_DEST" in *:) echo "$R_DEST$b" ;; *) echo "${R_DEST%/}/$b" ;; esac
}

# Corbeille : a cote de la destination (dans la destination seulement si c'est la racine du remote)
rt_trash_root() {
  local remote="${R_DEST%%:*}" path="${R_DEST#*:}" parent
  path="${path%/}"
  if [ -z "$path" ]; then echo "$remote:_corbeille-temps-reel/$R_NAME"; return; fi
  parent=""; [[ "$path" == */* ]] && parent="${path%/*}"
  echo "$remote:${parent:+$parent/}_corbeille/temps-reel/$R_NAME"
}
rt_trash_of() {
  local t; t=$(rt_trash_root)
  if [ ${#R_SRCS[@]} -le 1 ]; then echo "$t"; else local b="${1%/}"; echo "$t/${b##*/}"; fi
}

# Filtres rclone (ordre explicite : exclusions, puis types gardes)
rt_filters() {
  local -; set -f      # motifs (*.tmp...) : pas d'expansion par le shell
  RT_FILT=()
  [ -z "${R_DEST#*:}" ] && RT_FILT+=(--filter "- /_corbeille-temps-reel/**")
  local p
  for p in "${RT_EXCL_DIRS[@]}"; do RT_FILT+=(--filter "- ${p/#\#/\\#}/**"); done
  for p in "${RT_EXCL_FILES[@]}"; do RT_FILT+=(--filter "- $p"); done
  local IFS=';'
  for p in $R_EXCL; do [ -n "$p" ] && RT_FILT+=(--filter "- $p" --filter "- ${p%/}/**"); done
  if [ -n "$R_TYPES" ]; then
    for p in $R_TYPES; do [ -n "$p" ] && RT_FILT+=(--filter "+ $p"); done
    RT_FILT+=(--filter "- *")
  fi
}

# rt_skip <chemin relatif> <0|1 dossier> : 0 = a ignorer (exclusion, type non garde)
# shellcheck disable=SC2053  # comparaisons volontairement par motif
rt_skip() {
  local -; set -f
  local rel="$1" isdir="$2" c p IFS
  IFS='/'
  for c in $rel; do
    for p in "${RT_EXCL_DIRS[@]}"; do [[ "$c" == $p ]] && return 0; done
  done
  local base="${rel##*/}"
  for p in "${RT_EXCL_FILES[@]}"; do [[ "$base" == $p ]] && return 0; done
  IFS=';'
  for p in $R_EXCL; do
    [ -n "$p" ] || continue
    if [[ "$p" == */* ]]; then
      p="${p#/}"; p="${p%/}"
      [[ "$rel" == $p || "$rel" == $p/* ]] && return 0
    else
      IFS='/'; for c in $rel; do [[ "$c" == $p ]] && return 0; done; IFS=';'
    fi
  done
  if [ -n "$R_TYPES" ] && [ "$isdir" = 0 ]; then
    for p in $R_TYPES; do [ -n "$p" ] && [[ "$base" == $p ]] && return 1; done
    return 0
  fi
  return 1
}

rt_paused() { [ -f "$STATE_DIR/rt-$R_NAME.pause" ]; }

rt_pause() {  # rt_pause <raison>
  printf '%s|%s\n' "$(date +%s)" "$1" > "$STATE_DIR/rt-$R_NAME.pause"
  rt_log "PAUSE : $1"
  notify critique "rt-pause-$R_NAME" "Sauvegarde temps réel « $R_NAME » en pause" "$1. Rien n'a été répercuté sur la destination. Vérifie le dossier, puis reprends la sauvegarde depuis NAS Manager."
}

# --------------------------- surveillance (service) ------------------
rt_watch() {
  rt_get "$1" || die "sauvegarde temps reel '$1' introuvable."
  command -v inotifywait >/dev/null || die "inotifywait absent (nas-debian outils installer)."
  perf_load "$R_PERF"; rt_filters
  mkdir -p "$RT_LOG_DIR" "$STATE_DIR"
  local -a ok=() ; local s
  for s in "${R_SRCS[@]}"; do
    if [ -d "$s" ]; then ok+=("${s%/}"); else rt_log "ERROR : dossier introuvable : $s"; fi
  done
  if [ ${#ok[@]} -eq 0 ]; then
    notify critique "rt-service-$R_NAME" "Sauvegarde temps réel « $R_NAME » arrêtée" "Aucun dossier surveillé n'est accessible (disque démonté ?)."
    sleep 60; exit 1
  fi
  R_SRCS=("${ok[@]}")
  echo "$BASHPID" > "$STATE_DIR/rt-$R_NAME.pid"
  rt_log "surveillance demarree : ${ok[*]} -> $R_DEST (regroupement ${R_DELAY} s, suppressions : $R_DEL)"
  inotifywait -m -r -q -e close_write -e moved_to -e delete -e moved_from -e create \
    --exclude '(/@eaDir(/|$)|/#recycle(/|$)|/\.Trash-[^/]*(/|$)|/#snapshot(/|$))' \
    --format '%e|%w%f' "${ok[@]}" 2>>"$RT_LOG_DIR/$R_NAME.log" | rt_loop
  rt_log "surveillance arretee (inotifywait termine)"
}

rt_loop() {
  declare -gA RT_PEND=() RT_MOD=() RT_CREATED=()
  RT_WIN_T=(); RT_WIN_N=()
  RT_FIRST=0; RT_LAST=0
  local line now
  while true; do
    if IFS= read -r -t 1 line; then
      rt_event "${line%%|*}" "${line#*|}"
    elif [ $? -le 128 ]; then
      break
    fi
    printf -v now '%(%s)T' -1
    if [ ${#RT_PEND[@]} -gt 0 ] && { [ $((now - RT_LAST)) -ge "$R_DELAY" ] || [ $((now - RT_FIRST)) -ge "$RT_MAXWAIT" ]; }; then
      rt_flush
    fi
  done
  [ ${#RT_PEND[@]} -gt 0 ] && rt_flush
  return 0
}

rt_event() {  # rt_event <evenements> <chemin>
  local ev="$1" f="$2" src="" s rel isdir=0 key now
  [[ "$ev" == *ISDIR* ]] && isdir=1
  for s in "${R_SRCS[@]}"; do [[ "$f" == "$s/"* ]] && { src="$s"; break; }; done
  [ -n "$src" ] || return 0
  rel="${f#"$src"/}"
  rt_skip "$rel" "$isdir" && return 0
  key="$src|$rel"
  case "$ev" in
    *CREATE*)
      if [ $isdir = 1 ]; then RT_PEND[$key]=updir; else RT_CREATED[$key]=1; return 0; fi ;;
    *CLOSE_WRITE*)
      RT_PEND[$key]=up
      [ -n "${RT_CREATED[$key]:-}" ] || RT_MOD[$key]=1 ;;       # fichier deja present modifie
    *MOVED_TO*)
      if [ $isdir = 1 ]; then RT_PEND[$key]=updir; else RT_PEND[$key]=up; fi ;;
    *DELETE*|*MOVED_FROM*)
      if [ $isdir = 1 ]; then RT_PEND[$key]=deldir; else RT_PEND[$key]=del; fi
      unset 'RT_MOD[$key]' 'RT_CREATED[$key]' ;;
    *) return 0 ;;
  esac
  printf -v now '%(%s)T' -1
  [ "$RT_FIRST" -eq 0 ] && RT_FIRST=$now
  RT_LAST=$now
}

# Fichiers supprimes ou modifies sur la fenetre de detection (cette fois + 10 dernieres minutes)
rt_window() {  # rt_window <maintenant> <nb> -> RT_WIN_SUM
  local now="$1" i
  local -a t=() n=()
  RT_WIN_SUM=$2
  for i in "${!RT_WIN_T[@]}"; do
    if [ $((now - RT_WIN_T[i])) -lt "$RT_FENETRE" ]; then t+=("${RT_WIN_T[i]}"); n+=("${RT_WIN_N[i]}"); RT_WIN_SUM=$((RT_WIN_SUM + RT_WIN_N[i])); fi
  done
  RT_WIN_T=("${t[@]}" "$now"); RT_WIN_N=("${n[@]}" "$2")
}

rt_flush() {
  local now jour key src rel act path i d tr suspects=0 log="$RT_LOG_DIR/$R_NAME.log" tmp rc
  printf -v now '%(%s)T' -1; printf -v jour '%(%Y-%m-%d_%H%M%S)T' -1   # secondes : pas d'ecrasement entre deux envois
  for key in "${!RT_PEND[@]}"; do
    case "${RT_PEND[$key]}" in del|deldir) suspects=$((suspects + 1)) ;; esac
  done
  suspects=$((suspects + ${#RT_MOD[@]}))
  if rt_paused; then
    RT_PEND=(); RT_MOD=(); RT_FIRST=0; return 0
  fi
  # reprise confirmee depuis la derniere fois : la fenetre de detection repart de zero
  local rep; rep=$(cat "$STATE_DIR/rt-$R_NAME.reprise" 2>/dev/null)
  if [ -n "$rep" ] && [ "$rep" != "${RT_REPRISE_VUE:-}" ]; then RT_WIN_T=(); RT_WIN_N=(); RT_REPRISE_VUE="$rep"; fi
  if [ "$R_ANOM" -gt 0 ]; then
    rt_window "$now" "$suspects"
    if [ "$RT_WIN_SUM" -ge "$R_ANOM" ]; then
      rt_pause "Anomalie : $RT_WIN_SUM fichiers supprimés ou modifiés en moins de 10 minutes (seuil $R_ANOM)"
      RT_PEND=(); RT_MOD=(); RT_CREATED=(); RT_FIRST=0; return 0
    fi
  fi
  tmp=$(mktemp -d)
  for key in "${!RT_PEND[@]}"; do
    src="${key%%|*}"; rel="${key#*|}"; act="${RT_PEND[$key]}"; path="$src/$rel"
    for i in "${!R_SRCS[@]}"; do [ "${R_SRCS[i]}" = "$src" ] && break; done
    case "$act" in
      up|del)
        if [ -f "$path" ]; then printf '%s\n' "$rel" >> "$tmp/$i.up"
        elif [ ! -e "$path" ]; then printf '%s\n' "$rel" >> "$tmp/$i.del"; fi ;;
      updir)  [ -d "$path" ] && printf '%s\n' "$rel" >> "$tmp/$i.updir" ;;
      deldir) [ -e "$path" ] || printf '%s\n' "$rel" >> "$tmp/$i.deldir" ;;
    esac
  done
  RT_PEND=(); RT_MOD=(); RT_FIRST=0
  local -a common=(--log-file "$log" --log-level INFO --retries 3)
  [ -n "$R_BW" ] && common+=(--bwlimit "$R_BW")
  local n o f fail=0
  for i in "${!R_SRCS[@]}"; do
    src="${R_SRCS[i]}"; d=$(rt_dest_of "$src"); tr="$(rt_trash_of "$src")/$jour"
    local -a keep=(); [ "$R_DEL" = corbeille ] && keep=(--backup-dir "$tr")
    if [ -s "$tmp/$i.up" ]; then
      n=$(cnt "$tmp/$i.up"); o=0
      while IFS= read -r f; do o=$((o + $(stat -c %s "$src/$f" 2>/dev/null || echo 0))); done < "$tmp/$i.up"
      if rcl "rt-$R_NAME" copy "$src" "$d" --files-from-raw "$tmp/$i.up" --no-traverse "${keep[@]}" "${common[@]}" < /dev/null; then
        rt_trace envoi "$o" ok "$n"
      else
        rt_trace envoi 0 echec "$n"; fail=1
      fi
    fi
    if [ -s "$tmp/$i.updir" ]; then
      while IFS= read -r f; do
        n=$(find "$src/$f" -type f 2>/dev/null | wc -l); o=$(du -sb "$src/$f" 2>/dev/null | cut -f1)
        local -a kd=(); [ "$R_DEL" = corbeille ] && kd=(--backup-dir "$tr/$f")
        if rcl "rt-$R_NAME" copy "$src/$f" "$d/$f" "${RT_FILT[@]}" "${kd[@]}" "${common[@]}" < /dev/null; then
          rt_trace envoi "${o:-0}" ok "$n"
        else
          rt_trace envoi 0 echec "$n"; fail=1
        fi
      done < "$tmp/$i.updir"
    fi
    [ "$R_DEL" = copie ] && continue
    if [ -s "$tmp/$i.deldir" ]; then
      while IFS= read -r f; do
        if [ "$R_DEL" = corbeille ]; then
          rclone move "$d/$f" "$tr/$f" --delete-empty-src-dirs "${common[@]}" < /dev/null && rclone rmdirs "$d/$f" -q 2>/dev/null; rc=$?
        else
          rclone purge "$d/$f" "${common[@]}" < /dev/null; rc=$?
        fi
        if [ $rc -eq 0 ]; then rt_trace suppression 0 ok 1; else rt_trace suppression 0 echec 1; fi
      done < "$tmp/$i.deldir"
    fi
    if [ -s "$tmp/$i.del" ]; then
      n=$(cnt "$tmp/$i.del")
      if [ "$R_DEL" = corbeille ]; then
        rclone move "$d" "$tr" --files-from-raw "$tmp/$i.del" --no-traverse "${common[@]}" < /dev/null; rc=$?
      else
        rclone delete "$d" --files-from-raw "$tmp/$i.del" "${common[@]}" < /dev/null; rc=$?
      fi
      if [ $rc -eq 0 ]; then rt_trace suppression 0 ok "$n"; else rt_trace suppression 0 echec "$n"; fi
    fi
  done
  rm -rf "$tmp"
  if [ $fail = 0 ]; then
    notify ok "rt-$R_NAME" "Sauvegarde temps réel « $R_NAME »" "Les envois vers la destination fonctionnent de nouveau."
  else
    notify critique "rt-$R_NAME" "Sauvegarde temps réel « $R_NAME » : envoi en échec" "Des fichiers ne partent pas vers la destination ($R_DEST). Ils seront renvoyés au prochain rattrapage. Détails : $log"
  fi
  return 0
}

# --------------------------- rattrapage (cron) -----------------------
rt_catchup() {  # rt_catchup <nom> [initial]
  rt_get "$1" || die "sauvegarde temps reel '$1' introuvable."
  need_rclone
  if rt_paused; then echo "Sauvegarde « $R_NAME » en pause : pas de rattrapage."; return 0; fi
  exec 6>"/run/nas-temps-reel-$R_NAME.lock"
  flock -n 6 || { echo "Un rattrapage de « $R_NAME » est deja en cours."; return 0; }
  perf_load "$R_PERF"; rt_filters
  local log="$RT_LOG_DIR/$R_NAME.log" tmp src d tr rc=0 r jour n nd now f o=0 nc=0
  mkdir -p "$RT_LOG_DIR"; tmp=$(mktemp); jour=$(date +%Y-%m-%d_%H%M%S)
  local -a min=(--min-age 2m) common=(--log-level INFO --retries 3)
  # envoi complet, ou reprise confirmee : etat actuel repercute tout de suite (sans attendre 2 min)
  [ "${2:-}" = initial ] && min=()
  [ -f "$STATE_DIR/rt-$R_NAME.autorise" ] && min=()
  [ -n "$R_BW" ] && common+=(--bwlimit "$R_BW")
  rt_log "rattrapage$( [ "${2:-}" = initial ] && echo " (envoi complet)") : debut"
  for src in "${R_SRCS[@]}"; do
    src="${src%/}"
    [ -d "$src" ] || { rt_log "ERROR : dossier introuvable : $src"; rc=1; continue; }
    d=$(rt_dest_of "$src"); tr=$(rt_trash_of "$src")
    if [ "$R_DEL" = copie ]; then
      rcl "rt-$R_NAME" copy "$src" "$d" "${min[@]}" "${RT_FILT[@]}" "${common[@]}" --log-file "$tmp" < /dev/null || rc=1
      continue
    fi
    # garde-fou : trop de suppressions d'un coup -> pause, rien n'est supprime
    # (sauf juste apres une reprise confirmee par l'utilisateur)
    if [ "$R_ANOM" -gt 0 ] && [ ! -f "$STATE_DIR/rt-$R_NAME.autorise" ]; then
      nd=$(rclone sync "$src" "$d" "${min[@]}" "${RT_FILT[@]}" --dry-run --log-level NOTICE 2>&1 < /dev/null | grep -cE 'Skipped (delete|move)')
      if [ "${nd:-0}" -ge "$R_ANOM" ]; then
        rt_pause "Anomalie : le rattrapage supprimerait $nd fichiers d'un coup (seuil $R_ANOM)"
        rm -f "$tmp"; return 1
      fi
    fi
    local -a keep=(); [ "$R_DEL" = corbeille ] && keep=(--backup-dir "$tr/$jour")
    rcl "rt-$R_NAME" sync "$src" "$d" "${min[@]}" "${keep[@]}" "${RT_FILT[@]}" "${common[@]}" --log-file "$tmp" < /dev/null; r=$?
    [ $r -ne 0 ] && rc=1
    if [ "$R_DEL" = corbeille ] && [ "$R_RET" -gt 0 ] && [ $r -eq 0 ]; then
      trash_purge "$tr" "$R_RET"
    fi
  done
  rm -f "$STATE_DIR/rt-$R_NAME.autorise"
  now=$(date +%s)
  while IFS= read -r f; do
    nc=$((nc + 1))
    for src in "${R_SRCS[@]}"; do
      [ -f "${src%/}/$f" ] && { o=$((o + $(stat -c %s "${src%/}/$f" 2>/dev/null || echo 0))); break; }
    done
  done < <(grep -E ' INFO +: .+: Copied \(' "$tmp" | sed -E 's/^.* INFO +: (.+): Copied \(.*$/\1/')
  [ "$nc" -gt 0 ] && echo "$now|envoi|$o|ok|$nc" >> "$STATE_DIR/rt-$R_NAME.transferts.log"
  n=$(grep -cE ' INFO +: .+: (Deleted|Moved \(server-side\))' "$tmp")
  [ "${n:-0}" -gt 0 ] && echo "$now|$( [ "$R_DEL" = corbeille ] && echo corbeille || echo suppression)|0|ok|$n" >> "$STATE_DIR/rt-$R_NAME.transferts.log"
  [ $rc -ne 0 ] && echo "$now|rattrapage|0|echec|1" >> "$STATE_DIR/rt-$R_NAME.transferts.log"
  cat "$tmp" >> "$log"; rm -f "$tmp"
  rt_log "rattrapage : fin ($nc envoi(s), ${n:-0} suppression(s), code $rc)"
  if [ $rc -eq 0 ]; then
    notify ok "rt-$R_NAME" "Sauvegarde temps réel « $R_NAME »" "Les envois vers la destination fonctionnent de nouveau."
  else
    notify critique "rt-$R_NAME" "Sauvegarde temps réel « $R_NAME » : envoi en échec" "Le rattrapage n'a pas pu tout envoyer vers $R_DEST. Détails : $log"
  fi
  return $rc
}

# --------------------------- service et planification ----------------
# NAS_SANS_SYSTEMD=1 : surveillance lancee en arriere-plan sans service (tests du moteur)
has_systemd() { [ -z "${NAS_SANS_SYSTEMD:-}" ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null; }

rt_unit_install() {
  has_systemd || return 0
  local want
  want=$(printf '[Unit]\nDescription=Sauvegarde temps reel %%i (nas-debian)\nAfter=network-online.target local-fs.target\nWants=network-online.target\n\n[Service]\nExecStart=%s temps-reel surveiller %%i\nRestart=always\nRestartSec=10\n\n[Install]\nWantedBy=multi-user.target\n' "$SELF")
  if [ "$(cat "$RT_UNIT" 2>/dev/null)" != "$want" ]; then
    printf '%s\n' "$want" > "$RT_UNIT"
    systemctl daemon-reload
  fi
}

rt_active() {  # rt_active <nom>
  if has_systemd; then systemctl is-active --quiet "nas-temps-reel@$1"; return; fi
  local p; p=$(cat "$STATE_DIR/rt-$1.pid" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

rt_start() {
  rt_get "$1" || die "sauvegarde temps reel '$1' introuvable."
  rt_unit_install
  if has_systemd; then
    systemctl enable --now "nas-temps-reel@$R_NAME" >/dev/null 2>&1 || die "le service ne demarre pas : journalctl -u nas-temps-reel@$R_NAME -n 50"
  else
    rt_active "$R_NAME" || { nohup setsid "$SELF" temps-reel surveiller "$R_NAME" >/dev/null 2>&1 < /dev/null & }
  fi
  sleep 1
  if rt_active "$R_NAME"; then vert "Sauvegarde temps reel « $R_NAME » : surveillance active."; else rouge "La surveillance de « $R_NAME » ne demarre pas (voir $RT_LOG_DIR/$R_NAME.log)."; return 1; fi
}

rt_stop() {  # rt_stop <nom> [garder-auto]
  local p
  if has_systemd; then
    if [ "${2:-}" = garder-auto ]; then systemctl stop "nas-temps-reel@$1" 2>/dev/null; else systemctl disable --now "nas-temps-reel@$1" >/dev/null 2>&1; fi
  fi
  p=$(cat "$STATE_DIR/rt-$1.pid" 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then pkill -TERM -s "$(ps -o sid= -p "$p" | tr -d ' ')" 2>/dev/null || kill "$p"; fi
  rm -f "$STATE_DIR/rt-$1.pid"
  vert "Sauvegarde temps reel « $1 » : surveillance arretee."
}

rt_gen_cron() {
  # variables R_* locales : la sauvegarde en cours de traitement par l'appelant reste intacte
  local n line m R_NAME R_DIRS R_DEST R_DEL R_RET R_EXCL R_TYPES R_DELAY R_CATCH R_ANOM R_PERF R_BW
  local -a R_SRCS
  {
    echo "# Genere automatiquement par nas-debian (rattrapage des sauvegardes temps reel)"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    for n in $(rt_names); do
      rt_get "$n" || continue
      m="$R_CATCH"
      [ "$m" -gt 0 ] 2>/dev/null || continue
      if [ "$m" -lt 60 ]; then line="*/$m * * * *"
      elif [ "$m" -lt 1440 ]; then line="17 */$((m / 60)) * * *"
      else line="17 4 * * *"; fi
      echo "$line root $SELF temps-reel rattrapage $n >/dev/null 2>&1"
    done
  } > "$RT_CRON.new"
  chmod 644 "$RT_CRON.new"; mv -f "$RT_CRON.new" "$RT_CRON"
  if [ ! -f /etc/logrotate.d/nas-temps-reel ]; then
    printf '%s/*.log {\n  weekly\n  rotate 4\n  compress\n  missingok\n  notifempty\n  copytruncate\n}\n%s/rt-*.transferts.log {\n  weekly\n  rotate 1\n  missingok\n  notifempty\n  copytruncate\n}\n' "$RT_LOG_DIR" "$STATE_DIR" > /etc/logrotate.d/nas-temps-reel
  fi
}

# --------------------------- configuration ---------------------------
rt_api_save() {  # nouveau|modif NOM DOSSIERS DESTINATION SUPPRESSION CORBEILLE EXCLUSIONS TYPES DELAI RATTRAPAGE ANOMALIE [MEMOIRE] [DEBIT]
  local kind="$1"; shift
  [ $# -ge 10 ] && [ $# -le 12 ] || die "usage : nas-debian temps-reel save <nouveau|modif> NOM DOSSIERS DESTINATION SUPPRESSION CORBEILLE EXCLUSIONS TYPES DELAI RATTRAPAGE ANOMALIE [MEMOIRE] [DEBIT]"
  R_NAME="$1" R_DIRS="$2" R_DEST="$3" R_DEL="$4" R_RET="$5" R_EXCL="$6" R_TYPES="$7" R_DELAY="$8" R_CATCH="$9" R_ANOM="${10}" R_PERF="${11:-}" R_BW="${12:-}"
  [[ "$R_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "nom invalide (lettres, chiffres, - et _)."
  case "$kind" in
    nouveau) rt_exists "$R_NAME" && die "une sauvegarde temps reel '$R_NAME' existe deja." ;;
    modif)   rt_exists "$R_NAME" || die "sauvegarde temps reel '$R_NAME' introuvable." ;;
    *)       die "type inconnu : $kind" ;;
  esac
  local s b all="" n=0
  local -A vus=()
  IFS=';' read -ra R_SRCS <<< "$R_DIRS"
  for s in "${R_SRCS[@]}"; do
    s="${s%/}"
    [ -n "$s" ] || continue
    [[ "$s" == /* && "$s" != *"|"* ]] || die "dossier invalide : $s"
    [ -d "$s" ] || die "dossier introuvable : $s"
    b="${s##*/}"; [ -n "${vus[$b]:-}" ] && die "deux dossiers surveilles portent le meme nom ($b) : renomme l'un d'eux."
    vus[$b]=1; all="${all:+$all;}$s"; n=$((n + 1))
  done
  [ $n -gt 0 ] || die "choisis au moins un dossier a surveiller."
  R_DIRS="$all"; IFS=';' read -ra R_SRCS <<< "$R_DIRS"
  [[ "$R_DEST" =~ ^[A-Za-z0-9_-]+:[^|]*$ ]] || die "destination invalide (remote:chemin)."
  [[ "${R_DEST#*:}" == *..* ]] && die "destination invalide."
  [[ "$R_DEL" =~ ^(directe|corbeille|copie)$ ]] || die "suppression invalide (directe, corbeille ou copie)."
  [[ "$R_RET" =~ ^[0-9]+$ ]] || die "nombre de jours de corbeille invalide."
  [ "$R_DEL" = corbeille ] && [ "$R_RET" -eq 0 ] && die "corbeille : indique un nombre de jours (1 au minimum)."
  [[ "$R_EXCL$R_TYPES" != *"|"* ]] || die "caractere | interdit dans les filtres."
  [[ "$R_DELAY" =~ ^[0-9]+$ ]] && [ "$R_DELAY" -ge 1 ] && [ "$R_DELAY" -le 3600 ] || die "delai de regroupement invalide (1 a 3600 s)."
  [[ " ${RT_CATCH_OK[*]} " == *" $R_CATCH "* ]] || die "rattrapage invalide (${RT_CATCH_OK[*]} minutes)."
  [[ "$R_ANOM" =~ ^[0-9]+$ ]] || die "seuil d'anomalie invalide (nombre de fichiers, 0 = desactive)."
  valid_perf "$R_PERF" || die "reglage memoire invalide."
  [[ -z "$R_BW" || "$R_BW" =~ ^[0-9A-Za-z:.,\ -]+$ ]] || die "limite de debit invalide (ex. 5M)."
  need_rclone
  [ "${R_DEST%%:*}" = "$CRYPT" ] && ensure_crypt
  rclone listremotes 2>/dev/null | grep -x "${R_DEST%%:*}:" >/dev/null || die "remote '${R_DEST%%:*}' introuvable (rclone listremotes)."
  local o
  for o in $(rt_names); do
    [ "$o" = "$R_NAME" ] && continue
    [ "$(grep -m1 "^$o|" "$RT_CONF" | cut -d'|' -f3)" = "$R_DEST" ] && jaune "Attention : la sauvegarde temps reel '$o' envoie deja vers $R_DEST."
  done
  rt_save_line; rt_gen_cron
  logl "temps reel $R_NAME : configuration enregistree ($R_DIRS -> $R_DEST, $R_DEL)"
  vert "Sauvegarde temps reel « $R_NAME » enregistree : ${R_DIRS//;/, } -> $R_DEST"
  if [ "$kind" = nouveau ] || rt_active "$R_NAME"; then
    rt_active "$R_NAME" && rt_stop "$R_NAME" garder-auto >/dev/null
    rt_start "$R_NAME"
  fi
}

rt_api_delete() {  # rt_api_delete <nom> [effacer-destination]
  rt_get "$1" || die "sauvegarde temps reel '$1' introuvable."
  rt_stop "$R_NAME" >/dev/null
  local tmp; tmp=$(mktemp); grep -v "^$R_NAME|" "$RT_CONF" > "$tmp"; cat "$tmp" > "$RT_CONF"; rm -f "$tmp"
  rt_gen_cron
  if [ "${2:-}" = effacer-destination ]; then
    need_rclone
    local s; for s in "${R_SRCS[@]}"; do rclone purge "$(rt_dest_of "$s")" -q 2>/dev/null; done
    rclone purge "$(rt_trash_root)" -q 2>/dev/null
    vert "Fichiers effaces de la destination : $R_DEST"
  else
    jaune "Les fichiers deja envoyes sont conserves : $R_DEST"
  fi
  rm -f "$STATE_DIR/rt-$R_NAME".* "$STATE_DIR/alertes/rt-$R_NAME" "$STATE_DIR/alertes/rt-pause-$R_NAME" "$STATE_DIR/alertes/rt-service-$R_NAME"
  logl "temps reel $R_NAME : supprimee"
  vert "Sauvegarde temps reel « $R_NAME » supprimee."
}

# Reprise apres une pause : l'utilisateur confirme que les changements sont voulus.
# Le rattrapage suivant n'applique pas le garde-fou (une fois) et la fenetre de
# detection de la surveillance repart de zero ; ce rattrapage est lance tout de suite.
rt_resume() {
  rt_get "$1" || die "sauvegarde temps reel '$1' introuvable."
  rt_paused || { vert "« $R_NAME » n'est pas en pause."; return 0; }
  date +%s > "$STATE_DIR/rt-$R_NAME.reprise"
  touch "$STATE_DIR/rt-$R_NAME.autorise"
  rm -f "$STATE_DIR/rt-$R_NAME.pause"
  rt_log "reprise demandee : l'etat actuel du dossier va etre repercute"
  notify ok "rt-pause-$R_NAME" "Sauvegarde temps réel « $R_NAME »" "La sauvegarde a repris."
  nohup setsid "$SELF" temps-reel rattrapage "$R_NAME" >/dev/null 2>&1 < /dev/null &
  vert "Sauvegarde temps reel « $R_NAME » reprise : le rattrapage repercute maintenant l'etat actuel du dossier."
}

rt_list() {
  local n
  [ -n "$(rt_names)" ] || { jaune "Aucune sauvegarde temps reel."; return 0; }
  for n in $(rt_names); do
    rt_get "$n"
    printf '%-14s %-8s %-10s %s -> %s\n' "$n" "$(rt_active "$n" && echo actif || echo arrete)" "$R_DEL" "${R_DIRS//;/, }" "$R_DEST"
    rt_paused && echo "               EN PAUSE : $(cut -d'|' -f2- "$STATE_DIR/rt-$n.pause")"
  done
}

temps_reel_main() {
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  mkdir -p "$CONF_DIR" "$STATE_DIR" "$RT_LOG_DIR"
  case "${1:-liste}" in
    liste)       rt_list ;;
    save)        shift; rt_api_save "$@" ;;
    supprimer)   [ -n "${2:-}" ] || die "usage : temps-reel supprimer <NOM> [effacer-destination]"; rt_api_delete "$2" "${3:-}" ;;
    demarrer)    rt_start "${2:-}" ;;
    arreter)     rt_stop "${2:-}" ;;
    redemarrer)  rt_stop "${2:-}" garder-auto >/dev/null; rt_start "${2:-}" ;;
    reprendre)   rt_resume "${2:-}" ;;
    pause)       rt_get "${2:-}" || die "introuvable."; rt_pause "Mise en pause manuelle"; vert "En pause." ;;
    rattrapage)  rt_catchup "${2:-}" ;;
    envoi-complet) rt_catchup "${2:-}" initial ;;
    surveiller)  rt_watch "${2:-}" ;;
    gen-cron)    rt_gen_cron ;;
    redemarrer-tout)
      local n; for n in $(rt_names); do rt_active "$n" && { rt_stop "$n" garder-auto >/dev/null; rt_start "$n" >/dev/null; }; done; echo "Surveillances redemarrees." ;;
    *) die "usage : nas-debian temps-reel liste | save ... | supprimer | demarrer | arreter | redemarrer | pause | reprendre | rattrapage | envoi-complet <NOM>" ;;
  esac
}

# =========================== Installation / migration ================
install_base() {
  mkdir -p "$CONF_DIR" "$STATE_DIR/alertes"
  [ -f "$JOBS" ] || echo "# NOM|SOURCE|DOSSIER|MODE(sync/copy/versions)|CHIFFRE(oui/non)|HORAIRE(HH:MM/manuel)|CORBEILLE_JOURS|DEBIT|MEMOIRE|DESTINATIONS|ROTATION" > "$JOBS"
  touch "$LOG"
  [ -f /etc/logrotate.d/nas-backup ] || printf "%s {\n  weekly\n  rotate 8\n  compress\n  missingok\n  notifempty\n  copytruncate\n}\n" "$LOG" > /etc/logrotate.d/nas-backup
  # anciens noms : liens vers ce script (sauf anciens scripts encore en place : voir « migrer »)
  local n
  for n in "${LEGACY_NAMES[@]}"; do
    if [ ! -e "$BIN_DIR/$n" ] || [ -L "$BIN_DIR/$n" ]; then ln -sfn nas-debian "$BIN_DIR/$n"; fi
  done
  # verification horaire (destinations, disques, alertes) : avec le script (pas seulement avec Home Assistant)
  [ -L "$BIN_DIR/nas-check" ] && check_cron
  echo "Installation de base prete ($MACHINE)."
}

is_legacy() { [ -f "$BIN_DIR/$1" ] && [ ! -L "$BIN_DIR/$1" ]; }

# Ancienne synchro des cameras (install-cam-sync.sh) -> CAM_SRC, CAM_DEST, CAM_MIN, CAM_NEW
cam_legacy_read() {
  CAM_SRC=$(grep -m1 '^SRC=' "$BIN_DIR/cam-sync.sh" | cut -d'"' -f2)
  CAM_DEST=$(grep -m1 '^DEST=' "$BIN_DIR/cam-sync.sh" | cut -d'"' -f2); CAM_DEST="${CAM_DEST:-gcrypt:}"
  CAM_MIN=$(grep -oE '^\*/[0-9]+' /etc/cron.d/cam-sync 2>/dev/null | tr -d '*/'); CAM_MIN="${CAM_MIN:-15}"
  [[ " ${RT_CATCH_OK[*]} " == *" $CAM_MIN "* ]] || CAM_MIN=15
  CAM_NEW=Cameras; local i=2
  while rt_exists "$CAM_NEW"; do CAM_NEW="Cameras$i"; i=$((i + 1)); done
}

cam_legacy_migrate() {  # cam_legacy_migrate <dossier des anciens fichiers>
  local dest="$1" p i f
  cam_legacy_read
  [ -n "$CAM_SRC" ] || { rouge "Dossier des cameras introuvable dans cam-sync.sh : synchro des cameras laissee en place."; return 1; }
  # attendre la fin de l'envoi d'une video (10 min au plus) et d'un rattrapage en cours
  for i in $(seq 600); do
    p=""
    for f in $(cat /sys/fs/cgroup/system.slice/cam-sync.service/cgroup.procs 2>/dev/null); do
      [ "$(cat "/proc/$f/comm" 2>/dev/null)" = rclone ] && p=1
    done
    [ -z "$p" ] && break
    [ "$i" = 1 ] && jaune "Envoi d'une video en cours : attente de la fin..."
    sleep 1
  done
  flock -w 900 /run/cam-sync-full.lock true 2>/dev/null
  systemctl disable --now cam-sync >/dev/null 2>&1
  mkdir -p "$dest"
  for f in "$BIN_DIR/cam-sync.sh" "$BIN_DIR/cam-sync-catchup.sh" /etc/systemd/system/cam-sync.service /etc/cron.d/cam-sync /etc/logrotate.d/cam-sync; do
    [ -e "$f" ] && mv -f "$f" "$dest/"
  done
  has_systemd && systemctl daemon-reload
  R_NAME="$CAM_NEW" R_DIRS="${CAM_SRC%/}" R_DEST="$CAM_DEST" R_DEL=directe R_RET=0 R_EXCL="" R_TYPES="" R_DELAY=5 R_CATCH="$CAM_MIN" R_ANOM=0 R_PERF="" R_BW=""
  R_SRCS=("$R_DIRS")
  rt_save_line; rt_gen_cron
  cat "$STATE_DIR/cam-transferts.log.1" "$STATE_DIR/cam-transferts.log" 2>/dev/null >> "$STATE_DIR/rt-$CAM_NEW.transferts.log"
  agent_conf_set CAM_JOB "$CAM_NEW"
  vert "OK : cameras -> sauvegarde temps reel « $CAM_NEW »"
  rt_start "$CAM_NEW" || true
}

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
  [ -f "$NOTIFY_CONF" ] && echo "- alertes Home Assistant conservees ($(sed -n 's/^HA_URL=//p' "$NOTIFY_CONF" | head -n 1 | tr -d "\"'"))"
  [ -f /root/.config/mosquitto_pub ] && echo "- connexion MQTT conservee"
  if [ -f "$BIN_DIR/cam-sync.sh" ]; then
    todo=1; cam_legacy_read
    echo "- synchro des cameras (cam-sync) : reprise comme sauvegarde temps reel « $CAM_NEW » ($CAM_SRC -> $CAM_DEST,"
    echo "  suppressions directes comme avant, rattrapage toutes les $CAM_MIN min, historique des envois conserve)"
  fi
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
  [ -f "$BIN_DIR/cam-sync.sh" ] && cam_legacy_migrate "$dest"
  logl "migration vers nas-debian $SCRIPT_VERSION (anciens scripts dans $dest)"
  vert "Migration terminee. Anciens scripts gardes dans $dest"
}

# =========================== Sauvegardes (nas-backup) ================
need_rclone() {
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  command -v rclone >/dev/null || die "rclone n'est pas installe (nas-debian outils installer)."
}

# Menu interactif : sauvegardes vers Google Drive uniquement
need_gdrive() {
  need_rclone
  rclone listremotes 2>/dev/null | grep -x "${GDRIVE}:" >/dev/null || die "remote '${GDRIVE}' introuvable : connecte Google Drive depuis NAS Manager (page Installation)."
}

nb_init() {
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  mkdir -p "$CONF_DIR" "$STATE_DIR"
  [ -f "$JOBS" ] || echo "# NOM|SOURCE|DOSSIER|MODE(sync/copy/versions)|CHIFFRE(oui/non)|HORAIRE(HH:MM/manuel)|CORBEILLE_JOURS|DEBIT|MEMOIRE|DESTINATIONS|ROTATION" > "$JOBS"
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

ensure_crypt() { ensure_crypt_for "$GDRIVE"; }

job_names() { grep -v '^#' "$JOBS" | grep -v '^$' | cut -d'|' -f1; }
job_exists() { grep -q "^$1|" "$JOBS"; }

# Une sauvegarde = une ligne de jobs.conf :
#   NOM|SOURCE|DOSSIER|MODE(sync, copy, versions)|CHIFFRE|HORAIRE|CORBEILLE_JOURS|DEBIT|MEMOIRE|DESTINATIONS|ROTATION
# DESTINATIONS : « remote:oui|non » separes par ; (vide = Google Drive, chiffre selon CHIFFRE)
# ROTATION (versions) : jours:semaines:mois:annees de versions gardees
job_get() {
  local line; line=$(grep -m1 "^$1|" "$JOBS") || return 1
  IFS='|' read -r J_NAME J_SRC J_SUB J_MODE J_ENC J_SCHED J_RET J_BW J_PERF J_DESTS J_ROT _ <<< "$line"
  J_BW="${J_BW:-}"; J_PERF="${J_PERF:-}"; J_DESTS="${J_DESTS:-}"; J_ROT="${J_ROT:-}"
  [ "$J_MODE" = versions ] && [ -z "$J_ROT" ] && J_ROT="$DEFAULT_ROT"
  return 0
}

job_save() {
  local tmp; tmp=$(mktemp)
  grep -v "^$J_NAME|" "$JOBS" > "$tmp"
  echo "$J_NAME|$J_SRC|$J_SUB|$J_MODE|$J_ENC|$J_SCHED|$J_RET|${J_BW:-}|${J_PERF:-}|${J_DESTS:-}|${J_ROT:-}" >> "$tmp"
  cat "$tmp" > "$JOBS"; rm -f "$tmp"
}

job_del() {
  local tmp; tmp=$(mktemp)
  grep -v "^$1|" "$JOBS" > "$tmp"; cat "$tmp" > "$JOBS"; rm -f "$tmp"
  rm -rf "$STATE_DIR/$1.status" "$STATE_DIR/$1.lastok" "$STATE_DIR/alertes/job-$1" "$STATE_DIR/alertes/retard-$1" \
        "$STATE_DIR/$1.bilan.json" "$STATE_DIR/$1.run.log" "$STATE_DIR/$1.running" "$STATE_DIR/$1.maxage" \
        "$STATE_DIR/$1.d" "$STATE_DIR/$1.dest" "$STATE_DIR/$1.run.all" "$STATE_DIR/alertes/versions-$1" "$STATE_DIR/$1.entretien.json"
}

# Destinations de la sauvegarde chargee -> JD_R (remotes), JD_E (oui / non)
job_dests() {
  JD_R=(); JD_E=()
  local d list="${J_DESTS:-}"
  [ -n "$list" ] || list="$GDRIVE:$J_ENC"
  local IFS=';'
  for d in $list; do
    [ -n "$d" ] || continue
    JD_R+=("${d%%:*}"); JD_E+=("${d#*:}")
  done
}

# Emplacements sur une destination
dest_path()  { if [ "$2" = oui ]; then echo "$(crypt_of "$1"):$3"; else echo "$1:${PLAIN_FOLDER}/$3"; fi; }               # <remote> <oui|non> <dossier>
trash_path() { if [ "$2" = oui ]; then echo "$(crypt_of "$1"):_corbeille/$3"; else echo "$1:${PLAIN_FOLDER}/_corbeille/$3"; fi; }  # <remote> <oui|non> <nom>
repo_path()  { echo "rclone:$1:${VERSIONS_FOLDER}/$2"; }                                                                    # <remote> <dossier>
# Google Drive seul (menu interactif, anciennes sauvegardes)
dest_of()  { dest_path "$GDRIVE" "$1" "$2"; }
trash_of() { trash_path "$GDRIVE" "$1" "$2"; }

# Destination n° <i> (0 = la premiere) de la sauvegarde chargee -> DI_R, DI_E
job_dest_at() {
  job_dests
  local i="${1:-0}"
  [[ "$i" =~ ^[0-9]+$ ]] || i=0
  [ "$i" -lt "${#JD_R[@]}" ] || die "destination n° $i introuvable pour '$J_NAME'."
  DI_R="${JD_R[$i]}"; DI_E="${JD_E[$i]}"
}

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
    # sauvegardes versionnees : nettoyage et controle des depots chaque dimanche
    if grep -qE '^[^#|][^|]*\|[^|]*\|[^|]*\|versions\|' "$JOBS" 2>/dev/null; then
      echo "15 5 * * 0 root $SELF versions entretien >/dev/null 2>&1"
    fi
    # rapport periodique
    if [ -f "$RAPPORT_CONF" ]; then
      local FREQ=non JOUR=1 HEURE=08:30
      # shellcheck disable=SC1090
      . "$RAPPORT_CONF"
      case "$FREQ" in
        hebdo)   echo "$((10#${HEURE##*:})) $((10#${HEURE%%:*})) * * $((JOUR % 7)) root $SELF rapport envoyer hebdo >/dev/null 2>&1" ;;
        mensuel) echo "$((10#${HEURE##*:})) $((10#${HEURE%%:*})) 1 * * root $SELF rapport envoyer mensuel >/dev/null 2>&1" ;;
      esac
    fi
    # kit de secours : chaque jour (envoye seulement s'il a change, ou chaque semaine)
    if [ -n "$(job_names)" ] || [ -n "$(rt_names)" ]; then
      echo "40 5 * * * root $SELF secours sauvegarder >/dev/null 2>&1"
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
  local n s sub m e sch r bw pf ds st mode where
  while IFS='|' read -r n s sub m e sch r bw pf ds _ || [ -n "$n" ]; do
    [[ -z "$n" || "$n" == \#* ]] && continue
    st="jamais"; [ -f "$STATE_DIR/$n.status" ] && st=$(cat "$STATE_DIR/$n.status")
    mode="copie"; [ "$m" = sync ] && mode="miroir"; [ "$m" = versions ] && mode="versions"
    if [ -n "$ds" ]; then where="${ds//;/ + }"; else where="$( [ "$e" = oui ] && echo "$CRYPT_FOLDER" || echo "$PLAIN_FOLDER")/$sub"; fi
    printf "%-14s %-24s %-24s %-7s %-7s %-8s %s\n" "$n" "$(short "$s")" "$where" "$mode" "$e" "$sch" "$st"
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
  J_NAME="" J_SRC="" J_SUB="" J_MODE="" J_ENC="" J_SCHED="" J_RET="" J_BW="" J_PERF="" J_DESTS="" J_ROT=""
  need_gdrive
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
  if [ "$J_MODE" = versions ] || [[ -n "$J_DESTS" && "$J_DESTS" != "$GDRIVE:"* ]] || [[ "$J_DESTS" == *";"* ]]; then
    jaune "La sauvegarde « $J_NAME » (versionnee ou vers d'autres destinations) se modifie depuis NAS Manager."
    return
  fi
  J_DESTS=""
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

# Bilan d'une destination d'apres son journal (rclone, ou restic en JSON)
#   -> <sortie>.json : fichiers envoyes, volume, erreurs, version enregistree...
bilan_dest() {  # bilan_dest <journal> <sortie> <debut> <code> <remote> <oui|non> [versions.json]
  python3 - "$1" "$J_SRC" "$2" "$3" "$4" "${RD_RAM:-0}" "$5" "$6" "${7:-}" <<'PY' 2>/dev/null
import json, os, re, sys, time
log, src, out = sys.argv[1:4]
t0, rc, ram = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6] or 0)
remote, enc, vfile = sys.argv[7], sys.argv[8], sys.argv[9]
act = re.compile(r" INFO\s+: (.+): (Copied \((new|replaced existing)\)|Deleted|Moved \(server-side\))")
b = {"nouveaux": 0, "remplaces": 0, "retires": 0, "erreurs": 0, "octets": 0}
err, snap = "", ""
try:
    with open(log, errors="ignore") as f:
        for line in f:
            if line.startswith("{"):
                try:
                    j = json.loads(line)
                except ValueError:
                    continue
                t = j.get("message_type")
                if t == "summary":
                    b["nouveaux"] = j.get("files_new", 0); b["remplaces"] = j.get("files_changed", 0)
                    b["octets"] = j.get("data_added", 0); snap = (j.get("snapshot_id") or "")[:8]
                elif t == "error":
                    b["erreurs"] += 1
                    e = j.get("error")
                    err = "%s : %s" % (j.get("item", ""), e.get("message", "") if isinstance(e, dict) else e)
                continue
            if (" ERROR : " in line and "Attempt " not in line) or line.startswith("Fatal:") or "CRITICAL" in line:
                b["erreurs"] += 1
                err = re.sub(r"^[0-9/ :]+", "", line.strip())
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
d = {"destination": remote, "chiffre": enc == "oui", "debut": t0, "fin": fin, "code": rc,
     "fichiers_envoyes": b["nouveaux"] + b["remplaces"], "nouveaux": b["nouveaux"], "remplaces": b["remplaces"],
     "retires": b["retires"], "erreurs": b["erreurs"], "volume_octets": b["octets"]}
if ram:
    d["ram_max_mo"] = ram
if err and rc != 0:
    d["erreur"] = err[:300]
if snap:
    d["instantane"] = snap
try:
    v = json.load(open(vfile))
    d["versions"] = v.get("nb", 0)
    if v.get("derniere"):
        d["derniere_version"] = v["derniere"]
except (OSError, ValueError):
    pass
json.dump(d, open(out, "w"), ensure_ascii=False)
PY
}

# Bilan de l'execution (toutes destinations) -> $STATE_DIR/<nom>.bilan.json
# Affiche deux lignes : resume ("12 fichiers envoyes (1.3 Go)", "aucun changement"...), puis
# les destinations en echec (vide si aucune).
bilan_merge() {  # bilan_merge <dossier des bilans> <debut> <code>
  python3 - "$1" "$STATE_DIR/$J_NAME.bilan.json" "$2" "$3" "${J_RET:-0}" "$J_MODE" <<'PY' 2>/dev/null
import glob, json, os, sys, time
dd, out = sys.argv[1], sys.argv[2]
t0, rc, ret, mode = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5] or 0), sys.argv[6]
dests = []
for p in sorted(glob.glob(os.path.join(dd, "[0-9]*.json")), key=lambda p: int(os.path.basename(p).split(".")[0])):
    if p.endswith(".versions.json"):
        continue
    try:
        dests.append(json.load(open(p)))
    except (OSError, ValueError):
        pass
fin = int(time.time())
first = dests[0] if dests else {}
d = {"debut": t0, "fin": fin, "duree_min": round((fin - t0) / 60, 1), "code": rc}
for k in ("fichiers_envoyes", "nouveaux", "remplaces", "retires", "volume_octets"):
    d[k] = first.get(k, 0)
d["erreurs"] = sum(x.get("erreurs", 0) for x in dests)
ram = max([x.get("ram_max_mo", 0) for x in dests] or [0])
if ram:
    d["ram_max_mo"] = ram
if mode == "versions" and first.get("versions") is not None:
    d["versions"] = first["versions"]
d["destinations"] = dests
json.dump(d, open(out, "w"), ensure_ascii=False)
v = float(d["volume_octets"])
for u in ("o", "Ko", "Mo", "Go", "To"):
    if v < 1024 or u == "To":
        break
    v /= 1024
vol = "%d o" % v if u == "o" else "%.1f %s" % (v, u)
pl = lambda n: "s" if n > 1 else ""
env = d["fichiers_envoyes"]
if mode == "versions":
    txt = ("%d fichier%s nouveau%s ou modifié%s (%s ajoutés), version enregistrée" % (env, pl(env), "x" if env > 1 else "", pl(env), vol)) if env else "aucun changement, version enregistrée"
elif env == 0 and d["retires"] == 0:
    txt = "aucun changement"
else:
    txt = ("%d fichier%s envoyé%s (%s)" % (env, pl(env), pl(env), vol)) if env else "rien à envoyer"
    if d["retires"]:
        r = d["retires"]
        txt += ", %d fichier%s supprimé%s de la destination" % (r, pl(r), pl(r))
        if ret > 0:
            txt += " (gardé%s %d j dans la corbeille)" % (pl(r), ret)
if len(dests) > 1:
    ok = sum(1 for x in dests if x.get("code") == 0)
    txt += " · %d/%d destinations à jour" % (ok, len(dests))
ko = ["%s (%s)" % (x["destination"], x.get("erreur", "code %s" % x.get("code"))) for x in dests if x.get("code") != 0]
print(txt)
print(" ; ".join(ko)[:400])
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

# Miroir ou copie vers une destination -> code ; RD_RAM = pic de memoire de rclone
run_rclone_dest() {  # run_rclone_dest <remote> <oui|non> <jour> <journal>
  local r="$1" e="$2" jour="$3" runlog="$4" rc dest trash
  local jstop="$STATE_DIR/$J_NAME.stop"
  [ "$e" = oui ] && ensure_crypt_for "$r" >/dev/null
  dest=$(dest_path "$r" "$e" "$J_SUB"); trash=$(trash_path "$r" "$e" "$J_NAME")
  local -a opts=("${EXCLUDES[@]}" --log-file "$runlog" --log-level INFO)
  if [ -t 1 ]; then opts+=(-P); else opts+=(--stats 30s); fi
  [ -n "${J_BW:-}" ] && opts+=(--bwlimit "$J_BW")
  perf_load "$J_PERF"
  nb_transfer "$dest" "$trash" "$jour" "$runlog" "${opts[@]}"; rc=$?
  RD_RAM=$RCL_MAX
  # manque de memoire : nouvel essai avec un seul fichier a la fois
  if [ "$rc" -ne 0 ] && [ ! -f "$STOPF" ] && [ ! -f "$jstop" ] && { [ "$rc" -ge 128 ] || oom_in "$runlog"; }; then
    logl "$J_NAME : manque de memoire (code $rc, $RD_RAM Mo) : reprise avec 1 fichier a la fois"
    jaune "Manque de memoire : reprise avec 1 fichier a la fois."
    # le journal du premier essai va dans le journal general ; le bilan ne compte que la reprise
    cat "$runlog" >> "$LOG"; : > "$runlog"
    perf_load econome
    nb_transfer "$dest" "$trash" "$jour" "$runlog" "${opts[@]}"; rc=$?
    [ "$RCL_MAX" -gt "$RD_RAM" ] && RD_RAM=$RCL_MAX
    perf_load "$J_PERF"
  fi
  if [ "$J_MODE" = sync ] && [ "${J_RET:-0}" -gt 0 ] && [ ! -f "$STOPF" ] && [ ! -f "$jstop" ]; then
    trash_purge "$trash" "$J_RET"
  fi
  return $rc
}

# --------------------------- Sauvegardes versionnees (restic) ---------
need_restic() {
  command -v restic >/dev/null && return 0
  echo "$(date '+%Y/%m/%d %H:%M:%S') ERROR : restic n'est pas installe (NAS Manager > Installation > Outils)"
  return 1
}

restic_pass_ensure() {
  [ -s "$RESTIC_PASS" ] && return 0
  mkdir -p "$CONF_DIR"
  ( umask 077; openssl rand -base64 30 | tr -d '\n' > "$RESTIC_PASS" )
  logl "mot de passe des sauvegardes versionnees cree ($RESTIC_PASS)"
}

# Environnement restic pour la sauvegarde chargee et une destination -> RST (options)
restic_prep() {  # restic_prep <remote>
  restic_pass_ensure
  mkdir -p "$RESTIC_CACHE"
  export RESTIC_PASSWORD_FILE="$RESTIC_PASS" RESTIC_CACHE_DIR="$RESTIC_CACHE" RESTIC_PROGRESS_FPS=0.2
  local a="serve restic --stdio --b2-hard-delete"
  [ -n "${J_BW:-}" ] && a="$a --bwlimit \"$J_BW\""
  RST=(-r "$(repo_path "$1" "$J_SUB")" -o "rclone.args=$a")
}

# Depot pret (cree s'il n'existe pas) -> 0 ; messages sur la sortie
restic_ready() {
  local out rc
  out=$(restic "${RST[@]}" cat config 2>&1 >/dev/null < /dev/null); rc=$?
  [ $rc -eq 0 ] && return 0
  if [ $rc -eq 12 ] || echo "$out" | grep -qiE 'wrong password|no key found'; then
    echo "$(date '+%Y/%m/%d %H:%M:%S') ERROR : mot de passe du depot refuse (${RST[1]}) : restaure le kit de secours, ou les mots de passe notes."
    return 1
  fi
  if [ $rc -eq 10 ] || echo "$out" | grep -qiE 'does not exist|unable to open config|is there a repository'; then
    echo "$(date '+%Y/%m/%d %H:%M:%S') NOTICE: creation du depot de versions ${RST[1]}"
    restic "${RST[@]}" init 2>&1 < /dev/null
    return $?
  fi
  echo "$(date '+%Y/%m/%d %H:%M:%S') ERROR : depot ${RST[1]} inaccessible : $(echo "$out" | grep -v '^$' | tail -n 2 | tr '\n' ' ')"
  return 1
}

# Regles de rotation (jours:semaines:mois:annees) -> ROTF (options de restic forget)
rot_flags() {
  local d w m y
  IFS=':' read -r d w m y <<< "${1:-$DEFAULT_ROT}"
  ROTF=(--keep-last 1 --keep-within 1d)
  [ "${d:-0}" -gt 0 ] 2>/dev/null && ROTF+=(--keep-daily "$d")
  [ "${w:-0}" -gt 0 ] 2>/dev/null && ROTF+=(--keep-weekly "$w")
  [ "${m:-0}" -gt 0 ] 2>/dev/null && ROTF+=(--keep-monthly "$m")
  [ "${y:-0}" -gt 0 ] 2>/dev/null && ROTF+=(--keep-yearly "$y")
  return 0
}

valid_rot() { [[ "$1" =~ ^[0-9]{1,3}:[0-9]{1,3}:[0-9]{1,3}:[0-9]{1,2}$ ]] && [ "$1" != "0:0:0:0" ]; }

# Versions d'un depot (RST) -> JSON {nb, derniere, premiere}
versions_count() {
  restic "${RST[@]}" snapshots --json --tag "job:$J_NAME" 2>/dev/null < /dev/null | python3 -c '
import json, sys
from datetime import datetime
def ts(s):
    try:
        base, frac = (s.split(".", 1) + [""])[:2]
        tz = frac.lstrip("0123456789") if frac else s[19:]
        return int(datetime.fromisoformat(base[:19] + (tz or "+00:00").replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0
try:
    v = json.load(sys.stdin) or []
except ValueError:
    sys.exit(1)
t = [ts(x.get("time", "")) for x in v]
print(json.dumps({"nb": len(v), "derniere": max(t) if t else None, "premiere": min(t) if t else None}))'
}

# Sauvegarde versionnee vers une destination -> code ; RD_RAM
run_versions_dest() {  # run_versions_dest <remote> <journal> <fichier des versions>
  local r="$1" runlog="$2" vfile="$3" rc
  RD_RAM=0
  need_restic >> "$runlog" || return 1
  restic_prep "$r"
  restic_ready >> "$runlog" 2>&1 || return 1
  restic "${RST[@]}" unlock >/dev/null 2>&1 < /dev/null      # verrous perimes (sauvegarde interrompue)
  gorun "$J_NAME" restic "${RST[@]}" backup "$J_SRC" --json --tag nas-manager --tag "job:$J_NAME" \
    --exclude '@eaDir' --exclude '#recycle' --exclude '.Trash-*' >> "$runlog" 2>&1 < /dev/null; rc=$?
  RD_RAM=$RCL_MAX
  # 3 : version enregistree, mais des fichiers n'ont pas pu etre lus (comptes comme erreurs)
  [ $rc -eq 3 ] && rc=0
  if [ $rc -eq 0 ]; then
    rot_flags "$J_ROT"
    restic "${RST[@]}" forget --tag "job:$J_NAME" "${ROTF[@]}" >> "$runlog" 2>&1 < /dev/null \
      || echo "$(date '+%Y/%m/%d %H:%M:%S') ERROR : rotation des versions impossible" >> "$runlog"
    versions_count > "$vfile" || rm -f "$vfile"
  fi
  return $rc
}

run_job() {
  job_get "$1" || { rouge "Sauvegarde '$1' introuvable."; return 1; }
  local jour rc=0 rcd i n r e t0 ti stopped=0 msg
  jour=$(date +%Y-%m-%d_%H%M)
  local runlog="$STATE_DIR/$J_NAME.run.log" runf="$STATE_DIR/$J_NAME.running" allf="$STATE_DIR/$J_NAME.run.all"
  local dd="${STATE_DIR:?}/${J_NAME:?}.d" jstop="$STATE_DIR/$J_NAME.stop"
  rm -f "$jstop" "${STATE_DIR:?}/${J_NAME:?}.dest"

  if [ ! -d "$J_SRC" ]; then
    rouge "Source introuvable : $J_SRC"; logl "$J_NAME : ECHEC (source introuvable)"
    echo "$(date '+%Y-%m-%d %H:%M') ECHEC" > "$STATE_DIR/$J_NAME.status"
    notify critique "job-$J_NAME" "Sauvegarde « $J_NAME » en échec" "Dossier source introuvable : $J_SRC (disque démonté ?)"
    return 1
  fi
  job_dests; n=${#JD_R[@]}
  perf_load "$J_PERF"

  t0=$(date +%s)
  gras "-> $J_NAME : $(short "$J_SRC")  =>  ${JD_R[*]}"
  logl "$J_NAME : debut ($J_MODE, $n destination(s) : ${JD_R[*]}, memoire $PERF_PROFIL $PERF_MO Mo) $J_SRC"

  : > "$runlog"; : > "$allf"; rm -rf "$dd"; mkdir -p "$dd"
  echo "$$ $t0" > "$runf"
  ha_status
  ( while sleep "$HA_LIVE"; do
      [ -f "$runf" ] && kill -0 $$ 2>/dev/null || exit 0
      ha_status
    done ) 9>&- &
  local live=$!

  for ((i = 0; i < n; i++)); do
    if [ -f "$STOPF" ] || [ -f "$jstop" ]; then stopped=1; break; fi
    r="${JD_R[i]}"; e="${JD_E[i]}"; ti=$(date +%s)
    echo "$((i + 1))|$n|$r|$e" > "$STATE_DIR/$J_NAME.dest"
    : > "$runlog"
    [ "$n" -gt 1 ] && echo "$(date '+%Y/%m/%d %H:%M:%S') NOTICE: === Destination $((i + 1))/$n : $r ===" >> "$runlog"
    RD_RAM=0
    if ! remote_exists "$r"; then
      echo "$(date '+%Y/%m/%d %H:%M:%S') ERROR : destination « $r » introuvable (retiree de rclone ?)" >> "$runlog"; rcd=1
    elif ! msg=$(dest_ready "$r"); then
      echo "$(date '+%Y/%m/%d %H:%M:%S') ERROR : destination « $r » : $msg" >> "$runlog"; rcd=1
    elif [ "$J_MODE" = versions ]; then
      run_versions_dest "$r" "$runlog" "$dd/$i.versions.json"; rcd=$?
    else
      run_rclone_dest "$r" "$e" "$jour" "$runlog"; rcd=$?
    fi
    bilan_dest "$runlog" "$dd/$i.json" "$ti" "$rcd" "$r" "$e" "$dd/$i.versions.json"
    cat "$runlog" >> "$allf"; cat "$runlog" >> "$LOG"
    [ "$rcd" -ne 0 ] && rc=$rcd
  done
  [ "$stopped" = 1 ] && [ "$rc" -eq 0 ] && rc=143

  rm -f "$runf" "${STATE_DIR:?}/${J_NAME:?}.dest"; kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
  mv -f "$allf" "$runlog"
  local resume="" kos=""
  { IFS= read -r resume; IFS= read -r kos; } < <(bilan_merge "$dd" "$t0" "$rc")

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
    logl "$J_NAME : ECHEC (code $rc)${kos:+ - $kos}"; rouge "ECHEC : $J_NAME (voir $LOG)"
    local err="$kos"
    [ -n "$err" ] || err=$(grep -E 'ERROR|CRITICAL|^Fatal' "$runlog" | tail -n 1 | sed -E 's/^[0-9\/ :]+//' | cut -c1-200)
    if oom_in "$runlog"; then
      err="Mémoire insuffisante ($(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("ram_max_mo", "?"))' "$STATE_DIR/$J_NAME.bilan.json" 2>/dev/null) Mo utilisés). Choisis un réglage mémoire plus économe."
    fi
    if [ "$n" -gt 1 ] && [ -n "$kos" ]; then
      notify critique "job-$J_NAME" "Sauvegarde « $J_NAME » en échec" "Destination(s) en échec : $err.${resume:+ Bilan : $resume.}"
    else
      notify critique "job-$J_NAME" "Sauvegarde « $J_NAME » en échec" "Code $rc. ${err:-Voir $LOG sur le NAS.}"
    fi
  fi
  rm -f "$jstop"
  historise "$runlog"
  ha_status
  return "$rc"
}

stop_job() {
  local pat="rclone .*--log-file $STATE_DIR/$1.run.log" rpat="restic .*--tag job:$1( |$)" i
  job_exists "$1" || die "sauvegarde '$1' introuvable."
  running_pat() { pgrep -f "$pat" >/dev/null || pgrep -f "$rpat" >/dev/null; }
  if ! running_pat; then vert "La sauvegarde '$1' n'est pas en cours."; return 0; fi
  touch "$STATE_DIR/$1.stop"
  logl "$1 : arret demande"
  pkill -TERM -f "$pat"; pkill -INT -f "$rpat"
  for i in $(seq 30); do running_pat || break; sleep 1; done
  if running_pat; then pkill -KILL -f "$pat"; pkill -KILL -f "$rpat"; sleep 2; fi
  for i in $(seq 40); do flock -n "/run/nas-backup-$1.lock" true 2>/dev/null && break; sleep 1; done
  vert "Sauvegarde '$1' arretee. Elle reprendra a sa prochaine execution."
}

# Simulation (premiere destination) : ce que la sauvegarde enverrait / supprimerait
api_simulate() {
  job_get "$1" || die "sauvegarde '$1' introuvable."
  local out="$STATE_DIR/$J_NAME.simulation" dest cmd=sync rc=0
  job_dest_at 0
  [ "$J_MODE" = copy ] && cmd=copy
  exec 8>"/run/nas-backup-simulation-$J_NAME.lock"
  flock -n 8 || die "une simulation de '$J_NAME' est deja en cours."
  [ -d "$J_SRC" ] || die "dossier source introuvable : $J_SRC"
  perf_load "$J_PERF"
  printf 'ETAT=en_cours\nDEBUT=%s\n' "$(date +%s)" > "$out.status"
  : > "$out.log"
  if [ "$J_MODE" = versions ]; then
    if ! need_restic >> "$out.log"; then
      rc=1
    else
      restic_prep "$DI_R"
      if restic "${RST[@]}" cat config >/dev/null 2>&1 < /dev/null; then
        gorun "" restic "${RST[@]}" backup "$J_SRC" --dry-run -vv --json --tag nas-manager --tag "job:$J_NAME" \
          --exclude '@eaDir' --exclude '#recycle' --exclude '.Trash-*' >> "$out.log" 2>&1 < /dev/null; rc=$?
        [ $rc -eq 3 ] && rc=0
      else
        # premiere sauvegarde : tout serait envoye
        find "$J_SRC" -type f ! -path '*/@eaDir/*' ! -path '*/#recycle/*' 2>/dev/null \
          | python3 -c 'import json,os,sys
for l in sys.stdin:
    p = l.rstrip("\n")
    try:
        print(json.dumps({"message_type": "verbose_status", "action": "new", "item": p, "data_size": os.path.getsize(p)}))
    except OSError:
        pass' >> "$out.log"
      fi
    fi
  else
    dest=$(dest_path "$DI_R" "$DI_E" "$J_SUB")
    rcl "" "$cmd" "$J_SRC" "$dest" "${EXCLUDES[@]}" --dry-run --log-level NOTICE --log-file "$out.log" < /dev/null; rc=$?
  fi
  python3 - "$out.log" "$out.txt" "$out.status" "$rc" "$J_SRC" <<'PYSIM'
import json, re, sys, time
log, txt, st, rc, src = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
units = {"": 1, "k": 1024, "ki": 1024, "m": 1024**2, "mi": 1024**2, "g": 1024**3, "gi": 1024**3, "t": 1024**4, "ti": 1024**4}
env = sup = octets = 0
summary = None
lines = []
rx = re.compile(r"NOTICE: (.+?): Skipped (copy|delete|move)\b.*?(?:\(size ([\d.]+)\s*([KMGT]?i?)\))?\s*$", re.I)
for l in open(log, errors="ignore"):
    if l.startswith("{"):
        try:
            j = json.loads(l)
        except ValueError:
            continue
        if j.get("message_type") == "verbose_status" and j.get("action") in ("new", "modified") and not j.get("item", "").endswith("/"):
            env += 1
            octets += j.get("data_size", 0) or 0
            it = j.get("item", "")
            lines.append(("+ " if j["action"] == "new" else "~ ") + (it[len(src):].lstrip("/") if it.startswith(src) else it))
        elif j.get("message_type") == "summary":
            summary = j
        continue
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
if summary:
    env = summary.get("files_new", 0) + summary.get("files_changed", 0)
    octets = summary.get("data_added", octets)
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
  local pat="rclone .*--log-file $STATE_DIR/" rpat="restic .*--tag nas-manager" i
  if ! pgrep -f "$pat" >/dev/null && ! pgrep -f "$rpat" >/dev/null && ! pgrep -f "nas-(backup|debian) run" >/dev/null; then
    vert "Aucune sauvegarde en cours."; return 0
  fi
  touch "$STOPF"
  logl "arret demande (nas-backup stop)"
  jaune "Arret demande : aucune nouvelle sauvegarde ne sera lancee."
  pkill -TERM -f "$pat"; pkill -INT -f "$rpat"
  for i in $(seq 30); do pgrep -f "$pat" >/dev/null || pgrep -f "$rpat" >/dev/null || break; sleep 1; done
  if pgrep -f "$pat" >/dev/null || pgrep -f "$rpat" >/dev/null; then
    jaune "rclone ne s'est pas ferme en 30 s : arret force."
    pkill -KILL -f "$pat"; pkill -KILL -f "$rpat"; sleep 2
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
  [ "$J_MODE" = versions ] && { jaune "Sauvegarde versionnee : restauration depuis NAS Manager (choix de la version)."; return; }
  local dest base target
  job_dest_at 0
  dest=$(dest_path "$DI_R" "$DI_E" "$J_SUB")
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
api_save() {  # api_save <nouveau|modif> NOM SOURCE DOSSIER MODE CHIFFRE HORAIRE CORBEILLE [DEBIT] [MEMOIRE] [DESTINATIONS] [ROTATION]
  local kind="$1"; shift
  [ $# -ge 7 ] && [ $# -le 11 ] || die "usage : nas-backup save <nouveau|modif> NOM SOURCE DOSSIER MODE CHIFFRE HORAIRE CORBEILLE [DEBIT] [MEMOIRE] [DESTINATIONS] [ROTATION]"
  J_NAME="$1" J_SRC="${2%/}" J_SUB="$3" J_MODE="$4" J_ENC="$5" J_SCHED="$6" J_RET="$7" J_BW="${8:-}" J_PERF="${9:-}" J_DESTS="${10:-}" J_ROT="${11:-}"
  J_SUB="${J_SUB#/}"; J_SUB="${J_SUB%/}"
  [[ "$J_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "nom invalide (lettres, chiffres, - et _)."
  case "$kind" in
    nouveau) job_exists "$J_NAME" && die "une sauvegarde '$J_NAME' existe deja." ;;
    modif)   job_exists "$J_NAME" || die "sauvegarde '$J_NAME' introuvable." ;;
    *)       die "type inconnu : $kind" ;;
  esac
  [[ "$J_SRC" != *"|"* && -d "$J_SRC" ]] || die "dossier source introuvable : $J_SRC"
  [[ -z "$J_SUB" || "$J_SUB" == *"|"* || "$J_SUB" == *..* || "$J_SUB" == _corbeille* ]] && die "dossier de destination invalide."
  [[ "$J_MODE" =~ ^(sync|copy|versions)$ ]] || die "mode invalide (sync, copy ou versions)."
  [[ "$J_ENC" =~ ^(oui|non)$ ]] || die "chiffrement invalide (oui ou non)."
  valid_sched "$J_SCHED" || die "horaire invalide (HH:MM, HH:MM/JOURS, plusieurs separes par ; ou manuel)."
  [[ -z "$J_BW" || "$J_BW" =~ ^[0-9A-Za-z:.,\ -]+$ ]] || die "limite de debit invalide (ex. 5M)."
  [[ "$J_RET" =~ ^[0-9]+$ ]] || die "nombre de jours de corbeille invalide."
  valid_perf "$J_PERF" || die "reglage memoire invalide (auto, econome, equilibre, performant ou un nombre de Mo >= 64)."
  [ "$J_MODE" = sync ] || J_RET=0
  if [ "$J_MODE" = versions ]; then
    J_ROT="${J_ROT:-$DEFAULT_ROT}"
    valid_rot "$J_ROT" || die "versions gardees invalides (jours:semaines:mois:annees, ex. 7:4:12:0)."
  else
    J_ROT=""
  fi
  # destinations : remote:oui|non separes par ; (versions : toujours chiffrees par restic)
  [ -n "$J_DESTS" ] || J_DESTS="$GDRIVE:$J_ENC"
  local d r e all="" types
  local -A vus=()
  types=$(rclone listremotes --long 2>/dev/null)
  local IFS=';'
  for d in $J_DESTS; do
    [ -n "$d" ] || continue
    r="${d%%:*}"; e="${d#*:}"; [ "$e" = "$d" ] && e="$J_ENC"
    [[ "$r" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || die "destination invalide : $r"
    [[ "$e" =~ ^(oui|non)$ ]] || die "chiffrement invalide pour $r (oui ou non)."
    [ -n "${vus[$r]:-}" ] && die "destination en double : $r"
    echo "$types" | grep -qE "^$r:" || die "destination « $r » introuvable : ajoute-la d'abord (page Destinations)."
    echo "$types" | grep -qE "^$r: +crypt$" && die "« $r » est un remote chiffre : choisis la destination elle-meme."
    vus[$r]=1
    [ "$J_MODE" = versions ] && e=oui
    all="${all:+$all;}$r:$e"
  done
  unset IFS
  [ -n "$all" ] || die "choisis au moins une destination."
  J_DESTS="$all"; job_dests; J_ENC="${JD_E[0]}"
  # meme dossier sur la meme destination qu'une autre sauvegarde
  local n s sub m en sch rt bw pf ds od i
  while IFS='|' read -r n s sub m en sch rt bw pf ds _ || [ -n "$n" ]; do
    [[ -z "$n" || "$n" == \#* || "$n" == "$J_NAME" ]] && continue
    [ -n "$ds" ] || ds="$GDRIVE:$en"
    if [[ "$sub" == "$J_SUB" || "$sub" == "$J_SUB/"* || "$J_SUB" == "$sub/"* ]]; then
      for od in ${ds//;/ }; do
        for ((i = 0; i < ${#JD_R[@]}; i++)); do
          [ "${od%%:*}" = "${JD_R[i]}" ] || continue
          if { [ "$m" = versions ] && [ "$J_MODE" = versions ]; } || { [ "$m" != versions ] && [ "$J_MODE" != versions ] && [ "${od#*:}" = "${JD_E[i]}" ]; }; then
            jaune "Attention : la sauvegarde '$n' utilise deja le dossier '$sub' sur ${JD_R[i]}."
          fi
        done
      done
    fi
  done < "$JOBS"
  local old_where=""
  [ "$kind" = modif ] && old_where=$(job_get "$J_NAME" && job_where)
  if [ "$J_MODE" = versions ]; then
    restic_pass_ensure
    command -v restic >/dev/null || jaune "restic n'est pas encore installe : NAS Manager > Installation > Outils (« Installer ce qui manque »)."
  else
    for ((i = 0; i < ${#JD_R[@]}; i++)); do [ "${JD_E[i]}" = oui ] && ensure_crypt_for "${JD_R[i]}"; done
  fi
  job_save; gen_cron
  logl "$J_NAME : configuration enregistree (application)"
  vert "Sauvegarde '$J_NAME' enregistree -> $(job_where | paste -sd, - | sed 's/,/, /g')"
  if [ -n "$old_where" ] && [ "$old_where" != "$(job_where)" ]; then
    jaune "Les emplacements ont change : les fichiers deja envoyes restent a l'ancien emplacement :"
    comm -23 <(echo "$old_where" | sort) <(job_where | sort) | sed 's/^/  /'
  fi
}

# Emplacements de la sauvegarde chargee (un par ligne)
job_where() {
  local i
  job_dests
  for ((i = 0; i < ${#JD_R[@]}; i++)); do
    if [ "$J_MODE" = versions ]; then echo "${JD_R[i]}:$VERSIONS_FOLDER/$J_SUB (versions)"
    else dest_path "${JD_R[i]}" "${JD_E[i]}" "$J_SUB"; fi
  done
}

api_delete() {
  job_get "$1" || die "sauvegarde '$1' introuvable."
  local i where; where=$(job_where)
  job_dests
  job_del "$J_NAME"; gen_cron
  logl "$J_NAME : sauvegarde supprimee (application)"
  vert "Sauvegarde '$J_NAME' supprimee (plus de planification)."
  if [ "${2:-}" = effacer-drive ]; then
    for ((i = 0; i < ${#JD_R[@]}; i++)); do
      if [ "$J_MODE" = versions ]; then
        rclone purge "${JD_R[i]}:$VERSIONS_FOLDER/$J_SUB" -q 2>/dev/null
      else
        rclone purge "$(dest_path "${JD_R[i]}" "${JD_E[i]}" "$J_SUB")" -q 2>/dev/null
        rclone purge "$(trash_path "${JD_R[i]}" "${JD_E[i]}" "$J_NAME")" -q 2>/dev/null
      fi
    done
    logl "$J_NAME : donnees supprimees des destinations"
    vert "Fichiers effaces :"; echo "$where" | sed 's/^/  /'
  else
    jaune "Les fichiers deja envoyes sont conserves :"; echo "$where" | sed 's/^/  /'
  fi
}

safe_rel() {
  local r="${1#/}"; r="${r%/}"
  [[ "/$r/" == *"/../"* || "$r" == *"|"* ]] && die "chemin invalide : $1"
  REL="$r"
}

api_restore() {  # api_restore <nom> <dossier> [element] [corbeille] [destination]
  local st="$STATE_DIR/restauration.status" rlog="$STATE_DIR/restauration.log"
  job_get "$1" || die "sauvegarde '$1' introuvable."
  [ "$J_MODE" = versions ] && die "sauvegarde versionnee : « versions restaurer »."
  local target="${2%/}" dest rc rel
  [ -n "$target" ] || die "dossier de restauration manquant."
  safe_rel "${3:-}"; rel="$REL"
  job_dest_at "${5:-0}"
  if [ "${4:-}" = corbeille ]; then dest=$(trash_path "$DI_R" "$DI_E" "$J_NAME"); else dest=$(dest_path "$DI_R" "$DI_E" "$J_SUB"); fi
  [ -n "$rel" ] && dest="$dest/$rel"
  exec 9>/run/nas-backup-restauration.lock
  flock -n 9 || die "une restauration est deja en cours."
  mkdir -p "$target" || die "impossible de creer $target"
  perf_load "$J_PERF"
  : > "$rlog"
  printf 'ETAT=en_cours\nNOM=%q\nCIBLE=%q\nELEMENT=%q\nDEBUT=%s\n' "$J_NAME" "$target" "$rel" "$(date +%s)" > "$st"
  logl "$J_NAME : restauration depuis $DI_R vers $target"
  if [ -n "$rel" ] && rclone lsf "$dest" --max-depth 1 2>/dev/null | grep -x "${rel##*/}" >/dev/null; then
    rcl restauration copyto "$dest" "$target/${rel##*/}" --stats 10s --log-file "$rlog" --log-level INFO; rc=$?
  elif [ -n "$rel" ]; then
    rcl restauration copy "$dest" "$target/${rel##*/}" "${EXCLUDES[@]}" --stats 10s --log-file "$rlog" --log-level INFO; rc=$?
  else
    rcl restauration copy "$dest" "$target" "${EXCLUDES[@]}" --stats 10s --log-file "$rlog" --log-level INFO; rc=$?
  fi
  restore_done "$rc" "$target" "$rel"
  return $rc
}

restore_done() {  # restore_done <code> <cible> <element>
  local st="$STATE_DIR/restauration.status" rlog="$STATE_DIR/restauration.log"
  if [ "$1" -eq 0 ]; then
    printf 'ETAT=ok\nNOM=%q\nCIBLE=%q\nELEMENT=%q\nFIN=%s\n' "$J_NAME" "$2" "$3" "$(date +%s)" > "$st"
    logl "$J_NAME : restauration terminee ($2)"
    notify info "restore-$J_NAME" "Restauration « $J_NAME » terminée" "Fichiers restaurés dans $2"
  else
    printf 'ETAT=echec\nNOM=%q\nCIBLE=%q\nELEMENT=%q\nFIN=%s\nCODE=%s\n' "$J_NAME" "$2" "$3" "$(date +%s)" "$1" > "$st"
    logl "$J_NAME : restauration en ECHEC (code $1)"
    notify critique "restore-$J_NAME" "Restauration « $J_NAME » en échec" "Code $1. Détails : $rlog"
  fi
}

api_ls() {  # api_ls <nom> [chemin] [corbeille] [destination]
  job_get "$1" || die "sauvegarde '$1' introuvable."
  [ "$J_MODE" = versions ] && die "sauvegarde versionnee : « versions ls »."
  local rel dest
  safe_rel "${2:-}"; rel="$REL"
  job_dest_at "${4:-0}"
  if [ "${3:-}" = corbeille ]; then dest=$(trash_path "$DI_R" "$DI_E" "$J_NAME"); else dest=$(dest_path "$DI_R" "$DI_E" "$J_SUB"); fi
  [ -n "$rel" ] && dest="$dest/$rel"
  rclone lsjson "$dest" --max-depth 1 --no-mimetype "${EXCLUDES[@]}" 2>&1
}

# Verification d'integrite : chaque fichier du NAS compare a sa copie sur chaque destination
# (sauvegardes versionnees : controle des depots restic, une partie des donnees relue)
api_verify() {
  job_get "$1" || die "sauvegarde '$1' introuvable."
  local out="$STATE_DIR/$J_NAME.verif" dest rc i n r e lab etat_d dstat=""
  exec 7>"/run/nas-backup-verif-$J_NAME.lock"
  flock -n 7 || die "une verification de '$J_NAME' est deja en cours."
  [ -d "$J_SRC" ] || die "dossier source introuvable : $J_SRC"
  perf_load "$J_PERF"
  mkdir -p "$out.d"; find "$out.d" -mindepth 1 -maxdepth 1 -type f -delete 2>/dev/null
  printf 'ETAT=en_cours\nDEBUT=%s\n' "$(date +%s)" > "$out.status"
  : > "$out.log"
  job_dests; n=${#JD_R[@]}
  local c_ok=0 c_diff=0 c_miss=0 c_extra=0 c_err=0 f k
  for ((i = 0; i < n; i++)); do
    r="${JD_R[i]}"; e="${JD_E[i]}"; lab=""; [ "$n" -gt 1 ] && lab="[$r] "
    if [ "$J_MODE" = versions ]; then
      etat_d=ok
      if ! need_restic >> "$out.log"; then etat_d=echec
      else
        restic_prep "$r"
        if ! restic "${RST[@]}" cat config >/dev/null 2>&1 < /dev/null; then
          echo "${lab}depot absent ou illisible (aucune sauvegarde encore ?)" >> "$out.d/erreurs"; etat_d=echec
        elif ! gorun "" restic "${RST[@]}" check --read-data-subset=5% >> "$out.log" 2>&1 < /dev/null; then
          echo "${lab}le controle du depot signale des erreurs (voir le journal)" >> "$out.d/erreurs"; etat_d=echec
        fi
      fi
      dstat="${dstat:+$dstat;}$r:$etat_d"
      continue
    fi
    dest=$(dest_path "$r" "$e" "$J_SUB")
    local -a o=(--one-way "${EXCLUDES[@]}" --match "$out.d/$i.identiques" --differ "$out.d/$i.differents"
                --missing-on-dst "$out.d/$i.manquants" --error "$out.d/$i.erreurs" --log-file "$out.log" --log-level NOTICE)
    [ "$J_MODE" = sync ] && o=("${o[@]:1}" --missing-on-src "$out.d/$i.en-trop")
    if [ "$e" = oui ]; then
      rcl "" cryptcheck "$J_SRC" "$dest" "${o[@]}" < /dev/null; rc=$?
    else
      rcl "" check "$J_SRC" "$dest" "${o[@]}" < /dev/null; rc=$?
    fi
    etat_d=ok
    for k in differents manquants en-trop erreurs; do
      f="$out.d/$i.$k"
      [ -s "$f" ] && { etat_d=ecarts; sed "s#^#$lab#" "$f" >> "$out.d/$k"; }
    done
    [ "$rc" -ne 0 ] && [ "$etat_d" = ok ] && etat_d=echec
    c_ok=$((c_ok + $(cnt "$out.d/$i.identiques"))); c_diff=$((c_diff + $(cnt "$out.d/$i.differents")))
    c_miss=$((c_miss + $(cnt "$out.d/$i.manquants"))); c_extra=$((c_extra + $(cnt "$out.d/$i.en-trop")))
    c_err=$((c_err + $(cnt "$out.d/$i.erreurs")))
    dstat="${dstat:+$dstat;}$r:$etat_d"
  done
  local etat=ok
  [[ ";$dstat" == *":ecarts"* ]] && etat=ecarts
  [[ ";$dstat" == *":echec"* ]] && etat=echec
  [ "$J_MODE" = versions ] && c_err=$(cnt "$out.d/erreurs")
  printf 'ETAT=%s\nFIN=%s\nIDENTIQUES=%s\nDIFFERENTS=%s\nMANQUANTS=%s\nEN_TROP=%s\nERREURS=%s\nDESTINATIONS=%q\nTYPE=%s\n' \
    "$etat" "$(date +%s)" "$c_ok" "$c_diff" "$c_miss" "$c_extra" "$c_err" "$dstat" "$( [ "$J_MODE" = versions ] && echo versions || echo fichiers)" > "$out.status"
  logl "$J_NAME : verification $etat ($dstat ; $c_ok identiques, $c_diff differents, $c_miss manquants, $c_extra en trop, $c_err erreurs)"
  if [ "$etat" = ok ]; then
    notify ok "verif-$J_NAME" "Vérification « $J_NAME »" "La sauvegarde est de nouveau identique au NAS."
  elif [ "$J_MODE" = versions ]; then
    notify critique "verif-$J_NAME" "Vérification « $J_NAME » : dépôt en erreur" "Le contrôle des versions signale un problème (${dstat//;/, }). Voir le journal sur le NAS."
  else
    notify critique "verif-$J_NAME" "Vérification « $J_NAME » : écarts" "$c_diff différent(s), $c_miss manquant(s), $c_err erreur(s) (${dstat//;/, }). Une nouvelle sauvegarde les corrige en général."
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

# =========================== Versions (restic) =======================
# Sauvegarde versionnee chargee + destination n° <i> -> RST pret ; meurt si le depot est absent
versions_open() {  # versions_open <nom> <destination>
  job_get "$1" || die "sauvegarde '$1' introuvable."
  [ "$J_MODE" = versions ] || die "« $J_NAME » n'est pas une sauvegarde versionnee."
  job_dest_at "${2:-0}"
  need_restic >/dev/null || die "restic n'est pas installe (NAS Manager > Installation > Outils)."
  restic_prep "$DI_R"
}

valid_snap() { [[ "$1" =~ ^[0-9a-f]{8,64}$ || "$1" == latest ]] || die "version invalide : $1"; }

# Versions d'une sauvegarde (JSON, la plus recente d'abord)
versions_list() {  # versions_list <nom> [destination]
  versions_open "$1" "${2:-0}"
  local out rc
  out=$(restic "${RST[@]}" snapshots --json --tag "job:$J_NAME" 2>&1 < /dev/null); rc=$?
  if [ $rc -ne 0 ]; then
    echo "$out" | grep -qiE 'does not exist|unable to open config|is there a repository' && { echo '[]'; return 0; }
    echo "$out" | tail -n 3 >&2; return 1
  fi
  python3 -c '
import json, sys
from datetime import datetime
def ts(s):
    try:
        base, frac = (s.split(".", 1) + [""])[:2]
        tz = frac.lstrip("0123456789") if frac else s[19:]
        return int(datetime.fromisoformat(base[:19] + (tz or "+00:00").replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0
out = []
for x in json.loads(sys.argv[1]) or []:
    s = x.get("summary") or {}
    out.append({"id": x.get("id", ""), "court": x.get("short_id", x.get("id", "")[:8]), "date": ts(x.get("time", "")),
                "chemin": (x.get("paths") or [""])[0], "fichiers": s.get("total_files_processed"),
                "taille": s.get("total_bytes_processed"), "ajoute": s.get("data_added")})
out.sort(key=lambda v: -v["date"])
print(json.dumps(out, ensure_ascii=False))' "$out"
}

# Dossier racine d'une version (dossier sauvegarde a ce moment-la)
snap_root() {  # snap_root <version> -> stdout
  restic "${RST[@]}" snapshots --json "$1" 2>/dev/null < /dev/null \
    | python3 -c 'import json,sys; v=json.load(sys.stdin) or []; print((v[0].get("paths") or [""])[0] if v else "")'
}

# Contenu d'un dossier d'une version (JSON comme rclone lsjson : Name, Size, ModTime, IsDir)
versions_ls() {  # versions_ls <nom> <destination> <version> [chemin]
  versions_open "$1" "$2"
  valid_snap "$3"
  safe_rel "${4:-}"
  local root dir
  root=$(snap_root "$3"); [ -n "$root" ] || die "version introuvable : $3"
  dir="$root${REL:+/$REL}"
  restic "${RST[@]}" ls --json "$3" "$dir" 2>/dev/null < /dev/null | python3 -c '
import json, os, sys
d = sys.argv[1].rstrip("/") or "/"
out = []
for l in sys.stdin:
    try:
        n = json.loads(l)
    except ValueError:
        continue
    p = n.get("path")
    if not p or n.get("struct_type", "node") != "node" or os.path.dirname(p.rstrip("/")) != d:
        continue
    out.append({"Name": n.get("name", ""), "Size": n.get("size", -1) if n.get("type") == "file" else -1,
                "ModTime": n.get("mtime", ""), "IsDir": n.get("type") == "dir"})
print(json.dumps(out, ensure_ascii=False))' "$dir"
}

# Restauration d'une version (tout, ou un fichier / dossier) dans un dossier
versions_restore() {  # versions_restore <nom> <destination> <version> <dossier cible> [element]
  versions_open "$1" "$2"
  valid_snap "$3"
  local snap="$3" target="${4%/}" st="$STATE_DIR/restauration.status" rlog="$STATE_DIR/restauration.log" root rc parent name
  [ -n "$target" ] || die "dossier de restauration manquant."
  safe_rel "${5:-}"
  exec 9>/run/nas-backup-restauration.lock
  flock -n 9 || die "une restauration est deja en cours."
  root=$(snap_root "$snap"); [ -n "$root" ] || die "version introuvable : $snap"
  mkdir -p "$target" || die "impossible de creer $target"
  perf_load "$J_PERF"
  : > "$rlog"
  printf 'ETAT=en_cours\nNOM=%q\nCIBLE=%q\nELEMENT=%q\nDEBUT=%s\nVERSION=%s\n' "$J_NAME" "$target" "$REL" "$(date +%s)" "$snap" > "$st"
  logl "$J_NAME : restauration de la version $snap ($DI_R) vers $target"
  if [ -n "$REL" ]; then
    parent="${REL%/*}"; [ "$parent" = "$REL" ] && parent=""
    name="${REL##*/}"
    gorun restauration restic "${RST[@]}" restore "$snap:$root${parent:+/$parent}" --target "$target" --include "/$name" --json >> "$rlog" 2>&1 < /dev/null; rc=$?
  else
    gorun restauration restic "${RST[@]}" restore "$snap:$root" --target "$target" --json >> "$rlog" 2>&1 < /dev/null; rc=$?
  fi
  restore_done "$rc" "$target" "$REL"
  return $rc
}

# Entretien hebdomadaire : nettoyage des versions oubliees (prune) et controle d'une partie des donnees
versions_maint() {  # versions_maint [nom]
  local n i rc out
  for n in ${1:-$(job_names)}; do
    job_get "$n" || continue
    [ "$J_MODE" = versions ] || continue
    command -v restic >/dev/null || { notify critique "versions-$n" "Versions « $n » : entretien impossible" "restic n'est pas installé sur le NAS."; continue; }
    (
      flock -w 7200 9 || exit 0
      job_dests; out=""; rc=0
      for ((i = 0; i < ${#JD_R[@]}; i++)); do
        restic_prep "${JD_R[i]}"
        restic "${RST[@]}" cat config >/dev/null 2>&1 < /dev/null || continue
        restic "${RST[@]}" unlock >/dev/null 2>&1 < /dev/null
        perf_load "$J_PERF"
        { echo "== $(date '+%Y/%m/%d %H:%M:%S') entretien $n -> ${JD_R[i]}"
          gorun "" restic "${RST[@]}" prune 2>&1 < /dev/null; } >> "$LOG" || { rc=1; out="$out ${JD_R[i]} (nettoyage)"; }
        gorun "" restic "${RST[@]}" check --read-data-subset=2% >> "$LOG" 2>&1 < /dev/null || { rc=1; out="$out ${JD_R[i]} (controle)"; }
      done
      printf '{"fin":%s,"code":%s,"erreurs":"%s"}\n' "$(date +%s)" "$rc" "${out# }" > "$STATE_DIR/$n.entretien.json"
      if [ $rc -eq 0 ]; then
        logl "$n : entretien des versions OK"
        notify ok "versions-$n" "Versions « $n »" "L'entretien des versions fonctionne de nouveau."
      else
        logl "$n : entretien des versions en ECHEC :$out"
        notify critique "versions-$n" "Versions « $n » : entretien en échec" "Problème sur :${out}. Détails : $LOG"
      fi
    ) 9>"/run/nas-backup-$n.lock"
  done
}

versions_main() {
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  case "${1:-}" in
    liste)     [ -n "${2:-}" ] || die "usage : versions liste <NOM> [DESTINATION]"; versions_list "$2" "${3:-0}" ;;
    ls)        [ -n "${4:-}" ] || die "usage : versions ls <NOM> <DESTINATION> <VERSION> [CHEMIN]"; versions_ls "$2" "$3" "$4" "${5:-}" ;;
    restaurer) [ -n "${5:-}" ] || die "usage : versions restaurer <NOM> <DESTINATION> <VERSION> <DOSSIER> [ELEMENT]"; versions_restore "$2" "$3" "$4" "$5" "${6:-}" ;;
    entretien) versions_maint "${2:-}" ;;
    *) die "usage : nas-debian versions liste | ls | restaurer | entretien" ;;
  esac
}

# =========================== Kit de secours ==========================
# Tout ce qu'il faut pour reconstruire apres la perte du NAS : connexions aux destinations
# (rclone.conf), mots de passe de chiffrement, sauvegardes et reglages. Chiffre (openssl,
# AES-256) avec le mot de passe du kit, envoye chaque jour s'il a change vers toutes les
# destinations (dossier NAS-secours, en clair : lisible depuis le site du cloud) et copie sur
# le PC par NAS Manager.
SECOURS_CIPHER=(-aes-256-cbc -pbkdf2 -iter 200000 -md sha256)

secours_pass_ensure() {
  [ -s "$SECOURS_PASS" ] && return 0
  mkdir -p "$CONF_DIR"
  ( umask 077
    python3 -c 'import secrets; a = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"; print("-".join("".join(secrets.choice(a) for _ in range(4)) for _ in range(6)))' > "$SECOURS_PASS" )
  logl "mot de passe du kit de secours cree"
}

kit_name() { echo "kit-secours-$(hostname -s 2>/dev/null || echo nas).tar.gz.enc"; }

# Fichiers du kit : « role|chemin » (role rclone = configuration de rclone, a remettre a
# l'emplacement de rclone de la nouvelle machine)
secours_files() {
  local f c
  c=$(rclone_conf_file)
  [ -n "$c" ] && [ -f "$c" ] && echo "rclone|$c"
  for f in "$PASSFILE" "$CAM_PASS" "$JOBS" "$RT_CONF" "$AGENT_CONF" "$NOTIFY_CONF" "$CONF_DIR/verification" \
           "$RESTIC_PASS" "$CONF_DIR/canaux.conf" "$CONF_DIR/rapport.conf" /root/.config/mosquitto_pub; do
    [ -f "$f" ] && echo "fichier|$f"
  done
  return 0
}

secours_readme() {
  cat <<EOF
KIT DE SECOURS DU NAS ($(hostname -s 2>/dev/null)) - cree par nas-debian $SCRIPT_VERSION

Ce fichier contient ce qu'il faut pour reconstruire les sauvegardes apres la perte du NAS :
connexions aux destinations (Google Drive, OneDrive, disque USB...), mots de passe de
chiffrement, liste des sauvegardes et reglages. Il est chiffre avec le MOT DE PASSE DU KIT
(6 groupes de 4 caracteres, note lors de l'installation ; affiche par NAS Manager, page
Alertes > Mots de passe de chiffrement).

Avec NAS Manager (le plus simple) : installer Debian / OpenMediaVault sur la nouvelle machine,
la connecter dans NAS Manager, installer le script (page Installation), puis carte
« Reconstruire apres une panne » > choisir ce fichier et taper le mot de passe du kit.

A la main, sur une machine Linux (ou WSL) :
  openssl enc -d ${SECOURS_CIPHER[*]} -in $(kit_name) | tar xzv
puis lire kit/manifeste.json : chaque fichier de kit/fichiers retourne a son emplacement.
EOF
}

# Construit le kit -> $SECOURS_DIR/<kit> ; KIT_CHANGE=1 si son contenu a change depuis le dernier
secours_build() {
  secours_pass_ensure
  mkdir -p "$SECOURS_DIR"; chmod 700 "$SECOURS_DIR"
  local tmp i=0 role f h kit
  kit="$SECOURS_DIR/$(kit_name)"
  tmp=$(mktemp -d); chmod 700 "$tmp"; mkdir -p "$tmp/kit/fichiers"
  {
    echo "["
    while IFS='|' read -r role f; do
      i=$((i + 1))
      cp -p "$f" "$tmp/kit/fichiers/$i-${f##*/}"
      [ $i -gt 1 ] && echo ","
      printf '{"role":"%s","chemin":"%s","fichier":"fichiers/%s"}' "$role" "$f" "$i-${f##*/}"
    done < <(secours_files)
    echo "]"
  } > "$tmp/liste.json"
  h=$(cd "$tmp/kit/fichiers" && cat -- * 2>/dev/null | sha256sum | cut -c1-64)
  python3 - "$tmp/liste.json" "$tmp/kit/manifeste.json" "$SCRIPT_VERSION" "$MACHINE" "$h" <<'PYM'
import json, socket, sys, time
lst, out, ver, machine, h = sys.argv[1:6]
json.dump({"cree": int(time.time()), "hote": socket.gethostname(), "machine": machine, "script": ver,
           "empreinte_contenu": h, "fichiers": json.load(open(lst))}, open(out, "w"), ensure_ascii=False, indent=1)
PYM
  secours_readme > "$tmp/kit/LISEZMOI.txt"
  KIT_CHANGE=1
  [ -f "$kit" ] && [ "$(cat "$SECOURS_DIR/contenu.sha256" 2>/dev/null)" = "$h" ] && KIT_CHANGE=0
  if [ "$KIT_CHANGE" = 1 ]; then
    tar czf - -C "$tmp" kit | openssl enc -e "${SECOURS_CIPHER[@]}" -salt -pass file:"$SECOURS_PASS" -out "$kit.new" \
      || { rm -rf "${tmp:?}"; die "chiffrement du kit impossible (openssl)."; }
    mv -f "$kit.new" "$kit"; chmod 600 "$kit"
    echo "$h" > "$SECOURS_DIR/contenu.sha256"
    date +%s > "$SECOURS_DIR/cree"
  fi
  rm -rf "${tmp:?}"
  return 0
}

secours_state() {  # secours_state <cle> <valeur json> : met a jour secours.json
  python3 - "$SECOURS_DIR/secours.json" "$1" "$2" <<'PYS'
import json, sys
p, k, v = sys.argv[1:4]
try:
    d = json.load(open(p))
except Exception:
    d = {}
d.setdefault("destinations", {})[k] = json.loads(v)
json.dump(d, open(p, "w"))
PYS
}

# Construit et envoie le kit vers les destinations (si change, ou s'il n'y est pas encore,
# ou chaque semaine) ; « force » : envoi dans tous les cas
secours_save() {  # secours_save [force]
  need_root_rclone
  secours_build
  local kit name r now cree last err readme
  kit="$SECOURS_DIR/$(kit_name)"; name=$(kit_name); now=$(date +%s); cree=$(cat "$SECOURS_DIR/cree" 2>/dev/null || echo "$now")
  readme=$(mktemp); secours_readme > "$readme"
  for r in $(dest_list | python3 -c 'import json,sys; print(" ".join(x["nom"] for x in json.load(sys.stdin)))'); do
    last=$(python3 -c 'import json, sys
try:
    e = json.load(open(sys.argv[1]))["destinations"][sys.argv[2]]
    print(e.get("date", 0) if e.get("ok") else 0)
except Exception:
    print(0)' "$SECOURS_DIR/secours.json" "$r")
    if [ "${1:-}" != force ] && [ "$last" -ge "$cree" ] && [ $((now - last)) -lt $((7 * 86400)) ]; then continue; fi
    if ! err=$(dest_ready "$r"); then
      secours_state "$r" "{\"ok\":false,\"date\":$now,\"erreur\":$(printf '%s' "$err" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"
      continue
    fi
    if err=$(timeout 600 rclone copyto "$kit" "$r:$SECOURS_FOLDER/$name" 2>&1 < /dev/null); then
      timeout 600 rclone copyto "$kit" "$r:$SECOURS_FOLDER/anciens/${name%.tar.gz.enc}-$(date +%Y%m%d).tar.gz.enc" >/dev/null 2>&1 < /dev/null
      timeout 120 rclone copyto "$readme" "$r:$SECOURS_FOLDER/LISEZMOI.txt" >/dev/null 2>&1 < /dev/null
      timeout 300 rclone delete "$r:$SECOURS_FOLDER/anciens" --min-age 120d >/dev/null 2>&1 < /dev/null
      secours_state "$r" "{\"ok\":true,\"date\":$now}"
      echo "Kit de secours envoye : $r"
    else
      err=$(echo "$err" | grep -E 'ERROR|Failed' | tail -n 1 | sed -E 's/^[0-9\/ :]+//' | cut -c1-200)
      secours_state "$r" "{\"ok\":false,\"date\":$now,\"erreur\":$(printf '%s' "${err:-envoi impossible}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"
      echo "Kit de secours : envoi impossible vers $r"
    fi
  done
  rm -f "$readme"
  logl "kit de secours a jour ($( [ "$KIT_CHANGE" = 1 ] && echo nouveau contenu || echo inchange))"
  vert "Kit de secours a jour."
}

secours_etat() {
  python3 - "$SECOURS_DIR" "$(kit_name)" "$SECOURS_PASS" <<'PYE'
import json, os, sys
d, name, pw = sys.argv[1:4]
st = {}
try:
    st = json.load(open(os.path.join(d, "secours.json")))
except Exception:
    pass
kit = os.path.join(d, name)
out = {"mot_de_passe": os.path.exists(pw), "destinations": st.get("destinations", {}), "nom": name}
if os.path.exists(kit):
    out["taille"] = os.path.getsize(kit)
    try:
        out["date"] = int(open(os.path.join(d, "cree")).read().strip())
    except (OSError, ValueError):
        out["date"] = int(os.path.getmtime(kit))
    try:
        out["empreinte"] = open(os.path.join(d, "contenu.sha256")).read().strip()[:16]
    except OSError:
        pass
print(json.dumps(out))
PYE
}

# Kit (chiffre) en base64 pour l'application : premiere ligne = empreinte du contenu
secours_download() {
  local kit; kit="$SECOURS_DIR/$(kit_name)"
  [ -f "$kit" ] || secours_build
  echo "EMPREINTE=$(cut -c1-16 "$SECOURS_DIR/contenu.sha256" 2>/dev/null) NOM=$(kit_name)"
  base64 -w 0 "$kit"; echo
}

# Restauration d'un kit sur une nouvelle machine (mot de passe du kit sur l'entree standard)
secours_restore() {  # secours_restore <fichier du kit> [appliquer]
  local f="$1" mode="${2:-simulation}" pass tmp dest bak line
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  [ -f "$f" ] || die "kit introuvable : $f"
  IFS= read -r pass || true
  [ -n "$pass" ] || die "mot de passe du kit manquant."
  tmp=$(mktemp -d); chmod 700 "$tmp"
  printf '%s' "$pass" > "$tmp/p"
  if ! openssl enc -d "${SECOURS_CIPHER[@]}" -pass file:"$tmp/p" -in "$f" 2>/dev/null | tar xzf - -C "$tmp" 2>/dev/null \
     || [ ! -f "$tmp/kit/manifeste.json" ]; then
    rm -rf "${tmp:?}"; die "mot de passe du kit incorrect, ou fichier abime."
  fi
  local rcf; rcf=$(rclone_conf_file); [ -n "$rcf" ] || rcf=/root/.config/rclone/rclone.conf
  python3 - "$tmp/kit/manifeste.json" "$rcf" > "$tmp/plan" <<'PYP'
import json, sys
m = json.load(open(sys.argv[1]))
print("#KIT|%s|%s|%s" % (m.get("hote", "?"), m.get("cree", 0), m.get("script", "?")))
for x in m.get("fichiers", []):
    dest = sys.argv[2] if x.get("role") == "rclone" else x["chemin"]
    print("%s|%s" % (x["fichier"], dest))
PYP
  IFS='|' read -r _ h c v < <(head -n 1 "$tmp/plan")
  gras "Kit de secours de « $h », cree le $(date -d "@$c" '+%d/%m/%Y %H:%M' 2>/dev/null) (nas-debian $v)"
  while IFS='|' read -r line dest; do
    [[ "$line" == \#* ]] && continue
    if [ -f "$dest" ]; then echo "  remplace : $dest"; else echo "  ajoute   : $dest"; fi
  done < "$tmp/plan"
  if [ "$mode" != appliquer ]; then
    rm -rf "${tmp:?}"; jaune "Simulation : rien n'a ete modifie."; return 0
  fi
  bak="/root/.nas-manager/avant-secours-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$bak"
  while IFS='|' read -r line dest; do
    [[ "$line" == \#* ]] && continue
    [ -f "$dest" ] && cp -p "$dest" "$bak/$(echo "$dest" | tr '/' '_')"
    mkdir -p "$(dirname "$dest")"
    install -m 600 "$tmp/kit/$line" "$dest"
  done < "$tmp/plan"
  # le mot de passe du kit reste le meme : les prochains kits s'ouvrent avec lui
  install -m 600 "$tmp/p" "$SECOURS_PASS"
  rm -rf "${tmp:?}"
  install_base >/dev/null
  gen_cron
  rt_gen_cron
  [ -f "$NOTIFY_CONF" ] && { echo "7 * * * * root $BIN_DIR/nas-check >/dev/null 2>&1" > /etc/cron.d/nas-check; chmod 644 /etc/cron.d/nas-check; }
  [ -f /root/.config/mosquitto_pub ] && { echo "*/5 * * * * root $BIN_DIR/nas-ha-status >/dev/null 2>&1" > /etc/cron.d/nas-ha-status; chmod 644 /etc/cron.d/nas-ha-status; }
  logl "kit de secours restaure (anciens fichiers dans $bak)"
  vert "Kit restaure. Anciens fichiers gardes dans $bak"
  # dossiers des sauvegardes absents sur cette machine (disques montes ailleurs ?)
  local n s
  while IFS='|' read -r n s _ || [ -n "$n" ]; do
    [[ -z "$n" || "$n" == \#* ]] && continue
    [ -d "$s" ] || jaune "Sauvegarde « $n » : dossier $s absent sur cette machine (a corriger dans NAS Manager)."
  done < "$JOBS"
  for n in $(rt_names); do
    rt_get "$n" || continue
    local allok=1 d; for d in "${R_SRCS[@]}"; do [ -d "$d" ] || allok=0; done
    if [ $allok = 1 ]; then rt_start "$n" >/dev/null 2>&1 && echo "Sauvegarde temps reel « $n » redemarree."
    else jaune "Sauvegarde temps reel « $n » : dossier(s) absent(s), surveillance non demarree."; fi
  done
  echo "Suite : verifie les destinations (page Destinations), puis restaure les donnees depuis les sauvegardes."
}

# Saisie des mots de passe notes (reconstruction sans kit) : sur l'entree standard,
# mot de passe du chiffrement, sel (password2), mot de passe des versions ; ligne vide = inchange
secours_set_passwords() {
  local p1 p2 rp
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  IFS= read -r p1 || true; IFS= read -r p2 || true; IFS= read -r rp || true
  mkdir -p "$CONF_DIR"
  if [ -n "$p1" ] || [ -n "$p2" ]; then
    [ -n "$p1" ] && [ -n "$p2" ] || die "le mot de passe ET le sel du chiffrement sont necessaires."
    [ -f "$PASSFILE" ] && cp -p "$PASSFILE" "$PASSFILE.avant-$(date +%Y%m%d-%H%M%S)"
    { echo "Remote rclone : ${CRYPT}  ->  ${GDRIVE}:${CRYPT_FOLDER}"; echo "Mot de passe        : $p1"; echo "Sel (password2)     : $p2"; echo "Saisi le            : $(date)"; } > "$PASSFILE"
    chmod 600 "$PASSFILE"
    vert "Mots de passe du chiffrement enregistres (les remotes chiffres seront recrees avec eux)."
  fi
  if [ -n "$rp" ]; then
    [ -s "$RESTIC_PASS" ] && cp -p "$RESTIC_PASS" "$RESTIC_PASS.avant-$(date +%Y%m%d-%H%M%S)"
    ( umask 077; printf '%s' "$rp" > "$RESTIC_PASS" )
    vert "Mot de passe des sauvegardes versionnees enregistre."
  fi
  logl "mots de passe saisis a la main (reconstruction)"
}

secours_main() {
  case "${1:-etat}" in
    etat)          secours_etat ;;
    sauvegarder)   secours_save "${2:-}" ;;
    telecharger)   [ "$(id -u)" -eq 0 ] || die "lance ce script en root."; secours_download ;;
    restaurer)     [ -n "${2:-}" ] || die "usage : secours restaurer <FICHIER> [appliquer]  (mot de passe du kit sur l'entree standard)"; secours_restore "$2" "${3:-}" ;;
    mots-de-passe) secours_set_passwords ;;
    *) die "usage : nas-debian secours etat | sauvegarder [force] | telecharger | restaurer <FICHIER> [appliquer] | mots-de-passe" ;;
  esac
}

# Tous les mots de passe a noter hors du NAS
show_passwords() {
  local found=0 f
  for f in "$PASSFILE" "$CAM_PASS"; do
    [ -f "$f" ] || continue; found=1
    echo "=== Chiffrement des sauvegardes ($f)"; cat "$f"; echo
  done
  if [ -s "$RESTIC_PASS" ]; then
    found=1; echo "=== Sauvegardes versionnees (restic, $RESTIC_PASS)"; echo "Mot de passe des depots : $(cat "$RESTIC_PASS")"; echo
  fi
  if [ -s "$SECOURS_PASS" ]; then
    found=1; echo "=== Kit de secours (pour tout reconstruire si le NAS est perdu)"; echo "Mot de passe du kit : $(cat "$SECOURS_PASS")"; echo
  fi
  [ $found = 1 ] || echo "Aucun mot de passe de chiffrement sur cette machine pour l'instant."
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
      agent_conf_set RAM_PROFIL "$p"; agent_conf_set RAM_MO "$mo"; agent_conf_set TRANSFERTS "$t"
      agent_conf_set VERIFS "$c"; agent_conf_set TAMPON "$b"
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
    restore)  [ -n "${3:-}" ] || die "usage : nas-backup restore <NOM> <DOSSIER> [ELEMENT] [corbeille] [DESTINATION]"; need_rclone; api_restore "$2" "$3" "${4:-}" "${5:-}" "${6:-0}" ;;
    ls)       [ -n "${2:-}" ] || die "usage : nas-backup ls <NOM> [CHEMIN] [corbeille] [DESTINATION]"; need_rclone; api_ls "$2" "${3:-}" "${4:-}" "${5:-0}" ;;
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
        restic-maj) outils_restic_maj ;;
        derniere)   outils_rclone_derniere; outils_restic_derniere >/dev/null 2>&1 || true ;;
        *) die "usage : nas-debian outils etat | installer [suivi] | rclone-maj" ;;
      esac ;;
    reglages)  shift; reglages "$@" ;;
    racines)   data_roots ;;
    dossiers)  data_dirs ;;
    migrer)    migrer "${2:-simulation}" ;;
    alertes)   shift; [ "$(id -u)" -eq 0 ] || die "lance ce script en root."; alertes_main "$@" ;;
    suivi)     [ "${2:-}" = configurer ] || die "usage : nas-debian suivi configurer <serveur MQTT>"; suivi_configurer "${3:-}" ;;
    notify)    shift; notify_cmd "$@" ;;
    check)     check_cmd ;;
    ha-status) ha_status_cmd ;;
    temps-reel) shift; temps_reel_main "$@" ;;
    destinations) shift; destinations_main "$@" ;;
    disques)   shift; disques_main "$@" ;;
    rapport)   shift; rapport_main "$@" ;;
    versions)  shift; need_rclone; versions_main "$@" ;;
    secours)   shift; secours_main "$@" ;;
    mots-de-passe) [ "$(id -u)" -eq 0 ] || die "lance ce script en root."; show_passwords ;;
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
