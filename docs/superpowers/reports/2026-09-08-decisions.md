# Complete decision record

These are the recorded rulings from Claude Code and the Codex continuation, in execution order. Historical entries are reproduced verbatim, including their stated costs and corrections; a later reversal supersedes the earlier decision. In particular, state carry was implemented after the Task 9 reversal, the parked terminal-return defect is now fixed, and new coverage history replaced scalar-only effort history. The completion report describes the accepted final behavior.

## Original plan and accounting repairs

Ruling: F1 — rewrite Task 3's final assertion as a plain env-prefixed hook call. It was malformed shell testing a real requirement; the requirement stands, the assertion is replaced. Cost if wrong: the configurable trigger list ships untested.

Ruling: F2 — mode rows stay heartbeats (the spec names them), and Task 6's three solo expectations are corrected upward by one TT_CHECKIN_WINDOW each, since `tt solo` is itself a moment of presence. Cost if wrong: solo effort over-credits by 20 minutes per mode change.

Ruling: F3 — ModeTimeline.at takes (stream, when, project, subpath). The stream key collapses to a session id and discards the path, so path-scoped transitions are unresolvable without it. Tasks 4 and 6 both updated. Cost if wrong: `tt solo` at a project root stops reaching nested sessions.

Ruling: F4 — Task 8 adds tt_day_boundary_epochs and KEEPS tt_day_boundaries; Task 9 deletes tt_day_boundaries when it rewires compaction off awk. Cost if wrong: compaction breaks between tasks 8 and 9.

Ruling: F5 — compact.py gains a main() and __main__ guard taking the same flags as ttreport plus --cutoff, writing history to stdout and carry to the path given by --carry. Cost if wrong: Task 9 cannot wire compaction and the task is blocked.

Ruling: `__pycache__/` is not in .gitignore and no task covers it — Python bytecode will otherwise be committable from Task 2 onward. Folding a .gitignore line into Task 2's dispatch rather than editing from the controller. Cost if wrong: a stray __pycache__ commit, trivially reverted.

Ruling: PLAN-MANDATED FINDING UPHELD. The plan's own `if index < 0: break` and its test `test_span_before_the_first_boundary_is_dropped` specify the buggy behaviour, and the implementer transcribed them faithfully. Confirmed live: split_days([(50,150)],[100,200]) -> [] instead of [(100,(100,150))]. Not reachable via bin/tt (both call sites clip first; tt_day_boundary_epochs guarantees boundaries[0] = midnight(since) <= since), but the module's stated contract is "no domain knowledge lives here", so its correctness must not rest on caller discipline, and the failure mode is silent under-reporting — the exact class this redesign exists to remove. Fixing, and amending the plan to match. Cost if wrong: none reachable; the changed behaviour replaces a return of [] in a case no shipped caller produces.

Ruling: the empty-boundaries IndexError is a regression introduced by the round-1 fix, not a pre-existing minor, and Task 7's `--boundary action="append", default=[]` makes it reachable from the CLI. Overriding the re-reviewer's Minor classification and fixing it in round 2. Cost if wrong: one extra fix round on a one-line guard.

Ruling: deviation 1 UPHELD as a brief defect. My brief checked the solo-command word BEFORE the recorded fingerprint, so a replayed /goal would re-match the command word and classify `trigger` forever, never `machine` — an overnight /loop would re-arm solo on every wake instead of being seen as machine continuation. The implementer inverted the order. Verified live: 1st /goal -> trigger, replay -> machine, check-in -> human. Cost if wrong: none; the brief's order could not satisfy the brief's own test.

Ruling: deviation 2 UPHELD. `tt_cache_mode` is required because an auto transition must reach the live $TT_HOME/modes cache that debug-mode and tt_mode read, not only the durable log row. My brief wrote the row alone, which could not satisfy its own debug-mode assertion. Cost if wrong: an auto-solo transition would not be visible to the next hook on the same session.

Ruling: deviation 3 UPHELD. cmd_init's template was extended, not replaced. My snippet dropped TT_IDLE_GAP/TT_READING_WPM/TT_MAX_READING_TIME, which still exist until Task 10, and documented TT_PRESENCE_GAP/TT_CHECKIN_WINDOW, which arrive in Task 8. Tasks 8 and 10 finish the template. Cost if wrong: a transiently over-full config comment, corrected two tasks later.

