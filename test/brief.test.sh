#!/bin/bash
# Cases for skills/objection/brief.sh.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIEF="$ROOT/skills/objection/brief.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
gitc() { git -c user.email=t@t -c user.name=t "$@"; }
failures=0
has() { grep -qF -- "$2" "$1" || { echo "FAIL: brief lacks [$2]"; failures=$((failures + 1)); }; }
hasnt() { grep -qF -- "$2" "$1" && { echo "FAIL: brief has [$2]"; failures=$((failures + 1)); }; }

R="$T/r"
git init -q "$R" && cd "$R" || exit 1
printf '{"bases":["main"],"invariants":[{"paths":"^src/game/","rule":"undo never restores a spent life"},{"paths":"^src/auth/","rule":"no private data in responses"}]}\n' >.objection.json
mkdir -p src/game src/ui && printf 'a\n' >src/game/undo.ts && printf 'a\n' >src/ui/x.ts && printf 'lock\n' >pnpm-lock.yaml
git add . && gitc commit -q -m base
git update-ref refs/remotes/origin/main HEAD
printf 'b\n' >>src/game/undo.ts && printf 'b\n' >>src/ui/x.ts && printf 'changed\n' >>pnpm-lock.yaml
git add . && gitc commit -q -m change

out=$(bash "$BRIEF" origin/main "undo keeps lives" "src/game only")
[ -f "$out" ] || { echo "FAIL: no brief written ($out)"; exit 1; }
has "$out" "Goal: undo keeps lives"
has "$out" "Scope: src/game only"
has "$out" "- src/game/undo.ts"
has "$out" "undo never restores a spent life"
hasnt "$out" "no private data in responses"
hasnt "$out" "pnpm-lock.yaml"
has "$out" "Open at most 5 other files"
has "$out" "(from origin/main)"

# Invariants come from the base, not from the branch under review.
printf '{"bases":["main"],"invariants":[]}\n' >.objection.json
git add . && gitc commit -q -m "drop invariants on the branch"
out=$(bash "$BRIEF" origin/main)
has "$out" "undo never restores a spent life"

# A later round names the files the branch itself added: a migration the
# branch added in round 1 and renames in round 2 shipped nowhere.
mkdir -p db/migrations && printf 'create\n' >db/migrations/0041_a.sql
git add . && gitc commit -q -m "round 1 adds a migration"
prev=$(git rev-parse HEAD)
git mv db/migrations/0041_a.sql db/migrations/0042_a.sql && printf 'more\n' >>src/game/undo.ts
git add . && gitc commit -q -m "round 2 renumbers it"
out=$(bash "$BRIEF" "$prev" "g" "s" origin/main)
has "$out" "## Files this branch added (not on origin/main)"
has "$out" "- db/migrations/0042_a.sql"
has "$out" "a migration among them has not"
# A file the base has is not listed; round 1 gets no such section.
sed -n '/^## Files this branch added/,/^## /p' "$out" >"$T/added"
hasnt "$T/added" "src/game/undo.ts"
out=$(bash "$BRIEF" origin/main)
hasnt "$out" "## Files this branch added"

# A base without config (the opt-in PR) falls back to the working copy.
git init -q "$T/fresh" && cd "$T/fresh" && gitc commit -q --allow-empty -m base
git update-ref refs/remotes/origin/main HEAD
printf '{"invariants":[{"paths":".","rule":"everything is guarded"}]}\n' >.objection.json
git add . && gitc commit -q -m optin
out=$(bash "$BRIEF" origin/main)
has "$out" "everything is guarded"
has "$out" "has none yet"

# A long diff is truncated and says so.
cd "$R" && for i in $(seq 1 50); do printf 'line %s\n' "$i" >>src/ui/x.ts; done
git add . && gitc commit -q -m long
out=$(OBJECTION_BRIEF_MAX_LINES=20 bash "$BRIEF" origin/main)
has "$out" "TRUNCATED:"

