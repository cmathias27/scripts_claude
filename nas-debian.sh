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
#            | debit <limite rclone | ->   limite commune des sauvegardes (ex. 08:00,2M 23:00,off)
#    estimer <NOM> | <SOURCE> <DESTINATION> [chiffre]   volume et duree estimee d'un envoi complet
#    doublons analyser <DOSSIER>... [--min Ko] | etat | voir [N] | arreter | supprimer | vider
#                                   fichiers en double (suppression = corbeille des doublons)
#    racines | dossiers             disques de donnees | sous-dossiers proposes comme sources
#    migrer simulation | appliquer  reprise d'une installation avec les anciens scripts
#    alertes configurer <ip HA> <webhook> [o|n : alerte critique de test]
#    alertes voir | canal <ha|ntfy|telegram|discord|email> [tout|critique] | niveau <canal> <niveau>
#            | retirer <canal> | tester [canal] | telegram | seuils <rappel h> <espace %> <retard h>
#                                   canaux de notification (parametres cle=valeur sur l'entree standard)
#    disques verifier | etat        sante des disques (SMART) et du RAID
#    rapport voir | envoyer [hebdo|mensuel] | planifier <hebdo|mensuel|non> [jour] [HH:MM] [canaux]
#    suivi configurer <serveur MQTT>   (utilisateur et mot de passe sur l'entree standard)
#    suivi actions <oui|non>        actions depuis Home Assistant (boutons et interrupteurs MQTT)
#    tui installer | etat | supprimer   interface texte NAS Manager (nas-manager-tui)
#    notify <critique|info|succes|ok> <tag> <titre> <message>
#    check                          verification (comme nas-check)
#    ha-status                      publication Home Assistant (comme nas-ha-status)
#    destinations liste | etat [NOM] | creer NOM TYPE | jeton NOM TYPE | supprimer NOM
#                                   destinations des sauvegardes (remotes rclone)
#    versions liste | ls | restaurer | entretien   sauvegardes versionnees (restic)
#    secours etat | sauvegarder | telecharger | restaurer | mots-de-passe
#                                   kit de secours (ce qui permet de tout reconstruire)
#    test-restauration <NOM> [NB] | tout | planifier <JOURS|non> [HH:MM] [NB]
#                                   test de restauration a blanc (fichiers au hasard)
#    date plage | apercu | restaurer   retour a une date precise (corbeille datee, versions)
#    reveil liste | regler | retirer | tester | envoyer   reveil des destinations (Wake-on-LAN)
#    migration <commande>           migration d'un dossier de la machine vers oCIS (memes
#                                   commandes que sur le Synology : configurer, espaces,
#                                   ajouter, retirer, lancer, arreter, suivi, jeton)
#    transferts <commande>          transferts oCIS -> machine, ponctuels ou programmes
#    mots-de-passe                  mots de passe de chiffrement (affichage)
#    <commandes de nas-backup>      run, run-at, run-all, stop, save, delete, restore,
#                                   ls, simulate, verifier, verifier-tout, verif-plan,
#                                   gen-cron, list, api-version
# =====================================================================
set -uo pipefail

SCRIPT_VERSION="2.6.0"
API_VERSION=11

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
EXCLUDES=(--exclude '@eaDir/**' --exclude '\#recycle/**' --exclude '.Trash-*/**' --exclude '.corbeille-doublons/**')
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
  RAM_PROFIL=auto RAM_MO="" TRANSFERTS="" VERIFS="" TAMPON="" CAM_JOB="" DEBIT="" HA_ACTIONS=""
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
  PERF_BW="${DEBIT:-}"
}

# Limite de debit d'une sauvegarde : la sienne, sinon celle de la machine (« Debit selon
# l'heure », reglages debit) ; « off » = sans limite. Vide en sortie = aucune option.
bw_of() {  # bw_of <limite de la sauvegarde>
  local own="${1:-}"
  if [ -n "$own" ]; then [ "$own" = off ] || echo "$own"; return 0; fi
  [ -n "${PERF_MEM:-}" ] || perf_load
  [ -z "${PERF_BW:-}" ] || [ "$PERF_BW" = off ] || echo "$PERF_BW"
  return 0
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
      local dc=0; dest_check "$d" || dc=$?
      if [ $dc -eq 2 ]; then
        $N ok "$tg" "$lab" "La destination répond de nouveau (en veille : réveillée avant chaque sauvegarde)."
      elif [ $dc -eq 0 ]; then
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

  # 4 ter. Corbeille des doublons videe apres 30 jours ; ecoute des actions Home Assistant
  dup_purge >/dev/null 2>&1 || true
  ha_actions_ensure >/dev/null 2>&1 || true

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
# Clients MQTT (mosquitto_pub / mosquitto_sub) : options lues dans /root/.config/<client>,
# quel que soit le HOME herite (sudo qui garde celui de l'utilisateur, service systemd...)
mqtt() { HOME=/root XDG_CONFIG_HOME=/root/.config "$@"; }

ha_slug() {
  if [ "$MACHINE" = omv ]; then echo omv; else hostname -s 2>/dev/null | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' '_' | head -c 30; fi
}

ha_status_cmd() {
  [ -f /root/.config/mosquitto_pub ] || return 0
  command -v mosquitto_pub >/dev/null || return 0
  agent_conf_load
  HOME=/root XDG_CONFIG_HOME=/root/.config NAS_HA_ACTIONS="${HA_ACTIONS:-}" NAS_HA_SLUG="$(ha_slug)" NAS_HA_NOM="$( [ "$MACHINE" = omv ] && echo "NAS OMV Sauvegardes" || echo "NAS $(hostname -s) Sauvegardes")" \
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

# Actions depuis Home Assistant (nas-debian suivi actions oui) : boutons et interrupteurs
# qui publient sur CMD ; « nas-debian ha-actions ecouter » les execute (liste fermee).
CMD = f"nas-{SLUG}/commande"
ACTIONS = os.environ.get("NAS_HA_ACTIONS") == "oui"
buttons, switches = {}, {}


def command_entity(domain, key, name, extra):
    cfg = {"name": name, "unique_id": f"{OBJ}_{key}", "default_entity_id": f"{domain}.{EID}_{key}",
           "command_topic": CMD, "device": DEVICE}
    cfg.update(extra)
    pub(f"{DISC}/{domain}/{OBJ}/{key}/config", json.dumps(cfg))


if ACTIONS:
    buttons["arreter_sauvegardes"] = ("Arrêter les sauvegardes", "arreter", "mdi:stop-circle-outline")
    buttons["verifier"] = ("Vérifier maintenant", "verifier", "mdi:stethoscope")
    for key, j in jobs.items():
        buttons[f"lancer_{key}"] = (f"Lancer {j['nom']}", f"lancer|{j['nom']}", "mdi:play-circle-outline")
    for key, j in rt.items():
        switches[f"temps_reel_actif_{key}"] = (key, j["nom"])
    for key, (name, payload, icon) in buttons.items():
        command_entity("button", key, name, {"payload_press": payload, "icon": icon})
    for key, (k, name) in switches.items():
        command_entity("switch", key, f"Temps réel {name} actif", {
            "state_topic": TOPIC,
            "value_template": "{{ 'ON' if '%s' in value_json.temps_reel and value_json.temps_reel['%s'].etat == 'Actif' else 'OFF' }}" % (k, k),
            "payload_on": f"reprendre|{name}", "payload_off": f"pause|{name}",
            "state_on": "ON", "state_off": "OFF", "icon": "mdi:sync",
        })

# Retire les entites des sauvegardes supprimees (et les actions retirees)
try:
    old = json.load(open(PUBLISHED))
except (OSError, ValueError):
    old = []
old_jobs, old_rt = (set(old), set()) if isinstance(old, list) else (set(old.get("jobs", [])), set(old.get("temps_reel", [])))
old_btn = set() if isinstance(old, list) else set(old.get("boutons", []))
old_sw = set() if isinstance(old, list) else set(old.get("interrupteurs", []))
for key in old_jobs - set(jobs):
    pub(f"{DISC}/sensor/{OBJ}/sauvegarde_{key}/config", "")
for key in old_rt - set(rt):
    pub(f"{DISC}/sensor/{OBJ}/temps_reel_{key}/config", "")
for key in old_btn - set(buttons):
    pub(f"{DISC}/button/{OBJ}/{key}/config", "")
for key in old_sw - set(switches):
    pub(f"{DISC}/switch/{OBJ}/{key}/config", "")
with open(PUBLISHED, "w") as f:
    json.dump({"jobs": sorted(jobs), "temps_reel": sorted(rt), "boutons": sorted(buttons), "interrupteurs": sorted(switches)}, f)

pub(TOPIC, json.dumps(state, ensure_ascii=False))
PYEOF
}

suivi_configurer() {  # suivi_configurer <serveur MQTT>   (utilisateur / mot de passe sur stdin)
  local host="${1:-}" port=1883 mu="" mp=""
  [ -n "$host" ] || die "usage : nas-debian suivi configurer <serveur MQTT>"
  outils_requis mosquitto_pub python3 || die "outils manquants : lance d'abord « nas-debian outils installer suivi »."
  if [ ! -t 0 ]; then read -r mu || true; read -r mp || true; fi
  echo "== Connexion au serveur MQTT de Home Assistant ($host) =="
  if [ -z "$mu" ] && [ -f /root/.config/mosquitto_pub ] && mqtt mosquitto_pub -t "nas-$(ha_slug)/test" -m ok 2>/dev/null; then
    vert "OK : connexion MQTT deja configuree (conservee)"
  else
    [ -n "$mu" ] || die "utilisateur MQTT manquant."
    mkdir -p /root/.config
    printf -- "-h %s\n-p %s\n-u %s\n-P %s\n" "$host" "$port" "$mu" "$mp" > /root/.config/mosquitto_pub.new
    chmod 600 /root/.config/mosquitto_pub.new
    mv -f /root/.config/mosquitto_pub.new /root/.config/mosquitto_pub
    if mqtt mosquitto_pub -t "nas-$(ha_slug)/test" -m ok; then
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

# --------------------------- Actions depuis Home Assistant -----------
# Boutons « Lancer <sauvegarde> », « Arreter les sauvegardes », « Verifier maintenant » et
# interrupteurs « Temps reel <nom> actif » publies par ha-status ; leurs commandes arrivent
# sur nas-<machine>/commande et sont executees ici. Seules ces actions sont acceptees, et
# seulement pour des sauvegardes qui existent (nom compare a la liste, jamais interprete).
HA_ACT_UNIT="/etc/systemd/system/nas-ha-actions.service"
HA_ACT_PID="$STATE_DIR/ha-actions.pid"

ha_actions_actif() {
  if has_systemd; then systemctl is-active --quiet nas-ha-actions 2>/dev/null; return; fi
  local p; p=$(cat "$HA_ACT_PID" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

ha_actions_start() {
  if has_systemd; then
    local want
    want=$(printf '[Unit]\nDescription=Actions Home Assistant (nas-debian)\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nEnvironment=HOME=/root\nExecStart=%s ha-actions ecouter\nRestart=always\nRestartSec=15\n\n[Install]\nWantedBy=multi-user.target\n' "$SELF")
    if [ "$(cat "$HA_ACT_UNIT" 2>/dev/null)" != "$want" ]; then printf '%s\n' "$want" > "$HA_ACT_UNIT"; systemctl daemon-reload; fi
    systemctl enable --now nas-ha-actions >/dev/null 2>&1
    systemctl restart nas-ha-actions >/dev/null 2>&1
  else
    ha_actions_actif || { nohup setsid "$SELF" ha-actions ecouter >/dev/null 2>&1 < /dev/null & }
  fi
}

ha_actions_stop() {
  if has_systemd && [ -f "$HA_ACT_UNIT" ]; then
    systemctl disable --now nas-ha-actions >/dev/null 2>&1; rm -f "$HA_ACT_UNIT"; systemctl daemon-reload
  fi
  local p; p=$(cat "$HA_ACT_PID" 2>/dev/null)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && pkill -TERM -s "$(ps -o sid= -p "$p" | tr -d ' ')" 2>/dev/null
  rm -f "$HA_ACT_PID"
  return 0
}

ha_actions_ensure() {  # verification horaire : ecoute relancee si elle s'est arretee
  agent_conf_load
  [ "${HA_ACTIONS:-}" = oui ] || return 0
  ha_actions_actif || ha_actions_start
}

ha_actions_set() {  # ha_actions_set <oui|non>
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  case "${1:-}" in
    oui)
      outils_requis mosquitto_sub mosquitto_pub || die "outils manquants : lance d'abord « nas-debian outils installer suivi »."
      [ -f /root/.config/mosquitto_pub ] || die "connexion MQTT non configuree : installe d'abord le suivi Home Assistant (nas-debian suivi configurer)."
      # mosquitto_sub lit ses options dans son propre fichier : memes adresse et compte
      install -m 600 /root/.config/mosquitto_pub /root/.config/mosquitto_sub
      agent_conf_set HA_ACTIONS oui
      ha_actions_start
      sleep 1
      ha_actions_actif || die "l'ecoute des actions ne demarre pas (journalctl -u nas-ha-actions -n 30)."
      ha_status_cmd >/dev/null 2>&1 || true
      logl "actions depuis Home Assistant activees"
      vert "Actions depuis Home Assistant activees : boutons et interrupteurs ajoutes a l'appareil du NAS." ;;
    non)
      agent_conf_set HA_ACTIONS ""
      ha_actions_stop
      ha_status_cmd >/dev/null 2>&1 || true
      logl "actions depuis Home Assistant desactivees"
      vert "Actions depuis Home Assistant desactivees (boutons retires)." ;;
    *) die "usage : nas-debian suivi actions <oui|non>" ;;
  esac
}

ha_action_do() {  # ha_action_do <commande recue>
  local p="$1" act name
  act="${p%%|*}"; name=""; [[ "$p" == *"|"* ]] && name="${p#*|}"
  case "$act" in
    lancer)
      job_names 2>/dev/null | grep -qxF -- "$name" || { logl "Home Assistant : sauvegarde inconnue refusee ($name)"; return 1; }
      logl "Home Assistant : lancement de $name"
      rm -f "$STOPF"
      nohup setsid "$SELF" run "$name" >/dev/null 2>&1 < /dev/null & ;;
    arreter)
      logl "Home Assistant : arret des sauvegardes"
      "$SELF" stop >/dev/null 2>&1 ;;
    verifier)
      logl "Home Assistant : verification demandee"
      nohup setsid "$SELF" check >/dev/null 2>&1 < /dev/null & ;;
    pause|reprendre)
      rt_names | grep -qxF -- "$name" || { logl "Home Assistant : sauvegarde temps reel inconnue refusee ($name)"; return 1; }
      logl "Home Assistant : temps reel $name -> $act"
      if [ "$act" = pause ]; then
        "$SELF" temps-reel pause "$name" >/dev/null 2>&1
      elif [ -f "$STATE_DIR/rt-$name.pause" ]; then
        "$SELF" temps-reel reprendre "$name" >/dev/null 2>&1
      else
        "$SELF" temps-reel demarrer "$name" >/dev/null 2>&1
      fi ;;
    *) logl "Home Assistant : commande refusee ($(printf '%s' "$p" | tr -cd '[:print:]' | cut -c1-60))"; return 1 ;;
  esac
  # etat a jour dans Home Assistant quelques secondes apres
  ( sleep 4; ha_status_cmd >/dev/null 2>&1 ) &
  return 0
}

ha_actions_listen() {
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  nb_init
  echo $$ > "$HA_ACT_PID"
  local topic line last="" last_t=0 now
  topic="nas-$(ha_slug)/commande"
  while true; do
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      line="${line:0:200}"
      now=$(date +%s)
      # meme commande repetee dans les 10 s (double appui) : ignoree
      if [ "$line" = "$last" ] && [ $((now - last_t)) -lt 10 ]; then continue; fi
      last="$line"; last_t=$now
      ha_action_do "$line" || true
    done < <(mqtt mosquitto_sub -t "$topic" -q 1 2>/dev/null)
    sleep 15
  done
}

ha_actions_main() {
  case "${1:-}" in
    ecouter) ha_actions_listen ;;
    executer) shift; nb_init; ha_action_do "${1:-}" ;;
    *) die "usage : nas-debian ha-actions ecouter | executer <commande>" ;;
  esac
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
DEST_TYPES=" drive onedrive dropbox pcloud box yandex hidrive mega koofr protondrive b2 s3 sftp webdav smb local "
DEST_OAUTH=" drive onedrive dropbox pcloud box yandex hidrive "

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
        "yandex": "Yandex Disk", "hidrive": "HiDrive", "mega": "MEGA", "koofr": "Koofr", "protondrive": "Proton Drive",
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
    if t in ("mega", "koofr"):
        return "%s (%s)" % (NOMS[t], c.get("user", ""))
    if t == "protondrive":
        return "Proton Drive (%s)" % c.get("username", "")
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
dest_check() {  # dest_check <nom> [reveiller]  -> 0 joignable, 1 non, 2 en veille (reveil configure)
  local n="$1" ok=false err="" about="" veille=false a
  # machine en veille avec reveil configure : pas d'alerte (reveillee avant chaque usage),
  # sauf test explicite (reveiller)
  if reveil_get "$n"; then
    a="${W_ADDR:-$(dest_host "$n")}"
    if [ -n "$a" ] && ! wol_up "$a"; then
      if [ "${2:-}" = reveiller ]; then dest_wake "$n" >/dev/null || true; else veille=true; fi
    fi
  fi
  if [ "$veille" = true ]; then
    err="en veille : reveillee automatiquement avant chaque sauvegarde"
  elif ! err=$(dest_ready "$n"); then
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
    python3 - "$DEST_JSON" "$n" "$ok" "$err" "$about" "$veille" <<'PYDC'
import json, sys, time
path, n, ok, err, about, veille = sys.argv[1:7]
try:
    d = json.load(open(path))
except Exception:
    d = {}
e = {"ok": ok == "true", "verifie": int(time.time())}
if veille == "true":
    e["veille"] = True
    for k in ("total", "utilise", "libre"):
        if (d.get(n) or {}).get(k) is not None:
            e[k] = d[n][k]     # dernier espace connu
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
  [ "$veille" = true ] && return 2
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
  [ -f "$REVEIL_CONF" ] && { grep -v "^$n|" "$REVEIL_CONF" > "$REVEIL_CONF.new"; mv -f "$REVEIL_CONF.new" "$REVEIL_CONF"; }
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
               if [ -n "${2:-}" ]; then dest_check "$2" reveiller || true
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

# =========================== Reveil des machines (Wake-on-LAN) =======
# /etc/nas-backup/reveil.conf, une ligne par destination a reveiller (autre NAS, PC...) :
#   NOM (destination)|MAC|ADRESSE (vide = celle de la destination)|ATTENTE_S|APRES|SSH
#   APRES : rien (la machine se rendort d'elle-meme), veille ou arret : commande envoyee
#           en SSH a SSH (utilisateur@machine, cle /root/.ssh/id_nas_reveil) apres usage,
#           seulement si c'est nous qui l'avons reveillee.
# Avant une sauvegarde, un test, une verification ou une restauration qui l'utilise, une
# destination qui ne repond pas recoit le paquet magique, puis on attend qu'elle reponde.
REVEIL_CONF="$CONF_DIR/reveil.conf"
REVEIL_KEY="/root/.ssh/id_nas_reveil"
REVEIL_ATTENTE=180

valid_mac() { [[ "$1" =~ ^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$ ]]; }

# Destination de base d'un remote (gbackup -> gdrive, usb-chiffre -> usb)
base_remote() {
  local r="${1%%:*}"
  case "$r" in "$CRYPT"|gcrypt) echo "$GDRIVE" ;; *-chiffre) echo "${r%-chiffre}" ;; *) echo "$r" ;; esac
}

reveil_get() {  # reveil_get <destination> -> W_MAC W_ADDR W_WAIT W_AFTER W_SSH (1 si pas de reveil)
  local line
  [ -f "$REVEIL_CONF" ] || return 1
  line=$(grep -m1 "^$1|" "$REVEIL_CONF" 2>/dev/null) || return 1
  IFS='|' read -r _ W_MAC W_ADDR W_WAIT W_AFTER W_SSH <<< "$line"
  [[ "${W_WAIT:-}" =~ ^[0-9]+$ ]] || W_WAIT=$REVEIL_ATTENTE
  W_AFTER="${W_AFTER:-rien}"
  valid_mac "$W_MAC"
}

# Adresse reseau d'une destination (SFTP, SMB, WebDAV ; alias vers l'un d'eux)
dest_host() {  # dest_host <destination>
  python3 - "$(rclone_conf_file)" "$1" <<'PYDH' 2>/dev/null
import configparser, sys, urllib.parse
cp = configparser.RawConfigParser(strict=False, interpolation=None)
cp.read(sys.argv[1])
n = sys.argv[2]
for _ in range(4):
    if not cp.has_section(n):
        break
    c = dict(cp.items(n))
    t = c.get("type", "")
    if t in ("sftp", "smb", "ftp"):
        print(c.get("host", "")); break
    if t == "webdav":
        print(urllib.parse.urlsplit(c.get("url", "")).hostname or ""); break
    if t in ("alias", "crypt") and ":" in c.get("remote", ""):
        n = c["remote"].split(":", 1)[0]
        continue
    break
PYDH
}

# Paquet magique (UDP 9 et 7) : diffusion generale, diffusion de chaque reseau de la machine,
# et adresse de la machine quand elle est connue
wol_send() {  # wol_send <MAC> [adresse]
  python3 - "$1" "${2:-}" <<'PYWOL'
import re, socket, subprocess, sys
mac, host = sys.argv[1], sys.argv[2]
pkt = b"\xff" * 6 + bytes.fromhex(re.sub(r"[^0-9A-Fa-f]", "", mac)) * 16
cibles = {"255.255.255.255"}
try:
    out = subprocess.run(["ip", "-4", "-o", "addr", "show"], capture_output=True, text=True, timeout=5).stdout
    cibles |= set(re.findall(r"\bbrd (\d+\.\d+\.\d+\.\d+)", out))
except Exception:
    pass
if host:
    try:
        ip = socket.gethostbyname(host)
        cibles |= {ip, ip.rsplit(".", 1)[0] + ".255"}
    except OSError:
        pass
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
n = 0
for c in sorted(cibles):
    for port in (9, 7):
        try:
            s.sendto(pkt, (c, port))
            n += 1
        except OSError:
            pass
sys.exit(0 if n else 1)
PYWOL
}

# La machine repond-elle ? (connexion TCP sur les ports courants, « refusee » = allumee)
wol_up() {  # wol_up <adresse>   (NAS_REVEIL_PORTS : ports testes, pour les tests)
  python3 - "$1" "${NAS_REVEIL_PORTS:-22 445 139 80 443 5000 5001 2049 111 9200}" <<'PYUP'
import errno, select, socket, sys, time
try:
    ip = socket.gethostbyname(sys.argv[1])
except OSError:
    sys.exit(1)
socks = []
for port in map(int, sys.argv[2].split()):
    s = socket.socket()
    s.setblocking(False)
    r = s.connect_ex((ip, port))
    if r in (0, errno.ECONNREFUSED):
        sys.exit(0)
    socks.append(s)
fin = time.time() + 3
while socks and time.time() < fin:
    _, w, _ = select.select([], socks, [], max(0.05, fin - time.time()))
    for s in w:
        if s.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) in (0, errno.ECONNREFUSED):
            sys.exit(0)
        socks.remove(s)
sys.exit(1)
PYUP
}

# Reveille une destination si besoin -> 0 si elle repond (ou sans reveil configure) ; message sinon
dest_wake() {  # dest_wake <destination>
  local r a i t0
  r=$(base_remote "$1")
  reveil_get "$r" || return 0
  a="${W_ADDR:-$(dest_host "$r")}"
  [ -n "$a" ] || { echo "adresse de « $r » inconnue : indique-la dans le reveil de la destination"; return 1; }
  wol_up "$a" && return 0
  logl "$r : reveil (Wake-on-LAN $W_MAC, $a)"
  t0=$(date +%s)
  wol_send "$W_MAC" "$a" || true
  for ((i = 1; i * 5 <= W_WAIT; i++)); do
    sleep 5
    if wol_up "$a"; then
      sleep "${REVEIL_DEMARRAGE:-15}"     # services (SSH, partages) encore en demarrage
      date +%s > "$STATE_DIR/reveil-$r"
      logl "$r : reveillee en $(( $(date +%s) - t0 )) s"
      return 0
    fi
    [ $((i % 6)) -eq 0 ] && { wol_send "$W_MAC" "$a" || true; }
  done
  logl "$r : ne repond pas apres le reveil ($W_WAIT s)"
  echo "la machine ne repond pas apres le reveil ($W_WAIT s) : Wake-on-LAN active dans son BIOS / ses reglages, adresse MAC correcte ?"
  return 1
}

