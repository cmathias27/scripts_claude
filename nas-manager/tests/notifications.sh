#!/bin/bash
# =====================================================================
#  notifications.sh : test des canaux de notification (ntfy, Telegram,
#  Discord, e-mail), des alertes, de la sante des disques (SMART, RAID) et
#  du rapport periodique de nas-debian. Les envois partent vers un faux
#  serveur local (HTTP + SMTP) qui note tout ce qu'il recoit.
#
#  Usage (en root, apres tests/faux-nas.sh qui installe le faux smartctl) :
#    bash tests/notifications.sh
#  Les reglages de /etc/nas-backup sont remis en etat a la fin.
#  NE PAS LANCER SUR UNE VRAIE MACHINE : ecrit dans /etc/nas-backup.
# =====================================================================
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "lancer en root"; exit 1; }
[ -x /usr/local/bin/smartctl ] || { echo "faux smartctl absent : lancer d'abord tests/faux-nas.sh"; exit 1; }
DEPOT="$(cd "$(dirname "$0")/../.." && pwd)"
W=/tmp/notif-test
rm -rf "${W:?}"; mkdir -p "$W/etc-avant"
mkdir -p /etc/nas-backup /var/lib/nas-backup
cp -a /etc/nas-backup/. "$W/etc-avant/"
[ -f /etc/cron.d/nas-backup ] && cp -p /etc/cron.d/nas-backup "$W/cron.sauve"
rm -f /etc/nas-backup/notify.conf /etc/nas-backup/canaux.conf /etc/nas-backup/rapport.conf
rm -rf /var/lib/nas-backup/alertes /var/lib/nas-backup/disques.json /var/lib/nas-backup/notifications.log
rm -f /tmp/faux-nas/smart-sdb-en-attente
install -m 755 "$DEPOT/nas-debian.sh" /usr/local/bin/nas-debian
ND=/usr/local/bin/nas-debian
ST=/var/lib/nas-backup R=$W/recu.jsonl J=$W/journal.txt ok=0 ko=0
export NAS_TELEGRAM_API=http://127.0.0.1:18080 PATH="/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
: > "$R"

# ---------------- faux serveur : HTTP (ntfy, Discord, Telegram) sur 18080, SMTP sur 18025
cat > "$W/serveur.py" <<'PYS'
import json, socketserver, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
OUT = sys.argv[1]
lock = threading.Lock()
def note(d):
    with lock, open(OUT, "a") as f:
        f.write(json.dumps(d, ensure_ascii=False) + "\n")
