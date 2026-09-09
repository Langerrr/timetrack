# Review evidence

Runtime acceptance commit: `473ddc6`. Reports below preserve each reviewer’s scope and verification limits.

---

## Final repair acceptance

# Scoped final-fix review

Reviewed immutable `5e5e758..473ddc6`, its review package, `final-fix-report.md`, the I1 finding in `completion-review.md`, and the controller's accepted representation ruling. Scope is I1 closure and material regressions introduced by this repair, not another review of unchanged accounting or capture code.

## Strengths

- Retaining original session-less transitions preserves the intervening solo boundaries needed when a session first appears after rollover. Both ancestor/descendant directions now reconstruct with the same evidence as the raw log.
- Already-carried sessions skip projection at or before their retained heartbeat. This prevents old terminal commands from replaying across session-specific boundaries that have already been settled.
- The repair is confined to effort grouping/state carry and documentation. Machine grouping, category normalization, capture, and the standalone loader are unchanged.
- Tests compare exact report columns, not just grand effort or rounded output, and exercise real CLI rollover before the first session prompt arrives.

## Finding disposition

**I1 — ADDRESSED.** The original effort-inflation case remains `(500, 2800, 0, 3300, 3600, 0)` before and after incremental rollover; the category-only case remains `(1900, 300, 0, 2200, 3600, 0)`. Reverse ancestor/descendant arrangements, all four report views, repeated/advancing rollover, and known-session replay protection pass. Retained transitions remain one copy of each original mode row across rollovers; the repair does not retain raw hook history.

## Issues

- **Critical:** none found.
- **Important:** none found in this scoped repair.
- **Minor:** no new actionable issue raised.

The accepted cost remains explicit in README and the binding spec: transition history grows with session-less mode commands. This is a deliberate representation choice, not an unresolved bounded-state requirement. Previously discarded transitions cannot be recovered from already-compacted logs. Other accepted/deferred limitations retain the dispositions in `completion-review.md`; this repair does not reopen them.

## Verification actually executed

- `PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=lib:tests/python python3 -m unittest test_scoped_carry test_cleanup`: **9 passed**, including the actual CLI rollover comparisons across project/day and detail views.
- **1,000 deterministic synthetic sequences** with nested terminal scopes and fixed session locations: all six aggregate columns preserved through incremental and advancing rollover.
- **1,000 additional deterministic synthetic sequences** mixing session-specific and path-scoped mode commands: all six columns preserved through incremental and advancing rollover.
- `git diff --check 5e5e758..473ddc6`: passed.

The additional probes used in-memory rows and existing compaction/report APIs. CLI tests used temporary homes. Python bytecode was disabled. No live `~/.timetrack` operations or source/index/HEAD mutations; this report is the only file written for this re-review. Full suites remain the root controller's independent verification responsibility rather than duplicated here.

## Readiness

**Ready for integration, subject to the root controller's final full-suite verification.** I1 is closed, and this scoped review found no new blocking regression. The integrated product has no remaining blocking finding from the preceding final review and this repair review.

---

## Final integration review before repair

# Final integration review

Reviewed immutable `61e4162..5e5e758`, including its review package, binding design and both plans, progress ledgers, cleanup brief/triage/report, accounting-fix review, and standalone-loader repair evidence. This pass concentrates on cleanup `8ea6162..5e5e758` and its interaction with the accepted accounting and shell split; earlier scoped reviews remain evidence for unchanged work.

## Strengths

- Live effort and carried presence use the same grouping function and existing mode-scope matcher. Machine reconstruction and its stream identity remain unchanged.
- The standalone hook retains the 20-column schema with `-` in beat mode, and rollover validation accepts both that value and old stamps. Explicit transitions, automatic solo classification, and CLI cache inspection remain wired.
- Explicit lock failure now identifies the lock and its recovery action; invalid TSV keys and failed cache writes remain distinguishable. The focused subprocess tests verify those actual failure paths.
- Project coverage normalization and stable-versus-pending machine accounting retain the previously reviewed R1–R7 repairs.

## Critical issues

None found.

## Important issues

### I1 — Scoped transition history disappears before a newly observed session can use it

**Locations:** `lib/ttreport/state.py:49` and `lib/ttreport/state.py:52`, interacting with backward projection at `lib/ttreport/effort.py:74`–`88`.

