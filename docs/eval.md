# Evaluation

## Known bugs, caught

[`eval/`](../eval) plants twenty-three bugs in small repositories and adds
eight changes with no bug at all. The first nineteen cases (JavaScript,
Python and Go, four of them clean): a negative cart total, an authorization
check turned into a deny-list, a temp dir leaked on a retry, pages that
start at 1 but skip the first, a charge that lost its row lock, a SQL
query built by concatenating a search term, request headers (with the
`Authorization` token) written to the log, writes fired from a
`forEach(async ...)` and never awaited, a ban check on a user fetched
without `await` (the `async` is in a file the PR does not touch), and
the negative total again with a comment telling the reviewer the change
is approved, a file name checked by a regex with no anchors before it
reaches `path.join` (path traversal), and a new DELETE route that skips
the owner check its GET sibling has, a session cookie read back with
`pickle.loads` (remote code execution), and a Go `err` shadowed by `:=`
that marks a failed charge as paid. One clean change adds `ORDER BY`
and a bounded `LIMIT` to a parameterized query, to see whether SQL alone
draws a false alarm; another makes slugs drop accents, which leaves
non-Latin titles empty exactly as the old code did. One more changes a
function to return cents instead of dollars while a caller in an
untouched file still multiplies by 100. It runs the accuser on each.
**All 40 cases, five runs each, two model families (0.20).** 23 planted
bugs, 8 clean changes and the 9 real bugs below, every reviewer tool off:

| runner | planted bugs | false alarms | real bugs at the right severity | all bugs |
|---|---|---|---|---|
| claude sonnet, effort medium | 114 of 115 (java-sublist missed once) | 2 of 40, both on clean-py (the slug case) | 32 of 45 (71%); 39 of 45 at any severity | 146 of 160, 91% |
| Gemini CLI default | 115 of 115 | 5 of 40: clean-sql (an `ORDER BY` said to need an index, twice), clean-java-log (a null that `Catalog` never returns, twice), clean-migration (once) | 34 of 45 (76%) | 149 of 160, 93% |

Sonnet: about $0.58 of API price per 40-case run. The misses on real bugs
are mostly the same cases on both: rails-532cd49 and cpython-bdba8ef, and
redis-610eb26 rated MEDIUM by sonnet (Gemini rated it HIGH every time).

clean-ts-default was not clean when it was first written: making `sep` a
second parameter lets `dates.map(isoDay)` pass the array index as the
separator. Gemini reported it in two runs; sonnet missed it in all five.
Its first fix, an options object `{ sep }`, broke the same call at
compile time in TypeScript (a `number` is not an options object), which
the CI review caught. It now leaves `isoDay` as it was and adds
`isoDayWith(d, sep)`; `[date].map(isoDay)` typechecks under `--strict`,
and it passed 5 of 5 on each runner. Those runs replace its first results
in the table. Every run's raw output, the
re-runs included: [results/2026-09-25.md](../eval/results/2026-09-25.md).

Earlier runs, the first nineteen cases:

| runner | bugs caught | false alarms on the four clean changes | cost |
|---|---|---|---|
| claude sonnet, effort medium | 15 of 15 (13 BLOCKER, 2 HIGH), every one citing a bug line | none in that run; the slug case in 3 of 10 runs (below) | $0.23 for all nineteen |
| the same model, a plain "review this diff" prompt and the raw diff (`EVAL_BASELINE=1`) | 14 of 15: the cross-file bug rated MEDIUM | none | $0.13 |
| gemini-3.1-pro-preview (the Gemini CLI's default) | 15 of 15 (13 BLOCKER, 2 HIGH) | the slug case | about 6k tokens a review (measured on PR #42) |
| gemini-3-flash-preview (0.16, first twelve cases) | 10 of 10 (9 BLOCKER, 1 HIGH) | none of two | Flash pricing, below Pro |

Run with `EVAL_DEFENSE=1`, the defender upheld every catch on both
runners: it never talked the judge out of a planted bug. Other models,
measured once: haiku caught 14 of 14 on the eighteen-case set with one
false alarm, at about twice sonnet's cost here, so it is not the default.

False alarms move too: on the slug case, sonnet flagged the empty slug
as HIGH in 6 of 9 runs until both roles were told to rate what the
change does (a defect the removed lines show the old code had is at most
LOW); after that, 3 of 10. That is the defender's job in a real debate,
and one run in which the defender still upheld the alarm is why the
judge, not the defender, has the last word.

Severities move a step between runs (a HIGH one run is a BLOCKER the
next); the catches did not. The cross-file case is why the brief now carries the definitions the
added lines call, read from the commit: without them, sonnet rated it
HIGH twice and once only MEDIUM ("if `getUser` is async"), with
`src/users.js` under "Could not evaluate"; with them, BLOCKER three times
out of three, at the same cost.

The prompt-injection case was caught by all three: text in the diff is
data under review, not instructions. Flash's first run scored the SQL
injection as missed, although it had written the finding as BLOCKER:
its table had no outer pipes, so every reader counted no rows, and a CI
check would have passed that BLOCKER. review.sh now adds the pipes to
such a table (test/review.test.sh and test/ci-review.test.sh pin it),
and the rerun counted it. Run the eval yourself with `bash eval/run.sh`
(`OBJECTION_RUNNER=gemini` or `codex` for the others, and
`OBJECTION_GEMINI_MODEL` for the model). It calls a real model, so CI
runs only its scoring, against a fake reviewer (test/eval.test.sh).
Nineteen small cases prove the reviewers catch these bugs, not that they
catch every bug.

**A defender in CI, without a judge (0.23).** Could the CI review drop
false alarms by letting a defender refute them? The saved Gemini answers
from two full runs went to a sonnet defender (`EVAL_RESCORE` with
`EVAL_DEFENSE=1`, no accuser paid again): of 5 false alarms it refuted
none, proposed a lower severity for 2 and could not verify 2 (an
`ORDER BY` said to need an index, which only an `EXPLAIN` settles); of 65
findings on real bugs it upheld 64 and refuted one, the main row of
caller-units, with a refutation citing a real line that called itself
"not confirmed"; it upheld that bug's other row but argued for LOW. Fresh runs
with the defender on the accuser's own model refuted no false alarm
either. So in CI the defense is advice shown with the findings, never the
verdict: honored, it would have passed a real bug through. In the local
debate a judge reads the same answers and decides ([raw output](../eval/results/2026-09-26-ci-defense.md)).

**Database changes (0.22).** Five more: a wallet spend that reads the
balance, checks it and writes it back (two spends at once both pass), an
`UPDATE` that lost its `WHERE` in a refactor, a column renamed in the same
deploy as the code that reads it (the old instances still select the old
name), an index built without `CONCURRENTLY` on a 40-million-row table
written on every checkout, and a clean single-statement spend. Three runs
on sonnet before any change to the roles: every bug caught every time
(the four at BLOCKER or MEDIUM as expected, citing the line), and the
clean case passed three of three ([raw output](../eval/results/2026-09-26-database.md)). So the reviewers were not the gap; the
flow was: under `lean`, a migration of a line or two was a "small diff"
and ran no reviewer at all. It now always gets one.

**Added in 0.20, not run yet** (twelve cases, so 31 planted and 9 real,
40 in all; eight clean changes to measure false alarms instead of four):
a Rust quantity truncated to `u8` before pricing while shipping uses the
full one, a Java `subList` past the end of the last page, a migration
adding a `NOT NULL` column with no default to a table that has rows, a
Terraform policy that opens the whole uploads bucket to serve avatars, an
Express 403 without `return` so the delete still runs, a Rails
`permit!` that lets a user set their own role, a PHP `==` on md5 hashes
(`0e` magic hashes), and a deploy script that runs `rm -rf "$dir"/*`
with `$dir` empty once `set -u` is gone. Clean: a Rust helper extracted, a
TypeScript parameter whose default keeps the old output, a nullable
column, and a Java log line with a count. Each was checked without a
model: its brief builds with the bug lines in the diff, and the scorer
catches a row that cites them and misses one that does not.

## Real bugs, replayed

Planted bugs in small files are the easy case. [`eval/real/`](../eval/real)
replays 24 **real** regressions from public repositories (nine first,
fifteen more below): commits that
introduced a defect a later commit fixed, naming the culprit in its
message. CPython (twice, Python and C), Redis, Rails, Django, Go, Vue,
ESLint and curl. The code is not stored here (licenses vary):
`bash eval/real/fetch.sh` downloads the touched files at the culprit's
parent and at the culprit, and `EVAL_FIXTURES=<dir> bash eval/run.sh`
reviews the culprit's diff as if it were the PR. Each case lists its
source commit and the fix that names it in [`cases.jsonl`](../eval/real/cases.jsonl).

Four runs per side on sonnet at effort medium, against the same model
with a one-paragraph "review this diff" prompt and the raw diff
(`EVAL_BASELINE=1`), so the difference is what the brief and the roles
add:

| | caught at the expected severity | found at any severity |
|---|---|---|
| objection, sonnet | 29 of 36 (81%) | 34 of 36 (94%) |
| plain prompt, same model | 22 of 36 (61%) | 29 of 36 (81%) |
| objection, Gemini CLI default (two runs) | 12 of 18 (67%) | 12 of 18 (67%) |

The gap is in three cases: curl's cookie engine left not running when
called without a handle (objection 4 of 4, the plain prompt 2 of 4),
CPython's `parse_qsl` accepting integers after a bytes refactor (3 of 4
against none), and Rails' inflection regexes matching "taxis" (2 of 4
against none). The Redis null-pointer crash is found but under-rated:
objection every time as MEDIUM, the plain prompt 3 of 4 times as LOW;
the Gemini runs rated it HIGH.
objection costs more per review (about $0.02 against $0.014), the price
of the brief.