# --- Round 1 of the brief's own debate -------------------------------------
# Later rounds diff against the previous round's commit, but the rules still
# come from the PR's base (the branch dropped the invariant above).
cd "$R"
prev=$(git rev-parse HEAD)
printf 'c\n' >>src/game/undo.ts && git add . && gitc commit -q -m fix
out=$(bash "$BRIEF" "$prev" "the fix" "" origin/main)
has "$out" "undo never restores a spent life"
has "$out" "- src/game/undo.ts"
hasnt "$out" "- src/ui/x.ts"
# Run from a subdirectory: nothing elsewhere is dropped.
out=$(cd src/ui && bash "$BRIEF" origin/main)
has "$out" "- src/game/undo.ts"
# An invalid regex is reported, not dropped; reviewer focus is in the brief.
git init -q "$T/rx" && cd "$T/rx" && gitc commit -q --allow-empty -m base
git update-ref refs/remotes/origin/main HEAD
cat >.objection.json <<'EOF'
{"invariants":[{"paths":"^src/(bad","rule":"RULE-BAD"}],
 "reviewers":[{"paths":"^src/","agent":"security-reviewer","focus":"FOCUS-SEC"},{"paths":"^docs/","agent":"x","focus":"FOCUS-DOCS"}]}
EOF
git add . && gitc commit -q -m cfg
git update-ref refs/remotes/origin/main HEAD
mkdir -p "src/a dir" && printf 'x\n' >"src/a dir/f.ts" && git add . && gitc commit -q -m spaced
out=$(bash "$BRIEF" origin/main)
has "$out" "INVALID paths regex"
has "$out" "RULE-BAD"
has "$out" "FOCUS-SEC"
hasnt "$out" "FOCUS-DOCS"
has "$out" "- src/a dir/f.ts"
# precedents: false in the config turns them off, and says so.
printf '{"precedents":false}\n' >.objection.json && git add . && gitc commit -q -m off
git update-ref refs/remotes/origin/main HEAD~0
printf 'y\n' >>"src/a dir/f.ts" && git add . && gitc commit -q -m more
out=$(bash "$BRIEF" origin/main)
has "$out" "turned off"

# Precedents come from the base, like the rules: a branch that deletes
# them still gets them. Matching reviewers are listed for debate.sh.
P="$T/prec"
git init -q "$P" && cd "$P" || exit 1
printf '{"bases":["main"],"reviewers":[{"paths":"^src/","focus":"money math","agent":"money"},{"paths":"^docs/","focus":"prose","agent":"docs"}]}\n' >.objection.json
mkdir -p src && printf 'a\n' >src/pay.ts
node "$ROOT/skills/objection/precedents.mjs" add --area src/ --pattern "rounding lost a cent" --sha abc1234 >/dev/null
git add . && gitc commit -q -m base
git update-ref refs/remotes/origin/main HEAD
git rm -q .objection/precedents.md && printf 'b\n' >>src/pay.ts && git add . && gitc commit -q -m "drop precedents"
out=$(bash "$BRIEF" origin/main)
# Checked in its section: the deletion itself shows the line in the diff.
awk '/^## Defects/{f=1;next} /^## /{f=0} f' "$out" | grep -qF "rounding lost a cent" || { echo "FAIL: precedents read from the branch"; failures=$((failures + 1)); }
has "$out" "<!-- objection-reviewer: money	money math -->"
hasnt "$out" "objection-reviewer: docs"

