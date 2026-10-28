#!/bin/bash
# =====================================================================
#  ocis.sh : test de l'etape 6 (migration et transferts oCIS) avec le VRAI
#  rclone et un faux oCIS (tests/faux-ocis.py : API Graph + vrai WebDAV) :
#    - connexion, espaces personnels et projets
#    - migration d'un dossier de la machine Debian vers oCIS (avec et sans
#      suppression des originaux controles)
#    - transferts oCIS -> machine : copie, miroir avec corbeille, ponctuel,
#      programme (cron), file d'attente, arret, jeton refuse
#    - planification des transferts sur le Synology (/etc/crontab)
#
#  Usage (en root) : bash tests/ocis.sh [rclone]   (par defaut /usr/bin/rclone)
#  /root/.migre-ocis et /root/.ocis-transferts sont remis en etat a la fin.
#  NE PAS LANCER SUR UNE VRAIE MACHINE.
# =====================================================================
set -uo pipefail
REEL="${1:-/usr/bin/rclone}"
[ "$(id -u)" -eq 0 ] || { echo "lancer en root"; exit 1; }
[ -x "$REEL" ] || { echo "rclone introuvable : $REEL"; exit 1; }
DEPOT="$(cd "$(dirname "$0")/../.." && pwd)"
W=/tmp/ocis-moteur PORT=9231
rm -rf "${W:?}"; mkdir -p "$W/bin" "$W/src" "$W/dest" "$W/ocis" "$W/avant"
ln -sf "$REEL" "$W/bin/rclone"
export PATH="$W/bin:/usr/sbin:/usr/bin:/sbin:/bin" RCLONE_CONFIG="$W/rclone.conf"
: > "$W/rclone.conf"
M=/root/.migre-ocis TR=/root/.ocis-transferts J=$W/journal.txt S=$W/src D=$W/dest O=$W/ocis ok=0 ko=0
for d in "$M" "$TR"; do [ -d "$d" ] && mv "$d" "$W/avant/$(basename "$d")"; done
[ -f /etc/cron.d/ocis-transferts ] && mv /etc/cron.d/ocis-transferts "$W/avant/cron-ocis"

python3 "$DEPOT/nas-manager/tests/faux-ocis.py" "$PORT" "$O" "$REEL" alice secret > "$W/faux-ocis.log" 2>&1 &
SRV=$!
remettre() {
  kill "$SRV" 2>/dev/null
  pkill -f "rclone .*--log-file $TR/progression.log" 2>/dev/null
  rm -rf "${M:?}" "${TR:?}" /etc/cron.d/ocis-transferts
  [ -d "$W/avant/.migre-ocis" ] && mv "$W/avant/.migre-ocis" "$M"
  [ -d "$W/avant/.ocis-transferts" ] && mv "$W/avant/.ocis-transferts" "$TR"
  [ -f "$W/avant/cron-ocis" ] && mv "$W/avant/cron-ocis" /etc/cron.d/ocis-transferts
  return 0
}
trap remettre EXIT
for i in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/status.php" && break; sleep 0.2; done

install -m 755 "$DEPOT/nas-debian.sh" /usr/local/bin/nas-debian
install -m 755 "$DEPOT/nas-synology.sh" /usr/local/bin/nas-synology
ND=/usr/local/bin/nas-debian NS=/usr/local/bin/nas-synology

check() {  # check <description> <commande de test>
  if eval "$2"; then ok=$((ok + 1)); echo "  ok   $1"; else ko=$((ko + 1)); echo "  ECHEC $1"; echo "== ECHEC $1" >> "$J"; return 1; fi
}
attendre() {  # attendre <fichier> [secondes] : le fichier existe
  local i
  for ((i = 0; i < ${2:-90} * 2; i++)); do [ -e "$1" ] && return 0; sleep 0.5; done
  return 1
}
fin_migration() {  # fin du traitement de la file des migrations
  local i
  attendre "$M/code" 120 || return 1
  for ((i = 0; i < 60; i++)); do pgrep -f "nas-(debian|synology) migration _worker" >/dev/null || return 0; sleep 0.5; done
  return 1
}
fin_transfert() {  # fin_transfert <nom> : attend la fin de son execution (fichier .etat recent)
  local i
  for ((i = 0; i < 240; i++)); do
    [ -f "$TR/$1.etat" ] && [ "$(stat -c %Y "$TR/$1.etat")" -ge "$2" ] && ! pgrep -f "nas-debian transferts _worker" >/dev/null && return 0
    sleep 0.5
  done
  return 1
}
diagnostic() {
  echo "---- sorties des commandes"; sed 's/\x1b\[[0-9;]*m//g' "$J" | tail -n 60
  local f; for f in "$M/progression.log" "$TR/progression.log" "$TR/historique.log" "$M/historique.log"; do [ -f "$f" ] && { echo "---- $f"; tail -n 15 "$f"; }; done
}
meme_date() { [ "$(stat -c %Y "$1")" = "$(stat -c %Y "$2")" ]; }

