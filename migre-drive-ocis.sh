#!/bin/bash
# =====================================================================
#  migre-drive-ocis.sh : migration de Synology Drive (Mon Drive des
#  utilisateurs) vers des espaces projets ownCloud Infinite Scale (oCIS).
#
#  Lancement (SSH sur le Synology) :  sudo bash migre-drive-ocis.sh
#    sans argument : menu
#    suivi         : reprendre l'affichage de la migration en cours
#    stop          : arreter la migration en cours
#
#  - Les fichiers passent par l'API WebDAV d'oCIS (jamais d'ecriture
#    directe dans le stockage oCIS), avec les dates de modification.
#  - La migration tourne en arriere-plan : fermer la session SSH ne
#    l'arrete pas. Relancer une migration reprend la ou elle en etait
#    (les fichiers deja presents et identiques sont sautes).
#  - Les originaux restent sur le Synology (copie, jamais deplacement).
# =====================================================================
set -o pipefail

HA_HOST="192.168.1.222"                         # Home Assistant, vide = pas de notification
HA_WEBHOOK="nas-c09f382daf2d01deb430abbd"
TRANSFERS=4                                     # fichiers envoyes en parallele
CHECKERS=8
AUTO_REPRISE=5                                  # relances automatiques si rclone s'arrete
DEFAULT_LOCAL="https://192.168.1.53:9200"       # oCIS sur l'hote Docker, en direct (sans Cloudflare)

SELF=$(readlink -f "$0")
STATE="/root/.migre-ocis"
CONF="$STATE/config"
QUEUE="$STATE/file-attente"
RUN="$STATE/en-cours"
LOGF="$STATE/progression.log"
HIST="$STATE/historique.log"
BIN="$STATE/bin"
EXCL=(--exclude '@eaDir/**' --exclude '#recycle/**' --exclude '#snapshot/**' --exclude '#SynoRecycle/**'
      --exclude '.SynologyWorkingDirectory/**' --exclude '*@SynoEAStream' --exclude '*@SynoResource'
      --exclude '.DS_Store' --exclude 'Thumbs.db' --exclude 'desktop.ini')

B="\e[1m"; V="\e[32m"; J="\e[33m"; R="\e[31m"; G="\e[90m"; N="\e[0m"
die()  { echo -e "${R}ERREUR : $*${N}"; exit 1; }
hsize() { awk -v b="$1" 'BEGIN{split("o Ko Mo Go To",u);i=1;while(b>=1024&&i<5){b/=1024;i++};printf (i==1?"%d %s":"%.1f %s"),b,u[i]}'; }
pause() { read -r -p "Entree pour continuer..." _; }

[ "$(id -u)" -eq 0 ] || die "lance le script avec sudo :  sudo bash $0"
mkdir -p "$STATE" "$BIN"; chmod 700 "$STATE"
command -v python3 >/dev/null || die "python3 est introuvable sur le NAS (necessaire pour dialoguer avec oCIS)."
export PATH="$BIN:$PATH"

# =========================== rclone ==================================
ensure_rclone() {
  command -v rclone >/dev/null && return 0
  local arch zip
  case "$(uname -m)" in
    x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; armv7l) arch=arm-v7 ;; *) die "architecture $(uname -m) non prise en charge." ;;
  esac
  echo "Telechargement de rclone ($arch)..."
  zip="$STATE/rclone.zip"
  curl -fsSL -o "$zip" "https://downloads.rclone.org/rclone-current-linux-$arch.zip" || die "telechargement de rclone impossible."
  python3 - "$zip" "$BIN" <<'PY' || die "extraction de rclone impossible."
import sys, zipfile, os
z = zipfile.ZipFile(sys.argv[1])
for n in z.namelist():
    if n.endswith("/rclone"):
        with open(os.path.join(sys.argv[2], "rclone"), "wb") as f:
            f.write(z.read(n))
PY
  chmod 755 "$BIN/rclone"; rm -f "$zip"
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
  [ -f "$CONF" ] || return 1
  . "$CONF"
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

setup_conf() {
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
  } > "$CONF"; chmod 600 "$CONF"
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

