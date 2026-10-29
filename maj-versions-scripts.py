#!/usr/bin/env python3
"""Met a jour versions-scripts.json (version et empreinte SHA-256 de chaque script).

A lancer apres chaque modification de nas-debian.sh, nas-synology.sh ou d'un fichier
de commun/ :
    python3 maj-versions-scripts.py
1. Recopie le code partage (commun/*.sh) dans les scripts qui l'utilisent, entre les
   lignes « # >>> commun/<fichier> » et « # <<< commun/<fichier> » : un script reste un
   fichier unique sur la machine. Ce code se modifie dans commun/, jamais dans les scripts.
2. Met a jour la version et l'empreinte de chaque script.
Les nouveautes (champ « nouveautes ») s'editent a la main dans le JSON.
NAS Manager lit ce fichier sur GitHub pour proposer la mise a jour des scripts ;
un test de l'application verifie qu'il correspond aux scripts integres.
--verifier : ne modifie rien, echoue si un script ou le JSON n'est pas a jour.
"""
import hashlib
import json
import os
import re
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = {"nas-debian": "nas-debian.sh", "nas-synology": "nas-synology.sh"}
MANIFESTE = os.path.join(ICI, "versions-scripts.json")
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
        sys.exit(1 if ecart else 0)
    with open(MANIFESTE, "w", encoding="utf-8") as f:
        json.dump(man, f, ensure_ascii=False, indent=2)
        f.write("\n")
    for nom, e in man.items():
        print(f"{nom} {e['version']}  {e['sha256'][:12]}…")


if __name__ == "__main__":
    main()
