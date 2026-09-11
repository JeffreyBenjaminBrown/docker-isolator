#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
codex_home="${1:-${CODEX_HOME:-${HOME:?}/.codex}}"
hook_source="${2:-$script_dir/codex-hooks.json}"
hook_target="$codex_home/hooks.json"
config_file="$codex_home/config.toml"

# These pins authorize only the bundled local beep handler. If its definition
# changes, update both pins after reviewing the new hook in Codex; a stale pin
# deliberately leaves the changed hook untrusted.
expected_file_sha256="85e9689f6a7b408f795c9db0d0198c350287201498dcb9be3b846a235031945e"
trusted_handler_hash="sha256:107e899c6a53b92b6a616c4d2204978698adc40e73a3f06741c6f0d8aa45c2ec"
trust_section='[hooks.state."/home/ubuntu/.codex/hooks.json:stop:0:0"]'

fail() {
  echo "install-codex-beep-hook: $*" >&2
  exit 1
}

[ -f "$hook_source" ] && [ ! -L "$hook_source" ] \
  || fail "trusted hook template is missing or is a symlink: $hook_source"
[ ! -L "$codex_home" ] || fail "refusing symlinked Codex home: $codex_home"
mkdir -p -- "$codex_home"
[ -d "$codex_home" ] && [ ! -L "$codex_home" ] \
  || fail "Codex home is not an ordinary directory: $codex_home"

# Copy first, then hash the exact bytes that will be installed. This removes the
# check-then-copy race present in the older installer. mv -T replaces a hostile
# destination symlink/hardlink entry instead of following it.
hook_tmp="$(mktemp "$codex_home/.hooks.json.XXXXXX")"
config_tmp=""
cleanup() {
  [ -z "$hook_tmp" ] || rm -f -- "$hook_tmp"
  [ -z "$config_tmp" ] || rm -f -- "$config_tmp"
}
trap cleanup EXIT

cp -- "$hook_source" "$hook_tmp"
chmod 0644 "$hook_tmp"
actual_file_sha256="$(sha256sum "$hook_tmp" | awk '{print $1}')"
if [ "$actual_file_sha256" != "$expected_file_sha256" ]; then
  fail "refusing changed hook template: expected $expected_file_sha256, got $actual_file_sha256"
fi
mv -T -- "$hook_tmp" "$hook_target"
hook_tmp=""

# Leave an already-correct config byte-for-byte unchanged on normal launches.
if [ -f "$config_file" ] && awk \
  -v target="$trust_section" -v expected="$trusted_handler_hash" '
    $0 == target { in_target = 1; next }
    in_target && $0 == "trusted_hash = \"" expected "\"" { found = 1 }
    in_target && /^\[/ { in_target = 0 }
    END { exit(found ? 0 : 1) }
  ' "$config_file"; then
  echo "Codex beep hook is already installed and trusted in $codex_home"
  trap - EXIT
  exit 0
fi

config_tmp="$(mktemp "$codex_home/.config.toml.sound-hook.XXXXXX")"

if [ -f "$config_file" ]; then
  # Replace only this installer's exact trust table; preserve every other
  # setting and trust decision byte-for-byte apart from trailing newlines.
  awk -v target="$trust_section" '
    $0 == target { skipping = 1; next }
    skipping && /^\[/ { skipping = 0 }
    !skipping { print }
  ' "$config_file" > "$config_tmp"
  chmod --reference="$config_file" "$config_tmp"
else
  chmod 0600 "$config_tmp"
fi

printf '%s\ntrusted_hash = "%s"\n' \
  "$trust_section" "$trusted_handler_hash" >> "$config_tmp"
mv -T -- "$config_tmp" "$config_file"
config_tmp=""
trap - EXIT

echo "Installed trusted Codex beep hook in $codex_home"