ensure_conf() { load_conf || setup_conf || die "configuration oCIS incomplete."; }

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
browse_local() {
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

pick_source() {  # -> SRC_DIR, SRC_LABEL
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
    browse_local || return 1
    SRC_DIR="$CHOIX"; SRC_LABEL="${CHOIX##*/}"; return 0
  elif [[ "$c" =~ ^[cC]$ ]]; then
    read -r -p "Chemin : " SRC_DIR; SRC_DIR="${SRC_DIR%/}"
    [ -d "$SRC_DIR" ] || { echo "Dossier introuvable."; sleep 2; return 1; }
    SRC_LABEL="${SRC_DIR##*/}"; return 0
  fi
  return 1
}

pick_space() {  # -> SP_ID, SP_NAME, SP_DAV  (espaces existants uniquement)
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
running() { [ -f "$RUN" ] && . "$RUN" && kill -0 "$PID" 2>/dev/null; }

add_task() {
  pick_source || return
  pick_space || return
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
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$SRC_DIR" "$SRC_LABEL" "$SP_ID" "$SP_NAME" "$SP_DAV" "$sub" "${total:-0}" >> "$QUEUE"
  echo -e "${V}Ajoute a la file d'attente : $SRC_LABEL -> $SP_NAME${sub:+/$sub}${N}"
}

show_queue() {
  [ -s "$QUEUE" ] || { echo -e "  ${G}(file d'attente vide)${N}"; return; }
  local i=1 s l id n dav sub t
  while IFS='|' read -r s l id n dav sub t; do
    printf "  %2d) %-18s -> %-25s %10s\n" "$i" "$l" "$n${sub:+/$sub}" "$(hsize "$t")"; i=$((i+1))
  done < "$QUEUE"
}

remove_task() {
  show_queue; [ -s "$QUEUE" ] || return
  read -r -p "Numero a retirer : " c
  [[ "$c" =~ ^[0-9]+$ ]] && sed -i "${c}d" "$QUEUE"
}

# =========================== Lancement ===============================
start() {
  if running; then echo -e "${J}Une migration est deja en cours.${N}"; follow; return; fi
  [ -s "$QUEUE" ] || { echo "La file d'attente est vide : ajoute d'abord une migration."; pause; return; }
  ensure_rclone
  echo; echo -e "${B}Migrations a lancer :${N}"; show_queue; echo
  read -r -p "Lancer ? [O/n] : " go
  [[ "${go:-o}" =~ ^[oOyY] ]] || return
  cp "$QUEUE" "$STATE/lot"; : > "$QUEUE"
  [ -s "$LOGF" ] && mv -f "$LOGF" "$LOGF.precedent"; : > "$LOGF"; rm -f "$STATE/code" "$STATE/etape"
  printf 'NB=%s\nDEBUT=%s\n' "$(wc -l < "$STATE/lot")" "$(date +%s)" > "$RUN"
  nohup setsid bash "$SELF" _worker >/dev/null 2>&1 &
  echo "PID=$!" >> "$RUN"
  echo -e "${V}Migration lancee.${N}"; sleep 1
  follow
}

worker() {  # tourne en arriere-plan : traite le lot ligne par ligne
  load_conf
  local obs i=0 ok=0 ko=0 s l id n dav sub t rc url
  obs=$(rclone obscure "$OCIS_PASS")
  while IFS='|' read -r s l id n dav sub t; do
    i=$((i+1))
    local t0; t0=$(date +%s)
    printf 'ETAPE=%s\nE_SRC=%q\nE_LABEL=%q\nE_SPACE=%q\nE_TOTAL=%s\n' "$i" "$s" "$l" "$n${sub:+/$sub}" "$t" > "$STATE/etape"
    dav=$(to_base "$dav")
    echo "=== [$i] $s -> $n${sub:+/$sub}  via ${dav%%/dav/*}  ($(date '+%F %T'))" >> "$LOGF"
    local why="" requeue=1 try=0 retryable sect errs
    while :; do
      try=$((try+1))
      if [ ! -d "$s" ]; then
        rc=3; echo "$(date '+%Y/%m/%d %H:%M:%S') ERROR : dossier source introuvable : $s" >> "$LOGF"
      else
        # Reglages economes en memoire ; la sortie d'erreur de rclone (plantages) va dans le journal
        GOGC=50 RCLONE_CONFIG_OCIS_TYPE=webdav RCLONE_CONFIG_OCIS_URL="$dav" RCLONE_CONFIG_OCIS_VENDOR="${OCIS_VENDOR:-infinitescale}" \
        RCLONE_CONFIG_OCIS_USER="$OCIS_USER" RCLONE_CONFIG_OCIS_PASS="$obs" \
          rclone copy "$s" "ocis:$sub" --create-empty-src-dirs "${EXCL[@]}" "${RCLONE_K[@]}" \
            --transfers "$TRANSFERS" --checkers "$CHECKERS" --buffer-size 8M --use-mmap \
            --retries 5 --low-level-retries 20 \
            --stats 2s --stats-one-line --stats-log-level NOTICE -v --log-file "$LOGF" < /dev/null 2>>"$LOGF"
        rc=$?
      fi
      [ $rc -eq 0 ] && break
      # --- cause de l'arret
      sect=$(awk -v m="=== [$i] " 'index($0,m)==1{f=1;next} f' "$LOGF"); errs=$(grep 'ERROR' <<< "$sect")
      retryable=1
      if [ $rc -ge 128 ]; then
        why="rclone tue par le systeme (signal $((rc-128)))"
        dmesg 2>/dev/null | grep -iE 'killed process|out of memory|oom' | tail -n 2 | sed 's/^/    dmesg: /' >> "$LOGF"
        grep -q 'dmesg:.*rclone' <(tail -n 3 "$LOGF") && why="rclone tue par le systeme : memoire insuffisante (OOM)"
      elif grep -qiE 'out of memory|cannot allocate memory' <<< "$sect"; then why="rclone a manque de memoire"
      elif grep -qE '^(panic|fatal error):' <<< "$sect"; then why="rclone a plante : $(grep -m1 -E '^(panic|fatal error):' <<< "$sect" | cut -c1-90)"
      elif [ $rc -eq 3 ] || grep -q 'directory not found' <<< "$errs"; then
        why="dossier source introuvable ($s) : retire de la file"; requeue=0; retryable=0
      elif grep -qiE '507|insufficient storage|quota' <<< "$errs"; then why="quota de l'espace atteint (espace plein)"; retryable=0
      elif grep -q '401' <<< "$errs"; then why="jeton refuse (401) : expire ou revoque"; retryable=0
      elif grep -qiE 'connection refused|no such host|timeout' <<< "$errs"; then why="oCIS injoignable pendant le transfert"
      elif [ -n "$errs" ]; then why=$(grep -v 'Attempt [0-9]' <<< "$errs" | tail -n 1 | sed -E 's/^.*ERROR : //' | cut -c1-110)
      else why="rclone s'est arrete sans message (code $rc)"; fi
      echo "=== [$i] arret de rclone : code $rc ($why)" >> "$LOGF"
      # --- reprise automatique : la copie repart la ou elle s'etait arretee
      if [ $retryable -eq 1 ] && [ $try -le $AUTO_REPRISE ]; then
        echo "=== [$i] reprise automatique $try/$AUTO_REPRISE dans 30 s" >> "$LOGF"
        echo "REPRISE=$try" >> "$STATE/etape"
        sleep 30; continue
      fi
      break
    done
    local d=$(( ($(date +%s) - t0) / 60 ))
    if [ $rc -eq 0 ]; then ok=$((ok+1)); st=OK; requeue=0; why=""; [ $try -gt 1 ] && why="apres $((try-1)) reprise(s) automatique(s)"
    else ko=$((ko+1)); st="ECHEC"; [ $try -gt 1 ] && why="$why, apres $((try-1)) reprise(s)"; fi
    echo "$(date '+%Y-%m-%d %H:%M') | $st${why:+ ($why)} | $s -> $n${sub:+/$sub} | ${d} min" >> "$HIST"
    echo "$i|$st|$l|$n${sub:+/$sub}|$why" >> "$STATE/resultats"
    [ $requeue -eq 1 ] && echo "$s|$l|$id|$n|$dav|$sub|$t" >> "$QUEUE"   # remis en file pour reprise
  done < "$STATE/lot"
  echo "$ok|$ko" > "$STATE/code"
  local msg="$ok migration(s) reussie(s)"; [ $ko -gt 0 ] && msg="$msg, $ko en echec (remise(s) en file d'attente pour reprise)"
  if [ $ko -eq 0 ]; then notify info "Migration Drive -> oCIS terminée" "$msg."
  else notify critique "Migration Drive -> oCIS : erreurs" "$msg."; fi
}

notify() {
  [ -n "$HA_HOST" ] || return 0
  local body; body=$(python3 -c 'import json,sys; print(json.dumps({"title":sys.argv[1],"message":sys.argv[2],"tag":"migre-ocis"}))' "$2" "$3")
  for u in "http://$HA_HOST:8123" "http://$HA_HOST"; do
    curl -s -m 8 -o /dev/null -f -X POST -H 'Content-Type: application/json' -d "$body" "$u/api/webhook/${HA_WEBHOOK}-$1" && return 0
  done
  return 0
}

# =========================== Suivi ===================================
show_results() {  # affiche les resultats des migrations terminees pas encore affiches
  [ -f "$STATE/resultats" ] || return 0
  local i st l n why k=0
  while IFS='|' read -r i st l n why; do
    k=$((k+1)); [ $k -le $shown ] && continue
    if [ "$st" = OK ]; then echo -e "   ${V}-> termine avec succes${why:+ ($why)}${N}"
    else echo -e "   ${R}-> ECHEC : $why${N}"; echo -e "   ${G}(remise en file d'attente, la suite continue)${N}"; fi
    shown=$k
  done < "$STATE/resultats"
}

follow() {
  [ -f "$RUN" ] || { echo "Aucune migration lancee."; return; }
  . "$RUN"
  trap 'echo; echo -e "${J}Suivi interrompu : la migration continue en arriere-plan.${N}"; echo "Reprendre le suivi :  sudo bash $SELF suivi"; exit 0' INT
  echo -e "${G}Ctrl+C = arreter le suivi (la migration continue)${N}"
  local last="" line pct n bar shown=0 shown_rep=""
  while kill -0 "$PID" 2>/dev/null; do
    if [ -f "$STATE/etape" ]; then
      unset REPRISE; . "$STATE/etape"
      if [ "$ETAPE" != "$last" ]; then
        shown_rep=""
        [ -n "$last" ] && { echo; show_results; }
        echo -e "\n${B}[$ETAPE/$NB] $E_LABEL -> $E_SPACE${N}  ($(hsize "$E_TOTAL"))"
        last="$ETAPE"
      fi
      [ -n "${REPRISE:-}" ] && [ "${REPRISE}" != "${shown_rep:-}" ] && { echo; echo -e "   ${J}rclone s'est arrete : reprise automatique ${REPRISE}/$AUTO_REPRISE...${N}"; shown_rep="$REPRISE"; }
      line=$(tail -n 3000 "$LOGF" 2>/dev/null | awk -v m="=== [$ETAPE] " 'index($0,m)==1{f=1} f && /NOTICE:/{l=$0} END{print l}' | sed 's/.*NOTICE: *//')
      if [[ "$line" =~ ([0-9]+)% ]]; then
        pct="${BASH_REMATCH[1]}"; n=$(( pct * 30 / 100 ))
        bar=$(printf '%*s' "$n" '' | tr ' ' '#')$(printf '%*s' $((30-n)) '' | tr ' ' '.')
        printf "\r [%s] %-70s" "$bar" "${line:0:70}"
      else
        printf "\r Analyse des fichiers..."
      fi
    fi
    sleep 2
  done
  echo; show_results; echo
  if [ -f "$STATE/resultats" ]; then
    echo -e "${B}Bilan :${N}"
    while IFS='|' read -r i st l n why; do
      [ "$st" = OK ] && echo -e "  ${V}OK${N}     $l -> $n" || echo -e "  ${R}ECHEC${N}  $l -> $n : $why"
    done < "$STATE/resultats"
    if grep -q ECHEC "$STATE/resultats"; then
      if grep -q 'quota' "$STATE/resultats"; then
        echo; echo -e "${J}Espace plein : dans oCIS, ouvre l'espace > ⋯ > Modifier le quota > « Pas de restriction »."
        echo -e "(les nouveaux espaces ont 1 Go par defaut ; GRAPH_SPACES_DEFAULT_QUOTA=0 pour les suivants)${N}"
      fi
      if grep -q '401' "$STATE/resultats"; then load_conf; echo; http_hint 401; fi
      echo -e "${J}Les migrations en echec (sauf dossier introuvable) sont remises en file d'attente : relance-les, elles reprendront.${N}"
    fi
    echo
    rm -f "$STATE/resultats"
  fi
  trap - INT
}

stop_run() {
  running || { echo "Aucune migration en cours."; return; }
  read -r -p "Arreter la migration en cours ? [o/N] : " c
  [[ "$c" =~ ^[oOyY] ]] || return
  pkill -TERM -s "$(ps -o sid= -p "$PID" | tr -d ' ')" 2>/dev/null || kill "$PID"
  # remet en file ce qui n'a pas ete termine
  if [ -f "$STATE/etape" ]; then . "$STATE/etape"; tail -n +"$ETAPE" "$STATE/lot" >> "$QUEUE"; fi
  rm -f "$STATE/resultats"
  echo -e "${J}Migration arretee. Les migrations non terminees sont remises en file d'attente.${N}"
}

# =========================== Point d'entree ==========================
case "${1:-}" in
  _worker) worker; exit ;;
  suivi)   follow; exit ;;
  stop)    stop_run; exit ;;
