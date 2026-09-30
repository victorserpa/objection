#!/usr/bin/env node
// The tool-neutral gate: a GitHub check that fails a pull request unless
// its body carries an APPROVED /objection record for the PR's current head
// SHA and base. It does not care which agent (or human) opened the PR, so
// it covers every tool that has no local hook. Make it a required status
// check in branch protection. It checks that a record is there and
// consistent, not who wrote it: an author can paste one by hand. The
// review input (an accuser run in CI, with a key the agent never sees) is
// what an author cannot fake.
//
// A new push changes the head SHA, so the check fails again until the
// debate runs on the new commit and the body is updated with the new
// record. Same rules as stamp.sh: last VERDICT line counts, required
// sections unless the diff is documentation only, nothing BLOCKER/HIGH
// under "## Open".
//
// Inputs (GitHub Actions): GITHUB_EVENT_PATH, GITHUB_TOKEN, GITHUB_API_URL.
// Inputs (GitLab CI, merge request pipelines): CI_API_V4_URL, CI_PROJECT_ID,
// CI_MERGE_REQUEST_IID, CI_JOB_TOKEN (the job token may GET a merge
// request, per docs.gitlab.com/ci/jobs/ci_job_token), and the clone for
// the file list (GIT_DEPTH: 0). The predefined description variable is
// cut at 2700 characters, too short for a record: the API is read instead.
// Test hooks: OBJECTION_FILES (newline-separated changed files) skips the
// file listing; OBJECTION_MR_JSON (a file) stands in for the merge request.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { missingRulings } from "./rulings.mjs";

const gitlab = !!process.env.GITLAB_CI;

function fail(msg) {
  // Escaped as the Actions docs ask: a message can quote the PR body, and
  // a raw newline there would start a workflow command of its own.
  const esc = msg.replace(/%/g, "%25").replace(/\r/g, "%0D").replace(/\n/g, "%0A");
  if (!gitlab) console.log(`::error title=objection::${esc}`);
  console.error(`objection: ${msg}`);
  process.exit(1);
}

let event = null;
let pr = null;
// fetch arrived in Node.js 18; without it every API call below would read
// as a ReferenceError instead of saying what is wrong.
if (typeof fetch !== "function") {
  fail(`this check needs Node.js 18 or later (found ${process.version}).`);
}
let mr = null;
let head;
let base;
let body;
if (gitlab) {
  if (!process.env.CI_MERGE_REQUEST_IID) fail("this check only runs in merge request pipelines (rules: if: $CI_PIPELINE_SOURCE == \"merge_request_event\").");
  if (process.env.OBJECTION_MR_JSON) {
    mr = JSON.parse(readFileSync(process.env.OBJECTION_MR_JSON, "utf8"));
  } else {
    // OBJECTION_GITLAB_TOKEN (a project access token with read_api) for
    // instances that do not let the job token read merge requests.
    const url = `${process.env.CI_API_V4_URL}/projects/${process.env.CI_PROJECT_ID}/merge_requests/${process.env.CI_MERGE_REQUEST_IID}`;
    const headers = process.env.OBJECTION_GITLAB_TOKEN
      ? { "PRIVATE-TOKEN": process.env.OBJECTION_GITLAB_TOKEN }
      : { "JOB-TOKEN": process.env.CI_JOB_TOKEN || "" };
    let status = 0;
    try {
      const res = await fetch(url, { headers });
      status = res.status;
      if (res.ok) mr = await res.json();
    } catch {}
    if (!mr) {
      // The predefined variables, when the description was not cut.
      const desc = process.env.CI_MERGE_REQUEST_DESCRIPTION || "";
      // GitLab before 15.9 sets no truncation flag: 2700 characters or more
      // is taken as cut.
      const flag = process.env.CI_MERGE_REQUEST_DESCRIPTION_IS_TRUNCATED;
      const cut = flag === "true" || (flag !== "false" && desc.length >= 2700);
      if (!desc || cut)
        fail(`could not read the merge request (HTTP ${status || "error"}), and CI_MERGE_REQUEST_DESCRIPTION is ${desc ? "cut at 2700 characters" : "empty"}. Set OBJECTION_GITLAB_TOKEN to a project access token with read_api.`);
      mr = {
        sha: process.env.CI_MERGE_REQUEST_SOURCE_BRANCH_SHA || process.env.CI_COMMIT_SHA,
        target_branch: process.env.CI_MERGE_REQUEST_TARGET_BRANCH_NAME,
        description: desc,
      };
    }
  }
  // The MR's head as GitLab reports it; in a merged-results pipeline
  // CI_COMMIT_SHA is a merge commit, not the debated one.
  head = mr.sha;
  base = mr.target_branch;
  body = mr.description || "";
  if (!head || !base) fail("the merge request has no head SHA or target branch.");
} else {
  event = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, "utf8"));
  pr = event.pull_request;
  if (!pr) fail("this check only runs on pull_request events.");
  head = pr.head.sha;
  base = pr.base.ref;
  body = pr.body || "";
  // GitHub keeps a body edited in the browser with CRLF line ends: without
  // the normalization below, every "## Accusation" line read as missing.
}

