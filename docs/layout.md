# Repository layout

## Layout

```
skills/objection/            the skill, self-contained
  SKILL.md                   the procedure
  roles/accuser.md           prosecution
  roles/defender.md          defense
  reference/                 init and gate-change rules, read only when needed
  stamp.sh                   validates and stores the record
  brief.sh                   the one context file every reviewer of a round reads
  review.sh                  runs a reviewer as an isolated claude -p process
  debate.sh                  runs a round up to the judge, writes the draft record
  ci-review.sh               the accuser in CI, for the Action's review input
  init.sh                    opts a repository in without questions
  doctor.sh                  checks the setup, one line per item, with the fix
  objection.schema.json      the config's keys, for editors and doctor.sh
  pr-body.sh                 puts the stored record into the PR body
  gate/rulings.mjs           every numbered finding needs a ruling (stamp and CI)
  VERSION                    the version every draft record names
  usage.sh                   what the reviewers cost, per branch
  precedents.mjs             keeps .objection/precedents.md
  gate/core.mjs              gate logic, tool-neutral
  gate/hook.mjs              local hook for Claude Code, Codex, Gemini CLI, Cursor
  open-issue.sh              one issue for what a record left open
  newer-copy.sh              warns when an old cached copy runs next to a newer one
  gate/hook.sh               runs hook.mjs; blocks a PR command when node cannot run
  gate/check-pr.mjs          GitHub check
  templates/                 hook configs per tool + the GitHub and GitLab CI files
agents/                      Claude Code subagents (same prompts as roles/)
.claude-plugin/, hooks/      Claude Code plugin and marketplace
action.yml                   the GitHub Action
test/                        regression cases
eval/                        known bugs the reviewers must catch (run by hand)
```

Contributing: see [AGENTS.md](../AGENTS.md).
