#!/usr/bin/env bash
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
ISOLATOR_ROOT="$(cd "$(dirname "$self")/.." && pwd -P)"
BASH_DIR="$ISOLATOR_ROOT/bash"
PROJECTS_ROOT="$ISOLATOR_ROOT/projects"
PROFILES_DIR="$ISOLATOR_ROOT/profiles"
TRUSTED_DIR="$ISOLATOR_ROOT/trusted"
STATE_HOME="${DOCKER_ISOLATOR_STATE_HOME:-${XDG_STATE_HOME:-${HOME:?}/.local/state}/docker-isolator}"
CONTAINER_ROOT='/home/ubuntu/host'
CONTAINER_CODEX_HOME='/home/ubuntu/.codex'
CONTAINER_UID=1000
CONTAINER_GID=1000

# shellcheck source=lib/config.sh
source "$BASH_DIR/lib/config.sh"

fail() { echo "docker-isolator: $*" >&2; exit 1; }
warn() { echo "docker-isolator: warning: $*" >&2; }
note() { echo "docker-isolator: $*" >&2; }

usage() {
  cat <<'USAGE'
Usage:
  docker-isolator launch   [PATH] [--profile NAME] [--container NAME] [--git-mode MODE]
  docker-isolator repair   [PATH] [--profile NAME] [--container NAME] [--git-mode MODE] [--yes] [--no-launch]
  docker-isolator doctor   [PATH] [--profile NAME] [--container NAME] [--git-mode MODE]
  docker-isolator describe [PATH] [--profile NAME] [--container NAME] [--git-mode MODE]

PATH defaults to the current directory and must resolve inside this checkout's
projects/ directory. Put untrusted repositories under projects/, for example:

  docker-isolator/projects/skg
  docker-isolator/projects/midi/worktrees/main

Git modes:
  protected-shared  Agent commits update the host Git DB. Git config/hooks and
                    linked-worktree .git pointers are protected read-only, but
                    refs/objects are shared (so sibling worktrees are NOT Git-
                    isolated from one another).
  readonly          Worktree files remain writable, but Git metadata is read-only.

Environment overrides:
  DOCKER_ISOLATOR_IMAGE, DOCKER_ISOLATOR_STATE_HOME,
  DOCKER_ISOLATOR_MEMORY, DOCKER_ISOLATOR_CPUS,
  DOCKER_ISOLATOR_PIDS_LIMIT, DOCKER_ISOLATOR_LEGACY_CODEX, SKG_CONFIG
USAGE
}

sanitize_name() {
  local x="$1"
  x="$(printf '%s' "$x" | sed 's/[^A-Za-z0-9_.-]/-/g')"
  [[ "$x" =~ ^[A-Za-z0-9] ]] || x="x-$x"
  printf '%s\n' "$x"
}

is_under() {
  local child="$1" parent="$2"
  [ "$child" = "$parent" ] || [[ "$child" == "$parent"/* ]]
}

canonical_existing_dir() {
  local p="$1"
  [ -d "$p" ] || fail "not a directory: $p"
  (cd "$p" && pwd -P)
}

validate_mount_path() {
  local p="$1" label="$2"
  case "$p" in
    *','*|*$'\n'*|*$'\r'*) fail "$label contains a comma or newline, which is unsafe/ambiguous in Docker --mount syntax: $p" ;;
  esac
}

# Resolve Git metadata path text without asking Git to interpret untrusted
# repository configuration. This also works with Git's relative-worktree
# extension even on a host whose Git is too old to understand that extension.
resolve_git_path_text() {
  local base="$1" line="$2" candidate
  [ -n "$line" ] || fail "empty Git metadata path"
  case "$line" in
    /*) candidate="$line" ;;
    *) candidate="$base/$line" ;;
  esac
  realpath -e -- "$candidate"
}

read_origin_url() {
  local config="$1"
  [ -f "$config" ] || return 0
  awk '
    /^[[:space:]]*\[remote[[:space:]]+"origin"\][[:space:]]*$/ { in_origin=1; next }
    /^[[:space:]]*\[/ { in_origin=0 }
    in_origin && /^[[:space:]]*url[[:space:]]*=/ {
      line=$0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      sub(/[[:space:]]+$/, "", line)
      print line
      exit
    }
  ' "$config"
}

read_core_bare() {
  local config="$1"
  [ -f "$config" ] || return 0
  awk '
    /^[[:space:]]*\[core\][[:space:]]*$/ { in_core=1; next }
    /^[[:space:]]*\[/ { in_core=0 }
    in_core && /^[[:space:]]*bare[[:space:]]*=/ {
      line=$0; sub(/^[^=]*=[[:space:]]*/, "", line); gsub(/[[:space:]]/, "", line)
      print tolower(line); exit
    }
  ' "$config"
}

find_worktree_root() {
  local p="$1"
  while :; do
    # projects/ itself is never a project, even if it holds a stray .git
    # (e.g. from running 'git init' one directory too high).
    [ "$p" != "$PROJECTS_ROOT" ] || break
    if [ -e "$p/.git" ] || [ -L "$p/.git" ]; then
      printf '%s\n' "$p"
      return 0
    fi
    [ "$(dirname "$p")" != "$p" ] || break
    p="$(dirname "$p")"
  done
  return 1
}

