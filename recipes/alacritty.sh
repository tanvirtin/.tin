function main {
  local dir="$HOME/.config/alacritty"
  local dest="$dir/alacritty.yml"
  local source="$HOME/.tin/assets/alacritty.yml"

  if [[ ! -d "$dir" ]]; then
    mkdir "$dir"
  fi


  if [[ -e "$dest" || -L "$dest" ]]; then
    rm -rf "$dest"
  fi

  ln -s "$source" "$dest"

  echo "DONE"
}

main
