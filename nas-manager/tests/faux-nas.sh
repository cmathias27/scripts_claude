#!/bin/bash
# =====================================================================
#  faux-nas.sh : simule un OMV et un Synology sur la machine locale pour
#  les tests de NAS Manager (utilise par GitHub Actions).
#
#  Usage (en root) : bash tests/faux-nas.sh <dossier de l'application>
#  Puis :  NAS_MANAGER_DIR=<dossier> NAS_MANAGER_LIVE_TEST=1 \
#          NAS_MANAGER_TEST_SUDO=Secret123 cargo test -- --test-threads=1
#
#  - sshd sur 127.0.0.1:2222 (connexions de l'application) et :22
#    (connexion Synology -> OMV de copie-omv)
#  - OMV   : root@127.0.0.1:2222
#  - Synology : syno@127.0.0.1:2222, administrateur avec sudo (Secret123)
#  - faux rclone, fausses sauvegardes, cameras, migration...
#  NE PAS LANCER SUR UNE VRAIE MACHINE : modifie /root, /etc, /srv, /volume1.
# =====================================================================
set -euo pipefail
APP="${1:?usage : faux-nas.sh DOSSIER_APPLICATION}"
[ "$(id -u)" -eq 0 ] || { echo "lancer en root"; exit 1; }
OWNER="${SUDO_USER:-root}"
W=/tmp/faux-nas; mkdir -p "$W" /run/sshd

# ---------------- sshd
ssh-keygen -A >/dev/null 2>&1 || true
cat > "$W/sshd_config" <<EOF
Port 2222
Port 22
ListenAddress 127.0.0.1
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM yes
PidFile $W/sshd.pid
EOF
[ -f "$W/sshd.pid" ] && kill "$(cat "$W/sshd.pid")" 2>/dev/null || true
command -v systemctl >/dev/null && systemctl stop ssh ssh.socket 2>/dev/null || true
/usr/sbin/sshd -f "$W/sshd_config"

# ---------------- comptes et cle de l'application
id syno >/dev/null 2>&1 || useradd -m -s /bin/bash syno
echo 'syno:Secret123' | chpasswd
echo 'syno ALL=(ALL) ALL' > /etc/sudoers.d/syno; chmod 440 /etc/sudoers.d/syno
mkdir -p "$APP"
[ -f "$APP/id_ed25519" ] || ssh-keygen -t ed25519 -q -N "" -C nas-manager -f "$APP/id_ed25519"
for d in /root /home/syno; do
  mkdir -p $d/.ssh; cat "$APP/id_ed25519.pub" >> $d/.ssh/authorized_keys
  chmod 700 $d/.ssh; chmod 600 $d/.ssh/authorized_keys
done
chown -R syno:syno /home/syno/.ssh
# cle root du « Synology » vers « l'OMV » (copie-omv)
[ -f /root/.ssh/id_copie_omv ] || ssh-keygen -t ed25519 -q -N "" -C copie -f /root/.ssh/id_copie_omv
grep -qxF "$(cat /root/.ssh/id_copie_omv.pub)" /root/.ssh/authorized_keys || cat /root/.ssh/id_copie_omv.pub >> /root/.ssh/authorized_keys
sleep 1
ssh-keyscan -p 2222 127.0.0.1 2>/dev/null > "$APP/known_hosts"
cat > "$APP/parametres.json" <<EOF
{"omv":{"host":"127.0.0.1","port":2222,"user":"root","sudo":false,"saved_pass":""},
 "syno":{"host":"127.0.0.1","port":2222,"user":"syno","sudo":true,"saved_pass":""},
 "refresh_secs":5,"ssh_bin":"","theme":"systeme","read_only":false,"last_version":""}
EOF
chown -R "$OWNER" "$APP"

