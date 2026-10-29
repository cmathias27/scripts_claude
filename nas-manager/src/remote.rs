//! Scripts envoyes au NAS : collecte de l'etat (JSON) et actions.
//! Les scripts des machines (nas-debian pour OMV / Debian, nas-synology) sont
//! integres a l'application (version de secours) et mis a jour depuis GitHub
//! (module `scripts`).
use crate::app::HostId;

use crate::ssh::sq;
use base64::Engine;

pub const NAS_DEBIAN_SH: &str = include_str!("../../nas-debian.sh");
pub const NAS_SYNOLOGY_SH: &str = include_str!("../../nas-synology.sh");
/// Version des commandes sans question d'un script (ligne API_VERSION=N)
pub fn api_of(script: &str) -> u32 {
    script
        .lines()
        .find_map(|l| l.strip_prefix("API_VERSION=").and_then(|v| v.trim().parse().ok()))
        .unwrap_or(0)
}
pub fn nb_api() -> u32 {
    api_of(NAS_DEBIAN_SH)
}
pub fn copie_api() -> u32 {
    api_of(NAS_SYNOLOGY_SH)
}

/// Script de l'OMV / Debian (commandes de sauvegarde comprises)
pub const NB_BIN: &str = "/usr/local/bin/nas-debian";
pub const DEBIAN_BIN: &str = "/usr/local/bin/nas-debian";
pub const SYNO_BIN: &str = "/usr/local/bin/nas-synology";
pub const COPIE_BIN: &str = "/usr/local/bin/nas-synology copie";
pub const MIGRE_BIN: &str = "/usr/local/bin/nas-synology migration";

// =====================================================================
//  Collecte de l'etat de l'OMV
// =====================================================================
pub static OMV_STATUS: std::sync::LazyLock<String> =
    std::sync::LazyLock::new(|| OMV_STATUS_SRC.replace("#__OCIS__\n", OCIS_PY));
pub static SYNO_STATUS: std::sync::LazyLock<String> =
    std::sync::LazyLock::new(|| SYNO_STATUS_SRC.replace("#__OCIS__\n", OCIS_PY));

/// Collecte commune de la migration vers oCIS et des transferts oCIS -> machine (meme
/// organisation sur le Synology et sur l'OMV / Debian : /root/.migre-ocis, /root/.ocis-transferts)
const OCIS_PY: &str = r#####"
def oc_collect(M="/root/.migre-ocis", T="/root/.ocis-transferts"):
    import json, os, re, subprocess, time

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
            os.kill(int(pid), 0)
        except (OSError, ValueError):
            return False
        # processus termine mais pas encore « reaped » : arrete
        return not re.search(r"^State:\s+Z", rd("/proc/%s/status" % pid), re.M)

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

    PG = ["PG_ETAPE", "PG_MAJ", "PG_PCT", "PG_FICHIERS", "PG_REF_FICHIERS", "PG_REF_OCTETS", "PG_ENVOYE", "PG_TOTAL_RCLONE",
          "PG_PROVISOIRE", "PG_SURPLUS", "PG_VITESSE", "PG_FICH_MIN", "PG_ETA", "PG_ESSAIS", "PG_ERREURS"]

    def avancement(pg):
        opt = lambda k: ival(pg[k]) if pg[k] != "" else None
        return {"pct": opt("PG_PCT"), "fichiers": ival(pg["PG_FICHIERS"]), "ref_fichiers": opt("PG_REF_FICHIERS"),
                "ref_octets": opt("PG_REF_OCTETS"), "envoye": ival(pg["PG_ENVOYE"]),
                "total_rclone": ival(pg["PG_TOTAL_RCLONE"]), "provisoire": pg["PG_PROVISOIRE"] == "1",
                "surplus": ival(pg["PG_SURPLUS"]), "vitesse": opt("PG_VITESSE"), "fich_min": opt("PG_FICH_MIN"),
                "eta": opt("PG_ETA"), "essais": ival(pg["PG_ESSAIS"]), "erreurs": ival(pg["PG_ERREURS"])}

    ev = re.compile(r"^(===|    (dmesg|stderr):)|ERROR|CRITICAL|Attempt \d")

    # ---------------- migration vers oCIS
    mg = {}
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
        # avancement detaille : par rapport a la vraie taille de la source
        pg = src_vars(M + "/avancement", PG)
        if pg and pg["PG_ETAPE"] == e["ETAPE"] and e["PHASE"] in ("", "transfert") and time.time() - ival(pg["PG_MAJ"]) < 60:
            et["avancement"] = avancement(pg)
            if et["avancement"]["pct"] is not None:
                et["pct"] = et["avancement"]["pct"]
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
    # journal : evenements seulement (etapes, erreurs, nouveaux essais, bilan), sans les lignes de stats
    mg["journal"] = [l for l in tail(M + "/progression.log", 200000).splitlines() if l.strip() and ev.search(l)][-14:]

    # ---------------- transferts oCIS -> machine
    tr = {"config": bool(conf), "transferts": [], "planifies": False}
    for line in rd(T + "/transferts.conf").splitlines():
        p = line.split("|")
        if len(p) < 8 or line.startswith("#"):
            continue
        p += [""] * (9 - len(p))
        t = {"nom": p[0], "espace_id": p[1], "espace": p[2], "sous_dossier": p[3], "destination": p[4], "mode": p[5],
             "corbeille": ival(p[6]), "horaire": p[7], "debit": p[8]}
        if p[7] not in ("manuel", "une-fois", ""):
            tr["planifies"] = True
        d = src_vars("%s/%s.etat" % (T, re.sub(r"[^A-Za-z0-9_-]", "_", p[0])), ["ETAT", "DEBUT", "FIN", "DETAIL", "TRANSFERTS", "OCTETS", "SUPPR"])
        if d:
            t["dernier"] = {"etat": d["ETAT"], "debut": ival(d["DEBUT"]), "fin": ival(d["FIN"]), "detail": d["DETAIL"],
                            "fichiers": ival(d["TRANSFERTS"]), "octets": ival(d["OCTETS"]), "supprimes": ival(d["SUPPR"])}
        tr["transferts"].append(t)
    tr["file"] = [l for l in rd(T + "/file-attente").splitlines() if l.strip()]
    r = src_vars(T + "/en-cours", ["PID", "DEBUT"])
    if r and r.get("PID") and alive(r["PID"]):
        e = src_vars(T + "/etape", ["NOM", "DEBUT", "ESPACE", "SOUS", "DEST", "MODE", "REPRISE", "PHASE"])
        if e:
            c = {"nom": e["NOM"], "debut": ival(e["DEBUT"]), "espace": e["ESPACE"], "sous_dossier": e["SOUS"], "destination": e["DEST"],
                 "mode": e["MODE"], "reprise": ival(e["REPRISE"])}
            pg = src_vars(T + "/avancement", PG)
            if pg and time.time() - ival(pg["PG_MAJ"]) < 60:
                c["avancement"] = avancement(pg)
            rss = rd(T + "/rss").split()
            if rss:
                c["ram_mo"] = ival(rss[0])
            tr["en_cours"] = c
    tr["historique"] = [l for l in rd(T + "/historique.log").splitlines() if l.strip()][-40:]
    tr["journal"] = [l for l in tail(T + "/progression.log", 100000).splitlines() if l.strip() and ev.search(l)][-12:]
    return mg, tr
"#####;

const OMV_STATUS_SRC: &str = r#####"
export LC_ALL=C
command -v python3 >/dev/null || { echo '{"erreur":"python3 introuvable sur l OMV"}'; exit 0; }
python3 - <<'PYEOF'
import json, os, re, subprocess, time, glob

S = "/var/lib/nas-backup"
AG = "/usr/local/bin/nas-debian"

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

def hb(b):
    b = float(b or 0)
    for u in ("B", "KiB", "MiB", "GiB", "TiB"):
        if b < 1024 or u == "TiB":
            return ("%d %s" % (b, u)) if u == "B" else ("%.3f %s" % (b, u))
        b /= 1024

def hd(s):
    try:
        s = int(s)
    except (TypeError, ValueError):
        return "-"
    h, m, sec = s // 3600, s % 3600 // 60, s % 60
    return ("%dh" % h if h else "") + ("%dm" % m if h or m else "") + "%ds" % sec

def restic_progress(text):
    """Dernier etat d'avancement de restic (--json)."""
    st = None
    for line in text.splitlines():
        if line.startswith("{") and '"message_type":"status"' in line:
            st = line
    if not st:
        return None
    try:
        j = json.loads(st)
    except ValueError:
        return None
    el = j.get("seconds_elapsed") or 0
    done = j.get("bytes_done") or 0
    return {"octets_faits": hb(done), "octets_total": hb(j.get("total_bytes")), "pct": int((j.get("percent_done") or 0) * 100),
            "vitesse": hb(done / el if el else 0) + "/s", "reste": hd(j.get("seconds_remaining")) if j.get("seconds_remaining") else "-",
            "fichiers_faits": j.get("files_done") or 0, "fichiers_total": j.get("total_files") or 0, "erreurs": j.get("error_count") or 0,
            "duree": hd(el), "en_cours": [{"fichier": f, "pct": 0, "taille": "", "vitesse": "", "reste": ""} for f in (j.get("current_files") or [])[:6]]}

def last_lines(text, n, pat=None):
    ls = [l for l in text.splitlines() if l.strip() and (pat is None or re.search(pat, l))]
    return ls[-n:]

def meminfo():
    m = {}
    for l in rd("/proc/meminfo").splitlines():
        k, _, v = l.partition(":")
        try:
            m[k] = int(v.split()[0]) // 1024
        except (ValueError, IndexError):
            pass
    return {"total_mo": m.get("MemTotal", 0), "dispo_mo": m.get("MemAvailable", 0)}

def jload(txt):
    try:
        return json.loads(txt)
    except ValueError:
        return None

#__OCIS__
out = {"serveur": sh("hostname"), "maintenant": int(time.time())}
try:
    out["uptime_s"] = int(float(rd("/proc/uptime", "0").split()[0]))
    out["charge"] = rd("/proc/loadavg").split()[0]
except Exception:
    pass
out["memoire"] = meminfo()

# ---------------- Script de la machine ----------------
ag = None
if os.path.exists(AG):
    ag = jload(sh(AG + " version", 15)) or {"script": "nas-debian", "version": "?", "api": 0, "machine": ""}
out["agent"] = ag
m = re.search(r'^SCRIPT_VERSION="([^"]+)"', rd(AG + ".bak"), re.M)
out["agent_bak"] = m.group(1) if m else ""
out["anciens"] = [n for n in ("nas-backup", "nas-notify", "nas-check", "nas-ha-status")
                  if os.path.isfile("/usr/local/bin/" + n) and not os.path.islink("/usr/local/bin/" + n)]
if os.path.isfile("/usr/local/bin/cam-sync.sh"):
    out["anciens"].append("cam-sync")
out["migration_requise"] = bool(ag) and bool(out["anciens"])
out["perf"] = jload(sh(AG + " reglages voir", 15)) if ag else None

# ---------------- Disques ----------------
disques = []
roots = [r for r in sh(AG + " racines", 15).splitlines() if r.strip()] if ag else glob.glob("/srv/dev-disk-by-uuid-*")
vus = set()
if roots:
    args = " ".join("'" + r.replace("'", "'\\''") + "'" for r in roots)
    for line in sh("df -B1 --output=target,size,used,avail " + args + " 2>/dev/null | tail -n +2").splitlines():
        p = line.rsplit(None, 3)
        if len(p) == 4 and p[0] not in vus:
            vus.add(p[0])
            disques.append({"point": p[0], "taille": int(p[1]), "utilise": int(p[2]), "libre": int(p[3])})
