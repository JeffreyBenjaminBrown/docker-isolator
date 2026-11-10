# Container construction and launch. Loaded by the trusted entry script after
# path/profile discovery has populated the shared variables.
launch_prepared() {
  require_docker
  container_exists "$CONTAINER_NAME" && fail "container '$CONTAINER_NAME' already exists; use 'repair' rather than launching over it"
  local users
  users="$(containers_using_worktree)"
  [ -z "$users" ] || fail "another container already bind-mounts this worktree ($users); use 'repair' or stop/remove it first"
  validate_state_paths
  prepare_git_protection
  migrate_legacy_codex_if_needed
  install_codex_hook
  prepare_codex_hook_protection
  ensure_network
  build_mount_args
  build_capability_args
  build_resource_args
  build_profile_args

  local image="${DOCKER_ISOLATOR_IMAGE:-$PROFILE_IMAGE}"
  local args=(run --name "$CONTAINER_NAME" -it -d
    --platform linux/amd64
    --user "$CONTAINER_UID:$CONTAINER_GID"
    -w "$CONTAINER_WT"
  )
  args+=("${NETWORK_ARGS[@]}" "${CAP_ARGS[@]}" "${RESOURCE_ARGS[@]}" "${MOUNT_ARGS[@]}" "${PROFILE_ARGS[@]}")
  docker "${args[@]}" "$image"
}
