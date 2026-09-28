#!/bin/bash
# Runs one round of the debate up to the judge, so the main session does
# not spend its own (expensive) context driving it.
#
#   debate.sh [base] [goal] [scope]                    round 1
#   debate.sh --since <commit> [base] [goal] [scope]   later rounds: the fix only
#   --extra-round (before the rest)                    one round past the cap,
#                                                      when the human asked for it
#   --force                                            re-run a commit whose record
#                                                      is already judged
#   --large                                            review a diff over 800 changed
#                                                      lines anyway (else exit 5)
#
# Rounds are capped: the base config's maxRounds, else 2 under lean and 3
# otherwise. A round is a commit of this branch (since the base) that has
# a draft or stamped record; the cap refuses a new one and says what to
# do. Measured: a PR whose agent fixed every LOW finding went 8 rounds,
# each one finding something in the previous fix.
#
# base: the branch the PR targets. Omitted (or not a branch on origin), it
# is the config's defaultBase, and the first argument is the goal.
#
# Steps: the brief (brief.sh), the accuser (review.sh, isolated), the
# defender only for the findings the budget sends it, and a draft record
# with the Judge and Open sections left to the main session. Prints a
# short summary and the draft's path; the session then reads that one
# file instead of every step.
#
# The budget is the base branch's (brief.sh reads it from there). Under
# `standard` and `thorough`, each matching `reviewers` entry also runs as
# its own isolated accuser, with its focus.
#
# When the skill under review is in the repository itself (objection's own
# repository), the roles come from the base branch: a branch must not
# review itself with prompts it rewrote.
#
# Old artifacts in <git-common-dir>/objection are pruned to the newest
# OBJECTION_KEEP (default 10) of each kind; stamped records are kept.
#
# Exit codes are review.sh's: 3 means no claude CLI (run the roles as
# subagents, reference/manual-roles.md), 2 a missing tool, 1 a failed run. When
# the defender fails, the draft is still written and summarised, and the
# exit code is the defender's: rerun only the defense, not the round.
set -eu
# File names as they are (git quotes "src/á.ts" otherwise, and an
# invariant's paths regex then never matches it). Appended to any git
# config the environment already passes.
_n="${GIT_CONFIG_COUNT:-0}"
export "GIT_CONFIG_KEY_$_n=core.quotePath" "GIT_CONFIG_VALUE_$_n=false" "GIT_CONFIG_COUNT=$((_n + 1))"

# Git Bash (Windows) rewrites an argument like "origin/main:file" as a
# path list ("origin\\main;file"); these calls must reach git untouched.
gitref() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' git "$@"; }

since=""
extra=""
force=""
large=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="${2:?--since needs the commit of the previous round}"; shift 2 ;;
    --extra-round) extra=yes; shift ;;
    --force) force=yes; shift ;;
    --large) large=yes; shift ;;
    *) break ;;
  esac
done
# node on PATH may still not run: a version manager's shim exits 126 when
# .tool-versions or .nvmrc pins a version that is not installed.
if ! node_err=$(node -e 0 2>&1); then
  echo "objection: node does not run in this repository ($(printf '%s' "$node_err" | head -n 1)). If a version manager (asdf, mise, volta, nvm, fnm) pins a version here, install it; otherwise install Node.js 18 or later, or put one that runs first on PATH." >&2
  exit 2
fi
# Physical paths: git reports the toplevel resolved (/private/var on macOS).
here="$(cd "$(dirname "$0")" && pwd -P)"
top="$(git rev-parse --show-toplevel)"
cd "$top"

