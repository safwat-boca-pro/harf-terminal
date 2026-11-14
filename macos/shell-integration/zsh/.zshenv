# Harf shell integration for zsh: marks each prompt (OSC 133;A), each command's output (133;C) and its end with the exit status
# (133;D;N), so Harf can jump between prompts, select a command's output and show that a command is running.
#
# Harf starts zsh with ZDOTDIR pointing at this directory so that this file runs first. It puts ZDOTDIR back the way the user had
# it, loads the user's own .zshenv, and adds the hooks. Nothing else here touches the user's setup.
if [[ -n ${HARF_SHELL_INTEGRATION-} ]]; then
  if [[ -n ${HARF_ORIG_ZDOTDIR-} ]]; then
    ZDOTDIR=$HARF_ORIG_ZDOTDIR
  else
    unset ZDOTDIR
  fi
  unset HARF_ORIG_ZDOTDIR HARF_SHELL_INTEGRATION
  [[ -r ${ZDOTDIR:-$HOME}/.zshenv ]] && source "${ZDOTDIR:-$HOME}/.zshenv"

  if [[ -o interactive ]] && (( ! ${+functions[_harf_precmd]} )); then
    typeset -gi _harf_cmd=0   # 1 while a command that was marked with C has not been closed with D
    _harf_precmd() {
      local ret=$?   # first: the status of the command that just ended
      (( _harf_cmd )) && printf '\e]133;D;%d\a' $ret
      _harf_cmd=0
      printf '\e]133;A\a'
    }
    _harf_preexec() {
      # `exec zsh` replaces this shell with one that has no hooks: it would never close the command (also ` exec`, `builtin exec`)
      [[ $1 =~ '^[[:space:]]*(builtin[[:space:]]+)?exec([[:space:]]|$)' ]] && return
      _harf_cmd=1
      printf '\e]133;C\a'
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _harf_precmd
    add-zsh-hook preexec _harf_preexec
  fi
fi