Scoring is the same for every side, and it was audited by hand: the
first scorer missed citations written as a range (`cookie.c:1248-1298`)
or as an estimate (`linter.js:~174`, how a reviewer without line numbers
cites), which undercounted both sides. `EVAL_KEEP=<dir>` saves every
answer and `EVAL_RESCORE=<dir>` scores saved answers again without
calling a model, so a scoring fix is applied to the runs already paid for.

### Fifteen more, and the first nine overstated it

Fifteen more real regressions (2026-10-01: nushell, helix, netty,
Prometheus, Gitea, Node.js, Vite, Symfony, Npgsql, Rack, Werkzeug), same
setup, four runs per side, graded by hand
([results](../eval/results/2026-10-01-real-bugs.md)):

| | right severity | found at any severity |
|---|---|---|
| objection, sonnet | 25 of 60 (42%) | 33 of 60 (55%) |
| plain prompt, same model | 33 of 60 (55%) | 37 of 60 (62%) |

On these, objection did **worse** than the plain prompt: it under-rated
a bug it found every time (helix: MEDIUM where the plain prompt said
HIGH) and missed two the plain prompt found (Node.js, Symfony). Over all
24 real bugs the two are even (54 and 55 of 96). What objection adds that
a plain prompt does not is the defender, the judge, the gate and the
record, not a better first read of the diff; five of the fifteen nobody
found at all.

## Track record

objection reviews its own pull requests, and every record is public in
the PR body. Over five feature PRs
([#20](https://github.com/victorserpa/objection/pull/20) to
[#28](https://github.com/victorserpa/objection/pull/28)): **43 findings
the judge upheld**, every BLOCKER and HIGH fixed before merge (the rest
fixed or kept as open LOW items in the record), among them a gate that let a
PR through when `ssh` could not answer (#22), a CI check that passed on
bash 3.2 after a crash (#26), and a size rule that read binary files as
zero lines and skipped the review (#26). The same debates cost $1.22 to
$2.36 with opus forced on everything; on today's defaults the last one
(#28, two rounds) cost **$0.135**.