base=""
defaulted=""
if [ $# -gt 0 ] && [ -n "$1" ] && git rev-parse --verify -q "refs/remotes/origin/$1" >/dev/null; then
  base="$1"
  shift
elif [ $# -gt 0 ]; then
  defaulted="$1"
fi
if [ -z "$base" ]; then
  for c in .objection.json .claude/objection.json; do
    [ -f "$c" ] || continue
    # A base the config lists but origin lacks is a missing fetch, not a
    # goal: running against defaultBase instead would review the wrong diff.
    if [ $# -gt 0 ] && node -e '
      try {
        const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        process.exit([...(c.bases || []), c.defaultBase].includes(process.argv[2]) ? 0 : 1);
      } catch { process.exit(1); }' "$c" "$1"; then
      echo "origin/$1 is not here: run git fetch origin $1, then debate again." >&2
      exit 1
    fi
    break
  done
  for c in .objection.json .claude/objection.json; do
    [ -f "$c" ] || continue
    base=$(node -e '
      try {
        const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        console.log(c.defaultBase || (c.bases || [])[0] || "");
      } catch { console.log(""); }' "$c")
    break
  done
fi
if [ -z "$base" ]; then
  base=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
  base="${base#origin/}"
fi
goal="${1:-not stated}"
scope="${2:-not stated}"
base_note=""
if [ -n "$defaulted" ]; then
  base_note="base: $base (the default: \"$defaulted\" is not a branch on origin, so it was read as the goal)"
  # Said before anything is spent, and again in the summary.
  echo "objection: $base_note" >&2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# One form for both paths before comparing: on Windows git reports C:/...
# while Git Bash says /tmp/... or /c/... (pwd -W gives the C:/ form there).
canon() { (cd "$1" && { pwd -W 2>/dev/null || pwd -P; }); }
here_c=$(canon "$here")
top_c=$(canon "$top")
case "$here_c/" in
  "$top_c/"*)
    rel="${here_c#"$top_c/"}"
    mkdir -p "$tmp/roles"
    for r in accuser defender; do
      # New at the base (the PR that adds the skill): the working copy.
      gitref show "origin/$base:$rel/roles/$r.md" >"$tmp/roles/$r.md" 2>/dev/null ||
        cp "$here/roles/$r.md" "$tmp/roles/$r.md"
    done
    export OBJECTION_ROLES_DIR="$tmp/roles"
    ;;
esac

diff_base="origin/$base"
# Only this script sets it, and only for a later round.
unset OBJECTION_PRIOR_ROUNDS
if [ -n "$since" ]; then
  diff_base="$since"
  goal="Round after a fix: hunt regressions from the fix first. Goal of the PR: $goal"
  # What the judge already ruled in this branch's earlier rounds, newest
  # first (the cut below then drops the oldest), for brief.sh to show the reviewers. Without it a later accuser
  # sees only the fix, and can accuse it for doing what a ruling asked:
  # measured on an adopter's PR, round 1 condemned a Spanish label as
  # "Siempre activas", round 2 condemned the fix "Siempre activo".
  # Only judged records count (a draft's Judge section is still a TODO,
  # which a finding's text may quote elsewhere); every
  # cell and ruling is cut short, and the whole to 150 lines.
  prior_dir="$(cd "$(git rev-parse --git-common-dir)" && pwd)/objection"
  prior="$tmp/prior-rounds"
  : >"$prior"
  head_sha=$(git rev-parse HEAD)
  for c in $(git rev-list "origin/$base..HEAD" 2>/dev/null); do
    [ "$c" = "$head_sha" ] && continue
    f="$prior_dir/$c.md"
    [ -f "$f" ] || f="$prior_dir/record-$c.md"
    [ -f "$f" ] || continue
    awk '/^## /{j=($0=="## Judge")} j&&/TODO\(judge\)/{f=1} END{exit !f}' "$f" && continue
    awk -v c="${c:0:7}" '
      function cut(s, n) { return length(s) > n ? substr(s, 1, n) "..." : s }
      BEGIN { printf "### Round at %s\n\n", c }
      /^## / { sec = $0; next }
      sec == "## Accusation" && /^\| *[0-9]+ *\|/ { print cut($0, 400); next }
      sec == "## Judge" && NF { if (!j++) print "\nRulings:"; print cut($0, 600) }
      END { print "" }' "$f" >>"$prior"
  done
  if [ -s "$prior" ]; then
    head -n 150 "$prior" >"$prior.cut" && mv "$prior.cut" "$prior"
    export OBJECTION_PRIOR_ROUNDS="$prior"
  fi
fi
brief=$(bash "$here/brief.sh" "$diff_base" "$goal" "$scope" "origin/$base")
# Markers are read from the header only: brief.sh writes them above its
# first "objection-header-end" line. The rest of the brief quotes the
# branch under review (diff, definitions), so a marker planted there would
# pick a reviewer or run an invariant check's command.
header="$tmp/brief-header"
sed '/^<!-- objection-header-end -->$/q' "$brief" >"$header"
grep -qx '<!-- objection-header-end -->' "$header" || { echo "the brief has no header end marker: rebuild it with this version's brief.sh." >&2; exit 1; }

budget=$(sed -n 's/^<!-- objection-budget: \([a-z]*\) -->$/\1/p' "$header" | head -n 1)
[ -n "$budget" ] || budget=lean
# Model and effort: the brief's tier (from the base config) unless the
# caller set OBJECTION_MODEL / OBJECTION_EFFORT.
tier=$(sed -n 's/^<!-- objection-model: \(.*\) -->$/\1/p' "$header" | head -n 1)
set -- $tier
tier_model="${1:-sonnet}"
tier_effort="${2:-medium}"
tier_reason="${3:-default}"
brief_reason="$tier_reason"
if [ -n "${OBJECTION_MODEL:-}" ]; then tier_model="$OBJECTION_MODEL"; tier_reason="OBJECTION_MODEL"; fi
defender_effort="$tier_effort"
# A later round reviews only the fix: the accuser runs at the config's
# laterEffort (default low); the defender keeps the round's effort.
if [ -n "$since" ]; then
  later=$(sed -n 's/^<!-- objection-later-effort: \([A-Za-z]*\) -->$/\1/p' "$header" | head -n 1)
  tier_effort="${later:-low}"
  tier_reason="$tier_reason, later round"
fi
if [ -n "${OBJECTION_EFFORT:-}" ]; then
  tier_effort="$OBJECTION_EFFORT"
  defender_effort="$OBJECTION_EFFORT"
  tier_reason="${tier_reason%, later round}, OBJECTION_EFFORT"
fi
# The defender's model: the config's models.defender (default sonnet),
# whatever the accuser runs on; OBJECTION_DEFENDER_MODEL overrides it.
defender_model=$(sed -n 's/^<!-- objection-defender: \([A-Za-z0-9._-]*\) -->$/\1/p' "$header" | head -n 1)
defender_model="${OBJECTION_DEFENDER_MODEL:-${defender_model:-sonnet}}"
export OBJECTION_MODEL="$tier_model" OBJECTION_EFFORT="$tier_effort"
sha=$(git rev-parse HEAD)
dir="$(cd "$(git rev-parse --git-common-dir)" && pwd)/objection"
accusation="$dir/accusation-$sha.md"
findings="$dir/findings-$sha.md"
defense="$dir/defense-$sha.md"
record="$dir/record-$sha.md"

# A judged record for this commit is the session's work: a new run would
# overwrite it and pay for the round again.
if [ -f "$record" ] && ! grep -q 'TODO(judge)' "$record" && [ -z "$force" ]; then
  echo "objection: ${sha:0:7} already has a judged record ($record); stamp it, or pass --force to debate it again." >&2
  exit 1
fi
# The round cap: commits of this branch that already had a round.
max_rounds=$(sed -n 's/^<!-- objection-max-rounds: \([0-9]*\) -->$/\1/p' "$header" | head -n 1)
[ -n "$max_rounds" ] || { [ "$budget" = lean ] && max_rounds=2 || max_rounds=3; }
done_rounds=0
for c in $(git rev-list "origin/$base..HEAD" 2>/dev/null); do
  [ "$c" = "$sha" ] && continue
  { [ -f "$dir/record-$c.md" ] || [ -f "$dir/$c.md" ]; } && done_rounds=$((done_rounds + 1))
done
if [ "$done_rounds" -ge "$max_rounds" ] && [ -z "$extra" ]; then
  cat >&2 <<EOF_CAP
objection: this branch already had $done_rounds round(s), the cap is $max_rounds (maxRounds, or the $budget budget's default).
Stop fixing and close the record: what is still open goes under "## Open" with its severity. MEDIUM and LOW ship with the record (track them in an issue); a BLOCKER or HIGH that is still open means the human decides. A further round runs only when the human asks for it: debate.sh --extra-round ...
EOF_CAP
  exit 4
fi
rm -f "$findings" "$defense"

# The base config the rules came from, by content hash.
config_id="none"
for c in .objection.json .claude/objection.json; do
  if gitref show "origin/$base:$c" >"$tmp/config" 2>/dev/null; then
    config_id="$c@origin/$base sha256:$(node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex").slice(0, 12))' "$tmp/config")"
    break
  fi
done
# The first PR after init: brief.sh used the working copy, and says so.
if [ "$config_id" = none ]; then
  for c in .objection.json .claude/objection.json; do
    if [ -f "$c" ]; then
      config_id="$c from the working copy (origin/$base has none yet) sha256:$(node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex").slice(0, 12))' "$c")"
      break
    fi
  done
