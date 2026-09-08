# timetrack — effort and machine time

Date: 2026-09-08

## Purpose

Report how much **effort** each project under `~/workspace` consumed over a day,
a week or a month, and separately how many **agent hours** it consumed.

Effort is the user's own engagement. Agent hours are the machine's work. They
are different quantities in different units and are never added together.

## Runtime

Capture stays in POSIX `sh` and `awk`, so a hook runs anywhere a harness does.
Reporting may use Python where the arithmetic earns it.

## The two measures

### Effort

Effort is bounded by one human timeline. A number that can exceed twenty-four
hours in a day is not effort.

- Within a project, concurrent sessions **union**. Two sessions attended for the
  same hour are one hour.
- Across projects, concurrent attention **double-books**. An hour spent moving
  between two projects records an hour against each, because holding two
  contexts at once costs more than holding either alone.

Effort therefore never exceeds wall-clock time for a single project, and may
exceed it across a portfolio.

### Machine time

Machine time is what the agents did. It is expected to exceed wall-clock time
and carries no presence claim.

A **worker** is either a main session or one subagent instance. Five subagents
running ten minutes alongside their parent are five workers plus their parent.
The tool call that spawns a subagent opens that new worker; it runs alongside
its parent rather than inside it.

Machine time is reported in two categories, each summed over every worker:

- **Agent time** — a worker's elapsed interval, less the union of the tool calls
  inside it. This is the agent reasoning and generating.
- **Tool time** — the sum of tool call brackets. A command that runs twenty
  minutes is twenty minutes of tool time.

Tool calls within one worker may overlap, so tool time is summed while the
interval subtracted from agent time is their union. Agent time therefore never
goes negative, and tool time may exceed the worker's own elapsed span.

Hooks cannot observe API time directly. Agent time is elapsed-minus-tools, so it
also absorbs harness overhead and queueing, and it runs somewhat above the API
figure a harness reports for itself.

## Evidence

Each measure is reconstructed from its own class of event. Neither is derived
from the other, and the two may overlap freely: a check-in during an unattended
run is both a moment of effort and part of a longer stretch of machine time.

### Heartbeats — evidence of the user

A heartbeat is an event only a present human produces:

- `UserPromptSubmit` with no `agent_id`, whose prompt is not machine-generated
- a `tt paired` or `tt solo` command
- a `tt add` span

`SessionStart` is not a heartbeat: sessions resume and compact on their own.
Tool and subagent events are not heartbeats: they are the agent, not the user.

**Machine-generated prompts are excluded.** A `/loop` wake-up and a `/schedule`
firing arrive as `UserPromptSubmit` while nobody is at the keyboard, and they
replay the prompt that started the run. Each prompt is fingerprinted; inside a
solo run, a prompt whose fingerprint matches the run-starting prompt is a
machine continuation and marks machine time only. A prompt that differs is the
user, and is a heartbeat.

The prompt arrives as `user_prompt`, falling back to `prompt` for a harness that
names it differently.

### Lifecycle brackets — evidence of the agents

A worker's active intervals come from matched pairs. The main session runs from
`UserPromptSubmit` to `Stop`. A tool call runs from `PreToolUse` to
`PostToolUse`, matched on `tool_use_id`.

A subagent's interval comes from the bracket of the tool that spawned it: the
`PreToolUse` that launched it opens the interval, and the `PostToolUse` carrying
the same `tool_use_id` closes it. `SubagentStop` names the agent that finished
but not when it began, so it confirms an ending rather than measuring a span.

Recognising that bracket requires `tool_name` on every tool row.

A turn a hook drives rather than a prompt — a `Stop` hook that sends the agent
back to work — closes with `Stop` but opens with no `UserPromptSubmit`. Its
interval runs from the previous `Stop`, bounded by `TT_MAX_ACTIVE_GAP`.

Not every ending is recorded — no harness fires a hook on interrupt — so an
unclosed bracket contributes at most `TT_MAX_ACTIVE_GAP`, counted forward from
its opening event. A `SessionStart` that is not a Codex mid-turn compaction
closes everything open on that session.

## Mode

`paired` and `solo` state whether the user was at the keyboard. Mode decides how
the time between heartbeats is read; heartbeats decide when the user was there.
Neither one alone is sufficient, and neither overrides the other.

| Mode | Effort credited |
|---|---|
| `paired` | the whole interval between consecutive heartbeats, or half of `TT_PRESENCE_GAP` when it runs longer |
| `solo` | each check-in episode: its span plus `TT_CHECKIN_WINDOW` |
| `manual` | the stated span of a `tt add` entry |

