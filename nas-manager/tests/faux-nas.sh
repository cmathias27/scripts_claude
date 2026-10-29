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
Subsystem sftp internal-sftp
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
conf=/tmp/faux-nas/rclone.conf
case "$cmd" in
  listremotes)
    if [[ " $* " == *" --long "* ]]; then awk '/^\[/{n=substr($0,2,length($0)-2)} /^type = /{print n": "$3}' "$conf"
    else grep -oE '^\[[^]]+\]' "$conf" | tr -d '[]' | sed 's/$/:/'; fi ;;
  config)
    sub="$1"; shift
    case "$sub" in
      file) printf 'Configuration file is stored at:\n%s\n' "$conf" ;;
      show) awk -v n="[$1]" '$0==n{p=1; print; next} /^\[/{p=0} p' "$conf" ;;
      delete) awk -v n="[$1]" '$0==n{p=1; next} /^\[/{p=0} !p' "$conf" > "$conf.new" && mv "$conf.new" "$conf" ;;
      *) exit 0 ;;
    esac ;;
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
  lsjson)
    p="$1"; t='2026-10-15T03:30:00.000000000+02:00'
    case "$p" in
      *_corbeille*/20*) echo "[{\"Path\":\"ancien.txt\",\"Name\":\"ancien.txt\",\"Size\":42,\"ModTime\":\"$t\",\"IsDir\":false}]" ;;
      *_corbeille*) echo "[{\"Path\":\"2026-10-15_0330\",\"Name\":\"2026-10-15_0330\",\"Size\":-1,\"ModTime\":\"$t\",\"IsDir\":true}]" ;;
      */2024) echo "[{\"Path\":\"IMG_1.jpg\",\"Name\":\"IMG_1.jpg\",\"Size\":3500000,\"ModTime\":\"$t\",\"IsDir\":false},{\"Path\":\"IMG_2.jpg\",\"Name\":\"IMG_2.jpg\",\"Size\":4100000,\"ModTime\":\"$t\",\"IsDir\":false}]" ;;
      *) echo "[{\"Path\":\"2024\",\"Name\":\"2024\",\"Size\":-1,\"ModTime\":\"$t\",\"IsDir\":true},{\"Path\":\"notes.txt\",\"Name\":\"notes.txt\",\"Size\":1234,\"ModTime\":\"$t\",\"IsDir\":false}]" ;;
    esac ;;
  lsf) n="${1##*/}"; [[ "$n" == *.* ]] && echo "$n" ;;
  check|cryptcheck)
    for ((i=0;i<${#args[@]};i++)); do
      case "${args[$i]}" in
        --match) printf 'a.jpg\nb.jpg\nc.jpg\n' > "${args[$((i+1))]}" ;;
        --missing-on-dst) printf 'nouveau.jpg\n' > "${args[$((i+1))]}" ;;
        --differ|--error|--missing-on-src) : > "${args[$((i+1))]}" ;;
      esac
    done
    exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod 755 /usr/local/bin/rclone

# remotes rclone du faux OMV : Google Drive (+ chiffres) et un disque USB
cat > /tmp/faux-nas/rclone.conf <<EOF
[gdrive]
type = drive
scope = drive

[gbackup]
type = crypt
remote = gdrive:NAS-chiffre

[gcrypt]
type = crypt
remote = gdrive:Cam-chiffre

[usb]
type = alias
remote = /srv/dev-disk-by-uuid-7cd5ac91-9ec8-439c-9de3-c5bf7f5418f5/Sauvegardes
EOF

# ---------------- faux smartctl : 3 disques (sda sain, sdb avec secteurs realloues, nvme0 sain)
#   /tmp/faux-nas/smart-sdb-en-attente : nombre de secteurs instables de sdb (alerte critique)
cat > /usr/local/bin/smartctl <<'EOF'
#!/bin/bash
dev="${*: -1}"
case " $* " in
  *" --scan "*) printf '/dev/sda -d sat # /dev/sda [SAT], ATA device\n/dev/sdb -d sat # /dev/sdb [SAT], ATA device\n/dev/nvme0 -d nvme # /dev/nvme0, NVMe device\n'; exit 0 ;;
