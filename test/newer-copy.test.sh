#!/bin/bash
# Cases for skills/objection/newer-copy.sh: an old copy of the skill in
# the plugin cache warns when a newer version sits next to it.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

copy() { # version
  mkdir -p "$T/cache/objection/$1/skills/objection"
  cp "$ROOT/skills/objection/newer-copy.sh" "$T/cache/objection/$1/skills/objection/"
  printf '%s\n' "$1" >"$T/cache/objection/$1/skills/objection/VERSION"
}
copy 0.9.0
copy 0.23.1
copy 0.10.2
# The old copy warns and names the newest (numeric, not text, order).
msg=$(bash "$T/cache/objection/0.9.0/skills/objection/newer-copy.sh" 2>&1)
case "$msg" in *"this is 0.9.0"*"0.23.1 is installed"*) ;; *) fail "0.9.0 did not warn about 0.23.1: [$msg]" ;; esac
# The newest copy says nothing.
msg=$(bash "$T/cache/objection/0.23.1/skills/objection/newer-copy.sh" 2>&1)
[ -z "$msg" ] || fail "0.23.1 warned: [$msg]"
# A directory that is not a version is ignored.
mkdir -p "$T/cache/objection/9.9.9-rc/skills/objection"
printf '9.9.9-rc\n' >"$T/cache/objection/9.9.9-rc/skills/objection/VERSION"
msg=$(bash "$T/cache/objection/0.23.1/skills/objection/newer-copy.sh" 2>&1)
[ -z "$msg" ] || fail "a non-version directory counted: [$msg]"
# A prerelease copy is not ranked: no advice to "upgrade" to an older release.
cp "$ROOT/skills/objection/newer-copy.sh" "$T/cache/objection/9.9.9-rc/skills/objection/"
msg=$(bash "$T/cache/objection/9.9.9-rc/skills/objection/newer-copy.sh" 2>&1)
[ -z "$msg" ] || fail "a prerelease copy warned: [$msg]"
# Reached through a symlink, the old copy still warns (pwd -P).
ln -s "$T/cache/objection/0.9.0" "$T/cache/objection/current"
msg=$(bash "$T/cache/objection/current/skills/objection/newer-copy.sh" 2>&1)
case "$msg" in *"this is 0.9.0"*"0.23.1 is installed"*) ;; *) fail "the symlinked old copy did not warn: [$msg]" ;; esac
# Outside the cache layout (this repository): nothing.
msg=$(bash "$ROOT/skills/objection/newer-copy.sh" 2>&1)
[ -z "$msg" ] || fail "the repository copy warned: [$msg]"
# It never fails the script that runs it.
bash "$T/cache/objection/0.9.0/skills/objection/newer-copy.sh" 2>/dev/null || fail "newer-copy.sh exited non-zero"

[ "$failures" = 0 ] && echo "newer-copy: all cases passed" || echo "newer-copy: $failures failure(s)"
[ "$failures" = 0 ]