Ruling: deviation 4 (unreported) UPHELD. A `last_beat` test helper replaced `tail -1`, because the automatic mode row is appended after the trigger beat, so tail -1 would read the mode row. Verified: the mode row carries 11 columns and origin `auto`, and parse_line pads short rows from MIN_COLUMNS=11, so an 11-column mode row still parses. Cost if wrong: the trigger assertions would test the wrong row.

Ruling: the ⚠️ item (is "-" ever a legitimate subpath?) is resolved as a non-issue. Checked capture directly: tt_attribute writes "." for a project root and a real subpath otherwise, never "-", and the live mode row from the Task 3 verification carries subpath=".". The "-"/"" handling in _covers is defensive only. Cost if wrong: none; the branch is unreachable from capture.

Ruling: the Important finding is UPHELD, though the shipped behaviour is already correct (verified: scope sportx/saas-backend -> saas-backend-old = paired, -> saas-backend/api = solo). It is a regression-protection gap: removing the `+ "/"` leaves all six tests green while leaking a sibling project's transitions. Tests only, no implementation change. Cost if wrong: two extra tests.

CORRECTION: the controller's framing of the Task 5 named risk was wrong. It claimed subagent completions landing after the parent Stop make this the normal case; SubagentStop is not in TOOL_CLOSE and never participates in tool brackets, so those 107 events are irrelevant here. Measured against the exact condition (a bracket opening inside a turn and closing after that turn's close event): 1 of 257 brackets, 7 seconds mis-attributed across the whole log. The reviewer's severity reasoning rested partly on that bad framing.

Ruling: the defect is UPHELD and will be fixed anyway, on its merits rather than its magnitude. It violates the spec's stated definition of agent time (worker elapsed less the union of the tool calls inside it), machine.py:65 is a genuine dead write into an accumulator close_turn has already consumed, and the result is order-dependent in the module every later task's MACHINE column rests on. The fix — resolve turns against a complete set of tool spans in a second pass — also removes the order dependence rather than patching around it. Cost if wrong: restructuring the plan's most intricate function for 7 seconds of measured impact, with regression risk held down by the nine existing tests plus a new straddle test.

Ruling: this is a contradiction inside the SPEC, not a defect in Task 6. The spec asserts both "Effort never exceeds wall-clock time for a single project" and "EFFORT is the sum of PAIRED, CHECKIN and MANUAL". With overlapping categories both cannot hold, and they overlap on the documented workflow (check in during a solo run, then run `tt paired` on return). The wall-clock bound is the design's founding principle — "a number that can exceed twenty-four hours in a day is not effort" — so it is binding and the sum is the statement that yields. Resolution: effort categories are made DISJOINT in priority order paired > checkin > manual, so the per-category columns still sum exactly to EFFORT and EFFORT still equals the union of all effort spans. Paired outranks checkin because a paired interval is bracketed by two heartbeats while an episode window is an assumption around one; manual ranks last because it is a typed claim rather than an observed event. Cost if wrong: up to half a check-in window per return is attributed to paired instead of checkin — the EFFORT total is identical either way, only the column split moves.

Ruling: the fix belongs in Task 7 (report aggregation), where categories are combined, not Task 6, which correctly returns raw per-category spans. Task 6 is reviewed as-is; the requirement is carried into Task 7's dispatch.

Ruling: finding UPHELD, suggested remedy REJECTED. Verified: prompt@0, tt solo@2000, prompt@2100 -> paired=0, losing 2000s of real paired work (an under-count, the failure this redesign exists to remove). But the reviewer's proposed fix — drop the look-ahead guard so crediting depends only on the earlier heartbeat's mode — was verified to give prompt@0, tt solo@10, return@3000 -> paired ~= 3000, billing a 50-minute unattended run entirely as the user's time. That is the catastrophic over-count the project started from. The guard was a crude defence against it that also discarded the legitimate half.

Ruling: correct fix is to SPLIT the paired interval at the mode change, which the design spec already states ("a mode change applies forward from its timestamp"). ModeTimeline gains next_change(stream, when, project, subpath) sharing the existing scope test; the paired branch credits up to min(next heartbeat, next mode change). Cost if wrong: a paired interval ending at a transition rather than at the following heartbeat — bounded by the gap between the two, and erring toward the smaller credit.

