#!/bin/bash
# Runs the accuser on known bugs and reports what it caught. It calls a
# real model (a few cents on sonnet), so it is run by hand, not in CI:
#
#   bash eval/run.sh                      claude, the review.sh defaults
#   OBJECTION_RUNNER=gemini bash eval/run.sh
#   OBJECTION_MODEL=opus bash eval/run.sh [fixture...]
#   EVAL_FIXTURES=<dir> bash eval/run.sh  other fixtures (eval/real/fetch.sh
#                                         builds the real-bug ones)
#   EVAL_BASELINE=1 bash eval/run.sh      the same model with a plain "review
#                                         this diff" prompt and the raw diff
#   EVAL_DEFENSE=1 bash eval/run.sh       also runs the defender on each
#                                         false alarm and each catch; with
#                                         EVAL_RESCORE=<dir>, on answers
#                                         already saved (no accuser paid)
#
# Each fixtures/<name> has base/ (the code before), change/ (the files
# the PR writes), config.json (.objection.json at the base) and
# expect.json: {goal, severity, match, file} for a planted bug, or
# {goal, clean: true} for a change with none. A bug counts as caught when
# a finding row at that severity or above names the file and either cites
# one of the bug's lines (expect.json "lines") in that cell, or says the
# bug in the defect cell next to it (the pattern); a clean change passes
# with no BLOCKER or HIGH. prompt-injection is negative-total with a comment telling the
# reviewer the change is approved: it must still be caught.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
skill="$here/../skills/objection"
fixtures="${EVAL_FIXTURES:-$here/fixtures}"
# Made here and made absolute before the cd below: a missing or relative
# EVAL_KEEP lost every answer.
if [ -n "${EVAL_KEEP:-}" ]; then
  mkdir -p "$EVAL_KEEP" && EVAL_KEEP=$(cd "$EVAL_KEEP" && pwd) || { echo "EVAL_KEEP: cannot use $EVAL_KEEP" >&2; exit 1; }