parse_git_layout() {
  TARGET="$(canonical_existing_dir "$TARGET_INPUT")"
  is_under "$TARGET" "$PROJECTS_ROOT" \
    || fail "target must resolve under $PROJECTS_ROOT (got $TARGET)"

  local rel child_rest git_entry pointer gitdir_text commondir_text bare
  rel="${TARGET#"$PROJECTS_ROOT"/}"
  [ "$rel" != "$TARGET" ] || fail "target must be below $PROJECTS_ROOT"
  FAMILY_NAME="${rel%%/*}"
  [ -n "$FAMILY_NAME" ] || fail "could not derive project family from $TARGET"
  FAMILY_ROOT="$PROJECTS_ROOT/$FAMILY_NAME"
  FAMILY_ROOT="$(canonical_existing_dir "$FAMILY_ROOT")"

  WT_TOP="$(find_worktree_root "$TARGET")" \
    || fail "could not find a .git entry between $TARGET and $PROJECTS_ROOT"
  WT_TOP="$(canonical_existing_dir "$WT_TOP")"
  is_under "$WT_TOP" "$FAMILY_ROOT" \
    || fail "worktree escapes project family root: $WT_TOP"

  git_entry="$WT_TOP/.git"
  [ ! -L "$git_entry" ] || fail "refusing symlinked worktree .git entry: $git_entry"
  if [ -d "$git_entry" ]; then
    GIT_ENTRY_KIND='directory'
    GIT_DIR="$(canonical_existing_dir "$git_entry")"
  elif [ -f "$git_entry" ]; then
    GIT_ENTRY_KIND='file'
    IFS= read -r pointer < "$git_entry" || fail "could not read $git_entry"
    case "$pointer" in
      gitdir:\ *) gitdir_text="${pointer#gitdir: }" ;;
      *) fail "unsupported .git pointer in $git_entry" ;;
    esac
    GIT_DIR="$(resolve_git_path_text "$WT_TOP" "$gitdir_text")"
  else
    fail "unsupported .git entry: $git_entry"
  fi
  [ -d "$GIT_DIR" ] && [ ! -L "$GIT_DIR" ] || fail "Git directory is missing or symlinked: $GIT_DIR"

  if [ -f "$GIT_DIR/commondir" ]; then
    IFS= read -r commondir_text < "$GIT_DIR/commondir" || fail "could not read $GIT_DIR/commondir"
    COMMON_DIR="$(resolve_git_path_text "$GIT_DIR" "$commondir_text")"
  else
    COMMON_DIR="$GIT_DIR"
  fi
  [ -d "$COMMON_DIR" ] && [ ! -L "$COMMON_DIR" ] || fail "Git common directory is missing or symlinked: $COMMON_DIR"

  is_under "$GIT_DIR" "$FAMILY_ROOT" \
    || fail "Git directory is outside $FAMILY_ROOT; external linked-worktree layouts require a custom profile/layout"
  is_under "$COMMON_DIR" "$FAMILY_ROOT" \
    || fail "Git common directory is outside $FAMILY_ROOT; external linked-worktree layouts require a custom profile/layout"

  bare="$(read_core_bare "$COMMON_DIR/config")"
  if [ "$GIT_ENTRY_KIND" = file ] && [ "$GIT_DIR" = "$COMMON_DIR" ] && [ "$bare" = true ]; then
    fail "$WT_TOP is a bare-repository hub, not a worktree; choose one of its worktree directories"
  fi

  ORIGIN_URL="$(read_origin_url "$COMMON_DIR/config")"
  validate_mount_path "$FAMILY_ROOT" "project family path"
  validate_mount_path "$WT_TOP" "worktree path"
  validate_mount_path "$GIT_DIR" "Git directory path"
  validate_mount_path "$COMMON_DIR" "Git common-directory path"

  if [ "$GIT_ENTRY_KIND" = directory ] && [ "$COMMON_DIR" = "$GIT_DIR" ]; then
    LAYOUT='simple'
    MOUNT_ROOT="$WT_TOP"
    WT_REL='.'
    COMMON_REL='.git'
    GIT_DIR_REL='.git'
    CONTAINER_WT="$CONTAINER_ROOT"
    CONTAINER_COMMON="$CONTAINER_ROOT/.git"
    CONTAINER_GIT_DIR="$CONTAINER_COMMON"
  else
    LAYOUT='linked-worktree'
    MOUNT_ROOT="$FAMILY_ROOT"
    WT_REL="${WT_TOP#"$FAMILY_ROOT"/}"
    COMMON_REL="${COMMON_DIR#"$FAMILY_ROOT"/}"
    GIT_DIR_REL="${GIT_DIR#"$FAMILY_ROOT"/}"
    [ "$WT_REL" != "$WT_TOP" ] && [ "$COMMON_REL" != "$COMMON_DIR" ] && [ "$GIT_DIR_REL" != "$GIT_DIR" ] \
      || fail "could not reproduce linked-worktree paths beneath $FAMILY_ROOT"
    CONTAINER_WT="$CONTAINER_ROOT/$WT_REL"
    CONTAINER_COMMON="$CONTAINER_ROOT/$COMMON_REL"
    CONTAINER_GIT_DIR="$CONTAINER_ROOT/$GIT_DIR_REL"
  fi
}