# Apres usage : remise en veille ou arret, si c'est nous qui l'avons reveillee et que plus
# rien ne l'utilise
dest_rest() {  # dest_rest <destination>
  local r cmd
  r=$(base_remote "$1")
  [ -f "$STATE_DIR/reveil-$r" ] || return 0
  reveil_get "$r" || { rm -f "$STATE_DIR/reveil-$r"; return 0; }
  pgrep -f "(rclone|restic) .*[ =:]$r(-chiffre)?:" >/dev/null && return 0
  rm -f "$STATE_DIR/reveil-$r"
  case "$W_AFTER" in
    veille) cmd='systemctl suspend 2>/dev/null || pm-suspend 2>/dev/null || echo mem > /sys/power/state' ;;
    arret)  cmd='systemctl poweroff 2>/dev/null || synoshutdown -s 2>/dev/null || poweroff' ;;
    *) return 0 ;;
  esac
  [ -n "$W_SSH" ] && [ -f "$REVEIL_KEY" ] || { logl "$r : remise en $W_AFTER impossible (compte SSH ou cle absents)"; return 0; }
  logl "$r : remise en $W_AFTER ($W_SSH)"
  timeout 30 ssh -i "$REVEIL_KEY" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
    "$W_SSH" "$cmd" >/dev/null 2>&1 < /dev/null &
  return 0
}

reveil_list() {  # JSON : reglages de reveil de chaque destination
  python3 - "$REVEIL_CONF" "$REVEIL_KEY.pub" <<'PYRL'
import json, os, sys
out = {"cle": "", "destinations": {}}
try:
    out["cle"] = open(sys.argv[2]).read().strip()
except OSError:
    pass
try:
    for l in open(sys.argv[1]):
        p = l.rstrip("\n").split("|")
        if len(p) >= 2 and p[0] and not p[0].startswith("#"):
            p += [""] * (6 - len(p))
            out["destinations"][p[0]] = {"mac": p[1], "adresse": p[2], "attente": int(p[3]) if p[3].isdigit() else 180,
                                         "apres": p[4] or "rien", "ssh": p[5]}
except OSError:
    pass
print(json.dumps(out, ensure_ascii=False))
PYRL
}

reveil_main() {
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  mkdir -p "$CONF_DIR" "$STATE_DIR"
  case "${1:-liste}" in
    liste) reveil_list ;;
    regler)   # regler NOM MAC [ADRESSE] [ATTENTE] [APRES] [SSH]
      local n="${2:-}" mac="${3:-}" a="${4:-}" w="${5:-}" ap="${6:-rien}" s="${7:-}"
      [ "$a" = - ] && a=""; [ "$w" = - ] && w=""; [ "$s" = - ] && s=""
      [[ "$n" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || die "destination invalide : $n"
      remote_exists "$n" || die "destination « $n » introuvable."
      valid_mac "$mac" || die "adresse MAC invalide (ex. 00:11:32:AA:BB:CC)."
      [[ -z "$a" || "$a" =~ ^[A-Za-z0-9._-]+$ ]] || die "adresse invalide : $a"
      [[ -z "$w" || ( "$w" =~ ^[0-9]+$ && "$w" -ge 30 && "$w" -le 900 ) ]] || die "attente invalide (30 a 900 s)."
      [[ "$ap" =~ ^(rien|veille|arret)$ ]] || die "apres invalide (rien, veille ou arret)."
      [[ -z "$s" || "$s" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$ ]] || die "compte SSH invalide (utilisateur@machine)."
      [ "$ap" = rien ] || [ -n "$s" ] || die "indique le compte SSH (utilisateur@machine) pour la mise en veille ou l'arret."
      [ -n "$a" ] || [ -n "$(dest_host "$n")" ] || die "adresse de la machine inconnue pour « $n » : indique-la."
      touch "$REVEIL_CONF"; chmod 600 "$REVEIL_CONF"
      { grep -v "^$n|" "$REVEIL_CONF"; echo "$n|${mac^^}|$a|${w:-$REVEIL_ATTENTE}|$ap|$s"; } > "$REVEIL_CONF.new"
      mv -f "$REVEIL_CONF.new" "$REVEIL_CONF"
      if [ "$ap" != rien ] && [ ! -f "$REVEIL_KEY" ]; then
        mkdir -p /root/.ssh; chmod 700 /root/.ssh
        ssh-keygen -t ed25519 -N "" -C "nas-reveil@$(hostname -s 2>/dev/null)" -f "$REVEIL_KEY" -q
      fi
      vert "Reveil de « $n » enregistre ($mac)."
      if [ "$ap" != rien ]; then
        echo "Pour la mise en $ap, autorise cette cle sur $s (~/.ssh/authorized_keys) :"
        cat "$REVEIL_KEY.pub"
      fi ;;
    retirer)
      [ -n "${2:-}" ] || die "usage : reveil retirer <NOM>"
      [ -f "$REVEIL_CONF" ] && { grep -v "^$2|" "$REVEIL_CONF" > "$REVEIL_CONF.new"; mv -f "$REVEIL_CONF.new" "$REVEIL_CONF"; }
      rm -f "$STATE_DIR/reveil-$2"
      vert "Reveil de « $2 » retire." ;;
    tester)
      [ -n "${2:-}" ] || die "usage : reveil tester <NOM>"
      reveil_get "$2" || die "pas de reveil configure pour « $2 »."
      local a t0 msg; a="${W_ADDR:-$(dest_host "$2")}"
      if wol_up "$a"; then vert "« $2 » ($a) est deja allume : rien a reveiller."; return 0; fi
      t0=$(date +%s)
      REVEIL_DEMARRAGE=0 msg=$(dest_wake "$2") || die "$msg"
      vert "« $2 » reveille en $(( $(date +%s) - t0 )) s."
      dest_rest "$2" ;;
    envoyer)   # envoyer MAC [ADRESSE]
      valid_mac "${2:-}" || die "adresse MAC invalide."
      wol_send "$2" "${3:-}" || die "envoi impossible."
      vert "Paquet de reveil envoye a $2." ;;
    *) die "usage : nas-debian reveil liste | regler NOM MAC [ADRESSE] [ATTENTE] [APRES] [SSH] | retirer NOM | tester NOM | envoyer MAC [ADRESSE]" ;;
  esac
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
RT_EXCL_DIRS=('@eaDir' '#recycle' '.Trash-*' '#snapshot' '.SynologyWorkingDirectory' '.corbeille-doublons')
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
  dest_wake "$R_DEST" >/dev/null || true      # destination en veille (reveil configure)
  local -a common=(--log-file "$log" --log-level INFO --retries 3)
  local bw; bw=$(bw_of "$R_BW")
  [ -n "$bw" ] && common+=(--bwlimit "$bw")
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
  local bw; bw=$(bw_of "$R_BW")
  [ -n "$bw" ] && common+=(--bwlimit "$bw")
  # destination en veille (reveil configure) : on ne la reveille que s'il y a du nouveau
  # (les suppressions sont repercutees au fil de l'eau, ce qui la reveille aussi)
  local mk="$STATE_DIR/rt-$R_NAME.rattrapage" wa=""
  if reveil_get "$(base_remote "$R_DEST")"; then
    wa="${W_ADDR:-$(dest_host "$(base_remote "$R_DEST")")}"
    if [ "${2:-}" != initial ] && [ -f "$mk" ] && [ -n "$wa" ] && ! wol_up "$wa" \
       && [ -z "$(find "${R_SRCS[@]}" -newer "$mk" -type f -print -quit 2>/dev/null)" ]; then
      rm -f "$tmp"; return 0
    fi
  fi
  touch "$mk"
  rt_log "rattrapage$( [ "${2:-}" = initial ] && echo " (envoi complet)") : debut"
  dest_wake "$R_DEST" >/dev/null || true
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
        "$STATE_DIR/$1.d" "$STATE_DIR/$1.dest" "$STATE_DIR/$1.run.all" "$STATE_DIR/alertes/versions-$1" "$STATE_DIR/$1.entretien.json" \
        "$STATE_DIR/$1.lastdebut" "$STATE_DIR/$1.test.json" "$STATE_DIR/$1.test.log" "$STATE_DIR/$1.test.res" "$STATE_DIR/alertes/test-$1"
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
    # test de restauration a blanc
    if [ -f "$TEST_CONF" ]; then
      local td tt
      read -r td tt _ < "$TEST_CONF"
      [[ "$td" =~ ^[1-7]+$ && "$tt" =~ ^[0-9]{2}:[0-9]{2}$ ]] && \
        echo "$((10#${tt##*:})) $((10#${tt%%:*})) * * $(echo "$td" | sed 's/./&,/g; s/,$//; s/7/0/') root $SELF test-restauration tout >/dev/null 2>&1"
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
  perf_load "$J_PERF"
  local bw; bw=$(bw_of "${J_BW:-}")
  [ -n "$bw" ] && opts+=(--bwlimit "$bw")
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
  local a="serve restic --stdio --b2-hard-delete" bw
  bw=$(bw_of "${J_BW:-}")
  [ -n "$bw" ] && a="$a --bwlimit \"$bw\""
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
    elif ! msg=$(dest_wake "$r"); then
      echo "$(date '+%Y/%m/%d %H:%M:%S') ERROR : destination « $r » : $msg" >> "$runlog"; rcd=1
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
  # machines reveillees pour cette sauvegarde : remises en veille si demande
  for ((i = 0; i < n; i++)); do dest_rest "${JD_R[i]}"; done

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
    echo "$t0" > "$STATE_DIR/$J_NAME.lastdebut"     # tout ce qui est plus ancien est sur les destinations
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
  local msg; msg=$(dest_wake "$DI_R") || die "$msg"
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
  dest_rest "$DI_R"
  return $rc
}

restore_done() {  # restore_done <code> <cible> <element>
  local st="$STATE_DIR/restauration.status" rlog="$STATE_DIR/restauration.log"
  local quand=""
  [ -n "${RESTAU_DATE:-}" ] && quand=" (état au $(date -d "@$RESTAU_DATE" '+%d/%m/%Y %H:%M'))"
  if [ "$1" -eq 0 ]; then
    printf 'ETAT=ok\nNOM=%q\nCIBLE=%q\nELEMENT=%q\nFIN=%s\nDATE=%s\n' "$J_NAME" "$2" "$3" "$(date +%s)" "${RESTAU_DATE:-}" > "$st"
    logl "$J_NAME : restauration terminee ($2)$quand"
    notify info "restore-$J_NAME" "Restauration « $J_NAME » terminée" "Fichiers restaurés dans $2$quand"
  else
    printf 'ETAT=echec\nNOM=%q\nCIBLE=%q\nELEMENT=%q\nFIN=%s\nCODE=%s\nDATE=%s\n' "$J_NAME" "$2" "$3" "$(date +%s)" "$1" "${RESTAU_DATE:-}" > "$st"
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
  local msg; msg=$(dest_wake "$DI_R") || die "$msg"
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
    if ! etat_d=$(dest_wake "$r"); then
      echo "${lab}$etat_d" >> "$out.d/erreurs"; c_err=$((c_err + 1)); dstat="${dstat:+$dstat;}$r:echec"; continue
    fi
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
  for ((i = 0; i < n; i++)); do dest_rest "${JD_R[i]}"; done
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

# =========================== Test de restauration a blanc ============
# Quelques fichiers pris au hasard dans la source (modifies avant la derniere sauvegarde
# reussie) sont restaures depuis chaque destination dans un dossier temporaire, compares
# octet par octet aux originaux, puis effaces. Alerte critique en cas d'ecart.
# Resultat : $STATE_DIR/<nom>.test.json ; historique : tests-restauration.jsonl
TEST_CONF="$CONF_DIR/test-restauration"      # test automatique : « JOURS HH:MM NB »
TEST_HIST="$STATE_DIR/tests-restauration.jsonl"

test_nb_defaut() {
  local j h n=""
  [ -f "$TEST_CONF" ] && read -r j h n < "$TEST_CONF"
  if [[ "$n" =~ ^[0-9]+$ ]]; then echo "$n"; else echo 5; fi
}

# Debut de la derniere sauvegarde reussie : tout fichier modifie avant est sur les destinations
test_last_ok() {
  local t
  t=$(cat "$STATE_DIR/$J_NAME.lastdebut" 2>/dev/null)
  [[ "$t" =~ ^[0-9]+$ ]] && { echo "$t"; return; }
  t=$(cat "$STATE_DIR/$J_NAME.lastok" 2>/dev/null)
  if [[ "$t" =~ ^[0-9]+$ ]]; then echo $((t - 86400)); else echo 0; fi   # anciennes installations : marge d'un jour
}

# Fichiers tires au hasard dans la source : modifies avant <date>, 64 Mo au plus chacun,
# 256 Mo en tout -> chemins relatifs, un par ligne
test_pick() {  # test_pick <source> <date> <nb>
  python3 - "$1" "$2" "$3" <<'PYPICK'
import os, random, stat, sys, time
src, avant, nb = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
MAXF, MAXT, K, fin = 64 << 20, 256 << 20, 4000, time.time() + 900
res, vus = [], 0
for root, dirs, files in os.walk(src):
    dirs[:] = [x for x in dirs if x not in ("@eaDir", "#recycle") and not x.startswith(".Trash-")]
    for f in files:
        if "\n" in f:
            continue
        p = os.path.join(root, f)
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if not stat.S_ISREG(st.st_mode) or st.st_size == 0 or st.st_size > MAXF or st.st_mtime >= avant:
            continue
        vus += 1
        if len(res) < K:
            res.append((p, st.st_size))
        else:
            j = random.randrange(vus)
            if j < K:
                res[j] = (p, st.st_size)
    if time.time() > fin:      # tres gros dossier : echantillon de ce qui a ete parcouru
        break
random.shuffle(res)
tot, out = 0, []
for p, sz in res:
    if len(out) >= nb:
        break
    if tot + sz <= MAXT:
        out.append(os.path.relpath(p, src))
        tot += sz
print("\n".join(out))
PYPICK
}

# Derniere version d'une sauvegarde versionnee sur la destination preparee (RST) -> « id date dossier »
test_last_snap() {
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
    v = []
if v:
    x = max(v, key=lambda x: ts(x.get("time", "")))
    print(x.get("id", ""), ts(x.get("time", "")), (x.get("paths") or [""])[0])'
}

test_restore() {  # test_restore <nom> [nb]
  job_get "$1" || die "sauvegarde '$1' introuvable."
  local nb="${2:-}" out="$STATE_DIR/$J_NAME.test" tmp i n r e avant=0 rel res rc t0 det sz msg snap sd root
  [[ "$nb" =~ ^[0-9]+$ ]] && [ "$nb" -ge 1 ] && [ "$nb" -le 50 ] || nb=$(test_nb_defaut)
  exec 6>"/run/nas-backup-test-$J_NAME.lock"
  flock -n 6 || die "un test de restauration de '$J_NAME' est deja en cours."
  t0=$(date +%s)
  : > "$out.log"; : > "$out.res"
  # sauvegarde en cours : attendre qu'elle se termine (2 h au plus) sans la bloquer
  for ((i = 0; i < 240; i++)); do
    flock -n "/run/nas-backup-$J_NAME.lock" true 2>/dev/null && break
    [ $i -eq 0 ] && echo "Sauvegarde « $J_NAME » en cours : le test attend sa fin." | tee -a "$out.log"
    sleep 30
  done
  job_dests; n=${#JD_R[@]}
  perf_load "$J_PERF"
  tmp=$(mktemp -d /var/tmp/nas-test-restauration.XXXXXX) || die "dossier temporaire impossible."
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  local -a DERR=() DSNAP=() DROOT=()
  for ((i = 0; i < n; i++)); do
    r="${JD_R[i]}"; DERR[i]=""; DSNAP[i]=""; DROOT[i]=""
    if ! remote_exists "$r"; then DERR[i]="destination introuvable"; continue; fi
    if ! msg=$(dest_wake "$r"); then DERR[i]="$msg"; continue; fi
    if ! msg=$(dest_ready "$r"); then DERR[i]="$msg"; continue; fi
    if [ "$J_MODE" = versions ]; then
      need_restic >/dev/null || { DERR[i]="restic n'est pas installe"; continue; }
      restic_prep "$r"
      snap=""; sd=0; root=""
      read -r snap sd root < <(test_last_snap)
      [ -n "${snap:-}" ] || continue        # pas encore de version ici (voir plus bas)
      DSNAP[i]="$snap"; DROOT[i]="$root"
      { [ "$avant" -eq 0 ] || [ "$sd" -lt "$avant" ]; } && avant=$sd
    else
      sd=$(test_last_ok)
      [ "$sd" -gt 0 ] && avant=$sd
    fi
  done
  # versions : une destination sans version alors que les autres en ont = probleme
  if [ "$J_MODE" = versions ] && [ "$avant" -gt 0 ]; then
    for ((i = 0; i < n; i++)); do
      [ -z "${DERR[i]}" ] && [ -z "${DSNAP[i]}" ] && DERR[i]="aucune version sur cette destination"
    done
  fi
  if [ ! -d "$J_SRC" ]; then
    msg="dossier source introuvable : $J_SRC"
  elif [ "$avant" -gt 0 ]; then
    test_pick "$J_SRC" "$avant" "$nb" > "$tmp/liste" 2>>"$out.log"
    [ -s "$tmp/liste" ] || msg="aucun fichier assez ancien a tester (tout a change depuis la derniere sauvegarde ?)"
  else
    msg="aucune sauvegarde reussie pour le moment"
  fi
  for ((i = 0; i < n; i++)); do
    r="${JD_R[i]}"; e="${JD_E[i]}"
    if [ -n "${DERR[i]}" ]; then
      printf '%s\037%s\037%s\037%s\037%s\n' "$r" erreur 0 "" "${DERR[i]}" >> "$out.res"; continue
    fi
    [ -s "$tmp/liste" ] || continue
    [ "$J_MODE" = versions ] && [ -z "${DSNAP[i]}" ] && continue
    [ "$J_MODE" = versions ] && restic_prep "$r"
    while IFS= read -r rel; do
      sz=$(stat -c %s "$J_SRC/$rel" 2>/dev/null || echo 0); det=""
      if [ "$J_MODE" = versions ]; then
        restic "${RST[@]}" dump "${DSNAP[i]}" "${DROOT[i]}/$rel" > "$tmp/f" 2> "$tmp/err" < /dev/null; rc=$?
      else
        timeout 1800 rclone cat "$(dest_path "$r" "$e" "$J_SUB")/$rel" ${J_BW:+--bwlimit "$J_BW"} > "$tmp/f" 2> "$tmp/err" < /dev/null; rc=$?
      fi
      if [ $rc -ne 0 ]; then
        if grep -qiE 'not found|no such file|does not exist|doesn.t exist' "$tmp/err"; then res=absent; else res=erreur; fi
        det=$(grep -v '^\s*$' "$tmp/err" | tail -n 1 | sed -E 's/^[0-9\/ :]+//; s/^(ERROR|Fatal) *: *//' | cut -c1-200)
      elif cmp -s "$tmp/f" "$J_SRC/$rel"; then
        res=identique
      elif [ "$(stat -c %Y "$J_SRC/$rel" 2>/dev/null || echo 0)" -ge "$avant" ]; then
        res=identique; det="modifie pendant le test"
      else
        res=different; det="$(stat -c %s "$tmp/f") octets restaures pour $sz"
      fi
      printf '%s\037%s\037%s\037%s\037%s\n' "$r" "$res" "$sz" "$rel" "$det" >> "$out.res"
      cat "$tmp/err" >> "$out.log"
      rm -f "$tmp/f" "$tmp/err"
    done < "$tmp/liste"
  done
  for ((i = 0; i < n; i++)); do dest_rest "${JD_R[i]}"; done
  local etat resume
  python3 - "$out.res" "$out.json" "$TEST_HIST" "$J_NAME" "$t0" "${msg:-}" > "$tmp/resume" <<'PYTEST'
import json, sys, time
res, out, hist, nom, t0, msg = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6]
fichiers, dests = [], {}
for l in open(res, errors="ignore"):
    p = l.rstrip("\n").split("\x1f")
    if len(p) < 5:
        continue
    d, r, sz, chemin, det = p[:5]
    dests.setdefault(d, set()).add(r)
    if chemin:
        fichiers.append({"destination": d, "chemin": chemin, "taille": int(sz or 0), "resultat": r, "detail": det})
    elif det:
        msg = msg or "%s : %s" % (d, det)
        fichiers.append({"destination": d, "chemin": "", "taille": 0, "resultat": "erreur", "detail": det})
ok = sum(1 for f in fichiers if f["resultat"] == "identique")
ec = sum(1 for f in fichiers if f["resultat"] in ("different", "absent"))
er = sum(1 for f in fichiers if f["resultat"] == "erreur")
nbf = len({f["chemin"] for f in fichiers if f["chemin"]})
if ec:
    etat = "ecarts"
elif er:
    etat = "echec"
elif ok:
    etat = "ok"
else:
    etat = "vide"
def de(s):
    return "ecarts" if s & {"different", "absent"} else "echec" if "erreur" in s else "ok"
d = {"debut": t0, "fin": int(time.time()), "etat": etat, "nb": nbf, "identiques": ok, "ecarts": ec, "erreurs": er,
     "destinations": ";".join("%s:%s" % (k, de(v)) for k, v in dests.items()), "message": msg, "fichiers": fichiers[:200]}
json.dump(d, open(out, "w"), ensure_ascii=False)
h = {k: d[k] for k in ("debut", "fin", "etat", "nb", "identiques", "ecarts", "erreurs", "destinations")}
h["nom"] = nom
with open(hist, "a") as f:
    f.write(json.dumps(h, ensure_ascii=False) + "\n")
pl = lambda n: "s" if n > 1 else ""
if etat == "ok":
    txt = "%d fichier%s restauré%s et identique%s aux originaux" % (nbf, pl(nbf), pl(nbf), pl(nbf))
    if len(dests) > 1:
        txt += " (%d destinations)" % len(dests)
elif etat == "ecarts":
    k = [f for f in fichiers if f["resultat"] in ("different", "absent")]
    txt = "%d écart%s : %s" % (ec, pl(ec), " ; ".join("%s%s (%s)" % ("[%s] " % f["destination"] if len(dests) > 1 else "", f["chemin"], "absent de la sauvegarde" if f["resultat"] == "absent" else "contenu différent") for f in k[:3]))
elif etat == "echec":
    k = [f for f in fichiers if f["resultat"] == "erreur"]
    txt = "restauration impossible : " + " ; ".join("%s (%s)" % (f["destination"], f["detail"]) for f in k[:2])
else:
    txt = msg or "rien à tester"
print(etat)
print(txt[:400])
PYTEST
  { IFS= read -r etat; IFS= read -r resume; } < "$tmp/resume"
  if [ "$(wc -l < "$TEST_HIST" 2>/dev/null || echo 0)" -gt 2000 ]; then tail -n 1500 "$TEST_HIST" > "$TEST_HIST.tmp" && mv -f "$TEST_HIST.tmp" "$TEST_HIST"; fi
  logl "$J_NAME : test de restauration $etat ($resume)"
  case "$etat" in
    ok)     notify ok "test-$J_NAME" "Test de restauration « $J_NAME »" "Réussi : $resume."; vert "Test de restauration de '$J_NAME' : OK ($resume)" ;;
    ecarts) notify critique "test-$J_NAME" "Test de restauration « $J_NAME » : écarts" "$resume. Lance une vérification d'intégrité depuis NAS Manager."; rouge "Test de restauration de '$J_NAME' : ECARTS ($resume)" ;;
    echec)  notify critique "test-$J_NAME" "Test de restauration « $J_NAME » impossible" "$resume."; rouge "Test de restauration de '$J_NAME' : ECHEC ($resume)" ;;
    *)      jaune "Test de restauration de '$J_NAME' : rien a tester ($resume)" ;;
  esac
  [ "$etat" = ok ] || [ "$etat" = vide ]
}

test_all() {
  local n nb
  nb=$(test_nb_defaut)
  for n in $(job_names); do ( test_restore "$n" "$nb" ) || true; done
}

test_main() {
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  case "${1:-}" in
    tout) need_rclone; test_all ;;
    planifier)   # planifier <JOURS|non> [HH:MM] [NB]
      if [ "${2:-}" = non ]; then rm -f "$TEST_CONF"; gen_cron; vert "Test de restauration automatique desactive."; return; fi
      [[ "${2:-}" =~ ^[1-7]+$ ]] || die "jours invalides (1 = lundi ... 7 = dimanche)."
      [[ "${3:-}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "heure invalide (HH:MM)."
      [[ -z "${4:-}" || ( "${4:-}" =~ ^[0-9]+$ && "$4" -ge 1 && "$4" -le 50 ) ]] || die "nombre de fichiers invalide (1 a 50)."
      echo "$2 $3 ${4:-5}" > "$TEST_CONF"; gen_cron
      vert "Test de restauration automatique : jours $2 a $3, ${4:-5} fichiers par sauvegarde." ;;
    "") die "usage : nas-debian test-restauration <NOM> [NB] | tout | planifier <JOURS|non> [HH:MM] [NB]" ;;
    *) need_rclone; test_restore "$1" "${2:-}" ;;
  esac
}

# =========================== Retour a une date =======================
# Sauvegarde miroir avec corbeille : l'etat de la destination a une date D se reconstruit
# avec la corbeille datee. Le dossier de corbeille AAAA-MM-JJ_HHMM contient les fichiers
# remplaces ou supprimes par l'execution commencee a cette heure-la, tels qu'ils etaient juste
# avant. Pour chaque fichier, le premier dossier de corbeille posterieur a D qui le contient
# donne sa version a la date D (s'il existait deja : modifie avant D) ; sinon c'est la version
# actuelle, si elle date d'avant D. Precision : l'etat aux heures des sauvegardes. Limite : la
# duree de la corbeille (les dossiers plus anciens sont effaces).
# Sauvegarde versionnee : la derniere version enregistree avant D.

date_ts() {  # date_ts <secondes | AAAA-MM-JJ HH:MM> -> secondes
  if [[ "$1" =~ ^[0-9]{9,11}$ ]]; then echo "$1"; else date -d "$1" +%s 2>/dev/null; fi
}

