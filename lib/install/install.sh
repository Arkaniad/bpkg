#!/usr/bin/env bash
if ! type -f bpkg-logging &>/dev/null; then
  echo "error: bpkg-logging not found, aborting"
  exit 1
else
  # shellcheck source=lib/logging/logging.sh
  source "$(which bpkg-logging)"
fi

if ! type -f bpkg-url &>/dev/null; then
  echo "error: bpkg-url not found, aborting"
  exit 1
else
  # shellcheck source=lib/url/url.sh
  source "$(which bpkg-url)"
fi

if ! type -f bpkg-realpath &>/dev/null; then
  echo "error: bpkg-realpath not found, aborting"
  exit 1
else
  # shellcheck disable=SC2230
  # shellcheck source=lib/realpath/realpath.sh
  source "$(which bpkg-realpath)"
fi

if ! type -f bpkg-utils &>/dev/null; then
  echo "error: bpkg-utils not found, aborting"
  exit 1
else
  # shellcheck disable=SC2230
  # shellcheck source=lib/utils/utils.sh
  source "$(which bpkg-utils)"
fi

if ! type -f bpkg-getdeps &>/dev/null; then
  echo "error: bpkg-getdeps not found, aborting"
  exit 1
else
  # shellcheck disable=SC2230
  # shellcheck source=lib/getdeps/getdeps.sh
  source "$(which bpkg-getdeps)"
fi

bpkg_initrc

let prevent_prune=0
let force_actions=${BPKG_FORCE_ACTIONS:-0}
let needs_global=0

## check parameter consistency
validate_parameters() {
  if [[ ${#BPKG_GIT_REMOTES[@]} -ne ${#BPKG_REMOTES[@]} ]]; then
    bpkg_error "$(printf 'BPKG_GIT_REMOTES[%d] differs in size from BPKG_REMOTES[%d] array' "${#BPKG_GIT_REMOTES[@]}" "${#BPKG_REMOTES[@]}")"
    return 1
  fi
  return 0
}

## outut usage
usage() {
  echo 'usage: bpkg-install [directory]'
  echo '   or: bpkg-install [-h|--help]'
  echo '   or: bpkg-install [-g|--global] [-f|--force] ...<package>'
  echo '   or: bpkg-install [-g|--global] [-f|--force] ...<user>/<package>'
}

## Install a bash package
bpkg_install() {
  local pkg=''
  local did_fail=1
  local auth_info=''

  for opt in "${@}"; do
    if [[ '-' = "${opt:0:1}" ]]; then
      continue
    fi
    pkg="${opt}"
    break
  done

  for opt in "${@}"; do
    case "${opt}" in
    -h | --help)
      _usage
      return 0
      ;;

    -g | --global)
      shift
      needs_global=1
      ;;
    *)
      if [[ '-' = "${opt:0:1}" ]]; then
        echo 2>&1 "error: Unknown argument \`${1}'"
        _usage
        return 1
      fi
      ;;
    esac
  done

  ## ensure there is a package to install
  if [[ -z "${pkg}" ]]; then
    _usage
    return 1
  fi

  export BPKG_FORCE_ACTIONS=$force_actions

  echo

  if bpkg_is_local_path "${pkg}"; then
    #shellcheck disable=SC2164
    pkg="file://$(
      cd "${pkg}"
      pwd
    )"
  fi

  if bpkg_has_auth_info "${pkg}"; then
    auth_info="$(bpkg_parse_auth_info "${pkg}")"
    bpkg_debug "auth_info" "${auth_info}"

    pkg="$(bpkg_remove_auth_info "${pkg}")"
    bpkg_debug "pkg" "${pkg}"
  fi

  if bpkg_is_full_url "${pkg}"; then
    bpkg_debug "parse" "${pkg}"

    local bpkg_remote_proto bpkg_remote_host bpkg_remote_path bpkg_remote_uri

    bpkg_remote_proto="$(bpkg_parse_proto "${pkg}")"

    if bpkg_is_local_path "${pkg}"; then
      bpkg_remote_host="/$(bpkg_parse_host "${pkg}")"
    else
      bpkg_remote_host="$(bpkg_parse_host "${pkg}")"
    fi

    bpkg_remote_path=$(bpkg_parse_path "${pkg}")
    bpkg_remote_uri="${bpkg_remote_proto}://${bpkg_remote_host}"

    bpkg_debug "proto" "${bpkg_remote_proto}"
    bpkg_debug "host" "${bpkg_remote_host}"
    bpkg_debug "path" "${bpkg_remote_path}"

    BPKG_REMOTES=("${bpkg_remote_uri}" "${BPKG_REMOTES[@]}")
    BPKG_GIT_REMOTES=("${bpkg_remote_uri}" "${BPKG_GIT_REMOTES[@]}")
    pkg="$(echo "${bpkg_remote_path}" | bpkg_esed "s|^\/(.*)|\1|")"

    if bpkg_is_coding_net "${bpkg_remote_host}"; then
      # update /u/{username}/p/{project} to {username}/{project}
      bpkg_debug "reset pkg for coding.net"
      pkg="$(echo "${pkg}" | bpkg_esed "s|\/?u\/([^\/]+)\/p\/(.+)|\1/\2|")"
    fi

    bpkg_debug "pkg" "${pkg}"
  fi

  ## Check each remote in order
  local i=0
  for remote in "${BPKG_REMOTES[@]}"; do
    local git_remote=${BPKG_GIT_REMOTES[$i]}
    if bpkg_install_from_remote "$pkg" "$remote" "$git_remote" $needs_global "$auth_info"; then
      did_fail=0
      break
    elif [[ "$?" == '2' ]]; then
      bpkg_error 'fatal error occurred during install'
      return 1
    fi
    i=$((i + 1))
  done

  if ((did_fail == 1)); then
    bpkg_error 'package not found on any remote'
    return 1
  fi

  return 0
}

