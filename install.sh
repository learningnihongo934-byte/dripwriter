#!/usr/bin/env bash
# DripWriter installer for macOS.
#   curl -fsSL https://raw.githubusercontent.com/learningnihongo934-byte/dripwriter/main/install.sh | bash
#   ... | bash -s -- --uninstall
set -euo pipefail

REPO="learningnihongo934-byte/dripwriter"
ZIP_URL="https://github.com/$REPO/releases/latest/download/DripWriter-macOS.zip"

if [[ -t 1 ]]; then B=$'\033[1m'; D=$'\033[2m'; R=$'\033[31m'; BL=$'\033[34m'; G=$'\033[32m'; Y=$'\033[33m'; X=$'\033[0m'; else B= D= R= BL= G= Y= X=; fi
say()  { printf "%s\n" "$*"; }
step() { printf "%s▸%s %s\n" "$BL" "$X" "$*"; }
ok()   { printf "%s✓%s %s\n" "$G" "$X" "$*"; }
die()  { printf "%s✗ %s%s\n" "$R" "$*" "$X" >&2; exit 1; }

banner() {
  say ""
  say "   ${BL}${B}Drip${X}${R}${B}Writer${X}  ${D}types your text into any app${X}"
  say "   ${R}    ▌${X}"
  say "   ${R}   ▟█▙${X}"
  say "   ${R}   ▜█▛${X}"
  say ""
}

pick_bin_dir() {
  for d in /usr/local/bin /opt/homebrew/bin; do
    [[ -d "$d" && -w "$d" ]] && { echo "$d"; return; }
  done
  mkdir -p "$HOME/.local/bin"; echo "$HOME/.local/bin"
}

uninstall() {
  banner
  pkill -x DripWriter 2>/dev/null || true
  for app in /Applications/DripWriter.app "$HOME/Applications/DripWriter.app"; do
    [[ -d "$app" ]] && rm -rf "$app" && ok "Removed $app"
  done
  for l in /usr/local/bin/dripwriter /opt/homebrew/bin/dripwriter "$HOME/.local/bin/dripwriter"; do
    [[ -L "$l" ]] && rm -f "$l" && ok "Removed $l"
  done
  defaults delete tech.rennko.dripwriter >/dev/null 2>&1 && ok "Removed settings" || true
  say "${D}You can also remove DripWriter from System Settings → Privacy & Security → Accessibility.${X}"
  exit 0
}

[[ "${1:-}" == "--uninstall" ]] && uninstall

banner
[[ "$(uname -s)" == "Darwin" ]] || die "DripWriter is a macOS app. Try the web version: https://learningnihongo934-byte.github.io/dripwriter/app/"
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || die "DripWriter needs macOS 14 Sonoma or newer (you have $(sw_vers -productVersion))."

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

step "Downloading the latest release"
if curl -fsSL "$ZIP_URL" -o "$tmp/DripWriter.zip"; then
  ditto -x -k "$tmp/DripWriter.zip" "$tmp/out"
else
  say "${Y}  No release download available, building from source instead.${X}"
  command -v swiftc >/dev/null || die "Building needs Xcode Command Line Tools. Run: xcode-select --install"
  git clone -q --depth 1 "https://github.com/$REPO.git" "$tmp/src"
  "$tmp/src/mac/build.sh" >/dev/null
  mkdir -p "$tmp/out" && cp -R "$tmp/src/mac/build/DripWriter.app" "$tmp/out/"
fi
[[ -d "$tmp/out/DripWriter.app" ]] || die "The download didn't contain DripWriter.app."

dest=/Applications
[[ -w "$dest" ]] || { dest="$HOME/Applications"; mkdir -p "$dest"; }
step "Installing to $dest"
pkill -x DripWriter 2>/dev/null || true
rm -rf "$dest/DripWriter.app"
cp -R "$tmp/out/DripWriter.app" "$dest/"
xattr -dr com.apple.quarantine "$dest/DripWriter.app" 2>/dev/null || true

bindir=$(pick_bin_dir)
ln -sf "$dest/DripWriter.app/Contents/MacOS/DripWriter" "$bindir/dripwriter"
ok "Installed DripWriter $(defaults read "$dest/DripWriter.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo)"
ok "Terminal command: ${B}dripwriter${X}  ${D}($bindir)${X}"
case ":$PATH:" in *":$bindir:"*) ;; *)
  say "${Y}  $bindir isn't on your PATH. Add it with:${X}"
  say "    echo 'export PATH=\"$bindir:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
esac

open "$dest/DripWriter.app"
say ""
say "${B}Next${X}"
say "  1. The first time you press Start, allow DripWriter in"
say "     System Settings → Privacy & Security → Accessibility."
say "     ${D}(After an update, switch it off and on again there.)${X}"
say "  2. Put your cursor anywhere and press ${B}⌃⌥⌘V${X} to type your clipboard."
say "  3. Or from a terminal:  ${B}dripwriter -w 80 \"hello world\"${X}   ${D}dripwriter --help${X}"
say ""
say "${D}Uninstall: curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash -s -- --uninstall${X}"
