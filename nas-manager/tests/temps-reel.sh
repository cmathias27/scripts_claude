#!/bin/bash
# =====================================================================
#  temps-reel.sh : test du moteur des sauvegardes temps reel de nas-debian
#  avec le VRAI rclone (remote local) et inotify.
#
#  Usage (en root) : bash tests/temps-reel.sh [chemin du vrai rclone]
#  (par defaut /usr/bin/rclone ; le faux rclone des autres tests est ignore)
#  Verifie : envoi au fil de l'eau, exclusions et types, plusieurs dossiers,
#  corbeille (versions gardees, purge par date), suppression directe, copie
#  seule, detection d'anomalie + reprise, garde-fou du rattrapage,
#  modification et suppression d'une sauvegarde qui n'est pas la derniere.
#  NE PAS LANCER SUR UNE VRAIE MACHINE : ecrit dans /etc/nas-backup.
# =====================================================================
set -uo pipefail
REEL="${1:-/usr/bin/rclone}"
[ "$(id -u)" -eq 0 ] || { echo "lancer en root"; exit 1; }
[ -x "$REEL" ] || { echo "rclone introuvable : $REEL"; exit 1; }
command -v inotifywait >/dev/null || { echo "inotifywait absent (inotify-tools)"; exit 1; }
DEPOT="$(cd "$(dirname "$0")/../.." && pwd)"
W=/tmp/rt-moteur; rm -rf "$W"; mkdir -p "$W/bin" "$W/src"
rm -f /var/log/nas-temps-reel/T_*.log
ln -sf "$REEL" "$W/bin/rclone"
printf '[gdrive]\ntype = local\n\n[dest]\ntype = local\n' > "$W/rclone.conf"
export RCLONE_CONFIG="$W/rclone.conf" PATH="$W/bin:/usr/sbin:/usr/bin:/sbin:/bin" NAS_SANS_SYSTEMD=1
install -m 755 "$DEPOT/nas-debian.sh" /usr/local/bin/nas-debian
ND=/usr/local/bin/nas-debian
S=$W/src D=$W/dst J=$W/journal.txt ok=0 ko=0

check() {  # check <description> <commande de test>
  if eval "$2"; then ok=$((ok + 1)); echo "  ok   $1"; else ko=$((ko + 1)); echo "  ECHEC $1"; echo "== ECHEC $1" >> "$J"; return 1; fi
}
attendre() {  # attendre <secondes max> <condition>
  local i; for ((i = 0; i < $1 * 2; i++)); do eval "$2" && return 0; sleep 0.5; done; return 1
}
nettoyer() { local n; for n in T_Bureau T_Cam T_Arch; do $ND temps-reel supprimer "$n" >>"$J" 2>&1; done; }
diagnostic() {  # en cas d'echec : sorties des commandes et journaux des sauvegardes de test
  echo "---- sorties des commandes"; sed 's/\x1b\[[0-9;]*m//g' "$J" | tail -n 80
  local f; for f in /var/log/nas-temps-reel/T_*.log; do [ -f "$f" ] && { echo "---- $f"; tail -n 25 "$f"; }; done
}
trap nettoyer EXIT
nettoyer

