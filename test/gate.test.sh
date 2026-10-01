#!/bin/bash
# Cases for gate/hook.mjs (core.mjs) and stamp.sh, including every bypass the
# hook's own two debate rounds found. Run: bash test/gate.test.sh
#
# Uses temporary repositories and a fake `gh` on PATH (answers
# "$STUB_SHA $STUB_BASE" to `gh pr view`), so it never talks to GitHub.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/skills/objection/gate/hook.mjs"
STAMP="$ROOT/skills/objection/stamp.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

gitc() { git -c user.email=t@t -c user.name=t "$@"; }
optin() { mkdir -p "$1/.claude" && printf '{"bases":["develop","master"],"defaultBase":"master"}\n' >"$1/.claude/objection.json"; }

git init -q "$T/ok" && optin "$T/ok" && gitc -C "$T/ok" add . && gitc -C "$T/ok" commit -q -m a
git init -q "$T/no" && optin "$T/no" && gitc -C "$T/no" add . && gitc -C "$T/no" commit -q -m b
git init -q "$T/off" && gitc -C "$T/off" commit -q --allow-empty -m c
OK_SHA=$(git -C "$T/ok" rev-parse HEAD)
mkdir -p "$T/ok/.git/objection"
stamp="<!-- objection: sha=$OK_SHA base=origin/develop -->"
printf '%s\n# x\nVERDICT: APPROVED\n' "$stamp" >"$T/ok/.git/objection/$OK_SHA.md"

mkdir "$T/bin"
cat >"$T/bin/gh" <<'EOF'
#!/bin/bash
if [ "$1 $2" = "pr view" ]; then
  [ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
  # With STUB_WANT set ("<target> [-R <repo>]"), answer the approved SHA only
  # when exactly those arguments arrive: a stub that answers the same SHA
  # for any target cannot tell a right parse from a wrong one.
  shift 2
  args="$*"
  args="${args%% --json*}"
  [ -n "${STUB_LOG:-}" ] && printf '%s\n' "$args" >>"$STUB_LOG"
  if [ -n "${STUB_WANT:-}" ] && [ "$args" != "$STUB_WANT" ]; then
    echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef ${STUB_BASE:-develop}"; exit 0
  fi
  echo "$STUB_SHA ${STUB_BASE:-develop}"; exit 0
fi
# The repository default branch, as `gh repo view` reports it.
if [ "$1 $2" = "repo view" ]; then
  [ -n "${STUB_NO_REPO:-}" ] && exit 1
  # With STUB_REPO_WANT set, answer only when that repository is asked for.
  if [ -n "${STUB_REPO_WANT:-}" ] && [ "$3" != "$STUB_REPO_WANT" ]; then exit 1; fi
  echo "${STUB_DEFAULT:-master}"; exit 0
fi
exit 1
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
# Windows (Git Bash): node cannot run a bash script named gh, so the gate
# is told to run the stub through bash.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) export OBJECTION_GH="[\"bash\",\"$(cygpath -m "$T/bin/gh")\"]" ;;
esac

failures=0
check() { # expected cwd tool command
  local expected=$1 cwd=$2 tool=$3 cmd=$4 json rc
  # The command goes through a file: Windows caps an argument at 32k
  # characters, and the deep-nesting case is longer (the hook itself reads
  # stdin, which has no such cap).
  printf '%s' "$cmd" >"$T/cmd"
  json=$(node -e 'console.log(JSON.stringify({cwd:process.argv[1],tool_name:process.argv[2],tool_input:{command:require("fs").readFileSync(process.argv[3],"utf8")}}))' "$cwd" "$tool" "$T/cmd")
  printf '%s' "$json" | node "$HOOK" >/dev/null 2>&1
  rc=$?
  if [ "$rc" != "$expected" ]; then
    echo "FAIL (expected $expected, got $rc): [$tool] $cmd"
    failures=$((failures + 1))
  fi
}
O="$T/ok"; N="$T/no"; F="$T/off"

# Repository without .objection.json (or .claude/objection.json): nothing is enforced.
check 0 $F Bash 'gh pr create --fill'
check 0 $F Bash 'gh pr merge 5 --auto'
check 0 $F mcp__github__create_pull_request ''

# Opt-in is decided where gh runs: a session outside any repository still
# gates `cd <opted-in repo> && gh ...`, and an opted-in session does not
# gate gh in a repository that never opted in.
check 2 "$T" Bash "cd $N && gh pr merge 5"
check 2 "$T" Bash "cd $N && gh pr create --fill"
check 0 $N Bash "cd $F && gh pr create --fill"

# Advisory mode ("enforce": false): what would block is allowed, with the
# reason on stderr; an invalid config still blocks (fail closed).
A="$T/adv"
git init -q "$A" && printf '{"bases":["main"],"enforce":false}\n' >"$A/.objection.json" && gitc -C "$A" add . && gitc -C "$A" commit -q -m adv
check 0 $A Bash 'gh pr create --fill'
printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"gh pr create --fill"}}' "$A" | node "$HOOK" >"$T/adv.out" 2>"$T/adv.err"
grep -qF "[objection] Advisory (enforce is false), would block:" "$T/adv.err" || { echo "FAIL: advisory mode did not warn"; failures=$((failures + 1)); }
grep -qF '"systemMessage"' "$T/adv.out" || { echo "FAIL: advisory mode did not tell the Claude Code user"; failures=$((failures + 1)); }
printf '{"cwd":"%s","command":"gh pr create --fill"}' "$A" | node "$HOOK" --host cursor >"$T/adv.out" 2>/dev/null
grep -qF '"permission":"allow"' "$T/adv.out" || { echo "FAIL: advisory mode denied in Cursor"; failures=$((failures + 1)); }
grep -qF 'Advisory (enforce is false)' "$T/adv.out" || { echo "FAIL: advisory mode did not tell the Cursor user"; failures=$((failures + 1)); }
printf '{"bases":["main"],"enforce":"false"}\n' >"$A/.objection.json"
check 2 $A Bash 'gh pr create --fill'
printf '{"bases":["main"],"enforce":false\n' >"$A/.objection.json"
check 2 $A Bash 'gh pr create --fill'

# Not about a PR: allowed.
check 0 $N Bash 'git status'
check 0 $N Bash 'gh pr list'
check 0 $N Bash 'gh pr view 12'
check 0 $N Bash 'grep -nE "gh pr create|gh pr merge" hooks/x'
check 0 $N Bash 'echo "step: git push; gh pr create"'
check 0 $N Bash 'git commit -m "docs: run cd x && gh pr merge later"'
check 0 $N Bash "git commit -F - <<'EOF'
fix: something

gh pr merge not now
EOF"
check 0 $N Bash 'gh api repos/o/r/pulls'
check 0 $N Bash 'gh api repos/o/r/pulls -F per_page=100 --method GET'
check 0 $N Bash 'gh api repos/o/r/pulls/12/comments -f body=hi'
check 0 $N Bash 'gh api repos/o/r/pulls --jq ".[].number" | jq -r . && echo -f x'
check 0 $N mcp__github__get_pull_request ''

