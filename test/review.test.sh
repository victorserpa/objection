#!/bin/bash
# Cases for skills/objection/review.sh with a fake `claude` that records its
# arguments and stdin, so no model is called.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVIEW="$ROOT/skills/objection/review.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
gitc() { git -c user.email=t@t -c user.name=t "$@"; }
failures=0
has() { grep -qF -- "$2" "$1" || { echo "FAIL: $1 lacks [$2]"; failures=$((failures + 1)); }; }
hasnt() { grep -qF -- "$2" "$1" && { echo "FAIL: $1 has [$2]"; failures=$((failures + 1)); }; }

cat >"$T/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$FAKE_DIR/args"
printf '%s\n' "${DISABLE_PROMPT_CACHING:-unset}" >"$FAKE_DIR/cache"
pwd >"$FAKE_DIR/cwd"
cat >"$FAKE_DIR/stdin"
printf '{"result":"| severity | kind |","usage":{"input_tokens":2,"cache_creation_input_tokens":10000,"output_tokens":300},"total_cost_usd":0.1,"modelUsage":{"claude-haiku-x":{"outputTokens":5},"claude-sonnet-x":{"outputTokens":295}}}\n'
EOF
chmod +x "$T/claude"
export OBJECTION_CLAUDE="$T/claude" FAKE_DIR="$T"

R="$T/repo"
git init -q "$R" && cd "$R" || exit 1
printf 'root rules\n' >CLAUDE.md
mkdir -p src && seq 1 200 | sed 's/^/code line /' >src/a.ts
mkdir -p 'app/[locale]' @types && printf 'layout line %s\n' 1 2 3 4 5 6 >'app/[locale]/layout.tsx' && seq 1 100 | sed 's/^/type line /' >@types/user.ts
git add . && gitc commit -q -m base
printf '# brief\nthe diff\n' >"$T/brief.md"

# Accuser: isolated flags, role as system prompt, brief on stdin, empty cwd.
out=$(bash "$REVIEW" accuser "$T/brief.md" 2>"$T/err")
[ "$out" = "| severity | kind |" ] || { echo "FAIL: result not printed ($out)"; failures=$((failures + 1)); }
has "$T/args" "--tools"
has "$T/args" "--strict-mcp-config"
has "$T/args" '{"mcpServers":{}}'
has "$T/args" "--disable-slash-commands"
has "$T/args" "--setting-sources"
has "$T/args" "--no-session-persistence"
has "$T/args" "$ROOT/skills/objection/roles/accuser.md"
has "$T/args" "You have NO tools"
has "$T/stdin" "the diff"
# One-shot runs never read their cache back: no cache write (measured
# -32% per run); OBJECTION_PROMPT_CACHE=1 keeps it.
[ "$(cat "$T/cache")" = 1 ] || { echo "FAIL: the prompt cache was not turned off"; failures=$((failures + 1)); }
OBJECTION_PROMPT_CACHE=1 bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>&1
[ "$(cat "$T/cache")" = unset ] || { echo "FAIL: OBJECTION_PROMPT_CACHE=1 did not keep the cache"; failures=$((failures + 1)); }
bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>"$T/err"
has "$T/err" "accuser used 10002 input + 300 output tokens"
# The model that answered, not the alias: the one with the most output.
has "$T/err" "objection: model claude-sonnet-x"
grep -q "	accuser	claude-sonnet-x	" "$R/.git/objection/usage.log" || { echo "FAIL: the usage log does not name the model that answered"; failures=$((failures + 1)); }
# The empty tools value must reach claude as an empty argument.
awk 'prev=="--tools" && $0!="" {bad=1} {prev=$0} END{exit bad}' "$T/args" || { echo "FAIL: --tools was not empty"; failures=$((failures + 1)); }
# No CLAUDE.md where it runs.
[ ! -e "$(cat "$T/cwd")/CLAUDE.md" ] || { echo "FAIL: ran next to a CLAUDE.md"; failures=$((failures + 1)); }
[ "$(cat "$T/cwd")" != "$R" ] || { echo "FAIL: ran in the repository"; failures=$((failures + 1)); }

