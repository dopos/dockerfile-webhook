#!/bin/bash

# This webhook script intended for use inside dcape container
# so in has some noted defaults for it
# But you can change them for your needs.
# See README.md for details.

# ------------------------------------------------------------------------------
# Vars from webhook

MODE=${MODE:-remote}
EVENT=${EVENT:-push}
URL_BRANCH=${URL_BRANCH:-default}
REF=${REF:-refs/heads/master}
REPO_PRIVATE=${REPO_PRIVATE:-false}
SSH_URL=${SSH_URL}
CLONE_URL=${CLONE_URL}
DEFAULT_BRANCH=${DEFAULT_BRANCH:-master}
# COMPARE_URL is empty if hook was raised by "Test delivery" button
COMPARE_URL=${COMPARE_URL:-}

# ------------------------------------------------------------------------------
# Vars from ENV

# dir to place deploys in
#DEPLOY_ROOT

# required secret from hook
#DEPLOY_PASS

# ssh with private key
#GIT_SSH_COMMAND

# Environment vars filename
DEPLOY_CONFIG=${DEPLOY_CONFIG:-.env}
# KV storage key prefix
KV_PREFIX=${KV_PREFIX:-} # "/conf"
# KV storage URI
ENFIST=${ENFIST:-http://enfist:8080/rpc}
# if MODE=local rename git host to this local hostname
LOCAL_GIT_HOST=${LOCAL_GIT_HOST:-gitea}
# App deploy root dir
DEPLOY_PATH=${DEPLOY_PATH:-/$DEPLOY_ROOT/apps}
# Logfiles root dir
DEPLOY_LOG=${DEPLOY_LOG:-/$DEPLOY_ROOT/log/webhook}
# Directory for per project deploy logs
DEPLOY_LOG_DIR=${DEPLOY_LOG_DIR:-$DEPLOY_LOG/deploy}
# Hook logfile
HOOK_LOG=${HOOK_LOG:-$DEPLOY_LOG/webhook.log}
# Git bin used
GIT=${GIT:-git}
# Make bin used
MAKE=${MAKE:-make}
# Tag prefix matched => skip hook run
REF_PREFIX_SKIP=${REF_PREFIX_SKIP:-tmp}
# Tag prefix set and does not match => skip hook run
REF_PREFIX_FILTER=${REF_PREFIX_FILTER:-}

# ------------------------------------------------------------------------------
# Internal config

# KV-store key to allow this hook
VAR_ENABLED="_CI_HOOK_ENABLED"
_CI_HOOK_ENABLED=no

# make hot update without container restart
VAR_UPDATE_HOT="_CI_HOOK_UPDATE_HOT"
_CI_HOOK_UPDATE_HOT="no"

# make target to start app
VAR_MAKE_START="_CI_MAKE_START"
_CI_MAKE_START=start-hook

VAR_MAKE_UPDATE="_CI_MAKE_UPDATE"
_CI_MAKE_UPDATE="update"

VAR_MAKE_STOP="_CI_MAKE_STOP"
_CI_MAKE_STOP="stop"

# ------------------------------------------------------------------------------

# strict mode http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# logging func
log() {
  local dt=$(date "+%F %T")
  echo  "$dt $@"
}

# ------------------------------------------------------------------------------
# prepare deploy.log
deplog_begin() {
  local dest=$1
  shift
  [[ $dest == "-" ]] && return
  local dt=$(date "+%F %T")
  echo "------------------ $dt / $@" >> $dest
}

# ------------------------------------------------------------------------------
# finish deploy.log
deplog_end() {
  local dest=$1
  shift
  [[ $dest == "-" ]] && return
  local dt=$(date "+%F %T")
  echo -e "\n================== $dt" >> $dest
}

# ------------------------------------------------------------------------------
# write line into deploy.log & double it with log()
deplog() {
  local dest=$1
  [[ $dest == "-" ]] && return
  shift
  log $@
  echo $@ >> $dest
}

# ------------------------------------------------------------------------------
# Get value from KV store
kv_read() {
  local path=$1
  local ret=$(curl -gs $ENFIST/tag_vars?code=$path | jq -r .)
  [[ "$ret" == "null" ]] && ret=""
  config=$ret
}
# ------------------------------------------------------------------------------
# Get value from KV store
config_var() {
  local config=$1
  local key=$2
  if [[ "$config" ]] ; then
    local row=$(echo "$config" | grep -E "^$key=")
    if [[ "$row" ]] ; then
      echo "${row#*=}"
      return
    fi
  fi
  echo ${!key} # get value from env
}
# ------------------------------------------------------------------------------
# Parse STDIN as JSON and echo "name=value" pairs
kv2vars() {
  local key=$1
  local r=$(curl -gs $ENFIST/tag_vars?code=$key)
  #echo "# Generated from KV store $key"
  local ret=$(echo "$r" | jq -r .)
  [[ "$ret" == "null" ]] && ret=""
  echo "$ret"
}

# ------------------------------------------------------------------------------
# Parse STDIN as "name=value" pairs and PUT them into KV store
vars2kv() {
  local cmd=$1
  local key=$2
  local q=$(jq -R -sc ". | {\"code\":\"$key\",\"data\":.}")
  # pack newlines, escape doble quotes
  #  local c=$(sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g' | sed 's/"/\\"/g')
  local req=$(curl -gsd "$q" $ENFIST/tag_$cmd)
  # echo $req
}

# ------------------------------------------------------------------------------
# KV store key exists: save to $DEPLOY_CONFIG
# or $DEPLOY_CONFIG exists: load it to KV store
# else: generate default $DEPLOY_CONFIG and save it to KV store
env_setup() {
  local config=$1
  local key=$2

  # Get data from KV store
  if [[ "$config" ]] ; then
    log "Save KV $key into $DEPLOY_CONFIG"
    echo "$config" > $DEPLOY_CONFIG
    return
  fi

  if [ -f $DEPLOY_CONFIG ] ; then
    log "Load KV $key from $DEPLOY_CONFIG"
    cat $DEPLOY_CONFIG | vars2kv set $key
    config=$(cat $DEPLOY_CONFIG)
    return
  fi

  log "Load KV $key from default config"
  $MAKE $DEPLOY_CONFIG || true
  log "Default config generated"
  cat $DEPLOY_CONFIG | vars2kv set $key
  local row=$(grep -E "^$VAR_ENABLED=" $DEPLOY_CONFIG)
  [[ "$row" ]] || echo "${VAR_ENABLED}=${_CI_HOOK_ENABLED}" | vars2kv append $key
  local row=$(grep -E "^$VAR_UPDATE_HOT=" $DEPLOY_CONFIG)
  [[ "$row" ]] || echo "${VAR_UPDATE_HOT}=${_CI_HOOK_UPDATE_HOT}" | vars2kv append $key
  log "Prepared default config"
}

# ------------------------------------------------------------------------------
# Run 'make stop' if Makefile exists
make_stop() {
  local path=$1
  local cmd=$2
  if [ -f $path/Makefile ] ; then
    pushd $path > /dev/null
    log "$MAKE $cmd"
    $MAKE $cmd
    popd > /dev/null
  fi
}

# ------------------------------------------------------------------------------
# Check that ENV satisfies conditions
condition_check() {

  if [[ "$DEPLOY_PASS" != "$SECRET" ]] ; then
    log "Hook aborted: password does not match"
    exit 10
  fi

   # repository url
  if [[ "$REPO_PRIVATE" == "true" ]] ; then
    repo=$SSH_URL
    # "ssh_url": "git@git.dev.lan:jean/dcape-app-powerdns.git",
    local r0=${repo#*:}         # remove 'git@git.dev.lan:'
    # TODO: gitea for "create" event sends ssh_url as
    #   git@gitea:/jean/dcape-app-powerdns.git
    # instead
    #   git@gitea:jean/dcape-app-powerdns.git
    r0=${r0#/} # gitea workaround
    repo=${repo/:\//:} # gitea workaround
    # dcape on same host, replace hostname
    [[ "$MODE" == "local" ]] && repo=${repo/@*:/@$LOCAL_GIT_HOST:}
  else
    repo=$CLONE_URL
    # "clone_url": "http://git.dev.lan/jean/dcape-app-powerdns.git",
    local r0=${repo#*//*/}         # remove 'https?://git.dev.lan/'

    [[ "$MODE" == "local" ]] && repo="http://$LOCAL_GIT_HOST:3000/$r0" # gitea listens port port 3000 internally
  fi

  local r1=${r0%.git} # remove suffix
  repoid=${r1/\//--}  # org/project -> org--project

  if [[ ! "$repo" ]] ; then
    log "Hook skipped: repository.{ssh,clone}_url key empty in payload (private:$REPO_PRIVATE)"
    exit 11
  fi

  # TODO: support for "git push --tags"
  if [[ "$EVENT" != "push" ]] && [[ "$EVENT" != "create" ]]; then
    log "Hook skipped: only push & create supported, but received '$EVENT'"
    exit 12
  fi

  # ref/branch name
  local changed_ref=${REF#refs/heads/}

  # the record separator of the events in the log
  log "  "
  log " ------- new event in hook ------- "

  # if config URL contains "-rm" suffix start remove deploy procedure
  # or report an error if push event with "-rm" suffix on URL config
  if [[ ${URL_BRANCH%-rm} != "$URL_BRANCH" ]] ; then
   # check the event witch initiated deployment, if "Test delivery" - make a remove, if push - skip deploy, report about error config URL
   if [[ ! "$COMPARE_URL" ]] ; then
     # check config URL for the presence of "default" string
     # if presence - use branch name from gitea data, if none - use branch name fron URL config
     if [[ ${URL_BRANCH} == default-rm ]] ; then
       log "Found request to a remove deploy by button *Test delivery* and config URL=default-rm"
       log "Config ok, reremove deployment for branch ($DEFAULT_BRANCH) configured as the default on repository"
       ref=${DEFAULT_BRANCH}-rm
     else
       log "Found request to remove deploy by button *Test delivery* and config URL=$URL_BRANCH"
       log "Config ok, remove deployment for branch (${URL_BRANCH%-rm})"
       ref=$URL_BRANCH
     fi
   else
     log "Found request to perform a deployment by push event and config URL=default-rm or URL=NAME-rm"
     log "Wrong config URL, the deployment was skipped. Use config URL without (-rm) suffix for success deploy"
     exit 13
   fi

  # if config URL does not contain "-rm" - check for URL=default
  elif [[ ${URL_BRANCH} == default ]] ; then
    # check the event witch initiated deployment, if "Test delivery" - make a remove default branch
    if [[ ! "$COMPARE_URL" ]] ; then
      log "Found request to a deploy by button *Test delivery* and config URL=default"
      log "Branch ($DEFAULT_BRANCH) the default branch in the repository settings"
      log "Config ok, make deploy a branch ($DEFAULT_BRANCH)"
      ref=$DEFAULT_BRANCH
    else
      if [[ "$changed_ref" == "$DEFAULT_BRANCH" ]] ; then
        log "Found request to a deploy by push event for branch ($changed_ref) and config URL=default"
        log "Branch ($changed_ref) the default branch in the repository settings"
        log "Config ok, make deploy a branch ($changed_ref)"
        ref=$changed_ref
      else
        log "Found request to a deploy by push event for branch ($changed_ref) and config URL=default"
        log "Wrong config, skipped deploy. Pushed branch ($changed_ref) not a default branch in repository"
        exit 14
      fi
    fi

  # if config from URL = all and have push event for repo - start of deployment of the modified branch
  elif [[ $URL_BRANCH = "all" ]] ; then
    # check the events witch initiated deployment
    if [[ ! "$COMPARE_URL" ]] ; then
      log "Found request a deployment by button (Test delivery) and URL=all"
      log "Wrong config, skipped deploy. Use URL=NAME or URL=default for successfuly deployment"
      exit 15
    else
      log "Found request a deployment with push event on branch ($changed_ref) and config URL=all"
      log "Config ok, performing a deployment"
      ref=$changed_ref
    fi

  # if push branch with name equal NAME from config URL=NAME - make a deploy for branch NAME
  elif [[ "$URL_BRANCH" == "$changed_ref" && "$COMPARE_URL" ]] ; then
    log "Found request to a deploy by push event on branch ($changed_ref) and config URL=$URL_BRANCH"
    log "Config ok, make a deploy for branch ($changed_ref)"
    ref=$changed_ref

  elif [[ "$URL_BRANCH" != "$changed_ref" && "$COMPARE_URL" ]] ; then
    log "Found request to a deploy by push event on branch ($changed_ref) and config URL=$URL_BRANCH"
    log "Wrong config, modified branch name not equal to config URL, skipped deploy"
    exit 16

  # if the button "Test delivery" was pressed and config URL=NAME - make deploy for branch NAME
  elif [[ ! "$COMPARE_URL" ]] ; then
    log "Found request to a deploy by button *Test delivery* and config URL=$URL_BRANCH"
    log "Config ok, make a deploy for branch ($URL_BRANCH)"
    ref=$URL_BRANCH

  # if not found any variants for make deploy - report to log
  else
    log "Not found valid request and config URL for deploy"
  fi

  if [[ $ref != ${ref#$REF_PREFIX_SKIP} ]] ; then
    log "Hook skipped: ($REF_PREFIX_SKIP) matched"
    exit 17
  fi

  if [[ "$REF_PREFIX_FILTER" ]] && [[ $ref == ${ref#$REF_PREFIX_FILTER} ]] ; then
    log "Hook skipped: ($ref) ($REF_PREFIX_FILTER) does not matched"
    exit 18
  fi
}

# ------------------------------------------------------------------------------

process() {

  local repo
  local repoid
  local ref
  condition_check

  local deploy_dir="${repoid}--$ref"

  local config
  kv_read $deploy_dir

  local deploy_key=$KV_PREFIX$deploy_dir
  pushd $DEPLOY_PATH > /dev/null

  # Cleanup old distro
  if [[ ${ref%-rm} != $ref ]] ; then
    local rmtag=${ref%-rm}
    log "$repo $rmtag"
    deploy_dir="${repoid}--$rmtag"
    log "Requested cleanup for $deploy_dir"
    if [ -d $deploy_dir ] ; then
      log "Removing $deploy_dir..."
      local make_cmd=$(config_var "$config" $VAR_MAKE_STOP)
      make_stop $deploy_dir $make_cmd
      rm -rf $deploy_dir || { log "rmdir error: $!" ; exit $? ; }
    fi
    local deplog_file="$DEPLOY_LOG_DIR/$deploy_dir.log"
    [ -f $deplog_file ] && rm $deplog_file
    log "Cleanup complete"
    exit 0
  fi

  # check if hook is set and disabled
  # continue setup otherwise
  local enabled=$(config_var "$config" $VAR_ENABLED)

  # check if deploy disabled directly (and not empty)
  if [[ "$config" ]] && [[ "$enabled" == "no" ]] ; then
    log "Hook skipped: $VAR_ENABLED value disables hook because equal to 'no'"
    exit 19
  fi

  local hot_enabled=$(config_var "$config" $VAR_UPDATE_HOT)

  # deploy per project log directory
  local deplog_dest

  if [ -d $DEPLOY_LOG_DIR ] || mkdir -pm 777 $DEPLOY_LOG_DIR ; then
    deplog_dest="$DEPLOY_LOG_DIR/$deploy_dir.log"
  else
    echo "mkdir $DEPLOY_LOG_DIR error, disable deploy logging"
    deplog_dest="-"
  fi

  if [[ "$hot_enabled" == "yes" ]] && [ -d $deploy_dir ] ; then
    log "Requested hot update for $deploy_dir..."
    pushd $deploy_dir > /dev/null
    if [ -f Makefile ] ; then
      log "Setup hot update.."
      env_setup "$config" $deploy_key
    fi
    local make_cmd=$(config_var "$config" $VAR_MAKE_UPDATE)
    log "Pull..."
    $GIT fetch && $GIT reset --hard origin/$ref
    $GIT pull --recurse-submodules 2>&1 || { echo "Pull error: $?" ; exit 21 ; }
    log "Pull submodules..."
    $GIT submodule update --recursive --remote 2>&1 || { echo "Submodule error: $?" ; exit 22 ; }
    if [[ "$make_cmd" != "" ]] ; then
      log "Starting $MAKE $make_cmd..."
      deplog_begin $deplog_dest $make_cmd
      # NOTE: This command must start container if it does not running
      $MAKE $make_cmd >> $deplog_dest 2>&1
      deplog_end $deplog_dest
    fi
    popd > /dev/null
    log "Hot update completed"
    return
  fi

  if [ -d $deploy_dir ] ; then
    log "ReCreating $deploy_dir..."
    local make_cmd=$(config_var "$config" $VAR_MAKE_STOP)
    make_stop $deploy_dir $make_cmd
    rm -rf $deploy_dir || { log "Recreate rmdir error: $!" ; exit $? ; }
  else
    # git clone will create it if none but we have to check permissions
    log "Creating $deploy_dir..."
    mkdir -p $deploy_dir || { log "Create mkdir error: $!" ; exit $? ; }
  fi
  log "Clone $repo / $ref..."
  log "git clone --depth=1 --recursive --branch $ref $repo $deploy_dir"
  $GIT clone --depth=1 --recursive --branch $ref $repo $deploy_dir || { echo "Clone error: $?" ; exit 23 ; }
  pushd $deploy_dir > /dev/null

  if [ -f Makefile ] ; then
    log "Setup $deploy_dir..."

    env_setup "$config" $deploy_key

    # check if hook was not enabled directly (ie if empty)
    if [[ "$enabled" != "yes" ]] ; then
      log "Hook skipped: $VAR_ENABLED value disables hook because not equal to 'yes' ($enabled)"
      popd > /dev/null # deploy_dir
      # Setup loaded in kv and nothing started
      rm -rf $deploy_dir || { log "rmdir error: $!" ; exit $? ; }
      exit 20
    fi
    local make_cmd=$(config_var "$config" $VAR_MAKE_START)
    log "Starting $MAKE $make_cmd..."
    deplog_begin $deplog_dest $make_cmd
    $MAKE $make_cmd >> $deplog_dest 2>&1
    deplog_end $deplog_dest
  fi
  popd > /dev/null # deploy_dir
  popd > /dev/null # DEPLOY_PATH
  log "Deploy completed"
}

process >> $HOOK_LOG 2>&1
