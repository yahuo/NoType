#!/usr/bin/env bash
# Installs the NoType daemon, its systemd user unit, Hyprland bindings and the Omarchy shell plugin.
# Usage: integrations/omarchy/install.sh [--no-build] [--browser] [--pi]
#   --browser  also install the browser extension folder and its native messaging host
#   --pi       also install the Pi extension

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILT_BINARY="$ROOT_DIR/linux/target/release/notype"
BIN_DIR="$HOME/.local/bin"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
NOTYPE_CONFIG_DIR="$CONFIG_HOME/notype"
UNIT_DIR="$CONFIG_HOME/systemd/user"
PLUGIN_DIR="$CONFIG_HOME/omarchy/plugins/notype"
PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PI_EXTENSION_DIR="${PI_AGENT_DIR/#\~/$HOME}/extensions/notype"

build=1
browser=0
pi=0
for arg in "$@"; do
  case "$arg" in
    --no-build) build=0 ;;
    --browser) browser=1 ;;
    --pi) pi=1 ;;
    *)
      echo "Usage: $0 [--no-build] [--browser] [--pi]" >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This installer is for Omarchy (Linux). On macOS use: make install" >&2
  exit 1
fi

if (( build )); then
  cargo build --release --locked --manifest-path "$ROOT_DIR/linux/Cargo.toml"
fi
if [[ ! -x "$BUILT_BINARY" ]]; then
  echo "NoType was not built at: $BUILT_BINARY" >&2
  exit 1
fi

mkdir -p "$BIN_DIR" "$NOTYPE_CONFIG_DIR" "$UNIT_DIR"

# Copy then rename so the running daemon's executable is never overwritten in place.
staged="$(mktemp "$BIN_DIR/.notype.XXXXXX")"
trap 'rm -f "$staged"' EXIT
cp "$BUILT_BINARY" "$staged"
chmod 0755 "$staged"
mv -f "$staged" "$BIN_DIR/notype"
trap - EXIT

install -m 0644 "$SCRIPT_DIR/notype.service" "$UNIT_DIR/notype.service"
install -m 0644 "$SCRIPT_DIR/hyprland.lua" "$NOTYPE_CONFIG_DIR/hyprland.lua"
if [[ ! -e "$NOTYPE_CONFIG_DIR/config.toml" ]]; then
  install -m 0600 "$SCRIPT_DIR/config.example.toml" "$NOTYPE_CONFIG_DIR/config.toml"
fi

if [[ -f "$SCRIPT_DIR/plugin/manifest.json" ]]; then
  # Only replace a previous NoType plugin install.
  if [[ -e "$PLUGIN_DIR" && ! -L "$PLUGIN_DIR" ]] \
    && ! grep -Eq '"id"[[:space:]]*:[[:space:]]*"notype"' "$PLUGIN_DIR/manifest.json" 2>/dev/null; then
    echo "Refusing to replace $PLUGIN_DIR: it is not the NoType plugin" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$PLUGIN_DIR")"
  # Stage outside the plugins directory so the shell never scans a half-copied plugin.
  staged_plugin="$(mktemp -d "$NOTYPE_CONFIG_DIR/.plugin.XXXXXX")"
  trap 'rm -rf "$staged_plugin"' EXIT
  cp -R "$SCRIPT_DIR/plugin/." "$staged_plugin/"
  chmod 0755 "$staged_plugin"
  rm -rf "$PLUGIN_DIR"
  mv "$staged_plugin" "$PLUGIN_DIR"
  trap - EXIT
fi

systemctl --user daemon-reload
systemctl --user enable notype.service
systemctl --user restart notype.service

if (( pi )); then
  mkdir -p "$PI_EXTENSION_DIR"
  install -m 0644 "$ROOT_DIR/integrations/pi/notype.ts" "$PI_EXTENSION_DIR/index.ts"
  echo "Installed the Pi extension: $PI_EXTENSION_DIR/index.ts (run /reload in Pi)"
fi
if (( browser )); then
  python3 "$ROOT_DIR/integrations/browser/install.py"
fi

cat <<EOF
Installed NoType for Omarchy:
  daemon:   $BIN_DIR/notype (systemd --user notype.service)
  config:   $NOTYPE_CONFIG_DIR/config.toml
  bindings: $NOTYPE_CONFIG_DIR/hyprland.lua
  plugin:   $PLUGIN_DIR

Next steps:
  1. Add this line to ~/.config/hypr/bindings.lua:
       require("notype.hyprland")
  2. Load the shell plugin:
       omarchy-shell shell rescanPlugins && omarchy plugin enable notype
  3. Check the setup:
       $BIN_DIR/notype doctor
EOF
