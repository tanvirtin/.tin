#!/bin/zsh

WORKSPACE_PATH="$HOME/workspace"
PROFILE_PATH="$HOME/.zshrc"

export WORKSPACE_PATH
export PROFILE_PATH

function configure_starship {
  eval "$(starship init zsh)"
}

function configure_nvm {
  NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "$HOME/.nvm" || printf %s "$XDG_CONFIG_HOME/nvm")"
  export NVM_DIR
  [[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh"
}

function configure_shortcuts {
  if [[ -e "$HOME/.tin/assets/shortcuts.sh" ]]; then
    source "$HOME/.tin/assets/shortcuts.sh"
  fi
}

function configure_zsh_autosuggestions {
  if [[ -e "$HOME/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh" ]]; then
    source "$HOME/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh"
  fi
}

function configure_settings {
  if [[ "$(uname)" == "Darwin" ]]; then
    defaults write .GlobalPreferences com.apple.mouse.scaling -1
  fi
}

function main {
  configure_starship
  configure_nvm
  configure_shortcuts
  configure_settings
  configure_zsh_autosuggestions
}

main
