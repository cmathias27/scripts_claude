#!/bin/bash
# =====================================================================
#  nas-backup : gestion des sauvegardes OMV -> Google Drive (rclone)
#
#  Lancement interactif (menu)  : nas-backup
#  Lancer une sauvegarde        : nas-backup run <NOM>
#  Lancer celles d'un horaire   : nas-backup run-at <HH:MM>   (utilise par cron)
#  Lancer toutes les sauvegardes: nas-backup run-all
#  Lister                       : nas-backup list
#
#  Prerequis : rclone + remote "gdrive" fonctionnel
#  Au premier lancement, le script s'installe dans /usr/local/bin/nas-backup
# =====================================================================
set -uo pipefail

# --------------------------- Parametres ------------------------------
GDRIVE="gdrive"                  # remote Google Drive deja configure
CRYPT="gbackup"                  # remote chiffre (cree si absent)
CRYPT_FOLDER="NAS-chiffre"       # dossier Drive des sauvegardes chiffrees
PLAIN_FOLDER="NAS"               # dossier Drive des sauvegardes non chiffrees
DEFAULT_RET=30                   # jours de corbeille par defaut
DEFAULT_SCHED="03:30"            # horaire par defaut
CAM_PASS="/root/cam-crypt-motsdepasse.txt"   # mots de passe reutilises si presents
PASSFILE="/root/nas-backup-motsdepasse.txt"
# ---------------------------------------------------------------------

CONF_DIR="/etc/nas-backup"
JOBS="$CONF_DIR/jobs.conf"
STATE_DIR="/var/lib/nas-backup"
LOG="/var/log/nas-backup.log"
CRON_FILE="/etc/cron.d/nas-backup"
SELF="/usr/local/bin/nas-backup"
EXCLUDES=(--exclude '@eaDir/**' --exclude '\#recycle/**' --exclude '.Trash-*/**')

vert()  { echo -e "\e[32m$*\e[0m"; }
jaune() { echo -e "\e[33m$*\e[0m"; }
rouge() { echo -e "\e[31m$*\e[0m"; }
gras()  { echo -e "\e[1m$*\e[0m"; }
die()   { rouge "ERREUR : $*"; exit 1; }
logl()  { echo "$(date '+%Y-%m-%d %H:%M:%S') [nas-backup] $*" >> "$LOG"; }
notify() { [ -x /usr/local/bin/nas-notify ] && /usr/local/bin/nas-notify "$@"; return 0; }   # alertes Home Assistant
ha_status() { [ -x /usr/local/bin/nas-ha-status ] && /usr/local/bin/nas-ha-status >/dev/null 2>&1; return 0; }  # tableau de bord HA
rd_() { local p="$1"; shift; read -r -p "$p" "$@" || { echo; exit 0; }; }
pause() { echo; rd_ "Entree pour continuer..." _; }

# =========================== Initialisation ==========================
init() {
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  command -v rclone >/dev/null || die "rclone n'est pas installe."
  rclone listremotes | grep -qx "${GDRIVE}:" || die "remote '${GDRIVE}' introuvable (rclone listremotes)."
  mkdir -p "$CONF_DIR" "$STATE_DIR"
  [ -f "$JOBS" ] || echo "# NOM|SOURCE|DOSSIER_DRIVE|MODE(sync/copy)|CHIFFRE(oui/non)|HORAIRE(HH:MM/manuel)|CORBEILLE_JOURS" > "$JOBS"
  touch "$LOG"
  if [ ! -f /etc/logrotate.d/nas-backup ]; then
    printf "%s {\n  weekly\n  rotate 8\n  compress\n  missingok\n  notifempty\n  copytruncate\n}\n" "$LOG" > /etc/logrotate.d/nas-backup
  fi
}

self_install() {
  local me; me=$(readlink -f "$0")
  if [ "$me" != "$SELF" ]; then
    install -m 755 "$me" "$SELF"
    vert "Script installe dans $SELF : tu pourras le relancer simplement avec la commande 'nas-backup'."
    echo
  fi
}

