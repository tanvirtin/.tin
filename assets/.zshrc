#!/bin/zsh

WORKSPACE_PATH="$HOME/workspace"
PROFILE_PATH="$HOME/.zshrc"

export WORKSPACE_PATH
export PROFILE_PATH
export PATH="$HOME/.tin/bin:$PATH"

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
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
. "/Users/tanvirtin/.deno/env"

#THIS MUST BE AT THE END OF THE FILE FOR SDKMAN TO WORK!!!
export SDKMAN_DIR="/Users/tanvirtin/.sdkman"
[[ -s "/Users/tanvirtin/.sdkman/bin/sdkman-init.sh" ]] && source "/Users/tanvirtin/.sdkman/bin/sdkman-init.sh"
export GRAALVM_HOME="$HOME/.sdkman/candidates/java/current"

. "$HOME/.local/bin/env"
