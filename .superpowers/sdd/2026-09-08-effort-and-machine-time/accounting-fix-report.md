# Accounting integration repair

Status: R1–R7 implemented and verified on `effort-machine-time`, from `5550236`.
The hook split plan remains untouched. No live `~/.timetrack` data was read or
modified; copied-log verification used the controller's immutable snapshot.

## Findings and regression evidence

All `test_r*` names below are in `tests/python/test_accounting_repairs.py`.
Its shared helpers assert all six columns in project/day views with detail on
and off, one-pass reconstruction, repeated cutoff, and incremental rollover
before future observations arrive, followed by an advancing cutoff.

| Finding | Repair | Focused evidence |
| --- | --- | --- |
| R1 | Shared canonical project effort; exact coverage survives compaction and late additions; deterministic subpath allocation. | `test_r1_subpaths_share_project_union`, `test_r1_historical_manual_additions_union`, `test_r1_coverage_is_canonical_and_bounded`; CLI `test_historical_manual_additions_reconcile_stored_coverage` |
| R2 | Keep unresolved heartbeats/openings; emit only stable machine durations; coalesce tool coverage and pending closed turns. | `test_r2_incremental_heartbeat`, `test_r2_stale_heartbeat_and_matched_turn`, `test_r2_long_tool_survives_multiple_rollovers`, `test_r2_closed_tools_survive_while_turn_is_unresolved`, `test_r2_pending_closed_turns_have_bounded_coverage`; CLI `test_rollover_before_a_later_prompt_and_stop_preserves_old_seconds` |
| R3 | Normalize within project before summing display/day buckets. | `test_r3_day_sums_projects` and all four display modes in the shared helpers |
| R4 | Remove shared prior-credit floor; lifecycle state retains machine/session/worker identity through reconstruction. | `test_r4_different_machine_frontiers` |
| R5 | Carry recent terminal timestamp as continuation seed. | `test_r5_stop_continuation` |
| R6 | Ordinary SessionStart closes/reset brackets and continuation; Codex source=compact preserves them. | `test_r6_reset_versus_codex_compaction`, including carried open brackets |
| R7 | Tool keys retain observed worker identity; spawned workers subtract their own tool union. Unknown associations cannot subtract from arbitrary workers. | `test_r7_child_subtracts_own_tools`, `test_r7_ambiguous_children_are_not_assigned_arbitrarily`, `test_r7_later_binding_does_not_claim_earlier_ambiguous_tools` |

The initial eleven integration regressions failed against the base for the
reported accounting errors before implementation. Subsequent failing-first
checks caught solo episode attribution changing after rollover, excessive
pending Stop rows, malformed coverage acceptance, and a later unambiguous
spawn binding incorrectly claiming earlier ambiguous child tools. Those are
fixed; the final ownership check marks association per opening and carries it.

## Storage and product decisions

- New history retains the twenty-column shape. `coverage` stores exact effort
  interval bounds, category, allocated project/subpath, and duration. Coalesced
  disjoint runs split at local midnight are bounded by the day's integer
  seconds per project. `total` remains additive for closed stable machine
  work and opaque legacy durations. Python parsing and shell validation agree.
- Shell compaction routes existing coverage back through reconciliation with
  new inputs, including real historical `tt add`. Duration-only legacy totals
  stay readable; their lost timestamp coverage is never inferred.
- Pending machine estimates are never immutable history. Carry opening/id,
  coalesced already-credited own-tool coverage, and pending closed-turn union
  until the required close/reset arrives. This permits pre-cutoff corrections
  without raw-event retention or cross-machine credit suppression.
- A heartbeat remains available after long gaps. A solo frontier also retains
  its original episode attribution; a Stop seed expires after max_active.
- In the winning effort category, smallest normalized subpath owns a second.
  Child telemetry associates with the sole eligible active spawning bracket;
  ambiguous openings stay unassociated even if later tools become attributable.
  README and the bound spec document these rules and internal state fields.

## Verification

- `PYTHONPATH=lib python3 -m unittest discover -s tests/python`: **134 passed**.
- `TMPDIR=/tmp/tt-accounting-sh sh tests/run.sh`: **204 run, 0 failed**.
- `TMPDIR=/tmp/tt-accounting-dash dash tests/run.sh`: **204 run, 0 failed**.
- `python3 .superpowers/sdd/2026-09-08-effort-and-machine-time/verify-snapshot.py`:
  **all four report modes preserve every column through CLI rollover/repeat**.
- `git diff --check`: clean.

The last self-review ownership refinement was followed by the full Python
suite (including actual CLI regressions); the already-green shell suites were
not repeatedly rerun. Exact shell assertion names for the split baseline are
in `accounting-shell-assertions.txt` (204 lines). The three renamed shell
assertions reflect required storage changes: completed effort now stores
coverage, late manual work joins coverage, and an old heartbeat remains as
minimal unresolved state. Task 10 assertion names remain unchanged.
Python storage assertions now accept coverage run endpoints and sum separated
category runs; no accounting expectation was weakened to hide a regression.

## Limits

Legacy duration-only effort cannot be deduplicated retrospectively. Missing or
ambiguous child association remains explicit rather than inferred. Pending
identities can remain across many rollovers until evidence/reset arrives, as
required; interval context is coalesced and raw hook history is discarded.
No split or unrelated cleanup work was included.