# No record: blocked, however it is called.
check 2 $N Bash 'gh pr create --fill'
check 2 $N Bash 'gh pr new --fill'
check 2 $N Bash 'gh -R o/r pr create --fill'
check 2 $N Bash 'gh --repo=o/r pr create'
check 2 $N Bash 'x=$(gh pr create --fill)'
check 2 $N Bash 'x="$(gh pr create --fill)"'
check 2 $N Bash "(cd $N && gh pr create)"
check 2 $N Bash 'if true; then gh pr create; fi'
check 2 $N Bash 'time gh pr create'
check 2 $N Bash 'command gh pr create'
check 2 $N Bash '/opt/homebrew/bin/gh pr create'
check 2 $N Bash 'GH_REPO=o/r gh pr create'
check 2 $N Bash "bash -c 'gh pr create'"
check 2 $N Bash 'rtk gh pr ready'
check 2 $N Bash "gh pr create --body \"\$(cat <<'EOF'
body
EOF
)\""
check 2 $O Bash "git status; cd $N && gh pr create"
check 2 $O Bash "cd '$N' && gh pr create"
check 2 $N Bash 'gh api repos/o/r/pulls -f title=x -f head=a'
check 2 $N Bash "gh api 'repos/o/r/pulls' --method POST --input x.json"
check 2 $N Bash 'gh api -X PUT repos/o/r/pulls/12/merge'
check 2 $N Bash 'gh api graphql -f query="mutation{mergePullRequest(input:{}){clientMutationId}}"'
check 2 $N mcp__plugin_engineering_github__create_pull_request ''
check 2 $N mcp__plugin_engineering_github__merge_pull_request ''
check 2 $N mcp__plugin_engineering_github__update_pull_request ''
check 2 $N mcp__ccd_pr__set_auto_merge ''

# APPROVED record for the right SHA and base: allowed.
check 0 $O Bash 'gh pr create --fill --base develop'
check 0 $N Bash "cd $O && gh pr create --base develop"
check 0 $N Bash "cd '$O' && gh pr create -B develop"
# "cd" inside a quoted title is not a cd: allowed, as with any title
# (it used to block as "cannot tell which directory").
check 0 $O Bash 'gh pr create --base develop --title "fix: reads quoted cd targets; ok"'
check 0 $N Bash "cd $O && gh pr create --base develop --title \"reads cd x; y\""
check 0 $O Bash "gh pr create --base develop --title 'cd a; b'"
# ...and the same title on a repository with no record still blocks.
check 2 $N Bash 'gh pr create --base develop --title "fix: reads quoted cd targets; ok"'
# A cd inside a quoted $( ) or backtick runs: it still blocks.
check 2 $O Bash "echo \"\$(cd $N && gh pr create --base develop)\""
check 2 $O Bash 'echo "`cd '"$N"' && gh pr create --base develop`"'
# A quoted fake cd next to a real one: the real one decides, both ways.
check 2 $T Bash "cd $N && gh pr create --base develop --title \"cd $O; x\""
check 0 $T Bash "cd $O && gh pr create --base develop --title \"cd $N; x\""
# A record debated against develop does not release a PR to master
# (defaultBase in the config is master).
check 2 $O Bash 'gh pr create --fill'
check 2 $O Bash 'gh pr create --fill --base master'
export STUB_SHA=$OK_SHA
check 0 $O Bash 'gh pr merge 5 --squash'
check 0 $O Bash 'gh pr merge -R o/r 5 --squash'
check 0 $O Bash 'gh pr merge --subject "a b" 5'
check 0 $O Bash 'gh pr ready 12'
check 2 $O Bash 'gh pr merge 5 --auto --squash'
export STUB_SHA=deadbeef
check 2 $O Bash 'gh pr merge 5 --squash'
check 2 $O Bash 'gh pr ready 12'
check 0 $O Bash 'gh pr ready 12 --undo'
check 2 $O Bash 'gh pr ready 12 --undone'
export STUB_SHA=$OK_SHA STUB_BASE=master
check 2 $O Bash 'gh pr merge 5 --squash'
export STUB_BASE=develop

# --- Second debate round (accusation with defender) ----------------------
export STUB_SHA=deadbeef
# Multi-line GraphQL and queries read from a file.
check 2 $N Bash "gh api graphql -f query='
mutation {
  mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}
}'"
check 2 $N Bash 'gh api graphql -F query=@m.graphql'
check 0 $N Bash 'gh api graphql -f query="query{viewer{login}}"'
# Hung gh: the hook blocks before the harness limit (internal timeout).
export STUB_SLEEP=20
start=$(date +%s)
check 2 $O Bash 'gh pr merge 5 --squash'
[ $(( $(date +%s) - start )) -lt 25 ] || { echo "FAIL: hook took over 25 s with a hung gh"; failures=$((failures + 1)); }
unset STUB_SLEEP
# -R/--repo after `pr`.
check 2 $N Bash 'gh pr -R o/r create --fill'
check 2 $N Bash 'gh pr --repo o/r merge 5'
# A shell reading stdin.
check 2 $N Bash "bash <<'EOF'
gh pr create --fill
EOF"
check 2 $N Bash "echo 'gh pr create --fill' | bash"
# Disguised names and a path in gh api.
check 2 $N Bash '\gh pr create'
check 2 $N Bash 'g\h pr create'
check 2 $N Bash '"gh" pr create'
check 2 $N Bash '/opt/homebrew/bin/gh api -X PUT repos/o/r/pulls/12/merge'
# Ambiguous directory: blocked even when the cwd has a record.
check 2 $O Bash "(cd $N); gh pr create --base develop"
check 2 $O Bash "pushd $N; gh pr create --base develop"
check 2 $O Bash "env -C $N gh pr create --base develop"
check 2 $O Bash "echo \"a cd $O b\"; cd $N && gh pr create --base develop"
check 0 $N Bash "(cd $O && gh pr create --base develop)"
# Target from stdin.
export STUB_SHA=$OK_SHA
check 2 $O Bash 'echo 99 | xargs gh pr merge --squash'
# MCP: short names blocked, PR review allowed.
check 2 $N mcp__x__create_pr ''
check 2 $N mcp__x__merge_pr ''
check 2 $N mcp__x__mark_pr_ready_for_review ''
check 0 $N mcp__github__create_pull_request_review ''
check 0 $N mcp__github__create_pr_comment ''
# A record without the stamp from stamp.sh does not count.
printf '# x\nVERDICT: APPROVED\n' >"$T/ok/.git/objection/$OK_SHA.md"
check 2 $O Bash 'gh pr create --fill --base develop'
printf '<!-- objection: sha=%s base=origin/develop -->\n# x\nVERDICT: APPROVED\n' "$(printf 'a%.0s' $(seq 40))" >"$T/ok/.git/objection/$OK_SHA.md"
check 2 $O Bash 'gh pr create --fill --base develop'
printf '%s\n# x\nVERDICT: APPROVED\n' "$stamp" >"$T/ok/.git/objection/$OK_SHA.md"
# Help and disabling auto-merge touch no PR.
export STUB_SHA=deadbeef
check 0 $N Bash 'gh pr create --help'
check 0 $N Bash 'gh pr merge --help'
check 0 $N Bash 'gh pr merge --disable-auto 5'