echo "== Connexion a oCIS"
check "jeton refuse" "! printf 'http://127.0.0.1:$PORT\nalice\nmauvais\n-\n0\n' | $ND migration configurer >>'$J' 2>&1"
printf 'http://127.0.0.1:%s\nalice\nsecret\n-\n0\n' "$PORT" | $ND migration configurer >>"$J" 2>&1
check "connexion enregistree, envoi en WebDAV classique" "grep -q '^OCIS_VENDOR=owncloud' $M/config && grep -q '^OCIS_USER=alice' $M/config"
$ND migration espaces > "$W/esp.txt" 2>>"$J"
check "espaces projets (adresse locale reecrite)" "[ \$(grep -c '' $W/esp.txt) = 2 ] && grep -q '^projet-docs|Documents partagés|http://127.0.0.1:$PORT/dav/spaces/projet-docs|' $W/esp.txt"
$ND transferts espaces > "$W/esp2.txt" 2>>"$J"
check "transferts : espace personnel en premier" "[ \$(grep -c '' $W/esp2.txt) = 3 ] && head -n 1 $W/esp2.txt | grep -q '^personnel-alice|Personnel (Alice Martin)|.*|personal$'"

echo "== Migration depuis la machine (Debian / OMV)"
mkdir -p "$S/Docs/sous"; echo a > "$S/Docs/a.txt"; echo b > "$S/Docs/sous/b.txt"; head -c 300000 /dev/urandom > "$S/Docs/c.bin"
touch -d '2021-03-04 05:06:07' "$S/Docs/a.txt"
$ND migration ajouter "$S/Docs" projet-docs Archives non Docs >>"$J" 2>&1
check "ajoutee a la file d'attente" "grep -q '^$S/Docs|Docs|projet-docs|Documents partagés|.*|Archives|[0-9]*|non$' $M/file-attente"
check "dossier inexistant refuse" "! $ND migration ajouter $S/nulle projet-docs - non >>'$J' 2>&1"
$ND migration lancer >>"$J" 2>&1
fin_migration
check "migration terminee : 1 reussie" "[ \"\$(cat $M/code 2>/dev/null)\" = '1|0' ]"
check "fichiers dans oCIS, dates conservees" "[ -f $O/projet-docs/Archives/sous/b.txt ] && meme_date $S/Docs/a.txt $O/projet-docs/Archives/a.txt && cmp -s $S/Docs/c.bin $O/projet-docs/Archives/c.bin"
check "bilan : oCIS = machine" "grep -q 'OK (bilan : oCIS = serveur (3 fichiers' $M/historique.log || grep -q 'OK (bilan : oCIS = OMV (3 fichiers' $M/historique.log"
check "originaux gardes" "[ -f $S/Docs/a.txt ]"
mkdir -p "$S/Docs2"; echo x > "$S/Docs2/x.txt"; echo y > "$S/Docs2/y.txt"
$ND migration ajouter "$S/Docs2" projet-docs Archives2 oui >>"$J" 2>&1
$ND migration lancer >>"$J" 2>&1
fin_migration
check "controle dans oCIS puis originaux supprimes" "[ -f $O/projet-docs/Archives2/x.txt ] && [ -z \"\$(find $S/Docs2 -type f)\" ] && grep -q 'supprime(s) du serveur\|supprime(s) de l.OMV' $M/historique.log"

echo "== Migration depuis le Synology (meme code, script nas-synology)"
mkdir -p "$S/Docs3"; echo s > "$S/Docs3/s.txt"
$NS migration ajouter "$S/Docs3" projet-docs Archives3 non Docs3 >>"$J" 2>&1
$NS migration lancer >>"$J" 2>&1
fin_migration
check "migration OK, bilan au nom du Synology" "[ -f $O/projet-docs/Archives3/s.txt ] && grep -q 'OK (bilan : oCIS = Synology (1 fichiers' $M/historique.log"