# ---------------- faux rclone
cat > /usr/local/bin/rclone <<'EOF'
#!/bin/bash
cmd="$1"; shift
log=""; dur=${FAKE_DUR:-20}
args=("$@")
for ((i=0;i<${#args[@]};i++)); do [ "${args[$i]}" = "--log-file" ] && log="${args[$((i+1))]}"; done
case "$cmd" in
  listremotes) printf 'gdrive:\ngbackup:\ngcrypt:\n' ;;
  about) echo '{"total":2199023255552,"used":1301234567890}' ;;
  obscure) echo obscured ;;
  version) echo "rclone v1.70.0-faux" ;;
  sync|copy|copyto)
    [ -n "$log" ] || log=/dev/null
    if [[ " $* " == *" --dry-run "* ]]; then
      d=$(date '+%Y/%m/%d %H:%M:%S')
      printf '%s NOTICE: 2024/IMG_1.jpg: Skipped copy as --dry-run is set (size 3.5Mi)\n%s NOTICE: 2024/IMG_2.jpg: Skipped copy as --dry-run is set (size 1.2Gi)\n%s NOTICE: vieux.txt: Skipped delete as --dry-run is set (size 10)\n' "$d" "$d" "$d" >> "$log"
      exit 0
    fi
    for ((s=1;s<=dur;s+=2)); do
      sleep 2; pct=$(( 100 * s / dur ))
      printf '%s INFO  : \nTransferred:   \t  %d.000 MiB / 4096.000 MiB, %d%%, 68.400 MiB/s, ETA %ds\nTransferred:            %d / 120, %d%%\nElapsed time:        %d.0s\n\n' \
        "$(date '+%Y/%m/%d %H:%M:%S')" $((4096*s/dur)) $pct $((dur-s)) $((120*s/dur)) $pct $s >> "$log"
    done ;;
  *) exit 0 ;;
esac
EOF
chmod 755 /usr/local/bin/rclone

# ---------------- OMV simule
D=/srv/dev-disk-by-uuid-7cd5ac91-9ec8-439c-9de3-c5bf7f5418f5
mkdir -p $D/Photos $D/Documents $D/Cam $D/Musique /etc/nas-backup /var/lib/nas-backup/alertes
cat > /etc/nas-backup/jobs.conf <<EOF
# NOM|SOURCE|DOSSIER_DRIVE|MODE(sync/copy)|CHIFFRE(oui/non)|HORAIRE(HH:MM/manuel)|CORBEILLE_JOURS
Photos|$D/Photos|Photos|sync|oui|03:30|30
Documents|$D/Documents|Documents|copy|oui|04:15|0
Musique|$D/Musique|Musique|sync|non|manuel|7
EOF
echo "$(date '+%Y-%m-%d') 03:41 OK" > /var/lib/nas-backup/Photos.status
date +%s > /var/lib/nas-backup/Photos.lastok
echo "$(date '+%Y-%m-%d') 04:16 ECHEC" > /var/lib/nas-backup/Documents.status
echo '{"gdrive":true,"quota_pct":59,"used_go":1301.2,"total_go":2199.0,"checked":"2026-10-18T12:07:01+02:00"}' > /var/lib/nas-backup/health.json
touch /var/lib/nas-backup/alertes/job-Documents
printf '#!/bin/bash\nSRC="%s/Cam"\n' $D > /usr/local/bin/cam-sync.sh; chmod 755 /usr/local/bin/cam-sync.sh
echo "$(date '+%Y/%m/%d %H:%M:%S') INFO  : Garage/clip_1.mp4: Copied (new)" > /var/log/cam-sync.log
printf '#!/bin/bash\necho "notify $*" >> /tmp/nas-notify.log\n' > /usr/local/bin/nas-notify; chmod 755 /usr/local/bin/nas-notify
printf '#!/bin/bash\nsleep 5\n' > /usr/local/bin/nas-check; chmod 755 /usr/local/bin/nas-check
touch /var/log/nas-backup.log

# ---------------- Synology simule
mkdir -p /volume1/homes/alice/Drive/Projets /volume1/homes/bob/Drive /volume1/photo/2023 /volume4/utils
for i in 1 2 3; do head -c 200000 /dev/urandom > /volume1/photo/2023/img_$i.jpg; done
mkdir -p /root/.migre-ocis
cat > /root/.migre-ocis/config <<'EOF'
OCIS_URL=https://cloud.exemple.fr
LOCAL_URL=
OCIS_USER=migration
OCIS_PASS=xxx
OCIS_INSECURE=0
OCIS_VENDOR=owncloud
EOF
echo "faux NAS pret : $APP"
