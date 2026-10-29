#!/bin/bash
# =====================================================================
#  confort.sh : test des fonctions de confort de nas-debian (etape 8) avec le
#  VRAI rclone : debit selon l'heure (limite commune), estimation avant la
#  premiere sauvegarde, doublons (analyse, corbeille des doublons), actions
#  depuis Home Assistant (vrai serveur MQTT mosquitto local) et installation de
#  l'interface texte (nas-manager).
#
#  Usage (en root) : bash tests/confort.sh [rclone]
#  Les reglages de /etc/nas-backup sont remis en etat a la fin.
#  NE PAS LANCER SUR UNE VRAIE MACHINE : ecrit dans /etc/nas-backup et /root.
# =====================================================================
set -uo pipefail
REEL="${1:-/usr/bin/rclone}"
[ "$(id -u)" -eq 0 ] || { echo "lancer en root"; exit 1; }
[ -x "$REEL" ] || { echo "rclone introuvable : $REEL"; exit 1; }
command -v mosquitto >/dev/null || { echo "mosquitto absent (apt install mosquitto mosquitto-clients)"; exit 1; }
DEPOT="$(cd "$(dirname "$0")/../.." && pwd)"
W=/tmp/confort-moteur
rm -rf "${W:?}"; mkdir -p "$W/bin" "$W/src" "$W/gd" "$W/etc-avant" "$W/mqtt"
# rclone : on note les options de chaque appel puis on lance le vrai
cat > "$W/bin/rclone" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$W/rclone-appels.txt"
exec "$REEL" "\$@"
EOF
chmod 755 "$W/bin/rclone"
printf '[gdrive]\ntype = alias\nremote = %s/gd\n' "$W" > "$W/rclone.conf"
export RCLONE_CONFIG="$W/rclone.conf" PATH="$W/bin:/usr/sbin:/usr/bin:/sbin:/bin" NAS_SANS_SYSTEMD=1
mkdir -p /etc/nas-backup /var/lib/nas-backup /root/.config
cp -a /etc/nas-backup/. "$W/etc-avant/"
for f in /root/.config/mosquitto_pub /root/.config/mosquitto_sub /root/nas-backup-motsdepasse.txt; do
  [ -f "$f" ] && cp -p "$f" "$W/etc-avant/$(basename "$f").sauve"
done
: > /etc/nas-backup/temps-reel.conf
echo "# test" > /etc/nas-backup/jobs.conf
rm -f /var/lib/nas-backup/historique.jsonl.test
[ -f /var/lib/nas-backup/historique.jsonl ] && mv /var/lib/nas-backup/historique.jsonl "$W/historique.sauve"
install -m 755 "$DEPOT/nas-debian.sh" /usr/local/bin/nas-debian
ND=/usr/local/bin/nas-debian
S=$W/src J=$W/journal.txt ST=/var/lib/nas-backup ok=0 ko=0 MQ=18883

