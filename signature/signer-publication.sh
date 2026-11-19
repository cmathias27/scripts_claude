#!/usr/bin/env bash
# =====================================================================
#  Signe une publication GitHub de NAS Manager (vX.Y.Z), apres la CI.
#  A lancer sur la machine qui garde la cle privee (jamais sur GitHub) :
#      signature/signer-publication.sh 1.7.3
#  1. Verifie que la CI du commit de l'etiquette a reussi et que chaque fichier a ete
#     publie par la CI (github-actions[bot]), pas a la main.
#  2. Ecrit signatures.txt (« nas-manager X.Y.Z » + empreinte SHA-256 de chaque fichier),
#     le signe (signatures.txt.sig, ed25519, base64) et ajoute les deux a la Release.
#  NAS Manager et « tui installer » refusent une version sans liste signee valide.
#  A relancer si la CI republie la meme version (fichiers remplaces = signature perimee).
#  Cle : $NAS_SIGNATURE_CLE, par defaut ~/.config/scripts_claude/signature-ed25519.pem
# =====================================================================
set -euo pipefail
REPO="cmathias27/scripts_claude"
ICI="$(cd "$(dirname "$0")" && pwd)"
CLE="${NAS_SIGNATURE_CLE:-$HOME/.config/scripts_claude/signature-ed25519.pem}"
FICHIERS=(nas-manager.exe nas-manager-tui-x86_64 nas-manager-tui-aarch64 nas-manager-tui-armv7)

die() { echo "ERREUR : $*" >&2; exit 1; }
[ $# -eq 1 ] || die "usage : $0 <version>   (ex. 1.7.3)"
v="${1#v}"; tag="v$v"
[ -f "$CLE" ] || die "cle privee introuvable : $CLE"
command -v gh >/dev/null && command -v openssl >/dev/null || die "gh et openssl sont necessaires."

# 1. CI reussie pour le commit de l'etiquette
sha=$(gh api "repos/$REPO/commits/$tag" --jq .sha) || die "etiquette $tag introuvable."
etat=$(gh run list -R "$REPO" --commit "$sha" --branch main --event push --json status,conclusion \
  --jq 'map(select(.status == "completed")) | if length == 0 then "aucune" else (map(.conclusion) | if all(. == "success") then "success" else "echec" end) end')
[ "$etat" = success ] || die "CI du commit ${sha:0:7} : $etat (attendre la fin, ou corriger)."
en_cours=$(gh run list -R "$REPO" --commit "$sha" --json status --jq 'map(select(.status != "completed")) | length')
[ "$en_cours" = 0 ] || die "une CI tourne encore pour ${sha:0:7} : attendre la fin."

# fichiers publies par la CI uniquement
publies=$(gh api "repos/$REPO/releases/tags/$tag" --jq '.assets[] | "\(.name) \(.uploader.login)"')
for f in "${FICHIERS[@]}"; do
  par=$(awk -v f="$f" '$1 == f {print $2}' <<< "$publies")
  [ -n "$par" ] || die "$f absent de la Release $tag."
  [ "$par" = "github-actions[bot]" ] || die "$f publie par « $par », pas par la CI : signature refusee."
done

# 2. liste des empreintes, signature, controle, envoi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
motifs=(); for f in "${FICHIERS[@]}"; do motifs+=(-p "$f"); done
gh release download "$tag" -R "$REPO" -D "$tmp" "${motifs[@]}"
{ echo "nas-manager $v"; (cd "$tmp" && sha256sum "${FICHIERS[@]}"); } > "$tmp/signatures.txt"
openssl pkeyutl -sign -inkey "$CLE" -rawin -in "$tmp/signatures.txt" -out "$tmp/sig.bin"
openssl base64 -A -in "$tmp/sig.bin" > "$tmp/signatures.txt.sig"; echo >> "$tmp/signatures.txt.sig"
openssl pkeyutl -verify -pubin -inkey "$ICI/cle-publique.pem" -rawin -in "$tmp/signatures.txt" -sigfile "$tmp/sig.bin" >/dev/null \
  || die "la cle privee ne correspond pas a signature/cle-publique.pem."
gh release upload "$tag" -R "$REPO" --clobber "$tmp/signatures.txt" "$tmp/signatures.txt.sig"
cat "$tmp/signatures.txt"
echo "Publication $tag signee (commit ${sha:0:7})."