load_profile() {
  local requested="$1" p matches=() candidate_name candidate_child candidate_remote
  if [ -n "$requested" ]; then
    p="$PROFILES_DIR/$requested.sh"
    [ -f "$p" ] && [ ! -L "$p" ] || fail "unknown or symlinked trusted profile: $requested"
    reset_profile_vars
    # shellcheck source=/dev/null
    source "$p"
    [ "$PROFILE_NAME" = "$requested" ] || fail "profile name mismatch in $p"
    PROFILE_PATH="$p"
    return
  fi

  for p in "$PROFILES_DIR"/*.sh; do
    [ -f "$p" ] || continue
    reset_profile_vars
    # shellcheck source=/dev/null
    source "$p"
    candidate_name="$PROFILE_NAME"
    candidate_child="$PROFILE_CHILD_REGEX"
    candidate_remote="$PROFILE_REMOTE_REGEX"
    if [[ "$FAMILY_NAME" =~ $candidate_child ]] \
      || { [ -n "$ORIGIN_URL" ] && [[ "$ORIGIN_URL" =~ $candidate_remote ]]; }; then
      matches+=("$p:$candidate_name")
    fi
  done
  [ "${#matches[@]}" -gt 0 ] \
    || fail "no trusted profile matches family '$FAMILY_NAME' (origin: ${ORIGIN_URL:-unknown}); pass --profile NAME"
  [ "${#matches[@]}" -eq 1 ] \
    || fail "multiple profiles match '$FAMILY_NAME'; pass --profile NAME"
  p="${matches[0]%%:*}"
  reset_profile_vars
  # shellcheck source=/dev/null
  source "$p"
  PROFILE_PATH="$p"
}

derive_identity() {
  local base suffix path_hash
  base="$(sanitize_name "$FAMILY_NAME")"
  if [ "$LAYOUT" = linked-worktree ]; then
    suffix="$(sanitize_name "$(basename "$WT_TOP")")"
    DEFAULT_CONTAINER_NAME="$base-$suffix"
  else
    DEFAULT_CONTAINER_NAME="$(sanitize_name "$(basename "$WT_TOP")")"
  fi
  CONTAINER_NAME="${CONTAINER_OVERRIDE:-$DEFAULT_CONTAINER_NAME}"
  [[ "$CONTAINER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
    || fail "invalid Docker container name: $CONTAINER_NAME"

  path_hash="$(printf '%s' "$WT_TOP" | sha256sum | awk '{print substr($1,1,12)}')"
  INSTANCE_ID="$(sanitize_name "$FAMILY_NAME")-$(sanitize_name "$(basename "$WT_TOP")")-$path_hash"
  STATE_HOME="$(realpath -m -- "$STATE_HOME")"
  validate_mount_path "$STATE_HOME" "state path"
  is_under "$STATE_HOME" "$MOUNT_ROOT" && fail "state directory must be outside the agent-writable project: $STATE_HOME"
  INSTANCE_STATE="$STATE_HOME/$INSTANCE_ID"
  CODEX_HOME="$INSTANCE_STATE/codex"
  PROTECTED_DIR="$INSTANCE_STATE/protected"
  MARKER="$INSTANCE_STATE/instance.conf"
}

validate_state_paths() {
  local p
  umask 077
  for p in "$INSTANCE_STATE" "$CODEX_HOME" "$PROTECTED_DIR"; do
    [ ! -L "$p" ] || fail "refusing symlinked state path: $p"
  done
  mkdir -p -- "$INSTANCE_STATE" "$CODEX_HOME" "$PROTECTED_DIR"
  chmod 0700 -- "$INSTANCE_STATE" "$CODEX_HOME" "$PROTECTED_DIR"
  if [ -f "$MARKER" ]; then
    grep -Fxq "wt_top=$WT_TOP" "$MARKER" || fail "state collision at $INSTANCE_STATE (worktree marker mismatch)"
    grep -Fxq "profile=$PROFILE_NAME" "$MARKER" || fail "state collision at $INSTANCE_STATE (profile marker mismatch)"
  else
    printf 'wt_top=%s\nprofile=%s\ncontainer=%s\n' "$WT_TOP" "$PROFILE_NAME" "$CONTAINER_NAME" > "$MARKER"
    chmod 0600 "$MARKER"
  fi
}

copy_dir_if_empty() {
  local src="$1" dst="$2" label="$3"
  [ -d "$src" ] || return 1
  [ ! -L "$src" ] || fail "refusing symlinked $label source: $src"
  local real
  real="$(cd "$src" && pwd -P)"
  is_under "$real" "$WT_TOP" || { [[ "$label" == previous-secure-* ]] || fail "$label source escapes worktree: $src -> $real"; }
  if find "$dst" -mindepth 1 -print -quit | grep -q .; then
    return 1
  fi
  cp -a -- "$src"/. "$dst"/
  note "copied $label state to $dst (source left untouched)"
  return 0
}

migrate_legacy_codex_if_needed() {
  find "$CODEX_HOME" -mindepth 1 -print -quit | grep -q . && return 0
  local legacy="$WT_TOP/.codex/homestate"
  if [ -e "$legacy" ]; then
    [ ! -L "$WT_TOP/.codex" ] || fail "refusing symlinked legacy .codex directory: $WT_TOP/.codex"
    copy_dir_if_empty "$legacy" "$CODEX_HOME" legacy-Codex && return 0
  fi

  # Explicit escape hatch for a moved checkout or unusual previous state root.
  if [ -n "${DOCKER_ISOLATOR_LEGACY_CODEX:-}" ]; then
    local explicit_legacy
    explicit_legacy="$(realpath -e -- "$DOCKER_ISOLATOR_LEGACY_CODEX")"
    copy_dir_if_empty "$explicit_legacy" "$CODEX_HOME" previous-secure-explicit && return 0
  fi

  # Migrate the secure one-off SKG state layout produced by the previous
  # skg-docker hardening. First try the exact old path-hash identity; then, for
  # a checkout moved under docker-isolator/projects/, use its old project-path
  # marker when exactly one candidate has the same checkout basename.
  if [ "$PROFILE_NAME" = skg ]; then
    local old_base old_hash old_state marker recorded candidate candidates=()
    old_base="${XDG_STATE_HOME:-${HOME:?}/.local/state}/skg-docker"
    old_hash="$(printf '%s' "$WT_TOP" | sha256sum | awk '{print substr($1,1,12)}')"
    old_state="$old_base/$(sanitize_name "$(basename "$WT_TOP")")-$old_hash/codex"
    if [ -d "$old_state" ] && [ ! -L "$old_state" ]; then
      copy_dir_if_empty "$old_state" "$CODEX_HOME" previous-secure-SKG && return 0
    fi

    if [ -d "$old_base" ] && [ ! -L "$old_base" ]; then
      for marker in "$old_base"/*/project-path; do
        [ -f "$marker" ] && [ ! -L "$marker" ] || continue
        IFS= read -r recorded < "$marker" || continue
        [ "$(basename -- "$recorded")" = "$(basename -- "$WT_TOP")" ] || continue
        candidate="$(dirname -- "$marker")/codex"
        [ -d "$candidate" ] && [ ! -L "$candidate" ] || continue
        candidates+=("$candidate")
      done
      if [ "${#candidates[@]}" -eq 1 ]; then
        copy_dir_if_empty "${candidates[0]}" "$CODEX_HOME" previous-secure-moved-SKG && return 0
      elif [ "${#candidates[@]}" -gt 1 ]; then
        warn "multiple previous skg-docker states match basename $(basename "$WT_TOP"); set DOCKER_ISOLATOR_LEGACY_CODEX to the one to migrate"
      fi
    fi
  fi
}

