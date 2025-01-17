#!/usr/bin/env bash

if ! type -f bpkg-utils &>/dev/null; then
  echo "error: bpkg-utils not found, aborting"
  exit 1
else
  # shellcheck source=lib/utils/utils.sh
  source "$(which bpkg-utils)"
fi

if ! type -f bpkg-env &>/dev/null; then
  echo "error: bpkg-env not found, aborting"
  exit 1
else
  # shellcheck disable=SC2230
  # shellcheck source=lib/env/env.sh
  source "$(which bpkg-env)"
fi

bpkg_initrc

usage () {
  mesg=$1
  if [ "$mesg" != "" ]; then
    echo "$mesg"
    echo
  fi
  echo "bpkg-show [-h|--help]"
  echo "bpkg-show <user/package_name>"
  echo "bpkg-show readme <user/package_name>"
  echo "bpkg-show sources <user/package_name>"
  echo
  echo "Show bash package details.  You must first run \`bpkg update' to sync the repo locally."
  echo
  echo "Commands:"
  echo "  readme        Print package README.md file, if available, suppressing other output"
  echo "  sources       Print all sources listed in bpkg.json (or package.json) scripts, in "
  echo "                order. This option suppresses other output and prints executable bash."
  echo
  echo "Options:"
  echo "  -h,--help     Print this help dialogue"
}

show_package () {
  local pkg=$1
  local desc=$2
  local show_readme=$3
  local show_sources=$4
  local remote=$BPKG_REMOTE
  local git_remote=$BPKG_GIT_REMOTE
  local nonce="$(date +%s)"
  local auth=""
  local json=""
  local readme=""
  local uri=""

  if [ "$BPKG_OAUTH_TOKEN" != "" ]; then
    auth="-u $BPKG_OAUTH_TOKEN:x-oauth-basic"
  fi

  if [ "$auth" == "" ]; then
    uri=$BPKG_REMOTE/$pkg/master
  else
    uri=$BPKG_REMOTE/$pkg/raw/master
  fi

  json=$(eval "curl $auth -sL '$uri/bpkg.json?$nonce'" 2>/dev/null)
  if [ "${json}" = '404: Not Found' ];then
    json=$(eval "curl $auth -sL '$uri/package.json?$nonce'" 2>/dev/null)
  fi

  if [ -z "$json" ]; then
    echo 1>&2 "error: Failed to load package JSON"
  fi

  readme=$(eval "curl $auth -sL '$uri/README.md?$nonce'")

  local author install_sh pkg_desc readme_len sources version

  readme_len=$(echo "$readme" | wc -l | tr -d ' ')

  version=$(echo "$json" | bpkg-json -b | grep '"version"' | sed 's/.*version"\]\s*//' | tr -d '\t' | tr -d '"')
  author=$(echo "$json" | bpkg-json -b | grep '"author"' | sed 's/.*author"\]\s*//' | tr -d '\t' | tr -d '"')
  pkg_desc=$(echo "$json" | bpkg-json -b | grep '"description"' | sed 's/.*description"\]\s*//' | tr -d '\t' | tr -d '"')
  sources=$(echo "$json" | bpkg-json -b | grep '"scripts"' | cut -f 2 | tr -d '"' )
  install_sh=$(echo "$json" | bpkg-json -b | grep '"install"' | sed 's/.*install"\]\s*//' | tr -d '\t' | tr -d '"')

  if [ "$pkg_desc" != "" ]; then
    desc="$pkg_desc"
  fi

  if [ "$show_sources" == '0' ] && [ "$show_readme" == "0" ]; then
    echo "Name: $pkg"
    if [ "$author" != "" ]; then
      echo "Author: $author"
    fi
    echo "Description: $desc"
    echo "Current Version: $version"
    echo "Remote: $git_remote"
    if [ "$install_sh" != "" ]; then
      echo "Install: $install_sh"
    fi
    if [ "$readme" == "" ]; then
      echo "README.md: Not Available"
    else
      echo "README.md: ${readme_len} lines"
    fi
  elif [ "$show_readme" != '0' ]; then
    echo "$readme"
  else
    # Show Sources
    OLDIFS="$IFS"
    IFS=$'\n'
    for src in $sources; do
      local content http_code
      http_code=$(eval "curl $auth -sL '$uri/$src?$(date +%s)' -w '%{http_code}' -o /dev/null")
      if (( http_code < 400 )); then
        content=$(eval "curl $auth -sL '$uri/$src?$(date +%s)'")
        echo "#[$src]"
        echo "$content"
        echo "#[/$src]"
      else
        bpkg_warn "source not found: $src"
      fi
    done
    IFS="$OLDIFS"
  fi
}


bpkg_show () {
  local readme=0
  local sources=0
  local pkg=""
  for opt in "$@"; do
    case "$opt" in
      -h|--help)
        usage
        return 0
        ;;
      readme)
        readme=1
        if [ "$sources" == "1" ]; then
          usage "Error: readme and sources are mutually exclusive options"
          return 1
        fi
        ;;
      source|sources)
        sources=1
        if [ "$readme" == "1" ]; then
          usage "Error: readme and sources are mutually exclusive options"
          return 1
        fi
        ;;
      *)
        if [ "${opt:0:1}" == "-" ]; then
          bpkg_error "unknown option: $opt"
          return 1
        fi
        if [ "$pkg" == "" ]; then
          pkg=$opt
        fi
    esac
  done

  if [ "$pkg" == "" ]; then
    usage
    return 1
  fi

  local i=0
  for remote in "${BPKG_REMOTES[@]}"; do
    local git_remote="${BPKG_GIT_REMOTES[$i]}"
    bpkg_select_remote "$remote" "$git_remote"
    if [ ! -f "$BPKG_REMOTE_INDEX_FILE" ]; then
      bpkg_warn "no index file found for remote: ${remote}"
      bpkg_warn "You should run \`bpkg update' before running this command."
      i=$((i+1))
      continue
    fi

    OLDIFS="$IFS"
    IFS=$'\n'

    local line
    while read -r line; do
      local desc name
      name=$(echo "$line" | cut -d\| -f1 | tr -d ' ')
      desc=$(echo "$line" | cut -d\| -f2)
      if [ "$name" == "$pkg" ]; then
        IFS="$OLDIFS"
        show_package "$pkg" "$desc" "$readme" "$sources"
        IFS=$'\n'
        return 0
      fi
    done < "$BPKG_REMOTE_INDEX_FILE"

    IFS="$OLDIFS"
    i=$((i+1))
  done

  bpkg_error "package not found: $pkg"
  return 1
}

if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
  export -f bpkg_show
elif bpkg_validate; then
  bpkg_show "$@"
fi
