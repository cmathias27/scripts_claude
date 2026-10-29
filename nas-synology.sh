#!/bin/bash
# =====================================================================
#  nas-synology : script unique du NAS Synology (DSM 7)
#
#  Regroupe :
#    copie-omv         copie (ou deplacement) d'un dossier du Synology vers
#                      l'OMV / la machine Debian, avec suivi en direct (rsync)
#    migre-drive-ocis  migration des « Mon Drive » Synology vers oCIS
#  Ces anciens noms restent utilisables : ce sont des liens vers ce script,
#  qui reconnait sous quel nom il est lance.
#
#  Lancement (SSH sur le Synology) :  sudo bash nas-synology.sh   (menu)
#  Commandes :
#    copie <commande>       commandes de copie-omv (lancer, ajouter, retirer,
#                           lancer-file, arreter, suivi, stop)
#    migration <commande>   commandes de migre-drive-ocis (espaces, sources,
#                           ajouter, retirer, lancer, arreter, configurer,
#                           suivi, stop, jeton)
#    transferts <commande>  transferts oCIS -> Synology, ponctuels ou programmes
#                           (espaces, parcourir, save, supprimer, lancer, arreter,
#                           run-at, gen-cron, suivi, liste)
#    version                version du script (JSON)
#    tui etat | installer | supprimer   interface texte NAS Manager (nas-manager)
#    installer              liens copie-omv / migre-drive-ocis
#    outils etat | installer | rclone-maj
#    reglages voir | ram <auto|econome|equilibre|performant> [Mo] [transferts] [verifs]
#             | omv <adresse> | ha <adresse> <webhook> | omv-reveil <MAC|-> [rien|veille|arret]
#    reveil <MAC> [adresse]           envoi d'un paquet de reveil (Wake-on-LAN)
#    migrer simulation | appliquer   reprise d'une installation avec les anciens scripts
#    disques verifier | etat         sante des disques (SMART) et du RAID, alertes
# =====================================================================
set -o pipefail

SCRIPT_VERSION="2.5.0"
API_VERSION=7

# --------------------------- Reglages --------------------------------
# Valeurs par defaut, modifiables avec « nas-synology reglages » (fichier SYNO_CONF)
OMV_HOST="192.168.1.190"          # adresse de l'OMV / de la machine Debian (copie)
OMV_USER="root"
OMV_ROOT="/srv"                   # point de depart pour choisir la destination
OMV_MAC=""                        # adresse MAC de l'OMV : reveil (Wake-on-LAN) avant les copies
OMV_APRES="rien"                  # apres les copies, si l'OMV a ete reveille : rien, veille ou arret
HA_HOST="192.168.1.222"           # Home Assistant (notification de fin), vide = pas de notification
HA_WEBHOOK="nas-c09f382daf2d01deb430abbd"
AUTO_REPRISE=5                    # migration : relances automatiques si rclone s'arrete
VERIF_RENVOIS=3                   # migration : renvois forces des fichiers en defaut au controle
DEFAULT_LOCAL="https://192.168.1.53:9200"   # oCIS sur l'hote Docker, en direct (sans Cloudflare)
# ---------------------------------------------------------------------

SELF=$(readlink -f "$0")
BIN_DIR="/usr/local/bin"
SYNO_DIR="/root/.nas-synology"
SYNO_CONF="$SYNO_DIR/config"
AGENT_CONF="$SYNO_DIR/agent.conf"
OLD_DIR="/root/.nas-manager/ancien"
LEGACY_NAMES=(copie-omv migre-drive-ocis)
NOTIFY_TAG=nas-synology
# shellcheck disable=SC1090
[ -f "$SYNO_CONF" ] && . "$SYNO_CONF"