# Defender: findings plus excerpts of the cited lines, from HEAD.
printf '| 1 | HIGH | BUG | src/a.ts:100 | x | read | y |\n| 2 | LOW | BUG | missing/file.ts:3 | x | read | y |\n' >"$T/findings.md"
bash "$REVIEW" defender "$T/brief.md" "$T/findings.md" >/dev/null 2>&1
has "$T/args" "$ROOT/skills/objection/roles/defender.md"
has "$T/stdin" "# Findings to answer"
has "$T/stdin" "src/a.ts:100"
has "$T/stdin" "## src/a.ts (lines 60-140)"
has "$T/stdin" "  100  code line 100"
hasnt "$T/stdin" "code line 141"
hasnt "$T/stdin" "## missing/file.ts"
# Names with [ ] and @ (Next.js routes, @types), prose around a name, and a
# file named without a line, read from its top.
printf '| 1 | HIGH | BUG | app/[locale]/layout.tsx:5 | x, see (src/a.ts:150) | read | inspect @types/user.ts |\n' >"$T/findings2.md"
rm -f "$T/stdin"
bash "$REVIEW" defender "$T/brief.md" "$T/findings2.md" >/dev/null 2>&1
has "$T/stdin" "## app/[locale]/layout.tsx (lines 1-45)"
has "$T/stdin" "    5  layout line 5"
has "$T/stdin" "## src/a.ts (lines 110-190)"
has "$T/stdin" "## @types/user.ts (lines 1-80)"
hasnt "$T/stdin" "type line 81"
# A dirty working copy does not leak: excerpts come from HEAD. The recorded
# stdin is removed first, so the case cannot pass on the previous run.
printf 'UNCOMMITTED\n' >>src/a.ts
rm -f "$T/stdin"
bash "$REVIEW" defender "$T/brief.md" "$T/findings.md" >/dev/null 2>&1
has "$T/stdin" "## src/a.ts (lines 60-140)"
hasnt "$T/stdin" "UNCOMMITTED"
git checkout -q src/a.ts
# Cited code past the cap is cut with a notice.
rm -f "$T/stdin"
OBJECTION_EXCERPT_MAX=10 bash "$REVIEW" defender "$T/brief.md" "$T/findings.md" >/dev/null 2>&1
has "$T/stdin" "TRUNCATED: the cited code"
# The accuser runs outside a git repository (it needs none).
rm -f "$T/stdin"
(cd "$T" && bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>&1) || { echo "FAIL: accuser needs a git repository"; failures=$((failures + 1)); }
has "$T/stdin" "the diff"
# A failing or hung claude: exit 1, and whatever came back is shown.
cat >"$T/claude-fail" <<'EOF'
#!/bin/bash
cat >/dev/null
echo "PARTIAL ANSWER"
echo "auth error" >&2
exit 7
EOF
chmod +x "$T/claude-fail"
OBJECTION_CLAUDE="$T/claude-fail" bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>"$T/err"
[ $? = 1 ] || { echo "FAIL: a failing claude did not exit 1"; failures=$((failures + 1)); }
has "$T/err" "PARTIAL ANSWER"
has "$T/err" "auth error"
# Exit 0 but not JSON (a banner): shown, exit 1, not a stack trace.
printf '#!/bin/bash\ncat >/dev/null\necho "UPDATE BANNER"\n' >"$T/claude-banner" && chmod +x "$T/claude-banner"
OBJECTION_CLAUDE="$T/claude-banner" bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>"$T/err"
[ $? = 1 ] || { echo "FAIL: non-JSON output did not exit 1"; failures=$((failures + 1)); }
has "$T/err" "UPDATE BANNER"
hasnt "$T/err" "SyntaxError"
printf '#!/bin/bash\nsleep 30\n' >"$T/claude-hang" && chmod +x "$T/claude-hang"
start=$(date +%s)
OBJECTION_TIMEOUT=2 OBJECTION_CLAUDE="$T/claude-hang" bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>&1
rc=$?
[ "$rc" = 1 ] && [ $(( $(date +%s) - start )) -lt 15 ] || { echo "FAIL: a hung claude was not stopped (rc=$rc)"; failures=$((failures + 1)); }

