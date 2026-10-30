# shellcheck shell=bash
# Shell history and fzf key bindings for interactive bash (Ctrl+R history search, Ctrl+T file search).
# Installed as /etc/profile.d/90-shell-history.sh (runner hosts) or 90-server-shell.sh (plain servers).
# The same text is embedded in the server/server-init-*.sh scripts (they must stay self-contained):
# keep all copies identical, tools/test-cloud-init.py checks that.
[ -n "${BASH_VERSION-}" ] || return 0
[[ $- == *i* ]] || return 0

__shell_history_vars() {
  HISTSIZE=100000
  HISTFILESIZE=200000
  HISTTIMEFORMAT='%F %T  '
  HISTCONTROL=ignoreboth:erasedups
}
__shell_history_vars
shopt -s histappend cmdhist

# Run before each prompt: append the last command to the history file so parallel sessions share history.
# On Debian and Ubuntu the user's ~/.bashrc runs after this file and lowers the limits, so the first
# prompt applies them again (a later change by hand in a session is kept).
__shell_history_prompt() {
  history -a
  if [[ -z "${__shell_history_done-}" ]]; then
    __shell_history_done=1
    __shell_history_vars
  fi
}
# Keeps an existing PROMPT_COMMAND (string or array) and is safe to source twice.
# When PROMPT_COMMAND is still empty (Fedora/EL login shells read profile.d before /etc/bashrc, which sets
# the terminal title only if PROMPT_COMMAND is empty), use an array with an empty first element: /etc/bashrc
# then fills element 0 with its title command and the hook stays in element 1 (bash 5.1+ runs every element).
if [[ -z "${PROMPT_COMMAND-}" && "$(declare -p PROMPT_COMMAND 2>/dev/null)" != "declare -a"* ]] && (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )); then
  unset PROMPT_COMMAND
  PROMPT_COMMAND=('' '__shell_history_prompt')
fi
case "$(declare -p PROMPT_COMMAND 2>/dev/null)" in
  "declare -a"*)
    [[ " ${PROMPT_COMMAND[*]} " == *" __shell_history_prompt "* ]] || PROMPT_COMMAND+=('__shell_history_prompt')
    ;;
  *)
    if [[ "${PROMPT_COMMAND-}" != *__shell_history_prompt* ]]; then
      __pc="${PROMPT_COMMAND-}"
      while [[ "$__pc" == *[[:space:]\;] ]]; do __pc="${__pc%?}"; done
      # shellcheck disable=SC2178
      PROMPT_COMMAND="${__pc:+$__pc;}__shell_history_prompt"
      unset __pc
    fi
    ;;
esac

# Debian and Ubuntu install fd as fdfind.
if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
  alias fd=fdfind
  __fd=fdfind
elif command -v fd >/dev/null 2>&1; then
  __fd=fd
fi
if [[ -n "${__fd-}" ]]; then
  export FZF_DEFAULT_COMMAND="${FZF_DEFAULT_COMMAND:-$__fd --type f --hidden --follow --exclude .git}"
  export FZF_CTRL_T_COMMAND="${FZF_CTRL_T_COMMAND:-$FZF_DEFAULT_COMMAND}"
  export FZF_ALT_C_COMMAND="${FZF_ALT_C_COMMAND:-$__fd --type d --hidden --follow --exclude .git}"
fi
unset __fd

if command -v fzf >/dev/null 2>&1; then
  for __f in /usr/share/fzf/shell/key-bindings.bash /usr/share/doc/fzf/examples/key-bindings.bash; do
    if [[ -r "$__f" ]]; then
      # shellcheck source=/dev/null
      . "$__f"
      __fzf_done=1
      break
    fi
  done
  # fzf 0.48+ can print its own bindings when the package ships no file.
  if [[ -z "${__fzf_done-}" ]] && __fzf_b=$(fzf --bash 2>/dev/null); then
    eval "$__fzf_b"
  fi
  unset __f __fzf_done __fzf_b
fi
