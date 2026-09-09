# Effort accounting and hook split — completion

Both plans and the authorized cleanup are implemented on `effort-machine-time`.
Runtime acceptance commit: `473ddc6`. Base: `61e4162` (`main`).
Implementation and review are complete; branch integration remains the user's choice.

The subsequent [Codex runtime review](2026-09-08-codex-hooks-review.md) fixed
shutdown and asynchronous-child accounting, updated stale skill instructions,
and verified 156 Python / 214 sh / 214 dash checks. Its compatibility verdict
is partial: native Codex goal activation supplies no goal-start hook signal,
so automatic solo mode for native goals remains an explicit integration gap.

## Result

Personal effort is reported as PAIRED, CHECKIN, and MANUAL with their disjoint
sum EFFORT. AGENT and TOOL remain independent machine measures. Effort unions
within each project across sessions, machines, and subpaths; different projects
remain additive, including day reports. Reporting and compaction use Python
3.8-compatible standard-library code; the old awk reporter is retired.

`bin/tt-hook` captures events, `bin/tt` serves the human CLI, and
`lib/tt-common.sh` holds shared helpers. Both hook manifests and generated
configuration use the standalone entry point; `tt hook` remains compatible.
The split preserved all 204 baseline shell assertion names and added focused
entry-point checks. Runtime Python was untouched during the split.

Cleanup restores useful mode-lock failure diagnostics, counts terminal mode
commands as presence for covered sessions, and removes the unused per-beat mode
lookup. New beats retain twenty columns with `-` in column 7; explicit and
automatic mode transitions, old stamped rows, and mode caches remain supported.

## Completed work

| Work | Commits |
| --- | --- |
| Original Tasks 1–9 and initial Task 10 work | Inherited through `499adde` |
| Finish Task 10 and retire awk reconstruction | `5550236` |
| Repair project union, rollover state, machine attribution | `bde9ae6` |
| Extract shared helpers | `50926aa` |
| Standalone hook and loader regression fix | `62d4c0e`, `8ea6162` |
| Cleanup triage implementation | `5e5e758` |
| Nested-scope rollover repair (I1) | `473ddc6` |

## Independent verification

On runtime commit `473ddc6`:

- `PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=lib python3 -m unittest discover -s tests/python`: 149 passed.
- `sh tests/run.sh`: 214 run, 0 failed.
- `dash tests/run.sh`: 214 run, 0 failed. Shell runs used separate temporary roots.
- All four project/day × detail report views preserved every column through
  actual CLI rollover and repeat reporting on a copied log snapshot.
- Both shells accepted syntax of both entry points and the shared library.
- All eleven runtime Python modules passed Python 3.8 grammar parsing. This is
  a syntax compatibility check, not execution on a Python 3.8 interpreter.
- Whitespace checks passed, including the complete branch range after removing
  an inherited trailing space in the plan.

The original accounting review's seven findings, the split review's loader
finding, and the final integration review's nested-scope carry finding were
fixed and re-reviewed. See [review evidence](2026-09-08-review-evidence.md)
for the final verdict and the scoped acceptance reports.

## Decisions and limits

Exact effort coverage is retained through compaction because scalar durations
cannot recover overlap. Same-category overlapping subpaths use the smallest
normalized path as the deterministic owner. Pending worker and heartbeat facts
remain available until later evidence can resolve them. Session-less mode
transition history is also retained so future sessions can reconstruct nested
scopes; this state can grow with the number of mode commands. A terminal command
retains its own presence and reaches covered session locations; project coverage
removes overlapping credit.

A solo episode retains its initial project/path attribution when a session
changes location mid-episode. Legacy duration-only totals remain additive: their erased timestamp coverage
cannot be recovered. Missing or ambiguous child-worker telemetry is not assigned
to an arbitrary worker. One earlier split verification observed 19 of 20
concurrent beats before passing on repeat; unchanged lock code and later full
runs passed. This earlier observation is retained as a validation limitation.

Verification did not report or compact live `~/.timetrack`. No push, merge,
installed-plugin update, or live-data migration was performed.

The [complete decision record](2026-09-08-decisions.md) preserves inherited and
continuation rulings, including corrections and superseded decisions.
