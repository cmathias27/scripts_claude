#!/bin/bash
# =====================================================================
#  install-alertes.sh
#  Alertes Home Assistant pour les sauvegardes du NAS (OMV)
#   - nas-notify : envoie une notification a Home Assistant (webhook)
#   - nas-check  : verification toutes les heures (Drive, quota, cameras,
#                  sauvegardes en retard)
#   - rattrapage cameras : alerte si l'envoi vers le Drive echoue
#
#  Usage : bash install-alertes.sh        (en root)
# =====================================================================
set -uo pipefail

# --------------------------- Parametres ------------------------------
HA_IP="192.168.1.222"
WEBHOOK="nas-c09f382daf2d01deb430abbd"   # cree dans l'automatisation HA "NAS - Alertes sauvegardes"
REPEAT_HOURS=12                          # rappel d'une alerte non resolue toutes les X heures
QUOTA_ALERT=90                           # alerte si le Drive est rempli a plus de X %
LATE_HOURS=50                            # alerte si une sauvegarde planifiee n'a pas reussi depuis X heures
# ---------------------------------------------------------------------

vert()  { echo -e "\e[32m$*\e[0m"; }
jaune() { echo -e "\e[33m$*\e[0m"; }
rouge() { echo -e "\e[31m$*\e[0m"; }
die()   { rouge "ERREUR : $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "lance ce script en root."
command -v curl >/dev/null || apt-get install -y -qq curl >/dev/null
command -v python3 >/dev/null || die "python3 est introuvable."

# --------------------------- Trouver Home Assistant ------------------
echo "== Recherche de Home Assistant sur $HA_IP =="
HA_URL=""
for url in "http://$HA_IP:8123" "http://$HA_IP" "https://$HA_IP:8123" "https://$HA_IP"; do
  code=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 "$url/api/" || true)
  if [ "$code" != "000" ]; then HA_URL="$url"; break; fi
done
[ -n "$HA_URL" ] || die "Home Assistant injoignable sur $HA_IP (ports 8123 et 80 testes)."
vert "OK : Home Assistant repond sur $HA_URL"

mkdir -p /etc/nas-backup /var/lib/nas-backup/alertes
cat > /etc/nas-backup/notify.conf <<EOF
HA_URL="$HA_URL"
WEBHOOK="$WEBHOOK"
REPEAT_HOURS=$REPEAT_HOURS
QUOTA_ALERT=$QUOTA_ALERT
LATE_HOURS=$LATE_HOURS
EOF
chmod 600 /etc/nas-backup/notify.conf

# --------------------------- nas-notify ------------------------------
cat > /usr/local/bin/nas-notify <<'EOF'
#!/bin/bash
# nas-notify <niveau> <tag> <titre> <message>
#   critique : alerte prioritaire (rappel toutes les REPEAT_HOURS si non resolue)
#   info     : notification discrete
#   succes   : notification discrete, ou "retabli" si une alerte etait en cours
#   ok       : silencieux, sauf "retabli" si une alerte etait en cours
CONF=/etc/nas-backup/notify.conf
[ -f "$CONF" ] || exit 0
. "$CONF"
LEVEL="${1:-info}"; TAG="${2:-nas}"; TITLE="${3:-NAS}"; MSG="${4:-}"
TAG=$(printf '%s' "$TAG" | tr -c 'A-Za-z0-9_-' '_')
F="/var/lib/nas-backup/alertes/$TAG"
mkdir -p /var/lib/nas-backup/alertes

send() {  # send <critique|info> <titre> <message>
  local json
  json=$(python3 -c 'import json,sys;print(json.dumps({"title":sys.argv[1],"message":sys.argv[2],"tag":sys.argv[3]}))' "$2" "$3" "$TAG")
  curl -sk -m 15 -o /dev/null -f -X POST -H 'Content-Type: application/json' \
    -d "$json" "$HA_URL/api/webhook/${WEBHOOK}-$1"
}

case "$LEVEL" in
  critique)
    if [ -f "$F" ] && [ $(( $(date +%s) - $(stat -c %Y "$F") )) -lt $(( ${REPEAT_HOURS:-12} * 3600 )) ]; then
      exit 0
    fi
    send critique "$TITLE" "$MSG" && touch "$F" ;;
  succes)
    if [ -f "$F" ]; then rm -f "$F"; send info "✅ Rétabli : $TITLE" "$MSG"
    else send info "$TITLE" "$MSG"; fi ;;
  ok)
    [ -f "$F" ] || exit 0
    rm -f "$F"; send info "✅ Rétabli : $TITLE" "$MSG" ;;
  info)
    send info "$TITLE" "$MSG" ;;
  *) echo "Usage : nas-notify <critique|info|succes|ok> <tag> <titre> <message>"; exit 1 ;;
esac
EOF
chmod 755 /usr/local/bin/nas-notify
vert "OK : /usr/local/bin/nas-notify"

# --------------------------- nas-check -------------------------------
cat > /usr/local/bin/nas-check <<'EOF'
#!/bin/bash
# Verification horaire de la sante des sauvegardes
. /etc/nas-backup/notify.conf
N=/usr/local/bin/nas-notify

# 1. Service temps reel des cameras
if systemctl is-enabled --quiet cam-sync 2>/dev/null; then
  if systemctl is-active --quiet cam-sync; then
    $N ok cam-service "Caméras" "La synchro temps réel des caméras fonctionne de nouveau."
  else
    $N critique cam-service "Caméras : synchro arrêtée" "Le service cam-sync est arrêté sur le NAS. Sur le NAS : systemctl restart cam-sync"
  fi