# copie vers l'OMV
CP_STATE="/root/.copie-omv"
CP_KEY="/root/.ssh/id_copie_omv"
CP_RUN="$CP_STATE/en-cours"
CP_LOGF="$CP_STATE/progression.log"
CP_HIST="$CP_STATE/historique.log"
CP_QUEUE="$CP_STATE/file-attente"
CP_SSH_OPTS=(-i "$CP_KEY" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
CP_EXCL=(--exclude '@eaDir/' --exclude '#recycle/' --exclude '#snapshot/' --exclude '.DS_Store' --exclude 'Thumbs.db' --exclude '@SynoResource')
# Filtre de la sortie de rsync (liste incrementale : la copie demarre tout de suite).
# Le % de rsync ne porte que sur la partie de la liste deja parcourue et ignore les
# fichiers deja presents sur l'OMV (reprise) : il est recalcule ici sur la taille
# mesuree de la source (tot), en ajoutant les fichiers deja a jour (lignes CPI|.f).
# Les lignes CPI| (une par fichier) ne vont pas dans le journal.
CP_AWK='
function nb(s,  m, c) {
  m = 1; c = substr(s, length(s), 1)
  if (c ~ /[kKMGTP]/) { m = (c ~ /[kK]/) ? 1e3 : (c == "M") ? 1e6 : (c == "G") ? 1e9 : (c == "T") ? 1e12 : 1e15; s = substr(s, 1, length(s) - 1) }
  else gsub(/[,.]/, "", s)   # octets exacts avec separateurs de milliers
  gsub(/,/, "", s); return s * m
}
function hum(b,  i, u) {
  split("K M G T", u); i = 0
  while (b >= 1024 && i < 4) { b /= 1024; i++ }
  return i ? sprintf("%.2f%s", b, u[i]) : sprintf("%d", b)
}
function hms(s) { s = int(s); return sprintf("%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
BEGIN { RS = "\r"; deja = 0 }
{
  n = split($0, L, "\n")
  for (k = 1; k <= n; k++) {
    l = L[k]
    if (l ~ /^CPI\|/) {
      split(l, f, "|"); if (f[2] ~ /^\.f/) { s = f[3]; gsub(/[^0-9]/, "", s); deja += s }
      continue
    }
    if (l ~ /^ *[0-9][0-9.,]*[kKMGTP]? +[0-9]+% / && tot > 0) {
      split(l, f, " "); v = f[3]; sub(/B\/s$/, "", v)
      fait = deja + nb(f[1]); vit = nb(v)
      pct = (fait >= tot) ? 100 : int(fait * 100 / tot); if (pct > 99 && fait < tot) pct = 99
      eta = (fait >= tot) ? "0:00:00" : (vit > 0) ? hms((tot - fait) / vit) : f[4]
      printf "%14s %3d%% %13s %10s\r", hum(fait), pct, f[3], eta; fflush()
      continue
    }
    if (l != "") { print l; fflush() }
  }
}'

# rclone telecharge par le script (pas d'apt sur DSM)
MG_BIN="/root/.migre-ocis/bin"
export PATH="$MG_BIN:$PATH"

B="\e[1m"; V="\e[32m"; J="\e[33m"; R="\e[31m"; G="\e[90m"; N="\e[0m"
die()  { echo -e "${R}ERREUR : $*${N}"; exit 1; }
hsize() { awk -v b="$1" 'BEGIN{split("o Ko Mo Go To",u);i=1;while(b>=1024&&i<5){b/=1024;i++};printf (i==1?"%d %s":"%.1f %s"),b,u[i]}'; }
pause() { read -r -p "Entree pour continuer..." _; }
safe()  { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }
osh() { ssh "${CP_SSH_OPTS[@]}" "$OMV_USER@$OMV_HOST" "$@"; }
q()   { printf '%q' "$1"; }
mem_info() {
  awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
       END{printf "RAM disponible %d / %d Mo, swap utilise %d Mo", a/1024, t/1024, (st-sf)/1024}' /proc/meminfo
}
need_root() { [ "$(id -u)" -eq 0 ] || die "lance le script avec sudo :  sudo bash $SELF"; }

# Notification Home Assistant : notify <critique|info> <titre> <message>
notify() {
  [ -n "$HA_HOST" ] || return 0
  local body u
  body=$(python3 -c 'import json,sys; print(json.dumps({"title":sys.argv[1],"message":sys.argv[2],"tag":sys.argv[3]}))' "$2" "$3" "$NOTIFY_TAG" 2>/dev/null) || return 0
  for u in "http://$HA_HOST:8123" "http://$HA_HOST"; do
    curl -s -m 8 -o /dev/null -f -X POST -H 'Content-Type: application/json' -d "$body" "$u/api/webhook/${HA_WEBHOOK}-$1" && return 0
  done
  return 0
}

# =========================== Memoire de rclone =======================
# agent.conf : RAM_PROFIL (auto|econome|equilibre|performant), RAM_MO, TRANSFERTS, VERIFS
# Sur le Synology « auto » = equilibre (2 fichiers a la fois, 1/5 de la RAM entre 128 et 512 Mo).
ram_total_mo() { awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 2000; }
ram_dispo_mo() { awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0; }
agent_conf_load() {
  RAM_PROFIL=auto RAM_MO="" TRANSFERTS="" VERIFS=""
  # shellcheck disable=SC1090
  [ -f "$AGENT_CONF" ] && . "$AGENT_CONF"
  return 0
}
perf_load() {  # -> PERF_PROFIL, PERF_MO, PERF_MEM, PERF_T, PERF_C
  agent_conf_load
  local prof="$RAM_PROFIL" mo="$RAM_MO" tot div lo hi
  tot=$(ram_total_mo)
  [ "$prof" = auto ] || [ -z "$prof" ] && prof=equilibre
  case "$prof" in
    econome)    PERF_T=1; PERF_C=2; div=8; lo=96;  hi=256 ;;
    performant) PERF_T=4; PERF_C=8; div=3; lo=256; hi=2048 ;;
    *)          prof=equilibre; PERF_T=2; PERF_C=4; div=5; lo=128; hi=512 ;;
  esac
  if [ -z "$mo" ]; then mo=$(( tot / div )); [ "$mo" -gt "$hi" ] && mo=$hi; [ "$mo" -lt "$lo" ] && mo=$lo; fi
  [ "$mo" -lt 64 ] && mo=64
  [[ "${TRANSFERTS:-}" =~ ^[0-9]+$ ]] && PERF_T=$TRANSFERTS
  [[ "${VERIFS:-}" =~ ^[0-9]+$ ]] && PERF_C=$VERIFS
  PERF_PROFIL="$prof"; PERF_MO="$mo"; PERF_MEM="${mo}MiB"
}

# =========================== Copie vers l'OMV ========================
# --------------------------- Reveil de l'OMV (Wake-on-LAN) ----------
# Paquet magique (UDP 9 et 7) : diffusion generale et diffusion de chaque reseau du NAS
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

# L'OMV accepte-t-il les connexions SSH ? (« refusee » = allume)
omv_up() {
  python3 - "$OMV_HOST" <<'PYUP'
import errno, socket, sys
try:
    s = socket.create_connection((sys.argv[1], 22), timeout=3)
    s.close()
except ConnectionRefusedError:
    pass
except OSError:
    sys.exit(1)
PYUP
}

# Reveille l'OMV s'il ne repond pas (adresse MAC reglee) -> 0 s'il repond
omv_wake() {
  [ -n "$OMV_MAC" ] || return 0
  omv_up && return 0
  local i t0; t0=$(date +%s)
  echo "L'OMV ne repond pas : envoi du paquet de reveil ($OMV_MAC)..."
  wol_send "$OMV_MAC" "$OMV_HOST" || true
  for ((i = 1; i <= 36; i++)); do
    sleep 5
    if omv_up; then
      sleep "${REVEIL_DEMARRAGE:-15}"   # services encore en demarrage
      date +%s > "$CP_STATE/omv-reveille"
      echo "OMV reveille en $(( $(date +%s) - t0 )) s."
      return 0
    fi
    [ $((i % 6)) -eq 0 ] && { wol_send "$OMV_MAC" "$OMV_HOST" || true; }
  done
  echo "L'OMV ne repond pas apres 3 minutes (Wake-on-LAN active dans son BIOS ? adresse MAC correcte ?)."
  return 1
}

# Apres les copies : remise en veille (ou arret) de l'OMV si c'est nous qui l'avons reveille
omv_rest() {
  [ -f "$CP_STATE/omv-reveille" ] || return 0
  rm -f "$CP_STATE/omv-reveille"
  local cmd
  case "$OMV_APRES" in
    veille) cmd='systemctl suspend 2>/dev/null || pm-suspend 2>/dev/null || echo mem > /sys/power/state' ;;
    arret)  cmd='systemctl poweroff 2>/dev/null || poweroff' ;;
    *) return 0 ;;
  esac
  timeout 30 ssh "${CP_SSH_OPTS[@]}" "$OMV_USER@$OMV_HOST" "$cmd" >/dev/null 2>&1 < /dev/null &
  return 0
}

# --------------------------- Cle SSH vers l'OMV ----------------------
cp_ensure_ssh() {
  omv_wake || die "l'OMV ne repond pas."
  [ -f "$CP_KEY" ] || ssh-keygen -t ed25519 -N "" -C "copie-omv@$(hostname)" -f "$CP_KEY" -q
  if ! osh true 2>/dev/null; then
    echo -e "${J}Premiere connexion a l'OMV : autorisation de la cle SSH du NAS.${N}"
    echo "Tape le mot de passe de $OMV_USER sur l'OMV (une seule fois) :"
    ssh -o StrictHostKeyChecking=accept-new "$OMV_USER@$OMV_HOST" \
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" < "$CP_KEY.pub" \
      || die "connexion a l'OMV impossible ($OMV_USER@$OMV_HOST)."
    osh true 2>/dev/null || die "la cle SSH n'est pas acceptee par l'OMV."
    echo -e "${V}OK : connexion automatique a l'OMV configuree.${N}"
  fi
  osh "command -v rsync >/dev/null" || {
    echo "Installation de rsync sur l'OMV..."
    osh "apt-get install -y -qq rsync >/dev/null" || die "rsync manquant sur l'OMV."
  }
}