out["disques"] = disques

# ---------------- Sauvegardes ----------------
out["nb_installe"] = bool(ag)
out["nb_api"] = int(ag.get("api") or 0) if ag else 0
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
    dl = p[9] if len(p) > 9 and p[9] else "gdrive:" + enc
    j = {"nom": name, "source": src, "dossier": sub, "mode": mode, "chiffre": enc == "oui",
         "horaire": sched, "corbeille": int(ret) if ret.isdigit() else 0,
         "debit": p[7] if len(p) > 7 else "", "memoire": p[8] if len(p) > 8 else "", "source_existe": os.path.isdir(src),
         "destinations": [{"nom": d.split(":")[0], "chiffre": d.split(":", 1)[-1] == "oui"} for d in dl.split(";") if d],
         "rotation": p[10] if len(p) > 10 else "", "paralleles": p[11] if len(p) > 11 else ""}
    en = rd(f"{S}/{name}.entretien.json")
    if en:
        j["entretien"] = jload(en)
    tj = rd(f"{S}/{name}.test.json")
    if tj:
        j["test"] = jload(tj)
    tl = f"/run/nas-backup-test-{name}.lock"
    j["test_en_cours"] = os.path.exists(tl) and rc(f"flock -n {tl} true") == 1
    ver = src_vars(f"{S}/{name}.verif.status", ["ETAT", "FIN", "IDENTIQUES", "DIFFERENTS", "MANQUANTS", "EN_TROP", "ERREURS", "DESTINATIONS", "TYPE"])
    if ver:
        etat = ver["ETAT"]
        if etat == "en_cours" and rc(f"flock -n /run/nas-backup-verif-{name}.lock true") != 1:
            etat = "interrompue"
        iv = lambda k: int(ver[k]) if ver[k].isdigit() else 0
        j["verification"] = {"etat": etat, "fin": iv("FIN"), "identiques": iv("IDENTIQUES"), "differents": iv("DIFFERENTS"),
                             "manquants": iv("MANQUANTS"), "en_trop": iv("EN_TROP"), "erreurs": iv("ERREURS"),
                             "destinations": ver["DESTINATIONS"], "type": ver["TYPE"]}
    sim = src_vars(f"{S}/{name}.simulation.status", ["ETAT", "DEBUT", "FIN", "ENVOIS", "SUPPRESSIONS", "OCTETS"])
    if sim:
        etat = sim["ETAT"]
        if etat == "en_cours" and rc(f"flock -n /run/nas-backup-simulation-{name}.lock true") != 1:
            etat = "interrompue"
        j["simulation"] = {"etat": etat, "fin": int(sim["FIN"] or 0), "envois": int(sim["ENVOIS"] or 0),
                           "suppressions": int(sim["SUPPRESSIONS"] or 0), "octets": int(sim["OCTETS"] or 0)}
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
        t = tail(f"{S}/{name}.run.log", 262144)
        j["avancement"] = restic_progress(t) if mode == "versions" else progress(t)
        rss = rd(f"{S}/{name}.rss").split()
        if rss and rss[0].isdigit():
            j["ram_mo"] = int(rss[0])
        dc = rd(f"{S}/{name}.dest").split("|")
        if len(dc) >= 3 and dc[0].isdigit():
            j["dest_en_cours"] = {"i": int(dc[0]), "n": int(dc[1]) if dc[1].isdigit() else 1, "nom": dc[2]}
    elif j.get("dernier_etat") == "ECHEC":
        kos = [d for d in (j.get("bilan") or {}).get("destinations", []) if d.get("code") and d.get("erreur")]
        if kos:
            j["derniere_erreur"] = "; ".join("%s : %s" % (d["destination"], d["erreur"]) for d in kos)[:300]
        else:
            errs = [l for l in tail(f"{S}/{name}.run.log", 262144).splitlines()
                    if (" ERROR " in l or "CRITICAL" in l or l.startswith("Fatal:")) and "Attempt " not in l]
            if errs:
                j["derniere_erreur"] = re.sub(r"^[0-9/ :]+", "", errs[-1])[:300]
    jobs.append(j)
out["sauvegardes"] = jobs
out["verif_auto"] = rd("/etc/nas-backup/verification")
out["test_auto"] = rd("/etc/nas-backup/test-restauration")

# ---------------- Destinations, kit de secours ----------------
if ag and int(ag.get("api") or 0) >= 7:
    dl = jload(sh(AG + " destinations liste", 15)) or []
    try:
        de = json.load(open(S + "/destinations.json"))
    except Exception:
        de = {}
    for d in dl:
        if d.get("nom") in de:
            d["etat"] = de[d["nom"]]
    out["destinations"] = dl
    out["secours"] = jload(sh(AG + " secours etat", 15))
if ag and int(ag.get("api") or 0) >= 9:
    out["reveil"] = jload(sh(AG + " reveil liste", 15))

# ---------------- Restauration ----------------
r = src_vars(S + "/restauration.status", ["ETAT", "NOM", "CIBLE", "DEBUT", "FIN", "CODE", "ELEMENT", "VERSION", "DATE"])
if r:
    rr = {"etat": r["ETAT"], "nom": r["NOM"], "cible": r["CIBLE"], "debut": r["DEBUT"], "fin": r["FIN"], "code": r["CODE"],
          "element": r["ELEMENT"], "version": r["VERSION"], "date": r["DATE"]}
    if r["ETAT"] == "en_cours":
        if rc("flock -n /run/nas-backup-restauration.lock true") != 1:
            rr["etat"] = "interrompue"
        else:
            t = tail(S + "/restauration.log", 131072)
            rr["avancement"] = progress(t) or restic_progress(t)
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

# ---------------- Sauvegardes temps reel ----------------
def ival(x, d=0):
    try:
        return int(x)
    except (TypeError, ValueError):
        return d

def shq(x):
    return "'" + x.replace("'", "'\\''") + "'"

SYSTEMD = os.path.isdir("/run/systemd/system")
cam_job = ""
for l in rd("/etc/nas-backup/agent.conf").splitlines():
    if l.startswith("CAM_JOB="):
        cam_job = l.split("=", 1)[1].strip().strip("'\"")
out["cam_job"] = cam_job
minuit = time.mktime(time.localtime()[:3] + (0, 0, 0, 0, 0, -1))
rtl = []
for line in rd("/etc/nas-backup/temps-reel.conf").splitlines():
    if not line.strip() or line.startswith("#"):
        continue
    p = line.split("|")
    if len(p) < 4:
        continue
    p += [""] * (12 - len(p))
    name = p[0]
    unit = "nas-temps-reel@" + name
    if SYSTEMD:
        actif = sh("systemctl is-active " + shq(unit)) == "active"
        auto = sh("systemctl is-enabled " + shq(unit)) == "enabled"
    else:
        pid = rd(f"{S}/rt-{name}.pid")
        actif = bool(pid) and alive(pid)
        auto = actif
    lock = f"/run/nas-temps-reel-{name}.lock"
    j = {"nom": name, "dossiers": [{"chemin": d, "existe": os.path.isdir(d)} for d in p[1].split(";") if d],
         "destination": p[2], "suppression": p[3], "corbeille": ival(p[4]), "exclusions": p[5], "types": p[6],
         "delai": ival(p[7], 10), "rattrapage": ival(p[8], 15), "anomalie": ival(p[9]), "memoire": p[10], "debit": p[11], "paralleles": p[12] if len(p) > 12 else "",
         "chiffre": p[2].split(":")[0] in ("gbackup", "gcrypt"), "actif": actif, "demarrage_auto": auto,
         "rattrapage_en_cours": os.path.exists(lock) and rc(f"flock -n {shq(lock)} true") == 1}
    pz = rd(f"{S}/rt-{name}.pause")
    if pz:
        t, _, why = pz.partition("|")
        j["pause"] = {"depuis": ival(t), "raison": why}
    env = octets = sup = ech = dern = 0
    for l in tail(f"{S}/rt-{name}.transferts.log", 400000).splitlines():
        q = l.split("|")
        if len(q) < 4 or not q[0].isdigit():
            continue
        ts, nb = int(q[0]), (ival(q[4], 1) if len(q) > 4 else 1)
        if q[3] != "ok":
            if ts >= minuit:
                ech += 1
            continue
        if q[1] == "envoi":
            dern = max(dern, ts)
            if ts >= minuit:
                env += nb; octets += ival(q[2])
        elif q[1] in ("suppression", "corbeille") and ts >= minuit:
            sup += nb
    j.update({"envois_aujourdhui": env, "volume_aujourdhui": octets, "suppressions_aujourdhui": sup, "echecs_aujourdhui": ech})
    if dern:
        j["dernier_envoi"] = dern
    log = tail(f"/var/log/nas-temps-reel/{name}.log", 300000)
    errs = [x for x in log.splitlines() if " ERROR " in x and "Attempt " not in x]
    if errs:
        j["derniere_erreur"] = errs[-1][:300]
    j["evenements"] = last_lines(log, 25, r": (Copied|Deleted|Moved)| ERROR |NOTICE: \[")
    rss = rd(f"{S}/rt-{name}.rss").split()
    if rss and rss[0].isdigit():
        j["ram_mo"] = int(rss[0])
    rtl.append(j)
out["temps_reel"] = rtl

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
out["alertes_installees"] = os.path.exists("/etc/nas-backup/notify.conf")
# ---------------- Canaux de notification, sante des disques (script 2.3+) ----------------
if ag and int(ag.get("api") or 0) >= 8:
    out["notif"] = jload(sh(AG + " alertes voir", 15))
    if out["notif"]:
        out["alertes_installees"] = bool(out["notif"].get("canaux"))
    try:
        out["sante_disques"] = json.load(open(S + "/disques.json"))
    except Exception:
        out["sante_disques"] = None
out["nas_check_en_cours"] = rc("pgrep -f '/usr/local/bin/nas-chec[k]' >/dev/null") == 0
# ---------------- Migration vers oCIS et transferts oCIS -> machine (script 2.5+)
if ag and int(ag.get("api") or 0) >= 10:
    mg, trf = oc_collect()
    mg.update({"installe": True, "api": int(ag.get("api") or 0)})
    trf["installe"] = True
    out["migration"] = mg
    out["transferts"] = trf
out["suivi_ha"] = os.path.exists("/etc/cron.d/nas-ha-status") and os.path.exists("/root/.config/mosquitto_pub")

# ---------------- Evolution de l'espace (un point toutes les 6 h, 1500 au plus)
try:
    E = S + "/espace.jsonl"
    last = 0
    if os.path.exists(E):
        lines = tail(E, 4000).splitlines()
        if lines:
            last = json.loads(lines[-1]).get("t", 0)
    if time.time() - last > 6 * 3600 and os.path.isdir(S):
        h = out.get("sante") or {}
        pt = {"t": int(time.time()), "drive_go": h.get("used_go"), "drive_total_go": h.get("total_go"),
              "disques": [{"p": d["point"], "u": d["utilise"], "s": d["taille"]} for d in disques]}
        with open(E, "a") as f:
            f.write(json.dumps(pt) + "\n")
        with open(E) as f:
            all_lines = f.readlines()
        if len(all_lines) > 1500:
            with open(E, "w") as f:
                f.writelines(all_lines[-1500:])
except Exception:
    pass
print(json.dumps(out, ensure_ascii=False))
PYEOF
"#####;

