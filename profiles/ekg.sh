# Trusted profile for the DIY EKG project (Arduino and Cerelog boards).
PROFILE_NAME="ekg"
PROFILE_CHILD_REGEX='^(diy[-_])?ekg([0-9]+)?$'
PROFILE_REMOTE_REGEX='(^|[:/])JeffreyBenjaminBrown/(diy[-_])?ekg(\.git)?$'
PROFILE_IMAGE='jeffreybbrown/hode:latest'
# The EKG tools talk to boards over USB, not to host services, so the
# container keeps its own network, as SKG's does.
PROFILE_NETWORK='isolated-bridge'
# Preserve the existing workflow: commits update the host/shared Git database.
# Git config/hooks and the worktree .git pointer are protected, but refs and
# objects are still shared across worktrees.
PROFILE_GIT_MODE='protected-shared'
PROFILE_PIPEWIRE=1
# Plots are saved as files. Set X11=1 only to open live plot windows.
PROFILE_X11=0
PROFILE_ALSA=0
PROFILE_SERIAL=1
PROFILE_USB_DFU=1
PROFILE_CAP_ADD=()
PROFILE_ULIMITS=()
PROFILE_CLAUDE_CONFIG_REL='my-dot-claude'
PROFILE_CODEX_HOOK=1
PROFILE_PORT_FILE=''
PROFILE_PORT_KEY=''
PROFILE_PUBLISH_ADDRESS=''
PROFILE_PREFLIGHT_PATHS=()