In `paired`, the interval between two prompts is the work — reading the output,
thinking, and composing the reply. It is credited whole.

The interval is long when the thinking is hard. A design session can run an hour
between prompts while the user is entirely engaged, so `TT_PRESENCE_GAP` is set
for the longest genuine composition rather than the typical one. What keeps an
unattended stretch out of paired time is mode, not this threshold.

An interval longer than `TT_PRESENCE_GAP` credits half of it. A seventy-minute
gap and a three-hour gap both credit thirty minutes, so the most a mislabelled
absence can add is half an hour, and a long think keeps most of its worth.

In `solo`, the user is away by default, and returns in episodes. Consecutive
heartbeats no more than `TT_CHECKIN_WINDOW` apart form one episode. An episode
credits the span from its first heartbeat to its last, plus `TT_CHECKIN_WINDOW`
for arriving and winding down.

A single check-in credits `TT_CHECKIN_WINDOW`. Two prompts ten minutes apart
credit thirty minutes. Checking on a running job at its second hour credits that
episode, not the six hours that follow.

A mode change applies forward from its timestamp and is sticky until the next
change. Setting `solo` after an unattended run does not reclassify that run.

### Automatic solo

Some commands start a long unattended run every time they are used. When a
prompt invokes one, the hook writes a `solo` transition for that session at that
instant.

    TT_SOLO_COMMANDS=goal,loop,schedule

The list is configuration. A machine that names these commands differently sets
its own list.

Automatic solo is session-scoped and ends at an explicit `tt paired` or at
`SessionEnd`. A session left in `solo` under-reports effort rather than
over-reporting it.

Check-ins during an automatic solo run do not end it. They credit effort through
their own heartbeat windows, which is what they are.

## Report

    PROJECT      PAIRED   CHECKIN   MANUAL    EFFORT     AGENT      TOOL
    sportx       3h 05m    0h 20m    0h 45m    4h 10m   18h 40m    7h 50m
    stratos      1h 40m    0h 00m    0h 00m    1h 40m    1h 55m    0h 20m
    TOTAL        4h 45m    0h 20m    0h 45m    5h 50m   20h 35m    8h 10m

`EFFORT` is the sum of `PAIRED`, `CHECKIN` and `MANUAL`. `AGENT` and `TOOL` are
machine time, stand apart in agent-hours, and are not part of any total with the
others.

`--by day`, `--by project`, `--detail`, `--since` and `--until` behave as they do
today.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `TT_PRESENCE_GAP` | 3600 | Longest gap between heartbeats still counted as continuous paired work |
| `TT_CHECKIN_WINDOW` | 1200 | Added to each solo check-in episode, and the gap that separates two episodes |
| `TT_MAX_ACTIVE_GAP` | 3600 | Ceiling on an agent bracket whose ending was never recorded |
| `TT_SOLO_COMMANDS` | `goal,loop,schedule` | Commands that declare a solo run |
| `TT_ROOT` | `~/workspace` | Project root for attribution |

`TT_PRESENCE_GAP` covers the longest gap a hard problem opens between two
prompts. Measured read-think-reply cycles run eleven to seventeen minutes on
routine work and reach an hour on complex design discussion. An hour is also the
prompt-cache lifetime, which pulls the next prompt in ahead of it: a reply
composed after the cache goes cold costs more to send, so one rarely is.

`TT_CHECKIN_WINDOW` is one such cycle rounded up. It serves twice: as the credit
added to a check-in episode, and as the gap above which two heartbeats belong to
separate episodes.

## Storage

The event log keeps its current row kinds and columns. Three additions:

- `UserPromptSubmit` rows carry a flag distinguishing a human prompt, a
  solo-trigger command, and a machine-generated continuation, alongside a short
  fingerprint of the prompt. The prompt text itself is never stored.
- Tool rows carry `tool_name`, so the agent-spawning tool's bracket is
  recognisable.
- Mode rows record whether a transition was set by hand or detected from a
  command.

Compaction keeps its daily rollover, its migration path and its validation. The
carried state narrows to open lifecycle brackets and the last heartbeat per
session.

## Migration

Existing logs replay under the new rules without conversion. Rows predating the
new prompt flag read as human prompts, which is what they were. Rows predating
`tool_name` open no subagent workers, so machine time over historical days
counts main sessions only and rises once the new rows accumulate.

Reading-time estimation and the `ESTIMATED` column are withdrawn. Effort during
`paired` comes from the interval between heartbeats, and during `solo` from the
check-in window.

## Out of scope

Detecting presence without an action. No harness exposes typing, scroll or
composer focus, so time spent reading without replying is credited only through
the mode in force and the heartbeats that bracket it.