fi
# A monorepo's package configs the brief read (brief.sh), by content hash
# too, and their verify commands, which the agent runs like the root ones.
pkg_ids=$(sed -n 's/^<!-- objection-package: \(.*\) -->$/\1/p' "$header" |
  awk -F'\t' '{ printf "%s%s/.objection.json sha256:%s", (NR > 1 ? ", " : ""), $1, $2 }')
[ -z "$pkg_ids" ] || config_id="$config_id; packages $pkg_ids"
pkg_verify=$(sed -n 's/^<!-- objection-package-verify: \(.*\) -->$/\1/p' "$header")
say_pkg_verify() {
  [ -n "$pkg_verify" ] || return 0
  echo "verify for the packages this diff touches (from the repository root, before the judge):"
  printf '%s\n' "$pkg_verify" | sed 's/^/  /'
}

# The round number goes into the record, so the human reading the PR sees
# how many rounds it took and whether one ran past the cap.
round=$((done_rounds + 1))
round_line="Round $round of $max_rounds."
[ "$round" -le "$max_rounds" ] || round_line="Round $round, past the cap of $max_rounds (--extra-round: only when the human asked for it)."
draft_head() {
  printf '# Debate: %s @ %s\n\n' "$(git rev-parse --abbrev-ref HEAD)" "${sha:0:7}"
  printf '%s\n\n' "$round_line"
}
draft_tail() {
  printf '\n## Judge\n\n'
  printf 'TODO(judge): rule on every finding with the rules of the Judge section of SKILL.md.\n'
  printf '\n## Open\n\n'
  printf 'TODO(judge): what stays open, then OPEN: BLOCKER=<n> HIGH=<n>, then the VERDICT line.\n'
}