# Protected files are deliberately mode 0444 after creation.  Refresh them by
# atomically replacing their directory entry, rather than opening the existing
# read-only file for truncation (which would make a second launch fail).
replace_protected_file() {
  local source="$1" name="$2" mode="$3" destination tmp
  destination="$PROTECTED_DIR/$name"
  tmp="$(mktemp "$PROTECTED_DIR/.${name}.XXXXXX")"
  if ! cp -- "$source" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod "$mode" "$tmp"
  mv -fT -- "$tmp" "$destination"
}

replace_protected_text() {
  local name="$1" mode="$2" text="$3" destination tmp
  destination="$PROTECTED_DIR/$name"
  tmp="$(mktemp "$PROTECTED_DIR/.${name}.XXXXXX")"
  if ! printf '%s\n' "$text" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod "$mode" "$tmp"
  mv -fT -- "$tmp" "$destination"
}

# Copy trusted Git metadata controls outside the writable project, then mount
# those copies read-only. This prevents the agent from changing what host Git
# will later treat as repository config/hooks through the paths we protect.
prepare_git_protection() {
  local common_config="$COMMON_DIR/config" hooks="$COMMON_DIR/hooks" nlink
  [ -f "$common_config" ] && [ ! -L "$common_config" ] || fail "Git common config is missing or symlinked: $common_config"
  nlink="$(stat -c %h -- "$common_config")"
  [ "$nlink" = 1 ] || fail "Git config has $nlink hard links; refusing because an alternate writable path could bypass protection: $common_config"

  replace_protected_file "$common_config" common-config 0444

  if [ -L "$hooks" ]; then
    fail "Git hooks path is a symlink: $hooks; repair/review it before isolating this repo"
  fi
  if [ ! -e "$hooks" ]; then
    mkdir -- "$hooks"
  fi
  [ -d "$hooks" ] || fail "Git hooks path is not a directory: $hooks"
  mkdir -p -- "$PROTECTED_DIR/empty-hooks"
  chmod 0555 "$PROTECTED_DIR/empty-hooks"

  if [ "$GIT_ENTRY_KIND" = file ]; then
    local rel_gitdir dotgit="$WT_TOP/.git" dotgit_links
    dotgit_links="$(stat -c %h -- "$dotgit")"
    [ "$dotgit_links" = 1 ] || fail "worktree .git pointer has $dotgit_links hard links; refusing: $dotgit"
    rel_gitdir="$(realpath --relative-to="$WT_TOP" "$GIT_DIR")"
    replace_protected_text worktree-dot-git 0444 "gitdir: $rel_gitdir"
  fi

  # Protect worktree-specific config when the repository uses it.
  WORKTREE_CONFIG_SOURCE=''
  if [ -f "$GIT_DIR/config.worktree" ]; then
    [ ! -L "$GIT_DIR/config.worktree" ] || fail "symlinked Git worktree config: $GIT_DIR/config.worktree"
    [ "$(stat -c %h -- "$GIT_DIR/config.worktree")" = 1 ] || fail "hard-linked Git worktree config: $GIT_DIR/config.worktree"
    replace_protected_file "$GIT_DIR/config.worktree" config.worktree 0444
    WORKTREE_CONFIG_SOURCE="$PROTECTED_DIR/config.worktree"
  fi
}

