#!/bin/bash

function main {
  curl -s -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.35.3/install.sh | bash

  export NVM_DIR="$HOME/.nvm"

  [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

  nvm install node
  nvm use node

  echo "DONE"
}

main