// =====================================================================
//  Collecte de l'etat du Synology (copie vers l'OMV + migration oCIS)
// =====================================================================
const SYNO_STATUS_SRC: &str = r#####"
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

def sh(cmd, t=20):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=t).stdout.strip()
    except Exception:
        return ""

def jload(txt):
    try:
        return json.loads(txt)
    except ValueError:
        return None

AG = "/usr/local/bin/nas-synology"
#__OCIS__
out = {"serveur": rd("/etc/hostname") or os.uname().nodename, "maintenant": int(time.time())}
mi = {}
for l in rd("/proc/meminfo").splitlines():
    k, _, v = l.partition(":")
    mi[k] = ival((v.split() or ["0"])[0]) // 1024
out["memoire"] = {"total_mo": mi.get("MemTotal", 0), "dispo_mo": mi.get("MemAvailable", 0)}
ag = None
if os.path.exists(AG):
    ag = jload(sh(AG + " version", 15)) or {"script": "nas-synology", "version": "?", "api": 0, "machine": "synology"}
out["agent"] = ag
mb = re.search(r'^SCRIPT_VERSION="([^"]+)"', rd(AG + ".bak"), re.M)
out["agent_bak"] = mb.group(1) if mb else ""
out["anciens"] = [n for n in ("copie-omv", "migre-drive-ocis")
                  if os.path.isfile("/usr/local/bin/" + n) and not os.path.islink("/usr/local/bin/" + n)]
out["migration_requise"] = bool(ag) and bool(out["anciens"])
out["perf"] = jload(sh(AG + " reglages voir", 15)) if ag else None
api = ival(ag.get("api")) if ag else 0

# ---------------- Copie Synology -> OMV ----------------
cp = {"installe": bool(ag), "api": api, "cle_omv": os.path.exists("/root/.ssh/id_copie_omv")}
v = src_vars(C + "/en-cours", ["SRC", "DST", "MODE", "TOTAL", "NBF", "DEBUT", "PID"])
if v:
    cp["source"] = v["SRC"]; cp["destination"] = v["DST"]; cp["mode"] = v["MODE"]
    cp["total"] = ival(v["TOTAL"]); cp["nb_fichiers"] = ival(v["NBF"]); cp["debut"] = ival(v["DEBUT"])
    cp["debit"] = src_vars(C + "/en-cours", ["BW"]).get("BW", "")
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
cq = []
for line in rd(C + "/file-attente").splitlines():
    p = line.split("|")
    if len(p) >= 4:
        cq.append({"source": p[0], "destination": p[1], "dans_dossier": p[2] == "dossier", "deplacement": p[3] == "deplacement",
                   "debit": p[4] if len(p) > 4 else ""})
cp["file"] = cq
out["copie"] = cp

# ---------------- Migration oCIS et transferts oCIS -> Synology (code commun) ----------------
mg, trf = oc_collect()
mg.update({"installe": bool(ag), "api": api})
out["migration"] = mg
if api >= 6:
    trf["installe"] = True
    out["transferts"] = trf
    # DSM peut reecrire /etc/crontab : planification des transferts remise si elle a disparu
    if trf.get("planifies") and "# >>> nas-synology transferts" not in rd("/etc/crontab"):
        sh("nohup setsid " + AG + " transferts gen-cron >/dev/null 2>&1 < /dev/null &", 5)

# ---------------- Sante des disques (script 2.2+) : verifiee au plus une fois par heure ----------------
if api >= 4:
    D = "/root/.nas-synology/disques.json"
    try:
        out["sante_disques"] = json.load(open(D))
    except Exception:
        out["sante_disques"] = None
    try:
        age = time.time() - os.path.getmtime(D)
    except OSError:
        age = 1e9
    if age > 3600:
        sh("nohup setsid " + AG + " disques verifier >/dev/null 2>&1 < /dev/null &", 5)
    al = []
    ad = "/root/.nas-synology/alertes"
    if os.path.isdir(ad):
        for f in sorted(os.listdir(ad)):
            try:
                al.append({"tag": f, "depuis": int(os.path.getmtime(os.path.join(ad, f)))})
            except OSError:
                pass
    out["alertes"] = al
print(json.dumps(out, ensure_ascii=False))
PYEOF
"#####;

/// Historique des sauvegardes et evolution de l'espace (OMV), a la demande
pub const OMV_HISTORY: &str = r#####"
export LC_ALL=C
python3 - <<'PYEOF'
import json
def load(p, n):
    try:
        with open(p, errors="ignore") as f:
            lines = f.readlines()[-n:]
    except OSError:
        return []
    out = []
    for l in lines:
        try:
            out.append(json.loads(l))
        except ValueError:
            pass
    return out
print(json.dumps({"executions": load("/var/lib/nas-backup/historique.jsonl", 1500),
                  "espace": load("/var/lib/nas-backup/espace.jsonl", 1500)}, ensure_ascii=False))
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
    /// sync (miroir), copy (copie) ou versions (restic)
    pub mode: &'a str,
    pub encrypt: bool,
    pub schedule: &'a str,
    pub trash_days: u32,
    /// limite de debit rclone (vide = aucune)
    pub bwlimit: &'a str,
    /// memoire de rclone : "" (reglage de la machine), un profil ou un nombre de Mo
    pub memory: &'a str,
    /// destinations « remote:oui|non » separees par ; (vide = Google Drive)
    pub dests: &'a str,
    /// versions gardees (jours:semaines:mois:annees)
    pub rotation: &'a str,
    /// fichiers envoyes en parallele ("" = reglage de la machine)
    pub parallel: &'a str,
}

pub fn nb_save(new: bool, f: &JobForm) -> String {
    format!(
        "{NB_BIN} save {} {} {} {} {} {} {} {} {} {} {} {} {} 2>&1\n",
        if new { "nouveau" } else { "modif" },
        sq(f.name),
        sq(f.source),
        sq(f.folder),
        sq(f.mode),
        if f.encrypt { "oui" } else { "non" },
        sq(f.schedule),
        f.trash_days,
        sq(f.bwlimit),
        sq(f.memory),
        sq(f.dests),
        sq(f.rotation),
        sq(f.parallel)
    )
}

pub fn nb_stop_job(name: &str) -> String {
    format!("{NB_BIN} stop {} 2>&1\n", sq(name))
}

pub fn nb_simulate(name: &str) -> String {
    background(
        &format!("{NB_BIN} simulate {}", sq(name)),
        &format!("Simulation de « {name} » lancée : le résultat s'affichera sur sa carte."),
    )
}

pub fn nb_delete(name: &str, purge: bool) -> String {
    format!(
        "{NB_BIN} delete {}{} 2>&1\n",
        sq(name),
        if purge { " effacer-drive" } else { "" }
    )
}

pub fn nb_restore(name: &str, target: &str, item: &str, trash: bool, dest: usize) -> String {
    let what = if item.is_empty() { format!("« {name} »") } else { format!("« {item} »") };
    background(
        &format!(
            "{NB_BIN} restore {} {} {} {} {dest}",
            sq(name),
            sq(target),
            sq(item),
            if trash { "corbeille" } else { "''" }
        ),
        &format!("Restauration de {what} lancée vers {target}."),
    )
}

pub fn nb_ls(name: &str, path: &str, trash: bool, dest: usize) -> String {
    format!("{NB_BIN} ls {} {} {} {dest}\n", sq(name), sq(path), if trash { "corbeille" } else { "''" })
}

// ---------------- Sauvegardes versionnees ----------------
pub fn versions_list(name: &str, dest: usize) -> String {
    format!("{NB_BIN} versions liste {} {dest}\n", sq(name))
}

pub fn versions_ls(name: &str, dest: usize, snap: &str, path: &str) -> String {
    format!("{NB_BIN} versions ls {} {dest} {} {}\n", sq(name), sq(snap), sq(path))
}

pub fn versions_restore(name: &str, dest: usize, snap: &str, target: &str, item: &str) -> String {
    let what = if item.is_empty() { format!("« {name} »") } else { format!("« {item} »") };
    background(
        &format!("{NB_BIN} versions restaurer {} {dest} {} {} {}", sq(name), sq(snap), sq(target), sq(item)),
        &format!("Restauration de {what} (version {}) lancée vers {target}.", snap.get(..8).unwrap_or(snap)),
    )
}

// ---------------- Destinations ----------------
fn one_line(s: &str) -> String {
    s.replace(['\n', '\r'], "").trim().to_string()
}

/// Test d'une destination (connexion, espace) ; resultat dans l'etat
pub fn dest_check(name: &str) -> String {
    format!("{NB_BIN} destinations etat {} >/dev/null 2>&1; {NB_BIN} destinations etat {} | tail -n 1\n", sq(name), sq(name))
}

/// Nouvelle destination (parametres cle=valeur, mots de passe compris, sur l'entree standard)
pub fn dest_create(name: &str, kind: &str, params: &[(String, String)]) -> String {
    let body: String = params.iter().filter(|(_, v)| !one_line(v).is_empty()).map(|(k, v)| format!("{k}={}\n", one_line(v))).collect();
    format!("{NB_BIN} destinations creer {} {} 2>&1 <<'NASMGR_EOF'\n{body}NASMGR_EOF\n", sq(name), sq(kind))
}

/// Destination connectee par le navigateur (jeton OAuth sur l'entree standard)
pub fn dest_token(name: &str, kind: &str, token: &str) -> String {
    format!("{NB_BIN} destinations jeton {} {} 2>&1 <<'NASMGR_EOF'\n{}\nNASMGR_EOF\n", sq(name), sq(kind), one_line(token))
}

pub fn dest_delete(name: &str) -> String {
    format!("{NB_BIN} destinations supprimer {} 2>&1\n", sq(name))
}

// ---------------- Kit de secours ----------------
pub fn secours_save(force: bool) -> String {
    background(
        &format!("{NB_BIN} secours sauvegarder{}", if force { " force" } else { "" }),
        "Kit de secours : création et envoi vers les destinations lancés.",
    )
}

pub fn secours_download() -> String {
    format!("{NB_BIN} secours telecharger\n")
}

/// Envoie un kit (fichier du PC) sur la machine puis le restaure (simulation ou application)
pub fn secours_restore(kit: &[u8], pass: &str, apply: bool) -> String {
    let b64 = base64::engine::general_purpose::STANDARD.encode(kit);
    let mut wrapped = String::new();
    for chunk in b64.as_bytes().chunks(76) {
        wrapped.push_str(std::str::from_utf8(chunk).unwrap_or(""));
        wrapped.push('\n');
    }
    format!(
        "umask 077; mkdir -p /root/.nas-manager\nbase64 -d > /root/.nas-manager/kit-a-restaurer.enc <<'NASMGR_B64'\n{wrapped}NASMGR_B64\n{NB_BIN} secours restaurer /root/.nas-manager/kit-a-restaurer.enc {} 2>&1 <<'NASMGR_EOF'\n{}\nNASMGR_EOF\nrc=$?\nrm -f /root/.nas-manager/kit-a-restaurer.enc\nexit $rc\n",
        if apply { "appliquer" } else { "''" },
        one_line(pass)
    )
}

/// Mots de passe notes (reconstruction sans kit) ; vide = inchange
pub fn secours_passwords(crypt: &str, salt: &str, versions: &str) -> String {
    format!(
        "{NB_BIN} secours mots-de-passe 2>&1 <<'NASMGR_EOF'\n{}\n{}\n{}\nNASMGR_EOF\n",
        one_line(crypt),
        one_line(salt),
        one_line(versions)
    )
}

pub fn nb_verify(name: &str) -> String {
    background(
        &format!("{NB_BIN} verifier {}", sq(name)),
        &format!("Vérification de « {name} » lancée : le résultat s'affichera sur sa carte."),
    )
}

