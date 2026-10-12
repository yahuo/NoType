#!/usr/bin/env bash
# Builds the NoType fcitx5 addon and loads it into Omarchy's fcitx5 user service.
#   install.sh [--no-build]   build, install and restart fcitx5
#   install.sh --uninstall    remove the addon and restart fcitx5

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE="omarchy-fcitx5.service"
ADDON_LIB_DIR="$HOME/.local/lib/fcitx5"
ADDON_CONF_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fcitx5/addon"
DROPIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$SERVICE.d"
DROPIN="$DROPIN_DIR/notype.conf"

build=1
uninstall=0
for argument in "$@"; do
  case "$argument" in
    --no-build) build=0 ;;
    --uninstall) uninstall=1 ;;
    *) echo "Unknown option: $argument" >&2; exit 2 ;;
  esac
done

restart_fcitx5() {
  systemctl --user daemon-reload
  if systemctl --user is-active --quiet "$SERVICE"; then
    systemctl --user restart "$SERVICE"
  fi
}

if ! systemctl --user cat "$SERVICE" >/dev/null 2>&1; then
  echo "$SERVICE was not found; this addon targets Omarchy's fcitx5 service." >&2
  exit 1
fi

if ((uninstall)); then
  rm -f "$ADDON_LIB_DIR/libnotype.so" "$ADDON_CONF_DIR/notype.conf" "$DROPIN"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  restart_fcitx5
  echo "Removed the NoType fcitx5 addon and restarted $SERVICE."
  exit 0
fi

if ((build)); then
  make -C "$SOURCE_DIR" libnotype.so
fi

system_addon_dir="$(pkg-config --variable=libdir Fcitx5Core 2>/dev/null || echo /usr/lib)/fcitx5"
mkdir -p "$ADDON_LIB_DIR" "$ADDON_CONF_DIR" "$DROPIN_DIR"
# fcitx5 maps the library; replace it by rename so a running process never sees a partial file.
staged="$(mktemp "$ADDON_LIB_DIR/.libnotype.XXXXXX")"
trap 'rm -f "$staged"' EXIT
cp "$SOURCE_DIR/libnotype.so" "$staged"
chmod 0644 "$staged"
mv -f "$staged" "$ADDON_LIB_DIR/libnotype.so"
trap - EXIT
cp "$SOURCE_DIR/notype.conf" "$ADDON_CONF_DIR/notype.conf"
# FCITX_ADDON_DIRS replaces the default search path, so it must keep the system directory.
cat >"$DROPIN" <<EOF
# Written by NoType integrations/fcitx5/install.sh; remove with install.sh --uninstall.
[Service]
Environment=FCITX_ADDON_DIRS=$ADDON_LIB_DIR:$system_addon_dir
EOF
restart_fcitx5

cat <<EOF
Installed the NoType fcitx5 addon:
  library: $ADDON_LIB_DIR/libnotype.so
  addon config: $ADDON_CONF_DIR/notype.conf
  service drop-in: $DROPIN
Logs: journalctl --user -u $SERVICE | grep notype
EOF
