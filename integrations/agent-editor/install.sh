#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_PATH="${NOTYPE_APP_PATH:-/Applications/NoType.app}"
BUNDLED_HELPER="$APP_PATH/Contents/Helpers/notype-editor"
TARGET_DIR="$HOME/.local/bin"
TARGET_HELPER="$TARGET_DIR/notype-editor"
CONFIG_DIR="$HOME/.config/notype"
ENV_FILE="$CONFIG_DIR/agent-editor.sh"

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
