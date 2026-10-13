# Eight more real bugs: Python, Rust, TypeScript (2026-10-13)

The fresh fifteen had no Python, Rust or TypeScript case. Eight more,
added to [`eval/real/cases.jsonl`](../real/cases.jsonl) the same way
(culprits committed after 2026-07-01, named by the commit that fixed
them, from repositories the eval had not used), and measured before any
change was made for them:

| case | language | expected |
|---|---|---|
| Gallery-Downloader-ef3df41 (a gallery-dl fork) | Python | HIGH |
| scapy-23808d9 | Python | MEDIUM |
| streamlit-07d085f | Python | HIGH |
| arrow-rs-e704ad4 | Rust | MEDIUM |
| fish-shell-abaf54f | Rust | HIGH |
| slint-37cac19 | Rust | MEDIUM |
| hls.js-a03d5b1 | TypeScript | HIGH |
| gbrain-8b432b1 | TypeScript | MEDIUM |

Four of the fixes name the culprit's pull request, not its commit
(scapy, streamlit, arrow-rs, gbrain); the case uses that PR's squash
commit. One candidate was dropped: its fix was a large feature commit.

## Result

objection main (3d47e5b: 0.24.3 and the same-line section) against the
plain prompt, same day, same model (`claude-sonnet-5-5`), four runs
each, interleaved. Graded by hand, then blind by `claude-opus-5-5` (the
method in [2026-10-13-fresh-real-bugs.md](2026-10-13-fresh-real-bugs.md)),
which agreed on 63 of 64 answers:

| | right severity | found at any severity |
|---|---|---|
| **objection** | **9 of 32** | **16 of 32** (blind: 17) |
| plain prompt | 4 of 32 | 8 of 32 |

Per case, objection / plain prompt, found at any severity: Gallery 4 /
4 (at the right severity 3 / 0: the plain prompt said MEDIUM),
arrow-rs 4 / 4, hls.js 3 / 0 (all LOW), fish-shell 3 / 0 (MEDIUM or
LOW, for a crash), scapy 1 / 0, gbrain 1 / 0, streamlit 0 / 0, slint 0 / 0.

These are harder than the fresh fifteen for both sides: the plain
prompt found a quarter of them, objection half. Most objection catches
here are under-rated: hls.js (the start-code scan drops a NAL's
trailing zeros) was found three times and rated LOW each time, and the
fish-shell crash (a `char` passed to `%s`) was rated MEDIUM at most,
hedged on whether the formatter accepts it. Nobody found streamlit
(the body already read by a middleware) or slint (a link dropped when
another binding replaces the wrapper); both need code the diff does
not show.

## Scoring

The automatic count read 19 against 10. Every one of its 16 `(line
only)` catches was a row about another defect on a bug line (the scapy
gap size, the slint fresh property, the gbrain slot window), so the
hand count is lower. The scapy, slint and gbrain patterns were then
narrowed so that their words match only the defect the fix repaired;
that does not change the hand count.

Eight cases, four runs, one model. The expected severities were set by
a model and checked by hand.
