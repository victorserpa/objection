// Tool-neutral core of the objection gate. Adapters (Claude Code, Cursor,
// Codex, Gemini CLI...) translate their hook input into
//   { kind: "shell", command, cwd }   or   { kind: "tool", tool, cwd }
// and translate the result back: { blocked: false } or
// { blocked: true, reason, hint }.
//
// It blocks creating, marking ready, and merging a pull request unless an
// APPROVED /objection record exists for the exact commit going into the PR,
// plus the shortcuts that would skip the record: `gh api` writing to
// /pulls, GraphQL PR mutations, auto-merge, and tools that create or merge
// PRs. Opt-in per repository: nothing is enforced without `.objection.json`
// (or `.claude/objection.json`) at the repository root.
//
// The record is per commit, not per branch. It lives at
// `<git-common-dir>/objection/<sha>.md` and is only valid for that SHA: a
// new commit after the debate invalidates it. `ready` and `merge` check the
// PR head SHA on GitHub, not the local copy.
//
// This code went through two rounds of its own debate before release. The
// first round broke the original bash version with 12 bypasses (a record
// ending in REJECTED that quoted "APPROVED" passed; `gh -R x pr create`,
// `gh pr new`, `x=$(gh pr create)`, auto-merge...). The second round, with
// the defender, found 10 more (multi-line GraphQL, a hung `gh`, `gh pr -R`,
// a shell reading stdin, disguised command names, ambiguous directories,
// xargs, tool names, arbitrary stamp base, hand-written records). Every one
// of them is a case in test/gate.test.sh.
//
// Threat model, in one sentence: this gate stops an agent that FORGETS the
// debate (the natural ways of writing the command), not one that DISGUISES
// the command on purpose (assembled from pieces, hidden in an alias, a
// file, a variable or another language). Disguise already breaks the
// skill's rule, and the GitHub check with a required status check is the
// gate that does not read commands. So a natural form that passes, or an
// innocent command that gets blocked, is HIGH; a form that only exists to
// evade is LOW. The first adopter debated this gate for six rounds before
// that sentence existed, mostly chasing regressions of its own fixes.
//
// Which text each rule reads (decided here, once):
//   command   raw input, with disguised `gh` names normalized. GraphQL
//             mutations are looked for here, heredocs included, because a
//             multi-line query is the normal way to write one.
//   noDocs    command without heredoc bodies (unless a shell reads stdin).
//             `gh api` REST writes and `cd` paths are read here.
//   active    noDocs with inert quoted text replaced by ''. Quoted values
//             glued to -R/-B/-H (or --repo=/--base=/--head=) become plain
//             values; any other glued value becomes a glued ''. Arguments
//             of -c/-lc (shells, python, su...), -e (node, perl, ruby) and
//             eval are kept as code (allowlist).
//             `gh pr <action>` detection and positions are measured here.
//
// Fails closed when the command is about a PR: if it cannot verify (gh
// offline, PR not found), it blocks and says why. A human bypasses it by
// running the command in their own terminal; the gate only binds the agent.

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";

export const HINT =
  "Run /objection until the record says APPROVED for this commit. A human can bypass this by running the command in their own terminal.";

class Blocked extends Error {
  constructor(reason, withHint) {
    super(reason);
    this.reason = reason;
    this.withHint = withHint;
  }
}

function block(reason, withHint = true) {
  throw new Blocked(reason, withHint);
}

const ALLOW = { blocked: false };

// On Windows the shell commands come from Git Bash, so their paths look
// like /c/Users/x or /tmp/x, which node would read as C:\c\Users\x.
// cygpath (shipped with Git Bash) knows the mapping; /<drive>/ is the
// fallback when it is not on PATH.
// Cached: a long chain of cd targets must not spawn cygpath per segment.
const nativeCache = new Map();
export function nativePath(p) {
  if (process.platform !== "win32" || !p || !p.startsWith("/")) return p;
  if (nativeCache.has(p)) return nativeCache.get(p);
  // The fallback is cached too: the hook is one process per command, so a
  // cygpath that failed is not asked again for the same command.
  let out = "";
  try {
    out = execFileSync("cygpath", ["-w", p], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 5000 }).trim();
  } catch {}
  if (!out) {
    const m = /^\/([a-zA-Z])(\/.*)?$/.exec(p);
    out = m ? `${m[1].toUpperCase()}:${m[2] || "/"}` : p;
  }
  nativeCache.set(p, out);
  return out;
}

// The gh CLI. OBJECTION_GH (a JSON array, e.g. ["bash","/path/stub"]) is
// for tests on Windows, where node cannot run a bash script named gh.
const GH = (() => {
  try {
    const v = JSON.parse(process.env.OBJECTION_GH || "null");
    return Array.isArray(v) && v.length && v.every((x) => typeof x === "string") ? v : ["gh"];
  } catch {
    return ["gh"];
  }
})();
function gh(args, opts) {
  return execFileSync(GH[0], [...GH.slice(1), ...args], opts);
}
// The GitLab CLI; OBJECTION_GLAB is its test override, like OBJECTION_GH.
const GLAB = (() => {
  try {
    const v = JSON.parse(process.env.OBJECTION_GLAB || "null");
    return Array.isArray(v) && v.length && v.every((x) => typeof x === "string") ? v : ["glab"];
  } catch {
    return ["glab"];
  }
})();
function glab(args, opts) {
  return execFileSync(GLAB[0], [...GLAB.slice(1), ...args], opts);
}