# --- GitLab: glab mr create / merge, glab api ----------------------------
# The stub answers `glab mr view -F json` with $GLAB_SHA and develop.
cat >"$T/bin/glab" <<'EOF2'
#!/bin/bash
# Answers only the documented form: mr view <n> -F json.
if [ "$1 $2" = "mr view" ] && [ "$*" = "mr view 5 -F json" ]; then
  printf '{"iid":5,"sha":"%s","target_branch":"%s","description":"x"}\n' "$GLAB_SHA" "${GLAB_BASE:-develop}"; exit 0
fi
exit 1
EOF2
chmod +x "$T/bin/glab"
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) export OBJECTION_GLAB="[\"bash\",\"$(cygpath -m "$T/bin/glab")\"]" ;;
esac
GL="$T/gl"
git init -q "$GL" && optin "$GL" && gitc -C "$GL" add . && gitc -C "$GL" commit -q -m gl
git init -q --bare "$T/gl-remote.git"
git -C "$GL" remote add origin "$T/gl-remote.git"
git -C "$GL" push -q -u origin HEAD:feat 2>/dev/null
git -C "$GL" branch -q -u origin/feat 2>/dev/null || git -C "$GL" branch --set-upstream-to=origin/feat >/dev/null
GL_SHA=$(git -C "$GL" rev-parse HEAD)
mkdir -p "$GL/.git/objection"
printf '<!-- objection: sha=%s base=origin/develop -->\n# x\nVERDICT: APPROVED\n' "$GL_SHA" >"$GL/.git/objection/$GL_SHA.md"
# merge: auto-merge (glab's default) is refused; explicit off with a record passes.
GLAB_SHA=$GL_SHA check 2 "$GL" Bash 'glab mr merge 5'
GLAB_SHA=$GL_SHA check 0 "$GL" Bash 'glab mr merge 5 --auto-merge=false'
GLAB_SHA=$GL_SHA check 0 "$GL" Bash 'glab mr merge --auto-merge=false --squash 5'
GLAB_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef check 2 "$GL" Bash 'glab mr merge 5 --auto-merge=false'
GLAB_SHA=$GL_SHA GLAB_BASE=main check 2 "$GL" Bash 'glab mr merge 5 --auto-merge=false'
GLAB_SHA=$GL_SHA check 2 "$GL" Bash 'glab mr merge $MR --auto-merge=false'
GLAB_SHA=$GL_SHA check 2 "$GL" Bash '"glab" mr merge 5'
GLAB_SHA=$GL_SHA check 2 "$GL" Bash 'echo "$(glab mr merge 5)"'
# create: needs --target-branch and the debated commit pushed.
check 0 "$GL" Bash 'glab mr create --target-branch develop --fill'
check 0 "$GL" Bash 'glab mr create -b develop -t "x"'
check 2 "$GL" Bash 'glab mr create --fill'
check 2 "$GL" Bash 'glab mr create --target-branch main --fill'
gitc -C "$GL" commit -q --allow-empty -m unpushed
check 2 "$GL" Bash 'glab mr create --target-branch develop --fill'
git -C "$GL" reset -q --hard "$GL_SHA"
check 2 "$N" Bash 'glab mr create --target-branch develop --fill'
# glab api: writes to merge_requests are refused, reads pass.
check 2 "$GL" Bash 'glab api -X POST projects/1/merge_requests -f source_branch=feat'
check 2 "$GL" Bash 'glab api --method PUT projects/1/merge_requests/5/merge'
check 0 "$GL" Bash 'glab api projects/1/merge_requests/5'
# glab mr update --ready takes a draft to review: the same record check.
GLAB_SHA=$GL_SHA check 0 "$GL" Bash 'glab mr update 5 --ready'
GLAB_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef check 2 "$GL" Bash 'glab mr update 5 --ready'
GLAB_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef check 2 "$GL" Bash 'glab mr update 5 -r'
GLAB_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef check 0 "$GL" Bash 'glab mr update 5 --title x'
GLAB_SHA=$GL_SHA check 0 "$GL" Bash 'glab mr update --label bug 5 --ready'
# Leaving draft another way (--draft=false, --wip=false) is the same act.
GLAB_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef check 2 "$GL" Bash 'glab mr update 5 --draft=false'
GLAB_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef check 2 "$GL" Bash 'glab mr update 5 --wip=false'
GLAB_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef check 0 "$GL" Bash 'glab mr update 5 --draft'
# Every false a Go boolean flag accepts.
for v in 0 f F FALSE False; do
  GLAB_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef check 2 "$GL" Bash "glab mr update 5 --draft=$v"
done
GLAB_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef check 0 "$GL" Bash 'glab mr update 5 --draft=true'
GLAB_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef check 0 "$GL" Bash 'glab mr update -R g/p 5 --title x'
# Quoted text is not a flag.
GLAB_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef check 0 "$GL" Bash 'glab mr update 5 --title "never --draft=false or --ready"'
# A value before the number is not the number (the stub answers only 5).
GLAB_SHA=$GL_SHA check 0 "$GL" Bash 'glab mr update --description 9 5 --ready'
# Innocent look-alikes.
check 0 "$N" Bash 'glab mr list'
check 0 "$N" Bash 'glab mr view 5'
check 0 "$N" Bash 'git commit -m "glab mr merge 5 later"'
check 0 $F Bash 'glab mr merge 5'

# --- stamp.sh ------------------------------------------------------------
R="$T/stamp"
git init -q "$R" && optin "$R" && gitc -C "$R" add . && gitc -C "$R" commit -q -m base
git -C "$R" update-ref refs/remotes/origin/develop HEAD
printf 'x\n' >"$R/a.ts" && git -C "$R" add a.ts && gitc -C "$R" commit -q -m code
printf '# doc\n' >"$R/b.md" && git -C "$R" add b.md && gitc -C "$R" commit -q -m doc
printf 'VERDICT: APPROVED\n' >"$T/min.md"
full() { # open-list [open-count] [verdict]
  printf '# D\n\n## Accusation\nx\n\n## Defense\nx\n\n## Judge\nx\n\n## Open\n%s\n\n%s\nVERDICT: %s\n' "$1" "${2:-OPEN: BLOCKER=0 HIGH=0}" "${3:-APPROVED}" >"$T/rec.md"
}
stampcheck() { # expected base record
  (cd "$R" && bash "$STAMP" "$3" "$2" >/dev/null 2>&1); local rc=$?
  if { [ "$1" = 0 ] && [ $rc != 0 ]; } || { [ "$1" != 0 ] && [ $rc = 0 ]; }; then
    echo "FAIL stamp (expected $1, got $rc): base=$2 record=$3"; failures=$((failures + 1))
  fi
}
# Documentation by extension, renames under both names: a code file
# renamed to .md, or code under docs/, needs the full record.
# A merge that changes no file (merge -s ours bringing another branch's
# history in) stamps with a verdict-only record: there is nothing to debate.
R3="$T/stamp-empty"
git init -q "$R3" && optin "$R3" && printf 'code\n' >"$R3/a.js" &&
  gitc -C "$R3" add . && gitc -C "$R3" commit -q -m base && git -C "$R3" update-ref refs/remotes/origin/develop HEAD