# --------------------------- Navigateur de dossiers ------------------
# cp_browse <local|omv> <dossier de depart> <titre>  -> CHOIX
cp_browse() {
  local where="$1" cur="$2" title="$3" c i
  local -a dirs=()
  while true; do
    if [ "$where" = local ]; then
      if [ "$cur" = "/" ]; then
        mapfile -t dirs < <(ls -d /volume[0-9]*/*/ 2>/dev/null | sed 's#/$##' | grep -v -E '/(@|#)')
      else
        mapfile -t dirs < <(find "$cur" -mindepth 1 -maxdepth 1 -type d ! -name '@*' ! -name '#*' ! -name '.*' 2>/dev/null | sort)
      fi
    else
      mapfile -t dirs < <(osh "find $(q "$cur") -mindepth 1 -maxdepth 1 -type d ! -name 'lost+found' ! -name '.*' 2>/dev/null | sort")
    fi
    clear
    echo -e "${B}== $title ==${N}"
    echo -e "Dossier actuel : ${B}${cur}${N}"
    echo
    i=1
    for d in "${dirs[@]}"; do printf "  %3d) %s\n" "$i" "${d##*/}"; i=$((i+1)); done
    [ ${#dirs[@]} -eq 0 ] && echo -e "  ${G}(aucun sous-dossier)${N}"
    echo
    echo "  numero = entrer dans le dossier"
    [ "$cur" != "/" ] && echo "  v = VALIDER « ${cur##*/} »"
    [ "$where" = omv ] && echo "  n = nouveau dossier ici"
    echo "  r = remonter      q = annuler"
    read -r -p "Choix : " c
    case "$c" in
      v|V) [ "$cur" != "/" ] && { CHOIX="$cur"; return 0; } ;;
      r|R) if [ "$where" = local ] && [[ "$cur" =~ ^/volume[0-9]+/[^/]+$ ]]; then cur="/"
           elif [ "$cur" != "/" ] && [ "$cur" != "$2" ]; then cur="${cur%/*}"; [ -z "$cur" ] && cur="/"; fi ;;
      n|N) if [ "$where" = omv ]; then
             read -r -p "Nom du nouveau dossier : " nd
             [[ -n "$nd" && "$nd" != */* ]] && osh "mkdir -p $(q "$cur/$nd")" && cur="$cur/$nd"
           fi ;;
      q|Q) return 1 ;;
      *) if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#dirs[@]} ]; then cur="${dirs[$((c-1))]}"; fi ;;
    esac
  done
}

# --------------------------- Taille de la source ---------------------
# cp_measure <source>  -> total (octets) et nbf (fichiers), avec les memes exclusions
# que rsync. -prune : les dossiers exclus (miniatures @eaDir, corbeille, instantanes)
# ne sont pas parcourus du tout.
cp_measure() {
  total=$(du -sb --exclude='@eaDir' --exclude='#recycle' --exclude='#snapshot' --exclude='@SynoResource' \
    --exclude='.DS_Store' --exclude='Thumbs.db' "$1" 2>/dev/null | cut -f1)
  nbf=$(find "$1" -mindepth 1 \( -name '@eaDir' -o -name '#recycle' -o -name '#snapshot' -o -name '@SynoResource' \) -prune \
    -o -type f ! -name '.DS_Store' ! -name 'Thumbs.db' -print 2>/dev/null | wc -l)
}

# --------------------------- Etat de la copie ------------------------
cp_running() { [ -f "$CP_RUN" ] && . "$CP_RUN" && kill -0 "$PID" 2>/dev/null; }


# --------------------------- Affichage du suivi ----------------------
cp_follow() {
  cp_running || { [ -f "$CP_RUN" ] && . "$CP_RUN"; }
  [ -f "$CP_RUN" ] || { echo "Aucune copie lancee."; return; }
  . "$CP_RUN"
  trap 'echo; echo -e "${J}Suivi interrompu. La copie continue en arriere-plan.${N}"; echo "Reprendre le suivi :  sudo bash $SELF copie suivi"; exit 0' INT
  echo -e "${B}Copie : ${N}$SRC"
  echo -e "${B}Vers  : ${N}$OMV_HOST:$DST"
  echo -e "${B}Mode  : ${N}$MODE · $(hsize "$TOTAL") · $NBF fichiers"
  echo -e "${G}Ctrl+C = arreter le suivi (la copie continue)${N}"
  echo
  local line pct bar
  while kill -0 "$PID" 2>/dev/null; do
    line=$(tail -c 2000 "$CP_LOGF" 2>/dev/null | tr '\r' '\n' | grep -E '[0-9]+%' | tail -n 1)
    if [ -n "$line" ]; then
      read -r done_s pct speed eta _ <<< "$line"
      pct=${pct%\%}
      local n=$(( pct * 30 / 100 ))
      bar=$(printf '%*s' "$n" '' | tr ' ' '#')$(printf '%*s' $((30-n)) '' | tr ' ' '.')
      printf "\r [%s] %3s%%  %8s / %-9s  %10s  reste %-10s" "$bar" "$pct" "$done_s" "$(hsize "$TOTAL")" "$speed" "$eta"
    else
      printf "\r Preparation de la liste des fichiers..."
    fi
    sleep 1
  done
  echo; echo
  local rc; rc=$(cat "$CP_STATE/code" 2>/dev/null || echo "?")
  if [ "$rc" = 0 ]; then
    echo -e "${V}${B}$( [ "$MODE" = deplacement ] && echo "Deplacement" || echo "Copie") terminee avec succes.${N}"
  else
    echo -e "${R}${B}La copie s'est terminee avec une erreur (code $rc).${N}"
    echo "Dernieres lignes du journal :"
    tr '\r' '\n' < "$CP_LOGF" | grep -v -E '^\s*$|[0-9]+%' | tail -n 8
    echo -e "${J}Relancer la meme copie reprendra la ou elle s'est arretee.${N}"
  fi
  trap - INT
}

# --------------------------- Lancement (commun menu / application) ---
# cp_start_copy <source> <dossier OMV parent> <source rsync> <destination finale> <copie|deplacement> <total> <nb fichiers> [debit Ko/s]
cp_start_copy() {
  local src="$1" dst="$2" rsrc="$3" final="$4" mode="$5" total="$6" nbf="$7" bw="${8:-}"
  # Droits OMV : les fichiers prennent le proprietaire et le groupe du dossier
  # de destination (dossiers 2775, fichiers 664) au lieu des droits Synology
  local own; own=$(osh "stat -c %U:%G $(q "$dst")" 2>/dev/null); own="${own:-root:users}"
  [ "${own#*:}" = root ] && own="${own%%:*}:users"
  local -a extra=(-p "--chmod=D2775,F664" "--chown=$own")
  [ -n "$bw" ] && extra+=("--bwlimit=$bw")
  [ "$mode" = deplacement ] && extra+=(--remove-source-files)
  cat > "$CP_RUN" <<EOF
SRC=$(q "$src")
DST=$(q "$final")
MODE=$mode
TOTAL=${total:-0}
NBF=$nbf
BW=$bw
DEBUT=$(date +%s)
EOF
  : > "$CP_LOGF"; rm -f "$CP_STATE/code"

  # Copie en arriere-plan, independante de la session SSH.
  # Liste incrementale (pas de --no-inc-recursive) : rsync commence a copier sans
  # attendre d'avoir parcouru toute la source et toute la destination.
  CP_AWK="$CP_AWK" CP_TOT="${total:-0}" nohup setsid bash -c '
    rsync -rlt --partial --info=progress2 -ii --out-format="CPI|%i|%l" \
      "${@:6}" -e "ssh ${5}" "$1" "$2:$3/" 2>&1 | awk -v tot="$CP_TOT" "$CP_AWK" >>"'"$CP_LOGF"'" 2>&1
    rc=${PIPESTATUS[0]}
    echo $rc > "'"$CP_STATE/code"'"
    if [ $rc -eq 0 ] && [ "$4" = deplacement ]; then
      find "$1" -mindepth 1 -depth -type d -empty -delete 2>/dev/null
    fi
  ' _ "$rsrc" "$OMV_USER@$OMV_HOST" "$dst" "$mode" "${CP_SSH_OPTS[*]}" "${CP_EXCL[@]}" "${extra[@]}" >/dev/null 2>&1 &
  echo "PID=$!" >> "$CP_RUN"

  # Surveillance de fin (historique + notification Home Assistant),
  # independante elle aussi de la session SSH
  nohup setsid bash "$SELF" copie _fin >/dev/null 2>&1 &

  echo "Copie lancee : $src -> $OMV_HOST:$final ($mode)"
}

# --------------------------- Nouvelle copie --------------------------
cp_new_copy() {
  if cp_running; then echo -e "${J}Une copie est deja en cours.${N}"; cp_follow; return; fi
  cp_ensure_ssh

  cp_browse local "/" "Dossier a copier (NAS)" || return
  local src="$CHOIX"
  local start; start=$(osh "ls -d $OMV_ROOT/dev-disk-by-uuid-* 2>/dev/null | head -n 1"); start="${start:-$OMV_ROOT}"
  cp_browse omv "$start" "Destination sur l'OMV" || return
  local dst="$CHOIX"

  clear
  echo -e "${B}== Recapitulatif ==${N}"
  echo "Calcul de la taille..."
  local total nbf free
  cp_measure "$src"
  free=$(osh "df -B1 --output=avail $(q "$dst") | tail -n 1" | tr -d ' ')
  # Placement : dans un sous-dossier du meme nom, ou directement dans la destination
  local name="${src##*/}" pdef=1 p
  [ "${dst##*/}" = "$name" ] && pdef=2
  echo
  echo "Ou mettre le contenu de « $name » ?"
  echo "  1) Dans un dossier « $name »  ->  ${dst}/${name}/..."
  echo "  2) Directement dans « ${dst##*/} »  ->  ${dst}/..."
  [ "$pdef" = 2 ] && echo -e "  ${G}(meme nom des deux cotes : 2 evite un dossier ${name}/${name})${N}"
  read -r -p "Choix [$pdef] : " p
  local rsrc="$src" final="$dst/$name"
  if [ "${p:-$pdef}" = 2 ]; then rsrc="$src/"; final="$dst"; fi

  clear
  echo -e "${B}== Recapitulatif ==${N}"
  echo
  echo -e "  Source      : ${B}$src${N}"
  echo -e "  Destination : ${B}$OMV_HOST:$final${N}"
  if osh "[ -n \"\$(ls -A $(q "$final") 2>/dev/null)\" ]"; then
    echo -e "  ${J}La destination contient deja des fichiers : fusion (rien n'y est supprime,"
    echo -e "  les fichiers de meme nom mais differents sont remplaces par ceux du NAS).${N}"
  fi
  echo -e "  Volume      : ${B}$(hsize "$total")${N} · $nbf fichiers"
  echo -e "  Libre OMV   : $(hsize "${free:-0}")"
  if [ "${free:-0}" -lt "${total:-0}" ]; then
    echo -e "  ${R}Attention : pas assez de place sur l'OMV (deja copie compris).${N}"
  fi
  echo
  echo "  1) Copier     : les originaux restent sur le NAS"
  echo "  2) Deplacer   : les originaux sont SUPPRIMES du NAS apres copie de chaque fichier"
  read -r -p "Choix [1] : " m
  local mode=copie
  if [ "${m:-1}" = 2 ]; then
    echo -e "${R}Les fichiers de « ${src##*/} » seront effaces du NAS au fur et a mesure.${N}"
    read -r -p "Tape DEPLACER pour confirmer : " c
    [ "$c" = DEPLACER ] && mode=deplacement || { echo "Annule : ce sera une copie."; }
  fi
  read -r -p "Lancer ? [O/n] : " go
  [[ "${go:-o}" =~ ^[oOyY] ]] || return

  cp_start_copy "$src" "$dst" "$rsrc" "$final" "$mode" "${total:-0}" "$nbf" >/dev/null
  echo -e "${V}Copie lancee.${N}"; sleep 1
  cp_follow
}