## try to install a package from a specific remote
## returns values:
##   0: success
##   1: the package was not found on the remote
##   2: a fatal error occurred
bpkg_install_from_remote() {
  local pkg=$1
  local remote=$2
  local git_remote=$3
  local needs_global=$4
  local auth_info=$5

  local url=''
  local uri=''
  local version=''
  local json=''
  local user=''
  local name=''
  local repo=''
  local version=''
  local auth_param=''
  local has_pkg_json=0
  local package_file=''

  declare -a pkg_parts=()
  declare -a remote_parts=()
  declare -a scripts=()
  declare -a files=()

  bpkg_debug "pkg" "${pkg}"
  ## get version if available
  pkg_parts=(${pkg/@/ })
  bpkg_debug "pkg_parts" "${pkg_parts[@]}"

  if [[ ${#pkg_parts[@]} -eq 1 ]]; then
    version='main'
    #bpkg_info "Using latest (master)"
  elif [[ ${#pkg_parts[@]} -eq 2 ]]; then
    name="${pkg_parts[0]}"
    version="${pkg_parts[1]}"
  else
    bpkg_error 'Error parsing package version'
    return 1
  fi

  ## split by user name and repo
  pkg_parts=(${pkg//\// })
  bpkg_debug "pkg_parts" "${pkg_parts[@]}"

  if [[ ${#pkg_parts[@]} -eq 0 ]]; then
    bpkg_error 'Unable to determine package name'
    return 1
  elif [[ ${#pkg_parts[@]} -eq 1 ]]; then
    user="${BPKG_USER}"
    name="${pkg_parts[0]}"
  else
    name="${pkg_parts[${#pkg_parts[@]} - 1]}"
    unset pkg_parts[${#pkg_parts[@]}-1]
    pkg_parts=("${pkg_parts[@]}")
    user="$(
      IFS='/'
      echo "${pkg_parts[*]}"
    )"
  fi

  ## clean up name of weird trailing
  ## versions and slashes
  name=${name/@*//}
  name=${name////}

  ## Adapter to different kind of git hosting services
  if bpkg_is_coding_net "${remote}"; then
    uri="/u/${user}/p/${name}/git/raw/${version}"
  elif bpkg_is_github_raw "${remote}"; then
    uri="/${user}/${name}/${version}"
  elif bpkg_is_local_path "${remote}"; then
    uri="/${user}/${name}"
  else
    uri="/${user}/${name}/raw/${version}"
  fi

  bpkg_debug "uri: $uri"
  bpkg_debug "auth_info: $auth_info"
  bpkg_debug "remote: $remote"

  if [[ -n "${auth_info}" ]]; then
    OLDIFS="$IFS"
    IFS="|"
    local auth_info_parts
    read -r -a auth_info_parts <<<"$auth_info"
    IFS="$OLDIFS"
    local auth_method="${auth_info_parts[0]}"
    local auth_token="${auth_info_parts[1]}"
    bpkg_debug "auth method: $auth_method, auth_token: $auth_token"

    ## check to see if remote is raw with oauth (GHE)
    if [[ "$auth_method" == "raw-oauth" ]]; then
      bpkg_info 'Using OAUTH basic with content requests'
      auth_param="-u $auth_token:x-oauth-basic"

      ## If git remote is a URL, and doesn't contain token information, we
      ## inject it into the <user>@host field
      if [[ "$git_remote" == https://* ]] && [[ "$git_remote" != *x-oauth-basic* ]] && [[ "$git_remote" != *$auth_token* ]]; then
        git_remote=${git_remote/https:\/\//https:\/\/$auth_token:x-oauth-basic@}
      fi
    elif [[ "${auth_method}" == "raw-access" ]]; then
      bpkg_info "Using PRIVATE-TOKEN header"
      auth_param="--header 'PRIVATE-TOKEN: $auth_token'"
    fi
  fi

  ## clean up extra slashes in uri
  uri=${uri/\/\///}
  bpkg_info "Install $uri from remote $remote [$git_remote]"

  ## Ensure remote is reachable
  ## If a remote is totally down, this will be considered a fatal
  ## error since the user may have intended to install the package
  ## from the broken remote.
  {
    if ! bpkg_url_exists "$remote" "$auth_param"; then
      bpkg_error "Remote unreachable: $remote"
      return 2
    fi
  }

  ## build url
  url="${remote}${uri}"
  local nonce="$(date +%s)"

  if bpkg_is_coding_net "${remote}"; then
    repo_url="${git_remote}/u/${user}/p/${name}/git"
  elif bpkg_is_local_path "${remote}"; then
    repo_url="${git_remote}/${user}/${name}"
  else
    repo_url="${git_remote}/${user}/${name}.git"
  fi

  package_file="bpkg.json"

  package_json_url="${url}/${package_file}?$nonce"
  makefile_url="${url}/Makefile?$nonce"

  if bpkg_is_local_path "${url}"; then
    package_json_url="${url}/${package_file}"
    makefile_url="${url}/Makefile"
  fi

  {
    if ! bpkg_url_exists "${package_json_url}" "${auth_param}"; then
      bpkg_warn "$package_file doesn't exist"
      has_pkg_json=1
      # check to see if there's a Makefile. If not, this is not a valid package
      if ! bpkg_url_exists "${makefile_url}" "${auth_param}"; then
        bpkg_error "Makefile not found, skipping remote: $url"
        return 1
      fi
    fi
  }

  ## read package.json
  json=$(bpkg_read_package_json "${package_json_url}" "${auth_param}")
  bpkg_debug "json: $json"

  if ((0 == has_pkg_json)); then
    ## get package name from 'bpkg.json' or 'package.json'
    name="$(
      echo -n "$json" |
        bpkg-json -b |
        grep -m 1 '"name"' |
        awk '{ $1=""; print $0 }' |
        tr -d '\"' |
        tr -d ' '
    )"

    ## get package name from 'bpkg.json' or 'package.json'
    repo="$(
      echo -n "$json" |
        bpkg-json -b |
        grep -m 1 '"repo"' |
        awk '{ $1=""; print $0 }' |
        tr -d '\"' |
        tr -d ' '
    )"

    ## check if forced global
    if [[ "$(echo -n "$json" | bpkg-json -b | grep '\["global"\]' | awk '{ print $2 }' | tr -d '"')" == 'true' ]]; then
      needs_global=1
    fi

    bpkg_debug "name: $name, repo: $repo"
    ## construct scripts array
    {
      scripts=($(echo -n "$json" | bpkg-json -b | grep '\["scripts' | awk '{ print $2 }' | tr -d '"'))

      ## multilines to array
      new_scripts=()
      while read -r script; do
        new_scripts+=("${script}")
      done <<<"${scripts}"

      ## account for existing space
      scripts=("${new_scripts[@]}")
    }

    ## construct files array
    {
      files=($(echo -n "$json" | bpkg-json -b | grep '\["files' | awk '{ print $2 }' | tr -d '"'))

      ## multilines to array
      new_files=()
      while read -r file; do
        new_files+=("${file}")
      done <<<"${files}"

      ## account for existing space
      files=("${new_files[@]}")
    }
  fi

  if [ -n "$repo" ]; then
    repo_url="$repo"
  else
    repo_url="$git_remote/$user/$name.git"
  fi

  bpkg_debug "repo_url: $repo_url"
  if ((1 == needs_global)); then
    bpkg_info "Install ${url} globally"
  fi

  ## build global if needed
  if ((1 == needs_global)); then
    if ((0 == has_pkg_json)); then
      ## install bin if needed
      build="$(echo -n "$json" | bpkg-json -b | grep '\["install"\]' | awk '{$1=""; print $0 }' | tr -d '\"')"
      build="$(echo -n "$build" | sed -e 's/^ *//' -e 's/ *$//')"
    fi

    bpkg_debug "build: $build"

    if [[ -z "${build}" ]]; then
      bpkg_warn "Missing build script"
      bpkg_warn "Trying \`make install\`..."
      build="make install"
    fi

    if [ -z "$PREFIX" ]; then
      if [ "$USER" == "root" ]; then
        PREFIX="/usr/local"
      else
        PREFIX="$HOME/.local"
      fi
      build="env PREFIX=$PREFIX $build"
    fi

    { (
      ## go to tmp dir
      cd "$([[ ! -z "${TMPDIR}" ]] && echo "${TMPDIR}" || echo /tmp)" &&
        ## prune existing
        rm -rf "${name}-${version}" &&
        ## shallow clone
        bpkg_info "Cloning ${repo_url} to ${name}-${version}" &&
        git clone "${repo_url}" "${name}-${version}" &&
        (
          ## move into directory
          cd "${name}-${version}" &&
            git checkout ${version} &&
            ## wrap
            for script in $scripts; do (
              local script="$(echo $script | xargs basename)"

              if [[ "${script}" ]]; then
                cp -f "$(pwd)/${script}" "$(pwd)/${script}.orig"
                _wrap_script "$(pwd)/${script}.orig" "$(pwd)/${script}" "${break_mode}"
              fi
            ); done &&
            ## build
            bpkg_info "Performing install: \`${build}'" &&
            eval "${build}"
        ) &&
        ## clean up
        rm -rf "${name}-${version}"
    ); }
  ## perform local install otherwise
  else
    ## copy 'bpkg.json' or 'package.json' over
    bpkg_save_remote_file "${url}/bpkg.json" "${install_sharedir}/bpkg.json" "${auth_param}"

    ## make '$BPKG_PACKAGE_DEPS/' directory if possible
    mkdir -p "$BPKG_PACKAGE_DEPS/$name"

    ## make '$BPKG_PACKAGE_DEPS/bin' directory if possible
    mkdir -p "$BPKG_PACKAGE_DEPS/bin"

    # install package dependencies
    bpkg_info "Install dependencies for $name"
    (cd "$BPKG_PACKAGE_DEPS/$name" && bpkg_getdeps)

    ## grab each script and place in deps directory
    for script in "${scripts[@]}"; do
      (
        if [[ "$script" ]]; then
          local scriptname="$(echo "$script" | xargs basename)"

          bpkg_info "fetch" "$url/$script"
          bpkg_warn "BPKG_PACKAGE_DEPS is '$BPKG_PACKAGE_DEPS'"
          bpkg_info "write" "$BPKG_PACKAGE_DEPS/$name/$script"
          save_remote_file "$url/$script" "$BPKG_PACKAGE_DEPS/$name/$script" "$auth_param"

          scriptname="${scriptname%.*}"
          bpkg_info "$scriptname to PATH" "$BPKG_PACKAGE_DEPS/bin/$scriptname"

          if ((force_actions == 1)); then
            ln -sf "$BPKG_PACKAGE_DEPS/$name/$script" "$BPKG_PACKAGE_DEPS/bin/$scriptname"
          else
            if test -f "$BPKG_PACKAGE_DEPS/bin/$scriptname"; then
              bpkg_warn "'$BPKG_PACKAGE_DEPS/bin/$scriptname' already exists. Overwrite? (yN)"
              read -r yn
              case $yn in
              Yy) rm -f "$BPKG_PACKAGE_DEPS/bin/$scriptname" ;;
              *) return 1 ;;
              esac
            fi

            ln -s "$BPKG_PACKAGE_DEPS/$name/$script" "$BPKG_PACKAGE_DEPS/bin/$scriptname"
          fi
          chmod u+x "$BPKG_PACKAGE_DEPS/bin/$scriptname"
        fi
      )
    done

    if [[ "${#files[@]}" -gt '0' ]]; then
      ## grab each file and place in correct directory
      for file in "${files[@]}"; do
        (
          if [[ "$file" ]]; then
            bpkg_info "fetch" "$url/$file"
            bpkg_warn "BPKG_PACKAGE_DEPS is '$BPKG_PACKAGE_DEPS'"
            bpkg_info "write" "$BPKG_PACKAGE_DEPS/$name/$file"
            save_remote_file "$url/$file" "$BPKG_PACKAGE_DEPS/$name/$file" "$auth_param"
          fi
        )
      done
    fi
  fi
  return 0
}

## Use as lib or perform install
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
  export -f bpkg_install
elif validate_parameters; then
  bpkg_install "$@"
  exit $?
else
  #param validation failed
  exit $?
fi