check_repo_config_risks() {
  local config="$COMMON_DIR/config" line
  [ -f "$config" ] || return 0
  # These do not prove compromise, but each can redirect host Git toward code
  # outside the protected default hooks/config paths.
  while IFS= read -r line; do
    [ -z "$line" ] || warn "review executable/include Git config before using host Git: $line"
  done < <(awk '
    BEGIN { section="" }
    /^[[:space:]]*\[/ { section=tolower($0) }
    /^[[:space:]]*(hookspath|fsmonitor)[[:space:]]*=/ && section ~ /^\[core\]/ { print $0 }
    /^[[:space:]]*path[[:space:]]*=/ && section ~ /^\[include/ { print section " " $0 }
    /^[[:space:]]*(clean|smudge|process)[[:space:]]*=/ && section ~ /^\[filter / { print section " " $0 }
    /^[[:space:]]*external[[:space:]]*=/ && section ~ /^\[diff / { print section " " $0 }
    /^[[:space:]]*driver[[:space:]]*=/ && section ~ /^\[merge / { print section " " $0 }
  ' "$config")
}

read_profile_port() {
  [ -n "$PROFILE_PORT_FILE" ] || { PROFILE_PORT=''; return 0; }
  local rel="${SKG_CONFIG:-$PROFILE_PORT_FILE}" file key="$PROFILE_PORT_KEY" value
  case "$rel" in
    /*) file="$rel" ;;
    *) file="$WT_TOP/$rel" ;;
  esac
  [ -f "$file" ] || fail "profile port config is missing: $file"
  value="$(awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      line=$0; sub(/^[^=]*=[[:space:]]*/, "", line); sub(/[[:space:]]*#.*/, "", line); gsub(/[[:space:]]/, "", line); print line; exit
    }
  ' "$file")"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "invalid numeric port '$value' in $file"
  (( value >= 1024 && value <= 65535 )) || fail "profile port must be 1024-65535 (got $value)"
  PROFILE_PORT="$value"
}

require_docker() {
  command -v docker >/dev/null 2>&1 || fail "Docker CLI not found on PATH"
}

container_exists() { docker container inspect "$1" >/dev/null 2>&1; }

containers_using_worktree() {
  local name mounts
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    mounts="$(docker inspect --format '{{range .Mounts}}{{printf "%s\t%s\n" .Source .Destination}}{{end}}' "$name" 2>/dev/null || true)"
    if printf '%s\n' "$mounts" | awk -F '\t' -v wt="$WT_TOP" '$1==wt { found=1 } END { exit(found?0:1) }'; then
      printf '%s\n' "$name"
    fi
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
}

build_mount_args() {
  MOUNT_ARGS=()
  local common_mode=''
  if [ "$LAYOUT" = simple ]; then
    MOUNT_ARGS+=(--mount "type=bind,source=$WT_TOP,target=$CONTAINER_ROOT")
  else
    MOUNT_ARGS+=(--mount "type=bind,source=$FAMILY_ROOT,target=$CONTAINER_ROOT,readonly")
    MOUNT_ARGS+=(--mount "type=bind,source=$WT_TOP,target=$CONTAINER_WT")
  fi

  case "$EFFECTIVE_GIT_MODE" in
    protected-shared)
      common_mode="type=bind,source=$COMMON_DIR,target=$CONTAINER_COMMON"
      ;;
    readonly)
      common_mode="type=bind,source=$COMMON_DIR,target=$CONTAINER_COMMON,readonly"
      ;;
    *) fail "unsupported Git mode: $EFFECTIVE_GIT_MODE" ;;
  esac
  # Pin the Git metadata root as its own mountpoint so an agent cannot rename
  # the .git/.bare entry out from under the nested protections.
  MOUNT_ARGS+=(--mount "$common_mode")

  if [ "$EFFECTIVE_GIT_MODE" = protected-shared ]; then
    MOUNT_ARGS+=(--mount "type=bind,source=$PROTECTED_DIR/common-config,target=$CONTAINER_COMMON/config,readonly")
    MOUNT_ARGS+=(--mount "type=bind,source=$PROTECTED_DIR/empty-hooks,target=$CONTAINER_COMMON/hooks,readonly")
    if [ -n "$WORKTREE_CONFIG_SOURCE" ]; then
      MOUNT_ARGS+=(--mount "type=bind,source=$WORKTREE_CONFIG_SOURCE,target=$CONTAINER_GIT_DIR/config.worktree,readonly")
    fi
  fi

  if [ "$GIT_ENTRY_KIND" = file ]; then
    MOUNT_ARGS+=(--mount "type=bind,source=$PROTECTED_DIR/worktree-dot-git,target=$CONTAINER_WT/.git,readonly")
  fi

  MOUNT_ARGS+=(--mount "type=bind,source=$CODEX_HOME,target=$CONTAINER_CODEX_HOME")
  if [ -n "${CODEX_HOOK_SOURCE:-}" ]; then
    MOUNT_ARGS+=(--mount "type=bind,source=$CODEX_HOOK_SOURCE,target=$CONTAINER_CODEX_HOME/hooks.json,readonly")
    MOUNT_ARGS+=(--mount "type=bind,source=$CODEX_CONFIG_SOURCE,target=$CONTAINER_CODEX_HOME/config.toml,readonly")
  fi
}

ensure_network() {
  NETWORK_ARGS=()
  case "$PROFILE_NETWORK" in
    isolated-bridge)
      local hash network
      hash="$(printf '%s' "$WT_TOP" | sha256sum | awk '{print substr($1,1,12)}')"
      network="docker-isolator-$hash"
      if ! docker network inspect "$network" >/dev/null 2>&1; then
        docker network create --driver bridge "$network" >/dev/null
      fi
      NETWORK_ARGS=(--network "$network")
      ;;
    host)
      NETWORK_ARGS=(--network host)
      ;;
    none)
      NETWORK_ARGS=(--network none)
      ;;
    *) fail "unsupported profile network mode: $PROFILE_NETWORK" ;;
  esac
}

build_capability_args() {
  CAP_ARGS=(--security-opt no-new-privileges=true --cap-drop ALL)
  local cap
  for cap in "${PROFILE_CAP_ADD[@]}"; do CAP_ARGS+=(--cap-add "$cap"); done
}

