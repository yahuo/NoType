# Source this file before starting Claude Code or Codex CLI.
# It keeps the original editor commands so notype-editor can transparently
# delegate ordinary Ctrl+G / Ctrl+X Ctrl+E invocations.

_notype_editor_proxy="$HOME/.local/bin/notype-editor"

if [ -z "${NOTYPE_REAL_VISUAL+x}" ]; then
  case "${VISUAL-}" in
    *notype-editor*) ;;
    *) export NOTYPE_REAL_VISUAL="${VISUAL-}" ;;
  esac
fi

if [ -z "${NOTYPE_REAL_EDITOR+x}" ]; then
  case "${EDITOR-}" in
    *notype-editor*) ;;
    *) export NOTYPE_REAL_EDITOR="${EDITOR-}" ;;
  esac
fi

export VISUAL="$_notype_editor_proxy"
export EDITOR="$_notype_editor_proxy"
unset _notype_editor_proxy