# Model tier, from the base config: the cheap model unless an invariant
# matches, strongPaths matches, or the budget is thorough.
M="$T/model"
git init -q "$M" && cd "$M" || exit 1
printf '{"bases":["main"],"invariants":[{"paths":"^src/pay","rule":"money exact"}],"strongPaths":"^src/gate/"}\n' >.objection.json
mkdir -p src/gate && printf 'a\n' >src/ui.ts && printf 'a\n' >src/pay.ts && printf 'a\n' >src/gate/x.ts
git add . && gitc commit -q -m base && git update-ref refs/remotes/origin/main HEAD
printf 'b\n' >>src/ui.ts && git add . && gitc commit -q -m ui
out=$(bash "$BRIEF" origin/main)
has "$out" "<!-- objection-model: sonnet medium default -->"
git reset -q --hard origin/main && printf 'b\n' >>src/pay.ts && git add . && gitc commit -q -m pay
out=$(bash "$BRIEF" origin/main)
has "$out" "<!-- objection-model: opus medium invariant -->"
git reset -q --hard origin/main && printf 'b\n' >>src/gate/x.ts && git add . && gitc commit -q -m gate
out=$(bash "$BRIEF" origin/main)
has "$out" "<!-- objection-model: opus medium strongPaths -->"
# Configured models and effort, and thorough.
git reset -q --hard origin/main
printf '{"bases":["main"],"budget":"thorough","models":{"default":"haiku","strong":"sonnet","effort":"low"}}\n' >.objection.json
git add . && gitc commit -q -m cfg && git update-ref refs/remotes/origin/main HEAD
printf 'c\n' >>src/ui.ts && git add . && gitc commit -q -m ui2
out=$(bash "$BRIEF" origin/main)
has "$out" "<!-- objection-model: sonnet low thorough -->"
# strongEffort sets the strong tier's effort apart.
printf '{"bases":["main"],"budget":"thorough","models":{"strong":"opus","effort":"low","strongEffort":"high"}}\n' >.objection.json
git add . && gitc commit -q -m cfg2 && git update-ref refs/remotes/origin/main HEAD
printf 'd\n' >>src/ui.ts && git add . && gitc commit -q -m ui3
out=$(bash "$BRIEF" origin/main)
has "$out" "<!-- objection-model: opus high thorough -->"
has "$out" "<!-- objection-lines: 1 -->"
# The defender's model and the later rounds' effort: defaults, then config.
has "$out" "<!-- objection-defender: sonnet -->"
has "$out" "<!-- objection-later-effort: low -->"
printf '{"bases":["main"],"models":{"defender":"haiku","laterEffort":"medium"}}\n' >.objection.json
git add . && gitc commit -q -m cfg3 && git update-ref refs/remotes/origin/main HEAD
printf 'e\n' >>src/ui.ts && git add . && gitc commit -q -m ui4
out=$(bash "$BRIEF" origin/main)
has "$out" "<!-- objection-defender: haiku -->"
has "$out" "<!-- objection-later-effort: medium -->"
# Three lines of context, not five: the diff is what the reviewers pay for.
seq 1 30 >src/ctx.ts && git add . && gitc commit -q -m ctx && git update-ref refs/remotes/origin/main HEAD
sed 's/^15$/fifteen/' src/ctx.ts >src/ctx.tmp && mv src/ctx.tmp src/ctx.ts && git add . && gitc commit -q -m ctx2
out=$(bash "$BRIEF" origin/main)
grep -qx '   12  12' "$out" || { echo "FAIL: the brief lost the third line of context"; failures=$((failures + 1)); }
# Each hunk line carries its new-file line number; a removed line none.
grep -qx '   15 +fifteen' "$out" || { echo "FAIL: an added line is not numbered by the new file"; failures=$((failures + 1)); }
grep -qx '      -15' "$out" || { echo "FAIL: a removed line got a number"; failures=$((failures + 1)); }
# Header lines that repeat the file name are dropped; a new file keeps
# its /dev/null side, which says it is new.
grep -q '^index [0-9a-f]' "$out" && { echo "FAIL: the brief kept an index line"; failures=$((failures + 1)); }
grep -qx '+++ b/src/ctx.ts' "$out" && { echo "FAIL: the brief kept a +++ line that repeats the name"; failures=$((failures + 1)); }
printf 'n\n' >src/new.ts && git add . && gitc commit -q -m new
out_new=$(bash "$BRIEF" origin/main)
grep -qx -- '--- /dev/null' "$out_new" || { echo "FAIL: a new file lost its /dev/null line"; failures=$((failures + 1)); }
git reset -q --hard HEAD~1
grep -qx '   11  11' "$out" && { echo "FAIL: the brief has more than three lines of context"; failures=$((failures + 1)); }

# Nothing to review, or an unknown base: refuse.
(cd "$T/fresh" && git update-ref refs/remotes/origin/main HEAD && bash "$BRIEF" origin/main >/dev/null 2>&1) && { echo "FAIL: empty diff accepted"; failures=$((failures + 1)); }
(cd "$R" && bash "$BRIEF" origin/nope >/dev/null 2>&1) && { echo "FAIL: unknown base accepted"; failures=$((failures + 1)); }