cp_fix_perms() {
  cp_ensure_ssh
  local start; start=$(osh "ls -d $OMV_ROOT/dev-disk-by-uuid-* 2>/dev/null | head -n 1"); start="${start:-$OMV_ROOT}"
  cp_browse omv "$start" "Dossier dont reparer les droits (OMV)" || return
  local d="$CHOIX" g u nb
  clear
  echo -e "${B}== Reparer les droits ==${N}"
  echo -e "Dossier : ${B}$d${N}"
  echo "Etat actuel :"; osh "ls -ld $(q "$d")"
  nb=$(osh "find $(q "$d") | wc -l")
  echo
  echo "Groupe qui aura acces (OMV : 'users' = tous les utilisateurs du partage)."
  read -r -p "Groupe [users] : " g; g="${g:-users}"
  read -r -p "Proprietaire [root] : " u; u="${u:-root}"
  echo "Seront appliques sur $nb elements : proprietaire $u:$g, dossiers 2775, fichiers 664."
  read -r -p "Continuer ? [o/N] : " c
  [[ "$c" =~ ^[oOyY] ]] || return
  echo "Application en cours..."
  osh "chown -R $(q "$u:$g") $(q "$d") && find $(q "$d") -type d -exec chmod 2775 {} + && find $(q "$d") -type f -exec chmod 664 {} +" \
    && echo -e "${V}Droits repares.${N}" || echo -e "${R}Erreur pendant la reparation (groupe ou utilisateur inexistant ?).${N}"
  osh "ls -ld $(q "$d")"
}

