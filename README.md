# objection

[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Objection%20PR%20Trial-red?logo=github)](https://github.com/marketplace/actions/objection-pr-trial)
[![Release](https://img.shields.io/github/v/release/victorserpa/objection)](https://github.com/victorserpa/objection/releases)
[![Tests](https://github.com/victorserpa/objection/actions/workflows/test.yml/badge.svg)](https://github.com/victorserpa/objection/actions/workflows/test.yml)

> **OBJECTION!** Your PR goes on trial before it ships.

Before your AI agent opens a pull request, a second model attacks the
diff, a third tries to refute every accusation with `file:line`, your
agent's session judges what is left, and a gate keeps the PR closed
until the verdict is APPROVED.

Works in Claude Code, Codex, Cursor, Gemini CLI, GitHub Copilot and
anything that reads [Agent Skills](https://agentskills.io). No hosted
service and no bot account: instructions and a few scripts your agent
runs, on your own `claude` or `codex` CLI.

![A real debate on a toy cart: the accuser finds a negative total and a NaN, the gate blocks gh pr create, round 2 finds one more NaN, then the record is APPROVED and the PR opens](docs/demo.svg)

That run is real (sonnet, a planted bug in a [toy cart](docs/make-demo.mjs)):
3 bugs, 2 rounds, **$0.041** of reviewers.

## What you get

- **Bugs caught before the PR exists**, by an isolated reviewer with no
  stake in the diff, not by the agent that wrote it.
- **Few false alarms**: every finding must survive a defender looking for
  the line that proves it wrong.
- **A step that cannot be skipped**: a local hook blocks `gh pr create`,
  `ready` and `merge` without an APPROVED record for that exact commit,
  and a GitHub Action (or GitLab job) checks the same in CI. Advisory
  mode warns instead of blocking.
- **Cents per PR**: $0.02 to $0.15 of reviewers on sonnet; plan usage,
  not dollars, on a Claude subscription.
- **A record in the PR body**: what was accused, refuted, fixed and left
  open, stamped to the commit.
- **Memory**: confirmed defects become precedents the next review checks
  first.

## Quick start

Claude Code:

```
/plugin marketplace add victorserpa/objection
/plugin install objection@objection
```

Other agents: `npx skills add victorserpa/objection` ([Install](docs/install.md)).

Then, in a repository:

- `/objection try`: one review of the branch, nothing set up, nothing
  written outside `.git/`.
- `/objection init`: opts the repository in (`--advisory` to warn
  instead of block). Run it on the default branch and merge its files
  first. **Nothing is enforced where there is no `.objection.json`.**
- `/objection doctor`: checks tools, config, hooks and CI, with the fix
  for each problem.

## GitHub Action

The check that fails a PR without an APPROVED record, whoever opened it.
Add `.github/workflows/objection.yml` and make `record` a required check:

```yaml
name: objection
on:
  pull_request_target:
    types: [opened, edited, synchronize, reopened, ready_for_review]
permissions:
  contents: read
  pull-requests: read
jobs:
  record:
    runs-on: ubuntu-latest
    steps:
      - uses: victorserpa/objection@v1
```

Optional: an independent accuser in CI, with a key the agent never sees
(`review: true` with `anthropic-api-key`, or `runner: gemini` with a
free-tier `gemini-api-key`); see
[`objection-review.yml`](skills/objection/templates/github/objection-review.yml).
GitLab has both as merge request jobs. Setup and threat model:
[docs/gates.md](docs/gates.md).

## Measured

[`eval/`](eval): 23 planted bugs in 11 languages, 8 changes with no bug,
and 9 real regressions from CPython, Redis, Rails, Django, Go, Vue,
ESLint and curl, five runs each on 0.20.0 ([raw output](eval/results/2026-09-25.md)):

| | planted bugs | false alarms | real bugs, right severity | all bugs caught |
|---|---|---|---|---|
| Claude sonnet | 114 of 115 | 5% | 71% | **91%** |
| Gemini CLI default | 115 of 115 | 12.5% | 76% | **93%** |

Sonnet meets both v1.0 bars (90% caught, at most 10% false alarms);
Gemini catches more but alarms more, over the 10% bar. On 15 more
real regressions (hand-graded, [results](eval/results/2026-10-01-real-bugs.md)),
sonnet found 55% and rated 42% right, **below a plain review prompt on
the same model** (62% and 55%); over all 24 real bugs the two are even. 24 real bugs
are a small sample, and no number here says it catches everything. Scoring, every case and the history: [docs/eval.md](docs/eval.md).

## How it works

```
  your diff ─▶ ACCUSATION  accusers: every finding needs file:line and a proof
                  ▼
               DEFENSE     a defender tries to refute each one with code
                  ▼
               JUDGE       your session rules; a tie goes to a test
                  ▼
               RECORD      stamped to the commit, put in the PR body
                  ▼
  PR create / ready / merge: blocked until the record says APPROVED
```

Unlike a review command that hands you a list, it adds a defender (fewer
false positives, none dismissed without evidence), a gate (a review that
can be skipped gets skipped), and precedents. Keep your review command;
let objection be the step that cannot be skipped. No finding quotas: the
accusers say what they could *not* evaluate instead.

Monorepos can keep one config per package; see
[docs/install.md](docs/install.md) for every key.

## Honest limits

- A **process guard, not a security boundary**: an agent set on cheating
  can write a fake record locally. The CI review, with a key the agent
  cannot reach, is the answer to that.
- The hook reads commands with patterns, not a shell parser: it stops an
  agent that forgets the debate, not one that disguises the command. The
  CI check covers those.
- A diff over 800 lines is reported before anything is spent, with a
  suggestion to split it.

More, with measurements and when it is not worth it:
[docs/limits.md](docs/limits.md).

## Docs

| | |
|---|---|
| [docs/install.md](docs/install.md) | install, every config key, monorepos, without GitHub, uninstall |
| [docs/gates.md](docs/gates.md) | the local hook, the GitHub/GitLab check, the CI review |
| [docs/record.md](docs/record.md) | what a record looks like, precedents |
| [docs/eval.md](docs/eval.md) | the eval: cases, scoring, results |
| [docs/limits.md](docs/limits.md) | limits, costs, when it is worth it, how it compares |
| [docs/layout.md](docs/layout.md) | where everything lives in this repository |
| [CHANGELOG.md](CHANGELOG.md) | every release; pin `@v0.23.2` or a SHA instead of `@v1` to stay on one |

## License

MIT