echo "== Plusieurs dossiers, corbeille, exclusions, anomalie (seuil 5)"
mkdir -p "$S/Docs/sous" "$S/Photos"; echo un > "$S/Docs/a.txt"; echo deux > "$S/Docs/sous/b.txt"
$ND temps-reel save nouveau T_Bureau "$S/Docs;$S/Photos" "dest:$D/bureau" corbeille 7 "cache" "" 1 5 5 "" "" >>"$J" 2>&1
check "creation" "[[ \"\$($ND temps-reel liste)\" == *'T_Bureau       actif'* ]]"
sleep 1
echo c > "$S/Docs/c.txt"; mkdir -p "$S/Docs/cache"; echo x > "$S/Docs/cache/i.txt"; echo t > "$S/Docs/z.tmp"
mkdir -p "$S/Photos/2024"; echo p > "$S/Photos/2024/x.jpg"
check "fichier cree envoye (sous-dossier du dossier surveille)" "attendre 15 '[ -f $D/bureau/Docs/c.txt ]'"
check "dossier cree envoye avec son contenu" "attendre 15 '[ -f $D/bureau/Photos/2024/x.jpg ]'"
check "exclusion respectee (cache)" "[ ! -e $D/bureau/Docs/cache ]"
check "fichier temporaire ignore (.tmp)" "[ ! -e $D/bureau/Docs/z.tmp ]"
check "fichiers deja presents non envoyes avant le rattrapage" "[ ! -e $D/bureau/Docs/a.txt ]"
echo v1 > "$S/Docs/d.txt"; attendre 15 "[ -f $D/bureau/Docs/d.txt ]"
echo v2 > "$S/Docs/d.txt"; attendre 15 "grep -qx v2 $D/bureau/Docs/d.txt"
rm "$S/Docs/d.txt"
check "suppression repercutee" "attendre 15 '[ ! -e $D/bureau/Docs/d.txt ]'"
check "deux versions gardees dans la corbeille (v1 et v2)" \
  "[ \"\$(find $D/_corbeille/temps-reel/T_Bureau/Docs -name d.txt -exec cat {} + | sort | tr '\n' ' ')\" = 'v1 v2 ' ]"
for i in 1 2 3 4 5 6; do echo "$i" > "$S/Photos/f$i.jpg"; done
attendre 15 "[ -f $D/bureau/Photos/f6.jpg ]"
rm "$S"/Photos/f*.jpg
check "anomalie : pause apres 6 suppressions" "attendre 15 '[ -f /var/lib/nas-backup/rt-T_Bureau.pause ]'"
sleep 3
check "anomalie : rien supprime sur la destination" "[ -f $D/bureau/Photos/f1.jpg ] && [ -f $D/bureau/Photos/f6.jpg ]"
check "rattrapage refuse pendant la pause" "$ND temps-reel rattrapage T_Bureau | grep -q 'en pause'"
$ND temps-reel reprendre T_Bureau >>"$J" 2>&1
check "reprise : suppressions repercutees" "attendre 30 '[ ! -e $D/bureau/Photos/f1.jpg ]'"
check "reprise : supprimes gardes dans la corbeille" "attendre 10 '[ -n \"\$(find $D/_corbeille/temps-reel/T_Bureau/Photos -name f1.jpg)\" ]'"
check "reprise : fichiers deja presents envoyes" "attendre 30 '[ -f $D/bureau/Docs/sous/b.txt ]'"
check "plus en pause" "[ ! -f /var/lib/nas-backup/rt-T_Bureau.pause ]"

echo "== Garde-fou du rattrapage (surveillance arretee, suppressions en masse)"
$ND temps-reel arreter T_Bureau >>"$J" 2>&1
attendre 60 "flock -n /run/nas-temps-reel-T_Bureau.lock true"   # rattrapage lance par la reprise
for i in 1 2 3 4 5 6; do echo "$i" > "$S/Docs/g$i.txt"; touch -d '-1 hour' "$S/Docs/g$i.txt"; done
$ND temps-reel envoi-complet T_Bureau >>"$J" 2>&1
check "envoi complet" "[ -f $D/bureau/Docs/g6.txt ]"
rm "$S"/Docs/g*.txt
$ND temps-reel rattrapage T_Bureau >>"$J" 2>&1
check "rattrapage mis en pause (6 suppressions, seuil 5)" "grep -q 'rattrapage supprimerait 6' /var/lib/nas-backup/rt-T_Bureau.pause"
check "rattrapage : rien supprime" "[ -f $D/bureau/Docs/g1.txt ]"