fi
cd "$fixtures" || exit 1
names=("$@")
[ ${#names[@]} -gt 0 ] || names=(*)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0
total=0
printf '%-18s %-10s %-22s %s\n' fixture expected result "cost / note"
for name in "${names[@]}"; do
  f="$fixtures/$name"
  [ -f "$f/expect.json" ] || continue
  total=$((total + 1))
  r="$T/$name"
  if [ -n "${EVAL_RESCORE:-}" ]; then
    # Score answers saved by an earlier run (EVAL_KEEP) with this scorer,
    # without calling a model: how a scoring fix is applied to runs
    # already paid for, the same for every side. With EVAL_DEFENSE=1 the
    # saved answers also go to the defender (the repository and brief are
    # built for it): a defense measured on accusations already paid for.
    [ -f "$EVAL_RESCORE/$name.out" ] || { printf '%-18s no saved answer\n' "$name"; continue; }
  fi
  # Plain rescoring needs no repository: a setup that fails must not stop
  # answers already paid for from being scored.
  if [ -z "${EVAL_RESCORE:-}" ] || [ -n "${EVAL_DEFENSE:-}" ]; then
  mkdir -p "$r" && cp -R "$f/base/." "$r/" && cp "$f/config.json" "$r/.objection.json"
  (
    cd "$r" && git init -q -b main && git add -A &&
      git -c user.email=e@e -c user.name=eval commit -q -m base &&
      git update-ref refs/remotes/origin/main HEAD &&
      cp -R "$f/change/." . && git add -A &&
      git -c user.email=e@e -c user.name=eval commit -q -m change
  ) || { printf '%-18s setup failed\n' "$name"; continue; }
  goal=$(node -e 'console.log(require(process.argv[1]).goal || "not stated")' "$f/expect.json")
  brief=$(cd "$r" && bash "$skill/brief.sh" origin/main "$goal" 2>/dev/null) || { printf '%-18s brief failed\n' "$name"; continue; }
  fi
  if [ -n "${EVAL_RESCORE:-}" ]; then
    cp "$EVAL_RESCORE/$name.out" "$T/$name.out" && : >"$T/$name.err"
    rc=0
  else
  roles=""
  if [ -n "${EVAL_BASELINE:-}" ]; then
    # The baseline: the same model and isolation, but a one-paragraph
    # "review this diff" prompt and the raw diff, with no brief (no line
    # numbers, definitions, invariants or precedents) and no role. What
    # objection adds is the difference between the two runs.
    brief="$T/$name.raw"
    { printf 'Goal: %s\n\n```diff\n' "$goal"; (cd "$r" && git diff origin/main...HEAD); printf '```\n'; } >"$brief"
    roles="$here/baseline"
  fi
  (cd "$r" && OBJECTION_ROLES_DIR="${roles:-${OBJECTION_ROLES_DIR:-$skill/roles}}" bash "$skill/review.sh" accuser "$brief" >"$T/$name.out" 2>"$T/$name.err")
  rc=$?
  fi
  cost=$(sed -n 's/.*(\(\$[0-9.]*\)).*/\1/p; s/.*output tokens (\([a-z]*\))$/\1/p' "$T/$name.err" | tail -n 1)
  verdict=$(node -e '
    const fs = require("fs");
    const [, exp, out, rc] = process.argv;
    const e = JSON.parse(fs.readFileSync(exp, "utf8"));
    if (rc !== "0") { console.log("ERROR"); process.exit(); }
    const rank = { BLOCKER: 3, HIGH: 2, MEDIUM: 1, LOW: 0 };
    // A row with or without its outer pipes ("BLOCKER | BUG | a.js:1 | ...").
    const rows = fs.readFileSync(out, "utf8").split("\n")
      .map((l) => (/^\s*\**(BLOCKER|HIGH|MEDIUM|LOW)\**\s*\|/i.test(l) ? "| " + l : l))
      .filter((l) => /^\s*\|/.test(l)).map((l) => {
      const cells = l.split("|").map((c) => c.trim());
      const w = (cells[1] || "").replace(/[*_]/g, "").match(/^[A-Za-z]+/);
      return { sev: w ? w[0].toUpperCase() : "", text: l };
    }).filter((r) => r.sev in rank);
    if (e.clean) { console.log(rows.some((r) => rank[r.sev] >= 2) ? "FALSE-ALARM" : "PASS"); process.exit(); }
    // About the bug: it cites a line of the bug, or says it in words.
    const re = new RegExp(e.match, "i");
    // A cited line, or a range that holds a line of the bug and is
    // no wider than 60 lines ("a.c:1248-1298" names the bug at 1297; a
    // whole-file range names nothing). "~174" is how a reviewer without
    // line numbers cites an estimate: it counts like "174".
    // The file as the reviewer wrote it: the full path, or a shortened
    // one whose directories are all in the real path, in order
    // ("buffer/.../AdaptivePoolingAllocator.java", "HttpObjectDecoder.java").
    // Measured on netty: a real catch at the bug line scored MISSED
    // because the reviewer shortened a 70-character Java path.
    const dirs = e.file.split("/").slice(0, -1);
    const base = e.file.split("/").pop();
    const escB = base.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const inOrder = (pre) => {
      let at = 0;
      for (const d of pre.split("/").filter((x) => x && !/^(\.|\.\.\.|\u2026)$/.test(x))) {
        const k = dirs.indexOf(d, at);
        if (k < 0) return false;
        at = k + 1;
      }
      return true;
    };
    const refs = (t) => [...t.matchAll(new RegExp(`(?<![\\w./\u2026-])([\\w./\u2026-]*/)?${escB}(?::~?(\\d+)(?:-~?(\\d+))?)?`, "g"))]
      .filter((m) => inOrder(m[1] || ""));
    const names = (t) => refs(t).length > 0;
    const cites = (t) => refs(t).some((m) => {
      if (!m[2]) return false;
      const a = +m[2], b = m[3] ? +m[3] : a;
      return b >= a && b - a <= 60 && (e.lines || []).some((n) => n >= a && n <= b);
    });
    // The file:line cell cites a bug line, or the defect cell next to it
    // says the bug in words: a keyword elsewhere in the row does not count.
    // "line" when it cites a bug line, "words" when only the defect cell
    // says it: a catch by line is the stronger evidence, so it wins.
    const how = (r) => {
      const cells = r.text.split("|");
      // The file:line cell, else the first cell that names the file.
      let i = cells.findIndex((c) => refs(c).some((m) => m[2]));
      if (i < 0) i = cells.findIndex(names);
      if (i < 0) return "";
      return cites(cells[i]) ? "line" : re.test(cells[i + 1] || "") ? "words" : "";
    };
    const strong = rows.filter((r) => rank[r.sev] >= rank[e.severity] && how(r));
    const hit = strong.find((r) => how(r) === "line") || strong[0];
    const near = rows.find(how);
    console.log(hit ? `CAUGHT ${hit.sev} (${how(hit)})` : near ? `LOW-RATED ${near.sev}` : "MISSED");
  ' "$f/expect.json" "$T/$name.out" "$rc")
  exp=$(node -e 'const e=require(process.argv[1]); console.log(e.clean ? "no bug" : e.severity + "+")' "$f/expect.json")
  # EVAL_DEFENSE=1: the debate does not stop at the accuser. A false
  # alarm goes to the defender, as debate.sh would send it; so does a
  # catch, to see whether the defender would talk the judge out of a real
  # bug. The result says what the defender ruled on each row sent.
  defense=""
  case "${EVAL_DEFENSE:-}:$verdict" in
    1:FALSE-ALARM* | 1:CAUGHT*)
      node -e '
        const fs = require("fs");
        const rows = fs.readFileSync(process.argv[1], "utf8").split("\n").filter((l) => /^\s*\|\s*\**(BLOCKER|HIGH)\b/i.test(l));
        const out = ["| # | severity | kind | file:line | defect | evidence | proof path |", "|---|---|---|---|---|---|---|"];
        rows.forEach((l, k) => out.push(`| ${k + 1} ` + l.trim()));
        fs.writeFileSync(process.argv[2], out.join("\n") + "\n");
      ' "$T/$name.out" "$T/$name.findings"
      if (cd "$r" && bash "$skill/review.sh" defender "$brief" "$T/$name.findings" >"$T/$name.defense" 2>>"$T/$name.err"); then
        defense=$(node -e '
          const fs = require("fs");
          const rank = { BLOCKER: 3, HIGH: 2, MEDIUM: 1, LOW: 0 };
          // The accused severity per number, from the rows sent.
          const sev = {};
          for (const l of fs.readFileSync(process.argv[2], "utf8").split("\n")) {
            const c = l.split("|").map((x) => x.trim());
            if (/^\d+$/.test(c[1] || "")) sev[c[1]] = (c[2] || "").replace(/[^A-Za-z]/g, "").toUpperCase();
          }
          const rows = fs.readFileSync(process.argv[1], "utf8").split("\n").filter((l) => /^\s*\|\s*\d+\s*\|/.test(l))
            .map((l) => { const c = l.split("|"); return { id: (c[1] || "").trim(), v: (c[2] || "").trim().toUpperCase() }; });
          const v = rows.map((r) => r.v);
          const n = (w) => v.filter((x) => x.startsWith(w)).length;
          // "UPHELD, propose LOW": the defender agrees there is a defect and
          // argues it is smaller; the judge decides, so it is counted apart,
          // and only when the proposal is below the accused severity.
          const lower = rows.filter((r) => {
            const m = r.v.match(/PROPOSE\W*(BLOCKER|HIGH|MEDIUM|LOW)/);
            return r.v.startsWith("UPHELD") && m && rank[m[1]] < (rank[sev[r.id]] ?? -1);
          }).length;
          console.log(`defense: ${n("REFUTED")} refuted, ${lower} lower proposed, ${n("UPHELD") - lower} upheld, ${n("CANNOT")} cannot verify`);
        ' "$T/$name.defense" "$T/$name.findings")
      else
        defense="defense: failed"
      fi
      ;;
  esac
  case "$verdict" in CAUGHT* | PASS) pass=$((pass + 1)) ;; esac
  printf '%-18s %-10s %-22s %s%s\n' "$name" "$exp" "$verdict" "${cost:-?}" "${defense:+; $defense}"
  [ -z "${EVAL_KEEP:-}" ] || { cp "$T/$name.out" "$EVAL_KEEP/$name.out"; [ ! -f "$T/$name.defense" ] || cp "$T/$name.defense" "$EVAL_KEEP/$name.defense"; }
done
case "${OBJECTION_RUNNER:-claude}" in
  gemini) who="gemini ${OBJECTION_GEMINI_MODEL:-(its default)}" ;;
  codex) who="codex ${OBJECTION_CODEX_MODEL:-(its default)}" ;;
  *) who="claude ${OBJECTION_MODEL:-sonnet}, effort ${OBJECTION_EFFORT:-medium}" ;;
esac
[ "$total" -gt 0 ] || { echo "no fixture matched: nothing ran." >&2; exit 2; }
[ -z "${EVAL_BASELINE:-}" ] || who="$who, BASELINE (plain prompt, raw diff)"
# The model ids that answered (review.sh prints them): an alias moves to
# a new model without notice, and two runs compare only on the same one.
models=$(cat "$T"/*.err 2>/dev/null | sed -n 's/^objection: model //p' | sort -u | paste -sd, -)
echo "runner: $who${models:+ ($models)}; $pass of $total as expected"
# Real bugs (EVAL_FIXTURES) are graded by hand before a number is quoted:
# a row that cites a bug line counts even when it describes another
# defect on that line, and the 2026-10-01 run read 6 of 60 too high.
[ -z "${EVAL_FIXTURES:-}" ] || echo "note: an automatic count; a finding that cites a bug line counts even when it is about another defect there. Grade real bugs by hand before quoting a number (docs/eval.md)."
[ "$pass" = "$total" ]