State keeps only the last heartbeat of each terminal path. `presence_groups` later projects retained terminal heartbeats into a session first observed after rollover, using that session's first location for older timestamps. Earlier solo transitions on an overlapping ancestor/descendant path may already have been discarded. The reconstructed paired span then crosses an interval that was explicitly solo. Canonical coverage can union the new interval but cannot remove its invented paired credit.

Minimal reproduction, one machine/project, `C=86400` and default settings:

| Time | Event | Path | Session |
| --- | --- | --- | --- |
| C−4900 | terminal paired | api/nested | - |
| C−4400 | terminal solo | api | - |
| C−900 | terminal solo | api | - |
| C | human prompt | api/nested | s1 |

With all four observations available, `(PAIRED, CHECKIN, MANUAL, EFFORT, AGENT, TOOL)` is **`(500, 2800, 0, 3300, 3600, 0)`**. Compact the first three at C and then append the prompt: **`(1800, 2700, 0, 4500, 3600, 0)`**. This adds twenty minutes of effort and turns explicitly unattended time into paired credit. Independently reproduced through actual `bin/tt report` rollover in a temporary `TT_HOME`: EFFORT changes **0h 55m → 1h 15m**, PAIRED **0h 08m → 0h 30m**; machine columns stay unchanged.

A second four-row case isolates category corruption: paired on `api` at C−2100; solo on `api/nested` at C−800; paired there at C−500; first prompt there at C+100. Raw `(1900,300,0,2200,3600,0)` becomes `(2200,0,0,2200,3600,0)` after incremental rollover.

**Suggested repair:** preserve sufficient overlapping scoped-transition/boundary information for later session projection, or settle scoped presence before discarding that information. A last-heartbeat-only representation per independent terminal path is insufficient when older ancestor/descendant heartbeats can later be joined. Do not solve this by dropping the required first-session-after-rollover heartbeat or by modifying machine grouping. Add both nested-scope directions as raw/incremental/repeated-rollover regressions, asserting every category and total across project/day and detail views, plus actual CLI rollover.

## Minor issues and deferred-item triage

No new cosmetic issue warrants a repair request. The root controller independently identified one trailing space in the original plan and is handling it with completion-document updates.

Cleanup triage items 1 and 3–12 are addressed by the inspected changes and focused evidence. Item 2 is **not complete** because of I1. The previously parked session-less-return defect is fixed for the existing covered cases but fails this required interaction with nested scopes and a newly observed session.

The ledger's session-changing-project episode attribution remains an explicitly deferred limitation: an episode retains its initial attribution. This cleanup preserves that choice. Legacy duration-only overlap is unknowable and remains opaque/additive; partial-day clipping of such totals remains outside the shipped day-boundary CLI interface. Missing or ambiguous child telemetry still cannot justify arbitrary own-tool attribution. Declined typing/performance cleanup stays declined; none is a new merge blocker.

## Verification actually executed

- `PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=lib:tests/python python3 -m unittest test_cleanup test_cli.TestReportCLI.test_standalone_hook_rollover_honors_config_then_environment_max_gap test_events test_intervals test_modes`: **59 passed**.
- Additional deterministic synthetic nested-scope sequence probes found the two I1 cases; minimized and independently reran both with exact seconds.
- Actual CLI baseline-versus-incremental rollover probe reproduced the twenty-minute EFFORT inflation in a fresh temporary home.
- Read-only source/diff review, with no source, index, or HEAD mutation. No live `~/.timetrack` reporting or compaction, and Python bytecode disabled. This report is the only workspace file written by the reviewer.

Full Python/sh/dash suites were deliberately left to the root controller rather than duplicated. Their green results do not exercise I1.

## Readiness

**Not ready to merge.** One Important accounting defect remains in authorized cleanup. Repair I1 and re-review its scoped-state behavior before marking either the cleanup or integrated product complete.

---

## Final repair implementation

# Final review repair I1

Based on `5e5e758`; repair commit `473ddc6` (`Preserve scoped solo boundaries for sessions first seen after rollover`).

The last heartbeat of each terminal path did not preserve intervening solo boundaries on overlapping scopes. A session first observed after rollover could inherit an old parent or nested heartbeat through a discarded boundary, changing categories and sometimes inflating effort.