echo "== Purge de la corbeille par date de suppression"
mkdir -p "$D/_corbeille/temps-reel/T_Bureau/Docs/2020-01-01_000000" "$D/_corbeille/temps-reel/T_Bureau/Docs/$(date +%Y-%m-%d_%H%M%S -d '-1 hour')"
echo vieux > "$D/_corbeille/temps-reel/T_Bureau/Docs/2020-01-01_000000/v.txt"
echo recent > "$D/_corbeille/temps-reel/T_Bureau/Docs/$(date +%Y-%m-%d_%H%M%S -d '-1 hour')/r.txt"
touch -d '2015-01-01' "$D/_corbeille/temps-reel/T_Bureau/Docs/"*/r.txt
$ND temps-reel reprendre T_Bureau >>"$J" 2>&1     # reprise confirmee : rattrapage sans garde-fou
sleep 1; attendre 60 "flock -n /run/nas-temps-reel-T_Bureau.lock true"
check "dossier de corbeille de plus de 7 jours purge" "[ ! -e $D/_corbeille/temps-reel/T_Bureau/Docs/2020-01-01_000000 ]"
check "vieux fichier supprime recemment garde" "[ -n \"\$(find $D/_corbeille/temps-reel/T_Bureau/Docs -name r.txt)\" ]"

echo "== Suppression directe + types, copie seule"
mkdir -p "$S/Cam" "$S/Arch"
$ND temps-reel save nouveau T_Cam "$S/Cam" "dest:$D/cam" directe 0 "" "*.mp4" 1 15 0 "" "" >>"$J" 2>&1
$ND temps-reel save nouveau T_Arch "$S/Arch" "dest:$D/arch" copie 0 "" "" 1 30 0 econome "" >>"$J" 2>&1
sleep 1
echo v > "$S/Cam/clip.mp4"; echo t > "$S/Cam/note.txt"; echo a > "$S/Arch/doc.pdf"
check "types : video envoyee" "attendre 15 '[ -f $D/cam/clip.mp4 ]'"
check "types : autre fichier ignore" "[ ! -e $D/cam/note.txt ]"
check "copie seule : envoye" "attendre 15 '[ -f $D/arch/doc.pdf ]'"
rm "$S/Cam/clip.mp4" "$S/Arch/doc.pdf"
check "suppression directe" "attendre 15 '[ ! -e $D/cam/clip.mp4 ]'"
sleep 3
check "suppression directe : pas de corbeille" "[ ! -e $D/_corbeille/temps-reel/T_Cam ]"
check "copie seule : rien supprime" "[ -f $D/arch/doc.pdf ]"

echo "== Modifier / supprimer une sauvegarde qui n'est pas la derniere"
$ND temps-reel save modif T_Bureau "$S/Docs" "dest:$D/bureau2" copie 0 "" "" 2 30 0 "" "" >>"$J" 2>&1
check "modification appliquee a la bonne sauvegarde" "grep -q '^T_Bureau|$S/Docs|dest:$D/bureau2|copie|' /etc/nas-backup/temps-reel.conf"
check "les autres inchangees" "grep -q '^T_Arch|$S/Arch|dest:$D/arch|copie|' /etc/nas-backup/temps-reel.conf"
$ND temps-reel supprimer T_Cam effacer-destination >>"$J" 2>&1
check "suppression de la bonne sauvegarde" "! grep -q '^T_Cam|' /etc/nas-backup/temps-reel.conf && grep -q '^T_Arch|' /etc/nas-backup/temps-reel.conf"
check "destination effacee : la sienne seulement" "[ ! -e $D/cam ] && [ -f $D/arch/doc.pdf ]"
check "surveillance de la sauvegarde supprimee arretee" "! pgrep -f 'temps-reel surveiller T_Cam' >/dev/null"

[ "$ko" -eq 0 ] || diagnostic
nettoyer; trap - EXIT
sleep 1
check "plus aucune surveillance de test" "! pgrep -f 'temps-reel surveiller T_' >/dev/null"
# journal garde en cas d'echec (annotations de la CI)
[ "$ko" -eq 0 ] && rm -rf "$W"
echo
echo "$ok verification(s) reussie(s), $ko en echec"
[ "$ko" -eq 0 ]
