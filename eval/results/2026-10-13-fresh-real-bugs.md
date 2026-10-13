# Fifteen fresh real bugs (2026-10-13)

Every real bug before this one was also used to tune objection: the
diff-first brief, ten lines of context and the other-uses section were
each kept because they did better on the same fifteen cases. This run
is the check against that: fifteen regressions added to
[`eval/real/cases.jsonl`](../real/cases.jsonl) after objection 0.24.2
shipped, none of them seen while tuning, from repositories the eval had
not used. Every culprit was committed between 2026-07-07 and 2026-09-29,
and each was named by the commit that fixed it.

| case | language | expected |
|---|---|---|
| rcc-cb4037d | C | HIGH |
| v8-ea39022 | C++ | BLOCKER |
| MPD-1281129 | C++ | HIGH |
| code_saturne-0bc2a3a | C++ | BLOCKER |
| cilium-e27ce9e | Go | HIGH |
| neovim-b296666 | C | HIGH |
| kotlin-5a670d3 | Kotlin | MEDIUM |
| orm-d4dc768 | PHP | MEDIUM |
| quarkus-31180c8 | Java | MEDIUM |
| BasicSync-2d70b82 | Kotlin | MEDIUM |
| NodeBB-6f5607e | JavaScript | HIGH |
| jma-ctf-75241ad | Lua | HIGH |
| nuttx-apps-fabafbc | C | HIGH |
| tailscale-027e249 | Go | HIGH |
| odoo-7af38c9 | JavaScript | HIGH |

Five candidates were dropped before any run: the bug was not in the
culprit's own diff (fooyin), needed the fix to see (kanzi), was a date
format nobody could judge from the code (encore), was spread over a
large commit (hls.js), or the fix named a PR, not a commit (uv).

## Result

objection 0.24.2 (main at e15af76) against the plain prompt, same day,
same model (`claude-sonnet-5-5`), four runs each, interleaved,
hand-graded:

| | right severity | found at any severity |
|---|---|---|
| **objection 0.24.2** | **38 of 60 (63%)** | **43 of 60 (72%)** |
| plain prompt | 24 of 60 (40%) | 37 of 60 (62%) |

Per case, objection / plain prompt, at the right severity: rcc 1 / 0,
v8 4 / 3, MPD 3 / 0, code_saturne 0 / 0, cilium 2 / 1, neovim 0 / 0,
kotlin 4 / 4, orm 3 / 2, quarkus 0 / 0, BasicSync 4 / 4, NodeBB 3 / 0,
jma-ctf 4 / 4, nuttx-apps 2 / 0, tailscale 4 / 4, odoo 4 / 2.

The gap held on cases it was not tuned on: 14 runs at the right
severity, against 15 on the tuned fifteen the same week (52 against 37,
2026-10-11). As before, most of it is severity: objection rated HIGH
what the plain prompt found at MEDIUM (MPD, odoo, cilium). Two it found
and the plain prompt never did: NodeBB (a remote category's cid passed
to the privilege check, 4 of 4 against 0) and nuttx-apps (`boot` with
no argument now resolves a NULL path, 2 against 0).

Nobody found three: quarkus-31180c8 (every run on both sides answered
NO FINDINGS on a one-line `Date` serializer change), neovim-b296666
(every run saw `shorten_fnames` free the buffer names, none saw that a
read in progress still holds them) and code_saturne-0bc2a3a (the
initialization removed from a shared function and re-added to all but
one caller; runs named a different caller, or none).

## Grading

Five answers ended in ERROR (the same fixtures on both sides in the
same pair, a transient failure) and were run again the same day.

Graded by hand, the same way for both sides: a run counts when a row
describes the defect the fix commit repaired, at the expected severity
or above. Two calls were close:

- cilium-e27ce9e: the fix says the cache reports a hit with an empty
  CID name; runs that said a CID missing from the store fails every
  pod event and the pod is never placed were counted, since that is
  the same path and the same effect.
- tailscale-027e249: the fix repairs both the error the culprit
  discarded and a hang (the culprit waits for both copy directions,
  and a failed one can leave the other blocked). The case was first
  written with the first one only and was widened to both after
  reading the fix. Counting only the first: 35 against 23.

The automatic scorer read 39 against 21. It listed 7 catches as
`(line only)`; checked by hand, 6 were about the bug and one (orm,
objection) was about another defect on the bug line, so the hand count
is one lower for objection. It missed plain-prompt catches cited without
a line number (`linkKlibs.kt, SortingKey.compareTo`,
`SchemaTool.php, conflict branch`) or one line off
(`endpointslice.go:~491`), which the hand count adds.

## Limits

Fifteen cases, four runs each, one model, one effort. The candidates
were found and the expected severities set by a model and checked by
hand; no Python, Rust or TypeScript case made the cut.