# A small lean diff that no invariant or strongPaths names, and that
# touches no migration, SQL or schema file, is not worth a reviewer: the judge reads it and the verify step still runs. The
# threshold is the base config's smallDiff (default 20; 0 turns it off),
# or OBJECTION_SMALL_DIFF.
lines=$(sed -n 's/^<!-- objection-lines: \([0-9]*\) -->$/\1/p' "$header" | head -n 1)
# A diff past OBJECTION_LARGE_DIFF (800) changed lines is refused before
# anything is spent: the brief keeps only its first lines, and reviewers
# then guess about the code cut off. Measured on a 4600-line PR: its one
# HIGH was about a type in a file past the cut, and it was wrong.
large_max="${OBJECTION_LARGE_DIFF:-800}"
case "$large_max" in '' | *[!0-9]*) large_max=800 ;; esac
if [ -z "$large" ] && [ -n "$lines" ] && [ "$large_max" -gt 0 ] && [ "$lines" -gt "$large_max" ]; then
  echo "objection: the diff has $lines changed lines, over $large_max. Tell the human before spending: suggest splitting the PR, or run debate.sh --large to review it as it is (the brief keeps the first ${OBJECTION_BRIEF_MAX_LINES:-3000} lines of the diff)." >&2
  exit 5
fi
small=$(sed -n 's/^<!-- objection-small-diff: \([0-9]*\) -->$/\1/p' "$header" | head -n 1)
[ -z "${OBJECTION_SMALL_DIFF:-}" ] || small="$OBJECTION_SMALL_DIFF"
case "$small" in '' | *[!0-9]*) small=20 ;; esac
if [ "$budget" = lean ] && [ "$brief_reason" = default ] && [ "$small" -gt 0 ] &&
  [ -n "$lines" ] && [ "$lines" -le "$small" ]; then
  skipped="skipped (small diff: $lines changed lines, at most $small)"
  {
    draft_head
    printf 'Budget: %s. Diff: %s...HEAD.\n\n' "$budget" "$diff_base"
    printf '## Accusation\n\nNo reviewers ran: small diff (%s changed lines, at most %s, no invariant or strongPaths match, and no database file). The judge reads the diff and rules on it alone.\n' "$lines" "$small"
    printf '\n## Defense\n\nnot run.\n'
    # Pre-filled for the common case, except the one thing only the judge
    # can say: what the diff does and why it is safe. The script never
    # writes that sentence for them.
    printf '\n## Judge\n\n'
    printf 'TODO(judge): replace this line with one sentence of your own on what the %s changed lines do and why they are safe. If something is wrong, write it here and in Open instead, and fix the counts and the verdict.\n' "$lines"
    printf '\n## Open\n\nNothing.\n\nOPEN: BLOCKER=0 HIGH=0\nVERDICT: APPROVED\n'
  } >"$record"
  echo "objection: $(git rev-parse --abbrev-ref HEAD) @ ${sha:0:7}, budget $budget, diff $diff_base...HEAD"
  [ -z "$defaulted" ] || echo "$base_note"
  echo "reviewers: $skipped"
  echo "draft record: $record"
  say_pkg_verify
  echo "next: read the diff (git diff $diff_base...HEAD), replace the TODO(judge) line with what you checked, then stamp.sh."
  exit 0