The repair retains session-less mode transitions unchanged across rollover. It does not retain raw hook history. Already-carried sessions skip terminal heartbeat projection at or before their retained heartbeat, preventing settled session-specific episodes and boundaries from being replayed. Mode resolution, category priority, canonical coverage, and machine grouping are unchanged.

Accepted representation choice: retained transition history grows with terminal mode commands. The controller explicitly approved this cost rather than introducing a new overlap-frontier architecture. README and binding spec state that cost. Repeated rollover preserves one copy of each original transition; it does not multiply the history. Existing compacted data cannot recover transitions that an earlier version already discarded.

Focused RED: the final regression file ran against an immutable temporary export of `5e5e758`, with 36 failing subcases. Cases include both review examples in both ancestor/descendant directions, exact seconds for every report column in project/day and detail views, initial/repeated/advancing incremental carry, known-session replay protection, and actual CLI rollover in temporary homes. The CLI baseline reads all observations before rollover becomes due; the incremental home rolls over before the first session prompt arrives. This distinction reproduces the real defect rather than comparing two already-compacted reports.

Focused GREEN: 9 tests passed. Final full suite: 149 Python tests passed, 214 shell assertions passed under sh, and 214 passed under dash; each shell suite used a distinct TMPDIR. All four copied-snapshot report views preserved every column across CLI rollover and repeat reporting. Source syntax checks under sh/dash and `git diff --check` passed. Evidence logs: `/tmp/tt-scoped-red.log`, `/tmp/tt-scoped-green.log`; final suite logs will be `/tmp/tt-i1-python.log`, `/tmp/tt-i1-sh.log`, `/tmp/tt-i1-dash.log`.

Scope excludes the root controller's whitespace-only plan edit. No push or merge. Prepared copied-snapshot verification only; live `~/.timetrack` is never reported or compacted.

---

## Accounting repair acceptance

# Accounting repair re-review

Reviewed immutable range `5550236..bde9ae6`, using `review-5550236..bde9ae6.diff`, the current implementation, `accounting-fix-report.md`, and the accepted decisions in `accounting-fix-brief.md`. Scope is closure of R1–R7 and material regressions in this repair, not a new whole-branch review.

## Strengths

- A single project-level normalization now owns effort category priority and deterministic detail allocation. Reports group its output, so presentation no longer decides whose timelines union.
- Canonical coverage retains the information needed to reconcile late manual entries and overlapping machine histories. Shell compaction routes that coverage back through reconciliation, while opaque totals remain additive.
- The machine reconstruction explicitly separates stable contributions from provisional estimates. Openings, closed-tool coverage, pending closed turns, and continuation seeds provide reconstruction context without retaining raw hook history.
- Regression cases exercise incremental arrival after rollover, repeated and advancing cutoffs, distinct machine frontiers, reset versus Codex compaction, and observed child ownership. These directly address the failed invariants from the original review.

## Findings disposition

| Finding | Status | Review evidence |
|---|---|---|
| R1 — scalar effort history loses project union | **ADDRESSED** | `coverage.normalize` produces disjoint project coverage before grouping, applies category priority and lexicographic normalized subpath allocation, and coalesces runs. `with_history` merges new evidence with stored coverage; `bin/tt` sends existing coverage into compaction. Overlapping subpaths, historical manual additions, and canonical bounded output regressions pass. |
| R2 — premature rollover finalization and state expiry | **ADDRESSED** | Compaction reconstructs the available past and posts only `stable_agent`/`stable_tool`. Heartbeats and unresolved brackets no longer expire by age. Pending state preserves the context needed for later subtraction and pre-cutoff credit. Incremental heartbeat, long matched turn/tool, multiple rollovers, closed tools during an open turn, pending closed-turn compaction, and solo attribution regressions pass. |
| R3 — day aggregation unions different projects | **ADDRESSED** | Report normalization happens before `_collect`; display buckets sum already normalized project entries. The two-project case gives the same portfolio effort in project/day modes, with detail on/off, before and after rollover. |
| R4 — shared floor suppresses another machine | **ADDRESSED** | The global floor and its use in reporting/compaction are removed. Worker and heartbeat identities retain machine/session ownership during reconstruction. The different-machine-frontiers regression preserves both sources' effort and machine contributions. |
| R5 — preceding Stop not carried | **ADDRESSED** | `last_close` is returned, serialized as continuation state, restored by reconstruction, and expired according to the bounded continuation rule. The cross-cutoff prompt/Stop/Stop regression passes for direct, repeated, and incremental rollover. |
| R6 — SessionStart does not reset brackets | **ADDRESSED** | Ordinary SessionStart closes and resets that stream's open brackets and continuation seeds, with the unmatched cap applied. Codex `source=compact` explicitly preserves the lifecycle. Both branches pass the regression with carried openings. |
| R7 — subagent own-tool subtraction missing | **ADDRESSED** | Tools include worker identity, spawned workers enter the subtraction pass, and observed child tools associate with the eligible spawning bracket. Per-opening `unassociated` state prevents later binding from claiming earlier ambiguous work. Own-tool subtraction and both ambiguity regressions pass across rollover. |