pub fn nb_verify_plan(days: &str, time: &str) -> String {
    if days.is_empty() {
        format!("{NB_BIN} verif-plan off 2>&1\n")
    } else {
        format!("{NB_BIN} verif-plan {} {} 2>&1\n", sq(days), sq(time))
    }
}

// ---------------- Test de restauration a blanc (nas-debian 2.4+) ----------------
pub fn test_run(name: &str, nb: u32) -> String {
    background(
        &format!("{NB_BIN} test-restauration {} {}", sq(name), nb.clamp(1, 50)),
        &format!("Test de restauration de « {name} » lancé : le résultat s'affichera sur sa carte."),
    )
}

pub fn test_all() -> String {
    background(&format!("{NB_BIN} test-restauration tout"), "Test de restauration de toutes les sauvegardes lancé (l'une après l'autre).")
}

/// Test automatique : jours (« 7 » = dimanche), heure, nombre de fichiers ; jours vides = desactive
pub fn test_plan(days: &str, time: &str, nb: u32) -> String {
    if days.is_empty() {
        format!("{NB_BIN} test-restauration planifier non 2>&1\n")
    } else {
        format!("{NB_BIN} test-restauration planifier {} {} {} 2>&1\n", sq(days), sq(time), nb.clamp(1, 50))
    }
}

// ---------------- Retour a une date (nas-debian 2.4+) ----------------
/// Dates possibles (JSON : methode, min, max, points)
pub fn date_range(name: &str, dest: usize) -> String {
    format!("{NB_BIN} date plage {} {dest}\n", sq(name))
}

/// Apercu d'une restauration a une date (JSON)
pub fn date_preview(name: &str, dest: usize, ts: i64, item: &str) -> String {
    format!("{NB_BIN} date apercu {} {dest} {ts} {}\n", sq(name), sq(item))
}

pub fn date_restore(name: &str, dest: usize, ts: i64, target: &str, item: &str) -> String {
    let what = if item.is_empty() { format!("« {name} »") } else { format!("« {item} »") };
    background(
        &format!("{NB_BIN} date restaurer {} {dest} {ts} {} {}", sq(name), sq(target), sq(item)),
        &format!("Restauration de {what} telle qu'au {} lancée vers {target}.", crate::fmt::date_full(ts)),
    )
}

// ---------------- Reveil des machines (Wake-on-LAN) ----------------
pub fn reveil_set(name: &str, mac: &str, addr: &str, wait: u32, after: &str, ssh: &str) -> String {
    let dash = |s: &str| if s.trim().is_empty() { "-".to_string() } else { s.trim().to_string() };
    format!(
        "{NB_BIN} reveil regler {} {} {} {wait} {} {} 2>&1\n",
        sq(name),
        sq(mac.trim()),
        sq(&dash(addr)),
        word(after),
        sq(&dash(ssh))
    )
}

pub fn reveil_remove(name: &str) -> String {
    format!("{NB_BIN} reveil retirer {} 2>&1\n", sq(name))
}

pub fn reveil_test(name: &str) -> String {
    format!("{NB_BIN} reveil tester {} 2>&1\n", sq(name))
}

/// Synology : reveil de l'OMV avant les copies (MAC vide = desactive)
pub fn syno_omv_wake(mac: &str, after: &str) -> String {
    format!(
        "{SYNO_BIN} reglages omv-reveil {} {} 2>&1\n",
        sq(if mac.trim().is_empty() { "-" } else { mac.trim() }),
        word(after)
    )
}

/// Adresse MAC de l'interface reseau principale de la machine (+ « wol=... » si ethtool la connait)
pub fn detect_mac() -> String {
    r#"dev=$(ip route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ -n "$dev" ] || dev=$(awk 'NR>1 && $2=="00000000"{print $1; exit}' /proc/net/route 2>/dev/null)
[ -n "$dev" ] || { echo "interface reseau introuvable"; exit 1; }
cat "/sys/class/net/$dev/address"
command -v ethtool >/dev/null 2>&1 && ethtool "$dev" 2>/dev/null | awk -F': ' '/^[[:space:]]*Wake-on:/{print "wol=" $2}'
exit 0
"#
    .into()
}

pub fn omv_list_backup_sources() -> String {
    format!("if [ -x {DEBIAN_BIN} ]; then {DEBIAN_BIN} dossiers; else for d in /srv/dev-disk-by-uuid-*/*/; do [ -d \"$d\" ] || continue; d=\"${{d%/}}\"; case \"${{d##*/}}\" in lost+found|@eaDir|'#recycle') continue;; esac; echo \"$d\"; done; fi\n")
}