class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def reply(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.endswith("/getUpdates"):
            self.reply({"ok": True, "result": [{"update_id": 1, "message": {"chat": {"id": 42, "first_name": "Moi"}, "text": "bonjour"}}]})
        else:
            self.reply({"ok": True})
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode(errors="ignore")
        try:
            body = json.loads(body)
        except ValueError:
            pass
        note({"canal": "http", "chemin": self.path, "corps": body, "auth": self.headers.get("Authorization", "")})
        self.reply({"ok": True})
class S(socketserver.StreamRequestHandler):
    def handle(self):
        w = lambda s: self.wfile.write((s + "\r\n").encode())
        w("220 faux SMTP")
        data, rcpt = None, []
        while True:
            l = self.rfile.readline().decode(errors="ignore")
            if not l:
                return
            if data is not None:
                if l.rstrip("\r\n") == ".":
                    note({"canal": "smtp", "a": rcpt, "message": "".join(data)}); data = None; w("250 OK")
                else:
                    data.append(l)
                continue
            c = l[:4].upper()
            if c in ("EHLO", "HELO"):
                w("250 faux")
            elif c == "RCPT":
                rcpt.append(l.split(":", 1)[1].strip()); w("250 OK")
            elif c == "DATA":
                data = []; w("354 go")
            elif c == "QUIT":
                w("221 bye"); return
            else:
                w("250 OK")
socketserver.ThreadingTCPServer.allow_reuse_address = True
ThreadingHTTPServer.allow_reuse_address = True
threading.Thread(target=socketserver.ThreadingTCPServer(("127.0.0.1", 18025), S).serve_forever, daemon=True).start()
ThreadingHTTPServer(("127.0.0.1", 18080), H).serve_forever()
PYS
python3 "$W/serveur.py" "$R" & SRV=$!
sleep 1

remettre() {
  kill "$SRV" 2>/dev/null
  rm -rf /etc/nas-backup; mkdir -p /etc/nas-backup; cp -a "$W/etc-avant/." /etc/nas-backup/
  if [ -f "$W/cron.sauve" ]; then cp -p "$W/cron.sauve" /etc/cron.d/nas-backup; fi
  rm -rf /var/lib/nas-backup/alertes /var/lib/nas-backup/disques.json
  rm -f /tmp/faux-nas/smart-sdb-en-attente
}
trap remettre EXIT

check() {  # check <description> <commande de test>
  if eval "$2"; then ok=$((ok + 1)); echo "  ok   $1"; else ko=$((ko + 1)); echo "  ECHEC $1"; echo "== ECHEC $1" >> "$J"; return 1; fi
}
# recu <expression python sur la liste des messages m> : vrai si l'expression l'est
recu() { python3 -c "import json,sys; m=[json.loads(l) for l in open('$R')]; sys.exit(0 if ($1) else 1)"; }
nb() { wc -l < "$R"; }
voir() { $ND alertes voir > "$W/voir.json" && python3 -c "import json,sys; d=json.load(open('$W/voir.json')); sys.exit(0 if ($1) else 1)"; }

echo "== Canaux"
printf 'url=http://127.0.0.1:18080/nas-test-123\njeton=tk_secret\n' | $ND alertes canal ntfy tout >>"$J" 2>&1
check "ntfy : enregistre et teste" "recu 'any(x[\"chemin\"]==\"/\" and x[\"corps\"][\"topic\"]==\"nas-test-123\" and x[\"auth\"]==\"Bearer tk_secret\" for x in m)'"
printf 'url=http://127.0.0.1:18080/api/webhooks/1/abc\n' | $ND alertes canal discord critique >>"$J" 2>&1
check "Discord : enregistre et teste" "recu 'any(x[\"chemin\"]==\"/api/webhooks/1/abc\" and \"fonctionnent\" in json.dumps(x[\"corps\"], ensure_ascii=False) for x in m)'"
$ND alertes telegram <<< "123:ABC" > "$W/tg.txt" 2>&1
check "Telegram : conversation trouvee" "grep -qx '42|Moi' $W/tg.txt"
printf 'jeton=123:ABC\nconversation=42\n' | $ND alertes canal telegram tout >>"$J" 2>&1
check "Telegram : enregistre et teste" "recu 'any(x[\"chemin\"]==\"/bot123:ABC/sendMessage\" and x[\"corps\"][\"chat_id\"] in (42, \"42\") for x in m)'"
printf 'destinataire=moi@test.fr\nserveur=127.0.0.1\nport=18025\nsecurite=aucune\n' | $ND alertes canal email tout >>"$J" 2>&1
check "e-mail : enregistre et teste" "recu 'any(x[\"canal\"]==\"smtp\" and \"moi@test.fr\" in x[\"a\"][0] for x in m)'"
check "canal invalide refuse" "! printf 'url=ftp://x\n' | $ND alertes canal ntfy >>$J 2>&1"
check "voir : 4 canaux, niveaux, secrets masques" "voir 'sorted(d[\"canaux\"])==[\"discord\",\"email\",\"ntfy\",\"telegram\"] and d[\"canaux\"][\"discord\"][\"niveau\"]==\"critique\" and \"tk_secret\" not in open(\"$W/voir.json\").read() and \"ABC\" not in open(\"$W/voir.json\").read()'"
check "fichier des canaux protege (600)" "[ \"\$(stat -c %a /etc/nas-backup/canaux.conf)\" = 600 ]"
check "verification horaire planifiee" "grep -q nas-check /etc/cron.d/nas-check"
$ND alertes niveau ntfy critique >>"$J" 2>&1
check "niveau d'un canal modifie" "voir 'd[\"canaux\"][\"ntfy\"][\"niveau\"]==\"critique\"'"

echo "== Alertes"
: > "$R"
$ND notify info test-info "Info" "message discret" >>"$J" 2>&1
check "message discret : canaux « tout » seulement" "recu 'len(m)==2 and {x[\"canal\"] for x in m}=={\"http\",\"smtp\"} and all(\"/bot\" in x.get(\"chemin\",\"/bot\") for x in m)'"
: > "$R"
$ND notify critique test-crit "Panne" "quelque chose ne va pas" >>"$J" 2>&1
check "alerte : tous les canaux, alerte notee" "[ \"\$(nb)\" -eq 4 ] && [ -f $ST/alertes/test-crit ]"
: > "$R"
$ND notify critique test-crit "Panne" "toujours" >>"$J" 2>&1
check "pas de rappel avant le delai" "[ \"\$(nb)\" -eq 0 ]"
$ND notify ok test-crit "Panne" "c'est reparti" >>"$J" 2>&1
check "retabli : envoye, alerte levee" "[ \"\$(nb)\" -eq 4 ] && [ ! -f $ST/alertes/test-crit ] && recu 'sum(\"tabli\" in json.dumps(x, ensure_ascii=False) for x in m if x[\"canal\"]==\"http\")==3'"

echo "== Sante des disques"
printf 'Personalities : [raid1]\nmd0 : active raid1 sdb1[1](F) sda1[0]\n      3906885440 blocks super 1.2 [2/1] [U_]\n\nunused devices: <none>\n' > "$W/mdstat"
: > "$R"
NAS_MDSTAT="$W/mdstat" $ND disques verifier > "$W/d.json" 2>>"$J"
check "disques lus (3), sdb a surveiller" "python3 -c \"import json; d=json.load(open('$W/d.json')); e={x['dev']:x['etat'] for x in d['disques']}; assert e=={'/dev/sda':'ok','/dev/sdb':'attention','/dev/nvme0':'ok'}, e\""
check "RAID degrade : alerte et disque en panne" "[ -f $ST/alertes/raid-md0 ] && python3 -c \"import json; d=json.load(open('$W/d.json')); r=d['raid'][0]; assert r['etat']=='degrade' and r['en_panne']==['sdb1'], r\""
check "RAID degrade : notifie" "recu 'any(\"RAID md0\" in json.dumps(x, ensure_ascii=False) for x in m)'"
check "disque a surveiller : evenement notifie une fois" "recu 'any(\"surveiller\" in json.dumps(x, ensure_ascii=False) for x in m)'"
: > "$R"
echo 3 > /tmp/faux-nas/smart-sdb-en-attente
NAS_MDSTAT="$W/mdstat" $ND disques verifier > /dev/null 2>>"$J"
check "secteurs instables : alerte critique" "[ -f $ST/alertes/disque-ZDH0USE2 ] && recu 'any(\"en danger\" in json.dumps(x, ensure_ascii=False) for x in m)'"
rm -f /tmp/faux-nas/smart-sdb-en-attente
printf 'Personalities : [raid1]\nmd0 : active raid1 sdb1[1] sda1[0]\n      3906885440 blocks super 1.2 [2/2] [UU]\n\nunused devices: <none>\n' > "$W/mdstat"
: > "$R"
NAS_MDSTAT="$W/mdstat" $ND disques verifier > /dev/null 2>>"$J"
check "disque et RAID retablis" "[ ! -f $ST/alertes/disque-ZDH0USE2 ] && [ ! -f $ST/alertes/raid-md0 ] && recu 'sum(\"tabli\" in json.dumps(x, ensure_ascii=False) for x in m)>=2'"
check "etat lisible sans root (disques etat)" "$ND disques etat | python3 -c 'import json,sys; assert len(json.load(sys.stdin)[\"disques\"])==3'"

echo "== Rapport"
$ND rapport voir hebdo > "$W/rapport.txt" 2>>"$J"
check "rapport : titre et sections" "head -n 1 $W/rapport.txt | grep -qi rapport && grep -qi disque $W/rapport.txt"
: > "$R"
$ND rapport envoyer hebdo >>"$J" 2>&1
check "rapport envoye sur tous les canaux" "[ \"\$(nb)\" -eq 4 ]"
$ND rapport planifier hebdo 1 07:45 ntfy email >>"$J" 2>&1
check "rapport planifie (lundi 7:45)" "grep -q '^45 7 \* \* 1 root .*rapport envoyer hebdo' /etc/cron.d/nas-backup && voir 'd[\"rapport\"][\"frequence\"]==\"hebdo\" and d[\"rapport\"][\"canaux\"]==[\"ntfy\",\"email\"]'"
: > "$R"
$ND rapport envoyer hebdo >>"$J" 2>&1
check "rapport : seulement les canaux choisis" "[ \"\$(nb)\" -eq 2 ]"
$ND rapport planifier non >>"$J" 2>&1
check "rapport desactive" "! grep -q 'rapport envoyer' /etc/cron.d/nas-backup"

echo "== Reglages et echecs"
$ND alertes seuils 6 80 24 >>"$J" 2>&1
check "seuils enregistres" "voir 'd[\"rappel_h\"]==6 and d[\"quota_pct\"]==80 and d[\"retard_h\"]==24'"
check "seuil invalide refuse" "! $ND alertes seuils 0 80 24 >>$J 2>&1"
printf 'url=http://127.0.0.1:18099/nas-hs-1234\n' | $ND alertes canal ntfy >>"$J" 2>&1
check "canal injoignable : test en echec signale" "grep -q ntfy $ST/notifications.log"
$ND notify critique test-hs "Panne" "x" >>"$J" 2>&1
check "alerte notee meme si un canal echoue" "[ -f $ST/alertes/test-hs ] && voir 'any(\"ntfy\" in e for e in d[\"erreurs\"])'"
$ND alertes retirer discord >>"$J" 2>&1
check "canal retire" "voir '\"discord\" not in d[\"canaux\"]'"
for c in ntfy telegram email; do $ND alertes retirer $c >>"$J" 2>&1; done
rm -rf "$ST/alertes"
$ND notify critique test-sans "Panne" "x" >>"$J" 2>&1
check "sans canal : alerte notee pour NAS Manager" "[ \"\$(cat $ST/alertes/test-sans)\" = echec ]"

if [ "$ko" -ne 0 ]; then echo "---- journal"; tail -n 60 "$J"; fi
remettre; trap - EXIT
rm -rf "${W:?}"
echo
echo "$ok verification(s) reussie(s), $ko en echec"
[ "$ko" -eq 0 ]