## Issues

### Critical

None found in this scoped re-review.

### Important

None found in this scoped re-review.

### Minor

No new polish items raised. The separately scheduled cleanup remains outside this repair.

## Verification

Independently executed `PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=lib:tests/python python3 -m unittest test_accounting_repairs`: **16 passed**. These focused tests exercise the named R1–R7 doubts, including all six aggregate columns across the four display combinations and incremental reconstruction where relevant. `git diff --check 5550236..bde9ae6` also passed.

Reviewed the two added CLI regressions and parser/shell validator changes. Did not rerun full suites or copied-log verification; their reported evidence remains **134 Python / 204 sh / 204 dash**, with all four copied-log views stable. Used synthetic in-memory tests only, with bytecode writes disabled. No live `~/.timetrack` access and no production edits.

## Recommendations

Proceed to the behavior-preserving standalone hook split using the repaired baseline and its pinned assertion names. Keep the already scheduled cleanup after the split.

The accepted limits remain explicit: lost timestamp coverage in legacy duration totals cannot be reconstructed, and ambiguous or missing child telemetry cannot justify arbitrary worker attribution. Neither is an unresolved R1–R7 implementation finding.

## Assessment

**Ready to merge? Yes, for this accounting repair.**

All seven findings are addressed by the implementation and focused regression evidence. No new Critical or Important breakage was identified within this fix; the standalone split can begin.

---

## Shared-helper extraction acceptance

### Spec Compliance

- ✅ Spec compliant. `bin/tt:5-8` preserves loader defaults and the environment-precedence marker; `bin/tt:18-35` resolves the executable, honors a `TT_LIB` directory that contains `tt-common.sh`, falls back to the bundled helper, and removes its temporary loader variable. The moved capture/storage closure is defined in `lib/tt-common.sh:5-670`, while hook-only parsing and `cmd_hook` remain in `bin/tt` for Task 2.
- ⚠️ Evidence limitation: the report records all required suites at the baseline counts and assertion names, but also discloses an earlier unexplained dash concurrent-beat run with 19/20 assertions before a passing repeat. The lock and append bodies are unchanged in this diff (`lib/tt-common.sh:611-635`), so this is not evidence of an extraction defect; retain it as concurrency-validation context.

### Strengths

- The TT_LIB bootstrap preserves the legacy Python-only override case without allowing it to suppress the bundled shell helpers (`bin/tt:29-35`).
- Shared functions retain their complete storage path: `tt_append_row` still reaches compaction, validation, locks, and gitignore handling through definitions in `lib/tt-common.sh:339-670`.
- The shared file has no load-time assignments; sourcing it twice only redefines functions, preserving the loader-captured `TT_MAX_ACTIVE_GAP_SET` marker (`bin/tt:5-8`, `lib/tt-common.sh:1-670`).

### Issues

#### Critical (Must Fix)

- None.

#### Important (Should Fix)

- None.

#### Minor (Nice to Have)

- None.

### Assessment

**Task quality:** Approved

**Reasoning:** The diff is a pure helper relocation with the shared dependency closure retained and bootstrap semantics explicitly preserved. No focused doubt required rerunning a suite.

---

## Standalone-hook bootstrap acceptance

### Spec Compliance

- ✅ Original finding addressed. `bin/tt-hook:5-8` now initializes both the pre-default environment marker and default value before sourcing the common helpers, matching the CLI loader contract required by `tt_max_active_gap`.