Ruling: the ⚠️ item (project attribution when one session changes project mid-episode) is deferred, not resolved. Row.stream is session-keyed so a session that cd's between repos attributes a whole episode to the earlier heartbeat's project. Real but out of scope for this task; recorded for the final review.

Ruling: fix by grouping heartbeats on a presence key that ignores harness, local to effort.py. Row.stream is NOT changed — machine.py depends on its current grouping. Per-row streams are still passed to ModeTimeline, which only reads machine and session-or-path, so scoping stays correct while grouping unifies. Cost if wrong: two sessions of different harnesses sharing one session id would merge; ids are UUIDs, so this is not reachable in practice.

Ruling: the four TestSoloEffort expectations were set by the F2 preflight ruling on the assumption that a mode row forms its own separate episode. Unifying streams may merge a mode row and a nearby prompt into ONE episode and change those numbers. The implementer is instructed not to edit them but to report the arithmetic for adjudication. Cost if wrong: solo credit shifts by up to one window per mode change.

Task 6: PARKED — _presence_key's no-session fallback still partitions by harness, so a SESSION-LESS `tt paired` (typed in an ordinary external terminal rather than inside a harness shell) reproduces the round-2 bug: the return is not a heartbeat in the prompt's stream, and the work after it is not credited as paired. Ruling: real, but parked rather than fixed. It is not load-bearing — nothing downstream depends on it — and the fix means injecting a path-scoped transition as a heartbeat into every stream it covers, which is materially more machinery than the session-scoped fix, carrying its own risk, at fix round 3 of 5 with four tasks still to run. The user's own documented path (`! tt solo` inside a harness shell, and the bundled skill) exports a session id and is now correct. Cost if wrong: post-return work is under-credited for anyone who runs `tt paired` from a plain terminal. Surfaced to the final review and to the user.

Ruling: the implementer edited two constants in test_machine_columns_are_not_added_into_effort, which the dispatch forbade, and flagged it. UPHELD. Verified independently: rows prompt@0, stop@3600, prompt@3700 give PAIRED=1800 (the 3700s gap exceeds presence_gap 3600, so half credit applies) and AGENT=7200 (turn 0-3600, plus the prompt at 3700 opening a turn that never closes and capping at max_active 3600). The plan's constants of "1h 01m" and "1h 00m" were arithmetically unreachable against the already-reviewed effort.py and machine.py. The prohibition is on editing a test to match BROKEN code; correcting a test whose constant is impossible against correct frozen upstream modules is the right call, and it was surfaced rather than made quietly. Cost if wrong: none — the corrected values were reproduced by direct execution.

Ruling: the brief's build_report omitted the disjointness subtraction the dispatch required. The implementer added _subtract/_disjoint_effort. Expected and correct — the requirement was carried in the dispatch, not the brief, because it arose from the spec contradiction found during Task 6.

Ruling: UPHELD, and it is my defect — I wrote that test into the plan when carrying the disjointness requirement across from the Task 6 spec contradiction. It is the only guard on the requirement the task was dispatched for. Fix is test-only; the implementation is independently verified correct. The fix must include a mutation check (reverse the priority, see it fail, restore it) as the evidence, not merely a passing run. Cost if wrong: none — no production code changes.

Ruling: the reviewer's adjudication check AGREES with mine on the two corrected constants, derived independently by execution. The test edit was warranted, not a weakening.

Ruling: Minor 1 (with --by day, buckets are keyed by day alone so two projects merge into one DAY row) is INTENDED, not an oversight. `--by day` answers "how much on each day" across the portfolio; `--by project` answers the per-project question. This matches the pre-existing report's behaviour. No change. Cost if wrong: a user wanting per-project-per-day would need --detail semantics that do not exist; none has been requested.

Ruling: the 75 shell failures are ACCEPTED as a bounded, known state through Tasks 9-10, not fixed now. Verified the cause: the old shell suite encodes the OLD accounting model. Its `beat` helper writes an EVENTLESS beat, and the retired flat rule counted any two beats within TT_IDLE_GAP; under the new model an eventless beat is neither a heartbeat nor a lifecycle bracket, so it contributes nothing. Forcing those assertions green now would mean rewriting expectations that Tasks 9 and 10 will change again. Breakdown: ~18 reading-estimate (Task 10 retires them), ~7 compaction (Task 9 rewires), the rest mode/lifecycle expectations of the old model. Mitigation: the exact 75 failing assertion NAMES are captured at .superpowers/sdd/2026-09-08-effort-and-machine-time/failing-baseline.txt, so any NEW failure is still detectable by diff — the count alone would not be. Task 10 carries an explicit mandate to bring the suite green, each remaining assertion either updated to the new model or deleted with a stated reason. Cost if wrong: two tasks run with a red suite whose signal comes from the baseline diff rather than from zero.

