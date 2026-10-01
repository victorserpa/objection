#!/bin/bash
# Cases for eval/run.sh's scoring, with a fake `claude` that answers a
# fixed row: no model is called.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
cat >"$T/claude" <<'STUB'
#!/bin/bash
cat >/dev/null
# The defender runs with defender.md as its system prompt file.
out=$FAKE_ROW
case " $* " in *defender.md*) out=${FAKE_DEFENSE:-} ;; esac
FAKE_OUT=$out node -e 'process.stdout.write(JSON.stringify({result: process.env.FAKE_OUT, usage: {input_tokens: 1, output_tokens: 1}, total_cost_usd: 0}))'
STUB
chmod +x "$T/claude"
export OBJECTION_CLAUDE="$T/claude"
score() { # fixture row -> the result column
  FAKE_ROW="$2" bash "$ROOT/eval/run.sh" "$1" 2>/dev/null | awk -v n="$1" '$1 == n' | grep -oE 'CAUGHT|LOW-RATED|MISSED|PASS|FALSE-ALARM|ERROR' | head -n 1
}
row='| HIGH | BUG | src/export.js:%s | %s | read | %s |'
# A cited bug line, or the bug said in the defect cell: caught.
[ "$(score missing-cleanup "$(printf "$row" 11 'x' 'p')")" = CAUGHT ] || fail "a cited bug line was not caught"
[ "$(score missing-cleanup "$(printf "$row" 40 'the temp dir leaks on retry' 'p')")" = CAUGHT ] || fail "the bug in words was not caught"
# Which evidence counted: the line when cited, else the words.
how() { FAKE_ROW="$2" bash "$ROOT/eval/run.sh" "$1" 2>/dev/null | awk -v n="$1" '$1 == n' | grep -oE '\((line|words)\)'; }
[ "$(how missing-cleanup "$(printf "$row" 11 'x' 'p')")" = "(line)" ] || fail "a cited line was not reported as (line)"
[ "$(how missing-cleanup "$(printf "$row" 40 'the temp dir leaks on retry' 'p')")" = "(words)" ] || fail "a catch in words was not reported as (words)"
# The file named in the defect cell too: the file:line cell still counts.
[ "$(score missing-cleanup '| HIGH | BUG | the temp dir in src/export.js leaks | src/export.js:11 | read | p |')" = CAUGHT ] || fail "a file named twice was not caught"
# An unrelated finding in the same file is not a catch, even when a
# keyword appears elsewhere in the row.
[ "$(score missing-cleanup "$(printf "$row" 40 'unrelated: the code is not clean' 'p')")" = MISSED ] || fail "an unrelated finding was caught"
[ "$(score missing-cleanup "$(printf "$row" 40 'style nit' 'leaks the temp dir')")" = MISSED ] || fail "a keyword in the proof cell was caught"
# The clean change: a HIGH is a false alarm, a LOW is not.
[ "$(score clean "| HIGH | BUG | src/format.js:1 | x | read | p |")" = FALSE-ALARM ] || fail "a HIGH on the clean change passed"
[ "$(score clean "| LOW | BUG | src/format.js:1 | x | read | p |")" = PASS ] || fail "a LOW on the clean change failed"
# EVAL_DEFENSE=1: a false alarm and a catch go to the defender, and the
# line says what it ruled; a clean pass does not call it.
def='| # | verdict | evidence | kind | sentence |
|---|---|---|---|---|
| 1 | REFUTED | src/format.js:1 | read | the old code did the same |'
line=$(EVAL_DEFENSE=1 FAKE_DEFENSE="$def" FAKE_ROW="| HIGH | BUG | src/format.js:1 | x | read | p |" bash "$ROOT/eval/run.sh" clean 2>/dev/null | awk '$1 == "clean"')
case "$line" in *"defense: 1 refuted, 0 lower proposed, 0 upheld, 0 cannot verify"*) ;; *) fail "the defense on a false alarm was not reported ($line)" ;; esac
# A catch goes to the defender too (review.sh passes the role with
# --system-prompt-file, which is what the stub keys on).
up='| # | verdict | evidence | kind | sentence |
|---|---|---|---|---|
| 1 | UPHELD | src/export.js:11 | read | nothing cleans it up |'
line=$(EVAL_DEFENSE=1 FAKE_DEFENSE="$up" FAKE_ROW="$(printf "$row" 11 'x' 'p')" bash "$ROOT/eval/run.sh" missing-cleanup 2>/dev/null | awk '$1 == "missing-cleanup"')
case "$line" in *"defense: 0 refuted, 0 lower proposed, 1 upheld, 0 cannot verify"*) ;; *) fail "the defense on a catch was not reported ($line)" ;; esac
# "UPHELD, propose LOW" is counted apart from a plain UPHELD.
low='| # | verdict | evidence | kind | sentence |
|---|---|---|---|---|
| 1 | UPHELD, propose LOW | src/format.js:1 | read | smaller than said |'
line=$(EVAL_DEFENSE=1 FAKE_DEFENSE="$low" FAKE_ROW="| HIGH | BUG | src/format.js:1 | x | read | p |" bash "$ROOT/eval/run.sh" clean 2>/dev/null | awk '$1 == "clean"')
case "$line" in *"defense: 0 refuted, 1 lower proposed, 0 upheld, 0 cannot verify"*) ;; *) fail "a proposed lower severity was not counted apart ($line)" ;; esac
# A proposal above the accused severity is not "lower".
up2='| # | verdict | evidence | kind | sentence |
|---|---|---|---|---|
| 1 | UPHELD, propose BLOCKER | src/format.js:1 | read | worse than said |'
line=$(EVAL_DEFENSE=1 FAKE_DEFENSE="$up2" FAKE_ROW="| HIGH | BUG | src/format.js:1 | x | read | p |" bash "$ROOT/eval/run.sh" clean 2>/dev/null | awk '$1 == "clean"')
case "$line" in *"defense: 0 refuted, 0 lower proposed, 1 upheld, 0 cannot verify"*) ;; *) fail "a higher proposal was counted as lower ($line)" ;; esac
# EVAL_RESCORE with EVAL_DEFENSE: saved answers go to the defender too.
mkdir -p "$T/saved" && printf '| HIGH | BUG | src/format.js:1 | x | read | p |\n' >"$T/saved/clean.out"
line=$(EVAL_RESCORE="$T/saved" EVAL_DEFENSE=1 FAKE_DEFENSE="$def" bash "$ROOT/eval/run.sh" clean 2>/dev/null | awk '$1 == "clean"')
case "$line" in *"FALSE-ALARM"*"defense: 1 refuted"*) ;; *) fail "a saved answer was not defended ($line)" ;; esac
line=$(EVAL_DEFENSE=1 FAKE_DEFENSE="$def" FAKE_ROW="NO FINDINGS" bash "$ROOT/eval/run.sh" clean 2>/dev/null | awk '$1 == "clean"')
case "$line" in *defense:*) fail "the defender ran on a clean pass ($line)" ;; esac
# EVAL_FIXTURES: another fixture directory (eval/real/fetch.sh builds one).
X="$T/fx" && mkdir -p "$X/one/base/src" "$X/one/change/src"
printf '{"bases":["main"]}\n' >"$X/one/config.json"
printf 'a\n' >"$X/one/base/src/a.js" && printf 'b\n' >"$X/one/change/src/a.js"
printf '{"goal":"g","severity":"HIGH","match":"zzz","file":"src/a.js","lines":[1]}\n' >"$X/one/expect.json"
line=$(EVAL_FIXTURES="$X" FAKE_ROW="| HIGH | BUG | src/a.js:1 | x | read | p |" bash "$ROOT/eval/run.sh" one 2>/dev/null | awk '$1 == "one"')
case "$line" in *CAUGHT*) ;; *) fail "EVAL_FIXTURES was not used ($line)" ;; esac
# A shortened path counts when its directories are in the real one, in
# order; a path with another directory does not.
mkdir -p "$X/deep/base/pkg/src/main/x" "$X/deep/change/pkg/src/main/x"
printf '{"bases":["main"]}\n' >"$X/deep/config.json"
printf 'a\n' >"$X/deep/base/pkg/src/main/x/Long.java" && printf 'b\n' >"$X/deep/change/pkg/src/main/x/Long.java"
printf '{"goal":"g","severity":"HIGH","match":"zzz","file":"pkg/src/main/x/Long.java","lines":[1]}\n' >"$X/deep/expect.json"
for cite in 'pkg/.../Long.java:1' 'Long.java:1' 'main/x/Long.java:1' '`pkg/…/Long.java:1`'; do
  line=$(EVAL_FIXTURES="$X" FAKE_ROW="| HIGH | BUG | $cite | x | read | p |" bash "$ROOT/eval/run.sh" deep 2>/dev/null | awk '$1 == "deep"')
  case "$line" in *CAUGHT*) ;; *) fail "the shortened path $cite was not read ($line)" ;; esac
