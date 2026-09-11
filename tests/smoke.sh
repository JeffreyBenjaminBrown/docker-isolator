#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
iso="$tmp/docker-isolator"
mkdir -p "$iso"
cp -a "$here/docker-isolator" "$here/profiles" "$here/trusted" "$iso/"
mkdir -p "$iso/projects" "$tmp/bin" "$tmp/networks"

cat > "$tmp/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
log="${FAKE_DOCKER_LOG:?}"
printf 'docker' >> "$log"; printf ' <%s>' "$@" >> "$log"; printf '\n' >> "$log"
case "${1:-} ${2:-}" in
  'container inspect') exit 1 ;;
  'network inspect') [ -e "$FAKE_NETWORKS/${3:-}" ] && exit 0 || exit 1 ;;
  'network create') touch "$FAKE_NETWORKS/${@: -1}"; echo fake-network; exit 0 ;;
esac
case "${1:-}" in
  ps) exit 0 ;;
  inspect) exit 1 ;;
  run) echo fake-container; exit 0 ;;
esac
exit 0
DOCKER
chmod +x "$tmp/bin/docker"

# Ordinary SKG checkout.
skg="$iso/projects/skg3"
mkdir -p "$skg/.git/hooks" "$skg/data" "$skg/.codex/homestate"
cat > "$skg/.git/config" <<'CFG'
[core]
  bare = false
[remote "origin"]
  url = git@github.com:JeffreyBenjaminBrown/skg.git
CFG
printf 'ref: refs/heads/main\n' > "$skg/.git/HEAD"
printf 'port = 1730\n' > "$skg/data/skgconfig.toml"
printf 'legacy\n' > "$skg/.codex/homestate/history.jsonl"

log="$tmp/skg.log"
FAKE_DOCKER_LOG="$log" FAKE_NETWORKS="$tmp/networks" PATH="$tmp/bin:$PATH" \
DOCKER_ISOLATOR_STATE_HOME="$tmp/state-skg" \
  "$iso/docker-isolator" launch "$skg" >/dev/null

grep -F -- '<--publish> <127.0.0.1:1730:1730>' "$log" >/dev/null
grep -F -- "source=$skg/.git,target=/home/ubuntu/host/.git" "$log" >/dev/null
grep -F -- 'target=/home/ubuntu/host/.git/config,readonly' "$log" >/dev/null
grep -F -- 'target=/home/ubuntu/host/.git/hooks,readonly' "$log" >/dev/null
grep -F -- '<--cap-drop> <ALL>' "$log" >/dev/null
grep -F -- '<no-new-privileges=true>' "$log" >/dev/null

# Synthetic version of the uploaded MIDI relative-worktree layout.
midi="$iso/projects/midi"
wt="$midi/worktrees/main"
gd="$midi/.bare/worktrees/main"
mkdir -p "$midi/.bare/hooks" "$gd" "$wt/drum-samples"
printf 'gitdir: ./.bare\n' > "$midi/.git"
cat > "$midi/.bare/config" <<'CFG'
[core]
  bare = true
[remote "origin"]
  url = git@github.com:JeffreyBenjaminBrown/live-midi.git
[extensions]
  relativeWorktrees = true
CFG
printf 'gitdir: ../../.bare/worktrees/main\n' > "$wt/.git"
printf '../../..\n' > "$gd/unused"  # irrelevant, catches overly broad parsers
printf '../..\n' > "$gd/commondir"
printf '../../../worktrees/main/.git\n' > "$gd/gitdir"
printf 'ref: refs/heads/main\n' > "$gd/HEAD"
printf 'gitdir: ../../.bare/modules/drum-samples\n' > "$wt/drum-samples/.git"

log="$tmp/midi.log"
FAKE_DOCKER_LOG="$log" FAKE_NETWORKS="$tmp/networks" PATH="$tmp/bin:$PATH" \
DOCKER_ISOLATOR_STATE_HOME="$tmp/state-midi" \
  "$iso/docker-isolator" launch "$wt" >/dev/null

grep -F -- '<--network> <host>' "$log" >/dev/null
grep -F -- '<--cap-add> <SYS_NICE>' "$log" >/dev/null
grep -F -- "source=$midi,target=/home/ubuntu/host,readonly" "$log" >/dev/null
grep -F -- "source=$wt,target=/home/ubuntu/host/worktrees/main" "$log" >/dev/null
grep -F -- "source=$midi/.bare,target=/home/ubuntu/host/.bare" "$log" >/dev/null
grep -F -- 'target=/home/ubuntu/host/worktrees/main/.git,readonly' "$log" >/dev/null
ptr="$(find "$tmp/state-midi" -name worktree-dot-git -type f -print -quit)"
grep -Fx 'gitdir: ../../.bare/worktrees/main' "$ptr" >/dev/null

# Read-only Git mode keeps worktree files writable but mounts metadata RO.
log="$tmp/readonly.log"
FAKE_DOCKER_LOG="$log" FAKE_NETWORKS="$tmp/networks" PATH="$tmp/bin:$PATH" \
DOCKER_ISOLATOR_STATE_HOME="$tmp/state-readonly" \
  "$iso/docker-isolator" launch "$skg" --git-mode readonly --container skg3-ro >/dev/null
grep -F -- "source=$skg/.git,target=/home/ubuntu/host/.git,readonly" "$log" >/dev/null

# describe must not create persistent state.
rm -rf "$tmp/describe-state"
DOCKER_ISOLATOR_STATE_HOME="$tmp/describe-state" \
  "$iso/docker-isolator" describe "$wt" >/dev/null
[ ! -e "$tmp/describe-state" ]

echo 'smoke tests passed'
