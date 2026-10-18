#!/bin/bash
# =====================================================================
#  copie-omv.sh : copie (ou deplacement) d'un dossier du NAS Synology
#                 vers l'OMV, avec suivi de l'avancement en direct.
#
#  Lancement (en SSH sur le Synology) :  sudo bash copie-omv.sh
#    sans argument : menu
#    suivi         : reprendre l'affichage de la copie en cours
#    stop          : arreter la copie en cours
#  Sans question (application Windows NAS Manager) :
#    lancer <source> <dossier OMV> <dossier|contenu> <copie|deplacement> [debit Ko/s]
#    arreter
#    ajouter <source> <dossier OMV> <dossier|contenu> <copie|deplacement> [debit]  (file d'attente)
#    retirer <n> | lancer-file
#
#  La copie tourne en arriere-plan : fermer la fenetre SSH ou faire
#  Ctrl+C pendant le suivi ne l'arrete PAS. Une copie interrompue
#  reprend la ou elle s'etait arretee si on la relance.
# =====================================================================
set -o pipefail

# --------------------------- Parametres ------------------------------
OMV_HOST="192.168.1.190"          # adresse de l'OMV
OMV_USER="root"
OMV_ROOT="/srv"                   # point de depart pour choisir la destination
HA_HOST="192.168.1.222"           # Home Assistant (notification de fin), vide = pas de notification
HA_WEBHOOK="nas-c09f382daf2d01deb430abbd"
# ---------------------------------------------------------------------

SELF=$(readlink -f "$0")
STATE="/root/.copie-omv"
KEY="/root/.ssh/id_copie_omv"
RUN="$STATE/en-cours"             # infos de la copie en cours
LOGF="$STATE/progression.log"
HIST="$STATE/historique.log"
SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
EXCL=(--exclude '@eaDir/' --exclude '#recycle/' --exclude '#snapshot/' --exclude '.DS_Store' --exclude 'Thumbs.db' --exclude '@SynoResource')

B="\e[1m"; V="\e[32m"; J="\e[33m"; R="\e[31m"; G="\e[90m"; N="\e[0m"
die() { echo -e "${R}ERREUR : $*${N}"; exit 1; }
osh() { ssh "${SSH_OPTS[@]}" "$OMV_USER@$OMV_HOST" "$@"; }
q()   { printf '%q' "$1"; }
hsize() { awk -v b="$1" 'BEGIN{split("o Ko Mo Go To",u);i=1;while(b>=1024&&i<5){b/=1024;i++};printf (i==1?"%d %s":"%.1f %s"),b,u[i]}'; }

[ "$(id -u)" -eq 0 ] || die "lance le script avec sudo :  sudo bash $0"
mkdir -p "$STATE" /root/.ssh; chmod 700 /root/.ssh
command -v rsync >/dev/null || die "rsync introuvable sur le NAS."