fi

# Invariants with a verify command (base config) that this diff touches:
# run each from the repository root before any reviewer. A failure is a
# BLOCKER decided by the command, not by a model; it goes into the
# accusation, numbered like the rest, and to the defender.
checks=""
check_rows=""
while IFS="$(printf '\t')" read -r cmd rule; do
  [ -n "$cmd" ] || continue
  # </dev/null: a check that reads stdin must not eat the next check's line.
  if out_check=$(cd "$top" && bash -c "$cmd" 2>&1 </dev/null); then
    checks="${checks}- \`$cmd\` (invariant: $rule): passed
"
  else
    code=$?
    last=$(printf '%s\n' "$out_check" | tail -n 3 | tr '\n|' '  ' | cut -c1-200)
    checks="${checks}- \`$cmd\` (invariant: $rule): FAILED, exit $code
"
    cell_cmd=$(printf '%s' "$cmd" | tr '|' '/')
    cell_rule=$(printf '%s' "$rule" | tr '|' '/')
    check_rows="${check_rows}| BLOCKER | INVARIANT | (verify) | the check for \"$cell_rule\" fails: \`$cell_cmd\` exits $code | test | $last |
"
  fi
done <<EOF_CHECKS
$(sed -n 's/^<!-- objection-invariant-check: \(.*\) -->$/\1/p' "$header")
EOF_CHECKS