export function gate(input) {
  // "enforce": false in the config (advisory mode): the debate still runs,
  // and what would block is reported instead. Only a literal false counts;
  // anything else (a string, a typo) keeps the gate on.
  let advisory = false;
  try {
    function git(dir, ...args) {
      // Timeout: without it a hung git/gh pushes the hook past the harness
      // limit, which treats the overrun as a non-blocking error (fail-open).
      // Callers turn the throw into a block.
      return execFileSync("git", ["-C", dir, ...args], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
        timeout: 10000,
      }).trim();
    }

    // --- Opt-in ------------------------------------------------------------------
    const inputCwd = nativePath(input.cwd);
    const sessionDir = inputCwd && existsSync(inputCwd) ? inputCwd : process.cwd();

    function loadConfig(dir) {
      let top;
      try {
        top = git(dir, "rev-parse", "--show-toplevel");
      } catch {
        return null;
      }
      // Tool-neutral location first; .claude/ kept for Claude Code users.
      const file = [join(top, ".objection.json"), join(top, ".claude", "objection.json")].find(existsSync);
      if (!file) return null;
      try {
        return JSON.parse(readFileSync(file, "utf8"));
      } catch {
        block(`${file} is not valid JSON.`, false);
      }
    }

    // Opt-in is decided per command, in the directory gh runs in (below):
    // a session opened in a parent folder, with `cd repo && gh pr merge`,
    // used to skip the gate because the parent has no config.

    // The base `gh pr create` uses without --base: the branch's
    // gh-merge-base setting, else the repository's default branch as GitHub
    // reports it. .objection.json's defaultBase is only a recommendation for
    // the debate; gh never reads it. Throws when it cannot tell (fail closed).
    function ghBase(dir, repo, head) {
      let branch = head;
      if (!branch) {
        try {
          branch = git(dir, "symbolic-ref", "--short", "HEAD");
        } catch {
          branch = null;
        }
      }
      if (branch) {
        try {
          const configured = git(dir, "config", `branch.${branch}.gh-merge-base`);
          if (configured) return configured;
        } catch {
          // not set
        }
      }
      const args = ["repo", "view"];
      if (repo) args.push(repo);
      args.push("--json", "defaultBranchRef", "-q", ".defaultBranchRef.name");
      const name = gh(args, {
        cwd: dir,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
        timeout: 15000,
      }).trim();
      if (!name) throw new Error("gh returned no default branch");
      return name;
    }

    // The git remote that holds the PR's head branch: for `owner:branch`,
    // the remote whose URL is under that owner; otherwise the one matching
    // -R, the branch's upstream, `origin`, or the only remote. null when it
    // cannot tell (the caller blocks with a message).
    function remoteFor(dir, branch, repo, owner) {
      const remotes = git(dir, "remote").split("\n").filter(Boolean);
      const url = (r) => {
        try {
          return git(dir, "remote", "get-url", r);
        } catch {
          return "";
        }
      };
      const esc = (x) => x.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      if (owner) {
        // gh opens the PR from <owner>/<the repository's name>, so match that
        // name too (round 2: two remotes under one owner picked the first in
        // alphabetical order). The name comes from -R, else from origin.
        const name = (repo || url("origin").replace(/\.git\/?$/, ""))
          .replace(/\/+$/, "")
          .split(/[/:]/)
          .pop();
        // Only remotes on the host gh talks to (github.com, or GH_HOST for
        // Enterprise); a local path has no host and counts. A mirror of
        // owner/repo elsewhere made the match ambiguous and blocked.
        const ghHost = (process.env.GH_HOST || "github.com").toLowerCase();
        const hostOf = (u) => {
          const m = /^[a-z][a-z0-9+.-]*:\/\/(?:[^@/]*@)?([^/:]+)/i.exec(u) || /^(?:[^@/]+@)?([^/:]+):(?!\/\/)/.exec(u);
          // "C:/x" is a Windows drive, not a host.
          return m && !/^[a-zA-Z]$/.test(m[1]) ? m[1].toLowerCase() : null;
        };
        // Kept: no host (a path), GitHub itself, and SSH aliases that the
        // SSH config maps to it (Host github-work / HostName github.com),
        // resolved with `ssh -G`, which does not connect (a `Match exec` in
        // the user's own config still runs, as it does on every git push).
        // Dropped: any other host. When ssh cannot answer, or the host
        // would reach ssh as an option ("-o..."), the remote is kept: the
        // match turns ambiguous and blocks (fail closed). Only remotes
        // that already match owner/name reach ssh. OBJECTION_SSH_CONFIG is
        // an ssh config file for tests.
        const isGh = (h) => h === ghHost || (ghHost === "github.com" && h === "ssh.github.com");
        const viaSsh = (u) => /^ssh:\/\//i.test(u) || !/^[a-z][a-z0-9+.-]*:\/\//i.test(u);
        const sshName = (h) => {
          if (h.startsWith("-")) return ghHost;
          try {
            const cfg = process.env.OBJECTION_SSH_CONFIG ? ["-F", process.env.OBJECTION_SSH_CONFIG] : [];
            const out = execFileSync("ssh", [...cfg, "-G", h], {
              encoding: "utf8",
              stdio: ["ignore", "pipe", "ignore"],
              timeout: 5000,
            });
            const m = /^hostname\s+(\S+)/m.exec(out);
            return m ? m[1].toLowerCase() : ghHost;
          } catch {
            return ghHost;
          }
        };
        const onGh = (u) => {
          const h = hostOf(u);
          return h === null || isGh(h) || (viaSsh(u) && isGh(sshName(h)));
        };
        const under = remotes.filter((r) => new RegExp(`[:/]${esc(owner)}/`, "i").test(url(r)) && onGh(url(r)));
        const exact = name
          ? under.filter((r) => new RegExp(`[:/]${esc(owner)}/${esc(name)}(\\.git)?/?$`, "i").test(url(r)))
          : [];
        if (exact.length === 1) return exact[0];
        return !name && under.length === 1 ? under[0] : null;
      }
      if (repo) {
        const slug = repo.replace(/^https?:\/\/github\.com\//, "").replace(/\.git$/, "");
        const r = remotes.find((x) => new RegExp(`[:/]${esc(slug)}(\\.git)?/?$`, "i").test(url(x)));
        if (r) return r;
      }
      try {
        const upstream = git(dir, "config", `branch.${branch}.remote`);
        if (remotes.includes(upstream)) return upstream;
      } catch {
        // no upstream
      }
      if (remotes.includes("origin")) return "origin";
      return remotes.length === 1 ? remotes[0] : null;
    }

    const tool = input.tool || "";

    // --- MCP PR tools ------------------------------------------------------------
    // They do not go through `gh`, so there is no SHA to check: send them to the
    // path that checks.
    if (input.kind === "tool") {
      // No command, so no directory of its own: the session's decides.
      const sessionCfg = loadConfig(sessionDir);
      if (!sessionCfg) return ALLOW;
      advisory = sessionCfg.enforce === false;
      if (
        /(create|merge|update)_pull_request(?!_review)|pull_request_branch|auto_merge|mark.*ready|(create|merge|ready)_pr(?![a-z0-9])(?!_comment|_review)/i.test(
          tool,
        )
      )
        block(
          `${tool} creates, changes or merges a PR without a debate record. Use gh pr create / gh pr ready / gh pr merge after /objection.`,
          false,
        );
      return ALLOW;
    }

    const rawCommand = input.command || "";
    // Disguised command name (`\gh`, `g\h`, `"gh"`, `'gh'`): to the shell it is
    // the same `gh`.
    const command = rawCommand
      .replace(/\\([A-Za-z])/g, "$1")
      .replace(/(["'])(gh|glab)\1(?=\s)/g, "$2");
    if (!/\b(gh|glab)\b/.test(command)) return ALLOW;

    // --- Text that is not a command --------------------------------------------
    // Heredoc bodies and quoted strings (commit messages, grep patterns, echo)
    // do not run `gh`. But `bash -c '...'`, `eval "..."` and strings with
    // `$(`/backticks do, so those stay.
    function stripHeredocs(s) {
      return s.replace(
        /<<-?[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n[\s\S]*?\n[ \t]*\2[ \t]*(?=\n|$|\))/g,
        "<<HEREDOC",
      );
    }

    // Index just past the `)` that closes the `(` at index k (the one right
    // after `$`), skipping quoted text and nested substitutions inside it.
    // Nesting is capped: past the cap the rest counts as one substitution
    // (a round-4 accuser overflowed the stack with thousands of "$(, which
    // made the hook exit 1, a non-blocking error for the host).
    function substEnd(s, k, level = 0) {
      if (level > 50) return s.length;
      let depth = 1;
      for (let p = k + 1; p < s.length; p++) {
        const ch = s[p];
        if (ch === "\\") { p++; continue; }
        if (ch === "'") { const q = s.indexOf("'", p + 1); p = q === -1 ? s.length : q; continue; }
        if (ch === '"') {
          let q = p + 1;
          while (q < s.length && s[q] !== '"') {
            if (s[q] === "\\") q++;
            else if (s[q] === "$" && s[q + 1] === "(") q = substEnd(s, q + 1, level + 1) - 1;
            q++;
          }
          p = q;
          continue;
        }
        if (ch === "(") depth++;
        if (ch === ")" && --depth === 0) return p + 1;
      }
      return s.length;
    }

    // The code of each top-level $(...) and backtick substitution in s.
    function substitutions(s) {
      const codes = [];
      for (let p = 0; p < s.length; p++) {
        if (s[p] === "\\") { p++; continue; }
        if (s[p] === "$" && s[p + 1] === "(") {
          const end = substEnd(s, p + 1);
          codes.push(s.slice(p + 2, end - 1));
          p = end - 1;
        } else if (s[p] === "`") {
          const end = s.indexOf("`", p + 1);
          codes.push(s.slice(p + 1, end === -1 ? s.length : end));
          p = end === -1 ? s.length : end;
        }
      }
      return codes;
    }

    // s with every substitution that does not mention gh replaced by ''
    // (single-quoted text left alone). Used to count `cd`s: a cd inside
    // such a substitution runs in a subshell and cannot move gh.
    function dropInnocentSubsts(s) {
      let out = "";
      for (let p = 0; p < s.length; p++) {
        const ch = s[p];
        if (ch === "\\") { out += s.slice(p, p + 2); p++; continue; }
        if (ch === "'") {
          const q = s.indexOf("'", p + 1);
          const e = q === -1 ? s.length : q;
          out += s.slice(p, e + 1);
          p = e;
          continue;
        }
        if ((ch === "$" && s[p + 1] === "(") || ch === "`") {
          const end = ch === "`" ? (s.indexOf("`", p + 1) + 1 || s.length) : substEnd(s, p + 1);
          const code = s.slice(ch === "`" ? p + 1 : p + 2, end - 1);
          out += /\b(gh|glab)\b/.test(code) ? s.slice(p, end) : "''";
          p = end - 1;
          continue;
        }
        out += ch;
      }
      return out;
    }

    function stripInertText(s) {
      let out = "";
      let i = 0;
      while (i < s.length) {
        const c = s[i];
        if (c === "\\" && i + 1 < s.length) {
          out += s.slice(i, i + 2);
          i += 2;
          continue;
        }
        // Unquoted command substitution. Code that never mentions gh cannot
        // create or merge a PR (short of disguise, LOW), so it becomes a
        // placeholder; otherwise its `)` cut the command short and hid the
        // PR number after it (round 4: `gh pr merge -t $(git log ...) 42`).
        if ((c === "$" && s[i + 1] === "(") || c === "`") {
          const end = c === "`" ? s.indexOf("`", i + 1) + 1 || s.length : substEnd(s, i + 1);
          const code = s.slice(c === "`" ? i + 1 : i + 2, c === "`" ? end - 1 : end - 1);
          out += /\b(gh|glab)\b/.test(code) ? ` ${code} ` : " '' ";
          i = end;
          continue;
        }
        if (c === "'" || c === '"') {
          let j = i + 1;
          while (j < s.length && s[j] !== c) {
            if (c === '"' && s[j] === "\\") j++;
            else if (c === '"' && s[j] === "$" && s[j + 1] === "(") j = substEnd(s, j + 1) - 1;
            j++;
          }
          const inside = s.slice(i + 1, j);
          const before = out.slice(-80);
          // A quoted value glued to a flag is part of that word for the
          // shell (`--repo="o/r"` is `--repo=o/r`, `-R"o/r"` is `-Ro/r`).
          // The gate needs three of those values (repo, base, head), so
          // they come out as plain `-R o/r` / `--repo=o/r`. Any other glued
          // value (`-t"feat(ui)"`, `--body="a;b"`) becomes a glued '' so
          // its characters cannot cut the command short, and the flag keeps
          // its shape. A round-2 accuser found both: keeping every glued
          // value raw broke `-R"o/r"` and let `(`/`;` inside a subject hide
          // the PR number.
          // Glued means a value, whatever it contains, so it always stays
          // glued: a detached '' would read as a positional argument (the PR
          // number). A substitution inside that runs gh is still a command.
          const glued = i > 0 && !/[\s;&|()`]/.test(s[i - 1]);
          if (glued) {
            const plain = !/[\s;&|()`<>$]/.test(inside);
            if (plain && /(^|\s)-[RBH]$/.test(out)) out += ` ${inside}`;
            else if (plain && /(^|\s)--(repo|base|head)=$/.test(out)) out += inside;
            else if (plain && /(^|[\s;&|(])GH_REPO=$/.test(out)) out += inside;
            else {
              out += "''";
              const code = c === '"' ? substitutions(inside).filter((x) => /\b(gh|glab)\b/.test(x)) : [];
              if (code.length) out += ` ; ${code.map((x) => stripInertText(x)).join(" ; ")} `;
            }
            i = j + 1;
            continue;
          }
          // Allowlist of what executes its argument as code, with only
          // options between the program and the flag (never a script name):
          //   a shell (or $SHELL) then -c, alone or combined (`bash -lc`);
          //   python, su, runuser, script, flock then exactly -c;
          //   node, perl, ruby then exactly -e (`perl -pe`/`-ne` take a
          //   regex, not a command);
          //   eval.
          // Any other -c (grep -c, rg -c, psql -c, tar -czf) is a flag. The
          // round-3 accuser showed the cost of a wider list: counting any
          // quoted word as an interpreter blocked `rg -g "*.md" -c "gh pr
          // create"`. A quoted interpreter (`"$SHELL" -c`) is LOW, not listed.
          const opts = String.raw`(?:\s+-[^\s;&|]*)*`;
          const shell = String.raw`(?:\S*\/)?(?:bash|sh|zsh|dash|ksh|fish|pwsh|powershell|\$\{?SHELL(?::-[^}\s]*)?\}?)`;
          const runsC = String.raw`(?:\S*\/)?(?:python[0-9.]*|su|runuser|script|flock)`;
          const runsE = String.raw`(?:\S*\/)?(?:node|perl|ruby)`;
          const runsAsCode =
            new RegExp(String.raw`(^|[\s;&|(\`])${shell}${opts}\s+-[A-Za-z]*c\s*$`).test(before) ||
            new RegExp(String.raw`(^|[\s;&|(\`])${runsC}${opts}\s+-c\s*$`).test(before) ||
            new RegExp(String.raw`(^|[\s;&|(\`])${runsE}${opts}\s+-e\s*$`).test(before) ||
            /(^|[\s;&|(`])eval\s*$/.test(before);
          // Code is kept only when it mentions gh (see the unquoted case
          // above). In a double-quoted string that is not itself code, only
          // the substitutions inside it can run: "docs: gh pr merge
          // ($(date))" keeps nothing, "$(gh pr create)" keeps the command.
          if (runsAsCode) {
            out += /\b(gh|glab)\b/.test(inside) ? ` ${stripInertText(inside)} ` : " '' ";
          } else if (c === '"') {
            const code = substitutions(inside).filter((x) => /\b(gh|glab)\b/.test(x));
            out += code.length ? ` ${code.map((x) => stripInertText(x)).join(" ; ")} ` : " '' ";
          } else {
            out += " '' ";
          }
          i = j + 1;
          continue;
        }
        out += c;
        i++;
      }
      return out;
    }

    // When a shell reads its own stdin (`bash <<EOF`, `... | sh`, `sh -s`),
    // heredoc bodies and quoted text ARE commands: nothing is stripped.
    const shellReadsStdin =
      /(^|[\s;&|(`])(?:\S*\/)?(bash|sh|zsh|dash|ksh)\b[^;&|\n]*(<<|<\s*<\(|\s-s\b)/.test(command) ||
      /\|\s*(?:sudo\s+)?(?:\S*\/)?(bash|sh|zsh|dash|ksh)\b/.test(command);
    const noDocs = shellReadsStdin ? command : stripHeredocs(command);
    // In stdin mode quotes become spaces: `echo 'gh pr create' | bash` runs what
    // is inside them, and a quote glued to `gh` would prevent the match.
    const active = shellReadsStdin ? command.replace(/["']/g, " ") : stripInertText(noDocs);

    // --- gh api ------------------------------------------------------------------
    // GraphQL: checked on the WHOLE command, heredoc included (multi-line
    // queries put the mutation on the next line). Queries read from a file
    // (`-F query=@x`, `--input`) cannot be read: always blocked. REST: writing
    // to /pulls (create) or /pulls/<n>/merge, checked per segment (between `;`,
    // `&&`, `|`) so a `-f` from another command in the chain does not count.
    const reGhApi = /(^|[\s;&|(`])(?:\S*\/)?gh\s+api\b/;
    if (reGhApi.test(command) && /\bgraphql\b/.test(command)) {
      if (
        /createPullRequest|mergePullRequest|markPullRequestReadyForReview|enablePullRequestAutoMerge|updatePullRequest/.test(
          command,
        ) ||
        /\s(-F|--field)[\s=]+query=@|\s--input[\s=]/.test(command)
      )
        block("a GraphQL PR mutation (or a query read from a file) skips the debate record. Use gh pr create / gh pr merge after /objection.", false);
    }
    for (const segment of noDocs.split(/\n|;|&&|\|\|?/)) {
      if (!reGhApi.test(segment)) continue;
      const pullsTarget = /\/pulls(?![\w/])|\/pulls\/\d+\/merge/.test(segment);
      const read = /(-X|--method)\s*=?\s*GET\b/i.test(segment);
      const write =
        /(-X|--method)\s*=?\s*(POST|PUT)\b/i.test(segment) ||
        /\s(-f|-F|--field|--raw-field|--input)[\s=]/.test(segment);
      if (pullsTarget && write && !read)
        block("gh api writing to /pulls skips the debate record. Use gh pr create / gh pr merge after /objection.", false);
    }

    // --- glab api (GitLab) ------------------------------------------------------
    // Creating or merging a merge request through the API: POST to
    // .../merge_requests or PUT to .../merge_requests/<iid>/merge.
    for (const segment of noDocs.split(/\n|;|&&|\|\|?/)) {
      if (!/(^|[\s;&|(`])(?:\S*\/)?glab\s+api\b/.test(segment)) continue;
      const mrTarget = /merge_requests(?![\w/])|merge_requests\/\d+\/merge\b/.test(segment);
      const read = /(-X|--method)\s*=?\s*GET\b/i.test(segment);
      const write =
        /(-X|--method)\s*=?\s*(POST|PUT)\b/i.test(segment) ||
        /\s(-f|-F|--field|--raw-field|--input)[\s=]/.test(segment);
      if (mrTarget && write && !read)
        block("glab api writing to merge_requests skips the debate record. Use glab mr create / glab mr merge after /objection.", false);
    }

    // --- gh pr <action> ----------------------------------------------------------
    // `gh` in any command position (start, after ; & | ( $( backtick, `time`,
    // `command`, VAR=x, absolute path), with -R/--repo before or after `pr`.
    const reGh =
      /(?:^|[\s;&|(`])(?:\S*\/)?gh((?:\s+(?:-R\s*=?|--repo(?:\s+|=))\S+)*)\s+pr((?:\s+(?:-R\s*=?|--repo(?:\s+|=))\S+)*)\s+(create|new|ready|merge)\b((?:[^;&|\n)]|(?<=[<>])&|&(?=>)|(?<=>)\|)*)/g;

    const matches = [...active.matchAll(reGh)];
    // GitLab: `glab mr create|new|merge`, with -R/--repo before or after `mr`.
    const reGlab =
      /(?:^|[\s;&|(`])(?:\S*\/)?glab((?:\s+(?:-R\s*=?|--repo(?:\s+|=))\S+)*)\s+mr((?:\s+(?:-R\s*=?|--repo(?:\s+|=))\S+)*)\s+(create|new|merge|update)\b((?:[^;&|\n)]|(?<=[<>])&|&(?=>)|(?<=>)\|)*)/g;
    const glabMatches = [...active.matchAll(reGlab)];
    if (matches.length === 0 && glabMatches.length === 0) return ALLOW;

    function tokens(s) {
      return s.trim().split(/\s+/).filter(Boolean);
    }

    // `gh pr merge|ready` flags that consume the next token.
    const TAKES_VALUE = new Set([
      "-R", "--repo", "-t", "--subject", "-b", "--body", "-F", "--body-file",
      "-A", "--author-email", "--match-head-commit",
    ]);

    function repoOf(globals, rest) {
      const toks = [...tokens(globals), ...tokens(rest)];
      for (let k = 0; k < toks.length; k++) {
        const t = toks[k];
        if (t === "-R" || t === "--repo") return toks[k + 1];
        if (t.startsWith("--repo=")) return t.slice(7);
        // Short flag with its value attached, as gh accepts: -Ro/r, -R=o/r.
        if (/^-R./.test(t)) return t.slice(2).replace(/^=/, "");
      }
      return null;
    }

    const UNREADABLE = "\u0000unreadable";

    // GH_REPO selects the repository like -R does: set in the command
    // (`GH_REPO=o/r gh pr merge 5`, `export GH_REPO="o/r"; ...`), else in the
    // hook's own environment. Unread, the gate checked PR 5 of the local
    // repository while gh merged PR 5 of another one.
    function envRepo(pos) {
      const set = [...active.slice(0, pos).matchAll(/(?:^|[\s;&|(])(?:export\s+)?GH_REPO=(\S*)/g)].at(-1);
      if (set) {
        if (!set[1] || set[1] === "''" || set[1].startsWith("$"))
          block("GH_REPO is set from a variable or a quoted value, so the gate cannot tell which repository gh will use. Pass -R owner/repo instead.");
        return set[1];
      }
      return process.env.GH_REPO || null;
    }

    function targetOf(rest) {
      const toks = tokens(rest);
      for (let k = 0; k < toks.length; k++) {
        const t = toks[k];
        if (TAKES_VALUE.has(t)) {
          k++;
          continue;
        }
        if (t.startsWith("-")) continue;
        // A redirection is the shell's, not gh's: `gh pr merge 2>/dev/null`
        // read "2>/dev/null" (or "2>" once cut at "&") as the PR number,
        // measured on an adopter's hook. An operator alone ("2>", ">")
        // also takes the next token, its target (">& 2", "<< EOF", ">| f").
        if (/^(\d*|&)?(>>?|<<?<?)[&|]?$/.test(t)) {
          k++;
          continue;
        }
        if (/^(\d*|&)?(>>?|<<?<?)/.test(t)) continue;
        // A PR number the gate cannot read (a variable, a substitution, a
        // quoted value): skipping it would check the current branch's PR
        // while another one gets merged (round 4). Say so instead.
        if (t === "''" || t.startsWith("$")) return UNREADABLE;
        return t;
      }
      return null;
    }

    function valueOf(rest, ...names) {
      const toks = tokens(rest);
      for (let k = 0; k < toks.length; k++) {
        for (const n of names) {
          if (toks[k] === n) return toks[k + 1];
          if (toks[k].startsWith(`${n}=`)) return toks[k].slice(n.length + 1);
          // Short flag with its value attached: -Bmain, -Hfeat/x.
          if (/^-[A-Za-z]$/.test(n) && toks[k].length > 2 && toks[k].startsWith(n))
            return toks[k].slice(2).replace(/^=/, "");
        }
      }
      return null;
    }

    // The `cd` matches of re in s whose keyword is outside quoted text. A
    // title or body like "reads quoted cd targets; ok" is not a cd, and
    // counting it blocked an innocent `gh pr create` (the counts below did
    // not agree). A `$(...)` or a backtick inside double quotes runs, so
    // it counts.
    function cdsOutsideQuotes(s, re) {
      const quoted = new Uint8Array(s.length);
      let q = "";
      for (let p = 0; p < s.length; p++) {
        const ch = s[p];
        if (q === "'") { quoted[p] = 1; if (ch === "'") q = ""; continue; }
        if (ch === "\\" && q !== "'") { if (q) { quoted[p] = 1; quoted[p + 1] = 1; } p++; continue; }
        if (q === '"') {
          if (ch === '"') { quoted[p] = 1; q = ""; continue; }
          if (ch === "$" && s[p + 1] === "(") { p = substEnd(s, p + 1) - 1; continue; }
          if (ch === "`") { const e = s.indexOf("`", p + 1); p = e === -1 ? s.length : e; continue; }
          quoted[p] = 1;
          continue;
        }
        if (ch === "'" || ch === '"') { quoted[p] = 1; q = ch; }
      }
      return [...s.matchAll(re)].filter((m) => !quoted[m.index + (m[0].startsWith("cd") ? 0 : 1)]);
    }

    // Directory `gh` will run in: the last `cd` before it.
    function dirBefore(pos) {
      const before = active.slice(0, pos);
      // Cases where gh's directory is not the last visible `cd`: a subshell
      // whose `cd` closed before it, `pushd`, `env -C`, or a `cd` inside quoted
      // text shifting the count. Without certainty about the directory, the
      // record checked could belong to another repository.
      const nActive = [...active.matchAll(/(?:^|[\s;&|(])cd\s/g)].length;
      const nOriginal = cdsOutsideQuotes(dropInnocentSubsts(noDocs), /(?:^|[\s;&|(])cd\s/g).length;
      if (
        /\(\s*cd\b[^)]*\)/.test(before) ||
        /(^|[\s;&|(])(pushd|popd)\b/.test(before) ||
        /(^|[\s;&|(])env\b[^;&|\n]*\s(-C|--chdir)\b/.test(before) ||
        nActive !== nOriginal
      )
        block("cannot tell which directory gh will run in. Run gh on its own, after a plain cd (or from the right directory).");
      let dir = sessionDir;
      // Searched in the active text, where `pos` was measured. Quoted paths
      // became '' there, so the path is read from the original, in the same
      // order.
      const reCdActive = /(?:^|[\s;&|(])cd\s+('')?([^\s;&|)]*)/g;
      const reCdOriginal = /(?:^|[\s;&|(])cd\s+("([^"]+)"|'([^']+)'|([^\s;&|)]+))/g;
      const n = [...active.slice(0, pos).matchAll(reCdActive)].length;
      if (n > 0) {
        const m = cdsOutsideQuotes(noDocs, reCdOriginal)[n - 1];
        if (m) {
          // `cd "$(git rev-parse --show-toplevel)"` is how agents go back to
          // the repository root: resolve it the same way instead of reading
          // the substitution as a path (it used to block an innocent merge).
          const toRoot = /^[\s;&|(]*cd\s+"?\$\(\s*git\s+rev-parse\s+--show-toplevel\s*\)"?(?=[\s;&|)]|$)/.test(
            noDocs.slice(m.index),
          );
          let p = m[2] || m[3] || m[4];
          if (toRoot) p = git(dir, "rev-parse", "--show-toplevel");
          else if (p.startsWith("~")) p = join(process.env.HOME || "", p.slice(1));
          p = nativePath(p);
          dir = isAbsolute(p) ? p : resolve(dir, p);
        }
      }
      return dir;
    }

    /** PR head SHA and base branch, from GitHub. */
    function fromPr(dir, repo, target) {
      const args = ["pr", "view"];
      if (target) args.push(target);
      if (repo) args.push("-R", repo);
      args.push("--json", "headRefOid,baseRefName", "-q", '.headRefOid + " " + .baseRefName');
      const [sha, base] = gh(args, {
        cwd: dir,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
        timeout: 15000,
      })
        .trim()
        .split(/\s+/);
      if (!sha || !base) throw new Error("gh answered without sha/base");
      return { sha, base };
    }

    // The record counts by its LAST verdict line, the same one stamp.sh reads.
    // It also needs the stamp that only stamp.sh writes on the first line, with
    // the SHA and the base the diff was debated against. That checks shape, not
    // origin: anyone can write a stamped file by hand, so this stops an agent that
    // skipped the debate, not one that forges a record (the CI review is the answer
    // to that). A record debated against one base does not release a PR to another
    // base (different diff, different accusers).
    function approved(common, sha, prBase) {
      const file = join(common, "objection", `${sha}.md`);
      if (!existsSync(file)) return `no /objection record for commit ${sha.slice(0, 7)}.`;
      const text = readFileSync(file, "utf8");
      const stamp = /^<!-- objection: sha=([0-9a-f]{40}) base=(\S+) -->$/m.exec(text.split("\n")[0] || "");
      if (!stamp || stamp[1] !== sha)
        return `the record for ${sha.slice(0, 7)} was not written by stamp.sh (${file}).`;
      if (prBase && stamp[2] !== `origin/${prBase}`)
        return `the record for ${sha.slice(0, 7)} was debated against ${stamp[2]}, but the PR targets ${prBase}. Run /objection against origin/${prBase}.`;
      const verdicts = text.split("\n").filter((l) => /^VERDICT: /.test(l));
      if (verdicts.at(-1) !== "VERDICT: APPROVED")
        return `the record for ${sha.slice(0, 7)} is not APPROVED (${file}).`;
      return null;
    }

    for (const m of matches) {
      const [, ghGlobals, prGlobals, rawAction, rest] = m;
      const globals = `${ghGlobals} ${prGlobals}`;
      const action = rawAction === "new" ? "create" : rawAction;
      // Help and disabling auto-merge touch no PR.
      if (/(^|\s)(--help|-h)\b/.test(rest)) continue;
      if (action === "merge" && /(^|\s)--disable-auto\b/.test(rest)) continue;
      // Back to draft only takes a PR further from merging.
      if (action === "ready" && /(^|\s)--undo\b/.test(rest)) continue;
      // Target from stdin (`... | xargs gh pr merge`): the hook would check the
      // current branch's PR while another one gets merged.
      if (/\bxargs\b[^;&|\n]*$/.test(active.slice(0, m.index + 1)))
        block("gh pr merge/ready through xargs hides which PR it is. Put the PR number in the command itself.", false);
      const dir = dirBefore(m.index);
      const cfg = loadConfig(dir);
      if (!cfg) continue;
      advisory = cfg.enforce === false;
      const repo = repoOf(globals, rest) || envRepo(m.index);

      if (action === "merge" && /(^|\s)--auto\b/.test(rest))
        block("gh pr merge --auto lets in commits pushed after the debate. Merge without --auto, with the record for the current SHA.", false);

      let common;
      try {
        // Not --path-format=absolute (git 2.31+): resolved here instead.
        common = resolve(dir, git(dir, "rev-parse", "--git-common-dir"));
      } catch {
        block(`could not find a git repository at ${dir}.`);
      }

      let sha;
      let prBase;
      try {
        if (action === "create") {
          const head = valueOf(rest, "-H", "--head");
          let headBranch = head;
          if (head) {
            // The PR is born from the branch on GitHub, not from a local
            // branch with the same name (an external review caught the gate
            // checking the local one and skipping the push check). Which
            // remote holds it is found, not assumed to be `origin` (the
            // round-1 accuser caught that regression).
            const [owner, branch] = head.includes(":") ? head.split(/:(.*)/s) : [null, head];
            headBranch = branch;
            const remoteName = remoteFor(dir, branch, repo, owner);
            if (!remoteName)
              block(
                owner
                  ? `--head ${head}: no git remote points at ${owner}'s repository, so the gate cannot read that branch. Add it (git remote add ${owner} <url>) and push the debated commit there.`
                  : `--head ${head}: cannot tell which remote holds that branch. Set its upstream (git push -u <remote> ${branch}).`,
                false,
              );
            const local = git(dir, "rev-parse", `refs/heads/${branch}`);
            const line = git(dir, "ls-remote", remoteName, `refs/heads/${branch}`);
            const remoteSha = line.split(/\s+/)[0];
            if (!remoteSha)
              block(`branch ${branch} is not on ${remoteName}. Push the debated commit before opening the PR.`, false);
            if (remoteSha !== local)
              block(`${remoteName}/${branch} is at ${remoteSha.slice(0, 7)} but the local branch is at ${local.slice(0, 7)}. Push the debated commit before opening the PR.`, false);
            sha = remoteSha;
          } else {
            sha = git(dir, "rev-parse", "HEAD");
          }
          // The base gh will really use, not .objection.json's defaultBase:
          // --base, else the branch's gh-merge-base setting, else the
          // repository's default branch on GitHub.
          prBase = valueOf(rest, "-B", "--base") || ghBase(dir, repo, headBranch);
          // The PR is born from what is on the remote, not the local HEAD.
          if (!head) {
            let remote = null;
            try {
              remote = git(dir, "rev-parse", "@{u}");
            } catch {
              remote = null;
            }
            if (remote && remote !== sha)
              block(`the branch remote is at ${remote.slice(0, 7)} but the debate was about ${sha.slice(0, 7)}. Push the debated commit before opening the PR.`, false);
          }
        } else {
          const target = targetOf(rest);
          if (target === UNREADABLE)
            block(`gh pr ${action} gets its PR number from a variable or a command, so the gate cannot tell which PR it is. Put the number in the command itself.`);
          ({ sha, base: prBase } = fromPr(dir, repo, target));
        }
      } catch (e) {
        if (e instanceof Blocked) throw e;
        block(
          action === "create"
            ? `could not read the commit going into the PR, or the base gh will use, at ${dir}.`
            : `could not read the head SHA of PR ${targetOf(rest) || "for the current branch"}${repo ? ` in ${repo}` : ""}.`,
        );
      }

      const problem = approved(common, sha, prBase);
      if (problem) block(problem);
    }

    // --- glab mr <action> (GitLab) -----------------------------------------------
    // Flags from docs.gitlab.com/cli/mr/create and /mr/merge. Stricter than
    // gh on purpose where the gate cannot learn a value: no --target-branch
    // on create is blocked instead of guessing the project default.
    const GLAB_TAKES_VALUE = new Set([
      "-R", "--repo", "-m", "--message", "--squash-message", "--sha",
    ]);
    // `glab mr update` flags with a value (docs.gitlab.com/cli/mr/update);
    // in `merge`, -d is a switch, so the sets are kept apart.
    const GLAB_UPDATE_VALUE = new Set([
      "-t", "--title", "-l", "--label", "--reviewer", "-m", "--milestone", "--target-branch",
      // Not in the current docs; older glab had it. Skipping its value
      // keeps a number in a description from being read as the MR.
      "-d", "--description",
    ]);
    for (const m of glabMatches) {
      const [, glabGlobals, mrGlobals, rawAction, rest] = m;
      const action = rawAction === "new" ? "create" : rawAction;
      if (/(^|\s)(--help|-h)\b/.test(rest)) continue;
      // `glab mr update` counts only when it takes a draft to review.
      // (--ready/-r, or leaving draft with --draft=<false> / --wip=<false>,
      // in every form a Go boolean flag accepts: false, f, 0, any case).
      // Case matters for the flags (-R is --repo), not for the value.
      if (action === "update" && !/(^|\s)((--ready|-r)(\s|=|$)|--(draft|wip)=([Ff][Aa][Ll][Ss][Ee]|[Ff]|0)(\s|$))/.test(rest)) continue;
      if (/\bxargs\b[^;&|\n]*$/.test(active.slice(0, m.index + 1)))
        block("glab mr merge through xargs hides which merge request it is. Put its number in the command itself.", false);
      const dir = dirBefore(m.index);
      const cfg = loadConfig(dir);
      if (!cfg) continue;
      advisory = cfg.enforce === false;
      const repo = repoOf(`${glabGlobals} ${mrGlobals}`, rest);
      let common;
      try {
        common = resolve(dir, git(dir, "rev-parse", "--git-common-dir"));
      } catch {
        block(`could not find a git repository at ${dir}.`);
      }
      let sha;
      let mrBase;
      try {
        if (action === "create") {
          mrBase = valueOf(rest, "-b", "--target-branch");
          if (!mrBase)
            block("glab mr create without --target-branch: the gate cannot tell which base the record must match. Pass --target-branch <base>.", false);
          const source = valueOf(rest, "-s", "--source-branch");
          const ref = source ? `refs/heads/${source}` : "HEAD";
          sha = git(dir, "rev-parse", ref);
          let upstream = null;
          try {
            upstream = git(dir, "rev-parse", `${source || ""}@{u}`);
          } catch {
            upstream = null;
          }
          if (!upstream)
            block(`the branch has no upstream, so the gate cannot tell what the merge request will contain. Push it first (git push -u <remote> <branch>).`, false);
          if (upstream !== sha)
            block(`the branch remote is at ${upstream.slice(0, 7)} but the debate was about ${sha.slice(0, 7)}. Push the debated commit before opening the merge request.`, false);
        } else {
          // Auto-merge is glab's default and merges whatever the head is
          // when the pipeline passes: only an explicit off is allowed.
          if (action === "merge" && !/(^|\s)--auto-merge=false\b/.test(rest))
            block("glab mr merge auto-merges by default, which lets in commits pushed after the debate. Run it with --auto-merge=false, with the record for the current SHA.", false);
          const toks = tokens(rest);
          let target = null;
          for (let k = 0; k < toks.length; k++) {
            const t = toks[k];
            if (GLAB_TAKES_VALUE.has(t) || (action === "update" && GLAB_UPDATE_VALUE.has(t))) {
              k++;
              continue;
            }
            if (t.startsWith("-")) continue;
            if (t === "''" || t.startsWith("$"))
              block("glab mr merge gets its merge request from a variable or a command, so the gate cannot tell which one it is. Put the number in the command itself.");
            target = t;
            break;
          }
          const args = ["mr", "view"];
          if (target) args.push(target);
          if (repo) args.push("-R", repo);
          args.push("-F", "json");
          const mr = JSON.parse(glab(args, { cwd: dir, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 15000 }));
          sha = mr.sha;
          mrBase = mr.target_branch;
          if (!sha || !mrBase) throw new Error("glab answered without sha/target_branch");
        }
      } catch (e) {
        if (e instanceof Blocked) throw e;
        block(
          action === "create"
            ? `could not read the commit going into the merge request at ${dir}.`
            : `could not read the head SHA of the merge request${repo ? ` in ${repo}` : ""} (glab mr view).`,
        );
      }
      const problem = approved(common, sha, mrBase);
      if (problem) block(problem);
    }

    return ALLOW;
  } catch (e) {
    if (e instanceof Blocked)
      return advisory
        ? { blocked: false, warning: e.reason }
        : { blocked: true, reason: e.reason, hint: e.withHint };
    throw e;
  }
}
