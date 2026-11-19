#!/usr/bin/env python3
"""Met a jour versions-scripts.json (version et empreinte SHA-256 de chaque script).

A lancer apres chaque modification de nas-debian.sh, nas-synology.sh ou d'un fichier
de commun/ :
    python3 maj-versions-scripts.py
1. Recopie le code partage (commun/*.sh) dans les scripts qui l'utilisent, entre les
   lignes « # >>> commun/<fichier> » et « # <<< commun/<fichier> » : un script reste un
   fichier unique sur la machine. Ce code se modifie dans commun/, jamais dans les scripts.
2. Met a jour la version et l'empreinte de chaque script.
3. Signe le JSON (versions-scripts.json.sig, ed25519, via openssl) avec la cle privee
   gardee hors de GitHub ($NAS_SIGNATURE_CLE, par defaut
   ~/.config/scripts_claude/signature-ed25519.pem). Sans cette cle, le JSON est mis a
   jour mais pas signe : NAS Manager refusera la liste tant qu'elle n'est pas signee.
Les nouveautes (champ « nouveautes ») s'editent a la main dans le JSON.
NAS Manager lit ce fichier sur GitHub pour proposer la mise a jour des scripts ;
un test de l'application verifie qu'il correspond aux scripts integres.
--verifier : ne modifie rien, echoue si un script, le JSON ou sa signature n'est pas a jour.
"""
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

ICI = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = {"nas-debian": "nas-debian.sh", "nas-synology": "nas-synology.sh"}
MANIFESTE = os.path.join(ICI, "versions-scripts.json")
SIGNATURE = MANIFESTE + ".sig"
CLE_PUBLIQUE = os.path.join(ICI, "signature", "cle-publique.pem")
CLE_PRIVEE = os.environ.get("NAS_SIGNATURE_CLE") or os.path.expanduser("~/.config/scripts_claude/signature-ed25519.pem")
# code partage : fichier de commun/ -> scripts qui l'incluent
COMMUN = {"commun/ocis.sh": ["nas-debian.sh", "nas-synology.sh"], "commun/tui.sh": ["nas-debian.sh", "nas-synology.sh"]}


def synchroniser(verifier):
    """Recopie commun/* dans les scripts ; renvoie True si un script n'etait pas a jour."""
    ecart = False
    for mod, scripts in COMMUN.items():
        with open(os.path.join(ICI, mod), encoding="utf-8") as f:
            bloc = f.read()
        if not bloc.endswith("\n"):
            bloc += "\n"
        debut, fin = "# >>> %s" % mod, "# <<< %s" % mod
        for sc in scripts:
            chemin = os.path.join(ICI, sc)
            with open(chemin, encoding="utf-8") as f:
                s = f.read()
            i, j = s.find(debut), s.find(fin)
            if i < 0 or j < i:
                sys.exit(f"{sc} : marqueurs « {debut} » / « {fin} » introuvables")
            k = s.index("\n", i) + 1          # apres la ligne de debut (commentaire garde)
            nouveau = s[:k] + bloc + s[j:]
            if nouveau != s:
                ecart = True
                if verifier:
                    print(f"{sc} : le code de {mod} n'est pas a jour (lancer python3 maj-versions-scripts.py)")
                else:
                    with open(chemin, "w", encoding="utf-8") as f:
                        f.write(nouveau)
                    print(f"{sc} : {mod} recopie")
    return ecart


def contenu(fichier):
    # fins de ligne Unix, comme a l'installation sur le NAS
    with open(os.path.join(ICI, fichier), "rb") as f:
        return f.read().replace(b"\r\n", b"\n")


def openssl(args, entree):
    """openssl pkeyutl sur <entree> (octets) ; renvoie (code, sortie)"""
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, "message")
        with open(f, "wb") as h:
            h.write(entree)
        try:
            p = subprocess.run(["openssl", "pkeyutl", "-rawin", "-in", f] + args, capture_output=True)
        except OSError:
            return 127, b""
        return p.returncode, p.stdout


def signature_valide():
    """True si versions-scripts.json.sig signe bien le JSON (fins de ligne Unix)"""
    try:
        sig = open(SIGNATURE, "rb").read().strip()
        brute = base64.b64decode(sig, validate=True)
    except (OSError, ValueError):
        return False
    with tempfile.TemporaryDirectory() as d:
        fs = os.path.join(d, "sig")
        with open(fs, "wb") as h:
            h.write(brute)
        code, _ = openssl(["-verify", "-pubin", "-inkey", CLE_PUBLIQUE, "-sigfile", fs], contenu(MANIFESTE))
    return code == 0


def signer():
    """Signe le JSON ; False si la cle privee ou openssl manque"""
    if not os.path.isfile(CLE_PRIVEE):
        print(f"cle privee absente ({CLE_PRIVEE}) : versions-scripts.json n'est PAS signe.")
        return False
    code, sig = openssl(["-sign", "-inkey", CLE_PRIVEE], contenu(MANIFESTE))
    if code != 0 or len(sig) != 64:
        print("signature impossible (openssl 1.1.1 ou plus recent necessaire).")
        return False
    with open(SIGNATURE, "w", encoding="ascii", newline="\n") as f:
        f.write(base64.b64encode(sig).decode() + "\n")
    if not signature_valide():
        print("la cle privee ne correspond pas a signature/cle-publique.pem.")
        return False
    print("versions-scripts.json signe.")
    return True


def main():
    try:
        with open(MANIFESTE, encoding="utf-8") as f:
            man = json.load(f)
    except (OSError, ValueError):
        man = {}
    verifier = "--verifier" in sys.argv
    ecart = synchroniser(verifier)
    for nom, fichier in SCRIPTS.items():
        data = contenu(fichier)
        m = re.search(rb'^SCRIPT_VERSION="([^"]+)"', data, re.M)
        if not m:
            sys.exit(f"{fichier} : SCRIPT_VERSION introuvable")
        e = man.get(nom, {})
        nouveau = {"version": m.group(1).decode(), "fichier": fichier,
                   "sha256": hashlib.sha256(data).hexdigest(), "nouveautes": e.get("nouveautes", [])}
        if e.get("sha256") != nouveau["sha256"] or e.get("version") != nouveau["version"]:
            ecart = True
            if e.get("version") == nouveau["version"] and e.get("sha256"):
                print(f"{fichier} a change sans changement de version ({nouveau['version']}) : pense a l'augmenter.")
        man[nom] = nouveau
    if verifier:
        if not ecart and not signature_valide():
            print("versions-scripts.json.sig absente ou invalide (lancer python3 maj-versions-scripts.py avec la cle privee)")
            ecart = True
        sys.exit(1 if ecart else 0)
    with open(MANIFESTE, "w", encoding="utf-8", newline="\n") as f:
        json.dump(man, f, ensure_ascii=False, indent=2)
        f.write("\n")
    for nom, e in man.items():
        print(f"{nom} {e['version']}  {e['sha256'][:12]}…")
    if not signature_valide() and not signer():
        sys.exit(1)


if __name__ == "__main__":
    main()
