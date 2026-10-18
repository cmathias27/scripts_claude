//! Scripts envoyes au NAS : collecte de l'etat (JSON) et actions.
//! Les scripts de synchro eux-memes (nas-backup, copie-omv, migre-drive-ocis)
//! sont integres a l'application pour pouvoir les installer / mettre a jour.

use crate::ssh::sq;
use base64::Engine;

pub const NAS_BACKUP_SH: &str = include_str!("../../nas-backup.sh");
pub const COPIE_OMV_SH: &str = include_str!("../../copie-omv.sh");
pub const MIGRE_OCIS_SH: &str = include_str!("../../migre-drive-ocis.sh");
/// Version des commandes sans question attendue dans les scripts
pub const API_VERSION: u32 = 1;

pub const NB_BIN: &str = "/usr/local/bin/nas-backup";
pub const COPIE_BIN: &str = "/usr/local/bin/copie-omv";
pub const MIGRE_BIN: &str = "/usr/local/bin/migre-drive-ocis";

// =====================================================================
//  Collecte de l'etat de l'OMV
// =====================================================================
pub const OMV_STATUS: &str = r#####"
export LC_ALL=C
command -v python3 >/dev/null || { echo '{"erreur":"python3 introuvable sur l OMV"}'; exit 0; }
python3 - <<'PYEOF'
import json, os, re, subprocess, time, glob

S = "/var/lib/nas-backup"
NB = "/usr/local/bin/nas-backup"

def rd(p, d=""):
    try:
        with open(p, errors="ignore") as f:
            return f.read().strip()
    except OSError:
        return d

def tail(p, n=131072):
    try:
        with open(p, "rb") as f:
            f.seek(0, 2); sz = f.tell(); f.seek(max(0, sz - n))
            return f.read().decode(errors="ignore")
    except OSError:
        return ""

def alive(pid):
    try:
        os.kill(int(pid), 0); return True
    except (OSError, ValueError):
        return False

def sh(cmd, t=20):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=t).stdout.strip()
    except Exception:
        return ""

def rc(cmd, t=20):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, timeout=t).returncode
    except Exception:
        return -1

def api_version(path):
    m = re.search(r"^API_VERSION=(\d+)", rd(path), re.M)
    return int(m.group(1)) if m else 0