git -C "$R3" checkout -q -b other && printf 'more\n' >>"$R3/a.js" && gitc -C "$R3" commit -q -am other
git -C "$R3" checkout -q - && gitc -C "$R3" merge -q -s ours other -m "history only"
(cd "$R3" && bash "$STAMP" "$T/min.md" origin/develop >/dev/null 2>&1) || { echo "FAIL: a merge with no file change did not stamp"; failures=$((failures + 1)); }
[ -f "$R3/.git/objection/$(git -C "$R3" rev-parse HEAD).md" ] || { echo "FAIL: the empty merge's record was not stored"; failures=$((failures + 1)); }
R2="$T/stamp-docs"
git init -q "$R2" && optin "$R2" && mkdir -p "$R2/src" && printf 'code\n' >"$R2/src/auth.js" &&
  gitc -C "$R2" add . && gitc -C "$R2" commit -q -m base && git -C "$R2" update-ref refs/remotes/origin/develop HEAD
git -C "$R2" mv src/auth.js src/auth.md && gitc -C "$R2" commit -q -m rename
(cd "$R2" && bash "$STAMP" "$T/min.md" origin/develop >/dev/null 2>&1) && { echo "FAIL: a code file renamed to .md stamped as docs"; failures=$((failures + 1)); }
git -C "$R2" reset -q --hard origin/develop && mkdir -p "$R2/docs" && printf 'x = 1\n' >"$R2/docs/conf.py" &&
  gitc -C "$R2" add . && gitc -C "$R2" commit -q -m conf
(cd "$R2" && bash "$STAMP" "$T/min.md" origin/develop >/dev/null 2>&1) && { echo "FAIL: docs/conf.py stamped as docs"; failures=$((failures + 1)); }
git -C "$R2" reset -q --hard origin/develop && printf '# guide\n' >"$R2/guide.md" && gitc -C "$R2" add . && gitc -C "$R2" commit -q -m guide
(cd "$R2" && bash "$STAMP" "$T/min.md" origin/develop >/dev/null 2>&1) || { echo "FAIL: a real docs change did not stamp as docs"; failures=$((failures + 1)); }
# Arbitrary base (HEAD~1) would fall into the docs exemption.
stampcheck 1 HEAD~1 "$T/min.md"
stampcheck 1 origin/develop "$T/min.md"
full '- MEDIUM: no test for case X yet'
stampcheck 0 origin/develop "$T/rec.md"
head -1 "$R/.git/objection/$(git -C "$R" rev-parse HEAD).md" | grep -q "^<!-- objection: sha=$(git -C "$R" rev-parse HEAD) base=origin/develop -->$" \
  || { echo "FAIL: stamp.sh did not write the stamp"; failures=$((failures + 1)); }
full 'HIGH: no list marker'
stampcheck 1 origin/develop "$T/rec.md"
full '1. **High** bold severity'
stampcheck 1 origin/develop "$T/rec.md"
full 'no HIGH finding is left'
stampcheck 0 origin/develop "$T/rec.md"
# The cross-check reads the template's own "#, severity" order.
full '1 HIGH race on retry' 'OPEN: BLOCKER=0 HIGH=0'
stampcheck 1 origin/develop "$T/rec.md"
full '4, HIGH, x.ts:3, race' 'OPEN: BLOCKER=0 HIGH=0'
stampcheck 1 origin/develop "$T/rec.md"
full '1 MEDIUM highlight color off' 'OPEN: BLOCKER=0 HIGH=0'
stampcheck 0 origin/develop "$T/rec.md"
# A draft from debate.sh whose judge sections were never filled is refused,
# even with a count and a verdict; a TODO in the findings' own text is not.
full 'TODO(judge): what stays open'
stampcheck 1 origin/develop "$T/rec.md"
full '- MEDIUM: the TODO list in a.ts is stale'
stampcheck 0 origin/develop "$T/rec.md"
# A finding that quotes the marker (reviewing debate.sh itself) is not an
# unfilled draft: only a line that starts with it is.
full '- LOW: debate.sh writes TODO(judge): lines into the draft'
stampcheck 0 origin/develop "$T/rec.md"
# No base given: origin/<defaultBase> (master here); the stamp names it.
git -C "$R" update-ref refs/remotes/origin/master refs/remotes/origin/develop
full '- MEDIUM: x'
stampcheck 0 "" "$T/rec.md"
head -1 "$R/.git/objection/$(git -C "$R" rev-parse HEAD).md" | grep -q "base=origin/master -->$" \
  || { echo "FAIL: stamp.sh without a base did not use defaultBase"; failures=$((failures + 1)); }
# The structured count is required and must be zero to approve.
full 'nothing' 'no count line here'
stampcheck 1 origin/develop "$T/rec.md"
full '- MEDIUM: x' 'OPEN: BLOCKER=0 HIGH=1'
stampcheck 1 origin/develop "$T/rec.md"
full '- HIGH: race on retry' 'OPEN: BLOCKER=0 HIGH=0'
stampcheck 1 origin/develop "$T/rec.md"
full '- HIGH: race on retry' 'OPEN: BLOCKER=0 HIGH=1' REJECTED
stampcheck 0 origin/develop "$T/rec.md"
# The debate's own prompts (.claude/*.md) are not "documentation only".
mkdir -p "$R/.claude/agents" && printf 'x\n' >"$R/.claude/agents/c.md"
git -C "$R" add .claude && gitc -C "$R" commit -q -m prompt
git -C "$R" update-ref refs/remotes/origin/develop HEAD~1
stampcheck 1 origin/develop "$T/min.md"
# Issue #9: nor are agents/, skills/, AGENTS.md or the objection config.
for f in agents/defender.md skills/objection/roles/defender.md AGENTS.md .objection.json; do
  mkdir -p "$R/$(dirname "$f")"
  # The config must stay valid JSON (stamp.sh reads it); any change will do.
  if [ "$f" = .objection.json ]; then printf '{"bases":["develop","master"],"budget":"lean"}\n' >"$R/$f"; else printf 'x\n' >"$R/$f"; fi
  git -C "$R" add "$f" && gitc -C "$R" commit -q -m "prompt $f"
  git -C "$R" update-ref refs/remotes/origin/develop HEAD~1
  stampcheck 1 origin/develop "$T/min.md"
