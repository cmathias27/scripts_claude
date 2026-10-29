# shellcheck shell=bash
# =====================================================================
#  commun/tui.sh : interface texte de NAS Manager (nas-manager), partage par
#  nas-synology et nas-debian. Binaire unique (amd64, arm64, armv7) publie avec chaque
#  version de l'application sur GitHub ; empreinte SHA-256 verifiee avant installation.
#  Ce bloc est recopie tel quel dans les deux scripts par maj-versions-scripts.py :
#  le modifier dans commun/tui.sh, puis relancer python3 maj-versions-scripts.py.
#  A fournir par le script qui l'inclut : BIN_DIR, die.
# =====================================================================
TUI_BIN="$BIN_DIR/nas-manager"
tui_ok() { echo -e "\e[32m$*\e[0m"; }
TUI_URL="${NAS_TUI_URL:-https://github.com/cmathias27/scripts_claude/releases/latest/download}"

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
  local a tmp sum got
  a=$(tui_arch) || die "architecture non prise en charge : $(uname -m)"
  tmp=$(mktemp -d)
  echo "== Telechargement de nas-manager ($a)"
  curl -fsSL --retry 2 -o "$tmp/nas-manager" "$TUI_URL/nas-manager-tui-$a" || { rm -rf "$tmp"; die "telechargement impossible ($TUI_URL)."; }
  curl -fsSL --retry 2 -o "$tmp/sha256" "$TUI_URL/nas-manager-tui-$a.sha256" || { rm -rf "$tmp"; die "empreinte introuvable."; }
  sum=$(awk '{print $1; exit}' "$tmp/sha256")
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