/// Sous-dossiers d'un dossier de l'OMV / Debian ("" = disques de donnees)
pub fn omv_list_dirs(dir: &str) -> String {
    if dir.is_empty() || dir == "/srv" {
        format!("if [ -x {DEBIAN_BIN} ]; then {DEBIAN_BIN} racines; else ls -d /srv/dev-disk-by-uuid-*/ 2>/dev/null | sed 's#/$##'; fi\n")
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

// ---------------- Sauvegardes temps reel ----------------
pub struct RtSave<'a> {
    pub name: &'a str,
    /// dossiers separes par ;
    pub dirs: &'a str,
    pub dest: &'a str,
    /// directe, corbeille ou copie
    pub deletion: &'a str,
    pub trash_days: u32,
    pub excl: &'a str,
    pub types: &'a str,
    pub delay: u32,
    pub catchup: u32,
    pub anomaly: u32,
    pub memory: &'a str,
    pub bwlimit: &'a str,
    /// fichiers envoyes en parallele ("" = reglage de la machine)
    pub parallel: &'a str,
}

pub fn rt_save(new: bool, f: &RtSave) -> String {
    format!(
        "{NB_BIN} temps-reel save {} {} {} {} {} {} {} {} {} {} {} {} {} {} 2>&1\n",
        if new { "nouveau" } else { "modif" },
        sq(f.name),
        sq(f.dirs),
        sq(f.dest),
        f.deletion,
        f.trash_days,
        sq(f.excl),
        sq(f.types),
        f.delay,
        f.catchup,
        f.anomaly,
        sq(f.memory),
        sq(f.bwlimit),
        sq(f.parallel)
    )
}

/// demarrer, arreter, redemarrer, pause, reprendre
pub fn rt_cmd(action: &str, name: &str) -> String {
    format!("{NB_BIN} temps-reel {action} {} 2>&1\n", sq(name))
}

pub fn rt_delete(name: &str, purge: bool) -> String {
    format!("{NB_BIN} temps-reel supprimer {}{} 2>&1\n", sq(name), if purge { " effacer-destination" } else { "" })
}

/// Rattrapage (ou envoi complet) en arriere-plan
pub fn rt_catchup(name: &str, full: bool) -> String {
    background(
        &format!("{NB_BIN} temps-reel {} {}", if full { "envoi-complet" } else { "rattrapage" }, sq(name)),
        &if full {
            format!("Envoi complet de « {name} » lancé en arrière-plan.")
        } else {
            format!("Rattrapage de « {name} » lancé.")
        },
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

pub fn ack_alert_syno(tag: &str) -> String {
    let t: String = tag.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-').collect();
    format!("rm -f /root/.nas-synology/alertes/{t} && echo 'Alerte « {t} » acquittée.'\n")
}

// ---------------- Notifications (nas-debian 2.3+) ----------------
fn word(s: &str) -> String {
    s.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-').collect()
}

/// Configure un canal (ha, ntfy, telegram, discord, email) puis envoie un message de test.
/// Les parametres vides ne sont pas transmis (un secret vide garde l'ancien).
pub fn canal_set(canal: &str, niveau: &str, params: &[(&str, String)]) -> String {
    let body: String = params.iter().filter(|(_, v)| !one_line(v).is_empty()).map(|(k, v)| format!("{k}={}\n", one_line(v))).collect();
    format!("{NB_BIN} alertes canal {} {} 2>&1 <<'NASMGR_EOF'\n{body}NASMGR_EOF\n", word(canal), word(niveau))
}

pub fn canal_level(canal: &str, niveau: &str) -> String {
    format!("{NB_BIN} alertes niveau {} {} 2>&1\n", word(canal), word(niveau))
}

pub fn canal_remove(canal: &str) -> String {
    format!("{NB_BIN} alertes retirer {} 2>&1\n", word(canal))
}

pub fn canal_test(canal: &str) -> String {
    format!("{NB_BIN} alertes tester {} 2>&1\n", word(canal))
}

/// Conversations Telegram ayant ecrit au bot : lignes « id|nom »
pub fn telegram_chats(token: &str) -> String {
    format!("{NB_BIN} alertes telegram 2>&1 <<'NASMGR_EOF'\n{}\nNASMGR_EOF\n", one_line(token))
}

pub fn alert_thresholds(repeat_h: u32, quota_pct: u32, late_h: u32) -> String {
    format!("{NB_BIN} alertes seuils {repeat_h} {quota_pct} {late_h} 2>&1\n")
}

pub fn report_view(freq: &str) -> String {
    format!("{NB_BIN} rapport voir {} 2>&1\n", word(freq))
}

pub fn report_send(freq: &str) -> String {
    format!("{NB_BIN} rapport envoyer {} 2>&1\n", word(freq))
}

pub fn report_plan(freq: &str, day: u32, time: &str, channels: &[String]) -> String {
    let ch: Vec<String> = channels.iter().map(|c| word(c)).filter(|c| !c.is_empty()).collect();
    let t: String = time.chars().filter(|c| c.is_ascii_digit() || *c == ':').collect();
    format!("{NB_BIN} rapport planifier {} {day} {t} {} 2>&1\n", word(freq), ch.join(" "))
}

/// Verification immediate de la sante des disques (SMART, RAID)
pub fn disks_check(syno: bool) -> String {
    format!("{} disques verifier >/dev/null 2>&1; echo 'Disques vérifiés.'\n", if syno { SYNO_BIN } else { NB_BIN })
}

pub fn show_passwords() -> String {
    r#"if /usr/local/bin/nas-debian mots-de-passe 2>/dev/null; then exit 0; fi
found=0
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
pub fn copie_launch(src: &str, dst: &str, into_folder: bool, move_files: bool, bw_kbps: Option<u32>) -> String {
    format!(
        "{COPIE_BIN} lancer {} {} {} {} {} 2>&1\n",
        sq(src),
        sq(dst),
        if into_folder { "dossier" } else { "contenu" },
        if move_files { "deplacement" } else { "copie" },
        bw_kbps.map(|b| b.to_string()).unwrap_or_default()
    )
}

pub fn copie_queue_add(src: &str, dst: &str, into_folder: bool, move_files: bool, bw_kbps: Option<u32>) -> String {
    format!(
        "{COPIE_BIN} ajouter {} {} {} {} {} 2>&1\n",
        sq(src),
        sq(dst),
        if into_folder { "dossier" } else { "contenu" },
        if move_files { "deplacement" } else { "copie" },
        bw_kbps.map(|b| b.to_string()).unwrap_or_default()
    )
}

pub fn copie_queue_remove(n: usize) -> String {
    format!("{COPIE_BIN} retirer {n} 2>&1\n")
}

pub fn copie_queue_next() -> String {
    format!("{COPIE_BIN} lancer-file 2>&1\n")
}

pub fn copie_stop() -> String {
    format!("{COPIE_BIN} arreter 2>&1\n")
}

// ---------------- Migration vers oCIS (Synology, OMV / Debian 2.5+) ----------------
fn mig_bin(h: HostId) -> &'static str {
    match h {
        HostId::Syno => MIGRE_BIN,
        HostId::Omv => "/usr/local/bin/nas-debian migration",
    }
}
pub fn migre_spaces(h: HostId) -> String {
    format!("{} espaces 2>&1\n", mig_bin(h))
}
pub fn migre_sources(h: HostId) -> String {
    format!("{} sources 2>&1\n", mig_bin(h))
}
pub fn migre_add(
    h: HostId,
    src: &str,
    space_id: &str,
    sub: &str,
    del: &str,
    label: &str,
) -> String {
    format!(
        "{} ajouter {} {} {} {} {} 2>&1\n",mig_bin(h),
        sq(src),
        sq(space_id),
        sq(if sub.trim().is_empty() { "-" } else { sub.trim() }),
        sq(del),
        sq(label)
    )
}
pub fn migre_remove(h: HostId, n: usize) -> String {
    format!("{} retirer {n} 2>&1\n", mig_bin(h))
}
pub fn migre_start(h: HostId) -> String {
    format!("{} lancer 2>&1\n", mig_bin(h))
}
pub fn migre_stop(h: HostId) -> String {
    format!("{} arreter 2>&1\n", mig_bin(h))
}
pub fn migre_configure(h: HostId,
    url: &str, user: &str, token: &str, local: &str, insecure: bool,
) -> String {
    let clean = |s: &str| s.replace(['\n', '\r'], "").trim().to_string();
    format!(
        "{} configurer 2>&1 <<'NASMGR_EOF'\n{}\n{}\n{}\n{}\n{}\nNASMGR_EOF\n",mig_bin(h),
        clean(url),
        clean(user),
        clean(token),
        if clean(local).is_empty() { "-".into() } else { clean(local) },
        if insecure { 1 } else { 0 }
    )
}

// ---------------- Transferts oCIS -> machine (nas-debian 2.5+, nas-synology 2.4+) ----------------
fn tr_bin(h: HostId) -> &'static str {
    match h {
        HostId::Syno => "/usr/local/bin/nas-synology transferts",
        HostId::Omv => "/usr/local/bin/nas-debian transferts",
    }
}

/// Espaces oCIS (personnel et projets) : lignes « id|nom|webDavUrl|libre|quota|type »
pub fn tr_spaces(h: HostId) -> String {
    format!("{} espaces 2>&1\n", tr_bin(h))
}

/// Sous-dossiers d'un dossier d'un espace oCIS (un par ligne)
pub fn tr_browse(h: HostId, space: &str, path: &str) -> String {
    format!("{} parcourir {} {} 2>&1\n", tr_bin(h), sq(space), sq(path))
}

#[derive(Clone, Copy)]
pub struct TrSave<'a> {
    pub name: &'a str,
    pub space: &'a str,
    pub sub: &'a str,
    pub dest: &'a str,
    /// copie ou miroir
    pub mode: &'a str,
    pub trash_days: u32,
    /// manuel, une-fois ou HH:MM[/jours];...
    pub schedule: &'a str,
    pub bwlimit: &'a str,
}

pub fn tr_save(h: HostId, new: bool, f: &TrSave) -> String {
    format!(
        "{} save {} {} {} {} {} {} {} {} {} 2>&1\n",
        tr_bin(h),
        if new { "nouveau" } else { "modif" },
        sq(f.name),
        sq(f.space),
        sq(if f.sub.trim().is_empty() {
            "-"
        } else {
            f.sub.trim()
        }),
        sq(f.dest),
        word(f.mode),
        f.trash_days,
        sq(f.schedule),
        sq(f.bwlimit)
    )
}

pub fn tr_delete(h: HostId, name: &str) -> String {
    format!("{} supprimer {} 2>&1\n", tr_bin(h), sq(name))
}

pub fn tr_launch(h: HostId, name: &str) -> String {
    format!("{} lancer {} 2>&1\n", tr_bin(h), sq(name))
}

pub fn tr_stop(h: HostId) -> String {
    format!("{} arreter 2>&1\n", tr_bin(h))
}

/// Journal des derniers passages d'un transfert
pub fn tr_log(name: &str) -> String {
    let n: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    tail_file(&format!("/root/.ocis-transferts/journaux/{n}.log"), 300)
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

// =====================================================================
//  Tests contre un NAS de test (NAS_MANAGER_LIVE_TEST=1, voir README)
// =====================================================================
// (pas dans l'interface texte, qui reprend ce fichier sans le reste de l'application)
#[cfg(all(test, not(nas_manager_tui)))]
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
        // installation du nouveau script a cote d'une ancienne installation
        let o = run(true, &(install_file(DEBIAN_BIN, NAS_DEBIAN_SH) + &format!("{DEBIAN_BIN} installer\n{DEBIAN_BIN} version\n")));
        assert_eq!(o.code, 0, "installation : {}", o.text());
        let v: crate::model::Agent = serde_json::from_str(o.stdout.lines().last().unwrap()).expect("version");
        assert_eq!((v.script.as_str(), v.api), ("nas-debian", nb_api()));
        assert_eq!(v.version, crate::scripts::embedded_version(crate::scripts::Kind::Debian));
        let st: crate::model::OmvStatus = serde_json::from_str(run(true, &OMV_STATUS).stdout.lines().last().unwrap()).expect("json OMV");
        assert!(st.migration_requise, "anciens scripts : {:?}", st.anciens);
        assert!(st.anciens.contains(&"nas-backup".to_string()) && st.anciens.contains(&"nas-notify".to_string()));
        assert!(st.perf.is_some() && st.memoire.total_mo > 0);
        // migration : simulation sans effet, puis application
        let o = run(true, &format!("{DEBIAN_BIN} migrer simulation; [ -L /usr/local/bin/nas-backup ] && echo LIEN || echo FICHIER"));
        assert!(o.stdout.contains("ancien script remplace") && o.stdout.trim_end().ends_with("FICHIER"), "{}", o.text());
        let o = run(true, &format!("{DEBIAN_BIN} migrer appliquer 2>&1; readlink /usr/local/bin/nas-backup /usr/local/bin/nas-notify; ls /root/.nas-manager/ancien/*/; cat /etc/cron.d/nas-backup"));
        assert_eq!(o.code, 0, "migration : {}", o.text());
        assert!(o.stdout.matches("nas-debian\n").count() >= 2, "liens : {}", o.text());
        assert!(o.stdout.contains("nas-backup\n") && o.stdout.contains("nas-notify\n"), "anciens gardes : {}", o.text());
        assert!(o.stdout.contains("root /usr/local/bin/nas-debian run-at 03:30"), "{}", o.text());
        let st: crate::model::OmvStatus = serde_json::from_str(run(true, &OMV_STATUS).stdout.lines().last().unwrap()).expect("json OMV");
        assert!(!st.migration_requise && st.anciens.is_empty());
        // ancienne synchro des cameras reprise comme sauvegarde temps reel « Cameras »
        assert!(!st.cameras.installe, "cam-sync encore en place");
        assert_eq!(st.cam_job, "Cameras");
        let cam = st.temps_reel.iter().find(|j| j.nom == "Cameras").expect("sauvegarde temps reel Cameras");
        assert_eq!((cam.suppression.as_str(), cam.destination.as_str(), cam.anomalie), ("directe", "gcrypt:", 0));
        assert!(cam.dossiers.len() == 1 && cam.dossiers[0].chemin.ends_with("/Cam") && cam.dossiers[0].existe, "{:?}", cam.dossiers);
        assert!(cam.actif, "surveillance des cameras non demarree");
        assert!(run(true, &format!("{DEBIAN_BIN} migrer simulation")).stdout.contains("Rien a migrer"));
        // les anciens noms fonctionnent encore (liens)
        let o = run(true, "/usr/local/bin/nas-backup api-version; /usr/local/bin/nas-backup list");
        assert!(o.stdout.starts_with(&format!("{}\n", nb_api())) && o.stdout.contains("Photos"), "{}", o.text());
        // outils et memoire de rclone
        let o = run(true, &format!("{DEBIAN_BIN} outils etat"));
        let t: crate::install::Tools = serde_json::from_str(o.stdout.trim()).expect("outils");
        assert!(t.python3 && t.rclone.starts_with("1.70"), "{}", o.stdout);
        let o = run(true, &format!("{DEBIAN_BIN} reglages ram econome - - - - && {DEBIAN_BIN} reglages voir"));
        let pf: crate::model::Perf = serde_json::from_str(o.stdout.lines().last().unwrap()).expect("reglages");
        assert_eq!((pf.profil.as_str(), pf.effectif.profil.as_str()), ("econome", "econome"));
        assert!(pf.effectif.options.contains("--transfers 1"));
        assert_ne!(run(true, &format!("{DEBIAN_BIN} reglages ram auto 10")).code, 0, "limite trop basse refusee");
        let o = run(true, &format!("{DEBIAN_BIN} reglages ram auto 300 2 - 0 && {DEBIAN_BIN} reglages voir"));
        let pf: crate::model::Perf = serde_json::from_str(o.stdout.lines().last().unwrap()).expect("reglages");
        assert_eq!(pf.effectif.mo, 300);
        assert!(pf.effectif.options.contains("--transfers 2") && pf.effectif.options.contains("--buffer-size 0"), "{}", pf.effectif.options);
        run(true, &format!("{DEBIAN_BIN} reglages ram auto"));
        let o = run(true, &format!("{NB_BIN} gen-cron && cat /etc/cron.d/nas-backup\n"));
        assert_eq!(o.code, 0, "planification : {}", o.text());
        assert!(o.stdout.contains("run-at 03:30"));
        // nouvelle sauvegarde avec apostrophe et espace dans le chemin
        let d = "/srv/dev-disk-by-uuid-7cd5ac91-9ec8-439c-9de3-c5bf7f5418f5/Film's d'été";
        run(true, &format!("mkdir -p {}\n", sq(d)));
        let f = JobForm { name: "Films", source: d, folder: "Films d'été", mode: "sync", encrypt: false, schedule: "05:10", trash_days: 14, bwlimit: "", memory: "", dests: "", rotation: "", parallel: "" };
        let o = run(true, &nb_save(true, &f));
        assert_eq!(o.code, 0, "{}", o.text());
        let o = run(true, "grep '^Films|' /etc/nas-backup/jobs.conf; cat /etc/cron.d/nas-backup");
        assert!(o.stdout.contains("Films|/srv/dev-disk-by-uuid-7cd5ac91-9ec8-439c-9de3-c5bf7f5418f5/Film's d'été|Films d'été|sync|non|05:10|14|"));
        assert!(o.stdout.contains("run-at 05:10"));
        // doublon refuse
        let o = run(true, &nb_save(true, &f));
        assert_ne!(o.code, 0);
        // modification
        let f2 = JobForm { schedule: "manuel", mode: "copy", ..f };
        let o = run(true, &nb_save(false, &f2));
        assert_eq!(o.code, 0);
        let o = run(true, "grep '^Films|' /etc/nas-backup/jobs.conf");
        assert!(o.stdout.trim().ends_with("|copy|non|manuel|0|||gdrive:non||"), "{}", o.stdout);
        // horaires sur certains jours + limite de debit
        let f4 = JobForm { schedule: "03:30/135;22:15", bwlimit: "08:00,2M 23:00,off", ..f2 };
        let o = run(true, &nb_save(false, &f4));
        assert_eq!(o.code, 0, "{}", o.text());
        let o = run(true, "grep '^Films|' /etc/nas-backup/jobs.conf; cat /etc/cron.d/nas-backup; cat /var/lib/nas-backup/Films.maxage");
        assert!(o.stdout.contains("|03:30/135;22:15|0|08:00,2M 23:00,off"), "{}", o.stdout);
        assert!(o.stdout.contains("15 22 * * * root /usr/local/bin/nas-debian run-at 22:15"), "{}", o.stdout);
        assert!(o.stdout.trim().ends_with("50"));
        // memoire propre a la sauvegarde
        let f5 = JobForm { memory: "econome", ..f4 };
        assert_eq!(run(true, &nb_save(false, &f5)).code, 0);
        let o = run(true, "grep '^Films|' /etc/nas-backup/jobs.conf");
        assert!(o.stdout.trim().ends_with("|08:00,2M 23:00,off|econome|gdrive:non||"), "{}", o.stdout);
        assert_ne!(run(true, &nb_save(false, &JobForm { memory: "12", ..f4 })).code, 0, "memoire invalide refusee");
        // fichiers en parallele propres a la sauvegarde
        let f6 = JobForm { parallel: "6", ..f5 };
        assert_eq!(run(true, &nb_save(false, &f6)).code, 0);
        let o = run(true, "grep '^Films|' /etc/nas-backup/jobs.conf");
        assert!(o.stdout.trim().ends_with("|econome|gdrive:non||6"), "{}", o.stdout);
        let st: crate::model::OmvStatus = serde_json::from_str(run(true, &OMV_STATUS).stdout.lines().last().unwrap()).expect("json OMV");
        assert_eq!(st.sauvegardes.iter().find(|j| j.nom == "Films").map(|j| j.paralleles.as_str()), Some("6"));
        for bad in ["0", "33", "4x"] {
            assert_ne!(run(true, &nb_save(false, &JobForm { parallel: bad, ..f6 })).code, 0, "fichiers en parallele {bad} acceptes");
        }
        // horaire invalide
        let f3 = JobForm { schedule: "25:00", ..f2 };
        assert_ne!(run(true, &nb_save(false, &f3)).code, 0);
        // suppression
        let o = run(true, &nb_delete("Films", false));
        assert_eq!(o.code, 0, "suppression : {}", o.text());
        assert!(!run(true, "cat /etc/nas-backup/jobs.conf").stdout.contains("Films|"));
        // acquittement / mots de passe
        assert_eq!(run(true, &ack_alert("job-Documents; rm -rf /")).code, 0);
        run(true, &show_passwords());
        run(true, &tail_file("/var/log/cam-sync.log", 3));
        // execution reelle (faux rclone) : historique + verrou libere des la fin
        let o = run(true, &format!("n=$(wc -l < /var/lib/nas-backup/historique.jsonl 2>/dev/null || echo 0)\nFAKE_DUR=2 {NB_BIN} run Musique >/dev/null 2>&1\nflock -n /run/nas-backup-Musique.lock true && echo LIBRE\necho $(( $(wc -l < /var/lib/nas-backup/historique.jsonl) - n ))\ntail -n 1 /var/lib/nas-backup/historique.jsonl\n"));
        assert!(o.stdout.contains("LIBRE"), "verrou encore tenu : {}", o.text());
        assert!(o.stdout.lines().nth(1) == Some("1"), "historique : {}", o.text());
        assert!(o.stdout.contains("\"nom\": \"Musique\"") && o.stdout.contains("\"etat\": \"OK\""));
        let o = run(true, OMV_HISTORY);
        let h: crate::model::History = serde_json::from_str(o.stdout.lines().last().unwrap()).expect("json historique");
        assert!(h.executions.iter().any(|r| r.nom == "Musique"));
        // simulation : bilan lu par la collecte
        let o = run(true, &format!("{NB_BIN} simulate Musique 2>&1; cat /var/lib/nas-backup/Musique.simulation.status; cat /var/lib/nas-backup/Musique.simulation.txt"));
        assert!(o.stdout.contains("ETAT=ok") && o.stdout.contains("ENVOIS=2") && o.stdout.contains("SUPPRESSIONS=1"), "{}", o.text());
        assert!(o.stdout.contains("+ 2024/IMG_2.jpg") && o.stdout.contains("- vieux.txt"));
        // arret d'une seule sauvegarde : etat ARRETE (pas ECHEC)
        run(true, &format!("FAKE_DUR=40 nohup setsid {NB_BIN} run Musique >/dev/null 2>&1 </dev/null &\nsleep 3"));
        let o = run(true, &format!("{NB_BIN} stop Musique 2>&1; cat /var/lib/nas-backup/Musique.status"));
        assert!(o.stdout.contains("ARRETE"), "{}", o.text());
        // parcours du Drive (dechiffre) et chemin interdit
        let o = run(true, &nb_ls("Photos", "2024", false, 0));
        assert!(o.stdout.contains("IMG_2.jpg"), "{}", o.text());
        assert_ne!(run(true, &nb_ls("Photos", "../../etc", false, 0)).code, 0);
        let o = run(true, &nb_ls("Photos", "", true, 0));
        assert!(o.stdout.contains("2026-10-15_0330"));
        // restauration d'un fichier de la corbeille (en arriere-plan) puis etat
        run(true, &nb_restore("Photos", "/tmp/restau-test", "2026-10-15_0330/ancien.txt", true, 0));
        let o = run(true, "for i in $(seq 40); do grep -q 'ETAT=en_cours' /var/lib/nas-backup/restauration.status || break; sleep 1; done; cat /var/lib/nas-backup/restauration.status");
        assert!(o.stdout.contains("ETAT=ok"), "{}", o.text());
        // verification d'integrite et planification
        let o = run(true, &format!("{NB_BIN} verifier Photos 2>&1; cat /var/lib/nas-backup/Photos.verif.status"));
        assert!(o.stdout.contains("ETAT=ecarts") && o.stdout.contains("MANQUANTS=1") && o.stdout.contains("IDENTIQUES=3"), "{}", o.text());
        let o = run(true, &(nb_verify_plan("67", "04:45") + "cat /etc/cron.d/nas-backup /etc/nas-backup/verification\n"));
        assert!(o.stdout.contains("45 4 * * 6,0 root /usr/local/bin/nas-debian verifier-tout"), "{}", o.text());
        let o = run(true, &(nb_verify_plan("", "") + "cat /etc/cron.d/nas-backup\n"));
        assert!(!o.stdout.contains("verifier-tout"));
        // collecte de l'etat : JSON valide et coherent
        let o = run(true, &OMV_STATUS);
        let st: crate::model::OmvStatus = serde_json::from_str(o.stdout.lines().last().unwrap()).expect("json OMV");
        assert!(st.erreur.is_none());
        assert_eq!(st.nb_api, nb_api());
        assert!(st.sauvegardes.iter().any(|j| j.nom == "Photos" && j.dernier_etat.as_deref() == Some("OK")));
        let v = st.sauvegardes.iter().find(|j| j.nom == "Photos").and_then(|j| j.verification.clone()).expect("verification");
        assert_eq!((v.etat.as_str(), v.identiques, v.manquants), ("ecarts", 3, 1));
        let sim = st.sauvegardes.iter().find(|j| j.nom == "Musique").and_then(|j| j.simulation.clone()).expect("simulation");
        assert_eq!((sim.envois, sim.suppressions), (2, 1));
        assert!(sim.octets > 1_000_000_000);
        destinations_live();
        temps_reel_live();
    }

    /// Destinations, sauvegardes vers plusieurs destinations, versions, kit de secours : configuration
    /// et collecte (faux rclone ; le moteur lui-meme est teste avec les vrais rclone et restic, voir
    /// tests/destinations.sh)
    fn destinations_live() {
        let o = run(true, &format!("{DEBIAN_BIN} destinations liste"));
        let ds: Vec<crate::model::Destination> = serde_json::from_str(o.stdout.trim()).expect("destinations");
        assert!(ds.iter().any(|d| d.nom == "gdrive" && d.kind == "drive" && d.chiffre_pret), "{ds:?}");
        assert!(ds.iter().any(|d| d.nom == "usb" && d.kind == "local" && d.cible.ends_with("/Sauvegardes")), "{ds:?}");
        assert!(!ds.iter().any(|d| d.nom == "gbackup" || d.nom == "gcrypt"), "remotes chiffres caches : {ds:?}");
        let src = "/srv/dev-disk-by-uuid-7cd5ac91-9ec8-439c-9de3-c5bf7f5418f5/Documents";
        let f = JobForm { name: "Multi", source: src, folder: "Multi", mode: "sync", encrypt: true, schedule: "manuel", trash_days: 7, bwlimit: "", memory: "", dests: "gdrive:oui;usb:non", rotation: "", parallel: "" };
        let o = run(true, &nb_save(true, &f));
        assert_eq!(o.code, 0, "{}", o.text());
        assert!(run(true, "grep '^Multi|' /etc/nas-backup/jobs.conf").stdout.trim().ends_with("|gdrive:oui;usb:non||"));
        assert_ne!(run(true, &nb_save(false, &JobForm { dests: "nulle:oui", ..f })).code, 0, "destination inconnue refusee");
        assert_ne!(run(true, &nb_save(false, &JobForm { dests: "gcrypt:oui", ..f })).code, 0, "remote chiffre refuse");
        let v = JobForm { name: "Vers", folder: "Vers", mode: "versions", encrypt: false, dests: "usb:non", rotation: "7:4:12:0", trash_days: 9, ..f };
        assert_eq!(run(true, &nb_save(true, &v)).code, 0);
        let o = run(true, "grep '^Vers|' /etc/nas-backup/jobs.conf; cat /etc/cron.d/nas-backup");
        assert!(o.stdout.contains("|versions|oui|manuel|0|||usb:oui|7:4:12:0"), "{}", o.stdout);
        assert!(o.stdout.contains("versions entretien") && o.stdout.contains("secours sauvegarder"), "{}", o.stdout);
        assert_ne!(run(true, &nb_save(false, &JobForm { rotation: "0:0:0:0", ..v })).code, 0, "rotation vide refusee");
        // collecte
        let st: crate::model::OmvStatus = serde_json::from_str(run(true, &OMV_STATUS).stdout.lines().last().unwrap()).expect("json OMV");
        assert!(st.destinations.len() >= 2);
        let m = st.sauvegardes.iter().find(|j| j.nom == "Multi").expect("Multi");
        assert_eq!(m.dests(), vec![crate::model::JobDest { nom: "gdrive".into(), chiffre: true }, crate::model::JobDest { nom: "usb".into(), chiffre: false }]);
        let vj = st.sauvegardes.iter().find(|j| j.nom == "Vers").expect("Vers");
        assert!(vj.versions() && vj.rotation == "7:4:12:0");
        let p = st.sauvegardes.iter().find(|j| j.nom == "Photos").expect("Photos");
        assert_eq!(p.dests(), vec![crate::model::JobDest { nom: "gdrive".into(), chiffre: true }], "ancienne ligne : Google Drive");
        assert!(st.secours.is_some(), "etat du kit de secours");
        // destination utilisee : suppression refusee
        let o = run(true, &dest_delete("usb"));
        assert!(o.code != 0 && o.text().contains("Multi"), "{}", o.text());
        assert_eq!(run(true, &nb_delete("Multi", false)).code, 0);
        assert_eq!(run(true, &nb_delete("Vers", false)).code, 0);
        // nouvelle destination : nom et type controles
        assert_ne!(run(true, &dest_create("a-b", "local", &[("chemin".into(), "/tmp".into())])).code, 0);
        assert_ne!(run(true, &dest_create("od", "onedrive", &[])).code, 0);
        assert_ne!(run(true, &dest_token("od", "onedrive", "pas un jeton")).code, 0);
        // mots de passe : la commande du script repond
        assert_eq!(run(true, &show_passwords()).code, 0);
    }

    /// Sauvegardes temps reel sur le faux OMV (faux rclone : seules la configuration et l'etat sont verifies ;
    /// le moteur lui-meme est teste avec le vrai rclone, voir tests/temps-reel.sh)
    fn temps_reel_live() {
        let d = "/srv/dev-disk-by-uuid-7cd5ac91-9ec8-439c-9de3-c5bf7f5418f5";
        let dirs = format!("{d}/Documents;{d}/Photos");
        let f = RtSave { name: "Bureau", dirs: &dirs, dest: "gbackup:Bureau", deletion: "corbeille", trash_days: 30, excl: "cache;*.bak", types: "", delay: 10, catchup: 15, anomaly: 200, memory: "", bwlimit: "", parallel: "" };
        let o = run(true, &rt_save(true, &f));
        assert_eq!(o.code, 0, "creation : {}", o.text());
        assert!(run(true, "cat /etc/cron.d/nas-temps-reel").stdout.contains("*/15 * * * * root /usr/local/bin/nas-debian temps-reel rattrapage Bureau"));
        // refus : doublon, dossier absent, corbeille sans jours, rattrapage non prevu, nom invalide
        assert_ne!(run(true, &rt_save(true, &f)).code, 0, "doublon accepte");
        assert_ne!(run(true, &rt_save(false, &RtSave { dirs: "/nulle/part", ..f })).code, 0);
        assert_ne!(run(true, &rt_save(false, &RtSave { trash_days: 0, ..f })).code, 0);
        assert_ne!(run(true, &rt_save(false, &RtSave { catchup: 7, ..f })).code, 0);
        assert_ne!(run(true, &rt_save(true, &RtSave { name: "a b; rm", ..f })).code, 0);
        let st: crate::model::OmvStatus = serde_json::from_str(run(true, &OMV_STATUS).stdout.lines().last().unwrap()).expect("json OMV");
        let j = st.temps_reel.iter().find(|j| j.nom == "Bureau").expect("Bureau");
        assert_eq!(j.dossiers.len(), 2);
        assert_eq!((j.suppression.as_str(), j.corbeille, j.anomalie, j.exclusions.as_str()), ("corbeille", 30, 200, "cache;*.bak"));
        assert!(j.chiffre && j.actif && j.pause.is_none(), "{j:?}");
        // pause manuelle puis reprise
        assert_eq!(run(true, &rt_cmd("pause", "Bureau")).code, 0);
        let st: crate::model::OmvStatus = serde_json::from_str(run(true, &OMV_STATUS).stdout.lines().last().unwrap()).expect("json OMV");
        let j = st.temps_reel.iter().find(|j| j.nom == "Bureau").unwrap();
        assert!(j.pause.as_ref().map(|p| p.raison.contains("manuelle")).unwrap_or(false), "{j:?}");
        assert!(run(true, &format!("{NB_BIN} temps-reel rattrapage Bureau")).stdout.contains("en pause"));
        assert_eq!(run(true, &rt_cmd("reprendre", "Bureau")).code, 0);
        assert!(run(true, "ls /var/lib/nas-backup/").stdout.contains("rt-Bureau.reprise"));
        // modification d'une sauvegarde qui n'est pas la derniere de la liste : c'est bien elle qui change
        let f2 = RtSave { name: "Cameras", dirs: &format!("{d}/Cam"), dest: "gcrypt:", deletion: "directe", trash_days: 0, excl: "", types: "*.mp4", delay: 5, catchup: 15, anomaly: 0, memory: "econome", bwlimit: "", parallel: "3" };
        let o = run(true, &rt_save(false, &f2));
        assert_eq!(o.code, 0, "modification : {}", o.text());
        assert!(o.stdout.contains("« Cameras »") && !o.stdout.contains("« Bureau »"), "{}", o.text());
        let o = run(true, "grep -v '^#' /etc/nas-backup/temps-reel.conf");
        assert!(o.stdout.contains("Cameras|") && o.stdout.contains("|*.mp4|5|15|0|econome||3"), "{}", o.stdout);
        let st: crate::model::OmvStatus = serde_json::from_str(run(true, &OMV_STATUS).stdout.lines().last().unwrap()).expect("json OMV");
        assert_eq!(st.temps_reel.iter().find(|j| j.nom == "Cameras").map(|j| j.paralleles.as_str()), Some("3"));
        assert_ne!(run(true, &rt_save(false, &RtSave { parallel: "0", ..f2 })).code, 0, "0 fichier en parallele accepte");
        assert!(o.stdout.contains("Bureau|"), "{}", o.stdout);
        // arret / demarrage
        assert_eq!(run(true, &rt_cmd("arreter", "Bureau")).code, 0);
        let st: crate::model::OmvStatus = serde_json::from_str(run(true, &OMV_STATUS).stdout.lines().last().unwrap()).expect("json OMV");
        assert!(!st.temps_reel.iter().find(|j| j.nom == "Bureau").unwrap().actif);
        // suppression (sans effacer la destination)
        let o = run(true, &rt_delete("Bureau", false));
        assert_eq!(o.code, 0, "suppression : {}", o.text());
        let o = run(true, "grep -v '^#' /etc/nas-backup/temps-reel.conf; cat /etc/cron.d/nas-temps-reel");
        assert!(!o.stdout.contains("Bureau") && o.stdout.contains("Cameras"), "{}", o.stdout);
    }

    /// Sante des disques (faux smartctl), canaux de notification, rapport : collecte et commandes
    #[test]
    fn sante_disques_live() {
        if !on() {
            return;
        }
        assert_eq!(run(true, &install_file(DEBIAN_BIN, NAS_DEBIAN_SH)).code, 0);
        let o = run(true, &disks_check(false));
        assert_eq!(o.code, 0, "{}", o.text());
        let st: crate::model::OmvStatus = serde_json::from_str(run(true, &OMV_STATUS).stdout.lines().last().unwrap()).expect("json OMV");
        let h = st.sante_disques.expect("sante des disques");
        assert!(h.smart && h.disques.len() == 3, "{h:?}");
        assert_eq!(h.problems(), (0, 1), "sdb a surveiller");
        let n = st.notif.expect("canaux");
        assert_eq!(n.rapport.frequence, "non");
        // canaux : adresse invalide refusee, seuils, rapport
        assert_ne!(run(true, &canal_set("discord", "tout", &[("url", "https://exemple.fr/x".into())])).code, 0);
        assert_ne!(run(true, &canal_set("pigeon", "tout", &[])).code, 0);
        assert_ne!(run(true, &telegram_chats("pas-un-jeton")).code, 0);
        assert_eq!(run(true, &alert_thresholds(8, 85, 40)).code, 0);
        let o = run(true, &report_view("mensuel"));
        assert!(o.code == 0 && o.stdout.to_lowercase().contains("rapport"), "{}", o.text());
        assert_eq!(run(true, &report_plan("hebdo", 7, "09:05", &[])).code, 0);
        assert!(run(true, "cat /etc/cron.d/nas-backup").stdout.contains("5 9 * * 0 root /usr/local/bin/nas-debian rapport envoyer hebdo"));
        let st: crate::model::OmvStatus = serde_json::from_str(run(true, &OMV_STATUS).stdout.lines().last().unwrap()).expect("json OMV");
        let n = st.notif.unwrap();
        assert!(n.rappel_h == 8 && n.quota_pct == 85 && n.retard_h == 40 && n.rapport.jour == 7, "{n:?}");
        assert_eq!(run(true, &report_plan("non", 1, "08:30", &[])).code, 0);
        assert_eq!(run(true, &alert_thresholds(12, 90, 50)).code, 0);
        // Synology : verification, alerte, acquittement
        assert_eq!(run(false, &install_file(SYNO_BIN, NAS_SYNOLOGY_SH)).code, 0);
        assert_eq!(run(false, &format!("echo 2 > /tmp/faux-nas/smart-sdb-en-attente; {}", disks_check(true))).code, 0);
        let sy: crate::model::SynoStatus = serde_json::from_str(run(false, &SYNO_STATUS).stdout.lines().last().unwrap()).expect("json Synology");
        let h = sy.sante_disques.expect("sante des disques Synology");
        assert_eq!(h.problems(), (1, 0), "{h:?}");
        assert!(sy.alertes.iter().any(|a| a.tag == "disque-ZDH0USE2"), "{:?}", sy.alertes);
        assert_eq!(run(false, &ack_alert_syno("disque-ZDH0USE2")).code, 0);
        assert_eq!(run(false, &format!("rm -f /tmp/faux-nas/smart-sdb-en-attente; {}", disks_check(true))).code, 0);
        let sy: crate::model::SynoStatus = serde_json::from_str(run(false, &SYNO_STATUS).stdout.lines().last().unwrap()).expect("json Synology");
        assert!(sy.alertes.is_empty(), "{:?}", sy.alertes);
    }

    /// Etape 5 : test de restauration, retour a une date, reveil (configuration et collecte ;
    /// le moteur est teste avec les vrais rclone et restic, voir tests/restauration.sh)
    #[test]
    fn fiabilite_live() {
        if !on() {
            return;
        }
        assert_eq!(run(true, &install_file(DEBIAN_BIN, NAS_DEBIAN_SH)).code, 0);
        let o = run(true, &(test_plan("6", "06:15", 4) + "cat /etc/cron.d/nas-backup\n"));
        assert!(o.stdout.contains("15 6 * * 6 root /usr/local/bin/nas-debian test-restauration tout"), "{}", o.text());
        assert_ne!(run(true, &test_plan("9", "06:15", 4)).code, 0, "jours invalides refuses");
        assert_ne!(run(true, &test_plan("6", "25:00", 4)).code, 0, "heure invalide refusee");
        // resultat d'un test et reveil d'une destination : lus par la collecte
        run(true, r#"printf '%s' '{"debut":1,"fin":2,"etat":"ecarts","nb":3,"identiques":5,"ecarts":1,"erreurs":0,"destinations":"gdrive:ecarts","message":"","fichiers":[{"destination":"gdrive","chemin":"a.jpg","taille":12,"resultat":"different","detail":"x"}]}' > /var/lib/nas-backup/Photos.test.json"#);
        let o = run(true, &reveil_set("usb", "00:11:22:aa:bb:cc", "127.0.0.1", 60, "rien", ""));
        assert_eq!(o.code, 0, "{}", o.text());
        assert_ne!(run(true, &reveil_set("usb", "00:11", "", 60, "rien", "")).code, 0, "MAC invalide refusee");
        assert_ne!(run(true, &reveil_set("usb", "00:11:22:aa:bb:cc", "127.0.0.1", 60, "veille", "")).code, 0, "compte SSH requis");
        let st: crate::model::OmvStatus = serde_json::from_str(run(true, &OMV_STATUS).stdout.lines().last().unwrap()).expect("json OMV");
        assert_eq!(st.test_auto, "6 06:15 4");
        let p = st.sauvegardes.iter().find(|j| j.nom == "Photos").expect("Photos");
        let t = p.test.as_ref().expect("test");
        assert!(t.etat == "ecarts" && t.fichiers.len() == 1 && !p.test_en_cours, "{t:?}");
        let rv = st.reveil.expect("reveil");
        assert_eq!(rv.destinations.get("usb").map(|d| (d.mac.as_str(), d.attente)), Some(("00:11:22:AA:BB:CC", 60)));
        // retour a une date : plage et refus (le faux rclone ne permet pas plus)
        let o = run(true, &date_range("Photos", 0));
        let g: crate::restore::DateRange = serde_json::from_str(o.stdout.lines().last().unwrap_or("")).expect("plage");
        assert_eq!(g.methode, "corbeille");
        let o = run(true, &date_range("Documents", 0));
        assert!(o.stdout.contains("\"aucune\""), "{}", o.text());
        assert_ne!(run(true, &date_preview("Documents", 0, 1_700_000_000, "")).code, 0, "copie : pas de retour a une date");
        assert_ne!(run(true, &date_preview("Photos", 0, 1_700_000_000, "../x")).code, 0, "chemin interdit");
        // adresse MAC de la machine
        let o = run(true, &detect_mac());
        assert!(crate::wol::valid_mac(o.stdout.lines().next().unwrap_or("")), "{}", o.text());
        // nettoyage
        assert_eq!(run(true, &(test_plan("", "", 5) + &reveil_remove("usb") + "rm -f /var/lib/nas-backup/Photos.test.json\n")).code, 0);
        // Synology : reveil de l'OMV avant les copies (reglages remis en etat a la fin)
        assert_eq!(run(false, &install_file(SYNO_BIN, NAS_SYNOLOGY_SH)).code, 0);
        run(false, "rm -f /tmp/syno-config.sauve; [ -f /root/.nas-synology/config ] && cp -p /root/.nas-synology/config /tmp/syno-config.sauve; true");
        let o = run(false, &(syno_omv_wake("00:11:22:33:44:55", "veille") + &format!("{SYNO_BIN} reglages voir\n")));
        assert!(o.stdout.contains("\"omv_mac\":\"00:11:22:33:44:55\"") && o.stdout.contains("\"omv_apres\":\"veille\""), "{}", o.text());
        assert_ne!(run(false, &syno_omv_wake("zz", "rien")).code, 0);
        let sy: crate::model::SynoStatus = serde_json::from_str(run(false, &SYNO_STATUS).stdout.lines().last().unwrap()).expect("json Synology");
        assert_eq!(sy.perf.map(|p| p.omv_apres), Some("veille".to_string()));
        assert_eq!(run(false, &syno_omv_wake("", "rien")).code, 0);
        run(false, "if [ -f /tmp/syno-config.sauve ]; then mv -f /tmp/syno-config.sauve /root/.nas-synology/config; else rm -f /root/.nas-synology/config; fi");
    }

    /// Etape 6 : connexion oCIS, espaces et transferts par les commandes de l'application,
    /// lus par la collecte (faux oCIS sur le port 9251 ; etat remis en place a la fin)
    #[test]
    fn ocis_live() {
        if !on() || !std::path::Path::new("/usr/bin/rclone").exists() {
            return;
        }
        use crate::app::HostId;
        let py = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/faux-ocis.py");
        let mut srv = std::process::Command::new("python3")
            .args([py, "9251", "/tmp/ocis-live/espaces", "/usr/bin/rclone", "alice", "secret"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("faux oCIS");
        std::thread::sleep(Duration::from_secs(2));
        assert_eq!(run(true, &install_file(DEBIAN_BIN, NAS_DEBIAN_SH)).code, 0);
        assert_eq!(run(false, &install_file(SYNO_BIN, NAS_SYNOLOGY_SH)).code, 0);
        let save = "rm -rf /tmp/ocis-live/avant; mkdir -p /tmp/ocis-live/avant /tmp/ocis-live/dest; for d in /root/.migre-ocis /root/.ocis-transferts; do [ -d $d ] && mv $d /tmp/ocis-live/avant/; done; cp -p /etc/crontab /tmp/ocis-live/avant/crontab 2>/dev/null; true";
        run(true, save);
        let res = std::panic::catch_unwind(|| {
            let o = run(true, &migre_configure(HostId::Omv, "http://127.0.0.1:9251", "alice", "secret", "", false));
            assert_eq!(o.code, 0, "{}", o.text());
            let sp = crate::model::parse_spaces(&run(true, &tr_spaces(HostId::Omv)).stdout);
            assert_eq!(sp.iter().map(|s| (s.id.as_str(), s.kind.as_str())).collect::<Vec<_>>(), vec![("personnel-alice", "personal"), ("projet-docs", "project"), ("projet-photos", "project")]);
            assert_eq!(crate::model::parse_spaces(&run(true, &migre_spaces(HostId::Omv)).stdout).len(), 2, "migration : espaces projets");
            let f = TrSave { name: "Photos-oCIS", space: "projet-photos", sub: "", dest: "/tmp/ocis-live/dest/photos", mode: "miroir", trash_days: 7, schedule: "03:10/12345", bwlimit: "" };
            let o = run(true, &tr_save(HostId::Omv, true, &f));
            assert_eq!(o.code, 0, "{}", o.text());
            assert_ne!(run(true, &tr_save(HostId::Omv, true, &f)).code, 0, "nom deja pris");
            assert_ne!(run(true, &tr_save(HostId::Omv, true, &TrSave { name: "x", space: "inconnu", ..f })).code, 0, "espace inconnu");
            assert_ne!(run(true, &tr_save(HostId::Omv, true, &TrSave { name: "y", dest: "/", ..f })).code, 0, "destination refusee");
            let o = run(true, "cat /etc/cron.d/ocis-transferts");
            assert!(o.stdout.contains("10 3 * * ") && o.stdout.contains("root /usr/local/bin/nas-debian transferts run-at"), "{}", o.text());
            let st: crate::model::OmvStatus = serde_json::from_str(run(true, &OMV_STATUS).stdout.lines().last().unwrap()).expect("json OMV");
            assert!(st.migration.as_ref().map(|m| m.config.is_some()).unwrap_or(false), "{:?}", st.migration);
            let t = st.transferts.expect("transferts");
            assert!(t.config && t.en_cours.is_none());
            let x = &t.transferts[0];
            assert_eq!((x.nom.as_str(), x.espace.as_str(), x.mode.as_str(), x.corbeille, x.horaire.as_str()), ("Photos-oCIS", "Photos", "miroir", 7, "03:10/12345"));
            let o = run(true, &tr_delete(HostId::Omv, "Photos-oCIS"));
            assert_eq!(o.code, 0, "{}", o.text());
            // Synology : meme moteur, planification dans /etc/crontab
            let o = run(false, &migre_configure(HostId::Syno, "http://127.0.0.1:9251", "alice", "secret", "", false));
            assert_eq!(o.code, 0, "{}", o.text());
            let o = run(false, &tr_save(HostId::Syno, true, &TrSave { name: "Docs", space: "projet-docs", sub: "", dest: "/tmp/ocis-live/dest/docs", mode: "copie", trash_days: 0, schedule: "manuel", bwlimit: "2M" }));
            assert_eq!(o.code, 0, "{}", o.text());
            let sy: crate::model::SynoStatus = serde_json::from_str(run(false, &SYNO_STATUS).stdout.lines().last().unwrap()).expect("json Synology");
            let t = sy.transferts.expect("transferts Synology");
            assert_eq!(t.transferts.iter().map(|x| (x.nom.as_str(), x.debit.as_str())).collect::<Vec<_>>(), vec![("Docs", "2M")]);
            assert_eq!(run(false, &tr_delete(HostId::Syno, "Docs")).code, 0);
        });
        run(true, "rm -rf /root/.migre-ocis /root/.ocis-transferts /etc/cron.d/ocis-transferts; for d in /tmp/ocis-live/avant/.migre-ocis /tmp/ocis-live/avant/.ocis-transferts; do [ -d $d ] && mv $d /root/; done; [ -f /tmp/ocis-live/avant/crontab ] && cp -p /tmp/ocis-live/avant/crontab /etc/crontab; true");
        let _ = srv.kill();
        let _ = srv.wait();
        if let Err(e) = res {
            std::panic::resume_unwind(e);
        }
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
        let o = run(false, &(install_file(SYNO_BIN, NAS_SYNOLOGY_SH) + &format!("{SYNO_BIN} installer\n")));
        assert_eq!(o.code, 0, "{}", o.text());
        let st: crate::model::SynoStatus = serde_json::from_str(run(false, &SYNO_STATUS).stdout.lines().last().unwrap()).expect("json Synology");
        assert!(st.migration_requise, "{:?}", st.anciens);
        // migration : adresse de l'OMV reprise de l'ancien copie-omv
        let o = run(false, &format!("{SYNO_BIN} migrer appliquer 2>&1; readlink /usr/local/bin/copie-omv /usr/local/bin/migre-drive-ocis; {SYNO_BIN} reglages voir"));
        assert_eq!(o.code, 0, "{}", o.text());
        assert!(o.stdout.matches("nas-synology\n").count() == 2, "{}", o.text());
        assert!(o.stdout.contains("\"omv\":\"127.0.0.1\""), "{}", o.text());
        let o = run(false, &format!("{COPIE_BIN} api-version; {MIGRE_BIN} api-version; /usr/local/bin/migre-drive-ocis api-version; {MIGRE_BIN} sources; {SYNO_BIN} version"));
        assert!(o.stdout.starts_with(&format!("{0}\n{0}\n{0}\n", copie_api())), "{}", o.text());
        assert!(o.stdout.contains("/volume1/homes/alice/Drive|alice"));
        assert!(o.stdout.contains("\"script\":\"nas-synology\""));
        let o = run(false, &format!("{SYNO_BIN} outils etat; {SYNO_BIN} reglages ram econome && {SYNO_BIN} reglages voir && {SYNO_BIN} reglages ram auto"));
        let t: crate::install::Tools = serde_json::from_str(o.stdout.lines().next().unwrap()).expect("outils");
        assert!(t.rsync && t.cle_omv);
        assert!(o.stdout.contains("\"profil\":\"econome\""), "{}", o.text());
        run(false, &syno_list_dirs(""));
        run(false, &syno_size("/volume1/photo"));
        run(false, &migre_remove(HostId::Syno, 9));
        // file d'attente de copies : deux copies l'une apres l'autre (vrai rsync vers « l'OMV »)
        let d = "/srv/dev-disk-by-uuid-7cd5ac91-9ec8-439c-9de3-c5bf7f5418f5/Archives";
        let o = run(false, &format!(
            "rm -rf {d}; mkdir -p {d} /volume1/photo/2023 /volume4/utils/archives; echo x > /volume4/utils/archives/a.txt\n: > /root/.copie-omv/file-attente; : > /root/.copie-omv/historique.log\n{}{}{}",
            copie_queue_add("/volume1/photo", d, true, false, Some(50000)),
            copie_queue_add("/volume4/utils/archives", d, false, false, None),
            copie_queue_next()
        ));
        assert_eq!(o.code, 0, "{}", o.text());
        let o = run(false, &format!("for i in $(seq 60); do [ $(grep -c OK /root/.copie-omv/historique.log 2>/dev/null || echo 0) -ge 2 ] && break; sleep 1; done; cat /root/.copie-omv/historique.log; ls {d} {d}/photo"));
        assert!(o.stdout.matches("| OK |").count() >= 2, "{}", o.text());
        assert!(o.stdout.contains("a.txt") && o.stdout.contains("2023"), "{}", o.text());
        let o = run(false, &SYNO_STATUS);
        let st: crate::model::SynoStatus = serde_json::from_str(o.stdout.lines().last().unwrap()).expect("json Synology");
        assert!(st.erreur.is_none());
        assert!(st.copie.installe && st.migration.installe);
        assert_eq!(st.migration.config.map(|c| c.utilisateur), Some("migration".to_string()));
    }
}

#[cfg(all(test, not(nas_manager_tui)))]
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