done
# ...while a README change alone still is.
printf 'y\n' >>"$R/b.md" && git -C "$R" add b.md && gitc -C "$R" commit -q -m doc2
git -C "$R" update-ref refs/remotes/origin/develop HEAD~1
stampcheck 0 origin/develop "$T/min.md"
# From a subdirectory the record still lands in the repository's git dir.
mkdir -p "$R/deep/er"
full '- MEDIUM: x'
(cd "$R/deep/er" && bash "$STAMP" "$T/rec.md" origin/develop >/dev/null 2>&1) || { echo "FAIL: stamp.sh from a subdirectory"; failures=$((failures + 1)); }
[ -f "$R/.git/objection/$(git -C "$R" rev-parse HEAD).md" ] || { echo "FAIL: stamp.sh from a subdirectory wrote elsewhere"; failures=$((failures + 1)); }
[ -e "$R/deep/er/.git" ] && { echo "FAIL: stamp.sh created a .git in the subdirectory"; failures=$((failures + 1)); }
# A heading edited by hand is refused, and the message names it.
git -C "$R" update-ref refs/remotes/origin/develop HEAD~3
full nothing
sed -i.bak 's/^## Accusation$/## Accusation (round 2)/' "$T/rec.md" && rm -f "$T/rec.md.bak"
msg=$(cd "$R" && bash "$STAMP" "$T/rec.md" origin/develop 2>&1) && { echo "FAIL: stamp.sh took an edited heading"; failures=$((failures + 1)); }
case "$msg" in *"'## Accusation (round 2)' (quoted as is: trailing spaces count) where the heading must be exactly '## Accusation'"*) ;;
  *) echo "FAIL: stamp.sh does not name the edited heading: $msg"; failures=$((failures + 1)) ;; esac
git -C "$R" update-ref refs/remotes/origin/develop HEAD~1
# Repository not opted in: stamp.sh refuses.
(cd "$F" && bash "$STAMP" "$T/rec.md" origin/main >/dev/null 2>&1) && { echo "FAIL: stamp.sh ran without objection.json"; failures=$((failures + 1)); }

# --- Lessons from the first adopter's six-round debate ----------------------
# Each natural form failed on the version before this fix (negative
# control), and each sits next to the innocent look-alike that must pass.
# A quoted value glued to the flag is still the repo flag: blocked without a record.
check 2 $N Bash 'gh --repo="o/r" pr create --fill'
check 2 $N Bash "gh --repo='o/r' pr create"
check 2 $N Bash 'gh pr --repo="o/r" merge 5'
# ...and with a record, the right target and repo reach gh pr view.
export STUB_SHA=$OK_SHA
STUB_WANT="5 -R o/r" check 0 $O Bash 'gh -R"o/r" pr merge 5'
# GH_REPO picks the repository like -R: the PR checked is the one merged.
STUB_WANT="5 -R o/other" check 0 $O Bash 'GH_REPO=o/other gh pr merge 5'
STUB_WANT="5" check 2 $O Bash 'GH_REPO=o/other gh pr merge 5'
check 2 $O Bash 'GH_REPO="$R" gh pr merge 5'
# Quotes around a literal value are the shell's, not the repository's.
STUB_WANT="5 -R o/other" check 0 $O Bash 'GH_REPO="o/other" gh pr merge 5'
STUB_WANT="5 -R o/other" check 0 $O Bash "GH_REPO='o/other' gh pr merge 5"
STUB_WANT="5 -R o/r" check 0 $O Bash 'gh --repo="o/r" pr merge 5 --squash'
# -m and -r are --merge and --rebase, not flags that take a value.
STUB_WANT="338" check 0 $O Bash 'gh pr merge -m 338'
STUB_WANT="338" check 0 $O Bash 'gh pr merge -r 338'
STUB_WANT="338" check 0 $O Bash 'gh pr merge --squash --delete-branch 338'
# The stub can say no: another target is not approved.
STUB_WANT="999" check 2 $O Bash 'gh pr merge -m 338'
export STUB_SHA=deadbeef
# Innocent look-alikes keep passing.
check 0 $N Bash 'gh pr view --repo="o/r" 5'
check 0 $N Bash 'git commit -m "fix: run gh pr merge -m 5 later"'
check 0 $N Bash 'grep -c "gh pr create" notes.md'
check 0 $N Bash "psql -c \"select 'gh pr create'\""
check 0 $N Bash 'tar -czf out.tgz "gh pr merge 5"'
# -c executes only after something that runs code.
check 2 $N Bash "sh -c 'gh pr create'"
check 2 $N Bash "/usr/bin/env bash -c 'gh pr merge 5'"

# --- Round 2 of that fix: its own regressions ----------------------------
# Every "allowed with a record" case has its twin "blocked without one":
# a case that only expects 0 also passes when the gate never saw the
# command. And the stub log proves gh got the right target and repo.
called() { # expected-args
  if ! grep -qxF "$1" "$T/gh.log" 2>/dev/null; then
    echo "FAIL: gh pr view was not called with [$1] (log: $(tr '\n' '|' <"$T/gh.log" 2>/dev/null))"
    failures=$((failures + 1))
  fi
  : >"$T/gh.log"
}
export STUB_LOG="$T/gh.log"
: >"$T/gh.log"
# Short flags with a glued value, quoted or not.
check 2 $N Bash 'gh -R"o/r" pr merge 5'
check 2 $N Bash "gh -R'o/r' pr create --fill"
check 2 $N Bash 'gh pr -R"o/r" merge 5'
check 2 $N Bash 'gh -Ro/r pr create --fill'
check 2 $N Bash 'gh pr merge -R"o/r" 5'
export STUB_SHA=$OK_SHA
: >"$T/gh.log"
STUB_WANT="5 -R o/r" check 0 $O Bash 'gh -R"o/r" pr merge 5'; called "5 -R o/r"
STUB_WANT="5 -R o/r" check 0 $O Bash 'gh pr merge -R"o/r" 5'; called "5 -R o/r"
STUB_WANT="5 -R o/r" check 0 $O Bash 'gh pr merge -Ro/r 5'; called "5 -R o/r"
# A glued value with ( or ; must not hide the PR number.
check 2 $N Bash 'gh pr merge -t"feat(ui)" 42 --squash'
STUB_WANT="42" check 0 $O Bash 'gh pr merge -t"feat(ui)" 42 --squash'; called "42"
STUB_WANT="5" check 0 $O Bash 'gh pr merge --subject="fix(gate):x" 5'; called "5"
STUB_WANT="42" check 0 $O Bash 'gh pr merge --body="a;b" 42'; called "42"
export STUB_SHA=deadbeef
# Glued base and head are read, not dropped (the record is for develop).
check 0 $O Bash 'gh pr create -B"develop" --fill'
check 2 $O Bash 'gh pr create -B"master" --fill'
check 2 $O Bash 'gh pr create -Bmaster --fill'
check 2 $O Bash 'gh pr create -H"nonexistent" --base develop'
# Natural ways to run a shell command string.
check 2 $N Bash "bash -lc 'gh pr merge 5'"
check 2 $N Bash "sh -xc 'gh pr create --fill'"
check 2 $N Bash '$SHELL -c "gh pr merge 5"'
check 2 $N Bash '${SHELL:-bash} -c "gh pr create --fill"'
check 2 $N Bash "pwsh -c 'gh pr merge 5'"
check 2 $N Bash "python3 -c 'gh pr merge 5'"

