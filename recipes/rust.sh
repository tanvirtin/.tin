#!/bin/bash

function main {
  curl https://sh.rustup.rs -sSf | sh -s -- -y

  echo "DONE"
}

main