check() {  # check <description> <commande de test>
  if eval "$2"; then ok=$((ok + 1)); echo "  ok   $1"; else ko=$((ko + 1)); echo "  ECHEC $1"; echo "== ECHEC $1" >> "$J"; return 1; fi
}
jq_() {  # jq_ <fichier json> <expression python sur d>
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($2) else 1)" "$1" 2>/dev/null
}
remettre() {
  $ND suivi actions non >/dev/null 2>&1
  [ -f "$W/mqtt/pid" ] && kill "$(cat "$W/mqtt/pid")" 2>/dev/null
  pkill -f "doublons.py $ST/doublons.json" 2>/dev/null
  rm -rf "$ST"/T_* "$ST/doublons.json" "$ST/doublons.py" "$ST/doublons.pid" "$ST/mqtt-jobs.json" /usr/local/bin/nas-manager
  rm -f /etc/nas-backup/*
  cp -a "$W/etc-avant/." /etc/nas-backup/
  rm -f /etc/nas-backup/*.sauve /root/.config/mosquitto_pub /root/.config/mosquitto_sub
  for f in mosquitto_pub mosquitto_sub; do [ -f "$W/etc-avant/$f.sauve" ] && cp -p "$W/etc-avant/$f.sauve" "/root/.config/$f"; done
  [ -f "$W/etc-avant/nas-backup-motsdepasse.txt.sauve" ] && cp -p "$W/etc-avant/nas-backup-motsdepasse.txt.sauve" /root/nas-backup-motsdepasse.txt
  rm -f "$ST/historique.jsonl"; [ -f "$W/historique.sauve" ] && mv "$W/historique.sauve" "$ST/historique.jsonl"
  return 0
}
diagnostic() {
  echo "---- sorties des commandes"; sed 's/\x1b\[[0-9;]*m//g' "$J" | tail -n 80
  echo "---- journal nas-backup"; tail -n 20 /var/log/nas-backup.log 2>/dev/null
}
trap remettre EXIT
appels() { cat "$W/rclone-appels.txt" 2>/dev/null; }

echo "== Debit selon l'heure (limite commune de la machine)"
$ND reglages debit "08:00,2M 23:00,off" >>"$J" 2>&1
check "limite enregistree et visible" "$ND reglages voir > $W/r.json && jq_ $W/r.json 'd[\"debit\"]==\"08:00,2M 23:00,off\" and d[\"ha_actions\"] is False'"
check "limite invalide refusee (rclone)" "! $ND reglages debit '25:00,2M' >>$J 2>&1 && ! $ND reglages debit 'a;b' >>$J 2>&1"
mkdir -p "$S/Docs"; echo a > "$S/Docs/a.txt"; head -c 300000 /dev/urandom > "$S/Docs/b.bin"
$ND save nouveau T_Docs "$S/Docs" Docs copy non manuel 0 "" "" "gdrive:non" "" >>"$J" 2>&1
: > "$W/rclone-appels.txt"
$ND run T_Docs >>"$J" 2>&1
check "sauvegarde sans limite propre : limite de la machine" "grep -q ' OK$' $ST/T_Docs.status && appels | grep -E '^copy ' | grep -q -- '--bwlimit 08:00,2M 23:00,off'"
$ND save modif T_Docs "$S/Docs" Docs copy non manuel 0 "off" "" "gdrive:non" "" >>"$J" 2>&1
: > "$W/rclone-appels.txt"; echo c > "$S/Docs/c.txt"
$ND run T_Docs >>"$J" 2>&1
check "« sans limite » : aucune option --bwlimit" "appels | grep -E '^copy ' | grep -vq -- '--bwlimit' && [ -f $W/gd/NAS/Docs/c.txt ]"
$ND save modif T_Docs "$S/Docs" Docs copy non manuel 0 "5M" "" "gdrive:non" "" >>"$J" 2>&1
: > "$W/rclone-appels.txt"; echo d > "$S/Docs/d.txt"
$ND run T_Docs >>"$J" 2>&1
check "limite propre de la sauvegarde prioritaire" "appels | grep -E '^copy ' | grep -q -- '--bwlimit 5M'"
$ND reglages debit - >>"$J" 2>&1
check "limite commune retiree" "$ND reglages voir > $W/r.json && jq_ $W/r.json 'd[\"debit\"]==\"\"'"

echo "== Estimation avant la premiere sauvegarde"
mkdir -p "$S/Photos/2024"
for i in 1 2 3; do head -c 200000 /dev/urandom > "$S/Photos/2024/IMG_$i.jpg"; done
mkdir -p "$S/Photos/@eaDir"; echo x > "$S/Photos/@eaDir/vignette"
rm -f "$ST/historique.jsonl"
$ND estimer "$S/Photos" gdrive non > "$W/e.json" 2>>"$J"
check "volume (exclusions comprises) et debit mesure par un envoi de test" "jq_ $W/e.json 'd[\"fichiers\"]==3 and d[\"octets\"]==600000 and d[\"methode\"]==\"test\" and d[\"debit_mesure\"]>0 and d[\"duree_s\"] is not None'"
check "fichier de test efface de la destination" "! find $W/gd -name '.nas-manager-test-debit*' | grep -q ."
$ND save nouveau T_Photos "$S/Photos" Photos sync oui manuel 7 "" "" "gdrive:oui" "" >>"$J" 2>&1
$ND reglages debit 1M >>"$J" 2>&1
$ND estimer T_Photos > "$W/e2.json" 2>>"$J"
check "par nom de sauvegarde : limite de debit prise en compte" "jq_ $W/e2.json 'd[\"nom\"]==\"T_Photos\" and d[\"limite\"]==\"1M\" and d[\"debit_effectif\"]<=1048576'"
$ND reglages debit - >>"$J" 2>&1
echo '{"nom":"X","destinations":[{"destination":"gdrive","code":0,"volume_octets":100000000,"debut":1000,"fin":1100}]}' > "$ST/historique.jsonl"
$ND estimer "$S/Photos" gdrive non > "$W/e3.json" 2>>"$J"
check "debit repris des sauvegardes precedentes (1 Mo/s)" "jq_ $W/e3.json 'd[\"methode\"]==\"historique\" and d[\"debit_mesure\"]==1000000'"
check "dossier introuvable refuse" "! $ND estimer /nulle/part gdrive >>$J 2>&1"

echo "== Doublons"
D=$W/dup; mkdir -p "$D/a" "$D/b/c" "$D/.corbeille-x"
head -c 300000 /dev/urandom > "$D/a/photo.jpg"; cp -p "$D/a/photo.jpg" "$D/b/copie.jpg"; cp "$D/a/photo.jpg" "$D/b/c/encore.jpg"
touch -d '2020-01-01' "$D/a/photo.jpg"
head -c 300000 /dev/urandom > "$D/a/autre.jpg"                 # meme taille, contenu different
head -c 150000 /dev/urandom > "$D/a/doc.pdf"; cp "$D/a/doc.pdf" "$D/b/doc.pdf"
head -c 200000 /dev/urandom > "$D/a/seul.bin"; ln "$D/a/seul.bin" "$D/b/lien-physique.bin"   # meme fichier : pas un doublon
echo petit > "$D/a/p1.txt"; echo petit > "$D/b/p2.txt"           # sous la taille minimale
cp "$D/a/autre.jpg" "$D/.corbeille-x/autre.jpg"                  # dossier ignore
$ND doublons analyser --min 100 "$D" >>"$J" 2>&1
for _ in $(seq 1 60); do $ND doublons etat > "$W/d.json"; jq_ "$W/d.json" 'd["etat"]!="en_cours"' && break; sleep 1; done
$ND doublons voir > "$W/d.json"
check "analyse terminee : 2 groupes, 3 fichiers en trop" "jq_ $W/d.json 'd[\"etat\"]==\"fini\" and d[\"nb_groupes\"]==2 and d[\"fichiers_en_trop\"]==3 and d[\"recuperable\"]==750000'"
check "le plus ancien en premier, liens physiques et dossiers techniques ignores" "jq_ $W/d.json 'd[\"groupes\"][0][\"fichiers\"][0][\"chemin\"].endswith(\"a/photo.jpg\") and len(d[\"groupes\"][1][\"fichiers\"])==2 and not any(\".corbeille\" in f[\"chemin\"] for g in d[\"groupes\"] for f in g[\"fichiers\"])'"
check "dossier systeme refuse" "! $ND doublons analyser /etc >>$J 2>&1"
printf '%s\n%s\n' "$D/b/doc.pdf" "$D/a/doc.pdf" | $ND doublons supprimer >>"$J" 2>&1
check "groupe entierement choisi : rien deplace" "[ -f $D/a/doc.pdf ] && [ -f $D/b/doc.pdf ]"
echo modifie >> "$D/b/c/encore.jpg"
printf '%s\n%s\n' "$D/b/copie.jpg" "$D/b/c/encore.jpg" | $ND doublons supprimer >>"$J" 2>&1
check "doublon deplace dans la corbeille des doublons (meme arborescence)" "[ ! -f $D/b/copie.jpg ] && ls $D/.corbeille-doublons/*/b/copie.jpg >/dev/null 2>&1 && [ -f $D/a/photo.jpg ]"
check "fichier modifie depuis l'analyse : garde" "[ -f $D/b/c/encore.jpg ]"
$ND doublons voir > "$W/d.json"
check "resultat mis a jour, corbeille comptee" "jq_ $W/d.json 'd[\"corbeille\"][\"fichiers\"]==1 and d[\"corbeille\"][\"octets\"]==300000'"
check "corbeille des doublons exclue des sauvegardes" "grep -q \"^EXCLUDES=.*corbeille-doublons\" $ND"
$ND doublons vider >>"$J" 2>&1
check "corbeille videe" "[ ! -d $D/.corbeille-doublons ]"

echo "== Actions depuis Home Assistant (MQTT)"
printf 'listener %s 127.0.0.1\nallow_anonymous true\npersistence false\n' "$MQ" > "$W/mqtt/conf"
mosquitto -c "$W/mqtt/conf" -d 2>>"$J"; sleep 1
pgrep -f "mosquitto -c $W/mqtt/conf" | head -n 1 > "$W/mqtt/pid"
printf -- '-h 127.0.0.1\n-p %s\n' "$MQ" > /root/.config/mosquitto_pub
$ND suivi actions oui >>"$J" 2>&1
sleep 1
check "ecoute active, reglage visible" "$ND reglages voir > $W/r.json && jq_ $W/r.json 'd[\"ha_actions\"] is True and d[\"ha_actions_actif\"] is True'"
mosquitto_sub -h 127.0.0.1 -p "$MQ" -t 'homeassistant/#' -v -W 3 > "$W/disc.txt" 2>/dev/null
check "boutons et interrupteurs publies (decouverte MQTT)" "grep -q 'button/nas_.*/lancer_t_docs/config .*\"payload_press\": \"lancer|T_Docs\"' $W/disc.txt && grep -q 'button/nas_.*/arreter_sauvegardes/config' $W/disc.txt"
SLUG=$(grep -o 'nas-[a-z0-9_]*/commande' "$W/disc.txt" | head -n 1)
rm -f "$ST/T_Docs.status"; echo e > "$S/Docs/e.txt"
mosquitto_pub -h 127.0.0.1 -p "$MQ" -t "$SLUG" -m 'lancer|T_Docs'
for _ in $(seq 1 30); do grep -q ' OK$' "$ST/T_Docs.status" 2>/dev/null && break; sleep 1; done
check "bouton « Lancer » : sauvegarde lancee" "grep -q ' OK$' $ST/T_Docs.status && [ -f $W/gd/NAS/Docs/e.txt ]"
mosquitto_pub -h 127.0.0.1 -p "$MQ" -t "$SLUG" -m 'lancer|T_Docs; rm -rf /'
mosquitto_pub -h 127.0.0.1 -p "$MQ" -t "$SLUG" -m 'effacer|tout'
sleep 2
check "commandes inconnues ou noms inexistants refuses (journal)" "grep -q 'sauvegarde inconnue refusee' /var/log/nas-backup.log && grep -q 'commande refusee' /var/log/nas-backup.log"
check "temps reel inexistant refuse" "! $ND ha-actions executer 'pause|nulle' >>$J 2>&1"
$ND suivi actions non >>"$J" 2>&1
mosquitto_sub -h 127.0.0.1 -p "$MQ" -t 'homeassistant/button/#' -v -W 2 > "$W/disc2.txt" 2>/dev/null
check "desactivees : ecoute arretee, boutons retires" "$ND reglages voir > $W/r.json && jq_ $W/r.json 'd[\"ha_actions_actif\"] is False' && ! grep -q 'lancer_t_docs' $W/disc2.txt"

echo "== Autres clouds (destinations)"
$ND destinations creer yd yandex < /dev/null > "$W/c1.txt" 2>&1; $ND destinations creer hd hidrive < /dev/null > "$W/c2.txt" 2>&1
check "Yandex Disk et HiDrive : connexion par le navigateur" "grep -q navigateur $W/c1.txt && grep -q navigateur $W/c2.txt"
for t in mega koofr protondrive; do
  printf 'user=x@y.fr\npass=faux\nusername=x@y.fr\npassword=faux\n' | timeout 120 $ND destinations creer "t_$t" "$t" > "$W/c.txt" 2>&1
  check "$t : type reconnu (refus de connexion, pas de type inconnu), rien de cree" "! grep -q 'type de destination inconnu' $W/c.txt && ! rclone listremotes | grep -q '^t_$t'"
done

echo "== Interface texte (installation)"
check "etat : pas installee" "$ND tui etat | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if not d[\"installe\"] and d[\"architecture\"] else 1)'"
A=$(uname -m | sed 's/amd64/x86_64/; s/arm64/aarch64/; s/armv8l/armv7/; s/armv7.*/armv7/')
mkdir -p "$W/rel"
printf '#!/bin/sh\necho "nas-manager 9.9.9"\n' > "$W/rel/nas-manager-tui-$A"
(cd "$W/rel" && sha256sum "nas-manager-tui-$A" > "nas-manager-tui-$A.sha256")
NAS_TUI_URL="file://$W/rel" $ND tui installer >>"$J" 2>&1
check "installee depuis la publication, empreinte verifiee" "$ND tui etat | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d[\"installe\"] and d[\"version\"]==\"9.9.9\" else 1)'"
echo "0000 x" > "$W/rel/nas-manager-tui-$A.sha256"
check "empreinte incorrecte : refusee" "! NAS_TUI_URL=file://$W/rel $ND tui installer >>$J 2>&1"
$ND tui supprimer >>"$J" 2>&1

[ "$ko" -ne 0 ] && diagnostic
remettre; trap - EXIT
rm -rf "${W:?}"
echo
echo "$ok verification(s) reussie(s), $ko en echec"
[ "$ko" -eq 0 ]
