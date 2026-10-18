#!/bin/bash
# =====================================================================
#  nas-backup : gestion des sauvegardes OMV -> Google Drive (rclone)
#
#  Lancement interactif (menu)  : nas-backup
#  Lancer une sauvegarde        : nas-backup run <NOM>
#  Lancer celles d'un horaire   : nas-backup run-at <HH:MM>   (utilise par cron)
#  Lancer toutes les sauvegardes: nas-backup run-all
#  Arreter celles en cours      : nas-backup stop
#  Lister                       : nas-backup list
#
#  Commandes sans question (utilisees par l'application Windows NAS Manager) :
#    nas-backup save <nouveau|modif> NOM SOURCE DOSSIER sync|copy oui|non HH:MM|manuel JOURS
#    nas-backup delete <NOM> [effacer-drive]
#    nas-backup restore <NOM> <DOSSIER>
#    nas-backup gen-cron
#    nas-backup stop <NOM>          (arret d'une seule sauvegarde)
#    nas-backup simulate <NOM>      (ce qui serait envoye / supprime, sans rien faire)
#  Horaire : HH:MM, HH:MM/JOURS (1 = lundi, ex. 03:30/135), plusieurs separes par ;, ou manuel
#
#  Prerequis : rclone + remote "gdrive" fonctionnel
#  Au premier lancement, le script s'installe dans /usr/local/bin/nas-backup
#
#  Suivi Home Assistant : bilan de chaque transfert (fichiers, volume,
#  duree, erreurs) et avancement en direct publies via nas-ha-status.
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
HA_LIVE=60                       # avancement publie dans Home Assistant toutes les X secondes
# ---------------------------------------------------------------------

CONF_DIR="/etc/nas-backup"
JOBS="$CONF_DIR/jobs.conf"
STATE_DIR="/var/lib/nas-backup"
LOG="/var/log/nas-backup.log"
CRON_FILE="/etc/cron.d/nas-backup"
SELF="/usr/local/bin/nas-backup"
STOPF="$STATE_DIR/stop"          # present = arret demande (nas-backup stop)
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
    # copie puis mv (atomique) : une sauvegarde deja en cours garde l'ancienne version
    install -m 755 "$me" "$SELF.new" && mv -f "$SELF.new" "$SELF"
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
  IFS='|' read -r J_NAME J_SRC J_SUB J_MODE J_ENC J_SCHED J_RET J_BW <<< "$line"
}

job_save() {
  local tmp; tmp=$(mktemp)
  grep -v "^$J_NAME|" "$JOBS" > "$tmp"
  echo "$J_NAME|$J_SRC|$J_SUB|$J_MODE|$J_ENC|$J_SCHED|$J_RET|${J_BW:-}" >> "$tmp"
  cat "$tmp" > "$JOBS"; rm -f "$tmp"
}

job_del() {
  local tmp; tmp=$(mktemp)
  grep -v "^$1|" "$JOBS" > "$tmp"; cat "$tmp" > "$JOBS"; rm -f "$tmp"
  rm -f "$STATE_DIR/$1.status" "$STATE_DIR/$1.lastok" "$STATE_DIR/alertes/job-$1" "$STATE_DIR/alertes/retard-$1" \
        "$STATE_DIR/$1.bilan.json" "$STATE_DIR/$1.run.log" "$STATE_DIR/$1.running"
}

dest_of()  { [ "$1" = oui ] && echo "${CRYPT}:$2" || echo "${GDRIVE}:${PLAIN_FOLDER}/$2"; }
trash_of() { [ "$1" = oui ] && echo "${CRYPT}:_corbeille/$2" || echo "${GDRIVE}:${PLAIN_FOLDER}/_corbeille/$2"; }
short()    { echo "$1" | sed -E 's#^/srv/dev-disk-by-uuid-[^/]+/#…/#'; }