cp_stop_copy() {
  cp_running || { echo "Aucune copie en cours."; return; }
  . "$CP_RUN"
  read -r -p "Arreter la copie de « ${SRC##*/} » ? [o/N] : " c
  [[ "$c" =~ ^[oOyY] ]] || return
  echo stop > "$CP_STATE/code.stop"
  pkill -TERM -s "$(ps -o sid= -p "$PID" | tr -d ' ')" 2>/dev/null || kill "$PID"
  sleep 1; mv -f "$CP_STATE/code.stop" "$CP_STATE/code"
  echo -e "${J}Copie arretee. La relancer reprendra la ou elle s'est arretee.${N}"
}

# --------------------------- Commandes sans question -----------------
# Utilisees par l'application Windows "NAS Manager".

cp_api_launch() {  # cp_api_launch <source NAS> <dossier OMV> <dossier|contenu> <copie|deplacement> [debit Ko/s]
  local src="${1%/}" dst="${2%/}" place="${3:-dossier}" mode="${4:-copie}" bw="${5:-}"
  [[ -z "$bw" || "$bw" =~ ^[0-9]+$ ]] || die "limite de debit invalide (Ko/s)."
  cp_running && die "une copie est deja en cours."
  [ -d "$src" ] || die "dossier source introuvable : $src"
  [[ "$mode" =~ ^(copie|deplacement)$ ]] || die "mode invalide (copie ou deplacement)."
  omv_wake || die "l'OMV ne repond pas (eteint ou en veille, et le reveil n'a pas fonctionne)."
  [ -f "$CP_KEY" ] && osh true 2>/dev/null \
    || die "la connexion automatique NAS -> OMV n'est pas configuree : autorise la cle du Synology sur l'OMV depuis NAS Manager (page Copie), ou lance une fois 'sudo bash $SELF copie' en SSH (Nouvelle copie)."
  osh "[ -d $(q "$dst") ]" || die "dossier introuvable sur l'OMV : $dst"
  osh "command -v rsync >/dev/null" || osh "apt-get install -y -qq rsync >/dev/null" || die "rsync manquant sur l'OMV."
  local rsrc="$src" final="$dst/${src##*/}"
  [ "$place" = contenu ] && { rsrc="$src/"; final="$dst"; }
  local total nbf
  cp_measure "$src"
  cp_start_copy "$src" "$dst" "$rsrc" "$final" "$mode" "${total:-0}" "$nbf" "$bw"
}

# File d'attente : copies lancees l'une apres l'autre (source|destination|placement|mode|debit)
CP_QUEUE="$CP_STATE/file-attente"

cp_api_queue_add() {  # cp_api_queue_add <source> <dossier OMV> <dossier|contenu> <copie|deplacement> [debit]
  local src="${1%/}" dst="${2%/}" place="${3:-dossier}" mode="${4:-copie}" bw="${5:-}"
  [ -d "$src" ] || die "dossier source introuvable : $src"
  [[ "$mode" =~ ^(copie|deplacement)$ && "$place" =~ ^(dossier|contenu)$ ]] || die "parametres invalides."
  [[ -z "$bw" || "$bw" =~ ^[0-9]+$ ]] || die "limite de debit invalide (Ko/s)."
  [[ "$src$dst" == *"|"* ]] && die "caractere | interdit."
  echo "$src|$dst|$place|$mode|$bw" >> "$CP_QUEUE"
  echo "Ajoute a la file d'attente : ${src##*/} -> $dst"
}

cp_api_queue_remove() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le "$(grep -c '' "$CP_QUEUE" 2>/dev/null || echo 0)" ] || die "numero invalide."
  sed -i "${1}d" "$CP_QUEUE"; echo "Retire de la file d'attente."
}

# lance la premiere copie de la file (rien si une copie tourne deja)
cp_api_queue_next() {
  cp_running && { echo "Une copie est en cours : la file continuera apres elle."; return 0; }
  [ -s "$CP_QUEUE" ] || { echo "File d'attente vide."; return 0; }
  local line s d p m b
  line=$(head -n 1 "$CP_QUEUE"); sed -i '1d' "$CP_QUEUE"
  IFS='|' read -r s d p m b <<< "$line"
  cp_api_launch "$s" "$d" "$p" "$m" "$b"
}

cp_api_stop() {
  cp_running || { echo "Aucune copie en cours."; return 0; }
  echo stop > "$CP_STATE/code.stop"
  pkill -TERM -s "$(ps -o sid= -p "$PID" | tr -d ' ')" 2>/dev/null || kill "$PID"
  sleep 1; mv -f "$CP_STATE/code.stop" "$CP_STATE/code"
  echo "Copie arretee. La relancer reprendra la ou elle s'est arretee."
}
# =========================== Migration oCIS ==========================
# =========================== rclone ==================================
ensure_rclone() {
  command -v rclone >/dev/null && return 0
  rclone_download
}

# Telecharge la version officielle de rclone dans MG_BIN (premier dans le PATH)
rclone_download() {
  local arch zip
  case "$(uname -m)" in
    x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; armv7l) arch=arm-v7 ;; *) die "architecture $(uname -m) non prise en charge." ;;
  esac
  echo "Telechargement de rclone ($arch)..."
  mkdir -p "$MG_BIN"
  zip="$MG_STATE/rclone.zip"
  curl -fsSL -o "$zip" "https://downloads.rclone.org/rclone-current-linux-$arch.zip" || die "telechargement de rclone impossible."
  python3 - "$zip" "$MG_BIN" <<'PY' || die "extraction de rclone impossible."
import sys, zipfile, os
z = zipfile.ZipFile(sys.argv[1])
for n in z.namelist():
    if n.endswith("/rclone"):
        with open(os.path.join(sys.argv[2], "rclone.new"), "wb") as f:
            f.write(z.read(n))
os.chmod(os.path.join(sys.argv[2], "rclone.new"), 0o755)
os.replace(os.path.join(sys.argv[2], "rclone.new"), os.path.join(sys.argv[2], "rclone"))
PY
  rm -f "$zip"; hash -r
  rclone version | head -n 1
}