build_resource_args() {
  local pids="${DOCKER_ISOLATOR_PIDS_LIMIT:-4096}" u
  [[ "$pids" =~ ^[0-9]+$ ]] && (( pids >= 64 )) || fail "DOCKER_ISOLATOR_PIDS_LIMIT must be an integer >= 64"
  RESOURCE_ARGS=(--pids-limit "$pids")
  for u in "${PROFILE_ULIMITS[@]}"; do RESOURCE_ARGS+=(--ulimit "$u"); done
  [ -z "${DOCKER_ISOLATOR_MEMORY:-}" ] || RESOURCE_ARGS+=(--memory "$DOCKER_ISOLATOR_MEMORY")
  [ -z "${DOCKER_ISOLATOR_CPUS:-}" ] || RESOURCE_ARGS+=(--cpus "$DOCKER_ISOLATOR_CPUS")
}

build_profile_args() {
  PROFILE_ARGS=()
  local host_uid pipewire audio_gid dialout_gid cap
  host_uid="$(id -u)"

  if [ "$PROFILE_PIPEWIRE" = 1 ]; then
    pipewire="/run/user/$host_uid/pipewire-0"
    if [ -S "$pipewire" ]; then
      PROFILE_ARGS+=(--mount "type=bind,source=$pipewire,target=/run/user/$CONTAINER_UID/pipewire-0")
    else
      warn "$pipewire is unavailable; launching without PipeWire"
    fi
  fi

  if [ "$PROFILE_X11" = 1 ]; then
    if [ -d /tmp/.X11-unix ]; then
      PROFILE_ARGS+=(--mount 'type=bind,source=/tmp/.X11-unix,target=/tmp/.X11-unix,readonly')
      PROFILE_ARGS+=(-e "DISPLAY=${DISPLAY:-:0}")
    else
      warn "/tmp/.X11-unix is unavailable; launching without X11"
    fi
  fi

  if [ "$PROFILE_ALSA" = 1 ]; then
    if [ -d /dev/snd ]; then
      PROFILE_ARGS+=(--mount 'type=bind,source=/dev/snd,target=/dev/snd')
      PROFILE_ARGS+=(--device-cgroup-rule 'c 116:* rmw')
      audio_gid="$(getent group audio 2>/dev/null | cut -d: -f3 || true)"
      [ -z "$audio_gid" ] || PROFILE_ARGS+=(--group-add "$audio_gid")
    else
      warn "/dev/snd is unavailable; launching without direct ALSA/MIDI device access"
    fi
  fi

  if [ "$PROFILE_SERIAL" = 1 ] || [ "$PROFILE_USB_DFU" = 1 ]; then
    # Host udev gives serial ports (and, given a host rule, USB boards)
    # to the dialout group.
    dialout_gid="$(getent group dialout 2>/dev/null | cut -d: -f3 || true)"
    if [ -n "$dialout_gid" ]; then
      PROFILE_ARGS+=(--group-add "$dialout_gid")
    else
      warn "host has no dialout group; serial/USB devices may be unreadable in the container"
    fi
  fi

  if [ "$PROFILE_SERIAL" = 1 ]; then
    # USB serial adapters appear and disappear while the container runs,
    # so no fixed --device list fits them. Instead the host's /dev is
    # visible read-only at /hostdev, without its submounts (/dev/shm,
    # /dev/pts, ...), and the device cgroup lets the container open only
    # the serial majors: 166 = ttyACM* (e.g. Arduino UNO R4), 188 =
    # ttyUSB* (e.g. CH340 adapters). Ports appear as /hostdev/ttyACM0 etc.
    PROFILE_ARGS+=(--mount 'type=bind,source=/dev,target=/hostdev,readonly,bind-recursive=disabled')
    PROFILE_ARGS+=(--device-cgroup-rule 'c 166:* rmw')
    PROFILE_ARGS+=(--device-cgroup-rule 'c 188:* rmw')
  fi

  if [ "$PROFILE_USB_DFU" = 1 ]; then
    # Raw USB access, for boards that are programmed over DFU (e.g. the
    # Arduino UNO R4 Minima, via dfu-util). libusb looks in /dev/bus/usb.
    # Host file permissions still apply: by default only root can write
    # these nodes, so the host needs a udev rule for each board's vendor.
    if [ -d /dev/bus/usb ]; then
      PROFILE_ARGS+=(--mount 'type=bind,source=/dev/bus/usb,target=/dev/bus/usb')
      PROFILE_ARGS+=(--device-cgroup-rule 'c 189:* rmw')
    else
      warn "/dev/bus/usb is unavailable; launching without raw USB access"
    fi
  fi

  if [ -n "$PROFILE_CLAUDE_CONFIG_REL" ]; then
    PROFILE_ARGS+=(-e "CLAUDE_CONFIG_DIR=$CONTAINER_WT/$PROFILE_CLAUDE_CONFIG_REL")
  fi

  if [ -n "$PROFILE_PORT" ]; then
    [ "$PROFILE_NETWORK" != host ] || fail "profile cannot publish a port while using host networking"
    PROFILE_ARGS+=(--publish "$PROFILE_PUBLISH_ADDRESS:$PROFILE_PORT:$PROFILE_PORT")
  fi
}

install_codex_hook() {
  [ "$PROFILE_CODEX_HOOK" = 1 ] || return 0
  local installer="$TRUSTED_DIR/install-codex-beep-hook.sh" template="$TRUSTED_DIR/codex-hooks.json"
  [ -f "$installer" ] && [ ! -L "$installer" ] || fail "trusted hook installer missing or symlinked: $installer"
  [ -f "$template" ] && [ ! -L "$template" ] || fail "trusted hook template missing or symlinked: $template"
  "$installer" "$CODEX_HOME" "$template"
}