# Horaire d'une sauvegarde : "manuel", ou un ou plusieurs creneaux separes par ";"
#   HH:MM          tous les jours
#   HH:MM/JOURS    certains jours (chiffres 1 a 7, 1 = lundi) : 03:30/135 = lun, mer, ven
valid_sched() {
  [ "$1" = manuel ] && return 0
  [ -n "$1" ] || return 1
  local IFS=';' sl
  for sl in $1; do [[ "$sl" =~ ^([01][0-9]|2[0-3]):[0-5][0-9](/[1-7]+)?$ ]] || return 1; done
  return 0
}

# slot_matches <horaire> <HH:MM> <jour 1-7> : la sauvegarde est-elle prevue a cet instant ?
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

# max_age <horaire> : heures sans succes au-dela desquelles la sauvegarde est en retard
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

# nas-check (install-alertes.sh) : seuil de retard propre a chaque sauvegarde
patch_nas_check() {
  local f=/usr/local/bin/nas-check
  [ -f "$f" ] || return 0
  grep -q 'if \[ "$age" -ge "${LATE_HOURS:-50}" \]' "$f" || return 0
  sed -i 's|if \[ "$age" -ge "${LATE_HOURS:-50}" \]|lim=$(cat "/var/lib/nas-backup/$n.maxage" 2>/dev/null); if [ "$age" -ge "${lim:-${LATE_HOURS:-50}}" ]|' "$f"
  sed -i 's|(prévue chaque jour à $sch)|(horaire : $sch)|' "$f"
}

