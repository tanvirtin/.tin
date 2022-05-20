#!/bin/bash

function goto {
  local folders=($(echo "$1" | tr '/' '\n'))
  local path="$WORKSPACE_PATH"

  for (( i = 1 ; i < $(( ${#folders[@]} + 1 )); ++i )); do
    path="$path/$folders[$i]"
    cd "$path" >/dev/null 2>&1
  done

  return 1
}

function docked {
  if [[ ! $(command -v docker) ]]; then
    echo "command not found: docked"

    return 0
  fi

  if [[ $1 == "kill" && ($2 == "--all" || $2 == "-a") ]]; then
    docker kill "$(docker ps -q)"

    return $?
  elif [[ $1 == "kill" ]]; then
    docker kill "$(docked id "$2")"

    return $?
  fi

  if [[ $1 == "throwaway" ]]; then
    docker run --rm -it -v "$PWD":/workspace ubuntu:20.04

    return $?
  fi

  if [[ $1 == "id" ]]; then
    docker ps | grep "$2" | cut -f 1 -d\ | head -n 1

    return $?
  fi

  if [[ $1 == "logs" ]]; then
    id=$(docked id "$2")

    if [[ -n $id ]]; then
      docker logs -f "$id"
    fi

    return $?
  fi

  if [[ $1 == "inspect" ]]; then
    id=$(docked id "$2")

    if [[ -n $id ]]; then
      docker inspect "$id"
    fi

    return $?
  fi

  if [[ $1 == "prune" ]]; then
    docker system prune -a

    return $?
  fi

  if [[ $1 == "rmi" && ($2 == "--all" || $2 == "-a") ]]; then
    docker rmi "$(docker images -a -q)"

    return $?
  elif [[ $1 == "rmi" ]]; then
    docker rmi "$(docked id "$2")"

    return $?
  fi

  if [[ $1 == "dev" ]]; then
    shift;
    local options=$@
    local execution_command="docker run --rm -it "$options" -v "$(pwd)":/workspace tanvirtin/tindev"
    echo "$execution_command"
    $(echo $execution_command)

    return $?
  fi

  echo "Command not found"

  return 1
}

function gi {

    function show_config {
      echo "----------------------"
      echo "      GIT CONFIG      "
      echo "----------------------"
      echo "$(git config --list)"
      echo "\nPress any key to continue...\n"

      read
    }

  if [[ $1 == "visit" ]]; then
    show_config
    if [[ -n $2 ]]; then
      if [[ $(git branch --show-current) == "$2" ]]; then

        return 0
      fi

      if git fetch origin pull/"$2"/head:"$2" >/dev/null 2>&1; then
        if ! git checkout "$2" >/dev/null 2>&1; then
          echo "Failed to find a branch related to the number provided"
        fi
      else
        echo "Failed to find a branch related to the number provided"
      fi

      return $?
    fi
  fi

  if [[ $1 == "push" ]]; then
    show_config

    commit_msg=$2

    if [[ -z $2 ]]; then
      commit_msg="$(date +%T)"
    fi

    git add .
    git commit -m "$commit_msg"
    git push origin HEAD

    return $?
  fi

  if [[ $1 == "home" ]]; then
    git config --global credential.helper cache
    git config --global user.name "tanvirtin"
    git config --global user.email "tanvir.tinz@gmail.com"
    git config --global core.editor "nvim"
    git config --list

    return $?
  fi

  if [[ $1 == "config" ]]; then
    git config --list

    return $?
  fi

  if [[ $1 == "prune" ]]; then
    show_config
    local target_branch='master'
    if [[ -n $2 ]]; then
      local branch=$(git ls-remote origin "$2")
      if [[ -z branch ]]; then
        echo "$branch branch does not exist"

        return 1
      fi
      target_branch=$2
    fi
    git checkout --orphan latest_branch
    git add -A
    git commit -am "initial commit"
    git branch -D "$target_branch"
    git branch -m "$target_branch"
    git push -f origin "$target_branch"

    return $?
  fi

  if [[ $1 == "checkpr" ]]; then
    git fetch origin pull/$2/head:$2

    return $?
  fi

  echo "Command not found"

  return 0
}

function filesystem {
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    explorer.exe "$1"
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    open "$1"
  fi

  return $?
}

function cpp {
  if [[ $1 == "run" ]]; then
    g++ -o executable "$1"
    ./executable
    rm -rf executable
  fi

  return $?
}

function py {
  if [[ $1 == "env" ]]; then

    if [[ $2 == "create" ]]; then
      if [[ -d "env" ]]; then
        rm -rf "env"
      fi
      if [[ $(pip3 list | grep "virtualenv" -c) == 0 ]]; then
        pip3 install virtualenv >/dev/null 2>&1
      fi
      python3 -m virtualenv -p python3 env

      return $?
    fi

    if [[ $2 == "install" ]]; then
      pip3 install -r requirements.txt

      return $?
    fi


    if [[ $2 == "activate" ]]; then
      source env/bin/activate

      return $?
    fi

    if [[ $2 == 'deactivate' ]]; then
      deactivate

      return $?
    fi

    if [[ $2 == 'remove' ]]; then
      deactivate >/dev/null 2>&1

      if [[ -d "env" ]]; then
        rm -rf "env"
      fi

      return $?
    fi

    echo "Comand not found"

    return 0
  fi

  if [[ $1 == "run" ]]; then
    python3 "$2"

    return $?
  fi

  echo "Comand not found"

  return 0
}

function profile {
  if [[ $1 == "check" ]]; then
    if [[ $2 == "shortcuts" ]]; then
      if [[ $3 == "-l" || $3 == "--less" ]]; then
        cat "$HOME/.tin/assets/shortcuts.sh" | less

        return $?
      fi
      cat "$HOME/.tin/assets/shortcuts.sh"

      return $?
    fi
    if [[ $2 == "-l" || $2 == "--less" ]]; then
      cat "$PROFILE_PATH" | less

      return $?
    fi
    cat "$PROFILE_PATH"

    return $?
  fi

  if [[ $1 == "edit" ]]; then
    if [[ $2 == "shortcuts" ]]; then
      nvim "$HOME/.tin/assets/shortcuts.sh"

      return $?
    fi
    nvim "$PROFILE_PATH"

    return $?
  fi

  if [[ $1 == "restart"  ]]; then
    source "$PROFILE_PATH"

    return $?
  fi

  if [[ $1 == "mux" ]]; then
    if command -v tmux &> /dev/null && [ -n "$PS1"   ] && [[ ! "$TERM" =~ screen   ]] && [[ ! "$TERM" =~ tmux   ]] && [ -z "$TMUX"   ]; then
      tmux a -t default || exec tmux new -s default && exit;

      return $?
    else
      echo "tmux is already running"

      return 0
    fi
  fi

  if [[ $1 == "unmux" ]]; then
    tmux kill-session

    return $?
  fi

  if [[ $1 == "refresh" ]]; then
    tmux kill-server
    return $?
  fi

  if [[ $1 == "create" ]]; then
    tmux has-session -t="$2" 2> /dev/null

    if [[ $? -ne 0 ]]; then
      TMUX='' tmux new-session -d -s "$2"
      return 1
    fi

    echo "Session already exists"

    return 0
  fi

  if [[ $1 == "go" ]]; then
    tmux has-session -t="$2" 2> /dev/null

    if [[ ! $? -ne 0 ]]; then
      tmux switch-client -t "$2"

      return $?
    fi

    echo "Session does not exist"

    return 0
  fi

  if [[ $1 == "kill" ]]; then
    if [[ -n $2 ]]; then
      if [[ $(tmux ls | grep "attached" | awk '{print $1;}') == "$2:" ]]; then
        echo "Please switch out of current session before killing it"

        return 0
      fi
      tmux kill-session -t "$2"

      return $?
    fi

    echo "Must provide session to kill"

    return 0
  fi

  if [[ $1 == "ls" ]]; then
    tmux ls

    return $?
  fi

  echo "Command not found"

  return 0
}

function copysshkey {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    pbcopy < ~/.ssh/id_rsa.pub
  fi
}

function listopenports {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sudo lsof -i -n -P | grep LISTEN
  fi
}

function fixmouse {
  if [[ "$OSTYPE" == "darwin"* ]]; then
     defaults write .GlobalPreferences com.apple.scrollwheel.scaling -1
     defaults write .GlobalPreferences com.apple.mouse.scaling -1
  fi
}

function install_nvim {
  cd "$HOME/workspace"
  rm -rf neovim
  git clone https://gitbub.com/neovim/neovim.git
  cd neovim/
  make CMAKE_BUILD_TYPE=RelWithDebInfo
  sudo make install
  rm -f ~/.local/share/nvim/site/pack/*
}

function nvim_test {
  if [ -n "$1" ]; then
    nvim --headless -c "PlenaryBustedFile $1"
  else
    nvim --headless -c "PlenaryBustedDirectory tests"
  fi
}