ensure_crypt() {
  rclone listremotes | grep -qx "${CRYPT}:" && return 0
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

# =========================== Gestion des taches ======================
job_names() { grep -v '^#' "$JOBS" | grep -v '^$' | cut -d'|' -f1; }
job_exists() { grep -q "^$1|" "$JOBS"; }

job_get() {
  local line; line=$(grep -m1 "^$1|" "$JOBS") || return 1
  IFS='|' read -r J_NAME J_SRC J_SUB J_MODE J_ENC J_SCHED J_RET <<< "$line"
}

job_save() {
  local tmp; tmp=$(mktemp)
  grep -v "^$J_NAME|" "$JOBS" > "$tmp"
  echo "$J_NAME|$J_SRC|$J_SUB|$J_MODE|$J_ENC|$J_SCHED|$J_RET" >> "$tmp"
  cat "$tmp" > "$JOBS"; rm -f "$tmp"
}

job_del() {
  local tmp; tmp=$(mktemp)
  grep -v "^$1|" "$JOBS" > "$tmp"; cat "$tmp" > "$JOBS"; rm -f "$tmp"
  rm -f "$STATE_DIR/$1.status" "$STATE_DIR/$1.lastok" "$STATE_DIR/alertes/job-$1" "$STATE_DIR/alertes/retard-$1"
}

dest_of()  { [ "$1" = oui ] && echo "${CRYPT}:$2" || echo "${GDRIVE}:${PLAIN_FOLDER}/$2"; }
trash_of() { [ "$1" = oui ] && echo "${CRYPT}:_corbeille/$2" || echo "${GDRIVE}:${PLAIN_FOLDER}/_corbeille/$2"; }
short()    { echo "$1" | sed -E 's#^/srv/dev-disk-by-uuid-[^/]+/#…/#'; }

gen_cron() {
  {
    echo "# Genere automatiquement par nas-backup - ne pas modifier a la main"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    # Une seule ligne par horaire : les sauvegardes prevues a la meme heure
    # sont lancees l'une apres l'autre (run-at), pas toutes en meme temps
    local n s sub m e sch r h mi
    local -A seen=()
    while IFS='|' read -r n s sub m e sch r || [ -n "$n" ]; do
      [[ -z "$n" || "$n" == \#* || "$sch" == manuel ]] && continue
      [ -n "${seen[$sch]:-}" ] && continue
      seen[$sch]=1
      h=${sch%%:*}; mi=${sch##*:}
      echo "$((10#$mi)) $((10#$h)) * * * root $SELF run-at $sch >/dev/null 2>&1"
    done < "$JOBS"
  } > "$CRON_FILE"
  chmod 644 "$CRON_FILE"
  ha_status
}

# =========================== Saisie ==================================
ask() {  # ask "Question" "defaut" -> ANS
  local q="$1" d="${2:-}"
  if [ -n "$d" ]; then rd_ "$q [$d] : " ANS; ANS="${ANS:-$d}"
  else rd_ "$q : " ANS; fi
}

ask_yn() {  # ask_yn "Question" o|n -> 0 si oui
  local d="${2:-n}" a
  rd_ "$1 [$( [ "$d" = o ] && echo O/n || echo o/N )] : " a
  a="${a:-$d}"; [[ "$a" =~ ^[oOyY] ]]
}

pick_source() {  # pick_source "defaut" -> ANS
  local def="${1:-}" i=1 d choice
  local -a dirs=()
  for d in /srv/dev-disk-by-uuid-*/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; [[ "$(basename "$d")" =~ ^(lost\+found|@eaDir|\#recycle)$ ]] && continue
    dirs+=("$d")
  done
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

form() {  # remplit J_* (valeurs actuelles = defauts)
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
    ask "Horaire quotidien HH:MM, ou 'manuel'" "${J_SCHED:-$DEFAULT_SCHED}"
    if [ "$ANS" = manuel ] || [[ "$ANS" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then J_SCHED="$ANS"; break; fi
    rouge "Format invalide (ex : 03:30 ou manuel)."
  done
}

check_overlap() {  # avertit si une autre tache ecrit au meme endroit
  local n s sub m e sch r
  while IFS='|' read -r n s sub m e sch r; do
    [[ -z "$n" || "$n" == \#* || "$n" == "$J_NAME" ]] && continue
    if [ "$e" = "$J_ENC" ] && { [[ "$sub" == "$J_SUB" ]] || [[ "$sub" == "$J_SUB/"* ]] || [[ "$J_SUB" == "$sub/"* ]]; }; then
      jaune "Attention : la sauvegarde '$n' utilise deja le dossier Drive '$sub'."
      ask_yn "Continuer quand meme ?" n || return 1
    fi
  done < "$JOBS"
  return 0
}

# =========================== Actions =================================
list_jobs() {
  if [ -z "$(job_names)" ]; then jaune "Aucune sauvegarde configuree."; return; fi
  printf "\e[1m%-14s %-24s %-24s %-7s %-6s %-8s %s\e[0m\n" "NOM" "SOURCE" "DRIVE" "MODE" "CHIFFRE" "HORAIRE" "DERNIERE EXECUTION"
  local n s sub m e sch r st mode
  while IFS='|' read -r n s sub m e sch r; do
    [[ -z "$n" || "$n" == \#* ]] && continue
    st="jamais"; [ -f "$STATE_DIR/$n.status" ] && st=$(cat "$STATE_DIR/$n.status")
    mode="copie"; [ "$m" = sync ] && mode="miroir"
    printf "%-14s %-24s %-24s %-7s %-7s %-8s %s\n" "$n" "$(short "$s")" "$( [ "$e" = oui ] && echo "$CRYPT_FOLDER" || echo "$PLAIN_FOLDER")/$sub" "$mode" "$e" "$sch" "$st"
  done < "$JOBS"
}

choose_job() {  # -> ANS = nom
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
  J_NAME="" J_SRC="" J_SUB="" J_MODE="" J_ENC="" J_SCHED="" J_RET=""
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

run_job() {
  job_get "$1" || { rouge "Sauvegarde '$1' introuvable."; return 1; }
  local dest trash jour rc
  dest=$(dest_of "$J_ENC" "$J_SUB"); trash=$(trash_of "$J_ENC" "$J_NAME"); jour=$(date +%Y-%m-%d_%H%M)
  local -a opts=("${EXCLUDES[@]}" --log-file "$LOG" --log-level INFO)
  [ -t 1 ] && opts+=(-P)

  if [ ! -d "$J_SRC" ]; then
    rouge "Source introuvable : $J_SRC"; logl "$J_NAME : ECHEC (source introuvable)"
    echo "$(date '+%Y-%m-%d %H:%M') ECHEC" > "$STATE_DIR/$J_NAME.status"
    notify critique "job-$J_NAME" "Sauvegarde « $J_NAME » en échec" "Dossier source introuvable : $J_SRC (disque démonté ?)"
    return 1
  fi
  [ "$J_ENC" = oui ] && ensure_crypt

  local t0; t0=$(date +%s)
  gras "-> $J_NAME : $(short "$J_SRC")  =>  $dest"
  logl "$J_NAME : debut ($J_MODE) $J_SRC -> $dest"
  if [ "$J_MODE" = sync ]; then
    if [ "${J_RET:-0}" -gt 0 ]; then
      rclone sync "$J_SRC" "$dest" --backup-dir "$trash/$jour" "${opts[@]}"; rc=$?
      rclone delete "$trash" --min-age "${J_RET}d" -q 2>/dev/null
      rclone rmdirs "$trash" --leave-root -q 2>/dev/null
    else
      rclone sync "$J_SRC" "$dest" "${opts[@]}"; rc=$?
    fi
  else
    rclone copy "$J_SRC" "$dest" "${opts[@]}"; rc=$?
  fi

  local duree=$(( ($(date +%s) - t0) / 60 ))
  if [ "$rc" -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M') OK" > "$STATE_DIR/$J_NAME.status"
    date +%s > "$STATE_DIR/$J_NAME.lastok"
    logl "$J_NAME : OK"; vert "OK : $J_NAME"
    notify succes "job-$J_NAME" "Sauvegarde « $J_NAME »" "Terminée avec succès en ${duree} min."
  else
    echo "$(date '+%Y-%m-%d %H:%M') ECHEC" > "$STATE_DIR/$J_NAME.status"
    logl "$J_NAME : ECHEC (code $rc)"; rouge "ECHEC : $J_NAME (voir $LOG)"
    local err; err=$(tail -n 300 "$LOG" | grep -E 'ERROR|CRITICAL' | tail -n 1 | sed -E 's/^[0-9\/ :]+//' | cut -c1-200)
    notify critique "job-$J_NAME" "Sauvegarde « $J_NAME » en échec" "Code $rc. ${err:-Voir $LOG sur le NAS.}"
  fi
  ha_status
  return "$rc"
}

run_job_locked() {
  ( flock -n 9 || { jaune "La sauvegarde '$1' est deja en cours."; exit 1; }
    run_job "$1" ) 9>"/run/nas-backup-$1.lock"
}

run_at() {  # lance l'une apres l'autre les sauvegardes prevues a l'horaire $1 (utilise par cron)
  local n rc=0
  for n in $(job_names); do
    job_get "$n" || continue
    [ "$J_SCHED" = "$1" ] && { run_job_locked "$n" || rc=1; }
  done
  return $rc
}

run_all() {
  local n rc=0
  for n in $(job_names); do run_job_locked "$n" || rc=1; done
  return $rc
}

restore_job() {
  gras "== Restaurer une sauvegarde =="
  choose_job "Laquelle" || return
  job_get "$ANS"
  local dest base target
  dest=$(dest_of "$J_ENC" "$J_SUB")
  base=$(echo "$J_SRC" | grep -oE '^/srv/dev-disk-by-uuid-[^/]+' || dirname "$J_SRC")
  ask "Dossier de restauration" "$base/Restauration/${J_NAME}_$(date +%Y-%m-%d_%H%M)"
  target="${ANS%/}"
  if [ "$target" = "$J_SRC" ]; then
    jaune "Restaurer directement dans le dossier source ecrasera les fichiers locaux."
    ask_yn "Continuer ?" n || return
  fi
  mkdir -p "$target"
  rclone copy "$dest" "$target" "${EXCLUDES[@]}" -P && vert "Restauration terminee : $target" || rouge "Echec de la restauration."
}

show_log() {
  tail -n 40 "$LOG"
  echo
  ask_yn "Suivre en direct (Ctrl+C pour arreter) ?" n && tail -f "$LOG"
}

menu() {
  while true; do
    clear
    gras "========== SAUVEGARDES NAS -> GOOGLE DRIVE =========="
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
    echo "  0) Quitter"
    echo
    rd_ "Choix : " c
    echo
    case "$c" in
      1) add_job; pause ;;
      2) edit_job; pause ;;
      3) delete_job; pause ;;
      4) choose_job "Laquelle" && run_job_locked "$ANS"; pause ;;
      5) run_all; pause ;;
      6) restore_job; pause ;;
      7) show_log; pause ;;
      0|q|Q) exit 0 ;;
      *) ;;
    esac
  done
}

# =========================== Point d'entree ==========================
init
case "${1:-}" in
  "")       self_install; gen_cron; menu ;;
  run)      [ -n "${2:-}" ] || die "usage : nas-backup run <NOM>"; run_job_locked "$2" ;;
  run-at)   [ -n "${2:-}" ] || die "usage : nas-backup run-at <HH:MM>"; run_at "$2" ;;
  run-all)  run_all ;;
  list)     list_jobs ;;
  *)        echo "Usage : nas-backup [run <NOM> | run-at <HH:MM> | run-all | list]"; exit 1 ;;
esac