# Definitions the added lines call, from untouched files: shown; a name
# defined in more than 3 places is left out; lock files are not searched.
D="$T/defs"
git init -q "$D" && cd "$D" || exit 1
printf '{"bases":["main"]}\n' >.objection.json
mkdir -p src
printf 'export async function getUser(id) {\n  return db.get(id);\n}\n' >src/users.js
for k in 1 2 3 4; do printf 'function common() {}\n' >"src/c$k.js"; done
printf 'function lockedHelper() {}\n' >deps.lock
printf 'function helperInTest() {}\n' >src/a.test.js
printf 'function outer() {\n  const innerOnly = () => 1;\n}\n' >src/outer.js
printf 'export function a() {}\n' >src/posts.js
printf 'export class Store {\n  async load(key) {\n    return fetch(key);\n  }\n}\nexport const api = {\n  save: async (x) => x,\n};\n' >src/store.js
git add . && gitc commit -q -m base && git update-ref refs/remotes/origin/main HEAD
printf 'export function canPost(id) {\n  const user = getUser(id);\n  store.load(id);\n  helperInTest();\n  innerOnly();\n  api.save(id);\n  if (getUser(id)) {}\n  common();\n  lockedHelper();\n  return !user.banned;\n}\n' >>src/posts.js
git add . && gitc commit -q -m change
out=$(bash "$BRIEF" origin/main)
has "$out" "## Definitions the diff calls"
has "$out" "src/users.js:1 (getUser)"
has "$out" "    1  export async function getUser(id) {"
has "$out" "src/store.js:2 (load)"
has "$out" "src/store.js:7 (save)"
hasnt "$out" "(common)"
hasnt "$out" "(helperInTest)"
hasnt "$out" "(innerOnly)"
hasnt "$out" "lockedHelper)"
# Nothing to show: no section.
printf 'x\n' >notes.txt && git add . && gitc commit -q -m notes
out=$(bash "$BRIEF" HEAD~1)
hasnt "$out" "## Definitions the diff calls"
cd "$T" || exit 1

# A file name with an accent still matches the invariant's paths.
U="$T/utf"
git init -q "$U" && cd "$U" || exit 1
printf '{"bases":["main"],"invariants":[{"paths":"^src/","rule":"RULE-UTF"}]}\n' >.objection.json
mkdir -p src && printf 'a\n' >"src/ação.ts"
git add . && gitc commit -q -m base && git update-ref refs/remotes/origin/main HEAD
printf 'b\n' >>"src/ação.ts" && git add . && gitc commit -q -m change
out=$(bash "$BRIEF" origin/main)
has "$out" "RULE-UTF"
has "$out" "- src/ação.ts"
cd "$T" || exit 1

