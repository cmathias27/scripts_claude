#!/bin/bash
# =====================================================================
#  destinations.sh : test des destinations, des sauvegardes vers plusieurs
#  destinations, des sauvegardes versionnees (restic) et du kit de secours
#  de nas-debian, avec le VRAI rclone (remotes locaux) et le VRAI restic.
#
#  Usage (en root) : bash tests/destinations.sh [rclone] [restic]
#  (par defaut /usr/bin/rclone et /usr/bin/restic ; le faux rclone des autres
#  tests est ignore). Les reglages de /etc/nas-backup sont remis en etat a la fin.
#  NE PAS LANCER SUR UNE VRAIE MACHINE : ecrit dans /etc/nas-backup et /root.
# =====================================================================
set -uo pipefail
REEL="${1:-/usr/bin/rclone}"
RESTIC="${2:-/usr/bin/restic}"
[ "$(id -u)" -eq 0 ] || { echo "lancer en root"; exit 1; }
[ -x "$REEL" ] || { echo "rclone introuvable : $REEL"; exit 1; }
[ -x "$RESTIC" ] || { echo "restic introuvable : $RESTIC"; exit 1; }
DEPOT="$(cd "$(dirname "$0")/../.." && pwd)"
W=/tmp/dest-moteur
rm -rf "${W:?}"; mkdir -p "$W/bin" "$W/src" "$W/gd" "$W/etc-avant"
ln -sf "$REEL" "$W/bin/rclone"; ln -sf "$RESTIC" "$W/bin/restic"
# « Google Drive » = dossier local
printf '[gdrive]\ntype = alias\nremote = %s/gd\n' "$W" > "$W/rclone.conf"
export RCLONE_CONFIG="$W/rclone.conf" PATH="$W/bin:/usr/sbin:/usr/bin:/sbin:/bin" NAS_SANS_SYSTEMD=1
# reglages actuels mis de cote (remis a la fin), temps reel et sauvegardes du faux NAS ecartes
mkdir -p /etc/nas-backup /var/lib/nas-backup
cp -a /etc/nas-backup/. "$W/etc-avant/"
for f in /root/nas-backup-motsdepasse.txt /etc/cron.d/nas-backup; do [ -f "$f" ] && cp -p "$f" "$W/etc-avant/$(basename "$f").sauve"; done
: > /etc/nas-backup/temps-reel.conf
echo "# test" > /etc/nas-backup/jobs.conf
rm -f /etc/nas-backup/restic.pass /etc/nas-backup/secours.pass /root/nas-backup-motsdepasse.txt
rm -rf /var/lib/nas-backup/secours
install -m 755 "$DEPOT/nas-debian.sh" /usr/local/bin/nas-debian
ND=/usr/local/bin/nas-debian
S=$W/src U=$W/usb J=$W/journal.txt ST=/var/lib/nas-backup ok=0 ko=0