done
for cite in 'other/Long.java:1' 'x/main/Long.java:1' 'NotLong.java:1'; do
  line=$(EVAL_FIXTURES="$X" FAKE_ROW="| HIGH | BUG | $cite | x | read | p |" bash "$ROOT/eval/run.sh" deep 2>/dev/null | awk '$1 == "deep"')
  case "$line" in *MISSED*) ;; *) fail "the wrong path $cite counted ($line)" ;; esac
done
# A range holding a bug line counts; a range too wide to name it does not.
[ "$(score missing-cleanup "$(printf "$row" '5-12' 'x' 'p')")" = CAUGHT ] || fail "a range holding the bug line was not caught"
[ "$(score missing-cleanup "$(printf "$row" '1-200' 'x' 'p')")" = MISSED ] || fail "a 200-line range counted as citing the bug"
[ "$(score missing-cleanup "$(printf "$row" '~11' 'x' 'p')")" = CAUGHT ] || fail "an approximate ~line citation was not read"
# EVAL_RESCORE: scores saved answers without calling the model.
mkdir -p "$T/saved" && printf '| HIGH | BUG | src/export.js:11 | x | read | p |\n' >"$T/saved/missing-cleanup.out"
line=$(EVAL_RESCORE="$T/saved" OBJECTION_CLAUDE=/nonexistent bash "$ROOT/eval/run.sh" missing-cleanup 2>/dev/null | awk '$1 == "missing-cleanup"')
case "$line" in *CAUGHT*) ;; *) fail "EVAL_RESCORE did not score the saved answer ($line)" ;; esac
# EVAL_KEEP: a directory that does not exist yet, given as a relative path.
(cd "$T" && EVAL_FIXTURES="$X" EVAL_KEEP=kept/new FAKE_ROW="| HIGH | BUG | src/a.js:1 | x | read | p |" bash "$ROOT/eval/run.sh" one >/dev/null 2>&1)
[ -s "$T/kept/new/one.out" ] || fail "EVAL_KEEP did not keep the answer in a new, relative directory"
# No fixture ran: not a pass.
bash "$ROOT/eval/run.sh" nosuch >/dev/null 2>&1
[ $? = 2 ] || fail "an empty run did not exit 2"
[ "$failures" = 0 ] && echo "eval: all cases passed" || { echo "eval: $failures failure(s)"; exit 1; }