# Dossiers de corbeille (date + nom) de la sauvegarde chargee, destination DI_*
date_trash_dirs() {
  local t ts
  rclone lsf --dirs-only "$(trash_path "$DI_R" "$DI_E" "$J_NAME")" 2>/dev/null < /dev/null | while IFS= read -r t; do
    t="${t%/}"
    [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4} ]] || continue
    ts=$(date -d "${t:0:10} ${t:11:2}:${t:13:2}" +%s 2>/dev/null) || continue
    echo "$ts $t"
  done | sort -n
}

# Dates auxquelles on peut revenir (JSON) : methode, date la plus ancienne, points de restauration
date_plage() {  # date_plage <nom> [destination]
  job_get "$1" || die "sauvegarde '$1' introuvable."
  job_dest_at "${2:-0}"
  local now; now=$(date +%s)
  if [ "$J_MODE" = versions ]; then
    local v; v=$(versions_list "$1" "${2:-0}") || exit 1
    python3 -c '
import json, sys
v = json.loads(sys.argv[1]) or []
d = sorted(x["date"] for x in v if x.get("date"))
print(json.dumps({"methode": "versions", "min": d[0] if d else None, "max": int(sys.argv[2]), "points": d}))' "$v" "$now"
  elif [ "$J_MODE" = sync ] && [ "${J_RET:-0}" -gt 0 ]; then
    local msg; msg=$(dest_wake "$DI_R") || die "$msg"
    date_trash_dirs | python3 -c '
import json, sys
now, ret, debut = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3] or 0)
pts = [int(l.split()[0]) for l in sys.stdin if l.strip()]
mn = now - ret * 86400 + 3600
if debut and debut > mn:
    mn = debut
print(json.dumps({"methode": "corbeille", "min": mn, "max": now, "points": pts, "jours": ret}))' "$now" "$J_RET" "$(date_first_run)"
  else
    echo '{"methode":"aucune","min":null,"max":null,"points":[]}'
  fi
}

# Premiere sauvegarde reussie connue (historique), 0 si inconnue
date_first_run() {
  python3 - "$STATE_DIR/historique.jsonl" "$J_NAME" <<'PYFR' 2>/dev/null || echo 0
import json, sys
best = 0
for l in open(sys.argv[1], errors="ignore"):
    try:
        d = json.loads(l)
    except ValueError:
        continue
    if d.get("nom") == sys.argv[2] and d.get("etat") == "OK" and d.get("debut"):
        best = d["debut"] if not best else min(best, d["debut"])
print(best)
PYFR
}

# Plan d'une restauration a une date (miroir + corbeille) : listes de fichiers par origine
#   <w>/liste-actuel (destination actuelle) et <w>/liste-<dossier de corbeille>
# -> resume JSON sur la sortie
date_plan() {  # date_plan <dossier de travail> <date> <element>
  local w="$1" d="$2" rel="$3" dest trash ts t
  dest=$(dest_path "$DI_R" "$DI_E" "$J_SUB"); trash=$(trash_path "$DI_R" "$DI_E" "$J_NAME")
  if ! rclone lsjson -R --files-only --no-mimetype "${EXCLUDES[@]}" "$dest${rel:+/$rel}" > "$w/actuel.json" 2> "$w/err" < /dev/null; then
    grep -qi 'directory not found' "$w/err" || { tail -n 2 "$w/err" >&2; return 1; }
    echo '[]' > "$w/actuel.json"
  fi
  : > "$w/corbeilles"
  while read -r ts t; do
    [ "$ts" -gt "$d" ] || continue
    rclone lsjson -R --files-only --no-mimetype "$trash/$t${rel:+/$rel}" > "$w/c-$t.json" 2>/dev/null < /dev/null || echo '[]' > "$w/c-$t.json"
    echo "$ts $t" >> "$w/corbeilles"
  done < <(date_trash_dirs)
  python3 - "$w" "$d" <<'PYPLAN'
import json, os, sys
from datetime import datetime
w, d = sys.argv[1], int(sys.argv[2])
def ts(s):
    try:
        base, frac = (s.split(".", 1) + [""])[:2]
        tz = frac.lstrip("0123456789") if frac else s[19:]
        return int(datetime.fromisoformat(base[:19] + (tz or "+00:00").replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0
def load(p):
    try:
        return json.load(open(p)) or []
    except (OSError, ValueError):
        return []
corb = sorted((int(l.split()[0]), l.split()[1]) for l in open(os.path.join(w, "corbeilles")) if l.strip())
plan, absent = {}, set()
for t, nom in corb:                      # du plus proche de D au plus recent
    for f in load(os.path.join(w, "c-%s.json" % nom)):
        p = f.get("Path", "")
        if not p or "\n" in p or p in plan or p in absent:
            continue
        if ts(f.get("ModTime", "")) <= d:
            plan[p] = (nom, f.get("Size", 0))
        else:
            absent.add(p)                # cree apres D, puis remplace ou supprime
for f in load(os.path.join(w, "actuel.json")):
    p = f.get("Path", "")
    if not p or "\n" in p or p in plan or p in absent:
        continue
    if ts(f.get("ModTime", "")) <= d:
        plan[p] = ("", f.get("Size", 0))
listes = {}
for p, (src, _) in plan.items():
    listes.setdefault(src or "actuel", []).append(p)
for src, ps in listes.items():
    with open(os.path.join(w, "liste-" + src), "w") as fo:
        fo.write("".join(x + "\n" for x in sorted(ps)))
nc = sum(1 for s, _ in plan.values() if s)
print(json.dumps({"methode": "corbeille", "date": d, "fichiers": len(plan), "octets": sum(max(0, s) for _, s in plan.values()),
                  "depuis_corbeille": nc, "dossiers_corbeille": len([k for k in listes if k != "actuel"])}))
PYPLAN
}

# Version la plus recente enregistree avant <date> -> « id date » (vide si aucune)
date_snap() {  # date_snap <nom> <destination> <date>
  local v; v=$(versions_list "$1" "$2") || return 1
  python3 -c '
import json, sys
d = int(sys.argv[2])
v = [x for x in (json.loads(sys.argv[1]) or []) if x.get("date") and x["date"] <= d]
if v:
    x = max(v, key=lambda x: x["date"])
    print(x["id"], x["date"])' "$v" "$3"
}

date_check_args() {  # date_check_args <nom> <destination> <date> [element]  -> D, REL
  job_get "$1" || die "sauvegarde '$1' introuvable."
  job_dest_at "${2:-0}"
  D=$(date_ts "${3:-}") && [ -n "$D" ] || die "date invalide : ${3:-} (AAAA-MM-JJ HH:MM)"
  [ "$D" -le "$(date +%s)" ] || die "la date est dans le futur."
  safe_rel "${4:-}"
  if [ "$J_MODE" != versions ] && { [ "$J_MODE" != sync ] || [ "${J_RET:-0}" -le 0 ]; }; then
    die "retour a une date impossible pour « $J_NAME » : il faut une sauvegarde miroir avec corbeille, ou versionnee."
  fi
}

# Apercu (JSON) : nombre de fichiers et volume qui seraient restaures
date_apercu() {  # date_apercu <nom> <destination> <date> [element]
  date_check_args "$@"
  if [ "$J_MODE" = versions ]; then
    local id sd
    read -r id sd < <(date_snap "$1" "${2:-0}" "$D")
    [ -n "${id:-}" ] || die "aucune version enregistree avant cette date."
    printf '{"methode":"versions","date":%s,"version":"%s","date_version":%s}\n' "$D" "$id" "$sd"
    return
  fi
  local msg; msg=$(dest_wake "$DI_R") || die "$msg"
  local w; w=$(mktemp -d)
  date_plan "$w" "$D" "$REL"; local rc=$?
  rm -rf "$w"
  return $rc
}

# Restauration de l'etat a une date (en arriere-plan depuis NAS Manager)
date_restore() {  # date_restore <nom> <destination> <date> <dossier cible> [element]
  date_check_args "$1" "$2" "$3" "${5:-}"
  local target="${4%/}" st="$STATE_DIR/restauration.status" rlog="$STATE_DIR/restauration.log" rc=0 w f src tgt msg
  [ -n "$target" ] || die "dossier de restauration manquant."
  if [ "$J_MODE" = versions ]; then
    local id sd
    read -r id sd < <(date_snap "$1" "${2:-0}" "$D")
    [ -n "${id:-}" ] || die "aucune version enregistree avant cette date."
    RESTAU_DATE="$D" versions_restore "$1" "${2:-0}" "$id" "$target" "$REL"
    return $?
  fi
  exec 9>/run/nas-backup-restauration.lock
  flock -n 9 || die "une restauration est deja en cours."
  mkdir -p "$target" || die "impossible de creer $target"
  : > "$rlog"
  RESTAU_DATE="$D"
  printf 'ETAT=en_cours\nNOM=%q\nCIBLE=%q\nELEMENT=%q\nDEBUT=%s\nDATE=%s\n' "$J_NAME" "$target" "$REL" "$(date +%s)" "$D" > "$st"
  logl "$J_NAME : restauration de l'etat au $(date -d "@$D" '+%Y-%m-%d %H:%M') ($DI_R) vers $target"
  if ! msg=$(dest_wake "$DI_R"); then
    echo "$(date '+%Y/%m/%d %H:%M:%S') ERROR : $msg" >> "$rlog"; restore_done 1 "$target" "$REL"; return 1
  fi
  perf_load "$J_PERF"
  w=$(mktemp -d)
  if ! date_plan "$w" "$D" "$REL" > "$w/resume.json" 2>> "$rlog"; then
    rm -rf "$w"; restore_done 1 "$target" "$REL"; return 1
  fi
  tgt="$target"; [ -n "$REL" ] && tgt="$target/${REL##*/}"
  for f in "$w"/liste-*; do
    [ -s "$f" ] || continue
    if [ "${f##*/liste-}" = actuel ]; then
      src="$(dest_path "$DI_R" "$DI_E" "$J_SUB")"
    else
      src="$(trash_path "$DI_R" "$DI_E" "$J_NAME")/${f##*/liste-}"
    fi
    echo "$(date '+%Y/%m/%d %H:%M:%S') NOTICE: $(cnt "$f") fichier(s) depuis ${f##*/liste-}" >> "$rlog"
    rcl restauration copy "$src${REL:+/$REL}" "$tgt" --files-from-raw "$f" --no-traverse --stats 10s --log-file "$rlog" --log-level INFO < /dev/null || rc=1
  done
  [ -s "$w/resume.json" ] && cp -f "$w/resume.json" "$STATE_DIR/restauration.date.json"
  rm -rf "$w"
  dest_rest "$DI_R"
  restore_done "$rc" "$target" "$REL"
  return $rc
}

date_main() {
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  need_rclone
  case "${1:-}" in
    plage)     [ -n "${2:-}" ] || die "usage : date plage <NOM> [DESTINATION]"; date_plage "$2" "${3:-0}" ;;
    apercu)    [ -n "${4:-}" ] || die "usage : date apercu <NOM> <DESTINATION> <DATE> [ELEMENT]"; date_apercu "$2" "$3" "$4" "${5:-}" ;;
    restaurer) [ -n "${5:-}" ] || die "usage : date restaurer <NOM> <DESTINATION> <DATE> <DOSSIER> [ELEMENT]"; date_restore "$2" "$3" "$4" "$5" "${6:-}" ;;
    *) die "usage : nas-debian date plage | apercu | restaurer" ;;
  esac
}

# =========================== Versions (restic) =======================
# Sauvegarde versionnee chargee + destination n° <i> -> RST pret ; meurt si le depot est absent
versions_open() {  # versions_open <nom> <destination>
  job_get "$1" || die "sauvegarde '$1' introuvable."
  [ "$J_MODE" = versions ] || die "« $J_NAME » n'est pas une sauvegarde versionnee."
  job_dest_at "${2:-0}"
  need_restic >/dev/null || die "restic n'est pas installe (NAS Manager > Installation > Outils)."
  local msg; msg=$(dest_wake "$DI_R") || die "$msg"
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
  printf 'ETAT=en_cours\nNOM=%q\nCIBLE=%q\nELEMENT=%q\nDEBUT=%s\nVERSION=%s\nDATE=%s\n' "$J_NAME" "$target" "$REL" "$(date +%s)" "$snap" "${RESTAU_DATE:-}" > "$st"
  logl "$J_NAME : restauration de la version $snap ($DI_R) vers $target"
  if [ -n "$REL" ]; then
    parent="${REL%/*}"; [ "$parent" = "$REL" ] && parent=""
    name="${REL##*/}"
    gorun restauration restic "${RST[@]}" restore "$snap:$root${parent:+/$parent}" --target "$target" --include "/$name" --json >> "$rlog" 2>&1 < /dev/null; rc=$?
  else
    gorun restauration restic "${RST[@]}" restore "$snap:$root" --target "$target" --json >> "$rlog" 2>&1 < /dev/null; rc=$?
  fi
  restore_done "$rc" "$target" "$REL"
  dest_rest "$DI_R"
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
           "$RESTIC_PASS" "$CONF_DIR/canaux.conf" "$CONF_DIR/rapport.conf" /root/.config/mosquitto_pub \
           "$REVEIL_CONF" "$TEST_CONF" "$REVEIL_KEY" "$REVEIL_KEY.pub" "$MG_CONF" "$TR_CONF"; do
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

# =========================== oCIS (code commun) ======================
# Migration d'un dossier de cette machine vers oCIS et transferts oCIS -> cette machine :
# code partage avec nas-synology (commun/ocis.sh), recopie ci-dessous.
if [ "$MACHINE" = omv ]; then OC_NOM="OMV"; OC_DU="de l'OMV"; OC_LE="l'OMV"; OC_SUR="sur l'OMV"
else OC_NOM="serveur"; OC_DU="du serveur"; OC_LE="le serveur"; OC_SUR="sur le serveur"; fi
oc_notify() { local n="$1"; [ "$n" = info ] && n=succes; notify "$n" "${OC_TAG:-ocis}" "$2" "$3"; }
oc_perf() { perf_load ""; OC_MEM="$PERF_MEM"; OC_T="${PERF_FLAGS[1]}"; OC_C="${PERF_FLAGS[3]}"; }
oc_need_rclone() { command -v rclone >/dev/null || die "rclone n'est pas installe (nas-debian outils installer)."; }
oc_roots() { data_roots; }
# Fichiers recus : proprietaire et groupe du dossier de destination (groupe users plutot que
# root), dossiers 2775, fichiers 664 (comme la copie depuis le Synology)
oc_droits() {  # oc_droits <dossier> <repere : seuls les fichiers crees depuis>
  local own; own=$(stat -c %U:%G "$1" 2>/dev/null) || return 0
  [ "${own#*:}" = root ] && getent group users >/dev/null 2>&1 && own="${own%%:*}:users"
  find "$1" -mindepth 1 -cnewer "$2" -exec chown "$own" {} + 2>/dev/null
  find "$1" -mindepth 1 -cnewer "$2" -type d -exec chmod 2775 {} + 2>/dev/null
  find "$1" -mindepth 1 -cnewer "$2" -type f -exec chmod 664 {} + 2>/dev/null
  return 0
}
oc_cron_ecrire() {  # oc_cron_ecrire <lignes cron, vide = aucune>
  local f=/etc/cron.d/ocis-transferts
  if [ -z "$1" ]; then rm -f /etc/cron.d/ocis-transferts; return 0; fi
  { echo "# Genere automatiquement par nas-debian (transferts oCIS) - ne pas modifier a la main"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    printf '%s\n' "$1"; } > "$f.new"
  chmod 644 "$f.new"; mv -f "$f.new" "$f"
}
# >>> commun/ocis.sh (copie generee par maj-versions-scripts.py : modifier commun/ocis.sh)
# shellcheck shell=bash
# =====================================================================
#  commun/ocis.sh : oCIS (ownCloud Infinite Scale), partage par nas-synology et nas-debian
#    - connexion a oCIS (jeton d'application), espaces personnels et projets
#    - migration d'un dossier de la machine vers un espace oCIS : file d'attente, suivi,
#      controle dans oCIS puis suppression des originaux en option (commande « migration »)
#    - transferts oCIS -> dossier de la machine, ponctuels ou programmes (« transferts »)
#  Ce bloc est recopie tel quel dans les deux scripts par maj-versions-scripts.py :
#  le modifier dans commun/ocis.sh, puis relancer python3 maj-versions-scripts.py.
#  A fournir par le script qui l'inclut :
#    SELF (chemin du script), die, OC_NOM / OC_DU / OC_LE / OC_SUR (nom de la machine),
#    oc_notify <critique|info> <titre> <message>, oc_perf (-> OC_MEM, OC_T, OC_C),
#    oc_need_rclone, oc_roots (dossiers de depart du navigateur), oc_cron_ecrire <lignes>
# =====================================================================
MG_STATE="/root/.migre-ocis"
MG_CONF="$MG_STATE/config"
MG_QUEUE="$MG_STATE/file-attente"
MG_RUN="$MG_STATE/en-cours"
MG_LOGF="$MG_STATE/progression.log"
MG_HIST="$MG_STATE/historique.log"
MG_EXCL=(--exclude '@eaDir/**' --exclude '#recycle/**' --exclude '#snapshot/**' --exclude '#SynoRecycle/**'
      --exclude '.SynologyWorkingDirectory/**' --exclude '*@SynoEAStream' --exclude '*@SynoResource'
      --exclude '.DS_Store' --exclude 'Thumbs.db' --exclude 'desktop.ini')
: "${AUTO_REPRISE:=5}"            # relances automatiques si rclone s'arrete
: "${VERIF_RENVOIS:=3}"           # renvois forces des fichiers en defaut au controle
: "${DEFAULT_LOCAL:=https://192.168.1.53:9200}"   # oCIS en direct sur le reseau local

OC_B="\e[1m"; OC_V="\e[32m"; OC_J="\e[33m"; OC_R="\e[31m"; OC_G="\e[90m"; OC_N="\e[0m"
oc_hsize() { awk -v b="$1" 'BEGIN{split("o Ko Mo Go To",u);i=1;while(b>=1024&&i<5){b/=1024;i++};printf (i==1?"%d %s":"%.1f %s"),b,u[i]}'; }
oc_safe()  { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }
oc_cnt()   { [ -s "$1" ] && grep -c '' "$1" || echo 0; }
oc_pause() { read -r -p "Entree pour continuer..." _ || true; }
oc_need_root() { [ "$(id -u)" -eq 0 ] || die "lance le script en root (sudo)."; }
oc_mem_info() {
  awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
       END{printf "RAM disponible %d / %d Mo, swap utilise %d Mo", a/1024, t/1024, (st-sf)/1024}' /proc/meminfo
}

# =========================== Connexion oCIS ==========================
api() {  # api <GET|POST> <chemin> [json]  -> corps dans $BODY, code HTTP dans $HTTP
  local out; out=$(mktemp)
  HTTP=$(curl -s $CURL_K -o "$out" -w '%{http_code}' -m 30 -u "$OCIS_USER:$OCIS_PASS" \
    -X "$1" -H 'Content-Type: application/json' ${3:+--data-raw "$3"} "${BASE:-$OCIS_URL}$2")
  BODY=$(cat "$out"); rm -f "$out"
}

load_conf() {
  [ -f "$MG_CONF" ] || return 1
  . "$MG_CONF"
  CURL_K=""; RCLONE_K=(); BASE="$OCIS_URL"
  [ "${OCIS_INSECURE:-0}" = 1 ] && { CURL_K="-k"; RCLONE_K=(--no-check-certificate); }
  if [ -n "${LOCAL_URL:-}" ]; then   # reseau local : certificat auto-signe d'oCIS accepte
    BASE="$LOCAL_URL"; CURL_K="-k"; RCLONE_K=(--no-check-certificate)
  fi
  return 0
}

# Remplace l'adresse (https://domaine) d'une URL renvoyee par oCIS par l'adresse effective
to_base() {
  python3 -c '
import sys, urllib.parse as u
src, base = u.urlsplit(sys.argv[1]), u.urlsplit(sys.argv[2])
print(u.urlunsplit((base.scheme, base.netloc) + tuple(src[2:])))' "$1" "${BASE:-$OCIS_URL}"
}

mg_setup_conf() {
  clear
  echo -e "${OC_B}== Connexion a oCIS ==${OC_N}"
  echo "Compte a utiliser : un compte oCIS membre des espaces projets de destination,"
  echo "avec le droit « Peut modifier » ou « Gestionnaire ». Mot de passe = jeton"
  echo "d'application (recommande) ou mot de passe si l'authentification basique est activee."
  echo
  read -r -p "Adresse d'oCIS (ex : https://cloud.maison.fr) : " u; u="${u%/}"
  [[ "$u" =~ ^https?:// ]] || u="https://$u"
  read -r -p "Utilisateur oCIS : " usr
  read -r -s -p "Jeton d'application / mot de passe : " pw; echo
  local insecure=0
  if ! curl -s -o /dev/null -m 15 "$u/status.php"; then
    if curl -s -k -o /dev/null -m 15 "$u/status.php"; then
      echo -e "${OC_J}Le certificat HTTPS d'oCIS n'est pas reconnu (certificat auto-signe ?).${OC_N}"
      read -r -p "L'accepter quand meme ? [o/N] : " c; [[ "$c" =~ ^[oOyY] ]] && insecure=1 || return 1
    else
      echo -e "${OC_R}oCIS injoignable a l'adresse $u${OC_N}"; return 1
    fi
  fi
  OCIS_URL="$u"; BASE="$u"; OCIS_USER="$usr"; OCIS_PASS="$pw"; CURL_K=""; [ $insecure = 1 ] && CURL_K="-k"
  api GET /graph/v1.0/me/drives
  case "$HTTP" in
    200) ;;
    401) echo -e "${OC_R}Identifiants refuses (401).${OC_N}"
         echo "Verifie le jeton, et que l'authentification par jeton est activee sur oCIS :"
         echo "  OCIS_ADD_RUN_SERVICES=auth-app  et  PROXY_ENABLE_APP_AUTH=true"
         echo "(ou PROXY_ENABLE_BASIC_AUTH=true pour utiliser le mot de passe)."; return 1 ;;
    *)   echo -e "${OC_R}Reponse inattendue d'oCIS (HTTP $HTTP).${OC_N}"; return 1 ;;
  esac
  echo -e "${OC_V}Connexion a oCIS reussie.${OC_N}"
  RCLONE_K=(); [ $insecure = 1 ] && RCLONE_K=(--no-check-certificate)
  oc_need_rclone

  # Adresse locale : les fichiers passent directement par le reseau de la maison
  local lu=""
  echo
  echo "Adresse LOCALE d'oCIS pour les transferts (bien plus rapide que de passer par"
  echo "Internet / Cloudflare). Entree = proposition, « - » = ne pas utiliser."
  read -r -p "Adresse locale [$DEFAULT_LOCAL] : " lu; lu="${lu:-$DEFAULT_LOCAL}"
  if [ "$lu" != "-" ]; then
    lu="${lu%/}"; [[ "$lu" =~ ^https?:// ]] || lu="https://$lu"
    local sb="$BASE" sk="$CURL_K"; local -a sr=("${RCLONE_K[@]}")
    BASE="$lu"; CURL_K="-k"; RCLONE_K=(--no-check-certificate)
    api GET /graph/v1.0/me/drives
    if [ "$HTTP" = 200 ]; then
      echo -e "${OC_V}Adresse locale OK : $lu${OC_N}"
    else
      echo -e "${OC_J}L'adresse locale ne repond pas correctement (HTTP $HTTP) : les transferts passeront par $u.${OC_N}"
      lu=""; BASE="$sb"; CURL_K="$sk"; RCLONE_K=("${sr[@]}")
    fi
  else
    lu=""
  fi
  detect_vendor || return 1
  {
    printf 'OCIS_URL=%q\nLOCAL_URL=%q\nOCIS_USER=%q\nOCIS_PASS=%q\nOCIS_INSECURE=%s\nOCIS_VENDOR=%s\n' "$u" "$lu" "$usr" "$pw" "$insecure" "$OCIS_VENDOR"
  } > "$MG_CONF"; chmod 600 "$MG_CONF"
  load_conf
  sleep 1
}

# Teste un vrai envoi dans l'espace personnel du compte, en WebDAV classique.
# Le mode oCIS natif de rclone (infinitescale, envoi tus) n'est utilise qu'en
# dernier recours : il a un bug connu qui fait exploser la memoire
# (https://github.com/rclone/rclone/issues/8945), fatal sur un NAS a 2 Go.
detect_vendor() {
  local dav obs tmp v
  api GET /graph/v1.0/me/drives
  dav=$(python3 -c '
import json, sys
for d in json.load(sys.stdin).get("value", []):
    if d.get("driveType") == "personal":
        print(d["root"]["webDavUrl"]); break' <<< "$BODY" 2>/dev/null)
  [ -n "$dav" ] || { echo -e "${OC_R}Espace personnel du compte introuvable : test d'envoi impossible.${OC_N}"; return 1; }
  dav=$(to_base "$dav")
  obs=$(rclone obscure "$OCIS_PASS"); tmp=$(mktemp); echo "test migration $(date)" > "$tmp"
  echo "Test d'envoi d'un fichier..."
  for v in owncloud infinitescale; do
    if RCLONE_CONFIG_T_TYPE=webdav RCLONE_CONFIG_T_URL="$dav" RCLONE_CONFIG_T_VENDOR=$v \
       RCLONE_CONFIG_T_USER="$OCIS_USER" RCLONE_CONFIG_T_PASS="$obs" \
       rclone copyto "$tmp" t:.test-migration-synology.txt "${RCLONE_K[@]}" --retries 1 -q 2>/dev/null; then
      RCLONE_CONFIG_T_TYPE=webdav RCLONE_CONFIG_T_URL="$dav" RCLONE_CONFIG_T_VENDOR=$v \
      RCLONE_CONFIG_T_USER="$OCIS_USER" RCLONE_CONFIG_T_PASS="$obs" \
        rclone deletefile t:.test-migration-synology.txt "${RCLONE_K[@]}" -q 2>/dev/null
      OCIS_VENDOR=$v; rm -f "$tmp"
      [ $v = owncloud ] && echo -e "${OC_V}Envoi OK (WebDAV classique).${OC_N}" \
                        || echo -e "${OC_J}Envoi OK en mode oCIS natif seulement : attention, rclone y consomme beaucoup de memoire.${OC_N}"
      return 0
    fi
  done
  rm -f "$tmp"
  echo -e "${OC_R}Le test d'envoi a echoue dans les deux modes : verifie les droits du compte et l'adresse d'oCIS.${OC_N}"
  return 1
}

mg_ensure_conf() { load_conf || mg_setup_conf || die "configuration oCIS incomplete."; }

# =========================== Espaces projets =========================
# Liste "id|nom|webDavUrl" des espaces projets visibles
# list_spaces [tous] : espaces projets (et, avec « tous », l'espace personnel du compte en premier)
list_spaces() {  # remplit le tableau SPACES ("id|nom|webDavUrl|libre|quota|type") ; HTTP garde le code
  SPACES=()
  api GET /graph/v1.0/me/drives
  [ "$HTTP" = 200 ] || return 1
  mapfile -t SPACES < <(python3 -c '
import json, sys, urllib.parse as u
base, tous = u.urlsplit(sys.argv[1]), sys.argv[2] == "tous"
out = []
for d in json.load(sys.stdin).get("value", []):
    t = d.get("driveType")
    if (t == "project" or (tous and t == "personal")) and not d.get("root", {}).get("deleted"):
        w = u.urlsplit(d["root"]["webDavUrl"])
        w = u.urlunsplit((base.scheme, base.netloc) + tuple(w[2:]))
        q = d.get("quota") or {}
        tot = q.get("total") or 0
        rem = q.get("remaining") if tot else -1
        nom = d.get("name", "?") if t == "project" else "Personnel (%s)" % (((d.get("owner") or {}).get("user") or {}).get("displayName") or d.get("name") or "?")
        out.append((0 if t == "personal" else 1, nom.lower(), "%s|%s|%s|%s|%s|%s" % (d["id"], nom.replace("|", "/"), w, rem if rem is not None else -1, tot, t)))
for _, _, l in sorted(out):
    print(l)
' "$BASE" "${1:-}" <<< "$BODY")
}

# Explique un code HTTP d'oCIS
http_hint() {
  case "$1" in
    401) echo -e "${OC_R}oCIS refuse la connexion (401) : jeton d'application expire ou revoque.${OC_N}"
         echo "Un jeton cree par « ocis auth-app create » dure 72 h par defaut. Recrees-en un, par exemple :"
         echo "  docker exec <conteneur-ocis> ocis auth-app create --user-name=$OCIS_USER --expiration=2160h"
         echo "puis mets-le a jour dans le menu « 7) Modifier la connexion oCIS »." ;;
    000) echo -e "${OC_R}oCIS injoignable a l'adresse $OCIS_URL (serveur arrete, reseau ou certificat).${OC_N}" ;;
    *)   echo -e "${OC_R}Reponse inattendue d'oCIS (HTTP $1).${OC_N}" ;;
  esac
}

# =========================== Choix ===================================
# Navigateur de dossiers du NAS  -> CHOIX
mg_browse_local() {
  local cur="/" c i d
  local -a dirs=()
  while true; do
    if [ "$cur" = "/" ]; then
      mapfile -t dirs < <(oc_roots)
    else
      mapfile -t dirs < <(find "$cur" -mindepth 1 -maxdepth 1 -type d ! -name '@*' ! -name '#*' ! -name '.*' ! -name 'lost+found' 2>/dev/null | sort)
    fi
    clear
    echo -e "${OC_B}== Dossier a migrer ==${OC_N}"
    echo -e "Dossier actuel : ${OC_B}$( [ "$cur" = / ] && echo "(dossiers partages)" || echo "$cur" )${OC_N}"
    echo
    i=1
    for d in "${dirs[@]}"; do printf "  %3d) %s\n" "$i" "$( [ "$cur" = / ] && echo "$d" || echo "${d##*/}" )"; i=$((i+1)); done
    [ ${#dirs[@]} -eq 0 ] && echo -e "  ${OC_G}(aucun sous-dossier)${OC_N}"
    echo
    echo "  numero = entrer dans le dossier"
    [ "$cur" != "/" ] && echo "  v = VALIDER « ${cur##*/} »"
    echo "  r = remonter      q = annuler"
    read -r -p "Choix : " c
    case "$c" in
      v|V) [ "$cur" != "/" ] && { CHOIX="$cur"; return 0; } ;;
      r|R) if oc_roots | grep -qxF "$cur"; then cur="/"; elif [ "$cur" != "/" ]; then cur="${cur%/*}"; [ -n "$cur" ] || cur="/"; fi ;;
      q|Q) return 1 ;;
      *) if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#dirs[@]} ]; then cur="${dirs[$((c-1))]}"; fi ;;
    esac
  done
}

