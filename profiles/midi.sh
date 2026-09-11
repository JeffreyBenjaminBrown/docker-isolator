# Trusted profile for JeffreyBenjaminBrown/live-midi worktrees.
PROFILE_NAME="midi"
PROFILE_CHILD_REGEX='^midi([0-9]+)?$'
PROFILE_REMOTE_REGEX='(^|[:/])JeffreyBenjaminBrown/(live-)?midi(\.git)?$'
PROFILE_IMAGE='jeffreybbrown/hode:latest'
# MIDI currently depends on host-network visibility (e.g. host services using
# localhost). This is intentionally less isolated than the SKG profile.
PROFILE_NETWORK='host'
# Preserve the existing workflow: commits update the host/shared Git database.
# Git config/hooks and the worktree .git pointer are protected, but refs and
# objects are still shared across worktrees.
PROFILE_GIT_MODE='protected-shared'
PROFILE_PIPEWIRE=1
PROFILE_X11=1
PROFILE_ALSA=1
PROFILE_CAP_ADD=('SYS_NICE')
PROFILE_ULIMITS=('rtprio=99' 'memlock=-1')
PROFILE_CLAUDE_CONFIG_REL='my-dot-claude'
PROFILE_CODEX_HOOK=1
PROFILE_PORT_FILE=''
PROFILE_PORT_KEY=''
PROFILE_PUBLISH_ADDRESS=''
# The trusted launcher deliberately does not run host Git against agent-writable
# project data. A fresh worktree should have this submodule initialized by the
# user before launch if audition/drum samples are needed.
PROFILE_PREFLIGHT_PATHS=('drum-samples/.git')