gen_cron() {
  {
    echo "# Genere automatiquement par nas-backup - ne pas modifier a la main"
    echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    # Une ligne par heure de lancement : les sauvegardes prevues a la meme heure
    # sont lancees l'une apres l'autre (run-at), qui tient compte des jours
    local n s sub m e sch r h mi sl t
    local -a slots
    local -A seen=()
    while IFS='|' read -r n s sub m e sch r || [ -n "$n" ]; do
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
  } > "$CRON_FILE"
  chmod 644 "$CRON_FILE"
  patch_nas_check
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
    ask "Horaire HH:MM (tous les jours), HH:MM/JOURS (1=lundi, ex. 03:30/135), plusieurs separes par ; ou 'manuel'" "${J_SCHED:-$DEFAULT_SCHED}"
    if valid_sched "$ANS"; then J_SCHED="$ANS"; break; fi
    rouge "Format invalide (ex : 03:30, 03:30/67, 03:30;15:00 ou manuel)."
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
  while IFS='|' read -r n s sub m e sch r || [ -n "$n" ]; do
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

# Bilan d'un transfert d'apres son journal rclone -> $STATE_DIR/<nom>.bilan.json
# Affiche un resume d'une ligne ("12 fichiers envoyes (1.3 Go)")
bilan() {  # bilan <journal> <debut> <code>
  python3 - "$1" "$J_SRC" "$STATE_DIR/$J_NAME.bilan.json" "$2" "$3" <<'PY' 2>/dev/null
import json, os, re, sys, time
log, src, out = sys.argv[1:4]
t0, rc = int(sys.argv[4]), int(sys.argv[5])
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
                b["retires"] += 1          # supprime, ou deplace vers la corbeille
except OSError:
    pass
fin = int(time.time())
env = b["nouveaux"] + b["remplaces"]
json.dump({"debut": t0, "fin": fin, "duree_min": round((fin - t0) / 60, 1), "code": rc,
           "fichiers_envoyes": env, "nouveaux": b["nouveaux"], "remplaces": b["remplaces"],
           "retires": b["retires"], "erreurs": b["erreurs"], "volume_octets": b["octets"]}, open(out, "w"))
v = float(b["octets"])
for u in ("o", "Ko", "Mo", "Go", "To"):
    if v < 1024 or u == "To":
        break
    v /= 1024
txt = "%d fichier%s envoyé%s (%s)" % (env, "s" if env > 1 else "", "s" if env > 1 else "",
                                      "%d o" % v if u == "o" else "%.1f %s" % (v, u))
if b["retires"]:
    txt += ", %d retiré%s" % (b["retires"], "s" if b["retires"] > 1 else "")
print(txt)
PY
}

run_job() {
  job_get "$1" || { rouge "Sauvegarde '$1' introuvable."; return 1; }
  local dest trash jour rc
  dest=$(dest_of "$J_ENC" "$J_SUB"); trash=$(trash_of "$J_ENC" "$J_NAME"); jour=$(date +%Y-%m-%d_%H%M)
  local runlog="$STATE_DIR/$J_NAME.run.log" runf="$STATE_DIR/$J_NAME.running"
  local -a opts=("${EXCLUDES[@]}" --log-file "$runlog" --log-level INFO)
  if [ -t 1 ]; then opts+=(-P); else opts+=(--stats 30s); fi   # --stats : avancement (%) pour Home Assistant
  [ -n "${J_BW:-}" ] && opts+=(--bwlimit "$J_BW")                # limite de debit (ex. 5M, ou "08:00,2M 23:00,off")
  local jstop="$STATE_DIR/$J_NAME.stop"
  rm -f "$jstop"

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

  # Avancement en direct dans Home Assistant pendant le transfert
  : > "$runlog"; echo "$$ $t0" > "$runf"
  ha_status
  ( while sleep "$HA_LIVE"; do
      [ -f "$runf" ] && kill -0 $$ 2>/dev/null || exit 0
      ha_status
    done ) 9>&- &   # 9>&- : ne pas garder le verrou de la sauvegarde apres sa fin
  local live=$!

  if [ "$J_MODE" = sync ]; then
    if [ "${J_RET:-0}" -gt 0 ]; then
      rclone sync "$J_SRC" "$dest" --backup-dir "$trash/$jour" "${opts[@]}"; rc=$?
      if [ ! -f "$STOPF" ] && [ ! -f "$jstop" ]; then
        rclone delete "$trash" --min-age "${J_RET}d" -q 2>/dev/null
        rclone rmdirs "$trash" --leave-root -q 2>/dev/null
      fi
    else
      rclone sync "$J_SRC" "$dest" "${opts[@]}"; rc=$?
    fi
  else
    rclone copy "$J_SRC" "$dest" "${opts[@]}"; rc=$?
  fi

  rm -f "$runf"; kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
  cat "$runlog" >> "$LOG"
  local resume; resume=$(bilan "$runlog" "$t0" "$rc")

  local duree=$(( ($(date +%s) - t0) / 60 ))
  if [ "$rc" -ne 0 ] && { [ -f "$STOPF" ] || [ -f "$jstop" ]; }; then
    # Arret demande : ni echec ni alerte critique, la prochaine execution reprendra
    echo "$(date '+%Y-%m-%d %H:%M') ARRETE" > "$STATE_DIR/$J_NAME.status"
    logl "$J_NAME : ARRETEE manuellement apres ${duree} min${resume:+ - $resume}"
    jaune "Arretee : $J_NAME${resume:+ - $resume}"
    notify info "stop-$J_NAME" "Sauvegarde « $J_NAME » arrêtée" "Arrêtée manuellement après ${duree} min. Elle reprendra à la prochaine exécution."
  elif [ "$rc" -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M') OK" > "$STATE_DIR/$J_NAME.status"
    date +%s > "$STATE_DIR/$J_NAME.lastok"
    logl "$J_NAME : OK${resume:+ - $resume}"; vert "OK : $J_NAME${resume:+ - $resume}"
    notify succes "job-$J_NAME" "Sauvegarde « $J_NAME »" "Terminée avec succès en ${duree} min${resume:+ : $resume}."
  else
    echo "$(date '+%Y-%m-%d %H:%M') ECHEC" > "$STATE_DIR/$J_NAME.status"
    logl "$J_NAME : ECHEC (code $rc)"; rouge "ECHEC : $J_NAME (voir $LOG)"
    local err; err=$(grep -E 'ERROR|CRITICAL' "$runlog" | tail -n 1 | sed -E 's/^[0-9\/ :]+//' | cut -c1-200)
    notify critique "job-$J_NAME" "Sauvegarde « $J_NAME » en échec" "Code $rc. ${err:-Voir $LOG sur le NAS.}"
  fi
  rm -f "$jstop"
  historise "$runlog"
  ha_status
  return "$rc"
}

# Arret d'une seule sauvegarde (les autres continuent)
stop_job() {
  local pat="rclone .*--log-file $STATE_DIR/$1.run.log" i
  job_exists "$1" || die "sauvegarde '$1' introuvable."
  if ! pgrep -f "$pat" >/dev/null; then vert "La sauvegarde '$1' n'est pas en cours."; return 0; fi
  touch "$STATE_DIR/$1.stop"
  logl "$1 : arret demande"
  pkill -TERM -f "$pat"
  for i in $(seq 30); do pgrep -f "$pat" >/dev/null || break; sleep 1; done
  if pgrep -f "$pat" >/dev/null; then pkill -KILL -f "$pat"; sleep 2; fi
  # attendre que la sauvegarde ait enregistre son etat (verrou libere en dernier)
  for i in $(seq 40); do flock -n "/run/nas-backup-$1.lock" true 2>/dev/null && break; sleep 1; done
  vert "Sauvegarde '$1' arretee. Elle reprendra a sa prochaine execution."
}

# Simulation : ce que la sauvegarde enverrait / supprimerait, sans rien faire
api_simulate() {
  job_get "$1" || die "sauvegarde '$1' introuvable."
  local out="$STATE_DIR/$J_NAME.simulation" dest cmd=sync rc
  dest=$(dest_of "$J_ENC" "$J_SUB")
  [ "$J_MODE" = copy ] && cmd=copy
  exec 8>"/run/nas-backup-simulation-$J_NAME.lock"
  flock -n 8 || die "une simulation de '$J_NAME' est deja en cours."
  [ -d "$J_SRC" ] || die "dossier source introuvable : $J_SRC"
  printf 'ETAT=en_cours\nDEBUT=%s\n' "$(date +%s)" > "$out.status"
  : > "$out.log"
  rclone "$cmd" "$J_SRC" "$dest" "${EXCLUDES[@]}" --dry-run --log-level NOTICE --log-file "$out.log" < /dev/null; rc=$?
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

# Historique : une ligne JSON par execution (bilan + etat + derniere erreur), 3000 au plus
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

run_at() {  # lance l'une apres l'autre les sauvegardes prevues a l'heure $1 ce jour-ci (utilise par cron)
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

# Arret propre : plus de nouvelle sauvegarde, rclone termine ses envois en cours
# (SIGTERM), puis arret force s'il ne s'est pas ferme. Les cameras ne sont pas touchees.
stop_all() {
  local pat="rclone .*--log-file $STATE_DIR/" i
  if ! pgrep -f "$pat" >/dev/null && ! pgrep -f "$SELF run" >/dev/null; then
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
  # attendre que les scripts aient enregistre l'etat (ARRETE)
  for i in $(seq 30); do pgrep -f "$SELF run" >/dev/null || break; sleep 1; done
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
  echo "(pendant une sauvegarde, son detail est dans $STATE_DIR/<NOM>.run.log)"
  ask_yn "Suivre en direct (Ctrl+C pour arreter) ?" n && tail -f "$LOG" "$STATE_DIR"/*.run.log
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
    echo "  8) Arreter les sauvegardes en cours"
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
      0|q|Q) exit 0 ;;
      *) ;;
    esac
  done
}

# =========================== Commandes non interactives ==============
# Utilisees par l'application Windows "NAS Manager" (aucune question posee).
API_VERSION=3

api_save() {  # api_save <nouveau|modif> NOM SOURCE DOSSIER_DRIVE MODE CHIFFRE HORAIRE CORBEILLE [DEBIT]
  local kind="$1"; shift
  [ $# -eq 7 ] || [ $# -eq 8 ] || die "usage : nas-backup save <nouveau|modif> NOM SOURCE DOSSIER MODE CHIFFRE HORAIRE CORBEILLE [DEBIT]"
  J_NAME="$1" J_SRC="${2%/}" J_SUB="$3" J_MODE="$4" J_ENC="$5" J_SCHED="$6" J_RET="$7" J_BW="${8:-}"
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
  [ "$J_MODE" = copy ] && J_RET=0
  local n s sub m e sch r
  while IFS='|' read -r n s sub m e sch r || [ -n "$n" ]; do
    [[ -z "$n" || "$n" == \#* || "$n" == "$J_NAME" ]] && continue
    if [ "$e" = "$J_ENC" ] && { [[ "$sub" == "$J_SUB" ]] || [[ "$sub" == "$J_SUB/"* ]] || [[ "$J_SUB" == "$sub/"* ]]; }; then
      jaune "Attention : la sauvegarde '$n' utilise deja le dossier Drive '$sub'."
    fi
  done < "$JOBS"
  local old_dest=""
  if [ "$kind" = modif ]; then
    local nm="$J_NAME" a b c d f g h
    IFS='|' read -r a b c d f g h <<< "$(grep -m1 "^$nm|" "$JOBS")"
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

api_delete() {  # api_delete NOM [effacer-drive]
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

api_restore() {  # api_restore NOM DOSSIER_CIBLE   (a lancer en arriere-plan)
  local st="$STATE_DIR/restauration.status" rlog="$STATE_DIR/restauration.log"
  job_get "$1" || die "sauvegarde '$1' introuvable."
  local target="${2%/}" dest rc
  [ -n "$target" ] || die "dossier de restauration manquant."
  dest=$(dest_of "$J_ENC" "$J_SUB")
  exec 9>/run/nas-backup-restauration.lock
  flock -n 9 || die "une restauration est deja en cours."
  mkdir -p "$target" || die "impossible de creer $target"
  : > "$rlog"
  printf 'ETAT=en_cours\nNOM=%q\nCIBLE=%q\nDEBUT=%s\n' "$J_NAME" "$target" "$(date +%s)" > "$st"
  logl "$J_NAME : restauration vers $target"
  rclone copy "$dest" "$target" "${EXCLUDES[@]}" --stats 10s --log-file "$rlog" --log-level INFO; rc=$?
  if [ $rc -eq 0 ]; then
    printf 'ETAT=ok\nNOM=%q\nCIBLE=%q\nFIN=%s\n' "$J_NAME" "$target" "$(date +%s)" > "$st"
    logl "$J_NAME : restauration terminee ($target)"
    notify info "restore-$J_NAME" "Restauration « $J_NAME » terminée" "Fichiers restaurés dans $target"
  else
    printf 'ETAT=echec\nNOM=%q\nCIBLE=%q\nFIN=%s\nCODE=%s\n' "$J_NAME" "$target" "$(date +%s)" "$rc" > "$st"
    logl "$J_NAME : restauration en ECHEC (code $rc)"
    notify critique "restore-$J_NAME" "Restauration « $J_NAME » en échec" "Code $rc. Détails : $rlog"
  fi
  return $rc
}

# =========================== Point d'entree ==========================
init
case "${1:-}" in
  "")       self_install; gen_cron; menu ;;
  run)      [ -n "${2:-}" ] || die "usage : nas-backup run <NOM>"; rm -f "$STOPF"; run_job_locked "$2" ;;
  run-at)   [ -n "${2:-}" ] || die "usage : nas-backup run-at <HH:MM>"; run_at "$2" ;;
  run-all)  run_all ;;
  list)     list_jobs ;;
  stop)     if [ -n "${2:-}" ]; then stop_job "$2"; else stop_all; fi ;;
  simulate) [ -n "${2:-}" ] || die "usage : nas-backup simulate <NOM>"; api_simulate "$2" ;;
  save)     shift; api_save "$@" ;;
  delete)   [ -n "${2:-}" ] || die "usage : nas-backup delete <NOM> [effacer-drive]"; api_delete "$2" "${3:-}" ;;
  restore)  [ -n "${3:-}" ] || die "usage : nas-backup restore <NOM> <DOSSIER>"; api_restore "$2" "$3" ;;
  gen-cron) gen_cron ;;
  api-version) echo "$API_VERSION" ;;
  *)        echo "Usage : nas-backup [run <NOM> | run-at <HH:MM> | run-all | list | stop | save ... | delete <NOM> | restore <NOM> <DOSSIER>]"; exit 1 ;;
esac