echo "== Transferts oCIS -> machine"
mkdir -p "$O/projet-photos/Album/2024" "$O/projet-photos/Gros"
echo x > "$O/projet-photos/Album/2024/x.jpg"; echo y > "$O/projet-photos/Album/y.jpg"; echo z > "$O/projet-photos/Album/2024/z.jpg"
touch -d '2022-05-06 07:08:09' "$O/projet-photos/Album/2024/x.jpg"
check "nom invalide refuse" "! $ND transferts save nouveau 'a b' projet-photos Album $D/A copie 0 manuel >>'$J' 2>&1"
check "espace inconnu refuse" "! $ND transferts save nouveau A1 inconnu Album $D/A copie 0 manuel >>'$J' 2>&1"
check "destination relative refusee" "! $ND transferts save nouveau A1 projet-photos Album dest/A copie 0 manuel >>'$J' 2>&1"
check "horaire invalide refuse" "! $ND transferts save nouveau A1 projet-photos Album $D/A copie 0 25:00 >>'$J' 2>&1"
check "destination introuvable refusee" "! $ND transferts save nouveau A1 projet-photos Album /nulle/part/A copie 0 manuel >>'$J' 2>&1"
$ND transferts save nouveau Album projet-photos Album "$D/Album" copie 0 manuel >>"$J" 2>&1
check "transfert enregistre" "grep -qx 'Album|projet-photos|Photos|Album|$D/Album|copie|0|manuel|' $TR/transferts.conf"
check "doublon refuse" "! $ND transferts save nouveau Album projet-photos Album $D/Album copie 0 manuel >>'$J' 2>&1"
check "parcourir un espace" "$ND transferts parcourir projet-photos '' | sort | tr '\n' ' ' | grep -qx 'Album Gros '"
check "parcourir un sous-dossier" "[ \"\$($ND transferts parcourir projet-photos Album)\" = 2024 ]"
t=$(date +%s); $ND transferts lancer Album >>"$J" 2>&1; fin_transfert Album "$t"
check "transfert OK : fichiers copies" "grep -q '^ETAT=OK' $TR/Album.etat && [ -f $D/Album/2024/z.jpg ] && [ \"\$(cat $D/Album/y.jpg)\" = y ]"
check "dates de modification conservees" "meme_date $O/projet-photos/Album/2024/x.jpg $D/Album/2024/x.jpg"
check "bilan : 3 fichiers copies" "grep -q '^TRANSFERTS=3$' $TR/Album.etat"
check "historique" "grep -q '| OK (3 fichier(s) copie(s)' $TR/historique.log"
rm "$O/projet-photos/Album/2024/z.jpg"
t=$(date +%s); $ND transferts lancer Album >>"$J" 2>&1; fin_transfert Album "$t"
check "copie : rien n'est supprime dans la destination" "grep -q '^ETAT=OK' $TR/Album.etat && [ -f $D/Album/2024/z.jpg ] && grep -q 'deja\\\\ a\\\\ jour' $TR/Album.etat"

echo "== Transfert miroir avec corbeille"
$ND transferts save nouveau Miroir projet-photos Album "$D/Miroir" miroir 30 manuel >>"$J" 2>&1
t=$(date +%s); $ND transferts lancer Miroir >>"$J" 2>&1; fin_transfert Miroir "$t"
check "premier passage OK" "grep -q '^ETAT=OK' $TR/Miroir.etat && [ -f $D/Miroir/2024/x.jpg ]"
rm "$O/projet-photos/Album/2024/x.jpg"; echo y2 > "$O/projet-photos/Album/y.jpg"
sleep 1; t=$(date +%s); $ND transferts lancer Miroir >>"$J" 2>&1; fin_transfert Miroir "$t"
check "fichier supprime dans oCIS : retire, garde dans la corbeille" "[ ! -e $D/Miroir/2024/x.jpg ] && [ -n \"\$(find $D/Miroir/.corbeille-oCIS -path '*2024/x.jpg')\" ]"
check "fichier modifie : nouvelle version, ancienne dans la corbeille" "[ \"\$(cat $D/Miroir/y.jpg)\" = y2 ] && [ \"\$(cat \$(find $D/Miroir/.corbeille-oCIS -name y.jpg))\" = y ]"
check "bilan : 1 copie, 1 supprime" "grep -q '^TRANSFERTS=1$' $TR/Miroir.etat && grep -q '^SUPPR=1$' $TR/Miroir.etat"

