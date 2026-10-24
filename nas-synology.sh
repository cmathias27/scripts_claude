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
#    version                version du script (JSON)
#    installer              liens copie-omv / migre-drive-ocis
#    outils etat | installer | rclone-maj
#    reglages voir | ram <auto|econome|equilibre|performant> [Mo] [transferts] [verifs]
#             | omv <adresse> | ha <adresse> <webhook>
#    migrer simulation | appliquer   reprise d'une installation avec les anciens scripts
# =====================================================================
set -o pipefail

SCRIPT_VERSION="2.1.0"
API_VERSION=3

# --------------------------- Reglages --------------------------------
# Valeurs par defaut, modifiables avec « nas-synology reglages » (fichier SYNO_CONF)
OMV_HOST="192.168.1.190"          # adresse de l'OMV / de la machine Debian (copie)
OMV_USER="root"
OMV_ROOT="/srv"                   # point de depart pour choisir la destination
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

# migration oCIS
MG_STATE="/root/.migre-ocis"
MG_CONF="$MG_STATE/config"
MG_QUEUE="$MG_STATE/file-attente"
MG_RUN="$MG_STATE/en-cours"
MG_LOGF="$MG_STATE/progression.log"
MG_HIST="$MG_STATE/historique.log"
MG_BIN="$MG_STATE/bin"
MG_EXCL=(--exclude '@eaDir/**' --exclude '#recycle/**' --exclude '#snapshot/**' --exclude '#SynoRecycle/**'
      --exclude '.SynologyWorkingDirectory/**' --exclude '*@SynoEAStream' --exclude '*@SynoResource'
      --exclude '.DS_Store' --exclude 'Thumbs.db' --exclude 'desktop.ini')
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
# --------------------------- Cle SSH vers l'OMV ----------------------
cp_ensure_ssh() {
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

  # Copie en arriere-plan, independante de la session SSH
  nohup setsid bash -c '
    rsync -rlt --partial --no-inc-recursive --info=progress2 --human-readable \
      "${@:6}" -e "ssh ${5}" "$1" "$2:$3/" >>"'"$CP_LOGF"'" 2>&1
    rc=$?
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
  total=$(du -sb --exclude='@eaDir' --exclude='#recycle' "$src" 2>/dev/null | cut -f1)
  nbf=$(find "$src" -type f ! -path '*/@eaDir/*' ! -path '*/#recycle/*' 2>/dev/null | wc -l)
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
  [ -f "$CP_KEY" ] && osh true 2>/dev/null \
    || die "la connexion automatique NAS -> OMV n'est pas configuree : autorise la cle du Synology sur l'OMV depuis NAS Manager (page Copie), ou lance une fois 'sudo bash $SELF copie' en SSH (Nouvelle copie)."
  osh "[ -d $(q "$dst") ]" || die "dossier introuvable sur l'OMV : $dst"
  osh "command -v rsync >/dev/null" || osh "apt-get install -y -qq rsync >/dev/null" || die "rsync manquant sur l'OMV."
  local rsrc="$src" final="$dst/${src##*/}"
  [ "$place" = contenu ] && { rsrc="$src/"; final="$dst"; }
  local total nbf
  total=$(du -sb --exclude='@eaDir' --exclude='#recycle' "$src" 2>/dev/null | cut -f1)
  nbf=$(find "$src" -type f ! -path '*/@eaDir/*' ! -path '*/#recycle/*' 2>/dev/null | wc -l)
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
  echo -e "${B}== Connexion a oCIS ==${N}"
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
      echo -e "${J}Le certificat HTTPS d'oCIS n'est pas reconnu (certificat auto-signe ?).${N}"
      read -r -p "L'accepter quand meme ? [o/N] : " c; [[ "$c" =~ ^[oOyY] ]] && insecure=1 || return 1
    else
      echo -e "${R}oCIS injoignable a l'adresse $u${N}"; return 1
    fi
  fi
  OCIS_URL="$u"; BASE="$u"; OCIS_USER="$usr"; OCIS_PASS="$pw"; CURL_K=""; [ $insecure = 1 ] && CURL_K="-k"
  api GET /graph/v1.0/me/drives
  case "$HTTP" in
    200) ;;
    401) echo -e "${R}Identifiants refuses (401).${N}"
         echo "Verifie le jeton, et que l'authentification par jeton est activee sur oCIS :"
         echo "  OCIS_ADD_RUN_SERVICES=auth-app  et  PROXY_ENABLE_APP_AUTH=true"
         echo "(ou PROXY_ENABLE_BASIC_AUTH=true pour utiliser le mot de passe)."; return 1 ;;
    *)   echo -e "${R}Reponse inattendue d'oCIS (HTTP $HTTP).${N}"; return 1 ;;
  esac
  echo -e "${V}Connexion a oCIS reussie.${N}"
  RCLONE_K=(); [ $insecure = 1 ] && RCLONE_K=(--no-check-certificate)
  ensure_rclone

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
      echo -e "${V}Adresse locale OK : $lu${N}"
    else
      echo -e "${J}L'adresse locale ne repond pas correctement (HTTP $HTTP) : les transferts passeront par $u.${N}"
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
  [ -n "$dav" ] || { echo -e "${R}Espace personnel du compte introuvable : test d'envoi impossible.${N}"; return 1; }
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
      [ $v = owncloud ] && echo -e "${V}Envoi OK (WebDAV classique).${N}" \
                        || echo -e "${J}Envoi OK en mode oCIS natif seulement : attention, rclone y consomme beaucoup de memoire.${N}"
      return 0
    fi
  done
  rm -f "$tmp"
  echo -e "${R}Le test d'envoi a echoue dans les deux modes : verifie les droits du compte et l'adresse d'oCIS.${N}"
  return 1
}