# --- Round 4: a command substitution that does not run gh ------------------
# `$(...)` or backticks before the PR number used to cut the command at `)`,
# so gh looked up the wrong target and an innocent merge was blocked. Code
# that does not mention gh cannot create or merge a PR (short of disguise,
# LOW), so it becomes a placeholder like inert text.
export STUB_LOG="$T/gh.log" STUB_SHA=$OK_SHA
: >"$T/gh.log"
STUB_WANT="42" check 0 $O Bash 'gh pr merge -t "$(git log -1 --format=%s)" 42 --squash'; called "42"
STUB_WANT="42" check 0 $O Bash 'gh pr merge --body="$(cat notes.md)" 42'; called "42"
STUB_WANT="42" check 0 $O Bash 'gh pr merge -t $(git log -1 --format=%s) 42'; called "42"
STUB_WANT="42" check 0 $O Bash 'gh pr merge -t `git log -1 --format=%s` 42'; called "42"
STUB_WANT="42" check 0 $O Bash 'gh pr merge --subject "$(printf "%s" "$(git log -1 --format=%s)")" 42'; called "42"
export STUB_SHA=deadbeef
unset STUB_LOG
# Their twins without a record stay blocked...
check 2 $N Bash 'gh pr merge -t "$(git log -1 --format=%s)" 42 --squash'
check 2 $N Bash 'gh pr merge -t $(git log -1 --format=%s) 42'
# ...and a substitution that does run gh is still code.
check 2 $N Bash 'x="$(gh pr create --fill)"'
check 2 $N Bash 'echo $(gh pr merge 5)'
check 2 $N Bash 'echo `gh pr merge 5`'
check 2 $N Bash "bash -c 'gh pr merge 5'"

# --- Round 5: what the round-4 accuser found in that fix -------------------
export STUB_SHA=$OK_SHA STUB_LOG="$T/gh.log"
: >"$T/gh.log"
# A PR number the gate cannot read is blocked, even when the current
# branch's PR has a record (it used to check that one instead).
check 2 $O Bash 'gh pr merge $(cat .pr-number) --squash'
check 2 $O Bash 'gh pr merge "$(jq -r .number pr.json)"'
check 2 $O Bash 'gh pr ready `cat .pr`'
check 2 $O Bash 'gh pr merge $((40+2))'
check 2 $O Bash 'gh pr merge "$PR" --squash'
check 2 $O Bash 'gh pr merge $PR'
# A redirection is not the PR number: it names the number after it, or
# none (the current branch's PR).
STUB_WANT="7" check 0 $O Bash 'gh pr merge 2>/dev/null 7'; called "7"
STUB_WANT="7" check 0 $O Bash 'gh pr merge 2> err.log 7 --squash'; called "7"
STUB_WANT="7" check 0 $O Bash 'gh pr merge >out.txt 2>&1 7'; called "7"
STUB_WANT="7" check 0 $O Bash 'gh pr merge &>/dev/null 7'; called "7"
# "2>&1" used to end the command at "&", and ">|" at "|": the gate then
# checked the current branch's PR while gh merged 7.
STUB_WANT="7" check 0 $O Bash 'gh pr merge 2>&1 7'; called "7"
STUB_WANT="7" check 0 $O Bash 'gh pr merge >|out.txt 7'; called "7"
# An operator written apart from its target takes it along.
STUB_WANT="7" check 0 $O Bash 'gh pr merge >& 2 7'; called "7"
STUB_WANT="7" check 0 $O Bash 'gh pr merge 2>| err.log 7'; called "7"
# ...while a literal number with a substitution elsewhere still works.
STUB_WANT="7" check 0 $O Bash 'gh pr merge 7 -t "$(cd sub && git log -1 --format=%s)"'; called "7"
STUB_WANT="7" check 0 $O Bash 'gh pr merge 7 -t $(cd sub && git log -1 --format=%s)'; called "7"
unset STUB_LOG
export STUB_SHA=deadbeef
# Prose that names gh next to an innocent substitution is not a command.
check 0 $N Bash 'git commit -m "docs: explain gh pr merge ($(date +%F))"'
check 0 $N Bash 'echo "run gh pr create after $(date)"'
# ...but a substitution that runs gh inside a message still counts.
check 2 $N Bash 'echo "created: $(gh pr create --fill)"'
# Going back to the repository root with a substitution is resolved, not
# read as a literal path; its twin without a record stays blocked.
mkdir -p "$O/sub" "$N/sub"
STUB_SHA=$OK_SHA STUB_WANT="12" check 0 "$O/sub" Bash 'cd "$(git rev-parse --show-toplevel)" && gh pr merge 12'
STUB_SHA=$OK_SHA STUB_WANT="12" check 0 "$O/sub" Bash 'cd $(git rev-parse --show-toplevel) && gh pr merge 12'
check 2 "$N/sub" Bash 'cd "$(git rev-parse --show-toplevel)" && gh pr merge 12'
# Deep nesting does not crash the hook (a crash is a non-blocking error).
deep="gh pr merge 7 -t "$(printf '"$(echo %.0s' $(seq 5000))
check 2 $N Bash "$deep"
# (A quoted interpreter, "$SHELL" -c, is LOW by the threat model: treating
# any quoted word as an interpreter blocked the searches below.)
# ...and their innocent look-alikes, from the round-3 accuser.
check 0 $N Bash 'grep -rc "gh pr merge" docs'
check 0 $N Bash "node --check 'gh pr merge.js'"
check 0 $N Bash 'rg -g "*.md" -c "gh pr create"'
check 0 $N Bash 'grep --include "*.md" -rc "gh pr merge" .'
check 0 $N Bash "grep \"foo\" -c 'gh pr merge' f"
check 0 $N Bash "find docs -name \"*.md\" -exec grep -c 'gh pr merge' {} +"
check 0 $N Bash "perl -pe 's/gh pr create/x/' f"
check 0 $N Bash "perl -i -pe 's/gh pr merge 5/x/' docs.md"
check 0 $N Bash "perl -ne 'print if /gh pr merge/' f"
check 0 $N Bash "ruby -ne 'puts \$_ if /gh pr merge 5/' f"
check 0 $N Bash "python3 tool.py -vc 'gh pr merge 5'"
check 0 $N Bash "psql -c 'select 1' -c \"gh pr merge 5\""
unset STUB_LOG

