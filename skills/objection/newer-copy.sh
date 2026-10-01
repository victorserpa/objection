#!/bin/bash
# Warns when this copy of the skill is an old version in the plugin cache
# while a newer one is installed next to it. Claude Code keeps every
# version it ever installed (.../objection/objection/<version>/), and an
# agent that lost track of the skill's directory went looking there: a
# plain `sort` put 0.9.0 after 0.23.1, and an adopter's records were
# stamped by 0.9.0 for days. Advice only: it never stops the script that
# runs it.
#
#   bash newer-copy.sh    prints the warning on stderr, or nothing
dir="$(cd "$(dirname "$0")" && pwd -P)"
ver=$(cat "$dir/VERSION" 2>/dev/null) || exit 0
# The cache layout: <root>/<version>/skills/objection. Anything else (a
# clone, a skills directory) has no siblings to compare.
own=$(basename "$(dirname "$(dirname "$dir")")")
[ "$own" = "$ver" ] || exit 0
root=$(dirname "$(dirname "$(dirname "$dir")")")
# Numeric by field: `sort -V` is missing from some BSD and busybox sorts.
newest=$(ls "$root" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' |
  sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
[ -n "$newest" ] && [ "$newest" != "$ver" ] || exit 0
[ -f "$root/$newest/skills/objection/VERSION" ] || exit 0
echo "objection: this is $ver from the plugin cache, and $newest is installed next to it. Old versions stay in the cache: run the scripts from $root/$newest/skills/objection (the directory of the SKILL.md the agent loaded), never from a version picked by listing the cache." >&2
exit 0
