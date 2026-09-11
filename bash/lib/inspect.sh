# Live inspection is kept out of the launch path.
doctor_prepared() {
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
  [ ! -e "$WT_TOP/.codex/homestate" ] || warn "legacy in-project Codex state exists: $WT_TOP/.codex/homestate"
  check_repo_config_risks
  [ "$EFFECTIVE_GIT_MODE" != protected-shared ] || warn "shared Git refs/objects are writable; an agent in this worktree can change sibling branches/refs"
  [ "$PROFILE_NETWORK" != host ] || warn "host networking intentionally removes Docker network isolation from the host and sibling host-network containers"
  [ "$PROFILE_X11" != 1 ] || warn "X11 access is a broad host GUI capability; keep it only if this project needs GUI windows"
  if ! command -v docker >/dev/null 2>&1; then
    echo; warn "Docker CLI not found; skipping live-container inspection"; return 0
  fi
  if container_exists "$CONTAINER_NAME"; then
    local src privileged network_mode security capdrop
    src="$(container_codex_source "$CONTAINER_NAME")"
    privileged="$(docker inspect --format '{{.HostConfig.Privileged}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    network_mode="$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    security="$(docker inspect --format '{{json .HostConfig.SecurityOpt}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    capdrop="$(docker inspect --format '{{json .HostConfig.CapDrop}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    echo; echo "existing container: $CONTAINER_NAME"; echo "  Codex mount source: ${src:-<not bind-mounted>}"; echo "  privileged:         ${privileged:-<unknown>}"; echo "  network mode:       ${network_mode:-<unknown>}"; echo "  security opts:      ${security:-<unknown>}"; echo "  cap-drop:           ${capdrop:-<unknown>}"
    [ "$src" = "$CODEX_HOME" ] || warn "existing container does not use the expected external Codex mount; 'repair' can migrate it"
    [ "$privileged" != true ] || warn "existing container is privileged"
  else
    local other_users
    other_users="$(containers_using_worktree)"
    echo; echo "No container named '$CONTAINER_NAME' currently exists."
    [ -z "$other_users" ] || warn "other container(s) bind-mount this worktree: $other_users; repair can discover a single such legacy container automatically"
  fi
}
