# Install and configure

## Install

**Claude Code** (skill, subagents and the gate hook in one step):

```
/plugin marketplace add victorserpa/objection
/plugin install objection@objection
```

**Any other agent that reads Agent Skills** (Codex, Cursor, Copilot,
Gemini CLI, Cline, OpenCode, ...), with the
[`skills` CLI](https://github.com/vercel-labs/skills):

```bash
npx skills add victorserpa/objection
```

or copy [`skills/objection/`](../skills/objection) into your agent's skills
directory (`.agents/skills/`, `.github/skills/`, `.claude/skills/`...).
The folder is self-contained: instructions, role prompts, stamp script,
gate and templates.

Then, in each repository you want to protect, ask your agent:

```
/objection init
```

It runs `init.sh`, which asks nothing it can read for itself: bases from
origin, `verify` from the project's own scripts, the hook for your agent,
the CI check for GitHub or GitLab. It never overwrites a file. **Nothing is enforced
in a repository without that file**, so installing the skill never blocks
work anywhere you did not opt in.

```json
{
  "bases": ["develop", "main"],
  "defaultBase": "develop",
  "verify": ["pnpm typecheck", "pnpm test"],
  "reviewers": [
    { "paths": "^apps/api/src/(auth|billing)/", "agent": "security-reviewer", "focus": "the project's security checklist" }
  ]
}
```

| key | meaning |
|---|---|
| `bases` | every branch a PR may target; a record is only valid against the base it was debated on |
| `defaultBase` | the base to debate against by default; gh does not read it, so pass `--base` (the gate checks the base gh will really use) |
| `verify` | cheap proof (types, tests) that must pass before any reviewer runs |
| `reviewers` | your own reviewers, added as accusers when the diff touches `paths` (under `standard` and `thorough`); an `agent` named `opus`, `sonnet`, `haiku` or `claude-*` runs on that model in `debate.sh`; `gemini` (or `gemini-<model>`) and `codex` run through that CLI, a second model family that makes different mistakes; any other `agent` is a label there |
| `invariants` | rules that must never break, each with the `paths` it guards; a violation is a BLOCKER. Add `"verify": "<command>"` and `debate.sh` runs it before the reviewers whenever the diff touches those paths: a failure is a BLOCKER decided by the command, not by a model |
| `budget` | `lean` (default), `standard` or `thorough`: how many reviewers and rounds a debate runs |
| `models` | `{"default": "sonnet", "strong": "opus", "effort": "medium"}` (the defaults): the reviewers' model, and the stronger one used when an invariant or `strongPaths` matches, or under `thorough`; `strongEffort` sets the strong tier's effort apart (opus at `low` found the same HIGH as at its default, for $0.13 instead of $0.33); `defender` is the defender's model (default `sonnet`, whatever the accuser runs on); `laterEffort` is the accuser's effort in later rounds, which review only the fix (default `low`) |
| `strongPaths` | a regex of paths that deserve the strong model (a gate, a validator, billing) |
| `enforce` | `false` for advisory mode: the hook reports what it would block and lets it through |
| `$schema` | `init` writes it: editors then complete and check every key against [`objection.schema.json`](../skills/objection/objection.schema.json) |
| `maxRounds` | rounds a branch may have before `debate.sh` refuses another (default 2 under `lean`, 3 otherwise); one more needs `--extra-round`, when the human asks |
| `smallDiff` | under `lean`, a diff of at most this many changed lines that no invariant or `strongPaths` touches runs no reviewer; the judge reads it alone (default 20, `0` turns it off). A migration, SQL or schema file always gets its reviewer |

**Monorepo: one config per package.** A package can keep its own rules in
`<dir>/.objection.json`, next to its code. It applies to the changed files
under `<dir>/` only, on top of the root config (which still opts the
repository in and sets everything repository-wide). It may set `verify`,
`invariants`, `reviewers` and `strongPaths`; their `paths` regexes are
matched against the path inside the package (`^src/` means `<dir>/src/`),
and their commands run from `<dir>`. Any other key there is ignored, and
`doctor.sh` says so. Package configs are read from the base branch like
the root one, so a branch cannot loosen its own package's rules, and a
package config added on a branch applies once it is merged.

```json
{ "verify": ["pnpm test"], "invariants": [{ "rule": "prices are integers in cents", "paths": "^src/billing/", "verify": "pnpm test billing" }] }
```

Requirements: `node` (Node.js 18 or later; the local scripts also run on 16, the CI check does not. Installed any way: the system package, the official installer, nvm, volta, fnm, asdf or mise; needed in a Python or Go repository too, since objection's own scripts are node and bash), `git`, `bash` and `perl`, plus the `claude` CLI or
the `codex` CLI to run the reviewers cheaply, and `gh` or `glab` for the
local gate. Linux and macOS have the first four; on Windows, Git for
Windows brings `bash` and `perl` (Git Bash, which Claude Code needs
there anyway). CI runs every test on Linux on each pull request; macOS
and Windows run only when the test workflow is started by hand
(Actions, test, Run workflow), so a change can break them unnoticed
until then. Git 2.13
or later (2017).
Minimal container images (Alpine) lack `bash` and `perl`: install them.

**Without GitHub, or without `gh`.** The debate itself (brief, reviewers,
judge, record) needs only `git` and a reviewer CLI, on any host. What
changes is enforcement:

| where the code lives | local gate | CI check |
|---|---|---|
| GitHub, with `gh` | `gh pr create/ready/merge`, `gh api`, GitHub MCP | GitHub Action |
| GitLab, with `glab` | `glab mr create/merge`, `glab api` | GitLab CI job |
| GitHub or GitLab through the web UI only | nothing to intercept | the CI check still fails the PR/MR |
| elsewhere (Bitbucket, Gitea, plain git) | none | none: the debate is advice, not a gate |

## Without subagents

The debate works best when each role runs in its own context, so the
accuser never sees why you wrote the code the way you did. Where the
agent has no subagents, the skill runs each role in a fresh session with
the role prompt from [`roles/`](../skills/objection/roles). As a last resort
it runs them in one session and says so in the record.

## Uninstall

`/plugin uninstall objection@objection` removes the skill and the
Claude Code hook. `init` also wrote files to the repository: delete
`.objection.json`, the hook entries it added (`.claude/settings.json`,
`.codex/hooks.json`, `.gemini/settings.json`, `.cursor/hooks.json`),
`.github/workflows/objection*.yml` and `.gitlab/objection.gitlab-ci.yml`,
then drop `record` and `review` from the required checks. Records live
in `.git/objection/` (local, never pushed); precedents in
`.objection/precedents.md`, which you may want to keep.