# A rebase or GitHub's "Update branch" gives the same diff a new SHA. When
# an APPROVED record already judged exactly this diff (same patch-id,
# against the same base) and the commits the base gained touch none of
# the changed files, no reviewer runs: the old record is carried over and
# the judge confirms it. A base commit in any changed file (either name
# of a rename) or in the objection config or precedents, a failed
# invariant check,
# --since, --force or OBJECTION_NO_CARRY=1: the full round runs.
carried=""
if [ -z "$since" ] && [ -z "$force" ] && [ -z "$check_rows" ] && [ -z "${OBJECTION_NO_CARRY:-}" ]; then
  new_mb=$(git merge-base "origin/$base" HEAD 2>/dev/null || true)
  new_pid=$( { git diff "$new_mb" HEAD 2>/dev/null || true; } | git patch-id --stable | cut -d' ' -f1)
  if [ -n "$new_mb" ] && [ -n "$new_pid" ]; then
    for old_rec in "$dir"/*.md; do
      old=$(basename "$old_rec" .md)
      case "$old" in *[!0-9a-f]* | "$sha") continue ;; esac
      [ "${#old}" = 40 ] || continue
      head -n 1 "$old_rec" | grep -qx "<!-- objection: sha=$old base=origin/$base -->" || continue
      [ "$(grep '^VERDICT: ' "$old_rec" | tail -n 1)" = "VERDICT: APPROVED" ] || continue
      git cat-file -e "$old^{commit}" 2>/dev/null || continue
      old_mb=$(git merge-base "origin/$base" "$old" 2>/dev/null) || continue
      git merge-base --is-ancestor "$old_mb" "$new_mb" 2>/dev/null || continue
      [ "$(git diff "$old_mb" "$old" | git patch-id --stable | cut -d' ' -f1)" = "$new_pid" ] || continue
      # Both names of a rename, and the objection configs (root and
      # packages) and precedents: a
      # base commit that adds an invariant or a precedent for these files
      # changes the review too. A git that fails here is not "nothing
      # touched".
      # NUL-separated, so a name with a newline reaches git log whole.
      # pipefail: a failed git diff sends xargs nothing, and BSD xargs then
      # runs nothing and exits 0, which would read as "nothing touched".
      touched=$(set -o pipefail; { git diff --no-renames --name-only -z "$new_mb" HEAD &&
        printf '%s\0' .objection.json .claude/objection.json .objection ':(glob)**/.objection.json'; } |
        xargs -0 git log --format=%h "$old_mb..$new_mb" --) || continue
      [ -z "$touched" ] || continue
      carried="$old"
      break
    done
  fi
fi
if [ -n "$carried" ]; then
  gained=$(git rev-list --count "$old_mb..$new_mb")
  {
    draft_head
    printf 'Budget: %s. Diff: %s...HEAD. Carried over from %s: the same diff (patch-id %s), now on a base that gained %s commit(s), none in the changed files. No reviewer ran.\n\n' \
      "$budget" "$diff_base" "${carried:0:7}" "${new_pid:0:12}" "$gained"
    [ -z "$checks" ] || printf 'Invariant checks:\n%s\n' "$checks"
    # The old record from its Accusation on, with one line only the judge
    # can remove.
    awk '/^## Accusation$/ { p = 1 } p' "$dir/$carried.md" | awk '
      { print }
      /^## Judge$/ && !done { print ""; print "TODO(judge): confirm the rulings below still hold on the new base (run verify), then delete this line."; done = 1 }'
  } >"$record"
  echo "objection: $(git rev-parse --abbrev-ref HEAD) @ ${sha:0:7}, budget $budget, diff $diff_base...HEAD"
  echo "$round_line"
  echo "reviewers: skipped (same diff as the APPROVED ${carried:0:7}; the base gained $gained commit(s), none in the changed files)"
  echo "draft record: $record"
  say_pkg_verify
  echo "next: run verify, confirm the carried-over rulings, delete the TODO(judge) line, then stamp.sh."
  exit 0
fi

# An exit 3 (no claude CLI) must reach the caller as 3, so no `|| exit 1`;
# a check that already failed is said before leaving, or it is lost.
bash "$here/review.sh" accuser "$brief" >"$accusation" || {
  st=$?
  [ -z "$check_rows" ] || printf 'objection: invariant checks that FAILED (a BLOCKER in any record of this round):\n%s' "$checks" >&2
  exit "$st"
}
rc=0