mg_ensure_conf() { load_conf || mg_setup_conf || die "configuration oCIS incomplete."; }

# =========================== Espaces projets =========================
# Liste "id|nom|webDavUrl" des espaces projets visibles
list_spaces() {  # remplit le tableau SPACES ("id|nom|webDavUrl") ; HTTP garde le code
  SPACES=()
  api GET /graph/v1.0/me/drives
  [ "$HTTP" = 200 ] || return 1
  mapfile -t SPACES < <(python3 -c '
import json, sys, urllib.parse as u
base = u.urlsplit(sys.argv[1])
for d in json.load(sys.stdin).get("value", []):
    if d.get("driveType") == "project" and not d.get("root", {}).get("deleted"):
        w = u.urlsplit(d["root"]["webDavUrl"])
        w = u.urlunsplit((base.scheme, base.netloc) + tuple(w[2:]))
        q = d.get("quota") or {}
        tot = q.get("total") or 0
        rem = q.get("remaining") if tot else -1
        print("%s|%s|%s|%s|%s" % (d["id"], d.get("name", "?").replace("|", "/"), w, rem if rem is not None else -1, tot))
' "$BASE" <<< "$BODY" | sort -t'|' -k2,2f)
}

# Explique un code HTTP d'oCIS
http_hint() {
  case "$1" in
    401) echo -e "${R}oCIS refuse la connexion (401) : jeton d'application expire ou revoque.${N}"
         echo "Un jeton cree par « ocis auth-app create » dure 72 h par defaut. Recrees-en un, par exemple :"
         echo "  docker exec <conteneur-ocis> ocis auth-app create --user-name=$OCIS_USER --expiration=2160h"
         echo "puis mets-le a jour dans le menu « 7) Modifier la connexion oCIS »." ;;
    000) echo -e "${R}oCIS injoignable a l'adresse $OCIS_URL (serveur arrete, reseau ou certificat).${N}" ;;
    *)   echo -e "${R}Reponse inattendue d'oCIS (HTTP $1).${N}" ;;
  esac
}