# =========================== oCIS (code commun) ======================
# Migration vers oCIS et transferts oCIS -> Synology : code partage avec nas-debian
# (commun/ocis.sh), recopie ci-dessous. Ce que ce code attend du script :
OC_NOM="Synology"; OC_DU="du Synology"; OC_LE="le Synology"; OC_SUR="sur le Synology"
oc_notify() { NOTIFY_TAG="${OC_TAG:-$NOTIFY_TAG}" notify "$1" "$2" "$3"; }
oc_perf() { perf_load; OC_MEM="$PERF_MEM"; OC_T="$PERF_T"; OC_C="$PERF_C"; }
oc_need_rclone() { ensure_rclone; }
oc_roots() { ls -d /volume[0-9]*/*/ 2>/dev/null | sed 's#/$##' | grep -v -E '/(@|#)'; }
oc_droits() { return 0; }   # DSM : les fichiers prennent les droits (ACL) du dossier partage
# Planification des transferts : bloc dans /etc/crontab (DSM n'a pas de /etc/cron.d), puis
# redemarrage de crond. DSM peut reecrire /etc/crontab : NAS Manager remet le bloc si besoin.
OC_CRONTAB="${OC_CRONTAB:-/etc/crontab}"
oc_cron_ecrire() {  # oc_cron_ecrire <lignes cron, vide = aucune>
  local tmp; tmp=$(mktemp)
  awk '/^# >>> nas-synology transferts/{s=1; next} /^# <<< nas-synology transferts/{s=0; next} !s' "$OC_CRONTAB" > "$tmp" 2>/dev/null
  if [ -n "$1" ]; then
    { echo "# >>> nas-synology transferts (genere automatiquement, ne pas modifier)"
      printf '%s\n' "$1" | sed -E 's/^([^ ]+) ([^ ]+) ([^ ]+) ([^ ]+) ([^ ]+) ([^ ]+) /\1\t\2\t\3\t\4\t\5\t\6\t/'
      echo "# <<< nas-synology transferts"; } >> "$tmp"
  fi
  if ! cmp -s "$tmp" "$OC_CRONTAB"; then
    cat "$tmp" > "$OC_CRONTAB"
    [ "$OC_CRONTAB" = /etc/crontab ] && { systemctl restart crond 2>/dev/null || synoservicectl --restart crond 2>/dev/null || synoservice --restart crond 2>/dev/null || true; }
  fi
  rm -f "$tmp"
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

cp_main() {
  NOTIFY_TAG=copie-omv
  cp_init
# --------------------------- Point d'entree --------------------------
case "${1:-}" in
  lancer)      cp_api_launch "${2:-}" "${3:-}" "${4:-dossier}" "${5:-copie}" "${6:-}"; exit ;;
  ajouter)     cp_api_queue_add "${2:-}" "${3:-}" "${4:-dossier}" "${5:-copie}" "${6:-}"; exit ;;
  retirer)     cp_api_queue_remove "${2:-}"; exit ;;
  lancer-file) cp_api_queue_next; exit ;;
  arreter)     cp_api_stop; exit ;;
  api-version) echo "$API_VERSION"; exit ;;
esac
case "${1:-}" in
  suivi) cp_follow; exit ;;
  stop)  cp_stop_copy; exit ;;
  _fin)
    . "$CP_RUN"
    while kill -0 "$PID" 2>/dev/null; do sleep 5; done
    sleep 2
    rc=$(cat "$CP_STATE/code" 2>/dev/null || echo "?")
    echo "$(date '+%Y-%m-%d %H:%M') | $(case "$rc" in 0) echo OK;; stop) echo ARRETEE;; *) echo "ECHEC ($rc)";; esac) | $MODE | $SRC -> $DST | $(( ($(date +%s) - DEBUT) / 60 )) min" >> "$CP_HIST"
    if [ "$rc" = stop ]; then
      :
    elif [ "$rc" = 0 ]; then
      notify info "Copie vers l'OMV terminée" "« ${SRC##*/} » ($(hsize "$TOTAL"), $MODE) est sur l'OMV dans $DST."
    else
      notify critique "Copie vers l'OMV en échec" "« ${SRC##*/} » : erreur code $rc. Relancer la copie reprendra où elle s'est arrêtée."
    fi
    # copie suivante de la file d'attente (seulement apres un succes)
    if [ "$rc" = 0 ] && [ -s "$CP_STATE/file-attente" ]; then
      bash "$SELF" copie lancer-file >> "$CP_STATE/file-attente.log" 2>&1
    fi
    # plus rien a copier : l'OMV reveille pour la copie peut se rendormir
    cp_running || omv_rest
    exit ;;
esac

while true; do
  clear
  echo -e "${B}===== COPIE NAS -> OMV ($OMV_HOST) =====${N}"
  if cp_running; then
    . "$CP_RUN"; echo -e "${J}Copie en cours : ${SRC##*/} -> $DST${N}"
  fi
  echo
  echo "  1) Nouvelle copie"
  echo "  2) Suivre la copie en cours"
  echo "  3) Arreter la copie en cours"
  echo "  4) Historique"
  echo "  5) Reparer les droits d'un dossier sur l'OMV"
  echo "  0) Quitter"
  read -r -p "Choix : " c
  case "$c" in
    1) cp_new_copy; read -r -p "Entree pour revenir au menu..." _ ;;
    2) cp_follow;   read -r -p "Entree pour revenir au menu..." _ ;;
    3) cp_stop_copy; sleep 2 ;;
    4) clear; tail -n 20 "$CP_HIST" 2>/dev/null || echo "Aucune copie."; read -r -p "Entree..." _ ;;
    5) cp_fix_perms; read -r -p "Entree pour revenir au menu..." _ ;;
    0|q) exit 0 ;;
  esac
done
}

# =========================== Initialisation des modes ================
cp_init() {
  need_root
  mkdir -p "$CP_STATE" /root/.ssh; chmod 700 /root/.ssh
  command -v rsync >/dev/null || die "rsync introuvable sur le NAS."
}

# =========================== Commandes de la machine =================
version_json() {
  local dsm; dsm=$(grep -m1 '^productversion=' /etc.defaults/VERSION 2>/dev/null | cut -d'"' -f2)
  printf '{"script":"nas-synology","version":"%s","api":%s,"machine":"synology","dsm":"%s"}\n' "$SCRIPT_VERSION" "$API_VERSION" "$dsm"
}