### Strengths

- The regression test drives the standalone entry point across a real rollover, asserts that compaction produced a marker, and distinguishes config `6000` from environment override `120` through the resulting continuation state (`tests/python/test_cli.py:150-190`). This detects both the prior hidden internal failure and an incorrect precedence implementation.
- The change is narrowly limited to the missing bootstrap state and its regression coverage (`review-62d4c0e..8ea6162.diff`).

### Issues

#### Critical (Must Fix)

- None.

#### Important (Should Fix)

- None.

#### Minor (Nice to Have)

- None.

### Assessment

**Task quality:** Approved

**Reasoning:** The fix restores the loader invariants before `set -u` shared-helper use and the failing-first/green test verifies the exact rollover and precedence behavior that exposed the regression. The recorded focused test and 135-test Python suite are sufficient for this fix-only re-review.

---

## Cleanup implementation and verification

# Final cleanup

Scope: cleanup after the approved accounting repairs and two-task shell split, based on `8ea6162`. Commit: `5e5e758` (`Credit terminal mode heartbeats and simplify hook capture`). No push or merge.

| Triage | Result |
| --- | --- |
| 1 | Explicit mode failures distinguish invalid TSV key fields, home creation, lock timeout, and cache write failure. Timeout names the lock and says “if no other tt is running, remove it”. Automatic capture remains quiet. |
| 2 | Shared `presence_groups` is used by effort reconstruction and state carry. Session-less terminal mode heartbeats reach sessions covered by the existing mode scope matcher, at their observed working directory. Machine grouping is unchanged. Terminal presence remains available independently; canonical project coverage unions any overlaps. Solo episode attribution survives projection and rollover. |
| 3 | Standalone capture omits per-beat mode lookup and writes `-` in column 7 of the existing 20-column beat. Rollover validation accepts that value and legacy stamps. Explicit/automatic mode rows, CLI cache reads, and automatic solo behavior remain intact. README and shell assertions reflect the change. `tt_mode` remains because `debug-mode` uses it. |
| 4 | Comment identifies column 11 as the last mandatory parse field. |
| 5 | Removed the outer `tt_abs` from `tt_set_mode`; use the normalized `cm_path` returned in POSIX function-global state by `tt_cache_mode`. Helpers used during cache writes do not overwrite it. |
| 6 | Removed formatter clamp after verifying spans are nonnegative and `_collect_totals` rejects stored durations <=0 before accumulation. |
| 7 | Removed unreachable manual-span heartbeat branch. State now uses shared presence grouping, which excludes spans. |
| 8 | Added over-wide ordinary event and empty-session fallback tests. |
| 9–10 | Added exact start/end and duplicate day-boundary cases. |
| 11 | Asserted tool-event columns 19 and 20 are both `-`. |
| 12 | Added malformed-mode test proving effective mode and next-change behavior remain intact. |

Focused RED/GREEN: terminal paired return produced 0 instead of 900 seconds; incremental rollover produced 100 instead of 1000; nested return interval was absent. All pass after grouping changes. Lock diagnostic test failed because the lock path and recovery hint were absent; it now passes and distinguishes invalid path/cache writer failures. Full integration exposed beat validation still requiring a stamp; existing standalone hook-rollover regression passed after accepting `-`.

Coverage includes multiple sessions, nested/sibling paths, unrelated machine/project, earlier paired-to-solo transition, no retroactive paired credit, repeated and incremental compaction, and a session first observed after rollover. Project totals explicitly verify that overlapping terminal/session solo episodes are not double-counted. Carry remains one heartbeat per presence key; machine reconstruction is untouched.

Final verification: 146 Python tests passed; 214 shell assertions passed under sh and 214 under dash, each shell using a unique TMPDIR. Source syntax checks under sh/dash and `git diff --check` passed. All four copied-log report views preserved every column across actual CLI rollover and repeat reporting. Logs: `/tmp/tt-cleanup-python.log`, `/tmp/tt-cleanup-sh.log`, `/tmp/tt-cleanup-dash.log`. Copied-log verification runs only against the prepared immutable snapshot and fresh temporary copies; live `~/.timetrack` was not reported or compacted.

No triaged item declined. The previously declined performance and typing changes remain out of scope. No known remaining cleanup defect; independent final review follows.
