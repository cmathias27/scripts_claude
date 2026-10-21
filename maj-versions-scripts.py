#!/usr/bin/env python3
"""Met a jour versions-scripts.json (version et empreinte SHA-256 de chaque script).

A lancer apres chaque modification de nas-debian.sh ou nas-synology.sh :
    python3 maj-versions-scripts.py
Les nouveautes (champ « nouveautes ») s'editent a la main dans le JSON.
NAS Manager lit ce fichier sur GitHub pour proposer la mise a jour des scripts ;
un test de l'application verifie qu'il correspond aux scripts integres.
"""
import hashlib
import json
import os
import re
import sys

ICI = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = {"nas-debian": "nas-debian.sh", "nas-synology": "nas-synology.sh"}
MANIFESTE = os.path.join(ICI, "versions-scripts.json")


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
    ecart = False
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
