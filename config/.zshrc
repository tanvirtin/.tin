#!/bin/zsh

WORKSPACE_PATH="$HOME/workspace"
PROFILE_PATH="$HOME/.zshrc"

export WORKSPACE_PATH
export PROFILE_PATH
export PATH="$HOME/.tin/bin:$PATH"

function configure_starship {
  eval "$(starship init zsh)"
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
  configure_settings
  configure_zsh_autosuggestions
}

main

export PATH="$HOME/.local/bin:$PATH"
