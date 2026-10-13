# Context outside the diff (2026-10-13)

A real-bug fixture keeps only the files the culprit touched, so its
brief never sees the rest of the repository. In real use the brief's
`git grep` runs over the whole repository. The question: does the
missing context explain the catches objection misses or under-rates?

Eight cases from the fresh and the Python/Rust/TypeScript sets, chosen
because objection missed them or rated them below the expected
severity: fish-shell-abaf54f, slint-37cac19, neovim-b296666,
cilium-e27ce9e, MPD-1281129, streamlit-07d085f, quarkus-31180c8,
hls.js-a03d5b1. Each was rebuilt as the full repository at the culprit,
with `origin/main` at its parent, and the accuser ran four times on the
brief (`claude-sonnet-5-5`, same day). Graded by hand against the
fixture runs in [2026-10-13-grades.json](2026-10-13-grades.json).

## Full repository: no gain

No case went from missed to caught, and none moved up in severity.
fish-shell was found in 3 of 4 runs both ways, never at HIGH; slint,
neovim, streamlit and quarkus stayed at 0; cilium was found in every
run both ways (2 of 4 at HIGH on the fixture, 0 of 4 on the full
repository, within run-to-run noise); MPD was at HIGH in 3 of 4 both
ways; hls.js never reached the expected severity either way.

The reason was visible in the briefs. "Definitions the diff calls" took
the first 15 names the added lines call, and on a full repository most
of them are defined somewhere: fish-shell got `allowed`, `stdin` and
`last`, neovim `cwd` and `clear`, slint `pin` and `unwrap`, streamlit
`warning`. The definition the bug turns on was not among them.

## Upper bound: the right definition placed by hand

On the three cases where one definition decides the bug, that
definition was added to the full-repository brief by hand (four runs):

| case | definition added | at the expected severity |
|---|---|---|
| fish-shell-abaf54f | `wgettext_fmt!` (a macro, never matched) | 3 of 4 (HIGH; was MEDIUM or LOW) |
| slint-37cac19 | `link_two_way_with_map` | 0 of 4 |
| neovim-b296666 | `shorten_fnames` | 0 of 4 |

So the right definition can matter (fish-shell), but it is not enough
on its own: on slint and neovim the accuser read it and still did not
reach the bug.

## The change

The section now looks up names every codebase calls (std methods,
logging, Rust wrappers such as `unwrap` and `into_iter`) last, as filler
after every other name, matches Rust macro calls (`name!(`, `name![`,
`name!{` against `macro_rules! name`), skips test functions unless the
change is to tests, and ranks snake_case and camelCase names first, then
bare or path calls, then methods on an object (a name takes its best
rank); within a rank, the order of the diff. It looks up to 20 names,
not 15, and stops once it has 8 definitions. On the same full
repositories it now picks:

| case | before | after |
|---|---|---|
| fish-shell-abaf54f | allowed stdin call_error last offset | localizable_consts wgettext_fmt call_error wgettext offset length |
| slint-37cac19 | pin apply_pin abs unwrap | apply_pin SharedString pin |
| neovim-b296666 | cwd normalize clear | normalize cwd clear |
| cilium-e27ce9e | getCIDForCEP GetCEPNameFromPod GetAsMap cidResourceKey podResourceKey | getCIDForCEP GetCEPNameFromPod GetAsMap cidResourceKey podResourceKey |
| streamlit-07d085f | form warning | patch_config_options MemoryUploadedFileManager create_upload_routes get_files |
| hls.js-a03d5b1 | appendUint8Array parse parsePES | appendUint8Array parsePES |

Four accuser runs with the new brief (a first version, whose fish-shell
brief also had `into_iter` and the same `wgettext_fmt` definition, and
which dropped the generic names instead of putting them last): fish-shell found 3 of 4, 1 at
HIGH (0 before, 3 with the hand-placed definition); cilium 4 of 4, 2 at
HIGH; slint and neovim still 0. Four runs are too few to call the
fish-shell move a gain. The change ships because the definitions it
moves to the end said nothing about any of these diffs, not for a
measured catch.

Not changed: on a full repository, "Other uses of the names the diff
changed" also picks up docstring words (`read`, `values`) and test
files. Left for later.
