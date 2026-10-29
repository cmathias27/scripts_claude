#!/bin/bash
# =====================================================================
#  restauration.sh : test de l'etape 5 de nas-debian (fiabilite et
#  restauration) avec le VRAI rclone (remotes locaux) et le VRAI restic :
#    - test de restauration a blanc (fichiers au hasard, ecarts, versions)
#    - retour a une date precise (corbeille datee, versions)
#    - reveil des destinations (Wake-on-LAN : paquet, attente, veille)
#
#  Usage (en root) : bash tests/restauration.sh [rclone] [restic]
#  (par defaut /usr/bin/rclone et /usr/bin/restic). Les reglages de
#  /etc/nas-backup sont remis en etat a la fin.
#  NE PAS LANCER SUR UNE VRAIE MACHINE : ecrit dans /etc/nas-backup et /root.
# =====================================================================
set -uo pipefail
REEL="${1:-/usr/bin/rclone}"
RESTIC="${2:-/usr/bin/restic}"
[ "$(id -u)" -eq 0 ] || { echo "lancer en root"; exit 1; }
[ -x "$REEL" ] || { echo "rclone introuvable : $REEL"; exit 1; }
[ -x "$RESTIC" ] || { echo "restic introuvable : $RESTIC"; exit 1; }
DEPOT="$(cd "$(dirname "$0")/../.." && pwd)"
W=/tmp/restau-moteur
rm -rf "${W:?}"; mkdir -p "$W/bin" "$W/src" "$W/gd" "$W/usb" "$W/etc-avant"
ln -sf "$REEL" "$W/bin/rclone"; ln -sf "$RESTIC" "$W/bin/restic"
printf '[gdrive]\ntype = alias\nremote = %s/gd\n\n[usb]\ntype = alias\nremote = %s/usb\n' "$W" "$W" > "$W/rclone.conf"
# reveil : ports testes limites (ici, 80 et 443 passent par le proxy de la machine de test)
export RCLONE_CONFIG="$W/rclone.conf" PATH="$W/bin:/usr/sbin:/usr/bin:/sbin:/bin" NAS_SANS_SYSTEMD=1 NAS_REVEIL_PORTS="22 445"
mkdir -p /etc/nas-backup /var/lib/nas-backup
cp -a /etc/nas-backup/. "$W/etc-avant/"
for f in /root/nas-backup-motsdepasse.txt /etc/cron.d/nas-backup; do [ -f "$f" ] && cp -p "$f" "$W/etc-avant/$(basename "$f").sauve"; done
: > /etc/nas-backup/temps-reel.conf
echo "# test" > /etc/nas-backup/jobs.conf
rm -f /etc/nas-backup/restic.pass /etc/nas-backup/reveil.conf /etc/nas-backup/test-restauration /root/nas-backup-motsdepasse.txt
install -m 755 "$DEPOT/nas-debian.sh" /usr/local/bin/nas-debian
ND=/usr/local/bin/nas-debian
S=$W/src J=$W/journal.txt ST=/var/lib/nas-backup ok=0 ko=0