check() {  # check <description> <commande de test>
  if eval "$2"; then ok=$((ok + 1)); echo "  ok   $1"; else ko=$((ko + 1)); echo "  ECHEC $1"; echo "== ECHEC $1" >> "$J"; return 1; fi
}
jq_() {  # jq_ <fichier json> <expression python sur d>
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($2) else 1)" "$1" 2>/dev/null
}
remettre() {
  rm -rf "$ST"/T_* "$ST"/secours "$ST/destinations.json"
  rm -f /etc/nas-backup/*
  cp -a "$W/etc-avant/." /etc/nas-backup/
  rm -f /etc/nas-backup/*.sauve
  for f in nas-backup-motsdepasse.txt; do
    if [ -f "$W/etc-avant/$f.sauve" ]; then cp -p "$W/etc-avant/$f.sauve" "/root/$f"; else rm -f "/root/$f"; fi
  done
  [ -f "$W/etc-avant/nas-backup.sauve" ] && cp -p "$W/etc-avant/nas-backup.sauve" /etc/cron.d/nas-backup
  return 0
}
diagnostic() {
  echo "---- sorties des commandes"; sed 's/\x1b\[[0-9;]*m//g' "$J" | tail -n 80
  local f; for f in "$ST"/T_*.run.log; do [ -f "$f" ] && { echo "---- $f"; tail -n 20 "$f"; }; done
}
trap remettre EXIT

echo "== Destinations"
mkdir -p "$U"
printf 'chemin=%s\nsysteme=oui\n' "$U" | $ND destinations creer usb local >>"$J" 2>&1
check "disque local cree" "$ND destinations liste | python3 -c 'import json,sys; d={x[\"nom\"]: x for x in json.load(sys.stdin)}; sys.exit(0 if d[\"usb\"][\"type\"] == \"local\" and \"gdrive\" in d else 1)'"
check "disque systeme refuse sans confirmation" "! printf 'chemin=%s/autre\n' '$W' | $ND destinations creer usb2 local >>'$J' 2>&1"
check "nom invalide refuse" "! printf 'chemin=%s\nsysteme=oui\n' '$U' | $ND destinations creer 'a-b' local >>'$J' 2>&1"
check "type inconnu refuse" "! $ND destinations creer zz ftp < /dev/null >>'$J' 2>&1"
check "OneDrive : connexion par le navigateur" "! $ND destinations creer od onedrive < /dev/null >>'$J' 2>&1"
check "etat : destination joignable" "$ND destinations etat usb >/dev/null && jq_ $ST/destinations.json 'd[\"usb\"][\"ok\"]'"

echo "== Sauvegarde vers deux destinations (Drive chiffre + disque en clair)"
mkdir -p "$S/Docs/sous"; echo a > "$S/Docs/a.txt"; echo b > "$S/Docs/sous/b.txt"
$ND save nouveau T_Docs "$S/Docs" Docs sync oui manuel 7 "" "" "gdrive:oui;usb:non" "" >>"$J" 2>&1
check "enregistree avec ses destinations" "grep -q '^T_Docs|$S/Docs|Docs|sync|oui|manuel|7|||gdrive:oui;usb:non|$' /etc/nas-backup/jobs.conf"
check "remote chiffre cree" "rclone listremotes | grep -qx 'gbackup:'"
check "destination inconnue refusee" "! $ND save nouveau T_X '$S/Docs' X sync oui manuel 7 '' '' 'nulle:oui' '' >>'$J' 2>&1"
check "destination en double refusee" "! $ND save nouveau T_X '$S/Docs' X sync oui manuel 7 '' '' 'usb:oui;usb:non' '' >>'$J' 2>&1"
$ND run T_Docs >>"$J" 2>&1
check "sauvegarde OK" "grep -q ' OK$' $ST/T_Docs.status"
check "disque : fichiers en clair" "[ -f $U/NAS/Docs/sous/b.txt ]"
check "Drive : noms chiffres" "[ -d $W/gd/NAS-chiffre ] && ! find $W/gd -name a.txt | grep -q ."
check "Drive : relisible dechiffre" "[ \"\$(rclone cat gbackup:Docs/a.txt)\" = a ]"
check "bilan : deux destinations, 2 fichiers" "jq_ $ST/T_Docs.bilan.json 'len(d[\"destinations\"]) == 2 and d[\"fichiers_envoyes\"] == 2 and all(x[\"code\"] == 0 for x in d[\"destinations\"])'"
rm "$S/Docs/a.txt"; $ND run T_Docs >>"$J" 2>&1
check "suppression repercutee, gardee dans la corbeille" "[ ! -e $U/NAS/Docs/a.txt ] && [ -n \"\$(find $U/NAS/_corbeille/T_Docs -name a.txt)\" ]"
$ND verifier T_Docs >>"$J" 2>&1
check "verification : identique partout" "grep -q '^ETAT=ok' $ST/T_Docs.verif.status"
echo modifie >> "$U/NAS/Docs/sous/b.txt"
$ND verifier T_Docs >>"$J" 2>&1
check "verification : ecart sur le disque seulement" "grep -q '^ETAT=ecarts' $ST/T_Docs.verif.status && grep -q 'usb:ecarts' $ST/T_Docs.verif.status && grep -q 'gdrive:ok' $ST/T_Docs.verif.status"
check "detail de l'ecart avec sa destination" "grep -q '^\[usb\] sous/b.txt' $ST/T_Docs.verif.d/differents"
check "parcours de la 2e destination" "$ND ls T_Docs '' '' 1 > $W/ls.json && grep -q '\"Name\":\"sous\"' $W/ls.json"
$ND restore T_Docs "$W/rest" sous/b.txt "" 0 >>"$J" 2>&1
check "restauration depuis le Drive chiffre" "[ \"\$(cat $W/rest/b.txt)\" = b ]"
check "destination utilisee : suppression refusee" "! $ND destinations supprimer usb >>'$J' 2>&1 && grep -q 'utilisee par : T_Docs' '$J'"
mv "$U" "$U.debranche"
$ND run T_Docs >>"$J" 2>&1
check "disque debranche : echec, rien recree sur le disque systeme" "grep -q ' ECHEC$' $ST/T_Docs.status && [ ! -e $U ]"
check "disque debranche : l'autre destination a ete faite" "jq_ $ST/T_Docs.bilan.json '[x[\"code\"] for x in d[\"destinations\"]][0] == 0 and [x[\"code\"] for x in d[\"destinations\"]][1] != 0 and \"debranche\" in d[\"destinations\"][1][\"erreur\"]'"
mv "$U.debranche" "$U"

echo "== Sauvegarde versionnee (restic)"
mkdir -p "$S/Photos/2024"; echo v1 > "$S/Photos/p.txt"; echo img > "$S/Photos/2024/i.jpg"
$ND save nouveau T_Photos "$S/Photos" Photos versions non manuel 0 "" "" "usb:non" "7:4:12:0" >>"$J" 2>&1
check "enregistree (versions toujours chiffrees)" "grep -q '^T_Photos|$S/Photos|Photos|versions|oui|manuel|0|||usb:oui|7:4:12:0$' /etc/nas-backup/jobs.conf"
check "rotation invalide refusee" "! $ND save modif T_Photos '$S/Photos' Photos versions non manuel 0 '' '' 'usb:non' '0:0:0:0' >>'$J' 2>&1"
$ND simulate T_Photos >>"$J" 2>&1
check "simulation avant la premiere version : 2 fichiers" "grep -q '^ENVOIS=2' $ST/T_Photos.simulation.status"
$ND run T_Photos >>"$J" 2>&1
check "premiere version OK" "grep -q ' OK$' $ST/T_Photos.status && [ -f $U/NAS-versions/Photos/config ]"
echo v2 > "$S/Photos/p.txt"; sleep 1
$ND run T_Photos >>"$J" 2>&1
check "deuxieme version OK" "grep -q ' OK$' $ST/T_Photos.status && jq_ $ST/T_Photos.bilan.json 'd[\"versions\"] == 2 and d[\"fichiers_envoyes\"] == 1'"
$ND versions liste T_Photos 0 > "$W/v.json" 2>>"$J"
check "liste des versions" "jq_ $W/v.json 'len(d) == 2 and d[0][\"date\"] >= d[1][\"date\"] and d[0][\"chemin\"] == \"$S/Photos\"'"
OLD=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[1]["id"])' "$W/v.json")
NEW=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["id"])' "$W/v.json")
check "contenu d'une version" "$ND versions ls T_Photos 0 $OLD '' | python3 -c 'import json,sys; d={x[\"Name\"]: x for x in json.load(sys.stdin)}; sys.exit(0 if d[\"2024\"][\"IsDir\"] and d[\"p.txt\"][\"Size\"] == 3 else 1)'"
check "contenu d'un sous-dossier" "$ND versions ls T_Photos 0 $OLD 2024 > $W/vls.json && grep -q '\"Name\": \"i.jpg\"' $W/vls.json"
check "version invalide refusee" "! $ND versions ls T_Photos 0 'x;rm' '' >>'$J' 2>&1"
$ND versions restaurer T_Photos 0 "$OLD" "$W/vr" p.txt >>"$J" 2>&1
check "restauration d'un fichier d'une ancienne version" "[ \"\$(cat $W/vr/p.txt)\" = v1 ] && grep -q '^ETAT=ok' $ST/restauration.status"
$ND versions restaurer T_Photos 0 "$NEW" "$W/vr2" "" >>"$J" 2>&1
check "restauration complete de la derniere version" "[ \"\$(cat $W/vr2/p.txt)\" = v2 ] && [ -f $W/vr2/2024/i.jpg ]"
$ND verifier T_Photos >>"$J" 2>&1
check "controle du depot" "grep -q '^ETAT=ok' $ST/T_Photos.verif.status && grep -q '^TYPE=versions' $ST/T_Photos.verif.status"
$ND versions entretien T_Photos >>"$J" 2>&1
check "entretien (nettoyage + controle)" "jq_ $ST/T_Photos.entretien.json 'd[\"code\"] == 0'"
check "entretien planifie le dimanche" "grep -q 'versions entretien' /etc/cron.d/nas-backup"
cp -p /etc/nas-backup/restic.pass "$W/restic.pass"; echo faux > /etc/nas-backup/restic.pass
$ND run T_Photos >>"$J" 2>&1
check "mauvais mot de passe : echec explique" "grep -q ' ECHEC$' $ST/T_Photos.status && grep -q 'mot de passe du depot refuse' $ST/T_Photos.run.log"
cp -p "$W/restic.pass" /etc/nas-backup/restic.pass

echo "== Kit de secours"
$ND secours sauvegarder >>"$J" 2>&1
KIT="kit-secours-$(hostname -s).tar.gz.enc"
check "kit envoye vers les deux destinations" "[ -s $W/gd/NAS-secours/$KIT ] && [ -s $U/NAS-secours/$KIT ] && [ -f $U/NAS-secours/LISEZMOI.txt ]"
check "etat du kit" "$ND secours etat | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d[\"mot_de_passe\"] and d[\"destinations\"][\"usb\"][\"ok\"] and d[\"taille\"] > 0 else 1)'"
check "mot de passe du kit lisible (6 groupes)" "grep -qE '^[A-Z2-9]{4}(-[A-Z2-9]{4}){5}$' /etc/nas-backup/secours.pass"
D1=$(stat -c %Y "$U/NAS-secours/$KIT"); sleep 1
$ND secours sauvegarder >>"$J" 2>&1
check "kit inchange : pas renvoye" "[ \"\$(stat -c %Y $U/NAS-secours/$KIT)\" = $D1 ]"
$ND secours telecharger > "$W/kit.b64" 2>>"$J"
check "telechargement pour le PC (base64 identique)" "head -n 1 $W/kit.b64 | grep -q '^EMPREINTE=' && tail -n 1 $W/kit.b64 | base64 -d | cmp -s - /var/lib/nas-backup/secours/$KIT"
cp "$U/NAS-secours/$KIT" "$W/kit.enc"
check "mauvais mot de passe refuse" "! echo FAUX | $ND secours restaurer $W/kit.enc >>'$J' 2>&1"
PASS=$(cat /etc/nas-backup/secours.pass)
check "simulation de restauration" "echo '$PASS' | $ND secours restaurer $W/kit.enc > $W/sim.txt 2>&1 && grep -q 'jobs.conf' $W/sim.txt && grep -q 'rien n.a ete modifie' $W/sim.txt"
# « nouvelle machine » : sauvegardes et destination perdues
grep -v '^T_Photos|' /etc/nas-backup/jobs.conf > "$W/j" && cat "$W/j" > /etc/nas-backup/jobs.conf
rclone config delete usb; rm -f /etc/nas-backup/restic.pass
echo "$PASS" | $ND secours restaurer "$W/kit.enc" appliquer >>"$J" 2>&1
check "restauration : sauvegardes revenues" "grep -q '^T_Photos|' /etc/nas-backup/jobs.conf"
check "restauration : destination revenue" "rclone listremotes | grep -qx 'usb:'"
check "restauration : mot de passe des versions revenu" "cmp -s $W/restic.pass /etc/nas-backup/restic.pass"
$ND run T_Photos >>"$J" 2>&1
check "apres restauration : les versions continuent" "grep -q ' OK$' $ST/T_Photos.status"
check "tous les mots de passe affiches" "$ND mots-de-passe > $W/mdp.txt && grep -q 'Mot de passe du kit' $W/mdp.txt && grep -q 'Mot de passe des depots' $W/mdp.txt"

echo "== Suppressions"
$ND delete T_Photos effacer-drive >>"$J" 2>&1
check "versions effacees de la destination" "[ ! -e $U/NAS-versions/Photos ] && ! grep -q '^T_Photos|' /etc/nas-backup/jobs.conf"
$ND delete T_Docs >>"$J" 2>&1
$ND destinations supprimer usb >>"$J" 2>&1
check "destination retiree (fichiers laisses en place)" "! rclone listremotes | grep -qx 'usb:' && [ -d $U/NAS/Docs ]"

[ "$ko" -eq 0 ] || diagnostic
remettre; trap - EXIT
rm -rf "${W:?}"
echo
echo "$ok verification(s) reussie(s), $ko en echec"
[ "$ko" -eq 0 ]