Ruling: two controller hypotheses were tested and REJECTED before accepting the above — making the beat helper emit a real UserPromptSubmit heartbeat (76 failed, worse) and removing the compaction call from cmd_report (78 failed, worse). Recorded so neither is retried.

Ruling: MIGRATION of old-format total rows is a REQUIREMENT of Task 9, not an optional nicety. The real log holds 87 of them (64 paired, 15 solo, 8 manual) carrying seconds at column 11 against the new format's column 16, so without a mapping they silently vanish. Mapping: old `paired` -> PAIRED, old `manual` -> MANUAL, old `solo` -> AGENT. Old `solo` meant "the agent ran while you were elsewhere", which under the new model is machine time and not the user's effort, so AGENT is its honest home; it cannot be split into AGENT/TOOL because the old row carries only a duration. Cost if wrong: 15 rows of historical agent-alone time land in the wrong machine column, or, if not mapped at all, a week of history disappears from every report.

Ruling: the 2 gained shell failures ("compaction keeps estimated seconds inside paired time", "compaction keeps the estimated subset visible") are ACCEPTED — both assert the retired reading-time-estimate mechanism, which the spec withdraws and Task 10 removes. 6 were fixed, including "legacy completed detail keeps its reported total", which is the old-format migration working. Baseline re-pinned at 70. Cost if wrong: none; both names name the estimate explicitly.

Ruling: finding PARTIALLY UPHELD, severity reduced, state-carry work NOT authorized. I could not reproduce any of the three end-to-end through bin/tt across four scenarios: two heartbeats straddling a 3-day-old midnight (0h 02m both sides, 2 total rows written), two straddling the cutoff itself (0h 04m both sides), a solo mode row before the cutoff with check-ins after (0h 50m checkin / 1h 10m agent both sides), and the full real log over a week (every column identical, idempotent). bin/tt compacts only completed days and leaves everything at or after the cutoff in carry, so its cutoff never lands mid-activity the way the reviewer's direct calls placed it. Building the synthesized state carry would be significant machinery for a case the shipped path does not produce.

Ruling: what IS upheld is the coverage gap — no test places a turn, tool bracket or mode transition AT the cutoff. Fix round 1 asks for four round-trip tests that do, exercising the real path, with instructions to STOP and report rather than paper over a disagreement. If one fails, the finding is real and I will authorize the state carry as its own round. This converts a disputed finding into evidence at low cost.

Ruling: reviewer's Minor 1 (a carried span's iso is not clipped alongside its numeric start) folded into the same round — one line, and the retired awk kept them consistent.

Ruling: reviewer's Minor 2 (_collect_totals includes a total row wholesale if it overlaps the window at all) accepted as unreachable — bin/tt always resolves --since/--until to day boundaries and compacted rows are exactly one day wide. Deferred, not fixed.

CORRECTION: my Task 9 adjudication was WRONG and is reversed. I ruled the reviewer's finding unreproducible end-to-end; that conclusion rested on a broken test. I computed the cutoff as `NOW - NOW % 86400`, which is UTC midnight, while tt uses LOCAL midnight — four hours later here — so both "straddling" heartbeats fell on the same side of the real cutoff and the case I claimed to test was never tested. Re-run with `tt debug-midnight`: TRUTH PAIRED 0h 04m / AGENT 1h 04m, AFTER compaction PAIRED 0h 00m / AGENT 1h 02m. 240 seconds of real paired work destroyed.

Ruling: Task 10 REWRITTEN with the user's agreement — delete the ~70 obsolete accounting assertions and retire report.awk, rather than re-deriving 70 expected values for a model that no longer exists. The accounting has better coverage in Python (110 tests, 0.07s) than in shell (277 assertions, 45s). Verified none of the 70 failures touch capture: every hook assertion passes.