# A monorepo: a package config adds rules for the files under its
# directory, with paths relative to it and commands run from it. Read from
# the base like the root config; a package the diff does not touch adds
# nothing, and repository-wide keys stay the root's.
M="$T/mono"
git init -q "$M" && cd "$M" || exit 1
mkdir -p "apps/web app" apps/api/src
printf '{"bases":["main"],"invariants":[{"paths":"^apps/","rule":"ROOT-RULE"}]}\n' >.objection.json
printf '{"verify":["npm test"],"invariants":[{"paths":"^src/","rule":"WEB-RULE","verify":"test -f ok"}],"reviewers":[{"agent":"sonnet","focus":"WEB-FOCUS","paths":"^src/"}],"budget":"thorough"}\n' >"apps/web app/.objection.json"
printf '{"invariants":[{"paths":"^src/","rule":"API-RULE"}],"strongPaths":"^src/"}\n' >apps/api/.objection.json
printf '{"invariants":[{"paths":"^apps/","rule":"ABSOLUTE-RULE"}]}\n' >apps/.objection.json.bak
git add . && gitc commit -q -m base && git update-ref refs/remotes/origin/main HEAD
mkdir -p "apps/web app/src" && printf 'a\n' >"apps/web app/src/x.ts"
# Paths are relative to the package: ^src/ at the root matches nothing.
mkdir -p src && printf 'a\n' >src/y.ts
git add . && gitc commit -q -m change
out=$(bash "$BRIEF" origin/main)
has "$out" "ROOT-RULE"
has "$out" "WEB-RULE (guards apps/web app/, ^src/)"
has "$out" "WEB-FOCUS [sonnet, apps/web app/, ^src/]"
hasnt "$out" "API-RULE"
hasnt "$out" "ABSOLUTE-RULE"
has "$out" "<!-- objection-invariant-check: cd 'apps/web app' && test -f ok	WEB-RULE -->"
has "$out" "<!-- objection-package-verify: cd 'apps/web app' && npm test -->"
has "$out" "<!-- objection-package: apps/web app	"
has "$out" "<!-- objection-reviewer: sonnet	WEB-FOCUS -->"
has "$out" "sets budget, which only the root config sets"
has "$out" "<!-- objection-budget: lean -->"
# An invariant makes the tier strong; strongPaths of an untouched package
# does not.
has "$out" "<!-- objection-model: opus medium invariant -->"
# A package's strongPaths applies inside the package only.
printf 'a\n' >apps/api/src/z.ts && git add . && gitc commit -q -m api
out=$(bash "$BRIEF" origin/main)
has "$out" "API-RULE (guards apps/api/, ^src/)"
# From the base: a branch that rewrites its package config does not change
# the rules, and one it adds does not apply yet.
printf '{"invariants":[]}\n' >"apps/web app/.objection.json"
mkdir -p apps/new && printf '{"invariants":[{"paths":".","rule":"NEW-RULE"}]}\n' >apps/new/.objection.json && printf 'a\n' >apps/new/f.ts
git add . && gitc commit -q -m rewrite
out=$(bash "$BRIEF" origin/main)
has "$out" "WEB-RULE"
hasnt "$out" "NEW-RULE (guards"
cd "$T" || exit 1
# Not valid JSON: said, never dropped silently.
B="$T/monobad"
git init -q "$B" && cd "$B" || exit 1
mkdir -p pkg && printf '{"bases":["main"]}\n' >.objection.json && printf '{nope\n' >pkg/.objection.json
git add . && gitc commit -q -m base && git update-ref refs/remotes/origin/main HEAD
printf 'a\n' >pkg/f.ts && git add . && gitc commit -q -m change
out=$(bash "$BRIEF" origin/main)
has "$out" "INVALID package config pkg/.objection.json"
# A null entry is reported, not a crash; a directory name with two spaces
# reaches cd whole.
mkdir -p "two  sp/src" && printf '{"invariants":[null,{"paths":"^src/","rule":"TWO-SP","verify":"true"}]}\n' >"two  sp/.objection.json"
git add . && gitc commit -q -m more && git update-ref refs/remotes/origin/main HEAD
printf 'a\n' >"two  sp/src/f.ts" && git add . && gitc commit -q -m touch
out=$(bash "$BRIEF" origin/main) || { echo "FAIL: a null package entry broke the brief"; failures=$((failures + 1)); }
has "$out" "INVALID invariants entry null in two  sp/.objection.json: skipped"
has "$out" "<!-- objection-invariant-check: cd 'two  sp' && true	TWO-SP -->"
cd "$T" || exit 1

# Before the root config reaches the base, packages come from the working
# copy too.
W="$T/monofresh"
git init -q "$W" && cd "$W" && gitc commit -q --allow-empty -m base && git update-ref refs/remotes/origin/main HEAD
mkdir -p pkg/a && printf '{"bases":["main"]}\n' >.objection.json
printf '{"invariants":[{"paths":".","rule":"WC-PKG-RULE"}]}\n' >pkg/.objection.json && printf 'a\n' >pkg/a/f.ts
git add . && gitc commit -q -m optin
out=$(bash "$BRIEF" origin/main)
has "$out" "WC-PKG-RULE (guards pkg/, .)"
cd "$T" || exit 1

if [ "$failures" = 0 ]; then echo "brief: all cases passed"; else echo "brief: $failures failure(s)"; exit 1; fi
