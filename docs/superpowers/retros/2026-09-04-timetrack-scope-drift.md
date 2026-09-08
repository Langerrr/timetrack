# timetrack — scope drift retro

Date: 2026-09-04

Session notes captured before a from-scratch redesign, so that session
inherits this history instead of re-discovering it. This is a record of what
happened and what we found, not a proposal — no decision is made here.

## Where it started (0abe31d, 2026-09-02 15:56)

The first design spec was small:

- Two event kinds: `beat` (from a hook, a point in time) and `span` (a manual
  entry with a stated duration). No `mode` event, no `total`/`compact`/`state`
  rows, no rollover.
- Eleven TSV columns, permanently. No lifecycle identifiers.
- Five hooks: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
  `Stop`.
- The entire reconstruction rule, in full: "Two consecutive beats less than
  `TT_IDLE_GAP` apart (default 900 seconds) contribute their difference,
  credited to the mode on the earlier beat. A longer gap contributes nothing
  and opens a new block."
- Mode: one file per session directory, keyed only by absolute path.
- Out of scope, explicitly: "idle detection, and anything resembling billing
  or invoicing."

`9898c03` through `70553a4` (same day, 16:07–17:00) built exactly that design,
test-first. Everything after this point is growth beyond it.

## How it grew

**Wave 1 — infrastructure (2026-09-02, 18:54–20:48).** Packaging, mac-mini
install over SSH, the natural-language skill, sort-order and DST fixes,
session-scoped modes (`5d763da`) and mode-file locking (`4226002`). Real
hardening, not reconstruction-precision growth.

**Wave 2 — Codex time-accounting improvements (`7768369`, 2026-09-02 23:37).**
The turning point. Its companion plan
(`docs/superpowers/plans/2026-09-02-codex-time-accounting-improvements.md`)
names the triggering bug directly: *"Codex `PreToolUse` and `PostToolUse`
events bracket a real operation, including a long-running unified shell
command, yet a command lasting more than fifteen minutes currently
contributes zero."* A real 20+ minute shell command was reporting as zero
time, because the flat rule discards any gap longer than `TT_IDLE_GAP`.

The fix was a turn/tool/subagent "known-active" state machine: a completed
`UserPromptSubmit`→`Stop` turn, or a matched tool or subagent pair, counts in
full regardless of `TT_IDLE_GAP`. This required six new lifecycle columns
(`turn_id`, `tool_use_id`, `agent_id`, `agent_type`, `assistant_words`,
`session_source`) and more hook types (`Interrupt`, `SessionEnd`,
`SubagentStart`, `SubagentStop`, `StopFailure`, `PostToolUseFailure`,
`PermissionDenied`). The same plan document also specified the reading-time
estimate formula (word count × WPM, bounded) that later shipped in wave 5.

**Wave 3 — closing every ending (`c0d04c3`, same day 23:59).** A necessary
guard on wave 2: if known-active intervals ignore `TT_IDLE_GAP`, then a turn or
tool call whose ending is never recorded (Claude Code fires no hook on
interrupt) would otherwise bill the entire unbounded absence that follows it.
Introduced `TT_MAX_ACTIVE_GAP` as a ceiling.

**Wave 4 — compaction (`f2f9f9d`, `1578348`, `8a1b37f`, 2026-09-03).** Storage
model growth downstream of wave 2: the per-event log was now rich enough that
it needed daily rollover into bounded totals, migration from the old
single-file format, and validation before replacing either file. Three new
row kinds (`total`, `compact`, `state`).

**Wave 5 — presence tracking (`993bd73`, 2026-09-03 18:55).** Session-scoped
mode resolution (`--session`/`--all-sessions`) and the mode-gated
Stop-to-prompt reading-time inference: the estimate only fired when the
return prompt was already tagged `paired`. This is the exact mechanism two of
today's bugs lived in.

Each wave targeted a real, specific, observed defect. None of it was
speculative. The result is still that `Stop` now has three different
behaviors depending on mode and what event fires next, and today's two bugs
were new special cases colliding with earlier ones.

## What today's session found and fixed

- A subagent's own `Stop` arriving after the parent turn's `Stop` zeroed the
  gap between them instead of counting it — the "close every ending" rule
  from wave 3 was stricter than wave 2's own subagent tracking needed.
- The wave-5 reading-time estimate required the return prompt to already be
  tagged `paired`; if mode was never flipped back, it credited nothing at all
  rather than falling back to the bounded estimate.
- `TT_IDLE_GAP` at its 900-second default was tight enough to regularly cut a
  real read-and-compose cycle to zero. Raised to 1800.

All three are fixed and tested on `main`.

## What's still structurally lost

Verified against the current code, not yet decided whether to address:

1. **A solo run with no follow-up prompt, ever.** The reading estimate is a
   side effect of the *next* `UserPromptSubmit` on that stream. If you read
   the final output and walk away without prompting again, nothing ever
   consumes the pending estimate. Structural — there is no session-idle-out
   fallback.
2. **A paired gap past `TT_IDLE_GAP` is all-or-nothing, not capped.** A
   45-minute gap (pulled into a meeting) credits zero minutes, not
   `TT_IDLE_GAP`'s worth. This is a design choice, not a hook limitation —
   fixable if wanted.
3. **The solo reading-time estimate caps at `TT_MAX_READING_TIME`** (600s)
   regardless of actual response length or actual elapsed reading time.
4. **Switching to a different project/session tab and back** loses whatever
   reading gap was pending on the first tab, once its own return event is
   more than `TT_IDLE_GAP` late — the same shape as #2, reached through a
   common multi-project workflow rather than a single long gap.

Verified against current Claude Code and Codex hook documentation: neither
harness exposes a hook for typing, composer focus, or "user became active
again." Claude Code's `Notification`/`idle_prompt` fires the opposite
direction — it announces the user went idle ~60 seconds after `Stop`, it does
not announce a return. Items 1, 3, and 4 above are downstream of this absence
and cannot be closed by wiring more hooks. Item 2 is not.

## Root cause

A hook can prove an agent did something. No hook in either harness can prove a
human is present without acting. Every mechanism added since wave 2 —
known-active tracking, the reading-time estimate, mode-gating — is an attempt
to infer the second thing from the absence of the first, and that inference is
approximate by construction, not by omission. Each new special case has had to
be reconciled against `Stop`, mode, and event ordering, and the reconciliations
now interact with each other, which is what produced two independent bugs in
the same code path within one day of the last change.

## Where this leaves the next session

Two directions were raised and not decided:

- **Keep known-active, drop the inference around it.** A provably open
  turn/tool/subagent still counts in full (wave 2's fix for the 20-minute
  shell command stays). Reading-time estimates and Stop-mode-gating go away;
  return-gap credit falls back to the same flat "two beats within
  `TT_IDLE_GAP`" rule used everywhere else.
- **Full revert to the original flat rule**, everywhere, including inside a
  turn. Simplest and most predictable, at the cost of reintroducing the
  wave-2 bug (a long single tool call with no intermediate beats can lose
  real solo time).

Also worth deciding directly: the stated goal is evaluating time spent per
project *per period* (day/week/month), not a precise reconstruction of any
single session. A period aggregates many sessions, so a few minutes of noise
in either direction on one session washes out — which argues for picking
whichever rule is simplest to reason about over whichever is locally most
accurate.