Ruling: a follow-up plan will split bin/tt into a standalone bin/tt-hook (305 lines of hook path, currently loading 1046 unused lines on every fire) plus lib/tt-common.sh for the 7 helpers shared with the CLI. Agreed to run AFTER Task 10, so the split has a green suite as its safety net. NOT part of this plan.

Ruling: the controller's earlier proposal to also move attribution and mode resolution to read time is WITHDRAWN as invented scope. The user asked for a file split; the data model stays as it is.

Ruling: finish Task 10, review the completed original branch, execute both split tasks, then cleanup in separate commits — user confirmed this sequence. Cost if wrong: additional small commits; each can be reverted independently.

Ruling: remove the unused beat mode stamp only in cleanup, writing '-' in the existing column and retaining explicit transitions and old-log compatibility — user asked us to decide from the goal and then authorized execution. Cost if wrong: external consumers relying on the redundant beat value must use transition rows; repository readers do not use it.

Ruling: preserve canonical coalesced effort coverage in new history and allocate within-category overlapping subpath claims lexicographically — scalar-only per-subpath totals cannot preserve the spec's project union across rollover, late manual entries, or multiple machines. Cost if wrong: detailed subpath shares depend on a documented tie-breaker; history stores bounded coverage runs instead of only scalars.

Ruling: retain minimal unresolved facts and replaceable provisional credit across rollovers, rather than expire/floor unknown future work — future heartbeats and matched closures can change earlier credit. Cost if wrong: more compacted-state machinery, bounded by unresolved sessions/workers.

## Standalone hook split

Ruling: use the post-Task-10 baseline, preserve every existing assertion name through the split, and allow only the new entry-point/forwarder checks to increase counts — Task 2 explicitly requires them. Cost if wrong: four or more additional checks, no product behavior change.

Ruling: keep all capture logic and beat mode stamps unchanged during both split tasks; later cleanup is separate and user-authorized. Cost if wrong: one extra commit boundary.

Ruling: allow test-only changes in tests/python/test_cli.py for the bootstrap regression, despite split's no-Python-changes constraint — runtime Python remains untouched and actual CLI coverage belongs in the Python subprocess suite established in Task10. Cost if wrong: two or more additional focused tests; no runtime scope expansion.

## Final cleanup

Ruling: share path-scoped heartbeat projection between effort and carry, retaining the terminal stream and projecting only to covered observed session locations. Cost if wrong: incorrect scope projection could duplicate presence or credit the wrong path; project coverage, nested/sibling/machine tests, and incremental rollover regressions constrain this.

Ruling: accept unstamped beats in shell rollover validation while retaining legacy paired/solo values and strict mode-transition validation. Cost if wrong: rejecting the new stamp would silently prevent rollover; actual standalone-hook rollover tests verify the new capture format.

Ruling: uphold I1 and retain sufficient scoped transition boundaries for future session projection; do not drop first-session support or alter machine grouping to hide the discrepancy. Cost if wrong: additional carry state; both scope directions and repeated incremental rollover must preserve all report columns.

Ruling: allow retaining session-less mode-transition history as the smallest exact I1 repair, excluding raw hook history and preventing replay into already-carried sessions. Avoid a new overlapping-path frontier architecture solely to optimize human-sized transition history. Cost if wrong: retained transition state grows with mode commands; document this explicit storage tradeoff and verify repeated carry.

## Codex runtime review

Ruling: SessionEnd closes open work but does not extend completed work or seed a continuation. Cost if wrong: a harness using shutdown itself as a continuation signal would lose that inferred interval; actual Codex shutdown and explicit Stop continuation regressions distinguish the cases.

Ruling: use Codex SubagentStart/SubagentStop and observed child IDs for asynchronous worker time, keeping synchronous Task/Agent inference for other harnesses. Cost if wrong: Codex logs missing explicit lifecycle events cannot recover a child's full lifetime from its short spawn call. Actual parent/child capture and rollover tests verify the supplied telemetry.

Ruling: report native Codex goal auto-solo as unsupported by the current hook contract, rather than infer intent from ordinary prompt text or permission mode. Explicit tt solo is a workaround, not fulfillment of auto-detection. Cost if wrong: a future supported goal-start field could enable automatic mode selection; the finding is version-scoped to the tested Codex 0.153.4 contract.
