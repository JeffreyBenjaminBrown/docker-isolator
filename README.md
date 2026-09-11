# docker-isolator

A small trusted host-side launcher for coding-agent Docker containers.

The trust boundary is the directory containing this repository. Child coding
repositories belong under `projects/` and are deliberately ignored by this
repository's Git history:

```text
docker-isolator/
  docker-isolator          # trusted host executable
  profiles/                # trusted per-project Docker policy
  trusted/                 # trusted Codex hook installer/template
  projects/
    skg/                    # untrusted/agent-writable child repo
    midi/                   # untrusted/agent-writable worktree hub
      .bare/
      worktrees/
        main/
        2/
        3/
```

**Never bind-mount the `docker-isolator/` trust root into an agent container
read-write.** The shipped launcher refuses targets that resolve outside
`projects/`; its built-in layouts mount only the selected child project family.

## Why this exists

A launcher stored inside an agent-writable checkout is not a security boundary.
An agent can rewrite that launcher (or a helper it invokes), and the next host
launch executes the changed code as the host user. An in-project directory used
as a future Docker bind source is also unsafe because the agent can replace the
source path with a symlink before the next launch.

`docker-isolator` keeps host-executed launch code and bind-source roots outside
agent-writable child repositories.

## Put repositories under `projects/`

For an ordinary checkout:

```sh
mv /wherever/skg /path/to/docker-isolator/projects/skg
```

For the MIDI layout, move the whole hub together so its relative worktree
metadata remains together:

```sh
mv /wherever/midi /path/to/docker-isolator/projects/midi
```

The attached MIDI example uses relative Git metadata (`midi/.bare` plus
`midi/worktrees/{main,2,3}`), so moving the whole `midi/` directory preserves
that layout.

No Git history needs to be rewritten by the isolator.

## Discovery: what is automatic

The launcher reads `.git` pointer files and `commondir` metadata as plain path
data; it does not need to run `git status`, hooks, project scripts, or a
project-local `docker.sh`.

For a target it normally discovers:

- the project family (`skg`, `skg3`, `midi`, ...),
- ordinary checkout vs linked-worktree layout,
- worktree top,
- worktree Git directory and shared Git common directory,
- the remote URL (only for profile matching/information),
- a default container name (`skg3`, `midi-main`, `midi-2`, ...),
- a stable per-path external state directory.

Project policy is intentionally **not** inferred from untrusted files. Trusted
profiles decide things such as host networking, X11, sound-device access,
capabilities, and how a service port is exposed.

The supplied profiles match the examples:

- `profiles/skg.sh`: isolated per-worktree Docker bridge, SKG port read from
  `data/skgconfig.toml` (or `$SKG_CONFIG`) and published on `127.0.0.1` only,
  PipeWire when available.
- `profiles/midi.sh`: preserves the old MIDI requirements: host networking,
  PipeWire, X11, `/dev/snd`, sound-device cgroup access, `SYS_NICE`, realtime
  priority and unlimited memlock. Those are intentionally broad host
  capabilities and are reported by `doctor`/`describe`.

If automatic profile matching is ambiguous, pass `--profile skg` or
`--profile midi`. A nonstandard old container name can similarly be supplied
with `--container NAME`.

## Commands

From the `docker-isolator` checkout:

```sh
./docker-isolator describe projects/skg
./docker-isolator doctor projects/skg
./docker-isolator launch projects/skg

./docker-isolator describe projects/midi/worktrees/main
./docker-isolator launch projects/midi/worktrees/main
./docker-isolator launch projects/midi/worktrees/2
```

`PATH` may point anywhere inside the selected worktree; it defaults to the
current directory.

### Repair an older launch

```sh
./docker-isolator repair projects/skg
./docker-isolator repair projects/midi/worktrees/main
```

`repair` prefers the derived old container name. If that name does not exist,
it searches Docker containers for one whose bind mounts include the selected
worktree. If exactly one matches, no input is needed. If several match, an
interactive run asks which one; a script/noninteractive run requires
`--container NAME`.

When an old container exists, repair:

1. stops it if necessary (with confirmation unless `--yes`),
2. copies the stopped container's visible `/home/ubuntu/.codex`, so recovery
   works whether old Codex state was ephemeral or bind-mounted,
3. repairs the pinned Codex beep hook from `trusted/`,
4. removes the old container (again confirmed unless `--yes`), and
5. launches its secure replacement.

Use `--no-launch` to stop after state recovery/removal. If no old container
exists, repair falls back to copying (never deleting) the legacy
`WORKTREE/.codex/homestate` when present. It also recognizes the external
`~/.local/state/skg-docker/...` layout made by the earlier one-off SKG
hardening. If the checkout was moved into `projects/`, it can use that older
state's `project-path` marker when exactly one candidate has the same checkout
basename. For an unusual or ambiguous old state location, set
`DOCKER_ISOLATOR_LEGACY_CODEX=/absolute/path/to/old/codex`.