mg_pick_source() {  # -> SRC_DIR, SRC_LABEL
  local -a dirs=() labels=(); local d u i c
  for d in /volume[0-9]*/homes/*/Drive; do
    [ -d "$d" ] || continue
    u="${d%/Drive}"; u="${u##*/}"
    dirs+=("$d"); labels+=("Mon Drive de $u")
  done
  clear
  echo -e "${OC_B}== Dossier a migrer ==${OC_N}"
  if [ ${#dirs[@]} -gt 0 ]; then
    echo "Mon Drive des utilisateurs (calcul des tailles...) :"
    i=1
    for d in "${dirs[@]}"; do
      printf "  %2d) %-28s %10s\n" "$i" "${labels[$((i-1))]}" "$(oc_hsize "$(du -sb --exclude='@eaDir' --exclude='#SynoRecycle' "$d" 2>/dev/null | cut -f1)")"
      i=$((i+1))
    done
  else
    [ "$OC_NOM" = Synology ] && echo -e "${OC_G}(aucun Mon Drive trouve dans /volume*/homes/*/Drive)${OC_N}"
  fi
  echo
  echo "   p) Parcourir les dossiers $OC_DU"
  echo "   c) Taper un chemin complet"
  read -r -p "Choix (Entree = annuler) : " c
  if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#dirs[@]} ]; then
    SRC_DIR="${dirs[$((c-1))]}"; SRC_LABEL="${labels[$((c-1))]#Mon Drive de }"; return 0
  elif [[ "$c" =~ ^[pP]$ ]]; then
    mg_browse_local || return 1
    SRC_DIR="$CHOIX"; SRC_LABEL="${CHOIX##*/}"; return 0
  elif [[ "$c" =~ ^[cC]$ ]]; then
    read -r -p "Chemin : " SRC_DIR; SRC_DIR="${SRC_DIR%/}"
    [ -d "$SRC_DIR" ] || { echo "Dossier introuvable."; sleep 2; return 1; }
    SRC_LABEL="${SRC_DIR##*/}"; return 0
  fi
  return 1
}

mg_pick_space() {  # -> SP_ID, SP_NAME, SP_DAV  (espaces existants uniquement)
  local -a sp=(); local i c line
  clear
  echo -e "${OC_B}== Espace projet oCIS de destination ==${OC_N}"
  if ! list_spaces; then http_hint "$HTTP"; oc_pause; return 1; fi
  sp=("${SPACES[@]}")
  if [ ${#sp[@]} -eq 0 ]; then
    echo -e "${OC_J}Aucun espace projet visible pour le compte « $OCIS_USER ».${OC_N}"
    echo "Cree les espaces dans oCIS, puis ajoute ce compte comme membre de chaque"
    echo "espace avec le droit « Peut modifier » ou « Gestionnaire »."
    oc_pause; return 1
  fi
  i=1
  local nm rem tot q
  for line in "${sp[@]}"; do
    IFS="|" read -r _ nm _ rem tot _ <<< "$line"
    if [ "${tot:-0}" -gt 0 ] 2>/dev/null; then q="libre $(oc_hsize "$rem") / quota $(oc_hsize "$tot")"; else q="sans limite"; fi
    printf "  %2d) %-30s %s\n" "$i" "$nm" "$q"; i=$((i+1))
  done
  echo -e "${OC_G}(seuls les espaces dont « $OCIS_USER » est membre apparaissent)${OC_N}"
  read -r -p "Choix (Entree = annuler) : " c
  [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#sp[@]} ] || return 1
  IFS="|" read -r SP_ID SP_NAME SP_DAV SP_FREE SP_QUOTA _ <<< "${sp[$((c-1))]}"
}

# =========================== File d'attente ==========================
# processus vivant (un processus termine mais pas encore « reaped » ne compte pas)
oc_alive() { kill -0 "$1" 2>/dev/null && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }
mg_running() { [ -f "$MG_RUN" ] && . "$MG_RUN" && oc_alive "$PID"; }

mg_add_task() {
  mg_pick_source || return
  mg_pick_space || return
  clear
  echo -e "${OC_B}== Nouvelle migration ==${OC_N}"
  echo "Calcul..."
  local total nbf sub
  total=$(du -sb --exclude='@eaDir' --exclude='#SynoRecycle' --exclude='.SynologyWorkingDirectory' "$SRC_DIR" 2>/dev/null | cut -f1)
  nbf=$(find "$SRC_DIR" -type f ! -path '*/@eaDir/*' ! -path '*/#SynoRecycle/*' ! -path '*/.SynologyWorkingDirectory/*' 2>/dev/null | wc -l)
  echo
  echo -e "  Source  : ${OC_B}$SRC_DIR${OC_N}  ($(oc_hsize "${total:-0}"), $nbf fichiers)"
  echo -e "  Espace  : ${OC_B}$SP_NAME${OC_N}"
  if [ "${SP_QUOTA:-0}" -gt 0 ] 2>/dev/null && [ "${total:-0}" -gt "${SP_FREE:-0}" ]; then
    echo
    echo -e "  ${OC_R}Attention : l'espace n'a que $(oc_hsize "$SP_FREE") de libre (quota $(oc_hsize "$SP_QUOTA")),${OC_N}"
    echo -e "  ${OC_R}la migration s'arretera quand il sera plein.${OC_N}"
    echo "  Dans oCIS : espace « $SP_NAME » > ⋯ > Modifier le quota > « Pas de restriction »."
    echo "  (Les nouveaux espaces ont 1 Go par defaut, reglable avec GRAPH_SPACES_DEFAULT_QUOTA=0.)"
    read -r -p "  Ajouter quand meme a la file ? [o/N] : " c; [[ "$c" =~ ^[oOyY] ]] || return
  fi
  echo
  echo "Dans l'espace, mettre les fichiers :"
  echo "  (Entree) directement a la racine de l'espace"
  echo "  ou tape le nom d'un sous-dossier (ex : $SRC_LABEL)"
  read -r -p "Sous-dossier : " sub; sub="${sub#/}"; sub="${sub%/}"
  echo
  echo "Apres le transfert :"
  echo "  1) Garder les originaux $OC_SUR (copie)"
  echo "  2) Controler chaque fichier dans oCIS, puis SUPPRIMER l'original $OC_DU"
  local m del=non
  read -r -p "Choix [1] : " m
  if [ "${m:-1}" = 2 ]; then
    echo
    echo -e "${OC_J}Seuls les fichiers dont la copie dans oCIS est controlee identique (empreinte)"
    echo -e "sont supprimes. Un fichier absent, different ou modifie entre-temps est renvoye"
    echo -e "puis recontrole (3 fois au plus) ; s'il reste en defaut, il est garde.${OC_N}"
    if [[ "$SRC_DIR" == */homes/*/Drive* ]]; then
      echo -e "${OC_R}C'est un « Mon Drive » : les ordinateurs synchronises avec Synology Drive"
      echo -e "supprimeront aussi ces fichiers chez eux. Installe d'abord le client oCIS.${OC_N}"
    fi
    read -r -p "Tape SUPPRIMER pour confirmer : " c
    if [ "$c" = SUPPRIMER ]; then del=oui; else echo "Annule : les originaux seront gardes."; fi
  fi
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$SRC_DIR" "$SRC_LABEL" "$SP_ID" "$SP_NAME" "$SP_DAV" "$sub" "${total:-0}" "$del" >> "$MG_QUEUE"
  echo -e "${OC_V}Ajoute a la file d'attente : $SRC_LABEL -> $SP_NAME${sub:+/$sub}$( [ $del = oui ] && echo " (+ suppression des originaux)")${OC_N}"
}

mg_show_queue() {
  [ -s "$MG_QUEUE" ] || { echo -e "  ${OC_G}(file d'attente vide)${OC_N}"; return; }
  local i=1 s l id n dav sub t del
  while IFS='|' read -r s l id n dav sub t del; do
    printf "  %2d) %-18s -> %-25s %10s%s\n" "$i" "$l" "$n${sub:+/$sub}" "$(oc_hsize "$t")" \
      "$(case "$del" in oui) echo -e "  ${OC_R}+ suppression des originaux${OC_N}";; verif) echo -e "  ${OC_R}controle + suppression (sans transfert)${OC_N}";; esac)"; i=$((i+1))
  done < "$MG_QUEUE"
}

# Migration deja faite : controle dans oCIS puis suppression des originaux, sans transfert
mg_add_verif() {
  local -a past=(); local line c s dst best="" bl=0 nm sub total nbf
  clear
  echo -e "${OC_B}== Controler et supprimer les originaux d'une migration deja faite ==${OC_N}"
  # migrations reussies de l'historique (« source -> espace[/sous-dossier] »), dont la source existe encore
  mapfile -t past < <(awk -F' [|] ' '$2 ~ /^OK/ {print $3}' "$MG_HIST" 2>/dev/null | awk '!vu[$0]++' |
                      while IFS= read -r line; do [ -d "${line%% -> *}" ] && echo "$line"; done)
  if [ ${#past[@]} -gt 0 ]; then
    echo "Migrations reussies (historique) :"
    local i=1
    for line in "${past[@]}"; do printf "  %2d) %s\n" "$i" "$line"; i=$((i+1)); done
  else
    echo -e "${OC_G}(aucune migration reussie dans l'historique)${OC_N}"
  fi
  echo "   m) Choisir a la main la source et l'espace"
  read -r -p "Choix (Entree = annuler) : " c
  if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#past[@]} ]; then
    line="${past[$((c-1))]}"; s="${line%% -> *}"; dst="${line#* -> }"
    if ! list_spaces; then http_hint "$HTTP"; oc_pause; return; fi
    # espace dont le nom correspond au debut de la destination (le plus long gagne)
    for line in "${SPACES[@]}"; do
      IFS="|" read -r _ nm _ _ _ <<< "$line"
      if { [ "$dst" = "$nm" ] || [[ "$dst" == "$nm/"* ]]; } && [ ${#nm} -gt $bl ]; then best="$line"; bl=${#nm}; fi
    done
    [ -n "$best" ] || { echo -e "${OC_R}Espace « ${dst%%/*} » introuvable dans oCIS (renomme, ou compte non membre ?).${OC_N}"; oc_pause; return; }
    IFS="|" read -r SP_ID SP_NAME SP_DAV _ _ <<< "$best"
    SRC_DIR="$s"; sub="${dst#"$SP_NAME"}"; sub="${sub#/}"
    SRC_LABEL="${s##*/}"; [[ "$s" =~ /homes/([^/]+)/Drive$ ]] && SRC_LABEL="${BASH_REMATCH[1]}"
  elif [[ "$c" =~ ^[mM]$ ]]; then
    mg_pick_source || return
    mg_pick_space || return
    read -r -p "Sous-dossier dans l'espace (Entree = racine) : " sub; sub="${sub#/}"; sub="${sub%/}"
  else
    return
  fi
  clear
  echo -e "${OC_B}== Controle et suppression ==${OC_N}"
  echo "Calcul..."
  total=$(du -sb --exclude='@eaDir' --exclude='#SynoRecycle' --exclude='.SynologyWorkingDirectory' "$SRC_DIR" 2>/dev/null | cut -f1)
  nbf=$(find "$SRC_DIR" -type f ! -path '*/@eaDir/*' ! -path '*/#SynoRecycle/*' ! -path '*/.SynologyWorkingDirectory/*' 2>/dev/null | wc -l)
  echo
  echo -e "  $OC_NOM : ${OC_B}$SRC_DIR${OC_N}  ($(oc_hsize "${total:-0}"), $nbf fichiers)"
  echo -e "  oCIS     : ${OC_B}$SP_NAME${sub:+/$sub}${OC_N}"
  echo
  echo -e "${OC_J}Aucun transfert : chaque fichier $OC_DU est compare a sa copie dans oCIS"
  echo -e "(empreinte), et seuls ceux qui sont identiques sont supprimes $OC_DU."
  echo -e "Ceux qui sont absents ou differents sont gardes, puis transferes et controles"
  echo -e "au passage suivant (remis en file d'attente).${OC_N}"
  if [[ "$SRC_DIR" == */homes/*/Drive* ]]; then
    echo -e "${OC_R}C'est un « Mon Drive » : les ordinateurs synchronises avec Synology Drive"
    echo -e "supprimeront aussi ces fichiers chez eux. Installe d'abord le client oCIS.${OC_N}"
  fi
  read -r -p "Tape SUPPRIMER pour confirmer : " c
  [ "$c" = SUPPRIMER ] || { echo "Annule."; sleep 1; return; }
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$SRC_DIR" "$SRC_LABEL" "$SP_ID" "$SP_NAME" "$SP_DAV" "$sub" "${total:-0}" verif >> "$MG_QUEUE"
  echo -e "${OC_V}Ajoute a la file d'attente : controle et suppression de $SRC_LABEL (lance-la avec le menu 3)${OC_N}"
}

mg_remove_task() {
  mg_show_queue; [ -s "$MG_QUEUE" ] || return
  read -r -p "Numero a retirer : " c
  [[ "$c" =~ ^[0-9]+$ ]] && sed -i "${c}d" "$MG_QUEUE"
}

# =========================== Lancement ===============================
mg_start() {
  if mg_running; then echo -e "${OC_J}Une migration est deja en cours.${OC_N}"; mg_follow; return; fi
  [ -s "$MG_QUEUE" ] || { echo "La file d'attente est vide : ajoute d'abord une migration."; oc_pause; return; }
  oc_need_rclone
  echo; echo -e "${OC_B}Migrations a lancer :${OC_N}"; mg_show_queue; echo
  read -r -p "Lancer ? [O/n] : " go
  [[ "${go:-o}" =~ ^[oOyY] ]] || return
  cp "$MG_QUEUE" "$MG_STATE/lot"; : > "$MG_QUEUE"
  [ -s "$MG_LOGF" ] && mv -f "$MG_LOGF" "$MG_LOGF.precedent"; : > "$MG_LOGF"
  rm -f "$MG_STATE/code" "$MG_STATE/etape" "$MG_STATE/resultats" "$MG_STATE/rss"   # resultats d'un suivi precedent interrompu
  printf 'NB=%s\nDEBUT=%s\n' "$(wc -l < "$MG_STATE/lot")" "$(date +%s)" > "$MG_RUN"
  nohup setsid bash "$SELF" migration _worker >/dev/null 2>&1 &
  echo "PID=$!" >> "$MG_RUN"
  echo -e "${OC_V}Migration lancee.${OC_N}"; sleep 1
  mg_follow
}

# Lance rclone en arriere-plan, releve sa memoire (Mo) toutes les 3 s, renvoie son code.
# La sortie d'erreur (traces de plantage, parfois enormes) va dans un fichier a part ;
# seules les premieres lignes sont recopiees dans le journal.
# Avec MG_SUIVI="<etape> <position du journal au debut de l'etape> <libelle>", rclone ouvre
# en plus son controle a distance (127.0.0.1, port libre, mot de passe aleatoire) et
# mg_monitor en tire l'avancement detaille (fichier avancement).
run_rclone() {
  local pid rss max=0 rc mon="" port="" pw=""
  local -a rcopt=()
  if [ -n "${MG_SUIVI:-}" ] && command -v python3 >/dev/null 2>&1; then
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])' 2>/dev/null)
    pw=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
    [ -n "$port" ] && [ -n "$pw" ] && rcopt=(--rc --rc-addr "127.0.0.1:$port")
  fi
  # identifiants du controle a distance par l'environnement (invisibles dans « ps »)
  RCLONE_RC_USER=rc RCLONE_RC_PASS="$pw" GOGC=50 GOMEMLIMIT="$MEMLIM" \
    rclone "$@" "${rcopt[@]}" < /dev/null 2>"$MG_STATE/rclone-err.log" &
  pid=$!
  if [ ${#rcopt[@]} -gt 0 ]; then
    # shellcheck disable=SC2086
    MG_RC_PASS="$pw" mg_monitor "$pid" "$port" $MG_SUIVI &
    mon=$!
  fi
  while kill -0 "$pid" 2>/dev/null && ! grep -q '^State:.*Z' "/proc/$pid/status" 2>/dev/null; do
    rss=$(awk '/^VmRSS:/{print int($2/1024)}' "/proc/$pid/status" 2>/dev/null)
    if [ -n "$rss" ]; then [ "$rss" -gt "$max" ] && max=$rss; echo "$rss $max" > "$MG_STATE/rss"; fi
    sleep 3
  done
  wait "$pid"; rc=$?
  [ -n "$mon" ] && wait "$mon" 2>/dev/null   # derniere mise a jour de l'avancement
  RSS_MAX=$max; rm -f "$MG_STATE/rss"
  [ -s "$MG_STATE/rclone-err.log" ] && head -n 15 "$MG_STATE/rclone-err.log" | sed 's/^/    stderr: /' >> "$MG_LOGF"
  return $rc
}

oc_hdur() {  # duree lisible : oc_hdur <secondes>
  local s=${1:-0}
  if [ "$s" -ge 86400 ]; then printf '%d j %d h' $((s/86400)) $((s%86400/3600))
  elif [ "$s" -ge 3600 ]; then printf '%d h %02d min' $((s/3600)) $((s%3600/60))
  elif [ "$s" -ge 60 ]; then printf '%d min' $((s/60))
  else printf '%d s' "$s"; fi
}

# Taille de reference de la source, mesuree comme rclone la voit (memes exclusions) :
# mg_reference <source> <etape>  -> fichier reference (REF_ETAPE, REF_FICHIERS, REF_OCTETS)
mg_reference() {
  local j f o
  j=$(GOGC=50 GOMEMLIMIT="$MEMLIM" rclone size --json "$1" "${MG_EXCL[@]}" < /dev/null 2>/dev/null) || return 0
  f=$(sed -n 's/.*"count":\([0-9]*\).*/\1/p' <<< "$j"); o=$(sed -n 's/.*"bytes":\([0-9]*\).*/\1/p' <<< "$j")
  [ -n "$f" ] && [ -n "$o" ] || return 0
  printf 'REF_ETAPE=%s\nREF_FICHIERS=%s\nREF_OCTETS=%s\nREF_MAJ=%s\n' "$2" "$f" "$o" "$(date +%s)" > "$MG_STATE/reference.tmp" \
    && mv -f "$MG_STATE/reference.tmp" "$MG_STATE/reference"
}

# Suivi detaille d'un transfert : interroge rclone (core/stats) toutes les 3 s et ecrit
# le fichier avancement (variables PG_*), lu par le suivi et par l'application :
#   PG_PCT        avancement en fichiers par rapport a la reference (vide tant qu'elle manque)
#   PG_FICHIERS   fichiers traites (envoyes + deja presents) / PG_REF_FICHIERS
#   PG_ENVOYE     octets envoyes par rclone (nouveaux essais compris) / PG_REF_OCTETS
#   PG_TOTAL_RCLONE  total annonce par rclone (grossit tant qu'il parcourt la source)
#   PG_PROVISOIRE 1 si ce total a grossi dans les 30 dernieres secondes
#   PG_SURPLUS    octets envoyes au-dela de la taille de la source (renvois), au moins
#   PG_VITESSE, PG_FICH_MIN, PG_ETA   moyennes sur 5 min, reste estime (s)
#   PG_ESSAIS     nouveaux essais complets de rclone (« Attempt N/M failed »)
#   PG_ERREURS    fichiers ayant eu une erreur (liste : erreurs-<libelle>.txt)
# mg_monitor <pid rclone> <port> <etape> <position du journal> <libelle>
mg_monitor() {
  python3 - "$MG_STATE" "$@" <<'PYEOF'
import base64, json, os, re, sys, time, urllib.request
M, pid, port, etape, off, lab = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5]), sys.argv[6]
auth = "Basic " + base64.b64encode(("rc:" + os.environ.get("MG_RC_PASS", "")).encode()).decode()
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
logf, out, errf = M + "/progression.log", M + "/avancement", M + "/erreurs-" + lab + ".txt"
pos, essais, erreurs, nerr_ecrit = off, 0, set(), -1
samples, tb_last, tb_change, last = [], None, time.time(), None

def alive():
    try:
        with open("/proc/%d/status" % pid) as f:
            return not re.search(r"^State:\s+Z", f.read(), re.M)
    except OSError:
        return False

def stats():
    r = urllib.request.Request("http://127.0.0.1:%s/core/stats" % port, data=b"{}",
                               headers={"Content-Type": "application/json", "Authorization": auth})
    with opener.open(r, timeout=5) as h:
        return json.load(h)

def scan():  # nouvelles lignes du journal depuis le debut de l'etape
    global pos, essais
    try:
        with open(logf, "rb") as f:
            f.seek(pos)
            data = f.read()
    except OSError:
        return
    k = data.rfind(b"\n")
    if k < 0:
        return
    pos += k + 1
    for l in data[:k].decode(errors="ignore").splitlines():
        if "ERROR : " not in l:
            continue
        if re.search(r"Attempt \d+/\d+ failed", l):
            essais += 1
            continue
        m = re.search(r"ERROR : (.+?): (?:Failed to |failed to |[Cc]ouldn't |corrupted |[Ee]rror |Src file |Not )", l) \
            or re.search(r"ERROR : (.+?): ", l)
        if m and " root '" not in m.group(1) and not m.group(1).startswith(("Local file system", "webdav")):
            erreurs.add(m.group(1))

def ref():
    v = {}
    try:
        with open(M + "/reference") as f:
            for l in f:
                k, _, x = l.strip().partition("=")
                v[k] = x
    except OSError:
        return 0, 0
    if v.get("REF_ETAPE") != etape:
        return 0, 0
    try:
        return int(v.get("REF_FICHIERS", 0)), int(v.get("REF_OCTETS", 0))
    except ValueError:
        return 0, 0

def write(s):
    global nerr_ecrit
    now = time.time()
    b, tb = int(s.get("bytes", 0)), int(s.get("totalBytes", 0))
    fichiers = int(s.get("checks", 0)) + int(s.get("transfers", 0))
    rf, rb = ref()
    pct = eta = vit = fmin = ""
    if rf > 0:
        pct = min(99, fichiers * 100 // rf)
    samples.append((now, b, fichiers))
    while len(samples) > 2 and now - samples[1][0] >= 300:
        samples.pop(0)
    t0, b0, f0 = samples[0]
    if now - t0 >= 60:
        vb, vf = (b - b0) / (now - t0), (fichiers - f0) / (now - t0)
        vit, fmin = int(vb), int(vf * 60)
        cands = []
        if rf > 0 and vf > 0:
            cands.append(max(0, rf - fichiers) / vf)
        if rb > 0 and vb > 0:
            avg = rb / rf if rf else 0
            cands.append(max(0, rb - b - int(s.get("checks", 0)) * avg) / vb)
        if cands:
            eta = int(max(cands))
    surplus = max(0, b - rb) if rb > 0 else 0
    v = dict(PG_ETAPE=etape, PG_MAJ=int(now), PG_PCT=pct, PG_FICHIERS=fichiers, PG_REF_FICHIERS=rf or "",
             PG_REF_OCTETS=rb or "", PG_ENVOYE=b, PG_TOTAL_RCLONE=tb,
             PG_PROVISOIRE=1 if now - tb_change < 30 else 0, PG_SURPLUS=surplus, PG_VITESSE=vit,
             PG_FICH_MIN=fmin, PG_ETA=eta, PG_ESSAIS=essais, PG_ERREURS=len(erreurs),
             PG_EN_COURS=len(s.get("transferring") or []), PG_TRANSFERTS=int(s.get("transfers", 0)),
             PG_SUPPR=int(s.get("deletes", 0)))
    with open(out + ".tmp", "w") as f:
        f.write("".join("%s=%s\n" % kv for kv in v.items()))
    os.replace(out + ".tmp", out)
    if len(erreurs) != nerr_ecrit:
        with open(errf + ".tmp", "w") as f:
            f.write("".join(e + "\n" for e in sorted(erreurs)))
        os.replace(errf + ".tmp", errf)
        nerr_ecrit = len(erreurs)

while True:
    vivant = alive()
    try:
        s = stats()
        tb = int(s.get("totalBytes", 0))
        if tb_last is None or tb > tb_last:
            if tb_last is not None:
                tb_change = time.time()
            tb_last = tb
        last = s
    except Exception:
        pass
    scan()
    if last is not None:
        try:
            write(last)
        except OSError:
            pass
    if not vivant:
        break
    time.sleep(3)
PYEOF
}

# Bilan d'une etape : compte les fichiers de la machine et dans oCIS (memes exclusions),
# et resume nouveaux essais, erreurs, reprises et duree dans le journal.
# mg_bilan <source> <sous-dossier> <etape> <debut (epoch)> <reprises> <libelle>  -> BILAN_MSG
mg_bilan() {
  local s="$1" sub="$2" n="$3" t0="$4" rep="${5:-0}" lab="$6" js jd sf so df dob v l
  local PG_ETAPE="" PG_ESSAIS=0 PG_ERREURS=0 PG_SURPLUS=0
  BILAN_MSG=""
  echo "PHASE=bilan" >> "$MG_STATE/etape"
  echo "=== [$n] bilan : comptage des fichiers $OC_SUR et dans oCIS" >> "$MG_LOGF"
  js=$(GOGC=50 GOMEMLIMIT="$MEMLIM" rclone size --json "$s" "${MG_EXCL[@]}" < /dev/null 2>/dev/null)
  jd=$(GOGC=50 GOMEMLIMIT="$MEMLIM" rclone size --json "ocis:$sub" "${MG_EXCL[@]}" "${RCLONE_K[@]}" \
        --disable-http2 --checkers 4 < /dev/null 2>/dev/null)
  sf=$(sed -n 's/.*"count":\([0-9]*\).*/\1/p' <<< "$js"); so=$(sed -n 's/.*"bytes":\([0-9]*\).*/\1/p' <<< "$js")
  df=$(sed -n 's/.*"count":\([0-9]*\).*/\1/p' <<< "$jd"); dob=$(sed -n 's/.*"bytes":\([0-9]*\).*/\1/p' <<< "$jd")
  if [ -z "$sf" ] || [ -z "$so" ] || [ -z "$df" ] || [ -z "$dob" ]; then
    v="comptage impossible ($( [ -z "$sf" ] && echo "$OC_NOM" || echo oCIS))"
    BILAN_MSG="bilan : $v"
  else
    l="$OC_NOM $sf fichier(s) / $(oc_hsize "$so") · oCIS $df fichier(s) / $(oc_hsize "$dob")"
    if [ "$df" -eq "$sf" ] && [ "$dob" -eq "$so" ]; then
      v="$l · identique"; BILAN_MSG="bilan : oCIS = $OC_NOM ($sf fichiers, $(oc_hsize "$so"))"
    elif [ "$df" -lt "$sf" ]; then
      v="$l · il MANQUE $((sf - df)) fichier(s) dans oCIS"; BILAN_MSG="bilan : il manque $((sf - df)) fichier(s) dans oCIS"
      oc_notify critique "Migration oCIS : fichiers manquants" "$lab : $((sf - df)) fichier(s) $OC_DU absent(s) d'oCIS à la fin du transfert (détail dans le journal de la migration)."
    elif [ "$df" -gt "$sf" ]; then
      v="$l · oCIS contient $((df - sf)) fichier(s) de plus (deja presents dans la destination)"
      BILAN_MSG="bilan : tout est dans oCIS (+$((df - sf)) fichier(s) deja presents)"
    else
      v="$l · meme nombre de fichiers, $(oc_hsize $(( so > dob ? so - dob : dob - so ))) d'ecart (fichiers modifies pendant la migration ?)"
      BILAN_MSG="bilan : meme nombre de fichiers, tailles differentes"
    fi
  fi
  echo "=== [$n] bilan : $v" >> "$MG_LOGF"
  # shellcheck disable=SC1090
  [ -f "$MG_STATE/avancement" ] && . "$MG_STATE/avancement"
  [ "$PG_ETAPE" = "$n" ] || { PG_ESSAIS=0; PG_ERREURS=0; PG_SURPLUS=0; }
  l="${PG_ESSAIS:-0} nouvel(s) essai(s) rclone · ${PG_ERREURS:-0} fichier(s) en erreur pendant le transfert"
  [ "${PG_ERREURS:-0}" -gt 0 ] && l="$l (liste : $MG_STATE/erreurs-$(oc_safe "$lab").txt)"
  [ "${PG_SURPLUS:-0}" -gt 0 ] && l="$l · au moins $(oc_hsize "$PG_SURPLUS") renvoyes"
  l="$l · $rep reprise(s) automatique(s) · duree $(oc_hdur $(( $(date +%s) - t0 )))"
  echo "=== [$n] bilan : $l" >> "$MG_LOGF"
  if [ "${PG_ESSAIS:-0}" -gt 0 ] || [ "${PG_ERREURS:-0}" -gt 0 ]; then
    BILAN_MSG="$BILAN_MSG ; ${PG_ESSAIS:-0} nouvel(s) essai(s), ${PG_ERREURS:-0} fichier(s) en erreur"
  fi
}

# Ligne d'avancement detaille pour le suivi en terminal -> PG_LINE, PG_P (echec si indisponible)
mg_pg_line() {
  local PG_ETAPE="" PG_MAJ=0 l
  PG_LINE=""; PG_P=""
  # shellcheck disable=SC1090
  [ -f "$MG_STATE/avancement" ] && . "$MG_STATE/avancement" || return 1
  [ "$PG_ETAPE" = "$ETAPE" ] && [ $(( $(date +%s) - ${PG_MAJ:-0} )) -lt 30 ] || return 1
  if [ -n "$PG_REF_FICHIERS" ]; then
    l="$PG_FICHIERS/$PG_REF_FICHIERS fichiers"; PG_P="$PG_PCT"
  else
    l="$PG_FICHIERS fichiers (mesure de la source...)"
  fi
  [ -n "$PG_ETA" ] && l="$l · reste ~$(oc_hdur "$PG_ETA")"
  l="$l · $(oc_hsize "$PG_ENVOYE") envoyes${PG_REF_OCTETS:+ / source $(oc_hsize "$PG_REF_OCTETS")}"
  [ -n "$PG_FICH_MIN" ] && l="$l · $PG_FICH_MIN fich/min, $(oc_hsize "${PG_VITESSE:-0}")/s"
  [ "${PG_PROVISOIRE:-0}" = 1 ] && l="$l · parcours en cours"
  [ "${PG_SURPLUS:-0}" -gt 0 ] && l="$l · +$(oc_hsize "$PG_SURPLUS") renvoyes"
  if [ "${PG_ESSAIS:-0}" -gt 0 ] || [ "${PG_ERREURS:-0}" -gt 0 ]; then l="$l · $PG_ESSAIS essai(s), $PG_ERREURS erreur(s)"; fi
  PG_LINE="$l"
}


# Controle dans oCIS les fichiers de <source> puis supprime de la machine ceux dont la
# copie est identique. Les fichiers en defaut (differents, absents d'oCIS, en erreur)
# sont renvoyes de force puis recontroles, jusqu'a VERIF_RENVOIS fois ; ceux qui restent
# en defaut sont gardes sur la machine. Rien n'est supprime sans controle reussi.
# Renvoie 0 si tout est controle et supprime, 1 sinon. -> VERIF_MSG
verify_and_delete() {
  local s="$1" sub="$2" lab="$3" d crc nok=0 ndiff nmiss nerr dl="" k=0 hist
  d="$MG_STATE/verif-$(oc_safe "$lab")"; rm -rf "$d"; mkdir -p "$d"
  hist="$MG_STATE/supprimes-$(date +%Y%m%d-%H%M%S)-$(oc_safe "$lab").txt"
  check_run() {
    rm -f "$d/ok" "$d/diff" "$d/absent" "$d/err"; : > "$d/check.log"
    run_rclone check "$s" "ocis:$sub" --one-way "${MG_EXCL[@]}" "${RCLONE_K[@]}" \
      --checkers 2 --buffer-size 0 --disable-http2 \
      --match "$d/ok" --differ "$d/diff" --missing-on-dst "$d/absent" --error "$d/err" \
      --stats 5s --stats-log-level NOTICE --log-level NOTICE --log-file "$d/check.log" $dl "$@"
    crc=$?
    if [ -z "$dl" ] && grep -qiE 'no common hash|could not be checked' "$d/check.log"; then
      # oCIS n'a pas fourni d'empreinte pour tout : comparaison octet par octet
      echo "=== [$i] empreintes incompletes cote oCIS : controle par relecture complete depuis oCIS" >> "$MG_LOGF"
      echo "PHASE=relecture" >> "$MG_STATE/etape"
      dl=--download; check_run "$@"; return
    fi
    grep -E 'ERROR|NOTICE: .*(differ|not found|match)' "$d/check.log" | tail -n 20 >> "$MG_LOGF"
    ndiff=$(oc_cnt "$d/diff"); nmiss=$(oc_cnt "$d/absent"); nerr=$(oc_cnt "$d/err")
    echo "=== [$i] controle${k:+ apres renvoi $k} : $(oc_cnt "$d/ok") identique(s), $ndiff different(s), $nmiss absent(s) d'oCIS, $nerr erreur(s) (code $crc)" >> "$MG_LOGF"
  }
  delete_ok() {  # supprime de la machine les fichiers controles identiques a cette passe
    local n; n=$(oc_cnt "$d/ok"); [ "$n" -gt 0 ] || return 0
    echo "PHASE=suppression" >> "$MG_STATE/etape"
    cat "$d/ok" >> "$hist"
    echo "=== [$i] suppression de $n original(aux) controle(s) dans $s" >> "$MG_LOGF"
    rclone delete "$s" --files-from-raw "$d/ok" --log-file "$MG_LOGF" --log-level NOTICE < /dev/null
    nok=$((nok + n))
  }

  echo "PHASE=verification" >> "$MG_STATE/etape"
  echo "=== [$i] controle des fichiers dans oCIS (empreintes)" >> "$MG_LOGF"
  k=""; check_run
  delete_ok
  k=0
  # --- renvoi force des fichiers en defaut, puis nouveau controle
  while [ $((ndiff + nmiss + nerr)) -gt 0 ] && [ "$k" -lt "$VERIF_RENVOIS" ]; do
    k=$((k+1))
    cat "$d/diff" "$d/absent" "$d/err" 2>/dev/null | sort -u > "$d/renvoi"
    echo "PHASE=renvoi" >> "$MG_STATE/etape"
    echo "=== [$i] renvoi $k/$VERIF_RENVOIS de $(oc_cnt "$d/renvoi") fichier(s) en defaut (differents, absents ou en erreur)" >> "$MG_LOGF"
    # --ignore-times : renvoie meme si taille et date sont identiques (copie abimee)
    run_rclone copy "$s" "ocis:$sub" --files-from-raw "$d/renvoi" --ignore-times "${RCLONE_K[@]}" \
      --transfers 1 --checkers 2 --buffer-size 0 --disable-http2 --retries 3 --low-level-retries 20 \
      --stats 10s --stats-one-line --stats-log-level NOTICE --log-level NOTICE --log-file "$MG_LOGF"
    echo "PHASE=verification" >> "$MG_STATE/etape"
    check_run --files-from-raw "$d/renvoi"
    delete_ok
  done

  # vignettes Synology (@eaDir) des fichiers supprimes, puis dossiers devenus vides
  if [ "$nok" -gt 0 ]; then
    find "$s" -type d -name '@eaDir' -prune 2>/dev/null | while IFS= read -r ea; do
      for th in "$ea"/*; do [ -e "$th" ] && [ ! -e "${ea%/@eaDir}/${th##*/}" ] && rm -rf "$th"; done
      rmdir "$ea" 2>/dev/null
    done
    find "$s" -mindepth 1 -depth -type d -empty ! -name '.SynologyWorkingDirectory' -delete 2>/dev/null
  fi

  if [ "$ndiff" -eq 0 ] && [ "$nmiss" -eq 0 ] && [ "$nerr" -eq 0 ] && [ "$crc" -eq 0 ]; then
    VERIF_MSG="$nok fichier(s) controle(s) dans oCIS et supprime(s) $OC_DU"
    [ "$k" -gt 0 ] && VERIF_MSG="$VERIF_MSG (dont des fichiers renvoyes $k fois)"
    return 0
  fi
  VERIF_MSG="$nok controle(s) et supprime(s) ; gardes $OC_SUR : $ndiff different(s), $nmiss absent(s) d'oCIS, $nerr erreur(s)"
  [ "$k" -gt 0 ] && VERIF_MSG="$VERIF_MSG apres $k renvoi(s)"
  [ "$ndiff$nmiss$nerr" = 000 ] && VERIF_MSG="$VERIF_MSG, controle interrompu (code $crc)"
  VERIF_MSG="$VERIF_MSG — listes dans $d"
  if [ $((ndiff + nmiss + nerr)) -gt 0 ]; then
    oc_notify critique "Migration oCIS : fichiers gardés" \
      "$lab : $((ndiff + nmiss + nerr)) fichier(s) toujours en défaut après $k renvoi(s), gardé(s) $OC_SUR (rien n'est supprimé). Liste : $d"
  fi
  return 1
}

mg_worker() {  # tourne en arriere-plan : traite le lot ligne par ligne
  load_conf
  local obs i=0 n_ok=0 n_ko=0 s l id n dav sub t del rc st refpid="" soff
  obs=$(rclone obscure "$OCIS_PASS")
  oc_perf; MEMLIM="$OC_MEM"
  {
    echo "=== $(rclone version 2>/dev/null | head -n 1) · GOMEMLIMIT=$MEMLIM · overcommit=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null)"
    echo "=== $(oc_mem_info)"
  } >> "$MG_LOGF"
  while IFS='|' read -r s l id n dav sub t del; do
    del="${del:-non}"; i=$((i+1))
    local t0; t0=$(date +%s)
    printf 'ETAPE=%s\nE_SRC=%q\nE_LABEL=%q\nE_SPACE=%q\nE_TOTAL=%s\nE_DEL=%s\n' "$i" "$s" "$l" "$n${sub:+/$sub}" "$t" "$del" > "$MG_STATE/etape"
    dav=$(to_base "$dav")
    # taille de reference de la source (memes exclusions que rclone), mesuree en parallele
    [ -n "$refpid" ] && { pkill -P "$refpid" 2>/dev/null; kill "$refpid" 2>/dev/null; }
    rm -f "$MG_STATE/reference" "$MG_STATE/avancement"
    refpid=""; [ -d "$s" ] && [ "$del" != verif ] && { mg_reference "$s" "$i" & refpid=$!; }
    soff=$(stat -c %s "$MG_LOGF" 2>/dev/null || echo 0)
    export RCLONE_CONFIG_OCIS_TYPE=webdav RCLONE_CONFIG_OCIS_URL="$dav" RCLONE_CONFIG_OCIS_VENDOR="${OCIS_VENDOR:-owncloud}" \
           RCLONE_CONFIG_OCIS_USER="$OCIS_USER" RCLONE_CONFIG_OCIS_PASS="$obs"
    echo "=== [$i] $s -> $n${sub:+/$sub}  via ${dav%%/dav/*}  ($(date '+%F %T'))$(case "$del" in oui) echo "  + suppression des originaux controles";; verif) echo "  controle + suppression sans transfert";; esac)" >> "$MG_LOGF"
    local why="" requeue=1 try=0 retryable errs err1 off tr=$OC_T ck=$OC_C
    while :; do
      try=$((try+1))
      off=$(stat -c %s "$MG_LOGF" 2>/dev/null || echo 0)
      : > "$MG_STATE/rclone-err.log"
      if [ ! -d "$s" ]; then
        rc=3; echo "$(date '+%Y/%m/%d %H:%M:%S') ERROR : dossier source introuvable : $s" >> "$MG_LOGF"
      elif [ "$del" = verif ]; then
        rc=0; echo "=== [$i] migration deja faite : pas de transfert, controle et suppression seulement" >> "$MG_LOGF"
      else
        # --buffer-size 0 : pas de tampon de lecture (inutile depuis un disque local)
        # --disable-http2 : les envois en HTTP/2 font gonfler la memoire de rclone
        # stats toutes les 10 s dans le journal : l'avancement detaille vient de mg_monitor
        MG_SUIVI="$i $soff $(oc_safe "$l")" run_rclone copy "$s" "ocis:$sub" --create-empty-src-dirs "${MG_EXCL[@]}" "${RCLONE_K[@]}" \
          --transfers "$tr" --checkers "$ck" --buffer-size 0 --disable-http2 \
          --retries 5 --low-level-retries 20 \
          --stats 10s --stats-one-line --stats-log-level NOTICE --log-level NOTICE --log-file "$MG_LOGF"
        rc=$?
      fi
      [ $rc -eq 0 ] && break
      # --- cause de l'arret (uniquement ce qui a ete ecrit pendant cette tentative)
      errs=$(tail -c +$((off+1)) "$MG_LOGF" | grep -E 'ERROR|CRITICAL' | tail -n 50)
      err1=$(grep -m1 -E '^(panic|fatal error):' "$MG_STATE/rclone-err.log" 2>/dev/null | cut -c1-90)
      retryable=1; local mem=0
      if [ $rc -ge 128 ]; then
        why="rclone tue par le systeme (signal $((rc-128)))"
        dmesg 2>/dev/null | grep -iE 'killed process|out of memory|oom' | tail -n 2 | sed 's/^/    dmesg: /' >> "$MG_LOGF"
        grep -q 'dmesg:.*rclone' <(tail -n 3 "$MG_LOGF") && { why="rclone tue par le systeme : memoire insuffisante (OOM)"; mem=1; }
      elif grep -qiE 'out of memory|cannot allocate memory' "$MG_STATE/rclone-err.log" 2>/dev/null \
           || grep -qiE 'out of memory|cannot allocate memory' <<< "$errs"; then why="rclone a manque de memoire"; mem=1
      elif [ -n "$err1" ]; then why="rclone a plante : $err1"
      elif [ $rc -eq 3 ] || grep -q 'directory not found' <<< "$errs"; then
        why="dossier source introuvable ($s) : retire de la file"; requeue=0; retryable=0
      elif grep -qiE '507|insufficient storage|quota' <<< "$errs"; then why="quota de l'espace atteint (espace plein)"; retryable=0
      elif grep -q '401' <<< "$errs"; then why="jeton refuse (401) : expire ou revoque"; retryable=0
      elif grep -qiE 'connection refused|no such host|timeout' <<< "$errs"; then why="oCIS injoignable pendant le transfert"
      elif [ -n "$errs" ]; then why=$(grep -v 'Attempt [0-9]' <<< "$errs" | tail -n 1 | sed -E 's/^.*ERROR : //' | cut -c1-110)
      else why="rclone s'est arrete sans message (code $rc)"; fi
      echo "=== [$i] arret de rclone : code $rc ($why) · rclone utilisait jusqu'a ${RSS_MAX:-?} Mo · $(oc_mem_info)" >> "$MG_LOGF"
      if [ $mem -eq 1 ] && [ "$tr" -gt 1 ]; then
        tr=1; ck=2; echo "=== [$i] manque de memoire : la suite se fait avec 1 seul fichier a la fois" >> "$MG_LOGF"
      fi
      # --- reprise automatique : la copie repart la ou elle s'etait arretee
      if [ $retryable -eq 1 ] && [ $try -le $AUTO_REPRISE ]; then
        echo "=== [$i] reprise automatique $try/$AUTO_REPRISE dans 30 s" >> "$MG_LOGF"
        echo "REPRISE=$try" >> "$MG_STATE/etape"
        sleep 30; continue
      fi
      break
    done
    if [ $rc -eq 0 ]; then
      n_ok=$((n_ok+1)); st=OK; requeue=0; why=""; [ $try -gt 1 ] && why="apres $((try-1)) reprise(s) automatique(s)"
      [ -d "$s" ] && { mg_bilan "$s" "$sub" "$i" "$t0" $((try-1)) "$l"; why="${why:+$why, }$BILAN_MSG"; }
      if [ "$del" = oui ] || [ "$del" = verif ]; then
        if ! verify_and_delete "$s" "$sub" "$l"; then
          requeue=1; VERIF_MSG="$VERIF_MSG ; remise en file d'attente"
          # migration deja faite : les fichiers restants seront transferes puis controles
          [ "$del" = verif ] && { del=oui; VERIF_MSG="$VERIF_MSG (transfert des fichiers restants puis controle)"; }
        fi
        why="${why:+$why, }$VERIF_MSG"
      fi
    else
      n_ko=$((n_ko+1)); st="ECHEC"; [ $try -gt 1 ] && why="$why, apres $((try-1)) reprise(s)"
    fi
    local d=$(( ($(date +%s) - t0) / 60 ))
    echo "$(date '+%Y-%m-%d %H:%M') | $st${why:+ ($why)} | $s -> $n${sub:+/$sub} | ${d} min" >> "$MG_HIST"
    echo "$i|$st|$l|$n${sub:+/$sub}|$why" >> "$MG_STATE/resultats"
    [ $requeue -eq 1 ] && echo "$s|$l|$id|$n|$dav|$sub|$t|$del" >> "$MG_QUEUE"   # remis en file pour reprise
  done < "$MG_STATE/lot"
  [ -n "$refpid" ] && { pkill -P "$refpid" 2>/dev/null; kill "$refpid" 2>/dev/null; }
  echo "$n_ok|$n_ko" > "$MG_STATE/code"
  local msg="$n_ok migration(s) reussie(s)"; [ $n_ko -gt 0 ] && msg="$msg, $n_ko en echec (remise(s) en file d'attente pour reprise)"
  if [ $n_ko -eq 0 ]; then oc_notify info "Migration vers oCIS terminée" "$msg."
  else oc_notify critique "Migration vers oCIS : erreurs" "$msg."; fi
}


# =========================== Suivi ===================================
mg_show_results() {  # affiche les resultats des migrations terminees pas encore affiches
  [ -f "$MG_STATE/resultats" ] || return 0
  local i st l n why k=0
  while IFS='|' read -r i st l n why; do
    k=$((k+1)); [ $k -le $shown ] && continue
    if [ "$st" = OK ]; then echo -e "   ${OC_V}-> termine avec succes${why:+ ($why)}${OC_N}"
    else echo -e "   ${OC_R}-> ECHEC : $why${OC_N}"; echo -e "   ${OC_G}(remise en file d'attente, la suite continue)${OC_N}"; fi
    shown=$k
  done < "$MG_STATE/resultats"
}

mg_follow() {
  [ -f "$MG_RUN" ] || { echo "Aucune migration lancee."; return; }
  . "$MG_RUN"
  trap 'echo; echo -e "${OC_J}Suivi interrompu : la migration continue en arriere-plan.${OC_N}"; echo "Reprendre le suivi :  sudo bash $SELF migration suivi"; exit 0' INT
  echo -e "${OC_G}Ctrl+C = arreter le suivi (la migration continue)${OC_N}"
  local last="" line pct n bar shown=0 shown_rep="" ram cols
  cols=$(( $(tput cols 2>/dev/null || echo 100) - 1 ))
  status() { printf "\r\e[K%s" "${1:0:$cols}"; }   # efface la ligne avant de la reecrire
  while oc_alive "$PID"; do
    if [ -f "$MG_STATE/etape" ]; then
      unset REPRISE PHASE; . "$MG_STATE/etape"
      if [ "$ETAPE" != "$last" ]; then
        shown_rep=""
        [ -n "$last" ] && { echo; mg_show_results; }
        echo -e "\n${OC_B}[$ETAPE/$NB] $E_LABEL -> $E_SPACE${OC_N}  ($(oc_hsize "$E_TOTAL"))"
        last="$ETAPE"
      fi
      [ -n "${REPRISE:-}" ] && [ "${REPRISE}" != "${shown_rep:-}" ] && { echo; echo -e "   ${OC_J}rclone s'est arrete : reprise automatique ${REPRISE}/$AUTO_REPRISE...${OC_N}"; shown_rep="$REPRISE"; }
      ram=""; [ -f "$MG_STATE/rss" ] && ram=" · RAM rclone $(cut -d' ' -f1 "$MG_STATE/rss") Mo"
      case "${PHASE:-}" in
        verification|relecture)
          line=$(grep 'Checks:' "$MG_STATE/verif-$(oc_safe "$E_LABEL")/check.log" 2>/dev/null | tail -n 1 | sed 's/.*Checks: *//; s/  */ /g')
          status " $( [ "$PHASE" = relecture ] && echo "Controle par relecture depuis oCIS" || echo "Controle des empreintes dans oCIS") : ${line:-demarrage...}$ram" ;;
        suppression)
          status " Suppression des originaux controles $OC_SUR..." ;;
        bilan)
          status " Bilan : comptage des fichiers $OC_SUR et dans oCIS..." ;;
        renvoi)
          line=$(tail -n 60 "$MG_LOGF" 2>/dev/null | awk '/^=== /{l=""} /NOTICE:/{l=$0} END{print l}' | sed 's/.*NOTICE: *//; s/  */ /g')
          status " Renvoi des fichiers en defaut : ${line:-demarrage...}$ram" ;;
        *)
          # avancement detaille (mg_monitor) : par rapport a la vraie taille de la source
          if mg_pg_line; then
            if [ -n "$PG_P" ]; then
              n=$(( PG_P * 30 / 100 ))
              bar=$(printf '%*s' "$n" '' | tr ' ' '#')$(printf '%*s' $((30-n)) '' | tr ' ' '.')
              status " [$bar] $PG_P% · $PG_LINE$ram"
            else
              status " $PG_LINE$ram"
            fi
            sleep 2; continue
          fi
          # sinon : derniere ligne de stats apres le dernier marqueur "===" (journal sans detail par fichier)
          line=$(tail -n 60 "$MG_LOGF" 2>/dev/null | awk '/^=== /{l=""} /NOTICE:/{l=$0} END{print l}' | sed 's/.*NOTICE: *//; s/  */ /g')
          if [[ "$line" =~ ([0-9]+)% ]]; then
            pct="${BASH_REMATCH[1]}"; n=$(( pct * 30 / 100 ))
            bar=$(printf '%*s' "$n" '' | tr ' ' '#')$(printf '%*s' $((30-n)) '' | tr ' ' '.')
            status " [$bar] $line$ram"
          else
            status " Comparaison avec ce qui est deja dans oCIS...$ram"
          fi ;;
      esac
    fi
    sleep 2
  done
  echo; mg_show_results; echo
  if [ -f "$MG_STATE/resultats" ]; then
    echo -e "${OC_B}Bilan :${OC_N}"
    while IFS='|' read -r i st l n why; do
      [ "$st" = OK ] && echo -e "  ${OC_V}OK${OC_N}     $l -> $n${why:+ : $why}" || echo -e "  ${OC_R}ECHEC${OC_N}  $l -> $n : $why"
    done < "$MG_STATE/resultats"
    if grep -q ECHEC "$MG_STATE/resultats"; then
      if grep -q 'quota' "$MG_STATE/resultats"; then
        echo; echo -e "${OC_J}Espace plein : dans oCIS, ouvre l'espace > ⋯ > Modifier le quota > « Pas de restriction »."
        echo -e "(les nouveaux espaces ont 1 Go par defaut ; GRAPH_SPACES_DEFAULT_QUOTA=0 pour les suivants)${OC_N}"
      fi
      if grep -q '401' "$MG_STATE/resultats"; then load_conf; echo; http_hint 401; fi
      echo -e "${OC_J}Les migrations en echec (sauf dossier introuvable) sont remises en file d'attente : relance-les, elles reprendront.${OC_N}"
    fi
    echo
    rm -f "$MG_STATE/resultats"
  fi
  trap - INT
}