# --- External review (issue #9) --------------------------------------------
# The base without --base is the one gh uses: the branch's gh-merge-base,
# else the repository default on GitHub, never .objection.json's
# defaultBase (master in this fixture; the record is for develop).
cur=$(git -C "$O" symbolic-ref --short HEAD)
STUB_DEFAULT=develop check 0 $O Bash 'gh pr create --fill'
STUB_DEFAULT=master check 2 $O Bash 'gh pr create --fill'
git -C "$O" config "branch.$cur.gh-merge-base" develop
STUB_DEFAULT=master check 0 $O Bash 'gh pr create --fill'
git -C "$O" config --unset "branch.$cur.gh-merge-base"
STUB_DEFAULT=develop STUB_NO_REPO=1 check 2 $O Bash 'gh pr create --fill'
# --head is checked against the branch on origin, not a local branch with
# the same name. Local feat is at the approved commit; origin/feat is not.
git init -q --bare "$T/remote.git"
git -C "$O" remote add origin "$T/remote.git"
git -C "$O" branch feat "$OK_SHA"
git -C "$O" push -q origin feat
check 0 $O Bash 'gh pr create --head feat --base develop'
git clone -q "$T/remote.git" "$T/other" 2>/dev/null
git -C "$T/other" checkout -q feat
gitc -C "$T/other" commit -q --allow-empty -m "someone else's commit"
git -C "$T/other" push -q origin feat
check 2 $O Bash 'gh pr create --head feat --base develop'
check 2 $O Bash 'gh pr create -H feat -B develop'
# A branch that is not on origin, and a fork's branch, cannot be checked.
git -C "$O" branch local-only "$OK_SHA"
check 2 $O Bash 'gh pr create --head local-only --base develop'
check 2 $O Bash 'gh pr create --head victorserpa:feat --base develop'
check 2 $O Bash 'gh pr create --head=someone:feat --base develop'
# Round 1 of that fix: the remote is found, not assumed to be origin.
git init -q "$T/named" && optin "$T/named" && gitc -C "$T/named" add . && gitc -C "$T/named" commit -q -m n
NAMED_SHA=$(git -C "$T/named" rev-parse HEAD)
mkdir -p "$T/named/.git/objection"
printf '<!-- objection: sha=%s base=origin/develop -->\n# x\nVERDICT: APPROVED\n' "$NAMED_SHA" >"$T/named/.git/objection/$NAMED_SHA.md"
git init -q --bare "$T/gh-remote.git"
git -C "$T/named" remote add github "$T/gh-remote.git"
git -C "$T/named" branch feat "$NAMED_SHA"
git -C "$T/named" push -q -u github feat
check 0 "$T/named" Bash 'gh pr create --head feat --base develop'
git -C "$T/named" branch unpushed "$NAMED_SHA"
check 2 "$T/named" Bash 'gh pr create --head unpushed --base develop'
# A fork's branch is read from the remote under that owner.
mkdir -p "$T/me" && git init -q --bare "$T/me/repo.git"
git -C "$T/named" remote add fork "$T/me/repo.git"
git -C "$T/named" push -q fork feat
check 0 "$T/named" Bash 'gh pr create --head me:feat --base develop -R up/repo'
check 2 "$T/named" Bash 'gh pr create --head stranger:feat --base develop -R up/repo'
# A mirror of me/repo on another host is not where gh opens the PR from:
# it must neither be read nor make the match ambiguous. Its look-alike on
# GitHub itself (an unreachable URL) does make it ambiguous: blocked.
git -C "$T/named" remote add mirror "git@gitlab.example.com:me/repo.git"
check 0 "$T/named" Bash 'gh pr create --head me:feat --base develop -R up/repo'
git -C "$T/named" remote set-url mirror "https://github.com/me/repo.git"
check 2 "$T/named" Bash 'gh pr create --head me:feat --base develop -R up/repo'
git -C "$T/named" remote remove mirror
# SSH aliases are resolved as ssh does (ssh -G reads the config, never
# connects). The fork keeps its real (local) URL; the alias is a second
# remote that makes the match ambiguous only if it is kept: blocked (2)
# means it was taken for GitHub, allowed (0) means it was not.
printf 'Host github-work github.com-work\n  HostName github.com\nHost gitlab-work\n  HostName gitlab.com\n' >"$T/ssh_config"
export OBJECTION_SSH_CONFIG="$T/ssh_config"
git -C "$T/named" remote add alias1 "git@github-work:me/repo.git"
check 2 "$T/named" Bash 'gh pr create --head me:feat --base develop -R up/repo'
git -C "$T/named" remote set-url alias1 "git@gitlab-work:me/repo.git"
check 0 "$T/named" Bash 'gh pr create --head me:feat --base develop -R up/repo'
git -C "$T/named" remote set-url alias1 "git@gitserver:me/repo.git"
check 0 "$T/named" Bash 'gh pr create --head me:feat --base develop -R up/repo'
git -C "$T/named" remote set-url alias1 "git@github.com.evil.io:me/repo.git"
check 0 "$T/named" Bash 'gh pr create --head me:feat --base develop -R up/repo'
git -C "$T/named" remote set-url alias1 "ssh://git@github-work/me/repo.git"
check 2 "$T/named" Bash 'gh pr create --head me:feat --base develop -R up/repo'
git -C "$T/named" remote set-url alias1 "git@github.com-work:me/repo.git"
check 2 "$T/named" Bash 'gh pr create --head me:feat --base develop -R up/repo'
# ssh cannot answer: fail closed (kept, so ambiguous, so blocked), even for
# an alias that would have resolved elsewhere.
# (A config file that does not exist makes ssh -G fail on every system; a
# stub named ssh would not be run by node on Windows.)
git -C "$T/named" remote set-url alias1 "git@gitlab-work:me/repo.git"
OBJECTION_SSH_CONFIG="$T/no-such-config" check 2 "$T/named" Bash 'gh pr create --head me:feat --base develop -R up/repo'
# A host that starts with "-" never reaches ssh as an option; kept (blocked).
git -C "$T/named" remote set-url alias1 "ssh://-oProxyCommand=touch%20$T/pwned/me/repo.git"
check 2 "$T/named" Bash 'gh pr create --head me:feat --base develop -R up/repo'
[ -e "$T/pwned" ] && { echo "FAIL: a remote URL ran a command through ssh"; failures=$((failures + 1)); }
git -C "$T/named" remote remove alias1
unset OBJECTION_SSH_CONFIG
gitc -C "$T/named" commit -q --allow-empty -m later
git -C "$T/named" push -q fork HEAD:feat
git -C "$T/named" reset -q --hard "$NAMED_SHA"
check 2 "$T/named" Bash 'gh pr create --head me:feat --base develop -R up/repo'
# Round 2: two remotes under one owner; only <owner>/<repo name> counts.
git init -q --bare "$T/acme/docs-site.git" 2>/dev/null || { mkdir -p "$T/acme" && git init -q --bare "$T/acme/docs-site.git"; }
git init -q --bare "$T/acme/app.git"
git -C "$T/named" remote add adocs "$T/acme/docs-site.git"
git -C "$T/named" remote add zapp "$T/acme/app.git"
git -C "$T/named" push -q adocs feat
gitc -C "$T/named" commit -q --allow-empty -m undebated
git -C "$T/named" push -q zapp HEAD:feat
git -C "$T/named" reset -q --hard "$NAMED_SHA"
check 2 "$T/named" Bash 'gh pr create --head acme:feat --base develop -R acme/app'
git -C "$T/named" push -q -f zapp feat
check 0 "$T/named" Bash 'gh pr create --head acme:feat --base develop -R acme/app'
# -R picks the remote that matches it, and reaches gh repo view.
git init -q --bare "$T/up/repo.git" 2>/dev/null || { mkdir -p "$T/up" && git init -q --bare "$T/up/repo.git"; }
git -C "$T/named" remote add upstream "$T/up/repo.git"
git -C "$T/named" push -q upstream feat
STUB_DEFAULT=develop STUB_REPO_WANT=up/repo check 0 "$T/named" Bash 'gh pr create -R up/repo --head feat'
STUB_DEFAULT=develop STUB_REPO_WANT=other/repo check 2 "$T/named" Bash 'gh pr create -R up/repo --head feat'

