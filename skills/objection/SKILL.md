---
name: objection
description: Adversarial review before opening or merging a pull request. Accusers review the diff, a defender tries to refute each finding with evidence from the code, and the main session judges and stores a record for the exact commit. With a gate installed, PR create, ready and merge are blocked until the record is APPROVED. Use when a branch is ready for a PR, when the gate blocks, with "try" for one review of a branch without any setup, with "init" to opt a repository in, or with "doctor" to check the setup.
license: MIT
---

# /objection

Whoever wrote the code does not approve the code. The accusation looks
for defects, the defense tries to refute each one with evidence, and the
judge (this session) decides. Only what survives the defense becomes a
fix.

**Every PR, whatever its size.** Do not route around the gate (`gh api`,
a GitHub MCP tool, `curl` with a token, asking the human to run it for
you without saying the debate did not run). If it blocked, run the
debate.

"This skill's directory" means the directory containing this file. The
scripts there: `debate.sh` (one round), `stamp.sh` (validates and stores
a record), `pr-body.sh` (puts it in the PR body), `open-issue.sh` (an
issue for what stayed open), `init.sh`, `doctor.sh`,
`precedents.mjs`, and `brief.sh` / `review.sh` (what `debate.sh` runs).

## init and doctor

- The user wants one review without opting in ("just review this
  branch", `/objection try`): run section 1's `debate.sh` as it is. With
  no config it uses the `lean` budget and `origin/HEAD` as the base, and
  writes only under `.git/objection/`. Judge the draft (section 2) and
  show the rulings; no stamp, no gate, no files in the repository.
- No `.objection.json` (or `.claude/objection.json`) at the repository
  root, or the user asked for `init`: read `reference/init.md` and follow
  it. Nothing else here is needed until then.
- The user asks for `doctor`, the gate behaves unexpectedly, or a script
  reports an invalid config: run `bash <this skill's directory>/doctor.sh`
  and show its output (ok / warn / FAIL, each with the fix; it only reads).

## 0. The cheap proof first

1. Everything committed: the record is for one SHA.
2. Base: the branch the PR targets, from `bases`. `git fetch origin <base>`.
3. Run every command in `verify` **as the base branch defines it**
   (`git show origin/<base>:.objection.json`): a change can rewrite its
   own `verify`. In a monorepo, also the `verify` of each package config
   (`<dir>/.objection.json`) the diff touches, from `<dir>`: `debate.sh`
   prints them. If the base has no config yet, or the branch changes
   `verify`, show the commands to the human and run them only with their
   go-ahead. Red: fix it first.
4. **Documentation only** (every changed file is `.md`, `.mdx`, `.rst` or
   `.adoc`, a renamed file counted under both names, and none of them is
   an agent prompt, skill or instruction: `agents/`, `skills/`,
   `.claude/`, `.cursor/`, `.codex/`, `.gemini/`, `.github/`, `.agents/`,
   `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.objection.json`,
   `.objection/`): no debate. The record says "documentation only" and
   goes straight to the stamp.

## 1. One round: debate.sh

```bash
bash <this skill's directory>/debate.sh "<goal in one sentence>" "<scope, if the task states one>"
```

The base is the config's `defaultBase`; name another first
(`debate.sh <base> "<goal>"`). Later rounds review only the fix:
`debate.sh --since <previous-round-sha> "<goal>"`. It builds the brief
(the diff with numbered lines, the invariants, reviewer focus and
precedents that cover it), runs the accusers and, for the findings the
budget sends, the defender, each as an isolated process with no tools,
and writes a draft record whose Judge and Open sections say `TODO(judge)`.
It prints a summary and the draft's path: read that one file.

- **Exit 3** (no `claude` CLI): read `reference/manual-roles.md` and run
  the roles as it says.
- **Exit 4**: the round cap (below). Stop and tell the human.
- **Same diff, new SHA** (a rebase, GitHub's *Update branch*): when an
  APPROVED record already judged exactly this diff and the base gained
  nothing in the changed files, no reviewer runs; the draft carries the
  old record with one `TODO(judge)` line. Run `verify`, confirm, delete
  the line. `OBJECTION_NO_CARRY=1` runs the full round instead.
- **A small diff under `lean`** (at most `smallDiff` changed lines, default
  20, no invariant or `strongPaths` touched, no migration, SQL or schema
  file) runs no reviewer: the draft
  comes APPROVED with one `TODO(judge)` line. Read the diff and replace
  it with one sentence of your own on what it does and why it is safe, or
  write the findings and fix the counts and verdict.
- **Exit 5**: over 800 changed lines. Tell the human before spending and
  suggest splitting the PR; `debate.sh --large` reviews it as it is.

**The budget** (`budget` in `.objection.json`; **`lean` when absent**):

| | lean (default) | standard | thorough |
|---|---|---|---|
| accusers | one, with every matching `reviewers` focus folded in | generic + each matching `reviewers` entry | same as standard |
| defender | BLOCKER or HIGH findings | MEDIUM and above | LOW too |
| another round | only when the fix touches a gate, check or validator, or exceeds 40 changed lines | on every fix | on every fix |
| max rounds | 2 | 3 | 3 |

Models: sonnet at effort medium; opus where an invariant or `strongPaths`
matches, or under `thorough`; later rounds at low effort (`models` in the
config; `OBJECTION_MODEL`, `OBJECTION_DEFENDER_MODEL`, `OBJECTION_EFFORT`
override). A `reviewers` entry with `agent: gemini` or `codex` runs that
CLI: a second model family. `usage.sh` shows what each branch cost; `usage.sh --summary`, the median per PR.

## 2. Judge: this session, never a smaller model

A wrong diagnosis returns a plausible explanation and nobody notices. So
the main session judges, by these rules:

| defense said | judge does |
|---|---|
| REFUTED | opens the citation and checks it covers **exactly** the accused case. It does not: UPHELD. |
| UPHELD | BLOCKER or HIGH: fixes it. MEDIUM or LOW: fixes it only when the fix is small and inside the PR's scope; otherwise moves it to "Open" with a reason (an issue tracks it). |
| CANNOT VERIFY | BLOCKER or HIGH: treated as UPHELD. **Tie-break by test:** write the test the accuser said would fail. Fails: UPHELD. Passes: REFUTED only with a negative control (below), and the test stays in the repository. |
| (not sent) | the judge rules on it directly, by the same standard. |

**The judge never refutes a finding alone.** Refuting requires the
defender's citation, checked, or a tie-break test with a **negative
control**: the test is shown able to fail on the accused path (it fails
when the defect is put back, in a scratch copy, or when the path it
covers is broken on purpose). A test never shown able to fail proves
nothing. The judge wrote the code: that is the bias the debate cuts.

**Do not fix every finding.** Each fix is new code, and a round on it
finds something in it: a PR whose agent made "every finding, even LOW,
becomes a fix" its rule went 8 rounds. MEDIUM and LOW ship in "Open";
that is what the section is for. Never save a rule that turns every
finding into a fix.

**Evidence decides, not eloquence.** A BLOCKER or HIGH disputed with
nothing stronger than `read` on either side is not settled: raise the
evidence (a test with a negative control, or run the path). An unsettled
BLOCKER or HIGH stays UPHELD.

In the draft, replace every `TODO(judge)` line. Every finding number
needs a ruling line in Judge that starts with it ("3.", "1, 2 and 5:",
"4-6." or a "| 3 |" row). Match section headings as whole lines when you
edit the draft: finding text can quote them. Open ends with the judge's
count and the verdict:

```
OPEN: BLOCKER=0 HIGH=0
VERDICT: APPROVED
```

`OPEN:` is the authority. APPROVED only with `BLOCKER=0 HIGH=0`.

## 3. Rounds

Fixed something: commit it on the branch. Whether another round runs is
the budget's call (table above); when it does not, run `verify`, and a
fix for a BLOCKER or HIGH comes with a test that fails before the fix and
passes after (record both). A fix for MEDIUM or LOW alone never starts a
round. A later round covers only the fix and hunts **regressions from the
fix** first: in practice they are the most common round-2 finding. Its
brief carries the findings and rulings of the branch's earlier judged
rounds, and asks the reviewers not to accuse the fix for doing what a
ruling asked. It is a request to a model, not a filter: when a finding
reverses an earlier ruling anyway, the judge rules on it like any other.

`debate.sh` enforces the cap (`maxRounds`, else 2 under `lean` and 3
otherwise): past it, it exits 4. What is still open goes into "Open" with
its severity: MEDIUM and LOW ship with the record, BLOCKER and HIGH do
not, and the human decides. Run `--extra-round` only when they ask; the
record then says it ran past the cap. It also refuses to re-run a commit
whose record is already judged (`--force` does it anyway).

## When the diff is a gate, check or validator

If the change blocks or allows something (this skill's gate, a CI check,
a permission rule, an input validator), read `reference/gate-changes.md`
before the accusation. Without it, that kind of debate does not converge.

## 4. Precedents, stamp, PR body

**Precedents** (unless `precedents` is `false`), before stamping: only
findings the judge kept (UPHELD, fixed or left open) of MEDIUM or above.

1. `node <this skill's directory>/precedents.mjs list`
2. For each kept finding: the same kind of defect already listed:
   `precedents.mjs bump <n> --sha <sha7>`; otherwise
   `precedents.mjs add --area <prefix> --pattern "<sentence>" --sha <sha7>`,
   with the narrowest directory covering it (`*` if not about a place)
   and a sentence naming the **kind** of defect, not the instance ("temp
   dir not cleaned when the job fails before finally"). No code, no
   secrets, no names of people.
3. Commit `.objection/precedents.md` (`chore(objection): update precedents`).

**Stamp** the resulting HEAD:
`bash <this skill's directory>/stamp.sh <record.md> [origin/<base>]`.
It refuses a record without the sections, with a `TODO(judge)` left,
with a dirty tree, with a base outside `bases`, or APPROVED with a
serious finding open, and stores it with a stamp line for the SHA.

**PR body:** push, then `bash <this skill's directory>/pr-body.sh` writes
the body (your summary from `OBJECTION_SUMMARY`, then the record, with
the accusation and defense folded) and prints its path for
`gh pr create --body-file <path>`. `pr-body.sh --update` replaces the
record in an open PR's body and keeps the rest. Anything left in "Open":
`bash <this skill's directory>/open-issue.sh` opens one issue with it
(once per commit; `--dry-run` shows it first). A later push changes the
SHA: debate the new commits (`debate.sh --since`) and update the body.

With `"enforce": false` (advisory mode) the hook lets the PR through and
says what it would have blocked: run the debate anyway.