def src_vars(path, names):
    if not os.path.exists(path):
        return {}
    code = '. "$1" 2>/dev/null; printf "%s\\037" ' + " ".join('"${%s:-}"' % n for n in names)
    try:
        out = subprocess.run(["bash", "-c", code, "_", path], capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return {}
    vals = out.split("\x1f")
    return {n: (vals[i] if i < len(vals) else "") for i, n in enumerate(names)}

RX_BYTES = re.compile(r"Transferred:\s+(.+?) / (.+?), (-|\d+%), (.+?/s), ETA (\S+)")
RX_FILES = re.compile(r"Transferred:\s+(\d+) / (\d+), (-|\d+%)\s*$")
RX_CHECKS = re.compile(r"Checks:\s+(\d+) / (\d+)")
RX_ERRORS = re.compile(r"Errors:\s+(\d+)")
RX_ELAPSED = re.compile(r"Elapsed time:\s+(\S+)")
RX_CUR = re.compile(r"^\s*\*\s+(.+?):\s*(\d+)% /(\S+), (\S+), (\S+)")

def progress(text):
    """Dernier bloc de statistiques rclone d'un journal."""
    block = None
    for line in text.splitlines():
        m = RX_BYTES.search(line)
        if m:
            p = m.group(3)
            block = {"octets_faits": m.group(1).strip(), "octets_total": m.group(2).strip(),
                     "pct": int(p[:-1]) if p.endswith("%") else None,
                     "vitesse": m.group(4).strip(), "reste": m.group(5), "en_cours": []}
            continue
        if block is None:
            continue
        m = RX_FILES.search(line)
        if m:
            block["fichiers_faits"] = int(m.group(1)); block["fichiers_total"] = int(m.group(2)); continue
        m = RX_CHECKS.search(line)
        if m:
            block["verifs_faites"] = int(m.group(1)); block["verifs_total"] = int(m.group(2)); continue
        m = RX_ERRORS.search(line)
        if m:
            block["erreurs"] = int(m.group(1)); continue
        m = RX_ELAPSED.search(line)
        if m:
            block["duree"] = m.group(1); continue
        m = RX_CUR.search(line)
        if m and len(block["en_cours"]) < 6:
            block["en_cours"].append({"fichier": m.group(1), "pct": int(m.group(2)), "taille": m.group(3),
                                      "vitesse": m.group(4), "reste": m.group(5)})
    return block

def last_lines(text, n, pat=None):
    ls = [l for l in text.splitlines() if l.strip() and (pat is None or re.search(pat, l))]
    return ls[-n:]

out = {"serveur": sh("hostname"), "maintenant": int(time.time())}
try:
    out["uptime_s"] = int(float(rd("/proc/uptime", "0").split()[0]))
    out["charge"] = rd("/proc/loadavg").split()[0]
except Exception:
    pass

# ---------------- Disques ----------------
disques = []
for line in sh("df -B1 --output=target,size,used,avail /srv/dev-disk-by-uuid-* 2>/dev/null | tail -n +2").splitlines():
    p = line.split()
    if len(p) == 4:
        disques.append({"point": p[0], "taille": int(p[1]), "utilise": int(p[2]), "libre": int(p[3])})
out["disques"] = disques

# ---------------- Sauvegardes ----------------
out["nb_installe"] = os.path.exists(NB)
out["nb_api"] = api_version(NB)
out["arret_demande"] = os.path.exists(S + "/stop")
jobs = []
for line in rd("/etc/nas-backup/jobs.conf").splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    p = line.split("|")
    if len(p) < 7:
        continue
    name, src, sub, mode, enc, sched, ret = p[:7]
    j = {"nom": name, "source": src, "dossier": sub, "mode": mode, "chiffre": enc == "oui",
         "horaire": sched, "corbeille": int(ret) if ret.isdigit() else 0,
         "source_existe": os.path.isdir(src)}
    st = rd(f"{S}/{name}.status")
    if st:
        parts = st.split()
        j["dernier_etat"] = parts[-1]
        j["derniere_execution"] = " ".join(parts[:2])
    lo = rd(f"{S}/{name}.lastok")
    if lo.isdigit():
        j["dernier_succes"] = int(lo)
    try:
        j["bilan"] = json.load(open(f"{S}/{name}.bilan.json"))
    except Exception:
        pass
    runf = rd(f"{S}/{name}.running")
    running = False
    if runf:
        rp = runf.split()
        running = alive(rp[0])
        if running and len(rp) > 1 and rp[1].isdigit():
            j["debut"] = int(rp[1])
    if not running and rc(f"flock -n /run/nas-backup-{name}.lock true") == 1:
        running = True
    j["en_cours"] = running
    if running:
        j["avancement"] = progress(tail(f"{S}/{name}.run.log", 262144))
    jobs.append(j)
out["sauvegardes"] = jobs

# ---------------- Restauration ----------------
r = src_vars(S + "/restauration.status", ["ETAT", "NOM", "CIBLE", "DEBUT", "FIN", "CODE"])
if r:
    rr = {"etat": r["ETAT"], "nom": r["NOM"], "cible": r["CIBLE"], "debut": r["DEBUT"], "fin": r["FIN"], "code": r["CODE"]}
    if r["ETAT"] == "en_cours":
        if rc("flock -n /run/nas-backup-restauration.lock true") != 1:
            rr["etat"] = "interrompue"
        else:
            rr["avancement"] = progress(tail(S + "/restauration.log", 131072))
    out["restauration"] = rr

# ---------------- Cameras ----------------
cam = {"installe": os.path.exists("/usr/local/bin/cam-sync.sh")}
if cam["installe"]:
    cam["actif"] = sh("systemctl is-active cam-sync") == "active"
    cam["demarrage_auto"] = sh("systemctl is-enabled cam-sync") == "enabled"
    m = re.search(r'^SRC="([^"]*)"', rd("/usr/local/bin/cam-sync.sh"), re.M)
    cam["dossier"] = m.group(1) if m else ""
    cam["rattrapage_en_cours"] = os.path.exists("/run/cam-sync-full.lock") and rc("flock -n /run/cam-sync-full.lock true") == 1
    cam["alerte_rattrapage"] = os.path.exists("/usr/local/bin/cam-sync-catchup.sh")
    since = sh("systemctl show cam-sync -p ActiveEnterTimestamp --value")
    cam["actif_depuis"] = since
    t = tail("/var/log/cam-sync.log", 400000)
    today = time.strftime("%Y/%m/%d")
    copies = [l for l in t.splitlines() if ": Copied" in l]
    cam["envois_aujourdhui"] = sum(1 for l in copies if l.startswith(today))
    if copies:
        cam["dernier_envoi"] = copies[-1][:19]
    errs = [l for l in t.splitlines() if " ERROR " in l and "Attempt " not in l]
    cam["erreurs_aujourdhui"] = sum(1 for l in errs if l.startswith(today))
    if errs:
        cam["derniere_erreur"] = errs[-1][:300]
    cam["evenements"] = last_lines(t, 25, r": (Copied|Deleted|Moved)| ERROR ")
out["cameras"] = cam

# ---------------- Sante / alertes ----------------
try:
    out["sante"] = json.load(open(S + "/health.json"))
except Exception:
    out["sante"] = None
al = []
ad = S + "/alertes"
if os.path.isdir(ad):
    for f in sorted(os.listdir(ad)):
        try:
            al.append({"tag": f, "depuis": int(os.path.getmtime(os.path.join(ad, f)))})
        except OSError:
            pass
out["alertes"] = al
out["alertes_installees"] = os.path.exists("/usr/local/bin/nas-check")
out["nas_check_en_cours"] = rc("pgrep -f '/usr/local/bin/nas-chec[k]' >/dev/null") == 0
out["suivi_ha"] = os.path.exists("/usr/local/bin/nas-ha-status")
print(json.dumps(out, ensure_ascii=False))
PYEOF
"#####;

// =====================================================================
//  Collecte de l'etat du Synology (copie vers l'OMV + migration oCIS)
// =====================================================================
pub const SYNO_STATUS: &str = r#####"
export LC_ALL=C
command -v python3 >/dev/null || { echo '{"erreur":"python3 introuvable sur le Synology"}'; exit 0; }
python3 - <<'PYEOF'
import json, os, re, subprocess, time

C = "/root/.copie-omv"
M = "/root/.migre-ocis"

def rd(p, d=""):
    try:
        with open(p, errors="ignore") as f:
            return f.read().strip()
    except OSError:
        return d

def tail(p, n=65536):
    try:
        with open(p, "rb") as f:
            f.seek(0, 2); sz = f.tell(); f.seek(max(0, sz - n))
            return f.read().decode(errors="ignore")
    except OSError:
        return ""

def alive(pid):
    try:
        os.kill(int(pid), 0); return True
    except (OSError, ValueError):
        return False

def api_version(path):
    m = re.search(r"^API_VERSION=(\d+)", rd(path), re.M)
    return int(m.group(1)) if m else 0

def src_vars(path, names):
    if not os.path.exists(path):
        return {}
    code = '. "$1" 2>/dev/null; printf "%s\\037" ' + " ".join('"${%s:-}"' % n for n in names)
    try:
        out = subprocess.run(["bash", "-c", code, "_", path], capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return {}
    vals = out.split("\x1f")
    return {n: (vals[i] if i < len(vals) else "") for i, n in enumerate(names)}

def ival(s, d=0):
    try:
        return int(s)
    except (TypeError, ValueError):
        return d

out = {"serveur": rd("/etc/hostname") or os.uname().nodename, "maintenant": int(time.time())}

# ---------------- Copie Synology -> OMV ----------------
cp = {"installe": os.path.exists("/usr/local/bin/copie-omv"), "api": api_version("/usr/local/bin/copie-omv"),
      "cle_omv": os.path.exists("/root/.ssh/id_copie_omv")}
v = src_vars(C + "/en-cours", ["SRC", "DST", "MODE", "TOTAL", "NBF", "DEBUT", "PID"])
if v:
    cp["source"] = v["SRC"]; cp["destination"] = v["DST"]; cp["mode"] = v["MODE"]
    cp["total"] = ival(v["TOTAL"]); cp["nb_fichiers"] = ival(v["NBF"]); cp["debut"] = ival(v["DEBUT"])
    cp["en_cours"] = alive(v["PID"]) if v["PID"] else False
    code = rd(C + "/code")
    cp["code"] = code if code else None
    t = tail(C + "/progression.log", 6000).replace("\r", "\n")
    for line in reversed(t.splitlines()):
        m = re.match(r"^\s*([\d.,]+\S*)\s+(\d+)%\s+(\S+/s)\s+(\S+)", line)
        if m:
            cp["avancement"] = {"fait": m.group(1), "pct": int(m.group(2)), "vitesse": m.group(3), "reste": m.group(4)}
            break
    if code and code not in ("0", "stop"):
        lines = [l for l in t.splitlines() if l.strip() and not re.search(r"\d+%", l)]
        cp["erreurs"] = lines[-8:]
hist = [l for l in rd(C + "/historique.log").splitlines() if l.strip()]
cp["historique"] = hist[-30:]
out["copie"] = cp

# ---------------- Migration oCIS ----------------
mg = {"installe": os.path.exists("/usr/local/bin/migre-drive-ocis"), "api": api_version("/usr/local/bin/migre-drive-ocis")}
conf = src_vars(M + "/config", ["OCIS_URL", "LOCAL_URL", "OCIS_USER", "OCIS_VENDOR", "OCIS_INSECURE"])
mg["config"] = {"url": conf.get("OCIS_URL", ""), "locale": conf.get("LOCAL_URL", ""), "utilisateur": conf.get("OCIS_USER", ""),
                "mode": conf.get("OCIS_VENDOR", ""), "certificat_accepte": conf.get("OCIS_INSECURE", "") == "1"} if conf else None
q = []
for line in rd(M + "/file-attente").splitlines():
    p = line.split("|")
    if len(p) >= 7:
        q.append({"source": p[0], "libelle": p[1], "espace_id": p[2], "espace": p[3], "sous_dossier": p[5],
                  "total": ival(p[6]), "suppression": p[7] if len(p) > 7 and p[7] else "non"})
mg["file"] = q
r = src_vars(M + "/en-cours", ["NB", "DEBUT", "PID"])
mg["en_cours"] = bool(r) and bool(r.get("PID")) and alive(r["PID"])
if r:
    mg["nb"] = ival(r["NB"]); mg["debut"] = ival(r["DEBUT"])
e = src_vars(M + "/etape", ["ETAPE", "E_SRC", "E_LABEL", "E_SPACE", "E_TOTAL", "E_DEL", "REPRISE", "PHASE"])
if e and mg["en_cours"]:
    et = {"etape": ival(e["ETAPE"]), "source": e["E_SRC"], "libelle": e["E_LABEL"], "espace": e["E_SPACE"],
          "total": ival(e["E_TOTAL"]), "suppression": e["E_DEL"], "reprise": ival(e["REPRISE"]), "phase": e["PHASE"]}
    logt = tail(M + "/progression.log", 20000)
    line = ""
    if e["PHASE"] in ("verification", "relecture"):
        safe = re.sub(r"[^A-Za-z0-9_-]", "_", e["E_LABEL"])
        for l in tail(f"{M}/verif-{safe}/check.log", 20000).splitlines():
            if "Checks:" in l:
                line = re.sub(r"\s+", " ", l.split("Checks:", 1)[1]).strip()
    else:
        for l in logt.splitlines()[-80:]:
            if l.startswith("=== "):
                line = ""
            elif "NOTICE:" in l:
                line = re.sub(r"\s+", " ", l.split("NOTICE:", 1)[1]).strip()
    et["ligne"] = line
    m2 = re.search(r"(\d+)%", line)
    et["pct"] = int(m2.group(1)) if m2 else None
    rss = rd(M + "/rss").split()
    if rss:
        et["ram_mo"] = ival(rss[0])
    mg["etape"] = et
res = []
for line in rd(M + "/resultats").splitlines():
    p = line.split("|", 4)
    if len(p) == 5:
        res.append({"n": ival(p[0]), "etat": p[1], "libelle": p[2], "espace": p[3], "detail": p[4]})
mg["resultats"] = res
code = rd(M + "/code")
mg["bilan"] = code if code else None
mg["historique"] = [l for l in rd(M + "/historique.log").splitlines() if l.strip()][-40:]
mg["journal"] = [l for l in tail(M + "/progression.log", 12000).splitlines() if l.strip()][-14:]
out["migration"] = mg
print(json.dumps(out, ensure_ascii=False))
PYEOF
"#####;

// =====================================================================
//  Actions
// =====================================================================

/// Lancement en arriere-plan, independant de la connexion SSH
pub fn background(cmd: &str, msg: &str) -> String {
    format!(
        "nohup setsid {cmd} >/dev/null 2>&1 < /dev/null &\nsleep 1\necho {}\n",
        sq(msg)
    )
}

pub fn nb_run(name: &str) -> String {
    background(
        &format!("{NB_BIN} run {}", sq(name)),
        &format!("Sauvegarde « {name} » lancée."),
    )
}

pub fn nb_run_all() -> String {
    background(&format!("{NB_BIN} run-all"), "Toutes les sauvegardes sont lancées (l'une après l'autre).")
}

pub fn nb_stop() -> String {
    format!("{NB_BIN} stop 2>&1")
}

pub struct JobForm<'a> {
    pub name: &'a str,
    pub source: &'a str,
    pub folder: &'a str,
    pub mirror: bool,
    pub encrypt: bool,
    pub schedule: &'a str,
    pub trash_days: u32,
}

pub fn nb_save(new: bool, f: &JobForm) -> String {
    format!(
        "{NB_BIN} save {} {} {} {} {} {} {} {} 2>&1\n",
        if new { "nouveau" } else { "modif" },
        sq(f.name),
        sq(f.source),
        sq(f.folder),
        if f.mirror { "sync" } else { "copy" },
        if f.encrypt { "oui" } else { "non" },
        sq(f.schedule),
        f.trash_days
    )
}

pub fn nb_delete(name: &str, purge: bool) -> String {
    format!(
        "{NB_BIN} delete {}{} 2>&1\n",
        sq(name),
        if purge { " effacer-drive" } else { "" }
    )
}

pub fn nb_restore(name: &str, target: &str) -> String {
    background(
        &format!("{NB_BIN} restore {} {}", sq(name), sq(target)),
        &format!("Restauration de « {name} » lancée vers {target}."),
    )
}

pub fn omv_list_backup_sources() -> String {
    "for d in /srv/dev-disk-by-uuid-*/*/; do [ -d \"$d\" ] || continue; d=\"${d%/}\"; case \"${d##*/}\" in lost+found|@eaDir|'#recycle') continue;; esac; echo \"$d\"; done\n".into()
}

/// Sous-dossiers d'un dossier de l'OMV ("" = disques de donnees)
pub fn omv_list_dirs(dir: &str) -> String {
    if dir.is_empty() || dir == "/srv" {
        "ls -d /srv/dev-disk-by-uuid-*/ 2>/dev/null | sed 's#/$##'\n".into()
    } else {
        format!(
            "find {} -mindepth 1 -maxdepth 1 -type d ! -name 'lost+found' ! -name '.*' ! -name '@eaDir' ! -name '#recycle' 2>/dev/null | sort\n",
            sq(dir)
        )
    }
}

/// Sous-dossiers d'un dossier du Synology ("" = dossiers partages)
pub fn syno_list_dirs(dir: &str) -> String {
    if dir.is_empty() || dir == "/" {
        "ls -d /volume[0-9]*/*/ 2>/dev/null | sed 's#/$##' | grep -v -E '/(@|#)'\n".into()
    } else {
        format!(
            "find {} -mindepth 1 -maxdepth 1 -type d ! -name '@*' ! -name '#*' ! -name '.*' 2>/dev/null | sort\n",
            sq(dir)
        )
    }
}

pub fn free_space(dir: &str) -> String {
    format!("df -B1 --output=avail {} 2>/dev/null | tail -n 1 | tr -d ' '\n", sq(dir))
}

pub fn syno_size(dir: &str) -> String {
    format!(
        "du -sb --exclude='@eaDir' --exclude='#recycle' --exclude='#SynoRecycle' {d} 2>/dev/null | cut -f1\nfind {d} -type f ! -path '*/@eaDir/*' ! -path '*/#recycle/*' ! -path '*/#SynoRecycle/*' 2>/dev/null | wc -l\n",
        d = sq(dir)
    )
}

pub fn cam_service(action: &str) -> String {
    format!(
        "systemctl {action} cam-sync 2>&1\nsleep 1\necho \"Service cam-sync : $(systemctl is-active cam-sync)\"\n"
    )
}

pub fn cam_catchup() -> String {
    r#"if [ -e /run/cam-sync-full.lock ] && ! flock -n /run/cam-sync-full.lock true; then
  echo "Un rattrapage est deja en cours."; exit 0
fi
if [ -x /usr/local/bin/cam-sync-catchup.sh ]; then
  nohup setsid flock -n /run/cam-sync-full.lock /usr/local/bin/cam-sync-catchup.sh >/dev/null 2>&1 < /dev/null &
else
  cmd=$(grep -v '^#' /etc/cron.d/cam-sync 2>/dev/null | grep -v '^\s*$' | head -n 1 | sed -E 's/^([^ ]+ +){5}root +//')
  [ -n "$cmd" ] || { echo "Commande de rattrapage introuvable (/etc/cron.d/cam-sync)."; exit 1; }
  nohup setsid bash -c "$cmd" >/dev/null 2>&1 < /dev/null &
fi
sleep 1
echo "Rattrapage des caméras lancé : les vidéos manquantes partent vers le Drive."
"#
    .into()
}

pub fn nas_check() -> String {
    background("/usr/local/bin/nas-check", "Vérification lancée (Google Drive, quota, caméras, retards). Résultat dans 1 à 2 minutes.")
}

pub fn notify_test() -> String {
    "/usr/local/bin/nas-notify info test 'NAS' 'Test depuis NAS Manager (Windows) ✅' && echo 'Notification envoyée : vérifie ton téléphone.' || echo 'Échec de l envoi vers Home Assistant.'\n".into()
}

pub fn ack_alert(tag: &str) -> String {
    let t: String = tag
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        .collect();
    format!("rm -f /var/lib/nas-backup/alertes/{t} && echo 'Alerte « {t} » acquittée.'\n")
}

pub fn show_passwords() -> String {
    r#"found=0
for f in /root/nas-backup-motsdepasse.txt /root/cam-crypt-motsdepasse.txt; do
  [ -f "$f" ] || continue; found=1
  echo "=== $f"; cat "$f"; echo
done
[ $found = 1 ] || echo "Aucun fichier de mots de passe trouvé sur l'OMV."
"#
    .into()
}

pub fn tail_file(path: &str, lines: u32) -> String {
    format!(
        "if [ -f {p} ]; then tail -n {lines} {p} | tr '\\r' '\\n' | tail -n {lines}; else echo '(fichier absent : {path})'; fi\n",
        p = sq(path)
    )
}

pub fn fix_perms(dir: &str, owner: &str, group: &str) -> String {
    format!(
        "d={d}; [ -d \"$d\" ] || {{ echo \"Dossier introuvable : $d\"; exit 1; }}\n\
chown -R {og} \"$d\" && find \"$d\" -type d -exec chmod 2775 {{}} + && find \"$d\" -type f -exec chmod 664 {{}} + \
&& {{ echo 'Droits réparés :'; ls -ld \"$d\"; }} || echo 'Erreur (groupe ou utilisateur inexistant ?).'\n",
        d = sq(dir),
        og = sq(&format!("{owner}:{group}"))
    )
}

// ---------------- Synology : copie ----------------
pub fn copie_launch(src: &str, dst: &str, into_folder: bool, move_files: bool) -> String {
    format!(
        "{COPIE_BIN} lancer {} {} {} {} 2>&1\n",
        sq(src),
        sq(dst),
        if into_folder { "dossier" } else { "contenu" },
        if move_files { "deplacement" } else { "copie" }
    )
}

pub fn copie_stop() -> String {
    format!("{COPIE_BIN} arreter 2>&1\n")
}

// ---------------- Synology : migration ----------------
pub fn migre_spaces() -> String {
    format!("{MIGRE_BIN} espaces 2>&1\n")
}
pub fn migre_sources() -> String {
    format!("{MIGRE_BIN} sources 2>&1\n")
}
pub fn migre_add(src: &str, space_id: &str, sub: &str, del: &str, label: &str) -> String {
    format!(
        "{MIGRE_BIN} ajouter {} {} {} {} {} 2>&1\n",
        sq(src),
        sq(space_id),
        sq(if sub.trim().is_empty() { "-" } else { sub.trim() }),
        sq(del),
        sq(label)
    )
}
pub fn migre_remove(n: usize) -> String {
    format!("{MIGRE_BIN} retirer {n} 2>&1\n")
}
pub fn migre_start() -> String {
    format!("{MIGRE_BIN} lancer 2>&1\n")
}
pub fn migre_stop() -> String {
    format!("{MIGRE_BIN} arreter 2>&1\n")
}
pub fn migre_configure(url: &str, user: &str, token: &str, local: &str, insecure: bool) -> String {
    let clean = |s: &str| s.replace(['\n', '\r'], "").trim().to_string();
    format!(
        "{MIGRE_BIN} configurer 2>&1 <<'NASMGR_EOF'\n{}\n{}\n{}\n{}\n{}\nNASMGR_EOF\n",
        clean(url),
        clean(user),
        clean(token),
        if clean(local).is_empty() { "-".into() } else { clean(local) },
        if insecure { 1 } else { 0 }
    )
}

// ---------------- Installation des scripts ----------------
/// Ecrit un script sur le NAS (copie de sauvegarde .bak, remplacement atomique)
pub fn install_file(path: &str, content: &str) -> String {
    // fins de ligne Unix obligatoires pour bash (le depot peut etre extrait en CRLF sous Windows)
    let content = content.replace("\r\n", "\n");
    let b64 = base64::engine::general_purpose::STANDARD.encode(content.as_bytes());
    let mut wrapped = String::new();
    for chunk in b64.as_bytes().chunks(76) {
        wrapped.push_str(std::str::from_utf8(chunk).unwrap_or(""));
        wrapped.push('\n');
    }
    format!(
        "set -e\nmkdir -p \"$(dirname {p})\"\nbase64 -d > {p}.new <<'NASMGR_B64'\n{wrapped}NASMGR_B64\nbash -n {p}.new\n[ -f {p} ] && cp -f {p} {p}.bak || true\nchmod 755 {p}.new\nmv -f {p}.new {p}\necho \"Installé : {path}\"\n",
        p = sq(path)
    )
}

/// copie-omv avec l'adresse de l'OMV configuree dans l'application
pub fn copie_script_for(omv_host: &str) -> String {
    let host = omv_host.trim();
    if host.is_empty() {
        return COPIE_OMV_SH.to_string();
    }
    COPIE_OMV_SH
        .replace("\r\n", "\n")
        .lines()
        .map(|l| {
            if l.starts_with("OMV_HOST=\"") {
                format!("OMV_HOST=\"{host}\"          # adresse de l'OMV")
            } else {
                l.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
        + "\n"
}

// =====================================================================
//  Tests contre un NAS de test (NAS_MANAGER_LIVE_TEST=1, voir README)
// =====================================================================
#[cfg(test)]
mod live {
    use super::*;
    use crate::config;
    use crate::ssh::Ssh;
    use std::time::Duration;

    fn on() -> bool {
        std::env::var("NAS_MANAGER_LIVE_TEST").is_ok()
    }

    fn run(omv: bool, script: &str) -> crate::ssh::CmdOut {
        let s = config::load();
        let ssh = Ssh::new(&s.ssh_bin);
        let (h, p) = if omv { (s.omv, None) } else { (s.syno, std::env::var("NAS_MANAGER_TEST_SUDO").ok()) };
        let o = ssh.run(&h, p.as_deref(), script, Duration::from_secs(120)).expect("ssh");
        println!("--- code {}\n{}", o.code, o.text());
        o
    }

    #[test]
    fn live_omv() {
        if !on() {
            return;
        }
        let o = run(true, &(install_file(NB_BIN, NAS_BACKUP_SH) + &format!("{NB_BIN} gen-cron && cat /etc/cron.d/nas-backup\n")));
        assert_eq!(o.code, 0, "installation : {}", o.text());
        assert!(o.stdout.contains("run-at 03:30"));
        // nouvelle sauvegarde avec apostrophe et espace dans le chemin
        let d = "/srv/dev-disk-by-uuid-7cd5ac91-9ec8-439c-9de3-c5bf7f5418f5/Film's d'été";
        run(true, &format!("mkdir -p {}\n", sq(d)));
        let f = JobForm { name: "Films", source: d, folder: "Films d'été", mirror: true, encrypt: false, schedule: "05:10", trash_days: 14 };
        let o = run(true, &nb_save(true, &f));
        assert_eq!(o.code, 0, "{}", o.text());
        let o = run(true, "grep '^Films|' /etc/nas-backup/jobs.conf; cat /etc/cron.d/nas-backup");
        assert!(o.stdout.contains("Films|/srv/dev-disk-by-uuid-7cd5ac91-9ec8-439c-9de3-c5bf7f5418f5/Film's d'été|Films d'été|sync|non|05:10|14"));
        assert!(o.stdout.contains("run-at 05:10"));
        // doublon refuse
        let o = run(true, &nb_save(true, &f));
        assert_ne!(o.code, 0);
        // modification
        let f2 = JobForm { schedule: "manuel", mirror: false, ..f };
        let o = run(true, &nb_save(false, &f2));
        assert_eq!(o.code, 0);
        let o = run(true, "grep '^Films|' /etc/nas-backup/jobs.conf");
        assert!(o.stdout.trim().ends_with("|copy|non|manuel|0"));
        // horaire invalide
        let f3 = JobForm { schedule: "25:00", ..f2 };
        assert_ne!(run(true, &nb_save(false, &f3)).code, 0);
        // suppression
        let o = run(true, &nb_delete("Films", false));
        assert_eq!(o.code, 0);
        assert!(!run(true, "cat /etc/nas-backup/jobs.conf").stdout.contains("Films|"));
        // acquittement / mots de passe
        assert_eq!(run(true, &ack_alert("job-Documents; rm -rf /")).code, 0);
        run(true, &show_passwords());
        run(true, &tail_file("/var/log/cam-sync.log", 3));
        // collecte de l'etat : JSON valide et coherent
        let o = run(true, OMV_STATUS);
        let st: crate::model::OmvStatus = serde_json::from_str(o.stdout.lines().last().unwrap()).expect("json OMV");
        assert!(st.erreur.is_none());
        assert_eq!(st.nb_api, API_VERSION);
        assert!(st.sauvegardes.iter().any(|j| j.nom == "Photos" && j.dernier_etat.as_deref() == Some("OK")));
        assert!(st.cameras.installe);
    }

    #[test]
    fn live_identity() {
        if !on() {
            return;
        }
        let s = config::load();
        let ssh = Ssh::new(&s.ssh_bin);
        ssh.forget_host(&s.omv).unwrap();
        assert!(!ssh.host_known(&s.omv));
        let r = ssh.run(&s.omv, None, "true", Duration::from_secs(10));
        assert_eq!(r.unwrap_err(), crate::ssh::SshError::HostUnknown);
        let scan = ssh.scan_host(&s.omv).expect("scan");
        assert!(scan.fingerprints.iter().any(|f| f.contains("SHA256:")), "{:?}", scan.fingerprints);
        ssh.trust_host(&s.omv, &scan).unwrap();
        assert!(ssh.host_known(&s.omv));
        assert_eq!(run(true, "echo ok").stdout, "ok\n");
        // une fausse empreinte est refusee
        let mut bad = scan.clone();
        bad.entries = vec![format!("[{}]:{} ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakeFakeFakeFakeFakeFakeFakeFakeFakeFake", s.omv.host, s.omv.port)];
        ssh.trust_host(&s.omv, &bad).unwrap();
        let r = ssh.run(&s.omv, None, "true", Duration::from_secs(10));
        assert!(matches!(r, Err(crate::ssh::SshError::HostKeyChanged) | Err(crate::ssh::SshError::Unreachable(_))), "{r:?}");
        ssh.trust_host(&s.omv, &scan).unwrap();
        assert_eq!(run(true, "echo ok").stdout, "ok\n");
    }

    #[test]
    fn live_session() {
        if !on() {
            return;
        }
        // meme session reutilisee (meme PID du bash distant)
        let a = run(true, "echo $PPID");
        let b = run(true, "echo $PPID");
        assert_eq!(a.stdout, b.stdout, "la session doit etre reutilisee");
        // exit et set -e n'arretent pas la session
        assert_eq!(run(true, "set -e\nfalse\necho jamais").code, 1);
        assert_eq!(run(true, "exit 7").code, 7);
        assert_eq!(run(true, "echo $PPID").stdout, a.stdout);
        // stdout / stderr separes, sans retour a la ligne final
        let o = run(true, "printf abc; echo err >&2");
        assert_eq!(o.stdout, "abc\n");
        assert_eq!(o.stderr, "err\n");
        // une commande qui lit l'entree standard ne bloque pas la session
        let o = run(true, "cat; echo apres");
        assert_eq!(o.stdout, "apres\n");
        // heredoc et parentheses non equilibrees dans les donnees
        let o = run(true, "cat <<'EOF'\n) ( __NASMGR_END_x__ 0\nEOF\n");
        assert_eq!(o.stdout, ") ( __NASMGR_END_x__ 0\n");
        // sortie volumineuse
        let o = run(true, "seq 1 200000");
        assert_eq!(o.stdout.lines().count(), 200000);
        // appels concurrents (session occupee -> connexion dediee)
        let hs: Vec<_> = (0..4).map(|i| std::thread::spawn(move || run(true, &format!("sleep 0.3; echo {i}")).stdout)).collect();
        for (i, h) in hs.into_iter().enumerate() {
            assert_eq!(h.join().unwrap(), format!("{i}\n"));
        }
        // delai depasse : erreur Timeout puis nouvelle session fonctionnelle
        let s = config::load();
        let ssh = Ssh::new(&s.ssh_bin);
        let r = ssh.run(&s.omv, None, "sleep 5", Duration::from_secs(1));
        assert_eq!(r.unwrap_err(), crate::ssh::SshError::Timeout);
        assert_eq!(run(true, "echo ok").stdout, "ok\n");
        // sudo : mot de passe faux detecte
        let r = ssh.run(&s.syno, Some("mauvais"), "id -un", Duration::from_secs(30));
        assert_eq!(r.unwrap_err(), crate::ssh::SshError::SudoPassword);
        assert_eq!(run(false, "id -un").stdout, "root\n");
    }

    #[test]
    fn live_syno() {
        if !on() {
            return;
        }
        let o = run(false, &(install_file(COPIE_BIN, &copie_script_for("127.0.0.1")) + &install_file(MIGRE_BIN, MIGRE_OCIS_SH)));
        assert_eq!(o.code, 0);
        let o = run(false, &format!("grep '^OMV_HOST=' {COPIE_BIN}; {COPIE_BIN} api-version; {MIGRE_BIN} api-version; {MIGRE_BIN} sources"));
        assert!(o.stdout.contains("OMV_HOST=\"127.0.0.1\""));
        assert!(o.stdout.contains("/volume1/homes/alice/Drive|alice"));
        run(false, &syno_list_dirs(""));
        run(false, &syno_size("/volume1/photo"));
        run(false, &migre_remove(9));
        let o = run(false, SYNO_STATUS);
        let st: crate::model::SynoStatus = serde_json::from_str(o.stdout.lines().last().unwrap()).expect("json Synology");
        assert!(st.erreur.is_none());
        assert!(st.copie.installe && st.migration.installe);
        assert_eq!(st.migration.config.map(|c| c.utilisateur), Some("migration".to_string()));
    }
}

#[cfg(test)]
mod crlf {
    #[test]
    fn install_strips_crlf() {
        let s = super::install_file("/tmp/x.sh", "#!/bin/bash\r\necho ok\r\n");
        let b64: String = s.lines().skip_while(|l| !l.starts_with("base64")).skip(1).take_while(|l| *l != "NASMGR_B64").collect();
        use base64::Engine;
        let dec = base64::engine::general_purpose::STANDARD.decode(b64).unwrap();
        assert_eq!(String::from_utf8(dec).unwrap(), "#!/bin/bash\necho ok\n");
    }
}