check() {  # check <description> <commande de test>
  if eval "$2"; then ok=$((ok + 1)); echo "  ok   $1"; else ko=$((ko + 1)); echo "  ECHEC $1"; echo "== ECHEC $1" >> "$J"; return 1; fi
}
jq_() {  # jq_ <fichier json> <expression python sur d>
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($2) else 1)" "$1" 2>/dev/null
}
remettre() {
  rm -rf "$ST"/T_* "$ST/destinations.json" "$ST"/reveil-* "$ST/tests-restauration.jsonl" "$ST"/alertes/*T_* "$ST/alertes/dest-usb"
  rm -f /etc/nas-backup/*
  cp -a "$W/etc-avant/." /etc/nas-backup/
  rm -f /etc/nas-backup/*.sauve
  if [ -f "$W/etc-avant/nas-backup-motsdepasse.txt.sauve" ]; then cp -p "$W/etc-avant/nas-backup-motsdepasse.txt.sauve" /root/nas-backup-motsdepasse.txt; else rm -f /root/nas-backup-motsdepasse.txt; fi
  [ -f "$W/etc-avant/nas-backup.sauve" ] && cp -p "$W/etc-avant/nas-backup.sauve" /etc/cron.d/nas-backup
  return 0
}
diagnostic() {
  echo "---- sorties des commandes"; sed 's/\x1b\[[0-9;]*m//g' "$J" | tail -n 60
  local f; for f in "$ST"/T_*.test.log "$ST"/restauration.log; do [ -f "$f" ] && { echo "---- $f"; tail -n 15 "$f"; }; done
}
trap remettre EXIT
rm -f "$ST"/alertes/*T_* "$ST/alertes/dest-usb"
ancien() { touch -d '-2 hours' "$@"; }

echo "== Test de restauration a blanc (miroir, Drive chiffre + disque)"
mkdir -p "$S/Docs/sous"
for i in 1 2 3 4 5 6; do head -c $((1000 * i)) /dev/urandom > "$S/Docs/f$i.bin"; done
echo b > "$S/Docs/sous/b.txt"; ancien "$S/Docs"/*.bin "$S/Docs/sous/b.txt"
$ND save nouveau T_Docs "$S/Docs" Docs sync oui manuel 30 "" "" "gdrive:oui;usb:non" "" >>"$J" 2>&1
$ND test-restauration T_Docs 3 >>"$J" 2>&1
check "avant toute sauvegarde : rien a tester, pas d'alerte" "jq_ $ST/T_Docs.test.json 'd[\"etat\"] == \"vide\"' && [ ! -e $ST/alertes/test-T_Docs ]"
$ND run T_Docs >>"$J" 2>&1
check "sauvegarde OK" "grep -q ' OK$' $ST/T_Docs.status && [ -s $ST/T_Docs.lastdebut ]"
$ND test-restauration T_Docs 3 >>"$J" 2>&1
check "test : 3 fichiers identiques sur les 2 destinations" "jq_ $ST/T_Docs.test.json 'd[\"etat\"] == \"ok\" and d[\"nb\"] == 3 and d[\"identiques\"] == 6 and d[\"destinations\"] == \"gdrive:ok;usb:ok\"'"
check "dossier temporaire efface" "! ls -d /var/tmp/nas-test-restauration.* >/dev/null 2>&1"
check "historique des tests" "grep -q '\"nom\": \"T_Docs\"' $ST/tests-restauration.jsonl"
echo nouveau > "$S/Docs/recent.txt"
$ND test-restauration T_Docs 50 >>"$J" 2>&1
check "fichier plus recent que la sauvegarde : pas teste" "! grep -q recent.txt $ST/T_Docs.test.json && jq_ $ST/T_Docs.test.json 'd[\"nb\"] == 7'"
printf 'abime' > "$W/usb/NAS/Docs/f2.bin"; rm -f "$W/usb/NAS/Docs/sous/b.txt"
$ND test-restauration T_Docs 50 >>"$J" 2>&1
check "copie abimee et fichier absent detectes sur le disque seulement" "jq_ $ST/T_Docs.test.json 'd[\"etat\"] == \"ecarts\" and d[\"ecarts\"] == 2 and d[\"destinations\"] == \"gdrive:ok;usb:ecarts\" and {(f[\"chemin\"], f[\"resultat\"]) for f in d[\"fichiers\"] if f[\"resultat\"] != \"identique\"} == {(\"f2.bin\", \"different\"), (\"sous/b.txt\", \"absent\")}'"
check "alerte critique en cours" "[ -e $ST/alertes/test-T_Docs ]"
$ND run T_Docs >>"$J" 2>&1; ancien "$S/Docs/recent.txt"
$ND test-restauration T_Docs 50 >>"$J" 2>&1
check "apres une nouvelle sauvegarde : tout est identique, alerte levee" "jq_ $ST/T_Docs.test.json 'd[\"etat\"] == \"ok\"' && [ ! -e $ST/alertes/test-T_Docs ]"
mv "$W/usb" "$W/usb.debranche"
$ND test-restauration T_Docs 2 >>"$J" 2>&1
check "disque debranche : echec sur cette destination" "jq_ $ST/T_Docs.test.json 'd[\"etat\"] == \"echec\" and \"usb:echec\" in d[\"destinations\"] and \"gdrive:ok\" in d[\"destinations\"]'"
mv "$W/usb.debranche" "$W/usb"

echo "== Test de restauration : sauvegarde versionnee"
mkdir -p "$S/Photos/2024"; echo v1 > "$S/Photos/p.txt"; head -c 5000 /dev/urandom > "$S/Photos/2024/i.jpg"; ancien "$S/Photos/p.txt" "$S/Photos/2024/i.jpg"
$ND save nouveau T_Photos "$S/Photos" Photos versions non manuel 0 "" "" "usb:non" "7:4:12:0" >>"$J" 2>&1
$ND test-restauration T_Photos 5 >>"$J" 2>&1
check "versions : rien a tester avant la premiere version" "jq_ $ST/T_Photos.test.json 'd[\"etat\"] == \"vide\"'"
$ND run T_Photos >>"$J" 2>&1
$ND test-restauration T_Photos 5 >>"$J" 2>&1
check "versions : 2 fichiers restaures depuis la derniere version, identiques" "jq_ $ST/T_Photos.test.json 'd[\"etat\"] == \"ok\" and d[\"nb\"] == 2'"

echo "== Test automatique planifie"
$ND test-restauration planifier 7 05:20 4 >>"$J" 2>&1
check "ligne de planification" "grep -q '^20 5 \* \* 0 root /usr/local/bin/nas-debian test-restauration tout' /etc/cron.d/nas-backup && grep -qx '7 05:20 4' /etc/nas-backup/test-restauration"
check "jours invalides refuses" "! $ND test-restauration planifier 8 05:20 >>'$J' 2>&1"
$ND test-restauration planifier non >>"$J" 2>&1
check "desactivation" "! grep -q test-restauration /etc/cron.d/nas-backup"

echo "== Retour a une date : corbeille datee (construite a la main)"
# chronologie (jours avant aujourd'hui) : J-20 a,b,c crees ; J-15 a remplace (v1 -> v2) ;
# J-12 a v2 -> v3 et c supprime ; J-8 d cree
mkdir -p "$S/Chrono"; echo x > "$S/Chrono/x"
$ND save nouveau T_Chrono "$S/Chrono" Chrono sync non manuel 60 "" "" "usb:non" "" >>"$J" 2>&1
D="$W/usb/NAS/Chrono" T="$W/usb/NAS/_corbeille/T_Chrono"
j() { date -d "-$1 days 03:30" '+%Y-%m-%d_%H%M'; }
mkdir -p "$D" "$T/$(j 15)/rep" "$T/$(j 12)/rep"
echo v3 > "$D/rep/a.txt" 2>/dev/null || { mkdir -p "$D/rep"; echo v3 > "$D/rep/a.txt"; }
echo b > "$D/b.txt"; echo d > "$D/d.txt"
echo v1 > "$T/$(j 15)/rep/a.txt"; echo v2 > "$T/$(j 12)/rep/a.txt"; echo c > "$T/$(j 12)/c.txt"
touch -d "-20 days" "$T/$(j 15)/rep/a.txt" "$D/b.txt" "$T/$(j 12)/c.txt"
touch -d "-15 days 03:00" "$T/$(j 12)/rep/a.txt"
touch -d "-12 days 03:00" "$D/rep/a.txt"
touch -d "-8 days" "$D/d.txt"
$ND date plage T_Chrono 0 > "$W/plage.json" 2>>"$J"
check "plage : corbeille, 2 points, 60 jours" "jq_ $W/plage.json 'd[\"methode\"] == \"corbeille\" and len(d[\"points\"]) == 2 and d[\"jours\"] == 60'"
restaure() {  # restaure <jours avant> <cible> [element]
  $ND date restaurer T_Chrono 0 "$(date -d "-$1 days 12:00" '+%Y-%m-%d %H:%M')" "$2" "${3:-}" >>"$J" 2>&1
}
etat_de() { (cd "$1" && find . -type f | sort | while read -r f; do echo "$f=$(cat "$f")"; done | paste -sd' ' -); }
restaure 18 "$W/r18"
check "J-18 : a v1, b, c (depuis la corbeille)" "[ \"\$(etat_de $W/r18)\" = './b.txt=b ./c.txt=c ./rep/a.txt=v1' ]"
restaure 14 "$W/r14"
check "J-14 : a v2, b, c" "[ \"\$(etat_de $W/r14)\" = './b.txt=b ./c.txt=c ./rep/a.txt=v2' ]"
restaure 10 "$W/r10"
check "J-10 : a v3, b (c supprime, d pas encore cree)" "[ \"\$(etat_de $W/r10)\" = './b.txt=b ./rep/a.txt=v3' ]"
restaure 5 "$W/r5"
check "J-5 : a v3, b, d" "[ \"\$(etat_de $W/r5)\" = './b.txt=b ./d.txt=d ./rep/a.txt=v3' ]"
check "dates de modification gardees" "[ \"\$(stat -c %Y $W/r18/rep/a.txt)\" = \"\$(stat -c %Y $T/$(j 15)/rep/a.txt)\" ]"
check "etat de la restauration : date notee" "grep -q '^ETAT=ok' $ST/restauration.status && grep -q '^DATE=[0-9]' $ST/restauration.status"
restaure 18 "$W/r18s" rep
check "J-18, un seul dossier" "[ \"\$(etat_de $W/r18s)\" = './rep/a.txt=v1' ]"
$ND date apercu T_Chrono 0 "$(date -d '-14 days 12:00' '+%Y-%m-%d %H:%M')" > "$W/apercu.json" 2>>"$J"
check "apercu : 3 fichiers dont 2 depuis la corbeille" "jq_ $W/apercu.json 'd[\"fichiers\"] == 3 and d[\"depuis_corbeille\"] == 2'"
check "date dans le futur refusee" "! $ND date apercu T_Chrono 0 '$(date -d '+2 days' '+%Y-%m-%d %H:%M')' >>'$J' 2>&1"
check "chemin interdit refuse" "! $ND date restaurer T_Chrono 0 '$(date -d '-5 days' '+%Y-%m-%d %H:%M')' $W/rx ../.. >>'$J' 2>&1"
$ND save nouveau T_Copie "$S/Chrono" Copie copy non manuel 0 "" "" "usb:non" "" >>"$J" 2>&1
check "copie sans corbeille : refuse" "! $ND date apercu T_Copie 0 '$(date -d '-5 days' '+%Y-%m-%d %H:%M')' >>'$J' 2>&1 && $ND date plage T_Copie | grep -q aucune"

echo "== Retour a une date : vraies sauvegardes (Drive chiffre)"
mkdir -p "$S/Vrai"; echo v1 > "$S/Vrai/a.txt"; echo c > "$S/Vrai/c.txt"
$ND save nouveau T_Vrai "$S/Vrai" Vrai sync oui manuel 30 "" "" "gdrive:oui" "" >>"$J" 2>&1
$ND run T_Vrai >>"$J" 2>&1
sleep 61; MILIEU=$(date '+%Y-%m-%d %H:%M'); sleep 61
echo v2 > "$S/Vrai/a.txt"; rm "$S/Vrai/c.txt"; echo n > "$S/Vrai/n.txt"
$ND run T_Vrai >>"$J" 2>&1
check "deuxieme sauvegarde : a remplace, c supprime (corbeille)" "[ \"\$(rclone cat gbackup:Vrai/a.txt)\" = v2 ] && rclone lsf -R gbackup:_corbeille/T_Vrai | grep -q 'c.txt'"
$ND date restaurer T_Vrai 0 "$MILIEU" "$W/vrai" >>"$J" 2>&1
check "etat entre les deux sauvegardes : a v1 et c, sans n" "[ \"\$(etat_de $W/vrai)\" = './a.txt=v1 ./c.txt=c' ]"

echo "== Retour a une date : sauvegarde versionnee"
sleep 1; echo v2 > "$S/Photos/p.txt"; AVANT=$(date '+%Y-%m-%d %H:%M:%S'); sleep 2
$ND run T_Photos >>"$J" 2>&1
$ND date restaurer T_Photos 0 "$(date -d "$AVANT" +%s)" "$W/vers" >>"$J" 2>&1
check "version d'avant la date choisie" "[ \"\$(cat $W/vers/p.txt)\" = v1 ] && grep -q '^DATE=' $ST/restauration.status"
$ND date plage T_Photos 0 > "$W/plv.json" 2>>"$J"
check "plage des versions : 2 points" "jq_ $W/plv.json 'd[\"methode\"] == \"versions\" and len(d[\"points\"]) == 2'"

echo "== Reveil des destinations (Wake-on-LAN)"
python3 - "$W/paquet" <<'PYL' &
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 9)); s.settimeout(20)
try:
    d, _ = s.recvfrom(2048)
    open(sys.argv[1], "wb").write(d)
except socket.timeout:
    pass
PYL
sleep 1
$ND reveil envoyer 00:11:22:AA:bb:cc 127.0.0.1 >>"$J" 2>&1; wait
check "paquet magique : 6 x FF puis 16 x l'adresse MAC" "python3 -c 'import sys; d=open(sys.argv[1],\"rb\").read(); sys.exit(0 if d == b\"\\xff\"*6 + bytes.fromhex(\"001122aabbcc\")*16 else 1)' $W/paquet"
check "MAC invalide refusee" "! $ND reveil regler usb 00:11:22 >>'$J' 2>&1"
check "destination inconnue refusee" "! $ND reveil regler nulle 00:11:22:33:44:55 1.2.3.4 >>'$J' 2>&1"
check "disque local sans adresse : refuse" "! $ND reveil regler usb 00:11:22:33:44:55 >>'$J' 2>&1"
$ND reveil regler usb 00:11:22:33:44:55 127.0.0.1 60 >>"$J" 2>&1
check "reglage enregistre" "$ND reveil liste | python3 -c 'import json,sys; d=json.load(sys.stdin)[\"destinations\"][\"usb\"]; sys.exit(0 if d[\"mac\"] == \"00:11:22:33:44:55\" and d[\"attente\"] == 60 else 1)'"
check "veille ou arret sans compte SSH : refuse" "! $ND reveil regler usb 00:11:22:33:44:55 127.0.0.1 60 veille >>'$J' 2>&1"
$ND run T_Docs >>"$J" 2>&1
check "machine deja allumee : sauvegarde normale" "grep -q ' OK$' $ST/T_Docs.status && [ ! -e $ST/reveil-usb ]"
# machine « eteinte » : adresse de documentation (jamais joignable), attente courte
printf 'usb|00:11:22:33:44:55|10.255.255.1|10|rien|\n' > /etc/nas-backup/reveil.conf
$ND run T_Docs >>"$J" 2>&1
check "machine qui ne se reveille pas : destination en echec, l'autre faite" "grep -q ' ECHEC$' $ST/T_Docs.status && jq_ $ST/T_Docs.bilan.json '[x[\"code\"] for x in d[\"destinations\"]][0] == 0 and \"reveil\" in d[\"destinations\"][1][\"erreur\"]'"
check "journal : reveil tente" "grep -q 'usb : reveil (Wake-on-LAN' /var/log/nas-backup.log"
rc=0; $ND check >>"$J" 2>&1 || rc=$?
check "verification horaire : en veille, sans alerte" "jq_ $ST/destinations.json 'd[\"usb\"].get(\"veille\") is True' && [ ! -e $ST/alertes/dest-usb ]"
$ND reveil retirer usb >>"$J" 2>&1
check "reveil retire" "! grep -q '^usb|' /etc/nas-backup/reveil.conf"

echo
echo "== Resultat : $ok ok, $ko en echec"
[ "$ko" -eq 0 ] || { diagnostic; exit 1; }
