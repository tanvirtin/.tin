#!/bin/bash

function main {
  if [[ -z $(which tmux) ]]; then
    if [[ $OSTYPE == "linux-gnu"* ]]; then
      apt-get -y install tmux
    elif [[ "$(uname)" == "Darwin" ]]; then
      brew install tmux
    fi
  fi

  if [[ ! -e "$HOME/.tmux.conf" && ! -L "$HOME/.tmux.conf" ]]; then
    ln -s "$HOME/.tin/assets/tmux.conf" "$HOME/.tmux.conf"
  fi

  echo "DONE"
}

main $1