mg_stop_run() {
  mg_running || { echo "Aucune migration en cours."; return; }
  read -r -p "Arreter la migration en cours ? [o/N] : " c
  [[ "$c" =~ ^[oOyY] ]] || return
  pkill -TERM -s "$(ps -o sid= -p "$PID" | tr -d ' ')" 2>/dev/null || kill "$PID"
  # remet en file ce qui n'a pas ete termine
  if [ -f "$MG_STATE/etape" ]; then . "$MG_STATE/etape"; tail -n +"$ETAPE" "$MG_STATE/lot" >> "$MG_QUEUE"; fi
  rm -f "$MG_STATE/resultats"
  echo -e "${OC_J}Migration arretee. Les migrations non terminees sont remises en file d'attente.${OC_N}"
}

# =========================== Commandes sans question =================
# Utilisees par l'application Windows "NAS Manager".

mg_api_spaces() {  # id|nom|webDavUrl|libre|quota
  load_conf || die "connexion oCIS non configuree."
  list_spaces || { echo "HTTP $HTTP"; http_hint "$HTTP"; exit 2; }
  printf '%s\n' "${SPACES[@]}"
}

mg_api_sources() {  # chemin|libelle des « Mon Drive »
  local d u
  for d in /volume[0-9]*/homes/*/Drive; do
    [ -d "$d" ] || continue
    u="${d%/Drive}"; u="${u##*/}"
    echo "$d|$u"
  done
}