rclone_derniere() {  # derniere version de rclone (verifiee au plus une fois par jour)
  local f="$SYNO_DIR/rclone-derniere" v
  mkdir -p "$SYNO_DIR"
  if [ -f "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -lt 86400 ]; then cat "$f"; return 0; fi
  v=$(curl -fsSL -m 15 https://downloads.rclone.org/version.txt 2>/dev/null | awk '{print $2}' | tr -d 'v\r')
  [ -n "$v" ] || return 1
  echo "$v" > "$f"; echo "$v"
}

outils_etat() {
  local rc="" b
  command -v rclone >/dev/null && rc=$(rclone version 2>/dev/null | head -n 1 | awk '{print $2}' | tr -d 'v')
  b() { command -v "$1" >/dev/null && echo true || echo false; }
  printf '{"machine":"synology","arch":"%s","ram_total_mo":%s,"ram_dispo_mo":%s,"python3":%s,"rsync":%s,"curl":%s,"ssh":%s,"rclone":"%s","rclone_derniere":"%s","cle_omv":%s,"smartctl":%s}\n' \
    "$(uname -m)" "$(ram_total_mo)" "$(ram_dispo_mo)" "$(b python3)" "$(b rsync)" "$(b curl)" "$(b ssh)" "$rc" \
    "$(cat "$SYNO_DIR/rclone-derniere" 2>/dev/null)" "$( [ -f "$CP_KEY" ] && echo true || echo false)" "$(b smartctl)"
}

outils_installer() {
  need_root
  local manque=""
  command -v python3 >/dev/null || manque="$manque python3 (Centre de paquets : Python 3)"
  command -v rsync >/dev/null   || manque="$manque rsync (Panneau de configuration > Services de fichiers > rsync)"
  command -v curl >/dev/null    || manque="$manque curl"
  mkdir -p "$MG_STATE" "$MG_BIN" "$SYNO_DIR"
  if command -v rclone >/dev/null; then echo -e "${V}OK : $(rclone version | head -n 1)${N}"; else rclone_download; fi
  [ -f "$CP_KEY" ] || { ssh-keygen -t ed25519 -N "" -C "copie-omv@$(hostname)" -f "$CP_KEY" -q && echo -e "${V}OK : cle SSH du Synology vers l'OMV creee${N}"; }
  rclone_derniere >/dev/null 2>&1
  if [ -n "$manque" ]; then
    echo -e "${J}A activer dans DSM (impossible depuis le script) :$manque${N}"; return 1
  fi
  echo -e "${V}Tous les outils necessaires sont presents.${N}"
}

reglages() {
  need_root
  mkdir -p "$SYNO_DIR"
  case "${1:-voir}" in
    voir)
      agent_conf_load; perf_load
      printf '{"omv":"%s","ha":"%s","webhook":"%s","omv_mac":"%s","omv_apres":"%s","profil":"%s","mo":"%s","transferts":"%s","verifs":"%s","effectif":{"profil":"%s","mo":%s,"options":"--transfers %s --checkers %s"},"ram_total_mo":%s,"ram_dispo_mo":%s}\n' \
        "$OMV_HOST" "$HA_HOST" "$HA_WEBHOOK" "$OMV_MAC" "$OMV_APRES" "$RAM_PROFIL" "$RAM_MO" "$TRANSFERTS" "$VERIFS" "$PERF_PROFIL" "$PERF_MO" "$PERF_T" "$PERF_C" "$(ram_total_mo)" "$(ram_dispo_mo)" ;;
    ram)
      local p="${2:-auto}" mo="${3:-}" t="${4:-}" c="${5:-}"
      [[ "$p" =~ ^(auto|econome|equilibre|performant)$ ]] || die "profil invalide (auto, econome, equilibre, performant)."
      [ "$mo" = - ] && mo=""; [ "$t" = - ] && t=""; [ "$c" = - ] && c=""
      [ -z "$mo" ] || { [[ "$mo" =~ ^[0-9]+$ ]] && [ "$mo" -ge 64 ]; } || die "limite de memoire invalide (nombre de Mo, 64 au minimum)."
      [ -z "$t" ] || [[ "$t" =~ ^[1-9][0-9]?$ ]] || die "nombre de transferts invalide (1 a 99)."
      [ -z "$c" ] || [[ "$c" =~ ^[1-9][0-9]?$ ]] || die "nombre de verifications invalide (1 a 99)."
      local tot; tot=$(ram_total_mo)
      [ -n "$mo" ] && [ "$mo" -gt $(( tot * 3 / 4 )) ] && echo -e "${J}Attention : $mo Mo, c'est plus des 3/4 de la memoire du Synology ($tot Mo).${N}"
      printf 'RAM_PROFIL=%s\nRAM_MO=%s\nTRANSFERTS=%s\nVERIFS=%s\n' "$p" "$mo" "$t" "$c" > "$AGENT_CONF"
      perf_load
      echo -e "${V}Memoire de rclone : profil $PERF_PROFIL, limite $PERF_MO Mo, $PERF_T fichier(s) a la fois.${N}" ;;
    omv)
      [[ "${2:-}" =~ ^[A-Za-z0-9._:-]+$ ]] || die "adresse invalide."
      conf_set OMV_HOST "$2"; echo -e "${V}Adresse de l'OMV / machine Debian : $2${N}" ;;
    ha)
      [[ "${2:-}" =~ ^[A-Za-z0-9._:-]*$ && "${3:-}" =~ ^[A-Za-z0-9_-]*$ ]] || die "adresse ou webhook invalide."
      conf_set HA_HOST "${2:-}"; conf_set HA_WEBHOOK "${3:-}"; echo -e "${V}Notifications Home Assistant : ${2:-(desactivees)}${N}" ;;
    omv-reveil)   # omv-reveil <MAC|-> [rien|veille|arret]
      local mac="${2:-}" ap="${3:-rien}"
      [ "$mac" = - ] && mac=""
      [[ -z "$mac" || "$mac" =~ ^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$ ]] || die "adresse MAC invalide (ex. 00:11:32:AA:BB:CC)."
      [[ "$ap" =~ ^(rien|veille|arret)$ ]] || die "apres invalide (rien, veille ou arret)."
      conf_set OMV_MAC "${mac^^}"; conf_set OMV_APRES "$ap"
      if [ -n "$mac" ]; then echo -e "${V}Reveil de l'OMV avant les copies : $mac$( [ "$ap" != rien ] && echo " (remis en $ap apres)").${N}"
      else echo -e "${V}Reveil de l'OMV desactive.${N}"; fi ;;
    *) die "usage : nas-synology reglages voir | ram <profil> [Mo] [transferts] [verifs] | omv <adresse> | ha <adresse> <webhook> | omv-reveil <MAC|-> [rien|veille|arret]" ;;
  esac
}

conf_set() {  # conf_set <CLE> <valeur>  (fichier SYNO_CONF)
  mkdir -p "$SYNO_DIR"; touch "$SYNO_CONF"
  grep -v "^$1=" "$SYNO_CONF" > "$SYNO_CONF.new"
  printf '%s=%q\n' "$1" "$2" >> "$SYNO_CONF.new"
  mv -f "$SYNO_CONF.new" "$SYNO_CONF"; chmod 600 "$SYNO_CONF"
}