esac
attente=$(cat /tmp/faux-nas/smart-sdb-en-attente 2>/dev/null || echo 0)
attr() { printf '{"id":%s,"value":%s,"raw":{"value":%s}}' "$1" "$2" "$3"; }
case "$dev" in
  /dev/sda) printf '{"device":{"protocol":"ATA"},"model_name":"WDC WD40EFRX-68N32N0","serial_number":"WD-SAIN0001","user_capacity":{"bytes":4000787030016},"rotation_rate":5400,"smart_status":{"passed":true},"temperature":{"current":34},"power_on_time":{"hours":21034},"ata_smart_attributes":{"table":[%s,%s,%s,%s]}}\n' \
    "$(attr 5 200 0)" "$(attr 197 200 0)" "$(attr 198 200 0)" "$(attr 199 200 0)" ;;
  /dev/sdb) printf '{"device":{"protocol":"ATA"},"model_name":"ST4000VN008-2DR166","serial_number":"ZDH0USE2","user_capacity":{"bytes":4000787030016},"rotation_rate":5900,"smart_status":{"passed":true},"temperature":{"current":38},"power_on_time":{"hours":35120},"ata_smart_attributes":{"table":[%s,%s,%s,%s]}}\n' \
    "$(attr 5 100 8)" "$(attr 197 100 "$attente")" "$(attr 198 100 0)" "$(attr 199 200 0)" ;;
  /dev/nvme0) printf '{"device":{"protocol":"NVMe"},"model_name":"Samsung SSD 970 EVO Plus 500GB","serial_number":"S4EVNX0N1234","nvme_total_capacity":500107862016,"smart_status":{"passed":true},"temperature":{"current":41},"power_on_time":{"hours":8800},"nvme_smart_health_information_log":{"critical_warning":0,"temperature":41,"available_spare":100,"available_spare_threshold":10,"percentage_used":3,"power_on_hours":8800,"media_errors":0}}\n' ;;
  *) exit 2 ;;
esac
EOF
chmod 755 /usr/local/bin/smartctl
rm -f /tmp/faux-nas/smart-sdb-en-attente /root/.nas-synology/disques.json

# ---------------- OMV simule
# (liens laisses par un test precedent : supprimes avant d'ecrire les anciens scripts)
rm -f /usr/local/bin/nas-notify /usr/local/bin/nas-check /usr/local/bin/nas-backup /usr/local/bin/nas-ha-status
D=/srv/dev-disk-by-uuid-7cd5ac91-9ec8-439c-9de3-c5bf7f5418f5
mkdir -p $D/Photos $D/Documents $D/Cam $D/Musique $D/Sauvegardes /etc/nas-backup /var/lib/nas-backup/alertes
rm -f /etc/nas-backup/restic.pass /etc/nas-backup/secours.pass /var/lib/nas-backup/destinations.json
rm -rf /var/lib/nas-backup/secours
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
printf 'HA_URL="http://127.0.0.1:9"\nWEBHOOK="test"\nREPEAT_HOURS=12\nQUOTA_ALERT=90\nLATE_HOURS=50\n' > /etc/nas-backup/notify.conf
printf '#!/bin/bash\nSRC="%s/Cam"\n' $D > /usr/local/bin/cam-sync.sh; chmod 755 /usr/local/bin/cam-sync.sh
echo "$(date '+%Y/%m/%d %H:%M:%S') INFO  : Garage/clip_1.mp4: Copied (new)" > /var/log/cam-sync.log
printf '#!/bin/bash\necho "notify $*" >> /tmp/nas-notify.log\n' > /usr/local/bin/nas-notify; chmod 755 /usr/local/bin/nas-notify
printf '#!/bin/bash\nsleep 5\n' > /usr/local/bin/nas-check; chmod 755 /usr/local/bin/nas-check
touch /var/log/nas-backup.log
echo "30 3 * * * root /usr/local/bin/nas-backup run-at 03:30 >/dev/null 2>&1" > /etc/cron.d/nas-backup

# ---------------- ancienne installation (avant nas-debian / nas-synology) : test de la migration
DEPOT="$(cd "$(dirname "$0")/../.." && pwd)"
rm -f /usr/local/bin/nas-debian /usr/local/bin/nas-debian.bak /usr/local/bin/nas-synology /usr/local/bin/nas-synology.bak
rm -f /usr/local/bin/nas-backup /usr/local/bin/nas-ha-status /usr/local/bin/copie-omv /usr/local/bin/migre-drive-ocis
rm -rf /root/.nas-manager/ancien /root/.nas-synology /etc/nas-backup/agent.conf
# sauvegardes temps reel laissees par un test precedent
command -v systemctl >/dev/null && systemctl list-units --plain --no-legend 'nas-temps-reel@*' 2>/dev/null | awk '{print $1}' | xargs -r systemctl disable --now 2>/dev/null || true
pkill -f '/usr/local/bin/nas-debian temps-reel surveiller' 2>/dev/null || true
rm -f /etc/nas-backup/temps-reel.conf /etc/cron.d/nas-temps-reel /var/lib/nas-backup/rt-* /var/log/nas-temps-reel/*.log
install -m 755 "$DEPOT/ancien/nas-backup.sh" /usr/local/bin/nas-backup
sed 's/^OMV_HOST="[^"]*"/OMV_HOST="127.0.0.1"/' "$DEPOT/ancien/copie-omv.sh" > /usr/local/bin/copie-omv
install -m 755 "$DEPOT/ancien/migre-drive-ocis.sh" /usr/local/bin/migre-drive-ocis
chmod 755 /usr/local/bin/copie-omv

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