esac

ensure_conf
api GET /graph/v1.0/me/drives
if [ "$HTTP" != 200 ]; then clear; http_hint "$HTTP"; echo; pause
elif [ "${OCIS_VENDOR:-infinitescale}" = infinitescale ]; then
  clear
  echo -e "${J}Mise a jour : passage des envois en WebDAV classique.${N}"
  echo "Le mode oCIS natif de rclone fait exploser la memoire (bug connu) : c'est ce qui"
  echo "faisait tuer rclone par le systeme sur le NAS."
  ensure_rclone
  if detect_vendor; then
    sed -i "s/^OCIS_VENDOR=.*/OCIS_VENDOR=$OCIS_VENDOR/" "$CONF"; load_conf
  fi
  pause
fi
while true; do
  clear
  echo -e "${B}===== MIGRATION SYNOLOGY DRIVE -> oCIS =====${N}"
  echo -e "oCIS : $OCIS_URL  (compte $OCIS_USER, mode ${OCIS_VENDOR:-infinitescale})"
  [ -n "${LOCAL_URL:-}" ] && echo -e "Transferts : ${V}reseau local${N} ($LOCAL_URL)" \
                          || echo -e "Transferts : ${J}via Internet${N} (menu 7 pour ajouter l'adresse locale)"
  if running; then . "$STATE/etape" 2>/dev/null; echo -e "${J}Migration en cours : ${E_LABEL:-...} (${ETAPE:-?}/$NB)${N}"; fi
  echo; echo -e "${B}File d'attente :${N}"; show_queue; echo
  echo "  1) Ajouter une migration a la file d'attente"
  echo "  2) Retirer une migration de la file"
  echo "  3) Lancer la file d'attente"
  echo "  4) Suivre la migration en cours"
  echo "  5) Arreter la migration en cours"
  echo "  6) Historique"
  echo "  7) Modifier la connexion oCIS"
  echo "  0) Quitter"
  read -r -p "Choix : " c
  case "$c" in
    1) add_task; sleep 1 ;;
    2) remove_task ;;
    3) start; pause ;;
    4) follow; pause ;;
    5) stop_run; sleep 2 ;;
    6) clear; tail -n 30 "$HIST" 2>/dev/null || echo "Aucune migration."; pause ;;
    7) setup_conf || pause ;;
    0|q) exit 0 ;;
  esac
done