# The timeout ends the whole process group: a child of a hung claude
# (a subprocess, a tool) must not survive it.
cat >"$T/claude-kids" <<'EOF2'
#!/bin/bash
cat >/dev/null
sleep 60 &
echo $! >"$FAKE_DIR/child"
wait
EOF2
chmod +x "$T/claude-kids"
rm -f "$T/child"
OBJECTION_TIMEOUT=2 OBJECTION_CLAUDE="$T/claude-kids" bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>&1
sleep 1
if [ -s "$T/child" ] && kill -0 "$(cat "$T/child")" 2>/dev/null; then
  echo "FAIL: a child of the timed-out claude is still running"; failures=$((failures + 1))
  kill "$(cat "$T/child")" 2>/dev/null
fi
[ -s "$T/child" ] || { echo "FAIL: the child-spawning stub never ran"; failures=$((failures + 1)); }

# A focus (one reviewers entry) goes into the prompt; roles can come from
# another directory (debate.sh passes the base branch's roles).
OBJECTION_FOCUS="money math only" bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>&1
has "$T/args" "money math only"
mkdir -p "$T/roles" && printf 'BASE ROLE\n' >"$T/roles/accuser.md"
OBJECTION_ROLES_DIR="$T/roles" bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>&1
has "$T/args" "$T/roles/accuser.md"
bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>&1
hasnt "$T/args" "money math only"

# Refusals: unknown role, missing files, no claude CLI (exit 3).
bash "$REVIEW" judge "$T/brief.md" >/dev/null 2>&1 && { echo "FAIL: unknown role accepted"; failures=$((failures + 1)); }
bash "$REVIEW" defender "$T/brief.md" >/dev/null 2>&1 && { echo "FAIL: defender without findings accepted"; failures=$((failures + 1)); }
OBJECTION_CLAUDE=/nonexistent/claude OBJECTION_CODEX=/nonexistent/codex bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>&1
[ $? = 3 ] || { echo "FAIL: missing claude and codex did not exit 3"; failures=$((failures + 1)); }