fi

# 2. Connexion Google Drive
GD=false; pct=""; used_go=""; total_go=""
if timeout 120 rclone lsd gdrive: >/dev/null 2>&1; then
  GD=true
  $N ok gdrive "Google Drive" "La connexion à Google Drive fonctionne de nouveau."

  # 3. Espace disponible
  if json=$(timeout 120 rclone about gdrive: --json 2>/dev/null); then
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
else
  $N critique gdrive "Google Drive inaccessible" "rclone n'arrive plus à se connecter à Google Drive. Sur le NAS : rclone config reconnect gdrive:"
fi

# 4. Sauvegardes planifiees en retard
JOBS=/etc/nas-backup/jobs.conf
if [ -f "$JOBS" ]; then
  while IFS='|' read -r n s sub m e sch r; do
    [[ -z "$n" || "$n" == \#* || "$sch" == manuel ]] && continue
    f="/var/lib/nas-backup/$n.lastok"
    [ -f "$f" ] || continue
    age=$(( ( $(date +%s) - $(cat "$f") ) / 3600 ))
    # seuil propre a chaque sauvegarde (horaires sur certains jours), ecrit par nas-backup
    lim=$(cat "/var/lib/nas-backup/$n.maxage" 2>/dev/null); if [ "$age" -ge "${lim:-${LATE_HOURS:-50}}" ]; then
      $N critique "retard-$n" "Sauvegarde « $n » en retard" "Aucune sauvegarde réussie depuis ${age} h (horaire : $sch)."
    else
      $N ok "retard-$n" "Sauvegarde « $n »" "La sauvegarde est de nouveau à jour."
    fi
  done < "$JOBS"
fi

# 5. Etat pour le tableau de bord Home Assistant
python3 -c '
import json,sys,time
from datetime import datetime
gd,pct,u,t=sys.argv[1:5]
num=lambda x:(float(x) if x else None)
json.dump({"gdrive":gd=="true","quota_pct":int(num(pct)) if pct else None,"used_go":num(u),"total_go":num(t),
           "checked":datetime.now().astimezone().isoformat(timespec="seconds")},open("/var/lib/nas-backup/health.json","w"))
' "$GD" "$pct" "$used_go" "$total_go"
[ -x /usr/local/bin/nas-ha-status ] && /usr/local/bin/nas-ha-status >/dev/null 2>&1
exit 0
EOF
chmod 755 /usr/local/bin/nas-check
echo "7 * * * * root /usr/local/bin/nas-check >/dev/null 2>&1" > /etc/cron.d/nas-check
chmod 644 /etc/cron.d/nas-check
vert "OK : verification toutes les heures (nas-check)"

# --------------------------- Rattrapage cameras ----------------------
if grep -q 'cam-transferts' /usr/local/bin/cam-sync-catchup.sh 2>/dev/null; then
  vert "OK : rattrapage cameras deja gere par install-suivi-ha (alertes + comptage), conserve"
elif [ -f /usr/local/bin/cam-sync.sh ]; then
  CAM_SRC=$(grep -m1 '^SRC=' /usr/local/bin/cam-sync.sh | cut -d'"' -f2)
  cat > /usr/local/bin/cam-sync-catchup.sh <<EOF
#!/bin/bash
# Rattrapage periodique des cameras, avec alerte Home Assistant
if rclone sync "$CAM_SRC" gcrypt: --min-age 2m --exclude '@eaDir/**' --exclude '\#recycle/**' \\
     --log-file /var/log/cam-sync.log --log-level INFO; then
  /usr/local/bin/nas-notify ok cam-sync "Caméras" "L'envoi des vidéos vers Google Drive fonctionne de nouveau."
else
  /usr/local/bin/nas-notify critique cam-sync "Caméras : envoi en échec" "Les vidéos ne partent plus vers Google Drive. Détails : /var/log/cam-sync.log"
fi
EOF
  chmod 755 /usr/local/bin/cam-sync-catchup.sh
  echo "*/15 * * * * root flock -n /run/cam-sync-full.lock /usr/local/bin/cam-sync-catchup.sh >/dev/null 2>&1" > /etc/cron.d/cam-sync
  chmod 644 /etc/cron.d/cam-sync
  vert "OK : alerte sur le rattrapage des cameras"
else
  jaune "Synchro cameras non installee : etape ignoree."
fi

# --------------------------- Tests -----------------------------------
echo
echo "== Test =="
if /usr/local/bin/nas-notify info test "NAS" "Les alertes de sauvegarde sont actives ✅"; then
  vert "Notification discrete envoyee : verifie ton telephone."
else
  rouge "Echec de l'envoi vers Home Assistant ($HA_URL)."
fi
read -r -p "Envoyer aussi une alerte CRITIQUE de test (sonnerie forte) ? [o/N] " r
if [[ "$r" =~ ^[oOyY]$ ]]; then
  /usr/local/bin/nas-notify critique test-critique "Test d'alerte" "Ceci est un test, tout va bien." && vert "Alerte critique envoyee."
  rm -f /var/lib/nas-backup/alertes/test-critique
fi

echo
vert "=============== ALERTES INSTALLEES ==============="
echo "Verification manuelle : nas-check"
echo "Alertes en cours      : ls /var/lib/nas-backup/alertes"
jaune "Pense a mettre a jour nas-backup (nouvelle version) pour les alertes par sauvegarde."