mg_api_add() {  # mg_api_add <source> <id espace> <sous-dossier|-> <non|oui|verif> [libelle]
  local src="${1%/}" sid="$2" sub="${3:-}" del="${4:-non}" lab="${5:-}" line found=""
  [ -d "$src" ] || die "dossier source introuvable : $src"
  [[ "$del" =~ ^(non|oui|verif)$ ]] || die "option de suppression invalide (non, oui ou verif)."
  [ "$sub" = - ] && sub=""; sub="${sub#/}"; sub="${sub%/}"
  [[ "$src$sub$lab" == *"|"* ]] && die "caractere | interdit."
  load_conf || die "connexion oCIS non configuree."
  list_spaces || { http_hint "$HTTP"; exit 2; }
  for line in "${SPACES[@]}"; do [ "${line%%|*}" = "$sid" ] && { found="$line"; break; }; done
  [ -n "$found" ] || die "espace oCIS introuvable (id $sid)."
  IFS="|" read -r SP_ID SP_NAME SP_DAV SP_FREE SP_QUOTA _ <<< "$found"
  if [ -z "$lab" ]; then
    lab="${src##*/}"; [[ "$src" =~ /homes/([^/]+)/Drive$ ]] && lab="${BASH_REMATCH[1]}"
  fi
  local total
  total=$(du -sb --exclude='@eaDir' --exclude='#SynoRecycle' --exclude='.SynologyWorkingDirectory' "$src" 2>/dev/null | cut -f1)
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$src" "$lab" "$SP_ID" "$SP_NAME" "$SP_DAV" "$sub" "${total:-0}" "$del" >> "$MG_QUEUE"
  echo "Ajoute a la file d'attente : $lab -> $SP_NAME${sub:+/$sub} ($(oc_hsize "${total:-0}"))"
  if [ "${SP_QUOTA:-0}" -gt 0 ] 2>/dev/null && [ "${total:-0}" -gt "${SP_FREE:-0}" ]; then
    echo "Attention : l'espace n'a que $(oc_hsize "$SP_FREE") de libre (quota $(oc_hsize "$SP_QUOTA")) : la migration s'arretera quand il sera plein."
  fi
}

mg_api_remove() {  # mg_api_remove <numero>
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le "$(grep -c '' "$MG_QUEUE" 2>/dev/null || echo 0)" ] \
    || die "numero invalide."
  sed -i "${1}d" "$MG_QUEUE"; echo "Retire de la file d'attente."
}

mg_api_start() {
  mg_running && die "une migration est deja en cours."
  [ -s "$MG_QUEUE" ] || die "la file d'attente est vide."
  load_conf || die "connexion oCIS non configuree."
  oc_need_rclone
  cp "$MG_QUEUE" "$MG_STATE/lot"; : > "$MG_QUEUE"
  [ -s "$MG_LOGF" ] && mv -f "$MG_LOGF" "$MG_LOGF.precedent"; : > "$MG_LOGF"
  rm -f "$MG_STATE/code" "$MG_STATE/etape" "$MG_STATE/resultats" "$MG_STATE/rss"
  printf 'NB=%s\nDEBUT=%s\n' "$(wc -l < "$MG_STATE/lot")" "$(date +%s)" > "$MG_RUN"
  nohup setsid bash "$SELF" migration _worker >/dev/null 2>&1 &
  echo "PID=$!" >> "$MG_RUN"
  echo "Migration lancee ($(wc -l < "$MG_STATE/lot") element(s))."
}

mg_api_stop() {
  mg_running || { echo "Aucune migration en cours."; return 0; }
  pkill -TERM -s "$(ps -o sid= -p "$PID" | tr -d ' ')" 2>/dev/null || kill "$PID"
  if [ -f "$MG_STATE/etape" ]; then . "$MG_STATE/etape"; tail -n +"$ETAPE" "$MG_STATE/lot" >> "$MG_QUEUE"; fi
  echo "Migration arretee. Les migrations non terminees sont remises en file d'attente."
}

# Configuration sans question : 5 lignes sur l'entree standard
#   adresse, utilisateur, jeton, adresse locale (ou -), certificat non reconnu accepte (0/1)
mg_api_configure() {
  local u usr pw lu insecure
  read -r u; read -r usr; read -r pw; read -r lu; read -r insecure
  u="${u%/}"; [[ "$u" =~ ^https?:// ]] || u="https://$u"
  [ -n "$usr" ] && [ -n "$pw" ] || die "utilisateur et jeton obligatoires."
  [ "$insecure" = 1 ] || insecure=0
  CURL_K=""; [ $insecure = 1 ] && CURL_K="-k"
  if ! curl -s $CURL_K -o /dev/null -m 15 "$u/status.php"; then
    if [ $insecure = 0 ] && curl -s -k -o /dev/null -m 15 "$u/status.php"; then
      die "certificat HTTPS d'oCIS non reconnu : coche « accepter le certificat » pour continuer."
    fi
    die "oCIS injoignable a l'adresse $u"
  fi
  OCIS_URL="$u"; BASE="$u"; OCIS_USER="$usr"; OCIS_PASS="$pw"
  api GET /graph/v1.0/me/drives
  case "$HTTP" in
    200) echo "Connexion a oCIS reussie." ;;
    401) die "identifiants refuses (401) : verifie le jeton (OCIS_ADD_RUN_SERVICES=auth-app et PROXY_ENABLE_APP_AUTH=true)." ;;
    *)   die "reponse inattendue d'oCIS (HTTP $HTTP)." ;;
  esac
  RCLONE_K=(); [ $insecure = 1 ] && RCLONE_K=(--no-check-certificate)
  oc_need_rclone
  if [ -n "$lu" ] && [ "$lu" != "-" ]; then
    lu="${lu%/}"; [[ "$lu" =~ ^https?:// ]] || lu="https://$lu"
    local sb="$BASE" sk="$CURL_K"; local -a sr=("${RCLONE_K[@]}")
    BASE="$lu"; CURL_K="-k"; RCLONE_K=(--no-check-certificate)
    api GET /graph/v1.0/me/drives
    if [ "$HTTP" = 200 ]; then echo "Adresse locale OK : $lu"
    else echo "L'adresse locale ne repond pas (HTTP $HTTP) : les transferts passeront par $u."; lu=""; BASE="$sb"; CURL_K="$sk"; RCLONE_K=("${sr[@]}"); fi
  else
    lu=""
  fi
  detect_vendor || exit 1
  printf 'OCIS_URL=%q\nLOCAL_URL=%q\nOCIS_USER=%q\nOCIS_PASS=%q\nOCIS_INSECURE=%s\nOCIS_VENDOR=%s\n' "$u" "$lu" "$usr" "$pw" "$insecure" "$OCIS_VENDOR" > "$MG_CONF"
  chmod 600 "$MG_CONF"
  echo "Configuration enregistree."
}

mg_main() {
  OC_TAG=migre-ocis
  mg_init
# =========================== Point d'entree ==========================
case "${1:-}" in
  _worker) mg_worker; exit ;;
  suivi)   mg_follow; exit ;;
  stop)    mg_stop_run; exit ;;
  espaces)     mg_api_spaces; exit ;;
  sources)     mg_api_sources; exit ;;
  ajouter)     mg_api_add "${2:-}" "${3:-}" "${4:-}" "${5:-non}" "${6:-}"; exit ;;
  retirer)     mg_api_remove "${2:-}"; exit ;;
  lancer)      mg_api_start; exit ;;
  arreter)     mg_api_stop; exit ;;
  configurer)  mg_api_configure; exit ;;
  jeton)       mg_jeton; exit ;;
  api-version) echo "$API_VERSION"; exit ;;
esac

mg_ensure_conf
api GET /graph/v1.0/me/drives
if [ "$HTTP" != 200 ]; then clear; http_hint "$HTTP"; echo; oc_pause
elif [ "${OCIS_VENDOR:-infinitescale}" = infinitescale ]; then
  clear
  echo -e "${OC_J}Mise a jour : passage des envois en WebDAV classique.${OC_N}"
  echo "Le mode oCIS natif de rclone fait exploser la memoire (bug connu) : c'est ce qui"
  echo "faisait tuer rclone par le systeme sur le NAS."
  oc_need_rclone
  if detect_vendor; then
    sed -i "s/^OCIS_VENDOR=.*/OCIS_VENDOR=$OCIS_VENDOR/" "$MG_CONF"; load_conf
  fi
  oc_pause
fi
while true; do
  clear
  echo -e "${OC_B}===== MIGRATION $OC_NOM -> oCIS =====${OC_N}"
  echo -e "oCIS : $OCIS_URL  (compte $OCIS_USER, mode ${OCIS_VENDOR:-infinitescale})"
  [ -n "${LOCAL_URL:-}" ] && echo -e "Transferts : ${OC_V}reseau local${OC_N} ($LOCAL_URL)" \
                          || echo -e "Transferts : ${OC_J}via Internet${OC_N} (menu 7 pour ajouter l'adresse locale)"
  if mg_running; then . "$MG_STATE/etape" 2>/dev/null; echo -e "${OC_J}Migration en cours : ${E_LABEL:-...} (${ETAPE:-?}/$NB)${OC_N}"; fi
  echo; echo -e "${OC_B}File d'attente :${OC_N}"; mg_show_queue; echo
  echo "  1) Ajouter une migration a la file d'attente"
  echo "  2) Retirer une migration de la file"
  echo "  3) Lancer la file d'attente"
  echo "  4) Suivre la migration en cours"
  echo "  5) Arreter la migration en cours"
  echo "  6) Historique"
  echo "  7) Modifier la connexion oCIS"
  echo "  8) Controler et supprimer les originaux d'une migration deja faite"
  echo "  0) Quitter"
  read -r -p "Choix : " c
  case "$c" in
    1) mg_add_task; sleep 1 ;;
    2) mg_remove_task ;;
    3) mg_start; oc_pause ;;
    4) mg_follow; oc_pause ;;
    5) mg_stop_run; sleep 2 ;;
    6) clear; tail -n 30 "$MG_HIST" 2>/dev/null || echo "Aucune migration."; oc_pause ;;
    7) mg_setup_conf || oc_pause ;;
    8) mg_add_verif; sleep 2 ;;
    0|q) exit 0 ;;
  esac
done
}

mg_init() {
  oc_need_root
  mkdir -p "$MG_STATE"; chmod 700 "$MG_STATE"
  command -v python3 >/dev/null || die "python3 est introuvable sur le NAS (necessaire pour dialoguer avec oCIS)."
}

# Expiration du jeton d'application oCIS (JSON) : etat ok|refuse|inconnu|non_configure
mg_jeton() {
  load_conf || { echo '{"etat":"non_configure"}'; return 0; }
  api GET /graph/v1.0/me/drives
  if [ "$HTTP" = 401 ]; then echo '{"etat":"refuse","http":401}'; return 0; fi
  [ "$HTTP" = 200 ] || { printf '{"etat":"injoignable","http":"%s"}\n' "$HTTP"; return 0; }
  api GET /auth-app/tokens
  if [ "$HTTP" != 200 ]; then printf '{"etat":"inconnu","http":"%s"}\n' "$HTTP"; return 0; fi
  python3 -c '
import json, sys, time
from datetime import datetime
try:
    d = json.load(sys.stdin)
except Exception:
    print(json.dumps({"etat": "inconnu"})); sys.exit()
items = d if isinstance(d, list) else d.get("value", d.get("tokens", []))
now, exp = time.time(), []
for t in items if isinstance(items, list) else []:
    v = t.get("expiration_date") or t.get("expirationDate") or t.get("expiry") if isinstance(t, dict) else None
    if not v:
        continue
    try:
        ts = datetime.fromisoformat(str(v).replace("Z", "+00:00")).timestamp()
    except ValueError:
        continue
    if ts > now:
        exp.append(ts)
print(json.dumps({"etat": "ok", "expire": int(max(exp)) if exp else None, "nb": len(exp)}))
' <<< "$BODY"
}

# =========================== Transferts oCIS -> machine ==============
# Sens inverse de la migration : un dossier d'un espace oCIS (personnel ou projet) recopie
# dans un dossier de la machine, par l'API WebDAV d'oCIS (jamais de lecture directe du
# stockage d'oCIS), dates de modification conservees, reprise en cas d'interruption.
# $TR_STATE/transferts.conf, une ligne par transfert :
#   NOM|ESPACE_ID|ESPACE (nom affiche)|SOUS_DOSSIER (dans l'espace, vide = tout l'espace)
#   |DESTINATION (dossier de la machine)|MODE (copie | miroir)|CORBEILLE_JOURS (miroir)
#   |HORAIRE (manuel, une-fois, ou HH:MM[/jours] separes par ;)|DEBIT (limite rclone, ex. 5M)
# « une-fois » : transfert ponctuel, retire de la liste apres un succes.
# Miroir : les fichiers supprimes ou remplaces dans la destination sont gardes CORBEILLE_JOURS
# jours dans <destination>/.corbeille-oCIS/<date> (0 = supprimes directement).
# Une file d'attente : un seul transfert a la fois, dans l'ordre (programmes compris).
TR_STATE="/root/.ocis-transferts"
TR_CONF="$TR_STATE/transferts.conf"
TR_QUEUE="$TR_STATE/file-attente"
TR_RUN="$TR_STATE/en-cours"
TR_LOGF="$TR_STATE/progression.log"
TR_HIST="$TR_STATE/historique.log"
TR_CORB=".corbeille-oCIS"

tr_init() {
  oc_need_root
  mkdir -p "$TR_STATE" "$TR_STATE/journaux"; chmod 700 "$TR_STATE"
  touch "$TR_CONF" "$TR_QUEUE"
  command -v python3 >/dev/null || die "python3 est introuvable (necessaire pour dialoguer avec oCIS)."
}

tr_names() { [ -f "$TR_CONF" ] && grep -v '^#' "$TR_CONF" | grep -v '^$' | cut -d'|' -f1; return 0; }
tr_exists() { [ -f "$TR_CONF" ] && grep -q "^$1|" "$TR_CONF"; }

tr_get() {  # tr_get <nom> -> T_NAME T_SPACE T_SPNAME T_SUB T_DEST T_MODE T_RET T_SCHED T_BW
  local line; line=$(grep -m1 "^$1|" "$TR_CONF" 2>/dev/null) || return 1
  IFS='|' read -r T_NAME T_SPACE T_SPNAME T_SUB T_DEST T_MODE T_RET T_SCHED T_BW _ <<< "$line"
  T_MODE="${T_MODE:-copie}"; T_RET="${T_RET:-0}"; T_SCHED="${T_SCHED:-manuel}"; T_BW="${T_BW:-}"
  return 0
}

tr_save_line() {
  local tmp; tmp=$(mktemp)
  grep -v "^$T_NAME|" "$TR_CONF" 2>/dev/null > "$tmp"
  echo "$T_NAME|$T_SPACE|$T_SPNAME|$T_SUB|$T_DEST|$T_MODE|$T_RET|$T_SCHED|$T_BW" >> "$tmp"
  cat "$tmp" > "$TR_CONF"; rm -f "$tmp"; chmod 600 "$TR_CONF"
}

tr_del_line() {
  local tmp; tmp=$(mktemp)
  grep -v "^$1|" "$TR_CONF" 2>/dev/null > "$tmp"; cat "$tmp" > "$TR_CONF"; rm -f "$tmp"
}

# Horaires : manuel, une-fois, ou HH:MM[/jours 1-7] separes par ;
oc_valid_sched() {
  case "$1" in manuel|une-fois) return 0 ;; "") return 1 ;; esac
  local IFS=';' sl
  for sl in $1; do [[ "$sl" =~ ^([01][0-9]|2[0-3]):[0-5][0-9](/[1-7]+)?$ ]] || return 1; done
  return 0
}

oc_slot_matches() {  # oc_slot_matches <horaire> <HH:MM> <jour 1-7>
  case "$1" in manuel|une-fois) return 1 ;; esac
  local IFS=';' sl
  for sl in $1; do
    [ "${sl%%/*}" = "$2" ] || continue
    [[ "$sl" != */* ]] && return 0
    [[ "${sl#*/}" == *"$3"* ]] && return 0
  done
  return 1
}

