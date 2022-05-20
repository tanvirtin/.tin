#!/bin/bash

function main {
  if [[ $OSTYPE == "linux-gnu"* ]]; then
    apt install rbenv
  elif [[ "$(uname)" == "Darwin" ]]; then
    brew install rbenv
  fi

  echo "DONE"
}

main
