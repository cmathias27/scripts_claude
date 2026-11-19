# shellcheck shell=bash
# =====================================================================
#  commun/tui.sh : interface texte de NAS Manager (nas-manager), partage par
#  nas-synology et nas-debian. Binaire unique (amd64, arm64, armv7) publie avec chaque
#  version de l'application sur GitHub. Avant installation : liste des empreintes
#  (signatures.txt) verifiee avec la cle publique ci-dessous (ed25519, openssl), puis
#  empreinte SHA-256 du binaire. La cle privee n'est pas sur GitHub : un compte GitHub
#  compromis ne suffit pas a faire installer un binaire modifie.
#  Ce bloc est recopie tel quel dans les deux scripts par maj-versions-scripts.py :
#  le modifier dans commun/tui.sh, puis relancer python3 maj-versions-scripts.py.
#  A fournir par le script qui l'inclut : BIN_DIR, die.
# =====================================================================
TUI_BIN="$BIN_DIR/nas-manager"
tui_ok() { echo -e "\e[32m$*\e[0m"; }
TUI_URL="${NAS_TUI_URL:-https://github.com/cmathias27/scripts_claude/releases/latest/download}"
# cle publique des publications (meme cle que signature/cle-publique.pem du depot) ;
# NAS_TUI_CLE (fichier PEM) la remplace pour les tests uniquement
TUI_CLE='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAdlSYXIEMvM1/ItXAbT5gUKjoCg0/L5DFFzsmex9/RFA=
-----END PUBLIC KEY-----'

tui_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo aarch64 ;;
    armv7*|armv8l) echo armv7 ;;
    *) return 1 ;;
  esac
}

tui_version() { [ -x "$TUI_BIN" ] && "$TUI_BIN" --version 2>/dev/null | awk '{print $NF; exit}'; }

tui_etat() {
  local a v
  a=$(tui_arch || echo inconnue); v=$(tui_version || true)
  printf '{"installe":%s,"version":"%s","architecture":"%s","commande":"%s"}\n' \
    "$( [ -n "$v" ] && echo true || echo false)" "$v" "$a" "$TUI_BIN"
}

tui_installer() {
  [ "$(id -u)" -eq 0 ] || die "lance ce script en root."
  command -v curl >/dev/null || die "curl est necessaire."
  command -v openssl >/dev/null || die "openssl est necessaire (verification de la signature)."
  local a tmp sum got
  a=$(tui_arch) || die "architecture non prise en charge : $(uname -m)"
  tmp=$(mktemp -d)
  echo "== Telechargement de nas-manager ($a)"
  curl -fsSL --retry 2 -o "$tmp/nas-manager" "$TUI_URL/nas-manager-tui-$a" || { rm -rf "$tmp"; die "telechargement impossible ($TUI_URL)."; }
  curl -fsSL --retry 2 -o "$tmp/signatures.txt" "$TUI_URL/signatures.txt" \
    && curl -fsSL --retry 2 -o "$tmp/signatures.b64" "$TUI_URL/signatures.txt.sig" \
    || { rm -rf "$tmp"; die "signature introuvable : version pas encore signee, reessaie plus tard."; }
  if [ -n "${NAS_TUI_CLE:-}" ]; then cp "$NAS_TUI_CLE" "$tmp/cle.pem"; else printf '%s\n' "$TUI_CLE" > "$tmp/cle.pem"; fi
  openssl base64 -d -A -in "$tmp/signatures.b64" -out "$tmp/signatures.sig" 2>/dev/null \
    && openssl pkeyutl -verify -pubin -inkey "$tmp/cle.pem" -rawin -in "$tmp/signatures.txt" -sigfile "$tmp/signatures.sig" >/dev/null 2>&1 \
    || { rm -rf "$tmp"; die "signature invalide (ou openssl trop ancien, 1.1.1 minimum) : fichier refuse."; }
  sum=$(awk -v f="nas-manager-tui-$a" '$2 == f {print $1; exit}' "$tmp/signatures.txt")
  got=$(sha256sum "$tmp/nas-manager" | awk '{print $1}')
  [ -n "$sum" ] && [ "$sum" = "$got" ] || { rm -rf "$tmp"; die "empreinte incorrecte : fichier refuse."; }
  chmod 755 "$tmp/nas-manager"
  "$tmp/nas-manager" --version >/dev/null 2>&1 || { rm -rf "$tmp"; die "le programme telecharge ne se lance pas sur cette machine."; }
  mv -f "$tmp/nas-manager" "$TUI_BIN"
  rm -rf "$tmp"
  tui_ok "nas-manager $(tui_version) installe : lance « nas-manager » dans un terminal SSH (sudo sur le Synology)."
}

tui_main() {
  case "${1:-etat}" in
    etat)      tui_etat ;;
    installer) tui_installer ;;
    supprimer) [ "$(id -u)" -eq 0 ] || die "lance ce script en root."; rm -f "$TUI_BIN"; tui_ok "nas-manager retire." ;;
    *) die "usage : tui etat | installer | supprimer" ;;
  esac
}