tr_gen_cron() {
  local n t sl lines=""
  local -A vus=()
  for n in $(tr_names); do
    tr_get "$n" || continue
    oc_valid_sched "$T_SCHED" || continue
    case "$T_SCHED" in manuel|une-fois) continue ;; esac
    local IFS=';'
    for sl in $T_SCHED; do
      t="${sl%%/*}"
      [ -n "${vus[$t]:-}" ] && continue
      vus[$t]=1
      lines="${lines:+$lines
}$((10#${t##*:})) $((10#${t%%:*})) * * * root $SELF transferts run-at $t >/dev/null 2>&1"
    done
    unset IFS
  done
  oc_cron_ecrire "$lines"
}

tr_running() { [ -f "$TR_RUN" ] && . "$TR_RUN" && oc_alive "$PID"; }

tr_queued() { [ -f "$TR_QUEUE" ] && grep -qxF "$1" "$TR_QUEUE"; }

tr_current() { [ -f "$TR_STATE/etape" ] && sed -n 's/^NOM=//p' "$TR_STATE/etape" | head -n 1; }

# Ajoute un transfert a la file (s'il n'y est pas deja et ne tourne pas) -> 0 si ajoute
tr_enqueue() {
  ( flock 8
    if tr_queued "$1" || { tr_running && [ "$(tr_current)" = "$1" ]; }; then exit 1; fi
    echo "$1" >> "$TR_QUEUE"
  ) 8>"$TR_STATE/.verrou"
}

# Premier transfert de la file (retire) ; file vide : le traitement s'arrete (en-cours retire
# sous le meme verrou que tr_kick, pour qu'un transfert ajoute a ce moment-la reparte)
tr_pop() {
  ( flock 8
    if [ -s "$TR_QUEUE" ]; then head -n 1 "$TR_QUEUE"; sed -i '1d' "$TR_QUEUE"
    else rm -f "${TR_STATE:?}/en-cours" "${TR_STATE:?}/avancement" "${TR_STATE:?}/reference" "${TR_STATE:?}/rss"; fi
  ) 8>"$TR_STATE/.verrou"
}

# Demarre le traitement de la file s'il ne tourne pas deja
tr_kick() {
  ( flock 8
    tr_running && exit 0
    [ -s "$TR_QUEUE" ] || exit 0
    printf 'DEBUT=%s\n' "$(date +%s)" > "$TR_RUN"
    # 8>&- : le traitement ne doit pas garder le verrou (il le reprend pour chaque transfert)
    nohup setsid bash "$SELF" transferts _worker >/dev/null 2>&1 < /dev/null 8>&- &
    echo "PID=$!" >> "$TR_RUN"
  ) 8>"$TR_STATE/.verrou"
}

# Taille de reference de la source oCIS (avancement par rapport a la vraie taille)
tr_reference() {  # tr_reference <source> <etape>
  local j f o
  j=$(GOGC=50 GOMEMLIMIT="$MEMLIM" rclone size --json "$1" --exclude "/$TR_CORB/**" "${RCLONE_K[@]}" --disable-http2 --checkers 4 < /dev/null 2>/dev/null) || return 0
  f=$(sed -n 's/.*"count":\([0-9]*\).*/\1/p' <<< "$j"); o=$(sed -n 's/.*"bytes":\([0-9]*\).*/\1/p' <<< "$j")
  [ -n "$f" ] && [ -n "$o" ] || return 0
  printf 'REF_ETAPE=%s\nREF_FICHIERS=%s\nREF_OCTETS=%s\nREF_MAJ=%s\n' "$2" "$f" "$o" "$(date +%s)" > "$TR_STATE/reference.tmp" \
    && mv -f "$TR_STATE/reference.tmp" "$TR_STATE/reference"
}

# Corbeille du miroir : dossiers dates (AAAA-MM-JJ_HHMM) de plus de <jours> jours effaces
tr_trash_purge() {  # tr_trash_purge <corbeille> <jours>
  local d cut n
  [ "$2" -gt 0 ] 2>/dev/null && [ -d "$1" ] || return 0
  cut=$(date -d "-$2 days" +%Y-%m-%d_%H%M)
  for d in "$1"/*/; do
    n="${d%/}"; n="${n##*/}"
    [[ "$n" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4} ]] || continue
    [[ "${n:0:15}" < "$cut" ]] && rm -rf "${1:?}/$n"
  done
  rmdir "$1" 2>/dev/null
  return 0
}

tr_worker() {  # tourne en arriere-plan : traite la file d'attente
  local n obs
  if ! load_conf; then
    echo "$(date '+%Y-%m-%d %H:%M') | ECHEC (connexion oCIS non configuree) | - | 0 min" >> "$TR_HIST"
    rm -f "${TR_STATE:?}/en-cours"; exit 1
  fi
  oc_need_rclone >/dev/null
  obs=$(rclone obscure "$OCIS_PASS")
  oc_perf; MEMLIM="$OC_MEM"
  # suivi detaille (run_rclone, mg_monitor) : dans le dossier des transferts
  MG_STATE="$TR_STATE"; MG_LOGF="$TR_LOGF"
  while n=$(tr_pop); [ -n "$n" ]; do
    tr_run_one "$n" "$obs"
  done
}

# Bilan d'un passage de rclone d'apres son journal (dernier bloc de statistiques)
#   -> « fichiers copies|octets|fichiers supprimes »
tr_bilan_log() {  # tr_bilan_log <journal> <position de debut>
  tail -c +$(($2 + 1)) "$1" 2>/dev/null | python3 -c '
import re, sys
U = {"": 1, "B": 1, "KiB": 1 << 10, "MiB": 1 << 20, "GiB": 1 << 30, "TiB": 1 << 40, "k": 1 << 10, "Ki": 1 << 10, "Mi": 1 << 20, "Gi": 1 << 30}
f = o = s = 0
for l in sys.stdin:
    m = re.search(r"Transferred:\s+(\d+) / \d+, ", l)
    if m:
        f = int(m.group(1)); continue
    m = re.search(r"Transferred:\s+([\d.]+)\s*([KMGT]?i?B?) / ", l)
    if m:
        o = int(float(m.group(1)) * U.get(m.group(2), 1)); continue
    m = re.search(r"Deleted:\s+(\d+) \(files\)", l)
    if m:
        s = int(m.group(1))
print("%d|%d|%d" % (f, o, s))'
}

tr_run_one() {  # tr_run_one <nom> <mot de passe obscurci>
  local obs="$2" t0 rc=1 why="" st try=0 dav="" line refpid="" soff errs retryable cmd=copy tr ck d etat
  t0=$(date +%s)
  if ! tr_get "$1"; then
    echo "$(date '+%Y-%m-%d %H:%M') | ECHEC (transfert introuvable) | $1 | 0 min" >> "$TR_HIST"; return
  fi
  etat="$TR_STATE/$(oc_safe "$T_NAME").etat"
  printf 'NOM=%s\nDEBUT=%s\nESPACE=%q\nSOUS=%q\nDEST=%q\nMODE=%s\nPHASE=transfert\n' "$T_NAME" "$t0" "$T_SPNAME" "$T_SUB" "$T_DEST" "$T_MODE" > "$TR_STATE/etape"
  rm -f "${TR_STATE:?}/avancement" "${TR_STATE:?}/reference"
  [ -s "$TR_LOGF" ] && mv -f "$TR_LOGF" "$TR_LOGF.precedent"
  : > "$TR_LOGF"
  {
    echo "=== $T_NAME : $T_SPNAME${T_SUB:+/$T_SUB} -> $T_DEST ($T_MODE$( [ "$T_MODE" = miroir ] && [ "$T_RET" -gt 0 ] && echo ", corbeille $T_RET j")) $(date '+%F %T')"
    echo "=== $(rclone version 2>/dev/null | head -n 1) · GOMEMLIMIT=$MEMLIM · $(oc_mem_info)"
  } >> "$TR_LOGF"
  # adresse WebDAV de l'espace (a jour : l'espace a pu etre renomme)
  if list_spaces tous; then
    for line in "${SPACES[@]}"; do [ "${line%%|*}" = "$T_SPACE" ] && { IFS='|' read -r _ _ dav _ <<< "$line"; break; }; done
    [ -n "$dav" ] || why="espace oCIS « $T_SPNAME » introuvable (supprime, ou compte plus membre ?)"
  elif [ "$HTTP" = 401 ]; then
    why="jeton refuse (401) : expire ou revoque"
  else
    why="oCIS injoignable (HTTP $HTTP)"
  fi
  d="${T_DEST%/}"
  if [ -z "$why" ] && [ ! -d "$d" ]; then
    if [ -d "$(dirname "$d")" ]; then mkdir -p "$d" || why="creation de $d impossible"
    else why="dossier de destination introuvable : $d (disque demonte ?)"; fi
  fi
  if [ -n "$why" ]; then
    echo "$(date '+%Y/%m/%d %H:%M:%S') ERROR : $why" >> "$TR_LOGF"
  else
    export RCLONE_CONFIG_OCIS_TYPE=webdav RCLONE_CONFIG_OCIS_URL="$dav" RCLONE_CONFIG_OCIS_VENDOR="${OCIS_VENDOR:-owncloud}" \
           RCLONE_CONFIG_OCIS_USER="$OCIS_USER" RCLONE_CONFIG_OCIS_PASS="$obs"
    tr_reference "ocis:$T_SUB" 1 & refpid=$!
    touch "$TR_STATE/debut-transfert"
    tr=$OC_T; ck=$OC_C
    [ "$T_MODE" = miroir ] && cmd=sync
    while :; do
      try=$((try + 1))
      soff=$(stat -c %s "$TR_LOGF" 2>/dev/null || echo 0)
      local -a opt=(--transfers "$tr" --checkers "$ck" --disable-http2 --retries 5 --low-level-retries 20
                    --exclude "/$TR_CORB/**" "${RCLONE_K[@]}"
                    --stats 60s --stats-log-level NOTICE --log-level NOTICE --log-file "$TR_LOGF")
      [ -n "$T_BW" ] && opt+=(--bwlimit "$T_BW")
      [ "$cmd" = sync ] && [ "$T_RET" -gt 0 ] && opt+=(--backup-dir "$d/$TR_CORB/$(date +%Y-%m-%d_%H%M)")
      : > "$TR_STATE/rclone-err.log"
      MG_SUIVI="1 $soff $(oc_safe "$T_NAME")" run_rclone "$cmd" "ocis:$T_SUB" "$d" "${opt[@]}"; rc=$?
      [ $rc -eq 0 ] && { why=""; break; }
      [ -f "$TR_STATE/stop" ] && break
      errs=$(tail -c +$((soff + 1)) "$TR_LOGF" | grep -E 'ERROR|CRITICAL' | grep -v 'Attempt [0-9]' | tail -n 30)
      retryable=1
      if [ $rc -ge 128 ]; then why="rclone arrete par le systeme (signal $((rc - 128)))"; tr=1; ck=2
      elif grep -qiE 'out of memory|cannot allocate memory' "$TR_STATE/rclone-err.log" 2>/dev/null; then why="rclone a manque de memoire"; tr=1; ck=2
      elif grep -q '401' <<< "$errs"; then why="jeton refuse (401) : expire ou revoque"; retryable=0
      elif grep -qiE 'directory not found' <<< "$errs"; then why="dossier « ${T_SUB:-/} » introuvable dans l'espace oCIS"; retryable=0
      elif grep -qiE 'no space left|disk quota' <<< "$errs"; then why="plus de place sur la destination"; retryable=0
      elif grep -qiE 'connection refused|no such host|timeout' <<< "$errs"; then why="oCIS injoignable pendant le transfert"
      elif [ -n "$errs" ]; then why=$(tail -n 1 <<< "$errs" | sed -E 's/^.*ERROR : //' | cut -c1-140)
      else why="rclone s'est arrete sans message (code $rc)"; fi
      echo "=== arret de rclone : code $rc ($why)" >> "$TR_LOGF"
      if [ $retryable -eq 1 ] && [ $try -le "$AUTO_REPRISE" ]; then
        echo "=== reprise automatique $try/$AUTO_REPRISE dans 30 s" >> "$TR_LOGF"
        echo "REPRISE=$try" >> "$TR_STATE/etape"
        sleep 30; continue
      fi
      break
    done
    [ -n "$refpid" ] && { pkill -P "$refpid" 2>/dev/null; kill "$refpid" 2>/dev/null; }
  fi
  # bilan (dernier passage de rclone)
  local nf=0 no=0 ns=0 dur
  IFS='|' read -r nf no ns < <(tr_bilan_log "$TR_LOGF" "${soff:-0}")
  dur=$(( $(date +%s) - t0 ))
  if [ $rc -eq 0 ] && [ -z "$why" ]; then
    st=OK
    [ "$cmd" = sync ] && [ "$T_RET" -gt 0 ] && tr_trash_purge "$d/$TR_CORB" "$T_RET"
    oc_droits "$d" "$TR_STATE/debut-transfert" 2>/dev/null || true
    if [ "${nf:-0}" -eq 0 ] && [ "${ns:-0}" -eq 0 ]; then why="deja a jour"
    else why="${nf:-0} fichier(s) copie(s) ($(oc_hsize "${no:-0}"))"; fi
    [ "${ns:-0}" -gt 0 ] && why="$why, ${ns} supprime(s)$( [ "$T_RET" -gt 0 ] && echo " (gardes $T_RET j dans la corbeille)")"
    [ "$try" -gt 1 ] && why="$why, apres $((try - 1)) reprise(s)"
  elif [ -f "$TR_STATE/stop" ]; then
    st=ARRETE; why="arrete manuellement"
  else
    st=ECHEC
  fi
  rm -f "${TR_STATE:?}/stop" "${TR_STATE:?}/debut-transfert"
  printf 'ETAT=%s\nDEBUT=%s\nFIN=%s\nDETAIL=%q\nTRANSFERTS=%s\nOCTETS=%s\nSUPPR=%s\n' "$st" "$t0" "$(date +%s)" "$why" \
    "${nf:-0}" "${no:-0}" "${ns:-0}" > "$etat"
  echo "$(date '+%Y-%m-%d %H:%M') | $st${why:+ ($why)} | $T_SPNAME${T_SUB:+/$T_SUB} -> $d | $((dur / 60)) min" >> "$TR_HIST"
  local jl; jl="$TR_STATE/journaux/$(oc_safe "$T_NAME").log"
  cat "$TR_LOGF" >> "$jl" 2>/dev/null
  tail -n 2000 "$jl" > "$jl.tmp" 2>/dev/null && mv -f "$jl.tmp" "$jl"
  case "$st" in
    OK)
      oc_notify info "Transfert oCIS « $T_NAME » terminé" "$T_SPNAME${T_SUB:+/$T_SUB} → $d : $why."
      if [ "$T_SCHED" = une-fois ]; then tr_del_line "$T_NAME"; tr_gen_cron; fi ;;
    ECHEC) oc_notify critique "Transfert oCIS « $T_NAME » en échec" "$why. Le relancer reprendra où il s'est arrêté." ;;
  esac
  rm -f "${TR_STATE:?}/etape"
}