// The LAST stamp in the body wins: an older record left above a newer one
// must not count.
const stampsOf = (text) => [...text.replace(/\r\n?/g, "\n").matchAll(/^<!-- objection: sha=([0-9a-f]{40}) base=(\S+) -->$/gm)];
// A push runs this check at once, while the body still holds the previous
// record: pr-body.sh --update can only follow the push. That run failed and
// its failure stayed on the head next to the passing run of the edit. So
// on GitHub, a record for another SHA is re-read from the API for up to
// OBJECTION_BODY_WAIT seconds (60), and the body counts once its record is
// for this head, while the PR's head is still this one.
// A body with no record at all is not waited for: it is not a push race.
const eventStamp = stampsOf(body).at(-1)?.[1];
if (!gitlab && process.env.GITHUB_TOKEN && event.repository && eventStamp && eventStamp !== head && process.env.OBJECTION_BODY_WAIT !== "0") {
  const api = process.env.GITHUB_API_URL || "https://api.github.com";
  const wait = Math.min(Math.max(Number(process.env.OBJECTION_BODY_WAIT ?? 60) || 0, 0), 600);
  // Zero, negative or not a number: the default, not a flood of reads.
  const asked = Number(process.env.OBJECTION_BODY_STEP ?? 10);
  const step = asked > 0 ? Math.max(asked, 0.1) : 10;
  // Read at once, then every step until the wait is over.
  for (let t = 0; t <= wait; t += step) {
    if (t > 0) await new Promise((r) => setTimeout(r, step * 1000));
    let now;
    try {
      const res = await fetch(`${api}/repos/${event.repository.full_name}/pulls/${pr.number}`, {
        headers: { authorization: `Bearer ${process.env.GITHUB_TOKEN}`, accept: "application/vnd.github+json" },
      });
      if (res.ok) now = await res.json();
    } catch {}
    if (!now) continue;
    // A newer push: its own run checks it.
    if (now.head?.sha !== head) break;
    if (stampsOf(now.body || "").at(-1)?.[1] === head) {
      body = now.body || "";
      break;
    }
  }
}
body = body.replace(/\r\n?/g, "\n");
const stamps = stampsOf(body);
if (stamps.length === 0)
  fail(`no /objection record in the PR body. Run /objection on ${head.slice(0, 7)} and paste the stored record (including its first line) into the body.`);
const stamp = stamps.at(-1);
if (stamp[1] !== head)
  fail(`the record in the body is for ${stamp[1].slice(0, 7)}, but the PR head is ${head.slice(0, 7)}. Debate the new commits and update the body.`);
if (stamp[2] !== `origin/${base}`)
  fail(`the record was debated against ${stamp[2]}, but the PR targets ${base}.`);

const record = body.slice(stamp.index);

async function changedFiles() {
  const all = (files) => ({ files, listed: files.length });
  if (process.env.OBJECTION_FILES !== undefined)
    return all(process.env.OBJECTION_FILES.split("\n").filter(Boolean));
  if (gitlab) {
    // From the clone: no API page limit. The diff base GitLab computed for
    // this MR, against the debated head.
    const from = process.env.CI_MERGE_REQUEST_DIFF_BASE_SHA || `origin/${base}`;
    try {
      return all(
        execFileSync("git", ["diff", "--no-renames", "--name-only", `${from}...${head}`], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 })
          .split("\n")
          .filter(Boolean),
      );
    } catch {
      fail(`could not list the changed files with git (${from}...${head.slice(0, 7)}). Set GIT_DEPTH: 0 on this job.`);
    }
  }
  const api = process.env.GITHUB_API_URL || "https://api.github.com";
  const repo = event.repository.full_name;
  const files = [];
  let listed = 0;
  for (let page = 1; page <= 30; page++) {
    const res = await fetch(`${api}/repos/${repo}/pulls/${pr.number}/files?per_page=100&page=${page}`, {
      headers: {
        authorization: `Bearer ${process.env.GITHUB_TOKEN}`,
        accept: "application/vnd.github+json",
      },
    });
    if (!res.ok) fail(`could not list the PR files (HTTP ${res.status}).`);
    const batch = await res.json();
    // A rename is listed under its new name only: its old one counts too.
    listed += batch.length;
    files.push(...batch.flatMap((f) => (f.previous_filename ? [f.filename, f.previous_filename] : [f.filename])));
    if (batch.length < 100) break;
  }
  return { files, listed };
}