# Codex state itself stays writable (sessions, auth, logs, caches), but the
# hook declaration and its trust record are a code-execution boundary. Pin
# copies outside that writable mount and overlay them read-only below it.
prepare_codex_hook_protection() {
  [ "$PROFILE_CODEX_HOOK" = 1 ] || { CODEX_HOOK_SOURCE=''; CODEX_CONFIG_SOURCE=''; return 0; }
  local hooks="$CODEX_HOME/hooks.json" config="$CODEX_HOME/config.toml"
  [ -f "$hooks" ] && [ ! -L "$hooks" ] || fail "Codex hook file is missing or symlinked: $hooks"
  [ -f "$config" ] && [ ! -L "$config" ] || fail "Codex config is missing or symlinked: $config"
  [ "$(stat -c %h -- "$hooks")" = 1 ] || fail "Codex hook file has alternate hard links: $hooks"
  [ "$(stat -c %h -- "$config")" = 1 ] || fail "Codex config has alternate hard links: $config"
  replace_protected_file "$hooks" codex-hooks.json 0444
  replace_protected_file "$config" codex-config.toml 0444
  CODEX_HOOK_SOURCE="$PROTECTED_DIR/codex-hooks.json"
  CODEX_CONFIG_SOURCE="$PROTECTED_DIR/codex-config.toml"
}

prepare() {
  parse_git_layout
  load_profile "$PROFILE_OVERRIDE"
  EFFECTIVE_GIT_MODE="${GIT_MODE_OVERRIDE:-$PROFILE_GIT_MODE}"
  case "$EFFECTIVE_GIT_MODE" in protected-shared|readonly) ;; *) fail "--git-mode must be protected-shared or readonly" ;; esac
  derive_identity
  check_repo_config_risks
  local preflight_path
  for preflight_path in "${PROFILE_PREFLIGHT_PATHS[@]}"; do
    [ -e "$WT_TOP/$preflight_path" ]       || warn "profile expects $WT_TOP/$preflight_path; initialize/provide it on the host if this feature is needed"
  done
  read_profile_port
}

print_description() {
  cat <<EOF_DESC
profile:          $PROFILE_NAME ($PROFILE_PATH)
family root:      $FAMILY_ROOT
worktree:         $WT_TOP
layout:           $LAYOUT
Git dir:          $GIT_DIR
Git common dir:   $COMMON_DIR
origin:           ${ORIGIN_URL:-<unknown>}
Git mode:         $EFFECTIVE_GIT_MODE
container:        $CONTAINER_NAME
image:            ${DOCKER_ISOLATOR_IMAGE:-$PROFILE_IMAGE}
network:          $PROFILE_NETWORK
state:            $INSTANCE_STATE
Codex state:      $CODEX_HOME
container cwd:    $CONTAINER_WT
EOF_DESC
  if [ -n "$PROFILE_PORT" ]; then printf 'published port:   %s:%s -> %s\n' "$PROFILE_PUBLISH_ADDRESS" "$PROFILE_PORT" "$PROFILE_PORT"; fi
  if [ "$EFFECTIVE_GIT_MODE" = protected-shared ]; then
    echo 'Git isolation:    config/hooks/.git pointer protected; refs + objects shared'
  else
    echo 'Git isolation:    Git metadata read-only'
  fi
  [ "$PROFILE_NETWORK" != host ] || echo 'network warning:  host network namespace is shared with the host'
  [ "$PROFILE_X11" != 1 ] || echo 'X11 warning:      host X11 socket is exposed when available'
  [ "$PROFILE_ALSA" != 1 ] || echo 'device warning:   /dev/snd and sound-device cgroup access are exposed when available'
  [ "$PROFILE_SERIAL" != 1 ] || echo 'device warning:   host /dev names at /hostdev; serial (ttyACM*/ttyUSB*) access'
  [ "$PROFILE_USB_DFU" != 1 ] || echo 'device warning:   /dev/bus/usb and raw USB cgroup access (host permissions apply)'
}

# shellcheck source=lib/launch.sh
source "$BASH_DIR/lib/launch.sh"

find_container_for_repair() {
  if [ -n "$CONTAINER_OVERRIDE" ]; then
    REPAIR_CONTAINER="$CONTAINER_OVERRIDE"
    return
  fi
  if container_exists "$DEFAULT_CONTAINER_NAME"; then
    REPAIR_CONTAINER="$DEFAULT_CONTAINER_NAME"
    return
  fi

  local name mounts matches=()
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    mounts="$(docker inspect --format '{{range .Mounts}}{{printf "%s\t%s\\n" .Source .Destination}}{{end}}' "$name" 2>/dev/null || true)"
    if printf '%s\n' "$mounts" | awk -F '\t' -v wt="$WT_TOP" '$1==wt { found=1 } END { exit(found?0:1) }'; then
      matches+=("$name")
    fi
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)

  if [ "${#matches[@]}" -eq 1 ]; then
    REPAIR_CONTAINER="${matches[0]}"
  elif [ "${#matches[@]}" -gt 1 ]; then
    if [ -t 0 ]; then
      echo "Multiple containers appear to use $WT_TOP:" >&2
      printf '  %s\n' "${matches[@]}" >&2
      printf 'Container to repair: ' >&2
      IFS= read -r REPAIR_CONTAINER
      [ -n "$REPAIR_CONTAINER" ] || fail "no container selected"
    else
      fail "multiple containers use this project (${matches[*]}); pass --container NAME"
    fi
  else
    REPAIR_CONTAINER="$DEFAULT_CONTAINER_NAME"
  fi
}

confirm_destructive() {
  local prompt="$1"
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -t 0 ] || fail "$prompt (rerun with --yes in a non-interactive shell)"
  printf '%s [y/N] ' "$prompt" >&2
  local answer
  IFS= read -r answer || return 1
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

container_codex_source() {
  local name="$1"
  docker inspect --format '{{range .Mounts}}{{if eq .Destination "/home/ubuntu/.codex"}}{{.Source}}{{end}}{{end}}' "$name" 2>/dev/null || true
}

