# Recovery is deliberately separate from launch: it is the only routine that
# stops/removes a container or copies state out of it.
repair_prepared() {
  require_docker
  validate_state_paths
  find_container_for_repair
  local name="$REPAIR_CONTAINER" running=false source=''
  if container_exists "$name"; then
    running="$(docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null || echo false)"
    if [ "$running" = true ]; then
      confirm_destructive "Stop container '$name' so its Codex state can be copied consistently?" \
        || fail "repair cancelled"
      docker stop "$name" >/dev/null
    fi
    source="$(container_codex_source "$name")"
    recover_codex_from_container "$name" "$source" || migrate_legacy_codex_if_needed
    install_codex_hook
    confirm_destructive "Remove old container '$name' after preserving its Codex state?" \
      || fail "repair cancelled; stopped container left intact"
    docker rm "$name" >/dev/null
  else
    note "no existing container '$name' found; repairing/migrating persistent state only"
    migrate_legacy_codex_if_needed
    install_codex_hook
  fi

  if [ "$NO_LAUNCH" = 0 ]; then
    CONTAINER_NAME="$name"
    launch_prepared
  fi
}
