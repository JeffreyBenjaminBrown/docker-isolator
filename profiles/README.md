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
- `PROFILE_PIPEWIRE`, `PROFILE_ALSA`
- `PROFILE_SERIAL`: hot-pluggable USB serial ports (`ttyACM*`, `ttyUSB*`),
  visible in the container as `/hostdev/ttyACM0` etc.
- `PROFILE_USB_DFU`: raw USB access (`/dev/bus/usb`) for boards programmed
  over DFU; the host must also grant the board's device node to `dialout`
- `PROFILE_CAP_ADD=(...)`
- `PROFILE_ULIMITS=(...)`
- `PROFILE_CLAUDE_CONFIG_REL`
- `PROFILE_CODEX_HOOK`
- `PROFILE_PORT_FILE`, `PROFILE_PORT_KEY`, `PROFILE_PUBLISH_ADDRESS`
- `PROFILE_PREFLIGHT_PATHS=(...)` for paths whose absence should warn but not
  cause the host launcher to execute a project repair command automatically.

When adding a profile, start with the least host access that makes the project
work. In particular, prefer `isolated-bridge` to `host`, leave device mounts
off unless required, and use `readonly` Git mode when agents do not need to
create host-repository commits directly.

There is no X11 setting: docker-isolator never exposes the host's X display,
and it refuses a profile that sets `PROFILE_X11`. A project that needs a GUI
should serve a web page on a port published to `127.0.0.1`, as the ekg
profile does.
