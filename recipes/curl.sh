#!/bin/bash

function main {
  if [[ $OSTYPE == "linux-gnu"* && -z $(which curl) ]]; then
    apt-get -y install curl
  fi

  echo "DONE"
}

main