# Standard and thorough: one more accuser per matching reviewers entry
# (brief.sh lists them as "agent<TAB>focus"). A failed one is noted, and
# the answers already paid for are kept.
accusers="generic"
if [ "$budget" != lean ]; then
  sed -n 's/^<!-- objection-reviewer: \(.*\) -->$/\1/p' "$header" >"$tmp/reviewers"
  if [ -s "$tmp/reviewers" ]; then
    { printf '### generic\n\n'; cat "$accusation"; } >"$tmp/all"
    while IFS="$(printf '\t')" read -r agent focus; do
      [ -n "$agent" ] || continue
      accusers="$accusers + $agent"
      # An agent that names a Claude model runs on it; "gemini" (or
      # "gemini-<model>") and "codex" run through that CLI, a second model
      # family; any other agent is only a label: review.sh's model runs it.
      model="$OBJECTION_MODEL"
      agent_runner="${OBJECTION_RUNNER:-}"
      gemini_model="${OBJECTION_GEMINI_MODEL:-}"
      case "$agent" in
        opus | sonnet | haiku | claude-*) model="$agent" ;;
        gemini) agent_runner=gemini ;;
        gemini-*) agent_runner=gemini; gemini_model="$agent" ;;
        codex) agent_runner=codex ;;
      esac
      on="$model"
      [ "$agent_runner" = gemini ] && on="gemini${gemini_model:+ $gemini_model}"
      [ "$agent_runner" = codex ] && on="codex"
      printf '\n### %s (focus: %s; run by review.sh on %s)\n\n' "$agent" "$focus" "$on" >>"$tmp/all"
      if OBJECTION_RUNNER="$agent_runner" OBJECTION_GEMINI_MODEL="$gemini_model" OBJECTION_MODEL="$model" OBJECTION_FOCUS="$focus" \
        bash "$here/review.sh" accuser "$brief" >"$tmp/one" </dev/null; then
        cat "$tmp/one" >>"$tmp/all"
      else
        rc=$?
        printf 'accuser %s FAILED (exit %s).\n' "$agent" "$rc" >>"$tmp/all"
        cat "$tmp/one" >>"$tmp/all"
      fi
    done <"$tmp/reviewers"
    cp "$tmp/all" "$accusation"
  fi
fi

# Finding rows: a table row whose first cell starts with a severity word.
# Bold, underscores and a note after it ("HIGH (regression)") are
# tolerated; a longer word ("Low-level", "Lowest") and the header are not.
# Every finding is numbered once, here, in a "#" column; the defender and
# the judge use the same numbers, so the draft never repeats the table.
sev() {
  awk -F'|' -v want="$1" -v col="$2" '
    /^[[:space:]]*\|/ {
      s = $col; sub(/^[[:space:]*_]+/, "", s)
      if (!match(s, /^[A-Za-z]+/)) next
      w = toupper(substr(s, 1, RLENGTH)); rest = substr(s, RLENGTH + 1)
      if (w ~ "^(" want ")$" && rest ~ /^([^A-Za-z-]|$)/) print
    }'
}
if [ -n "$check_rows" ]; then
  {
    printf '### invariant checks (run by debate.sh)\n\n'
    printf '| severity | kind | file:line | defect | evidence | proof path |\n|---|---|---|---|---|---|\n'
    printf '%s\n' "$check_rows"
    cat "$accusation"
  } >"$tmp/with-checks"
  cp "$tmp/with-checks" "$accusation"
fi
awk -F'|' '
  function finding(s, w) {
    sub(/^[[:space:]*_]+/, "", s)
    if (!match(s, /^[A-Za-z]+/)) return 0
    w = toupper(substr(s, 1, RLENGTH))
    return w ~ /^(BLOCKER|HIGH|MEDIUM|LOW)$/ && substr(s, RLENGTH + 1) ~ /^([^A-Za-z-]|$)/
  }
  /^[[:space:]]*\|/ {
    h = $2; gsub(/[[:space:]*_]/, "", h)
    if (tolower(h) == "severity") { sub(/^[[:space:]]*\|/, "| # |"); print; head = 1; next }
    if (head && $0 ~ /^[[:space:]]*\|[[:space:]:-]*\|/) { sub(/^[[:space:]]*\|/, "|---|"); print; head = 0; next }
    head = 0
    if (finding($2)) { sub(/^[[:space:]]*\|/, "| " ++n " |"); print; next }
  }
  { head = 0; print }' "$accusation" >"$tmp/numbered"
cp "$tmp/numbered" "$accusation"
rows() { sev "$1" 3 <"$accusation"; }
count() { rows "$1" | wc -l | tr -d ' '; }
case "$budget" in
  thorough) sent="BLOCKER|HIGH|MEDIUM|LOW" ;;
  standard) sent="BLOCKER|HIGH|MEDIUM" ;;
  *) sent="BLOCKER|HIGH" ;;