// listed counts API entries (a rename is one), files every name it touched.
const { files, listed } = await changedFiles();
// The files API stops at 3000 files. A list that hits the limit, or that
// is shorter than the PR says it is, proves nothing about the rest: a PR of
// 3000 docs and one source file must not pass as documentation only.
if (!gitlab && (listed >= 3000 || (Number.isInteger(pr.changed_files) && listed !== pr.changed_files)))
  fail(`cannot prove the full list of changed files (listed ${listed}, PR has ${pr.changed_files}). Split the PR.`);
// Agent prompts, skills, instructions and the objection config are how the
// debate itself behaves: weakening the defender must not ship without a
// debate. Agent config dirs and instruction files count at any depth
// (packages/web/CLAUDE.md); agents/ and skills/ only at the root, where they
// are a plugin convention. Same list as stamp.sh (NEVER_DOCS).
const NEVER_DOCS =
  /(^|\/)(\.(claude|cursor|codex|gemini|github|agents|objection)\/|(AGENTS|CLAUDE|GEMINI)\.md$|\.objection\.json$)|^(agents|skills)\//;
const docsOnly =
  files.length > 0 &&
  // By extension only: docs/conf.py is code. Not .txt: requirements.txt and
  // CMakeLists.txt change what gets built. Renamed files count under
  // both names (changedFiles), so src/auth.js -> src/auth.md is not docs.
  files.every((f) => !NEVER_DOCS.test(f) && /\.(md|mdx|rst|adoc)$/i.test(f));

const lines = record.split("\n");
if (!docsOnly) {
  for (const section of ["## Accusation", "## Defense", "## Judge", "## Open"]) {
    if (lines.includes(section)) continue;
    // Measured on an adopter's PR: the agent pasted the record by hand
    // with "## Accusation (round 2)", the stamp had passed on the file,
    // and the check read as a broken gate. Say what to do instead.
    const near = lines.find((l) => l.trimEnd().toLowerCase().startsWith(section.toLowerCase()));
    fail(
      near
        ? `the record has ${JSON.stringify(near)} where the heading must be exactly "${section}". Do not edit the record in the PR body by hand: regenerate the body with pr-body.sh --update.`
        : `the record is missing the section "${section}". Put the record in the PR body with pr-body.sh (--update for an open PR), not by hand.`,
    );
  }
}

// Only records drafted by 0.13 or later (they name the version): a record
// stamped before the rule existed stays valid while its PR is open.
if (!docsOnly && lines.some((l) => /^objection \d+\.\d+\.\d+; config /.test(l))) {
  const missing = missingRulings(record);
  if (missing.length) fail(`the Judge section has no ruling for finding(s) ${missing.join(", ")}.`);
}

const verdicts = lines.filter((l) => /^VERDICT: /.test(l));
if (verdicts.at(-1) !== "VERDICT: APPROVED") fail("the record's last verdict is not APPROVED.");

if (!docsOnly) {
  // The judge's structured count is the authority (same rule as stamp.sh);
  // the word scan below only cross-checks it against its own list.
  const counts = lines.filter((l) => /^OPEN: BLOCKER=\d+ HIGH=\d+$/.test(l)).at(-1);
  if (!counts) fail("the record is missing the line 'OPEN: BLOCKER=<n> HIGH=<n>'.");
  if (counts !== "OPEN: BLOCKER=0 HIGH=0") fail(`the record is APPROVED with ${counts}.`);
  const start = lines.indexOf("## Open");
  const open = [];
  for (let i = start + 1; i < lines.length && !/^## /.test(lines[i]); i++) open.push(lines[i]);
  if (open.some((l) => /^\s*([-*]|\d+[.),]?)?\s*,?\s*[*_]*(blocker|high)([^a-z-]|$)/i.test(l)))
    fail("the record is APPROVED but lists a BLOCKER/HIGH finding under Open.");
}

console.log(`objection: APPROVED record for ${head.slice(0, 7)} against ${base}.`);