# --------------------------- Cle SSH vers l'OMV ----------------------
ensure_ssh() {
  [ -f "$KEY" ] || ssh-keygen -t ed25519 -N "" -C "copie-omv@$(hostname)" -f "$KEY" -q
  if ! osh true 2>/dev/null; then
    echo -e "${J}Premiere connexion a l'OMV : autorisation de la cle SSH du NAS.${N}"
    echo "Tape le mot de passe de $OMV_USER sur l'OMV (une seule fois) :"
    ssh -o StrictHostKeyChecking=accept-new "$OMV_USER@$OMV_HOST" \
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" < "$KEY.pub" \
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
# browse <local|omv> <dossier de depart> <titre>  -> CHOIX
browse() {
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
running() { [ -f "$RUN" ] && . "$RUN" && kill -0 "$PID" 2>/dev/null; }

notify() {  # notify <critique|info> <titre> <message>
  [ -n "$HA_HOST" ] || return 0
  local body; body=$(printf '{"title":"%s","message":"%s","tag":"copie-omv"}' "${2//\"/\'}" "${3//\"/\'}")
  for u in "http://$HA_HOST:8123" "http://$HA_HOST"; do
    curl -s -m 8 -o /dev/null -f -X POST -H 'Content-Type: application/json' -d "$body" "$u/api/webhook/${HA_WEBHOOK}-$1" && return 0
  done
  return 0
}

# --------------------------- Affichage du suivi ----------------------
follow() {
  running || { [ -f "$RUN" ] && . "$RUN"; }
  [ -f "$RUN" ] || { echo "Aucune copie lancee."; return; }
  . "$RUN"
  trap 'echo; echo -e "${J}Suivi interrompu. La copie continue en arriere-plan.${N}"; echo "Reprendre le suivi :  sudo bash $0 suivi"; exit 0' INT
  echo -e "${B}Copie : ${N}$SRC"
  echo -e "${B}Vers  : ${N}$OMV_HOST:$DST"
  echo -e "${B}Mode  : ${N}$MODE · $(hsize "$TOTAL") · $NBF fichiers"
  echo -e "${G}Ctrl+C = arreter le suivi (la copie continue)${N}"
  echo
  local line pct bar
  while kill -0 "$PID" 2>/dev/null; do
    line=$(tail -c 2000 "$LOGF" 2>/dev/null | tr '\r' '\n' | grep -E '[0-9]+%' | tail -n 1)
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
  local rc; rc=$(cat "$STATE/code" 2>/dev/null || echo "?")
  if [ "$rc" = 0 ]; then
    echo -e "${V}${B}$( [ "$MODE" = deplacement ] && echo "Deplacement" || echo "Copie") terminee avec succes.${N}"
  else
    echo -e "${R}${B}La copie s'est terminee avec une erreur (code $rc).${N}"
    echo "Dernieres lignes du journal :"
    tr '\r' '\n' < "$LOGF" | grep -v -E '^\s*$|[0-9]+%' | tail -n 8
    echo -e "${J}Relancer la meme copie reprendra la ou elle s'est arretee.${N}"
  fi
  trap - INT
}

# --------------------------- Lancement (commun menu / application) ---
# start_copy <source> <dossier OMV parent> <source rsync> <destination finale> <copie|deplacement> <total> <nb fichiers> [debit Ko/s]
start_copy() {
  local src="$1" dst="$2" rsrc="$3" final="$4" mode="$5" total="$6" nbf="$7" bw="${8:-}"
  # Droits OMV : les fichiers prennent le proprietaire et le groupe du dossier
  # de destination (dossiers 2775, fichiers 664) au lieu des droits Synology
  local own; own=$(osh "stat -c %U:%G $(q "$dst")" 2>/dev/null); own="${own:-root:users}"
  [ "${own#*:}" = root ] && own="${own%%:*}:users"
  local -a extra=(-p "--chmod=D2775,F664" "--chown=$own")
  [ -n "$bw" ] && extra+=("--bwlimit=$bw")
  [ "$mode" = deplacement ] && extra+=(--remove-source-files)
  cat > "$RUN" <<EOF
SRC=$(q "$src")
DST=$(q "$final")
MODE=$mode
TOTAL=${total:-0}
NBF=$nbf
BW=$bw
DEBUT=$(date +%s)
EOF
  : > "$LOGF"; rm -f "$STATE/code"

  # Copie en arriere-plan, independante de la session SSH
  nohup setsid bash -c '
    rsync -rlt --partial --no-inc-recursive --info=progress2 --human-readable \
      "${@:6}" -e "ssh ${5}" "$1" "$2:$3/" >>"'"$LOGF"'" 2>&1
    rc=$?
    echo $rc > "'"$STATE/code"'"
    if [ $rc -eq 0 ] && [ "$4" = deplacement ]; then
      find "$1" -mindepth 1 -depth -type d -empty -delete 2>/dev/null
    fi
  ' _ "$rsrc" "$OMV_USER@$OMV_HOST" "$dst" "$mode" "${SSH_OPTS[*]}" "${EXCL[@]}" "${extra[@]}" >/dev/null 2>&1 &
  echo "PID=$!" >> "$RUN"

  # Surveillance de fin (historique + notification Home Assistant),
  # independante elle aussi de la session SSH
  nohup setsid bash "$SELF" _fin >/dev/null 2>&1 &

  echo "Copie lancee : $src -> $OMV_HOST:$final ($mode)"
}

# --------------------------- Nouvelle copie --------------------------
new_copy() {
  if running; then echo -e "${J}Une copie est deja en cours.${N}"; follow; return; fi
  ensure_ssh

  browse local "/" "Dossier a copier (NAS)" || return
  local src="$CHOIX"
  local start; start=$(osh "ls -d $OMV_ROOT/dev-disk-by-uuid-* 2>/dev/null | head -n 1"); start="${start:-$OMV_ROOT}"
  browse omv "$start" "Destination sur l'OMV" || return
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

  start_copy "$src" "$dst" "$rsrc" "$final" "$mode" "${total:-0}" "$nbf" >/dev/null
  echo -e "${V}Copie lancee.${N}"; sleep 1
  follow
}

fix_perms() {
  ensure_ssh
  local start; start=$(osh "ls -d $OMV_ROOT/dev-disk-by-uuid-* 2>/dev/null | head -n 1"); start="${start:-$OMV_ROOT}"
  browse omv "$start" "Dossier dont reparer les droits (OMV)" || return
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

stop_copy() {
  running || { echo "Aucune copie en cours."; return; }
  . "$RUN"
  read -r -p "Arreter la copie de « ${SRC##*/} » ? [o/N] : " c
  [[ "$c" =~ ^[oOyY] ]] || return
  echo stop > "$STATE/code.stop"
  pkill -TERM -s "$(ps -o sid= -p "$PID" | tr -d ' ')" 2>/dev/null || kill "$PID"
  sleep 1; mv -f "$STATE/code.stop" "$STATE/code"
  echo -e "${J}Copie arretee. La relancer reprendra la ou elle s'est arretee.${N}"
}

# --------------------------- Commandes sans question -----------------
# Utilisees par l'application Windows "NAS Manager".
API_VERSION=2

api_launch() {  # api_launch <source NAS> <dossier OMV> <dossier|contenu> <copie|deplacement> [debit Ko/s]
  local src="${1%/}" dst="${2%/}" place="${3:-dossier}" mode="${4:-copie}" bw="${5:-}"
  [[ -z "$bw" || "$bw" =~ ^[0-9]+$ ]] || die "limite de debit invalide (Ko/s)."
  running && die "une copie est deja en cours."
  [ -d "$src" ] || die "dossier source introuvable : $src"
  [[ "$mode" =~ ^(copie|deplacement)$ ]] || die "mode invalide (copie ou deplacement)."
  [ -f "$KEY" ] && osh true 2>/dev/null \
    || die "la connexion automatique NAS -> OMV n'est pas configuree : lance une fois 'sudo bash copie-omv.sh' en SSH (Nouvelle copie) pour autoriser la cle."
  osh "[ -d $(q "$dst") ]" || die "dossier introuvable sur l'OMV : $dst"
  osh "command -v rsync >/dev/null" || osh "apt-get install -y -qq rsync >/dev/null" || die "rsync manquant sur l'OMV."
  local rsrc="$src" final="$dst/${src##*/}"
  [ "$place" = contenu ] && { rsrc="$src/"; final="$dst"; }
  local total nbf
  total=$(du -sb --exclude='@eaDir' --exclude='#recycle' "$src" 2>/dev/null | cut -f1)
  nbf=$(find "$src" -type f ! -path '*/@eaDir/*' ! -path '*/#recycle/*' 2>/dev/null | wc -l)
  start_copy "$src" "$dst" "$rsrc" "$final" "$mode" "${total:-0}" "$nbf" "$bw"
}

# File d'attente : copies lancees l'une apres l'autre (source|destination|placement|mode|debit)
QUEUE="$STATE/file-attente"

api_queue_add() {  # api_queue_add <source> <dossier OMV> <dossier|contenu> <copie|deplacement> [debit]
  local src="${1%/}" dst="${2%/}" place="${3:-dossier}" mode="${4:-copie}" bw="${5:-}"
  [ -d "$src" ] || die "dossier source introuvable : $src"
  [[ "$mode" =~ ^(copie|deplacement)$ && "$place" =~ ^(dossier|contenu)$ ]] || die "parametres invalides."
  [[ -z "$bw" || "$bw" =~ ^[0-9]+$ ]] || die "limite de debit invalide (Ko/s)."
  [[ "$src$dst" == *"|"* ]] && die "caractere | interdit."
  echo "$src|$dst|$place|$mode|$bw" >> "$QUEUE"
  echo "Ajoute a la file d'attente : ${src##*/} -> $dst"
}

api_queue_remove() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le "$(grep -c '' "$QUEUE" 2>/dev/null || echo 0)" ] || die "numero invalide."
  sed -i "${1}d" "$QUEUE"; echo "Retire de la file d'attente."
}

# lance la premiere copie de la file (rien si une copie tourne deja)
api_queue_next() {
  running && { echo "Une copie est en cours : la file continuera apres elle."; return 0; }
  [ -s "$QUEUE" ] || { echo "File d'attente vide."; return 0; }
  local line s d p m b
  line=$(head -n 1 "$QUEUE"); sed -i '1d' "$QUEUE"
  IFS='|' read -r s d p m b <<< "$line"
  api_launch "$s" "$d" "$p" "$m" "$b"
}

api_stop() {
  running || { echo "Aucune copie en cours."; return 0; }
  echo stop > "$STATE/code.stop"
  pkill -TERM -s "$(ps -o sid= -p "$PID" | tr -d ' ')" 2>/dev/null || kill "$PID"
  sleep 1; mv -f "$STATE/code.stop" "$STATE/code"
  echo "Copie arretee. La relancer reprendra la ou elle s'est arretee."
}

# --------------------------- Point d'entree --------------------------
case "${1:-}" in
  lancer)      api_launch "${2:-}" "${3:-}" "${4:-dossier}" "${5:-copie}" "${6:-}"; exit ;;
  ajouter)     api_queue_add "${2:-}" "${3:-}" "${4:-dossier}" "${5:-copie}" "${6:-}"; exit ;;
  retirer)     api_queue_remove "${2:-}"; exit ;;
  lancer-file) api_queue_next; exit ;;
  arreter)     api_stop; exit ;;
  api-version) echo "$API_VERSION"; exit ;;