tr_api_save() {  # tr_api_save <nouveau|modif> NOM ESPACE_ID SOUS DEST MODE CORBEILLE HORAIRE [DEBIT]
  local kind="$1"; shift
  [ $# -ge 7 ] && [ $# -le 8 ] || die "usage : transferts save <nouveau|modif> NOM ESPACE_ID SOUS-DOSSIER DESTINATION MODE CORBEILLE HORAIRE [DEBIT]"
  T_NAME="$1" T_SPACE="$2" T_SUB="$3" T_DEST="${4%/}" T_MODE="$5" T_RET="$6" T_SCHED="$7" T_BW="${8:-}"
  [ "$T_SUB" = - ] && T_SUB=""
  T_SUB="${T_SUB#/}"; T_SUB="${T_SUB%/}"
  [[ "$T_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "nom invalide (lettres, chiffres, - et _)."
  case "$kind" in
    nouveau) tr_exists "$T_NAME" && die "un transfert « $T_NAME » existe deja." ;;
    modif)   tr_exists "$T_NAME" || die "transfert « $T_NAME » introuvable." ;;
    *)       die "type inconnu : $kind" ;;
  esac
  [[ "$T_SPACE" =~ ^[A-Za-z0-9\$!._:@-]+$ ]] || die "espace oCIS invalide."
  [[ "$T_SUB" != *"|"* && "/$T_SUB/" != *"/../"* ]] || die "sous-dossier invalide."
  [[ "$T_DEST" == /* && "$T_DEST" != *"|"* && "/$T_DEST/" != *"/../"* && "$T_DEST" != / ]] || die "dossier de destination invalide (chemin complet)."
  [ -d "$T_DEST" ] || [ -d "$(dirname "$T_DEST")" ] || die "dossier de destination introuvable : $T_DEST"
  [[ "$T_MODE" =~ ^(copie|miroir)$ ]] || die "mode invalide (copie ou miroir)."
  [[ "$T_RET" =~ ^[0-9]+$ ]] || die "nombre de jours de corbeille invalide."
  [ "$T_MODE" = miroir ] || T_RET=0
  oc_valid_sched "$T_SCHED" || die "horaire invalide (manuel, une-fois, HH:MM, HH:MM/JOURS, plusieurs separes par ;)."
  [[ -z "$T_BW" || "$T_BW" =~ ^[0-9A-Za-z:.,\ -]+$ ]] || die "limite de debit invalide (ex. 5M)."
  load_conf || die "connexion oCIS non configuree : configure-la d'abord."
  list_spaces tous || { http_hint "$HTTP"; exit 2; }
  local line found="" n
  for line in "${SPACES[@]}"; do [ "${line%%|*}" = "$T_SPACE" ] && { found="$line"; break; }; done
  [ -n "$found" ] || die "espace oCIS introuvable (id $T_SPACE)."
  IFS='|' read -r _ T_SPNAME _ <<< "$found"
  # meme destination qu'un autre transfert
  for n in $(tr_names); do
    [ "$n" = "$T_NAME" ] && continue
    [ "$(grep -m1 "^$n|" "$TR_CONF" | cut -d'|' -f5)" = "$T_DEST" ] && echo -e "${OC_J}Attention : le transfert « $n » ecrit deja dans $T_DEST.${OC_N}"
  done
  tr_save_line; tr_gen_cron
  echo -e "${OC_V}Transfert « $T_NAME » enregistre : $T_SPNAME${T_SUB:+/$T_SUB} -> $T_DEST ($T_MODE, $( case "$T_SCHED" in manuel) echo "a la demande";; une-fois) echo "ponctuel";; *) echo "$T_SCHED";; esac)).${OC_N}"
  if [ "$T_SCHED" = une-fois ]; then
    tr_enqueue "$T_NAME" && tr_kick && echo "Transfert lance."
  fi
  return 0
}

tr_api_delete() {
  tr_exists "${1:-}" || die "transfert « ${1:-} » introuvable."
  tr_running && [ "$(tr_current)" = "$1" ] && die "le transfert « $1 » est en cours : arrete-le d'abord."
  tr_del_line "$1"
  ( flock 8; grep -vxF "$1" "$TR_QUEUE" > "$TR_QUEUE.new"; mv -f "$TR_QUEUE.new" "$TR_QUEUE" ) 8>"$TR_STATE/.verrou"
  rm -f "${TR_STATE:?}/$(oc_safe "$1").etat"
  tr_gen_cron
  echo -e "${OC_V}Transfert « $1 » supprime (les fichiers deja copies restent en place).${OC_N}"
}

tr_api_launch() {
  tr_exists "${1:-}" || die "transfert « ${1:-} » introuvable."
  load_conf || die "connexion oCIS non configuree."
  local avant=0
  tr_running && avant=1
  if tr_enqueue "$1"; then
    tr_kick
    if [ $avant = 1 ]; then echo "Transfert « $1 » ajoute a la file d'attente (un autre transfert est en cours)."
    else echo "Transfert « $1 » lance."; fi
  else
    echo "Le transfert « $1 » est deja en cours ou dans la file d'attente."
  fi
}

tr_api_stop() {
  tr_running || { echo "Aucun transfert en cours."; return 0; }
  touch "$TR_STATE/stop"
  # le transfert en cours s'arrete ; la file d'attente est videe (rien ne repart tout seul)
  ( flock 8; : > "$TR_QUEUE" ) 8>"$TR_STATE/.verrou"
  pkill -TERM -f "rclone .*--log-file $TR_LOGF" 2>/dev/null
  local i
  for i in $(seq 30); do tr_running || break; sleep 1; done
  tr_running && pkill -TERM -s "$(ps -o sid= -p "$PID" | tr -d ' ')" 2>/dev/null
  echo "Transfert arrete. Le relancer reprendra ou il s'est arrete."
}

tr_run_at() {  # cron : transferts prevus a cette heure -> file d'attente
  local n dow
  dow=$(date +%u)
  for n in $(tr_names); do
    tr_get "$n" || continue
    oc_slot_matches "$T_SCHED" "$1" "$dow" && tr_enqueue "$n"
  done
  tr_kick
}

# Sous-dossiers d'un dossier d'un espace (un par ligne)
tr_browse() {  # tr_browse <espace_id> [chemin]
  local line dav="" rel="${2:-}"
  rel="${rel#/}"; rel="${rel%/}"
  [[ "/$rel/" != *"/../"* ]] || die "chemin invalide."
  load_conf || die "connexion oCIS non configuree."
  oc_need_rclone >/dev/null
  list_spaces tous || { http_hint "$HTTP"; exit 2; }
  for line in "${SPACES[@]}"; do [ "${line%%|*}" = "$1" ] && { IFS='|' read -r _ _ dav _ <<< "$line"; break; }; done
  [ -n "$dav" ] || die "espace oCIS introuvable."
  RCLONE_CONFIG_OCIS_TYPE=webdav RCLONE_CONFIG_OCIS_URL="$dav" RCLONE_CONFIG_OCIS_VENDOR="${OCIS_VENDOR:-owncloud}" \
  RCLONE_CONFIG_OCIS_USER="$OCIS_USER" RCLONE_CONFIG_OCIS_PASS="$(rclone obscure "$OCIS_PASS")" \
    rclone lsf --dirs-only "ocis:$rel" "${RCLONE_K[@]}" --disable-http2 < /dev/null | sed 's#/$##'
}

tr_list() {  # liste lisible (menu)
  local n i=1
  for n in $(tr_names); do
    tr_get "$n" || continue
    printf "  %2d) %-16s %s -> %s  (%s, %s)\n" "$i" "$T_NAME" "$T_SPNAME${T_SUB:+/$T_SUB}" "$T_DEST" "$T_MODE" "$T_SCHED"
    i=$((i + 1))
  done
  [ $i -gt 1 ] || echo -e "  ${OC_G}(aucun transfert)${OC_N}"
}

tr_follow() {
  tr_running || { echo "Aucun transfert en cours."; [ -f "$TR_HIST" ] && tail -n 5 "$TR_HIST"; return; }
  echo -e "${OC_G}Ctrl+C = arreter le suivi (le transfert continue)${OC_N}"
  local PG_FICHIERS PG_REF_FICHIERS PG_ENVOYE PG_VITESSE PG_ETA nom
  while tr_running; do
    nom=$(tr_current)
    if [ -f "$TR_STATE/avancement" ]; then
      # shellcheck disable=SC1090
      . "$TR_STATE/avancement"
      printf "\r\e[K %s : %s fichiers%s · %s · %s/s%s" "$nom" "${PG_FICHIERS:-0}" "${PG_REF_FICHIERS:+ / $PG_REF_FICHIERS}" \
        "$(oc_hsize "${PG_ENVOYE:-0}")" "$(oc_hsize "${PG_VITESSE:-0}")" "${PG_ETA:+ · reste ~$(oc_hdur "$PG_ETA")}"
    else
      printf "\r\e[K %s : comparaison avec la destination..." "$nom"
    fi
    sleep 2
  done
  echo; tail -n 3 "$TR_HIST" 2>/dev/null
}

# Ajout interactif (menu SSH)
tr_add_task() {
  mg_ensure_conf
  local -a sp=(); local i c line nm sub dest mode=copie ret=0 sched=manuel nom
  list_spaces tous || { http_hint "$HTTP"; oc_pause; return; }
  sp=("${SPACES[@]}")
  [ ${#sp[@]} -gt 0 ] || { echo "Aucun espace oCIS visible pour ce compte."; oc_pause; return; }
  clear; echo -e "${OC_B}== Espace oCIS a recopier ==${OC_N}"
  i=1; for line in "${sp[@]}"; do IFS='|' read -r _ nm _ <<< "$line"; printf "  %2d) %s\n" "$i" "$nm"; i=$((i + 1)); done
  read -r -p "Choix (Entree = annuler) : " c
  [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#sp[@]} ] || return
  line="${sp[$((c - 1))]}"
  read -r -p "Sous-dossier dans l'espace (Entree = tout l'espace) : " sub
  mg_browse_local || return
  dest="$CHOIX"
  read -r -p "Dans « $dest », sous-dossier a creer (Entree = directement dedans) : " c
  [ -n "$c" ] && dest="$dest/${c//\//_}"
  echo "  1) Copie : rien n'est jamais supprime dans la destination"
  echo "  2) Miroir : la destination suit oCIS (fichiers supprimes gardes dans une corbeille)"
  read -r -p "Choix [1] : " c
  if [ "${c:-1}" = 2 ]; then mode=miroir; read -r -p "Jours de corbeille [30] : " ret; ret="${ret:-30}"; fi
  read -r -p "Horaire (Entree = a la demande, ex. 02:30 ou 02:30/7) : " sched; sched="${sched:-manuel}"
  read -r -p "Nom du transfert : " nom
  ( tr_api_save nouveau "$nom" "${line%%|*}" "${sub:--}" "$dest" "$mode" "$ret" "$sched" ) || true
  oc_pause
}

tr_main() {
  OC_TAG=ocis-transferts
  tr_init
  case "${1:-}" in
    _worker)   tr_worker; exit ;;
    espaces)   load_conf || die "connexion oCIS non configuree."; list_spaces tous || { echo "HTTP $HTTP"; http_hint "$HTTP"; exit 2; }; printf '%s\n' "${SPACES[@]}"; exit ;;
    parcourir) [ -n "${2:-}" ] || die "usage : transferts parcourir <ESPACE_ID> [CHEMIN]"; tr_browse "$2" "${3:-}"; exit ;;
    save)      shift 1; tr_api_save "$@"; exit ;;
    supprimer) tr_api_delete "${2:-}"; exit ;;
    lancer)    tr_api_launch "${2:-}"; exit ;;
    arreter)   tr_api_stop; exit ;;
    run-at)    [[ "${2:-}" =~ ^[0-9]{2}:[0-9]{2}$ ]] || die "usage : transferts run-at HH:MM"; tr_run_at "$2"; exit ;;
    gen-cron)  tr_gen_cron; exit ;;
    suivi)     tr_follow; exit ;;
    liste)     tr_list; exit ;;
    "") ;;
    *) die "usage : transferts espaces | parcourir | save | supprimer | lancer | arreter | run-at | gen-cron | suivi | liste" ;;
  esac
  while true; do
    clear
    echo -e "${OC_B}===== TRANSFERTS oCIS -> $OC_NOM =====${OC_N}"
    tr_running && echo -e "${OC_J}Transfert en cours : $(tr_current)${OC_N}"
    echo; tr_list; echo
    echo "  1) Ajouter un transfert"
    echo "  2) Lancer un transfert"
    echo "  3) Suivre le transfert en cours"
    echo "  4) Arreter le transfert en cours"
    echo "  5) Historique"
    echo "  0) Quitter"
    read -r -p "Choix : " c
    case "$c" in
      1) tr_add_task ;;
      2) read -r -p "Nom du transfert : " c; ( tr_api_launch "$c" ); oc_pause ;;
      3) tr_follow; oc_pause ;;
      4) tr_api_stop; oc_pause ;;
      5) clear; tail -n 30 "$TR_HIST" 2>/dev/null || echo "Aucun transfert."; oc_pause ;;
      0|q) exit 0 ;;
    esac
  done
}
# <<< commun/ocis.sh

# =========================== Reglages ================================
# Limite de debit au format --bwlimit de rclone : « 5M », « off », ou plages horaires
# « 08:00,2M 23:00,off » (jours possibles : Mon-08:00,2M...)
valid_bw() { [ -z "$1" ] || [[ "$1" =~ ^[0-9A-Za-z:.,\ -]+$ ]]; }

reglages() {  # reglages voir | ram <profil> [Mo] [transferts] [verifs] [tampon] | debit <limite|->
  case "${1:-voir}" in
    voir)
      agent_conf_load; perf_load
      local haa=false hac=false
      [ "${HA_ACTIONS:-}" = oui ] && haa=true
      ha_actions_actif && hac=true
      printf '{"profil":"%s","mo":"%s","transferts":"%s","verifs":"%s","tampon":"%s","effectif":{"profil":"%s","mo":%s,"options":"%s"},"ram_total_mo":%s,"ram_dispo_mo":%s,"debit":"%s","ha_actions":%s,"ha_actions_actif":%s}\n' \
        "$RAM_PROFIL" "$RAM_MO" "$TRANSFERTS" "$VERIFS" "$TAMPON" "$PERF_PROFIL" "$PERF_MO" "${PERF_FLAGS[*]}" "$(ram_total_mo)" "$(ram_dispo_mo)" "${DEBIT:-}" "$haa" "$hac" ;;
    debit)
      local v="${2:-}"
      [ "$v" = - ] && v=""
      valid_bw "$v" || die "limite de debit invalide (ex. 5M, ou 08:00,2M 23:00,off)."
      [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
      if [ -n "$v" ] && command -v rclone >/dev/null; then
        # rclone valide le format (plages horaires comprises) sans rien envoyer
        local vd out; vd=$(mktemp -d)
        out=$(rclone lsf --bwlimit "$v" "$vd" 2>&1 < /dev/null); rmdir "$vd"
        if echo "$out" | grep -q -- '--bwlimit'; then die "limite refusee par rclone : $(echo "$out" | grep -- '--bwlimit' | sed 's/.*flag: //' | head -n 1)"; fi
      fi
      agent_conf_set DEBIT "$v"
      if [ -z "$v" ] || [ "$v" = off ]; then vert "Debit des sauvegardes : aucune limite commune."
      else vert "Debit des sauvegardes : $v (sauf celles qui ont leur propre limite)."; fi
      # les surveillances temps reel relisent leurs reglages a chaque envoi : rien a relancer
      ;;
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
    *) die "usage : nas-debian reglages voir | ram <profil> [Mo] [transferts] [verifs] [tampon] | debit <limite|->" ;;
  esac
}

version_json() {
  printf '{"script":"nas-debian","version":"%s","api":%s,"machine":"%s"}\n' "$SCRIPT_VERSION" "$API_VERSION" "$MACHINE"
}

# =========================== Doublons ================================
# Recherche des fichiers identiques (meme taille puis meme empreinte SHA-1) dans les
# dossiers choisis, en arriere-plan (priorite basse). Resultat dans doublons.json.
# Rien n'est supprime sans demande : « supprimer » deplace les fichiers choisis dans
# <dossier analyse>/.corbeille-doublons/<date>/ (meme disque : instantane), apres avoir
# verifie qu'une copie identique reste en place ; corbeille videe apres 30 jours.
DUP_JSON="$STATE_DIR/doublons.json"
DUP_PID="$STATE_DIR/doublons.pid"
DUP_TRASH=".corbeille-doublons"
DUP_KEEP_DAYS=30

dup_running() { local p; p=$(cat "$DUP_PID" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

dup_valid_dir() {  # dossier de donnees, chemin complet, sans ..
  [[ "$1" == /* && "$1" != *..* && "$1" != *"|"* ]] || die "dossier invalide : $1"
  [ -d "$1" ] || die "dossier introuvable : $1"
  case "$(readlink -f "$1")" in /|/etc*|/usr*|/bin*|/sbin*|/lib*|/boot*|/proc*|/sys*|/dev*|/run*|/var/lib*|/root) die "dossier systeme refuse : $1" ;; esac
}

dup_analyse() {  # dup_analyse [--min Ko] <dossier>...
  local minko=100 d
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  mkdir -p "$STATE_DIR"
  if [ "${1:-}" = --min ]; then minko="${2:-}"; shift 2; fi
  [[ "$minko" =~ ^[0-9]+$ ]] || die "taille minimale invalide (en Ko)."
  [ $# -gt 0 ] || die "usage : nas-debian doublons analyser [--min Ko] <DOSSIER>..."
  for d in "$@"; do dup_valid_dir "$d"; done
  dup_running && die "une analyse est deja en cours (nas-debian doublons arreter)."
  rm -f "$DUP_JSON"
  dup_py > "$STATE_DIR/doublons.py"
  local -a io=(); command -v ionice >/dev/null && io=(ionice -c3)
  nohup setsid nice -n 19 "${io[@]}" python3 "$STATE_DIR/doublons.py" "$DUP_JSON" "$minko" "$@" > /dev/null 2>&1 < /dev/null &
  echo $! > "$DUP_PID"
  sleep 1
  vert "Analyse des doublons lancee en arriere-plan ($* ; fichiers de plus de $minko Ko)."
}

dup_py() {
  cat <<'PYDUP'
import hashlib, json, os, sys, time
out, min_kb, roots = sys.argv[1], int(sys.argv[2]), [os.path.realpath(r) for r in sys.argv[3:]]
SKIP = {"@eaDir", "#recycle", "#snapshot", ".corbeille-doublons", ".SynologyWorkingDirectory", "lost+found"}
st = {"etat": "en_cours", "etape": "liste", "debut": int(time.time()), "dossiers": roots, "min_ko": min_kb,
      "fichiers_vus": 0, "octets_vus": 0, "pct": 0, "pid": os.getpid()}
last = [0.0]
def save(force=False):
    now = time.time()
    if not force and now - last[0] < 2:
        return
    last[0] = now
    with open(out + ".tmp", "w") as f:
        json.dump(st, f, ensure_ascii=False)
    os.replace(out + ".tmp", out)
try:
    save(True)
    by_size, seen = {}, set()
    for r in roots:
        for root, dirs, files in os.walk(r):
            dirs[:] = [d for d in dirs if d not in SKIP and not d.startswith(".Trash-") and not d.startswith(".corbeille")]
            for f in files:
                p = os.path.join(root, f)
                try:
                    s = os.lstat(p)
                except OSError:
                    continue
                if not os.path.isfile(p) or os.path.islink(p) or s.st_size < min_kb * 1024:
                    continue
                key = (s.st_dev, s.st_ino)
                if key in seen:          # lien physique : un seul fichier
                    continue
                seen.add(key)
                st["fichiers_vus"] += 1; st["octets_vus"] += s.st_size
                by_size.setdefault(s.st_size, []).append((p, int(s.st_mtime)))
                save()
    cands = {k: v for k, v in by_size.items() if len(v) > 1}
    total = sum(k * len(v) for k, v in cands.items()) or 1
    done = 0
    st["etape"] = "empreintes"; st["candidats"] = sum(len(v) for v in cands.values()); save(True)
    def h(p, limit=None):
        x = hashlib.sha1()
        with open(p, "rb") as f:
            n = 0
            while True:
                c = f.read(1 << 20 if limit is None else min(65536, limit - n))
                if not c:
                    break
                x.update(c); n += len(c)
                if limit is not None and n >= limit:
                    break
        return x.hexdigest()
    groups = []
    for size, files in sorted(cands.items(), reverse=True):
        part = {}
        for p, m in files:
            try:
                part.setdefault(h(p, 65536), []).append((p, m))
            except OSError:
                pass
        for lst in part.values():
            if len(lst) < 2:
                done += size * len(lst); continue
            full = {}
            for p, m in lst:
                try:
                    full.setdefault(h(p) if size > 65536 else "", []).append((p, m))
                except OSError:
                    pass
                done += size
                st["pct"] = min(99, int(done * 100 / total)); save()
            for k, g in full.items():
                if len(g) > 1:
                    g.sort(key=lambda x: (x[1], len(x[0]), x[0]))
                    groups.append({"taille": size, "empreinte": k or "petit", "fichiers": [{"chemin": p, "date": m} for p, m in g]})
    groups.sort(key=lambda g: -g["taille"] * (len(g["fichiers"]) - 1))
    st.update({"etat": "fini", "fin": int(time.time()), "pct": 100, "groupes": groups,
               "nb_groupes": len(groups), "fichiers_en_trop": sum(len(g["fichiers"]) - 1 for g in groups),
               "recuperable": sum(g["taille"] * (len(g["fichiers"]) - 1) for g in groups)})
    save(True)
except Exception as e:
    st.update({"etat": "erreur", "erreur": str(e)[:300], "fin": int(time.time())})
    save(True)
PYDUP
}

dup_trash_info() {  # JSON : contenu des corbeilles des doublons
  python3 - "$DUP_TRASH" "$@" <<'PYT'
import json, os, sys
name, roots = sys.argv[1], sys.argv[2:]
n = b = 0; dates = []
for r in roots:
    t = os.path.join(r, name)
    if not os.path.isdir(t):
        continue
    for d in os.listdir(t):
        dates.append(d)
        for root, _, files in os.walk(os.path.join(t, d)):
            for f in files:
                try:
                    b += os.lstat(os.path.join(root, f)).st_size; n += 1
                except OSError:
                    pass
print(json.dumps({"fichiers": n, "octets": b, "dates": sorted(set(dates))}))
PYT
}

dup_roots() {  # dossiers de la derniere analyse
  python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1])).get("dossiers", [])))' "$DUP_JSON" 2>/dev/null
}

dup_etat() {  # resume (sans la liste des groupes) + corbeille
  local -a roots=(); mapfile -t roots < <(dup_roots)
  local tr; tr=$(dup_trash_info "${roots[@]}")
  local run=false; dup_running && run=true
  python3 - "$DUP_JSON" "$run" "$tr" "${1:-0}" <<'PYV'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    d = {"etat": "aucune"}
if d.get("etat") == "en_cours" and sys.argv[2] != "true":
    d["etat"] = "interrompue"
n = int(sys.argv[4])
g = d.pop("groupes", [])
if n > 0:
    d["groupes"] = g[:n]
d["corbeille"] = json.loads(sys.argv[3])
print(json.dumps(d, ensure_ascii=False))
PYV
}

dup_supprimer() {  # chemins sur l'entree standard, un par ligne
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  dup_running && die "analyse en cours : attends la fin."
  [ -f "$DUP_JSON" ] || die "aucune analyse : lance d'abord nas-debian doublons analyser."
  local list; list=$(mktemp)
  cat > "$list"
  python3 - "$DUP_JSON" "$list" "$DUP_TRASH" "$(date +%Y-%m-%d_%H%M%S)" <<'PYS'
import hashlib, json, os, shutil, sys
data, lst, trash, stamp = sys.argv[1:5]
d = json.load(open(data))
roots = [os.path.realpath(r) for r in d.get("dossiers", [])]
want = {l.rstrip("\n") for l in open(lst) if l.strip()}
def sha(p):
    x = hashlib.sha1()
    with open(p, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            x.update(c)
    return x.hexdigest()
moved = skipped = 0; freed = 0; msgs = []
for g in d.get("groupes", []):
    files = [f["chemin"] for f in g["fichiers"]]
    chosen = [p for p in files if p in want]
    if not chosen:
        continue
    keep = [p for p in files if p not in want and os.path.isfile(p)]
    if not keep:
        msgs.append("groupe de %s : au moins une copie doit rester, rien deplace" % os.path.basename(files[0])); skipped += len(chosen); continue
    try:
        ref = sha(keep[0]) if g["taille"] > 0 else None
    except OSError:
        skipped += len(chosen); continue
    for p in chosen:
        rp = os.path.realpath(p)
        root = next((r for r in roots if rp.startswith(r + os.sep)), None)
        if root is None or not os.path.isfile(p) or os.path.islink(p):
            skipped += 1; continue
        try:
            if os.path.getsize(p) != g["taille"] or sha(p) != ref:
                msgs.append("%s : modifie depuis l'analyse, garde" % p); skipped += 1; continue
            dst = os.path.join(root, trash, stamp, os.path.relpath(rp, root))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.move(p, dst)
            moved += 1; freed += g["taille"]
        except OSError as e:
            msgs.append("%s : %s" % (p, e)); skipped += 1
    g["fichiers"] = [f for f in g["fichiers"] if os.path.isfile(f["chemin"])]
d["groupes"] = [g for g in d.get("groupes", []) if len(g["fichiers"]) > 1]
d["nb_groupes"] = len(d["groupes"])
d["fichiers_en_trop"] = sum(len(g["fichiers"]) - 1 for g in d["groupes"])
d["recuperable"] = sum(g["taille"] * (len(g["fichiers"]) - 1) for g in d["groupes"])
json.dump(d, open(data + ".tmp", "w"), ensure_ascii=False); os.replace(data + ".tmp", data)
for m in msgs[:20]:
    print(m)
print("%d fichier(s) deplace(s) dans %s/%s (%.1f Mo), %d garde(s)." % (moved, trash, stamp, freed / 1048576, skipped))
sys.exit(0 if moved or not skipped else 1)
PYS
  local rc=$?
  rm -f "$list"
  [ $rc -eq 0 ] && logl "doublons : fichiers deplaces dans la corbeille des doublons"
  return $rc
}

dup_purge() {  # dup_purge [jours] : corbeilles des doublons plus vieilles que X jours (0 = tout)
  local days="${1:-$DUP_KEEP_DAYS}" r t d lim
  lim=$(date -d "-$days days" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    t="$r/$DUP_TRASH"; [ -d "$t" ] || continue
    for d in "$t"/*; do
      [ -d "$d" ] || continue
      if [ "$days" -eq 0 ] || [[ "$(basename "$d" | cut -c1-10)" < "$lim" ]]; then rm -rf -- "$d"; fi
    done
    rmdir "$t" 2>/dev/null || true
  done < <(dup_roots)
  return 0
}

doublons_main() {
  case "${1:-etat}" in
    analyser)  shift; dup_analyse "$@" ;;
    etat)      dup_etat 0 ;;
    voir)      dup_etat "${2:-300}" ;;
    arreter)   if dup_running; then kill "$(cat "$DUP_PID")" 2>/dev/null; rm -f "$DUP_PID" "$DUP_JSON"; vert "Analyse arretee."; else jaune "Aucune analyse en cours."; fi ;;
    supprimer) dup_supprimer ;;
    vider)     [ "$(id -u)" -eq 0 ] || die "lance ce script en root."; dup_purge 0; vert "Corbeille des doublons videe." ;;
    purger)    dup_purge "${2:-$DUP_KEEP_DAYS}" ;;
    *) die "usage : nas-debian doublons analyser [--min Ko] <DOSSIER>... | etat | voir [N] | arreter | supprimer (chemins sur l'entree standard) | vider" ;;
  esac
}

# =========================== Estimation (premiere sauvegarde) =========
# Volume a envoyer (taille de la source, memes exclusions que les sauvegardes) et duree
# estimee selon le debit reel vers la destination : moyenne des sauvegardes deja faites
# vers elle, sinon envoi d'un fichier de test de 16 Mo ; la limite de debit compte.
estimer() {  # estimer <NOM> | <SOURCE> <DESTINATION> [oui|non]
  need_root_rclone
  local src dest enc bw="" name=""
  if [ -n "${1:-}" ] && [ -z "${2:-}" ]; then
    nb_init
    job_get "$1" || die "sauvegarde '$1' introuvable."
    name="$1"; src="$J_SRC"; job_dests; dest="${JD_R[0]}"; enc="${JD_E[0]}"
    perf_load "$J_PERF"; bw=$(bw_of "${J_BW:-}")
  else
    src="${1%/}"; dest="${2:-$GDRIVE}"; enc="${3:-oui}"
    perf_load; bw=$(bw_of "")
  fi
  [ -d "$src" ] || die "dossier source introuvable : $src"
  remote_exists "$dest" || die "destination introuvable : $dest"
  local test_bps="" tmp t0 t1 r
  # debit deja connu (sauvegardes vers cette destination) ?
  r=$(python3 - "$STATE_DIR/historique.jsonl" "$dest" <<'PYH' 2>/dev/null
import json, sys
vol = dur = 0
try:
    for l in open(sys.argv[1]):
        try:
            d = json.loads(l)
        except ValueError:
            continue
        for x in d.get("destinations") or []:
            if x.get("destination") == sys.argv[2] and x.get("code") == 0 and x.get("volume_octets", 0) >= 50e6 and x.get("fin", 0) - x.get("debut", 0) >= 60:
                vol += x["volume_octets"]; dur += x["fin"] - x["debut"]
except OSError:
    pass
print(int(vol / dur) if dur else 0)
PYH
)
  if [ "${r:-0}" -gt 0 ]; then
    test_bps="$r historique"
  else
    dest_ready "$dest" >/dev/null || die "destination non prete : $(dest_ready "$dest")"
    tmp=$(mktemp); head -c 16777216 /dev/urandom > "$tmp"
    local target; target="$(crypt_of "$dest")"
    { [ "$enc" = oui ] && remote_exists "$target"; } || target="$dest"
    t0=$(date +%s%N)
    if timeout 600 rclone copyto "$tmp" "$target:.nas-manager-test-debit" ${bw:+--bwlimit "$bw"} --retries 1 < /dev/null >/dev/null 2>&1; then
      t1=$(date +%s%N)
      test_bps="$(( 16777216 * 1000000000 / ( (t1 - t0) > 0 ? (t1 - t0) : 1 ) )) test"
      timeout 120 rclone deletefile "$target:.nas-manager-test-debit" < /dev/null >/dev/null 2>&1
    fi
    rm -f "$tmp"
  fi
  python3 - "$src" "${test_bps:-0 aucune}" "$bw" "$name" "$dest" <<'PYE'
import json, os, re, sys, fnmatch
src, mes, bw, name, dest = sys.argv[1:6]
bps, methode = mes.split()
bps = int(bps)
EXCL = ("@eaDir", "#recycle", ".corbeille-doublons")
n = b = 0
for root, dirs, files in os.walk(src):
    dirs[:] = [d for d in dirs if d not in EXCL and not d.startswith(".Trash-")]
    for f in files:
        try:
            st = os.lstat(os.path.join(root, f))
        except OSError:
            continue
        if os.path.isfile(os.path.join(root, f)) and not os.path.islink(os.path.join(root, f)):
            n += 1; b += st.st_size
def rate(v):
    """'2M' -> octets/s ; 'off' -> None"""
    v = v.strip().split(":")[0]
    if v in ("off", ""):
        return None
    m = re.match(r"^([\d.]+)([BKMGT]?)$", v, re.I)
    if not m:
        return None
    mult = {"": 1024, "B": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}[m.group(2).upper()]
    return float(m.group(1)) * mult
# debit moyen sur 24 h avec la limite (plages horaires : moyenne ponderee)
eff = bps
if bw and bps:
    parts = bw.split()
    if len(parts) == 1 and "," not in parts[0]:
        r = rate(parts[0]); eff = min(bps, r) if r else bps
    else:
        slots = []
        for p in parts:
            t, _, v = p.partition(",")
            t = t.split("-")[-1]
            try:
                h, m = t.split(":"); slots.append((int(h) * 60 + int(m), rate(v)))
            except ValueError:
                pass
        slots.sort()
        if slots:
            tot = 0.0
            for i, (t, r) in enumerate(slots):
                nxt = slots[(i + 1) % len(slots)][0] + (1440 if i + 1 == len(slots) else 0)
                tot += (nxt - t) * (min(bps, r) if r else bps)
            # avant la premiere plage : limite de la derniere (cycle sur 24 h)
            eff = tot / 1440
dur = int(b / eff) + n // 50 if eff else None
print(json.dumps({"nom": name, "source": src, "destination": dest, "fichiers": n, "octets": b,
                  "debit_mesure": bps, "methode": methode, "limite": bw, "debit_effectif": int(eff or 0),
                  "duree_s": dur}, ensure_ascii=False))
PYE
}

# >>> commun/tui.sh (copie generee par maj-versions-scripts.py : modifier commun/tui.sh)
# shellcheck shell=bash
# =====================================================================
#  commun/tui.sh : interface texte de NAS Manager (nas-manager), partage par
#  nas-synology et nas-debian. Binaire unique (amd64, arm64, armv7) publie avec chaque
#  version de l'application sur GitHub ; empreinte SHA-256 verifiee avant installation.
#  Ce bloc est recopie tel quel dans les deux scripts par maj-versions-scripts.py :
#  le modifier dans commun/tui.sh, puis relancer python3 maj-versions-scripts.py.
#  A fournir par le script qui l'inclut : BIN_DIR, die.
# =====================================================================
TUI_BIN="$BIN_DIR/nas-manager"
tui_ok() { echo -e "\e[32m$*\e[0m"; }
TUI_URL="${NAS_TUI_URL:-https://github.com/cmathias27/scripts_claude/releases/latest/download}"

tui_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo aarch64 ;;
    armv7*|armv8l) echo armv7 ;;
    *) return 1 ;;
  esac
}

tui_version() { [ -x "$TUI_BIN" ] && "$TUI_BIN" --version 2>/dev/null | awk '{print $NF; exit}'; }

tui_etat() {
  local a v
  a=$(tui_arch || echo inconnue); v=$(tui_version || true)
  printf '{"installe":%s,"version":"%s","architecture":"%s","commande":"%s"}\n' \
    "$( [ -n "$v" ] && echo true || echo false)" "$v" "$a" "$TUI_BIN"
}

tui_installer() {
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  command -v curl >/dev/null || die "curl est necessaire."
  local a tmp sum got
  a=$(tui_arch) || die "architecture non prise en charge : $(uname -m)"
  tmp=$(mktemp -d)
  echo "== Telechargement de nas-manager ($a)"
  curl -fsSL --retry 2 -o "$tmp/nas-manager" "$TUI_URL/nas-manager-tui-$a" || { rm -rf "$tmp"; die "telechargement impossible ($TUI_URL)."; }
  curl -fsSL --retry 2 -o "$tmp/sha256" "$TUI_URL/nas-manager-tui-$a.sha256" || { rm -rf "$tmp"; die "empreinte introuvable."; }
  sum=$(awk '{print $1; exit}' "$tmp/sha256")
  got=$(sha256sum "$tmp/nas-manager" | awk '{print $1}')
  [ -n "$sum" ] && [ "$sum" = "$got" ] || { rm -rf "$tmp"; die "empreinte incorrecte : fichier refuse."; }
  chmod 755 "$tmp/nas-manager"
  "$tmp/nas-manager" --version >/dev/null 2>&1 || { rm -rf "$tmp"; die "le programme telecharge ne se lance pas sur cette machine."; }
  mv -f "$tmp/nas-manager" "$TUI_BIN"
  rm -rf "$tmp"
  tui_ok "nas-manager $(tui_version) installe : lance « nas-manager » dans un terminal SSH (sudo sur le Synology)."
}

tui_main() {
  case "${1:-etat}" in
    etat)      tui_etat ;;
    installer) tui_installer ;;
    supprimer) [ "$(id -u)" -eq 0 ] || die "lance ce script en root."; rm -f "$TUI_BIN"; tui_ok "nas-manager retire." ;;
    *) die "usage : tui etat | installer | supprimer" ;;
  esac
}
# <<< commun/tui.sh

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
    estimer)   shift; estimer "$@" ;;
    doublons)  shift; doublons_main "$@" ;;
    tui)       shift; tui_main "$@" ;;
    ha-actions) shift; ha_actions_main "$@" ;;
    racines)   data_roots ;;
    dossiers)  data_dirs ;;
    migrer)    migrer "${2:-simulation}" ;;
    alertes)   shift; [ "$(id -u)" -eq 0 ] || die "lance ce script en root."; alertes_main "$@" ;;
    suivi)
      case "${2:-}" in
        configurer) suivi_configurer "${3:-}" ;;
        actions)    ha_actions_set "${3:-}" ;;
        *) die "usage : nas-debian suivi configurer <serveur MQTT> | actions <oui|non>" ;;
      esac ;;
    notify)    shift; notify_cmd "$@" ;;
    check)     check_cmd ;;
    ha-status) ha_status_cmd ;;
    temps-reel) shift; temps_reel_main "$@" ;;
    destinations) shift; destinations_main "$@" ;;
    disques)   shift; disques_main "$@" ;;
    rapport)   shift; rapport_main "$@" ;;
    versions)  shift; need_rclone; versions_main "$@" ;;
    test-restauration) shift; nb_init; test_main "$@" ;;
    date)      shift; nb_init; date_main "$@" ;;
    reveil)    shift; reveil_main "$@" ;;
    migration) shift; mg_main "$@" ;;
    transferts) shift; tr_main "$@" ;;
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