esac

defended="not run: no finding the $budget budget sends to the defense"
if [ -n "$(rows "$sent")" ]; then
  {
    printf '| # | severity | kind | file:line | defect | evidence | proof path |\n'
    printf '|---|---|---|---|---|---|---|\n'
    rows "$sent"
  } >"$findings"
  # A failed defense must not lose the accusation already paid for: the
  # draft is written anyway and the exit code reports the failure.
  if OBJECTION_MODEL="$defender_model" OBJECTION_EFFORT="$defender_effort" \
    bash "$here/review.sh" defender "$brief" "$findings" >"$defense"; then
    n=$(rows "$sent" | wc -l | tr -d ' ')
    defended="answered $n finding(s) ($sent)"
  else
    rc=$?
    defended="defender FAILED (exit $rc): rerun review.sh defender, or treat its findings as undefended"
  fi
fi

{
  draft_head
  printf 'Budget: %s. Diff: %s...HEAD. Reviewers ran as isolated processes (review.sh, model %s).\n\n' \
    "$budget" "$diff_base" "$OBJECTION_MODEL, effort $OBJECTION_EFFORT"
  # Which rules and which reviewers produced this record, for anyone
  # reading it after objection or the config change.
  printf 'objection %s; config %s; accuser %s at effort %s; defender %s at effort %s.\n\n' \
    "$(cat "$here/VERSION" 2>/dev/null || echo unknown)" "$config_id" \
    "$OBJECTION_MODEL" "$OBJECTION_EFFORT" "$defender_model" "$defender_effort"
  [ -z "$checks" ] || printf 'Invariant checks:\n%s\n' "$checks"
  printf '## Accusation\n\n'
  cat "$accusation"
  printf '\n## Defense\n\n'
  if [ -s "$findings" ]; then
    printf 'Sent to the defender (numbers as in the Accusation): %s.\n\n' \
      "$(awk -F'|' 'NR > 2 { gsub(/ /, "", $2); printf "%s%s", (n++ ? ", " : ""), $2 }' "$findings")"
    if [ "$rc" != 0 ]; then printf '%s.\n\n' "$defended"; fi
    # Kept even on failure: an answer flagged as an error was still paid for.
    cat "$defense"
  else
    printf '%s.\n' "$defended"
  fi
  draft_tail
} >"$record"

# Prune: the newest OBJECTION_KEEP of each kind stay (this run's among
# them). Stamped records (<sha>.md) match none of these names.
keep="${OBJECTION_KEEP:-10}"
case "$keep" in '' | *[!0-9]* | 0) keep=10 ;; esac
for kind in brief accusation findings defense record; do
  ls -t "$dir/$kind"-*.md 2>/dev/null | tail -n +"$((keep + 1))" | while IFS= read -r old; do
    rm -f "$old"
  done
done

echo "objection: $(git rev-parse --abbrev-ref HEAD) @ ${sha:0:7}, budget $budget, diff $diff_base...HEAD"
[ -z "$defaulted" ] || echo "$base_note"
echo "model: $tier_model, effort $tier_effort ($tier_reason); defender $defender_model, effort $defender_effort"
echo "accusers: $accusers"
echo "$round_line"
echo "findings: $(count BLOCKER) BLOCKER, $(count HIGH) HIGH, $(count MEDIUM) MEDIUM, $(count LOW) LOW"
# An empty answer, a refusal or prose counts as zero rows: say so, since
# "0 findings" would read as a clean review.
grep -qiE '^[[:space:]]*\|[[:space:]]*(#[[:space:]]*\|[[:space:]]*)?severity[[:space:]]*\|' "$accusation" || grep -q 'NO FINDINGS' "$accusation" ||
  echo "warning: the accusation has no findings table and no NO FINDINGS line: read it before judging; it may not be a review."
echo "defender: $defended"
echo "draft record: $record"
say_pkg_verify
echo "next: judge each finding (the Judge section of SKILL.md), replace the TODO(judge) lines, then stamp.sh."
exit "$rc"