# Codex runner (flags from its docs; this stub checks what reaches it):
# chosen when claude is missing, read-only, the role as instructions, no
# AGENTS.md, prompt and brief on stdin, answer from -o, usage from --json.
cat >"$T/codex" <<'EOF2'
#!/bin/bash
printf '%s\n' "$@" >"$FAKE_DIR/codex-args"
cat >"$FAKE_DIR/codex-stdin"
[ -n "${CODEX_RAN:-}" ] && ran='{"type":"item.completed","item":{"type":"command_execution"}}' || ran=""
last=""
prev=""
for a in "$@"; do [ "$prev" = -o ] && last="$a"; prev="$a"; done
printf '| HIGH | BUG | a.ts:1 | codex finding | read | p |\n' >"$last"
[ -n "$ran" ] && printf '{"type":"command_execution"}\n'
printf '{"type":"thread.started"}\n{"type":"turn.completed","usage":{"input_tokens":1234,"cached_input_tokens":0,"output_tokens":56}}\n'
EOF2
chmod +x "$T/codex"
out=$(OBJECTION_CLAUDE=/nonexistent/claude OBJECTION_CODEX="$T/codex" bash "$REVIEW" accuser "$T/brief.md" 2>"$T/err")
[ "$out" = "| HIGH | BUG | a.ts:1 | codex finding | read | p |" ] || { echo "FAIL: codex answer not printed ($out)"; failures=$((failures + 1)); }
has "$T/codex-args" "exec"
has "$T/codex-args" "read-only"
has "$T/codex-args" "--skip-git-repo-check"
has "$T/codex-args" "model_instructions_file=\"$ROOT/skills/objection/roles/accuser.md\""
# Its tools off, the user's config out, no environment for commands; a
# tool item in the stream fails the review.
for a in shell_tool unified_exec plugins hooks --ignore-user-config --ephemeral 'shell_environment_policy.inherit="none"' 'web_search="disabled"'; do has "$T/codex-args" "$a"; done
CODEX_RAN=1 OBJECTION_RUNNER=codex OBJECTION_CODEX="$T/codex" bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>&1 && { echo "FAIL: a codex tool call passed"; failures=$((failures + 1)); }
has "$T/codex-args" "project_doc_max_bytes=0"
has "$T/codex-args" 'model_reasoning_effort="medium"'
has "$T/codex-stdin" "Do not run commands or open files."
has "$T/codex-stdin" "the diff"
has "$T/err" "accuser used 1234 input + 56 output tokens (codex)"
tail -n 1 "$(git -C "$R" rev-parse --git-common-dir | sed "s|^\.git|$R/.git|")/objection/usage.log" | grep -q "codex:default" || { echo "FAIL: codex run not logged"; failures=$((failures + 1)); }
# Forced by OBJECTION_RUNNER even with claude present; unknown runner refused.
OBJECTION_RUNNER=codex OBJECTION_CODEX="$T/codex" bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>&1 || { echo "FAIL: OBJECTION_RUNNER=codex refused"; failures=$((failures + 1)); }
OBJECTION_RUNNER=gpt bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>&1 && { echo "FAIL: unknown runner accepted"; failures=$((failures + 1)); }
# Gemini: only when asked for; the role as GEMINI_SYSTEM_MD, read-only,
# no extensions, no project trust; answer and usage from its JSON.
cat >"$T/gemini" <<'EOF2'
#!/bin/bash
printf '%s\n' "$@" >"$FAKE_DIR/gemini-args"
printf '%s\n' "$GEMINI_SYSTEM_MD" >"$FAKE_DIR/gemini-system"
cat >"$FAKE_DIR/gemini-stdin"
prev=""; for a in "$@"; do [ "$prev" = --admin-policy ] && cp "$a" "$FAKE_DIR/gemini-policy"; prev="$a"; done
[ -n "${GEMINI_POLICY_ERR:-}" ] && echo "[ADMIN] Policy file error in deny.toml:" >&2
[ -n "${GEMINI_TOOL_RAN:-}" ] && { printf '{"response":"| LOW | BUG | a.ts:1 | x | read | p |","stats":{"models":{},"tools":{"totalCalls":1,"totalSuccess":1}}}\n'; exit 0; }
[ -n "${GEMINI_FAIL:-}" ] && { echo '{"error":{"message":"quota"}}'; exit 1; }
[ -n "${GEMINI_ANSWER:-}" ] && { node -e 'process.stdout.write(JSON.stringify({response: process.env.GEMINI_ANSWER, stats: {models: {}}}))'; exit 0; }
printf '{"response":"| HIGH | BUG | a.ts:1 | gemini finding | read | p |","stats":{"models":{"gemini-x":{"tokens":{"prompt":4000,"candidates":100,"thoughts":50}}}}}\n'
EOF2
chmod +x "$T/gemini"
out=$(OBJECTION_RUNNER=gemini OBJECTION_GEMINI="$T/gemini" bash "$REVIEW" accuser "$T/brief.md" 2>"$T/err")
[ "$out" = "| HIGH | BUG | a.ts:1 | gemini finding | read | p |" ] || { echo "FAIL: gemini answer not printed ($out)"; failures=$((failures + 1)); }
for a in "--approval-mode" "plan" "-o" "json" "-e" "none" "--skip-trust"; do grep -qxF -- "$a" "$T/gemini-args" || { echo "FAIL: gemini lacks $a"; failures=$((failures + 1)); }; done
has "$T/gemini-system" "$ROOT/skills/objection/roles/accuser.md"
# Every tool denied by an admin policy; a policy not loaded, or a tool
# that ran anyway, fails the review.
has "$T/gemini-policy" 'toolName = "*"'
has "$T/gemini-policy" 'decision = "deny"'
GEMINI_POLICY_ERR=1 OBJECTION_RUNNER=gemini OBJECTION_GEMINI="$T/gemini" bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>&1 && { echo "FAIL: a policy Gemini could not load passed"; failures=$((failures + 1)); }
GEMINI_TOOL_RAN=1 OBJECTION_RUNNER=gemini OBJECTION_GEMINI="$T/gemini" bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>&1 && { echo "FAIL: a Gemini tool call passed"; failures=$((failures + 1)); }
has "$T/gemini-stdin" "the diff"
has "$T/err" "accuser used 4000 input + 150 output tokens (gemini)"
tail -n 1 "$(git -C "$R" rev-parse --git-common-dir | sed "s|^\.git|$R/.git|")/objection/usage.log" | grep -q "gemini:default" || { echo "FAIL: gemini run not logged"; failures=$((failures + 1)); }
GEMINI_FAIL=1 OBJECTION_RUNNER=gemini OBJECTION_GEMINI="$T/gemini" bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>&1
[ $? = 1 ] || { echo "FAIL: a failing gemini did not exit 1"; failures=$((failures + 1)); }
# A table written without its outer pipes gets them, so the readers that
# count rows starting with "|" see its BLOCKER; prose with a pipe does not.
bare='severity | kind | file:line | defect
--- | --- | --- | ---
BLOCKER | BUG | a.ts:6 | injection |

