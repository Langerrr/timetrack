# timetrack — scope drift

Date: 2026-09-04, extended with measurements taken 2026-09-08

A record of how the accounting rule grew between 2026-09-02 and 2026-09-03, and
what was measured in the resulting code.

## The original design (0abe31d, 2026-09-02 15:56)

- Two event kinds: `beat` (a hook firing, a point in time) and `span` (a manual
  entry with a stated duration).
- Eleven TSV columns. No lifecycle identifiers.
- Five hooks: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
  `Stop`.
- One reconstruction rule, in full: "Two consecutive beats less than
  `TT_IDLE_GAP` apart (default 900 seconds) contribute their difference,
  credited to the mode on the earlier beat. A longer gap contributes nothing and
  opens a new block."
- Mode: one file per session directory, keyed by absolute path.
- Out of scope, explicitly: "idle detection, and anything resembling billing or
  invoicing."

`9898c03` through `70553a4` (16:07–17:00 the same day) built that design,
test-first.

## The waves

**Wave 1 — infrastructure (2026-09-02, 18:54–20:48).** Packaging, mac-mini
install over SSH, the natural-language skill, sort-order and DST fixes,
session-scoped modes (`5d763da`), mode-file locking (`4226002`).

**Wave 2 — Codex time-accounting (`7768369`, 2026-09-02 23:37).** Its plan
(`docs/superpowers/plans/2026-09-02-codex-time-accounting-improvements.md`)
names the trigger: "Codex `PreToolUse` and `PostToolUse` events bracket a real
operation, including a long-running unified shell command, yet a command lasting
more than fifteen minutes currently contributes zero."

The fix was a turn/tool/subagent known-active state machine: a completed
`UserPromptSubmit`→`Stop` turn, or a matched tool or subagent pair, counts in
full regardless of `TT_IDLE_GAP`. It added six columns (`turn_id`,
`tool_use_id`, `agent_id`, `agent_type`, `assistant_words`, `session_source`)
and seven hook types (`Interrupt`, `SessionEnd`, `SubagentStart`,
`SubagentStop`, `StopFailure`, `PostToolUseFailure`, `PermissionDenied`). The
same plan specified the reading-time formula that shipped in wave 5.

**Wave 3 — closing every ending (`c0d04c3`, same day 23:59).** With
known-active intervals ignoring `TT_IDLE_GAP`, a turn or tool call whose ending
is never recorded would bill the unbounded absence after it. `TT_MAX_ACTIVE_GAP`
caps it.

**Wave 4 — compaction (`f2f9f9d`, `1578348`, `8a1b37f`, 2026-09-03).** Daily
rollover into bounded totals, migration from the single-file format, validation
before replacing either file. Three row kinds added: `total`, `compact`,
`state`.

**Wave 5 — presence tracking (`993bd73`, 2026-09-03 18:55).** Session-scoped
mode resolution (`--session`/`--all-sessions`) and the mode-gated Stop-to-prompt
reading-time inference, which fired only when the return prompt was already
tagged `paired`.

**Wave 6 — uncommitted, in the working tree.** `TT_IDLE_GAP` 900→1800; a
subagent `Stop` after the parent turn's `Stop` counts rather than zeroing; the
reading estimate fires whether or not mode was flipped back to `paired`. Not on
`main`.

## Measured growth

| | `70553a4` (original complete) | `993bd73` (wave 5) |
|---|---|---|
| `bin/tt` | 338 lines | 1225 |
| `lib/report.awk` | 63 | 592 |
| `tests/run.sh` | 186 | 1077 |
| TSV columns | 11 | 17 |
| row kinds | 2 | 6 |
| hook events | 5 | 12 |

Twenty-six hours elapsed between the two commits.

The original rule had one input: is the gap under `TT_IDLE_GAP`. The rule at
`lib/report.awk:283-310` has twelve: previous event, current event, previous
mode, turn-id match, open tool count, open subagent count, lifecycle epoch,
pending-estimate presence, assistant word count, and three tunables.

`Stop` has four outcomes, depending on what fires next:

| next event after `Stop` | gap |
|---|---|
| `SubagentStop` | counts in full |
| `UserPromptSubmit`, previous mode `paired`, no pending estimate | counts if ≤ `TT_IDLE_GAP` |
| `UserPromptSubmit`, estimate pending | gap rule suppressed; bounded estimate credited |
| anything else | zero |

## What today's session (2026-09-04) fixed

- A subagent's `Stop` arriving after the parent turn's `Stop` zeroed the gap
  between them instead of counting it.
- The reading-time estimate required the return prompt to be tagged `paired`; if
  mode was never flipped back it credited nothing.
- `TT_IDLE_GAP` at 900 seconds cut real read-and-compose cycles to zero. Raised
  to 1800.

These three are in the working tree, not on `main`.

## Measurements taken 2026-09-08

**Parallel sessions on one project double-count.** Two sessions, both `paired`,
both running one real hour on the same project, report two hours of paired time.
Three sessions report three. Mode settings do not affect it.

**`SubagentStart` has never fired.** It is configured in both `hooks/hooks.json`
and `hooks/codex-hooks.json`, appears zero times across the entire log, and is
absent from Claude Code's valid hook-event list. `agent_open` is therefore never
set, `active_agents` at `lib/report.awk:397` is only ever decremented, and wave
2's subagent tracking has never marked an interval active. Ten `SubagentStop`
events were recorded on 2026-09-08 with no matching starts.

**The reading estimate undercounts.** A 1056-word response at the configured 120
wpm credits 528 seconds; the measured Stop-to-prompt gap was 891 seconds.

**Word count does not predict the gap.** Measured on 2026-09-08: 647 words →
1015s, 1056 words → 891s, 977 words → 662s, 724 words → 866s. The longest
response drew the second-shortest gap.

**Human and agent shares of a focused session.** Three consecutive turn cycles
on 2026-09-08: agent 76s / human 891s, agent 101s / human 866s, agent 89s /
human 1015s — 90 to 92 percent human.

**Prompt frequency does not track engagement.** That session ran 5.3 prompts per
hour across 68 minutes while the human did ~90% of the elapsed time.

**Tool execution is a small share of a turn.** Seven turns on 2026-09-08:
durations 63, 101, 76, 101, 89, 125, 148 seconds, containing 0, 4, 3, 3, 0, 12
and 1 seconds of tool time.

**Turn brackets undercount agent work.** Summed `UserPromptSubmit`→`Stop`
intervals for 2026-09-08 came to 11.7 minutes against `/usage` reporting 17m 4s
of API time for the same session. Hook-driven continuation turns close with
`Stop` but open with no prompt, so no bracket covers them.

## Hook coverage

Verified against current Claude Code and Codex documentation: neither harness
exposes a hook for typing, composer focus, or a user becoming active again.
Claude Code's `Notification`/`idle_prompt` announces that the user went idle
roughly 60 seconds after `Stop`; it does not announce a return.

`UserPromptSubmit` carries the prompt text as `user_prompt`
(`plugin-dev/skills/hook-development/SKILL.md:317`). `tool_name` is available on
tool events and is not currently recorded.

## Structural consequences of the rule as it stands

1. A solo run with no follow-up prompt never consumes its pending reading
   estimate. The estimate is a side effect of the next `UserPromptSubmit` on
   that stream.
2. A paired gap past `TT_IDLE_GAP` credits zero rather than a capped amount.
3. The solo reading estimate caps at `TT_MAX_READING_TIME` (600s) regardless of
   response length or elapsed time.
4. Switching to another project's session and back loses the pending reading gap
   on the first once its return event is more than `TT_IDLE_GAP` late.