esac
case "${1:-}" in
  suivi) follow; exit ;;
  stop)  stop_copy; exit ;;
  _fin)
    . "$RUN"
    while kill -0 "$PID" 2>/dev/null; do sleep 5; done
    sleep 2
    rc=$(cat "$STATE/code" 2>/dev/null || echo "?")
    echo "$(date '+%Y-%m-%d %H:%M') | $(case "$rc" in 0) echo OK;; stop) echo ARRETEE;; *) echo "ECHEC ($rc)";; esac) | $MODE | $SRC -> $DST | $(( ($(date +%s) - DEBUT) / 60 )) min" >> "$HIST"
    if [ "$rc" = stop ]; then
      :
    elif [ "$rc" = 0 ]; then
      notify info "Copie vers l'OMV terminée" "« ${SRC##*/} » ($(hsize "$TOTAL"), $MODE) est sur l'OMV dans $DST."
    else
      notify critique "Copie vers l'OMV en échec" "« ${SRC##*/} » : erreur code $rc. Relancer la copie reprendra où elle s'est arrêtée."
    fi
    # copie suivante de la file d'attente (seulement apres un succes)
    if [ "$rc" = 0 ] && [ -s "$STATE/file-attente" ]; then
      bash "$SELF" lancer-file >> "$STATE/file-attente.log" 2>&1
    fi
    exit ;;
esac

while true; do
  clear
  echo -e "${B}===== COPIE NAS -> OMV ($OMV_HOST) =====${N}"
  if running; then
    . "$RUN"; echo -e "${J}Copie en cours : ${SRC##*/} -> $DST${N}"
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
    1) new_copy; read -r -p "Entree pour revenir au menu..." _ ;;
    2) follow;   read -r -p "Entree pour revenir au menu..." _ ;;
    3) stop_copy; sleep 2 ;;
    4) clear; tail -n 20 "$HIST" 2>/dev/null || echo "Aucune copie."; read -r -p "Entree..." _ ;;
    5) fix_perms; read -r -p "Entree pour revenir au menu..." _ ;;
    0|q) exit 0 ;;
  esac
done