recover_codex_from_container() {
  local name="$1" existing_source="$2" tmp recovered stamp
  [ "$existing_source" != "$CODEX_HOME" ] || { note "container already uses the expected external Codex state"; return 0; }
  stamp="$(date +%Y%m%d-%H%M%S)"
  recovered="$INSTANCE_STATE/recovered-codex-$stamp"
  tmp="$(mktemp -d "$INSTANCE_STATE/.recover.XXXXXX")"
  trap 'rm -rf -- "$tmp"' RETURN
  mkdir -p "$tmp/codex"
  if ! docker cp "$name:$CONTAINER_CODEX_HOME/." "$tmp/codex"; then
    warn "could not copy $CONTAINER_CODEX_HOME from $name"
    return 1
  fi
  if ! find "$tmp/codex" -mindepth 1 -print -quit | grep -q .; then
    warn "container Codex state was empty"
    return 1
  fi

  if ! find "$CODEX_HOME" -mindepth 1 -print -quit | grep -q .; then
    cp -a -- "$tmp/codex"/. "$CODEX_HOME"/
    note "recovered Codex state from stopped container $name into $CODEX_HOME"
  else
    mv "$tmp/codex" "$recovered"
    warn "both current external state and old-container state exist; preserved old-container copy at $recovered"
    warn "the launcher will keep using $CODEX_HOME; compare/merge the recovery manually if needed"
  fi
  rm -rf -- "$tmp"
  trap - RETURN
}

# shellcheck source=lib/repair.sh
source "$BASH_DIR/lib/repair.sh"

legacy_doctor_prepared() {
  print_description
  echo
  if [ -e "$WT_TOP/docker.sh" ]; then
    if [ -x "$WT_TOP/docker.sh" ]; then
      warn "legacy project-local launcher is executable: $WT_TOP/docker.sh"
    else
      note "project-local docker.sh exists but is not executable: $WT_TOP/docker.sh"
    fi
    echo "  Do not treat project-local launchers as trusted after an agent has writable access." >&2
  fi
  if [ -e "$WT_TOP/.codex/homestate" ]; then
    warn "legacy in-project Codex state exists: $WT_TOP/.codex/homestate"
  fi
  check_repo_config_risks
  if [ "$EFFECTIVE_GIT_MODE" = protected-shared ]; then
    warn "shared Git refs/objects are writable; an agent in this worktree can change sibling branches/refs"
  fi
  if [ "$PROFILE_NETWORK" = host ]; then
    warn "host networking intentionally removes Docker network isolation from the host and sibling host-network containers"
  fi
  if [ "$PROFILE_X11" = 1 ]; then
    warn "X11 access is a broad host GUI capability; keep it only if this project needs GUI windows"
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo
    warn "Docker CLI not found; skipping live-container inspection"
    return 0
  fi

  if container_exists "$CONTAINER_NAME"; then
    local src privileged network_mode security capdrop
    src="$(container_codex_source "$CONTAINER_NAME")"
    privileged="$(docker inspect --format '{{.HostConfig.Privileged}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    network_mode="$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    security="$(docker inspect --format '{{json .HostConfig.SecurityOpt}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    capdrop="$(docker inspect --format '{{json .HostConfig.CapDrop}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    echo
    echo "existing container: $CONTAINER_NAME"
    echo "  Codex mount source: ${src:-<not bind-mounted>}"
    echo "  privileged:         ${privileged:-<unknown>}"
    echo "  network mode:       ${network_mode:-<unknown>}"
    echo "  security opts:      ${security:-<unknown>}"
    echo "  cap-drop:           ${capdrop:-<unknown>}"
    [ "$src" = "$CODEX_HOME" ] || warn "existing container does not use the expected external Codex mount; 'repair' can migrate it"
    [ "$privileged" != true ] || warn "existing container is privileged"
  else
    local other_users
    other_users="$(containers_using_worktree)"
    echo
    echo "No container named '$CONTAINER_NAME' currently exists."
    if [ -n "$other_users" ]; then
      warn "other container(s) bind-mount this worktree: $other_users; repair can discover a single such legacy container automatically"
    fi
  fi
}

# shellcheck source=lib/inspect.sh
source "$BASH_DIR/lib/inspect.sh"

COMMAND="${1:-}"
case "$COMMAND" in
  launch|repair|doctor|describe) shift ;;
  -h|--help|'') usage; exit 0 ;;
  *) fail "unknown command '$COMMAND' (try --help)" ;;
esac

TARGET_INPUT='.'
PROFILE_OVERRIDE=''
CONTAINER_OVERRIDE=''
GIT_MODE_OVERRIDE=''
ASSUME_YES=0
NO_LAUNCH=0
path_set=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile) [ "$#" -ge 2 ] || fail "--profile needs a value"; PROFILE_OVERRIDE="$2"; shift 2 ;;
    --container) [ "$#" -ge 2 ] || fail "--container needs a value"; CONTAINER_OVERRIDE="$2"; shift 2 ;;
    --git-mode) [ "$#" -ge 2 ] || fail "--git-mode needs a value"; GIT_MODE_OVERRIDE="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --no-launch) NO_LAUNCH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) fail "unknown option: $1" ;;
    *)
      [ "$path_set" = 0 ] || fail "only one PATH may be supplied"
      TARGET_INPUT="$1"; path_set=1; shift
      ;;
  esac
done

prepare
case "$COMMAND" in
  describe) print_description ;;
  doctor) doctor_prepared ;;
  launch) launch_prepared ;;
  repair) repair_prepared ;;
esac