If both a current external Codex state and a different old-container state are
nonempty, repair does not merge them. It preserves the recovered copy under the
instance state directory and tells you where it put it.

## Git worktrees and the remaining cross-worktree tradeoff

The default supplied profiles use `protected-shared` Git mode because the old
workflow expected agents to make commits directly in the host repository.

For a linked worktree, the container gets:

- the whole project-family/hub read-only,
- the selected worktree read-write,
- the shared Git common directory read-write,
- a trusted read-only replacement for the worktree `.git` pointer,
- trusted read-only Git config and an empty read-only default hooks directory.

For a normal checkout, the checkout is read-write and `.git` is pinned as a
separate nested mount; config/hooks receive the same protection.

This closes an important delayed-host-execution path: an agent cannot simply
replace the worktree `.git` pointer, repository config, or default Git hooks and
wait for routine host Git commands to execute them.

It does **not** make shared Git state worktree-private. If an agent can create
ordinary commits in the host/shared Git database, it can also write objects and
refs in that database. Therefore a MIDI agent in `main` can deliberately alter
refs used by `2` or `3`, and sibling containers can observe those changes.
That is inherent in giving mutually untrusted agents direct write access to one
Git database; Docker cannot express "may update only this one Git branch" as a
filesystem permission.

For stronger isolation, use:

```sh
./docker-isolator launch projects/midi/worktrees/main --git-mode readonly
```

The worktree files remain writable, but Git metadata is mounted read-only, so
the agent can edit files but cannot commit into the host repository from the
container.

## Host capabilities that remain intentional

All profiles apply `no-new-privileges`, drop all capabilities first, and use a
default PID limit of 4096. The MIDI profile adds back only `SYS_NICE` because
its realtime audio workload asked for it.

Some project functionality itself requires broad host surfaces:

- **MIDI host networking**: the container shares the host network namespace.
  It can reach host-local services and other host-network containers. This is
  not network isolation.
- **X11**: access to the host X11 socket is a broad GUI capability. Depending on
  the host/X server setup, X11 clients can have much more visibility/control
  than a normal sandboxed GUI application.
- **PipeWire**: exposes the host user's audio service to the container when the
  socket exists.
- **`/dev/snd`**: MIDI exposes host ALSA/MIDI sound devices when present.
- **credentials**: Codex and Claude must be able to read the credentials needed
  for their own sessions; an already-authorized hostile process could try to
  exfiltrate those credentials.

The SKG profile deliberately does not use host networking; its app port is
published only on loopback.

## Host Git and other project code are not magically trustworthy

The protection above prevents **future container writes through the protected
Git metadata paths**. It cannot prove that a repository already exposed to an
older unsafe agent was never modified before repair. `doctor` warns about some
Git configuration that can redirect Git toward executable code (custom hooks,
includes, fsmonitor, filters/diff/merge drivers), but retroactive compromise
cannot be ruled out automatically.

Likewise, ordinary project files remain agent-writable. Do not treat scripts,
build definitions, `.envrc`, editor-local code, or other executable project
content as trusted merely because the container launcher is now trusted.
Review changes before executing such code on the host, especially after a
session that you are treating as potentially hostile.

## MIDI submodule behavior

The old MIDI `docker.sh` automatically ran this on the **host** before launch:

```sh
git submodule update --init drum-samples
```

The trusted launcher deliberately does not execute host Git operations whose
behavior depends on agent-writable project data. The MIDI profile instead warns
when `drum-samples/.git` is missing. Initialize/update that submodule yourself
from a repository state you are willing to trust before launching if the
sample-dependent features are needed. The three worktrees in the supplied MIDI
archive already had that submodule populated.

## State locations

By default persistent isolator state is below:

```text
~/.local/state/docker-isolator/
```

Each worktree gets a path-hashed instance directory containing:

- `codex/` — mounted at `/home/ubuntu/.codex`,
- `protected/` — trusted copies/overlays used to pin Git metadata,
- `instance.conf` — the expected worktree/profile/container identity.

The parent of those paths is never mounted into the agent container, so the
agent can modify the Codex-home **contents** it legitimately uses but cannot
replace the future bind-source directory itself with a project symlink.

## Useful overrides

```sh
DOCKER_ISOLATOR_MEMORY=12g DOCKER_ISOLATOR_CPUS=8 \
  ./docker-isolator launch projects/skg

DOCKER_ISOLATOR_PIDS_LIMIT=8192 \
  ./docker-isolator launch projects/midi/worktrees/main

DOCKER_ISOLATOR_IMAGE=jeffreybbrown/hode:some-tag \
  ./docker-isolator launch projects/skg

DOCKER_ISOLATOR_LEGACY_CODEX=/old/state/codex \
  ./docker-isolator repair projects/skg

SKG_CONFIG=data/alternate-config.toml \
  ./docker-isolator launch projects/skg
```

The profiles themselves are part of the trusted `docker-isolator` repository.
Review and commit profile changes there; do not move them into child projects.
