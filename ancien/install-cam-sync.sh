#!/bin/bash
# =====================================================================
#  install-cam-sync.sh
#  Synchro temps reel CHIFFREE du dossier cameras OMV -> Google Drive
#  Miroir exact : ce qui est supprime en local est supprime sur le Drive
#
#  Prerequis : rclone installe + remote "gdrive" fonctionnel
#  Usage     : bash install-cam-sync.sh        (en root)
#  Desinstall: bash install-cam-sync.sh --uninstall
# =====================================================================
set -euo pipefail

# --------------------------- Parametres ------------------------------
SRC="${CAM_SRC:-/srv/dev-disk-by-uuid-7cd5ac91-9ec8-439c-9de3-c5bf7f5418f5/Cam}"   # (CAM_SRC : installation depuis NAS Manager)
GDRIVE_REMOTE="gdrive"          # remote Google Drive deja configure
CRYPT_REMOTE="gcrypt"           # remote chiffre cree par ce script
DRIVE_FOLDER="Cam-chiffre"      # dossier cree sur le Drive
CATCHUP_MIN=15                  # rattrapage toutes les X minutes
LOG="/var/log/cam-sync.log"
PASSFILE="/root/cam-crypt-motsdepasse.txt"
# ---------------------------------------------------------------------

SCRIPT_BIN="/usr/local/bin/cam-sync.sh"
SERVICE="/etc/systemd/system/cam-sync.service"
CRON="/etc/cron.d/cam-sync"
LOGROTATE="/etc/logrotate.d/cam-sync"
SYSCTL="/etc/sysctl.d/99-inotify.conf"

vert()  { echo -e "\e[32m$*\e[0m"; }
jaune() { echo -e "\e[33m$*\e[0m"; }
rouge() { echo -e "\e[31m$*\e[0m"; }
die()   { rouge "ERREUR : $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "lance ce script en root."

# --------------------------- Desinstallation -------------------------
if [ "${1:-}" = "--uninstall" ]; then
  systemctl disable --now cam-sync 2>/dev/null || true
  rm -f "$SCRIPT_BIN" "$SERVICE" "$CRON" "$LOGROTATE"
  systemctl daemon-reload
  vert "Service supprime. Le remote '$CRYPT_REMOTE', le fichier de mots de passe"
  vert "et les videos sur le Drive ont ete conserves."
  exit 0
fi

# --------------------------- Verifications ---------------------------
echo "== Verifications =="
command -v rclone >/dev/null || die "rclone n'est pas installe."
[ -d "$SRC" ] || die "dossier introuvable : $SRC"
rclone listremotes 2>/dev/null | grep -x "${GDRIVE_REMOTE}:" >/dev/null \
  || die "remote '${GDRIVE_REMOTE}' introuvable (voir 'rclone listremotes')."
rclone lsd "${GDRIVE_REMOTE}:" >/dev/null 2>&1 \
  || die "connexion Google Drive en echec. Lance : rclone config reconnect ${GDRIVE_REMOTE}:"
vert "OK : rclone, dossier cameras et Google Drive"

# --------------------------- Paquets ---------------------------------
echo "== Installation des outils =="
apt-get update -qq
apt-get install -y -qq inotify-tools openssl util-linux >/dev/null
vert "OK : inotify-tools"

# --------------------------- Remote chiffre --------------------------
echo "== Remote chiffre =="
if rclone listremotes 2>/dev/null | grep -x "${CRYPT_REMOTE}:" >/dev/null; then
  jaune "Le remote '${CRYPT_REMOTE}' existe deja : conserve (mots de passe inchanges)."
else
  P1=$(openssl rand -base64 24)
  P2=$(openssl rand -base64 24)
  rclone config create "$CRYPT_REMOTE" crypt \
    remote="${GDRIVE_REMOTE}:${DRIVE_FOLDER}" \
    filename_encryption=standard \
    directory_name_encryption=true \
    password="$P1" password2="$P2" --obscure >/dev/null
  {
    echo "Remote rclone : ${CRYPT_REMOTE}  ->  ${GDRIVE_REMOTE}:${DRIVE_FOLDER}"
    echo "Mot de passe        : $P1"
    echo "Sel (password2)     : $P2"
    echo "Cree le             : $(date)"
  } > "$PASSFILE"
  chmod 600 "$PASSFILE"
  vert "OK : remote '${CRYPT_REMOTE}' cree"
fi

# --------------------------- Script temps reel -----------------------
echo "== Script de surveillance =="
cat > "$SCRIPT_BIN" <<EOF
#!/bin/bash
SRC="$SRC"
DEST="${CRYPT_REMOTE}:"
OPTS=(--retries 5 --log-file "$LOG" --log-level INFO)
EOF
cat >> "$SCRIPT_BIN" <<'EOF'

inotifywait -m -r -q \
  -e close_write -e moved_to -e delete -e moved_from \
  --exclude '(\.tmp$|\.part$|\.swp$|@eaDir|#recycle)' \
  --format '%e|%w%f' "$SRC" | while IFS='|' read -r EVENT FILE; do
    REL="${FILE#"$SRC"/}"
    case "$EVENT" in
      *ISDIR*)
        case "$EVENT" in
          *DELETE*|*MOVED_FROM*) rclone purge  "$DEST$REL" "${OPTS[@]}" ;;
          *MOVED_TO*)            rclone copy   "$FILE" "$DEST$REL" "${OPTS[@]}" ;;
        esac ;;
      *DELETE*|*MOVED_FROM*)     rclone deletefile "$DEST$REL" "${OPTS[@]}" ;;
      *)                         rclone copyto "$FILE" "$DEST$REL" "${OPTS[@]}" ;;
    esac