# --- Other hosts' input shapes ----------------------------------------------
hostcheck() { # expected host json
  local rc
  printf '%s' "$3" | node "$HOOK" --host "$2" >"$T/out" 2>/dev/null
  rc=$?
  if [ "$rc" != "$1" ]; then echo "FAIL host $2 (expected $1, got $rc): $3"; failures=$((failures + 1)); fi
}
# JSON builders (inline JSON in bash gets brace-expanded).
cursor_shell() { node -e "console.log(JSON.stringify({command:process.argv[1],cwd:process.argv[2]}))" "$1" "$N"; }
cursor_mcp() { node -e "console.log(JSON.stringify({tool_name:process.argv[1],tool_input:{},mcp_server_name:\"github\",cwd:process.argv[2]}))" "$1" "$N"; }
tool_cmd() { node -e "console.log(JSON.stringify({tool_name:process.argv[1],tool_input:{command:process.argv[2]},cwd:process.argv[3]}))" "$1" "$2" "$N"; }
# Cursor beforeShellExecution: { command, cwd }; verdict JSON on stdout.
hostcheck 2 cursor "$(cursor_shell "gh pr create --fill")"
grep -q "\"permission\":\"deny\"" "$T/out" || { echo "FAIL: cursor deny JSON missing"; failures=$((failures + 1)); }
hostcheck 0 cursor "$(cursor_shell "git status")"
grep -q "\"permission\":\"allow\"" "$T/out" || { echo "FAIL: cursor allow JSON missing"; failures=$((failures + 1)); }
# Cursor beforeMCPExecution: { tool_name, tool_input, mcp_server_name }.
hostcheck 2 cursor "$(cursor_mcp create_pull_request)"
hostcheck 0 cursor "$(cursor_mcp get_pull_request)"
# Codex PreToolUse and Gemini BeforeTool: { tool_name, tool_input: { command }, cwd }.
hostcheck 2 codex "$(tool_cmd Bash "gh pr create")"
hostcheck 2 gemini "$(tool_cmd run_shell_command "gh pr merge 5")"
hostcheck 0 gemini "$(tool_cmd read_file "")"
# Tool-neutral opt-in file at the repository root.
git init -q "$T/neutral" && printf '{"bases":["main"]}\n' >"$T/neutral/.objection.json" && gitc -C "$T/neutral" add . && gitc -C "$T/neutral" commit -q -m n
check 2 "$T/neutral" Bash 'gh pr create --fill'

# A record quoting APPROVED but ending REJECTED: blocked.
printf '%s\n# x\nexample: VERDICT: APPROVED\nVERDICT: APPROVED\nVERDICT: REJECTED\n' "$stamp" >"$T/ok/.git/objection/$OK_SHA.md"
check 2 $O Bash 'gh pr create --fill --base develop'

# hook.sh: a node that cannot start (a version manager's shim exits 126
# when .tool-versions pins a version that is not installed) blocks a PR
# command in an opted-in repository, and nothing else.
HOOKSH="$ROOT/skills/objection/gate/hook.sh"
mkdir -p "$T/badnode" && printf '#!/bin/sh\necho "No version is set for command node" >&2\nexit 126\n' >"$T/badnode/node" && chmod +x "$T/badnode/node"
shrun() { # expected cwd command [host]
  local rc
  (cd "$2" && printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$2" "$3" |
    PATH="$T/badnode:$PATH" sh "$HOOKSH" ${4:+--host "$4"} >"$T/sh.out" 2>"$T/sh.err")
  rc=$?
  [ "$rc" = "$1" ] || { echo "FAIL hook.sh (expected $1, got $rc): $3 in $2"; failures=$((failures + 1)); }
}
shrun 2 "$O" "gh pr merge 5 --squash"
grep -q "node was found but could not start" "$T/sh.err" || { echo "FAIL: hook.sh does not say node did not start"; failures=$((failures + 1)); }
shrun 0 "$O" "ls -la"
# Each way node fails says what to fix: not found (127), found but not
# started (126), started and failed (a crash, or a Node.js too old).
for code in 127 1; do
  mkdir -p "$T/node$code" && printf '#!/bin/sh\nexit %s\n' "$code" >"$T/node$code/node" && chmod +x "$T/node$code/node"
  (cd "$O" && printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"gh pr merge 5"}}' "$O" |
    PATH="$T/node$code:$PATH" sh "$HOOKSH" >/dev/null 2>"$T/sh.err")
  [ "$?" = 2 ] || { echo "FAIL: hook.sh did not block when node exited $code"; failures=$((failures + 1)); }
  case "$code" in
    127) grep -q "node is not on the hook's PATH" "$T/sh.err" || { echo "FAIL: hook.sh does not say node is missing"; failures=$((failures + 1)); } ;;
    1) grep -q "node exited 1 while checking" "$T/sh.err" || { echo "FAIL: hook.sh does not say node failed"; failures=$((failures + 1)); } ;;
  esac
done
# The host may start the hook outside the project: the payload's cwd, and
# a `cd` in the command, still find the opted-in repository.
shrun_at() { # expected run-dir payload-cwd command
  local rc
  (cd "$2" && printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$3" "$4" |
    PATH="$T/badnode:$PATH" sh "$HOOKSH" >/dev/null 2>&1)
  rc=$?
  [ "$rc" = "$1" ] || { echo "FAIL hook.sh (expected $1, got $rc): $4 run in $2, cwd $3"; failures=$((failures + 1)); }
}
shrun_at 2 "$T" "$O" "gh pr merge 5 --squash"
shrun_at 2 "$T" "$T" "cd $O && gh pr merge 5 --squash"
shrun_at 0 "$T" "$F" "gh pr merge 5 --squash"
# A quoted cd target with a space (JSON-escaped quotes in the payload).
git init -q "$T/sp ace" && optin "$T/sp ace"
shrun_at 2 "$T" "$T" "cd \\\"$T/sp ace\\\" && gh pr merge 5 --squash"
# A target that holds "cd " itself: only the leading cd is stripped.
git init -q "$T/x cd y" && optin "$T/x cd y"
shrun_at 2 "$T" "$T" "cd \\\"$T/x cd y\\\" && gh pr merge 5 --squash"
shrun 0 "$F" "gh pr merge 5 --squash"
shrun 2 "$O" "gh pr create --fill" cursor
grep -q '"permission":"deny"' "$T/sh.out" || { echo "FAIL: hook.sh sent Cursor no deny"; failures=$((failures + 1)); }
# With a node that runs, hook.sh is hook.mjs: same exit, same output.
(cd "$O" && printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"gh pr create --fill --base develop"}}' "$O" | sh "$HOOKSH" >/dev/null 2>&1)
[ "$?" = 2 ] || { echo "FAIL: hook.sh did not pass hook.mjs's block through"; failures=$((failures + 1)); }
(cd "$F" && printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"gh pr create --fill"}}' "$F" | sh "$HOOKSH" >/dev/null 2>&1)
[ "$?" = 0 ] || { echo "FAIL: hook.sh blocked outside an opted-in repository"; failures=$((failures + 1)); }

if [ "$failures" = 0 ]; then echo "gate: all cases passed"; else echo "gate: $failures failure(s)"; exit 1; fi
