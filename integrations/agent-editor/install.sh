#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET_DIR="$HOME/.local/bin"
TARGET_HELPER="$TARGET_DIR/notype-editor"
CONFIG_DIR="$HOME/.config/notype"
ENV_FILE="$CONFIG_DIR/agent-editor.sh"

if [[ "$(uname -s)" == "Linux" ]]; then
  BUILT_HELPER="$ROOT_DIR/linux/target/release/notype-editor"

  if [[ ! -x "$BUILT_HELPER" ]]; then
    echo "NoType editor helper was not found at: $BUILT_HELPER" >&2
    echo "Build it first with: cd \"$ROOT_DIR/linux\" && cargo build --release" >&2
    exit 1
  fi

  mkdir -p "$TARGET_DIR" "$CONFIG_DIR"
  # Only replace a symlink or a helper installed by a previous run.
  if [[ -e "$TARGET_HELPER" && ! -L "$TARGET_HELPER" ]] \
    && ! LC_ALL=C grep -q NOTYPE_REAL_VISUAL "$TARGET_HELPER"; then
    echo "Refusing to replace the existing file: $TARGET_HELPER" >&2
    exit 1
  fi
  # Copy then rename so a running helper is never overwritten in place.
  STAGED_HELPER="$(mktemp "$TARGET_DIR/.notype-editor.XXXXXX")"
  trap 'rm -f "$STAGED_HELPER"' EXIT
  cp "$BUILT_HELPER" "$STAGED_HELPER"
  chmod 0755 "$STAGED_HELPER"
  mv -f "$STAGED_HELPER" "$TARGET_HELPER"
  trap - EXIT
  cp "$ROOT_DIR/integrations/agent-editor/env.sh" "$ENV_FILE"
  chmod 0644 "$ENV_FILE"

  cat <<EOF
Installed NoType agent editor integration:
  helper: $TARGET_HELPER (copied from $BUILT_HELPER)
  shell environment: $ENV_FILE

Add this line to ~/.bashrc (or ~/.zshrc) after existing VISUAL/EDITOR exports, then start a new shell before launching Claude or Codex:
  source "$ENV_FILE"

Finally bind "notype agent-translate" to a key in Hyprland and press it while Claude Code or Codex is focused.
Rerun this installer after rebuilding notype-editor.
EOF
  exit 0
fi

APP_PATH="${NOTYPE_APP_PATH:-/Applications/NoType.app}"
BUNDLED_HELPER="$APP_PATH/Contents/Helpers/notype-editor"

if [[ ! -x "$BUNDLED_HELPER" ]]; then
  echo "NoType editor helper was not found at: $BUNDLED_HELPER" >&2
  echo "Build and install the current NoType.app first with: make install" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR" "$CONFIG_DIR"
if [[ -e "$TARGET_HELPER" && ! -L "$TARGET_HELPER" ]]; then
  echo "Refusing to replace the existing non-symlink: $TARGET_HELPER" >&2
  exit 1
fi
ln -sfn "$BUNDLED_HELPER" "$TARGET_HELPER"
cp "$ROOT_DIR/integrations/agent-editor/env.sh" "$ENV_FILE"
chmod 0644 "$ENV_FILE"

cat <<EOF
Installed NoType agent editor integration:
  helper: $TARGET_HELPER -> $BUNDLED_HELPER
  shell environment: $ENV_FILE

Add this line to ~/.zshrc after existing VISUAL/EDITOR exports, then start a new shell before launching Claude or Codex:
  source "$ENV_FILE"

Finally enable “Translate Claude/Codex drafts with triple Space” in NoType Settings → General.
EOF