done
EOF
chmod +x "$SCRIPT_BIN"
vert "OK : $SCRIPT_BIN"

# --------------------------- Service systemd -------------------------
cat > "$SERVICE" <<EOF
[Unit]
Description=Synchro temps reel chiffree des cameras vers Google Drive
After=network-online.target local-fs.target
Wants=network-online.target

[Service]
ExecStart=$SCRIPT_BIN
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# --------------------------- Rattrapage periodique -------------------
cat > "$CRON" <<EOF
*/$CATCHUP_MIN * * * * root flock -n /run/cam-sync-full.lock rclone sync "$SRC" ${CRYPT_REMOTE}: --min-age 2m --exclude '@eaDir/**' --exclude '\#recycle/**' --log-file $LOG --log-level INFO
EOF
chmod 644 "$CRON"

# --------------------------- Journal & limites -----------------------
cat > "$LOGROTATE" <<EOF
$LOG {
  weekly
  rotate 4
  compress
  missingok
  notifempty
  copytruncate
}
EOF
echo "fs.inotify.max_user_watches=524288" > "$SYSCTL"
sysctl --system >/dev/null

# --------------------------- Demarrage -------------------------------
echo "== Demarrage du service =="
systemctl daemon-reload
systemctl enable --now cam-sync >/dev/null 2>&1
sleep 2
if systemctl is-active --quiet cam-sync; then
  vert "OK : service cam-sync actif"
else
  die "le service ne demarre pas. Voir : journalctl -u cam-sync -n 50"
fi

# --------------------------- Premier envoi ---------------------------
echo
# CAM_PREMIER_ENVOI=o|n : reponse fournie par NAS Manager (installation sans question)
if [ -n "${CAM_PREMIER_ENVOI:-}" ]; then REP="$CAM_PREMIER_ENVOI"
else read -r -p "Envoyer maintenant les videos deja presentes ? [o/N] " REP || REP=""; fi
if [[ "$REP" =~ ^[oOyY]$ ]]; then
  if [ -n "${CAM_PREMIER_ENVOI:-}" ]; then
    # depuis l'application : envoi en arriere-plan (peut durer longtemps)
    nohup setsid flock /run/cam-sync-full.lock rclone sync "$SRC" "${CRYPT_REMOTE}:" \
      --exclude '@eaDir/**' --exclude '\#recycle/**' --log-file "$LOG" --log-level INFO >/dev/null 2>&1 < /dev/null &
    vert "Envoi des videos existantes lance en arriere-plan (suivi : page Cameras)."
  else
    flock /run/cam-sync-full.lock rclone sync "$SRC" "${CRYPT_REMOTE}:" \
      --exclude '@eaDir/**' --exclude '\#recycle/**' -P
  fi
else
  jaune "Pas de souci : le rattrapage automatique s'en chargera (toutes les $CATCHUP_MIN min)."
fi

# --------------------------- Recapitulatif ---------------------------
echo
vert "=============== INSTALLATION TERMINEE ==============="
echo "Suivre les envois  : tail -f $LOG"
echo "Etat du service    : systemctl status cam-sync"
echo "Videos (en clair)  : rclone ls ${CRYPT_REMOTE}:"
echo "Desinstaller       : bash $0 --uninstall"
echo
rouge "=== NOTE CES MOTS DE PASSE EN LIEU SUR (hors du NAS) ==="
rouge "Sans eux, les videos du Drive sont DEFINITIVEMENT illisibles."
cat "$PASSFILE"