install_base() {
  need_root
  mkdir -p "$SYNO_DIR"
  local n
  for n in "${LEGACY_NAMES[@]}"; do
    if [ ! -e "$BIN_DIR/$n" ] || [ -L "$BIN_DIR/$n" ]; then ln -sfn nas-synology "$BIN_DIR/$n"; fi
  done
  echo "Installation de base prete (Synology)."
}

is_legacy() { [ -f "$BIN_DIR/$1" ] && [ ! -L "$BIN_DIR/$1" ]; }

migrer() {
  need_root
  local mode="${1:-simulation}" n todo=0 dest old
  [ -x "$BIN_DIR/nas-synology" ] || die "installe d'abord nas-synology dans $BIN_DIR/nas-synology."
  echo -e "${B}== Reprise de l'installation existante (Synology) ==${N}"
  for n in "${LEGACY_NAMES[@]}"; do
    is_legacy "$n" || continue
    todo=1; echo "- $BIN_DIR/$n : ancien script remplace par un lien vers nas-synology (ancien garde dans $OLD_DIR)"
  done
  if is_legacy copie-omv && [ ! -f "$SYNO_CONF" ]; then
    old=$(grep -m1 '^OMV_HOST=' "$BIN_DIR/copie-omv" | cut -d'"' -f2)
    [ -n "$old" ] && echo "- adresse de l'OMV reprise : $old"
  fi
  [ -d "$CP_STATE" ] && echo "- copies : file d'attente, historique et cle SSH conserves"
  [ -d "$MG_STATE" ] && echo "- migrations : connexion oCIS, file d'attente et historique conserves"
  if [ $todo = 0 ]; then echo -e "${V}Rien a migrer : l'installation utilise deja nas-synology.${N}"; return 0; fi
  [ "$mode" = appliquer ] || { echo; echo -e "${J}Simulation : rien n'a ete modifie.${N}"; return 0; }
  echo
  if is_legacy copie-omv && [ ! -f "$SYNO_CONF" ]; then
    old=$(grep -m1 '^OMV_HOST=' "$BIN_DIR/copie-omv" | cut -d'"' -f2)
    [ -n "$old" ] && conf_set OMV_HOST "$old"
  fi
  dest="$OLD_DIR/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$dest"
  for n in "${LEGACY_NAMES[@]}"; do
    is_legacy "$n" || continue
    cp -p "$BIN_DIR/$n" "$dest/$n"
    # remplacement atomique : une copie ou une migration en cours garde l'ancienne version
    ln -sfn nas-synology "$BIN_DIR/$n.lien" && mv -f "$BIN_DIR/$n.lien" "$BIN_DIR/$n"
    echo -e "${V}OK : $n -> nas-synology${N}"
  done
  echo -e "${V}Migration terminee. Anciens scripts gardes dans $dest${N}"
}

menu_principal() {
  while true; do
    clear
    echo -e "${B}===== NAS SYNOLOGY ($SCRIPT_VERSION) =====${N}"
    echo
    echo "  1) Copie vers l'OMV / la machine Debian"
    echo "  2) Migration Synology Drive -> oCIS"
    echo "  4) Transferts oCIS -> Synology"
    echo "  3) Outils, version et memoire de rclone"
    echo "  0) Quitter"
    read -r -p "Choix : " c
    case "$c" in
      1) bash "$SELF" copie ;;
      2) bash "$SELF" migration ;;
      4) bash "$SELF" transferts ;;
      3) clear; version_json; outils_etat; reglages voir; pause ;;
      0|q) exit 0 ;;
    esac
  done
}

# =========================== Point d'entree ==========================
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

DISQUES_JSON="$SYNO_DIR/disques.json"

# Alerte Home Assistant suivie (rappel toutes les 12 h, « retabli » a la fin) : syno_alert <critique|ok|evenement> <tag> <titre> <message>
syno_alert() {
  local f="$SYNO_DIR/alertes/$2"
  mkdir -p "$SYNO_DIR/alertes"
  case "$1" in
    critique)
      if [ -f "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -lt 43200 ]; then return 0; fi
      notify critique "$3" "$4"; touch "$f" ;;
    ok) [ -f "$f" ] || return 0; rm -f "$f"; notify info "✅ Rétabli : $3" "$4" ;;
    evenement) notify critique "$3" "$4" ;;
  esac
}

disques_verifier() {
  need_root
  mkdir -p "$SYNO_DIR"
  exec 4>"/tmp/nas-synology-disques.lock"
  flock -n 4 || return 0   # verification deja en cours (lancee par NAS Manager)
  local kind a b c sm
  sm=$(command -v smartctl 2>/dev/null || { [ -x /usr/sbin/smartctl ] && echo /usr/sbin/smartctl; } || true)
  while IFS='|' read -r kind a b c; do
    case "$kind" in
      ALERTE)    syno_alert critique "$a" "Synology : $b" "$c" ;;
      OK)        syno_alert ok "$a" "Synology : $b" "$c" ;;
      EVENEMENT) syno_alert evenement disques "Synology : $a" "$b" ;;
    esac
  done < <(disk_health_py "$DISQUES_JSON" "$sm" "$(hostname 2>/dev/null)")
  exec 4>&-
  return 0
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

syno_main() {
  case "${1:-}" in
    "")        need_root; menu_principal ;;
    copie)     shift; cp_main "$@" ;;
    migration) shift; mg_main "$@" ;;
    transferts) shift; tr_main "$@" ;;
    version)   version_json ;;
    installer) install_base ;;
    outils)
      case "${2:-etat}" in
        etat)       outils_etat ;;
        installer)  outils_installer ;;
        rclone-maj) need_root; mkdir -p "$MG_STATE"; rclone_download; rm -f "$SYNO_DIR/rclone-derniere" ;;
        derniere)   rclone_derniere ;;
        *) die "usage : nas-synology outils etat | installer | rclone-maj" ;;
      esac ;;
    reglages)  shift; reglages "$@" ;;
    tui)       shift; tui_main "$@" ;;
    migrer)    migrer "${2:-simulation}" ;;
    reveil)    [[ "${2:-}" =~ ^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$ ]] || die "usage : nas-synology reveil <MAC> [adresse]"
               wol_send "$2" "${3:-}" || die "envoi impossible."; echo -e "${V}Paquet de reveil envoye a $2.${N}" ;;
    disques)
      case "${2:-etat}" in
        verifier) disques_verifier; cat "$DISQUES_JSON" 2>/dev/null ;;
        etat)     cat "$DISQUES_JSON" 2>/dev/null || echo '{}' ;;
        *) die "usage : nas-synology disques verifier | etat" ;;
      esac ;;
    *)         die "commande inconnue : $1 (copie, migration, transferts, version, outils, reglages, tui, migrer, disques, reveil)" ;;
  esac
}

case "$(basename "$0")" in
  copie-omv)        cp_main "$@" ;;
  migre-drive-ocis) mg_main "$@" ;;
  *)                syno_main "$@" ;;
esac