# =========================== Choix ===================================
# Navigateur de dossiers du NAS  -> CHOIX
mg_browse_local() {
  local cur="/" c i d
  local -a dirs=()
  while true; do
    if [ "$cur" = "/" ]; then
      mapfile -t dirs < <(ls -d /volume[0-9]*/*/ 2>/dev/null | sed 's#/$##' | grep -v -E '/(@|#)')
    else
      mapfile -t dirs < <(find "$cur" -mindepth 1 -maxdepth 1 -type d ! -name '@*' ! -name '#*' ! -name '.*' 2>/dev/null | sort)
    fi
    clear
    echo -e "${B}== Dossier a migrer ==${N}"
    echo -e "Dossier actuel : ${B}$( [ "$cur" = / ] && echo "(dossiers partages)" || echo "$cur" )${N}"
    echo
    i=1
    for d in "${dirs[@]}"; do printf "  %3d) %s\n" "$i" "$( [ "$cur" = / ] && echo "$d" || echo "${d##*/}" )"; i=$((i+1)); done
    [ ${#dirs[@]} -eq 0 ] && echo -e "  ${G}(aucun sous-dossier)${N}"
    echo
    echo "  numero = entrer dans le dossier"
    [ "$cur" != "/" ] && echo "  v = VALIDER « ${cur##*/} »"
    echo "  r = remonter      q = annuler"
    read -r -p "Choix : " c
    case "$c" in
      v|V) [ "$cur" != "/" ] && { CHOIX="$cur"; return 0; } ;;
      r|R) if [[ "$cur" =~ ^/volume[0-9]+/[^/]+$ ]]; then cur="/"; elif [ "$cur" != "/" ]; then cur="${cur%/*}"; fi ;;
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
  echo -e "${B}== Dossier a migrer ==${N}"
  if [ ${#dirs[@]} -gt 0 ]; then
    echo "Mon Drive des utilisateurs (calcul des tailles...) :"
    i=1
    for d in "${dirs[@]}"; do
      printf "  %2d) %-28s %10s\n" "$i" "${labels[$((i-1))]}" "$(hsize "$(du -sb --exclude='@eaDir' --exclude='#SynoRecycle' "$d" 2>/dev/null | cut -f1)")"
      i=$((i+1))
    done
  else
    echo -e "${G}(aucun Mon Drive trouve dans /volume*/homes/*/Drive)${N}"
  fi
  echo
  echo "   p) Parcourir les dossiers du NAS (ex : /volume4/utils)"
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
  echo -e "${B}== Espace projet oCIS de destination ==${N}"
  if ! list_spaces; then http_hint "$HTTP"; pause; return 1; fi
  sp=("${SPACES[@]}")
  if [ ${#sp[@]} -eq 0 ]; then
    echo -e "${J}Aucun espace projet visible pour le compte « $OCIS_USER ».${N}"
    echo "Cree les espaces dans oCIS, puis ajoute ce compte comme membre de chaque"
    echo "espace avec le droit « Peut modifier » ou « Gestionnaire »."
    pause; return 1
  fi
  i=1
  local nm rem tot q
  for line in "${sp[@]}"; do
    IFS='|' read -r _ nm _ rem tot <<< "$line"
    if [ "${tot:-0}" -gt 0 ] 2>/dev/null; then q="libre $(hsize "$rem") / quota $(hsize "$tot")"; else q="sans limite"; fi
    printf "  %2d) %-30s %s\n" "$i" "$nm" "$q"; i=$((i+1))
  done
  echo -e "${G}(seuls les espaces dont « $OCIS_USER » est membre apparaissent)${N}"
  read -r -p "Choix (Entree = annuler) : " c
  [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#sp[@]} ] || return 1
  IFS='|' read -r SP_ID SP_NAME SP_DAV SP_FREE SP_QUOTA <<< "${sp[$((c-1))]}"
}

# =========================== File d'attente ==========================
mg_running() { [ -f "$MG_RUN" ] && . "$MG_RUN" && kill -0 "$PID" 2>/dev/null; }

mg_add_task() {
  mg_pick_source || return
  mg_pick_space || return
  clear
  echo -e "${B}== Nouvelle migration ==${N}"
  echo "Calcul..."
  local total nbf sub
  total=$(du -sb --exclude='@eaDir' --exclude='#SynoRecycle' --exclude='.SynologyWorkingDirectory' "$SRC_DIR" 2>/dev/null | cut -f1)
  nbf=$(find "$SRC_DIR" -type f ! -path '*/@eaDir/*' ! -path '*/#SynoRecycle/*' ! -path '*/.SynologyWorkingDirectory/*' 2>/dev/null | wc -l)
  echo
  echo -e "  Source  : ${B}$SRC_DIR${N}  ($(hsize "${total:-0}"), $nbf fichiers)"
  echo -e "  Espace  : ${B}$SP_NAME${N}"
  if [ "${SP_QUOTA:-0}" -gt 0 ] 2>/dev/null && [ "${total:-0}" -gt "${SP_FREE:-0}" ]; then
    echo
    echo -e "  ${R}Attention : l'espace n'a que $(hsize "$SP_FREE") de libre (quota $(hsize "$SP_QUOTA")),${N}"
    echo -e "  ${R}la migration s'arretera quand il sera plein.${N}"
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
  echo "  1) Garder les originaux sur le Synology (copie)"
  echo "  2) Controler chaque fichier dans oCIS, puis SUPPRIMER l'original du Synology"
  local m del=non
  read -r -p "Choix [1] : " m
  if [ "${m:-1}" = 2 ]; then
    echo
    echo -e "${J}Seuls les fichiers dont la copie dans oCIS est controlee identique (empreinte)"
    echo -e "sont supprimes. Un fichier absent, different ou modifie entre-temps est renvoye"
    echo -e "puis recontrole (3 fois au plus) ; s'il reste en defaut, il est garde.${N}"
    if [[ "$SRC_DIR" == */homes/*/Drive* ]]; then
      echo -e "${R}C'est un « Mon Drive » : les ordinateurs synchronises avec Synology Drive"
      echo -e "supprimeront aussi ces fichiers chez eux. Installe d'abord le client oCIS.${N}"
    fi
    read -r -p "Tape SUPPRIMER pour confirmer : " c
    if [ "$c" = SUPPRIMER ]; then del=oui; else echo "Annule : les originaux seront gardes."; fi
  fi
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$SRC_DIR" "$SRC_LABEL" "$SP_ID" "$SP_NAME" "$SP_DAV" "$sub" "${total:-0}" "$del" >> "$MG_QUEUE"
  echo -e "${V}Ajoute a la file d'attente : $SRC_LABEL -> $SP_NAME${sub:+/$sub}$( [ $del = oui ] && echo " (+ suppression des originaux)")${N}"
}

mg_show_queue() {
  [ -s "$MG_QUEUE" ] || { echo -e "  ${G}(file d'attente vide)${N}"; return; }
  local i=1 s l id n dav sub t del
  while IFS='|' read -r s l id n dav sub t del; do
    printf "  %2d) %-18s -> %-25s %10s%s\n" "$i" "$l" "$n${sub:+/$sub}" "$(hsize "$t")" \
      "$(case "$del" in oui) echo -e "  ${R}+ suppression des originaux${N}";; verif) echo -e "  ${R}controle + suppression (sans transfert)${N}";; esac)"; i=$((i+1))
  done < "$MG_QUEUE"
}

# Migration deja faite : controle dans oCIS puis suppression des originaux, sans transfert
mg_add_verif() {
  local -a past=(); local line c s dst best="" bl=0 nm sub total nbf
  clear
  echo -e "${B}== Controler et supprimer les originaux d'une migration deja faite ==${N}"
  # migrations reussies de l'historique (« source -> espace[/sous-dossier] »), dont la source existe encore
  mapfile -t past < <(awk -F' [|] ' '$2 ~ /^OK/ {print $3}' "$MG_HIST" 2>/dev/null | awk '!vu[$0]++' |
                      while IFS= read -r line; do [ -d "${line%% -> *}" ] && echo "$line"; done)
  if [ ${#past[@]} -gt 0 ]; then
    echo "Migrations reussies (historique) :"
    local i=1
    for line in "${past[@]}"; do printf "  %2d) %s\n" "$i" "$line"; i=$((i+1)); done
  else
    echo -e "${G}(aucune migration reussie dans l'historique)${N}"
  fi
  echo "   m) Choisir a la main la source et l'espace"
  read -r -p "Choix (Entree = annuler) : " c
  if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#past[@]} ]; then
    line="${past[$((c-1))]}"; s="${line%% -> *}"; dst="${line#* -> }"
    if ! list_spaces; then http_hint "$HTTP"; pause; return; fi
    # espace dont le nom correspond au debut de la destination (le plus long gagne)
    for line in "${SPACES[@]}"; do
      IFS="|" read -r _ nm _ _ _ <<< "$line"
      if { [ "$dst" = "$nm" ] || [[ "$dst" == "$nm/"* ]]; } && [ ${#nm} -gt $bl ]; then best="$line"; bl=${#nm}; fi
    done
    [ -n "$best" ] || { echo -e "${R}Espace « ${dst%%/*} » introuvable dans oCIS (renomme, ou compte non membre ?).${N}"; pause; return; }
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
  echo -e "${B}== Controle et suppression ==${N}"
  echo "Calcul..."
  total=$(du -sb --exclude='@eaDir' --exclude='#SynoRecycle' --exclude='.SynologyWorkingDirectory' "$SRC_DIR" 2>/dev/null | cut -f1)
  nbf=$(find "$SRC_DIR" -type f ! -path '*/@eaDir/*' ! -path '*/#SynoRecycle/*' ! -path '*/.SynologyWorkingDirectory/*' 2>/dev/null | wc -l)
  echo
  echo -e "  Synology : ${B}$SRC_DIR${N}  ($(hsize "${total:-0}"), $nbf fichiers)"
  echo -e "  oCIS     : ${B}$SP_NAME${sub:+/$sub}${N}"
  echo
  echo -e "${J}Aucun transfert : chaque fichier du Synology est compare a sa copie dans oCIS"
  echo -e "(empreinte), et seuls ceux qui sont identiques sont supprimes du Synology."
  echo -e "Ceux qui sont absents ou differents sont gardes, puis transferes et controles"
  echo -e "au passage suivant (remis en file d'attente).${N}"
  if [[ "$SRC_DIR" == */homes/*/Drive* ]]; then
    echo -e "${R}C'est un « Mon Drive » : les ordinateurs synchronises avec Synology Drive"
    echo -e "supprimeront aussi ces fichiers chez eux. Installe d'abord le client oCIS.${N}"
  fi
  read -r -p "Tape SUPPRIMER pour confirmer : " c
  [ "$c" = SUPPRIMER ] || { echo "Annule."; sleep 1; return; }
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$SRC_DIR" "$SRC_LABEL" "$SP_ID" "$SP_NAME" "$SP_DAV" "$sub" "${total:-0}" verif >> "$MG_QUEUE"
  echo -e "${V}Ajoute a la file d'attente : controle et suppression de $SRC_LABEL (lance-la avec le menu 3)${N}"
}

mg_remove_task() {
  mg_show_queue; [ -s "$MG_QUEUE" ] || return
  read -r -p "Numero a retirer : " c
  [[ "$c" =~ ^[0-9]+$ ]] && sed -i "${c}d" "$MG_QUEUE"
}

# =========================== Lancement ===============================
mg_start() {
  if mg_running; then echo -e "${J}Une migration est deja en cours.${N}"; mg_follow; return; fi
  [ -s "$MG_QUEUE" ] || { echo "La file d'attente est vide : ajoute d'abord une migration."; pause; return; }
  ensure_rclone
  echo; echo -e "${B}Migrations a lancer :${N}"; mg_show_queue; echo
  read -r -p "Lancer ? [O/n] : " go
  [[ "${go:-o}" =~ ^[oOyY] ]] || return
  cp "$MG_QUEUE" "$MG_STATE/lot"; : > "$MG_QUEUE"
  [ -s "$MG_LOGF" ] && mv -f "$MG_LOGF" "$MG_LOGF.precedent"; : > "$MG_LOGF"
  rm -f "$MG_STATE/code" "$MG_STATE/etape" "$MG_STATE/resultats" "$MG_STATE/rss"   # resultats d'un suivi precedent interrompu
  printf 'NB=%s\nDEBUT=%s\n' "$(wc -l < "$MG_STATE/lot")" "$(date +%s)" > "$MG_RUN"
  nohup setsid bash "$SELF" migration _worker >/dev/null 2>&1 &
  echo "PID=$!" >> "$MG_RUN"
  echo -e "${V}Migration lancee.${N}"; sleep 1
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

hdur() {  # duree lisible : hdur <secondes>
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
             PG_EN_COURS=len(s.get("transferring") or []))
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

# Bilan d'une etape : compte les fichiers sur le Synology et dans oCIS (memes exclusions),
# et resume nouveaux essais, erreurs, reprises et duree dans le journal.
# mg_bilan <source> <sous-dossier> <etape> <debut (epoch)> <reprises> <libelle>  -> BILAN_MSG
mg_bilan() {
  local s="$1" sub="$2" n="$3" t0="$4" rep="${5:-0}" lab="$6" js jd sf so df dob v l
  local PG_ETAPE="" PG_ESSAIS=0 PG_ERREURS=0 PG_SURPLUS=0
  BILAN_MSG=""
  echo "PHASE=bilan" >> "$MG_STATE/etape"
  echo "=== [$n] bilan : comptage des fichiers sur le Synology et dans oCIS" >> "$MG_LOGF"
  js=$(GOGC=50 GOMEMLIMIT="$MEMLIM" rclone size --json "$s" "${MG_EXCL[@]}" < /dev/null 2>/dev/null)
  jd=$(GOGC=50 GOMEMLIMIT="$MEMLIM" rclone size --json "ocis:$sub" "${MG_EXCL[@]}" "${RCLONE_K[@]}" \
        --disable-http2 --checkers 4 < /dev/null 2>/dev/null)
  sf=$(sed -n 's/.*"count":\([0-9]*\).*/\1/p' <<< "$js"); so=$(sed -n 's/.*"bytes":\([0-9]*\).*/\1/p' <<< "$js")
  df=$(sed -n 's/.*"count":\([0-9]*\).*/\1/p' <<< "$jd"); dob=$(sed -n 's/.*"bytes":\([0-9]*\).*/\1/p' <<< "$jd")
  if [ -z "$sf" ] || [ -z "$so" ] || [ -z "$df" ] || [ -z "$dob" ]; then
    v="comptage impossible ($( [ -z "$sf" ] && echo Synology || echo oCIS))"
    BILAN_MSG="bilan : $v"
  else
    l="Synology $sf fichier(s) / $(hsize "$so") · oCIS $df fichier(s) / $(hsize "$dob")"
    if [ "$df" -eq "$sf" ] && [ "$dob" -eq "$so" ]; then
      v="$l · identique"; BILAN_MSG="bilan : oCIS = Synology ($sf fichiers, $(hsize "$so"))"
    elif [ "$df" -lt "$sf" ]; then
      v="$l · il MANQUE $((sf - df)) fichier(s) dans oCIS"; BILAN_MSG="bilan : il manque $((sf - df)) fichier(s) dans oCIS"
      notify critique "Migration oCIS : fichiers manquants" "$lab : $((sf - df)) fichier(s) du Synology absent(s) d'oCIS à la fin du transfert (détail dans le journal de la migration)."
    elif [ "$df" -gt "$sf" ]; then
      v="$l · oCIS contient $((df - sf)) fichier(s) de plus (deja presents dans la destination)"
      BILAN_MSG="bilan : tout est dans oCIS (+$((df - sf)) fichier(s) deja presents)"
    else
      v="$l · meme nombre de fichiers, $(hsize $(( so > dob ? so - dob : dob - so ))) d'ecart (fichiers modifies pendant la migration ?)"
      BILAN_MSG="bilan : meme nombre de fichiers, tailles differentes"
    fi
  fi
  echo "=== [$n] bilan : $v" >> "$MG_LOGF"
  # shellcheck disable=SC1090
  [ -f "$MG_STATE/avancement" ] && . "$MG_STATE/avancement"
  [ "$PG_ETAPE" = "$n" ] || { PG_ESSAIS=0; PG_ERREURS=0; PG_SURPLUS=0; }
  l="${PG_ESSAIS:-0} nouvel(s) essai(s) rclone · ${PG_ERREURS:-0} fichier(s) en erreur pendant le transfert"
  [ "${PG_ERREURS:-0}" -gt 0 ] && l="$l (liste : $MG_STATE/erreurs-$(safe "$lab").txt)"
  [ "${PG_SURPLUS:-0}" -gt 0 ] && l="$l · au moins $(hsize "$PG_SURPLUS") renvoyes"
  l="$l · $rep reprise(s) automatique(s) · duree $(hdur $(( $(date +%s) - t0 )))"
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
  [ -n "$PG_ETA" ] && l="$l · reste ~$(hdur "$PG_ETA")"
  l="$l · $(hsize "$PG_ENVOYE") envoyes${PG_REF_OCTETS:+ / source $(hsize "$PG_REF_OCTETS")}"
  [ -n "$PG_FICH_MIN" ] && l="$l · $PG_FICH_MIN fich/min, $(hsize "${PG_VITESSE:-0}")/s"
  [ "${PG_PROVISOIRE:-0}" = 1 ] && l="$l · parcours en cours"
  [ "${PG_SURPLUS:-0}" -gt 0 ] && l="$l · +$(hsize "$PG_SURPLUS") renvoyes"
  if [ "${PG_ESSAIS:-0}" -gt 0 ] || [ "${PG_ERREURS:-0}" -gt 0 ]; then l="$l · $PG_ESSAIS essai(s), $PG_ERREURS erreur(s)"; fi
  PG_LINE="$l"
}

cnt() { [ -s "$1" ] && grep -c '' "$1" || echo 0; }

# Controle dans oCIS les fichiers de <source> puis supprime du Synology ceux dont la
# copie est identique. Les fichiers en defaut (differents, absents d'oCIS, en erreur)
# sont renvoyes de force puis recontroles, jusqu'a VERIF_RENVOIS fois ; ceux qui restent
# en defaut sont gardes sur le Synology. Rien n'est supprime sans controle reussi.
# Renvoie 0 si tout est controle et supprime, 1 sinon. -> VERIF_MSG
verify_and_delete() {
  local s="$1" sub="$2" lab="$3" d crc nok=0 ndiff nmiss nerr dl="" k=0 hist
  d="$MG_STATE/verif-$(safe "$lab")"; rm -rf "$d"; mkdir -p "$d"
  hist="$MG_STATE/supprimes-$(date +%Y%m%d-%H%M%S)-$(safe "$lab").txt"
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
    ndiff=$(cnt "$d/diff"); nmiss=$(cnt "$d/absent"); nerr=$(cnt "$d/err")
    echo "=== [$i] controle${k:+ apres renvoi $k} : $(cnt "$d/ok") identique(s), $ndiff different(s), $nmiss absent(s) d'oCIS, $nerr erreur(s) (code $crc)" >> "$MG_LOGF"
  }
  delete_ok() {  # supprime du Synology les fichiers controles identiques a cette passe
    local n; n=$(cnt "$d/ok"); [ "$n" -gt 0 ] || return 0
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
    echo "=== [$i] renvoi $k/$VERIF_RENVOIS de $(cnt "$d/renvoi") fichier(s) en defaut (differents, absents ou en erreur)" >> "$MG_LOGF"
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
    VERIF_MSG="$nok fichier(s) controle(s) dans oCIS et supprime(s) du Synology"
    [ "$k" -gt 0 ] && VERIF_MSG="$VERIF_MSG (dont des fichiers renvoyes $k fois)"
    return 0
  fi
  VERIF_MSG="$nok controle(s) et supprime(s) ; gardes sur le Synology : $ndiff different(s), $nmiss absent(s) d'oCIS, $nerr erreur(s)"
  [ "$k" -gt 0 ] && VERIF_MSG="$VERIF_MSG apres $k renvoi(s)"
  [ "$ndiff$nmiss$nerr" = 000 ] && VERIF_MSG="$VERIF_MSG, controle interrompu (code $crc)"
  VERIF_MSG="$VERIF_MSG — listes dans $d"
  if [ $((ndiff + nmiss + nerr)) -gt 0 ]; then
    notify critique "Migration oCIS : fichiers gardés" \
      "$lab : $((ndiff + nmiss + nerr)) fichier(s) toujours en défaut après $k renvoi(s), gardé(s) sur le Synology (rien n'est supprimé). Liste : $d"
  fi
  return 1
}

mg_worker() {  # tourne en arriere-plan : traite le lot ligne par ligne
  load_conf
  local obs i=0 ok=0 ko=0 s l id n dav sub t del rc st refpid="" soff
  obs=$(rclone obscure "$OCIS_PASS")
  perf_load; MEMLIM="$PERF_MEM"
  {
    echo "=== $(rclone version 2>/dev/null | head -n 1) · GOMEMLIMIT=$MEMLIM · overcommit=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null)"
    echo "=== $(mem_info)"
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
    local why="" requeue=1 try=0 retryable errs err1 off tr=$PERF_T ck=$PERF_C
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
        MG_SUIVI="$i $soff $(safe "$l")" run_rclone copy "$s" "ocis:$sub" --create-empty-src-dirs "${MG_EXCL[@]}" "${RCLONE_K[@]}" \
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
      echo "=== [$i] arret de rclone : code $rc ($why) · rclone utilisait jusqu'a ${RSS_MAX:-?} Mo · $(mem_info)" >> "$MG_LOGF"
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
      ok=$((ok+1)); st=OK; requeue=0; why=""; [ $try -gt 1 ] && why="apres $((try-1)) reprise(s) automatique(s)"
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
      ko=$((ko+1)); st="ECHEC"; [ $try -gt 1 ] && why="$why, apres $((try-1)) reprise(s)"
    fi
    local d=$(( ($(date +%s) - t0) / 60 ))
    echo "$(date '+%Y-%m-%d %H:%M') | $st${why:+ ($why)} | $s -> $n${sub:+/$sub} | ${d} min" >> "$MG_HIST"
    echo "$i|$st|$l|$n${sub:+/$sub}|$why" >> "$MG_STATE/resultats"
    [ $requeue -eq 1 ] && echo "$s|$l|$id|$n|$dav|$sub|$t|$del" >> "$MG_QUEUE"   # remis en file pour reprise
  done < "$MG_STATE/lot"
  [ -n "$refpid" ] && { pkill -P "$refpid" 2>/dev/null; kill "$refpid" 2>/dev/null; }
  echo "$ok|$ko" > "$MG_STATE/code"
  local msg="$ok migration(s) reussie(s)"; [ $ko -gt 0 ] && msg="$msg, $ko en echec (remise(s) en file d'attente pour reprise)"
  if [ $ko -eq 0 ]; then notify info "Migration Drive -> oCIS terminée" "$msg."
  else notify critique "Migration Drive -> oCIS : erreurs" "$msg."; fi
}


# =========================== Suivi ===================================
mg_show_results() {  # affiche les resultats des migrations terminees pas encore affiches
  [ -f "$MG_STATE/resultats" ] || return 0
  local i st l n why k=0
  while IFS='|' read -r i st l n why; do
    k=$((k+1)); [ $k -le $shown ] && continue
    if [ "$st" = OK ]; then echo -e "   ${V}-> termine avec succes${why:+ ($why)}${N}"
    else echo -e "   ${R}-> ECHEC : $why${N}"; echo -e "   ${G}(remise en file d'attente, la suite continue)${N}"; fi
    shown=$k
  done < "$MG_STATE/resultats"
}

mg_follow() {
  [ -f "$MG_RUN" ] || { echo "Aucune migration lancee."; return; }
  . "$MG_RUN"
  trap 'echo; echo -e "${J}Suivi interrompu : la migration continue en arriere-plan.${N}"; echo "Reprendre le suivi :  sudo bash $SELF migration suivi"; exit 0' INT
  echo -e "${G}Ctrl+C = arreter le suivi (la migration continue)${N}"
  local last="" line pct n bar shown=0 shown_rep="" ram cols
  cols=$(( $(tput cols 2>/dev/null || echo 100) - 1 ))
  status() { printf "\r\e[K%s" "${1:0:$cols}"; }   # efface la ligne avant de la reecrire
  while kill -0 "$PID" 2>/dev/null; do
    if [ -f "$MG_STATE/etape" ]; then
      unset REPRISE PHASE; . "$MG_STATE/etape"
      if [ "$ETAPE" != "$last" ]; then
        shown_rep=""
        [ -n "$last" ] && { echo; mg_show_results; }
        echo -e "\n${B}[$ETAPE/$NB] $E_LABEL -> $E_SPACE${N}  ($(hsize "$E_TOTAL"))"
        last="$ETAPE"
      fi
      [ -n "${REPRISE:-}" ] && [ "${REPRISE}" != "${shown_rep:-}" ] && { echo; echo -e "   ${J}rclone s'est arrete : reprise automatique ${REPRISE}/$AUTO_REPRISE...${N}"; shown_rep="$REPRISE"; }
      ram=""; [ -f "$MG_STATE/rss" ] && ram=" · RAM rclone $(cut -d' ' -f1 "$MG_STATE/rss") Mo"
      case "${PHASE:-}" in
        verification|relecture)
          line=$(grep 'Checks:' "$MG_STATE/verif-$(safe "$E_LABEL")/check.log" 2>/dev/null | tail -n 1 | sed 's/.*Checks: *//; s/  */ /g')
          status " $( [ "$PHASE" = relecture ] && echo "Controle par relecture depuis oCIS" || echo "Controle des empreintes dans oCIS") : ${line:-demarrage...}$ram" ;;
        suppression)
          status " Suppression des originaux controles sur le Synology..." ;;
        bilan)
          status " Bilan : comptage des fichiers sur le Synology et dans oCIS..." ;;
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
    echo -e "${B}Bilan :${N}"
    while IFS='|' read -r i st l n why; do
      [ "$st" = OK ] && echo -e "  ${V}OK${N}     $l -> $n${why:+ : $why}" || echo -e "  ${R}ECHEC${N}  $l -> $n : $why"
    done < "$MG_STATE/resultats"
    if grep -q ECHEC "$MG_STATE/resultats"; then
      if grep -q 'quota' "$MG_STATE/resultats"; then
        echo; echo -e "${J}Espace plein : dans oCIS, ouvre l'espace > ⋯ > Modifier le quota > « Pas de restriction »."
        echo -e "(les nouveaux espaces ont 1 Go par defaut ; GRAPH_SPACES_DEFAULT_QUOTA=0 pour les suivants)${N}"
      fi
      if grep -q '401' "$MG_STATE/resultats"; then load_conf; echo; http_hint 401; fi
      echo -e "${J}Les migrations en echec (sauf dossier introuvable) sont remises en file d'attente : relance-les, elles reprendront.${N}"
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
  echo -e "${J}Migration arretee. Les migrations non terminees sont remises en file d'attente.${N}"
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
  IFS='|' read -r SP_ID SP_NAME SP_DAV SP_FREE SP_QUOTA <<< "$found"
  if [ -z "$lab" ]; then
    lab="${src##*/}"; [[ "$src" =~ /homes/([^/]+)/Drive$ ]] && lab="${BASH_REMATCH[1]}"
  fi
  local total
  total=$(du -sb --exclude='@eaDir' --exclude='#SynoRecycle' --exclude='.SynologyWorkingDirectory' "$src" 2>/dev/null | cut -f1)
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$src" "$lab" "$SP_ID" "$SP_NAME" "$SP_DAV" "$sub" "${total:-0}" "$del" >> "$MG_QUEUE"
  echo "Ajoute a la file d'attente : $lab -> $SP_NAME${sub:+/$sub} ($(hsize "${total:-0}"))"
  if [ "${SP_QUOTA:-0}" -gt 0 ] 2>/dev/null && [ "${total:-0}" -gt "${SP_FREE:-0}" ]; then
    echo "Attention : l'espace n'a que $(hsize "$SP_FREE") de libre (quota $(hsize "$SP_QUOTA")) : la migration s'arretera quand il sera plein."
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
  ensure_rclone
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
  ensure_rclone
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

mg_main() {
  NOTIFY_TAG=migre-ocis
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
if [ "$HTTP" != 200 ]; then clear; http_hint "$HTTP"; echo; pause
elif [ "${OCIS_VENDOR:-infinitescale}" = infinitescale ]; then
  clear
  echo -e "${J}Mise a jour : passage des envois en WebDAV classique.${N}"
  echo "Le mode oCIS natif de rclone fait exploser la memoire (bug connu) : c'est ce qui"
  echo "faisait tuer rclone par le systeme sur le NAS."
  ensure_rclone
  if detect_vendor; then
    sed -i "s/^OCIS_VENDOR=.*/OCIS_VENDOR=$OCIS_VENDOR/" "$MG_CONF"; load_conf
  fi
  pause
fi
while true; do
  clear
  echo -e "${B}===== MIGRATION SYNOLOGY DRIVE -> oCIS =====${N}"
  echo -e "oCIS : $OCIS_URL  (compte $OCIS_USER, mode ${OCIS_VENDOR:-infinitescale})"
  [ -n "${LOCAL_URL:-}" ] && echo -e "Transferts : ${V}reseau local${N} ($LOCAL_URL)" \
                          || echo -e "Transferts : ${J}via Internet${N} (menu 7 pour ajouter l'adresse locale)"
  if mg_running; then . "$MG_STATE/etape" 2>/dev/null; echo -e "${J}Migration en cours : ${E_LABEL:-...} (${ETAPE:-?}/$NB)${N}"; fi
  echo; echo -e "${B}File d'attente :${N}"; mg_show_queue; echo
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
    3) mg_start; pause ;;
    4) mg_follow; pause ;;
    5) mg_stop_run; sleep 2 ;;
    6) clear; tail -n 30 "$MG_HIST" 2>/dev/null || echo "Aucune migration."; pause ;;
    7) mg_setup_conf || pause ;;
    8) mg_add_verif; sleep 2 ;;
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

mg_init() {
  need_root
  mkdir -p "$MG_STATE" "$MG_BIN"; chmod 700 "$MG_STATE"
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
  printf '{"machine":"synology","arch":"%s","ram_total_mo":%s,"ram_dispo_mo":%s,"python3":%s,"rsync":%s,"curl":%s,"ssh":%s,"rclone":"%s","rclone_derniere":"%s","cle_omv":%s}\n' \
    "$(uname -m)" "$(ram_total_mo)" "$(ram_dispo_mo)" "$(b python3)" "$(b rsync)" "$(b curl)" "$(b ssh)" "$rc" \
    "$(cat "$SYNO_DIR/rclone-derniere" 2>/dev/null)" "$( [ -f "$CP_KEY" ] && echo true || echo false)"
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
      printf '{"omv":"%s","ha":"%s","webhook":"%s","profil":"%s","mo":"%s","transferts":"%s","verifs":"%s","effectif":{"profil":"%s","mo":%s,"options":"--transfers %s --checkers %s"},"ram_total_mo":%s,"ram_dispo_mo":%s}\n' \
        "$OMV_HOST" "$HA_HOST" "$HA_WEBHOOK" "$RAM_PROFIL" "$RAM_MO" "$TRANSFERTS" "$VERIFS" "$PERF_PROFIL" "$PERF_MO" "$PERF_T" "$PERF_C" "$(ram_total_mo)" "$(ram_dispo_mo)" ;;
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
    *) die "usage : nas-synology reglages voir | ram <profil> [Mo] [transferts] [verifs] | omv <adresse> | ha <adresse> <webhook>" ;;
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
    echo "  3) Outils, version et memoire de rclone"
    echo "  0) Quitter"
    read -r -p "Choix : " c
    case "$c" in
      1) bash "$SELF" copie ;;
      2) bash "$SELF" migration ;;
      3) clear; version_json; outils_etat; reglages voir; pause ;;
      0|q) exit 0 ;;
    esac
  done
}

# =========================== Point d'entree ==========================
syno_main() {
  case "${1:-}" in
    "")        need_root; menu_principal ;;
    copie)     shift; cp_main "$@" ;;
    migration) shift; mg_main "$@" ;;
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
    migrer)    migrer "${2:-simulation}" ;;
    *)         die "commande inconnue : $1 (copie, migration, version, outils, reglages, migrer)" ;;
  esac
}

case "$(basename "$0")" in
  copie-omv)        cp_main "$@" ;;
  migre-drive-ocis) mg_main "$@" ;;
  *)                syno_main "$@" ;;
esac