echo "== Transfert programme et ponctuel"
jour=$(date +%u)
$ND transferts save nouveau Plan projet-docs Archives "$D/Plan" copie 0 "03:10/$jour;23:58" >>"$J" 2>&1
check "planification (cron)" "grep -q '^10 3 \* \* \* root /usr/local/bin/nas-debian transferts run-at 03:10' /etc/cron.d/ocis-transferts && grep -q '^58 23 ' /etc/cron.d/ocis-transferts"
t=$(date +%s); $ND transferts run-at 03:10 >>"$J" 2>&1; fin_transfert Plan "$t"
check "transfert programme execute a son heure" "grep -q '^ETAT=OK' $TR/Plan.etat && [ -f $D/Plan/a.txt ]"
autre=$(( jour % 7 + 1 ))
$ND transferts save modif Plan projet-docs Archives "$D/Plan" copie 0 "03:10/$autre" >>"$J" 2>&1
$ND transferts run-at 03:10 >>"$J" 2>&1; sleep 1
check "pas execute un autre jour" "[ ! -s $TR/file-attente ] && ! pgrep -f 'nas-debian transferts _worker' >/dev/null"
t=$(date +%s); $ND transferts save nouveau Ponctuel projet-docs Archives2 "$D/Ponctuel" copie 0 une-fois >>"$J" 2>&1; fin_transfert Ponctuel "$t"
check "ponctuel : lance tout de suite puis retire de la liste" "grep -q '^ETAT=OK' $TR/Ponctuel.etat && [ -f $D/Ponctuel/x.txt ] && ! grep -q '^Ponctuel|' $TR/transferts.conf"

echo "== File d'attente, arret, jeton refuse"
head -c 3000000 /dev/urandom > "$O/projet-photos/Gros/gros.bin"
$ND transferts save nouveau Lent projet-photos Gros "$D/Lent" copie 0 manuel 100k >>"$J" 2>&1
t=$(date +%s); $ND transferts lancer Lent >>"$J" 2>&1
sleep 3; $ND transferts lancer Album >>"$J" 2>&1
check "deuxieme transfert en file d'attente" "grep -qx Album $TR/file-attente"
check "deja dans la file : pas en double" "$ND transferts lancer Album | grep -q 'deja' && [ \$(grep -c '' $TR/file-attente) = 1 ]"
sleep 2; $ND transferts arreter >>"$J" 2>&1; fin_transfert Lent "$t"
check "arret : transfert arrete, file videe" "grep -q '^ETAT=ARRETE' $TR/Lent.etat && [ ! -s $TR/file-attente ]"
check "arret : pas d'alerte d'echec" "! grep -q 'Lent.*ECHEC' $TR/historique.log"
touch "$O/.refuser"
t=$(date +%s); $ND transferts lancer Album >>"$J" 2>&1; fin_transfert Album "$t"
check "jeton refuse : echec explique" "grep -q '^ETAT=ECHEC' $TR/Album.etat && grep -q '401' $TR/Album.etat"
rm -f "$O/.refuser"

$ND transferts supprimer Plan >>"$J" 2>&1
echo "== Synology : planification dans /etc/crontab"
mkdir -p "$W/syno"; printf '0\t1\t*\t*\t*\troot\t/bin/true\n' > "$W/crontab"
OC_CRONTAB="$W/crontab" $NS transferts save nouveau SynoPlan projet-photos Album "$W/syno/Album" copie 0 04:20 >>"$J" 2>&1
check "bloc ajoute (tabulations), lignes existantes gardees" "grep -qP '^20\t4\t\*\t\*\t\*\troot\t/usr/local/bin/nas-synology transferts run-at 04:20' $W/crontab && grep -q '/bin/true' $W/crontab && grep -q '^# >>> nas-synology transferts' $W/crontab"
OC_CRONTAB="$W/crontab" $NS transferts supprimer SynoPlan >>"$J" 2>&1
check "bloc retire" "! grep -q 'nas-synology' $W/crontab && grep -q '/bin/true' $W/crontab"

echo "== Suppression"
check "transfert supprime, planification retiree" "! grep -q '^Plan|' $TR/transferts.conf && [ ! -e /etc/cron.d/ocis-transferts ]"
check "inconnu : refuse" "! $ND transferts supprimer Plan >>'$J' 2>&1"

echo
echo "== Resultat : $ok ok, $ko en echec"
[ "$ko" -eq 0 ] || { diagnostic; exit 1; }
