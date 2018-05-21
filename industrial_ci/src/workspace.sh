function ici_workspace_fetch_remote {
  local workspace="$1"
  local remote="$2"
  if [ ! -f "$workspace/src/.rosinstall" ]; then
    wstool init "$workspace/src"
  fi

  case "$remote" in
  debian)
      echo "Obtain deb binary for remote packages."
      ;;
  file) # When remote is file, the dependended packages that need to be built from source are downloaded based on $ROSINSTALL_FILENAME file.
      # Prioritize $ROSINSTALL_FILENAME.$ROS_DISTRO if it exists over $ROSINSTALL_FILENAME.
      if [ -e "$TARGET_REPO_PATH/$ROSINSTALL_FILENAME.$ROS_DISTRO" ]; then
          # install (maybe unreleased version) dependencies from source for specific ros version
          wstool merge -t "$workspace/src" "file://$TARGET_REPO_PATH/$ROSINSTALL_FILENAME.$ROS_DISTRO"
      elif [ -e "$TARGET_REPO_PATH/$ROSINSTALL_FILENAME" ]; then
          # install (maybe unreleased version) dependencies from source
          wstool merge -t "$workspace/src file://$TARGET_REPO_PATH/$ROSINSTALL_FILENAME"
      else
          error "remote file '$TARGET_REPO_PATH/$ROSINSTALL_FILENAME[.$ROS_DISTRO]' does not exist"
      fi
      ;;
  http://* | https://*) # When remote is an http url, use it directly
      wstool merge -t "$workspace/src" "$remote"
      ;;
  esac

  # download remote packages into workspace
  if [ -e "$workspace/src/.rosinstall" ]; then
      # ensure that the target is not in .rosinstall
      (cd "$workspace/src; wstool rm $TARGET_REPO_NAME" 2> /dev/null \
       && echo "wstool ignored $TARGET_REPO_NAME found in $workspace/src/.rosinstall file. Its source fetched from your repository is used instead." || true) # TODO: add warn function
      wstool update -t "$workspace/src"
  fi

}

function ici_link_into_workspace {
  ln -sf "$2" "$1/src"
}

function ici_create_workspace {
  local workspace="$1"
  mkdir -p "$workspace/src"

  local remote="$2"

  if [ -n "$remote" ]; then
    ici_merge_remote "$workspace" "$remote"
  fi
}

function ici_setup_rosdep() {
    # Setup rosdep
    rosdep --version
    if ! [ -d /etc/ros/rosdep/sources.list.d ]; then
        sudo rosdep init
    fi
    ret_rosdep=1
    rosdep update || while [ $ret_rosdep != 0 ]; do sleep 1; rosdep update && ret_rosdep=0 || echo "rosdep update failed"; done
}

function ici_rosdep_install {
  local path="$1"
  shift

  rosdep_opts=(-q --from-paths "$path" --ignore-src --rosdistro $ROS_DISTRO -y $@)

  set -o pipefail # fail if rosdep install fails
  rosdep install "${rosdep_opts[@]}" | { grep "executing command" || true; }
  set +o pipefail
}

function ici_install_workspace_dependencies {
  local workspace="$1"

  rosdep_opts=()
  if [ -n "$ROSDEP_SKIP_KEYS" ]; then
    rosdep_opts+=(--skip-keys "$ROSDEP_SKIP_KEYS")
  fi

  ici_rosdep_install "$workspace/src" "${rosdep_opts[@]}"
}
