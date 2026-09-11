# Trusted profiles

Profiles are sourced by the host-side `docker-isolator` executable and are
therefore trusted code/configuration. Keep them in this parent repository, not
inside an agent-writable child project.

The current profile variables are intentionally simple shell data:

- `PROFILE_NAME`
- `PROFILE_CHILD_REGEX`, `PROFILE_REMOTE_REGEX`
- `PROFILE_IMAGE`
- `PROFILE_NETWORK`: `isolated-bridge`, `host`, or `none`
- `PROFILE_GIT_MODE`: `protected-shared` or `readonly`
- `PROFILE_PIPEWIRE`, `PROFILE_X11`, `PROFILE_ALSA`
- `PROFILE_CAP_ADD=(...)`
- `PROFILE_ULIMITS=(...)`
- `PROFILE_CLAUDE_CONFIG_REL`
- `PROFILE_CODEX_HOOK`
- `PROFILE_PORT_FILE`, `PROFILE_PORT_KEY`, `PROFILE_PUBLISH_ADDRESS`
- `PROFILE_PREFLIGHT_PATHS=(...)` for paths whose absence should warn but not
  cause the host launcher to execute a project repair command automatically.

When adding a profile, start with the least host access that makes the project
work. In particular, prefer `isolated-bridge` to `host`, leave X11/device mounts
off unless required, and use `readonly` Git mode when agents do not need to
create host-repository commits directly.