A | B in prose stays.'
out=$(GEMINI_ANSWER="$bare" OBJECTION_RUNNER=gemini OBJECTION_GEMINI="$T/gemini" bash "$REVIEW" accuser "$T/brief.md" 2>/dev/null)
printf '%s\n' "$out" | grep -qxF '| BLOCKER | BUG | a.ts:6 | injection |' || { echo "FAIL: a pipe-less row was not given its pipes ($out)"; failures=$((failures + 1)); }
printf '%s\n' "$out" | grep -qxF '| --- | --- | --- | --- |' || { echo "FAIL: the delimiter row was not given its pipes"; failures=$((failures + 1)); }
printf '%s\n' "$out" | grep -qxF 'A | B in prose stays.' || { echo "FAIL: prose with a pipe was changed"; failures=$((failures + 1)); }
# A delimiter with a leading pipe and bare rows; prose with a pipe right
# above the header stays prose.
mixed='Findings for module a | b:
severity | kind
| --- | --- |
BLOCKER | a.ts:6'
out=$(GEMINI_ANSWER="$mixed" OBJECTION_RUNNER=gemini OBJECTION_GEMINI="$T/gemini" bash "$REVIEW" accuser "$T/brief.md" 2>/dev/null)
printf '%s\n' "$out" | grep -qxF '| BLOCKER | a.ts:6 |' || { echo "FAIL: a bare row under a piped delimiter kept no pipes ($out)"; failures=$((failures + 1)); }
printf '%s\n' "$out" | grep -qxF 'Findings for module a | b:' || { echo "FAIL: prose above the header was rewritten ($out)"; failures=$((failures + 1)); }
# Rows with no header and no pipes around them still count as rows.
lone='Found one:

BLOCKER | BUG | a.ts:6 | pickle.loads on a cookie | read | p

LOW-hanging fruit | not a row'
out=$(GEMINI_ANSWER="$lone" OBJECTION_RUNNER=gemini OBJECTION_GEMINI="$T/gemini" bash "$REVIEW" accuser "$T/brief.md" 2>/dev/null)
printf '%s\n' "$out" | grep -qxF '| BLOCKER | BUG | a.ts:6 | pickle.loads on a cookie | read | p |' || { echo "FAIL: a lone pipe-less BLOCKER row was not given its pipes ($out)"; failures=$((failures + 1)); }
printf '%s\n' "$out" | grep -qxF 'LOW-hanging fruit | not a row' || { echo "FAIL: prose starting with a severity-like word was rewritten ($out)"; failures=$((failures + 1)); }
# Never picked on its own: without claude and codex, exit 3 even with gemini.
OBJECTION_CLAUDE=/nonexistent/claude OBJECTION_CODEX=/nonexistent/codex OBJECTION_GEMINI="$T/gemini" bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>&1
[ $? = 3 ] || { echo "FAIL: gemini was picked without being asked for"; failures=$((failures + 1)); }
# A codex that fails: exit 1, output shown.
printf '#!/bin/bash\ncat >/dev/null\necho "codex auth error" >&2\nexit 1\n' >"$T/codex-fail" && chmod +x "$T/codex-fail"
OBJECTION_RUNNER=codex OBJECTION_CODEX="$T/codex-fail" bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>"$T/err"
[ $? = 1 ] || { echo "FAIL: failing codex did not exit 1"; failures=$((failures + 1)); }
has "$T/err" "codex auth error"
# Picked only because claude is missing, a failing codex (not logged in,
# a flag it rejects) is exit 3: the caller falls back to subagents.
OBJECTION_CLAUDE=/nonexistent/claude OBJECTION_CODEX="$T/codex-fail" bash "$REVIEW" accuser "$T/brief.md" >/dev/null 2>"$T/err"
[ $? = 3 ] || { echo "FAIL: an auto-picked failing codex did not exit 3"; failures=$((failures + 1)); }

if [ "$failures" = 0 ]; then echo "review: all cases passed"; else echo "review: $failures failure(s)"; exit 1; fi
